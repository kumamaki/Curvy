import AppKit
import Foundation
import OSLog
import UniformTypeIdentifiers

/// Pre-encryption image preprocessing. Reads a file URL or in-memory
/// `NSImage`, downscales the longest side to ≤ 2048 px, and recompresses
/// to JPEG @ 0.85 quality. Already-small JPEGs pass through untouched
/// — no quality loss for screenshots, no pointless CPU work.
///
/// The output `Prepared.bytes` is what gets fed into AES-GCM. Anything
/// that touches this pipeline ends up encrypted, so we run the resize
/// + recompress *before* the seal to avoid uploading megabytes of
/// ciphertext we'd never want.
///
/// Stateless `Sendable` struct — no shared mutable state. The
/// `Logger` is a static let, also stateless.
struct ImagePipeline: Sendable {
    /// Result of preparing one image. `bytes` is JPEG-encoded and
    /// ready to encrypt; `mime` is always `"image/jpeg"` because we
    /// re-encode every input. `width`/`height` come from the resampled
    /// rep, not the source — they describe the bytes we're going to
    /// upload, which is what the receiver needs to lay out the bubble.
    struct Prepared: Sendable, Equatable {
        let bytes: Data
        let mime: String
        let width: Int
        let height: Int
    }

    enum PipelineError: Error, CustomStringConvertible {
        case unreadable(URL)
        case notAnImage
        case bitmapRepresentationFailed
        case encodeFailed

        var description: String {
            switch self {
            case .unreadable(let url): "couldn't read image at <\(url.path)>"
            case .notAnImage: "the file isn't a recognized image"
            case .bitmapRepresentationFailed: "couldn't build a bitmap representation"
            case .encodeFailed: "couldn't JPEG-encode the prepared bitmap"
            }
        }
    }

    /// Longest-side cap. Anything larger gets resampled down; anything
    /// smaller passes through unchanged (modulo the JPEG re-encode).
    /// 2048px is the sweet spot for a 4-person chat: indistinguishable
    /// from a phone-camera original on a 5K display, ~10x smaller after
    /// JPEG @ 0.85 compression.
    static let maxLongestSide: Int = 2048
    static let jpegQuality: CGFloat = 0.85

    private static let logger = Logger(subsystem: "dev.kumamaki.Curvy", category: "ImagePipeline")

    /// Read URL via `NSImage` and prepare. Used by NSOpenPanel + drag-
    /// drop file URLs. GIFs are passed through as-is to preserve animation;
    /// all other formats are normalized to JPEG.
    func prepare(url: URL) throws -> Prepared {
        if url.pathExtension.lowercased() == "gif" {
            let data = try Data(contentsOf: url)
            guard let image = NSImage(contentsOf: url) else {
                throw PipelineError.unreadable(url)
            }
            return try prepareGIF(rawData: data, image: image)
        }
        guard let image = NSImage(contentsOf: url) else {
            throw PipelineError.unreadable(url)
        }
        return try prepare(image: image)
    }

    /// Prepare raw GIF bytes from a clipboard paste or item provider.
    /// Extracts pixel dimensions from the first frame via `NSImage`.
    func prepare(gifData: Data) throws -> Prepared {
        guard let image = NSImage(data: gifData) else {
            throw PipelineError.notAnImage
        }
        return try prepareGIF(rawData: gifData, image: image)
    }

    /// Prepare an in-memory `NSImage` — used for clipboard pastes (where
    /// the bytes never hit disk) and drag-drop in-memory item providers.
    func prepare(image: NSImage) throws -> Prepared {
        // NSImage's `.size` is in points, not pixels. We want pixel
        // dimensions because the receiver renders at the natural
        // resolution. Pull from the largest bitmap rep, falling back
        // to the image's size if no bitmap rep exists yet.
        let sourcePixelSize = pixelSize(of: image)
        guard sourcePixelSize.width > 0, sourcePixelSize.height > 0 else {
            throw PipelineError.notAnImage
        }

        let target = targetPixelSize(for: sourcePixelSize)
        let needsResize = target != sourcePixelSize

        // Always re-encode to JPEG. NSImage initializers accept many
        // formats (HEIC, PNG, GIF, TIFF, BMP) but we standardize on
        // one wire format so the receiver doesn't need a format zoo.
        let bitmap: NSBitmapImageRep
        if needsResize {
            bitmap = try resampleToBitmap(image: image, targetPixelSize: target)
        } else {
            bitmap = try directBitmap(image: image)
        }

        guard let jpegData = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: Self.jpegQuality]
        ) else {
            throw PipelineError.encodeFailed
        }

        let outWidth = bitmap.pixelsWide
        let outHeight = bitmap.pixelsHigh
        Self.logger.debug(
            "prepared image <\(sourcePixelSize.width, privacy: .public)x\(sourcePixelSize.height, privacy: .public)> -> <\(outWidth, privacy: .public)x\(outHeight, privacy: .public)>, jpeg <\(jpegData.count, privacy: .public)> bytes"
        )

        return Prepared(
            bytes: jpegData,
            mime: "image/jpeg",
            width: outWidth,
            height: outHeight
        )
    }

    // MARK: - Internals

    private func prepareGIF(rawData: Data, image: NSImage) throws -> Prepared {
        let size = pixelSize(of: image)
        guard size.width > 0, size.height > 0 else {
            throw PipelineError.notAnImage
        }
        if rawData.count > 10 * 1024 * 1024 {
            Self.logger.warning("gif is large: <\(rawData.count, privacy: .public)> bytes")
        }
        Self.logger.debug("prepared gif <\(Int(size.width), privacy: .public)x\(Int(size.height), privacy: .public)>, <\(rawData.count, privacy: .public)> bytes")
        return Prepared(bytes: rawData, mime: "image/gif", width: Int(size.width), height: Int(size.height))
    }

    /// Largest pixel dimensions across all bitmap reps the NSImage
    /// carries. NSImage caches multiple resolutions for retina; we
    /// always want the densest one.
    private func pixelSize(of image: NSImage) -> CGSize {
        var bestWidth = 0
        var bestHeight = 0
        for rep in image.representations {
            if rep.pixelsWide > bestWidth || rep.pixelsHigh > bestHeight {
                bestWidth = rep.pixelsWide
                bestHeight = rep.pixelsHigh
            }
        }
        if bestWidth > 0 && bestHeight > 0 {
            return CGSize(width: bestWidth, height: bestHeight)
        }
        // Fallback: no bitmap rep yet (e.g. PDF-backed). Trust the
        // image's logical size.
        return image.size
    }

    /// Compute the target pixel size after applying the longest-side
    /// cap. Returns the source size unchanged if it's already within
    /// budget — that's the pass-through path.
    private func targetPixelSize(for source: CGSize) -> CGSize {
        let longest = max(source.width, source.height)
        guard longest > CGFloat(Self.maxLongestSide) else { return source }
        let scale = CGFloat(Self.maxLongestSide) / longest
        return CGSize(
            width: max(1, (source.width * scale).rounded()),
            height: max(1, (source.height * scale).rounded())
        )
    }

    /// Render `image` into a fresh ARGB bitmap at the target pixel
    /// size. The Lanczos high-quality interpolation is what gives the
    /// downscale a clean look (vs. the box-filter default).
    private func resampleToBitmap(image: NSImage, targetPixelSize: CGSize) throws -> NSBitmapImageRep {
        let width = Int(targetPixelSize.width)
        let height = Int(targetPixelSize.height)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw PipelineError.bitmapRepresentationFailed
        }
        bitmap.size = CGSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw PipelineError.bitmapRepresentationFailed
        }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        image.draw(
            in: CGRect(x: 0, y: 0, width: width, height: height),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        ctx.flushGraphics()
        return bitmap
    }

    /// Pass-through path: get the densest existing bitmap rep, or
    /// rasterize via TIFF if the image is vector-backed.
    private func directBitmap(image: NSImage) throws -> NSBitmapImageRep {
        if let existing = image.representations.compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }) {
            return existing
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            throw PipelineError.bitmapRepresentationFailed
        }
        return bitmap
    }
}


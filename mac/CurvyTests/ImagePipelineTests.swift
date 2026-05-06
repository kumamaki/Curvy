import AppKit
import Foundation
import Testing
@testable import Curvy

/// Tests the resize-and-recompress preprocessing. We care about three
/// invariants:
/// - Anything larger than 2048px on the longest side gets capped.
/// - Aspect ratio is preserved across the resize.
/// - Output is always JPEG with the right MIME, regardless of input
///   format (so receivers can assume one wire format).
struct ImagePipelineTests {
    private let pipeline = ImagePipeline()

    /// Build an in-memory NSImage of the requested pixel size, filled
    /// with a solid color. Round-trips through TIFF then NSImage so
    /// the pipeline's `representations` lookup sees a real bitmap rep
    /// (matches what NSOpenPanel hands us).
    private func makeImage(width: Int, height: Int) -> NSImage {
        let rep = NSBitmapImageRep(
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
        )!
        rep.size = CGSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = ctx
        NSColor.systemOrange.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: width, height: height)).fill()
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: CGSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    @Test func capsLongestSideAt2048() throws {
        let oversized = makeImage(width: 4096, height: 3072)
        let prepared = try pipeline.prepare(image: oversized)
        #expect(max(prepared.width, prepared.height) <= 2048)
        // Aspect ratio preserved within rounding (4:3).
        let ratio = Double(prepared.width) / Double(prepared.height)
        #expect(abs(ratio - (4.0 / 3.0)) < 0.01)
    }

    @Test func passesThroughWhenWithinBudget() throws {
        let small = makeImage(width: 800, height: 600)
        let prepared = try pipeline.prepare(image: small)
        #expect(prepared.width == 800)
        #expect(prepared.height == 600)
    }

    @Test func outputIsAlwaysJPEG() throws {
        let small = makeImage(width: 100, height: 100)
        let prepared = try pipeline.prepare(image: small)
        #expect(prepared.mime == "image/jpeg")
        // JPEG SOI marker — first two bytes 0xFF, 0xD8.
        #expect(prepared.bytes.count >= 2)
        #expect(prepared.bytes[0] == 0xFF)
        #expect(prepared.bytes[1] == 0xD8)
    }

    @Test func handlesPortraitOrientation() throws {
        let portrait = makeImage(width: 1080, height: 4096)
        let prepared = try pipeline.prepare(image: portrait)
        #expect(max(prepared.width, prepared.height) <= 2048)
        #expect(prepared.height > prepared.width, "portrait should stay portrait after resize")
    }

    @Test func roundTripsThroughDataInit() throws {
        let original = makeImage(width: 2000, height: 1500)
        let prepared = try pipeline.prepare(image: original)
        // The output bytes should be loadable as an NSImage.
        let restored = try #require(NSImage(data: prepared.bytes))
        #expect(restored.size.width > 0)
        #expect(restored.size.height > 0)
    }

    @Test func preparedIsEquatable() throws {
        let a = ImagePipeline.Prepared(bytes: Data([0xFF, 0xD8]), mime: "image/jpeg", width: 10, height: 10)
        let b = ImagePipeline.Prepared(bytes: Data([0xFF, 0xD8]), mime: "image/jpeg", width: 10, height: 10)
        let c = ImagePipeline.Prepared(bytes: Data([0xFF, 0xD8]), mime: "image/jpeg", width: 11, height: 10)
        #expect(a == b)
        #expect(a != c)
    }
}

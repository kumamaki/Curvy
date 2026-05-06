import AppKit
import Foundation
import OSLog
import QuickLookUI

/// Drives the system `QLPreviewPanel` for a single image at a time.
/// `QLPreviewPanel` is a process-wide singleton `NSPanel`, so this is a
/// singleton too — adopting the same shape app uses.
///
/// `previewURL` is `nonisolated(unsafe)` because `QLPreviewPanel` calls
/// its data source on the main thread, which is exactly where `show(_:)`
/// writes to it. The unsafe annotation is the cheap way to teach Swift
/// 6 strict concurrency that this property is main-thread-only by
/// construction without dragging in actor isolation we don't need.
///
/// Curvy's image cache lives at
/// `~/Library/Caches/dev.kumamaki.Curvy/blobs/<uuid>.bin`. The `.bin`
/// extension is decorative (`NSImage` reads by magic number), but
/// `QLPreviewPanel` shows nicer chrome — title, "Open With…" — when the
/// URL it's handed has the right extension. `previewURL(for:mime:)`
/// hard-links the cached file to a temp path with a mime-derived
/// extension; hard-linking is O(1) and shares the inode, so we don't
/// duplicate bytes.
final class QuickLookManager: NSObject, QLPreviewPanelDataSource, @unchecked Sendable {
    static let shared = QuickLookManager()

    private let logger = Logger(subsystem: "dev.kumamaki.Curvy", category: "QuickLook")

    nonisolated(unsafe) private var previewURL: URL?

    @MainActor
    func show(_ url: URL) {
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in _: QLPreviewPanel!) -> Int { 1 }

    func previewPanel(_: QLPreviewPanel!, previewItemAt _: Int) -> (any QLPreviewItem)! {
        previewURL as NSURL?
    }

    /// Returns a URL safe to hand to `show(_:)`. If `cacheURL` already
    /// has a non-`bin` extension (e.g. the optimistic `pending-N.jpg`
    /// sidecar), it's returned as-is. Otherwise we hard-link the
    /// cached blob to `tmp/curvy-ql-<basename>.<ext>` and return that
    /// — same bytes, real extension. Falls back to a copy if hard
    /// linking fails (e.g. cross-volume).
    func previewURL(for cacheURL: URL, mime: String?) -> URL {
        let existingExt = cacheURL.pathExtension.lowercased()
        if !existingExt.isEmpty && existingExt != "bin" {
            return cacheURL
        }

        let ext = Self.preferredExtension(for: mime)
        let basename = cacheURL.deletingPathExtension().lastPathComponent
        let tempURL = FileManager.default.temporaryDirectory
            .appending(path: "curvy-ql-\(basename).\(ext)", directoryHint: .notDirectory)

        let fm = FileManager.default
        if fm.fileExists(atPath: tempURL.path) {
            return tempURL
        }
        do {
            try fm.linkItem(at: cacheURL, to: tempURL)
        } catch {
            do {
                try fm.copyItem(at: cacheURL, to: tempURL)
            } catch {
                logger.warning("couldn't stage QL preview at <\(tempURL.path, privacy: .public)>: \(error.localizedDescription, privacy: .public)")
                return cacheURL
            }
        }
        return tempURL
    }

    private static func preferredExtension(for mime: String?) -> String {
        switch mime?.lowercased() {
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/heic": "heic"
        case "image/heif": "heif"
        case "image/webp": "webp"
        case "image/tiff": "tiff"
        default: "jpg"
        }
    }
}


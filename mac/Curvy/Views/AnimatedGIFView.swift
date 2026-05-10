import AppKit
import SwiftUI

/// SwiftUI wrapper around `NSImageView` that plays animated GIFs.
/// SwiftUI's `Image(nsImage:)` flattens an NSImage to a single
/// bitmap rep — animation is lost. `NSImageView` with `animates = true`
/// drives the frame loop natively, no third-party library needed.
struct AnimatedGIFView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.image = image
    }
}

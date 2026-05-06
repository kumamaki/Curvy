#!/usr/bin/env swift
import AppKit

// Renders the Curvy DMG install-window background at @1x and @2x.
// Currently: solid white. Kept as a script (rather than a checked-in flat PNG)
// so size and color stay consistent with build-dmg.sh's --window-size.

let canvas = NSSize(width: 540, height: 380)
let backgroundColor = NSColor.white

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvas.width  * scale),
        pixelsHigh: Int(canvas.height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    )!
    rep.size = canvas

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: scale, y: scale)

    ctx.setFillColor(backgroundColor.cgColor)
    ctx.fill(CGRect(origin: .zero, size: canvas))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to path: String) throws {
    let data = rep.representation(using: .png, properties: [.interlaced: false])!
    try data.write(to: URL(fileURLWithPath: path))
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/dmg"
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

try write(render(scale: 1), to: "\(outDir)/background.png")
try write(render(scale: 2), to: "\(outDir)/background@2x.png")
print("wrote <\(outDir)/background.png> and <\(outDir)/background@2x.png>")


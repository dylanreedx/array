import AppKit

// Compose a macOS app icon from a square logo SVG:
// 1024 canvas, 824x824 rounded-rect tile centered (Apple Big Sur+ grid),
// corner radius 185.4/824 of the tile, transparent margins.

let args = CommandLine.arguments
guard args.count == 3 else {
    fputs("usage: make-icon.swift <logo.svg> <output.iconset>\n", stderr)
    exit(2)
}
let svgURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
guard let logo = NSImage(contentsOf: svgURL) else {
    fputs("cannot read \(svgURL.path)\n", stderr)
    exit(1)
}
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(_ pixels: Int, _ name: String) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fputs("rep fail \(pixels)\n", stderr); exit(1) }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels)
    let tile = s * 824.0 / 1024.0
    let margin = (s - tile) / 2.0
    let radius = tile * 185.4 / 824.0
    let tileRect = NSRect(x: margin, y: margin, width: tile, height: tile)
    let clip = NSBezierPath(roundedRect: tileRect, xRadius: radius, yRadius: radius)
    clip.addClip()
    // The source logo pads the mark heavily (A spans ~33% of the canvas width,
    // centered at (0.5, 0.474) in bottom-left fractions). Scale it up so the
    // mark reads at icon size; the tile clip crops the enlarged background.
    let scale: CGFloat = 1.67
    let drawSide = tile * scale
    let originX = tileRect.midX - 0.5 * drawSide
    let originY = tileRect.midY - 0.474 * drawSide
    let drawRect = NSRect(x: originX, y: originY, width: drawSide, height: drawSide)
    logo.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fputs("png fail \(pixels)\n", stderr); exit(1)
    }
    try! png.write(to: outDir.appendingPathComponent(name))
}

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in sizes { render(px, name) }
print("iconset written to \(outDir.path)")

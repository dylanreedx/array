import AppKit

@main
struct CursorContrastCheck {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func ns(_ value: ChipColor) -> NSColor {
            NSColor(srgbRed: value.r, green: value.g, blue: value.b, alpha: 1)
        }
        for theme in TokenTheme.allCases {
            let surface = ns(SurfaceToken.overlay.color.resolved(for: theme))
            let ink = ns(TextToken.textPrimary.color.resolved(for: theme))
            let accent = ns(AccentToken.accentWorking.color.resolved(for: theme))
            func render(_ backdrop: Int) -> NSBitmapImageRep {
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 100,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
                context.translateBy(x: 0, y: 100); context.scaleBy(x: 1, y: -1)
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                let bg: NSColor = backdrop == 0 ? .white : backdrop == 1 ? .black : accent
                bg.setFill(); NSRect(x: 0, y: 0, width: 320, height: 100).fill()
                if backdrop == 3 {
                    for x in stride(from: 0, to: 320, by: 5) {
                        (x % 10 == 0 ? NSColor.white : NSColor.black).setFill()
                        NSRect(x: x, y: 0, width: 5, height: 100).fill()
                    }
                }
                SharedCursorDrawing.draw(at: .init(x: 40, y: 40), name: "Sam · Collaborator",
                    colour: accent, surface: surface, ink: ink, font: .systemFont(ofSize: 11))
                NSGraphicsContext.restoreGraphicsState()
                return rep
            }
            let images = (0..<4).map(render)
            for (i, rep) in images.enumerated() {
                try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("cursor-\(theme.rawValue)-\(i).png"))
            }
            // A real opaque name backing must make a substantial region identical
            // over white and black content. Bare glyphs alone cannot satisfy this.
            var stable = 0
            var darkest = 1.0, lightest = 0.0
            for x in 65..<155 { for y in 35..<48 {
                let a = images[0].colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                let luma = WCAGContrast.relativeLuminance(ChipColor(r: a.redComponent, g: a.greenComponent, b: a.blueComponent))
                darkest = min(darkest, luma); lightest = max(lightest, luma)
                let b = images[1].colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                if abs(a.redComponent - b.redComponent) < 0.02 && abs(a.greenComponent - b.greenComponent) < 0.02 && abs(a.blueComponent - b.blueComponent) < 0.02 { stable += 1 }
            } }
            guard stable > 700 else { print("FAIL name backing absent: \(theme), stable pixels \(stable)"); exit(1) }
            let ratio = (lightest + 0.05) / (darkest + 0.05)
            guard ratio >= 4.5 else { print("FAIL rendered text contrast \(theme): \(ratio)"); exit(1) }
            // The outline must survive even when the arrow fill matches content.
            var edge = 0
            for x in 37..<60 { for y in 37..<64 {
                let pixel = images[2].colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                let bg = accent.usingColorSpace(.sRGB)!
                if abs(pixel.redComponent-bg.redComponent) + abs(pixel.greenComponent-bg.greenComponent) + abs(pixel.blueComponent-bg.blueComponent) > 0.3 { edge += 1 }
            } }
            guard edge > 30 else { print("FAIL cursor edge absent: \(theme), pixels \(edge)"); exit(1) }
            print("PASS cursor contrast \(theme): opaque label \(stable) pixels; same-colour arrow edge \(edge) pixels")
        }
    }
}

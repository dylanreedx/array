import AppKit

/// `--symbol-raster-cache-check`: `SymbolRasterCache.draw` lands on exactly the
/// pixels `NSImage.draw` does, at the fractional device scales a zoom passes
/// through, in flipped and unflipped contexts, light and dark; and a repeated
/// draw at one size is a cache hit that skips AppKit's representation lookup.
///
/// RED on a binary without the cache (or with `CONTINUUM_SYMBOL_RASTER_CACHE=0`):
/// no draw is ever a hit.
@MainActor
enum SymbolRasterCacheChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func run() throws {
        SymbolRasterCache.qaReset()
        // Camera zoom × a 2x display: what a pinch from 0.35 to 1.4 passes through,
        // including scales that put symbol edges on fractional pixels.
        let scales: [CGFloat] = [0.7, 0.83, 0.947, 1.226, 1.5, 2.0, 2.37, 2.8]
        let rects = [CGRect(x: 3, y: 5, width: 13, height: 13),
                     CGRect(x: 7.25, y: 2.6, width: 11.5, height: 12.3)]
        let images = [
            AgentTranscriptCanvasView.symbol("terminal", pointSize: 13, color: .systemTeal),
            AgentTranscriptCanvasView.symbol("checkmark.circle.fill", pointSize: 11, color: .labelColor),
            NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil),
        ].compactMap { $0 }
        guard images.count == 3 else { throw Failure(description: "could not make the test symbols") }
        var worst = 0
        var compared = 0
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            guard let appearance = NSAppearance(named: appearanceName) else { continue }
            for image in images {
                for scale in scales {
                    for rect in rects {
                        for flipped in [true, false] {
                            func render(_ cached: Bool) -> [UInt8] {
                                Self.render(scale: scale, flipped: flipped, appearance: appearance) {
                                    if cached {
                                        SymbolRasterCache.draw(image, in: rect)
                                    } else {
                                        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                                                   respectFlipped: true, hints: nil)
                                    }
                                }
                            }
                            let direct = render(false)
                            let miss = render(true)
                            let hit = render(true)
                            for (a, b) in [(direct, miss), (direct, hit)] {
                                for index in a.indices { worst = max(worst, abs(Int(a[index]) - Int(b[index]))) }
                            }
                            compared += 1
                            if worst > 0 {
                                throw Failure(description: "cached symbol differs from NSImage.draw by \(worst) "
                                    + "(appearance \(appearanceName.rawValue), scale \(scale), rect \(rect), flipped \(flipped))")
                            }
                        }
                    }
                }
            }
        }
        print("[symbol-raster-cache] \(compared) cases pixel-identical; hits \(SymbolRasterCache.qaHits), misses \(SymbolRasterCache.qaMisses)")
        guard SymbolRasterCache.qaHits >= compared, SymbolRasterCache.qaMisses <= compared else {
            throw Failure(description: "a second draw at the same size must be a cache hit "
                + "(hits \(SymbolRasterCache.qaHits), misses \(SymbolRasterCache.qaMisses), cases \(compared))")
        }

        // Light and dark of one palette symbol are different pixels: the cache must
        // not hand one appearance's bitmap to the other.
        let dynamic = images[1]
        let light = render(scale: 2, flipped: true, appearance: NSAppearance(named: .aqua)!) {
            SymbolRasterCache.draw(dynamic, in: rects[0])
        }
        let dark = render(scale: 2, flipped: true, appearance: NSAppearance(named: .darkAqua)!) {
            SymbolRasterCache.draw(dynamic, in: rects[0])
        }
        let directDark = render(scale: 2, flipped: true, appearance: NSAppearance(named: .darkAqua)!) {
            dynamic.draw(in: rects[0], from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        guard dark == directDark else { throw Failure(description: "dark appearance reused the light bitmap") }
        print("[symbol-raster-cache] light/dark differ: \(light != dark)")

        // The point of it: 400 draws of one symbol at one size.
        SymbolRasterCache.qaReset()
        func time(_ cached: Bool) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = render(scale: 1.226, flipped: true, appearance: NSAppearance(named: .aqua)!) {
                for index in 0..<400 {
                    let rect = CGRect(x: CGFloat(index % 20) * 14, y: CGFloat(index / 20) * 14, width: 13, height: 13)
                    if cached { SymbolRasterCache.draw(images[0], in: rect) } else {
                        images[0].draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                                       respectFlipped: true, hints: nil)
                    }
                }
            }
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        }
        let directMs = time(false), cachedMs = time(true)
        print(String(format: "[symbol-raster-cache] 400 draws: NSImage.draw %.2f ms, cache %.2f ms (hits %d, misses %d)",
                     directMs, cachedMs, SymbolRasterCache.qaHits, SymbolRasterCache.qaMisses))
        guard SymbolRasterCache.qaHits >= 399 else {
            throw Failure(description: "400 draws at one size made \(SymbolRasterCache.qaHits) cache hits, expected 399")
        }
    }

    /// A 300×300 pt canvas at `scale` device pixels per point, drawn the way a
    /// layer-backed view draws: an NSGraphicsContext of the given flippedness.
    private static func render(scale: CGFloat, flipped: Bool, appearance: NSAppearance,
                               _ body: () -> Void) -> [UInt8] {
        let pixels = Int((300 * scale).rounded(.up))
        var data = [UInt8](repeating: 0, count: pixels * pixels * 4)
        data.withUnsafeMutableBytes { buffer in
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let context = CGContext(data: buffer.baseAddress, width: pixels, height: pixels, bitsPerComponent: 8,
                                    bytesPerRow: pixels * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            if flipped {
                context.translateBy(x: 0, y: CGFloat(pixels))
                context.scaleBy(x: scale, y: -scale)
            } else {
                context.scaleBy(x: scale, y: scale)
            }
            let graphics = NSGraphicsContext(cgContext: context, flipped: flipped)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            appearance.performAsCurrentDrawingAppearance(body)
            NSGraphicsContext.restoreGraphicsState()
        }
        return data
    }
}

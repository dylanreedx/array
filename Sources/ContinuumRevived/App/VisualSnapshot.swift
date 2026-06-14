import AppKit

/// Pixel-content metrics for a rendered bitmap so self-checks can assert a
/// snapshot is NOT blank / uniform / zero-sized — the "grey screen" class of
/// regression — instead of only checking that PNG bytes exist. A view can
/// render to a perfectly valid, perfectly grey PNG; `bytes > 0` passes over it.
///
/// This is the Tier-1 visual gate from the verification doctrine (docs/26):
/// zero-maintenance, no committed baselines, catches gross render failures
/// (zero-sized overlays, all-one-color fills). Tier-2 baseline diffing layers
/// on later. Only valid for AppKit-drawn chrome — WKWebView / Ghostty content
/// (GPU/Metal) does not composite through `cacheDisplay`, so never snapshot
/// live web/terminal pixels.
enum VisualSnapshot {
    struct Metrics {
        let width: Int
        let height: Int
        let distinctSampledColors: Int

        /// True when the render is zero-sized or a single flat color — i.e. a
        /// user would see a blank/grey rectangle.
        var isBlank: Bool { width <= 0 || height <= 0 || distinctSampledColors <= 1 }
    }

    /// Samples a grid of pixels (channels quantized to 5 bits to absorb
    /// antialiasing noise) and counts distinct colors. A uniform/blank render
    /// yields 1; real chrome (headers, borders, text) yields many. The grid is
    /// capped to ~64×64 samples so cost is bounded regardless of pixel size.
    static func metrics(of rep: NSBitmapImageRep) -> Metrics {
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        guard w > 0, h > 0 else { return Metrics(width: w, height: h, distinctSampledColors: 0) }
        let step = max(4, max(w, h) / 64)
        var seen = Set<Int>()
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    let r = Int((color.redComponent * 31).rounded())
                    let g = Int((color.greenComponent * 31).rounded())
                    let b = Int((color.blueComponent * 31).rounded())
                    seen.insert((r << 10) | (g << 5) | b)
                }
                x += step
            }
            y += step
        }
        return Metrics(width: w, height: h, distinctSampledColors: seen.count)
    }
}

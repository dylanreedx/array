import AppKit

/// AppKit's own bitmap of a drawn image, kept for the next draw at the same
/// device size.
///
/// `NSImage.draw(in:)` on an SF Symbol does two things on every call: it looks
/// up the best representation (an LRU and CoreUI glyph queries), then has that
/// representation make a `CGImage` for the proposed rect at the device scale and
/// draws it. A zoom redraws every visible tile's transcript and resting chrome
/// at each camera step, and both draw the same few symbols many times over, so
/// in a pure zoom those two halves were ~7% of the main thread.
///
/// This keeps the `CGImage` AppKit made, keyed by everything it depends on: the
/// image object, the destination size in device pixels to a thousandth of a
/// pixel, and the drawing appearance (a template or palette symbol resolves its
/// colours against it). Any other size is a miss that asks AppKit again, so a
/// symbol is never stretched to a size it was not made for: an earlier version
/// bucketed the scale to quarters and left icons resampled — soft — at rest.
///
/// Witness: `--symbol-raster-cache-check` (pixel identity against
/// `NSImage.draw` at fractional zooms; repeated draws hit).
/// QA: `CONTINUUM_SYMBOL_RASTER_CACHE=0` draws through `NSImage.draw` as before.
@MainActor
enum SymbolRasterCache {
    static var isEnabled = ProcessInfo.processInfo.environment["CONTINUUM_SYMBOL_RASTER_CACHE"] != "0"

    private struct Key: Hashable {
        let image: ObjectIdentifier
        let milliPixelWidth: Int
        let milliPixelHeight: Int
        let appearance: String
    }

    private struct Entry {
        /// Held so the image's ObjectIdentifier cannot be reused while keyed.
        let source: NSImage
        let bitmap: CGImage
        /// Where AppKit placed the bitmap, as an inset of the destination rect
        /// (`cgImage(forProposedRect:)` may adjust the rect it was given).
        let insets: NSEdgeInsets
    }

    private static var entries: [Key: Entry] = [:]
    /// A gesture walks through hundreds of sizes; dropping everything at the
    /// cap is cheaper than tracking recency, and a miss costs only what every
    /// draw cost before.
    private static let limit = 1_024

    private(set) static var qaHits = 0
    private(set) static var qaMisses = 0
    /// Nanoseconds inside `draw`, cached or not, so one binary measures both arms.
    private(set) static var qaDrawNanos: UInt64 = 0
    private(set) static var qaDraws = 0
    static func qaReset() { qaHits = 0; qaMisses = 0; qaDrawNanos = 0; qaDraws = 0; entries.removeAll() }
    static func qaResetCounters() { qaHits = 0; qaMisses = 0; qaDrawNanos = 0; qaDraws = 0 }

    /// Draws `image` into `rect` of the current graphics context exactly as
    /// `image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
    /// respectFlipped: true, hints: nil)` would.
    static func draw(_ image: NSImage, in rect: CGRect) {
        let start = DispatchTime.now().uptimeNanoseconds
        defer { qaDraws += 1; qaDrawNanos &+= DispatchTime.now().uptimeNanoseconds &- start }
        guard isEnabled, let graphics = NSGraphicsContext.current else {
            return direct(image, in: rect)
        }
        let context = graphics.cgContext
        let device = context.userSpaceToDeviceSpaceTransform
        // Axis-aligned drawing only; anything rotated or skewed goes to AppKit.
        guard device.b == 0, device.c == 0, rect.width > 0, rect.height > 0 else {
            return direct(image, in: rect)
        }
        let key = Key(image: ObjectIdentifier(image),
                      milliPixelWidth: Int((rect.width * abs(device.a) * 1_000).rounded()),
                      milliPixelHeight: Int((rect.height * abs(device.d) * 1_000).rounded()),
                      appearance: NSAppearance.currentDrawing().name.rawValue)
        let entry: Entry
        if let hit = entries[key] {
            qaHits += 1
            entry = hit
        } else {
            qaMisses += 1
            var proposed = rect
            guard let bitmap = image.cgImage(forProposedRect: &proposed, context: graphics, hints: nil) else {
                return direct(image, in: rect)
            }
            if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
            entry = Entry(source: image, bitmap: bitmap,
                          insets: NSEdgeInsets(top: proposed.minY - rect.minY, left: proposed.minX - rect.minX,
                                               bottom: rect.maxY - proposed.maxY, right: rect.maxX - proposed.maxX))
            entries[key] = entry
        }
        let target = CGRect(x: rect.minX + entry.insets.left, y: rect.minY + entry.insets.top,
                            width: rect.width - entry.insets.left - entry.insets.right,
                            height: rect.height - entry.insets.top - entry.insets.bottom)
        context.saveGState()
        if graphics.isFlipped {
            // respectFlipped: the bitmap's top row goes to the rect's top edge.
            context.translateBy(x: 0, y: target.maxY + target.minY)
            context.scaleBy(x: 1, y: -1)
        }
        context.draw(entry.bitmap, in: target)
        context.restoreGState()
    }

    private static func direct(_ image: NSImage, in rect: CGRect) {
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

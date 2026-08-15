import AppKit

/// Shared, template-preserving bitmap images for SF Symbols installed below the
/// canvas world plane.
///
/// An `NSSymbolImageRep` is a vector recipe. When the plane's effective backing
/// scale changes during zoom, AppKit asks every resident symbol image view to
/// rasterize that recipe again. These images instead contain one explicit bitmap
/// representation: Core Animation can scale the pixels with the rest of the
/// plane, while `isTemplate` leaves the owning view's live `contentTintColor` in
/// charge of appearance.
@MainActor
enum CanvasSymbolImage {
    private struct Key: Hashable {
        let name: String
        let pointSize: CGFloat?
        let weight: CGFloat?
    }

    private static let rasterScale: CGFloat = 2
    private static var cache: [Key: NSImage] = [:]

    static func image(
        named name: String,
        pointSize: CGFloat? = nil,
        weight: NSFont.Weight? = nil
    ) -> NSImage? {
        let key = Key(name: name, pointSize: pointSize, weight: weight?.rawValue)
        if let cached = cache[key] { return cached }

        guard var source = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        if let pointSize {
            let configuration = NSImage.SymbolConfiguration(
                pointSize: pointSize,
                weight: weight ?? .regular
            )
            guard let configured = source.withSymbolConfiguration(configuration) else { return nil }
            source = configured
        }

        let logicalSize = source.size
        guard logicalSize.width > 0, logicalSize.height > 0 else { return nil }
        let pixelsWide = max(1, Int((logicalSize.width * rasterScale).rounded(.up)))
        let pixelsHigh = max(1, Int((logicalSize.height * rasterScale).rounded(.up)))
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        representation.size = logicalSize
        guard let context = NSGraphicsContext(bitmapImageRep: representation) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        source.draw(
            in: NSRect(origin: .zero, size: logicalSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: logicalSize)
        image.addRepresentation(representation)
        image.isTemplate = true
        cache[key] = image
        return image
    }

    static func owns(_ image: NSImage?) -> Bool {
        guard let image else { return false }
        return cache.values.contains { $0 === image }
    }

    /// Direct witness for the two properties the appearance render cannot infer
    /// from pixels alone: the vector recipe is gone, and the cached bitmap remains
    /// a template that each owning view may tint after an appearance flip.
    static func qaBitmapContractHolds() -> Bool {
        guard let first = image(named: "house", pointSize: 11, weight: .semibold),
              let second = image(named: "house", pointSize: 11, weight: .semibold) else {
            return false
        }
        guard first === second,
              first.isTemplate,
              first.representations.count == 1,
              let representation = first.representations.first as? NSBitmapImageRep,
              representation.pixelsWide == Int((first.size.width * rasterScale).rounded(.up)),
              representation.pixelsHigh == Int((first.size.height * rasterScale).rounded(.up)),
              let bytes = representation.bitmapData else {
            return false
        }
        let byteCount = representation.bytesPerRow * representation.pixelsHigh
        return (0..<byteCount).contains { bytes[$0] != 0 }
    }
}

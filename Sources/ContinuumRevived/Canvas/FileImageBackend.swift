import Foundation
import CoreGraphics
import ImageIO
import ContinuumRevivedCore

/// Immutable, eagerly decoded pixels from one retained, authorized file revision.
/// The system decoder is never retained by a view or invoked during layout.
final class FileImageDocument: @unchecked Sendable {
    let image: CGImage
    let pixelWidth: Int
    let pixelHeight: Int
    let pageCount: Int
    let typeIdentifier: String
    let decodedBytes: Int
    let isDownsampled: Bool
    let isAnimated: Bool
    let snapshot: SecureFileSnapshot
    var statusText: String {
        var parts = ["\(pixelWidth) × \(pixelHeight) pixels"]
        if pageCount > 1 { parts.append(isAnimated ? "First frame of \(pageCount) · animation paused" : "Page 1 of \(pageCount)") }
        if isDownsampled { parts.insert("Reduced preview · \(image.width) × \(image.height)", at: 0) }
        parts.append(typeIdentifier)
        return parts.joined(separator: " · ")
    }
    init(image: CGImage, pixelWidth: Int, pixelHeight: Int, pageCount: Int,
         typeIdentifier: String, isAnimated: Bool, snapshot: SecureFileSnapshot) {
        self.image = image; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.pageCount = pageCount; self.typeIdentifier = typeIdentifier
        self.decodedBytes = image.bytesPerRow * image.height
        self.isDownsampled = image.width < pixelWidth || image.height < pixelHeight
        self.isAnimated = isAnimated; self.snapshot = snapshot
    }
}

enum FileImageBackend {
    static let compressedByteLimit = 64 * 1_024 * 1_024
    static let decodedByteLimit = 64 * 1_024 * 1_024
    static let maximumDimension = 4_096
    enum LoadError: Error, LocalizedError {
        case tooLarge, unsupported, invalidDimensions, decodeFailed
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "This image exceeds the bounded preview limit. Open it externally to inspect it."
            case .unsupported: return "This image format is not supported by this Mac’s image decoder."
            case .invalidDimensions: return "The image has invalid or unsupported pixel dimensions."
            case .decodeFailed: return "The image could not be decoded. It may be damaged."
            }
        }
    }
    static func load(snapshot: SecureFileSnapshot) throws -> FileImageDocument {
        try Task.checkCancellation()
        guard snapshot.byteCount <= compressedByteLimit else { throw LoadError.tooLarge }
        guard let source = CGImageSourceCreateWithURL(snapshot.url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let detectedType = CGImageSourceGetType(source) else { throw LoadError.unsupported }
        let type = detectedType as String
        let supported = CGImageSourceCopyTypeIdentifiers() as! [String]
        guard supported.contains(type), type != "public.svg-image" else { throw LoadError.unsupported }
        let count = CGImageSourceGetCount(source)
        guard count > 0, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw LoadError.invalidDimensions }
        let w = width.doubleValue, h = height.doubleValue
        // Validate before integer conversion and before asking ImageIO to decode.
        guard w.isFinite, h.isFinite, w >= 1, h >= 1, w <= 1_000_000, h <= 1_000_000,
              w.rounded() == w, h.rounded() == h, w * h <= 100_000_000 else { throw LoadError.invalidDimensions }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapsAxes = (5...8).contains(orientation)
        try Task.checkCancellation()
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
            kCGImageSourceShouldCacheImmediately: true, kCGImageSourceShouldAllowFloat: false]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw LoadError.decodeFailed }
        try Task.checkCancellation()
        guard image.width <= maximumDimension, image.height <= maximumDimension,
              image.bytesPerRow <= decodedByteLimit / max(1, image.height) else { throw LoadError.tooLarge }
        let animated = count > 1 && ["com.compuserve.gif", "public.png", "org.webmproject.webp"].contains(type)
        return FileImageDocument(image: image, pixelWidth: Int(swapsAxes ? h : w),
            pixelHeight: Int(swapsAxes ? w : h), pageCount: count, typeIdentifier: type,
            isAnimated: animated, snapshot: snapshot)
    }
}

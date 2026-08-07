import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ComposerImageThumbnail: Equatable, Sendable {
    var pngData: Data
    var pixelWidth: Int
    var pixelHeight: Int
}

protocol ComposerImageThumbnailLoading: AnyObject, Sendable {
    func thumbnail(for fileURL: URL, maxPixelSize: Int) async throws -> ComposerImageThumbnail
}

actor ComposerImageIOThumbnailPipeline: ComposerImageThumbnailLoading {
    struct Configuration: Sendable {
        var maximumEntries: Int
        var maximumBytes: Int

        init(maximumEntries: Int = 96, maximumBytes: Int = 24 * 1024 * 1024) {
            self.maximumEntries = max(1, maximumEntries)
            self.maximumBytes = max(256 * 1024, maximumBytes)
        }
    }

    enum ThumbnailError: Error, Equatable, CustomStringConvertible {
        case unsupportedSource
        case imageSourceCreationFailed
        case thumbnailCreationFailed
        case pngEncodingFailed

        var description: String {
            switch self {
            case .unsupportedSource: return "unsupported thumbnail source"
            case .imageSourceCreationFailed: return "failed to create ImageIO source"
            case .thumbnailCreationFailed: return "failed to downsample image thumbnail"
            case .pngEncodingFailed: return "failed to encode thumbnail"
            }
        }
    }

    private struct CacheKey: Hashable, Sendable {
        var path: String
        var fileSize: Int?
        var modificationStamp: TimeInterval?
        var maxPixelSize: Int
    }

    private struct CacheEntry: Sendable {
        var thumbnail: ComposerImageThumbnail
        var byteCount: Int
        var lastAccess: UInt64
    }

    private let configuration: Configuration
    private var cache: [CacheKey: CacheEntry] = [:]
    private var clock: UInt64 = 0
    private var totalBytes = 0

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    func thumbnail(for fileURL: URL, maxPixelSize: Int) async throws -> ComposerImageThumbnail {
        guard fileURL.isFileURL, maxPixelSize > 0 else { throw ThumbnailError.unsupportedSource }
        try Task.checkCancellation()
        let key = Self.cacheKey(for: fileURL, maxPixelSize: maxPixelSize)
        if let cached = cache[key] {
            clock &+= 1
            cache[key]?.lastAccess = clock
            return cached.thumbnail
        }

        let boundedPixelSize = min(max(maxPixelSize, 24), 512)
        let thumbnail = try await Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let result = try Self.renderThumbnail(fileURL: fileURL, maxPixelSize: boundedPixelSize)
            try Task.checkCancellation()
            return result
        }.value
        try Task.checkCancellation()
        insert(thumbnail, for: key)
        return thumbnail
    }

    func cachedEntryCount() -> Int { cache.count }

    private func insert(_ thumbnail: ComposerImageThumbnail, for key: CacheKey) {
        clock &+= 1
        let bytes = thumbnail.pngData.count
        if let existing = cache[key] {
            totalBytes -= existing.byteCount
        }
        cache[key] = CacheEntry(thumbnail: thumbnail, byteCount: bytes, lastAccess: clock)
        totalBytes += bytes
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        while cache.count > configuration.maximumEntries || totalBytes > configuration.maximumBytes {
            guard let oldest = cache.min(by: { $0.value.lastAccess < $1.value.lastAccess }) else { break }
            totalBytes -= oldest.value.byteCount
            cache.removeValue(forKey: oldest.key)
        }
    }

    private static func cacheKey(for fileURL: URL, maxPixelSize: Int) -> CacheKey {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return CacheKey(
            path: fileURL.standardizedFileURL.path,
            fileSize: values?.fileSize,
            modificationStamp: values?.contentModificationDate?.timeIntervalSinceReferenceDate,
            maxPixelSize: maxPixelSize
        )
    }

    private static func renderThumbnail(fileURL: URL, maxPixelSize: Int) throws -> ComposerImageThumbnail {
        let sourceOptions = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions) else {
            throw ThumbnailError.imageSourceCreationFailed
        }
        guard let type = CGImageSourceGetType(source) as String?,
              ComposerImagePasteboardDecoder.acceptedContentTypes.contains(type)
        else { throw ThumbnailError.unsupportedSource }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw ThumbnailError.thumbnailCreationFailed
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw ThumbnailError.pngEncodingFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ThumbnailError.pngEncodingFailed }
        return ComposerImageThumbnail(
            pngData: data as Data,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }
}

import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ComposerImageThumbnail: Equatable, Sendable {
    var pngData: Data
    var pixelWidth: Int
    var pixelHeight: Int

    var decodedByteCost: Int {
        let pixels = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        guard !pixels.overflow else { return Int.max }
        let bytes = pixels.partialValue.multipliedReportingOverflow(by: 4)
        return bytes.overflow ? Int.max : bytes.partialValue
    }
}

protocol ComposerImageThumbnailLoading: AnyObject, Sendable {
    func thumbnail(for fileURL: URL, maxPixelSize: Int) async throws -> ComposerImageThumbnail
}

actor ComposerImageIOThumbnailPipeline: ComposerImageThumbnailLoading {
    struct Configuration: Sendable {
        var maximumEntries: Int
        var maximumDecodedBytes: Int
        var minimumPixelSize: Int
        var maximumPixelSize: Int
        var decodeStartDelayNanosecondsForChecks: UInt64

        init(
            maximumEntries: Int = 96,
            maximumBytes: Int = 24 * 1024 * 1024,
            minimumPixelSize: Int = 24,
            maximumPixelSize: Int = 1024,
            decodeStartDelayNanosecondsForChecks: UInt64 = 0
        ) {
            self.maximumEntries = max(1, maximumEntries)
            maximumDecodedBytes = max(256 * 1024, maximumBytes)
            self.minimumPixelSize = max(1, minimumPixelSize)
            self.maximumPixelSize = max(self.minimumPixelSize, maximumPixelSize)
            self.decodeStartDelayNanosecondsForChecks = decodeStartDelayNanosecondsForChecks
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
        var targetPixelSize: Int
    }

    private struct CacheEntry: Sendable {
        var thumbnail: ComposerImageThumbnail
        var decodedByteCost: Int
        var lastAccess: UInt64
    }

    private struct InFlightRequest: Sendable {
        var requestID: UUID
        var task: Task<ComposerImageThumbnail, Error>
        var leases: Set<UUID>
    }

    private let configuration: Configuration
    private var cache: [CacheKey: CacheEntry] = [:]
    private var inFlight: [CacheKey: InFlightRequest] = [:]
    private var clock: UInt64 = 0
    private var totalDecodedByteCost = 0
    private var renderInvocationCount = 0
    private var cancelledRenderCount = 0

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    func thumbnail(for fileURL: URL, maxPixelSize: Int) async throws -> ComposerImageThumbnail {
        guard fileURL.isFileURL, maxPixelSize > 0 else { throw ThumbnailError.unsupportedSource }
        try Task.checkCancellation()
        let targetPixelSize = canonicalPixelSize(maxPixelSize)
        let key = Self.cacheKey(for: fileURL, targetPixelSize: targetPixelSize)
        if let cached = cache[key] {
            clock &+= 1
            cache[key]?.lastAccess = clock
            return cached.thumbnail
        }

        let leaseID = UUID()
        let request = beginRequest(for: key, fileURL: fileURL, targetPixelSize: targetPixelSize, leaseID: leaseID)
        return try await withTaskCancellationHandler {
            do {
                let thumbnail = try await request.task.value
                try Task.checkCancellation()
                finishRequest(for: key, requestID: request.id, leaseID: leaseID, result: .success(thumbnail))
                return thumbnail
            } catch {
                finishRequest(for: key, requestID: request.id, leaseID: leaseID, result: .failure(error))
                throw error
            }
        } onCancel: {
            Task { await self.cancelLease(for: key, requestID: request.id, leaseID: leaseID) }
        }
    }

    func cachedEntryCount() -> Int { cache.count }
    func cachedDecodedByteCost() -> Int { totalDecodedByteCost }
    func qaRenderInvocationCount() -> Int { renderInvocationCount }
    func qaCancelledRenderCount() -> Int { cancelledRenderCount }
    func qaInFlightCount() -> Int { inFlight.count }
    func qaCanonicalPixelSize(for requestedSize: Int) -> Int { canonicalPixelSize(requestedSize) }

    private func canonicalPixelSize(_ requestedSize: Int) -> Int {
        min(max(requestedSize, configuration.minimumPixelSize), configuration.maximumPixelSize)
    }

    private func beginRequest(
        for key: CacheKey,
        fileURL: URL,
        targetPixelSize: Int,
        leaseID: UUID
    ) -> (id: UUID, task: Task<ComposerImageThumbnail, Error>) {
        if var request = inFlight[key] {
            request.leases.insert(leaseID)
            inFlight[key] = request
            return (request.requestID, request.task)
        }

        renderInvocationCount += 1
        let delay = configuration.decodeStartDelayNanosecondsForChecks
        let task = Task(priority: .utility) {
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            try Task.checkCancellation()
            let result = try Self.renderThumbnail(fileURL: fileURL, maxPixelSize: targetPixelSize)
            try Task.checkCancellation()
            return result
        }
        let requestID = UUID()
        inFlight[key] = InFlightRequest(requestID: requestID, task: task, leases: [leaseID])
        return (requestID, task)
    }

    private func finishRequest(
        for key: CacheKey,
        requestID: UUID,
        leaseID: UUID,
        result: Result<ComposerImageThumbnail, Error>
    ) {
        if var request = inFlight[key], request.requestID == requestID {
            request.leases.remove(leaseID)
            inFlight[key] = request
        }

        switch result {
        case .success(let thumbnail):
            if inFlight[key]?.requestID == requestID {
                inFlight[key] = nil
            }
            insert(thumbnail, for: key)
        case .failure(let error):
            if error is CancellationError { cancelledRenderCount += 1 }
            if inFlight[key]?.requestID == requestID {
                inFlight[key] = nil
            }
        }
    }

    private func cancelLease(for key: CacheKey, requestID: UUID, leaseID: UUID) {
        guard var request = inFlight[key], request.requestID == requestID else { return }
        request.leases.remove(leaseID)
        if request.leases.isEmpty {
            request.task.cancel()
            inFlight[key] = request
        } else {
            inFlight[key] = request
        }
    }

    private func insert(_ thumbnail: ComposerImageThumbnail, for key: CacheKey) {
        clock &+= 1
        let decodedByteCost = Self.decodedByteCost(for: thumbnail)
        if let existing = cache[key] {
            totalDecodedByteCost -= existing.decodedByteCost
        }
        cache[key] = CacheEntry(thumbnail: thumbnail, decodedByteCost: decodedByteCost, lastAccess: clock)
        totalDecodedByteCost += decodedByteCost
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        while cache.count > configuration.maximumEntries || totalDecodedByteCost > configuration.maximumDecodedBytes {
            guard let oldest = cache.min(by: { $0.value.lastAccess < $1.value.lastAccess }) else { break }
            totalDecodedByteCost -= oldest.value.decodedByteCost
            cache.removeValue(forKey: oldest.key)
        }
    }

    private static func cacheKey(for fileURL: URL, targetPixelSize: Int) -> CacheKey {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return CacheKey(
            path: fileURL.standardizedFileURL.path,
            fileSize: values?.fileSize,
            modificationStamp: values?.contentModificationDate?.timeIntervalSinceReferenceDate,
            targetPixelSize: targetPixelSize
        )
    }

    private static func decodedByteCost(for thumbnail: ComposerImageThumbnail) -> Int {
        let pixels = thumbnail.pixelWidth.multipliedReportingOverflow(by: thumbnail.pixelHeight)
        guard !pixels.overflow else { return Int.max }
        let bytes = pixels.partialValue.multipliedReportingOverflow(by: 4)
        return bytes.overflow ? Int.max : bytes.partialValue
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

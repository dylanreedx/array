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
        var decodeStageHooksForChecks: DecodeStageHooks

        init(
            maximumEntries: Int = 96,
            maximumBytes: Int = 24 * 1024 * 1024,
            minimumPixelSize: Int = 24,
            maximumPixelSize: Int = 1024,
            decodeStartDelayNanosecondsForChecks: UInt64 = 0,
            decodeStageHooksForChecks: DecodeStageHooks = .none
        ) {
            self.maximumEntries = max(1, maximumEntries)
            maximumDecodedBytes = max(256 * 1024, maximumBytes)
            self.minimumPixelSize = max(1, minimumPixelSize)
            self.maximumPixelSize = max(self.minimumPixelSize, maximumPixelSize)
            self.decodeStartDelayNanosecondsForChecks = decodeStartDelayNanosecondsForChecks
            self.decodeStageHooksForChecks = decodeStageHooksForChecks
        }
    }

    struct DecodeStageHooks: Sendable {
        static let none = DecodeStageHooks()

        var beforeSourceCreation: (@Sendable () async throws -> Void)?
        var afterSourceCreation: (@Sendable () async throws -> Void)?
        var beforeThumbnailDecode: (@Sendable () async throws -> Void)?
        var afterThumbnailDecode: (@Sendable () async throws -> Void)?
        var beforeEncoding: (@Sendable () async throws -> Void)?
        var afterEncoding: (@Sendable () async throws -> Void)?

        init(
            beforeSourceCreation: (@Sendable () async throws -> Void)? = nil,
            afterSourceCreation: (@Sendable () async throws -> Void)? = nil,
            beforeThumbnailDecode: (@Sendable () async throws -> Void)? = nil,
            afterThumbnailDecode: (@Sendable () async throws -> Void)? = nil,
            beforeEncoding: (@Sendable () async throws -> Void)? = nil,
            afterEncoding: (@Sendable () async throws -> Void)? = nil
        ) {
            self.beforeSourceCreation = beforeSourceCreation
            self.afterSourceCreation = afterSourceCreation
            self.beforeThumbnailDecode = beforeThumbnailDecode
            self.afterThumbnailDecode = afterThumbnailDecode
            self.beforeEncoding = beforeEncoding
            self.afterEncoding = afterEncoding
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
        var didCacheResult: Bool
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
                let thumbnail = try await awaitRequestValueOrCancellation(request.task)
                guard leaseIsActive(for: key, requestID: request.id, leaseID: leaseID) else {
                    throw CancellationError()
                }
                try Task.checkCancellation()
                finishRequest(for: key, requestID: request.id, leaseID: leaseID, result: .success(thumbnail))
                return thumbnail
            } catch {
                finishRequest(for: key, requestID: request.id, leaseID: leaseID, result: .failure(error))
                throw error
            }
        } onCancel: {
            Task.detached { await self.cancelLease(for: key, requestID: request.id, leaseID: leaseID) }
        }
    }

    nonisolated private func awaitRequestValueOrCancellation(
        _ task: Task<ComposerImageThumbnail, Error>
    ) async throws -> ComposerImageThumbnail {
        let awaiter = CancellationAwareThumbnailAwaiter()
        return try await awaiter.value(for: task)
    }

    func cachedEntryCount() -> Int { cache.count }
    func cachedDecodedByteCost() -> Int { totalDecodedByteCost }
    func qaRenderInvocationCount() -> Int { renderInvocationCount }
    func qaCancelledRenderCount() -> Int { cancelledRenderCount }
    func qaInFlightCount() -> Int { inFlight.count }
    func qaInFlightLeaseCount() -> Int { inFlight.values.reduce(0) { $0 + $1.leases.count } }
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
        let stageHooks = configuration.decodeStageHooksForChecks
        let task = Task.detached(priority: .utility) {
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            try Task.checkCancellation()
            let result = try await Self.renderThumbnail(
                fileURL: fileURL,
                maxPixelSize: targetPixelSize,
                stageHooks: stageHooks
            )
            try Task.checkCancellation()
            return result
        }
        let requestID = UUID()
        inFlight[key] = InFlightRequest(requestID: requestID, task: task, leases: [leaseID], didCacheResult: false)
        return (requestID, task)
    }

    private func leaseIsActive(for key: CacheKey, requestID: UUID, leaseID: UUID) -> Bool {
        guard let request = inFlight[key], request.requestID == requestID else { return false }
        return request.leases.contains(leaseID)
    }

    private func finishRequest(
        for key: CacheKey,
        requestID: UUID,
        leaseID: UUID,
        result: Result<ComposerImageThumbnail, Error>
    ) {
        guard var request = inFlight[key], request.requestID == requestID else {
            return
        }

        request.leases.remove(leaseID)
        switch result {
        case .success(let thumbnail):
            if !request.didCacheResult {
                request.didCacheResult = true
                insert(thumbnail, for: key)
            }
        case .failure(let error):
            if error is CancellationError { cancelledRenderCount += 1 }
        }

        if request.leases.isEmpty {
            inFlight[key] = nil
        } else {
            inFlight[key] = request
        }
    }

    private func cancelLease(for key: CacheKey, requestID: UUID, leaseID: UUID) {
        guard var request = inFlight[key], request.requestID == requestID else { return }
        request.leases.remove(leaseID)
        if request.leases.isEmpty {
            request.task.cancel()
            inFlight[key] = nil
            cancelledRenderCount += 1
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

    private static func renderThumbnail(
        fileURL: URL,
        maxPixelSize: Int,
        stageHooks: DecodeStageHooks
    ) async throws -> ComposerImageThumbnail {
        try Task.checkCancellation()
        try await stageHooks.beforeSourceCreation?()
        try Task.checkCancellation()

        let sourceOptions = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions) else {
            throw ThumbnailError.imageSourceCreationFailed
        }
        try Task.checkCancellation()
        try await stageHooks.afterSourceCreation?()
        try Task.checkCancellation()

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
        try await stageHooks.beforeThumbnailDecode?()
        try Task.checkCancellation()
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw ThumbnailError.thumbnailCreationFailed
        }
        try Task.checkCancellation()
        try await stageHooks.afterThumbnailDecode?()
        try Task.checkCancellation()

        try await stageHooks.beforeEncoding?()
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw ThumbnailError.pngEncodingFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ThumbnailError.pngEncodingFailed }
        try Task.checkCancellation()
        try await stageHooks.afterEncoding?()
        try Task.checkCancellation()

        return ComposerImageThumbnail(
            pngData: data as Data,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }
}

private final class CancellationAwareThumbnailAwaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ComposerImageThumbnail, Error>?
    private var didResume = false

    func value(for task: Task<ComposerImageThumbnail, Error>) async throws -> ComposerImageThumbnail {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if didResume {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                lock.unlock()

                Task.detached { [weak self] in
                    do {
                        let thumbnail = try await task.value
                        self?.resume(.success(thumbnail))
                    } catch {
                        self?.resume(.failure(error))
                    }
                }
            }
        } onCancel: {
            resume(.failure(CancellationError()))
        }
    }

    private func resume(_ result: Result<ComposerImageThumbnail, Error>) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

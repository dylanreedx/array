import AppKit
import ContinuumRevivedCore
import Foundation
import ImageIO

/// WS7 — bounded, off-main decode and cache for background images.
///
/// Three properties the canvas depends on, each of which has a counter so a
/// witness can prove it rather than assume it:
///
/// - **Nothing decodes at camera time.** A pan or a zoom does not change the
///   cache key (the image is SCREEN-fixed, so the target pixel size depends on
///   the viewport SIZE and the backing scale only), so a camera step is a cache
///   hit or nothing at all.
/// - **Decoding is off the main thread and downsampled.** ImageIO produces a
///   thumbnail at the viewport's bucketed pixel size, capped at
///   `maximumDecodePixelDimension`, so a 12,000 px photo costs the same as a
///   4,096 px one.
/// - **A stale completion can never win.** Every request carries a generation
///   token; a completion whose token is behind the newest request is dropped and
///   counted.
@MainActor
final class CanvasBackgroundImageCache {
    struct Key: Hashable {
        let assetID: CanvasBackgroundAssetID
        /// Content revision of the managed file — its size and mtime. Two
        /// different files can never share an id (the id IS the digest), but a
        /// file replaced in place, or restored after a corrupt read, must not be
        /// served from the entry that was decoded before.
        let revision: String
        let targetPixels: Int
        let mode: CanvasBackgroundImageMode
        let backingScale: Int
    }

    enum Outcome: Equatable {
        case ready(Key)
        case pending(Key)
        case failed(CanvasBackgroundAssetID)
    }

    struct Stats: Equatable {
        var decodeRequests = 0
        var decodeCompletions = 0
        var decodeFailures = 0
        var cacheHits = 0
        var cacheMisses = 0
        var staleCompletionDrops = 0
        var evictions = 0
    }

    /// Small on purpose: the live configuration needs one entry, and the only
    /// reason to keep more is a window mid-resize crossing buckets.
    static let maximumEntries = 4

    private(set) var stats = Stats()
    private var entries: [Key: CGImage] = [:]
    private var order: [Key] = []
    private var pending: Set<Key> = []
    private var generation: UInt64 = 0
    private var pendingCount = 0

    private let store: CanvasBackgroundAssetStore
    private let queue = DispatchQueue(label: "dev.arrayapp.canvas-background-decode", qos: .userInitiated)

    /// Called on the main thread when a decode lands (successfully or not).
    var onImageAvailable: ((Key) -> Void)?
    var onDecodeFailed: ((CanvasBackgroundAssetID) -> Void)?

    init(store: CanvasBackgroundAssetStore) {
        self.store = store
    }

    func resetStats() { stats = Stats(); qaIssuedRequests = [] }

    /// QA: every request issued since the last `resetStats`, with the generation
    /// token it carried. A witness needs these to land a SUPERSEDED completion
    /// LAST — which is the only ordering the token defends against, and the one
    /// the decode queue can never produce on its own because it is FIFO. A
    /// witness that merely waits for real decodes passes with the token check
    /// deleted; that is exactly what happened here.
    private(set) var qaIssuedRequests: [(key: Key, token: UInt64)] = []

    /// QA: deliver a completion by hand, through the real `complete` path.
    func qaLandCompletion(key: Key, token: UInt64, image: CGImage?) {
        pending.insert(key)
        pendingCount += 1
        complete(key: key, token: token, image: image)
    }
    var qaEntryCount: Int { entries.count }
    var qaPendingCount: Int { pendingCount }
    var qaGeneration: UInt64 { generation }

    func image(for key: Key) -> CGImage? { entries[key] }

    /// The revision component of a key, or `nil` when the managed file is gone.
    func revision(for id: CanvasBackgroundAssetID) -> String? {
        let url = store.url(for: id)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        let size = values.fileSize ?? -1
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? -1
        return "\(size)-\(Int(modified * 1000))"
    }

    func key(for spec: CanvasBackgroundImageSpec, viewportSize: CGSize, backingScale: Double) -> Key? {
        guard let revision = revision(for: spec.assetID) else { return nil }
        return Key(
            assetID: spec.assetID,
            revision: revision,
            targetPixels: CanvasBackgroundGeometry.decodeTargetPixels(viewportSize: viewportSize, backingScale: backingScale),
            mode: spec.mode,
            backingScale: Int((backingScale * 100).rounded())
        )
    }

    /// Ask for an image. Returns immediately: `.ready` when it is already cached
    /// (no decode), `.pending` when a decode was scheduled, `.failed` when the
    /// managed file is missing.
    @discardableResult
    func request(spec: CanvasBackgroundImageSpec, viewportSize: CGSize, backingScale: Double) -> Outcome {
        guard let key = key(for: spec, viewportSize: viewportSize, backingScale: backingScale) else {
            stats.cacheMisses += 1
            stats.decodeFailures += 1
            onDecodeFailed?(spec.assetID)
            return .failed(spec.assetID)
        }
        if entries[key] != nil {
            stats.cacheHits += 1
            touch(key)
            return .ready(key)
        }
        stats.cacheMisses += 1
        guard !pending.contains(key) else { return .pending(key) }
        pending.insert(key)
        pendingCount += 1
        generation &+= 1
        let token = generation
        qaIssuedRequests.append((key, token))
        stats.decodeRequests += 1
        let url = store.url(for: key.assetID)
        let target = key.targetPixels
        queue.async { [weak self] in
            let decoded = Self.decode(url: url, maximumPixelDimension: target)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.complete(key: key, token: token, image: decoded)
                }
            }
        }
        return .pending(key)
    }

    private func complete(key: Key, token: UInt64, image: CGImage?) {
        pending.remove(key)
        pendingCount -= 1
        stats.decodeCompletions += 1
        // A completion is stale when a newer request has been issued since this
        // one started. Dropping it is the whole point of the token: without it a
        // slow decode of the image the user just replaced would land last and
        // win, and the canvas would show the OLD picture with no way back short
        // of another edit. A repeat request for a key already in flight does not
        // bump the generation, so it is not stale against itself.
        guard token == generation else {
            stats.staleCompletionDrops += 1
            return
        }
        guard let image else {
            stats.decodeFailures += 1
            onDecodeFailed?(key.assetID)
            return
        }
        entries[key] = image
        touch(key)
        evictIfNeeded()
        onImageAvailable?(key)
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictIfNeeded() {
        while entries.count > Self.maximumEntries, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
            stats.evictions += 1
        }
    }

    /// Drop everything. Used when an asset is replaced or removed.
    func invalidateAll() {
        entries.removeAll()
        order.removeAll()
    }

    /// QA: run the main run loop until every scheduled decode has landed.
    /// Bounded so a check can never hang.
    func qaDrainPendingDecodes(timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while pendingCount > 0, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - Decode

    /// `nonisolated` and static: this runs on the decode queue, and it touches
    /// nothing but its arguments.
    private nonisolated static func decode(url: URL, maximumPixelDimension: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maximumPixelDimension, CanvasBackgroundGeometry.maximumDecodePixelDimension),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

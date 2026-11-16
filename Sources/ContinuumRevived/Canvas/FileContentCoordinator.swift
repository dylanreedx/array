import AppKit
import Darwin
import UniformTypeIdentifiers
import ContinuumRevivedCore

/// Selection is separate from loading and presentation. New backends add one
/// factory case without changing canvas identity, navigation or text saving.
enum FileContentKind: Equatable, Sendable {
    case text, image, delimited(UInt8), workbook, external(String)
    static func select(path: String) -> Self {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "csv": return .delimited(44)
        case "tsv", "tab": return .delimited(9)
        case "xlsx": return .workbook
        case "xls", "xlsb", "xlsm", "ods", "numbers":
            return .external("This workbook format requires an external application. Array’s read-only data viewer currently supports XLSX, CSV and TSV.")
        case "svg", "html", "htm": return .text
        default:
            if UTType(filenameExtension: ext)?.conforms(to: .image) == true { return .image }
            return .text
        }
    }
}

/// Counts admitted renderer resources independently of the canvas surface cache.
/// Decoder internals remain OS-owned; concurrency and output dimensions are
/// separately bounded. Reservations are made before invoking any decoder.
final class FileContentBudget: @unchecked Sendable {
    static let shared = FileContentBudget(limit: 128 * 1_024 * 1_024)
    let limit: Int
    private let lock = NSLock()
    private var used = 0
    var retainedBytes: Int { lock.withLock { used } }
    init(limit: Int) { self.limit = limit }
    func reserve(_ bytes: Int) throws -> Lease {
        try lock.withLock {
            guard bytes >= 0, bytes <= limit - used else { throw FileContentFailure.memoryLimit }
            used += bytes
            return Lease(owner: self, bytes: bytes)
        }
    }
    final class Lease: @unchecked Sendable {
        private let owner: FileContentBudget
        private var bytes: Int
        fileprivate init(owner: FileContentBudget, bytes: Int) { self.owner = owner; self.bytes = bytes }
        func reduce(to value: Int) {
            owner.lock.withLock {
                let next = max(0, min(value, bytes))
                owner.used -= bytes - next; bytes = next
            }
        }
        deinit { owner.lock.withLock { owner.used -= bytes } }
    }
}

enum FileContentFailure: Error, LocalizedError {
    case memoryLimit, unsupported, cancelled, snapshotComparisonFailed
    var errorDescription: String? {
        switch self {
        case .memoryLimit: return "The shared file-preview memory limit is in use. Close another large preview, then reload this file."
        case .unsupported: return "This file has no supported read-only preview. Open it externally."
        case .cancelled: return "File preview cancelled."
        case .snapshotComparisonFailed: return "The file preview could not compare its private snapshots."
        }
    }
}

enum FileContentPayload: @unchecked Sendable {
    case image(FileImageDocument)
    case table(DelimitedFileDocument)
    case workbook(XLSXDocument)
}

final class FileContentLoad: @unchecked Sendable {
    let payload: FileContentPayload
    let lease: FileContentBudget.Lease
    let revision: String
    let byteCount: Int
    /// The private, validated bytes underlying this presentation. Retaining the
    /// snapshot lets a later refresh compare content before invoking a decoder.
    let snapshot: SecureFileSnapshot
    let sourcePath: String
    let kind: FileContentKind
    init(payload: FileContentPayload, lease: FileContentBudget.Lease,
         snapshot: SecureFileSnapshot, sourcePath: String, kind: FileContentKind) {
        self.payload = payload; self.lease = lease; self.snapshot = snapshot
        self.revision = snapshot.revision; self.byteCount = snapshot.byteCount
        self.sourcePath = sourcePath; self.kind = kind
    }
}

final class FileContentRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

final class FileContentCoordinator: @unchecked Sendable {
    static let shared = FileContentCoordinator()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Array.file-content"; queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private final class WeakLoad: @unchecked Sendable {
        weak var value: FileContentLoad?
        init(_ value: FileContentLoad) { self.value = value }
    }
    private let cacheLock = NSLock()
    private var cache: [String: WeakLoad] = [:]
    private var decodeCount = 0
    private var decodeCountByPath: [String: Int] = [:]
    /// Active plus queued operations only: entries vanish as soon as a path is
    /// quiescent, so counting never retains a history of user paths.
    private var activeOperationsByPath: [String: Int] = [:]
    private var qaCaptureFailures: Set<String> = []
    private var qaComparisonFailures: Set<String> = []
    private var qaAfterCaptureHooks: [String: @Sendable () -> Void] = [:]
    var qaDecodeCount: Int { cacheLock.withLock { decodeCount } }
    private static func qaKey(forPath path: String) -> String {
        path.hasPrefix("/var/") || path.hasPrefix("/tmp/") ? "/private" + path : path
    }
    func qaBeginDecodeTracking(forPath path: String) {
        cacheLock.withLock { decodeCountByPath[Self.qaKey(forPath: path)] = 0 }
    }
    func qaEndDecodeTracking(forPath path: String) {
        _ = cacheLock.withLock { decodeCountByPath.removeValue(forKey: Self.qaKey(forPath: path)) }
    }
    func qaDecodeCount(forPath path: String) -> Int {
        // Match the two fixed system aliases the host resolves before capture.
        return cacheLock.withLock { decodeCountByPath[Self.qaKey(forPath: path), default: 0] }
    }
    /// One-shot, path-scoped failure used only by the offline retry witness.
    func qaFailNextCapture(forPath path: String) {
        cacheLock.withLock { _ = qaCaptureFailures.insert(Self.qaKey(forPath: path)) }
    }
    func qaClearCaptureFailure(forPath path: String) {
        cacheLock.withLock { _ = qaCaptureFailures.remove(Self.qaKey(forPath: path)) }
    }
    func qaFailNextComparison(forPath path: String) {
        cacheLock.withLock { _ = qaComparisonFailures.insert(Self.qaKey(forPath: path)) }
    }
    func qaClearComparisonFailure(forPath path: String) {
        cacheLock.withLock { _ = qaComparisonFailures.remove(Self.qaKey(forPath: path)) }
    }
    func qaActiveOperationCount(forPath path: String) -> Int {
        cacheLock.withLock { activeOperationsByPath[Self.qaKey(forPath: path), default: 0] }
    }
    /// Run once on the worker after validation, to witness a source change
    /// while a refresh is in flight. The hook must never wait without a bound.
    func qaAfterCaptureOnce(forPath path: String, _ hook: @escaping @Sendable () -> Void) {
        cacheLock.withLock { qaAfterCaptureHooks[Self.qaKey(forPath: path)] = hook }
    }
    func qaClearAfterCaptureHook(forPath path: String) {
        _ = cacheLock.withLock { qaAfterCaptureHooks.removeValue(forKey: Self.qaKey(forPath: path)) }
    }
    private let budget = FileContentBudget.shared

    @discardableResult
    func load(path: String, kind: FileContentKind, reusing prior: FileContentLoad? = nil,
              completion: @escaping @MainActor @Sendable (Result<FileContentLoad, Error>) -> Void) -> FileContentRequest {
        let request = FileContentRequest()
        // Do not keep the old renderer's budget alive after the host retires it
        // to retry a changed preview that could not fit alongside that renderer.
        let priorRef = prior.map(WeakLoad.init)
        let qaPath = Self.qaKey(forPath: path)
        cacheLock.withLock { activeOperationsByPath[qaPath, default: 0] += 1 }
        queue.addOperation { [self, priorRef] in
            defer {
                cacheLock.withLock {
                    if let count = activeOperationsByPath[qaPath], count > 1 {
                        activeOperationsByPath[qaPath] = count - 1
                    } else {
                        activeOperationsByPath.removeValue(forKey: qaPath)
                    }
                }
            }
            guard !request.isCancelled else { return }
            let result: Result<FileContentLoad, Error>
            do {
                let sourceLimit: Int
                switch kind {
                case .delimited: sourceLimit = 256 * 1_024 * 1_024
                case .image, .workbook: sourceLimit = 64 * 1_024 * 1_024
                default: throw FileContentFailure.unsupported
                }
                let injectFailure = cacheLock.withLock { qaCaptureFailures.remove(qaPath) != nil }
                if injectFailure { throw SecureFileSnapshot.CaptureError.stagingFailed(EIO) }
                let snapshot = try SecureFileSnapshot.capture(path: path, maxBytes: sourceLimit,
                                                              cancelled: { request.isCancelled })
                let hook = cacheLock.withLock { qaAfterCaptureHooks.removeValue(forKey: qaPath) }
                hook?()
                guard !request.isCancelled else { return }
                let key = path + "#" + snapshot.revision + "#" + String(describing: kind)
                // Restrict the strong prior to the comparison scope. For changed
                // content it is released before reserving/decoding anything.
                let sameAsPrior = try { () throws -> Bool in
                    guard let value = priorRef?.value, value.kind == kind, value.sourcePath == path else { return false }
                    if cacheLock.withLock({ qaComparisonFailures.remove(qaPath) != nil }) {
                        throw FileContentFailure.snapshotComparisonFailed
                    }
                    do {
                        return try Self.sameBytes(snapshot, value.snapshot, cancelled: { request.isCancelled })
                    } catch FileContentFailure.cancelled {
                        throw FileContentFailure.cancelled
                    } catch {
                        // A comparison failure is temporary: unlike malformed
                        // source bytes, it must be retried even if metadata is
                        // unchanged on the next observation tick.
                        throw FileContentFailure.snapshotComparisonFailed
                    }
                }()
                guard !request.isCancelled else { return }
                if sameAsPrior, let prior = priorRef?.value {
                    // Identity lets the host retain its renderer and all of its
                    // scroll/selection state. No decoder has run for this load.
                    result = .success(prior)
                } else if let cached = cacheLock.withLock({ cache[key]?.value }) {
                    result = .success(cached)
                } else {
                    let reservation = try budget.reserve(kind.isTable ? 32 * 1_024 * 1_024 : 64 * 1_024 * 1_024)
                    cacheLock.withLock {
                        decodeCount += 1
                        if let count = decodeCountByPath[qaPath] { decodeCountByPath[qaPath] = count + 1 }
                    }
                    let payload: FileContentPayload
                    switch kind {
                    case .image:
                        let document = try FileImageBackend.load(snapshot: snapshot)
                        reservation.reduce(to: document.decodedBytes)
                        payload = .image(document)
                    case let .delimited(delimiter):
                        let document = try DelimitedFileDocument.load(snapshot: snapshot, delimiter: delimiter,
                                                                     cancelled: { request.isCancelled })
                        reservation.reduce(to: document.indexByteCount + 64 * 1_024)
                        payload = .table(document)
                    case .workbook:
                        let document = try XLSXDocument.load(snapshot: snapshot, cancelled: { request.isCancelled })
                        payload = .workbook(document)
                    default: throw FileContentFailure.unsupported
                    }
                    guard !request.isCancelled else { throw FileContentFailure.cancelled }
                    let loaded = FileContentLoad(payload: payload, lease: reservation,
                                                 snapshot: snapshot, sourcePath: path, kind: kind)
                    cacheLock.withLock {
                        cache = cache.filter { $0.value.value != nil }
                        cache[key] = WeakLoad(loaded)
                    }
                    result = .success(loaded)
                }
            } catch { result = .failure(error) }
            guard !request.isCancelled else { return }
            Task { @MainActor in
                guard !request.isCancelled else { return }
                completion(result)
            }
        }
        return request
    }

    /// Compare two private snapshots rather than mutable source paths. Both were
    /// securely opened and revalidated by capture, and remain retained for the
    /// duration of this off-main comparison. A read failure is not equality.
    private static func sameBytes(_ a: SecureFileSnapshot, _ b: SecureFileSnapshot,
                                  cancelled: @Sendable () -> Bool) throws -> Bool {
        guard a.byteCount == b.byteCount else { return false }
        let left = try FileHandle(forReadingFrom: a.url)
        defer { try? left.close() }
        let right = try FileHandle(forReadingFrom: b.url)
        defer { try? right.close() }

        func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
            var bytes = Data()
            bytes.reserveCapacity(count)
            while bytes.count < count {
                if cancelled() { throw FileContentFailure.cancelled }
                guard let chunk = try handle.read(upToCount: count - bytes.count), !chunk.isEmpty else {
                    throw CocoaError(.fileReadUnknown)
                }
                bytes.append(chunk)
            }
            return bytes
        }
        var remaining = a.byteCount
        while remaining > 0 {
            if cancelled() { throw FileContentFailure.cancelled }
            let size = min(64 * 1_024, remaining)
            guard try readExactly(size, from: left) == readExactly(size, from: right) else { return false }
            remaining -= size
        }
        if cancelled() { throw FileContentFailure.cancelled }
        return true
    }
}

private extension FileContentKind {
    var isTable: Bool { if case .delimited = self { return true }; return false }
}

import AppKit
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
    case memoryLimit, unsupported, cancelled
    var errorDescription: String? {
        switch self {
        case .memoryLimit: return "The shared file-preview memory limit is in use. Close another large preview, then reload this file."
        case .unsupported: return "This file has no supported read-only preview. Open it externally."
        case .cancelled: return "File preview cancelled."
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
    init(payload: FileContentPayload, lease: FileContentBudget.Lease, revision: String, byteCount: Int) {
        self.payload = payload; self.lease = lease; self.revision = revision; self.byteCount = byteCount
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
    private final class WeakLoad { weak var value: FileContentLoad?; init(_ value: FileContentLoad) { self.value = value } }
    private let cacheLock = NSLock()
    private var cache: [String: WeakLoad] = [:]
    private let budget = FileContentBudget.shared

    @discardableResult
    func load(path: String, kind: FileContentKind,
              completion: @escaping @MainActor @Sendable (Result<FileContentLoad, Error>) -> Void) -> FileContentRequest {
        let request = FileContentRequest()
        queue.addOperation { [self] in
            guard !request.isCancelled else { return }
            let result: Result<FileContentLoad, Error>
            do {
                let sourceLimit: Int
                switch kind {
                case .delimited: sourceLimit = 256 * 1_024 * 1_024
                case .image, .workbook: sourceLimit = 64 * 1_024 * 1_024
                default: throw FileContentFailure.unsupported
                }
                let snapshot = try SecureFileSnapshot.capture(path: path, maxBytes: sourceLimit,
                                                              cancelled: { request.isCancelled })
                let key = path + "#" + snapshot.revision + "#" + String(describing: kind)
                if let cached = cacheLock.withLock({ cache[key]?.value }) {
                    result = .success(cached)
                } else {
                    let reservation = try budget.reserve(kind.isTable ? 32 * 1_024 * 1_024 : 64 * 1_024 * 1_024)
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
                    let loaded = FileContentLoad(payload: payload, lease: reservation, revision: snapshot.revision, byteCount: snapshot.byteCount)
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
}

private extension FileContentKind {
    var isTable: Bool { if case .delimited = self { return true }; return false }
}

import Foundation
import Darwin

/// A private, read-only copy of one validated regular-file revision. The caller
/// supplies an already authorized canonical path; capture never follows a new
/// symlink in that path. Retain this object while consumers use `url`.
public final class SecureFileSnapshot: @unchecked Sendable {
    public enum CaptureError: Error, Equatable, LocalizedError {
        case invalidPath
        case cannotOpen(Int32)
        case notRegularFile
        case tooLarge(maxBytes: Int)
        case changedDuringCapture
        case cancelled
        case stagingFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case .invalidPath: return "The file path must be absolute and canonical."
            case .cannotOpen: return "The file could not be opened without following symbolic links."
            case .notRegularFile: return "Only regular files can be previewed; folders and packages are unsupported."
            case let .tooLarge(maxBytes): return "The file exceeds the preview limit of \(maxBytes) bytes."
            case .changedDuringCapture: return "The file changed while its preview was being prepared."
            case .cancelled: return "The file preview was cancelled."
            case .stagingFailed: return "A private file preview could not be created."
            }
        }
    }

    public let url: URL
    public let byteCount: Int
    public let revision: String
    private let directory: URL

    private init(url: URL, byteCount: Int, revision: String, directory: URL) {
        self.url = url
        self.byteCount = byteCount
        self.revision = revision
        self.directory = directory
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    public static func capture(
        path: String,
        maxBytes: Int,
        cancelled: @Sendable () -> Bool = { false }
    ) throws -> SecureFileSnapshot {
        try capture(path: path, maxBytes: maxBytes, cancelled: cancelled, phase: { _ in })
    }

    /// Controlled seams for race/cancellation witnesses, not filesystem polling.
    package enum CapturePhase: Sendable {
        case sourceValidated
        case stagingCreated(URL)
        case copiedChunk
        case copyFinished
    }

    package static func capture(
        path: String,
        maxBytes: Int,
        cancelled: @Sendable () -> Bool,
        phase: @Sendable (CapturePhase) -> Void
    ) throws -> SecureFileSnapshot {
        guard maxBytes >= 0 && maxBytes < Int.max else { throw CaptureError.invalidPath }
        try checkCancellation(cancelled)
        let source = try openSource(path: path)
        defer { Darwin.close(source) }
        let before = try fileState(source)
        guard before.isRegular else { throw CaptureError.notRegularFile }
        guard before.size >= 0 && before.size <= Int64(maxBytes) else {
            throw CaptureError.tooLarge(maxBytes: maxBytes)
        }
        phase(.sourceValidated)
        try checkCancellation(cancelled)

        // mkdtemp atomically creates an application-private directory (0700).
        var template = Array(FileManager.default.temporaryDirectory
            .appendingPathComponent("array-file-snapshot-XXXXXX").path.utf8CString)
        let directoryPath = try template.withUnsafeMutableBufferPointer { buffer -> String in
            guard let pointer = mkdtemp(buffer.baseAddress!) else { throw CaptureError.stagingFailed(errno) }
            return String(cString: pointer)
        }
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: directory) } }
        // Retain a bounded filename suffix for system preview format recognition.
        let suffix = URL(fileURLWithPath: path).pathExtension
        let name = suffix.isEmpty || suffix.utf8.count > 64 ? "snapshot" : "snapshot.\(suffix)"
        let outputURL = directory.appendingPathComponent(name, isDirectory: false)
        let output = outputURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard output >= 0 else { throw CaptureError.stagingFailed(errno) }
        defer { Darwin.close(output) }
        phase(.stagingCreated(outputURL))

        var total = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try checkCancellation(cancelled)
            // Read at most one byte beyond admission, even if the source grows.
            let request = min(buffer.count, maxBytes - total + 1)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress!, request) }
            if count < 0 {
                if errno == EINTR { continue }
                throw CaptureError.cannotOpen(errno)
            }
            if count == 0 { break }
            guard count <= maxBytes - total else { throw CaptureError.tooLarge(maxBytes: maxBytes) }
            try checkCancellation(cancelled)
            var written = 0
            while written < count {
                try checkCancellation(cancelled)
                let result = buffer.withUnsafeBytes {
                    Darwin.write(output, $0.baseAddress!.advanced(by: written), count - written)
                }
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { throw CaptureError.stagingFailed(errno) }
                written += result
            }
            total += count
            phase(.copiedChunk)
        }
        phase(.copyFinished)
        try checkCancellation(cancelled)
        let after = try fileState(source)
        guard before == after && after.size == Int64(total) else { throw CaptureError.changedDuringCapture }
        // Rewalk from /: checking only the original parent descriptor would miss
        // replacement of a parent directory or the final path binding.
        let bound: Int32
        do { bound = try openSource(path: path) }
        catch { throw CaptureError.changedDuringCapture }
        defer { Darwin.close(bound) }
        guard try fileState(bound) == before else { throw CaptureError.changedDuringCapture }
        try checkCancellation(cancelled)
        guard fchmod(output, mode_t(0o400)) == 0 else { throw CaptureError.stagingFailed(errno) }
        let result = SecureFileSnapshot(url: outputURL, byteCount: total, revision: before.revision, directory: directory)
        retained = true
        return result
    }

    private static func checkCancellation(_ cancelled: @Sendable () -> Bool) throws {
        if cancelled() { throw CaptureError.cancelled }
    }

    /// Every parent is opened relative to an already validated directory. Neither
    /// Foundation standardization nor realpath may turn a swapped symlink into a
    /// newly authorized target. O_NONBLOCK prevents a swapped FIFO from hanging.
    private static func openSource(path: String) throws -> Int32 {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw CaptureError.invalidPath }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CaptureError.invalidPath
        }
        var parent = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw CaptureError.cannotOpen(errno) }
        defer { Darwin.close(parent) }
        for component in components.dropLast() {
            let child = String(component).withCString {
                openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard child >= 0 else { throw CaptureError.cannotOpen(errno) }
            Darwin.close(parent)
            parent = child
        }
        let source = String(components.last!).withCString {
            openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard source >= 0 else { throw CaptureError.cannotOpen(errno) }
        return source
    }

    private struct FileState: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let mode: UInt16
        let modificationSeconds: Int
        let modificationNanoseconds: Int
        let changeSeconds: Int
        let changeNanoseconds: Int
        var isRegular: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFREG) }
        var revision: String {
            "\(device):\(inode):\(size):\(modificationSeconds).\(modificationNanoseconds):\(changeSeconds).\(changeNanoseconds)"
        }
    }

    private static func fileState(_ descriptor: Int32) throws -> FileState {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw CaptureError.cannotOpen(errno) }
        return FileState(device: value.st_dev, inode: value.st_ino, size: value.st_size, mode: value.st_mode,
                         modificationSeconds: value.st_mtimespec.tv_sec, modificationNanoseconds: value.st_mtimespec.tv_nsec,
                         changeSeconds: value.st_ctimespec.tv_sec, changeNanoseconds: value.st_ctimespec.tv_nsec)
    }
}

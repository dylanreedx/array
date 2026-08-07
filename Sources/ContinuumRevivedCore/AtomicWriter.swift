import Darwin
import Foundation

public enum AtomicWriterError: Error, Equatable {
    case noValidBackup(path: String)
}

public struct AtomicWriterDescriptorOperations: Sendable {
    public var open: @Sendable (_ path: String, _ flags: Int32) -> Int32
    public var fsync: @Sendable (_ fd: Int32) -> Int32
    public var close: @Sendable (_ fd: Int32) -> Int32

    public init(
        open: @escaping @Sendable (_ path: String, _ flags: Int32) -> Int32 = { Darwin.open($0, $1) },
        fsync: @escaping @Sendable (_ fd: Int32) -> Int32 = { Darwin.fsync($0) },
        close: @escaping @Sendable (_ fd: Int32) -> Int32 = { Darwin.close($0) }
    ) {
        self.open = open
        self.fsync = fsync
        self.close = close
    }

    public static let live = AtomicWriterDescriptorOperations()
}

public struct AtomicWriter: Sendable {
    public let backupsDirectory: URL?
    public let retainedBackups: Int
    public let prettyPrint: Bool
    public let descriptorOperations: AtomicWriterDescriptorOperations

    public init(
        backupsDirectory: URL? = nil,
        retainedBackups: Int = 3,
        prettyPrint: Bool = true,
        descriptorOperations: AtomicWriterDescriptorOperations = .live
    ) {
        self.backupsDirectory = backupsDirectory
        self.retainedBackups = max(0, retainedBackups)
        self.prettyPrint = prettyPrint
        self.descriptorOperations = descriptorOperations
    }

    /// Write `value` as JSON to `url`. The previous file (if any) is copied to
    /// `backupsDirectory` before the new content lands; old backups beyond
    /// `retainedBackups` are pruned.
    public func write<T: Codable>(_ value: T, to url: URL) throws {
        let encoder = JSONCodec.makeEncoder(prettyPrinted: prettyPrint)
        let data = try encoder.encode(value)
        // Validate the encoded bytes round-trip into the same type before we
        // touch the filesystem. If decode throws, the existing file is intact.
        _ = try JSONCodec.makeDecoder().decode(T.self, from: data)

        let parentDir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDir,
            withIntermediateDirectories: true
        )

        // Backup the existing file before overwriting.
        try backupExistingFile(at: url)

        // Durable atomic write: temp in same dir → fsync temp fd → rename(2) → fsync dir fd.
        try atomicDurableWrite(data, to: url)

        // Trim old backups for this file.
        try pruneOldBackups(for: url)
    }

    /// Read JSON from `url`. If the main file is missing or corrupt, fall back
    /// to the newest valid backup. Throws if neither path yields a parseable
    /// value of `T`.
    public func read<T: Codable>(at url: URL) throws -> T {
        try read(at: url, decoder: JSONCodec.makeDecoder())
    }

    public func read<T: Codable>(at url: URL, decoder: JSONDecoder) throws -> T {
        if let data = try? Data(contentsOf: url),
           let value = try? decoder.decode(T.self, from: data) {
            return value
        }

        // Try backups from newest to oldest.
        for backupURL in try backupURLsNewestFirst(for: url) {
            if let data = try? Data(contentsOf: backupURL),
               let value = try? decoder.decode(T.self, from: data) {
                return value
            }
        }

        throw AtomicWriterError.noValidBackup(path: url.path)
    }

    // MARK: - Internal helpers

    /// Write `data` to `url` durably:
    ///   1. Write bytes to a dot-prefixed sibling temp in the **same directory** (same volume → rename is atomic).
    ///   2. fsync the temp's file descriptor so bytes are on stable storage before the rename.
    ///   3. rename(2) the temp into place atomically.
    ///   4. fsync the parent directory fd so the rename itself is durable.
    /// If any step fails, the temp is removed and `url` is untouched.
    private func atomicDurableWrite(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        // Write bytes to the temp (not atomic — it's throwaway; atomicity comes from rename).
        try data.write(to: tmp)
        // fsync the temp's data to stable storage before rename.
        let fd = descriptorOperations.open(tmp.path, O_RDONLY)
        guard fd >= 0 else {
            let err = errno
            try? FileManager.default.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        if descriptorOperations.fsync(fd) != 0 {
            let err = errno
            _ = descriptorOperations.close(fd)
            try? FileManager.default.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        if descriptorOperations.close(fd) != 0 {
            let err = errno
            try? FileManager.default.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        // Atomic, same-volume rename. On failure, clean up the temp and rethrow.
        if rename(tmp.path, url.path) != 0 {
            let err = errno
            try? FileManager.default.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        // fsync the parent directory so the directory entry (rename) is durable.
        let dfd = descriptorOperations.open(dir.path, O_RDONLY)
        guard dfd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if descriptorOperations.fsync(dfd) != 0 {
            let err = errno
            _ = descriptorOperations.close(dfd)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        if descriptorOperations.close(dfd) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func backupExistingFile(at url: URL) throws {
        guard
            let backupsDirectory,
            FileManager.default.fileExists(atPath: url.path)
        else { return }

        try FileManager.default.createDirectory(
            at: backupsDirectory,
            withIntermediateDirectories: true
        )

        let backupURL = backupsDirectory.appendingPathComponent(
            backupName(for: url, at: Date())
        )
        try? FileManager.default.removeItem(at: backupURL)
        try FileManager.default.copyItem(at: url, to: backupURL)
    }

    private func pruneOldBackups(for url: URL) throws {
        guard backupsDirectory != nil else { return }
        let urls = try backupURLsNewestFirst(for: url)
        guard urls.count > retainedBackups else { return }
        for stale in urls.dropFirst(retainedBackups) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    private func backupURLsNewestFirst(for url: URL) throws -> [URL] {
        guard
            let backupsDirectory,
            FileManager.default.fileExists(atPath: backupsDirectory.path)
        else { return [] }

        let prefix = "\(url.deletingPathExtension().lastPathComponent)."
        let ext = "." + url.pathExtension
        let entries = try FileManager.default.contentsOfDirectory(
            at: backupsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return entries
            .filter { entry in
                let name = entry.lastPathComponent
                return name.hasPrefix(prefix) && name.hasSuffix(ext)
            }
            // Backup names embed an ISO 8601 timestamp + millis + monotonic
            // tiebreaker (see backupName), so lexicographic descending order
            // is newest-first.
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private static let backupCounter = AtomicCounter()

    private func backupName(for url: URL, at date: Date) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
        // Monotonic suffix prevents collisions when multiple writes land in
        // the same millisecond on a fast machine.
        let n = Self.backupCounter.next()
        return "\(stem).\(iso).\(String(format: "%06d", n)).\(ext)"
    }
}

private final class AtomicCounter: @unchecked Sendable {
    private var value: UInt64 = 0
    private let lock = NSLock()

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }
}

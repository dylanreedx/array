import Darwin
import Foundation
import CryptoKit

/// Whether a writer can still FIND backups written under the pre-v2 name
/// `<stem>.<iso>.<counter>.<ext>`.
///
/// Every installed copy in the field has backups under the old name, and a
/// writer that cannot see them silently strands the user's entire recoverable
/// history: the target corrupts, recovery reports "no valid backup", the store
/// boots empty, and the next save begins a fresh v2 chain over the empty
/// document while the good files sit on disk that no code path will ever read.
/// That really was the state — only `WorkspaceStore` opted in, so `ProjectStore`,
/// which owns `<project root>/.array/canvas.json`, could not recover one of them.
///
/// So every store that owns its OWN backups directory opts in. The default stays
/// `.disabled` deliberately: legacy names carry no identity, so two same-basename
/// targets sharing ONE backups directory would cross-recover from each other's
/// backups. v2 names embed the target's identity hash and are immune; legacy
/// names are not, and `--workspace-restart-fault-check` pins that hazard. Opting
/// in is therefore a per-store statement that the store owns its directory.
public enum AtomicWriterLegacyBackupPolicy: Sendable, Equatable {
    case disabled
    case targetDedicated
}

public enum AtomicWriterError: Error, Equatable, CustomStringConvertible {
    case noValidBackup(path: String)
    case priorTargetUnreadable
    case rollbackIndeterminate

    /// The associated path is retained for local recovery code only. Never let
    /// the filesystem location cross a warning/UI/diagnostic boundary.
    public var description: String {
        switch self {
        case .noValidBackup:
            return "no valid backup"
        case .priorTargetUnreadable:
            return "existing document is unreadable"
        case .rollbackIndeterminate:
            return "document rollback durability is indeterminate"
        }
    }
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

/// Injectable boundaries for the filesystem operations that form the atomic
/// commit. Production always uses `live`; focused persistence checks can fail
/// one named operation without changing process permissions or global state.
public struct AtomicWriterFileOperations: Sendable {
    public var writeTemporary: @Sendable (Data, URL) throws -> Void
    public var replace: @Sendable (URL, URL) throws -> Void
    public var remove: @Sendable (URL) throws -> Void
    public var listDirectory: @Sendable (URL) throws -> [URL]
    public var readExisting: @Sendable (URL) throws -> Data

    public init(
        writeTemporary: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
            try data.write(to: url)
        },
        replace: @escaping @Sendable (URL, URL) throws -> Void = { source, destination in
            if Darwin.rename(source.path, destination.path) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        },
        remove: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        listDirectory: @escaping @Sendable (URL) throws -> [URL] = {
            try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        },
        readExisting: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) {
        self.writeTemporary = writeTemporary
        self.replace = replace
        self.remove = remove
        self.listDirectory = listDirectory
        self.readExisting = readExisting
    }

    public static let live = AtomicWriterFileOperations()
}

public struct AtomicWriter: Sendable {
    public let backupsDirectory: URL?
    public let retainedBackups: Int
    public let prettyPrint: Bool
    public let descriptorOperations: AtomicWriterDescriptorOperations
    public let fileOperations: AtomicWriterFileOperations
    public let backupDate: @Sendable () -> Date
    public let legacyBackupPolicy: AtomicWriterLegacyBackupPolicy

    public init(
        backupsDirectory: URL? = nil,
        retainedBackups: Int = 3,
        prettyPrint: Bool = true,
        descriptorOperations: AtomicWriterDescriptorOperations = .live,
        fileOperations: AtomicWriterFileOperations = .live,
        backupDate: @escaping @Sendable () -> Date = { Date() },
        legacyBackupPolicy: AtomicWriterLegacyBackupPolicy = .disabled
    ) {
        self.backupsDirectory = backupsDirectory
        self.retainedBackups = max(0, retainedBackups)
        self.prettyPrint = prettyPrint
        self.descriptorOperations = descriptorOperations
        self.fileOperations = fileOperations
        self.backupDate = backupDate
        self.legacyBackupPolicy = legacyBackupPolicy
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

        try withTargetLock(url) {
            // The entire prior-read/backup/replace/rollback transaction is one
            // cross-process critical section. A failed writer can therefore
            // never roll an acknowledged later writer back out of existence.
            let priorBytes = try existingBytes(at: url)
            try backupExistingFile(at: url)
            try atomicDurableWrite(data, to: url, priorBytes: priorBytes)
            // Replacement + directory fsync is the commit point. Backup
            // maintenance is deliberately non-transactional and must not turn
            // an already durable generation into a reported save failure.
            do {
                try pruneOldBackups(for: url)
            } catch {
                // The replacement is already durable. Report maintenance
                // separately without lying to the caller about its commit.
                fputs("AtomicWriter: post-commit backup maintenance failed: \(error)\n", stderr)
            }
        }
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

    private func withTargetLock<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        let canonical = canonicalTarget(for: url)
        // Resolving the parent collapses relative and symlink aliases before
        // choosing both locks. Workspace documents are owned canonical paths;
        // callers must not address one document through distinct hardlinks.
        let processLease = AtomicWriterTargetLocks.acquire(for: canonical.path)
        processLease.lock.lock()
        defer {
            processLease.lock.unlock()
            AtomicWriterTargetLocks.release(processLease, for: canonical.path)
        }
        let lockURL = canonical.deletingLastPathComponent()
            .appendingPathComponent(".\(canonical.lastPathComponent).array-write.lock")
        let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var lock = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        while Darwin.fcntl(fd, F_SETLKW, &lock) != 0 {
            let lockError = errno
            if lockError == EINTR { continue }
            // close(2) is cleanup only and is deliberately attempted once: on
            // EINTR/EIO Darwin does not promise that the descriptor is still
            // ours, so retrying could close a subsequently reused descriptor.
            _ = Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: lockError) ?? .EIO)
        }
        defer {
            var unlock = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_UNLCK), l_whence: Int16(SEEK_SET))
            // Unlock is best-effort cleanup. Closing the descriptor releases
            // any surviving process lock; neither result changes body truth.
            _ = Darwin.fcntl(fd, F_SETLK, &unlock)
            _ = Darwin.close(fd)
        }
        return try body()
    }

    /// Canonical identity for a target file. This string is hashed into every
    /// backup filename and the lock path, so it MUST be identical for every
    /// spelling of the same file.
    ///
    /// `standardizedFileURL` is deliberately not used: on macOS it abbreviates
    /// `/private/tmp` back to `/tmp` (and `/private/var` to `/var`), so the same
    /// directory hashed to two different namespaces depending on how the caller
    /// spelled it and on whether the directory existed yet. That silently split
    /// a file's backups in two -- retention then saw an empty history and kept
    /// nothing. `resolvingSymlinksInPath` alone is idempotent and maps every
    /// spelling onto the one real path.
    private func canonicalTarget(for url: URL) -> URL {
        URL(fileURLWithPath: Self.canonicalIdentityPath(for: url))
    }

    /// The exact string hashed into every backup filename and the lock path.
    /// Public so a witness can assert the one property that matters: it must not
    /// change when the target's directory comes into existence.
    public static func canonicalIdentityPath(for url: URL) -> String {
        let directory = url.deletingLastPathComponent().resolvingSymlinksInPath()
        return URL(fileURLWithPath: stablePrivatePrefix(directory.path))
            .appendingPathComponent(url.lastPathComponent).path
    }

    /// `resolvingSymlinksInPath()` applies the macOS `/private` abbreviation
    /// ONLY once the path exists: `/private/tmp/x` resolves to itself while the
    /// directory is missing and to `/tmp/x` once it is there. That made the
    /// canonical path -- and therefore the backup namespace and the lock path --
    /// change between a file's first save and every later one, so retention
    /// looked at an empty history and kept nothing. Apply the abbreviation
    /// unconditionally so identity is stable from the first write.
    public static func stablePrivatePrefix(_ path: String) -> String {
        for prefix in ["/private/tmp", "/private/var"]
        where path == prefix || path.hasPrefix(prefix + "/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    private func targetNamespace(for url: URL) -> String {
        SHA256.hash(data: Data(canonicalTarget(for: url).path.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Write `data` to `url` durably:
    ///   1. Write bytes to a dot-prefixed sibling temp in the **same directory** (same volume → rename is atomic).
    ///   2. fsync the temp's file descriptor so bytes are on stable storage before the rename.
    ///   3. rename(2) the temp into place atomically.
    ///   4. fsync the parent directory fd so the rename itself is durable.
    /// If any step fails, the temp is removed and `url` is untouched.
    private func existingBytes(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return try fileOperations.readExisting(url) }
        catch { throw AtomicWriterError.priorTargetUnreadable }
    }

    private func atomicDurableWrite(_ data: Data, to url: URL, priorBytes: Data?) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        // Write bytes to the temp (not atomic — it's throwaway; atomicity comes from rename).
        do {
            try fileOperations.writeTemporary(data, tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
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
        // This is pre-commit cleanup. A close failure is reported, but never
        // retried because descriptor identity after close error is unspecified.
        if descriptorOperations.close(fd) != 0 {
            let err = errno
            try? FileManager.default.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        // Atomic, same-volume rename. On failure, clean up the temp and rethrow.
        do {
            try fileOperations.replace(tmp, url)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        // fsync the parent directory so the directory entry (rename) is durable.
        let dfd = descriptorOperations.open(dir.path, O_RDONLY)
        guard dfd >= 0 else {
            do { try rollbackCommittedWrite(at: url, priorBytes: priorBytes) }
            catch { throw AtomicWriterError.rollbackIndeterminate }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if descriptorOperations.fsync(dfd) != 0 {
            let err = errno
            _ = descriptorOperations.close(dfd)
            do { try rollbackCommittedWrite(at: url, priorBytes: priorBytes) }
            catch { throw AtomicWriterError.rollbackIndeterminate }
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        // Successful parent-directory fsync is the transaction commit point.
        // close is cleanup only: attempt it exactly once, and never turn its
        // ambiguous result into rollback or a false save failure.
        _ = descriptorOperations.close(dfd)
    }

    /// A directory durability failure happens after rename. Do not expose those
    /// unacknowledged bytes as the next launch's truth: atomically restore the
    /// retained prior bytes with live operations, then durably sync the directory.
    private func rollbackCommittedWrite(at url: URL, priorBytes: Data?) throws {
        guard let priorBytes else {
            try fileOperations.remove(url)
            try syncDirectory(url.deletingLastPathComponent())
            return
        }
        let dir = url.deletingLastPathComponent()
        let rollback = dir.appendingPathComponent(".\(url.lastPathComponent).rollback-\(UUID().uuidString)")
        do {
            try priorBytes.write(to: rollback)
            let fd = Darwin.open(rollback.path, O_RDONLY)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            defer { _ = Darwin.close(fd) }
            guard Darwin.fsync(fd) == 0 else { throw POSIXError(.EIO) }
            guard Darwin.rename(rollback.path, url.path) == 0 else { throw POSIXError(.EIO) }
            let dfd = Darwin.open(dir.path, O_RDONLY)
            guard dfd >= 0 else { throw POSIXError(.EIO) }
            defer { _ = Darwin.close(dfd) }
            guard Darwin.fsync(dfd) == 0 else { throw POSIXError(.EIO) }
        } catch {
            try? FileManager.default.removeItem(at: rollback)
            throw error
        }
    }

    private func syncDirectory(_ dir: URL) throws {
        let dfd = Darwin.open(dir.path, O_RDONLY)
        guard dfd >= 0 else { throw POSIXError(.EIO) }
        defer { _ = Darwin.close(dfd) }
        guard Darwin.fsync(dfd) == 0 else { throw POSIXError(.EIO) }
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

        // The canonical target lock covers this directory scan and copy. The
        // generation is therefore durable, process-independent ordering truth;
        // wall clock is only human-readable metadata.
        let existing = try backupEntries(for: url, entries:
            FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: nil))
        let maximum = existing.compactMap(\.generation).max() ?? 0
        guard maximum < UInt64.max else { throw POSIXError(.EOVERFLOW) }
        let generation = maximum + 1
        let backupURL = backupsDirectory.appendingPathComponent(
            backupName(for: url, at: backupDate(), generation: generation)
        )
        // Never remove or overwrite a collision. This should be unreachable
        // under the target lock, but copyItem's exclusive failure is fail-safe.
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

        return try backupEntries(for: url).sorted { lhs, rhs in
            switch (lhs.generation, rhs.generation) {
            case let (l?, r?): return l == r ? lhs.url.lastPathComponent > rhs.url.lastPathComponent : l > r
            case (_?, nil): return true       // every new generation follows legacy history
            case (nil, _?): return false
            case (nil, nil): return lhs.url.lastPathComponent > rhs.url.lastPathComponent
            }
        }.map(\.url)
    }

    private struct BackupEntry {
        let url: URL
        let generation: UInt64?
    }

    private func backupEntries(for url: URL) throws -> [BackupEntry] {
        guard let backupsDirectory else { return [] }
        let entries = try fileOperations.listDirectory(backupsDirectory)
        return backupEntries(for: url, entries: entries)
    }

    private func backupEntries(for url: URL, entries: [URL]) -> [BackupEntry] {
        let identity = targetNamespace(for: url)
        let newPrefix = "array-backup-v2-\(identity)-"
        let legacyStem = url.deletingPathExtension().lastPathComponent
        let legacyPrefix = "\(legacyStem)."
        let legacySuffix = ".\(url.pathExtension)"
        return entries.compactMap { entry in
            let name = entry.lastPathComponent
            if name.hasPrefix(newPrefix) {
                guard let generation = v2Generation(in: name, identity: identity) else { return nil }
                return BackupEntry(url: entry, generation: generation)
            }
            // Legacy: exact stem/extension plus a parseable ISO-8601 timestamp
            // and the historical 6- or 12-digit suffix. This rejects similarly
            // prefixed and dotted target names sharing one backup directory.
            guard legacyBackupPolicy == .targetDedicated,
                  name.hasPrefix(legacyPrefix), name.hasSuffix(legacySuffix) else { return nil }
            let body = name.dropFirst(legacyPrefix.count).dropLast(legacySuffix.count)
            guard let separator = body.lastIndex(of: ".") else { return nil }
            var timestamp = String(body[..<separator])
            guard timestamp.count > 16 else { return nil }
            for offset in [16, 13] {
                let index = timestamp.index(timestamp.startIndex, offsetBy: offset)
                guard timestamp[index] == "-" else { return nil }
                timestamp.replaceSubrange(index...index, with: ":")
            }
            let suffix = body[body.index(after: separator)...]
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard (suffix.count == 6 || suffix.count == 12), suffix.allSatisfy(\.isNumber),
                  formatter.date(from: timestamp) != nil else { return nil }
            return BackupEntry(url: entry, generation: nil)
        }
    }

    private func v2Generation(in name: String, identity: String) -> UInt64? {
        let prefix = "array-backup-v2-\(identity)-"
        guard name.hasPrefix(prefix) else { return nil }
        let remainder = String(name.dropFirst(prefix.count))
        guard remainder.utf8.count == 45 else { return nil }
        let bytes = Array(remainder.utf8)
        guard bytes[20] == 45, bytes[0..<20].allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        let token = String(decoding: bytes[0..<20], as: UTF8.self)
        let metadata = String(decoding: bytes[21..<45], as: UTF8.self)
        guard isValidBackupTimestamp(metadata) else { return nil }
        return UInt64(token)
    }

    /// Audit seam shared by production checks and backup discovery so callers do
    /// not duplicate the exact identity/grammar parser.
    public func validBackupGeneration(named name: String, for target: URL) -> UInt64? {
        v2Generation(in: name, identity: targetNamespace(for: target))
    }

#if DEBUG
    public func debugBackupGeneration(named name: String, for target: URL) -> UInt64? {
        validBackupGeneration(named: name, for: target)
    }
#endif

    private func isValidBackupTimestamp(_ value: String) -> Bool {
        guard value.utf8.count == 24 else { return false }
        let bytes = Array(value.utf8)
        let separators: [Int: UInt8] = [4:45, 7:45, 10:84, 13:45, 16:45, 19:46, 23:90]
        for index in bytes.indices {
            if let expected = separators[index] { if bytes[index] != expected { return false } }
            else if bytes[index] < 48 || bytes[index] > 57 { return false }
        }
        func number(_ range: Range<Int>) -> Int { range.reduce(0) { $0 * 10 + Int(bytes[$1] - 48) } }
        let year = number(0..<4), month = number(5..<7), day = number(8..<10)
        let leap = year % 400 == 0 || (year % 4 == 0 && year % 100 != 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...12).contains(month), (1...days[month - 1]).contains(day),
              number(11..<13) < 24, number(14..<16) < 60, number(17..<19) < 60 else { return false }
        return true
    }

    private func backupName(for url: URL, at date: Date, generation: UInt64) -> String {
        let identity = targetNamespace(for: url)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
        return "array-backup-v2-\(identity)-\(String(format: "%020llu", generation))-\(iso)"
    }
}

/// POSIX record locks are process-associated on Darwin, so they do not exclude
/// two threads in this process. Pair the cross-process fcntl lock with this
/// canonical-target mutex; both cover the identical complete transaction.
private final class AtomicWriterTargetLocks: @unchecked Sendable {
    static let shared = AtomicWriterTargetLocks()
    final class Entry {
        let lock = NSLock()
        var leases = 0
    }
    private let registryLock = NSLock()
    private var locks: [String: Entry] = [:]

    static func acquire(for path: String) -> Entry { shared.acquire(for: path) }
    static func release(_ entry: Entry, for path: String) { shared.release(entry, for: path) }

    private func acquire(for path: String) -> Entry {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = locks[path] {
            existing.leases += 1
            return existing
        }
        let created = Entry()
        created.leases = 1
        locks[path] = created
        return created
    }

    private func release(_ entry: Entry, for path: String) {
        registryLock.lock()
        defer { registryLock.unlock() }
        precondition(entry.leases > 0)
        entry.leases -= 1
        if entry.leases == 0, locks[path] === entry { locks.removeValue(forKey: path) }
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

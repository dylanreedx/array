import Darwin
import Foundation
import ContinuumRevivedCollaborationProtocol

/// Device-local undo intent. The source project and remote document are never
/// stored here; only portable before/after placements and exact command IDs.
public struct SharedAreaGeometryLedger: Codable, Sendable {
    public let schema: Int
    public let identity: Collaboration.Identity
    public let area: SharedArea.ID<SharedArea.Area>
    public var generation: UInt64
    public var history: SharedAreaGeometryHistory
    public var pending: SharedAreaGeometryHistory.Mutation?
    public init(identity: Collaboration.Identity, area: SharedArea.ID<SharedArea.Area>, history: SharedAreaGeometryHistory = .init()) {
        schema = 1; self.identity = identity; self.area = area; generation = 0; self.history = history; pending = nil
    }
    public func validate() throws {
        guard schema == 1 else { throw SharedAreaLocalStoreError.unsupportedSchema }
        try history.validate(area: area)
        try pending?.validate(area: area)
    }
}

/// Separate atomic generations let the UI retain its inverse BEFORE the data
/// outbox can cause a remote effect. A pending generation is reconciled against
/// the data outbox/authority after relaunch, never inferred from frame equality.
public struct SharedAreaGeometryLedgerStore: Sendable {
    public let directory: URL
    public let file: URL
    public let identity: Collaboration.Identity
    public let area: SharedArea.ID<SharedArea.Area>
    private let backups: URL
    private let lockFile: URL
    private let writer: AtomicWriter
    private let maximumBytes = 64 * 1024 * 1024

    public init(directory: URL, identity: Collaboration.Identity, area: SharedArea.ID<SharedArea.Area>,
                fileOperations: AtomicWriterFileOperations = .live) throws {
        guard directory.isFileURL else { throw SharedAreaLocalStoreError.invalidRoot }
        self.directory = directory.standardizedFileURL; self.identity = identity; self.area = area
        let name = "geometry-" + identity.device.uuidString
        file = self.directory.appendingPathComponent(name + ".json")
        backups = self.directory.appendingPathComponent(name + "-backups", isDirectory: true)
        lockFile = self.directory.appendingPathComponent("." + name + ".guard.lock")
        var secured = fileOperations
        let write = fileOperations.writeTemporary
        secured.writeTemporary = { data, file in
            try write(data, file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        writer = AtomicWriter(backupsDirectory: backups, retainedBackups: 3, fileOperations: secured, legacyBackupPolicy: .disabled)
        try ensureOwnedPath()
    }
    public func load() throws -> SharedAreaGeometryLedger? {
        try ensureOwnedPath()
        guard FileManager.default.fileExists(atPath: file.path) else {
            if FileManager.default.fileExists(atPath: backups.path),
               try !FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).isEmpty {
                throw SharedAreaLocalStoreError.recoveryRequired
            }
            return nil
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= maximumBytes else { throw SharedAreaLocalStoreError.corruptState }
        let value: SharedAreaGeometryLedger
        do { value = try JSONCodec.makeDecoder().decode(SharedAreaGeometryLedger.self, from: Data(contentsOf: file)) }
        catch { throw SharedAreaLocalStoreError.corruptState }
        try value.validate()
        guard value.identity == identity, value.area == area else { throw SharedAreaLocalStoreError.scopeMismatch }
        guard value.generation > 0 else { throw SharedAreaLocalStoreError.invalidState }
        return value
    }
    @discardableResult
    public func save(_ value: SharedAreaGeometryLedger) throws -> SharedAreaGeometryLedger {
        try value.validate()
        guard value.identity == identity, value.area == area else { throw SharedAreaLocalStoreError.scopeMismatch }
        try ensureOwnedPath()
        let fd = Darwin.open(lockFile.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        var result: Int32
        repeat { result = flock(fd, LOCK_EX) } while result != 0 && errno == EINTR
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = flock(fd, LOCK_UN) }
        if let current = try load() {
            guard current.generation == value.generation else { throw SharedAreaLocalStoreError.staleGeneration }
        } else if value.generation != 0 { throw SharedAreaLocalStoreError.staleGeneration }
        guard value.generation < UInt64.max else { throw SharedAreaLocalStoreError.exhaustedGeneration }
        var accepted = value; accepted.generation += 1
        let encoded = try JSONCodec.makeEncoder().encode(accepted)
        guard encoded.count <= maximumBytes else { throw SharedAreaLocalStoreError.invalidState }
        try StoreFileWriter.perform(.write, at: file) { try writer.write(accepted, to: file) }
        return accepted
    }
    private func ensureOwnedPath() throws {
        for path in [directory, file, backups, lockFile] {
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) == nil else { throw SharedAreaLocalStoreError.invalidRoot }
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw SharedAreaLocalStoreError.invalidRoot }
    }
}

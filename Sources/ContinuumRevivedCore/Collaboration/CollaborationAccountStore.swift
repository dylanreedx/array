import Foundation
import Darwin
import ContinuumRevivedCollaborationProtocol

/// A remembered destination is private navigation metadata, never membership.
public struct CollaborationKnownArea: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var label: String
    public init(id: UUID, label: String) { self.id = id; self.label = label }
}

/// No bearer, enrollment code, source project path or provider data belongs here.
public struct CollaborationLocalAccount: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let endpoint: String
    public let identity: Collaboration.Identity
    public var label: String
    public var knownAreas: [CollaborationKnownArea]
    /// Hint from this device's registration; publication still checks the host.
    public var hostID: SharedArea.ID<SharedArea.Host>?

    public init(endpoint: CollaborationServiceEndpoint, identity: Collaboration.Identity, label: String,
                knownAreas: [CollaborationKnownArea] = [], hostID: SharedArea.ID<SharedArea.Host>? = nil) {
        self.id = CollaborationCredentialScope(endpoint: endpoint, identity: identity).storageAccount
        self.endpoint = endpoint.canonicalString; self.identity = identity; self.label = label
        self.knownAreas = knownAreas; self.hostID = hostID
    }
    public var endpointValue: CollaborationServiceEndpoint {
        get throws {
            guard let url = URL(string: endpoint) else { throw CollaborationAccountStoreError.invalidState }
            let value = try CollaborationServiceEndpoint(url, allowsInsecureLoopback: true)
            guard value.canonicalString == endpoint else { throw CollaborationAccountStoreError.invalidState }
            return value
        }
    }
    fileprivate func validate() throws {
        let scope = CollaborationCredentialScope(endpoint: try endpointValue, identity: identity)
        guard id == scope.storageAccount, Self.validLabel(label), knownAreas.count <= 512,
              Set(knownAreas.map(\.id)).count == knownAreas.count,
              knownAreas.allSatisfy({ Self.validLabel($0.label) }) else { throw CollaborationAccountStoreError.invalidState }
    }
    static func validLabel(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 256
            && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }
}

public struct CollaborationAccountRegistry: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    public let schema: Int
    public let channelNamespace: String
    public fileprivate(set) var generation: UInt64
    public var accounts: [CollaborationLocalAccount]
    public var selectedAccountID: String?
    public init(bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        schema = Self.currentSchema
        channelNamespace = AppChannel.bundledDefaultsDomain(bundleIdentifier: bundleIdentifier)
        generation = 0; accounts = []; selectedAccountID = nil
    }
    fileprivate func validate() throws {
        guard schema == Self.currentSchema else { throw CollaborationAccountStoreError.unsupportedSchema }
        guard accounts.count <= 128, Set(accounts.map(\.id)).count == accounts.count,
              selectedAccountID == nil || accounts.contains(where: { $0.id == selectedAccountID }) else {
            throw CollaborationAccountStoreError.invalidState
        }
        for account in accounts { try account.validate() }
    }
    private enum CodingKeys: String, CodingKey { case schema, channelNamespace, generation, accounts, selectedAccountID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        guard schema == Self.currentSchema else { throw CollaborationAccountStoreError.unsupportedSchema }
        channelNamespace = try c.decode(String.self, forKey: .channelNamespace)
        generation = try c.decode(UInt64.self, forKey: .generation)
        guard generation > 0 else { throw CollaborationAccountStoreError.invalidState }
        accounts = try c.decode([CollaborationLocalAccount].self, forKey: .accounts)
        selectedAccountID = try c.decodeIfPresent(String.self, forKey: .selectedAccountID)
        try validate()
    }
}

public enum CollaborationAccountStoreError: Error, Equatable {
    case invalidRoot, invalidState, unsupportedSchema, corruptState, scopeMismatch
    case recoveryRequired, staleGeneration, exhaustedGeneration, tooLarge
}

/// Explicit app-support parent plus channel only. It never uses a source root.
public struct CollaborationAccountStore: Sendable {
    public let applicationSupportRoot: URL
    public let channelNamespace: String
    public let directory: URL
    public var stateFile: URL { directory.appendingPathComponent("accounts.json") }
    public var backupsDirectory: URL { directory.appendingPathComponent("backups", isDirectory: true) }
    private let bundleIdentifier: String?
    private let writer: AtomicWriter
    private static let maximumBytes = 4 * 1024 * 1024

    public init(applicationSupportRoot: URL, bundleIdentifier: String? = Bundle.main.bundleIdentifier,
                fileOperations: AtomicWriterFileOperations = .live) throws {
        guard applicationSupportRoot.isFileURL else { throw CollaborationAccountStoreError.invalidRoot }
        self.applicationSupportRoot = applicationSupportRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.bundleIdentifier = bundleIdentifier
        channelNamespace = AppChannel.bundledDefaultsDomain(bundleIdentifier: bundleIdentifier)
        directory = self.applicationSupportRoot
            .appendingPathComponent(AppChannel.applicationSupportDirectoryName(bundleIdentifier: bundleIdentifier), isDirectory: true)
            .appendingPathComponent("collaboration/account-registry", isDirectory: true)
        var files = fileOperations
        let writeTemporary = files.writeTemporary
        files.writeTemporary = { bytes, file in
            try writeTemporary(bytes, file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        writer = AtomicWriter(backupsDirectory: directory.appendingPathComponent("backups"), fileOperations: files, legacyBackupPolicy: .disabled)
        try ensureOwnedPath()
    }
    public func load() throws -> CollaborationAccountRegistry {
        try ensureOwnedPath()
        guard FileManager.default.fileExists(atPath: stateFile.path) else {
            if FileManager.default.fileExists(atPath: backupsDirectory.path),
               try !FileManager.default.contentsOfDirectory(atPath: backupsDirectory.path).isEmpty {
                throw CollaborationAccountStoreError.recoveryRequired
            }
            return .init(bundleIdentifier: bundleIdentifier)
        }
        let bytes = try Data(contentsOf: stateFile)
        guard bytes.count <= Self.maximumBytes else { throw CollaborationAccountStoreError.tooLarge }
        let registry: CollaborationAccountRegistry
        do { registry = try JSONCodec.makeDecoder().decode(CollaborationAccountRegistry.self, from: bytes) }
        catch CollaborationAccountStoreError.unsupportedSchema { throw CollaborationAccountStoreError.unsupportedSchema }
        catch { throw CollaborationAccountStoreError.corruptState }
        guard registry.channelNamespace == channelNamespace else { throw CollaborationAccountStoreError.scopeMismatch }
        return registry
    }
    @discardableResult
    public func save(_ registry: CollaborationAccountRegistry) throws -> CollaborationAccountRegistry {
        try registry.validate()
        guard registry.channelNamespace == channelNamespace else { throw CollaborationAccountStoreError.scopeMismatch }
        try ensureOwnedPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var path = directory
        while path.path != applicationSupportRoot.path {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
            path.deleteLastPathComponent()
        }
        let lockFile = directory.appendingPathComponent(".accounts.guard.lock")
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: lockFile.path)) == nil else { throw CollaborationAccountStoreError.invalidRoot }
        let fd = Darwin.open(lockFile.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        var locked: Int32
        repeat { locked = flock(fd, LOCK_EX) } while locked != 0 && errno == EINTR
        guard locked == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = flock(fd, LOCK_UN) }
        let prior = try load()
        guard prior.generation == registry.generation else { throw CollaborationAccountStoreError.staleGeneration }
        guard registry.generation < UInt64.max else { throw CollaborationAccountStoreError.exhaustedGeneration }
        var next = registry; next.generation += 1
        guard try JSONCodec.makeEncoder().encode(next).count <= Self.maximumBytes else { throw CollaborationAccountStoreError.tooLarge }
        try StoreFileWriter.perform(.write, at: stateFile) { try writer.write(next, to: stateFile) }
        return next
    }
    private func ensureOwnedPath() throws {
        let root = applicationSupportRoot.path
        var path = directory
        guard path.path.hasPrefix(root + "/") else { throw CollaborationAccountStoreError.invalidRoot }
        for file in [stateFile, backupsDirectory] {
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) == nil else { throw CollaborationAccountStoreError.invalidRoot }
        }
        while path.path != root {
            guard path.path.hasPrefix(root + "/"),
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) == nil else { throw CollaborationAccountStoreError.invalidRoot }
            path.deleteLastPathComponent()
        }
    }
}

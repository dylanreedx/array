import CryptoKit
import Darwin
import Foundation
import ContinuumRevivedCollaborationProtocol

/// These records are local cache/navigation state. They are never authority to
/// read, publish or execute, and the collaboration wire API cannot accept them.
public struct SharedAreaLocalScope: Codable, Equatable, Sendable {
    public let channelNamespace: String
    public let endpoint: String
    public let person: SharedArea.ID<SharedArea.Person>
    public let area: SharedArea.ID<SharedArea.Area>
    public init(endpoint: CollaborationServiceEndpoint, person: SharedArea.ID<SharedArea.Person>, area: SharedArea.ID<SharedArea.Area>, bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        self.channelNamespace = AppChannel.bundledDefaultsDomain(bundleIdentifier: bundleIdentifier)
        self.endpoint = endpoint.canonicalString; self.person = person; self.area = area
    }
}

/// IDs resolve through the explicit local project/agent owner later. This stores
/// neither a checkout root nor an AgentRecord, and constructing it starts nothing.
public struct SharedAreaLocalSourceBinding: Codable, Equatable, Sendable {
    public let object: SharedArea.ID<SharedArea.Object>
    public let binding: SharedArea.ID<SharedArea.Binding>
    public let host: SharedArea.ID<SharedArea.Host>
    public let projectID: UUID
    public let tileID: UUID?
    public let agentID: AgentID?
    public init(object: SharedArea.ID<SharedArea.Object>, binding: SharedArea.ID<SharedArea.Binding>, host: SharedArea.ID<SharedArea.Host>, projectID: UUID, tileID: UUID? = nil, agentID: AgentID? = nil) {
        self.object = object; self.binding = binding; self.host = host
        self.projectID = projectID; self.tileID = tileID; self.agentID = agentID
    }
}

public struct SharedAreaLocalView: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var zoom: Double
    public var focusedObject: SharedArea.ID<SharedArea.Object>?
    public init(x: Double = 0, y: Double = 0, zoom: Double = 1, focusedObject: SharedArea.ID<SharedArea.Object>? = nil) {
        self.x = x; self.y = y; self.zoom = zoom; self.focusedObject = focusedObject
    }
    var valid: Bool { x.isFinite && y.isFinite && zoom.isFinite && zoom > 0 }
}

/// A rejected/conflicting edit stays a private draft. It is not an outbox entry
/// and cannot be submitted or interpreted as an executable request by this store.
public struct SharedAreaLocalDraft: Codable, Equatable, Sendable {
    public let id: UUID
    public var object: SharedArea.ID<SharedArea.Object>?
    public var basedOn: SharedArea.ID<SharedArea.Revision>?
    public var text: String
    public init(id: UUID = UUID(), object: SharedArea.ID<SharedArea.Object>? = nil, basedOn: SharedArea.ID<SharedArea.Revision>? = nil, text: String) {
        self.id = id; self.object = object; self.basedOn = basedOn; self.text = text
    }
}

public enum SharedAreaLocalResolution: Equatable, Sendable {
    case localReference(SharedAreaLocalSourceBinding)
    case remoteSource(SharedArea.Source)
    case sharedContent(SharedArea.Kind)
    case unavailable
}

public struct SharedAreaLocalState: Codable, Equatable, Sendable {
    public static let currentSchema = 3
    public let schema: Int
    public let scope: SharedAreaLocalScope
    /// Optimistic local concurrency token, independent of the server revision.
    /// A successful save returns a new state carrying its accepted generation.
    public fileprivate(set) var localGeneration: UInt64
    public var document: SharedArea.Document
    /// Last observed value, never a reusable grant or an offline execution right.
    public var observedMembershipEpoch: Int64
    public var sourceBindings: [SharedAreaLocalSourceBinding]
    public var view: SharedAreaLocalView
    public var drafts: [SharedAreaLocalDraft]
    /// Confirmed loss of online access suppresses cached content on reopening.
    /// This is a UI/recovery marker, never authority to submit or read remotely.
    public var accessDenied: Bool
    /// Exact document intents and final receipts, private to this local person/area.
    public var operations: [SharedAreaPendingOperation]

    public init(scope: SharedAreaLocalScope, document: SharedArea.Document, observedMembershipEpoch: Int64,
                sourceBindings: [SharedAreaLocalSourceBinding] = [], view: SharedAreaLocalView = .init(), drafts: [SharedAreaLocalDraft] = [], accessDenied: Bool = false, operations: [SharedAreaPendingOperation] = []) {
        schema = Self.currentSchema; self.scope = scope; self.localGeneration = 0; self.document = document
        self.observedMembershipEpoch = observedMembershipEpoch; self.sourceBindings = sourceBindings
        self.view = view; self.drafts = drafts; self.accessDenied = accessDenied; self.operations = operations
    }
    public var appliedRevision: UInt64 { document.revision }
    public func resolution(for object: SharedArea.ID<SharedArea.Object>) -> SharedAreaLocalResolution {
        guard let item = document.items.first(where: { $0.id == object }) else { return .unavailable }
        if let binding = sourceBindings.first(where: { $0.object == object }) {
            guard let source = item.source, source.owner == scope.person,
                  source.binding == binding.binding, source.host == binding.host,
                  item.kind != .agentObservation || binding.agentID != nil else { return .unavailable }
            return .localReference(binding)
        }
        if let source = item.source { return .remoteSource(source) }
        return .sharedContent(item.kind)
    }
    public func validate() throws {
        guard schema == Self.currentSchema else { throw SharedAreaLocalStoreError.unsupportedSchema }
        guard scope.area == document.id, observedMembershipEpoch > 0, view.valid else { throw SharedAreaLocalStoreError.invalidState }
        guard Set(sourceBindings.map(\.object)).count == sourceBindings.count,
              Set(drafts.map(\.id)).count == drafts.count else { throw SharedAreaLocalStoreError.invalidState }
        guard Set(operations.map { $0.command.id }).count == operations.count,
              operations.filter(\.isPending).count <= 64,
              operations.filter({ !$0.isPending }).count <= 64 else { throw SharedAreaLocalStoreError.invalidState }
        for operation in operations {
            try operation.validate(scope: scope)
            guard operation.sourceBindings.allSatisfy({ sourceBindings.contains($0) }) else { throw SharedAreaLocalStoreError.invalidState }
            if case .accepted(let revision) = operation.state {
                var probe = document
                guard try probe.apply(operation.command) == .duplicate(revision) else { throw SharedAreaLocalStoreError.invalidState }
            }
        }
        guard try JSONEncoder().encode(operations).count <= 16 * 1024 * 1024 else { throw SharedAreaLocalStoreError.invalidState }
        for binding in sourceBindings {
            // Retain a missing source reference for honest unavailable/recovery UI.
            guard let item = document.items.first(where: { $0.id == binding.object }) else { continue }
            guard let source = item.source, source.owner == scope.person,
                  source.binding == binding.binding, source.host == binding.host,
                  item.kind != .agentObservation || binding.agentID != nil else { throw SharedAreaLocalStoreError.invalidState }
        }
    }
    private enum CodingKeys: String, CodingKey {
        case schema, scope, localGeneration, document, observedMembershipEpoch, sourceBindings, view, drafts, accessDenied, operations
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let storedSchema = try c.decode(Int.self, forKey: .schema)
        guard storedSchema == 2 || storedSchema == Self.currentSchema else { throw SharedAreaLocalStoreError.unsupportedSchema }
        // Migration is in memory until the next atomic successful save. Original
        // v2 bytes/backups stay intact on any future decode/write failure.
        schema = Self.currentSchema
        scope = try c.decode(SharedAreaLocalScope.self, forKey: .scope)
        localGeneration = try c.decode(UInt64.self, forKey: .localGeneration)
        guard localGeneration > 0 else { throw SharedAreaLocalStoreError.invalidState }
        document = try c.decode(SharedArea.Document.self, forKey: .document)
        observedMembershipEpoch = try c.decode(Int64.self, forKey: .observedMembershipEpoch)
        sourceBindings = try c.decode([SharedAreaLocalSourceBinding].self, forKey: .sourceBindings)
        view = try c.decode(SharedAreaLocalView.self, forKey: .view)
        drafts = try c.decode([SharedAreaLocalDraft].self, forKey: .drafts)
        accessDenied = try c.decodeIfPresent(Bool.self, forKey: .accessDenied) ?? false
        if storedSchema == 2 {
            guard !c.contains(.operations) else { throw SharedAreaLocalStoreError.invalidState }
            operations = []
        } else {
            // A current record missing its outbox is corrupt, not an empty
            // queue. Do not silently erase delivery recovery on partial edits.
            operations = try c.decode([SharedAreaPendingOperation].self, forKey: .operations)
        }
        try validate()
    }
}

public enum SharedAreaLocalStoreError: Error, Equatable {
    case invalidRoot, unsupportedSchema, invalidState, scopeMismatch
    case corruptState, recoveryRequired, staleState, conflictingDocument
    case staleGeneration, exhaustedGeneration
}

public struct SharedAreaLocalStoreLayout: Sendable {
    /// Explicit injected parent of the Array / Array Dev channel directory.
    public let applicationSupportRoot: URL
    public let channelDirectory: URL
    public let areaDirectory: URL
    public var stateFile: URL { areaDirectory.appendingPathComponent("state.json") }
    public var backupsDirectory: URL { areaDirectory.appendingPathComponent("backups", isDirectory: true) }
}

/// No default filesystem root: integration must explicitly provide app support,
/// never a project root. This cache cannot write the source project's .array.
public struct SharedAreaLocalStore: Sendable {
    public let scope: SharedAreaLocalScope
    public let layout: SharedAreaLocalStoreLayout
    private let writer: AtomicWriter

    public init(applicationSupportRoot: URL, bundleIdentifier: String? = Bundle.main.bundleIdentifier,
                endpoint: CollaborationServiceEndpoint, person: SharedArea.ID<SharedArea.Person>, area: SharedArea.ID<SharedArea.Area>,
                retainedBackups: Int = 3, descriptorOperations: AtomicWriterDescriptorOperations = .live,
                fileOperations: AtomicWriterFileOperations = .live) throws {
        guard applicationSupportRoot.isFileURL else { throw SharedAreaLocalStoreError.invalidRoot }
        scope = .init(endpoint: endpoint, person: person, area: area, bundleIdentifier: bundleIdentifier)
        let root = applicationSupportRoot.standardizedFileURL.resolvingSymlinksInPath()
        let channel = root.appendingPathComponent(AppChannel.applicationSupportDirectoryName(bundleIdentifier: bundleIdentifier), isDirectory: true)
        let endpointKey = SHA256.hash(data: Data(endpoint.canonicalString.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = channel.appendingPathComponent("collaboration", isDirectory: true)
            .appendingPathComponent(endpointKey, isDirectory: true)
            .appendingPathComponent(person.rawValue.uuidString, isDirectory: true)
            .appendingPathComponent(area.rawValue.uuidString, isDirectory: true)
        layout = .init(applicationSupportRoot: root, channelDirectory: channel, areaDirectory: directory)
        var securedFiles = fileOperations
        let writeTemporary = fileOperations.writeTemporary
        securedFiles.writeTemporary = { data, file in
            try writeTemporary(data, file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        writer = AtomicWriter(backupsDirectory: layout.backupsDirectory, retainedBackups: retainedBackups,
            descriptorOperations: descriptorOperations, fileOperations: securedFiles, legacyBackupPolicy: .disabled)
        try ensureOwnedPath()
    }
    public func load() throws -> SharedAreaLocalState? {
        try ensureOwnedPath()
        guard FileManager.default.fileExists(atPath: layout.stateFile.path) else {
            if try hasBackups() { throw SharedAreaLocalStoreError.recoveryRequired }
            return nil
        }
        let state: SharedAreaLocalState
        do { state = try JSONCodec.makeDecoder().decode(SharedAreaLocalState.self, from: Data(contentsOf: layout.stateFile)) }
        catch SharedAreaLocalStoreError.unsupportedSchema { throw SharedAreaLocalStoreError.unsupportedSchema }
        catch { throw SharedAreaLocalStoreError.corruptState }
        guard state.scope == scope else { throw SharedAreaLocalStoreError.scopeMismatch }
        return state
    }
    /// Carry the returned state forward after every accepted local mutation.
    /// A stale generation refuses even when both callers saw the same server
    /// revision, so an incoming snapshot or view save cannot erase another draft.
    @discardableResult
    public func save(_ state: SharedAreaLocalState) throws -> SharedAreaLocalState {
        try state.validate()
        guard state.scope == scope else { throw SharedAreaLocalStoreError.scopeMismatch }
        try ensureOwnedPath()
        return try withCommitLock {
            if let prior = try load() {
                guard state.localGeneration == prior.localGeneration else { throw SharedAreaLocalStoreError.staleGeneration }
                guard state.appliedRevision >= prior.appliedRevision,
                      state.observedMembershipEpoch >= prior.observedMembershipEpoch else { throw SharedAreaLocalStoreError.staleState }
                if state.appliedRevision == prior.appliedRevision,
                   try state.document.canonicalData() != prior.document.canonicalData() { throw SharedAreaLocalStoreError.conflictingDocument }
            } else {
                guard state.localGeneration == 0 else { throw SharedAreaLocalStoreError.staleGeneration }
            }
            guard state.localGeneration < UInt64.max else { throw SharedAreaLocalStoreError.exhaustedGeneration }
            var accepted = state
            accepted.localGeneration += 1
            // State and its applied cursor are one atomic generation. A pointer
            // or binding cannot advance a separate uncommitted cursor.
            try StoreFileWriter.perform(.write, at: layout.stateFile) {
                try writer.write(accepted, to: layout.stateFile)
            }
            return accepted
        }
    }
    private func withCommitLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: layout.areaDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try restrictPermissions()
        let lockFile = layout.areaDirectory.appendingPathComponent(".state.guard.lock")
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: lockFile.path)) == nil else { throw SharedAreaLocalStoreError.invalidRoot }
        let fd = Darwin.open(lockFile.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        var result: Int32
        repeat { result = flock(fd, LOCK_EX) } while result != 0 && errno == EINTR
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }
    private func hasBackups() throws -> Bool {
        guard FileManager.default.fileExists(atPath: layout.backupsDirectory.path) else { return false }
        return try !FileManager.default.contentsOfDirectory(at: layout.backupsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).isEmpty
    }
    private func ensureOwnedPath() throws {
        let root = layout.applicationSupportRoot.path
        guard layout.areaDirectory.path.hasPrefix(root + "/") else { throw SharedAreaLocalStoreError.invalidRoot }
        var current = layout.areaDirectory
        let protected = [layout.stateFile, layout.backupsDirectory]
        for file in protected where (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil {
            throw SharedAreaLocalStoreError.invalidRoot
        }
        while current.path != root {
            guard current.path.hasPrefix(root + "/"),
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) == nil else { throw SharedAreaLocalStoreError.invalidRoot }
            current.deleteLastPathComponent()
        }
    }
    private func restrictPermissions() throws {
        var directory = layout.areaDirectory
        while directory.path != layout.applicationSupportRoot.path {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            directory.deleteLastPathComponent()
        }
    }
}

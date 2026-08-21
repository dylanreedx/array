import ContinuumRevivedAgentContent
import Foundation

public enum AgentTranscriptStoreError: Error, Equatable, Sendable {
    case identityMismatch
    case versionMismatch(expected: UInt64, actual: UInt64)
}

public struct AgentTranscriptArchive: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var agentID: AgentID
    public var sessionID: String
    public var document: AgentDocument
    public var savedAt: Date

    public init(agentID: AgentID, sessionID: String, document: AgentDocument, savedAt: Date = Date()) {
        schemaVersion = Self.currentSchemaVersion
        self.agentID = agentID
        self.sessionID = sessionID
        self.document = document
        self.savedAt = savedAt
    }
}

public struct AgentTranscriptJournal: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var agentID: AgentID
    public var sessionID: String
    public var baseVersion: UInt64
    public var mutations: [AgentDocumentMutation]

    public init(agentID: AgentID, sessionID: String, baseVersion: UInt64, mutations: [AgentDocumentMutation] = []) {
        schemaVersion = Self.currentSchemaVersion
        self.agentID = agentID
        self.sessionID = sessionID
        self.baseVersion = baseVersion
        self.mutations = mutations
    }
}

/// Durable semantic transcript storage. The snapshot and journal are written
/// atomically and can be recovered independently from their retained backups.
/// Host-local tool capabilities never enter either file because the store accepts
/// only the portable AgentContent vocabulary.
public actor AgentTranscriptStore {
    public static let defaultCompactionMutationCount = 128

    private let root: URL
    private let compactionMutationCount: Int

    public init(root: URL, compactionMutationCount: Int = defaultCompactionMutationCount) {
        self.root = root
        self.compactionMutationCount = max(1, compactionMutationCount)
    }

    public func saveSnapshot(
        agentID: AgentID,
        sessionID: String,
        document: AgentDocument,
        at date: Date = Date()
    ) throws {
        let writer = writer(agentID: agentID, sessionID: sessionID)
        try document.validateIdentityInvariants()
        try writer.write(
            AgentTranscriptArchive(agentID: agentID, sessionID: sessionID, document: document, savedAt: date),
            to: snapshotURL(agentID: agentID, sessionID: sessionID)
        )
        try writer.write(
            AgentTranscriptJournal(agentID: agentID, sessionID: sessionID, baseVersion: document.version),
            to: journalURL(agentID: agentID, sessionID: sessionID)
        )
    }

    /// Append one semantic mutation after validating it against recovered truth.
    /// The journal is compacted into a fresh snapshot after the configured bound.
    @discardableResult
    public func append(
        _ mutation: AgentDocumentMutation,
        agentID: AgentID,
        sessionID: String
    ) throws -> AgentDocument {
        var recovered = try load(agentID: agentID, sessionID: sessionID) ?? AgentDocument()
        var reducer = AgentDocumentReducer(document: recovered)
        _ = try reducer.apply(mutation)
        recovered = reducer.document

        let url = journalURL(agentID: agentID, sessionID: sessionID)
        let writer = writer(agentID: agentID, sessionID: sessionID)
        let existingJournal: AgentTranscriptJournal? = try? writer.read(at: url)
        var journal = existingJournal
            ?? AgentTranscriptJournal(agentID: agentID, sessionID: sessionID, baseVersion: recovered.version - 1)
        guard journal.agentID == agentID, journal.sessionID == sessionID else {
            throw AgentTranscriptStoreError.identityMismatch
        }
        journal.mutations.append(mutation)
        try writer.write(journal, to: url)

        if journal.mutations.count >= compactionMutationCount {
            try saveSnapshot(agentID: agentID, sessionID: sessionID, document: recovered)
        }
        return recovered
    }

    /// Recover the newest valid snapshot and replay the longest valid journal
    /// prefix. A torn or invalid final mutation is ignored; prior history remains.
    public func load(agentID: AgentID, sessionID: String) throws -> AgentDocument? {
        let writer = writer(agentID: agentID, sessionID: sessionID)
        let archive: AgentTranscriptArchive? = try? writer.read(
            at: snapshotURL(agentID: agentID, sessionID: sessionID)
        )
        let journal: AgentTranscriptJournal? = try? writer.read(
            at: journalURL(agentID: agentID, sessionID: sessionID)
        )
        guard archive != nil || journal != nil else { return nil }
        if let archive, archive.agentID != agentID || archive.sessionID != sessionID {
            throw AgentTranscriptStoreError.identityMismatch
        }
        if let journal, journal.agentID != agentID || journal.sessionID != sessionID {
            throw AgentTranscriptStoreError.identityMismatch
        }

        let base = archive?.document ?? AgentDocument(version: journal?.baseVersion ?? 0)
        if let journal, journal.baseVersion != base.version {
            // A snapshot compaction may have landed before journal reset. The
            // snapshot is authoritative and complete in that crash window.
            return base
        }
        var reducer = AgentDocumentReducer(document: base)
        for mutation in journal?.mutations ?? [] {
            do { _ = try reducer.apply(mutation) }
            catch { break }
        }
        return reducer.document
    }

    public func remove(agentID: AgentID, sessionID: String) throws {
        let url = directory(agentID: agentID, sessionID: sessionID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func writer(agentID: AgentID, sessionID: String) -> AtomicWriter {
        AtomicWriter(
            backupsDirectory: directory(agentID: agentID, sessionID: sessionID)
                .appendingPathComponent("backups", isDirectory: true),
            retainedBackups: 2,
            prettyPrint: false)
    }

    private func snapshotURL(agentID: AgentID, sessionID: String) -> URL {
        directory(agentID: agentID, sessionID: sessionID).appendingPathComponent("snapshot.json")
    }

    private func journalURL(agentID: AgentID, sessionID: String) -> URL {
        directory(agentID: agentID, sessionID: sessionID).appendingPathComponent("journal.json")
    }

    private func directory(agentID: AgentID, sessionID: String) -> URL {
        root.appendingPathComponent(agentID.rawValue.uuidString, isDirectory: true)
            .appendingPathComponent(Self.sessionKey(sessionID), isDirectory: true)
    }

    private static func sessionKey(_ value: String) -> String {
        // FNV-1a keeps provider session text out of filesystem paths while
        // remaining deterministic across launches.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

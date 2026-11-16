import ContinuumRevivedAgentContent
import Foundation

public enum AgentTranscriptStoreError: Error, Equatable, Sendable {
    case identityMismatch
    case versionMismatch(expected: UInt64, actual: UInt64)
    case incompleteReleasedSnapshot
    case unownedArchive
}

public struct AgentTranscriptArchive: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var agentID: AgentID
    public var sessionID: String
    public var document: AgentDocument
    public var savedAt: Date
    /// Identifies one completed snapshot save, including across equal versions.
    /// Older archives predate this field and decode it as nil.
    public var saveGeneration: UUID?

    public init(agentID: AgentID, sessionID: String, document: AgentDocument, savedAt: Date = Date(), saveGeneration: UUID? = nil) {
        schemaVersion = Self.currentSchemaVersion
        self.agentID = agentID
        self.sessionID = sessionID
        self.document = document
        self.savedAt = savedAt
        self.saveGeneration = saveGeneration
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
    private let afterSnapshotWriteForQA: (@Sendable () throws -> Void)?

    public init(root: URL, compactionMutationCount: Int = defaultCompactionMutationCount,
                afterSnapshotWriteForQA: (@Sendable () throws -> Void)? = nil) {
        self.root = root
        self.compactionMutationCount = max(1, compactionMutationCount)
        self.afterSnapshotWriteForQA = afterSnapshotWriteForQA
    }

    /// The ONE storage key for an agent's transcript.
    ///
    /// It used to be the TILE's thread id (`"managed-<tileId>"`), which is not
    /// merely unreadable but UNSTABLE: revealing an existing agent mints a fresh
    /// tile id, so every reveal orphaned the previous directory and the agent
    /// appeared to lose its history. The reader, meanwhile, asked for the literal
    /// `"thread-main"` and therefore never found anything at all.
    ///
    /// A transcript belongs to the AGENT; a tile is one view of it. This is
    /// deliberately the same string `AgentSupervisor.sessionId(for:)` hands pi as
    /// `--session-id`, and that function now calls this one so the two cannot
    /// drift apart into two names for one conversation.
    public nonisolated static func canonicalSessionID(for agentID: AgentID) -> String {
        "array-agent-\(agentID.rawValue.uuidString)"
    }

    @discardableResult
    public func saveSnapshot(
        agentID: AgentID,
        sessionID: String,
        document: AgentDocument,
        at date: Date = Date()
    ) throws -> UUID {
        let writer = writer(agentID: agentID, sessionID: sessionID)
        let generation = UUID()
        try document.validateIdentityInvariants()
        try writer.write(
            AgentTranscriptArchive(agentID: agentID, sessionID: sessionID, document: document, savedAt: date, saveGeneration: generation),
            to: snapshotURL(agentID: agentID, sessionID: sessionID)
        )
        try afterSnapshotWriteForQA?()
        try writer.write(
            AgentTranscriptJournal(agentID: agentID, sessionID: sessionID, baseVersion: document.version),
            to: journalURL(agentID: agentID, sessionID: sessionID)
        )
        return generation
    }

    /// Save a supervisor projection only if this process can prove which
    /// archive it is extending. A restored provider transcript may be bounded
    /// and must never replace a richer or unreadable canonical archive.
    public func saveGuardedSnapshot(
        agentID: AgentID, sessionID: String, document: AgentDocument,
        expectedVersion: UInt64?, expectedGeneration: UUID?
    ) throws -> UUID {
        switch (expectedVersion, expectedGeneration) {
        case let (version?, generation?):
            _ = try loadReleased(agentID: agentID, sessionID: sessionID,
                                 expectedVersion: version, expectedGeneration: generation)
        case (nil, nil):
            // Check the agent directory, not just the canonical session: an
            // older session directory may still be awaiting startup migration.
            let url = root.appendingPathComponent(agentID.rawValue.uuidString, isDirectory: true)
            do {
                // Backups and unrecognized files count too: absence cannot be
                // inferred from an unreadable snapshot or journal.
                guard try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty else {
                    throw AgentTranscriptStoreError.unownedArchive
                }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && error.code == NSFileReadNoSuchFileError {
                // No agent directory: this is the first archive.
            }
        default:
            throw AgentTranscriptStoreError.unownedArchive
        }
        return try saveSnapshot(agentID: agentID, sessionID: sessionID, document: document)
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

    /// Reload a document released by this process only when its complete saved
    /// snapshot is still recoverable. Unlike a general archive read, release
    /// follows a successful `saveSnapshot`: its snapshot and empty journal must
    /// both name the exact version released. A journal without its snapshot is
    /// not a replacement for that snapshot, even if it decodes successfully.
    public func loadReleased(agentID: AgentID, sessionID: String, expectedVersion: UInt64, expectedGeneration: UUID) throws -> AgentDocument {
        // The normal reader may recover an older backup after a primary read
        // fails. That is useful for display but cannot prove that replacing the
        // primary preserves its newest history.
        let decoder = JSONCodec.makeDecoder()
        guard let snapshot = try? Data(contentsOf: snapshotURL(agentID: agentID, sessionID: sessionID)),
              let journalData = try? Data(contentsOf: journalURL(agentID: agentID, sessionID: sessionID)),
              let archive = try? decoder.decode(AgentTranscriptArchive.self, from: snapshot),
              let journal = try? decoder.decode(AgentTranscriptJournal.self, from: journalData) else {
            throw AgentTranscriptStoreError.incompleteReleasedSnapshot
        }
        guard archive.agentID == agentID, archive.sessionID == sessionID,
              journal.agentID == agentID, journal.sessionID == sessionID else {
            throw AgentTranscriptStoreError.identityMismatch
        }
        guard archive.saveGeneration == expectedGeneration, archive.document.version == expectedVersion, journal.baseVersion == expectedVersion,
              journal.mutations.isEmpty else {
            throw AgentTranscriptStoreError.incompleteReleasedSnapshot
        }
        try archive.document.validateIdentityInvariants()
        return archive.document
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
            prettyPrint: false,
            legacyBackupPolicy: .targetDedicated)
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

    // MARK: - Migration to the canonical key

    public struct MigrationReport: Equatable, Sendable {
        /// Agents whose one legacy directory was adopted under the canonical key.
        public var adopted: [AgentID] = []
        /// Agents that already stored under the canonical key; nothing moved.
        public var alreadyCanonical: [AgentID] = []
        /// Agents where several legacy directories existed: the newest by its own
        /// `savedAt` won and this many were quarantined rather than deleted.
        public var quarantined: [AgentID: Int] = [:]
        /// Directories that could not be read at all; left exactly as they were.
        public var skipped: [String] = []

        public init() {}
    }

    /// Adopts pre-2026-08-24 per-tile transcript directories under
    /// `canonicalSessionID(for:)`. **Migrates, never wipes**, and is idempotent:
    /// running it twice reports the second run as `alreadyCanonical`.
    ///
    /// The legacy session id is read out of the archive itself rather than
    /// reverse-engineered from the directory name, because the name is an FNV-1a
    /// hash and is not invertible. Recovery goes through the ordinary `load`,
    /// so an uncompacted journal's mutations survive the move; the document is
    /// then written afresh under the canonical key. That also rewrites the
    /// `sessionID` field INSIDE both files, without which `load` would refuse the
    /// migrated transcript with `identityMismatch` — a rename alone is not a
    /// migration here.
    @discardableResult
    public func migrateLegacySessionDirectories() throws -> MigrationReport {
        var report = MigrationReport()
        let manager = FileManager.default
        guard let agentDirs = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return report }

        for agentDir in agentDirs {
            guard (try? agentDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let uuid = UUID(uuidString: agentDir.lastPathComponent)
            else { continue }
            let agentID = AgentID(rawValue: uuid)
            let canonical = Self.sessionKey(Self.canonicalSessionID(for: agentID))
            guard let sessionDirs = try? manager.contentsOfDirectory(
                at: agentDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else {
                report.skipped.append(agentDir.lastPathComponent)
                continue
            }
            let legacy = sessionDirs.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    && $0.lastPathComponent != canonical
                    && !$0.lastPathComponent.hasPrefix("quarantine-")
            }
            let hasCanonical = sessionDirs.contains { $0.lastPathComponent == canonical }
            if legacy.isEmpty {
                if hasCanonical { report.alreadyCanonical.append(agentID) }
                continue
            }

            // Newest first, by the archive's OWN `savedAt` rather than by file
            // mtime: a backup rewrite touches the file without advancing the
            // conversation, and the newest conversation is the one to keep.
            let dated: [(url: URL, archive: AgentTranscriptArchive)] = legacy.compactMap { url in
                let reader = AtomicWriter(
                    backupsDirectory: url.appendingPathComponent("backups", isDirectory: true),
                    retainedBackups: 2,
                    prettyPrint: false)
                guard let archive: AgentTranscriptArchive = try? reader.read(
                    at: url.appendingPathComponent("snapshot.json"))
                else { return nil }
                return (url, archive)
            }.sorted { $0.archive.savedAt > $1.archive.savedAt }

            guard let winner = dated.first, !hasCanonical else {
                // Either nothing readable, or a canonical transcript already
                // exists and wins by construction. Quarantine, never delete: a
                // transcript is the user's own record of their work.
                var count = 0
                for url in legacy {
                    let destination = agentDir.appendingPathComponent(
                        "quarantine-\(url.lastPathComponent)", isDirectory: true)
                    guard (try? manager.moveItem(at: url, to: destination)) != nil else { continue }
                    count += 1
                }
                if count > 0 { report.quarantined[agentID] = count }
                if hasCanonical { report.alreadyCanonical.append(agentID) }
                continue
            }

            let recovered = (try? load(agentID: agentID, sessionID: winner.archive.sessionID))
                ?? winner.archive.document
            try saveSnapshot(
                agentID: agentID,
                sessionID: Self.canonicalSessionID(for: agentID),
                document: recovered
            )
            report.adopted.append(agentID)
            var quarantinedCount = 0
            for entry in dated.dropFirst() {
                let destination = agentDir.appendingPathComponent(
                    "quarantine-\(entry.url.lastPathComponent)", isDirectory: true)
                guard (try? manager.moveItem(at: entry.url, to: destination)) != nil else { continue }
                quarantinedCount += 1
            }
            if quarantinedCount > 0 { report.quarantined[agentID] = quarantinedCount }
            try? manager.removeItem(at: winner.url)
        }
        return report
    }

    // MARK: - Archive (C4)

    /// A deleted agent's whole transcript directory (every session under it),
    /// moved aside rather than removed. Same rule the migration above already
    /// follows: **a transcript is the user's own record of their work**, and an
    /// `AgentSupervisor.archive` is a person deleting the AGENT, not asking for
    /// its history to disappear too. Quarantining beside `migrateLegacySessionDirectories`'s
    /// own `quarantine-` directories means one cleanup sweep can find both kinds
    /// later; nothing reads them back today.
    ///
    /// Returns `false` (no-op) when the agent has no transcript directory —
    /// true for a tile-less child that was archived before its first save, and
    /// harmless if this is ever called twice for the same agent id (a UUID is
    /// not recycled, so a second call simply finds nothing to move).
    @discardableResult
    public func quarantineTranscript(agentID: AgentID) -> Bool {
        let manager = FileManager.default
        let source = root.appendingPathComponent(agentID.rawValue.uuidString, isDirectory: true)
        guard manager.fileExists(atPath: source.path) else { return false }
        let destination = root.appendingPathComponent(
            "quarantine-\(agentID.rawValue.uuidString)", isDirectory: true)
        return (try? manager.moveItem(at: source, to: destination)) != nil
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

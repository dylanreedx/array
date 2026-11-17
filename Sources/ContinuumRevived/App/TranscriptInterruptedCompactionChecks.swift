import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// Verify the crash window where compaction replaced its snapshot but did not
/// reset the old-base journal. A backup plus the complete journal must prove
/// exactly the current primary before it can be extended.
@MainActor
enum TranscriptInterruptedCompactionChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    private final class SnapshotFault: @unchecked Sendable {
        private let lock = NSLock()
        private var enabled = false
        func arm() { lock.lock(); enabled = true; lock.unlock() }
        func throwIfArmed() throws {
            lock.lock()
            let shouldThrow = enabled
            lock.unlock()
            if shouldThrow { throw CocoaError(.fileWriteUnknown) }
        }
    }

    private struct Interrupted {
        let root: URL
        let id: AgentID
        let session: String
        let snapshot: URL
        let journal: URL
        let backups: URL
        let primary: AgentTranscriptArchive
    }

    private static func interrupted(root: URL, name: String, ambiguousBase: Bool = false) async throws -> Interrupted {
        let directory = root.appendingPathComponent("compaction-\(name)", isDirectory: true)
        let fault = SnapshotFault()
        let writer = AgentTranscriptStore(root: directory, compactionMutationCount: 2,
                                          afterSnapshotWriteForQA: { try fault.throwIfArmed() })
        let id = AgentID(rawValue: UUID())
        let session = AgentTranscriptStore.canonicalSessionID(for: id)
        guard let entry = AgentNodeID(rawValue: "compaction-\(name)-entry") else {
            throw Failure(description: "compaction fixture entry ID was invalid")
        }
        if ambiguousBase {
            guard let other = AgentNodeID(rawValue: "compaction-ambiguous-old-entry") else {
                throw Failure(description: "ambiguous fixture ID was invalid")
            }
            let different = AgentDocument(version: 0, entries: [AgentEntry(
                id: other, role: .user, provenance: .localPrompt(promptID: "older"), lifecycle: .finished)])
            try await writer.saveSnapshot(agentID: id, sessionID: session, document: different)
        }
        try await writer.saveSnapshot(agentID: id, sessionID: session, document: AgentDocument())
        fault.arm()
        try await writer.append(.beginEntry(id: entry, role: .assistant,
                                            provenance: .providerItem(provider: "fixture", itemID: "item")),
                                agentID: id, sessionID: session)
        do {
            try await writer.append(.appendMarkup(entryID: entry, delta: "COMPACTION_PRIOR_HISTORY"),
                                    agentID: id, sessionID: session)
            throw Failure(description: "compaction fault did not interrupt snapshot/journal reset")
        } catch is Failure {
            throw Failure(description: "compaction fault did not interrupt snapshot/journal reset")
        } catch {
            // The snapshot landed; the fault deliberately prevents journal reset.
        }
        let agentDirectory = directory.appendingPathComponent(id.rawValue.uuidString)
        guard let enumerator = FileManager.default.enumerator(at: agentDirectory, includingPropertiesForKeys: nil),
              let snapshot = enumerator.allObjects.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "snapshot.json" }) else {
            throw Failure(description: "interrupted compaction snapshot was missing")
        }
        let journal = snapshot.deletingLastPathComponent().appendingPathComponent("journal.json")
        let backups = snapshot.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        let decoder = JSONCodec.makeDecoder()
        let archive = try decoder.decode(AgentTranscriptArchive.self, from: Data(contentsOf: snapshot))
        let oldJournal = try decoder.decode(AgentTranscriptJournal.self, from: Data(contentsOf: journal))
        guard archive.agentID == id, archive.sessionID == session,
              archive.document.version != oldJournal.baseVersion, oldJournal.mutations.count == 2,
              !archive.document.entries.isEmpty,
              FileManager.default.fileExists(atPath: backups.path) else {
            throw Failure(description: "compaction fault did not establish a mismatched primary pair with backup")
        }
        return Interrupted(root: directory, id: id, session: session, snapshot: snapshot,
                           journal: journal, backups: backups, primary: archive)
    }

    private static func mustRefuse(_ store: AgentTranscriptStore, _ fixture: Interrupted, reason: String) async throws {
        let snapshotBytes = try Data(contentsOf: fixture.snapshot)
        let journalBytes = try Data(contentsOf: fixture.journal)
        do {
            _ = try await store.preflightGuardedArchive(agentID: fixture.id, sessionID: fixture.session)
            throw Failure(description: "ambiguous interrupted compaction was accepted: \(reason)")
        } catch let error as Failure { throw error }
        catch { }
        guard try Data(contentsOf: fixture.snapshot) == snapshotBytes,
              try Data(contentsOf: fixture.journal) == journalBytes else {
            throw Failure(description: "refusing \(reason) modified a primary archive")
        }
    }

    static func run(root: URL) async throws {
        let positive = try await interrupted(root: root, name: "positive")
        let store = AgentTranscriptStore(root: positive.root)
        guard case let .present(recovered, proof) = try await store.preflightGuardedArchive(agentID: positive.id, sessionID: positive.session),
              recovered == positive.primary.document else {
            throw Failure(description: "verified interrupted compaction did not recover the primary document")
        }
        let originalText = recovered.entries.map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
        guard originalText.contains("COMPACTION_PRIOR_HISTORY") else {
            throw Failure(description: "compaction recovery lost prior content")
        }
        var continuation = ManagedAgentTranscriptModel(threadId: AgentSupervisor.threadId(for: positive.id),
                                                       resuming: recovered, status: .idle, finalAssistantSource: nil)
        continuation.appendUserPrompt("NEW_AFTER_INTERRUPTED_COMPACTION")
        _ = try await store.saveGuardedSnapshot(agentID: positive.id, sessionID: positive.session, document: continuation.document,
                                                expectedVersion: nil, expectedGeneration: nil,
                                                expectedArchiveProof: proof, protectedPrefixCount: recovered.entries.count)
        guard let persisted = try await store.load(agentID: positive.id, sessionID: positive.session),
              Array(persisted.entries.prefix(recovered.entries.count)) == recovered.entries else {
            throw Failure(description: "guarded write after compaction did not preserve the recovered prefix")
        }
        let savedText = persisted.entries.map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
        guard savedText.contains("COMPACTION_PRIOR_HISTORY"), savedText.contains("NEW_AFTER_INTERRUPTED_COMPACTION") else {
            throw Failure(description: "guarded write after compaction lost prior or new content")
        }

        let noBackup = try await interrupted(root: root, name: "missing-backup")
        try FileManager.default.removeItem(at: noBackup.backups)
        try await mustRefuse(AgentTranscriptStore(root: noBackup.root), noBackup, reason: "missing base snapshot")

        let mismatched = try await interrupted(root: root, name: "mismatched-snapshot")
        var altered = mismatched.primary
        guard let priorEntry = altered.document.entries.first else { throw Failure(description: "mismatch fixture had no entry") }
        var reducer = AgentDocumentReducer(document: altered.document)
        try reducer.apply(.appendMarkup(entryID: priorEntry.id, delta: "_UNEXPLAINED"))
        altered.document = reducer.document
        // Keep the original version to show that version equality is not proof
        // that a snapshot contains the journal's recovered document.
        altered.document.version = mismatched.primary.document.version
        try JSONCodec.makeEncoder().encode(altered).write(to: mismatched.snapshot)
        try await mustRefuse(AgentTranscriptStore(root: mismatched.root), mismatched, reason: "same-version snapshot mismatch")

        // Multiple same-version base backups with different contents are
        // ambiguous even when one replay happens to match the primary.
        let ambiguous = try await interrupted(root: root, name: "ambiguous-base", ambiguousBase: true)
        try await mustRefuse(AgentTranscriptStore(root: ambiguous.root), ambiguous, reason: "distinct same-version bases")
    }
}

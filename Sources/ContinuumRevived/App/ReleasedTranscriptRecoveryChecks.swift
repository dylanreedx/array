import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// A readable journal cannot stand in for an unreadable released snapshot.
@MainActor
enum ReleasedTranscriptRecoveryChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    private final class SnapshotFault: @unchecked Sendable {
        private let lock = NSLock()
        private var enabled = false
        func enable() { lock.lock(); enabled = true; lock.unlock() }
        func throwIfEnabled() throws {
            lock.lock()
            let shouldThrow = enabled
            lock.unlock()
            if shouldThrow { throw CocoaError(.fileWriteUnknown) }
        }
    }

    static func run(root: URL) async throws {
        let fixture = root.appendingPathComponent("released-recovery", isDirectory: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let transcriptRoot = fixture.appendingPathComponent("transcripts")
        let transcripts = AgentTranscriptStore(root: transcriptRoot)
        let id = AgentID(rawValue: UUID())
        try agents.upsert(AgentRecord(id: id, displayName: "Recovery", harness: .pi,
                                     model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: root.path,
                                     createdAt: Date(), lastActivityAt: Date()))
        let supervisor = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil }, transcriptStore: transcripts)
        _ = supervisor.restore()
        let previousDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .zero
        defer { AgentSupervisor.transcriptReleaseDelay = previousDelay }
        let thread = AgentSupervisor.threadId(for: id)
        func turn(_ number: Int) {
            let turnID = "recovery-\(number)"
            supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: turnID), to: id)
            supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: turnID, streamKind: .assistant,
                                              delta: "RECOVERY_MARKER_\(number)"), to: id)
            supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: turnID, outcome: .completed, errorMessage: nil), to: id)
        }
        turn(1)
        let deadline = ContinuousClock.now + .seconds(20)
        while !supervisor.isTranscriptReleased(id), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard supervisor.isTranscriptReleased(id) else { throw Failure(description: "fixture did not release") }
        let session = AgentTranscriptStore.canonicalSessionID(for: id)
        guard let original = try await transcripts.load(agentID: id, sessionID: session), !original.entries.isEmpty,
              original.version > 0 else { throw Failure(description: "fixture did not save a nonempty snapshot") }
        let agentRoot = transcriptRoot.appendingPathComponent(id.rawValue.uuidString)
        guard let enumerator = FileManager.default.enumerator(at: agentRoot, includingPropertiesForKeys: nil),
              let snapshot = enumerator.allObjects.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "snapshot.json" }) else {
            throw Failure(description: "fixture snapshot missing")
        }
        let snapshotBytes = try Data(contentsOf: snapshot)
        let backups = snapshot.deletingLastPathComponent().appendingPathComponent("backups")
        let savedBackups = fixture.appendingPathComponent("held-backups")
        let hadBackups = FileManager.default.fileExists(atPath: backups.path)
        if hadBackups { try FileManager.default.moveItem(at: backups, to: savedBackups) }
        let corrupt = Data("unreadable snapshot".utf8)
        try corrupt.write(to: snapshot)
        // The ordinary recovery API's journal-only fallback demonstrates why
        // checking only for a non-nil document is insufficient here.
        guard let partial = try await transcripts.load(agentID: id, sessionID: session), partial.entries.isEmpty else {
            throw Failure(description: "fixture did not expose the journal-only fallback")
        }
        let attachment = supervisor.transcriptAttachment(for: id, reboundTo: "half-corrupt")
        let view = Task { for await _ in attachment.tail {} }
        if let reload = attachment.reload { await reload.value }
        view.cancel()
        guard supervisor.isTranscriptReleased(id), try Data(contentsOf: snapshot) == corrupt else {
            throw Failure(description: "half-corrupt released snapshot was accepted or overwritten")
        }
        turn(2)
        let retry = supervisor.transcriptAttachment(for: id, reboundTo: "still-corrupt")
        let retryView = Task { for await _ in retry.tail {} }
        if let reload = retry.reload { await reload.value }
        retryView.cancel()
        guard supervisor.isTranscriptReleased(id), try Data(contentsOf: snapshot) == corrupt else {
            throw Failure(description: "a write replaced the half-corrupt released snapshot")
        }
        try snapshotBytes.write(to: snapshot)
        if hadBackups { try FileManager.default.moveItem(at: savedBackups, to: backups) }
        // A different save can have exactly the same semantic version. It is
        // not the snapshot the supervisor released, so it must not cause the
        // held writes to be replayed into an unrelated generation.
        _ = try await transcripts.saveSnapshot(agentID: id, sessionID: session, document: original)
        let replaced = supervisor.transcriptAttachment(for: id, reboundTo: "replaced-generation")
        let replacedView = Task { for await _ in replaced.tail {} }
        if let reload = replaced.reload { await reload.value }
        replacedView.cancel()
        guard supervisor.isTranscriptReleased(id) else {
            throw Failure(description: "a same-version replacement released queued writes into the wrong generation")
        }
        try snapshotBytes.write(to: snapshot)
        let repaired = supervisor.transcriptAttachment(for: id, reboundTo: "repaired")
        let repairedView = Task { for await _ in repaired.tail {} }
        if let reload = repaired.reload { await reload.value }
        defer { repairedView.cancel() }
        let text = (supervisor.transcriptDocument(for: id)?.entries ?? [])
            .map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
        guard !supervisor.isTranscriptReleased(id), text.contains("RECOVERY_MARKER_1"), text.contains("RECOVERY_MARKER_2") else {
            throw Failure(description: "repaired snapshot did not resume the original and queued history")
        }

        // Equal document versions do not identify the same saved generation.
        let first = try await transcripts.saveSnapshot(agentID: id, sessionID: "generation-check", document: original)
        let second = try await transcripts.saveSnapshot(agentID: id, sessionID: "generation-check", document: original)
        do {
            _ = try await transcripts.loadReleased(agentID: id, sessionID: "generation-check", expectedVersion: original.version, expectedGeneration: first)
            throw Failure(description: "a different snapshot generation was accepted")
        } catch AgentTranscriptStoreError.incompleteReleasedSnapshot { }
        _ = try await transcripts.loadReleased(agentID: id, sessionID: "generation-check", expectedVersion: original.version, expectedGeneration: second)

        try await runInterruptedSave(root: root, agents: agents, transcriptRoot: transcriptRoot)
    }

    /// A save can replace the snapshot and then fail to replace its journal.
    /// The old generation must not be used to release the still-live document.
    private static func runInterruptedSave(root: URL, agents: AgentStore, transcriptRoot: URL) async throws {
        let id = AgentID(rawValue: UUID())
        let fault = SnapshotFault()
        let transcripts = AgentTranscriptStore(root: transcriptRoot, afterSnapshotWriteForQA: { try fault.throwIfEnabled() })
        try agents.upsert(AgentRecord(id: id, displayName: "Interrupted save", harness: .pi,
                                     model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: root.path,
                                     createdAt: Date(), lastActivityAt: Date()))
        let supervisor = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil }, transcriptStore: transcripts)
        _ = supervisor.restore()
        let attachment = supervisor.transcriptAttachment(for: id, reboundTo: "save-failure")
        let view = Task { for await _ in attachment.tail {} }
        let thread = AgentSupervisor.threadId(for: id)
        supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: "save-failure"), to: id)
        supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: "save-failure", streamKind: .assistant,
                                          delta: "INTERRUPTED_SAVE_MARKER"), to: id)
        supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: "save-failure", outcome: .completed, errorMessage: nil), to: id)
        await supervisor.qaSaveTranscript(for: id)
        let agentRoot = transcriptRoot.appendingPathComponent(id.rawValue.uuidString)
        guard let enumerator = FileManager.default.enumerator(at: agentRoot, includingPropertiesForKeys: nil),
              let snapshot = enumerator.allObjects.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "snapshot.json" }) else {
            view.cancel()
            throw Failure(description: "interrupted-save fixture snapshot missing")
        }
        let before = try Data(contentsOf: snapshot)
        // Fail after the guarded save has accepted the current primary and has
        // replaced its snapshot, but before it writes the journal.
        fault.enable()
        await supervisor.qaSaveTranscript(for: id)
        let after = try Data(contentsOf: snapshot)
        guard before != after else {
            view.cancel()
            throw Failure(description: "interrupted-save fixture did not replace its snapshot before failing")
        }
        view.cancel()
        let detachDeadline = ContinuousClock.now + .seconds(10)
        while supervisor.subscriberCount(for: id) != 0, ContinuousClock.now < detachDeadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard supervisor.subscriberCount(for: id) == 0 else { throw Failure(description: "interrupted-save view did not detach") }
        supervisor.qaReleaseTranscriptIfDormant(id)
        let text = (supervisor.transcriptDocument(for: id)?.entries ?? [])
            .map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
        guard supervisor.qaTranscriptPersistenceIsBlocked(id), !supervisor.isTranscriptReleased(id),
              text.contains("INTERRUPTED_SAVE_MARKER"), try Data(contentsOf: snapshot) == after else {
            throw Failure(description: "partial save did not retain the live transcript and stop retries")
        }
    }
}

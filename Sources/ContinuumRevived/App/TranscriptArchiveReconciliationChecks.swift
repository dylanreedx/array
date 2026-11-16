import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCore
import Foundation

/// A prior Array archive and a provider-only restore are distinct histories.
/// Canonical writes extend the former; the latter remains in the local display
/// projection, including when the user deliberately shares that display.
@MainActor
enum TranscriptArchiveReconciliationChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private final class Sink: SharedAgentProjectionSink {
        func publish(_ batch: Collaboration.AgentProjection.Batch) async throws {}
    }

    static func run(root: URL) async throws {
        let fixture = root.appendingPathComponent("archive-reconciliation", isDirectory: true)
        let agentStore = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let transcriptRoot = fixture.appendingPathComponent("transcripts", isDirectory: true)
        let transcriptStore = AgentTranscriptStore(root: transcriptRoot)
        let id = AgentID(rawValue: UUID()), corruptID = AgentID(rawValue: UUID())
        let olderID = AgentID(rawValue: UUID()), lateID = AgentID(rawValue: UUID())
        for agent in [id, corruptID, olderID, lateID] {
            try agentStore.upsert(AgentRecord(id: agent, displayName: "Archive", harness: .pi,
                                            model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: root.path,
                                            createdAt: Date(), lastActivityAt: Date()))
        }
        let session = AgentTranscriptStore.canonicalSessionID(for: id)
        var existing = ManagedAgentTranscriptModel(threadId: AgentSupervisor.threadId(for: id))
        existing.appendUserPrompt("ARRAY_CANONICAL_BEFORE_RESTART")
        try await transcriptStore.saveSnapshot(agentID: id, sessionID: session, document: existing.document)
        guard let before = try await transcriptStore.load(agentID: id, sessionID: session), !before.entries.isEmpty else {
            throw Failure(description: "fixture did not save the prior canonical history")
        }
        let corruptedSession = AgentTranscriptStore.canonicalSessionID(for: corruptID)
        var corruptExisting = ManagedAgentTranscriptModel(threadId: AgentSupervisor.threadId(for: corruptID))
        corruptExisting.appendUserPrompt("CORRUPT_PRIOR_HISTORY")
        try await transcriptStore.saveSnapshot(agentID: corruptID, sessionID: corruptedSession, document: corruptExisting.document)
        let corruptRoot = transcriptRoot.appendingPathComponent(corruptID.rawValue.uuidString)
        guard let enumerator = FileManager.default.enumerator(at: corruptRoot, includingPropertiesForKeys: nil),
              let corruptSnapshot = enumerator.allObjects.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "snapshot.json" }) else {
            throw Failure(description: "fixture did not locate the corrupt snapshot")
        }
        let corruptBytes = Data("UNREADABLE_CANONICAL_PRIMARY".utf8)
        try corruptBytes.write(to: corruptSnapshot)
        // Older valid archives predate saveGeneration. They must resume too.
        let olderSession = AgentTranscriptStore.canonicalSessionID(for: olderID)
        var older = ManagedAgentTranscriptModel(threadId: AgentSupervisor.threadId(for: olderID))
        older.appendUserPrompt("LEGACY_CANONICAL_HISTORY")
        try await transcriptStore.saveSnapshot(agentID: olderID, sessionID: olderSession, document: older.document)
        let olderRoot = transcriptRoot.appendingPathComponent(olderID.rawValue.uuidString)
        guard let oldEnumerator = FileManager.default.enumerator(at: olderRoot, includingPropertiesForKeys: nil),
              let oldSnapshot = oldEnumerator.allObjects.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "snapshot.json" }) else {
            throw Failure(description: "fixture did not locate the older snapshot")
        }
        var legacyArchive = try JSONCodec.makeDecoder().decode(AgentTranscriptArchive.self, from: Data(contentsOf: oldSnapshot))
        legacyArchive.saveGeneration = nil
        let legacyWriter = AtomicWriter(backupsDirectory: oldSnapshot.deletingLastPathComponent().appendingPathComponent("backups"),
                                        retainedBackups: 2, prettyPrint: false, legacyBackupPolicy: .targetDedicated)
        try legacyWriter.write(legacyArchive, to: oldSnapshot)
        let lateSession = AgentTranscriptStore.canonicalSessionID(for: lateID)
        var lateCanonical = ManagedAgentTranscriptModel(threadId: AgentSupervisor.threadId(for: lateID))
        lateCanonical.appendUserPrompt("LATE_CANONICAL_HISTORY")
        try await transcriptStore.saveSnapshot(agentID: lateID, sessionID: lateSession, document: lateCanonical.document)

        var warnings: [String] = []
        let supervisor = AgentSupervisor(store: agentStore, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { warnings.append($0) }, nameTitlerCommand: { _ in nil },
                                         transcriptStore: transcriptStore)
        _ = supervisor.restore()
        guard supervisor.records[id] != nil, supervisor.records[corruptID] != nil, supervisor.records[olderID] != nil,
              supervisor.records[lateID] != nil else {
            throw Failure(description: "restart fixture did not restore all agent records")
        }
        let oldReleaseDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        defer { AgentSupervisor.transcriptReleaseDelay = oldReleaseDelay }
        let restoredThread = AgentSupervisor.threadId(for: id)
        let provider = RehydratedTranscript(steps: [
            .userPrompt("PROVIDER_LOCAL_ONLY"),
            .event(.turnStarted(threadId: restoredThread, turnId: "provider-old")),
            .event(.contentDelta(threadId: restoredThread, turnId: "provider-old", streamKind: .assistant,
                                 delta: "PROVIDER_PRIVATE_ASSISTANT")),
            .event(.turnCompleted(threadId: restoredThread, turnId: "provider-old", outcome: .completed, errorMessage: nil))
        ], restoredMessageCount: 2, omittedEarlier: true)
        supervisor.seedRehydratedTranscript(provider, for: id)
        supervisor.seedRehydratedTranscript(provider, for: corruptID)
        func tile() -> ManagedAgentTileNSView {
            let result = ManagedAgentTileNSView(tile: Tile(
                id: UUID(), kind: .managedAgent, title: "archive recovery",
                frame: TileFrame(x: 0, y: 0, width: 520, height: 320),
                zPosition: .fromLegacyRank(1), runtimeRef: nil,
                metadata: TileMetadata(launchProfileId: "managed")))
            result.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
            return result
        }
        let view = tile()
        view.attach(agentID: id, supervisor: supervisor)
        guard view.qaTranscriptText.contains("PROVIDER_LOCAL_ONLY"), view.qaTranscriptText.contains("PROVIDER_PRIVATE_ASSISTANT") else {
            view.detach()
            throw Failure(description: "provider history was not visible before the new turn")
        }
        view.detach()
        let detachDeadline = ContinuousClock.now + .seconds(10)
        while supervisor.subscriberCount(for: id) != 0, ContinuousClock.now < detachDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard supervisor.subscriberCount(for: id) == 0 else { throw Failure(description: "view did not detach") }
        AgentModelCatalog.shared.resetForQA(options: AgentCatalogQAFixture.pi)
        let prompt = "NEW_HEADLESS_AFTER_RESTART"
        guard supervisor.send(prompt, to: id) else {
            throw Failure(description: "new headless turn was refused: \(supervisor.sendRefusal(for: id) ?? "unknown")")
        }
        let thread = AgentSupervisor.threadId(for: id)
        supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: "archive-new"), to: id)
        supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: "archive-new", streamKind: .assistant,
                                           delta: "NEW_ASSISTANT_AFTER_RESTART"), to: id)
        supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: "archive-new", outcome: .completed, errorMessage: nil), to: id)
        let saveDeadline = ContinuousClock.now + .seconds(30)
        var saved: AgentDocument?
        func plain(_ document: AgentDocument?) -> String {
            (document?.entries ?? []).map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
        }
        while ContinuousClock.now < saveDeadline {
            saved = try await transcriptStore.load(agentID: id, sessionID: session)
            if plain(saved).contains(prompt), plain(saved).contains("NEW_ASSISTANT_AFTER_RESTART") { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard let saved,
              Array(saved.entries.prefix(before.entries.count)).map(\.id) == before.entries.map(\.id),
              plain(saved).contains("ARRAY_CANONICAL_BEFORE_RESTART"), plain(saved).contains(prompt),
              plain(saved).components(separatedBy: "NEW_ASSISTANT_AFTER_RESTART").count - 1 == 1,
              !plain(saved).contains("PROVIDER_LOCAL_ONLY"), !plain(saved).contains("PROVIDER_PRIVATE_ASSISTANT") else {
            throw Failure(description: "canonical after restart did not preserve Array history and new turn while excluding provider-only history: \(plain(saved))")
        }
        guard !supervisor.qaTranscriptPersistenceIsBlocked(id) else {
            throw Failure(description: "a complete canonical archive refused a new turn")
        }
        // Deliberate shared-agent publishing uses the local display projection.
        // Companion sync separately reads the canonical store checked above.
        let shared = supervisor.sharedTranscriptDocument(for: id)
        guard plain(shared).contains("PROVIDER_LOCAL_ONLY"), plain(shared).contains("PROVIDER_PRIVATE_ASSISTANT"),
              plain(shared).contains(prompt),
              plain(shared).components(separatedBy: "NEW_ASSISTANT_AFTER_RESTART").count - 1 == 1,
              !plain(shared).isEmpty else {
            throw Failure(description: "shared transcript omitted local display history or duplicated the new turn: \(plain(shared))")
        }
        // Drive the other production sharing path too: it reads the local
        // display snapshot and allows only assistant output.
        let projector = try SharedAgentProjector(supervisor: supervisor, agent: id, host: .init(), object: .init(),
                                                 generation: 1, history: .assistantOutput, sink: Sink())
        await projector.flush()
        let projected = projector.log.head.rows.map(\.text).joined(separator: "\n")
        projector.stop()
        guard projected.contains("NEW_ASSISTANT_AFTER_RESTART"), projected.contains("PROVIDER_PRIVATE_ASSISTANT") else {
            throw Failure(description: "shared projector omitted an assistant row from the local display: \(projected)")
        }
        let idleDeadline = ContinuousClock.now + .seconds(20)
        while (supervisor.isRunning(id) || supervisor.subscriberCount(for: id) != 0), ContinuousClock.now < idleDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard !supervisor.isRunning(id), supervisor.subscriberCount(for: id) == 0 else {
            throw Failure(description: "fixture did not become idle and unwatched before the release decision")
        }
        supervisor.qaReleaseTranscriptIfDormant(id)
        await supervisor.qaWaitForTranscriptPersistence(for: id)
        let reopened = tile()
        defer { reopened.detach() }
        reopened.attach(agentID: id, supervisor: supervisor)
        let visibleDeadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < visibleDeadline {
            if reopened.qaTranscriptText.contains("PROVIDER_LOCAL_ONLY"), reopened.qaTranscriptText.contains("PROVIDER_PRIVATE_ASSISTANT"), reopened.qaTranscriptText.contains(prompt),
               reopened.qaTranscriptText.contains("NEW_ASSISTANT_AFTER_RESTART") { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard reopened.qaTranscriptText.contains("PROVIDER_LOCAL_ONLY"), reopened.qaTranscriptText.contains("PROVIDER_PRIVATE_ASSISTANT"), reopened.qaTranscriptText.contains(prompt),
              reopened.qaTranscriptText.components(separatedBy: "NEW_ASSISTANT_AFTER_RESTART").count - 1 == 1,
              supervisor.rehydratedTranscript(for: id) == provider else {
            throw Failure(description: "reopened tile lost its separately retained provider history or new turn")
        }

        let olderThread = AgentSupervisor.threadId(for: olderID)
        supervisor.qaDeliver(.turnStarted(threadId: olderThread, turnId: "old-format-new"), to: olderID)
        supervisor.qaDeliver(.contentDelta(threadId: olderThread, turnId: "old-format-new", streamKind: .assistant,
                                           delta: "LEGACY_NEW_TURN"), to: olderID)
        supervisor.qaDeliver(.turnCompleted(threadId: olderThread, turnId: "old-format-new", outcome: .completed, errorMessage: nil), to: olderID)
        var olderSaved: AgentDocument?
        let olderDeadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < olderDeadline {
            olderSaved = try await transcriptStore.load(agentID: olderID, sessionID: olderSession)
            if plain(olderSaved).contains("LEGACY_NEW_TURN") { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard plain(olderSaved).contains("LEGACY_CANONICAL_HISTORY"), plain(olderSaved).contains("LEGACY_NEW_TURN"),
              !supervisor.qaTranscriptPersistenceIsBlocked(olderID) else {
            throw Failure(description: "valid archive without a generation could not be extended: \(plain(olderSaved))")
        }

        // No production provider read finishes for a released transcript: the
        // read pins refuse one and keep a pinned one resident. A direct seed is
        // refused, and the released history still reloads intact.
        let lateThread = AgentSupervisor.threadId(for: lateID)
        supervisor.qaDeliver(.turnStarted(threadId: lateThread, turnId: "late-new"), to: lateID)
        supervisor.qaDeliver(.contentDelta(threadId: lateThread, turnId: "late-new", streamKind: .assistant,
                                           delta: "LATE_NEW_TURN"), to: lateID)
        supervisor.qaDeliver(.turnCompleted(threadId: lateThread, turnId: "late-new", outcome: .completed, errorMessage: nil), to: lateID)
        var lateSaved: AgentDocument?
        let lateSaveDeadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < lateSaveDeadline {
            lateSaved = try await transcriptStore.load(agentID: lateID, sessionID: lateSession)
            if plain(lateSaved).contains("LATE_NEW_TURN") { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard plain(lateSaved).contains("LATE_CANONICAL_HISTORY"), plain(lateSaved).contains("LATE_NEW_TURN") else {
            throw Failure(description: "late-restore fixture failed to extend the canonical archive")
        }
        await supervisor.qaWaitForTranscriptPersistence(for: lateID)
        supervisor.qaReleaseTranscriptIfDormant(lateID)
        await supervisor.qaWaitForTranscriptPersistence(for: lateID)
        guard supervisor.isTranscriptReleased(lateID) else {
            throw Failure(description: "late-restore fixture did not release canonical history before provider read")
        }
        if let pin = supervisor.beginProviderHistoryRead(for: lateID) {
            supervisor.endProviderHistoryRead(pin, for: lateID)
            throw Failure(description: "a provider read pinned a released transcript")
        }
        let warningsBeforeLate = warnings.count
        supervisor.seedRehydratedTranscript(provider, for: lateID)
        guard supervisor.rehydratedTranscript(for: lateID) == nil, warnings.count == warningsBeforeLate + 1 else {
            throw Failure(description: "a released transcript accepted provider history")
        }
        let lateView = tile()
        lateView.attach(agentID: lateID, supervisor: supervisor)
        let lateVisibleDeadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < lateVisibleDeadline {
            let text = lateView.qaTranscriptText
            if text.contains("LATE_CANONICAL_HISTORY"), text.contains("LATE_NEW_TURN") { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let lateVisible = lateView.qaTranscriptText
        lateView.detach()
        lateSaved = try await transcriptStore.load(agentID: lateID, sessionID: lateSession)
        guard lateVisible.contains("LATE_CANONICAL_HISTORY"), lateVisible.components(separatedBy: "LATE_NEW_TURN").count - 1 == 1,
              !lateVisible.contains("PROVIDER_LOCAL_ONLY"), !lateVisible.contains("PROVIDER_PRIVATE_ASSISTANT"),
              !plain(lateSaved).contains("PROVIDER_LOCAL_ONLY"), !plain(lateSaved).contains("PROVIDER_PRIVATE_ASSISTANT") else {
            throw Failure(description: "released history did not reload intact after a refused provider seed: \(lateVisible)")
        }

        let warningsBeforeCorrupt = warnings.count
        var notices: [AgentLocalNotice] = []
        let token = supervisor.addLocalNoticeObserver(for: corruptID) { notices.append($0) }
        defer { supervisor.removeLocalNoticeObserver(token, for: corruptID) }
        let corruptThread = AgentSupervisor.threadId(for: corruptID)
        supervisor.qaDeliver(.turnStarted(threadId: corruptThread, turnId: "corrupt-new"), to: corruptID)
        supervisor.qaDeliver(.contentDelta(threadId: corruptThread, turnId: "corrupt-new", streamKind: .assistant,
                                           delta: "UNSAVED_CORRUPT_NEW"), to: corruptID)
        supervisor.qaDeliver(.turnCompleted(threadId: corruptThread, turnId: "corrupt-new", outcome: .completed, errorMessage: nil), to: corruptID)
        let blockedDeadline = ContinuousClock.now + .seconds(20)
        while !supervisor.qaTranscriptPersistenceIsBlocked(corruptID), ContinuousClock.now < blockedDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard supervisor.qaTranscriptPersistenceIsBlocked(corruptID),
              notices.contains(where: { $0.title == "Transcript not saved" }), warnings.count > warningsBeforeCorrupt,
              try Data(contentsOf: corruptSnapshot) == corruptBytes else {
            throw Failure(description: "corrupt canonical archive was overwritten or did not visibly fail closed")
        }
    }
}

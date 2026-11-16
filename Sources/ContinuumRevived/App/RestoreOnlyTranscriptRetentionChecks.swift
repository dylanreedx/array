import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// Provider-restored history must survive an idle detach and a headless turn.
@MainActor
enum RestoreOnlyTranscriptRetentionChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(supervisor: AgentSupervisor, id: AgentID, transcriptStore: AgentTranscriptStore) async throws {
        let oldPrompt = "RESTORE_ONLY_OLD_PROMPT"
        let oldReply = "RESTORE_ONLY_OLD_REPLY"
        let newPrompt = "RESTORE_ONLY_NEW_HEADLESS_PROMPT"
        let thread = AgentSupervisor.threadId(for: id)
        let restored = RehydratedTranscript(steps: [
            .userPrompt(oldPrompt),
            .event(.turnStarted(threadId: thread, turnId: "restored-turn")),
            .event(.contentDelta(threadId: thread, turnId: "restored-turn", streamKind: .assistant, delta: oldReply)),
            .event(.turnCompleted(threadId: thread, turnId: "restored-turn", outcome: .completed, errorMessage: nil))
        ], restoredMessageCount: 2, omittedEarlier: false)
        supervisor.seedRehydratedTranscript(restored, for: id)

        func makeTile() -> ManagedAgentTileNSView {
            let tile = ManagedAgentTileNSView(tile: Tile(
                id: UUID(), kind: .managedAgent, title: "restore retention",
                frame: TileFrame(x: 0, y: 0, width: 520, height: 320),
                zPosition: .fromLegacyRank(1), runtimeRef: nil,
                metadata: TileMetadata(launchProfileId: "managed")))
            tile.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
            return tile
        }
        let original = makeTile()
        original.attach(agentID: id, supervisor: supervisor)
        guard original.qaTranscriptText.contains(oldPrompt), original.qaTranscriptText.contains(oldReply) else {
            throw Failure(description: "restore-only fixture did not show the prior history in its tile")
        }
        original.detach()
        // Wait until detach removes the subscriber, then drive the production
        // idle-release decision without relying on a timed sleep.
        let detachDeadline = ContinuousClock.now + .seconds(20)
        while supervisor.subscriberCount(for: id) != 0, ContinuousClock.now < detachDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard supervisor.subscriberCount(for: id) == 0 else {
            throw Failure(description: "restore-only fixture did not detach its subscriber")
        }
        supervisor.qaReleaseTranscriptIfDormant(id)
        guard supervisor.rehydratedTranscript(for: id) == restored, !supervisor.isTranscriptReleased(id) else {
            throw Failure(description: "idle detach discarded the restore-only history")
        }

        AgentModelCatalog.shared.resetForQA(options: AgentCatalogQAFixture.pi)
        guard supervisor.send(newPrompt, to: id) else {
            throw Failure(description: "restore-only headless prompt was refused: \(supervisor.sendRefusal(for: id) ?? "unknown")")
        }
        let sessionID = AgentTranscriptStore.canonicalSessionID(for: id)
        var savedText = ""
        let saveDeadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < saveDeadline {
            if let document = try await transcriptStore.load(agentID: id, sessionID: sessionID) {
                savedText = document.entries.map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
                if savedText.contains(newPrompt) { break }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let oldPromptRange = savedText.range(of: oldPrompt),
              let oldReplyRange = savedText.range(of: oldReply),
              let newPromptRange = savedText.range(of: newPrompt),
              oldPromptRange.lowerBound < oldReplyRange.lowerBound,
              oldReplyRange.lowerBound < newPromptRange.lowerBound else {
            throw Failure(description: "headless prompt after restore-only detach did not save the prior prompt, reply, and new prompt in order: \(savedText)")
        }

        let reopened = makeTile()
        defer { reopened.detach() }
        reopened.attach(agentID: id, supervisor: supervisor)
        let viewDeadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < viewDeadline {
            let text = reopened.qaTranscriptText
            if text.contains(oldPrompt), text.contains(oldReply), text.contains(newPrompt) { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let text = reopened.qaTranscriptText
        guard text.contains(oldPrompt), text.contains(oldReply), text.contains(newPrompt) else {
            throw Failure(description: "reopened tile omitted history after restore-only detach and a headless prompt: \(text)")
        }
    }

    /// Do not replace an existing, possibly richer, Array archive merely because
    /// a provider restore has become idle. This also covers unreadable files.
    static func runPreservingExisting(root: URL) async throws {
        let fixtureRoot = root.appendingPathComponent("restore-existing", isDirectory: true)
        let agents = AgentStore(applicationSupportDirectory: fixtureRoot.appendingPathComponent("agents"))
        let transcriptStore = AgentTranscriptStore(root: fixtureRoot.appendingPathComponent("transcripts"))
        let id = AgentID(rawValue: UUID()), corruptID = AgentID(rawValue: UUID())
        for agent in [id, corruptID] {
            try agents.upsert(AgentRecord(id: agent, displayName: "Existing history", harness: .pi,
                                         model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: root.path,
                                         createdAt: Date(), lastActivityAt: Date()))
        }
        let sessionID = AgentTranscriptStore.canonicalSessionID(for: id)
        var existing = ManagedAgentTranscriptModel(threadId: AgentSupervisor.threadId(for: id))
        existing.appendUserPrompt("ARRAY_ONLY_EXISTING_HISTORY")
        try await transcriptStore.saveSnapshot(agentID: id, sessionID: sessionID, document: existing.document)
        let original = try await transcriptStore.load(agentID: id, sessionID: sessionID)
        guard original != nil else { throw Failure(description: "existing-archive fixture was empty") }
        let corruptSession = AgentTranscriptStore.canonicalSessionID(for: corruptID)
        try await transcriptStore.saveSnapshot(agentID: corruptID, sessionID: corruptSession, document: existing.document)
        let corruptRoot = fixtureRoot.appendingPathComponent("transcripts").appendingPathComponent(corruptID.rawValue.uuidString)
        guard let enumerator = FileManager.default.enumerator(at: corruptRoot, includingPropertiesForKeys: nil) else {
            throw Failure(description: "could not find the unreadable-archive fixture")
        }
        let corruptFiles = enumerator.allObjects.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "snapshot.json" || $0.lastPathComponent == "journal.json" }
        guard corruptFiles.count == 2 else { throw Failure(description: "unreadable-archive fixture has no snapshot and journal") }
        let corruptBytes = Data("unreadable archive".utf8)
        for url in corruptFiles { try corruptBytes.write(to: url) }
        guard try await transcriptStore.load(agentID: corruptID, sessionID: corruptSession) == nil else {
            throw Failure(description: "unreadable-archive fixture unexpectedly loaded")
        }
        let supervisor = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil }, transcriptStore: transcriptStore)
        _ = supervisor.restore()
        let restored = RehydratedTranscript(steps: [.userPrompt("BOUNDED_PROVIDER_RESTORE")],
                                            restoredMessageCount: 1, omittedEarlier: true)
        // A provider read may finish after the tile has already detached.
        supervisor.seedRehydratedTranscript(restored, for: id)
        supervisor.seedRehydratedTranscript(restored, for: corruptID)
        supervisor.qaReleaseTranscriptIfDormant(id)
        supervisor.qaReleaseTranscriptIfDormant(corruptID)
        guard supervisor.rehydratedTranscript(for: id) == restored,
              supervisor.rehydratedTranscript(for: corruptID) == restored,
              try await transcriptStore.load(agentID: id, sessionID: sessionID) == original else {
            throw Failure(description: "idle restore discarded history or changed an existing Array archive")
        }
        for url in corruptFiles {
            guard try Data(contentsOf: url) == corruptBytes else {
                throw Failure(description: "idle restore overwrote an unreadable Array archive")
            }
        }
    }
}

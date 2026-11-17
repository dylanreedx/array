import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// The external-session link pins a saved idle projection until adoption.
@MainActor
enum TranscriptLinkedRetentionChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(root: URL) async throws {
        let fixture = root.appendingPathComponent("linked-retention", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let transcripts = AgentTranscriptStore(root: fixture.appendingPathComponent("transcripts"))
        let linked = AgentID(rawValue: UUID()), ordinary = AgentID(rawValue: UUID())
        for id in [linked, ordinary] {
            try agents.upsert(AgentRecord(id: id, displayName: "Linked retention", harness: .pi,
                                         model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: fixture.path,
                                         createdAt: Date(), lastActivityAt: Date()))
        }
        let supervisor = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil }, transcriptStore: transcripts)
        _ = supervisor.restore()
        let previousDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        defer { AgentSupervisor.transcriptReleaseDelay = previousDelay; supervisor.stopAll() }
        guard supervisor.records[linked] != nil, supervisor.records[ordinary] != nil else {
            throw Failure(description: "linked-retention agents did not restore")
        }
        // The same supervisor API used by a production watch or Move-here
        // sets this link. No external session file or real process is touched.
        supervisor.linkExternalSession(linked, AgentExternalSessionLink(
            mode: .watching, provider: .claude, sessionId: UUID().uuidString, hostName: "Fixture",
            transcriptPath: nil, tracksProcess: false))
        guard supervisor.records[linked]?.externalSession != nil, supervisor.isSessionHeld(linked) else {
            throw Failure(description: "external session was not linked")
        }
        let linkedText = "LINKED_RETAINED_HISTORY", ordinaryText = "UNLINKED_RELEASED_HISTORY"
        for (id, marker) in [(linked, linkedText), (ordinary, ordinaryText)] {
            let thread = AgentSupervisor.threadId(for: id)
            supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: marker), to: id)
            supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: marker, streamKind: .assistant, delta: marker), to: id)
            supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: marker, outcome: .completed, errorMessage: nil), to: id)
            await supervisor.qaSaveTranscript(for: id)
            guard let saved = try await transcripts.load(agentID: id, sessionID: AgentTranscriptStore.canonicalSessionID(for: id)),
                  saved.entries.contains(where: { AgentTranscriptCopyController.plainText(for: $0.blocks).contains(marker) }) else {
                throw Failure(description: "linked-retention fixture failed to persist its projection")
            }
        }
        func tile() -> ManagedAgentTileNSView {
            let view = ManagedAgentTileNSView(tile: Tile(
                id: UUID(), kind: .managedAgent, title: "Linked retention",
                frame: TileFrame(x: 0, y: 0, width: 520, height: 320),
                zPosition: .fromLegacyRank(1), runtimeRef: nil,
                metadata: TileMetadata(launchProfileId: "managed")))
            view.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
            return view
        }
        let linkedTile = tile(), ordinaryTile = tile()
        linkedTile.attach(agentID: linked, supervisor: supervisor)
        ordinaryTile.attach(agentID: ordinary, supervisor: supervisor)
        linkedTile.detach(); ordinaryTile.detach()
        let detachDeadline = ContinuousClock.now + .seconds(20)
        while (supervisor.subscriberCount(for: linked) != 0 || supervisor.subscriberCount(for: ordinary) != 0),
              ContinuousClock.now < detachDeadline { try? await Task.sleep(for: .milliseconds(20)) }
        guard supervisor.subscriberCount(for: linked) == 0, supervisor.subscriberCount(for: ordinary) == 0 else {
            throw Failure(description: "linked-retention fixture did not detach both tiles")
        }
        let releaseDeadline = ContinuousClock.now + .seconds(20)
        while !supervisor.isTranscriptReleased(ordinary), ContinuousClock.now < releaseDeadline {
            supervisor.qaReleaseTranscriptIfDormant(linked)
            supervisor.qaReleaseTranscriptIfDormant(ordinary)
            await supervisor.qaWaitForTranscriptPersistence(for: linked)
            await supervisor.qaWaitForTranscriptPersistence(for: ordinary)
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard supervisor.isTranscriptReleased(ordinary), !supervisor.isTranscriptReleased(linked),
              supervisor.records[linked]?.externalSession != nil,
              let resident = supervisor.transcriptDocument(for: linked),
              resident.entries.contains(where: { AgentTranscriptCopyController.plainText(for: $0.blocks).contains(linkedText) }),
              let saved = try await transcripts.load(agentID: linked, sessionID: AgentTranscriptStore.canonicalSessionID(for: linked)),
              saved.entries.contains(where: { AgentTranscriptCopyController.plainText(for: $0.blocks).contains(linkedText) }) else {
            throw Failure(description: "linked agent released or lost history while the ordinary agent was releasable")
        }
    }
}

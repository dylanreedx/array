import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// Both in-memory projections must be counted until they are safely released.
@MainActor
enum TranscriptDualCensusChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(root: URL) async throws {
        let fixture = root.appendingPathComponent("transcript-dual-census", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let transcripts = AgentTranscriptStore(root: fixture.appendingPathComponent("transcripts"))
        let id = AgentID(rawValue: UUID())
        try agents.upsert(AgentRecord(id: id, displayName: "Census", harness: .pi,
                                     model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: fixture.path,
                                     createdAt: Date(), lastActivityAt: Date()))
        let sessionID = AgentTranscriptStore.canonicalSessionID(for: id)
        let thread = AgentSupervisor.threadId(for: id)
        var prior = ManagedAgentTranscriptModel(threadId: thread)
        prior.appendUserPrompt("DUAL_CENSUS_OLD_HISTORY")
        try await transcripts.saveSnapshot(agentID: id, sessionID: sessionID, document: prior.document)
        guard case .present = try await transcripts.preflightGuardedArchive(agentID: id, sessionID: sessionID) else {
            throw Failure(description: "fixture did not create a valid prior archive")
        }
        let supervisor = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil }, transcriptStore: transcripts)
        _ = supervisor.restore()
        guard supervisor.records[id] != nil else { throw Failure(description: "fixture agent did not restore") }
        let previousDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        defer { AgentSupervisor.transcriptReleaseDelay = previousDelay }

        // Keep a real subscription open while the canonical and local models
        // both receive the same later turn.
        let attachment = supervisor.transcriptAttachment(for: id, reboundTo: "dual-census-probe")
        let view = Task { for await _ in attachment.tail {} }
        defer { view.cancel() }
        supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: "dual-census-new"), to: id)
        supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: "dual-census-new", streamKind: .assistant,
                                           delta: "DUAL_CENSUS_NEW_REPLY"), to: id)
        supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: "dual-census-new", outcome: .completed, errorMessage: nil), to: id)
        await supervisor.qaSaveTranscript(for: id)
        let held = supervisor.qaHeldTranscripts
        guard !supervisor.qaTranscriptPersistenceIsBlocked(id), held.projections == 2,
              held.events >= 6, held.released == 0 else {
            throw Failure(description: "dual census expected two live projections and both event streams; got \(held)")
        }
        let document = try await transcripts.load(agentID: id, sessionID: sessionID)
        let savedText = (document?.entries ?? []).map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
        guard savedText.contains("DUAL_CENSUS_OLD_HISTORY"), savedText.contains("DUAL_CENSUS_NEW_REPLY") else {
            throw Failure(description: "canonical save omitted old or new history: \(savedText)")
        }

        view.cancel()
        let detachDeadline = ContinuousClock.now + .seconds(10)
        while supervisor.subscriberCount(for: id) != 0, ContinuousClock.now < detachDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard supervisor.subscriberCount(for: id) == 0 else { throw Failure(description: "census probe did not detach") }
        let releaseDeadline = ContinuousClock.now + .seconds(10)
        while !supervisor.isTranscriptReleased(id), ContinuousClock.now < releaseDeadline {
            supervisor.qaReleaseTranscriptIfDormant(id)
            await supervisor.qaWaitForTranscriptPersistence(for: id)
            try? await Task.sleep(for: .milliseconds(20))
        }
        let released = supervisor.qaHeldTranscripts
        guard supervisor.isTranscriptReleased(id), released.projections == 0, released.released == 1 else {
            throw Failure(description: "dual census still holds projections after release: \(released)")
        }
        let reopened = supervisor.transcriptAttachment(for: id, reboundTo: "dual-census-reopen")
        let reopenedView = Task { for await _ in reopened.tail {} }
        defer { reopenedView.cancel() }
        if let reload = reopened.reload { await reload.value }
        let text = (supervisor.transcriptDocument(for: id)?.entries ?? [])
            .map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
        guard !supervisor.isTranscriptReleased(id),
              text.components(separatedBy: "DUAL_CENSUS_OLD_HISTORY").count - 1 == 1,
              text.components(separatedBy: "DUAL_CENSUS_NEW_REPLY").count - 1 == 1 else {
            throw Failure(description: "dual census reopen lost or duplicated history: \(text)")
        }
    }
}

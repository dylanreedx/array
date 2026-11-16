import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// A single headless shared read must not keep a reloaded transcript resident.
@MainActor
enum TranscriptSharedReadReleaseChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(root: URL) async throws {
        let fixture = root.appendingPathComponent("shared-read-release", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let transcripts = AgentTranscriptStore(root: fixture.appendingPathComponent("transcripts"))
        let id = AgentID(rawValue: UUID())
        let thread = AgentSupervisor.threadId(for: id)
        let session = AgentTranscriptStore.canonicalSessionID(for: id)
        try agents.upsert(AgentRecord(id: id, displayName: "Shared read release", harness: .pi,
                                     model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: fixture.path,
                                     createdAt: Date(), lastActivityAt: Date()))
        let supervisor = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil }, transcriptStore: transcripts)
        _ = supervisor.restore()
        let previousDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .milliseconds(250)
        defer {
            AgentSupervisor.transcriptReleaseDelay = previousDelay
            supervisor.stopAll()
        }
        guard supervisor.records[id] != nil else { throw Failure(description: "shared-read fixture did not restore its agent") }
        let marker = "SHARED_READ_RELEASE_HISTORY"
        supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: marker), to: id)
        supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: marker, streamKind: .assistant, delta: marker), to: id)
        supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: marker, outcome: .completed, errorMessage: nil), to: id)
        await supervisor.qaSaveTranscript(for: id)
        let initialDeadline = ContinuousClock.now + .seconds(20)
        while !supervisor.isTranscriptReleased(id), ContinuousClock.now < initialDeadline {
            supervisor.qaReleaseTranscriptIfDormant(id)
            await supervisor.qaWaitForTranscriptPersistence(for: id)
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard supervisor.isTranscriptReleased(id),
              let before = try await transcripts.load(agentID: id, sessionID: session),
              before.entries.contains(where: { AgentTranscriptCopyController.plainText(for: $0.blocks).contains(marker) }) else {
            throw Failure(description: "shared-read fixture did not save and release its history")
        }

        // No tile, observer, or subscription exists. A single publisher read
        // starts the real reload; no further reads refresh its release delay.
        guard supervisor.sharedTranscriptDocument(for: id) == nil,
              let reload = supervisor.qaTranscriptReloadTask(for: id) else {
            throw Failure(description: "shared read did not start a released transcript reload")
        }
        await reload.value
        guard !supervisor.isTranscriptReleased(id),
              let resumed = supervisor.transcriptDocument(for: id),
              resumed.entries.contains(where: { AgentTranscriptCopyController.plainText(for: $0.blocks).contains(marker) }) else {
            throw Failure(description: "shared read did not resume the archived history")
        }
        let releaseDeadline = ContinuousClock.now + .seconds(20)
        while !supervisor.isTranscriptReleased(id), ContinuousClock.now < releaseDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard supervisor.isTranscriptReleased(id),
              let after = try await transcripts.load(agentID: id, sessionID: session), after.entries == before.entries else {
            throw Failure(description: "shared-read transcript did not automatically re-release with its archive intact")
        }
    }
}

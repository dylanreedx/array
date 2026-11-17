import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// A real Copy-here action with an isolated supervisor and a suspended file read.
/// This covers the combined adoption/read retention protection, not either guard
/// independently. It does not mount the app or construct a sidebar/account.
@MainActor
enum ProviderHistoryCopyHandoffChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    private actor ReadGate {
        private(set) var entered = false
        private var opened = false
        private var waiter: CheckedContinuation<Void, Never>?

        func wait() async {
            entered = true
            guard !opened else { return }
            await withCheckedContinuation { waiter = $0 }
        }

        func open() {
            opened = true
            waiter?.resume()
            waiter = nil
        }
    }

    static func run(root: URL) async throws {
        let fixture = root.appendingPathComponent("copy-here-read-pin", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let transcripts = AgentTranscriptStore(root: fixture.appendingPathComponent("transcripts"))
        let id = AgentID(rawValue: UUID())
        let thread = AgentSupervisor.threadId(for: id)
        let session = AgentTranscriptStore.canonicalSessionID(for: id)
        guard let model = AgentCatalogQAFixture.claude.seedModel else {
            throw Failure(description: "no synthetic Claude model")
        }
        try agents.upsert(AgentRecord(id: id, displayName: "Copy-here pin", harness: .claudeCode,
                                     model: model, thinking: "none", cwd: fixture.path,
                                     createdAt: Date(), lastActivityAt: Date()))
        let supervisor = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil }, transcriptStore: transcripts)
        _ = supervisor.restore()
        let previousDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        let gate = ReadGate()
        defer {
            AdoptedTranscriptReadCheckHooks.beforeRead = nil
            AgentSupervisor.transcriptReleaseDelay = previousDelay
            supervisor.stopAll()
            Task { await gate.open() }
        }
        let provider = "COPY_HERE_PROVIDER_HISTORY"
        let sessionFile = fixture.appendingPathComponent("synthetic-session.jsonl")
        let line = #"{"type":"user","uuid":"copy-provider-1","message":{"role":"user","content":"COPY_HERE_PROVIDER_HISTORY"}}"#
        try Data((line + "\n").utf8).write(to: sessionFile)
        let link = AgentExternalSessionLink(mode: .watching, provider: .claude, sessionId: "copy-here-qa",
                                            hostName: "Synthetic", transcriptPath: sessionFile.path,
                                            tracksProcess: false)
        supervisor.linkExternalSession(id, link)
        let local = "COPY_HERE_LOCAL_BEFORE_READ"
        supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: local), to: id)
        supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: local, streamKind: .assistant, delta: local), to: id)
        supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: local, outcome: .completed, errorMessage: nil), to: id)
        await supervisor.qaSaveTranscript(for: id)
        guard !supervisor.qaTranscriptPersistenceIsBlocked(id),
              supervisor.transcriptDocumentProjection(for: id) != nil else {
            throw Failure(description: "fixture could not save an existing local transcript")
        }

        // No workspace scene is mounted. The production copy action sees no
        // tile/sidebar, so it cannot visit accounts, a project or the network.
        let delegate = AppDelegate()
        delegate.agentSupervisor = supervisor
        AdoptedTranscriptReadCheckHooks.beforeRead = { agent in
            if agent == id { await gate.wait() }
        }
        delegate.performSessionHandoffAction(.copyHere, agentId: id)
        let deadline = ContinuousClock.now + .seconds(20)
        while !(await gate.entered), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard await gate.entered, supervisor.records[id]?.externalSession == nil,
              supervisor.records[id]?.pendingSessionForkFrom == link.sessionId else {
            throw Failure(description: "Copy here did not enter the suspended production read and unlink the watch")
        }
        supervisor.qaReleaseTranscriptIfDormant(id)
        await supervisor.qaWaitForTranscriptPersistence(for: id)
        guard !supervisor.isTranscriptReleased(id),
              let resident = supervisor.transcriptDocumentProjection(for: id),
              resident.entries.map({ AgentTranscriptCopyController.plainText(for: $0.blocks) })
                .joined(separator: "\n").contains(local) else {
            throw Failure(description: "Copy here released the saved local transcript while the provider read was pending")
        }
        await gate.open()
        let finishDeadline = ContinuousClock.now + .seconds(20)
        while supervisor.rehydratedTranscript(for: id) == nil, ContinuousClock.now < finishDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard let restored = supervisor.rehydratedTranscript(for: id),
              restored.steps.contains(.userPrompt(provider)),
              supervisor.sessionFileMark(for: id, url: sessionFile) == UInt64((line + "\n").utf8.count) else {
            throw Failure(description: "Copy here did not finish the synthetic provider read or commit its file mark")
        }
        await supervisor.qaSaveTranscript(for: id)
        guard let disk = try await transcripts.load(agentID: id, sessionID: session) else {
            throw Failure(description: "Copy here did not retain the canonical transcript on disk")
        }
        let diskText = disk.entries.map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
        guard diskText.components(separatedBy: local).count - 1 == 1, !diskText.contains(provider) else {
            throw Failure(description: "Copy here changed local canonical history or persisted provider-only history")
        }
    }
}

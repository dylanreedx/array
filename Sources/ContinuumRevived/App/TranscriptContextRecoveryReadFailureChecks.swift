import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// Context-full recovery cannot act on a released transcript that failed to
/// reload, even when the caller does not supply a block ID.
@MainActor
enum TranscriptContextRecoveryReadFailureChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    private final class Runner: AgentRunning, AgentCompactionRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var runCount = 0
        private var compactCount = 0
        var counts: (runs: Int, compactions: Int) { lock.withLock { (runCount, compactCount) } }
        var compactionCapabilities: AgentCompactionCapabilities { .init(supportsManual: true) }
        var keepsSessionAliveBetweenTurns: Bool { true }
        var canAcceptAnotherTurn: Bool { true }

        func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
            let first = lock.withLock { runCount += 1; return runCount == 1 }
            let turn = first ? "context-full-first" : "context-full-retry"
            onEvent(.turnStarted(threadId: "runner", turnId: turn))
            onEvent(.contentDelta(threadId: "runner", turnId: turn, streamKind: .assistant,
                                  delta: first ? "CONTEXT_RECOVERY_OLD_HISTORY" : "CONTEXT_RECOVERY_RETRY_RESULT"))
            onEvent(.turnCompleted(threadId: "runner", turnId: turn, outcome: first ? .failed : .completed,
                                   errorMessage: first ? AgentContextFullRecovery.canonicalErrorMessage : nil))
        }
        func compact(_ request: AgentCompactionRequest, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
            lock.withLock { compactCount += 1 }
            onEvent(.compactionChanged(threadId: "runner", event: AgentCompactionLifecycleEvent(
                operationID: request.operationID, phase: .running, trigger: .manual, provider: "script")))
            onEvent(.compactionChanged(threadId: "runner", event: AgentCompactionLifecycleEvent(
                operationID: request.operationID, boundaryID: "recovery-check-boundary", phase: .succeeded,
                trigger: .manual, provider: "script")))
        }
        func stop() {}
        func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {}
        func observeRuntimeObservations(_ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void) {}
    }

    static func run(root: URL) async throws {
        let fixture = root.appendingPathComponent("context-recovery-read-failure", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let agentStore = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let transcriptRoot = fixture.appendingPathComponent("transcripts", isDirectory: true)
        let transcripts = AgentTranscriptStore(root: transcriptRoot)
        let drafts = AgentComposerDraftStore(applicationSupportDirectory: fixture.appendingPathComponent("drafts"), debounceInterval: 0)
        let runner = Runner()
        var warnings: [String] = []
        let supervisor = AgentSupervisor(store: agentStore, makeRunner: { _ in runner }, warn: { warnings.append($0) },
                                         nameTitlerCommand: { _ in nil }, submissionRecoveryStore: drafts,
                                         transcriptStore: transcripts)
        let oldDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        defer { AgentSupervisor.transcriptReleaseDelay = oldDelay; supervisor.stopAll() }
        AgentModelCatalog.shared.resetForQA(options: AgentCatalogQAFixture.pi)
        let id = supervisor.spawn(role: nil, prompt: nil, cwd: fixture, harness: .pi,
                                  model: AgentCatalogQAFixture.pi[0], thinking: "none")
        guard supervisor.send("CONTEXT_RECOVERY_ORIGINAL_REQUEST", to: id) else {
            throw Failure(description: "context-full fixture could not start its scripted turn")
        }
        let terminalDeadline = ContinuousClock.now + .seconds(20)
        while (supervisor.isRunning(id) || !supervisor.isQueuePaused(for: id)), ContinuousClock.now < terminalDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard !supervisor.isRunning(id), supervisor.isQueuePaused(for: id), runner.counts.runs == 1 else {
            throw Failure(description: "scripted context-full turn did not settle in the recovery state")
        }
        // Retain a real queued follow-up to prove that the failed recovery does
        // not enqueue, remove, resume, or otherwise change the pending work.
        _ = await drafts.enqueueMessage(text: "CONTEXT_RECOVERY_EXISTING_FOLLOWUP", for: id)
        let queuedBefore = await drafts.queuedWorkItems(for: id)
        guard !queuedBefore.isEmpty else { throw Failure(description: "fixture follow-up was not queued") }
        await supervisor.qaSaveTranscript(for: id)
        let releaseDeadline = ContinuousClock.now + .seconds(20)
        while !supervisor.isTranscriptReleased(id), ContinuousClock.now < releaseDeadline {
            supervisor.qaReleaseTranscriptIfDormant(id)
            await supervisor.qaWaitForTranscriptPersistence(for: id)
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard supervisor.isTranscriptReleased(id) else { throw Failure(description: "fixture transcript did not release") }
        let session = AgentTranscriptStore.canonicalSessionID(for: id)
        guard let before = try await transcripts.load(agentID: id, sessionID: session), !before.entries.isEmpty else {
            throw Failure(description: "fixture transcript was not saved before release")
        }
        let agentRoot = transcriptRoot.appendingPathComponent(id.rawValue.uuidString, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: agentRoot, includingPropertiesForKeys: nil),
              let snapshot = enumerator.allObjects.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "snapshot.json" }) else {
            throw Failure(description: "fixture saved snapshot missing")
        }
        let journal = snapshot.deletingLastPathComponent().appendingPathComponent("journal.json")
        let snapshotBytes = try Data(contentsOf: snapshot), journalBytes = try Data(contentsOf: journal)
        let savedSession = snapshot.deletingLastPathComponent().lastPathComponent
        let aside = fixture.appendingPathComponent("held-transcript", isDirectory: true)
        try FileManager.default.moveItem(at: agentRoot, to: aside)
        let beforeRecords = Set(supervisor.records.keys)
        let beforeCalls = runner.counts

        // blockID is explicitly nil: the absent projection must not allow the
        // copy action to succeed or permit compact/retry to enqueue work.
        let copyResult = await supervisor.recoverContextFull(.copyTranscript, for: id, blockID: nil)
        let compactResult = await supervisor.recoverContextFull(.compactAndRetry, for: id, blockID: nil)
        let forkResult = await supervisor.recoverContextFull(.forkWithSummary, for: id, blockID: nil)
        let heldSnapshot = aside.appendingPathComponent(savedSession).appendingPathComponent("snapshot.json")
        let heldJournal = aside.appendingPathComponent(savedSession).appendingPathComponent("journal.json")
        guard copyResult == nil, compactResult == nil, forkResult == nil,
              supervisor.isTranscriptReleased(id), !warnings.isEmpty,
              Set(supervisor.records.keys) == beforeRecords,
              await drafts.queuedWorkItems(for: id) == queuedBefore,
              runner.counts.runs == beforeCalls.runs, runner.counts.compactions == beforeCalls.compactions,
              !FileManager.default.fileExists(atPath: agentRoot.path),
              try Data(contentsOf: heldSnapshot) == snapshotBytes,
              try Data(contentsOf: heldJournal) == journalBytes else {
            throw Failure(description: "context-full recovery acted after an unreadable transcript reload")
        }

        try FileManager.default.moveItem(at: aside, to: agentRoot)
        guard await supervisor.recoverContextFull(.copyTranscript, for: id, blockID: nil) == id,
              !supervisor.isTranscriptReleased(id),
              try await transcripts.load(agentID: id, sessionID: session) == before else {
            throw Failure(description: "context-full recovery did not become available after the original archive was repaired")
        }
        let localText = (supervisor.transcriptDocument(for: id)?.entries ?? [])
            .map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
        guard localText.contains("CONTEXT_RECOVERY_OLD_HISTORY"),
              await drafts.queuedWorkItems(for: id) == queuedBefore else {
            throw Failure(description: "repaired recovery lost old history or changed the queued follow-up")
        }
    }
}

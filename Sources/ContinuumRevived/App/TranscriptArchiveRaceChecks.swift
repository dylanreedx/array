import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// Checks the delete/save interleaving using a paused detached save and
/// quarantine lifecycle hooks. The negative check uses a bounded observation
/// interval after the quarantine task has started, so this is a timing-based
/// race witness in addition to the final on-disk outcome assertion.
@MainActor
enum TranscriptArchiveRaceChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    private actor SaveGate {
        private(set) var entered = false
        private var resumed = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            entered = true
            if resumed { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            resumed = true
            continuation?.resume()
            continuation = nil
        }
    }

    private final class QuarantineSignals: @unchecked Sendable {
        private let lock = NSLock()
        private var didStart = false
        private var didFinish = false
        func start() { lock.lock(); didStart = true; lock.unlock() }
        func finish() { lock.lock(); didFinish = true; lock.unlock() }
        func read() -> (started: Bool, finished: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (didStart, didFinish)
        }
    }

    static func run(root: URL) async throws {
        let fixture = root.appendingPathComponent("archive-save-race", isDirectory: true)
        let agentStore = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let transcriptRoot = fixture.appendingPathComponent("transcripts", isDirectory: true)
        let transcriptStore = AgentTranscriptStore(root: transcriptRoot)
        let id = AgentID(rawValue: UUID())
        try agentStore.upsert(AgentRecord(id: id, displayName: "Archive save race", harness: .pi,
                                         model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: root.path,
                                         createdAt: Date(), lastActivityAt: Date()))
        let supervisor = AgentSupervisor(store: agentStore, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil }, transcriptStore: transcriptStore)
        _ = supervisor.restore()
        guard supervisor.records[id] != nil else { throw Failure(description: "fixture agent was not restored") }
        let gate = SaveGate()
        let signals = QuarantineSignals()
        supervisor.qaBeforeTranscriptSave = { await gate.wait() }
        supervisor.qaQuarantineStarted = { signals.start() }
        supervisor.qaQuarantineFinished = { signals.finish() }
        defer { Task { await gate.release() } }

        let marker = "SAVE_WHILE_ARCHIVING"
        let thread = AgentSupervisor.threadId(for: id)
        supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: marker), to: id)
        supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: marker, streamKind: .assistant, delta: marker), to: id)
        supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: marker, outcome: .completed, errorMessage: nil), to: id)
        let saveDeadline = ContinuousClock.now + .seconds(20)
        while !(await gate.entered), ContinuousClock.now < saveDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard await gate.entered else { throw Failure(description: "detached transcript save did not reach its gate") }

        let report = supervisor.archive(id)
        guard report.recordDeleted else { throw Failure(description: "fixture agent could not be archived") }
        let quarantineStartDeadline = ContinuousClock.now + .seconds(20)
        while !signals.read().started, ContinuousClock.now < quarantineStartDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard signals.read().started else { throw Failure(description: "quarantine task did not start") }
        // The negative half uses a bounded interval; it is a scheduler-dependent
        // witness, not a mathematical proof that another task could never run.
        try? await Task.sleep(for: .milliseconds(500))
        let finishedWhileSavePaused = signals.read().finished
        await gate.release()
        let quarantineDeadline = ContinuousClock.now + .seconds(20)
        while !signals.read().finished, ContinuousClock.now < quarantineDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard signals.read().finished else { throw Failure(description: "quarantine did not finish after the save resumed") }
        guard !finishedWhileSavePaused else { throw Failure(description: "quarantine finished before the pending save") }

        let source = transcriptRoot.appendingPathComponent(id.rawValue.uuidString, isDirectory: true)
        let quarantine = transcriptRoot.appendingPathComponent("quarantine-\(id.rawValue.uuidString)", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: source.path),
              let enumerator = FileManager.default.enumerator(at: quarantine, includingPropertiesForKeys: nil),
              let snapshot = enumerator.allObjects.compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "snapshot.json" }) else {
            throw Failure(description: "pending save recreated the active directory or was not quarantined")
        }
        let archive = try JSONCodec.makeDecoder().decode(AgentTranscriptArchive.self, from: Data(contentsOf: snapshot))
        let text = archive.document.entries.map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
        guard text.contains(marker) else { throw Failure(description: "quarantine omitted the pending saved history") }
    }
}

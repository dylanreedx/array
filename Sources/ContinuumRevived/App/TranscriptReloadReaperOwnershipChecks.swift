import ContinuumRevivedCore
import Foundation

/// The held reload batch and later-arriving FIFO both relinquish captured
/// values off main when an agent is archived during the bounded drain.
@MainActor
enum TranscriptReloadReaperOwnershipChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private actor Gate {
        private(set) var entered = false
        private var opened = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() { opened = true; continuation?.resume(); continuation = nil }
    }
    private final class Record: @unchecked Sendable {
        private let lock = NSLock()
        private var destructions: [Bool] = []
        private var executed = false
        func markExecuted() { lock.lock(); executed = true; lock.unlock() }
        func destroyed(_ onMain: Bool) { lock.lock(); destructions.append(onMain); lock.unlock() }
        func read() -> ([Bool], Bool) { lock.lock(); defer { lock.unlock() }; return (destructions, executed) }
    }
    private final class Probe: @unchecked Sendable {
        let record: Record
        init(_ record: Record) { self.record = record }
        @inline(never) func touch() { record.markExecuted() }
        deinit { record.destroyed(Thread.isMainThread) }
    }
    @inline(never)
    private static func enqueue(_ supervisor: AgentSupervisor, id: AgentID, record: Record) {
        let probe = Probe(record)
        supervisor.qaEnqueueReloadReleaseProbe(for: id) { [probe] in probe.touch() }
    }

    static func run(root: URL) async throws {
        let oldDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        defer { AgentSupervisor.transcriptReleaseDelay = oldDelay }
        let fixture = root.appendingPathComponent("reload-reaper-ownership", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let store = AgentTranscriptStore(root: fixture.appendingPathComponent("transcripts"))
        let id = AgentID(rawValue: UUID())
        let thread = AgentSupervisor.threadId(for: id)
        try agents.upsert(AgentRecord(id: id, displayName: "Reload reaper", harness: .pi,
                                     model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: fixture.path,
                                     createdAt: Date(), lastActivityAt: Date()))
        let supervisor = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil }, transcriptStore: store)
        _ = supervisor.restore()
        guard supervisor.records[id] != nil else { throw Failure(description: "reload reaper agent did not restore") }
        defer {
            supervisor.qaBeforeResumedTranscriptConstruction = nil
            supervisor.qaAfterTranscriptReloadChunk = nil
            supervisor.qaAfterReloadBatchDiscard = nil
            supervisor.qaAfterReloadBatchDiscardScheduled = nil
            supervisor.qaAfterArchivedReloadDiscard = nil
            supervisor.qaAfterArchivedReloadDiscardScheduled = nil
            supervisor.stopAll()
        }
        func deliver(_ turn: String) {
            supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: turn), to: id)
            supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: turn, streamKind: .assistant, delta: turn), to: id)
            supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: turn, outcome: .completed, errorMessage: nil), to: id)
        }
        deliver("REAPER_SETUP")
        await supervisor.qaSaveTranscript(for: id)
        let releaseDeadline = ContinuousClock.now + .seconds(20)
        while !supervisor.isTranscriptReleased(id), ContinuousClock.now < releaseDeadline {
            supervisor.qaReleaseTranscriptIfDormant(id)
            await supervisor.qaWaitForTranscriptPersistence(for: id)
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard supervisor.isTranscriptReleased(id) else { throw Failure(description: "reload reaper fixture did not release") }
        let gate = Gate()
        supervisor.qaBeforeResumedTranscriptConstruction = { agent, preflight in
            if agent == id && !preflight { await gate.wait() }
        }
        defer { Task { await gate.open() } }
        let attachment = supervisor.transcriptAttachment(for: id, reboundTo: "reload-reaper")
        guard let reload = attachment.reload else { throw Failure(description: "reload reaper fixture did not start reload") }
        let gateDeadline = ContinuousClock.now + .seconds(20)
        while !(await gate.entered), ContinuousClock.now < gateDeadline { try? await Task.sleep(for: .milliseconds(10)) }
        guard await gate.entered else { throw Failure(description: "reload reaper construction did not reach gate") }
        for index in 0..<100 { deliver("REAPER_\(index)") }
        let batch = Record(), later = Record()
        enqueue(supervisor, id: id, record: batch)
        guard batch.read().0.isEmpty else { throw Failure(description: "held batch probe was released early") }
        let batchDiscarded = DispatchSemaphore(value: 0), laterDiscarded = DispatchSemaphore(value: 0)
        var batchAtCheckpoint: ([Bool], Bool)?, laterAtCheckpoint: ([Bool], Bool)?
        var batchTimedOut = false, laterTimedOut = false
        supervisor.qaAfterReloadBatchDiscard = { agent in if agent == id { batchDiscarded.signal() } }
        supervisor.qaAfterReloadBatchDiscardScheduled = { agent in
            guard agent == id else { return }
            guard batchDiscarded.wait(timeout: .now() + 10) == .success else { batchTimedOut = true; return }
            batchAtCheckpoint = batch.read()
        }
        supervisor.qaAfterArchivedReloadDiscard = { agent in if agent == id { laterDiscarded.signal() } }
        supervisor.qaAfterArchivedReloadDiscardScheduled = { agent in
            guard agent == id else { return }
            guard laterDiscarded.wait(timeout: .now() + 10) == .success else { laterTimedOut = true; return }
            laterAtCheckpoint = later.read()
        }
        var scheduled = false, archived = false
        supervisor.qaAfterTranscriptReloadChunk = { agent, _ in
            guard agent == id, !scheduled else { return }
            scheduled = true
            Task { @MainActor in
                guard supervisor.qaTranscriptReloadTask(for: id) != nil else { return }
                enqueue(supervisor, id: id, record: later)
                archived = supervisor.archive(id).recordDeleted
            }
        }
        await gate.open()
        await reload.value
        let batchResult = batch.read(), laterResult = later.read()
        guard scheduled, archived, !batchTimedOut, !laterTimedOut,
              batchAtCheckpoint?.0 == [false], batchAtCheckpoint?.1 == false,
              laterAtCheckpoint?.0 == [false], laterAtCheckpoint?.1 == false,
              batchResult.0 == [false], !batchResult.1, laterResult.0 == [false], !laterResult.1 else {
            throw Failure(description: "reload FIFO probes were executed, retained, or released on main (batch checkpoint=\(String(describing: batchAtCheckpoint)), later checkpoint=\(String(describing: laterAtCheckpoint)), batch=\(batchResult), later=\(laterResult), timeouts=\(batchTimedOut)/\(laterTimedOut))")
        }
    }
}

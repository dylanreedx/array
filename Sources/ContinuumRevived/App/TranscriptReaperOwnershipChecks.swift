import ContinuumRevivedCore
import Foundation

/// The real absent-archive preflight must hand its FIFO to the reaper before
/// detached cleanup starts, so the main actor cannot release the last copy.
@MainActor
enum TranscriptReaperOwnershipChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            guard !opened else { return }
            opened = true
            let waiting = waiters
            waiters.removeAll()
            waiting.forEach { $0.resume() }
        }
    }

    private final class DestructionRecord: @unchecked Sendable {
        private let lock = NSLock()
        private var mainThreadValues: [Bool] = []
        func append(_ isMain: Bool) {
            lock.lock(); mainThreadValues.append(isMain); lock.unlock()
        }
        func snapshot() -> [Bool] {
            lock.lock(); defer { lock.unlock() }
            return mainThreadValues
        }
    }

    private final class Probe: @unchecked Sendable {
        let record: DestructionRecord
        init(record: DestructionRecord) { self.record = record }
        @inline(never) func touch() { withExtendedLifetime(record) {} }
        deinit { record.append(Thread.isMainThread) }
    }

    /// Keep the fixture's own probe reference out of scope before the reaper
    /// runs; the only remaining ownership belongs to the production FIFO.
    @inline(never)
    private static func enqueueProbe(_ supervisor: AgentSupervisor, id: AgentID, record: DestructionRecord) {
        let probe = Probe(record: record)
        supervisor.qaEnqueueCanonicalReleaseProbe(for: id) { [probe] in probe.touch() }
    }

    static func run(root: URL) async throws {
        var failures: [String] = []
        do { try await runAbsentPreflight(root: root) }
        catch { failures.append("absent preflight: \(error)") }
        do { try await runArchive(root: root) }
        catch { failures.append("archive: \(error)") }
        guard failures.isEmpty else { throw Failure(description: failures.joined(separator: "\n")) }
    }

    private static func runAbsentPreflight(root: URL) async throws {
        let fixture = root.appendingPathComponent("transcript-reaper-ownership", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let store = AgentTranscriptStore(root: fixture.appendingPathComponent("transcripts"))
        let id = AgentID(rawValue: UUID())
        try agents.upsert(AgentRecord(id: id, displayName: "Reaper ownership", harness: .pi,
                                     model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: fixture.path,
                                     createdAt: Date(), lastActivityAt: Date()))
        let migrationGate = Gate()
        let discardGate = Gate()
        let migration: Task<AgentTranscriptStore.MigrationReport, Error> = Task.detached {
            await migrationGate.wait()
            return AgentTranscriptStore.MigrationReport()
        }
        defer {
            Task { await migrationGate.open(); await discardGate.open() }
        }
        let supervisor = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil },
                                         transcriptStore: store, transcriptMigrationTaskProvider: { migration })
        _ = supervisor.restore()
        guard supervisor.records[id] != nil else { throw Failure(description: "fixture agent did not restore") }
        defer {
            supervisor.qaAfterAbsentCanonicalDiscard = nil
            supervisor.qaAfterAbsentCanonicalDiscardScheduled = nil
            supervisor.stopAll()
        }
        let record = DestructionRecord()
        var observationAtCheckpoint: [Bool]?
        supervisor.qaAfterAbsentCanonicalDiscard = { agent in
            guard agent == id else { return }
            Task { await discardGate.open() }
        }
        supervisor.qaAfterAbsentCanonicalDiscardScheduled = { agent in
            guard agent == id else { return }
            // Only a broken witness seam needs this bound; the normal signal
            // comes from the detached task after it has discarded the FIFO.
            let timeout = Task {
                try? await Task.sleep(for: .seconds(10))
                await discardGate.open()
            }
            await discardGate.wait()
            timeout.cancel()
            // This checkpoint still runs inside the real branch scope, after
            // the detached reaper has discarded its array.
            observationAtCheckpoint = record.snapshot()
        }
        enqueueProbe(supervisor, id: id, record: record)
        guard supervisor.qaCanonicalPreflightIsRunning(id), record.snapshot().isEmpty else {
            throw Failure(description: "fixture did not hold the probe in the pending preflight")
        }
        await migrationGate.open()
        await supervisor.qaWaitForTranscriptPersistence(for: id)
        guard observationAtCheckpoint == [false], record.snapshot() == [false] else {
            throw Failure(description: "pending FIFO probe was not destroyed off main before leaving the handoff: checkpoint=\(String(describing: observationAtCheckpoint)), final=\(record.snapshot())")
        }
    }

    private static func runArchive(root: URL) async throws {
        let fixture = root.appendingPathComponent("transcript-archived-reaper-ownership", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let store = AgentTranscriptStore(root: fixture.appendingPathComponent("transcripts"))
        let id = AgentID(rawValue: UUID())
        try agents.upsert(AgentRecord(id: id, displayName: "Archived reaper ownership", harness: .pi,
                                     model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: fixture.path,
                                     createdAt: Date(), lastActivityAt: Date()))
        let migrationGate = Gate()
        let migration: Task<AgentTranscriptStore.MigrationReport, Error> = Task.detached {
            await migrationGate.wait()
            return AgentTranscriptStore.MigrationReport()
        }
        defer { Task { await migrationGate.open() } }
        let supervisor = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil },
                                         transcriptStore: store, transcriptMigrationTaskProvider: { migration })
        _ = supervisor.restore()
        guard supervisor.records[id] != nil else { throw Failure(description: "archive fixture agent did not restore") }
        defer {
            supervisor.qaAfterArchivedCanonicalDiscard = nil
            supervisor.qaAfterArchivedCanonicalDiscardScheduled = nil
            supervisor.stopAll()
        }
        let record = DestructionRecord()
        let discarded = DispatchSemaphore(value: 0)
        var observationAtCheckpoint: [Bool]?
        var checkpointTimedOut = false
        supervisor.qaAfterArchivedCanonicalDiscard = { agent in
            guard agent == id else { return }
            discarded.signal()
        }
        supervisor.qaAfterArchivedCanonicalDiscardScheduled = { agent in
            guard agent == id else { return }
            // The archive API is synchronous; only this QA callback blocks,
            // with a deadline, until the independent detached reaper finishes.
            guard discarded.wait(timeout: .now() + 10) == .success else {
                checkpointTimedOut = true
                return
            }
            observationAtCheckpoint = record.snapshot()
        }
        enqueueProbe(supervisor, id: id, record: record)
        guard supervisor.qaCanonicalPreflightIsRunning(id), record.snapshot().isEmpty else {
            throw Failure(description: "archive fixture did not hold its pending probe")
        }
        let report = supervisor.archive(id)
        guard report.recordDeleted, !checkpointTimedOut,
              observationAtCheckpoint == [false], record.snapshot() == [false] else {
            throw Failure(description: "archive FIFO probe was not destroyed off main before leaving the handoff: checkpoint=\(String(describing: observationAtCheckpoint)), final=\(record.snapshot()), timedOut=\(checkpointTimedOut)")
        }
    }
}

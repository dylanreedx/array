import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// Measure and verify the main-actor drain after a delayed released reload.
@MainActor
enum TranscriptReloadBurstChecks {
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
        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    static func run(root: URL) async throws {
        let oldDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        defer { AgentSupervisor.transcriptReleaseDelay = oldDelay }
        let fixture = root.appendingPathComponent("released-reload-burst", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let store = AgentTranscriptStore(root: fixture.appendingPathComponent("transcripts"))
        let id = AgentID(rawValue: UUID())
        let thread = AgentSupervisor.threadId(for: id)
        let session = AgentTranscriptStore.canonicalSessionID(for: id)
        try agents.upsert(AgentRecord(id: id, displayName: "Reload burst", harness: .pi,
                                     model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: fixture.path,
                                     createdAt: Date(), lastActivityAt: Date()))
        var prior = ManagedAgentTranscriptModel(threadId: thread)
        for index in 0..<1_200 { prior.appendUserPrompt("RELOAD_BURST_PRIOR_\(index)") }
        try await store.saveSnapshot(agentID: id, sessionID: session, document: prior.document)
        let supervisor = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil }, transcriptStore: store)
        _ = supervisor.restore()
        guard supervisor.records[id] != nil else { throw Failure(description: "reload burst fixture did not restore") }
        defer { supervisor.qaBeforeResumedTranscriptConstruction = nil; supervisor.stopAll() }
        func deliver(_ marker: String) {
            supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: marker), to: id)
            supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: marker, streamKind: .assistant, delta: marker), to: id)
            supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: marker, outcome: .completed, errorMessage: nil), to: id)
        }
        deliver("RELOAD_BURST_SETUP")
        await supervisor.qaSaveTranscript(for: id)
        let releaseDeadline = ContinuousClock.now + .seconds(20)
        while !supervisor.isTranscriptReleased(id), ContinuousClock.now < releaseDeadline {
            supervisor.qaReleaseTranscriptIfDormant(id)
            await supervisor.qaWaitForTranscriptPersistence(for: id)
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard supervisor.isTranscriptReleased(id),
              let original = try await store.load(agentID: id, sessionID: session), original.entries.count >= 1_200 else {
            throw Failure(description: "reload burst fixture could not release its prior archive")
        }
        let gate = Gate()
        supervisor.qaBeforeResumedTranscriptConstruction = { agent, isPreflight in
            if agent == id && !isPreflight { await gate.wait() }
        }
        defer { Task { await gate.open() } }
        let attachment = supervisor.transcriptAttachment(for: id, reboundTo: "reload-burst")
        guard let reload = attachment.reload else { throw Failure(description: "reload burst did not start reload") }
        let gateDeadline = ContinuousClock.now + .seconds(20)
        while !(await gate.entered), ContinuousClock.now < gateDeadline { try? await Task.sleep(for: .milliseconds(10)) }
        guard await gate.entered else { throw Failure(description: "reload burst construction did not reach gate") }
        let count = 400
        let markers = (0..<count).map { String(format: "RELOAD_BURST_%04d_END", $0) }
        for marker in markers { deliver(marker) }
        guard supervisor.isTranscriptReleased(id) else { throw Failure(description: "reload burst fixture resumed before its gate") }
        var measuring = true, samplerStarted = false
        var frameCPU: [Double] = []
        let sampler = Task { @MainActor in
            samplerStarted = true
            while measuring {
                let before = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                try? await Task.sleep(for: .milliseconds(16))
                frameCPU.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - before) / 1_000_000)
            }
        }
        while !samplerStarted { await Task.yield() }
        await gate.open()
        await reload.value
        await supervisor.qaWaitForTranscriptPersistence(for: id)
        measuring = false
        await sampler.value
        guard !frameCPU.isEmpty else { throw Failure(description: "reload burst did not sample main-thread CPU") }
        let sorted = frameCPU.sorted()
        let p95 = sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
        let maximum = sorted.last ?? 0
        print(String(format: "METRIC reload-burst prior=%d turns=%d main frame CPU p95=%.3fms max=%.3fms samples=%d",
                     original.entries.count, count, p95, maximum, frameCPU.count))
        await supervisor.qaSaveTranscript(for: id)
        guard !supervisor.qaTranscriptPersistenceIsBlocked(id),
              let saved = try await store.load(agentID: id, sessionID: session),
              Array(saved.entries.prefix(original.entries.count)) == original.entries else {
            throw Failure(description: "reload burst lost its prior archive")
        }
        let text = saved.entries.map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
        var previous: String.Index?
        for marker in markers {
            guard text.components(separatedBy: marker).count - 1 == 1, let range = text.range(of: marker),
                  previous.map({ $0 < range.lowerBound }) ?? true else {
                throw Failure(description: "reload burst lost, duplicated or reordered \(marker)")
            }
            previous = range.lowerBound
        }
        guard p95 < TranscriptSavePerfChecks.frameBudgetMilliseconds else {
            throw Failure(description: String(format: "reload burst main-thread p95 %.3fms exceeded %.1fms frame budget", p95,
                                              TranscriptSavePerfChecks.frameBudgetMilliseconds))
        }
    }
}

import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// A preflight delayed by I/O must drain its pending canonical writes without
/// monopolizing the main actor or moving new arrivals ahead of queued history.
@MainActor
enum TranscriptPreflightReplayChecks {
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
            let queued = waiters
            waiters.removeAll()
            queued.forEach { $0.resume() }
        }
    }

    private static func cpu() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
    private static func percentile(_ values: [Double], _ p: Int) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, sorted.count * p / 100)]
    }
    private static func body(_ document: AgentDocument?) -> String {
        (document?.entries ?? []).map { AgentTranscriptCopyController.plainText(for: $0.blocks) }.joined(separator: "\n")
    }

    static func run(root: URL) async throws {
        let oldDelay = AgentSupervisor.transcriptReleaseDelay
        AgentSupervisor.transcriptReleaseDelay = .seconds(60)
        defer { AgentSupervisor.transcriptReleaseDelay = oldDelay }
        try await runFIFO(root: root)
    }

    private static func runFIFO(root: URL) async throws {
        let fixture = root.appendingPathComponent("preflight-replay-fifo", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let agents = AgentStore(applicationSupportDirectory: fixture.appendingPathComponent("agents"))
        let store = AgentTranscriptStore(root: fixture.appendingPathComponent("transcripts"))
        let id = AgentID(rawValue: UUID())
        let session = AgentTranscriptStore.canonicalSessionID(for: id)
        let thread = AgentSupervisor.threadId(for: id)
        try agents.upsert(AgentRecord(id: id, displayName: "Replay FIFO", harness: .pi,
                                     model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: fixture.path,
                                     createdAt: Date(), lastActivityAt: Date()))
        var prior = ManagedAgentTranscriptModel(threadId: thread)
        for index in 0..<1_200 { prior.appendUserPrompt("PRIOR_\(index)") }
        try await store.saveSnapshot(agentID: id, sessionID: session, document: prior.document)
        guard let original = try await store.load(agentID: id, sessionID: session), original.entries.count == 1_200 else {
            throw Failure(description: "could not create the 1,200-entry prior archive")
        }
        let gate = Gate()
        let migration: Task<AgentTranscriptStore.MigrationReport, Error> = Task.detached {
            await gate.wait()
            return try await store.migrateLegacySessionDirectories()
        }
        defer { Task { await gate.open() } }
        var warnings: [String] = []
        let supervisor = AgentSupervisor(store: agents, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { warnings.append($0) }, nameTitlerCommand: { _ in nil },
                                         transcriptStore: store, transcriptMigrationTaskProvider: { migration })
        _ = supervisor.restore()
        guard supervisor.records[id] != nil else { throw Failure(description: "FIFO fixture agent did not restore") }
        defer {
            supervisor.qaAfterCanonicalReplayChunk = nil
            supervisor.qaCanonicalReplayPhaseCPU = nil
            supervisor.stopAll()
        }
        supervisor.seedRehydratedTranscript(RehydratedTranscript(steps: [.userPrompt("REPLAY_PROVIDER_LOCAL")],
                                                                restoredMessageCount: 1, omittedEarlier: true), for: id)
        func deliver(_ marker: String) {
            supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: marker), to: id)
            supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: marker, streamKind: .assistant, delta: marker), to: id)
            supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: marker, outcome: .completed, errorMessage: nil), to: id)
        }
        let queuedCount = 400
        let markers = (0..<queuedCount).map { String(format: "REPLAY_QUEUED_%04d_END", $0) }
        for marker in markers { deliver(marker) }
        guard supervisor.qaCanonicalPreflightIsRunning(id) else { throw Failure(description: "fixture preflight was not gated") }
        var phaseCPU: [String: (count: Int, total: UInt64, maximum: UInt64)] = [:]
        let capturePhases = ProcessInfo.processInfo.environment["CONTINUUM_TRANSCRIPT_REPLAY_TIMING"] == "1"
        if capturePhases {
            supervisor.qaCanonicalReplayPhaseCPU = { phase, duration in
                let prior = phaseCPU[phase] ?? (0, 0, 0)
                phaseCPU[phase] = (prior.count + 1, prior.total + duration, max(prior.maximum, duration))
            }
        }
        var injectedCPU: UInt64 = 0
        var checkpoints = 0, scheduled = false, heartbeatInFlight = false, injected = false
        supervisor.qaAfterCanonicalReplayChunk = { agent, _ in
            guard agent == id else { return }
            checkpoints += 1
            guard !scheduled else { return }
            scheduled = true
            // This independent task cannot execute until the production replay
            // really suspends; the synchronous checkpoint supplies no yield.
            Task { @MainActor in
                heartbeatInFlight = supervisor.qaCanonicalPreflightIsRunning(id)
                if heartbeatInFlight {
                    let start = capturePhases ? cpu() : 0
                    deliver("REPLAY_INJECTED_AFTER_YIELD")
                    if capturePhases { injectedCPU = cpu() &- start }
                    injected = true
                }
            }
        }
        var measuring = true
        var frameCPU: [Double] = []
        let frames = Task { @MainActor in
            while measuring {
                let before = cpu()
                try? await Task.sleep(for: .milliseconds(16))
                frameCPU.append(Double(cpu() - before) / 1_000_000)
            }
        }
        await gate.open()
        await supervisor.qaWaitForTranscriptPersistence(for: id)
        measuring = false
        await frames.value
        guard checkpoints > 0, heartbeatInFlight, injected else {
            throw Failure(description: "canonical replay did not let the independent heartbeat run before it completed")
        }
        guard !supervisor.qaTranscriptPersistenceIsBlocked(id), warnings.isEmpty,
              let saved = try await store.load(agentID: id, sessionID: session),
              saved.entries.count >= original.entries.count + queuedCount + 1,
              Array(saved.entries.prefix(original.entries.count)) == original.entries else {
            throw Failure(description: "FIFO replay blocked or changed the prior archive")
        }
        let text = body(saved)
        var previous: String.Index?
        for marker in markers + ["REPLAY_INJECTED_AFTER_YIELD"] {
            guard text.components(separatedBy: marker).count - 1 == 1, let range = text.range(of: marker),
                  previous.map({ $0 < range.lowerBound }) ?? true else {
                throw Failure(description: "canonical replay lost, duplicated, or reordered \(marker)")
            }
            previous = range.lowerBound
        }
        guard !text.contains("REPLAY_PROVIDER_LOCAL") else {
            throw Failure(description: "canonical replay exposed the provider-only restore")
        }
        guard !frameCPU.isEmpty else { throw Failure(description: "no main-thread replay frame was sampled") }
        let p95 = percentile(frameCPU, 95), maximum = frameCPU.max() ?? 0
        print(String(format: "METRIC preflight-replay prior=%d turns=%d checkpoints=%d main frame CPU p95=%.3fms max=%.3fms samples=%d",
                     original.entries.count, queuedCount, checkpoints, p95, maximum, frameCPU.count))
        for phase in ["initialization worker", "mutation", "chunk", "flush and install", "save setup"] {
            if let sample = phaseCPU[phase] {
                print(String(format: "METRIC preflight-replay phase=%@ count=%d total=%.3fms max=%.3fms",
                             phase, sample.count, Double(sample.total) / 1_000_000, Double(sample.maximum) / 1_000_000))
            }
        }
        if capturePhases {
            print(String(format: "METRIC preflight-replay injected-turn=%.3fms", Double(injectedCPU) / 1_000_000))
        }
        guard p95 < TranscriptSavePerfChecks.frameBudgetMilliseconds else {
            throw Failure(description: String(format: "preflight replay main-thread p95 %.3fms exceeded %.1fms frame budget", p95,
                                              TranscriptSavePerfChecks.frameBudgetMilliseconds))
        }
    }

}

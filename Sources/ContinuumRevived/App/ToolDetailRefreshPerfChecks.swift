import Foundation
import ContinuumRevivedAgentContent
import ContinuumRevivedCore

/// `--tool-detail-refresh-perf-check`: what a burst of tool events costs the
/// main thread through the tool-detail capture (`AgentTranscriptCanvasToolDetail`),
/// and that what the capture holds afterwards is exactly its store's records.
///
/// Three real supervisor agents. The time is the main thread's own CPU time,
/// read across frame-long waits in which this check delivers nothing, so it is
/// the work the capture's refreshes land on main, not the event ingest.
///
/// - After a burst (220 tool runs per agent delivered at once to three agents'
///   captures), the main thread stays under 4 ms in every frame, and the
///   fallout totals under 50 ms. Before, every event read every record and the
///   main thread freed each snapshot, for seconds. The whole supervisor after
///   the same burst (tool detail and transcript saves together) stays under
///   4 ms per frame too.
/// - Paced: a tool run per agent every frame while the transcript is presented
///   each frame (as a tile does): under 4 ms per frame at p95.
/// - Same output: each capture holds the store's own records, and every tool
///   block presents as an uncached presentation of those records would. An
///   expired record leaves the capture as it leaves the store.
@MainActor
enum ToolDetailRefreshPerfChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(description: message()) }
    }

    static let frameBudgetMilliseconds = 4.0
    static let falloutBudgetMilliseconds = 50.0

    private static func mainThreadCPU() -> Duration {
        precondition(Thread.isMainThread)
        return .nanoseconds(Int64(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)))
    }
    private static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
    private static func percentile(_ xs: [Double], _ p: Int) -> Double {
        let sorted = xs.sorted()
        return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, sorted.count * p / 100)]
    }
    private static func stats(_ xs: [Double]) -> String {
        String(format: "n=%d median=%.3fms p95=%.3fms max=%.3fms total=%.1fms", xs.count, percentile(xs, 50), percentile(xs, 95),
               xs.max() ?? 0, xs.reduce(0, +))
    }

    /// Main-thread CPU over one frame in which this check does nothing.
    private static func idleFrame() async -> Double {
        let before = mainThreadCPU()
        try? await Task.sleep(for: .milliseconds(16))
        return ms(mainThreadCPU() - before)
    }

    static func run() async throws {
        var failures: [String] = []
        do { try await captureBurst() } catch { failures.append("\(error)") }
        do { try await burst() } catch { failures.append("\(error)") }
        do { try await expiry() } catch { failures.append("\(error)") }
        guard failures.isEmpty else { throw Failure(description: failures.joined(separator: "\nFAIL: ")) }
        print("PASS: tool detail refresh stays inside its main-thread budget during and after a burst, and holds the store's records")
    }

    private static func deliverTurn(_ supervisor: AgentSupervisor, _ id: AgentID, _ turn: Int) {
        let thread = AgentSupervisor.threadId(for: id), t = "h\(turn)"
        supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: t), to: id)
        supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: t, streamKind: .reasoning, delta: "Checkout state validates. "), to: id)
        supervisor.qaDeliver(.itemStarted(threadId: thread, itemId: "c\(turn)", kind: .commandExecution, title: "rg -n state Sources/Checkout"), to: id)
        supervisor.qaDeliver(.itemCompleted(threadId: thread, itemId: "c\(turn)", kind: .commandExecution, status: turn % 7 == 0 ? .failed : .completed), to: id)
        supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: t, streamKind: .assistant, delta: "Turn \(turn) settles the ledger. "), to: id)
        supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: t, outcome: .completed, errorMessage: nil), to: id)
    }

    /// The capture alone: three agents' captures, each on its own store, take
    /// 220 tool runs at once, as the supervisor's do in a burst.
    private static func captureBurst() async throws {
        let runs = 220
        let agents = (0..<3).map { _ in AgentID(rawValue: UUID()) }
        let captures = agents.map { agent -> AgentTranscriptCanvasToolDetail in
            let capture = AgentTranscriptCanvasToolDetail(store: AgentToolDetailStore())
            capture.bind(agentID: agent)
            return capture
        }
        var refreshes = 0
        for capture in captures { capture.onRefresh = { refreshes += 1 } }
        for turn in 1...runs {
            for capture in captures {
                let thread = "thread", t = "t\(turn)"
                capture.captureRuntimeEvent(.turnStarted(threadId: thread, turnId: t))
                capture.captureRuntimeEvent(.itemStarted(threadId: thread, itemId: "c\(turn)", kind: .commandExecution, title: "rg -n state Sources/Checkout"))
                capture.captureRuntimeEvent(.itemCompleted(threadId: thread, itemId: "c\(turn)", kind: .commandExecution, status: turn % 7 == 0 ? .failed : .completed))
                capture.captureRuntimeEvent(.turnCompleted(threadId: thread, turnId: t, outcome: .completed, errorMessage: nil))
            }
        }
        var fallout: [Double] = []
        var quiet = 0
        let started = ContinuousClock.now
        while quiet < 5, ContinuousClock.now - started < .seconds(30) {
            let spent = await idleFrame()
            fallout.append(spent)
            quiet = spent < 0.25 ? quiet + 1 : 0
        }
        let settled = ContinuousClock.now - started
        print("METRIC tool-detail-refresh capture agents=3 runs=\(runs) after-burst per-frame \(stats(fallout)) settled=\(String(format: "%.0f", ms(settled)))ms refreshes=\(refreshes)")
        for capture in captures {
            await capture.qaWaitForRefresh()
            let held = await capture.qaDetailsMatchStore()
            try expect(held.equal && held.stored == runs, "capture burst: the capture holds \(held.held) records, the store \(held.stored) of \(runs), equal=\(held.equal)")
        }
        try expect(quiet >= 5, "the main thread never went quiet within 30 s of the burst")
        try expect(fallout.max() ?? 0 < frameBudgetMilliseconds, String(format:
            "after a burst one frame spent %.3f ms of main-thread time on tool detail, over the %.1f ms budget", fallout.max() ?? 0, frameBudgetMilliseconds))
        let total = fallout.reduce(0, +)
        try expect(total < falloutBudgetMilliseconds, String(format:
            "a burst's tool detail spent %.1f ms of main-thread time after it, over %.0f ms", total, falloutBudgetMilliseconds))
    }

    private static func burst() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tool-detail-refresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("agents"))
        let project = UUID()
        let ids = (0..<3).map { _ in AgentID(rawValue: UUID()) }
        for id in ids {
            try store.upsert(AgentRecord(id: id, displayName: "Burst", harness: .pi, model: AgentCatalogQAFixture.pi[0],
                                         thinking: "none", cwd: root.path, projectId: project, createdAt: Date(), lastActivityAt: Date()))
        }
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil },
                                         transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts", isDirectory: true)))
        _ = supervisor.restore()

        // A burst: every agent's tool runs at once.
        let runs = 220
        // Delivered in its own autorelease pool, so what the delivery autoreleases
        // (the agent-record writes' Foundation objects) is freed with it, as each
        // run-loop turn frees its own in the app, not in the next measured frame.
        autoreleasepool { for turn in 1...runs { for id in ids { deliverTurn(supervisor, id, turn) } } }
        var fallout: [Double] = []
        var quiet = 0
        let started = ContinuousClock.now
        while quiet < 5, ContinuousClock.now - started < .seconds(30) {
            let spent = await idleFrame()
            fallout.append(spent)
            quiet = spent < 0.25 ? quiet + 1 : 0
        }
        let settled = ContinuousClock.now - started
        // The whole supervisor after the burst: tool detail and transcript saves
        // together (`--transcript-save-perf-check` owns the saves' share).
        print("METRIC tool-detail-refresh supervisor agents=3 runs=\(runs) after-burst per-frame \(stats(fallout)) settled=\(String(format: "%.0f", ms(settled)))ms")
        try expect(quiet >= 5, "the main thread never went quiet within 30 s of the burst")
        try expect(fallout.max() ?? 0 < frameBudgetMilliseconds, String(format:
            "after a burst one frame spent %.3f ms of the supervisor's main-thread time, over the %.1f ms budget", fallout.max() ?? 0, frameBudgetMilliseconds))
        try await sameOutput(supervisor, ids, "after the burst", runs: runs)

        // Paced: a tool run per agent per frame, the transcript presented each
        // frame as a tile does, so presentations are cached when an end lands.
        var paced: [Double] = []
        for turn in (runs + 1)...(runs + 90) {
            for id in ids {
                deliverTurn(supervisor, id, turn)
                _ = supervisor.sharedTranscriptToolBlocks(for: id)
            }
            paced.append(await idleFrame())
        }
        for _ in 0..<40 { paced.append(await idleFrame()) }
        print("METRIC tool-detail-refresh agents=3 paced per-frame \(stats(paced))")
        try await sameOutput(supervisor, ids, "after paced runs", runs: runs + 90)

        try expect(percentile(paced, 95) < frameBudgetMilliseconds, String(format:
            "paced tool runs spent %.3f ms of main-thread time per frame at p95, over the %.1f ms budget", percentile(paced, 95), frameBudgetMilliseconds))
    }

    /// The capture holds the store's records, and every tool block presents as
    /// it would from those records with nothing cached.
    private static func sameOutput(_ supervisor: AgentSupervisor, _ ids: [AgentID], _ label: String, runs: Int) async throws {
        for id in ids {
            guard let capture = supervisor.qaSharedTranscriptToolDetail(for: id),
                  let document = supervisor.transcriptDocument(for: id) else { throw Failure(description: "\(label): no capture") }
            await capture.qaWaitForRefresh()
            let held = await capture.qaDetailsMatchStore()
            try expect(held.equal && held.stored == runs, "\(label): the capture holds \(held.held) records, the store \(held.stored) of \(runs) runs, equal=\(held.equal)")
            let live = capture.presentation
            let uncached = AgentTranscriptCanvasToolDetail.Presentation(
                agentID: live.agentID, identityByEntryID: live.identityByEntryID, details: live.details,
                timeToLive: live.timeToLive, clock: live.clock, cache: [:], generation: live.generation)
            var compared = 0
            for entry in document.entries {
                for block in entry.blocks {
                    guard case .toolCall = block.payload else { continue }
                    let fresh: AgentBlock
                    switch uncached.present(block, in: entry) {
                    case let .fresh(value, _), let .cached(value): fresh = value
                    case .unchanged, .fallback: fresh = block
                    }
                    try expect(capture.presented(block, in: entry) == fresh, "\(label): tool block \(block.id.rawValue) presents stale detail")
                    compared += 1
                }
            }
            try expect(compared == runs, "\(label): compared \(compared) tool blocks of \(runs)")
        }
        print("METRIC tool-detail-refresh \(label) records-and-presentations=equal")
    }

    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    }

    /// A record that expires in the store leaves the capture at its next refresh.
    private static func expiry() async throws {
        let clock = TestClock()
        let store = AgentToolDetailStore(clock: { clock.now }, timeToLive: 60)
        defer { Task { await store.shutdown() } }
        let capture = AgentTranscriptCanvasToolDetail(store: store)
        let agent = AgentID(rawValue: UUID())
        capture.bind(agentID: agent)
        let thread = "thread"
        capture.captureRuntimeEvent(.turnStarted(threadId: thread, turnId: "t1"))
        capture.captureRuntimeEvent(.itemStarted(threadId: thread, itemId: "old", kind: .commandExecution, title: "ls"))
        capture.captureRuntimeEvent(.itemCompleted(threadId: thread, itemId: "old", kind: .commandExecution, status: .completed))
        for _ in 0..<50 {
            if (await capture.qaDetailsMatchStore()).held >= 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await capture.qaWaitForRefresh()
        clock.advance(120)
        capture.captureRuntimeEvent(.itemStarted(threadId: thread, itemId: "new", kind: .commandExecution, title: "pwd"))
        for _ in 0..<100 {
            await capture.qaWaitForRefresh()
            let held = await capture.qaDetailsMatchStore()
            if held.equal && held.stored == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let held = await capture.qaDetailsMatchStore()
        try expect(held.equal && held.held == 1 && held.stored == 1,
                   "an expired record stays in the capture after the store drops it (capture \(held.held), store \(held.stored))")
        print("METRIC tool-detail-refresh expiry records-and-presentations=equal")
    }
}

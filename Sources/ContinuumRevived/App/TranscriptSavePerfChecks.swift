import Foundation
import ContinuumRevivedAgentContent
import ContinuumRevivedCore

/// `--transcript-save-perf-check`: what saving managed agents' transcripts costs
/// the main thread during and after a burst of finished turns, and that what
/// lands on disk is the document the supervisor holds.
///
/// Three real supervisor agents with fixed ids. Main-thread CPU is read per 16 ms frame: the frame's own
/// delivery (ingest, which pays for copying a document a pending save still
/// holds) and the idle rest of the frame (saves finishing, copies freed).
///
/// - After a burst (220 finished turns per agent at once): every frame under
///   4 ms of main-thread time, and under 50 ms in total.
/// - Paced (one finished turn per agent per frame): what the saves leave on
///   main in the rest of each frame under 4 ms at p95. The delivery itself is
///   the supervisor's transcript ingest; it is reported, not budgeted here.
/// - Positive control: once settled, each agent's `snapshot.json` (wall-clock
///   `savedAt` blanked) and `journal.json` are byte-identical to saving the
///   supervisor's final document directly through the same store, which is
///   what the old path's last save wrote.
@MainActor
enum TranscriptSavePerfChecks {
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
    private static func idleFrame(_ length: Duration = .milliseconds(16)) async -> Double {
        let before = mainThreadCPU()
        try? await Task.sleep(for: length)
        return ms(mainThreadCPU() - before)
    }

    private static let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let agentIDs = [
        "6F1C3A52-0B8D-4E41-9C71-2D5A6B7E8F01", "6F1C3A52-0B8D-4E41-9C71-2D5A6B7E8F02", "6F1C3A52-0B8D-4E41-9C71-2D5A6B7E8F03",
    ].map { AgentID(rawValue: UUID(uuidString: $0)!) }

    private static func deliverTurn(_ supervisor: AgentSupervisor, _ id: AgentID, _ turn: Int) {
        let thread = AgentSupervisor.threadId(for: id), t = "h\(turn)"
        func at(_ step: Int) -> Date { base.addingTimeInterval(Double(turn * 10 + step)) }
        supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: t), to: id, now: at(0))
        supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: t, streamKind: .reasoning, delta: "Checkout state validates. "), to: id, now: at(1))
        supervisor.qaDeliver(.itemStarted(threadId: thread, itemId: "c\(turn)", kind: .commandExecution, title: "rg -n state Sources/Checkout"), to: id, now: at(2))
        supervisor.qaDeliver(.itemCompleted(threadId: thread, itemId: "c\(turn)", kind: .commandExecution, status: .completed), to: id, now: at(3))
        supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: t, streamKind: .assistant, delta: "Turn \(turn) settles the ledger. "), to: id, now: at(4))
        supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: t, outcome: .completed, errorMessage: nil), to: id, now: at(5))
    }

    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let transcripts = root.appendingPathComponent("transcripts", isDirectory: true)
        let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("agents"))
        let project = UUID(uuidString: "6F1C3A52-0B8D-4E41-9C71-2D5A6B7E8F00")!
        for id in agentIDs {
            try store.upsert(AgentRecord(id: id, displayName: "Saves", harness: .pi, model: AgentCatalogQAFixture.pi[0],
                                         thinking: "none", cwd: "/tmp/transcript-save", projectId: project, createdAt: base, lastActivityAt: base))
        }
        let transcriptStore = AgentTranscriptStore(root: transcripts)
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) },
                                         warn: { _ in }, nameTitlerCommand: { _ in nil }, transcriptStore: transcriptStore)
        _ = supervisor.restore()
        var failures: [String] = []

        // A burst: 220 finished turns per agent at once.
        let runs = 220
        let burstStart = mainThreadCPU()
        for turn in 1...runs { for id in agentIDs { deliverTurn(supervisor, id, turn) } }
        print(String(format: "METRIC transcript-save agents=3 turns=%d burst delivery %.1fms", runs, ms(mainThreadCPU() - burstStart)))
        var fallout: [Double] = []
        var quiet = 0
        let started = ContinuousClock.now
        while quiet < 5, ContinuousClock.now - started < .seconds(30) {
            let spent = await idleFrame()
            fallout.append(spent)
            quiet = spent < 0.25 ? quiet + 1 : 0
        }
        print("METRIC transcript-save agents=3 turns=\(runs) after-burst per-frame \(stats(fallout))")
        if (fallout.max() ?? 0) >= frameBudgetMilliseconds {
            failures.append(String(format: "after a burst one frame spent %.3f ms of main-thread time, over the %.1f ms budget",
                                   fallout.max() ?? 0, frameBudgetMilliseconds))
        }
        if fallout.reduce(0, +) >= falloutBudgetMilliseconds {
            failures.append(String(format: "a burst's saves spent %.1f ms of main-thread time after it, over %.0f ms",
                                   fallout.reduce(0, +), falloutBudgetMilliseconds))
        }
        do { try await savedMatchesSupervisor(supervisor, transcriptStore, transcripts, "after the burst") } catch { failures.append("\(error)") }

        // Paced: one finished turn per agent per frame.
        // Delivery is the supervisor's ingest (the transcript projection parsing
        // and scanning), reported; the rest of the frame is what the saves
        // leave on main, asserted.
        var delivery: [Double] = [], rest: [Double] = []
        for turn in (runs + 1)...(runs + 90) {
            let before = mainThreadCPU()
            for id in agentIDs { deliverTurn(supervisor, id, turn) }
            delivery.append(ms(mainThreadCPU() - before))
            rest.append(await idleFrame())
        }
        print("METRIC transcript-save agents=3 paced delivery (ingest) per-frame \(stats(delivery))")
        print("METRIC transcript-save agents=3 paced rest-of-frame per-frame \(stats(rest))")
        print("METRIC transcript-save agents=3 paced whole-frame per-frame \(stats(zip(delivery, rest).map { $0 + $1 }))")
        if percentile(rest, 95) >= frameBudgetMilliseconds {
            failures.append(String(format: "paced finished turns left %.3f ms of main-thread work per frame at p95, over the %.1f ms budget",
                                   percentile(rest, 95), frameBudgetMilliseconds))
        }
        for _ in 0..<40 { _ = await idleFrame() }
        do { try await savedMatchesSupervisor(supervisor, transcriptStore, transcripts, "after paced turns") } catch { failures.append("\(error)") }

        guard failures.isEmpty else { throw Failure(description: failures.joined(separator: "\nFAIL: ")) }
        print("PASS: transcript saves stay inside the main-thread budget during and after a burst, and save the supervisor's document")
    }

    /// Each agent's saved files are byte-identical to saving the supervisor's
    /// final document directly, through the same store writer, into a
    /// reference root: `snapshot.json` (its wall-clock `savedAt` blanked) and
    /// `journal.json`. The old path's last save was exactly that direct save.
    private static func savedMatchesSupervisor(_ supervisor: AgentSupervisor, _ store: AgentTranscriptStore, _ root: URL,
                                               _ label: String) async throws {
        let referenceRoot = root.deletingLastPathComponent().appendingPathComponent("reference-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: referenceRoot) }
        let reference = AgentTranscriptStore(root: referenceRoot)
        var rawIdentical = 0
        for id in agentIDs {
            let sessionID = AgentTranscriptStore.canonicalSessionID(for: id)
            guard let live = supervisor.transcriptDocument(for: id) else { throw Failure(description: "\(label): no document") }
            try await reference.saveSnapshot(agentID: id, sessionID: sessionID, document: live)
            var files: (snapshot: Data, journal: Data)?
            var expected: (snapshot: Data, journal: Data)?
            for _ in 0..<200 {
                files = try? savedFiles(root, id)
                expected = try savedFiles(referenceRoot, id)
                if let files, let expected, files == expected { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            guard let files, let expected else { throw Failure(description: "\(label): no saved transcript") }
            if files.snapshot == expected.snapshot { rawIdentical += 1 } else {
                let at = zip(files.snapshot, expected.snapshot).prefix { $0 == $1 }.count
                func around(_ data: Data) -> String { String(decoding: data.dropFirst(max(0, at - 80)).prefix(200), as: UTF8.self) }
                fputs("DIAG \(label) raw bytes differ at \(at): saved …\(around(files.snapshot)) direct …\(around(expected.snapshot))\n", stderr)
            }
            // The store's encoder does not sort keys; compare every value byte for byte in one key order.
            try expect(try canonical(files.snapshot) == canonical(expected.snapshot),
                       "\(label): the saved snapshot is not the supervisor's document (\(files.snapshot.count) vs \(expected.snapshot.count) bytes)")
            try expect(try canonical(files.journal) == canonical(expected.journal), "\(label): the saved journal differs from a direct save's")
        }
        print("METRIC transcript-save \(label) saved-files=identical-to-direct-save agents=\(agentIDs.count) raw-bytes-identical=\(rawIdentical)")
    }

    private static func canonical(_ data: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject: try JSONSerialization.jsonObject(with: data), options: [.sortedKeys])
    }

    /// An agent's snapshot (with `savedAt` blanked) and journal, as bytes.
    private static func savedFiles(_ root: URL, _ id: AgentID) throws -> (snapshot: Data, journal: Data) {
        let directory = root.appendingPathComponent(id.rawValue.uuidString, isDirectory: true)
        guard let session = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("snapshot.json").path) }) else {
            throw Failure(description: "no session directory")
        }
        let snapshot = try Data(contentsOf: session.appendingPathComponent("snapshot.json"))
        let journal = try Data(contentsOf: session.appendingPathComponent("journal.json"))
        guard let saved = snapshot.range(of: Data("\"savedAt\":".utf8)) else { throw Failure(description: "the snapshot has no savedAt") }
        // Blank the number after `"savedAt":`, byte for byte everywhere else.
        var end = saved.upperBound
        while end < snapshot.endIndex, snapshot[end] != UInt8(ascii: ","), snapshot[end] != UInt8(ascii: "}") { end += 1 }
        var blanked = snapshot
        blanked.replaceSubrange(saved.upperBound..<end, with: Data("0".utf8))
        return (blanked, journal)
    }
}

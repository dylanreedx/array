import AppKit
import ContinuumRevivedCore

/// `--idle-waker-check`: an idle agent is woken once when a process it started
/// exits, and is not woken for work its CLI tracks. A reply that promises later
/// action is never nudged. Through the production supervisor (send,
/// turn-end, runner retention) and the production tracker's job-list diff; only
/// the CLI is a scripted runner.
@MainActor
enum AgentIdleWakerChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("idle-waker-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AgentCatalogQAFixture.pi[0]
        let previous = AgentModelCatalog.shared.snapshot(for: .pi)
        defer { AgentModelCatalog.shared.resetForQA(snapshot: previous) }
        AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .pi, readiness: .ready,
            models: [model], displayNames: [:], refreshedAt: Date()))
        let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("agents"))
        let agent = AgentID(rawValue: UUID())
        try store.upsert(AgentRecord(id: agent, displayName: "Waker", harness: .pi, model: model, thinking: "medium",
            cwd: root.path, createdAt: Date(), lastActivityAt: Date()))
        let runner = HelperCompletionChecks.HeldWakeRunner(autoEnd: true)
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in runner }, warn: { _ in },
            nameTitlerCommand: { _ in nil },
            submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: root.appendingPathComponent("drafts")),
            transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts", isDirectory: true)),
            maximumActiveManagedChildren: { nil })
        _ = supervisor.restore()
        defer { supervisor.stopAll() }
        let tracker = AgentProcessTracker(internalPathPrefixes: [])
        tracker.knownAgents = { [agent] }
        supervisor.processTracker = tracker
        supervisor.idleWaker.batchWindow = 0.3

        var failures: [String] = []
        func verdict(_ ok: Bool, _ label: String) {
            print("idle-waker-check: \(label) \(ok ? "PASS" : "FAIL")")
            if !ok { failures.append(label) }
        }
        func until(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return condition()
        }
        func settle(_ seconds: TimeInterval) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func idle() async -> Bool { await until { !supervisor.isRunning(agent) && runner.openTurns == 0 } }
        func wakes() -> [String] { runner.prompts.filter { $0.contains("background command") } }
                func job(_ pid: Int32, _ label: String, detached: Bool = true) -> AgentBackgroundJob {
            AgentBackgroundJob(id: "job-\(pid)", owner: agent.rawValue.uuidString, rootPid: pid, pids: [pid],
                startTimes: [:], label: label, commandLine: label, ports: [],
                startedAt: Date().addingTimeInterval(-90), detached: detached)
        }
        func publish(_ jobs: [AgentBackgroundJob]) { tracker.publish(jobs.isEmpty ? [:] : [agent.rawValue.uuidString: jobs]) }

        // The agent has run one turn, so its session is retained and it is idle.
        guard supervisor.send("start", to: agent) else { throw Failure(description: "the first turn did not start") }
        verdict(await idle(), "idle after its first turn")

        // (a) An untracked job exits while the agent is idle: exactly one wake.
        publish([job(9001, "swift build")])
        await settle(0.1)
        publish([])
        verdict(await until { wakes().count == 1 }, "a. one wake after the job exits")
        verdict(wakes().first?.contains("swift build") == true && wakes().first?.contains("Continue") == true,
                "a. the wake names the command")
        await settle(0.8)
        verdict(wakes().count == 1, "a. still exactly one wake")
        _ = await idle()

        // Exits inside the batch window are one wake.
        publish([job(9002, "xcodebuild test"), job(9003, "npm run build")])
        publish([])
        verdict(await until { wakes().count == 2 }, "a. two exits in one window wake once")
        await settle(0.8)
        verdict(wakes().count == 2 && wakes().last?.contains("xcodebuild test") == true
                && wakes().last?.contains("npm run build") == true, "a. the batch names both commands")
        _ = await idle()

        // A job a person stopped from the panel does not wake the agent.
        let stopped = job(9004, "dev server")
        publish([stopped])
        tracker.stop([stopped])
        await settle(0.1)
        publish([])
        await settle(0.8)
        verdict(wakes().count == 2, "a. a user-stopped job does not wake")
        _ = await idle()

        // (b) The CLI tracks this one (run_in_background): it wakes the agent
        // itself, so Array must not.
        runner.background = true
        publish([job(9005, "npm run dev", detached: false)])
        publish([])
        await settle(1.0)
        verdict(wakes().count == 2, "b. CLI-tracked background work is not double-woken")
        runner.background = false

        // (c) A reply that promises later action is never nudged: phrases match
        // quoted and descriptive text, and the nudge was visible to the person.
        runner.end(saying: "The build is going. I'll check again in 4 minutes.")
        guard supervisor.send("go", to: agent) else { throw Failure(description: "the promise turn did not start") }
        _ = await idle()
        await settle(1.2)
        verdict(supervisor.idleWaker.wakeCount == 2 && !runner.prompts.contains { $0.contains("nothing will wake you") },
                "c. a promise with nothing running earns no nudge")
        runner.end(saying: "A proposed label is \"waiting on 1 helper\".")
        guard supervisor.send("go again", to: agent) else { throw Failure(description: "the quoted-phrase turn did not start") }
        _ = await idle()
        await settle(1.2)
        verdict(!runner.prompts.contains { $0.contains("nothing will wake you") }, "c. quoted 'waiting on' earns no nudge")

        if !failures.isEmpty { throw Failure(description: "FAILED: " + failures.joined(separator: "; ")) }
    }
}

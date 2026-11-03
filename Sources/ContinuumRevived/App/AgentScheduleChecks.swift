import Foundation
import ContinuumRevivedCore

@MainActor
enum AgentScheduleChecks {
    static func nativeCronLifetime(originalPath: String) async throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-cron-lifetime-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        try AgentSteeringQAFakes.install(.claude, in: bin)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("ContinuumRevivedCoreChecks/Fixtures/claude-cron-lifecycle.jsonl")
        try FileManager.default.copyItem(at: fixture, to: bin.appendingPathComponent("cron.jsonl"))
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        setenv("PATH", bin.path + ":" + originalPath, 1)
        defer { setenv("PATH", originalPath, 1) }
        var sessions: [ClaudeAgentRunner] = []
        let supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root), makeRunner: { launch in
            let runner = AgentSupervisor.productionRunner(for: launch)
            if let claude = runner as? ClaudeAgentRunner { sessions.append(claude) }
            return runner
        }, idleRunnerTimeout: 0.1)
        defer { supervisor.stopAll() }
        let id = supervisor.spawn(role: nil, prompt: nil, cwd: work, harness: .claudeCode,
            model: "anthropic/claude-haiku-4-5-20251001", thinking: "low")
        try AgentPresenceChecks.expect(supervisor.send("CRON CREATE", to: id), "CronCreate send refused")
        try await AgentPresenceChecks.eventually("CronCreate did not finish") { supervisor.records[id]?.latestTerminalEvent != nil && !supervisor.isRunning(id) }
        try await Task.sleep(for: .milliseconds(500))
        try AgentPresenceChecks.expect(sessions.count == 1 && sessions[0].isSessionRunning,
            "cron-keeps-session: idle reaper killed a session with a live CronCreate job")
        let scheduledTask = try supervisor.companionTaskSnapshot()
        try AgentPresenceChecks.expect(scheduledTask.tasks.contains { !$0.membershipComplete },
            "native scheduled background work falsely advertised task completion")
        print("PASS schedules: cron-keeps-session; native background schedule keeps task completion quiet")
        let sequence = supervisor.records[id]?.latestTerminalEvent?.sequence
        try AgentPresenceChecks.expect(supervisor.send("CRON DELETE", to: id), "CronDelete send refused")
        try await AgentPresenceChecks.eventually("CronDelete did not finish") { supervisor.records[id]?.latestTerminalEvent?.sequence != sequence && !supervisor.isRunning(id) }
        _ = try supervisor.companionTaskSnapshot() // observe the now-ended background work while the session is pooled
        try await AgentPresenceChecks.eventually("cron-deleted-reaps: cancelled cron kept the process alive") { !sessions[0].isSessionRunning }
        try AgentPresenceChecks.expect(sessions.count == 1, "CronDelete unexpectedly started a different session")
        print("PASS schedules: cron-deleted-reaps")
        return "CronCreate keeps its production session alive; CronDelete permits idle reaping"
    }
    private final class Prompts: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ text: String) { lock.lock(); values.append(text); lock.unlock() }
        var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }
    private final class Runner: AgentRunning, @unchecked Sendable {
        let prompts: Prompts
        init(_ prompts: Prompts) { self.prompts = prompts }
        var commandCapabilities: AgentSessionCommandCapabilities { .oneShotProse }
        func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
            prompts.add(prompt.text)
            onEvent(.turnStarted(threadId: "schedule", turnId: "wake"))
            onEvent(.turnCompleted(threadId: "schedule", turnId: "wake", outcome: .completed, errorMessage: nil))
        }
        func stop() {}
        func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {}
        func observeRuntimeObservations(_ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void) {}
    }

    static func durableWakeups() async throws -> String {
        let fixture = try WorkspaceAPIChecks.makeFixture()
        defer { fixture.delegate.qaAgentSupervisor.stopAll(); fixture.runtime.closeAll(); fixture.tearDown() }
        let root = fixture.tempRoot.appendingPathComponent("schedule-support")
        let queue = AgentComposerDraftStore(applicationSupportDirectory: root)
        let prompts = Prompts()
        let supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root),
            makeRunner: { _ in Runner(prompts) }, submissionRecoveryStore: queue)
        defer { supervisor.stopAll() }
        let id = supervisor.spawn(role: nil, prompt: nil, cwd: fixture.pbRoot,
            harness: .claudeCode, model: "anthropic/claude-haiku-4-5-20251001", thinking: "low")
        _ = supervisor.setWorkspaceToolsEnabled(agentID: id, true)
        let api = WorkspaceAPIService(runtime: { fixture.runtime }, canvas: { fixture.canvas },
            focusBroker: { fixture.focusBroker }, supervisor: supervisor, registryStore: { nil },
            epoch: "schedule-check", approvalHandler: { _ in .deny })
        func call(_ payload: [String: Any]) -> WorkspaceAPIService.Reply {
            api.dispatch(agentId: id, requestId: UUID().uuidString, op: "agent.schedule", payload: payload)
        }
        func jobs(_ reply: WorkspaceAPIService.Reply) throws -> [[String: Any]] {
            guard case .result(let value) = reply,
                  let rows = WorkspaceAPIService.plain(value)["schedules"] as? [[String: Any]] else {
                throw AgentPresenceChecks.Failure(description: "schedule API failed: \(reply)")
            }
            return rows
        }
        let request: [String: Any] = ["op": "create", "idempotencyKey": "overnight", "prompt": "durable check-in", "intervalSeconds": 1200]
        let created = try jobs(call(request))
        let retried = try jobs(call(request))
        try AgentPresenceChecks.expect(created.count == 1 && retried.count == 1, "schedule retry duplicated its timer")
        guard let scheduleID = created[0]["id"] as? String else { throw AgentPresenceChecks.Failure(description: "schedule id missing") }
        if case .error(let error) = call(["op": "list", "agentId": UUID().uuidString]) {
            try AgentPresenceChecks.expect(error.code == .permissionDenied, "foreign schedule request was not denied")
        } else { throw AgentPresenceChecks.Failure(description: "foreign schedules allowed") }
        let due = Date().addingTimeInterval(1201)
        try await supervisor.qaTickWakeups(now: due)
        try await AgentPresenceChecks.eventually("durable wakeup never started a stopped session") { prompts.snapshot == ["durable check-in"] }
        try await AgentPresenceChecks.eventually("durable wakeup did not finish") { !supervisor.isRunning(id) }
        try await supervisor.qaTickWakeups(now: due)
        try AgentPresenceChecks.expect(prompts.snapshot.count == 1, "the same due occurrence ran twice")
        _ = try jobs(call(["op": "delete", "scheduleId": scheduleID]))
        try await supervisor.qaTickWakeups(now: due.addingTimeInterval(3600))
        try AgentPresenceChecks.expect(prompts.snapshot.count == 1, "deleted durable timer still fired")
        print("PASS schedules: durable API retry, self scope, stopped-session queue delivery and deletion")

        // A normal turn completes while the scheduled message is durably queued
        // but its outbox receipt is still pending. It must not drain that head.
        let racing = try jobs(call(["op": "create", "idempotencyKey": "cancel-race",
            "prompt": "must never run", "runAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))]))
        var barrierFinished = false
        supervisor.qaAfterScheduledQueueWrite = {
            _ = supervisor.send("handoff barrier", to: id)
            for _ in 0..<100 {
                if prompts.snapshot.last == "handoff barrier" && !supervisor.isRunning(id) { barrierFinished = true; break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            _ = call(["op": "delete", "scheduleId": racing[0]["id"]!])
        }
        try await supervisor.qaTickWakeups(now: Date().addingTimeInterval(3601))
        supervisor.qaAfterScheduledQueueWrite = nil
        try AgentPresenceChecks.expect(barrierFinished && prompts.snapshot == ["durable check-in", "handoff barrier"],
            "an unacknowledged or cancelled scheduled wakeup escaped the queue: barrier=\(barrierFinished), prompts=\(prompts.snapshot)")
        print("PASS schedules: turn completion cannot drain an unacknowledged wakeup; concurrent delete cancels it")

        // Simulate quitting after durable enqueue but before the outbox receipt.
        // A second enqueue with that id must be harmless, including after restart.
        let starts = ISO8601DateFormatter().string(from: Date().addingTimeInterval(7200))
        _ = try jobs(call(["op": "create", "idempotencyKey": "restart", "prompt": "restart check-in", "runAt": starts]))
        let saved = try AgentWakeupScheduleStore(applicationSupportDirectory: root)
        var pending = saved.entries
        let occurrence = UUID()
        pending[0].pendingDelivery = occurrence; pending[0].nextFireAt = nil
        try saved.replace(pending)
        try await queue.enqueueScheduledMessage(id: occurrence, text: "restart check-in", for: id)
        try await queue.enqueueScheduledMessage(id: occurrence, text: "restart check-in", for: id)
        supervisor.stopAll()
        let restoredQueue = AgentComposerDraftStore(applicationSupportDirectory: root)
        let restored = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root),
            makeRunner: { _ in Runner(prompts) }, submissionRecoveryStore: restoredQueue)
        defer { restored.stopAll() }
        _ = restored.restore()
        try await restored.qaTickWakeups(now: Date())
        try await AgentPresenceChecks.eventually("persisted scheduled queue did not resume after restart") { prompts.snapshot == ["durable check-in", "handoff barrier", "restart check-in"] }
        try await AgentPresenceChecks.eventually("restored scheduled turn did not finish") { !restored.isRunning(id) }
        try await restored.qaTickWakeups(now: Date().addingTimeInterval(8000))
        try AgentPresenceChecks.expect(prompts.snapshot.count == 3, "restart duplicated an acknowledged wakeup")
        print("PASS schedules: persisted outbox/queue restart delivers exactly one pending wakeup")
        return "Array-owned schedules persist and restart stopped sessions through the existing queue"
    }

}

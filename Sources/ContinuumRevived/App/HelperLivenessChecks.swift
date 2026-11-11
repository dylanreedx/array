import AppKit
import ContinuumRevivedCore

/// `.plans/116` part 20, liveness step — `--helper-liveness-check`.
///
/// Drives the production supervisor (the boot-mounted bench, a fake pi runner
/// for the lead and its helper) and the app's own `AgentProcessTracker`
/// scanning the real process table. The helper's "build" is a real process
/// tree started under a stand-in CLI tagged with the helper's id. The clock is
/// the watchdog's injected clock; the sweep is the watchdog's own sweep.
///
/// The same timeline runs twice, first with detection off (an infinite quiet
/// threshold, so every in-turn helper reads `working`) and then on. The lead's
/// queued stream must be byte-identical between the two.
@MainActor
enum HelperLivenessChecks {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        try WorkspaceAgentReportChecks.expect(condition(), message)
    }

    static func run() async throws {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "helper liveness check")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let bench = try WorkspaceAgentReportChecks.makeBench(label: "helper-liveness")
        defer { bench.tearDown() }
        let supervisor = bench.supervisor, lead = bench.f.agentId
        let tracker = bench.f.delegate.agentProcessTracker
        try expect(supervisor.processTracker === tracker, "the boot mount must hand the supervisor the app's tracker")
        bench.f.delegate.wireCanvasCallbacks(bench.f.canvas)
        try bench.f.delegate.reconciledManagedSessionSource.reconcile(
            registry: bench.f.delegate.registryStore!.loadOrEmpty(), reason: .continuumRestarted, now: Date())
        bench.f.api.approvalHandler = { _ in .allowForSession }
        var now = Date()
        supervisor.helperWatchdogNow = { now }
        let helper = try bench.delegate("HOLD-liveness")
        let finished = try bench.delegate("finished-control")
        try expect(supervisor.send("HOLD-lead", to: lead), "the lead did not start")
        let started = await waitUntil(timeout: 15, pollInterval: 0.02) {
            supervisor.isRunning(helper) && supervisor.isRunning(lead) && !supervisor.isRunning(finished)
                && supervisor.records[finished]?.latestTerminalEvent != nil
        }
        try expect(started, "the working helper and the finished control were not established")
        try await Task.sleep(nanoseconds: 200_000_000)
        // The finished control's completion is pushed to the lead; let it land
        // before either timeline so both start from the same queue.
        let settled = await waitUntil(timeout: 10, pollInterval: 0.02) {
            supervisor.queuedMessages(for: lead).contains { $0.text.contains("finished-control") }
        }
        try expect(settled, "the finished control's completion never reached the lead's queue")
        tracker.start()
        defer { tracker.stop() }

        let cwd = URL(fileURLWithPath: supervisor.records[lead]!.cwd)
        func prompts() -> String { (try? String(contentsOf: cwd.appendingPathComponent("prompts.log"), encoding: .utf8)) ?? "" }
        func state(_ id: AgentID) -> HelperLiveness? { supervisor.helperLiveness[id]?.state }
        func leadQueue() -> [String] { supervisor.queuedMessages(for: lead).map(\.text) }
        func progress() { supervisor.qaDeliver(.contentDelta(threadId: "liveness", turnId: "turn", streamKind: .assistant, delta: "progress"), to: helper) }
        var sweepNanos: [UInt64] = []
        func sweep() async throws {
            let t0 = DispatchTime.now().uptimeNanoseconds
            await supervisor.sweepHelperWatchdog()
            sweepNanos.append(DispatchTime.now().uptimeNanoseconds - t0)
            try expect(state(finished) == .finished, "a finished helper read \(String(describing: state(finished)))")
            try expect(state(lead) == nil, "the lead, no one's helper, got a liveness fact")
        }
        func inspected() throws -> String? {
            let reply = bench.f.api.dispatch(agentId: lead, requestId: UUID().uuidString, op: "agent.inspect",
                                             payload: ["agentId": helper.rawValue.uuidString])
            guard case let .result(object) = reply else { throw WorkspaceAgentReportChecks.Failure(description: "agent.inspect failed: \(reply)") }
            return object["liveness"]?.object?["state"]?.string
        }
        let me = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let tag = AgentProcessAttribution.ownerTag(for: helper)

        /// One timeline. Returns what the lead's queue gained.
        func episode(detection: Bool) async throws -> [String] {
            let label = detection ? "on" : "off"
            func want(_ on: HelperLiveness) -> HelperLiveness { detection ? on : .working }
            supervisor.helperLivenessQuietAfter = detection ? 120 : .infinity
            let queueBefore = leadQueue(), promptsBefore = prompts()
            let promptAt = supervisor.records[helper]?.latestPromptAt

            // 1. Events arriving: working.
            progress()
            await supervisor.sweepHelperWatchdog()
            now.addTimeInterval(60)
            progress()
            let lastEvent = now
            now.addTimeInterval(90)
            try await sweep()
            try expect(state(helper) == .working, "\(label): a helper with events arriving read \(String(describing: state(helper)))")

            // 2. Silent, with a live child process (a stand-in build).
            let directory = bench.f.tempRoot.appendingPathComponent("liveness-\(label)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let cli = try ProcessGroupChild.spawn(
                executable: me, arguments: [ProcessTrackingQAHelper.flag, "portless-agent", directory.path],
                environment: PiAgentRunner.childEnvironment(processOwner: tag),
                currentDirectory: nil, standardInput: .nullDevice)
            defer { cli.terminateGroup(graceSeconds: 0.2) }
            let listed = await waitUntil(timeout: 15, pollInterval: 0.02) { !tracker.jobs(for: helper).isEmpty }
            try expect(listed, "\(label): the tracker never listed the helper's build")
            now = lastEvent.addingTimeInterval(150)
            try await sweep()
            try expect(state(helper) == want(.waitingOnChild), "\(label): silent with a live build read \(String(describing: state(helper)))")
            now = lastEvent.addingTimeInterval(300)
            try await sweep()
            try expect(state(helper) == want(.waitingOnChild), "\(label): still building read \(String(describing: state(helper)))")

            // 3. The build ends. No event from the helper; the next sweep moves it.
            // The tool shell runs in a process group of its own, so end its
            // listed tree directly, then the stand-in CLI.
            for pid in tracker.jobs(for: helper).flatMap(\.pids) { kill(pid, SIGKILL) }
            cli.terminateGroup(graceSeconds: 0.2)
            let gone = await waitUntil(timeout: 10, pollInterval: 0.02) { tracker.jobs(for: helper).isEmpty }
            try expect(gone, "\(label): the tracker kept the ended build: \(tracker.jobs(for: helper).map(\.label))")
            now = lastEvent.addingTimeInterval(330)
            try await sweep()
            try expect(supervisor.isRunning(helper) && supervisor.queuedMessages(for: helper).isEmpty,
                       "\(label): classifying the helper stopped or messaged it")
            try expect(state(helper) == want(.stalled), "\(label): silent with nothing running read \(String(describing: state(helper)))")
            try expect(supervisor.helperLiveness[helper]?.lastProgressAt == lastEvent,
                       "\(label): the stall must be read from the helper's last event, not a new one")
            let seen = try inspected()
            try expect(seen == want(.stalled).rawValue, "\(label): agent.inspect reported liveness \(String(describing: seen))")
            try expect(leadQueue() == queueBefore, "\(label): a liveness change reached the lead's queue")

            // 4. The existing watchdog escalation, unchanged.
            now = lastEvent.addingTimeInterval(601)
            try await sweep()
            try expect(state(helper) == want(.stalled), "\(label): after the watchdog read \(String(describing: state(helper)))")

            // Nothing stopped, restarted or messaged the helper.
            try expect(supervisor.isRunning(helper) && supervisor.isRunning(lead), "\(label): a runner was stopped")
            try expect(supervisor.queuedMessages(for: helper).isEmpty, "\(label): the helper was messaged")
            try expect(prompts() == promptsBefore && supervisor.records[helper]?.latestPromptAt == promptAt,
                       "\(label): a prompt reached a runner (restart or message)")
            // The queue orders by priority, so take what is new, not a suffix.
            var gained = leadQueue()
            for text in queueBefore { if let i = gained.firstIndex(of: text) { gained.remove(at: i) } }

            // 5. A stalled helper that produces an event is working at once.
            progress()
            try expect(state(helper) == .working, "\(label): an event left the helper \(String(describing: state(helper)))")
            try await sweep()
            try expect(state(helper) == .working, "\(label): after the event's sweep read \(String(describing: state(helper)))")
            return gained
        }

        let off = try await episode(detection: false)
        let on = try await episode(detection: true)
        try expect(off.count == 1 && off[0].contains("has shown no progress"),
                   "the watchdog control must queue exactly its one alert: \(off); helper needs-you \(String(describing: supervisor.records[helper]?.helperWatchdogNeedsYou))")
        try expect(on == off, "the lead's queued stream differs with detection on:\noff \(off)\non  \(on)")

        // 6. Finished: release the scripted turns; a finished helper is never stalled.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline && (supervisor.isRunning(helper) || supervisor.isRunning(lead)) {
            try Data().write(to: cwd.appendingPathComponent("release.flag"))
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try expect(!supervisor.isRunning(helper), "the helper's scripted turn did not finish")
        try await sweep()
        now.addTimeInterval(3600)
        try await sweep()
        try expect(state(helper) == .finished, "a finished helper read \(String(describing: state(helper)))")
        let finalInspect = try inspected()
        try expect(finalInspect == HelperLiveness.finished.rawValue, "agent.inspect reported \(String(describing: finalInspect)) for a finished helper")

        // Cost, printed and not asserted.
        let iterations = 200_000
        var tally = 0
        let base = Date()
        let t0 = DispatchTime.now().uptimeNanoseconds
        for i in 0..<iterations {
            let state = HelperLiveness.classify(inTurn: i % 7 != 0, blocked: i % 11 == 0, lastProgressAt: base,
                                                liveChildren: i % 3, now: base.addingTimeInterval(Double(i % 300)), quietAfter: 120)
            tally &+= state == .stalled ? 1 : 0
        }
        let classifyNs = Double(DispatchTime.now().uptimeNanoseconds - t0) / Double(iterations)
        let sorted = sweepNanos.sorted()
        print(String(format: "helper-liveness timing: classify %.1f ns/call (%d calls, %d stalled); watchdog sweep with 2 helpers median %.1f µs, max %.1f µs over %d sweeps",
                     classifyNs, iterations, tally, Double(sorted[sorted.count / 2]) / 1000, Double(sorted.last ?? 0) / 1000, sorted.count))
    }
}

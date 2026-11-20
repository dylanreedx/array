import AppKit
import ContinuumRevivedCore

/// `--helper-usage-check`: what a helper costs its lead to wait on. Both
/// sections drive production — the watchdog sweep and the workspace API
/// dispatch — with the clock injected and no threshold overridden.
@MainActor
enum HelperUsageChecks {
    static func run() async throws {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "helper usage check")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let bench = try WorkspaceAgentReportChecks.makeBench(label: "helper-usage")
        defer { bench.tearDown() }
        let supervisor = bench.supervisor, lead = bench.f.agentId
        bench.f.delegate.wireCanvasCallbacks(bench.f.canvas)
        try bench.f.delegate.reconciledManagedSessionSource.reconcile(
            registry: bench.f.delegate.registryStore!.loadOrEmpty(), reason: .continuumRestarted, now: Date())
        bench.f.api.approvalHandler = { _ in .allowForSession }
        var now = Date()
        supervisor.helperWatchdogNow = { now }
        bench.f.api.pollNow = { now }
        let child = try bench.delegate("HOLD-usage")
        // A lead mid-turn queues alerts instead of waking at once, so they can be counted.
        try HelperGuardChecks.expect(supervisor.send("HOLD-parent", to: lead), "the lead did not start")
        let started = await waitUntil(timeout: 15, pollInterval: 0.02) { supervisor.isRunning(child) && supervisor.isRunning(lead) }
        try HelperGuardChecks.expect(started, "the helper and lead never started")
        try await Task.sleep(nanoseconds: 200_000_000)

        func alerts() -> [String] {
            supervisor.queuedMessages(for: lead).map(\.text).filter { $0.contains("Helper ") }
        }
        // 1. Twenty minutes of quiet, not ten, and a closing line that asks for nothing.
        await supervisor.sweepHelperWatchdog()
        now.addTimeInterval(11 * 60)
        await supervisor.sweepHelperWatchdog()
        try HelperGuardChecks.expect(alerts().isEmpty, "a 10-minute quiet raised an alert: \(alerts())")
        now.addTimeInterval(9 * 60 + 1)
        await supervisor.sweepHelperWatchdog()
        let first = alerts()
        try HelperGuardChecks.expect(first.count == 1 && first[0].contains("20 min")
            && first[0].contains("No action needed unless") && !first[0].contains("Check it, message it, or stop it"),
            "the 20-minute alert is missing or worded wrong: \(first)")

        // 2. A running command is not a stall: no alert until the 30-minute wait ceiling.
        try await HelperGuardChecks.hook(bench, child, tool: "Read")
        try HelperGuardChecks.expect(supervisor.qaDeliverFromBoundRunner(
            .itemStarted(threadId: "usage", itemId: "cmd-1", kind: .commandExecution, title: "swift build"), to: child),
            "no bound runner to start a command on")
        now.addTimeInterval(1201)
        await supervisor.sweepHelperWatchdog()
        try HelperGuardChecks.expect(alerts().count == 1, "a helper with a running command was alerted at 20 minutes: \(alerts())")
        now.addTimeInterval(700)
        await supervisor.sweepHelperWatchdog()
        try HelperGuardChecks.expect(alerts().count == 2 && alerts()[1].contains("still waiting"),
            "the wait ceiling did not alert once: \(alerts())")

        // 3. Polling: the second inspect of the same helper inside five minutes is refused.
        func inspect() -> WorkspaceAPIService.Reply {
            bench.f.api.dispatch(agentId: lead, requestId: "usage-inspect-\(UUID().uuidString)", op: "agent.inspect",
                                 payload: ["agentId": child.rawValue.uuidString])
        }
        guard case .result = inspect() else { throw WorkspaceAgentReportChecks.Failure(description: "the first inspect was refused") }
        now.addTimeInterval(60)
        guard case let .error(refused) = inspect(), refused.message.contains("arrive by themselves") else {
            throw WorkspaceAgentReportChecks.Failure(description: "a second inspect inside five minutes was not refused")
        }
        now.addTimeInterval(5 * 60)
        guard case .result = inspect() else { throw WorkspaceAgentReportChecks.Failure(description: "an inspect after five minutes was refused") }
        print("Helper usage checks passed: 20-minute stall alert with closing advice, running command suppressed until the ceiling, second inspect inside five minutes refused")
    }
}

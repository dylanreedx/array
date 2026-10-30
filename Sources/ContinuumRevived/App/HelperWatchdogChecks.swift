import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

@MainActor
enum HelperWatchdogChecks {
    static func run() async throws {
        let bench = try WorkspaceAgentReportChecks.makeBench(label: "helper-watchdog")
        defer { bench.tearDown() }
        let supervisor = bench.supervisor, parent = bench.f.agentId
        bench.f.delegate.wireCanvasCallbacks(bench.f.canvas)
        try bench.f.delegate.reconciledManagedSessionSource.reconcile(
            registry: bench.f.delegate.registryStore!.loadOrEmpty(), reason: .continuumRestarted, now: Date())
        var now = Date()
        supervisor.helperWatchdogNow = { now }
        let child = try bench.delegate("HOLD-watchdog")
        let idle = try bench.delegate("idle-control")
        try HelperGuardChecks.expect(supervisor.send("HOLD-parent", to: parent), "parent did not start")
        let started = await waitUntil(timeout: 15, pollInterval: 0.02) {
            supervisor.isRunning(child) && supervisor.isRunning(parent) && !supervisor.isRunning(idle)
                && supervisor.records[idle]?.latestTerminalEvent != nil
        }
        try HelperGuardChecks.expect(started, "working and idle controls not established")
        // Let the scripted runner's initial text arrive before advancing time.
        try await Task.sleep(nanoseconds: 200_000_000)
        let sidebar = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        let window = NSWindow(contentRect: sidebar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = sidebar
        bench.f.delegate.qaInstallWorkspaceSidebar(sidebar)
        bench.f.delegate.qaRefreshAgentSurfaces()
        sidebar.inboxForQA.layoutForQA()
        if sidebar.inboxForQA.collapsedParentsForQA.contains(parent.rawValue) {
            try HelperGuardChecks.expect(sidebar.inboxForQA.clickDisclosureForQA(id: parent.rawValue), "could not expand the helper group")
        }
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        func line() -> String? {
            sidebar.inboxForQA.layoutForQA()
            return sidebar.inboxForQA.onScreenCardForQA(id: child.rawValue)?.selfReportTextForQA?.string
        }
        func alerts() -> [AgentComposerQueuedMessage] {
            supervisor.queuedMessages(for: parent).filter { $0.text.contains("has shown no progress") }
        }
        await supervisor.sweepHelperWatchdog()
        now.addTimeInterval(599)
        await supervisor.sweepHelperWatchdog()
        try HelperGuardChecks.expect(alerts().isEmpty && line() == nil, "watchdog fired early")
        now.addTimeInterval(2)
        await supervisor.sweepHelperWatchdog()
        let drawn = await waitUntil(timeout: 5, pollInterval: 0.02) { line() == "Needs you: no progress for 10 min" }
        try HelperGuardChecks.expect(drawn, "supervisor did not push the needs-you sidebar line: \(String(describing: line())), stored \(String(describing: supervisor.records[child]?.helperWatchdogNeedsYou)), row \(String(describing: sidebar.inboxForQA.pushedRowForQA(id: child.rawValue)?.selfReportLine)), alerts \(alerts().count)")
        try HelperGuardChecks.expect(alerts().count == 1, "expected exactly one queued parent message, got \(alerts().count)")
        let text = AgentMessageEnvelope.unwrappedText(alerts()[0].text)
        try HelperGuardChecks.expect(text.split(whereSeparator: \.isWhitespace).count <= 40
            && text.contains("Check it, message it, or stop it."), "alert wording is wrong: \(text)")
        // Reuse the shipped needs-you style in both appearances.
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            sidebar.inboxForQA.layoutForQA()
            guard let cell = sidebar.inboxForQA.onScreenCardForQA(id: child.rawValue),
                  let actual = cell.selfReportTextForQA else {
                throw WorkspaceAgentReportChecks.Failure(description: "no painted watchdog line")
            }
            let expected = AgentInbox96CellView.selfReportText(.needsYou("no progress for 10 min"), in: cell)
            try HelperGuardChecks.expect(actual.isEqual(to: expected), "watchdog did not reuse amber needs-you rendering")
        }
        now.addTimeInterval(1200)
        await supervisor.sweepHelperWatchdog()
        try HelperGuardChecks.expect(alerts().count == 1, "same episode escalated twice")
        try await HelperGuardChecks.hook(bench, child, tool: "Read")
        let cleared = await waitUntil(timeout: 5, pollInterval: 0.02) { line() == nil }
        try HelperGuardChecks.expect(cleared, "hook progress did not clear sidebar")
        now.addTimeInterval(601)
        await supervisor.sweepHelperWatchdog()
        try HelperGuardChecks.expect(alerts().count == 2, "second episode did not escalate")
        supervisor.qaDeliver(.contentDelta(threadId: "watchdog", turnId: "turn", streamKind: .assistant, delta: "progress"), to: child)
        try HelperGuardChecks.expect(supervisor.records[child]?.helperWatchdogNeedsYou == nil, "transcript growth did not reset")
        now.addTimeInterval(500)
        _ = supervisor.declareStatus(.init(now: "Waiting", needsYou: "Approve access", declaredAt: Date()), for: child)
        now.addTimeInterval(599)
        await supervisor.sweepHelperWatchdog()
        try HelperGuardChecks.expect(alerts().count == 2, "status change failed to reset")
        now.addTimeInterval(2)
        await supervisor.sweepHelperWatchdog()
        try HelperGuardChecks.expect(alerts().count == 3, "a needs-you wait did not escalate")
        supervisor.qaDeliver(.requestOpened(threadId: "watchdog", requestId: "permission", kind: .commandExecutionApproval), to: child)
        await supervisor.sweepHelperWatchdog()
        now.addTimeInterval(601)
        await supervisor.sweepHelperWatchdog()
        try HelperGuardChecks.expect(alerts().count == 4, "a permission wait did not escalate")
        supervisor.qaDeliver(.requestResolved(threadId: "watchdog", requestId: "permission", decision: "accept"), to: child)
        try HelperGuardChecks.expect(supervisor.records[idle]?.helperWatchdogNeedsYou == nil
            && supervisor.records[parent]?.helperWatchdogNeedsYou == nil, "idle child or root agent escalated")
        try HelperGuardChecks.expect(supervisor.isRunning(child) && supervisor.isRunning(parent), "watchdog stopped a runner")
        // Release the scripted turns and witness the queue actually reaching
        // the parent's runner, with exactly one envelope per episode.
        let cwd = URL(fileURLWithPath: supervisor.records[parent]!.cwd)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline && (supervisor.isRunning(parent) || supervisor.isRunning(child) || !alerts().isEmpty) {
            try Data().write(to: cwd.appendingPathComponent("release.flag"))
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let prompts = try String(contentsOf: cwd.appendingPathComponent("prompts.log"), encoding: .utf8)
        try HelperGuardChecks.expect(prompts.components(separatedBy: "has shown no progress").count - 1 == 4,
                                     "the parent did not receive exactly four queued alerts")
        try HelperGuardChecks.expect(!supervisor.isRunning(child) && !supervisor.isRunning(parent), "scripted turns did not finish")
        now.addTimeInterval(1200)
        await supervisor.sweepHelperWatchdog()
        try HelperGuardChecks.expect(alerts().isEmpty && supervisor.records[child]?.helperWatchdogNeedsYou == nil,
                                     "completed helper escalated")

        // A parent missing after a relaunch: retain the spawned child's record
        // in a separate store, exactly as an orphaned record is restored.
        let orphanStore = AgentStore(applicationSupportDirectory: bench.f.tempRoot.appendingPathComponent("orphan-support"))
        try orphanStore.upsert(supervisor.records[child]!)
        let orphan = AgentSupervisor(store: orphanStore)
        defer { orphan.stopAll() }
        orphan.helperWatchdogNow = { now }
        _ = orphan.restore()
        try HelperGuardChecks.expect(orphan.records[parent] == nil, "orphan setup retained its parent")
        try? FileManager.default.removeItem(at: cwd.appendingPathComponent("release.flag"))
        try HelperGuardChecks.expect(orphan.send("HOLD-orphan", to: child), "orphan did not start")
        try await Task.sleep(nanoseconds: 300_000_000)
        await orphan.sweepHelperWatchdog()
        now.addTimeInterval(601)
        await orphan.sweepHelperWatchdog()
        try HelperGuardChecks.expect(orphan.records[child]?.helperWatchdogNeedsYou == "no progress for 10 min"
            && orphan.isRunning(child), "orphan should get only the sidebar status and keep running")
    }
}

import AppKit
import ContinuumRevivedCore

@MainActor
enum HelperCompletionChecks {
    static func runSetting() async throws {
        let bench = try WorkspaceAgentReportChecks.makeBench(label: "helper-wake-setting")
        defer { bench.tearDown() }
        let s = bench.supervisor, id = bench.f.agentId
        let before = s.records[id]!
        try HelperGuardChecks.expect(!s.wakesForHelperCompletion(id), "plain agent default must be off")
        let managedStore = AgentStore(applicationSupportDirectory: bench.f.tempRoot.appendingPathComponent("managed-setting-default"))
        var managed = before
        managed.harness = .codex
        managed.mode = .managed
        try managedStore.upsert(managed)
        let managedSupervisor = AgentSupervisor(store: managedStore)
        _ = managedSupervisor.restore()
        managedSupervisor.configureManagedMode(defaults: bench.settings)
        try HelperGuardChecks.expect(managedSupervisor.wakesForHelperCompletion(id), "Managed lead default must be on")
        try HelperGuardChecks.expect(s.setHelperCompletionWake(true, for: id) && s.wakesForHelperCompletion(id), "plain agent could not enable helper wakes")
        try HelperGuardChecks.expect(s.records[id] == before, "wake preference replaced or changed the agent record")
        let restored = AgentSupervisor(store: AgentStore(applicationSupportDirectory: bench.f.tempRoot.appendingPathComponent("setting-restore")))
        restored.configureManagedMode(defaults: bench.settings)
        try HelperGuardChecks.expect(restored.wakesForHelperCompletion(id), "preference did not survive supervisor recreation")
        bench.f.delegate.wireCanvasCallbacks(bench.f.canvas)
        try bench.f.delegate.reconciledManagedSessionSource.reconcile(
            registry: bench.f.delegate.registryStore!.loadOrEmpty(), reason: .continuumRestarted, now: Date())
        let sidebar = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
        bench.f.delegate.qaInstallWorkspaceSidebar(sidebar)
        bench.f.delegate.qaRefreshAgentSurfaces()
        s.configureHelperWakeMenu(sidebar.agentInbox)
        try HelperGuardChecks.expect(sidebar.agentInbox.openRowMenuForQA(clickedRowId: id.rawValue), "lead menu did not open")
        try HelperGuardChecks.expect(sidebar.agentInbox.rowMenuTitlesForQA.contains("Wake me when helpers finish"), "wake setting absent from lead menu")
        guard let list = sidebar.agentInbox.rowMenuRenderingForQA else { throw WorkspaceAgentReportChecks.Failure(description: "no choice menu to render") }
        list.frame = NSRect(x: 0, y: 0, width: 360, height: 900)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            list.appearance = NSAppearance(named: appearance)
            list.layoutSubtreeIfNeeded()
            guard let rep = list.bitmapImageRepForCachingDisplay(in: list.bounds) else { throw WorkspaceAgentReportChecks.Failure(description: "choice menu render unavailable") }
            list.cacheDisplay(in: list.bounds, to: rep)
            let out = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("array-scratch/lead-wakeups/setting-\(name).png")
            try rep.representation(using: .png, properties: [:])?.write(to: out)
        }
        try HelperGuardChecks.expect(sidebar.agentInbox.pickRowMenuItemForQA(id: "helper-completion-wake"), "wake preference action did not route")
        try HelperGuardChecks.expect(!s.wakesForHelperCompletion(id), "explicit off ignored")
        try HelperGuardChecks.expect(s.records[id]?.harness == before.harness && s.records[id]?.mode == before.mode, "menu action changed harness or mode")
    }

    static func runMessages() async throws {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "helper message check")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let bench = try WorkspaceAgentReportChecks.makeBench(label: "helper-message-result")
        defer { bench.tearDown() }
        let s = bench.supervisor, parent = bench.f.agentId
        let child = try bench.delegate("initial")
        let idle = await waitUntil(timeout: 15, pollInterval: 0.02) { !s.isRunning(child) && s.records[child]?.latestTerminalEvent != nil }
        try HelperGuardChecks.expect(idle, "initial helper did not settle")
        let config = try bench.configuration(for: parent)
        for (index, outcome) in [TurnOutcome.completed, .failed, .interrupted].enumerated() {
            let handle = "message-result-\(index)"
            let reply = bench.f.api.dispatch(agentId: parent, requestId: handle, op: "agent.message", payload: [
                "agentId": child.rawValue.uuidString, "text": "HOLD-message-\(index)", "idempotencyKey": handle])
            guard case let .result(result) = reply, result["delivery"]?.string == "delivered" else {
                throw WorkspaceAgentReportChecks.Failure(description: "message failed: \(reply)")
            }
            // The new handle must not inherit the preceding turn's result.
            let before = bench.f.api.dispatch(agentId: parent, requestId: UUID().uuidString, op: "operation.get", payload: ["operationId": handle])
            guard case let .result(beforeResult) = before else { throw WorkspaceAgentReportChecks.Failure(description: "operation refused") }
            try HelperGuardChecks.expect(beforeResult["childResult"] == nil, "new message inherited old result")
            s.qaDeliver(.turnCompleted(threadId: "message", turnId: handle, outcome: outcome, errorMessage: outcome == .failed ? "helper work error" : nil), to: child)
            // The handle settles independently of a later active turn.
            let waited = try await WorkspaceAgentReportChecks.call(config, "wait_agents", ["handles": [handle], "timeoutSeconds": 1])
            let entries = (waited.reply["result"] as? [String: Any])?["agents"] as? [[String: Any]]
            let expected = outcome == .completed ? "completed" : (outcome == .failed ? "failed" : "interrupted")
            try HelperGuardChecks.expect(entries?.first?["status"] as? String == expected, "message handle did not settle as \(expected): \(waited.reply)")
            try Data().write(to: URL(fileURLWithPath: s.records[child]!.cwd).appendingPathComponent("release.flag"))
            let done = await waitUntil(timeout: 15, pollInterval: 0.02) { !s.isRunning(child) }
            try HelperGuardChecks.expect(done, "helper did not release")
            let file = SpawnResultFile.read(parentCwd: s.records[parent]!.cwd, handle: handle)
            try HelperGuardChecks.expect(file?.status.rawValue == expected, "later terminal overwrote a message handle")
        }
    }
    static func run() async throws {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "helper completion check")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let bench = try WorkspaceAgentReportChecks.makeBench(label: "helper-completion")
        defer { bench.tearDown() }
        let script = WorkspaceAgentReportChecks.fakePi.replacingOccurrences(
            of: "if \"HOLD\" in json.dumps(text):",
            with: "if \"HOLD\" in json.dumps(text) and not any(line == \"Helper turn updates\" for line in str(text).splitlines()):")
        try script.write(to: bench.binDir.appendingPathComponent("pi"), atomically: true, encoding: .utf8)
        let s = bench.supervisor, parent = bench.f.agentId
        var now = Date()
        s.helperCompletionNow = { now }
        s.helperCompletionEnabled = { _ in true }
        func finish(_ child: AgentID, _ turn: String, _ outcome: TurnOutcome = .completed) {
            s.qaDeliver(.turnCompleted(threadId: "fixture", turnId: turn, outcome: outcome, errorMessage: outcome == .failed ? "work failed" : nil), to: child)
        }
        let child = try bench.delegate("HOLD-first")
        let started = await waitUntil(timeout: 15, pollInterval: 0.02) { s.isRunning(child) }
        try HelperGuardChecks.expect(started, "helper did not start")
        _ = s.fileReport(.init(summary: "WAKE-REPORT"), for: child)
        finish(child, "first")
        now.addTimeInterval(7)
        await s.flushHelperCompletions()
        try HelperGuardChecks.expect(!s.isRunning(parent), "completion fired before eight seconds")
        now.addTimeInterval(2)
        await s.flushHelperCompletions()
        let cwd = URL(fileURLWithPath: s.records[parent]!.cwd)
        func log() -> String { (try? String(contentsOf: cwd.appendingPathComponent("prompts.log"), encoding: .utf8)) ?? "" }
        func wakeCount() -> Int {
            log().split(separator: "\n").compactMap { line -> String? in
                try? JSONDecoder().decode(String.self, from: Data(line.utf8))
            }.filter { $0.components(separatedBy: "\n").contains("Helper turn updates") }.count
        }
        let received = await waitUntil(timeout: 15, pollInterval: 0.02) { log().contains("WAKE-REPORT") && !s.isRunning(parent) }
        try HelperGuardChecks.expect(received, "idle lead did not receive helper report")
        finish(child, "first")
        now.addTimeInterval(9)
        await s.flushHelperCompletions()
        try HelperGuardChecks.expect(log().components(separatedBy: "WAKE-REPORT").count - 1 == 1, "duplicate completion delivered")
        try HelperGuardChecks.expect(s.send("HOLD-parent", to: parent), "parent did not start")
        let children = try (0..<3).map { try bench.delegate("HOLD-group-\($0)") }
        for (i, c) in children.enumerated() { finish(c, "group-\(i)", i == 0 ? .failed : .interrupted) }
        now.addTimeInterval(9)
        await s.flushHelperCompletions()
        let updates = s.queuedMessages(for: parent).filter { $0.text.contains("Helper turn updates") }
        try HelperGuardChecks.expect(updates.count == 1 && children.allSatisfy { updates[0].text.contains($0.rawValue.uuidString) }, "busy lead did not queue one grouped update")
        await s.flushHelperCompletions()
        try HelperGuardChecks.expect(s.queuedMessages(for: parent).filter { $0.text.contains("Helper turn updates") }.count == 1, "queued update repeated")
        let end = Date().addingTimeInterval(20)
        while Date() < end && (s.isRunning(parent) || !s.queuedMessages(for: parent).isEmpty) {
            try Data().write(to: cwd.appendingPathComponent("release.flag"))
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try HelperGuardChecks.expect(wakeCount() == 2, "group did not deliver once after busy turn; queued=\(s.queuedMessages(for: parent).count), running=\(s.isRunning(parent)), log=\(log())")
        let stopped = try bench.delegate("HOLD-stop")
        s.stop(stopped)
        now.addTimeInterval(9)
        await s.flushHelperCompletions()
        let stopDelivered = await waitUntil(timeout: 15, pollInterval: 0.02) { wakeCount() == 3 && !s.isRunning(parent) }
        try HelperGuardChecks.expect(stopDelivered, "stopped helper did not wake lead")
        s.helperCompletionEnabled = { _ in false }
        finish(child, "off")
        now.addTimeInterval(9)
        await s.flushHelperCompletions()
        try HelperGuardChecks.expect(wakeCount() == 3, "disabled lead was woken")
    }
}

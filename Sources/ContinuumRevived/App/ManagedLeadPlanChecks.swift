import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// Production MCP binary -> mounted API -> store/supervisor -> attached tile.
/// Helpers run the production Claude runner against a disposable scripted CLI.
@MainActor
enum ManagedLeadPlanChecks {
    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw WorkspaceAgentReportChecks.Failure(description: "lead-plan: " + message) }
    }
    static func run() async throws {
        let b = try ManagedModeChecks.bench("lead-plan")
        defer { b.tearDown() }
        let script = ManagedModeChecks.fakeClaude
            .replacingOccurrences(of: "'is_error':False", with: "'is_error': 'FAIL-TURN' in json.dumps(o)")
            .replacingOccurrences(of: "'subtype':'success','is_error'", with: "'subtype': 'error_during_execution' if 'FAIL-TURN' in json.dumps(o) else 'success','is_error'")
        try script.write(to: b.binDir.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: b.binDir.appendingPathComponent("claude").path)
        let supervisor = b.supervisor, lead = b.f.agentId
        try b.f.delegate.reconciledManagedSessionSource.reconcile(
            registry: b.f.delegate.registryStore!.loadOrEmpty(), reason: .continuumRestarted, now: Date())
        try expect(supervisor.setMode(.managed, for: lead), "could not enable managed lead")
        try expect(supervisor.setProviderSettings(agentID: lead, harness: .claudeCode, model: ManagedModeChecks.model),
                   "could not select lead harness")
        // The API fixture uses a note as the lead's placement anchor. Replace
        // that fixture-only stand-in through the production spawn/wiring route.
        for entry in b.f.canvas.allWorkspaceTiles() where entry.zoneId == b.f.zoneB {
            b.f.canvas.removeTile(id: entry.id)
        }
        supervisor.detachView(agentID: lead)
        let spawner = try b.f.runtime.ensureSpawner(forProjectId: b.f.projectPb)
        let scope = CreationScope(projectId: b.f.projectPb, projectRoot: b.f.pbRoot.path,
                                  homeRelativePath: nil, source: .zone, zoneId: b.f.zoneB)
        guard case let .spawned(tileID) = spawner.spawnManagedAgentForExistingAgent(lead, supervisor: supervisor,
                at: CGPoint(x: 3360, y: 740), creationScope: scope) else {
            throw WorkspaceAgentReportChecks.Failure(description: "production lead spawn failed")
        }
        b.f.delegate.wireManagedAgentTile(tileID, agentID: lead)
        guard let tile = b.f.canvas.tileView(for: tileID) as? ManagedAgentTileNSView else {
            throw WorkspaceAgentReportChecks.Failure(description: "production spawn did not mount lead tile")
        }
        try expect(tile.qaLeadPlanView.isHidden, "unposted plan visible")
        let helper = try await ManagedModeChecks.delegate(b, mode: nil, label: "HOLD-login")
        let failed = try await ManagedModeChecks.delegate(b, mode: nil, label: "Compare error screen")
        try await ManagedModeChecks.settled(b, failed)
        try await AgentPresenceChecks.eventually("helper did not start") { supervisor.derivedStreamStatus(for: helper) == .working }
        _ = try ManagedModeChecks.argv(b, helper)
        _ = supervisor.rename(agentID: lead, to: "Ship the sign-in rework")
        _ = supervisor.rename(agentID: helper, to: "Maya")
        _ = supervisor.rename(agentID: failed, to: "Leo")
        let config = try b.configuration(for: lead)
        let helperConfig = try b.configuration(for: helper)
        let failedConfig = try b.configuration(for: failed)
        func call(_ c: WorkspaceMCPConfiguration, _ tool: String, _ args: [String: Any]) async throws {
            let reply = try await WorkspaceAgentReportChecks.call(c, tool, args)
            try expect(!reply.isError, "\(tool) refused: \(reply.reply)")
        }
        try await call(failedConfig, "array_report", ["summary": "Error screen needs a fix", "checks": [["what": "Error layout", "result": "fail"]]])
        var plan: [[String: Any]] = [
            ["title": "Build sign-in screens", "owner": "lead", "state": "done"],
            ["title": "Check login flow", "owner": supervisor.records[helper]!.humanDisplayName],
            ["title": "Compare error screen", "owner": failed.rawValue.uuidString],
            ["title": "Choose error copy", "owner": "you"],
            ["title": "Review and merge", "owner": "lead", "state": "waiting"]]
        try await call(config, "array_status", ["now": "Reviewing helper results", "plan": plan])
        let view = tile.qaLeadPlanView
        try expect(!view.isHidden && view.presentation?.collapsed == false, "posted plan did not render expanded")
        try expect(view.presentation?.steps.map(\.state) == [.done, .running, .failed, .needsYou, .waiting], "incorrect live step states: \(String(describing: view.presentation))")
        try expect(view.presentation?.steps[1].owner == "\(supervisor.records[helper]!.humanDisplayName) · Fixture", "helper name/model missing")
        try expect(supervisor.records[lead]?.declaredStatus?.plan?[1].owner == helper.rawValue.uuidString, "helper name did not resolve to stable ID")
        try expect(view.chevron.superview === view && view.chevron.image != nil, "disclosure must be an image view")
        let expandedImage = view.chevron.image
        try expect(view.accessibilityPerformPress() && view.presentation?.collapsed == true, "header did not collapse")
        try expect(view.presentation?.header == "Plan · 1 of 5 done · Needs you: Choose error copy", "collapsed urgency/order incorrect")
        try expect(view.chevron.image !== expandedImage, "chevron did not change with disclosure")
        try await call(config, "array_status", ["now": "Still reviewing"])
        try expect(view.presentation?.steps.count == 5, "ordinary status erased plan")

        // Bounds and forgery: every refusal leaves the full declaration intact.
        let before = supervisor.records[lead]?.declaredStatus
        let badPlans: [Any] = [[], Array(repeating: plan[0], count: 7),
            [["title": "", "owner": "lead"]], [["title": String(repeating: "x", count: 81), "owner": "you"]],
            [["title": "x", "owner": ""]], [["title": "x", "owner": String(repeating: "o", count: 161)]],
            [["title": "x", "owner": "lead", "state": "running"]],
            [["title": "x", "owner": helper.rawValue.uuidString, "state": "done"]],
            [["title": "x", "owner": "unknown helper"]], "not an array"]
        for bad in badPlans {
            let reply = try await WorkspaceAgentReportChecks.call(config, "array_status", ["now": "bad", "plan": bad])
            try expect(reply.isError && String(describing: reply.reply).contains("invalid_request"), "out-of-bounds plan accepted: \(bad)")
            try expect(supervisor.records[lead]?.declaredStatus == before, "refusal changed declaration")
        }
        // A helper token can write only its own declaration; even a managed
        // helper with a plan must never display the lead surface.
        try expect(supervisor.setMode(.managed, for: failed), "helper mode setup failed")
        try await call(failedConfig, "array_status", ["now": "Helper plan", "agentId": lead.rawValue.uuidString,
            "plan": [["title": "Own work", "owner": "lead"]]])
        try expect(supervisor.records[lead]?.declaredStatus == before, "helper rewrote lead plan")
        _ = try supervisor.popOut(failed)
        if let id = supervisor.records[failed]?.tileId,
           let helperTile = b.f.canvas.tileView(for: id) as? ManagedAgentTileNSView {
            try expect(helperTile.qaLeadPlanView.isHidden, "helper displays plan")
        } else { throw WorkspaceAgentReportChecks.Failure(description: "missing production helper tile") }
        try expect(supervisor.setMode(.free, for: lead) && view.isHidden, "free lead displays plan")
        try expect(supervisor.setMode(.managed, for: lead) && !view.isHidden, "managed plan did not return")

        // Render the actual mounted tile in each appearance, both disclosure states.
        tile.removeFromSuperview()
        tile.frame = NSRect(x: 0, y: 0, width: 640, height: 600)
        let window = NSWindow(contentRect: tile.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tile; window.orderFrontOffscreenForChecks()
        defer { tile.detach(); window.orderOut(nil) }
        tile.appendUserPrompt("Finish the sign-in rework. Have helpers check login and screenshots.")
        supervisor.qaDeliver(.contentDelta(threadId: "plan-lead", turnId: "plan-turn", streamKind: .assistant,
            delta: "The screens are ready. A helper is checking login; another found a mismatch in the error screen. I need your choice of copy before the final review."), to: lead)
        try await Task.sleep(for: .milliseconds(200))
        try render(tile, window: window)

        // One scripted helper: running -> needs you -> failed checks -> done.
        try await call(helperConfig, "array_status", ["now": "Waiting on decision", "needsYou": "Approve login"])
        try expect(view.presentation?.steps[1].state == .needsYou, "helper needs-you did not repaint lead")
        try expect(view.presentation?.header.contains("Needs you: Check login flow") == true, "first urgent helper missing from header")
        try await call(helperConfig, "array_status", ["now": "Testing login"])
        try expect(view.presentation?.steps[1].state == .running, "cleared needs-you did not return to running")
        try await call(helperConfig, "array_report", ["summary": "Login check failed", "checks": [["what": "Login", "result": "fail"]]])
        try Data().write(to: URL(fileURLWithPath: supervisor.records[helper]!.cwd).appendingPathComponent("managed-release"))
        try await ManagedModeChecks.settled(b, helper)
        try expect(view.presentation?.steps[1].state == .failed, "completed failed checks did not repaint failed")
        try await call(helperConfig, "array_report", ["summary": "Login now passes", "checks": [["what": "Login", "result": "pass"]]])
        try expect(view.presentation?.steps[1].state == .done, "successful helper did not repaint done")
        // A claimed pass cannot hide a failed command Array observed.
        for exitCode in [1, 0] {
            _ = try await ManagedModeChecks.hook(b, helper, ["hook_event_name": "PostToolUse", "tool_name": "Bash",
                "tool_input": ["command": "swift test"], "tool_response": ["exit_code": exitCode]])
            try await call(helperConfig, "array_report", ["summary": "Checks finished",
                "checks": [["what": "swift test", "result": "pass"]]])
            try expect(view.presentation?.steps[1].state == (exitCode == 0 ? .done : .failed),
                       "observed command failure lost behind helper's pass claim")
        }
        plan[3]["state"] = "done"
        try await call(config, "array_status", ["now": "Review", "plan": plan])
        try expect(view.presentation?.header.contains("Failed: Compare error screen") == true, "failed urgency lost to done/waiting")
        try await call(failedConfig, "array_report", ["summary": "Fixed", "checks": [["what": "Error layout", "result": "pass"]]])
        try expect(supervisor.send("HOLD-again", to: helper), "helper restart failed")
        try await AgentPresenceChecks.eventually("running urgency not updated") {
            view.presentation?.header.contains("Running: Check login flow") == true
        }
        // Watchdog state comes from the production sweep, not from a lead claim.
        var now = Date(); supervisor.helperWatchdogNow = { now }
        await supervisor.sweepHelperWatchdog()
        try await Task.sleep(for: .milliseconds(200))
        now.addTimeInterval(601)
        await supervisor.sweepHelperWatchdog()
        try expect(view.presentation?.steps[1].state == .needsYou, "watchdog did not repaint plan")
        _ = try await ManagedModeChecks.hook(b, helper, ["hook_event_name": "PreToolUse", "tool_name": "Read", "tool_input": [:]])
        try expect(view.presentation?.steps[1].state == .running, "hook progress did not clear watchdog plan state")
        try Data().write(to: URL(fileURLWithPath: supervisor.records[helper]!.cwd).appendingPathComponent("managed-release"))
        try await ManagedModeChecks.settled(b, helper)

        try expect(supervisor.send("FAIL-TURN", to: helper), "error turn did not start")
        try await AgentPresenceChecks.eventually("helper error did not repaint failed", timeout: 15) {
            !supervisor.isRunning(helper) && view.presentation?.steps[1].state == .failed
        }
        let waiting = supervisor.spawn(role: nil, prompt: nil, cwd: b.f.pbRoot, harness: .claudeCode,
            model: ManagedModeChecks.model, thinking: "high", projectId: b.f.projectPb,
            projectRoot: b.f.pbRoot, parentAgentID: lead, displayName: "Not started")
        plan.append(["title": String(repeating: "x", count: 80), "owner": waiting.rawValue.uuidString])
        try await call(config, "array_status", ["now": "Review", "plan": plan])
        try expect(view.presentation?.steps.count == 6 && view.presentation?.steps.last?.state == .waiting,
                   "six-step/80-character boundary or unstarted helper failed")

        // Real disk restore and a newly attached tile, not a Codable round trip.
        try expect(view.presentation?.collapsed == true, "render did not leave collapsed state")
        supervisor.stopAll()
        let restored = AgentSupervisor(store: AgentStore(smokeTest: false)); restored.restore()
        defer { restored.stopAll() }
        tile.detach(); tile.attach(agentID: lead, supervisor: restored)
        try expect(tile.qaLeadPlanView.presentation?.collapsed == true && restored.records[lead]?.declaredStatus?.plan == supervisor.records[lead]?.declaredStatus?.plan,
                   "plan/disclosure lost on relaunch")
        try expect(tile.qaLeadPlanView.accessibilityPerformPress() && tile.qaLeadPlanView.presentation?.collapsed == false, "restored header did not expand")
        let again = AgentSupervisor(store: AgentStore(smokeTest: false)); again.restore()
        defer { again.stopAll() }
        try expect(again.records[lead]?.leadPlanCollapsed == false, "expanded preference did not persist")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(again.records[lead]!)) as! [String: Any]
        legacy.removeValue(forKey: "leadPlanCollapsed")
        let old = try JSONDecoder().decode(AgentRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        try expect(!old.leadPlanCollapsed, "old record default is not expanded")
        try expect(AgentReport.wordCount(ManagedLeadHookState.brief) <= 140 && ManagedLeadHookState.brief.contains("array_status"), "brief lacks plan or exceeds 140 words")
        print("Managed lead plan passed: production MCP/store/tile, bounds, self-only, live helper states/watchdog, urgency, image disclosure, relaunch, free/helper suppression, light/dark renders")
    }

    static func render(_ tile: ManagedAgentTileNSView, window: NSWindow) throws {
        let output = ProcessInfo.processInfo.environment["CONTINUUM_LEAD_PLAN_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let theme = NSAppearance(named: appearance)!
            NSApp.appearance = theme; window.appearance = theme; tile.appearance = theme
            var images: [NSBitmapImageRep] = []
            for collapsed in [false, true] {
                if tile.qaLeadPlanView.presentation?.collapsed != collapsed { _ = tile.qaLeadPlanView.accessibilityPerformPress() }
                tile.wakeChrome(); tile.layoutSubtreeIfNeeded(); window.layoutIfNeeded()
                tile.qaCanvasTranscript?.flushPendingVisualUpdate()
                try expect(tile.qaLeadPlanView.frame.height > 0, "plan has no layout height")
                let plan = tile.qaLeadPlanView.convert(tile.qaLeadPlanView.bounds, to: tile)
                let composer = tile.qaPageZoomComposeBackdrop.convert(tile.qaPageZoomComposeBackdrop.bounds, to: tile)
                try expect(!plan.intersects(composer), "plan overlaps composer")
                var result: Result<NSBitmapImageRep, Error>!
                theme.performAsCurrentDrawingAppearance { result = Result { try UIProbe.bitmap(of: tile, id: "managed-lead-plan") } }
                images.append(try result.get())
            }
            if let output {
                let size = NSSize(width: 1280, height: 600)
                let image = NSImage(size: size)
                image.lockFocus()
                for (i, rep) in images.enumerated() {
                    let part = NSImage(size: rep.size); part.addRepresentation(rep)
                    part.draw(in: NSRect(x: i * 640, y: 0, width: 640, height: 600))
                }
                let bitmap = NSBitmapImageRep(focusedViewRect: NSRect(origin: .zero, size: size))!
                image.unlockFocus()
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("lead-plan-built-\(name).png"))
            }
        }
    }
}

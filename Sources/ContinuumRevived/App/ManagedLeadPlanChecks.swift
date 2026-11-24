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
        let tile = try mountLead(b)
        try expect(tile.qaLeadPlanView.isHidden, "unposted plan visible")
        // Live 2026-11-02, verbatim: the brief says "plan first", so a real lead
        // posts its plan BEFORE any helper exists. It must be kept, not refused.
        let early = try await WorkspaceAgentReportChecks.call(b.configuration(for: lead), "array_status", ["now": "Delegating two independent jobs in parallel",
            "plan": [["title": "Job A: greeting.txt + make test", "owner": "helper A"], ["title": "Job B: notes.txt + sleep 100", "owner": "helper B"],
                     ["title": "Collect reports", "owner": "lead"]]])
        try expect(!early.isError, "plan posted before delegating was refused: \(early.reply)")
        try expect(tile.qaLeadPlanView.presentation?.steps.map(\.owner) == ["helper A", "helper B", "Lead"]
            && tile.qaLeadPlanView.presentation?.steps.allSatisfy { $0.state == .waiting } == true,
            "early plan did not render its unstarted helper steps: \(String(describing: tile.qaLeadPlanView.presentation))")
        let helper = try await delegateHelper(b, label: "HOLD-login")
        let failed = try await delegateHelper(b, label: "Compare error screen")
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
        try expect(supervisor.setLeadPlanCollapsed(true, for: lead) && view.presentation?.collapsed == true, "plan did not collapse")
        try expect(view.presentation?.header == "Plan · 1 of 5 done · Needs you: Choose error copy", "collapsed urgency/order incorrect")
        try await call(config, "array_status", ["now": "Still reviewing"])
        try expect(view.presentation?.steps.count == 5, "ordinary status erased plan")

        // ---- plan-drawer: roster (B), plan age (A), decision chips (C) ----
        // Everything below goes through the production MCP -> supervisor -> tile path;
        // the offscreen stills are of the same mounted drawer.
        let stillsDir = ProcessInfo.processInfo.environment["CONTINUUM_PLAN_DRAWER_DIR"].map { URL(fileURLWithPath: $0) }
        func still(_ name: String) throws {
            guard let stillsDir else { return }
            try FileManager.default.createDirectory(at: stillsDir, withIntermediateDirectories: true)
            let previous = NSApp.appearance
            defer { NSApp.appearance = previous; tile.appearance = nil }
            for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let theme = NSAppearance(named: appearance)!
                NSApp.appearance = theme; tile.appearance = theme
                tile.window?.appearance = theme
                tile.layoutSubtreeIfNeeded(); view.layoutSubtreeIfNeeded()
                var result: Result<NSBitmapImageRep, Error>!
                theme.performAsCurrentDrawingAppearance { result = Result { try UIProbe.bitmap(of: view, id: "plan-drawer-\(name)") } }
                try result.get().representation(using: .png, properties: [:])!
                    .write(to: stillsDir.appendingPathComponent("\(name)-\(label).png"))
            }
        }
        _ = supervisor.setLeadPlanCollapsed(false, for: lead)
        try expect(view.presentation?.collapsed == false, "plan did not expand for roster checks")
        try expect(view.presentation?.steps.contains { $0.isSection } == false,
                   "a plan that names every helper must not repeat them as a roster")
        try still("1-plan-up-to-date")

        // B. The plan names nobody: helpers appear from the delegations, grouped, with live state.
        try await call(config, "array_status", ["now": "Replanned", "plan": [
            ["title": "Merge the sign-in rework", "owner": "lead"], ["title": "Choose error copy", "owner": "you"]]])
        func sections() -> [String] { view.presentation?.steps.filter(\.isSection).map(\.title) ?? [] }
        try expect(sections() == ["Needs you", "Working", "Plan"], "roster groups wrong: \(sections())")
        try expect(view.presentation?.title == "Helpers · 1 working · 1 need you", "roster header wrong: \(String(describing: view.presentation?.title))")
        let rosterRows = view.presentation?.steps.filter { $0.ownerAgent != nil } ?? []
        try expect(rosterRows.first { $0.ownerAgent == failed }?.state == .failed
                   && rosterRows.first { $0.ownerAgent == helper }?.state == .running, "roster rows did not carry the helpers' real state")
        // A helper's real status change moves its row: a new helper appears, then settles to Done.
        let quick = try await delegateHelper(b, label: "Quick check")
        try await AgentPresenceChecks.eventually("new helper did not reach the roster") {
            view.presentation?.steps.contains { $0.ownerAgent == quick } == true
        }
        try await ManagedModeChecks.settled(b, quick)
        // Done needs the helper's report, not just its turn ending.
        try await call(b.configuration(for: quick), "array_report", ["summary": "Quick check passed"])
        try await AgentPresenceChecks.eventually("settled helper did not move to Done") {
            view.presentation?.steps.first { $0.ownerAgent == quick }?.state == .done
                && view.presentation?.steps.contains { $0.isSection && $0.title == "Done" } == true
        }
        try still("2-roster-live")

        // B. Revealing a helper from its row is `--lead-plan-popover-check`'s;
        // here, the app can reveal that helper's tile.
        try expect(b.f.delegate.revealAgentFromInbox(helper.rawValue), "the app could not reveal that helper's tile")

        // A. A plan nobody has touched for three days says so, and an ordinary status does not reset it.
        let threeDaysAgo = Date().addingTimeInterval(-3 * 86400)
        try expect(supervisor.declareStatus(AgentDeclaredStatus(now: "Old news", plan: [
            AgentPlanStep(title: "Dylan picks the option", owner: "you"), AgentPlanStep(title: "Ship", owner: "lead")],
            declaredAt: threeDaysAgo, planDeclaredAt: threeDaysAgo), for: lead), "could not write the old plan")
        try await call(config, "array_status", ["now": "Busy with helpers"])
        let aged = view.presentation?.steps ?? []
        try expect(aged.contains { $0.isSection && $0.stale && $0.title == "Plan · written 3d ago" }, "stale plan did not show its age: \(aged.map(\.title))")
        try expect(aged.first { $0.title == "Dylan picks the option" }?.note == "asked 3d ago"
                   && aged.first { $0.title == "Ship" }?.stale == true, "stale rows not marked")
        try expect(supervisor.records[lead]?.declaredStatus?.planDeclaredAt.map { abs($0.timeIntervalSince(threeDaysAgo)) < 1 } == true,
                   "an ordinary status reset the plan's age")
        try still("3-plan-stale")
        try await call(config, "array_status", ["now": "Replanned again", "plan": [["title": "Fresh step", "owner": "lead"]]])
        try expect(view.presentation?.steps.contains { $0.stale } == false, "a rewritten plan stayed stale")

        // C. A decision with options: chips in the composer's chip style; a chip answers into the composer.
        try await call(config, "array_status", ["now": "Waiting on you", "needsYou": "Which error copy ships?",
                                                "options": ["Short and blunt", "Long and kind"]])
        try expect(view.presentation?.decision == "Which error copy ships?" && view.presentation?.options == ["Short and blunt", "Long and kind"],
                   "decision did not reach the drawer")
        view.window?.orderFrontOffscreenForChecks()
        view.open()
        try expect(view.isOpen && view.list?.rail.qaOptions == ["Short and blunt", "Long and kind"] && view.list?.rail.isHidden == false, "chips not shown")
        try still("4-decision-chips")
        try expect(view.list?.rail.qaPressChip(titled: "Long and kind") == true, "chip could not be pressed")
        try expect(tile.qaComposerDraftText == "Long and kind", "chip did not answer into the composer: \(tile.qaComposerDraftText)")
        try expect(!view.isOpen, "answering did not close the plan")
        for bad: [String: Any] in [["now": "x", "options": ["a", "b"]], ["now": "x", "needsYou": "q", "options": ["only one"]],
                                   ["now": "x", "needsYou": "q", "options": ["a", "a"]], ["now": "x", "needsYou": "q", "options": ["a", String(repeating: "z", count: 41)]]] {
            let reply = try await WorkspaceAgentReportChecks.call(config, "array_status", bad)
            try expect(reply.isError, "bad options accepted: \(bad)")
        }
        try await call(config, "array_status", ["now": "Waiting on you", "needsYou": "Which error copy ships?"])
        try expect(view.presentation?.options.isEmpty == true && view.glance?.options.isEmpty == true, "options outlived the status that offered them")
        try await call(config, "array_status", ["now": "Resolved"])
        try expect(view.presentation?.decision == nil, "decision stayed after needsYou cleared")
        // Put the drawer back as the rest of this check found it.
        try await call(config, "array_status", ["now": "Reviewing helper results", "plan": plan])

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
        // A helper token can write only its own declaration. Settings keeps
        // helpers Free, and their own plans never display the lead surface.
        try expect(supervisor.records[failed]?.mode == .free, "helper must remain Free")
        try await call(failedConfig, "array_status", ["now": "Helper plan", "agentId": lead.rawValue.uuidString,
            "plan": [["title": "Own work", "owner": "lead"]]])
        try expect(supervisor.records[lead]?.declaredStatus == before, "helper rewrote lead plan")
        _ = try supervisor.popOut(failed)
        if let id = supervisor.records[failed]?.tileId,
           let helperTile = b.f.canvas.tileView(for: id) as? ManagedAgentTileNSView {
            try expect(helperTile.qaLeadPlanView.isHidden, "helper displays plan")
        } else { throw WorkspaceAgentReportChecks.Failure(description: "missing production helper tile") }
        ManagedSettingChecks.write(AgentManagedModeConfig.enabledKey, false, b)
        try expect(supervisor.records[lead]?.mode == .free && view.isHidden, "free lead displays plan")
        ManagedSettingChecks.write(AgentManagedModeConfig.enabledKey, true, b)
        try expect(supervisor.records[lead]?.mode == .managed && !view.isHidden, "managed plan did not return")

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
        // Urgency is what the status line shows: the step's phase and the
        // "N need(s) you" pill, which survives every width the row can give.
        func linePhase(_ title: String) -> PlanGlance.Phase? { view.glance?.steps.first { $0.title == title }?.phase }
        func lineNeedsYou(_ n: Int) -> Bool { view.glance?.needsYou == n && view.sentence.contains("\(n) need\(n == 1 ? "s" : "") you") }
        let attentionBefore = view.glance?.needsYou ?? 0
        try await call(helperConfig, "array_status", ["now": "Waiting on decision", "needsYou": "Approve login"])
        try expect(view.presentation?.steps.first { $0.title == "Check login flow" }?.state == .needsYou, "helper needs-you did not repaint lead")
        try expect(linePhase("Check login flow") == .needsYou && lineNeedsYou(attentionBefore + 1),
                   "urgent helper missing from the status line: \(view.sentence) \(String(describing: linePhase("Check login flow")))")
        try await call(helperConfig, "array_status", ["now": "Testing login"])
        try expect(view.presentation?.steps.first { $0.title == "Check login flow" }?.state == .running, "cleared needs-you did not return to running")
        try await call(helperConfig, "array_report", ["summary": "Login check failed", "checks": [["what": "Login", "result": "fail"]]])
        try Data().write(to: URL(fileURLWithPath: supervisor.records[helper]!.cwd).appendingPathComponent("managed-release"))
        try await ManagedModeChecks.settled(b, helper)
        try expect(view.presentation?.steps.first { $0.title == "Check login flow" }?.state == .failed, "completed failed checks did not repaint failed")
        try await call(helperConfig, "array_report", ["summary": "Login now passes", "checks": [["what": "Login", "result": "pass"]]])
        try expect(view.presentation?.steps.first { $0.title == "Check login flow" }?.state == .done, "successful helper did not repaint done")
        // A claimed pass cannot hide a failed command Array observed.
        for exitCode in [1, 0] {
            _ = try await ManagedModeChecks.hook(b, helper, ["hook_event_name": "PostToolUse", "tool_name": "Bash",
                "tool_input": ["command": "swift test"], "tool_response": ["exit_code": exitCode]])
            try await call(helperConfig, "array_report", ["summary": "Checks finished",
                "checks": [["what": "swift test", "result": "pass"]]])
            try expect(view.presentation?.steps.first { $0.title == "Check login flow" }?.state == (exitCode == 0 ? .done : .failed),
                       "observed command failure lost behind helper's pass claim")
        }
        plan[3]["state"] = "done"
        try await call(config, "array_status", ["now": "Review", "plan": plan])
        // Leo's failure stays Failed when another step goes done. Whether it
        // still asks for Dylan depends on whether Managed mode's wake turn on
        // the lead has ended yet (22ff76080; the rule itself is
        // --lead-plan-model-check's), so the line must agree with the model
        // either way: attention exactly while the failure is unhandled.
        let leo = view.presentation?.steps.first { $0.title == "Compare error screen" }
        try expect(leo?.state == .failed && linePhase("Compare error screen").map(PlanGlance.isAttention) == (leo?.past == false),
                   "failed step lost or line disagrees with the model: \(view.sentence) \(String(describing: leo)) line=\(String(describing: linePhase("Compare error screen")))")
        try await call(failedConfig, "array_report", ["summary": "Fixed", "checks": [["what": "Error layout", "result": "pass"]]])
        try expect(supervisor.send("HOLD-again", to: helper), "helper restart failed")
        try await AgentPresenceChecks.eventually("running urgency not updated") {
            linePhase("Check login flow") == .working
        }
        // Watchdog state comes from the production sweep, not from a lead claim.
        var now = Date(); supervisor.helperWatchdogNow = { now }
        await supervisor.sweepHelperWatchdog()
        try await Task.sleep(for: .milliseconds(200))
        // Past every production alert threshold (20/20/30 min since 7d7f83837).
        now.addTimeInterval(max(supervisor.helperWatchdogThreshold, supervisor.helperStallAlertAfter, supervisor.helperWaitCeiling) + 1)
        await supervisor.sweepHelperWatchdog()
        try expect(view.presentation?.steps.first { $0.title == "Check login flow" }?.state == .needsYou, "watchdog did not repaint plan")
        _ = try await ManagedModeChecks.hook(b, helper, ["hook_event_name": "PreToolUse", "tool_name": "Read", "tool_input": [:]])
        try expect(view.presentation?.steps.first { $0.title == "Check login flow" }?.state == .running, "hook progress did not clear watchdog plan state")
        try Data().write(to: URL(fileURLWithPath: supervisor.records[helper]!.cwd).appendingPathComponent("managed-release"))
        try await ManagedModeChecks.settled(b, helper)

        try expect(supervisor.send("FAIL-TURN", to: helper), "error turn did not start")
        try await AgentPresenceChecks.eventually("helper error did not repaint failed", timeout: 15) {
            !supervisor.isRunning(helper) && view.presentation?.steps.first { $0.title == "Check login flow" }?.state == .failed
        }
        let waiting = supervisor.spawn(role: nil, prompt: nil, cwd: b.f.pbRoot, harness: .claudeCode,
            model: ManagedModeChecks.model, thinking: "high", projectId: b.f.projectPb,
            projectRoot: b.f.pbRoot, parentAgentID: lead, displayName: "Not started")
        plan.append(["title": String(repeating: "x", count: 80), "owner": waiting.rawValue.uuidString])
        try await call(config, "array_status", ["now": "Review", "plan": plan])
        let steps6 = view.presentation?.steps ?? []
        let planRows = steps6.reversed().prefix(while: { !$0.isSection })
        try expect(planRows.count == 6 && steps6.last?.state == .waiting,
                   "six-step/80-character boundary or unstarted helper failed")

        // Real disk restore and a newly attached tile, not a Codable round trip.
        _ = supervisor.setLeadPlanCollapsed(true, for: lead)
        supervisor.stopAll()
        let restored = AgentSupervisor(store: AgentStore(smokeTest: false))
        restored.configureManagedMode(defaults: b.settings); restored.restore()
        defer { restored.stopAll() }
        tile.detach(); tile.attach(agentID: lead, supervisor: restored)
        try expect(tile.qaLeadPlanView.presentation?.collapsed == true && restored.records[lead]?.declaredStatus?.plan == supervisor.records[lead]?.declaredStatus?.plan,
                   "plan/disclosure lost on relaunch")
        _ = restored.setLeadPlanCollapsed(false, for: lead)
        let again = AgentSupervisor(store: AgentStore(smokeTest: false))
        again.configureManagedMode(defaults: b.settings); again.restore()
        defer { again.stopAll() }
        try expect(again.records[lead]?.leadPlanCollapsed == false, "expanded preference did not persist")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(again.records[lead]!)) as! [String: Any]
        legacy.removeValue(forKey: "leadPlanCollapsed")
        let old = try JSONDecoder().decode(AgentRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        try expect(!old.leadPlanCollapsed, "old record default is not expanded")
        try expect(AgentReport.wordCount(ManagedLeadHookState.brief) <= 230 && ManagedLeadHookState.brief.contains("array_status"), "brief lacks plan or exceeds 230 words")
        print("Managed lead plan passed: production MCP/store/tile, bounds, self-only, live helper states/watchdog, urgency, relaunch, free/helper suppression, light/dark renders")
    }

    /// `--lead-plan-steady-check`. Live 2026-11-22 on 0.7.59: the drawer above a
    /// lead's composer "bugs and tweaks out" while helpers stream. A burst of
    /// helper events goes through the production `deliver` path into the mounted
    /// tile, and every change the drawer takes is recorded. While no helper's
    /// state changes, the drawer must not move: each column holds one kind of
    /// content, rows keep their order and section, the height holds, and the
    /// drawer repaints at a bounded cadence, not once per event.
    static func runSteady() async throws {
        let b = try ManagedModeChecks.bench("lead-plan-steady")
        defer { b.tearDown() }
        let supervisor = b.supervisor, lead = b.f.agentId
        let tile = try mountLead(b)
        let view = tile.qaLeadPlanView
        // Rows as drawn: section label, then title | owner | state per row.
        func rows(_ p: LeadPlanPresentation?) -> [String] {
            (p?.steps ?? []).map { $0.isSection ? "[\($0.title)]" : "\($0.title) | \($0.owner) | \($0.state.rawValue)\($0.note.map { " · " + $0 } ?? "")" }
        }
        var trace: [(rows: [String], height: CGFloat)] = []
        var heightChanges = 0
        view.qaOnUpdate = { p in
            let height = view.intrinsicContentSize.height
            if let last = trace.last, last.height != height { heightChanges += 1 }
            trace.append((rows(p), height))
        }
        defer { view.qaOnUpdate = nil }
        var notifications = 0
        let counter = supervisor.addLeadPlanObserver(for: lead) { notifications += 1 }
        defer { supervisor.removeLeadPlanObserver(counter) }
        func dump() -> String { trace.enumerated().map { "push \($0.offset) h=\(Int($0.element.height)): " + $0.element.rows.joined(separator: " / ") }.joined(separator: "\n") }

        // Four helpers of this lead, as array_delegate names them: for their task.
        let names = ["Compile Dylan's recent work history", "Audit the sidebar rows", "Check the login flow", "Fix the drawer jitter"]
        let start = Date()
        var helpers: [AgentID] = []
        for (i, name) in names.enumerated() {
            let id = supervisor.spawn(role: nil, prompt: nil, cwd: b.f.pbRoot, harness: .claudeCode,
                model: ManagedModeChecks.model, thinking: "high", projectId: b.f.projectPb,
                projectRoot: b.f.pbRoot, parentAgentID: lead, displayName: name)
            helpers.append(id)
            let thread = AgentSupervisor.threadId(for: id)
            supervisor.qaDeliver(.sessionStateChanged(.running), to: id, now: start.addingTimeInterval(Double(i)))
            supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: "t1"), to: id, now: start.addingTimeInterval(Double(i)))
        }
        // One helper has already said what it is doing; the others have not.
        try expect(supervisor.declareStatus(AgentDeclaredStatus(now: "Reading git log for the last week", declaredAt: Date()), for: helpers[0]),
                   "helper status refused")
        try await AgentPresenceChecks.eventually("the four helpers did not reach the drawer") {
            view.presentation?.steps.filter { $0.ownerAgent != nil && $0.state == .running }.count == 4
        }
        try await Task.sleep(for: .milliseconds(400))
        // The plan stays open through everything below: a stream must not close it.
        view.window?.orderFrontOffscreenForChecks()
        view.open()
        try expect(view.isOpen, "the plan did not open")
        // The popover closes itself when its window loses key or the app goes
        // inactive, which any other app or check running alongside can cause.
        // That is focus, not the stream: reopen and carry on. Any other close
        // (a repaint dropping the plan, its anchor moving) is the failure.
        func streamClosedPlan() -> String? {
            guard !view.isOpen else { return nil }
            let reason = view.popover.qaLastSelfDismissal
            if reason == "resignKey" || reason == "resignActive" {
                view.window?.orderFrontOffscreenForChecks(); view.open()
                return view.isOpen ? nil : "could not reopen after \(reason!)"
            }
            return reason ?? "closed by the plan itself"
        }
        let settled = rows(view.presentation)
        let settledHeight = view.intrinsicContentSize.height
        let order = view.presentation?.steps.compactMap(\.ownerAgent) ?? []
        trace.removeAll(); heightChanges = 0; notifications = 0

        // The burst: what four streaming helpers deliver in about a second —
        // tokens, tool items and usage, round robin, each event a fresh activity
        // stamp. Mid-burst one helper posts its first status line and another's
        // runner restarts (session starting -> running) inside the same turn.
        // No helper's state changes: all four stay running throughout.
        let burstStart = Date()
        for i in 0..<120 {
            let id = helpers[i % 4], thread = AgentSupervisor.threadId(for: id)
            let at = burstStart.addingTimeInterval(Double(i) * 0.01)
            switch i % 6 {
            case 0: supervisor.qaDeliver(.itemStarted(threadId: thread, itemId: "i\(i)", kind: .commandExecution, title: "Bash"), to: id, now: at)
            case 3: supervisor.qaDeliver(.itemCompleted(threadId: thread, itemId: "i\(i - 3)", kind: .commandExecution, status: .completed), to: id, now: at)
            default: supervisor.qaDeliver(.contentDelta(threadId: thread, turnId: "t1", streamKind: .assistant, delta: "token \(i) "), to: id, now: at)
            }
            if i == 40 { _ = supervisor.declareStatus(AgentDeclaredStatus(now: "Diffing sidebar row heights", declaredAt: Date()), for: helpers[1]) }
            if i == 60 { supervisor.qaDeliver(.sessionStateChanged(.starting), to: helpers[2], now: at) }
            if i == 62 { supervisor.qaDeliver(.sessionStateChanged(.running), to: helpers[2], now: at) }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(400))
        let burstSeconds = Date().timeIntervalSince(burstStart)

        var failures: [String] = []
        // 1. One kind per column. Title: the helper's name; owner: its model.
        for (n, push) in trace.enumerated() {
            for row in push.rows where !row.hasPrefix("[") {
                let cells = row.components(separatedBy: " | ")
                if cells.count < 3 || !names.contains(cells[0]) || cells[1].contains(" · ") || cells[1] != "Fixture" {
                    failures.append("push \(n): a column changed kind: \(row)"); break
                }
            }
        }
        // 2. Order and section stable while no state changed; drawer returns to the same picture.
        for (n, push) in trace.enumerated() where push.rows.filter({ $0.hasPrefix("[") }) != settled.filter({ $0.hasPrefix("[") })
            || push.rows.map({ $0.components(separatedBy: " | ")[0] }) != settled.map({ $0.components(separatedBy: " | ")[0] }) {
            failures.append("push \(n): rows moved or changed section"); break
        }
        if rows(view.presentation) != settled { failures.append("after the burst the drawer differs from before it") }
        if view.presentation?.steps.compactMap(\.ownerAgent) != order { failures.append("row order changed") }
        // 3. Height holds; repaints bounded by a steady cadence, not per event.
        if heightChanges > 0 || view.intrinsicContentSize.height != settledHeight { failures.append("height changed \(heightChanges)x during the burst") }
        if let closed = streamClosedPlan() { failures.append("the burst closed the open plan (\(closed))") }
        let cadenceBound = Int((burstSeconds / AgentSupervisor.leadPlanActivityCadence).rounded(.up)) + 3
        if trace.count > cadenceBound { failures.append("drawer changed \(trace.count)x for 120 events (bound \(cadenceBound))") }
        if notifications > cadenceBound { failures.append("drawer recomputed \(notifications)x for 120 events (bound \(cadenceBound))") }
        guard failures.isEmpty else {
            throw WorkspaceAgentReportChecks.Failure(description: "lead-plan-steady: " + failures.joined(separator: "; ")
                + "\nsettled: " + settled.joined(separator: " / ") + "\n" + dump())
        }
        print("lead-plan-steady burst: 120 events over \(String(format: "%.2f", burstSeconds))s -> \(trace.count) drawer changes, \(notifications) recomputes, \(heightChanges) height changes")

        // 4. A real change still lands, live: one helper finishing two minutes
        // ago moves to Done. The height grows once (a new section), the other
        // rows keep their order, and the owner column does not shift sideways.
        func ownerCell(_ id: AgentID) -> NSRect {
            guard let list = view.list, let i = list.glance.steps.firstIndex(where: { list.glance.helperID(of: $0) == id }) else { return .zero }
            list.layoutSubtreeIfNeeded()
            return NSRect(x: list.ownerColumnRight, y: list.rowRect(i).minY, width: list.bounds.width, height: list.rowRect(i).height)
        }
        let ownerBefore = ownerCell(helpers[0])
        trace.removeAll(); heightChanges = 0
        let done = helpers[3], doneThread = AgentSupervisor.threadId(for: done)
        let ended = Date().addingTimeInterval(-120)
        // Its report, filed in its turn (the fixture stamps that turn start + 3 s).
        _ = supervisor.fileReport(AgentReport(summary: "Finished"), for: done, at: max(Date(), start.addingTimeInterval(Double(names.count))))
        supervisor.qaDeliver(.turnCompleted(threadId: doneThread, turnId: "t1", outcome: .completed, errorMessage: nil), to: done, now: ended)
        supervisor.qaDeliver(.sessionStateChanged(.ready), to: done, now: ended)
        try await AgentPresenceChecks.eventually("the finished helper did not move to Done") {
            view.presentation?.steps.first { $0.ownerAgent == done }?.state == .done
        }
        try await Task.sleep(for: .milliseconds(400))
        view.layoutSubtreeIfNeeded()
        let after = view.presentation?.steps ?? []
        try expect(after.filter(\.isSection).map(\.title) == ["Working", "Done"], "sections after a finish: \(rows(view.presentation))\n\(dump())")
        try expect(after.compactMap(\.ownerAgent) == order.filter { $0 != done } + [done], "a finish reordered the others: \(rows(view.presentation))")
        try expect(heightChanges <= 1 && trace.count <= 2, "a finish took \(trace.count) changes / \(heightChanges) height changes\n\(dump())")
        if let closed = streamClosedPlan() { throw WorkspaceAgentReportChecks.Failure(description: "lead-plan: the finish closed the open plan (\(closed))") }
        let ownerAfter = ownerCell(helpers[0])
        try expect(ownerAfter.minX == ownerBefore.minX && ownerAfter.width == ownerBefore.width,
                   "the owner column shifted when a row gained an age: \(ownerBefore) -> \(ownerAfter)")
        try expect(after.first { $0.ownerAgent == done }?.note == "2 min ago", "finished helper lost its age: \(rows(view.presentation))")
        try expect(view.isOpen && view.list?.glance.steps.first { view.list?.glance.helperID(of: $0) == done }?.phase == .done,
                   "the open plan did not take the finish in place")
        view.close()

        if let dir = ProcessInfo.processInfo.environment["CONTINUUM_PLAN_DRAWER_DIR"].map({ URL(fileURLWithPath: $0) }) {
            try stills(tile, view: view, to: dir, name: "steady")
        }
        print("Lead plan steady passed: one kind per column, stable order/sections/height through a 120-event burst, bounded cadence, finish lands once")
    }

    /// `--lead-plan-model-check`. Live 2026-11-23 on 0.7.60: the drawer read
    /// "Helpers · 1 working · 3 need you" over three helpers that failed six days
    /// ago, counted two idle helpers as working, and numbered helpers and plan
    /// steps as two lists though the steps were owned by those helpers. This
    /// builds his drawer through the production supervisor path and the mounted
    /// tile, and asserts the model: steps link to their helpers, old failures
    /// do not need the user, waiting is not working, and the order is stable.
    static func runModel() async throws {
        let b = try ManagedModeChecks.bench("lead-plan-model")
        defer { b.tearDown() }
        let supervisor = b.supervisor, lead = b.f.agentId
        let tile = try mountLead(b)
        let view = tile.qaLeadPlanView
        let sixDays = Date().addingTimeInterval(-6 * 86400)
        var serial = 0
        func helper(_ name: String) -> AgentID {
            serial += 1
            let id = supervisor.spawn(role: nil, prompt: nil, cwd: b.f.pbRoot, harness: .claudeCode,
                model: ManagedModeChecks.model, thinking: "high", projectId: b.f.projectPb,
                projectRoot: b.f.pbRoot, parentAgentID: lead, displayName: name)
            supervisor.qaDeliver(.sessionStateChanged(.running), to: id, now: Date().addingTimeInterval(Double(serial) - 600))
            return id
        }
        func startTurn(_ id: AgentID, at: Date) {
            supervisor.qaDeliver(.turnStarted(threadId: AgentSupervisor.threadId(for: id), turnId: "t1"), to: id, now: at)
        }
        func finishTurn(_ id: AgentID, _ outcome: TurnOutcome, at: Date) {
            supervisor.qaDeliver(.turnCompleted(threadId: AgentSupervisor.threadId(for: id), turnId: "t1", outcome: outcome, errorMessage: outcome == .failed ? "boom" : nil), to: id, now: at)
            supervisor.qaDeliver(.sessionStateChanged(.ready), to: id, now: at)
        }
        // His drawer: three helpers failed six days ago, two idle, one done, one running.
        let failed = ["Sidebar audit", "Login flow", "History export"].map(helper)
        for id in failed { startTurn(id, at: sixDays); finishTurn(id, .failed, at: sixDays.addingTimeInterval(60)) }
        let idle = ["Copy review", "Icon pass"].map(helper)
        for id in idle { supervisor.qaDeliver(.sessionStateChanged(.ready), to: id, now: Date().addingTimeInterval(-500)) }
        let done = helper("Release notes")
        startTurn(done, at: Date().addingTimeInterval(-300)); finishTurn(done, .completed, at: Date().addingTimeInterval(-120))
        _ = supervisor.fileReport(AgentReport(summary: "Release notes written"), for: done, at: Date().addingTimeInterval(-120))
        let running = helper("Drawer rework")
        startTurn(running, at: Date().addingTimeInterval(-30))
        let names = ["Sidebar audit": failed[0], "Login flow": failed[1], "History export": failed[2],
                     "Copy review": idle[0], "Icon pass": idle[1], "Release notes": done, "Drawer rework": running]
        for (name, id) in names { try expect(supervisor.records[id]?.humanDisplayName == name, "helper \(name) did not take its name") }
        // Plan: owners by name and by id; the rest are the lead's.
        let plan = [AgentPlanStep(title: "Rework the drawer", owner: "Drawer rework"),
                    AgentPlanStep(title: "Copy pass", owner: idle[0].rawValue.uuidString),
                    AgentPlanStep(title: "Retry the history export", owner: failed[2].rawValue.uuidString),
                    AgentPlanStep(title: "Review and merge", owner: "lead"),
                    AgentPlanStep(title: "Ship", owner: "lead")]
        try expect(supervisor.declareStatus(AgentDeclaredStatus(now: "Delegated", plan: plan, declaredAt: Date(), planDeclaredAt: Date().addingTimeInterval(-120)), for: lead), "plan refused")
        try await AgentPresenceChecks.eventually("the plan did not reach the drawer") { view.presentation?.entries.count == 5 }
        guard let p = view.presentation else { throw WorkspaceAgentReportChecks.Failure(description: "lead-plan-model: no drawer") }
        var failures: [String] = []
        func check(_ ok: Bool, _ message: String) { if !ok { failures.append(message) } }
        func name(_ id: AgentID) -> String { supervisor.records[id]?.humanDisplayName ?? "?" }
        // 1. One ordered list: plan order, each step carrying its helpers; the rest in a tail.
        check(p.entries.map(\.title) == plan.map(\.title), "entries not in plan order: \(p.entries.map(\.title))")
        check(p.entries.first?.helpers.map(\.id) == [running], "step 1 not linked to its helper by name: \(p.entries.first?.helpers.map { name($0.id) } ?? [])")
        check(p.entries.dropFirst().first?.helpers.map(\.id) == [idle[0]], "step 2 not linked to its helper by id")
        check(p.entries.dropFirst(2).first?.helpers.map(\.id) == [failed[2]], "step 3 not linked to its helper by id")
        check(p.entries.suffix(2).allSatisfy { $0.helpers.isEmpty && $0.ownerLabel == "Lead" }, "lead steps carry helpers")
        check(Set(p.tail.map(\.id)).isDisjoint(with: Set(p.entries.flatMap(\.helpers).map(\.id))), "a linked helper is also in the tail")
        check(p.tail.map(\.id) == [idle[1], done], "tail wrong (want unlinked helpers: waiting, then recent done): \(p.tail.map { name($0.id) + ":" + $0.bucket.rawValue })")
        // 2. Six-day-old failures do not need the user, anywhere.
        check(p.counts.needsYou == 0, "old failures count as needing the user: \(p.counts)")
        check(p.entries[2].helpers.first?.bucket == .finished && p.entries[2].helpers.first?.state == .failed, "an old failure on a step is not finished/failed")
        check(!p.steps.contains { $0.isSection && $0.title == "Needs you" }, "an old failure got a Needs you group")
        check(p.urgent?.state != .failed, "an old failure is urgent")
        // 3. Waiting is not working: counted, headed and grouped apart.
        check(p.counts.working == 1 && p.counts.waiting == 2 && p.counts.finished == 1, "counts wrong: \(p.counts)")
        check(p.title == "Helpers · 1 working · 2 waiting", "header wrong: \(p.title ?? "nil")")
        check(p.entries[1].helpers.first?.bucket == .waiting && p.entries[1].state == .waiting, "an idle helper's step is not waiting")
        var section = ""
        for row in p.steps { if row.isSection { section = row.title } else if row.ownerAgent != nil && row.state == .waiting && section == "Working" { failures.append("a waiting helper sits under Working") } }
        // 4. Order is stable across recomputes and a burst of helper events.
        let before = p
        for i in 0..<30 {
            supervisor.qaDeliver(.contentDelta(threadId: AgentSupervisor.threadId(for: running), turnId: "t1", streamKind: .assistant, delta: "t\(i) "), to: running, now: Date())
        }
        try await Task.sleep(for: .milliseconds(500))
        check(view.presentation?.entries.map(\.id) == before.entries.map(\.id) && view.presentation?.tail.map(\.id) == before.tail.map(\.id), "order changed under streaming")
        check(supervisor.leadPlan(for: lead, now: Date())?.entries.map(\.id) == before.entries.map(\.id), "entry ids unstable")
        guard failures.isEmpty else {
            throw WorkspaceAgentReportChecks.Failure(description: "lead-plan-model: " + failures.joined(separator: "; "))
        }
        // 5. A fresh failure needs the user until the lead takes a turn after it.
        guard failures.isEmpty else {
            throw WorkspaceAgentReportChecks.Failure(description: "lead-plan-model: " + failures.joined(separator: "; "))
        }
        // 5. A fresh failure needs the user until the lead takes a turn after it. (The
        // production alert path makes the lead take a turn straight away, which is
        // the rule working; stamp the failure just ahead of that turn so the
        // unacknowledged state can be held still and observed.)
        let fresh = helper("Fresh failure")
        let failedAt = Date().addingTimeInterval(120)
        startTurn(fresh, at: failedAt.addingTimeInterval(-30)); finishTurn(fresh, .failed, at: failedAt)
        try await AgentPresenceChecks.eventually("a fresh failure did not need the user") { view.presentation?.counts.needsYou == 1 }
        check(view.presentation?.title == "Helpers · 1 working · 2 waiting · 1 need you", "header after fresh failure: \(view.presentation?.title ?? "nil")")
        check(view.presentation?.tail.first?.id == fresh && view.presentation?.tail.first?.bucket == .needsYou, "a fresh failure is not first in the tail as needsYou")
        startTurn(lead, at: failedAt.addingTimeInterval(10)); finishTurn(lead, .completed, at: failedAt.addingTimeInterval(20))
        try await AgentPresenceChecks.eventually("the lead's turn did not acknowledge the failure") { view.presentation?.counts.needsYou == 0 }
        check(view.presentation?.title == "Helpers · 1 working · 2 waiting", "header after the lead's turn: \(view.presentation?.title ?? "nil")")
        guard failures.isEmpty else {
            throw WorkspaceAgentReportChecks.Failure(description: "lead-plan-model: " + failures.joined(separator: "; "))
        }
        // 6. A turn ending is not the helper being done. Live 2026-11-24: the plan
        // read "2 of 4 done" while the lead said alpha was not, because a turn
        // that ended without a report, with a background command still running,
        // read Done. Done needs its report and no live job of its own.
        let previousTracker = supervisor.processTracker
        let tracker = AgentProcessTracker(internalPathPrefixes: [])
        supervisor.processTracker = tracker
        tracker.onJobsEnded = nil // the idle waker's wake is not under test here
        defer { supervisor.processTracker = previousTracker }
        let alpha = helper("Alpha")
        tracker.knownAgents = { [alpha] }
        func alphaState() -> String {
            let h = view.presentation?.tail.first { $0.id == alpha }
            return h.map { "\($0.state.rawValue)/\($0.bucket.rawValue)" } ?? "absent"
        }
        startTurn(alpha, at: Date().addingTimeInterval(-60)); finishTurn(alpha, .completed, at: Date().addingTimeInterval(-10))
        try await AgentPresenceChecks.eventually("alpha's turn did not end") { !supervisor.isRunning(alpha) && view.presentation?.tail.contains { $0.id == alpha } == true }
        try await Task.sleep(for: .milliseconds(300))
        check(alphaState() == "Waiting/waiting", "a turn that ended without a report reads \(alphaState()), not Waiting")
        tracker.publish([alpha.rawValue.uuidString: [AgentBackgroundJob(id: "job-4242", owner: alpha.rawValue.uuidString, rootPid: 4242,
            pids: [4242], startTimes: [:], label: "swift test", commandLine: "swift test", ports: [],
            startedAt: Date().addingTimeInterval(-30), detached: true)]])
        _ = supervisor.fileReport(AgentReport(summary: "Alpha done"), for: alpha)
        try await Task.sleep(for: .milliseconds(300))
        check(alphaState() == "Waiting/waiting", "a reported helper with a live background job reads \(alphaState()), not Waiting")
        tracker.publish([:])
        try await AgentPresenceChecks.eventually("alpha did not read Done once its report was in and its job ended") { alphaState() == "Done/finished" }
        guard failures.isEmpty else {
            throw WorkspaceAgentReportChecks.Failure(description: "lead-plan-model: " + failures.joined(separator: "; "))
        }
        print("Lead plan model passed: steps link to helpers, stale failures do not need you, waiting is not working, order is stable, done needs a report and no live job")
    }

    static func stills(_ tile: ManagedAgentTileNSView, view: AgentLeadPlanView, to dir: URL, name: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous; tile.appearance = nil }
        for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let theme = NSAppearance(named: appearance)!
            NSApp.appearance = theme; tile.appearance = theme
            tile.window?.appearance = theme
            tile.layoutSubtreeIfNeeded(); view.layoutSubtreeIfNeeded()
            var result: Result<NSBitmapImageRep, Error>!
            theme.performAsCurrentDrawingAppearance { result = Result { try UIProbe.bitmap(of: view, id: "plan-drawer-\(name)") } }
            try result.get().representation(using: .png, properties: [:])!
                .write(to: dir.appendingPathComponent("\(name)-\(label).png"))
        }
    }

    /// The lead tile, managed and mounted through the production spawn/wiring route.
    static func mountLead(_ b: WorkspaceAgentReportChecks.Bench) throws -> ManagedAgentTileNSView {
        let supervisor = b.supervisor, lead = b.f.agentId
        try b.f.delegate.reconciledManagedSessionSource.reconcile(
            registry: b.f.delegate.registryStore!.loadOrEmpty(), reason: .continuumRestarted, now: Date())
        try expect(supervisor.setProviderSettings(agentID: lead, harness: .claudeCode, model: ManagedModeChecks.model),
                   "could not select lead harness")
        ManagedSettingChecks.write(AgentManagedModeConfig.enabledKey, true, b)
        try expect(supervisor.records[lead]?.mode == .managed && supervisor.records[lead]?.parentAgentID == nil,
                   "Settings did not enable the top-level lead")
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
        return tile
    }

    private static func delegateHelper(_ b: WorkspaceAgentReportChecks.Bench, label: String) async throws -> AgentID {
        // ManagedModeChecks.delegate deliberately spawns top-level runner-policy
        // fixtures. Plan owners need real children of the token-bound lead.
        let reply = try await WorkspaceAgentReportChecks.call(b.configuration(for: b.f.agentId), "array_delegate", [
            "task": label, "title": label, "harness": "Claude Code",
            "model": ManagedModeChecks.model, "idempotencyKey": UUID().uuidString])
        guard !reply.isError, let result = reply.reply["result"] as? [String: Any],
              let raw = result["childAgentId"] as? String, let uuid = UUID(uuidString: raw) else {
            throw WorkspaceAgentReportChecks.Failure(description: "plan helper delegation failed: \(reply.reply)")
        }
        let id = AgentID(rawValue: uuid)
        try expect(b.supervisor.records[id]?.parentAgentID == b.f.agentId && b.supervisor.records[id]?.mode == .free,
                   "delegation must create a Free helper of the lead")
        return id
    }

    static func render(_ tile: ManagedAgentTileNSView, window: NSWindow) throws {
        let output = ProcessInfo.processInfo.environment["CONTINUUM_LEAD_PLAN_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let theme = NSAppearance(named: appearance)!
            NSApp.appearance = theme; window.appearance = theme; tile.appearance = theme
            tile.wakeChrome(); tile.layoutSubtreeIfNeeded(); window.layoutIfNeeded()
            tile.qaCanvasTranscript?.flushPendingVisualUpdate()
            // The plan is a line inside the composer's status row, never a band of its own.
            let line = tile.qaLeadPlanView
            try expect(line.frame.height > 0 && line.frame.width > 0, "plan line has no layout size")
            try expect(line.superview?.superview?.identifier?.rawValue == "agentTile.statusRow", "plan line is not in the status row")
            let plan = line.convert(line.bounds, to: tile)
            let composer = tile.qaPageZoomComposeBackdrop.convert(tile.qaPageZoomComposeBackdrop.bounds, to: tile)
            try expect(composer.contains(plan), "plan line sits outside the compose area: \(plan) vs \(composer)")
            var result: Result<NSBitmapImageRep, Error>!
            theme.performAsCurrentDrawingAppearance { result = Result { try UIProbe.bitmap(of: tile, id: "managed-lead-plan") } }
            let rep = try result.get()
            if let output {
                try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("lead-plan-built-\(name).png"))
            }
        }
    }
}

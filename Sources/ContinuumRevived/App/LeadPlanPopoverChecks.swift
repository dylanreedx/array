import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// His plan, built through the production supervisor: real helper records and
/// events, a declared plan that names them, and (with `attention`) a helper
/// that failed after the lead's last turn plus a lead decision with answers.
/// Shared by `--lead-plan-popover-check` and `--lead-plan-popover-render`.
@MainActor
enum LeadPlanFixture {
    struct Helpers {
        var running: AgentID
        var design: AgentID
        var strays: [AgentID]
    }
    static let decision = "Ship the drawer fix in 0.7.61, or hold it?"
    static let options = ["Ship it", "Hold for 0.7.62"]

    static func his(_ s: AgentSupervisor, lead: AgentID, attention: Bool, spawn: (String) throws -> AgentID) throws -> Helpers {
        let now = Date()
        func start(_ id: AgentID, at: Date) {
            s.qaDeliver(.sessionStateChanged(.running), to: id, now: at)
            s.qaDeliver(.turnStarted(threadId: AgentSupervisor.threadId(for: id), turnId: "t1"), to: id, now: at)
        }
        func finish(_ id: AgentID, _ outcome: TurnOutcome, at: Date) {
            s.qaDeliver(.turnCompleted(threadId: AgentSupervisor.threadId(for: id), turnId: "t1", outcome: outcome,
                                       errorMessage: outcome == .failed ? "render failed" : nil), to: id, now: at)
            s.qaDeliver(.sessionStateChanged(.ready), to: id, now: at)
        }
        let sixDays = now.addingTimeInterval(-6 * 86400)
        for name in ["Sidebar fold band", "Relay deletion routes", "Bubble orb sizing"] {
            let id = try spawn(name); start(id, at: sixDays); finish(id, .failed, at: sixDays.addingTimeInterval(60))
        }
        var strays: [AgentID] = []
        for name in ["Settings theme picker", "Companion task alerts"] {
            let id = try spawn(name); s.qaDeliver(.sessionStateChanged(.ready), to: id, now: now.addingTimeInterval(-500)); strays.append(id)
        }
        let done = try spawn("iOS preview tiles")
        start(done, at: now.addingTimeInterval(-4000)); finish(done, .completed, at: now.addingTimeInterval(-3600))
        _ = s.fileReport(AgentReport(summary: "Preview tiles shipped"), for: done, at: now.addingTimeInterval(-3600))
        let running = try spawn("Drawer data model")
        start(running, at: now.addingTimeInterval(-30))
        let design = try spawn("Drawer redesign view")
        if attention {
            // Failed after the lead's last turn: it needs him until the lead acts.
            let failedAt = now.addingTimeInterval(120)
            start(design, at: failedAt.addingTimeInterval(-60)); finish(design, .failed, at: failedAt)
        } else {
            s.qaDeliver(.sessionStateChanged(.ready), to: design, now: now.addingTimeInterval(-400))
        }
        let plan = [AgentPlanStep(title: "Fix the drawer's data model", owner: running.rawValue.uuidString),
                    AgentPlanStep(title: "Design three drawer directions", owner: design.rawValue.uuidString),
                    AgentPlanStep(title: "Review the directions with Dylan", owner: "you"),
                    AgentPlanStep(title: "Join the view to the model", owner: "lead"),
                    AgentPlanStep(title: "Gate and ship 0.7.61", owner: "lead")]
        guard s.declareStatus(AgentDeclaredStatus(now: "Delegated", needsYou: attention ? decision : nil, plan: plan, declaredAt: now,
                                                  planDeclaredAt: now, options: attention ? options : nil), for: lead) else {
            throw WorkspaceAgentReportChecks.Failure(description: "lead-plan fixture: plan refused")
        }
        return Helpers(running: running, design: design, strays: strays)
    }

    /// A two-step plan on a small tile; with `attention`, its helper asks him
    /// something and the lead asks a decision.
    static func small(_ s: AgentSupervisor, lead: AgentID, attention: Bool, spawn: (String) throws -> AgentID) throws {
        let id = try spawn("Login redirect fix")
        s.qaDeliver(.sessionStateChanged(.running), to: id, now: Date().addingTimeInterval(-40))
        s.qaDeliver(.turnStarted(threadId: AgentSupervisor.threadId(for: id), turnId: "t1"), to: id, now: Date().addingTimeInterval(-40))
        if attention {
            _ = s.declareStatus(AgentDeclaredStatus(now: "Waiting on you", needsYou: "Clear the stale session cookie too?", declaredAt: Date()), for: id)
        }
        let plan = [AgentPlanStep(title: "Fix the login redirect", owner: id.rawValue.uuidString),
                    AgentPlanStep(title: "Ship the hotfix", owner: "lead")]
        guard s.declareStatus(AgentDeclaredStatus(now: "Delegated", needsYou: attention ? "Ship the hotfix tonight, or wait for QA?" : nil, plan: plan,
                                                  declaredAt: Date(), planDeclaredAt: Date(),
                                                  options: attention ? ["Ship tonight", "Wait for QA"] : nil), for: lead) else {
            throw WorkspaceAgentReportChecks.Failure(description: "lead-plan fixture: small plan refused")
        }
    }
}

extension ManagedLeadPlanChecks {
    /// A left click at `point` (window coordinates) through `NSApp.sendEvent`,
    /// so the popover's own event monitor sees it exactly as a real click.
    static func click(_ window: NSWindow, at point: NSPoint, number: Int) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                              context: nil, eventNumber: number, clickCount: 1, pressure: 1) { NSApp.sendEvent(event) }
        }
    }

    /// `--lead-plan-popover-check`: the lead's plan line, through the production
    /// spawn, supervisor and tile, driven by real click and key events.
    static func runPopover() async throws {
        let b = try ManagedModeChecks.bench("lead-plan-popover")
        defer { b.tearDown() }
        let supervisor = b.supervisor, lead = b.f.agentId
        let tile = try mountLead(b)
        let line = tile.qaLeadPlanView
        let previousReduced = ChoicePanelMotion.prefersReducedMotion
        ChoicePanelMotion.prefersReducedMotion = { false }
        defer { ChoicePanelMotion.prefersReducedMotion = previousReduced }
        let helpers = try LeadPlanFixture.his(supervisor, lead: lead, attention: true) { name in
            supervisor.spawn(role: nil, prompt: nil, cwd: b.f.pbRoot, harness: .claudeCode, model: ManagedModeChecks.model, thinking: "high",
                             projectId: b.f.projectPb, projectRoot: b.f.pbRoot, parentAgentID: lead, displayName: name)
        }
        try await AgentPresenceChecks.eventually("the plan did not reach the line") { line.glance?.steps.count == 5 && !line.isHidden }
        // The bench parks the tile off its canvas's visible area; host it in
        // its own offscreen window at his tile size, as the render leg does.
        tile.removeFromSuperview()
        tile.frame = NSRect(x: 0, y: 0, width: 960, height: 800)
        let host = NSWindow(contentRect: tile.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView = tile
        host.orderFrontOffscreenForChecks()
        defer { line.close(); host.orderOut(nil) }
        // A resting tile keeps its body in a detached host; a pointer on the
        // tile wakes it into the tile's window, which is where clicks land.
        tile.wakeChrome(); tile.layoutSubtreeIfNeeded()
        guard let window = tile.window, line.window === window else {
            throw WorkspaceAgentReportChecks.Failure(description: "lead-plan-popover: the line is not in the tile's window: tile \(String(describing: tile.window)) line \(String(describing: line.window)) resting \(tile.isChromeResting) hidden \(line.isHidden) super \(String(describing: line.superview))")
        }
        window.orderFrontOffscreenForChecks()

        // 1. It lives in the status row.
        try expect(line.superview?.superview?.identifier?.rawValue == "agentTile.statusRow", "the line is not in the composer's status row")
        try expect(line.frame.width > 0, "the line has no width")

        // 2. The count is what the popover marks: the decision and the step
        // that failed. The step he owns is not his yet (steps before it are open).
        guard let g = line.glance else { throw WorkspaceAgentReportChecks.Failure(description: "lead-plan-popover: no glance") }
        let marked = (g.decision == nil ? 0 : 1) + g.steps.filter { PlanGlance.isAttention($0.phase) }.count
            + g.strays.filter { PlanGlance.isAttention($0.phase) }.count
        try expect(g.steps.map(\.phase) == [.working, .failed, .todo, .todo, .todo], "step states: \(g.steps.map(\.phase))")
        try expect(marked == 2 && line.sentence.contains("2 need you"), "the line's count \(line.sentence) is not the 2 marks the popover shows")
        try expect(g.alsoText == "Also · 2 idle", "the Also line says more than it should: \(g.alsoText ?? "nil")")

        // 3. A click opens it, with the shared entrance.
        var clicks = 100
        func clickLine() async {
            // A real second click comes on a later pass of the event loop, and
            // lands on a line that has stopped moving (a reveal glides the camera).
            try? await Task.sleep(for: .milliseconds(30))
            var last = line.convert(line.bounds, to: nil), still = 0
            for _ in 0..<100 where still < 3 {
                try? await Task.sleep(for: .milliseconds(50))
                let now = line.convert(line.bounds, to: nil)
                still = now == last ? still + 1 : 0
                last = now
            }
            clicks += 1
            let p = line.convert(NSPoint(x: line.bounds.maxX - 8, y: line.bounds.midY), to: nil)
            click(window, at: p, number: clicks)
        }
        await clickLine()
        let probe = line.convert(NSPoint(x: line.bounds.maxX - 8, y: line.bounds.midY), to: nil)
        let hit = window.contentView.flatMap { $0.hitTest($0.superview?.convert(probe, from: nil) ?? probe) }
        try expect(line.isOpen, "a click on the line did not open the plan: hit \(hit.map { String(describing: type(of: $0)) } ?? "nil") at \(probe), line window \(line.window === window), panel \(String(describing: line.popover.panel)), visible \(window.isVisible)")
        guard let panel = line.popover.panel, let chrome = panel.contentView, let list = line.list else {
            throw WorkspaceAgentReportChecks.Failure(description: "lead-plan-popover: no panel")
        }
        try expect(panel.isVisible && panel.parent === window, "the plan is not a child panel of the tile's window")
        try expect(chrome.layer?.animation(forKey: ChoicePanelMotion.enterKey) != nil, "the panel appeared without the shared entrance")
        let tileOnScreen = window.convertToScreen(tile.convert(tile.visibleRect, to: nil))
        let surface = panel.frame.insetBy(dx: ChoicePanelShadowView.margin, dy: ChoicePanelShadowView.margin)
        let lineOnScreen = window.convertToScreen(line.convert(line.bounds, to: nil))
        try expect(tileOnScreen.contains(surface), "the plan left the tile: \(surface) vs \(tileOnScreen)")
        try expect(surface.minY >= lineOnScreen.maxY, "the plan does not open above its line")
        list.layoutSubtreeIfNeeded()
        try expect(abs(list.chipRailFrame.minX - list.questionTextX) < 0.5, "the chips do not start at the question's left edge")
        func chipsIn(_ v: NSView) -> [ComposerReplyOptionChipButton] {
            v.subviews.flatMap { ($0 as? ComposerReplyOptionChipButton).map { [$0] } ?? chipsIn($0) }
        }
        let chips = chipsIn(list.rail)
        let firstChip = chips.first.map { list.convert($0.bounds, from: $0) }
        try expect(firstChip.map { abs($0.minX - list.questionTextX) < 0.5 } == true,
                   "the first chip does not start at the question's left edge: \(String(describing: firstChip)) vs \(list.questionTextX)")
        try expect(chips.count == 2 && chips.allSatisfy { $0.style == .compact }, "the answers are not equal chips: \(chips.map { "\($0.style)" })")
        try expect(list.rail.qaOptions == LeadPlanFixture.options, "chips: \(list.rail.qaOptions)")

        // 4. A second click on the line closes it, with the shared exit, and does not reopen it.
        await clickLine()
        try expect(!line.isOpen, "a second click did not close the plan")
        try expect(line.popover.qaLeavingPanel === panel && chrome.layer?.animation(forKey: ChoicePanelMotion.leaveKey) != nil,
                   "the panel vanished without the shared exit")
        try await Task.sleep(for: .milliseconds(Int(ChoicePanelMotion.leaveDuration * 1000) + 120))
        try expect(!panel.isVisible && line.popover.qaLeavingPanel == nil, "the panel outlived its exit")
        try expect(!line.isOpen, "the closing click reopened the plan")

        // 5. Escape closes it.
        await clickLine()
        try expect(line.isOpen, "the plan did not reopen")
        if let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: line.popover.panel?.windowNumber ?? 0, context: nil, characters: "\u{1b}",
                                      charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) { NSApp.sendEvent(esc) }
        try expect(!line.isOpen, "Escape did not close the plan")

        // 6. It stays open and takes a helper's change in place.
        await clickLine()
        try expect(line.isOpen, "the plan did not reopen for the live update")
        supervisor.qaDeliver(.turnStarted(threadId: AgentSupervisor.threadId(for: helpers.strays[0]), turnId: "t2"), to: helpers.strays[0], now: Date())
        supervisor.qaDeliver(.sessionStateChanged(.running), to: helpers.strays[0], now: Date())
        try await AgentPresenceChecks.eventually("the open plan did not take the change") {
            line.list?.glance.alsoText == "Also · 1 running · 1 idle"
        }
        try expect(line.isOpen, "a helper's change closed the plan")

        // 7. Clicking a helper's orb reveals that helper and closes the plan.
        var revealed: [AgentID] = []
        let originalReveal = tile.onRevealAgent
        tile.onRevealAgent = { id, parent in revealed.append(id); originalReveal?(id, parent) }
        defer { tile.onRevealAgent = originalReveal }
        guard let open = line.list, let openPanel = line.popover.panel, let orb = open.orbFrame(0) else {
            throw WorkspaceAgentReportChecks.Failure(description: "lead-plan-popover: no orb on step 1")
        }
        clicks += 1
        click(openPanel, at: open.convert(NSPoint(x: orb.midX, y: orb.midY), to: nil), number: clicks)
        try expect(revealed == [helpers.running], "clicking step 1's orb did not reveal its helper: \(revealed)")
        try expect(!line.isOpen, "revealing a helper left the plan open")

        // 8. A chip answers into the composer. The reveal focused the tile in
        // its canvas (moved it, parked its chrome); put it back in the host window.
        tile.frame = NSRect(x: 0, y: 0, width: 960, height: 800)
        tile.wakeChrome(); tile.layoutSubtreeIfNeeded()
        await clickLine()
        try expect(line.isOpen, "the plan did not reopen after a reveal: window \(line.window === window) dismissal \(line.popover.qaLastSelfDismissal ?? "-")")
        try expect(line.list?.rail.qaPressChip(titled: "Hold for 0.7.62") == true, "the chip could not be pressed: \(line.list?.rail.qaOptions ?? [])")
        try expect(tile.qaComposerDraftText == "Hold for 0.7.62", "the chip did not answer into the composer: \(tile.qaComposerDraftText)")
        try expect(!line.isOpen, "answering left the plan open")

        // 9. When the decision goes, the count follows.
        try expect(supervisor.declareStatus(AgentDeclaredStatus(now: "Restarting the redesign", plan: supervisor.records[lead]?.declaredStatus?.plan,
                                                                declaredAt: Date(), planDeclaredAt: Date()), for: lead), "status refused")
        try await AgentPresenceChecks.eventually("the count did not drop with the decision") { line.sentence.contains("1 needs you") }
        print("Lead plan popover passed: in the status row, \(line.sentence); opens above the line inside the tile with the shared entrance; a second click closes it with the shared exit and does not reopen; Escape closes; stays open through a helper's change; an orb reveals its helper; a chip answers into the composer; chips start at the question; the count follows the decision")
    }
}

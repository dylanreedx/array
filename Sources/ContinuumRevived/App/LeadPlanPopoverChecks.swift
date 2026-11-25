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
        // Key-capable, so the line's key-window tracking area answers the pointer.
        let host = SidebarParityCapture.KeyWindow(contentRect: tile.frame, styleMask: [.borderless], backing: .buffered, defer: false)
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
        try expect(g.also.map(\.phase) == [.idle, .idle], "the Also rows are not the two idle helpers: \(g.also.map { "\($0.name) \($0.phase)" })")

        // 3. A click opens it, with the shared entrance.
        var clicks = 100
        func clickLine(at x: CGFloat? = nil, y: CGFloat? = nil) async {
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
            let p = line.convert(NSPoint(x: x ?? line.bounds.maxX - 8, y: y ?? line.bounds.midY), to: nil)
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
            line.list?.glance.also.map(\.phase) == [.working, .idle]
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

        // 9b. The whole section is one control: a click anywhere on the line,
        // an orb, the gap after the pile or the hover fill's pad, opens the
        // plan and reveals nothing; a second click there closes it. Going to
        // a helper is the popover's job, from its row or its orb.
        revealed = []
        line.layoutSubtreeIfNeeded()
        guard let lineOrb = line.qaPile.first?.frame, let pileEnd = line.qaPile.map(\.frame.maxX).max() else {
            throw WorkspaceAgentReportChecks.Failure(description: "lead-plan-popover: no orb on the line")
        }
        let fillPad = PlanMetrics.s(Space.s, line.zoom)
        let targets: [(String, CGFloat, CGFloat)] = [
            ("an orb", lineOrb.midX, lineOrb.midY),
            ("the gap after the pile", pileEnd + 2, line.bounds.midY),
            ("the fill's left pad", line.bounds.minX - fillPad / 2, line.bounds.midY),
            ("the fill's right pad", line.bounds.maxX + fillPad / 2, line.bounds.midY),
        ]
        var sectionClicks: [String] = []
        for (what, x, y) in targets {
            await clickLine(at: x, y: y)
            try expect(line.isOpen && revealed.isEmpty,
                       "a click on \(what) of the line did not open the plan: open \(line.isOpen), revealed \(revealed)")
            await clickLine(at: x, y: y)
            try expect(!line.isOpen, "a second click on \(what) did not close the plan")
            sectionClicks.append(what)
        }
        // In the popover, a helper's whole row takes the row hover and reveals it.
        await clickLine()
        guard let rows = line.list, let rowsPanel = line.popover.panel,
              let row = rows.glance.steps.indices.first(where: { rows.glance.helperID(of: rows.glance.steps[$0]) != nil }),
              let rowHelper = rows.glance.helperID(of: rows.glance.steps[row]) else {
            throw WorkspaceAgentReportChecks.Failure(description: "lead-plan-popover: no helper row in the open plan")
        }
        let rowRect = rows.rowRect(row)
        let rowProbe = NSPoint(x: rowRect.minX + PlanMetrics.s(Space.m, line.zoom), y: rowRect.midY)
        func rowPixel() throws -> NSColor? {
            let rep = try UIProbe.bitmap(of: rows, id: "lead-plan-rows")
            let k = CGFloat(rep.pixelsWide) / rows.bounds.width
            return rep.colorAt(x: Int(rowProbe.x * k), y: Int(rowProbe.y * k))
        }
        let resting = try rowPixel()
        if let move = NSEvent.mouseEvent(with: .mouseMoved, location: rows.convert(NSPoint(x: rowRect.midX, y: rowRect.midY), to: nil),
                                         modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rowsPanel.windowNumber,
                                         context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            rows.mouseEntered(with: move); rows.mouseMoved(with: move)
        }
        let hovered = try rowPixel()
        try expect(resting != hovered, "a hovered helper row in the plan shows no hover fill: \(String(describing: resting)) then \(String(describing: hovered))")
        clicks += 1
        click(rowsPanel, at: rows.convert(NSPoint(x: rowRect.midX, y: rowRect.midY), to: nil), number: clicks)
        try expect(revealed == [rowHelper], "clicking a helper's row in the plan did not reveal it: \(revealed)")
        try expect(!line.isOpen, "revealing from a row left the plan open")
        print("Lead plan section: a click on \(sectionClicks.joined(separator: ", ")) opens the plan and reveals nothing, a second closes it; a helper row takes the row hover and reveals its helper")
        tile.frame = NSRect(x: 0, y: 0, width: 960, height: 800)
        tile.wakeChrome(); tile.layoutSubtreeIfNeeded()

        // 10. The pile is an avatar stack: each front orb cuts an even gap out
        // of the one behind it, at every rung, in both appearances, and again
        // when helpers leave the pile.
        let stills = ProcessInfo.processInfo.environment["CONTINUUM_LEAD_PLAN_ORB_CUT_DIR"].map { URL(fileURLWithPath: $0) }
        var cuts: [String] = []
        func cutPass(_ label: String) throws {
            for percent in [100, 80] {
                _ = tile.setPageZoom(AgentPageZoom(percent: percent))
                tile.wakeChrome(); tile.layoutSubtreeIfNeeded(); line.layoutSubtreeIfNeeded()
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    cuts.append("\(label)@\(percent)%/\(name): " + (try orbCut(line, appearance: appearance,
                        still: stills?.appendingPathComponent("\(label)-\(percent)-\(name).png"))))
                }
            }
            _ = tile.setPageZoom(.default)
        }
        try await AgentPresenceChecks.eventually("the pile did not hold four orbs") { line.qaPile.count == 4 }
        try cutPass("pile4")
        let hoverStills = ProcessInfo.processInfo.environment["CONTINUUM_LEAD_PLAN_HOVER_DIR"].map { URL(fileURLWithPath: $0) }
        var hovers: [String] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            hovers.append(try await hoverPass(line, window: window, appearance: appearance, stills: hoverStills))
        }
        print("Lead plan hover: " + hovers.joined(separator: "; "))
        // Helpers finish until two are left: the cut follows the new pile.
        for h in line.glance?.helpers ?? [] where line.qaPile.count > 2 && h.phase != .done {
            supervisor.qaDeliver(.turnStarted(threadId: AgentSupervisor.threadId(for: h.id), turnId: "t9"), to: h.id, now: Date())
            supervisor.qaDeliver(.turnCompleted(threadId: AgentSupervisor.threadId(for: h.id), turnId: "t9", outcome: .completed,
                                                errorMessage: nil), to: h.id, now: Date())
            supervisor.qaDeliver(.sessionStateChanged(.ready), to: h.id, now: Date())
            _ = supervisor.fileReport(AgentReport(summary: "Done"), for: h.id, at: Date())
            try? await Task.sleep(for: .milliseconds(100))
        }
        try await AgentPresenceChecks.eventually("the pile did not shrink to two orbs: \(line.qaPile.count)") { line.qaPile.count == 2 }
        try cutPass("pile2")
        print("Lead plan orb cut: " + cuts.joined(separator: "; "))

        // 11. Every helper is reachable from the card. A plan whose steps are
        // all the lead's own leaves its live helpers unlinked: they are the
        // card's "Also" rows, most pressing first, and a click on one reveals
        // that helper and closes the card.
        guard supervisor.declareStatus(AgentDeclaredStatus(now: "Researching", plan: [
            AgentPlanStep(title: "Search for the next event", owner: "lead"),
            AgentPlanStep(title: "Write the preview", owner: "lead")], declaredAt: Date(), planDeclaredAt: Date()), for: lead) else {
            throw WorkspaceAgentReportChecks.Failure(description: "lead-plan-popover: the lead-owned plan was refused")
        }
        try await AgentPresenceChecks.eventually("the plan did not become the lead's own") {
            line.glance.map { $0.steps.count == 2 && $0.steps.allSatisfy { $0.owner == .lead } } == true
        }
        func pressing(_ p: PlanGlance.Phase) -> Int { switch p { case .needsYou, .failed: 0; case .working: 1; case .idle: 2; default: 3 } }
        let unlinked = (line.glance?.helpers ?? []).enumerated().filter { $0.element.phase != .done }
            .sorted { (pressing($0.element.phase), $0.offset) < (pressing($1.element.phase), $1.offset) }.map(\.element)
        try expect(unlinked.count == 2, "the lead-owned plan should leave two live helpers, not \(unlinked.map(\.name))")
        // Back to his zoom and size, settled, so the card's anchor holds still.
        _ = tile.setPageZoom(.default)
        tile.frame = NSRect(x: 0, y: 0, width: 960, height: 800)
        tile.wakeChrome(); tile.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        tile.layoutSubtreeIfNeeded()
        await clickLine()
        guard line.isOpen, let card = line.list, let cardPanel = line.popover.panel else {
            throw WorkspaceAgentReportChecks.Failure(description: "lead-plan-popover: the lead-owned plan did not open: open \(line.isOpen), hidden \(line.isHidden), window \(line.window === window), key \(window.isKeyWindow), frame \(line.frame), dismissal \(line.popover.qaLastSelfDismissal ?? "-"), sentence \(line.sentence)")
        }
        card.layoutSubtreeIfNeeded()
        let second = card.alsoRowRect(1)
        revealed = []
        clicks += 1
        click(cardPanel, at: card.convert(NSPoint(x: second.midX, y: second.midY), to: nil), number: clicks)
        try expect(revealed == [unlinked[1].id] && !line.isOpen,
                   "clicking the Also row of \(unlinked[1].name) did not reveal it and close the card: revealed \(revealed), open \(line.isOpen)")
        print("Lead plan also: with every step the lead's own, \(unlinked.map { "\($0.name) (\($0.phase))" }.joined(separator: ", ")) are the card's Also rows; clicking the second reveals \(unlinked[1].name) and closes the card")

        print("Lead plan popover passed: in the status row, \(line.sentence); opens above the line inside the tile with the shared entrance; a second click closes it with the shared exit and does not reopen; Escape closes; stays open through a helper's change; an orb or row in the plan reveals its helper, the line itself never does; a chip answers into the composer; chips start at the question; the count follows the decision; each orb in the pile cuts an even gap out of the one behind it")
    }

    /// Renders the line and, for each orb and the one behind it, reads the
    /// band just outside the front orb's circle (its ring's outer edge) out to
    /// the knockout gap, where it overlaps the rear orb: every pixel there must
    /// be clear. The rear orb must still paint beyond the band.
    static func lineBitmap(_ line: AgentLeadPlanView, appearance: NSAppearance.Name, still: URL?) throws -> NSBitmapImageRep {
        let theme = NSAppearance(named: appearance)!
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous; line.window?.appearance = nil }
        NSApp.appearance = theme; line.window?.appearance = theme
        line.window?.contentView?.layoutSubtreeIfNeeded(); line.layoutSubtreeIfNeeded()
        var result: Result<NSBitmapImageRep, Error>!
        theme.performAsCurrentDrawingAppearance { result = Result { try UIProbe.bitmap(of: line, id: "lead-plan-line") } }
        let rep = try result.get()
        if let still {
            try FileManager.default.createDirectory(at: still.deletingLastPathComponent(), withIntermediateDirectories: true)
            try rep.representation(using: .png, properties: [:])!.write(to: still)
        }
        return rep
    }

    /// `pairs` are (front, rear) indices into the pile; by default each orb
    /// cuts the one after it.
    /// With `background` (the line's own hover fill), the gap shows that fill
    /// instead of nothing.
    static func orbCut(_ line: AgentLeadPlanView, appearance: NSAppearance.Name, still: URL?,
                       pairs: [(Int, Int)]? = nil, background: NSColor? = nil) throws -> String {
        let pile = line.qaPile
        try expect(pile.count >= 2, "orb cut: the pile has \(pile.count) orbs")
        let rep = try lineBitmap(line, appearance: appearance, still: still)
        let scale = CGFloat(rep.pixelsWide) / line.bounds.width
        let gap = PlanMetrics.s(SwarmPose.knockout, line.zoom)
        func alpha(_ px: Int, _ py: Int) -> CGFloat { rep.colorAt(x: px, y: py)?.alphaComponent ?? 0 }
        /// How far a gap pixel is from showing nothing but what is behind the pile.
        func off(_ px: Int, _ py: Int) -> CGFloat {
            guard let background, let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB) else { return alpha(px, py) }
            return premultipliedDistance(c, background)
        }
        /// Rear ink beyond the gap: anything that is not the background.
        func ink(_ px: Int, _ py: Int) -> Bool { background == nil ? alpha(px, py) > 0.5 : off(px, py) > 0.2 }
        var worst: CGFloat = 0, rearInk = 0, sampled = 0
        for (f, b) in pairs ?? (1..<pile.count).map({ ($0 - 1, $0) }) {
            let front = pile[f].frame, rear = pile[b].frame
            let fc = CGPoint(x: front.midX, y: front.midY), rc = CGPoint(x: rear.midX, y: rear.midY)
            let r = front.width / 2
            for py in Int(rear.minY * scale)..<Int(ceil(rear.maxY * scale)) {
                for px in Int(rear.minX * scale)..<Int(ceil(rear.maxX * scale)) {
                    let p = CGPoint(x: (CGFloat(px) + 0.5) / scale, y: (CGFloat(py) + 0.5) / scale)
                    let df = hypot(p.x - fc.x, p.y - fc.y), dr = hypot(p.x - rc.x, p.y - rc.y)
                    guard dr < r - 0.5 else { continue }
                    // Half a device pixel of antialiasing at each edge of the band.
                    if df > r + 0.5 / scale, df < r + gap - 0.5 / scale {
                        worst = max(worst, off(px, py)); sampled += 1
                    } else if df > r + gap + 1, ink(px, py) { rearInk += 1 }
                }
            }
        }
        try expect(sampled > 0, "orb cut: no pixels in the gap band (gap \(gap) pt at \(scale)x)")
        try expect(rearInk > 0, "orb cut: the rear orbs painted nothing outside the gap")
        try expect(worst < 0.1, "orb cut: the rear orb paints inside the gap around the front orb (\(background == nil ? "alpha" : "off the line's fill by") \(String(format: "%.2f", worst)) over \(sampled) px)")
        return "gap \(String(format: "%.2f", gap)) pt clear over \(sampled) px (max alpha \(String(format: "%.2f", worst)))"
    }

    /// The largest channel difference of two colours, premultiplied, so a faint
    /// translucent fill compares by what it actually adds.
    static func premultipliedDistance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let a = a.usingColorSpace(.deviceRGB)!, b = b.usingColorSpace(.deviceRGB)!
        return max(abs(a.redComponent * a.alphaComponent - b.redComponent * b.alphaComponent),
                   abs(a.greenComponent * a.alphaComponent - b.greenComponent * b.alphaComponent),
                   abs(a.blueComponent * a.alphaComponent - b.blueComponent * b.alphaComponent),
                   abs(a.alphaComponent - b.alphaComponent))
    }

    /// The line's hover, driven through `NSApp.sendEvent`: the whole line takes
    /// the row hover fill and gives it back on exit; an orb under the pointer
    /// comes to the front of the cut, swells, and after the dwell shows its
    /// helper's card; crossing the pile never leaves the line.
    static func hoverPass(_ line: AgentLeadPlanView, window: NSWindow, appearance: NSAppearance.Name,
                          stills: URL?) async throws -> String {
        let name = appearance == .darkAqua ? "dark" : "light"
        window.acceptsMouseMovedEvents = true
        window.makeKey()
        window.appearance = NSAppearance(named: appearance)
        line.layoutSubtreeIfNeeded()
        let pile = line.qaPile
        try expect(pile.count == 4, "hover: the pile has \(pile.count) orbs")
        var movesHanded = 0
        func move(_ p: NSPoint) throws {
            guard let e = NSEvent.mouseEvent(with: .mouseMoved, location: line.convert(p, to: nil), modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else {
                throw WorkspaceAgentReportChecks.Failure(description: "hover: no mouse-moved event")
            }
            // A synthetic move carries no window-server tracking area, so the
            // window hands it to the first responder (the composer), not to the
            // line's area; then it goes to the area's owner, as a real move does.
            let before = line.qaMoves
            NSApp.sendEvent(e)
            if line.qaMoves == before { line.mouseMoved(with: e); movesHanded += 1 }
        }
        // AppKit drops a synthetic crossing (it carries no window-server tracking
        // area); then it goes to the area's owner, the one call a real crossing
        // makes (`SidebarHelperHoverChecks.crossing`).
        var handed = 0
        func crossing(_ type: NSEvent.EventType, _ p: NSPoint) throws {
            guard let area = line.qaTrackingArea,
                  let e = NSEvent.enterExitEvent(with: type, location: line.convert(p, to: nil), modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, trackingNumber: unsafeBitCast(area, to: Int.self),
                                                 userData: nil) else {
                throw WorkspaceAgentReportChecks.Failure(description: "hover: the line has no tracking area")
            }
            let before = line.qaCrossings
            NSApp.sendEvent(e)
            guard line.qaCrossings == before else { return }
            guard let owner = area.owner as? NSResponder else { throw WorkspaceAgentReportChecks.Failure(description: "hover: no owner") }
            if type == .mouseEntered { owner.mouseEntered(with: e) } else { owner.mouseExited(with: e) }
            handed += 1
        }
        let theme: TokenTheme = appearance == .darkAqua ? .dark : .light
        let hoverInk = NSColor(cgColor: AgentInboxCardView.hoverMarkColour(theme: theme))!.usingColorSpace(.deviceRGB)!
        /// A review still of `view` in this pass's appearance.
        func snap(_ view: NSView, _ file: String) throws {
            guard let stills else { return }
            let theme = NSAppearance(named: appearance)!
            let previous = NSApp.appearance
            defer { NSApp.appearance = previous; window.appearance = nil }
            NSApp.appearance = theme; window.appearance = theme
            (view as? TokenThemed)?.applyTokens()
            window.contentView?.layoutSubtreeIfNeeded()
            var result: Result<NSBitmapImageRep, Error>!
            theme.performAsCurrentDrawingAppearance { result = Result { try UIProbe.bitmap(of: view, id: "lead-plan-still") } }
            try result.get().representation(using: .png, properties: [:])!.write(to: stills.appendingPathComponent(file))
        }
        /// The line's own fill, read between the pile and the words.
        func fill(_ still: String) throws -> NSColor? {
            if let stills, let row = line.superview?.superview {
                // In place: the whole status row, on its own chrome.
                try FileManager.default.createDirectory(at: stills, withIntermediateDirectories: true)
                try snap(row, "\(still)-\(name)-row.png")
            }
            let rep = try lineBitmap(line, appearance: appearance, still: stills?.appendingPathComponent("\(still)-\(name).png"))
            let scale = CGFloat(rep.pixelsWide) / line.bounds.width
            let p = NSPoint(x: pile[3].frame.maxX + 3, y: line.bounds.midY)
            let c = rep.colorAt(x: Int(p.x * scale), y: Int(p.y * scale))?.usingColorSpace(.deviceRGB)
            return (c?.alphaComponent ?? 0) < 0.01 ? nil : c
        }
        func isHoverInk(_ c: NSColor?) -> Bool { c.map { premultipliedDistance($0, hoverInk) < 0.02 } ?? false }
        let fade = UInt64((AgentInboxCardView.fillFadeDuration + 0.15) * 1000)
        let words = NSPoint(x: pile[3].frame.maxX + 20, y: line.bounds.midY)
        func centre(_ i: Int) -> NSPoint { NSPoint(x: pile[i].frame.midX, y: pile[i].frame.midY) }

        // Resting: nothing painted.
        try expect(line.qaLineFillRole == nil && line.hoveredOrb == nil, "hover(\(name)): the line is not at rest")
        try expect(try fill("resting") == nil, "hover(\(name)): the resting line paints a fill")

        // The line.
        try crossing(.mouseEntered, words)
        try move(words)
        try await Task.sleep(for: .milliseconds(fade))
        try expect(line.qaLineFillRole == .hover, "hover(\(name)): the hovered line's fill is \(String(describing: line.qaLineFillRole)), not the hover step")
        let lineFill = try fill("line-hover")
        try expect(isHoverInk(lineFill), "hover(\(name)): the hovered line paints \(String(describing: lineFill)), not the hover step \(hoverInk)")
        try expect(line.hoveredOrb == nil, "hover(\(name)): an orb is hovered over the words")
        /// The line's words, pixel for pixel: an orb hover must leave them alone.
        func wordsBand() throws -> [UInt8] {
            let rep = try lineBitmap(line, appearance: appearance, still: nil)
            let k = CGFloat(rep.pixelsWide) / line.bounds.width
            let x0 = Int((pile[3].frame.maxX + 4) * k), x1 = Int((line.bounds.maxX - 4) * k)
            var out: [UInt8] = []
            for y in 0..<rep.pixelsHigh { for x in x0..<x1 {
                let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                out += [c?.redComponent ?? 0, c?.greenComponent ?? 0, c?.blueComponent ?? 0, c?.alphaComponent ?? 0].map { UInt8(($0 * 255).rounded()) }
            } }
            return out
        }
        let wordsAtRest = try wordsBand()

        // Across the pile, back to front and back again: one line, never left.
        let crossed = line.qaCrossings
        for i in [3, 2, 1, 0, 1, 2] {
            try move(centre(i))
            try expect(line.hoveredOrb === pile[i], "hover(\(name)): the pointer on orb \(i) hovers \(String(describing: line.hoveredOrb.flatMap { o in pile.firstIndex { $0 === o } })) (line in window \(line.window === window), key \(window.isKeyWindow), first responder \(String(describing: window.firstResponder.map { type(of: $0) })), moved \(line.qaMoves))")
            try expect(pile[i].qaIsHovered && pile.enumerated().allSatisfy { $0.offset == i || !$0.element.qaIsHovered },
                       "hover(\(name)): orb \(i) is not the only swollen orb")
            try expect(line.qaLineFillRole == .hover, "hover(\(name)): the line lost its hover on orb \(i)")
        }
        try expect(line.qaCrossings == crossed, "hover(\(name)): crossing the pile left and re-entered the line \(line.qaCrossings) vs \(crossed)")

        // Orb 2 (behind 0 and 1) is the front now: it cuts both its neighbours.
        try expect(pile.allSatisfy { $0 === pile[2] || ($0.layer?.zPosition ?? 0) < (pile[2].layer?.zPosition ?? 0) },
                   "hover(\(name)): the hovered orb is not on top")
        let cut = try orbCut(line, appearance: appearance, still: stills?.appendingPathComponent("orb-hover-\(name).png"),
                             pairs: [(2, 1), (2, 3)], background: hoverInk)
        func helper(_ i: Int) -> PlanGlance.Helper? {
            line.glance?.helpers.first { h in if case let .agent(id, _) = pile[i].kind { return h.id == id }; return false }
        }
        guard let front = helper(2) else { throw WorkspaceAgentReportChecks.Failure(description: "hover(\(name)): orb 2 has no helper") }
        let failedIndex = (0..<pile.count).first { helper($0)?.phase == .failed }
        var said: [String] = []
        // A card above the hovered orb, in a child panel of the window, after
        // the dwell; the line's own words do not change.
        try await AgentPresenceChecks.eventually("hover(\(name)): no orb card after the dwell") { line.qaTipPanel?.isVisible == true }
        guard let panel = line.qaTipPanel, let card = line.qaTipView else { throw WorkspaceAgentReportChecks.Failure(description: "hover(\(name)): no orb card") }
        func cardSits(over i: Int) -> (NSRect, NSRect, Bool) {
            let surface = panel.frame.insetBy(dx: ChoicePanelShadowView.margin, dy: ChoicePanelShadowView.margin)
            let orb = window.convertToScreen(pile[i].convert(pile[i].bounds, to: nil))
            return (surface, orb, panel.parent === window && abs(surface.midX - orb.midX) <= 1 && surface.minY >= orb.maxY
                    && surface.minY - orb.maxY <= PlanMetrics.s(Space.m, line.zoom))
        }
        let (surface, orbOnScreen, above) = cardSits(over: 2)
        try expect(above, "hover(\(name)): the card \(surface) is not centred just above orb 2 \(orbOnScreen)")
        try expect(card.qaLines == [front.name, PlanOrbHover.stateText(front)], "hover(\(name)): the card says \(card.qaLines)")
        try expect(card.qaSymbol == PlanOrbHover.symbol(front.phase), "hover(\(name)): the card's glyph is \(card.qaSymbol ?? "none") for \(front.phase)")
        let wordsHovered = try wordsBand()
        try expect(wordsHovered == wordsAtRest, "hover(\(name)): the orb hover changed the line's words")
        _ = try fill("orb-hover")
        if let chrome = panel.contentView { try snap(chrome, "orb-card-\(name).png") }
        said.append(card.qaLines.joined(separator: " / "))
        if let f = failedIndex {
            try move(centre(f))
            let (moved, failedOrb, followed) = cardSits(over: f)
            try expect(followed && card.qaSymbol == "exclamationmark.triangle.fill",
                       "hover(\(name)): the failed orb's card has \(card.qaSymbol ?? "no glyph") at \(moved) for \(failedOrb)")
            if let chrome = panel.contentView { try snap(chrome, "orb-card-failed-\(name).png") }
            said.append("failed orb \(f) with \(card.qaSymbol ?? "-")")
        }
        // The plan open: no card over it.
        line.open()
        try expect(line.isOpen && panel.isVisible == false, "hover(\(name)): the orb card stayed up over the open plan")
        line.close()
        try await Task.sleep(for: .milliseconds(fade))

        // Leaving: the fill, the hover, the card and the cut all go back.
        try crossing(.mouseExited, NSPoint(x: line.bounds.maxX + 40, y: line.bounds.midY))
        try await Task.sleep(for: .milliseconds(fade))
        try expect(line.qaLineFillRole == nil && line.hoveredOrb == nil && pile.allSatisfy { !$0.qaIsHovered },
                   "hover(\(name)): leaving did not restore the line")
        try expect(try fill("left") == nil, "hover(\(name)): the line kept a fill after the pointer left")
        try expect(line.qaTipPanel?.isVisible != true, "hover(\(name)): the orb card outlived the hover")
        _ = try orbCut(line, appearance: appearance, still: nil)
        return "\(name): line fill the sidebar hover step then nil; orb 2 front with \(cut); shows \(said); 0 crossings over the pile; \(handed) crossings and \(movesHanded) moves handed to the line after NSApp.sendEvent"
    }
}

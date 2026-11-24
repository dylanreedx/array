import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// Sidebar dogfood fixes (0.7.53). `--sidebar-dogfood-check [dir]`.
//
// The production fixture (real delegate, supervisor and sidebar), real agents
// finished through the supervisor's own delivery path, and every control
// pressed through `NSApp.sendEvent`:
//
//  1. History rows draw A's two lines: the title, then "N helpers · Nov 10",
//     at A's height, never "N folded".
//  2. After Clear, opening History and scrolling, every History row on screen
//     is painted at full strength without a hover.
//  3. A usage item shows only while that CLI's live usage is exhausted, clears
//     itself when usage returns, offers Switch only with a second signed-in
//     account, and every Needs-you item can be dismissed until a new incident.
//  4. A finished helper whose lead record is gone draws as its own root card.
@MainActor
enum SidebarDogfoodChecks {
    nonisolated static let flag = "--sidebar-dogfood-check"
    typealias Q = QuickHideChecks
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !condition() { throw Failure(description: message()) }
    }

    static let usageWords = "You've hit your 5-hour limit · resets 1:20 AM"

    @MainActor
    struct Harness {
        let fixture: WorkspaceAPIChecks.Fixture
        let suite: QAIsolatedDefaults
        let window: NSWindow
        let sidebar: WorkspaceSidebarView
        var inbox: AgentInboxView { sidebar.inboxForQA }
        var delegate: AppDelegate { fixture.delegate }
        var supervisor: AgentSupervisor { fixture.delegate.qaAgentSupervisor }

        func spawn(_ name: String, parent: AgentID? = nil, harness: AgentHarness = .pi) -> AgentID {
            supervisor.spawn(role: nil, prompt: nil, cwd: fixture.pbRoot, harness: harness,
                             model: harness == .pi ? "openai-codex/gpt-5.6-sol" : "", thinking: "high",
                             projectId: fixture.projectPb, projectRoot: fixture.pbRoot,
                             parentAgentID: parent, displayName: name)
        }

        func finish(_ id: AgentID, failed words: String? = nil, turn: String = UUID().uuidString) {
            let thread = AgentSupervisor.threadId(for: id)
            supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: turn), to: id)
            supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: turn,
                                                outcome: words == nil ? .completed : .failed,
                                                errorMessage: words), to: id)
        }

        func refresh() {
            delegate.qaRefreshAgentSurfaces()
            inbox.layoutForQA()
        }

        /// The process's own store, put back when this harness closes.
        let inheritedAppSupport: String?
        let appSupport: URL

        func close() {
            window.orderOut(nil)
            suite.removePersistentDomain(forName: suite.suiteDomainName)
            try? FileManager.default.removeItem(at: fixture.tempRoot)
            try? FileManager.default.removeItem(at: appSupport)
            if let inheritedAppSupport { setenv("CONTINUUM_APP_SUPPORT", inheritedAppSupport, 1) } else { unsetenv("CONTINUUM_APP_SUPPORT") }
        }
    }

    static func makeHarness(_ name: String, reducedMotion: Bool = true,
                            beforeMount: ((_ delegate: AppDelegate, _ tempRoot: URL) throws -> Void)? = nil) throws -> Harness {
        Q.acceptFirstMouseEverywhere()
        guard let suite = QAIsolatedDefaults(isolatedSuiteName: "dev.arrayapp.qa.dogfood-\(name).\(UUID().uuidString)") else {
            throw Failure(description: "no isolated defaults suite")
        }
        suite.set(SidebarLayout.quietInbox.rawValue, forKey: SidebarLayout.defaultsKey)
        // Each case gets its OWN agent store. One process runs every case, and a
        // shared store let one case's agents (woken leads, failed helpers) leak
        // into the next case's sidebar.
        let inherited = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"]
        let agentStoreRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("dogfood-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: agentStoreRoot, withIntermediateDirectories: true)
        setenv("CONTINUUM_APP_SUPPORT", agentStoreRoot.path, 1)
        let fixture = try WorkspaceAPIChecks.makeFixture(settings: suite, beforeMount: beforeMount)
        let delegate = fixture.delegate
        let window = Q.KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 900),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let sidebar = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: 380, height: 900), inboxDefaults: suite)
        window.contentView = sidebar
        window.orderFrontOffscreenForChecks()
        window.makeKey()
        let appSupport = fixture.tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        try delegate.reconciledManagedSessionSource.reconcile(
            registry: try RegistryStore(applicationSupportDirectory: appSupport).loadOrEmpty(),
            reason: .continuumRestarted, now: Date())
        delegate.qaInstallWorkspaceSidebar(sidebar)
        let inbox = sidebar.inboxForQA
        inbox.pinScrollerStyleForQA()
        inbox.prefersReducedMotion = { reducedMotion }
        inbox.hoverCardEnabled = false
        inbox.setScope(.all)
        // The fixture's own source agent has never run: settle it so the list
        // is only about the agents each section makes.
        _ = delegate.qaAgentSupervisor.settle(agentID: fixture.agentId)
        // Usage pauses here are sidebar fixtures: nothing resumes mid-check.
        delegate.qaAgentSupervisor.usageAutoResumeDefault = false
        return Harness(fixture: fixture, suite: suite, window: window, sidebar: sidebar,
                       inheritedAppSupport: inherited, appSupport: agentStoreRoot)
    }

    /// Make one CLI's usage LIVE-exhausted through the supervisor's real
    /// reading path (CLI folders under `root`, no CLI probe), optionally with a
    /// second signed-in login to switch to. Legs that model "usage ran out"
    /// owe this: since the dogfood fix, old failure words alone are not a pause.
    static func makeUsageLive(_ supervisor: AgentSupervisor, harness: AgentHarness, root: URL,
                              secondLogin: Bool) throws {
        let folders = root.appendingPathComponent("cli-folders-\(UUID().uuidString)", isDirectory: true)
        supervisor.personalCodexDirectory = folders.appendingPathComponent("codex", isDirectory: true)
        supervisor.personalClaudeDirectory = folders.appendingPathComponent("claude", isDirectory: true)
        for dir in [supervisor.personalCodexDirectory.appendingPathComponent("sessions"),
                    supervisor.personalClaudeDirectory.appendingPathComponent("projects")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        supervisor.accountUsageReader = { _ in nil }
        // Accounts added below go in this check's folder, never the channel's own store.
        supervisor.qaUseAccountStore(under: folders)
        func read(_ accountId: String, org: String, used: Double) {
            supervisor.applyAccountUsageReading(
                .init(identity: AgentAccountIdentity(harness: harness, email: "\(org)@example.test",
                                                     organizationId: org, observedAt: Date()),
                      quota: AgentAccountQuotaSnapshot(
                        harness: harness,
                        windows: [AgentQuotaWindow(kind: .fiveHour, utilization: used,
                                                   resetsAt: Date().addingTimeInterval(3_600))],
                        observedAt: Date(), source: harness == .codex ? .codexRateLimitsRead : .claudeUsageRequest,
                        accountId: accountId)),
                accountId: accountId)
        }
        read(supervisor.activeAccount(for: harness).id, org: "org-in-use", used: 1.0)
        if secondLogin {
            let other = try supervisor.addAccount(harness: harness, label: supervisor.nextAccountLabel(for: harness))
            read(other.id, org: "org-other", used: 0.1)
        }
    }

    /// Press the History heading the way a person does: scrolled into view,
    /// then clicked through the window.
    static func clickHistoryHeading(_ inbox: AgentInboxView) throws {
        guard let row = inbox.historyHeaderTableRowForQA else { throw Failure(description: "no History heading") }
        inbox.scrollItemToVisibleForQA(row)
        inbox.layoutForQA()
        guard let header = inbox.historyHeaderViewForQA, header.window != nil else {
            throw Failure(description: "the History heading is not drawn after scrolling to it")
        }
        try Q.click(header)
        inbox.layoutForQA()
    }

    static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func run() throws -> String {
        // Every case runs and reports, so one red case never hides another.
        let cases: [(String, () throws -> String)] = [
            ("history-rows", checkHistoryRows), ("history-order", checkHistoryOrder),
            ("history-paints", checkHistoryPaints), ("live-usage", checkLiveUsage),
            ("orphan-root", checkOrphanRoot), ("untitled-lead", { try checkUntitledLead() }),
            ("cleared-card", checkClearedCardAcrossPush), ("runner-quota", checkRunnerQuota),
            ("switch-identity", checkSwitchNeedsDistinctLogin), ("history-dates", checkHistoryDates),
            ("history-chatter", checkHistoryChatter), ("restored-titles", checkRestoredTitlesPublishOnce),
            ("switch-shared-organization", checkSwitchSharedOrganization),
            ("history-branch-search", checkHistoryBranchSearch),
            ("usage-scope-actions", checkUsageScopeActions),
            ("family-cause-action", checkFamilyCauseAction),
            ("lead-count-fold", checkLeadCountFold),
            ("history-rename", checkHistoryRename),
            ("history-focused-helper", checkHistoryFocusedHelper),
            ("usage-project-dismissals", checkUsageProjectDismissals),
            ("history-keyboard-paint", checkHistoryKeyboardPaint),
            ("history-manual-placeholder", { try checkUntitledLead(renameToPlaceholder: true) }),
            ("history-display-title-search", checkHistoryDisplayTitleSearch),
        ]
        var reports: [String] = []
        var failures: [String] = []
        for (name, body) in cases {
            do { reports.append("PASS \(name): " + (try body())) } catch { failures.append("FAIL \(name): \(error)") }
        }
        guard failures.isEmpty else {
            throw Failure(description: (failures + reports).joined(separator: "\n"))
        }
        return "SidebarDogfoodChecks passed:\n" + reports.joined(separator: "\n")
    }

    // MARK: - 2. History rows paint without a hover

    /// The product of every alpha from the cell to the window: what the window
    /// actually composites the row at.
    static func effectiveAlpha(_ view: NSView) -> CGFloat {
        var alpha: CGFloat = 1
        var current: NSView? = view
        while let v = current {
            if v.isHidden { return 0 }
            alpha *= v.alphaValue
            current = v.superview
        }
        return alpha
    }

    static func checkHistoryPaints() throws -> String {
        let h = try makeHarness("history-paints", reducedMotion: false)
        defer { h.close() }
        let inbox = h.inbox
        func clickHistory(open: Bool) throws {
            if inbox.isHistoryExpandedForQA != open {
                try clickHistoryHeading(inbox)
                pump(0.4)
                inbox.layoutForQA()
            }
            try expect(inbox.isHistoryExpandedForQA == open, "History heading's click did not \(open ? "open" : "close") it")
        }
        // Finished agents parked in History, plus a lead and helpers to Clear.
        let returning = (0..<4).map { h.spawn("Back to work \($0 + 1)") }
        let finished = (0..<3).map { h.spawn("Finished task \($0 + 1)") }
        let lead = h.spawn("Lead with helpers")
        let helpers = (0..<2).map { h.spawn("Helper \($0 + 1)", parent: lead) }
        for id in returning + finished + [lead] + helpers { h.finish(id) }
        for id in returning { _ = h.supervisor.settle(agentID: id) }
        // One finished family stays parked in History throughout, so History
        // keeps its heading while the others work again.
        _ = h.supervisor.settle(agentID: finished[0])
        h.refresh()
        pump(0.4)
        try clickHistory(open: true)
        // Each parked agent works again while its History row is on screen: the
        // row changes shape in place (History row -> live card).
        for id in returning {
            let thread = AgentSupervisor.threadId(for: id)
            h.supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: "again-\(id.rawValue)"), to: id)
            h.delegate.qaRefreshAgentSurfaces()
            pump(0.05)
        }
        pump(0.5)
        // History shut, they finish and park again; Clear takes the rest.
        try clickHistory(open: false)
        for id in returning {
            let thread = AgentSupervisor.threadId(for: id)
            h.supervisor.qaDeliver(.turnCompleted(threadId: thread, turnId: "again-\(id.rawValue)",
                                                  outcome: .completed, errorMessage: nil), to: id)
            _ = h.supervisor.settle(agentID: id)
        }
        h.refresh()
        pump(0.4)
        let clear = Q.views(in: inbox) {
            ($0 as? SidebarSectionLabelView)?.titleForQA.hasPrefix("Inbox") == true && !$0.isHiddenOrHasHiddenAncestor
        }.first as? SidebarSectionLabelView
        if let button = clear?.clearButton, !button.isHidden {
            try Q.click(button)
            pump(0.5)
        }
        // Open History and scroll it, as Dylan did.
        try clickHistory(open: true)
        if let headerRow = inbox.historyHeaderTableRowForQA { inbox.scrollItemToTopForQA(headerRow) }
        pump(0.1)
        inbox.scrollForQA(byPoints: 80)
        pump(0.2)
        inbox.scrollForQA(byPoints: -80)
        pump(0.4)
        inbox.layoutForQA()

        // Every History row the table draws, read off the table itself.
        let items = inbox.itemsForQuietCheck
        guard let headerRow = items.firstIndex(where: { if case .historyHeader = $0 { return true }; return false }) else {
            throw Failure(description: "History heading left the list")
        }
        let table = inbox.tableForQA
        let visible = table.rows(in: table.visibleRect)
        var checked: [String] = []
        var blank: [String] = []
        for row in visible.location..<(visible.location + visible.length) where row > headerRow {
            guard case .agent(let model) = items[row] else { continue }
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) else {
                blank.append("\(model.displayTitle): no view in its row"); continue
            }
            let alpha = effectiveAlpha(cell)
            let layerOpacity = cell.layer?.opacity ?? 1
            let frame = cell.convert(cell.bounds, to: table)
            let rowRect = table.rect(ofRow: row)
            if alpha < 0.99 || layerOpacity < 0.99 || !rowRect.insetBy(dx: -0.5, dy: -0.5).contains(frame) || frame.height < 10 {
                blank.append("\(model.displayTitle): alpha \(String(format: "%.2f", alpha)), layer \(layerOpacity), frame \(frame), row \(rowRect)")
            }
            checked.append(model.displayTitle)
        }
        try expect(checked.count >= returning.count,
                   "the History rows are not on screen to check (checked \(checked), visible \(visible))")
        try expect(blank.isEmpty, "History rows drawn blank without a hover: \(blank)")
        return "History paints: \(checked.count) History rows on screen after rows changed shape, Clear, reopen and scroll, each at full strength"
    }

    // MARK: - 3. Usage items follow live usage; every Needs-you item dismisses

    static func checkLiveUsage() throws -> String {
        let h = try makeHarness("live-usage")
        defer { h.close() }
        let inbox = h.inbox
        let supervisor = h.supervisor
        // Never the real CLI folders, never a CLI probe.
        let folders = h.fixture.tempRoot.appendingPathComponent("cli-folders", isDirectory: true)
        supervisor.personalCodexDirectory = folders.appendingPathComponent("codex", isDirectory: true)
        supervisor.personalClaudeDirectory = folders.appendingPathComponent("claude", isDirectory: true)
        for dir in [supervisor.personalCodexDirectory.appendingPathComponent("sessions"),
                    supervisor.personalClaudeDirectory.appendingPathComponent("projects")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        supervisor.accountUsageReader = { _ in nil }

        func codex(_ name: String, parent: AgentID? = nil) -> AgentID {
            supervisor.spawn(role: nil, prompt: nil, cwd: h.fixture.pbRoot, harness: .codex,
                             model: "openai-codex/gpt-5.6-sol", thinking: "low",
                             projectId: h.fixture.projectPb, projectRoot: h.fixture.pbRoot,
                             parentAgentID: parent, displayName: name)
        }
        let codexWords = "You've hit your usage limit. Upgrade to Pro or try again at 3:05 PM."
        // This fixture has no CLI to run the lead: a wake with the helpers'
        // "paused for usage" report fails and retries, flipping the lead to
        // working mid-check, which takes it out of Clear. The lead's delivery
        // is witnessed by --agent-usage-resume-check; here it stays off.
        supervisor.helperCompletionEnabled = { _ in false }
        let lead = codex("Release lead")
        let paused = (0..<2).map { codex("Overnight helper \($0 + 1)", parent: lead) }
        h.finish(lead)
        for id in paused { h.finish(id, failed: codexWords) }
        h.refresh()

        func box() -> SidebarQuietNeedsYouView? {
            Q.views(in: inbox) { $0 is SidebarQuietNeedsYouView && !$0.isHiddenOrHasHiddenAncestor }.first
                as? SidebarQuietNeedsYouView
        }
        func usageLine() -> SidebarQuietNeedsYouView.Line? {
            box()?.lines.first { $0.incident?.kind == .cause(.usageLimit) }
        }
        func usageIncidents() -> [SidebarIncident] {
            inbox.sidebarIncidents.filter { $0.kind == .cause(.usageLimit) }
        }
        let active = supervisor.activeAccount(for: .codex)
        func reading(_ accountId: String, org: String, used: Double?) {
            let quota = used.map { used in
                AgentAccountQuotaSnapshot(
                    harness: .codex,
                    windows: [AgentQuotaWindow(kind: .fiveHour, utilization: used, resetsAt: Date().addingTimeInterval(3_600))],
                    observedAt: Date(), source: .codexRateLimitsRead, accountId: accountId)
            }
            supervisor.applyAccountUsageReading(
                .init(identity: AgentAccountIdentity(harness: .codex, email: "\(org)@example.test",
                                                     organizationId: org, observedAt: Date()),
                      quota: quota),
                accountId: accountId)
            inbox.layoutForQA()
        }

        // Usage-resume: each stop opened a real usage pause on its own agent.
        // Resume automatically is off here so nothing resumes mid-check.
        for id in paused { supervisor.setUsageAutoResume(false, for: id) }
        h.refresh()
        inbox.layoutForQA()
        // (a) The stop is a pause on the agent, never a Needs you item.
        guard let incident = usageIncidents().first else {
            throw Failure(description: "(a) the agents' own usage pauses draw no usage item — incidents \(inbox.sidebarIncidents.map(\.title))")
        }
        try expect(incident.title == "Waiting for Codex usage" && !incident.isBlocking && box() == nil && usageLine() == nil,
                   "(a) the pause reads '\(incident.title)', blocking \(incident.isBlocking), box \(box() != nil)")
        try expect(paused.allSatisfy { id in inbox.allRowsForQuietCheck.first { $0.id == id.rawValue }.map { SidebarRecovery.state(for: $0) == .paused } == true },
                   "(a) each stopped helper reads paused")
        // (b) A live reading changes nothing by itself: 40%, 100%, and a second
        // signed-in login all leave one item whose action is Open, never Switch.
        for (org, used) in [("org-personal", 0.4), ("org-personal", 1.0)] {
            reading(active.id, org: org, used: used)
            try expect(usageIncidents().count == 1 && box() == nil, "(b) a \(Int(used * 100))% reading moved the usage item")
        }
        let work = try supervisor.addAccount(harness: .codex, label: "Work")
        reading(work.id, org: "org-work", used: 0.1)
        try expect(usageIncidents().first?.actionTitle == "Open"
                   && !inbox.sidebarIncidents.contains { $0.actionTitle == "Switch & resume…" },
                   "(b) with a second login the sidebar still offers '\(usageIncidents().first?.actionTitle ?? "nil")', never Switch & resume…")
        // (c) Open reveals a paused agent through the host.
        _ = h.delegate.performSidebarIncident(usageIncidents()[0])
        try expect(h.delegate.lastSidebarIncidentOutcomeForQA == .revealedAgent(lead.rawValue)
                       || paused.contains { h.delegate.lastSidebarIncidentOutcomeForQA == .revealedAgent($0.rawValue) },
                   "(c) Open reveals the paused agent — got \(h.delegate.lastSidebarIncidentOutcomeForQA)")
        inbox.scrollToTopForQA()
        Q.photograph(h.sidebar, "dogfood-usage-pause")
        // (d) The pauses end (reset, success or probe): the item clears itself.
        for id in paused { supervisor.qaSetUsagePause(nil, for: id) }
        // No wait: the push that ending a pause schedules may land after the
        // click below. A Clear must win over any push carrying older state.
        inbox.layoutForQA()
        try expect(usageIncidents().isEmpty && box() == nil,
                   "(d) the pauses ended but the item stays — incidents \(inbox.sidebarIncidents.map(\.title))")
        // Cleared stays cleared when usage later reads 100%: old words without a
        // pause are never one, so the old stop must not bring the family back.
        guard let clear = (Q.views(in: inbox) {
            ($0 as? SidebarSectionLabelView)?.titleForQA.hasPrefix("Inbox") == true && !$0.isHiddenOrHasHiddenAncestor
        }.first as? SidebarSectionLabelView)?.clearButton, !clear.isHidden,
              inbox.sidebarClearIDs.contains(lead.rawValue) else {
            throw Failure(description: "with the pauses over, the family is not offered to Clear — Clear \(inbox.sidebarClearIDs.count)")
        }
        let clearIDsBefore = inbox.sidebarClearIDs.count
        // Ending the pauses removes the usage item above the Inbox heading, and the
        // list's scroll anchor holds the agent rows in place by scrolling the heading
        // (and its Clear button) 30pt off the top. A person scrolls back up to press
        // it; so does the arm, rather than clicking a button that is not on screen.
        inbox.scrollToTopForQA()
        inbox.layoutForQA()
        try Q.click(clear)
        inbox.layoutForQA()
        let clickedMarks = inbox.clearMarks.keys.contains(lead.rawValue)
        // The pause-end push, and another, land after the Clear.
        pump(0.3)
        h.refresh()
        inbox.layoutForQA()
        func drawnLive() -> Bool {
            inbox.itemsForQuietCheck.contains { $0.agentRow?.id == lead.rawValue && $0.agentRow?.isCleared == false }
        }
        try expect(!drawnLive(), "Clear left the family in the live list (click marked lead \(clickedMarks), marks now \(inbox.clearMarks.keys.contains(lead.rawValue)), toast '\(inbox.undoToastTextForQA)', clear ids before \(clearIDsBefore)) — rows \(inbox.allRowsForQuietCheck.filter { $0.id == lead.rawValue || $0.parentId == lead.rawValue }.map { "\($0.displayTitle):\($0.state):\(SidebarRecovery.state(for: $0)):cause=\(String(describing: SidebarRecovery.cause(for: $0))):blocked=\($0.settlementBlocked):cleared=\($0.isCleared):active=\($0.lastActiveAt.map { "\($0.timeIntervalSinceNow)" } ?? "-"):ended=\($0.terminalEvent.map { "\($0.outcome)@\($0.endedAt.timeIntervalSinceNow)" } ?? "-")" }), pauses \(supervisor.usagePauses.count)")
        reading(active.id, org: "org-personal", used: 1.0)
        try expect(!drawnLive() && usageIncidents().isEmpty,
                   "usage reading 100% again brought a cleared family back (live \(drawnLive()), item \(!usageIncidents().isEmpty))")
        return "Usage pauses: a stop pauses its own agent ('Waiting for Codex usage', never Needs you); 40%/100% readings and a second login change nothing and never offer Switch & resume…; Open reveals the agent; the pauses ending clears the item; Clear clicked with no wait stayed cleared through the pushes that landed after it, and at 100%"
    }

    // MARK: - 4. An orphan whose lead is gone is its own root card

    static func checkOrphanRoot() throws -> String {
        let h = try makeHarness("orphan-root")
        defer { h.close() }
        let inbox = h.inbox
        let lead = h.spawn("Measure performance at scale")
        let orphan = h.spawn("Measure and archive cold agent residency", parent: lead)
        h.finish(lead)
        h.finish(orphan, failed: "Tests failed: 3 of 40 in ResidencyChecks")
        h.refresh()
        // The lead record goes (Delete), its failed helper stays unopened.
        _ = h.supervisor.archive(lead)
        h.refresh()
        try expect(h.supervisor.records[lead] == nil && h.supervisor.records[orphan] != nil,
                   "fixture: the lead's record must be gone and the helper's kept")
        let drawn = inbox.itemsForQuietCheck.compactMap(\.agentRow).first { $0.id == orphan.rawValue }
        guard let row = drawn else {
            throw Failure(description: "the orphan failure is not drawn at all — rows \(inbox.itemsForQuietCheck.compactMap(\.agentRow).map(\.displayTitle))")
        }
        try expect(row.parentId == nil && row.depth == 0,
                   "the orphan failure draws under an absent lead (parent \(row.parentId?.uuidString ?? "nil"), depth \(row.depth)) — a loose strip")
        guard let index = inbox.itemsForQuietCheck.firstIndex(where: { $0.agentRow?.id == orphan.rawValue }),
              let cell = inbox.tableForQA.view(atColumn: 0, row: index, makeIfNecessary: true) as? AgentInbox96CellView else {
            throw Failure(description: "the orphan failure has no card cell")
        }
        try expect(!cell.isSubagentRow, "the orphan failure draws as a helper strip, not a lead card")
        return "Orphan root: '\(row.displayTitle)' with its lead deleted draws as its own root card (depth 0, no parent)"
    }

    // MARK: - 1b. History is newest first by the last REAL turn

    /// Restored records, the shape found in Dylan's store: a relaunch stamps
    /// every helper's activity, run-completed and terminal times with "now",
    /// while its real turns are days old. Restored records emit no helper
    /// results, so no lead wakes and the order is deterministic.
    static func checkHistoryOrder() throws -> String {
        let now = Date()
        func days(_ n: Double) -> Date { now.addingTimeInterval(-n * 86_400) }
        var titles: [AgentID: String] = [:]
        var unusedID: AgentID?
        let h = try makeHarness("history-order") { delegate, _ in
            guard let peer = delegate.qaAgentSupervisor.records.values.first else {
                throw Failure(description: "fixture agent missing")
            }
            let store = AgentStore(smokeTest: false)
            func put(_ title: String, parent: AgentID? = nil, turn: Date, stamp: Date? = nil) throws -> AgentID {
                let id = AgentID(rawValue: UUID())
                let touched = stamp ?? turn.addingTimeInterval(60)
                var record = AgentRecord(
                    id: id, displayName: title, model: peer.model, thinking: peer.thinking, cwd: peer.cwd,
                    projectId: peer.projectId, parentAgentID: parent,
                    createdAt: turn.addingTimeInterval(-60), lastActivityAt: touched, latestPromptAt: parent == nil ? turn : nil,
                    latestTurnAt: turn,
                    latestTerminalEvent: AgentTerminalEvent(sequence: 1, turnID: "t", outcome: .succeeded, endedAt: touched),
                    archivedAt: max(touched, turn.addingTimeInterval(120)))
                record.runCompletedAt = touched
                record.acknowledgedTerminalSequence = 1
                try store.upsert(record)
                titles[id] = title
                return id
            }
            // Real turns 5 days ago; a relaunch stamped its helpers "now".
            let stamped = try put("Restart-stamped family", turn: days(5))
            for n in 1...2 { _ = try put("Stamped helper \(n)", parent: stamped, turn: days(5), stamp: now) }
            // Lead 3 days ago, its helper really worked 1 day ago.
            let lifted = try put("Helper worked later", turn: days(3))
            _ = try put("Late helper", parent: lifted, turn: days(1))
            _ = try put("Recent lead", turn: days(2))
            for n in 1...10 { _ = try put("Older family \(n)", turn: days(Double(10 + n))) }
            // Opened and never used: no prompt, no turn, no outcome, closed.
            var unused = AgentRecord(
                id: AgentID(rawValue: UUID()), displayName: AgentRecord.defaultAgentName, displayNameSource: .sentinel,
                model: peer.model, thinking: peer.thinking, cwd: peer.cwd, projectId: peer.projectId,
                createdAt: now.addingTimeInterval(-600), lastActivityAt: now.addingTimeInterval(-600),
                archivedAt: now.addingTimeInterval(-300))
            unused.acknowledgedTerminalSequence = 0
            try store.upsert(unused)
            unusedID = unused.id
        }
        defer { h.close() }
        let inbox = h.inbox
        h.refresh()
        if !inbox.isHistoryExpandedForQA { _ = inbox.clickHistoryDisclosureForQA() }
        inbox.layoutForQA()
        try expect(inbox.isHistoryExpandedForQA, "History did not open")
        let table = inbox.tableForQA
        func cards() -> [(title: String, at: Date?)] {
            inbox.itemsForQuietCheck.indices.compactMap { row -> (String, Date?)? in
                guard let entry = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarQuietHistoryEntryView
                else { return nil }
                return (entry.titleForQA, entry.shownDate)
            }
        }
        func nonIncreasing(_ order: [(title: String, at: Date?)]) -> Bool {
            zip(order, order.dropFirst()).allSatisfy { ($0.at ?? .distantPast) >= ($1.at ?? .distantPast) }
        }
        func describe(_ order: [(title: String, at: Date?)]) -> String {
            order.map { "\($0.title) \($0.at.map { String(format: "%.1fd", now.timeIntervalSince($0) / 86_400) } ?? "-")" }.joined(separator: ", ")
        }
        // Agents opened and never used (the restored one and the fixture's own
        // source agent) are not History: nothing happened there.
        let page = cards()
        try expect(!page.contains { $0.title == AgentName.defaultName },
                   "an agent opened and never used is drawn in History: \(describe(page))")
        let families = page
        try expect(Array(families.prefix(3).map(\.title)) == ["Helper worked later", "Recent lead", "Restart-stamped family"]
                   && nonIncreasing(page),
                   "History is not newest first by last real turn: \(describe(page))")
        guard let stampedAt = page.first(where: { $0.title == "Restart-stamped family" })?.at,
              abs(stampedAt.timeIntervalSince(days(5))) < 1 else {
            throw Failure(description: "a relaunch's stamps moved the family's date: \(describe(page))")
        }
        guard let liftedAt = families.first?.at, abs(liftedAt.timeIntervalSince(days(1))) < 1 else {
            throw Failure(description: "a helper's later real turn is not its family's date: \(describe(page))")
        }
        guard let more = Q.views(in: inbox, where: { $0 is AgentInboxSettledMoreView && !$0.isHiddenOrHasHiddenAncestor }).first else {
            throw Failure(description: "no Show more under History (\(page.count) cards)")
        }
        try Q.click(more)
        inbox.layoutForQA()
        let all = cards()
        try expect(nonIncreasing(all) && all.count >= 13,
                   "after Show more, History is not newest first: \(describe(all))")
        try expect(!all.contains { $0.title == AgentName.defaultName }, "after Show more, an unused agent is in History")
        // Search still finds it.
        inbox.setSearchForQA("New agent")
        inbox.layoutForQA()
        try expect(unusedID.map { id in inbox.rowIdsForQA.contains(id.rawValue) } == true,
                   "Search no longer finds an agent opened and never used")
        inbox.setSearchForQA("")
        inbox.layoutForQA()
        return "History order: unused agents left out (Search finds them); newest first by last real turn across Show more (\(all.count) cards): \(describe(Array(all.prefix(3)))); relaunch stamps on helpers did not move a family"
    }

    // MARK: - 5. An untitled, prompted lead reads as its first prompt

    static func checkUntitledLead(renameToPlaceholder: Bool = false) throws -> String {
        let untitled = AgentID(rawValue: UUID())
        let prompt = "You are working in the Array repository at: /Users/someone/Array\n\n**Fix** the flaky `login` test on CI"
        let h = try makeHarness("untitled-lead") { delegate, _ in
            // A restored lead that was prompted but never named, closed to History.
            let ended = Date().addingTimeInterval(-3_600)
            guard let peer = delegate.qaAgentSupervisor.records.values.first else {
                throw Failure(description: "fixture agent missing")
            }
            let record = AgentRecord(
                id: untitled, displayName: AgentRecord.defaultAgentName, displayNameSource: .sentinel,
                model: peer.model, thinking: peer.thinking, cwd: peer.cwd, projectId: peer.projectId,
                createdAt: ended.addingTimeInterval(-60), lastActivityAt: ended, latestPromptAt: ended.addingTimeInterval(-50),
                latestTerminalEvent: AgentTerminalEvent(sequence: 1, turnID: "t", outcome: .succeeded, endedAt: ended),
                settledOverride: renameToPlaceholder ? .settled : .default,
                settledAt: renameToPlaceholder ? ended : nil,
                archivedAt: renameToPlaceholder ? nil : ended)
            try AgentStore(smokeTest: false).upsert(record)
            var projection = AgentTranscriptProjection(threadId: "untitled")
            projection.appendUserPrompt(prompt)
            let transcripts = AgentTranscriptStore(root: RegistryStore.defaultApplicationSupportDirectory()
                .appendingPathComponent("agent-transcripts", isDirectory: true))
            var saved = false
            Task { @MainActor in
                try? await transcripts.saveSnapshot(agentID: untitled,
                    sessionID: AgentTranscriptStore.canonicalSessionID(for: untitled), document: projection.document)
                saved = true
            }
            while !saved { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        defer { h.close() }
        let inbox = h.inbox
        h.refresh()
        guard let header = inbox.historyHeaderViewForQA else { throw Failure(description: "no History heading") }
        _ = header
        if !inbox.isHistoryExpandedForQA { _ = inbox.clickHistoryDisclosureForQA() }
        inbox.layoutForQA()
        try expect(inbox.isHistoryExpandedForQA, "History did not open")
        func card() -> SidebarQuietHistoryEntryView? {
            guard let row = inbox.itemsForQuietCheck.firstIndex(where: { $0.agentRow?.id == untitled.rawValue }) else { return nil }
            return inbox.tableForQA.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarQuietHistoryEntryView
        }
        // The transcript is read off the main thread; the sidebar re-pushes when it lands.
        let deadline = Date().addingTimeInterval(10)
        let expected = "Fix the flaky login test on CI"
        while card()?.titleForQA != expected, Date() < deadline {
            pump(0.05)
            inbox.layoutForQA()
        }
        try expect(card()?.titleForQA == expected,
                   "an untitled, prompted History lead reads '\(card()?.titleForQA ?? "no card")', wanted its prompt line '\(expected)' (record \(h.supervisor.records[untitled] != nil), pushed \(inbox.pushedRowForQA(id: untitled.rawValue).map { "\($0.displayTitle) \($0.lifecycle)" } ?? "nil"), History \(inbox.historyHeaderTitleForQA ?? "nil"))")
        if renameToPlaceholder {
            guard let original = card(), original.window === h.window else {
                throw Failure(description: "fixture: the prompted History card is not mounted")
            }
            inbox.presentsPopoversOffscreenForQA = true
            try Q.rightClick(original)
            let name = AgentRecord.defaultAgentName
            try expect(inbox.pickRowMenuItemForQA(.rename) && inbox.typeRenameForQA(name)
                       && inbox.pressKeyInRenameForQA(#selector(NSResponder.insertNewline(_:))),
                       "fixture: could not commit the rename through the History card")
            let stored = try AgentStore(smokeTest: false).load(id: untitled)
            try expect(stored?.displayName == name && stored?.displayNameSource == .manual,
                       "the shared editor did not persist the manual name")
            inbox.layoutForQA()
            try expect(card()?.titleForQA == name,
                       "the settled card painted '\(card()?.titleForQA ?? "no card")' after persisting the manual name '\(name)'")
            return "History painted the persisted manual New agent name after previously showing the first-prompt fallback."
        }
        return "Untitled lead: a restored, prompted lead with no title draws its first prompt line '\(expected)' in History, not 'New agent'"
    }

    // MARK: - 1. History rows read like A

    static func checkHistoryRows() throws -> String {
        let h = try makeHarness("history-rows")
        defer { h.close() }
        let inbox = h.inbox
        let lead = h.spawn("Conduct overnight UX checks")
        let helpers = (0..<4).map { h.spawn("Overnight helper \($0 + 1)", parent: lead) }
        let solo = h.spawn("Draft the release notes")
        // More families than one History page holds, each with helpers.
        var extra: [AgentID] = []
        for index in 0..<InboxSort.settledPageSize {
            let family = h.spawn("Older family \(index + 1)")
            extra.append(family)
            extra.append(contentsOf: (0..<2).map { h.spawn("Older helper \(index + 1).\($0 + 1)", parent: family) })
        }
        for id in extra { h.finish(id) }
        for id in [lead, solo] + helpers { h.finish(id) }
        h.refresh()
        // Clear through the drawn control: both families go to History.
        guard let clear = (Q.views(in: inbox) {
            ($0 as? SidebarSectionLabelView)?.titleForQA.hasPrefix("Inbox") == true && !$0.isHiddenOrHasHiddenAncestor
        }.first as? SidebarSectionLabelView)?.clearButton, !clear.isHidden else {
            throw Failure(description: "no Clear to press")
        }
        try Q.click(clear)
        inbox.layoutForQA()
        try clickHistoryHeading(inbox)
        inbox.layoutForQA()
        try expect(inbox.isHistoryExpandedForQA, "History did not open")
        Q.photograph(h.sidebar, "dogfood-history")

        let table = inbox.tableForQA
        let items = inbox.itemsForQuietCheck
        guard let headerRow = items.firstIndex(where: { if case .historyHeader = $0 { return true }; return false }) else {
            throw Failure(description: "History heading left the list")
        }
        var drawn: [UUID: SidebarQuietHistoryEntryView] = [:]
        var other: [String] = []
        for row in (headerRow + 1)..<items.count {
            guard case .agent(let model) = items[row] else {
                if case .fanoutRemainder = items[row] { other.append("fold line under History") }
                continue
            }
            let view = table.view(atColumn: 0, row: row, makeIfNecessary: true)
            if let entry = view as? SidebarQuietHistoryEntryView {
                drawn[model.id] = entry
                try expect(abs(table.rect(ofRow: row).height - table.intercellSpacing.height - SidebarQuietHistoryEntryView.height) < 0.5,
                           "History row '\(model.displayTitle)' is \(table.rect(ofRow: row).height)pt, wanted A's \(SidebarQuietHistoryEntryView.height)")
            } else {
                other.append("\(model.displayTitle) as \(type(of: view))")
            }
        }
        try expect(other.isEmpty, "History draws something other than one card per family: \(other)")
        let pageCards = drawn.count
        drawn[h.fixture.agentId.rawValue] = nil  // the fixture's own parked source agent
        // Families total: 2 + the older ones (the fixture's never-run source
        // agent is not History: nothing happened there); a page of
        // `settledPageSize` cards, and the footer counts the families left.
        let families = 2 + InboxSort.settledPageSize
        try expect(pageCards == InboxSort.settledPageSize,
                   "History's first page shows \(pageCards) cards, wanted \(InboxSort.settledPageSize) families — helpers took page slots")
        let footer = items.compactMap { item -> Int? in if case .settledMore(let hidden) = item { return hidden }; return nil }.first
        try expect(footer == families - InboxSort.settledPageSize,
                   "the History footer hides \(footer.map(String.init) ?? "nil"), wanted \(families - InboxSort.settledPageSize) families (no helpers)")
        try expect(drawn.keys.contains(lead.rawValue) && drawn.keys.contains(solo.rawValue),
                   "History holds the newest families as cards, helpers inside their lead — got \(drawn.values.map(\.titleForQA))")
        try expect(inbox.historyHeaderTitleForQA == "History (\(families))",
                   "the History heading counts families (\(families)), not helpers — got '\(inbox.historyHeaderTitleForQA ?? "nil")'")
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        let today = formatter.string(from: Date())
        let leadCard = drawn[lead.rawValue]!, soloCard = drawn[solo.rawValue]!
        try expect(leadCard.titleForQA == "Conduct overnight UX checks" && leadCard.detailForQA == "4 helpers · \(today)",
                   "the lead's History card reads '\(leadCard.titleForQA)' / '\(leadCard.detailForQA)', wanted A's title / '4 helpers · \(today)'")
        try expect(soloCard.detailForQA == today, "a family with no helpers reads its date only — got '\(soloCard.detailForQA)'")
        for card in [leadCard, soloCard] {
            try expect(!card.detailForQA.contains("folded"), "a History card says 'folded': \(card.detailForQA)")
            let t = card.titleFrameForQA, d = card.detailFrameForQA, c = card.cardFrameForQA
            try expect(t.maxY <= d.minY + 0.5 && c.contains(t) && c.contains(d) && t.height >= 14 && d.height >= 12,
                       "History card lines overlap or leave the card: title \(t), detail \(d), card \(c)")
            try expect(c.height >= 50 && c.height <= 58, "History card is \(c.height)pt tall, wanted A's ~54")
        }
        return "History rows: one card per family at \(SidebarQuietHistoryEntryView.height)pt; '\(leadCard.titleForQA)' / '\(leadCard.detailForQA)', solo '\(soloCard.detailForQA)'; helpers stay inside their lead"
    }

    // MARK: - Shared fixtures for the review-round witnesses

    /// Never the real CLI folders, never a CLI probe.
    static func isolateAccounts(_ supervisor: AgentSupervisor, root: URL) throws {
        let folders = root.appendingPathComponent("cli-folders-\(UUID().uuidString)", isDirectory: true)
        supervisor.personalCodexDirectory = folders.appendingPathComponent("codex", isDirectory: true)
        supervisor.personalClaudeDirectory = folders.appendingPathComponent("claude", isDirectory: true)
        for dir in [supervisor.personalCodexDirectory.appendingPathComponent("sessions"),
                    supervisor.personalClaudeDirectory.appendingPathComponent("projects")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        supervisor.accountUsageReader = { _ in nil }
    }

    static func codexAgent(_ h: Harness, _ name: String, parent: AgentID? = nil) -> AgentID {
        h.supervisor.spawn(role: nil, prompt: nil, cwd: h.fixture.pbRoot, harness: .codex,
                           model: "openai-codex/gpt-5.6-sol", thinking: "low",
                           projectId: h.fixture.projectPb, projectRoot: h.fixture.pbRoot,
                           parentAgentID: parent, displayName: name)
    }

    static let codexUsageWords = "You've hit your usage limit. Upgrade to Pro or try again at 3:05 PM."

    static func usageLine(_ inbox: AgentInboxView) -> SidebarQuietNeedsYouView.Line? {
        (Q.views(in: inbox) { $0 is SidebarQuietNeedsYouView && !$0.isHiddenOrHasHiddenAncestor }.first
            as? SidebarQuietNeedsYouView)?.lines.first { $0.incident?.kind == .cause(.usageLimit) }
    }

    /// What is wrong with the view drawing `id`'s row, or nil when it sits in
    /// its own table row at full strength.
    static func rowViewProblem(_ inbox: AgentInboxView, _ id: UUID) -> String? {
        guard let row = inbox.itemsForQuietCheck.firstIndex(where: { $0.agentRow?.id == id }) else {
            return "not in the list"
        }
        let table = inbox.tableForQA
        inbox.scrollItemToVisibleForQA(row)
        inbox.layoutForQA()
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) else { return "no view in its row" }
        if let rowView = table.rowView(atRow: row, makeIfNecessary: false), cell.superview !== rowView {
            return "its view left its row (parent \(cell.superview.map { String(describing: type(of: $0)) } ?? "none"))"
        }
        if cell.window == nil { return "its view is not in the window" }
        let alpha = effectiveAlpha(cell)
        if alpha < 0.99 { return "drawn at alpha \(String(format: "%.2f", alpha))" }
        return nil
    }

    // MARK: - 6. A cleared History card survives unrelated pushes and reversals

    static func checkClearedCardAcrossPush() throws -> String {
        let h = try makeHarness("cleared-card", reducedMotion: false)
        defer { h.close() }
        let inbox = h.inbox
        // No helpers: their results would wake the lead into a turn this fixture
        // has no runner for, and an unopened failure is never cleared.
        let lead = h.spawn("Cleared lead")
        let bystander = h.spawn("Bystander")
        let reversing = h.spawn("Back and forth")
        for id in [lead, bystander, reversing] { h.finish(id) }
        _ = h.supervisor.settle(agentID: reversing)
        h.refresh()
        pump(0.4)
        guard let clear = (Q.views(in: inbox) {
            ($0 as? SidebarSectionLabelView)?.titleForQA.hasPrefix("Inbox") == true && !$0.isHiddenOrHasHiddenAncestor
        }.first as? SidebarSectionLabelView)?.clearButton, !clear.isHidden else {
            let labels = Q.views(in: inbox) { $0 is SidebarSectionLabelView }.compactMap { ($0 as? SidebarSectionLabelView)?.titleForQA }
            let refusals = inbox.allRowsForQuietCheck.map { "\($0.displayTitle): \(String(describing: SidebarClear.refusal(for: $0, standing: [])))" }
            throw Failure(description: "no Clear to press — labels \(labels), Clear ids \(inbox.sidebarClearIDs.count), refusals \(refusals)")
        }
        try Q.click(clear)
        pump(0.4)
        if !inbox.isHistoryExpandedForQA { try clickHistoryHeading(inbox); pump(0.4) }
        try expect(inbox.isHistoryExpandedForQA, "History did not open")
        try expect(inbox.pushedRowForQA(id: lead.rawValue)?.lifecycle == .active
                   && inbox.itemsForQuietCheck.contains { $0.agentRow?.id == lead.rawValue && $0.agentRow?.isCleared == true },
                   "fixture: the lead must be cleared (raw active, drawn settled in History) — raw \(String(describing: inbox.pushedRowForQA(id: lead.rawValue).map { "\($0.lifecycle) \($0.state)" })), drawn \(inbox.itemsForQuietCheck.compactMap(\.agentRow).filter { $0.id == lead.rawValue }.map { "\($0.lifecycle) cleared \($0.isCleared)" })")
        if let problem = rowViewProblem(inbox, lead.rawValue) {
            throw Failure(description: "fixture: the cleared card is already wrong before any push: \(problem)")
        }

        // (a) Unrelated pushes: the bystander works and chatters. The cleared
        // card's raw row stays active while it is drawn settled; nothing about it
        // changed, so nothing about it may fade.
        let thread = AgentSupervisor.threadId(for: bystander)
        h.supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: "busy"), to: bystander)
        h.delegate.qaRefreshAgentSurfaces()
        try expect(inbox.crossfadeGhostFrameForQA(id: lead.rawValue) == nil,
                   "(a) an unrelated push lifted the cleared card as a crossfade ghost")
        for step in 0..<4 {
            h.supervisor.qaDeliver(.itemStarted(threadId: thread, itemId: "s\(step)", kind: .commandExecution,
                                                title: "rg needle"), to: bystander)
            h.delegate.qaRefreshAgentSurfaces()
            pump(0.05)
            try expect(inbox.crossfadeGhostFrameForQA(id: lead.rawValue) == nil,
                       "(a) push \(step + 2) lifted the cleared card as a crossfade ghost")
        }
        pump(0.5)
        if let problem = rowViewProblem(inbox, lead.rawValue) {
            throw Failure(description: "(a) after unrelated pushes the cleared History card is \(problem)")
        }

        // (b) Rapid reversal: a History card works, settles, works and settles
        // again faster than one crossfade. The live cell can be lent back while
        // each parked card must be drawn in its own row at full strength.
        let table = inbox.tableForQA
        func reversingCell() -> NSView? {
            guard let row = inbox.itemsForQuietCheck.firstIndex(where: { $0.agentRow?.id == reversing.rawValue }) else {
                return nil
            }
            return table.view(atColumn: 0, row: row, makeIfNecessary: false)
        }
        var previousLiveCell: NSView?
        let back = AgentSupervisor.threadId(for: reversing)
        for round in 0..<3 {
            guard let outgoing = reversingCell() as? SidebarQuietHistoryEntryView else {
                throw Failure(description: "(b) reversal \(round + 1): the outgoing History card is not mounted")
            }
            h.supervisor.qaDeliver(.turnStarted(threadId: back, turnId: "r\(round)"), to: reversing)
            h.delegate.qaRefreshAgentSurfaces()
            try expect(inbox.crossfadeGhostFrameForQA(id: reversing.rawValue) != nil && outgoing.superview === table,
                       "(b) reversal \(round + 1): the History-to-live fade did not start")
            guard let liveCell = reversingCell(), liveCell !== outgoing else {
                throw Failure(description: "(b) reversal \(round + 1): the live cell did not arrive")
            }
            if let previousLiveCell {
                try expect(liveCell === previousLiveCell, "(b) reversal \(round + 1): the live cell was not reused")
            }
            previousLiveCell = liveCell
            pump(0.03)
            h.supervisor.qaDeliver(.turnCompleted(threadId: back, turnId: "r\(round)", outcome: .completed,
                                                  errorMessage: nil), to: reversing)
            _ = h.supervisor.settle(agentID: reversing)
            try expect(inbox.crossfadeGhostFrameForQA(id: reversing.rawValue) != nil,
                       "(b) reversal \(round + 1): the original fade ended before the return to History")
            h.delegate.qaRefreshAgentSurfaces()
            try expect(reversingCell() is SidebarQuietHistoryEntryView,
                       "(b) reversal \(round + 1): the new History card did not arrive")
            try expect(outgoing.superview == nil && outgoing.alphaValue == 1,
                       "(b) reversal \(round + 1): the outgoing History ghost was not retired at full strength")
            pump(0.03)
        }
        pump(0.6)
        var problems: [String] = []
        for id in [reversing, lead] {
            if let problem = rowViewProblem(inbox, id.rawValue) {
                problems.append("\(inbox.pushedRowForQA(id: id.rawValue)?.displayTitle ?? "?"): \(problem)")
            }
        }
        try expect(problems.isEmpty, "(b) after a rapid reversal: \(problems)")
        try expect(inbox.crossfadingRowCountForQA == 0, "(b) \(inbox.crossfadingRowCountForQA) ghosts still held after every fade ended")
        return "Cleared card: 5 unrelated pushes lifted no ghost and left the cleared History card in its row at full strength; 3 rapid reversals started real fades, reused the live cell, and left both History cards in their rows, opaque, with no ghosts held"
    }

    // MARK: - 7. A usage pause's entry and exit announce; runner readings alone are quiet

    static func checkRunnerQuota() throws -> String {
        let h = try makeHarness("runner-quota")
        defer { h.close() }
        let inbox = h.inbox
        let supervisor = h.supervisor
        try isolateAccounts(supervisor, root: h.fixture.tempRoot)
        let lead = codexAgent(h, "Quota lead")
        let paused = (0..<2).map { codexAgent(h, "Quota helper \($0 + 1)", parent: lead) }
        h.finish(lead)
        for id in paused { h.finish(id, failed: codexUsageWords) }
        h.refresh()
        var announcements: [String] = []
        inbox.accessibilityAnnouncementSink = { _, message in announcements.append(message) }
        let active = supervisor.activeAccount(for: .codex)
        let runnerAccount = supervisor.account(forAgent: lead)?.id ?? AgentAccount.defaultAccountId(for: .codex)
        try expect(runnerAccount == active.id, "fixture: the runner's account \(runnerAccount) is not the one in use \(active.id)")
        // A probe read the login with usage available: nothing needs you.
        supervisor.applyAccountUsageReading(
            .init(identity: AgentAccountIdentity(harness: .codex, email: "me@example.test",
                                                 organizationId: "org-personal", observedAt: Date()),
                  quota: AgentAccountQuotaSnapshot(
                    harness: .codex,
                    windows: [AgentQuotaWindow(kind: .fiveHour, utilization: 0.4, resetsAt: Date().addingTimeInterval(3_600))],
                    observedAt: Date(), source: .codexRateLimitsRead, accountId: active.id)),
            accountId: active.id)
        inbox.layoutForQA()
        // Each stop opened the helper's own pause (Resume automatically off here).
        for id in paused { supervisor.setUsageAutoResume(false, for: id) }
        inbox.layoutForQA()
        try expect(usageLine(inbox) == nil, "fixture: a usage pause drew a Needs you line")

        let pausedLabel = SidebarFailureCause.usageLimit.label(harness: "codex")
        func announced(since start: Int) -> [String] { Array(announcements.dropFirst(start)) }
        /// The runner's own `.accountQuota` observation, as a live codex turn hands it over.
        func runner(_ used: Double, resetsIn: TimeInterval = 3_600) {
            supervisor.qaObserveSharedTranscript(.accountQuota(AgentAccountQuotaSnapshot(
                harness: .codex,
                windows: [AgentQuotaWindow(kind: .fiveHour, utilization: used, resetsAt: Date().addingTimeInterval(resetsIn))],
                observedAt: Date(), source: .codexAccountRateLimits)), for: lead)
            inbox.layoutForQA()
        }

        func rowState(_ id: AgentID) -> SidebarTallyState? {
            inbox.allRowsForQuietCheck.first { $0.id == id.rawValue }.map(SidebarRecovery.state(for:))
        }
        try expect(paused.allSatisfy { rowState($0) == .paused }, "fixture: the stopped helpers read paused")
        // Exit: the pauses end (a reset, a later success, a reading under 99%).
        var mark = announcements.count
        for id in paused { supervisor.qaSetUsagePause(nil, for: id) }
        inbox.layoutForQA()
        let recovered = announced(since: mark)
        try expect(paused.allSatisfy { rowState($0) != .paused }
                   && recovered.contains { $0.hasPrefix("Quota helper 1: ") && !$0.hasSuffix(pausedLabel) },
                   "exit: MAC-15 did not announce the helper leaving '\(pausedLabel)' — \(recovered)")
        // Quiet: the runner reports the window spent, again and again. A reading
        // never makes a pause on its own, and never rebuilds the rows.
        mark = announcements.count
        let buildsBefore = h.delegate.qaInboxRowBuildCount
        runner(1.0)
        runner(1.0)
        runner(0.2)
        try expect(announced(since: mark).isEmpty && paused.allSatisfy { rowState($0) != .paused },
                   "quiet: a runner reading moved a row — \(announced(since: mark))")
        try expect(h.delegate.qaInboxRowBuildCount == buildsBefore,
                   "quiet: runner readings rebuilt the sidebar rows \(h.delegate.qaInboxRowBuildCount - buildsBefore) times")
        // Entry: a helper's own turn stops on usage again.
        mark = announcements.count
        h.finish(paused[0], failed: codexUsageWords)
        supervisor.setUsageAutoResume(false, for: paused[0])
        h.refresh()
        inbox.layoutForQA()
        let entered = announced(since: mark)
        try expect(rowState(paused[0]) == .paused && usageLine(inbox) == nil
                   && entered.contains { $0.hasPrefix("Quota helper 1: ") && $0.hasSuffix(pausedLabel) },
                   "entry: MAC-15 did not announce '\(pausedLabel)' for the stopped helper — \(entered)")
        return "Usage pause announcements: the pauses ending announced recovery; three runner readings (100%, 100%, 20%) moved no row, announced nothing and rebuilt 0 rows; a new stop paused its own helper, announced '\(pausedLabel)', and drew no Needs you line"
    }

    // MARK: - 8. Switch needs evidence of a different login

    static func checkSwitchNeedsDistinctLogin() throws -> String {
        let h = try makeHarness("switch-identity")
        defer { h.close() }
        let inbox = h.inbox
        let supervisor = h.supervisor
        try isolateAccounts(supervisor, root: h.fixture.tempRoot)
        let lead = codexAgent(h, "Identity lead")
        let helper = codexAgent(h, "Identity helper", parent: lead)
        h.finish(lead)
        h.finish(helper, failed: codexUsageWords)
        h.refresh()
        func reading(_ accountId: String, email: String?, org: String?, used: Double) {
            supervisor.applyAccountUsageReading(
                .init(identity: AgentAccountIdentity(harness: .codex, email: email, organizationId: org, observedAt: Date()),
                      quota: AgentAccountQuotaSnapshot(
                        harness: .codex,
                        windows: [AgentQuotaWindow(kind: .fiveHour, utilization: used, resetsAt: Date().addingTimeInterval(3_600))],
                        observedAt: Date(), source: .codexRateLimitsRead, accountId: accountId)),
                accountId: accountId)
            inbox.layoutForQA()
        }
        func action() -> String {
            inbox.sidebarIncidents.first { $0.kind == .cause(.usageLimit) }?.actionTitle ?? "no item"
        }
        supervisor.setUsageAutoResume(false, for: helper)
        let active = supervisor.activeAccount(for: .codex)
        reading(active.id, email: "me@example.test", org: nil, used: 1.0)
        try expect(action() == "Open", "one account: '\(action())', wanted Open")
        let work = try supervisor.addAccount(harness: .codex, label: "Work")
        // Whatever the second login is, the sidebar never offers a switch:
        // switching accounts lives in the agent's tile only.
        for (email, org) in [("me@example.test", nil), (nil, nil), ("me@example.test", "org-team"), ("work@example.test", nil)] as [(String?, String?)] {
            reading(work.id, email: email, org: org, used: 0.1)
            try expect(action() == "Open" && usageLine(inbox) == nil,
                       "a second login (\(email ?? "nil"), \(org ?? "nil")) drew '\(action())' / a Needs you line, wanted Open only")
        }
        return "Switch: one account, the same login twice, a login naming nothing, an organisation on one side and a different email all leave the sidebar's one usage action as Open — never Switch & resume…, never Needs you"
    }

    static func checkSwitchSharedOrganization() throws -> String {
        let h = try makeHarness("switch-shared-organization")
        defer { h.close() }
        let supervisor = h.supervisor
        try isolateAccounts(supervisor, root: h.fixture.tempRoot)
        let lead = h.spawn("Claude lead", harness: .claudeCode)
        let helper = h.spawn("Claude helper", parent: lead, harness: .claudeCode)
        h.finish(lead)
        h.finish(helper, failed: "You've hit your limit · resets 1:20 AM (America/Toronto)")
        h.refresh()

        let active = supervisor.activeAccount(for: .claudeCode)
        let alternate = try supervisor.addAccount(harness: .claudeCode, label: "Work")
        func reading(_ account: AgentAccount, email: String, org: String, used: Double) {
            supervisor.applyAccountUsageReading(
                .init(identity: AgentAccountIdentity(harness: .claudeCode, email: email,
                                                     organizationId: org, observedAt: Date()),
                      quota: AgentAccountQuotaSnapshot(
                        harness: .claudeCode,
                        windows: [AgentQuotaWindow(kind: .fiveHour, utilization: used,
                                                   resetsAt: Date().addingTimeInterval(3_600))],
                        observedAt: Date(), source: .claudeUsageRequest, accountId: account.id)),
                accountId: account.id)
            h.inbox.layoutForQA()
        }
        func action() -> String {
            h.inbox.sidebarIncidents.first { $0.kind == .cause(.usageLimit) }?.actionTitle ?? "no usage item"
        }
        supervisor.setUsageAutoResume(false, for: helper)
        reading(active, email: "personal@example.test", org: "team", used: 1.0)
        reading(alternate, email: "work@example.test", org: "team", used: 0.1)
        let settings = supervisor.settingsAccountRows().first { $0.id == alternate.id }
        try expect(settings?.sameLoginAs == active.label && settings?.canSignIn == true,
                   "Settings did not offer Sign In for the alternate in the same organization")
        guard case .refused = supervisor.switchAccount(to: alternate.id) else {
            throw Failure(description: "the supervisor accepted a switch within the same organization")
        }
        try expect(action() == "Open",
                   "the only alternate shares the active organization and Settings offers Sign In; the sidebar draws '\(action())', wanted Open")

        reading(alternate, email: "personal@example.test", org: "other-team", used: 0.1)
        let eligible = supervisor.settingsAccountRows().first { $0.id == alternate.id }
        try expect(eligible?.canSignIn == false && action() == "Open",
                   "a switchable login in another organization still leaves the sidebar on Open (switching is the tile's), got '\(action())'")
        return "Settings requires Sign In for an alternate in the shared organization and the supervisor refuses that switch; with a switchable login in another organization the mounted sidebar's Claude usage item still offers Open, never Switch & resume…"
    }

    // MARK: - 9. History dates come from real turns and redraw when they move

    static func checkHistoryDates() throws -> String {
        let now = Date()
        func days(_ n: Double) -> Date { now.addingTimeInterval(-n * 86_400) }
        let root = AgentID(rawValue: UUID()), worked = AgentID(rawValue: UUID()), unused = AgentID(rawValue: UUID())
        let h = try makeHarness("history-dates") { delegate, _ in
            guard let peer = delegate.qaAgentSupervisor.records.values.first else {
                throw Failure(description: "fixture agent missing")
            }
            let store = AgentStore(smokeTest: false)
            func put(_ id: AgentID, _ title: String, parent: AgentID?, turn: Date?, created: Date) throws {
                var record = AgentRecord(
                    id: id, displayName: title, model: peer.model, thinking: peer.thinking, cwd: peer.cwd,
                    projectId: peer.projectId, parentAgentID: parent,
                    createdAt: created, lastActivityAt: turn ?? created, latestPromptAt: parent == nil ? turn : nil,
                    latestTurnAt: turn,
                    latestTerminalEvent: turn.map { AgentTerminalEvent(sequence: 1, turnID: "t", outcome: .succeeded, endedAt: $0) },
                    archivedAt: (turn ?? created).addingTimeInterval(120))
                record.acknowledgedTerminalSequence = turn == nil ? 0 : 1
                try store.upsert(record)
            }
            try put(root, "Older real work", parent: nil, turn: days(3), created: days(3.1))
            try put(worked, "Helper that worked", parent: root, turn: days(4), created: days(4.1))
            // Opened today, never used.
            try put(unused, "Helper never used", parent: root, turn: nil, created: now.addingTimeInterval(-600))
        }
        defer { h.close() }
        let inbox = h.inbox
        inbox.clock = { now }
        h.refresh()
        if !inbox.isHistoryExpandedForQA { _ = inbox.clickHistoryDisclosureForQA() }
        inbox.layoutForQA()
        try expect(inbox.isHistoryExpandedForQA, "History did not open")
        let table = inbox.tableForQA
        func card() -> SidebarQuietHistoryEntryView? {
            guard let row = inbox.itemsForQuietCheck.firstIndex(where: { $0.agentRow?.id == root.rawValue }) else { return nil }
            inbox.scrollItemToVisibleForQA(row)
            return table.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarQuietHistoryEntryView
        }
        func age(_ date: Date?) -> String { date.map { String(format: "%.2fd", now.timeIntervalSince($0) / 86_400) } ?? "nil" }
        guard let first = card() else { throw Failure(description: "no History card for the family") }
        let firstDetail = SidebarQuietHistoryEntryView.detail(helpers: 2, endedAt: days(3), now: now)
        try expect(first.shownDate.map { abs($0.timeIntervalSince(days(3))) < 1 } == true && first.detailForQA == firstDetail,
                   "(i) an unused helper moved the family's date: shows \(age(first.shownDate)) ago, wanted the root's real turn 3.00d")

        // (ii) A helper's later real turn reaches the mounted card. The helper is
        // never drawn in History and the root row does not change: only the
        // card's derived date does.
        var rows = inbox.allRowsForQuietCheck
        guard let index = rows.firstIndex(where: { $0.id == worked.rawValue }) else {
            throw Failure(description: "fixture: the working helper has no pushed row")
        }
        rows[index].lastTurnAt = days(1)
        inbox.apply(rows: rows, changed: AgentsBoardChangeSet(added: [], updated: [worked.rawValue], removed: []))
        inbox.layoutForQA()
        guard let row = inbox.itemsForQuietCheck.firstIndex(where: { $0.agentRow?.id == root.rawValue }),
              let mounted = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarQuietHistoryEntryView else {
            throw Failure(description: "(ii) the family's card is not mounted after the push")
        }
        let updatedDetail = SidebarQuietHistoryEntryView.detail(helpers: 2, endedAt: days(1), now: now)
        try expect(mounted.shownDate.map { abs($0.timeIntervalSince(days(1))) < 1 } == true && mounted.detailForQA == updatedDetail,
                   "(ii) a helper's later turn left the mounted card showing \(age(mounted.shownDate)) ago, wanted 1.00d")
        return "History dates: an unused helper made today left the family at its real 3-day-old turn; a helper's later turn redrew the mounted card to 1 day ago"
    }

    // MARK: - 10. Chatter does no History work

    static func checkHistoryChatter() throws -> String {
        let h = try makeHarness("history-chatter")
        defer { h.close() }
        let inbox = h.inbox
        for family in 0..<8 {
            let lead = h.spawn("Parked family \(family + 1)")
            let helpers = (0..<3).map { h.spawn("Parked helper \(family + 1).\($0 + 1)", parent: lead) }
            for id in [lead] + helpers { h.finish(id) }
            _ = h.supervisor.settle(agentID: lead)
        }
        let worker = h.spawn("Chatty worker")
        let thread = AgentSupervisor.threadId(for: worker)
        h.refresh()
        let warmDeadline = Date().addingTimeInterval(5)
        while h.delegate.branchWarmInFlight, Date() < warmDeadline { pump(0.02) }
        try expect(!h.delegate.branchWarmInFlight, "fixture: initial branch refresh timed out")
        // Let the working state and its first tool event reach the row before
        // measuring chatter, which should patch an already confirmed row.
        h.supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: "t"), to: worker)
        let workingDeadline = Date().addingTimeInterval(5)
        while inbox.pushedRowForQA(id: worker.rawValue)?.state != .working, Date() < workingDeadline { pump(0.02) }
        try expect(inbox.pushedRowForQA(id: worker.rawValue)?.state == .working, "fixture: the worker did not start")
        h.supervisor.qaDeliver(.itemStarted(threadId: thread, itemId: "warm", kind: .commandExecution, title: "cat README.md"), to: worker)
        let chatterDeadline = Date().addingTimeInterval(5)
        while inbox.pushedRowForQA(id: worker.rawValue)?.characterActivity?.action != .read, Date() < chatterDeadline { pump(0.02) }
        try expect(inbox.pushedRowForQA(id: worker.rawValue)?.characterActivity?.action == .read,
                   "fixture: the worker's warm-up tool event did not reach the sidebar")
        try expect((inbox.historyHeaderTitleForQA ?? "").hasPrefix("History"), "fixture: no History heading")
        if inbox.isHistoryExpandedForQA { try clickHistoryHeading(inbox); pump(0.3) }
        try expect(!inbox.isHistoryExpandedForQA, "fixture: History did not close")

        func chatter(_ tag: String) throws -> (projections: Int, rowBuilds: Int) {
            let projections = inbox.historyProjectionBuildCountForQA
            let rowBuilds = h.delegate.qaInboxRowBuildCount
            let before = inbox.pushedRowForQA(id: worker.rawValue)
            for round in 0..<3 {
                h.supervisor.qaDeliver(.itemCompleted(threadId: thread, itemId: "\(tag)\(round)", kind: .commandExecution,
                                                      status: .completed), to: worker)
                h.supervisor.qaDeliver(.itemStarted(threadId: thread, itemId: "\(tag)\(round)", kind: .commandExecution,
                                                    title: "rg needle \(tag)\(round)"), to: worker)
                pump(0.3)
            }
            pump(0.4)
            // Positive control: the chatter really was pushed to the sidebar.
            try expect(inbox.pushedRowForQA(id: worker.rawValue) != before,
                       "\(tag): the chatter never reached the sidebar row")
            return (inbox.historyProjectionBuildCountForQA - projections, h.delegate.qaInboxRowBuildCount - rowBuilds)
        }
        let collapsed = try chatter("collapsed")
        try expect(collapsed.projections == 0 && collapsed.rowBuilds == 0,
                   "collapsed: 6 chatter events rebuilt the History projection \(collapsed.projections) times (row builds \(collapsed.rowBuilds))")
        try clickHistoryHeading(inbox)
        pump(0.3)
        try expect(inbox.isHistoryExpandedForQA, "History did not open")
        let expanded = try chatter("expanded")
        try expect(expanded.projections == 0 && expanded.rowBuilds == 0,
                   "expanded: 6 chatter events rebuilt the History projection \(expanded.projections) times (row builds \(expanded.rowBuilds))")
        // Positive control: a History family's change does rebuild it.
        let before = inbox.historyProjectionBuildCountForQA
        let late = h.spawn("Late family")
        h.finish(late)
        _ = h.supervisor.settle(agentID: late)
        h.refresh()
        try expect(inbox.historyProjectionBuildCountForQA > before, "control: a new History family did not rebuild the projection")
        return "History chatter: 6 chatter events with History collapsed and 6 open built the family projection 0 times (row builds \(collapsed.rowBuilds)/\(expanded.rowBuilds)); a new History family rebuilt it"
    }

    static func checkHistoryBranchSearch() throws -> String {
        let h = try makeHarness("history-branch-search")
        defer { h.close() }
        let inbox = h.inbox
        let fixture = h.fixture
        let query = "branch-needle"
        let ordinary = "ordinary"
        h.supervisor.accountUsageReader = { _ in nil }

        func parkedLead(_ title: String, in root: URL, project: UUID, branch: String) throws -> AgentID {
            _ = try CandidatePrepassChecks.git(root, ["init", "-qb", branch])
            _ = try CandidatePrepassChecks.git(root, ["commit", "--allow-empty", "-qm", "fixture"])
            let id = h.supervisor.spawn(role: nil, prompt: nil, cwd: root, harness: .pi,
                                        model: "openai-codex/gpt-5.6-sol", thinking: "high",
                                        projectId: project, projectRoot: root, displayName: title)
            h.finish(id)
            _ = h.supervisor.settle(agentID: id)
            return id
        }
        let first = try parkedLead("First parked lead", in: fixture.paRoot, project: fixture.projectPa, branch: query)
        let second = try parkedLead("Second parked lead", in: fixture.pcRoot, project: fixture.projectPc, branch: ordinary)
        let worker = h.spawn("Unrelated worker")
        let thread = AgentSupervisor.threadId(for: worker)
        h.supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: "work"), to: worker)
        h.refresh()
        func awaitBranchWarm() throws {
            let deadline = Date().addingTimeInterval(5)
            while h.delegate.branchWarmInFlight, Date() < deadline { pump(0.02) }
            try expect(!h.delegate.branchWarmInFlight, "activation branch refresh timed out")
            inbox.layoutForQA()
        }
        try awaitBranchWarm()
        try expect(inbox.pushedRowForQA(id: first.rawValue)?.branch == query
                   && inbox.pushedRowForQA(id: second.rawValue)?.branch == ordinary,
                   "fixture: the initial checkout branches did not reach the sidebar")
        inbox.setSearchForQA(query)
        if !inbox.isHistoryExpandedForQA { try clickHistoryHeading(inbox) }
        func drawnTitles() -> [String] {
            inbox.layoutForQA()
            return Q.views(in: inbox.tableForQA) { $0 is SidebarQuietHistoryEntryView }
                .compactMap { ($0 as? SidebarQuietHistoryEntryView)?.titleForQA }
        }
        try expect(drawnTitles() == ["First parked lead"], "fixture: expected the first branch match, drew \(drawnTitles())")

        // Leave an unrelated update as the last activity push before activation.
        let before = inbox.pushedRowForQA(id: worker.rawValue)
        h.supervisor.qaDeliver(.itemStarted(threadId: thread, itemId: "chatter", kind: .commandExecution,
                                            title: "cat README.md"), to: worker)
        let deadline = Date().addingTimeInterval(5)
        while inbox.pushedRowForQA(id: worker.rawValue) == before, Date() < deadline { pump(0.02) }
        try expect(inbox.pushedRowForQA(id: worker.rawValue) != before, "fixture: worker chatter did not reach the sidebar")

        _ = try CandidatePrepassChecks.git(fixture.paRoot, ["branch", "-m", ordinary])
        _ = try CandidatePrepassChecks.git(fixture.pcRoot, ["branch", "-m", query])
        h.delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification,
                                                            object: NSApplication.shared))
        try awaitBranchWarm()
        try expect(inbox.pushedRowForQA(id: first.rawValue)?.branch == ordinary
                   && inbox.pushedRowForQA(id: second.rawValue)?.branch == query,
                   "activation did not push both new checkout branches")
        let titles = drawnTitles()
        try expect(inbox.historyHeaderTitleForQA == "History (1)" && titles == ["Second parked lead"],
                   "activation swapped the branches and left one match, but mounted History drew \(titles); wanted the second lead")
        return "Activation refreshed two checkout branches together. One matching mounted History card replaced the other after unrelated chatter."
    }

    static func checkUsageScopeActions() throws -> String {
        func switchedScope(layout: SidebarLayout) throws -> String? {
            let h = try makeHarness("scope-\(layout.rawValue)-open")
            defer { h.close() }
            let inbox = h.inbox
            inbox.setSidebarLayoutForQA(layout)
            let fixture = h.fixture
            let first = h.supervisor.spawn(role: nil, prompt: nil, cwd: fixture.paRoot, harness: .codex,
                                           model: "openai-codex/gpt-5.6-sol", thinking: "low",
                                           projectId: fixture.projectPa, projectRoot: fixture.paRoot,
                                           displayName: "Paused in Pa")
            let second = h.spawn("Paused in Pb", harness: .codex)
            try makeUsageLive(h.supervisor, harness: .codex, root: fixture.tempRoot, secondLogin: false)
            for id in [first, second] { h.finish(id, failed: "You've hit your usage limit. Upgrade to Pro or try again at 3:05 PM.") }
            h.refresh()

            // Quiet draws a usage pause as its family's cause line (never a
            // Needs you line); the Ledger, as an incident row.
            func resumeButton() -> NSButton? {
                if layout == .quietInbox {
                    return Q.views(in: inbox.tableForQA) { ($0 as? AgentInboxRemainderView)?.causeIncidentForQA?.kind == .cause(.usageLimit)
                        && !$0.isHiddenOrHasHiddenAncestor }
                        .compactMap { ($0 as? AgentInboxRemainderView)?.causeActionForQA }.first
                }
                return Q.views(in: inbox) { $0 is SidebarIncidentCellView && !$0.isHiddenOrHasHiddenAncestor }
                    .compactMap { $0 as? SidebarIncidentCellView }.first?.actionButton
            }
            try expect(inbox.pickScopeForQA(.project("Pa")), "fixture: Pa scope unavailable")
            inbox.scrollToTopForQA()
            inbox.layoutForQA()
            try expect(inbox.sidebarIncidents.first?.agentIDs == [first.rawValue] && resumeButton()?.window === h.window,
                       "fixture: Pa usage line was not mounted")
            try expect(inbox.pickScopeForQA(.project("Pb")), "fixture: Pb scope unavailable")
            inbox.layoutForQA()
            guard let current = inbox.sidebarIncidents.first(where: { $0.kind == .cause(.usageLimit) }),
                  let resume = resumeButton(), resume.title == SidebarFailureCause.usageResumeTitle else {
                throw Failure(description: "fixture: Pb usage line was not mounted")
            }
            try expect(current.agentIDs == [second.rawValue], "fixture: usage model did not switch to Pb")
            try Q.click(resume)
            if h.delegate.lastSidebarIncidentOutcomeForQA != .revealedAgent(second.rawValue) {
                return "\(layout.rawValue) Open expected Pb's agent \(second.rawValue), got \(h.delegate.lastSidebarIncidentOutcomeForQA) (Pa's agent \(first.rawValue))"
            }
            return nil
        }
        let failures = try [switchedScope(layout: .quietInbox), switchedScope(layout: .ledger)].compactMap { $0 }
        try expect(failures.isEmpty, failures.joined(separator: "\n"))
        return "After a same-count Pa → Pb scope change, Quiet's cause line and the Ledger's incident Open revealed Pb's agent. (A usage pause is not a Needs you item, so it has no Dismiss.)"
    }

    static func checkFamilyCauseAction() throws -> String {
        let h = try makeHarness("family-cause-action")
        defer { h.close() }
        let inbox = h.inbox
        let lead = h.spawn("Lead with paused helper")
        let first = h.spawn("Initially paused helper", parent: lead, harness: .codex)
        let second = h.spawn("Newly paused helper", parent: lead, harness: .codex)
        // Standalone helper tiles make each helper its own resume owner.
        try expect(h.delegate.revealAgentFromInbox(lead.rawValue)
                   && h.delegate.revealAgentFromInbox(first.rawValue)
                   && h.delegate.revealAgentFromInbox(second.rawValue), "fixture: could not pop out both helpers")
        try makeUsageLive(h.supervisor, harness: .codex, root: h.fixture.tempRoot, secondLogin: false)
        let words = "You've hit your usage limit. Upgrade to Pro or try again at 3:05 PM."
        h.finish(first, failed: words)
        h.finish(second)
        h.refresh()
        func causeLine() -> AgentInboxRemainderView? {
            Q.views(in: inbox.tableForQA) { ($0 as? AgentInboxRemainderView)?.causeIncidentForQA != nil }
                .compactMap { $0 as? AgentInboxRemainderView }.first
        }
        try expect(causeLine()?.causeIncidentForQA?.ownerIDs == [first.rawValue],
                   "fixture: the mounted family cause did not target the first helper")
        h.finish(first)
        h.finish(second, failed: words)
        h.refresh()
        guard let action = causeLine()?.causeActionForQA, action.title == SidebarFailureCause.usageResumeTitle else {
            throw Failure(description: "fixture: the family usage Open did not stay mounted")
        }
        try expect(inbox.sidebarFamilyChips.first?.incident.agentIDs == [second.rawValue],
                   "fixture: the family cause model did not switch to the second helper")
        try Q.click(action)
        try expect(h.delegate.lastSidebarIncidentOutcomeForQA == .revealedAgent(second.rawValue),
                   "family Resume targeted \(h.delegate.lastSidebarIncidentOutcomeForQA), wanted the newly paused helper \(second.rawValue)")
        return "A family kept one paused helper as ownership changed. Its mounted Resume opened the newly paused helper."
    }

    static func checkLeadCountFold() throws -> String {
        let h = try makeHarness("lead-count-fold")
        defer { h.close() }
        let inbox = h.inbox
        let lead = h.spawn("Lead")
        let subLead = h.spawn("Sub-lead", parent: lead)
        _ = h.spawn("Nested helper", parent: subLead)
        h.refresh()
        func countCell() -> AgentInboxRemainderView? {
            guard let index = inbox.itemsForQuietCheck.firstIndex(where: {
                if case .leadCount(let tally) = $0 { return tally.leadId == lead.rawValue }
                return false
            }) else { return nil }
            return inbox.tableForQA.view(atColumn: 0, row: index, makeIfNecessary: false) as? AgentInboxRemainderView
        }
        guard let openCell = countCell(), let openTally = openCell.countTallyForQA, openTally.shown == 2 else {
            throw Failure(description: "fixture: the mounted lead count did not have two shown helpers")
        }
        try expect(inbox.clickDisclosureForQA(id: subLead.rawValue), "fixture: could not fold the sub-lead")
        inbox.layoutForQA()
        guard let foldedCell = countCell(), let folded = inbox.sidebarTallies[lead.rawValue] else {
            throw Failure(description: "fixture: the lead count was not mounted after the fold")
        }
        try expect(folded.shown == 1 && folded.folded == 1 && folded.countLine == openTally.countLine,
                   "fixture: fold did not preserve the visible helper count while hiding one nested helper")
        try expect(foldedCell.accessibilityLabel() == folded.accessibilityLabel,
                   "the mounted count announced '\(foldedCell.accessibilityLabel() ?? "")', wanted '\(folded.accessibilityLabel)'")
        return "Folding a sub-lead kept the helper count and updated the mounted count line's shown/folded accessibility text."
    }

    static func checkHistoryRename() throws -> String {
        let h = try makeHarness("history-rename")
        defer { h.close() }
        let inbox = h.inbox
        let title = "Finished release notes"
        let renamed = "Reviewed release notes"
        let id = h.spawn(title)
        h.finish(id)
        try expect(h.supervisor.settle(agentID: id), "fixture: could not settle the agent")
        h.refresh()
        if !inbox.isHistoryExpandedForQA { try clickHistoryHeading(inbox) }
        func card() -> SidebarQuietHistoryEntryView? {
            guard let index = inbox.itemsForQuietCheck.firstIndex(where: { $0.agentRow?.id == id.rawValue }) else { return nil }
            inbox.scrollItemToVisibleForQA(index)
            inbox.layoutForQA()
            return inbox.cellForQA(atItem: index) as? SidebarQuietHistoryEntryView
        }
        guard let original = card(), original.titleForQA == title else {
            throw Failure(description: "fixture: settled History card was not mounted")
        }
        inbox.presentsPopoversOffscreenForQA = true
        try Q.rightClick(original)
        try expect(inbox.pickRowMenuItemForQA(.rename), "History card did not offer Rename")
        try expect(inbox.renamingRowIdForQA == id.rawValue && inbox.renameFieldTextForQA == title,
                   "History card offered Rename but did not open the shared editor")
        let titleFrame = original.convert(original.titleFrameForQA, to: inbox)
        try expect(inbox.renameFieldFrameForQA?.contains(titleFrame) == true,
                   "shared editor does not cover the mounted History title")
        try expect(inbox.typeRenameForQA(renamed) && inbox.pressKeyInRenameForQA(#selector(NSResponder.insertNewline(_:))),
                   "shared editor did not handle Return")
        try expect(h.supervisor.records[id]?.displayName == renamed && card()?.titleForQA == renamed,
                   "the committed name did not reach the agent and the mounted History card")
        try expect(inbox.doubleClickRowForQA(id: id.rawValue, onTitle: true)
                   && inbox.renamingRowIdForQA == id.rawValue,
                   "double-clicking the History title did not open the shared editor")
        try expect(inbox.pressKeyInRenameForQA(#selector(NSResponder.cancelOperation(_:))), "shared editor did not handle Escape")
        return "The mounted History card opened the shared editor from its context menu and title; Return renamed the agent and repainted the card."
    }

    static func checkHistoryFocusedHelper() throws -> String {
        let h = try makeHarness("history-focused-helper")
        defer { h.close() }
        let inbox = h.inbox
        let lead = h.spawn("Old parked family")
        let helper = h.spawn("Focused helper", parent: lead)
        h.finish(helper)
        h.finish(lead)
        try expect(h.delegate.revealAgentFromInbox(lead.rawValue) && h.delegate.revealAgentFromInbox(helper.rawValue),
                   "fixture: could not open the lead and pop out its helper")
        for index in 0...InboxSort.settledPageSize {
            let newer = h.spawn("Newer parked family \(index + 1)")
            h.finish(newer)
            try expect(h.supervisor.settle(agentID: newer), "fixture: could not settle newer family \(index + 1)")
        }
        h.refresh()
        try expect(inbox.scrollToAgentForQA(id: lead.rawValue), "fixture: live lead was not visible")
        try expect(inbox.openRowMenuForQA(clickedRowId: lead.rawValue) && inbox.pickRowMenuItemForQA(.settle),
                   "fixture: could not settle the lead through the sidebar")
        try expect(h.supervisor.records[lead]?.tileId == nil && h.supervisor.records[helper]?.tileId != nil,
                   "fixture: settling the lead did not leave only the helper's tile open")

        func cardIDs() -> [UUID] {
            inbox.itemsForQuietCheck.enumerated().compactMap { index, item in
                guard let row = item.agentRow,
                      inbox.tableForQA.view(atColumn: 0, row: index, makeIfNecessary: true) is SidebarQuietHistoryEntryView
                else { return nil }
                return row.id
            }
        }
        guard let note = h.fixture.canvas.navigationTileSnapshots().first(where: { $0.kind == .note }) else {
            throw Failure(description: "fixture: no non-agent tile to focus for the first page")
        }
        h.fixture.canvas.markActive(tileId: note.tileId)
        h.refresh()
        if !inbox.isHistoryExpandedForQA { try clickHistoryHeading(inbox) }
        let firstPage = cardIDs()
        try expect(firstPage.count == InboxSort.settledPageSize && !firstPage.contains(lead.rawValue),
                   "fixture: older family was not beyond page one (\(firstPage.count) cards)")
        try expect(h.delegate.revealAgentFromInbox(helper.rawValue), "fixture: could not focus the popped-out helper")
        h.refresh()
        try expect(inbox.openAgentId == helper.rawValue, "fixture: helper tile did not become the sidebar's focused agent")
        let focusedPage = cardIDs()
        try expect(focusedPage == firstPage + [lead.rawValue],
                   "focusing the helper drew \(focusedPage.count) cards without appending its old family to the first page")
        let hidden = inbox.itemsForQuietCheck.compactMap { item -> Int? in
            if case .settledMore(let count) = item { return count }
            return nil
        }
        try expect(hidden == [1], "History footer should count only the one other hidden family, got \(hidden)")
        return "Focusing the popped-out helper drew its older family after the ten recent cards. The footer counted one other hidden family."
    }

    static func checkUsageProjectDismissals() throws -> String {
        let h = try makeHarness("usage-project-dismissals")
        defer { h.close() }
        let inbox = h.inbox
        let fixture = h.fixture
        let first = h.supervisor.spawn(role: nil, prompt: nil, cwd: fixture.paRoot, harness: .codex,
                                       model: "openai-codex/gpt-5.6-sol", thinking: "low",
                                       projectId: fixture.projectPa, projectRoot: fixture.paRoot,
                                       displayName: "Paused in Pa")
        let second = h.spawn("Paused in Pb", harness: .codex)
        try makeUsageLive(h.supervisor, harness: .codex, root: fixture.tempRoot, secondLogin: false)
        for id in [first, second] {
            h.finish(id, failed: "You've hit your usage limit. Upgrade to Pro or try again at 3:05 PM.")
        }
        h.refresh()

        func selectProject(_ project: String) throws {
            try expect(inbox.pickScopeForQA(.project(project)), "fixture: \(project) scope unavailable")
            inbox.scrollToTopForQA()
            inbox.layoutForQA()
        }
        func mountedUsageLine() -> SidebarQuietNeedsYouView.Line? {
            Q.views(in: inbox) { $0 is SidebarQuietNeedsYouView && !$0.isHiddenOrHasHiddenAncestor }
                .compactMap { $0 as? SidebarQuietNeedsYouView }
                .first?.lines.first { $0.incident?.kind == .cause(.usageLimit) }
        }
        // Each project shows its own agent's pause, and never as a Needs you
        // line: there is nothing to dismiss, and nothing to act on but Open.
        for (project, id) in [("Pa", first), ("Pb", second)] {
            try selectProject(project)
            let usage = inbox.sidebarIncidents.filter { $0.kind == .cause(.usageLimit) }
            try expect(usage.count == 1 && usage[0].agentIDs == [id.rawValue] && !usage[0].isBlocking
                       && usage[0].actionTitle == "Open" && mountedUsageLine() == nil,
                       "\(project): wanted one non-blocking usage item for its own agent and no Needs you line — got \(usage.map { "\($0.title):\($0.agentIDs.count):\($0.isBlocking)" })")
        }
        return "Pa and Pb each showed only their own agent's usage pause, non-blocking with Open, and neither drew a Needs you line to dismiss."
    }

    static func checkHistoryKeyboardPaint() throws -> String {
        let h = try makeHarness("history-keyboard-paint")
        defer { h.close() }
        let inbox = h.inbox
        let older = h.spawn("Older finished agent")
        let newer = h.spawn("Newer finished agent")
        for id in [older, newer] {
            h.finish(id)
            try expect(h.supervisor.settle(agentID: id), "fixture: could not settle agent")
        }
        h.refresh()
        if !inbox.isHistoryExpandedForQA { try clickHistoryHeading(inbox) }
        let cards = inbox.itemsForQuietCheck.enumerated().compactMap { index, item -> (UUID, Int)? in
            guard let row = item.agentRow,
                  inbox.cellForQA(atItem: index) is SidebarQuietHistoryEntryView else { return nil }
            return (row.id, index)
        }
        try expect(cards.map(\.0) == [newer.rawValue, older.rawValue] && inbox.focusListForQA(),
                   "fixture: could not focus the two History cards in order")
        func paint(_ index: Int) -> (fill: Bool, ring: Bool) {
            inbox.layoutForQA()
            guard let card = inbox.cellForQA(atItem: index), card.window === h.window,
                  let chrome = Q.views(in: card, where: { $0 is AgentInboxCardView }).first as? AgentInboxCardView
            else { return (false, false) }
            return (chrome.layer?.backgroundColor != nil, chrome.qaIsFocusRingVisible)
        }
        try Q.key(119, "\u{F72B}", in: h.window) // End
        try expect(inbox.selectedRowIdsForQA == [older.rawValue], "fixture: End did not select the older History card")
        let end = paint(cards[1].1)
        try Q.key(126, "\u{F700}", in: h.window) // Up
        try expect(inbox.selectedRowIdsForQA == [newer.rawValue], "fixture: Up did not select the newer History card")
        let up = paint(cards[0].1)
        let previous = paint(cards[1].1)
        try Q.key(36, "\r", in: h.window)
        try expect(h.supervisor.records[newer]?.tileId != nil && h.supervisor.records[older]?.tileId == nil,
                   "Return did not open the keyboard-selected History card")
        try expect(end.fill && end.ring && up.fill && up.ring && !previous.fill && !previous.ring,
                   "History keyboard target reached Return but paint did not follow (End \(end), Up \(up), previous \(previous))")
        return "End and Up moved the painted selection and focus ring between mounted History cards. Return opened the painted target."
    }

    static func checkHistoryDisplayTitleSearch() throws -> String {
        let h = try makeHarness("history-display-title-search")
        defer { h.close() }
        let inbox = h.inbox
        let storedTitle = "Audit **pricing** flow"
        let displayedTitle = "Audit pricing flow"
        let id = h.spawn("Pricing audit")
        h.finish(id)
        try expect(h.supervisor.settle(agentID: id), "fixture: could not settle the search target")
        try expect(h.supervisor.rename(agentID: id, to: storedTitle), "fixture: could not store the marked-up title")
        h.refresh()
        if !inbox.isHistoryExpandedForQA { try clickHistoryHeading(inbox) }
        func mountedTitle() -> String? {
            inbox.layoutForQA()
            guard let index = inbox.itemsForQuietCheck.firstIndex(where: { $0.agentRow?.id == id.rawValue }),
                  let card = inbox.cellForQA(atItem: index) as? SidebarQuietHistoryEntryView, card.window === h.window
            else { return nil }
            return card.titleForQA
        }
        try expect(inbox.pushedRowForQA(id: id.rawValue)?.title == storedTitle && mountedTitle() == displayedTitle,
                   "fixture: the stored and painted titles did not differ")
        inbox.setSearchForQA(storedTitle)
        try expect(mountedTitle() == displayedTitle, "search stopped matching the stored title")
        inbox.setSearchForQA(displayedTitle)
        try expect(mountedTitle() == displayedTitle, "searching the painted title dropped its mounted History card")
        inbox.setSearchForQA("unrelated audit title")
        try expect(mountedTitle() == nil, "an unrelated title unexpectedly matched")
        return "The mounted History card matched both the stored Markdown title and the title it paints."
    }

    // MARK: - 11. Restored titles publish once

    static func checkRestoredTitlesPublishOnce() throws -> String {
        let untitled = (0..<3).map { _ in AgentID(rawValue: UUID()) }
        let prompts = ["Fix the flaky login test", "Tidy the release notes", "Measure cold launch"]
        let h = try makeHarness("restored-titles") { delegate, _ in
            let ended = Date().addingTimeInterval(-3_600)
            guard let peer = delegate.qaAgentSupervisor.records.values.first else {
                throw Failure(description: "fixture agent missing")
            }
            let transcripts = AgentTranscriptStore(root: RegistryStore.defaultApplicationSupportDirectory()
                .appendingPathComponent("agent-transcripts", isDirectory: true))
            for (id, prompt) in zip(untitled, prompts) {
                try AgentStore(smokeTest: false).upsert(AgentRecord(
                    id: id, displayName: AgentRecord.defaultAgentName, displayNameSource: .sentinel,
                    model: peer.model, thinking: peer.thinking, cwd: peer.cwd, projectId: peer.projectId,
                    createdAt: ended.addingTimeInterval(-60), lastActivityAt: ended, latestPromptAt: ended.addingTimeInterval(-50),
                    latestTerminalEvent: AgentTerminalEvent(sequence: 1, turnID: "t", outcome: .succeeded, endedAt: ended),
                    archivedAt: ended))
                var projection = AgentTranscriptProjection(threadId: "untitled")
                projection.appendUserPrompt(prompt)
                var saved = false
                Task { @MainActor in
                    try? await transcripts.saveSnapshot(agentID: id,
                        sessionID: AgentTranscriptStore.canonicalSessionID(for: id), document: projection.document)
                    saved = true
                }
                while !saved { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            }
        }
        defer { h.close() }
        let inbox = h.inbox
        var publishes = 0
        let original = h.supervisor.onFailureDetailsLoaded
        h.supervisor.onFailureDetailsLoaded = { publishes += 1; original?() }
        h.refresh()
        func titles() -> Set<String> {
            Set(untitled.compactMap { inbox.pushedRowForQA(id: $0.rawValue)?.displayTitle })
        }
        let deadline = Date().addingTimeInterval(10)
        while titles() != Set(prompts), Date() < deadline { pump(0.05) }
        try expect(titles() == Set(prompts), "the restored titles did not all arrive: \(titles())")
        pump(0.5)
        try expect(publishes == 1, "3 restored untitled agents published \(publishes) full row updates, wanted 1 (title batches \(h.supervisor.untitledNamePublishCountForQA))")
        return "Restored titles: 3 untitled agents' first prompts arrived in one published update"
    }
}

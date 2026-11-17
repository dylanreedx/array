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

        func close() {
            window.orderOut(nil)
            suite.removePersistentDomain(forName: suite.suiteDomainName)
            try? FileManager.default.removeItem(at: fixture.tempRoot)
        }
    }

    static func makeHarness(_ name: String, reducedMotion: Bool = true,
                            beforeMount: ((_ delegate: AppDelegate, _ tempRoot: URL) throws -> Void)? = nil) throws -> Harness {
        Q.acceptFirstMouseEverywhere()
        guard let suite = QAIsolatedDefaults(isolatedSuiteName: "dev.arrayapp.qa.dogfood-\(name).\(UUID().uuidString)") else {
            throw Failure(description: "no isolated defaults suite")
        }
        suite.set(SidebarLayout.quietInbox.rawValue, forKey: SidebarLayout.defaultsKey)
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
        return Harness(fixture: fixture, suite: suite, window: window, sidebar: sidebar)
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

    static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func run() throws -> String {
        var reports: [String] = []
        reports.append(try checkHistoryRows())
        reports.append(try checkHistoryPaints())
        reports.append(try checkLiveUsage())
        reports.append(try checkOrphanRoot())
        reports.append(try checkUntitledLead())
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
            if inbox.isHistoryExpandedForQA != open, let header = inbox.historyHeaderViewForQA {
                try Q.click(header)
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

        // (a) Old failure words alone, no live reading: nothing needs you.
        try expect(usageIncidents().isEmpty && usageLine() == nil,
                   "(a) a usage item shows with no live reading — incidents \(inbox.sidebarIncidents.map(\.title))")
        // Live usage NOT exhausted: still nothing, and the stops are clearable.
        reading(active.id, org: "org-personal", used: 0.4)
        try expect(usageIncidents().isEmpty && usageLine() == nil,
                   "(a) a usage item shows while live usage is 40% — incidents \(inbox.sidebarIncidents.map(\.title))")
        try expect(inbox.sidebarClearIDs.contains(lead.rawValue),
                   "(a) with usage available, the family with old usage stops is clearable (its lead takes them) — Clear \(inbox.sidebarClearIDs.count)")
        // Live usage exhausted: the item appears, through the reading's own notification.
        reading(active.id, org: "org-personal", used: 1.0)
        guard let line = usageLine() else {
            throw Failure(description: "(a) live usage is exhausted but Needs you has no usage item — incidents \(inbox.sidebarIncidents.map(\.title))")
        }
        try expect(line.titleLabel.stringValue == "Codex usage ran out", "(a) the item reads '\(line.titleLabel.stringValue)'")
        // (c, e) One Codex account: Resume, never Switch.
        try expect(line.actionButton.title == SidebarFailureCause.usageResumeTitle,
                   "(c) with one Codex account the action reads '\(line.actionButton.title)', wanted Resume")
        try Q.click(line.actionButton)
        try expect(h.delegate.lastSidebarIncidentOutcomeForQA == .revealedAgent(lead.rawValue)
                       || paused.contains { h.delegate.lastSidebarIncidentOutcomeForQA == .revealedAgent($0.rawValue) },
                   "(c) Resume opens the paused agent — got \(h.delegate.lastSidebarIncidentOutcomeForQA)")
        // (c) A second folder holding the SAME login is not a second account.
        let work = try supervisor.addAccount(harness: .codex, label: "Work")
        reading(work.id, org: "org-personal", used: 0.1)
        try expect(usageLine()?.actionButton.title == SidebarFailureCause.usageResumeTitle,
                   "(c) a second folder on the same login offers '\(usageLine()?.actionButton.title ?? "nil")', wanted Resume")
        // (c) A second signed-in account with a different login: Switch.
        reading(work.id, org: "org-work", used: 0.1)
        guard let switchLine = usageLine(), switchLine.actionButton.title == "Switch & resume…" else {
            throw Failure(description: "(c) a second signed-in Codex account offers '\(usageLine()?.actionButton.title ?? "nil")', wanted Switch & resume…")
        }
        inbox.scrollToTopForQA()
        Q.photograph(h.sidebar, "dogfood-needsyou-live")
        try Q.click(switchLine.actionButton)
        try expect(h.delegate.lastSidebarIncidentOutcomeForQA == .openedSettings("agents"),
                   "(c) Switch & resume… opens Settings > Agents — got \(h.delegate.lastSidebarIncidentOutcomeForQA)")

        // (d) Dismiss through the drawn ×; it persists and stays away on a push.
        try Q.click(switchLine.dismissButton)
        inbox.layoutForQA()
        try expect(usageLine() == nil, "(d) the dismissed usage item is still drawn")
        try expect(SidebarIncidentDismissals.load(from: h.suite)["cause:usageLimit:Codex"] != nil,
                   "(d) the dismissal is not persisted — \(SidebarIncidentDismissals.load(from: h.suite))")
        h.refresh()
        let reread = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 380, height: 600), indicatorDefaults: h.suite)
        reread.reload(rows: inbox.allRowsForQuietCheck)
        try expect(!reread.sidebarIncidents.contains { $0.kind == .cause(.usageLimit) },
                   "(d) a sidebar built from the saved settings shows the dismissed item again")
        try expect(usageLine() == nil, "(d) a push brought the dismissed item back with nothing new")
        // (d) A new incident brings it back: another helper stops on usage.
        let third = codex("Overnight helper 3", parent: lead)
        h.finish(third, failed: codexWords)
        h.refresh()
        try expect(usageLine() != nil, "(d) a new usage stop did not bring the dismissed item back")

        // (b) Usage returns: the item clears itself, through the reading alone.
        reading(active.id, org: "org-personal", used: 0.3)
        try expect(usageLine() == nil && usageIncidents().isEmpty,
                   "(b) usage returned but the item stays — incidents \(inbox.sidebarIncidents.map(\.title))")
        // Cleared stays cleared when usage later runs out: nothing happened to
        // those agents, so the old stop must not bring the family back.
        guard let clear = (Q.views(in: inbox) {
            ($0 as? SidebarSectionLabelView)?.titleForQA.hasPrefix("Inbox") == true && !$0.isHiddenOrHasHiddenAncestor
        }.first as? SidebarSectionLabelView)?.clearButton, !clear.isHidden,
              inbox.sidebarClearIDs.contains(lead.rawValue) else {
            throw Failure(description: "with usage back, the family is not offered to Clear — Clear \(inbox.sidebarClearIDs.count)")
        }
        try Q.click(clear)
        inbox.layoutForQA()
        func drawnLive() -> Bool {
            inbox.itemsForQuietCheck.contains { $0.agentRow?.id == lead.rawValue && $0.agentRow?.isCleared == false }
        }
        try expect(!drawnLive(), "Clear left the family in the live list")
        reading(active.id, org: "org-personal", used: 1.0)
        try expect(!drawnLive() && usageLine() == nil,
                   "usage running out again brought a cleared family back (live \(drawnLive()), item \(usageLine() != nil))")
        return "Live usage: no item from old words or at 40%; at 100% 'Codex usage ran out' with Resume (one account, or a second folder on the same login) and Switch & resume… only with a second login; × dismisses, persists, and a new stop brings it back; usage back clears it; a family cleared while usage was back stays cleared when it runs out again"
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

    // MARK: - 5. An untitled, prompted lead reads as its first prompt

    static func checkUntitledLead() throws -> String {
        let untitled = AgentID(rawValue: UUID())
        let prompt = "Investigate the flaky login test on CI"
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
                archivedAt: ended)
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
        while card()?.titleForQA != AgentName.fromPrompt(prompt), Date() < deadline {
            pump(0.05)
            inbox.layoutForQA()
        }
        let expected = AgentName.fromPrompt(prompt) ?? prompt
        try expect(card()?.titleForQA == expected,
                   "an untitled, prompted History lead reads '\(card()?.titleForQA ?? "no card")', wanted its prompt line '\(expected)' (record \(h.supervisor.records[untitled] != nil), pushed \(inbox.pushedRowForQA(id: untitled.rawValue).map { "\($0.displayTitle) \($0.lifecycle)" } ?? "nil"), History \(inbox.historyHeaderTitleForQA ?? "nil"))")
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
        // Family 4's helper finishes LAST: its family's last activity is the
        // newest, so it must lead History although its lead finished early.
        let lateHelper = extra[3 * 3 + 1]  // "Older helper 4.1"
        for id in extra where id != lateHelper { h.finish(id) }
        for id in [lead, solo] + helpers { h.finish(id) }
        pump(0.05)
        h.finish(lateHelper)
        h.refresh()
        // Clear through the drawn control: both families go to History.
        guard let clear = (Q.views(in: inbox) {
            ($0 as? SidebarSectionLabelView)?.titleForQA.hasPrefix("Inbox") == true && !$0.isHiddenOrHasHiddenAncestor
        }.first as? SidebarSectionLabelView)?.clearButton, !clear.isHidden else {
            throw Failure(description: "no Clear to press")
        }
        try Q.click(clear)
        inbox.layoutForQA()
        guard let header = inbox.historyHeaderViewForQA else { throw Failure(description: "no History heading") }
        try Q.click(header)
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
        // Newest first by family activity, and the card shows that same date.
        func drawnOrder() -> [(title: String, at: Date?)] {
            inbox.itemsForQuietCheck.indices.compactMap { row -> (String, Date?)? in
                guard let entry = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarQuietHistoryEntryView
                else { return nil }
                return (entry.titleForQA, entry.shownDate)
            }
        }
        func nonIncreasing(_ order: [(title: String, at: Date?)]) -> Bool {
            zip(order, order.dropFirst()).allSatisfy { ($0.at ?? .distantPast) >= ($1.at ?? .distantPast) }
        }
        let firstPage = drawnOrder()
        try expect(firstPage.first?.title == "Older family 4" && nonIncreasing(firstPage),
                   "History is not newest-first by family activity: \(firstPage.map { "\($0.title) \($0.at.map { String(format: "%.3f", $0.timeIntervalSince1970) } ?? "-")" })")
        drawn[h.fixture.agentId.rawValue] = nil  // the fixture's own parked source agent
        // Families total: 2 + the older ones + the fixture's agent; a page of
        // `settledPageSize` cards, and the footer counts the families left.
        let families = 2 + InboxSort.settledPageSize + 1
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
        // "Show more" through its drawn control keeps the order.
        guard let more = Q.views(in: inbox, where: { $0 is AgentInboxSettledMoreView && !$0.isHiddenOrHasHiddenAncestor }).first else {
            throw Failure(description: "no Show more under History")
        }
        try Q.click(more)
        inbox.layoutForQA()
        let allPages = drawnOrder()
        try expect(allPages.count == families && nonIncreasing(allPages),
                   "after Show more, History is not newest-first (\(allPages.count) cards): \(allPages.map(\.title))")
        return "History rows: newest first by family activity across Show more (\(allPages.count) cards, '\(firstPage.first?.title ?? "")' first by its late helper); one card per family at \(SidebarQuietHistoryEntryView.height)pt; '\(leadCard.titleForQA)' / '\(leadCard.detailForQA)', solo '\(soloCard.detailForQA)'; helpers stay inside their lead"
    }
}

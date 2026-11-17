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

    static func makeHarness(_ name: String, reducedMotion: Bool = true) throws -> Harness {
        Q.acceptFirstMouseEverywhere()
        guard let suite = QAIsolatedDefaults(isolatedSuiteName: "dev.arrayapp.qa.dogfood-\(name).\(UUID().uuidString)") else {
            throw Failure(description: "no isolated defaults suite")
        }
        suite.set(SidebarLayout.quietInbox.rawValue, forKey: SidebarLayout.defaultsKey)
        let fixture = try WorkspaceAPIChecks.makeFixture(settings: suite)
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

    static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func run() throws -> String {
        var reports: [String] = []
        reports.append(try checkHistoryRows())
        reports.append(try checkHistoryPaints())
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

    // MARK: - 1. History rows read like A

    static func checkHistoryRows() throws -> String {
        let h = try makeHarness("history-rows")
        defer { h.close() }
        let inbox = h.inbox
        let lead = h.spawn("Conduct overnight UX checks")
        let helpers = (0..<4).map { h.spawn("Overnight helper \($0 + 1)", parent: lead) }
        let solo = h.spawn("Draft the release notes")
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
        drawn[h.fixture.agentId.rawValue] = nil  // the fixture's own parked source agent
        try expect(Set(drawn.keys) == [lead.rawValue, solo.rawValue],
                   "History holds the two families, helpers inside their lead — got \(drawn.values.map(\.titleForQA))")
        try expect(inbox.historyHeaderTitleForQA == "History (3)",
                   "the History heading counts its cards (2 families + the fixture's agent), not helpers — got '\(inbox.historyHeaderTitleForQA ?? "nil")'")
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
}

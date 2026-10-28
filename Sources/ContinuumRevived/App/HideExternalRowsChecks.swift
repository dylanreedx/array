import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// `--hide-external-rows-check [sheet-dir]`. Hiding sessions from elsewhere
/// on the Mac, through the PRODUCTION sidebar.
///
/// Boots the fixture, installs the sidebar the way boot does, publishes a made-up
/// discovery snapshot through the app's monitor, and then drives the real view:
/// the hover × hides a row and Undo brings it back; the row menu's Hide and ⌘Z do
/// the same; a hidden live session stays hidden across a store reload and a fresh
/// discovery pass; the scope menu's Hidden list shows one and Show all the rest.
/// Array's own agent offers no ×. The hidden set lives in a throwaway defaults
/// suite, never the standard domain.
///
/// With a folder argument it also writes the review sheet: the hover ×, the undo
/// notice and the Hidden list, light and dark.
@MainActor
enum HideExternalRowsChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    static func run(sheetDirectory: String?) throws -> String {
        let suiteName = "dev.arrayapp.qa.hide-external-rows.\(ProcessInfo.processInfo.processIdentifier)"
        guard let suite = UserDefaults(suiteName: suiteName) else { throw Failure(message: "no defaults suite") }
        suite.removePersistentDomain(forName: suiteName)
        defer { suite.removePersistentDomain(forName: suiteName) }

        let fixture = try WorkspaceAPIChecks.makeFixture()
        defer { fixture.tearDown() }
        let delegate = fixture.delegate
        delegate.externalSessionHiding = ExternalSessionHiding(defaults: suite)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let sidebar = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: 340, height: 900))
        window.contentView = sidebar
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        let appSupport = fixture.tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        try delegate.reconciledManagedSessionSource.reconcile(
            registry: try RegistryStore(applicationSupportDirectory: appSupport).loadOrEmpty(),
            reason: .continuumRestarted, now: Date())
        delegate.qaInstallWorkspaceSidebar(sidebar)
        delegate.qaRefreshAgentSurfaces()
        let inbox = sidebar.inboxForQA
        inbox.pinScrollerStyleForQA()
        inbox.setScope(.currentWorkspace)
        inbox.layoutForQA()
        let agentRow = fixture.agentId.rawValue
        try expect(inbox.rowIdsForQA.contains(agentRow), "precondition: the fixture agent has a row")

        let now = Date()
        func session(_ id: String, title: String, status: ExternalSessionStatus, host: String) -> ExternalAgentSession {
            ExternalAgentSession(
                provider: .claude, sessionId: id, pid: 4242, cwd: fixture.pbRoot.path, title: title, status: status,
                startedAt: now.addingTimeInterval(-900), statusSince: now.addingTimeInterval(-300),
                lastActivity: now.addingTimeInterval(-240), host: .app(host),
                transcriptURL: fixture.tempRoot.appendingPathComponent("\(id).jsonl"))
        }
        let cmux = session("s-cmux", title: "Fix flaky upload test", status: .waiting, host: "cmux")
        let ghostty = session("s-ghostty", title: "Port scanner spike", status: .idle, host: "Ghostty")
        let terminal = session("s-terminal", title: "Old README pass", status: .idle, host: "Terminal")
        func publish(_ sessions: [ExternalAgentSession]) {
            delegate.externalSessionMonitor.publish(ExternalSessionSnapshot(sessions: sessions))
            inbox.layoutForQA()
        }
        publish([cmux, ghostty, terminal])
        func rowId(_ session: ExternalAgentSession) -> UUID { ExternalSessionRows.rowId(forSessionKey: session.id) }
        func shown(_ session: ExternalAgentSession) -> Bool { inbox.rowIdsForQA.contains(rowId(session)) }
        try expect([cmux, ghostty, terminal].allSatisfy(shown), "precondition: every session is a row; got \(inbox.titlesForQA)")

        // Array's own agent: its clock SNOOZES (.plans/87, --sidebar-hide-any-row-check),
        // and never touches the hidden-sessions store.
        _ = inbox.hoverRowForQA(id: agentRow)
        inbox.layoutForQA()
        try expect(inbox.hoverActionsForQA(id: agentRow)?.titles.contains("Snooze") == true,
                   "an Array agent's row offers the clock that snoozes it; got \(inbox.hoverActionsForQA(id: agentRow)?.titles ?? [])")
        try expect(inbox.clickHoverSnoozeForQA(id: agentRow), "the agent's clock must be pressable")
        inbox.layoutForQA()
        try expect(delegate.externalSessionHiding.entries.isEmpty,
                   "an Array agent's clock snoozes; it hides nothing — got \(delegate.externalSessionHiding.entries.map(\.title))")
        try expect(inbox.clickUndoForQA(), "the snooze's Undo must be pressable")
        inbox.layoutForQA()
        try expect(inbox.rowIdsForQA.contains(agentRow), "Undo brings the agent back; got \(inbox.titlesForQA)")

        // The hover × hides, and the toast's Undo brings it back.
        try expect(inbox.hoverRowForQA(id: rowId(cmux)), "the cmux row must be hoverable")
        inbox.layoutForQA()
        let hoverTitles = inbox.hoverActionsForQA(id: rowId(cmux))?.titles ?? []
        try expect(hoverTitles.last == "Hide", "a session from elsewhere offers the × on hover; got \(hoverTitles)")
        if let sheetDirectory { try writeSheet(sidebar: sidebar, window: window, inbox: inbox, name: "1-hover", to: sheetDirectory) }
        try expect(inbox.clickHoverHideForQA(id: rowId(cmux)), "the hover × must be pressable")
        inbox.layoutForQA()
        try expect(!shown(cmux), "the × hides the row; got \(inbox.titlesForQA)")
        try expect(inbox.undoToastTextForQA == "Hidden · Undo", "hiding raises 'Hidden · Undo'; got '\(inbox.undoToastTextForQA)'")
        if let sheetDirectory { try writeSheet(sidebar: sidebar, window: window, inbox: inbox, name: "2-undo", to: sheetDirectory) }
        try expect(inbox.clickUndoForQA(), "Undo must be pressable")
        inbox.layoutForQA()
        try expect(shown(cmux), "Undo brings the row back; got \(inbox.titlesForQA)")
        try expect(delegate.externalSessionHiding.entries.isEmpty, "Undo forgets the hide")

        // The row menu's Hide, then ⌘Z.
        try expect(inbox.openRowMenuForQA(clickedRowId: rowId(ghostty)), "a session's row opens a menu")
        try expect(inbox.rowMenuTitlesForQA == ["Hide"], "a session's menu offers Hide; got \(inbox.rowMenuTitlesForQA)")
        try expect(inbox.pickRowMenuItemForQA(id: AgentInboxView.hideItemId), "Hide must be pickable")
        inbox.layoutForQA()
        try expect(!shown(ghostty), "the menu's Hide hides the row")
        inbox.pressCommandZForQA()
        inbox.layoutForQA()
        try expect(shown(ghostty), "⌘Z on the list undoes the hide; got \(inbox.titlesForQA)")

        // Hidden survives a reload of the store and a new discovery pass, even
        // when the session turns live.
        for target in [cmux, ghostty, terminal] {
            _ = inbox.hoverRowForQA(id: rowId(target))
            inbox.layoutForQA()
            try expect(inbox.clickHoverHideForQA(id: rowId(target)), "the × must be pressable on \(target.id)")
            inbox.layoutForQA()
        }
        try expect(![cmux, ghostty, terminal].contains(where: shown), "all three hidden; got \(inbox.titlesForQA)")
        let reloaded = ExternalSessionHiding(defaults: suite)
        try expect(reloaded.hiddenKeys == [cmux.id, ghostty.id, terminal.id],
                   "the hidden set is persisted; got \(reloaded.hiddenKeys)")
        delegate.externalSessionHiding = reloaded
        inbox.externalSessionHiding = reloaded
        var busy = cmux
        busy.status = .busy
        publish([busy, ghostty, terminal])
        try expect(![cmux, ghostty, terminal].contains(where: shown),
                   "a hidden session stays hidden after a reload and when it turns live; got \(inbox.titlesForQA)")

        // .plans/87: `Hidden (N)` under the list is the way back (it replaced the
        // scope menu's "Hidden from elsewhere" list): open it, Show one, Show all.
        // Driven through real events in --sidebar-hidden-footer-check.
        try expect(inbox.hiddenFooterTitleForQA == "Hidden (3)",
                   "the footer counts the three hidden sessions; got '\(inbox.hiddenFooterTitleForQA ?? "none")'")
        try expect(!inbox.scopeItemIdsForQA.contains("hidden:list"), "the scope menu no longer carries a Hidden list")
        inbox.toggleHiddenRevealed()
        inbox.layoutForQA()
        try expect([cmux, ghostty, terminal].allSatisfy(shown) && inbox.isRevealedHiddenForQA(id: rowId(terminal)),
                   "open, the footer draws each hidden session in place, dimmed; got \(inbox.titlesForQA)")
        if let sheetDirectory {
            try writeSheet(sidebar: sidebar, window: window, inbox: inbox, name: "3-hidden-footer", to: sheetDirectory)
        }
        try expect(inbox.clickHoverHideForQA(id: rowId(terminal)), "a revealed row's Show must be pressable")
        inbox.layoutForQA()
        try expect(!inbox.isRevealedHiddenForQA(id: rowId(terminal)) && delegate.externalSessionHiding.hiddenKeys == [cmux.id, ghostty.id],
                   "Show brings back that one session only; got \(delegate.externalSessionHiding.hiddenKeys)")
        try expect(inbox.clickShowAllHiddenForQA(), "Show all must be pressable")
        inbox.layoutForQA()
        try expect([cmux, ghostty, terminal].allSatisfy(shown), "Show all brings every session back; got \(inbox.titlesForQA)")
        try expect(inbox.hiddenFooterTitleForQA == nil, "with nothing hidden there is no footer")

        // A session discovery no longer reports is forgotten after a day.
        let ageing = ExternalSessionHiding(defaults: suite)
        ageing.hide([(key: "gone", title: "Gone"), (key: cmux.id, title: "kept")], now: now)
        ageing.noteDiscovered([cmux.id], now: now.addingTimeInterval(ExternalSessionHiding.forgetAfter + 60))
        try expect(ageing.hiddenKeys == [cmux.id], "an ended session drops out of the set; got \(ageing.hiddenKeys)")
        ageing.showAll()

        return "HideExternalRowsChecks: × and menu Hide remove a session's row, Undo and ⌘Z restore it, hidden survives a store reload "
            + "and a live turn, Hidden (N) shows one and Show all the rest, an Array agent's clock snoozes and hides nothing"
            + (sheetDirectory.map { " (sheet: \($0))" } ?? "")
    }

    /// One frame of the review sheet, light and dark.
    private static func writeSheet(
        sidebar view: NSView, window: NSWindow, inbox: AgentInboxView, name: String, to directory: String
    ) throws {
        let original = window.appearance
        defer { window.appearance = original; inbox.layoutForQA() }
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance)
            view.appearance = NSAppearance(named: appearance)
            if view.superview == nil { view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize) }
            inbox.layoutForQA()
            if let themed = view as? TokenThemed {
                NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance { themed.applyTokens() }
            }
            // Let the list's exit motion land before photographing it.
            if name == "2-undo" { RunLoop.main.run(until: Date().addingTimeInterval(0.6)) }
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw Failure(message: "could not snapshot \(name)")
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                throw Failure(message: "could not encode \(name)")
            }
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(suffix).png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }
}

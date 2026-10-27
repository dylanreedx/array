import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ObjectiveC

// Plan: .plans/87-sidebar-liveness/README.md (quick hide/show, Dylan 2026-10-27)
//
// The quick hide/show witnesses. Each one boots the production fixture, installs
// the sidebar the way boot does, publishes outside sessions through the app's own
// monitor and then drives the REAL `AgentInboxView` the way a person does: every
// click and key goes through `NSApp.sendEvent`, so the window hit-tests, AppKit
// routes the release to the view that took the press, and the table's own key
// handling runs. Settings live in a throwaway suite, never the standard domain.
@MainActor
enum QuickHideChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !condition() { throw Failure(description: message()) }
    }

    /// The user's window is key when they click it. Activating the check app
    /// would take the user's keyboard, so the window says it is key instead.
    final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    /// An inactive app swallows every press as an activation click unless the
    /// view accepts the first mouse; the user's app is active when they click.
    static func acceptFirstMouseEverywhere() {
        guard let method = class_getInstanceMethod(NSView.self, #selector(NSView.acceptsFirstMouse(for:))) else { return }
        let always: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
        method_setImplementation(method, imp_implementationWithBlock(always))
    }

    // MARK: - The production sidebar

    @MainActor
    struct Harness {
        let fixture: WorkspaceAPIChecks.Fixture
        let window: KeyWindow
        let sidebar: WorkspaceSidebarView
        let suite: QAIsolatedDefaults
        let sessions: [ExternalAgentSession]
        var delegate: AppDelegate { fixture.delegate }
        var inbox: AgentInboxView { sidebar.inboxForQA }
        var agentRow: UUID { fixture.agentId.rawValue }
        var workspaceA: UUID { fixture.workspaceWA }
        var workspaceB: UUID { fixture.workspaceWB }

        func session(_ id: String) -> ExternalAgentSession { sessions.first { $0.sessionId == id }! }
        func rowId(_ id: String) -> UUID { ExternalSessionRows.rowId(forSessionKey: session(id).id) }
        func shown(_ id: String) -> Bool { inbox.rowIdsForQA.contains(rowId(id)) }

        func publish(_ sessions: [ExternalAgentSession]) {
            delegate.externalSessionMonitor.publish(ExternalSessionSnapshot(sessions: sessions))
            inbox.layoutForQA()
        }

        func tearDown() {
            window.orderOut(nil)
            suite.removePersistentDomain(forName: suite.suiteDomainName)
            UserDefaults(suiteName: "dev.arrayapp.qa.hidden-external-sessions")?
                .removePersistentDomain(forName: "dev.arrayapp.qa.hidden-external-sessions")
            fixture.tearDown()
        }
    }

    /// Four outside sessions: tmux (busy) and cmux (idle) in workspace A's Pb,
    /// the Claude app (waiting on you) and Terminal (idle) in workspace B's Pc.
    static func makeHarness(name: String, width: CGFloat = 480, height: CGFloat = 900) throws -> Harness {
        acceptFirstMouseEverywhere()
        guard let suite = QAIsolatedDefaults(isolatedSuiteName: "dev.arrayapp.qa.quick-hide.\(name).\(UUID().uuidString)") else {
            throw Failure(description: "no isolated defaults suite")
        }
        let fixture = try WorkspaceAPIChecks.makeFixture(settings: suite)
        let delegate = fixture.delegate
        let hidingSuite = "dev.arrayapp.qa.quick-hide-hidden.\(name).\(UUID().uuidString)"
        delegate.externalSessionHiding = ExternalSessionHiding(defaults: UserDefaults(suiteName: hidingSuite)!)

        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let sidebar = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView = sidebar
        window.orderFrontOffscreenForChecks()
        // The app's key window is where `NSApp.sendEvent` delivers keys. Making it
        // key inside this (inactive) app does not activate it or take the user's
        // keyboard; a click would do the same.
        window.makeKey()
        let appSupport = fixture.tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        try delegate.reconciledManagedSessionSource.reconcile(
            registry: try RegistryStore(applicationSupportDirectory: appSupport).loadOrEmpty(),
            reason: .continuumRestarted, now: Date())
        delegate.qaInstallWorkspaceSidebar(sidebar)
        delegate.qaRefreshAgentSurfaces()
        let inbox = sidebar.inboxForQA
        inbox.pinScrollerStyleForQA()
        inbox.prefersReducedMotion = { true }
        inbox.hoverCardEnabled = false
        inbox.layoutForQA()

        let now = Date()
        func session(_ id: String, _ title: String, _ status: ExternalSessionStatus, _ host: ExternalSessionHost,
                     in root: URL) -> ExternalAgentSession {
            ExternalAgentSession(
                provider: .claude, sessionId: id, pid: 4242, cwd: root.path, title: title, status: status,
                startedAt: now.addingTimeInterval(-900), statusSince: now.addingTimeInterval(-300),
                lastActivity: now.addingTimeInterval(-240), host: host,
                transcriptURL: fixture.tempRoot.appendingPathComponent("\(id).jsonl"))
        }
        let sessions = [
            session("s-tmux", "Bisect the flaky upload test", .busy, .tmux, in: fixture.pbRoot),
            session("s-cmux", "Bump GRDB and fix warnings", .idle, .app("cmux"), in: fixture.pbRoot),
            session("s-claude", "Outline the launch thread", .waiting, .app("Claude app"), in: fixture.pcRoot),
            session("s-terminal", "Old README pass", .idle, .app("Terminal"), in: fixture.pcRoot),
        ]
        let harness = Harness(fixture: fixture, window: window, sidebar: sidebar, suite: suite, sessions: sessions)
        harness.publish(sessions)
        return harness
    }

    // MARK: - Real events

    private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, flags: NSEvent.ModifierFlags,
                              window: NSWindow) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1)
        else { throw Failure(description: "could not synthesise \(type)") }
        return event
    }

    /// A click at the middle of `view` (or at `local` in it), down and up through
    /// the application. The release is queued first, because a control tracks its
    /// own mouse-up with `nextEvent`; one that did not is handed it after.
    static func click(_ view: NSView, at local: NSPoint? = nil, flags: NSEvent.ModifierFlags = []) throws {
        // Find the view AFTER layout: a click on one a re-layout has detached
        // would land on whatever now sits at its old place.
        guard let window = view.window else { throw Failure(description: "\(type(of: view)) is in no window") }
        let point = view.convert(local ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        NSApp.postEvent(try mouse(.leftMouseUp, at: point, flags: flags, window: window), atStart: false)
        NSApp.sendEvent(try mouse(.leftMouseDown, at: point, flags: flags, window: window))
        while let pending = NSApp.nextEvent(matching: [.leftMouseUp], until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(pending)
        }
    }

    static func rightClick(_ view: NSView, at local: NSPoint? = nil) throws {
        guard let window = view.window else { throw Failure(description: "\(type(of: view)) is in no window") }
        let point = view.convert(local ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        NSApp.sendEvent(try mouse(.rightMouseDown, at: point, flags: [], window: window))
        NSApp.sendEvent(try mouse(.rightMouseUp, at: point, flags: [], window: window))
    }

    /// A key, through the application to the window's first responder.
    static func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = [], in window: NSWindow) throws {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
        else { throw Failure(description: "could not synthesise key \(code)") }
        NSApp.sendEvent(event)
    }

    // MARK: - Pictures

    /// Where the witnesses photograph the production sidebar: the folder after
    /// the flag, when one is given. Never part of what passes or fails.
    static var sheetDirectory: String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(where: { $0.hasPrefix("--sidebar-") && $0.hasSuffix("-check") }),
              args.indices.contains(index + 1), !args[index + 1].hasPrefix("-") else { return nil }
        return args[index + 1]
    }

    /// `name-light.png` and `name-dark.png` of `view` (and any open popover
    /// panel beside it), in the sheet folder.
    static func photograph(_ view: NSView, _ name: String, panel: NSView? = nil) {
        guard let directory = sheetDirectory, let window = view.window else { return }
        let original = window.appearance
        defer { window.appearance = original; view.layoutSubtreeIfNeeded() }
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance)
            panel?.window?.appearance = NSAppearance(named: appearance)
            panel?.appearance = NSAppearance(named: appearance)
            for themed in views(in: view, where: { $0 is TokenThemed }) + (panel.map { views(in: $0) { $0 is TokenThemed } } ?? []) {
                NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance { (themed as? TokenThemed)?.applyTokens() }
            }
            view.layoutSubtreeIfNeeded()
            guard let base = image(of: view) else { continue }
            var output = base
            if let panel, let list = image(of: panel) {
                output = composite(base, view: view, panel: panel, panelImage: list) ?? base
            }
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(suffix).png")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    private static func image(of view: NSView) -> CGImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    /// The sidebar with the popover's list drawn where its panel sits, the
    /// canvas colour behind both.
    private static func composite(_ base: CGImage, view: NSView, panel: NSView, panelImage: CGImage) -> CGImage? {
        guard let baseWindow = view.window, let panelWindow = panel.window else { return nil }
        let scale = CGFloat(base.width) / view.bounds.width
        let panelInScreen = panelWindow.convertToScreen(panel.convert(panel.bounds, to: nil))
        let viewInScreen = baseWindow.convertToScreen(view.convert(view.bounds, to: nil))
        let width = max(viewInScreen.width, panelInScreen.maxX - viewInScreen.minX) * scale
        let height = CGFloat(base.height)
        guard let cg = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let dark = baseWindow.appearance?.name == .darkAqua
        cg.setFillColor(dark ? CGColor(gray: 0.20, alpha: 1) : CGColor(gray: 0.86, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: width, height: height))
        cg.draw(base, in: CGRect(x: 0, y: 0, width: CGFloat(base.width), height: height))
        let rect = CGRect(x: (panelInScreen.minX - viewInScreen.minX) * scale,
                          y: (panelInScreen.minY - viewInScreen.minY) * scale,
                          width: CGFloat(panelImage.width), height: CGFloat(panelImage.height))
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -4 * scale), blur: 18 * scale,
                     color: CGColor(gray: 0, alpha: dark ? 0.55 : 0.22))
        cg.draw(panelImage, in: rect)
        cg.restoreGState()
        return cg.makeImage()
    }

    // MARK: - Finding views

    static func views(in root: NSView, where match: (NSView) -> Bool) -> [NSView] {
        var found: [NSView] = []
        func visit(_ view: NSView) {
            if match(view) { found.append(view) }
            view.subviews.forEach(visit)
        }
        visit(root)
        return found
    }

    static func view(_ identifier: String, in root: NSView) -> NSView? {
        views(in: root) { $0.accessibilityIdentifier() == identifier && !$0.isHiddenOrHasHiddenAncestor }.first
    }

    /// The pills on screen, in order: (id, value) — value is "on", "off" or
    /// "off, needs you".
    static func pills(_ inbox: AgentInboxView) -> [(id: String, value: String, label: String)] {
        let prefix = "ContinuumAgentInboxPill:"
        return views(in: inbox) { ($0.accessibilityIdentifier().hasPrefix(prefix)) && !$0.isHiddenOrHasHiddenAncestor }
            .sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
            .map { (String($0.accessibilityIdentifier().dropFirst(prefix.count)),
                    ($0.accessibilityValue() as? String) ?? "", $0.accessibilityLabel() ?? "") }
    }

    static func pill(_ id: String, in inbox: AgentInboxView) throws -> NSView {
        inbox.layoutForQA()
        guard let view = view("ContinuumAgentInboxPill:\(id)", in: inbox) else {
            throw Failure(description: "no pill '\(id)' on screen; pills: \(pills(inbox).map(\.id))")
        }
        return view
    }

    static func value(_ id: String, _ inbox: AgentInboxView) -> String? {
        pills(inbox).first { $0.id == id }?.value
    }

    // MARK: - Rows

    static func card(_ id: UUID, in inbox: AgentInboxView) -> AgentInbox96CellView? {
        inbox.layoutForQA()
        return inbox.qaMaterializedRowCells.compactMap { $0 as? AgentInbox96CellView }.first { $0.qaAgentID == id }
    }

    /// The row's × as drawn: the visible button labelled Hide.
    static func hideButton(_ id: UUID, in inbox: AgentInboxView) -> NSButton? {
        guard let card = card(id, in: inbox) else { return nil }
        return views(in: card) { $0 is NSButton && $0.accessibilityLabel() == "Hide" && !$0.isHiddenOrHasHiddenAncestor }
            .first as? NSButton
    }

    /// No row the list draws lies under the undo notice: every card, clipped to
    /// the list's visible area, misses the toast's frame.
    static func toastCoversNoRow(_ inbox: AgentInboxView) -> (Bool, String) {
        let toast = inbox.undoToastFrameForQA
        let list = inbox.listFrameForQA
        for cell in inbox.qaMaterializedRowCells {
            guard let view = cell as? NSView, !view.isHiddenOrHasHiddenAncestor else { continue }
            let visible = view.convert(view.bounds, to: inbox).intersection(list)
            if !visible.isNull, !visible.isEmpty, visible.intersects(toast) {
                return (false, "row \(cell.qaAgentID?.uuidString.prefix(8) ?? "?") at \(visible) under the toast \(toast)")
            }
        }
        let clear = inbox.isFlipped ? list.maxY <= toast.minY + 0.5 : list.minY >= toast.maxY - 0.5
        return (clear, "list \(list) toast \(toast)")
    }

    static func pressDelete(_ inbox: AgentInboxView) throws {
        inbox.window?.makeFirstResponder(inbox.tableForQA)
        try key(51, "\u{7F}", in: inbox.window!)
        inbox.layoutForQA()
    }

    static func pressUndo(_ inbox: AgentInboxView) throws {
        inbox.window?.makeFirstResponder(inbox.tableForQA)
        try key(6, "z", flags: .command, in: inbox.window!)
        inbox.layoutForQA()
    }

    // MARK: - 2. Hide any row

    /// `--sidebar-hide-any-row-check`. The × on any row and ⌫ on a selected one:
    /// a session from elsewhere hides, an Array agent snoozes for three hours or
    /// until it needs you (and comes back the moment it does); ⌘Z undoes either;
    /// the notice pushes the list up rather than covering a row; a selected row
    /// keeps its ×.
    static func runHideAnyRow() throws -> String {
        let h = try makeHarness(name: "hide-any-row")
        defer { h.tearDown() }
        let inbox = h.inbox
        let supervisor = h.delegate.qaAgentSupervisor
        inbox.setScope(.all)
        inbox.layoutForQA()
        try expect(inbox.rowIdsForQA.contains(h.agentRow), "precondition: the fixture agent is a row; got \(inbox.titlesForQA)")

        // Array agent: the hover × takes the Snooze pill's place.
        _ = inbox.hoverRowForQA(id: h.agentRow)
        guard let agentX = hideButton(h.agentRow, in: inbox) else {
            throw Failure(description: "an Array agent's row offers no × on hover; actions \(inbox.hoverActionsForQA(id: h.agentRow)?.titles ?? [])")
        }
        try expect(!(inbox.hoverActionsForQA(id: h.agentRow)?.titles ?? []).contains("Snooze"),
                   "the × replaces the Snooze pill — got \(inbox.hoverActionsForQA(id: h.agentRow)?.titles ?? [])")
        photograph(inbox, "2-hide-hover-agent")
        let before = Date()
        try click(agentX)
        inbox.layoutForQA()
        let until = supervisor.records[h.fixture.agentId]?.snoozedUntil
        try expect(until.map { abs($0.timeIntervalSince(before) - 3 * 3600) < 120 } == true,
                   "the × snoozes for three hours — snoozedUntil \(String(describing: until))")
        try expect(!inbox.rowIdsForQA.contains(h.agentRow), "the snoozed agent leaves the list — got \(inbox.titlesForQA)")
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "HH:mm"
        let wanted = "Snoozed until \(clock.string(from: until ?? before)) · or when it needs you · Undo"
        try expect(inbox.undoToastTextForQA == wanted, "the notice reads '\(wanted)' — got '\(inbox.undoToastTextForQA)'")
        let (clear, detail) = toastCoversNoRow(inbox)
        try expect(clear, "the notice pushes the list up and covers no row — \(detail)")
        photograph(inbox, "2-hide-snoozed-toast")
        try pressUndo(inbox)
        try expect(inbox.rowIdsForQA.contains(h.agentRow) && supervisor.records[h.fixture.agentId]?.snoozedUntil == nil,
                   "⌘Z wakes the agent and brings its row back — got \(inbox.titlesForQA)")
        try expect(inbox.undoToastTextForQA.isEmpty, "⌘Z takes the notice down")
        let listAfter = inbox.listFrameForQA
        try expect(inbox.isFlipped ? abs(listAfter.maxY - inbox.bounds.height) < 0.5 : listAfter.minY < 0.5,
                   "with the notice gone the list reaches the bottom again — list \(listAfter) in \(inbox.bounds)")

        // A selected row keeps its ×, without the pointer on it.
        try expect(inbox.selectRowForQA(id: h.agentRow), "the agent's row must be selectable")
        _ = inbox.hoverRowForQA(id: nil)
        try expect(hideButton(h.agentRow, in: inbox) != nil, "a selected row keeps its × with the pointer elsewhere")
        photograph(inbox, "2-hide-selected")

        // ⌫ on the selected agent: snoozed again, the same notice.
        try pressDelete(inbox)
        try expect(supervisor.records[h.fixture.agentId]?.snoozedUntil != nil && !inbox.rowIdsForQA.contains(h.agentRow),
                   "⌫ snoozes the selected agent — got \(inbox.titlesForQA)")
        try expect(inbox.undoToastTextForQA.hasSuffix("· or when it needs you · Undo"),
                   "⌫ raises the same notice — got '\(inbox.undoToastTextForQA)'")

        // Outside sessions: the × hides, ⌘Z restores; ⌫ hides, ⌘Z restores.
        _ = inbox.hoverRowForQA(id: h.rowId("s-tmux"))
        guard let tmuxX = hideButton(h.rowId("s-tmux"), in: inbox) else { throw Failure(description: "the tmux row offers no ×") }
        try click(tmuxX)
        inbox.layoutForQA()
        try expect(!h.shown("s-tmux") && inbox.undoToastTextForQA == "Hidden · Undo",
                   "the × hides an outside session — got \(inbox.titlesForQA), '\(inbox.undoToastTextForQA)'")
        try expect(toastCoversNoRow(inbox).0, "the Hidden notice covers no row — \(toastCoversNoRow(inbox).1)")
        photograph(inbox, "2-hide-outside-toast")
        try pressUndo(inbox)
        try expect(h.shown("s-tmux"), "⌘Z brings the session back — got \(inbox.titlesForQA)")
        try expect(inbox.selectRowForQA(id: h.rowId("s-cmux")), "the cmux row must be selectable")
        try pressDelete(inbox)
        try expect(!h.shown("s-cmux") && h.delegate.externalSessionHiding.isHidden(h.session("s-cmux").id),
                   "⌫ hides the selected session — got \(inbox.titlesForQA)")
        try pressUndo(inbox)
        try expect(h.shown("s-cmux"), "⌘Z brings it back — got \(inbox.titlesForQA)")

        // "…or when it needs you": the snoozed agent asks a question and is back.
        supervisor.qaDeliver(.userInputRequested(threadId: "quick-hide", requestId: "qh-1", questions: []),
                             to: h.fixture.agentId)
        h.delegate.qaRefreshAgentSurfaces()
        inbox.layoutForQA()
        try expect(inbox.rowIdsForQA.contains(h.agentRow), "a snoozed agent that needs you is back in the list — got \(inbox.titlesForQA)")
        try expect(supervisor.records[h.fixture.agentId]?.snoozedUntil != nil,
                   "…by the raised hand, with the snooze itself left in place")

        return "QuickHide hide-any-row: the × and ⌫ snooze an Array agent for 3h or until it needs you (it came back on a question) "
            + "and hide an outside session; ⌘Z undoes both; the notice pushes the list up; a selected row keeps its ×"
    }

    // MARK: - 3. Hidden (N)

    /// The opacity a label inside the card is really drawn at.
    static func drawnAlpha(of text: String, in card: NSView) -> CGFloat? {
        guard let label = views(in: card, where: { ($0 as? NSTextField)?.stringValue == text }).first else { return nil }
        var alpha: CGFloat = 1
        var view: NSView? = label
        while let current = view, current !== card.superview { alpha *= current.alphaValue; view = current.superview }
        return alpha
    }

    static func showButton(_ id: UUID, in inbox: AgentInboxView) -> NSButton? {
        guard let card = card(id, in: inbox) else { return nil }
        return views(in: card) { $0 is NSButton && $0.accessibilityLabel() == "Show" && !$0.isHiddenOrHasHiddenAncestor }
            .first as? NSButton
    }

    /// `--sidebar-hidden-footer-check`. `Hidden (N)` is pinned under the list and
    /// counts what opening it brings back; a click draws the hidden rows in place,
    /// dimmed, each with an eye Show pill, plus Show all; a second click folds them
    /// away; Show and Show all bring sessions back; the scope popover no longer
    /// carries a Hidden list.
    static func runHiddenFooter() throws -> String {
        let h = try makeHarness(name: "hidden-footer")
        defer { h.tearDown() }
        let inbox = h.inbox
        inbox.setScope(.all)
        inbox.undoToastDuration = 0.01
        inbox.layoutForQA()
        func footer() -> NSView? { view("ContinuumAgentInboxHiddenFooter", in: inbox) }
        try expect(footer() == nil, "nothing hidden, no footer")

        // Hide two sessions the user's way: ⌫ on one, the × on the other.
        try expect(inbox.selectRowForQA(id: h.rowId("s-tmux")), "the tmux row must be selectable")
        try pressDelete(inbox)
        _ = inbox.hoverRowForQA(id: h.rowId("s-terminal"))
        guard let x = hideButton(h.rowId("s-terminal"), in: inbox) else { throw Failure(description: "the Terminal row offers no ×") }
        try click(x)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        inbox.layoutForQA()
        try expect(!h.shown("s-tmux") && !h.shown("s-terminal"), "precondition: both sessions hidden — got \(inbox.titlesForQA)")
        guard let pinned = footer() else { throw Failure(description: "two hidden sessions and no Hidden footer") }
        try expect(inbox.hiddenFooterTitleForQA == "Hidden (2)", "the footer reads Hidden (2) — got '\(inbox.hiddenFooterTitleForQA ?? "none")'")
        let footerFrame = inbox.hiddenFooterFrameForQA
        try expect(abs(inbox.isFlipped ? footerFrame.maxY - inbox.bounds.height : footerFrame.minY) < 0.5
                   && (inbox.isFlipped ? inbox.listFrameForQA.maxY <= footerFrame.minY + 0.5 : inbox.listFrameForQA.minY >= footerFrame.maxY - 0.5),
                   "the footer is pinned under the list, not in it — footer \(footerFrame), list \(inbox.listFrameForQA)")
        try expect(!inbox.scopeItemIdsForQA.contains("hidden:list"),
                   "the footer replaces the scope menu's Hidden list — got \(inbox.scopeItemIdsForQA)")
        photograph(inbox, "3-hidden-collapsed")

        // Open: the hidden rows come back in place, dimmed, each with Show.
        try click(pinned, at: NSPoint(x: 40, y: pinned.bounds.midY))
        inbox.layoutForQA()
        try expect(h.shown("s-tmux") && h.shown("s-terminal"), "open, the hidden rows are drawn — got \(inbox.titlesForQA)")
        for id in ["s-tmux", "s-terminal"] {
            guard let card = card(h.rowId(id), in: inbox) else { throw Failure(description: "\(id) drew no card") }
            let alpha = drawnAlpha(of: h.session(id).title ?? "", in: card) ?? 1
            try expect(alpha < 0.5, "\(id) is dimmed in place — its title draws at \(alpha)")
            try expect(showButton(h.rowId(id), in: inbox) != nil, "\(id) carries an eye Show pill without hover")
        }
        let plain = drawnAlpha(of: h.session("s-cmux").title ?? "", in: try card(h.rowId("s-cmux"), in: inbox).orThrow("no cmux card")) ?? 0
        try expect(plain > 0.8, "a row that was never hidden keeps its own emphasis, undimmed — draws at \(plain)")
        guard let showAll = view("ContinuumAgentInboxHiddenShowAll", in: inbox) else {
            throw Failure(description: "the open footer offers no Show all")
        }
        photograph(inbox, "3-hidden-expanded")

        // Show one: it is a normal row again, and the footer counts one.
        try click(try showButton(h.rowId("s-tmux"), in: inbox).orThrow("the tmux row lost its Show"))
        inbox.layoutForQA()
        try expect(h.shown("s-tmux") && !inbox.isRevealedHiddenForQA(id: h.rowId("s-tmux"))
                   && !h.delegate.externalSessionHiding.isHidden(h.session("s-tmux").id),
                   "Show brings the session back for good")
        try expect(inbox.hiddenFooterTitleForQA == "Hidden (1)", "the footer counts one — got '\(inbox.hiddenFooterTitleForQA ?? "none")'")

        // A second click on the footer folds the hidden rows away again.
        try click(try footer().orThrow("the footer went away"), at: NSPoint(x: 40, y: InboxHiddenFooter.height / 2))
        inbox.layoutForQA()
        try expect(!h.shown("s-terminal") && view("ContinuumAgentInboxHiddenShowAll", in: inbox) == nil,
                   "clicking again collapses — got \(inbox.titlesForQA)")
        _ = showAll

        // Open again and Show all: every session back, no footer.
        try click(try footer().orThrow("the footer went away"), at: NSPoint(x: 40, y: InboxHiddenFooter.height / 2))
        try click(try view("ContinuumAgentInboxHiddenShowAll", in: inbox).orThrow("no Show all after reopening"))
        inbox.layoutForQA()
        try expect(["s-tmux", "s-terminal", "s-cmux", "s-claude"].allSatisfy(h.shown) && footer() == nil
                   && h.delegate.externalSessionHiding.entries.isEmpty,
                   "Show all brings every session back and the footer goes — got \(inbox.titlesForQA)")
        try expect(!inbox.isRevealedHiddenForQA(id: h.rowId("s-terminal")), "…undimmed")

        return "QuickHide hidden-footer: Hidden (N) pinned under the list; open draws hidden rows in place, dimmed, with Show; "
            + "Show and Show all bring sessions back; a second click folds them; the popover's Hidden list is gone"
    }

    // MARK: - 1. Toggle pills

    /// `--sidebar-pills-check`. One pill per workspace and per outside source,
    /// in a fixed order, counting top-level agents; a click toggles and is the
    /// scope popover's own set; Option-click solos; an off pill keeps a dot for
    /// what it hides that needs you; the row shows only with two or more pills;
    /// what does not fit folds into `+N`, whose checklist toggles and solos too;
    /// and both dimensions persist and come back through the boot path.
    static func runPills() throws -> String {
        var h = try makeHarness(name: "pills")
        defer { h.tearDown() }
        let inbox = h.inbox
        // A subagent under the fixture agent: a workspace pill counts its parent once.
        let child = h.delegate.qaAgentSupervisor.spawn(
            role: "Explore", prompt: nil, cwd: h.fixture.pbRoot, harness: .pi,
            model: "openai-codex/gpt-5.6-sol", thinking: "high",
            projectId: h.fixture.projectPb, projectRoot: h.fixture.pbRoot, parentAgentID: h.fixture.agentId)
        h.delegate.qaRefreshAgentSurfaces()
        inbox.setScope(.all)
        inbox.layoutForQA()
        try expect(inbox.rowIdsForQA.contains(h.agentRow) && ["s-tmux", "s-cmux", "s-claude", "s-terminal"].allSatisfy(h.shown),
                   "precondition: every agent and session is a row; got \(inbox.titlesForQA)")

        let a = "workspace:\(h.workspaceA.uuidString.lowercased())"
        let b = "workspace:\(h.workspaceB.uuidString.lowercased())"
        let order = [a, b, "source:Terminal", "source:Claude app", "source:cmux"]
        try expect(pills(inbox).map(\.id) == order,
                   "pills: one per workspace by name, then Terminal, Claude app, cmux — got \(pills(inbox).map(\.id))")
        try expect(pills(inbox).allSatisfy { $0.value == "on" }, "every pill starts on — got \(pills(inbox).map(\.value))")
        photograph(inbox, "1-pills-all-on")
        let labels = Dictionary(uniqueKeysWithValues: pills(inbox).map { ($0.id, $0.label) })
        try expect(labels[a] == "A, 3 agents" && labels[b] == "B, 2 agents",
                   "workspace pills count top-level agents (A: the agent, not its subagent, + tmux + cmux) — got \(labels)")
        try expect(labels["source:Terminal"] == "Terminal, 2 agents" && labels["source:cmux"] == "cmux, 1 agent",
                   "Terminal holds tmux and Terminal; cmux one — got \(labels)")
        _ = child

        // Click B: its rows go, its pill keeps a dot for the Claude app session waiting on you.
        try click(try pill(b, in: inbox))
        inbox.layoutForQA()
        try expect(!h.shown("s-claude") && !h.shown("s-terminal") && h.shown("s-tmux"),
                   "B off hides its rows only — got \(inbox.titlesForQA)")
        try expect(value(b, inbox) == "off, needs you", "an off pill keeps a needs-you dot — got \(value(b, inbox) ?? "nil")")
        photograph(inbox, "1-pills-b-off")
        let excludeB = InboxScope.normalized(InboxWorkspaceFilter(mode: .exclude, workspaces: [h.workspaceB], showsUnplaced: true))
        try expect(inbox.scope == excludeB, "the pill IS the popover's set: All but B — got \(inbox.scope.storageValue)")
        try expect(inbox.scopeTriggerTitleForQA == "All but B", "the trigger names the same set — got '\(inbox.scopeTriggerTitleForQA)'")
        try expect(WorkspaceSidebarConfig.resolveScope(defaults: h.suite) == excludeB,
                   "the pill's set is persisted like the scope — got \(WorkspaceSidebarConfig.resolveScope(defaults: h.suite).storageValue)")
        try click(try pill(b, in: inbox))
        inbox.layoutForQA()
        try expect(inbox.scope == .all && h.shown("s-claude"), "clicking B again shows it — got \(inbox.scope.storageValue)")

        // Option-click A: A alone, every source off.
        try click(try pill(a, in: inbox), flags: .option)
        inbox.layoutForQA()
        try expect(inbox.scope == .currentWorkspace, "Option-click solos A (the workspace on screen) — got \(inbox.scope.storageValue)")
        try expect(inbox.rowIdsForQA == [h.agentRow], "solo A shows A's own agents only — got \(inbox.titlesForQA)")
        try expect(pills(inbox).map(\.value) == ["on", "off, needs you", "off", "off, needs you", "off"],
                   "solo: A on, B and every source off, the Claude app's waiting session dotting both — got \(pills(inbox).map(\.value))")
        photograph(inbox, "1-pills-solo-a")
        try expect(Set(h.suite.stringArray(forKey: "continuum.workspaceSidebar.hiddenSources") ?? [])
                   == ["Terminal", "Claude app", "cmux"],
                   "hidden sources persist beside the scope — got \(h.suite.stringArray(forKey: "continuum.workspaceSidebar.hiddenSources") ?? [])")

        // A source back on: its session in A returns.
        try click(try pill("source:cmux", in: inbox))
        inbox.layoutForQA()
        try expect(h.shown("s-cmux") && !h.shown("s-tmux"), "cmux on brings back its row in A — got \(inbox.titlesForQA)")

        // Option-click Terminal: only tmux among everything in the workspace set.
        try click(try pill("source:Terminal", in: inbox), flags: .option)
        inbox.layoutForQA()
        try expect(inbox.rowIdsForQA == [h.rowId("s-tmux")],
                   "solo Terminal shows its sessions only, Array's agents included out — got \(inbox.titlesForQA)")
        try expect(value(a, inbox) == "off" && value("source:Terminal", inbox) == "on",
                   "soloing a source turns the workspace pills off — got \(pills(inbox).map(\.value))")
        // A workspace pill brings Array's agents back, for that workspace.
        try click(try pill(a, in: inbox))
        inbox.layoutForQA()
        try expect(Set(inbox.rowIdsForQA) == [h.agentRow, h.rowId("s-tmux")] && value(a, inbox) == "on",
                   "A on after a source solo shows A's agents and the soloed source — got \(inbox.titlesForQA)")

        // Back to everything: the popover's All agents, then the sources.
        try expect(inbox.chooseScopeItemForQA(id: InboxScope.all.storageValue), "All agents must be pickable")
        for source in ["source:Claude app", "source:cmux"] where value(source, inbox)?.hasPrefix("off") == true {
            try click(try pill(source, in: inbox))
        }
        inbox.layoutForQA()
        try expect(pills(inbox).allSatisfy { $0.value == "on" } && h.suite.stringArray(forKey: "continuum.workspaceSidebar.hiddenSources") == nil,
                   "everything on again, nothing stored — got \(pills(inbox).map(\.value))")

        // Narrow: what does not fit folds into +N, on one line, order kept.
        h.window.setContentSize(NSSize(width: 260, height: 900))
        h.sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
        inbox.layoutForQA()
        let narrow = pills(inbox).map(\.id)
        try expect(narrow.last == "more" && narrow.count < order.count + 1 && Array(order.prefix(narrow.count - 1)) == narrow.dropLast(),
                   "at 260pt the pills that do not fit fold into +N, in order — got \(narrow)")
        let tops = Set(views(in: inbox) { $0.accessibilityIdentifier().hasPrefix("ContinuumAgentInboxPill:") && !$0.isHiddenOrHasHiddenAncestor }
            .map { Int($0.convert($0.bounds, to: nil).minY) })
        try expect(tops.count == 1, "the pills stay on one line — got rows at \(tops)")
        inbox.presentsPillOverflowOffscreenForQA = true
        defer { inbox.dismissPillOverflowForQA() }
        try click(try pill("more", in: inbox))
        guard let list = inbox.pillOverflowListForQA else { throw Failure(description: "+N opened no checklist") }
        photograph(inbox, "1-pills-overflow", panel: list)
        let rest = Array(order.dropFirst(narrow.count - 1))
        try expect(list.qaItems.map(\.id) == rest, "+N lists the rest, in order — got \(list.qaItems.map(\.id)), wanted \(rest)")
        list.choose(id: "source:Claude app")
        inbox.layoutForQA()
        try expect(!h.shown("s-claude"), "unchecking Claude app in +N hides it — got \(inbox.titlesForQA)")
        try expect(value("more", inbox) == "on, needs you", "a hidden needs-you rides on +N — got \(value("more", inbox) ?? "nil")")
        try expect(inbox.pillOverflowListForQA?.qaItems.first { $0.id == "source:Claude app" }?.check == .off,
                   "the open checklist follows the toggle")
        list.pressAccessory(itemID: "source:cmux", accessoryID: "only")
        inbox.layoutForQA()
        try expect(inbox.rowIdsForQA == [h.rowId("s-cmux")], "Only in +N solos cmux — got \(inbox.titlesForQA)")
        inbox.dismissPillOverflowForQA()

        // A relaunch restores both dimensions through the boot path.
        let stored = Set(h.suite.stringArray(forKey: "continuum.workspaceSidebar.hiddenSources") ?? [])
        let relaunched = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: 480, height: 900))
        h.window.contentView = relaunched
        h.delegate.qaInstallWorkspaceSidebar(relaunched)
        h.delegate.qaRefreshAgentSurfaces()
        relaunched.inboxForQA.layoutForQA()
        try expect(relaunched.inboxForQA.hiddenSources == stored && relaunched.inboxForQA.rowIdsForQA == [h.rowId("s-cmux")],
                   "a relaunch restores the hidden sources \(stored) — got \(relaunched.inboxForQA.hiddenSources), rows \(relaunched.inboxForQA.titlesForQA)")

        // Two or more pills, or no row at all.
        let bare = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        let bareWindow = NSWindow(contentRect: bare.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        bareWindow.contentView = bare
        bareWindow.orderFrontOffscreenForChecks()
        defer { bareWindow.orderOut(nil) }
        let one = UUID(), two = UUID()
        bare.scopeCatalog = [.workspaceID(one, "Solo")]
        bare.reload(rows: [AgentInboxRow(id: UUID(), title: "Only one", projectName: "p", workspaceName: "Solo",
                                         workspaceId: one, state: .ready, createdAt: Date())])
        bare.layoutForQA()
        let listTopAlone = bare.listTopInsetForQA
        try expect(pills(bare).isEmpty, "one pill draws no pill row — got \(pills(bare).map(\.id))")
        bare.scopeCatalog = [.workspaceID(one, "Solo"), .workspaceID(two, "Second")]
        bare.layoutForQA()
        try expect(pills(bare).count == 2 && bare.listTopInsetForQA > listTopAlone,
                   "two pills draw the row, and the list starts below it — got \(pills(bare).map(\.id))")

        return "QuickHide pills: workspaces then sources in a fixed order with top-level counts; click toggles the popover's own set, "
            + "Option-click solos; an off pill keeps its needs-you dot; +N folds the rest into a checklist that toggles and solos; "
            + "both dimensions persist and come back on a relaunch; the row needs two pills"
    }
}

extension Optional {
    func orThrow(_ message: String) throws -> Wrapped {
        guard let value = self else { throw QuickHideChecks.Failure(description: message) }
        return value
    }
}

import AppKit
import ContinuumRevivedCore
import ObjectiveC

/// Renaming an agent from its tile, the user's way: every press and key goes
/// through `NSApp.sendEvent` into a production-mounted canvas, with the app's
/// tile focus monitor installed, so the window's hit-test, the title bar's
/// routing and the mouse-up focus pass all run (the 0.7.31 lesson, see
/// `CanvasPointerPathChecks`). Outcomes are read from the record, the store,
/// the production sidebar row and the drawn title.
@MainActor
enum AgentTileRenameChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    private static func acceptFirstMouseEverywhere() {
        guard let method = class_getInstanceMethod(NSView.self, #selector(NSView.acceptsFirstMouse(for:))) else { return }
        let always: @convention(block) (NSView, NSEvent?) -> Bool = { _, _ in true }
        method_setImplementation(method, imp_implementationWithBlock(always))
    }

    private static var failures: [String] = []
    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { failures.append(message()) }
    }

    static func run() async throws -> String {
        acceptFirstMouseEverywhere()
        failures = []
        let agentTile = TileInsertSlideChecks.tileA
        let fixture = try TileInsertSlideChecks.makeFixture("agent-rename")
        defer { fixture.dispose() }
        let root = fixture.projectRoots[WorkspaceInvariantsFixture.projectA1]!
        let projectStore = ProjectStore(projectRoot: root)
        var state = try projectStore.loadCanvas()
        guard let index = state.tiles.firstIndex(where: { $0.id == agentTile }) else {
            throw Failure(description: "fixture: tile A missing")
        }
        state.tiles[index].kind = .managedAgent
        state.tiles[index].metadata = TileMetadata(launchProfileId: "managed-agent", projectRelativeCwd: ".")
        // Below the seeded row, clear of every other tile, at a typical width.
        state.tiles[index].frame = TileFrame(x: 440, y: 600, width: 420, height: 280)
        try projectStore.saveCanvas(state)
        let appSupport = fixture.appSupport
        var agent: AgentID?
        fixture.configureMount = { delegate, _ in
            delegate.agentSupervisor = AgentSupervisor(
                store: AgentStore(applicationSupportDirectory: appSupport),
                makeRunner: { _ in ScriptedAgentRunner(script: [], holdUntilStopped: true) })
            agent = delegate.agentSupervisor.spawn(
                role: nil, prompt: nil, cwd: root, harness: .claudeCode,
                model: "fixture/rename", thinking: "medium",
                projectId: WorkspaceInvariantsFixture.projectA1, projectRoot: root, tileId: agentTile)
        }
        try fixture.mount()
        let mounted = try fixture.requireMounted("agent rename")
        guard let agentID = agent else { throw Failure(description: "fixture: no agent") }
        let canvas = mounted.canvas
        let delegate = mounted.delegate
        let supervisor = delegate.agentSupervisor
        canvas.setViewport(CanvasViewport(x: 300, y: 250, zoom: 1))
        let window = KeyWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        window.makeKey()
        defer { window.orderOut(nil) }
        delegate.wireManagedAgentTile(agentTile, agentID: agentID)
        delegate.qaInstallTileFocusMonitor()
        defer { delegate.qaRemoveTileFocusMonitor() }
        let sidebar = WorkspaceSidebarView(frame: NSRect(x: 0, y: 0, width: WorkspaceSidebarConfig.defaultWidth, height: 2000))
        // Boot's managed-session sweep, without which the inbox publishes nothing.
        try delegate.reconciledManagedSessionSource.reconcile(
            registry: try RegistryStore(applicationSupportDirectory: appSupport).loadOrEmpty(),
            reason: .continuumRestarted, now: Date())
        delegate.qaInstallWorkspaceSidebar(sidebar)
        delegate.qaRefreshAgentSurfaces()
        canvas.layoutSubtreeIfNeeded()
        guard let tile = canvas.tileView(for: agentTile) as? ManagedAgentTileNSView,
              let bar = tile.qaTitleBarView else {
            throw Failure(description: "production mount did not hydrate the agent tile")
        }
        // Keep the real controls live: the check's pointer is nowhere near.
        ManagedAgentTileNSView.qaPointerInside = { _ in true }
        defer { ManagedAgentTileNSView.qaPointerInside = nil }
        tile.wakeChrome()
        canvas.layoutSubtreeIfNeeded()

        func pump(_ seconds: TimeInterval = 0.02) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint, clicks: Int) {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)
            else { return }
            NSApp.sendEvent(event)
        }
        func key(_ characters: String, code: UInt16) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code) else { return }
            NSApp.sendEvent(event)
        }
        func type(_ text: String) {
            for character in text { key(String(character), code: character == " " ? 49 : 0) }
        }
        func enter() { key("\r", code: 36); pump() }
        func escape() { key("\u{1b}", code: 53); pump() }
        /// A point on the drawn title, in window space.
        func titlePoint() -> NSPoint {
            let rect = tile.titleRectInTileSpaceForQA
            return tile.convert(NSPoint(x: rect.minX + min(40, rect.width / 3), y: rect.midY), to: nil)
        }
        func doubleClickTitle() {
            let point = titlePoint()
            mouse(.leftMouseDown, point, clicks: 1)
            mouse(.leftMouseUp, point, clicks: 1)
            mouse(.leftMouseDown, point, clicks: 2)
            mouse(.leftMouseUp, point, clicks: 2)
            pump()
            canvas.layoutSubtreeIfNeeded()
        }
        func editorHasKeyboard() -> Bool {
            guard let field = tile.qaTitleEditor, let editor = field.currentEditor() else { return false }
            return window.firstResponder === editor
        }
        func name() -> String? { supervisor.records[agentID]?.displayName }
        func row() -> String? { sidebar.inboxForQA.pushedRowForQA(id: agentID.rawValue)?.title }
        func title() -> String? { tile.chromeSnapshot?.title }
        func stored() -> AgentRecord? { try? AgentStore(applicationSupportDirectory: appSupport).load(id: agentID) }

        let original = name()
        check(original != nil && row() == supervisor.records[agentID]?.humanDisplayName,
              "fixture: sidebar row \(String(describing: row())) must show the record's name \(String(describing: original))")

        // 1. A single click on the title focuses; it does not rename.
        let point = titlePoint()
        mouse(.leftMouseDown, point, clicks: 1)
        mouse(.leftMouseUp, point, clicks: 1)
        pump()
        check(tile.qaTitleEditor == nil, "a single click on the title opened the rename field")

        // 2. Double-click, type, Enter: record, store, row and title all follow.
        doubleClickTitle()
        check(tile.qaTitleEditor != nil, "double-clicking the title opened no rename field")
        check(editorHasKeyboard(), "the rename field does not hold the keyboard after the double-click's mouse-up")
        check(tile.qaTitleEditor?.stringValue == supervisor.records[agentID]?.humanDisplayName,
              "the field opened with \(String(describing: tile.qaTitleEditor?.stringValue)), not the agent's name")
        if let field = tile.qaTitleEditor, let editor = field.currentEditor() {
            check(editor.selectedRange.length == (field.stringValue as NSString).length, "the field must open with the name selected")
        }
        type("Parser flake hunt")
        try captureEditor(tile: tile, window: window, canvas: canvas, label: "field")
        enter()
        check(tile.qaTitleEditor == nil, "Enter left the rename field open")
        check(name() == "Parser flake hunt" && supervisor.records[agentID]?.displayNameSource == .manual,
              "Enter did not rename the record as manual: \(String(describing: name())) / \(String(describing: supervisor.records[agentID]?.displayNameSource))")
        check(stored()?.displayName == "Parser flake hunt" && stored()?.displayNameSource == .manual,
              "the rename was not persisted: \(String(describing: stored()?.displayName))")
        pump(0.2)
        check(row() == "Parser flake hunt", "the sidebar row still reads \(String(describing: row()))")
        check(title() == "Agent · Parser flake hunt", "the tile title reads \(String(describing: title()))")

        // 3. Escape cancels whatever was typed.
        doubleClickTitle()
        type("Discard me")
        escape()
        check(tile.qaTitleEditor == nil, "Escape left the rename field open")
        check(name() == "Parser flake hunt" && title() == "Agent · Parser flake hunt",
              "Escape renamed the agent to \(String(describing: name()))")

        // 4. An empty or whitespace-only name is refused; the old one stays.
        doubleClickTitle()
        key("\u{7f}", code: 51)
        enter()
        check(name() == "Parser flake hunt", "an emptied field renamed the agent to \(String(describing: name()))")
        doubleClickTitle()
        type("   ")
        enter()
        check(name() == "Parser flake hunt" && stored()?.displayName == "Parser flake hunt",
              "a whitespace-only name renamed the agent to \(String(describing: name()))")

        // 5. The tile's action menu: Rename opens the same field.
        guard let button = tile.titleBarActionsButtonForQA else {
            throw Failure(description: "the agent tile has no actions button")
        }
        check(button.accessibilityPerformPress(), "AX pressing Agent actions did not open the menu")
        guard let controller = tile.qaActionsMenuController, controller.isPresented,
              let list = controller.qaPopovers.first?.listView,
              let renameIndex = list.items.firstIndex(where: { $0.title == "Rename" }),
              let rows = list.accessibilityChildren() as? [NSView], rows.indices.contains(renameIndex) else {
            throw Failure(description: "the agent actions menu has no rendered Rename row")
        }
        try captureMenu(list: list, label: "menu")
        check(rows[renameIndex].accessibilityPerformPress(), "pressing the Rename row did nothing")
        pump()
        check(!controller.isPresented, "choosing Rename left the menu open")
        check(tile.qaTitleEditor != nil && editorHasKeyboard(), "the Rename item did not open a focused rename field")
        // `NSApp.sendEvent` delivers keys to the app's key window, and this
        // inactive check app leaves that on the closed menu panel; an active app
        // hands key back to the canvas window as the panel closes.
        window.makeKey()
        type("Renamed from the menu")
        enter()
        check(name() == "Renamed from the menu" && stored()?.displayName == "Renamed from the menu",
              "the menu rename did not land: \(String(describing: name()))")
        pump(0.2)
        check(row() == "Renamed from the menu" && title() == "Agent · Renamed from the menu",
              "row/title after menu rename: \(String(describing: row())) / \(String(describing: title()))")

        // 6. A relaunch reads the same name from disk.
        let relaunched = AgentSupervisor(store: AgentStore(applicationSupportDirectory: appSupport),
                                         makeRunner: { _ in ScriptedAgentRunner(script: []) })
        _ = relaunched.restore()
        check(relaunched.records[agentID]?.displayName == "Renamed from the menu"
              && relaunched.records[agentID]?.displayNameSource == .manual,
              "a relaunch restored \(String(describing: relaunched.records[agentID]?.displayName))")

        guard failures.isEmpty else {
            throw Failure(description: "\(failures.count) failed:\n  " + failures.joined(separator: "\n  "))
        }
        return "double-click/Enter, Escape, empty and whitespace refusal, menu Rename, row/title/store/relaunch"
    }

    private static func artifactsDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: "qa-runs/agent-tile-rename", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The open field over the title bar, light and dark.
    private static func captureEditor(tile: TileNSView, window: NSWindow, canvas: NSView, label: String) throws {
        let directory = try artifactsDirectory()
        let band = tile.convert(NSRect(x: 0, y: 0, width: tile.bounds.width, height: tile.chromeBarHeight * 3), to: canvas)
            .insetBy(dx: -12, dy: -12).intersection(canvas.bounds)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            canvas.layoutSubtreeIfNeeded()
            canvas.displayIfNeeded()
            guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: band) else { continue }
            canvas.cacheDisplay(in: band, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("\(label)-\(name).png"))
        }
        window.appearance = nil
    }

    /// The shared Choice menu with its Rename row, light and dark.
    private static func captureMenu(list: NSView, label: String) throws {
        let directory = try artifactsDirectory()
        guard let panel = list.window, let content = panel.contentView else { return }
        let original = panel.appearance
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            panel.appearance = NSAppearance(named: appearance)
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { continue }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("\(label)-\(name).png"))
        }
        panel.appearance = original
    }
}

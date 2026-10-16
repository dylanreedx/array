import AppKit
import ContinuumRevivedCore
import Foundation
import WebKit

/// The mounted main window the Settings witnesses open Settings in: the
/// production window builder (`makeWorkspaceWindow`) around a canvas mounted by
/// `mountWorkspaceSceneAtBoot`, with a real Ghostty terminal tile (a Metal
/// surface running `/bin/cat`, never tmux) and a real WKWebView browser tile, so
/// "Settings sits above everything" is asserted against the views that have
/// historically refused to sit under anything.
///
/// The window is made borderless and parked off every display
/// (`orderFrontOffscreenForChecks`), and every preference Settings writes goes
/// to a private suite deleted at teardown.
@MainActor
final class SettingsCheckFixture {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    let delegate: AppDelegate
    let window: NSWindow
    let canvas: CanvasNSView
    let defaults: UserDefaults
    let suiteName: String
    let terminalTileId: UUID
    let browserTileId: UUID
    private let tempRoot: URL
    private let browserEngine: BrowserEngineContext
    private let ghostty: GhosttyRuntimeContext
    private let terminalRuntime: GhosttyTerminalRuntime
    private let browserRuntime: WKWebViewBrowserRuntime
    private var torn = false

    init(label: String) throws {
        let fileManager = FileManager.default
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let workspaceId = UUID()
        let projectId = UUID()
        let zoneId = UUID()
        tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("settings-\(label)-\(UUID().uuidString)", isDirectory: true)
        let root = tempRoot.appendingPathComponent("Alpha", isDirectory: true)
        let appSupport = tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        for dir in [root, appSupport] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        suiteName = "continuum.settings.\(label).\(UUID().uuidString)"
        guard let suite = QAIsolatedDefaults(isolatedSuiteName: suiteName) else {
            throw Failure(message: "could not create the isolated defaults suite")
        }
        defaults = suite

        let project = Project(
            id: projectId, name: "Alpha", rootPath: root.path, createdAt: now, updatedAt: now,
            defaultLaunchProfileId: "shell", editorPreference: .auto,
            settings: ProjectSettings(
                restorePolicy: .restoreDescriptors,
                browserStoragePolicy: .perProject,
                terminalClosePolicy: .askWhenRunning))
        let store = ProjectStore(projectRoot: root)
        try store.saveProject(project)
        try store.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
        let document = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            zones: [ZonePlacement(
                zoneId: zoneId, projectId: projectId,
                origin: ZonePoint(x: 40, y: 40), size: ZoneSize(width: 1_100, height: 640),
                color: "blue", collapsed: false, hydrationPolicy: .automatic)],
            zoneZOrder: [zoneId],
            lastActiveZoneId: zoneId)
        try WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: appSupport).save(document)
        var registry = Registry.empty()
        registry.lastActiveWorkspaceId = workspaceId
        registry.workspaces = [WorkspaceEntry(
            id: workspaceId, name: "Default", projectIds: [projectId], createdAt: now, updatedAt: now)]
        registry.projects = [ProjectEntry(
            id: projectId, name: "Alpha", rootPath: root.path, workspaceId: workspaceId,
            lastOpenedAt: now, pinned: false, missing: false)]
        let registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        try registryStore.save(registry)

        browserEngine = BrowserEngineContext()
        let zoneRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { id in
            guard id == projectId else { throw Failure(message: "unexpected project \(id)") }
            return ZoneRuntimeController(projectRoot: root, projectStore: store, project: project)
        })
        let bootCanvasState = try store.loadCanvas()
        canvas = CanvasNSView(
            canvasState: bootCanvasState,
            activeZone: document.zones.first,
            zoneRenderModels: document.zones.map {
                CanvasNSView.ZoneRenderModel(placement: $0, displayName: "Alpha")
            })
        canvas.frame = CGRect(x: 0, y: 0, width: 1_280, height: 800)

        delegate = AppDelegate()
        delegate.qaSettingsDefaults = defaults
        delegate.qaSettingsCompanionEnabled = false
        let runtime = WorkspaceRuntime(
            boot: try zoneRegistry.acquire(projectId: projectId),
            workspaceId: workspaceId, document: document, registry: zoneRegistry,
            focusBroker: delegate.qaFocusBroker, registryStore: registryStore,
            ghostty: nil, browserEngine: browserEngine)
        delegate.qaPrepareForBootMountCheck(
            canvas: canvas, browserEngine: browserEngine, runtime: runtime, registryStore: registryStore)
        delegate.agentSupervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: tempRoot.appendingPathComponent("Agents", isDirectory: true)),
            makeRunner: { _ in ScriptedAgentRunner(script: []) })
        let bootSpawner = TileSpawner(
            canvasView: canvas, ghostty: nil, browserEngine: browserEngine,
            projectStore: store, project: project)
        try delegate.mountWorkspaceSceneAtBoot(
            canvasView: canvas, spawner: bootSpawner, projectStore: store,
            canvasState: bootCanvasState, installsGlobalEventMonitors: false)

        // The PRODUCTION window and content view, made borderless only so it can be
        // parked off every display (a titled window is constrained to a screen).
        window = delegate.makeWorkspaceWindow(canvasView: canvas, title: "Array")
        window.styleMask = [.borderless]
        window.isReleasedWhenClosed = false
        window.orderFrontOffscreenForChecks()
        delegate.qaAttachWindowInstallingHotkeyMonitor(window)

        // A real Ghostty terminal (Metal surface) and a real WKWebView browser.
        ghostty = try GhosttyRuntimeContext()
        terminalTileId = UUID()
        var terminalTile = Tile(
            id: terminalTileId, kind: .terminal, title: "SETTINGS_TERMINAL",
            frame: TileFrame(x: 80, y: 80, width: 520, height: 360),
            zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        terminalTile.zoneId = zoneId
        terminalRuntime = GhosttyTerminalRuntime(
            tileId: terminalTileId, title: "settings-terminal",
            launchProfile: LaunchProfile(
                command: "/bin/cat", arguments: [], cwd: tempRoot.path, title: "settings-terminal"),
            ghostty: ghostty)
        let terminalView = TerminalTileNSView(tile: terminalTile, runtime: terminalRuntime)
        guard case .zoneLayer = canvas.installProjectTile(tileView: terminalView, for: terminalTile, targetZoneId: zoneId, arrangeAfterSpawn: false) else {
            throw Failure(message: "fixture: the terminal tile did not install into its zone layer")
        }
        browserTileId = UUID()
        var browserTile = Tile(
            id: browserTileId, kind: .browser, title: "SETTINGS_BROWSER",
            frame: TileFrame(x: 640, y: 80, width: 460, height: 360),
            zPosition: .fromLegacyRank(2), runtimeRef: nil, metadata: TileMetadata(url: "about:blank"))
        browserTile.zoneId = zoneId
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        browserRuntime = WKWebViewBrowserRuntime(
            id: UUID(), tileId: browserTileId,
            webView: WKWebView(frame: .zero, configuration: configuration),
            initialURL: "about:blank")
        let browserView = BrowserTileNSView(tile: browserTile, runtime: browserRuntime)
        guard case .zoneLayer = canvas.installProjectTile(tileView: browserView, for: browserTile, targetZoneId: zoneId, arrangeAfterSpawn: false) else {
            throw Failure(message: "fixture: the browser tile did not install into its zone layer")
        }
        window.contentView?.layoutSubtreeIfNeeded()
        pump(0.1)
    }

    func pump(_ seconds: TimeInterval = 0.05) {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// A keyDown through the production route: `NSApp.sendEvent` → the app's local
    /// keyDown monitor → `handleHotkey`, then normal dispatch if it passes.
    func sendKey(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) throws {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode) else {
            throw Failure(message: "could not synthesize key \(keyCode)")
        }
        NSApp.sendEvent(event)
        pump()
    }

    /// A left click delivered to the window at a point in window coordinates.
    func click(atWindowPoint point: NSPoint) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                throw Failure(message: "could not synthesize a click")
            }
            window.sendEvent(event)
        }
        pump()
    }

    func tileView(_ id: UUID) -> TileNSView? { canvas.tileView(for: id) }

    func tearDown() {
        guard !torn else { return }
        torn = true
        terminalRuntime.terminate(policy: .force)
        (tileView(terminalTileId) as? TerminalTileNSView)?.hostView.detachRuntime()
        browserRuntime.terminate(policy: .requestClose)
        window.orderOut(nil)
        browserEngine.shutdown()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempRoot)
    }
}

/// `--settings-modal-check` — Settings is an in-window modal, not a window.
///
/// Opened through the real ⌘, key route in the production window: no window is
/// created, the overlay is the window content's top-most subview over a live
/// Metal terminal and a WKWebView, ⌘, focuses rather than duplicating or
/// toggling, app shortcuts are suppressed while it is open, and each of the four
/// ways out (Esc, ⌘W, the scrim, the close button) closes it, fires `onClose`
/// once and returns focus to the tile that had it. The last pane comes back.
@MainActor
enum SettingsModalChecks {
    static let overlayIdentifier = SettingsOverlayView.identifier

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SettingsCheckFixture.Failure(message: message) }
    }

    static func run() throws {
        let standardGuard = QAStandardDefaultsGuard(keys: [SettingsModel.lastPaneKey, WorkspaceSidebarConfig.visibleKey])
        let fixture = try SettingsCheckFixture(label: "modal")
        defer { fixture.tearDown() }
        let delegate = fixture.delegate
        guard let content = fixture.window.contentView else {
            throw SettingsCheckFixture.Failure(message: "the main window has no content view")
        }
        let windowsBefore = Set(NSApp.windows.map(ObjectIdentifier.init))
        func newWindows() -> [NSWindow] {
            // The system's text-input window (`TUINSWindow`) appears whenever ANY field
            // takes focus; it is AppKit's, not Settings', and is the only exclusion.
            NSApp.windows.filter {
                !windowsBefore.contains(ObjectIdentifier($0)) && !String(describing: type(of: $0)).hasPrefix("TUI")
            }
        }
        func overlays() -> [NSView] { content.subviews.filter { $0.accessibilityIdentifier() == overlayIdentifier } }
        func openWithCommandComma() throws { try fixture.sendKey(keyCode: 43, characters: ",", modifiers: [.command]) }

        // Focus starts on the terminal tile, as it would after a click.
        _ = delegate.qaFocusBroker.requestFocus(.tile(fixture.terminalTileId), reason: .userClick)
        let focusedBefore = delegate.qaFocusBroker.activeSurface
        try expect(focusedBefore == .tile(fixture.terminalTileId), "precondition: the terminal tile must hold focus")

        // 1. ⌘, through the production key route opens Settings INSIDE the window.
        try openWithCommandComma()
        try expect(newWindows().isEmpty,
                   "⌘, must not create a window; it created \(newWindows().map { "\(type(of: $0)) '\($0.title)'" })")
        try expect(overlays().count == 1, "⌘, must mount exactly one Settings overlay in the main window; found \(overlays().count)")
        try expect(content.subviews.last === overlays().first,
                   "the Settings overlay must be the top-most subview of the window content")
        try expect(delegate.qaFocusBroker.activeSurface == .modal(.settings),
                   "Settings must own focus through the broker; active=\(String(describing: delegate.qaFocusBroker.activeSurface))")
        guard let modal = delegate.qaSettingsModal, let overlay = modal.overlay else {
            throw SettingsCheckFixture.Failure(message: "the app holds no Settings modal after ⌘,")
        }

        // 2. The scrim covers the whole content, above the Metal terminal, the
        // WKWebView, the canvas toolbar and the sidebar: every point hits Settings.
        try expect(overlay.frame == content.bounds, "the scrim must cover the window content; \(overlay.frame) vs \(content.bounds)")
        let card = overlay.card.frame
        try expect(card.width <= SettingsOverlayView.preferredCardSize.width && card.minX >= SettingsOverlayView.margin
                   && card.minY >= SettingsOverlayView.margin, "the card must keep its margins: \(card) in \(content.bounds)")
        func hitsOverlay(_ point: NSPoint) -> Bool {
            var view = content.hitTest(point)
            while let current = view { if current === overlay { return true }; view = current.superview }
            return false
        }
        for (name, id) in [("terminal", fixture.terminalTileId), ("browser", fixture.browserTileId)] {
            guard let tile = fixture.tileView(id), tile.window === fixture.window else {
                throw SettingsCheckFixture.Failure(message: "the \(name) tile is not in the window")
            }
            let center = tile.convert(NSPoint(x: tile.bounds.midX, y: tile.bounds.midY), to: content)
            try expect(hitsOverlay(center), "a point on the \(name) tile must hit Settings, not the tile")
        }
        try expect(fixture.tileView(fixture.terminalTileId)?.isDescendant(of: overlay) == false, "tiles stay under, not inside, Settings")
        for corner in [NSPoint(x: 4, y: 4), NSPoint(x: content.bounds.maxX - 4, y: content.bounds.maxY - 4),
                       NSPoint(x: 4, y: content.bounds.maxY - 4)] {
            try expect(hitsOverlay(corner), "the scrim must cover \(corner) (sidebar, top bar, toolbar)")
        }

        // The card follows the window: preferred size when there is room, ≥32pt
        // margins while it shrinks, the margins giving way below the minimum.
        let sizes: [(NSSize, NSSize)] = [
            (NSSize(width: 1_280, height: 800), NSSize(width: 880, height: 620)),
            (NSSize(width: 760, height: 560), NSSize(width: 696, height: 496)),
            (NSSize(width: 520, height: 380), NSSize(width: 520, height: 380)),
        ]
        for (bounds, expected) in sizes {
            let frame = SettingsOverlayView.cardFrame(in: NSRect(origin: .zero, size: bounds))
            try expect(frame.size == expected, "card in \(bounds) must be \(expected), got \(frame.size)")
        }
        let originalSize = fixture.window.frame.size
        fixture.window.setContentSize(NSSize(width: 900, height: 600))
        fixture.pump()
        try expect(overlay.frame == content.bounds && overlay.card.frame.width == 900 - 64 && overlay.card.frame.height == 600 - 64,
                   "the modal must follow a window resize; overlay \(overlay.frame) card \(overlay.card.frame)")
        fixture.window.setContentSize(originalSize)
        fixture.pump()

        // 3. ⌘, again focuses the same modal: one overlay, no window, no toggle.
        try openWithCommandComma()
        try expect(overlays().count == 1 && delegate.qaSettingsModal === modal && newWindows().isEmpty,
                   "a second ⌘, must keep exactly one Settings, open")
        try expect(modal.searchField.map { fixture.window.firstResponder === $0.currentEditor() } == true,
                   "⌘, on an open Settings must focus its search field")

        // 4. App shortcuts are suppressed: ⌘1-⌘4 spawn nothing; ⌘K opens nothing.
        let tilesBefore = fixture.canvas.allWorkspaceTiles().count
        for (keyCode, digit) in [(UInt16(18), "1"), (19, "2"), (20, "3"), (21, "4")] {
            try fixture.sendKey(keyCode: keyCode, characters: digit, modifiers: [.command])
        }
        try fixture.sendKey(keyCode: 40, characters: "k", modifiers: [.command])
        try expect(fixture.canvas.allWorkspaceTiles().count == tilesBefore, "⌘1-⌘4 must not spawn tiles while Settings is open")
        try expect(delegate.qaProfilePalette?.isVisible != true, "⌘K must not open the command menu over Settings")
        try expect(delegate.qaFocusBroker.activeSurface == .modal(.settings) && overlays().count == 1,
                   "suppressed shortcuts must leave Settings open and focused")
        // Ordinary typing still reaches the field.
        let plainA = try keyEvent(fixture, keyCode: 0, characters: "a")
        try expect(!delegate.handleHotkey(plainA), "plain typing must pass through to the search field")

        // 5. Esc clears an active search first, then closes.
        modal.model.searchQuery = "dark"
        try fixture.sendKey(keyCode: 53, characters: "\u{1B}")
        try expect(modal.isVisible && modal.model.searchQuery.isEmpty, "Esc with a search must clear it and keep Settings open")

        // 6. Each way out closes once and restores the tile's focus.
        var closes = delegate.qaSettingsCloseCount
        func expectClosed(_ how: String) throws {
            fixture.pump()
            try expect(overlays().isEmpty && delegate.qaSettingsModal == nil, "\(how) must remove Settings")
            try expect(delegate.qaSettingsCloseCount == closes + 1,
                       "\(how) must fire onClose exactly once; fired \(delegate.qaSettingsCloseCount - closes)")
            try expect(delegate.qaFocusBroker.activeSurface == focusedBefore,
                       "\(how) must hand focus back to the terminal tile; active=\(String(describing: delegate.qaFocusBroker.activeSurface))")
            try expect(newWindows().isEmpty, "\(how) left a window behind")
            closes = delegate.qaSettingsCloseCount
        }
        try fixture.sendKey(keyCode: 53, characters: "\u{1B}")
        try expectClosed("Esc")

        try openWithCommandComma()
        try fixture.sendKey(keyCode: 13, characters: "w", modifiers: [.command])
        try expectClosed("⌘W")
        try expect(fixture.window.isVisible, "⌘W must close Settings, never the main window")

        try openWithCommandComma()
        guard let scrimCard = delegate.qaSettingsModal?.overlay?.card.frame else {
            throw SettingsCheckFixture.Failure(message: "Settings did not reopen")
        }
        try fixture.click(atWindowPoint: content.convert(NSPoint(x: scrimCard.minX - 12, y: scrimCard.midY), to: nil))
        try expectClosed("a click on the scrim")

        try openWithCommandComma()
        delegate.qaSettingsModal?.overlay?.closeButton.performClick(nil)
        try expectClosed("the close button")

        // A click INSIDE the card is not a dismissal.
        try openWithCommandComma()
        if let inside = delegate.qaSettingsModal?.overlay?.card.frame {
            try fixture.click(atWindowPoint: content.convert(NSPoint(x: inside.midX, y: inside.minY + 6), to: nil))
        }
        try expect(delegate.qaSettingsModal?.isVisible == true, "a click inside the card must not close Settings")

        // A text edit in progress survives the modal closing under it: type a new
        // zone name into the real field, press Esc, and the name is saved.
        delegate.qaSettingsModal?.model.selectPane("canvasAndZones")
        fixture.pump(0.1)
        func textFields(_ view: NSView) -> [NSTextField] {
            ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(textFields)
        }
        guard let paneOverlay = delegate.qaSettingsModal?.overlay,
              let nameField = textFields(paneOverlay).first(where: { $0.isEditable && $0.stringValue == DefaultGroupZoneName.fallback }) else {
            throw SettingsCheckFixture.Failure(message: "the Canvas pane must draw an editable New zone name field")
        }
        fixture.window.makeFirstResponder(nameField)
        guard let editor = nameField.currentEditor() as? NSTextView else {
            throw SettingsCheckFixture.Failure(message: "the zone name field took no field editor")
        }
        editor.selectAll(nil)
        editor.insertText("Studio", replacementRange: editor.selectedRange())
        fixture.pump()
        try fixture.sendKey(keyCode: 53, characters: "\u{1B}")
        try expectClosed("Esc mid-edit")
        try expect(fixture.defaults.string(forKey: DefaultGroupZoneName.userDefaultsKey) == "Studio",
                   "closing mid-edit must keep the typed zone name; stored \(fixture.defaults.string(forKey: DefaultGroupZoneName.userDefaultsKey) ?? "nothing")")
        try openWithCommandComma()

        // 7. The last pane comes back on the next open; the memory lives in the
        // injected suite, never the standard domain.
        delegate.qaSettingsModal?.model.selectPane("terminal")
        fixture.pump()
        try fixture.sendKey(keyCode: 53, characters: "\u{1B}")
        try expectClosed("Esc (pane memory)")
        try openWithCommandComma()
        try expect(delegate.qaSettingsModal?.model.selectedPaneID == "terminal",
                   "Settings must reopen on the last pane; got \(delegate.qaSettingsModal?.model.selectedPaneID ?? "none")")
        try expect(fixture.defaults.string(forKey: SettingsModel.lastPaneKey) == "terminal", "the last pane must persist in Settings' defaults")
        delegate.qaSettingsModal?.close()
        let touched = standardGuard.finish()
        try expect(touched.isEmpty, "Settings wrote the standard defaults domain: \(touched)")
        print("settings-modal: in-window, top-most, single, shortcut-proof; Esc/⌘W/scrim/× each close once and restore focus")
    }

    static func keyEvent(_ fixture: SettingsCheckFixture, keyCode: UInt16, characters: String,
                         modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode) else {
            throw SettingsCheckFixture.Failure(message: "could not synthesize key \(keyCode)")
        }
        return event
    }
}

/// `--settings-search-check` — the search field at the top of the Settings
/// sidebar finds settings by the words a person would type, and takes them there.
///
/// Drives the real field (typed through the field editor), ↑/↓/Return through the
/// app's key route, and asserts what the person sees: the results, the pane
/// navigated to, the row scrolled into the viewport and highlighted. The drift
/// guard holds the registry and the rendered rows to each other in both
/// directions, pane by pane.
@MainActor
enum SettingsSearchChecks {
    static let searchFieldIdentifier = SettingsSearchField.identifier

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SettingsCheckFixture.Failure(message: message) }
    }

    static func run() throws {
        let fixture = try SettingsCheckFixture(label: "search")
        defer { fixture.tearDown() }
        try fixture.sendKey(keyCode: 43, characters: ",", modifiers: [.command])
        guard let content = fixture.window.contentView else {
            throw SettingsCheckFixture.Failure(message: "the main window has no content view")
        }
        func find(_ view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField, field.accessibilityIdentifier() == searchFieldIdentifier { return field }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        guard let field = find(content), let modal = fixture.delegate.qaSettingsModal else {
            throw SettingsCheckFixture.Failure(message: "the Settings search field must be inside the main window")
        }
        let model = modal.model
        func isFocused() -> Bool { fixture.window.firstResponder === field.currentEditor() && field.currentEditor() != nil }
        try expect(isFocused(), "opening Settings must focus the search field")

        // ⌘F focuses the field from anywhere in Settings.
        fixture.window.makeFirstResponder(nil)
        try fixture.sendKey(keyCode: 3, characters: "f", modifiers: [.command])
        try expect(isFocused(), "⌘F must focus the search field")

        /// Types through the field editor, as keystrokes would, then settles.
        func type(_ text: String) throws {
            field.stringValue = ""
            model.clearSearch()
            fixture.window.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else {
                throw SettingsCheckFixture.Failure(message: "the search field has no field editor")
            }
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: editor.selectedRange())
            fixture.pump()
        }
        func results() -> [SettingsEntry] { model.searchResults.map(\.entry) }

        try type("dark")
        try expect(model.searchQuery == "dark", "typing must reach the model; query='\(model.searchQuery)'")
        try expect(results().contains { $0.paneID == "editor" && $0.label == "Appearance" }, "'dark' must find the Editor appearance")
        try expect(results().contains { $0.id == "pane.appearance" }, "'dark' must find the Appearance pane")
        try type("theme")
        try expect(results().contains { $0.id == "pane.appearance" } && results().contains { $0.paneID == "editor" && $0.label == "Appearance" },
                   "'theme' must find Appearance and the Editor appearance")
        try type("codex")
        try expect(results().contains { $0.field?.key == AgentBackendConfig.key }, "'codex' must find the default agent CLI")
        try type("chime")
        try expect(results().contains { $0.anchor == "sounds.master" }, "'chime' must find the sounds")
        try type("background")
        try expect(results().contains { $0.anchor == "canvasBackground.scope" }, "'background' must find the canvas background")
        try type("on")
        try expect(!results().isEmpty, "'on' must find something")
        for entry in results() {
            let words = ([entry.label, entry.groupTitle ?? "", entry.paneTitle] + entry.keywords + entry.optionTitles)
                .flatMap(SettingsSearch.words)
            try expect(words.contains { $0.hasPrefix("on") }, "'on' returned '\(entry.label)' without a word starting with 'on'")
        }
        try type("zzqxv")
        try expect(results().isEmpty && model.groupedResults.isEmpty, "a query with no match must show the empty state")

        // ↓ + Return navigates: to the Keyboard pane, the row scrolled into view
        // from below the fold, and highlighted.
        model.clearSearch()
        model.selectPane("keybindings")
        fixture.pump(0.15)
        let target = "shortcut.tile.browser.browserFind"
        try expect(model.renderedAnchors[target] != nil && !model.isAnchorVisible(target),
                   "precondition: the browser Find shortcut must render below the fold of the Keyboard pane")
        model.selectPane("general")
        fixture.pump()
        try type("browser find")
        guard let targetIndex = model.searchResults.firstIndex(where: { $0.entry.anchor == target }) else {
            throw SettingsCheckFixture.Failure(message: "'browser find' must find the browser Find shortcut; got \(results().map(\.label))")
        }
        try expect(model.selectedResultIndex == 0, "the first result must be selected as you type")
        for _ in 0..<targetIndex { try fixture.sendKey(keyCode: 125, characters: "\u{F701}") }
        try expect(model.selectedResultIndex == targetIndex, "↓ must move the selection; at \(String(describing: model.selectedResultIndex)) want \(targetIndex)")
        try fixture.sendKey(keyCode: 126, characters: "\u{F700}")
        try fixture.sendKey(keyCode: 125, characters: "\u{F701}")
        try fixture.sendKey(keyCode: 36, characters: "\r")
        fixture.pump(0.2)
        try expect(model.selectedPaneID == "keybindings", "Return must navigate to the result's pane; at \(model.selectedPaneID)")
        try expect(model.highlightedEntryID == target, "the result's row must be highlighted; highlighted=\(model.highlightedEntryID ?? "none")")
        try expect(model.isAnchorVisible(target), "the result's row must be scrolled into view; frame=\(String(describing: model.anchorFrames[target])) viewport=\(model.viewportSize)")

        // Esc clears the search and keeps Settings open.
        fixture.window.makeFirstResponder(field)
        try fixture.sendKey(keyCode: 53, characters: "\u{1B}")
        try expect(model.searchQuery.isEmpty && field.stringValue.isEmpty && modal.isVisible, "Esc must clear the search and keep Settings open")

        // Drift guard: every registry entry has a rendered anchor, and every
        // rendered anchor is in the registry, pane by pane. Each pane is also
        // written out (the app's real custom views included) for review.
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let artifacts = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs/\(timestamp)/settings-modal", isDirectory: true)
        try? FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        for pane in model.visiblePanes {
            model.selectPane(pane.id)
            fixture.pump()
            if let card = modal.overlay?.card, let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) {
                card.cacheDisplay(in: card.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: artifacts.appendingPathComponent("\(pane.id).png"))
            }
            let expected = Set(model.entries().filter { $0.paneID == pane.id }.compactMap(\.anchor))
            let rendered = Set(model.renderedAnchors.keys)
            try expect(expected.subtracting(rendered).isEmpty, "\(pane.title): registry entries with no rendered row: \(expected.subtracting(rendered).sorted())")
            try expect(rendered.subtracting(expected).isEmpty, "\(pane.title): rendered rows missing from the registry: \(rendered.subtracting(expected).sorted())")
        }
        print("settings-search: word-prefix results, ↓/Return navigation with scroll and highlight, Esc clears, registry and rows agree")
    }
}

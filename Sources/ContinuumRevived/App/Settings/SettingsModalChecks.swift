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
@MainActor
enum SettingsModalChecks {
    static let overlayIdentifier = "ArraySettingsOverlay"

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SettingsCheckFixture.Failure(message: message) }
    }

    static func run() throws {
        let fixture = try SettingsCheckFixture(label: "modal")
        defer { fixture.tearDown() }
        guard let content = fixture.window.contentView else {
            throw SettingsCheckFixture.Failure(message: "the main window has no content view")
        }
        let windowsBefore = Set(NSApp.windows.map(ObjectIdentifier.init))

        // 1. ⌘, through the production key route opens Settings INSIDE the window.
        try fixture.sendKey(keyCode: 43, characters: ",", modifiers: [.command])
        // The system's text-input window (`TUINSWindow`) appears whenever ANY field
        // takes focus; it is AppKit's, not Settings', and is the only exclusion.
        let newWindows = NSApp.windows.filter {
            !windowsBefore.contains(ObjectIdentifier($0)) && !String(describing: type(of: $0)).hasPrefix("TUI")
        }
        try expect(newWindows.isEmpty,
                   "⌘, must not create a window; it created \(newWindows.map { "\(type(of: $0)) '\($0.title)'" })")
        let overlays = content.subviews.filter { $0.accessibilityIdentifier() == overlayIdentifier }
        try expect(overlays.count == 1, "⌘, must mount exactly one Settings overlay in the main window; found \(overlays.count)")
        try expect(content.subviews.last === overlays.first,
                   "the Settings overlay must be the top-most subview of the window content")
    }
}

/// `--settings-search-check` — the search field at the top of the Settings
/// sidebar finds settings by the words a person would type.
@MainActor
enum SettingsSearchChecks {
    static let searchFieldIdentifier = "ArraySettingsSearch"

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
        try expect(find(content) != nil, "the Settings search field must be inside the main window")
    }
}

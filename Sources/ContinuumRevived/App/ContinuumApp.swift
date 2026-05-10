import AppKit
import ContinuumRevivedCore
import Foundation
import GhosttyKit

@main
enum ContinuumApp {
    @MainActor
    private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let executablePath = CommandLine.arguments.first ?? "continuum-revived"
        let ghosttyInitStatus = executablePath.withCString { executablePointer in
            var argv: [UnsafeMutablePointer<CChar>?] = [
                UnsafeMutablePointer(mutating: executablePointer),
                nil
            ]
            return argv.withUnsafeMutableBufferPointer { buffer in
                ghostty_init(1, buffer.baseAddress)
            }
        }

        guard ghosttyInitStatus == GHOSTTY_SUCCESS else {
            fputs("ghostty_init failed\n", stderr)
            Foundation.exit(1)
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate

        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, CanvasNSViewDelegate {
    private var window: NSWindow?
    private var ghostty: GhosttyRuntimeContext?
    private var browserEngine: BrowserEngineContext?
    private var runtimes: [GhosttyTerminalRuntime] = []
    private var browserRuntimes: [WKWebViewBrowserRuntime] = []
    private var noteViews: [UUID: NoteTileNSView] = [:]
    private var canvasView: CanvasNSView?
    private var saveTimer: Timer?
    private var browserSaveTimer: Timer?
    private var noteSaveTimer: Timer?
    private let smokeTestEnabled = ProcessInfo.processInfo.environment["CONTINUUM_SMOKE_TEST"] == "1"
    private var smokeTestExitCode: Int32?
    private var projectStore: ProjectStore?
    private var registryStore: RegistryStore?
    private var activeProject: Project?
    private var tileSpawner: TileSpawner?
    private var profilePalette: LaunchProfilePalette?
    private var qaPerf: QAPerf?
    private var launchStartTime: CFTimeInterval?
    private var hotkeyMonitor: Any?
    private static let smokeNoteId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let smokeNoteTileId = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    private static let smokeFileTileId = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    private static let smokeFileTreeTileId = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
    private static let smokeNoteBody = "smoke-note-ok"
    private static let smokeFileBody = "smoke-file-ok"

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchStartTime = QAPerf.timestamp()
        qaPerf = QAPerf()
        do {
            let projectRoot = Self.resolveProjectRoot(smokeTest: smokeTestEnabled)
            let appSupportDir = Self.resolveAppSupportDir(smokeTest: smokeTestEnabled)
            let projectStore = ProjectStore(projectRoot: projectRoot)
            let registryStore = RegistryStore(applicationSupportDirectory: appSupportDir)
            self.projectStore = projectStore
            self.registryStore = registryStore

            pruneExitedSessions(in: projectStore)

            let project = try Self.loadOrCreateProject(in: projectStore, projectRoot: projectRoot)
            self.activeProject = project
            try Self.recordProjectInRegistry(project: project, in: registryStore)

            let ghostty = try GhosttyRuntimeContext()
            let browserEngine = BrowserEngineContext()
            let seededSmokeTiles = smokeTestEnabled && Self.requestedQAFlow() != .emptyCanvas
                ? try Self.seedSmokeTestTiles(in: projectStore, projectRoot: projectRoot)
                : []

            var canvasState: CanvasState
            if let existing = try projectStore.tryLoadCanvas() {
                canvasState = existing
            } else {
                canvasState = Self.defaultCanvasState()
            }
            for seededTile in seededSmokeTiles {
                if let index = canvasState.tiles.firstIndex(where: { $0.id == seededTile.id }) {
                    canvasState.tiles[index] = seededTile
                } else {
                    canvasState.tiles.append(seededTile)
                }
            }
            if smokeTestEnabled,
               Self.requestedQAFlow() != .emptyCanvas,
               !canvasState.tiles.contains(where: { $0.kind == .terminal }) {
                canvasState.tiles.append(Self.defaultTerminalTile())
            }

            let canvasView = CanvasNSView(canvasState: canvasState)
            canvasView.delegate = self

            self.ghostty = ghostty
            self.browserEngine = browserEngine
            self.canvasView = canvasView

            let spawner = TileSpawner(
                canvasView: canvasView,
                ghostty: ghostty,
                browserEngine: browserEngine,
                projectStore: projectStore,
                project: project
            )
            spawner.browserPersistenceHandler = { [weak self] in
                self?.scheduleBrowserSave()
            }
            spawner.notePersistenceHandler = { [weak self] in
                self?.scheduleNoteSave()
            }
            self.tileSpawner = spawner
            canvasView.configureEmptyStateActions(CanvasEmptyStateActions(
                spawnClaude: { [weak self] in
                    self?.spawnTerminalFromProfile("claude")
                },
                spawnShell: { [weak self] in
                    self?.spawnTerminalFromProfile("shell")
                },
                spawnBrowser: { [weak self] in
                    self?.spawnBrowserDefault()
                },
                openInEditor: { [weak self] in
                    self?.openProjectInEditor()
                }
            ))

            installHotkeyMonitor()

            // Walk every tile in the canvas, spawn a runtime for each terminal
            // tile (or install a Restart placeholder if the profile fails to
            // resolve), and install descriptor placeholders for non-terminal
            // tiles. The spawner persists each session descriptor; saveCanvas
            // happens once at the end.
            for tile in canvasState.tiles {
                switch tile.kind {
                case .terminal:
                    installInitialTerminalTile(tile, in: canvasView, via: spawner)
                case .browser:
                    installInitialBrowserTile(tile, in: canvasView, via: spawner)
                case .note:
                    installInitialNoteTile(tile, in: canvasView, via: spawner)
                case .file:
                    installInitialFileTile(tile, in: canvasView, via: spawner)
                case .fileTree:
                    installInitialFileTreeTile(tile, in: canvasView, via: spawner)
                }
            }

            try projectStore.saveCanvas(canvasView.canvasState)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "continuum-revived"
            window.center()
            window.contentView = canvasView
            window.delegate = self
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(canvasView)
            self.window = window

            // Activate after runtimes are wired up: NSApp.activate can fire
            // applicationDidBecomeActive synchronously, and the focus path needs
            // a non-nil ghostty to forward set_focus into the surface.
            NSApp.activate(ignoringOtherApps: true)

            if smokeTestEnabled {
                runSmokeTest(window: window, runtime: runtimes.first)
            }
        } catch {
            presentFatalError(error)
        }
    }

    private func installInitialTerminalTile(_ tile: Tile, in canvasView: CanvasNSView, via spawner: TileSpawner) {
        switch spawner.restartTerminalTile(tileId: tile.id) {
        case let .restarted(runtime):
            wireRuntimeExitHandler(runtime)
            runtimes.append(runtime)
        case let .missingCommand(executable):
            installRestartPlaceholder(
                for: tile,
                statusText: "\(executable) not found on $PATH",
                restartable: true,
                in: canvasView
            )
        case let .notConfigured(profileId):
            installRestartPlaceholder(
                for: tile,
                statusText: "Profile '\(profileId)' is not configured",
                restartable: false,
                in: canvasView
            )
        case let .unknownProfile(id):
            installRestartPlaceholder(
                for: tile,
                statusText: "Profile '\(id)' is missing",
                restartable: false,
                in: canvasView
            )
        case .tileNotFound:
            installRestartPlaceholder(
                for: tile,
                statusText: "Tile not found in canvas state",
                restartable: false,
                in: canvasView
            )
        case let .failure(error):
            fputs("Boot terminal install failed: \(error)\n", stderr)
            installRestartPlaceholder(
                for: tile,
                statusText: "Failed to start terminal",
                restartable: true,
                in: canvasView
            )
        }
    }

    private func installRestartPlaceholder(
        for tile: Tile,
        statusText: String,
        restartable: Bool,
        in canvasView: CanvasNSView
    ) {
        let onRestart: (() -> Void)?
        if restartable {
            let tileId = tile.id
            onRestart = { [weak self] in self?.restartTile(tileId: tileId) }
        } else {
            onRestart = nil
        }
        let view = TerminalRestartTileNSView(tile: tile, statusText: statusText, onRestart: onRestart)
        canvasView.install(tileView: view, for: tile)
    }

    private func wireRuntimeExitHandler(_ runtime: GhosttyTerminalRuntime) {
        runtime.onRuntimeExited = { [weak self] runtimeId, exitCode in
            self?.handleRuntimeExited(runtimeId: runtimeId, exitCode: exitCode)
        }
    }

    private func wireContentProcessTerminationHandler(_ runtime: WKWebViewBrowserRuntime) {
        runtime.onContentProcessTerminated = { [weak self] runtimeId in
            self?.handleBrowserContentProcessTerminated(runtimeId: runtimeId)
        }
    }

    private func handleBrowserContentProcessTerminated(runtimeId: BrowserRuntimeID) {
        guard let runtime = browserRuntimes.first(where: { $0.id == runtimeId }) else { return }
        let tileId = runtime.tileId

        tileSpawner?.writeBrowserTileSnapshot(for: runtime)

        browserRuntimes.removeAll { $0.id == runtimeId }
        runtime.terminate(policy: .force)

        guard let canvasView,
              let tile = canvasView.canvasState.tiles.first(where: { $0.id == tileId })
        else {
            fputs("Browser content-process terminated: tile \(tileId) not found in canvas\n", stderr)
            return
        }

        installBrowserRestartPlaceholder(
            for: tile,
            statusText: "Web content process terminated",
            restartable: true,
            in: canvasView
        )
    }

    private func handleRuntimeExited(runtimeId: TerminalSessionID, exitCode: Int32?) {
        // Late .exited after windowWillClose teardown -- already handled there.
        guard let runtime = runtimes.first(where: { $0.id == runtimeId }) else { return }
        let tileId = runtime.tileId

        if let projectStore, var descriptor = try? projectStore.loadSession(id: runtimeId) {
            descriptor.lastExit = TerminalLastExit(exitCode: exitCode, signal: nil, at: Date())
            try? projectStore.saveSession(descriptor)
        }

        runtimes.removeAll { $0.id == runtimeId }
        runtime.terminate(policy: .force)

        guard let canvasView,
              let tile = canvasView.canvasState.tiles.first(where: { $0.id == tileId })
        else { return }

        let statusText: String
        if let exitCode {
            statusText = "Shell exited (code \(exitCode))"
        } else {
            statusText = "Shell exited"
        }
        installRestartPlaceholder(for: tile, statusText: statusText, restartable: true, in: canvasView)
    }

    private func restartTile(tileId: UUID) {
        guard let spawner = tileSpawner, let canvasView else { return }
        switch spawner.restartTerminalTile(tileId: tileId) {
        case let .restarted(runtime):
            wireRuntimeExitHandler(runtime)
            runtimes.append(runtime)
        case let .missingCommand(executable):
            if let tile = canvasView.canvasState.tiles.first(where: { $0.id == tileId }) {
                installRestartPlaceholder(
                    for: tile,
                    statusText: "\(executable) not found on $PATH",
                    restartable: true,
                    in: canvasView
                )
            }
            presentMissingCommand(executable: executable, profileId: "")
        case let .notConfigured(profileId):
            presentMissingCommand(executable: profileId, profileId: profileId, kind: .notConfigured)
        case let .unknownProfile(id):
            fputs("Restart: unknown profile '\(id)'\n", stderr)
        case .tileNotFound:
            fputs("Restart: tile \(tileId) no longer exists\n", stderr)
        case let .failure(error):
            fputs("Restart failed: \(error)\n", stderr)
        }
    }

    private func installInitialBrowserTile(_ tile: Tile, in canvasView: CanvasNSView, via spawner: TileSpawner) {
        switch spawner.restartBrowserTile(tileId: tile.id) {
        case let .restarted(runtime):
            wireContentProcessTerminationHandler(runtime)
            browserRuntimes.append(runtime)
        case let .invalidURL(url):
            installBrowserRestartPlaceholder(
                for: tile,
                statusText: "Invalid URL: \(url)",
                restartable: false,
                in: canvasView
            )
        case .tileNotFound:
            installBrowserRestartPlaceholder(
                for: tile,
                statusText: "Tile not found in canvas state",
                restartable: false,
                in: canvasView
            )
        case let .failure(error):
            fputs("Boot browser install failed: \(error)\n", stderr)
            installBrowserRestartPlaceholder(
                for: tile,
                statusText: "Failed to start browser",
                restartable: true,
                in: canvasView
            )
        }
    }

    private func installBrowserRestartPlaceholder(
        for tile: Tile,
        statusText: String,
        restartable: Bool,
        in canvasView: CanvasNSView
    ) {
        let onRestart: (() -> Void)?
        if restartable {
            let tileId = tile.id
            onRestart = { [weak self] in self?.restartBrowserTile(tileId: tileId) }
        } else {
            onRestart = nil
        }
        let view = BrowserRestartTileNSView(tile: tile, statusText: statusText, onRestart: onRestart)
        canvasView.install(tileView: view, for: tile)
    }

    private func restartBrowserTile(tileId: UUID) {
        guard let spawner = tileSpawner else { return }
        switch spawner.restartBrowserTile(tileId: tileId) {
        case let .restarted(runtime):
            wireContentProcessTerminationHandler(runtime)
            browserRuntimes.append(runtime)
        case let .invalidURL(url):
            fputs("Browser restart: invalid URL '\(url)'\n", stderr)
        case .tileNotFound:
            fputs("Browser restart: tile \(tileId) no longer exists\n", stderr)
        case let .failure(error):
            fputs("Browser restart failed: \(error)\n", stderr)
        }
    }

    private func installInitialNoteTile(_ tile: Tile, in canvasView: CanvasNSView, via spawner: TileSpawner) {
        spawner.installNoteTile(tile, in: canvasView)
        let view = canvasView.tileView(for: tile.id) as! NoteTileNSView
        noteViews[view.noteId] = view
    }

    private func installInitialFileTile(_ tile: Tile, in canvasView: CanvasNSView, via spawner: TileSpawner) {
        spawner.installFileTile(tile, in: canvasView)
    }

    private func installInitialFileTreeTile(_ tile: Tile, in canvasView: CanvasNSView, via spawner: TileSpawner) {
        spawner.installFileTreeTile(tile, in: canvasView)
    }

    // MARK: - Hotkeys + spawning

    private func installHotkeyMonitor() {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleHotkey(event) ? nil : event
        }
        self.hotkeyMonitor = monitor
    }

    private func handleHotkey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let onlyCommand: NSEvent.ModifierFlags = [.command]
        guard mods == onlyCommand else { return false }
        guard let chars = event.charactersIgnoringModifiers else { return false }
        switch chars {
        case "k":
            openProfilePalette()
            return true
        case "1":
            spawnTerminalFromProfile("claude")
            return true
        case "2":
            spawnTerminalFromProfile("shell")
            return true
        case "3":
            spawnBrowserDefault()
            return true
        case "4":
            spawnTerminalFromProfile("nvim")
            return true
        default:
            return false
        }
    }

    private func openProfilePalette() {
        guard let spawner = tileSpawner,
              let host = window else { return }
        let palette = profilePalette ?? makeProfilePalette()
        profilePalette = palette
        palette.show(near: host, profiles: spawner.annotatedProfiles())
    }

    private func makeProfilePalette() -> LaunchProfilePalette {
        let palette = LaunchProfilePalette()
        palette.onSelectProfile = { [weak self] profileId in
            self?.spawnTerminalFromProfile(profileId)
        }
        palette.onSelectAction = { [weak self] action in
            self?.performPaletteAction(action)
        }
        palette.onClose = { [weak self] in
            self?.profilePalette = nil
        }
        return palette
    }

    private func spawnTerminalFromProfile(_ profileId: String) {
        guard let spawner = tileSpawner else { return }
        switch spawner.spawnTerminal(profileId: profileId) {
        case let .spawned(runtime):
            wireRuntimeExitHandler(runtime)
            runtimes.append(runtime)
        case let .missingCommand(executable):
            presentMissingCommand(executable: executable, profileId: profileId)
        case let .notConfigured(id):
            presentMissingCommand(executable: id, profileId: id, kind: .notConfigured)
        case let .unknownProfile(id):
            fputs("Unknown profile id: \(id)\n", stderr)
        case let .failure(error):
            fputs("TileSpawner.spawnTerminal failed: \(error)\n", stderr)
        }
    }

    private func spawnBrowserDefault() {
        guard let spawner = tileSpawner else { return }
        switch spawner.spawnBrowser() {
        case let .spawned(runtime):
            wireContentProcessTerminationHandler(runtime)
            browserRuntimes.append(runtime)
        case let .invalidURL(url):
            fputs("TileSpawner.spawnBrowser invalid URL: \(url)\n", stderr)
        case let .failure(error):
            fputs("TileSpawner.spawnBrowser failed: \(error)\n", stderr)
        }
    }

    private func openProjectInEditor() {
        spawnTerminalFromProfile("nvim")
    }

    private func performPaletteAction(_ action: LaunchPaletteAction) {
        switch action {
        case .newNote:
            spawnNoteFromPalette()
        case .openFile:
            openFileFromPalette()
        }
    }

    private func spawnNoteFromPalette() {
        guard let spawner = tileSpawner else { return }
        switch spawner.spawnNote(title: "New Note") {
        case .spawned:
            break
        case let .failure(error):
            fputs("TileSpawner.spawnNote failed: \(error)\n", stderr)
        }
    }

    private func openFileFromPalette() {
        guard let spawner = tileSpawner,
              let project = activeProject else { return }
        let projectRoot = URL(fileURLWithPath: project.rootPath, isDirectory: true)
        let panel = NSOpenPanel()
        panel.title = "Open File"
        panel.directoryURL = projectRoot
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK,
              let selectedURL = panel.url else { return }
        guard LaunchPaletteModel.isFileURL(selectedURL, insideProjectRoot: projectRoot) else {
            NSSound.beep()
            return
        }

        switch spawner.spawnFile(path: selectedURL.standardizedFileURL.path, title: selectedURL.lastPathComponent) {
        case .spawned:
            break
        case .invalidPath:
            fputs("TileSpawner.spawnFile rejected empty file path\n", stderr)
        case let .failure(error):
            fputs("TileSpawner.spawnFile failed: \(error)\n", stderr)
        }
    }

    private enum MissingKind { case notFound, notConfigured }

    private func presentMissingCommand(executable: String, profileId: String, kind: MissingKind = .notFound) {
        let alert = NSAlert()
        switch kind {
        case .notFound:
            alert.messageText = "\(executable) is not installed"
            alert.informativeText = "Couldn't find \(executable) on your $PATH. Install the CLI or pick a different profile from Cmd-K."
        case .notConfigured:
            alert.messageText = "Profile '\(profileId)' is not configured"
            alert.informativeText = "Custom profiles aren't editable yet — pick a built-in profile from Cmd-K."
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if let app = try? ghostty?.app {
            ghostty_app_set_focus(app, true)
        }
        if let targetId = canvasView?.canvasState.lastActiveTileId {
            if let m = runtimes.first(where: { $0.tileId == targetId }) {
                m.focus(); return
            }
            if let m = browserRuntimes.first(where: { $0.tileId == targetId }) {
                m.focus(); return
            }
        }
        runtimes.last?.focus()
    }

    func applicationDidResignActive(_ notification: Notification) {
        if let app = try? ghostty?.app {
            ghostty_app_set_focus(app, false)
        }
        for runtime in runtimes {
            runtime.blur()
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Flush any pending saves so the close-leg observation catches the
        // most recent in-memory state.
        flushCanvasSave()
        flushBrowserSave()
        flushNoteSave()

        // Mark each terminal session as exited before we tear down its runtime.
        // We don't know the exit code from this side (Ghostty owns the PTY), so
        // record a clean close — the user closed the window.
        if let projectStore {
            let now = Date()
            for runtime in runtimes {
                if var descriptor = try? projectStore.loadSession(id: runtime.id) {
                    descriptor.lastExit = TerminalLastExit(exitCode: nil, signal: nil, at: now)
                    try? projectStore.saveSession(descriptor)
                }
            }
        }

        if let monitor = hotkeyMonitor {
            NSEvent.removeMonitor(monitor)
            hotkeyMonitor = nil
        }
        profilePalette?.close()
        profilePalette = nil

        // Browsers tear down first: WKWebView's process pool teardown is
        // independent of GhosttyKit's. Inverting the order risks WebKit KVO
        // callbacks firing into a half-torn-down app.
        for runtime in browserRuntimes {
            runtime.terminate(policy: .force)
        }
        browserRuntimes.removeAll()

        // Free every Ghostty surface before ghostty_app_free, per ADR-0010.
        // ghostty_app_free walks the surface registry and dereferences
        // PAC-protected pointers; if a surface is still alive at that point,
        // deinit traps with EXC_BAD_ACCESS.
        for runtime in runtimes {
            runtime.terminate(policy: .force)
        }
        canvasView = nil
        runtimes.removeAll()
        noteViews.removeAll()
        tileSpawner = nil
        ghostty?.shutdown()
        ghostty = nil
        browserEngine?.shutdown()
        browserEngine = nil
        if let exitCode = smokeTestExitCode {
            Foundation.exit(exitCode)
        }
        NSApp.terminate(nil)
    }

    // MARK: - CanvasNSViewDelegate

    func canvasDidChange(_ canvas: CanvasNSView) {
        // Coalesce drag-rate writes: schedule a save 200ms after the last
        // change. flushCanvasSave() runs immediately if we need to observe
        // the latest state (smoke test, close path).
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushCanvasSave() }
        }
    }

    private func scheduleBrowserSave() {
        // Browser url/title changes coalesce identically to canvas drags.
        browserSaveTimer?.invalidate()
        browserSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushBrowserSave() }
        }
    }

    private func flushBrowserSave() {
        browserSaveTimer?.invalidate()
        browserSaveTimer = nil
        guard let spawner = tileSpawner else { return }
        for runtime in browserRuntimes {
            spawner.writeBrowserTileSnapshot(for: runtime)
        }
    }

    private func scheduleNoteSave() {
        noteSaveTimer?.invalidate()
        noteSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushNoteSave() }
        }
    }

    private func flushNoteSave() {
        noteSaveTimer?.invalidate()
        noteSaveTimer = nil
        guard let spawner = tileSpawner else { return }
        for view in noteViews.values {
            spawner.writeNoteSnapshot(noteId: view.noteId, tileId: view.tile.id, text: view.textView.string)
        }
    }

    private func flushCanvasSave() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard let projectStore, let canvasView else { return }
        try? projectStore.saveCanvas(canvasView.canvasState)
    }

    // MARK: - Persistence helpers

    private static func resolveProjectRoot(smokeTest: Bool) -> URL {
        if let override = ProcessInfo.processInfo.environment["CONTINUUM_PROJECT_ROOT"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if smokeTest {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("continuum-smoke-project-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            return temp
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    private static func resolveAppSupportDir(smokeTest: Bool) -> URL? {
        if let override = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if smokeTest {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("continuum-smoke-appsupport-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            return temp
        }
        return nil // Fall through to the canonical Application Support path.
    }

    private static func loadOrCreateProject(in store: ProjectStore, projectRoot: URL) throws -> Project {
        if let existing = try store.tryLoadProject() {
            return existing
        }
        let now = Date()
        let project = Project(
            name: projectRoot.lastPathComponent,
            rootPath: projectRoot.path,
            createdAt: now,
            updatedAt: now,
            defaultLaunchProfileId: "shell",
            editorPreference: .auto,
            settings: ProjectSettings(
                restorePolicy: .restoreDescriptors,
                browserStoragePolicy: .perProject,
                terminalClosePolicy: .askWhenRunning
            )
        )
        try store.saveProject(project)
        return project
    }

    private static func defaultCanvasState() -> CanvasState {
        return CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [],
            groups: [],
            lastActiveTileId: nil
        )
    }

    private static func defaultTerminalTile() -> Tile {
        Tile(
            id: UUID(),
            kind: .terminal,
            title: "Shell",
            frame: TileFrame(x: 40, y: 40, width: 660, height: 480),
            zIndex: 2,
            runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "shell", projectRelativeCwd: ".")
        )
    }

    private static func seedSmokeTestTiles(in projectStore: ProjectStore, projectRoot: URL) throws -> [Tile] {
        try projectStore.saveNoteBody(id: smokeNoteId, text: smokeNoteBody)

        var noteState = (try? projectStore.tryLoadNoteState()) ?? NoteState(tiles: [])
        let now = Date()
        let smokeNoteTile = NoteTile(
            id: smokeNoteId,
            tileId: smokeNoteTileId,
            filename: "\(smokeNoteId.uuidString).md",
            title: "Smoke note",
            createdAt: now,
            updatedAt: now
        )
        if let index = noteState.tiles.firstIndex(where: { $0.id == smokeNoteId }) {
            noteState.tiles[index] = smokeNoteTile
        } else {
            noteState.tiles.append(smokeNoteTile)
        }
        try projectStore.saveNoteState(noteState)

        let smokeFileURL = projectRoot
            .appendingPathComponent(".continuum-revived", isDirectory: true)
            .appendingPathComponent("smoke-file.txt", isDirectory: false)
        try FileManager.default.createDirectory(
            at: smokeFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        let smokeFileData = Data(smokeFileBody.utf8)
        try smokeFileData.write(to: smokeFileURL, options: .atomic)

        let noteSize = CanvasEngine.defaultFrame(for: .note)
        let fileSize = CanvasEngine.defaultFrame(for: .file)
        let fileTreeSize = CanvasEngine.defaultFrame(for: .fileTree)
        let fileTreeState = FileTreeState(tiles: [
            FileTreeTile(
                tileId: smokeFileTreeTileId,
                rootPath: projectRoot.path,
                expandedPaths: [".continuum-revived"],
                selectedPath: ".continuum-revived/smoke-file.txt",
                searchQuery: "smoke",
                ignoredNames: [".git", "node_modules", ".build"],
                gitBadges: .off
            )
        ])
        try projectStore.saveFileTreeState(fileTreeState)

        return [
            Tile(
                id: smokeNoteTileId,
                kind: .note,
                title: "Smoke note",
                frame: TileFrame(x: 720, y: 300, width: Double(noteSize.width), height: Double(noteSize.height)),
                zIndex: 3,
                runtimeRef: nil,
                metadata: TileMetadata(noteId: smokeNoteId)
            ),
            Tile(
                id: smokeFileTileId,
                kind: .file,
                title: "smoke-file.txt",
                frame: TileFrame(x: 40, y: 560, width: Double(fileSize.width), height: Double(fileSize.height)),
                zIndex: 4,
                runtimeRef: nil,
                metadata: TileMetadata(filePath: smokeFileURL.path)
            ),
            Tile(
                id: smokeFileTreeTileId,
                kind: .fileTree,
                title: "Smoke files",
                frame: TileFrame(x: 380, y: 560, width: Double(fileTreeSize.width), height: Double(fileTreeSize.height)),
                zIndex: 5,
                runtimeRef: nil,
                metadata: TileMetadata()
            )
        ]
    }

    private static func recordProjectInRegistry(project: Project, in store: RegistryStore) throws {
        var registry = try store.loadOrEmpty()
        let now = Date()
        if let idx = registry.projects.firstIndex(where: { $0.id == project.id }) {
            registry.projects[idx].name = project.name
            registry.projects[idx].rootPath = project.rootPath
            registry.projects[idx].lastOpenedAt = now
        } else {
            registry.projects.append(ProjectEntry(
                id: project.id,
                name: project.name,
                rootPath: project.rootPath,
                workspaceId: nil,
                lastOpenedAt: now,
                pinned: false
            ))
        }
        registry.lastActiveProjectId = project.id
        try store.save(registry)
    }

    private func presentFatalError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Terminal engine failed to initialize."
        alert.informativeText = String(describing: error)
        alert.alertStyle = .critical
        alert.runModal()
        NSApp.terminate(nil)
    }

    private enum QASmokeFlow: String {
        case defaultSmoke = "default-smoke"
        case paletteOpenClose = "palette-open-close"
        case cmd1Claude = "cmd-1-claude"
        case cmd2Shell = "cmd-2-shell"
        case cmd3Browser = "cmd-3-browser"
        case cmd4Nvim = "cmd-4-nvim"
        case terminalMidExit = "terminal-mid-exit"
        case browserLoadError = "browser-load-error"
        case canvasDragResize = "canvas-drag-resize"
        case canvasZoomPanEdge = "canvas-zoom-pan-edge"
        case emptyCanvas = "empty-canvas"
        case restartPlaceholderClick = "restart-placeholder-click"
        case terminalStress10 = "terminal-stress-10"
        case paletteLeakCheck = "palette-leak-check"
    }

    private static func requestedQAFlow() -> QASmokeFlow? {
        let rawFlow = ProcessInfo.processInfo.environment["CONTINUUM_QA_FLOW"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let flowName = rawFlow.flatMap { $0.isEmpty ? nil : $0 } ?? QASmokeFlow.defaultSmoke.rawValue
        return QASmokeFlow(rawValue: flowName)
    }

    private func runSmokeTest(window: NSWindow, runtime: GhosttyTerminalRuntime?) {
        guard let flow = Self.requestedQAFlow() else {
            let rawFlow = ProcessInfo.processInfo.environment["CONTINUUM_QA_FLOW"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let flowName = rawFlow.flatMap { $0.isEmpty ? nil : $0 } ?? QASmokeFlow.defaultSmoke.rawValue
            fputs("Unknown CONTINUUM_QA_FLOW: \(flowName)\n", stderr)
            smokeTestExitCode = 2
            window.performClose(nil)
            return
        }

        switch flow {
        case .defaultSmoke:
            guard let runtime else {
                fputs("Default smoke requires an initial terminal runtime\n", stderr)
                smokeTestExitCode = 2
                window.performClose(nil)
                return
            }
            runDefaultSmokeTest(window: window, runtime: runtime)
        case .paletteOpenClose:
            runPaletteOpenCloseFlow(window: window)
        case .cmd1Claude:
            runCommandProfileFlow(window: window, profileId: "claude", label: "cmd-1-claude")
        case .cmd2Shell:
            runCommandProfileFlow(window: window, profileId: "shell", label: "cmd-2-shell")
        case .cmd3Browser:
            runBrowserSpawnFlow(window: window)
        case .cmd4Nvim:
            runCommandProfileFlow(window: window, profileId: "nvim", label: "cmd-4-nvim")
        case .terminalMidExit:
            runTerminalMidExitFlow(window: window)
        case .browserLoadError:
            runBrowserLoadErrorFlow(window: window)
        case .canvasDragResize:
            runCanvasDragResizeFlow(window: window)
        case .canvasZoomPanEdge:
            runCanvasZoomPanEdgeFlow(window: window)
        case .emptyCanvas:
            runEmptyCanvasFlow(window: window)
        case .restartPlaceholderClick:
            runRestartPlaceholderClickFlow(window: window)
        case .terminalStress10:
            runTerminalStress10Flow(window: window)
        case .paletteLeakCheck:
            runPaletteLeakCheckFlow(window: window)
        }
    }

    private func runDefaultSmokeTest(window: NSWindow, runtime: GhosttyTerminalRuntime) {
        let qaCapture = QACapture()
        func capture(_ step: String, tSec: Double, notes: String? = nil) {
            qaCapture?.capture(
                step: step,
                tSec: tSec,
                window: window,
                canvasState: self.canvasView?.canvasState,
                notes: notes
            )
        }

        // 1.0s - exercise the committed IME text path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.recordLaunchTime()
            runtime.dispatchInsertedText("echo ghostty-ok")
            runtime.dispatchKeyDown(keyCode: 0x24, characters: "\r")
            capture("echo-text", tSec: 1.0)
        }

        // 2.0s — exercise the key path: up-arrow recalls the previous command.
        // Without ghostty_surface_key, the PUA codepoint goes nowhere useful and
        // the shell does not recall the history entry.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            runtime.dispatchKeyDown(
                keyCode: 0x7E,
                characters: "\u{F700}",
                charactersIgnoringModifiers: "\u{F700}"
            )
            capture("up-arrow", tSec: 2.0)
        }

        // 2.4s — Enter to execute the recalled command.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            runtime.dispatchKeyDown(keyCode: 0x24, characters: "\r")
            capture("enter-recall", tSec: 2.4)
        }

        // 2.5s — P4.5: spawn a second terminal via the TileSpawner seam. This
        // proves multi-terminal shutdown works (each surface freed before
        // ghostty_app_free) and that descriptors persist with their profile id.
        var secondaryRuntimeId: UUID?
        var secondaryTileId: UUID?
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard let spawner = self.tileSpawner else { return }
            switch spawner.spawnTerminal(profileId: "shell") {
            case let .spawned(secondary):
                self.wireRuntimeExitHandler(secondary)
                self.runtimes.append(secondary)
                secondaryRuntimeId = secondary.id
                secondaryTileId = secondary.tileId
            case let .missingCommand(executable):
                fputs("Smoke spawn missing command: \(executable)\n", stderr)
            case let .notConfigured(profileId):
                fputs("Smoke spawn notConfigured: \(profileId)\n", stderr)
            case let .unknownProfile(id):
                fputs("Smoke spawn unknownProfile: \(id)\n", stderr)
            case let .failure(error):
                fputs("Smoke spawn failure: \(error)\n", stderr)
            }
        }

        // 2.8s - fill scrollback with enough output to push earlier lines off
        // the visible viewport, so a scroll-up has something to reveal. Send
        // the command body via the text path then Enter via the key path
        // (mirrors how a user types a command and presses Return).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            runtime.dispatchInsertedText("seq 1 60")
            runtime.dispatchKeyDown(keyCode: 0x24, characters: "\r")
            capture("seq-scroll", tSec: 2.8)
        }

        // 3.0s — P5.x: send `exit` to the secondary so we can observe the
        // mid-session runtime-exit detection swap the live tile for a
        // Restart placeholder.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if let id = secondaryRuntimeId,
               let secondary = self.runtimes.first(where: { $0.id == id }) {
                secondary.dispatchInsertedText("exit")
                secondary.dispatchKeyDown(keyCode: 0x24, characters: "\r")
            }
            capture("mid-exit-trigger", tSec: 3.0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.3) {
            capture("post-exit-swap", tSec: 3.3)
        }

        // 3.5s — window resize must still complete without crashing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            window.setContentSize(NSSize(width: 860, height: 540))
            capture("resize", tSec: 3.5)
        }

        // 3.6s — P5.6: spawn a live WKWebView browser tile via a deterministic
        // data: URL so the smoke test stays offline-safe. The KVO + persistence
        // path writes the URL/title into BrowserState.
        var browserRuntimeId: UUID?
        var browserTileId: UUID?
        let browserDataURL = "data:text/html;charset=utf-8,<html><head><title>continuum-browser-ok</title></head><body>ok</body></html>"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) {
            guard let spawner = self.tileSpawner else { return }
            switch spawner.spawnBrowser(url: browserDataURL) {
            case let .spawned(runtime):
                self.wireContentProcessTerminationHandler(runtime)
                self.browserRuntimes.append(runtime)
                browserRuntimeId = runtime.id
                browserTileId = runtime.tileId
            case let .invalidURL(url):
                fputs("Smoke browser spawn invalid URL: \(url)\n", stderr)
            case let .failure(error):
                fputs("Smoke browser spawn failure: \(error)\n", stderr)
            }
        }

        // 4.0s — capture pre-scroll viewport, scroll up via the C scroll API,
        // then assert the viewport content changed. Proves Ghostty's scroll
        // engine is actually being driven from our wrapper.
        var preScrollText = ""
        var modifierOnlyOk = false
        var imeInsertedTextSeen = false
        var markedTextCleared = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            runtime.dispatchModifierFlagsChanged(keyCode: 0x38, modifierFlags: [.shift])
            runtime.dispatchModifierFlagsChanged(keyCode: 0x38, modifierFlags: [.shift])
            runtime.dispatchModifierFlagsChanged(keyCode: 0x38, modifierFlags: [])
            runtime.dispatchModifierFlagsChanged(keyCode: 0x3B, modifierFlags: [.control])
            runtime.dispatchModifierFlagsChanged(keyCode: 0x3B, modifierFlags: [])
            runtime.dispatchModifierFlagsChanged(keyCode: 0x3A, modifierFlags: [.option])
            runtime.dispatchModifierFlagsChanged(keyCode: 0x3A, modifierFlags: [])
            runtime.dispatchModifierFlagsChanged(keyCode: 0x37, modifierFlags: [.command])
            runtime.dispatchModifierFlagsChanged(keyCode: 0x37, modifierFlags: [])
            runtime.dispatchModifierFlagsChanged(keyCode: 0x39, modifierFlags: [.capsLock])
            runtime.dispatchModifierFlagsChanged(keyCode: 0x39, modifierFlags: [])
            runtime.dispatchModifierFlagsChanged(keyCode: 0xFF, modifierFlags: [])
            modifierOnlyOk = runtime.status == .running
            runtime.dispatchInsertedText("printf 'ime-é-ok\\n'")
            runtime.dispatchKeyDown(keyCode: 0x24, characters: "\r")
            runtime.dispatchMarkedText("ime-compose")
            markedTextCleared = runtime.dispatchInsertedText(" ")
            capture("pre-scroll", tSec: 4.0)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) {
            preScrollText = runtime.visibleText()
            imeInsertedTextSeen = preScrollText.contains("ime-é-ok")
            capture("ime-inserted-text", tSec: 5.2)
            runtime.scrollDirectly(deltaY: 400)
        }

        // 4.4s — exercise the canvas: pan the viewport and drag the terminal
        // tile a few world units. The canvas writes get coalesced through
        // the 200ms save timer; flushCanvasSave() in the verification block
        // forces it out before we read the file.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.4) {
            guard let canvasView = self.canvasView else { return }
            // Pan: shift origin to (10, 5) world units.
            var v = canvasView.viewport
            v.x = 10
            v.y = 5
            canvasView.setViewport(v)
            // Drag: move the terminal tile right by 25 world units.
            if let terminalTile = canvasView.canvasState.tiles.first(where: { $0.kind == .terminal }) {
                let moved = CanvasEngine.tile(
                    terminalTile,
                    draggedByScreenDelta: CGSize(width: 25 * v.zoom, height: 0),
                    viewport: v
                )
                canvasView.updateTile(moved)
            }
            capture("pan-and-drag", tSec: 4.4)
        }

        // 6.0s — verify and close through the production close path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            let visibleText = runtime.visibleText()
            let occurrences = visibleText.components(separatedBy: "ghostty-ok").count - 1
            let textPathOk = occurrences >= 1
            // The initial echo produces 3 occurrences (shell echoes typed input
            // before its prompt is ready, so the typed line shows twice plus the
            // echo output). A successful key path adds at least one more
            // occurrence from the recalled `echo ghostty-ok` execution. Without
            // ghostty_surface_key, the PUA up-arrow codepoint goes nowhere, the
            // recall does not happen, and we cap at 3.
            //
            // Note: by t=5.0 the smoke test has scrolled up, so the viewport
            // shows older content rather than the most-recent prompts. The
            // initial echo + recall lines should still appear in the scrolled
            // viewport (if scroll moved up enough), so we keep the >= 4 floor.
            let keyPathOk = occurrences >= 4
            let scrollOk = preScrollText != visibleText

            // P2.6 — persistence must have landed by the time we get here.
            // P3.4 — also assert the canvas has ≥ 3 tiles, the drag landed,
            // and the viewport advanced from its initial position.
            // P4.5 — assert the spawned secondary terminal landed in
            // sessions/*.json with its launchProfileId, that both sessions
            // have non-nil profile ids and distinct tile ids, and that the
            // canvas now contains ≥ 4 tiles (3 seeded + 1 spawned).
            var persistenceOk = false
            var canvasOk = false
            var multiTerminalOk = false
            var browserOk = false
            var midExitOk = false
            var noteOk = false
            var fileOk = false
            var fileTreeOk = false
            let browserTileCount = self.canvasView?.canvasState.tiles.filter { $0.kind == .browser }.count ?? 0
            // Cardinality is gating, not advisory: if browserRuntimes count drifts
            // from the canvas's live .browser tile count, runtimes leaked or were
            // dropped without canvas update — that's a regression worth failing on.
            let browserCardinalityOk = self.browserRuntimes.count == browserTileCount
            if !browserCardinalityOk {
                fputs("Smoke cardinality: browserRuntimes.count=\(self.browserRuntimes.count) != browserTileCount=\(browserTileCount)\n", stderr)
            }
            do {
                let project = try self.projectStore?.loadProject()
                let sessions = try self.projectStore?.listSessions() ?? []
                let registry = try self.registryStore?.loadOrEmpty()
                persistenceOk =
                    project != nil
                    && sessions.contains(where: { $0.id == runtime.id })
                    && (registry?.projects.contains(where: { $0.id == project?.id }) ?? false)
                    && registry?.lastActiveProjectId == project?.id

                // The canvas state was force-saved by canvasDidChange's
                // debounced timer; flush manually so this check is exact.
                self.flushCanvasSave()
                self.flushBrowserSave()
                self.flushNoteSave()
                let canvasOnDisk = try self.projectStore?.loadCanvas()
                let tileCount = canvasOnDisk?.tiles.count ?? 0
                let viewportMoved = (canvasOnDisk?.viewport.x ?? 0) != 0
                    || (canvasOnDisk?.viewport.y ?? 0) != 0
                let terminalTileMoved = canvasOnDisk?.tiles
                    .first(where: { $0.kind == .terminal })?
                    .frame.x != 40
                canvasOk = tileCount >= 4 && (viewportMoved || terminalTileMoved)

                let primary = sessions.first(where: { $0.id == runtime.id })
                let secondary = secondaryRuntimeId.flatMap { id in sessions.first(where: { $0.id == id }) }
                let bothLiveHaveProfile = !(primary?.launchProfileId.isEmpty ?? true)
                    && !(secondary?.launchProfileId.isEmpty ?? true)
                let distinctLiveTileIds = primary != nil
                    && secondary != nil
                    && primary?.tileId != secondary?.tileId
                let secondaryOnCanvas = secondaryTileId.map { id in
                    canvasOnDisk?.tiles.contains(where: { $0.id == id && $0.kind == .terminal }) ?? false
                } ?? false
                let liveRuntimeIds = Set(self.runtimes.map { $0.id })
                let noOrphanSessions = sessions.allSatisfy { session in
                    session.lastExit != nil || liveRuntimeIds.contains(session.id)
                }
                multiTerminalOk =
                    noOrphanSessions
                    && primary != nil
                    && secondary != nil
                    && bothLiveHaveProfile
                    && distinctLiveTileIds
                    && secondaryOnCanvas

                // P5.x: assert the mid-session exit handler swapped the secondary's
                // live tile for a TerminalRestartTileNSView and stamped lastExit
                // on its descriptor. The runtime must no longer be live.
                if let id = secondaryRuntimeId, let tileId = secondaryTileId {
                    let runtimeRemoved = !self.runtimes.contains(where: { $0.id == id })
                    let placeholderInstalled = self.canvasView?.tileView(for: tileId) is TerminalRestartTileNSView
                    let descriptorStamped = sessions.first(where: { $0.id == id })?.lastExit != nil
                    midExitOk = runtimeRemoved && placeholderInstalled && descriptorStamped
                    if !midExitOk {
                        fputs(
                            "Mid-exit check: runtimeRemoved=\(runtimeRemoved) placeholderInstalled=\(placeholderInstalled) descriptorStamped=\(descriptorStamped)\n",
                            stderr
                        )
                    }
                }

                // P6.6: assert the seeded note and file descriptors were present
                // before the boot loop, so restore installed real tile views.
                if let noteTile = canvasOnDisk?.tiles.first(where: { $0.id == Self.smokeNoteTileId }),
                   let noteView = self.canvasView?.tileView(for: noteTile.id) as? NoteTileNSView {
                    let noteState = try self.projectStore?.tryLoadNoteState()
                    let noteIndexMatches = noteState?.tiles.contains(where: {
                        $0.id == Self.smokeNoteId && $0.tileId == Self.smokeNoteTileId
                    }) ?? false
                    let trackedViewMatches = self.noteViews[Self.smokeNoteId] === noteView
                    let canvasMetadataMatches = noteTile.metadata.noteId == Self.smokeNoteId
                    let bodyMatches = noteView.textView.string == Self.smokeNoteBody
                    noteOk = trackedViewMatches && canvasMetadataMatches && bodyMatches && noteIndexMatches
                    if !noteOk {
                        fputs(
                            "Note check details: trackedViewMatches=\(trackedViewMatches) canvasMetadataMatches=\(canvasMetadataMatches) bodyMatches=\(bodyMatches) noteIndexMatches=\(noteIndexMatches)\n",
                            stderr
                        )
                    }
                }

                if let fileTile = canvasOnDisk?.tiles.first(where: { $0.id == Self.smokeFileTileId }),
                   let fileView = self.canvasView?.tileView(for: fileTile.id) as? FileTileNSView {
                    let metadataPathMatches = fileTile.metadata.filePath?.hasSuffix(".continuum-revived/smoke-file.txt") ?? false
                    let bodyMatches = fileView.textView.string.contains(Self.smokeFileBody)
                    fileOk = metadataPathMatches && bodyMatches
                    if !fileOk {
                        fputs(
                            "File check details: metadataPathMatches=\(metadataPathMatches) bodyMatches=\(bodyMatches)\n",
                            stderr
                        )
                    }
                }

                if let fileTreeTile = canvasOnDisk?.tiles.first(where: { $0.id == Self.smokeFileTreeTileId }) {
                    let fileTreeState = try self.projectStore?.tryLoadFileTreeState()
                    let stateMatches = fileTreeState?.tiles.contains(where: {
                        $0.tileId == Self.smokeFileTreeTileId
                            && $0.rootPath == project?.rootPath
                            && $0.gitBadges == .off
                    }) ?? false
                    let fileTreeInstalled = self.canvasView?.tileView(for: fileTreeTile.id) is FileTreeTileNSView
                    fileTreeOk = fileTreeTile.kind == .fileTree
                        && fileTreeTile.runtimeRef == nil
                        && stateMatches
                        && fileTreeInstalled
                    if !fileTreeOk {
                        fputs(
                            "File tree check details: kind=\(fileTreeTile.kind) runtimeRef=\(String(describing: fileTreeTile.runtimeRef)) stateMatches=\(stateMatches) fileTreeInstalled=\(fileTreeInstalled)\n",
                            stderr
                        )
                    }
                }

                // P5.6: assert the spawned WKWebView browser landed on disk
                // with the data: URL, the title KVO + persistence path captured
                // "continuum-browser-ok", the canvas tracks it as a .browser
                // tile with .browserTile runtimeRef, and the storageGroupId
                // matches the helper's deterministic output.
                if let project, let tileId = browserTileId {
                    let browserState = try self.projectStore?.tryLoadBrowserState()
                    let browserEntry = browserState?.tiles.first(where: { $0.tileId == tileId })
                    let canvasTile = canvasOnDisk?.tiles.first(where: { $0.id == tileId })
                    let expectedStorageId = BrowserState.storageGroupIdentifier(for: project)
                    let urlMatches = browserEntry?.url.hasPrefix("data:text/html") ?? false
                    let titleMatches = browserEntry?.title == "continuum-browser-ok"
                    let kindMatches = canvasTile?.kind == .browser
                    let runtimeRefMatches = canvasTile?.runtimeRef?.kind == .browserTile
                    let storageIdMatches = browserEntry?.storageGroupId == expectedStorageId
                    let runtimeIdPresent = browserRuntimeId != nil
                    browserOk =
                        urlMatches
                        && titleMatches
                        && kindMatches
                        && runtimeRefMatches
                        && storageIdMatches
                        && runtimeIdPresent
                    if !browserOk {
                        fputs(
                            "Browser check details: urlMatches=\(urlMatches) titleMatches=\(titleMatches) kindMatches=\(kindMatches) runtimeRefMatches=\(runtimeRefMatches) storageIdMatches=\(storageIdMatches) runtimeIdPresent=\(runtimeIdPresent) entry=\(String(describing: browserEntry))\n",
                            stderr
                        )
                    }
                }
            } catch {
                fputs("Persistence check threw: \(error)\n", stderr)
            }

            if textPathOk && keyPathOk && scrollOk && modifierOnlyOk && imeInsertedTextSeen && markedTextCleared && persistenceOk && canvasOk && multiTerminalOk && browserOk && midExitOk && noteOk && fileOk && fileTreeOk && browserCardinalityOk {
                print("Ghostty smoke test passed (text + key + scroll + modifier + ime + persistence + canvas + multiTerminal + browser + midExit + note + file + fileTree, occurrences=\(occurrences))")
                if ProcessInfo.processInfo.environment["CONTINUUM_DUMP_VISIBLE"] == "1" {
                    fputs("--- pre-scroll visible text ---\n", stderr)
                    fputs(preScrollText, stderr)
                    fputs("\n--- post-scroll visible text ---\n", stderr)
                    fputs(visibleText, stderr)
                    fputs("\n--- end ---\n", stderr)
                }
                self.smokeTestExitCode = 0
            } else {
                fputs(
                    "Ghostty smoke test failed: textPathOk=\(textPathOk) keyPathOk=\(keyPathOk) scrollOk=\(scrollOk) modifierOnlyOk=\(modifierOnlyOk) imeInsertedTextSeen=\(imeInsertedTextSeen) markedTextCleared=\(markedTextCleared) persistenceOk=\(persistenceOk) canvasOk=\(canvasOk) multiTerminalOk=\(multiTerminalOk) browserOk=\(browserOk) midExitOk=\(midExitOk) noteOk=\(noteOk) fileOk=\(fileOk) fileTreeOk=\(fileTreeOk) browserCardinalityOk=\(browserCardinalityOk) occurrences=\(occurrences)\n",
                    stderr
                )
                fputs("--- pre-scroll ---\n", stderr)
                fputs(preScrollText, stderr)
                fputs("\n--- post-scroll ---\n", stderr)
                fputs(visibleText, stderr)
                self.smokeTestExitCode = 2
            }

            capture("final-state", tSec: 6.0)
            qaCapture?.writeManifest()
            self.qaPerf?.writeReport()

            // Exercise the production close path: any crash on shutdown surfaces
            // here rather than being hidden behind the manual-teardown shortcut.
            window.performClose(nil)
        }
    }

    private func makeQACapture(window: NSWindow) -> (QACapture?, (String, Double, String?) -> Void) {
        let qaCapture = QACapture()
        let capture: (String, Double, String?) -> Void = { [weak self] step, tSec, notes in
            qaCapture?.capture(
                step: step,
                tSec: tSec,
                window: window,
                canvasState: self?.canvasView?.canvasState,
                notes: notes
            )
        }
        return (qaCapture, capture)
    }

    private func recordLaunchTime() {
        guard let launchStartTime else { return }
        let elapsedMs = (QAPerf.timestamp() - launchStartTime) * 1000
        qaPerf?.recordValue(key: "launch-time", value: elapsedMs, unit: "ms")
        self.launchStartTime = nil
    }

    private func finishQAFlow(
        window: NSWindow,
        qaCapture: QACapture?,
        capture: @escaping (String, Double, String?) -> Void,
        step: String,
        tSec: Double,
        success: Bool,
        notes: String? = nil
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + tSec) {
            self.recordLaunchTime()
            capture(step, tSec, notes)
            qaCapture?.writeManifest()
            self.qaPerf?.writeReport()
            self.smokeTestExitCode = success ? 0 : 2
            window.performClose(nil)
        }
    }

    private func scheduleInitialCapture(_ capture: @escaping (String, Double, String?) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            capture("initial-canvas", 0.2, nil)
        }
    }

    private func runPaletteOpenCloseFlow(window: NSWindow) {
        let (qaCapture, capture) = makeQACapture(window: window)
        scheduleInitialCapture(capture)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.openProfilePalette()
            capture("palette-open", 0.4, nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.profilePalette?.close()
            capture("palette-closed", 0.8, nil)
        }
        finishQAFlow(
            window: window,
            qaCapture: qaCapture,
            capture: capture,
            step: "final-state",
            tSec: 1.1,
            success: true
        )
    }

    private func runCommandProfileFlow(window: NSWindow, profileId: String, label: String) {
        let (qaCapture, capture) = makeQACapture(window: window)
        scheduleInitialCapture(capture)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let notes = self.spawnTerminalForQA(profileId: profileId)
            capture("\(label)-requested", 0.4, notes)
        }
        finishQAFlow(
            window: window,
            qaCapture: qaCapture,
            capture: capture,
            step: "\(label)-final-state",
            tSec: 1.2,
            success: true
        )
    }

    private func spawnTerminalForQA(profileId: String) -> String {
        guard let spawner = tileSpawner else { return "tile spawner unavailable" }
        switch spawner.spawnTerminal(profileId: profileId) {
        case let .spawned(runtime):
            wireRuntimeExitHandler(runtime)
            runtimes.append(runtime)
            return "spawned profile \(profileId)"
        case let .missingCommand(executable):
            return "missing command \(executable) for profile \(profileId)"
        case let .notConfigured(id):
            return "profile \(id) not configured"
        case let .unknownProfile(id):
            return "unknown profile \(id)"
        case let .failure(error):
            return "spawn failed: \(error)"
        }
    }

    private func runBrowserSpawnFlow(window: NSWindow) {
        let (qaCapture, capture) = makeQACapture(window: window)
        scheduleInitialCapture(capture)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let notes = self.spawnBrowserForQA(url: "data:text/html;charset=utf-8,<html><head><title>qa-browser</title></head><body>browser ok</body></html>")
            capture("cmd-3-browser-requested", 0.4, notes)
        }
        finishQAFlow(
            window: window,
            qaCapture: qaCapture,
            capture: capture,
            step: "cmd-3-browser-final-state",
            tSec: 1.4,
            success: true
        )
    }

    private func runBrowserLoadErrorFlow(window: NSWindow) {
        let (qaCapture, capture) = makeQACapture(window: window)
        scheduleInitialCapture(capture)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let notes = self.spawnBrowserForQA(url: "http://127.0.0.1:9/continuum-qa-load-error")
            capture("browser-load-error-requested", 0.4, notes)
        }
        finishQAFlow(
            window: window,
            qaCapture: qaCapture,
            capture: capture,
            step: "browser-load-error-final-state",
            tSec: 1.8,
            success: true
        )
    }

    private func spawnBrowserForQA(url: String) -> String {
        guard let spawner = tileSpawner else { return "tile spawner unavailable" }
        switch spawner.spawnBrowser(url: url) {
        case let .spawned(runtime):
            wireContentProcessTerminationHandler(runtime)
            browserRuntimes.append(runtime)
            return "spawned browser \(runtime.id)"
        case let .invalidURL(url):
            return "invalid URL \(url)"
        case let .failure(error):
            return "browser spawn failed: \(error)"
        }
    }

    private func runTerminalMidExitFlow(window: NSWindow) {
        let (qaCapture, capture) = makeQACapture(window: window)
        scheduleInitialCapture(capture)
        var runtimeId: UUID?
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let spawner = self.tileSpawner else {
                capture("terminal-spawn-skipped", 0.4, "tile spawner unavailable")
                return
            }
            switch spawner.spawnTerminal(profileId: "shell") {
            case let .spawned(runtime):
                self.wireRuntimeExitHandler(runtime)
                self.runtimes.append(runtime)
                runtimeId = runtime.id
                capture("terminal-spawned", 0.4, "spawned shell runtime")
            case let .missingCommand(executable):
                capture("terminal-spawn-skipped", 0.4, "missing command \(executable)")
            case let .notConfigured(id):
                capture("terminal-spawn-skipped", 0.4, "profile \(id) not configured")
            case let .unknownProfile(id):
                capture("terminal-spawn-skipped", 0.4, "unknown profile \(id)")
            case let .failure(error):
                capture("terminal-spawn-skipped", 0.4, "spawn failed: \(error)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if let id = runtimeId,
               let runtime = self.runtimes.first(where: { $0.id == id }) {
                runtime.sendInput(Data("exit\n".utf8))
            }
            capture("terminal-exit-requested", 0.8, nil)
        }
        finishQAFlow(
            window: window,
            qaCapture: qaCapture,
            capture: capture,
            step: "terminal-placeholder-visible",
            tSec: 1.4,
            success: true
        )
    }

    private func runCanvasDragResizeFlow(window: NSWindow) {
        let (qaCapture, capture) = makeQACapture(window: window)
        scheduleInitialCapture(capture)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let canvasView = self.canvasView,
                  let terminalTile = canvasView.canvasState.tiles.first(where: { $0.kind == .terminal })
            else {
                capture("canvas-drag-resize-skipped", 0.4, "terminal tile unavailable")
                return
            }
            var latencies: [Double] = []
            var moved = terminalTile
            for index in 0..<200 {
                let started = QAPerf.timestamp()
                moved = CanvasEngine.tile(
                    moved,
                    draggedByScreenDelta: CGSize(width: index.isMultiple(of: 2) ? 1 : -1, height: 0),
                    viewport: canvasView.viewport
                )
                canvasView.updateTile(moved)
                latencies.append((QAPerf.timestamp() - started) * 1000)
            }
            let resized = CanvasEngine.tile(
                moved,
                resizedByScreenDelta: CGSize(width: 100, height: 60),
                edge: .bottomRight,
                viewport: canvasView.viewport
            )
            canvasView.updateTile(resized)
            self.qaPerf?.recordSamples(key: "drag-latency-p95", samples: latencies, unit: "ms")
            capture("canvas-drag-resize-applied", 0.4, "measured 200 updateTile calls")
        }
        finishQAFlow(
            window: window,
            qaCapture: qaCapture,
            capture: capture,
            step: "canvas-drag-resize-final-state",
            tSec: 1.0,
            success: true
        )
    }

    private func runTerminalStress10Flow(window: NSWindow) {
        let (qaCapture, capture) = makeQACapture(window: window)
        scheduleInitialCapture(capture)
        let memoryBefore = QAPerf.residentMemoryBytes()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            var spawned = 0
            for _ in 0..<10 {
                if self.spawnTerminalForQA(profileId: "shell").hasPrefix("spawned profile") {
                    spawned += 1
                }
            }
            capture("terminal-stress-spawned", 0.4, "spawned \(spawned) shell tiles")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            let memoryAfter = QAPerf.residentMemoryBytes()
            let delta = Int64(memoryAfter) - Int64(memoryBefore)
            self.qaPerf?.recordValue(key: "memory-at-10-tiles", value: Double(delta), unit: "bytes")
            capture("terminal-stress-memory-sampled", 1.4, "delta \(delta) bytes")
        }
        finishQAFlow(
            window: window,
            qaCapture: qaCapture,
            capture: capture,
            step: "terminal-stress-final-state",
            tSec: 1.8,
            success: true
        )
    }

    private func runPaletteLeakCheckFlow(window: NSWindow) {
        let (qaCapture, capture) = makeQACapture(window: window)
        scheduleInitialCapture(capture)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let memoryBefore = QAPerf.residentMemoryBytes()
            autoreleasepool {
                for _ in 0..<25 {
                    self.openProfilePalette()
                    self.profilePalette?.close()
                }
            }
            capture("palette-leak-cycle", 0.4, "opened and closed Cmd-K 25 times")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let memoryAfter = QAPerf.residentMemoryBytes()
                let delta = Int64(memoryAfter) - Int64(memoryBefore)
                self.qaPerf?.recordValue(key: "palette-leak-delta", value: Double(delta), unit: "bytes")
                capture("palette-leak-memory-sampled", 0.6, "delta \(delta) bytes")
            }
        }
        finishQAFlow(
            window: window,
            qaCapture: qaCapture,
            capture: capture,
            step: "palette-leak-final-state",
            tSec: 1.3,
            success: true
        )
    }

    private func runCanvasZoomPanEdgeFlow(window: NSWindow) {
        let (qaCapture, capture) = makeQACapture(window: window)
        scheduleInitialCapture(capture)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let canvasView = self.canvasView else {
                capture("canvas-zoom-pan-skipped", 0.4, "canvas unavailable")
                return
            }
            let anchor = CGPoint(x: canvasView.bounds.maxX - 8, y: canvasView.bounds.maxY - 8)
            var viewport = CanvasEngine.zoom(canvasView.viewport, by: 1.4, anchorScreen: anchor)
            viewport.x += 160
            viewport.y += 120
            canvasView.setViewport(viewport)
            capture("canvas-zoom-pan-edge-applied", 0.4, nil)
        }
        finishQAFlow(
            window: window,
            qaCapture: qaCapture,
            capture: capture,
            step: "canvas-zoom-pan-edge-final-state",
            tSec: 1.0,
            success: true
        )
    }

    private func runEmptyCanvasFlow(window: NSWindow) {
        let (qaCapture, capture) = makeQACapture(window: window)
        scheduleInitialCapture(capture)
        var emptyStateWasInstalled = false
        var emptyStateWasRemoved = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let canvasView = self.canvasView else {
                capture("empty-canvas-skipped", 0.4, "canvas unavailable")
                return
            }
            emptyStateWasInstalled = canvasView.canvasState.tiles.isEmpty && canvasView.emptyStateInstalled
            capture(
                "empty-canvas-visible",
                0.4,
                "tiles \(canvasView.canvasState.tiles.count), empty state \(canvasView.emptyStateInstalled)"
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let notes = self.spawnTerminalForQA(profileId: "shell")
            emptyStateWasRemoved = self.canvasView?.canvasState.tiles.isEmpty == false
                && self.canvasView?.emptyStateInstalled == false
            capture("empty-canvas-spawned-shell", 0.6, notes)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.recordLaunchTime()
            capture("empty-canvas-final-state", 1.0, nil)
            qaCapture?.writeManifest()
            self.qaPerf?.writeReport()
            self.smokeTestExitCode = emptyStateWasInstalled && emptyStateWasRemoved ? 0 : 2
            window.performClose(nil)
        }
    }

    private func runRestartPlaceholderClickFlow(window: NSWindow) {
        let (qaCapture, capture) = makeQACapture(window: window)
        scheduleInitialCapture(capture)
        var tileId: UUID?
        var runtimeId: UUID?
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let spawner = self.tileSpawner else {
                capture("restart-spawn-skipped", 0.4, "tile spawner unavailable")
                return
            }
            switch spawner.spawnTerminal(profileId: "shell") {
            case let .spawned(runtime):
                self.wireRuntimeExitHandler(runtime)
                self.runtimes.append(runtime)
                runtimeId = runtime.id
                tileId = runtime.tileId
                capture("restart-terminal-spawned", 0.4, nil)
            case let .missingCommand(executable):
                capture("restart-spawn-skipped", 0.4, "missing command \(executable)")
            case let .notConfigured(id):
                capture("restart-spawn-skipped", 0.4, "profile \(id) not configured")
            case let .unknownProfile(id):
                capture("restart-spawn-skipped", 0.4, "unknown profile \(id)")
            case let .failure(error):
                capture("restart-spawn-skipped", 0.4, "spawn failed: \(error)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if let id = runtimeId,
               let runtime = self.runtimes.first(where: { $0.id == id }) {
                runtime.sendInput(Data("exit\n".utf8))
            }
            capture("restart-placeholder-requested", 0.8, nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            if let tileId {
                self.restartTile(tileId: tileId)
                capture("restart-placeholder-clicked", 1.3, nil)
            } else {
                capture("restart-placeholder-click-skipped", 1.3, "tile id unavailable")
            }
        }
        finishQAFlow(
            window: window,
            qaCapture: qaCapture,
            capture: capture,
            step: "restart-placeholder-final-state",
            tSec: 1.8,
            success: true
        )
    }
}

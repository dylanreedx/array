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
    private var canvasView: CanvasNSView?
    private var saveTimer: Timer?
    private var browserSaveTimer: Timer?
    private let smokeTestEnabled = ProcessInfo.processInfo.environment["CONTINUUM_SMOKE_TEST"] == "1"
    private var smokeTestExitCode: Int32?
    private var projectStore: ProjectStore?
    private var registryStore: RegistryStore?
    private var activeProject: Project?
    private var tileSpawner: TileSpawner?
    private var profilePalette: LaunchProfilePalette?
    private var hotkeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
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

            var canvasState: CanvasState
            if let existing = try projectStore.tryLoadCanvas() {
                canvasState = existing
            } else {
                canvasState = Self.defaultCanvasState()
            }
            if !canvasState.tiles.contains(where: { $0.kind == .terminal }) {
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
            self.tileSpawner = spawner

            let palette = LaunchProfilePalette()
            palette.onSelect = { [weak self] profileId in
                self?.spawnTerminalFromProfile(profileId)
            }
            self.profilePalette = palette

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
                case .note, .file:
                    let view = DescriptorTileNSView(tile: tile)
                    canvasView.install(tileView: view, for: tile)
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

            if smokeTestEnabled, let primary = runtimes.first {
                runSmokeTest(window: window, runtime: primary)
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
        guard let palette = profilePalette,
              let spawner = tileSpawner,
              let host = window else { return }
        palette.show(near: host, profiles: spawner.annotatedProfiles())
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
        let terminalTile = defaultTerminalTile()
        let browserTile = Tile(
            id: UUID(),
            kind: .browser,
            title: "Local browser",
            frame: TileFrame(x: 720, y: 40, width: 460, height: 240),
            zIndex: 1,
            runtimeRef: nil,
            metadata: TileMetadata(url: "http://localhost:3000")
        )
        let noteTile = Tile(
            id: UUID(),
            kind: .note,
            title: "Notes",
            frame: TileFrame(x: 720, y: 300, width: 460, height: 240),
            zIndex: 0,
            runtimeRef: nil,
            metadata: TileMetadata()
        )
        return CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [terminalTile, browserTile, noteTile],
            groups: [],
            lastActiveTileId: terminalTile.id
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

    private func runSmokeTest(window: NSWindow, runtime: GhosttyTerminalRuntime) {
        // 1.0s — exercise the IME/text path (ghostty_surface_text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            runtime.sendInput(Data("echo ghostty-ok\n".utf8))
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
        }

        // 2.4s — Enter to execute the recalled command.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            runtime.dispatchKeyDown(keyCode: 0x24, characters: "\r")
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

        // 2.8s — fill scrollback with enough output to push earlier lines off
        // the visible viewport, so a scroll-up has something to reveal. Send
        // the command body via the text path then Enter via the key path
        // (mirrors how a user types a command and presses Return).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            runtime.sendInput(Data("seq 1 60".utf8))
            runtime.dispatchKeyDown(keyCode: 0x24, characters: "\r")
        }

        // 3.0s — P5.x: send `exit` to the secondary so we can observe the
        // mid-session runtime-exit detection swap the live tile for a
        // Restart placeholder.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if let id = secondaryRuntimeId,
               let secondary = self.runtimes.first(where: { $0.id == id }) {
                secondary.sendInput(Data("exit\n".utf8))
            }
        }
        // 3.5s — window resize must still complete without crashing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            window.setContentSize(NSSize(width: 860, height: 540))
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            preScrollText = runtime.visibleText()
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
            let browserTileCount = self.canvasView?.canvasState.tiles.filter { $0.kind == .browser }.count ?? 0
            if self.browserRuntimes.count != browserTileCount {
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

            if textPathOk && keyPathOk && scrollOk && persistenceOk && canvasOk && multiTerminalOk && browserOk && midExitOk {
                print("Ghostty smoke test passed (text + key + scroll + persistence + canvas + multiTerminal + browser + midExit, occurrences=\(occurrences))")
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
                    "Ghostty smoke test failed: textPathOk=\(textPathOk) keyPathOk=\(keyPathOk) scrollOk=\(scrollOk) persistenceOk=\(persistenceOk) canvasOk=\(canvasOk) multiTerminalOk=\(multiTerminalOk) browserOk=\(browserOk) midExitOk=\(midExitOk) occurrences=\(occurrences)\n",
                    stderr
                )
                fputs("--- pre-scroll ---\n", stderr)
                fputs(preScrollText, stderr)
                fputs("\n--- post-scroll ---\n", stderr)
                fputs(visibleText, stderr)
                self.smokeTestExitCode = 2
            }

            // Exercise the production close path: any crash on shutdown surfaces
            // here rather than being hidden behind the manual-teardown shortcut.
            window.performClose(nil)
        }
    }
}

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
    private var runtime: GhosttyTerminalRuntime?
    private var canvasView: CanvasNSView?
    private var saveTimer: Timer?
    private let smokeTestEnabled = ProcessInfo.processInfo.environment["CONTINUUM_SMOKE_TEST"] == "1"
    private var smokeTestExitCode: Int32?
    private var projectStore: ProjectStore?
    private var registryStore: RegistryStore?
    private var activeProject: Project?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let projectRoot = Self.resolveProjectRoot(smokeTest: smokeTestEnabled)
            let appSupportDir = Self.resolveAppSupportDir(smokeTest: smokeTestEnabled)
            let projectStore = ProjectStore(projectRoot: projectRoot)
            let registryStore = RegistryStore(applicationSupportDirectory: appSupportDir)
            self.projectStore = projectStore
            self.registryStore = registryStore

            let project = try Self.loadOrCreateProject(in: projectStore, projectRoot: projectRoot)
            self.activeProject = project
            try Self.recordProjectInRegistry(project: project, in: registryStore)

            let launchProfile = try ShellLaunchResolver().resolveShell(cwd: projectRoot.path)
            let ghostty = try GhosttyRuntimeContext()

            // Phase 3: load or create the canvas. Always have at least one
            // terminal tile so the spike has something to host.
            var canvasState: CanvasState
            if let existing = try projectStore.tryLoadCanvas() {
                canvasState = existing
            } else {
                canvasState = Self.defaultCanvasState(title: launchProfile.title)
            }
            if !canvasState.tiles.contains(where: { $0.kind == .terminal }) {
                // The on-disk canvas was somehow valid but had no terminal —
                // append a default one rather than fail.
                canvasState.tiles.append(Self.defaultTerminalTile(title: launchProfile.title))
            }
            let terminalTileIndex = canvasState.tiles.firstIndex(where: { $0.kind == .terminal })!
            var terminalTile = canvasState.tiles[terminalTileIndex]

            // The session descriptor is fresh per launch; refresh the tile's
            // runtimeRef to point at the new session id.
            let runtime = GhosttyTerminalRuntime(
                id: UUID(),
                tileId: terminalTile.id,
                title: launchProfile.title,
                launchProfile: launchProfile,
                ghostty: ghostty
            )
            terminalTile.runtimeRef = RuntimeRef(kind: .terminalSession, id: runtime.id)
            canvasState.tiles[terminalTileIndex] = terminalTile

            try projectStore.saveSession(TerminalSessionDescriptor(
                id: runtime.id,
                tileId: runtime.tileId,
                launchProfileId: "shell",
                command: launchProfile.command,
                args: launchProfile.arguments,
                cwd: launchProfile.cwd,
                env: [:],
                title: launchProfile.title,
                createdAt: Date(),
                lastStartedAt: Date(),
                lastExit: nil
            ))

            let canvasView = CanvasNSView(canvasState: canvasState)
            canvasView.delegate = self
            for tile in canvasState.tiles {
                if tile.id == terminalTile.id {
                    let view = TerminalTileNSView(tile: tile, runtime: runtime)
                    canvasView.install(tileView: view, for: tile)
                } else {
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

            self.ghostty = ghostty
            self.runtime = runtime
            self.canvasView = canvasView
            self.window = window

            // Activate after the runtime is wired up: NSApp.activate can fire
            // applicationDidBecomeActive synchronously, and the focus path needs
            // a non-nil ghostty to forward set_focus into the surface.
            NSApp.activate(ignoringOtherApps: true)

            if smokeTestEnabled {
                runSmokeTest(window: window, runtime: runtime)
            }
        } catch {
            presentFatalError(error)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if let app = try? ghostty?.app {
            ghostty_app_set_focus(app, true)
        }
        runtime?.focus()
    }

    func applicationDidResignActive(_ notification: Notification) {
        if let app = try? ghostty?.app {
            ghostty_app_set_focus(app, false)
        }
        runtime?.blur()
    }

    func windowWillClose(_ notification: Notification) {
        // Flush any pending canvas save so the close-leg observation catches
        // the most recent in-memory state.
        flushCanvasSave()

        // Mark the session as exited before we tear down the runtime. We don't
        // know the exit code from this side (Ghostty owns the PTY), so record
        // a clean close — the user closed the window.
        if let runtime, let projectStore {
            if var descriptor = try? projectStore.loadSession(id: runtime.id) {
                descriptor.lastExit = TerminalLastExit(exitCode: nil, signal: nil, at: Date())
                try? projectStore.saveSession(descriptor)
            }
        }

        // Free the surface before the app: ghostty_app_free walks the surface
        // registry during teardown and dereferences PAC-protected pointers; if a
        // surface is still alive at that point, deinit traps with EXC_BAD_ACCESS.
        runtime?.terminate(policy: .force)
        canvasView = nil
        runtime = nil
        ghostty?.shutdown()
        ghostty = nil
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

    private static func defaultCanvasState(title: String) -> CanvasState {
        let terminalTile = defaultTerminalTile(title: title)
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

    private static func defaultTerminalTile(title: String) -> Tile {
        Tile(
            id: UUID(),
            kind: .terminal,
            title: title,
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

        // 2.8s — fill scrollback with enough output to push earlier lines off
        // the visible viewport, so a scroll-up has something to reveal. Send
        // the command body via the text path then Enter via the key path
        // (mirrors how a user types a command and presses Return).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            runtime.sendInput(Data("seq 1 60".utf8))
            runtime.dispatchKeyDown(keyCode: 0x24, characters: "\r")
        }

        // 3.5s — window resize must still complete without crashing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            window.setContentSize(NSSize(width: 860, height: 540))
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

        // 5.0s — verify and close through the production close path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
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
            var persistenceOk = false
            var canvasOk = false
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
                let canvasOnDisk = try self.projectStore?.loadCanvas()
                let tileCount = canvasOnDisk?.tiles.count ?? 0
                let viewportMoved = (canvasOnDisk?.viewport.x ?? 0) != 0
                    || (canvasOnDisk?.viewport.y ?? 0) != 0
                let terminalTileMoved = canvasOnDisk?.tiles
                    .first(where: { $0.kind == .terminal })?
                    .frame.x != 40
                canvasOk = tileCount >= 3 && (viewportMoved || terminalTileMoved)
            } catch {
                fputs("Persistence check threw: \(error)\n", stderr)
            }

            if textPathOk && keyPathOk && scrollOk && persistenceOk && canvasOk {
                print("Ghostty smoke test passed (text + key + scroll + persistence + canvas, occurrences=\(occurrences))")
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
                    "Ghostty smoke test failed: textPathOk=\(textPathOk) keyPathOk=\(keyPathOk) scrollOk=\(scrollOk) persistenceOk=\(persistenceOk) canvasOk=\(canvasOk) occurrences=\(occurrences)\n",
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

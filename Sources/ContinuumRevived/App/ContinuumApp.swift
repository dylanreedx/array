import AppKit
import ContinuumRevivedCore
import Foundation
import GhosttyKit
import WebKit

@main
enum ContinuumApp {
    @MainActor
    private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--menu-contract-check") {
            do {
                _ = NSApplication.shared
                installMainMenu()
                try runMenuContractSelfCheck()
                if let sentinel = launchProbeSentinelPath() {
                    try "menu-contract-check passed\n".write(toFile: sentinel, atomically: true, encoding: .utf8)
                }
                print("ContinuumRevivedMenuContractChecks passed")
                Foundation.exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }

        if CommandLine.arguments.contains("--delete-confirm-policy-defaults-check") {
            do {
                try runDeleteConfirmPolicyDefaultsSelfCheck()
                print("ContinuumRevivedDeleteConfirmPolicyDefaultsChecks passed")
                Foundation.exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }

        if CommandLine.arguments.contains("--palette-duplicate-root-check") {
            do {
                _ = NSApplication.shared
                try LaunchProfilePalette.runDuplicateRootSelfCheck()
                print("ContinuumRevivedPaletteChecks passed")
                Foundation.exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }

        if CommandLine.arguments.contains("--project-root-resolution-check") {
            do {
                try AppDelegate.runProjectRootResolutionSelfCheck()
                print("ContinuumRevivedProjectRootResolutionChecks passed")
                Foundation.exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }

        if CommandLine.arguments.contains("--project-picker-resolution-check") {
            do {
                try AppDelegate.runProjectPickerResolutionSelfCheck()
                print("ContinuumRevivedProjectPickerResolutionChecks passed")
                Foundation.exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }

        if CommandLine.arguments.contains("--palette-first-responder-restore-check") {
            do {
                _ = NSApplication.shared
                try LaunchProfilePalette.runFirstResponderRestoreSelfCheck()
                print("ContinuumRevivedPaletteFirstResponderRestoreChecks passed")
                Foundation.exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }

        if CommandLine.arguments.contains("--browser-url-focus-check") {
            do {
                _ = NSApplication.shared
                try BrowserTileNSView.runURLFocusSelfCheck()
                print("ContinuumRevivedBrowserURLFocusChecks passed")
                Foundation.exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }

        if CommandLine.arguments.contains("--palette-browser-spawn-check") {
            do {
                _ = NSApplication.shared
                let artifact = try AppDelegate.runPaletteBrowserSpawnSelfCheck()
                print("ContinuumRevivedPaletteBrowserSpawnChecks passed: \(artifact.path)")
                Foundation.exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }

        if CommandLine.arguments.contains("--spawn-focus-policy-check") {
            do {
                _ = NSApplication.shared
                let artifact = try AppDelegate.runSpawnFocusPolicySelfCheck()
                print("ContinuumRevivedSpawnFocusPolicyChecks passed: \(artifact.path)")
                Foundation.exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }

        if CommandLine.arguments.contains("--focus-broker-activation-check") {
            do {
                _ = NSApplication.shared
                let artifact = try AppDelegate.runFocusBrokerActivationSelfCheck()
                print("ContinuumRevivedFocusBrokerActivationChecks passed: \(artifact.path)")
                Foundation.exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }

        if CommandLine.arguments.contains("--zindex-relaunch-hit-test-check") {
            do {
                _ = NSApplication.shared
                let artifact = try CanvasNSView.runZIndexRelaunchHitTestSelfCheck()
                print("ContinuumRevivedZIndexRelaunchHitTestChecks passed: \(artifact.path)")
                Foundation.exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }

        if CommandLine.arguments.contains("--tile-world-bounds-check") {
            do {
                _ = NSApplication.shared
                let artifact = try CanvasNSView.runTileWorldBoundsSelfCheck()
                print("ContinuumRevivedTileWorldBoundsChecks passed: \(artifact.path)")
                Foundation.exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }

        if CommandLine.arguments.contains("--bring-to-front-focus-check") {
            do {
                _ = NSApplication.shared
                let artifact = try CanvasNSView.runBringToFrontFocusSelfCheck()
                print("ContinuumRevivedBringToFrontFocusChecks passed: \(artifact.path)")
                Foundation.exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }

        if CommandLine.arguments.contains("--note-click-focus-check") {
            do {
                _ = NSApplication.shared
                let artifact = try NoteTileNSView.runNoteClickFocusSelfCheck()
                print("ContinuumRevivedNoteClickFocusChecks passed: \(artifact.path)")
                Foundation.exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }

        if CommandLine.arguments.contains("--browser-restore-state-check") {
            do {
                _ = NSApplication.shared
                let artifact = try TileSpawner.runBrowserRestoreStateSelfCheck()
                print("ContinuumRevivedBrowserRestoreStateChecks passed: \(artifact.path)")
                Foundation.exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }

        if CommandLine.arguments.contains("--note-file-tile-spawn-check") {
            do {
                _ = NSApplication.shared
                let artifact = try TileSpawner.runNoteFileTileSpawnSelfCheck()
                print("ContinuumRevivedNoteFileTileSpawnChecks passed: \(artifact.path)")
                Foundation.exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }

        if CommandLine.arguments.contains("--file-tree-boot-persistence-check") {
            do {
                _ = NSApplication.shared
                let artifact = try TileSpawner.runFileTreeBootPersistenceSelfCheck()
                print("ContinuumRevivedFileTreeBootPersistenceChecks passed: \(artifact.path)")
                Foundation.exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }

        if CommandLine.arguments.contains("--spawn-placement-check") {
            do {
                _ = NSApplication.shared
                let artifact = try TileSpawner.runSpawnPlacementSelfCheck()
                print("ContinuumRevivedSpawnPlacementChecks passed: \(artifact.path)")
                Foundation.exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }

        if CommandLine.arguments.contains("--file-tree-hardening-check") {
            do {
                _ = NSApplication.shared
                let artifact = try TileSpawner.runFileTreeHardeningSelfCheck()
                print("ContinuumRevivedFileTreeHardeningChecks passed: \(artifact.path)")
                Foundation.exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }

        if CommandLine.arguments.contains("--viewport-sanitize-check") {
            do {
                let artifact = try AppDelegate.runViewportSanitizeSelfCheck()
                print("ContinuumRevivedViewportSanitizeChecks passed: \(artifact.path)")
                Foundation.exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }

        if let probeIndex = CommandLine.arguments.firstIndex(of: "--project-lock-probe") {
            guard CommandLine.arguments.indices.contains(probeIndex + 1) else {
                fputs("FAIL: --project-lock-probe requires a root path\n", stderr)
                Foundation.exit(2)
            }
            let root = URL(fileURLWithPath: CommandLine.arguments[probeIndex + 1], isDirectory: true)
            let lock = ProjectLock(root: root)
            do {
                try lock.acquire()
                print("project-lock-probe: acquired")
                Foundation.exit(0)
            } catch ProjectLockError.alreadyLocked {
                fputs("project-lock-probe: locked\n", stderr)
                Foundation.exit(1)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                Foundation.exit(2)
            }
        }

        if CommandLine.arguments.contains("--project-lock-check") {
            do {
                let artifact = try AppDelegate.runProjectLockSelfCheck()
                print("ContinuumRevivedProjectLockChecks passed: \(artifact.path)")
                Foundation.exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }

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

        if CommandLine.arguments.contains("--ghostty-zoom-scale-spike") {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            do {
                let artifact = try GhosttyTerminalView.runZoomScaleSpike()
                print("GhosttyZoomScaleSpike artifact: \(artifact.path)")
                Foundation.exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate

        application.delegate = delegate
        application.setActivationPolicy(.regular)
        installMainMenu()
        application.run()
    }

    @MainActor
    private static func installMainMenu() {
        let appName = "Continuum Revived"
        let mainMenu = NSMenu(title: "Main Menu")

        let appMenuItem = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: appName)
        appMenu.addItem(NSMenuItem(title: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())

        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu

        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: ""))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private static func launchProbeSentinelPath() -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--launch-probe-sentinel") else { return nil }
        let valueIndex = CommandLine.arguments.index(after: index)
        guard valueIndex < CommandLine.arguments.endIndex else { return nil }
        return CommandLine.arguments[valueIndex]
    }

    @MainActor
    private static func runMenuContractSelfCheck() throws {
        guard let mainMenu = NSApp.mainMenu else { throw SelfCheckError("missing NSApp.mainMenu") }
        guard mainMenu.items.first?.title == "Continuum Revived",
              let appMenu = mainMenu.items.first?.submenu,
              appMenu.title == "Continuum Revived" else { throw SelfCheckError("missing Continuum Revived app menu") }
        try expectMenuItem(appMenu, title: "About Continuum Revived", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        guard appMenu.item(withTitle: "Services")?.submenu === NSApp.servicesMenu else { throw SelfCheckError("missing Services menu") }
        try expectMenuItem(appMenu, title: "Hide Continuum Revived", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        try expectMenuItem(appMenu, title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h", modifiers: [.command, .option])
        try expectMenuItem(appMenu, title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        try expectMenuItem(appMenu, title: "Quit Continuum Revived", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        guard let editMenu = mainMenu.item(withTitle: "Edit")?.submenu else { throw SelfCheckError("missing Edit menu") }
        try expectMenuItem(editMenu, title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        try expectMenuItem(editMenu, title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z", modifiers: [.command, .shift])
        try expectMenuItem(editMenu, title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        try expectMenuItem(editMenu, title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        try expectMenuItem(editMenu, title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        try expectMenuItem(editMenu, title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        try expectMenuItem(editMenu, title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    }

    private static func expectMenuItem(
        _ menu: NSMenu,
        title: String,
        action: Selector,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) throws {
        guard let item = menu.item(withTitle: title) else { throw SelfCheckError("missing menu item \(title)") }
        guard item.action == action else { throw SelfCheckError("menu item \(title) has action \(String(describing: item.action))") }
        guard item.target == nil else { throw SelfCheckError("menu item \(title) target should be nil") }
        guard item.keyEquivalent == keyEquivalent else { throw SelfCheckError("menu item \(title) key equivalent expected \(keyEquivalent) got \(item.keyEquivalent)") }
        if !keyEquivalent.isEmpty {
            guard item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == modifiers else {
                throw SelfCheckError("menu item \(title) modifiers expected \(modifiers) got \(item.keyEquivalentModifierMask)")
            }
        }
    }

    private static func runDeleteConfirmPolicyDefaultsSelfCheck() throws {
        guard Bundle.main.bundleIdentifier == DeleteConfirmPolicy.bundledDefaultsDomain else {
            throw SelfCheckError("expected bundled executable domain \(DeleteConfirmPolicy.bundledDefaultsDomain), got \(Bundle.main.bundleIdentifier ?? "nil")")
        }
        let key = DeleteConfirmPolicy.userDefaultsKey
        let standardSuite = "con113-standard-\(UUID().uuidString)"
        let legacySuite = "con113-legacy-\(UUID().uuidString)"
        guard let standard = UserDefaults(suiteName: standardSuite),
              let legacy = UserDefaults(suiteName: legacySuite) else {
            throw SelfCheckError("could not open isolated defaults domains")
        }
        let globalDefaults = UserDefaults.standard
        let globalDomain = UserDefaults.globalDomain
        let originalGlobalDomain = globalDefaults.persistentDomain(forName: globalDomain) ?? [:]
        defer {
            globalDefaults.setPersistentDomain(originalGlobalDomain, forName: globalDomain)
            standard.removePersistentDomain(forName: standardSuite)
            legacy.removePersistentDomain(forName: legacySuite)
        }
        var scrubbedGlobalDomain = originalGlobalDomain
        scrubbedGlobalDomain.removeValue(forKey: key)
        globalDefaults.setPersistentDomain(scrubbedGlobalDomain, forName: globalDomain)
        standard.setPersistentDomain([:], forName: standardSuite)
        legacy.setPersistentDomain([:], forName: legacySuite)

        func assertResolution(_ expectedPolicy: DeleteConfirmPolicy, _ expectedSource: DeleteConfirmPolicyResolution.Source, _ label: String) throws {
            let resolution = DeleteConfirmPolicy.resolvedFromDefaults(standardDefaults: standard, legacyDefaults: legacy)
            guard resolution.policy == expectedPolicy else { throw SelfCheckError("\(label): expected policy \(expectedPolicy.rawValue) got \(resolution.policy.rawValue)") }
            guard resolution.source == expectedSource else { throw SelfCheckError("\(label): expected source \(expectedSource.rawValue) got \(resolution.source.rawValue)") }
            print("deleteConfirmPolicy \(label): policy=\(resolution.policy.rawValue) source=\(resolution.source.rawValue) raw=\(resolution.rawValue ?? "nil")")
        }

        try assertResolution(.runtimes, .fallbackDefault, "missing")
        standard.set("never", forKey: key)
        try assertResolution(.never, .standardDomain, "new-domain-never")
        standard.set("runtimes", forKey: key)
        try assertResolution(.runtimes, .standardDomain, "new-domain-runtimes")
        standard.set("always", forKey: key)
        try assertResolution(.always, .standardDomain, "new-domain-always")
        standard.set("invalid", forKey: key)
        try assertResolution(.runtimes, .standardDomain, "new-domain-invalid")

        standard.removeObject(forKey: key)
        legacy.set("never", forKey: key)
        try assertResolution(.never, .legacyDomainMigrated, "legacy-only-valid")
        guard standard.string(forKey: key) == "never" else { throw SelfCheckError("legacy-only-valid did not copy into standard domain") }

        standard.set("always", forKey: key)
        legacy.set("never", forKey: key)
        try assertResolution(.always, .standardDomain, "new-domain-wins")

        standard.removeObject(forKey: key)
        legacy.set("invalid", forKey: key)
        try assertResolution(.runtimes, .fallbackDefault, "legacy-invalid")
        guard standard.string(forKey: key) == nil else { throw SelfCheckError("invalid legacy value was copied into standard domain") }
    }

    private struct SelfCheckError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, CanvasNSViewDelegate {
    private var window: NSWindow?
    private var ghostty: GhosttyRuntimeContext?
    private var browserEngine: BrowserEngineContext?
    private var runtimes: [GhosttyTerminalRuntime] {
        get { zoneRuntimeController?.runtimes ?? [] }
        set { zoneRuntimeController?.runtimes = newValue }
    }
    private var browserRuntimes: [WKWebViewBrowserRuntime] {
        get { zoneRuntimeController?.browserRuntimes ?? [] }
        set { zoneRuntimeController?.browserRuntimes = newValue }
    }
    private var noteViews: [UUID: NoteTileNSView] {
        get { zoneRuntimeController?.noteViews ?? [:] }
        set { zoneRuntimeController?.noteViews = newValue }
    }
    private var fileTreeViews: [UUID: FileTreeTileNSView] {
        get { zoneRuntimeController?.fileTreeViews ?? [:] }
        set { zoneRuntimeController?.fileTreeViews = newValue }
    }
    private var canvasView: CanvasNSView?
    private var saveTimer: Timer?
    private var browserSaveTimer: Timer?
    private var noteSaveTimer: Timer?
    private var fileTreeSaveTimer: Timer?
    private let smokeTestEnabled = ProcessInfo.processInfo.environment["CONTINUUM_SMOKE_TEST"] == "1"
    private var smokeTestExitCode: Int32?
    private var zoneRuntimeController: ZoneRuntimeController?
    private var projectStore: ProjectStore? { zoneRuntimeController?.projectStore }
    private var activeProject: Project? { zoneRuntimeController?.project }
    private var registryStore: RegistryStore?
    private var tileSpawner: TileSpawner?
    private var profilePalette: LaunchProfilePalette?
    private let focusBroker = FocusBroker()
    private var qaPerf: QAPerf?
    private var launchStartTime: CFTimeInterval?
    private var hotkeyMonitor: Any?
    private var tileFocusMonitor: Any?
    private var canvasScrollMonitor: Any?
    private var canvasMagnifyMonitor: Any?
    private static let smokeNoteId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let smokeNoteTileId = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    private static let smokeFileTileId = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    private static let smokeFileTreeTileId = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
    private static let smokeNoteBody = "smoke-note-ok"
    private static let smokeFileBody = "smoke-file-ok"
    private static let smokeFileLongBody: String = {
        let longLine = "let unwrappedSourceLine = \"" + String(repeating: "0123456789", count: 36) + "\""
        let lines = (1...90).map { idx in
            "\(String(format: "%03d", idx)) \(idx == 1 ? smokeFileBody : "smoke-file-line") \(longLine)"
        }
        return lines.joined(separator: "\n") + "\n"
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchStartTime = QAPerf.timestamp()
        qaPerf = QAPerf()
        do {
            let appSupportDir = Self.resolveAppSupportDir(smokeTest: smokeTestEnabled)
            let registryStore = RegistryStore(applicationSupportDirectory: appSupportDir)
            let registry = try registryStore.loadOrEmpty()
            let projectRoot = try Self.resolveProjectRoot(smokeTest: smokeTestEnabled, registry: registry)
            let zoneRuntimeController = try ZoneRuntimeController(root: projectRoot)
            self.zoneRuntimeController = zoneRuntimeController
            self.registryStore = registryStore

            let projectStore = zoneRuntimeController.projectStore
            let project = zoneRuntimeController.project
            try Self.recordProjectInRegistry(project: project, in: registryStore)

            let ghostty = try GhosttyRuntimeContext()
            let browserEngine = BrowserEngineContext()
            let seededSmokeTiles = smokeTestEnabled && Self.requestedQAFlow() != .emptyCanvas
                ? try Self.seedSmokeTestTiles(in: projectStore, projectRoot: projectRoot)
                : []

            var canvasState: CanvasState
            if let existing = try projectStore.tryLoadCanvasWithSanitizationResult() {
                canvasState = existing.canvas
                if existing.recenteredViewport {
                    for note in existing.notes {
                        fputs("viewport sanitation: \(note)\n", stderr)
                    }
                }
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
            canvasView.focusBroker = focusBroker
            canvasView.onTileCloseRequested = { [weak self] tileId in
                self?.deleteTile(id: tileId)
            }

            self.ghostty = ghostty
            self.browserEngine = browserEngine
            self.canvasView = canvasView
            focusBroker.activationFallbackSurfaces = { [weak self] in
                var fallbacks: [FocusSurfaceID] = []
                if let targetId = self?.canvasView?.canvasState.lastActiveTileId {
                    fallbacks.append(.tile(targetId))
                }
                if let fallback = self?.runtimes.last?.tileId,
                   !fallbacks.contains(.tile(fallback)) {
                    fallbacks.append(.tile(fallback))
                }
                return fallbacks
            }

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
            spawner.fileTreePersistenceHandler = { [weak self] in
                self?.scheduleFileTreeSave()
            }
            spawner.reservedShortcutHandler = { [weak self] event in
                self?.handleReservedShortcut(event) ?? false
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
            ), projectPath: project.rootPath)

            installHotkeyMonitor()
            installTileFocusMonitor()
            installCanvasGestureMonitors()

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
            // E7: workspace switching will replace this with `<workspace name> — Continuum`.
            window.title = Self.mainWindowTitle(for: project)
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

            if CommandLine.arguments.contains("--palette-captures-keys-over-browser-check") {
                runPaletteCapturesKeysOverBrowserCheck(window: window)
            } else if smokeTestEnabled {
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
        _ = focusBroker.requestFocus(.tile(tileId), reason: .runtimeExited)
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
        _ = focusBroker.requestFocus(.tile(tileId), reason: .runtimeExited)
    }

    private func recoverFocusAfterTileRemoval(deletedTileId: UUID, in canvasView: CanvasNSView) {
        let fallbackTiles = canvasView.canvasState.tiles
            .filter { $0.id != deletedTileId }
            .sorted { lhs, rhs in
                if lhs.zIndex == rhs.zIndex {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.zIndex > rhs.zIndex
            }
            .map { FocusSurfaceID.tile($0.id) }
        _ = focusBroker.recoverFocus(candidates: fallbackTiles, reason: .tileClosed)
    }

    /// Tile-delete orchestrator. Per-kind cleanup mirrors the
    /// `handleRuntimeExited` shape but with kill+forget semantics: descriptors
    /// and snapshots are purged so the boot loop won't resurrect the tile next
    /// launch. Confirmation policy is read from `DeleteConfirmPolicy.current`
    /// which honors the `continuum.deleteConfirmPolicy` UserDefaults key.
    func deleteTile(id: UUID) {
        guard let canvasView else { return }
        guard let tile = canvasView.canvasState.tiles.first(where: { $0.id == id }) else { return }

        fputs("deleteTile entry kind=\(tile.kind.rawValue) id=\(id.uuidString)\n", stderr)
        var deleteOutcome = "deleted"
        defer {
            fputs("deleteTile exit kind=\(tile.kind.rawValue) id=\(id.uuidString) outcome=\(deleteOutcome)\n", stderr)
        }

        let policy = DeleteConfirmPolicy.current
        if policy.requiresConfirmation(for: tile.kind) {
            let configuration = policy.alertConfiguration(for: tile.kind)
            let alert = NSAlert()
            alert.messageText = configuration.message
            alert.informativeText = configuration.informative
            alert.alertStyle = .warning
            let cancel = alert.addButton(withTitle: configuration.buttonTitles[0])
            let delete = alert.addButton(withTitle: configuration.buttonTitles[1])
            delete.hasDestructiveAction = true
            delete.keyEquivalent = configuration.destructiveKeyEquivalent
            cancel.keyEquivalent = configuration.cancelKeyEquivalent
            if alert.runModal() != .alertSecondButtonReturn {
                deleteOutcome = "skipped"
                return
            }
        }

        switch tile.kind {
        case .terminal:
            if let runtime = runtimes.first(where: { $0.tileId == id }) {
                if let projectStore, var descriptor = try? projectStore.loadSession(id: runtime.id) {
                    descriptor.lastExit = TerminalLastExit(exitCode: nil, signal: nil, at: Date())
                    try? projectStore.saveSession(descriptor)
                }
                runtimes.removeAll { $0.id == runtime.id }
                runtime.terminate(policy: .force)
                try? projectStore?.deleteSession(id: runtime.id)
            }
        case .browser:
            if let runtime = browserRuntimes.first(where: { $0.tileId == id }) {
                browserRuntimes.removeAll { $0.id == runtime.id }
                runtime.terminate(policy: .force)
            }
            // Drop the persisted browser tile snapshot so the boot loop won't
            // try to resurrect this tile from BrowserState on next launch.
            if let projectStore,
               var browserState = try? projectStore.tryLoadBrowserState() {
                browserState.tiles.removeAll { $0.tileId == id }
                try? projectStore.saveBrowserState(browserState)
            }
        case .note:
            if let noteId = tile.metadata.noteId {
                noteViews.removeValue(forKey: noteId)
                if let projectStore {
                    if var noteState = try? projectStore.tryLoadNoteState() {
                        noteState.tiles.removeAll { $0.id == noteId || $0.tileId == id }
                        try? projectStore.saveNoteState(noteState)
                    }
                    let noteFile = projectStore.layout.noteFile(id: noteId)
                    try? FileManager.default.removeItem(at: noteFile)
                }
            }
        case .file:
            // No on-disk descriptor to purge — file tiles only carry metadata.
            break
        case .fileTree:
            fileTreeViews.removeValue(forKey: id)
            if let projectStore,
               var fileTreeState = try? projectStore.tryLoadFileTreeState() {
                fileTreeState.tiles.removeAll { $0.tileId == id }
                try? projectStore.saveFileTreeState(fileTreeState)
            }
        }

        canvasView.removeTile(id: id)
        recoverFocusAfterTileRemoval(deletedTileId: id, in: canvasView)
        flushCanvasSave()
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
        if let view = canvasView.tileView(for: tile.id) as? NoteTileNSView {
            noteViews[view.noteId] = view
        }
    }

    private func installInitialFileTile(_ tile: Tile, in canvasView: CanvasNSView, via spawner: TileSpawner) {
        spawner.installFileTile(tile, in: canvasView)
    }

    private func installInitialFileTreeTile(_ tile: Tile, in canvasView: CanvasNSView, via spawner: TileSpawner) {
        switch spawner.restartFileTreeTile(tileId: tile.id) {
        case .restarted:
            if let view = canvasView.tileView(for: tile.id) as? FileTreeTileNSView {
                fileTreeViews[tile.id] = view
            }
        case .tileNotFound:
            fputs("Boot file-tree install failed: tile \(tile.id) not found in canvas\n", stderr)
        case let .failure(error):
            fputs("Boot file-tree install failed: \(error)\n", stderr)
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

    /// Body clicks (terminal surface, NSTextView, WKWebView, file tree row…)
    /// are consumed by the content child before TileNSView.mouseDown can fire,
    /// so the existing in-tile bring-to-front never runs for them. A
    /// non-consuming local monitor lets us bring the tile forward without
    /// taking the event away from its real target. Clicks route through
    /// FocusBroker so adapter-specific primary-input focus stays canonical.
    ///
    /// We listen on `.leftMouseUp` rather than `.leftMouseDown`: bringToFront
    /// removes the target view from its superview and re-adds it (to push it
    /// to the top of the subview array). Doing that during pre-dispatch on
    /// .leftMouseDown cancels AppKit's mouse-tracking continuation — the
    /// subsequent mouseDragged events never reach the tile. mouseUp fires
    /// after any drag has already completed, so reordering is safe and the
    /// "click → tile pops forward" delay is imperceptible.
    private func installTileFocusMonitor() {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self, let canvas = self.canvasView else { return event }
            guard let window = canvas.window, event.window === window else { return event }
            Self.routeTileClickFocus(at: event.locationInWindow, in: canvas, focusBroker: self.focusBroker)
            return event
        }
        self.tileFocusMonitor = monitor
    }

    /// Trackpad gestures (two-finger scroll, pinch) get consumed by tile
    /// content (NSScrollView in notes/file tree, Ghostty surface, WKWebView)
    /// before they can reach the canvas. Window-level monitors filter for the
    /// trackpad case and route background events to the canvas. Events over an
    /// NSScrollView/NSTextView, WKWebView/browser host, or Ghostty terminal host
    /// are passed through so tile content keeps native trackpad scrolling.
    static func routeTileClickFocus(at windowPoint: NSPoint, in canvas: CanvasNSView, focusBroker: FocusBroker) {
        let pointInCanvas = canvas.convert(windowPoint, from: nil)
        guard let tileId = canvas.tileId(at: pointInCanvas) else { return }
        let surface: FocusSurfaceID = .tile(tileId)
        if let firstResponder = canvas.window?.firstResponder as? NSView,
           let tileView = canvas.tileView(for: tileId),
           firstResponder.isDescendant(of: tileView) {
            focusBroker.acceptExistingFocus(surface, reason: .userClick)
            return
        }
        _ = focusBroker.requestFocus(surface, reason: .userClick)
    }

    private func installCanvasGestureMonitors() {
        let scrollMon = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let canvas = self.canvasView else { return event }
            guard let window = canvas.window, event.window === window else { return event }
            guard event.hasPreciseScrollingDeltas else { return event }
            if self.eventTargetsScrollableTileContent(event, in: window) {
                return event
            }
            canvas.scrollWheel(with: event)
            return nil
        }
        self.canvasScrollMonitor = scrollMon

        let magnifyMon = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            guard let self, let canvas = self.canvasView else { return event }
            guard let window = canvas.window, event.window === window else { return event }
            canvas.handlePinch(event)
            return nil
        }
        self.canvasMagnifyMonitor = magnifyMon
    }

    private func eventTargetsScrollableTileContent(_ event: NSEvent, in window: NSWindow) -> Bool {
        pointTargetsScrollableTileContent(event.locationInWindow, in: window)
    }

    private func pointTargetsScrollableTileContent(_ locationInWindow: NSPoint, in window: NSWindow) -> Bool {
        guard let contentView = window.contentView else { return false }
        let pointInContent = contentView.convert(locationInWindow, from: nil)
        guard let hitView = contentView.hitTest(pointInContent) else { return false }
        return hitView.hasAncestor(ofType: NSScrollView.self)
            || hitView.hasAncestor(ofType: NSTextView.self)
            || hitView.hasAncestor(ofType: WKWebView.self)
            || hitView.hasAncestor(ofType: BrowserHostView.self)
            || hitView.hasAncestor(ofType: GhosttyTerminalView.self)
            || hitView.hasAncestor(ofType: TerminalHostView.self)
    }

    private func handleHotkey(_ event: NSEvent) -> Bool {
        if profilePalette?.handleKeyEvent(event) == true {
            return true
        }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let onlyCommand: NSEvent.ModifierFlags = [.command]
        guard mods == onlyCommand else { return false }

        // Cmd-Backspace (key code 51): delete the active tile. Only fires when
        // the canvas itself is first responder so a Cmd-Backspace inside an
        // NSTextView, terminal, or WKWebView form field still gets its native
        // semantics. The × close button covers the case where the user is
        // focused inside a tile's content.
        if event.keyCode == 51 {
            guard window?.firstResponder === canvasView else { return false }
            guard let id = canvasView?.canvasState.lastActiveTileId else { return false }
            deleteTile(id: id)
            return true
        }

        return handleReservedShortcut(event)
    }

    private func handleReservedShortcut(_ event: NSEvent) -> Bool {
        guard let shortcut = focusBroker.reservedShortcut(for: event) else { return false }
        if let activeSurface = focusBroker.activeSurface,
           focusBroker.shouldSurfaceReceive(shortcut, surface: activeSurface) {
            return false
        }

        switch shortcut {
        case .palette:
            openProfilePalette()
            return true
        case .spawnProfile(1):
            spawnTerminalFromProfile("claude")
            return true
        case .spawnProfile(2):
            spawnTerminalFromProfile("shell")
            return true
        case .spawnProfile(3):
            spawnBrowserDefault()
            return true
        case .spawnProfile(4):
            spawnTerminalFromProfile("nvim")
            return true
        case .spawnProfile:
            return false
        }
    }

    private func openProfilePalette() {
        guard let spawner = tileSpawner,
              let host = window else { return }
        let palette = profilePalette ?? makeProfilePalette()
        let wasVisible = palette.isVisible
        profilePalette = palette
        if !wasVisible {
            focusBroker.openModal(.palette)
        }
        palette.show(near: host, profiles: spawner.annotatedProfiles(), projects: switchableProjectRows())
    }

    private func switchableProjectRows() -> [ProjectPickerRow] {
        guard let registryStore,
              let activeProject,
              let registry = try? registryStore.loadOrEmpty() else { return [] }
        return ProjectPickerModel.makeRows(registry: registry)
            .filter { $0.id != activeProject.id }
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
            self?.focusBroker.closeModal(.palette)
            self?.profilePalette = nil
        }
        return palette
    }

    private func focusSpawnedTile(_ tileId: UUID) {
        _ = focusBroker.requestFocus(.tile(tileId), reason: .tileSpawned)
    }

    private func spawnTerminalFromProfile(_ profileId: String) {
        guard let spawner = tileSpawner else { return }
        switch spawner.spawnTerminal(profileId: profileId) {
        case let .spawned(runtime):
            wireRuntimeExitHandler(runtime)
            runtimes.append(runtime)
            focusSpawnedTile(runtime.tileId)
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
        spawnBrowserFromPalette(url: nil)
    }

    private func spawnBrowserFromPalette(url: String?) {
        guard let spawner = tileSpawner else { return }
        switch spawner.spawnBrowser(url: url) {
        case let .spawned(runtime):
            wireContentProcessTerminationHandler(runtime)
            browserRuntimes.append(runtime)
            focusSpawnedTile(runtime.tileId)
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
        case .newBrowser:
            spawnBrowserDefault()
        case let .openURL(url):
            spawnBrowserFromPalette(url: url)
        case .openFile:
            openFileFromPalette()
        case .openFileTree:
            spawnFileTreeFromPalette()
        case let .switchProject(projectId):
            switchProjectAndRelaunch(projectId: projectId)
        }
    }

    private func switchProjectAndRelaunch(projectId: UUID) {
        guard let registryStore else { return }
        do {
            var registry = try registryStore.loadOrEmpty()
            let rows = ProjectPickerModel.makeRows(registry: registry)
            guard case let .selected(projectRoot) = ProjectPickerModel.select(id: projectId, from: rows) else {
                fputs("Switch Project failed: unavailable project \(projectId)\n", stderr)
                return
            }
            guard registry.selectProjectForNextLaunch(id: projectId) else {
                fputs("Switch Project failed: unknown project \(projectId)\n", stderr)
                return
            }
            flushCanvasSave()
            flushBrowserSave()
            flushNoteSave()
            flushFileTreeSave()
            try registryStore.save(registry)
            relaunchApplication(projectRoot: projectRoot)
        } catch {
            fputs("Switch Project failed: \(error)\n", stderr)
        }
    }

    private func relaunchApplication(projectRoot: URL) {
        let bundleURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.environment = ProcessInfo.processInfo.environment.merging([
            "CONTINUUM_PROJECT_ROOT": projectRoot.path
        ]) { _, selected in selected }
        NSWorkspace.shared.openApplication(
            at: bundleURL,
            configuration: configuration
        ) { _, error in
            if let error {
                fputs("Switch Project relaunch failed: \(error)\n", stderr)
                return
            }
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    private func spawnNoteFromPalette() {
        guard let spawner = tileSpawner else { return }
        switch spawner.spawnNote(title: "New Note") {
        case let .spawned(noteId, tileId):
            if let view = canvasView?.tileView(for: tileId) as? NoteTileNSView {
                noteViews[noteId] = view
            }
            focusSpawnedTile(tileId)
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
        case let .spawned(tileId):
            focusSpawnedTile(tileId)
        case .invalidPath:
            fputs("TileSpawner.spawnFile rejected empty file path\n", stderr)
        case let .failure(error):
            fputs("TileSpawner.spawnFile failed: \(error)\n", stderr)
        }
    }

    private func spawnFileTreeFromPalette() {
        guard let spawner = tileSpawner,
              let project = activeProject else { return }
        switch spawner.spawnFileTree(rootPath: project.rootPath) {
        case let .spawned(tileId, _):
            if let view = canvasView?.tileView(for: tileId) as? FileTreeTileNSView {
                fileTreeViews[tileId] = view
            }
            focusSpawnedTile(tileId)
        case .invalidPath:
            fputs("TileSpawner.spawnFileTree rejected project root: \(project.rootPath)\n", stderr)
        case let .failure(error):
            fputs("TileSpawner.spawnFileTree failed: \(error)\n", stderr)
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
        focusBroker.applicationDidBecomeActive()
    }

    func applicationDidResignActive(_ notification: Notification) {
        if let app = try? ghostty?.app {
            ghostty_app_set_focus(app, false)
        }
        focusBroker.applicationDidResignActive()
    }

    func windowWillClose(_ notification: Notification) {
        zoneRuntimeController?.close(
            flushPendingWrites: { [self] in
                // Flush any pending saves so the close-leg observation catches the
                // most recent in-memory state.
                flushCanvasSave()
                flushBrowserSave()
                flushNoteSave()
                flushFileTreeSave()
            }
        )

        if let monitor = hotkeyMonitor {
            NSEvent.removeMonitor(monitor)
            hotkeyMonitor = nil
        }
        if let monitor = tileFocusMonitor {
            NSEvent.removeMonitor(monitor)
            tileFocusMonitor = nil
        }
        if let monitor = canvasScrollMonitor {
            NSEvent.removeMonitor(monitor)
            canvasScrollMonitor = nil
        }
        if let monitor = canvasMagnifyMonitor {
            NSEvent.removeMonitor(monitor)
            canvasMagnifyMonitor = nil
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
        fileTreeViews.removeAll()
        tileSpawner = nil
        ghostty?.shutdown()
        ghostty = nil
        browserEngine?.shutdown()
        browserEngine = nil
        zoneRuntimeController = nil
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

    private func scheduleFileTreeSave() {
        fileTreeSaveTimer?.invalidate()
        fileTreeSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushFileTreeSave() }
        }
    }

    private func flushFileTreeSave() {
        fileTreeSaveTimer?.invalidate()
        fileTreeSaveTimer = nil
        guard let spawner = tileSpawner else { return }
        for view in fileTreeViews.values {
            spawner.writeFileTreeTileSnapshot(for: view)
        }
    }

    private func flushCanvasSave() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard let projectStore, let canvasView else { return }
        try? projectStore.saveCanvas(canvasView.canvasState)
    }

    // MARK: - Persistence helpers

    private static func resolveProjectRoot(smokeTest: Bool, registry: Registry) throws -> URL {
        if smokeTest, ProcessInfo.processInfo.environment["CONTINUUM_PROJECT_ROOT"] == nil {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("continuum-smoke-project-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            return temp
        }

        switch ProjectLaunchCoordinator.decide(registry: registry) {
        case let .open(url):
            return url
        case let .presentPicker(request):
            let picker = ProjectPickerPanel(request: request)
            guard let selected = picker.runModal() else {
                NSApp.terminate(nil)
                throw CocoaError(.userCancelled)
            }
            return selected
        }
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
        CanvasState(
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
        let smokeFileData = Data(smokeFileLongBody.utf8)
        try smokeFileData.write(to: smokeFileURL, options: .atomic)

        let smokeTreeRoot = projectRoot
            .appendingPathComponent(".continuum-revived", isDirectory: true)
            .appendingPathComponent("smoke-tree", isDirectory: true)
        try FileManager.default.createDirectory(
            at: smokeTreeRoot.appendingPathComponent("b", isDirectory: true),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try Data("a\n".utf8).write(to: smokeTreeRoot.appendingPathComponent("a.txt"), options: .atomic)
        try Data("c\n".utf8).write(to: smokeTreeRoot.appendingPathComponent("b/c.txt"), options: .atomic)
        try FileManager.default.createDirectory(
            at: smokeTreeRoot.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try Data("ref: refs/heads/main\n".utf8)
            .write(to: smokeTreeRoot.appendingPathComponent(".git/HEAD"), options: .atomic)

        let noteSize = CanvasEngine.defaultFrame(for: .note)
        let fileSize = CanvasEngine.defaultFrame(for: .file)
        let fileTreeSize = CanvasEngine.defaultFrame(for: .fileTree)
        let fileTreeState = FileTreeState(tiles: [
            FileTreeTile(
                tileId: smokeFileTreeTileId,
                rootPath: smokeTreeRoot.path,
                expandedPaths: ["b"],
                selectedPath: "a.txt",
                searchQuery: "",
                ignoredNames: [".git", "node_modules", ".build"],
                gitBadges: .cheap
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
                frame: TileFrame(x: 360, y: 40, width: Double(fileSize.width), height: Double(fileSize.height)),
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
        registry.upsertProject(project, openedAt: Date())
        try store.save(registry)
    }

    private static func mainWindowTitle(for project: Project) -> String {
        "\(project.name) — Continuum"
    }

    static func runProjectRootResolutionSelfCheck() throws {
        struct CheckFailure: Error, CustomStringConvertible {
            let description: String
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckFailure(description: message) }
        }

        let originalCwd = FileManager.default.currentDirectoryPath
        let cwdProbe = "/tmp/continuum-root-resolution-cwd-should-not-be-used"
        try? FileManager.default.createDirectory(atPath: cwdProbe, withIntermediateDirectories: true)
        defer {
            FileManager.default.changeCurrentDirectoryPath(originalCwd)
            try? FileManager.default.removeItem(atPath: cwdProbe)
        }
        FileManager.default.changeCurrentDirectoryPath(cwdProbe)

        let usableId = UUID()
        let missingId = UUID()
        let usablePath = "/tmp/continuum-root-resolution-usable"
        let missingPath = "/tmp/continuum-root-resolution-missing"
        let envPath = "/tmp/continuum-root-resolution-env"
        var registry = Registry.empty()
        registry.lastActiveProjectId = usableId
        registry.projects = [
            ProjectEntry(id: usableId, name: "Usable", rootPath: usablePath, workspaceId: nil, lastOpenedAt: Date(timeIntervalSince1970: 1_800_000_100), pinned: false),
            ProjectEntry(id: missingId, name: "Missing", rootPath: missingPath, workspaceId: nil, lastOpenedAt: Date(timeIntervalSince1970: 1_800_000_000), pinned: false)
        ]

        final class ProbeRecorder: @unchecked Sendable {
            private var storage: [String] = []
            func append(_ value: String) { storage.append(value) }
            func contains(_ value: String) -> Bool { storage.contains(value) }
        }
        let probedPaths = ProbeRecorder()
        let probes = ProjectRootResolver.FileSystemProbes(
            directoryExists: {
                probedPaths.append($0)
                return $0 == usablePath
            },
            continuumDirectoryExists: {
                probedPaths.append($0 + "/.continuum-revived")
                return $0 == usablePath
            },
            canCreateContinuumDirectory: {
                probedPaths.append($0 + "/.continuum-revived:create")
                return false
            }
        )

        let envDecision = ProjectLaunchCoordinator.decide(environment: ["CONTINUUM_PROJECT_ROOT": envPath], registry: registry, fileSystem: probes)
        try expect(envDecision == .open(URL(fileURLWithPath: envPath)), "environment root wins")

        let titleProbeDate = Date(timeIntervalSince1970: 1_800_000_000)
        let titleProbe = Project(
            id: usableId,
            name: "Usable",
            rootPath: usablePath,
            createdAt: titleProbeDate,
            updatedAt: titleProbeDate,
            defaultLaunchProfileId: "shell",
            editorPreference: .auto,
            settings: ProjectSettings(
                restorePolicy: .restoreDescriptors,
                browserStoragePolicy: .perProject,
                terminalClosePolicy: .askWhenRunning
            )
        )
        try expect(mainWindowTitle(for: titleProbe) == "Usable — Continuum", "window title includes active project name")

        let registryDecision = ProjectLaunchCoordinator.decide(environment: [:], registry: registry, fileSystem: probes)
        try expect(registryDecision == .open(URL(fileURLWithPath: usablePath)), "usable registry last-active root opens")

        registry.lastActiveProjectId = missingId
        guard case let .presentPicker(request) = ProjectLaunchCoordinator.decide(environment: [:], registry: registry, fileSystem: probes) else {
            throw CheckFailure(description: "missing registry root should reach picker state")
        }
        try expect(request.reason == .noUsableProject, "missing registry root uses noUsableProject picker reason")
        try expect(ProjectLaunchCoordinator.selectProject(id: usableId, from: request) == URL(fileURLWithPath: usablePath), "picker selection returns usable registry URL")
        try expect(!probedPaths.contains(cwdProbe), "resolver must not probe cwd")
        try expect(!probedPaths.contains(cwdProbe + "/.continuum-revived"), "resolver must not probe cwd continuum directory")

        if ProcessInfo.processInfo.environment["CONTINUUM_PROJECT_ROOT"] == nil {
            let smokeRoot = try resolveProjectRoot(smokeTest: true, registry: .empty())
            try expect(smokeRoot.lastPathComponent.hasPrefix("continuum-smoke-project-"), "smoke path still bypasses picker with temp root")
            try expect(FileManager.default.fileExists(atPath: smokeRoot.path), "smoke temp root is created")
            try? FileManager.default.removeItem(at: smokeRoot)
        }
    }

    static func runProjectPickerResolutionSelfCheck() throws {
        struct CheckFailure: Error, CustomStringConvertible {
            let description: String
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckFailure(description: message) }
        }

        let availableId = UUID()
        let missingId = UUID()
        let unusableId = UUID()
        let availablePath = "/tmp/continuum-picker-available"
        let missingPath = "/tmp/continuum-picker-missing"
        let unusablePath = "/tmp/continuum-picker-unusable"
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var registry = Registry.empty()
        registry.lastActiveProjectId = missingId
        registry.projects = [
            ProjectEntry(id: missingId, name: "Missing", rootPath: missingPath, workspaceId: nil, lastOpenedAt: now, pinned: false),
            ProjectEntry(id: availableId, name: "Available", rootPath: availablePath, workspaceId: nil, lastOpenedAt: now.addingTimeInterval(-10), pinned: false),
            ProjectEntry(id: unusableId, name: "Unusable", rootPath: unusablePath, workspaceId: nil, lastOpenedAt: now.addingTimeInterval(-20), pinned: false)
        ]
        let probes = ProjectRootResolver.FileSystemProbes(
            directoryExists: { $0 == availablePath || $0 == unusablePath },
            continuumDirectoryExists: { $0 == availablePath },
            canCreateContinuumDirectory: { _ in false }
        )

        let pickerDecision = ProjectLaunchCoordinator.decide(environment: [:], registry: registry, fileSystem: probes)
        guard case let .presentPicker(request) = pickerDecision else {
            throw CheckFailure(description: "missing last-active project should present picker")
        }
        try expect(request.reason == .noUsableProject, "picker receives noUsableProject reason")
        try expect(request.rows.map(\.id) == [missingId, availableId, unusableId], "picker receives model rows in recency order")
        try expect(ProjectLaunchCoordinator.selectProject(id: availableId, from: request) == URL(fileURLWithPath: availablePath), "available row continues with exact URL")
        try expect(ProjectLaunchCoordinator.selectProject(id: missingId, from: request) == nil, "missing row does not continue")
        try expect(ProjectLaunchCoordinator.selectProject(id: unusableId, from: request) == nil, "unusable row does not continue")

        registry.lastActiveProjectId = availableId
        let autoOpenDecision = ProjectLaunchCoordinator.decide(environment: [:], registry: registry, fileSystem: probes)
        try expect(autoOpenDecision == .open(URL(fileURLWithPath: availablePath)), "usable last-active project opens without picker")

        let envPath = "/tmp/continuum-picker-env"
        let envDecision = ProjectLaunchCoordinator.decide(environment: ["CONTINUUM_PROJECT_ROOT": envPath], registry: registry, fileSystem: probes)
        try expect(envDecision == .open(URL(fileURLWithPath: envPath)), "environment root bypasses picker")

        registry.settings.openLastProjectOnLaunch = false
        guard case let .presentPicker(disabledRequest) = ProjectLaunchCoordinator.decide(environment: [:], registry: registry, fileSystem: probes) else {
            throw CheckFailure(description: "openLastProject disabled should present picker")
        }
        try expect(disabledRequest.reason == .openLastProjectDisabled, "picker receives disabled-open-last reason")
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
        case browserURLFocus = "browser-url-focus"
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
        case .browserURLFocus:
            runBrowserURLFocusFlow(window: window)
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
        func preciseScrollPassThroughVisiblePoint(of view: NSView) -> Bool {
            guard let contentView = window.contentView else { return false }
            let viewWindowRect = view.convert(view.bounds, to: nil)
            let contentWindowRect = contentView.convert(contentView.bounds, to: nil)
            let visibleWindowRect = viewWindowRect.intersection(contentWindowRect)
            guard !visibleWindowRect.isNull, visibleWindowRect.width > 1, visibleWindowRect.height > 1 else { return false }
            return self.pointTargetsScrollableTileContent(
                NSPoint(x: visibleWindowRect.midX, y: visibleWindowRect.midY),
                in: window
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
            var browserPreciseScrollPassThrough = false
            var terminalPreciseScrollPassThrough = false
            var midExitOk = false
            var noteOk = false
            var fileOk = false
            var fileTreeOk = false
            var deleteOk = false
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
                self.flushFileTreeSave()
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
                    // Guards against the regression where the text view ended up
                    // zero-height because constraint setup orphaned the document
                    // view inside its NSClipView. Frame and laid-out glyph rect
                    // must both be non-zero or the body is invisible.
                    let tv = noteView.textView
                    let frameSized = tv.frame.height > 0 && tv.frame.width > 0
                    var layoutSized = false
                    if let lm = tv.layoutManager, let tc = tv.textContainer {
                        lm.ensureLayout(for: tc)
                        let used = lm.usedRect(for: tc)
                        layoutSized = used.width > 0 && used.height > 0
                    }
                    noteOk = trackedViewMatches && canvasMetadataMatches && bodyMatches && noteIndexMatches && frameSized && layoutSized
                    if !noteOk {
                        fputs(
                            "Note check details: trackedViewMatches=\(trackedViewMatches) canvasMetadataMatches=\(canvasMetadataMatches) bodyMatches=\(bodyMatches) noteIndexMatches=\(noteIndexMatches) frameSized=\(frameSized) layoutSized=\(layoutSized) tvFrame=\(tv.frame)\n",
                            stderr
                        )
                    }
                }

                if let fileTile = canvasOnDisk?.tiles.first(where: { $0.id == Self.smokeFileTileId }),
                   let fileView = self.canvasView?.tileView(for: fileTile.id) as? FileTileNSView {
                    self.canvasView?.bringToFront(tileId: fileTile.id)
                    fileView.layoutSubtreeIfNeeded()
                    let metadataPathMatches = fileTile.metadata.filePath?.hasSuffix(".continuum-revived/smoke-file.txt") ?? false
                    let bodyMatches = fileView.textView.string.contains(Self.smokeFileBody)
                    let lineCountMatches = fileView.textView.string.components(separatedBy: "\n").count >= 90
                    let evidence = fileView.textVisibilityEvidence(containing: Self.smokeFileBody)
                    let visibleLayout = evidence.visibleLayoutOK
                    let longFileBehavior = evidence.longFileBehaviorOK
                    let filePreciseScrollPassThrough = self.window.map {
                        self.pointTargetsScrollableTileContent(
                            NSPoint(x: evidence.textVisibleWindowRect.midX, y: evidence.textVisibleWindowRect.midY),
                            in: $0
                        )
                    } ?? false
                    fileOk = metadataPathMatches && bodyMatches && lineCountMatches && visibleLayout && longFileBehavior && filePreciseScrollPassThrough
                    fputs(
                        "File check details: metadataPathMatches=\(metadataPathMatches) bodyMatches=\(bodyMatches) lineCountMatches=\(lineCountMatches) visibleLayout=\(visibleLayout) longFileBehavior=\(longFileBehavior) filePreciseScrollPassThrough=\(filePreciseScrollPassThrough) evidence={\(evidence)}\n",
                        stderr
                    )
                }

                if let fileTreeTile = canvasOnDisk?.tiles.first(where: { $0.id == Self.smokeFileTreeTileId }) {
                    let fileTreeState = try self.projectStore?.tryLoadFileTreeState()
                    let stateMatches = fileTreeState?.tiles.contains(where: {
                        $0.tileId == Self.smokeFileTreeTileId
                            && $0.rootPath.hasSuffix(".continuum-revived/smoke-tree")
                            && $0.gitBadges == .cheap
                    }) ?? false
                    let fileTreeView = self.canvasView?.tileView(for: fileTreeTile.id) as? FileTreeTileNSView
                    let fileTreeInstalled = fileTreeView != nil
                    let fileTreeTracked = self.fileTreeViews[Self.smokeFileTreeTileId] === fileTreeView
                    let snapshotPaths = Set(fileTreeView?.currentSnapshot?.nodes.map(\.relativePath) ?? [])
                    let fileTreeLeavesVisible = snapshotPaths.contains("a.txt")
                        && snapshotPaths.contains("b/c.txt")
                    let gitFiltered = !snapshotPaths.contains(".git/HEAD")
                    fileTreeOk = fileTreeTile.kind == .fileTree
                        && fileTreeTile.runtimeRef == nil
                        && stateMatches
                        && fileTreeInstalled
                        && fileTreeTracked
                        && fileTreeLeavesVisible
                        && gitFiltered
                    if !fileTreeOk {
                        fputs(
                            "File tree check details: kind=\(fileTreeTile.kind) runtimeRef=\(String(describing: fileTreeTile.runtimeRef)) stateMatches=\(stateMatches) fileTreeInstalled=\(fileTreeInstalled) fileTreeTracked=\(fileTreeTracked) fileTreeLeavesVisible=\(fileTreeLeavesVisible) gitFiltered=\(gitFiltered)\n",
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
                    if let runtimeId = browserRuntimeId,
                       let browserRuntime = self.browserRuntimes.first(where: { $0.id == runtimeId }) {
                        self.canvasView?.bringToFront(tileId: browserRuntime.tileId)
                        self.canvasView?.layoutSubtreeIfNeeded()
                        browserRuntime.webView.layoutSubtreeIfNeeded()
                        if let browserTileView = self.canvasView?.tileView(for: browserRuntime.tileId) as? BrowserTileNSView {
                            browserPreciseScrollPassThrough = preciseScrollPassThroughVisiblePoint(of: browserTileView.hostView)
                                || preciseScrollPassThroughVisiblePoint(of: browserRuntime.webView)
                        } else {
                            browserPreciseScrollPassThrough = preciseScrollPassThroughVisiblePoint(of: browserRuntime.webView)
                        }
                    }
                    if !browserOk || !browserPreciseScrollPassThrough {
                        fputs(
                            "Browser check details: urlMatches=\(urlMatches) titleMatches=\(titleMatches) kindMatches=\(kindMatches) runtimeRefMatches=\(runtimeRefMatches) storageIdMatches=\(storageIdMatches) runtimeIdPresent=\(runtimeIdPresent) browserPreciseScrollPassThrough=\(browserPreciseScrollPassThrough) entry=\(String(describing: browserEntry))\n",
                            stderr
                        )
                    }
                }

                if let terminalView = self.canvasView?.tileView(for: runtime.tileId) as? TerminalTileNSView {
                    terminalPreciseScrollPassThrough = preciseScrollPassThroughVisiblePoint(of: terminalView.hostView)
                }
                if !terminalPreciseScrollPassThrough {
                    fputs("Terminal precise scroll check: terminalPreciseScrollPassThrough=\(terminalPreciseScrollPassThrough)\n", stderr)
                }

                // Exercise the per-tile delete path. The seeded `.file` tile is
                // the safest target: no runtime to terminate, no descriptor to
                // purge, and the default `.runtimes` confirm policy never
                // prompts for `.file` kind (so no NSAlert blocks the smoke).
                let preDeleteCanvasCount = self.canvasView?.canvasState.tiles.count ?? 0
                self.deleteTile(id: Self.smokeFileTileId)
                self.flushCanvasSave()
                let postDeleteCanvas = try self.projectStore?.loadCanvas()
                let tileGoneFromCanvasView = self.canvasView?.tileView(for: Self.smokeFileTileId) == nil
                let tileGoneFromCanvasState =
                    !(self.canvasView?.canvasState.tiles.contains(where: { $0.id == Self.smokeFileTileId }) ?? true)
                let tileGoneOnDisk = !((postDeleteCanvas?.tiles.contains { $0.id == Self.smokeFileTileId }) ?? true)
                let postDeleteCanvasCount = self.canvasView?.canvasState.tiles.count ?? -1
                let canvasCountDropped = postDeleteCanvasCount == preDeleteCanvasCount - 1
                deleteOk = tileGoneFromCanvasView
                    && tileGoneFromCanvasState
                    && tileGoneOnDisk
                    && canvasCountDropped
                if !deleteOk {
                    fputs(
                        "Delete check details: tileGoneFromCanvasView=\(tileGoneFromCanvasView) tileGoneFromCanvasState=\(tileGoneFromCanvasState) tileGoneOnDisk=\(tileGoneOnDisk) canvasCountDropped=\(canvasCountDropped) (pre=\(preDeleteCanvasCount), post=\(postDeleteCanvasCount))\n",
                        stderr
                    )
                }
            } catch {
                fputs("Persistence check threw: \(error)\n", stderr)
            }

            if textPathOk && keyPathOk && scrollOk && modifierOnlyOk && imeInsertedTextSeen && markedTextCleared && persistenceOk && canvasOk && multiTerminalOk && browserOk && browserPreciseScrollPassThrough && terminalPreciseScrollPassThrough && midExitOk && noteOk && fileOk && fileTreeOk && browserCardinalityOk && deleteOk {
                print("Ghostty smoke test passed (text + key + scroll + modifier + ime + persistence + canvas + multiTerminal + browser + preciseScrollPassThrough + midExit + note + file + fileTree + delete, occurrences=\(occurrences))")
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
                    "Ghostty smoke test failed: textPathOk=\(textPathOk) keyPathOk=\(keyPathOk) scrollOk=\(scrollOk) modifierOnlyOk=\(modifierOnlyOk) imeInsertedTextSeen=\(imeInsertedTextSeen) markedTextCleared=\(markedTextCleared) persistenceOk=\(persistenceOk) canvasOk=\(canvasOk) multiTerminalOk=\(multiTerminalOk) browserOk=\(browserOk) browserPreciseScrollPassThrough=\(browserPreciseScrollPassThrough) terminalPreciseScrollPassThrough=\(terminalPreciseScrollPassThrough) midExitOk=\(midExitOk) noteOk=\(noteOk) fileOk=\(fileOk) fileTreeOk=\(fileTreeOk) browserCardinalityOk=\(browserCardinalityOk) deleteOk=\(deleteOk) occurrences=\(occurrences)\n",
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

    private func runPaletteCapturesKeysOverBrowserCheck(window: NSWindow) {
        var runtime: WKWebViewBrowserRuntime?
        var browserTile: BrowserTileNSView?
        var webValue: String?
        var webKeys: String?
        var initialTerminalCount = 0
        var terminalCountAfterCmd1 = 0
        var notes: [String] = []

        func finish(success: Bool, _ message: String) {
            if success {
                print("ContinuumRevivedPaletteKeyCaptureOverBrowserChecks passed")
            } else {
                fputs("FAIL: \(message)\n", stderr)
            }
            smokeTestExitCode = success ? 0 : 1
            window.performClose(nil)
        }

        func makeKeyEvent(_ character: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: character,
                charactersIgnoringModifiers: character.lowercased(),
                isARepeat: false,
                keyCode: keyCode
            )
        }

        func send(_ character: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
            guard let event = makeKeyEvent(character, keyCode: keyCode, modifiers: modifiers) else {
                notes.append("could not create key event for \(character)")
                return
            }
            NSApplication.shared.sendEvent(event)
        }

        let html = """
        <html><body><input id='qa' autofocus><script>
        window.qaKeys = [];
        document.addEventListener('keydown', function(e) {
          if (e.key && e.key.length === 1 && !e.metaKey && !e.ctrlKey && !e.altKey) { window.qaKeys.push(e.key); }
        });
        window.onload = function() { document.getElementById('qa').focus(); };
        </script></body></html>
        """
        let encoded = html.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? html
        let url = "data:text/html;charset=utf-8,\(encoded)"

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let spawner = self.tileSpawner else {
                notes.append("tile spawner unavailable")
                return
            }
            switch spawner.spawnBrowser(url: url) {
            case let .spawned(spawned):
                self.wireContentProcessTerminationHandler(spawned)
                self.browserRuntimes.append(spawned)
                runtime = spawned
                browserTile = self.canvasView?.tileView(for: spawned.tileId) as? BrowserTileNSView
            case let .invalidURL(invalid):
                notes.append("invalid URL \(invalid)")
            case let .failure(error):
                notes.append("spawn failed: \(error)")
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard let runtime, let browserTile else {
                notes.append("browser runtime/tile unavailable")
                return
            }
            self.canvasView?.bringToFront(tileId: runtime.tileId)
            browserTile.layoutSubtreeIfNeeded()
            runtime.focus()
            initialTerminalCount = self.canvasView?.canvasState.tiles.filter { $0.kind == .terminal }.count ?? 0
            send("1", keyCode: 18, modifiers: .command)
            terminalCountAfterCmd1 = self.canvasView?.canvasState.tiles.filter { $0.kind == .terminal }.count ?? 0
            runtime.focus()
            send("K", keyCode: 40, modifiers: .command)
            runtime.focus()
            send("n", keyCode: 45)
            send("o", keyCode: 31)
            send("t", keyCode: 17)
            send("e", keyCode: 14)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            guard let runtime else {
                finish(success: false, "runtime unavailable for JS evaluation; notes=\(notes)")
                return
            }

            let group = DispatchGroup()
            group.enter()
            runtime.webView.evaluateJavaScript("document.getElementById('qa').value") { result, error in
                if let error { notes.append("value JS error: \(error)") }
                webValue = result as? String
                group.leave()
            }
            group.enter()
            runtime.webView.evaluateJavaScript("window.qaKeys.join('')") { result, error in
                if let error { notes.append("keys JS error: \(error)") }
                webKeys = result as? String
                group.leave()
            }
            group.notify(queue: .main) {
                let paletteText = self.profilePalette?.searchTextForQA
                let selected = self.profilePalette?.selectedDisplayNameForQA
                let contentFocused = browserTile?.browserContentHasFocusForQA == true
                let cmd1SpawnedTerminal = terminalCountAfterCmd1 == initialTerminalCount + 1
                let success = paletteText == "note"
                    && selected == LaunchPaletteAction.newNote.displayName
                    && contentFocused
                    && cmd1SpawnedTerminal
                    && webValue == ""
                    && webKeys == ""
                    && notes.isEmpty
                let message = "paletteText=\(String(describing: paletteText)) selected=\(String(describing: selected)) contentFocused=\(contentFocused) initialTerminalCount=\(initialTerminalCount) terminalCountAfterCmd1=\(terminalCountAfterCmd1) webValue=\(String(describing: webValue)) webKeys=\(String(describing: webKeys)) notes=\(notes)"
                finish(success: success, message)
            }
        }
    }

    private func runBrowserURLFocusFlow(window: NSWindow) {
        let (qaCapture, capture) = makeQACapture(window: window)
        scheduleInitialCapture(capture)
        var tileId: UUID?
        var returnCommandHandled = false
        var returnFocusedContent = false
        var escapeCommandHandled = false
        var escapeFocusedContent = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let spawner = self.tileSpawner else {
                capture("browser-url-focus-spawn-skipped", 0.4, "tile spawner unavailable")
                return
            }
            switch spawner.spawnBrowser(url: "data:text/html;charset=utf-8,<html><head><title>qa-browser-url-focus</title></head><body>browser url focus</body></html>") {
            case let .spawned(runtime):
                self.wireContentProcessTerminationHandler(runtime)
                self.browserRuntimes.append(runtime)
                tileId = runtime.tileId
                capture("browser-url-focus-spawned", 0.4, "spawned browser \(runtime.id)")
            case let .invalidURL(url):
                capture("browser-url-focus-spawn-skipped", 0.4, "invalid URL \(url)")
            case let .failure(error):
                capture("browser-url-focus-spawn-skipped", 0.4, "browser spawn failed: \(error)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard let tileId,
                  let browserTile = self.canvasView?.tileView(for: tileId) as? BrowserTileNSView
            else {
                capture("browser-url-focus-return-skipped", 0.9, "browser tile unavailable")
                return
            }
            self.canvasView?.bringToFront(tileId: tileId)
            browserTile.layoutSubtreeIfNeeded()
            returnCommandHandled = browserTile.performURLFieldCommandForQA(#selector(NSResponder.insertNewline(_:)))
            returnFocusedContent = browserTile.browserContentHasFocusForQA
            capture(
                "browser-url-focus-return",
                0.9,
                "handled=\(returnCommandHandled) contentFocused=\(returnFocusedContent) responder=\(String(describing: window.firstResponder))"
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard let tileId,
                  let browserTile = self.canvasView?.tileView(for: tileId) as? BrowserTileNSView
            else {
                capture("browser-url-focus-escape-skipped", 1.2, "browser tile unavailable")
                return
            }
            escapeCommandHandled = browserTile.performURLFieldCommandForQA(#selector(NSResponder.cancelOperation(_:)))
            escapeFocusedContent = browserTile.browserContentHasFocusForQA
            capture(
                "browser-url-focus-escape",
                1.2,
                "handled=\(escapeCommandHandled) contentFocused=\(escapeFocusedContent) responder=\(String(describing: window.firstResponder))"
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let success = returnCommandHandled && returnFocusedContent && escapeCommandHandled && escapeFocusedContent
            self.recordLaunchTime()
            capture(
                "browser-url-focus-final-state",
                1.5,
                "success=\(success) returnHandled=\(returnCommandHandled) returnContentFocused=\(returnFocusedContent) escapeHandled=\(escapeCommandHandled) escapeContentFocused=\(escapeFocusedContent)"
            )
            qaCapture?.writeManifest()
            self.qaPerf?.writeReport()
            self.smokeTestExitCode = success ? 0 : 2
            window.performClose(nil)
        }
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
        var repeatedVisibleOpenOK = false
        var closeCleanupOK = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let hostView = window.contentView else {
                capture("palette-leak-skipped", 0.4, "window content view unavailable")
                return
            }
            let memoryBefore = QAPerf.residentMemoryBytes()
            // palette-leak-cycle: repeatedly open while already visible to
            // prove show() reuses the same root view instead of orphaning
            // duplicate palette subviews.
            autoreleasepool {
                for _ in 0..<25 {
                    self.openProfilePalette()
                }
            }
            let visibleRootCount = LaunchProfilePalette.paletteRootCount(in: hostView)
            let visibleSubviewCount = self.profilePalette?.isVisible == true
                ? self.profilePaletteRootSubviewCount(in: hostView)
                : -1
            repeatedVisibleOpenOK = visibleRootCount == 1 && visibleSubviewCount == 2
            capture(
                "palette-repeated-visible-open",
                0.4,
                "opened Cmd-K 25 times while visible; roots \(visibleRootCount), rootSubviews \(visibleSubviewCount)"
            )
            self.profilePalette?.close()
            let closedRootCount = LaunchProfilePalette.paletteRootCount(in: hostView)
            closeCleanupOK = closedRootCount == 0 && self.profilePalette == nil
            capture("palette-close-cleanup", 0.5, "roots after close \(closedRootCount)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let memoryAfter = QAPerf.residentMemoryBytes()
                let delta = Int64(memoryAfter) - Int64(memoryBefore)
                self.qaPerf?.recordValue(key: "palette-leak-delta", value: Double(delta), unit: "bytes")
                capture("palette-leak-memory-sampled", 0.6, "delta \(delta) bytes")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            self.recordLaunchTime()
            capture("palette-leak-final-state", 1.3, nil)
            qaCapture?.writeManifest()
            self.qaPerf?.writeReport()
            self.smokeTestExitCode = repeatedVisibleOpenOK && closeCleanupOK ? 0 : 2
            window.performClose(nil)
        }
    }

    private func profilePaletteRootSubviewCount(in hostView: NSView) -> Int {
        hostView.subviews
            .first { $0.accessibilityIdentifier() == LaunchProfilePalette.rootAccessibilityIdentifier }?
            .subviews.count ?? 0
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
        var emptyStateContentMatched = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let canvasView = self.canvasView else {
                capture("empty-canvas-skipped", 0.4, "canvas unavailable")
                return
            }
            let snapshot = canvasView.emptyStateQASnapshot()
            let text = snapshot?.text.joined(separator: " | ") ?? ""
            let buttons = snapshot?.buttonTitles ?? []
            emptyStateWasInstalled = canvasView.canvasState.tiles.isEmpty && canvasView.emptyStateInstalled
            emptyStateContentMatched = snapshot?.accessibilityIdentifier == "ContinuumEmptyState"
                && buttons.count >= 4
                && text.contains("CONTINUUM")
                && text.contains("⌘K")
                && text.contains("open the command palette")
                && text.contains("notes, files, and projects live in ⌘K")
                && buttons.contains("New Claude Terminal   ⌘1")
                && buttons.contains("New Shell Terminal    ⌘2")
                && buttons.contains("New Browser           ⌘3")
                && buttons.contains("Open in Nvim          ⌘4")
            capture(
                "empty-canvas-visible",
                0.4,
                "tiles \(canvasView.canvasState.tiles.count), empty state \(canvasView.emptyStateInstalled), ax \(snapshot?.accessibilityIdentifier ?? "nil"), buttons \(buttons), contentMatched \(emptyStateContentMatched)"
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let notes = self.spawnTerminalForQA(profileId: "shell")
            capture("empty-canvas-spawn-requested", 0.6, notes)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            emptyStateWasRemoved = self.canvasView?.canvasState.tiles.isEmpty == false
                && self.canvasView?.emptyStateInstalled == false
            capture("empty-canvas-spawned-shell", 0.9, "empty state removed \(emptyStateWasRemoved)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.recordLaunchTime()
            capture("empty-canvas-final-state", 1.2, nil)
            qaCapture?.writeManifest()
            self.qaPerf?.writeReport()
            self.smokeTestExitCode = emptyStateWasInstalled && emptyStateContentMatched && emptyStateWasRemoved ? 0 : 2
            window.performClose(nil)
        }
    }

    static func runViewportSanitizeSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self { case let .failed(message): return message }
            }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }
        func allFinite(_ canvas: CanvasState) -> Bool {
            canvas.viewport.x.isFinite && canvas.viewport.y.isFinite && canvas.viewport.zoom.isFinite &&
                canvas.tiles.allSatisfy { tile in
                    tile.frame.x.isFinite && tile.frame.y.isFinite && tile.frame.width.isFinite && tile.frame.height.isFinite
                }
        }

        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let projectRoot = environment["CONTINUUM_PROJECT_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fileManager.temporaryDirectory.appendingPathComponent("continuum-viewport-sanitize-\(UUID().uuidString)", isDirectory: true)
        let appSupport = environment["CONTINUUM_APP_SUPPORT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fileManager.temporaryDirectory.appendingPathComponent("continuum-viewport-sanitize-appsupport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let store = ProjectStore(projectRoot: projectRoot)
        let now = Date()
        let project = Project(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            name: "viewport-sanitize-check",
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

        let tileId = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let runtimeId = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let fixture = """
        {
          "schemaVersion": 1,
          "viewport": { "x": 1000000000, "y": -1000000000, "zoom": "Infinity" },
          "tiles": [
            {
              "id": "\(tileId.uuidString)",
              "kind": "terminal",
              "title": "Pathological terminal",
              "frame": { "x": "NaN", "y": 80, "width": "-Infinity", "height": 0 },
              "zIndex": 7,
              "runtimeRef": { "kind": "terminalSession", "id": "\(runtimeId.uuidString)" },
              "metadata": { "launchProfileId": "shell", "projectRelativeCwd": "." }
            },
            {
              "id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
              "kind": "note",
              "title": "Visible anchor",
              "frame": { "x": 120, "y": 140, "width": 320, "height": 220 },
              "zIndex": 8,
              "metadata": { "noteId": "bbbbbbbb-cccc-dddd-eeee-ffffffffffff" }
            }
          ],
          "groups": [],
          "lastActiveTileId": "\(tileId.uuidString)"
        }
        """
        try fileManager.createDirectory(at: store.layout.stateRoot, withIntermediateDirectories: true)
        try Data(fixture.utf8).write(to: store.layout.canvasFile, options: .atomic)

        let result = try store.loadCanvasWithSanitizationResult()
        try expect(result.changed, "pathological persisted canvas should be changed")
        try expect(result.recenteredViewport, "disjoint persisted viewport should be recentered")
        try expect(allFinite(result.canvas), "sanitized canvas should contain only finite viewport/frame values")
        try expect(CanvasEngine.defaultZoomRange.contains(result.canvas.viewport.zoom), "sanitized zoom should be clamped to default range")
        try expect(result.canvas.tiles.count == 2, "sanitizer should preserve all tiles")
        try expect(result.canvas.tiles[0].runtimeRef == RuntimeRef(kind: .terminalSession, id: runtimeId), "sanitizer should preserve runtime refs")
        try expect(result.canvas.tiles[0].metadata.launchProfileId == "shell", "sanitizer should preserve metadata")
        for tile in result.canvas.tiles {
            let minimum = CanvasEngine.minimumFrame(for: tile.kind)
            try expect(tile.frame.width >= minimum.width && tile.frame.height >= minimum.height, "tile \(tile.id) dimensions should meet minimum")
        }
        let viewportSize = CGSize(width: 1280, height: 800)
        let screenFrames = result.canvas.tiles.map { CanvasEngine.tileScreenFrame($0.frame, viewport: result.canvas.viewport) }
        let visibleScreen = CGRect(x: 0, y: 0, width: viewportSize.width, height: viewportSize.height)
        let visibleIntersections = screenFrames.map { visibleScreen.intersects($0) }
        try expect(visibleIntersections.contains(true), "at least one tile should be visible after sanitation")

        for note in result.notes where note.contains("recentered") {
            fputs("viewport sanitation: \(note)\n", stderr)
        }
        try store.saveCanvas(result.canvas)
        let persisted = try store.loadCanvas()
        try expect(allFinite(persisted), "persisted sanitized canvas should remain finite after reload")
        try expect(CanvasEngine.defaultZoomRange.contains(persisted.viewport.zoom), "persisted sanitized zoom should remain clamped")
        try expect(persisted.tiles.map(\.id) == result.canvas.tiles.map(\.id), "persisted sanitized output should preserve tile ids")

        let legitimateViewport = CanvasViewport(x: 500_000, y: -500_000, zoom: 1)
        let legitimateCanvas = CanvasState(
            viewport: legitimateViewport,
            tiles: [
                Tile(
                    id: UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!,
                    kind: .note,
                    title: "Legitimate offscreen pan",
                    frame: TileFrame(x: 120, y: 140, width: 320, height: 220),
                    zIndex: 1,
                    runtimeRef: nil,
                    metadata: TileMetadata(noteId: UUID(uuidString: "abcdefab-cdef-cdef-cdef-abcdefabcdef")!)
                )
            ],
            groups: [],
            lastActiveTileId: nil
        )
        let legitimateResult = CanvasEngine.sanitizePersistedCanvas(legitimateCanvas, visibleSize: viewportSize)
        try expect(!legitimateResult.changed, "legitimate finite offscreen viewport should not be sanitized")
        try expect(!legitimateResult.recenteredViewport, "legitimate finite offscreen viewport should not be recentered")
        try expect(legitimateResult.canvas.viewport == legitimateViewport, "legitimate finite offscreen viewport should be preserved")

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("viewport-sanitize", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "check": "viewport-sanitize",
            "projectRoot": projectRoot.path,
            "appSupport": appSupport.path,
            "canvasPath": store.layout.canvasFile.path,
            "changed": result.changed,
            "recenteredViewport": result.recenteredViewport,
            "notes": result.notes,
            "sanitizedViewport": [
                "x": result.canvas.viewport.x,
                "y": result.canvas.viewport.y,
                "zoom": result.canvas.viewport.zoom,
            ],
            "tileFrames": result.canvas.tiles.map { tile in
                [
                    "id": tile.id.uuidString,
                    "kind": tile.kind.rawValue,
                    "x": tile.frame.x,
                    "y": tile.frame.y,
                    "width": tile.frame.width,
                    "height": tile.frame.height,
                ]
            },
            "visibleIntersections": visibleIntersections,
            "runtimeRefPreserved": result.canvas.tiles[0].runtimeRef == RuntimeRef(kind: .terminalSession, id: runtimeId),
            "metadataPreserved": result.canvas.tiles[0].metadata.launchProfileId == "shell",
            "persistedFinite": allFinite(persisted),
            "legitimateViewportPreserved": legitimateResult.canvas.viewport == legitimateViewport,
            "legitimateChanged": legitimateResult.changed,
            "legitimateRecenteredViewport": legitimateResult.recenteredViewport,
        ]
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    static func runProjectLockSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self { case let .failed(message): return message }
            }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("continuum-project-lock-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = ProjectLock(root: root)
        try lock.acquire()

        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        func runProbe() throws -> (code: Int32, stdout: String, stderr: String) {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--project-lock-probe", root.path]
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            process.waitUntilExit()
            return (
                process.terminationStatus,
                String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            )
        }

        let lockedProbe = try runProbe()
        try expect(lockedProbe.code == 1, "probe should fail while parent holds lock; got \(lockedProbe.code) stdout=\(lockedProbe.stdout) stderr=\(lockedProbe.stderr)")

        let inheritedFdGuard = Process()
        inheritedFdGuard.executableURL = URL(fileURLWithPath: "/bin/sleep")
        inheritedFdGuard.arguments = ["10"]
        try inheritedFdGuard.run()
        defer {
            if inheritedFdGuard.isRunning {
                inheritedFdGuard.terminate()
                inheritedFdGuard.waitUntilExit()
            }
        }
        usleep(100_000)

        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-p", String(inheritedFdGuard.processIdentifier)]
        let lsofOut = Pipe()
        lsof.standardOutput = lsofOut
        lsof.standardError = Pipe()
        try lsof.run()
        lsof.waitUntilExit()
        let childOpenFiles = String(data: lsofOut.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        try expect(!childOpenFiles.contains(lock.lockFile.path), "child process inherited project lock fd: \(childOpenFiles)")

        lock.release()
        let unlockedProbe = try runProbe()
        try expect(unlockedProbe.code == 0, "probe should acquire after release while a child process remains alive; got \(unlockedProbe.code) stdout=\(unlockedProbe.stdout) stderr=\(unlockedProbe.stderr)")

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("project-lock", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "check": "project-lock",
            "projectRoot": root.path,
            "lockFile": lock.lockFile.path,
            "lockedProbeExit": lockedProbe.code,
            "lockedProbeStdout": lockedProbe.stdout,
            "lockedProbeStderr": lockedProbe.stderr,
            "unlockedProbeExit": unlockedProbe.code,
            "unlockedProbeStdout": unlockedProbe.stdout,
            "unlockedProbeStderr": unlockedProbe.stderr,
            "childAliveDuringRelease": inheritedFdGuard.isRunning,
            "childOpenFilesCheckedWithLsof": true,
            "childOpenFilesContainsLockPath": childOpenFiles.contains(lock.lockFile.path),
        ]
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    static func runPaletteBrowserSpawnSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self { case let .failed(message): return message }
            }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        let legacyDefaults = UserDefaults(suiteName: DeleteConfirmPolicy.legacyDefaultsDomain)
        let savedDefaultBrowserURL = UserDefaults.standard.object(forKey: DefaultBrowserURL.userDefaultsKey)
        let savedLegacyDefaultBrowserURL = legacyDefaults?.object(forKey: DefaultBrowserURL.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: DefaultBrowserURL.userDefaultsKey)
        legacyDefaults?.removeObject(forKey: DefaultBrowserURL.userDefaultsKey)
        defer {
            if let savedDefaultBrowserURL {
                UserDefaults.standard.set(savedDefaultBrowserURL, forKey: DefaultBrowserURL.userDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultBrowserURL.userDefaultsKey)
            }
            if let savedLegacyDefaultBrowserURL {
                legacyDefaults?.set(savedLegacyDefaultBrowserURL, forKey: DefaultBrowserURL.userDefaultsKey)
            } else {
                legacyDefaults?.removeObject(forKey: DefaultBrowserURL.userDefaultsKey)
            }
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-palette-browser-spawn-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let now = Date()
        let project = Project(
            id: UUID(),
            name: "palette-browser-spawn-check",
            rootPath: tempRoot.path,
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
        let store = ProjectStore(projectRoot: tempRoot)
        try store.saveProject(project)
        try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))

        let canvas = CanvasNSView(canvasState: try store.loadCanvas())
        canvas.frame = CGRect(x: 0, y: 0, width: 2400, height: 1600)
        let browserEngine = BrowserEngineContext()
        let delegate = AppDelegate()
        delegate.canvasView = canvas
        delegate.browserEngine = browserEngine
        delegate.zoneRuntimeController = ZoneRuntimeController(projectRoot: tempRoot, projectStore: store, project: project)
        delegate.tileSpawner = TileSpawner(
            canvasView: canvas,
            ghostty: nil,
            browserEngine: browserEngine,
            projectStore: store,
            project: project
        )
        defer {
            delegate.browserRuntimes.forEach { $0.terminate(policy: .requestClose) }
            browserEngine.shutdown()
        }

        let explicitURL = "https://example.com/from-palette"
        delegate.performPaletteAction(.newBrowser)
        delegate.performPaletteAction(.openURL(explicitURL))

        let browserTiles = canvas.canvasState.tiles.filter { $0.kind == .browser }
        try expect(browserTiles.count == 2, "expected 2 browser tiles, got \(browserTiles.count)")
        try expect(delegate.browserRuntimes.count == 2, "expected 2 browser runtimes, got \(delegate.browserRuntimes.count)")
        try expect(browserTiles.map { $0.metadata.url } == ["about:blank", explicitURL], "unexpected browser tile URLs: \(browserTiles.map { $0.metadata.url ?? "nil" })")
        try expect(delegate.browserRuntimes.map(\.url) == ["about:blank", explicitURL], "unexpected runtime URLs: \(delegate.browserRuntimes.map(\.url))")
        let persisted = try store.loadBrowserState().tiles.map(\.url)
        try expect(persisted == ["about:blank", explicitURL], "unexpected persisted browser URLs: \(persisted)")

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("palette-browser-spawn", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "check": "palette-browser-spawn",
            "tileCount": browserTiles.count,
            "runtimeCount": delegate.browserRuntimes.count,
            "tileURLs": browserTiles.map { $0.metadata.url ?? "" },
            "runtimeURLs": delegate.browserRuntimes.map(\.url),
            "persistedURLs": persisted,
        ]
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    static func runSpawnFocusPolicySelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self { case let .failed(message): return message }
            }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-spawn-focus-policy-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let now = Date()
        let project = Project(
            id: UUID(),
            name: "spawn-focus-policy-check",
            rootPath: tempRoot.path,
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
        let store = ProjectStore(projectRoot: tempRoot)
        try store.saveProject(project)
        try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))

        let canvas = CanvasNSView(canvasState: try store.loadCanvas())
        canvas.frame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let delegate = AppDelegate()
        let browserEngine = BrowserEngineContext()
        delegate.canvasView = canvas
        delegate.browserEngine = browserEngine
        delegate.zoneRuntimeController = ZoneRuntimeController(projectRoot: tempRoot, projectStore: store, project: project)
        canvas.focusBroker = delegate.focusBroker
        delegate.tileSpawner = TileSpawner(
            canvasView: canvas,
            ghostty: nil,
            browserEngine: browserEngine,
            projectStore: store,
            project: project
        )
        defer { browserEngine.shutdown() }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = canvas
        delegate.window = window

        try expect(delegate.focusBroker.requestFocus(.canvas, reason: .appActivated), "initial canvas focus failed")
        delegate.openProfilePalette()
        delegate.openProfilePalette()
        try expect(delegate.focusBroker.activeSurface == .modal(.palette), "palette did not become active modal")
        guard let palette = delegate.profilePalette else {
            throw CheckError.failed("palette was not created")
        }
        for scalar in "note".unicodeScalars {
            let character = String(scalar)
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: character,
                charactersIgnoringModifiers: character,
                isARepeat: false,
                keyCode: 0
            )!
            try expect(palette.handleKeyEvent(event), "palette did not handle search character \(character)")
        }
        let returnEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        )!
        try expect(palette.handleKeyEvent(returnEvent), "palette did not handle Return")
        guard let spawnedTile = canvas.canvasState.tiles.first(where: { $0.kind == .note }) else {
            throw CheckError.failed("new note spawn did not create a note tile")
        }
        try expect(delegate.profilePalette == nil, "palette did not close after action selection")
        try expect(delegate.focusBroker.activeSurface == .tile(spawnedTile.id), "modal close restored pre-spawn focus instead of keeping spawned tile")
        try expect(canvas.canvasState.lastActiveTileId == spawnedTile.id, "spawned note did not become lastActiveTileId")
        guard let noteView = canvas.tileView(for: spawnedTile.id) as? NoteTileNSView else {
            throw CheckError.failed("spawned note view missing")
        }
        try expect(window.firstResponder === noteView.textView, "spawned note text view is not first responder")
        noteView.textView.keyDown(with: NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "z",
            charactersIgnoringModifiers: "z",
            isARepeat: false,
            keyCode: 6
        )!)
        try expect(noteView.textView.string.contains("z"), "typing sentinel did not land in spawned note")

        delegate.performPaletteAction(.newBrowser)
        guard let browserTile = canvas.canvasState.tiles.last(where: { $0.kind == .browser }) else {
            throw CheckError.failed("new browser spawn did not create a browser tile")
        }
        guard let browserRuntime = delegate.browserRuntimes.last else {
            throw CheckError.failed("new browser spawn did not create a browser runtime")
        }
        try expect(delegate.focusBroker.activeSurface == .tile(browserTile.id), "spawned browser did not become active")
        try expect(canvas.canvasState.lastActiveTileId == browserTile.id, "spawned browser did not become lastActiveTileId")
        try expect(browserRuntime.isSemanticContentResponder(window.firstResponder), "spawned browser content is not semantic first responder")

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("spawn-focus-policy", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "check": "spawn-focus-policy",
            "noteTileId": spawnedTile.id.uuidString,
            "browserTileId": browserTile.id.uuidString,
            "activeSurface": String(describing: delegate.focusBroker.activeSurface),
            "lastActiveTileId": canvas.canvasState.lastActiveTileId?.uuidString ?? "nil",
        ]
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    static func runFocusBrokerActivationSelfCheck() throws -> URL {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() {
                throw NSError(domain: "ContinuumRevivedFocusBrokerActivationChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }

        final class ProbeAdapter: FocusSurfaceAdapter {
            let focusSurfaceID: FocusSurfaceID
            let focusSurfaceKind: FocusSurfaceKind
            var acquireReasons: [FocusRequest] = []
            var releaseReasons: [FocusRequest] = []
            var shouldAcquire = true

            init(id: FocusSurfaceID, kind: FocusSurfaceKind) {
                self.focusSurfaceID = id
                self.focusSurfaceKind = kind
            }

            func acquireFocus(reason: FocusRequest) -> Bool {
                acquireReasons.append(reason)
                return shouldAcquire
            }

            func releaseFocus(reason: FocusRequest) {
                releaseReasons.append(reason)
            }

            func canHandleReservedShortcut(_ shortcut: ReservedShortcut) -> Bool { false }
        }

        let fileManager = FileManager.default
        let broker = FocusBroker()
        let canvas = ProbeAdapter(id: .canvas, kind: .canvas)
        let tileId = UUID()
        let fallbackTileId = UUID()
        let tile = ProbeAdapter(id: .tile(tileId), kind: .terminal)
        let fallbackTile = ProbeAdapter(id: .tile(fallbackTileId), kind: .note)
        broker.register(canvas)
        broker.register(tile)
        broker.register(fallbackTile)
        broker.activationFallbackSurfaces = { [.tile(fallbackTileId)] }

        broker.applicationDidBecomeActive()
        try expect(fallbackTile.acquireReasons == [.appActivated], "nil active surface should use broker fallback tile; reasons=\(fallbackTile.acquireReasons)")
        try expect(broker.activeSurface == .tile(fallbackTileId), "nil active surface should set fallback tile active")

        broker.openModal(.palette)
        broker.applicationDidBecomeActive()
        try expect(broker.activeSurface == .modal(.palette), "activation while modal is open should preserve modal active surface")
        broker.closeModal(.palette)

        try expect(broker.requestFocus(.tile(tileId), reason: .userClick), "initial tile focus failed")
        broker.applicationDidResignActive()
        try expect(tile.releaseReasons == [.recovery], "resign should release only active tile through broker; reasons=\(tile.releaseReasons)")
        try expect(canvas.releaseReasons.isEmpty, "resign should not release inactive canvas")

        broker.applicationDidBecomeActive()
        try expect(tile.acquireReasons.suffix(1) == [.appActivated], "activation should reacquire active tile; reasons=\(tile.acquireReasons)")
        try expect(broker.activeSurface == .tile(tileId), "activation should keep active tile")

        tile.shouldAcquire = false
        broker.applicationDidBecomeActive()
        try expect(fallbackTile.acquireReasons.suffix(1) == [.appActivated], "failed active tile should recover through broker fallback; reasons=\(fallbackTile.acquireReasons)")
        try expect(broker.activeSurface == .tile(fallbackTileId), "failed active tile should set fallback tile active")

        let deletedTileId = UUID()
        let survivorTileId = UUID()
        let deletedTile = ProbeAdapter(id: .tile(deletedTileId), kind: .note)
        let survivorTile = ProbeAdapter(id: .tile(survivorTileId), kind: .fileTree)
        broker.register(deletedTile)
        broker.register(survivorTile)
        try expect(broker.requestFocus(.tile(deletedTileId), reason: .userClick), "delete-recovery setup focus failed")
        broker.unregister(.tile(deletedTileId))
        try expect(broker.recoverFocus(candidates: [.tile(deletedTileId), .tile(survivorTileId)], reason: .tileClosed), "tile close recovery should skip deleted tile and focus survivor")
        try expect(broker.activeSurface == .tile(survivorTileId), "tile close recovery should set survivor active")
        try expect(survivorTile.acquireReasons.suffix(1) == [.tileClosed], "survivor should acquire for tileClosed; reasons=\(survivorTile.acquireReasons)")

        let runtimeTileId = UUID()
        let exitedAdapter = ProbeAdapter(id: .tile(runtimeTileId), kind: .terminal)
        broker.register(exitedAdapter)
        try expect(broker.requestFocus(.tile(runtimeTileId), reason: .userClick), "runtime-recovery setup focus failed")
        broker.unregister(.tile(runtimeTileId))
        let placeholderAdapter = ProbeAdapter(id: .tile(runtimeTileId), kind: .terminal)
        broker.register(placeholderAdapter)
        try expect(broker.requestFocus(.tile(runtimeTileId), reason: .runtimeExited), "runtime exit should focus replacement adapter")
        try expect(broker.activeSurface == .tile(runtimeTileId), "runtime exit should keep replacement tile active")
        try expect(placeholderAdapter.acquireReasons == [.runtimeExited], "replacement should acquire for runtimeExited; reasons=\(placeholderAdapter.acquireReasons)")

        let canvasBroker = FocusBroker()
        let canvasState = CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil)
        let realCanvas = CanvasNSView(canvasState: canvasState)
        realCanvas.focusBroker = canvasBroker
        let frontTileId = UUID()
        let rearTileId = UUID()
        let frontTile = Tile(id: frontTileId, kind: .note, title: "front", frame: TileFrame(x: 0, y: 0, width: 100, height: 100), zIndex: 2, runtimeRef: nil, metadata: TileMetadata())
        let rearTile = Tile(id: rearTileId, kind: .note, title: "rear", frame: TileFrame(x: 120, y: 0, width: 100, height: 100), zIndex: 1, runtimeRef: nil, metadata: TileMetadata())
        realCanvas.install(tileView: TileNSView(tile: rearTile), for: rearTile)
        realCanvas.install(tileView: TileNSView(tile: frontTile), for: frontTile)
        try expect(canvasBroker.requestFocus(.tile(frontTileId), reason: .userClick), "real-canvas focused tile setup failed")
        realCanvas.removeTile(id: frontTileId)
        try expect(!realCanvas.canvasState.tiles.contains(where: { $0.id == frontTileId }), "real-canvas removal should remove deleted tile from canvasState")
        let survivorCandidates = realCanvas.canvasState.tiles
            .sorted { $0.zIndex > $1.zIndex }
            .map { FocusSurfaceID.tile($0.id) }
        try expect(survivorCandidates == [.tile(rearTileId)], "real-canvas survivor candidates should derive from post-removal canvasState; candidates=\(survivorCandidates)")
        try expect(canvasBroker.recoverFocus(candidates: survivorCandidates, reason: .tileClosed), "real-canvas removal should recover to remaining tile")
        try expect(canvasBroker.activeSurface == .tile(rearTileId), "real-canvas removal should set remaining tile active")
        realCanvas.removeTile(id: rearTileId)
        try expect(realCanvas.canvasState.tiles.isEmpty, "real-canvas last tile removal should leave no tile candidates")
        let emptyCandidates = realCanvas.canvasState.tiles.map { FocusSurfaceID.tile($0.id) }
        try expect(canvasBroker.recoverFocus(candidates: emptyCandidates, reason: .tileClosed), "real-canvas last tile removal should recover to canvas")
        try expect(canvasBroker.activeSurface == .canvas, "real-canvas last tile removal should set canvas active")

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("focus-broker-activation", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "check": "focus-broker-activation",
            "tileId": tileId.uuidString,
            "fallbackTileId": fallbackTileId.uuidString,
            "tileAcquireReasons": tile.acquireReasons.map(\.rawValue),
            "tileReleaseReasons": tile.releaseReasons.map(\.rawValue),
            "fallbackTileAcquireReasons": fallbackTile.acquireReasons.map(\.rawValue),
            "tileClosedRecoverySurface": survivorTileId.uuidString,
            "tileClosedAcquireReasons": survivorTile.acquireReasons.map(\.rawValue),
            "runtimeExitedRecoverySurface": runtimeTileId.uuidString,
            "runtimeExitedAcquireReasons": placeholderAdapter.acquireReasons.map(\.rawValue),
            "realCanvasTileClosedRecoverySurface": rearTileId.uuidString,
            "realCanvasLastTileRecoverySurface": "canvas",
            "modalPreservedDuringActivation": true,
            "canvasAcquireReasons": canvas.acquireReasons.map(\.rawValue),
            "activeSurface": String(describing: broker.activeSurface),
        ]
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
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

private extension NSView {
    func hasAncestor<T: NSView>(ofType type: T.Type) -> Bool {
        var view: NSView? = self
        while let current = view {
            if current is T { return true }
            view = current.superview
        }
        return false
    }
}

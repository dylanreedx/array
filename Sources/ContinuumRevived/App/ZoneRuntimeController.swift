import AppKit
import ContinuumRevivedCore
import Foundation

@MainActor
final class ZoneRuntimeController {
    let projectRoot: URL
    let projectStore: ProjectStore
    private(set) var project: Project

    var runtimes: [GhosttyTerminalRuntime] = []
    var browserRuntimes: [WKWebViewBrowserRuntime] = []
    var noteViews: [UUID: NoteTileNSView] = [:]
    var fileTreeViews: [UUID: FileTreeTileNSView] = [:]

    weak var canvasView: CanvasNSView?
    weak var tileSpawner: TileSpawner?
    var onBrowserRuntimeHydrated: ((WKWebViewBrowserRuntime) -> Void)?
    private weak var focusBroker: FocusBroker?

    private var saveTimer: Timer?
    private var browserSaveTimer: Timer?
    private var noteSaveTimer: Timer?
    private var fileTreeSaveTimer: Timer?

    private let projectLock: ProjectLock?
    private var isClosed = false
    private(set) var hydrationTier: HydrationTier = .live

    enum HydrationLifecycleError: Error, CustomStringConvertible {
        case controllerClosed
        case uiUnavailable
        case focusedZoneMustRemainLive(UUID)
        case browserRehydrateFailed(UUID, TileSpawner.BrowserRestartOutcome)

        var description: String {
            switch self {
            case .controllerClosed:
                return "controller is closed"
            case .uiUnavailable:
                return "controller UI is unavailable"
            case let .focusedZoneMustRemainLive(tileId):
                return "cannot dehydrate focused zone while tile \(tileId) is active"
            case let .browserRehydrateFailed(tileId, outcome):
                return "failed to rehydrate browser tile \(tileId): \(outcome)"
            }
        }
    }

    init(root projectRoot: URL) throws {
        self.projectRoot = projectRoot
        let projectLock = ProjectLock(root: projectRoot)
        try projectLock.acquire()
        self.projectLock = projectLock

        let projectStore = ProjectStore(projectRoot: projectRoot)
        self.projectStore = projectStore

        pruneExitedSessions(in: projectStore)
        self.project = try Self.loadOrCreateProject(in: projectStore, projectRoot: projectRoot)
    }

    init(projectRoot: URL, projectStore: ProjectStore, project: Project) {
        self.projectRoot = projectRoot
        self.projectStore = projectStore
        self.project = project
        self.projectLock = nil
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true

        flushPendingSaves()
        detachUI()

        let now = Date()
        for runtime in runtimes {
            if var descriptor = try? projectStore.loadSession(id: runtime.id) {
                descriptor.lastExit = TerminalLastExit(exitCode: nil, signal: nil, at: now)
                try? projectStore.saveSession(descriptor)
            }
        }

        projectLock?.release()
    }

    func attachUI(canvasView: CanvasNSView, tileSpawner: TileSpawner, focusBroker: FocusBroker) {
        self.canvasView = canvasView
        self.tileSpawner = tileSpawner
        self.focusBroker = focusBroker
        canvasView.focusBroker = focusBroker
        focusBroker.activationFallbackSurfaces = { [weak self] in
            guard let self else { return [] }
            var fallbacks: [FocusSurfaceID] = []
            if let targetId = self.canvasView?.canvasState.lastActiveTileId {
                fallbacks.append(.tile(targetId))
            }
            if let fallback = self.runtimes.last?.tileId,
               !fallbacks.contains(.tile(fallback)) {
                fallbacks.append(.tile(fallback))
            }
            return fallbacks
        }
    }

    func detachUI() {
        canvasView?.detachFocusBroker()
        focusBroker?.activationFallbackSurfaces = nil
        focusBroker = nil
        canvasView = nil
        tileSpawner = nil
    }

    func setTier(
        _ targetTier: HydrationTier,
        allowDehydratingFocusedZone: Bool = false,
        snapshotImageProvider: (WKWebViewBrowserRuntime) -> NSImage = { _ in ZoneRuntimeController.placeholderSnapshotImage() }
    ) throws {
        guard !isClosed else { throw HydrationLifecycleError.controllerClosed }
        guard targetTier != hydrationTier else { return }

        switch targetTier {
        case .live:
            try hydrateToLive()
        case .snapshot, .cold:
            try dehydrate(to: targetTier, allowDehydratingFocusedZone: allowDehydratingFocusedZone, snapshotImageProvider: snapshotImageProvider)
        }
        hydrationTier = targetTier
    }

    private func dehydrate(
        to targetTier: HydrationTier,
        allowDehydratingFocusedZone: Bool,
        snapshotImageProvider: (WKWebViewBrowserRuntime) -> NSImage
    ) throws {
        guard targetTier == .snapshot || targetTier == .cold else { return }
        guard let canvasView, let tileSpawner else { throw HydrationLifecycleError.uiUnavailable }
        if !allowDehydratingFocusedZone, let focusedTileId = canvasView.canvasState.lastActiveTileId {
            throw HydrationLifecycleError.focusedZoneMustRemainLive(focusedTileId)
        }

        flushPendingSaves()
        let liveBrowsers = browserRuntimes
        for runtime in liveBrowsers {
            try tileSpawner.installBrowserSnapshotTile(runtime: runtime, snapshotImage: snapshotImageProvider(runtime))
        }
        browserRuntimes.removeAll { runtime in
            liveBrowsers.contains { $0.id == runtime.id }
        }
    }

    private func hydrateToLive() throws {
        guard let canvasView, let tileSpawner else { throw HydrationLifecycleError.uiUnavailable }
        let browserTileIds = canvasView.canvasState.tiles
            .filter { $0.kind == .browser && $0.runtimeRef == nil }
            .map(\.id)

        for tileId in browserTileIds {
            switch tileSpawner.restartBrowserTile(tileId: tileId) {
            case let .restarted(runtime):
                onBrowserRuntimeHydrated?(runtime)
                browserRuntimes.append(runtime)
            case let outcome:
                throw HydrationLifecycleError.browserRehydrateFailed(tileId, outcome)
            }
        }
    }

    private static func placeholderSnapshotImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 80, height: 60))
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: 80, height: 60).fill()
        image.unlockFocus()
        return image
    }

    func paletteRows(registryStore: RegistryStore?) -> (profiles: [TileSpawner.AnnotatedProfile], projects: [ProjectPickerRow]) {
        let profiles = tileSpawner?.annotatedProfiles() ?? []
        guard let registryStore,
              let registry = try? registryStore.loadOrEmpty() else {
            return (profiles, [])
        }
        let projects = ProjectPickerModel.makeRows(registry: registry)
            .filter { $0.id != project.id }
        return (profiles, projects)
    }

    func scheduleCanvasSave() {
        // Coalesce drag-rate writes: schedule a save after the last change.
        // flushPendingSaves() runs immediately for project switch and close.
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushCanvasSave() }
        }
    }

    func scheduleBrowserSave() {
        // Browser url/title changes coalesce identically to canvas drags.
        browserSaveTimer?.invalidate()
        browserSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushBrowserSave() }
        }
    }

    func scheduleNoteSave() {
        noteSaveTimer?.invalidate()
        noteSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushNoteSave() }
        }
    }

    func scheduleFileTreeSave() {
        fileTreeSaveTimer?.invalidate()
        fileTreeSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushFileTreeSave() }
        }
    }

    func flushPendingSaves() {
        flushCanvasSave()
        flushBrowserSave()
        flushNoteSave()
        flushFileTreeSave()
    }

    func flushCanvasSave() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard let canvasView else { return }
        try? projectStore.saveCanvas(canvasView.canvasState)
    }

    func flushBrowserSave() {
        browserSaveTimer?.invalidate()
        browserSaveTimer = nil
        guard let tileSpawner else { return }
        for runtime in browserRuntimes {
            tileSpawner.writeBrowserTileSnapshot(for: runtime)
        }
    }

    func flushNoteSave() {
        noteSaveTimer?.invalidate()
        noteSaveTimer = nil
        guard let tileSpawner else { return }
        for view in noteViews.values {
            tileSpawner.writeNoteSnapshot(noteId: view.noteId, tileId: view.tile.id, text: view.textView.string)
        }
    }

    func flushFileTreeSave() {
        fileTreeSaveTimer?.invalidate()
        fileTreeSaveTimer = nil
        guard let tileSpawner else { return }
        for view in fileTreeViews.values {
            tileSpawner.writeFileTreeTileSnapshot(for: view)
        }
    }

    static func runHydrationLifecycleSelfCheck() throws -> URL {
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
            .appendingPathComponent("continuum-zone-hydration-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let now = Date()
        let tileId = UUID(uuidString: "00000000-0000-0000-0000-000000000451")!
        let project = Project(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000045F")!,
            name: "zone-hydration-lifecycle-check",
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
        try store.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [Tile(
                id: tileId,
                kind: .browser,
                title: "Lifecycle browser",
                frame: TileFrame(x: 20, y: 20, width: 640, height: 420),
                zIndex: 1,
                runtimeRef: nil,
                metadata: TileMetadata(url: "data:text/html;charset=utf-8,<html><head><title>lifecycle</title></head><body>ok</body></html>")
            )],
            groups: [],
            lastActiveTileId: nil
        ))

        let canvas = CanvasNSView(canvasState: try store.loadCanvas())
        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }
        let spawner = TileSpawner(canvasView: canvas, ghostty: nil, browserEngine: browserEngine, projectStore: store, project: project)
        let controller = ZoneRuntimeController(projectRoot: tempRoot, projectStore: store, project: project)
        controller.attachUI(canvasView: canvas, tileSpawner: spawner, focusBroker: FocusBroker())

        switch spawner.restartBrowserTile(tileId: tileId) {
        case let .restarted(runtime):
            controller.browserRuntimes = [runtime]
        case let .invalidURL(url):
            throw CheckError.failed("seed restart rejected URL: \(url)")
        case .tileNotFound:
            throw CheckError.failed("seed restart did not find browser tile")
        case let .failure(error):
            throw CheckError.failed("seed restart failed: \(error)")
        }

        try controller.setTier(.snapshot)
        let afterSnapshotTile = canvas.canvasState.tiles.first(where: { $0.id == tileId })
        let snapshotViewPresent = canvas.tileView(for: tileId) is BrowserSnapshotTileNSView
        let liveCountAfterSnapshot = controller.browserRuntimes.count
        let snapshotRuntimeRefCleared = afterSnapshotTile?.runtimeRef == nil

        try controller.setTier(.live)
        let afterLiveTile = canvas.canvasState.tiles.first(where: { $0.id == tileId })
        let liveViewPresent = canvas.tileView(for: tileId) is BrowserTileNSView
        let liveCountAfterHydrate = controller.browserRuntimes.count
        let liveRuntimeRefRestored = afterLiveTile?.runtimeRef?.kind == .browserTile

        canvas.markActive(tileId: tileId)
        let focusedGuardRejected: Bool
        do {
            try controller.setTier(.snapshot)
            focusedGuardRejected = false
        } catch HydrationLifecycleError.focusedZoneMustRemainLive(tileId) {
            focusedGuardRejected = true
        }
        let tierAfterFocusedGuard = controller.hydrationTier

        try expect(controller.hydrationTier == .live, "controller returns to live tier")
        try expect(snapshotViewPresent, "snapshot tier installs BrowserSnapshotTileNSView")
        try expect(snapshotRuntimeRefCleared, "snapshot tier clears browser runtimeRef")
        try expect(liveCountAfterSnapshot == 0, "snapshot tier removes live browser runtime from controller")
        try expect(liveViewPresent, "live tier reinstalls BrowserTileNSView")
        try expect(liveCountAfterHydrate == 1, "live tier re-registers one browser runtime")
        try expect(liveRuntimeRefRestored, "live tier restores browser runtimeRef")
        try expect(focusedGuardRejected, "focused zone guard rejects dehydration")
        try expect(tierAfterFocusedGuard == .live, "focused zone guard leaves tier live")

        let manifest: [String: Any] = [
            "check": "zone-hydration-lifecycle",
            "snapshotViewPresent": snapshotViewPresent,
            "snapshotRuntimeRefCleared": snapshotRuntimeRefCleared,
            "liveCountAfterSnapshot": liveCountAfterSnapshot,
            "liveViewPresent": liveViewPresent,
            "liveCountAfterHydrate": liveCountAfterHydrate,
            "liveRuntimeRefRestored": liveRuntimeRefRestored,
            "focusedGuardRejected": focusedGuardRejected,
            "tierAfterFocusedGuard": String(describing: tierAfterFocusedGuard),
            "finalTier": String(describing: controller.hydrationTier),
            "tempProjectRoot": tempRoot.path
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("zone-hydration-lifecycle", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: manifestURL, options: .atomic)
        return manifestURL
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
}

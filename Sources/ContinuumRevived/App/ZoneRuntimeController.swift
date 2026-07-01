import AppKit
import ContinuumRevivedCore
import Foundation

@MainActor
final class ZoneRuntimeController {
    let projectRoot: URL
    let projectStore: any ProjectStoring
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
    private var isCanvasDirty = false
    private var isBrowserDirty = false
    private var isNoteDirty = false
    private var isFileTreeDirty = false

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

    init(root projectRoot: URL, acquireLock: Bool = true) throws {
        self.projectRoot = projectRoot
        if acquireLock {
            let projectLock = ProjectLock(root: projectRoot)
            try projectLock.acquire()
            self.projectLock = projectLock
        } else {
            self.projectLock = nil
        }

        let projectStore = ProjectStore(projectRoot: projectRoot)
        self.projectStore = projectStore

        pruneExitedSessions(in: projectStore)
        self.project = try Self.loadOrCreateProject(in: projectStore, projectRoot: projectRoot)
    }

    init(projectRoot: URL, projectStore: any ProjectStoring, project: Project) {
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
        // Lockstep: every accepted tile focus (via requestFocus OR
        // acceptExistingFocus, both fire this) marks the tile active on the
        // canvas, so `activeSurface` and `lastActiveTileId` can never drift.
        focusBroker.onAcceptedTileFocus = { [weak self] tileId in
            self?.canvasView?.markActive(tileId: tileId)
        }
        // Scope leaving all tiles (canvas/modal) clears the marching-ants
        // border; the tile→tile transition is covered by markActive above.
        focusBroker.onAcceptedCanvasScope = { [weak self] in
            self?.canvasView?.clearFocusBorder()
        }
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
        focusBroker?.onAcceptedTileFocus = nil
        focusBroker?.onAcceptedCanvasScope = nil
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
                browserRuntimes.append(runtime)
                onBrowserRuntimeHydrated?(runtime)
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

    func paletteRows(registryStore: RegistryStore?) -> (profiles: [TileSpawner.AnnotatedProfile], projects: [ProjectPickerRow], workspaces: [WorkspaceEntry]) {
        let profiles = tileSpawner?.annotatedProfiles() ?? []
        guard let registryStore,
              let registry = try? registryStore.loadOrEmpty() else {
            return (profiles, [], [])
        }
        let projects = ProjectPickerModel.makeRows(registry: registry)
            .filter { $0.id != project.id }
        return (profiles, projects, registry.workspaces)
    }

    func scheduleCanvasSave() {
        // Coalesce drag-rate writes: schedule a save after the last change.
        // flushPendingSaves() runs immediately for project switch and close.
        isCanvasDirty = true
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushCanvasSave() }
        }
    }

    func scheduleBrowserSave() {
        // Browser url/title changes coalesce identically to canvas drags.
        isBrowserDirty = true
        browserSaveTimer?.invalidate()
        browserSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushBrowserSave() }
        }
    }

    func scheduleNoteSave() {
        isNoteDirty = true
        noteSaveTimer?.invalidate()
        noteSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushNoteSave() }
        }
    }

    func scheduleFileTreeSave() {
        isFileTreeDirty = true
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
        guard isCanvasDirty, let canvasView else { return }
        try? projectStore.saveCanvas(canvasView.canvasState)
        isCanvasDirty = false
    }

    func flushBrowserSave() {
        browserSaveTimer?.invalidate()
        browserSaveTimer = nil
        guard isBrowserDirty, let tileSpawner else { return }
        for runtime in browserRuntimes {
            tileSpawner.writeBrowserTileSnapshot(for: runtime)
        }
        isBrowserDirty = false
    }

    func flushNoteSave() {
        noteSaveTimer?.invalidate()
        noteSaveTimer = nil
        guard isNoteDirty, let tileSpawner else { return }
        for view in noteViews.values {
            tileSpawner.writeNoteSnapshot(noteId: view.noteId, tileId: view.tile.id, text: view.textView.string)
        }
        isNoteDirty = false
    }

    func flushFileTreeSave() {
        fileTreeSaveTimer?.invalidate()
        fileTreeSaveTimer = nil
        guard isFileTreeDirty, let tileSpawner else { return }
        for view in fileTreeViews.values {
            tileSpawner.writeFileTreeTileSnapshot(for: view)
        }
        isFileTreeDirty = false
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

    static func runSaveIsolationSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self { case let .failed(message): return message }
            }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }
        func seedProject(root: URL, name: String, tileId: UUID) throws -> (ProjectStore, Project, CanvasState) {
            let store = ProjectStore(projectRoot: root)
            let project = Project(
                name: name,
                rootPath: root.path,
                createdAt: Date(),
                updatedAt: Date(),
                defaultLaunchProfileId: "shell",
                editorPreference: .auto,
                settings: ProjectSettings(
                    restorePolicy: .restoreDescriptors,
                    browserStoragePolicy: .perProject,
                    terminalClosePolicy: .askWhenRunning
                )
            )
            let canvas = CanvasState(
                viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                tiles: [Tile(
                    id: tileId,
                    kind: .note,
                    title: name,
                    frame: TileFrame(x: 20, y: 20, width: 300, height: 180),
                    zIndex: 1,
                    runtimeRef: nil,
                    metadata: TileMetadata(noteId: tileId)
                )],
                groups: [],
                lastActiveTileId: nil
            )
            try store.saveProject(project)
            try store.saveCanvas(canvas)
            return (store, project, canvas)
        }
        func bytes(at url: URL) throws -> Data { try Data(contentsOf: url) }
        func modificationDate(at url: URL) throws -> Date {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let date = values.contentModificationDate else { throw CheckError.failed("missing modification date for \(url.path)") }
            return date
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-zone-save-isolation-\(UUID().uuidString)", isDirectory: true)
        let projectARoot = tempRoot.appendingPathComponent("ProjectA", isDirectory: true)
        let projectBRoot = tempRoot.appendingPathComponent("ProjectB", isDirectory: true)
        let projectCRoot = tempRoot.appendingPathComponent("ProjectC", isDirectory: true)
        let appSupport = tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        try fileManager.createDirectory(at: projectARoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: projectBRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: projectCRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let tileA = UUID(uuidString: "00000000-0000-0000-0000-0000000049A1")!
        let tileB = UUID(uuidString: "00000000-0000-0000-0000-0000000049B2")!
        let tileC = UUID(uuidString: "00000000-0000-0000-0000-0000000049C3")!
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-0000000049D4")!
        let (storeA, projectA, canvasA) = try seedProject(root: projectARoot, name: "Project A", tileId: tileA)
        let (storeB, projectB, canvasB) = try seedProject(root: projectBRoot, name: "Project B", tileId: tileB)
        let (storeC, projectC, canvasC) = try seedProject(root: projectCRoot, name: "Project C", tileId: tileC)
        let workspaceStore = WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: appSupport)
        var workspaceDocument = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            zones: [ZonePlacement(
                zoneId: UUID(uuidString: "00000000-0000-0000-0000-0000000049E5")!,
                projectId: projectA.id,
                origin: ZonePoint(x: 0, y: 0),
                size: ZoneSize(width: 1280, height: 720),
                color: "mint",
                collapsed: false,
                hydrationPolicy: .automatic
            )],
            zoneZOrder: [UUID(uuidString: "00000000-0000-0000-0000-0000000049E5")!],
            lastActiveZoneId: UUID(uuidString: "00000000-0000-0000-0000-0000000049E5")!
        )
        try workspaceStore.save(workspaceDocument)
        let beforeWorkspace = try bytes(at: workspaceStore.layout.canvasFile)
        let beforeWorkspaceModifiedAt = try modificationDate(at: workspaceStore.layout.canvasFile)
        let beforeB = try bytes(at: storeB.layout.canvasFile)
        let beforeBModifiedAt = try modificationDate(at: storeB.layout.canvasFile)
        let beforeC = try bytes(at: storeC.layout.canvasFile)
        let beforeCModifiedAt = try modificationDate(at: storeC.layout.canvasFile)
        Thread.sleep(forTimeInterval: 1.1)

        let viewA = CanvasNSView(canvasState: canvasA)
        let viewB = CanvasNSView(canvasState: canvasB)
        let viewC = CanvasNSView(canvasState: canvasC)
        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }
        let spawnerA = TileSpawner(canvasView: viewA, ghostty: nil, browserEngine: browserEngine, projectStore: storeA, project: projectA)
        let spawnerB = TileSpawner(canvasView: viewB, ghostty: nil, browserEngine: browserEngine, projectStore: storeB, project: projectB)
        let spawnerC = TileSpawner(canvasView: viewC, ghostty: nil, browserEngine: browserEngine, projectStore: storeC, project: projectC)
        let controllerA = ZoneRuntimeController(projectRoot: projectARoot, projectStore: storeA, project: projectA)
        let controllerB = ZoneRuntimeController(projectRoot: projectBRoot, projectStore: storeB, project: projectB)
        let controllerC = ZoneRuntimeController(projectRoot: projectCRoot, projectStore: storeC, project: projectC)
        controllerA.attachUI(canvasView: viewA, tileSpawner: spawnerA, focusBroker: FocusBroker())
        controllerB.attachUI(canvasView: viewB, tileSpawner: spawnerB, focusBroker: FocusBroker())
        controllerC.attachUI(canvasView: viewC, tileSpawner: spawnerC, focusBroker: FocusBroker())

        controllerB.flushPendingSaves()
        controllerC.flushPendingSaves()
        let afterBCleanFlush = try bytes(at: storeB.layout.canvasFile)
        let afterBCleanFlushModifiedAt = try modificationDate(at: storeB.layout.canvasFile)
        let afterCCleanFlush = try bytes(at: storeC.layout.canvasFile)
        let afterCCleanFlushModifiedAt = try modificationDate(at: storeC.layout.canvasFile)
        let cleanSidecarsAbsent = !fileManager.fileExists(atPath: storeB.layout.browserFile.path)
            && !fileManager.fileExists(atPath: storeB.layout.notesIndexFile.path)
            && !fileManager.fileExists(atPath: storeB.layout.fileTreeIndexFile.path)
            && !fileManager.fileExists(atPath: storeC.layout.browserFile.path)
            && !fileManager.fileExists(atPath: storeC.layout.notesIndexFile.path)
            && !fileManager.fileExists(atPath: storeC.layout.fileTreeIndexFile.path)

        viewA.setViewport(CanvasViewport(x: 49, y: 0, zoom: 1))
        controllerA.scheduleCanvasSave()
        controllerA.flushPendingSaves()

        let afterBWhenAFlushed = try bytes(at: storeB.layout.canvasFile)
        let afterBWhenAFlushedModifiedAt = try modificationDate(at: storeB.layout.canvasFile)
        let afterWorkspaceWhenProjectAFlushed = try bytes(at: workspaceStore.layout.canvasFile)
        let afterWorkspaceWhenProjectAFlushedModifiedAt = try modificationDate(at: workspaceStore.layout.canvasFile)
        let reloadedA = try storeA.loadCanvas()
        let bCleanFlushUnchanged = beforeB == afterBCleanFlush && beforeBModifiedAt == afterBCleanFlushModifiedAt
        let cCleanFlushUnchanged = beforeC == afterCCleanFlush && beforeCModifiedAt == afterCCleanFlushModifiedAt
        let bUnchangedAfterAFlush = beforeB == afterBWhenAFlushed && beforeBModifiedAt == afterBWhenAFlushedModifiedAt
        let workspaceUnchangedAfterProjectFlush = beforeWorkspace == afterWorkspaceWhenProjectAFlushed && beforeWorkspaceModifiedAt == afterWorkspaceWhenProjectAFlushedModifiedAt
        let aViewportFlushed = reloadedA.viewport.x == 49

        workspaceDocument.zones[0].origin.x = 240
        let workspaceSaveController = WorkspaceDocumentSaveController(store: workspaceStore)
        workspaceSaveController.scheduleZoneLayoutSave(workspaceDocument)
        try workspaceSaveController.flushPendingSave()
        let afterWorkspaceLayoutChange = try bytes(at: workspaceStore.layout.canvasFile)
        let reloadedWorkspace = try workspaceStore.load()
        let workspaceChangedAfterZoneLayout = beforeWorkspace != afterWorkspaceLayoutChange && reloadedWorkspace.zones[0].origin.x == 240

        viewA.setViewport(CanvasViewport(x: 98, y: 0, zoom: 1))
        controllerA.scheduleCanvasSave()
        try controllerA.setTier(.snapshot, allowDehydratingFocusedZone: true)
        let reloadedAAfterDehydrate = try storeA.loadCanvas()
        let afterBAfterDehydrate = try bytes(at: storeB.layout.canvasFile)
        let afterBAfterDehydrateModifiedAt = try modificationDate(at: storeB.layout.canvasFile)
        let pendingFlushOnDehydrate = reloadedAAfterDehydrate.viewport.x == 98
        let bUnchangedAfterDehydrate = beforeB == afterBAfterDehydrate && beforeBModifiedAt == afterBAfterDehydrateModifiedAt

        try expect(bCleanFlushUnchanged, "clean zone B flush did not rewrite project B canvas")
        try expect(cCleanFlushUnchanged, "clean zone C flush did not rewrite project C canvas")
        try expect(cleanSidecarsAbsent, "clean browser/note/file-tree flushes did not create sidecar files in clean zones")
        try expect(aViewportFlushed, "zone A canvas change flushed to project A")
        try expect(bUnchangedAfterAFlush, "flushing zone A did not rewrite project B canvas")
        try expect(workspaceUnchangedAfterProjectFlush, "project canvas changes do not rewrite workspace document")
        try expect(workspaceChangedAfterZoneLayout, "zone-layout changes rewrite workspace document")
        try expect(pendingFlushOnDehydrate, "dehydrating zone A flushes pending canvas changes")
        try expect(bUnchangedAfterDehydrate, "dehydrating zone A did not rewrite project B canvas")

        let manifest: [String: Any] = [
            "check": "zone-save-isolation",
            "bCleanFlushUnchanged": bCleanFlushUnchanged,
            "cCleanFlushUnchanged": cCleanFlushUnchanged,
            "cleanSidecarsAbsent": cleanSidecarsAbsent,
            "aViewportFlushed": aViewportFlushed,
            "bUnchangedAfterAFlush": bUnchangedAfterAFlush,
            "workspaceUnchangedAfterProjectFlush": workspaceUnchangedAfterProjectFlush,
            "workspaceChangedAfterZoneLayout": workspaceChangedAfterZoneLayout,
            "pendingFlushOnDehydrate": pendingFlushOnDehydrate,
            "bUnchangedAfterDehydrate": bUnchangedAfterDehydrate,
            "workspaceCanvas": workspaceStore.layout.canvasFile.path,
            "projectACanvas": storeA.layout.canvasFile.path,
            "projectBCanvas": storeB.layout.canvasFile.path,
            "projectCCanvas": storeC.layout.canvasFile.path,
            "projectBCanvasModifiedAt": beforeBModifiedAt.timeIntervalSince1970,
            "tempRoot": tempRoot.path
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("zone-save-isolation", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: manifestURL, options: .atomic)
        return manifestURL
    }

    private static func loadOrCreateProject(in store: any ProjectStoring, projectRoot: URL) throws -> Project {
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

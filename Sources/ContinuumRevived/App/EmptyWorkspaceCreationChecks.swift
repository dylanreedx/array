import AppKit
import ContinuumRevivedCore
import Foundation

/// M1.11 (`.plans/46`) — a workspace with no projects must never be a dead end.
///
/// The toolbar `+` creates an EMPTY workspace and switches into it. That releases
/// every project, so `registry.liveControllers` is empty, `acquiredProjectIds`
/// is empty, and `WorkspaceRuntime.activeController` returns nil. From there:
///
/// - `openProfilePalette()` opened with
///   `guard let activeController = …, let host = window else { return }`, so ⌘K
///   and the toolbar's "Add or jump…" did **nothing at all, silently** — and the
///   palette is the app's only add surface.
/// - note and browser spawning guarded only on `tileSpawner`, which fell back to
///   `bootTileSpawner`: a spawner still pointing at the DEPARTED project's store.
///   They "succeeded" into another project's canvas, and because
///   `browserRuntimes`' setter is computed over `activeController` it dropped the
///   runtime too.
///
/// This leg reaches that state through the real `+` route rather than building it
/// by hand, so it also witnesses how easy the state is to reach.
@MainActor
enum EmptyWorkspaceCreationChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        var localizedDescription: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    static func run() throws {
        let fileManager = FileManager.default
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        let workspaceWA = UUID(uuidString: "00000000-0000-0000-0000-00000000B101")!
        let projectAlpha = UUID(uuidString: "00000000-0000-0000-0000-00000000B102")!
        let projectBeta = UUID(uuidString: "00000000-0000-0000-0000-00000000B103")!
        let zoneAlpha = UUID(uuidString: "00000000-0000-0000-0000-00000000B104")!
        let noteAlpha = UUID(uuidString: "00000000-0000-0000-0000-00000000B105")!

        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-empty-workspace-\(UUID().uuidString)", isDirectory: true)
        let alphaRoot = tempRoot.appendingPathComponent("Alpha", isDirectory: true)
        let betaRoot = tempRoot.appendingPathComponent("Beta", isDirectory: true)
        let appSupport = tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        for dir in [alphaRoot, betaRoot, appSupport] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? fileManager.removeItem(at: tempRoot) }

        func makeProject(id: UUID, name: String, root: URL) -> Project {
            Project(
                id: id, name: name, rootPath: root.path, createdAt: now, updatedAt: now,
                defaultLaunchProfileId: "shell", editorPreference: .auto,
                settings: ProjectSettings(
                    restorePolicy: .restoreDescriptors,
                    browserStoragePolicy: .perProject,
                    terminalClosePolicy: .askWhenRunning))
        }
        let alphaObj = makeProject(id: projectAlpha, name: "Alpha", root: alphaRoot)
        let betaObj = makeProject(id: projectBeta, name: "Beta", root: betaRoot)
        let storeAlpha = ProjectStore(projectRoot: alphaRoot)
        let storeBeta = ProjectStore(projectRoot: betaRoot)

        var alphaTile = Tile(
            id: noteAlpha, kind: .note, title: "note",
            frame: TileFrame(x: 20, y: 20, width: 220, height: 140),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(noteId: noteAlpha))
        alphaTile.zoneId = zoneAlpha
        try storeAlpha.saveProject(alphaObj)
        try storeAlpha.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [alphaTile], groups: [], lastActiveTileId: noteAlpha))
        try storeBeta.saveProject(betaObj)
        try storeBeta.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))

        // Alpha has a zone. Beta is REGISTERED but has no zone anywhere — the state
        // a project is in right after "Add Project…", and the one that used to
        // leave a spawn with nowhere to land.
        let docA = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            zones: [ZonePlacement(
                zoneId: zoneAlpha, projectId: projectAlpha,
                origin: ZonePoint(x: 0, y: 0), size: ZoneSize(width: 900, height: 700),
                color: "blue", collapsed: false, hydrationPolicy: .automatic)],
            zoneZOrder: [zoneAlpha],
            lastActiveZoneId: zoneAlpha)
        try WorkspaceStore(workspaceId: workspaceWA, applicationSupportDirectory: appSupport).save(docA)

        var appRegistry = Registry.empty()
        appRegistry.lastActiveWorkspaceId = workspaceWA
        appRegistry.projects = [
            ProjectEntry(id: projectAlpha, name: "Alpha", rootPath: alphaRoot.path, workspaceId: workspaceWA,
                         lastOpenedAt: now, pinned: false, missing: false),
            ProjectEntry(id: projectBeta, name: "Beta", rootPath: betaRoot.path, workspaceId: workspaceWA,
                         lastOpenedAt: now, pinned: false, missing: false)
        ]
        appRegistry.workspaces = [WorkspaceEntry(
            id: workspaceWA, name: "Alpha Workspace",
            projectIds: [projectAlpha, projectBeta], createdAt: now, updatedAt: now)]
        let registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        try registryStore.save(appRegistry)

        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }
        let zoneRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { projectId in
            if projectId == projectAlpha {
                return ZoneRuntimeController(projectRoot: alphaRoot, projectStore: storeAlpha, project: alphaObj)
            }
            if projectId == projectBeta {
                return ZoneRuntimeController(projectRoot: betaRoot, projectStore: storeBeta, project: betaObj)
            }
            throw Failure(message: "unexpected projectId: \(projectId)")
        })

        let bootCanvas = try storeAlpha.loadCanvas()
        let canvas = CanvasNSView(
            canvasState: bootCanvas,
            activeZone: docA.zones.first,
            zoneRenderModels: docA.zones.map {
                CanvasNSView.ZoneRenderModel(placement: $0, displayName: "Alpha")
            })
        canvas.frame = CGRect(x: 0, y: 0, width: 1400, height: 900)

        let delegate = AppDelegate()
        let runtime = WorkspaceRuntime(
            boot: try zoneRegistry.acquire(projectId: projectAlpha),
            workspaceId: workspaceWA,
            document: docA,
            registry: zoneRegistry,
            focusBroker: delegate.qaFocusBroker,
            registryStore: registryStore,
            ghostty: nil,
            browserEngine: browserEngine)
        delegate.qaPrepareForBootMountCheck(
            canvas: canvas, browserEngine: browserEngine, runtime: runtime, registryStore: registryStore)

        let spawner = TileSpawner(
            canvasView: canvas, ghostty: nil, browserEngine: browserEngine,
            projectStore: storeAlpha, project: alphaObj)
        try delegate.mountWorkspaceSceneAtBoot(
            canvasView: canvas, spawner: spawner, projectStore: storeAlpha,
            canvasState: bootCanvas, installsGlobalEventMonitors: false)

        // `openProfilePalette` needs a window; a check must never take the screen.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = canvas
        delegate.qaAttachWindowForOfflineCheck(window)

        let alphaCanvasBefore = try storeAlpha.loadCanvas()

        // === Reach the broken state the way a user does: the "+" button. ===
        delegate.workspaceCreatePromptProvider = { "Empty" }
        delegate.qaCreateWorkspaceFromChrome()

        try expect(runtime.activeController == nil,
                   "precondition: creating an empty workspace must leave no active controller — that "
                   + "is the state this leg exists for")
        try expect(!delegate.qaHasTileSpawner,
                   "precondition: `tileSpawner` must not fall back to the departed boot project's "
                   + "spawner; that fallback is what let note and browser spawn into nothing")

        // === A: the palette opens at all. RED before M1.11. ===
        delegate.qaOpenProfilePalette()
        guard let palette = delegate.qaProfilePalette else {
            throw Failure(message: "the command palette must open in a workspace with no projects. It "
                          + "guarded on activeController, so Cmd+K and the Add button did nothing "
                          + "whatsoever — and the palette is the only add surface there is.")
        }
        try expect(palette.isVisible, "the palette must actually be visible")

        // === B: it offers a way out, on the HOME, not merely findable by search. ===
        let home = palette.filteredDisplayNamesForQA
        try expect(home.contains("Add Project…"),
                   "the palette home must offer \"Add Project…\" when there is no project; got \(home)")
        try expect(home.contains(where: { $0.contains("Beta") }),
                   "the palette must offer the already-registered project Beta; got \(home)")

        // === C: a spawn is never a silent no-op. ===
        var scopeAsks = 0
        delegate.creationScopePickerPresenterForQA = { _ in scopeAsks += 1 }
        try expect(delegate.qaPerformPaletteAction(.newNote) == false,
                   "a note must not claim success with nowhere to put it")
        try expect(scopeAsks == 1, "it must ask which project to create into; asks=\(scopeAsks)")
        try expect(delegate.qaPerformPaletteAction(.newBrowser) == false,
                   "a browser must not claim success with nowhere to put it")
        try expect(scopeAsks == 2, "the browser path must ask too; asks=\(scopeAsks)")
        try expect(delegate.qaBrowserRuntimeCount == 0,
                   "no browser runtime may be built and then dropped; got \(delegate.qaBrowserRuntimeCount)")

        // And the departed project's canvas is untouched — the exact harm.
        let alphaCanvasAfter = try storeAlpha.loadCanvas()
        try expect(alphaCanvasAfter.tiles.count == alphaCanvasBefore.tiles.count,
                   "the DEPARTED project's canvas must be untouched: it had "
                   + "\(alphaCanvasBefore.tiles.count) tile(s) and now has \(alphaCanvasAfter.tiles.count). "
                   + "Spawning through the stale boot spawner is what wrote into it.")

        // === D: the add-project route lands, durably. ===
        delegate.creationScopePickerPresenterForQA = nil
        delegate.addProjectSelectionProvider = {
            appRegistry.projects.first(where: { $0.id == projectBeta })
        }
        try expect(delegate.qaPerformPaletteAction(.addProject),
                   "choosing a project must give it a live controller — registering it without a zone "
                   + "is the same dead end one level down")
        try expect(runtime.controller(for: projectBeta) != nil,
                   "Beta must now have a live controller")
        let emptyWorkspaceId = runtime.workspaceId
        let savedDoc = try WorkspaceStore(workspaceId: emptyWorkspaceId,
                                          applicationSupportDirectory: appSupport).tryLoad()
        try expect(savedDoc?.zones.contains(where: { $0.projectId == projectBeta }) == true,
                   "the new zone must be persisted into the workspace document")

        // === E: and now a note lands somewhere real, in the RIGHT project. ===
        // The durable fact, not `performPaletteAction`'s return: that return is a
        // `navigationTileSnapshots().count` heuristic, which is a pre-existing
        // inaccuracy this leg has no business pinning.
        _ = delegate.qaPerformPaletteAction(.newNote)
        let betaAfter = try storeBeta.loadCanvas()
        try expect(betaAfter.tiles.contains(where: { $0.kind == .note }),
                   "the note must land in Beta's canvas")
        let alphaFinal = try storeAlpha.loadCanvas()
        try expect(alphaFinal.tiles.count == alphaCanvasBefore.tiles.count,
                   "and Alpha's canvas must STILL be untouched")

        print("EmptyWorkspaceCreationChecks: the + button's empty workspace opened the palette, "
              + "offered Add Project and an existing project on the home, refused note and browser "
              + "audibly without touching the departed project's canvas, and after adding a project a "
              + "note landed in the right one")
    }
}

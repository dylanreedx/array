import AppKit
import ContinuumRevivedCore
import Foundation

/// M1.10 (`.plans/46`) — the shipping app must actually give `WorkspaceRuntime`
/// a canvas, and switching workspaces must change what is on it.
///
/// **The defect this exists for.** `WorkspaceRuntime.canvasView` is a
/// `private weak var` written in exactly one place, `install(into:appRegistry:)`
/// — and every one of that method's 26 call sites is a self-check or
/// `PerfScenarios`. Production has never called it, since the method was
/// introduced in `93c68f43`. So every canvas operation inside `switchWorkspace`
/// optional-chained through nil: `retireFlatCompatibilityScene()`,
/// `setZones(layers)`, `setViewport`, `setActiveProjectZone`,
/// `attachActiveControllerUI` and both hydration hooks all did nothing. The
/// document, the registry and the toolbar header changed; the canvas did not.
/// A user switching workspaces watched the header say "0 zones" over the
/// previous workspace's tiles.
///
/// **Why six green legs missed it, which is the part worth remembering.**
/// `--zone-tile-hydration-check`, `--zone-runtime-duplication-check`,
/// `--zone-spawner-coverage-check`, `--zone-tile-detach-sweep-check`,
/// `--canvas-persistence-model-check` and `--inbox-reveal-project-check` each
/// call `install(into:)` themselves before asserting. Every one of them proved a
/// property of a code path production does not execute. This leg's defining
/// constraint is therefore: **it never calls `install(into:)`.** It drives
/// `AppDelegate.mountWorkspaceSceneAtBoot(...)`, the method
/// `applicationDidFinishLaunching` calls, and everything it asserts flows from
/// that.
@MainActor
enum WorkspaceSceneOwnerChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        var localizedDescription: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    private static func describe(_ view: TileNSView?) -> String {
        guard let view else { return "nil" }
        return String(describing: type(of: view))
    }

    static func run() throws {
        let fileManager = FileManager.default
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        let workspaceWA = UUID(uuidString: "00000000-0000-0000-0000-00000000A101")!
        let workspaceWB = UUID(uuidString: "00000000-0000-0000-0000-00000000A102")!
        let projectPa = UUID(uuidString: "00000000-0000-0000-0000-00000000A103")!
        let projectPb = UUID(uuidString: "00000000-0000-0000-0000-00000000A104")!
        let projectForeign = UUID(uuidString: "00000000-0000-0000-0000-00000000A105")!
        let zoneA = UUID(uuidString: "00000000-0000-0000-0000-00000000A106")!
        let zoneForeign = UUID(uuidString: "00000000-0000-0000-0000-00000000A107")!
        let zoneB = UUID(uuidString: "00000000-0000-0000-0000-00000000A108")!
        // Three notes in Pa: correctly stamped, stamped with ANOTHER project's
        // zone (the field case — 89 tiles in one real project), and unstamped.
        let noteOwn = UUID(uuidString: "00000000-0000-0000-0000-00000000A109")!
        let noteForeign = UUID(uuidString: "00000000-0000-0000-0000-00000000A10A")!
        let noteUnstamped = UUID(uuidString: "00000000-0000-0000-0000-00000000A10B")!
        let noteB = UUID(uuidString: "00000000-0000-0000-0000-00000000A10C")!

        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-scene-owner-\(UUID().uuidString)", isDirectory: true)
        let paRoot = tempRoot.appendingPathComponent("Pa", isDirectory: true)
        let pbRoot = tempRoot.appendingPathComponent("Pb", isDirectory: true)
        let appSupport = tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        for dir in [paRoot, pbRoot, appSupport] {
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
                    terminalClosePolicy: .askWhenRunning
                )
            )
        }
        func note(_ id: UUID, zone: UUID?, x: Double, y: Double) -> Tile {
            var tile = Tile(
                id: id, kind: .note, title: "note",
                frame: TileFrame(x: x, y: y, width: 220, height: 140),
                zPosition: .fromLegacyRank(1), runtimeRef: nil,
                metadata: TileMetadata(noteId: id)
            )
            tile.zoneId = zone
            return tile
        }

        let projectPaObj = makeProject(id: projectPa, name: "Pa", root: paRoot)
        let projectPbObj = makeProject(id: projectPb, name: "Pb", root: pbRoot)
        let storePa = ProjectStore(projectRoot: paRoot)
        let storePb = ProjectStore(projectRoot: pbRoot)

        // WORLD frames, which is what every canvas.json in the field holds, and
        // inside zoneA's world rect so the rescue is unambiguous.
        let paTiles = [
            note(noteOwn, zone: zoneA, x: 640, y: 240),
            note(noteForeign, zone: zoneForeign, x: 700, y: 300),
            note(noteUnstamped, zone: nil, x: 760, y: 360)
        ]
        try storePa.saveProject(projectPaObj)
        try storePa.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: paTiles, groups: [], lastActiveTileId: noteOwn))
        try storePb.saveProject(projectPbObj)
        try storePb.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [note(noteB, zone: zoneB, x: 40, y: 40)], groups: [], lastActiveTileId: noteB))

        // zoneA sits at a NON-ZERO origin on purpose: world-vs-zone-local is the
        // hazard that would teleport every tile the first time layers went live.
        func placement(_ zone: UUID, project: UUID?, x: Double, y: Double, color: String) -> ZonePlacement {
            ZonePlacement(
                zoneId: zone, projectId: project,
                origin: ZonePoint(x: x, y: y), size: ZoneSize(width: 900, height: 700),
                color: color, collapsed: false, hydrationPolicy: .automatic
            )
        }
        let docA = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            zones: [placement(zoneA, project: projectPa, x: 600, y: 200, color: "blue"),
                    placement(zoneForeign, project: projectForeign, x: 2000, y: 200, color: "green")],
            zoneZOrder: [zoneA, zoneForeign],
            lastActiveZoneId: zoneA
        )
        let docB = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            zones: [placement(zoneB, project: projectPb, x: 0, y: 0, color: "red")],
            zoneZOrder: [zoneB],
            lastActiveZoneId: zoneB
        )
        try WorkspaceStore(workspaceId: workspaceWA, applicationSupportDirectory: appSupport).save(docA)
        try WorkspaceStore(workspaceId: workspaceWB, applicationSupportDirectory: appSupport).save(docB)

        var appRegistry = Registry.empty()
        appRegistry.lastActiveWorkspaceId = workspaceWA
        appRegistry.projects = [
            ProjectEntry(id: projectPa, name: "Pa", rootPath: paRoot.path, workspaceId: workspaceWA,
                         lastOpenedAt: now, pinned: false, missing: false),
            ProjectEntry(id: projectPb, name: "Pb", rootPath: pbRoot.path, workspaceId: workspaceWB,
                         lastOpenedAt: now, pinned: false, missing: false)
        ]
        let registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        try registryStore.save(appRegistry)

        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }

        let zoneRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { projectId in
            if projectId == projectPa {
                return ZoneRuntimeController(projectRoot: paRoot, projectStore: storePa, project: projectPaObj)
            }
            if projectId == projectPb {
                return ZoneRuntimeController(projectRoot: pbRoot, projectStore: storePb, project: projectPbObj)
            }
            throw Failure(message: "unexpected projectId in factory: \(projectId)")
        })

        // Boot the way production boots: the canvas is built from the BOOT
        // project's flat canvas plus the document's zone render models.
        let bootCanvasState = try storePa.loadCanvas()
        let canvas = CanvasNSView(
            canvasState: bootCanvasState,
            activeZone: docA.zones.first(where: { $0.projectId == projectPa }),
            zoneRenderModels: docA.zones.map {
                CanvasNSView.ZoneRenderModel(placement: $0, displayName: $0.name.isEmpty ? "Zone" : $0.name)
            }
        )
        canvas.frame = CGRect(x: 0, y: 0, width: 2000, height: 1200)

        let delegate = AppDelegate()
        let runtime = WorkspaceRuntime(
            boot: try zoneRegistry.acquire(projectId: projectPa),
            workspaceId: workspaceWA,
            document: docA,
            registry: zoneRegistry,
            focusBroker: delegate.qaFocusBroker,
            registryStore: registryStore,
            ghostty: nil,
            browserEngine: browserEngine
        )
        delegate.qaPrepareForBootMountCheck(
            canvas: canvas, browserEngine: browserEngine, runtime: runtime, registryStore: registryStore)

        let spawner = TileSpawner(
            canvasView: canvas,
            ghostty: nil,
            browserEngine: browserEngine,
            projectStore: storePa,
            project: projectPaObj
        )

        // === The production seam. NOT `install(into:)`. ===
        try delegate.mountWorkspaceSceneAtBoot(
            canvasView: canvas,
            spawner: spawner,
            projectStore: storePa,
            canvasState: bootCanvasState,
            installsGlobalEventMonitors: false)
        canvas.layoutSubtreeIfNeeded()

        // 1. THE assertion. RED for this defect's entire life: nothing in
        //    production ever handed the runtime a canvas, so every canvas call in
        //    `switchWorkspace` was a no-op.
        try expect(runtime.qaHasCanvas,
                   "the production boot mount must give the WorkspaceRuntime its canvas. Without "
                   + "this every canvas call in switchWorkspace optional-chains through nil, so "
                   + "switching workspaces changes the document and the header and leaves the "
                   + "previous workspace's tiles on screen.")

        // 2. Boot itself is unchanged: still the flat compatibility scene, still
        //    the boot project's tiles at their persisted WORLD frames.
        try expect(canvas.isFlatCompatibilitySceneActive,
                   "boot must still be the flat scene — this milestone deliberately does not move "
                   + "the launch path into layers")
        for tile in paTiles {
            let view = canvas.tileView(for: tile.id)
            try expect(view is NoteTileNSView,
                       "boot: \(tile.id) must be a live note tile; got \(describe(view))")
        }

        // 3. A runtime nobody handed a canvas must FAIL, loudly, rather than
        //    silently changing the document. This is the recurrence guard.
        let orphanRuntime = WorkspaceRuntime(
            boot: try zoneRegistry.acquire(projectId: projectPa),
            workspaceId: workspaceWA,
            document: docA,
            registry: zoneRegistry,
            focusBroker: delegate.qaFocusBroker,
            registryStore: registryStore,
            ghostty: nil,
            browserEngine: browserEngine
        )
        var refused = false
        do { try orphanRuntime.switchWorkspace(to: workspaceWB) } catch { refused = true }
        try expect(refused,
                   "a WorkspaceRuntime with no canvas must REFUSE to switch. Silently doing the "
                   + "document half and skipping the canvas half is the defect itself.")
        zoneRegistry.release(projectId: projectPa)

        print("WorkspaceSceneOwnerChecks: the production boot mount handed the runtime its canvas, "
              + "boot stayed flat with live tiles, and a canvas-less runtime refused to switch")
    }
}

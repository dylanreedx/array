import AppKit
import ContinuumRevivedCore
import Foundation

/// WS9 — a zone whose project was not live at boot must still create into its OWN
/// project.
///
/// **The defect, as reported from a real workspace.** Two zones, two projects. One
/// zone worked; creating an agent tile in the other "did not know about the home
/// project directory". The cause was three separate things lining up:
///
///  1. Controllers were acquired ONLY in `install`, and only for zones the
///     hydration plan called `.live`. A zone off-screen at mount got none.
///  2. `reconcileHydration` — the pass that runs for the rest of the session —
///     skipped any zone whose project had no controller, so it could never
///     acquire one. A zone that was not live at boot could therefore never
///     become live, no matter how far the camera moved or how often it was
///     clicked. Its own `focusedTileZone` computation was circular for the same
///     reason: it looked inside controllers to decide which zone was focused.
///  3. `spawnerForFilesystemCreation` fell back to the ACTIVE project's spawner
///     when the scoped controller was missing.
///
/// The scope and the spawner are resolved through different paths — the scope
/// from the app registry, the spawner from the live controller — so the scope was
/// happily correct for the unacquired project while the spawner was not. The tile
/// was stamped for one project and persisted into another, with its managed
/// session written under the wrong `.array/`.
///
/// A witness that asserted only the creation SCOPE would have stayed green
/// throughout: the scope was never wrong. This asserts the spawner's project,
/// which is what decides where the tile actually lands.
///
/// Drives `mountWorkspaceSceneAtBoot`, never `install(into:)` — the M1.10 rule.
@MainActor
enum ZoneUnacquiredProjectChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        var localizedDescription: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    static func run() throws {
        try runScenario(lockedProject: nil)
        try runScenario(lockedProject: .far)
        print("ZoneUnacquiredProjectChecks: a zone below the live tier acquired its project on "
              + "arming and created through its OWN spawner; an unacquirable project refused "
              + "instead of silently using the armed-away project")
    }

    private enum LockedProject { case far }

    private static func runScenario(lockedProject: LockedProject?) throws {
        let fileManager = FileManager.default
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ws9-unacquired-\(UUID().uuidString)", isDirectory: true)
        let appSupport = tempRoot.appendingPathComponent("support", isDirectory: true)
        let nearRoot = tempRoot.appendingPathComponent("near", isDirectory: true)
        let farRoot = tempRoot.appendingPathComponent("far", isDirectory: true)
        for dir in [appSupport, nearRoot, farRoot] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? fileManager.removeItem(at: tempRoot) }

        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000009000")!
        let projectNear = UUID(uuidString: "00000000-0000-0000-0000-000000009001")!
        let projectFar = UUID(uuidString: "00000000-0000-0000-0000-000000009002")!
        let zoneNear = UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!
        let zoneFar = UUID(uuidString: "00000000-0000-0000-0000-00000000A002")!
        let seedNote = UUID(uuidString: "00000000-0000-0000-0000-00000000B001")!

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
        let nearProjectObj = makeProject(id: projectNear, name: "Near", root: nearRoot)
        let farProjectObj = makeProject(id: projectFar, name: "Far", root: farRoot)
        let storeNear = ProjectStore(projectRoot: nearRoot)
        let storeFar = ProjectStore(projectRoot: farRoot)

        var seedTile = Tile(
            id: seedNote, kind: .note, title: "seed",
            frame: TileFrame(x: 640, y: 240, width: 220, height: 140),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(noteId: seedNote)
        )
        seedTile.zoneId = zoneNear
        try storeNear.saveProject(nearProjectObj)
        try storeNear.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [seedTile], groups: [], lastActiveTileId: seedNote))
        try storeFar.saveProject(farProjectObj)
        try storeFar.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [], groups: [], lastActiveTileId: nil))

        func placement(_ zone: UUID, project: UUID, x: Double) -> ZonePlacement {
            ZonePlacement(
                zoneId: zone, projectId: project,
                origin: ZonePoint(x: x, y: 200), size: ZoneSize(width: 900, height: 700),
                color: "blue", collapsed: false, hydrationPolicy: .automatic
            )
        }
        // The far zone sits well outside the 2000x1200 viewport at boot, so the
        // hydration plan gives it no controller. That is the whole scenario: the
        // reported workspace had exactly this shape.
        let document = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            zones: [placement(zoneNear, project: projectNear, x: 600),
                    placement(zoneFar, project: projectFar, x: 40_000)],
            zoneZOrder: [zoneNear, zoneFar],
            lastActiveZoneId: zoneNear
        )
        try WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: appSupport).save(document)

        var appRegistry = Registry.empty()
        appRegistry.lastActiveWorkspaceId = workspaceId
        appRegistry.workspaces = [
            WorkspaceEntry(id: workspaceId, name: "W", projectIds: [projectNear, projectFar],
                           createdAt: now, updatedAt: now)
        ]
        appRegistry.projects = [
            ProjectEntry(id: projectNear, name: "Near", rootPath: nearRoot.path, workspaceId: workspaceId,
                         lastOpenedAt: now, pinned: false, missing: false),
            ProjectEntry(id: projectFar, name: "Far", rootPath: farRoot.path, workspaceId: workspaceId,
                         lastOpenedAt: now, pinned: false, missing: false)
        ]
        let registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        try registryStore.save(appRegistry)

        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }

        let zoneRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { projectId in
            if projectId == projectNear {
                return ZoneRuntimeController(projectRoot: nearRoot, projectStore: storeNear, project: nearProjectObj)
            }
            if projectId == projectFar {
                // The locked scenario: another install holds this project's
                // `.array/` (CLAUDE.md hazard 10), so acquisition fails.
                if lockedProject == .far {
                    throw Failure(message: "simulated: Far's .array/ lock is held by another install")
                }
                return ZoneRuntimeController(projectRoot: farRoot, projectStore: storeFar, project: farProjectObj)
            }
            throw Failure(message: "unexpected projectId in factory: \(projectId)")
        })

        let bootCanvasState = try storeNear.loadCanvas()
        let canvas = CanvasNSView(
            canvasState: bootCanvasState,
            activeZone: document.zones.first(where: { $0.projectId == projectNear }),
            zoneRenderModels: document.zones.map {
                CanvasNSView.ZoneRenderModel(placement: $0, displayName: $0.name.isEmpty ? "Zone" : $0.name)
            }
        )
        canvas.frame = CGRect(x: 0, y: 0, width: 2000, height: 1200)

        let delegate = AppDelegate()
        let runtime = WorkspaceRuntime(
            boot: try zoneRegistry.acquire(projectId: projectNear),
            workspaceId: workspaceId,
            document: document,
            registry: zoneRegistry,
            focusBroker: delegate.qaFocusBroker,
            registryStore: registryStore,
            ghostty: nil,
            browserEngine: browserEngine
        )
        var unavailableReports: [UUID] = []
        runtime.onZoneProjectUnavailable = { projectId, _ in unavailableReports.append(projectId) }
        delegate.qaPrepareForBootMountCheck(
            canvas: canvas, browserEngine: browserEngine, runtime: runtime, registryStore: registryStore)

        let spawner = TileSpawner(
            canvasView: canvas, ghostty: nil, browserEngine: browserEngine,
            projectStore: storeNear, project: nearProjectObj
        )

        try delegate.mountWorkspaceSceneAtBoot(
            canvasView: canvas,
            spawner: spawner,
            projectStore: storeNear,
            canvasState: bootCanvasState,
            installsGlobalEventMonitors: false)
        canvas.layoutSubtreeIfNeeded()

        // POSITIVE CONTROL. Everything below is meaningless unless the far zone
        // genuinely starts WITHOUT a controller — that is the state the bug needs,
        // and a fixture that quietly acquired it at boot would pass while proving
        // nothing.
        try expect(runtime.controller(for: projectFar) == nil,
                   "control: the far zone's project must start unacquired, or this witnesses nothing")
        try expect(runtime.controller(for: projectNear) != nil,
                   "control: the near zone's project must be acquired at boot")
        try expect(delegate.qaCreationSpawnerProjectId == projectNear,
                   "boot: creation must run through the near project's spawner")

        // === The reported bug. Click the far zone, then create. ===
        // Click ONLY. No pan, no reconcile: `reconcileHydration` rides the camera
        // debounce and re-arms whatever zone the camera is over, so flushing it
        // here would re-arm the near zone and test the fixture instead of the
        // product. Clicking a zone must be enough on its own.
        delegate.qaActivateZoneByClick(zoneFar)

        try expect(runtime.qaArmedZoneId == zoneFar,
                   "arming a zone whose project is unacquired must still arm it; got "
                   + "\(String(describing: runtime.qaArmedZoneId))")

        // The creation SCOPE was always correct — it resolves from the app
        // registry, which knows Far perfectly well. Asserting only this is the
        // false-green trap.
        try expect(delegate.qaResolvedCreationScope?.projectId == projectFar,
                   "the creation scope must name the armed zone's project")

        if lockedProject == nil {
            try expect(runtime.controller(for: projectFar) != nil,
                       "arming a zone must acquire its project's controller; without one, creation "
                       + "silently falls back to the active project's spawner")
            // THE assertion. This is where the tile actually lands.
            try expect(delegate.qaCreationSpawnerProjectId == projectFar,
                       "creation must run through the ARMED zone's spawner, not the active "
                       + "project's; got \(String(describing: delegate.qaCreationSpawnerProjectId)) "
                       + "instead of \(projectFar)")
            try expect(unavailableReports.isEmpty,
                       "an acquirable project must not be reported unavailable")
        } else {
            // Locked: refuse rather than land somewhere wrong. `setActiveZone`'s
            // own contract — a spawn that cannot resolve its project must refuse.
            try expect(runtime.controller(for: projectFar) == nil,
                       "a project whose lock is held must not appear acquired")
            try expect(delegate.qaCreationSpawnerProjectId == nil,
                       "when the armed zone's project cannot be acquired, creation must REFUSE "
                       + "(nil spawner, so the caller offers the picker) rather than silently use "
                       + "the other project; got \(String(describing: delegate.qaCreationSpawnerProjectId))")
            try expect(unavailableReports.contains(projectFar),
                       "an unacquirable project must be reported so the app can say so out loud")
        }
    }
}

import AppKit
import ContinuumRevivedCore
import Foundation

/// WS2 F2 — a committed layout must survive a relaunch in the SAME place.
///
/// **The defect.** `persistLayoutTransaction` is handed WORLD frames
/// (`CanvasNSView.captureGeometry` converts every layer tile through
/// `CanvasEngine.worldFrame(tile:in:)` before building the transaction), and it
/// converted them to ZONE-LOCAL before writing them to durable storage. Both
/// durable stores hold WORLD:
///
///  - `WorkspaceDocument.ambientTiles` — the read path
///    (`WorkspaceRuntime.makeAmbientZoneLayer`) converts WORLD→LOCAL on the way
///    into the layer, and the pre-v3 migration flattened world-framed group-zone
///    tiles into the register untouched.
///  - `canvas.json` — the invariant the whole ZoneLayer model rests on
///    (`WorkspaceRuntime.memberTiles` converts on the way in,
///    `CanvasNSView.tilesInWorldFrames(forProjectId:)` on the way out).
///
/// So the origin was subtracted on the write AND again on the read: every tile
/// moved by −zoneOrigin per commit/remount cycle, and the error accumulated.
///
/// **Why nothing caught it.** `onLayoutCommitted` was wired inside
/// `applicationDidFinishLaunching`, the one place no self-check can reach — the
/// M1.10 trap. The only route from a canvas gesture to durable storage had no
/// witness in either direction. It is now wired in `mountWorkspaceSceneAtBoot`
/// and this drives that mount.
///
/// **Why the assertion is a ROUND TRIP and not a frame-space equality.** A
/// witness that asserted "the persisted frame is WORLD" states the convention;
/// it does not state the user-visible promise, and it would have to be inverted
/// by hand if the convention ever changed. This asserts what the user sees: move
/// a tile, relaunch, find it where you left it. It stays true under either
/// convention and false under a mismatched pair, which is the actual defect.
@MainActor
enum AmbientTileFrameSpaceChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        var localizedDescription: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    /// Two commit/remount cycles. One cycle catches the mismatch; two prove it
    /// ACCUMULATES, which is what separates a frame-space bug from a one-off
    /// rounding difference.
    private static let cycles = 2

    static func run() throws {
        try runScenario()
        print("ambient-tile-frame-space: a committed move of an ambient tile and of a project "
              + "tile survived \(cycles) commit/remount cycles in place; both durable stores "
              + "round-trip WORLD frames through persistLayoutTransaction")
    }

    private static func runScenario() throws {
        let fileManager = FileManager.default
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ws2-framespace-\(UUID().uuidString)", isDirectory: true)
        let appSupport = tempRoot.appendingPathComponent("support", isDirectory: true)
        let projectRoot = tempRoot.appendingPathComponent("proj", isDirectory: true)
        for dir in [appSupport, projectRoot] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? fileManager.removeItem(at: tempRoot) }

        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-0000000F0000")!
        let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000F0001")!
        let ambientZoneId = UUID(uuidString: "00000000-0000-0000-0000-0000000FA001")!
        let projectZoneId = UUID(uuidString: "00000000-0000-0000-0000-0000000FA002")!
        let ambientTileId = UUID(uuidString: "00000000-0000-0000-0000-0000000FB001")!
        let projectTileId = UUID(uuidString: "00000000-0000-0000-0000-0000000FB002")!

        // Non-zero, non-equal origins on both zones. A zone at the origin would
        // make the two frame spaces identical and this witness vacuous; equal
        // origins would let a fix that used the wrong zone's origin pass.
        let ambientOrigin = ZonePoint(x: 1_400, y: 800)
        let projectOrigin = ZonePoint(x: 300, y: 2_200)

        let project = Project(
            id: projectId, name: "P", rootPath: projectRoot.path, createdAt: now, updatedAt: now,
            defaultLaunchProfileId: "shell", editorPreference: .auto,
            settings: ProjectSettings(
                restorePolicy: .restoreDescriptors,
                browserStoragePolicy: .perProject,
                terminalClosePolicy: .askWhenRunning
            )
        )
        let projectStore = ProjectStore(projectRoot: projectRoot)
        try projectStore.saveProject(project)

        func makeTile(_ id: UUID, zone: UUID, frame: TileFrame) -> Tile {
            var tile = Tile(
                id: id, kind: .note, title: "t",
                frame: frame, zPosition: .fromLegacyRank(1), runtimeRef: nil,
                metadata: TileMetadata(noteId: id)
            )
            tile.zoneId = zone
            return tile
        }

        // Seeded in WORLD, inside their zones' rects.
        let ambientSeed = TileFrame(x: 1_500, y: 900, width: 220, height: 140)
        // 240x160 is the project tile's enforced minimum size: seeding smaller
        // makes the mount grow it and the control fails on size, not position.
        let projectSeed = TileFrame(x: 400, y: 2_300, width: 240, height: 160)

        try projectStore.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [makeTile(projectTileId, zone: projectZoneId, frame: projectSeed)],
            groups: [], lastActiveTileId: projectTileId))

        func placement(_ zoneId: UUID, project: UUID?, origin: ZonePoint) -> ZonePlacement {
            ZonePlacement(
                zoneId: zoneId, projectId: project,
                origin: origin, size: ZoneSize(width: 900, height: 700),
                color: "blue", collapsed: false, hydrationPolicy: .automatic
            )
        }
        let document = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            zones: [placement(ambientZoneId, project: nil, origin: ambientOrigin),
                    placement(projectZoneId, project: projectId, origin: projectOrigin)],
            zoneZOrder: [ambientZoneId, projectZoneId],
            lastActiveZoneId: projectZoneId,
            ambientTiles: [makeTile(ambientTileId, zone: ambientZoneId, frame: ambientSeed)]
        )
        let workspaceStore = WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: appSupport)
        try workspaceStore.save(document)

        var appRegistry = Registry.empty()
        appRegistry.lastActiveWorkspaceId = workspaceId
        appRegistry.workspaces = [
            WorkspaceEntry(id: workspaceId, name: "W", projectIds: [projectId],
                           createdAt: now, updatedAt: now)
        ]
        appRegistry.projects = [
            ProjectEntry(id: projectId, name: "P", rootPath: projectRoot.path, workspaceId: workspaceId,
                         lastOpenedAt: now, pinned: false, missing: false)
        ]
        let registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        try registryStore.save(appRegistry)

        /// One launch: mount the persisted scene exactly as the app does, hand the
        /// caller the live canvas, then tear down. Every cycle reads its state from
        /// DISK, so a value cached in memory can never carry a cycle.
        func withMountedScene(_ body: (CanvasNSView, AppDelegate) throws -> Void) throws {
            let browserEngine = BrowserEngineContext()
            defer { browserEngine.shutdown() }
            let zoneRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { id in
                guard id == projectId else { throw Failure(message: "unexpected project \(id)") }
                return ZoneRuntimeController(projectRoot: projectRoot, projectStore: projectStore, project: project)
            })
            let liveDocument = try workspaceStore.load()
            let bootCanvasState = try projectStore.loadCanvas()
            let canvas = CanvasNSView(
                canvasState: bootCanvasState,
                activeZone: liveDocument.zones.first(where: { $0.zoneId == projectZoneId }),
                zoneRenderModels: liveDocument.zones.map {
                    CanvasNSView.ZoneRenderModel(placement: $0, displayName: $0.name.isEmpty ? "Zone" : $0.name)
                }
            )
            canvas.frame = CGRect(x: 0, y: 0, width: 4_000, height: 4_000)

            let delegate = AppDelegate()
            let runtime = WorkspaceRuntime(
                boot: try zoneRegistry.acquire(projectId: projectId),
                workspaceId: workspaceId,
                document: liveDocument,
                registry: zoneRegistry,
                focusBroker: delegate.qaFocusBroker,
                registryStore: registryStore,
                ghostty: nil,
                browserEngine: browserEngine
            )
            delegate.qaPrepareForBootMountCheck(
                canvas: canvas, browserEngine: browserEngine, runtime: runtime, registryStore: registryStore)
            let spawner = TileSpawner(
                canvasView: canvas, ghostty: nil, browserEngine: browserEngine,
                projectStore: projectStore, project: project
            )
            try delegate.mountWorkspaceSceneAtBoot(
                canvasView: canvas,
                spawner: spawner,
                projectStore: projectStore,
                canvasState: bootCanvasState,
                installsGlobalEventMonitors: false)
            canvas.layoutSubtreeIfNeeded()
            try body(canvas, delegate)
        }

        func worldFrame(_ canvas: CanvasNSView, zone: UUID, tile: UUID) throws -> TileFrame {
            guard let tiles = canvas.tilesInWorldFrames(forZoneId: zone) else {
                throw Failure(message: "zone \(zone) has no installed layer — the scene did not mount")
            }
            guard let match = tiles.first(where: { $0.id == tile }) else {
                throw Failure(message: "tile \(tile) is not in zone \(zone) after mount; "
                              + "layer holds \(tiles.map(\.id))")
            }
            return match.frame
        }

        func close(_ lhs: TileFrame, _ rhs: TileFrame) -> Bool {
            abs(lhs.x - rhs.x) < 0.5 && abs(lhs.y - rhs.y) < 0.5
                && abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
        }
        func show(_ frame: TileFrame) -> String {
            "(\(frame.x), \(frame.y), \(frame.width)x\(frame.height))"
        }

        // POSITIVE CONTROL ON THE MOUNT. Everything below compares against these;
        // if the seeded scene does not come back at its seeded WORLD position, the
        // fixture is broken and no later comparison means anything.
        try withMountedScene { canvas, _ in
            let ambientMounted = try worldFrame(canvas, zone: ambientZoneId, tile: ambientTileId)
            try expect(close(ambientMounted, ambientSeed),
                       "control: the seeded ambient tile must mount at its seeded WORLD frame; got "
                       + "\(show(ambientMounted)) for \(show(ambientSeed))")
            let projectMounted = try worldFrame(canvas, zone: projectZoneId, tile: projectTileId)
            try expect(close(projectMounted, projectSeed),
                       "control: the seeded project tile must mount at its seeded WORLD frame; got "
                       + "\(show(projectMounted)) for \(show(projectSeed))")
        }

        var expectedAmbient = ambientSeed
        var expectedProject = projectSeed

        for cycle in 1...cycles {
            // Move both tiles by a distinct offset per cycle, through the real
            // gesture-commit seam: `applyGeometrySnapshot` →
            // `persistGeometrySnapshot` → `onLayoutCommitted` →
            // `persistLayoutTransaction`. Nothing here calls the persistence
            // method directly.
            let step = Double(cycle) * 10
            let targetAmbient = TileFrame(x: expectedAmbient.x + step, y: expectedAmbient.y + step,
                                          width: expectedAmbient.width, height: expectedAmbient.height)
            let targetProject = TileFrame(x: expectedProject.x + step, y: expectedProject.y + step,
                                          width: expectedProject.width, height: expectedProject.height)

            try withMountedScene { canvas, _ in
                let applied = canvas.applyGeometrySnapshot(CanvasGeometrySnapshot(
                    tiles: [
                        CanvasTileGeometry(tileId: ambientTileId, frame: targetAmbient, zoneId: ambientZoneId),
                        CanvasTileGeometry(tileId: projectTileId, frame: targetProject, zoneId: projectZoneId)
                    ],
                    zones: [
                        CanvasZoneGeometry(zoneId: ambientZoneId, origin: ambientOrigin,
                                           size: ZoneSize(width: 900, height: 700)),
                        CanvasZoneGeometry(zoneId: projectZoneId, origin: projectOrigin,
                                           size: ZoneSize(width: 900, height: 700))
                    ]))
                // POSITIVE CONTROL ON THE COMMIT. `applyGeometrySnapshot` returns
                // false when persistence refuses, and rolls the scene back — a
                // silent refusal would leave every tile where it already was and
                // let the round-trip assertions pass while nothing was written.
                try expect(applied, "cycle \(cycle): the geometry commit was refused, so nothing was persisted")
                let ambientLive = try worldFrame(canvas, zone: ambientZoneId, tile: ambientTileId)
                try expect(close(ambientLive, targetAmbient),
                           "cycle \(cycle): the LIVE ambient tile did not land where it was moved; got "
                           + "\(show(ambientLive)) for \(show(targetAmbient))")
            }

            expectedAmbient = targetAmbient
            expectedProject = targetProject

            // Relaunch. THE assertion: a committed move must survive.
            try withMountedScene { canvas, _ in
                let ambientAfter = try worldFrame(canvas, zone: ambientZoneId, tile: ambientTileId)
                try expect(close(ambientAfter, expectedAmbient),
                           "cycle \(cycle): the AMBIENT tile moved on relaunch — persisted and read "
                           + "in different frame spaces. Expected \(show(expectedAmbient)), got "
                           + "\(show(ambientAfter)); the delta is the zone origin "
                           + "(\(ambientOrigin.x), \(ambientOrigin.y))")
                let projectAfter = try worldFrame(canvas, zone: projectZoneId, tile: projectTileId)
                try expect(close(projectAfter, expectedProject),
                           "cycle \(cycle): the PROJECT tile moved on relaunch — canvas.json holds WORLD "
                           + "frames but the layout transaction wrote zone-local. Expected "
                           + "\(show(expectedProject)), got \(show(projectAfter)); the delta is the zone "
                           + "origin (\(projectOrigin.x), \(projectOrigin.y))")
            }
        }
    }
}

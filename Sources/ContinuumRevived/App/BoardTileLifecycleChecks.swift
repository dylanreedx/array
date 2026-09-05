import AppKit
import ContinuumRevivedCore
import Foundation

/// KB-01 B10 — the board tile's lifecycle, driven through production entry
/// points. Plan: `.plans/60-kanban-board.md`.
///
/// **What this exists to catch, and why the obvious assertion would not.**
///
/// A spawn must frame the tile against the SAME zone it installs into. While the
/// armed zone and the creation scope cannot differ, framing against one and
/// installing into the other is invisible — and they can differ now, because
/// clicking, focusing, creating a zone and panning all re-point the armed zone
/// (`.plans/47`). A witness that asserts the tile's `zoneId` STAMP stays green
/// through exactly that bug: the stamp is written by the install, so it is right
/// even when the geometry is wrong.
///
/// So this asserts the tile's **world frame against the zone's world rect**, on a
/// zone with a deliberately NON-ZERO origin. At the origin the two frame spaces
/// coincide and the whole witness is vacuous.
///
/// It then relaunches from disk and asserts the board hydrates through
/// `makeHydratedTileView` with its cards intact — the half that proves board
/// data survives independently of the canvas — and that closing the tile leaves
/// the document alone.
@MainActor
enum BoardTileLifecycleChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        var localizedDescription: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    static func run() throws {
        try runScenario()
        print("board-tile-lifecycle: a Command-K board spawned into a zone at a non-zero origin "
              + "landed inside that zone's WORLD rect, its cards survived a relaunch through "
              + "makeHydratedTileView, a card move left canvas.json untouched, and closing the "
              + "tile kept the document")
    }

    private static func runScenario() throws {
        let fileManager = FileManager.default
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("kb01-lifecycle-\(UUID().uuidString)", isDirectory: true)
        let appSupport = tempRoot.appendingPathComponent("support", isDirectory: true)
        let projectRoot = tempRoot.appendingPathComponent("proj", isDirectory: true)
        for dir in [appSupport, projectRoot] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? fileManager.removeItem(at: tempRoot) }

        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-00000000B000")!
        let projectId = UUID(uuidString: "00000000-0000-0000-0000-00000000B001")!
        // TWO zones for one project. With a single zone the armed zone and the
        // creation scope are necessarily the same placement, so a spawn that framed
        // against the armed zone while installing into the scope's would land in
        // exactly the right place and the witness would have no teeth — verified by
        // mutating the spawn to pass `targetZoneId: nil` and watching it still pass.
        // The armed zone is A; the scope points at B.
        let armedZoneId = UUID(uuidString: "00000000-0000-0000-0000-00000000BA02")!
        let projectZoneId = UUID(uuidString: "00000000-0000-0000-0000-00000000BA03")!
        let seedTileId = UUID(uuidString: "00000000-0000-0000-0000-00000000BB02")!

        // Non-zero on BOTH axes. A zone at the origin makes world and zone-local
        // identical, and every assertion below would hold for the broken code.
        let armedOrigin = ZonePoint(x: 1_300, y: 2_100)
        // Far from the armed zone on BOTH axes: framing against A and installing
        // into B displaces the tile by the difference of the origins, which must
        // land it clean outside B.
        let projectOrigin = ZonePoint(x: 3_400, y: 900)
        let zoneSize = ZoneSize(width: 1_600, height: 1_200)
        // A window-sized canvas looking at the middle of the zone, which is what a
        // user pressing Command-K actually has. Centre-aware placement puts the new
        // tile where the camera is looking, so a camera parked outside the zone
        // legitimately frames outside it — that is the placement policy working,
        // not the spawn misbehaving, and the fixture must not confuse the two.
        let canvasSize = CGSize(width: 1_000, height: 700)
        let cameraViewport = CanvasViewport(
            x: projectOrigin.x + zoneSize.width / 2 - Double(canvasSize.width) / 2,
            y: projectOrigin.y + zoneSize.height / 2 - Double(canvasSize.height) / 2,
            zoom: 1)

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

        var seedTile = Tile(
            id: seedTileId, kind: .note, title: "seed",
            frame: TileFrame(x: armedOrigin.x + 40, y: armedOrigin.y + 40, width: 240, height: 160),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(noteId: seedTileId))
        seedTile.zoneId = armedZoneId
        try projectStore.saveCanvas(CanvasState(
            viewport: cameraViewport,
            tiles: [seedTile], groups: [], lastActiveTileId: seedTileId))

        func placement(_ zoneId: UUID, _ origin: ZonePoint) -> ZonePlacement {
            ZonePlacement(
                zoneId: zoneId, projectId: projectId,
                origin: origin, size: zoneSize,
                color: "blue", collapsed: false, hydrationPolicy: .automatic)
        }
        let workspaceStore = WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: appSupport)
        try workspaceStore.save(WorkspaceDocument(
            viewport: cameraViewport,
            zones: [placement(armedZoneId, armedOrigin), placement(projectZoneId, projectOrigin)],
            zoneZOrder: [armedZoneId, projectZoneId],
            lastActiveZoneId: armedZoneId,
            ambientTiles: []))

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

        func withMountedScene(_ body: (CanvasNSView, AppDelegate, TileSpawner, ZoneRuntimeController) throws -> Void) throws {
            let browserEngine = BrowserEngineContext()
            defer { browserEngine.shutdown() }
            var madeController: ZoneRuntimeController?
            let zoneRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { id in
                guard id == projectId else { throw Failure(message: "unexpected project \(id)") }
                let controller = ZoneRuntimeController(
                    projectRoot: projectRoot, projectStore: projectStore, project: project)
                madeController = controller
                return controller
            })
            let liveDocument = try workspaceStore.load()
            let bootCanvasState = try projectStore.loadCanvas()
            let canvas = CanvasNSView(
                canvasState: bootCanvasState,
                activeZone: liveDocument.zones.first(where: { $0.zoneId == armedZoneId }),
                zoneRenderModels: liveDocument.zones.map {
                    CanvasNSView.ZoneRenderModel(placement: $0, displayName: $0.name.isEmpty ? "Zone" : $0.name)
                }
            )
            canvas.frame = CGRect(origin: .zero, size: canvasSize)

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
            // The production wiring, not a fixture shortcut: the spawner resolves
            // the board authority the same way the app does, and it is armed with
            // the same creation scope `configureSpawnerHandlers` supplies. Leaving
            // the scope nil would let the placement fall back to the ambient
            // `activeProjectZonePlacement` path — a different code path from the
            // one every real Command-K spawn takes, so the witness would be
            // testing something the user never runs.
            spawner.boardRuntimeProvider = { runtime.activeController?.boardRuntime }
            try delegate.mountWorkspaceSceneAtBoot(
                canvasView: canvas,
                spawner: spawner,
                projectStore: projectStore,
                canvasState: bootCanvasState,
                installsGlobalEventMonitors: false)
            canvas.layoutSubtreeIfNeeded()
            // AFTER the mount, which reconfigures the spawner it is handed —
            // arming the scope before it is silently discarded.
            spawner.creationScopeProvider = {
                CreationScope(
                    projectId: projectId, projectRoot: projectRoot.path,
                    source: .zone, zoneId: projectZoneId)
            }
            guard let controller = madeController ?? runtime.activeController else {
                throw Failure(message: "no ZoneRuntimeController was created")
            }
            try body(canvas, delegate, spawner, controller)
        }

        let zoneWorldRect = CGRect(
            x: projectOrigin.x, y: projectOrigin.y,
            width: zoneSize.width, height: zoneSize.height)
        let armedWorldRect = CGRect(
            x: armedOrigin.x, y: armedOrigin.y,
            width: zoneSize.width, height: zoneSize.height)

        var spawnedBoardId: UUID?
        var spawnedTileId: UUID?
        var cardA: UUID?

        // ---- Launch 1: spawn, then edit the board.
        try withMountedScene { canvas, _, spawner, controller in
            // POSITIVE CONTROL. If the seeded tile does not mount inside the zone,
            // the fixture is broken and nothing below means anything.
            guard let mounted = canvas.tilesInWorldFrames(forZoneId: armedZoneId),
                  let seed = mounted.first(where: { $0.id == seedTileId }) else {
                throw Failure(message: "control: the seeded tile did not mount into the zone layer")
            }
            try expect(armedWorldRect.contains(CGRect(
                x: seed.frame.x, y: seed.frame.y, width: seed.frame.width, height: seed.frame.height)),
                "control: the seeded tile must mount inside the ARMED zone's world rect")

            guard case let .spawned(boardId, tileId) = spawner.spawnBoard(title: "Board") else {
                throw Failure(message: "spawnBoard failed")
            }
            spawnedBoardId = boardId
            spawnedTileId = tileId
            canvas.layoutSubtreeIfNeeded()

            // THE ASSERTION. World frame against the zone's world rect — not the
            // zoneId stamp, which is written by the install and stays correct
            // through exactly the defect this guards.
            let scopeLayer = canvas.tilesInWorldFrames(forZoneId: projectZoneId)
            let armedLayer = canvas.tilesInWorldFrames(forZoneId: armedZoneId)
            guard let tiles = scopeLayer, let spawned = tiles.first(where: { $0.id == tileId }) else {
                throw Failure(message: "the spawned board tile is not in the SCOPE zone's layer. "
                              + "scope layer: \(scopeLayer.map { $0.map(\.id.uuidString) } as Any); "
                              + "armed layer: \(armedLayer.map { $0.map(\.id.uuidString) } as Any)")
            }
            let spawnedRect = CGRect(
                x: spawned.frame.x, y: spawned.frame.y,
                width: spawned.frame.width, height: spawned.frame.height)
            try expect(zoneWorldRect.contains(spawnedRect),
                       "a board spawned into a zone at \(projectOrigin.x),\(projectOrigin.y) must land "
                       + "inside that zone's WORLD rect \(zoneWorldRect); got \(spawnedRect).")
            // "Inside the zone" alone is NOT enough, and assuming it was is a real
            // hole this witness had: when the frame is computed against the armed
            // zone, `clampedZoneLocalViewport` parks it at the target zone's
            // TOP-LEFT CORNER, which is still inside the rect. Verified — the
            // rect-only assertion stayed green with the spawn framing against the
            // wrong zone. Placement is centre-aware, so assert it landed where the
            // camera is actually looking.
            let cameraCentre = CGPoint(
                x: cameraViewport.x + Double(canvasSize.width) / 2,
                y: cameraViewport.y + Double(canvasSize.height) / 2)
            let spawnedCentre = CGPoint(x: spawnedRect.midX, y: spawnedRect.midY)
            let offset = hypot(spawnedCentre.x - cameraCentre.x, spawnedCentre.y - cameraCentre.y)
            try expect(offset <= 200,
                       "a board must land where the camera is looking (centre-aware placement): "
                       + "camera centre \(cameraCentre), tile centre \(spawnedCentre), off by \(offset)pt. "
                       + "A tile framed against the ARMED zone and installed into the SCOPE zone "
                       + "lands at the scope zone's corner, which is inside the rect but nowhere "
                       + "near the camera.")

            // The board document exists and the tile points at it.
            guard let board = controller.boardRuntime.board(id: boardId) else {
                throw Failure(message: "the spawned board has no document")
            }
            try expect(board.orderedColumns.count == 3,
                       "a new board starts with three columns, got \(board.orderedColumns.count)")

            // Add two cards through the SAME command path the UI uses.
            let first = UUID()
            let second = UUID()
            cardA = first
            let columns = board.orderedColumns.map(\.id)
            for (id, title) in [(first, "alpha"), (second, "beta")] {
                let outcome = controller.boardRuntime.apply(
                    .createCard(id: id, columnId: columns[0], title: title, after: nil, before: nil),
                    to: boardId)
                guard case .applied = outcome else {
                    throw Failure(message: "createCard was not applied: \(outcome)")
                }
            }

            // A card move must not touch canvas.json. This is the architectural
            // claim of the ticket, asserted as a byte comparison against the real
            // store the app just wrote through.
            let canvasBefore = try Data(contentsOf: projectStore.layout.canvasFile)
            let moveOutcome = controller.boardRuntime.apply(
                .moveCard(id: first, toColumn: columns[2], after: nil, before: nil), to: boardId)
            guard case .applied = moveOutcome else {
                throw Failure(message: "moveCard was not applied: \(moveOutcome)")
            }
            let canvasAfter = try Data(contentsOf: projectStore.layout.canvasFile)
            try expect(canvasBefore == canvasAfter,
                       "moving a card rewrote canvas.json — card order is board data, not canvas geometry")
        }

        guard let boardId = spawnedBoardId, let tileId = spawnedTileId, let movedCard = cardA else {
            throw Failure(message: "the spawn did not report its ids")
        }

        // ---- Launch 2: everything comes from disk. Hydration, not re-derivation.
        KanbanHydrationProbe.reset()
        try withMountedScene { canvas, _, _, controller in
            // The witness NAMES a path, so it must prove that path ran. Without
            // this the summary line's claim about `makeHydratedTileView` is
            // unfalsifiable prose.
            try expect(KanbanHydrationProbe.hydratedViaMakeHydratedTileView == 1,
                       "the relaunch must hydrate the board through makeHydratedTileView exactly "
                       + "once, got \(KanbanHydrationProbe.hydratedViaMakeHydratedTileView)")
            try expect(KanbanHydrationProbe.hydratedViaBootWalk == 0,
                       "a zone-layer board must NOT come up through the flat boot walk, which "
                       + "mints ids and writes the canvas as a side effect")
            guard let view = canvas.tileView(for: tileId) as? KanbanTileNSView else {
                throw Failure(message: "the board tile did not hydrate into a KanbanTileNSView on relaunch; "
                              + "got \(String(describing: canvas.tileView(for: tileId)))")
            }
            let board = view.board
            try expect(board.id == boardId, "the hydrated tile must show the board its metadata names")
            try expect(board.cards.count == 2,
                       "both cards must survive the relaunch, got \(board.cards.count)")
            let columns = board.orderedColumns.map(\.id)
            try expect(board.orderedCards(in: columns[2]).map(\.id) == [movedCard],
                       "the moved card must still be in the column it was moved to")
            try expect(board.orderedCards(in: columns[0]).count == 1,
                       "the unmoved card must still be in the first column")

            // The tile is still framed inside its zone after a hydrate — the
            // relaunch half of the world-frame assertion.
            guard let tiles = canvas.tilesInWorldFrames(forZoneId: projectZoneId),
                  let hydrated = tiles.first(where: { $0.id == tileId }) else {
                throw Failure(message: "the hydrated board tile is not in the zone's layer")
            }
            try expect(zoneWorldRect.contains(CGRect(
                x: hydrated.frame.x, y: hydrated.frame.y,
                width: hydrated.frame.width, height: hydrated.frame.height)),
                "the hydrated board tile must still sit inside its zone's world rect")

            // The drag lease: an API edit naming the carried card is refused with
            // a reason rather than applied under the pointer.
            controller.boardRuntime.beginPointerDrag(cardId: movedCard)
            let refused = controller.boardRuntime.apply(
                .moveCard(id: movedCard, toColumn: columns[0], after: nil, before: nil), to: boardId)
            try expect(refused == .rejectedCardHeldByPointer,
                       "an API move of the card under the pointer must be rejected, got \(refused)")
            // An UNRELATED edit still applies — a drag must not freeze the board.
            let unrelated = controller.boardRuntime.apply(
                .renameColumn(id: columns[1], name: "Renamed"), to: boardId)
            guard case .applied = unrelated else {
                throw Failure(message: "an unrelated edit during a drag must still apply, got \(unrelated)")
            }
            controller.boardRuntime.endPointerDrag()
        }

        // ---- Closing the tile keeps the document.
        try withMountedScene { canvas, delegate, _, controller in
            try expect(canvas.tileView(for: tileId) != nil, "the board tile must be present before the close")
            delegate.deleteTile(id: tileId)
            canvas.layoutSubtreeIfNeeded()
            try expect(canvas.tileView(for: tileId) == nil, "the tile must be gone after the close")
            // Closing a tile is closing a WINDOW. The board survives.
            //
            // Read through a FRESH store, not `controller.boardRuntime.board(id:)`:
            // the runtime caches the board in memory, so a version of this that
            // asked the runtime stayed green when the close deleted the file —
            // verified by mutating the close path to call `deleteBoard` and
            // watching it still pass. Only disk can answer this question.
            _ = controller
            let onDisk = ProjectStore(projectRoot: projectRoot)
            // The FILE, not a load. `AtomicWriter` keeps backups and `tryLoadBoard`
            // will happily restore from one, so a load-based assertion survives an
            // outright delete — verified by mutating the close path to call
            // `deleteBoard` and watching the load still succeed.
            try expect(FileManager.default.fileExists(atPath: onDisk.layout.boardFile(id: boardId).path),
                       "closing the board TILE deleted the board FILE — a close is closing a "
                       + "window, not deleting the user's data")
            guard let board = try onDisk.tryLoadBoard(id: boardId) else {
                throw Failure(message: "closing the board TILE deleted the board DOCUMENT — "
                              + "a close is closing a window, not deleting the user's data")
            }
            try expect(board.cards.count == 2, "the closed board keeps its cards")
            let state = try onDisk.tryLoadBoardState()
            let entry = state?.boards.first { $0.id == boardId }
            try expect(entry != nil, "the board's index entry must survive the tile close")
            try expect(entry?.tileId == nil,
                       "the index entry must drop its tile pointer when the tile closes")
        }
    }
}

/// QA-only counters naming WHICH hydration path built a board tile. A witness
/// that claims a path must be able to prove the path ran.
@MainActor
enum KanbanHydrationProbe {
    static var hydratedViaMakeHydratedTileView = 0
    static var hydratedViaBootWalk = 0
    static func reset() {
        hydratedViaMakeHydratedTileView = 0
        hydratedViaBootWalk = 0
    }
}

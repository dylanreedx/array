import AppKit
import ContinuumRevivedCore
import Foundation

/// T1-T5 (`.plans/47`) — the zone new tiles land in must follow the user.
///
/// **The defect.** `CanvasNSView.activeProjectZoneId` is the only input to the
/// `.zone` candidate in `resolvedCreationScope`, and it was written in exactly
/// four places: the boot mount, `switchWorkspace`, the file-open repoint and the
/// onboarding starter. Nothing a *user* did ever re-pointed it. So:
///
///  - Creating a second zone moved `document.lastActiveZoneId` (and therefore the
///    active controller) but never told the canvas, so a tile created "in" the new
///    zone used the FIRST zone's project and Home.
///  - Correcting that through the creation-scope picker did not stick either.
///    The pick persists as `lastExplicitCreationScope`, which enters the resolver
///    as `.recentExplicit` — BELOW `.zone`. A stale armed zone therefore outranked
///    the user's own correction on the very next spawn, and every spawn after it.
///
/// **And the latent half.** `spawnManagedAgent` (and the terminal, and the file
/// tree) framed a tile against `activeProjectZonePlacement` while installing it
/// into `creationScope?.zoneId`. Those could not disagree while the scope could
/// only ever name the armed zone — the moment arming works, they can, and a
/// zone-local frame computed against the wrong origin lands the tile off by the
/// difference between the two zone origins. Notes and browsers ignored the scope
/// outright. Assertion 5 is world geometry, not merely the zone stamp, because a
/// stamp-only assertion would have stayed green through exactly that bug.
///
/// Drives `mountWorkspaceSceneAtBoot`, never `install(into:)` — the M1.10 rule.
@MainActor
enum ZoneArmingChecks {
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

        let workspaceWA = UUID(uuidString: "00000000-0000-0000-0000-00000000B201")!
        let projectPa = UUID(uuidString: "00000000-0000-0000-0000-00000000B202")!
        let projectPb = UUID(uuidString: "00000000-0000-0000-0000-00000000B203")!
        let zoneA = UUID(uuidString: "00000000-0000-0000-0000-00000000B204")!
        let zoneG = UUID(uuidString: "00000000-0000-0000-0000-00000000B205")!
        let noteA = UUID(uuidString: "00000000-0000-0000-0000-00000000B206")!

        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-zone-arming-\(UUID().uuidString)", isDirectory: true)
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

        let projectPaObj = makeProject(id: projectPa, name: "Pa", root: paRoot)
        let projectPbObj = makeProject(id: projectPb, name: "Pb", root: pbRoot)
        let storePa = ProjectStore(projectRoot: paRoot)
        let storePb = ProjectStore(projectRoot: pbRoot)

        var seedTile = Tile(
            id: noteA, kind: .note, title: "seed",
            frame: TileFrame(x: 640, y: 240, width: 220, height: 140),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(noteId: noteA)
        )
        seedTile.zoneId = zoneA
        try storePa.saveProject(projectPaObj)
        try storePa.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [seedTile], groups: [], lastActiveTileId: noteA))
        try storePb.saveProject(projectPbObj)
        try storePb.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [], groups: [], lastActiveTileId: nil))

        // zoneA at a NON-ZERO origin, so a frame computed against the wrong zone
        // is arithmetically visible rather than accidentally correct.
        func placement(_ zone: UUID, project: UUID?, x: Double, y: Double, color: String) -> ZonePlacement {
            ZonePlacement(
                zoneId: zone, projectId: project,
                origin: ZonePoint(x: x, y: y), size: ZoneSize(width: 900, height: 700),
                color: color, collapsed: false, hydrationPolicy: .automatic
            )
        }
        // A GROUP zone (projectId == nil) is in the document on purpose: arming one
        // would make `activeController` nil and disarm creation entirely.
        let docA = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            zones: [placement(zoneA, project: projectPa, x: 600, y: 200, color: "blue"),
                    placement(zoneG, project: nil, x: 4000, y: 200, color: "gray")],
            zoneZOrder: [zoneA, zoneG],
            lastActiveZoneId: zoneA
        )
        try WorkspaceStore(workspaceId: workspaceWA, applicationSupportDirectory: appSupport).save(docA)

        var appRegistry = Registry.empty()
        appRegistry.lastActiveWorkspaceId = workspaceWA
        appRegistry.workspaces = [
            WorkspaceEntry(id: workspaceWA, name: "A", projectIds: [projectPa, projectPb], createdAt: now, updatedAt: now)
        ]
        appRegistry.projects = [
            ProjectEntry(id: projectPa, name: "Pa", rootPath: paRoot.path, workspaceId: workspaceWA,
                         lastOpenedAt: now, pinned: false, missing: false),
            ProjectEntry(id: projectPb, name: "Pb", rootPath: pbRoot.path, workspaceId: workspaceWA,
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

        // At boot the scene is flat, so `activeProjectZoneId` is nil and the boot
        // `activeZone` is the real target. The indicator has to agree with the
        // resolver, fallback included, or it would just relocate the surprise.
        try expect(canvas.armedZoneId == zoneA,
                   "boot: the armed zone must be the boot project's zone; got "
                   + "\(String(describing: canvas.armedZoneId))")
        try expect(delegate.qaResolvedCreationScope?.projectId == projectPa,
                   "boot: creation must scope to the boot project")

        // ==================================================================
        // 1. THE reported bug: adding a second project's zone must arm it.
        // ==================================================================
        _ = delegate.qaPerformPaletteAction(.addProjectToCanvas(projectPb))
        canvas.layoutSubtreeIfNeeded()

        guard let zoneB = runtime.document.zones.first(where: { $0.projectId == projectPb })?.zoneId else {
            throw Failure(message: "adding Pb to the canvas created no zone for it")
        }
        try expect(runtime.qaArmedZoneId == zoneB,
                   "add-zone: the document must record the NEW zone as active; got "
                   + "\(String(describing: runtime.qaArmedZoneId))")
        try expect(canvas.armedZoneId == zoneB,
                   "add-zone: THE reported bug. `_addProjectZone` moved "
                   + "`document.lastActiveZoneId` (so the controller followed) but never called "
                   + "`setActiveProjectZone`, so the CANVAS — which is what the creation scope and "
                   + "every spawn's placement read — stayed on the first zone. Got "
                   + "\(String(describing: canvas.armedZoneId))")
        try expect(delegate.qaResolvedCreationScope?.projectId == projectPb,
                   "add-zone: a tile created now must use Pb's project Home, not Pa's. Got "
                   + "\(String(describing: delegate.qaResolvedCreationScope?.projectId))")
        try expect(delegate.qaResolvedCreationScope?.zoneId == zoneB,
                   "add-zone: the scope must name the new zone, since placement is computed "
                   + "against it")
        try expect(canvas.qaArmedChromeZoneIds == [zoneB],
                   "add-zone: exactly the armed zone draws the armed accent; got "
                   + "\(canvas.qaArmedChromeZoneIds)")

        // ==================================================================
        // 2. A tile spawned now lands in Zb, AT A FRAME INSIDE Zb.
        //    Stamp-only would stay green through the frame/install split.
        // ==================================================================
        let beforeNoteIds = Set(canvas.allWorkspaceTiles().map(\.id))
        _ = delegate.qaPerformPaletteAction(.newNote)
        canvas.layoutSubtreeIfNeeded()
        let spawnedIds = Set(canvas.allWorkspaceTiles().map(\.id)).subtracting(beforeNoteIds)
        guard let spawnedNoteId = spawnedIds.first, spawnedIds.count == 1 else {
            throw Failure(message: "expected exactly one new tile from `.newNote`; got \(spawnedIds.count)")
        }
        try expect(canvas.qaZoneMembership(of: spawnedNoteId) == zoneB,
                   "spawn: the note must belong to the armed zone; got "
                   + "\(String(describing: canvas.qaZoneMembership(of: spawnedNoteId)))")
        guard let zoneBPlacement = runtime.document.zones.first(where: { $0.zoneId == zoneB }),
              let spawnedWorld = canvas.tilesInWorldFrames(forProjectId: projectPb)
                  .first(where: { $0.id == spawnedNoteId })?.frame else {
            throw Failure(message: "spawn: could not read the new note's world frame")
        }
        let zoneRect = CanvasEngine.zoneWorldFrame(zoneBPlacement)
        try expect(spawnedWorld.x >= zoneRect.x - 0.001
                   && spawnedWorld.y >= zoneRect.y - 0.001
                   && spawnedWorld.x <= zoneRect.x + zoneRect.width + 0.001
                   && spawnedWorld.y <= zoneRect.y + zoneRect.height + 0.001,
                   "spawn: T4. The tile must be FRAMED against the zone it is INSTALLED into. "
                   + "Framing against the armed zone while installing into the scope's zone "
                   + "displaces it by the difference of the two origins, and a zone-membership "
                   + "assertion alone would not notice. World frame "
                   + "(\(spawnedWorld.x), \(spawnedWorld.y)) is outside zone Zb "
                   + "(\(zoneRect.x), \(zoneRect.y)) \(zoneRect.width)x\(zoneRect.height).")

        // ==================================================================
        // 3. A group zone must NOT arm, and neither must an unknown zone.
        //    Arming a group zone makes `activeController` nil, which disarms
        //    creation altogether — a worse failure than landing in the wrong place.
        // ==================================================================
        delegate.qaActivateZoneByClick(zoneG)
        try expect(runtime.qaArmedZoneId == zoneB,
                   "group zone: clicking a project-less zone must leave the arming alone; got "
                   + "\(String(describing: runtime.qaArmedZoneId))")
        try expect(runtime.setActiveZone(UUID(), reason: .click) == false,
                   "a zone this document does not contain must be refused, not armed")
        try expect(runtime.qaArmedZoneId == zoneB,
                   "unknown zone: the arming must survive a refused request")

        // ==================================================================
        // 4. Clicking a zone arms it. Focusing a tile in one arms it.
        // ==================================================================
        delegate.qaActivateZoneByClick(zoneA)
        try expect(runtime.qaArmedZoneId == zoneA,
                   "click: clicking zone A must arm it; got \(String(describing: runtime.qaArmedZoneId))")
        try expect(delegate.qaResolvedCreationScope?.projectId == projectPa,
                   "click: and creation must follow to Pa")

        delegate.qaAcceptTileFocus(spawnedNoteId, reason: .userClick)
        try expect(runtime.qaArmedZoneId == zoneB,
                   "focus: clicking into a tile must arm that tile's zone; got "
                   + "\(String(describing: runtime.qaArmedZoneId))")

        // A restore is not a user act. `switchWorkspace`'s own `restoreFocus` runs
        // through these reasons, and arming on them would let a switch's tail end
        // re-point the zone the switch had just deliberately set.
        delegate.qaActivateZoneByClick(zoneA)
        delegate.qaAcceptTileFocus(spawnedNoteId, reason: .recovery)
        try expect(runtime.qaArmedZoneId == zoneA,
                   "focus: a `.recovery` focus must NOT arm; got "
                   + "\(String(describing: runtime.qaArmedZoneId))")

        // ==================================================================
        // 5. The camera arms — through the REAL delegate chain.
        //
        // `canvas.setViewport` -> `delegate.canvasDidChange` -> the viewport-delta
        // gate -> `runtime.onViewportChanged()`. Calling `onViewportChanged()`
        // directly, as the first version of this leg did, proves the runtime method
        // works and says nothing about whether a pan ever reaches it. `delegate` is
        // assigned in `applicationDidFinishLaunching` rather than in the mount
        // seam, so the leg has to make the same assignment production does.
        // ==================================================================
        canvas.delegate = delegate

        func panCameraTo(_ centre: CGPoint) {
            canvas.setViewport(CanvasViewport(
                x: centre.x - Double(canvas.bounds.width) / 2,
                y: centre.y - Double(canvas.bounds.height) / 2,
                zoom: 1))
            runtime.flushPendingHydrationReconcile()
        }

        delegate.qaActivateZoneByClick(zoneA)
        panCameraTo(CGPoint(x: zoneRect.x + zoneRect.width / 2, y: zoneRect.y + zoneRect.height / 2))
        try expect(runtime.qaArmedZoneId == zoneB,
                   "camera: settling over Zb must arm it, and it must get there through "
                   + "canvasDidChange — a pan that never reaches the runtime arms nothing. Got "
                   + "\(String(describing: runtime.qaArmedZoneId))")

        // The zone the user is looking at is the zone as DRAWN. `liveZones` and the
        // document diverge — auto-layout grows a zone through `onZoneMoved`, which
        // updates the rendered placement while the document lags. Asking the
        // document whether the camera is inside a zone then answers about a
        // rectangle nobody can see.
        var grown = zoneBPlacement
        grown.origin = ZonePoint(x: zoneRect.x - 3000, y: zoneRect.y)
        grown.size = ZoneSize(width: zoneRect.width + 3000, height: zoneRect.height)
        canvas.setZonePlacement(grown)
        delegate.qaActivateZoneByClick(zoneA)
        panCameraTo(CGPoint(x: zoneRect.x - 1500, y: zoneRect.y + zoneRect.height / 2))
        try expect(runtime.qaArmedZoneId == zoneB,
                   "camera: must read the RENDERED zone set. This point is inside Zb as drawn "
                   + "and outside Zb as the document records it; the document answer is the one "
                   + "the user cannot see. Got \(String(describing: runtime.qaArmedZoneId))")
        canvas.setZonePlacement(zoneBPlacement)

        // Empty canvas is not a request to disarm. `nil` from `cameraArmedZone`
        // means "no answer", and a pan across the gap between zones must not
        // silently strand creation with no target.
        panCameraTo(CGPoint(x: 40_000, y: 40_000))
        try expect(runtime.qaArmedZoneId == zoneB,
                   "camera: empty canvas must leave the arming alone; got "
                   + "\(String(describing: runtime.qaArmedZoneId))")

        // Nor is a group zone.
        panCameraTo(CGPoint(x: 4000 + 450, y: 200 + 350))
        try expect(runtime.qaArmedZoneId == zoneB,
                   "camera: a group zone under the camera must leave the arming alone; got "
                   + "\(String(describing: runtime.qaArmedZoneId))")

        // ==================================================================
        // 5b. An armed zone with NO installed layer must not revert creation to
        //     the first project.
        //
        //     `setActiveProjectZone` silently no-ops without a layer, so
        //     `activeProjectZonePlacement` goes nil and the scope used to fall
        //     through to the boot `activeZone` — the FIRST zone in the workspace.
        //     That fallback was a magnet: at boot the scene is flat and no layer
        //     exists at all, and a zone below the live hydration tier has none
        //     either. Which project a new tile belongs to must not depend on
        //     whether its zone happens to be hydrated.
        // ==================================================================
        canvas.removeZoneLayer(zoneId: zoneB)
        try expect(delegate.qaResolvedCreationScope?.projectId == projectPb,
                   "no-layer: Zb is still the armed zone, so creation must still scope to Pb "
                   + "even with its layer gone. Got "
                   + "\(String(describing: delegate.qaResolvedCreationScope?.projectId)) "
                   + "— reverting to Pa here is the 'it went back to the first zone' report.")

        // ==================================================================
        // 5c. A managed agent's HOME must survive a cross-project spawn.
        //
        //     `managedAgentCreationScopes` is per-TileSpawner. A scoped spawn goes
        //     through `spawnerForFilesystemCreation()`, which is the SCOPE's
        //     project's spawner; `wireManagedAgentTile` then read the memo back off
        //     the ACTIVE controller's spawner. Different objects, so the lookup
        //     returned nil and the agent fell back to the plain active-project
        //     path — the tile in the right zone, the agent running in the first
        //     project's home directory. That is the second half of the report.
        // ==================================================================
        // The real sequence: spawn while Zb is armed (the memo lands on Pb's
        // spawner), then re-arm elsewhere, THEN wire. `attachActiveControllerUI`
        // rebuilds a fresh TileSpawner for every live controller whenever the
        // active project changes — which is now every click, focus and camera
        // settle — so a memo that lives only on a spawner instance does not
        // survive to the moment `wireManagedAgentTile` reads it.
        delegate.qaActivateZoneByClick(zoneB)
        guard let pbSpawner = runtime.controller(for: projectPb)?.tileSpawner else {
            throw Failure(message: "Pb must have a live spawner for the scope-lookup case")
        }
        let agentTileId = UUID()
        pbSpawner.qaRememberManagedAgentCreationScope(
            tileId: agentTileId,
            scope: CreationScope(
                projectId: projectPb, projectRoot: pbRoot.path,
                homeRelativePath: nil, source: .zone, zoneId: zoneB))

        // Now the user clicks back into the first zone before the agent is wired.
        delegate.qaActivateZoneByClick(zoneA)
        guard let paSpawner = runtime.controller(for: projectPa)?.tileSpawner else {
            throw Failure(message: "Pa must have a live spawner")
        }
        try expect(paSpawner !== pbSpawner,
                   "the active spawner must be a DIFFERENT object from the one that recorded "
                   + "the memo, or this case proves nothing")
        let found = runtime.managedAgentCreationScope(tileId: agentTileId)
        try expect(found?.projectId == projectPb,
                   "the runtime must find the memo on whichever live spawner created the tile. "
                   + "Got \(String(describing: found?.projectId)) — nil here is what silently "
                   + "dropped the agent into the first project's home directory.")
        try expect(found?.projectRoot == pbRoot.path,
                   "and it must carry Pb's root, which is what becomes the agent's cwd")

        // Persisted cold launch now uses the same layer model as switching, so the
        // old launch-only flat-spawn coordinate branch no longer exists. Keep the
        // layer growth invariant: moving a zone origin must not move its tiles.
        canvas.upsertZoneLayer(CanvasNSView.ZoneLayer(
            placement: zoneBPlacement,
            renderModel: CanvasNSView.ZoneRenderModel(placement: zoneBPlacement, displayName: "Pb"),
            tiles: []))
        delegate.qaActivateZoneByClick(zoneB)
        let anchorId = UUID()
        var anchor = Tile(
            id: anchorId, kind: .note, title: "anchor",
            frame: TileFrame(x: 100, y: 100, width: 200, height: 120),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(noteId: anchorId))
        anchor.zoneId = zoneB
        _ = canvas.installProjectTile(
            tileView: NoteTileNSView(tile: anchor, noteId: anchorId, initialBody: ""),
            for: anchor, targetZoneId: zoneB)
        let anchorWorldBefore = canvas.tilesInWorldFrames(forProjectId: projectPb)
            .first(where: { $0.id == anchorId })?.frame
        try expect(anchorWorldBefore != nil, "the anchor tile must be installed in Zb")

        // Force growth that pulls the origin UP-LEFT, the direction that would drag
        // every zone-local tile with it.
        let outsideRect = TileFrame(
            x: zoneRect.x - 500, y: zoneRect.y - 400, width: 240, height: 160)
        _ = canvas.growZone(zoneB, toInclude: outsideRect, notifyChange: false)
        let grownRect = CanvasEngine.zoneWorldFrame(canvas.zonePlacement(for: zoneB)!)
        try expect(grownRect.x <= outsideRect.x && grownRect.y <= outsideRect.y,
                   "grow (layer): the zone must have expanded up-left to contain the rect; got "
                   + "(\(grownRect.x), \(grownRect.y))")
        let anchorWorldAfter = canvas.tilesInWorldFrames(forProjectId: projectPb)
            .first(where: { $0.id == anchorId })?.frame
        try expect(anchorWorldAfter != nil, "the anchor must survive the growth")
        let moved = abs(anchorWorldAfter!.x - anchorWorldBefore!.x)
            + abs(anchorWorldAfter!.y - anchorWorldBefore!.y)
        try expect(moved < 0.001,
                   "grow (layer): moving a zone's ORIGIN must not move the tiles inside it. "
                   + "A layer stores zone-local frames and renders local + origin, so the "
                   + "locals have to be compensated by the same delta. Anchor was "
                   + "(\(anchorWorldBefore!.x), \(anchorWorldBefore!.y)), now "
                   + "(\(anchorWorldAfter!.x), \(anchorWorldAfter!.y)).")

        // ==================================================================
        // 6. The arming write is durable.
        // ==================================================================
        delegate.qaActivateZoneByClick(zoneB)
        runtime.flushPendingArmingSave()
        let reloaded = try WorkspaceStore(
            workspaceId: workspaceWA, applicationSupportDirectory: appSupport).load()
        try expect(reloaded.lastActiveZoneId == zoneB,
                   "persistence: the armed zone must survive a relaunch; on disk it is "
                   + "\(String(describing: reloaded.lastActiveZoneId))")

        print("ZoneArmingChecks: adding a zone armed it, a spawn landed inside that zone's world "
              + "rect, click/focus/camera all re-armed, a group zone and empty canvas left the "
              + "arming alone, and the choice persisted")
    }
}

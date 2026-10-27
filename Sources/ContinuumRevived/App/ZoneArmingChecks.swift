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
        let projectPc = UUID(uuidString: "00000000-0000-0000-0000-00000000B207")!
        let zoneC = UUID(uuidString: "00000000-0000-0000-0000-00000000B208")!
        let zoneA2 = UUID(uuidString: "00000000-0000-0000-0000-00000000B209")!

        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-zone-arming-\(UUID().uuidString)", isDirectory: true)
        let paRoot = tempRoot.appendingPathComponent("Pa", isDirectory: true)
        let pbRoot = tempRoot.appendingPathComponent("Pb", isDirectory: true)
        let pcRoot = tempRoot.appendingPathComponent("Pc", isDirectory: true)
        let appSupport = tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        for dir in [paRoot, pbRoot, pcRoot, appSupport] {
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
        let projectPcObj = makeProject(id: projectPc, name: "Pc", root: pcRoot)
        let storePa = ProjectStore(projectRoot: paRoot)
        let storePb = ProjectStore(projectRoot: pbRoot)
        let storePc = ProjectStore(projectRoot: pcRoot)

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
        try storePc.saveProject(projectPcObj)
        try storePc.saveCanvas(CanvasState(
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
                    placement(zoneG, project: nil, x: 4000, y: 200, color: "gray"),
                    // Far from every camera position below, so neither is in the
                    // live tier at mount and neither gets a layer then (section 7).
                    placement(zoneC, project: projectPc, x: -20_000, y: 200, color: "teal"),
                    placement(zoneA2, project: projectPa, x: -20_000, y: 20_000, color: "pink")],
            zoneZOrder: [zoneA, zoneG, zoneC, zoneA2],
            lastActiveZoneId: zoneA
        )
        try WorkspaceStore(workspaceId: workspaceWA, applicationSupportDirectory: appSupport).save(docA)

        var appRegistry = Registry.empty()
        appRegistry.lastActiveWorkspaceId = workspaceWA
        appRegistry.workspaces = [
            WorkspaceEntry(id: workspaceWA, name: "A", projectIds: [projectPa, projectPb, projectPc], createdAt: now, updatedAt: now)
        ]
        appRegistry.projects = [
            ProjectEntry(id: projectPa, name: "Pa", rootPath: paRoot.path, workspaceId: workspaceWA,
                         lastOpenedAt: now, pinned: false, missing: false),
            ProjectEntry(id: projectPb, name: "Pb", rootPath: pbRoot.path, workspaceId: workspaceWA,
                         lastOpenedAt: now, pinned: false, missing: false),
            ProjectEntry(id: projectPc, name: "Pc", rootPath: pcRoot.path, workspaceId: workspaceWA,
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
            if projectId == projectPc {
                return ZoneRuntimeController(projectRoot: pcRoot, projectStore: storePc, project: projectPcObj)
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
        try runtime.flushPendingArmingSave()
        let reloaded = try WorkspaceStore(
            workspaceId: workspaceWA, applicationSupportDirectory: appSupport).load()
        try expect(reloaded.lastActiveZoneId == zoneB,
                   "persistence: the armed zone must survive a relaunch; on disk it is "
                   + "\(String(describing: reloaded.lastActiveZoneId))")

        // ==================================================================
        // 7. A zone reached AFTER the mount gets a LAYER, and an agent created
        //    in it gets a RECORD.
        //
        //    The report: a second zone, an agent tile in it with a blank Home, a
        //    Home menu that opened nothing and a composer reading "Unavailable".
        //    The mount builds layers only for zones live at that moment;
        //    reaching one later acquired its controller and armed it, but built
        //    no layer, so the spawn installed into the retired flat model, whose
        //    save then refused: the tile stayed on screen and no agent was
        //    minted. 5b proved the SCOPE survives a missing layer and never
        //    spawned; this spawns, through ⌘K's own path.
        // ==================================================================
        let priorArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(priorArguments, forName: UserDefaults.argumentDomain) }
        guard let seedModel = AgentCatalogQAFixture.claude.defaultModel else {
            throw Failure(message: "the QA claude fixture has no default model to spawn on")
        }
        // In-process only: the argument domain outranks the persistent one and is
        // never written to disk.
        UserDefaults.standard.setVolatileDomain(priorArguments.merging([
            AgentHarnessConfig.key: AgentHarness.claudeCode.rawValue,
            AgentModelConfig.modelKey: seedModel,
            AgentModelConfig.thinkingKey: "high",
        ]) { _, new in new }, forName: UserDefaults.argumentDomain)
        AgentModelCatalog.shared.apply(readiness: .ready, for: .claudeCode)
        let agentStoreRoot = tempRoot.appendingPathComponent("Agents", isDirectory: true)
        delegate.agentSupervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: agentStoreRoot),
            makeRunner: { _ in ScriptedAgentRunner(script: []) })

        func spawnAgentThroughPalette(into zoneId: UUID, project: UUID, root: URL,
                                      store: ProjectStore, route: String) throws {
            try expect(delegate.qaResolvedCreationScope?.zoneId == zoneId,
                       "\(route): creation must scope to the zone just reached; got "
                       + "\(String(describing: delegate.qaResolvedCreationScope?.zoneId))")
            let before = Set(canvas.allWorkspaceTiles().map(\.id))
            let modelApplied = delegate.qaPerformPaletteAction(.newManagedAgent)
            canvas.layoutSubtreeIfNeeded()
            let spawned = Set(canvas.allWorkspaceTiles().map(\.id)).subtracting(before)
            guard let tileId = spawned.first, spawned.count == 1 else {
                throw Failure(message: "\(route): expected exactly one new tile from ⌘K New Agent; got \(spawned.count)")
            }
            try expect(canvas.installedZonePlacement(for: zoneId) != nil,
                       "\(route): the zone has no LAYER after a spawn into it. Its controller was "
                       + "acquired and it armed, so creation scoped to it, but the tile fell "
                       + "through to the retired flat model")
            try expect(modelApplied, "\(route): ⌘K New Agent must report its model applied to the record")
            try expect(canvas.tileView(for: tileId) is ManagedAgentTileNSView,
                       "\(route): the agent tile must be findable by `tileView(for:)`; a tile in "
                       + "the retired flat model is drawn but invisible to it")
            guard let agentId = delegate.agentSupervisor.agent(forTile: tileId),
                  let record = delegate.agentSupervisor.records[agentId] else {
                throw Failure(message: "\(route): THE reported bug. The tile is on screen and no agent "
                              + "record is bound to it, so its Home is blank, the Home menu opens "
                              + "nothing and the composer says Unavailable")
            }
            try expect(record.projectId == project,
                       "\(route): the agent must belong to the zone's project; got "
                       + "\(String(describing: record.projectId))")
            try expect(URL(fileURLWithPath: record.cwd).resolvingSymlinksInPath().path
                       == root.resolvingSymlinksInPath().path,
                       "\(route): the agent's Home must be the zone's project root; got \(record.cwd)")
            try expect(delegate.agentSupervisor.locationSnapshot(for: agentId) != nil,
                       "\(route): the Home menu reads the location snapshot; nil opens nothing")
            guard let persisted = try store.loadCanvas().tiles.first(where: { $0.id == tileId }) else {
                throw Failure(message: "\(route): the agent tile was not persisted into its project's canvas")
            }
            try expect(persisted.zoneId == zoneId,
                       "\(route): the persisted tile must name its zone; got \(String(describing: persisted.zoneId))")
            try expect(canvas.tilesInWorldFrames(forZoneId: zoneId)?.first(where: { $0.id == tileId })?.frame
                       == persisted.frame,
                       "\(route): canvas.json must hold the WORLD frame the tile is drawn at")
            guard let zonePlacement = canvas.zonePlacement(for: zoneId) else {
                throw Failure(message: "\(route): the zone vanished from the canvas")
            }
            let rect = CanvasEngine.zoneWorldFrame(zonePlacement)
            try expect(persisted.frame.x >= rect.x - 0.001 && persisted.frame.y >= rect.y - 0.001
                       && persisted.frame.x <= rect.x + rect.width + 0.001
                       && persisted.frame.y <= rect.y + rect.height + 0.001,
                       "\(route): the persisted WORLD frame (\(persisted.frame.x), \(persisted.frame.y)) "
                       + "must sit inside the zone (\(rect.x), \(rect.y)) \(rect.width)x\(rect.height)")
        }

        // Positive control: both zones really are layerless here, or 7 tests nothing.
        try expect(canvas.installedZonePlacement(for: zoneC) == nil
                   && canvas.installedZonePlacement(for: zoneA2) == nil,
                   "fixture: Zc and Za2 must be below the live tier until reached")

        // 7a. The camera: the real delegate chain into `reconcileHydration`, for a
        //     project nothing has acquired yet.
        panCameraTo(CGPoint(x: -20_000 + 450, y: 200 + 350))
        try expect(runtime.qaArmedZoneId == zoneC,
                   "camera: settling over Zc must arm it; got \(String(describing: runtime.qaArmedZoneId))")
        try spawnAgentThroughPalette(into: zoneC, project: projectPc, root: pcRoot, store: storePc,
                                     route: "camera")

        // 7b. A click, with no camera settle, for a second zone of a project whose
        //     controller already exists. Arming builds no layer (a relaunch could
        //     not reproduce one); the spawn must.
        delegate.qaActivateZoneByClick(zoneA2)
        try expect(runtime.qaArmedZoneId == zoneA2,
                   "click: clicking Za2 must arm it; got \(String(describing: runtime.qaArmedZoneId))")
        try spawnAgentThroughPalette(into: zoneA2, project: projectPa, root: paRoot, store: storePa,
                                     route: "click")

        print("ZoneArmingChecks: adding a zone armed it, a spawn landed inside that zone's world "
              + "rect, click/focus/camera all re-armed, a group zone and empty canvas left the "
              + "arming alone, the choice persisted, and a zone reached after the mount got a "
              + "layer and its agent a record")

        try runDrawnZoneSpawns()
        try runAutoLayoutSpawnsNeverOverlap()
        try runGrowthPushesNeighbours()
        try runSpawnFollowsCamera()
        try runCloseTightensZone()
    }

    // MARK: - 8. A zone the user DRAWS is a zone they can create into

    /// The marquee route: draw a zone on empty canvas, pick a project in the
    /// Home picker, then ⌘K a Board and an Agent.
    ///
    /// **The defect.** `WorkspaceRuntime.commitCreatedZone` wrote the zone into
    /// the document and set `lastActiveZoneId` directly. It never went through
    /// `setActiveZone`, so the canvas kept the old armed zone and nothing acquired
    /// the project's controller; and it never installed a `ZoneLayer`, so the
    /// zone had nowhere for tiles to live. The first spawn opened the project
    /// picker again (no spawner) or landed in the previously armed zone, and a
    /// forced spawn fell to the retired flat scene. "Add Project to Canvas…"
    /// (`_addProjectZone`) never had this bug — it builds and installs the layer.
    ///
    /// Two shapes, because they fail differently: a registered project with no
    /// zone anywhere (no controller), and a SECOND zone for a project that is
    /// already placed (controller live, but no layer for the new zone).
    ///
    /// Shared invariants fixture: `mountWorkspaceSceneAtBoot` and launch's own
    /// `wireCanvasCallbacks`, so the provisional zone reaches the real
    /// `presentProjectHomePicker` → `commitProvisionalZone` → `onZoneCreated`.
    private static func runDrawnZoneSpawns() throws {
        typealias Fixture = WorkspaceInvariantsFixture
        let fixture = try Fixture(label: "drawn-zone")
        defer { fixture.dispose() }

        // A registered project placed in no workspace: the picker offers it and
        // nothing has acquired it.
        let projectElm = UUID(uuidString: "00000000-0000-0000-0000-00000000B2E1")!
        let elmRoot = fixture.root.appendingPathComponent("Elm", isDirectory: true)
        try FileManager.default.createDirectory(at: elmRoot, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        try ProjectStore(projectRoot: elmRoot).saveProject(Project(
            id: projectElm, name: "Elm", rootPath: elmRoot.path, createdAt: now, updatedAt: now,
            defaultLaunchProfileId: "shell", editorPreference: .auto,
            settings: ProjectSettings(
                restorePolicy: .restoreDescriptors,
                browserStoragePolicy: .perProject,
                terminalClosePolicy: .askWhenRunning)))
        var registry = try fixture.registryStore.loadOrEmpty()
        registry.projects.append(ProjectEntry(
            id: projectElm, name: "Elm", rootPath: elmRoot.path, workspaceId: nil,
            lastOpenedAt: now, pinned: false, missing: false))
        try fixture.registryStore.save(registry)

        // ⌘K "New Agent" needs a ready harness with a catalogued model. Volatile
        // argument domain: read first by every `UserDefaults.standard` lookup,
        // never persisted.
        AgentModelCatalog.shared.resetForQA(snapshot: AgentHarnessCatalogSnapshot(
            harness: .pi, readiness: .ready, models: AgentCatalogQAFixture.pi))
        let savedArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = savedArguments
        arguments[AgentHarnessConfig.key] = AgentHarness.pi.rawValue
        arguments[AgentModelConfig.modelKey] = AgentCatalogQAFixture.pi[0]
        arguments[AgentModelConfig.thinkingKey] = AgentModelConfig.defaultThinking
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer {
            UserDefaults.standard.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain)
            AgentModelCatalog.shared.resetForQA()
        }

        try fixture.mount()
        let m = try fixture.requireMounted("drawn-zone")
        defer { m.delegate.qaAgentSupervisor.stopAll() }

        // Any request for the creation-scope picker is the "picker opened again"
        // half of the report. Counted, never presented.
        var pickerRequests = 0
        m.delegate.creationScopePickerPresenterForQA = { _ in pickerRequests += 1 }

        /// Draw on empty canvas and confirm `project` through the picker's row.
        func drawZone(_ label: String, screenRect: CGRect, project: UUID) throws -> UUID {
            let zoneId = m.canvas.beginProvisionalZone(screenRect: screenRect)
            try expect(m.delegate.qaConfirmProjectHomePicker(projectId: project, homeRelativePath: nil),
                       "\(label): drawing a zone presented no Home picker offering the project")
            m.canvas.layoutSubtreeIfNeeded()
            try expect(m.runtime.document.zones.contains { $0.zoneId == zoneId && $0.projectId == project },
                       "\(label): the confirmed zone must be in the document, bound to its project")
            try expect(m.runtime.qaArmedZoneId == zoneId,
                       "\(label): the document must arm the zone just drawn; got "
                       + "\(String(describing: m.runtime.qaArmedZoneId))")
            try expect(m.canvas.armedZoneId == zoneId,
                       "\(label): the CANVAS must arm the zone just drawn — it is what the creation "
                       + "scope and every placement read. `commitCreatedZone` wrote only "
                       + "`document.lastActiveZoneId`, bypassing `setActiveZone`. Got "
                       + "\(String(describing: m.canvas.armedZoneId))")
            try expect(m.canvas.installedZoneLayerIds.contains(zoneId),
                       "\(label): the zone must have a ZoneLayer, or a spawn into it falls to the "
                       + "retired flat scene; installed: \(m.canvas.installedZoneLayerIds)")
            try expect(m.runtime.controller(for: project)?.tileSpawner != nil,
                       "\(label): the project's controller and spawner must be ready, or the first "
                       + "spawn re-opens the project picker")
            let scope = m.delegate.qaResolvedCreationScope
            try expect(scope?.projectId == project && scope?.zoneId == zoneId,
                       "\(label): creation must scope to the drawn zone and its project; got "
                       + "\(String(describing: scope))")
            return zoneId
        }

        /// One ⌘K action; returns the one tile it created, from either model.
        func spawn(_ label: String, _ action: LaunchPaletteAction) throws -> UUID {
            let before = Set(m.canvas.allTilesInWorldFrames().map(\.id))
            let picksBefore = pickerRequests
            _ = m.delegate.qaPerformPaletteAction(action)
            m.canvas.layoutSubtreeIfNeeded()
            try expect(pickerRequests == picksBefore,
                       "\(label): the spawn asked for a project again (\(pickerRequests - picksBefore) "
                       + "picker request(s)) — the project was chosen when the zone was drawn")
            let created = Set(m.canvas.allTilesInWorldFrames().map(\.id)).subtracting(before)
            guard created.count == 1, let tileId = created.first else {
                throw Failure(message: "\(label): expected exactly one new installed tile; got \(created.count)")
            }
            return tileId
        }

        /// The tile's WORLD frame lies inside the zone as drawn.
        func expectInside(_ label: String, _ tileId: UUID, zone zoneId: UUID) throws {
            try expect(m.canvas.qaZoneMembership(of: tileId) == zoneId,
                       "\(label): the tile must belong to the drawn zone; got "
                       + "\(String(describing: m.canvas.qaZoneMembership(of: tileId)))")
            guard let frame = m.canvas.allTilesInWorldFrames().first(where: { $0.id == tileId })?.frame,
                  let zone = m.canvas.qaLiveZonePlacement(zoneId) else {
                throw Failure(message: "\(label): could not read the tile's world frame or the zone")
            }
            let rect = CanvasEngine.zoneWorldFrame(zone)
            try expect(frame.x >= rect.x - 0.001 && frame.y >= rect.y - 0.001
                       && frame.x + frame.width <= rect.x + rect.width + 0.001
                       && frame.y + frame.height <= rect.y + rect.height + 0.001,
                       "\(label): world frame (\(frame.x), \(frame.y)) \(frame.width)x\(frame.height) "
                       + "is not inside the drawn zone (\(rect.x), \(rect.y)) \(rect.width)x\(rect.height)")
        }

        // Case 1: a registered project with no zone anywhere. World
        // (1600, 1010)+1200x700 — clear of every seeded zone (A2 ends at y 960,
        // A3 at x 1500) under the seeded camera (300, -100).
        let elmZone = try drawZone("unplaced project", screenRect: CGRect(x: 1300, y: 1110, width: 1200, height: 700),
                                   project: projectElm)
        // A board takes the zone's name once the user has named it.
        m.canvas.qaRenameZone(elmZone, to: "Elm site")
        let elmBoard = try spawn("unplaced project: board", .newBoard)
        try expectInside("unplaced project: board", elmBoard, zone: elmZone)
        let elmBoardTitle = m.canvas.allTilesInWorldFrames().first(where: { $0.id == elmBoard })?.title
        try expect(elmBoardTitle == "Elm site",
                   "unplaced project: a board made in the zone named \"Elm site\" must take that name; got "
                   + "\(String(describing: elmBoardTitle))")
        let elmAgent = try spawn("unplaced project: agent", .newManagedAgent)
        try expectInside("unplaced project: agent", elmAgent, zone: elmZone)
        let supervisor = m.delegate.qaAgentSupervisor
        guard let agentId = supervisor.agent(forTile: elmAgent), let record = supervisor.records[agentId] else {
            throw Failure(message: "unplaced project: the agent tile has no agent record")
        }
        try expect(record.projectId == projectElm,
                   "unplaced project: the agent must belong to Elm; got \(String(describing: record.projectId))")

        // Case 2: a SECOND zone for a project already placed (Birch owns A2).
        // World (2800, 200)+1000x800, right of everything.
        let birchZone = try drawZone("placed project", screenRect: CGRect(x: 2500, y: 300, width: 1000, height: 800),
                                     project: Fixture.projectA2)
        let birchBoard = try spawn("placed project: board", .newBoard)
        try expectInside("placed project: board", birchBoard, zone: birchZone)
        // Birch's second zone is unnamed, so it shows the project's name and the board takes it.
        let birchBoardTitle = m.canvas.allTilesInWorldFrames().first(where: { $0.id == birchBoard })?.title
        let birchZoneTitle = m.canvas.qaZoneDisplayName(birchZone) ?? ""
        try expect(birchBoardTitle == AppDelegate.boardTitle(forZoneTitle: birchZoneTitle),
                   "placed project: the board must be titled after the zone header \"\(birchZoneTitle)\"; got "
                   + "\(String(describing: birchBoardTitle))")
        try expect(AppDelegate.boardTitle(forZoneTitle: "Zone 3") == "New Board"
                   && AppDelegate.boardTitle(forZoneTitle: "Group") == "New Board",
                   "an automatically named zone must give \"New Board\"")

        // Durable: each tile in its own project's canvas, stamped with the
        // drawn zone, at the frame on screen; and the zones in the workspace file.
        try m.runtime.flushMountedWorkspaceState()
        fixture.drain()
        func expectPersisted(_ label: String, _ tileId: UUID, root: URL, zone zoneId: UUID) throws {
            let persisted = ((try? ProjectStore(projectRoot: root).tryLoadCanvas()) ?? nil)?.tiles ?? []
            guard let tile = persisted.first(where: { $0.id == tileId }) else {
                throw Failure(message: "\(label): the tile is not in its project's canvas.json "
                              + "(\(persisted.count) tile(s) there)")
            }
            try expect(tile.zoneId == zoneId,
                       "\(label): persisted with zone \(String(describing: tile.zoneId)), expected the drawn zone")
            if let live = m.canvas.allTilesInWorldFrames().first(where: { $0.id == tileId })?.frame {
                try expect(abs(live.x - tile.frame.x) + abs(live.y - tile.frame.y) < 0.001,
                           "\(label): persisted frame (\(tile.frame.x), \(tile.frame.y)) is not the WORLD "
                           + "frame on screen (\(live.x), \(live.y))")
            }
        }
        try expectPersisted("unplaced project: board", elmBoard, root: elmRoot, zone: elmZone)
        try expectPersisted("unplaced project: agent", elmAgent, root: elmRoot, zone: elmZone)
        try expectPersisted("placed project: board", birchBoard,
                            root: fixture.projectRoots[Fixture.projectA2]!, zone: birchZone)
        for other in [Fixture.projectA1] {
            let tiles = ((try? ProjectStore(projectRoot: fixture.projectRoots[other]!).tryLoadCanvas()) ?? nil)?.tiles ?? []
            try expect(!tiles.contains { [elmBoard, elmAgent, birchBoard].contains($0.id) },
                       "a drawn zone's tile leaked into another project's canvas")
        }
        let onDisk = try fixture.readWorkspaceFile(Fixture.workspaceA).document
        try expect(onDisk?.zones.contains { $0.zoneId == elmZone && $0.projectId == projectElm } == true
                   && onDisk?.zones.contains { $0.zoneId == birchZone && $0.projectId == Fixture.projectA2 } == true,
                   "both drawn zones must be in workspace A's file, bound to their projects")

        print("ZoneArmingChecks: a drawn zone for an unplaced project and a second drawn zone for a "
              + "placed one each armed, got a layer and a spawner; ⌘K Board and Agent landed inside "
              + "them with no second picker and persisted into their own project")
    }

    // MARK: - 9. Under auto layout, a spawn never lands on a sibling

    /// The film capture `full-day-20261005T175103Z` (take 01-morning): with global
    /// auto layout on, a drawn zone holding a Board and an Agent side by side took a
    /// second Agent from ⌘K ON TOP of the board, and it stayed there.
    ///
    /// **The defect.** Automatic placement ranks "on screen" above "free", so with
    /// the camera framing the zone tightly every free dock candidate was off screen
    /// and the new tile was placed overlapping the board. Inside the zone, so the
    /// zone did not grow. `arrangeAutoLayoutAfterSpawn` then settled with no mover:
    /// the new tile, being top-most, seeded the cluster, and the board found no
    /// gap-contact slot inside a zone too small for three tiles — `absorb` leaves
    /// such a tile where it is, overlapping. Under a looser camera the placement
    /// happened to choose a free slot below, which is why an earlier capture of the
    /// same scene was fine.
    ///
    /// Drives the production ⌘K path (`qaPerformPaletteAction`) with auto layout ON
    /// in the volatile argument domain, under several camera framings, and asserts
    /// world geometry: no two members of the zone overlap and each lies inside the
    /// (grown) zone, after every spawn.
    private static func runAutoLayoutSpawnsNeverOverlap() throws {
        typealias Fixture = WorkspaceInvariantsFixture
        AgentModelCatalog.shared.resetForQA(snapshot: AgentHarnessCatalogSnapshot(
            harness: .pi, readiness: .ready, models: AgentCatalogQAFixture.pi))
        let savedArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = savedArguments
        arguments[AgentHarnessConfig.key] = AgentHarness.pi.rawValue
        arguments[AgentModelConfig.modelKey] = AgentCatalogQAFixture.pi[0]
        arguments[AgentModelConfig.thinkingKey] = AgentModelConfig.defaultThinking
        arguments[CanvasAutoLayoutConfig.enabledKey] = true
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer {
            UserDefaults.standard.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain)
            AgentModelCatalog.shared.resetForQA()
        }

        /// The drawn zone, in screen points under the seeded camera (300, -100, 1):
        /// world (1600, 1010) + 1750x810 — room for two tiles side by side, not three.
        let drawnRect = CGRect(x: 1300, y: 1110, width: 1750, height: 810)
        enum Framing: String, CaseIterable {
            /// The film: the camera frames the whole zone, edge to edge.
            case framesZone = "camera framing the zone"
            /// The camera as it was when the zone was drawn (zone partly visible).
            case asDrawn = "camera as drawn"
            /// Zoomed far out: every dock candidate is on screen.
            case zoomedOut = "camera zoomed out"
            /// The capture verbatim: its 1619x1048 canvas, its zone, and its two
            /// cameras — the one the Board and Agent were made under, then the
            /// re-framed one the second Agent was made under.
            case film = "the film's cameras"
        }
        let filmDrawCamera = CanvasViewport(x: 1480.1136363636365, y: -125.4545454545455, zoom: 0.88)
        let filmSpawnCamera = CanvasViewport(x: 1674.4639376218324, y: -161.52241715399612, zoom: 0.8784246575342466)

        for framing in Framing.allCases {
            let fixture = try Fixture(label: "autolayout-spawn")
            defer { fixture.dispose() }
            let projectElm = UUID(uuidString: "00000000-0000-0000-0000-00000000B2E2")!
            let elmRoot = fixture.root.appendingPathComponent("Elm", isDirectory: true)
            try FileManager.default.createDirectory(at: elmRoot, withIntermediateDirectories: true)
            let now = Date(timeIntervalSince1970: 1_900_000_000)
            try ProjectStore(projectRoot: elmRoot).saveProject(Project(
                id: projectElm, name: "Elm", rootPath: elmRoot.path, createdAt: now, updatedAt: now,
                defaultLaunchProfileId: "shell", editorPreference: .auto,
                settings: ProjectSettings(
                    restorePolicy: .restoreDescriptors,
                    browserStoragePolicy: .perProject,
                    terminalClosePolicy: .askWhenRunning)))
            var registry = try fixture.registryStore.loadOrEmpty()
            registry.projects.append(ProjectEntry(
                id: projectElm, name: "Elm", rootPath: elmRoot.path, workspaceId: nil,
                lastOpenedAt: now, pinned: false, missing: false))
            try fixture.registryStore.save(registry)

            try fixture.mount()
            let m = try fixture.requireMounted("autolayout-spawn")
            defer { m.delegate.qaAgentSupervisor.stopAll() }
            m.delegate.creationScopePickerPresenterForQA = { _ in }
            let label = framing.rawValue
            try expect(m.canvas.isAutoLayoutEnabled, "\(label): auto layout must be ON for this witness")

            var screenRect = drawnRect
            if framing == .film {
                m.canvas.frame = CGRect(x: 0, y: 0, width: 1619, height: 1048)
                m.canvas.setViewport(filmDrawCamera)
                // The capture's zone origin AS PERSISTED, float dust included: a real
                // pointer drag lands world coordinates off the integer grid, and that
                // dust is what makes an upward grow unrepresentable (see the fix).
                let topLeft = CanvasEngine.worldToScreen(
                    CGPoint(x: 1720, y: 30.00000000000003), viewport: filmDrawCamera)
                let bottomRight = CanvasEngine.worldToScreen(CGPoint(x: 2880, y: 840), viewport: filmDrawCamera)
                screenRect = CGRect(x: topLeft.x, y: topLeft.y,
                                    width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
            }
            let zoneId = m.canvas.beginProvisionalZone(screenRect: screenRect)
            try expect(m.delegate.qaConfirmProjectHomePicker(projectId: projectElm, homeRelativePath: nil),
                       "\(label): drawing a zone presented no Home picker offering the project")
            m.canvas.layoutSubtreeIfNeeded()
            try expect(m.canvas.armedZoneId == zoneId, "\(label): the drawn zone must be armed")

            func zoneRect() throws -> TileFrame {
                guard let zone = m.canvas.qaLiveZonePlacement(zoneId) else {
                    throw Failure(message: "\(label): the drawn zone vanished")
                }
                return CanvasEngine.zoneWorldFrame(zone)
            }
            func frameZone() throws {
                let rect = try zoneRect()
                let size = m.canvas.bounds.size
                let zoom = min(Double(size.width) / rect.width, Double(size.height) / rect.height)
                m.canvas.setViewport(CanvasViewport(
                    x: rect.x + rect.width / 2 - Double(size.width) / zoom / 2,
                    y: rect.y + rect.height / 2 - Double(size.height) / zoom / 2,
                    zoom: zoom))
                m.canvas.layoutSubtreeIfNeeded()
            }
            switch framing {
            case .framesZone: try frameZone()
            case .asDrawn, .film: break
            case .zoomedOut:
                let rect = try zoneRect()
                m.canvas.setViewport(CanvasViewport(x: rect.x - 2600, y: rect.y - 1400, zoom: 0.4))
                m.canvas.layoutSubtreeIfNeeded()
            }

            // Every OTHER zone, and how much the drawn zone overlaps it as drawn.
            // Growth may never add to that: it pushes the neighbour away (§10), and a
            // zone that grew across its neighbour stole the neighbour's clicks (capture
            // `full-day-20261005T175740Z`: a click "in Roast API" armed Storefront
            // and an agent landed in the wrong project).
            func overlapArea(_ a: TileFrame, _ b: TileFrame) -> Double {
                max(0, min(a.x + a.width, b.x + b.width) - max(a.x, b.x))
                    * max(0, min(a.y + a.height, b.y + b.height) - max(a.y, b.y))
            }
            let drawn = try zoneRect()
            var drawnOverlap: [UUID: Double] = [:]
            for zone in m.runtime.document.zones where zone.zoneId != zoneId {
                guard let other = m.canvas.qaLiveZonePlacement(zone.zoneId) else { continue }
                drawnOverlap[zone.zoneId] = overlapArea(drawn, CanvasEngine.zoneWorldFrame(other))
            }
            try expect(!drawnOverlap.isEmpty, "\(label): the fixture must have neighbouring zones")

            var spawned: [UUID] = []
            for (step, action) in [("board", LaunchPaletteAction.newBoard),
                                   ("agent", .newManagedAgent), ("second agent", .newManagedAgent)] {
                if framing == .film, step == "second agent" {
                    m.canvas.setViewport(filmSpawnCamera)
                    m.canvas.layoutSubtreeIfNeeded()
                }
                let before = Set(m.canvas.allTilesInWorldFrames().map(\.id))
                _ = m.delegate.qaPerformPaletteAction(action)
                m.canvas.layoutSubtreeIfNeeded()
                let created = Set(m.canvas.allTilesInWorldFrames().map(\.id)).subtracting(before)
                guard created.count == 1, let tileId = created.first else {
                    throw Failure(message: "\(label): ⌘K \(step) created \(created.count) tile(s), expected one")
                }
                spawned.append(tileId)
                let rect = try zoneRect()
                let members = m.canvas.allTilesInWorldFrames().filter {
                    m.canvas.qaZoneMembership(of: $0.id) == zoneId
                }
                try expect(Set(spawned).isSubset(of: Set(members.map(\.id))),
                           "\(label): after the \(step), every spawned tile must belong to the drawn zone")
                func describe(_ f: TileFrame) -> String { "(\(f.x), \(f.y)) \(f.width)x\(f.height)" }
                for member in members {
                    let f = member.frame
                    try expect(f.x >= rect.x - 0.001 && f.y >= rect.y - 0.001
                               && f.x + f.width <= rect.x + rect.width + 0.001
                               && f.y + f.height <= rect.y + rect.height + 0.001,
                               "\(label): after the \(step), \(member.kind) \(describe(f)) is not inside the "
                               + "zone \(describe(rect))")
                }
                for (index, a) in members.enumerated() {
                    for b in members.dropFirst(index + 1) {
                        let overlap = a.frame.x < b.frame.x + b.frame.width - 0.001
                            && b.frame.x < a.frame.x + a.frame.width - 0.001
                            && a.frame.y < b.frame.y + b.frame.height - 0.001
                            && b.frame.y < a.frame.y + a.frame.height - 0.001
                        try expect(!overlap,
                                   "\(label): after the \(step), \(a.kind) \(describe(a.frame)) overlaps "
                                   + "\(b.kind) \(describe(b.frame)) in an auto-layout zone")
                    }
                }
                for (id, before) in drawnOverlap {
                    guard let other = m.canvas.qaLiveZonePlacement(id) else { continue }
                    let otherRect = CanvasEngine.zoneWorldFrame(other)
                    try expect(overlapArea(rect, otherRect) <= before + 0.001,
                               "\(label): after the \(step), the zone \(describe(rect)) grew across the "
                               + "neighbouring zone \(describe(otherRect))")
                }
                // The film re-framed the zone between spawns; so does this framing.
                if framing == .framesZone { try frameZone() }
            }
        }

        print("ZoneArmingChecks: under auto layout, ⌘K Board, Agent, Agent in a drawn zone never "
              + "overlapped, stayed inside the zone, and never grew it across a neighbouring zone, "
              + "under every camera framing")
    }

    // MARK: - 10. A zone that grows pushes the neighbour it runs into

    /// Dylan, 2026-10-05: "push neighbour… new takes prio". A spawn into a full
    /// auto-layout zone docks the tile past the zone's edge, on whichever side the
    /// camera is looking (§10b), and the zone grows to hold it. When that growth runs into another zone, the
    /// zone that grew keeps its place and the neighbour moves away, with its
    /// tiles, as a dragged zone pushes. Before this, the growth either avoided
    /// the neighbour or, boxed in on both sides as here, ran straight across it.
    ///
    /// Fixture: Roots (900x700, three tiles) has Birch 200 pt to its right and
    /// Annex 100 pt below. A new Agent fits in neither gap.
    private static func runGrowthPushesNeighbours() throws {
        typealias Fixture = WorkspaceInvariantsFixture
        AgentModelCatalog.shared.resetForQA(snapshot: AgentHarnessCatalogSnapshot(
            harness: .pi, readiness: .ready, models: AgentCatalogQAFixture.pi))
        let savedArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = savedArguments
        arguments[AgentHarnessConfig.key] = AgentHarness.pi.rawValue
        arguments[AgentModelConfig.modelKey] = AgentCatalogQAFixture.pi[0]
        arguments[AgentModelConfig.thinkingKey] = AgentModelConfig.defaultThinking
        arguments[CanvasAutoLayoutConfig.enabledKey] = true
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer {
            UserDefaults.standard.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain)
            AgentModelCatalog.shared.resetForQA()
        }

        let fixture = try Fixture(label: "growth-push")
        defer { fixture.dispose() }
        try fixture.mount()
        let m = try fixture.requireMounted("growth-push")
        defer { m.delegate.qaAgentSupervisor.stopAll() }
        try expect(m.canvas.isAutoLayoutEnabled, "growth push: auto layout must be ON for this witness")

        let roots = Fixture.zoneA1
        let neighbours = [Fixture.zoneA2, Fixture.zoneA3]
        func rect(_ id: UUID) throws -> TileFrame {
            guard let zone = m.canvas.qaLiveZonePlacement(id) else {
                throw Failure(message: "growth push: zone \(id) vanished")
            }
            return CanvasEngine.zoneWorldFrame(zone)
        }
        func describe(_ f: TileFrame) -> String { "(\(f.x), \(f.y)) \(f.width)x\(f.height)" }
        func overlaps(_ a: TileFrame, _ b: TileFrame) -> Bool {
            a.x < b.x + b.width - 0.001 && b.x < a.x + a.width - 0.001
                && a.y < b.y + b.height - 0.001 && b.y < a.y + a.height - 0.001
        }
        func members(_ id: UUID) -> [UUID: TileFrame] {
            Dictionary(m.canvas.allTilesInWorldFrames()
                .filter { m.canvas.qaZoneMembership(of: $0.id) == id }
                .map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        }

        let rootsBefore = try rect(roots)
        var neighbourBefore: [UUID: (rect: TileFrame, members: [UUID: TileFrame])] = [:]
        for id in neighbours { neighbourBefore[id] = (try rect(id), members(id)) }
        for id in neighbours {
            try expect(!overlaps(rootsBefore, neighbourBefore[id]!.rect),
                       "growth push: the fixture's zones must start apart")
        }

        try expect(m.runtime.setActiveZone(roots, reason: .click), "growth push: Roots must arm")
        let before = Set(m.canvas.allTilesInWorldFrames().map(\.id))
        _ = m.delegate.qaPerformPaletteAction(.newManagedAgent)
        m.canvas.layoutSubtreeIfNeeded()
        let created = Set(m.canvas.allTilesInWorldFrames().map(\.id)).subtracting(before)
        try expect(created.count == 1, "growth push: ⌘K Agent created \(created.count) tile(s), expected one")

        let rootsAfter = try rect(roots)
        func contains(_ outer: TileFrame, _ inner: TileFrame) -> Bool {
            inner.x >= outer.x - 0.001 && inner.y >= outer.y - 0.001
                && inner.x + inner.width <= outer.x + outer.width + 0.001
                && inner.y + inner.height <= outer.y + outer.height + 0.001
        }
        try expect(contains(rootsAfter, rootsBefore) && rootsAfter != rootsBefore,
                   "growth push: Roots \(describe(rootsBefore)) had no room for the Agent and must have grown, "
                   + "never shrunk or moved; got \(describe(rootsAfter))")
        guard let agent = members(roots)[created.first!] else {
            throw Failure(message: "growth push: the Agent must belong to Roots")
        }
        try expect(contains(rootsAfter, agent),
                   "growth push: Roots \(describe(rootsAfter)) must have grown around the Agent \(describe(agent))")

        var pushed = 0
        for id in neighbours {
            let after = try rect(id)
            try expect(!overlaps(rootsAfter, after),
                       "growth push: Roots grew to \(describe(rootsAfter)) across its neighbour \(describe(after))")
            let (old, oldMembers) = neighbourBefore[id]!
            let dx = after.x - old.x, dy = after.y - old.y
            if dx != 0 || dy != 0 { pushed += 1 }
            try expect(after.width == old.width && after.height == old.height,
                       "growth push: a pushed neighbour moves, it never resizes; \(describe(old)) → \(describe(after))")
            for (tile, frame) in members(id) {
                guard let was = oldMembers[tile] else { continue }
                try expect(abs(frame.x - was.x - dx) < 0.001 && abs(frame.y - was.y - dy) < 0.001,
                           "growth push: a pushed zone's tile must move with it by (\(dx), \(dy)); "
                           + "\(describe(was)) → \(describe(frame))")
            }
        }
        try expect(pushed >= 1, "growth push: Roots grew into a neighbour, so one of them must have moved")

        print("ZoneArmingChecks: a zone that grew to take a new Agent pushed the neighbour it ran "
              + "into, tiles and all, so no two zones overlap")
    }

    // MARK: - 10b. A spawn lands where the camera is looking

    /// Dylan, 2026-10-26: new tiles used to land "in the center of where you were
    /// looking, or at least, try and squeeze around the existing layout". 0.7.30
    /// lost that under auto layout: the placement was clamped into the zone, and
    /// the post-spawn settle re-docked the tile at the nearest slot to the RIGHT
    /// or BELOW the zone, because the zone could only grow that way. With the
    /// camera on the left of a full zone, the Agent went to the far edge, off
    /// screen.
    ///
    /// Roots is reseeded as a full row, `A | B | file`, hugged by its zone and
    /// clear of every other zone, on a 1600x1000 canvas. Three legs drive ⌘K Agent:
    ///  - full: camera centred on A at zoom 1. The only free slot on screen is
    ///    left of the zone, so the zone has to grow left.
    ///  - dust: the same, with the zone's origin one ULP off 100. Growing left then
    ///    has no bit-exact origin for the members (a tile near x 124 gets a local x
    ///    near 784, a coarser binade), the case that made 0.7.30 grow right/down only.
    ///  - room: a large zone with the same row at its top, camera on the empty
    ///    space below it.
    /// After the spawn: the Agent is at least half on screen and gap-adjacent to a
    /// member, no two members overlap, every member is inside the zone, the zone
    /// overlaps no other zone, and the members that were there did not move (by
    /// less than the 1/64 pt the dust leg is allowed to round them by).
    private static func runSpawnFollowsCamera() throws {
        typealias Fixture = WorkspaceInvariantsFixture
        AgentModelCatalog.shared.resetForQA(snapshot: AgentHarnessCatalogSnapshot(
            harness: .pi, readiness: .ready, models: AgentCatalogQAFixture.pi))
        let savedArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = savedArguments
        arguments[AgentHarnessConfig.key] = AgentHarness.pi.rawValue
        arguments[AgentModelConfig.modelKey] = AgentCatalogQAFixture.pi[0]
        arguments[AgentModelConfig.thinkingKey] = AgentModelConfig.defaultThinking
        arguments[CanvasAutoLayoutConfig.enabledKey] = true
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer {
            UserDefaults.standard.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain)
            AgentModelCatalog.shared.resetForQA()
        }

        enum Leg: String, CaseIterable {
            case full = "full zone"
            case dust = "full zone with float dust"
            case room = "zone with room"
        }
        func describe(_ f: TileFrame) -> String { "(\(f.x), \(f.y)) \(f.width)x\(f.height)" }
        func overlaps(_ a: TileFrame, _ b: TileFrame) -> Bool {
            a.x < b.x + b.width - 0.001 && b.x < a.x + a.width - 0.001
                && a.y < b.y + b.height - 0.001 && b.y < a.y + a.height - 0.001
        }
        func visibleFraction(_ f: TileFrame, in view: TileFrame) -> Double {
            let w = max(0, min(f.x + f.width, view.x + view.width) - max(f.x, view.x))
            let h = max(0, min(f.y + f.height, view.y + view.height) - max(f.y, view.y))
            return w * h / (f.width * f.height)
        }

        for leg in Leg.allCases {
            let label = "spawn follows camera (\(leg.rawValue))"
            let fixture = try Fixture(label: "spawn-follows-camera")
            defer { fixture.dispose() }

            // Reseed Roots before the mount: zone and row in world space, at the
            // resolved gap and padding, so the row is already at rest.
            let gap = TileGapResolver.resolvedGap()
            let padding = ZoneBoundsConfig.padding(defaults: .standard)
            let header = Double(ZoneChromeNSView.headerHeight)
            let originX = leg == .dust ? 100.0.nextUp : 100.0
            let originY = leg == .room ? -3500.0 : -1500.0
            let rowX = originX + padding, rowY = originY + header + padding
            let row: [UUID: TileFrame] = [
                Fixture.noteA1a: TileFrame(x: rowX, y: rowY, width: 640, height: 520),
                Fixture.noteA1b: TileFrame(x: rowX + 640 + gap, y: rowY, width: 640, height: 520),
                Fixture.fileA1: TileFrame(x: rowX + 2 * (640 + gap), y: rowY, width: 240, height: 200)
            ]
            let size = leg == .room
                ? ZoneSize(width: 3000, height: 2000)
                : ZoneSize(width: 2 * (640 + gap) + 240 + 2 * padding, height: 520 + header + 2 * padding)
            let alder = ProjectStore(projectRoot: fixture.projectRoots[Fixture.projectA1]!)
            var canvasState = try alder.loadCanvas()
            for index in canvasState.tiles.indices {
                if let frame = row[canvasState.tiles[index].id] { canvasState.tiles[index].frame = frame }
            }
            try alder.saveCanvas(canvasState)
            let workspaceStore = WorkspaceStore(workspaceId: Fixture.workspaceA, applicationSupportDirectory: fixture.appSupport)
            var document = try workspaceStore.load()
            guard let rootsIndex = document.zones.firstIndex(where: { $0.zoneId == Fixture.zoneA1 }) else {
                throw Failure(message: "\(label): the fixture has no Roots")
            }
            document.zones[rootsIndex].origin = ZonePoint(x: originX, y: originY)
            document.zones[rootsIndex].size = size
            try workspaceStore.save(document)

            try fixture.mount()
            let m = try fixture.requireMounted(label)
            defer { m.delegate.qaAgentSupervisor.stopAll() }
            try expect(m.canvas.isAutoLayoutEnabled, "\(label): auto layout must be ON for this witness")
            m.canvas.frame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
            let camera: CanvasViewport
            switch leg {
            case .full, .dust:
                // Centred on A.
                camera = CanvasViewport(x: rowX + 320 - 800, y: rowY + 260 - 500, zoom: 1)
            case .room:
                // Centred 1100 pt into the zone: the row's bottom edge sits just above the view.
                camera = CanvasViewport(x: originX + 1500 - 800, y: originY + 1100 - 500, zoom: 1)
            }
            m.canvas.setViewport(camera)
            m.canvas.layoutSubtreeIfNeeded()
            try expect(m.runtime.setActiveZone(Fixture.zoneA1, reason: .click), "\(label): Roots must arm")
            m.canvas.layoutSubtreeIfNeeded()

            func zoneRect(_ id: UUID) throws -> TileFrame {
                guard let zone = m.canvas.qaLiveZonePlacement(id) else {
                    throw Failure(message: "\(label): zone \(id) vanished")
                }
                return CanvasEngine.zoneWorldFrame(zone)
            }
            func members() -> [UUID: TileFrame] {
                Dictionary(m.canvas.allTilesInWorldFrames()
                    .filter { m.canvas.qaZoneMembership(of: $0.id) == Fixture.zoneA1 }
                    .map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
            }
            let membersBefore = members()
            try expect(Set(membersBefore.keys) == Set(row.keys),
                       "\(label): precondition: Roots must hold exactly the reseeded row; got \(membersBefore.count)")
            let others = [Fixture.zoneA2, Fixture.zoneA3]
            let rootsBefore = try zoneRect(Fixture.zoneA1)
            for id in others {
                let other = try zoneRect(id)
                try expect(!overlaps(rootsBefore, other), "\(label): precondition: Roots must start clear")
            }

            if leg != .room {
                // The dust leg must reach the case 0.7.30 could not grow into: no
                // origin left of A keeps A's world frame bit-exact. The clean leg
                // must not, or it would not be the control.
                let leftOrigin = ZonePoint(x: rowX - 640 - gap - padding, y: originY)
                let exact = CanvasEngine.exactRebaseOriginIfPossible(
                    near: leftOrigin, preserving: Array(membersBefore.values))
                try expect((exact == nil) == (leg == .dust),
                           "\(label): precondition: growing left must \(leg == .dust ? "have no" : "have an") "
                           + "exact origin; got \(String(describing: exact))")
            }

            let before = Set(m.canvas.allTilesInWorldFrames().map(\.id))
            _ = m.delegate.qaPerformPaletteAction(.newManagedAgent)
            m.canvas.layoutSubtreeIfNeeded()
            let created = Set(m.canvas.allTilesInWorldFrames().map(\.id)).subtracting(before)
            guard created.count == 1, let agentId = created.first else {
                throw Failure(message: "\(label): ⌘K Agent created \(created.count) tile(s), expected one")
            }
            let after = members()
            guard let agent = after[agentId] else {
                throw Failure(message: "\(label): the Agent must belong to Roots")
            }
            let view = TileFrame(x: camera.x, y: camera.y, width: 1600, height: 1000)
            let visible = visibleFraction(agent, in: view)
            try expect(visible >= 0.5,
                       "\(label): the Agent \(describe(agent)) is \(Int(visible * 100))% on screen in the view "
                       + "\(describe(view)); it must land where the camera is looking")
            try expect(after.contains { $0.key != agentId
                    && CanvasAutoLayoutEngine.isGapAdjacent(agent, $0.value, gap: TileGapResolver.resolvedGap()) },
                       "\(label): the Agent \(describe(agent)) must dock onto a member in an auto-layout zone")
            let rootsAfter = try zoneRect(Fixture.zoneA1)
            if leg != .room {
                try expect(agent.x + agent.width <= membersBefore[Fixture.noteA1a]!.x && rootsAfter.x < rootsBefore.x,
                           "\(label): the free slot on screen is left of A, so the Agent \(describe(agent)) must dock "
                           + "there and Roots must grow left; Roots \(describe(rootsBefore)) → \(describe(rootsAfter))")
            }
            for (id, frame) in after {
                try expect(frame.x >= rootsAfter.x - 0.001 && frame.y >= rootsAfter.y - 0.001
                           && frame.x + frame.width <= rootsAfter.x + rootsAfter.width + 0.001
                           && frame.y + frame.height <= rootsAfter.y + rootsAfter.height + 0.001,
                           "\(label): \(describe(frame)) is not inside Roots \(describe(rootsAfter))")
                for (otherId, other) in after where otherId.uuidString < id.uuidString {
                    try expect(!overlaps(frame, other), "\(label): \(describe(frame)) overlaps \(describe(other))")
                }
                if let was = membersBefore[id] {
                    try expect(abs(frame.x - was.x) <= 1.0 / 64 && abs(frame.y - was.y) <= 1.0 / 64,
                               "\(label): a member that was already there moved \(describe(was)) → \(describe(frame))")
                }
            }
            for id in others {
                let other = try zoneRect(id)
                try expect(!overlaps(rootsAfter, other),
                           "\(label): Roots \(describe(rootsAfter)) grew across \(describe(other))")
            }
        }

        print("ZoneArmingChecks: under auto layout a ⌘K Agent docked onto the zone where the camera was "
              + "looking, growing the zone left when that was the free side, float dust included")
    }

    // MARK: - 11. Closing a tile in an auto-layout zone closes the gap

    /// Closing a member used to leave a hole: `CanvasNSView.removeTile` dropped the
    /// view and ran no layout, so a row `A | Agent | B` became `A | _ | B` and stayed
    /// that way. Every close the person makes commits through `AppDelegate.deleteTile`
    /// — the title bar's ✕ (`onTileCloseRequested`), ⌘⌫, and closing an agent to
    /// History from the sidebar (Archive, the close nudge) — so both legs below drive
    /// one of those real entries, never `removeTile` or the solver.
    ///
    /// Roots is arranged at rest: `A | Agent | B` across the top, the file under A.
    ///  - Leg 1 archives the Agent from the sidebar's row menu: B must move left into
    ///    gap contact with A, on the same line.
    ///  - Leg 2 closes A with its ✕: what is left must still be one gap-contact
    ///    cluster.
    /// After each: no member overlaps another, every member is inside the zone, the
    /// zone and its neighbours are unchanged, and the project's canvas file on disk
    /// holds the frames on screen.
    private static func runCloseTightensZone() throws {
        typealias Fixture = WorkspaceInvariantsFixture
        AgentModelCatalog.shared.resetForQA(snapshot: AgentHarnessCatalogSnapshot(
            harness: .pi, readiness: .ready, models: AgentCatalogQAFixture.pi))
        let savedArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = savedArguments
        arguments[AgentHarnessConfig.key] = AgentHarness.pi.rawValue
        arguments[AgentModelConfig.modelKey] = AgentCatalogQAFixture.pi[0]
        arguments[AgentModelConfig.thinkingKey] = AgentModelConfig.defaultThinking
        arguments[CanvasAutoLayoutConfig.enabledKey] = true
        // Pinned, so whoever's preferences run this cannot move the arithmetic, and a
        // close never stops on a confirmation alert.
        arguments[TileGapResolver.userDefaultsKey] = 8.0
        arguments[ZoneBoundsConfig.paddingKey] = 24.0
        arguments[DeleteConfirmPolicy.userDefaultsKey] = DeleteConfirmPolicy.never.rawValue
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer {
            UserDefaults.standard.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain)
            AgentModelCatalog.shared.resetForQA()
        }

        let fixture = try Fixture(label: "close-tightens")
        defer { fixture.dispose() }
        try fixture.mount()
        let m = try fixture.requireMounted("close-tightens")
        defer { m.delegate.qaAgentSupervisor.stopAll() }
        try expect(m.canvas.isAutoLayoutEnabled, "close tightens: auto layout must be ON for this witness")

        let roots = Fixture.zoneA1
        let gap = 8.0, padding = 24.0, header = Double(ZoneChromeNSView.headerHeight)
        func describe(_ f: TileFrame) -> String { "(\(f.x), \(f.y)) \(f.width)x\(f.height)" }
        func zoneRect(_ id: UUID) throws -> TileFrame {
            guard let zone = m.canvas.qaLiveZonePlacement(id) else {
                throw Failure(message: "close tightens: zone \(id) vanished")
            }
            return CanvasEngine.zoneWorldFrame(zone)
        }
        func members() -> [UUID: TileFrame] {
            Dictionary(m.canvas.allTilesInWorldFrames()
                .filter { m.canvas.qaZoneMembership(of: $0.id) == roots }
                .map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        }

        try expect(m.runtime.setActiveZone(roots, reason: .click), "close tightens: Roots must arm")
        let before = Set(m.canvas.allTilesInWorldFrames().map(\.id))
        _ = m.delegate.qaPerformPaletteAction(.newManagedAgent)
        m.canvas.layoutSubtreeIfNeeded()
        let created = Set(m.canvas.allTilesInWorldFrames().map(\.id)).subtracting(before)
        guard created.count == 1, let agentTile = created.first else {
            throw Failure(message: "close tightens: ⌘K Agent created \(created.count) tile(s), expected one")
        }
        guard let agentId = m.delegate.qaAgentSupervisor.agent(forTile: agentTile) else {
            throw Failure(message: "close tightens: the new Agent tile has no agent behind it")
        }

        // The arrangement, at rest: every member in gap contact, top-left at the
        // zone's content corner.
        let zone = try zoneRect(roots)
        let cx = zone.x + padding, cy = zone.y + header + padding
        let a = Fixture.noteA1a, b = Fixture.noteA1b, file = Fixture.fileA1
        let arranged: [UUID: TileFrame] = [
            a: TileFrame(x: cx, y: cy, width: 240, height: 160),
            agentTile: TileFrame(x: cx + 248, y: cy, width: 320, height: 240),
            b: TileFrame(x: cx + 248 + 328, y: cy, width: 240, height: 160),
            file: TileFrame(x: cx, y: cy + 168, width: 240, height: 200)
        ]
        try expect(cx + 248 + 328 + 240 <= zone.x + zone.width - padding,
                   "close tightens: Roots \(describe(zone)) is too narrow for the arranged row")
        var applied = false
        m.canvas.performGeometryEdit(.moveTile, includeAllTiles: true) {
            applied = m.canvas.applyGeometrySnapshot(CanvasGeometrySnapshot(
                tiles: arranged.map { CanvasTileGeometry(tileId: $0.key, frame: $0.value, zoneId: roots) },
                zones: []), notifyCommit: false)
        }
        m.canvas.layoutSubtreeIfNeeded()
        try expect(applied && members() == arranged,
                   "close tightens: the arrangement did not land — \(members().mapValues(describe))")

        let zonesBefore = try Dictionary(uniqueKeysWithValues: m.runtime.document.zones.map {
            ($0.zoneId, try zoneRect($0.zoneId))
        })
        let projectStore = ProjectStore(projectRoot: fixture.projectRoots[Fixture.projectA1]!)

        func expectSettled(_ leg: String, closed: UUID) throws {
            m.canvas.layoutSubtreeIfNeeded()
            let now = members()
            try expect(now[closed] == nil && !m.canvas.allTilesInWorldFrames().contains { $0.id == closed },
                       "\(leg): the closed tile is still on the canvas")
            for (id, was) in zonesBefore {
                let rect = try zoneRect(id)
                try expect(rect == was, "\(leg): closing a tile changed zone \(id) \(describe(was)) → \(describe(rect))")
            }
            for (id, f) in now {
                try expect(f.x >= zone.x + padding - 0.001 && f.y >= zone.y + header + padding - 0.001
                           && f.x + f.width <= zone.x + zone.width - padding + 0.001
                           && f.y + f.height <= zone.y + zone.height - padding + 0.001,
                           "\(leg): \(id) \(describe(f)) is not inside Roots \(describe(zone))")
            }
            let frames = Array(now.values)
            for (index, p) in frames.enumerated() {
                for q in frames.dropFirst(index + 1) {
                    let overlap = p.x < q.x + q.width - 0.001 && q.x < p.x + p.width - 0.001
                        && p.y < q.y + q.height - 0.001 && q.y < p.y + p.height - 0.001
                    try expect(!overlap, "\(leg): \(describe(p)) overlaps \(describe(q))")
                }
            }
            // One gap-contact cluster: the hole the closed tile left has closed.
            var reached: Set<UUID> = [now.keys.sorted { $0.uuidString < $1.uuidString }[0]]
            var grew = true
            while grew {
                grew = false
                for (id, f) in now where !reached.contains(id)
                    && reached.contains(where: { CanvasAutoLayoutEngine.isGapAdjacent(f, now[$0]!, gap: gap) }) {
                    reached.insert(id)
                    grew = true
                }
            }
            try expect(reached.count == now.count,
                       "\(leg): the zone kept the hole the closed tile left — the members are not one "
                       + "gap-contact cluster: \(now.mapValues(describe))")
            guard let persisted = try projectStore.tryLoadCanvas() else {
                throw Failure(message: "\(leg): project Alder has no canvas on disk")
            }
            try expect(!persisted.tiles.contains { $0.id == closed },
                       "\(leg): the closed tile is still in the canvas file")
            for (id, f) in now {
                let onDisk = persisted.tiles.first { $0.id == id }?.frame
                try expect(onDisk == f, "\(leg): \(id) is at \(describe(f)) on screen but "
                           + "\(onDisk.map(describe) ?? "absent") on disk")
            }
        }

        // Leg 1: Archive from the sidebar's row menu, the verb the close nudge uses.
        try expect(m.delegate.performInboxRowAction(.archive, on: [agentId.rawValue]),
                   "close tightens: Archive refused the idle Agent")
        try expectSettled("archive", closed: agentTile)
        let afterArchive = members()
        try expect(afterArchive[b] == TileFrame(x: cx + 248, y: cy, width: 240, height: 160),
                   "archive: B must close up to A at (\(cx + 248), \(cy)); it is at "
                   + "\(afterArchive[b].map(describe) ?? "nowhere")")
        try expect(afterArchive[a] == arranged[a] && afterArchive[file] == arranged[file],
                   "archive: A and the file were already in place and must not move")

        // Leg 2: the title bar's ✕.
        guard let closeRequested = m.canvas.onTileCloseRequested else {
            throw Failure(message: "close tightens: the canvas has no close handler wired")
        }
        closeRequested(a)
        try expectSettled("✕", closed: a)

        print("ZoneArmingChecks: closing a tile in an auto-layout zone (Archive from the sidebar, and "
              + "the ✕) closed the gap it left, kept the zone and its neighbours where they were, and "
              + "persisted the result")
    }
}

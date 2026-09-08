import AppKit
import ContinuumRevivedCore
import Foundation

/// CX-01 Phase 1 (`.plans/59`) — the workspace API through the PRODUCTION mount
/// and the PRODUCTION dispatch entry (`AppDelegate.qaWorkspaceAPI.dispatch`, the
/// same call the pi bridge makes). Never `install(into:)`; the scene comes from
/// `mountWorkspaceSceneAtBoot`, as at launch.
///
/// Fixture: two checkouts holding the same filename (`notes.md`), the source
/// agent's checkout (Pb) in a NON-armed, non-zero-origin zone that is live only
/// because it is pinned, a second Pb zone far off camera with no layer at all, an
/// already-open dirty document for the namesake in Pb, a duplicate-appearance
/// document, and a third project in another workspace.
///
/// `--workspace-api-open-check`: W01 context/coverage/projection, W02/W03/W14
/// correct checkout + draft preserved + world frame in the zone, W04 partial
/// relationship failure + retry, W15 unhydrated preservation, W16 duplicates.
/// `--workspace-api-grants-check`: W27 explicit target precedence + conflict,
/// W28 grants/approval/forgery/revocation, W20 leak-free denial, W24/W29 the
/// five presentation dimensions with concurrent user interaction.
@MainActor
enum WorkspaceAPIChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        var localizedDescription: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    // MARK: - Fixture

    @MainActor
    struct Fixture {
        let tempRoot: URL
        let delegate: AppDelegate
        let runtime: WorkspaceRuntime
        let canvas: CanvasNSView
        let browserEngine: BrowserEngineContext
        let agentId: AgentID
        let workspaceWA: UUID
        let workspaceWB: UUID
        let projectPa: UUID
        let projectPb: UUID
        let projectPc: UUID
        let zoneA: UUID
        let zoneB: UUID
        let zoneB2: UUID
        let agentTileB: UUID
        let fileTileB: UUID
        let hiddenB: UUID
        let paRoot: URL
        let pbRoot: URL
        let pcRoot: URL
        let storePa: ProjectStore
        let storePb: ProjectStore
        let storePc: ProjectStore
        let paSentinel: String
        let pbSentinel: String

        var api: WorkspaceAPIService { delegate.qaWorkspaceAPI }
        var focusBroker: FocusBroker { delegate.qaFocusBroker }
        var paHandle: CheckoutHandle { CheckoutHandle.derive(canonicalRoot: CheckoutHandle.canonicalRoot(paRoot.path)) }
        var pbHandle: CheckoutHandle { CheckoutHandle.derive(canonicalRoot: CheckoutHandle.canonicalRoot(pbRoot.path)) }
        var pcHandle: CheckoutHandle { CheckoutHandle.derive(canonicalRoot: CheckoutHandle.canonicalRoot(pcRoot.path)) }

        func tearDown() {
            browserEngine.shutdown()
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func makeFixture() throws -> Fixture {
        let fileManager = FileManager.default
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let workspaceWA = UUID(uuidString: "00000000-0000-0000-0000-0000000CA101")!
        let workspaceWB = UUID(uuidString: "00000000-0000-0000-0000-0000000CA102")!
        let projectPa = UUID(uuidString: "00000000-0000-0000-0000-0000000CA103")!
        let projectPb = UUID(uuidString: "00000000-0000-0000-0000-0000000CA104")!
        let projectPc = UUID(uuidString: "00000000-0000-0000-0000-0000000CA105")!
        let zoneA = UUID(uuidString: "00000000-0000-0000-0000-0000000CA106")!
        let zoneB = UUID(uuidString: "00000000-0000-0000-0000-0000000CA107")!
        let zoneB2 = UUID(uuidString: "00000000-0000-0000-0000-0000000CA108")!
        let zoneC = UUID(uuidString: "00000000-0000-0000-0000-0000000CA109")!
        let noteA = UUID(uuidString: "00000000-0000-0000-0000-0000000CA10A")!
        let agentTileB = UUID(uuidString: "00000000-0000-0000-0000-0000000CA10B")!
        let fileTileB = UUID(uuidString: "00000000-0000-0000-0000-0000000CA10C")!
        let dupTile1 = UUID(uuidString: "00000000-0000-0000-0000-0000000CA10D")!
        let dupTile2 = UUID(uuidString: "00000000-0000-0000-0000-0000000CA10E")!
        let hiddenB = UUID(uuidString: "00000000-0000-0000-0000-0000000CA10F")!
        let noteC = UUID(uuidString: "00000000-0000-0000-0000-0000000CA110")!

        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-workspace-api-\(UUID().uuidString)", isDirectory: true)
        let paRoot = tempRoot.appendingPathComponent("Pa", isDirectory: true)
        let pbRoot = tempRoot.appendingPathComponent("Pb", isDirectory: true)
        let pcRoot = tempRoot.appendingPathComponent("Pc", isDirectory: true)
        let appSupport = tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        for dir in [paRoot, pbRoot, pcRoot, appSupport] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // The SAME filename in every checkout, with distinguishing content.
        let paSentinel = "Pa notes: sentinel-pa\n"
        let pbSentinel = "Pb notes: sentinel-pb\n"
        try Data(paSentinel.utf8).write(to: paRoot.appendingPathComponent("notes.md"))
        try Data(pbSentinel.utf8).write(to: pbRoot.appendingPathComponent("notes.md"))
        try Data("Pc notes: sentinel-pc\n".utf8).write(to: pcRoot.appendingPathComponent("notes.md"))
        try Data("dup\n".utf8).write(to: pbRoot.appendingPathComponent("dup.md"))
        try Data("other\n".utf8).write(to: pbRoot.appendingPathComponent("other.md"))
        try Data("hidden target\n".utf8).write(to: pbRoot.appendingPathComponent("hidden-target.md"))
        try Data("second\n".utf8).write(to: paRoot.appendingPathComponent("second.md"))

        func makeProject(id: UUID, name: String, root: URL) -> Project {
            Project(
                id: id, name: name, rootPath: root.path, createdAt: now, updatedAt: now,
                defaultLaunchProfileId: "shell", editorPreference: .auto,
                settings: ProjectSettings(restorePolicy: .restoreDescriptors,
                                          browserStoragePolicy: .perProject,
                                          terminalClosePolicy: .askWhenRunning))
        }
        func note(_ id: UUID, zone: UUID, x: Double, y: Double) -> Tile {
            var tile = Tile(id: id, kind: .note, title: "note",
                            frame: TileFrame(x: x, y: y, width: 220, height: 140),
                            zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata(noteId: id))
            tile.zoneId = zone
            return tile
        }
        func fileTile(_ id: UUID, zone: UUID, root: URL, projectId: UUID, relative: String, x: Double, y: Double) -> Tile {
            let path = canonical(root.appendingPathComponent(relative))
            var tile = Tile(id: id, kind: .file, title: relative,
                            frame: TileFrame(x: x, y: y, width: 480, height: 360),
                            zPosition: .fromLegacyRank(2), runtimeRef: nil,
                            metadata: TileMetadata(
                                filePath: path,
                                documentLocation: DocumentLocation(
                                    path: path,
                                    scope: .checkout(projectId: projectId, rootPath: canonical(root), relativePath: relative)),
                                fileEditorViewState: FileEditorViewState(sidebarExpanded: false)))
            tile.zoneId = zone
            return tile
        }

        let projectPaObj = makeProject(id: projectPa, name: "Pa", root: paRoot)
        let projectPbObj = makeProject(id: projectPb, name: "Pb", root: pbRoot)
        let projectPcObj = makeProject(id: projectPc, name: "Pc", root: pcRoot)
        let storePa = ProjectStore(projectRoot: paRoot)
        let storePb = ProjectStore(projectRoot: pbRoot)
        let storePc = ProjectStore(projectRoot: pcRoot)
        try storePa.saveProject(projectPaObj)
        try storePa.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [note(noteA, zone: zoneA, x: 640, y: 240)], groups: [], lastActiveTileId: noteA))
        try storePb.saveProject(projectPbObj)
        // WORLD frames, inside zoneB's world rect (origin 3000,400) and zoneB2's (9000,9000).
        try storePb.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [
                note(agentTileB, zone: zoneB, x: 3040, y: 440),
                fileTile(fileTileB, zone: zoneB, root: pbRoot, projectId: projectPb, relative: "notes.md", x: 3300, y: 500),
                fileTile(dupTile1, zone: zoneB, root: pbRoot, projectId: projectPb, relative: "dup.md", x: 3040, y: 900),
                fileTile(dupTile2, zone: zoneB, root: pbRoot, projectId: projectPb, relative: "dup.md", x: 3600, y: 900),
                note(hiddenB, zone: zoneB2, x: 9040, y: 9040),
            ], groups: [], lastActiveTileId: agentTileB))
        try storePc.saveProject(projectPcObj)
        try storePc.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [note(noteC, zone: zoneC, x: 40, y: 40)], groups: [], lastActiveTileId: noteC))

        func placement(_ zone: UUID, project: UUID, x: Double, y: Double, w: Double, h: Double, color: String, policy: ZoneHydrationPolicy) -> ZonePlacement {
            ZonePlacement(zoneId: zone, projectId: project, origin: ZonePoint(x: x, y: y),
                          size: ZoneSize(width: w, height: h), color: color, collapsed: false, hydrationPolicy: policy)
        }
        // zoneA armed and on camera; zoneB pinned live but NOT armed and off
        // camera at a non-zero origin; zoneB2 far away with no layer.
        let docA = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            zones: [placement(zoneA, project: projectPa, x: 600, y: 200, w: 900, h: 700, color: "blue", policy: .automatic),
                    placement(zoneB, project: projectPb, x: 3000, y: 400, w: 1400, h: 1000, color: "red", policy: .pinnedLive),
                    placement(zoneB2, project: projectPb, x: 9000, y: 9000, w: 900, h: 700, color: "green", policy: .automatic)],
            zoneZOrder: [zoneA, zoneB, zoneB2],
            lastActiveZoneId: zoneA)
        let docB = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            zones: [placement(zoneC, project: projectPc, x: 0, y: 0, w: 900, h: 700, color: "purple", policy: .automatic)],
            zoneZOrder: [zoneC],
            lastActiveZoneId: zoneC)
        try WorkspaceStore(workspaceId: workspaceWA, applicationSupportDirectory: appSupport).save(docA)
        try WorkspaceStore(workspaceId: workspaceWB, applicationSupportDirectory: appSupport).save(docB)

        var appRegistry = Registry.empty()
        appRegistry.lastActiveWorkspaceId = workspaceWA
        appRegistry.workspaces = [
            WorkspaceEntry(id: workspaceWA, name: "A", projectIds: [projectPa, projectPb], createdAt: now, updatedAt: now),
            WorkspaceEntry(id: workspaceWB, name: "B", projectIds: [projectPc], createdAt: now, updatedAt: now),
        ]
        appRegistry.projects = [
            ProjectEntry(id: projectPa, name: "Pa", rootPath: paRoot.path, workspaceId: workspaceWA, lastOpenedAt: now, pinned: false, missing: false),
            ProjectEntry(id: projectPb, name: "Pb", rootPath: pbRoot.path, workspaceId: workspaceWA, lastOpenedAt: now, pinned: false, missing: false),
            ProjectEntry(id: projectPc, name: "Pc", rootPath: pcRoot.path, workspaceId: workspaceWB, lastOpenedAt: now, pinned: false, missing: false),
        ]
        let registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        try registryStore.save(appRegistry)

        let browserEngine = BrowserEngineContext()
        let zoneRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { projectId in
            if projectId == projectPa { return ZoneRuntimeController(projectRoot: paRoot, projectStore: storePa, project: projectPaObj) }
            if projectId == projectPb { return ZoneRuntimeController(projectRoot: pbRoot, projectStore: storePb, project: projectPbObj) }
            if projectId == projectPc { return ZoneRuntimeController(projectRoot: pcRoot, projectStore: storePc, project: projectPcObj) }
            throw Failure(message: "unexpected projectId in factory: \(projectId)")
        })

        let bootCanvasState = try storePa.loadCanvas()
        let canvas = CanvasNSView(
            canvasState: bootCanvasState,
            activeZone: docA.zones.first(where: { $0.projectId == projectPa }),
            zoneRenderModels: docA.zones.map {
                CanvasNSView.ZoneRenderModel(placement: $0, displayName: $0.name.isEmpty ? "Zone" : $0.name)
            })
        canvas.frame = CGRect(x: 0, y: 0, width: 2000, height: 1200)

        let delegate = AppDelegate()
        let runtime = WorkspaceRuntime(
            boot: try zoneRegistry.acquire(projectId: projectPa),
            workspaceId: workspaceWA, document: docA, registry: zoneRegistry,
            focusBroker: delegate.qaFocusBroker, registryStore: registryStore,
            ghostty: nil, browserEngine: browserEngine)
        delegate.qaPrepareForBootMountCheck(canvas: canvas, browserEngine: browserEngine, runtime: runtime, registryStore: registryStore)
        let spawner = TileSpawner(canvasView: canvas, ghostty: nil, browserEngine: browserEngine, projectStore: storePa, project: projectPaObj)

        // The SOURCE agent: a real pi record whose checkout is Pb, bound to a tile in
        // the unarmed zone. Created before the mount, as after a relaunch.
        let agentId = delegate.qaAgentSupervisor.spawn(
            role: nil, prompt: nil, cwd: pbRoot, harness: .pi,
            model: "openai-codex/gpt-5.6-sol", thinking: "high",
            projectId: projectPb, projectRoot: pbRoot, tileId: agentTileB)

        // === The production seam. NOT `install(into:)`. ===
        try delegate.mountWorkspaceSceneAtBoot(
            canvasView: canvas, spawner: spawner, projectStore: storePa,
            canvasState: bootCanvasState, installsGlobalEventMonitors: false)
        canvas.layoutSubtreeIfNeeded()

        return Fixture(
            tempRoot: tempRoot, delegate: delegate, runtime: runtime, canvas: canvas, browserEngine: browserEngine,
            agentId: agentId, workspaceWA: workspaceWA, workspaceWB: workspaceWB,
            projectPa: projectPa, projectPb: projectPb, projectPc: projectPc,
            zoneA: zoneA, zoneB: zoneB, zoneB2: zoneB2,
            agentTileB: agentTileB, fileTileB: fileTileB, hiddenB: hiddenB,
            paRoot: paRoot, pbRoot: pbRoot, pcRoot: pcRoot,
            storePa: storePa, storePb: storePb, storePc: storePc,
            paSentinel: paSentinel, pbSentinel: pbSentinel)
    }

    // MARK: - Reply helpers

    private static var requestCounter = 0
    private static func nextRequestId() -> String { requestCounter += 1; return "req-\(requestCounter)" }

    private static func result(_ reply: WorkspaceAPIService.Reply, _ what: String) throws -> [String: AnyHashableJSON] {
        guard case let .result(object) = reply else { throw Failure(message: "\(what): expected a result, got \(reply)") }
        return object
    }

    private static func error(_ reply: WorkspaceAPIService.Reply, _ code: WorkspaceAPIError.Code, _ what: String) throws -> WorkspaceAPIError {
        guard case let .error(error) = reply else { throw Failure(message: "\(what): expected \(code.rawValue), got \(reply)") }
        try expect(error.code == code, "\(what): expected \(code.rawValue), got \(error.code.rawValue) (\(error.message))")
        return error
    }

    private static func open(_ fixture: Fixture, _ payload: [String: Any], requestId: String? = nil) -> WorkspaceAPIService.Reply {
        fixture.api.dispatch(agentId: fixture.agentId, requestId: requestId ?? nextRequestId(), op: "artifact.open", payload: payload)
    }

    private static func context(_ fixture: Fixture) -> WorkspaceAPIService.Reply {
        fixture.api.dispatch(agentId: fixture.agentId, requestId: nextRequestId(), op: "workspace.context", payload: [:])
    }

    private static func uuid(_ value: AnyHashableJSON?) -> UUID? { value?.string.flatMap(UUID.init(uuidString:)) }

    private static func fileTileCount(_ fixture: Fixture) -> Int {
        fixture.canvas.allWorkspaceTiles().filter { $0.kind == .file }.count
    }

    struct Baselines {
        let armed: UUID?
        let viewportApplies: Int
        let focus: FocusSurfaceID?
        let workspace: UUID
        let selection: UUID?
        let generation: UInt64
        let viewport: CanvasViewport
    }

    private static func baselines(_ fixture: Fixture) -> Baselines {
        Baselines(armed: fixture.canvas.armedZoneId, viewportApplies: fixture.canvas.qaViewportApplyCount,
                  focus: fixture.focusBroker.activeSurface, workspace: fixture.runtime.workspaceId,
                  selection: fixture.canvas.canvasState.lastActiveTileId,
                  generation: fixture.runtime.interactionGeneration, viewport: fixture.canvas.viewport)
    }

    private static func expectPreserved(_ fixture: Fixture, _ before: Baselines, _ what: String) throws {
        try expect(fixture.canvas.armedZoneId == before.armed, "\(what): the armed zone must not change (\(String(describing: fixture.canvas.armedZoneId)) vs \(String(describing: before.armed)))")
        try expect(fixture.canvas.qaViewportApplyCount == before.viewportApplies, "\(what): the camera must not move")
        try expect(fixture.focusBroker.activeSurface == before.focus, "\(what): keyboard focus must not change")
        try expect(fixture.runtime.workspaceId == before.workspace, "\(what): the workspace must not switch")
        try expect(fixture.canvas.canvasState.lastActiveTileId == before.selection, "\(what): the selection must not change")
    }

    // MARK: - Leg 1: open / reveal

    static func runOpenRevealCheck() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let f = fixture
        let supervisor = f.delegate.qaAgentSupervisor

        // Fixture sanity: mount gave the runtime its canvas, zoneB is installed
        // though unarmed, zoneB2 is NOT installed, the armed zone is A.
        try expect(f.runtime.qaHasCanvas, "the production mount must give the runtime its canvas")
        try expect(f.canvas.armedZoneId == f.zoneA, "zoneA must be armed at boot, got \(String(describing: f.canvas.armedZoneId))")
        try expect(f.canvas.installedZonePlacement(for: f.zoneB) != nil, "zoneB (pinnedLive) must have an installed layer")
        try expect(f.canvas.installedZonePlacement(for: f.zoneB2) == nil, "zoneB2 (far, automatic) must have NO layer — the unhydrated case")
        guard let fileView = f.canvas.tileView(for: f.fileTileB) as? FileTileNSView else {
            throw Failure(message: "the persisted Pb file tile must hydrate as a FileTileNSView, got \(String(describing: f.canvas.tileView(for: f.fileTileB)))")
        }
        try expect(fileView.loadedText == f.pbSentinel, "the Pb tile must have loaded Pb's content, got \(String(describing: fileView.loadedText))")

        // Policy off → permission_denied that names nothing (W28 first rung, W20 shape).
        let denied = try error(open(f, ["relativePath": "notes.md"]), .permissionDenied, "flag off")
        try expect(!denied.message.contains("/") && denied.message.range(of: "[0-9A-F]{8}-", options: .regularExpression) == nil,
                   "a denial must not leak paths or identifiers: \(denied.message)")
        try expect(supervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true), "enabling the policy must change the record")

        // W01 — bounded context from the mounted scene.
        let ctx = try result(context(f), "context")
        try expect(uuid(ctx["agentId"]) == f.agentId.rawValue, "context agentId")
        try expect(ctx["checkoutHandle"]?.string == f.pbHandle.rawValue, "context checkoutHandle must be Pb's, got \(String(describing: ctx["checkoutHandle"]))")
        try expect(uuid(ctx["projectId"]) == f.projectPb && uuid(ctx["workspaceId"]) == f.workspaceWA, "context project/workspace")
        try expect(uuid(ctx["zoneId"]) == f.zoneB && uuid(ctx["tileId"]) == f.agentTileB, "context zone/tile follow the agent's own tile")
        let coverage = ctx["coverage"]?.object
        try expect(coverage?["complete"]?.bool == false, "coverage must not claim completeness with an unhydrated zone")
        try expect(coverage?["installedZoneIds"]?.array?.compactMap(uuid) == [f.zoneB], "installed zones = [zoneB], got \(String(describing: coverage?["installedZoneIds"]))")
        try expect(coverage?["unhydratedZoneIds"]?.array?.compactMap(uuid) == [f.zoneB2], "unhydrated zones = [zoneB2]")
        try expect((ctx["capabilities"]?.array?.compactMap(\.string) ?? []).sorted() == ["artifact.open", "workspace.context"], "capabilities from the preset grant")
        let ctxBytes = try JSONSerialization.data(withJSONObject: WorkspaceAPIService.plain(ctx)).count
        try expect(ctxBytes < WorkspaceContextResponse.encodedByteCeiling, "context must stay under the byte ceiling, got \(ctxBytes)")
        let revisionBefore = ctx["revision"]?.object?["structure"]?.int ?? -1

        // W01 — the projection feeds the pure index from authoritative models only.
        switch WorkspaceAPIService.snapshot(runtime: f.runtime, canvas: f.canvas, records: Array(supervisor.records.values)) {
        case let .failure(error): throw Failure(message: "projection must succeed on this scene: \(error)")
        case let .success(snapshot):
            let index = CanvasEntityIndexSnapshotAdapter.buildIndex(from: snapshot)
            let entities = index.allEntities
            let fileEntity = entities.first { $0.id == .tile(f.fileTileB) }
            try expect(fileEntity?.frame == CanvasWorldRect(x: 3300, y: 500, width: 480, height: 360),
                       "the projected file tile must be in WORLD space, got \(String(describing: fileEntity?.frame))")
            try expect(fileEntity?.zoneId == .zone(f.zoneB), "the projected file tile belongs to zoneB")
            try expect(!entities.contains { $0.id == .tile(f.hiddenB) }, "an unhydrated zone contributes no tiles — absence is not inferred")
            let unhydrated = entities.first { $0.id == .zone(f.zoneB2) }
            try expect(unhydrated?.freshness.isStale == true, "the unhydrated zone is reported stale, not empty")
            try expect(entities.first { $0.id == .agent(f.agentId) }?.visibility == .visible, "the agent is visible through its installed tile")
        }

        // Dirty the Pb namesake BEFORE the open (W03 setup). A Markdown tile edits
        // through its source view once in Edit mode (the same seam
        // `FileOpenChecks` drives); the draft lives in the tile's own
        // `FileDocumentSession`, which is exactly what the reveal must not touch.
        fileView.setMode(.edit)
        fileView.layoutSubtreeIfNeeded()
        let draft = f.pbSentinel + "unsaved draft line\n"
        fileView.textView.string = draft
        fileView.textView.didChangeText()
        try expect(fileView.isDirty && fileView.qaDraftText == draft, "the fixture must hold a dirty draft before the open")
        let fileTilesBefore = fileTileCount(f)
        let before = baselines(f)

        // W02/W03/W14 — default target = the agent's OWN checkout, not the active
        // project's namesake; the existing dirty tile is revealed untouched.
        let opened = try result(open(f, ["relativePath": "notes.md", "presentation": ["camera": "preserve"], "idempotencyKey": "k1"]), "own-checkout open")
        try expect(opened["document"]?.string == "existing" && opened["placement"]?.string == "existing", "the namesake in Pb is already open: \(opened)")
        try expect(uuid(opened["tileId"]) == f.fileTileB, "the ACTUAL tile is Pb's, not Pa's namesake")
        try expect(opened["checkoutHandle"]?.string == f.pbHandle.rawValue && uuid(opened["projectId"]) == f.projectPb, "identity names Pb")
        try expect(opened["artifactHandle"]?.string == "\(f.pbHandle.rawValue):notes.md", "artifact handle is checkout-scoped: \(String(describing: opened["artifactHandle"]))")
        try expect(uuid(opened["actualZoneId"]) == f.zoneB, "actual zone is zoneB")
        let rect = opened["actualWorldRect"]?.object
        try expect(rect?["x"]?.int == 3300 && rect?["y"]?.int == 500, "actual world rect is the persisted WORLD frame inside zoneB (origin 3000,400), got \(String(describing: rect))")
        try expect(opened["draft"]?.string == "preserved", "draft reported preserved")
        try expect(fileView.isDirty && fileView.qaDraftText == draft && fileView.tile.id == f.fileTileB, "the dirty draft and tile identity survive the reveal")
        try expect(opened["relationship"]?.string == "persisted" && opened["durability"]?.string == "committed" && opened["partial"]?.bool == false, "relationship persisted: \(opened)")
        try expect(f.runtime.document.documentLinks.contains { $0.agentId == f.agentId && $0.documentTileId == f.fileTileB }, "the agent↔document link is in the workspace document")
        try expect(opened["presentationEffects"]?.object?["camera"]?.string == "preserved", "camera preserved as requested")
        try expect(fileTileCount(f) == fileTilesBefore, "no new tile for an already-open document")
        try expectPreserved(f, before, "own-checkout reveal")

        // W04 — open succeeds, relationship save fails: partial, not failure; the
        // same key replays; a new key repairs the link without another tile.
        f.runtime._workspaceDocumentSaver = { _, _ in throw Failure(message: "disk full (injected)") }
        let partial = try result(open(f, ["relativePath": "other.md", "presentation": ["camera": "preserve"], "idempotencyKey": "k2"]), "partial open")
        f.runtime._workspaceDocumentSaver = nil
        guard let otherTileId = uuid(partial["tileId"]) else { throw Failure(message: "partial open must still return the tile id: \(partial)") }
        try expect(partial["document"]?.string == "opened" && partial["relationship"]?.string == "failed"
                   && partial["durability"]?.string == "failed" && partial["partial"]?.bool == true, "partial result shape: \(partial)")
        try expect(f.canvas.zoneId(containing: otherTileId) == f.zoneB, "the new tile landed in the agent's zone")
        try expect(fileTileCount(f) == fileTilesBefore + 1, "exactly one new tile")
        let replay = try result(open(f, ["relativePath": "other.md", "presentation": ["camera": "preserve"], "idempotencyKey": "k2"]), "replay")
        try expect(replay == partial && fileTileCount(f) == fileTilesBefore + 1, "same key + same payload replays the prior result with no new tile")
        _ = try error(open(f, ["relativePath": "notes.md", "presentation": ["camera": "preserve"], "idempotencyKey": "k2"]), .idempotencyConflict, "same key, different payload")
        let repaired = try result(open(f, ["relativePath": "other.md", "presentation": ["camera": "preserve"], "idempotencyKey": "k3"]), "repair")
        try expect(repaired["document"]?.string == "existing" && uuid(repaired["tileId"]) == otherTileId
                   && repaired["relationship"]?.string == "persisted" && repaired["partial"]?.bool == false,
                   "a new key repairs the relationship on the SAME tile: \(repaired)")
        try expect(fileTileCount(f) == fileTilesBefore + 1, "the repair did not open a second tile")

        // W15 — unhydrated-state preservation: the on-disk Pb canvas still holds
        // the tile nobody hydrated; an explicit unhydrated destination is refused
        // without a flat install.
        let persistedPb = try f.storePb.tryLoadCanvas()
        try expect(persistedPb?.tiles.contains(where: { $0.id == f.hiddenB }) == true, "the merge must preserve the unhydrated zone's tile")
        try expect(persistedPb?.tiles.contains(where: { $0.id == otherTileId }) == true, "the new tile is persisted")
        try expect(persistedPb?.tiles.first(where: { $0.id == otherTileId })?.zoneId == f.zoneB, "the new tile is stamped with zoneB")
        let persistedPa = try f.storePa.tryLoadCanvas()
        try expect(persistedPa?.tiles.count == 1, "Pa's canvas is untouched by Pb opens")
        let tilesBeforeRefusal = f.canvas.allWorkspaceTiles().count
        let unhydrated = try error(open(f, ["relativePath": "hidden-target.md", "placement": ["targetZoneId": f.zoneB2.uuidString]]), .unsupported, "unhydrated destination")
        try expect(unhydrated.message == "zone_unhydrated", "an unhydrated destination is refused, never flat-installed: \(unhydrated.message)")
        try expect(f.canvas.allWorkspaceTiles().count == tilesBeforeRefusal, "a refusal installs nothing")
        // A document ALREADY open elsewhere is revealed where it is, whatever
        // destination was suggested: identity beats placement.
        let alreadyOpenElsewhere = try result(open(f, ["relativePath": "other.md", "placement": ["targetZoneId": f.zoneB2.uuidString], "presentation": ["camera": "preserve"], "idempotencyKey": "k4"]), "existing doc, unhydrated suggestion")
        try expect(alreadyOpenElsewhere["document"]?.string == "existing" && uuid(alreadyOpenElsewhere["tileId"]) == otherTileId
                   && uuid(alreadyOpenElsewhere["actualZoneId"]) == f.zoneB, "an open document is revealed where it lives: \(alreadyOpenElsewhere)")
        try expect(f.canvas.allWorkspaceTiles().count == tilesBeforeRefusal, "revealing installs nothing")

        // W16 — duplicate appearances are refused, never guessed.
        let dup = try error(open(f, ["relativePath": "dup.md"]), .unsupported, "duplicate occurrences")
        try expect(dup.message == "duplicate_occurrence", "duplicate reason, got \(dup.message)")
        try expect(f.canvas.allWorkspaceTiles().count == tilesBeforeRefusal, "a duplicate refusal installs nothing")

        // revealOnly on something not open → not_found, nothing manufactured.
        // revealOnly never manufactures a tile: a Pb file that is not open → not_found;
        // a name that exists only in Pa is not a file inside Pb → not_found, never Pa's.
        _ = try error(open(f, ["relativePath": "hidden-target.md", "mode": "revealOnly"]), .notFound, "revealOnly of an unopened Pb file")
        _ = try error(open(f, ["relativePath": "second.md", "checkoutHandle": f.pbHandle.rawValue, "mode": "revealOnly"]), .notFound, "revealOnly of a Pa-only name inside Pb")
        try expect(f.canvas.allWorkspaceTiles().count == tilesBeforeRefusal, "revealOnly never creates a tile")

        // Revision moved with the committed open, not with the refusals.
        let ctxAfter = try result(context(f), "context after")
        let revisionAfter = ctxAfter["revision"]?.object?["structure"]?.int ?? -1
        try expect(revisionAfter > revisionBefore, "structural revision must advance after an opened document (\(revisionBefore) → \(revisionAfter))")
        let recent = ctxAfter["recentOperations"]?.array ?? []
        try expect(recent.contains { $0.object?["outcome"]?.string == "partial" } && recent.contains { $0.object?["outcome"]?.string == "ok" },
                   "recentOperations records the partial and the ok opens: \(recent)")
        try expectPreserved(f, before, "the whole open/reveal leg")
    }

    // MARK: - Leg 2: grants and presentation

    static func runGrantsAndPresentationCheck() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let f = fixture
        let supervisor = f.delegate.qaAgentSupervisor
        try expect(supervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true), "enable the policy")

        var decisions: [WorkspaceAPIService.ScopeApprovalDecision] = []
        var prompts: [WorkspaceAPIService.ScopeApprovalPrompt] = []
        f.api.approvalHandler = { prompt in
            prompts.append(prompt)
            return decisions.isEmpty ? .deny : decisions.removeFirst()
        }

        // In-grant opens never prompt.
        let own = try result(open(f, ["relativePath": "notes.md", "presentation": ["camera": "preserve"]]), "own open")
        try expect(uuid(own["tileId"]) == f.fileTileB && prompts.isEmpty, "an in-grant open prompts nobody")

        // W27 — explicit Pa overrides the Pb default; approval once; Pa's SENTINEL.
        let fileTilesBefore = fileTileCount(f)
        decisions = [.allowOnce]
        let paOpen = try result(open(f, ["relativePath": "notes.md", "checkoutHandle": f.paHandle.rawValue, "presentation": ["camera": "preserve"]]), "explicit Pa open")
        try expect(prompts.count == 1 && prompts[0].checkout == f.paHandle && prompts[0].relativePath == "notes.md" && prompts[0].agentId == f.agentId,
                   "extra scope goes through the trusted prompt with the concrete checkout and path: \(prompts)")
        guard let paTileId = uuid(paOpen["tileId"]) else { throw Failure(message: "explicit open must return a tile: \(paOpen)") }
        try expect(paOpen["document"]?.string == "opened" && uuid(paOpen["actualZoneId"]) == f.zoneA
                   && paOpen["checkoutHandle"]?.string == f.paHandle.rawValue && paOpen["artifactHandle"]?.string == "\(f.paHandle.rawValue):notes.md",
                   "the explicit target wins: Pa's notes.md in zoneA: \(paOpen)")
        try expect(paTileId != f.fileTileB && fileTileCount(f) == fileTilesBefore + 1, "a different document, a new tile")
        guard let paView = f.canvas.tileView(for: paTileId) as? FileTileNSView else { throw Failure(message: "Pa tile must be a FileTileNSView") }
        try expect(paView.loadedText == f.paSentinel, "the opened tile shows Pa's content, got \(String(describing: paView.loadedText))")
        let paRect = paOpen["actualWorldRect"]?.object
        let zoneAPlacement = f.canvas.installedZonePlacement(for: f.zoneA)!
        try expect((paRect?["x"]?.int ?? -1) >= Int(zoneAPlacement.origin.x) && (paRect?["y"]?.int ?? -1) >= Int(zoneAPlacement.origin.y),
                   "the new tile's world rect lies inside zoneA's world rect: \(String(describing: paRect)) vs origin \(zoneAPlacement.origin)")
        // The once-grant is spent: the next Pa open prompts again.
        decisions = [.deny]
        let deniedAgain = try error(open(f, ["relativePath": "second.md", "checkoutHandle": f.paHandle.rawValue]), .permissionDenied, "spent once-grant")
        try expect(prompts.count == 2 && deniedAgain.approvalRequestId == prompts[1].requestId, "a spent once-grant prompts again and the denial cites the prompt")
        try expect(fileTileCount(f) == fileTilesBefore + 1, "a denial applies no effect")

        // W27 — a conflicting handle is rejected outright, before any prompt.
        let promptsBeforeConflict = prompts.count
        _ = try error(open(f, ["relativePath": "notes.md", "checkoutHandle": f.paHandle.rawValue, "artifactHandle": "\(f.pbHandle.rawValue):notes.md"]), .targetConflict, "conflicting handle")
        _ = try error(open(f, ["relativePath": "other.md", "artifactHandle": "\(f.pbHandle.rawValue):notes.md"]), .targetConflict, "handle vs path")
        try expect(prompts.count == promptsBeforeConflict && fileTileCount(f) == fileTilesBefore + 1, "a conflict prompts nobody and opens nothing")

        // W28 — session approval: one prompt, then repeated Pa opens are silent.
        decisions = [.allowForSession]
        let second = try result(open(f, ["relativePath": "second.md", "checkoutHandle": f.paHandle.rawValue, "presentation": ["camera": "preserve"]]), "session approval")
        try expect(second["document"]?.string == "opened" && prompts.count == promptsBeforeConflict + 1, "session approval prompts once")
        let again = try result(open(f, ["relativePath": "notes.md", "checkoutHandle": f.paHandle.rawValue, "presentation": ["camera": "preserve"]]), "repeat under session grant")
        try expect(uuid(again["tileId"]) == paTileId && prompts.count == promptsBeforeConflict + 1, "a second in-session open prompts nobody and reuses the tile")

        // W28 — forged authorization in the payload is inert: a NEW checkout still
        // prompts, and a denied prompt denies.
        decisions = [.deny]
        let forged = try error(open(f, ["relativePath": "notes.md", "checkoutHandle": f.pcHandle.rawValue,
                                        "authorized": true, "approvalRequestId": prompts.last!.requestId]), .permissionDenied, "forged approval")
        try expect(forged.approvalRequestId != nil && forged.approvalRequestId != prompts.dropLast().last?.requestId, "the forged id did not stand in for a real prompt")

        // W29 — cross-workspace target: approval granted, yet the only route
        // would switch workspaces → presentation_required BEFORE any effect.
        decisions = [.allowOnce]
        let tilesBeforePc = f.canvas.allWorkspaceTiles().count
        let pcBefore = try f.storePc.tryLoadCanvas()
        let crossWorkspace = try error(open(f, ["relativePath": "notes.md", "checkoutHandle": f.pcHandle.rawValue,
                                                "presentation": ["workspace": "allowSwitchToResolvedTarget"]]), .presentationRequired, "cross-workspace")
        try expect(crossWorkspace.requiredEffects?.workspace == .changed, "presentation_required names the workspace dimension")
        try expect(f.runtime.workspaceId == f.workspaceWA && f.canvas.allWorkspaceTiles().count == tilesBeforePc, "no switch, no tile")
        let pcAfter = try f.storePc.tryLoadCanvas()
        try expect(pcAfter == pcBefore, "Pc's canvas on disk is untouched")

        // W24/W29 — presentation dimensions. Baselines first.
        let before = baselines(f)
        // (a) camera reveal into the UNARMED zoneB would re-arm it → unavailable.
        let revealB = try result(open(f, ["relativePath": "notes.md", "presentation": ["camera": "revealResult"]]), "reveal into unarmed zone")
        try expect(revealB["presentationEffects"]?.object?["camera"]?.string == "unavailable" && revealB["presentation"]?.string == "unavailable",
                   "revealing into an unarmed zone is unavailable (targeting ≠ arming): \(revealB["presentationEffects"] as Any)")
        try expectPreserved(f, before, "unavailable reveal")
        // (b) camera reveal into the ARMED zoneA moves the camera and nothing else.
        let revealA = try result(open(f, ["relativePath": "notes.md", "checkoutHandle": f.paHandle.rawValue, "presentation": ["camera": "revealResult"]]), "reveal into armed zone")
        let effectsA = revealA["presentationEffects"]?.object
        try expect(effectsA?["camera"]?.string == "changed" && revealA["presentation"]?.string == "navigated", "camera changed: \(String(describing: effectsA))")
        try expect(f.canvas.qaViewportApplyCount == before.viewportApplies + 1, "exactly one camera apply")
        let framed = f.canvas.framedViewportForTileJump(paTileId)
        try expect(framed.map { $0 == f.canvas.viewport } == true, "the camera landed on the reveal framing for the tile")
        try expect(f.focusBroker.activeSurface == before.focus && f.canvas.canvasState.lastActiveTileId == before.selection
                   && f.canvas.armedZoneId == before.armed && f.runtime.workspaceId == before.workspace,
                   "focus, selection, armed zone and workspace are untouched by a camera reveal")
        try expect(f.runtime.interactionGeneration == before.generation, "a programmatic reveal is not a user interaction")
        // (c) selection/focus/workspace/armedZone are outside the preset ceiling → preserved.
        let ceiling = try result(open(f, ["relativePath": "notes.md", "checkoutHandle": f.paHandle.rawValue,
                                          "presentation": ["camera": "preserve", "keyboardFocus": "enterResult", "selection": "selectResult",
                                                           "workspace": "allowSwitchToResolvedTarget", "armedZone": "setResolvedTarget"]]), "beyond ceiling")
        let ceilingEffects = ceiling["presentationEffects"]?.object
        try expect(ceilingEffects?["keyboardFocus"]?.string == "preserved" && ceilingEffects?["selection"]?.string == "preserved"
                   && ceilingEffects?["workspace"]?.string == "preserved" && ceilingEffects?["armedZone"]?.string == "preserved",
                   "the grant ceiling collapses every dimension it does not permit: \(String(describing: ceilingEffects))")
        try expect(f.focusBroker.activeSurface == before.focus && f.canvas.canvasState.lastActiveTileId == before.selection, "no focus or selection change")
        // (d) concurrent user interaction: the user arms/clicks during the request
        //     → every non-preserve dimension defers; nothing is overwritten.
        let appliesBeforeDeferred = f.canvas.qaViewportApplyCount
        f.api._beforePresentationHook = { f.runtime.setActiveZone(f.zoneA, reason: .click) }
        let deferred = try result(open(f, ["relativePath": "notes.md", "checkoutHandle": f.paHandle.rawValue, "presentation": ["camera": "revealResult"]]), "deferred reveal")
        f.api._beforePresentationHook = nil
        try expect(deferred["presentationEffects"]?.object?["camera"]?.string == "deferred" && deferred["presentation"]?.string == "deferred",
                   "a newer user interaction defers the reveal: \(deferred["presentationEffects"] as Any)")
        try expect(f.canvas.qaViewportApplyCount == appliesBeforeDeferred, "a deferred reveal does not move the camera")
        try expect(f.runtime.interactionGeneration == before.generation + 1, "the user's click bumped the generation exactly once")
        // (e) a stale expected generation supplied by the caller also defers.
        let stale = try result(open(f, ["relativePath": "notes.md", "checkoutHandle": f.paHandle.rawValue,
                                        "presentation": ["camera": "revealResult", "expectedInteractionGeneration": Int(before.generation)]]), "stale generation")
        try expect(stale["presentationEffects"]?.object?["camera"]?.string == "deferred", "a stale expectedInteractionGeneration defers")
        // (f) user camera motion bumps the generation; programmatic does not.
        let generationBeforeCamera = f.runtime.interactionGeneration
        f.canvas.setViewport(CanvasViewport(x: 10, y: 10, zoom: 1))
        try expect(f.runtime.interactionGeneration == generationBeforeCamera, "a programmatic setViewport is not a user interaction")
        var cameraCallbackFired = false
        let previous = f.canvas.onUserCameraChange
        f.canvas.onUserCameraChange = { cameraCallbackFired = true; previous?() }
        f.canvas.onUserCameraChange = previous
        _ = cameraCallbackFired
        // (g) CX-01 hardening: a KEYBOARD camera jump and a PALETTE spawn are the
        //     user's acts too, though neither runs through the camera driver or a
        //     click. Hold-⌥ Return reveals the current tile through
        //     `revealTileForWork`, the seam every ⌘K/leader tile jump shares; the
        //     palette's New Note focuses what it made through `focusSpawnedTile`.
        //     Each must bump the generation, and a reveal pinned to the pre-jump
        //     generation must then defer instead of overwriting the user's move.
        func synthesizedKey(_ type: NSEvent.EventType, _ key: String, _ keyCode: UInt16, _ mods: NSEvent.ModifierFlags) throws -> NSEvent {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                                               characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode)
            else { throw Failure(message: "could not synthesize \(type) \(key)") }
            return event
        }
        let generationBeforeKeyboard = f.runtime.interactionGeneration
        f.canvas.setViewport(CanvasViewport(x: -4000, y: -4000, zoom: 0.5))
        f.canvas.markActive(tileId: paTileId)
        f.delegate.leaderDwell = 0
        f.delegate.handleFlagsChanged(try synthesizedKey(.flagsChanged, "", 58, [.option]))
        try expect(f.focusBroker.activeSurface == .modal(.leader), "holding ⌥ arms the leader, got \(String(describing: f.focusBroker.activeSurface))")
        let appliesBeforeKeyboard = f.canvas.qaViewportApplyCount
        let leaderReturn = try synthesizedKey(.keyDown, "\r", 36, [.option])
        try expect(f.delegate.handleHotkey(leaderReturn), "leader Return is consumed")
        f.delegate.handleFlagsChanged(try synthesizedKey(.flagsChanged, "", 58, []))
        try expect(f.canvas.qaViewportApplyCount == appliesBeforeKeyboard + 1 && f.canvas.viewport == f.canvas.framedViewportForTileJump(paTileId),
                   "leader Return jumped the camera to the current tile")
        try expect(f.runtime.interactionGeneration > generationBeforeKeyboard, "a keyboard camera jump is a user interaction")
        let staleAfterKeyboard = try result(open(f, ["relativePath": "notes.md", "checkoutHandle": f.paHandle.rawValue,
                                                     "presentation": ["camera": "revealResult", "expectedInteractionGeneration": Int(generationBeforeKeyboard)]]), "stale after keyboard jump")
        try expect(staleAfterKeyboard["presentationEffects"]?.object?["camera"]?.string == "deferred", "a reveal pinned before the keyboard jump defers")
        let generationBeforeSpawn = f.runtime.interactionGeneration
        let notesBeforeSpawn = f.canvas.allWorkspaceTiles().filter { $0.kind == .note }.count
        try expect(f.delegate.qaPerformPaletteAction(.newNote), "the palette spawns a note into the armed zone")
        try expect(f.canvas.allWorkspaceTiles().filter { $0.kind == .note }.count == notesBeforeSpawn + 1, "exactly one note tile appeared")
        try expect(f.runtime.interactionGeneration > generationBeforeSpawn, "a palette spawn's focus is a user interaction")
        let staleAfterSpawn = try result(open(f, ["relativePath": "notes.md", "checkoutHandle": f.paHandle.rawValue,
                                                  "presentation": ["camera": "revealResult", "expectedInteractionGeneration": Int(generationBeforeSpawn)]]), "stale after palette spawn")
        try expect(staleAfterSpawn["presentationEffects"]?.object?["camera"]?.string == "deferred", "a reveal pinned before the palette spawn defers")

        // (h) CX-01 hardening: the per-agent Workspace Tools item on the agent's own
        //     tile menu. Driven through the REAL NSMenuItem — its target and action —
        //     so the witness covers the wiring a user's click uses, not a copy of the
        //     toggle. Unchecking must deny the next dispatch; re-checking must restore
        //     it. A tile with no agent behind it offers no item at all.
        let agentTile = ManagedAgentTileNSView(tile: Tile(
            id: f.agentTileB, kind: .managedAgent, title: "workspace-tools-menu",
            frame: TileFrame(x: 0, y: 0, width: 520, height: 420), zPosition: .fromLegacyRank(1),
            runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed")))
        try expect(agentTile.qaWorkspaceToolsMenuEntry() == nil, "a tile with no agent offers no Workspace Tools item")
        agentTile.attach(agentID: f.agentId, supervisor: supervisor, projectName: "Pb")
        let armed = agentTile.qaWorkspaceToolsMenuEntry()
        try expect(armed?.title == "Workspace Tools" && armed?.isOn == true,
                   "the item reads the record: enabled shows a checkmark, got \(String(describing: armed))")
        try expect(agentTile.qaInvokeWorkspaceToolsMenuItem(), "the menu item is invocable")
        try expect(supervisor.records[f.agentId]?.workspaceToolsEnabled == false && agentTile.qaWorkspaceToolsMenuEntry()?.isOn == false,
                   "unchecking clears the record and the checkmark")
        _ = try error(context(f), .permissionDenied, "context after the menu revoked")
        _ = try error(open(f, ["relativePath": "notes.md", "presentation": ["camera": "preserve"]]), .permissionDenied, "open after the menu revoked")
        try expect(f.api.qaGrants(for: f.agentId).isEmpty, "the menu's revocation dropped every minted grant")
        try expect(agentTile.qaInvokeWorkspaceToolsMenuItem(), "the menu item is invocable again")
        try expect(supervisor.records[f.agentId]?.workspaceToolsEnabled == true && agentTile.qaWorkspaceToolsMenuEntry()?.isOn == true,
                   "re-checking restores the record and the checkmark")
        _ = try result(context(f), "context after the menu restored access")
        agentTile.detach()

        // W28/W20 — revocation: flipping the policy off during the approval prompt
        // denies before any effect; afterwards even context is denied without leaks.
        let tilesBeforeRevoke = f.canvas.allWorkspaceTiles().count
        f.api.approvalHandler = { _ in
            _ = supervisor.setWorkspaceToolsEnabled(agentID: f.agentId, false)
            return .allowOnce
        }
        let revokedMidPrompt = try error(open(f, ["relativePath": "notes.md", "checkoutHandle": f.pcHandle.rawValue]), .permissionDenied, "revoked during prompt")
        try expect(revokedMidPrompt.approvalRequestId != nil && f.canvas.allWorkspaceTiles().count == tilesBeforeRevoke, "revocation mid-prompt applies nothing")
        let contextDenied = try error(context(f), .permissionDenied, "context after revocation")
        try expect(!contextDenied.message.contains("/") && contextDenied.message.range(of: "[0-9A-Fa-f]{8}-", options: .regularExpression) == nil,
                   "a revoked caller learns no identifiers: \(contextDenied.message)")
        _ = try error(open(f, ["relativePath": "notes.md"]), .permissionDenied, "own-checkout open after revocation")
        try expect(f.api.qaGrants(for: f.agentId).isEmpty, "revocation dropped every minted grant")
        // Re-enable: the preset is re-seeded, but the session approval for Pa is gone.
        try expect(supervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true), "re-enable")
        _ = try result(open(f, ["relativePath": "notes.md", "presentation": ["camera": "preserve"]]), "own open after re-enable")
        f.api.approvalHandler = { _ in .deny }
        _ = try error(open(f, ["relativePath": "notes.md", "checkoutHandle": f.paHandle.rawValue]), .permissionDenied, "Pa needs approval again after revocation")
    }
}

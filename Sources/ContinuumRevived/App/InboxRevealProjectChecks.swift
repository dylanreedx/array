import AppKit
import ContinuumRevivedCore
import Foundation

/// M1.6 (`.plans/46`) — revealing an agent from the inbox puts its tile in the
/// agent's OWN project.
///
/// `attachTileToAgentFromInbox` used the app-wide `tileSpawner`, and its own doc
/// comment said the honest thing: *"giving the agent's own project a tile needs a
/// per-project spawner, which is an architectural change no packet has asked
/// for."* M1.3b is that change, so this ticket comes after it. The old code
/// logged the mismatch on stderr and then committed it: the tile was framed
/// against the active zone, installed into the active project's layer, and
/// persisted into the active project's `canvas.json`, while the agent's record —
/// its cwd, its project, its row chip — went on naming a different project.
///
/// **Two things had to move together.** `spawnManagedAgent` frames and installs
/// against `creationScopeProvider()?.zoneId`, so handing it the right *store*
/// while leaving the active zone in place would install the tile into one
/// project's layer and persist it into another's — a worse mismatch than the one
/// being fixed. The reveal therefore overrides the creation scope for the
/// duration of the spawn as well as choosing the spawner.
///
/// **The witness is behavioural, and that is the point of it.** The existing
/// coverage of this method is a source scan (`TileSpawner.swift:1841-1844`)
/// asserting the body still *contains* `spawnManagedAgentForExistingAgent(` —
/// which is precisely the failure mode this program exists to stop: it stays
/// green while a reviewer inverts the behaviour. This leg drives the real
/// `revealAgentFromInbox` and asserts which project's layer the tile landed in
/// and which project's `canvas.json` it was written to.
///
/// **It does not extend `--cross-project-agents-check`.** That leg's
/// discriminating property is having no canvas, no `WorkspaceRuntime`, no
/// spawner and no controller; adding a canvas-dependent assertion would destroy
/// the thing it guards.
@MainActor
enum InboxRevealProjectChecks {
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

        let workspaceWA = UUID(uuidString: "00000000-0000-0000-0000-0000000A1601")!
        let projectPa = UUID(uuidString: "00000000-0000-0000-0000-0000000A1602")!
        let projectPb = UUID(uuidString: "00000000-0000-0000-0000-0000000A1603")!
        let zoneZa = UUID(uuidString: "00000000-0000-0000-0000-0000000A1604")!
        let zoneZb = UUID(uuidString: "00000000-0000-0000-0000-0000000A1605")!

        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-inbox-reveal-project-\(UUID().uuidString)", isDirectory: true)
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
        let emptyCanvas = CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil)
        try storePa.saveProject(projectPaObj)
        try storePa.saveCanvas(emptyCanvas)
        try storePb.saveProject(projectPbObj)
        try storePb.saveCanvas(emptyCanvas)

        func placement(_ zone: UUID, project: UUID, x: Double, color: String) -> ZonePlacement {
            ZonePlacement(
                zoneId: zone, projectId: project,
                origin: ZonePoint(x: x, y: 0), size: ZoneSize(width: 500, height: 400),
                color: color, collapsed: false, hydrationPolicy: .automatic
            )
        }
        // Pa is ACTIVE. Pb is the agent's project, live but not active — the case
        // the old code could not serve and logged its way past.
        let docA = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            zones: [placement(zoneZa, project: projectPa, x: 0, color: "blue"),
                    placement(zoneZb, project: projectPb, x: 560, color: "green")],
            zoneZOrder: [zoneZa, zoneZb],
            lastActiveZoneId: zoneZa
        )
        try WorkspaceStore(workspaceId: workspaceWA, applicationSupportDirectory: appSupport).save(docA)

        var appRegistry = Registry.empty()
        appRegistry.lastActiveWorkspaceId = workspaceWA
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

        let canvas = CanvasNSView(
            canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                                     tiles: [], groups: [], lastActiveTileId: nil),
            activeZone: nil, zoneRenderModels: [], showsZoneChrome: false
        )
        canvas.frame = CGRect(x: 0, y: 0, width: 2000, height: 1200)

        let delegate = AppDelegate()
        let runtime = WorkspaceRuntime(
            workspaceId: workspaceWA,
            document: docA,
            registry: zoneRegistry,
            focusBroker: delegate.qaFocusBroker,
            registryStore: registryStore,
            ghostty: nil,
            browserEngine: browserEngine
        )
        delegate.qaPrepareForOfflineSceneCheck(
            canvas: canvas, browserEngine: browserEngine, runtime: runtime, registryStore: registryStore
        )
        try runtime.install(into: canvas, appRegistry: appRegistry)
        canvas.layoutSubtreeIfNeeded()

        try expect(canvas.installedZoneLayerIds.contains(zoneZa) && canvas.installedZoneLayerIds.contains(zoneZb),
                   "precondition: both zones must be live; installed: \(canvas.installedZoneLayerIds)")

        // A headless agent in Pb: a record, a project, and NO tile. This is what an
        // orchestrator-spawned agent looks like in the inbox.
        let supervisor = delegate.qaAgentSupervisor
        let agentID = supervisor.spawn(
            role: nil,
            prompt: nil,
            cwd: pbRoot,
            model: "anthropic/claude-sonnet-4-5",
            thinking: "off",
            projectId: projectPb,
            projectRoot: pbRoot,
            tileId: nil
        )
        try expect(supervisor.records[agentID]?.tileId == nil,
                   "precondition: the agent must start with no tile")

        // The real production entry point, not a private helper.
        try expect(delegate.revealAgentFromInbox(agentID.rawValue),
                   "revealAgentFromInbox must succeed — P3.9's negative-test ledger (item 7) "
                   + "explicitly rejects refusing a cross-project reveal, because that would make "
                   + "the click a no-op for exactly the agents an orchestrator spawns")
        canvas.layoutSubtreeIfNeeded()

        guard let tileId = supervisor.records[agentID]?.tileId else {
            throw Failure(message: "the reveal must have bound a tile to the agent")
        }

        // Where the tile LANDED.
        let landedZone = canvas.zoneId(containing: tileId)
        try expect(landedZone == zoneZb,
                   "the revealed tile must land in the AGENT'S zone (Zb, project Pb), not in the "
                   + "active zone (Za, project Pa); it landed in "
                   + "\(landedZone.map { $0 == zoneZa ? "Za/Pa" : $0.uuidString } ?? "no zone")")

        // Where the tile was PERSISTED. The layer and the file must agree — using the
        // right store with the active zone still in place would split them, which is
        // worse than the original defect and would satisfy a layer-only assertion.
        let pbTiles = ((try? storePb.tryLoadCanvas()) ?? nil)?.tiles ?? []
        let paTiles = ((try? storePa.tryLoadCanvas()) ?? nil)?.tiles ?? []
        try expect(pbTiles.contains { $0.id == tileId },
                   "the revealed tile must be written into Pb's canvas.json; it holds "
                   + "\(pbTiles.count) tile(s) and none of them is it")
        try expect(!paTiles.contains { $0.id == tileId },
                   "the revealed tile must NOT be written into the active project Pa's canvas.json; "
                   + "it holds \(paTiles.count) tile(s) including this one")

        // The record is untouched by where its view went — that was true before and
        // must stay true.
        try expect(supervisor.records[agentID]?.projectId == projectPb,
                   "the agent's own record must still name its own project")
        try expect(canvas.tileView(for: tileId) is ManagedAgentTileNSView,
                   "the revealed tile must be a live managed agent tile; got "
                   + "\(String(describing: canvas.tileView(for: tileId).map { type(of: $0) }))")
        try expect(supervisor.agent(forTile: tileId) == agentID,
                   "the revealed tile must be bound to THIS agent, not to a freshly minted one")

        print("InboxRevealProjectChecks: a headless agent revealed from the inbox landed in its own "
              + "project's zone and was persisted to its own project's canvas, not the active one")
    }
}

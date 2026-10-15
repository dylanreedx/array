import AppKit
import ContinuumRevivedCore
import Foundation

/// `--floating-toolbar-agent-spawn-check` — the in-canvas toolbar's agent menu
/// (Claude Code / Codex / Pi) must put exactly one managed agent tile inside the
/// ARMED zone, in a multi-project workspace, for every harness.
///
/// **The report (0.7.27).** In a multi-project workspace every choice from the
/// toolbar's agent menu failed with "The operation couldn't be completed.
/// (ContinuumRevived.TileSpawner.SpawnError error 2.)": `canvasUnavailable`, bridged
/// to NSError with no description, so the person read an enum ordinal.
///
/// Drives the production seams only: `mountWorkspaceSceneAtBoot` (never
/// `install(into:)`), the click-arming route the canvas fires, and
/// `handleFloatingToolbarSelection` — the method `FloatingToolbarHostView.onSelection`
/// calls. The assertion is the tile's WORLD frame against the zone's world rect,
/// because a zone-stamp-only assertion stays green through a frame/install split.
@MainActor
enum FloatingToolbarAgentSpawnChecks {
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

        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-00000000F701")!
        let projectA = UUID(uuidString: "00000000-0000-0000-0000-00000000F702")!
        let projectB = UUID(uuidString: "00000000-0000-0000-0000-00000000F703")!
        let zoneA = UUID(uuidString: "00000000-0000-0000-0000-00000000F704")!
        let zoneB = UUID(uuidString: "00000000-0000-0000-0000-00000000F705")!
        let seedNote = UUID(uuidString: "00000000-0000-0000-0000-00000000F706")!

        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("toolbar-agent-spawn-\(UUID().uuidString)", isDirectory: true)
        let rootA = tempRoot.appendingPathComponent("Alpha", isDirectory: true)
        let rootB = tempRoot.appendingPathComponent("Beta", isDirectory: true)
        let appSupport = tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        for dir in [rootA, rootB, appSupport] {
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
        let projectAObj = makeProject(id: projectA, name: "Alpha", root: rootA)
        let projectBObj = makeProject(id: projectB, name: "Beta", root: rootB)
        let storeA = ProjectStore(projectRoot: rootA)
        let storeB = ProjectStore(projectRoot: rootB)

        var seedTile = Tile(
            id: seedNote, kind: .note, title: "seed",
            frame: TileFrame(x: 640, y: 240, width: 220, height: 140),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: TileMetadata(noteId: seedNote)
        )
        seedTile.zoneId = zoneA
        try storeA.saveProject(projectAObj)
        try storeA.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [seedTile], groups: [], lastActiveTileId: seedNote))
        try storeB.saveProject(projectBObj)
        try storeB.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [], groups: [], lastActiveTileId: nil))

        // Both zones on screen at mount, at NON-ZERO, different origins, so a frame
        // computed against the wrong zone is arithmetically visible. The SECOND
        // project's zone is the one armed at boot, as in the reported workspace.
        func placement(_ zone: UUID, project: UUID, x: Double, color: String) -> ZonePlacement {
            ZonePlacement(
                zoneId: zone, projectId: project,
                origin: ZonePoint(x: x, y: 200), size: ZoneSize(width: 800, height: 700),
                color: color, collapsed: false, hydrationPolicy: .automatic
            )
        }
        let document = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            zones: [placement(zoneA, project: projectA, x: 100, color: "blue"),
                    placement(zoneB, project: projectB, x: 1_100, color: "purple")],
            zoneZOrder: [zoneA, zoneB],
            lastActiveZoneId: zoneB
        )
        try WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: appSupport).save(document)

        var appRegistry = Registry.empty()
        appRegistry.lastActiveWorkspaceId = workspaceId
        appRegistry.workspaces = [
            WorkspaceEntry(id: workspaceId, name: "Default", projectIds: [projectA, projectB],
                           createdAt: now, updatedAt: now)
        ]
        appRegistry.projects = [
            ProjectEntry(id: projectA, name: "Alpha", rootPath: rootA.path, workspaceId: workspaceId,
                         lastOpenedAt: now, pinned: false, missing: false),
            ProjectEntry(id: projectB, name: "Beta", rootPath: rootB.path, workspaceId: workspaceId,
                         lastOpenedAt: now, pinned: false, missing: false)
        ]
        let registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        try registryStore.save(appRegistry)

        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }

        let zoneRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { projectId in
            if projectId == projectA {
                return ZoneRuntimeController(projectRoot: rootA, projectStore: storeA, project: projectAObj)
            }
            if projectId == projectB {
                return ZoneRuntimeController(projectRoot: rootB, projectStore: storeB, project: projectBObj)
            }
            throw Failure(message: "unexpected projectId in factory: \(projectId)")
        })

        // Production boots on the remembered project's canvas. Here that is Alpha.
        let bootCanvasState = try storeA.loadCanvas()
        let canvas = CanvasNSView(
            canvasState: bootCanvasState,
            activeZone: document.zones.first(where: { $0.projectId == projectA }),
            zoneRenderModels: document.zones.map {
                CanvasNSView.ZoneRenderModel(placement: $0, displayName: $0.name.isEmpty ? "Zone" : $0.name)
            }
        )
        canvas.frame = CGRect(x: 0, y: 0, width: 2000, height: 1200)

        let delegate = AppDelegate()
        let runtime = WorkspaceRuntime(
            boot: try zoneRegistry.acquire(projectId: projectA),
            workspaceId: workspaceId,
            document: document,
            registry: zoneRegistry,
            focusBroker: delegate.qaFocusBroker,
            registryStore: registryStore,
            ghostty: nil,
            browserEngine: browserEngine
        )
        delegate.qaPrepareForBootMountCheck(
            canvas: canvas, browserEngine: browserEngine, runtime: runtime, registryStore: registryStore)
        let bootSpawner = TileSpawner(
            canvasView: canvas, ghostty: nil, browserEngine: browserEngine,
            projectStore: storeA, project: projectAObj
        )

        // No real CLI ever starts: scripted runners, a private agent store, the QA
        // catalogue, and an in-process (argument-domain) ambient selection.
        guard let claudeModel = AgentCatalogQAFixture.claude.defaultModel else {
            throw Failure(message: "the QA claude fixture has no default model")
        }
        let unpin = AgentCatalogQAFixture.pinAmbientSelection(harness: .claudeCode, model: claudeModel)
        defer { unpin() }
        for harness in [AgentHarness.claudeCode, .codex, .pi] {
            AgentModelCatalog.shared.apply(readiness: .ready, for: harness)
        }
        delegate.agentSupervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: tempRoot.appendingPathComponent("Agents", isDirectory: true)),
            makeRunner: { _ in ScriptedAgentRunner(script: []) })

        try delegate.mountWorkspaceSceneAtBoot(
            canvasView: canvas,
            spawner: bootSpawner,
            projectStore: storeA,
            canvasState: bootCanvasState,
            installsGlobalEventMonitors: false)
        canvas.layoutSubtreeIfNeeded()

        func spawnFromToolbar(_ harness: AgentHarness, into zoneId: UUID, project: UUID,
                              root: URL, store: ProjectStore, route: String) throws {
            try expect(delegate.qaResolvedCreationScope?.zoneId == zoneId,
                       "\(route): the creation scope must name the armed zone; got "
                       + "\(String(describing: delegate.qaResolvedCreationScope?.zoneId))")
            let messageBefore = delegate.qaWorkspaceManagementMessage
            let before = Set(canvas.allWorkspaceTiles().map(\.id))
            delegate.handleFloatingToolbarSelection(.agentHarness(harness))
            canvas.layoutSubtreeIfNeeded()
            let spawned = Set(canvas.allWorkspaceTiles().map(\.id)).subtracting(before)
            let message = delegate.qaWorkspaceManagementMessage
            guard let tileId = spawned.first, spawned.count == 1 else {
                throw Failure(message: "\(route): the toolbar's \(harness.rawValue) choice must create "
                              + "exactly one tile; got \(spawned.count). Notification: "
                              + "\(message == messageBefore ? "none" : (message ?? "none"))")
            }
            try expect(canvas.tileView(for: tileId) is ManagedAgentTileNSView,
                       "\(route): the new tile must be a managed agent findable by `tileView(for:)`")
            try expect(canvas.qaZoneMembership(of: tileId) == zoneId,
                       "\(route): the tile must belong to the armed zone; got "
                       + "\(String(describing: canvas.qaZoneMembership(of: tileId)))")
            guard let agentId = delegate.agentSupervisor.agent(forTile: tileId),
                  let record = delegate.agentSupervisor.records[agentId] else {
                throw Failure(message: "\(route): no agent record is bound to the new tile")
            }
            try expect(record.harness == harness,
                       "\(route): the agent must run the harness chosen in the menu; got "
                       + "\(record.harness?.rawValue ?? "none")")
            try expect(record.projectId == project,
                       "\(route): the agent must belong to the armed zone's project; got "
                       + "\(String(describing: record.projectId))")
            try expect(URL(fileURLWithPath: record.cwd).resolvingSymlinksInPath().path
                       == root.resolvingSymlinksInPath().path,
                       "\(route): the agent's Home must be the zone's project root; got \(record.cwd)")
            guard let persisted = try store.loadCanvas().tiles.first(where: { $0.id == tileId }) else {
                throw Failure(message: "\(route): the tile was not persisted into its project's canvas")
            }
            guard let zone = canvas.zonePlacement(for: zoneId) else {
                throw Failure(message: "\(route): the armed zone vanished from the canvas")
            }
            let rect = CanvasEngine.zoneWorldFrame(zone)
            let frame = persisted.frame
            try expect(frame.x >= rect.x - 0.001 && frame.y >= rect.y - 0.001
                       && frame.x + frame.width <= rect.x + rect.width + 0.001
                       && frame.y + frame.height <= rect.y + rect.height + 0.001,
                       "\(route): the tile's WORLD frame (\(frame.x), \(frame.y)) \(frame.width)x\(frame.height) "
                       + "must sit inside the armed zone (\(rect.x), \(rect.y)) \(rect.width)x\(rect.height)")
            print("floating-toolbar-agent-spawn: \(route) -> one \(harness.rawValue) tile inside its zone")
        }

        let harnesses: [AgentHarness] = [.claudeCode, .codex, .pi]
        // The second project's zone, armed by a click.
        delegate.qaActivateZoneByClick(zoneB)
        try expect(runtime.qaArmedZoneId == zoneB, "click must arm Beta's zone")
        for harness in harnesses {
            try spawnFromToolbar(harness, into: zoneB, project: projectB, root: rootB, store: storeB,
                                 route: "Beta zone / \(harness.rawValue)")
        }
        // And the first.
        delegate.qaActivateZoneByClick(zoneA)
        try expect(runtime.qaArmedZoneId == zoneA, "click must arm Alpha's zone")
        for harness in harnesses {
            try spawnFromToolbar(harness, into: zoneA, project: projectA, root: rootA, store: storeA,
                                 route: "Alpha zone / \(harness.rawValue)")
        }

        // ==================================================================
        // THE reported state: a workspace the "+" button made, after a switch.
        //
        // `CanvasNSView.activeZone` is the BOOT zone, written once when the canvas
        // is built and never by a switch. `resolvedCreationScope` fell back to it
        // whenever nothing in the mounted document was armed, so in a fresh
        // workspace the toolbar scoped a new agent to Alpha's zone in the
        // workspace just left: no picker, a spawn into a zone with no layer, a
        // managed session written and withdrawn, and "SpawnError error 2".
        // ==================================================================
        // The picker needs a window to anchor to; this one is never ordered in.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 2000, height: 1200),
            styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = canvas
        delegate.qaAttachWindowForOfflineCheck(window)
        let defaultTileIds = Set(canvas.allWorkspaceTiles().map(\.id))
        delegate.workspaceCreatePromptProvider = { "Untitled Workspace" }
        delegate.qaCreateWorkspaceFromChrome()
        let emptyWorkspaceId = runtime.workspaceId
        try expect(emptyWorkspaceId != workspaceId && runtime.document.zones.isEmpty,
                   "control: the + button must switch into a new, zoneless workspace")
        let beforeEmpty = Set(canvas.allWorkspaceTiles().map(\.id))
        let alphaTilesBefore = try storeA.loadCanvas().tiles.count
        delegate.handleFloatingToolbarSelection(.agentHarness(.claudeCode))
        let refusal = delegate.qaWorkspaceManagementMessage ?? ""
        try expect(!refusal.contains("SpawnError") && !refusal.contains("error 2"),
                   "the toolbar spoke an enum ordinal: \(refusal)")
        try expect(Set(canvas.allWorkspaceTiles().map(\.id)).subtracting(beforeEmpty).isEmpty,
                   "no tile may appear before a project is chosen")
        let alphaTilesAfter = try storeA.loadCanvas().tiles.count
        try expect(alphaTilesAfter == alphaTilesBefore,
                   "the departed workspace's project must be untouched")
        try expect(delegate.qaIsCreationScopePickerPresented,
                   "with nothing to create into, the toolbar must present the project picker")
        try expect(delegate.qaResolvedCreationScope == nil,
                   "a workspace with no zone has nothing to create into; the creation scope resolved to "
                   + "\(String(describing: delegate.qaResolvedCreationScope)) — the boot zone of the "
                   + "workspace just left")

        // Choosing a project the user already keeps in ANOTHER workspace offers its
        // workspace; accepting lands the agent in that project's zone there.
        var conflictOffers = 0
        delegate.qaSetProjectWorkspaceConflictSwitchProvider { _ in conflictOffers += 1; return true }
        try expect(delegate.qaConfirmProjectHomePicker(projectId: projectB, homeRelativePath: nil),
                   "the picker must offer Beta")
        canvas.layoutSubtreeIfNeeded()
        try expect(conflictOffers == 1, "Beta belongs to Default, so picking it must offer Default; offers=\(conflictOffers)")
        try expect(runtime.workspaceId == workspaceId, "accepting the offer must switch to Default")
        let landed = Set(canvas.allWorkspaceTiles().map(\.id)).subtracting(defaultTileIds)
        guard let pickedTile = landed.first, landed.count == 1 else {
            throw Failure(message: "after the pick, exactly one agent tile must land; got \(landed.count). "
                          + "Notification: \(delegate.qaWorkspaceManagementMessage ?? "none")")
        }
        try expect(canvas.qaZoneMembership(of: pickedTile) == zoneB,
                   "the picked agent must land in Beta's zone; got "
                   + "\(String(describing: canvas.qaZoneMembership(of: pickedTile)))")
        guard let persisted = try storeB.loadCanvas().tiles.first(where: { $0.id == pickedTile }),
              let zone = canvas.zonePlacement(for: zoneB) else {
            throw Failure(message: "the picked agent tile was not persisted into Beta's canvas")
        }
        let rect = CanvasEngine.zoneWorldFrame(zone)
        try expect(persisted.frame.x >= rect.x - 0.001 && persisted.frame.y >= rect.y - 0.001
                   && persisted.frame.x + persisted.frame.width <= rect.x + rect.width + 0.001
                   && persisted.frame.y + persisted.frame.height <= rect.y + rect.height + 0.001,
                   "the picked agent's WORLD frame must sit inside Beta's zone")
        print("floating-toolbar-agent-spawn: empty workspace -> the toolbar asked, the pick offered "
              + "Beta's workspace, and one agent landed inside Beta's zone")
    }
}

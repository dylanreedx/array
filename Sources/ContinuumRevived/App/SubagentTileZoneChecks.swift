import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// `--subagent-tile-zone-check` — a subagent opened from its parent's chip lands
/// beside its parent, in the PARENT's zone, whichever zone is armed.
///
/// **The defect.** The chip routes through `revealAgentFromInbox` →
/// `attachTileToAgentFromInbox`, which scoped the spawn with
/// `spawnerAndScope(forProject:)`: the record's project and that project's FIRST
/// zone in the document. A project with two zones therefore sent every child to
/// whichever zone came first — in the dictation film's swarm spike, three
/// children of "Lead" (zone "Checkout fan-out", x 3700+) stacked up in
/// "Checkout review" at x 1040, their lineage tethers stretched across the canvas.
///
/// Drives production only: `mountWorkspaceSceneAtBoot` (never `install(into:)`),
/// the click-arming route, the toolbar's agent spawn for the parent (so the
/// parent's chip closure is the one `wireManagedAgentTile` binds), and the
/// parent tile's own render-action dispatch for the chip click. Asserts the
/// child's persisted WORLD frame against the parent zone's world rect, because a
/// zone stamp stays green through a frame/install split (hazard 9).
@MainActor
enum SubagentTileZoneChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        var localizedDescription: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    private static func describe(_ frame: TileFrame) -> String {
        "(\(Int(frame.x)), \(Int(frame.y))) \(Int(frame.width))x\(Int(frame.height))"
    }

    /// Both auto-layout settings, each from a private suite: with it on, the
    /// post-spawn settle packs a child against its neighbour wherever it was
    /// framed, so only the OFF pass can see whether the frame itself is beside
    /// the parent.
    static func run() throws {
        for autoLayout in [true, false] {
            let suite = "subagent-tile-zone-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else {
                throw Failure(message: "could not open a private defaults suite")
            }
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(autoLayout, forKey: CanvasAutoLayoutConfig.enabledKey)
            try runScenario(autoLayoutDefaults: defaults, mode: autoLayout ? "auto-layout on" : "auto-layout off")
        }
    }

    private static func runScenario(autoLayoutDefaults: UserDefaults, mode: String) throws {
        let fileManager = FileManager.default
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-00000000C401")!
        let projectId = UUID(uuidString: "00000000-0000-0000-0000-00000000C402")!
        // ONE project, two zones — the film's roast-web. Review is first in the
        // document, so "the project's first zone" and "the armed zone" both name
        // it, and a child that follows either rule lands there.
        let zoneReview = UUID(uuidString: "00000000-0000-0000-0000-00000000C403")!
        let zoneFanOut = UUID(uuidString: "00000000-0000-0000-0000-00000000C404")!

        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("subagent-tile-zone-\(UUID().uuidString)", isDirectory: true)
        let root = tempRoot.appendingPathComponent("roast-web", isDirectory: true)
        let appSupport = tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        for dir in [root, appSupport] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? fileManager.removeItem(at: tempRoot) }

        let project = Project(
            id: projectId, name: "roast-web", rootPath: root.path, createdAt: now, updatedAt: now,
            defaultLaunchProfileId: "shell", editorPreference: .auto,
            settings: ProjectSettings(
                restorePolicy: .restoreDescriptors,
                browserStoragePolicy: .perProject,
                terminalClosePolicy: .askWhenRunning
            )
        )
        let store = ProjectStore(projectRoot: root)
        try store.saveProject(project)
        try store.saveCanvas(CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [], groups: [], lastActiveTileId: nil))

        // Non-zero, different origins, so a frame computed against the wrong zone
        // is arithmetically visible. Fan-out has room for a column of children
        // beside the parent.
        let reviewPlacement = ZonePlacement(
            zoneId: zoneReview, projectId: projectId,
            origin: ZonePoint(x: 100, y: 200), size: ZoneSize(width: 900, height: 900),
            color: "blue", collapsed: false, hydrationPolicy: .automatic)
        let fanOutPlacement = ZonePlacement(
            zoneId: zoneFanOut, projectId: projectId,
            origin: ZonePoint(x: 1_300, y: 200), size: ZoneSize(width: 2_600, height: 2_200),
            color: "purple", collapsed: false, hydrationPolicy: .automatic)
        let document = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 0.5),
            zones: [reviewPlacement, fanOutPlacement],
            zoneZOrder: [zoneReview, zoneFanOut],
            lastActiveZoneId: zoneReview
        )
        try WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: appSupport).save(document)

        var appRegistry = Registry.empty()
        appRegistry.lastActiveWorkspaceId = workspaceId
        appRegistry.workspaces = [
            WorkspaceEntry(id: workspaceId, name: "Default", projectIds: [projectId],
                           createdAt: now, updatedAt: now)
        ]
        appRegistry.projects = [
            ProjectEntry(id: projectId, name: "roast-web", rootPath: root.path, workspaceId: workspaceId,
                         lastOpenedAt: now, pinned: false, missing: false)
        ]
        let registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        try registryStore.save(appRegistry)

        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }

        let zoneRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { id in
            guard id == projectId else { throw Failure(message: "unexpected projectId in factory: \(id)") }
            return ZoneRuntimeController(projectRoot: root, projectStore: store, project: project)
        })

        let bootCanvasState = try store.loadCanvas()
        let canvas = CanvasNSView(
            canvasState: bootCanvasState,
            activeZone: reviewPlacement,
            zoneRenderModels: document.zones.map {
                CanvasNSView.ZoneRenderModel(placement: $0, displayName: $0.name.isEmpty ? "Zone" : $0.name)
            }
        )
        canvas.frame = CGRect(x: 0, y: 0, width: 2400, height: 1200)
        canvas.autoLayoutDefaults = autoLayoutDefaults

        let delegate = AppDelegate()
        let runtime = WorkspaceRuntime(
            boot: try zoneRegistry.acquire(projectId: projectId),
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
            projectStore: store, project: project
        )

        // No real CLI ever starts.
        guard let claudeModel = AgentCatalogQAFixture.claude.defaultModel else {
            throw Failure(message: "the QA claude fixture has no default model")
        }
        let unpin = AgentCatalogQAFixture.pinAmbientSelection(harness: .claudeCode, model: claudeModel)
        defer { unpin() }
        AgentModelCatalog.shared.apply(readiness: .ready, for: .claudeCode)
        delegate.agentSupervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: tempRoot.appendingPathComponent("Agents", isDirectory: true)),
            makeRunner: { _ in ScriptedAgentRunner(script: []) })
        let supervisor = delegate.agentSupervisor

        try delegate.mountWorkspaceSceneAtBoot(
            canvasView: canvas,
            spawner: bootSpawner,
            projectStore: store,
            canvasState: bootCanvasState,
            installsGlobalEventMonitors: false)
        canvas.layoutSubtreeIfNeeded()
        try expect(canvas.installedZoneLayerIds.contains(zoneReview) && canvas.installedZoneLayerIds.contains(zoneFanOut),
                   "precondition: both zones must be live; installed: \(canvas.installedZoneLayerIds)")

        // The parent: armed Fan-out, then the toolbar's Claude spawn — the
        // production route that wires the parent tile's chip closure.
        delegate.qaActivateZoneByClick(zoneFanOut)
        try expect(runtime.qaArmedZoneId == zoneFanOut, "precondition: a click must arm Fan-out")
        let beforeParent = Set(canvas.allWorkspaceTiles().map(\.id))
        delegate.handleFloatingToolbarSelection(.agentHarness(.claudeCode))
        canvas.layoutSubtreeIfNeeded()
        guard let parentTile = Set(canvas.allWorkspaceTiles().map(\.id)).subtracting(beforeParent).first,
              let parentView = canvas.tileView(for: parentTile) as? ManagedAgentTileNSView,
              let parentId = supervisor.agent(forTile: parentTile) else {
            throw Failure(message: "precondition: the toolbar must create one wired Claude agent tile")
        }
        try expect(canvas.zoneId(containing: parentTile) == zoneFanOut,
                   "precondition: the parent must sit in Fan-out")

        // The film's state: the user went back and armed Review.
        delegate.qaActivateZoneByClick(zoneReview)
        try expect(runtime.qaArmedZoneId == zoneReview, "precondition: a click must arm Review")

        // Two tileless children, as an Agent tool_use mints them.
        func mintChild(_ name: String) -> AgentID {
            supervisor.spawn(
                role: nil, prompt: nil, cwd: root, harness: .claudeCode,
                model: claudeModel, thinking: "off", projectId: projectId, projectRoot: root,
                parentAgentID: parentId, tileId: nil, displayName: name)
        }
        let children = [mintChild("child-one"), mintChild("child-two")]

        guard let fanOutZone = canvas.zonePlacement(for: zoneFanOut) else {
            throw Failure(message: "Fan-out vanished from the canvas")
        }
        let fanOutRect = CanvasEngine.zoneWorldFrame(fanOutZone)
        var opened: [UUID] = []
        for (index, childId) in children.enumerated() {
            let route = "\(mode), child \(index + 1)"
            // The chip click, through the parent tile's own dispatch.
            guard let blockID = AgentNodeID(rawValue: "subagent-\(index)") else {
                throw Failure(message: "\(route): could not form a block id")
            }
            parentView.qaPerformRenderAction(.revealAgent(
                blockID: blockID,
                agentID: childId.rawValue,
                parentAgentID: parentId.rawValue))
            canvas.layoutSubtreeIfNeeded()
            guard let childTile = supervisor.records[childId]?.tileId else {
                throw Failure(message: "\(route): the chip must open the child in a tile")
            }
            opened.append(childTile)
            try expect(canvas.zoneId(containing: childTile) == zoneFanOut,
                       "\(route): the child must open in its PARENT's zone (Fan-out), not the armed "
                       + "zone or the project's first one; it landed in "
                       + "\(canvas.zoneId(containing: childTile).map { $0 == zoneReview ? "Review" : $0.uuidString } ?? "no zone")")
            guard let persisted = try store.loadCanvas().tiles.first(where: { $0.id == childTile }) else {
                throw Failure(message: "\(route): the child tile was not persisted into its project's canvas")
            }
            let frame = persisted.frame
            try expect(frame.x >= fanOutRect.x - 0.001 && frame.y >= fanOutRect.y - 0.001
                       && frame.x + frame.width <= fanOutRect.x + fanOutRect.width + 0.001
                       && frame.y + frame.height <= fanOutRect.y + fanOutRect.height + 0.001,
                       "\(route): the child's WORLD frame \(describe(frame)) must sit inside the "
                       + "parent's zone \(describe(fanOutRect))")
        }

        // Beside, not merely inside: the first child docks to the parent's right,
        // top-aligned, one tile gap away; the second, finding that spot taken,
        // stacks under it.
        let persisted = try store.loadCanvas().tiles
        guard let parentFrame = persisted.first(where: { $0.id == parentTile })?.frame,
              let first = persisted.first(where: { $0.id == opened[0] })?.frame,
              let second = persisted.first(where: { $0.id == opened[1] })?.frame else {
            throw Failure(message: "the parent and both children must be persisted")
        }
        // The gap is the canvas's tile gap, which auto-layout re-settles to.
        let gap = first.x - (parentFrame.x + parentFrame.width)
        try expect(gap >= 0 && gap <= TileGapResolver.defaultGap * 3 && abs(first.y - parentFrame.y) < 0.5,
                   "\(mode): the first child must open docked beside its parent \(describe(parentFrame)); got \(describe(first))")
        let stackGap = second.y - (first.y + first.height)
        try expect(abs(second.x - first.x) < 0.5 && stackGap >= 0 && stackGap <= TileGapResolver.defaultGap * 3,
                   "\(mode): the second child must stack under the first, beside the parent; first "
                   + "\(describe(first)), second \(describe(second))")

        print("subagent-tile-zone: \(mode): two children opened from the parent's chip landed beside it in its zone, "
              + "with another zone of the same project armed")
    }
}

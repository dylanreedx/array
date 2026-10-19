import AppKit
import ContinuumRevivedCore
import Foundation

/// `--zone-spawn-containment-check` — with canvas auto-layout OFF, a tile the
/// zone places automatically lands inside that zone.
///
/// **The defect.** `TileSpawner.makeProjectTilePlacement` translates the camera
/// into the target zone's local space and clamps only the camera ORIGIN
/// (`clampedZoneLocalViewport`). `TileSpawnPlacement.automatic` then centres or
/// docks the new tile around the camera's centre with no knowledge of the zone's
/// size, so a camera near the zone's right edge framed a 640x520 agent at world
/// x 3376 in a zone ending at 3900. With auto-layout on, the post-spawn settle
/// grows the zone over the tile and hides it; with it off nothing does, and the
/// tile hangs out of its own zone.
///
/// Drives production only: `mountWorkspaceSceneAtBoot` (never `install(into:)`),
/// the click-arming route and the toolbar's agent spawn, repeated until the zone
/// is full. Asserts each tile's persisted WORLD frame against the zone's world
/// content rect (inside the header and padding the auto-layout engine keeps),
/// because a zone stamp stays green through exactly this bug.
@MainActor
enum ZoneSpawnContainmentChecks {
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

    private static func describe(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)), \(Int(rect.minY))) \(Int(rect.width))x\(Int(rect.height))"
    }

    private static func rect(_ frame: TileFrame) -> CGRect {
        CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }

    /// Whether any `size` rect on a 4pt grid fits inside `bounds` without
    /// touching `obstacles`. Edge contact is legal, as in the placement policy.
    private static func hasFreeSlot(size: CGSize, in bounds: CGRect, avoiding obstacles: [CGRect]) -> Bool {
        var y = bounds.minY
        while y + size.height <= bounds.maxY {
            var x = bounds.minX
            while x + size.width <= bounds.maxX {
                let slot = CGRect(origin: CGPoint(x: x, y: y), size: size)
                if !obstacles.contains(where: { $0.intersection(slot).width > 0 && $0.intersection(slot).height > 0 }) {
                    return true
                }
                x += 4
            }
            y += 4
        }
        return false
    }

    static func run() throws {
        try toolbarSpawnsStayInsideTheZone()
        try oversizedTilePinsToTheLeadingEdge()
    }

    /// The decision for a zone with no room at all: a tile is never shrunk, so a
    /// tile bigger than the zone's content keeps its size, starts at the content's
    /// leading edge on the axis that cannot fit and overflows the far edge only.
    /// Pure geometry, so it is asserted on the policy directly.
    private static func oversizedTilePinsToTheLeadingEdge() throws {
        let bounds = CGRect(x: 24, y: 58, width: 400, height: 1_000)
        let frame = TileSpawnPlacement.automatic(TileSpawnPlacement.Context(
            newSize: CGSize(width: 640, height: 520),
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            visibleSize: CGSize(width: 2_400, height: 1_200),
            siblings: [],
            gap: 16,
            bounds: bounds))
        try expect(frame.width == 640 && frame.height == 520,
                   "an oversized tile keeps its working size; got \(describe(frame))")
        try expect(abs(frame.x - bounds.minX) < 0.001,
                   "a tile wider than the zone starts at the content's left edge \(Int(bounds.minX)); got \(describe(frame))")
        try expect(frame.y >= bounds.minY - 0.001 && frame.y + frame.height <= bounds.maxY + 0.001,
                   "on the axis that fits, the tile stays inside \(describe(bounds)); got \(describe(frame))")
    }

    private static func toolbarSpawnsStayInsideTheZone() throws {
        let fileManager = FileManager.default
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let suite = "zone-spawn-containment-\(UUID().uuidString)"
        guard let autoLayoutDefaults = UserDefaults(suiteName: suite) else {
            throw Failure(message: "could not open a private defaults suite")
        }
        defer { autoLayoutDefaults.removePersistentDomain(forName: suite) }
        autoLayoutDefaults.set(false, forKey: CanvasAutoLayoutConfig.enabledKey)

        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-00000000C501")!
        let projectId = UUID(uuidString: "00000000-0000-0000-0000-00000000C502")!
        let zoneId = UUID(uuidString: "00000000-0000-0000-0000-00000000C503")!

        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("zone-spawn-containment-\(UUID().uuidString)", isDirectory: true)
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

        // The observed zone: 2600x1400 at world (1300, 200). A non-zero origin, so
        // a frame persisted in the wrong space is arithmetically visible.
        let placement = ZonePlacement(
            zoneId: zoneId, projectId: projectId,
            origin: ZonePoint(x: 1_300, y: 200), size: ZoneSize(width: 2_600, height: 1_400),
            color: "purple", collapsed: false, hydrationPolicy: .automatic)
        // The camera's centre sits 300pt inside the zone's right edge: on screen,
        // inside the zone, and closer to the edge than half an agent tile.
        let camera = CanvasViewport(x: 2_400, y: 300, zoom: 1)
        let document = WorkspaceDocument(
            viewport: camera, zones: [placement], zoneZOrder: [zoneId], lastActiveZoneId: zoneId)
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
            activeZone: placement,
            zoneRenderModels: [CanvasNSView.ZoneRenderModel(placement: placement, displayName: "Fan-out")]
        )
        canvas.frame = CGRect(x: 0, y: 0, width: 2_400, height: 1_200)
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

        try delegate.mountWorkspaceSceneAtBoot(
            canvasView: canvas,
            spawner: bootSpawner,
            projectStore: store,
            canvasState: bootCanvasState,
            installsGlobalEventMonitors: false)
        canvas.layoutSubtreeIfNeeded()
        try expect(canvas.installedZoneLayerIds.contains(zoneId),
                   "precondition: the zone must be live; installed: \(canvas.installedZoneLayerIds)")
        delegate.qaActivateZoneByClick(zoneId)
        try expect(runtime.qaArmedZoneId == zoneId, "precondition: a click must arm the zone")

        guard let zone = canvas.zonePlacement(for: zoneId) else {
            throw Failure(message: "the zone vanished from the canvas")
        }
        let zoneRect = rect(CanvasEngine.zoneWorldFrame(zone))
        let padding = ZoneBoundsConfig.padding(defaults: autoLayoutDefaults)
        let header = Double(ZoneChromeNSView.headerHeight)
        let content = CGRect(
            x: zoneRect.minX + padding, y: zoneRect.minY + header + padding,
            width: zoneRect.width - 2 * padding, height: zoneRect.height - header - 2 * padding)

        // Five agents. The camera's centre sits on the first, so the next two dock
        // left of it in one row; that row leaves 374pt above and 408pt below, and
        // 608pt to its left, so after three there is no free 640x520 slot in the
        // zone at all (asserted, not assumed). Spawns four and five are the
        // full-zone decision: inside the zone, overlapping as little as the
        // bounded search can, never buried exactly under an existing tile.
        var placed: [TileFrame] = []
        for index in 1...5 {
            let route = "spawn \(index)"
            // The same camera every time, so each spawn presses on the right edge
            // instead of following the previous tile's focus reveal.
            canvas.setViewport(camera)
            let before = Set(canvas.allWorkspaceTiles().map(\.id))
            delegate.handleFloatingToolbarSelection(.agentHarness(.claudeCode))
            canvas.layoutSubtreeIfNeeded()
            let added = Set(canvas.allWorkspaceTiles().map(\.id)).subtracting(before)
            guard added.count == 1, let tileId = added.first else {
                throw Failure(message: "\(route): the toolbar must create exactly one agent tile; created \(added.count)")
            }
            try expect(canvas.zoneId(containing: tileId) == zoneId, "\(route): the tile must be stamped into the zone")
            guard let persisted = try store.loadCanvas().tiles.first(where: { $0.id == tileId }) else {
                throw Failure(message: "\(route): the tile was not persisted into its project's canvas")
            }
            let frame = persisted.frame
            let tileRect = rect(frame)
            try expect(tileRect.minX >= content.minX - 0.001 && tileRect.minY >= content.minY - 0.001
                       && tileRect.maxX <= content.maxX + 0.001 && tileRect.maxY <= content.maxY + 0.001,
                       "\(route): with auto-layout off the tile's WORLD frame \(describe(frame)) must sit inside "
                       + "the zone's content \(describe(content)) (zone \(describe(zoneRect))); its right edge is "
                       + "\(Int(tileRect.maxX)), its bottom \(Int(tileRect.maxY))")
            if index <= 3 {
                // The zone has room: inside must not mean on top of a neighbour.
                let overlapping = placed.first { rect($0).intersects(tileRect) }
                try expect(overlapping == nil,
                           "\(route): the zone has room, so the tile must not overlap \(overlapping.map(describe) ?? "")"
                           + "; got \(describe(frame))")
            } else {
                // No room: overlap is allowed, burying a whole tile is not.
                let buried = placed.first { rect($0).intersection(tileRect).size == tileRect.size }
                try expect(buried == nil,
                           "\(route): in a full zone the tile may overlap a neighbour but must not land exactly "
                           + "on \(buried.map(describe) ?? ""); got \(describe(frame))")
            }
            placed.append(frame)
            if index == 3 {
                try expect(!hasFreeSlot(size: tileRect.size, in: content, avoiding: placed.map(rect)),
                           "precondition: after three agents the zone must have no free 640x520 slot; "
                           + "placed \(placed.map(describe))")
            }
        }
        // Auto-layout is off, so nothing may have grown the zone to cover a tile.
        try expect(canvas.zonePlacement(for: zoneId).map { rect(CanvasEngine.zoneWorldFrame($0)) } == zoneRect,
                   "with auto-layout off the zone must keep its size; it is now "
                   + "\(canvas.zonePlacement(for: zoneId).map { describe(rect(CanvasEngine.zoneWorldFrame($0))) } ?? "gone")")

        print("zone-spawn-containment: five toolbar agents with auto-layout off all landed inside "
              + "\(describe(content)), the last two in a full zone: " + placed.map(describe).joined(separator: ", "))
    }
}

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
        // The group geometry, independent of creation presets: squares as tall
        // as the lead, rows of three at its right, then below, one gap apart.
        let preset = CanvasEngine.defaultFrame(for: .managedAgent)
        let lead = TileFrame(x: 113, y: 227, width: Double(preset.width), height: Double(preset.height))
        let configuredGap = TileGapResolver.resolvedGap()
        let side = TileSpawnPlacement.helperSide(lead: lead, minimum: CanvasEngine.minimumFrame(for: .managedAgent))
        try expect(side == lead.height, "a helper must be as tall as its lead; got \(side) for \(lead.height)")
        try expect(TileSpawnPlacement.helperSide(lead: TileFrame(x: 0, y: 0, width: 300, height: 100),
                                                 minimum: CGSize(width: 320, height: 240)) == 320,
                   "a helper must never be smaller than an agent's minimum")
        for index in 0..<6 {
            let slot = TileSpawnPlacement.helperGroupSlot(index: index, lead: lead, side: side, gap: configuredGap)
            let column = Double(index % 3), row = Double(index / 3)
            try expect(abs(slot.x - (lead.x + lead.width + configuredGap + column * (side + configuredGap))) < 0.001
                       && abs(slot.y - (lead.y + row * (side + configuredGap))) < 0.001
                       && slot.width == side && slot.height == side,
                       "helper slot \(index) must be square in row \(Int(row)), column \(Int(column)) at the lead's right; got \(describe(slot))")
        }
        let taken = TileSpawnPlacement.helperGroupSlot(index: 0, lead: lead, side: side, gap: configuredGap)
        try expect(TileSpawnPlacement.firstFreeHelperSlot(lead: lead, side: side, occupied: [taken], gap: configuredGap)
                   == TileSpawnPlacement.helperGroupSlot(index: 1, lead: lead, side: side, gap: configuredGap),
                   "a taken slot must hand the next helper the following slot")

        for (autoLayout, growth) in [(true, CanvasGrowthDirection.fan), (true, .right), (true, .down), (false, .fan)] {
            let suite = "subagent-tile-zone-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else {
                throw Failure(message: "could not open a private defaults suite")
            }
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(autoLayout, forKey: CanvasAutoLayoutConfig.enabledKey)
            defaults.set(growth.rawValue, forKey: CanvasAutoLayoutConfig.growthKey)
            try runScenario(autoLayoutDefaults: defaults, mode: "\(autoLayout ? "auto-layout on" : "auto-layout off"), growth \(growth.rawValue)")
        }
        try runHelperGroup()
    }

    /// A lead with 1, then 3, then 6 helpers opened from its chip, among
    /// neighbours (`HelperPlacementFixture`). Every helper is a square as tall
    /// as the lead, in spawn order in rows of three at the lead's right, inside
    /// the lead's zone; nothing overlaps; the lead never moves; a neighbour moves
    /// only when the group needs its place, along one axis, and only as far as
    /// gap contact with what pushed it. `CONTINUUM_HELPER_PLACEMENT_STILLS`
    /// names a directory for a still at three helpers.
    private static func runHelperGroup() throws {
        let fixture = try HelperPlacementFixture()
        defer { fixture.close() }
        let canvas = fixture.canvas
        func rect(_ f: TileFrame) -> CGRect { CGRect(x: f.x, y: f.y, width: f.width, height: f.height) }
        func same(_ a: TileFrame, _ b: TileFrame) -> Bool {
            abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
        }
        let gap = TileGapResolver.resolvedGap(defaults: canvas.autoLayoutDefaults)
        let initial = try fixture.persistedFrames()
        guard let lead = initial[fixture.leadTile] else { throw Failure(message: "the lead was not persisted") }
        let side = max(lead.height, Double(CanvasEngine.minimumFrame(for: .managedAgent).height))
        var previous = initial
        let stills = ProcessInfo.processInfo.environment["CONTINUUM_HELPER_PLACEMENT_STILLS"]
        for target in [1, 3, 6] {
            while fixture.helperTiles.count < target { try fixture.surfaceHelper() }
            let stage = "\(target) helper\(target == 1 ? "" : "s")"
            let frames = try fixture.persistedFrames()
            guard let zone = fixture.zoneRect else { throw Failure(message: "\(stage): the zone vanished") }
            try expect(frames[fixture.leadTile].map { same($0, lead) } == true,
                       "\(stage): the lead must not move; was \(describe(lead)), now \(frames[fixture.leadTile].map(describe) ?? "gone")")
            for (index, tile) in fixture.helperTiles.enumerated() {
                guard let f = frames[tile] else { throw Failure(message: "\(stage): helper \(index + 1) was not persisted") }
                try expect(abs(f.width - side) < 0.5 && abs(f.height - side) < 0.5,
                           "\(stage): helper \(index + 1) must be a \(Int(side)) square; got \(describe(f))")
                // Row-major at the lead's right, spawn order.
                let column = Double(index % 3), row = Double(index / 3)
                try expect(abs(f.x - (lead.x + lead.width + gap + column * (side + gap))) < 0.5
                           && abs(f.y - (lead.y + row * (side + gap))) < 0.5,
                           "\(stage): helper \(index + 1) must sit in row \(Int(row) + 1), column \(Int(column) + 1) "
                           + "of the group beside the lead \(describe(lead)); got \(describe(f))")
                try expect(canvas.zoneId(containing: tile) == fixture.zoneId
                           && rect(zone).insetBy(dx: -0.5, dy: -0.5).contains(rect(f)),
                           "\(stage): helper \(index + 1) \(describe(f)) must be inside the lead's zone \(describe(zone))")
            }
            let members = frames.filter { canvas.zoneId(containing: $0.key) == fixture.zoneId }
            try expect(members.count == 1 + fixture.neighbours.count + target,
                       "\(stage): every tile must stay in the lead's zone; \(members.count) of \(1 + fixture.neighbours.count + target) are")
            for (id, f) in members {
                for (other, g) in members where other != id {
                    let overlap = rect(f).intersection(rect(g))
                    try expect(overlap.isNull || overlap.width < 0.5 || overlap.height < 0.5,
                               "\(stage): \(describe(f)) overlaps \(describe(g))")
                }
            }
            for (name, id) in fixture.neighbours {
                guard let was = previous[id], let now = frames[id] else { throw Failure(message: "\(stage): neighbour \(name) vanished") }
                let dx = now.x - was.x, dy = now.y - was.y
                try expect(abs(now.width - was.width) < 0.5 && abs(now.height - was.height) < 0.5,
                           "\(stage): neighbour \(name) must keep its size")
                guard abs(dx) > 0.5 || abs(dy) > 0.5 else { continue }
                try expect(abs(dx) < 0.5 || abs(dy) < 0.5,
                           "\(stage): neighbour \(name) must be pushed along one axis; moved (\(Int(dx)), \(Int(dy)))")
                // Minimal: it stops at gap contact with a tile on the side it was pushed from.
                let pusher = members.contains { other, g in
                    guard other != id else { return false }
                    let overlapX = min(now.x + now.width, g.x + g.width) - max(now.x, g.x) > 0.5
                    let overlapY = min(now.y + now.height, g.y + g.height) - max(now.y, g.y) > 0.5
                    if dx > 0.5 { return overlapY && abs(now.x - (g.x + g.width + gap)) < 0.5 }
                    if dx < -0.5 { return overlapY && abs(g.x - (now.x + now.width + gap)) < 0.5 }
                    if dy > 0.5 { return overlapX && abs(now.y - (g.y + g.height + gap)) < 0.5 }
                    return overlapX && abs(g.y - (now.y + now.height + gap)) < 0.5
                }
                try expect(pusher, "\(stage): neighbour \(name) moved (\(Int(dx)), \(Int(dy))) further than gap contact with what pushed it")
                // Pushed only when the group needed its place.
                try expect(fixture.helperTiles.contains { frames[$0].map { rect($0).intersects(rect(was)) } == true }
                           || members.contains { $0.key != id && rect($0.value).intersects(rect(was)) },
                           "\(stage): neighbour \(name) moved although nothing took its place")
            }
            if target == 3 {
                // No painted lineage path may enter a tile that is not one of its endpoints.
                let edges = fixture.helperTiles.map { (parentTileID: fixture.leadTile, childTileID: $0) }
                canvas.showContextualAgentLineage(edges: edges)
                canvas.layoutSubtreeIfNeeded()
                let paths = canvas.qaLineagePathPointsInCanvasSpace
                try expect(paths.count == 3, "3 helpers: expected 3 painted lineage paths, got \(paths.count)")
                for (pathIndex, points) in paths.enumerated() {
                    let child = fixture.helperTiles[pathIndex]
                    for (id, _) in frames where id != fixture.leadTile && id != child {
                        guard let box = canvas.qaTileRectInCanvasSpace(id)?.insetBy(dx: 1, dy: 1) else { continue }
                        try expect(!points.contains { box.contains($0) },
                                   "3 helpers: the lineage path to helper \(pathIndex + 1) runs through a tile that is not its endpoint (\(describe(frames[id]!)))")
                    }
                }
            }
            if target == 3, let stills {
                try fixture.renderStill(to: URL(fileURLWithPath: stills, isDirectory: true), name: "three-helpers")
            }
            previous = frames
        }
        guard let left = fixture.neighbours.first(where: { $0.name == "left" }),
              let wasLeft = initial[left.id], let nowLeft = try fixture.persistedFrames()[left.id] else {
            throw Failure(message: "the left neighbour vanished")
        }
        try expect(same(wasLeft, nowLeft), "the neighbour left of the lead is clear of the group and must not move; "
                   + "was \(describe(wasLeft)), now \(describe(nowLeft))")
        print("subagent-tile-zone: helper group: 1, 3 and 6 helpers opened as \(Int(side)) squares in rows of three beside "
              + "their lead, in spawn order, inside its zone, pushing neighbours aside by gap contact, nothing overlapping")
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
        // is arithmetically visible. Fan-out has room for two columns of children
        // beside the parent.
        let reviewPlacement = ZonePlacement(
            zoneId: zoneReview, projectId: projectId,
            origin: ZonePoint(x: 100, y: 200), size: ZoneSize(width: 900, height: 900),
            color: "blue", collapsed: false, hydrationPolicy: .automatic)
        let fanOutPlacement = ZonePlacement(
            zoneId: zoneFanOut, projectId: projectId,
            origin: ZonePoint(x: 1_300, y: 200), size: ZoneSize(width: 3_400, height: 2_200),
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
        @discardableResult
        func openFromChip(_ childId: AgentID, index: Int) throws -> UUID {
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
            // The zone as it is NOW: under auto layout it grows to take a child
            // that fans out past its edge (.plans/107).
            let liveRect = canvas.zonePlacement(for: zoneFanOut).map(CanvasEngine.zoneWorldFrame) ?? fanOutRect
            try expect(frame.x >= liveRect.x - 0.001 && frame.y >= liveRect.y - 0.001
                       && frame.x + frame.width <= liveRect.x + liveRect.width + 0.001
                       && frame.y + frame.height <= liveRect.y + liveRect.height + 0.001,
                       "\(route): the child's WORLD frame \(describe(frame)) must sit inside the "
                       + "parent's zone \(describe(liveRect))")
            return childTile
        }
        for (index, childId) in children.enumerated() {
            try openFromChip(childId, index: index)
        }

        // Beside, not merely inside: the first child docks to the parent's right,
        // top-aligned, one tile gap away, as a square as tall as the parent; the
        // second takes the next square of the row.
        let persisted = try store.loadCanvas().tiles
        guard let parentFrame = persisted.first(where: { $0.id == parentTile })?.frame,
              let first = persisted.first(where: { $0.id == opened[0] })?.frame,
              let second = persisted.first(where: { $0.id == opened[1] })?.frame else {
            throw Failure(message: "the parent and both children must be persisted")
        }
        let gap = TileGapResolver.resolvedGap()
        let side = max(parentFrame.height, Double(CanvasEngine.minimumFrame(for: .managedAgent).height))
        for child in [first, second] {
            try expect(abs(child.width - side) < 0.5 && abs(child.height - side) < 0.5,
                       "\(mode): a child opened beside its parent must be a \(Int(side)) square; got \(describe(child))")
        }
        try expect(abs(first.x - (parentFrame.x + parentFrame.width + gap)) < 0.5 && abs(first.y - parentFrame.y) < 0.5,
                   "\(mode): the first child must open docked beside its parent \(describe(parentFrame)); got \(describe(first))")
        let autoLayout = autoLayoutDefaults.bool(forKey: CanvasAutoLayoutConfig.enabledKey)
        let inRow = abs(second.y - first.y) < 0.5 && abs(second.x - (first.x + first.width + gap)) < 0.5
        // Auto layout off moves nothing and keeps the group inside the zone, so
        // a row with no room left continues under the first child.
        let underFirst = !autoLayout && abs(second.x - first.x) < 0.5 && abs(second.y - (first.y + side + gap)) < 0.5
        try expect(inRow || underFirst,
                   "\(mode): the second child must take the next square of the group; first \(describe(first)), second \(describe(second))")

        // A full row. The film's fan-out zone held two children beside its Lead;
        // the third found no free slot, fell back to the zone's automatic
        // placement, whose camera centre sat in the gap between the two children,
        // and opened on top of the Lead. With the camera on that gap, a fourth
        // child still opens in the group, under the first, and nothing overlaps.
        for index in 2..<3 { try openFromChip(mintChild("child-\(index + 1)"), index: index) }
        let zoom = canvas.viewport.zoom
        let gapCentre = CGPoint(x: first.x + first.width + gap / 2, y: first.y + first.height / 2)
        canvas.setViewport(CanvasViewport(
            x: gapCentre.x - canvas.bounds.width / zoom / 2,
            y: gapCentre.y - canvas.bounds.height / zoom / 2,
            zoom: zoom))
        let overflowTile = try openFromChip(mintChild("child-overflow"), index: 3)
        let zoneTiles = try store.loadCanvas().tiles.filter { canvas.zoneId(containing: $0.id) == zoneFanOut }
        func rect(_ frame: TileFrame) -> CGRect { CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height) }
        for tile in zoneTiles {
            for other in zoneTiles where other.id != tile.id {
                let overlap = rect(tile.frame).intersection(rect(other.frame))
                try expect(overlap.isNull || overlap.width < 0.5 || overlap.height < 0.5,
                           "\(mode): \(describe(tile.frame)) overlaps \(describe(other.frame)) after four children opened")
            }
        }
        guard let overflowFrame = zoneTiles.first(where: { $0.id == overflowTile })?.frame else {
            throw Failure(message: "\(mode): the overflow child was not persisted")
        }
        if autoLayout && inRow {
            try expect(abs(overflowFrame.x - first.x) < 0.5 && abs(overflowFrame.y - (first.y + side + gap)) < 0.5,
                       "\(mode): the fourth child must start the second row under the first; first \(describe(first)), "
                       + "fourth \(describe(overflowFrame))")
        }

        print("subagent-tile-zone: \(mode): four square children opened from the parent's chip landed in a row beside it "
              + "in its zone, the fourth starting the next row, with another zone of the same project armed")
    }
}

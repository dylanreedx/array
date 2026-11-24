import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// A lead agent among neighbours, its helpers surfaced from the lead's own chip:
/// the production route (`mountWorkspaceSceneAtBoot`, the toolbar's agent spawn
/// for the lead, the lead tile's render-action dispatch for each chip click).
/// Neighbours are notes spawned at exact world points beside and below the
/// lead, so the helper group has someone to push. One project, one zone,
/// auto layout on, from a private defaults suite.
///
/// `--subagent-tile-zone-check` asserts on it; `renderStill` draws it.
@MainActor
final class HelperPlacementFixture {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    let canvas: CanvasNSView
    let store: ProjectStore
    let zoneId: UUID
    let leadTile: UUID
    /// Beside the lead (where the first helper goes), below the lead (wider
    /// than it, so in the second row's way), at the second row's second slot,
    /// and left of the lead, clear of the group.
    let neighbours: [(name: String, id: UUID)]
    private(set) var helperTiles: [UUID] = []

    private let delegate: AppDelegate
    private let runtime: WorkspaceRuntime
    private let leadView: ManagedAgentTileNSView
    private let leadAgent: AgentID
    private let mint: (String) -> AgentID
    private var cleanups: [() -> Void] = []

    func close() { cleanups.reversed().forEach { $0() }; cleanups = [] }

    init() throws {
        let fileManager = FileManager.default
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-00000000C501")!
        let projectId = UUID(uuidString: "00000000-0000-0000-0000-00000000C502")!
        let zoneId = UUID(uuidString: "00000000-0000-0000-0000-00000000C503")!
        self.zoneId = zoneId
        var cleanups: [() -> Void] = []

        let suite = "helper-placement-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(message: "no private defaults suite") }
        cleanups.append { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: CanvasAutoLayoutConfig.enabledKey)

        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("helper-placement-\(UUID().uuidString)", isDirectory: true)
        let root = tempRoot.appendingPathComponent("team", isDirectory: true)
        let appSupport = tempRoot.appendingPathComponent("AppSupport", isDirectory: true)
        for dir in [root, appSupport] { try fileManager.createDirectory(at: dir, withIntermediateDirectories: true) }
        cleanups.append { try? fileManager.removeItem(at: tempRoot) }

        let project = Project(
            id: projectId, name: "team", rootPath: root.path, createdAt: now, updatedAt: now,
            defaultLaunchProfileId: "shell", editorPreference: .auto,
            settings: ProjectSettings(restorePolicy: .restoreDescriptors, browserStoragePolicy: .perProject,
                                      terminalClosePolicy: .askWhenRunning))
        let store = ProjectStore(projectRoot: root)
        self.store = store
        try store.saveProject(project)
        try store.saveCanvas(CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                                         tiles: [], groups: [], lastActiveTileId: nil))
        let placement = ZonePlacement(
            zoneId: zoneId, projectId: projectId,
            origin: ZonePoint(x: 200, y: 200), size: ZoneSize(width: 2_000, height: 1_600),
            color: "purple", collapsed: false, hydrationPolicy: .automatic)
        let document = WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 0.5), zones: [placement],
            zoneZOrder: [zoneId], lastActiveZoneId: zoneId)
        try WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: appSupport).save(document)
        var registry = Registry.empty()
        registry.lastActiveWorkspaceId = workspaceId
        registry.workspaces = [WorkspaceEntry(id: workspaceId, name: "Default", projectIds: [projectId],
                                              createdAt: now, updatedAt: now)]
        registry.projects = [ProjectEntry(id: projectId, name: "team", rootPath: root.path, workspaceId: workspaceId,
                                          lastOpenedAt: now, pinned: false, missing: false)]
        let registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        try registryStore.save(registry)

        let browserEngine = BrowserEngineContext()
        cleanups.append { browserEngine.shutdown() }
        let zoneRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: { id in
            guard id == projectId else { throw Failure(message: "unexpected projectId \(id)") }
            return ZoneRuntimeController(projectRoot: root, projectStore: store, project: project)
        })
        let bootState = try store.loadCanvas()
        let canvas = CanvasNSView(
            canvasState: bootState, activeZone: placement,
            zoneRenderModels: [CanvasNSView.ZoneRenderModel(placement: placement, displayName: "Team")])
        canvas.frame = CGRect(x: 0, y: 0, width: 2400, height: 1500)
        canvas.autoLayoutDefaults = defaults
        self.canvas = canvas

        let delegate = AppDelegate()
        let runtime = WorkspaceRuntime(
            boot: try zoneRegistry.acquire(projectId: projectId), workspaceId: workspaceId, document: document,
            registry: zoneRegistry, focusBroker: delegate.qaFocusBroker, registryStore: registryStore,
            ghostty: nil, browserEngine: browserEngine)
        delegate.qaPrepareForBootMountCheck(canvas: canvas, browserEngine: browserEngine, runtime: runtime,
                                            registryStore: registryStore)
        let bootSpawner = TileSpawner(canvasView: canvas, ghostty: nil, browserEngine: browserEngine,
                                      projectStore: store, project: project)
        guard let model = AgentCatalogQAFixture.claude.defaultModel else {
            throw Failure(message: "the QA claude fixture has no default model")
        }
        let unpin = AgentCatalogQAFixture.pinAmbientSelection(harness: .claudeCode, model: model)
        cleanups.append(unpin)
        AgentModelCatalog.shared.apply(readiness: .ready, for: .claudeCode)
        delegate.agentSupervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: tempRoot.appendingPathComponent("Agents", isDirectory: true)),
            makeRunner: { _ in ScriptedAgentRunner(script: []) })
        let supervisor = delegate.agentSupervisor
        try delegate.mountWorkspaceSceneAtBoot(canvasView: canvas, spawner: bootSpawner, projectStore: store,
                                               canvasState: bootState, installsGlobalEventMonitors: false)
        canvas.layoutSubtreeIfNeeded()
        delegate.qaActivateZoneByClick(zoneId)

        let before = Set(canvas.allWorkspaceTiles().map(\.id))
        delegate.handleFloatingToolbarSelection(.agentHarness(.claudeCode))
        canvas.layoutSubtreeIfNeeded()
        guard let leadTile = Set(canvas.allWorkspaceTiles().map(\.id)).subtracting(before).first,
              let leadView = canvas.tileView(for: leadTile) as? ManagedAgentTileNSView,
              let leadAgent = supervisor.agent(forTile: leadTile),
              let lead = canvas.tilesInWorldFrames(forZoneId: zoneId)?.first(where: { $0.id == leadTile })?.frame,
              let spawner = runtime.activeController?.tileSpawner else {
            throw Failure(message: "precondition: the toolbar must create one wired lead agent tile in the zone")
        }
        // Neighbours, by their top-left corners.
        let gap = TileGapResolver.resolvedGap(defaults: defaults)
        let note = CanvasEngine.defaultFrame(for: .note)
        let corners: [(String, CGPoint)] = [
            ("beside", CGPoint(x: lead.x + lead.width + gap, y: lead.y)),
            ("below", CGPoint(x: lead.x, y: lead.y + lead.height + gap)),
            ("row-two", CGPoint(x: lead.x + lead.width + gap + lead.height + gap, y: lead.y + lead.height + gap)),
            ("left", CGPoint(x: lead.x - gap - note.width, y: lead.y)),
        ]
        var neighbours: [(String, UUID)] = []
        for (name, corner) in corners {
            let at = CGPoint(x: corner.x + note.width / 2, y: corner.y + note.height / 2)
            guard case let .spawned(_, tileId) = spawner.spawnNote(title: name, at: at) else {
                throw Failure(message: "precondition: the \(name) neighbour note did not spawn")
            }
            neighbours.append((name, tileId))
        }
        canvas.layoutSubtreeIfNeeded()

        self.delegate = delegate
        self.runtime = runtime
        self.leadTile = leadTile
        self.leadView = leadView
        self.leadAgent = leadAgent
        self.neighbours = neighbours
        self.mint = { name in
            supervisor.spawn(role: nil, prompt: nil, cwd: root, harness: .claudeCode, model: model, thinking: "off",
                             projectId: projectId, projectRoot: root, parentAgentID: leadAgent, tileId: nil,
                             displayName: name)
        }
        self.cleanups = cleanups
        self.supervisor = supervisor
    }

    private let supervisor: AgentSupervisor

    /// Mint a tileless helper and open it from the lead's chip, as a click does.
    @discardableResult
    func surfaceHelper() throws -> UUID {
        let index = helperTiles.count
        let child = mint("helper-\(index + 1)")
        guard let block = AgentNodeID(rawValue: "subagent-\(index)") else { throw Failure(message: "no block id") }
        leadView.qaPerformRenderAction(.revealAgent(blockID: block, agentID: child.rawValue,
                                                    parentAgentID: leadAgent.rawValue))
        canvas.layoutSubtreeIfNeeded()
        guard let tile = supervisor.records[child]?.tileId else {
            throw Failure(message: "helper \(index + 1): the chip must open the helper in a tile")
        }
        helperTiles.append(tile)
        return tile
    }

    /// World frames of every tile in the zone, from the persisted canvas.
    func persistedFrames() throws -> [UUID: TileFrame] {
        Dictionary(try store.loadCanvas().tiles.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
    }

    var zoneRect: TileFrame? { canvas.zonePlacement(for: zoneId).map(CanvasEngine.zoneWorldFrame) }

    /// The real canvas, framed on the zone, offscreen, in the light and dark
    /// appearances; and beside them a labelled plan of the same world frames.
    func renderStill(to directory: URL, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        if let rect = zoneRect {
            let margin = 80.0
            let zoom = min(Double(canvas.bounds.width) / (rect.width + 2 * margin),
                           Double(canvas.bounds.height) / (rect.height + 2 * margin))
            canvas.setViewport(CanvasViewport(
                x: rect.x + rect.width / 2 - Double(canvas.bounds.width) / zoom / 2,
                y: rect.y + rect.height / 2 - Double(canvas.bounds.height) / zoom / 2, zoom: zoom))
        }
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            canvas.layoutSubtreeIfNeeded()
            CATransaction.flush()
            canvas.display()
            guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { continue }
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("\(name)-canvas-\(suffix).png"), options: .atomic)
        }
        try plan().write(to: directory.appendingPathComponent("\(name)-plan.png"), options: .atomic)
    }

    private func plan() throws -> Data {
        let frames = try persistedFrames()
        guard let zone = zoneRect else { throw Failure(message: "no zone to draw") }
        var bounds = CGRect(x: zone.x, y: zone.y, width: zone.width, height: zone.height)
        for frame in frames.values { bounds = bounds.union(CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)) }
        bounds = bounds.insetBy(dx: -60, dy: -60)
        let scale = 1600 / bounds.width
        let size = CGSize(width: 1600, height: (bounds.height * scale).rounded())
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.white.setFill(); CGRect(origin: .zero, size: size).fill()
            func box(_ f: TileFrame) -> CGRect {
                CGRect(x: (f.x - bounds.minX) * scale, y: (f.y - bounds.minY) * scale,
                       width: f.width * scale, height: f.height * scale)
            }
            let zoneBox = NSBezierPath(roundedRect: box(zone), xRadius: 10, yRadius: 10)
            NSColor.systemPurple.withAlphaComponent(0.06).setFill(); zoneBox.fill()
            NSColor.systemPurple.withAlphaComponent(0.5).setStroke(); zoneBox.lineWidth = 2; zoneBox.stroke()
            var labelled: [(UUID, String, NSColor)] = [(self.leadTile, "lead", .systemBlue)]
            labelled += self.helperTiles.enumerated().map { ($0.element, "helper \($0.offset + 1)", .systemGreen) }
            labelled += self.neighbours.map { ($0.id, "neighbour: \($0.name)", .systemGray) }
            for (id, label, colour) in labelled {
                guard let frame = frames[id] else { continue }
                let path = NSBezierPath(roundedRect: box(frame), xRadius: 6, yRadius: 6)
                colour.withAlphaComponent(0.18).setFill(); path.fill()
                colour.setStroke(); path.lineWidth = 2; path.stroke()
                let text = "\(label)\n\(Int(frame.width))×\(Int(frame.height))" as NSString
                text.draw(at: CGPoint(x: box(frame).minX + 8, y: box(frame).minY + 6),
                          withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                           .foregroundColor: NSColor.black])
            }
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw Failure(message: "could not encode the plan")
        }
        return png
    }
}

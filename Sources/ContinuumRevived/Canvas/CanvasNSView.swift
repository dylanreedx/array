import AppKit
import ContinuumRevivedCore
import Foundation

/// Top-level canvas view: hosts tile subviews, owns the viewport, translates
/// world-space tile frames into AppKit subview frames, and routes pan/zoom
/// gestures to the underlying viewport. Flipped so the y-axis matches the
/// world-space convention (positive y = down).
@MainActor
final class CanvasNSView: NSView {
    weak var delegate: CanvasNSViewDelegate?
    var onFileURLDrop: ((String, CGPoint) -> Void)?
    /// Single-point hook for the app's tile-delete orchestrator. The canvas
    /// wires every installed tile's `onClose` to call this, so the app sets
    /// this once at startup rather than at every TileSpawner install site.
    var onTileCloseRequested: ((UUID) -> Void)?
    weak var focusBroker: FocusBroker? {
        didSet {
            guard oldValue !== focusBroker else { return }
            oldValue?.unregister(focusSurfaceID)
            for view in tileViews.values {
                oldValue?.unregister(view.focusSurfaceID)
            }
            focusBroker?.register(self)
            for view in tileViews.values {
                focusBroker?.register(view)
            }
        }
    }

    struct ZoneRenderModel: Equatable {
        var placement: ZonePlacement
        var displayName: String
    }

    private(set) var canvasState: CanvasState
    /// Active single-zone placement for stage-2 integration. Tile frames remain
    /// persisted zone-local; layout/hit-testing consume world frames through
    /// CanvasEngine. With the default origin (0,0), this is behavior-neutral.
    fileprivate let activeZone: ZonePlacement?
    fileprivate let zoneRenderModels: [ZoneRenderModel]
    private var tileViews: [UUID: TileNSView] = [:]
    private var zoneChromeViews: [UUID: ZoneChromeNSView] = [:]
    private var navModeOverlayView: NavModeOverlayNSView?
    private var emptyStateView: CanvasEmptyStateNSView?
    private var emptyStateActions: CanvasEmptyStateActions?
    private var emptyStateProjectPath: String?
    private(set) var emptyStateInstalled = false

    private var spaceHeld = false
    private var spaceDragLastWindowPoint: CGPoint = .zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(canvasState: CanvasState, activeZone: ZonePlacement? = nil, zoneRenderModels: [ZoneRenderModel] = []) {
        self.canvasState = canvasState
        self.activeZone = activeZone
        if zoneRenderModels.isEmpty, let activeZone {
            self.zoneRenderModels = [ZoneRenderModel(placement: activeZone, displayName: "Project")]
        } else {
            self.zoneRenderModels = zoneRenderModels
        }
        super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.92).cgColor
        registerForDraggedTypes([.fileURL])
        installZoneChromeViews()
        updateEmptyStateVisibility()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func installZoneChromeViews() {
        for model in zoneRenderModels {
            let view = ZoneChromeNSView(model: model)
            zoneChromeViews[model.placement.zoneId] = view
            addSubview(view)
        }
        layoutZoneChromeViews()
    }

    private func layoutZoneChromeViews() {
        for model in zoneRenderModels {
            guard let view = zoneChromeViews[model.placement.zoneId] else { continue }
            let worldFrame = CanvasEngine.zoneWorldFrame(model.placement)
            view.frame = CanvasEngine.tileScreenFrame(worldFrame, viewport: canvasState.viewport)
            view.needsDisplay = true
        }
    }

    // MARK: - Tile management

    func install(tileView: TileNSView, for tile: Tile) {
        // Replacing an existing tile (e.g. restart placeholder → live terminal)
        // must remove the old NSView; otherwise the prior view stays on top
        // of the new one and intercepts hits.
        if let existing = tileViews[tile.id] {
            focusBroker?.unregister(existing.focusSurfaceID)
            existing.removeFromSuperview()
        }
        tileViews[tile.id] = tileView
        tileView.canvas = self
        let tileId = tile.id
        tileView.onClose = { [weak self] in
            self?.onTileCloseRequested?(tileId)
        }
        addSubview(tileView)
        focusBroker?.register(tileView)
        layoutTile(tile)
        if let idx = canvasState.tiles.firstIndex(where: { $0.id == tile.id }) {
            canvasState.tiles[idx] = tile
        } else {
            canvasState.tiles.append(tile)
        }
        updateEmptyStateVisibility()
        reorderTileSubviewsByZIndex()
    }

    func configureEmptyStateActions(_ actions: CanvasEmptyStateActions, projectPath: String? = nil) {
        emptyStateActions = actions
        emptyStateProjectPath = projectPath
        emptyStateView?.actions = actions
        emptyStateView?.projectPath = projectPath
    }

    func detachFocusBroker() {
        guard let focusBroker else { return }
        focusBroker.unregister(focusSurfaceID)
        for view in tileViews.values {
            focusBroker.unregister(view.focusSurfaceID)
        }
        self.focusBroker = nil
    }

    /// Returns the NSView currently registered for `tileId`, or nil. Intended
    /// for tests / smoke-test assertions that need to inspect tile-view kind
    /// (e.g. checking that a runtime-exit handler swapped to a placeholder).
    /// Callers must NOT retain the returned reference — the canvas may swap
    /// the underlying view at any time and a cached pointer will go stale.
    func tileView(for tileId: UUID) -> TileNSView? {
        tileViews[tileId]
    }

    func updateTile(_ tile: Tile) {
        guard let idx = canvasState.tiles.firstIndex(where: { $0.id == tile.id }) else { return }
        canvasState.tiles[idx] = tile
        layoutTile(tile)
        delegate?.canvasDidChange(self)
    }

    /// Remove a tile from the canvas: drops the NSView, the dictionary entry,
    /// and the model-side tile. Per-runtime cleanup (terminate PTY, kill
    /// WKWebView, flush note save, purge descriptor) is the caller's
    /// responsibility — `removeTile` is the canvas-side teardown only.
    func removeTile(id: UUID) {
        if let view = tileViews[id] {
            focusBroker?.unregister(view.focusSurfaceID)
            view.removeFromSuperview()
            tileViews.removeValue(forKey: id)
        }
        canvasState.tiles.removeAll { $0.id == id }
        if canvasState.lastActiveTileId == id {
            canvasState.lastActiveTileId = nil
        }
        updateEmptyStateVisibility()
        delegate?.canvasDidChange(self)
    }

    func markActive(tileId: UUID) {
        canvasState.lastActiveTileId = tileId
        delegate?.canvasDidChange(self)
    }

    func bringToFront(tileId: UUID) {
        let previousActiveTileId = canvasState.lastActiveTileId
        guard let target = canvasState.tiles.first(where: { $0.id == tileId }) else { return }
        let alreadyFrontmost = canvasState.tiles.allSatisfy { tile in
            tile.id == tileId || target.zIndex > tile.zIndex
        }

        canvasState.lastActiveTileId = tileId
        if alreadyFrontmost {
            if previousActiveTileId != tileId {
                delegate?.canvasDidChange(self)
            }
            return
        }

        canvasState.tiles = CanvasEngine.bringToFront(tileId: tileId, in: canvasState.tiles)
        for tile in canvasState.tiles {
            tileViews[tile.id]?.tile = tile
        }
        reorderTileSubviewsByZIndex()
        delegate?.canvasDidChange(self)
    }

    func setViewport(_ viewport: CanvasViewport) {
        canvasState.viewport = viewport
        layoutAllTiles()
        delegate?.canvasDidChange(self)
    }

    var navZoneRenderModels: [ZoneRenderModel] { zoneRenderModels }

    func fitZoneToViewport(zoneId: UUID) -> CanvasViewport? {
        guard let model = zoneRenderModels.first(where: { $0.placement.zoneId == zoneId }) else { return nil }
        let frame = CanvasEngine.zoneWorldFrame(model.placement)
        return CanvasEngine.fit(
            worldRect: CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height),
            viewportSize: bounds.size
        )
    }

    /// Returns the topmost tile id at a screen-space point according to the
    /// semantic canvas model, not AppKit subview insertion order.
    func tileId(at screenPoint: CGPoint) -> UUID? {
        if let activeZone {
            if activeZone.collapsed { return nil }
            let worldPoint = CanvasEngine.screenToWorld(screenPoint, viewport: canvasState.viewport)
            return CanvasEngine.hitTest(
                worldPoint: worldPoint,
                zones: [CanvasEngine.NavigationZone(id: activeZone.zoneId, frame: CanvasEngine.zoneWorldFrame(activeZone), zIndex: 0)],
                tilesByZone: [activeZone.zoneId: canvasState.tiles]
            )?.tile.id
        }
        return CanvasEngine.hitTest(screenPoint: screenPoint, viewport: canvasState.viewport, tiles: canvasState.tiles)?.id
    }

    func zoneId(at screenPoint: CGPoint) -> UUID? {
        let worldPoint = CanvasEngine.screenToWorld(screenPoint, viewport: canvasState.viewport)
        return zoneRenderModels.reversed().first { model in
            let frame = CanvasEngine.zoneWorldFrame(model.placement)
            return worldPoint.x >= frame.x && worldPoint.x <= frame.x + frame.width
                && worldPoint.y >= frame.y && worldPoint.y <= frame.y + frame.height
        }?.placement.zoneId
    }

    func zoneChromeSnapshot(for zoneId: UUID) -> ZoneChromeNSView.Snapshot? {
        zoneChromeViews[zoneId]?.snapshot
    }

    struct NavModeOverlayQASnapshot: Equatable {
        var isInstalled: Bool
        var frame: CGRect
        var selectedTileId: UUID?
        var zoneBadgeCount: Int
        var hitTestPassesThrough: Bool
        var hintLine: String
    }

    func setNavModeOverlayVisible(_ visible: Bool) {
        if visible {
            installNavModeOverlayIfNeeded()
        } else {
            navModeOverlayView?.removeFromSuperview()
            navModeOverlayView = nil
        }
    }

    func navModeOverlayQASnapshot() -> NavModeOverlayQASnapshot {
        let probePoint = CGPoint(x: bounds.midX, y: bounds.midY)
        return NavModeOverlayQASnapshot(
            isInstalled: navModeOverlayView != nil,
            frame: navModeOverlayView?.frame ?? .zero,
            selectedTileId: navModeOverlayView?.selectedTileId,
            zoneBadgeCount: navModeOverlayView?.zoneBadgeCount ?? 0,
            hitTestPassesThrough: navModeOverlayView?.hitTest(probePoint) == nil,
            hintLine: NavModeOverlayNSView.hintLine
        )
    }

    var viewport: CanvasViewport { canvasState.viewport }

    func emptyStateQASnapshot() -> CanvasEmptyStateNSView.QASnapshot? {
        emptyStateView?.qaSnapshot()
    }

    private func reorderTileSubviewsByZIndex() {
        let ordering = NSMutableDictionary()
        for (index, tile) in canvasState.tiles.enumerated() {
            ordering[tile.id.uuidString] = [tile.zIndex, index]
        }
        sortSubviews({ lhs, rhs, context in
            guard
                let ordering = context.map({ Unmanaged<NSMutableDictionary>.fromOpaque($0).takeUnretainedValue() }),
                let lhs = lhs as? TileNSView,
                let rhs = rhs as? TileNSView,
                let lhsInfo = ordering[lhs.tile.id.uuidString] as? [Int],
                let rhsInfo = ordering[rhs.tile.id.uuidString] as? [Int]
            else {
                return .orderedSame
            }
            let lhsZ = lhsInfo[0]
            let rhsZ = rhsInfo[0]
            if lhsZ != rhsZ { return lhsZ < rhsZ ? .orderedAscending : .orderedDescending }
            let lhsOrder = lhsInfo[1]
            let rhsOrder = rhsInfo[1]
            if lhsOrder == rhsOrder { return .orderedSame }
            return lhsOrder < rhsOrder ? .orderedAscending : .orderedDescending
        }, context: Unmanaged.passUnretained(ordering).toOpaque())
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutAllTiles()
        layoutEmptyState()
        layoutNavModeOverlay()
    }

    private func layoutAllTiles() {
        layoutZoneChromeViews()
        for tile in canvasState.tiles {
            layoutTile(tile)
        }
        navModeOverlayView?.needsDisplay = true
    }

    private func layoutTile(_ tile: Tile) {
        guard let view = tileViews[tile.id] else { return }
        let worldFrame = activeZone.map { CanvasEngine.worldFrame(tile: tile, in: $0) } ?? tile.frame
        let rect = CanvasEngine.tileScreenFrame(worldFrame, viewport: canvasState.viewport)
        view.isHidden = activeZone?.collapsed == true
        view.frame = rect
        view.bounds = NSRect(x: 0, y: 0, width: tile.frame.width, height: tile.frame.height)
        view.tile = tile
        view.setNeedsDisplay(view.bounds)
    }

    private func updateEmptyStateVisibility() {
        if canvasState.tiles.isEmpty {
            installEmptyStateIfNeeded()
        } else {
            uninstallEmptyStateIfNeeded()
        }
    }

    private func installEmptyStateIfNeeded() {
        guard emptyStateView == nil else { return }
        let view = CanvasEmptyStateNSView(actions: emptyStateActions, projectPath: emptyStateProjectPath)
        emptyStateView = view
        addSubview(view, positioned: .above, relativeTo: nil)
        emptyStateInstalled = true
        layoutEmptyState()
    }

    private func uninstallEmptyStateIfNeeded() {
        emptyStateView?.removeFromSuperview()
        emptyStateView = nil
        emptyStateInstalled = false
    }

    private func layoutEmptyState() {
        emptyStateView?.frame = bounds
    }

    private func installNavModeOverlayIfNeeded() {
        guard navModeOverlayView == nil else {
            navModeOverlayView?.needsDisplay = true
            return
        }
        let overlay = NavModeOverlayNSView(canvas: self)
        navModeOverlayView = overlay
        addSubview(overlay, positioned: .above, relativeTo: nil)
        layoutNavModeOverlay()
    }

    private func layoutNavModeOverlay() {
        navModeOverlayView?.frame = bounds
        navModeOverlayView?.needsDisplay = true
    }

    // MARK: - Pan / zoom gestures

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let cursor = convert(event.locationInWindow, from: nil)
            // Roughly +/- 10% per logical line of scroll. Smooth, non-linear.
            let factor = exp(event.scrollingDeltaY * 0.02)
            let next = CanvasEngine.zoom(canvasState.viewport, by: factor, anchorScreen: cursor)
            setViewport(next)
        } else {
            var dx = event.scrollingDeltaX
            var dy = event.scrollingDeltaY
            if event.hasPreciseScrollingDeltas {
                dx *= 1
                dy *= 1
            } else {
                dx *= 16
                dy *= 16
            }
            var v = canvasState.viewport
            v.x -= Double(dx) / v.zoom
            v.y -= Double(dy) / v.zoom
            setViewport(v)
        }
    }

    /// Trackpad pinch entry point. The window-level magnify monitor in
    /// ContinuumApp routes here so pinches over a tile body still zoom the
    /// canvas (the tile content has no zoom of its own to compete with).
    func handlePinch(_ event: NSEvent) {
        let cursor = convert(event.locationInWindow, from: nil)
        let factor = 1.0 + Double(event.magnification)
        guard factor > 0 else { return }
        let next = CanvasEngine.zoom(canvasState.viewport, by: factor, anchorScreen: cursor)
        setViewport(next)
    }

    override func mouseDown(with event: NSEvent) {
        if spaceHeld {
            // Space + drag pan: openHand → closedHand on press; pop on
            // mouseUp. Cursor stack restores cleanly even if the cursor
            // rect logic of subviews fights for control.
            NSCursor.closedHand.push()
            spaceDragLastWindowPoint = event.locationInWindow
            return
        }
        // Click on canvas background — deselect.
        canvasState.lastActiveTileId = nil
        delegate?.canvasDidChange(self)
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        if spaceHeld {
            let dx = event.locationInWindow.x - spaceDragLastWindowPoint.x
            let dy = event.locationInWindow.y - spaceDragLastWindowPoint.y
            spaceDragLastWindowPoint = event.locationInWindow
            var v = canvasState.viewport
            // Window y goes up, canvas y is flipped (down). Drag-down on the
            // trackpad/mouse should move the viewport down (revealing tiles
            // higher up), matching the trackpad scroll math in scrollWheel.
            v.x -= Double(dx) / v.zoom
            v.y += Double(dy) / v.zoom
            setViewport(v)
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if spaceHeld {
            NSCursor.pop()
            return
        }
        super.mouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Space (keyCode 49) starts hand-pan mode while held. We only see
        // this event when the canvas itself is first responder, so a Space
        // typed inside a note/terminal/url-bar still inserts a literal
        // space — no global hijack.
        if event.keyCode == 49 {
            if !spaceHeld {
                spaceHeld = true
                NSCursor.openHand.push()
            }
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49, spaceHeld {
            spaceHeld = false
            NSCursor.pop()
            return
        }
        super.keyUp(with: event)
    }

    static func runZIndexRelaunchHitTestSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)

            var description: String {
                switch self {
                case let .failed(message): return message
                }
            }
        }

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        let midId = UUID(uuidString: "00000000-0000-0000-0000-000000000105")!
        let topId = UUID(uuidString: "00000000-0000-0000-0000-000000000199")!
        let lowId = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let overlap = TileFrame(x: 100, y: 100, width: 300, height: 220)
        let seededTiles = [
            Tile(id: midId, kind: .note, title: "MID_FIRST", frame: overlap, zIndex: 5, runtimeRef: nil, metadata: TileMetadata()),
            Tile(id: topId, kind: .note, title: "TOP_MIDDLE", frame: overlap, zIndex: 99, runtimeRef: nil, metadata: TileMetadata()),
            Tile(id: lowId, kind: .note, title: "LOW_LAST", frame: overlap, zIndex: 1, runtimeRef: nil, metadata: TileMetadata())
        ]
        let viewport = CanvasViewport(x: 0, y: 0, zoom: 1)
        let canvas = CanvasNSView(canvasState: CanvasState(viewport: viewport, tiles: seededTiles, groups: [], lastActiveTileId: nil))

        for tile in seededTiles {
            canvas.install(tileView: DescriptorTileNSView(tile: tile), for: tile)
        }
        // Replacement install must not let the replaced/later low-z view jump above max z.
        canvas.install(tileView: DescriptorTileNSView(tile: seededTiles[2]), for: seededTiles[2])

        let modelOrder = canvas.canvasState.tiles.map(\.id)
        let visualOrder = canvas.subviews.compactMap { ($0 as? TileNSView)?.tile.id }
        let visualTopId = visualOrder.last
        let hitPoint = CGPoint(x: 150, y: 150)
        let semanticHitId = CanvasEngine.hitTest(screenPoint: hitPoint, viewport: viewport, tiles: canvas.canvasState.tiles)?.id
        let canvasHitId = canvas.tileId(at: hitPoint)

        try expect(modelOrder == seededTiles.map(\.id), "self-check must preserve seeded model array order")
        try expect(visualTopId == topId, "top AppKit subview should be max zIndex tile")
        try expect(semanticHitId == topId, "CanvasEngine hit-test should return max zIndex tile")
        try expect(canvasHitId == topId, "CanvasNSView tileId(at:) should return max zIndex tile")

        let manifest: [String: Any] = [
            "check": "zindex-relaunch-hit-test",
            "arrayOrder": seededTiles.map { $0.id.uuidString },
            "zIndices": Dictionary(uniqueKeysWithValues: seededTiles.map { ($0.id.uuidString, $0.zIndex) }),
            "visualSubviewOrder": visualOrder.map { $0.uuidString },
            "hitPoint": ["x": hitPoint.x, "y": hitPoint.y],
            "expectedTopId": topId.uuidString,
            "actualVisualTopId": visualTopId?.uuidString as Any,
            "actualCanvasEngineHitId": semanticHitId?.uuidString as Any,
            "actualCanvasViewHitId": canvasHitId?.uuidString as Any
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("zindex-relaunch", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    static func runSingleZoneCompatSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self {
                case let .failed(message): return message
                }
            }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath)
        let tempRoot = root
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent("single-zone-compat-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = tempRoot.appendingPathComponent("project", isDirectory: true)
        let appSupport = tempRoot.appendingPathComponent("app-support", isDirectory: true)
        try fm.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let projectId = UUID(uuidString: "00000000-0000-0000-0000-000000003901")!
        let workspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000003902")!
        let zoneId = UUID(uuidString: "00000000-0000-0000-0000-000000003903")!
        let firstId = UUID(uuidString: "00000000-0000-0000-0000-000000003911")!
        let topId = UUID(uuidString: "00000000-0000-0000-0000-000000003912")!
        let outsideId = UUID(uuidString: "00000000-0000-0000-0000-000000003913")!
        let now = Date(timeIntervalSince1970: 39)
        let project = Project(
            id: projectId,
            name: "Single Zone Compat Fixture",
            rootPath: projectRoot.path,
            createdAt: now,
            updatedAt: now,
            defaultLaunchProfileId: "system-shell",
            editorPreference: .auto,
            settings: ProjectSettings(
                restorePolicy: .restoreDescriptors,
                browserStoragePolicy: .perProject,
                terminalClosePolicy: .askWhenRunning
            )
        )
        let viewport = CanvasViewport(x: 0, y: 0, zoom: 1)
        let preZoneTiles = [
            Tile(id: firstId, kind: .note, title: "legacy-low", frame: TileFrame(x: 40, y: 50, width: 220, height: 140), zIndex: 1, runtimeRef: nil, metadata: TileMetadata()),
            Tile(id: topId, kind: .note, title: "legacy-top", frame: TileFrame(x: 100, y: 90, width: 220, height: 140), zIndex: 9, runtimeRef: nil, metadata: TileMetadata()),
            Tile(id: outsideId, kind: .file, title: "legacy-outside", frame: TileFrame(x: 420, y: 80, width: 160, height: 120), zIndex: 2, runtimeRef: nil, metadata: TileMetadata())
        ]
        let preZoneCanvas = CanvasState(viewport: viewport, tiles: preZoneTiles, groups: [], lastActiveTileId: topId)
        let projectStore = ProjectStore(projectRoot: projectRoot)
        try projectStore.saveProject(project)
        try projectStore.saveCanvas(preZoneCanvas)
        let seededCanvasBytes = try Data(contentsOf: projectStore.layout.canvasFile)

        var registry = Registry.empty()
        let migration = DefaultWorkspaceMigration()
        let actualWorkspaceId = try migration.ensureDefaultWorkspace(
            for: project,
            registry: &registry,
            applicationSupportDirectory: appSupport,
            now: now,
            workspaceId: workspaceId,
            zoneId: zoneId
        )
        let workspace = try WorkspaceStore(workspaceId: actualWorkspaceId, applicationSupportDirectory: appSupport).load()
        try expect(actualWorkspaceId == workspaceId, "expected deterministic default workspace id")
        try expect(registry.lastActiveWorkspaceId == workspaceId, "registry should point at synthesized workspace")
        try expect(registry.lastActiveProjectId == projectId, "registry should preserve active project")
        try expect(workspace.zones.count == 1, "workspace should contain exactly one zone")
        guard let zone = workspace.zones.first else { throw CheckError.failed("missing synthesized zone") }
        try expect(zone.zoneId == zoneId, "expected deterministic single zone id")
        try expect(zone.projectId == projectId, "zone should reference project id")
        try expect(zone.origin == ZonePoint(x: 0, y: 0), "single-zone compatibility requires origin 0,0")
        try expect(workspace.zoneZOrder == [zoneId], "zone z-order should contain only the single zone")
        try expect(workspace.lastActiveZoneId == zoneId, "single zone should be active")

        let loadedCanvas = try projectStore.loadCanvas()
        let canvas = CanvasNSView(canvasState: loadedCanvas, activeZone: zone)
        for tile in preZoneTiles {
            canvas.install(tileView: DescriptorTileNSView(tile: tile), for: tile)
        }
        var frameMatches: [String: Bool] = [:]
        for tile in preZoneTiles {
            let expected = CanvasEngine.tileScreenFrame(tile.frame, viewport: viewport)
            let actual = canvas.tileView(for: tile.id)?.frame
            frameMatches[tile.id.uuidString] = actual == expected
            try expect(actual == expected, "world frame should equal pre-zone frame for \(tile.title); expected \(expected), got \(String(describing: actual))")
        }

        let hitPoint = CGPoint(x: 130, y: 110)
        let legacyHit = CanvasEngine.hitTest(screenPoint: hitPoint, viewport: viewport, tiles: preZoneTiles)?.id
        let zoneHit = CanvasEngine.hitTest(
            worldPoint: CanvasEngine.screenToWorld(hitPoint, viewport: viewport),
            zones: [CanvasEngine.NavigationZone(id: zone.zoneId, frame: CanvasEngine.zoneWorldFrame(zone), zIndex: 0)],
            tilesByZone: [zone.zoneId: preZoneTiles]
        )?.tile.id
        let canvasHit = canvas.tileId(at: hitPoint)
        try expect(legacyHit == topId, "legacy hit-test should target top overlapping tile")
        try expect(zoneHit == legacyHit, "zone-aware hit-test should match legacy hit-test")
        try expect(canvasHit == legacyHit, "CanvasNSView hit-test should match legacy hit-test")

        let controller = ZoneRuntimeController(projectRoot: projectRoot, projectStore: projectStore, project: project)
        controller.canvasView = canvas
        controller.flushCanvasSave()
        let roundTripBytes = try Data(contentsOf: projectStore.layout.canvasFile)
        _ = try projectStore.loadCanvas()
        try expect(roundTripBytes == seededCanvasBytes, "project canvas.json should byte-match after single-zone round trip")

        let directory = tempRoot.appendingPathComponent("artifact", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        let manifest: [String: Any] = [
            "check": "single-zone-compat",
            "projectRoot": projectRoot.path,
            "appSupport": appSupport.path,
            "projectCanvasPath": projectStore.layout.canvasFile.path,
            "workspaceCanvasPath": WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: appSupport).layout.canvasFile.path,
            "workspaceId": workspaceId.uuidString,
            "zoneId": zoneId.uuidString,
            "zoneOrigin": ["x": zone.origin.x, "y": zone.origin.y],
            "tileIds": preZoneTiles.map { $0.id.uuidString },
            "frameMatches": frameMatches,
            "hitPoint": ["x": hitPoint.x, "y": hitPoint.y],
            "legacyHitId": legacyHit?.uuidString as Any,
            "zoneHitId": zoneHit?.uuidString as Any,
            "canvasHitId": canvasHit?.uuidString as Any,
            "projectCanvasByteCountBefore": seededCanvasBytes.count,
            "projectCanvasByteCountAfter": roundTripBytes.count,
            "projectCanvasByteIdentical": roundTripBytes == seededCanvasBytes
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    static func runMultiZoneRenderSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self {
                case let .failed(message): return message
                }
            }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        let alphaProjectId = UUID(uuidString: "00000000-0000-0000-0000-000000004801")!
        let betaProjectId = UUID(uuidString: "00000000-0000-0000-0000-000000004802")!
        let gammaProjectId = UUID(uuidString: "00000000-0000-0000-0000-000000004803")!
        let alphaZoneId = UUID(uuidString: "00000000-0000-0000-0000-000000004811")!
        let betaZoneId = UUID(uuidString: "00000000-0000-0000-0000-000000004812")!
        let gammaZoneId = UUID(uuidString: "00000000-0000-0000-0000-000000004813")!
        let tileId = UUID(uuidString: "00000000-0000-0000-0000-000000004821")!
        let viewport = CanvasViewport(x: 0, y: 0, zoom: 1)
        let alpha = ZonePlacement(zoneId: alphaZoneId, projectId: alphaProjectId, origin: ZonePoint(x: 0, y: 0), size: ZoneSize(width: 640, height: 420), color: "blue", collapsed: false, hydrationPolicy: .automatic)
        let beta = ZonePlacement(zoneId: betaZoneId, projectId: betaProjectId, origin: ZonePoint(x: 760, y: 0), size: ZoneSize(width: 640, height: 420), color: "mint", collapsed: false, hydrationPolicy: .automatic)
        let gamma = ZonePlacement(zoneId: gammaZoneId, projectId: gammaProjectId, origin: ZonePoint(x: 1520, y: 0), size: ZoneSize(width: 640, height: 90), color: "purple", collapsed: true, hydrationPolicy: .automatic)
        let tile = Tile(id: tileId, kind: .note, title: "alpha", frame: TileFrame(x: 40, y: 52, width: 180, height: 120), zIndex: 1, runtimeRef: nil, metadata: TileMetadata())
        let canvas = CanvasNSView(
            canvasState: CanvasState(viewport: viewport, tiles: [tile], groups: [], lastActiveTileId: nil),
            activeZone: alpha,
            zoneRenderModels: [
                ZoneRenderModel(placement: alpha, displayName: "Alpha"),
                ZoneRenderModel(placement: beta, displayName: "Beta"),
                ZoneRenderModel(placement: gamma, displayName: "Gamma")
            ]
        )
        canvas.install(tileView: DescriptorTileNSView(tile: tile), for: tile)
        canvas.layoutSubtreeIfNeeded()

        let alphaTileFrame = canvas.tileView(for: tileId)?.frame
        let expectedAlphaTileFrame = CanvasEngine.tileScreenFrame(CanvasEngine.worldFrame(tile: tile, in: alpha), viewport: viewport)
        try expect(alphaTileFrame == expectedAlphaTileFrame, "expanded zone tile should render at zone origin + tile frame")
        try expect(canvas.tileId(at: CGPoint(x: 50, y: 60)) == tileId, "expanded zone hit-test should reach tile")

        let betaSnap = try expectSnapshot(canvas.zoneChromeSnapshot(for: betaZoneId), "missing beta chrome")
        try expect(betaSnap.displayName == "Beta", "zone name should come from render model")
        try expect(betaSnap.color == "mint", "zone color should be preserved")
        try expect(betaSnap.frame == CanvasEngine.tileScreenFrame(CanvasEngine.zoneWorldFrame(beta), viewport: viewport), "beta chrome should use zone world frame")

        let gammaSnap = try expectSnapshot(canvas.zoneChromeSnapshot(for: gammaZoneId), "missing gamma chrome")
        try expect(gammaSnap.collapsed, "gamma should be marked collapsed")
        try expect(canvas.zoneId(at: CGPoint(x: 1530, y: 10)) == gammaZoneId, "collapsed header should hit-test to zone")
        try expect(canvas.hitTest(CGPoint(x: 770, y: 10)) === canvas, "static zone chrome should pass AppKit hits through to canvas")

        let overlapBottom = ZonePlacement(zoneId: betaZoneId, projectId: betaProjectId, origin: ZonePoint(x: 0, y: 0), size: ZoneSize(width: 200, height: 200), color: "mint", collapsed: false, hydrationPolicy: .automatic)
        let overlapTop = ZonePlacement(zoneId: gammaZoneId, projectId: gammaProjectId, origin: ZonePoint(x: 50, y: 50), size: ZoneSize(width: 200, height: 200), color: "purple", collapsed: false, hydrationPolicy: .automatic)
        let overlapCanvas = CanvasNSView(
            canvasState: CanvasState(viewport: viewport, tiles: [], groups: [], lastActiveTileId: nil),
            activeZone: nil,
            zoneRenderModels: [
                ZoneRenderModel(placement: overlapBottom, displayName: "Bottom"),
                ZoneRenderModel(placement: overlapTop, displayName: "Top")
            ]
        )
        try expect(overlapCanvas.zoneId(at: CGPoint(x: 75, y: 75)) == gammaZoneId, "last render model should be semantic top zone")

        let collapsedCanvas = CanvasNSView(
            canvasState: CanvasState(viewport: viewport, tiles: [tile], groups: [], lastActiveTileId: nil),
            activeZone: gamma,
            zoneRenderModels: [ZoneRenderModel(placement: gamma, displayName: "Gamma")]
        )
        collapsedCanvas.install(tileView: DescriptorTileNSView(tile: tile), for: tile)
        try expect(collapsedCanvas.tileId(at: CGPoint(x: 1560, y: 64)) == nil, "collapsed zone should suppress child hit-testing")
        try expect(collapsedCanvas.zoneId(at: CGPoint(x: 1530, y: 10)) == gammaZoneId, "collapsed zone header should remain targetable")

        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath)
        let directory = root.appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent("multi-zone-render-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        let manifest: [String: Any] = [
            "check": "multi-zone-render",
            "artifactKind": "geometry-snapshot",
            "expandedTileFrame": rectDictionary(alphaTileFrame ?? .zero),
            "expectedExpandedTileFrame": rectDictionary(expectedAlphaTileFrame),
            "betaChromeFrame": rectDictionary(betaSnap.frame),
            "gammaChromeFrame": rectDictionary(gammaSnap.frame),
            "collapsedChildHitSuppressed": true,
            "collapsedHeaderZoneId": gammaZoneId.uuidString,
            "screenshots": "PENDING: deterministic geometry artifact only; no pixel screenshot captured by headless check"
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact

        func expectSnapshot(_ snapshot: ZoneChromeNSView.Snapshot?, _ message: String) throws -> ZoneChromeNSView.Snapshot {
            guard let snapshot else { throw CheckError.failed(message) }
            return snapshot
        }
        func rectDictionary(_ rect: CGRect) -> [String: Double] {
            ["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height]
        }
    }

    static func runTileWorldBoundsSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self {
                case let .failed(message): return message
                }
            }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        final class SizeProbeView: NSView {
            var setFrameSizeCalls = 0
            var observedSizes: [CGSize] = []
            override func setFrameSize(_ newSize: NSSize) {
                setFrameSizeCalls += 1
                observedSizes.append(newSize)
                super.setFrameSize(newSize)
            }
        }
        final class ProbeTileView: TileNSView {
            let probe = SizeProbeView(frame: .zero)
            override init(tile: Tile) {
                super.init(tile: tile)
                setContentView(probe)
            }
            required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        }

        let tile = Tile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001133")!,
            kind: .terminal,
            title: "WORLD_BOUNDS_PROBE",
            frame: TileFrame(x: 40, y: 30, width: 400, height: 240),
            zIndex: 1,
            runtimeRef: nil,
            metadata: TileMetadata()
        )
        let canvas = CanvasNSView(canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [tile], groups: [], lastActiveTileId: nil))
        canvas.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let tileView = ProbeTileView(tile: tile)
        canvas.install(tileView: tileView, for: tile)
        tileView.layoutSubtreeIfNeeded()
        let callsAfterInstall = tileView.probe.setFrameSizeCalls
        tileView.probe.setFrameSizeCalls = 0
        tileView.probe.observedSizes.removeAll()

        let zooms: [Double] = [0.5, 1.0, 2.0]
        var frames: [String: [String: Double]] = [:]
        var bounds: [String: [String: Double]] = [:]
        var edgePasses: [String: Bool] = [:]
        for zoom in zooms {
            canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
            tileView.layoutSubtreeIfNeeded()
            frames[String(zoom)] = ["width": tileView.frame.width, "height": tileView.frame.height]
            bounds[String(zoom)] = ["width": tileView.bounds.width, "height": tileView.bounds.height]
            let m = TileNSView.resizeMargin / CGFloat(zoom)
            let left = tileView.qaResizeEdge(at: CGPoint(x: max(0.25, m / 2), y: tileView.bounds.midY)) == .left
            let right = tileView.qaResizeEdge(at: CGPoint(x: tileView.bounds.width - max(0.25, m / 2), y: tileView.bounds.midY)) == .right
            let center = tileView.qaResizeEdge(at: CGPoint(x: tileView.bounds.midX, y: tileView.bounds.midY)) == nil
            edgePasses[String(zoom)] = left && right && center
            try expect(tileView.bounds.size == CGSize(width: tile.frame.width, height: tile.frame.height), "bounds should remain world-sized at zoom \(zoom)")
        }

        try expect(tileView.probe.setFrameSizeCalls == 0, "content setFrameSize calls during zoom should be zero, got \(tileView.probe.setFrameSizeCalls) sizes=\(tileView.probe.observedSizes)")
        try expect(edgePasses.values.allSatisfy { $0 }, "resize-edge hit tests failed: \(edgePasses)")

        let manifest: [String: Any] = [
            "check": "tile-world-bounds",
            "worldSize": ["width": tile.frame.width, "height": tile.frame.height],
            "zooms": zooms,
            "screenFrames": frames,
            "bounds": bounds,
            "contentSetFrameSizeCallsAfterInstall": callsAfterInstall,
            "contentSetFrameSizeCallsDuringZoom": tileView.probe.setFrameSizeCalls,
            "resizeEdgePasses": edgePasses
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("tile-world-bounds", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    static func runBringToFrontFocusSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)

            var description: String {
                switch self {
                case let .failed(message): return message
                }
            }
        }

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        final class SemanticTypingProbeView: NSView {
            let owner: String
            var typed = ""
            var mouseDownCount = 0
            var mouseUpCount = 0
            var stealFocusWhenAttached = false

            init(owner: String) {
                self.owner = owner
                super.init(frame: .zero)
            }

            required init?(coder: NSCoder) {
                fatalError("init(coder:) is not supported")
            }

            override var acceptsFirstResponder: Bool { true }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if stealFocusWhenAttached, let window {
                    window.makeFirstResponder(self)
                }
            }

            override func mouseDown(with event: NSEvent) {
                mouseDownCount += 1
                window?.makeFirstResponder(self)
            }

            override func mouseUp(with event: NSEvent) {
                mouseUpCount += 1
            }

            override func keyDown(with event: NSEvent) {
                typed += event.charactersIgnoringModifiers ?? ""
            }
        }

        final class ProbeTileNSView: TileNSView {
            let probe: SemanticTypingProbeView

            init(tile: Tile, owner: String) {
                self.probe = SemanticTypingProbeView(owner: owner)
                super.init(tile: tile)
                setContentView(probe)
            }

            required init?(coder: NSCoder) {
                fatalError("init(coder:) is not supported")
            }
        }

        func owner(of responder: NSResponder?) -> String {
            (responder as? SemanticTypingProbeView)?.owner ?? String(describing: responder)
        }

        func dispatchMouse(_ type: NSEvent.EventType, at windowPoint: NSPoint, in window: NSWindow) throws {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            ) else {
                throw CheckError.failed("could not create mouse event \(type)")
            }
            window.sendEvent(event)
        }

        func dispatchKey(_ characters: String, in window: NSWindow) throws {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: 0
            ) else {
                throw CheckError.failed("could not create key event")
            }
            window.sendEvent(event)
        }

        let lowerId = UUID(uuidString: "00000000-0000-0000-0000-000000000401")!
        let upperId = UUID(uuidString: "00000000-0000-0000-0000-000000000402")!
        let lowerFrame = TileFrame(x: 80, y: 80, width: 320, height: 220)
        let upperFrame = TileFrame(x: 140, y: 80, width: 320, height: 220)
        let lower = Tile(id: lowerId, kind: .note, title: "LOWER_PROBE", frame: lowerFrame, zIndex: 1, runtimeRef: nil, metadata: TileMetadata())
        let upper = Tile(id: upperId, kind: .note, title: "UPPER_STEALS_ON_REATTACH", frame: upperFrame, zIndex: 10, runtimeRef: nil, metadata: TileMetadata())
        let viewport = CanvasViewport(x: 0, y: 0, zoom: 1)
        let canvas = CanvasNSView(canvasState: CanvasState(viewport: viewport, tiles: [lower, upper], groups: [], lastActiveTileId: nil))
        canvas.frame = NSRect(x: 0, y: 0, width: 640, height: 480)

        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontRegardless()

        let lowerView = ProbeTileNSView(tile: lower, owner: "lower")
        let upperView = ProbeTileNSView(tile: upper, owner: "upper")
        canvas.install(tileView: lowerView, for: lower)
        canvas.install(tileView: upperView, for: upper)
        upperView.probe.stealFocusWhenAttached = true

        window.contentView?.layoutSubtreeIfNeeded()
        canvas.layoutSubtreeIfNeeded()
        lowerView.layoutSubtreeIfNeeded()
        upperView.layoutSubtreeIfNeeded()

        let overlappedHitPoint = CGPoint(x: 180, y: 120)
        let lowerFocusWindowPoint = lowerView.convert(NSPoint(x: 20, y: TileNSView.titleBarHeight + 20), to: nil)
        try dispatchMouse(.leftMouseDown, at: lowerFocusWindowPoint, in: window)
        try dispatchMouse(.leftMouseUp, at: lowerFocusWindowPoint, in: window)

        let beforeVisualOrder = canvas.subviews.compactMap { ($0 as? TileNSView)?.tile.id }
        let semanticHitBefore = canvas.tileId(at: overlappedHitPoint)
        try expect(beforeVisualOrder.last == upperId, "precondition: upper tile should start visually top")
        try expect(semanticHitBefore == upperId, "precondition: upper tile should start semantic top at overlap")
        try expect(lowerView.probe.mouseDownCount == 1 && lowerView.probe.mouseUpCount == 1, "precondition: lower focus click should route through AppKit mouse dispatch")
        try expect(window.firstResponder === lowerView.probe, "precondition: lower probe should be first responder before bring-to-front")

        let beforeResponderOwner = owner(of: window.firstResponder)
        let beforeZ = Dictionary(uniqueKeysWithValues: canvas.canvasState.tiles.map { ($0.id.uuidString, $0.zIndex) })

        // Operation under test: production bring-to-front only. Do not call any
        // runtime/probe focus repair after this point; that would mask BUG-004.
        canvas.bringToFront(tileId: lowerId)

        let afterVisualOrder = canvas.subviews.compactMap { ($0 as? TileNSView)?.tile.id }
        let afterZ = Dictionary(uniqueKeysWithValues: canvas.canvasState.tiles.map { ($0.id.uuidString, $0.zIndex) })
        let afterResponderOwner = owner(of: window.firstResponder)
        let semanticHitAfter = canvas.tileId(at: overlappedHitPoint)
        let sentinel = "b"
        try dispatchKey(sentinel, in: window)

        try expect(canvas.canvasState.tiles.first(where: { $0.id == lowerId })?.zIndex == (canvas.canvasState.tiles.map(\.zIndex).max() ?? -1), "lower tile should have max zIndex after bring-to-front")
        try expect(afterVisualOrder.last == lowerId, "lower tile should be top AppKit subview after bring-to-front")
        try expect(semanticHitAfter == lowerId, "lower tile should be semantic hit-test top after bring-to-front")
        try expect(window.firstResponder === lowerView.probe, "first responder should remain lower semantic responder; got \(String(describing: window.firstResponder))")
        try expect(lowerView.probe.typed == sentinel, "typed sentinel should route to lower probe through window.sendEvent; got \(lowerView.probe.typed)")
        try expect(upperView.probe.typed.isEmpty, "upper probe should not receive sentinel; got \(upperView.probe.typed)")

        let manifest: [String: Any] = [
            "check": "bring-to-front-focus",
            "lowerTileId": lowerId.uuidString,
            "upperTileId": upperId.uuidString,
            "zIndicesBefore": beforeZ,
            "zIndicesAfter": afterZ,
            "visualSubviewOrderBefore": beforeVisualOrder.map { $0.uuidString },
            "visualSubviewOrderAfter": afterVisualOrder.map { $0.uuidString },
            "overlappedHitPoint": ["x": overlappedHitPoint.x, "y": overlappedHitPoint.y],
            "semanticHitBefore": semanticHitBefore?.uuidString as Any,
            "semanticHitAfter": semanticHitAfter?.uuidString as Any,
            "firstResponderOwnerBefore": beforeResponderOwner,
            "firstResponderOwnerAfter": afterResponderOwner,
            "preBringToFrontFocusMouseDispatch": [
                "windowPoint": ["x": lowerFocusWindowPoint.x, "y": lowerFocusWindowPoint.y],
                "lowerMouseDownCount": lowerView.probe.mouseDownCount,
                "lowerMouseUpCount": lowerView.probe.mouseUpCount
            ],
            "keyDispatch": "window.sendEvent(keyDown)",
            "sentinel": sentinel,
            "lowerTyped": lowerView.probe.typed,
            "upperTyped": upperView.probe.typed
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("bring-to-front-focus", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    // MARK: - File drops

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedFileURL(from: sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = draggedFileURL(from: sender) else {
            return false
        }
        let screenPoint = convert(sender.draggingLocation, from: nil)
        let worldPoint = CanvasEngine.screenToWorld(screenPoint, viewport: canvasState.viewport)
        let spawnPoint = activeZone.map { CanvasEngine.zoneLocalPoint(world: worldPoint, zone: $0) } ?? worldPoint
        onFileURLDrop?(url.path, spawnPoint)
        return true
    }

    private func draggedFileURL(from sender: NSDraggingInfo) -> URL? {
        guard let raw = sender.draggingPasteboard.string(forType: .fileURL) else {
            return nil
        }
        return URL(string: raw)
    }
}

@MainActor
protocol CanvasNSViewDelegate: AnyObject {
    func canvasDidChange(_ canvas: CanvasNSView)
}

@MainActor
final class ZoneChromeNSView: NSView {
    struct Snapshot: Equatable {
        var displayName: String
        var color: String
        var collapsed: Bool
        var frame: CGRect
        var headerRect: CGRect
    }

    private let model: CanvasNSView.ZoneRenderModel
    private let headerHeight: CGFloat = 34

    var snapshot: Snapshot {
        Snapshot(
            displayName: model.displayName,
            color: model.placement.color,
            collapsed: model.placement.collapsed,
            frame: frame,
            headerRect: headerRect
        )
    }

    private var headerRect: CGRect {
        CGRect(x: 0, y: 0, width: bounds.width, height: min(headerHeight, bounds.height))
    }

    override var isFlipped: Bool { true }

    init(model: CanvasNSView.ZoneRenderModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let accent = Self.color(named: model.placement.color)
        let zoneRect = bounds.insetBy(dx: 1, dy: 1)
        accent.withAlphaComponent(model.placement.collapsed ? 0.20 : 0.10).setFill()
        zoneRect.fill()
        accent.withAlphaComponent(0.75).setStroke()
        let path = NSBezierPath(roundedRect: zoneRect, xRadius: 12, yRadius: 12)
        path.lineWidth = 2
        path.stroke()

        accent.withAlphaComponent(0.24).setFill()
        headerRect.fill()
        let title = model.placement.collapsed ? "▸ \(model.displayName)" : model.displayName
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.88)
        ]
        title.draw(in: headerRect.insetBy(dx: 12, dy: 8), withAttributes: attributes)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private static func color(named name: String) -> NSColor {
        switch name.lowercased() {
        case "mint": return NSColor.systemMint
        case "blue": return NSColor.systemBlue
        case "purple": return NSColor.systemPurple
        case "orange": return NSColor.systemOrange
        case "red": return NSColor.systemRed
        case "yellow": return NSColor.systemYellow
        default: return NSColor.systemTeal
        }
    }
}

@MainActor
private final class NavModeOverlayNSView: NSView {
    static let hintLine = "hjkl move · 1-9 zone · z/w pick · ⏎ focus · esc exit"

    private weak var canvas: CanvasNSView?
    private let badgeSize = CGSize(width: 24, height: 24)

    var selectedTileId: UUID? { canvas?.canvasState.lastActiveTileId }
    var zoneBadgeCount: Int { canvas?.zoneRenderModels.count ?? 0 }

    override var isFlipped: Bool { true }

    init(canvas: CanvasNSView) {
        self.canvas = canvas
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let canvas else { return }

        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()

        drawSelectionRing(in: canvas)
        drawZoneBadges(in: canvas)
        drawHintLine()
    }

    private func drawSelectionRing(in canvas: CanvasNSView) {
        guard
            let selectedTileId,
            let tile = canvas.canvasState.tiles.first(where: { $0.id == selectedTileId })
        else { return }

        let worldFrame = canvas.activeZone.map { CanvasEngine.worldFrame(tile: tile, in: $0) } ?? tile.frame
        let screenFrame = CanvasEngine.tileScreenFrame(worldFrame, viewport: canvas.canvasState.viewport).insetBy(dx: -4, dy: -4)
        let path = NSBezierPath(roundedRect: screenFrame, xRadius: 12, yRadius: 12)
        NSColor.controlAccentColor.withAlphaComponent(0.95).setStroke()
        path.lineWidth = 3
        path.stroke()
    }

    private func drawZoneBadges(in canvas: CanvasNSView) {
        for (index, model) in canvas.zoneRenderModels.enumerated() {
            let zoneFrame = CanvasEngine.tileScreenFrame(CanvasEngine.zoneWorldFrame(model.placement), viewport: canvas.canvasState.viewport)
            let rect = CGRect(x: zoneFrame.minX + 10, y: zoneFrame.minY + 8, width: badgeSize.width, height: badgeSize.height)
            let badgePath = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            NSColor.controlAccentColor.withAlphaComponent(0.90).setFill()
            badgePath.fill()
            let text = String(index + 1)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                withAttributes: attributes
            )
        }
    }

    private func drawHintLine() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92)
        ]
        let text = Self.hintLine
        let size = text.size(withAttributes: attributes)
        let padding = CGSize(width: 14, height: 8)
        let rect = CGRect(
            x: bounds.midX - (size.width + padding.width * 2) / 2,
            y: max(12, bounds.maxY - size.height - padding.height * 2 - 18),
            width: size.width + padding.width * 2,
            height: size.height + padding.height * 2
        )
        let background = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        NSColor.black.withAlphaComponent(0.62).setFill()
        background.fill()
        text.draw(at: CGPoint(x: rect.minX + padding.width, y: rect.minY + padding.height), withAttributes: attributes)
    }
}

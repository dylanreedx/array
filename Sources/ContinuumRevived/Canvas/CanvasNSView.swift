import AppKit
import ContinuumRevivedCore
import Foundation

extension Notification.Name {
    /// Posted by `SettingsPanel` after any preference write so live consumers
    /// (e.g. the focus-border overlay) can re-resolve their config.
    static let continuumSettingsChanged = Notification.Name("continuum.settingsChanged")
}

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
    var onTileStopRunRequested: ((UUID) -> Void)?
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
        var agentStatusRollup: AgentStatusRollup = .empty
        var qaVerdict: QARunManifestSnapshot?
    }

    struct AgentStatusRollup: Equatable {
        var working: Int = 0
        var needsAttention: Int = 0
        var done: Int = 0
        var stale: Int = 0

        static let empty = AgentStatusRollup()

        var displayText: String? {
            var parts: [String] = []
            if working > 0 { parts.append("\(working) working") }
            if needsAttention > 0 { parts.append("\(needsAttention) needs you") }
            if done > 0 { parts.append("\(done) done") }
            if stale > 0 { parts.append("\(stale) stale") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    private(set) var canvasState: CanvasState
    /// Active single-zone placement for stage-2 integration. Tile frames remain
    /// persisted zone-local; layout/hit-testing consume world frames through
    /// CanvasEngine. With the default origin (0,0), this is behavior-neutral.
    let activeZone: ZonePlacement?
    fileprivate let zoneRenderModels: [ZoneRenderModel]
    private var tileViews: [UUID: TileNSView] = [:]
    private let showsZoneChrome: Bool
    private var zoneChromeViews: [UUID: ZoneChromeNSView] = [:]
    private var navModeOverlayView: NavModeOverlayNSView?
    var navModeHintLine = NavKeymap.default.hintLine
    private var emptyStateView: CanvasEmptyStateNSView?
    private var emptyStateActions: CanvasEmptyStateActions?
    private var emptyStateProjectPath: String?
    private(set) var emptyStateInstalled = false

    private var spaceHeld = false
    private var spaceDragLastWindowPoint: CGPoint = .zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(
        canvasState: CanvasState,
        activeZone: ZonePlacement? = nil,
        zoneRenderModels: [ZoneRenderModel] = [],
        showsZoneChrome: Bool = ZoneChromeFeature.current
    ) {
        self.canvasState = canvasState
        self.activeZone = activeZone
        self.showsZoneChrome = showsZoneChrome
        if zoneRenderModels.isEmpty, let activeZone {
            self.zoneRenderModels = [ZoneRenderModel(placement: activeZone, displayName: "Project")]
        } else {
            self.zoneRenderModels = zoneRenderModels
        }
        super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.92).cgColor
        registerForDraggedTypes([.fileURL])
        if showsZoneChrome {
            installZoneChromeViews()
        }
        updateEmptyStateVisibility()
        // Live focus-border config: re-apply when Settings writes a preference.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(focusBorderConfigDidChange),
            name: .continuumSettingsChanged,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func installZoneChromeViews() {
        guard showsZoneChrome else { return }
        for model in zoneRenderModels {
            let view = ZoneChromeNSView(model: model)
            zoneChromeViews[model.placement.zoneId] = view
            addSubview(view)
        }
        layoutZoneChromeViews()
    }

    private func layoutZoneChromeViews() {
        guard showsZoneChrome else { return }
        for model in zoneRenderModels {
            guard let view = zoneChromeViews[model.placement.zoneId] else { continue }
            let worldFrame = CanvasEngine.zoneWorldFrame(model.placement)
            view.frame = CanvasEngine.tileScreenFrame(worldFrame, viewport: canvasState.viewport)
            view.needsDisplay = true
        }
    }

    // MARK: - Tile management

    func agentStatus(for tileId: UUID) -> AgentStatus? {
        tileViews[tileId]?.agentStatus
    }

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
        tileView.onStopRun = { [weak self] in
            self?.onTileStopRunRequested?(tileId)
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

    /// Magnetize a dragged tile's free (unsnapped) world frame to nearby tile
    /// edges. Returns the free frame unchanged when drag snapping is disabled,
    /// bypassed (hold `⌘`), or nothing is within the screen-space pull radius.
    /// The drag commits the snapped frame while the caller keeps accumulating the
    /// free frame, so the cursor stays attached. Pure positioning — the math is
    /// `TileArrangement.snapAdjustment`; the pull radius is a constant screen
    /// distance converted to world via `/ zoom`.
    func magnetizedFrame(for freeFrame: TileFrame, excludingTileId id: UUID, bypass: Bool) -> TileFrame {
        guard !bypass, DragMagnetizeConfig.enabled() else { return freeFrame }
        let zoom = viewport.zoom
        guard zoom.isFinite, zoom > 0 else { return freeFrame }
        let others = canvasState.tiles.filter { $0.id != id }.map(\.frame)
        guard !others.isEmpty else { return freeFrame }
        let gap = TileGapResolver.resolvedGap()
        let threshold = DragMagnetizeConfig.snapThresholdScreenPoints / zoom
        return TileArrangement.snapAdjustment(freeFrame, others: others, gap: gap, threshold: threshold).frame
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
        if borderedTileId == id {
            borderedTileId = nil
        }
        updateEmptyStateVisibility()
        delegate?.canvasDidChange(self)
    }

    func markActive(tileId: UUID) {
        canvasState.lastActiveTileId = tileId
        updateFocusBorder(borderedTileId: tileId)
        delegate?.canvasDidChange(self)
    }

    /// Tile currently wearing the marching-ants focus border. Exactly one tile
    /// is bordered at a time; nil when scope is canvas/modal.
    private(set) var borderedTileId: UUID?

    /// Canvas-owned overlay that draws the outset marching-ants border around
    /// the focused tile. Lives on the canvas (not the tile) so the outset path
    /// is not clipped by the tile's `masksToBounds`. Lazily installed as the
    /// topmost subview so it renders above tiles; click-transparent.
    private var focusBorderOverlay: FocusBorderOverlayView?

    /// UserDefaults the focus-border appearance resolves from (`FocusBorderConfig`).
    /// Overridable so `runFocusBorderSelfCheck` can drive enabled/color/gap
    /// deterministically without touching standard defaults.
    var focusBorderDefaults: UserDefaults = .standard

    private func focusBorderOverlayView() -> FocusBorderOverlayView {
        if let overlay = focusBorderOverlay { return overlay }
        let overlay = FocusBorderOverlayView(frame: .zero)
        focusBorderOverlay = overlay
        addSubview(overlay, positioned: .above, relativeTo: nil)
        return overlay
    }

    /// Map a `FocusBorderConfig` color name to an `NSColor` (App layer — Core
    /// stays AppKit-free). Unknown names fall back to the system accent.
    private static func focusBorderColor(named name: String) -> NSColor {
        switch name {
        case "Blue": return .systemBlue
        case "Mint": return .systemMint
        case "Orange": return .systemOrange
        case "Pink": return .systemPink
        default: return .controlAccentColor
        }
    }

    /// Drive the marching-ants overlay so it borders the single `targetId` tile
    /// (or none), clearing any previously-bordered tile. Lockstep entry point
    /// from `markActive` (tile became scope) and `clearFocusBorder` (scope left
    /// all tiles via the FocusBroker canvas/modal hook).
    private func updateFocusBorder(borderedTileId targetId: UUID?) {
        guard borderedTileId != targetId else { return }
        borderedTileId = targetId
        applyFocusBorder()
    }

    /// Resolve `FocusBorderConfig` and show/hide + style the overlay for the
    /// current `borderedTileId`. Re-runnable (no dedupe) so a live config change
    /// re-applies immediately.
    private func applyFocusBorder() {
        let config = FocusBorderConfig.resolvedFromDefaults(defaults: focusBorderDefaults)
        guard config.enabled, let targetId = borderedTileId, let view = tileViews[targetId] else {
            focusBorderOverlay?.hide()
            return
        }
        let overlay = focusBorderOverlayView()
        overlay.configure(
            color: Self.focusBorderColor(named: config.color).withAlphaComponent(0.7),
            gap: CGFloat(config.gap),
            animationDuration: config.speed
        )
        overlay.show(around: view.frame)
        // Keep the overlay topmost — tile installs/reorders can otherwise leave
        // it under later-added tile subviews.
        overlay.removeFromSuperview()
        addSubview(overlay, positioned: .above, relativeTo: nil)
    }

    /// Re-resolve focus-border config and re-apply to the current bordered tile.
    /// Wired to the settings-changed notification so toggling/recoloring the
    /// border in Settings reflects immediately (docs/29 §1 live update).
    @objc func focusBorderConfigDidChange() {
        applyFocusBorder()
    }

    /// Reposition the overlay around `tileId`'s current screen frame if it is
    /// the bordered tile. Called from layout paths so the border tracks the tile
    /// on pan/zoom/move/resize. No-op when `tileId` is not bordered.
    private func repositionFocusBorderIfNeeded(for tileId: UUID) {
        guard tileId == borderedTileId, let view = tileViews[tileId] else { return }
        focusBorderOverlayView().show(around: view.frame)
    }

    /// Clear the focus border when scope leaves all tiles (scope→canvas/modal).
    /// Wired to `FocusBroker.onAcceptedCanvasScope`.
    func clearFocusBorder() {
        updateFocusBorder(borderedTileId: nil)
    }

    /// QA: true when the overlay is visible + animating AND framed around the
    /// bordered tile's outset screen frame. Drives the `--focus-border-check`.
    var qaFocusBorderActive: Bool {
        guard let targetId = borderedTileId,
              let view = tileViews[targetId],
              let overlay = focusBorderOverlay,
              overlay.qaIsAnimating else { return false }
        return overlay.frame == view.frame.insetBy(dx: -overlay.gap, dy: -overlay.gap)
    }

    /// QA: the overlay's current frame (or nil when no tile is bordered).
    var qaFocusBorderFrame: CGRect? {
        guard borderedTileId != nil, let overlay = focusBorderOverlay, !overlay.isHidden else { return nil }
        return overlay.frame
    }

    /// QA: freeze the dash phase for a deterministic offscreen capture.
    func qaFreezeFocusBorder(phase: CGFloat = 0) {
        focusBorderOverlay?.qaFreeze(phase: phase)
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
        discardCursorRects()
        window?.invalidateCursorRects(for: self)
        delegate?.canvasDidChange(self)
    }

    func restoreTileSubviewOrder() {
        reorderTileSubviewsByZIndex()
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

    func fitAllToViewport() -> CanvasViewport? {
        if let zoneBounds = zoneWorldBounds(), zoneBounds.width > 0, zoneBounds.height > 0 {
            return CanvasEngine.fit(worldRect: zoneBounds, viewportSize: bounds.size)
        }
        guard let tileBounds = CanvasEngine.finiteTileBounds(canvasState.tiles), tileBounds.width > 0, tileBounds.height > 0 else { return nil }
        return CanvasEngine.fit(worldRect: tileBounds, viewportSize: bounds.size)
    }

    @discardableResult
    func qaDoubleClickZoneHeaderOrBackground(at screenPoint: CGPoint) -> CanvasViewport? {
        if let zoneId = zoneHeaderZoneId(at: screenPoint), let viewport = fitZoneToViewport(zoneId: zoneId) {
            setViewport(viewport)
            return viewport
        }
        if tileId(at: screenPoint) == nil, let viewport = fitAllToViewport() {
            setViewport(viewport)
            return viewport
        }
        return nil
    }

    func qaZoneHeaderCursorRectCount() -> Int {
        zoneRenderModels.filter { zoneHeaderScreenRect(for: $0.placement) != nil }.count
    }

    private func zoneWorldBounds() -> CGRect? {
        let rects = zoneRenderModels.map { Self.cgRect(from: CanvasEngine.zoneWorldFrame($0.placement)) }
            .filter { $0.origin.x.isFinite && $0.origin.y.isFinite && $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 }
        guard var bounds = rects.first else { return nil }
        for rect in rects.dropFirst() { bounds = bounds.union(rect) }
        return bounds
    }

    private func zoneHeaderZoneId(at screenPoint: CGPoint) -> UUID? {
        zoneRenderModels.reversed().first { model in
            guard let header = zoneHeaderScreenRect(for: model.placement) else { return false }
            return header.contains(screenPoint)
        }?.placement.zoneId
    }

    private func zoneHeaderScreenRect(for placement: ZonePlacement) -> CGRect? {
        let frame = CanvasEngine.tileScreenFrame(CanvasEngine.zoneWorldFrame(placement), viewport: canvasState.viewport)
        guard frame.width > 0, frame.height > 0 else { return nil }
        return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: min(32, frame.height))
    }

    private static func cgRect(from frame: TileFrame) -> CGRect {
        CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
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

    func tileChromeSnapshot(for tileId: UUID) -> TileNSView.ChromeSnapshot? {
        tileViews[tileId]?.chromeSnapshot
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
            hintLine: navModeOverlayView?.hintLine ?? navModeHintLine
        )
    }

    var viewport: CanvasViewport { canvasState.viewport }

    func emptyStateQASnapshot() -> CanvasEmptyStateNSView.QASnapshot? {
        emptyStateView?.qaSnapshot()
    }

    func qaPressEmptyStateButton(titled title: String) -> Bool {
        emptyStateView?.qaPressButton(titled: title) ?? false
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
        // The z-sort only orders tile subviews; keep the focus-border overlay
        // above them so it isn't buried by a brought-to-front tile.
        if let overlay = focusBorderOverlay, !overlay.isHidden {
            overlay.removeFromSuperview()
            addSubview(overlay, positioned: .above, relativeTo: nil)
        }
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
        // Track the focus border with the tile's screen frame on pan/zoom/move/
        // resize — the overlay lives on the canvas, not the tile, so it must be
        // repositioned here whenever the bordered tile's frame updates.
        repositionFocusBorderIfNeeded(for: tile.id)
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
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount >= 2, qaDoubleClickZoneHeaderOrBackground(at: point) != nil {
            return
        }
        // Click on canvas background — deselect.
        canvasState.lastActiveTileId = nil
        delegate?.canvasDidChange(self)
        window?.makeFirstResponder(self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for model in zoneRenderModels {
            if let rect = zoneHeaderScreenRect(for: model.placement) {
                addCursorRect(rect, cursor: .pointingHand)
            }
        }
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
                ZoneRenderModel(placement: beta, displayName: "Beta", qaVerdict: QARunManifestSnapshot(verdict: .passed, check: "matrix", manifestPath: "/tmp/qa/manifest.json", runDirectoryPath: "/tmp/qa", modifiedAt: Date(timeIntervalSince1970: 200))),
                ZoneRenderModel(placement: gamma, displayName: "Gamma")
            ],
            showsZoneChrome: true
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
        try expect(betaSnap.qaVerdictGlyph == "✓", "zone chrome snapshot should expose QA verdict glyph")
        try expect(betaSnap.qaVerdictTooltip?.contains("matrix: passed") == true, "zone chrome snapshot should expose QA verdict tooltip")

        let gammaSnap = try expectSnapshot(canvas.zoneChromeSnapshot(for: gammaZoneId), "missing gamma chrome")
        try expect(gammaSnap.collapsed, "gamma should be marked collapsed")
        try expect(canvas.zoneId(at: CGPoint(x: 1530, y: 10)) == gammaZoneId, "collapsed header should hit-test to zone")
        try expect(canvas.hitTest(CGPoint(x: 770, y: 10)) === canvas, "static zone chrome should pass AppKit hits through to canvas")

        let expectedFitAll = CanvasEngine.fit(worldRect: Self.cgRect(from: CanvasEngine.zoneWorldFrame(alpha)).union(Self.cgRect(from: CanvasEngine.zoneWorldFrame(beta))).union(Self.cgRect(from: CanvasEngine.zoneWorldFrame(gamma))), viewportSize: canvas.bounds.size)
        let fitAll = try expectViewport(canvas.fitAllToViewport(), "fit-all viewport should be available for multi-zone canvas")
        try expect(viewportsNearlyEqual(fitAll, expectedFitAll), "fit-all should frame the union of all zones")
        let headerFit = try expectViewport(canvas.qaDoubleClickZoneHeaderOrBackground(at: CGPoint(x: 770, y: 10)), "double-clicking a zone header should fit that zone")
        try expect(viewportsNearlyEqual(headerFit, CanvasEngine.fit(worldRect: Self.cgRect(from: CanvasEngine.zoneWorldFrame(beta)), viewportSize: canvas.bounds.size)), "header double-click should fit the clicked zone")
        canvas.setViewport(viewport)
        let backgroundFit = try expectViewport(canvas.qaDoubleClickZoneHeaderOrBackground(at: CGPoint(x: 2300, y: 500)), "double-clicking canvas background should fit all zones")
        try expect(viewportsNearlyEqual(backgroundFit, expectedFitAll), "background double-click should fit all zones")
        try expect(canvas.qaZoneHeaderCursorRectCount() == 3, "zone headers should expose cursor affordance rects")

        let overlapBottom = ZonePlacement(zoneId: betaZoneId, projectId: betaProjectId, origin: ZonePoint(x: 0, y: 0), size: ZoneSize(width: 200, height: 200), color: "mint", collapsed: false, hydrationPolicy: .automatic)
        let overlapTop = ZonePlacement(zoneId: gammaZoneId, projectId: gammaProjectId, origin: ZonePoint(x: 50, y: 50), size: ZoneSize(width: 200, height: 200), color: "purple", collapsed: false, hydrationPolicy: .automatic)
        let overlapCanvas = CanvasNSView(
            canvasState: CanvasState(viewport: viewport, tiles: [], groups: [], lastActiveTileId: nil),
            activeZone: nil,
            zoneRenderModels: [
                ZoneRenderModel(placement: overlapBottom, displayName: "Bottom"),
                ZoneRenderModel(placement: overlapTop, displayName: "Top")
            ],
            showsZoneChrome: true
        )
        try expect(overlapCanvas.zoneId(at: CGPoint(x: 75, y: 75)) == gammaZoneId, "last render model should be semantic top zone")

        let collapsedCanvas = CanvasNSView(
            canvasState: CanvasState(viewport: viewport, tiles: [tile], groups: [], lastActiveTileId: nil),
            activeZone: gamma,
            zoneRenderModels: [ZoneRenderModel(placement: gamma, displayName: "Gamma")],
            showsZoneChrome: true
        )
        collapsedCanvas.install(tileView: DescriptorTileNSView(tile: tile), for: tile)
        try expect(collapsedCanvas.tileId(at: CGPoint(x: 1560, y: 64)) == nil, "collapsed zone should suppress child hit-testing")
        try expect(collapsedCanvas.zoneId(at: CGPoint(x: 1530, y: 10)) == gammaZoneId, "collapsed zone header should remain targetable")

        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath)
        let directory = root.appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent("multi-zone-render-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let screenshot = directory.appendingPathComponent("zone-chrome-enabled.png")
        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            throw CheckError.failed("zone chrome screenshot bitmap rep was not created")
        }
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]), !png.isEmpty else {
            throw CheckError.failed("zone chrome screenshot PNG data was empty")
        }
        try png.write(to: screenshot, options: .atomic)
        let screenshotBytes = try Data(contentsOf: screenshot).count
        try expect(screenshotBytes > 0, "zone chrome screenshot should be non-empty")
        let chromePixels = VisualSnapshot.metrics(of: rep)
        try expect(!chromePixels.isBlank, "zone chrome render must not be blank/uniform (the grey-screen guard) — got \(chromePixels.distinctSampledColors) distinct sampled colors at \(chromePixels.width)x\(chromePixels.height)")
        let artifact = directory.appendingPathComponent("manifest.json")
        let manifest: [String: Any] = [
            "check": "multi-zone-render",
            "artifactKind": "geometry-snapshot",
            "expandedTileFrame": rectDictionary(alphaTileFrame ?? .zero),
            "expectedExpandedTileFrame": rectDictionary(expectedAlphaTileFrame),
            "betaChromeFrame": rectDictionary(betaSnap.frame),
            "gammaChromeFrame": rectDictionary(gammaSnap.frame),
            "fitAllViewport": viewportDictionary(fitAll),
            "headerDoubleClickViewport": viewportDictionary(headerFit),
            "backgroundDoubleClickViewport": viewportDictionary(backgroundFit),
            "zoneHeaderCursorRectCount": canvas.qaZoneHeaderCursorRectCount(),
            "collapsedChildHitSuppressed": true,
            "collapsedHeaderZoneId": gammaZoneId.uuidString,
            "zoneChromeScreenshot": screenshot.path,
            "screenshots": [screenshot.path]
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact

        func expectSnapshot(_ snapshot: ZoneChromeNSView.Snapshot?, _ message: String) throws -> ZoneChromeNSView.Snapshot {
            guard let snapshot else { throw CheckError.failed(message) }
            return snapshot
        }
        func expectViewport(_ viewport: CanvasViewport?, _ message: String) throws -> CanvasViewport {
            guard let viewport else { throw CheckError.failed(message) }
            return viewport
        }
        func viewportsNearlyEqual(_ lhs: CanvasViewport, _ rhs: CanvasViewport) -> Bool {
            abs(lhs.x - rhs.x) < 0.0001 && abs(lhs.y - rhs.y) < 0.0001 && abs(lhs.zoom - rhs.zoom) < 0.0001
        }
        func rectDictionary(_ rect: CGRect) -> [String: Double] {
            ["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height]
        }
        func viewportDictionary(_ viewport: CanvasViewport) -> [String: Double] {
            ["x": viewport.x, "y": viewport.y, "zoom": viewport.zoom]
        }
    }

    static func runAgentStatusBadgeSelfCheck() throws -> URL {
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

        let projectId = UUID(uuidString: "00000000-0000-0000-0000-000000008301")!
        let zoneId = UUID(uuidString: "00000000-0000-0000-0000-000000008311")!
        let workingTileId = UUID(uuidString: "00000000-0000-0000-0000-000000008321")!
        let needsTileId = UUID(uuidString: "00000000-0000-0000-0000-000000008322")!
        let plainTileId = UUID(uuidString: "00000000-0000-0000-0000-000000008323")!
        let zone = ZonePlacement(zoneId: zoneId, projectId: projectId, origin: ZonePoint(x: 0, y: 0), size: ZoneSize(width: 760, height: 480), color: "blue", collapsed: false, hydrationPolicy: .automatic)
        let working = Tile(id: workingTileId, kind: .terminal, title: "Agent · Claude", frame: TileFrame(x: 32, y: 52, width: 220, height: 140), zIndex: 1, runtimeRef: nil, metadata: TileMetadata())
        let needs = Tile(id: needsTileId, kind: .terminal, title: "Agent · Codex", frame: TileFrame(x: 280, y: 52, width: 220, height: 140), zIndex: 2, runtimeRef: nil, metadata: TileMetadata())
        let plain = Tile(id: plainTileId, kind: .terminal, title: "Shell", frame: TileFrame(x: 528, y: 52, width: 180, height: 140), zIndex: 3, runtimeRef: nil, metadata: TileMetadata())
        let canvas = CanvasNSView(
            canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [working, needs, plain], groups: [], lastActiveTileId: nil),
            activeZone: zone,
            zoneRenderModels: [
                ZoneRenderModel(placement: zone, displayName: "Agents", agentStatusRollup: AgentStatusRollup(working: 1, needsAttention: 1, done: 0, stale: 0))
            ],
            showsZoneChrome: true
        )
        let workingView = DescriptorTileNSView(tile: working)
        workingView.agentStatus = .working
        canvas.install(tileView: workingView, for: working)
        let needsView = DescriptorTileNSView(tile: needs)
        needsView.agentStatus = .needsAttention
        canvas.install(tileView: needsView, for: needs)
        canvas.install(tileView: DescriptorTileNSView(tile: plain), for: plain)
        canvas.layoutSubtreeIfNeeded()

        let workingChrome = canvas.tileChromeSnapshot(for: workingTileId)
        let needsChrome = canvas.tileChromeSnapshot(for: needsTileId)
        let plainChrome = canvas.tileChromeSnapshot(for: plainTileId)
        let zoneChrome = canvas.zoneChromeSnapshot(for: zoneId)
        try expect(workingChrome?.agentStatus == .working, "working agent tile should expose working badge state")
        try expect(workingChrome?.agentStatusLabel == "working", "working agent tile should expose working label")
        try expect(needsChrome?.agentStatus == .needsAttention, "needs-attention agent tile should expose needs-attention badge state")
        try expect(needsChrome?.agentStatusLabel == "needs you", "needs-attention agent tile should expose needs-you label")
        try expect(plainChrome?.agentStatus == nil, "non-agent terminal should not expose an agent badge")
        try expect(zoneChrome?.agentRollupText == "1 working · 1 needs you", "zone header should expose aggregate agent counts")
        try expect(canvas.hitTest(CGPoint(x: 10, y: 10)) === canvas, "zone chrome remains pass-through")

        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath)
        let directory = root.appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent("agent-status-badge-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        let manifest: [String: Any] = [
            "check": "agent-status-badge",
            "workingTileStatus": workingChrome?.agentStatusLabel as Any,
            "needsAttentionTileStatus": needsChrome?.agentStatusLabel as Any,
            "plainTileHasBadge": plainChrome?.agentStatus != nil,
            "zoneRollup": zoneChrome?.agentRollupText as Any,
            "screenshots": "PENDING: deterministic chrome snapshots only; no pixel screenshot captured by headless check"
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
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
        var cornerPasses: [String: Bool] = [:]
        for zoom in zooms {
            canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
            tileView.layoutSubtreeIfNeeded()
            frames[String(zoom)] = ["width": tileView.frame.width, "height": tileView.frame.height]
            bounds[String(zoom)] = ["width": tileView.bounds.width, "height": tileView.bounds.height]
            // Bands mirror TileNSView.resizeEdge: edge band `m` is a constant
            // 8 screen px (in world units); corner band `c` matches the visual
            // cornerHoverSize with a `2*m` screen-space floor. Probe points are
            // derived from the bounds + bands (not magic per-zoom constants).
            let m = TileNSView.resizeMargin / CGFloat(zoom)
            let c = max(TileNSView.cornerHoverSize, 2 * m)
            let w = tileView.bounds.width
            let h = tileView.bounds.height
            // Edge mid-points: x/y far from any corner so only the edge applies.
            let left = tileView.qaResizeEdge(at: CGPoint(x: max(0.25, m / 2), y: tileView.bounds.midY)) == .left
            let right = tileView.qaResizeEdge(at: CGPoint(x: w - max(0.25, m / 2), y: tileView.bounds.midY)) == .right
            let top = tileView.qaResizeEdge(at: CGPoint(x: tileView.bounds.midX, y: max(0.25, m / 2))) == .top
            let bottom = tileView.qaResizeEdge(at: CGPoint(x: tileView.bounds.midX, y: h - max(0.25, m / 2))) == .bottom
            let center = tileView.qaResizeEdge(at: CGPoint(x: tileView.bounds.midX, y: tileView.bounds.midY)) == nil
            edgePasses[String(zoom)] = left && right && top && bottom && center
            // Corner probe at offset `off` is strictly inside (m, c] on BOTH
            // axes: the OLD m-only hit-test would miss it (returns nil — neither
            // edge band reached) but the new corner band catches it. This proves
            // the fix, not just that corners-at-the-vertex work.
            let off = (m + c) / 2
            let topLeft = tileView.qaResizeEdge(at: CGPoint(x: off, y: off)) == .topLeft
            let topRight = tileView.qaResizeEdge(at: CGPoint(x: w - off, y: off)) == .topRight
            let bottomLeft = tileView.qaResizeEdge(at: CGPoint(x: off, y: h - off)) == .bottomLeft
            let bottomRight = tileView.qaResizeEdge(at: CGPoint(x: w - off, y: h - off)) == .bottomRight
            // Guard the premise: `off` must be beyond the edge band so this is a
            // genuine "old logic would miss" probe.
            try expect(off > m, "corner probe offset \(off) must exceed edge band \(m) at zoom \(zoom)")
            cornerPasses[String(zoom)] = topLeft && topRight && bottomLeft && bottomRight
            try expect(tileView.bounds.size == CGSize(width: tile.frame.width, height: tile.frame.height), "bounds should remain world-sized at zoom \(zoom)")
        }

        try expect(tileView.probe.setFrameSizeCalls == 0, "content setFrameSize calls during zoom should be zero, got \(tileView.probe.setFrameSizeCalls) sizes=\(tileView.probe.observedSizes)")
        try expect(edgePasses.values.allSatisfy { $0 }, "resize-edge hit tests failed: \(edgePasses)")
        try expect(cornerPasses.values.allSatisfy { $0 }, "resize-corner hit tests failed: \(cornerPasses)")

        let manifest: [String: Any] = [
            "check": "tile-world-bounds",
            "worldSize": ["width": tile.frame.width, "height": tile.frame.height],
            "zooms": zooms,
            "screenFrames": frames,
            "bounds": bounds,
            "contentSetFrameSizeCallsAfterInstall": callsAfterInstall,
            "contentSetFrameSizeCallsDuringZoom": tileView.probe.setFrameSizeCalls,
            "resizeEdgePasses": edgePasses,
            "resizeCornerPasses": cornerPasses
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

    static func runTileDragGrabSelfCheck() throws -> URL {
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

        // A tall tile so that even at the lowest test zoom the floored grab strip
        // (~minScreenGrabPx/zoom world units) still leaves a real body region
        // below it — otherwise the "body is not a move" probe is degenerate.
        let tile = Tile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001134")!,
            kind: .terminal,
            title: "DRAG_GRAB_PROBE",
            frame: TileFrame(x: 40, y: 30, width: 400, height: 1000),
            zIndex: 1,
            runtimeRef: nil,
            metadata: TileMetadata()
        )
        let canvas = CanvasNSView(canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [tile], groups: [], lastActiveTileId: nil))
        canvas.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let tileView = TileNSView(tile: tile)
        canvas.install(tileView: tileView, for: tile)
        tileView.layoutSubtreeIfNeeded()

        // Low zoom: the floored grab strip must exceed titleBarHeight so a point
        // BELOW the drawn 24px bar but WITHIN the grab strip starts a move.
        // Zoom 1: floor is inert relative to the bar, body stays non-move.
        let zooms: [Double] = [1.0, 0.3, 0.1]
        var grabHeights: [String: Double] = [:]
        var stripIsMove: [String: Bool] = [:]
        var stripRoutesToTile: [String: Bool] = [:]
        var bodyIsMove: [String: Bool] = [:]
        var titleBarIsMove: [String: Bool] = [:]
        var topEdgeIsResize: [String: Bool] = [:]
        for zoom in zooms {
            canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
            tileView.layoutSubtreeIfNeeded()
            let grab = tileView.grabHeightInLocalCoordinates
            grabHeights[String(zoom)] = grab
            let midX = tileView.bounds.midX
            // Resize band `m` is a constant 8 screen px in world units; at low zoom
            // it can exceed titleBarHeight, so a move-only point must clear both the
            // resize band AND the drawn bar (`floor`) while staying within `grab`.
            let m = TileNSView.resizeMargin / CGFloat(zoom)
            let titleH = TileNSView.titleBarHeight
            let h = tileView.bounds.height
            let floor = max(titleH, m)

            // Move probe: midpoint of (floor, grab). At low zoom floor == m > titleH,
            // so this point is BELOW the drawn 24px bar yet WITHIN the grab strip —
            // exactly the click the old titleBarHeight-only logic dropped to body.
            let stripY = (floor + grab) / 2
            stripIsMove[String(zoom)] = tileView.qaDragKindIsMove(at: CGPoint(x: midX, y: stripY))
            // Routing: the click must reach TileNSView (not body content) so
            // mouseDown classifies it as .move. Proves the hitTest floor, not just
            // the classifier.
            stripRoutesToTile[String(zoom)] = (tileView.hitTest(CGPoint(x: midX, y: stripY)) === tileView)

            // A point clearly in the body (below the grab strip, above the bottom
            // resize band) is NOT a move.
            let bodyY = (grab + (h - m)) / 2
            bodyIsMove[String(zoom)] = tileView.qaDragKindIsMove(at: CGPoint(x: midX, y: bodyY))

            // The very top edge band still resolves to a resize, not a move, so
            // the floored strip never swallows the top resize ring.
            topEdgeIsResize[String(zoom)] = (tileView.qaResizeEdge(at: CGPoint(x: midX, y: m / 2)) == .top)

            // Zoom 1: a point inside the drawn title bar (below the top resize
            // band) is a move — established behavior preserved. Captured inside the
            // loop so the viewport is actually at this zoom.
            if zoom == 1.0 {
                titleBarIsMove["1.0"] = tileView.qaDragKindIsMove(at: CGPoint(x: midX, y: (m + titleH) / 2))
            }

            // Premise guards: the move probe is genuinely below the bar + within
            // grab, and the body probe is genuinely below grab + a real region.
            try expect(stripY > titleH && stripY < grab, "stripY \(stripY) must lie in (titleBarHeight, grabHeight) at zoom \(zoom)")
            try expect(stripY > m, "stripY \(stripY) must clear the resize band \(m) at zoom \(zoom)")
            try expect(bodyY > grab && bodyY < h - m, "bodyY \(bodyY) must lie in (grabHeight, h - resizeBand) at zoom \(zoom)")
            if zoom < 1.0 {
                try expect(grab > titleH, "grabHeight \(grab) must exceed titleBarHeight \(titleH) at zoom \(zoom)")
            }
        }

        // Floor lifts the strip below the drawn bar into a move at low zoom...
        try expect(stripIsMove["0.3"] == true, "zoom 0.3: point below titleBarHeight but within grabHeight should be a MOVE")
        try expect(stripIsMove["0.1"] == true, "zoom 0.1: point below titleBarHeight but within grabHeight should be a MOVE")
        // ...and the click actually routes to the tile view (hitTest floor).
        try expect(stripRoutesToTile["0.3"] == true, "zoom 0.3: grab strip click should route to TileNSView, not body")
        try expect(stripRoutesToTile["0.1"] == true, "zoom 0.1: grab strip click should route to TileNSView, not body")
        // Body is never a move at any zoom.
        try expect(bodyIsMove.values.allSatisfy { $0 == false }, "body clicks must not be a move: \(bodyIsMove)")
        // Zoom 1 unchanged: drawn title bar is still a move.
        try expect(titleBarIsMove["1.0"] == true, "zoom 1: drawn title-bar click must be a move")
        // Top edge always a resize (ring preserved).
        try expect(topEdgeIsResize.values.allSatisfy { $0 == true }, "top edge must remain a resize at every zoom: \(topEdgeIsResize)")

        let manifest: [String: Any] = [
            "check": "tile-drag-grab",
            "worldSize": ["width": tile.frame.width, "height": tile.frame.height],
            "titleBarHeight": TileNSView.titleBarHeight,
            "minScreenGrabPx": TileNSView.minScreenGrabPx,
            "zooms": zooms,
            "grabHeights": grabHeights,
            "stripIsMove": stripIsMove,
            "stripRoutesToTile": stripRoutesToTile,
            "bodyIsMove": bodyIsMove,
            "titleBarIsMove": titleBarIsMove,
            "topEdgeIsResize": topEdgeIsResize
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("tile-drag-grab", isDirectory: true)
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

    /// Drives the production click→focus router (`AppDelegate.routeTileClickFocus`,
    /// the path the leftMouseUp monitor calls) for the three click regions that
    /// must set scope — title bar, body/content, and empty background — plus an
    /// A→B transition, and asserts `FocusBroker.activeSurface` is correct AND in
    /// lockstep with `CanvasState.lastActiveTileId`. The lockstep hook is wired
    /// exactly as production does in `ZoneRuntimeController.attachUI`.
    static func runFocusScopeDispatchSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self { case let .failed(message): return message }
            }
        }

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        final class ContentProbeView: NSView {
            override var acceptsFirstResponder: Bool { true }
        }

        final class ProbeTileNSView: TileNSView {
            let probe = ContentProbeView(frame: .zero)
            override init(tile: Tile) {
                super.init(tile: tile)
                setContentView(probe)
            }
            required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        }

        let tileAId = UUID(uuidString: "00000000-0000-0000-0000-0000000007A1")!
        let tileBId = UUID(uuidString: "00000000-0000-0000-0000-0000000007B2")!
        let tileA = Tile(id: tileAId, kind: .note, title: "SCOPE_A", frame: TileFrame(x: 60, y: 60, width: 280, height: 200), zIndex: 1, runtimeRef: nil, metadata: TileMetadata())
        let tileB = Tile(id: tileBId, kind: .note, title: "SCOPE_B", frame: TileFrame(x: 420, y: 60, width: 280, height: 200), zIndex: 2, runtimeRef: nil, metadata: TileMetadata())
        let viewport = CanvasViewport(x: 0, y: 0, zoom: 1)
        let canvas = CanvasNSView(canvasState: CanvasState(viewport: viewport, tiles: [tileA, tileB], groups: [], lastActiveTileId: nil))
        let focusBroker = FocusBroker()
        canvas.focusBroker = focusBroker
        // Lockstep mechanism under test — mirrors ZoneRuntimeController.attachUI.
        focusBroker.onAcceptedTileFocus = { [weak canvas] id in canvas?.markActive(tileId: id) }
        canvas.frame = NSRect(x: 0, y: 0, width: 800, height: 360)

        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontRegardless()

        let viewA = ProbeTileNSView(tile: tileA)
        let viewB = ProbeTileNSView(tile: tileB)
        canvas.install(tileView: viewA, for: tileA)
        canvas.install(tileView: viewB, for: tileB)
        window.contentView?.layoutSubtreeIfNeeded()
        canvas.layoutSubtreeIfNeeded()
        viewA.layoutSubtreeIfNeeded()
        viewB.layoutSubtreeIfNeeded()

        // 1) Title-bar click on A → scope .tile(A), lockstep.
        let titleAPoint = viewA.convert(NSPoint(x: viewA.bounds.midX, y: TileNSView.titleBarHeight / 2), to: nil)
        AppDelegate.routeTileClickFocus(at: titleAPoint, in: canvas, focusBroker: focusBroker)
        try expect(focusBroker.activeSurface == .tile(tileAId), "title-bar click should set scope .tile(A); activeSurface=\(String(describing: focusBroker.activeSurface))")
        try expect(canvas.canvasState.lastActiveTileId == tileAId, "title-bar click must keep lastActiveTileId in lockstep with scope; lastActiveTileId=\(String(describing: canvas.canvasState.lastActiveTileId))")

        // 2) Body/content click on A → scope .tile(A), lockstep. Make the
        //    content view first responder (as a real body click would) so the
        //    accepting-existing path runs; resolution comes from the click
        //    point / enclosingTileId, never a stale activeSurface.
        window.makeFirstResponder(viewA.probe)
        let bodyAPoint = viewA.convert(NSPoint(x: viewA.bounds.midX, y: TileNSView.titleBarHeight + (viewA.bounds.height - TileNSView.titleBarHeight) / 2), to: nil)
        let bodyResolvedTileId = canvas.tileId(at: canvas.convert(bodyAPoint, from: nil))
            ?? TileNSView.enclosingTileId(of: window.firstResponder)
        AppDelegate.routeTileClickFocus(at: bodyAPoint, in: canvas, focusBroker: focusBroker)
        try expect(focusBroker.activeSurface == .tile(tileAId), "body/content click should set scope .tile(A); activeSurface=\(String(describing: focusBroker.activeSurface))")
        try expect(canvas.canvasState.lastActiveTileId == tileAId, "body/content click must keep lastActiveTileId in lockstep; lastActiveTileId=\(String(describing: canvas.canvasState.lastActiveTileId))")

        // 3) Empty-canvas background click → scope .canvas. Drive the real
        //    background mouseDown (clears lastActiveTileId) then the router.
        let backgroundPoint = NSPoint(x: 770, y: 330)
        try expect(canvas.tileId(at: canvas.convert(backgroundPoint, from: nil)) == nil, "precondition: background point must hit no tile")
        guard let bgDown = NSEvent.mouseEvent(with: .leftMouseDown, location: backgroundPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
            throw CheckError.failed("could not create background mouseDown")
        }
        canvas.mouseDown(with: bgDown)
        AppDelegate.routeTileClickFocus(at: backgroundPoint, in: canvas, focusBroker: focusBroker)
        try expect(focusBroker.activeSurface == .canvas, "empty-canvas background click should set scope .canvas; activeSurface=\(String(describing: focusBroker.activeSurface))")

        // 4) Focus A then click B → scope is B, not A (no drift), lockstep.
        AppDelegate.routeTileClickFocus(at: titleAPoint, in: canvas, focusBroker: focusBroker)
        try expect(focusBroker.activeSurface == .tile(tileAId), "precondition: A focused before B click")
        let titleBPoint = viewB.convert(NSPoint(x: viewB.bounds.midX, y: TileNSView.titleBarHeight / 2), to: nil)
        AppDelegate.routeTileClickFocus(at: titleBPoint, in: canvas, focusBroker: focusBroker)
        try expect(focusBroker.activeSurface == .tile(tileBId), "clicking B after A must move scope to B (no drift); activeSurface=\(String(describing: focusBroker.activeSurface))")
        try expect(canvas.canvasState.lastActiveTileId == tileBId, "A→B click must keep lastActiveTileId in lockstep with scope B; lastActiveTileId=\(String(describing: canvas.canvasState.lastActiveTileId))")

        let manifest: [String: Any] = [
            "check": "focus-scope-dispatch",
            "tileAId": tileAId.uuidString,
            "tileBId": tileBId.uuidString,
            "titleClickScope": "tile(A)",
            "bodyClickResolvedTileId": bodyResolvedTileId?.uuidString as Any,
            "bodyClickScope": "tile(A)",
            "backgroundPoint": ["x": backgroundPoint.x, "y": backgroundPoint.y],
            "backgroundClickScope": "canvas",
            "transitionFinalScope": "tile(B)",
            "transitionFinalLastActiveTileId": canvas.canvasState.lastActiveTileId?.uuidString as Any
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("focus-scope-dispatch", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    /// Drives the production click→focus router for a 2-tile canvas and asserts
    /// the marching-ants border tracks the focus scope via the CANVAS overlay:
    /// exactly one tile is bordered, the overlay is framed around that tile's
    /// screen frame outset by the gap, it moves A→B on focus change, and clears
    /// entirely when scope leaves all tiles (focus → canvas background). Then
    /// renders the overlay offscreen with the dash phase frozen and asserts the
    /// chrome is non-degenerate (Tier-1 visual gate, docs/26). Wiring mirrors
    /// `ZoneRuntimeController.attachUI` (lockstep + canvas-scope hooks).
    static func runFocusBorderSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self { case let .failed(message): return message }
            }
        }

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        let tileAId = UUID(uuidString: "00000000-0000-0000-0000-0000000005A1")!
        let tileBId = UUID(uuidString: "00000000-0000-0000-0000-0000000005B2")!
        let tileA = Tile(id: tileAId, kind: .note, title: "BORDER_A", frame: TileFrame(x: 60, y: 60, width: 280, height: 200), zIndex: 1, runtimeRef: nil, metadata: TileMetadata())
        let tileB = Tile(id: tileBId, kind: .note, title: "BORDER_B", frame: TileFrame(x: 420, y: 60, width: 280, height: 200), zIndex: 2, runtimeRef: nil, metadata: TileMetadata())
        let viewport = CanvasViewport(x: 0, y: 0, zoom: 1)
        let canvas = CanvasNSView(canvasState: CanvasState(viewport: viewport, tiles: [tileA, tileB], groups: [], lastActiveTileId: nil))
        let focusBroker = FocusBroker()
        canvas.focusBroker = focusBroker
        // Lockstep + canvas-scope clear — mirrors ZoneRuntimeController.attachUI.
        focusBroker.onAcceptedTileFocus = { [weak canvas] id in canvas?.markActive(tileId: id) }
        focusBroker.onAcceptedCanvasScope = { [weak canvas] in canvas?.clearFocusBorder() }
        canvas.frame = NSRect(x: 0, y: 0, width: 800, height: 360)

        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontRegardless()

        let viewA = DescriptorTileNSView(tile: tileA)
        let viewB = DescriptorTileNSView(tile: tileB)
        canvas.install(tileView: viewA, for: tileA)
        canvas.install(tileView: viewB, for: tileB)
        canvas.layoutSubtreeIfNeeded()

        let titleAPoint = viewA.convert(NSPoint(x: viewA.bounds.midX, y: TileNSView.titleBarHeight / 2), to: nil)
        let titleBPoint = viewB.convert(NSPoint(x: viewB.bounds.midX, y: TileNSView.titleBarHeight / 2), to: nil)
        // Default config (standard defaults are empty in the check env) → default gap.
        let gap = CGFloat(FocusBorderConfig.defaultGap)

        // 1) Focus A → overlay visible + animating, framed around A's screen
        //    frame outset by the gap; B is not bordered.
        AppDelegate.routeTileClickFocus(at: titleAPoint, in: canvas, focusBroker: focusBroker)
        try expect(canvas.qaFocusBorderActive, "focusing A should show + animate the canvas focus-border overlay around A")
        try expect(canvas.borderedTileId == tileAId, "canvas should track A as the single bordered tile")
        let expectedAFrame = viewA.frame.insetBy(dx: -gap, dy: -gap)
        try expect(canvas.qaFocusBorderFrame == expectedAFrame, "overlay frame should equal A's screen frame outset by \(gap); expected \(expectedAFrame), got \(String(describing: canvas.qaFocusBorderFrame))")

        // 2) Focus B → overlay moves to B (A no longer bordered; exactly one).
        AppDelegate.routeTileClickFocus(at: titleBPoint, in: canvas, focusBroker: focusBroker)
        try expect(canvas.qaFocusBorderActive, "focusing B should keep the overlay visible + animating around B")
        try expect(canvas.borderedTileId == tileBId, "canvas should track B as the single bordered tile")
        let expectedBFrame = viewB.frame.insetBy(dx: -gap, dy: -gap)
        try expect(canvas.qaFocusBorderFrame == expectedBFrame, "overlay should move to B's screen frame outset by \(gap); expected \(expectedBFrame), got \(String(describing: canvas.qaFocusBorderFrame))")
        try expect(canvas.qaFocusBorderFrame != expectedAFrame, "overlay must no longer sit at A's outset frame after focus moves to B")

        // 3) Scope → canvas (background click) → overlay hidden. Drive the real
        //    background mouseDown first (it makes the canvas first responder,
        //    clearing the tile responder) so the router resolves to .canvas
        //    instead of falling back to the focused tile's responder.
        let backgroundPoint = NSPoint(x: 770, y: 330)
        try expect(canvas.tileId(at: canvas.convert(backgroundPoint, from: nil)) == nil, "precondition: background point must hit no tile")
        guard let bgDown = NSEvent.mouseEvent(with: .leftMouseDown, location: backgroundPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
            throw CheckError.failed("could not create background mouseDown")
        }
        canvas.mouseDown(with: bgDown)
        AppDelegate.routeTileClickFocus(at: backgroundPoint, in: canvas, focusBroker: focusBroker)
        try expect(focusBroker.activeSurface == .canvas, "background click should set scope .canvas")
        try expect(!canvas.qaFocusBorderActive, "overlay must be hidden when scope is canvas")
        try expect(canvas.qaFocusBorderFrame == nil, "overlay should report no frame when scope is canvas")
        try expect(canvas.borderedTileId == nil, "canvas should track no bordered tile when scope is canvas")

        // 4) Render the overlay offscreen with the dash phase FROZEN and assert
        //    the chrome is non-degenerate (grey-screen guard). Re-focus A so the
        //    overlay is visible and framed before capture.
        AppDelegate.routeTileClickFocus(at: titleAPoint, in: canvas, focusBroker: focusBroker)
        try expect(canvas.qaFocusBorderActive, "precondition: A re-focused for snapshot")
        canvas.qaFreezeFocusBorder(phase: 0)
        canvas.layoutSubtreeIfNeeded()
        // Render the canvas region covering A's outset overlay frame so the
        // captured pixels include the dashed border (the overlay alone over the
        // dark canvas reads as background + dashes).
        let snapshotRect = expectedAFrame
        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: snapshotRect) else {
            throw CheckError.failed("focus-border snapshot bitmap rep was not created")
        }
        canvas.cacheDisplay(in: snapshotRect, to: rep)
        let metrics = VisualSnapshot.metrics(of: rep)
        try expect(!metrics.isBlank, "focus-border overlay render must not be blank/uniform — got \(metrics.distinctSampledColors) distinct sampled colors at \(metrics.width)x\(metrics.height)")

        // 5) Live toggle OFF → overlay hides immediately without a scope change.
        //    Drives config via an isolated defaults suite + the settings-changed
        //    notification (the production live-update path).
        let disabledDefaults = UserDefaults(suiteName: "focus-border-disabled-\(UUID().uuidString)")!
        disabledDefaults.set(false, forKey: FocusBorderConfig.enabledKey)
        canvas.focusBorderDefaults = disabledDefaults
        NotificationCenter.default.post(name: .continuumSettingsChanged, object: nil)
        try expect(canvas.borderedTileId == tileAId, "scope unchanged: A is still the bordered tile after a config change")
        try expect(!canvas.qaFocusBorderActive, "disabling the focus border must hide the overlay live")
        try expect(canvas.qaFocusBorderFrame == nil, "disabled focus border reports no overlay frame")

        // 6) Live re-enable with a non-default color + gap → overlay returns,
        //    outset by the NEW gap (proves color/gap are config-driven, not
        //    hardcoded constants).
        let customGap: CGFloat = 20
        let customDefaults = UserDefaults(suiteName: "focus-border-custom-\(UUID().uuidString)")!
        customDefaults.set(true, forKey: FocusBorderConfig.enabledKey)
        customDefaults.set("Mint", forKey: FocusBorderConfig.colorKey)
        customDefaults.set(Double(customGap), forKey: FocusBorderConfig.gapKey)
        canvas.focusBorderDefaults = customDefaults
        NotificationCenter.default.post(name: .continuumSettingsChanged, object: nil)
        try expect(canvas.qaFocusBorderActive, "re-enabling with a custom config shows the overlay live")
        let expectedCustomFrame = viewA.frame.insetBy(dx: -customGap, dy: -customGap)
        try expect(canvas.qaFocusBorderFrame == expectedCustomFrame, "custom gap \(customGap) should outset the overlay by \(customGap); expected \(expectedCustomFrame), got \(String(describing: canvas.qaFocusBorderFrame))")

        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath)
        let directory = root.appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent("focus-border-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let screenshot = directory.appendingPathComponent("focus-border-frozen.png")
        if let png = rep.representation(using: .png, properties: [:]), !png.isEmpty {
            try png.write(to: screenshot, options: .atomic)
        }
        let artifact = directory.appendingPathComponent("manifest.json")
        func rectDict(_ rect: CGRect) -> [String: Double] {
            ["x": rect.origin.x, "y": rect.origin.y, "width": rect.width, "height": rect.height]
        }
        let manifest: [String: Any] = [
            "check": "focus-border",
            "overlay": "canvas-owned outset marching-ants",
            "gap": Double(gap),
            "lineWidth": Double(FocusBorderOverlayView.lineWidth),
            "animationDuration": FocusBorderConfig.defaultSpeed,
            "liveDisabledHidesOverlay": true,
            "liveCustomGap": Double(customGap),
            "liveCustomColor": "Mint",
            "tileAId": tileAId.uuidString,
            "tileBId": tileBId.uuidString,
            "focusAScope": "overlay around A (outset by gap), B not bordered",
            "focusBScope": "overlay moved to B (outset by gap), A cleared",
            "canvasScope": "overlay hidden",
            "tileAScreenFrame": rectDict(viewA.frame),
            "expectedAOutsetFrame": rectDict(expectedAFrame),
            "expectedBOutsetFrame": rectDict(expectedBFrame),
            "frozenSnapshotDistinctColors": metrics.distinctSampledColors,
            "frozenSnapshotSize": ["width": metrics.width, "height": metrics.height],
            "frozenSnapshotIsBlank": metrics.isBlank,
            "screenshots": [screenshot.path]
        ]
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

/// Canvas-owned marching-ants focus border. A `CAShapeLayer` strokes a dashed
/// rounded rect around the *outside* of the focused tile's on-screen frame; a
/// repeating `lineDashPhase` animation makes the dashes travel the perimeter.
/// Lives on the canvas (not the tile) so the outset path is not clipped by the
/// tile's `masksToBounds`; the overlay's own frame is the tile's screen frame
/// outset by `gap`, and the dashed path is its `bounds` (so the stroke draws on
/// the outside of the tile, in the gap). Click-transparent: `hitTest` returns
/// nil so it never blocks tiles or the canvas. Sized in screen space, so the
/// stroke + dashes stay screen-space constant at any canvas zoom.
@MainActor
final class FocusBorderOverlayView: NSView {
    static let lineWidth: CGFloat = 1.5
    static let dashPattern: [NSNumber] = [6, 4]
    private static let animationKey = "marchingAnts"

    /// Gap (screen px) between the tile edge and the dashed border. Configured
    /// from `FocusBorderConfig`; defaults match the pre-config constant so an
    /// unconfigured overlay looks identical to before.
    private(set) var gap: CGFloat = CGFloat(FocusBorderConfig.defaultGap)
    /// Marching-ants loop duration (s). Lower = faster march.
    private var animationDuration: CFTimeInterval = FocusBorderConfig.defaultSpeed
    /// Tile corner radius (TileNSView uses 6) + gap, so the border stays
    /// concentric with the rounded tile at any gap.
    private var cornerRadius: CGFloat { 6 + gap }

    private let shape = CAShapeLayer()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        shape.fillColor = NSColor.clear.cgColor
        // Subtle, low-opacity accent so the border reads as "focused" without
        // shouting inside a dense dark canvas. `configure` overrides this per the
        // user's color preference before each show.
        shape.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        shape.lineWidth = Self.lineWidth
        shape.lineDashPattern = Self.dashPattern
        layer?.addSublayer(shape)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Pass clicks through — the overlay draws only and must never consume
    /// mouse events on tiles or the canvas.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Apply resolved appearance config (the canvas maps the color name to an
    /// `NSColor` and applies alpha). Safe to call before each `show`.
    func configure(color: NSColor, gap: CGFloat, animationDuration: CFTimeInterval) {
        self.gap = gap
        self.animationDuration = animationDuration
        shape.strokeColor = color.cgColor
    }

    /// Position the overlay around `tileScreenFrame` (the focused tile's frame),
    /// outset by `gap`, show it, and (re)attach the marching animation.
    func show(around tileScreenFrame: CGRect) {
        frame = tileScreenFrame.insetBy(dx: -gap, dy: -gap)
        isHidden = false
        layoutShape()
        startMarchingAnts()
    }

    func hide() {
        isHidden = true
        shape.removeAnimation(forKey: Self.animationKey)
    }

    override func layout() {
        super.layout()
        layoutShape()
    }

    private func layoutShape() {
        // Inset by half the line width so the stroke sits fully inside the
        // overlay bounds; the path is the overlay bounds (gap-outset tile rect).
        let rect = bounds.insetBy(dx: Self.lineWidth / 2, dy: Self.lineWidth / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        CATransaction.commit()
    }

    private func startMarchingAnts() {
        let phase = Self.dashPattern.reduce(0) { $0 + $1.doubleValue }
        let animation = CABasicAnimation(keyPath: "lineDashPhase")
        animation.fromValue = 0
        animation.toValue = phase
        animation.duration = animationDuration
        animation.repeatCount = .infinity
        shape.add(animation, forKey: Self.animationKey)
    }

    /// QA: true when the overlay is visible AND its looping animation is
    /// attached. Combined with frame/position assertions by the canvas accessor.
    var qaIsAnimating: Bool {
        !isHidden && shape.animation(forKey: Self.animationKey) != nil
    }

    /// QA: freeze the marching motion so the border renders deterministically
    /// for an offscreen snapshot. Removes the animation and pins a fixed dash
    /// phase, leaving the dashed stroke statically visible.
    func qaFreeze(phase: CGFloat = 0) {
        shape.removeAnimation(forKey: Self.animationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.lineDashPhase = phase
        CATransaction.commit()
    }
}

@MainActor
final class ZoneChromeNSView: NSView {
    struct Snapshot: Equatable {
        var displayName: String
        var color: String
        var collapsed: Bool
        var frame: CGRect
        var headerRect: CGRect
        var agentRollupText: String?
        var qaVerdictGlyph: String?
        var qaVerdictTooltip: String?
    }

    private let model: CanvasNSView.ZoneRenderModel
    private let headerHeight: CGFloat = 34

    var snapshot: Snapshot {
        Snapshot(
            displayName: model.displayName,
            color: model.placement.color,
            collapsed: model.placement.collapsed,
            frame: frame,
            headerRect: headerRect,
            agentRollupText: model.agentStatusRollup.displayText,
            qaVerdictGlyph: model.qaVerdict?.verdict.glyph,
            qaVerdictTooltip: model.qaVerdict?.tooltip
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

        var rightInset: CGFloat = 12
        if let qaVerdict = model.qaVerdict {
            let badgeAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: Self.qaColor(for: qaVerdict.verdict).withAlphaComponent(0.92)
            ]
            let glyph = qaVerdict.verdict.glyph
            let badgeSize = (glyph as NSString).size(withAttributes: badgeAttributes)
            let badgeRect = CGRect(x: headerRect.maxX - badgeSize.width - 12, y: 8, width: badgeSize.width, height: 16)
            glyph.draw(in: badgeRect, withAttributes: badgeAttributes)
            toolTip = qaVerdict.tooltip
            rightInset += badgeSize.width + 10
        } else {
            toolTip = nil
        }

        if let rollup = model.agentStatusRollup.displayText {
            let rollupAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.70)
            ]
            let rollupSize = (rollup as NSString).size(withAttributes: rollupAttributes)
            let rollupRect = CGRect(
                x: max(12, headerRect.maxX - rollupSize.width - rightInset),
                y: 9,
                width: rollupSize.width,
                height: 16
            )
            rollup.draw(in: rollupRect, withAttributes: rollupAttributes)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private static func qaColor(for verdict: QAVerdict) -> NSColor {
        switch verdict {
        case .passed: return NSColor.systemGreen
        case .failed: return NSColor.systemRed
        case .unknown: return NSColor.systemYellow
        }
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
    private weak var canvas: CanvasNSView?
    private let badgeSize = CGSize(width: 24, height: 24)

    var selectedTileId: UUID? { canvas?.canvasState.lastActiveTileId }
    var zoneBadgeCount: Int { canvas?.zoneRenderModels.count ?? 0 }
    var hintLine: String { canvas?.navModeHintLine ?? NavKeymap.default.hintLine }

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
        let text = hintLine
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

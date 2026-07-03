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
    /// Which chrome the shared nav overlay draws: the legacy `⌃Space` nav-mode
    /// (zone badges + hint line) or the hold-leader jump labels.
    enum NavOverlayPresentation { case navMode, leaderLabels }
    var navOverlayPresentation: NavOverlayPresentation = .navMode
    /// The label keys offered to visible tiles in the hold-leader jump HUD,
    /// pushed in by the app from the resolved `NavKeymap` when the leader opens.
    var leaderLabelAlphabet: [String] = NavKeymap.default.leaderLabelAlphabet
    /// The auto-ordinal pool for zone-jump labels in the hold-leader HUD, pushed in
    /// by the app from the resolved `NavKeymap` when the leader opens (mirrors
    /// `leaderLabelAlphabet`).
    var leaderZoneOrdinalAlphabet: [String] = NavKeymap.default.leaderZoneOrdinalAlphabet

    private var spaceHeld = false
    private var spaceDragLastWindowPoint: CGPoint = .zero

    // MARK: - Zone gesture state machine (T19)

    private enum ZoneGesture {
        case none
        case creating(originScreen: CGPoint)
        case movingZone(zoneId: UUID, lastWindowPoint: CGPoint)
        case resizingZone(zoneId: UUID, edge: ResizeEdge, lastWindowPoint: CGPoint)
    }
    private var zoneGesture: ZoneGesture = .none
    /// Tracks the latest placement during a render-model zone move (no ZoneLayer).
    /// Read in mouseUp to fire onZoneMoved even on the render-model path.
    private var pendingMovedPlacement: ZonePlacement?

    // MARK: - Unified live zone model (zone-unify P0)

    /// The mutable live zone overlay — the single source of truth for zones the
    /// user interacts with on the active canvas (project zone + group zones).
    /// Seeded at init from `zoneRenderModels`. Distinct from `zoneLayers`, which
    /// remains the dormant keystone/descriptor multi-project path (T05–T10/T20).
    private var liveZones: [ZonePlacement] = []
    /// Chrome display metadata (name / agent rollup / qa) keyed by zoneId, derived
    /// from `zoneRenderModels`; `liveZones` holds the authoritative placement.
    private var zoneDisplayByZoneId: [UUID: ZoneRenderModel] = [:]
    /// tileId → zoneId. A tile absent from this map is a bare (unzoned) tile.
    /// Derived cache over the authoritative `Tile.zoneId` LWW register (ticket 03):
    /// every mutation goes through `setTileZone(_:zoneId:)`, which stamps the
    /// register in `canvasState` so membership persists with the canvas.
    private var tileZoneMembership: [UUID: UUID] = [:]

    /// Production membership write: the single sink every canvas membership
    /// change flows through. Writes ONLY the tile's `zoneId` register (plus the
    /// derived cache) — never any sibling field. This is the same field
    /// `Op.setTileZone` folds into, so the op-log apply (ticket 06) and the UI
    /// share one write path.
    func setTileZone(_ tileId: UUID, zoneId: UUID?) {
        if let zoneId {
            tileZoneMembership[tileId] = zoneId
        } else {
            tileZoneMembership.removeValue(forKey: tileId)
        }
        if let i = canvasState.tiles.firstIndex(where: { $0.id == tileId }) {
            canvasState.tiles[i].zoneId = zoneId
        }
    }

    /// QA reader: the persisted register value for a tile (nil = ambient).
    func qaTileZoneRegister(of tileId: UUID) -> UUID? {
        canvasState.tiles.first(where: { $0.id == tileId })?.zoneId
    }

    /// QA reader: the live zone ids in seeded order.
    var qaLiveZoneIds: [UUID] { liveZones.map { $0.zoneId } }
    /// QA reader: the zone a tile currently belongs to, or nil if bare.
    func qaZoneMembership(of tileId: UUID) -> UUID? { tileZoneMembership[tileId] }
    /// QA reader: the current (mutable) placement of a live zone, or nil.
    func qaLiveZonePlacement(_ zoneId: UUID) -> ZonePlacement? { liveZones.first { $0.zoneId == zoneId } }
    /// QA reader: the rendered display name of a live zone, or nil.
    func qaZoneDisplayName(_ zoneId: UUID) -> String? { zoneDisplayByZoneId[zoneId]?.displayName }
    /// QA reader: the move-grab header rect for a live zone (screen coords).
    func qaZoneHeaderGrabRect(_ zoneId: UUID) -> CGRect? {
        liveZones.first { $0.zoneId == zoneId }.flatMap { zoneHeaderScreenRect(for: $0) }
    }
    /// QA reader: true iff the zone's chrome paints BEHIND all its member tiles
    /// (lower subview index = painted first). Guards the chrome-over-tiles bug.
    func qaZoneChromeIsBehindMembers(_ zoneId: UUID) -> Bool {
        guard let chrome = zoneChromeViews[zoneId], let ci = subviews.firstIndex(of: chrome) else { return false }
        let memberViews = canvasState.tiles
            .filter { tileZoneMembership[$0.id] == zoneId }
            .compactMap { tileViews[$0.id] }
        guard !memberViews.isEmpty else { return true }
        return memberViews.allSatisfy { tv in
            guard let ti = subviews.firstIndex(of: tv) else { return false }
            return ci < ti
        }
    }

    /// UserDefaults the zone-gesture threshold resolves from (ZoneGestureConfig).
    /// Overridable so `runZoneCreateGestureSelfCheck` can drive deterministically.
    var zoneGestureDefaults: UserDefaults = .standard

    /// UserDefaults the zone break-out distance resolves from (ZoneBreakoutConfig).
    /// Overridable so the break-out check can drive a deterministic threshold.
    var breakoutDefaults: UserDefaults = .standard

    /// UserDefaults the default group-zone name base resolves from
    /// (`DefaultGroupZoneName`). Overridable so the auto-name check is deterministic.
    var zoneNameDefaults: UserDefaults = .standard

    /// Fired when a drag-to-create gesture commits a new group zone.
    /// The placement is passed; the caller persists it (e.g. via WorkspaceDocument).
    var onZoneCreated: ((ZonePlacement) -> Void)?

    /// Fired when a drag-on-chrome gesture commits a moved zone.
    /// The new placement (translated origin) is passed; the caller persists it.
    var onZoneMoved: ((ZonePlacement) -> Void)?

    /// Fired when the user clicks a zone's close (✕) button. The app decides
    /// keep-vs-delete (e.g. a confirm) and then calls `closeZone(zoneId:keepTiles:)`.
    var onZoneCloseRequested: ((UUID) -> Void)?

    /// Fired after a zone is closed so the caller can drop it from persistence.
    var onZoneClosed: ((UUID) -> Void)?

    /// Fired after a zone is renamed (inline edit committed) so the caller can
    /// persist the new name. Carries (zoneId, newName).
    var onZoneRenamed: ((UUID, String) -> Void)?

    // MARK: - Inline zone rename (double-click the header)
    private var zoneRenameField: NSTextField?
    private var renamingZoneId: UUID?
    /// True only while `beginZoneRename` is installing + selecting the field.
    /// `selectText(_:)` posts a synchronous end-editing notification during setup
    /// (via `-[NSWindow endEditingFor:]`); this gate makes the delegate ignore it
    /// so the rename isn't committed + torn down before the user can type.
    private var isOpeningZoneRename = false
    /// QA: number of times inline rename was begun (routing signal, robust to the
    /// field editor's lifecycle in headless checks).
    private(set) var qaZoneRenameBeginCount: Int = 0

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
        // zone-unify P0: seed the unified live model from the boot zone set.
        // `liveZones` is the authoritative placement; display metadata is kept
        // by zoneId. Tile membership is derived from persisted geometry, not
        // blindly assigned to the active project zone; otherwise relaunch makes
        // every tile belong to the default project zone and loses group-zone
        // organization.
        liveZones = self.zoneRenderModels.map { $0.placement }
        zoneDisplayByZoneId = Dictionary(self.zoneRenderModels.map { ($0.placement.zoneId, $0) }, uniquingKeysWith: { first, _ in first })
        seedTileZoneMembershipFromGeometry()
        if showsZoneChrome {
            installZoneChromeViews()
        }
        // Live focus-border config: re-apply when Settings writes a preference.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(focusBorderConfigDidChange),
            name: .continuumSettingsChanged,
            object: nil
        )
        // Ticket 24: a lazy-resume failure (ZoneRuntimeController.recoverManagedSessionOnFocus)
        // has no other subscriber anywhere in the UI — without this, recovery failures are
        // silent. Surface them as the stale indicator + a non-empty error label on the tile.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleManagedSessionRecoveryError(_:)),
            name: .continuumManagedSessionRecoveryError,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func seedTileZoneMembershipFromGeometry() {
        tileZoneMembership.removeAll()
        let liveZoneIds = Set(liveZones.map(\.zoneId))
        for tile in canvasState.tiles {
            // The persisted `Tile.zoneId` register wins: a tile that carries a
            // live zone's id re-joins it directly, no geometry probe.
            if let registered = tile.zoneId, liveZoneIds.contains(registered) {
                tileZoneMembership[tile.id] = registered
                continue
            }
            // Legacy tiles (pre-v2 canvas: register nil) fall back to the
            // historical geometry seed; the derived membership is stamped into
            // the register so it becomes durable on the next canvas save.
            let cx = tile.frame.x + tile.frame.width / 2
            let cy = tile.frame.y + tile.frame.height / 2
            guard let zone = liveZones.reversed().first(where: { placement in
                let f = CanvasEngine.zoneWorldFrame(placement)
                return cx >= f.x && cx <= f.x + f.width && cy >= f.y && cy <= f.y + f.height
            }) else { continue }
            setTileZone(tile.id, zoneId: zone.zoneId)
        }
    }

    private func installZoneChromeViews() {
        guard showsZoneChrome else { return }
        for placement in liveZones {
            let model = zoneDisplayByZoneId[placement.zoneId] ?? ZoneRenderModel(placement: placement, displayName: "")
            let view = ZoneChromeNSView(model: model)
            zoneChromeViews[placement.zoneId] = view
            // Chrome is the zone background — keep it BELOW every tile subview.
            addSubview(view, positioned: .below, relativeTo: nil)
        }
        layoutZoneChromeViews()
    }

    private func layoutZoneChromeViews() {
        guard showsZoneChrome else { return }
        // zone-unify P3: a zone renders at its STORED frame (placement), not an
        // adaptive hug. This keeps the size the user drew (room for more tiles),
        // and makes the visible chrome coincide with the move-grab header rect
        // (zoneHeaderScreenRect also reads placement) so the zone is movable.
        // The frame only changes via create / move / grow-on-tile-resize.
        for placement in liveZones {
            guard let view = zoneChromeViews[placement.zoneId] else { continue }
            view.frame = CanvasEngine.tileScreenFrame(CanvasEngine.zoneWorldFrame(placement), viewport: canvasState.viewport)
            view.needsDisplay = true
        }
    }

    /// Grow a zone's stored frame to contain its members (union + padding +
    /// header), never shrinking. Called on tile resize (not move). Persists the
    /// new placement via `onZoneMoved` so the grown size survives relaunch.
    private func growZoneToFitMembers(_ zoneId: UUID) {
        guard let idx = liveZones.firstIndex(where: { $0.zoneId == zoneId }) else { return }
        let members = canvasState.tiles.filter { tileZoneMembership[$0.id] == zoneId }
        guard !members.isEmpty else { return }
        let pad = ZoneBoundsConfig.padding()
        let hh = Double(ZoneChromeNSView.headerHeight)
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for m in members {
            minX = min(minX, m.frame.x); minY = min(minY, m.frame.y)
            maxX = max(maxX, m.frame.x + m.frame.width); maxY = max(maxY, m.frame.y + m.frame.height)
        }
        let cur = liveZones[idx]
        let newX = min(cur.origin.x, minX - pad)
        let newY = min(cur.origin.y, minY - pad - hh)
        let newMaxX = max(cur.origin.x + cur.size.width, maxX + pad)
        let newMaxY = max(cur.origin.y + cur.size.height, maxY + pad)
        let grown = ZonePoint(x: newX, y: newY)
        let grownSize = ZoneSize(width: newMaxX - newX, height: newMaxY - newY)
        guard grown != cur.origin || grownSize != cur.size else { return }
        var p = cur
        p.origin = grown
        p.size = grownSize
        liveZones[idx] = p
        onZoneMoved?(p)
    }

    /// After a tile MOVE commits, re-evaluate its zone membership (zone-unify P4):
    /// dropping a tile so its center lands inside a zone adopts it (re-homing across
    /// zones too); dragging a member so its center sits more than the break-out
    /// distance beyond its zone detaches it to bare canvas. Returns true if changed.
    @discardableResult
    func reevaluateZoneMembership(forMovedTile tileId: UUID) -> Bool {
        guard let tile = canvasState.tiles.first(where: { $0.id == tileId }) else { return false }
        let cx = tile.frame.x + tile.frame.width / 2
        let cy = tile.frame.y + tile.frame.height / 2
        let current = tileZoneMembership[tileId]
        let containing = liveZones.reversed().first { z in
            let f = CanvasEngine.zoneWorldFrame(z)
            return cx >= f.x && cx <= f.x + f.width && cy >= f.y && cy <= f.y + f.height
        }
        var changed = false
        if let containing {
            if containing.zoneId != current {
                setTileZone(tileId, zoneId: containing.zoneId)   // adopt / re-home
                growZoneToFitMembers(containing.zoneId)
                changed = true
            }
        } else if let current, let zone = liveZones.first(where: { $0.zoneId == current }) {
            // Center is outside every zone — eject only if pulled far enough past the edge.
            let f = CanvasEngine.zoneWorldFrame(zone)
            let outsideBy = max(f.x - cx, cx - (f.x + f.width), f.y - cy, cy - (f.y + f.height))
            if outsideBy >= ZoneBreakoutConfig.distance(defaults: breakoutDefaults) {
                setTileZone(tileId, zoneId: nil)   // break out → bare
                changed = true
            }
        }
        if changed {
            layoutAllTiles()
            delegate?.canvasDidChange(self)
        }
        return changed
    }

    /// Close a zone (zone-unify P5). `keepTiles` (the user's choice) spills the
    /// members onto bare canvas; otherwise a GROUP zone's tiles are deleted. A
    /// PROJECT zone never deletes its tiles (they're the project's, shared and
    /// persisted) — closing it just removes the zone view and keeps the tiles.
    func closeZone(zoneId: UUID, keepTiles: Bool) {
        guard let idx = liveZones.firstIndex(where: { $0.zoneId == zoneId }) else { return }
        let isGroupZone = liveZones[idx].projectId == nil
        let memberIds = canvasState.tiles.filter { tileZoneMembership[$0.id] == zoneId }.map { $0.id }
        if !keepTiles && isGroupZone {
            for id in memberIds {
                setTileZone(id, zoneId: nil)
                removeTile(id: id)
            }
        } else {
            for id in memberIds { setTileZone(id, zoneId: nil) }  // spill to bare canvas
        }
        liveZones.remove(at: idx)
        zoneDisplayByZoneId.removeValue(forKey: zoneId)
        zoneChromeViews[zoneId]?.removeFromSuperview()
        zoneChromeViews.removeValue(forKey: zoneId)
        onZoneClosed?(zoneId)
        layoutAllTiles()
        delegate?.canvasDidChange(self)
    }

    /// World-space member tile frames for `zone`. Tiles store world frames, so a
    /// member's world frame is simply its `frame`.
    private func zoneMemberWorldFrames(_ zone: ZonePlacement) -> [TileFrame] {
        canvasState.tiles.filter { tileZoneMembership[$0.id] == zone.zoneId }.map { $0.frame }
    }

    /// QA reader: the zone chrome's current drawn bounds in world coords, derived
    /// by inverting the screen→world transform on the chrome NSView's frame.
    /// Returns nil when the zone has no chrome view or the canvas has no viewport zoom.
    func qaZoneDrawnWorldBounds(for zoneId: UUID) -> TileFrame? {
        guard let view = zoneChromeViews[zoneId] else { return nil }
        let vp = canvasState.viewport
        guard vp.zoom > 0 else { return nil }
        let sx = view.frame.origin.x
        let sy = view.frame.origin.y
        let sw = view.frame.width
        let sh = view.frame.height
        let wx = Double(sx) / vp.zoom + vp.x
        let wy = Double(sy) / vp.zoom + vp.y
        let ww = Double(sw) / vp.zoom
        let wh = Double(sh) / vp.zoom
        return TileFrame(x: wx, y: wy, width: ww, height: wh)
    }

    // MARK: - Tile management

    func agentStatus(for tileId: UUID) -> AgentStatus? {
        tileViews[tileId]?.agentStatus
    }

    func install(tileView: TileNSView, for tile: Tile) {
        let previousTile = canvasState.tiles.first(where: { $0.id == tile.id })
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
            // Replacing a tile record (restart placeholder → live terminal, etc.)
            // must not clobber the membership register: callers construct their
            // Tile copies without membership knowledge, so the stored zoneId is
            // authoritative unless the caller's copy explicitly carries one.
            var updated = tile
            updated.zoneId = tile.zoneId ?? canvasState.tiles[idx].zoneId
            canvasState.tiles[idx] = updated
            if let zone = updated.zoneId {
                tileZoneMembership[tile.id] = zone
            } else {
                tileZoneMembership.removeValue(forKey: tile.id)
            }
        } else {
            canvasState.tiles.append(tile)
            if let zone = tile.zoneId {
                tileZoneMembership[tile.id] = zone
            }
        }
        reorderTileSubviewsByZIndex()
        if previousTile == nil || previousTile?.title != tile.title || previousTile?.kind != tile.kind {
            delegate?.canvasSidebarModelDidChange(self)
        }
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
        if let v = tileViews[tileId] { return v }
        for layer in zoneLayers {
            if let v = layer.tileViews[tileId] { return v }
        }
        return nil
    }

    func updateTile(_ tile: Tile, recalculateZoneBounds: Bool = true) {
        guard let idx = canvasState.tiles.firstIndex(where: { $0.id == tile.id }) else { return }
        let previousTile = canvasState.tiles[idx]
        canvasState.tiles[idx] = tile
        // zone-unify P3: only a RESIZE grows the owning zone; a MOVE leaves the
        // zone frame fixed (the caller passes recalculateZoneBounds: false).
        if recalculateZoneBounds, let zoneId = tileZoneMembership[tile.id] {
            growZoneToFitMembers(zoneId)
        }
        layoutTile(tile)
        layoutZoneChromeViews()
        if previousTile.title != tile.title || previousTile.kind != tile.kind {
            delegate?.canvasSidebarModelDidChange(self)
        }
        delegate?.canvasDidChange(self)
    }

    /// UserDefaults the drag-snap toggle resolves from (`DragMagnetizeConfig`).
    /// Overridable so `runDragMagnetizeSelfCheck` can drive enabled/disabled
    /// deterministically without touching standard defaults.
    var dragMagnetizeDefaults: UserDefaults = .standard

    /// The snapped world frame a tile being dragged to `freeFrame` would commit to,
    /// or nil when drag snapping is off or nothing is within the pull radius. The
    /// drag itself keeps the tile under the cursor (free); this only drives the
    /// ghost preview + the on-release commit. Pure positioning via
    /// `TileArrangement.cornerSnap` (dock gap + perpendicular edge-align → a clean
    /// 90° corner); the pull radius is a constant screen distance converted to
    /// world via `/ zoom`.
    func snapTarget(for freeFrame: TileFrame, excludingTileId id: UUID) -> TileFrame? {
        guard DragMagnetizeConfig.enabled(defaults: dragMagnetizeDefaults) else { return nil }
        let zoom = viewport.zoom
        guard zoom.isFinite, zoom > 0 else { return nil }
        let others = canvasState.tiles.filter { $0.id != id }.map(\.frame)
        guard !others.isEmpty else { return nil }
        let gap = TileGapResolver.resolvedGap()
        let threshold = DragMagnetizeConfig.snapThresholdScreenPoints / zoom
        let result = TileArrangement.cornerSnap(freeFrame, others: others, gap: gap, threshold: threshold)
        return result.guides.isEmpty ? nil : result.frame
    }

    /// The snapped world frame a live resize would commit to, snapping the dragged
    /// `edge` flush to a nearby neighbor's edge so a tile can take on a docked
    /// neighbor's dimension (`TileArrangement.resizeEdgeSnap`). Returns nil when drag
    /// snapping is off or nothing is within the pull radius. Shares the "Drag
    /// Snapping" toggle, the gap, and the screen→world pull radius with `snapTarget`.
    func resizeSnapTarget(for resizedFrame: TileFrame, edge: ResizeEdge, kind: TileKind, excludingTileId id: UUID) -> TileFrame? {
        guard DragMagnetizeConfig.enabled(defaults: dragMagnetizeDefaults) else { return nil }
        let zoom = viewport.zoom
        guard zoom.isFinite, zoom > 0 else { return nil }
        let others = canvasState.tiles.filter { $0.id != id }.map(\.frame)
        guard !others.isEmpty else { return nil }
        let gap = TileGapResolver.resolvedGap()
        let threshold = DragMagnetizeConfig.snapThresholdScreenPoints / zoom
        let minimum = CanvasEngine.minimumFrame(for: kind)
        let result = TileArrangement.resizeEdgeSnap(resizedFrame, edge: edge, others: others, gap: gap, threshold: threshold, minimum: minimum)
        return result.guides.isEmpty ? nil : result.frame
    }

    /// Show the translucent drag-snap ghost at `worldFrame`'s screen rect, keeping
    /// it topmost (tile installs/reorders can otherwise bury it).
    func showDragGhost(at worldFrame: TileFrame) {
        let overlay = dragGhostOverlayView()
        overlay.show(at: CanvasEngine.tileScreenFrame(worldFrame, viewport: canvasState.viewport))
        overlay.removeFromSuperview()
        addSubview(overlay, positioned: .above, relativeTo: nil)
    }

    func hideDragGhost() {
        dragGhostOverlay?.hide()
    }

    private func dragGhostOverlayView() -> DragGhostOverlayView {
        if let overlay = dragGhostOverlay { return overlay }
        let overlay = DragGhostOverlayView(frame: .zero)
        dragGhostOverlay = overlay
        addSubview(overlay, positioned: .above, relativeTo: nil)
        return overlay
    }

    /// QA: the drag-snap ghost's current screen frame, or nil when hidden.
    var qaDragGhostFrame: CGRect? {
        guard let overlay = dragGhostOverlay, !overlay.isHidden else { return nil }
        return overlay.frame
    }

    func showWorkspaceTransitionLabel(_ text: String, duration: TimeInterval = 1.2) {
        workspaceTransitionLabelView?.removeFromSuperview()
        let label = WorkspaceTransitionLabelView(text: text)
        workspaceTransitionLabelView = label
        addSubview(label, positioned: .above, relativeTo: nil)
        layoutWorkspaceTransitionLabel()
        label.alphaValue = 1
        guard duration > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak label] in
            guard let self, let label, self.workspaceTransitionLabelView === label else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                label.animator().alphaValue = 0
            } completionHandler: { [weak self, weak label] in
                Task { @MainActor [weak self, weak label] in
                    guard let self, let label, self.workspaceTransitionLabelView === label else { return }
                    label.removeFromSuperview()
                    self.workspaceTransitionLabelView = nil
                }
            }
        }
    }

    var qaWorkspaceTransitionLabelText: String? {
        guard let label = workspaceTransitionLabelView, !label.isHidden, label.alphaValue > 0 else { return nil }
        return label.text
    }

    private func layoutWorkspaceTransitionLabel() {
        guard let label = workspaceTransitionLabelView else { return }
        let size = label.preferredSize(maxWidth: max(160, bounds.width - 32))
        label.frame = CGRect(
            x: max(16, (bounds.width - size.width) / 2),
            y: 16,
            width: min(size.width, max(160, bounds.width - 32)),
            height: size.height
        )
        label.needsDisplay = true
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
        delegate?.canvasSidebarModelDidChange(self)
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

    /// Canvas-owned translucent ghost shown at a dragged tile's snap destination
    /// while drag magnetization is in range. Topmost, click-transparent.
    private var dragGhostOverlay: DragGhostOverlayView?

    /// Brief, click-through label shown after a workspace switch.
    private var workspaceTransitionLabelView: WorkspaceTransitionLabelView?

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

    // MARK: - Resize dimension HUD (live W×H readout near the cursor)

    private var resizeDimensionsOverlay: ResizeDimensionsOverlayView?

    /// UserDefaults the resize HUD's enabled toggle resolves from
    /// (`ResizeHUDConfig`). Overridable so the self-check can drive it.
    var resizeHUDDefaults: UserDefaults = .standard

    private func resizeDimensionsOverlayView() -> ResizeDimensionsOverlayView {
        if let overlay = resizeDimensionsOverlay { return overlay }
        let overlay = ResizeDimensionsOverlayView(frame: bounds)
        overlay.autoresizingMask = [.width, .height]
        resizeDimensionsOverlay = overlay
        addSubview(overlay, positioned: .above, relativeTo: nil)
        return overlay
    }

    /// Show the live "W × H" pixel readout near `windowPoint` (the cursor during a
    /// tile resize). `widthPx`/`heightPx` are the tile's content size in logical
    /// pixels — uniform for every tile kind. No-op when disabled in Settings.
    func showResizeDimensions(widthPx: Int, heightPx: Int, atWindowPoint windowPoint: CGPoint) {
        guard ResizeHUDConfig.enabled(defaults: resizeHUDDefaults) else { return }
        let overlay = resizeDimensionsOverlayView()
        // Keep it topmost — tile installs/reorders can otherwise bury it.
        overlay.removeFromSuperview()
        overlay.frame = bounds
        addSubview(overlay, positioned: .above, relativeTo: nil)
        overlay.showDimensions(
            widthPx: widthPx,
            heightPx: heightPx,
            atOverlayPoint: overlay.convert(windowPoint, from: nil)
        )
    }

    func hideResizeDimensions() {
        resizeDimensionsOverlay?.hideOverlay()
    }

    /// QA: resize HUD visibility + current text, for the real-path self-check.
    var qaResizeHUDVisible: Bool { resizeDimensionsOverlay?.qaVisible ?? false }
    var qaResizeHUDText: String { resizeDimensionsOverlay?.qaText ?? "" }

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

    /// Renders a lazy-resume failure on its tile: the gray hollow `.stale`
    /// indicator plus a non-empty error label (surfaced as the tile's tooltip),
    /// rather than leaving the failure invisible.
    @objc private func handleManagedSessionRecoveryError(_ notification: Notification) {
        guard let tileId = notification.userInfo?["tileId"] as? UUID,
              let error = notification.userInfo?["error"],
              let view = tileViews[tileId] else { return }
        view.agentStatus = .stale
        view.agentStatusErrorMessage = String(describing: error)
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
            tile.id == tileId || target.zPosition > tile.zPosition
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
        // Camera movement should reposition/scale existing tile layers, not mark
        // every tile's content dirty. Terminal/browser redraw work during a
        // trackpad pan or programmatic zoom is product-visible jank.
        layoutAllTiles(invalidateTileDisplay: false)
        discardCursorRects()
        window?.invalidateCursorRects(for: self)
        delegate?.canvasDidChange(self)
    }

    func restoreTileSubviewOrder() {
        reorderTileSubviewsByZIndex()
    }

    var navZoneRenderModels: [ZoneRenderModel] { zoneRenderModels }

    func fitZoneToViewport(zoneId: UUID) -> CanvasViewport? {
        let placement = zoneRenderModels.first(where: { $0.placement.zoneId == zoneId })?.placement
            ?? liveZones.first(where: { $0.zoneId == zoneId })
            ?? zoneLayers.first(where: { $0.placement.zoneId == zoneId })?.placement
        guard let placement else { return nil }
        let frame = CanvasEngine.zoneWorldFrame(placement)
        return CameraFraming.zoneOverviewViewport(
            for: CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height),
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
        liveZones.filter { zoneHeaderScreenRect(for: $0) != nil }.count
    }

    private func zoneWorldBounds() -> CGRect? {
        let placements = liveZones + zoneLayers.map(\.placement)
        let rects = placements.map { Self.cgRect(from: CanvasEngine.zoneWorldFrame($0)) }
            .filter { $0.origin.x.isFinite && $0.origin.y.isFinite && $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 }
        guard var bounds = rects.first else { return nil }
        for rect in rects.dropFirst() { bounds = bounds.union(rect) }
        return bounds
    }

    /// Next auto-name for a drag-created group zone: "<base> N", where base comes
    /// from `DefaultGroupZoneName` (default "Zone") and N is one past the highest
    /// "<base> K" index already used by a group zone (so deletions don't collide).
    private func nextDefaultGroupZoneName() -> String {
        let base = DefaultGroupZoneName.resolve(defaults: zoneNameDefaults)
        let prefix = base + " "
        var maxIndex = 0
        for zone in liveZones where zone.projectId == nil {
            guard zone.name.hasPrefix(prefix), let n = Int(zone.name.dropFirst(prefix.count)) else { continue }
            maxIndex = max(maxIndex, n)
        }
        return "\(base) \(maxIndex + 1)"
    }

    /// Begin inline rename of a zone: host an editable text field over its header,
    /// seeded with the current name + selected. Enter / focus-loss commits, Esc
    /// cancels (see the NSTextFieldDelegate extension).
    func beginZoneRename(zoneId: UUID) {
        guard let field = installZoneRenameField(zoneId: zoneId) else { return }
        // selectText(_:) ends any current editing via -[NSWindow endEditingFor:],
        // which posts a synchronous end-editing notification for the field editor we
        // just attached. Gate the delegate so that transient end doesn't commit +
        // tear the rename down during its own setup.
        isOpeningZoneRename = true
        window?.makeFirstResponder(field)
        field.selectText(nil)
        isOpeningZoneRename = false
    }

    /// Build + install the inline rename field over the zone header and set the
    /// rename state. Shared by `beginZoneRename` (which then makes it first
    /// responder + selects). Extracted so the field's geometry/styling/state has a
    /// single source of truth.
    private func installZoneRenameField(zoneId: UUID) -> NSTextField? {
        guard let placement = liveZones.first(where: { $0.zoneId == zoneId }),
              let header = zoneHeaderScreenRect(for: placement) else { return nil }
        cancelZoneRename()
        // Sit over the header where the title draws (12px inset), leaving room for
        // the ✕ close button at the top-right; vertically centered in the header.
        let fieldHeight = max(18, header.height - 8)
        let field = NSTextField(frame: CGRect(
            x: header.minX + 9,
            y: header.minY + (header.height - fieldHeight) / 2,
            width: max(40, header.width - 9 - 36),
            height: fieldHeight
        ))
        field.stringValue = zoneDisplayByZoneId[zoneId]?.displayName ?? placement.name
        field.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        field.textColor = NSColor.white.withAlphaComponent(0.95)
        field.backgroundColor = NSColor.black.withAlphaComponent(0.6)
        field.drawsBackground = true
        field.isBezeled = false
        field.isBordered = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        // Blend with the chrome: rounded pill + a thin border in the zone's accent.
        field.wantsLayer = true
        field.layer?.cornerRadius = 6
        field.layer?.masksToBounds = true
        field.layer?.borderWidth = 1.5
        field.layer?.borderColor = ZoneChromeNSView.color(named: placement.color).withAlphaComponent(0.9).cgColor
        field.delegate = self
        addSubview(field, positioned: .above, relativeTo: nil)
        zoneRenameField = field
        renamingZoneId = zoneId
        qaZoneRenameBeginCount += 1
        return field
    }

    /// Called by the app's click-focus router on every left mouse-up. While a
    /// rename is open, a click on the renamed zone's HEADER keeps editing (returns
    /// true → the router must NOT reroute focus, which would steal the field's
    /// first responder and tear the session down — this is the up of the very
    /// double-click that opened it, or a click into the field). A click anywhere
    /// else commits the rename (returns false → the router proceeds to route focus
    /// to whatever was clicked). No active rename → returns false.
    func consumeZoneRenameClick(atWindowPoint windowPoint: CGPoint) -> Bool {
        guard let zoneId = renamingZoneId,
              let placement = liveZones.first(where: { $0.zoneId == zoneId }),
              let header = zoneHeaderScreenRect(for: placement) else { return false }
        if header.contains(convert(windowPoint, from: nil)) { return true }
        commitZoneRename()
        return false
    }

    /// Commit the active rename: trim, and if non-empty + changed, update the live
    /// placement + render model + chrome and fire `onZoneRenamed`. Empty/whitespace
    /// keeps the previous name. Idempotent / re-entrancy-safe (tears down first).
    func commitZoneRename() {
        guard let zoneId = renamingZoneId, let field = zoneRenameField else { return }
        let text = field.stringValue
        teardownZoneRenameField()
        applyZoneRename(zoneId: zoneId, to: text)
    }

    /// Core rename mutation, shared by the inline commit and the QA path: update
    /// the live placement + render model + chrome and fire `onZoneRenamed`.
    /// Empty/whitespace names are ignored (the previous name is kept).
    @discardableResult
    private func applyZoneRename(zoneId: UUID, to rawName: String) -> Bool {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = liveZones.firstIndex(where: { $0.zoneId == zoneId }),
              liveZones[idx].name != trimmed else { return false }
        liveZones[idx].name = trimmed
        if var model = zoneDisplayByZoneId[zoneId] {
            model.displayName = trimmed
            zoneDisplayByZoneId[zoneId] = model
            zoneChromeViews[zoneId]?.update(model: model)
        }
        onZoneRenamed?(zoneId, trimmed)
        delegate?.canvasDidChange(self)
        return true
    }

    func cancelZoneRename() {
        teardownZoneRenameField()
    }

    private func teardownZoneRenameField() {
        zoneRenameField?.removeFromSuperview()
        zoneRenameField = nil
        renamingZoneId = nil
    }

    /// QA: the zone whose inline rename is active, or nil.
    var qaZoneRenameActiveZoneId: UUID? { renamingZoneId }
    /// QA: apply a rename through the real mutation path. The NSTextField field
    /// editor's lifecycle isn't reproducible headlessly (it ends synchronously in a
    /// non-interactive window); the double-click ROUTING is covered by
    /// `qaZoneRenameBeginCount`, and this drives the same `applyZoneRename` the
    /// inline commit uses.
    func qaRenameZone(_ zoneId: UUID, to name: String) { applyZoneRename(zoneId: zoneId, to: name) }

    private func zoneHeaderZoneId(at screenPoint: CGPoint) -> UUID? {
        liveZones.reversed().first { placement in
            guard let header = zoneHeaderScreenRect(for: placement) else { return false }
            return header.contains(screenPoint)
        }?.zoneId
    }

    /// Zone gesture classification (T19): checks both `zoneRenderModels` and `zoneLayers`
    /// so that zones installed via T05's ZoneLayer API are also recognized.
    private func _zoneHeaderZoneId(at screenPoint: CGPoint) -> UUID? {
        if let id = zoneHeaderZoneId(at: screenPoint) { return id }
        // Also check ZoneLayers installed via T05.
        return zoneLayers.reversed().first { layer in
            guard let header = zoneHeaderScreenRect(for: layer.placement) else { return false }
            return header.contains(screenPoint)
        }?.placement.zoneId
    }

    private func zoneHeaderScreenRect(for placement: ZonePlacement) -> CGRect? {
        let frame = CanvasEngine.tileScreenFrame(CanvasEngine.zoneWorldFrame(placement), viewport: canvasState.viewport)
        guard frame.width > 0, frame.height > 0 else { return nil }
        return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: min(32, frame.height))
    }

    /// Screen rect of a zone's close (✕) button — top-right of the header band.
    /// Mirrors `ZoneChromeNSView`'s drawn close glyph so click == what you see.
    func zoneCloseButtonScreenRect(for placement: ZonePlacement) -> CGRect? {
        guard let header = zoneHeaderScreenRect(for: placement) else { return nil }
        let s: CGFloat = 24
        return CGRect(x: header.maxX - s - 4, y: header.minY + 4, width: s, height: min(s, max(0, header.height - 4)))
    }

    /// The topmost zone whose close button contains `screenPoint`, or nil.
    private func zoneCloseButtonZoneId(at screenPoint: CGPoint) -> UUID? {
        liveZones.reversed().first { placement in
            guard let r = zoneCloseButtonScreenRect(for: placement) else { return false }
            return r.contains(screenPoint)
        }?.zoneId
    }

    /// The topmost zone + edge whose border `screenPoint` is within the resize
    /// band of (8px edges, 16px corners), or nil. Mirrors `TileNSView.resizeEdge`
    /// so a zone resizes by its edges/corners exactly like a tile.
    private func zoneResizeEdge(at screenPoint: CGPoint) -> (UUID, ResizeEdge)? {
        let m: CGFloat = 8, c: CGFloat = 16
        for placement in liveZones.reversed() {
            let f = CanvasEngine.tileScreenFrame(CanvasEngine.zoneWorldFrame(placement), viewport: canvasState.viewport)
            guard f.width > 0, f.height > 0 else { continue }
            guard screenPoint.x >= f.minX - m, screenPoint.x <= f.maxX + m,
                  screenPoint.y >= f.minY - m, screenPoint.y <= f.maxY + m else { continue }
            // The header strip is the move affordance (like a window title bar):
            // grabbing it — including within the corner band near a top corner —
            // must move, never resize. Defer to header-move there. Resize stays on
            // the outer border, the left/right/bottom edges, and the bottom corners
            // (all below the header). Without this, the top corners/edge silently
            // shadowed the header and a header drag near a corner resized instead.
            if let header = zoneHeaderScreenRect(for: placement), header.contains(screenPoint) {
                return nil
            }
            let nearLeft = abs(screenPoint.x - f.minX) <= m, nearRight = abs(screenPoint.x - f.maxX) <= m
            let nearTop = abs(screenPoint.y - f.minY) <= m, nearBottom = abs(screenPoint.y - f.maxY) <= m
            let nlC = abs(screenPoint.x - f.minX) <= c, nrC = abs(screenPoint.x - f.maxX) <= c
            let ntC = abs(screenPoint.y - f.minY) <= c, nbC = abs(screenPoint.y - f.maxY) <= c
            let edge: ResizeEdge?
            if ntC && nlC { edge = .topLeft } else if ntC && nrC { edge = .topRight }
            else if nbC && nlC { edge = .bottomLeft } else if nbC && nrC { edge = .bottomRight }
            else if nearTop { edge = .top } else if nearBottom { edge = .bottom }
            else if nearLeft { edge = .left } else if nearRight { edge = .right }
            else { edge = nil }
            if let edge { return (placement.zoneId, edge) }
        }
        return nil
    }

    /// Apply a resize-edge drag to a zone's stored frame (zone-unify: zones resize
    /// like tiles). Members keep their world frames — resizing the container does
    /// not move its contents. Clamped to a minimum zone size.
    private func resizedZonePlacement(_ placement: ZonePlacement, edge: ResizeEdge, screenDelta: CGSize) -> ZonePlacement {
        let vp = canvasState.viewport
        let dx = Double(screenDelta.width) / vp.zoom, dy = Double(screenDelta.height) / vp.zoom
        let minW = 120.0, minH = 80.0
        let touchesLeft: [ResizeEdge] = [.left, .topLeft, .bottomLeft]
        let touchesRight: [ResizeEdge] = [.right, .topRight, .bottomRight]
        let touchesTop: [ResizeEdge] = [.top, .topLeft, .topRight]
        let touchesBottom: [ResizeEdge] = [.bottom, .bottomLeft, .bottomRight]
        var x = placement.origin.x, y = placement.origin.y
        var w = placement.size.width, h = placement.size.height
        if touchesLeft.contains(edge) {
            let pw = w - dx
            if pw < minW { x += w - minW; w = minW } else { x += dx; w = pw }
        }
        if touchesRight.contains(edge) { w = max(w + dx, minW) }
        if touchesTop.contains(edge) {
            let ph = h - dy
            if ph < minH { y += h - minH; h = minH } else { y += dy; h = ph }
        }
        if touchesBottom.contains(edge) { h = max(h + dy, minH) }
        var p = placement
        p.origin = ZonePoint(x: x, y: y)
        p.size = ZoneSize(width: w, height: h)
        return p
    }

    private static func cgRect(from frame: TileFrame) -> CGRect {
        CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }

    /// Returns the topmost tile id at a screen-space point according to the
    /// semantic canvas model, not AppKit subview insertion order.
    func tileId(at screenPoint: CGPoint) -> UUID? {
        // Multi-layer path (T05): hit-test across all installed ZoneLayers.
        if !zoneLayers.isEmpty {
            let worldPoint = CanvasEngine.screenToWorld(screenPoint, viewport: canvasState.viewport)
            var navigationZones: [CanvasEngine.NavigationZone] = []
            var tilesByZone: [UUID: [Tile]] = [:]
            for zoneId in zoneLayerOrder {
                guard let layer = zoneLayers.first(where: { $0.placement.zoneId == zoneId }) else { continue }
                guard !layer.placement.collapsed else { continue }
                navigationZones.append(CanvasEngine.NavigationZone(
                    id: zoneId,
                    frame: CanvasEngine.zoneWorldFrame(layer.placement),
                    // The zone's own register decides who wins the hit-test —
                    // the engine sorts by (zPosition, id), never array order.
                    zPosition: layer.placement.zPosition
                ))
                tilesByZone[zoneId] = layer.tiles
            }
            return CanvasEngine.hitTest(worldPoint: worldPoint, zones: navigationZones, tilesByZone: tilesByZone)?.tile.id
        }
        // Unified live path (zone-unify P1): hit-test every tile at its world
        // frame — members offset by their membership zone, bare tiles as-is.
        // Tiles in a collapsed zone are skipped. zPosition ordering is global.
        return CanvasEngine.hitTest(screenPoint: screenPoint, viewport: canvasState.viewport, tiles: worldFrameTiles())?.id
    }

    /// The live zone a tile belongs to, resolved against the mutable `liveZones`
    /// (so a moved zone is reflected). Nil when the tile is bare.
    private func membershipPlacement(of tileId: UUID) -> ZonePlacement? {
        guard let zoneId = tileZoneMembership[tileId] else { return nil }
        return liveZones.first { $0.zoneId == zoneId }
    }

    /// Tiles eligible for hit-testing: all tiles (world frames) except those in
    /// a collapsed zone.
    private func worldFrameTiles() -> [Tile] {
        canvasState.tiles.filter { membershipPlacement(of: $0.id)?.collapsed != true }
    }

    func zoneId(at screenPoint: CGPoint) -> UUID? {
        let worldPoint = CanvasEngine.screenToWorld(screenPoint, viewport: canvasState.viewport)
        return liveZones.reversed().first { placement in
            let frame = CanvasEngine.zoneWorldFrame(placement)
            return worldPoint.x >= frame.x && worldPoint.x <= frame.x + frame.width
                && worldPoint.y >= frame.y && worldPoint.y <= frame.y + frame.height
        }?.zoneId
    }

    /// Zone gesture classification (T19): checks both `zoneRenderModels` and `zoneLayers`
    /// so that zones installed only via T05's ZoneLayer API (e.g. after a workspace switch
    /// where `zoneRenderModels` is stale) are not wrongly treated as empty canvas.
    private func _zoneId(at screenPoint: CGPoint) -> UUID? {
        if let id = zoneId(at: screenPoint) { return id }
        let worldPoint = CanvasEngine.screenToWorld(screenPoint, viewport: canvasState.viewport)
        return zoneLayers.reversed().first { layer in
            let frame = CanvasEngine.zoneWorldFrame(layer.placement)
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
            navOverlayPresentation = .navMode
            installNavModeOverlayIfNeeded()
        } else {
            navModeOverlayView?.removeFromSuperview()
            navModeOverlayView = nil
        }
    }

    // MARK: - Hold-leader jump (Phase C)

    struct LeaderJumpAssignment: Equatable {
        let tileId: UUID
        let label: String
        let worldFrame: TileFrame
        let placement: JumpIndicatorPlacement
    }

    struct NavigationTileSnapshot: Equatable {
        let tileId: UUID
        let title: String
        let kind: TileKind
        let worldFrame: TileFrame
        let zoneId: UUID?
    }

    /// The camera/navigation view of installed tiles. `layoutTile` treats
    /// `canvasState.tiles` as world-frame tiles (zone membership is an overlay
    /// tag), while `ZoneLayer` tiles remain zone-local and are projected through
    /// their layer placement. Jump labels and jump framing must use the same
    /// coordinates as layout/hit-testing, or badges and camera targets drift away
    /// from what the user sees.
    func navigationTileSnapshots() -> [NavigationTileSnapshot] {
        var snapshots: [NavigationTileSnapshot] = []
        var seen = Set<UUID>()
        for tile in canvasState.tiles {
            guard seen.insert(tile.id).inserted else { continue }
            let zone = membershipPlacement(of: tile.id)
            guard zone?.collapsed != true else { continue }
            snapshots.append(NavigationTileSnapshot(tileId: tile.id, title: tile.title, kind: tile.kind, worldFrame: tile.frame, zoneId: zone?.zoneId))
        }
        for zoneId in zoneLayerOrder {
            guard let layer = zoneLayers.first(where: { $0.placement.zoneId == zoneId }), !layer.placement.collapsed else { continue }
            for tile in layer.tiles {
                guard seen.insert(tile.id).inserted else { continue }
                snapshots.append(NavigationTileSnapshot(
                    tileId: tile.id,
                    title: tile.title,
                    kind: tile.kind,
                    worldFrame: CanvasEngine.worldFrame(tile: tile, in: layer.placement),
                    zoneId: layer.placement.zoneId
                ))
            }
        }
        return snapshots
    }

    func navigationTileSnapshot(for tileId: UUID) -> NavigationTileSnapshot? {
        navigationTileSnapshots().first { $0.tileId == tileId }
    }

    func firstNavigationTileId(inZone zoneId: UUID) -> UUID? {
        navigationTileSnapshots().first { $0.zoneId == zoneId }?.tileId
    }

    /// The single source of truth for the jump HUD: the visible tiles (their
    /// screen frame intersects the canvas) paired with their deterministic
    /// labels. Both the overlay's `drawTileLabels` and key resolution read this
    /// so a drawn label always maps to the tile the key jumps to.
    func leaderJumpAssignments() -> [LeaderJumpAssignment] {
        var worldFrames: [UUID: TileFrame] = [:]
        let focusedId = canvasState.lastActiveTileId
        let visible: [(id: UUID, frame: TileFrame)] = navigationTileSnapshots().compactMap { snapshot in
            let screenFrame = CanvasEngine.tileScreenFrame(snapshot.worldFrame, viewport: canvasState.viewport)
            guard screenFrame.intersects(bounds) else { return nil }
            // The tile you're already on AND fully seeing isn't a jump target —
            // you're there. A focused tile only partially in view stays a target
            // (the jump frames it), as does any unfocused visible tile.
            if snapshot.tileId == focusedId, bounds.contains(screenFrame) { return nil }
            worldFrames[snapshot.tileId] = snapshot.worldFrame
            return (id: snapshot.tileId, frame: snapshot.worldFrame)
        }
        return TileArrangement.jumpLabels(for: visible, alphabet: leaderLabelAlphabet).compactMap { label in
            guard let frame = worldFrames[label.id] else { return nil }
            let screenFrame = CanvasEngine.tileScreenFrame(frame, viewport: canvasState.viewport)
            guard let placement = JumpIndicatorPlacementEngine.placement(tileScreenFrame: screenFrame, viewportBounds: bounds) else { return nil }
            return LeaderJumpAssignment(tileId: label.id, label: label.label, worldFrame: frame, placement: placement)
        }
    }

    func leaderJumpTarget(forLabel label: String) -> UUID? {
        leaderJumpAssignments().first { $0.label == label }?.tileId
    }

    /// Returns the key→zone mapping for the current zone-jump leader state,
    /// pairing each zone in `navZoneRenderModels` order with its assigned key
    /// (configured `navKey` or auto-ordinal from `leaderZoneOrdinalAlphabet`).
    /// The conflict set is the live tile-jump labels so auto ordinals never shadow tiles.
    func leaderZoneJumpAssignments() -> [(zoneId: UUID, key: String)] {
        let models = navZoneRenderModels
        let zoneIds = models.map { $0.placement.zoneId }
        let configuredKeys = models.map { $0.placement.navKey }
        let tileLabels = Set(leaderJumpAssignments().map(\.label))
        return NavKeymap.zoneJumpLabels(
            zoneIds: zoneIds,
            configuredKeys: configuredKeys,
            ordinalAlphabet: leaderZoneOrdinalAlphabet,
            tileLabels: tileLabels
        )
    }

    /// Returns the zone ID that a pressed key maps to, or nil if no zone owns it.
    func leaderZoneJumpTarget(forKey key: String) -> UUID? {
        leaderZoneJumpAssignments().first { $0.key == key.lowercased() }?.zoneId
    }

    func framedViewportForTileJump(_ tileId: UUID) -> CanvasViewport? {
        guard let snapshot = navigationTileSnapshot(for: tileId) else { return nil }
        let frame = snapshot.worldFrame
        let rect = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        return CameraFraming.jumpViewport(for: rect, kind: snapshot.kind, currentViewport: canvasState.viewport, viewportSize: bounds.size)
    }

    /// Frames the tile as a readable jump target. This first T07 slice snaps to
    /// the computed camera target; animation remains out of scope until a
    /// transition coordinator/recorder is added.
    func centerOnTile(_ tileId: UUID) {
        guard let viewport = framedViewportForTileJump(tileId) else { return }
        setViewport(viewport)
    }

    func setLeaderOverlayVisible(_ visible: Bool) {
        if visible {
            navOverlayPresentation = .leaderLabels
            installNavModeOverlayIfNeeded()
            navModeOverlayView?.needsDisplay = true
        } else {
            navModeOverlayView?.removeFromSuperview()
            navModeOverlayView = nil
            navOverlayPresentation = .navMode
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

    private func reorderTileSubviewsByZIndex() {
        // ordering: tileId.uuidString → [zoneIndex, tileZPosition]
        // zoneIndex for single-zone tiles: 0 (they're their own zone).
        // For ZoneLayer tiles: position in zoneLayerOrder + 1 so they sort after
        // single-zone tiles when both are present (choice B coexistence).
        // Ties resolve by tile id (the deterministic (zPosition, id) sort key),
        // never by array position.
        let ordering = NSMutableDictionary()
        for tile in canvasState.tiles {
            ordering[tile.id.uuidString] = [0.0, tile.zPosition.value]
        }
        for layer in zoneLayers {
            let zoneIdx = Double((zoneLayerOrder.firstIndex(of: layer.placement.zoneId) ?? 0) + 1)
            for tile in layer.tiles {
                ordering[tile.id.uuidString] = [zoneIdx, tile.zPosition.value]
            }
        }
        sortSubviews({ lhs, rhs, context in
            guard
                let ordering = context.map({ Unmanaged<NSMutableDictionary>.fromOpaque($0).takeUnretainedValue() }),
                let lhs = lhs as? TileNSView,
                let rhs = rhs as? TileNSView,
                let lhsInfo = ordering[lhs.tile.id.uuidString] as? [Double],
                let rhsInfo = ordering[rhs.tile.id.uuidString] as? [Double]
            else {
                return .orderedSame
            }
            // Compare (zoneIndex, zPosition, id) lexicographically.
            for i in 0..<2 {
                let l = lhsInfo[i], r = rhsInfo[i]
                if l != r { return l < r ? .orderedAscending : .orderedDescending }
            }
            let lid = lhs.tile.id.uuidString, rid = rhs.tile.id.uuidString
            if lid != rid { return lid < rid ? .orderedAscending : .orderedDescending }
            return .orderedSame
        }, context: Unmanaged.passUnretained(ordering).toOpaque())
        // The sort only orders tile subviews; the chrome comparator returns
        // .orderedSame, so chrome z-position is otherwise undefined. Force every
        // zone chrome to the BACK so tiles always paint on top of their zone
        // background (while staying visually "in" the zone).
        for chrome in zoneChromeViews.values {
            chrome.removeFromSuperview()
            addSubview(chrome, positioned: .below, relativeTo: nil)
        }
        // Keep the focus-border overlay above everything so a brought-to-front
        // tile (or the chrome reordering above) never buries it.
        if let overlay = focusBorderOverlay, !overlay.isHidden {
            overlay.removeFromSuperview()
            addSubview(overlay, positioned: .above, relativeTo: nil)
        }
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutAllTiles()
        layoutNavModeOverlay()
    }

    private func layoutAllTiles(invalidateTileDisplay: Bool = true) {
        layoutZoneChromeViews()
        for tile in canvasState.tiles {
            layoutTile(tile, invalidateTileDisplay: invalidateTileDisplay)
        }
        // Lay out tiles for every installed ZoneLayer (T05).
        for layer in zoneLayers {
            for tile in layer.tiles {
                _layoutLayerTile(tile, in: layer, invalidateTileDisplay: invalidateTileDisplay)
            }
            if let chrome = layer.chrome {
                chrome.frame = _zoneLayerChromeScreenFrame(layer)
                chrome.needsDisplay = true
            }
        }
        navModeOverlayView?.needsDisplay = true
    }

    private func layoutTile(_ tile: Tile, invalidateTileDisplay: Bool = true) {
        guard let view = tileViews[tile.id] else { return }
        // zone-unify: tiles store WORLD frames (the project canvas stays
        // self-consistent). Zone membership is a pure overlay tag; a moved zone
        // translates its members' world frames explicitly. A member is hidden
        // only when its zone is collapsed.
        let rect = CanvasEngine.tileScreenFrame(tile.frame, viewport: canvasState.viewport)
        view.isHidden = membershipPlacement(of: tile.id)?.collapsed == true
        view.frame = rect
        view.bounds = NSRect(x: 0, y: 0, width: tile.frame.width, height: tile.frame.height)
        view.tile = tile
        if invalidateTileDisplay {
            view.invalidateForCanvasLayout()
        }
        // Track the focus border with the tile's screen frame on pan/zoom/move/
        // resize — the overlay lives on the canvas, not the tile, so it must be
        // repositioned here whenever the bordered tile's frame updates.
        repositionFocusBorderIfNeeded(for: tile.id)
        // Authoritatively size the terminal surface from the tile's WORLD content
        // size × backing — independent of canvas zoom. Terminal chrome may grow
        // visually at low zoom for a usable grab target, but that camera-only
        // chrome floor must not resize/reflow the Ghostty grid.
        if let terminalTile = view as? TerminalTileNSView {
            let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            let contentWorldWidth = max(0, tile.frame.width)
            let contentWorldHeight = max(0, tile.frame.height - Double(terminalTile.contentTopInsetWorldHeight))
            terminalTile.runtime.setSurfacePixelSize(
                CGSize(width: contentWorldWidth * backing, height: contentWorldHeight * backing)
            )
        }
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
        if event.clickCount >= 2 {
            // Double-click a zone HEADER → inline rename; otherwise fall through to
            // the existing zoom-fit (zone body / empty canvas).
            if let zoneId = zoneHeaderZoneId(at: point) {
                beginZoneRename(zoneId: zoneId)
                return
            }
            if qaDoubleClickZoneHeaderOrBackground(at: point) != nil {
                return
            }
        }
        // zone-unify P5: a click on a zone's close (✕) button requests closing it.
        if let zoneId = zoneCloseButtonZoneId(at: point) {
            onZoneCloseRequested?(zoneId)
            return
        }
        // zone-unify: a press on a zone's edge/corner resizes it (like a tile).
        // Checked before the header so the top edge resizes and the band below moves.
        if let (zoneId, edge) = zoneResizeEdge(at: point) {
            pendingMovedPlacement = nil
            zoneGesture = .resizingZone(zoneId: zoneId, edge: edge, lastWindowPoint: event.locationInWindow)
            return
        }
        // Zone gesture classification (T19): check chrome header → move; empty canvas → create.
        // A press that reaches a tile falls through to TileNSView, which owns tile drag.
        pendingMovedPlacement = nil
        if let zoneId = _zoneHeaderZoneId(at: point) {
            zoneGesture = .movingZone(zoneId: zoneId, lastWindowPoint: event.locationInWindow)
            return
        }
        if tileId(at: point) == nil && _zoneId(at: point) == nil {
            zoneGesture = .creating(originScreen: point)
            // Fall through to deselect on background click.
        }
        // Click on canvas background — deselect.
        canvasState.lastActiveTileId = nil
        delegate?.canvasDidChange(self)
        window?.makeFirstResponder(self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for placement in liveZones {
            if let rect = zoneHeaderScreenRect(for: placement) {
                addCursorRect(rect, cursor: .pointingHand)
            }
            // Resize cursors on the zone edges (added after the header so they win
            // on the thin edge bands). No public diagonal cursor → corners reuse these.
            let f = CanvasEngine.tileScreenFrame(CanvasEngine.zoneWorldFrame(placement), viewport: canvasState.viewport)
            guard f.width > 0, f.height > 0 else { continue }
            let m: CGFloat = 8
            addCursorRect(CGRect(x: f.minX - m / 2, y: f.minY, width: m, height: f.height), cursor: .resizeLeftRight)
            addCursorRect(CGRect(x: f.maxX - m / 2, y: f.minY, width: m, height: f.height), cursor: .resizeLeftRight)
            addCursorRect(CGRect(x: f.minX, y: f.minY - m / 2, width: f.width, height: m), cursor: .resizeUpDown)
            addCursorRect(CGRect(x: f.minX, y: f.maxY - m / 2, width: f.width, height: m), cursor: .resizeUpDown)
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
        let point = convert(event.locationInWindow, from: nil)
        switch zoneGesture {
        case .none:
            break
        case .creating(let originScreen):
            // Show marquee ghost once the drag exceeds the create threshold.
            let dx = point.x - originScreen.x
            let dy = point.y - originScreen.y
            let dist = sqrt(dx * dx + dy * dy)
            let threshold = ZoneGestureConfig.minCreateDragScreenPoints(defaults: zoneGestureDefaults)
            if dist >= threshold {
                let vp = canvasState.viewport
                let aw = CanvasEngine.screenToWorld(originScreen, viewport: vp)
                let bw = CanvasEngine.screenToWorld(point, viewport: vp)
                let marqueeWorld = TileFrame(
                    x: Double(min(aw.x, bw.x)),
                    y: Double(min(aw.y, bw.y)),
                    width: Double(abs(bw.x - aw.x)),
                    height: Double(abs(bw.y - aw.y))
                )
                showDragGhost(at: marqueeWorld)
            }
            return
        case .movingZone(let zoneId, let lastWindowPoint):
            let dx = event.locationInWindow.x - lastWindowPoint.x
            // Negate dy: window-y-up vs canvas-y-down (same convention as TileNSView.mouseDragged).
            let dy = -(event.locationInWindow.y - lastWindowPoint.y)
            zoneGesture = .movingZone(zoneId: zoneId, lastWindowPoint: event.locationInWindow)
            let vp = canvasState.viewport
            let screenDelta = CGSize(width: dx, height: dy)
            // Update the zone layer placement live so chrome + tiles repaint.
            if let layer = zoneLayers.first(where: { $0.placement.zoneId == zoneId }) {
                let newPlacement = CanvasEngine.zone(layer.placement, draggedByScreenDelta: screenDelta, viewport: vp)
                setZonePlacement(newPlacement)
            } else if let idx = liveZones.firstIndex(where: { $0.zoneId == zoneId }) {
                // Unified live path (zone-unify P1): mutate the authoritative
                // `liveZones` placement and translate its members' world frames by
                // the same delta, then relayout. Chrome reads liveZones — no
                // snap-back on the next relayout.
                let newPlacement = CanvasEngine.zone(liveZones[idx], draggedByScreenDelta: screenDelta, viewport: vp)
                let dxW = newPlacement.origin.x - liveZones[idx].origin.x
                let dyW = newPlacement.origin.y - liveZones[idx].origin.y
                liveZones[idx] = newPlacement
                for i in canvasState.tiles.indices where tileZoneMembership[canvasState.tiles[i].id] == zoneId {
                    let f = canvasState.tiles[i].frame
                    canvasState.tiles[i].frame = TileFrame(x: f.x + dxW, y: f.y + dyW, width: f.width, height: f.height)
                }
                pendingMovedPlacement = newPlacement
                layoutAllTiles()
            }
            return
        case .resizingZone(let zoneId, let edge, let lastWindowPoint):
            let dx = event.locationInWindow.x - lastWindowPoint.x
            let dy = -(event.locationInWindow.y - lastWindowPoint.y)
            zoneGesture = .resizingZone(zoneId: zoneId, edge: edge, lastWindowPoint: event.locationInWindow)
            if let idx = liveZones.firstIndex(where: { $0.zoneId == zoneId }) {
                let newPlacement = resizedZonePlacement(liveZones[idx], edge: edge, screenDelta: CGSize(width: dx, height: dy))
                liveZones[idx] = newPlacement
                pendingMovedPlacement = newPlacement
                layoutAllTiles()
            }
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if spaceHeld {
            NSCursor.pop()
            return
        }
        let currentGesture = zoneGesture
        zoneGesture = .none
        switch currentGesture {
        case .none:
            break
        case .creating(let originScreen):
            hideDragGhost()
            let point = convert(event.locationInWindow, from: nil)
            let dx = point.x - originScreen.x
            let dy = point.y - originScreen.y
            let dist = sqrt(dx * dx + dy * dy)
            let threshold = ZoneGestureConfig.minCreateDragScreenPoints(defaults: zoneGestureDefaults)
            if dist >= threshold {
                let vp = canvasState.viewport
                let aw = CanvasEngine.screenToWorld(originScreen, viewport: vp)
                let bw = CanvasEngine.screenToWorld(point, viewport: vp)
                let newZoneId = UUID()
                // Auto-name silently: "<base> N" (base from DefaultGroupZoneName,
                // default "Zone"; N = next unused index). Computed before append so
                // the new zone isn't counted against itself.
                let zoneName = nextDefaultGroupZoneName()
                let placement = ZonePlacement(
                    zoneId: newZoneId,
                    projectId: nil,
                    origin: ZonePoint(x: Double(min(aw.x, bw.x)), y: Double(min(aw.y, bw.y))),
                    size: ZoneSize(width: Double(abs(bw.x - aw.x)), height: Double(abs(bw.y - aw.y))),
                    color: "teal",
                    collapsed: false,
                    hydrationPolicy: .automatic,
                    name: zoneName,
                    navKey: nil
                )
                // Unified live path (zone-unify P2): register the zone in the
                // authoritative `liveZones` (NOT a ZoneLayer — that path is the
                // dormant keystone/descriptor world). Hit-test stays membership-
                // free, so creating a zone never orphans existing tiles. Any bare
                // tile whose center falls inside the marquee is adopted into the
                // new zone (frame converted world→zone-local so its world position
                // is preserved).
                liveZones.append(placement)
                zoneDisplayByZoneId[newZoneId] = ZoneRenderModel(placement: placement, displayName: zoneName)
                let ox = placement.origin.x, oy = placement.origin.y
                let ow = placement.size.width, oh = placement.size.height
                for i in canvasState.tiles.indices {
                    guard tileZoneMembership[canvasState.tiles[i].id] == nil else { continue }
                    let f = canvasState.tiles[i].frame
                    let cx = f.x + f.width / 2, cy = f.y + f.height / 2
                    guard cx >= ox && cx <= ox + ow && cy >= oy && cy <= oy + oh else { continue }
                    // Membership is a register write on the tile — the tile keeps
                    // its world frame (no conversion), so the project canvas stays valid.
                    setTileZone(canvasState.tiles[i].id, zoneId: newZoneId)
                }
                if showsZoneChrome, zoneChromeViews[newZoneId] == nil {
                    let view = ZoneChromeNSView(model: zoneDisplayByZoneId[newZoneId]!)
                    zoneChromeViews[newZoneId] = view
                    // Background: keep chrome below the tiles it encloses.
                    addSubview(view, positioned: .below, relativeTo: nil)
                }
                layoutAllTiles()
                reorderTileSubviewsByZIndex()
                onZoneCreated?(placement)
            }
            return
        case .movingZone(let zoneId, _):
            hideDragGhost()
            // Commit: fire onZoneMoved so callers can persist.
            // ZoneLayer path: placement was updated live via setZonePlacement.
            // Render-model path: accumulated in pendingMovedPlacement during mouseDragged.
            if let layer = zoneLayers.first(where: { $0.placement.zoneId == zoneId }) {
                onZoneMoved?(layer.placement)
            } else if let pending = pendingMovedPlacement {
                onZoneMoved?(pending)
                // Persist the members' translated world frames (canvas save).
                delegate?.canvasDidChange(self)
            }
            pendingMovedPlacement = nil
            return
        case .resizingZone:
            // Commit the resized frame (origin + size) via the same persist path.
            if let pending = pendingMovedPlacement {
                onZoneMoved?(pending)
                delegate?.canvasDidChange(self)
            }
            pendingMovedPlacement = nil
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

    // MARK: - ZoneLayer (T05)

    /// A reference type representing one installed layer on the canvas.
    /// Choice B: additive over the existing single-zone storage — the active zone
    /// keeps using activeZone+canvasState.tiles; ZoneLayer represents additional
    /// installed zones (plus an adopted active zone when setZones is called).
    @MainActor
    final class ZoneLayer {
        var placement: ZonePlacement
        var renderModel: ZoneRenderModel
        var tiles: [Tile]
        var tileViews: [UUID: TileNSView] = [:]
        fileprivate var chrome: ZoneChromeNSView?

        init(placement: ZonePlacement, renderModel: ZoneRenderModel, tiles: [Tile] = []) {
            self.placement = placement
            self.renderModel = renderModel
            self.tiles = tiles
        }
    }

    // Installed layers (excluding the activeZone single-zone path).
    private var zoneLayers: [ZoneLayer] = []
    // z-order: back-to-front (index 0 = bottom, last = top).
    private var zoneLayerOrder: [UUID] = []

    /// Replace the entire installed layer set in place. Install order (and so
    /// zoneLayerOrder, back-to-front) derives from each placement's zPosition
    /// register — the (zPosition, zoneId) sort — never from array order
    /// (ticket 04).
    func setZones(_ layers: [ZoneLayer]) {
        // Unregister + remove all currently installed layers.
        for layer in zoneLayers {
            for (_, view) in layer.tileViews {
                focusBroker?.unregister(view.focusSurfaceID)
                view.removeFromSuperview()
            }
            layer.chrome?.removeFromSuperview()
        }
        zoneLayers = []
        zoneLayerOrder = []

        // Install the new layers back-to-front by zone zPosition.
        let orderedLayers = layers.sorted { lhs, rhs in
            if lhs.placement.zPosition != rhs.placement.zPosition {
                return lhs.placement.zPosition < rhs.placement.zPosition
            }
            return lhs.placement.zoneId.uuidString < rhs.placement.zoneId.uuidString
        }
        for layer in orderedLayers {
            _installLayer(layer)
        }

        layoutAllTiles()
        reorderTileSubviewsByZIndex()
    }

    /// Add or replace a single layer by zoneId. Unregisters old tile adapters before registering new ones.
    func upsertZoneLayer(_ layer: ZoneLayer) {
        let zoneId = layer.placement.zoneId
        if let existing = zoneLayers.first(where: { $0.placement.zoneId == zoneId }) {
            // Unregister and remove old layer's tiles.
            for (_, view) in existing.tileViews {
                focusBroker?.unregister(view.focusSurfaceID)
                view.removeFromSuperview()
            }
            existing.chrome?.removeFromSuperview()
            zoneLayers.removeAll { $0.placement.zoneId == zoneId }
        }
        // Add at end of z-order if not already present.
        if !zoneLayerOrder.contains(zoneId) {
            zoneLayerOrder.append(zoneId)
        }
        _installLayer(layer)
        layoutAllTiles()
        reorderTileSubviewsByZIndex()
    }

    /// Remove a layer: unregisters its tile adapters, removes subviews, drops from set.
    func removeZoneLayer(zoneId: UUID) {
        guard let layer = zoneLayers.first(where: { $0.placement.zoneId == zoneId }) else { return }
        for (_, view) in layer.tileViews {
            focusBroker?.unregister(view.focusSurfaceID)
            view.removeFromSuperview()
        }
        layer.chrome?.removeFromSuperview()
        zoneLayers.removeAll { $0.placement.zoneId == zoneId }
        zoneLayerOrder.removeAll { $0 == zoneId }
    }

    /// Update only a layer's placement in place; relays its tiles + chrome.
    func setZonePlacement(_ placement: ZonePlacement) {
        guard let layer = zoneLayers.first(where: { $0.placement.zoneId == placement.zoneId }) else { return }
        layer.placement = placement
        for tile in layer.tiles {
            _layoutLayerTile(tile, in: layer)
        }
        if let chrome = layer.chrome {
            chrome.frame = _zoneLayerChromeScreenFrame(layer)
            chrome.needsDisplay = true
        }
    }

    /// Shared chrome-layout helper for ZoneLayer chrome: adaptive bounds derived
    /// from member world frames (mirrors `layoutZoneChromeViews` for T05 layers).
    private func _zoneLayerChromeScreenFrame(_ layer: ZoneLayer) -> CGRect {
        let memberFrames = layer.tiles.map { CanvasEngine.worldFrame(tile: $0, in: layer.placement) }
        var adaptiveBounds = CanvasEngine.zoneBounds(
            memberFrames: memberFrames,
            padding: ZoneBoundsConfig.padding(),
            minSize: ZoneBoundsConfig.emptyMinSize(),
            headerHeight: ZoneChromeNSView.headerHeight
        )
        if memberFrames.isEmpty {
            let origin = layer.placement.origin
            adaptiveBounds = TileFrame(
                x: origin.x + adaptiveBounds.x,
                y: origin.y + adaptiveBounds.y,
                width: adaptiveBounds.width,
                height: adaptiveBounds.height
            )
        }
        return CanvasEngine.tileScreenFrame(adaptiveBounds, viewport: canvasState.viewport)
    }

    /// Test introspection: screen frame of a ZoneLayer's chrome view.
    func zoneLayerChromeFrame(for zoneId: UUID) -> CGRect? {
        zoneLayers.first(where: { $0.placement.zoneId == zoneId })?.chrome?.frame
    }

    /// Test introspection: zoneIds of installed layers in z-order (back-to-front).
    var installedZoneLayerIds: [UUID] { zoneLayerOrder }

    /// Test introspection: the tile ids a layer currently owns.
    func tileIds(inZone zoneId: UUID) -> [UUID] {
        zoneLayers.first(where: { $0.placement.zoneId == zoneId })?.tiles.map(\.id) ?? []
    }

    /// QA (T19): the current stored placement for a ZoneLayer (reflects adaptive-bounds recompute).
    func qaZoneLayerPlacement(for zoneId: UUID) -> ZonePlacement? {
        zoneLayers.first(where: { $0.placement.zoneId == zoneId })?.placement
    }

    // Install a layer: add subviews + register adapters + track in storage.
    private func _installLayer(_ layer: ZoneLayer) {
        zoneLayers.append(layer)
        let zoneId = layer.placement.zoneId
        if !zoneLayerOrder.contains(zoneId) {
            zoneLayerOrder.append(zoneId)
        }
        for (_, view) in layer.tileViews {
            addSubview(view)
            focusBroker?.register(view)
        }
        if showsZoneChrome {
            let chromeView = ZoneChromeNSView(model: layer.renderModel)
            layer.chrome = chromeView
            addSubview(chromeView)
        }
    }

    // Layout a single tile belonging to a ZoneLayer.
    private func _layoutLayerTile(_ tile: Tile, in layer: ZoneLayer, invalidateTileDisplay: Bool = true) {
        guard let view = layer.tileViews[tile.id] else { return }
        let worldFrame = CanvasEngine.worldFrame(tile: tile, in: layer.placement)
        let rect = CanvasEngine.tileScreenFrame(worldFrame, viewport: canvasState.viewport)
        view.isHidden = layer.placement.collapsed
        view.frame = rect
        view.bounds = NSRect(x: 0, y: 0, width: tile.frame.width, height: tile.frame.height)
        view.tile = tile
        if invalidateTileDisplay {
            view.invalidateForCanvasLayout()
        }
        repositionFocusBorderIfNeeded(for: tile.id)
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
            Tile(id: midId, kind: .note, title: "MID_FIRST", frame: overlap, zPosition: .fromLegacyRank(5), runtimeRef: nil, metadata: TileMetadata()),
            Tile(id: topId, kind: .note, title: "TOP_MIDDLE", frame: overlap, zPosition: .fromLegacyRank(99), runtimeRef: nil, metadata: TileMetadata()),
            Tile(id: lowId, kind: .note, title: "LOW_LAST", frame: overlap, zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
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
            "zPositions": Dictionary(uniqueKeysWithValues: seededTiles.map { ($0.id.uuidString, $0.zPosition.value) }),
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
            Tile(id: firstId, kind: .note, title: "legacy-low", frame: TileFrame(x: 40, y: 50, width: 220, height: 140), zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata()),
            Tile(id: topId, kind: .note, title: "legacy-top", frame: TileFrame(x: 100, y: 90, width: 220, height: 140), zPosition: .fromLegacyRank(9), runtimeRef: nil, metadata: TileMetadata()),
            Tile(id: outsideId, kind: .file, title: "legacy-outside", frame: TileFrame(x: 420, y: 80, width: 160, height: 120), zPosition: .fromLegacyRank(2), runtimeRef: nil, metadata: TileMetadata())
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
        try expect(workspace.zonesInZOrder.map(\.zoneId) == [zoneId], "zone z-order should contain only the single zone")
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
            zones: [CanvasEngine.NavigationZone(id: zone.zoneId, frame: CanvasEngine.zoneWorldFrame(zone), zPosition: .fromLegacyRank(0))],
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

    /// zone-unify P0 — proves the unified live model (`liveZones` + `tileZoneMembership`)
    /// is seeded from the boot zone with bit-identical hit-test + layout output.
    static func runUnifiedModelBootSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String { switch self { case let .failed(m): return m } }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }
        let fm = FileManager.default
        let tempRoot = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent("unified-model-boot-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
        let zoneId = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
        let aId = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!
        let bId = UUID(uuidString: "00000000-0000-0000-0000-0000000000A4")!
        let viewport = CanvasViewport(x: 0, y: 0, zoom: 1)
        // The active project zone is always origin (0,0) (DefaultWorkspaceMigration),
        // so world frames == zone-local frames — output must stay bit-identical.
        let zone = ZonePlacement(
            zoneId: zoneId, projectId: projectId,
            origin: ZonePoint(x: 0, y: 0), size: ZoneSize(width: 800, height: 600),
            color: "teal", collapsed: false, hydrationPolicy: .automatic, name: "Proj", navKey: nil
        )
        let tileA = Tile(id: aId, kind: .note, title: "a", frame: TileFrame(x: 100, y: 100, width: 200, height: 140), zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        let tileB = Tile(id: bId, kind: .note, title: "b", frame: TileFrame(x: 360, y: 120, width: 200, height: 140), zPosition: .fromLegacyRank(2), runtimeRef: nil, metadata: TileMetadata())
        let canvas = CanvasNSView(
            canvasState: CanvasState(viewport: viewport, tiles: [tileA, tileB], groups: [], lastActiveTileId: nil),
            activeZone: zone
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        for t in [tileA, tileB] { canvas.install(tileView: DescriptorTileNSView(tile: t), for: t) }
        canvas.layoutSubtreeIfNeeded()

        // 1. liveZones seeded from the boot zone.
        try expect(canvas.qaLiveZoneIds == [zoneId], "liveZones should be seeded with exactly the project zone; got \(canvas.qaLiveZoneIds)")
        // 2. membership: both tiles belong to the project zone.
        try expect(canvas.qaZoneMembership(of: aId) == zoneId, "tileA should be a member of the project zone; got \(String(describing: canvas.qaZoneMembership(of: aId)))")
        try expect(canvas.qaZoneMembership(of: bId) == zoneId, "tileB should be a member of the project zone")
        // 3. hit-test parity (membership does not gate tile hits).
        try expect(canvas.tileId(at: CGPoint(x: 200, y: 170)) == aId, "hit over tileA center should return tileA")
        try expect(canvas.tileId(at: CGPoint(x: 460, y: 190)) == bId, "hit over tileB center should return tileB")
        try expect(canvas.tileId(at: CGPoint(x: 700, y: 500)) == nil, "hit inside the zone but outside any tile should be nil")
        // 4. layout parity: rendered frame equals the bare world frame.
        for t in [tileA, tileB] {
            let expected = CanvasEngine.tileScreenFrame(t.frame, viewport: viewport)
            try expect(canvas.tileView(for: t.id)?.frame == expected, "tile \(t.title) rendered frame should equal bare world frame \(expected); got \(String(describing: canvas.tileView(for: t.id)?.frame))")
        }

        let artifact = tempRoot.appendingPathComponent("manifest.json")
        let manifest: [String: Any] = [
            "check": "unified-model-boot",
            "liveZoneIds": canvas.qaLiveZoneIds.map { $0.uuidString },
            "membership": [aId.uuidString: canvas.qaZoneMembership(of: aId)?.uuidString as Any,
                           bId.uuidString: canvas.qaZoneMembership(of: bId)?.uuidString as Any]
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    /// zone-unify P1 — a zone move mutates the authoritative `liveZones`
    /// (no snap-back), carries its members (zone-local), leaves bare tiles put,
    /// keeps every tile clickable, and fires onZoneMoved exactly once.
    static func runZoneMoveUnifiedSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String { switch self { case let .failed(m): return m } }
        }
        func expect(_ c: @autoclosure () -> Bool, _ m: String) throws { if !c() { throw CheckError.failed(m) } }
        func mouse(_ type: NSEvent.EventType, at p: NSPoint, window: NSWindow) throws -> NSEvent {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1,
                                             pressure: type == .leftMouseUp ? 0 : 1)
            else { throw CheckError.failed("could not synthesize \(type) at \(p)") }
            return e
        }
        func win(_ cx: CGFloat, _ cy: CGFloat, canvasH: CGFloat) -> NSPoint { NSPoint(x: cx, y: canvasH - cy) }

        let cH: CGFloat = 700
        let vp = CanvasViewport(x: 0, y: 0, zoom: 1)
        let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
        let zoneId = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
        let aId = UUID(uuidString: "00000000-0000-0000-0000-0000000000B3")!
        let bId = UUID(uuidString: "00000000-0000-0000-0000-0000000000B4")!
        let bareId = UUID(uuidString: "00000000-0000-0000-0000-0000000000B5")!
        // Zone at a non-zero origin so member-following is observable.
        let zone = ZonePlacement(zoneId: zoneId, projectId: projectId,
                                 origin: ZonePoint(x: 50, y: 50), size: ZoneSize(width: 400, height: 300),
                                 color: "teal", collapsed: false, hydrationPolicy: .automatic, name: "Z", navKey: nil)
        // Member tiles store WORLD frames; zone-move translates them explicitly.
        let tileA = Tile(id: aId, kind: .note, title: "a", frame: TileFrame(x: 70, y: 90, width: 100, height: 80), zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        let tileB = Tile(id: bId, kind: .note, title: "b", frame: TileFrame(x: 250, y: 90, width: 100, height: 80), zPosition: .fromLegacyRank(2), runtimeRef: nil, metadata: TileMetadata())
        let canvas = CanvasNSView(
            canvasState: CanvasState(viewport: vp, tiles: [tileA, tileB], groups: [], lastActiveTileId: nil),
            activeZone: zone,
            zoneRenderModels: [ZoneRenderModel(placement: zone, displayName: "Z")],
            showsZoneChrome: true
        )
        canvas.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontRegardless()
        for t in [tileA, tileB] { canvas.install(tileView: DescriptorTileNSView(tile: t), for: t) }
        // Bare tile installed post-init → never assigned membership → world frame.
        let bare = Tile(id: bareId, kind: .note, title: "bare", frame: TileFrame(x: 700, y: 400, width: 100, height: 80), zPosition: .fromLegacyRank(3), runtimeRef: nil, metadata: TileMetadata())
        canvas.install(tileView: DescriptorTileNSView(tile: bare), for: bare)
        canvas.layoutSubtreeIfNeeded()

        // Pre-move sanity.
        try expect(canvas.tileView(for: aId)?.frame == CGRect(x: 70, y: 90, width: 100, height: 80), "pre-move: tileA renders at world (70,90)")
        try expect(canvas.qaZoneMembership(of: bareId) == nil, "bare tile must have no membership")
        try expect(canvas.tileId(at: CGPoint(x: 120, y: 130)) == aId, "pre-move: tileA clickable at its center")

        var moved: [ZonePlacement] = []
        canvas.onZoneMoved = { moved.append($0) }

        // Drag the zone header: local (100,60) → (250,120) ⇒ world delta (+150,+60).
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: win(100, 60, canvasH: cH), window: window))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: win(250, 120, canvasH: cH), window: window))
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: win(250, 120, canvasH: cH), window: window))

        // 1. liveZones origin updated by the world delta (no immutable render-model).
        try expect(canvas.qaLiveZonePlacement(zoneId)?.origin == ZonePoint(x: 200, y: 110), "zone origin should move to (200,110); got \(String(describing: canvas.qaLiveZonePlacement(zoneId)?.origin))")
        // 2. members followed by exactly (+150,+60).
        let aExpected = CGRect(x: 220, y: 150, width: 100, height: 80)
        try expect(canvas.tileView(for: aId)?.frame == aExpected, "tileA should follow to \(aExpected); got \(String(describing: canvas.tileView(for: aId)?.frame))")
        try expect(canvas.tileView(for: bId)?.frame == CGRect(x: 400, y: 150, width: 100, height: 80), "tileB should follow the zone")
        // 3. bare tile did NOT move.
        try expect(canvas.tileView(for: bareId)?.frame == CGRect(x: 700, y: 400, width: 100, height: 80), "bare tile must stay put")
        // 4. no snap-back after a forced relayout.
        canvas.layoutSubtreeIfNeeded()
        try expect(canvas.tileView(for: aId)?.frame == aExpected, "no snap-back: tileA stays moved after relayout")
        // 5. every tile still clickable at its new position (unclickable-bug guard).
        try expect(canvas.tileId(at: CGPoint(x: 270, y: 190)) == aId, "post-move: tileA clickable at moved center")
        try expect(canvas.tileId(at: CGPoint(x: 450, y: 190)) == bId, "post-move: tileB clickable at moved center")
        try expect(canvas.tileId(at: CGPoint(x: 750, y: 440)) == bareId, "bare tile still clickable")
        // 6. onZoneMoved fired exactly once with the new origin.
        try expect(moved.count == 1, "onZoneMoved should fire exactly once; got \(moved.count)")
        try expect(moved.first?.origin == ZonePoint(x: 200, y: 110), "onZoneMoved should carry the new origin")

        let fm = FileManager.default
        let tempRoot = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent("zone-move-unified-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let artifact = tempRoot.appendingPathComponent("manifest.json")
        let manifest: [String: Any] = [
            "check": "zone-move-unified",
            "newOrigin": ["x": 200, "y": 110],
            "memberDelta": ["dx": 150, "dy": 60],
            "onZoneMovedCount": moved.count
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: artifact, options: .atomic)
        return artifact
    }

    /// zone-unify P2 — drag-create registers a live zone (not a ZoneLayer) and
    /// adopts any bare tile whose center is inside the marquee, preserving each
    /// adopted tile's world position; tiles outside stay bare; all stay clickable.
    static func runZoneCreateEnclosesSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String { switch self { case let .failed(m): return m } }
        }
        func expect(_ c: @autoclosure () -> Bool, _ m: String) throws { if !c() { throw CheckError.failed(m) } }
        func mouse(_ type: NSEvent.EventType, at p: NSPoint, window: NSWindow) throws -> NSEvent {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1,
                                             pressure: type == .leftMouseUp ? 0 : 1)
            else { throw CheckError.failed("could not synthesize \(type) at \(p)") }
            return e
        }
        func win(_ cx: CGFloat, _ cy: CGFloat, canvasH: CGFloat) -> NSPoint { NSPoint(x: cx, y: canvasH - cy) }

        let cH: CGFloat = 700
        let vp = CanvasViewport(x: 0, y: 0, zoom: 1)
        let in1Id = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
        let in2Id = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!
        let outId = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!
        // Bare tiles (no activeZone → no seeded membership).
        let in1 = Tile(id: in1Id, kind: .note, title: "in1", frame: TileFrame(x: 150, y: 150, width: 80, height: 60), zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        let in2 = Tile(id: in2Id, kind: .note, title: "in2", frame: TileFrame(x: 250, y: 160, width: 80, height: 60), zPosition: .fromLegacyRank(2), runtimeRef: nil, metadata: TileMetadata())
        let out = Tile(id: outId, kind: .note, title: "out", frame: TileFrame(x: 600, y: 400, width: 80, height: 60), zPosition: .fromLegacyRank(3), runtimeRef: nil, metadata: TileMetadata())
        let canvas = CanvasNSView(
            canvasState: CanvasState(viewport: vp, tiles: [in1, in2, out], groups: [], lastActiveTileId: nil),
            showsZoneChrome: true
        )
        canvas.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontRegardless()
        for t in [in1, in2, out] { canvas.install(tileView: DescriptorTileNSView(tile: t), for: t) }
        canvas.layoutSubtreeIfNeeded()
        let suite = "P2-encloses-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        canvas.zoneGestureDefaults = defaults
        defer { defaults.removePersistentDomain(forName: suite) }

        try expect(canvas.qaZoneMembership(of: in1Id) == nil && canvas.qaZoneMembership(of: outId) == nil, "pre-create: all tiles bare")

        var created: [ZonePlacement] = []
        canvas.onZoneCreated = { created.append($0) }

        // Marquee canvas-local (100,100)→(400,300) ⇒ origin (100,100), size (300,200).
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: win(100, 100, canvasH: cH), window: window))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: win(400, 300, canvasH: cH), window: window))
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: win(400, 300, canvasH: cH), window: window))

        // 1. exactly one live zone (not a ZoneLayer).
        try expect(canvas.qaLiveZoneIds.count == 1, "exactly one live zone created; got \(canvas.qaLiveZoneIds.count)")
        try expect(canvas.installedZoneLayerIds.isEmpty, "create must not install a ZoneLayer")
        let zoneId = canvas.qaLiveZoneIds[0]
        try expect(created.count == 1, "onZoneCreated fired exactly once; got \(created.count)")
        // 2. enclosed tiles adopted into the zone.
        try expect(canvas.qaZoneMembership(of: in1Id) == zoneId, "in1 should be adopted into the new zone")
        try expect(canvas.qaZoneMembership(of: in2Id) == zoneId, "in2 should be adopted into the new zone")
        // 3. outside tile stays bare.
        try expect(canvas.qaZoneMembership(of: outId) == nil, "out tile must remain bare")
        // 4. adopted tiles keep their WORLD position (no jump on enroll).
        try expect(canvas.tileView(for: in1Id)?.frame == CGRect(x: 150, y: 150, width: 80, height: 60), "in1 world position preserved after adoption; got \(String(describing: canvas.tileView(for: in1Id)?.frame))")
        // 5. all tiles still clickable.
        try expect(canvas.tileId(at: CGPoint(x: 190, y: 180)) == in1Id, "in1 clickable after adoption")
        try expect(canvas.tileId(at: CGPoint(x: 290, y: 190)) == in2Id, "in2 clickable after adoption")
        try expect(canvas.tileId(at: CGPoint(x: 640, y: 430)) == outId, "out clickable (the unclickable-bug guard)")

        let fm = FileManager.default
        let tempRoot = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent("zone-create-encloses-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let artifact = tempRoot.appendingPathComponent("manifest.json")
        let manifest: [String: Any] = [
            "check": "zone-create-encloses",
            "zoneId": zoneId.uuidString,
            "adopted": [in1Id.uuidString, in2Id.uuidString],
            "bare": [outId.uuidString]
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: artifact, options: .atomic)
        return artifact
    }

    /// zone-unify P4 — a member dragged just past the zone edge stays (grace), but
    /// dragged beyond the configurable break-out distance detaches to a bare tile;
    /// a bare tile dropped inside a zone is adopted. All via real TileNSView drags.
    static func runZoneBreakoutSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String { switch self { case let .failed(m): return m } }
        }
        func expect(_ c: @autoclosure () -> Bool, _ m: String) throws { if !c() { throw CheckError.failed(m) } }
        func mouse(_ type: NSEvent.EventType, at p: NSPoint, window: NSWindow) throws -> NSEvent {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            else { throw CheckError.failed("could not synthesize \(type)") }
            return e
        }
        func dragTile(_ view: TileNSView, by dx: CGFloat, _ dy: CGFloat, window: NSWindow) throws {
            let g = view.convert(NSPoint(x: view.bounds.midX, y: TileNSView.titleBarHeight / 2), to: nil)
            view.mouseDown(with: try mouse(.leftMouseDown, at: g, window: window))
            view.mouseDragged(with: try mouse(.leftMouseDragged, at: NSPoint(x: g.x + dx, y: g.y + dy), window: window))
            view.mouseUp(with: try mouse(.leftMouseUp, at: NSPoint(x: g.x + dx, y: g.y + dy), window: window))
        }

        let vp = CanvasViewport(x: 0, y: 0, zoom: 1)
        let zoneId = UUID(uuidString: "00000000-0000-0000-0000-0000000000D2")!
        let memberId = UUID(uuidString: "00000000-0000-0000-0000-0000000000D3")!
        let bareId = UUID(uuidString: "00000000-0000-0000-0000-0000000000D4")!
        let zone = ZonePlacement(zoneId: zoneId, projectId: UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!,
                                 origin: ZonePoint(x: 50, y: 50), size: ZoneSize(width: 400, height: 300),
                                 color: "teal", collapsed: false, hydrationPolicy: .automatic, name: "Z", navKey: nil)
        let member = Tile(id: memberId, kind: .note, title: "m", frame: TileFrame(x: 100, y: 100, width: 120, height: 90), zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        let canvas = CanvasNSView(
            canvasState: CanvasState(viewport: vp, tiles: [member], groups: [], lastActiveTileId: nil),
            activeZone: zone,
            zoneRenderModels: [ZoneRenderModel(placement: zone, displayName: "Z")],
            showsZoneChrome: true)
        // Deterministic threshold + no drag-magnetize interference.
        let suite = "zone-breakout-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(60.0, forKey: ZoneBreakoutConfig.distanceKey)   // custom (proves config-driven)
        canvas.breakoutDefaults = defaults
        let noSnap = UserDefaults(suiteName: "zone-breakout-nosnap-\(UUID().uuidString)")!
        noSnap.set(false, forKey: DragMagnetizeConfig.enabledKey)
        canvas.dragMagnetizeDefaults = noSnap
        defer { defaults.removePersistentDomain(forName: suite) }
        canvas.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontRegardless()
        let memberView = DescriptorTileNSView(tile: member)
        canvas.install(tileView: memberView, for: member)
        let bare = Tile(id: bareId, kind: .note, title: "b", frame: TileFrame(x: 600, y: 400, width: 120, height: 90), zPosition: .fromLegacyRank(2), runtimeRef: nil, metadata: TileMetadata())
        let bareView = DescriptorTileNSView(tile: bare)
        canvas.install(tileView: bareView, for: bare)
        canvas.layoutSubtreeIfNeeded()

        try expect(canvas.qaZoneMembership(of: memberId) == zoneId, "precondition: member belongs to the zone")
        try expect(canvas.qaZoneMembership(of: bareId) == nil, "precondition: bare tile has no membership")
        // Ticket 03: the geometry seed writes through the production register —
        // the persisted Tile.zoneId must agree with the derived map.
        try expect(canvas.qaTileZoneRegister(of: memberId) == zoneId, "register: seed stamps Tile.zoneId for the member")
        try expect(canvas.qaTileZoneRegister(of: bareId) == nil, "register: bare tile's Tile.zoneId stays nil")

        // Leg 1a: nudge the member just past the right edge (center → 470, outsideBy 20 < 60) → STAYS.
        try dragTile(memberView, by: 310, 0, window: window)
        try expect(canvas.qaZoneMembership(of: memberId) == zoneId, "sub-threshold overshoot must NOT eject the member (got \(String(describing: canvas.qaZoneMembership(of: memberId))))")

        // Leg 1b: pull it far past the edge (outsideBy ≫ 60) → BREAKS OUT to bare.
        try dragTile(memberView, by: 260, 0, window: window)
        try expect(canvas.qaZoneMembership(of: memberId) == nil, "far drag past the edge must break the member out to bare")
        try expect(canvas.qaTileZoneRegister(of: memberId) == nil, "register: break-out clears Tile.zoneId through setTileZone")
        // Still a real, clickable tile (frame.x = 100+310+260 = 670, center 730,145).
        try expect(canvas.canvasState.tiles.contains { $0.id == memberId }, "broken-out tile must still exist")
        try expect(canvas.tileId(at: CGPoint(x: 730, y: 145)) == memberId, "broken-out tile must still be clickable")

        // Leg 2: drag the bare tile into the zone (world delta (-400,-300) → center 260,145 inside) → ADOPTED.
        try dragTile(bareView, by: -400, 300, window: window)
        try expect(canvas.qaZoneMembership(of: bareId) == zoneId, "bare tile dropped inside the zone must be adopted (got \(String(describing: canvas.qaZoneMembership(of: bareId))))")
        try expect(canvas.qaTileZoneRegister(of: bareId) == zoneId, "register: adoption writes Tile.zoneId through setTileZone")

        let fm = FileManager.default
        let tempRoot = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent("zone-breakout-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let artifact = tempRoot.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: ["check": "zone-breakout", "threshold": 60], options: [.sortedKeys]).write(to: artifact, options: .atomic)
        return artifact
    }

    /// zone-unify P5 — clicking a zone's close (✕) button routes through
    /// onZoneCloseRequested; KEEP spills a group zone's tiles to bare canvas,
    /// DELETE removes them, and a PROJECT zone never deletes its tiles. The
    /// keep/delete decision is injected (no runModal) and the click is real.
    static func runZoneCloseKeepDeleteSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String { switch self { case let .failed(m): return m } }
        }
        func expect(_ c: @autoclosure () -> Bool, _ m: String) throws { if !c() { throw CheckError.failed(m) } }
        let cH: CGFloat = 700
        let vp = CanvasViewport(x: 0, y: 0, zoom: 1)

        // Builds a canvas with one zone (`projectId`) holding one member tile, wires
        // the close request to closeZone(keepTiles:), then synthesizes a real click
        // on the zone's close button. Returns the canvas + ids for assertions.
        func makeCanvasAndClose(projectId: UUID?, keepTiles: Bool) throws -> (CanvasNSView, UUID, UUID) {
            let zoneId = UUID()
            let memberId = UUID()
            let zone = ZonePlacement(zoneId: zoneId, projectId: projectId,
                                     origin: ZonePoint(x: 0, y: 0), size: ZoneSize(width: 400, height: 300),
                                     color: "teal", collapsed: false, hydrationPolicy: .automatic, name: "Z", navKey: nil)
            let member = Tile(id: memberId, kind: .note, title: "m", frame: TileFrame(x: 100, y: 100, width: 120, height: 90), zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
            let canvas = CanvasNSView(
                canvasState: CanvasState(viewport: vp, tiles: [member], groups: [], lastActiveTileId: nil),
                activeZone: zone,
                zoneRenderModels: [ZoneRenderModel(placement: zone, displayName: "Z")],
                showsZoneChrome: true)
            canvas.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
            let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = canvas
            window.orderFrontRegardless()
            canvas.install(tileView: DescriptorTileNSView(tile: member), for: member)
            canvas.layoutSubtreeIfNeeded()
            // Inject the user's keep/delete decision (the app would show a confirm).
            canvas.onZoneCloseRequested = { [weak canvas] id in canvas?.closeZone(zoneId: id, keepTiles: keepTiles) }
            guard let closeRect = canvas.zoneCloseButtonScreenRect(for: zone) else { throw CheckError.failed("no close-button rect") }
            // Click (canvas-local close center → window coords for the synthesized event).
            let p = NSPoint(x: closeRect.midX, y: cH - closeRect.midY)
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil,
                                                eventNumber: 0, clickCount: 1, pressure: 1)
            else { throw CheckError.failed("could not synthesize close click") }
            canvas.mouseDown(with: down)
            return (canvas, zoneId, memberId)
        }

        // A. Group zone + KEEP → member spills to bare canvas, still present + clickable; zone gone.
        let (cA, zA, mA) = try makeCanvasAndClose(projectId: nil, keepTiles: true)
        try expect(!cA.qaLiveZoneIds.contains(zA), "KEEP: zone must be removed")
        try expect(cA.qaZoneMembership(of: mA) == nil, "KEEP: member must become bare")
        try expect(cA.canvasState.tiles.contains { $0.id == mA }, "KEEP: member tile must still exist")
        try expect(cA.tileId(at: CGPoint(x: 160, y: 145)) == mA, "KEEP: member must still be clickable")

        // B. Group zone + DELETE → member tile removed; zone gone.
        let (cB, zB, mB) = try makeCanvasAndClose(projectId: nil, keepTiles: false)
        try expect(!cB.qaLiveZoneIds.contains(zB), "DELETE: zone must be removed")
        try expect(!cB.canvasState.tiles.contains { $0.id == mB }, "DELETE: group-zone member tile must be removed")

        // C. PROJECT zone + DELETE → tiles are NEVER destroyed (the never-destroy guard).
        let (cC, zC, mC) = try makeCanvasAndClose(projectId: UUID(), keepTiles: false)
        try expect(!cC.qaLiveZoneIds.contains(zC), "PROJECT close: zone must be removed")
        try expect(cC.canvasState.tiles.contains { $0.id == mC }, "PROJECT close must NOT delete the project's tiles, even on 'delete'")
        try expect(cC.qaZoneMembership(of: mC) == nil, "PROJECT close: member spills to bare")

        let fm = FileManager.default
        let tempRoot = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent("zone-close-keep-delete-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let artifact = tempRoot.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: ["check": "zone-close-keep-delete", "legs": ["group-keep", "group-delete", "project-delete-keeps"]], options: [.sortedKeys]).write(to: artifact, options: .atomic)
        return artifact
    }

    /// zone-unify — the zone chrome (background) must paint BEHIND its member
    /// tiles, both for a boot-seeded zone and a gesture-created one (the create
    /// path added chrome on top of existing tiles → this guards that regression).
    static func runZoneChromeZOrderSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String { switch self { case let .failed(m): return m } }
        }
        func expect(_ c: @autoclosure () -> Bool, _ m: String) throws { if !c() { throw CheckError.failed(m) } }
        func mouse(_ type: NSEvent.EventType, at p: NSPoint, window: NSWindow) throws -> NSEvent {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            else { throw CheckError.failed("could not synthesize \(type)") }
            return e
        }
        func win(_ cx: CGFloat, _ cy: CGFloat) -> NSPoint { NSPoint(x: cx, y: 700 - cy) }
        let vp = CanvasViewport(x: 0, y: 0, zoom: 1)

        // Case A: boot-seeded zone with two members.
        let zoneId = UUID(uuidString: "00000000-0000-0000-0000-0000000000E1")!
        let aId = UUID(uuidString: "00000000-0000-0000-0000-0000000000E2")!
        let bId = UUID(uuidString: "00000000-0000-0000-0000-0000000000E3")!
        let zone = ZonePlacement(zoneId: zoneId, projectId: UUID(), origin: ZonePoint(x: 0, y: 0),
                                 size: ZoneSize(width: 600, height: 400), color: "teal",
                                 collapsed: false, hydrationPolicy: .automatic, name: "Z", navKey: nil)
        let tA = Tile(id: aId, kind: .note, title: "a", frame: TileFrame(x: 80, y: 80, width: 140, height: 100), zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        let tB = Tile(id: bId, kind: .note, title: "b", frame: TileFrame(x: 300, y: 120, width: 140, height: 100), zPosition: .fromLegacyRank(2), runtimeRef: nil, metadata: TileMetadata())
        let cvA = CanvasNSView(canvasState: CanvasState(viewport: vp, tiles: [tA, tB], groups: [], lastActiveTileId: nil),
                               activeZone: zone, zoneRenderModels: [ZoneRenderModel(placement: zone, displayName: "Z")], showsZoneChrome: true)
        cvA.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let wA = NSWindow(contentRect: cvA.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        wA.contentView = cvA
        for t in [tA, tB] { cvA.install(tileView: DescriptorTileNSView(tile: t), for: t) }
        cvA.layoutSubtreeIfNeeded()
        try expect(cvA.qaZoneChromeIsBehindMembers(zoneId), "boot-seeded zone chrome must paint behind its member tiles")

        // Case B: gesture-created zone over two existing bare tiles (the regression path).
        let in1 = Tile(id: UUID(), kind: .note, title: "i1", frame: TileFrame(x: 150, y: 150, width: 100, height: 80), zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        let in2 = Tile(id: UUID(), kind: .note, title: "i2", frame: TileFrame(x: 280, y: 170, width: 100, height: 80), zPosition: .fromLegacyRank(2), runtimeRef: nil, metadata: TileMetadata())
        let cvB = CanvasNSView(canvasState: CanvasState(viewport: vp, tiles: [in1, in2], groups: [], lastActiveTileId: nil), showsZoneChrome: true)
        cvB.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let wB = NSWindow(contentRect: cvB.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        wB.contentView = cvB
        for t in [in1, in2] { cvB.install(tileView: DescriptorTileNSView(tile: t), for: t) }
        cvB.layoutSubtreeIfNeeded()
        let suite = "chrome-zorder-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        cvB.zoneGestureDefaults = defaults
        defer { defaults.removePersistentDomain(forName: suite) }
        // Drag-create a marquee enclosing both tiles.
        cvB.mouseDown(with: try mouse(.leftMouseDown, at: win(100, 100), window: wB))
        cvB.mouseDragged(with: try mouse(.leftMouseDragged, at: win(450, 320), window: wB))
        cvB.mouseUp(with: try mouse(.leftMouseUp, at: win(450, 320), window: wB))
        guard let createdId = cvB.qaLiveZoneIds.first else { throw CheckError.failed("no zone created in case B") }
        try expect(cvB.qaZoneChromeIsBehindMembers(createdId), "gesture-created zone chrome must paint behind the tiles it enclosed (chrome-over-tiles regression guard)")

        let fm = FileManager.default
        let tempRoot = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent("zone-chrome-zorder-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let artifact = tempRoot.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: ["check": "zone-chrome-zorder", "cases": ["boot-seeded", "gesture-created"]], options: [.sortedKeys]).write(to: artifact, options: .atomic)
        return artifact
    }

    /// zone-unify — a zone resizes by its edges like a tile: the right edge grows
    /// width, the bottom grows height, the left edge shifts origin + width, and
    /// member tiles never move (resizing the container doesn't move its contents).
    static func runZoneResizeSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String { switch self { case let .failed(m): return m } }
        }
        func expect(_ c: @autoclosure () -> Bool, _ m: String) throws { if !c() { throw CheckError.failed(m) } }
        func win(_ cx: CGFloat, _ cy: CGFloat) -> NSPoint { NSPoint(x: cx, y: 700 - cy) }
        func drag(_ canvas: CanvasNSView, from: NSPoint, to: NSPoint, window: NSWindow) throws {
            func ev(_ t: NSEvent.EventType, _ p: NSPoint) throws -> NSEvent {
                guard let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: t == .leftMouseUp ? 0 : 1)
                else { throw CheckError.failed("synth \(t)") }
                return e
            }
            canvas.mouseDown(with: try ev(.leftMouseDown, from))
            canvas.mouseDragged(with: try ev(.leftMouseDragged, to))
            canvas.mouseUp(with: try ev(.leftMouseUp, to))
        }

        let vp = CanvasViewport(x: 0, y: 0, zoom: 1)
        let zoneId = UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!
        let memberId = UUID(uuidString: "00000000-0000-0000-0000-0000000000F3")!
        let zone = ZonePlacement(zoneId: zoneId, projectId: UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!,
                                 origin: ZonePoint(x: 100, y: 100), size: ZoneSize(width: 400, height: 300),
                                 color: "teal", collapsed: false, hydrationPolicy: .automatic, name: "Z", navKey: nil)
        let member = Tile(id: memberId, kind: .note, title: "m", frame: TileFrame(x: 150, y: 150, width: 120, height: 90), zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        let canvas = CanvasNSView(
            canvasState: CanvasState(viewport: vp, tiles: [member], groups: [], lastActiveTileId: nil),
            activeZone: zone, zoneRenderModels: [ZoneRenderModel(placement: zone, displayName: "Z")], showsZoneChrome: true)
        canvas.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontRegardless()
        canvas.install(tileView: DescriptorTileNSView(tile: member), for: member)
        canvas.layoutSubtreeIfNeeded()
        var moved = 0
        canvas.onZoneMoved = { _ in moved += 1 }
        let memberStart = CGRect(x: 150, y: 150, width: 120, height: 90)

        // 1. Right edge +100 → width 400→500, origin unchanged, member unmoved.
        try drag(canvas, from: win(500, 250), to: win(600, 250), window: window)
        try expect(abs((canvas.qaLiveZonePlacement(zoneId)?.size.width ?? 0) - 500) < 0.5, "right-edge resize should grow width to 500; got \(String(describing: canvas.qaLiveZonePlacement(zoneId)?.size.width))")
        try expect((canvas.qaLiveZonePlacement(zoneId)?.origin.x ?? -1) == 100, "right-edge resize must not move the origin")
        try expect(canvas.tileView(for: memberId)?.frame == memberStart, "right-edge resize must NOT move the member")

        // 2. Bottom edge +50 → height 300→350.
        try drag(canvas, from: win(300, 400), to: win(300, 450), window: window)
        try expect(abs((canvas.qaLiveZonePlacement(zoneId)?.size.height ?? 0) - 350) < 0.5, "bottom-edge resize should grow height to 350; got \(String(describing: canvas.qaLiveZonePlacement(zoneId)?.size.height))")

        // 3. Left edge dragged left 50 → origin.x 100→50, width 500→550, member unmoved.
        try drag(canvas, from: win(100, 250), to: win(50, 250), window: window)
        try expect(abs((canvas.qaLiveZonePlacement(zoneId)?.origin.x ?? -1) - 50) < 0.5, "left-edge resize should move origin.x to 50; got \(String(describing: canvas.qaLiveZonePlacement(zoneId)?.origin.x))")
        try expect(abs((canvas.qaLiveZonePlacement(zoneId)?.size.width ?? 0) - 550) < 0.5, "left-edge resize should grow width to 550; got \(String(describing: canvas.qaLiveZonePlacement(zoneId)?.size.width))")
        try expect(canvas.tileView(for: memberId)?.frame == memberStart, "left-edge resize must NOT move the member (container resize keeps contents put)")

        // 4. Each resize committed once.
        try expect(moved == 3, "each edge resize should fire onZoneMoved once; got \(moved)")

        let fm = FileManager.default
        let tempRoot = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent("zone-resize-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let artifact = tempRoot.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: ["check": "zone-resize", "finalWidth": 550, "finalHeight": 350], options: [.sortedKeys]).write(to: artifact, options: .atomic)
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
        let tile = Tile(id: tileId, kind: .note, title: "alpha", frame: TileFrame(x: 40, y: 52, width: 180, height: 120), zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
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
        // zone-unify P3: a zone renders at its STORED frame (placement), not an
        // adaptive hug — so beta's chrome is its full placement (640×420 at its
        // origin), keeping the size the user drew.
        let betaStoredBounds = CanvasEngine.zoneWorldFrame(beta)
        try expect(betaSnap.frame == CanvasEngine.tileScreenFrame(betaStoredBounds, viewport: viewport), "beta chrome should render at its stored placement frame; expected \(CanvasEngine.tileScreenFrame(betaStoredBounds, viewport: viewport)), got \(betaSnap.frame)")
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
        try expect(viewportsNearlyEqual(headerFit, CameraFraming.zoneOverviewViewport(for: Self.cgRect(from: CanvasEngine.zoneWorldFrame(beta)), viewportSize: canvas.bounds.size)), "header double-click should fit the clicked zone")
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
        // MARK: — Multi-layer block (T05 assertions 1–12)
        // Fresh canvas: no conflict with alpha/beta/gamma fixtures above.
        let layerViewport = CanvasViewport(x: 0, y: 0, zoom: 1)
        let layerCanvas = CanvasNSView(
            canvasState: CanvasState(viewport: layerViewport, tiles: [], groups: [], lastActiveTileId: nil),
            activeZone: nil,
            zoneRenderModels: [],
            showsZoneChrome: true
        )
        // Real FocusBroker held strongly (focusBroker property is weak).
        let broker = FocusBroker()
        layerCanvas.focusBroker = broker

        let layerAProjectId = UUID(uuidString: "00000000-0000-0000-0000-000000004801")!
        let layerBProjectId = UUID(uuidString: "00000000-0000-0000-0000-000000004802")!
        let layerAZoneId    = UUID(uuidString: "00000000-0000-0000-0000-000000004811")!
        let layerBZoneId    = UUID(uuidString: "00000000-0000-0000-0000-000000004812")!
        let layerGZoneId    = UUID(uuidString: "00000000-0000-0000-0000-000000004814")!
        let tAId            = UUID(uuidString: "00000000-0000-0000-0000-000000004821")!
        let tBId            = UUID(uuidString: "00000000-0000-0000-0000-000000004822")!
        let tGId            = UUID(uuidString: "00000000-0000-0000-0000-000000004824")!

        // Explicit zPositions: install order must derive from the register
        // (ticket 04), not from array order or zoneId luck.
        let placementA = ZonePlacement(zoneId: layerAZoneId, projectId: layerAProjectId, origin: ZonePoint(x: 0, y: 0), size: ZoneSize(width: 640, height: 420), color: "blue", collapsed: false, hydrationPolicy: .automatic, zPosition: .fromLegacyRank(1))
        let placementB = ZonePlacement(zoneId: layerBZoneId, projectId: layerBProjectId, origin: ZonePoint(x: 760, y: 0), size: ZoneSize(width: 640, height: 420), color: "mint", collapsed: false, hydrationPolicy: .automatic, zPosition: .fromLegacyRank(2))
        let placementG = ZonePlacement(zoneId: layerGZoneId, projectId: nil, origin: ZonePoint(x: 0, y: 500), size: ZoneSize(width: 640, height: 300), color: "purple", collapsed: false, hydrationPolicy: .automatic, zPosition: .fromLegacyRank(3))

        let tA = Tile(id: tAId, kind: .note, title: "tA", frame: TileFrame(x: 40, y: 52, width: 180, height: 120), zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        let tB = Tile(id: tBId, kind: .note, title: "tB", frame: TileFrame(x: 30, y: 40, width: 200, height: 140), zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        let tG = Tile(id: tGId, kind: .note, title: "tG", frame: TileFrame(x: 20, y: 30, width: 160, height: 100), zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())

        let layerA = ZoneLayer(placement: placementA, renderModel: ZoneRenderModel(placement: placementA, displayName: "LayerA"), tiles: [tA])
        layerA.tileViews[tAId] = DescriptorTileNSView(tile: tA)
        let layerB = ZoneLayer(placement: placementB, renderModel: ZoneRenderModel(placement: placementB, displayName: "LayerB"), tiles: [tB])
        layerB.tileViews[tBId] = DescriptorTileNSView(tile: tB)
        let layerG = ZoneLayer(placement: placementG, renderModel: ZoneRenderModel(placement: placementG, displayName: "LayerG"), tiles: [tG])
        layerG.tileViews[tGId] = DescriptorTileNSView(tile: tG)

        layerCanvas.setZones([layerA, layerB, layerG])
        layerCanvas.layoutSubtreeIfNeeded()

        // Assertion 1: installed set + order
        try expect(layerCanvas.installedZoneLayerIds == [layerAZoneId, layerBZoneId, layerGZoneId], "assertion 1: installedZoneLayerIds should match zoneZOrder [A,B,G]")

        // Assertion 2: per-layer ownership — no cross-leak
        try expect(layerCanvas.tileIds(inZone: layerAZoneId) == [tAId], "assertion 2: layer A should own only tA")
        try expect(layerCanvas.tileIds(inZone: layerBZoneId) == [tBId], "assertion 2: layer B should own only tB")
        try expect(layerCanvas.tileIds(inZone: layerGZoneId) == [tGId], "assertion 2: layer G should own only tG")

        // Assertion 3: per-layer layout A (origin 0,0)
        let expectedFrameA = CanvasEngine.tileScreenFrame(CanvasEngine.worldFrame(tile: tA, in: placementA), viewport: layerViewport)
        try expect(layerCanvas.tileView(for: tAId)?.frame == expectedFrameA, "assertion 3: tA frame should be \(expectedFrameA), got \(String(describing: layerCanvas.tileView(for: tAId)?.frame))")

        // Assertion 4: per-layer layout B (non-origin zone, origin 760,0)
        // tB zone-local (30,40) + origin (760,0) = world (790,40,200,140)
        let expectedFrameB = CanvasEngine.tileScreenFrame(CanvasEngine.worldFrame(tile: tB, in: placementB), viewport: layerViewport)
        try expect(layerCanvas.tileView(for: tBId)?.frame == expectedFrameB, "assertion 4: tB frame should be \(expectedFrameB) (world 790,40), got \(String(describing: layerCanvas.tileView(for: tBId)?.frame))")

        // Assertion 5: per-layer layout G (group zone, y-offset 500)
        // tG zone-local (20,30) + origin (0,500) = world (20,530,160,100)
        let expectedFrameG = CanvasEngine.tileScreenFrame(CanvasEngine.worldFrame(tile: tG, in: placementG), viewport: layerViewport)
        try expect(layerCanvas.tileView(for: tGId)?.frame == expectedFrameG, "assertion 5: tG frame should be \(expectedFrameG) (world 20,530), got \(String(describing: layerCanvas.tileView(for: tGId)?.frame))")

        // Assertion 6: per-layer hit-test A
        try expect(layerCanvas.tileId(at: CGPoint(x: 50, y: 60)) == tAId, "assertion 6: (50,60) should hit tA (world frame 40,52,180,120)")

        // Assertion 7: per-layer hit-test B (outside A entirely)
        try expect(layerCanvas.tileId(at: CGPoint(x: 800, y: 50)) == tBId, "assertion 7: (800,50) should hit tB (world 790,40,200,140), not tA")

        // Assertion 8: per-layer hit-test G
        try expect(layerCanvas.tileId(at: CGPoint(x: 40, y: 560)) == tGId, "assertion 8: (40,560) should hit tG (world 20,530,160,100)")

        // Assertion 9: cross-layer z-order paint — AppKit subview order tA < tB < tG
        let subviewTileIds = layerCanvas.subviews.compactMap { ($0 as? TileNSView)?.tile.id }
        try expect(subviewTileIds.contains(tAId) && subviewTileIds.contains(tBId) && subviewTileIds.contains(tGId), "assertion 9: all three tile subviews must be present")
        let posA = subviewTileIds.firstIndex(of: tAId)!
        let posB = subviewTileIds.firstIndex(of: tBId)!
        let posG = subviewTileIds.firstIndex(of: tGId)!
        try expect(posA < posB && posB < posG, "assertion 9: subview order should be tA(\(posA)) < tB(\(posB)) < tG(\(posG)) (zone z-order A<B<G)")

        // Assertion 10: adapter register-on-add
        try expect(broker.requestFocus(.tile(tAId), reason: .userClick), "assertion 10: tA adapter should be registered after setZones")
        try expect(broker.requestFocus(.tile(tBId), reason: .userClick), "assertion 10: tB adapter should be registered after setZones")
        try expect(broker.requestFocus(.tile(tGId), reason: .userClick), "assertion 10: tG adapter should be registered after setZones")

        // Assertion 11: overlap → topmost LAYER wins
        // layerOver: origin (0,0) size 200x200, tile tOver (10,10,150,150), frontmost via its zPosition register
        let layerOverZoneId   = UUID(uuidString: "00000000-0000-0000-0000-000000004815")!
        let layerOverProjectId = UUID(uuidString: "00000000-0000-0000-0000-000000004805")!
        let tOverId           = UUID(uuidString: "00000000-0000-0000-0000-000000004825")!
        let placementOver = ZonePlacement(zoneId: layerOverZoneId, projectId: layerOverProjectId, origin: ZonePoint(x: 0, y: 0), size: ZoneSize(width: 200, height: 200), color: "orange", collapsed: false, hydrationPolicy: .automatic, zPosition: .fromLegacyRank(4))
        let tOver = Tile(id: tOverId, kind: .note, title: "tOver", frame: TileFrame(x: 10, y: 10, width: 150, height: 150), zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        let layerOver = ZoneLayer(placement: placementOver, renderModel: ZoneRenderModel(placement: placementOver, displayName: "LayerOver"), tiles: [tOver])
        layerOver.tileViews[tOverId] = DescriptorTileNSView(tile: tOver)
        layerCanvas.upsertZoneLayer(layerOver)
        // (70,70) is inside tOver world (10,10,150,150) AND tA world (40,52,180,120) → topmost layer wins
        try expect(layerCanvas.tileId(at: CGPoint(x: 70, y: 70)) == tOverId, "assertion 11: (70,70) must resolve to tOver (top layer), not tA — overlap cross-layer z-order")

        // Assertion 12: remove layer B → unregisters adapters (T09 contract)
        layerCanvas.removeZoneLayer(zoneId: layerBZoneId)
        try expect(!layerCanvas.installedZoneLayerIds.contains(layerBZoneId), "assertion 12a: installedZoneLayerIds must not contain B after remove")
        try expect(layerCanvas.tileView(for: tBId) == nil, "assertion 12b: tileView(for: tB) should be nil after removeZoneLayer")
        try expect(layerCanvas.tileId(at: CGPoint(x: 800, y: 50)) == nil, "assertion 12c: hit at (800,50) should be nil — no layer there after removing B")
        // THE assertion: requestFocus returns false → adapter was unregistered
        let focusBAfterRemove = broker.requestFocus(.tile(tBId), reason: .userClick)
        try expect(!focusBAfterRemove, "assertion 12d: requestFocus(.tile(tB)) must return false after removeZoneLayer (adapter unregistered)")
        // Survivors intact: (200,100) is inside tA world (40,52,180,120) but outside tOver world (x>160)
        try expect(broker.requestFocus(.tile(tAId), reason: .userClick), "assertion 12e: tA adapter must still be registered after removing B")
        try expect(layerCanvas.tileId(at: CGPoint(x: 200, y: 100)) == tAId, "assertion 12f: (200,100) should still resolve to tA (outside tOver, inside tA)")

        let layerManifestFields: [String: Any] = [
            "installedZoneLayerIds": layerCanvas.installedZoneLayerIds.map { $0.uuidString },
            "perLayerTileFrames": [
                layerAZoneId.uuidString: [tAId.uuidString: rectDictionary(layerCanvas.tileView(for: tAId)?.frame ?? .zero)],
                layerBZoneId.uuidString: [:],
                layerGZoneId.uuidString: [tGId.uuidString: rectDictionary(layerCanvas.tileView(for: tGId)?.frame ?? .zero)]
            ],
            "perLayerHitIds": [
                "50_60": layerCanvas.tileId(at: CGPoint(x: 50, y: 60))?.uuidString as Any,
                "40_560": layerCanvas.tileId(at: CGPoint(x: 40, y: 560))?.uuidString as Any
            ],
            "crossLayerSubviewOrder": subviewTileIds.map { $0.uuidString },
            "adapterRegisteredOnAdd": [
                tAId.uuidString: true,
                tGId.uuidString: true
            ],
            "overlapTopHitId": tOverId.uuidString,
            "afterRemoveB": [
                "installedIds": layerCanvas.installedZoneLayerIds.map { $0.uuidString },
                "tBViewPresent": layerCanvas.tileView(for: tBId) != nil,
                "hitAtB": layerCanvas.tileId(at: CGPoint(x: 800, y: 50))?.uuidString as Any,
                "focusBFalse": !focusBAfterRemove,
                "aStillFocusable": true
            ]
        ]

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
            "screenshots": [screenshot.path],
            "multiLayerAssertions": layerManifestFields
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

    // MARK: - Zone adaptive bounds check (T11)

    /// Real-path check (zone-unify P3): a zone renders at its STORED frame
    /// (stable, not hugging), the move-grab header coincides with the visible
    /// chrome, moving a tile inside does NOT reshape the zone, and resizing a tile
    /// beyond the frame GROWS it (never shrinks). Drives real NSEvent drags.
    static func runZoneAdaptiveBoundsSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String { switch self { case let .failed(message): return message } }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }
        func expectFrame(_ actual: TileFrame?, _ expected: TileFrame, tolerance: Double = 0.5, _ message: String) throws {
            guard let a = actual else { throw CheckError.failed("\(message): got nil") }
            guard abs(a.x - expected.x) <= tolerance && abs(a.y - expected.y) <= tolerance
                && abs(a.width - expected.width) <= tolerance && abs(a.height - expected.height) <= tolerance
            else { throw CheckError.failed("\(message): expected \(expected), got \(a)") }
        }

        let viewport = CanvasViewport(x: 0, y: 0, zoom: 1)

        // UUIDs for this check — stable and outside every other check's space.
        let zoneId = UUID(uuidString: "00000000-0000-0000-0000-000000005B01")!
        let projId = UUID(uuidString: "00000000-0000-0000-0000-000000005B00")!
        let t1Id   = UUID(uuidString: "00000000-0000-0000-0000-000000005B11")!
        let t2Id   = UUID(uuidString: "00000000-0000-0000-0000-000000005B12")!

        // Zone at origin (0,0). Tiles zone-local (world == zone-local at origin 0,0).
        let zone = ZonePlacement(zoneId: zoneId, projectId: projId, origin: ZonePoint(x: 0, y: 0),
                                 size: ZoneSize(width: 600, height: 400), color: "blue",
                                 collapsed: false, hydrationPolicy: .automatic)
        // height=170: above the .note minimum (160), so shrink-by-60 returns cleanly to 170.
        // (spec listed h=120 but derived expected values as if h=150; h=150 < .note min 160,
        //  which would clamp the -60 shrink. h=170 matches the spec's structural assertions
        //  while being minimum-safe. adaptive h = 170+48+34=252 instead of spec's 232.)
        let t1Frame = TileFrame(x: 40, y: 52, width: 180, height: 170)
        let t2Frame = TileFrame(x: 260, y: 52, width: 180, height: 170)
        let tile1 = Tile(id: t1Id, kind: .note, title: "ZAB_T1", frame: t1Frame, zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        let tile2 = Tile(id: t2Id, kind: .note, title: "ZAB_T2", frame: t2Frame, zPosition: .fromLegacyRank(2), runtimeRef: nil, metadata: TileMetadata())

        let canvas = CanvasNSView(
            canvasState: CanvasState(viewport: viewport, tiles: [tile1, tile2], groups: [], lastActiveTileId: nil),
            activeZone: zone,
            zoneRenderModels: [ZoneRenderModel(placement: zone, displayName: "ZAB")],
            showsZoneChrome: true
        )
        // Disable drag-magnetize so resize assertions are not confounded by snap-to-neighbor.
        let noSnapDefaults = UserDefaults(suiteName: "zone-adaptive-bounds-no-snap-\(UUID().uuidString)")!
        noSnapDefaults.set(false, forKey: DragMagnetizeConfig.enabledKey)
        canvas.dragMagnetizeDefaults = noSnapDefaults
        canvas.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontRegardless()

        let view1 = DescriptorTileNSView(tile: tile1)
        let view2 = DescriptorTileNSView(tile: tile2)
        canvas.install(tileView: view1, for: tile1)
        canvas.install(tileView: view2, for: tile2)
        canvas.layoutSubtreeIfNeeded()

        func mouse(_ type: NSEvent.EventType, at p: NSPoint) throws -> NSEvent {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            else { throw CheckError.failed("could not synthesize \(type) at \(p)") }
            return e
        }

        // Assertion 1: the zone renders at its STORED frame (0,0,600,400),
        // NOT an adaptive hug of the tiles.
        let storedFrame = TileFrame(x: 0, y: 0, width: 600, height: 400)
        try expectFrame(canvas.qaZoneDrawnWorldBounds(for: zoneId), storedFrame, "assertion 1: zone renders at its stored placement frame (not hugging)")

        // Assertion 2: the move-grab header rect coincides with the visible chrome
        // top — so the zone is movable by grabbing what you see (the old divergence
        // between adaptive chrome and the placement-based grab rect is gone).
        guard let snap1 = canvas.zoneChromeSnapshot(for: zoneId) else { throw CheckError.failed("assertion 2: missing chrome snapshot") }
        guard let grab = canvas.qaZoneHeaderGrabRect(zoneId) else { throw CheckError.failed("assertion 2: missing header grab rect") }
        try expect(abs(grab.minX - snap1.frame.minX) < 0.5 && abs(grab.minY - snap1.frame.minY) < 0.5,
                   "assertion 2: header grab rect top must align with the visible chrome top; grab=\(grab), chrome=\(snap1.frame)")

        // Assertion 3: moving a tile WITHIN the zone does NOT reshape it.
        let grab2 = view2.convert(NSPoint(x: view2.bounds.midX, y: TileNSView.titleBarHeight / 2), to: nil)
        view2.mouseDown(with: try mouse(.leftMouseDown, at: grab2))
        view2.mouseDragged(with: try mouse(.leftMouseDragged, at: NSPoint(x: grab2.x + 100, y: grab2.y)))
        view2.mouseUp(with: try mouse(.leftMouseUp, at: NSPoint(x: grab2.x + 100, y: grab2.y)))
        try expectFrame(canvas.qaZoneDrawnWorldBounds(for: zoneId), storedFrame, "assertion 3: moving a tile inside must NOT reshape the zone")

        // Assertion 4: resizing a tile beyond the zone GROWS it (never shrinks below
        // the original frame). Drag tile2's bottom edge down well past the 400 floor.
        let resizeLocal = NSPoint(x: view2.bounds.midX, y: view2.bounds.height - 1)
        try expect(view2.qaResizeEdge(at: resizeLocal) == .bottom, "assertion 4 precondition: grab point must be the bottom resize edge")
        let resizeWindow = view2.convert(resizeLocal, to: nil)
        view2.mouseDown(with: try mouse(.leftMouseDown, at: resizeWindow))
        view2.mouseDragged(with: try mouse(.leftMouseDragged, at: NSPoint(x: resizeWindow.x, y: resizeWindow.y - 250)))
        view2.mouseUp(with: try mouse(.leftMouseUp, at: NSPoint(x: resizeWindow.x, y: resizeWindow.y - 250)))
        guard let grown = canvas.qaZoneDrawnWorldBounds(for: zoneId) else { throw CheckError.failed("assertion 4: nil bounds") }
        try expect(grown.height > 400 + 0.5, "assertion 4: resizing a tile beyond the zone must grow its height; got \(grown.height)")
        try expect(grown.x <= 0.5 && grown.y <= 0.5 && grown.x + grown.width >= 600 - 0.5 && grown.y + grown.height >= 400 - 0.5,
                   "assertion 4: grown zone must still contain the original frame; got \(grown)")

        // Assertion 9: Non-blank render (grey-screen guard) + PNG artifact.
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath)
        let directory = root
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent("zone-adaptive-bounds-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let screenshot = directory.appendingPathComponent("zone-adaptive-bounds.png")
        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            throw CheckError.failed("assertion 9: bitmap rep was not created")
        }
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]), !png.isEmpty else {
            throw CheckError.failed("assertion 9: PNG data was empty")
        }
        try png.write(to: screenshot, options: .atomic)
        let metrics = VisualSnapshot.metrics(of: rep)
        try expect(!metrics.isBlank, "assertion 9: non-blank render guard — got \(metrics.distinctSampledColors) distinct sampled colors at \(metrics.width)x\(metrics.height)")

        let artifact = directory.appendingPathComponent("manifest.json")
        let manifest: [String: Any] = [
            "check": "zone-frame (stable; move=no-reshape, resize=grow)",
            "path": "synthesized NSEvent move/resize through TileNSView (real drag path)",
            "storedFrame": ["x": storedFrame.x, "y": storedFrame.y, "w": storedFrame.width, "h": storedFrame.height],
            "screenshots": [screenshot.path]
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
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
        let working = Tile(id: workingTileId, kind: .terminal, title: "Agent · Claude", frame: TileFrame(x: 32, y: 52, width: 220, height: 140), zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        let needs = Tile(id: needsTileId, kind: .terminal, title: "Agent · Codex", frame: TileFrame(x: 280, y: 52, width: 220, height: 140), zPosition: .fromLegacyRank(2), runtimeRef: nil, metadata: TileMetadata())
        let plain = Tile(id: plainTileId, kind: .terminal, title: "Shell", frame: TileFrame(x: 528, y: 52, width: 180, height: 140), zPosition: .fromLegacyRank(3), runtimeRef: nil, metadata: TileMetadata())
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
            zPosition: .fromLegacyRank(1),
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
        var contentTopMatchesBar: [String: Bool] = [:]
        var prevBarHeight = tileView.chromeBarHeight
        // When the floored bar height does NOT change between zooms (the common
        // zoomed-IN regime), the content view must NOT be relaid out — that is
        // the world-bounds guarantee that AppKit's frame transform, not a manual
        // reflow, scales the body. The content only re-frames when the bar height
        // genuinely changes (the title-bar zoom-floor coupling).
        for zoom in zooms {
            canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
            tileView.probe.setFrameSizeCalls = 0
            tileView.layoutSubtreeIfNeeded()
            let barHeight = tileView.chromeBarHeight
            if barHeight == prevBarHeight {
                try expect(tileView.probe.setFrameSizeCalls == 0, "content setFrameSize calls during zoom \(zoom) (bar height unchanged at \(barHeight)) should be zero, got \(tileView.probe.setFrameSizeCalls) sizes=\(tileView.probe.observedSizes)")
            }
            prevBarHeight = barHeight
            // Content top must track the floored bar height (no overlap/gap).
            let contentTop = tileView.contentView?.frame.minY ?? -1
            contentTopMatchesBar[String(zoom)] = abs(contentTop - barHeight) < 0.001
            try expect(contentTopMatchesBar[String(zoom)] == true, "content top \(contentTop) must equal floored bar height \(barHeight) at zoom \(zoom)")
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

        try expect(edgePasses.values.allSatisfy { $0 }, "resize-edge hit tests failed: \(edgePasses)")
        try expect(cornerPasses.values.allSatisfy { $0 }, "resize-corner hit tests failed: \(cornerPasses)")
        try expect(contentTopMatchesBar.values.allSatisfy { $0 }, "content top must track floored bar height: \(contentTopMatchesBar)")

        let manifest: [String: Any] = [
            "check": "tile-world-bounds",
            "worldSize": ["width": tile.frame.width, "height": tile.frame.height],
            "zooms": zooms,
            "screenFrames": frames,
            "bounds": bounds,
            "contentSetFrameSizeCallsAfterInstall": callsAfterInstall,
            "resizeEdgePasses": edgePasses,
            "resizeCornerPasses": cornerPasses,
            "contentTopMatchesBar": contentTopMatchesBar
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
            zPosition: .fromLegacyRank(1),
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
            // Probe on the LEFT of the title bar, clear of the close button: it sits
            // top-right and is floored to stay clickable, so at extreme zoom-out it
            // balloons to fill most of the (also-floored) bar — a center probe would
            // legitimately land on it (a CLOSE target, not move).
            let stripY = (floor + grab) / 2
            let closeMinX = tileView.qaCloseButtonFrame.minX
            let stripX = closeMinX > m + 2 ? (m + closeMinX) / 2 : midX
            stripIsMove[String(zoom)] = tileView.qaDragKindIsMove(at: CGPoint(x: stripX, y: stripY))
            // Routing: the click must reach the tile's move handling (not body
            // content) so mouseDown classifies it as .move. The strip resolves to
            // EITHER the tile view (floored hitTest strip below the drawn bar) OR
            // the now-zoom-floored title bar, which forwards mouseDown to the tile
            // → .move. Either proves the move target survives at low zoom; only a
            // fall-through to body would be a regression.
            stripRoutesToTile[String(zoom)] = tileView.qaHitRoutesToMove(atLocal: CGPoint(x: stripX, y: stripY))

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

        // --- Resize-ring reclaim from body content at a non-origin pan/zoom ---
        // Regression guard for the hitTest coordinate bug: the bottom/left/right and
        // bottom-corner rings must be reclaimed from a covering content view even when
        // the tile is panned AND zoomed (so superview coords != local bounds coords).
        // The old hitTest used the raw superview point as if it were local, so only an
        // origin tile at zoom 1 reclaimed the ring — at any real position body content
        // swallowed bottom/side/corner resize clicks (top survived only because the
        // title bar forwards mouseDown). This drives the REAL hitTest resolution.
        var ringReclaim: [String: Bool] = [:]
        var ringBodyReclaimed = true
        do {
            let probe = Tile(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000011C0")!,
                kind: .note,
                title: "RING_PROBE",
                frame: TileFrame(x: 260, y: 180, width: 320, height: 240),
                zPosition: .fromLegacyRank(1),
                runtimeRef: nil,
                metadata: TileMetadata()
            )
            let ringCanvas = CanvasNSView(canvasState: CanvasState(viewport: CanvasViewport(x: 40, y: 25, zoom: 1.5), tiles: [probe], groups: [], lastActiveTileId: nil))
            ringCanvas.frame = NSRect(x: 0, y: 0, width: 1200, height: 900)
            let ringWindow = NSWindow(contentRect: ringCanvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            ringWindow.contentView = ringCanvas
            ringWindow.orderFrontRegardless()
            let ringView = TileNSView(tile: probe)
            ringCanvas.install(tileView: ringView, for: probe)
            ringView.setContentView(NSView(frame: .zero)) // a body that would swallow ring clicks
            ringCanvas.layoutSubtreeIfNeeded()

            let w = ringView.bounds.width
            let h = ringView.bounds.height
            let rm = TileNSView.resizeMargin / 1.5
            let ringProbes: [(String, CGPoint)] = [
                ("bottom", CGPoint(x: w / 2, y: h - 1)),
                ("left", CGPoint(x: 1, y: h / 2)),
                ("right", CGPoint(x: w - 1, y: h / 2)),
                ("bottomLeft", CGPoint(x: 1, y: h - 1)),
                ("bottomRight", CGPoint(x: w - 1, y: h - 1)),
            ]
            for (name, p) in ringProbes {
                try expect(ringView.qaResizeEdge(at: p) != nil, "ring probe \(name) must sit on the resize ring (local-coords premise); got nil at \(p)")
                ringReclaim[name] = ringView.qaHitRoutesToMove(atLocal: p)
            }
            // A deep-body point must still reach the content view (we didn't over-claim).
            let bodyPoint = CGPoint(x: w / 2, y: (ringView.grabHeightInLocalCoordinates + (h - rm)) / 2)
            try expect(ringView.qaResizeEdge(at: bodyPoint) == nil, "body probe must be off the ring; got \(String(describing: ringView.qaResizeEdge(at: bodyPoint)))")
            ringBodyReclaimed = ringView.qaHitRoutesToMove(atLocal: bodyPoint)
        }
        try expect(ringReclaim.values.allSatisfy { $0 == true }, "a panned/zoomed tile must reclaim the resize ring from body content on every edge/corner: \(ringReclaim)")
        try expect(ringBodyReclaimed == false, "a deep-body click must reach content, not be reclaimed by the tile as a resize/move")

        let manifest: [String: Any] = [
            "check": "tile-drag-grab",
            "ringReclaim": ringReclaim,
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

    /// Geometry check for the zoom-scaled title-bar chrome: builds a real
    /// `TileNSView`, drives the canvas zoom, runs layout, then reads the
    /// LAID-OUT bar + close-button frames (not the constants) and asserts their
    /// ON-SCREEN size (`worldHeight * zoom`) stays in a usable band across zoom.
    static func runTileChromeScaleSelfCheck() throws -> URL {
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

        // Tall enough that a body region survives below the floored bar even at
        // the lowest test zoom (mirrors the drag-grab probe's reasoning).
        let tile = Tile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001135")!,
            kind: .terminal,
            title: "CHROME_SCALE_PROBE",
            frame: TileFrame(x: 40, y: 30, width: 400, height: 1000),
            zPosition: .fromLegacyRank(1),
            runtimeRef: nil,
            metadata: TileMetadata()
        )
        let canvas = CanvasNSView(canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [tile], groups: [], lastActiveTileId: nil))
        canvas.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let tileView = TileNSView(tile: tile)
        // A real content view so the bar/content offset coupling is exercised.
        tileView.setContentView(NSView(frame: .zero))
        canvas.install(tileView: tileView, for: tile)
        tileView.layoutSubtreeIfNeeded()

        // Comfortable on-screen floor for the close button's hit size. The
        // drawn bar floors to `minScreenGrabPx` (28). Both must clear ~22px.
        let minUsableScreenPx: CGFloat = 22
        let zooms: [Double] = [0.3, 1.0, 3.0]
        var barScreenHeights: [String: Double] = [:]
        var closeScreenSizes: [String: Double] = [:]
        var titleScreenSizes: [String: Double] = [:]
        var contentTopWorld: [String: Double] = [:]
        var contentTopMatchesBar: [String: Bool] = [:]
        // The title text scales with the bar, so it must stay legible on screen
        // (>= this) instead of shrinking with zoom.
        let minTitleScreenPx: CGFloat = 11
        for zoom in zooms {
            canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
            tileView.layoutSubtreeIfNeeded()

            // Read laid-out world frames and convert to on-screen px via the zoom
            // transform (bounds are world-sized; frame = bounds * zoom).
            let barWorldHeight = tileView.qaTitleBarFrame.height
            let closeWorld = tileView.qaCloseButtonFrame
            let barScreenH = barWorldHeight * CGFloat(zoom)
            let closeScreenW = closeWorld.width * CGFloat(zoom)
            let closeScreenH = closeWorld.height * CGFloat(zoom)
            barScreenHeights[String(zoom)] = barScreenH
            closeScreenSizes[String(zoom)] = min(closeScreenW, closeScreenH)
            let titleScreen = tileView.qaTitleFontWorldSize * CGFloat(zoom)
            titleScreenSizes[String(zoom)] = titleScreen

            // Content offset must track the SAME floored bar height — no overlap,
            // no gap. Read the laid-out content view's top edge (world units).
            let contentTop = tileView.contentView?.frame.minY ?? -1
            contentTopWorld[String(zoom)] = contentTop
            contentTopMatchesBar[String(zoom)] = abs(contentTop - barWorldHeight) < 0.001

            try expect(barScreenH >= minUsableScreenPx, "zoom \(zoom): title bar on-screen height \(barScreenH)px must be >= \(minUsableScreenPx)px")
            try expect(closeScreenW >= minUsableScreenPx && closeScreenH >= minUsableScreenPx, "zoom \(zoom): close button on-screen hit size \(closeScreenW)x\(closeScreenH)px must be >= \(minUsableScreenPx)px")
            try expect(contentTopMatchesBar[String(zoom)] == true, "zoom \(zoom): content top \(contentTop) must equal floored bar height \(barWorldHeight)")
            // The close button must fit inside the bar at every zoom (otherwise
            // it clips and the × becomes partially unclickable).
            try expect(closeWorld.maxY <= barWorldHeight + 0.001, "zoom \(zoom): close button bottom \(closeWorld.maxY) must fit inside bar height \(barWorldHeight)")
            try expect(titleScreen >= minTitleScreenPx, "zoom \(zoom): title on-screen point size \(titleScreen)px must be >= \(minTitleScreenPx)px (must not shrink with zoom)")
        }

        // Floor only KICKS IN when zoomed out: at zoom 3 (zoomed in) the bar is
        // the NATURAL titleBarHeight in world units (floor inert), so on screen it
        // is `titleBarHeight * 3` — proving the floor doesn't inflate chrome when
        // zoomed in. Conversely at zoom 1 the floor is `minScreenGrabPx` (the bar
        // is intentionally aliased to the grab strip, so it never drops below it).
        try expect(abs((barScreenHeights["3.0"] ?? 0) - Double(TileNSView.titleBarHeight) * 3) < 0.5, "zoom 3: zoomed-in bar should be the natural titleBarHeight*3 on screen (floor inert), got \(barScreenHeights["3.0"] ?? 0)")
        try expect(abs((barScreenHeights["1.0"] ?? 0) - Double(TileNSView.minScreenGrabPx)) < 0.5, "zoom 1: bar should floor to minScreenGrabPx (aliased to grab strip), got \(barScreenHeights["1.0"] ?? 0)")

        let manifest: [String: Any] = [
            "check": "tile-chrome-scale",
            "worldSize": ["width": tile.frame.width, "height": tile.frame.height],
            "titleBarHeight": TileNSView.titleBarHeight,
            "minScreenGrabPx": TileNSView.minScreenGrabPx,
            "minScreenCloseButtonPx": TileNSView.minScreenCloseButtonPx,
            "minUsableScreenPx": minUsableScreenPx,
            "zooms": zooms,
            "barScreenHeights": barScreenHeights,
            "closeScreenSizes": closeScreenSizes,
            "titleScreenSizes": titleScreenSizes,
            "minTitleScreenPx": minTitleScreenPx,
            "contentTopWorld": contentTopWorld,
            "contentTopMatchesBar": contentTopMatchesBar
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("tile-chrome-scale", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    /// P2 (resize HUD): drives a REAL tile resize drag through
    /// `TileNSView.mouseDown/Dragged/Up` and asserts the live "W × H" overlay
    /// appears with the dragged dimensions mid-drag and is hidden on release.
    /// RED until `TileNSView`'s resize branch calls `showResizeDimensions`.
    static func runResizeDimensionsHUDSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String { switch self { case let .failed(m): return m } }
        }
        func expect(_ c: @autoclosure () -> Bool, _ m: String) throws { if !c() { throw CheckError.failed(m) } }
        func mouse(_ type: NSEvent.EventType, at p: NSPoint, window: NSWindow) throws -> NSEvent {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            else { throw CheckError.failed("could not synthesize \(type)") }
            return e
        }

        let canvasH: CGFloat = 700
        // Canvas-local (y-down, top-left) → window (y-up, bottom-left).
        func win(_ cx: CGFloat, _ cy: CGFloat) -> NSPoint { NSPoint(x: cx, y: canvasH - cy) }

        // Tile at world (100,100) size 400×300, zoom 1, viewport (0,0):
        // its screen frame == world, so the right edge is canvas-local x=500.
        let tile = Tile(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000005CC")!,
            kind: .note,
            title: "HUD_PROBE",
            frame: TileFrame(x: 100, y: 100, width: 400, height: 300),
            zPosition: .fromLegacyRank(1),
            runtimeRef: nil,
            metadata: TileMetadata()
        )
        let canvas = CanvasNSView(canvasState: CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [tile], groups: [], lastActiveTileId: nil
        ))
        canvas.frame = NSRect(x: 0, y: 0, width: 1000, height: canvasH)

        let suite = "resize-hud-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        canvas.resizeHUDDefaults = defaults
        defer { defaults.removePersistentDomain(forName: suite) }

        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontRegardless()
        let tileView = TileNSView(tile: tile)
        tileView.setContentView(NSView(frame: .zero))
        canvas.install(tileView: tileView, for: tile)
        canvas.layoutSubtreeIfNeeded()

        try expect(canvas.qaResizeHUDVisible == false, "HUD must be hidden before any resize")

        // Grab the right edge mid-height (canvas-local x≈498, y=250 → tile-local
        // (398,150), clear of the corner bands), drag +100 px wider.
        tileView.mouseDown(with: try mouse(.leftMouseDown, at: win(498, 250), window: window))
        tileView.mouseDragged(with: try mouse(.leftMouseDragged, at: win(598, 250), window: window))

        try expect(canvas.qaResizeHUDVisible == true, "HUD must be visible during a resize drag")
        let midText = canvas.qaResizeHUDText
        try expect(midText.contains("500"), "HUD must show the live dragged width 500; got '\(midText)'")

        tileView.mouseUp(with: try mouse(.leftMouseUp, at: win(598, 250), window: window))
        try expect(canvas.qaResizeHUDVisible == false, "HUD must hide on mouseUp; still showing '\(canvas.qaResizeHUDText)'")

        let fm = FileManager.default
        let dir = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent("resize-dimensions-hud-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let artifact = dir.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: ["check": "resize-dimensions-hud", "midDragText": midText], options: [.sortedKeys]).write(to: artifact, options: .atomic)
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
        let lower = Tile(id: lowerId, kind: .note, title: "LOWER_PROBE", frame: lowerFrame, zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        let upper = Tile(id: upperId, kind: .note, title: "UPPER_STEALS_ON_REATTACH", frame: upperFrame, zPosition: .fromLegacyRank(10), runtimeRef: nil, metadata: TileMetadata())
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
        let beforeZ = Dictionary(uniqueKeysWithValues: canvas.canvasState.tiles.map { ($0.id.uuidString, $0.zPosition.value) })

        // Operation under test: production bring-to-front only. Do not call any
        // runtime/probe focus repair after this point; that would mask BUG-004.
        canvas.bringToFront(tileId: lowerId)

        let afterVisualOrder = canvas.subviews.compactMap { ($0 as? TileNSView)?.tile.id }
        let afterZ = Dictionary(uniqueKeysWithValues: canvas.canvasState.tiles.map { ($0.id.uuidString, $0.zPosition.value) })
        let afterResponderOwner = owner(of: window.firstResponder)
        let semanticHitAfter = canvas.tileId(at: overlappedHitPoint)
        let sentinel = "b"
        try dispatchKey(sentinel, in: window)

        try expect(canvas.canvasState.tiles.first(where: { $0.id == lowerId })?.zPosition == canvas.canvasState.tiles.map(\.zPosition).max(), "lower tile should have max zPosition after bring-to-front")
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
        let tileA = Tile(id: tileAId, kind: .note, title: "SCOPE_A", frame: TileFrame(x: 60, y: 60, width: 280, height: 200), zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        let tileB = Tile(id: tileBId, kind: .note, title: "SCOPE_B", frame: TileFrame(x: 420, y: 60, width: 280, height: 200), zPosition: .fromLegacyRank(2), runtimeRef: nil, metadata: TileMetadata())
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
        let tileA = Tile(id: tileAId, kind: .note, title: "BORDER_A", frame: TileFrame(x: 60, y: 60, width: 280, height: 200), zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        let tileB = Tile(id: tileBId, kind: .note, title: "BORDER_B", frame: TileFrame(x: 420, y: 60, width: 280, height: 200), zPosition: .fromLegacyRank(2), runtimeRef: nil, metadata: TileMetadata())
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

    // MARK: - Zone create/move gesture check (T19)

    /// P1 (zone naming): a drag-created zone is auto-named "<base> N" (default
    /// "Zone 1", "Zone 2", …), the name shows in the chrome (displayName) and the
    /// stored placement, is carried by `onZoneCreated`, and round-trips through
    /// Codable. RED today (drag-create leaves the name blank).
    static func runZoneAutoNameSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String { switch self { case let .failed(m): return m } }
        }
        func expect(_ c: @autoclosure () -> Bool, _ m: String) throws { if !c() { throw CheckError.failed(m) } }
        func mouse(_ type: NSEvent.EventType, at p: NSPoint, window: NSWindow) throws -> NSEvent {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            else { throw CheckError.failed("could not synthesize \(type)") }
            return e
        }
        let cH: CGFloat = 700
        func win(_ cx: CGFloat, _ cy: CGFloat) -> NSPoint { NSPoint(x: cx, y: cH - cy) }
        func createDrag(_ canvas: CanvasNSView, _ window: NSWindow, from a: NSPoint, to b: NSPoint) throws {
            canvas.mouseDown(with: try mouse(.leftMouseDown, at: a, window: window))
            canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: b, window: window))
            canvas.mouseUp(with: try mouse(.leftMouseUp, at: b, window: window))
        }

        let canvas = CanvasNSView(
            canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil),
            showsZoneChrome: true
        )
        canvas.frame = NSRect(x: 0, y: 0, width: 1000, height: cH)

        let gestureSuite = "autoname-gesture-\(UUID().uuidString)"
        let gestureDefaults = UserDefaults(suiteName: gestureSuite)!
        gestureDefaults.removePersistentDomain(forName: gestureSuite)
        canvas.zoneGestureDefaults = gestureDefaults
        defer { gestureDefaults.removePersistentDomain(forName: gestureSuite) }

        let nameSuite = "autoname-name-\(UUID().uuidString)"
        let nameDefaults = UserDefaults(suiteName: nameSuite)!
        nameDefaults.removePersistentDomain(forName: nameSuite)
        canvas.zoneNameDefaults = nameDefaults
        defer { nameDefaults.removePersistentDomain(forName: nameSuite) }

        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontRegardless()
        canvas.layoutSubtreeIfNeeded()

        var created: [ZonePlacement] = []
        canvas.onZoneCreated = { created.append($0) }

        // First zone: canvas-local (120,150)→(520,470).
        try createDrag(canvas, window, from: win(120, 150), to: win(520, 470))
        try expect(created.count == 1, "first create should fire onZoneCreated once; got \(created.count)")
        let z1 = created[0].zoneId
        try expect(canvas.qaZoneDisplayName(z1) == "Zone 1", "first zone displayName must be 'Zone 1'; got '\(canvas.qaZoneDisplayName(z1) ?? "nil")'")
        try expect(canvas.qaLiveZonePlacement(z1)?.name == "Zone 1", "first zone stored name must be 'Zone 1'; got '\(canvas.qaLiveZonePlacement(z1)?.name ?? "nil")'")
        try expect(created[0].name == "Zone 1", "onZoneCreated placement must carry the name")

        // Second zone in a different empty region: (600,200)→(900,500).
        try createDrag(canvas, window, from: win(600, 200), to: win(900, 500))
        try expect(created.count == 2, "second create should fire onZoneCreated; got \(created.count)")
        let z2 = created[1].zoneId
        try expect(canvas.qaZoneDisplayName(z2) == "Zone 2", "second zone displayName must be 'Zone 2'; got '\(canvas.qaZoneDisplayName(z2) ?? "nil")'")

        // Persist round-trip: the name survives encode → decode.
        let data = try JSONEncoder().encode(created[0])
        let decoded = try JSONDecoder().decode(ZonePlacement.self, from: data)
        try expect(decoded.name == "Zone 1", "zone name must survive Codable round-trip; got '\(decoded.name)'")

        let fm = FileManager.default
        let dir = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent("zone-autoname-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let artifact = dir.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: ["check": "zone-autoname", "names": [canvas.qaZoneDisplayName(z1) ?? "", canvas.qaZoneDisplayName(z2) ?? ""]], options: [.sortedKeys]).write(to: artifact, options: .atomic)
        return artifact
    }

    /// P2 (zone naming): double-clicking a zone HEADER begins inline rename;
    /// committing updates the display name + stored name + fires `onZoneRenamed`;
    /// an empty commit keeps the old name; double-clicking the zone BODY still
    /// zoom-fits (didn't break). RED until `mouseDown` routes header double-click
    /// to `beginZoneRename`.
    static func runZoneRenameInlineSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String { switch self { case let .failed(m): return m } }
        }
        func expect(_ c: @autoclosure () -> Bool, _ m: String) throws { if !c() { throw CheckError.failed(m) } }
        func mouse(_ type: NSEvent.EventType, at p: NSPoint, clicks: Int, window: NSWindow) throws -> NSEvent {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)
            else { throw CheckError.failed("could not synthesize \(type)") }
            return e
        }
        let cH: CGFloat = 700
        func win(_ cx: CGFloat, _ cy: CGFloat) -> NSPoint { NSPoint(x: cx, y: cH - cy) }

        let canvas = CanvasNSView(
            canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil),
            showsZoneChrome: true
        )
        canvas.frame = NSRect(x: 0, y: 0, width: 1000, height: cH)
        let suite = "zone-rename-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        canvas.zoneGestureDefaults = defaults
        canvas.zoneNameDefaults = defaults
        defer { defaults.removePersistentDomain(forName: suite) }
        // A titled, key-able window so the inline NSTextField can hold the field
        // editor (a borderless window can't become key → the editor would end
        // immediately, tearing the session down).
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)
        canvas.layoutSubtreeIfNeeded()

        var created: [ZonePlacement] = []
        canvas.onZoneCreated = { created.append($0) }
        // Create a zone (auto-named "Zone 1"): canvas-local (120,150)→(520,470).
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: win(120, 150), clicks: 1, window: window))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: win(520, 470), clicks: 1, window: window))
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: win(520, 470), clicks: 1, window: window))
        try expect(created.count == 1, "zone created; got \(created.count)")
        let zoneId = created[0].zoneId
        try expect(canvas.qaZoneDisplayName(zoneId) == "Zone 1", "seed name 'Zone 1'; got '\(canvas.qaZoneDisplayName(zoneId) ?? "nil")'")

        var renamed: [(UUID, String)] = []
        canvas.onZoneRenamed = { renamed.append(($0, $1)) }

        // Double-click the HEADER (mid-x 300, y 165 ∈ [150,182]) → begin rename.
        // (No trailing canvas mouseUp: in the real app the up lands on the field
        // now covering the header, not the canvas; routing to the canvas would read
        // as a click-away that commits + ends the session.)
        let headerPoint = win(300, 165)
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: headerPoint, clicks: 2, window: window))
        try expect(canvas.qaZoneRenameBeginCount == 1, "double-click header must begin inline rename (not zoom-fit); beginCount=\(canvas.qaZoneRenameBeginCount)")

        // PRIMARY REGRESSION (live double-click never began editing): `selectText(_:)`
        // ends current editing via `-[NSWindow endEditingFor:]`, which posts a
        // synchronous end-editing notification for the field editor `beginZoneRename`
        // just attached. Without the `isOpeningZoneRename` gate the delegate treated
        // that as a commit and tore the field down inside `beginZoneRename` itself, so
        // the rename never survived its own opening gesture. It must stay OPEN.
        try expect(canvas.qaZoneRenameActiveZoneId == zoneId,
                   "double-click must leave the rename OPEN (selectText must not self-commit); got \(String(describing: canvas.qaZoneRenameActiveZoneId))")

        // SECONDARY REGRESSION: the app's `.leftMouseUp` monitor routes click-focus on
        // the up of that same double-click via `routeTileClickFocus`. Over a zone
        // header (no tile) it would `enterScope(.canvas)` → `makeFirstResponder(canvas)`,
        // stealing the field's first responder and ending the rename. The router must
        // leave an open rename alone when the up lands on the renamed zone's header.
        let focusBroker = FocusBroker()
        focusBroker.register(canvas)  // CanvasNSView is its own `.canvas` adapter.
        var routedToCanvas = false
        focusBroker.onAcceptedCanvasScope = { routedToCanvas = true }
        AppDelegate.routeTileClickFocus(at: headerPoint, in: canvas, focusBroker: focusBroker)
        try expect(!routedToCanvas, "click-focus over an open rename header must NOT reroute focus (would tear the rename down)")
        try expect(canvas.qaZoneRenameActiveZoneId == zoneId, "rename must stay open after the opening double-click's mouse-up")
        // A click-away (off the header) commits the rename, THEN routes focus normally.
        AppDelegate.routeTileClickFocus(at: win(800, 600), in: canvas, focusBroker: focusBroker)
        try expect(canvas.qaZoneRenameActiveZoneId == nil, "a click-away must commit + end the rename")
        try expect(routedToCanvas, "after committing, a background click-away must still route focus to the canvas")

        // Commit "Work" via the real mutation path (field-editor lifecycle is AppKit
        // and not reproducible headlessly).
        canvas.qaRenameZone(zoneId, to: "Work")
        try expect(canvas.qaZoneDisplayName(zoneId) == "Work", "displayName after rename must be 'Work'; got '\(canvas.qaZoneDisplayName(zoneId) ?? "nil")'")
        try expect(canvas.qaLiveZonePlacement(zoneId)?.name == "Work", "stored name after rename must be 'Work'")
        try expect(renamed.count == 1 && renamed[0].1 == "Work", "onZoneRenamed must fire once with 'Work'; got \(renamed)")

        // Empty/whitespace rename keeps the previous name.
        canvas.qaRenameZone(zoneId, to: "   ")
        try expect(canvas.qaLiveZonePlacement(zoneId)?.name == "Work", "empty rename must keep the previous name")
        try expect(renamed.count == 1, "empty rename must not fire onZoneRenamed again; got \(renamed.count)")

        // Double-click the zone BODY (below header, no tile) still zoom-fits.
        let before = canvas.canvasState.viewport
        let bodyPoint = win(300, 320)
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: bodyPoint, clicks: 2, window: window))
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: bodyPoint, clicks: 2, window: window))
        let after = canvas.canvasState.viewport
        try expect(after.zoom != before.zoom || abs(after.x - before.x) > 0.01 || abs(after.y - before.y) > 0.01,
                   "double-click on the zone body must still zoom-fit (viewport should change)")
        try expect(canvas.qaZoneRenameActiveZoneId == nil, "body double-click must NOT begin rename")

        // Renamed name survives a Codable round-trip.
        let placement = canvas.qaLiveZonePlacement(zoneId)!
        let decoded = try JSONDecoder().decode(ZonePlacement.self, from: try JSONEncoder().encode(placement))
        try expect(decoded.name == "Work", "renamed name must survive Codable round-trip; got '\(decoded.name)'")

        let fm = FileManager.default
        let dir = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent("zone-rename-inline-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let artifact = dir.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: ["check": "zone-rename-inline", "finalName": "Work"], options: [.sortedKeys]).write(to: artifact, options: .atomic)
        return artifact
    }

    static func runZoneCreateGestureSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String { switch self { case let .failed(m): return m } }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }
        func mouse(_ type: NSEvent.EventType, at p: NSPoint, window: NSWindow) throws -> NSEvent {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1,
                                             pressure: type == .leftMouseUp ? 0 : 1)
            else { throw CheckError.failed("could not synthesize \(type) at \(p)") }
            return e
        }
        // Convert canvas-local (y-down, 0 at top) → window (y-up, 0 at bottom).
        // The canvas is the contentView at origin (0,0), height = canvasH.
        func win(_ cx: CGFloat, _ cy: CGFloat, canvasH: CGFloat) -> NSPoint {
            NSPoint(x: cx, y: canvasH - cy)
        }

        // ── Setup A: empty canvas, zoom 1, window 1000×700 ────────────────────────

        let vp1 = CanvasViewport(x: 0, y: 0, zoom: 1)
        let canvasA = CanvasNSView(
            canvasState: CanvasState(viewport: vp1, tiles: [], groups: [], lastActiveTileId: nil),
            showsZoneChrome: true
        )
        canvasA.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let windowA = NSWindow(contentRect: canvasA.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        windowA.contentView = canvasA
        windowA.orderFrontRegardless()
        canvasA.layoutSubtreeIfNeeded()

        // Isolated defaults so ZoneGestureConfig doesn't read real user defaults.
        let suiteNameA = "T19-check-A-\(UUID().uuidString)"
        let gestureDefaultsA = UserDefaults(suiteName: suiteNameA)!
        gestureDefaultsA.removePersistentDomain(forName: suiteNameA)
        canvasA.zoneGestureDefaults = gestureDefaultsA
        // Same isolated suite for the auto-name base (no override → base "Zone").
        canvasA.zoneNameDefaults = gestureDefaultsA
        defer { gestureDefaultsA.removePersistentDomain(forName: suiteNameA) }

        var createdPlacements: [ZonePlacement] = []
        canvasA.onZoneCreated = { createdPlacements.append($0) }

        let cH: CGFloat = 700  // canvas height for win() conversion

        // ── Assertion 1: below-threshold drag is NOT a create ─────────────────────
        // Canvas-local: start (200,200), drag +10px to (210,200). Dist < 24 threshold.
        let threshold = ZoneGestureConfig.defaultMinCreateDragScreenPoints  // 24

        canvasA.mouseDown(with: try mouse(.leftMouseDown, at: win(200, 200, canvasH: cH), window: windowA))
        canvasA.mouseDragged(with: try mouse(.leftMouseDragged, at: win(210, 200, canvasH: cH), window: windowA))
        canvasA.mouseUp(with: try mouse(.leftMouseUp, at: win(210, 200, canvasH: cH), window: windowA))

        try expect(createdPlacements.isEmpty, "assertion 1: below-threshold drag (10 px < \(threshold) threshold) must NOT create a zone")
        try expect(canvasA.canvasState.lastActiveTileId == nil, "assertion 1: lastActiveTileId must remain nil after below-threshold drag")
        try expect(canvasA.installedZoneLayerIds.isEmpty, "assertion 1: canvas zone set must be empty after below-threshold drag")

        // ── Assertion 2: above-threshold drag creates exactly one group zone ───────
        // Canvas-local: (120,150)→(520,470). Window: (120, 700-150)=(120,550) → (520, 700-470)=(520,230).
        let downWin2 = win(120, 150, canvasH: cH)   // window (120, 550)
        let dragWin2 = win(520, 470, canvasH: cH)   // window (520, 230)

        canvasA.mouseDown(with: try mouse(.leftMouseDown, at: downWin2, window: windowA))
        canvasA.mouseDragged(with: try mouse(.leftMouseDragged, at: dragWin2, window: windowA))
        canvasA.mouseUp(with: try mouse(.leftMouseUp, at: dragWin2, window: windowA))

        try expect(createdPlacements.count == 1, "assertion 2: exactly one zone created; got \(createdPlacements.count)")
        let created = createdPlacements[0]
        try expect(created.projectId == nil, "assertion 2: created zone must have projectId == nil (group zone)")
        try expect(created.collapsed == false, "assertion 2: created zone collapsed == false")
        try expect(created.hydrationPolicy == .automatic, "assertion 2: created zone hydrationPolicy == .automatic")
        try expect(created.name == "Zone 1", "assertion 2: created zone auto-named \"Zone 1\"; got \"\(created.name)\"")
        try expect(created.navKey == nil, "assertion 2: created zone navKey == nil")
        try expect(created.color == "teal", "assertion 2: created zone color == \"teal\"")
        try expect(canvasA.qaLiveZoneIds == [created.zoneId], "assertion 2: created zone registered in the live zone set (not a ZoneLayer)")
        try expect(canvasA.installedZoneLayerIds.isEmpty, "assertion 2: live create must NOT install a ZoneLayer (keystone path stays dormant)")

        // ── Assertion 3: created zone bounds == drag rect (world) ─────────────────
        // At zoom 1, viewport (0,0): screen == world. origin=(120,150), size=(400,320).
        try expect(abs(created.origin.x - 120) < 0.5 && abs(created.origin.y - 150) < 0.5,
                   "assertion 3: created zone origin == (120, 150), got (\(created.origin.x), \(created.origin.y))")
        try expect(abs(created.size.width - 400) < 0.5 && abs(created.size.height - 320) < 0.5,
                   "assertion 3: created zone size == (400, 320), got (\(created.size.width), \(created.size.height))")

        // ── Assertion 4: in-flight marquee ghost ──────────────────────────────────
        // Fresh canvas for isolation.
        createdPlacements.removeAll()
        let canvasA4 = CanvasNSView(
            canvasState: CanvasState(viewport: vp1, tiles: [], groups: [], lastActiveTileId: nil),
            showsZoneChrome: true
        )
        canvasA4.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let windowA4 = NSWindow(contentRect: canvasA4.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        windowA4.contentView = canvasA4
        windowA4.orderFrontRegardless()
        canvasA4.layoutSubtreeIfNeeded()
        let suiteNameA4 = "T19-check-A4-\(UUID().uuidString)"
        let gestureDefaultsA4 = UserDefaults(suiteName: suiteNameA4)!
        gestureDefaultsA4.removePersistentDomain(forName: suiteNameA4)
        canvasA4.zoneGestureDefaults = gestureDefaultsA4
        defer { gestureDefaultsA4.removePersistentDomain(forName: suiteNameA4) }
        var createdA4: [ZonePlacement] = []
        canvasA4.onZoneCreated = { createdA4.append($0) }

        canvasA4.mouseDown(with: try mouse(.leftMouseDown, at: downWin2, window: windowA4))
        // Ghost should appear on first above-threshold drag event.
        canvasA4.mouseDragged(with: try mouse(.leftMouseDragged, at: dragWin2, window: windowA4))
        try expect(canvasA4.qaDragGhostFrame != nil, "assertion 4: ghost must be visible during above-threshold drag")
        // Ghost frame should equal tileScreenFrame of the current marquee world rect.
        // At zoom 1, viewport (0,0): world == canvas-local. Origin=(120,150), size=(400,320).
        let marqueeWorld4 = TileFrame(x: 120, y: 150, width: 400, height: 320)
        let expectedGhostFrame4 = CanvasEngine.tileScreenFrame(marqueeWorld4, viewport: vp1)
        try expect(canvasA4.qaDragGhostFrame == expectedGhostFrame4,
                   "assertion 4: ghost frame == tileScreenFrame(marqueeWorldRect); expected \(expectedGhostFrame4), got \(String(describing: canvasA4.qaDragGhostFrame))")
        canvasA4.mouseUp(with: try mouse(.leftMouseUp, at: dragWin2, window: windowA4))
        try expect(canvasA4.qaDragGhostFrame == nil, "assertion 4: ghost must be hidden after mouseUp")

        // ── Assertion 5: reversed drag normalizes ─────────────────────────────────
        createdPlacements.removeAll()
        let canvasA5 = CanvasNSView(
            canvasState: CanvasState(viewport: vp1, tiles: [], groups: [], lastActiveTileId: nil),
            showsZoneChrome: true
        )
        canvasA5.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let windowA5 = NSWindow(contentRect: canvasA5.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        windowA5.contentView = canvasA5
        windowA5.orderFrontRegardless()
        canvasA5.layoutSubtreeIfNeeded()
        let suiteNameA5 = "T19-check-A5-\(UUID().uuidString)"
        let gestureDefaultsA5 = UserDefaults(suiteName: suiteNameA5)!
        gestureDefaultsA5.removePersistentDomain(forName: suiteNameA5)
        canvasA5.zoneGestureDefaults = gestureDefaultsA5
        defer { gestureDefaultsA5.removePersistentDomain(forName: suiteNameA5) }
        var createdA5: [ZonePlacement] = []
        canvasA5.onZoneCreated = { createdA5.append($0) }

        // Drag up-left: canvas-local (520,470)→(120,150). Window: (520,230)→(120,550).
        canvasA5.mouseDown(with: try mouse(.leftMouseDown, at: win(520, 470, canvasH: cH), window: windowA5))
        canvasA5.mouseDragged(with: try mouse(.leftMouseDragged, at: win(120, 150, canvasH: cH), window: windowA5))
        canvasA5.mouseUp(with: try mouse(.leftMouseUp, at: win(120, 150, canvasH: cH), window: windowA5))

        try expect(createdA5.count == 1, "assertion 5: reversed drag creates exactly one zone")
        let rev = createdA5[0]
        try expect(abs(rev.origin.x - 120) < 0.5 && abs(rev.origin.y - 150) < 0.5,
                   "assertion 5: reversed drag origin == (120, 150), got (\(rev.origin.x), \(rev.origin.y))")
        try expect(abs(rev.size.width - 400) < 0.5 && abs(rev.size.height - 320) < 0.5,
                   "assertion 5: reversed drag size == (400, 320), got (\(rev.size.width), \(rev.size.height))")

        // ── Assertion 6: zoom + non-origin viewport ───────────────────────────────
        // Viewport (x:200, y:100, zoom:0.5). Drag screen (100,100)→(300,300).
        // worldX = vp.x + screenX/zoom = 200 + 100/0.5 = 400; worldY = 100 + 100/0.5 = 300.
        // size: |300-100|/0.5 = 400, |300-100|/0.5 = 400. → origin (400,300), size (400,400).
        let vp05 = CanvasViewport(x: 200, y: 100, zoom: 0.5)
        let canvasA6 = CanvasNSView(
            canvasState: CanvasState(viewport: vp05, tiles: [], groups: [], lastActiveTileId: nil),
            showsZoneChrome: true
        )
        canvasA6.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let windowA6 = NSWindow(contentRect: canvasA6.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        windowA6.contentView = canvasA6
        windowA6.orderFrontRegardless()
        canvasA6.layoutSubtreeIfNeeded()
        let suiteNameA6 = "T19-check-A6-\(UUID().uuidString)"
        let gestureDefaultsA6 = UserDefaults(suiteName: suiteNameA6)!
        gestureDefaultsA6.removePersistentDomain(forName: suiteNameA6)
        canvasA6.zoneGestureDefaults = gestureDefaultsA6
        defer { gestureDefaultsA6.removePersistentDomain(forName: suiteNameA6) }
        var createdA6: [ZonePlacement] = []
        canvasA6.onZoneCreated = { createdA6.append($0) }

        // Canvas-local (100,100)→(300,300). Window: (100,600)→(300,400).
        canvasA6.mouseDown(with: try mouse(.leftMouseDown, at: win(100, 100, canvasH: cH), window: windowA6))
        canvasA6.mouseDragged(with: try mouse(.leftMouseDragged, at: win(300, 300, canvasH: cH), window: windowA6))
        canvasA6.mouseUp(with: try mouse(.leftMouseUp, at: win(300, 300, canvasH: cH), window: windowA6))

        try expect(createdA6.count == 1, "assertion 6: zoom+non-origin viewport creates one zone")
        let z6 = createdA6[0]
        try expect(abs(z6.origin.x - 400) < 0.5 && abs(z6.origin.y - 300) < 0.5,
                   "assertion 6: origin must be screenToWorld((100,100)) = (400,300), got (\(z6.origin.x), \(z6.origin.y))")
        try expect(abs(z6.size.width - 400) < 0.5 && abs(z6.size.height - 400) < 0.5,
                   "assertion 6: size must be (200/0.5, 200/0.5) = (400,400), got (\(z6.size.width), \(z6.size.height))")

        // ── Assertion 7: persistence — real WorkspaceDocument disk round-trip ────
        // Wire onZoneCreated to inline persistence logic (same as persistCreatedGroupZone
        // in AppDelegate) so this checks the full seam: gesture → callback → WorkspaceStore
        // → disk → reload. A stubbed callback would leave the store empty → RED.
        let fm7 = FileManager.default
        let tempRoot7 = fm7.temporaryDirectory
            .appendingPathComponent("T19-check-A7-\(UUID().uuidString)", isDirectory: true)
        let appSupport7 = tempRoot7.appendingPathComponent("AppSupport", isDirectory: true)
        try fm7.createDirectory(at: appSupport7, withIntermediateDirectories: true)
        defer { try? fm7.removeItem(at: tempRoot7) }
        let workspaceId7 = UUID(uuidString: "00000000-0000-0000-0000-000000001970")!
        let store7 = WorkspaceStore(workspaceId: workspaceId7, applicationSupportDirectory: appSupport7)
        let emptyDoc7 = WorkspaceDocument(viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                                          zones: [], zoneZOrder: [], lastActiveZoneId: nil)
        try store7.save(emptyDoc7)

        let canvasA7 = CanvasNSView(
            canvasState: CanvasState(viewport: vp1, tiles: [], groups: [], lastActiveTileId: nil),
            showsZoneChrome: true
        )
        canvasA7.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let windowA7 = NSWindow(contentRect: canvasA7.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        windowA7.contentView = canvasA7
        windowA7.orderFrontRegardless()
        canvasA7.layoutSubtreeIfNeeded()
        let suiteNameA7 = "T19-check-A7-\(UUID().uuidString)"
        let gestureDefaultsA7 = UserDefaults(suiteName: suiteNameA7)!
        gestureDefaultsA7.removePersistentDomain(forName: suiteNameA7)
        canvasA7.zoneGestureDefaults = gestureDefaultsA7
        defer { gestureDefaultsA7.removePersistentDomain(forName: suiteNameA7) }
        // Wire onZoneCreated to real persistence (same logic as AppDelegate.persistCreatedGroupZone).
        canvasA7.onZoneCreated = { placement in
            do {
                var doc = try store7.load()
                guard !doc.zones.contains(where: { $0.zoneId == placement.zoneId }) else { return }
                doc.zones.append(placement)
                doc.bringZoneToFront(placement.zoneId)
                try store7.save(doc)
            } catch {
                // will be detected by the assertions below
            }
        }
        // Same above-threshold drag as assertion 2: canvas-local (120,150)→(520,470).
        canvasA7.mouseDown(with: try mouse(.leftMouseDown, at: win(120, 150, canvasH: cH), window: windowA7))
        canvasA7.mouseDragged(with: try mouse(.leftMouseDragged, at: win(520, 470, canvasH: cH), window: windowA7))
        canvasA7.mouseUp(with: try mouse(.leftMouseUp, at: win(520, 470, canvasH: cH), window: windowA7))
        // Reload from disk and assert the zone is present with correct geometry.
        let reloaded7 = try store7.load()
        try expect(reloaded7.zones.count == 1,
                   "assertion 7: reloaded WorkspaceDocument must contain exactly 1 zone; got \(reloaded7.zones.count)")
        let persisted7 = reloaded7.zones[0]
        try expect(persisted7.projectId == nil, "assertion 7: reloaded zone must have projectId == nil (group zone)")
        try expect(abs(persisted7.origin.x - 120) < 0.5 && abs(persisted7.origin.y - 150) < 0.5,
                   "assertion 7: reloaded zone origin == (120,150), got (\(persisted7.origin.x),\(persisted7.origin.y))")
        try expect(abs(persisted7.size.width - 400) < 0.5 && abs(persisted7.size.height - 320) < 0.5,
                   "assertion 7: reloaded zone size == (400,320), got (\(persisted7.size.width),\(persisted7.size.height))")
        try expect(reloaded7.zonesInZOrder.last?.zoneId == persisted7.zoneId,
                   "assertion 7: reloaded zone order must end with the created zone (frontmost)")

        // ── Assertion 7b: create-guard asymmetry — ZoneLayer-only canvas body press ─
        // A canvas with a zone installed ONLY as a ZoneLayer (zoneRenderModels is empty)
        // must NOT classify a press in the zone body as .creating (Defect A guard).
        // Without _zoneId(at:) checking zoneLayers, this press would produce a spurious zone.
        let gzBodyId = UUID(uuidString: "00000000-0000-0000-0000-000000001972")!
        let gzBodyPlacement = ZonePlacement(
            zoneId: gzBodyId, projectId: nil,
            origin: ZonePoint(x: 50, y: 50), size: ZoneSize(width: 200, height: 150),
            color: "teal", collapsed: false, hydrationPolicy: .automatic
        )
        // Build a canvas with NO zoneRenderModels but with a ZoneLayer for gzBodyPlacement.
        let canvasA7b = CanvasNSView(
            canvasState: CanvasState(viewport: vp1, tiles: [], groups: [], lastActiveTileId: nil),
            showsZoneChrome: true
        )
        canvasA7b.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let windowA7b = NSWindow(contentRect: canvasA7b.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        windowA7b.contentView = canvasA7b
        windowA7b.orderFrontRegardless()
        canvasA7b.layoutSubtreeIfNeeded()
        let suiteNameA7b = "T19-check-A7b-\(UUID().uuidString)"
        let gestureDefaultsA7b = UserDefaults(suiteName: suiteNameA7b)!
        gestureDefaultsA7b.removePersistentDomain(forName: suiteNameA7b)
        canvasA7b.zoneGestureDefaults = gestureDefaultsA7b
        defer { gestureDefaultsA7b.removePersistentDomain(forName: suiteNameA7b) }
        // Install the zone as a ZoneLayer (NOT in zoneRenderModels).
        let layerBody = ZoneLayer(placement: gzBodyPlacement,
                                  renderModel: ZoneRenderModel(placement: gzBodyPlacement, displayName: "Body"),
                                  tiles: [])
        canvasA7b.upsertZoneLayer(layerBody)
        canvasA7b.layoutSubtreeIfNeeded()
        var createdA7b: [ZonePlacement] = []
        canvasA7b.onZoneCreated = { createdA7b.append($0) }
        // Press at zone body center (100,120) — inside zone bounds [50..250, 50..200], below header band.
        // At zoom 1, canvas-local == world. gzBodyPlacement header band = y ∈ [50, 82].
        // Body point (100, 120) is inside the zone (x∈[50,250], y∈[50,200]) but below the header.
        // zoneId(at:) would return nil (zoneRenderModels is empty); _zoneId(at:) returns gzBodyId.
        // Then classify: drag (100,120)→(350,420), dist ≈ 354 > threshold → would create if not guarded.
        canvasA7b.mouseDown(with: try mouse(.leftMouseDown, at: win(100, 120, canvasH: cH), window: windowA7b))
        canvasA7b.mouseDragged(with: try mouse(.leftMouseDragged, at: win(350, 420, canvasH: cH), window: windowA7b))
        canvasA7b.mouseUp(with: try mouse(.leftMouseUp, at: win(350, 420, canvasH: cH), window: windowA7b))
        try expect(createdA7b.isEmpty,
                   "assertion 7b: press in ZoneLayer-only zone body must NOT create a new zone; got \(createdA7b.count)")

        // ── Setup B: MOVE — one group zone with two member tiles ──────────────────
        let gzId   = UUID(uuidString: "00000000-0000-0000-0000-000000001981")!
        let t1Id   = UUID(uuidString: "00000000-0000-0000-0000-000000001982")!
        let t2Id   = UUID(uuidString: "00000000-0000-0000-0000-000000001983")!

        // Zone-local tile frames.
        let t1ZoneLocal = TileFrame(x: 20, y: 40, width: 160, height: 120)
        let t2ZoneLocal = TileFrame(x: 200, y: 40, width: 160, height: 120)
        let t1 = Tile(id: t1Id, kind: .note, title: "MV_T1", frame: t1ZoneLocal, zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        let t2 = Tile(id: t2Id, kind: .note, title: "MV_T2", frame: t2ZoneLocal, zPosition: .fromLegacyRank(2), runtimeRef: nil, metadata: TileMetadata())

        let gz = ZonePlacement(
            zoneId: gzId, projectId: nil,
            origin: ZonePoint(x: 300, y: 200), size: ZoneSize(width: 400, height: 300),
            color: "teal", collapsed: false, hydrationPolicy: .automatic
        )

        let vpB = CanvasViewport(x: 0, y: 0, zoom: 1)
        // Pass gz in zoneRenderModels so zoneHeaderZoneId recognizes the header.
        let canvasB = CanvasNSView(
            canvasState: CanvasState(viewport: vpB, tiles: [], groups: [], lastActiveTileId: nil),
            zoneRenderModels: [ZoneRenderModel(placement: gz, displayName: "GZ")],
            showsZoneChrome: true
        )
        canvasB.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let windowB = NSWindow(contentRect: canvasB.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        windowB.contentView = canvasB
        windowB.orderFrontRegardless()

        // Install tile views in the ZoneLayer.
        let view1 = DescriptorTileNSView(tile: t1)
        let view2 = DescriptorTileNSView(tile: t2)
        let layer = ZoneLayer(placement: gz, renderModel: ZoneRenderModel(placement: gz, displayName: "GZ"), tiles: [t1, t2])
        layer.tileViews[t1Id] = view1
        layer.tileViews[t2Id] = view2
        canvasB.upsertZoneLayer(layer)
        canvasB.layoutSubtreeIfNeeded()

        let suiteNameB = "T19-check-B-\(UUID().uuidString)"
        let gestureDefaultsB = UserDefaults(suiteName: suiteNameB)!
        gestureDefaultsB.removePersistentDomain(forName: suiteNameB)
        canvasB.zoneGestureDefaults = gestureDefaultsB
        defer { gestureDefaultsB.removePersistentDomain(forName: suiteNameB) }

        var movedPlacements: [ZonePlacement] = []
        canvasB.onZoneMoved = { movedPlacements.append($0) }

        // ── Assertion 8: press on chrome classifies as move, not create, not tile ──
        // At zoom 1, viewport (0,0): world == canvas-local.
        // Zone chrome header: zone origin (300,200), size (400,300). Header band = y ∈ [200,232].
        // Canvas-local press point (310, 210) is inside the header band.
        // zoneHeaderZoneId(at:) takes canvas-local coords (it uses zoneHeaderScreenRect which
        // produces canvas-local rects at zoom 1). tileId(at:) also takes canvas-local coords.
        let pressBLocal = CGPoint(x: 310, y: 210)  // canvas-local
        try expect(canvasB.zoneHeaderZoneId(at: pressBLocal) == gzId,
                   "assertion 8 precondition: zoneHeaderZoneId at (\(pressBLocal.x),\(pressBLocal.y)) must == gzId")
        try expect(canvasB.tileId(at: pressBLocal) == nil,
                   "assertion 8 precondition: no tile at press point (header sits above tiles; tiles start at world-y=240)")

        // Gesture: canvas-local (310,210)→(390,260). Window: (310,490)→(390,440).
        // dy_window = 440-490 = -50 (window-y decreasing = downward drag = increasing canvas-y = +world-y).
        // In mouseDragged: dy = -(locationInWindow.y - lastWindowPoint.y) = -(-50) = +50.
        // worldDy = 50/1 = 50. New origin = (300+80, 200+50) = (380, 250). ✓
        canvasB.mouseDown(with: try mouse(.leftMouseDown, at: win(310, 210, canvasH: cH), window: windowB))
        canvasB.mouseDragged(with: try mouse(.leftMouseDragged, at: win(390, 260, canvasH: cH), window: windowB))
        canvasB.mouseUp(with: try mouse(.leftMouseUp, at: win(390, 260, canvasH: cH), window: windowB))

        try expect(movedPlacements.count == 1, "assertion 8: move gesture fires onZoneMoved exactly once; got \(movedPlacements.count)")

        // ── Assertion 9: whole zone translates by the world delta ─────────────────
        // Window delta dx = 390-310 = +80. Window dy = 440-490 = -50.
        // In mouseDragged: worldDx = 80/1 = 80; dy = -(-50) = +50, worldDy = 50/1 = 50.
        // New origin = (300+80, 200+50) = (380, 250). Size unchanged.
        let moved = movedPlacements[0]
        try expect(abs(moved.origin.x - 380) < 0.5, "assertion 9: moved origin.x == 300+80=380, got \(moved.origin.x)")
        try expect(abs(moved.origin.y - 250) < 0.5, "assertion 9: moved origin.y == 200+50=250, got \(moved.origin.y)")
        try expect(abs(moved.size.width - gz.size.width) < 0.5, "assertion 9: moved size unchanged (width)")
        try expect(abs(moved.size.height - gz.size.height) < 0.5, "assertion 9: moved size unchanged (height)")

        // ── Assertion 10: tiles ride along (stored zone-local frames unchanged) ────
        // Stored zone-local frames must be UNCHANGED.
        let layerAfter = canvasB.installedZoneLayerIds.first(where: { $0 == gzId })
        try expect(layerAfter != nil, "assertion 10 precondition: gz still installed after move")
        let layerB2 = canvasB.zoneLayers.first(where: { $0.placement.zoneId == gzId })!
        let t1Stored = layerB2.tiles.first(where: { $0.id == t1Id })!.frame
        let t2Stored = layerB2.tiles.first(where: { $0.id == t2Id })!.frame
        try expect(abs(t1Stored.x - t1ZoneLocal.x) < 0.5 && abs(t1Stored.y - t1ZoneLocal.y) < 0.5,
                   "assertion 10: t1 stored zone-local frame unchanged: expected (\(t1ZoneLocal.x),\(t1ZoneLocal.y)), got (\(t1Stored.x),\(t1Stored.y))")
        try expect(abs(t2Stored.x - t2ZoneLocal.x) < 0.5 && abs(t2Stored.y - t2ZoneLocal.y) < 0.5,
                   "assertion 10: t2 stored zone-local frame unchanged: expected (\(t2ZoneLocal.x),\(t2ZoneLocal.y)), got (\(t2Stored.x),\(t2Stored.y))")
        // On-screen frames must have shifted by world delta (+80, +50).
        // New zone origin (380,250). t1 world = (380+20, 250+40) = (400,290). Screen = same at zoom 1.
        let movedPlacement = layerB2.placement
        let t1ExpectedWorldFrame = TileFrame(
            x: movedPlacement.origin.x + t1ZoneLocal.x, y: movedPlacement.origin.y + t1ZoneLocal.y,
            width: t1ZoneLocal.width, height: t1ZoneLocal.height
        )
        let t1ExpectedScreenFrame = CanvasEngine.tileScreenFrame(t1ExpectedWorldFrame, viewport: vpB)
        try expect(canvasB.tileView(for: t1Id)?.frame == t1ExpectedScreenFrame,
                   "assertion 10: t1 screen frame must match world frame via new origin; expected \(t1ExpectedScreenFrame), got \(String(describing: canvasB.tileView(for: t1Id)?.frame))")

        // ── Assertion 11: adaptive bounds (T11) after the move ───────────────────
        // After move, zone origin is (380,250). Member tile world frames:
        // t1=(380+20, 250+40, 160, 120)=(400,290,160,120), t2=(380+200, 250+40,160,120)=(580,290,160,120).
        // Union: (400,290,340,120). With P=ZoneBoundsConfig.defaultPadding (24), H=ZoneChromeNSView.headerHeight (34):
        // adaptive: x=400-24=376, y=290-24-34=232, w=340+48=388, h=120+48+34=202.
        let P = ZoneBoundsConfig.defaultPadding      // 24
        let H = ZoneChromeNSView.headerHeight        // 34
        let expectedAdaptiveFrame = TileFrame(
            x: 400 - P, y: 290 - P - H,
            width: 340 + 2 * P, height: 120 + 2 * P + H
        )  // = (376, 232, 388, 202)
        let expectedChromeScreenFrame = CanvasEngine.tileScreenFrame(expectedAdaptiveFrame, viewport: vpB)
        let actualChromeFrame = canvasB.zoneLayerChromeFrame(for: gzId)
        try expect(actualChromeFrame == expectedChromeScreenFrame,
                   "assertion 11: chrome screen frame after move must equal adaptive bounds screen frame; expected \(expectedChromeScreenFrame), got \(String(describing: actualChromeFrame))")

        // ── Assertion 12: no drag-snap side effects ───────────────────────────────
        try expect(canvasB.qaDragGhostFrame == nil, "assertion 12: qaDragGhostFrame must be nil after move (no tile snap ghost)")
        try expect(canvasB.canvasState.lastActiveTileId == nil, "assertion 12: lastActiveTileId unchanged by chrome drag")

        // ── Setup C: MOVE via render-model-only path (production boot path) ────────
        // Production at boot has zones only in zoneRenderModels (immutable), NOT as
        // ZoneLayers — WorkspaceRuntime.install skips projectId==nil group zones so they
        // never get upsertZoneLayer. This exercises the pendingMovedPlacement branch
        // (mouseDragged :1026-1052) which the ZoneLayer Setup B does NOT cover.
        // If this branch is stubbed, assertion C1 fires RED.
        let gzCId = UUID(uuidString: "00000000-0000-0000-0000-000000001984")!
        let gzC = ZonePlacement(
            zoneId: gzCId, projectId: nil,
            origin: ZonePoint(x: 300, y: 200), size: ZoneSize(width: 400, height: 300),
            color: "teal", collapsed: false, hydrationPolicy: .automatic
        )
        let vpC = CanvasViewport(x: 0, y: 0, zoom: 1)
        // Build canvas with ONLY zoneRenderModels, NO upsertZoneLayer call.
        let canvasC = CanvasNSView(
            canvasState: CanvasState(viewport: vpC, tiles: [], groups: [], lastActiveTileId: nil),
            zoneRenderModels: [ZoneRenderModel(placement: gzC, displayName: "GZ-C")],
            showsZoneChrome: true
        )
        canvasC.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let windowC = NSWindow(contentRect: canvasC.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        windowC.contentView = canvasC
        windowC.orderFrontRegardless()
        canvasC.layoutSubtreeIfNeeded()
        let suiteNameC = "T19-check-C-\(UUID().uuidString)"
        let gestureDefaultsC = UserDefaults(suiteName: suiteNameC)!
        gestureDefaultsC.removePersistentDomain(forName: suiteNameC)
        canvasC.zoneGestureDefaults = gestureDefaultsC
        defer { gestureDefaultsC.removePersistentDomain(forName: suiteNameC) }

        var movedC: [ZonePlacement] = []
        canvasC.onZoneMoved = { movedC.append($0) }

        // Verify precondition: no ZoneLayers installed (render-model-only).
        try expect(canvasC.zoneLayers.isEmpty,
                   "Setup C precondition: canvas must have no ZoneLayers (render-model-only path)")
        try expect(canvasC.zoneHeaderZoneId(at: CGPoint(x: 310, y: 210)) == gzCId,
                   "Setup C precondition: zone header must be recognized via zoneRenderModels")

        // Same drag as Setup B: press header at (310,210), drag to (390,260).
        // Expected: onZoneMoved fires once via pendingMovedPlacement path.
        // delta dx=+80, dy=+50 → new origin (380,250). Size unchanged.
        canvasC.mouseDown(with: try mouse(.leftMouseDown, at: win(310, 210, canvasH: cH), window: windowC))
        canvasC.mouseDragged(with: try mouse(.leftMouseDragged, at: win(390, 260, canvasH: cH), window: windowC))
        canvasC.mouseUp(with: try mouse(.leftMouseUp, at: win(390, 260, canvasH: cH), window: windowC))

        // C1: render-model move fires onZoneMoved via pendingMovedPlacement.
        try expect(movedC.count == 1,
                   "assertion C1: render-model-only move must fire onZoneMoved exactly once; got \(movedC.count)")
        // C2: origin shifted correctly by the world delta.
        let movedCPlacement = movedC[0]
        try expect(abs(movedCPlacement.origin.x - 380) < 0.5,
                   "assertion C2: render-model move origin.x == 300+80=380, got \(movedCPlacement.origin.x)")
        try expect(abs(movedCPlacement.origin.y - 250) < 0.5,
                   "assertion C2: render-model move origin.y == 200+50=250, got \(movedCPlacement.origin.y)")
        try expect(abs(movedCPlacement.size.width - gzC.size.width) < 0.5,
                   "assertion C2: render-model move size.width unchanged")
        try expect(abs(movedCPlacement.size.height - gzC.size.height) < 0.5,
                   "assertion C2: render-model move size.height unchanged")
        // C3: no spurious create zone (body press on a render-model zone must not create).
        // (The _zoneId fix means the header press is already classified as movingZone, so no
        // create can happen here — this is a consistency proof for the render-model path.)
        try expect(canvasC.installedZoneLayerIds.isEmpty || canvasC.installedZoneLayerIds == [gzCId],
                   "assertion C3: render-model move must not spuriously install extra zone layers")

        // ── Write artifact ────────────────────────────────────────────────────────
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath)
        let directory = root.appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent("zone-create-gesture-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        let manifest: [String: Any] = [
            "check": "zone-create-gesture",
            "createZoneId": created.zoneId.uuidString,
            "createOrigin": ["x": created.origin.x, "y": created.origin.y],
            "createSize": ["w": created.size.width, "h": created.size.height],
            "moveZoneId": gzId.uuidString,
            "movedOrigin": ["x": moved.origin.x, "y": moved.origin.y],
            "threshold": threshold,
            "assertions": "1-12 + 7b + C1-C3 passed"
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
    func canvasSidebarModelDidChange(_ canvas: CanvasNSView)
}

extension CanvasNSViewDelegate {
    func canvasSidebarModelDidChange(_ canvas: CanvasNSView) {}
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
private final class WorkspaceTransitionLabelView: NSView {
    let text: String

    override var isFlipped: Bool { true }

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func preferredSize(maxWidth: CGFloat) -> CGSize {
        let textSize = (text as NSString).size(withAttributes: Self.textAttributes)
        return CGSize(width: min(maxWidth, max(160, textSize.width + 36)), height: 32)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14)
        NSColor.black.withAlphaComponent(0.72).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        path.lineWidth = 1
        path.stroke()
        let size = (text as NSString).size(withAttributes: Self.textAttributes)
        let rect = CGRect(
            x: max(12, (bounds.width - size.width) / 2),
            y: max(0, (bounds.height - size.height) / 2),
            width: min(size.width, max(0, bounds.width - 24)),
            height: size.height
        )
        (text as NSString).draw(in: rect, withAttributes: Self.textAttributes)
    }

    private static let textAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.92)
    ]
}

@MainActor
/// A phantom OUTLINE previewing where a dragged tile will snap — an accent border
/// with a barely-there tint, so the moving tile never reads as "turned blue". It
/// materializes with a small fade + scale pop. Click-transparent. Lifecycle
/// mirrors `FocusBorderOverlayView`.
final class DragGhostOverlayView: NSView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.06).cgColor
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = 6
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Draw only — never consume mouse events.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Show/move the phantom. `frame` is set to the destination synchronously (so
    /// it stays correct + deterministic for checks); the smoothing is purely
    /// presentational — a fade + scale pop on first appear, and a short eased
    /// TRAIL on moves so the phantom lags slightly behind the tile as you ride a
    /// neighbor's edge instead of rigidly mirroring it.
    func show(at screenFrame: CGRect) {
        let appearing = isHidden
        let previousCenter = layer?.presentation()?.position
            ?? CGPoint(x: frame.midX, y: frame.midY)
        isHidden = false
        let moved = frame != screenFrame
        frame = screenFrame
        guard let layer else { return }
        if appearing {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.96
            scale.toValue = 1
            let group = CAAnimationGroup()
            group.animations = [fade, scale]
            group.duration = 0.14
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(group, forKey: "ghostAppear")
        } else if moved {
            // Animate position FROM where the phantom currently appears TO the new
            // destination; each move interrupts the last, producing a continuous
            // trailing lag as the tile rides along.
            let trail = CABasicAnimation(keyPath: "position")
            trail.fromValue = NSValue(point: previousCenter)
            trail.duration = 0.16
            trail.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(trail, forKey: "ghostTrail")
        }
    }

    func hide() { isHidden = true }
}

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
extension CanvasNSView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === zoneRenameField else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitZoneRename()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelZoneRename()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Ignore the transient end-editing that `selectText(_:)` posts while
        // `beginZoneRename` is still installing the field (see `isOpeningZoneRename`).
        guard !isOpeningZoneRename else { return }
        // Focus loss (clicked elsewhere) commits. No-op if already torn down.
        guard (obj.object as? NSTextField) === zoneRenameField else { return }
        commitZoneRename()
    }
}

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

    /// Exposed for `zoneBounds` callers that need the header height without
    /// an instance; the instance `headerHeight` below drives `headerRect`.
    static let headerHeight: Double = 34

    private var model: CanvasNSView.ZoneRenderModel
    private let headerHeight: CGFloat = 34

    /// Replace the render model (e.g. after a rename) and redraw the header.
    func update(model: CanvasNSView.ZoneRenderModel) {
        self.model = model
        needsDisplay = true
    }

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

        // Close (✕) button — top-right of the header. The canvas owns the click
        // (hitTest here returns nil); this only draws the affordance.
        let closeSize: CGFloat = 24
        let closeRect = CGRect(x: headerRect.maxX - closeSize - 4, y: 4, width: closeSize, height: min(closeSize, max(0, headerRect.height - 4)))
        ("✕" as NSString).draw(in: closeRect.insetBy(dx: 6, dy: 3), withAttributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.70)
        ])

        var rightInset: CGFloat = 12 + closeSize + 6   // reserve the close-button slot
        if let qaVerdict = model.qaVerdict {
            let badgeAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: Self.qaColor(for: qaVerdict.verdict).withAlphaComponent(0.92)
            ]
            let glyph = qaVerdict.verdict.glyph
            let badgeSize = (glyph as NSString).size(withAttributes: badgeAttributes)
            let badgeRect = CGRect(x: headerRect.maxX - badgeSize.width - 12 - closeSize - 6, y: 8, width: badgeSize.width, height: 16)
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

    static func color(named name: String) -> NSColor {
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

        switch canvas.navOverlayPresentation {
        case .navMode:
            drawSelectionRing(in: canvas)
            drawZoneBadges(in: canvas)
            drawHintLine()
        case .leaderLabels:
            drawTileLabels(in: canvas)
        }
    }

    /// Hold-leader jump HUD: a label badge centered on each visible tile, sourced
    /// from the same `leaderJumpAssignments` key resolution uses so the badge a
    /// user sees is exactly the key that jumps there.
    private func drawTileLabels(in canvas: CanvasNSView) {
        for assignment in canvas.leaderJumpAssignments() {
            let badge = JumpIndicatorPlacementEngine.indicatorRect(for: assignment.placement, normalBadgeSize: badgeSize)
            let badgePath = NSBezierPath(roundedRect: badge, xRadius: min(8, badge.width / 2), yRadius: min(8, badge.height / 2))
            NSColor.controlAccentColor.withAlphaComponent(0.95).setFill()
            badgePath.fill()
            let text = assignment.label.uppercased()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let size = text.size(withAttributes: attributes)
            if badge.width >= size.width + 4, badge.height >= size.height + 2 {
                text.draw(
                    at: CGPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2),
                    withAttributes: attributes
                )
            }
        }
    }

    private func drawSelectionRing(in canvas: CanvasNSView) {
        guard
            let selectedTileId,
            let snapshot = canvas.navigationTileSnapshot(for: selectedTileId)
        else { return }

        let screenFrame = CanvasEngine.tileScreenFrame(snapshot.worldFrame, viewport: canvas.canvasState.viewport).insetBy(dx: -4, dy: -4)
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

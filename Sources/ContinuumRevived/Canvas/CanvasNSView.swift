import AppKit
import OSLog
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

private struct CanvasWorldPlaneSubviewSortKey {
    var tier: Int
    var rank: Int
    var originalIndex: Int
}

private final class CanvasWorldPlaneSubviewSortContext {
    let keys: [ObjectIdentifier: CanvasWorldPlaneSubviewSortKey]
    init(keys: [ObjectIdentifier: CanvasWorldPlaneSubviewSortKey]) { self.keys = keys }
}

/// Top-level canvas view: hosts tile subviews, owns the viewport, translates
/// world-space tile frames into AppKit subview frames, and routes pan/zoom
/// gestures to the underlying viewport. Flipped so the y-axis matches the
/// world-space convention (positive y = down).
@MainActor
final class CanvasNSView: NSView, TokenThemed {
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
        var scopeLabel: String? = nil
        var isProvisional: Bool = false
        var agentStatusRollup: AgentStatusRollup = .empty
        var qaVerdict: QARunManifestSnapshot?
    }

    struct AgentStatusRollup: Equatable {
        var working: Int = 0
        var needsAttention: Int = 0
        var done: Int = 0
        var stale: Int = 0
        var pushed: Int = 0
        var merged: Int = 0

        static let empty = AgentStatusRollup()

        var displayText: String? {
            var parts: [String] = []
            if working > 0 { parts.append("\(working) working") }
            if needsAttention > 0 { parts.append("\(needsAttention) needs you") }
            if done > 0 { parts.append("\(done) done") }
            if stale > 0 { parts.append("\(stale) stale") }
            if merged > 0 { parts.append("\(merged) merged") }
            if pushed > 0 { parts.append("\(pushed) pushed") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    private(set) var canvasState: CanvasState
    private struct PendingGeometryEdit {
        var action: CanvasGeometryAction
        var tileIds: Set<UUID>
        var zoneIds: Set<UUID>
        var before: CanvasGeometrySnapshot
    }
    private var pendingGeometryEdit: PendingGeometryEdit?
    private var canvasHistories: [UUID: CanvasHistoryController] = [:]
    private var activeUndoWorkspaceId: UUID?
    /// Active single-zone placement for stage-2 integration. Tile frames remain
    /// persisted zone-local; layout/hit-testing consume world frames through
    /// CanvasEngine. With the default origin (0,0), this is behavior-neutral.
    let activeZone: ZonePlacement?
    private(set) var zoneRenderModels: [ZoneRenderModel]
    private var tileViews: [UUID: TileNSView] = [:]
    /// The boot project initially renders through the legacy flat canvas. Once
    /// an in-process workspace switch installs ZoneLayers, that boot scene is a
    /// departed workspace and must no longer participate in rendering,
    /// navigation, hit-testing, or document identity.
    private var flatCompatibilitySceneActive = true
    /// See `withAutoLayoutSuppressed` (M1.2, `.plans/46`).
    private var _suppressesAutoLayoutForHydration = false
    private var agentLineageOverlay: AgentLineageOverlayView?
    /// C11: N edges, not one — a fan-out reveal shows the parent's whole
    /// visible fan, bounded the same way the inbox bounds visible children
    /// (`InboxSort.maxVisibleChildren`, enforced in
    /// `showContextualAgentLineage(edges:)`).
    private var contextualAgentLineage: [(parentTileID: UUID, childTileID: UUID)] = []
    private var showsZoneChrome: Bool
    private var zoneChromeViews: [UUID: ZoneChromeNSView] = [:]
    private var navModeOverlayView: NavModeOverlayNSView?
    var navModeHintLine = NavKeymap.default.hintLine
    /// The hold-leader HUD's own vocabulary. `⏎` is listed because the current
    /// tile, when fully visible, carries no jump label by design — Return is the
    /// only way to say "this one, reveal it for work".
    static let leaderHintLine = "letter jump · ⏎ reveal current tile · ←→↑↓ dock · esc cancel"
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
    /// True while this canvas owns the open-hand cursor pushed by Space. Kept
    /// separate from `spaceHeld` so releasing Space during a mouse drag can defer
    /// its pop until the closed-hand pointer-pan cursor above it is removed.
    private var spaceCursorPushed = false
    private var pointerPanActive = false
    private var pointerPanLastWindowPoint: CGPoint = .zero

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
    private var provisionalZoneIds: Set<UUID> = []
    private(set) var isZoneScopePickerActive = false
    /// tileId → zoneId. A tile absent from this map is a bare (unzoned) tile.
    /// Derived cache over the authoritative `Tile.zoneId` LWW register (ticket 03):
    /// every mutation goes through `setTileZone(_:zoneId:)`, which stamps the
    /// register in `canvasState` so membership persists with the canvas.
    private var tileZoneMembership: [UUID: UUID] = [:]
    /// Preference source is injectable for deterministic AppKit checks.
    var autoLayoutDefaults: UserDefaults = .standard
    private var lastAutoLayoutEnabled = CanvasAutoLayoutConfig.enabled()
    private var autoLayoutGestureBaseline: CanvasAutoLayoutEngine.Scene?
    private var autoLayoutSwapLatch: UUID?
    private var autoLayoutDeferredUntilEdit = false
    private let autoLayoutUndoToast = InboxUndoToast()
    private var autoLayoutUndoTimer: Timer?
    private var autoLayoutBlockedZoneIds: Set<UUID> = []
    var autoLayoutReduceMotionProvider: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var qaAutoLayoutUndoText: String { autoLayoutUndoToast.qaText }
    @discardableResult func qaClickAutoLayoutUndo() -> Bool { autoLayoutUndoToast.clickUndoForQA() }

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

    /// The zones as the canvas is ACTUALLY DRAWING them, in z-order.
    ///
    /// This is `liveZones` — Model B — and it is not always the document. A zone
    /// grown by auto-layout updates `liveZones` (and therefore the chrome the user
    /// sees) through `onZoneMoved`, and the document can lag. Anything that answers
    /// "which zone is the user looking at" must read THIS, because the user is
    /// looking at pixels. `cameraArmedZone` read the document and silently
    /// disagreed with the screen. T2 (`.plans/47`).
    var renderedZonesInZOrder: [ZonePlacement] {
        liveZones.sorted { lhs, rhs in
            if lhs.zPosition != rhs.zPosition { return lhs.zPosition < rhs.zPosition }
            return lhs.zoneId.uuidString < rhs.zoneId.uuidString
        }
    }
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
        // Paint order is the WORLD PLANE's child order — zone chrome and tiles are
        // both world content, so neither is a direct child of the canvas.
        let order = worldPlane.subviews
        guard let chrome = zoneChromeViews[zoneId], let ci = order.firstIndex(of: chrome) else { return false }
        let memberViews = canvasState.tiles
            .filter { tileZoneMembership[$0.id] == zoneId }
            .compactMap { tileViews[$0.id] }
        guard !memberViews.isEmpty else { return true }
        return memberViews.allSatisfy { tv in
            guard let ti = order.firstIndex(of: tv) else { return false }
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

    /// Filesystem scope evidence for a tile. Browser and Note never call this;
    /// Agent, Shell, File Tree, and checkout-backed File do.
    var filesystemScopeForTile: ((UUID) -> ZoneScope?)?
    var scopeLabelForZoneScope: ((ZoneScope) -> String)?

    /// Fired when a drag-to-create gesture commits a new group zone.
    /// The placement is passed; the caller persists it (e.g. via WorkspaceDocument).
    var onZoneCreated: ((ZonePlacement) -> Void)?

    /// A blank or mixed-scope marquee remains in memory only until this callback
    /// supplies a project/Home or cancels it.
    var onZoneScopeRequired: ((ZonePlacement, CGPoint) -> Void)?

    /// Existing-zone project/Home changes use the same picker, but never mutate
    /// member tile location identity.
    var onZoneScopeChangeRequested: ((ZonePlacement, CGPoint) -> Void)?

    /// Fired when a drag-on-chrome gesture commits a moved zone.
    /// The new placement (translated origin) is passed; the caller persists it.
    var onZoneMoved: ((ZonePlacement) -> Void)?

    /// Fired when the user clicks a zone's close (✕) button. The app decides
    /// keep-vs-delete (e.g. a confirm) and then calls `closeZone(zoneId:keepTiles:)`.
    var onZoneCloseRequested: ((UUID) -> Void)?

    /// Fired after a zone is closed so the caller can drop it from persistence.
    var onZoneClosed: ((UUID) -> Void)?

    /// Fired when a press lands anywhere inside a zone — chrome or interior.
    /// T2 (`.plans/47`): clicking a zone arms it as the target for new tiles. The
    /// canvas reports the hit and `WorkspaceRuntime.setActiveZone` decides whether
    /// it may arm (a group zone may not), so the arming policy stays in one place.
    var onZoneActivated: ((UUID) -> Void)?

    /// Fired after a zone is renamed (inline edit committed) so the caller can
    /// persist the new name. Carries (zoneId, newName).
    var onZoneRenamed: ((UUID, String) -> Void)?
    var onZoneColorChanged: ((UUID, String) -> Void)?

    /// Atomic geometry handoff used when one manipulation displaces multiple
    /// tiles/zones. Preview frames never reach this callback.
    /// Returns true only after every backing store durably accepted the solve.
    /// A false result restores the gesture baseline in memory.
    var onLayoutCommitted: ((CanvasLayoutTransaction) -> Bool)?

    private func autoLayoutScene() -> CanvasAutoLayoutEngine.Scene {
        var layoutTiles = canvasState.tiles.map {
            CanvasAutoLayoutEngine.LayoutTile(
                id: $0.id, frame: $0.frame, zoneId: tileZoneMembership[$0.id],
                minimumSize: TileGeometry.minimumSize(for: $0.kind))
        }
        let known = Set(layoutTiles.map(\.id))
        for layer in zoneLayers {
            for tile in layer.tiles where !known.contains(tile.id) {
                layoutTiles.append(.init(
                    id: tile.id,
                    frame: CanvasEngine.worldFrame(tile: tile, in: layer.placement),
                    zoneId: layer.placement.zoneId,
                    minimumSize: TileGeometry.minimumSize(for: tile.kind)
                ))
            }
        }
        var placements = liveZones
        let liveIds = Set(placements.map(\.zoneId))
        placements += zoneLayers.map(\.placement).filter { !liveIds.contains($0.zoneId) }
        return .init(tiles: layoutTiles, zones: placements, globalEnabled: CanvasAutoLayoutConfig.enabled(defaults: autoLayoutDefaults))
    }

    func beginAutoLayoutGesture() {
        guard CanvasAutoLayoutConfig.enabled(defaults: autoLayoutDefaults) else { return }
        if autoLayoutDeferredUntilEdit { autoLayoutDeferredUntilEdit = false }
        if autoLayoutGestureBaseline == nil {
            autoLayoutGestureBaseline = autoLayoutScene()
            autoLayoutSwapLatch = nil
        }
    }

    var isAutoLayoutEnabled: Bool { CanvasAutoLayoutConfig.enabled(defaults: autoLayoutDefaults) }

    func commitGeometryGesture() {
        _ = finishAutoLayoutGesture()
        _ = commitGeometryEdit()
    }

    private func applyAutoLayout(_ mutation: CanvasAutoLayoutEngine.Mutation, baseline: CanvasAutoLayoutEngine.Scene? = nil) {
        guard CanvasAutoLayoutConfig.enabled(defaults: autoLayoutDefaults) else { return }
        let scene = baseline ?? autoLayoutScene()
        let transaction = CanvasAutoLayoutEngine.solve(
            scene: scene,
            mutation: mutation,
            gap: TileGapResolver.resolvedGap(defaults: autoLayoutDefaults),
            zonePadding: ZoneBoundsConfig.padding(defaults: autoLayoutDefaults),
            headerHeight: Double(ZoneChromeNSView.headerHeight),
            latchedSwapTarget: autoLayoutSwapLatch
        )
        autoLayoutBlockedZoneIds = transaction.blockedZoneIds
        if case .tile = mutation { autoLayoutSwapLatch = transaction.swapTargetTileId }
        let activeTileId: UUID?
        let activeZoneId: UUID?
        switch mutation {
        case let .tile(id, _): activeTileId = id; activeZoneId = nil
        case let .zone(id, _): activeTileId = nil; activeZoneId = id
        case .tidy, .settle: activeTileId = nil; activeZoneId = nil
        }
        // The solver reports frames that differ from the SCENE it was given.
        // Mid-gesture the live views hold the PREVIOUS frame's solve, so a tile
        // whose solved position returned to its baseline (a relaxed push) would
        // otherwise keep its stale pushed frame. Apply the solved scene
        // absolutely: every scene entry lands, unlisted means "at baseline".
        var absolute = transaction
        for tile in scene.tiles where absolute.tileFrames[tile.id] == nil {
            absolute.tileFrames[tile.id] = tile.frame
        }
        for zone in scene.zones where absolute.zonePlacements[zone.zoneId] == nil {
            absolute.zonePlacements[zone.zoneId] = zone
        }
        applyLayoutTransaction(absolute, activeTileId: activeTileId, activeZoneId: activeZoneId)
    }

    private func applyLayoutTransaction(
        _ transaction: CanvasLayoutTransaction,
        activeTileId: UUID? = nil,
        activeZoneId: UUID? = nil
    ) {
        let oldTileOrigins = Dictionary(uniqueKeysWithValues: transaction.tileFrames.keys.compactMap { id in
            tileView(for: id).map { (id, $0.frame.origin) }
        })
        let oldZoneOrigins = Dictionary(uniqueKeysWithValues: transaction.zonePlacements.keys.compactMap { id in
            zoneChromeViews[id].map { (id, $0.frame.origin) }
        })
        // Placements must land first: ZoneLayer stores member frames locally, so
        // converting a solver's world target against the previous origin would
        // apply a zone move twice.
        for (id, placement) in transaction.zonePlacements {
            if let index = liveZones.firstIndex(where: { $0.zoneId == id }) { liveZones[index] = placement }
            if let layer = zoneLayers.first(where: { $0.placement.zoneId == id }) { layer.placement = placement }
            if var model = zoneDisplayByZoneId[id] {
                model.placement = placement
                zoneDisplayByZoneId[id] = model
            }
        }
        for (id, frame) in transaction.tileFrames {
            if let index = canvasState.tiles.firstIndex(where: { $0.id == id }) {
                canvasState.tiles[index].frame = frame
            }
            if let layer = zoneLayers.first(where: { $0.tiles.contains(where: { $0.id == id }) }),
               let index = layer.tiles.firstIndex(where: { $0.id == id }) {
                layer.tiles[index].frame = CanvasEngine.worldToZoneLocal(frame, zoneOrigin: layer.placement.origin)
            }
        }
        layoutAllTiles()

        guard !autoLayoutReduceMotionProvider() else { return }
        let activeZoneMembers: Set<UUID> = activeZoneId.map { zoneId in
            Set(autoLayoutScene().tiles.lazy.filter { $0.zoneId == zoneId }.map(\.id))
        } ?? []
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.allowsImplicitAnimation = true
            for (id, oldOrigin) in oldTileOrigins where id != activeTileId && !activeZoneMembers.contains(id) {
                guard let view = tileView(for: id), view.frame.origin != oldOrigin else { continue }
                let target = view.frame.origin
                view.setFrameOrigin(oldOrigin)
                view.animator().setFrameOrigin(target)
            }
            for (id, oldOrigin) in oldZoneOrigins where id != activeZoneId {
                guard let view = zoneChromeViews[id], view.frame.origin != oldOrigin else { continue }
                let target = view.frame.origin
                view.setFrameOrigin(oldOrigin)
                view.animator().setFrameOrigin(target)
            }
        }
    }

    @discardableResult
    func finishAutoLayoutGesture() -> CanvasLayoutTransaction? {
        guard let baseline = autoLayoutGestureBaseline else { return nil }
        autoLayoutGestureBaseline = nil
        autoLayoutSwapLatch = nil
        let current = autoLayoutScene()
        let oldTiles = Dictionary(uniqueKeysWithValues: baseline.tiles.map { ($0.id, $0.frame) })
        let oldZones = Dictionary(uniqueKeysWithValues: baseline.zones.map { ($0.zoneId, $0) })
        var transaction = CanvasLayoutTransaction()
        for tile in current.tiles where oldTiles[tile.id] != tile.frame { transaction.tileFrames[tile.id] = tile.frame }
        for zone in current.zones where oldZones[zone.zoneId] != zone { transaction.zonePlacements[zone.zoneId] = zone }
        guard !transaction.tileFrames.isEmpty || !transaction.zonePlacements.isEmpty else { return nil }
        return transaction
    }

    func tidyAutoLayout(zoneId: UUID? = nil, commit: Bool = true, offerUndo: Bool = true) {
        let baseline = autoLayoutScene()
        _ = beginGeometryEdit(
            .tidy,
            tileIds: Set(baseline.tiles.map(\.id)),
            zoneIds: Set(baseline.zones.map(\.zoneId))
        )
        autoLayoutGestureBaseline = baseline
        applyAutoLayout(.tidy(zoneId: zoneId), baseline: baseline)
        if commit {
            _ = finishAutoLayoutGesture()
            if let transaction = commitGeometryEdit(), offerUndo {
                showAutoLayoutUndo(
                    changedCount: transaction.changedEntityCount
                )
            }
        }
    }

    /// Suppresses `arrangeAutoLayoutAfterSpawn` for the duration of `body`.
    ///
    /// M1.2 (`.plans/46`): hydrating a zone reinstalls its runtime-backed tiles
    /// through `installProjectTile`, which ends in `arrangeAutoLayoutAfterSpawn` and
    /// re-tidies the WHOLE zone. Running that once per tile would move the user's
    /// tiles on every workspace switch. A hydration restores what was already
    /// arranged; it is not a spawn and must not arrange anything.
    func withAutoLayoutSuppressed(_ body: () -> Void) {
        let previous = suppressesAutoLayoutForHydration
        suppressesAutoLayoutForHydration = true
        defer { suppressesAutoLayoutForHydration = previous }
        body()
    }

    private var suppressesAutoLayoutForHydration: Bool {
        get { _suppressesAutoLayoutForHydration }
        set { _suppressesAutoLayoutForHydration = newValue }
    }

    func arrangeAutoLayoutAfterSpawn(zoneId: UUID?) {
        guard !suppressesAutoLayoutForHydration else { return }
        guard isAutoLayoutEnabled else { return }
        let baseline = autoLayoutScene()
        _ = beginGeometryEdit(
            .autoLayout,
            tileIds: Set(baseline.tiles.map(\.id)),
            zoneIds: Set(baseline.zones.map(\.zoneId))
        )
        autoLayoutGestureBaseline = baseline
        if let zoneId { expandZoneToContainMembers(zoneId) }
        applyAutoLayout(.tidy(zoneId: zoneId), baseline: autoLayoutScene())
        _ = finishAutoLayoutGesture()
        _ = commitGeometryEdit()
    }

    private func expandZoneToContainMembers(_ zoneId: UUID) {
        let scene = autoLayoutScene()
        guard var zone = scene.zones.first(where: { $0.zoneId == zoneId }) else { return }
        let members = scene.tiles.filter { $0.zoneId == zoneId }
        guard !members.isEmpty else { return }
        let padding = ZoneBoundsConfig.padding(defaults: autoLayoutDefaults)
        let header = Double(ZoneChromeNSView.headerHeight)
        let minX = members.map(\.frame.x).min()!
        let minY = members.map(\.frame.y).min()!
        let maxX = members.map { $0.frame.x + $0.frame.width }.max()!
        let maxY = members.map { $0.frame.y + $0.frame.height }.max()!
        let newX = min(zone.origin.x, minX - padding)
        let newY = min(zone.origin.y, minY - header - padding)
        let newRight = max(zone.origin.x + zone.size.width, maxX + padding)
        let newBottom = max(zone.origin.y + zone.size.height, maxY + padding)
        let expanded = ZonePlacement(
            zoneId: zone.zoneId, projectId: zone.projectId,
            homeRelativePath: zone.homeRelativePath,
            origin: ZonePoint(x: newX, y: newY),
            size: ZoneSize(width: newRight - newX, height: newBottom - newY),
            color: zone.color, collapsed: zone.collapsed,
            hydrationPolicy: zone.hydrationPolicy, autoLayoutMode: zone.autoLayoutMode,
            name: zone.name, navKey: zone.navKey, zPosition: zone.zPosition)
        guard expanded != zone else { return }
        zone = expanded
        applyLayoutTransaction(CanvasLayoutTransaction(
            tileFrames: Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.frame) }),
            zonePlacements: [zoneId: zone]
        ))
    }

    func setZoneAutoLayoutMode(_ mode: ZoneAutoLayoutMode, zoneId: UUID) {
        var placement: ZonePlacement?
        if let index = liveZones.firstIndex(where: { $0.zoneId == zoneId }) {
            liveZones[index].autoLayoutMode = mode
            placement = liveZones[index]
        }
        if let layer = zoneLayers.first(where: { $0.placement.zoneId == zoneId }) {
            layer.placement.autoLayoutMode = mode
            placement = layer.placement
        }
        guard let placement else { return }
        if var model = zoneDisplayByZoneId[zoneId] { model.placement.autoLayoutMode = mode; zoneDisplayByZoneId[zoneId] = model }
        onZoneMoved?(placement)
        if mode.resolves(globalEnabled: CanvasAutoLayoutConfig.enabled(defaults: autoLayoutDefaults)),
           CanvasAutoLayoutConfig.activation(defaults: autoLayoutDefaults) == .immediately {
            tidyAutoLayout(zoneId: zoneId)
        }
    }

    func setZoneScopePickerInteractionOwned(_ owned: Bool) {
        isZoneScopePickerActive = owned
        if owned {
            zoneGesture = .none
            endPointerPan()
            hideDragGhost()
        }
    }

    /// Starts the same memory-only zone flow as an empty-canvas drag, for
    /// Command Center and other non-pointer creation surfaces. The provisional
    /// zone cannot persist or capture members until a project/Home is confirmed.
    @discardableResult
    func beginProvisionalZone(screenRect: CGRect? = nil) -> UUID {
        let availableWidth = max(320, bounds.width - 80)
        let availableHeight = max(220, bounds.height - 80)
        let width = min(760, availableWidth)
        let height = min(520, availableHeight)
        let rect = screenRect ?? CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
        let first = CanvasEngine.screenToWorld(
            CGPoint(x: rect.minX, y: rect.minY),
            viewport: canvasState.viewport
        )
        let second = CanvasEngine.screenToWorld(
            CGPoint(x: rect.maxX, y: rect.maxY),
            viewport: canvasState.viewport
        )
        let zoneId = UUID()
        let zoneName = nextDefaultGroupZoneName()
        let placement = ZonePlacement(
            zoneId: zoneId,
            projectId: nil,
            homeRelativePath: nil,
            origin: ZonePoint(x: Double(min(first.x, second.x)), y: Double(min(first.y, second.y))),
            size: ZoneSize(width: Double(abs(second.x - first.x)), height: Double(abs(second.y - first.y))),
            color: ZoneColorAllocator.nextColor(existingColors: liveZones.map(\.color)),
            collapsed: false,
            hydrationPolicy: .automatic,
            name: zoneName,
            navKey: nil
        )
        liveZones.append(placement)
        provisionalZoneIds.insert(zoneId)
        zoneDisplayByZoneId[zoneId] = ZoneRenderModel(
            placement: placement,
            displayName: zoneName,
            scopeLabel: "Choose a project to finish",
            isProvisional: true
        )
        if showsZoneChrome, zoneChromeViews[zoneId] == nil {
            let view = ZoneChromeNSView(model: zoneDisplayByZoneId[zoneId]!)
            zoneChromeViews[zoneId] = view
            worldPlane.addSubview(view, positioned: .below, relativeTo: nil)
        }
        layoutAllTiles()
        reorderTileSubviewsByZIndex()

        if let scope = agreedFilesystemScope(enclosedBy: placement),
           let projectId = scope.projectId {
            commitProvisionalZone(
                zoneId: zoneId,
                projectId: projectId,
                homeRelativePath: scope.homeRelativePath,
                scopeLabel: scopeLabelForZoneScope?(scope)
                    ?? scope.homeRelativePath.map { "Project / \($0)" }
                    ?? "Project Root"
            )
        } else {
            onZoneScopeRequired?(placement, CGPoint(x: rect.midX, y: rect.midY))
        }
        return zoneId
    }

    /// Commits a new marquee only after project/Home validation. Until this call,
    /// the zone has no tile membership and has never reached persistence.
    func commitProvisionalZone(
        zoneId: UUID,
        projectId: UUID,
        homeRelativePath: String?,
        scopeLabel: String
    ) {
        guard provisionalZoneIds.remove(zoneId) != nil,
              let index = liveZones.firstIndex(where: { $0.zoneId == zoneId }) else { return }
        liveZones[index].projectId = projectId
        liveZones[index].homeRelativePath = homeRelativePath
        let placement = liveZones[index]
        if var model = zoneDisplayByZoneId[zoneId] {
            model.placement = placement
            model.scopeLabel = scopeLabel
            model.isProvisional = false
            zoneDisplayByZoneId[zoneId] = model
            zoneChromeViews[zoneId]?.update(model: model)
        }
        adoptBareTiles(enclosedBy: placement)
        layoutAllTiles()
        reorderTileSubviewsByZIndex()
        onZoneCreated?(placement)
        if isAutoLayoutEnabled { tidyAutoLayout(zoneId: zoneId, offerUndo: false) }
        delegate?.canvasDidChange(self)
    }

    /// A cancelled provisional zone was memory-only, so removal deliberately does
    /// not emit `onZoneClosed` and cannot delete or spill any tile.
    func cancelProvisionalZone(zoneId: UUID) {
        guard provisionalZoneIds.remove(zoneId) != nil else { return }
        liveZones.removeAll { $0.zoneId == zoneId }
        zoneDisplayByZoneId.removeValue(forKey: zoneId)
        zoneChromeViews.removeValue(forKey: zoneId)?.removeFromSuperview()
        layoutAllTiles()
        reorderTileSubviewsByZIndex()
    }

    /// Atomically updates the zone's creation default. Existing member tiles are
    /// intentionally untouched: membership is layout, never filesystem identity.
    func setZoneScope(
        zoneId: UUID,
        projectId: UUID,
        homeRelativePath: String?,
        scopeLabel: String
    ) {
        var placement: ZonePlacement?
        if let index = liveZones.firstIndex(where: { $0.zoneId == zoneId }) {
            liveZones[index].projectId = projectId
            liveZones[index].homeRelativePath = homeRelativePath
            placement = liveZones[index]
        }
        if let layer = zoneLayers.first(where: { $0.placement.zoneId == zoneId }) {
            layer.placement.projectId = projectId
            layer.placement.homeRelativePath = homeRelativePath
            placement = layer.placement
        }
        guard let placement else { return }
        if var model = zoneDisplayByZoneId[zoneId] {
            model.placement = placement
            model.scopeLabel = scopeLabel
            model.isProvisional = false
            zoneDisplayByZoneId[zoneId] = model
            zoneChromeViews[zoneId]?.update(model: model)
        }
        onZoneMoved?(placement)
        delegate?.canvasDidChange(self)
    }

    func setZoneColor(_ color: String, zoneId: UUID) {
        guard ZoneColorConfig.palette.contains(color.lowercased()) else { return }
        mutateZonePlacement(zoneId: zoneId) { $0.color = color.lowercased() }
        onZoneColorChanged?(zoneId, color.lowercased())
    }

    func setZoneCollapsed(_ collapsed: Bool, zoneId: UUID) {
        mutateZonePlacement(zoneId: zoneId) { $0.collapsed = collapsed }
        layoutAllTiles()
    }

    private func mutateZonePlacement(zoneId: UUID, mutation: (inout ZonePlacement) -> Void) {
        var placement: ZonePlacement?
        if let index = liveZones.firstIndex(where: { $0.zoneId == zoneId }) {
            mutation(&liveZones[index])
            placement = liveZones[index]
        }
        if let layer = zoneLayers.first(where: { $0.placement.zoneId == zoneId }) {
            mutation(&layer.placement)
            placement = layer.placement
        }
        guard let placement else { return }
        if let index = liveZones.firstIndex(where: { $0.zoneId == zoneId }) {
            liveZones[index] = placement
        }
        if let layer = zoneLayers.first(where: { $0.placement.zoneId == zoneId }) {
            layer.placement = placement
            layer.renderModel.placement = placement
        }
        if let index = zoneRenderModels.firstIndex(where: { $0.placement.zoneId == zoneId }) {
            zoneRenderModels[index].placement = placement
        }
        if var model = zoneDisplayByZoneId[zoneId] {
            model.placement = placement
            zoneDisplayByZoneId[zoneId] = model
            zoneChromeViews[zoneId]?.update(model: model)
        }
        onZoneMoved?(placement)
        delegate?.canvasDidChange(self)
    }

    private func adoptBareTiles(enclosedBy placement: ZonePlacement) {
        let ox = placement.origin.x, oy = placement.origin.y
        let ow = placement.size.width, oh = placement.size.height
        for tile in canvasState.tiles where tileZoneMembership[tile.id] == nil {
            let cx = tile.frame.x + tile.frame.width / 2
            let cy = tile.frame.y + tile.frame.height / 2
            guard cx >= ox, cx <= ox + ow, cy >= oy, cy <= oy + oh else { continue }
            setTileZone(tile.id, zoneId: placement.zoneId)
        }
    }

    private func agreedFilesystemScope(enclosedBy placement: ZonePlacement) -> ZoneScope? {
        let filesystemKinds: Set<TileKind> = [.terminal, .file, .fileTree, .managedAgent]
        let ox = placement.origin.x, oy = placement.origin.y
        let ow = placement.size.width, oh = placement.size.height
        let enclosed = canvasState.tiles.filter { tile in
            guard filesystemKinds.contains(tile.kind) else { return false }
            let cx = tile.frame.x + tile.frame.width / 2
            let cy = tile.frame.y + tile.frame.height / 2
            return cx >= ox && cx <= ox + ow && cy >= oy && cy <= oy + oh
        }
        guard !enclosed.isEmpty else { return nil }
        let scopes = enclosed.compactMap { filesystemScopeForTile?($0.id) }
        guard scopes.count == enclosed.count,
              let first = scopes.first,
              first.projectId != nil,
              scopes.dropFirst().allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    private func showAutoLayoutUndo(changedCount: Int) {
        guard changedCount > 0 else { return }
        autoLayoutUndoTimer?.invalidate()
        let noun = changedCount == 1 ? "item" : "items"
        autoLayoutUndoToast.show("Auto layout arranged \(changedCount) \(noun)")
        autoLayoutUndoTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissAutoLayoutUndo() }
        }
    }

    private func dismissAutoLayoutUndo() {
        autoLayoutUndoTimer?.invalidate()
        autoLayoutUndoTimer = nil
        autoLayoutUndoToast.hide()
    }

    @objc private func undoAutoLayout() {
        dismissAutoLayoutUndo()
        activeCanvasUndoManager?.undo()
    }

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

    /// QA: what a single camera step actually costs, counted rather than timed.
    /// A count is deterministic; a wall-clock assertion on a laptop is a flake
    /// generator (see docs/internals/performance.md, "Witnessing performance").
    /// Every field here is a WRITE that reached AppKit — an assignment skipped
    /// because the value was unchanged deliberately does not count, which is
    /// what makes "a pan writes bounds zero times" a meaningful assertion.
    struct CameraLayoutStats: Equatable {
        var tilesVisited = 0
        var tilesLaidOut = 0
        var frameWrites = 0
        var boundsWrites = 0
        var modelWrites = 0
        var chromeRepaints = 0
        var terminalSurfaceWrites = 0
        /// Writes of the CAMERA's own geometry — the one ancestor mutation a
        /// camera step is supposed to cost. It is deliberately **zero today**:
        /// there is no single place the camera is applied, because
        /// `layoutAllTiles` re-derives a screen frame per tile instead. That
        /// zero is the red half of `canvas.camera-slope`, and it is also its own
        /// anti-teeth — a canvas that stopped moving anything would report zero
        /// here too, which is why the scenario pairs it with a screen-frame
        /// invariant rather than trusting the count alone.
        var cameraMutations = 0
    }
    private(set) var qaCameraLayoutStats = CameraLayoutStats()
    func qaResetCameraLayoutStats() { qaCameraLayoutStats = CameraLayoutStats() }

    /// Live frame-time recorder for gestures. Nil unless frame logging or the
    /// frame HUD is explicitly enabled, so it costs nothing in a normal run.
    private(set) lazy var frameRecorder: CanvasFrameRecorder? =
        CanvasFrameRecorder.isEnabled
            ? CanvasFrameRecorder(view: self) { [weak self] stats in
                self?.frameHUD?.update(stats: stats)
            }
            : nil

    /// Shallow, screen-space, click-through HUD. It is absent from the view tree
    /// unless `CONTINUUM_FRAME_HUD=1`; it never participates in world geometry.
    private var frameHUD: CanvasFrameHUDView?

    /// QA: every installed tile view, across BOTH models the canvas keeps —
    /// the flat collection and each `ZoneLayer` (see the zone-unify note on
    /// `layoutTile`). A camera step pays for all of them.
    var qaTotalInstalledTileCount: Int {
        tileViews.count + zoneLayers.reduce(0) { $0 + $1.tileViews.count }
    }

    /// The single view whose geometry carries the camera. Tiles and zone chrome
    /// are its children at WORLD frames; screen-fixed overlays stay direct
    /// children of the canvas. See `CanvasWorldPlaneView`.
    let worldPlane = CanvasWorldPlaneView()
    private let documentRelationshipOverlay = DocumentRelationshipOverlayView()
    private var documentLinks: [DocumentAgentLink] = []
    private var documentAgentTileIds: [AgentID: UUID] = [:]
    private var hoveredRelationshipEndpointId: UUID?

    struct DocumentRelationshipQAStats: Equatable {
        /// Every call to `updateDocumentRelationshipOverlay`, including ones that
        /// early-out. A camera step must not grow this — see
        /// `canvas.document-relationship-zoom-cost`.
        var updateCalls = 0
        var tileIndexVisits = 0
        var linkEvaluations = 0
        var segmentAssignments = 0
        var stackingReconciliations = 0
        /// Times the overlay's own frame was actually rewritten. The overlay is a
        /// world-space sibling now, so this must track content (tiles moving,
        /// links changing), never the camera.
        var frameWrites = 0
    }
    private(set) var qaDocumentRelationshipStats = DocumentRelationshipQAStats()
    func qaResetDocumentRelationshipStats() { qaDocumentRelationshipStats = .init() }

    /// Where a surfaced tile's real body lives while the camera moves: in the
    /// window, outside the world plane, clipped out of every draw. See the comment
    /// at its installation in `init` for why this shape and not `isHidden`.
    let surfaceParkView = TileSurfaceParkView(frame: .zero)

    /// One baked surface per tile, with the revision it represents. `.plans/36`.
    let tileSurfaceStore = TileSurfaceStore()

    /// Resolved ONCE here from production config, rather than re-read per gesture.
    ///
    /// Settable for exactly one reason: `--tile-surface-residency-check` has to
    /// witness both states in one process, and the alternatives are worse — writing
    /// the flag into `UserDefaults.standard` would pollute the real defaults domain
    /// (hazard 3, and the bundle guard looks for exactly that), and mutating the
    /// environment after launch is not reliably visible through `ProcessInfo`. No
    /// production path assigns this; the check is the only caller.
    var surfaceResidencyEnabled: Bool = TileSurfaceResidencyConfig.enabled()

    private(set) var qaSurfaceDemotionCount = 0
    private(set) var qaSurfacePromotionCount = 0
    /// Tiles that WANTED to be surfaced for a gesture and were refused. The reasons
    /// are the safety invariant made observable: stale content, a surface less
    /// sharp than the screen needs, or the bake budget for the transition ran out.
    private(set) var qaSurfaceRefusedStaleCount = 0
    private(set) var qaSurfaceRefusedSharpnessCount = 0
    private(set) var qaSurfaceRefusedBudgetCount = 0
    /// Too-soft tiles a camera step left surfaced because the per-step promotion
    /// cap was spent. Deferral is the storm policy working; this is what makes it
    /// observable instead of indistinguishable from a stall.
    private(set) var qaSurfaceSharpnessDeferredCount = 0
    /// Bakes dropped for being a flat rectangle on a tile whose body always
    /// paints. Non-zero means something upstream is leaving bodies undrawable.
    private(set) var qaSurfaceRefusedBlankCount = 0
    /// Bakes refused because the window was not being shown. Non-zero is normal
    /// (it is the notification-lag gap being covered); large and growing means
    /// something is evaluating residency for a window nobody can see.
    private(set) var qaSurfaceRefusedOccludedCount = 0

    /// Live occlusion answer: the injected provider in checks, otherwise the
    /// window's own state. `nil` means "cannot know", which callers treat as
    /// permission — a canvas with no window has other guards.
    private func resolvedWindowVisibility() -> Bool? {
        if let occlusionVisibilityProvider { return occlusionVisibilityProvider() }
        guard let window else { return nil }
        return window.occlusionState.contains(.visible)
    }

    func qaResetSurfaceResidencyCounters() {
        qaSurfaceDemotionCount = 0
        qaSurfacePromotionCount = 0
        qaSurfaceRefusedStaleCount = 0
        qaSurfaceRefusedSharpnessCount = 0
        qaSurfaceRefusedBudgetCount = 0
        qaSurfaceStalePromotionCount = 0
        qaSurfaceEvictionCount = 0
        qaSurfaceRefusedMemoryCount = 0
        qaSurfaceDegradedBakeCount = 0
        qaSurfaceSlimCount = 0
        qaSurfaceSharpnessDeferredCount = 0
        qaSurfaceRefusedBlankCount = 0
        qaSurfaceRefusedOccludedCount = 0
        // Was missing, and its absence made `checkMidGestureDemotionCatchesUp`'s
        // "suppression must be observable" assertion satisfiable by history from an
        // earlier arm — a false green.
        qaResidencySuppressedDemotionCount = 0
        tileSurfaceStore.qaResetCounters()
    }

    /// Tile views currently rendering from a surface, maintained rather than
    /// derived, so the per-step sharpness pass is O(surfaced) and never a view-tree
    /// walk. `qaSurfacedTileViews` reads the tree instead, so the witness can
    /// require the two to agree — a maintained set that drifts from the tree is the
    /// bug this shape invites.
    private var surfacedTiles: [UUID: TileNSView] = [:]

    /// Tile views currently rendering from a surface rather than their real body,
    /// read from the view tree.
    /// The world-space rect the viewport currently shows — the "visible" the
    /// residency witnesses mean when they say a tile must be sharp on screen.
    var qaVisibleWorldRect: CGRect { worldPlane.bounds }

    var qaSurfacedTileViews: [TileNSView] {
        tileViewsInVisualOrder.filter { $0.surfaceResidency == .surfaced }
    }

    /// The same population according to the maintained set.
    var qaTrackedSurfacedTileCount: Int { surfacedTiles.count }

    var qaParkedBodyCount: Int { surfaceParkView.subviews.count }

    /// The visible world region, which is what "farthest" is measured from.
    var qaWorldPlaneBounds: CGRect { worldPlane.bounds }

    /// Point the world plane at `canvasState.viewport`. This is the whole camera
    /// application — one view's bounds — and it replaces the per-tile screen-frame
    /// pass `layoutAllTiles` used to run on every step.
    private func syncWorldPlaneToCamera() {
        if !Self.geometryNearlyEqual(worldPlane.frame.width, bounds.width)
            || !Self.geometryNearlyEqual(worldPlane.frame.height, bounds.height)
            || !Self.geometryNearlyEqual(worldPlane.frame.origin.x, 0)
            || !Self.geometryNearlyEqual(worldPlane.frame.origin.y, 0) {
            // Only when the canvas itself resizes, never per camera step.
            worldPlane.frame = bounds
        }
        let viewport = canvasState.viewport
        let writes = worldPlane.applyCamera(
            viewportSize: bounds.size,
            worldOrigin: CGPoint(x: viewport.x, y: viewport.y),
            zoom: viewport.zoom
        )
        qaCameraLayoutStats.cameraMutations += writes
        // The document-relationship overlay does NOT need a per-camera-step
        // recompute: it is a world-space sibling now (see
        // `updateDocumentRelationshipOverlay`'s doc comment), so its content is
        // camera-invariant and every real invalidation (links set, tiles
        // added/removed/moved, hover/focus) already calls it directly.
        updateContextualAgentLineageGeometry()
    }

    /// Every installed tile view in BACK-TO-FRONT paint order, read from the view
    /// tree rather than the model — the visual order `reorderTileSubviewsByZIndex`
    /// produces.
    ///
    /// It exists so callers stop reaching into `subviews` directly: tile views are
    /// direct children of this view today, but the retained world plane
    /// (.plans/22 Slice 3) reparents them, and every direct `subviews` read would
    /// silently start returning nothing. Changing this one accessor is how that
    /// migration keeps its witnesses honest.
    var tileViewsInVisualOrder: [TileNSView] {
        worldPlane.subviews.compactMap { $0 as? TileNSView }
    }

    /// Tile views the user can actually see.
    ///
    /// The plane's `bounds` IS the visible world region — that is what makes it
    /// the camera — so visibility is one rect test per tile against a value
    /// already to hand, with no `CanvasEngine` round trip and no screen-space
    /// conversion.
    ///
    /// This exists because zoom's chrome refresh used to run over EVERY installed
    /// tile, which made a zoom step O(installed) rather than O(1): a tile parked
    /// far off-screen cost a step exactly what an on-screen one cost.
    /// `canvas.magnify-slope` measured 4 chrome refreshes per step at 16 installed
    /// and 38 at 128, with the visible count pinned at 12 throughout.
    var visibleTileViews: [TileNSView] {
        let visibleWorld = worldPlane.bounds
        return worldPlane.subviews.compactMap { subview in
            guard let tile = subview as? TileNSView,
                  tile.frame.intersects(visibleWorld) else { return nil }
            return tile
        }
    }

    /// QA: how many installed tile views are NOT where the camera says they
    /// should be — each view's ACTUAL rect in canvas coordinates, converted
    /// through whatever view tree currently hosts it, against
    /// `CanvasEngine.tileScreenFrame`.
    ///
    /// Zero is the camera's correctness invariant, and it is deliberately
    /// phrased so it survives the retained-world-plane migration: today a
    /// tile's own frame IS its screen rect, and afterwards an ancestor's
    /// transform produces the same rect from an unchanged tile frame. That
    /// makes it the anti-teeth the write counters cannot be: a canvas that
    /// stopped moving tiles reports zero writes AND a nonzero mismatch here.
    /// Hidden (collapsed) tiles are skipped — they are deliberately not
    /// presented, so their geometry is not a camera claim.
    var qaTileScreenFrameMismatchCount: Int {
        var mismatches = 0
        func check(_ view: TileNSView, worldFrame: TileFrame) {
            guard !view.isHidden else { return }
            let expected = CanvasEngine.tileScreenFrame(worldFrame, viewport: canvasState.viewport)
            let actual = view.convert(view.bounds, to: self)
            if !Self.geometryNearlyEqual(actual.origin.x, expected.origin.x)
                || !Self.geometryNearlyEqual(actual.origin.y, expected.origin.y)
                || !Self.geometryNearlyEqual(actual.size.width, expected.size.width)
                || !Self.geometryNearlyEqual(actual.size.height, expected.size.height) {
                mismatches += 1
            }
        }
        for tile in canvasState.tiles {
            if let view = tileViews[tile.id] { check(view, worldFrame: tile.frame) }
        }
        for layer in zoneLayers {
            for tile in layer.tiles {
                if let view = layer.tileViews[tile.id] {
                    check(view, worldFrame: CanvasEngine.worldFrame(tile: tile, in: layer.placement))
                }
            }
        }
        return mismatches
    }

    /// QA: redraw invalidations every installed tile's chrome has asked for.
    ///
    /// This is the counter the camera budgets were MISSING, and its absence made
    /// `canvas.zoom` report a fixed canvas as green while a real one stayed
    /// choppy. The budgets measured layout work and wall time on a harness that
    /// never rasterizes — but a zoom changes SCALE, so the cost that dominates a
    /// real gesture is re-rasterizing layer-backed content at the new scale, and
    /// forced layout underneath it. A 30-second `sample` of a real pinch over 9
    /// live tiles (2026-08-14) put ~2,600 samples in `CA::Layer::display_if_needed`
    /// and only ~380 in the camera itself.
    ///
    /// Counting INVALIDATIONS rather than timing AppKit's rasterization keeps the
    /// witness deterministic and headless, for the same reason the camera budgets
    /// count bounds writes instead of timing `layoutSubtree`: the invalidation is
    /// the decision we control, and the redraw is its consequence.
    var qaTotalTileChromeRedrawCount: Int {
        tileViewsInVisualOrder.reduce(0) { $0 + $1.qaTitleBarRedrawCount }
    }

    /// QA: canvas-driven layout invalidations across every installed tile. A
    /// camera step must not mark tile bodies for relayout — that is what makes a
    /// rasterization pass drag the whole subtree with it.
    var qaTotalTileLayoutInvalidationCount: Int {
        tileViewsInVisualOrder.reduce(0) { $0 + $1.qaCanvasLayoutInvalidationCount }
    }

    /// QA: title-bar draws AppKit actually executed, across every installed
    /// tile. `qaTotalTileChromeRedrawCount` above counts invalidations — the
    /// decision we control; this counts the rasterization that follows, and it
    /// only moves when a display cycle is pumped. The pair closes the blindness
    /// that let a layout-only harness call zoom green while a real pinch was
    /// choppy: an invalidation storm with no draws means the harness never
    /// rendered, and draws exceeding invalidations means something repaints
    /// chrome without asking.
    var qaTotalTitleBarDrawCount: Int {
        tileViewsInVisualOrder.reduce(0) { $0 + $1.qaTitleBarDrawCount }
    }

    /// QA: title-bar z-order repairs across every installed tile. `layoutChrome`
    /// used to re-insert the bar unconditionally — a sublayer reorder per visible
    /// tile on every camera step that no other counter could see. A camera step
    /// over settled tiles must keep this at zero.
    var qaTotalChromeZOrderRepairCount: Int {
        tileViewsInVisualOrder.reduce(0) { $0 + $1.qaChromeZOrderRepairCount }
    }

    /// QA: layout passes that actually REACHED the tiles, whoever sent them.
    ///
    /// The invalidation counter above only sees the canvas asking. This sees the
    /// traversal arriving — including the window's own display-cycle layout pass,
    /// which is where a real zoom spends its largest single block and which no
    /// budget was watching. `pan` is expected to score 0 here and `zoom` roughly
    /// one per tile per step; that contrast is the measurement.
    var qaTotalTileLayoutPassCount: Int {
        tileViewsInVisualOrder.reduce(0) { $0 + $1.qaLayoutPassCount }
    }

    /// QA: the same, for the heaviest tile body we own. Zero on fixtures that hold
    /// no agent tile, which is itself worth seeing — it says the fixture cannot
    /// speak for a canvas that has one.
    var qaTotalTranscriptLayoutPassCount: Int {
        func walk(_ view: NSView) -> Int {
            var total = (view as? AgentTranscriptListView)?.qaLayoutPassCount ?? 0
            for subview in view.subviews { total += walk(subview) }
            return total
        }
        return tileViewsInVisualOrder.reduce(0) { $0 + walk($1) }
    }

    /// QA: how many installed tiles actually intersect the visible canvas at the
    /// current camera. The gap between this and `qaTotalInstalledTileCount` is
    /// the work a camera step spends on tiles the user cannot see.
    var qaTilesIntersectingViewport: Int {
        let visible = bounds
        var count = 0
        for tile in canvasState.tiles where tileViews[tile.id] != nil {
            if CanvasEngine.tileScreenFrame(tile.frame, viewport: canvasState.viewport).intersects(visible) { count += 1 }
        }
        for layer in zoneLayers {
            for tile in layer.tiles where layer.tileViews[tile.id] != nil {
                let world = CanvasEngine.worldFrame(tile: tile, in: layer.placement)
                if CanvasEngine.tileScreenFrame(world, viewport: canvasState.viewport).intersects(visible) { count += 1 }
            }
        }
        return count
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Kept separate from `NSResponder.undoManager`: editable descendants ask
    /// their responder chain for an undo manager while registering keystrokes.
    /// Exposing geometry history there would mix typing into the canvas stack.
    private var activeCanvasUndoManager: UndoManager? {
        guard let workspaceId = activeUndoWorkspaceId else { return nil }
        return canvasHistories[workspaceId]?.undoManager
    }

    private var focusedTextUndoManager: UndoManager? {
        guard let editor = window?.firstResponder as? NSTextView,
              editor.isEditable else { return nil }
        return editor.undoManager
    }

    /// Custom views must expose the standard responder actions explicitly.
    /// Editors nested inside tiles implement these actions themselves and win
    /// first; canvas chrome falls through here.
    @objc func undo(_ sender: Any?) {
        if let focusedTextUndoManager {
            focusedTextUndoManager.undo()
            return
        }
        activeCanvasUndoManager?.undo()
    }

    @objc func redo(_ sender: Any?) {
        if let focusedTextUndoManager {
            focusedTextUndoManager.redo()
            return
        }
        activeCanvasUndoManager?.redo()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo(_:)) {
            if let focusedTextUndoManager {
                menuItem.title = focusedTextUndoManager.undoMenuItemTitle
                return focusedTextUndoManager.canUndo
            }
            menuItem.title = activeCanvasUndoManager?.undoMenuItemTitle ?? "Undo"
            return activeCanvasUndoManager?.canUndo ?? false
        }
        if menuItem.action == #selector(redo(_:)) {
            if let focusedTextUndoManager {
                menuItem.title = focusedTextUndoManager.redoMenuItemTitle
                return focusedTextUndoManager.canRedo
            }
            menuItem.title = activeCanvasUndoManager?.redoMenuItemTitle ?? "Redo"
            return activeCanvasUndoManager?.canRedo ?? false
        }
        return true
    }

    func activateUndoWorkspace(_ workspaceId: UUID) {
        activeUndoWorkspaceId = workspaceId
        if canvasHistories[workspaceId] == nil {
            canvasHistories[workspaceId] = CanvasHistoryController(canvas: self)
        }
    }

    func clearActiveCanvasHistory() {
        guard let workspaceId = activeUndoWorkspaceId else { return }
        canvasHistories[workspaceId]?.removeAllActions()
    }

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
        // Defense-in-depth against the macOS 14 clipsToBounds default (NO): the
        // canvas's screen-fixed overlays (focus/attention rings outset past an
        // edge tile, HUDs) must not draw or composite over sibling chrome such
        // as the sidebar. The park clips itself; this bounds everything else.
        clipsToBounds = true
        // The world plane goes in FIRST and stays the bottom-most subview, so
        // every screen-fixed overlay added later with `positioned: .above` sits
        // above all world content without any further ordering work.
        worldPlane.frame = bounds
        addSubview(worldPlane, positioned: .below, relativeTo: nil)
        documentRelationshipOverlay.frame = worldPlane.bounds
        worldPlane.addSubview(documentRelationshipOverlay, positioned: .below, relativeTo: nil)
        // The park is a SIBLING of the world plane, which is the entire mechanism:
        // a camera step writes `worldPlane.bounds.size`, and that cascade reaches
        // descendants only. A parked body keeps its window, its appearance, its
        // backing scale and the layout cycle — measured at zero transcript layout
        // passes per camera step — while costing the camera nothing.
        //
        // Zero-sized AND clipped (the park sets `clipsToBounds` itself — macOS 14
        // flipped the default to NO, so relying on ancestor clipping silently
        // stopped being true), rather than `isHidden`: clipping bounds drawing and
        // compositing while layout still runs. `isHidden` would stop the layout
        // too, and with it the streaming this design exists to preserve.
        surfaceParkView.frame = .zero
        surfaceParkView.identifier = NSUserInterfaceItemIdentifier("canvas.surfacePark")
        addSubview(surfaceParkView, positioned: .below, relativeTo: nil)
        autoLayoutUndoToast.onUndo = { [weak self] in self?.undoAutoLayout() }
        autoLayoutUndoToast.setAccessibilityIdentifier("ContinuumCanvasAutoLayoutUndoToast")
        addSubview(autoLayoutUndoToast, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            autoLayoutUndoToast.centerXAnchor.constraint(equalTo: centerXAnchor),
            autoLayoutUndoToast.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Space.l),
            autoLayoutUndoToast.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -(Space.l * 2)),
        ])
        syncWorldPlaneToCamera()
        if CanvasFrameRecorder.isHUDEnabled {
            let hud = CanvasFrameHUDView(frame: .zero)
            hud.autoresizingMask = [.minXMargin, .maxYMargin]
            frameHUD = hud
            addSubview(hud, positioned: .above, relativeTo: nil)
            layoutFrameHUD()
        }
        applyTokens()
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
        reorderTileSubviewsByZIndex()
        // Exact-ID live settings: an unrelated preference write must never rerun
        // canvas policy or make a future feature depend on notification order.
        for key in [
            FocusBorderConfig.enabledKey,
            FocusBorderConfig.colorKey,
            FocusBorderConfig.gapKey,
            FocusBorderConfig.speedKey,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(focusBorderConfigDidChange),
                name: SettingChangeEvent.name(for: SettingID(rawValue: key)), object: nil)
        }
        for key in [CanvasAutoLayoutConfig.enabledKey, CanvasAutoLayoutConfig.activationKey] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(autoLayoutSettingsDidChange),
                name: SettingChangeEvent.name(for: SettingID(rawValue: key)), object: nil)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(tileGapSettingDidChange),
            name: SettingChangeEvent.name(for: SettingID(rawValue: TileGapResolver.userDefaultsKey)), object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(zoneChromeSettingDidChange),
            name: SettingChangeEvent.name(for: SettingID(rawValue: ZoneChromeFeature.userDefaultsKey)), object: nil)
        // Overlay-animation suspension: the marching ants freeze while the app
        // is inactive (and, via A3, while the window is occluded). Registered
        // with object nil so the activation witness can post synthetically.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActiveForOverlays),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActiveForOverlays),
            name: NSApplication.didResignActiveNotification,
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
            worldPlane.addSubview(view, positioned: .below, relativeTo: nil)
        }
        layoutZoneChromeViews()
        applyArmedZoneChrome()
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
            // A WORLD frame: zone chrome is a child of the world plane, so the
            // camera reaches it through the plane's bounds, not through this write.
            view.frame = Self.worldRect(CanvasEngine.zoneWorldFrame(placement))
            qaCameraLayoutStats.chromeRepaints += 1
            view.needsDisplay = true
        }
    }

    /// Grow a zone's stored frame so it contains one WORLD rect, never shrinking.
    /// T7 (`.plans/47`) — a zone resizes the moment a tile lands in it, not only
    /// once the tile is dragged afterwards.
    ///
    /// Takes an explicit rect rather than re-deriving the member set, because at
    /// spawn time the tile exists in exactly one of the two models and membership
    /// may not be stamped yet (a flat install does not stamp `zoneId`). The caller
    /// already knows precisely which rectangle has to fit.
    ///
    /// **Growing may move the origin, and that is not free for a layer.** A layer
    /// holds ZONE-LOCAL frames and `_layoutLayerTile` renders `local + origin`, so
    /// moving the origin left drags every existing tile left with it. The local
    /// frames are compensated by the same delta, which keeps every tile on the
    /// pixel it already occupied — the identical invariant the membership repair
    /// protects.
    @discardableResult
    func growZone(_ zoneId: UUID, toInclude worldFrame: TileFrame, notifyChange: Bool = true) -> Bool {
        guard let idx = liveZones.firstIndex(where: { $0.zoneId == zoneId }) else { return false }
        let pad = ZoneBoundsConfig.padding(defaults: autoLayoutDefaults)
        let hh = Double(ZoneChromeNSView.headerHeight)
        let cur = liveZones[idx]
        let newX = min(cur.origin.x, worldFrame.x - pad)
        let newY = min(cur.origin.y, worldFrame.y - pad - hh)
        let newMaxX = max(cur.origin.x + cur.size.width, worldFrame.x + worldFrame.width + pad)
        let newMaxY = max(cur.origin.y + cur.size.height, worldFrame.y + worldFrame.height + pad)
        let grown = ZonePoint(x: newX, y: newY)
        let grownSize = ZoneSize(width: newMaxX - newX, height: newMaxY - newY)
        guard grown != cur.origin || grownSize != cur.size else { return false }

        var placement = cur
        placement.origin = grown
        placement.size = grownSize
        liveZones[idx] = placement

        // world = local + origin, so an origin that moved by -delta needs every
        // local frame moved by +delta to stay where it is.
        let dx = cur.origin.x - grown.x
        let dy = cur.origin.y - grown.y
        if let layer = zoneLayers.first(where: { $0.placement.zoneId == zoneId }) {
            layer.placement = placement
            if dx != 0 || dy != 0 {
                for i in layer.tiles.indices {
                    layer.tiles[i].frame.x += dx
                    layer.tiles[i].frame.y += dy
                }
            }
            for tile in layer.tiles { _layoutLayerTile(tile, in: layer) }
        }
        if var model = zoneDisplayByZoneId[zoneId] {
            model.placement = placement
            zoneDisplayByZoneId[zoneId] = model
            zoneChromeViews[zoneId]?.update(model: model)
        }
        layoutZoneChromeViews()
        // Persist, so the grown zone survives a relaunch rather than snapping back.
        if notifyChange { onZoneMoved?(placement) }
        return true
    }

    /// `growZone` for the spawn path, skipped while hydration is replaying a
    /// persisted scene. A restore must not re-tidy or re-size the zone it is
    /// rebuilding — the frames it installs are already the ones that were saved.
    private func growZoneOnSpawn(_ zoneId: UUID, toInclude worldFrame: TileFrame) {
        guard !suppressesAutoLayoutForHydration else { return }
        growZone(zoneId, toInclude: worldFrame)
    }

    /// Grow a zone's stored frame to contain its members (union + padding +
    /// header), never shrinking. Called on tile resize (not move). Persists the
    /// new placement via `onZoneMoved` so the grown size survives relaunch.
    private func growZoneToFitMembers(_ zoneId: UUID, notifyChange: Bool = true) {
        guard let idx = liveZones.firstIndex(where: { $0.zoneId == zoneId }) else { return }
        let members = canvasState.tiles.filter { tileZoneMembership[$0.id] == zoneId }
        guard !members.isEmpty else { return }
        let pad = ZoneBoundsConfig.padding(defaults: autoLayoutDefaults)
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
        if notifyChange { onZoneMoved?(p) }
    }

    /// After a tile MOVE commits, re-evaluate its zone membership (zone-unify P4):
    /// dropping a tile so its center lands inside a zone adopts it (re-homing across
    /// zones too); dragging a member so its center sits more than the break-out
    /// distance beyond its zone detaches it to bare canvas. Returns true if changed.
    @discardableResult
    func reevaluateZoneMembership(forMovedTile tileId: UUID, notifyChange: Bool = true) -> Bool {
        guard let tile = canvasState.tiles.first(where: { $0.id == tileId }) else { return false }
        let cx = tile.frame.x + tile.frame.width / 2
        let cy = tile.frame.y + tile.frame.height / 2
        let current = tileZoneMembership[tileId]
        var containing = liveZones.reversed().first { z in
            let f = CanvasEngine.zoneWorldFrame(z)
            return cx >= f.x && cx <= f.x + f.width && cy >= f.y && cy <= f.y + f.height
        }
        if containing == nil, isAutoLayoutEnabled {
            // Attach-adoption: dropping a tile gap-flush against a zone member
            // appends it to that zone even though its center is outside the
            // zone frame (the zone then grows around it in the settle pass).
            let gap = TileGapResolver.resolvedGap(defaults: autoLayoutDefaults)
            let sceneTiles = autoLayoutScene().tiles
            containing = liveZones.reversed().first { z in
                sceneTiles.contains { member in
                    member.zoneId == z.zoneId && member.id != tileId
                        && CanvasAutoLayoutEngine.isGapAdjacent(tile.frame, member.frame, gap: gap, tolerance: 6)
                }
            }
        }
        var changed = false
        if let containing {
            if containing.zoneId != current {
                setTileZone(tileId, zoneId: containing.zoneId)   // adopt / re-home
                growZoneToFitMembers(containing.zoneId, notifyChange: notifyChange)
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
            if isAutoLayoutEnabled {
                // Membership is decided only by this direct drop. The zone the
                // tile LEFT closes ranks (magnetism keeps its members touching);
                // the destination zone settles in settleAutoLayoutAfterMove once
                // the caller's drop position is final.
                if let departed = current, departed != tileZoneMembership[tileId] {
                    applyAutoLayout(.settle(zoneId: departed, anchor: nil, pin: false), baseline: autoLayoutScene())
                }
            } else {
                layoutAllTiles()
            }
            if notifyChange { delegate?.canvasDidChange(self) }
        }
        return changed
    }

    /// Rest-state magnetism after a committed tile MOVE: the moved tile's zone
    /// settles so every member sits at exact gap-contact with the cluster, the
    /// moved tile joining last (the composition wins over its raw drop point).
    /// Membership is resolved through the scene so ZoneLayer-owned members
    /// settle too, not just flat-canvas tiles.
    func settleAutoLayoutAfterMove(tileId: UUID) {
        guard isAutoLayoutEnabled else { return }
        var scene = autoLayoutScene()
        guard let member = scene.tiles.first(where: { $0.id == tileId }),
              let zoneId = member.zoneId else { return }
        // A latched exchange completes EXACTLY: the mover takes the displaced
        // sibling's pre-gesture origin, so pointer jitter at the drop can never
        // skew the inherited slot, and it settles PINNED — residents are pushed
        // aside, never the mover into a different lane. (The latch and gesture
        // baseline are still alive here — the gesture finishes in
        // commitGeometryGesture.)
        var pinned = false
        if let latch = autoLayoutSwapLatch,
           scene.tiles.first(where: { $0.id == latch })?.zoneId == zoneId,
           let slot = autoLayoutGestureBaseline?.tiles.first(where: { $0.id == latch })?.frame {
            applyLayoutTransaction(CanvasLayoutTransaction(
                tileFrames: [tileId: TileFrame(x: slot.x, y: slot.y, width: member.frame.width, height: member.frame.height)]))
            pinned = true
            scene = autoLayoutScene()
        }
        // Appending to an edge: a member dropped gap-attached to a sibling is
        // an append, and the zone GROWS to absorb it — it is never clamped
        // back inside (the one sanctioned tile→zone size effect besides
        // resize pressure).
        let gap = TileGapResolver.resolvedGap(defaults: autoLayoutDefaults)
        if let frame = scene.tiles.first(where: { $0.id == tileId })?.frame,
           scene.tiles.contains(where: {
               $0.zoneId == zoneId && $0.id != tileId
                   && CanvasAutoLayoutEngine.isGapAdjacent(frame, $0.frame, gap: gap, tolerance: 6)
           }) {
            expandZoneToContainMembers(zoneId)
            scene = autoLayoutScene()
        }
        applyAutoLayout(.settle(zoneId: zoneId, anchor: tileId, pin: pinned), baseline: scene)
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
        reorderTileSubviewsByZIndex()
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
        // Zone chrome now lives in the world plane, so its frame already IS world
        // coordinates: the screen->world inversion this used to perform is gone,
        // and with it any chance of getting the camera term wrong here.
        return TileFrame(x: Double(view.frame.origin.x), y: Double(view.frame.origin.y),
                         width: Double(view.frame.width), height: Double(view.frame.height))
    }

    // MARK: - Tile management

    func agentStatus(for tileId: UUID) -> AgentStatus? {
        tileViews[tileId]?.agentStatus
    }

    func refreshRunArtifactsTiles() {
        for view in tileViews.values {
            (view as? RunArtifactsTileNSView)?.reloadRunArtifacts()
        }
        for layer in zoneLayers {
            for view in layer.tileViews.values {
                (view as? RunArtifactsTileNSView)?.reloadRunArtifacts()
            }
        }
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
        wireRelationshipHover(for: tileView, tileId: tileId)
        worldPlane.addSubview(tileView)
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
        if flatCompatibilitySceneActive, let v = tileViews[tileId] { return v }
        for layer in zoneLayers {
            if let v = layer.tileViews[tileId] { return v }
        }
        return nil
    }

    /// Shows one contextual direct edge. Convenience for the common single-edge
    /// caller; routes through `showContextualAgentLineage(edges:)`.
    func showContextualAgentLineage(parentTileID: UUID, childTileID: UUID) {
        showContextualAgentLineage(edges: [(parentTileID, childTileID)])
    }

    /// C11 — a fan-out reveal has more than one live edge to show: the
    /// parent's whole VISIBLE fan, not just the one agent that was clicked.
    /// No lineage is persisted here; callers derive edges from
    /// `AgentRecord.parentAgentID` and current tile bindings.
    ///
    /// Bounded to `InboxSort.maxVisibleChildren` — the same cap the inbox
    /// itself enforces on a parent's visible children (`boundedForInbox`) —
    /// so the canvas never draws more fan-out than the inbox would ever show
    /// at once. A degenerate edge (parent == child) or one naming a tile this
    /// canvas does not hold is dropped rather than failing the whole set.
    func showContextualAgentLineage(edges: [(parentTileID: UUID, childTileID: UUID)]) {
        let resolved = edges
            .filter { $0.parentTileID != $0.childTileID }
            .filter { tileView(for: $0.parentTileID) != nil && tileView(for: $0.childTileID) != nil }
            .prefix(InboxSort.maxVisibleChildren)
        guard !resolved.isEmpty else {
            clearContextualAgentLineage()
            return
        }
        contextualAgentLineage = Array(resolved)
        let overlay = agentLineageOverlay ?? AgentLineageOverlayView()
        agentLineageOverlay = overlay
        if overlay.superview == nil {
            overlay.frame = bounds
            overlay.autoresizingMask = [.width, .height]
            overlay.setMarchingSuspended(overlayAnimationsSuspended)
            // Priority-visible over opaque tiles. Focus, attention, and HUD
            // siblings already above the world plane retain precedence.
            addSubview(overlay, positioned: .above, relativeTo: worldPlane)
        }
        updateContextualAgentLineageGeometry()
    }

    func clearContextualAgentLineage() {
        contextualAgentLineage = []
        agentLineageOverlay?.hide()
        agentLineageOverlay?.removeFromSuperview()
    }

    private func updateContextualAgentLineageGeometry() {
        guard !contextualAgentLineage.isEmpty, let overlay = agentLineageOverlay else { return }
        overlay.frame = bounds
        let segments = contextualAgentLineage.compactMap { relation -> DocumentRelationshipOverlayView.Segment? in
            guard let parent = tileView(for: relation.parentTileID),
                  let child = tileView(for: relation.childTileID) else { return nil }
            return .init(
                source: overlay.convert(parent.bounds, from: parent),
                target: overlay.convert(child.bounds, from: child),
                emphasized: true
            )
        }
        overlay.show(segments: segments)
    }

    func setDocumentRelationships(_ links: [DocumentAgentLink], agentTileIds: [AgentID: UUID]) {
        documentLinks = links
        documentAgentTileIds = agentTileIds
        let agentTilesByDocument = Dictionary(grouping: links, by: \.documentTileId).mapValues { documentLinks in
            documentLinks.compactMap { agentTileIds[$0.agentId] }
        }
        for tile in allWorkspaceTiles() {
            guard let fileView = tileView(for: tile.id) as? FileTileNSView else { continue }
            fileView.onRevealReferencedAgentTile = { [weak self] agentTileId in
                guard let self else { return }
                self.bringToFront(tileId: agentTileId)
                _ = self.focusBroker?.requestFocus(.tile(agentTileId), reason: .userClick)
            }
            fileView.setReferencedAgentTiles(agentTilesByDocument[tile.id, default: []])
        }
        updateDocumentRelationshipOverlay()
    }

    var qaDocumentRelationshipSegmentCount: Int { documentRelationshipOverlay.segments.count }

    /// T8 (`.plans/48`): the segment rects as the overlay will actually paint them,
    /// plus the two conversions a leg needs to check them against an INDEPENDENT
    /// oracle. Asserting the segment equals `overlay.convert(view.bounds, from:)`
    /// would just restate the fix; converting both sides into the canvas's own
    /// space — the `tileRectInCanvasSpace` idiom — does not.
    var qaDocumentRelationshipSegmentRects: [(source: CGRect, target: CGRect)] {
        documentRelationshipOverlay.segments.map { ($0.source, $0.target) }
    }

    func qaSegmentRectInCanvasSpace(_ rect: CGRect) -> CGRect {
        documentRelationshipOverlay.convert(rect, to: self)
    }

    func qaTileRectInCanvasSpace(_ tileId: UUID) -> CGRect? {
        guard let view = tileView(for: tileId) else { return nil }
        return view.convert(view.bounds, to: self)
    }

    /// T8: the lineage overlay's painted endpoints, in the canvas's own space.
    /// C11: one entry per painted edge, in the same order `showContextualAgentLineage`
    /// resolved them — never more than `InboxSort.maxVisibleChildren`.
    var qaLineageEndpointsInCanvasSpace: [(start: CGPoint, end: CGPoint)] {
        guard let overlay = agentLineageOverlay else { return [] }
        return overlay.endpoints.map { (overlay.convert($0.start, to: self), overlay.convert($0.end, to: self)) }
    }

    var qaLineageAnimationCount: Int { agentLineageOverlay?.qaAnimationCount ?? 0 }
    var qaLineageIsAnimating: Bool { agentLineageOverlay?.qaIsAnimating == true }
    var qaLineageHitTestPassesThrough: Bool {
        guard let overlay = agentLineageOverlay else { return true }
        return overlay.hitTest(CGPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)) == nil
    }

    var qaDocumentRelationshipRoutes: [DocumentRelationshipOverlayView.Route] {
        documentRelationshipOverlay.segments.compactMap(DocumentRelationshipOverlayView.route(for:))
    }

    var qaDocumentRelationshipDisplayInvalidationCount: Int {
        documentRelationshipOverlay.displayInvalidationCount
    }

    struct DocumentRelationshipStackingQASnapshot {
        var backgroundIndices: [Int]
        var connectorIndices: [Int]
        var tileIndices: [Int]
        var worldPlaneIndex: Int?
        var topOverlayIndices: [Int]
        var relationshipOverlayInstances: Int
        var relationshipHitTestPassesThrough: Bool

        var contractHolds: Bool {
            guard let highestBackground = backgroundIndices.max(),
                  let lowestConnector = connectorIndices.min(),
                  let highestConnector = connectorIndices.max(),
                  let lowestTile = tileIndices.min() else { return false }
            return highestBackground < lowestConnector
                && highestConnector < lowestTile
                && worldPlaneIndex.map { plane in topOverlayIndices.allSatisfy { $0 > plane } } == true
                && relationshipOverlayInstances == 1
                && relationshipHitTestPassesThrough
        }
    }

    var qaDocumentRelationshipStackingSnapshot: DocumentRelationshipStackingQASnapshot {
        let worldSubviews = worldPlane.subviews
        let backgrounds = Set(zoneChromeViews.values.map(ObjectIdentifier.init))
        let connectors = Set(
            [ObjectIdentifier(documentRelationshipOverlay)]
                + [agentLineageOverlay].compactMap { $0 }.map(ObjectIdentifier.init))
        let tiles = Set(tileViewsInVisualOrder.map(ObjectIdentifier.init))
        let canvasSubviews = subviews
        let topOverlays = ([focusBorderOverlay].compactMap { $0 }
            + Array(attentionBorderOverlays.values)
            + [dragGhostOverlay, workspaceTransitionLabelView, frameHUD].compactMap { $0 })
        return .init(
            backgroundIndices: worldSubviews.indices.filter { backgrounds.contains(ObjectIdentifier(worldSubviews[$0])) },
            connectorIndices: worldSubviews.indices.filter { connectors.contains(ObjectIdentifier(worldSubviews[$0])) },
            tileIndices: worldSubviews.indices.filter { tiles.contains(ObjectIdentifier(worldSubviews[$0])) },
            worldPlaneIndex: canvasSubviews.firstIndex(where: { $0 === worldPlane }),
            topOverlayIndices: topOverlays.compactMap { overlay in canvasSubviews.firstIndex(where: { $0 === overlay }) },
            relationshipOverlayInstances: worldSubviews.filter { $0 === documentRelationshipOverlay }.count,
            relationshipHitTestPassesThrough: documentRelationshipOverlay.hitTest(.zero) == nil)
    }

    /// Perf (.plans/44 M item 1): this used to run every camera step from
    /// `syncWorldPlaneToCamera`, sizing itself to `worldPlane.bounds` — a
    /// viewport-sized frame write on every step, plus a full re-walk of every
    /// installed tile, even on a canvas with zero document links.
    ///
    /// Both tile views and this overlay are direct children of `worldPlane` at
    /// WORLD frames, so a rect resolved in `worldPlane`'s own coordinate space
    /// is camera-invariant: pan and zoom only change `worldPlane`'s bounds, not
    /// the relative position of its children. That means the overlay's frame
    /// can be sized to its CONTENT (the union of every linked tile pair, in
    /// world space) instead of the viewport, and this function no longer needs
    /// to run on a camera step at all — `syncWorldPlaneToCamera` does not call
    /// it. `qaSegmentRectInCanvasSpace` still resolves the live, on-screen
    /// position at call time via the normal view hierarchy, which is what lets
    /// the camera move the connectors "for free" the same way it moves tiles.
    ///
    /// Real callers remain: `setDocumentRelationships`, tile add/remove,
    /// `markActive`/hover (emphasis), and every geometry commit that already
    /// routes through `layoutAllTiles` or a zone-placement update.
    private func updateDocumentRelationshipOverlay() {
        qaDocumentRelationshipStats.updateCalls += 1
        guard !documentLinks.isEmpty else {
            if !documentRelationshipOverlay.segments.isEmpty {
                documentRelationshipOverlay.segments = []
            }
            return
        }
        let focused = canvasState.lastActiveTileId
        var viewsByTileId = tileViews
        qaDocumentRelationshipStats.tileIndexVisits += tileViews.count
        for layer in zoneLayers {
            for (tileId, view) in layer.tileViews {
                qaDocumentRelationshipStats.tileIndexVisits += 1
                viewsByTileId[tileId] = view
            }
        }
        struct Pair {
            let agentTileId: UUID
            let documentTileId: UUID
            let sourceWorldFrame: CGRect
            let targetWorldFrame: CGRect
        }
        var pairs: [Pair] = []
        pairs.reserveCapacity(documentLinks.count)
        for link in documentLinks {
            qaDocumentRelationshipStats.linkEvaluations += 1
            guard let agentTileId = documentAgentTileIds[link.agentId],
                  let source = viewsByTileId[agentTileId], !source.isHidden,
                  let target = viewsByTileId[link.documentTileId], !target.isHidden else { continue }
            pairs.append(Pair(
                agentTileId: agentTileId,
                documentTileId: link.documentTileId,
                sourceWorldFrame: worldPlane.convert(source.bounds, from: source),
                targetWorldFrame: worldPlane.convert(target.bounds, from: target)
            ))
        }
        guard !pairs.isEmpty else {
            if !documentRelationshipOverlay.segments.isEmpty {
                documentRelationshipOverlay.segments = []
            }
            return
        }
        // Padded past the route's max escape clearance (12pt, `route(for:)`'s
        // overlap-fallback polyline) plus stroke width, so every drawn path —
        // including curve handles, which stay within the source/target union —
        // stays inside the view it is drawn into.
        var worldBounds = pairs[0].sourceWorldFrame.union(pairs[0].targetWorldFrame)
        for pair in pairs.dropFirst() {
            worldBounds = worldBounds.union(pair.sourceWorldFrame).union(pair.targetWorldFrame)
        }
        let paddedBounds = worldBounds.insetBy(dx: -32, dy: -32)
        if documentRelationshipOverlay.frame != paddedBounds {
            qaDocumentRelationshipStats.frameWrites += 1
            documentRelationshipOverlay.frame = paddedBounds
        }
        // T8 (`.plans/48`): converted into the OVERLAY's coordinate space via
        // `convert`, the same idiom the lineage overlay and the focus border
        // already use — it cannot drift if the camera model changes again.
        let segments = pairs.map { pair -> DocumentRelationshipOverlayView.Segment in
            .init(
                source: documentRelationshipOverlay.convert(pair.sourceWorldFrame, from: worldPlane),
                target: documentRelationshipOverlay.convert(pair.targetWorldFrame, from: worldPlane),
                emphasized: focused == pair.agentTileId || focused == pair.documentTileId
                    || hoveredRelationshipEndpointId == pair.agentTileId
                    || hoveredRelationshipEndpointId == pair.documentTileId
            )
        }
        if documentRelationshipOverlay.segments != segments {
            qaDocumentRelationshipStats.segmentAssignments += 1
            documentRelationshipOverlay.segments = segments
        }
    }

    private func wireRelationshipHover(for tileView: TileNSView, tileId: UUID) {
        tileView.onHoverChanged = { [weak self] hovered in
            guard let self else { return }
            if hovered {
                self.hoveredRelationshipEndpointId = tileId
            } else if self.hoveredRelationshipEndpointId == tileId {
                self.hoveredRelationshipEndpointId = nil
            }
            self.updateDocumentRelationshipOverlay()
        }
    }

    // MARK: - Transactional geometry editing

    @discardableResult
    func beginGeometryEdit(
        _ action: CanvasGeometryAction,
        tileIds: Set<UUID> = [],
        zoneIds: Set<UUID> = [],
        includeAllTiles: Bool = false,
        includeAllZones: Bool = false
    ) -> Bool {
        guard pendingGeometryEdit == nil else { return false }
        let capturesLayoutChain = isAutoLayoutEnabled && action != .resizeTileToPreset && action != .dockTile
        let capturedTileIds = includeAllTiles || capturesLayoutChain
            ? Set(allWorkspaceTiles().map(\.id))
            : tileIds
        let capturedZoneIds = includeAllZones ? Set(allZonePlacements().map(\.zoneId)) : zoneIds
        pendingGeometryEdit = PendingGeometryEdit(
            action: action,
            tileIds: capturedTileIds,
            zoneIds: capturedZoneIds,
            before: captureGeometry(tileIds: capturedTileIds, zoneIds: capturedZoneIds)
        )
        return true
    }

    @discardableResult
    func commitGeometryEdit() -> CanvasGeometryTransaction? {
        guard let pending = pendingGeometryEdit else { return nil }
        pendingGeometryEdit = nil
        let after = captureGeometry(tileIds: pending.tileIds, zoneIds: pending.zoneIds)
        let transaction = CanvasGeometryTransaction(action: pending.action, before: pending.before, after: after)
        guard !transaction.isNoOp else { return nil }
        guard persistGeometrySnapshot(transaction.after) else {
            _ = applyGeometrySnapshot(transaction.before, notifyCommit: false)
            return nil
        }
        if let workspaceId = activeUndoWorkspaceId {
            canvasHistories[workspaceId]?.record(transaction)
        }
        notifyGeometryCommit(transaction)
        return transaction
    }

    func cancelGeometryEdit() {
        guard let pending = pendingGeometryEdit else { return }
        pendingGeometryEdit = nil
        applyGeometrySnapshot(pending.before, notifyCommit: false)
    }

    @discardableResult
    func performGeometryEdit(
        _ action: CanvasGeometryAction,
        tileIds: Set<UUID> = [],
        zoneIds: Set<UUID> = [],
        includeAllTiles: Bool = false,
        includeAllZones: Bool = false,
        mutation: () -> Void
    ) -> CanvasGeometryTransaction? {
        guard beginGeometryEdit(
            action,
            tileIds: tileIds,
            zoneIds: zoneIds,
            includeAllTiles: includeAllTiles,
            includeAllZones: includeAllZones
        ) else { return nil }
        mutation()
        return commitGeometryEdit()
    }

    private func allZonePlacements() -> [ZonePlacement] {
        // A ZoneLayer is the mutable owner whenever one is installed. `liveZones`
        // still carries the boot-time copy for hit testing, so letting it win here
        // makes a layer drag appear unchanged to the transaction and suppresses
        // both undo registration and `onZoneMoved`.
        var byId = Dictionary(uniqueKeysWithValues: liveZones.map { ($0.zoneId, $0) })
        for layer in zoneLayers { byId[layer.placement.zoneId] = layer.placement }
        return Array(byId.values)
    }

    /// Complete zone state exactly as the mounted workspace is displaying it.
    /// WorkspaceRuntime reads this synchronously before a switch so an in-flight
    /// debounce or stale document copy cannot discard the last visible mutation.
    func workspaceZonePlacementsForPersistence() -> [ZonePlacement] {
        allZonePlacements()
    }

    private func geometryTileIds(inZone zoneId: UUID) -> Set<UUID> {
        var ids = Set(canvasState.tiles.filter { $0.zoneId == zoneId || tileZoneMembership[$0.id] == zoneId }.map(\.id))
        if let layer = zoneLayers.first(where: { $0.placement.zoneId == zoneId }) {
            ids.formUnion(layer.tiles.map(\.id))
        }
        return ids
    }

    private func captureGeometry(tileIds: Set<UUID>, zoneIds: Set<UUID>) -> CanvasGeometrySnapshot {
        var tilesById: [UUID: CanvasTileGeometry] = [:]
        for tile in canvasState.tiles where tileIds.contains(tile.id) {
            tilesById[tile.id] = CanvasTileGeometry(tileId: tile.id, frame: tile.frame, zoneId: tile.zoneId)
        }
        for layer in zoneLayers {
            for tile in layer.tiles where tileIds.contains(tile.id) {
                tilesById[tile.id] = CanvasTileGeometry(
                    tileId: tile.id,
                    frame: CanvasEngine.worldFrame(tile: tile, in: layer.placement),
                    zoneId: tile.zoneId
                )
            }
        }
        let zones = allZonePlacements().compactMap { placement -> CanvasZoneGeometry? in
            guard zoneIds.contains(placement.zoneId) else { return nil }
            return CanvasZoneGeometry(zoneId: placement.zoneId, origin: placement.origin, size: placement.size)
        }
        return CanvasGeometrySnapshot(tiles: Array(tilesById.values), zones: zones)
    }

    func geometryMatches(_ snapshot: CanvasGeometrySnapshot) -> Bool {
        captureGeometry(
            tileIds: Set(snapshot.tiles.map(\.tileId)),
            zoneIds: Set(snapshot.zones.map(\.zoneId))
        ) == snapshot
    }

    @discardableResult
    func applyGeometrySnapshot(
        _ snapshot: CanvasGeometrySnapshot,
        previous: CanvasGeometrySnapshot? = nil,
        notifyCommit: Bool = true
    ) -> Bool {
        let zoneValues = Dictionary(uniqueKeysWithValues: snapshot.zones.map { ($0.zoneId, $0) })
        for index in liveZones.indices {
            guard let value = zoneValues[liveZones[index].zoneId] else { continue }
            liveZones[index].origin = value.origin
            liveZones[index].size = value.size
            if var model = zoneDisplayByZoneId[value.zoneId] {
                model.placement.origin = value.origin
                model.placement.size = value.size
                zoneDisplayByZoneId[value.zoneId] = model
                zoneChromeViews[value.zoneId]?.update(model: model)
            }
        }
        for layer in zoneLayers {
            guard let value = zoneValues[layer.placement.zoneId] else { continue }
            layer.placement.origin = value.origin
            layer.placement.size = value.size
            layer.renderModel.placement.origin = value.origin
            layer.renderModel.placement.size = value.size
        }

        let tileValues = Dictionary(uniqueKeysWithValues: snapshot.tiles.map { ($0.tileId, $0) })
        for index in canvasState.tiles.indices {
            guard let value = tileValues[canvasState.tiles[index].id] else { continue }
            canvasState.tiles[index].frame = value.frame
            canvasState.tiles[index].zoneId = value.zoneId
            if let zoneId = value.zoneId {
                tileZoneMembership[value.tileId] = zoneId
            } else {
                tileZoneMembership.removeValue(forKey: value.tileId)
            }
        }
        for layer in zoneLayers {
            for index in layer.tiles.indices {
                guard let value = tileValues[layer.tiles[index].id] else { continue }
                layer.tiles[index].frame = CanvasEngine.worldToZoneLocal(
                    value.frame,
                    zoneOrigin: layer.placement.origin
                )
                layer.tiles[index].zoneId = value.zoneId
            }
        }
        layoutAllTiles()
        reorderTileSubviewsByZIndex()

        if notifyCommit {
            guard persistGeometrySnapshot(snapshot) else {
                if let previous { _ = applyGeometrySnapshot(previous, notifyCommit: false) }
                return false
            }
            notifyGeometrySnapshotApplied(snapshot, previous: previous)
        }
        return true
    }

    private func persistGeometrySnapshot(_ snapshot: CanvasGeometrySnapshot) -> Bool {
        guard let onLayoutCommitted else { return true }
        let placements = Dictionary(uniqueKeysWithValues: allZonePlacements().map { ($0.zoneId, $0) })
        var layout = CanvasLayoutTransaction(
            tileFrames: Dictionary(uniqueKeysWithValues: snapshot.tiles.map { ($0.tileId, $0.frame) }),
            zonePlacements: [:]
        )
        for zone in snapshot.zones {
            guard var placement = placements[zone.zoneId] else { continue }
            placement.origin = zone.origin
            placement.size = zone.size
            layout.zonePlacements[zone.zoneId] = placement
        }
        return onLayoutCommitted(layout)
    }

    private func notifyGeometryCommit(_ transaction: CanvasGeometryTransaction) {
        notifyGeometrySnapshotApplied(transaction.after, previous: transaction.before)
    }

    private func notifyGeometrySnapshotApplied(
        _ snapshot: CanvasGeometrySnapshot,
        previous: CanvasGeometrySnapshot?
    ) {
        for zone in snapshot.zones {
            guard let before = previous?.zones.first(where: { $0.zoneId == zone.zoneId }),
                  before != zone,
                  let placement = allZonePlacements().first(where: { $0.zoneId == zone.zoneId }) else { continue }
            onZoneMoved?(placement)
        }
        delegate?.canvasDidChange(self)
    }

    func updateTile(_ tile: Tile, recalculateZoneBounds: Bool = true, notifyChange: Bool = true) {
        let baseline = autoLayoutGestureBaseline ?? autoLayoutScene()
        let previousTile: Tile
        let requestedWorldFrame: TileFrame
        if let idx = canvasState.tiles.firstIndex(where: { $0.id == tile.id }) {
            previousTile = canvasState.tiles[idx]
            canvasState.tiles[idx] = tile
            requestedWorldFrame = tile.frame
        } else if let layer = zoneLayers.first(where: { $0.tiles.contains(where: { $0.id == tile.id }) }),
                  let idx = layer.tiles.firstIndex(where: { $0.id == tile.id }) {
            previousTile = layer.tiles[idx]
            var updated = tile
            updated.zoneId = layer.placement.zoneId
            layer.tiles[idx] = updated
            requestedWorldFrame = CanvasEngine.worldFrame(tile: updated, in: layer.placement)
        } else {
            return
        }
        // zone-unify P3: only a RESIZE grows the owning zone; a MOVE leaves the
        // zone frame fixed (the caller passes recalculateZoneBounds: false).
        if CanvasAutoLayoutConfig.enabled(defaults: autoLayoutDefaults) {
            applyAutoLayout(.tile(id: tile.id, frame: requestedWorldFrame), baseline: baseline)
        } else if recalculateZoneBounds, let zoneId = tileZoneMembership[tile.id] {
            growZoneToFitMembers(zoneId, notifyChange: false)
        }
        if !CanvasAutoLayoutConfig.enabled(defaults: autoLayoutDefaults) { layoutAllTiles() }
        layoutZoneChromeViews()
        updateContextualAgentLineageGeometry()
        if previousTile.title != tile.title || previousTile.kind != tile.kind {
            delegate?.canvasSidebarModelDidChange(self)
        }
        if notifyChange { delegate?.canvasDidChange(self) }
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
    func showDragGhost(at worldFrame: TileFrame, label: String? = nil, detail: String? = nil) {
        let overlay = dragGhostOverlayView()
        overlay.show(
            at: CanvasEngine.tileScreenFrame(worldFrame, viewport: canvasState.viewport),
            label: label,
            detail: detail
        )
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
        // C11: the shared parent going away leaves every edge unanchored, so the
        // whole set clears; a single child going away only drops its own edge —
        // the rest of the parent's fan is still real and still on screen.
        if contextualAgentLineage.contains(where: { $0.parentTileID == id }) {
            clearContextualAgentLineage()
        } else if contextualAgentLineage.contains(where: { $0.childTileID == id }) {
            let remaining = contextualAgentLineage.filter { $0.childTileID != id }
            if remaining.isEmpty {
                clearContextualAgentLineage()
            } else {
                showContextualAgentLineage(edges: remaining)
            }
        }
        if let view = tileViews[id] {
            focusBroker?.unregister(view.focusSurfaceID)
            releaseSurfaceResidency(of: view)
            view.removeFromSuperview()
            tileViews.removeValue(forKey: id)
        }
        canvasState.tiles.removeAll { $0.id == id }
        // A tile installed through `installProjectTile` after `setZones` lives in a
        // ZoneLayer, not the flat collection — clearing only `canvasState.tiles`
        // took its VIEW away while leaving the model entry to be persisted and
        // rehydrated on the next load. The layer owns its own view map too.
        for layer in zoneLayers {
            if let view = layer.tileViews[id] {
                focusBroker?.unregister(view.focusSurfaceID)
                releaseSurfaceResidency(of: view)
                view.removeFromSuperview()
                layer.tileViews.removeValue(forKey: id)
            }
            layer.tiles.removeAll { $0.id == id }
        }
        if canvasState.lastActiveTileId == id {
            canvasState.lastActiveTileId = nil
        }
        // Clearing the ID is not enough: the overlay is a real subview that keeps
        // drawing (and animating) wherever it was last shown. Assigning
        // `borderedTileId = nil` directly left a marching-ants rectangle stranded at
        // the deleted tile's frame — visible, un-selectable, and un-deletable, since
        // there is no tile under it any more. Reported from the canvas as a "dead
        // zone I can see but can't delete"; it appeared to jump and then vanish
        // because focusing any other tile re-applies the overlay and MOVES it.
        // Route through `updateFocusBorder` so `applyFocusBorder` hides it.
        if borderedTileId == id {
            updateFocusBorder(borderedTileId: nil)
        }
        attentionTileIds.remove(id)
        if hoveredRelationshipEndpointId == id { hoveredRelationshipEndpointId = nil }
        attentionBorderOverlays[id]?.removeFromSuperview()
        attentionBorderOverlays.removeValue(forKey: id)
        updateDocumentRelationshipOverlay()
        delegate?.canvasSidebarModelDidChange(self)
        delegate?.canvasDidChange(self)
    }

    func markActive(tileId: UUID) {
        canvasState.lastActiveTileId = tileId
        updateFocusBorder(borderedTileId: tileId)
        updateDocumentRelationshipOverlay()
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
    private(set) var attentionTileIds: Set<UUID> = []
    private var attentionBorderOverlays: [UUID: FocusBorderOverlayView] = [:]

    /// Canvas-owned translucent ghost shown at a dragged tile's snap destination
    /// while drag magnetization is in range. Topmost, click-transparent.
    private var dragGhostOverlay: DragGhostOverlayView?

    /// Brief, click-through label shown after a workspace switch.
    private var workspaceTransitionLabelView: WorkspaceTransitionLabelView?

    /// UserDefaults the focus-border appearance resolves from (`FocusBorderConfig`).
    /// Overridable so `runFocusBorderSelfCheck` can drive enabled/color/gap
    /// deterministically without touching standard defaults.
    var focusBorderDefaults: UserDefaults = .standard

    /// App-activation input to overlay-animation suspension. Defaults TRUE and
    /// is flipped ONLY by the activation notifications — never initialized from
    /// live `NSApp.isActive` — so headless fixtures, which never activate the
    /// app, keep today's always-animating behavior without posting anything.
    private var appIsActiveForOverlayAnimation = true

    /// Occlusion input to the same suspension. Wired by the occlusion state
    /// machine (Leg A3); until then it stays true.
    private(set) var windowOcclusionVisible = true

    /// The ants march only when BOTH hold: the app is active and the window is
    /// at least partially visible. Everything else is compositor tax for motion
    /// nobody can see.
    private var overlayAnimationsSuspended: Bool {
        !(appIsActiveForOverlayAnimation && windowOcclusionVisible)
    }

    private func applyOverlayAnimationSuspension() {
        let suspended = overlayAnimationsSuspended
        focusBorderOverlay?.setMarchingSuspended(suspended)
        agentLineageOverlay?.setMarchingSuspended(suspended)
        for overlay in attentionBorderOverlays.values {
            overlay.setMarchingSuspended(suspended)
        }
    }

    @objc private func appDidBecomeActiveForOverlays() {
        appIsActiveForOverlayAnimation = true
        applyOverlayAnimationSuspension()
    }

    @objc private func appDidResignActiveForOverlays() {
        appIsActiveForOverlayAnimation = false
        applyOverlayAnimationSuspension()
        // A lost mouse-up must never leave preview geometry half-committed. Roll
        // the model back and clear per-view gesture state before focus returns.
        if pendingGeometryEdit != nil {
            cancelGeometryEdit()
            zoneGesture = .none
            pendingMovedPlacement = nil
            hideDragGhost()
            hideResizeDimensions()
            for view in tileViews.values { view.cancelActiveGeometryGesture() }
            for layer in zoneLayers {
                for view in layer.tileViews.values { view.cancelActiveGeometryGesture() }
            }
        }
    }

    private func focusBorderOverlayView() -> FocusBorderOverlayView {
        if let overlay = focusBorderOverlay { return overlay }
        let overlay = FocusBorderOverlayView(frame: .zero)
        // Born with the CURRENT suspension: an overlay created while the app is
        // inactive must be born static, not animate until the next transition.
        overlay.setMarchingSuspended(overlayAnimationsSuspended)
        focusBorderOverlay = overlay
        addSubview(overlay, positioned: .above, relativeTo: nil)
        return overlay
    }

    /// Show `overlay` around the tile's screen frame, or hide it when the outset
    /// ring would not intersect the canvas at all. Attention rings are uncapped
    /// (one per needs-attention tile), so without this an off-screen agent keeps
    /// an infinite animation running for pixels nobody can see. The reposition
    /// hooks run per camera commit for every ringed tile, so visibility tracks
    /// the camera with no extra plumbing.
    private func showOverlayIfOnViewport(_ overlay: FocusBorderOverlayView, around tileScreenFrame: CGRect) {
        let outset = tileScreenFrame.insetBy(dx: -overlay.gap, dy: -overlay.gap)
        if outset.intersects(bounds) {
            overlay.show(around: tileScreenFrame)
        } else {
            overlay.hide()
        }
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

    /// P1.11: the canvas IS `SurfaceToken.canvas` — the extreme end of the surface
    /// ladder, which is what makes a tile read as an object sitting ON something.
    /// `borderStrong`-on-`canvas` is the pair the ticket's Goal names, measured at
    /// 6.91:1 light / 6.09:1 dark, replacing white@0.25-on-white@0.10 at 1.68:1.
    ///
    /// WHAT THIS FILE DELIBERATELY DOES NOT ADOPT, each with the reason:
    ///
    ///  * `ZoneChromeNSView.color(named:)` and `focusBorderColor(named:)` are USER
    ///    configuration — a zone's colour and the focus-border colour are picked in
    ///    Settings from seven named hues. The palette declares five *semantic status*
    ///    accents; mapping the user's "mint" onto `accentDone` would silently change
    ///    what they chose. These are not literals standing in for a token.
    ///  * `NSColor.controlAccentColor` (selection ring, marquee, jump badges) is the
    ///    system accent the user set in System Settings, already appearance-resolved
    ///    through `appResolvedCGColor`. Replacing it with a token would be a
    ///    regression dressed as an adoption.
    ///  * The nav-mode and workspace-transition HUDs draw white text on a black
    ///    SCRIM over a dimmed canvas. That is legible in both appearances by
    ///    construction, and doing it properly needs a `scrim` surface plus an
    ///    on-scrim text token, neither of which P1.3 declared. Left for whoever
    ///    declares them; `runCanvasScrimInventoryCheck` pins the exact set so it
    ///    cannot quietly grow.
    func applyTokens() {
        layer?.backgroundColor = SurfaceToken.canvas.color.cgColor(in: self)
        if let zoneRenameField {
            zoneRenameField.textColor = TextToken.textPrimary.color.nsColor(in: self)
            zoneRenameField.backgroundColor = SurfaceToken.overlay.color.nsColor(in: self)
        }
        // The attention rings hold a RESOLVED colour (the overlay draws a stroke,
        // not a layer fill), so they have to be re-struck when the appearance
        // flips. No-op when nothing needs attention.
        if !attentionTileIds.isEmpty { applyAttentionBorders() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
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
        guard config.enabled, let targetId = borderedTileId, let view = tileView(for: targetId) else {
            focusBorderOverlay?.hide()
            return
        }
        // Attention-orange takes precedence: a focused tile that also needs a
        // human decision is represented only by the orange attention ring.
        guard !attentionTileIds.contains(targetId) else {
            focusBorderOverlay?.hide()
            return
        }
        let overlay = focusBorderOverlayView()
        overlay.configure(
            color: Self.focusBorderColor(named: config.color).withAlphaComponent(0.7),
            gap: CGFloat(config.gap),
            animationDuration: config.speed
        )
        showOverlayIfOnViewport(overlay, around: tileRectInCanvasSpace(view))
        // Keep the overlay topmost — tile installs/reorders can otherwise leave
        // it under later-added tile subviews.
        overlay.removeFromSuperview()
        addSubview(overlay, positioned: .above, relativeTo: nil)
    }

    func updateAttentionBorder(for tileId: UUID, status: AgentStatus?) {
        let shouldShow = status == .needsAttention
        let isShowing = attentionTileIds.contains(tileId)
        guard shouldShow != isShowing else {
            if shouldShow { applyAttentionBorders() }
            return
        }
        if shouldShow {
            attentionTileIds.insert(tileId)
        } else {
            attentionTileIds.remove(tileId)
            attentionBorderOverlays[tileId]?.removeFromSuperview()
            attentionBorderOverlays.removeValue(forKey: tileId)
        }
        applyAttentionBorders()
        applyFocusBorder()
    }

    /// The attention ring's hue, taken from P1.8's one status→appearance mapping
    /// rather than from the user's focus-border palette (P1.6).
    ///
    /// It used to be `focusBorderColor(named: FocusBorderConfig.attentionColor)`,
    /// i.e. the same name→`NSColor` map that serves the user's Settings choice,
    /// resolving "Orange" to `systemOrange`. `--ui-contrast-check` measured the
    /// result at **2.07:1** on a light tile, and no alpha fixes it: solid
    /// `systemOrange` on white is 2.31:1, because orange-on-white cannot clear
    /// 3:1 at all. The ring is not decorative — it is the app telling you a tile
    /// needs you — so WCAG 1.4.11's 3:1 applies and an exemption was not on the
    /// table.
    ///
    /// This is NOT the user-configuration carve-out `applyTokens()` documents:
    /// `FocusBorderConfig.attentionColor` was explicitly "not user-configurable"
    /// ("orange means human action is required"), so nothing the user picked is
    /// being overridden. The semantic is unchanged and the hue is still amber —
    /// `accentApproval` is 36°/35° across themes — but it now carries a darkened
    /// light-appearance variant, which is exactly what the old spelling lacked.
    /// Reading it off `StatusChipPresenter` also makes the ring, the approval
    /// dock's outline and the tile header's glyph one colour by construction.
    ///
    /// The 0.8 alpha is GONE, and that is the load-bearing half. A stroke at some
    /// alpha over an unknown backdrop is not a documented pair, so no gate can
    /// hold it to 3:1 — the same reason P1.11 dropped the sidebar's translucency
    /// when it adopted `panel`. Solid, the ring is exactly `accentApproval` on
    /// `canvas`/`tileBody`, two of P1.3's 104 documented pairs (5.90:1 and 5.62:1
    /// in light), asserted every run by `runTokenContrastChecks` — and named
    /// there explicitly as the attention ring, so it cannot be tuned out from
    /// under this call site.
    ///
    /// HONEST LIMIT: `--ui-contrast-check` does NOT see this ring. The overlay
    /// strokes its dashes in `draw(_:)`, so it is neither a layer border nor a
    /// `textColor` — the two things `UIProbeContrast.foregroundSlots` can read.
    /// What that gate measured at 2.07:1 was the LAB CARD's hand-painted stand-in
    /// (`makeManagedAgentApprovalDockPreview`), which had the same colour by copy.
    /// So the ratio is gated at the palette level (above) and the *pixels* by the
    /// committed `observer.rollup` baselines: reverting this line to
    /// `systemOrange` turns `--ui-baseline-check` red on both appearances (847 /
    /// 752 pixels, worst channel delta 105). Neither alone is sufficient — a
    /// baseline can be re-blessed, and the palette cannot know what this line
    /// paints — which is why both are recorded.
    private static var attentionAccent: TokenColor {
        StatusChipPresenter.display(for: .needsAttention).accent
    }

    private func applyAttentionBorders() {
        let color = Self.attentionAccent.nsColor(in: self)
        let gap = CGFloat(FocusBorderConfig.defaultGap)
        for tileId in Array(attentionBorderOverlays.keys) where !attentionTileIds.contains(tileId) {
            attentionBorderOverlays[tileId]?.removeFromSuperview()
            attentionBorderOverlays.removeValue(forKey: tileId)
        }
        for tileId in attentionTileIds.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let view = tileView(for: tileId) else { continue }
            let overlay = attentionBorderOverlays[tileId] ?? FocusBorderOverlayView(frame: .zero)
            overlay.setMarchingSuspended(overlayAnimationsSuspended)
            attentionBorderOverlays[tileId] = overlay
            overlay.configure(color: color, gap: gap, animationDuration: FocusBorderConfig.attentionSpeed)
            showOverlayIfOnViewport(overlay, around: tileRectInCanvasSpace(view))
            overlay.removeFromSuperview()
            addSubview(overlay, positioned: .above, relativeTo: nil)
        }
    }

    /// Re-resolve focus-border config and re-apply to the current bordered tile.
    /// Wired to the settings-changed notification so toggling/recoloring the
    /// border in Settings reflects immediately (docs/29 §1 live update).
    @objc func focusBorderConfigDidChange() {
        applyFocusBorder()
    }

    @objc private func autoLayoutSettingsDidChange() {
        let enabled = CanvasAutoLayoutConfig.enabled(defaults: autoLayoutDefaults)
        defer { lastAutoLayoutEnabled = enabled }
        guard enabled && !lastAutoLayoutEnabled else { return }
        switch CanvasAutoLayoutConfig.activation(defaults: autoLayoutDefaults) {
        case .immediately:
            tidyAutoLayout()
        case .onFirstEdit:
            autoLayoutDeferredUntilEdit = true
        }
    }

    @objc private func tileGapSettingDidChange() {
        guard CanvasAutoLayoutConfig.enabled(defaults: autoLayoutDefaults) else { return }
        tidyAutoLayout()
    }

    @objc private func zoneChromeSettingDidChange() {
        setZoneChromeVisible(ZoneChromeFeature.current)
    }

    private func setZoneChromeVisible(_ visible: Bool) {
        guard showsZoneChrome != visible else { return }
        showsZoneChrome = visible
        if visible {
            // M1.10: `installZoneChromeViews()` covers layers too, because
            // `setZones` now writes `liveZones` from the layer set.
            installZoneChromeViews()
        } else {
            for view in zoneChromeViews.values { view.removeFromSuperview() }
            zoneChromeViews.removeAll()
            for layer in zoneLayers {
            }
        }
        layoutAllTiles()
        reorderTileSubviewsByZIndex()
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
        guard tileId == borderedTileId, let view = tileView(for: tileId) else { return }
        showOverlayIfOnViewport(focusBorderOverlayView(), around: tileRectInCanvasSpace(view))
    }

    private func repositionAttentionBorderIfNeeded(for tileId: UUID) {
        guard attentionTileIds.contains(tileId),
              let view = tileView(for: tileId),
              let overlay = attentionBorderOverlays[tileId] else { return }
        showOverlayIfOnViewport(overlay, around: tileRectInCanvasSpace(view))
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
              let view = tileView(for: targetId),
              let overlay = focusBorderOverlay,
              overlay.qaIsAnimating else { return false }
        return overlay.frame == tileRectInCanvasSpace(view).insetBy(dx: -overlay.gap, dy: -overlay.gap)
    }

    /// QA: the frame the overlay is ACTUALLY painting, or nil if it is not on screen.
    ///
    /// Deliberately does **not** consult `borderedTileId`. It used to, and that is
    /// why a stranded overlay went unseen for so long: with the ID cleared but the
    /// view still visible, this reported `nil` while a marching-ants rectangle sat on
    /// the canvas. An accessor that asks the bookkeeping instead of the screen cannot
    /// witness the bookkeeping being wrong. Every existing caller is unaffected —
    /// when scope legitimately leaves all tiles, `applyFocusBorder` hides the overlay,
    /// so `isHidden` already answers nil.
    var qaFocusBorderFrame: CGRect? {
        guard let overlay = focusBorderOverlay, !overlay.isHidden else { return nil }
        return overlay.frame
    }

    /// QA: freeze the dash phase for a deterministic offscreen capture.
    func qaFreezeFocusBorder(phase: CGFloat = 0) {
        focusBorderOverlay?.qaFreeze(phase: phase)
    }

    /// QA: is the focus overlay's marching loop attached right now, regardless
    /// of which tile it frames. `qaFocusBorderActive` folds animation and
    /// geometry together; the activation witness needs them apart, because its
    /// subject is "visible but FROZEN".
    var qaFocusBorderAnimating: Bool {
        focusBorderOverlay?.qaIsAnimating == true
    }

    func qaAttentionBorderAnimating(for tileId: UUID) -> Bool {
        attentionBorderOverlays[tileId]?.qaIsAnimating == true
    }

    /// QA: the attention ring's painted frame, or nil when it is not on screen —
    /// same screen-truth contract as `qaFocusBorderFrame`.
    func qaAttentionBorderFrame(for tileId: UUID) -> CGRect? {
        guard let overlay = attentionBorderOverlays[tileId], !overlay.isHidden else { return nil }
        return overlay.frame
    }

    func qaAttentionBorderActive(for tileId: UUID) -> Bool {
        guard attentionTileIds.contains(tileId),
              let view = tileViews[tileId],
              let overlay = attentionBorderOverlays[tileId],
              overlay.qaIsAnimating else { return false }
        return overlay.frame == tileRectInCanvasSpace(view).insetBy(dx: -overlay.gap, dy: -overlay.gap)
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

    /// QA: every camera apply, whoever asked. With the driver in place, N input
    /// events inside one display interval must produce a BOUNDED number of
    /// these — the N-inputs-one-commit witness counts this, and it is the
    /// number that used to equal the raw event rate.
    private(set) var qaViewportApplyCount = 0

    func setViewport(_ viewport: CanvasViewport) {
        let cameraStepStart = ProcessInfo.processInfo.systemUptime
        if let last = lastViewportCommitAt {
            gestureCommitGapsMs.append((cameraStepStart - last) * 1_000)
        }
        lastViewportCommitAt = cameraStepStart
        // Read by the run-loop observer AFTER layout, display and the CA commit have
        // run — the three stages this method's own timing cannot see.
        pendingFrameStartedAt = cameraStepStart
        defer { gestureStepDurationsMs.append((ProcessInfo.processInfo.systemUptime - cameraStepStart) * 1_000) }
        qaViewportApplyCount += 1
        // Any writer other than the driver — a navigation snap, a pointer-pan
        // drag, a restore, a self-check — owns the camera now: gesture state
        // still in flight (a glide, accumulated scroll) must not keep steering
        // it. Field writes only; this sits on the perf scenarios' hot path.
        if !cameraDriver.isApplying { cameraDriver.noteExternalViewportChange() }
        canvasState.viewport = viewport
        frameRecorder?.noteCameraStep()
        // The camera is ONE view's geometry. Tiles and zone chrome hold world
        // frames that a camera step does not touch, so there is no per-tile pass
        // here any more — that pass was the 48 ms/step zoom cost.
        syncWorldPlaneToCamera()
        // A tile's chrome has screen-space FLOORS expressed in world units —
        // `grabHeightInLocalCoordinates`, `closeButtonWorldSize` and the resize
        // margin are all `max(worldConstant, screenPx / zoom)`, so the move-grab
        // strip stays grabbable when zoomed out. Those values change with zoom
        // (quantised into scale buckets) and nothing else. The old per-tile
        // camera pass repainted them as a side effect of resizing every tile;
        // the plane does not, so a zoom has to say so explicitly.
        //
        // VISIBLE tiles only, and unconditionally rather than guarded on the zoom
        // having changed. Two reasons, and they replace an earlier version that
        // was both narrower and wronger:
        //
        // - Iterating every INSTALLED tile made a zoom step O(installed) instead
        //   of O(1). `canvas.magnify-slope` measured 4 chrome refreshes per step
        //   at 16 installed and 38 at 128 with the visible count pinned at 12 —
        //   a tile parked off-screen cost a step exactly what an on-screen one
        //   cost.
        // - Dropping the zoom-changed guard is what keeps that correct. A PAN can
        //   bring a tile into view whose chrome was skipped while it was hidden,
        //   and this is the only place that would notice. It costs a pan nothing:
        //   `layoutChrome` compares the bar's frame before writing it, so at a
        //   constant zoom every visible tile is a no-op and `pan.chromeRedraws`
        //   and `pan.tileLayoutPasses` both stay at 0 — which the budgets assert.
        for view in visibleTileViews { view.refreshZoomDependentChrome() }
        // Sharpness is enforced HERE, per step, and not once per gesture.
        //
        // A tile admitted as sharp-enough at zoom 1.0 is not sharp enough two steps
        // into a zoom to 2.0, and deciding once per gesture would leave it soft for
        // the whole gesture. The per-step guarantee is CONVERGENCE, not
        // instantaneous sharpness: each step spends a capped promotion budget on
        // the too-soft tiles nearest the gesture anchor, because promoting them all
        // at once was the zoom-in storm (19 promotions, a 1.65 s gap, in a real
        // 89-tile session). The settled heartbeat catches up whatever a gesture
        // deferred.
        //
        // O(surfaced) over a maintained set, deliberately not a view-tree walk —
        // the same lesson `visibleTileViews` above records.
        enforceSurfaceSharpness()
        // Screen-fixed overlays are outside the plane, so they do not inherit the
        // camera and still have to be re-aimed at the tiles they track.
        repositionTrackingOverlaysForCamera()
        if navModeOverlayView != nil { qaCameraLayoutStats.chromeRepaints += 1 }
        navModeOverlayView?.needsDisplay = true
        if !cameraDriver.isApplying {
            // One-shot writers (navigation snaps, pointer drags, restores,
            // checks) keep the synchronous housekeeping. Driver commits defer
            // it to the gesture's settle: cursor rects are stale for at most
            // the settle window, and the delegate's save/hydration debounces
            // stop being re-armed per event only to detonate — a main-thread
            // double-fsync and a zone re-plan — in the gap where the NEXT
            // gesture begins. That gap was the zoom→pan transition lag.
            discardCursorRects()
            window?.invalidateCursorRects(for: self)
            delegate?.canvasDidChange(self)
        }
    }

    /// Once per gesture burst, when the driver's camera goes quiet: the
    /// housekeeping its commits deferred. Cursor rects rebuild against the
    /// resting camera; the delegate arms its persistence/hydration debounces
    /// exactly once.
    private func cameraGestureDidSettle() {
        discardCursorRects()
        window?.invalidateCursorRects(for: self)
        delegate?.canvasDidChange(self)
        // AFTER the delegate: baking and reparenting are the expensive halves, and
        // they belong on the far side of everything that makes the canvas
        // interactive again. Under Option A a settle is simply the first moment
        // demotions are allowed again, so the ordinary pass does the work.
        //
        // The sweep FIRST, and at the settle edge on purpose: it is the only
        // caller that promotes every soft in-lead tile in the same beat. Without
        // it the catch-up rationed promotions 2 per pass and bakes 4 per pass,
        // and a 20-tile view sharpened as seconds of one-by-one blur->sharp pops
        // — Dylan's "seeing a tile focus, blurry to hi res" report (2026-08-19).
        // Sharp on screen is ONE transition per gesture, together.
        enforceSurfaceSharpness()
        evaluateTileResidency()
        logGestureCost()
    }

    private func logGestureCost() {
        let steps = gestureStepDurationsMs.sorted()
        let frames = gestureFrameTailsMs.sorted()
        let gaps = gestureCommitGapsMs.sorted()
        gestureStepDurationsMs.removeAll(keepingCapacity: true)
        gestureFrameTailsMs.removeAll(keepingCapacity: true)
        gestureCommitGapsMs.removeAll(keepingCapacity: true)
        lastViewportCommitAt = nil
        pendingFrameStartedAt = nil
        guard steps.count >= 3 else { return }
        func p(_ sorted: [Double], _ q: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]
        }
        // Three views of one gesture. camera = Array's slice of the frame; frame =
        // the whole in-process frame including layout, display and the CA commit;
        // gap = the cadence commits actually arrived at. A smooth gesture needs
        // frame under the budget AND gap near the display period — a cheap frame at
        // 10 Hz and an expensive frame at 120 Hz feel identically bad.
        // Text measurement during a gesture is the identified cost (30k CoreText
        // samples), so every gesture reports how many measure passes it caused and
        // what the LAST one says moved. Deltas against the previous gesture's
        // totals, so a busy canvas at rest does not pollute the number.
        let proseMeasures = AssistantProseView.qaMeasurementCount - lastProseMeasureCount
        let markdownMeasures = FileMarkdownDocumentView.qaTotalMeasurePasses
            - lastMarkdownMeasureCount
        lastProseMeasureCount = AssistantProseView.qaMeasurementCount
        lastMarkdownMeasureCount = FileMarkdownDocumentView.qaTotalMeasurePasses
        let line = String(
            format: "gesture: %d steps | camera p50 %.2f / p95 %.2f ms | frame p50 %.2f / p95 %.2f ms "
            + "| gap p50 %.1f / p95 %.1f ms | %d surfaced, %d visible, %d chrome redraws | "
            + "prose measures %d (%@), markdown passes %d (%@)",
            steps.count, p(steps, 0.5), p(steps, 0.95), p(frames, 0.5), p(frames, 0.95),
            p(gaps, 0.5), p(gaps, 0.95), surfacedTiles.count, visibleTileViews.count,
            qaCameraLayoutStats.chromeRepaints,
            proseMeasures, AssistantProseView.qaLastMeasureTrigger,
            markdownMeasures, FileMarkdownDocumentView.qaLastMeasureTrigger
        )
        Logger(subsystem: "continuum.canvas", category: "gesture").notice("\(line, privacy: .public)")
    }

    // MARK: - Surface residency (.plans/36)

    // MARK: - Tile residency (Option A, `.plans/37`)

    /// Injected for QA determinism, exactly like `CanvasCameraDriver.nowProvider`.
    var residencyNowProvider: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// Where the pointer is, in WINDOW coordinates. Injected because
    /// `mouseLocationOutsideOfEventStream` cannot be driven from a check, and the
    /// pointer clause is a rule that has to be witnessed rather than assumed.
    var residencyPointerProvider: (() -> NSPoint?)?

    /// Injectable read of "is this window visible on the active space" for the
    /// occlusion witnesses — real occlusion cannot be simulated headlessly, so
    /// the check drives the real notification -> observer -> state machine path
    /// with only this OS-state read stubbed. Mirrors `residencyPointerProvider`.
    var occlusionVisibilityProvider: (() -> Bool)?

    var qaResidencyTimerRunning: Bool { residencyTimer != nil }

    var residencyTuning = TileResidencyPolicy.Tuning.default

    private var tileLiveness: [UUID: TileResidencyPolicy.Liveness] = [:]
    private var lastResidencyDecisions: [UUID: TileResidencyPolicy.Decision] = [:]
    private var residencyTimer: Timer?

    /// Edge-triggered, so an idle canvas logs nothing and a busy one logs once per
    /// change. This is the only way to see the policy working in a REAL app: the
    /// flag ships off, so there is no UI for it, and every other piece of evidence
    /// so far comes from a fixture. `log stream --predicate 'subsystem ==
    /// "continuum.canvas"'` while dogfooding with `ARRAY_TILE_SURFACE_RESIDENCY=1`.
    /// What the residency log last printed. A tuple rather than the surfaced count
    /// alone, so a pass whose promotions and demotions cancel still prints — the
    /// flicker the log exists to explain was exactly the case it used to skip.
    private struct ResidencySignature: Equatable {
        let surfaced: Int
        let promotions: Int
        let demotions: Int
    }

    private var lastLoggedResidencySignature: ResidencySignature?

    /// Array-owned cost of each camera commit in the current gesture, logged once
    /// when it settles.
    ///
    /// This exists because the fixtures and the app disagreed: `--tile-surface-
    /// residency-check` measures 0.16 ms a step with everything surfaced, and the
    /// real app still felt laggy with 7 of 8 tiles surfaced. A number from the
    /// fixture cannot settle that; a number from the gesture the user actually made
    /// can. If this reports sub-millisecond steps while a gesture feels bad, the cost
    /// is not Array's camera path at all and the search moves to rasterisation and
    /// the compositor — which is what `MATRIX_KNOWN_RED`'s zoom note already
    /// suspects.
    private var gestureStepDurationsMs: [Double] = []

    /// The WHOLE in-process frame, per commit: from `setViewport` to the run loop
    /// going back to sleep, which is after AppKit layout, display, and the Core
    /// Animation commit. `gestureStepDurationsMs` measures only the camera slice,
    /// and a real session proved that number can be 1.4 ms while the gesture feels
    /// unusable — the cost it is blind to is exactly the cost in question.
    private var gestureFrameTailsMs: [Double] = []

    /// Gap between consecutive camera commits — the actual cadence the user's
    /// gesture ran at. A cheap step arriving 10 times a second is still 10 Hz.
    private var gestureCommitGapsMs: [Double] = []
    private var lastViewportCommitAt: TimeInterval?
    private var lastProseMeasureCount = 0
    private var lastMarkdownMeasureCount = 0
    private var pendingFrameStartedAt: TimeInterval?
    private var frameTailObserver: CFRunLoopObserver?

    /// Order 3,000,000: AFTER Core Animation's own commit observer (~2,000,000), so
    /// the tail includes the commit, and after NSWindow's display cycle. Repeats on
    /// every run-loop turn but costs one nil check when no camera commit happened.
    private func installFrameTailObserver() {
        guard frameTailObserver == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 3_000_000
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, let start = self.pendingFrameStartedAt else { return }
                self.pendingFrameStartedAt = nil
                self.gestureFrameTailsMs.append(
                    (ProcessInfo.processInfo.systemUptime - start) * 1_000
                )
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        frameTailObserver = observer
    }

    private func removeFrameTailObserver() {
        guard let observer = frameTailObserver else { return }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        frameTailObserver = nil
    }

    private(set) var qaResidencyEvaluationCount = 0
    private(set) var qaResidencySuppressedDemotionCount = 0
    private(set) var qaSurfaceStalePromotionCount = 0
    private(set) var qaSurfaceEvictionCount = 0
    private(set) var qaSurfaceRefusedMemoryCount = 0
    private(set) var qaSurfaceDegradedBakeCount = 0
    private(set) var qaSurfaceSlimCount = 0

    /// What a surface for this body would cost, before paying for it. Four bytes a
    /// device pixel, which is what `bitmapImageRepForCachingDisplay` produces — and
    /// its rep sizes from the view's EFFECTIVE scale, which for an in-plane body
    /// includes the camera. Estimating without the zoom under-counted a zoomed-in
    /// bake by zoom squared.
    private static func estimatedSurfaceBytes(of body: NSView, scale: CGFloat) -> Int {
        let pixels = body.bounds.width * scale * body.bounds.height * scale
        return Int(max(0, pixels)) * 4
    }

    /// Settable so a witness can drive eviction with a budget it can actually
    /// exceed, instead of building a canvas of hundreds of megabytes to prove it.
    var residencySurfaceByteBudget = TileSurfaceResidencyConfig.maxSurfaceBytes

    func qaLastResidencyDecision(_ tileId: UUID) -> TileResidencyPolicy.Decision? {
        lastResidencyDecisions[tileId]
    }

    /// **One residency pass: who is live, who is quiet, and who therefore changes
    /// state.** This is Option A's whole production entry point.
    ///
    /// Promotions run whether or not the camera is moving — a tile that starts
    /// streaming mid-pan must show live text, and promoting one tile costs ~5 ms
    /// once. **Demotions are suppressed while the camera moves**, because a demote
    /// sweep at gesture time is precisely the 4.6x transition that killed slice 1.
    ///
    /// Nothing here is keyed on the camera otherwise, and nothing walks a tile's
    /// subtree: liveness is a `UInt64` compare, a rect test, and one responder
    /// question per tile.
    func evaluateTileResidency() {
        // A windowless canvas has no pointer, no first responder and no backing scale
        // to bake against, and nothing out there is visible to anyone. `.plans/38`.
        // Occluded is checked HERE, not only where the timer is armed: the guard
        // is what makes a stray fire or a direct call provably inert, and a
        // guard cannot be defeated by a path that forgot to stop the timer.
        guard surfaceResidencyEnabled, window != nil, windowOcclusionVisible else { return }
        qaResidencyEvaluationCount += 1
        // `TileNSView.hitTest` and `promoteForIncomingFocus` promote on their own, to
        // keep a click or a keystroke from reaching a picture. That leaves this set
        // holding tiles that are already native, so reconcile before deciding
        // anything — the same reconcile `enforceSurfaceSharpness` does.
        surfacedTiles = surfacedTiles.filter { $0.value.surfaceResidency == .surfaced }
        let now = residencyNowProvider()
        // **Nothing crosses while the camera moves.** A demotion is a sharp body
        // becoming a picture — as visible as the promotion in the other direction —
        // so under the hold (see `enforceSurfaceSharpness`) both directions are shut
        // for the duration of a gesture and everything reconciles once at settle.
        //
        // This replaces a rate limit of two per pass, whose stated reason was that a
        // gesture beginning all-native stayed all-native to its last frame (a real
        // 96-step zoom ran every step over eight native transcripts at ~3 ms each).
        // That reason is now self-cancelling: the tiles in that story were native
        // "because the previous zoom-in had promoted them", and the hold is precisely
        // what stops a zoom-in promoting anything. What remains native across a
        // gesture is native for a LIVE reason — streaming, focus, a resting pointer —
        // which a demote sweep should never have been touching mid-gesture anyway.
        //
        // The honest cost: a tile that falls quiet mid-gesture now stays native until
        // settle, at ~3 ms per step, bounded by the gesture plus `settleQuiet`
        // (0.25 s). Watched by `checkCost`.
        //
        // Deleted with it: a `zoomingIn` predicate derived from the zoom delta
        // BETWEEN 10 Hz passes (`lastResidencyZoom`), which read false on every
        // zoom-OUT and on any pass that happened to land between camera steps — so
        // the budget it guarded opened exactly when it should not have. Measured in a
        // real session as part of 738 crossings in 2m45s.
        var demotionBudget = cameraDriver.isSettled ? Int.max : 0
        // Spelled out, NOT `residencyPointerProvider?() ?? window?.mouse…`. That
        // collapses a doubly-optional: an installed provider RETURNING nil ("the
        // pointer is nowhere near this canvas") is indistinguishable from no provider
        // at all, so it fell through to the real cursor — which had a check reading
        // Dylan's actual mouse position and promoting whichever tile it happened to
        // sit over.
        let pointer: NSPoint?
        if let residencyPointerProvider {
            pointer = residencyPointerProvider()
        } else {
            pointer = window?.mouseLocationOutsideOfEventStream
        }
        let responder = window?.firstResponder as? NSView
        let zoom = canvasState.viewport.zoom
        let backingScale = window?.backingScaleFactor ?? 2
        var bakeBudget = residencyTuning.maxBakesPerPass
        // The catch-up half of the sharpness cap: tiles a mid-gesture step left
        // deliberately soft (see `enforceSurfaceSharpness`) are promoted here once
        // the camera is settled — capped per pass too, because a storm moved to
        // the settle edge is still a storm. Zero while the camera moves: motion
        // spend is the per-step cap's, and only the per-step cap's.
        var sharpnessCatchUpBudget =
            cameraDriver.isSettled ? residencyTuning.maxSharpnessCatchUpPromotionsPerPass : 0
        // Slims are byte housekeeping, not correctness: two per settled pass keeps
        // the downscale draws (a few ms on a dense image) out of any one frame.
        var slimBudget = 2
        let visibleWorld = worldPlane.bounds
        let catchUpLead = visibleWorld.insetBy(
            dx: -visibleWorld.width * 0.25, dy: -visibleWorld.height * 0.25
        )

        // Visible first, nearest the gesture anchor first among the visible: if
        // any budget runs out it runs out on tiles nobody can see, and what does
        // sharpen radiates outward from where the user is looking.
        var visibleBakeBudget =
            cameraDriver.isSettled ? residencyTuning.maxVisibleSharpenBakesPerSettledPass : 0
        let anchorWorld = worldPlane.convert(cameraDriver.anchor, from: self)
        let visible = Set(visibleTileViews.map { ObjectIdentifier($0) })
        func anchorDistance(_ view: TileNSView) -> CGFloat {
            hypot(view.frame.midX - anchorWorld.x, view.frame.midY - anchorWorld.y)
        }
        let ordered = tileViewsInVisualOrder.sorted { lhs, rhs in
            let lhsVisible = visible.contains(ObjectIdentifier(lhs))
            let rhsVisible = visible.contains(ObjectIdentifier(rhs))
            if lhsVisible != rhsVisible { return lhsVisible }
            guard lhsVisible else { return false }
            return anchorDistance(lhs) < anchorDistance(rhs)
        }
        for tileView in ordered {
            guard tileView.surfaceableBody != nil else { continue }
            let tileId = tileView.tile.id
            var liveness = tileLiveness[tileId] ?? TileResidencyPolicy.Liveness()

            let revision = tileView.surfaceContentRevision
            if liveness.lastContentRevision != revision {
                liveness.lastContentRevision = revision
                liveness.lastContentChangeAt = now
            }
            if let pointer, tileView.bounds.contains(tileView.convert(pointer, from: nil)) {
                if liveness.pointerInsideSince == nil { liveness.pointerInsideSince = now }
                // Rest ACHIEVED is recorded separately from rest in progress: the
                // policy's exit hysteresis lingers on this stamp, and it must
                // never be set by a pointer merely passing through.
                if let since = liveness.pointerInsideSince,
                   now - since >= residencyTuning.pointerRestDelay {
                    liveness.lastPointerRestingAt = now
                }
            } else {
                liveness.pointerInsideSince = nil
            }
            // `containsResponder`, not `isDescendant`: a surfaced tile's body is in
            // the park and is no longer part of the tile's subtree, so the plain
            // test would report "not focused" for the tile being typed into.
            liveness.hasFocus = responder.map { tileView.containsResponder($0) } ?? false
            liveness.isAnimating = tileView.surfaceIsAnimating
            let accessibilityCount = tileView.accessibilityAccessCount
            if liveness.lastAccessibilityCount != accessibilityCount {
                liveness.lastAccessibilityCount = accessibilityCount
                // A passive sweeper's reads are counted but are not liveness;
                // stamping them would make the policy finish what
                // `accessibilityChildren` correctly refused to start.
                if TileNSView.assistiveClientActive() {
                    liveness.lastAccessibilityAccessAt = now
                }
            }
            tileLiveness[tileId] = liveness

            let decision = TileResidencyPolicy.decide(
                now: now, liveness: liveness, tuning: residencyTuning
            )
            lastResidencyDecisions[tileId] = decision
            switch decision {
            case .native:
                guard tileView.surfaceResidency == .surfaced else { continue }
                tileView.promoteBodyToNative()
                surfacedTiles.removeValue(forKey: tileId)
                qaSurfacePromotionCount += 1
            case .surfaced:
                if tileView.surfaceResidency == .surfaced {
                    // **A surfaced tile whose surface went stale WITHOUT the tile
                    // becoming live.** The appearance changing is the case that
                    // matters: `TileSurfaceRevision` carries `appearanceName`, and
                    // switching to dark mode ingests nothing, animates nothing and
                    // touches no content — so every clause of the rule still says
                    // "quiet" while every surface on the canvas is now a picture of
                    // the light-mode tile. Give the body back; the next quiet pass
                    // re-bakes it, while native, which is the only faithful state.
                    if let wanted = tileView.currentSurfaceRevision,
                       tileSurfaceStore.surface(for: tileId)?.revision != wanted {
                        // Which field went stale, because "everything re-baked" has
                        // three very different causes and only one of them is normal.
                        // A canvas that re-bakes every second is a churn bug, and
                        // this is what names it without a rebuild.
                        if let held = tileSurfaceStore.surface(for: tileId)?.revision {
                            var reasons: [String] = []
                            if held.contentVersion != wanted.contentVersion { reasons.append("content") }
                            if held.bodySize != wanted.bodySize {
                                reasons.append("size \(held.bodySize) -> \(wanted.bodySize)")
                            }
                            if held.appearanceName != wanted.appearanceName { reasons.append("appearance") }
                            let why = reasons.joined(separator: ", ")
                            Logger(subsystem: "continuum.canvas", category: "residency")
                                .debug("surface went stale: \(why, privacy: .public)")
                        }
                        tileView.promoteBodyToNative()
                        surfacedTiles.removeValue(forKey: tileId)
                        // Drop it: this surface is stale by definition and will be
                        // re-baked before it is ever shown again, so keeping it is
                        // pure resident memory — 1.8 MB for a 420x300 body and
                        // 10.4 MB for a 760x900 one.
                        tileSurfaceStore.drop(tileId)
                        qaSurfacePromotionCount += 1
                        qaSurfaceStalePromotionCount += 1
                    }
                    // A quiet tile still surfaced TOO SOFT: the per-step cap
                    // deferred it mid-gesture, and softness at rest is plainly
                    // visible, so it is caught up here. Promote only — a bake
                    // needs the native body (a parked body's pixels are not
                    // faithful), so the NEXT pass's too-soft re-bake in
                    // `surfaceIfAdmissible` is what returns it, sharp at the
                    // current zoom. The surface is kept: its revision still
                    // matches, and dropping it is what the stale path is for.
                    if tileView.surfaceResidency == .surfaced,
                       sharpnessCatchUpBudget > 0,
                       tileView.frame.intersects(catchUpLead),
                       let surface = tileSurfaceStore.surface(for: tileId),
                       case let catchUpNeed = requiredSurfaceScale(
                           for: tileView, zoom: zoom, backingScale: backingScale, inLead: true),
                       !surface.isSharpEnough(forScale: catchUpNeed),
                       // A deliberately-degraded surface stays: promoting it for a
                       // softness the budget cannot afford to fix just strands it
                       // native (or flaps it), which is strictly worse than soft.
                       bakeWouldFit(tileView, tileId: tileId, at: catchUpNeed) {
                        tileView.promoteBodyToNative()
                        surfacedTiles.removeValue(forKey: tileId)
                        qaSurfacePromotionCount += 1
                        sharpnessCatchUpBudget -= 1
                    }
                    // A surface denser than its tile's CURRENT requirement is
                    // pure byte waste: it was baked for a zoom the tile is no
                    // longer seen at, and one deep zoom-in left enough of them to
                    // pin the whole budget after the zoom back out (measured live
                    // 2026-08-19: 261 MB held, refusedMemory in the thousands,
                    // every refused tile stranded native — and the stranded
                    // natives were the lag). Slim it IN PLACE — same picture,
                    // fewer bytes, no promote, no flip, no body needed because
                    // the dense image is already held. In-lead tiles too: after a
                    // zoom-out everything is in the lead and over-sharp, and both
                    // the dense image and its slim are downsampled to the same
                    // displayed size, so the swap is not visible.
                    if cameraDriver.isSettled, slimBudget > 0,
                       tileView.surfaceResidency == .surfaced,
                       let surface = tileSurfaceStore.surface(for: tileId) {
                        let wantedScale = requiredSurfaceScale(
                            for: tileView, zoom: zoom, backingScale: backingScale,
                            inLead: tileView.frame.intersects(catchUpLead))
                        if surface.bakedScale > wantedScale * 1.26,
                           let slimmed = tileSurfaceStore.slim(tileId: tileId, to: wantedScale) {
                            tileView.adoptSlimmedSurface(slimmed, backingScale: backingScale)
                            qaSurfaceSlimCount += 1
                            slimBudget -= 1
                        }
                    }
                    continue
                }
                guard demotionBudget > 0 else {
                    qaResidencySuppressedDemotionCount += 1
                    continue
                }
                // Density follows visibility: full zoom density inside the lead
                // rect, capped at rest density outside it. The lead-rect catch-up
                // above is the upgrade path — a capped tile entering the lead is
                // promoted, and this re-bakes it at the full requirement.
                let requiredScale = requiredSurfaceScale(
                    for: tileView, zoom: zoom, backingScale: backingScale,
                    inLead: tileView.frame.intersects(catchUpLead))
                // A visible tile mid-sharpen draws from its own, larger budget:
                // it is a pop the user is waiting on, not background housekeeping.
                let surfacedNow: Bool
                if visibleBakeBudget > 0, visible.contains(ObjectIdentifier(tileView)) {
                    surfacedNow = surfaceIfAdmissible(
                        tileView, bakeBudget: &visibleBakeBudget,
                        requiredScale: requiredScale, backingScale: backingScale
                    )
                } else {
                    surfacedNow = surfaceIfAdmissible(
                        tileView, bakeBudget: &bakeBudget,
                        requiredScale: requiredScale, backingScale: backingScale
                    )
                }
                if surfacedNow {
                    demotionBudget -= 1
                }
            }
        }
        enforceSurfaceMemoryBudget()
        logResidencyIfChanged()
    }

    /// The safety net under the budget: give the FARTHEST tiles their real bodies
    /// back when bytes are over the cap despite the pre-bake refusal — a body that
    /// grew, or a budget that shrank.
    ///
    /// Evicting a surfaced tile means promoting it: a tile's host holds the same
    /// `CGImage` the store does, so dropping the store entry alone frees nothing.
    /// Farthest-first because the near ones are what the camera is actually moving,
    /// and a promoted tile costs ~2.9 ms per camera step — real, but bounded, and
    /// invisible.
    private func enforceSurfaceMemoryBudget() {
        let budget = residencySurfaceByteBudget
        guard tileSurfaceStore.totalBytes > budget, !surfacedTiles.isEmpty else { return }
        let centre = CGPoint(x: worldPlane.bounds.midX, y: worldPlane.bounds.midY)
        let ordered = surfacedTiles.sorted { lhs, rhs in
            func distance(_ view: TileNSView) -> CGFloat {
                let mid = CGPoint(x: view.frame.midX, y: view.frame.midY)
                return hypot(mid.x - centre.x, mid.y - centre.y)
            }
            return distance(lhs.value) > distance(rhs.value)
        }
        for (tileId, tileView) in ordered {
            guard tileSurfaceStore.totalBytes > budget else { break }
            tileView.promoteBodyToNative()
            surfacedTiles.removeValue(forKey: tileId)
            tileView.discardRetainedSurfaceHost()
            tileSurfaceStore.drop(tileId)
            qaSurfacePromotionCount += 1
            qaSurfaceEvictionCount += 1
        }
    }

    private func logResidencyIfChanged() {
        let surfaced = surfacedTiles.count
        // **Every crossing, not every count change.** This used to return unless the
        // surfaced COUNT moved, so a pass that promoted one tile and demoted another
        // logged NOTHING — which is why a real session's "738 crossings" was a floor
        // read across lines that silently skipped, and why the flicker was invisible
        // in the very log built to explain it. The signature includes both crossing
        // counters, so a net-zero pass still prints.
        let signature = ResidencySignature(
            surfaced: surfaced,
            promotions: qaSurfacePromotionCount,
            demotions: qaSurfaceDemotionCount
        )
        guard signature != lastLoggedResidencySignature else { return }
        lastLoggedResidencySignature = signature
        let eligibleViews = tileViewsInVisualOrder.filter { $0.surfaceableBody != nil }
        // WHY the count moved, not just that it did. A resting canvas that flaps
        // 82<->83 has several possible promoters — a liveness clause, a hitTest
        // (AppKit hit-tests for scroll routing, tooltips and cursor updates,
        // background windows included), or an AX client polling the tree — and the
        // bare count cannot name one. "outOfBand" is a native tile whose last
        // DECISION was still .surfaced: a hitTest/AX/focus promotion the policy
        // pass has not caught up with yet. The trigger counters are cumulative;
        // read deltas between consecutive lines.
        var reasons: [String: Int] = [:]
        for view in eligibleViews where view.surfaceResidency != .surfaced {
            switch lastResidencyDecisions[view.tile.id] {
            case .native(let reason): reasons[reason.rawValue, default: 0] += 1
            case .surfaced, nil: reasons["outOfBand", default: 0] += 1
            }
        }
        let hitTestPromotes = eligibleViews.reduce(UInt64(0)) { $0 + $1.qaHitTestPromotionCount }
        let axReads = eligibleViews.reduce(UInt64(0)) { $0 + $1.accessibilityAccessCount }
        let native = reasons
            .sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }
            .joined(separator: ", ")
        // Composed as a String first: `OSLogMessage` is built from one interpolated
        // literal and cannot be concatenated.
        let line = "surfaced \(surfaced) of \(eligibleViews.count) eligible tiles, "
            + "\(tileSurfaceStore.totalBytes / 1_024) KB of surfaces"
            + " | native by: [\(native)]"
            + " | promotions \(qaSurfacePromotionCount) demotions \(qaSurfaceDemotionCount)"
            + " | hitTest promotes \(hitTestPromotes), ax reads \(axReads)"
            + " | refused: blank \(qaSurfaceRefusedBlankCount)"
            + " (uniform bakes \(tileSurfaceStore.qaUniformBakeCount)),"
            + " occluded \(qaSurfaceRefusedOccludedCount)"
            // Attribution, so a crossing count can be DECOMPOSED rather than
            // guessed at. Sharpness promotions and stale promotions are different
            // problems with different fixes, and a bare promotion count cannot tell
            // them apart — which left 485 demotions against 253 promotions
            // unexplained in the session that prompted the hold.
            + " | why: stale \(qaSurfaceStalePromotionCount),"
            + " softDeferred \(qaSurfaceSharpnessDeferredCount),"
            + " suppressedDemotes \(qaResidencySuppressedDemotionCount),"
            + " evictions \(qaSurfaceEvictionCount),"
            + " refusedMemory \(qaSurfaceRefusedMemoryCount),"
            + " degraded \(qaSurfaceDegradedBakeCount), slims \(qaSurfaceSlimCount),"
            + " refusedBudget \(qaSurfaceRefusedBudgetCount)"
            + " | camera \(cameraDriver.isSettled ? "settled" : "moving")"
        Logger(subsystem: "continuum.canvas", category: "residency").notice("\(line, privacy: .public)")
    }

    /// Give one quiet tile a surface, or leave it native.
    ///
    /// The refusal paths are the design, not error handling. A tile stays native
    /// when its bake fails, when the resulting surface is less sharp than the screen
    /// needs, or when this pass's bake budget is spent — and a native tile is simply
    /// a tile that costs what it costs today. There is no state in which a user sees
    /// the wrong pixels; only states in which the canvas is less cheap than it could
    /// be.
    ///
    /// **The bake happens here, while the body is still native, and that is
    /// load-bearing.** `.plans/37` Step 0 measured what a bake of a PARKED body
    /// produces: pixels that differ from the real body by 3.28 to 7.41 mean channel
    /// difference, and that never change again no matter what streams in, because
    /// the transcript's `visibleRect` degenerates once no ancestor places it in the
    /// visible area. Native is the only faithful state to bake from.
    @discardableResult
    /// The ONE place a tile's wanted surface density is decided, used by the
    /// bake, the admission gate, the sharpness catch-up, and the per-step
    /// sharpness sweep — if any of those computed it separately, a tile could be
    /// refused for a softness no bake is allowed to fix, and it would flap
    /// forever between native and surfaced.
    ///
    /// Full zoom density in the lead, `offscreenBakeZoomCap` outside it, and
    /// never more than `maxBytesPerBakedSurface` can hold for THIS body — but
    /// never less than rest density, which is always allowed.
    /// Would a bake of `tileView`'s body at `scale` fit the byte budget? The
    /// bake REPLACES the tile's existing surface, so those bytes are credited
    /// back — without that, a tile's own picture blocks its own re-bake (found
    /// by the degrade witness: refusedMemory with more headroom than the ask).
    private func bakeWouldFit(_ tileView: TileNSView, tileId: UUID, at scale: CGFloat) -> Bool {
        guard let body = tileView.surfaceableBody else { return false }
        let existing = tileSurfaceStore.surface(for: tileId)?.byteCount ?? 0
        return tileSurfaceStore.totalBytes - existing
            + Self.estimatedSurfaceBytes(of: body, scale: scale)
            <= residencySurfaceByteBudget
    }

    private func requiredSurfaceScale(
        for tileView: TileNSView, zoom: Double, backingScale: CGFloat, inLead: Bool
    ) -> CGFloat {
        let full = CGFloat(max(0.0001, zoom)) * backingScale
        var required = inLead
            ? full
            : min(full, CGFloat(residencyTuning.offscreenBakeZoomCap) * backingScale)
        if let body = tileView.surfaceableBody {
            let area = body.bounds.width * body.bounds.height
            if area > 0 {
                let capScale = (CGFloat(residencyTuning.maxBytesPerBakedSurface) / (4 * area))
                    .squareRoot()
                required = min(required, max(capScale, backingScale))
            }
        }
        return required
    }

    private func surfaceIfAdmissible(
        _ tileView: TileNSView, bakeBudget: inout Int, requiredScale: CGFloat, backingScale: CGFloat
    ) -> Bool {
        guard let body = tileView.surfaceableBody,
              let wanted = tileView.currentSurfaceRevision else { return false }
        let tileId = tileView.tile.id
        var surface = tileSurfaceStore.surface(for: tileId)
        // A fresh surface that is TOO SOFT for the current zoom is as unusable as a
        // stale one, and it has to trigger a re-bake the same way. Without this, one
        // zoom-in turned residency off permanently: sharpness promoted every tile,
        // and every later pass found a matching revision, skipped the bake, failed
        // the sharpness gate, and left the tile native — measured in a real session
        // as 0 of 8 surfaced for 36 seconds until the user happened to zoom back out.
        let tooSoft = surface.map { !$0.isSharpEnough(forScale: requiredScale) } ?? false
        // **A scroll is not a content change, and it moves the picture anyway.**
        // The revision cannot see it (scrolling bumps no version), so a surface
        // baked before the user scrolled matched the freshness test afterwards and
        // was handed straight back — a faithful picture of where the body used to be
        // looking, which is the largest jump this design can produce. Compared HERE
        // and nowhere else, because this function only ever runs on a native tile:
        // its body is in the world plane, so its scroll position is real. A parked
        // body's is not, and comparing that one thrashes every tile.
        let scrollMoved = surface.map { $0.bakedScrollOffsets != tileView.surfaceScrollOffsets } ?? false
        // What this pass actually asked the bake for; degraded below under budget
        // pressure, and the admission gate at the bottom judges against it.
        var admittedScale = requiredScale
        if surface?.revision != wanted || tooSoft || scrollMoved {
            // **Refuse BEFORE baking, not after.** Evicting after the fact thrashes:
            // the pass bakes eight surfaces, the budget evicts the farthest four, and
            // 100 ms later the same four are still quiet and get baked again —
            // forever, at ~2 ms a bake and ~5 ms a reparent. Prevention costs one
            // multiplication.
            // Under budget pressure, degrade the ASK before refusing residency:
            // a refused tile stays native, and stranded natives are what the lag
            // is made of (~4.5 ms per native tile per camera step — 20 of them
            // was a 90 ms frame, measured live 2026-08-19). A rest-density bake
            // is a fraction of the bytes and visibly soft only until the slim
            // pass frees room; native is the strictly worse state on both axes.
            if !bakeWouldFit(tileView, tileId: tileId, at: admittedScale),
               backingScale < requiredScale {
                admittedScale = backingScale
                if bakeWouldFit(tileView, tileId: tileId, at: admittedScale) {
                    qaSurfaceDegradedBakeCount += 1
                }
            }
            guard bakeWouldFit(tileView, tileId: tileId, at: admittedScale) else {
                qaSurfaceRefusedMemoryCount += 1
                return false
            }
            // Budget, not staleness: the tile IS stale, but what refused it is the
            // cap. Counting both would make the two reasons add up to more refusals
            // than there were tiles.
            guard bakeBudget > 0 else {
                qaSurfaceRefusedBudgetCount += 1
                return false
            }
            // **Never bake a window the system is not showing.** The cached
            // occlusion flag is notification-driven, so between the window
            // actually going away and the notification arriving there is a window
            // in which a pass can still run — and a body in a window with no
            // valid backing store bakes to nothing. Reported from the real canvas
            // after clicking in and out repeatedly: tiles left showing chrome
            // over an empty body, one blank surface per bake in that gap,
            // persisting because the revision still matched. Read the state
            // authoritatively here; `== false` on purpose, so an unknown state
            // (no window, a fixture that cannot answer) still bakes.
            if resolvedWindowVisibility() == false {
                qaSurfaceRefusedOccludedCount += 1
                return false
            }
            bakeBudget -= 1
            surface = tileSurfaceStore.bake(
                tileId: tileId, body: body, revision: wanted,
                scrollOffsets: tileView.surfaceScrollOffsets, maxScale: admittedScale
            )
            guard let baked = surface else {
                qaSurfaceRefusedStaleCount += 1
                return false
            }
            // **A picture of nothing is the wrong pixels.** Reported from the real
            // canvas: tiles showing chrome over an empty body while the log said
            // every tile was surfaced. Whatever leaves a content-bearing body
            // unable to draw itself at bake time, showing that bake breaks the
            // design's one promise, so the surface is dropped and the tile stays
            // native — which costs what a native tile costs today, and no more.
            if baked.isUniform, tileView.surfaceBakeExpectsContent {
                tileSurfaceStore.drop(tileId)
                qaSurfaceRefusedBlankCount += 1
                return false
            }
        }
        guard let admissible = surface else { return false }
        // Judged against what was ADMITTED, not what was wanted: a bake this
        // function just degraded under budget pressure is deliberately soft, and
        // refusing it here would re-strand the tile the degradation exists to save.
        guard admissible.isSharpEnough(forScale: min(requiredScale, admittedScale)) else {
            qaSurfaceRefusedSharpnessCount += 1
            return false
        }
        if tileView.demoteBodyToSurface(admissible, park: surfaceParkView, backingScale: backingScale) {
            surfacedTiles[tileId] = tileView
            qaSurfaceDemotionCount += 1
            return true
        }
        return false
    }

    /// The 10 Hz heartbeat behind `evaluateTileResidency`. Everything else that
    /// changes liveness — a keystroke, a streamed token, the pointer moving — does
    /// so without telling this view, and a hook per source would need
    /// `tileView.canvas` to be set on every install path, which `_installLayer`
    /// does not do.
    private func startResidencyEvaluation() {
        guard surfaceResidencyEnabled, residencyTimer == nil, window != nil,
              windowOcclusionVisible else { return }
        let timer = Timer(
            timeInterval: residencyTuning.evaluationInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluateTileResidency() }
        }
        RunLoop.main.add(timer, forMode: .common)
        residencyTimer = timer
    }

    private func stopResidencyEvaluation() {
        residencyTimer?.invalidate()
        residencyTimer = nil
    }

    /// **The canvas sleeps while its window cannot be seen.**
    ///
    /// `NSWindow.occlusionState` contains `.visible` only when the window is at
    /// least partially unoccluded ON THE ACTIVE SPACE, so one notification
    /// covers being covered, being hidden, being miniaturized, and sitting on
    /// another space — which is why there is no separate space observer.
    ///
    /// Asleep means: no heartbeat (it polled the window server for the mouse ten
    /// times a second and could bake four bodies a pass), no overlay animation,
    /// and every tile family with its own render loop told to pause. Residency
    /// state is deliberately UNTOUCHED — waking must not storm — so waking is
    /// one immediate catch-up pass and then the ordinary cadence.
    @objc private func windowOcclusionDidChange(_ notification: Notification) {
        noteWindowOcclusionChanged(visible: resolvedWindowVisibility() ?? true)
    }

    private func noteWindowOcclusionChanged(visible: Bool) {
        guard visible != windowOcclusionVisible else { return }
        windowOcclusionVisible = visible
        applyOverlayAnimationSuspension()
        for tileView in tileViewsInVisualOrder {
            tileView.windowOcclusionChanged(visible: visible)
        }
        if visible {
            startResidencyEvaluation()
            // NO immediate bake here, deliberately. A window that has just come
            // back has not necessarily redrawn itself yet, and a bake taken in
            // that instant captures nothing — which is the blank-tile report. The
            // ordinary tick is at most 100 ms away and a tile surfaced 100 ms
            // late is invisible; ask for a redraw and let it happen.
            needsDisplay = true
            for tileView in tileViewsInVisualOrder { tileView.needsDisplay = true }
        } else {
            stopResidencyEvaluation()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The occlusion observer is per-WINDOW, so it is re-registered on every
        // move: a canvas that changed windows would otherwise be listening to a
        // window it no longer lives in.
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didChangeOcclusionStateNotification, object: nil
        )
        if window == nil {
            removeFrameTailObserver()
            stopResidencyEvaluation()
            // Nothing evaluates residency for a canvas that is not in a window, so
            // no body may be left parked there. Same invariant
            // `releaseSurfaceResidency` keeps per tile, at canvas scale.
            promoteAllSurfacedTiles()
        } else {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowOcclusionDidChange(_:)),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window
            )
            installFrameTailObserver()
            startResidencyEvaluation()
        }
    }

    /// Leave motion: every tile gets its real body back, unconditionally.
    ///
    /// This is what keeps the app at rest identical to the app today — cursor
    /// rects, selection, IME, tooltips, the accessibility tree and every consumer
    /// that walks the view hierarchy see exactly what they always have, because at
    /// rest nothing is surfaced.
    func promoteAllSurfacedTiles() {
        // Both populations, because a tile view can leave the world plane while
        // still surfaced (`setZones`, `removeTile`) and only the maintained set
        // would still know about it.
        for tileView in tileViewsInVisualOrder where tileView.surfaceResidency == .surfaced {
            tileView.promoteBodyToNative()
            qaSurfacePromotionCount += 1
        }
        for (_, tileView) in surfacedTiles where tileView.surfaceResidency == .surfaced {
            tileView.promoteBodyToNative()
            qaSurfacePromotionCount += 1
        }
        surfacedTiles.removeAll()
    }

    /// Per camera step: surfaced tiles whose surfaces have become softer than the
    /// screen needs go back to their real bodies — capped per step, nearest the
    /// gesture anchor first.
    ///
    /// Promoting every too-soft tile in the same step that made it so was the
    /// zoom-in STORM: a real 89-tile session paid 19 promotions in one step and a
    /// 1.65 s frame gap, because each promotion is a reparent plus the transcript
    /// rows it materialises. The guarantee is now convergence, not instantaneous
    /// sharpness: each step spends `maxSharpnessPromotionsPerStep` on the tiles
    /// nearest the gesture's anchor (on-screen before lead-rect), the rest stay
    /// briefly soft and are counted, and the settled heartbeat catches them up.
    /// Brief peripheral softness on moving content was chosen over the
    /// whole-canvas hitch (2026-08-19, `.plans/38`).
    private func enforceSurfaceSharpness() {
        guard surfaceResidencyEnabled, !surfacedTiles.isEmpty else { return }
        // **The hold (Dylan's ruling, 2026-08-19).** While the camera is in flight,
        // nothing crosses: tiles may go progressively soft, and they converge ONCE at
        // the settle edge, which `cameraGestureDidSettle` already drives.
        //
        // The per-step cap below was already a concession that instantaneous
        // sharpness is not worth a hitch — one promotion per step, nearest the anchor,
        // periphery briefly soft. A real session showed the remaining per-step spend
        // is itself the artifact: one promotion per camera step is one visible
        // blur->sharp flip per step, and a 12-tile fixture zooming 1.0 -> 2.0 in eight
        // steps crossed eight times. He reported it as "SOOO much flickering".
        //
        // This reverses `.plans/36`, which added per-step enforcement because "a tile
        // admitted as sharp-enough at zoom 1.0 was still surfaced two steps into a
        // zoom to 2.0, showing exactly the soft text this design promises never to
        // show". That promise is the one being traded away, deliberately and for the
        // second time: chop over softness.
        //
        // The guard sits AFTER the soft set is collected, not here: returning early
        // would also stop counting `qaSurfaceSharpnessDeferredCount`, and a hold that
        // silences its own instrument is how "briefly soft" becomes "soft forever"
        // with every gate green.
        // `TileNSView.hitTest` can promote a tile on its own, to keep a click from
        // being swallowed. That leaves this set holding a tile that is already
        // native, so reconcile before deciding anything.
        surfacedTiles = surfacedTiles.filter { $0.value.surfaceResidency == .surfaced }
        let zoom = canvasState.viewport.zoom
        let backingScale = window?.backingScaleFactor ?? 2
        // Softness only matters where it can be seen, and zooming in shrinks the
        // visible set — which is what makes this affordable. The rect is inflated by
        // a quarter of the viewport so a tile is promoted just BEFORE it arrives on
        // screen: checking the exact viewport would leave a one-frame window in which
        // a tile entering the screen is visibly soft.
        let visibleWorld = worldPlane.bounds
        let lead = visibleWorld.insetBy(dx: -visibleWorld.width * 0.25, dy: -visibleWorld.height * 0.25)
        var soft: [(view: TileNSView, visible: Bool, distance: CGFloat)] = []
        let anchorWorld = worldPlane.convert(cameraDriver.anchor, from: self)
        for (tileId, tileView) in surfacedTiles {
            guard tileView.frame.intersects(lead) else { continue }
            guard let surface = tileSurfaceStore.surface(for: tileId) else {
                // A missing surface is not a state this can be in, but if it ever
                // is, native is the answer — immediately and outside the cap,
                // because that tile is showing nothing at all, not soft text.
                tileView.promoteBodyToNative()
                surfacedTiles.removeValue(forKey: tileId)
                qaSurfacePromotionCount += 1
                continue
            }
            let sweepNeed = requiredSurfaceScale(
                for: tileView, zoom: zoom, backingScale: backingScale, inLead: true)
            if surface.isSharpEnough(forScale: sweepNeed) { continue }
            // Soft the budget cannot fix is the deliberate state, not a defect —
            // promoting it strands the tile native (the lag), fixes nothing.
            if !bakeWouldFit(tileView, tileId: tileId, at: sweepNeed) { continue }
            let mid = CGPoint(x: tileView.frame.midX, y: tileView.frame.midY)
            soft.append((
                view: tileView,
                visible: tileView.frame.intersects(visibleWorld),
                distance: hypot(mid.x - anchorWorld.x, mid.y - anchorWorld.y)
            ))
        }
        guard !soft.isEmpty else { return }
        // The hold: while the camera is in flight nothing crosses. The soft tiles are
        // COUNTED so the softness is observable, then left alone until settle.
        if !cameraDriver.isSettled {
            qaSurfaceSharpnessDeferredCount += soft.count
            return
        }
        // A settled one-shot writer (a navigation snap, a restore) has no later
        // steps to spread the work across, and a hitch with no motion behind it is
        // invisible — so only an in-flight gesture is capped.
        let cap = cameraDriver.isSettled ? Int.max : residencyTuning.maxSharpnessPromotionsPerStep
        soft.sort { lhs, rhs in
            if lhs.visible != rhs.visible { return lhs.visible }
            return lhs.distance < rhs.distance
        }
        for (index, entry) in soft.enumerated() {
            guard index < cap else {
                qaSurfaceSharpnessDeferredCount += soft.count - index
                break
            }
            entry.view.promoteBodyToNative()
            surfacedTiles.removeValue(forKey: entry.view.tile.id)
            qaSurfacePromotionCount += 1
            qaSurfaceRefusedSharpnessCount += 1
        }
    }

    /// Give a tile its real body back and forget its surface, before the tile view
    /// leaves this canvas. Without this a departing surfaced tile strands its body
    /// in the park, where nothing owns it and nothing will ever remove it.
    private func releaseSurfaceResidency(of tileView: TileNSView) {
        if tileView.surfaceResidency == .surfaced {
            tileView.promoteBodyToNative()
            qaSurfacePromotionCount += 1
        }
        surfacedTiles.removeValue(forKey: tileView.tile.id)
        tileLiveness.removeValue(forKey: tileView.tile.id)
        lastResidencyDecisions.removeValue(forKey: tileView.tile.id)
        tileView.discardRetainedSurfaceHost()
        tileSurfaceStore.drop(tileView.tile.id)
    }

    /// Re-aim the overlays that live in SCREEN space but track a world tile —
    /// the focus border and the attention borders. They are deliberately not in
    /// the world plane: their stroke widths and corner radii are screen-space
    /// affordances that must not shrink with zoom.
    private func repositionTrackingOverlaysForCamera() {
        if let tileId = borderedTileId { repositionFocusBorderIfNeeded(for: tileId) }
        for tileId in attentionTileIds { repositionAttentionBorderIfNeeded(for: tileId) }
    }

    /// A tile view's rect in CANVAS (screen) coordinates.
    ///
    /// Screen-fixed overlays live outside the world plane, so they cannot be
    /// positioned from `tileView.frame` any more: that frame is now a WORLD rect
    /// inside the plane. Converting through the view tree is both correct and
    /// plane-agnostic — it produced the same answer before the plane existed.
    private func tileRectInCanvasSpace(_ view: TileNSView) -> CGRect {
        view.convert(view.bounds, to: self)
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
        for zone in liveZones {
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
        // P1.11: an editable field floating over the zone chrome is an `overlay`
        // surface carrying `textPrimary`, which is a documented pair. The old
        // white@0.95 on black@0.6 was a composite over whatever the zone's accent
        // wash happened to be — unpredictable, and white-on-light under Aqua.
        field.textColor = TextToken.textPrimary.color.nsColor(in: self)
        field.backgroundColor = SurfaceToken.overlay.color.nsColor(in: self)
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
        let placement = liveZones[idx]
        if let layer = zoneLayers.first(where: { $0.placement.zoneId == zoneId }) {
            layer.placement = placement
            layer.renderModel.placement = placement
            layer.renderModel.displayName = trimmed
        }
        if let modelIndex = zoneRenderModels.firstIndex(where: { $0.placement.zoneId == zoneId }) {
            zoneRenderModels[modelIndex].placement = placement
            zoneRenderModels[modelIndex].displayName = trimmed
        }
        if var model = zoneDisplayByZoneId[zoneId] {
            model.placement = placement
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

    private func zoneOverflowButtonZoneId(at screenPoint: CGPoint) -> UUID? {
        liveZones.reversed().first { placement in
            guard let close = zoneCloseButtonScreenRect(for: placement) else { return false }
            let overflow = CGRect(x: close.minX - 26, y: close.minY, width: 24, height: close.height)
            return overflow.contains(screenPoint)
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

    func updateZoneRenderModels(_ models: [ZoneRenderModel]) {
        zoneRenderModels = models
        zoneDisplayByZoneId = Dictionary(models.map { ($0.placement.zoneId, $0) }, uniquingKeysWith: { first, _ in first })
        for model in models {
            zoneChromeViews[model.placement.zoneId]?.update(model: model)
        }
        layoutZoneChromeViews()
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
        for tile in flatCompatibilitySceneActive ? canvasState.tiles : [] {
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

    /// The reveal/work camera for a tile, computed from the SAME navigation
    /// snapshot labels and hit-testing use, so canvas tiles and `ZoneLayer`
    /// tiles are both framed in true world coordinates.
    func framedViewportForTileJump(_ tileId: UUID) -> CanvasViewport? {
        guard let snapshot = navigationTileSnapshot(for: tileId) else { return nil }
        let frame = snapshot.worldFrame
        let rect = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        return CameraFraming.revealWorkViewport(for: rect, kind: snapshot.kind, currentViewport: canvasState.viewport, viewportSize: bounds.size)
    }

    /// Frames the tile as a readable jump target. This first T07 slice snaps to
    /// the computed camera target; animation remains out of scope until a
    /// transition coordinator/recorder is added.
    ///
    /// The NON-keyboard reveals come through here — inbox Space preview,
    /// `TileSpawner.revealTile`, and (via `jumpToTileFromPalette`) a sidebar tile
    /// click. All three deliberately use the same reveal/work framing as a ⌘K
    /// tile jump: each one exists to put a tile in front of the user to READ or
    /// USE, which is what that policy produces, and two of them take the tile's
    /// input scope as well. The policy's "never zoom out" rule is what makes that
    /// safe from a closer camera; the Space-preview case is witnessed in
    /// `--agent-inbox-check`.
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
        qaDocumentRelationshipStats.stackingReconciliations += 1

        // A strict total order for every world-plane child. Sorting in place is
        // important: remove/re-add churn loses responder/hover state and used to
        // put the relationship overlay back underneath zone chrome.
        let originals = Dictionary(uniqueKeysWithValues:
            worldPlane.subviews.enumerated().map { (ObjectIdentifier($0.element), $0.offset) })
        var keys: [ObjectIdentifier: CanvasWorldPlaneSubviewSortKey] = [:]

        var backgroundViews: [(zoneId: UUID, view: ZoneChromeNSView)] =
            zoneChromeViews.map { (zoneId: $0.key, view: $0.value) }
        let backgroundOrder = backgroundViews.sorted { lhs, rhs in
            let lhsPosition = liveZones.first(where: { $0.zoneId == lhs.zoneId })?.zPosition
                ?? zoneLayers.first(where: { $0.placement.zoneId == lhs.zoneId })?.placement.zPosition
                ?? .first
            let rhsPosition = liveZones.first(where: { $0.zoneId == rhs.zoneId })?.zPosition
                ?? zoneLayers.first(where: { $0.placement.zoneId == rhs.zoneId })?.placement.zPosition
                ?? .first
            if lhsPosition != rhsPosition { return lhsPosition < rhsPosition }
            return lhs.zoneId.uuidString < rhs.zoneId.uuidString
        }
        for (rank, entry) in backgroundOrder.enumerated() {
            let id = ObjectIdentifier(entry.view)
            keys[id] = .init(tier: 0, rank: rank, originalIndex: originals[id] ?? rank)
        }

        keys[ObjectIdentifier(documentRelationshipOverlay)] = .init(
            tier: 1, rank: 0, originalIndex: originals[ObjectIdentifier(documentRelationshipOverlay)] ?? 0)
        if let agentLineageOverlay {
            keys[ObjectIdentifier(agentLineageOverlay)] = .init(
                tier: 1, rank: 1, originalIndex: originals[ObjectIdentifier(agentLineageOverlay)] ?? 1)
        }

        var tileEntries: [(view: TileNSView, zoneRank: Int, z: Double, id: String)] = []
        tileEntries += tileViews.values.map { ($0, 0, $0.tile.zPosition.value, $0.tile.id.uuidString) }
        for layer in zoneLayers {
            let zoneRank = (zoneLayerOrder.firstIndex(of: layer.placement.zoneId) ?? 0) + 1
            tileEntries += layer.tileViews.values.map { ($0, zoneRank, $0.tile.zPosition.value, $0.tile.id.uuidString) }
        }
        tileEntries.sort {
            if $0.zoneRank != $1.zoneRank { return $0.zoneRank < $1.zoneRank }
            if $0.z != $1.z { return $0.z < $1.z }
            return $0.id < $1.id
        }
        for (rank, entry) in tileEntries.enumerated() {
            let id = ObjectIdentifier(entry.view)
            keys[id] = .init(tier: 2, rank: rank, originalIndex: originals[id] ?? rank)
        }

        // Unknown world-plane children retain a deterministic position after the
        // known tiers. There should be none in production, but this prevents an
        // extension view from making the comparator non-total.
        for view in worldPlane.subviews where keys[ObjectIdentifier(view)] == nil {
            let id = ObjectIdentifier(view)
            keys[id] = .init(tier: 3, rank: originals[id] ?? 0, originalIndex: originals[id] ?? 0)
        }
        let context = CanvasWorldPlaneSubviewSortContext(keys: keys)
        worldPlane.sortSubviews({ lhs, rhs, rawContext in
            guard let rawContext else { return .orderedSame }
            let context = Unmanaged<CanvasWorldPlaneSubviewSortContext>.fromOpaque(rawContext).takeUnretainedValue()
            guard let left = context.keys[ObjectIdentifier(lhs)],
                  let right = context.keys[ObjectIdentifier(rhs)] else { return .orderedSame }
            if left.tier != right.tier { return left.tier < right.tier ? .orderedAscending : .orderedDescending }
            if left.rank != right.rank { return left.rank < right.rank ? .orderedAscending : .orderedDescending }
            if left.originalIndex != right.originalIndex {
                return left.originalIndex < right.originalIndex ? .orderedAscending : .orderedDescending
            }
            return .orderedSame
        }, context: Unmanaged.passUnretained(context).toOpaque())
        updateDocumentRelationshipOverlay()
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // The plane is the viewport, so it tracks the canvas's own size. Its
        // bounds SIZE also depends on the viewport size (viewportSize / zoom), so
        // the camera has to be re-applied — a window resize genuinely changes how
        // much world is visible. Tiles still hold world frames and are untouched.
        syncWorldPlaneToCamera()
        layoutNavModeOverlay()
        layoutFrameHUD()
    }

    private func layoutFrameHUD() {
        guard let frameHUD else { return }
        let width: CGFloat = 190
        frameHUD.frame = CGRect(
            x: max(8, bounds.maxX - width - 10),
            y: 10,
            width: width,
            height: 24
        )
    }

    // Deterministic QA seam: presence, text, event transparency and AX silence.
    var qaFrameHUDSnapshot: (text: String, hitTransparent: Bool, accessibilityIgnored: Bool)? {
        guard let frameHUD else { return nil }
        return (
            frameHUD.qaText,
            frameHUD.hitTest(CGPoint(x: frameHUD.bounds.midX, y: frameHUD.bounds.midY)) == nil,
            frameHUD.qaIgnoresAccessibility
        )
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
        }
        if navModeOverlayView != nil { qaCameraLayoutStats.chromeRepaints += 1 }
        navModeOverlayView?.needsDisplay = true
        updateDocumentRelationshipOverlay()
        updateContextualAgentLineageGeometry()
    }

    /// Position and scale one tile view for the current camera, writing only what
    /// actually changed.
    ///
    /// The geometry contract: `bounds` stays at the tile's LOGICAL size while
    /// `frame` carries the scaled screen rect, so AppKit does the zoom scaling
    /// and the tile's content is always laid out at its own size (which is what
    /// keeps the width-keyed measurement caches hitting).
    ///
    /// The reason this is not three plain assignments: writing a frame that did
    /// not change still marks the view — and its whole subtree — as needing
    /// layout, and for a text view costs a TextKit glyph-bounds pass. That is
    /// trap 3 in docs/internals/performance.md and it is exactly what 0.4.17
    /// fixed one level down in `AssistantProseView`. Here it is multiplied by
    /// every tile on the canvas and by every step of a gesture.
    ///
    /// Origin and size are moved separately on purpose. A PAN changes only the
    /// origin, and `setFrameOrigin` does not resize the subtree or disturb
    /// `bounds` — so a pan now costs no subtree layout at all. Only a ZOOM
    /// changes the frame size, and only then does `bounds` need restoring to the
    /// logical size that `setFrameSize` scales away.
    private func applyTileGeometry(_ view: TileNSView, screenFrame rect: CGRect, logicalSize: TileFrame) {
        if !Self.geometryNearlyEqual(view.frame.origin.x, rect.origin.x)
            || !Self.geometryNearlyEqual(view.frame.origin.y, rect.origin.y) {
            qaCameraLayoutStats.frameWrites += 1
            view.setFrameOrigin(rect.origin)
        }
        if !Self.geometryNearlyEqual(view.frame.size.width, rect.size.width)
            || !Self.geometryNearlyEqual(view.frame.size.height, rect.size.height) {
            qaCameraLayoutStats.frameWrites += 1
            view.setFrameSize(rect.size)
        }
        // Compare with a TOLERANCE, not `!=`. AppKit does not store `bounds`
        // verbatim: it keeps the bounds/frame scale and recomputes the bounds
        // size from it, so at any zoom != 1 a bounds set to 420 reads back as
        // 420.00000000000006. An exact comparison therefore never matches, and a
        // "skip unchanged writes" guard rewrites bounds for every tile on every
        // step forever — worse than no guard, because each write also re-marks
        // that tile's whole subtree for layout. Measured over 48 agent tiles at
        // zoom 0.35: 39.9 ms/step with an exact compare, 5.4 ms/step with this.
        let logical = NSRect(x: 0, y: 0, width: logicalSize.width, height: logicalSize.height)
        if !Self.geometryNearlyEqual(view.bounds.size.width, logical.size.width)
            || !Self.geometryNearlyEqual(view.bounds.size.height, logical.size.height)
            || !Self.geometryNearlyEqual(view.bounds.origin.x, 0)
            || !Self.geometryNearlyEqual(view.bounds.origin.y, 0) {
            qaCameraLayoutStats.boundsWrites += 1
            view.bounds = logical
        }
    }

    /// Geometry equality for layout short-circuits. The tolerance is far below
    /// one device pixel, so a difference this small can never be visible — but it
    /// is large enough to absorb the float round-trip AppKit performs through the
    /// bounds/frame scale, which an exact comparison turns into a permanent
    /// cache miss.
    private static func geometryNearlyEqual(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) < 0.001
    }

    /// A `TileFrame`'s world rect, which is also its frame inside the world plane.
    /// The plane's bounds are world coordinates, so no camera term appears here —
    /// that is the entire point of the retained plane.
    private static func worldRect(_ frame: TileFrame) -> CGRect {
        CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }

    private func layoutTile(_ tile: Tile, invalidateTileDisplay: Bool = true) {
        guard let view = tileViews[tile.id] else { return }
        // zone-unify: tiles store WORLD frames (the project canvas stays
        // self-consistent). Zone membership is a pure overlay tag; a moved zone
        // translates its members' world frames explicitly. A member is hidden
        // only when its zone is collapsed.
        // A WORLD rect, not a screen rect: the tile lives in the world plane, and
        // the plane's bounds carry the camera. This is what makes a camera step
        // cost nothing per tile — the value below does not depend on the viewport.
        let rect = Self.worldRect(tile.frame)
        let hidden = membershipPlacement(of: tile.id)?.collapsed == true
        if view.isHidden != hidden { view.isHidden = hidden }
        qaCameraLayoutStats.tilesVisited += 1
        qaCameraLayoutStats.tilesLaidOut += 1
        applyTileGeometry(view, screenFrame: rect, logicalSize: tile.frame)
        if view.tile != tile {
            qaCameraLayoutStats.modelWrites += 1
            view.tile = tile
        }
        if invalidateTileDisplay {
            view.invalidateForCanvasLayout()
        }
        // Track the focus border with the tile's screen frame on pan/zoom/move/
        // resize — the overlay lives on the canvas, not the tile, so it must be
        // repositioned here whenever the bordered tile's frame updates.
        repositionFocusBorderIfNeeded(for: tile.id)
        repositionAttentionBorderIfNeeded(for: tile.id)
        // Authoritatively size the terminal surface from the tile's WORLD content
        // size × backing — independent of canvas zoom. Terminal chrome may grow
        // visually at low zoom for a usable grab target, but that camera-only
        // chrome floor must not resize/reflow the Ghostty grid.
        if let terminalTile = view as? TerminalTileNSView {
            let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
            let contentWorldWidth = max(0, tile.frame.width)
            let contentWorldHeight = max(0, tile.frame.height - Double(terminalTile.contentTopInsetWorldHeight))
            qaCameraLayoutStats.terminalSurfaceWrites += 1
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

    /// The one gesture pipeline: scroll pan, Cmd+scroll zoom and pinch all feed
    /// the driver, which composes them into at most one `setViewport` per
    /// display interval and carries the pinch glide. Pointer-pan drags stay
    /// direct — AppKit already coalesces `mouseDragged`, and the drag oracles
    /// assert the synchronous apply.
    private(set) lazy var cameraDriver: CanvasCameraDriver = {
        let driver = CanvasCameraDriver(
            tuning: .fromEnvironment(),
            currentViewport: { [weak self] in
                self?.canvasState.viewport ?? CanvasViewport(x: 0, y: 0, zoom: 1)
            },
            applyViewport: { [weak self] viewport in self?.setViewport(viewport) },
            makeDisplayLink: { [weak self] target, selector in
                self?.displayLink(target: target, selector: selector)
            }
        )
        driver.onSettle = { [weak self] in self?.cameraGestureDidSettle() }
        return driver
    }()

    override func scrollWheel(with event: NSEvent) {
        guard !isZoneScopePickerActive else { return }
        let cursor = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) {
            // Roughly +/- 10% per logical line of scroll. Smooth, non-linear.
            cameraDriver.noteScrollZoom(deltaY: Double(event.scrollingDeltaY), location: cursor)
        } else {
            var dx = event.scrollingDeltaX
            var dy = event.scrollingDeltaY
            if !event.hasPreciseScrollingDeltas {
                dx *= 16
                dy *= 16
            }
            cameraDriver.noteScrollPan(dx: dx, dy: dy, location: cursor)
        }
    }

    /// Trackpad pinch entry point. The window-level magnify monitor in
    /// ContinuumApp routes here so pinches over a tile body still zoom the
    /// canvas (the tile content has no zoom of its own to compete with).
    func handlePinch(_ event: NSEvent) {
        guard !isZoneScopePickerActive else { return }
        let cursor = convert(event.locationInWindow, from: nil)
        cameraDriver.notePinch(
            magnification: Double(event.magnification),
            phase: event.phase,
            location: cursor,
            timestamp: event.timestamp
        )
    }

    /// Whether this press should enter the shared camera-pan lifecycle. Tile
    /// chrome asks the canvas rather than reimplementing the Space/Cmd policy.
    func pointerPanRequested(for event: NSEvent) -> Bool {
        spaceHeld || event.modifierFlags.contains(.command)
    }

    /// Start the shared pointer-pan lifecycle. Canvas background gestures and
    /// Cmd/Space drags whose AppKit target is tile chrome both delegate here so
    /// camera math, cursor ownership, and release handling cannot diverge.
    func beginPointerPan(with event: NSEvent) {
        guard !pointerPanActive else { return }
        pointerPanActive = true
        pointerPanLastWindowPoint = event.locationInWindow
        NSCursor.closedHand.push()
    }

    func continuePointerPan(with event: NSEvent) {
        guard pointerPanActive else { return }
        let dx = event.locationInWindow.x - pointerPanLastWindowPoint.x
        let dy = event.locationInWindow.y - pointerPanLastWindowPoint.y
        pointerPanLastWindowPoint = event.locationInWindow
        var v = canvasState.viewport
        // Window y goes up, canvas y is flipped (down). Drag-down moves the
        // viewport down, matching the existing trackpad-scroll convention.
        v.x -= Double(dx) / v.zoom
        v.y += Double(dy) / v.zoom
        setViewport(v)
    }

    func endPointerPan() {
        guard pointerPanActive else { return }
        pointerPanActive = false
        NSCursor.pop() // closed hand
        if !spaceHeld, spaceCursorPushed {
            NSCursor.pop() // deferred open hand after a mid-drag Space release
            spaceCursorPushed = false
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !isZoneScopePickerActive else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard let zoneId = _zoneHeaderZoneId(at: point),
              let placement = liveZones.first(where: { $0.zoneId == zoneId })
                ?? zoneLayers.first(where: { $0.placement.zoneId == zoneId })?.placement else { return nil }

        let menu = NSMenu(title: "Zone")
        if let label = zoneDisplayByZoneId[zoneId]?.scopeLabel {
            let scope = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            scope.isEnabled = false
            menu.addItem(scope)
            menu.addItem(.separator())
        }
        let rename = NSMenuItem(title: "Rename", action: #selector(renameZoneFromMenu(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = zoneId.uuidString
        menu.addItem(rename)

        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colors = NSMenu(title: "Color")
        for color in ZoneColorConfig.palette {
            let item = NSMenuItem(title: color.capitalized, action: #selector(setZoneColorFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ["zoneId": zoneId.uuidString, "color": color]
            item.state = placement.color.lowercased() == color ? .on : .off
            colors.addItem(item)
        }
        menu.setSubmenu(colors, for: colorItem)
        menu.addItem(colorItem)

        let changeScope = NSMenuItem(title: "Change Project/Home…", action: #selector(changeZoneScopeFromMenu(_:)), keyEquivalent: "")
        changeScope.target = self
        changeScope.representedObject = zoneId.uuidString
        menu.addItem(changeScope)
        menu.addItem(.separator())

        let autoLayoutItem = NSMenuItem(title: "Auto Layout", action: nil, keyEquivalent: "")
        let modes = NSMenu(title: "Auto Layout")
        for (title, mode) in [("Use Global", ZoneAutoLayoutMode.inherit), ("On", .enabled), ("Off", .disabled)] {
            let item = NSMenuItem(title: title, action: #selector(setZoneAutoLayoutModeFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ["zoneId": zoneId.uuidString, "mode": mode.rawValue]
            item.state = placement.autoLayoutMode == mode ? .on : .off
            modes.addItem(item)
        }
        menu.setSubmenu(modes, for: autoLayoutItem)
        menu.addItem(autoLayoutItem)
        menu.addItem(.separator())
        let tidy = NSMenuItem(title: "Tidy Zone Now", action: #selector(tidyZoneFromMenu(_:)), keyEquivalent: "")
        tidy.target = self
        tidy.representedObject = zoneId.uuidString
        menu.addItem(tidy)
        let collapse = NSMenuItem(
            title: placement.collapsed ? "Expand" : "Collapse",
            action: #selector(toggleZoneCollapsedFromMenu(_:)),
            keyEquivalent: ""
        )
        collapse.target = self
        collapse.representedObject = zoneId.uuidString
        menu.addItem(collapse)
        menu.addItem(.separator())
        let close = NSMenuItem(title: "Close Zone…", action: #selector(closeZoneFromMenu(_:)), keyEquivalent: "")
        close.target = self
        close.representedObject = zoneId.uuidString
        menu.addItem(close)
        return menu
    }

    @objc private func renameZoneFromMenu(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let zoneId = UUID(uuidString: idString) else { return }
        beginZoneRename(zoneId: zoneId)
    }

    @objc private func setZoneColorFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String],
              let idString = payload["zoneId"], let zoneId = UUID(uuidString: idString),
              let color = payload["color"] else { return }
        setZoneColor(color, zoneId: zoneId)
    }

    @objc private func changeZoneScopeFromMenu(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let zoneId = UUID(uuidString: idString),
              let placement = liveZones.first(where: { $0.zoneId == zoneId })
                ?? zoneLayers.first(where: { $0.placement.zoneId == zoneId })?.placement else { return }
        let header = zoneHeaderScreenRect(for: placement) ?? .zero
        onZoneScopeChangeRequested?(placement, CGPoint(x: header.midX, y: header.maxY))
    }

    @objc private func toggleZoneCollapsedFromMenu(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let zoneId = UUID(uuidString: idString),
              let placement = liveZones.first(where: { $0.zoneId == zoneId })
                ?? zoneLayers.first(where: { $0.placement.zoneId == zoneId })?.placement else { return }
        setZoneCollapsed(!placement.collapsed, zoneId: zoneId)
    }

    @objc private func closeZoneFromMenu(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let zoneId = UUID(uuidString: idString) else { return }
        onZoneCloseRequested?(zoneId)
    }

    @objc private func setZoneAutoLayoutModeFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String],
              let idString = payload["zoneId"], let zoneId = UUID(uuidString: idString),
              let rawMode = payload["mode"], let mode = ZoneAutoLayoutMode(rawValue: rawMode) else { return }
        setZoneAutoLayoutMode(mode, zoneId: zoneId)
    }

    @objc private func tidyZoneFromMenu(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let zoneId = UUID(uuidString: idString) else { return }
        tidyAutoLayout(zoneId: zoneId)
    }

    func requestZoneScopeChange(zoneId: UUID) {
        guard let placement = liveZones.first(where: { $0.zoneId == zoneId })
                ?? zoneLayers.first(where: { $0.placement.zoneId == zoneId })?.placement else { return }
        let header = zoneHeaderScreenRect(for: placement) ?? .zero
        onZoneScopeChangeRequested?(placement, CGPoint(x: header.midX, y: header.maxY))
    }

    func toggleZoneAutoLayout(zoneId: UUID) {
        guard let placement = liveZones.first(where: { $0.zoneId == zoneId })
                ?? zoneLayers.first(where: { $0.placement.zoneId == zoneId })?.placement else { return }
        let enabled = placement.autoLayoutMode.resolves(globalEnabled: CanvasAutoLayoutConfig.enabled(defaults: autoLayoutDefaults))
        setZoneAutoLayoutMode(enabled ? .disabled : .enabled, zoneId: zoneId)
    }

    func presentZoneColorPicker(zoneId: UUID) {
        guard let placement = liveZones.first(where: { $0.zoneId == zoneId })
                ?? zoneLayers.first(where: { $0.placement.zoneId == zoneId })?.placement else { return }
        let menu = NSMenu(title: "Zone Color")
        for color in ZoneColorConfig.palette {
            let item = NSMenuItem(title: color.capitalized, action: #selector(setZoneColorFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ["zoneId": zoneId.uuidString, "color": color]
            item.state = placement.color.lowercased() == color ? .on : .off
            menu.addItem(item)
        }
        let header = zoneHeaderScreenRect(for: placement) ?? .zero
        menu.popUp(positioning: nil, at: CGPoint(x: header.minX + 18, y: header.maxY), in: self)
    }

    override func mouseDown(with event: NSEvent) {
        guard !isZoneScopePickerActive else { return }
        if pointerPanRequested(for: event) {
            beginPointerPan(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        // T2 (`.plans/47`): before any gesture classification, because every branch
        // below returns early. `_zoneId(at:)` rather than `zoneId(at:)` so a zone
        // installed only as a layer is not read as empty canvas — the same reason
        // the create-gesture branch uses it.
        if let activatedZoneId = _zoneId(at: point) {
            onZoneActivated?(activatedZoneId)
        }
        if zoneOverflowButtonZoneId(at: point) != nil,
           let zoneMenu = menu(for: event) {
            zoneMenu.popUp(positioning: nil, at: point, in: self)
            return
        }
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
            beginAutoLayoutGesture()
            zoneGesture = .resizingZone(zoneId: zoneId, edge: edge, lastWindowPoint: event.locationInWindow)
            beginGeometryEdit(.resizeZone, zoneIds: [zoneId])
            return
        }
        // Zone gesture classification (T19): check chrome header → move; empty canvas → create.
        // A press that reaches a tile falls through to TileNSView, which owns tile drag.
        pendingMovedPlacement = nil
        if let zoneId = _zoneHeaderZoneId(at: point) {
            beginAutoLayoutGesture()
            zoneGesture = .movingZone(zoneId: zoneId, lastWindowPoint: event.locationInWindow)
            beginGeometryEdit(.moveZone, tileIds: geometryTileIds(inZone: zoneId), zoneIds: [zoneId])
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
        guard !isZoneScopePickerActive else { return }
        if pointerPanActive {
            continuePointerPan(with: event)
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
                showDragGhost(at: marqueeWorld, label: "New Zone", detail: "Space-drag to pan")
            }
            return
        case .movingZone(let zoneId, let lastWindowPoint):
            let dx = event.locationInWindow.x - lastWindowPoint.x
            // Negate dy: window-y-up vs canvas-y-down (same convention as TileNSView.mouseDragged).
            let dy = -(event.locationInWindow.y - lastWindowPoint.y)
            zoneGesture = .movingZone(zoneId: zoneId, lastWindowPoint: event.locationInWindow)
            let vp = canvasState.viewport
            let screenDelta = CGSize(width: dx, height: dy)
            if isAutoLayoutEnabled,
               let current = liveZones.first(where: { $0.zoneId == zoneId })
                    ?? zoneLayers.first(where: { $0.placement.zoneId == zoneId })?.placement {
                let newPlacement = CanvasEngine.zone(current, draggedByScreenDelta: screenDelta, viewport: vp)
                applyAutoLayout(.zone(id: zoneId, placement: newPlacement), baseline: autoLayoutGestureBaseline)
                pendingMovedPlacement = liveZones.first(where: { $0.zoneId == zoneId })
                    ?? zoneLayers.first(where: { $0.placement.zoneId == zoneId })?.placement
                if let final = pendingMovedPlacement {
                    showResizeDimensions(
                        widthPx: Int(final.size.width.rounded()),
                        heightPx: Int(final.size.height.rounded()),
                        atWindowPoint: event.locationInWindow
                    )
                    if autoLayoutBlockedZoneIds.contains(zoneId) {
                        showDragGhost(at: CanvasEngine.zoneWorldFrame(final))
                    } else {
                        hideDragGhost()
                    }
                }
                return
            }
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
            if isAutoLayoutEnabled,
               let current = liveZones.first(where: { $0.zoneId == zoneId })
                    ?? zoneLayers.first(where: { $0.placement.zoneId == zoneId })?.placement {
                let newPlacement = resizedZonePlacement(current, edge: edge, screenDelta: CGSize(width: dx, height: dy))
                applyAutoLayout(.zone(id: zoneId, placement: newPlacement), baseline: autoLayoutGestureBaseline)
                pendingMovedPlacement = liveZones.first(where: { $0.zoneId == zoneId })
                    ?? zoneLayers.first(where: { $0.placement.zoneId == zoneId })?.placement
                return
            }
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
        guard !isZoneScopePickerActive else { return }
        if pointerPanActive {
            endPointerPan()
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
                _ = beginProvisionalZone(screenRect: CGRect(
                    x: min(originScreen.x, point.x),
                    y: min(originScreen.y, point.y),
                    width: abs(point.x - originScreen.x),
                    height: abs(point.y - originScreen.y)
                ))
            }
            return
        case .movingZone(let zoneId, _):
            hideDragGhost()
            _ = zoneId // identity is captured by the pending transaction
            if isAutoLayoutEnabled { _ = finishAutoLayoutGesture() }
            _ = commitGeometryEdit()
            pendingMovedPlacement = nil
            return
        case .resizingZone:
            hideDragGhost()
            hideResizeDimensions()
            if isAutoLayoutEnabled { _ = finishAutoLayoutGesture() }
            _ = commitGeometryEdit()
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
                // Do not push an open hand above an in-flight Cmd-pan's closed
                // hand; that would make cursor-stack teardown order ambiguous.
                if !pointerPanActive {
                    NSCursor.openHand.push()
                    spaceCursorPushed = true
                }
            }
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49, spaceHeld {
            spaceHeld = false
            if !pointerPanActive, spaceCursorPushed {
                NSCursor.pop()
                spaceCursorPushed = false
            }
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
    /// - Parameter documentZones: EVERY zone in the workspace document, not just
    ///   the ones that got a layer. M1.10 (`.plans/46`): a zone below the live
    ///   hydration tier still has to be drawn and still has to be navigable — that
    ///   is what a tier IS — so narrowing `liveZones` to the installed layers made
    ///   snapshot-tier zones vanish from framing, hit-testing and chrome. Caught by
    ///   `--workspace-sidebar-actions-check`. Defaults to the layer set for callers
    ///   that have no document (PerfScenarios and the older zone fixtures).
    func setZones(_ layers: [ZoneLayer], documentZones: [ZoneRenderModel]? = nil) {
        // Unregister + remove all currently installed layers.
        for layer in zoneLayers {
            for (_, view) in layer.tileViews {
                // M1.4: tell the view it is leaving BEFORE dismantling it. Without
                // this an agent tile's event subscription, three supervisor
                // observer tokens and its stale-location timer orphaned on every
                // switch -- and the flat `turnCapabilityObservers` entry among them
                // keeps firing for every agent in the app, not just its own.
                view.prepareForRemovalFromScene()
                focusBroker?.unregister(view.focusSurfaceID)
                releaseSurfaceResidency(of: view)
                view.removeFromSuperview()
            }
        }
        zoneLayers = []
        zoneLayerOrder = []
        // The departing zone set owns the spawn target; the caller re-declares it.
        activeProjectZoneId = nil

        // M1.10 (`.plans/46`): `setZones` is now the WRITER of the zone model, not
        // just of the tile layers.
        //
        // `liveZones` is not decoration. Zone create, move, resize, rename, close,
        // header hit-test, zone-at-point, drop membership and grow-to-fit all read
        // it, and only three of those consult `zoneLayers`. Because `setZones`
        // never wrote it and `retireFlatCompatibilityScene` empties it, the first
        // workspace switch used to leave every zone unmovable, unresizable,
        // unrenameable and unclosable — latent only because the layer path was
        // unreachable from production. Chrome has the same split: Model B's
        // `zoneChromeViews` were orphaned in `worldPlane` while `_installLayer`
        // added a second set on top.
        //
        // One owner: Model B owns zone geometry, chrome and gestures; a ZoneLayer
        // owns tiles.
        for (_, view) in zoneChromeViews { view.removeFromSuperview() }
        zoneChromeViews.removeAll()
        let zoneModels = documentZones ?? layers.map(\.renderModel)
        liveZones = zoneModels.map(\.placement)
        zoneRenderModels = zoneModels
        zoneDisplayByZoneId = Dictionary(
            zoneModels.map { ($0.placement.zoneId, $0) },
            uniquingKeysWith: { first, _ in first })
        tileZoneMembership = Dictionary(
            layers.flatMap { layer in layer.tiles.map { ($0.id, layer.placement.zoneId) } },
            uniquingKeysWith: { first, _ in first })
        installZoneChromeViews()

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
        // A surface is per-tile state, and a departed project's tiles are not coming
        // back into this canvas. Pruning here is what stops a workspace switch from
        // accumulating megabytes of pixels for tiles nobody can reach.
        tileSurfaceStore.prune(keeping: Set(tileViewsInVisualOrder.map { $0.tile.id }))
    }

    /// Permanently retire the boot-only flat scene before the first workspace
    /// swap. Its model remains intact for its owning ProjectStore, but none of
    /// its views or indexes may leak into the arriving workspace canvas.
    func retireFlatCompatibilityScene() {
        guard flatCompatibilitySceneActive else { return }
        flatCompatibilitySceneActive = false
        for (_, view) in tileViews {
            // M1.4: same removal, same contract -- the boot scene's agent tiles
            // leak exactly as a zone layer's do.
            view.prepareForRemovalFromScene()
            focusBroker?.unregister(view.focusSurfaceID)
            releaseSurfaceResidency(of: view)
            view.removeFromSuperview()
        }
        tileViews.removeAll()
        tileZoneMembership.removeAll()
        liveZones.removeAll()
        zoneRenderModels.removeAll()
        zoneDisplayByZoneId.removeAll()
        // M1.10: clearing the DATA while leaving the VIEWS in `worldPlane` is what
        // left a departed workspace's zone rectangles painted on screen forever,
        // frozen at their last frame (`layoutZoneChromeViews` iterates `liveZones`,
        // so an orphan is never re-framed again yet still rides the camera).
        for (_, view) in zoneChromeViews { view.removeFromSuperview() }
        zoneChromeViews.removeAll()
        canvasState.lastActiveTileId = nil
        clearFocusBorder()
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
            for tile in existing.tiles { tileZoneMembership.removeValue(forKey: tile.id) }
            zoneLayers.removeAll { $0.placement.zoneId == zoneId }
        }
        // Add at end of z-order if not already present.
        if !zoneLayerOrder.contains(zoneId) {
            zoneLayerOrder.append(zoneId)
        }
        // M1.10: this path does not go through `setZones`, so it registers the
        // zone into Model B itself — otherwise the zone would render (a layer
        // exists) but be unmovable, unresizable and unrenameable, because every
        // one of those gestures reads `liveZones`.
        if let index = liveZones.firstIndex(where: { $0.zoneId == zoneId }) {
            liveZones[index] = layer.placement
        } else {
            liveZones.append(layer.placement)
        }
        if let index = zoneRenderModels.firstIndex(where: { $0.placement.zoneId == zoneId }) {
            zoneRenderModels[index] = layer.renderModel
        } else {
            zoneRenderModels.append(layer.renderModel)
        }
        zoneDisplayByZoneId[zoneId] = layer.renderModel
        for tile in layer.tiles { tileZoneMembership[tile.id] = zoneId }
        if showsZoneChrome {
            if let chrome = zoneChromeViews[zoneId] {
                chrome.update(model: layer.renderModel)
            } else {
                let chrome = ZoneChromeNSView(model: layer.renderModel)
                zoneChromeViews[zoneId] = chrome
                worldPlane.addSubview(chrome, positioned: .below, relativeTo: nil)
            }
        }
        _installLayer(layer)
        layoutZoneChromeViews()
        // T5: a zone can be armed BEFORE its chrome exists — `_addProjectZone`
        // installs the layer and then arms it, and `setActiveProjectZone` is a
        // no-op until the layer is there. Re-apply once the chrome is built.
        applyArmedZoneChrome()
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
        zoneChromeViews.removeValue(forKey: zoneId)?.removeFromSuperview()
        liveZones.removeAll { $0.zoneId == zoneId }
        zoneRenderModels.removeAll { $0.placement.zoneId == zoneId }
        zoneDisplayByZoneId.removeValue(forKey: zoneId)
        for tile in layer.tiles { tileZoneMembership.removeValue(forKey: tile.id) }
        zoneLayers.removeAll { $0.placement.zoneId == zoneId }
        zoneLayerOrder.removeAll { $0 == zoneId }
        if activeProjectZoneId == zoneId { activeProjectZoneId = nil }
        reorderTileSubviewsByZIndex()
    }

    /// Update only a layer's placement in place; relays its tiles + chrome.
    func setZonePlacement(_ placement: ZonePlacement) {
        guard let layer = zoneLayers.first(where: { $0.placement.zoneId == placement.zoneId }) else { return }
        layer.placement = placement
        layer.renderModel.placement = placement
        // M1.10: Model B owns geometry, so a layer placement change has to land
        // there too — `liveZones` is what every zone gesture and the chrome layout
        // read.
        if let index = liveZones.firstIndex(where: { $0.zoneId == placement.zoneId }) {
            liveZones[index] = placement
        }
        if let index = zoneRenderModels.firstIndex(where: { $0.placement.zoneId == placement.zoneId }) {
            zoneRenderModels[index].placement = placement
        }
        if var model = zoneDisplayByZoneId[placement.zoneId] {
            model.placement = placement
            zoneDisplayByZoneId[placement.zoneId] = model
            zoneChromeViews[placement.zoneId]?.update(model: model)
        }
        for tile in layer.tiles {
            _layoutLayerTile(tile, in: layer)
        }
        layoutZoneChromeViews()
        updateDocumentRelationshipOverlay()
        updateContextualAgentLineageGeometry()
    }


    /// Test introspection: world frame of a zone's chrome view.
    ///
    /// M1.10: reads `zoneChromeViews`, which is now the only chrome there is —
    /// a ZoneLayer stopped owning a second one.
    func zoneLayerChromeFrame(for zoneId: UUID) -> CGRect? {
        zoneChromeViews[zoneId]?.frame
    }

    /// QA (M1.10): exactly one chrome view per zone, no orphan from a departed
    /// workspace and no duplicate from a layer install.
    var qaZoneChromeViewCount: Int { zoneChromeViews.count }

    /// Test introspection: zoneIds of installed layers in z-order (back-to-front).
    var installedZoneLayerIds: [UUID] { zoneLayerOrder }

    /// Test introspection: the tile ids a layer currently owns.
    func tileIds(inZone zoneId: UUID) -> [UUID] {
        zoneLayers.first(where: { $0.placement.zoneId == zoneId })?.tiles.map(\.id) ?? []
    }

    /// The tiles a layer currently owns, in its live in-memory order. This is the
    /// authoritative model for a project's tiles once `setZones` has run — the flat
    /// `canvasState.tiles` collection does not represent them (T09 shape-B gap).
    func tiles(inZone zoneId: UUID) -> [Tile]? {
        zoneLayers.first(where: { $0.placement.zoneId == zoneId })?.tiles
    }

    // MARK: - Active project zone (spawn target)

    /// The installed layer a NEW project tile belongs in, set by `WorkspaceRuntime`
    /// from the workspace document's `lastActiveZoneId` whenever it installs or
    /// swaps a zone set. nil at boot, where the single-zone `activeZone` +
    /// `canvasState.tiles` path still owns the active project.
    private(set) var activeProjectZoneId: UUID?

    func setActiveProjectZone(_ zoneId: UUID?) {
        defer { applyArmedZoneChrome() }
        guard let zoneId,
              zoneLayers.contains(where: {
                  $0.placement.zoneId == zoneId && $0.placement.projectId != nil
              }) else {
            activeProjectZoneId = nil
            return
        }
        activeProjectZoneId = zoneId
    }

    /// The zone new tiles will be created in, as the user should see it.
    /// T5 (`.plans/47`).
    ///
    /// Mirrors `resolvedCreationScope`'s own zone candidate exactly, fallback
    /// included: at boot no layer is installed, `activeProjectZoneId` is nil, and
    /// the boot `activeZone` is the real target. An indicator that disagreed with
    /// the resolver would be worse than none.
    var armedZoneId: UUID? {
        activeProjectZoneId ?? activeZone.flatMap { $0.projectId == nil ? nil : $0.zoneId }
    }

    /// Repaint the armed accent. O(zones), and only the two chrome views whose
    /// state actually flipped redraw — `isArmed`'s `didSet` is change-gated.
    private func applyArmedZoneChrome() {
        let armed = armedZoneId
        for (zoneId, view) in zoneChromeViews {
            view.isArmed = (zoneId == armed)
        }
    }

    /// QA (T5): which zone is drawn as armed.
    var qaArmedChromeZoneIds: Set<UUID> {
        Set(zoneChromeViews.filter { $0.value.isArmed }.keys)
    }

    /// Every tile belonging to the ACTIVE project, read from whichever model owns
    /// it. Spawn placement, "is this file already open", and z-ordering must all
    /// consult this rather than `canvasState.tiles`, which goes stale the moment
    /// `setZones` installs layers.
    func projectTiles() -> [Tile] {
        if let activeProjectZoneId, let tiles = tiles(inZone: activeProjectZoneId) { return tiles }
        return flatCompatibilitySceneActive ? canvasState.tiles : []
    }

    /// Every currently installed tile model across the compatibility canvas and
    /// all zone layers. Document identity is workspace-wide, not active-zone-only.
    func allWorkspaceTiles() -> [Tile] {
        var seen = Set<UUID>()
        let flatTiles = flatCompatibilitySceneActive ? canvasState.tiles : []
        return (flatTiles + zoneLayers.flatMap(\.tiles)).filter { seen.insert($0.id).inserted }
    }

    /// Resolve one tile from the model that currently owns it. App-level
    /// lifecycle and command code must not reach into `canvasState.tiles`
    /// directly after ZoneLayers are installed: that compatibility array is
    /// intentionally not a mirror and may describe the departed workspace.
    /// Every installed tile with its frame in WORLD coordinates, across BOTH
    /// models. T9 (`.plans/48`).
    ///
    /// `projectTiles()` answers in whichever space the ACTIVE zone uses, and
    /// `tiles(inZone:)` in that zone's local space — so a caller placing a tile
    /// relative to an anchor in a DIFFERENT zone was mixing spaces silently. World
    /// is the one space every tile can be expressed in, so compute there and
    /// convert once at the end, against the zone the tile will actually install
    /// into.
    func allTilesInWorldFrames() -> [Tile] {
        var seen = Set<UUID>()
        var result: [Tile] = []
        for layer in zoneLayers {
            for tile in layer.tiles where seen.insert(tile.id).inserted {
                var world = tile
                world.frame = CanvasEngine.zoneLocalToWorld(tile.frame, zoneOrigin: layer.placement.origin)
                result.append(world)
            }
        }
        if flatCompatibilitySceneActive {
            for tile in canvasState.tiles where seen.insert(tile.id).inserted {
                result.append(tile)
            }
        }
        return result
    }

    func tileRecord(for tileId: UUID) -> Tile? {
        if let tile = zoneLayers.lazy.compactMap({ layer in
            layer.tiles.first(where: { $0.id == tileId })
        }).first {
            return tile
        }
        return flatCompatibilitySceneActive
            ? canvasState.tiles.first(where: { $0.id == tileId })
            : nil
    }

    /// Union of every installed zone representing one registered project. The
    /// same project may intentionally appear in several zones; persistence must
    /// never replace the project canvas with only the last zone that changed.
    func tiles(forProjectId projectId: UUID) -> [Tile] {
        var seen = Set<UUID>()
        return zoneLayers
            .filter { $0.placement.projectId == projectId }
            .flatMap(\.tiles)
            .filter { seen.insert($0.id).inserted }
    }

    /// The same tiles, converted back to WORLD frames for persistence.
    ///
    /// M1.10 (`.plans/46`). A ZoneLayer holds ZONE-LOCAL frames; `canvas.json`
    /// holds WORLD frames, in every installed copy of the app, because the layer
    /// path has never been reachable from production. Persisting local frames
    /// would rewrite the file in a second convention that the boot flat path then
    /// reads as world — moving every tile by its zone origin on the next launch.
    /// This is the inverse of the conversion `WorkspaceRuntime` applies when it
    /// builds a layer's `memberTiles`.
    func tilesInWorldFrames(forProjectId projectId: UUID) -> [Tile] {
        var seen = Set<UUID>()
        return zoneLayers
            .filter { $0.placement.projectId == projectId }
            .flatMap { layer in
                layer.tiles.map { tile -> Tile in
                    var world = tile
                    world.frame = CanvasEngine.zoneLocalToWorld(tile.frame, zoneOrigin: layer.placement.origin)
                    return world
                }
            }
            .filter { seen.insert($0.id).inserted }
    }

    /// Whether the flat boot scene still owns the active project. False from the
    /// first `setZones`/`retireFlatCompatibilityScene` onward, after which
    /// `canvasState.tiles` describes the DEPARTED project and must not be persisted.
    /// M1.0 (`.plans/46`).
    var isFlatCompatibilitySceneActive: Bool { flatCompatibilitySceneActive }

    /// The zoneIds of this project's INSTALLED layers — the only zones entitled to
    /// report a tile as deleted. See `CanvasEngine.mergeProjectTilesForPersistence`.
    func installedZoneIds(forProjectId projectId: UUID) -> Set<UUID> {
        Set(zoneLayers.filter { $0.placement.projectId == projectId }.map(\.placement.zoneId))
    }

    /// The canvas state to persist for one project, merged over what is on disk.
    ///
    /// M1.0 (`.plans/46`). This is the ONE reader every persistence path must use.
    /// Before it, `flushCanvasSave` wrote the raw flat `canvasState` into whichever
    /// project was active — so the first canvas change after a workspace switch
    /// overwrote the arriving project's `canvas.json` with the departed project's
    /// tiles — and `persistProjectCanvas` replaced the file with the installed
    /// layers alone, dropping every zone below the live tier.
    ///
    /// `base` supplies every field except `tiles`, and the two callers want
    /// different bases — which is the whole reason this takes both.
    ///
    /// A **camera flush** must base on the LIVE `canvasState`, because the viewport
    /// it exists to save lives there and nowhere else; basing it on the disk copy
    /// silently stops persisting pan and zoom (caught by `--zone-save-isolation-check`
    /// and `--workspace-runtime-install-check`, which is exactly their job).
    /// A **spawn** bases on the disk copy, so adding a tile does not also commit
    /// whatever the camera happens to be doing.
    ///
    /// `persistedTiles` is always the on-disk tile list, whichever base is used:
    /// it is what tells the merge which zones exist beyond the installed ones.
    func canvasStateForPersistence(
        projectId: UUID,
        base: CanvasState,
        persistedTiles: [Tile]
    ) -> CanvasState {
        var state = base
        let covered = installedZoneIds(forProjectId: projectId)
        if flatCompatibilitySceneActive && covered.isEmpty {
            // Boot, single project, no layers yet: the flat scene IS this project.
            //
            // BOTH halves of that condition are load-bearing. The flag alone stays
            // true until the first workspace SWITCH, so it is still true after
            // `setZones` has installed this project's layers — and at that moment
            // the flat `canvasState` is no longer the project's model. Persisting
            // it then writes whatever the flat scene happens to hold, which for a
            // canvas built empty and populated purely through layers is nothing at
            // all: the project's `canvas.json` is truncated to zero tiles.
            // Found by `--zone-runtime-duplication-check`, whose fixture installs a
            // workspace into a canvas with no flat tiles and watched all three of
            // its tiles disappear from disk.
            state.tiles = canvasState.tiles
            state.lastActiveTileId = canvasState.lastActiveTileId
            return state
        }
        state.tiles = CanvasEngine.mergeProjectTilesForPersistence(
            persisted: persistedTiles,
            installed: tilesInWorldFrames(forProjectId: projectId),
            coveredZoneIds: covered
        )
        return state
    }

    func projectId(forZone zoneId: UUID) -> UUID? {
        zoneLayers.first(where: { $0.placement.zoneId == zoneId })?.placement.projectId
    }

    func zonePlacement(for zoneId: UUID) -> ZonePlacement? {
        zoneLayers.first(where: { $0.placement.zoneId == zoneId })?.placement
            ?? allZonePlacements().first(where: { $0.zoneId == zoneId })
    }

    /// The placement of a zone ONLY when an installed layer owns it.
    ///
    /// The distinction is a frame space, not a nicety. `installProjectTile` uses a
    /// layer when one exists and silently falls back to the flat model when it does
    /// not — and the flat model holds WORLD frames while a layer holds ZONE-LOCAL.
    /// So anything computing a frame for a tile about to be installed must ask
    /// whether the LAYER exists, not merely whether the zone does.
    /// `zonePlacement(for:)` answers the second question: it falls back to
    /// `allZonePlacements()`, which includes zones with no layer at all. Framing
    /// against one of those produced a zone-local frame that the flat install then
    /// read as world, displacing every new tile by the zone's origin.
    /// T4 (`.plans/47`).
    func installedZonePlacement(for zoneId: UUID) -> ZonePlacement? {
        zoneLayers.first(where: { $0.placement.zoneId == zoneId })?.placement
    }

    func zoneId(containing tileId: UUID) -> UUID? {
        zoneLayers.first(where: { $0.tiles.contains(where: { $0.id == tileId }) })?.placement.zoneId
            ?? (flatCompatibilitySceneActive ? canvasState.tiles.first(where: { $0.id == tileId })?.zoneId : nil)
    }

    /// Where `installProjectTile` actually put a tile. Callers persist through the
    /// matching model: the flat path saves `canvasState`, the layer path saves the
    /// layer's tiles into that project's own store.
    enum ProjectTileTarget: Equatable {
        case flatCanvasState
        case zoneLayer(UUID)
    }

    /// The active project zone's placement, when a layer owns it. New tiles must be
    /// framed in ZONE-LOCAL coordinates for a layer (`_layoutLayerTile` converts
    /// via the placement origin) and in WORLD coordinates for the flat path.
    var activeProjectZonePlacement: ZonePlacement? {
        guard let activeProjectZoneId else { return nil }
        return zoneLayers.first(where: { $0.placement.zoneId == activeProjectZoneId })?.placement
    }

    /// Installs a newly spawned project tile into whichever model owns the active
    /// project — the ZoneLayer installed by `setZones`, or the flat single-zone
    /// path at boot. Without this, a spawn after a workspace switch appended to the
    /// stale flat `canvasState` and laid the tile out against the DEPARTED zone's
    /// placement, so it never appeared in the zone the user was looking at.
    @discardableResult
    func installProjectTile(tileView: TileNSView, for tile: Tile, targetZoneId: UUID? = nil) -> ProjectTileTarget {
        guard let zoneId = targetZoneId ?? activeProjectZoneId,
              let layer = zoneLayers.first(where: { $0.placement.zoneId == zoneId })
        else {
            install(tileView: tileView, for: tile)
            // T7 (`.plans/47`): the flat model never grew its zone on a spawn — only
            // `installProjectTile`'s LAYER branch did, and only through
            // `arrangeAutoLayoutAfterSpawn`, which is gated on auto-layout being on.
            // The boot project is flat, so a tile spawned into the boot zone landed
            // outside it and the zone only caught up once the tile was dragged.
            // The tile's frame is already WORLD here.
            if let owning = tile.zoneId ?? activeProjectZoneId ?? activeZone?.zoneId {
                growZoneOnSpawn(owning, toInclude: tile.frame)
            }
            return .flatCanvasState
        }

        if let existing = layer.tileViews[tile.id] {
            focusBroker?.unregister(existing.focusSurfaceID)
            existing.removeFromSuperview()
        }
        var installed = tile
        installed.zoneId = zoneId
        layer.tileViews[tile.id] = tileView
        if let index = layer.tiles.firstIndex(where: { $0.id == tile.id }) {
            layer.tiles[index] = installed
        } else {
            layer.tiles.append(installed)
        }
        tileView.canvas = self
        let tileId = tile.id
        tileView.onClose = { [weak self] in self?.onTileCloseRequested?(tileId) }
        tileView.onStopRun = { [weak self] in self?.onTileStopRunRequested?(tileId) }
        wireRelationshipHover(for: tileView, tileId: tileId)
        worldPlane.addSubview(tileView)
        focusBroker?.register(tileView)
        _layoutLayerTile(installed, in: layer)
        tileZoneMembership[tile.id] = zoneId
        reorderTileSubviewsByZIndex()
        delegate?.canvasSidebarModelDidChange(self)
        // T7: unconditional, and BEFORE the auto-layout pass. `arrangeAutoLayoutAfterSpawn`
        // already expands the zone, but only when auto-layout is enabled — with it off,
        // a spawned tile sat outside its zone until someone dragged it.
        growZoneOnSpawn(zoneId, toInclude: CanvasEngine.worldFrame(tile: installed, in: layer.placement))
        arrangeAutoLayoutAfterSpawn(zoneId: zoneId)
        return .zoneLayer(zoneId)
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
        for (tileId, view) in layer.tileViews {
            view.canvas = self
            view.onClose = { [weak self] in self?.onTileCloseRequested?(tileId) }
            view.onStopRun = { [weak self] in self?.onTileStopRunRequested?(tileId) }
            wireRelationshipHover(for: view, tileId: tileId)
            worldPlane.addSubview(view)
            focusBroker?.register(view)
        }
        // M1.10: chrome belongs to Model B (`zoneChromeViews`), rebuilt by
        // `setZones`. A second set here was the double-draw half of the split, and
        // it would also have been the half that is NOT the move/resize grab target.
    }

    // Layout a single tile belonging to a ZoneLayer.
    private func _layoutLayerTile(_ tile: Tile, in layer: ZoneLayer, invalidateTileDisplay: Bool = true) {
        guard let view = layer.tileViews[tile.id] else { return }
        let worldFrame = CanvasEngine.worldFrame(tile: tile, in: layer.placement)
        // WORLD rect — see layoutTile. The plane carries the camera.
        let rect = Self.worldRect(worldFrame)
        if view.isHidden != layer.placement.collapsed { view.isHidden = layer.placement.collapsed }
        qaCameraLayoutStats.tilesVisited += 1
        qaCameraLayoutStats.tilesLaidOut += 1
        applyTileGeometry(view, screenFrame: rect, logicalSize: tile.frame)
        if view.tile != tile {
            qaCameraLayoutStats.modelWrites += 1
            view.tile = tile
        }
        if invalidateTileDisplay {
            view.invalidateForCanvasLayout()
        }
        repositionFocusBorderIfNeeded(for: tile.id)
    }

    /// Exercises the user-visible history contract without depending on pointer
    /// timing: one semantic edit, exact undo/redo, atomic membership + zone
    /// geometry, redo invalidation, workspace isolation, and stale-entry safety.
    static func runCanvasUndoSelfCheck() throws {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String { switch self { case let .failed(message): return message } }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }
        func frameX(_ canvas: CanvasNSView, _ tileId: UUID) -> Double? {
            canvas.canvasState.tiles.first(where: { $0.id == tileId })?.frame.x
        }

        let workspaceA = UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!
        let workspaceB = UUID(uuidString: "00000000-0000-0000-0000-00000000B001")!
        let workspaceC = UUID(uuidString: "00000000-0000-0000-0000-00000000C001")!
        let workspaceD = UUID(uuidString: "00000000-0000-0000-0000-00000000D002")!
        let projectId = UUID(uuidString: "00000000-0000-0000-0000-00000000D001")!
        let zoneId = UUID(uuidString: "00000000-0000-0000-0000-00000000E001")!
        let tileId = UUID(uuidString: "00000000-0000-0000-0000-00000000F001")!
        let originalFrame = TileFrame(x: 100, y: 100, width: 220, height: 160)
        let finalFrame = TileFrame(x: 540, y: 120, width: 220, height: 160)
        let originalZoneSize = ZoneSize(width: 400, height: 320)
        let grownZoneSize = ZoneSize(width: 640, height: 420)
        let zone = ZonePlacement(
            zoneId: zoneId,
            projectId: projectId,
            origin: ZonePoint(x: 500, y: 80),
            size: originalZoneSize,
            color: "teal",
            collapsed: false,
            hydrationPolicy: .automatic,
            name: "History",
            navKey: nil
        )
        let tile = Tile(
            id: tileId,
            kind: .note,
            title: "Undo probe",
            frame: originalFrame,
            zPosition: .fromLegacyRank(1),
            runtimeRef: nil,
            metadata: TileMetadata()
        )
        let canvas = CanvasNSView(
            canvasState: CanvasState(
                viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                tiles: [tile],
                groups: [],
                lastActiveTileId: nil
            ),
            zoneRenderModels: [ZoneRenderModel(placement: zone, displayName: "History")]
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)
        try expect(window.makeFirstResponder(canvas), "canvas should accept first responder for command routing")
        let delegate = CanvasUndoSelfCheckDelegate()
        canvas.delegate = delegate
        var zoneCommitCount = 0
        canvas.onZoneMoved = { _ in zoneCommitCount += 1 }
        canvas.activateUndoWorkspace(workspaceA)

        // Several live previews, membership adoption, and zone growth become one entry.
        canvas.beginGeometryEdit(.moveTile, tileIds: [tileId], includeAllZones: true)
        for x in [240.0, 360.0, finalFrame.x] {
            var changed = canvas.canvasState.tiles[0]
            changed.frame.x = x
            canvas.updateTile(changed, recalculateZoneBounds: false, notifyChange: false)
        }
        canvas.setTileZone(tileId, zoneId: zoneId)
        canvas.liveZones[0].size = grownZoneSize
        let transaction = canvas.commitGeometryEdit()
        try expect(transaction != nil, "semantic edit should create a transaction")
        if let transaction {
            let encoded = try JSONEncoder().encode(transaction)
            let decoded = try JSONDecoder().decode(CanvasGeometryTransaction.self, from: encoded)
            try expect(decoded == transaction, "geometry transaction should round-trip losslessly")
        }
        try expect(canvas.activeCanvasUndoManager?.undoActionName == "Move Tile", "Undo menu should name the action")
        try expect(delegate.changeCount == 1 && zoneCommitCount == 1, "commit should persist exactly once")

        // A no-op gesture must not add a second history step.
        canvas.beginGeometryEdit(.moveTile, tileIds: [tileId], includeAllZones: true)
        try expect(canvas.commitGeometryEdit() == nil, "no-op gesture should be omitted")
        canvas.activeCanvasUndoManager?.undo()
        try expect(frameX(canvas, tileId) == originalFrame.x, "undo should restore the exact original frame")
        try expect(canvas.qaZoneMembership(of: tileId) == nil, "undo should restore ambient membership")
        try expect(canvas.qaLiveZonePlacement(zoneId)?.size == originalZoneSize, "undo should restore zone growth atomically")
        try expect(canvas.activeCanvasUndoManager?.canUndo == false, "coalesced gesture should consume exactly one undo step")
        try expect(canvas.activeCanvasUndoManager?.redoActionName == "Move Tile", "Redo menu should name the action")

        canvas.activeCanvasUndoManager?.redo()
        try expect(frameX(canvas, tileId) == finalFrame.x, "redo should restore the exact committed frame")
        try expect(canvas.qaZoneMembership(of: tileId) == zoneId, "redo should restore zone membership")
        try expect(canvas.qaLiveZonePlacement(zoneId)?.size == grownZoneSize, "redo should restore zone growth")
        try expect(delegate.changeCount == 3 && zoneCommitCount == 3, "undo and redo should each persist once")

        // New work after undo forks history and clears the redo branch.
        canvas.activeCanvasUndoManager?.undo()
        canvas.beginGeometryEdit(.moveTile, tileIds: [tileId])
        var forked = canvas.canvasState.tiles[0]
        forked.frame.x = 250
        canvas.updateTile(forked, recalculateZoneBounds: false, notifyChange: false)
        _ = canvas.commitGeometryEdit()
        try expect(canvas.activeCanvasUndoManager?.canRedo == false, "new edit after undo should clear redo")

        // A second workspace has an independent manager; switching back preserves A.
        canvas.activateUndoWorkspace(workspaceB)
        try expect(canvas.activeCanvasUndoManager?.canUndo == false, "new workspace should start with empty history")
        canvas.beginGeometryEdit(.moveTile, tileIds: [tileId])
        var workspaceBTile = canvas.canvasState.tiles[0]
        workspaceBTile.frame.x = 700
        canvas.updateTile(workspaceBTile, recalculateZoneBounds: false, notifyChange: false)
        _ = canvas.commitGeometryEdit()
        try expect(canvas.activeCanvasUndoManager?.canUndo == true, "workspace B should own its edit")
        canvas.applyGeometrySnapshot(
            CanvasGeometrySnapshot(
                tiles: [CanvasTileGeometry(tileId: tileId, frame: forked.frame, zoneId: nil)],
                zones: []
            ),
            notifyCommit: false
        )
        canvas.activateUndoWorkspace(workspaceA)
        // `sendAction(to:nil)` requires the command-line check process itself to
        // be the active macOS app. Drive the exact key-window responder path
        // directly; the separate menu contract check proves Cmd-Z maps to undo:.
        let commandZWasRouted = window.firstResponder?.tryToPerform(
            Selector(("undo:")),
            with: nil
        ) ?? false
        try expect(commandZWasRouted, "Edit > Undo / Cmd-Z should route through the canvas responder")
        try expect(frameX(canvas, tileId) == originalFrame.x, "workspace A should resume its own history")

        // If geometry changed outside the transaction pipeline, fail closed instead
        // of applying an undo snapshot to surprising state.
        canvas.activateUndoWorkspace(workspaceC)
        canvas.beginGeometryEdit(.moveTile, tileIds: [tileId])
        var recorded = canvas.canvasState.tiles[0]
        recorded.frame.x = 320
        canvas.updateTile(recorded, recalculateZoneBounds: false, notifyChange: false)
        _ = canvas.commitGeometryEdit()
        var external = recorded
        external.frame.x = 999
        canvas.updateTile(external, recalculateZoneBounds: false, notifyChange: false)
        canvas.activeCanvasUndoManager?.undo()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        try expect(frameX(canvas, tileId) == 999, "stale undo must not overwrite out-of-band geometry")
        try expect(canvas.activeCanvasUndoManager?.canUndo == false && canvas.activeCanvasUndoManager?.canRedo == false,
                   "stale history should be invalidated")

        // Losing app activation can suppress mouse-up. Preview geometry rolls
        // back and does not enter history.
        canvas.activateUndoWorkspace(workspaceD)
        canvas.beginGeometryEdit(.resizeTile, tileIds: [tileId])
        var interrupted = external
        interrupted.frame.width = 777
        canvas.updateTile(interrupted, notifyChange: false)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        try expect(canvas.canvasState.tiles[0].frame == external.frame,
                   "interrupted gesture should restore its pre-gesture frame")
        try expect(canvas.activeCanvasUndoManager?.canUndo == false, "interrupted gesture should not create history")

        // Editable tile content owns Cmd-Z while it is first responder. Its text
        // undo must not consume or execute the canvas geometry history beneath it.
        let inputWorkspace = UUID(uuidString: "00000000-0000-0000-0000-00000000D003")!
        let inputTileId = UUID(uuidString: "00000000-0000-0000-0000-00000000F002")!
        let inputFrame = TileFrame(x: 40, y: 40, width: 320, height: 240)
        let inputTile = Tile(
            id: inputTileId,
            kind: .note,
            title: "Text undo probe",
            frame: inputFrame,
            zPosition: .fromLegacyRank(1),
            runtimeRef: nil,
            metadata: TileMetadata()
        )
        let inputCanvas = CanvasNSView(canvasState: CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [inputTile],
            groups: [],
            lastActiveTileId: inputTileId
        ))
        let noteView = NoteTileNSView(tile: inputTile, noteId: UUID(), initialBody: "a")
        inputCanvas.install(tileView: noteView, for: inputTile)
        inputCanvas.activateUndoWorkspace(inputWorkspace)
        window.contentView = inputCanvas
        var movedInputTile = inputTile
        movedInputTile.frame.x = 200
        _ = inputCanvas.performGeometryEdit(.moveTile, tileIds: [inputTileId]) {
            inputCanvas.updateTile(movedInputTile, recalculateZoneBounds: false, notifyChange: false)
        }
        try expect(inputCanvas.activeCanvasUndoManager?.canUndo == true, "setup should leave a canvas edit available")
        try expect(window.makeFirstResponder(noteView.textView), "note editor should accept first responder")
        noteView.textView.setSelectedRange(NSRange(location: 1, length: 0))
        noteView.textView.insertText("b", replacementRange: noteView.textView.selectedRange())
        noteView.textView.breakUndoCoalescing()
        // Programmatic insertion does not get AppKit's normal end-of-key-event
        // checkpoint in this command-line check, so close that implicit group.
        while let textUndoManager = noteView.textView.undoManager,
              textUndoManager.groupingLevel > 0 {
            textUndoManager.endUndoGrouping()
        }
        try expect(noteView.textView.string == "ab", "setup should insert note text")
        try expect(noteView.textView.undoManager?.canUndo == true, "note input should own a native undo step")
        try expect(noteView.textView.undoManager !== inputCanvas.activeCanvasUndoManager,
                   "text and canvas must use separate undo managers")
        let textUndoWasRouted = window.firstResponder?.tryToPerform(Selector(("undo:")), with: nil) ?? false
        try expect(textUndoWasRouted && noteView.textView.string == "a",
                   "Cmd-Z in a note should undo typing (routed=\(textUndoWasRouted), text=\(noteView.textView.string))")
        try expect(inputCanvas.canvasState.tiles[0].frame == movedInputTile.frame,
                   "text undo must not move or resize the tile")
        try expect(inputCanvas.activeCanvasUndoManager?.canUndo == true,
                   "text undo must leave canvas history available")
        let textRedoWasRouted = window.firstResponder?.tryToPerform(Selector(("redo:")), with: nil) ?? false
        try expect(textRedoWasRouted && noteView.textView.string == "ab", "Cmd-Shift-Z in a note should redo typing")
        try expect(inputCanvas.canvasState.tiles[0].frame == movedInputTile.frame,
                   "text redo must not alter tile geometry")
        try expect(window.makeFirstResponder(inputCanvas), "canvas chrome should regain first responder")
        let canvasUndoWasRouted = window.firstResponder?.tryToPerform(Selector(("undo:")), with: nil) ?? false
        try expect(canvasUndoWasRouted && inputCanvas.canvasState.tiles[0].frame == inputFrame,
                   "Cmd-Z should resume canvas undo after focus leaves the input")
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
        let visualOrder = canvas.tileViewsInVisualOrder.map(\.tile.id)
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

    /// The camera's correctness oracle, swept across pan and zoom.
    ///
    /// Two independent mechanisms answer "which tile is under this point": the
    /// MODEL (`CanvasEngine.hitTest(screenPoint:viewport:tiles:)`, pure geometry
    /// over world rects) and the VIEW TREE (`tileId(at:)` plus AppKit's own paint
    /// order). They must agree at every point and every camera, and today they do.
    ///
    /// This is recorded BEFORE the retained world plane exists, deliberately. The
    /// plane reparents every tile view and makes an ancestor's transform produce
    /// the screen rects that tile frames produce today. That is exactly the class
    /// of change that can leave the model right and the presentation wrong — a
    /// misconfigured bounds scale, a missing `isFlipped`, an unclipped plane — so
    /// the oracle has to exist first, green, in order to mean anything afterwards.
    ///
    /// `--zindex-relaunch-hit-test-check` covers one point at one camera; this
    /// covers a grid across a pan/zoom sweep and adds the paint-order agreement.
    static func runCameraHitOracleSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self { case let .failed(message): return message }
            }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        // Deliberately overlapping tiles at known z, so paint order is decidable
        // and a z-order regression cannot hide behind disjoint rects.
        var seeded: [Tile] = []
        for index in 0..<9 {
            seeded.append(Tile(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000009%02d", index))!,
                kind: .note, title: "oracle-\(index)",
                frame: TileFrame(x: Double(index % 3) * 200 + 60,
                                 y: Double(index / 3) * 150 + 40,
                                 width: 320, height: 240),
                zPosition: .fromLegacyRank(index + 1), runtimeRef: nil, metadata: TileMetadata()
            ))
        }
        let canvas = CanvasNSView(canvasState: CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: seeded,
            groups: [], lastActiveTileId: nil))
        canvas.frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        // A real window host, because AppKit's `hitTest` is only meaningful for a
        // view that is actually in a hierarchy — this mirrors the production path,
        // which hit-tests through the window's `contentView`.
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        for tile in seeded {
            canvas.install(tileView: DescriptorTileNSView(tile: tile), for: tile)
        }

        // Non-integral zooms are in the sweep on purpose: the camera's last
        // regression was invisible at zoom 1 (docs/internals/performance-budgets.md,
        // "The float-tolerance trap").
        let cameras: [CanvasViewport] = [
            CanvasViewport(x: 0, y: 0, zoom: 1),
            CanvasViewport(x: 137, y: 91, zoom: 1),
            CanvasViewport(x: 0, y: 0, zoom: 0.35),
            CanvasViewport(x: 137, y: 91, zoom: 0.35),
            CanvasViewport(x: -220, y: -160, zoom: 0.7),
            CanvasViewport(x: 480, y: 310, zoom: 1.85)
        ]

        // The point of the exercise. `tileId(at:)` and
        // `CanvasEngine.hitTest(screenPoint:…)` are BOTH pure model derivations
        // from `canvasState`, so agreeing with each other proves nothing about
        // presentation — that is the "a witness that re-derives what production
        // derives" trap in AGENTS.md. AppKit's own `hitTest` is the independent
        // third mechanism: it walks the real view tree and answers from actual
        // view geometry, which is what a misconfigured world plane would break.
        /// Which tile view actually covers this canvas point, decided from the
        /// INSTALLED view geometry in real paint order (front to back) using
        /// AppKit's own coordinate conversion. It never consults
        /// `canvasState.viewport` or `tile.frame`, which is what makes it an
        /// independent answer; and because `convert(_:from:)` walks the whole
        /// ancestor chain, it keeps working when the world plane adds a level and
        /// carries the zoom as a bounds scale.
        ///
        /// Deliberately NOT `canvas.hitTest(_:)`: that takes a point in the
        /// canvas's SUPERVIEW space, and the canvas is flipped while a window's
        /// frame view is not, so feeding it canvas coordinates silently probes a
        /// vertically mirrored location.
        func viewTreeTileId(at point: CGPoint, in canvas: CanvasNSView) -> UUID? {
            for view in canvas.tileViewsInVisualOrder.reversed() {
                guard !view.isHidden else { continue }
                if view.bounds.contains(view.convert(point, from: canvas)) { return view.tile.id }
            }
            return nil
        }

        var comparisons = 0
        var agreements = 0
        var zOrderChecks = 0
        var presentationComparisons = 0
        for camera in cameras {
            canvas.setViewport(camera)
            canvas.layoutSubtreeIfNeeded()

            // Paint order must match the model's (zPosition, id) order at every
            // camera — the camera must never reorder anything.
            let visual = canvas.tileViewsInVisualOrder.map(\.tile.id)
            let expectedOrder = canvas.canvasState.tiles
                .sorted { lhs, rhs in
                    lhs.zPosition.value == rhs.zPosition.value
                        ? lhs.id.uuidString < rhs.id.uuidString
                        : lhs.zPosition.value < rhs.zPosition.value
                }
                .map(\.id)
            try expect(visual == expectedOrder,
                       "paint order must follow the model's z-order at camera \(camera); got \(visual.count) views")
            zOrderChecks += 1

            for screenY in stride(from: 10.0, through: 760.0, by: 50.0) {
                for screenX in stride(from: 10.0, through: 1_160.0, by: 50.0) {
                    let point = CGPoint(x: screenX, y: screenY)
                    let model = CanvasEngine.hitTest(
                        screenPoint: point, viewport: camera, tiles: canvas.canvasState.tiles)?.id
                    let tree = canvas.tileId(at: point)
                    comparisons += 1
                    if model == tree { agreements += 1 }
                    try expect(model == tree,
                               "hit disagreement at \(point) camera \(camera): model \(model?.uuidString ?? "nil") vs canvas \(tree?.uuidString ?? "nil")")
                }
            }

            // The non-vacuous half: interior points, chosen 6 pt inside each
            // tile's EXPECTED screen rect so no answer depends on edge rounding,
            // compared against what AppKit's view tree actually reports. This is
            // the assertion the world plane has to satisfy with a transform
            // instead of per-tile frames.
            for tile in canvas.canvasState.tiles {
                let rect = CanvasEngine.tileScreenFrame(tile.frame, viewport: camera)
                let interior = rect.insetBy(dx: 6, dy: 6)
                guard interior.width > 0, interior.height > 0 else { continue }
                for probe in [CGPoint(x: interior.midX, y: interior.midY),
                              CGPoint(x: interior.minX + 1, y: interior.minY + 1),
                              CGPoint(x: interior.maxX - 1, y: interior.maxY - 1)] {
                    guard canvas.bounds.insetBy(dx: 2, dy: 2).contains(probe) else { continue }
                    let model = CanvasEngine.hitTest(
                        screenPoint: probe, viewport: camera, tiles: canvas.canvasState.tiles)?.id
                    let presented = viewTreeTileId(at: probe, in: canvas)
                    presentationComparisons += 1
                    try expect(model == presented,
                               "presentation disagrees with the model at \(probe) camera \(camera): model \(model?.uuidString ?? "nil") vs view tree \(presented?.uuidString ?? "nil")")
                }
            }
        }

        try expect(comparisons > 1_000, "oracle must sweep a meaningful grid; got \(comparisons) comparisons")
        try expect(agreements == comparisons, "every comparison must agree; \(agreements)/\(comparisons)")
        // Teeth in the other direction: a grid that never lands on a tile would
        // agree trivially at nil == nil.
        let hitsOnTiles = cameras.reduce(0) { partial, camera in
            partial + stride(from: 10.0, through: 760.0, by: 50.0).reduce(0) { inner, y in
                inner + stride(from: 10.0, through: 1_160.0, by: 50.0).reduce(0) { count, x in
                    count + (CanvasEngine.hitTest(screenPoint: CGPoint(x: x, y: y),
                                                  viewport: camera,
                                                  tiles: canvas.canvasState.tiles) == nil ? 0 : 1)
                }
            }
        }
        try expect(hitsOnTiles > 200,
                   "the sweep must actually land on tiles, or nil == nil agrees for free; got \(hitsOnTiles)")
        try expect(presentationComparisons > 60,
                   "the model-vs-view-tree comparison is the only non-vacuous half; got \(presentationComparisons)")

        let manifest: [String: Any] = [
            "check": "canvas-camera-hit-oracle",
            "cameras": cameras.map { ["x": $0.x, "y": $0.y, "zoom": $0.zoom] },
            "comparisons": comparisons,
            "agreements": agreements,
            "hitsOnTiles": hitsOnTiles,
            "presentationComparisons": presentationComparisons,
            "zOrderChecks": zOrderChecks,
            "tiles": seeded.count
        ]
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent("canvas-camera-hit-oracle-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: artifact, options: .atomic)
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

    /// zone-unify P2 — drag-create registers a memory-only zone (not a ZoneLayer),
    /// asks for project/Home because Notes carry no filesystem scope, and adopts
    /// enclosed bare tiles only after that scope is confirmed. World positions and
    /// clickability survive the commit.
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
        // This check pins the legacy adoption contract. Auto-layout-on spawn
        // behavior is exercised by runJellyAutoLayoutSelfCheck instead.
        defaults.set(false, forKey: CanvasAutoLayoutConfig.enabledKey)
        canvas.autoLayoutDefaults = defaults
        defer { defaults.removePersistentDomain(forName: suite) }

        try expect(canvas.qaZoneMembership(of: in1Id) == nil && canvas.qaZoneMembership(of: outId) == nil, "pre-create: all tiles bare")

        var created: [ZonePlacement] = []
        canvas.onZoneCreated = { created.append($0) }
        let selectedProjectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000C0")!
        var scopeRequests = 0
        canvas.onZoneScopeRequired = { placement, _ in
            scopeRequests += 1
            canvas.commitProvisionalZone(
                zoneId: placement.zoneId,
                projectId: selectedProjectId,
                homeRelativePath: nil,
                scopeLabel: "Fixture / Project Root"
            )
        }

        // Marquee canvas-local (100,100)→(400,300) ⇒ origin (100,100), size (300,200).
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: win(100, 100, canvasH: cH), window: window))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: win(400, 300, canvasH: cH), window: window))
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: win(400, 300, canvasH: cH), window: window))

        // 1. exactly one live zone (not a ZoneLayer).
        try expect(canvas.qaLiveZoneIds.count == 1, "exactly one live zone created; got \(canvas.qaLiveZoneIds.count)")
        try expect(canvas.installedZoneLayerIds.isEmpty, "create must not install a ZoneLayer")
        let zoneId = canvas.qaLiveZoneIds[0]
        try expect(scopeRequests == 1, "blank/non-filesystem enclosure must request project/Home exactly once; got \(scopeRequests)")
        try expect(created.count == 1, "onZoneCreated fired exactly once; got \(created.count)")
        try expect(created[0].projectId == selectedProjectId && created[0].homeRelativePath == nil, "confirmed zone did not carry the atomic project/root-Home scope")
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
            "projectId": selectedProjectId.uuidString,
            "scopeRequests": scopeRequests,
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
        noSnap.set(false, forKey: CanvasAutoLayoutConfig.enabledKey)
        canvas.dragMagnetizeDefaults = noSnap
        canvas.autoLayoutDefaults = noSnap
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
        let legacySuite = "zone-resize-legacy-\(UUID().uuidString)"
        let legacyDefaults = UserDefaults(suiteName: legacySuite)!
        legacyDefaults.set(false, forKey: CanvasAutoLayoutConfig.enabledKey)
        canvas.autoLayoutDefaults = legacyDefaults
        defer { legacyDefaults.removePersistentDomain(forName: legacySuite) }
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

    static func runJellyAutoLayoutSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String { switch self { case let .failed(message): return message } }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }
        func win(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: 700 - y) }
        func event(_ type: NSEvent.EventType, _ point: NSPoint, window: NSWindow) throws -> NSEvent {
            guard let value = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1) else { throw CheckError.failed("could not synthesize \(type)") }
            return value
        }
        func drag(_ canvas: CanvasNSView, from: NSPoint, to: NSPoint, window: NSWindow) throws {
            canvas.mouseDown(with: try event(.leftMouseDown, from, window: window))
            canvas.mouseDragged(with: try event(.leftMouseDragged, to, window: window))
            canvas.mouseUp(with: try event(.leftMouseUp, to, window: window))
        }
        func dragTile(_ view: TileNSView, worldDX: Double, worldDY: Double, window: NSWindow) throws {
            let start = view.convert(NSPoint(x: view.bounds.midX, y: TileNSView.titleBarHeight / 2), to: nil)
            let end = NSPoint(x: start.x + CGFloat(worldDX), y: start.y - CGFloat(worldDY))
            view.mouseDown(with: try event(.leftMouseDown, start, window: window))
            view.mouseDragged(with: try event(.leftMouseDragged, end, window: window))
            view.mouseUp(with: try event(.leftMouseUp, end, window: window))
        }
        func resizeTileRight(_ view: TileNSView, worldDX: Double, window: NSWindow) throws {
            let start = view.convert(NSPoint(x: view.bounds.maxX - 1, y: view.bounds.midY), to: nil)
            let end = NSPoint(x: start.x + CGFloat(worldDX), y: start.y)
            view.mouseDown(with: try event(.leftMouseDown, start, window: window))
            view.mouseDragged(with: try event(.leftMouseDragged, end, window: window))
            view.mouseUp(with: try event(.leftMouseUp, end, window: window))
        }

        let zoneId = UUID(uuidString: "A1300000-0000-4000-8000-000000000001")!
        let firstId = UUID(uuidString: "A1300000-0000-4000-8000-000000000011")!
        let secondId = UUID(uuidString: "A1300000-0000-4000-8000-000000000012")!
        let bareId = UUID(uuidString: "A1300000-0000-4000-8000-000000000013")!
        let zone = ZonePlacement(
            zoneId: zoneId, projectId: nil, origin: ZonePoint(x: 100, y: 100),
            size: ZoneSize(width: 232, height: 120), color: "teal", collapsed: false,
            hydrationPolicy: .automatic, name: "Jelly", navKey: nil)
        let tiles = [
            Tile(id: firstId, kind: .note, title: "A", frame: TileFrame(x: 108, y: 140, width: 100, height: 72), zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata()),
            Tile(id: secondId, kind: .note, title: "B", frame: TileFrame(x: 216, y: 140, width: 100, height: 72), zPosition: .fromLegacyRank(2), runtimeRef: nil, metadata: TileMetadata()),
            Tile(id: bareId, kind: .note, title: "Bare", frame: TileFrame(x: 340, y: 140, width: 80, height: 72), zPosition: .fromLegacyRank(3), runtimeRef: nil, metadata: TileMetadata()),
        ]
        let canvas = CanvasNSView(
            canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: tiles, groups: [], lastActiveTileId: nil),
            activeZone: zone, zoneRenderModels: [ZoneRenderModel(placement: zone, displayName: "Jelly")], showsZoneChrome: true)
        let suite = "jelly-layout-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: CanvasAutoLayoutConfig.enabledKey)
        defaults.set(false, forKey: DragMagnetizeConfig.enabledKey)
        defaults.set(8.0, forKey: TileGapResolver.userDefaultsKey)
        defaults.set(8.0, forKey: ZoneBoundsConfig.paddingKey)
        canvas.autoLayoutDefaults = defaults
        canvas.dragMagnetizeDefaults = defaults
        canvas.resizeHUDDefaults = defaults
        canvas.autoLayoutReduceMotionProvider = { true }
        canvas.activateUndoWorkspace(UUID(uuidString: "A1300000-0000-4000-8000-000000000099")!)
        defer { defaults.removePersistentDomain(forName: suite) }
        canvas.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontRegardless()
        for tile in tiles { canvas.install(tileView: DescriptorTileNSView(tile: tile), for: tile) }
        canvas.layoutSubtreeIfNeeded()

        var commits: [CanvasLayoutTransaction] = []
        canvas.onLayoutCommitted = { commits.append($0); return true }
        try drag(canvas, from: win(332, 190), to: win(304, 190), window: window)
        try expect(commits.count == 1, "one zone-resize gesture must commit one transaction; got \(commits.count)")
        guard let squeezed = canvas.qaLiveZonePlacement(zoneId) else { throw CheckError.failed("zone disappeared") }
        try expect(squeezed.size.width >= 200 && squeezed.size.width <= 205,
                   "zone should stop at feasible fixed-size packing; got \(squeezed.size.width)")
        let first = canvas.canvasState.tiles.first { $0.id == firstId }!.frame
        let second = canvas.canvasState.tiles.first { $0.id == secondId }!.frame
        try expect(first.width == 100 && second.width == 100 && first.x + first.width <= second.x,
                   "squeeze must preserve tile dimensions and avoid overlap")
        try expect(canvas.qaZoneMembership(of: firstId) == zoneId && canvas.qaZoneMembership(of: secondId) == zoneId,
                   "solver displacement must not change membership")

        let squeezedRight = squeezed.origin.x + squeezed.size.width
        try drag(canvas, from: win(squeezedRight, 190), to: win(450, 190), window: window)
        try expect(commits.count == 2, "the expansion gesture must add exactly one final commit")
        let expanded = canvas.qaLiveZonePlacement(zoneId)!
        let restoredA = canvas.canvasState.tiles.first { $0.id == firstId }!.frame
        let restoredB = canvas.canvasState.tiles.first { $0.id == secondId }!.frame
        try expect(abs(restoredB.x - restoredA.x - restoredA.width - 8) < 0.1,
                   "expansion must restore the configured tile gap; A=\(restoredA), B=\(restoredB), zone=\(expanded)")
        let pushedBare = canvas.canvasState.tiles.first { $0.id == bareId }!.frame
        try expect(pushedBare.x >= expanded.origin.x + expanded.size.width + 8,
                   "expanding a zone must push a bare tile through the external rigid-body solver")

        let zoneBeforeEntry = canvas.qaLiveZonePlacement(zoneId)!
        guard let bareView = canvas.tileView(for: bareId) else { throw CheckError.failed("bare tile view disappeared") }
        try dragTile(bareView, worldDX: 120 - pushedBare.x, worldDY: 140 - pushedBare.y, window: window)
        try expect(canvas.qaZoneMembership(of: bareId) == zoneId,
                   "auto layout must allow a directly dragged bare tile to enter and join a zone")
        let zoneAfterEntry = canvas.qaLiveZonePlacement(zoneId)!
        try expect(abs(zoneAfterEntry.origin.x - zoneBeforeEntry.origin.x) <= 8
                       && abs(zoneAfterEntry.origin.y - zoneBeforeEntry.origin.y) <= 8,
                   "a tile entering a zone must not push the destination zone away; before=\(zoneBeforeEntry), after=\(zoneAfterEntry)")
        try expect(commits.count == 3, "zone entry must add one final geometry transaction")
        let adoptedFrames = canvas.canvasState.tiles.filter { canvas.qaZoneMembership(of: $0.id) == zoneId }.map(\.frame)
        for (index, frame) in adoptedFrames.enumerated() {
            try expect(!adoptedFrames.dropFirst(index + 1).contains { other in
                frame.x < other.x + other.width && frame.x + frame.width > other.x
                    && frame.y < other.y + other.height && frame.y + frame.height > other.y
            }, "adoption must reflow destination members around the directly dropped tile")
        }

        let rightClick = try event(.rightMouseDown, win(160, 115), window: window)
        let zoneMenu = canvas.menu(for: rightClick)
        try expect(zoneMenu?.items.contains(where: { $0.title == "Tidy Zone Now" }) == true,
                   "zone header context menu must expose Tidy Zone Now")
        try expect(zoneMenu?.items.first(where: { $0.title == "Auto Layout" })?.submenu?.items.map(\.title) == ["Use Global", "On", "Off"],
                   "zone menu must expose all override states")
        canvas.setZoneAutoLayoutMode(.disabled, zoneId: zoneId)
        try expect(canvas.qaLiveZonePlacement(zoneId)?.autoLayoutMode == .disabled,
                   "per-zone Off override must update the live persisted placement")
        canvas.setZoneAutoLayoutMode(.enabled, zoneId: zoneId)

        if let index = canvas.canvasState.tiles.firstIndex(where: { $0.id == secondId }) {
            canvas.canvasState.tiles[index].frame.x = restoredA.x
        }
        canvas.layoutAllTiles()
        canvas.tidyAutoLayout()
        try expect(canvas.qaAutoLayoutUndoText.contains("Auto layout arranged") && canvas.qaAutoLayoutUndoText.contains("Undo"),
                   "explicit Tidy must show the six-second Undo notice")
        try expect(canvas.qaClickAutoLayoutUndo(), "Tidy Undo must be actionable")
        try expect(canvas.canvasState.tiles.first { $0.id == secondId }!.frame.x == restoredA.x,
                   "Undo must restore the exact captured pre-tidy frame")
        let durableFrames = Dictionary(uniqueKeysWithValues: canvas.canvasState.tiles.map { ($0.id, $0.frame) })
        canvas.onLayoutCommitted = { _ in false }
        canvas.tidyAutoLayout()
        try expect(Dictionary(uniqueKeysWithValues: canvas.canvasState.tiles.map { ($0.id, $0.frame) }) == durableFrames,
                   "a rejected cross-store transaction must restore the last durable geometry")

        // The production multi-zone representation stores member frames locally
        // in ZoneLayer. Drive a real right-edge resize through TileNSView and prove
        // that the same world solver moves and shrinks its neighbor before the
        // zone itself needs to expand.
        let layerZoneId = UUID(uuidString: "A1300000-0000-4000-8000-000000000021")!
        let layerFirstId = UUID(uuidString: "A1300000-0000-4000-8000-000000000022")!
        let layerSecondId = UUID(uuidString: "A1300000-0000-4000-8000-000000000023")!
        let layerPlacement = ZonePlacement(
            zoneId: layerZoneId, projectId: nil, origin: ZonePoint(x: 100, y: 100),
            size: ZoneSize(width: 624, height: 440), color: "blue", collapsed: false,
            hydrationPolicy: .automatic, name: "Layer Jelly", navKey: nil)
        let layerFirst = Tile(
            id: layerFirstId, kind: .note, title: "Layer A",
            frame: TileFrame(x: 8, y: 40, width: 240, height: 300),
            zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        let layerSecond = Tile(
            id: layerSecondId, kind: .note, title: "Layer B",
            frame: TileFrame(x: 256, y: 40, width: 360, height: 300),
            zPosition: .fromLegacyRank(2), runtimeRef: nil, metadata: TileMetadata())
        let layerCanvas = CanvasNSView(
            canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil),
            showsZoneChrome: true)
        layerCanvas.autoLayoutDefaults = defaults
        layerCanvas.dragMagnetizeDefaults = defaults
        layerCanvas.autoLayoutReduceMotionProvider = { true }
        layerCanvas.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let layerWindow = NSWindow(contentRect: layerCanvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        layerWindow.contentView = layerCanvas
        layerWindow.orderFrontRegardless()
        let layerFirstView = DescriptorTileNSView(tile: layerFirst)
        let layerSecondView = DescriptorTileNSView(tile: layerSecond)
        let layer = ZoneLayer(
            placement: layerPlacement,
            renderModel: ZoneRenderModel(placement: layerPlacement, displayName: "Layer Jelly"),
            tiles: [layerFirst, layerSecond])
        layer.tileViews[layerFirstId] = layerFirstView
        layer.tileViews[layerSecondId] = layerSecondView
        layerCanvas.upsertZoneLayer(layer)
        layerCanvas.layoutSubtreeIfNeeded()
        var layerCommits: [CanvasLayoutTransaction] = []
        layerCanvas.onLayoutCommitted = { layerCommits.append($0); return true }
        try resizeTileRight(layerFirstView, worldDX: 120, window: layerWindow)
        guard let resizedLayerTiles = layerCanvas.tiles(inZone: layerZoneId),
              let resizedLayerFirst = resizedLayerTiles.first(where: { $0.id == layerFirstId })?.frame,
              let resizedLayerSecond = resizedLayerTiles.first(where: { $0.id == layerSecondId })?.frame,
              let resizedLayerZone = layerCanvas.qaZoneLayerPlacement(for: layerZoneId) else {
            throw CheckError.failed("ZoneLayer resize lost its live model")
        }
        try expect(resizedLayerFirst.width == 360,
                   "direct ZoneLayer resize must preserve the requested tile width; got \(resizedLayerFirst.width)")
        try expect(resizedLayerSecond.x >= resizedLayerFirst.x + resizedLayerFirst.width,
                   "an in-zone neighbor must move away from the resized tile instead of overlapping; active=\(resizedLayerFirst), neighbor=\(resizedLayerSecond), zone=\(resizedLayerZone)")
        try expect(resizedLayerSecond.width < layerSecond.frame.width
                       && resizedLayerSecond.width >= TileGeometry.minimumSize(for: .note).width,
                   "after gaps reach zero, resize pressure must shrink the neighbor toward its minimum")
        try expect(resizedLayerZone.size.width == layerPlacement.size.width,
                   "the zone must stay fixed while neighbor shrink capacity can absorb the resize")
        try expect(layerCommits.count == 1,
                   "one ZoneLayer tile resize must produce one final geometry transaction")

        // Spawn a third member beyond the old right edge, then swap the middle
        // member into the left member's slot through a real title-bar drag.
        let swapZoneId = UUID(uuidString: "A1300000-0000-4000-8000-000000000031")!
        let swapLeftId = UUID(uuidString: "A1300000-0000-4000-8000-000000000032")!
        let swapMiddleId = UUID(uuidString: "A1300000-0000-4000-8000-000000000033")!
        let swapRightId = UUID(uuidString: "A1300000-0000-4000-8000-000000000034")!
        let swapZone = ZonePlacement(
            zoneId: swapZoneId, projectId: nil, origin: ZonePoint(x: 100, y: 100),
            size: ZoneSize(width: 664, height: 500), color: "teal", collapsed: false,
            hydrationPolicy: .automatic, name: "Swap Jelly", navKey: nil)
        let swapLeft = Tile(
            id: swapLeftId, kind: .managedAgent, title: "Left",
            frame: TileFrame(x: 108, y: 140, width: 260, height: 220),
            zPosition: .fromLegacyRank(1), zoneId: swapZoneId, runtimeRef: nil, metadata: TileMetadata())
        let swapMiddle = Tile(
            id: swapMiddleId, kind: .managedAgent, title: "Middle",
            frame: TileFrame(x: 376, y: 140, width: 340, height: 260),
            zPosition: .fromLegacyRank(2), zoneId: swapZoneId, runtimeRef: nil, metadata: TileMetadata())
        let swapCanvas = CanvasNSView(
            canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [swapLeft, swapMiddle], groups: [], lastActiveTileId: nil),
            activeZone: swapZone, zoneRenderModels: [ZoneRenderModel(placement: swapZone, displayName: "Swap Jelly")],
            showsZoneChrome: true)
        swapCanvas.autoLayoutDefaults = defaults
        swapCanvas.dragMagnetizeDefaults = defaults
        swapCanvas.autoLayoutReduceMotionProvider = { true }
        swapCanvas.frame = NSRect(x: 0, y: 0, width: 1_300, height: 700)
        let swapWindow = NSWindow(contentRect: swapCanvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        swapWindow.contentView = swapCanvas
        swapWindow.orderFrontRegardless()
        let swapLeftView = DescriptorTileNSView(tile: swapLeft)
        let swapMiddleView = DescriptorTileNSView(tile: swapMiddle)
        swapCanvas.install(tileView: swapLeftView, for: swapLeft)
        swapCanvas.install(tileView: swapMiddleView, for: swapMiddle)
        var swapCommits: [CanvasLayoutTransaction] = []
        swapCanvas.onLayoutCommitted = { swapCommits.append($0); return true }
        let swapRight = Tile(
            id: swapRightId, kind: .managedAgent, title: "Spawned",
            frame: TileFrame(x: 724, y: 140, width: 300, height: 240),
            zPosition: .fromLegacyRank(3), zoneId: swapZoneId, runtimeRef: nil, metadata: TileMetadata())
        swapCanvas.install(tileView: DescriptorTileNSView(tile: swapRight), for: swapRight)
        swapCanvas.arrangeAutoLayoutAfterSpawn(zoneId: swapZoneId)
        let expandedSwapZone = swapCanvas.qaLiveZonePlacement(swapZoneId)!
        let spawnedFrame = swapCanvas.canvasState.tiles.first { $0.id == swapRightId }!.frame
        try expect(expandedSwapZone.origin.x + expandedSwapZone.size.width >= spawnedFrame.x + spawnedFrame.width + 8,
                   "adding a member must expand its zone to contain the tile with configured padding")
        let preSwapZone = expandedSwapZone
        let preSwapLeft = swapCanvas.canvasState.tiles.first { $0.id == swapLeftId }!.frame
        let preSwapMiddle = swapCanvas.canvasState.tiles.first { $0.id == swapMiddleId }!.frame
        try dragTile(
            swapMiddleView,
            worldDX: (preSwapLeft.x + preSwapLeft.width / 2) - (preSwapMiddle.x + preSwapMiddle.width / 2) - 4,
            worldDY: 12,
            window: swapWindow)
        let postSwapLeft = swapCanvas.canvasState.tiles.first { $0.id == swapLeftId }!.frame
        let postSwapMiddle = swapCanvas.canvasState.tiles.first { $0.id == swapMiddleId }!.frame
        try expect(postSwapMiddle.x == preSwapLeft.x && postSwapMiddle.y == preSwapLeft.y,
                   "horizontal swap must claim the left slot without following vertical pointer jitter")
        try expect(postSwapLeft.x == preSwapLeft.x + preSwapMiddle.width + 8 && postSwapLeft.y == preSwapLeft.y,
                   "unequal tiles must exchange row order without a diagonal reflow")
        try expect(swapCanvas.qaLiveZonePlacement(swapZoneId) == preSwapZone,
                   "a valid member swap must not move or resize the zone")
        try expect(swapCommits.count == 2,
                   "spawn arrangement and slot swap must each commit exactly once")

        // Appending to an edge: drag the right member so it attaches gap-flush
        // BELOW the (post-swap) middle tile, sticking out past the zone's
        // bottom edge. The zone must GROW to absorb the appended member — the
        // member keeps its appended slot and its membership; it is never
        // clamped back inside or reflowed elsewhere.
        let preAppendMiddle = swapCanvas.canvasState.tiles.first { $0.id == swapMiddleId }!.frame
        let preAppendRight = swapCanvas.canvasState.tiles.first { $0.id == swapRightId }!.frame
        let appendTarget = TileFrame(
            x: preAppendMiddle.x, y: preAppendMiddle.y + preAppendMiddle.height + 8,
            width: preAppendRight.width, height: preAppendRight.height)
        let preAppendZone = swapCanvas.qaLiveZonePlacement(swapZoneId)!
        try expect(appendTarget.y + appendTarget.height > preAppendZone.origin.y + preAppendZone.size.height,
                   "precondition: the appended slot must stick out past the zone's bottom edge")
        guard let appendView = swapCanvas.tileView(for: swapRightId) else {
            throw CheckError.failed("append tile view disappeared")
        }
        try dragTile(
            appendView,
            worldDX: appendTarget.x - preAppendRight.x,
            worldDY: appendTarget.y - preAppendRight.y,
            window: swapWindow)
        let appendedRight = swapCanvas.canvasState.tiles.first { $0.id == swapRightId }!.frame
        try expect(appendedRight == appendTarget,
                   "an appended member keeps its gap-attached slot; wanted \(appendTarget), got \(appendedRight)")
        let grownForAppend = swapCanvas.qaLiveZonePlacement(swapZoneId)!
        try expect(grownForAppend.origin.y + grownForAppend.size.height >= appendedRight.y + appendedRight.height + 8,
                   "the zone must grow to absorb a member appended past its edge; zone=\(grownForAppend), member=\(appendedRight)")
        try expect(swapCanvas.qaZoneMembership(of: swapRightId) == swapZoneId,
                   "an appended member keeps its zone membership")
        try expect(swapCommits.count == 3,
                   "the append gesture must add exactly one final commit")

        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent("jelly-auto-layout-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let artifact = root.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: [
            "check": "jelly-auto-layout", "transactions": commits.count,
            "minimumWidth": squeezed.size.width, "expandedWidth": expanded.size.width,
            "reduceMotion": true, "zoneLayerResizeCommits": layerCommits.count,
            "spawnAndSwapCommits": swapCommits.count,
        ], options: [.sortedKeys]).write(to: artifact, options: .atomic)
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

        // The zone body/header must be clipped to the same rounded outline that
        // is stroked. A rectangular `headerRect.fill()` used to paint square teal
        // pixels through the rounded top corners. Render the real chrome view on
        // transparency: an interior header pixel is present, while the extreme
        // top-right corner stays clear outside the rounded path.
        guard let alphaChrome = canvas.zoneChromeViews[alphaZoneId],
              let alphaRep = alphaChrome.bitmapImageRepForCachingDisplay(in: alphaChrome.bounds) else {
            throw CheckError.failed("zone rounded-clip probe could not create a bitmap")
        }
        alphaChrome.cacheDisplay(in: alphaChrome.bounds, to: alphaRep)
        let cornerX = max(0, alphaRep.pixelsWide - 2)
        let cornerY = min(max(0, alphaRep.pixelsHigh - 1), 1)
        let interiorX = max(0, alphaRep.pixelsWide - 24)
        let interiorY = min(max(0, alphaRep.pixelsHigh - 1), 16)
        guard let cornerColor = alphaRep.colorAt(x: cornerX, y: cornerY)?.usingColorSpace(.deviceRGB),
              let interiorColor = alphaRep.colorAt(x: interiorX, y: interiorY)?.usingColorSpace(.deviceRGB) else {
            throw CheckError.failed("zone rounded-clip probe could not read rendered pixels")
        }
        let roundedCornerAlpha = cornerColor.alphaComponent
        let interiorHeaderAlpha = interiorColor.alphaComponent
        try expect(interiorHeaderAlpha > 0.05, "zone rounded-clip probe did not render an interior header pixel (alpha \(interiorHeaderAlpha))")
        try expect(roundedCornerAlpha < interiorHeaderAlpha * 0.25, "zone header/background escaped the rounded top-right clip (corner alpha \(roundedCornerAlpha), interior alpha \(interiorHeaderAlpha))")

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
        let subviewTileIds = layerCanvas.tileViewsInVisualOrder.map(\.tile.id)
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
            "roundedClip": [
                "cornerAlpha": roundedCornerAlpha,
                "interiorHeaderAlpha": interiorHeaderAlpha,
                "cornerToInteriorAlphaRatio": roundedCornerAlpha / interiorHeaderAlpha
            ],
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
        // P1.8: the title bar's private lowercase label map is gone; the label
        // is `StatusChipPresenter`'s, shared with the sidebar, board and phone.
        try expect(workingChrome?.agentStatusLabel == "Working", "working agent tile should expose working label")
        try expect(needsChrome?.agentStatus == .needsAttention, "needs-attention agent tile should expose needs-attention badge state")
        try expect(needsChrome?.agentStatusLabel == "Needs attention", "needs-attention agent tile should expose needs-you label")
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
        var observedContentTops: [String: Double] = [:]
        var barMeetsContent: [String: Bool] = [:]
        // The content inset is zoom-independent, so a camera zoom must NEVER
        // re-frame the body. This used to hold only while the floored bar height
        // happened to sit still (the zoomed-IN regime) because the inset was
        // aliased to that floor; decoupling them makes the guarantee
        // unconditional, which is what keeps a zoom step off the document's
        // layout path entirely.
        for zoom in zooms {
            canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: zoom))
            tileView.probe.setFrameSizeCalls = 0
            tileView.layoutSubtreeIfNeeded()
            try expect(tileView.probe.setFrameSizeCalls == 0, "content setFrameSize calls during zoom \(zoom) should be zero, got \(tileView.probe.setFrameSizeCalls) sizes=\(tileView.probe.observedSizes)")
            // Both sides are read from the LAID-OUT views, not re-derived from the
            // same properties production lays them out with.
            let contentTop = tileView.contentView?.frame.minY ?? -1
            observedContentTops[String(zoom)] = Double(contentTop)
            // The bar may now overlap the body at low zoom, but it must still reach
            // it: a bar that stopped short would leave an unpainted strip.
            let barBottom = tileView.qaTitleBarFrame.maxY
            barMeetsContent[String(zoom)] = barBottom >= contentTop - 0.001
            try expect(barMeetsContent[String(zoom)] == true, "title bar bottom \(barBottom) must meet or overlap content top \(contentTop) at zoom \(zoom)")
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
        try expect(barMeetsContent.values.allSatisfy { $0 }, "title bar must meet or overlap the body at every zoom: \(barMeetsContent)")
        // The invariance itself, measured across the sweep rather than compared to
        // the property production lays the body out with. Re-aliasing the inset to
        // the bar floor makes these three values diverge and fails here.
        let distinctContentTops = Set(observedContentTops.values.map { ($0 * 1000).rounded() })
        try expect(distinctContentTops.count == 1, "content top must not vary with zoom: \(observedContentTops)")

        let manifest: [String: Any] = [
            "check": "tile-world-bounds",
            "worldSize": ["width": tile.frame.width, "height": tile.frame.height],
            "zooms": zooms,
            "screenFrames": frames,
            "bounds": bounds,
            "contentSetFrameSizeCallsAfterInstall": callsAfterInstall,
            "resizeEdgePasses": edgePasses,
            "resizeCornerPasses": cornerPasses,
            "contentTopsByZoom": observedContentTops,
            "barMeetsContent": barMeetsContent
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
            func productionHit(atLocal localPoint: CGPoint) throws -> NSView? {
                // Exercise the complete AppKit route: canvas.hitTest receives a
                // point in the CANVAS SUPERVIEW's coordinates, then recursively
                // calls TileNSView.hitTest with a canvas-coordinate point. This is
                // the production contract documented by NSView.hitTest(_:), not a
                // direct helper call tailored to TileNSView's implementation.
                guard let canvasSuperview = ringCanvas.superview else {
                    throw CheckError.failed("ring probe canvas was not installed in a window view hierarchy")
                }
                let canvasLocal = ringView.convert(localPoint, to: ringCanvas)
                let canvasSuperviewPoint = ringCanvas.convert(canvasLocal, to: canvasSuperview)
                return ringCanvas.hitTest(canvasSuperviewPoint)
            }
            for (name, p) in ringProbes {
                try expect(ringView.qaResizeEdge(at: p) != nil, "ring probe \(name) must sit on the resize ring (local-coords premise); got nil at \(p)")
                ringReclaim[name] = try productionHit(atLocal: p) === ringView
            }
            // A deep-body point must still reach the content view (we didn't over-claim).
            let bodyPoint = CGPoint(x: w / 2, y: (ringView.grabHeightInLocalCoordinates + (h - rm)) / 2)
            try expect(ringView.qaResizeEdge(at: bodyPoint) == nil, "body probe must be off the ring; got \(String(describing: ringView.qaResizeEdge(at: bodyPoint)))")
            ringBodyReclaimed = try productionHit(atLocal: bodyPoint) === ringView
        }
        try expect(ringReclaim.values.allSatisfy { $0 == true }, "a panned/zoomed tile must reclaim the resize ring from body content on every edge/corner: \(ringReclaim)")
        try expect(ringBodyReclaimed == false, "a deep-body click must reach content, not be reclaimed by the tile as a resize/move")

        // Cmd-drag and canvas-owned Space-drag are camera gestures even when the
        // press lands on a tile's resize ring. Verify that the full canvas hit-test
        // route selects TileNSView, then drive that production handler lifecycle:
        // modifier precedence must preserve the tile frame and pan the viewport.
        var pointerPanProductionHitRoutedToTile = false
        var commandPanPreservedTileFrame = false
        var commandPanChangedViewport = false
        var spacePanPreservedTileFrame = false
        var spacePanChangedViewport = false
        var cornerResizeProductionPasses: [String: Bool] = [:]
        do {
            let pointerProbe = Tile(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000011C1")!,
                kind: .note,
                title: "POINTER_PAN_PROBE",
                frame: TileFrame(x: 260, y: 180, width: 320, height: 240),
                zPosition: .fromLegacyRank(1),
                runtimeRef: nil,
                metadata: TileMetadata()
            )
            let initialViewport = CanvasViewport(x: 40, y: 25, zoom: 1.5)
            let pointerCanvas = CanvasNSView(canvasState: CanvasState(
                viewport: initialViewport,
                tiles: [pointerProbe],
                groups: [],
                lastActiveTileId: pointerProbe.id
            ))
            pointerCanvas.frame = NSRect(x: 0, y: 0, width: 1200, height: 900)
            let pointerWindow = NSWindow(contentRect: pointerCanvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            pointerWindow.contentView = pointerCanvas
            pointerWindow.orderFrontRegardless()
            let pointerView = TileNSView(tile: pointerProbe)
            pointerCanvas.install(tileView: pointerView, for: pointerProbe)
            pointerView.setContentView(NSView(frame: .zero))
            pointerCanvas.layoutSubtreeIfNeeded()

            func mouse(_ type: NSEvent.EventType, at point: CGPoint, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
                guard let event = NSEvent.mouseEvent(
                    with: type,
                    location: point,
                    modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: pointerWindow.windowNumber,
                    context: nil,
                    eventNumber: 1,
                    clickCount: 1,
                    pressure: 1
                ) else { throw CheckError.failed("could not synthesize pointer-pan mouse event") }
                return event
            }
            func spaceKey(_ type: NSEvent.EventType) throws -> NSEvent {
                guard let event = NSEvent.keyEvent(
                    with: type,
                    location: .zero,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: pointerWindow.windowNumber,
                    context: nil,
                    characters: " ",
                    charactersIgnoringModifiers: " ",
                    isARepeat: false,
                    keyCode: 49
                ) else { throw CheckError.failed("could not synthesize Space pointer-pan key event") }
                return event
            }
            func runPointerPan(modifiers: NSEvent.ModifierFlags, holdingSpace: Bool) throws -> (preservedTile: Bool, changedViewport: Bool) {
                pointerCanvas.setViewport(initialViewport)
                pointerCanvas.layoutSubtreeIfNeeded()
                let localStart = CGPoint(x: pointerView.bounds.maxX - 1, y: pointerView.bounds.maxY - 1)
                let canvasStart = pointerView.convert(localStart, to: pointerCanvas)
                let windowStart = pointerCanvas.convert(canvasStart, to: nil)
                if holdingSpace { pointerCanvas.keyDown(with: try spaceKey(.keyDown)) }
                let tileFrameBefore = pointerCanvas.canvasState.tiles[0].frame
                let viewportBefore = pointerCanvas.viewport
                pointerView.mouseDown(with: try mouse(.leftMouseDown, at: windowStart, modifiers: modifiers))
                let windowEnd = CGPoint(x: windowStart.x + 36, y: windowStart.y + 18)
                pointerView.mouseDragged(with: try mouse(.leftMouseDragged, at: windowEnd, modifiers: modifiers))
                pointerView.mouseUp(with: try mouse(.leftMouseUp, at: windowEnd, modifiers: modifiers))
                if holdingSpace { pointerCanvas.keyUp(with: try spaceKey(.keyUp)) }
                return (
                    pointerCanvas.canvasState.tiles[0].frame == tileFrameBefore,
                    pointerCanvas.viewport != viewportBefore
                )
            }

            let localStart = CGPoint(x: pointerView.bounds.maxX - 1, y: pointerView.bounds.maxY - 1)
            let canvasStart = pointerView.convert(localStart, to: pointerCanvas)
            guard let canvasSuperview = pointerCanvas.superview else {
                throw CheckError.failed("pointer-pan canvas was not installed in a window view hierarchy")
            }
            let canvasSuperviewStart = pointerCanvas.convert(canvasStart, to: canvasSuperview)
            pointerPanProductionHitRoutedToTile = pointerCanvas.hitTest(canvasSuperviewStart) === pointerView

            let commandResult = try runPointerPan(modifiers: [.command], holdingSpace: false)
            commandPanPreservedTileFrame = commandResult.preservedTile
            commandPanChangedViewport = commandResult.changedViewport
            let spaceResult = try runPointerPan(modifiers: [], holdingSpace: true)
            spacePanPreservedTileFrame = spaceResult.preservedTile
            spacePanChangedViewport = spaceResult.changedViewport

            // Route and execute an actual resize gesture from every corner. The
            // prior edge/classifier checks alone could all pass while AppKit still
            // delivered a bottom-corner press to body content. Reset the same
            // panned/zoomed tile before each drag and require the expected anchored
            // origin plus growth on both axes.
            let cornerDrags: [(name: String, localStart: (TileNSView) -> CGPoint, windowDelta: CGPoint, movesLeft: Bool, movesTop: Bool)] = [
                ("topLeft", { _ in CGPoint(x: 1, y: 1) }, CGPoint(x: -30, y: 18), true, true),
                ("topRight", { CGPoint(x: $0.bounds.maxX - 1, y: 1) }, CGPoint(x: 30, y: 18), false, true),
                ("bottomLeft", { CGPoint(x: 1, y: $0.bounds.maxY - 1) }, CGPoint(x: -30, y: -18), true, false),
                ("bottomRight", { CGPoint(x: $0.bounds.maxX - 1, y: $0.bounds.maxY - 1) }, CGPoint(x: 30, y: -18), false, false)
            ]
            for corner in cornerDrags {
                pointerCanvas.updateTile(pointerProbe)
                pointerCanvas.setViewport(initialViewport)
                pointerCanvas.layoutSubtreeIfNeeded()
                let local = corner.localStart(pointerView)
                let canvasPoint = pointerView.convert(local, to: pointerCanvas)
                let superPoint = pointerCanvas.convert(canvasPoint, to: canvasSuperview)
                guard pointerCanvas.hitTest(superPoint) === pointerView else {
                    cornerResizeProductionPasses[corner.name] = false
                    continue
                }
                let windowStart = pointerCanvas.convert(canvasPoint, to: nil)
                let before = pointerCanvas.canvasState.tiles[0].frame
                pointerView.mouseDown(with: try mouse(.leftMouseDown, at: windowStart, modifiers: []))
                let windowEnd = CGPoint(x: windowStart.x + corner.windowDelta.x, y: windowStart.y + corner.windowDelta.y)
                pointerView.mouseDragged(with: try mouse(.leftMouseDragged, at: windowEnd, modifiers: []))
                pointerView.mouseUp(with: try mouse(.leftMouseUp, at: windowEnd, modifiers: []))
                let after = pointerCanvas.canvasState.tiles[0].frame
                let xPass = corner.movesLeft ? after.x < before.x : after.x == before.x
                let yPass = corner.movesTop ? after.y < before.y : after.y == before.y
                cornerResizeProductionPasses[corner.name] = xPass && yPass
                    && after.width > before.width && after.height > before.height
            }
            pointerWindow.orderOut(nil)
        }
        try expect(pointerPanProductionHitRoutedToTile, "canvas/window hit testing did not route a panned/zoomed bottom-right ring press to TileNSView")
        try expect(commandPanPreservedTileFrame, "Cmd+drag from a selected tile's resize ring resized the tile instead of preserving its frame")
        try expect(commandPanChangedViewport, "Cmd+drag from a selected tile's resize ring did not pan the canvas viewport")
        try expect(spacePanPreservedTileFrame, "Space-drag from a selected tile's resize ring resized the tile instead of preserving its frame")
        try expect(spacePanChangedViewport, "Space-drag from a selected tile's resize ring did not pan the canvas viewport")
        try expect(cornerResizeProductionPasses.count == 4 && cornerResizeProductionPasses.values.allSatisfy { $0 }, "production-routed resize gestures must work from all four corners: \(cornerResizeProductionPasses)")

        let manifest: [String: Any] = [
            "check": "tile-drag-grab",
            "ringReclaim": ringReclaim,
            "pointerPanProductionHitRoutedToTile": pointerPanProductionHitRoutedToTile,
            "commandPanPreservedTileFrame": commandPanPreservedTileFrame,
            "commandPanChangedViewport": commandPanChangedViewport,
            "spacePanPreservedTileFrame": spacePanPreservedTileFrame,
            "spacePanChangedViewport": spacePanChangedViewport,
            "cornerResizeProductionPasses": cornerResizeProductionPasses,
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
        var barMeetsContent: [String: Bool] = [:]
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

            // The content offset is deliberately NOT the floored bar height: it is
            // zoom-independent, so the bar overlaps the body when the floor inflates
            // it rather than reflowing the document. Read the laid-out content
            // view's top edge (world units); the invariance is asserted after the
            // sweep, and the bar must still reach the body at every zoom.
            let contentTop = tileView.contentView?.frame.minY ?? -1
            contentTopWorld[String(zoom)] = contentTop
            barMeetsContent[String(zoom)] = barWorldHeight >= contentTop - 0.001

            try expect(barScreenH >= minUsableScreenPx, "zoom \(zoom): title bar on-screen height \(barScreenH)px must be >= \(minUsableScreenPx)px")
            try expect(closeScreenW >= minUsableScreenPx && closeScreenH >= minUsableScreenPx, "zoom \(zoom): close button on-screen hit size \(closeScreenW)x\(closeScreenH)px must be >= \(minUsableScreenPx)px")
            try expect(barMeetsContent[String(zoom)] == true, "zoom \(zoom): title bar height \(barWorldHeight) must meet or overlap content top \(contentTop) — a bar that stops short leaves an unpainted strip")
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
        // The bar's world height therefore VARIES across this sweep (that is the
        // point of the two assertions above) while the body's top must not move at
        // all. Re-aliasing the inset to the floor makes these values diverge and
        // fails here — which is the teeth for the decoupling.
        let distinctContentTops = Set(contentTopWorld.values.map { ($0 * 1000).rounded() })
        try expect(distinctContentTops.count == 1, "content top must not vary with zoom while the bar floor does: \(contentTopWorld)")

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
            "barMeetsContent": barMeetsContent
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

    /// Camera moves must not re-rasterize tile chrome. `setViewport` says so in a
    /// comment and passes `invalidateTileDisplay: false`, but `layoutTile` also
    /// re-assigns `view.tile` on every event to keep the view's copy current — and
    /// that assignment used to mark the title bar dirty unconditionally, so every
    /// tile redrew its title text on every frame of a trackpad pan. With six agent
    /// tiles open at 120Hz that is ~700 text rasterizations a second for a picture
    /// that did not change.
    ///
    /// Both directions have teeth: a pan must cost ZERO redraws, and a real content
    /// change or a zoom that moves the chrome scale must still cost one — the fix
    /// must suppress redundant work, not correct work.
    static func runCameraChromeRedrawSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String { switch self { case let .failed(m): return m } }
        }
        func expect(_ c: @autoclosure () -> Bool, _ m: String) throws { if !c() { throw CheckError.failed(m) } }

        let canvasH: CGFloat = 700
        func drag(_ x: CGFloat, _ y: CGFloat, window: NSWindow) throws -> NSEvent {
            guard let e = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: x, y: canvasH - y),
                                             modifierFlags: [.command],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1)
            else { throw CheckError.failed("could not synthesize a drag event") }
            return e
        }

        // Three tiles, because the cost being witnessed is per-tile.
        let tiles: [Tile] = (0..<3).map { i in
            Tile(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000CA0\(i)")!,
                kind: .note,
                title: "CAMERA_REDRAW_PROBE_\(i)",
                frame: TileFrame(x: 60 + Double(i) * 340, y: 80, width: 300, height: 220),
                zPosition: .fromLegacyRank(i + 1),
                runtimeRef: nil,
                metadata: TileMetadata()
            )
        }
        let canvas = CanvasNSView(canvasState: CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: tiles, groups: [], lastActiveTileId: nil
        ))
        canvas.frame = NSRect(x: 0, y: 0, width: 1200, height: canvasH)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontRegardless()

        var views: [UUID: TileNSView] = [:]
        for tile in tiles {
            let view = TileNSView(tile: tile)
            view.setContentView(NSView(frame: .zero))
            canvas.install(tileView: view, for: tile)
            views[tile.id] = view
        }
        canvas.layoutSubtreeIfNeeded()

        func counts() -> [UUID: Int] { views.mapValues { $0.qaTitleBarRedrawCount } }
        func delta(_ before: [UUID: Int]) -> Int {
            let now = counts()
            return before.keys.reduce(0) { $0 + ((now[$1] ?? 0) - (before[$1] ?? 0)) }
        }

        // 1. A pure translation sweep through the shared camera funnel. Both the
        //    trackpad `scrollWheel` branch and `continuePointerPan` end here.
        let beforeScroll = counts()
        for step in 0..<60 {
            canvas.setViewport(CanvasViewport(x: Double(step) * 7, y: Double(step) * 3, zoom: 1))
            canvas.layoutSubtreeIfNeeded()
        }
        let scrollDelta = delta(beforeScroll)
        try expect(scrollDelta == 0, "a 60-step camera pan redrew tile chrome \(scrollDelta) times; it must cost none")

        // 2. The same thing through the REAL pointer-pan gesture, so the witness
        //    covers the event path a user actually drives and not just the funnel.
        let beforePan = counts()
        canvas.beginPointerPan(with: try drag(400, 300, window: window))
        for step in 0..<30 {
            canvas.continuePointerPan(with: try drag(400 + CGFloat(step) * 4, 300 + CGFloat(step) * 2, window: window))
            canvas.layoutSubtreeIfNeeded()
        }
        canvas.endPointerPan()
        let panDelta = delta(beforePan)
        try expect(panDelta == 0, "a 30-step Cmd-drag pan redrew tile chrome \(panDelta) times; it must cost none")

        // 3. TEETH: a real title change must still repaint that tile's bar.
        let beforeRename = counts()
        var renamed = tiles[1]
        renamed.title = "CAMERA_REDRAW_PROBE_RENAMED"
        canvas.updateTile(renamed)
        canvas.layoutSubtreeIfNeeded()
        let renameDelta = delta(beforeRename)
        try expect(renameDelta >= 1, "renaming a tile must repaint its chrome; got \(renameDelta) redraws")

        // 4. TEETH: zooming out past the chrome floor changes the bar's world
        //    height, so the title + dots must re-render at the new chrome scale.
        let beforeZoom = counts()
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 0.25))
        canvas.layoutSubtreeIfNeeded()
        let zoomDelta = delta(beforeZoom)
        try expect(zoomDelta >= 1, "zoom crossing the chrome floor must repaint the bar; got \(zoomDelta) redraws")

        let manifest: [String: Any] = [
            "check": "camera-chrome-redraw",
            "tileCount": tiles.count,
            "scrollSweepSteps": 60,
            "scrollSweepRedraws": scrollDelta,
            "pointerPanSteps": 30,
            "pointerPanRedraws": panDelta,
            "renameRedraws": renameDelta,
            "zoomFloorRedraws": zoomDelta
        ]
        let fm = FileManager.default
        let directory = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent("camera-chrome-redraw-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: artifact, options: .atomic)
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

        let beforeVisualOrder = canvas.tileViewsInVisualOrder.map(\.tile.id)
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

        let afterVisualOrder = canvas.tileViewsInVisualOrder.map(\.tile.id)
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
        SettingChangeEvent.post(SettingID(rawValue: FocusBorderConfig.enabledKey))
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
        SettingChangeEvent.post(SettingID(rawValue: FocusBorderConfig.enabledKey))
        try expect(canvas.qaFocusBorderActive, "re-enabling with a custom config shows the overlay live")
        let expectedCustomFrame = viewA.frame.insetBy(dx: -customGap, dy: -customGap)
        try expect(canvas.qaFocusBorderFrame == expectedCustomFrame, "custom gap \(customGap) should outset the overlay by \(customGap); expected \(expectedCustomFrame), got \(String(describing: canvas.qaFocusBorderFrame))")

        // 7) A production workspace tile lives in a ZoneLayer, not the legacy
        //    flat tileViews table. Focusing it must use the same marching-ants
        //    overlay and coordinate conversion.
        let layerZoneId = UUID(uuidString: "00000000-0000-0000-0000-0000000005C0")!
        let layerTileId = UUID(uuidString: "00000000-0000-0000-0000-0000000005C1")!
        let layerTile = Tile(
            id: layerTileId, kind: .note, title: "BORDER_LAYER",
            frame: TileFrame(x: 40, y: 40, width: 240, height: 160),
            zPosition: .fromLegacyRank(1), zoneId: layerZoneId,
            runtimeRef: nil, metadata: TileMetadata()
        )
        let layerPlacement = ZonePlacement(
            zoneId: layerZoneId, projectId: UUID(),
            origin: ZonePoint(x: 80, y: 80), size: ZoneSize(width: 360, height: 240),
            color: "mint", collapsed: false, hydrationPolicy: .automatic
        )
        let layer = ZoneLayer(
            placement: layerPlacement,
            renderModel: ZoneRenderModel(placement: layerPlacement, displayName: "Layer"),
            tiles: [layerTile]
        )
        let layerView = DescriptorTileNSView(tile: layerTile)
        layer.tileViews[layerTileId] = layerView
        canvas.upsertZoneLayer(layer)
        canvas.layoutSubtreeIfNeeded()
        let layerTitlePoint = layerView.convert(
            NSPoint(x: layerView.bounds.midX, y: TileNSView.titleBarHeight / 2), to: nil)
        AppDelegate.routeTileClickFocus(at: layerTitlePoint, in: canvas, focusBroker: focusBroker)
        let expectedLayerFrame = layerView.convert(layerView.bounds, to: canvas)
            .insetBy(dx: -customGap, dy: -customGap)
        try expect(canvas.qaFocusBorderActive, "focusing a ZoneLayer tile must show and animate the focus border")
        try expect(canvas.borderedTileId == layerTileId, "the ZoneLayer tile must become the bordered tile")
        try expect(canvas.qaFocusBorderFrame == expectedLayerFrame,
                   "the focus border must track a ZoneLayer tile in canvas coordinates; expected \(expectedLayerFrame), got \(String(describing: canvas.qaFocusBorderFrame))")

        // 8) Deleting the BORDERED tile must take its overlay with it. Last, because
        //    it destroys A.
        //
        //    Reported from the real canvas as a "dead zone I can see but can't
        //    delete": `removeTile` cleared `borderedTileId` but never re-applied, so
        //    the marching-ants overlay stayed on screen at the deleted tile's frame
        //    with no tile under it to select or remove. It appeared to jump and then
        //    vanish because focusing any other tile re-applies the overlay and MOVES
        //    it. Pre-existing since the feature landed (3647acf).
        //
        //    Asserted through `qaFocusBorderFrame`, which now reads the overlay's real
        //    visibility instead of `borderedTileId` — the old accessor consulted the
        //    very bookkeeping that was wrong, so it reported nil while the rectangle
        //    was plainly on screen. That is why no gate caught this.
        _ = focusBroker.requestFocus(.tile(tileAId), reason: .userClick)
        try expect(canvas.qaFocusBorderActive, "precondition: A is bordered before it is deleted")
        let frameBeforeDelete = canvas.qaFocusBorderFrame
        canvas.removeTile(id: tileAId)
        try expect(canvas.borderedTileId == nil, "removing the bordered tile must clear borderedTileId")
        try expect(
            canvas.qaFocusBorderFrame == nil,
            "removing the bordered tile must HIDE its overlay, not just forget the id — it is stranded at \(String(describing: canvas.qaFocusBorderFrame)) (bordered \(String(describing: frameBeforeDelete)) before the delete), un-selectable because no tile is under it"
        )
        try expect(!canvas.qaFocusBorderActive, "no overlay is active once the bordered tile is gone")

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
            "layerTileId": layerTileId.uuidString,
            "expectedLayerOutsetFrame": rectDict(expectedLayerFrame),
            "frozenSnapshotDistinctColors": metrics.distinctSampledColors,
            "frozenSnapshotSize": ["width": metrics.width, "height": metrics.height],
            "frozenSnapshotIsBlank": metrics.isBlank,
            "screenshots": [screenshot.path]
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    /// The marching ants must march ONLY while the app is active and the ringed
    /// tile is on the viewport.
    ///
    /// An infinite `lineDashPhase` animation is re-rasterized by the RENDER
    /// SERVER every display refresh for as long as the window is on screen —
    /// app activation, key status and the residency flag are all irrelevant to
    /// it. Measured live (2026-08-19): WindowServer held at 17-23% CPU by an
    /// idle, backgrounded Array, and the whole machine chopped on window drags
    /// and space switches; the ants were the dominant cause. The rule: suspended
    /// (app inactive, or later occluded) means the border stays VISIBLE with a
    /// frozen dash phase; off-viewport means hidden entirely. Fixtures that
    /// never post activation notifications see today's behavior byte-for-byte —
    /// the state flips ONLY on the notifications this check posts synthetically
    /// (precedent: UIProbeGeometry posts didResignKey).
    static func runFocusBorderActivationSelfCheck() throws {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String { switch self { case let .failed(m): return m } }
        }
        func expect(_ c: @autoclosure () -> Bool, _ m: String) throws {
            if !c() { throw CheckError.failed(m) }
        }

        let tileAId = UUID(uuidString: "00000000-0000-0000-0000-0000000006A1")!
        let tileBId = UUID(uuidString: "00000000-0000-0000-0000-0000000006B2")!
        let tileA = Tile(id: tileAId, kind: .note, title: "ANTS_A", frame: TileFrame(x: 60, y: 60, width: 280, height: 200), zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        let tileB = Tile(id: tileBId, kind: .note, title: "ANTS_B", frame: TileFrame(x: 420, y: 60, width: 280, height: 200), zPosition: .fromLegacyRank(2), runtimeRef: nil, metadata: TileMetadata())
        let canvas = CanvasNSView(canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [tileA, tileB], groups: [], lastActiveTileId: nil))
        let focusBroker = FocusBroker()
        canvas.focusBroker = focusBroker
        focusBroker.onAcceptedTileFocus = { [weak canvas] id in canvas?.markActive(tileId: id) }
        focusBroker.onAcceptedCanvasScope = { [weak canvas] in canvas?.clearFocusBorder() }
        canvas.frame = NSRect(x: 0, y: 0, width: 800, height: 360)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        let viewA = DescriptorTileNSView(tile: tileA)
        let viewB = DescriptorTileNSView(tile: tileB)
        canvas.install(tileView: viewA, for: tileA)
        canvas.install(tileView: viewB, for: tileB)
        canvas.layoutSubtreeIfNeeded()

        // 1) Focus A in the default (active) state: the ants march.
        let titleAPoint = viewA.convert(NSPoint(x: viewA.bounds.midX, y: TileNSView.titleBarHeight / 2), to: nil)
        AppDelegate.routeTileClickFocus(at: titleAPoint, in: canvas, focusBroker: focusBroker)
        try expect(canvas.qaFocusBorderAnimating, "baseline: the ants must march while the app is active")

        // 2) The app resigns active: the border stays VISIBLE, the ants FREEZE.
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        try expect(canvas.qaFocusBorderFrame != nil, "resigning active must keep the focus border visible — the glanceable cue survives, only the motion stops")
        try expect(!canvas.qaFocusBorderAnimating,
                   "resigning active must freeze the ants — an infinite dash animation makes the render server produce a frame for this window at every display refresh, forever")

        // 3) A camera commit while inactive must not re-attach the loop
        //    (`show` runs per commit for the bordered tile).
        canvas.setViewport(CanvasViewport(x: 10, y: 10, zoom: 1))
        try expect(canvas.qaFocusBorderFrame != nil, "the border must survive a camera commit while inactive")
        try expect(!canvas.qaFocusBorderAnimating, "a camera commit while inactive re-attached the marching loop")

        // 4) An overlay BORN while inactive is born static.
        canvas.updateAttentionBorder(for: tileBId, status: .needsAttention)
        try expect(canvas.qaAttentionBorderFrame(for: tileBId) != nil, "an attention ring created while inactive must still be visible")
        try expect(!canvas.qaAttentionBorderAnimating(for: tileBId), "an attention ring created while inactive must be born with its dashes frozen")

        // 5) Becoming active resumes both, instantly.
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try expect(canvas.qaFocusBorderAnimating, "becoming active must resume the focus ants")
        try expect(canvas.qaAttentionBorderAnimating(for: tileBId), "becoming active must resume attention rings")

        // 6) Off-viewport rings carry no animation at all: pan both tiles far
        //    off screen — the overlays hide (hide() detaches the animation).
        canvas.setViewport(CanvasViewport(x: 50_000, y: 50_000, zoom: 1))
        try expect(canvas.qaFocusBorderFrame == nil,
                   "a bordered tile panned off the viewport must not keep an animated ring on the canvas — attention rings are uncapped, so N offscreen agents would mean N infinite animations")
        try expect(canvas.qaAttentionBorderFrame(for: tileBId) == nil, "an attention ring off the viewport must hide")

        // 7) Panning back restores both, animating (the app is active).
        canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
        try expect(canvas.qaFocusBorderAnimating, "panning back must restore the animated focus ring")
        try expect(canvas.qaAttentionBorderAnimating(for: tileBId), "panning back must restore the attention ring")

        // 8) Occlusion freezes the ants the same way activation does: an ACTIVE
        //    app whose window is covered or parked on another space is still
        //    demanding a compositor frame per refresh for motion nobody can see.
        canvas.occlusionVisibilityProvider = { false }
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        try expect(canvas.qaFocusBorderFrame != nil, "occlusion must keep the border visible (it will be there when the space returns)")
        try expect(!canvas.qaFocusBorderAnimating, "occlusion must freeze the ants — the app being active does not make a covered window worth animating")
        canvas.occlusionVisibilityProvider = { true }
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        try expect(canvas.qaFocusBorderAnimating, "becoming visible again must resume the ants")
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
        let scopedProjectId = UUID(uuidString: "00000000-0000-0000-0000-00000000A710")!
        canvas.onZoneScopeRequired = { placement, _ in
            canvas.commitProvisionalZone(
                zoneId: placement.zoneId,
                projectId: scopedProjectId,
                homeRelativePath: nil,
                scopeLabel: "Autoname / Project Root"
            )
        }

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
        let renameProjectId = UUID(uuidString: "00000000-0000-0000-0000-00000000A711")!
        canvas.onZoneScopeRequired = { placement, _ in
            canvas.commitProvisionalZone(
                zoneId: placement.zoneId,
                projectId: renameProjectId,
                homeRelativePath: nil,
                scopeLabel: "Rename / Project Root"
            )
        }
        // Create a zone (auto-named "Zone 1"): canvas-local (120,150)→(520,470).
        canvas.mouseDown(with: try mouse(.leftMouseDown, at: win(120, 150), clicks: 1, window: window))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: win(520, 470), clicks: 1, window: window))
        canvas.mouseUp(with: try mouse(.leftMouseUp, at: win(520, 470), clicks: 1, window: window))
        try expect(created.count == 1, "zone created; got \(created.count)")
        let zoneId = created[0].zoneId
        try expect(canvas.qaZoneDisplayName(zoneId) == "Zone 1", "seed name 'Zone 1'; got '\(canvas.qaZoneDisplayName(zoneId) ?? "nil")'")

        // Production workspace hydration installs a ZoneLayer in addition to the
        // live placement. Keep that exact split present so this check catches the
        // regression where rename updated chrome but a later layer refresh restored
        // the project/old name.
        let installedLayer = CanvasNSView.ZoneLayer(
            placement: created[0],
            renderModel: CanvasNSView.ZoneRenderModel(
                placement: created[0], displayName: "Zone 1"))
        canvas.upsertZoneLayer(installedLayer)

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

        try expect(installedLayer.placement.name == "Work", "installed ZoneLayer placement retained the pre-rename name")
        try expect(installedLayer.renderModel.displayName == "Work", "installed ZoneLayer render model retained the project name")
        canvas.setZones([installedLayer], documentZones: [installedLayer.renderModel])
        try expect(canvas.qaZoneDisplayName(zoneId) == "Work", "a production layer reinstall flipped the custom name back")
        try expect(canvas.qaLiveZonePlacement(zoneId)?.name == "Work", "a production layer reinstall restored the old placement name")

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
        let fixtureProjectId = UUID(uuidString: "00000000-0000-0000-0000-000000001919")!
        func confirmRootScope(on canvas: CanvasNSView) {
            canvas.onZoneScopeRequired = { placement, _ in
                canvas.commitProvisionalZone(
                    zoneId: placement.zoneId,
                    projectId: fixtureProjectId,
                    homeRelativePath: nil,
                    scopeLabel: "Fixture / Project Root"
                )
            }
        }
        confirmRootScope(on: canvasA)

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
        try expect(created.projectId == fixtureProjectId && created.homeRelativePath == nil, "assertion 2: created zone must carry the confirmed project/root-Home scope")
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
        confirmRootScope(on: canvasA5)

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
        confirmRootScope(on: canvasA6)

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
        confirmRootScope(on: canvasA7)
        // Same above-threshold drag as assertion 2: canvas-local (120,150)→(520,470).
        canvasA7.mouseDown(with: try mouse(.leftMouseDown, at: win(120, 150, canvasH: cH), window: windowA7))
        canvasA7.mouseDragged(with: try mouse(.leftMouseDragged, at: win(520, 470, canvasH: cH), window: windowA7))
        canvasA7.mouseUp(with: try mouse(.leftMouseUp, at: win(520, 470, canvasH: cH), window: windowA7))
        // Reload from disk and assert the zone is present with correct geometry.
        let reloaded7 = try store7.load()
        try expect(reloaded7.zones.count == 1,
                   "assertion 7: reloaded WorkspaceDocument must contain exactly 1 zone; got \(reloaded7.zones.count)")
        let persisted7 = reloaded7.zones[0]
        try expect(persisted7.projectId == fixtureProjectId && persisted7.homeRelativePath == nil, "assertion 7: reloaded zone must carry the confirmed project/root-Home scope")
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
        gestureDefaultsB.set(false, forKey: CanvasAutoLayoutConfig.enabledKey)
        canvasB.zoneGestureDefaults = gestureDefaultsB
        canvasB.autoLayoutDefaults = gestureDefaultsB
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

        // ── Assertion 11: chrome follows the STORED placement after the move ─────
        // M1.10 (`.plans/46`): this asserted the ADAPTIVE hug (T11) — chrome sized
        // to the union of its members. That was ZoneLayer-only behaviour and it
        // contradicted the rule Model B already implements (zone-unify P3): a zone
        // renders at its stored placement frame, so the size the user drew survives
        // and — the part that matters — the visible rectangle IS the move-grab
        // header rect, which `zoneHeaderScreenRect` derives from the same
        // placement. Adaptive chrome means the rectangle you see is not the one you
        // can grab. Now that `setZones` owns Model B there is one answer.
        let expectedChromeScreenFrame = CanvasEngine.tileScreenFrame(
            CanvasEngine.zoneWorldFrame(layerB2.placement), viewport: vpB)
        let actualChromeFrame = canvasB.zoneLayerChromeFrame(for: gzId)
        try expect(actualChromeFrame == expectedChromeScreenFrame,
                   "assertion 11: chrome screen frame after move must equal the stored placement's screen frame; expected \(expectedChromeScreenFrame), got \(String(describing: actualChromeFrame))")
        if let grab = canvasB.qaZoneHeaderGrabRect(gzId), let chrome = actualChromeFrame {
            try expect(abs(grab.origin.x - chrome.origin.x) < 0.5 && abs(grab.width - chrome.width) < 0.5,
                       "assertion 11b: the move-grab header must sit on the visible chrome; header \(grab) vs chrome \(chrome)")
        }

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

@MainActor
private final class CanvasUndoSelfCheckDelegate: CanvasNSViewDelegate {
    private(set) var changeCount = 0
    func canvasDidChange(_ canvas: CanvasNSView) { changeCount += 1 }
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
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.06).appResolvedCGColor
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).appResolvedCGColor
        layer?.borderWidth = 2
        layer?.cornerRadius = 6
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        detailLabel.font = .systemFont(ofSize: 11, weight: .medium)
        detailLabel.textColor = .secondaryLabelColor
        addSubview(titleLabel)
        addSubview(detailLabel)
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
    func show(at screenFrame: CGRect, label: String? = nil, detail: String? = nil) {
        let appearing = isHidden
        let previousCenter = layer?.presentation()?.position
            ?? CGPoint(x: frame.midX, y: frame.midY)
        isHidden = false
        let moved = frame != screenFrame
        frame = screenFrame
        titleLabel.stringValue = label ?? ""
        detailLabel.stringValue = detail ?? ""
        titleLabel.isHidden = label == nil
        detailLabel.isHidden = detail == nil
        titleLabel.frame = NSRect(x: 12, y: 10, width: max(0, bounds.width - 24), height: 18)
        detailLabel.frame = NSRect(x: 12, y: 29, width: max(0, bounds.width - 24), height: 16)
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
        shape.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.7).appResolvedCGColor
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
        if animationDuration != self.animationDuration {
            // A running loop keeps its old duration; drop it so the next `show`
            // re-attaches at the configured speed.
            shape.removeAnimation(forKey: Self.animationKey)
        }
        self.animationDuration = animationDuration
        shape.strokeColor = color.cgColor
    }

    /// While suspended (app inactive, window occluded) the border stays visible
    /// with a frozen dash phase and the infinite animation is DETACHED. An
    /// attached `lineDashPhase` loop makes the render server produce a frame for
    /// this window at every display refresh, forever — measured live as the
    /// dominant cause of system-wide chop while Array sat backgrounded
    /// (2026-08-19). Suspension is pushed by the canvas from activation and
    /// occlusion state; it defaults OFF so fixtures that never post those
    /// notifications see the historical behavior byte-for-byte.
    private(set) var marchingSuspended = false

    func setMarchingSuspended(_ suspended: Bool) {
        guard suspended != marchingSuspended else { return }
        marchingSuspended = suspended
        if suspended {
            shape.removeAnimation(forKey: Self.animationKey)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shape.lineDashPhase = 0
            CATransaction.commit()
        } else if !isHidden, shape.animation(forKey: Self.animationKey) == nil {
            startMarchingAnts()
        }
    }

    /// Position the overlay around `tileScreenFrame` (the focused tile's frame),
    /// outset by `gap`, show it, and make sure the marching animation is attached.
    func show(around tileScreenFrame: CGRect) {
        let next = tileScreenFrame.insetBy(dx: -gap, dy: -gap)
        if frame != next {
            frame = next
            layoutShape()
        }
        isHidden = false
        // Attach-if-missing, never re-add: this runs on every camera commit
        // while a focused tile is on screen, and re-adding the infinite loop
        // restarted the dash phase each time — ants frozen mid-gesture, plus a
        // CA animation mutation per step. While suspended, never attach: a
        // camera commit in an inactive app must not resurrect the loop.
        if !marchingSuspended, shape.animation(forKey: Self.animationKey) == nil {
            startMarchingAnts()
        }
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
        var scopeLabel: String?
        var isProvisional: Bool
        var agentRollupText: String?
        var qaVerdictGlyph: String?
        var qaVerdictTooltip: String?
        /// T5 (`.plans/47`): the zone new tiles land in.
        var isArmed: Bool = false
    }

    /// Exposed for `zoneBounds` callers that need the header height without
    /// an instance; the instance `headerHeight` below drives `headerRect`.
    static let headerHeight: Double = 34

    private var model: CanvasNSView.ZoneRenderModel
    private let headerHeight: CGFloat = 34

    /// Whether this is the zone new tiles will be created in. T5 (`.plans/47`).
    ///
    /// Before this, "which zone am I creating into" had NO visual representation
    /// at all — `setActiveProjectZone` was pure routing. That was survivable while
    /// the answer only changed at scene mount; now that clicking, focusing and
    /// even panning re-point it, an invisible target would just relocate the
    /// surprise rather than remove it.
    ///
    /// Drawn with the zone's OWN accent rather than a new palette entry: no new
    /// colour literal, no new `TokenThemed` surface for the ui-probe census to
    /// hunt, and a resting zone paints exactly what it painted before.
    var isArmed: Bool = false {
        didSet { if isArmed != oldValue { needsDisplay = true } }
    }

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
            scopeLabel: model.scopeLabel,
            isProvisional: model.isProvisional,
            agentRollupText: model.agentStatusRollup.displayText,
            qaVerdictGlyph: model.qaVerdict?.verdict.glyph,
            qaVerdictTooltip: model.qaVerdict?.tooltip,
            isArmed: isArmed
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
        let path = NSBezierPath(roundedRect: zoneRect, xRadius: 12, yRadius: 12)
        path.lineWidth = isArmed ? 3 : 2

        // The body and header share one overflow boundary. Filling `zoneRect`
        // and `headerRect` as bare rectangles paints square pixels through the
        // rounded top corners; clip every interior draw to the rounded path, then
        // restore and stroke the outline last so the header cannot paint over it.
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        accent.withAlphaComponent(model.placement.collapsed ? 0.20 : 0.10).setFill()
        zoneRect.fill()

        accent.withAlphaComponent(isArmed ? 0.38 : 0.24).setFill()
        headerRect.fill()
        let title = model.placement.collapsed ? "▸ \(model.displayName)" : model.displayName
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.88)
        ]
        let dotRect = CGRect(x: 12, y: 13, width: 8, height: 8)
        accent.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        let titleWidth = min(
            max(52, (title as NSString).size(withAttributes: attributes).width + 4),
            max(52, headerRect.width * 0.36)
        )
        title.draw(
            in: CGRect(x: 27, y: 8, width: titleWidth, height: 18),
            withAttributes: attributes
        )
        if let scope = model.scopeLabel {
            let scopeAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: model.isProvisional ? .semibold : .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(model.isProvisional ? 0.86 : 0.62)
            ]
            scope.draw(
                in: CGRect(
                    x: 31 + titleWidth,
                    y: 9,
                    width: max(0, headerRect.width - titleWidth - 125),
                    height: 16
                ),
                withAttributes: scopeAttributes
            )
        }

        // Close (✕) button — top-right of the header. The canvas owns the click
        // (hitTest here returns nil); this only draws the affordance.
        let closeSize: CGFloat = 24
        let closeRect = CGRect(x: headerRect.maxX - closeSize - 4, y: 4, width: closeSize, height: min(closeSize, max(0, headerRect.height - 4)))
        ("✕" as NSString).draw(in: closeRect.insetBy(dx: 6, dy: 3), withAttributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.70)
        ])

        let overflowRect = CGRect(x: closeRect.minX - 26, y: 4, width: 24, height: 24)
        ("•••" as NSString).draw(in: overflowRect.insetBy(dx: 2, dy: 5), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.66)
        ])
        let layoutGlyph = model.placement.autoLayoutMode == .disabled ? "" : "⇥"
        if !layoutGlyph.isEmpty {
            (layoutGlyph as NSString).draw(
                in: CGRect(x: overflowRect.minX - 24, y: 7, width: 20, height: 18),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.62)
                ]
            )
        }

        var rightInset: CGFloat = 12 + closeSize + 56   // close + overflow + layout slots
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
        NSGraphicsContext.restoreGraphicsState()

        accent.withAlphaComponent(isArmed ? 1.0 : 0.75).setStroke()
        if model.isProvisional { path.setLineDash([6, 4], count: 2, phase: 0) }
        path.stroke()
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
    /// What the overlay actually draws, so the QA snapshot can't report a hint
    /// the user never sees. The two presentations describe two different key
    /// vocabularies.
    var hintLine: String {
        guard let canvas else { return NavKeymap.default.hintLine }
        switch canvas.navOverlayPresentation {
        case .navMode: return canvas.navModeHintLine
        case .leaderLabels: return CanvasNSView.leaderHintLine
        }
    }

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
            drawHintLine(hintLine)
        case .leaderLabels:
            drawTileLabels(in: canvas)
            drawHintLine(hintLine)
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

    private func drawHintLine(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92)
        ]
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

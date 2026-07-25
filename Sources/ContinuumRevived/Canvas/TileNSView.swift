import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// Tile view base. Subclasses host tile-kind-specific content. The tile's
/// title bar is the drag affordance for moving the tile; the body is for
/// content (terminal interaction, browser, etc.). The 8px ring around the
/// edges is a resize affordance.
@MainActor
class TileNSView: NSView, TokenThemed {
    struct ChromeSnapshot: Equatable {
        var title: String
        var agentStatus: AgentStatus?
        var agentStatusLabel: String?
        var agentStatusErrorMessage: String?
    }

    static let titleBarHeight: CGFloat = 24
    static let resizeMargin: CGFloat = 8
    static let cornerHoverSize: CGFloat = 16
    static let cornerBracketLength: CGFloat = 12
    /// Screen-space floor for the move-grab strip. The drawn title bar is
    /// `titleBarHeight` world units, so at low zoom its on-screen height
    /// collapses (`24*zoom`px) and the move target becomes near-ungrabbable.
    /// The move HIT region AND the drawn bar are floored to at least this many
    /// screen px regardless of zoom — see `grabHeightInLocalCoordinates`, which
    /// drives both the hit strip and the bar's laid-out height in `layout()`.
    static let minScreenGrabPx: CGFloat = 28
    /// Close-button edge length (world units) at zoom 1, and its screen-space
    /// floor at low zoom. Same world-px-as-screen-px floor pattern as the grab
    /// strip so the × stays a clickable target instead of collapsing to a few
    /// pixels when zoomed out. The button is sized in `layout()`.
    static let closeButtonSize: CGFloat = 14
    static let minScreenCloseButtonPx: CGFloat = 22
    /// Close glyph point size at zoom 1; floored on screen so the × stays
    /// legible when zoomed out (the symbol scales with the tile-view transform,
    /// so its world point size must grow as zoom shrinks to hold screen size).
    static let closeGlyphPointSize: CGFloat = 9
    static let minScreenCloseGlyphPx: CGFloat = 11

    weak var canvas: CanvasNSView?
    var tile: Tile {
        didSet { titleBar?.tile = tile }
    }

    var agentStatus: AgentStatus? {
        didSet {
            titleBar?.agentStatus = agentStatus
            canvas?.updateAttentionBorder(for: tile.id, status: agentStatus)
        }
    }

    /// Non-empty description of why the tile is in a failed/stale state (e.g. a
    /// lazy-resume recovery error). Surfaced as the tile's tooltip and carried
    /// in `ChromeSnapshot` so a caller can assert it is non-empty.
    var agentStatusErrorMessage: String? {
        didSet { titleBar?.agentStatusErrorMessage = agentStatusErrorMessage }
    }

    var chromeSnapshot: ChromeSnapshot? { titleBar?.snapshot }

    func setTitleBarAccessory(_ accessory: NSView?) {
        titleBar?.setAccessory(accessory)
    }

    func makeAdditionalTitleBarMenuItems() -> [NSMenuItem] { [] }

    func titleBarContextMenuForQA() -> NSMenu {
        titleBar?.makeTileContextMenu() ?? NSMenu(title: "Tile")
    }

    /// Invoked when the user clicks the title bar's × button. The app sets
    /// this to its tile-delete orchestrator at install time.
    var onClose: (() -> Void)?
    var onStopRun: (() -> Void)?

    private var titleBar: TitleBarView?
    private var cornerOverlay: CornerOverlayView?
    private var affordanceOverlay: AffordanceOverlayView?
    private(set) var contentView: NSView?

    /// Debug-draw mode, default off and set only by the Component Lab: overlays
    /// the interaction hitboxes (move-grab strip, resize edge bands, corner
    /// zones, close-button target) plus live screen-px metrics, so the otherwise
    /// invisible affordances can be seen and tuned. Never enabled in normal use;
    /// the overlay is hit-transparent so it never intercepts events.
    var showsInteractionAffordances = false {
        didSet {
            guard showsInteractionAffordances != oldValue else { return }
            if showsInteractionAffordances {
                installAffordanceOverlay()
            } else {
                affordanceOverlay?.removeFromSuperview()
                affordanceOverlay = nil
            }
        }
    }
    private var dragKind: DragKind = .none
    private var dragLastWindowPoint: CGPoint = .zero
    private var mouseDraggedSinceDown = false
    /// The world frame the in-flight move drag is ARMED to snap to: the ghost is
    /// shown and `mouseUp` commits it. Stays nil until the drag has dwelled in
    /// snap range for `dragGhostDelay`, so a quick drag-past places freely.
    private var dragSnapTarget: TileFrame?
    /// The UN-snapped frame a live resize has accumulated this gesture. Resize-snap
    /// is applied as a preview on top of this, but the raw drag keeps accruing here
    /// so the edge can be pulled back out of a snap — without it the committed snap
    /// becomes the next event's base and the edge sticks to the neighbor forever.
    /// nil between gestures; the first resize event seeds it from `tile.frame`.
    private var resizeFreeFrame: TileFrame?
    /// The candidate the dwell timer is currently counting down for (not yet
    /// armed). Distinct from `dragSnapTarget` so a re-entered/changed candidate
    /// restarts the dwell rather than arming instantly.
    private var pendingGhostTarget: TileFrame?
    private var pendingGhostWorkItem: DispatchWorkItem?
    /// Dwell before the snap phantom appears (and the snap arms). Short, so it
    /// reads as "settle near a tile" not lag. Overridable so the self-check can
    /// drive it to 0 (arm synchronously) or keep it (assert the dwell gates).
    var dragGhostDelay: TimeInterval = 0.15

    override var isFlipped: Bool { true }

    init(tile: Tile) {
        self.tile = tile
        self.agentStatus = nil
        super.init(frame: .zero)
        wantsLayer = true
        applyTokens()
        layer?.borderWidth = 1
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        let bar = TitleBarView(tile: tile, agentStatus: agentStatus)
        // Manual framing (not constraints) like the content view: under the
        // canvas's frame/bounds zoom transform, Auto Layout lays constraint-based
        // subviews out in the frame (screen) coordinate space, so a constrained
        // bar would shrink with zoom. Framing it from `bounds` (world units) in
        // `layout()` keeps it spanning the full world width at the floored height.
        bar.translatesAutoresizingMaskIntoConstraints = true
        bar.autoresizingMask = []
        bar.onCloseRequested = { [weak self] in self?.onClose?() }
        bar.onStopRunRequested = { [weak self] in self?.onStopRun?() }
        bar.additionalMenuItemsProvider = { [weak self] in self?.makeAdditionalTitleBarMenuItems() ?? [] }
        addSubview(bar)
        self.titleBar = bar

        installCornerOverlay()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// P1.9: every layer colour this view owns, assigned from scratch. Subclasses
    /// override and call `super` — a subclass that paints the tile body from
    /// somewhere else (the terminal's theme background) must re-assert it here or
    /// the next appearance change puts this default back.
    ///
    /// The values are still the shipped dark-only literals: adopting `DesignTokens`
    /// is P1.10's job (they are the P1.7 allowlist entries it owns). What changes
    /// here is only WHEN they are assigned.
    func applyTokens() {
        layer?.backgroundColor = NSColor(white: 0.10, alpha: 1.0).cgColor
        layer?.borderColor = NSColor(white: 0.25, alpha: 1.0).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    private func installCornerOverlay() {
        let overlay = CornerOverlayView(frame: .zero)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        self.cornerOverlay = overlay
    }

    private func installAffordanceOverlay() {
        guard affordanceOverlay == nil else { return }
        let overlay = AffordanceOverlayView(frame: bounds)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)  // topmost — installed after chrome/content/corner
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        affordanceOverlay = overlay
        updateAffordanceOverlay()
    }

    private func updateAffordanceOverlay() {
        affordanceOverlay?.metrics = affordanceMetrics()
    }

    /// The live interaction geometry, in world units + the derived on-screen px
    /// (world × zoom). The overlay draws from this and the self-check asserts the
    /// screen-px floors hold across zoom (the docs/25 dead-corner/grab regression).
    func affordanceMetrics() -> TileAffordanceMetrics {
        let zoom = max(0.0001, CGFloat(canvas?.viewport.zoom ?? 1))
        let m = resizeMarginInLocalCoordinates
        return TileAffordanceMetrics(
            zoom: zoom,
            resizeEdgeWorld: m,
            cornerWorld: max(Self.cornerHoverSize, 2 * m),
            grabWorld: grabHeightInLocalCoordinates,
            closeWorld: closeButtonWorldSize,
            closeFrame: qaCloseButtonFrame,
            zPosition: tile.zPosition
        )
    }

    var qaAffordanceOverlayInstalled: Bool { affordanceOverlay != nil }

    /// Subclasses install their content view via this entry point so the
    /// title bar stays on top and the body is automatically resized.
    func setContentView(_ view: NSView) {
        contentView?.removeFromSuperview()
        contentView = view
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = []
        // Place the body below the corner overlay so the corner brackets
        // remain visible above any tile content. Manual layout keeps the body
        // in world coordinates when the tile view's frame is AppKit-scaled by
        // a frame/bounds transform during canvas zoom.
        if let cornerOverlay {
            addSubview(view, positioned: .below, relativeTo: cornerOverlay)
        } else {
            addSubview(view)
        }
        if let titleBar {
            addSubview(titleBar, positioned: .above, relativeTo: view)
        }
        layoutContentView()
    }

    override func layout() {
        super.layout()
        layoutChrome()
        layoutContentView()
        updateAffordanceOverlay()
    }

    /// Drive the title-bar height + close-button size from the current zoom so
    /// their on-screen size stays in a usable band. The tile view's `bounds` is
    /// world-sized and AppKit scales the whole subtree by `zoom`, so a world
    /// height `H` renders at `H*zoom` px; framing the bar from `bounds` at the
    /// floored world height holds the screen size at the `minScreen*` floors when
    /// zoomed out (and spans the full world width — see init for why not Auto
    /// Layout).
    private func layoutChrome() {
        let barHeight = chromeBarHeight
        let barFrame = NSRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        if titleBar?.frame != barFrame {
            titleBar?.frame = barFrame
            // Bar height changed (zoom crossed the floor) → redraw the title +
            // dots at the new chrome scale.
            titleBar?.needsDisplay = true
        }
        titleBar?.applyCloseButtonSizing(buttonSize: closeButtonWorldSize, glyphPointSize: closeGlyphWorldPointSize)
        if let titleBar, titleBar.superview === self {
            addSubview(titleBar, positioned: .above, relativeTo: contentView)
        }
    }

    private func layoutContentView() {
        // Most tile bodies track the (zoom-floored) bar height so the body never
        // overlaps the bar or leaves a gap beneath it. Terminal tiles override
        // this inset to keep the Ghostty grid stable while the camera zooms;
        // their larger low-zoom grab strip is visual chrome over a stable body,
        // not a terminal resize request.
        let barHeight = contentTopInsetWorldHeight
        let nextFrame = NSRect(x: 0, y: barHeight, width: bounds.width, height: max(0, bounds.height - barHeight))
        if contentView?.frame != nextFrame {
            contentView?.frame = nextFrame
        }
    }

    /// Update the cached `tile` model and re-display the title bar. The
    /// canvas drives view-frame updates separately from this.
    func sync(tile: Tile) {
        self.tile = tile
    }

    func acquireFocus(reason: FocusRequest) -> Bool {
        canvas?.bringToFront(tileId: tile.id)
        if let contentView {
            window?.makeFirstResponder(contentView)
        } else {
            window?.makeFirstResponder(self)
        }
        return true
    }

    func releaseFocus(reason: FocusRequest) {}
    func canHandleReservedShortcut(_ shortcut: ReservedShortcut) -> Bool { false }

    /// Resolves the tile owning a responder by walking up the view hierarchy.
    /// The pre-dispatch shortcut monitor uses this to honor a tile's reserved-
    /// shortcut claim from the *live* first responder: clicks inside a WKWebView
    /// (or other body content) never reach `mouseUp`'s focus registration, so
    /// `FocusBroker.activeSurface` can be stale and must not be the sole gate.
    static func enclosingTileId(of responder: NSResponder?) -> UUID? {
        var view = responder as? NSView
        while let current = view {
            if let tileView = current as? TileNSView { return tileView.tile.id }
            view = current.superview
        }
        return nil
    }

    // MARK: - Hit testing

    /// Reclaim the 8pt resize ring from any body content view. Without this
    /// override, body subviews (NSScrollView, NSTextView, WKWebView,
    /// NSOutlineView, etc.) consume edge clicks because they're constrained
    /// from `topAnchor + titleBarHeight` down to `bottomAnchor`, covering the
    /// bottom/left/right ring. Returning self for ring points routes mouseDown
    /// to TileNSView.mouseDown so the existing resize logic fires.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // AppKit passes `point` in this receiver's local coordinate system.
        // A previous implementation treated it as superview/canvas coordinates
        // and converted it again, which made terminal title bars/rings miss at
        // non-zero origins and zoom levels. Browser tiles appeared better only
        // because their own subview stack still left more chrome hittable.
        let local = point
        if bounds.contains(local), resizeEdge(at: local) != nil {
            return self
        }
        // Floored move-grab strip. At low zoom the title bar is visually enlarged,
        // but body content can still be stacked above it in AppKit's subview order.
        // Claim the entire post-resize grab strip before `super.hitTest` so terminal
        // content cannot swallow title-bar drags. Route through TitleBarView first
        // so close/accessory controls still win; otherwise return self for move.
        if bounds.contains(local), local.y < grabHeightInLocalCoordinates {
            if let titleBar {
                let titlePoint = convert(local, to: titleBar)
                if let hit = titleBar.hitTest(titlePoint) { return hit }
            }
            return self
        }
        return super.hitTest(point)
    }

    // MARK: - Mouse handling for drag and resize

    override func mouseDown(with event: NSEvent) {
        mouseDraggedSinceDown = false
        resizeFreeFrame = nil
        dragLastWindowPoint = event.locationInWindow
        let local = convert(event.locationInWindow, from: nil)
        if let edge = resizeEdge(at: local) {
            dragKind = .resize(edge)
            return
        }
        if local.y < grabHeightInLocalCoordinates {
            dragKind = .move
            return
        }
        // Below the grab strip: defer to subclass / content view.
        dragKind = .none
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        mouseDraggedSinceDown = true
        guard let canvas else { return super.mouseDragged(with: event) }
        let dx = event.locationInWindow.x - dragLastWindowPoint.x
        let dy = event.locationInWindow.y - dragLastWindowPoint.y
        // The window y-axis goes UP; the canvas is flipped (y-down). Negate
        // dy so screen-down drags push the world down on the canvas too.
        let delta = CGSize(width: dx, height: -dy)
        dragLastWindowPoint = event.locationInWindow
        switch dragKind {
        case .move:
            // The tile follows the cursor freely; once it dwells within snap range
            // of a neighbor (~dragGhostDelay) the destination is previewed as a
            // translucent ghost and armed for commit on release. No modifier —
            // toggle the whole behavior in Settings ("Drag Snapping").
            let next = CanvasEngine.tile(tile, draggedByScreenDelta: delta, viewport: canvas.viewport)
            // zone-unify P3: a move must not reshape the owning zone.
            canvas.updateTile(next, recalculateZoneBounds: false)
            updateDragGhost(candidate: canvas.snapTarget(for: next.frame, excludingTileId: tile.id), on: canvas)
        case .resize(let edge):
            // Live resize: the tile previews itself as it sizes. Accumulate the raw,
            // UN-snapped resize in `resizeFreeFrame` (seeded from the current frame on
            // the first event) and apply the snap as a preview on top — so dragging an
            // edge ~past the pull radius pulls it back out of a snap instead of having
            // the committed snap re-capture every event. If the dragged edge is within
            // snap range of a neighbor's edge, snap it flush so the tile matches the
            // neighbor's dimension along that axis. No dwell/ghost.
            var freeTile = tile
            freeTile.frame = resizeFreeFrame ?? tile.frame
            let resizedFree = CanvasEngine.tile(freeTile, resizedByScreenDelta: delta, edge: edge, viewport: canvas.viewport)
            resizeFreeFrame = resizedFree.frame
            var next = resizedFree
            if let snapped = canvas.resizeSnapTarget(for: resizedFree.frame, edge: edge, kind: tile.kind, excludingTileId: tile.id) {
                next.frame = snapped
            }
            canvas.updateTile(next)
            // Live "W × H" readout near the cursor (sense of scale). Pixels =
            // the tile's CONTENT size (world frame minus the chrome bar), uniform
            // for every tile kind — e.g. a browser sized to 1280×720 reads as that.
            canvas.showResizeDimensions(
                widthPx: Int(next.frame.width.rounded()),
                heightPx: Int(max(0, next.frame.height - Double(TileNSView.titleBarHeight)).rounded()),
                atWindowPoint: event.locationInWindow
            )
        case .none:
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let completedDragKind = dragKind
        let wasClick = !mouseDraggedSinceDown
        dragKind = .none
        mouseDraggedSinceDown = false
        resizeFreeFrame = nil
        // Tear down the live resize readout (no-op if it was never shown).
        canvas?.hideResizeDimensions()

        // Commit the armed snap (if the dwell elapsed), then tear down the ghost.
        if case .move = completedDragKind, let target = dragSnapTarget {
            var snapped = tile
            snapped.frame = target
            canvas?.updateTile(snapped)
        }
        if let canvas { cancelDragGhost(on: canvas) } else { teardownDragGhostState() }

        if case .move = completedDragKind, wasClick {
            canvas?.focusBroker?.enterScope(.tile(tile.id), reason: .userClick)
            return
        }

        // zone-unify P4: a committed move can change zone membership — drop a tile
        // into a zone to adopt it, or pull a member far past the edge to break out.
        if case .move = completedDragKind, !wasClick {
            canvas?.reevaluateZoneMembership(forMovedTile: tile.id)
        }

        super.mouseUp(with: event)
    }

    /// Drive the dwell-gated snap phantom from the current drag candidate.
    /// - nil candidate (out of range) → cancel everything, hide the ghost.
    /// - same target already armed or already counting down → leave it.
    /// - a new/changed target → restart the dwell; arm (show ghost + set
    ///   `dragSnapTarget`) only after `dragGhostDelay`, so a quick drag-past never
    ///   flashes a phantom and never snaps on release.
    private func updateDragGhost(candidate: TileFrame?, on canvas: CanvasNSView) {
        guard let candidate else {
            cancelDragGhost(on: canvas)
            return
        }
        // Already armed → FOLLOW the candidate (the phantom rides the edge with a
        // trailing ease); never re-dwell mid-snap, so sliding along an edge stays
        // smooth instead of blinking out and waiting again.
        if dragSnapTarget != nil {
            dragSnapTarget = candidate
            canvas.showDragGhost(at: candidate)
            return
        }
        // Counting down → keep the same timer running; arm to wherever the drag is
        // when it fires (don't restart the dwell on every in-range jitter).
        if pendingGhostWorkItem != nil {
            pendingGhostTarget = candidate
            return
        }
        // Fresh entry into snap range → start the dwell.
        guard dragGhostDelay > 0 else {
            armDragGhost(candidate, on: canvas)
            return
        }
        pendingGhostTarget = candidate
        let work = DispatchWorkItem { [weak self, weak canvas] in
            guard let self, let canvas, let target = self.pendingGhostTarget else { return }
            self.armDragGhost(target, on: canvas)
        }
        pendingGhostWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dragGhostDelay, execute: work)
    }

    private func armDragGhost(_ target: TileFrame, on canvas: CanvasNSView) {
        pendingGhostTarget = nil
        pendingGhostWorkItem = nil
        dragSnapTarget = target
        canvas.showDragGhost(at: target)
    }

    private func cancelDragGhost(on canvas: CanvasNSView) {
        teardownDragGhostState()
        canvas.hideDragGhost()
    }

    private func teardownDragGhostState() {
        pendingGhostWorkItem?.cancel()
        pendingGhostWorkItem = nil
        pendingGhostTarget = nil
        dragSnapTarget = nil
    }

    // MARK: - Cursor affordance

    /// Make the resize ring discoverable: tracking-area-driven cursor rects
    /// for each edge zone, plus a drag-handle cursor over the title bar so the
    /// user reads it as draggable instead of a thin gray strip.
    override func resetCursorRects() {
        super.resetCursorRects()
        let m = resizeMarginInLocalCoordinates
        // Floor the open-hand cursor band to the grab strip (not the drawn 24-px
        // title bar) so the move affordance matches the floored hit region at
        // low zoom.
        let titleH = grabHeightInLocalCoordinates
        let w = bounds.width
        let h = bounds.height
        guard w > 2 * m, h > titleH + m else { return }

        // Edge bands. Top/bottom span the full width (covering corners with
        // a vertical-axis cursor — stock NSCursor has no diagonal corner
        // cursor; the L-bracket hover indicator carries the corner-resize
        // affordance visually).
        addCursorRect(NSRect(x: 0, y: 0, width: w, height: m), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: h - m, width: w, height: m), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: m, width: m, height: h - 2 * m), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: w - m, y: m, width: m, height: h - 2 * m), cursor: .resizeLeftRight)

        // Title bar (below the top resize ring) reads as a drag handle.
        let titleDragHeight = max(0, titleH - m)
        if titleDragHeight > 0 {
            addCursorRect(NSRect(x: m, y: m, width: w - 2 * m, height: titleDragHeight), cursor: .openHand)
        }
    }

    var resizeMarginInLocalCoordinates: CGFloat {
        guard let zoom = canvas?.viewport.zoom, zoom.isFinite, zoom > 0 else { return Self.resizeMargin }
        return Self.resizeMargin / CGFloat(zoom)
    }

    /// Height (world units) of the move-grab strip from the tile's top edge.
    /// Floored so the strip is never smaller than `minScreenGrabPx` on screen:
    /// at low zoom the constant-px floor (`minScreenGrabPx/zoom` world units)
    /// exceeds the drawn `titleBarHeight`, keeping the move target grabbable.
    /// Mirrors `resizeMarginInLocalCoordinates`'s screen-px-in-world pattern.
    var grabHeightInLocalCoordinates: CGFloat {
        guard let zoom = canvas?.viewport.zoom, zoom.isFinite, zoom > 0 else { return Self.titleBarHeight }
        return max(Self.titleBarHeight, Self.minScreenGrabPx / CGFloat(zoom))
    }

    /// World height the drawn title bar is laid out to. Aliased to the move-grab
    /// floor so the visible bar and the grabbable strip are exactly the same
    /// region — no second divergent floor to drift out of sync.
    var chromeBarHeight: CGFloat { grabHeightInLocalCoordinates }

    /// World y-offset for the content view. Defaults to the visual chrome height;
    /// terminal tiles override this so camera zoom does not reflow the PTY grid.
    var contentTopInsetWorldHeight: CGFloat { chromeBarHeight }

    private(set) var qaCanvasLayoutInvalidationCount = 0

    func invalidateForCanvasLayout() {
        qaCanvasLayoutInvalidationCount += 1
        setNeedsDisplay(bounds)
        updateAffordanceOverlay()  // zoom-dependent metrics refresh with the camera
    }

    /// World edge length for the close button, floored so its on-screen size
    /// stays `>= minScreenCloseButtonPx`. Mirrors the grab-strip floor pattern.
    var closeButtonWorldSize: CGFloat {
        guard let zoom = canvas?.viewport.zoom, zoom.isFinite, zoom > 0 else { return Self.closeButtonSize }
        return max(Self.closeButtonSize, Self.minScreenCloseButtonPx / CGFloat(zoom))
    }

    /// World point size for the × glyph, floored so it stays legible on screen
    /// (the glyph scales with the tile-view transform, hence the `/zoom` floor).
    var closeGlyphWorldPointSize: CGFloat {
        guard let zoom = canvas?.viewport.zoom, zoom.isFinite, zoom > 0 else { return Self.closeGlyphPointSize }
        return max(Self.closeGlyphPointSize, Self.minScreenCloseGlyphPx / CGFloat(zoom))
    }

    func qaResizeEdge(at point: CGPoint) -> ResizeEdge? {
        resizeEdge(at: point)
    }

    /// QA: laid-out title-bar frame (world units). On-screen height is
    /// `height * zoom`. Drives `--tile-chrome-scale-check`.
    var qaTitleBarFrame: CGRect { titleBar?.frame ?? .zero }

    /// QA: the title's world point size (scales with the bar). On-screen size is
    /// `* zoom`. Drives `--tile-chrome-scale-check`.
    var qaTitleFontWorldSize: CGFloat { titleBar?.titleFontWorldSize ?? 0 }

    /// QA: laid-out close-button frame (world units), converted to the tile
    /// view's own coordinate space. On-screen hit size is `size * zoom`.
    var qaCloseButtonFrame: CGRect {
        guard let titleBar else { return .zero }
        return titleBar.convert(titleBar.qaCloseButtonFrame, to: self)
    }

    /// QA: does a local tile-coordinate click route to this tile's move handling
    /// rather than body content? This validates the production override using
    /// AppKit's documented `hitTest(_:)` local-coordinate contract. Body content
    /// would be a regression. Drives `--tile-drag-grab-check`.
    func qaHitRoutesToMove(atLocal localPoint: CGPoint) -> Bool {
        let hit = hitTest(localPoint)
        return hit === self || hit === titleBar
    }

    /// QA: resolve the drag classification for a local-coordinate point, using
    /// the same precedence as `mouseDown` (resize ring wins, then the floored
    /// move-grab strip, else body). Drives `--tile-drag-grab-check`.
    func qaDragKindIsMove(at point: CGPoint) -> Bool {
        if resizeEdge(at: point) != nil { return false }
        return point.y < grabHeightInLocalCoordinates
    }

    private func resizeEdge(at point: CGPoint) -> ResizeEdge? {
        // `point`/`bounds` are in world units (the tile view's bounds is set to
        // the world tile size; AppKit scales bounds→frame by the zoom). The edge
        // band `m` is `resizeMargin/zoom`, i.e. a constant 8 *screen* px.
        let m = resizeMarginInLocalCoordinates
        // Corners get a wider band than edges so they're reliably grabbable
        // (an `m×m` corner is a near-impossible ~8px target, smaller when zoomed
        // out). Match the visual `cornerHoverSize` hover region (world units) so
        // what the user sees they can grab, with a screen-space floor of `2*m`
        // (twice the edge band) so the corner never collapses at low zoom.
        let c = max(TileNSView.cornerHoverSize, 2 * m)
        let nearLeft = point.x <= m
        let nearRight = point.x >= bounds.width - m
        let nearTop = point.y <= m
        let nearBottom = point.y >= bounds.height - m
        let nearLeftCorner = point.x <= c
        let nearRightCorner = point.x >= bounds.width - c
        let nearTopCorner = point.y <= c
        let nearBottomCorner = point.y >= bounds.height - c

        switch (nearTop, nearBottom, nearLeft, nearRight) {
        case _ where nearTopCorner && nearLeftCorner:     return .topLeft
        case _ where nearTopCorner && nearRightCorner:    return .topRight
        case _ where nearBottomCorner && nearLeftCorner:  return .bottomLeft
        case _ where nearBottomCorner && nearRightCorner: return .bottomRight
        case (true, _, _, _):     return .top
        case (_, true, _, _):     return .bottom
        case (_, _, true, _):     return .left
        case (_, _, _, true):     return .right
        default:                  return nil
        }
    }

    private enum DragKind {
        case none
        case move
        case resize(ResizeEdge)
    }
}

/// Lightweight chrome view drawing the tile title, a drag-handle indicator,
/// and a close button. Claims its own clicks (`hitTest` returns self for
/// non-button areas) and forwards mouse events to its parent `TileNSView`,
/// which interprets them as a move-drag. Owning the click here is more robust
/// than `hitTest = nil` fall-through because it is independent of subview
/// ordering and `super.hitTest` walking semantics.
@MainActor
private final class TitleBarView: NSView, TokenThemed {
    var tile: Tile { didSet { needsDisplay = true } }
    var agentStatus: AgentStatus? { didSet { needsDisplay = true } }
    var agentStatusErrorMessage: String? { didSet { toolTip = agentStatusErrorMessage } }
    var onCloseRequested: (() -> Void)?
    var onStopRunRequested: (() -> Void)?
    var additionalMenuItemsProvider: (() -> [NSMenuItem])?
    private var accessoryView: NSView?

    var snapshot: TileNSView.ChromeSnapshot {
        TileNSView.ChromeSnapshot(
            title: "\(tile.kind.displayName) · \(tile.title)",
            agentStatus: agentStatus,
            agentStatusLabel: agentStatus.map { StatusChipPresenter.display(for: $0).label },
            agentStatusErrorMessage: agentStatusErrorMessage
        )
    }

    private let closeButton: NSButton
    /// Desired close-button edge length (world units) + glyph point size, set
    /// from the parent tile's `layout()` so the × holds a usable on-screen size
    /// across zoom (see `applyCloseButtonSizing`). The button is framed manually
    /// in `layout()` — NSButton's bezel imposes its own required height
    /// constraint that fights an explicit height constraint, so manual framing
    /// (matching the body's manual-layout idiom) is the deterministic path.
    private var closeButtonWorldSize: CGFloat = TileNSView.closeButtonSize
    private var closeGlyphPointSize: CGFloat = TileNSView.closeGlyphPointSize
    /// Trailing inset of the close button from the bar's right edge (world).
    private static let closeButtonTrailingInset: CGFloat = 10

    init(tile: Tile, agentStatus: AgentStatus? = nil) {
        self.tile = tile
        self.agentStatus = agentStatus
        let btn = NSButton()
        // Plain `xmark` (not `xmark.circle.fill`) is a monochrome SF symbol
        // that respects contentTintColor — the filled multicolor variant
        // renders red regardless of tint, which read as "alert" inside a
        // dark, dense canvas.
        let config = NSImage.SymbolConfiguration(pointSize: TileNSView.closeGlyphPointSize, weight: .semibold)
        btn.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tile")?
            .withSymbolConfiguration(config)
        btn.imageScaling = .scaleProportionallyDown
        btn.isBordered = false
        btn.bezelStyle = .smallSquare
        btn.contentTintColor = NSColor(white: 0.55, alpha: 1.0)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setButtonType(.momentaryChange)
        self.closeButton = btn

        super.init(frame: .zero)
        wantsLayer = true
        applyTokens()

        btn.target = self
        btn.action = #selector(handleClose(_:))
        btn.translatesAutoresizingMaskIntoConstraints = true
        btn.autoresizingMask = []
        addSubview(btn)
    }

    func applyTokens() {
        layer?.backgroundColor = NSColor(white: 0.16, alpha: 1.0).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    /// Set the close button's edge length (world units) and glyph point size.
    /// Called from the tile's `layout()` so both track the current zoom; the
    /// button is then framed in `layout()`. The glyph is only re-imaged when its
    /// size changes (rebuilding the NSImage is needless churn on identity layout).
    func applyCloseButtonSizing(buttonSize: CGFloat, glyphPointSize: CGFloat) {
        if closeButtonWorldSize != buttonSize {
            closeButtonWorldSize = buttonSize
            needsLayout = true
        }
        if closeGlyphPointSize != glyphPointSize {
            closeGlyphPointSize = glyphPointSize
            let config = NSImage.SymbolConfiguration(pointSize: glyphPointSize, weight: .semibold)
            closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tile")?
                .withSymbolConfiguration(config)
        }
    }

    override func layout() {
        super.layout()
        // Right-align + vertically center the close button at its (zoom-floored)
        // world size. Manual framing so the size is exactly what we set.
        let size = closeButtonWorldSize
        closeButton.frame = NSRect(
            x: bounds.width - Self.closeButtonTrailingInset - size,
            y: (bounds.height - size) / 2,
            width: size,
            height: size
        )
    }

    /// QA: the close button's laid-out frame (world units) so the parent's
    /// self-check can assert its on-screen hit size stays in a usable band.
    var qaCloseButtonFrame: CGRect { closeButton.frame }

    func setAccessory(_ accessory: NSView?) {
        accessoryView?.removeFromSuperview()
        accessoryView = accessory
        guard let accessory else { return }
        accessory.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accessory)
        // Anchor to the bar's trailing edge (not the now-manually-framed close
        // button): inset past the button's zoom-1 footprint + the original gap.
        NSLayoutConstraint.activate([
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(Self.closeButtonTrailingInset + TileNSView.closeButtonSize + 34)),
            accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
            accessory.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            accessory.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// Claim every title-bar click for ourselves except hits on the close
    /// button. Returning self (rather than nil) means mouseDown fires here;
    /// our overrides forward to the parent TileNSView's mouseDown so the
    /// existing drag-to-move logic runs. This avoids relying on subview-walk
    /// fall-through which was the suspected reason move-drag stopped working
    /// after corner overlay + close button were added.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if closeButton.frame.contains(point) {
            return closeButton
        }
        if let accessoryView {
            let accessoryPoint = convert(point, to: accessoryView)
            if let hit = accessoryView.hitTest(accessoryPoint) { return hit }
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        superview?.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        superview?.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        superview?.mouseUp(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        makeTileContextMenu()
    }

    func makeTileContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Tile")
        let additionalItems = additionalMenuItemsProvider?() ?? []
        for item in additionalItems {
            menu.addItem(item)
        }
        if !additionalItems.isEmpty {
            menu.addItem(NSMenuItem.separator())
        }
        let stop = NSMenuItem(title: "Stop run", action: #selector(handleStopRun(_:)), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)
        menu.addItem(NSMenuItem.separator())
        let close = NSMenuItem(title: "Close tile", action: #selector(handleClose(_:)), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        return menu
    }

    @objc private func handleClose(_ sender: Any?) {
        onCloseRequested?()
    }

    @objc private func handleStopRun(_ sender: Any?) {
        onStopRunRequested?()
    }

    /// Chrome scale: how much taller the (zoom-floored) bar is than its natural
    /// height. 1 when zoomed in (floor inert), > 1 when zoomed out. Title text +
    /// drag dots scale by this so they grow with the tab instead of shrinking to
    /// nothing at low zoom (the bar height is `bounds.height`, set by the parent).
    private var chromeScale: CGFloat { max(1, bounds.height / TileNSView.titleBarHeight) }

    /// World point size the title is drawn at (natural 12 × chrome scale). On
    /// screen it renders at `* zoom`. Exposed for the chrome-scale check.
    var titleFontWorldSize: CGFloat { 12 * chromeScale }

    override func draw(_ dirtyRect: NSRect) {
        let scale = chromeScale
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: titleFontWorldSize, weight: .medium),
            .foregroundColor: NSColor.lightGray
        ]
        let title = "\(tile.kind.displayName) · \(tile.title)" as NSString
        // Vertically center in the (variable-height) bar; inset scales too.
        let titleSize = title.size(withAttributes: attrs)
        title.draw(at: NSPoint(x: 8 * scale, y: max(0, (bounds.height - titleSize.height) / 2)), withAttributes: attrs)

        if let agentStatus {
            drawAgentStatus(agentStatus)
        }

        // Three-dot drag handle indicator, left of the × close button. Sizes +
        // gap scale with the chrome; positioned relative to the floored button.
        let dot = NSColor(white: 0.55, alpha: 1.0)
        let radius: CGFloat = 1.5 * scale
        let spacing: CGFloat = 4 * scale
        let cy = bounds.midY
        var cx = bounds.width - Self.closeButtonTrailingInset - closeButtonWorldSize - 10 * scale
        dot.setFill()
        for _ in 0..<3 {
            let rect = NSRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
            NSBezierPath(ovalIn: rect).fill()
            cx -= spacing
        }

        // 1px hairline along the bottom edge of the title bar — separates
        // chrome from body and reinforces the "this is a header" read.
        NSColor(white: 0.28, alpha: 1.0).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    private func drawAgentStatus(_ status: AgentStatus) {
        let display = StatusChipPresenter.display(for: status)
        let label = display.label
        // The dot-and-tint shape, so the accent. `.dark` because the title bar
        // paints its own white:0.16 literal (allowlisted, owner P1.10).
        let color = StatusChipNSView.nsColor(display.accent.resolved(for: .dark))
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.82)
        ]
        let textSize = (label as NSString).size(withAttributes: textAttributes)
        let pillWidth = textSize.width + 18
        let pillRect = NSRect(x: max(8, bounds.width - 58 - pillWidth), y: 4, width: pillWidth, height: 16)
        color.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: 8, yRadius: 8).fill()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: pillRect.minX + 6, y: pillRect.midY - 3, width: 6, height: 6)).fill()
        label.draw(at: NSPoint(x: pillRect.minX + 15, y: pillRect.minY + 2), withAttributes: textAttributes)
    }

    // P1.8 deleted this bar's private label/colour maps outright — see
    // `StatusChipPresenter`, now the only status→appearance mapping. Not even a
    // wrapper is left behind: both former callers ask the presenter directly.
}

/// Transparent overlay that draws four corner L-brackets. Each corner has its
/// own NSTrackingArea + CAShapeLayer; on mouse-enter the matching bracket
/// fades in, on exit it fades out. The overlay returns nil from hitTest so it
/// doesn't compete with the body or the resize-ring hitTest on the parent
/// TileNSView. Tracking areas use `.inVisibleRect` so we don't churn them
/// every frame during a drag-resize.
@MainActor
private final class CornerOverlayView: NSView, TokenThemed {
    private var cornerLayers: [ResizeEdge: CAShapeLayer] = [:]
    private var cornerAreas: [NSTrackingArea] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let corners: [ResizeEdge] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        for corner in corners {
            let shape = CAShapeLayer()
            shape.lineWidth = 1.5
            shape.lineCap = .round
            shape.opacity = 0
            layer?.addSublayer(shape)
            cornerLayers[corner] = shape
        }
        applyTokens()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The bracket colours live on sublayers, not on `layer` — same rule: they are
    /// resolved CGColors and nothing else re-assigns them.
    func applyTokens() {
        for shape in cornerLayers.values {
            shape.strokeColor = NSColor(white: 0.85, alpha: 1.0).cgColor
            shape.fillColor = NSColor.clear.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    override var isFlipped: Bool { true }

    /// Pass clicks through. The overlay exists only to draw indicators and
    /// own tracking areas — it must not consume mouse events.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        layoutCornerBrackets()
    }

    private func layoutCornerBrackets() {
        let len = TileNSView.cornerBracketLength
        let inset: CGFloat = 3
        let w = bounds.width
        let h = bounds.height
        guard w > 2 * (inset + len), h > 2 * (inset + len) else { return }

        for (corner, shape) in cornerLayers {
            let path = CGMutablePath()
            switch corner {
            case .topLeft:
                path.move(to: CGPoint(x: inset, y: inset + len))
                path.addLine(to: CGPoint(x: inset, y: inset))
                path.addLine(to: CGPoint(x: inset + len, y: inset))
            case .topRight:
                path.move(to: CGPoint(x: w - inset - len, y: inset))
                path.addLine(to: CGPoint(x: w - inset, y: inset))
                path.addLine(to: CGPoint(x: w - inset, y: inset + len))
            case .bottomLeft:
                path.move(to: CGPoint(x: inset, y: h - inset - len))
                path.addLine(to: CGPoint(x: inset, y: h - inset))
                path.addLine(to: CGPoint(x: inset + len, y: h - inset))
            case .bottomRight:
                path.move(to: CGPoint(x: w - inset - len, y: h - inset))
                path.addLine(to: CGPoint(x: w - inset, y: h - inset))
                path.addLine(to: CGPoint(x: w - inset, y: h - inset - len))
            default: break
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shape.path = path
            shape.frame = bounds
            CATransaction.commit()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in cornerAreas { removeTrackingArea(area) }
        cornerAreas.removeAll()
        let s = TileNSView.cornerHoverSize
        let w = bounds.width
        let h = bounds.height
        let corners: [(ResizeEdge, NSRect)] = [
            (.topLeft,     NSRect(x: 0, y: 0, width: s, height: s)),
            (.topRight,    NSRect(x: w - s, y: 0, width: s, height: s)),
            (.bottomLeft,  NSRect(x: 0, y: h - s, width: s, height: s)),
            (.bottomRight, NSRect(x: w - s, y: h - s, width: s, height: s))
        ]
        for (corner, rect) in corners {
            let area = NSTrackingArea(
                rect: rect,
                options: [.mouseEnteredAndExited, .activeInActiveApp],
                owner: self,
                userInfo: ["corner": Self.cornerKey(corner)]
            )
            addTrackingArea(area)
            cornerAreas.append(area)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        animateCorner(from: event.trackingArea, to: 0.6)
    }

    override func mouseExited(with event: NSEvent) {
        animateCorner(from: event.trackingArea, to: 0)
    }

    private func animateCorner(from area: NSTrackingArea?, to opacity: Float) {
        guard let info = area?.userInfo,
              let key = info["corner"] as? String,
              let corner = Self.cornerFromKey(key),
              let layer = cornerLayers[corner]
        else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        layer.opacity = opacity
        CATransaction.commit()
    }

    private static func cornerKey(_ edge: ResizeEdge) -> String {
        switch edge {
        case .topLeft: return "topLeft"
        case .topRight: return "topRight"
        case .bottomLeft: return "bottomLeft"
        case .bottomRight: return "bottomRight"
        default: return ""
        }
    }

    private static func cornerFromKey(_ key: String) -> ResizeEdge? {
        switch key {
        case "topLeft": return .topLeft
        case "topRight": return .topRight
        case "bottomLeft": return .bottomLeft
        case "bottomRight": return .bottomRight
        default: return nil
        }
    }
}

/// Live interaction geometry for a tile, in world units plus the derived
/// on-screen pixels (world × zoom). Screen-px values are what the floors in
/// TileNSView are designed to hold constant/minimum across zoom.
struct TileAffordanceMetrics: Equatable {
    var zoom: CGFloat
    var resizeEdgeWorld: CGFloat
    var cornerWorld: CGFloat
    var grabWorld: CGFloat
    var closeWorld: CGFloat
    var closeFrame: CGRect
    var zPosition: FracIndex

    var resizeEdgeScreenPx: CGFloat { resizeEdgeWorld * zoom }
    var cornerScreenPx: CGFloat { cornerWorld * zoom }
    var grabScreenPx: CGFloat { grabWorld * zoom }
    var closeScreenPx: CGFloat { closeWorld * zoom }
}

/// Hit-transparent debug overlay drawing a tile's interaction zones + a live
/// screen-px readout. Draws in the tile's world coordinate space (flipped to
/// match), so the bands are exactly the hit regions `resizeEdge`/`hitTest` use —
/// no re-derivation that could drift from production geometry.
@MainActor
private final class AffordanceOverlayView: NSView {
    var metrics: TileAffordanceMetrics? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let m = metrics, m.zoom > 0 else { return }
        let w = bounds.width, h = bounds.height
        let edge = m.resizeEdgeWorld, c = m.cornerWorld, grab = m.grabWorld

        func fill(_ rect: NSRect, _ color: NSColor) { color.setFill(); rect.fill() }

        // Move-grab strip first; resize bands + corners layer on top (matching
        // hit precedence: resize wins over move).
        fill(NSRect(x: 0, y: 0, width: w, height: grab), NSColor.systemBlue.withAlphaComponent(0.16))

        let edgeColor = NSColor.systemOrange.withAlphaComponent(0.22)
        fill(NSRect(x: 0, y: 0, width: w, height: edge), edgeColor)
        fill(NSRect(x: 0, y: h - edge, width: w, height: edge), edgeColor)
        fill(NSRect(x: 0, y: edge, width: edge, height: max(0, h - 2 * edge)), edgeColor)
        fill(NSRect(x: w - edge, y: edge, width: edge, height: max(0, h - 2 * edge)), edgeColor)

        let cornerColor = NSColor.systemPink.withAlphaComponent(0.28)
        fill(NSRect(x: 0, y: 0, width: c, height: c), cornerColor)
        fill(NSRect(x: w - c, y: 0, width: c, height: c), cornerColor)
        fill(NSRect(x: 0, y: h - c, width: c, height: c), cornerColor)
        fill(NSRect(x: w - c, y: h - c, width: c, height: c), cornerColor)

        if !m.closeFrame.isEmpty {
            let path = NSBezierPath(rect: m.closeFrame)
            path.lineWidth = max(1, 1.5 / m.zoom)
            NSColor.systemTeal.withAlphaComponent(0.95).setStroke()
            path.stroke()
        }

        drawReadout(m, originX: edge + 6 / m.zoom, originY: grab + 6 / m.zoom)
    }

    private func drawReadout(_ m: TileAffordanceMetrics, originX: CGFloat, originY: CGFloat) {
        // Screen-constant font (≈11px) so the readout stays legible at any zoom.
        let font = NSFont.monospacedSystemFont(ofSize: max(6, 11 / m.zoom), weight: .medium)
        let text = """
        zoom \(String(format: "%.2f", m.zoom))×
        edge \(px(m.resizeEdgeScreenPx))  corner \(px(m.cornerScreenPx))
        grab \(px(m.grabScreenPx))  close \(px(m.closeScreenPx))
        z-position \(String(format: "%.6f", m.zPosition.value))
        """ as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let pad = 5 / m.zoom
        let size = text.size(withAttributes: attrs)
        let bg = NSRect(x: originX, y: originY, width: size.width + pad * 2, height: size.height + pad * 2)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 4 / m.zoom, yRadius: 4 / m.zoom).fill()
        text.draw(at: NSPoint(x: originX + pad, y: originY + pad), withAttributes: attrs)
    }

    private func px(_ value: CGFloat) -> String { "\(Int(value.rounded()))px" }
}

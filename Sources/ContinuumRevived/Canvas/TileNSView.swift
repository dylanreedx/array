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

    /// Action vocabulary is tile-kind specific. A managed agent closes by
    /// detaching its view; unlike a terminal tile, that operation never stops or
    /// archives the underlying entity.
    func setTileActionLabels(close: String, stop: String) {
        titleBar?.setActionLabels(close: close, stop: stop)
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
        // P1.11: `Radius.container`, per Metrics' own mapping table (6 → 10). The
        // tile CONTAINS cards, and P1.10 moved those to `Radius.card` (6) — this is
        // the other half of righting the inverted nesting.
        layer?.cornerRadius = Radius.container
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
    /// P1.11: the values are `DesignTokens`. The outline is `borderStrong`, not
    /// `border`: this edge is the whole "canvas looks like mush" defect —
    /// white@0.25 on white@0.10 measured **1.68:1**, so a tile had no visible
    /// boundary at all. `borderStrong` on `canvas` measures 6.91:1 light / 6.09:1
    /// dark (P1.3's provenance table), and `--ui-contrast-check` asserts it.
    func applyTokens() {
        layer?.backgroundColor = SurfaceToken.tileBody.color.cgColor(in: self)
        layer?.borderColor = LineToken.borderStrong.color.cgColor(in: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    /// P1.11: the token application shared by every content tile whose body is a
    /// mono `NSTextView` on the tile surface — note, file, run artifacts, diff.
    /// Each of those five files had independently re-declared the same
    /// `white:0.10` fill and `white:0.90` text; this is the one place that pair
    /// now lives, so they cannot drift apart again.
    ///
    /// `NSTextView.backgroundColor`/`.textColor` are `NSColor` properties rather
    /// than layer colours, so they are invisible to `UIProbeAppearance`'s sentinel
    /// sweep — `runDocumentTileTokenCheck` reads them back per appearance instead.
    /// QA (P1.11): the status pill's laid-out rect and the leading edge of the drag
    /// handle, forwarded from the private title bar so `runTitleBarPillLayoutCheck`
    /// can assert the pill clears the dots. `nil` if the bar is gone.
    func qaStatusPillRect(for status: AgentStatus) -> NSRect? { titleBar?.qaStatusPillRect(for: status) }
    var qaDragHandleLeadingX: CGFloat? { titleBar?.qaDragHandleLeadingX }
    /// The rect the tile title is really drawn into. `agentStatus` has to be set on
    /// the bar first — the title's available width depends on the pill.
    var qaTitleRect: NSRect? { titleBar?.qaTitleRect() }
    func applyDocumentTokens(to textView: NSTextView) {
        textView.backgroundColor = SurfaceToken.tileBody.color.nsColor(in: self)
        textView.textColor = TextToken.textPrimary.color.nsColor(in: self)
        textView.insertionPointColor = TextToken.textPrimary.color.nsColor(in: self)
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

    /// QA: how many times AppKit has actually laid this tile out.
    ///
    /// Distinct from `qaCanvasLayoutInvalidationCount`, which counts the canvas
    /// ASKING for a relayout. This counts the traversal ARRIVING, whoever sent it —
    /// and during a zoom most of it arrives from the window's own display-cycle
    /// layout pass, not from any call of ours. A 30-second sample of a real pinch
    /// (2026-08-14) put its largest single block in
    /// `NSWindow _layoutViewTree -> layoutSubtreeIfNeeded`, recursing through every
    /// mounted tile; nothing counted that, which is why `canvas.zoom` could report
    /// a fixed canvas as cheap while a real one was choppy.
    private(set) var qaLayoutPassCount = 0

    override func layout() {
        qaLayoutPassCount += 1
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
            titleBar?.invalidateChrome()
        }
        titleBar?.applyCloseButtonSizing(buttonSize: closeButtonWorldSize, glyphPointSize: closeGlyphWorldPointSize)
        // Repair the bar-above-body z-order only when it is actually wrong.
        // `addSubview(_:positioned:)` is a remove+insert that reorders the
        // backing sublayers even when the order is already correct, and this
        // path runs per visible tile on every camera step — an unconditional
        // reinsertion here put a sublayer reorder on every PAN event, which no
        // layout or redraw counter could see.
        if let titleBar, titleBar.superview === self,
           let contentView, contentView.superview === self,
           let barIndex = subviews.firstIndex(of: titleBar),
           let contentIndex = subviews.firstIndex(of: contentView),
           barIndex < contentIndex {
            qaChromeZOrderRepairCount += 1
            addSubview(titleBar, positioned: .above, relativeTo: contentView)
        }
    }

    /// Counts the times `layoutChrome` had to re-order the title bar above the
    /// body. A camera step over a settled tile must never raise this — the
    /// unconditional reinsertion it replaces was invisible to every other
    /// counter.
    private(set) var qaChromeZOrderRepairCount = 0

    private func layoutContentView() {
        // The inset is zoom-independent, so a camera move never re-frames the body:
        // an enlarged low-zoom grab strip is visual chrome OVER a stable body, not
        // a resize request. That rule was written for the Ghostty grid and now
        // holds for every tile kind — see `contentTopInsetWorldHeight`.
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
        // AppKit passes `point` in the receiver's SUPERVIEW coordinate system.
        // Convert to this tile's world-sized bounds before ring math. Treating the
        // canvas point as local only works accidentally near the canvas origin;
        // elsewhere body content swallows the bottom/side rings while the title
        // bar makes the top edge appear to work.
        let local = superview.map { convert(point, from: $0) } ?? point
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
        // Cmd/Space camera gestures must win before stale selection/resize-ring
        // state classifies this press as a tile resize. Limit interception to tile
        // chrome that already routes here; command-clicks and spaces inside terminal/
        // browser/text content retain their native behavior.
        if let canvas, canvas.pointerPanRequested(for: event) {
            dragKind = .canvasPan
            canvas.beginPointerPan(with: event)
            return
        }
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
        case .canvasPan:
            canvas.continuePointerPan(with: event)
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

        if case .canvasPan = completedDragKind {
            canvas?.endPointerPan()
            return
        }

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
        // The floor is quantised into scale BUCKETS before it is applied. Without
        // this the bar's world height changes on every zoom step, which re-frames
        // the title bar, which lays the whole tile out — measured at one layout
        // pass per tile per step, and the largest single cost of a real pinch.
        // Bucketing makes the bar hold still through a gesture and step only when
        // the bucket changes.
        return max(Self.titleBarHeight, Self.minScreenGrabPx / CGFloat(Self.chromeScaleBucket(for: zoom)))
    }

    /// Steps per octave for the chrome floor's scale bucket. Higher is
    /// finer-grained chrome and more layout passes; lower is steadier and fewer.
    static let chromeScaleStepsPerOctave: Double =
        Double(ProcessInfo.processInfo.environment["ARRAY_CHROME_BUCKETS"] ?? "") ?? 4

    /// Quantise the scale for chrome purposes, GEOMETRICALLY and always DOWNWARD.
    ///
    /// Downward is the load-bearing half. The floor exists so the move-grab strip
    /// is never smaller than `minScreenGrabPx` on screen; bucketing to the NEAREST
    /// step can round the scale UP, which makes the strip smaller than the floor
    /// promised and silently breaks the affordance. `--tile-drag-grab-check`
    /// catches exactly that at zoom 0.1. Rounding down can only make the strip
    /// larger than strictly needed, which is safe.
    ///
    /// Geometric rather than linear so the relative step is constant across the
    /// zoom range: a fixed 1/8 step is invisible at zoom 3 and enormous at 0.1.
    static func chromeScaleBucket(for zoom: Double) -> Double {
        guard zoom.isFinite, zoom > 0 else { return 1 }
        let steps = max(1, chromeScaleStepsPerOctave)
        let bucketed = pow(2, ((log2(zoom) * steps).rounded(.down)) / steps)
        return bucketed.isFinite && bucketed > 0 ? min(zoom, bucketed) : zoom
    }

    /// World height the drawn title bar is laid out to. Aliased to the move-grab
    /// floor so the visible bar and the grabbable strip are exactly the same
    /// region — no second divergent floor to drift out of sync.
    var chromeBarHeight: CGFloat { grabHeightInLocalCoordinates }

    /// World y-offset for the content view. Deliberately the UNFLOORED bar height,
    /// so it does not change with the camera: `chromeBarHeight` is
    /// `max(titleBarHeight, minScreenGrabPx/zoom)`, and since `minScreenGrabPx`
    /// (28) exceeds `titleBarHeight` (24), every zoom below 1.167 moves that floor
    /// on every step. Aliasing the inset to it re-framed the body on each step and
    /// reflowed the document. At low zoom the enlarged grab strip therefore overlays
    /// the top of the body rather than pushing it down — chrome geometry is
    /// unchanged, only what it covers.
    var contentTopInsetWorldHeight: CGFloat { Self.titleBarHeight }

    private(set) var qaCanvasLayoutInvalidationCount = 0

    func invalidateForCanvasLayout() {
        qaCanvasLayoutInvalidationCount += 1
        setNeedsDisplay(bounds)
        updateAffordanceOverlay()  // zoom-dependent metrics refresh with the camera
    }

    /// Re-apply ONLY the zoom-dependent chrome floors — the move-grab strip, the
    /// close button and the title bar's world height, each of which is
    /// `max(worldConstant, screenPx / zoom)` so it stays usable when zoomed out.
    ///
    /// The camera used to resize every tile view, which ran the tile's whole
    /// layout as a side effect and refreshed these floors by accident. The
    /// retained world plane deliberately does not, so the canvas calls this on a
    /// zoom change. It is deliberately narrower than `invalidateForCanvasLayout`:
    /// that also marks the tile for display and refreshes the affordance overlay,
    /// which on a 12-tile canvas costs 14,490 prose re-measurements per zoom
    /// sweep — the exact cost the plane exists to remove.
    func refreshZoomDependentChrome() {
        layoutChrome()
    }

    /// World edge length for the close button, floored so its on-screen size
    /// stays `>= minScreenCloseButtonPx`. Mirrors the grab-strip floor pattern,
    /// including the scale bucket: on raw zoom this floor moved on every step
    /// below zoom ~1.57, which re-framed the button per tile per step. The
    /// bucket rounds DOWN, so the floor can only overshoot its screen-px
    /// promise, never undercut it.
    var closeButtonWorldSize: CGFloat {
        guard let zoom = canvas?.viewport.zoom, zoom.isFinite, zoom > 0 else { return Self.closeButtonSize }
        return max(Self.closeButtonSize, Self.minScreenCloseButtonPx / CGFloat(Self.chromeScaleBucket(for: zoom)))
    }

    /// World point size for the × glyph, floored so it stays legible on screen
    /// (the glyph scales with the tile-view transform, hence the `/zoom` floor).
    /// Bucketed like the button: on raw zoom this changed on every step below
    /// zoom ~1.22, and each change rebuilt the button's SF Symbol NSImage — one
    /// image mint per tile per zoom step, invisible to every layout counter.
    var closeGlyphWorldPointSize: CGFloat {
        guard let zoom = canvas?.viewport.zoom, zoom.isFinite, zoom > 0 else { return Self.closeGlyphPointSize }
        return max(Self.closeGlyphPointSize, Self.minScreenCloseGlyphPx / CGFloat(Self.chromeScaleBucket(for: zoom)))
    }

    func qaResizeEdge(at point: CGPoint) -> ResizeEdge? {
        resizeEdge(at: point)
    }

    /// QA: laid-out title-bar frame (world units). On-screen height is
    /// `height * zoom`. Drives `--tile-chrome-scale-check`.
    var qaTitleBarFrame: CGRect { titleBar?.frame ?? .zero }
    /// Redraws the title bar has asked for. A camera move must not raise this.
    var qaTitleBarRedrawCount: Int { titleBar?.qaRedrawInvalidationCount ?? 0 }
    /// Draws the title bar actually EXECUTED — the rasterization side of the
    /// counter above; only a pumped display cycle moves it.
    var qaTitleBarDrawCount: Int { titleBar?.qaDrawCount ?? 0 }

    /// QA: the title's world point size (scales with the bar). On-screen size is
    /// `* zoom`. Drives `--tile-chrome-scale-check`.
    var qaTitleFontWorldSize: CGFloat { titleBar?.titleFontWorldSize ?? 0 }

    /// QA: laid-out close-button frame (world units), converted to the tile
    /// view's own coordinate space. On-screen hit size is `size * zoom`.
    var qaCloseButtonFrame: CGRect {
        guard let titleBar else { return .zero }
        return titleBar.convert(titleBar.qaCloseButtonFrame, to: self)
    }

    /// QA: does a local tile-coordinate click route to this tile's move/resize
    /// handling rather than body content? AppKit calls `hitTest(_:)` with a point
    /// in the receiver's SUPERVIEW coordinates, so this seam converts the desired
    /// local probe before driving the real override. Body content would be a
    /// regression. Drives `--tile-drag-grab-check`.
    func qaHitRoutesToMove(atLocal localPoint: CGPoint) -> Bool {
        guard let superview else { return false }
        let superPoint = convert(localPoint, to: superview)
        let hit = hitTest(superPoint)
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
        case canvasPan
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
    // Redraw only when the drawn VALUE moved. `CanvasNSView.layoutTile` re-assigns
    // `tile` on every camera event to keep the view's copy current, so an
    // unconditional `needsDisplay` here re-rasterized the title text of every tile
    // on every frame of a trackpad pan — defeating the `invalidateTileDisplay:
    // false` contract `setViewport` states one call up. Zoom is unaffected: the
    // chrome scale is a function of the bar's height, and `layoutChrome`
    // invalidates explicitly when that height changes.
    var tile: Tile { didSet { if tile != oldValue { invalidateChrome() } } }
    var agentStatus: AgentStatus? { didSet { if agentStatus != oldValue { invalidateChrome() } } }
    var agentStatusErrorMessage: String? { didSet { toolTip = agentStatusErrorMessage } }

    /// Counts the redraws the bar actually asks for, so a check can witness that a
    /// camera move costs none. Every `needsDisplay` for this bar routes here.
    private(set) var qaRedrawInvalidationCount = 0

    func invalidateChrome() {
        qaRedrawInvalidationCount += 1
        needsDisplay = true
    }
    var onCloseRequested: (() -> Void)?
    var onStopRunRequested: (() -> Void)?
    var additionalMenuItemsProvider: (() -> [NSMenuItem])?
    private var accessoryView: NSView?
    private var closeActionTitle = "Close tile"
    private var stopActionTitle = "Stop run"

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
        btn.image = Self.closeGlyphImage(pointSize: TileNSView.closeGlyphPointSize)
        btn.imageScaling = .scaleProportionallyDown
        btn.isBordered = false
        btn.bezelStyle = .smallSquare
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setButtonType(.momentaryChange)
        self.closeButton = btn

        super.init(frame: .zero)
        wantsLayer = true
        applyTokens()

        btn.target = self
        btn.action = #selector(handleClose(_:))
        btn.setAccessibilityLabel(closeActionTitle)
        btn.setAccessibilityHelp("Close this tile.")
        btn.toolTip = closeActionTitle
        btn.translatesAutoresizingMaskIntoConstraints = true
        btn.autoresizingMask = []
        addSubview(btn)
    }

    /// P1.11. The bar's fill is `tileChrome` — one step off the body's `tileBody`,
    /// which is what makes a header read as a header instead of as part of the
    /// content. `contentTintColor` is not a layer colour, but it is a resolved
    /// `NSColor` all the same, so it belongs here for the same reason: nothing else
    /// re-assigns it when the appearance moves.
    ///
    /// `needsDisplay` because this bar draws its title, its drag dots and its
    /// bottom hairline in `draw(_:)` from `effectiveTokenTheme` — re-applying the
    /// layer fill without re-drawing would leave a dark title on a light bar.
    func applyTokens() {
        layer?.backgroundColor = SurfaceToken.tileChrome.color.cgColor(in: self)
        closeButton.contentTintColor = TextToken.textSecondary.color.nsColor(in: self)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    /// One bitmap × image per bucketed glyph point size, shared across every
    /// tile's bar. The symbol's vector recipe is consumed here once, rather than
    /// re-rasterized by AppKit at every effective backing scale during zoom.
    static func closeGlyphImage(pointSize: CGFloat) -> NSImage? {
        CanvasSymbolImage.image(named: "xmark", pointSize: pointSize, weight: .semibold)
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
            closeButton.image = Self.closeGlyphImage(pointSize: glyphPointSize)
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

    func setActionLabels(close: String, stop: String) {
        closeActionTitle = close
        stopActionTitle = stop
        closeButton.setAccessibilityLabel(close)
        closeButton.setAccessibilityHelp(close == "Detach agent view"
            ? "Detach this view without stopping, archiving, or deleting the agent."
            : "Close this tile.")
        closeButton.toolTip = close
    }

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
        let stop = NSMenuItem(title: stopActionTitle, action: #selector(handleStopRun(_:)), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)
        menu.addItem(NSMenuItem.separator())
        let close = NSMenuItem(title: closeActionTitle, action: #selector(handleClose(_:)), keyEquivalent: "")
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

    /// The attributes the title is drawn with. Truncating-tail, which is the fix for
    /// a real defect the P0.6 baselines caught: the title was drawn at an origin with
    /// no width bound, so on a narrow tile (the ~180pt tiles inside a zone card) the
    /// status pill rendered straight over it. See `qaTitleRect`.
    private func titleAttributes(theme: TokenTheme) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return [
            .font: NSFont.systemFont(ofSize: titleFontWorldSize, weight: .medium),
            // P1.11: was `.lightGray` — a fixed light grey, so under Aqua the tile
            // title was near-invisible on its own bar.
            .foregroundColor: TextToken.textPrimary.color.nsColor(for: theme),
            .paragraphStyle: paragraph
        ]
    }

    /// The rect the title is drawn into: from the leading inset to whatever comes
    /// next on the right — the status pill if there is one, otherwise the drag dots —
    /// less one `Space.s` gap. Never negative-width, and never STARTING past the
    /// blocker either: on a 180-world tile at deep zoom-out the bucketed chrome
    /// floors legitimately overflow the bar, and an empty title rect whose origin
    /// sits right of the dots still reads as "title under the handle" to the
    /// pill-layout census. The clamp only moves rects that are already empty.
    private func titleRect(theme: TokenTheme) -> NSRect {
        let scale = chromeScale
        let blockedFrom = agentStatus.flatMap { statusPillRect(for: $0, theme: theme)?.minX }
            ?? qaDragHandleLeadingX
        let limit = max(0, blockedFrom - CGFloat(Space.s) * scale)
        let leading = min(CGFloat(Space.m) * scale, limit)
        let available = max(0, limit - leading)
        let height = ("X" as NSString).size(withAttributes: titleAttributes(theme: theme)).height
        return NSRect(
            x: leading, y: max(0, (bounds.height - height) / 2),
            width: available, height: height)
    }

    /// QA: every ACTUAL draw of this bar. `qaRedrawInvalidationCount` counts the
    /// ASK (`needsDisplay`); this counts AppKit executing it. The distinction is
    /// the rasterization witness: a harness that never pumps a display cycle
    /// sees invalidations but zero draws — which is exactly how `canvas.zoom`
    /// reported green while a real pinch was visibly bad.
    private(set) var qaDrawCount = 0

    override func draw(_ dirtyRect: NSRect) {
        qaDrawCount += 1
        let scale = chromeScale
        let theme = effectiveTokenTheme
        let attrs = titleAttributes(theme: theme)
        let title = "\(tile.kind.displayName) · \(tile.title)" as NSString
        title.draw(in: titleRect(theme: theme), withAttributes: attrs)

        if let agentStatus {
            drawAgentStatus(agentStatus)
        }

        // Three-dot drag handle indicator, left of the × close button. Sizes +
        // gap scale with the chrome; positioned relative to the floored button.
        let radius: CGFloat = Self.dragDotRadius * scale
        let spacing: CGFloat = Self.dragDotSpacing * scale
        let cy = bounds.midY
        var cx = bounds.width - Self.closeButtonTrailingInset - closeButtonWorldSize - Self.dragDotGap * scale
        TextToken.textSecondary.color.nsColor(for: theme).setFill()
        for _ in 0..<Self.dragDotCount {
            let rect = NSRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
            NSBezierPath(ovalIn: rect).fill()
            cx -= spacing
        }

        // 1px hairline along the bottom edge of the title bar — separates
        // chrome from body and reinforces the "this is a header" read. `separator`
        // is the palette's one gated-exempt line for exactly this: it divides
        // content inside a surface `borderStrong` has already delineated.
        LineToken.separator.color.nsColor(for: theme).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    // MARK: - Status pill geometry (P1.11)
    //
    // These replace the seven unnamed offsets `drawAgentStatus` used to carry
    // (`+18`, `-58`, `y: 4`, `+6`, `-3`, `+15`, `+2`). Each is now either a
    // `Space` rung or DERIVED from one — and the `-58` in particular was an
    // undocumented dependency on the close button plus the drag-dot cluster, so
    // moving either silently slid the pill under the dots. It is now that sum,
    // which is what `runTitleBarPillLayoutCheck` asserts.

    /// Drag-handle dot geometry. 1.5pt radius is off-grid on purpose: it is a
    /// 3pt-diameter dot, and 3 is `Space.s - 1`; the GRID governs gaps, not the
    /// size of a 3px indicator glyph. The gap and count are named so the
    /// cluster's width is computable rather than eyeballed.
    private static let dragDotRadius: CGFloat = 1.5
    private static let dragDotCount = 3
    /// Gap from the close button's leading edge to the first dot's centre.
    private static let dragDotGap = CGFloat(Space.m)
    /// Gap between adjacent dot centres.
    private static let dragDotSpacing = CGFloat(Space.s)
    /// World width the dot cluster occupies at chrome scale 1, from the close
    /// button's leading edge to the outer edge of the leftmost dot.
    private static var dragHandleWidth: CGFloat {
        dragDotGap + CGFloat(dragDotCount - 1) * dragDotSpacing + dragDotRadius
    }
    /// The pill's height and its inner rhythm. Height is one rendered line of
    /// `.caption` plus `Space.s` of vertical padding — a function of the type in
    /// it, per `Metrics`, rather than the old flat 16.
    private static var statusPillHeight: CGFloat { CGFloat(Metrics.lineHeight(for: .caption)) + CGFloat(Space.s) }
    private static let statusPillDotDiameter = CGFloat(Space.m - Space.xs)
    /// Leading pad before the dot, and the gap between dot and label — both
    /// `Space.s`, so the old `+6` / `+15` / `+18` trio collapses into one rung.
    private static let statusPillPad = CGFloat(Space.s)

    /// Right edge of the status pill, measured from the bar's trailing edge: past
    /// the close button, past the drag dots, plus one gap so the pill does not
    /// touch them. Was the bare literal `58`.
    ///
    /// Deliberately an INSTANCE value: the dot cluster scales with `chromeScale`
    /// and the close button carries its own zoom-floored world size, so a static
    /// 58 slid the pill under the dots at low zoom. Both live terms are read here.
    private var statusPillTrailingInset: CGFloat {
        Self.closeButtonTrailingInset + closeButtonWorldSize
            + Self.dragHandleWidth * chromeScale + CGFloat(Space.m)
    }

    /// The pill's text attributes and laid-out rect — one computation, used by
    /// `draw`, by `titleRect` and by the QA accessor, so the three cannot disagree.
    private func statusPillTextAttributes(theme: TokenTheme) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.token(.caption),
            .foregroundColor: TextToken.textPrimary.color.nsColor(for: theme)
        ]
    }

    /// `nil` when the pill cannot fit without being clamped on top of something.
    ///
    /// The old code clamped its x to a minimum and drew regardless, which at low zoom
    /// printed the pill over the drag handle AND over the title — the chrome floors
    /// mean a zoomed-out tile's close button and dot cluster take ~135 world points,
    /// so on a 180pt tile at zoom 0.35 there is nothing left. Suppressing beats
    /// overprinting, and costs nothing readable: `Typography.minimumLegibleZoom(for:
    /// .caption)` is 1.0, so a 9pt pill label is already illegible at that zoom.
    private func statusPillRect(for status: AgentStatus, theme: TokenTheme) -> NSRect? {
        let label = StatusChipPresenter.display(for: status).label as NSString
        let textSize = label.size(withAttributes: statusPillTextAttributes(theme: theme))
        let dot = Self.statusPillDotDiameter
        let pillWidth = textSize.width + dot + 3 * Self.statusPillPad
        let pillHeight = Self.statusPillHeight
        let x = bounds.width - statusPillTrailingInset - pillWidth
        guard x >= CGFloat(Space.m) * chromeScale else { return nil }
        return NSRect(
            x: x, y: (bounds.height - pillHeight) / 2,
            width: pillWidth, height: pillHeight)
    }

    private func drawAgentStatus(_ status: AgentStatus) {
        let display = StatusChipPresenter.display(for: status)
        let label = display.label
        // The dot-and-tint shape, so the accent — now resolved in the bar's OWN
        // theme. It was pinned `.dark` because this bar painted a dark-only
        // white:0.16 literal; P1.11 put the bar on `tileChrome`, which carries a
        // light leaf, so the pin would have been the black-on-dark bug inverted.
        let theme = effectiveTokenTheme
        let color = display.accent.nsColor(for: theme)
        let textAttributes = statusPillTextAttributes(theme: theme)
        let textSize = (label as NSString).size(withAttributes: textAttributes)
        let dot = Self.statusPillDotDiameter
        let pillHeight = Self.statusPillHeight
        guard let pillRect = statusPillRect(for: status, theme: theme) else { return }
        // The tinted pill body. Kept as an alpha wash over the bar rather than a
        // solid accent fill: `accent`-on-`tileChrome` IS one of P1.3's 104
        // documented pairs, whereas an accent at 16% over a surface is a composite
        // no gate can predict — so the READ comes from the dot and the outline.
        color.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: pillHeight / 2, yRadius: pillHeight / 2).fill()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(
            x: pillRect.minX + Self.statusPillPad, y: pillRect.midY - dot / 2,
            width: dot, height: dot)).fill()
        label.draw(
            at: NSPoint(
                x: pillRect.minX + Self.statusPillPad + dot + Self.statusPillPad,
                y: pillRect.midY - textSize.height / 2),
            withAttributes: textAttributes)
    }

    /// QA: the pill's laid-out rect at the current bounds, so the parent's check
    /// can assert it clears the drag dots instead of sliding under them.
    func qaStatusPillRect(for status: AgentStatus) -> NSRect? {
        statusPillRect(for: status, theme: effectiveTokenTheme)
    }

    /// QA: the rect the title is really drawn into, for the assertion that it never
    /// runs under the pill.
    func qaTitleRect() -> NSRect { titleRect(theme: effectiveTokenTheme) }

    /// QA: the world x of the leftmost drag dot's outer edge — the thing the pill
    /// must not cross.
    var qaDragHandleLeadingX: CGFloat {
        bounds.width - Self.closeButtonTrailingInset - closeButtonWorldSize - Self.dragHandleWidth * chromeScale
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
    /// P1.11: `borderStrong`. A resize bracket is a focus/affordance indicator, so
    /// it is exactly what that token is for — and the old fixed white@0.85 was
    /// invisible against a light tile body under Aqua.
    func applyTokens() {
        for shape in cornerLayers.values {
            shape.strokeColor = LineToken.borderStrong.color.cgColor(in: self)
            // `nil`, not `.clear`: a bracket is stroke-only, and an explicitly
            // transparent fill is still a fill slot the appearance gate would have
            // to hold an opinion about. Absence is the honest spelling — it drops
            // 4 fill slots from the sweep, which the floor below records.
            shape.fillColor = nil
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

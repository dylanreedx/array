import AppKit
import ContinuumRevivedCore
import Foundation

/// Tile view base. Subclasses host tile-kind-specific content. The tile's
/// title bar is the drag affordance for moving the tile; the body is for
/// content (terminal interaction, browser, etc.). The 8px ring around the
/// edges is a resize affordance.
@MainActor
class TileNSView: NSView {
    struct ChromeSnapshot: Equatable {
        var title: String
        var agentStatus: AgentStatus?
        var agentStatusLabel: String?
    }

    static let titleBarHeight: CGFloat = 24
    static let resizeMargin: CGFloat = 8
    static let cornerHoverSize: CGFloat = 16
    static let cornerBracketLength: CGFloat = 12
    /// Screen-space floor for the move-grab strip. The drawn title bar is
    /// `titleBarHeight` world units, so at low zoom its on-screen height
    /// collapses (`24*zoom`px) and the move target becomes near-ungrabbable.
    /// The move HIT region (not the drawn bar) is floored to at least this many
    /// screen px regardless of zoom — see `grabHeightInLocalCoordinates`.
    static let minScreenGrabPx: CGFloat = 28

    weak var canvas: CanvasNSView?
    var tile: Tile {
        didSet { titleBar?.tile = tile }
    }

    var agentStatus: AgentStatus? {
        didSet { titleBar?.agentStatus = agentStatus }
    }

    var chromeSnapshot: ChromeSnapshot? { titleBar?.snapshot }

    func setTitleBarAccessory(_ accessory: NSView?) {
        titleBar?.setAccessory(accessory)
    }

    /// Invoked when the user clicks the title bar's × button. The app sets
    /// this to its tile-delete orchestrator at install time.
    var onClose: (() -> Void)?
    var onStopRun: (() -> Void)?

    private var titleBar: TitleBarView?
    private var cornerOverlay: CornerOverlayView?
    private(set) var contentView: NSView?
    private var dragKind: DragKind = .none
    private var dragLastWindowPoint: CGPoint = .zero
    private var mouseDraggedSinceDown = false

    /// Marching-ants focus border. A `CAShapeLayer` strokes the tile's rounded
    /// rect with a dashed pattern; a repeating `lineDashPhase` animation makes
    /// the dashes travel around the perimeter. Installed only while the tile is
    /// the focus scope. Sized in the view's own (backing) coordinates so the
    /// stroke + dashes stay screen-space constant at any canvas zoom — the frame
    /// of the view is what the canvas scales, never this layer's lineWidth.
    private static let focusBorderDashPattern: [NSNumber] = [6, 4]
    private static let focusBorderAnimationKey = "marchingAnts"
    private var focusBorderLayer: CAShapeLayer?
    private var isFocusBordered = false

    override var isFlipped: Bool { true }

    init(tile: Tile) {
        self.tile = tile
        self.agentStatus = nil
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.10, alpha: 1.0).cgColor
        layer?.borderColor = NSColor(white: 0.25, alpha: 1.0).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        let bar = TitleBarView(tile: tile, agentStatus: agentStatus)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.onCloseRequested = { [weak self] in self?.onClose?() }
        bar.onStopRunRequested = { [weak self] in self?.onStopRun?() }
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.titleBarHeight)
        ])
        self.titleBar = bar

        installCornerOverlay()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
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
        layoutContentView()
    }

    override func layout() {
        super.layout()
        layoutContentView()
        layoutFocusBorder()
    }

    // MARK: - Marching-ants focus border

    /// Install (or remove) the animated marching-ants border. Idempotent.
    /// `setFocused(true)` adds the dashed stroke layer above the background but
    /// below the corner overlay (so the corner brackets stay readable) and
    /// attaches the looping `lineDashPhase` animation; `setFocused(false)`
    /// removes both. GPU-composited, so the march costs no main-thread work.
    func setFocused(_ focused: Bool) {
        guard focused != isFocusBordered else { return }
        isFocusBordered = focused
        if focused {
            installFocusBorderLayer()
            startMarchingAntsAnimation()
        } else {
            focusBorderLayer?.removeFromSuperlayer()
            focusBorderLayer = nil
        }
    }

    private func installFocusBorderLayer() {
        guard focusBorderLayer == nil, let hostLayer = layer else { return }
        let shape = CAShapeLayer()
        shape.fillColor = NSColor.clear.cgColor
        // Subtle, low-opacity accent so the border reads as "focused" without
        // shouting inside a dense dark canvas.
        shape.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        shape.lineWidth = 1.5
        shape.lineDashPattern = Self.focusBorderDashPattern
        // Added to the tile's own backing layer: it composites above the
        // background/border fill but below every subview (title bar, content,
        // corner overlay), so the L-bracket corners stay readable on top.
        hostLayer.addSublayer(shape)
        focusBorderLayer = shape
        layoutFocusBorder()
    }

    private func layoutFocusBorder() {
        guard let shape = focusBorderLayer else { return }
        let cornerRadius = layer?.cornerRadius ?? 6
        // Inset by half the line width so the stroke sits fully inside the tile
        // bounds and lines up with the 1px static border / rounded corner.
        let inset = shape.lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        CATransaction.commit()
    }

    private func startMarchingAntsAnimation() {
        guard let shape = focusBorderLayer else { return }
        let phase = Self.focusBorderDashPattern.reduce(0) { $0 + $1.doubleValue }
        let animation = CABasicAnimation(keyPath: "lineDashPhase")
        animation.fromValue = 0
        animation.toValue = phase
        animation.duration = 3.5
        animation.repeatCount = .infinity
        shape.add(animation, forKey: Self.focusBorderAnimationKey)
    }

    /// QA: true when the marching-ants border layer is installed AND its
    /// looping animation is attached. Drives the `--focus-border-check`.
    var qaFocusBorderActive: Bool {
        guard let shape = focusBorderLayer, shape.superlayer != nil else { return false }
        return shape.animation(forKey: Self.focusBorderAnimationKey) != nil
    }

    /// QA: freeze the marching motion so the border renders deterministically
    /// for an offscreen snapshot. Removes the animation and pins a fixed dash
    /// phase, leaving the dashed stroke statically visible.
    func qaFreezeFocusBorder(phase: CGFloat = 0) {
        guard let shape = focusBorderLayer else { return }
        shape.removeAnimation(forKey: Self.focusBorderAnimationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.lineDashPhase = phase
        CATransaction.commit()
    }

    private func layoutContentView() {
        let nextFrame = NSRect(x: 0, y: Self.titleBarHeight, width: bounds.width, height: max(0, bounds.height - Self.titleBarHeight))
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
        if bounds.contains(point), resizeEdge(at: point) != nil {
            return self
        }
        // Floored move-grab strip. The drawn TitleBarView subview is only
        // `titleBarHeight` world units tall, so at low zoom its on-screen height
        // collapses and clicks in the top strip fall through to body content.
        // Claim the portion of the floored strip that lies BELOW the title bar
        // subview so those clicks route to mouseDown → .move. The resize ring is
        // already claimed above (resize wins on the top edge), and the title bar
        // subview keeps its own [0, titleBarHeight] region (close/stop buttons +
        // its own move-forwarding), so neither is stolen here.
        if bounds.contains(point),
           let titleBar,
           point.y >= titleBar.frame.maxY,
           point.y < grabHeightInLocalCoordinates {
            return self
        }
        return super.hitTest(point)
    }

    // MARK: - Mouse handling for drag and resize

    override func mouseDown(with event: NSEvent) {
        mouseDraggedSinceDown = false
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
            let next = CanvasEngine.tile(tile, draggedByScreenDelta: delta, viewport: canvas.viewport)
            canvas.updateTile(next)
        case .resize(let edge):
            let next = CanvasEngine.tile(tile, resizedByScreenDelta: delta, edge: edge, viewport: canvas.viewport)
            canvas.updateTile(next)
        case .none:
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let completedDragKind = dragKind
        let wasClick = !mouseDraggedSinceDown
        dragKind = .none
        mouseDraggedSinceDown = false

        if case .move = completedDragKind, wasClick {
            canvas?.focusBroker?.enterScope(.tile(tile.id), reason: .userClick)
            return
        }

        super.mouseUp(with: event)
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

    func qaResizeEdge(at point: CGPoint) -> ResizeEdge? {
        resizeEdge(at: point)
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
private final class TitleBarView: NSView {
    var tile: Tile { didSet { needsDisplay = true } }
    var agentStatus: AgentStatus? { didSet { needsDisplay = true } }
    var onCloseRequested: (() -> Void)?
    var onStopRunRequested: (() -> Void)?
    private var accessoryView: NSView?

    var snapshot: TileNSView.ChromeSnapshot {
        TileNSView.ChromeSnapshot(
            title: "\(tile.kind.rawValue.capitalized) · \(tile.title)",
            agentStatus: agentStatus,
            agentStatusLabel: agentStatus.map(Self.label(for:))
        )
    }

    private let closeButton: NSButton

    init(tile: Tile, agentStatus: AgentStatus? = nil) {
        self.tile = tile
        self.agentStatus = agentStatus
        let btn = NSButton()
        // Plain `xmark` (not `xmark.circle.fill`) is a monochrome SF symbol
        // that respects contentTintColor — the filled multicolor variant
        // renders red regardless of tint, which read as "alert" inside a
        // dark, dense canvas.
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
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
        layer?.backgroundColor = NSColor(white: 0.16, alpha: 1.0).cgColor

        btn.target = self
        btn.action = #selector(handleClose(_:))
        addSubview(btn)
        NSLayoutConstraint.activate([
            btn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            btn.centerYAnchor.constraint(equalTo: centerYAnchor),
            btn.widthAnchor.constraint(equalToConstant: 14),
            btn.heightAnchor.constraint(equalToConstant: 14)
        ])
    }

    func setAccessory(_ accessory: NSView?) {
        accessoryView?.removeFromSuperview()
        accessoryView = accessory
        guard let accessory else { return }
        accessory.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accessory)
        NSLayoutConstraint.activate([
            accessory.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -34),
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
        let menu = NSMenu(title: "Tile")
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

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.lightGray
        ]
        let title = "\(tile.kind.rawValue.capitalized) · \(tile.title)" as NSString
        title.draw(at: NSPoint(x: 8, y: 5), withAttributes: attrs)

        if let agentStatus {
            drawAgentStatus(agentStatus)
        }

        // Three-dot drag handle indicator, shifted left of the × close button.
        let dot = NSColor(white: 0.55, alpha: 1.0)
        let radius: CGFloat = 1.5
        let spacing: CGFloat = 4
        let cy = bounds.midY
        var cx = bounds.width - 34
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
        let label = Self.label(for: status)
        let color = Self.color(for: status)
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

    private static func label(for status: AgentStatus) -> String {
        switch status {
        case .configuring: return "configuring"
        case .working: return "working"
        case .idle: return "idle"
        case .needsAttention: return "needs you"
        case .done: return "done"
        case .stale: return "stale"
        }
    }

    private static func color(for status: AgentStatus) -> NSColor {
        switch status {
        case .needsAttention: return .systemOrange
        case .working: return .systemBlue
        case .done: return .systemGreen
        case .stale: return .systemGray
        case .idle: return .systemTeal
        case .configuring: return .systemPurple
        }
    }
}

/// Transparent overlay that draws four corner L-brackets. Each corner has its
/// own NSTrackingArea + CAShapeLayer; on mouse-enter the matching bracket
/// fades in, on exit it fades out. The overlay returns nil from hitTest so it
/// doesn't compete with the body or the resize-ring hitTest on the parent
/// TileNSView. Tracking areas use `.inVisibleRect` so we don't churn them
/// every frame during a drag-resize.
@MainActor
private final class CornerOverlayView: NSView {
    private var cornerLayers: [ResizeEdge: CAShapeLayer] = [:]
    private var cornerAreas: [NSTrackingArea] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let corners: [ResizeEdge] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        for corner in corners {
            let shape = CAShapeLayer()
            shape.strokeColor = NSColor(white: 0.85, alpha: 1.0).cgColor
            shape.fillColor = NSColor.clear.cgColor
            shape.lineWidth = 1.5
            shape.lineCap = .round
            shape.opacity = 0
            layer?.addSublayer(shape)
            cornerLayers[corner] = shape
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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

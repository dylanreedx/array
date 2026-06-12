import AppKit
import ContinuumRevivedCore
import Foundation

/// Tile view base. Subclasses host tile-kind-specific content. The tile's
/// title bar is the drag affordance for moving the tile; the body is for
/// content (terminal interaction, browser, etc.). The 8px ring around the
/// edges is a resize affordance.
@MainActor
class TileNSView: NSView {
    static let titleBarHeight: CGFloat = 24
    static let resizeMargin: CGFloat = 8
    static let cornerHoverSize: CGFloat = 16
    static let cornerBracketLength: CGFloat = 12

    weak var canvas: CanvasNSView?
    var tile: Tile {
        didSet { titleBar?.needsDisplay = true }
    }

    /// Invoked when the user clicks the title bar's × button. The app sets
    /// this to its tile-delete orchestrator at install time.
    var onClose: (() -> Void)?

    private var titleBar: TitleBarView?
    private var cornerOverlay: CornerOverlayView?
    private(set) var contentView: NSView?
    private var dragKind: DragKind = .none
    private var dragLastWindowPoint: CGPoint = .zero

    override var isFlipped: Bool { true }

    init(tile: Tile) {
        self.tile = tile
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.10, alpha: 1.0).cgColor
        layer?.borderColor = NSColor(white: 0.25, alpha: 1.0).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        let bar = TitleBarView(tile: tile)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.onCloseRequested = { [weak self] in self?.onClose?() }
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
        view.translatesAutoresizingMaskIntoConstraints = false
        // Place the body below the corner overlay so the corner brackets
        // remain visible above any tile content. The title bar and × button
        // sit above the body's title-bar zone (y < titleBarHeight) regardless
        // of subview order because the body's frame starts at titleBarHeight.
        if let cornerOverlay {
            addSubview(view, positioned: .below, relativeTo: cornerOverlay)
        } else {
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor, constant: Self.titleBarHeight),
            view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
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
        return super.hitTest(point)
    }

    // MARK: - Mouse handling for drag and resize

    override func mouseDown(with event: NSEvent) {
        canvas?.markActive(tileId: tile.id)
        dragLastWindowPoint = event.locationInWindow
        let local = convert(event.locationInWindow, from: nil)
        if let edge = resizeEdge(at: local) {
            dragKind = .resize(edge)
            return
        }
        if local.y < Self.titleBarHeight {
            dragKind = .move
            return
        }
        // Below the title bar: defer to subclass / content view.
        dragKind = .none
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
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
        dragKind = .none
        super.mouseUp(with: event)
    }

    // MARK: - Cursor affordance

    /// Make the resize ring discoverable: tracking-area-driven cursor rects
    /// for each edge zone, plus a drag-handle cursor over the title bar so the
    /// user reads it as draggable instead of a thin gray strip.
    override func resetCursorRects() {
        super.resetCursorRects()
        let m = Self.resizeMargin
        let titleH = Self.titleBarHeight
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
        addCursorRect(NSRect(x: m, y: m, width: w - 2 * m, height: titleH - m), cursor: .openHand)
    }

    private func resizeEdge(at point: CGPoint) -> ResizeEdge? {
        let m = Self.resizeMargin
        let nearLeft = point.x <= m
        let nearRight = point.x >= bounds.width - m
        let nearTop = point.y <= m
        let nearBottom = point.y >= bounds.height - m

        switch (nearTop, nearBottom, nearLeft, nearRight) {
        case (true, _, true, _):  return .topLeft
        case (true, _, _, true):  return .topRight
        case (_, true, true, _):  return .bottomLeft
        case (_, true, _, true):  return .bottomRight
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
    var onCloseRequested: (() -> Void)?

    private let closeButton: NSButton

    init(tile: Tile) {
        self.tile = tile
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

    @objc private func handleClose(_ sender: Any?) {
        onCloseRequested?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.lightGray
        ]
        let title = "\(tile.kind.rawValue.capitalized) · \(tile.title)" as NSString
        title.draw(at: NSPoint(x: 8, y: 5), withAttributes: attrs)

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

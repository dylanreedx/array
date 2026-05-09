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

    weak var canvas: CanvasNSView?
    var tile: Tile {
        didSet { titleBar?.needsDisplay = true }
    }

    private var titleBar: TitleBarView?
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
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.titleBarHeight)
        ])
        self.titleBar = bar
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Subclasses install their content view via this entry point so the
    /// title bar stays on top and the body is automatically resized.
    func setContentView(_ view: NSView) {
        contentView?.removeFromSuperview()
        contentView = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
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

    // MARK: - Mouse handling for drag and resize

    override func mouseDown(with event: NSEvent) {
        canvas?.bringToFront(tileId: tile.id)
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

/// Lightweight chrome view drawing the tile title and a kind badge.
@MainActor
private final class TitleBarView: NSView {
    var tile: Tile { didSet { needsDisplay = true } }

    init(tile: Tile) {
        self.tile = tile
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.16, alpha: 1.0).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.lightGray
        ]
        let title = "\(tile.kind.rawValue.capitalized) · \(tile.title)" as NSString
        title.draw(at: NSPoint(x: 8, y: 5), withAttributes: attrs)
    }
}

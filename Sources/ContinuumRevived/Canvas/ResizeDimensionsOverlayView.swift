import AppKit

/// Small pass-through overlay that shows a live "W × H" pixel readout near the
/// cursor while a tile is being resized — a sense-of-scale aid on the infinite
/// canvas. Owned by `CanvasNSView`, sized to the canvas, positioned in the
/// canvas's coordinate space; never consumes mouse events.
@MainActor
final class ResizeDimensionsOverlayView: NSView {
    private(set) var dimensionsText: String = ""
    /// Anchor in this view's (overlay-local) coordinate space — near the cursor.
    private var anchor: CGPoint = .zero

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Draw only — never intercept clicks on tiles or the canvas.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func showDimensions(widthPx: Int, heightPx: Int, atOverlayPoint point: CGPoint) {
        dimensionsText = "\(widthPx) × \(heightPx)"
        anchor = point
        isHidden = false
        needsDisplay = true
    }

    func hideOverlay() {
        guard !isHidden else { return }
        isHidden = true
        needsDisplay = true
    }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)

    override func draw(_ dirtyRect: NSRect) {
        guard !dimensionsText.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: NSColor.white
        ]
        let text = dimensionsText as NSString
        let textSize = text.size(withAttributes: attributes)
        let padX: CGFloat = 8, padY: CGFloat = 4
        let pill = CGSize(width: textSize.width + padX * 2, height: textSize.height + padY * 2)
        // Offset up-and-right of the cursor so it doesn't sit under the pointer,
        // clamped inside the overlay bounds.
        var origin = CGPoint(x: anchor.x + 16, y: anchor.y + 16)
        origin.x = max(4, min(origin.x, bounds.maxX - pill.width - 4))
        origin.y = max(4, min(origin.y, bounds.maxY - pill.height - 4))
        let rect = CGRect(origin: origin, size: pill)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        text.draw(at: CGPoint(x: rect.minX + padX, y: rect.minY + padY), withAttributes: attributes)
    }

    // MARK: - QA
    var qaVisible: Bool { !isHidden }
    var qaText: String { dimensionsText }
}

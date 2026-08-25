import AppKit

/// Ephemeral direct parent→child relationship(s). Identity remains in
/// `AgentRecord.parentAgentID`; this view stores only current presentation.
///
/// C11: a fan-out reveal draws the parent's whole visible fan, not just one
/// child — `edges` holds every currently-resolved (start, end) pair, bounded
/// upstream by `CanvasNSView.showContextualAgentLineage(edges:)` to
/// `InboxSort.maxVisibleChildren`.
@MainActor
final class AgentLineageOverlayView: NSView {
    var edges: [(start: CGPoint, end: CGPoint)] = [] { didSet { needsDisplay = true } }
    var reducesMotion = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for edge in edges {
            drawEdge(from: edge.start, to: edge.end)
        }
    }

    private func drawEdge(from startPoint: CGPoint, to endPoint: CGPoint) {
        guard startPoint != endPoint else { return }
        let path = NSBezierPath()
        path.move(to: startPoint)
        let horizontal = max(44, abs(endPoint.x - startPoint.x) * 0.42)
        let direction: CGFloat = endPoint.x >= startPoint.x ? 1 : -1
        path.curve(
            to: endPoint,
            controlPoint1: CGPoint(x: startPoint.x + horizontal * direction, y: startPoint.y),
            controlPoint2: CGPoint(x: endPoint.x - horizontal * direction, y: endPoint.y))
        path.lineWidth = reducesMotion ? 1.25 : 1.5
        path.lineCapStyle = .round
        NSColor.controlAccentColor.withAlphaComponent(0.34).setStroke()
        path.stroke()

        let arrow = NSBezierPath()
        let angle = atan2(endPoint.y - startPoint.y, endPoint.x - startPoint.x)
        let length: CGFloat = 7
        for offset in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
            arrow.move(to: endPoint)
            arrow.line(to: CGPoint(
                x: endPoint.x + cos(angle + offset) * length,
                y: endPoint.y + sin(angle + offset) * length))
        }
        arrow.lineWidth = path.lineWidth
        arrow.lineCapStyle = .round
        arrow.stroke()
    }
}

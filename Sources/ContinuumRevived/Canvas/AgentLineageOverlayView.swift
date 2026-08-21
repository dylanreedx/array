import AppKit

/// Ephemeral direct parent→child relationship. Identity remains in
/// `AgentRecord.parentAgentID`; this view stores only current presentation.
@MainActor
final class AgentLineageOverlayView: NSView {
    var startPoint: CGPoint = .zero { didSet { needsDisplay = true } }
    var endPoint: CGPoint = .zero { didSet { needsDisplay = true } }
    var reducesMotion = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
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

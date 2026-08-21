import AppKit
import ContinuumRevivedCore

/// Quiet, click-through world-space connectors for durable agent/document links.
@MainActor
final class DocumentRelationshipOverlayView: NSView {
    struct Segment {
        var source: CGRect
        var target: CGRect
        var emphasized: Bool
    }

    var segments: [Segment] = [] { didSet { needsDisplay = true } }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for segment in segments {
            let start = CGPoint(x: segment.source.maxX, y: segment.source.midY)
            let end = CGPoint(x: segment.target.minX, y: segment.target.midY)
            let dx = max(36, abs(end.x - start.x) * 0.42)
            let path = NSBezierPath()
            path.move(to: start)
            path.curve(
                to: end,
                controlPoint1: CGPoint(x: start.x + dx, y: start.y),
                controlPoint2: CGPoint(x: end.x - dx, y: end.y)
            )
            path.lineWidth = 1
            NSColor.controlAccentColor.withAlphaComponent(segment.emphasized ? 0.52 : 0.18).setStroke()
            path.stroke()
        }
    }
}

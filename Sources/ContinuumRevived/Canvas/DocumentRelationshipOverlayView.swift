import AppKit
import ContinuumRevivedCore

/// Quiet, click-through world-space connectors for durable agent/document links.
@MainActor
final class DocumentRelationshipOverlayView: NSView {
    struct Segment: Equatable {
        var source: CGRect
        var target: CGRect
        var emphasized: Bool
    }

    enum Route: Equatable {
        case cubic(start: CGPoint, control1: CGPoint, control2: CGPoint, end: CGPoint)
        case polyline([CGPoint])

        var points: [CGPoint] {
            switch self {
            case let .cubic(start, control1, control2, end):
                return [start, control1, control2, end]
            case let .polyline(points):
                return points
            }
        }

        var path: NSBezierPath {
            let path = NSBezierPath()
            switch self {
            case let .cubic(start, control1, control2, end):
                path.move(to: start)
                path.curve(to: end, controlPoint1: control1, controlPoint2: control2)
            case let .polyline(points):
                guard let first = points.first else { return path }
                path.move(to: first)
                for point in points.dropFirst() { path.line(to: point) }
            }
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            return path
        }
    }

    private(set) var displayInvalidationCount = 0
    var segments: [Segment] = [] {
        didSet {
            guard oldValue != segments else { return }
            displayInvalidationCount += 1
            needsDisplay = true
        }
    }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for segment in segments {
            guard let route = Self.route(for: segment) else { continue }
            let path = route.path
            path.lineWidth = 1
            NSColor.controlAccentColor.withAlphaComponent(segment.emphasized ? 0.52 : 0.18).setStroke()
            path.stroke()
        }
    }

    /// A deterministic, world-space route that never lets a Bézier handle cross
    /// the available gap. The overlap fallback deliberately escapes the union of
    /// both tiles, since the connector paints below tile bodies.
    static func route(for segment: Segment) -> Route? {
        let source = segment.source.standardized
        let target = segment.target.standardized
        let scalars = [source.minX, source.minY, source.maxX, source.maxY,
                       target.minX, target.minY, target.maxX, target.maxY]
        guard scalars.allSatisfy(\.isFinite), !source.isEmpty, !target.isEmpty else { return nil }

        let rightGap = target.minX - source.maxX
        let leftGap = source.minX - target.maxX
        if rightGap > 0.5 || leftGap > 0.5 {
            let travelsRight = rightGap >= leftGap
            let start = CGPoint(x: travelsRight ? source.maxX : source.minX, y: source.midY)
            let end = CGPoint(x: travelsRight ? target.minX : target.maxX, y: target.midY)
            let separation = abs(end.x - start.x)
            let handle = min(separation * 0.42, separation * 0.5)
            let direction: CGFloat = travelsRight ? 1 : -1
            return .cubic(
                start: start,
                control1: CGPoint(x: start.x + direction * handle, y: start.y),
                control2: CGPoint(x: end.x - direction * handle, y: end.y),
                end: end)
        }

        let aboveGap = target.minY - source.maxY
        let belowGap = source.minY - target.maxY
        if aboveGap > 0.5 || belowGap > 0.5 {
            let travelsUp = aboveGap >= belowGap
            let start = CGPoint(x: source.midX, y: travelsUp ? source.maxY : source.minY)
            let end = CGPoint(x: target.midX, y: travelsUp ? target.minY : target.maxY)
            let separation = abs(end.y - start.y)
            let handle = min(separation * 0.42, separation * 0.5)
            let direction: CGFloat = travelsUp ? 1 : -1
            return .cubic(
                start: start,
                control1: CGPoint(x: start.x, y: start.y + direction * handle),
                control2: CGPoint(x: end.x, y: end.y - direction * handle),
                end: end)
        }

        let union = source.union(target)
        let clearance: CGFloat = 12
        enum EscapeSide: Int { case top, bottom, right, left }
        let candidates: [(EscapeSide, CGFloat)] = [
            (.top, (union.maxY - source.maxY) + (union.maxY - target.maxY)),
            (.bottom, (source.minY - union.minY) + (target.minY - union.minY)),
            (.right, (union.maxX - source.maxX) + (union.maxX - target.maxX)),
            (.left, (source.minX - union.minX) + (target.minX - union.minX)),
        ]
        let side = candidates.min {
            $0.1 == $1.1 ? $0.0.rawValue < $1.0.rawValue : $0.1 < $1.1
        }!.0
        switch side {
        case .top:
            let y = union.maxY + clearance
            return .polyline([
                CGPoint(x: source.midX, y: source.maxY), CGPoint(x: source.midX, y: y),
                CGPoint(x: target.midX, y: y), CGPoint(x: target.midX, y: target.maxY),
            ])
        case .bottom:
            let y = union.minY - clearance
            return .polyline([
                CGPoint(x: source.midX, y: source.minY), CGPoint(x: source.midX, y: y),
                CGPoint(x: target.midX, y: y), CGPoint(x: target.midX, y: target.minY),
            ])
        case .right:
            let x = union.maxX + clearance
            return .polyline([
                CGPoint(x: source.maxX, y: source.midY), CGPoint(x: x, y: source.midY),
                CGPoint(x: x, y: target.midY), CGPoint(x: target.maxX, y: target.midY),
            ])
        case .left:
            let x = union.minX - clearance
            return .polyline([
                CGPoint(x: source.minX, y: source.midY), CGPoint(x: x, y: source.midY),
                CGPoint(x: x, y: target.midY), CGPoint(x: target.minX, y: target.midY),
            ])
        }
    }
}

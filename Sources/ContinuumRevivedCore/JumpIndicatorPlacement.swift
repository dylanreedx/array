import CoreGraphics
import Foundation

public enum ViewportEdge: String, Equatable, Sendable {
    case left
    case right
    case top
    case bottom
}

public enum JumpIndicatorPlacementKind: Equatable, Sendable {
    case normal
    case edgePill(edge: ViewportEdge)
}

public struct JumpIndicatorPlacement: Equatable, Sendable {
    public var point: CGPoint
    public var kind: JumpIndicatorPlacementKind
    public var visibleIntersection: CGRect

    public init(point: CGPoint, kind: JumpIndicatorPlacementKind, visibleIntersection: CGRect) {
        self.point = point
        self.kind = kind
        self.visibleIntersection = visibleIntersection
    }
}

public enum JumpIndicatorPlacementEngine {
    public static let badgePaddingScreenPx: CGFloat = 12
    public static let normalBadgeMinScreenSize = CGSize(width: 28, height: 24)

    public static func indicatorRect(for placement: JumpIndicatorPlacement, normalBadgeSize: CGSize) -> CGRect {
        switch placement.kind {
        case .normal:
            return CGRect(origin: placement.point, size: normalBadgeSize)
        case .edgePill:
            let size = CGSize(
                width: min(normalBadgeSize.width, placement.visibleIntersection.width),
                height: min(normalBadgeSize.height, placement.visibleIntersection.height)
            )
            let x = min(max(placement.point.x - size.width / 2, placement.visibleIntersection.minX), placement.visibleIntersection.maxX - size.width)
            let y = min(max(placement.point.y - size.height / 2, placement.visibleIntersection.minY), placement.visibleIntersection.maxY - size.height)
            return CGRect(x: x, y: y, width: size.width, height: size.height)
        }
    }

    public static func placement(
        tileScreenFrame: CGRect,
        viewportBounds: CGRect,
        padding: CGFloat = badgePaddingScreenPx,
        normalBadgeMinSize: CGSize = normalBadgeMinScreenSize
    ) -> JumpIndicatorPlacement? {
        guard tileScreenFrame.intersects(viewportBounds) else { return nil }
        let intersection = tileScreenFrame.intersection(viewportBounds)
        guard !intersection.isNull, !intersection.isEmpty else { return nil }

        let inset = intersection.insetBy(dx: padding, dy: padding)
        if inset.width >= normalBadgeMinSize.width, inset.height >= normalBadgeMinSize.height {
            return JumpIndicatorPlacement(
                point: CGPoint(x: inset.minX, y: inset.minY),
                kind: .normal,
                visibleIntersection: intersection
            )
        }

        let point = CGPoint(
            x: min(max(intersection.midX, intersection.minX), intersection.maxX),
            y: min(max(intersection.midY, intersection.minY), intersection.maxY)
        )
        return JumpIndicatorPlacement(
            point: point,
            kind: .edgePill(edge: closestViewportEdge(to: intersection, viewportBounds: viewportBounds)),
            visibleIntersection: intersection
        )
    }

    private static func closestViewportEdge(to rect: CGRect, viewportBounds: CGRect) -> ViewportEdge {
        let distances: [(ViewportEdge, CGFloat)] = [
            (.left, abs(rect.minX - viewportBounds.minX)),
            (.right, abs(viewportBounds.maxX - rect.maxX)),
            (.top, abs(rect.minY - viewportBounds.minY)),
            (.bottom, abs(viewportBounds.maxY - rect.maxY)),
        ]
        return distances.sorted { lhs, rhs in
            if lhs.1 == rhs.1 { return edgeRank(lhs.0) < edgeRank(rhs.0) }
            return lhs.1 < rhs.1
        }[0].0
    }

    private static func edgeRank(_ edge: ViewportEdge) -> Int {
        switch edge {
        case .left: return 0
        case .right: return 1
        case .top: return 2
        case .bottom: return 3
        }
    }
}

import CoreGraphics
import Foundation

/// Pure rectangle-style tile arrangement math in world coordinates.
public enum TileArrangement {
    public enum Direction: String, Equatable, Sendable {
        case up
        case down
        case left
        case right

        public static func fromKey(_ key: String, keymap: NavKeymap = .default) -> Direction? {
            keymap.direction(for: key)
        }
    }

    public enum SnapGuide: Equatable, Sendable {
        case leadingToTrailingGap
        case trailingToLeadingGap
        case topToBottomGap
        case bottomToTopGap
        case leadingAligned
        case trailingAligned
        case topAligned
        case bottomAligned
    }

    public struct SnapResult: Equatable, Sendable {
        public let frame: TileFrame
        public let guides: [SnapGuide]

        public init(frame: TileFrame, guides: [SnapGuide]) {
            self.frame = frame
            self.guides = guides
        }
    }

    /// Parks `frame` gap-adjacent to its nearest neighbor in `direction`.
    ///
    /// "Neighbor" = the closest tile lying strictly ahead in the throw direction
    /// (its near edge at or past the moving tile's far edge, so the tile always
    /// moves forward), scored by forward edge-gap biased toward orthogonal
    /// alignment — the same `primary + 0.5·orthogonal` shape as
    /// `CanvasEngine.nearestTile`. When nothing lies ahead the throw is a no-op:
    /// the tile stays put rather than flinging to the far edge of the union of all
    /// tiles (the old behavior, which dropped the tile somewhere unpredictable).
    public static func throwDestination(_ frame: TileFrame, direction: Direction, others: [TileFrame], gap: Double) -> TileFrame {
        guard let neighbor = nearestNeighbor(ahead: frame, direction: direction, among: others) else {
            return frame
        }
        return moved(frame, direction: direction, against: neighbor, gap: gap)
    }

    /// Magnetize `frame` to nearby tile edges, snapping each axis INDEPENDENTLY to
    /// its closest-within-threshold guide. Per-axis (not one global nearest guide)
    /// so a horizontal drag still snaps the X gap even when the tiles already share
    /// a Y edge — the natural "click into place beside a neighbor" feel. Returns the
    /// frame unchanged with no guides when nothing is within threshold.
    public static func snapAdjustment(_ frame: TileFrame, others: [TileFrame], gap: Double, threshold: Double) -> SnapResult {
        var bestX: (delta: Double, guide: SnapGuide)?
        var bestY: (delta: Double, guide: SnapGuide)?
        func considerX(_ delta: Double, _ guide: SnapGuide) {
            guard abs(delta) <= threshold else { return }
            if bestX == nil || abs(delta) < abs(bestX!.delta) { bestX = (delta, guide) }
        }
        func considerY(_ delta: Double, _ guide: SnapGuide) {
            guard abs(delta) <= threshold else { return }
            if bestY == nil || abs(delta) < abs(bestY!.delta) { bestY = (delta, guide) }
        }

        for other in others {
            if orthogonalExtentsOverlap(frame, other, direction: .left) {
                considerX(other.x - gap - (frame.x + frame.width), .trailingToLeadingGap)
                considerX(other.x + other.width + gap - frame.x, .leadingToTrailingGap)
                considerX(other.x - frame.x, .leadingAligned)
                considerX(other.x + other.width - (frame.x + frame.width), .trailingAligned)
            }
            if orthogonalExtentsOverlap(frame, other, direction: .up) {
                considerY(other.y - gap - (frame.y + frame.height), .bottomToTopGap)
                considerY(other.y + other.height + gap - frame.y, .topToBottomGap)
                considerY(other.y - frame.y, .topAligned)
                considerY(other.y + other.height - (frame.y + frame.height), .bottomAligned)
            }
        }

        var adjusted = frame
        var guides: [SnapGuide] = []
        if let bestX { adjusted.x += bestX.delta; guides.append(bestX.guide) }
        if let bestY { adjusted.y += bestY.delta; guides.append(bestY.guide) }
        return SnapResult(frame: adjusted, guides: guides)
    }

    /// Magnetize `frame` into a clean 90° corner against a single "dock" neighbor.
    ///
    /// Model A — "dock tile only": pick the neighbor whose facing edge yields the
    /// smallest within-threshold *gap* snap, park `frame` gap-adjacent to it, then —
    /// for that **same** neighbor — align the perpendicular edge (top↔top / bottom↔bottom
    /// for a side-by-side dock; left↔left / right↔right for a stacked dock) so the shared
    /// edges meet at a corner. Only the dock neighbor influences `frame`, so the snap
    /// stays predictable instead of grabbing every nearby tile. This is what
    /// `snapAdjustment` can't do alone: its per-axis overlap gate blocks the
    /// perpendicular alignment exactly when tiles dock side-by-side. Returns `frame`
    /// unchanged with no guides when no neighbor is within gap range.
    public static func cornerSnap(_ frame: TileFrame, others: [TileFrame], gap: Double, threshold: Double) -> SnapResult {
        // Dock candidate: a within-threshold gap snap on one axis, gated (like
        // snapAdjustment) by perpendicular overlap so it reads as a real dock.
        var bestDock: (delta: Double, guide: SnapGuide, horizontal: Bool, neighbor: TileFrame)?
        func considerDock(_ delta: Double, _ guide: SnapGuide, horizontal: Bool, _ neighbor: TileFrame) {
            guard abs(delta) <= threshold else { return }
            if bestDock == nil || abs(delta) < abs(bestDock!.delta) {
                bestDock = (delta, guide, horizontal, neighbor)
            }
        }

        for other in others {
            // Side-by-side dock: X gap, requires Y overlap.
            if orthogonalExtentsOverlap(frame, other, direction: .left) {
                considerDock(other.x - gap - (frame.x + frame.width), .trailingToLeadingGap, horizontal: true, other)
                considerDock(other.x + other.width + gap - frame.x, .leadingToTrailingGap, horizontal: true, other)
            }
            // Stacked dock: Y gap, requires X overlap.
            if orthogonalExtentsOverlap(frame, other, direction: .up) {
                considerDock(other.y - gap - (frame.y + frame.height), .bottomToTopGap, horizontal: false, other)
                considerDock(other.y + other.height + gap - frame.y, .topToBottomGap, horizontal: false, other)
            }
        }

        guard let dock = bestDock else { return SnapResult(frame: frame, guides: []) }

        var adjusted = frame
        var guides: [SnapGuide] = [dock.guide]
        let n = dock.neighbor

        if dock.horizontal {
            adjusted.x += dock.delta
            // Corner: align top or bottom edge to the same neighbor (no overlap gate —
            // a side-by-side dock has no X overlap, which is exactly what snapAdjustment
            // would have required).
            if let align = nearestAlignment([
                (n.y - frame.y, .topAligned),
                (n.y + n.height - (frame.y + frame.height), .bottomAligned),
            ], threshold: threshold) {
                adjusted.y += align.delta
                guides.append(align.guide)
            }
        } else {
            adjusted.y += dock.delta
            if let align = nearestAlignment([
                (n.x - frame.x, .leadingAligned),
                (n.x + n.width - (frame.x + frame.width), .trailingAligned),
            ], threshold: threshold) {
                adjusted.x += align.delta
                guides.append(align.guide)
            }
        }

        return SnapResult(frame: adjusted, guides: guides)
    }

    private static func nearestAlignment(_ candidates: [(delta: Double, guide: SnapGuide)], threshold: Double) -> (delta: Double, guide: SnapGuide)? {
        candidates
            .filter { abs($0.delta) <= threshold }
            .min { abs($0.delta) < abs($1.delta) }
    }

    /// Snap a live resize so the dragged edge aligns with (or parks gap-adjacent to) a
    /// nearby neighbor's edge — letting a tile take on a docked neighbor's dimension by
    /// dragging an edge flush to it (drag a short tile's bottom edge down to a taller
    /// neighbor's bottom → equal heights). Only neighbors overlapping `frame` on the
    /// dragged edge's own axis are candidates (the "docked beside" band, so the snap
    /// isn't grabby). Snaps the dragged coordinate to the nearest neighbor edge within
    /// threshold, keeps the opposite edge fixed, and clamps the result to `minimum`.
    /// Returns `frame` unchanged with no guides when nothing is in range.
    public static func resizeEdgeSnap(_ frame: TileFrame, edge: ResizeEdge, others: [TileFrame], gap: Double, threshold: Double, minimum: CGSize) -> SnapResult {
        var adjusted = frame
        var guides: [SnapGuide] = []

        if edge.touchesTop || edge.touchesBottom {
            let originControls = edge.touchesTop // .top moves frame.y; .bottom moves the far edge
            let edges = others
                .filter { orthogonalExtentsOverlap(frame, $0, direction: .left) } // Y overlap
                .map { (near: $0.y, far: $0.y + $0.height) }
            if let snap = snapResizeAxis(origin: adjusted.y, extent: adjusted.height, originControls: originControls, edges: edges, gap: gap, threshold: threshold, minimum: Double(minimum.height), guide: originControls ? .topAligned : .bottomAligned) {
                adjusted.y = snap.origin
                adjusted.height = snap.extent
                guides.append(snap.guide)
            }
        }

        if edge.touchesLeft || edge.touchesRight {
            let originControls = edge.touchesLeft
            let edges = others
                .filter { orthogonalExtentsOverlap(frame, $0, direction: .up) } // X overlap
                .map { (near: $0.x, far: $0.x + $0.width) }
            if let snap = snapResizeAxis(origin: adjusted.x, extent: adjusted.width, originControls: originControls, edges: edges, gap: gap, threshold: threshold, minimum: Double(minimum.width), guide: originControls ? .leadingAligned : .trailingAligned) {
                adjusted.x = snap.origin
                adjusted.width = snap.extent
                guides.append(snap.guide)
            }
        }

        return SnapResult(frame: adjusted, guides: guides)
    }

    /// Snap one axis of a resize: move the dragged coordinate (the origin edge when
    /// `originControls`, else the far edge) to the nearest neighbor edge / gap-offset
    /// within threshold, keep the opposite edge fixed, and clamp the extent to `minimum`.
    private static func snapResizeAxis(origin: Double, extent: Double, originControls: Bool, edges: [(near: Double, far: Double)], gap: Double, threshold: Double, minimum: Double, guide: SnapGuide) -> (origin: Double, extent: Double, guide: SnapGuide)? {
        let far = origin + extent
        let current = originControls ? origin : far
        var bestDelta: Double?
        func consider(_ target: Double) {
            let delta = target - current
            guard abs(delta) <= threshold else { return }
            if bestDelta == nil || abs(delta) < abs(bestDelta!) { bestDelta = delta }
        }
        for e in edges {
            consider(e.near)       // align to neighbor's near edge (matching dimension)
            consider(e.far)        // align to neighbor's far edge (matching dimension)
            consider(e.near - gap) // park gap outside the near edge
            consider(e.far + gap)  // park gap outside the far edge
        }
        guard let delta = bestDelta else { return nil }
        let snapped = current + delta
        if originControls {
            let newOrigin = min(snapped, far - minimum) // never shrink below minimum
            return (newOrigin, far - newOrigin, guide)
        } else {
            let newFar = max(snapped, origin + minimum)
            return (origin, newFar - origin, guide)
        }
    }

    private static func orthogonalExtentsOverlap(_ a: TileFrame, _ b: TileFrame, direction: Direction) -> Bool {
        switch direction {
        case .up, .down: return a.x < b.x + b.width && b.x < a.x + a.width
        case .left, .right: return a.y < b.y + b.height && b.y < a.y + a.height
        }
    }

    private static func nearestNeighbor(ahead frame: TileFrame, direction: Direction, among others: [TileFrame]) -> TileFrame? {
        let frameCenterX = frame.x + frame.width / 2
        let frameCenterY = frame.y + frame.height / 2
        return others
            .compactMap { other -> (frame: TileFrame, score: Double)? in
                let primary: Double
                let orthogonal: Double
                switch direction {
                case .left:
                    guard other.x + other.width <= frame.x else { return nil }
                    primary = frame.x - (other.x + other.width)
                    orthogonal = abs((other.y + other.height / 2) - frameCenterY)
                case .right:
                    guard other.x >= frame.x + frame.width else { return nil }
                    primary = other.x - (frame.x + frame.width)
                    orthogonal = abs((other.y + other.height / 2) - frameCenterY)
                case .up:
                    guard other.y + other.height <= frame.y else { return nil }
                    primary = frame.y - (other.y + other.height)
                    orthogonal = abs((other.x + other.width / 2) - frameCenterX)
                case .down:
                    guard other.y >= frame.y + frame.height else { return nil }
                    primary = other.y - (frame.y + frame.height)
                    orthogonal = abs((other.x + other.width / 2) - frameCenterX)
                }
                return (other, primary + 0.5 * orthogonal)
            }
            .min { $0.score < $1.score }?
            .frame
    }

    private static func moved(_ frame: TileFrame, direction: Direction, against obstacle: TileFrame, gap: Double) -> TileFrame {
        switch direction {
        case .up: return TileFrame(x: frame.x, y: obstacle.y + obstacle.height + gap, width: frame.width, height: frame.height)
        case .down: return TileFrame(x: frame.x, y: obstacle.y - gap - frame.height, width: frame.width, height: frame.height)
        case .left: return TileFrame(x: obstacle.x + obstacle.width + gap, y: frame.y, width: frame.width, height: frame.height)
        case .right: return TileFrame(x: obstacle.x - gap - frame.width, y: frame.y, width: frame.width, height: frame.height)
        }
    }
}

public enum TileGapResolver {
    public static let userDefaultsKey = "continuum.tileGap"
    public static let defaultGap: Double = 8

    public static func resolvedGap(defaults: UserDefaults = .standard) -> Double {
        let value = defaults.double(forKey: userDefaultsKey)
        return value.isFinite && value > 0 ? value : defaultGap
    }
}

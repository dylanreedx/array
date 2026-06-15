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

    public static func snapAdjustment(_ frame: TileFrame, others: [TileFrame], gap: Double, threshold: Double) -> SnapResult {
        var best: (axis: Int, delta: Double, guide: SnapGuide)?
        func consider(axis: Int, delta: Double, guide: SnapGuide) {
            guard abs(delta) <= threshold else { return }
            if best == nil || abs(delta) < abs(best!.delta) { best = (axis, delta, guide) }
        }

        for other in others {
            if orthogonalExtentsOverlap(frame, other, direction: .left) {
                consider(axis: 0, delta: other.x - gap - (frame.x + frame.width), guide: .trailingToLeadingGap)
                consider(axis: 0, delta: other.x + other.width + gap - frame.x, guide: .leadingToTrailingGap)
                consider(axis: 0, delta: other.x - frame.x, guide: .leadingAligned)
                consider(axis: 0, delta: other.x + other.width - (frame.x + frame.width), guide: .trailingAligned)
            }
            if orthogonalExtentsOverlap(frame, other, direction: .up) {
                consider(axis: 1, delta: other.y - gap - (frame.y + frame.height), guide: .bottomToTopGap)
                consider(axis: 1, delta: other.y + other.height + gap - frame.y, guide: .topToBottomGap)
                consider(axis: 1, delta: other.y - frame.y, guide: .topAligned)
                consider(axis: 1, delta: other.y + other.height - (frame.y + frame.height), guide: .bottomAligned)
            }
        }

        guard let best else { return SnapResult(frame: frame, guides: []) }
        let adjusted: TileFrame
        if best.axis == 0 {
            adjusted = TileFrame(x: frame.x + best.delta, y: frame.y, width: frame.width, height: frame.height)
        } else {
            adjusted = TileFrame(x: frame.x, y: frame.y + best.delta, width: frame.width, height: frame.height)
        }
        return SnapResult(frame: adjusted, guides: [best.guide])
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

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

    public static func throwDestination(_ frame: TileFrame, direction: Direction, others: [TileFrame], gap: Double) -> TileFrame {
        guard !others.isEmpty else { return frame }

        let overlapping = others.filter { orthogonalExtentsOverlap(frame, $0, direction: direction) }
        if let obstacle = firstObstacle(from: frame, direction: direction, others: overlapping) {
            return moved(frame, direction: direction, against: obstacle, gap: gap)
        }

        let union = others.dropFirst().reduce(others[0].cgRect) { $0.union($1.cgRect) }
        switch direction {
        case .up: return TileFrame(x: frame.x, y: Double(union.minY) - gap - frame.height, width: frame.width, height: frame.height)
        case .down: return TileFrame(x: frame.x, y: Double(union.maxY) + gap, width: frame.width, height: frame.height)
        case .left: return TileFrame(x: Double(union.minX) - gap - frame.width, y: frame.y, width: frame.width, height: frame.height)
        case .right: return TileFrame(x: Double(union.maxX) + gap, y: frame.y, width: frame.width, height: frame.height)
        }
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

    private static func firstObstacle(from frame: TileFrame, direction: Direction, others: [TileFrame]) -> TileFrame? {
        switch direction {
        case .up: return others.filter { $0.y + $0.height <= frame.y }.max { $0.y + $0.height < $1.y + $1.height }
        case .down: return others.filter { $0.y >= frame.y + frame.height }.min { $0.y < $1.y }
        case .left: return others.filter { $0.x + $0.width <= frame.x }.max { $0.x + $0.width < $1.x + $1.width }
        case .right: return others.filter { $0.x >= frame.x + frame.width }.min { $0.x < $1.x }
        }
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

private extension TileFrame {
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

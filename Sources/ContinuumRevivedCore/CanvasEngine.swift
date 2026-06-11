import CoreGraphics
import Foundation

/// Pure geometry for the project canvas: coordinate conversion, cursor-anchored
/// zoom, hit testing, drag/resize math, z-order, group bounds, fit-to-bounds.
///
/// Convention: world coordinates have positive X to the right and positive Y
/// going DOWN (top-left origin, like SwiftUI / web). Tile frames are stored in
/// world coordinates. The viewport's `(x, y)` is the world point at the screen's
/// top-left corner; `zoom` is screen pixels per world unit.
public enum CanvasEngine {

    // MARK: - Coordinate conversion

    public static func worldToScreen(_ point: CGPoint, viewport: CanvasViewport) -> CGPoint {
        CGPoint(
            x: (Double(point.x) - viewport.x) * viewport.zoom,
            y: (Double(point.y) - viewport.y) * viewport.zoom
        )
    }

    public static func screenToWorld(_ point: CGPoint, viewport: CanvasViewport) -> CGPoint {
        CGPoint(
            x: Double(point.x) / viewport.zoom + viewport.x,
            y: Double(point.y) / viewport.zoom + viewport.y
        )
    }

    public static func tileScreenFrame(_ frame: TileFrame, viewport: CanvasViewport) -> CGRect {
        let topLeft = worldToScreen(CGPoint(x: frame.x, y: frame.y), viewport: viewport)
        return CGRect(
            x: topLeft.x,
            y: topLeft.y,
            width: frame.width * viewport.zoom,
            height: frame.height * viewport.zoom
        )
    }

    // MARK: - Zoom

    public static let defaultZoomRange: ClosedRange<Double> = 0.1 ... 4.0

    /// Multiply the viewport zoom by `factor`, anchored on `anchorScreen`. The
    /// world point under that anchor stays fixed across the zoom.
    public static func zoom(
        _ viewport: CanvasViewport,
        by factor: Double,
        anchorScreen: CGPoint,
        range: ClosedRange<Double> = defaultZoomRange
    ) -> CanvasViewport {
        let worldUnder = screenToWorld(anchorScreen, viewport: viewport)
        let newZoom = clamp(viewport.zoom * factor, to: range)
        // After zoom: anchor = (worldUnder - newOrigin) * newZoom
        //           → newOrigin = worldUnder - anchor / newZoom
        let newX = Double(worldUnder.x) - Double(anchorScreen.x) / newZoom
        let newY = Double(worldUnder.y) - Double(anchorScreen.y) / newZoom
        return CanvasViewport(x: newX, y: newY, zoom: newZoom)
    }

    // MARK: - Hit testing

    /// Topmost tile (by zIndex) whose frame contains the converted world point.
    public static func hitTest(
        screenPoint: CGPoint,
        viewport: CanvasViewport,
        tiles: [Tile]
    ) -> Tile? {
        let world = screenToWorld(screenPoint, viewport: viewport)
        return tiles
            .sorted { $0.zIndex > $1.zIndex }
            .first { tile in
                let f = tile.frame
                return Double(world.x) >= f.x
                    && Double(world.x) <= f.x + f.width
                    && Double(world.y) >= f.y
                    && Double(world.y) <= f.y + f.height
            }
    }

    // MARK: - Defaults and minimums per tile kind

    public static func defaultFrame(for kind: TileKind) -> CGSize {
        switch kind {
        case .terminal: return CGSize(width: 900, height: 620)
        case .browser:  return CGSize(width: 1000, height: 700)
        case .note:     return CGSize(width: 600, height: 400)
        case .file:     return CGSize(width: 320, height: 500)
        case .fileTree: return CGSize(width: 360, height: 520)
        }
    }

    public static func minimumFrame(for kind: TileKind) -> CGSize {
        switch kind {
        case .terminal: return CGSize(width: 280, height: 180)
        case .browser:  return CGSize(width: 320, height: 220)
        case .note:     return CGSize(width: 240, height: 160)
        case .file:     return CGSize(width: 200, height: 200)
        case .fileTree: return CGSize(width: 220, height: 240)
        }
    }

    // MARK: - Spawn placement

    /// First-fit placement: scan candidate origins inside the visible viewport
    /// (row-major, 32pt grid step) for the first rect of `size` that does not
    /// intersect any existing tile frame inflated by 16pt margin. Falls back to
    /// cascade (+24,+24 from the last tile) when the viewport is saturated.
    public static func placementFrame(
        size: CGSize,
        viewport: CanvasViewport,
        visibleSize: CGSize,
        existing: [TileFrame]
    ) -> TileFrame {
        let width = max(Double(size.width), 0)
        let height = max(Double(size.height), 0)
        let zoom = viewport.zoom.isFinite && viewport.zoom > 0 ? viewport.zoom : 1
        let visibleWidth = max(Double(visibleSize.width), 0) / zoom
        let visibleHeight = max(Double(visibleSize.height), 0) / zoom
        let minX = viewport.x
        let minY = viewport.y
        let maxX = max(minX, viewport.x + visibleWidth - width)
        let maxY = max(minY, viewport.y + visibleHeight - height)
        let step = 32.0
        let inflatedExisting = existing.map { rect(for: $0).insetBy(dx: -16, dy: -16) }

        var y = minY
        while y <= maxY + 0.001 {
            var x = minX
            while x <= maxX + 0.001 {
                let candidate = TileFrame(x: x, y: y, width: width, height: height)
                let candidateRect = rect(for: candidate)
                if !inflatedExisting.contains(where: { $0.intersects(candidateRect) }) {
                    return candidate
                }
                x += step
            }
            y += step
        }

        guard let last = existing.last else {
            return TileFrame(x: minX, y: minY, width: width, height: height)
        }
        return TileFrame(x: last.x + 24, y: last.y + 24, width: width, height: height)
    }

    private static func rect(for frame: TileFrame) -> CGRect {
        CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }

    // MARK: - Drag and resize

    /// Move the tile by a screen-space delta. World-space delta is `screenDelta / zoom`.
    public static func tile(_ tile: Tile, draggedByScreenDelta delta: CGSize, viewport: CanvasViewport) -> Tile {
        let worldDx = Double(delta.width) / viewport.zoom
        let worldDy = Double(delta.height) / viewport.zoom
        var moved = tile
        moved.frame.x += worldDx
        moved.frame.y += worldDy
        return moved
    }

    /// Resize the tile by a screen-space delta on the chosen edge, clamping to
    /// the kind's minimum frame.
    public static func tile(
        _ tile: Tile,
        resizedByScreenDelta delta: CGSize,
        edge: ResizeEdge,
        viewport: CanvasViewport
    ) -> Tile {
        let dx = Double(delta.width) / viewport.zoom
        let dy = Double(delta.height) / viewport.zoom
        var frame = tile.frame
        let minSize = minimumFrame(for: tile.kind)

        if edge.touchesLeft {
            let proposedX = frame.x + dx
            let proposedW = frame.width - dx
            if proposedW < minSize.width {
                frame.x += frame.width - minSize.width
                frame.width = minSize.width
            } else {
                frame.x = proposedX
                frame.width = proposedW
            }
        }
        if edge.touchesRight {
            frame.width = max(frame.width + dx, minSize.width)
        }
        if edge.touchesTop {
            let proposedY = frame.y + dy
            let proposedH = frame.height - dy
            if proposedH < minSize.height {
                frame.y += frame.height - minSize.height
                frame.height = minSize.height
            } else {
                frame.y = proposedY
                frame.height = proposedH
            }
        }
        if edge.touchesBottom {
            frame.height = max(frame.height + dy, minSize.height)
        }

        var resized = tile
        resized.frame = frame
        return resized
    }

    // MARK: - Z-order

    /// Promote `tileId` above every other tile by setting its zIndex to
    /// `max + 1`. Other tiles are unchanged. Use `renormalizeZOrder` to keep
    /// the integer space compact.
    public static func bringToFront(tileId: UUID, in tiles: [Tile]) -> [Tile] {
        let maxZ = tiles.map(\.zIndex).max() ?? 0
        return tiles.map { tile in
            guard tile.id == tileId else { return tile }
            var promoted = tile
            promoted.zIndex = maxZ + 1
            return promoted
        }
    }

    /// Compress the z-index space to `0 ... n-1` while preserving order.
    public static func renormalizeZOrder(_ tiles: [Tile]) -> [Tile] {
        let sorted = tiles.sorted { $0.zIndex < $1.zIndex }
        var rank: [UUID: Int] = [:]
        for (i, tile) in sorted.enumerated() {
            rank[tile.id] = i
        }
        return tiles.map { tile in
            var compressed = tile
            compressed.zIndex = rank[tile.id] ?? tile.zIndex
            return compressed
        }
    }

    // MARK: - Group bounds

    /// Bounding rect (in world coordinates) of the union of the group's
    /// member-tile frames. Returns nil if no member tile exists in `tiles`.
    public static func groupBounds(_ group: TileGroup, in tiles: [Tile]) -> CGRect? {
        let members = tiles.filter { group.tileIds.contains($0.id) }
        guard !members.isEmpty else { return nil }
        let minX = members.map { $0.frame.x }.min()!
        let minY = members.map { $0.frame.y }.min()!
        let maxX = members.map { $0.frame.x + $0.frame.width }.max()!
        let maxY = members.map { $0.frame.y + $0.frame.height }.max()!
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Fit-to-bounds

    /// Viewport that places `worldRect` centered inside `viewportSize` with
    /// `padding` of empty space on each axis, clamped to the zoom range.
    public static func fit(
        worldRect: CGRect,
        viewportSize: CGSize,
        padding: Double = 40,
        range: ClosedRange<Double> = defaultZoomRange
    ) -> CanvasViewport {
        let availW = max(Double(viewportSize.width) - 2 * padding, 1)
        let availH = max(Double(viewportSize.height) - 2 * padding, 1)
        let zX = availW / Double(worldRect.width)
        let zY = availH / Double(worldRect.height)
        let zoom = clamp(min(zX, zY), to: range)
        let centerX = Double(worldRect.midX)
        let centerY = Double(worldRect.midY)
        let originX = centerX - Double(viewportSize.width) / 2 / zoom
        let originY = centerY - Double(viewportSize.height) / 2 / zoom
        return CanvasViewport(x: originX, y: originY, zoom: zoom)
    }
}

public enum ResizeEdge: Sendable {
    case top
    case bottom
    case left
    case right
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    fileprivate var touchesTop: Bool {
        self == .top || self == .topLeft || self == .topRight
    }
    fileprivate var touchesBottom: Bool {
        self == .bottom || self == .bottomLeft || self == .bottomRight
    }
    fileprivate var touchesLeft: Bool {
        self == .left || self == .topLeft || self == .bottomLeft
    }
    fileprivate var touchesRight: Bool {
        self == .right || self == .topRight || self == .bottomRight
    }
}

private func clamp<T: Comparable>(_ value: T, to range: ClosedRange<T>) -> T {
    min(max(value, range.lowerBound), range.upperBound)
}

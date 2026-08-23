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

    // MARK: - Zone-local ↔ world conversion

    public static func zoneLocalToWorld(_ point: CGPoint, zoneOrigin: ZonePoint) -> CGPoint {
        CGPoint(x: Double(point.x) + zoneOrigin.x, y: Double(point.y) + zoneOrigin.y)
    }

    public static func worldToZoneLocal(_ point: CGPoint, zoneOrigin: ZonePoint) -> CGPoint {
        CGPoint(x: Double(point.x) - zoneOrigin.x, y: Double(point.y) - zoneOrigin.y)
    }

    public static func zoneLocalToWorld(_ frame: TileFrame, zoneOrigin: ZonePoint) -> TileFrame {
        TileFrame(
            x: frame.x + zoneOrigin.x,
            y: frame.y + zoneOrigin.y,
            width: frame.width,
            height: frame.height
        )
    }

    public static func worldToZoneLocal(_ frame: TileFrame, zoneOrigin: ZonePoint) -> TileFrame {
        TileFrame(
            x: frame.x - zoneOrigin.x,
            y: frame.y - zoneOrigin.y,
            width: frame.width,
            height: frame.height
        )
    }

    public static func worldFrame(tile: Tile, in zone: ZonePlacement) -> TileFrame {
        zoneLocalToWorld(tile.frame, zoneOrigin: zone.origin)
    }

    public static func worldFrame(frame: TileFrame, in zone: ZonePlacement) -> TileFrame {
        zoneLocalToWorld(frame, zoneOrigin: zone.origin)
    }

    public static func zoneLocalPoint(world point: CGPoint, zone: ZonePlacement) -> CGPoint {
        worldToZoneLocal(point, zoneOrigin: zone.origin)
    }

    public static func zoneWorldFrame(_ zone: ZonePlacement) -> TileFrame {
        TileFrame(x: zone.origin.x, y: zone.origin.y, width: zone.size.width, height: zone.size.height)
    }

    /// The zone the camera is looking at: the topmost project-backed zone whose
    /// world frame contains the viewport CENTRE. T2 (`.plans/47`).
    ///
    /// `nil` means "no answer", NOT "disarm" — the caller must leave the armed
    /// zone alone. Panning across empty canvas, or over a group zone, is not a
    /// request to stop targeting the zone you were working in.
    ///
    /// Deliberately containment and not nearest-centre: "nearest" would arm a zone
    /// far off screen the moment the camera crossed open canvas, which is the same
    /// class of surprise this change exists to remove. `zones` is expected in
    /// z-order (`WorkspaceDocument.zonesInZOrder`, last element frontmost), so the
    /// last container wins exactly as hit-testing does.
    ///
    /// The centre math matches `ZoneHydrationOrchestrator.plan`, which sorts the
    /// live budget by distance from this same point.
    public static func cameraArmedZone(
        zones: [ZonePlacement],
        viewport: CanvasViewport,
        visibleSize: CGSize
    ) -> UUID? {
        let zoom = viewport.zoom.isFinite && viewport.zoom > 0 ? viewport.zoom : 1
        let centerX = viewport.x + (Double(visibleSize.width) / zoom) / 2
        let centerY = viewport.y + (Double(visibleSize.height) / zoom) / 2
        var armed: UUID?
        for zone in zones where zone.projectId != nil {
            let frame = zoneWorldFrame(zone)
            let inside = centerX >= frame.x && centerX <= frame.x + frame.width
                && centerY >= frame.y && centerY <= frame.y + frame.height
            if inside { armed = zone.zoneId }
        }
        return armed
    }

    /// Returns the world-space outer rectangle of the zone chrome (the *adaptive*
    /// drawn rect, NOT the stored `zoneWorldFrame`). Origin = top-left, y-DOWN.
    ///
    /// Non-empty: union of `memberFrames` padded by `padding` on all sides, with
    /// a `headerHeight`-tall band prepended above the union (smaller y = above in
    /// y-down coords). Empty: returns a rect of `minSize` at origin (0,0); the
    /// caller offsets to the zone's stored origin.
    ///
    /// All inputs are clamped: padding ≥ 0, headerHeight ≥ 0, minSize ≥ 1×1.
    public static func zoneBounds(
        memberFrames: [TileFrame],
        padding: Double,
        minSize: CGSize,
        headerHeight: Double
    ) -> TileFrame {
        let p = max(0, padding)
        let hh = max(0, headerHeight)
        let mw = max(1, minSize.width)
        let mh = max(1, minSize.height)

        guard !memberFrames.isEmpty else {
            return TileFrame(x: 0, y: 0, width: mw, height: mh)
        }

        var minX = memberFrames[0].x
        var minY = memberFrames[0].y
        var maxX = memberFrames[0].x + memberFrames[0].width
        var maxY = memberFrames[0].y + memberFrames[0].height
        for f in memberFrames.dropFirst() {
            minX = Swift.min(minX, f.x)
            minY = Swift.min(minY, f.y)
            maxX = Swift.max(maxX, f.x + f.width)
            maxY = Swift.max(maxY, f.y + f.height)
        }
        let uW = maxX - minX
        let uH = maxY - minY
        return TileFrame(
            x: minX - p,
            y: minY - p - hh,
            width: uW + 2 * p,
            height: uH + 2 * p + hh
        )
    }

    // MARK: - Hydration tiers

    public static let defaultHydrationSnapshotMargin: Double = 256

    public static func hydrationTier(
        zone: ZonePlacement,
        viewport: CanvasViewport,
        visibleSize: CGSize,
        focusedTileZone: UUID?,
        snapshotMargin: Double = defaultHydrationSnapshotMargin
    ) -> HydrationTier {
        if zone.hydrationPolicy == .pinnedLive || focusedTileZone == zone.zoneId {
            return .live
        }

        let zoneFrame = zoneWorldFrame(zone)
        let visibleWorldFrame = TileFrame(
            x: viewport.x,
            y: viewport.y,
            width: Double(visibleSize.width) / viewport.zoom,
            height: Double(visibleSize.height) / viewport.zoom
        )

        if intersects(zoneFrame, visibleWorldFrame) {
            return .live
        }

        let margin = max(0, snapshotMargin)
        let snapshotBand = TileFrame(
            x: visibleWorldFrame.x - margin,
            y: visibleWorldFrame.y - margin,
            width: visibleWorldFrame.width + margin * 2,
            height: visibleWorldFrame.height + margin * 2
        )
        return touchesOrIntersects(zoneFrame, snapshotBand) ? .snapshot : .cold
    }

    private static func intersects(_ a: TileFrame, _ b: TileFrame) -> Bool {
        a.x < b.x + b.width
            && a.x + a.width > b.x
            && a.y < b.y + b.height
            && a.y + a.height > b.y
    }

    private static func touchesOrIntersects(_ a: TileFrame, _ b: TileFrame) -> Bool {
        a.x <= b.x + b.width
            && a.x + a.width >= b.x
            && a.y <= b.y + b.height
            && a.y + a.height >= b.y
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

    public struct ZoneHit: Equatable, Sendable {
        public let zoneId: UUID
        public let tile: Tile

        public init(zoneId: UUID, tile: Tile) {
            self.zoneId = zoneId
            self.tile = tile
        }
    }

    /// Topmost tile (by zIndex) whose frame contains the converted world point.
    public static func hitTest(
        screenPoint: CGPoint,
        viewport: CanvasViewport,
        tiles: [Tile]
    ) -> Tile? {
        let world = screenToWorld(screenPoint, viewport: viewport)
        return hitTest(worldPoint: world, tiles: tiles)
    }

    public static func hitTest(worldPoint: CGPoint, tiles: [Tile]) -> Tile? {
        tiles
            .sorted { lhs, rhs in
                if lhs.zPosition != rhs.zPosition { return lhs.zPosition > rhs.zPosition }
                return lhs.id.uuidString > rhs.id.uuidString   // deterministic tie-break
            }
            .first { tile in
                contains(worldPoint, in: tile.frame)
            }
    }

    public static func hitTest(
        worldPoint: CGPoint,
        zones: [NavigationZone],
        tilesByZone: [UUID: [Tile]]
    ) -> ZoneHit? {
        zones
            .sorted { lhs, rhs in
                if lhs.zPosition != rhs.zPosition { return lhs.zPosition > rhs.zPosition }
                return lhs.id.uuidString > rhs.id.uuidString   // deterministic tie-break
            }
            .lazy
            .compactMap { zone -> ZoneHit? in
                guard contains(worldPoint, in: zone.frame) else { return nil }
                let localPoint = worldToZoneLocal(worldPoint, zoneOrigin: ZonePoint(x: zone.frame.x, y: zone.frame.y))
                guard let tile = hitTest(worldPoint: localPoint, tiles: tilesByZone[zone.id] ?? []) else { return nil }
                return ZoneHit(zoneId: zone.id, tile: tile)
            }
            .first
    }

    private static func contains(_ point: CGPoint, in frame: TileFrame) -> Bool {
        Double(point.x) >= frame.x
            && Double(point.x) <= frame.x + frame.width
            && Double(point.y) >= frame.y
            && Double(point.y) <= frame.y + frame.height
    }

    // MARK: - Defaults and minimums per tile kind

    public static func defaultFrame(for kind: TileKind) -> CGSize {
        TileGeometry.preset(for: kind).defaultSize
    }

    public static func minimumFrame(for kind: TileKind) -> CGSize {
        TileGeometry.minimumSize(for: kind)
    }


    // MARK: - Persisted canvas sanitation

    public struct CanvasSanitizationResult: Equatable, Sendable {
        public var canvas: CanvasState
        public var changed: Bool
        public var recenteredViewport: Bool
        public var notes: [String]

        public init(canvas: CanvasState, changed: Bool, recenteredViewport: Bool, notes: [String]) {
            self.canvas = canvas
            self.changed = changed
            self.recenteredViewport = recenteredViewport
            self.notes = notes
        }
    }

    public static func sanitizePersistedCanvas(
        _ canvas: CanvasState,
        visibleSize: CGSize = CGSize(width: 1280, height: 800),
        range: ClosedRange<Double> = defaultZoomRange
    ) -> CanvasSanitizationResult {
        var sanitized = canvas
        var changed = false
        var recentered = false
        var notes: [String] = []

        let originalViewport = sanitized.viewport
        sanitized.viewport.zoom = sanitizedFiniteZoom(sanitized.viewport.zoom, range: range)
        sanitized.viewport.x = sanitizedFiniteCoordinate(sanitized.viewport.x, fallback: 0)
        sanitized.viewport.y = sanitizedFiniteCoordinate(sanitized.viewport.y, fallback: 0)
        let viewportCoordinatesWerePathological = sanitized.viewport.x != originalViewport.x || sanitized.viewport.y != originalViewport.y
        let viewportWasPathological = sanitized.viewport != originalViewport
        if viewportWasPathological {
            changed = true
            notes.append("sanitized persisted viewport")
        }

        sanitized.tiles = sanitized.tiles.map { tile in
            var next = tile
            let originalFrame = next.frame
            next.frame = sanitizedFrame(next.frame, kind: next.kind)
            if next.frame != originalFrame {
                changed = true
                notes.append("sanitized persisted tile frame \(next.id.uuidString)")
            }
            return next
        }

        if viewportCoordinatesWerePathological, let bounds = finiteTileBounds(sanitized.tiles) {
            let old = sanitized.viewport
            sanitized.viewport = fit(worldRect: bounds, viewportSize: visibleSize, range: range)
            if sanitized.viewport != old {
                changed = true
                recentered = true
                notes.append("recentered pathological persisted viewport to visible tile bounds")
            }
        }

        return CanvasSanitizationResult(canvas: sanitized, changed: changed, recenteredViewport: recentered, notes: notes)
    }

    public static func visibleWorldRect(
        viewport: CanvasViewport,
        visibleSize: CGSize,
        range: ClosedRange<Double> = defaultZoomRange
    ) -> CGRect {
        let zoom = sanitizedFiniteZoom(viewport.zoom, range: range)
        let x = sanitizedFiniteCoordinate(viewport.x, fallback: 0)
        let y = sanitizedFiniteCoordinate(viewport.y, fallback: 0)
        return CGRect(
            x: x,
            y: y,
            width: max(Double(visibleSize.width), 1) / zoom,
            height: max(Double(visibleSize.height), 1) / zoom
        )
    }

    public static func finiteTileBounds(_ tiles: [Tile]) -> CGRect? {
        let rects = tiles.map { rect(for: sanitizedFrame($0.frame, kind: $0.kind)) }
            .filter { rect in
                rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
            }
        guard var bounds = rects.first else { return nil }
        for rect in rects.dropFirst() {
            bounds = bounds.union(rect)
        }
        return bounds
    }

    private static func sanitizedFrame(_ frame: TileFrame, kind: TileKind) -> TileFrame {
        let defaults = defaultFrame(for: kind)
        let minimum = minimumFrame(for: kind)
        let width = frame.width.isFinite && frame.width > 0 ? min(frame.width, persistedDimensionLimit) : Double(defaults.width)
        let height = frame.height.isFinite && frame.height > 0 ? min(frame.height, persistedDimensionLimit) : Double(defaults.height)
        return TileFrame(
            x: sanitizedFiniteCoordinate(frame.x, fallback: 0),
            y: sanitizedFiniteCoordinate(frame.y, fallback: 0),
            width: max(width, Double(minimum.width)),
            height: max(height, Double(minimum.height))
        )
    }

    private static let persistedCoordinateLimit = 1_000_000.0
    private static let persistedDimensionLimit = 20_000.0

    private static func sanitizedFiniteZoom(_ zoom: Double, range: ClosedRange<Double>) -> Double {
        guard zoom.isFinite, zoom > 0 else { return 1 }
        return clamp(zoom, to: range)
    }

    private static func sanitizedFiniteCoordinate(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return clamp(value, to: -persistedCoordinateLimit ... persistedCoordinateLimit)
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
        let width = max(Double(size.width).isFinite ? Double(size.width) : 0, 0)
        let height = max(Double(size.height).isFinite ? Double(size.height) : 0, 0)
        let zoom = viewport.zoom.isFinite && viewport.zoom > 0 ? viewport.zoom : 1
        let visibleWidth = max(Double(visibleSize.width).isFinite ? Double(visibleSize.width) : 0, 0) / zoom
        let visibleHeight = max(Double(visibleSize.height).isFinite ? Double(visibleSize.height) : 0, 0) / zoom
        let minX = viewport.x.isFinite ? viewport.x : 0
        let minY = viewport.y.isFinite ? viewport.y : 0
        let maxX = max(minX, minX + visibleWidth - width)
        let maxY = max(minY, minY + visibleHeight - height)
        let step = 32.0
        let maxColumns = 256
        let maxRows = 256
        let inflatedExisting = existing.map { rect(for: $0).insetBy(dx: -16, dy: -16) }

        var row = 0
        var y = minY
        while y <= maxY + 0.001 && row < maxRows {
            var column = 0
            var x = minX
            while x <= maxX + 0.001 && column < maxColumns {
                let candidate = TileFrame(x: x, y: y, width: width, height: height)
                let candidateRect = rect(for: candidate)
                if !inflatedExisting.contains(where: { $0.intersects(candidateRect) }) {
                    return candidate
                }
                column += 1
                x += step
            }
            row += 1
            y += step
        }

        guard let last = existing.last else {
            return TileFrame(x: minX, y: minY, width: width, height: height)
        }
        let fallbackX = clamp(last.x + 24, to: minX ... max(minX, minX + visibleWidth - width))
        let fallbackY = clamp(last.y + 24, to: minY ... max(minY, minY + visibleHeight - height))
        return TileFrame(x: fallbackX, y: fallbackY, width: width, height: height)
    }

    private static func rect(for frame: TileFrame) -> CGRect {
        CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }

    // MARK: - Directional navigation

    public struct NavigationZone: Equatable, Sendable {
        public let id: UUID
        public var frame: TileFrame
        public var zPosition: FracIndex

        public init(id: UUID, frame: TileFrame, zPosition: FracIndex = .first) {
            self.id = id
            self.frame = frame
            self.zPosition = zPosition
        }
    }

    public static func nearestTile(
        from tileId: UUID,
        direction: TileArrangement.Direction,
        tiles: [Tile]
    ) -> UUID? {
        guard let origin = tiles.first(where: { $0.id == tileId }) else { return nil }
        return nearestRect(
            from: origin.id,
            direction: direction,
            items: tiles.map { NavigationItem(id: $0.id, rect: rect(for: $0.frame), zPosition: $0.zPosition) }
        )
    }

    public static func nearestZone(
        from zoneId: UUID,
        direction: TileArrangement.Direction,
        zones: [NavigationZone]
    ) -> UUID? {
        nearestRect(
            from: zoneId,
            direction: direction,
            items: zones.map { NavigationItem(id: $0.id, rect: rect(for: $0.frame), zPosition: $0.zPosition) }
        )
    }

    private struct NavigationItem {
        let id: UUID
        let rect: CGRect
        let zPosition: FracIndex
    }

    private static func nearestRect(
        from originId: UUID,
        direction: TileArrangement.Direction,
        items: [NavigationItem]
    ) -> UUID? {
        guard let origin = items.first(where: { $0.id == originId }) else { return nil }
        let originCenter = CGPoint(x: origin.rect.midX, y: origin.rect.midY)

        return items
            .filter { $0.id != originId }
            .compactMap { item -> (item: NavigationItem, primary: CGFloat, orthogonal: CGFloat)? in
                let center = CGPoint(x: item.rect.midX, y: item.rect.midY)
                let dx = center.x - originCenter.x
                let dy = center.y - originCenter.y
                let primary: CGFloat
                let orthogonal: CGFloat
                switch direction {
                case .up:
                    guard dy < 0 else { return nil }
                    primary = -dy
                    orthogonal = abs(dx)
                case .down:
                    guard dy > 0 else { return nil }
                    primary = dy
                    orthogonal = abs(dx)
                case .left:
                    guard dx < 0 else { return nil }
                    primary = -dx
                    orthogonal = abs(dy)
                case .right:
                    guard dx > 0 else { return nil }
                    primary = dx
                    orthogonal = abs(dy)
                }
                return (item, primary, orthogonal)
            }
            .min { lhs, rhs in
                let lhsScore = lhs.primary + 0.5 * lhs.orthogonal
                let rhsScore = rhs.primary + 0.5 * rhs.orthogonal
                if lhsScore != rhsScore { return lhsScore < rhsScore }
                if lhs.primary != rhs.primary { return lhs.primary < rhs.primary }
                if lhs.orthogonal != rhs.orthogonal { return lhs.orthogonal < rhs.orthogonal }
                if lhs.item.zPosition != rhs.item.zPosition { return lhs.item.zPosition > rhs.item.zPosition }
                return lhs.item.id.uuidString < rhs.item.id.uuidString
            }?.item.id
    }

    // MARK: - Drag and resize

    /// Move a zone placement by a screen-space delta. World-space delta is `screenDelta / zoom`.
    /// The dy convention matches `tile(_:draggedByScreenDelta:viewport:)`: the caller negates dy
    /// (window-y-up → world-y-down) before passing the delta, so this function simply divides by zoom.
    /// Member tile zone-local frames are unchanged; moving the origin moves them on screen for free.
    public static func zone(_ placement: ZonePlacement, draggedByScreenDelta delta: CGSize, viewport: CanvasViewport) -> ZonePlacement {
        let worldDx = Double(delta.width) / viewport.zoom
        let worldDy = Double(delta.height) / viewport.zoom
        var moved = placement
        moved.origin = ZonePoint(x: placement.origin.x + worldDx, y: placement.origin.y + worldDy)
        return moved
    }

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

    /// The fractional position a NEW tile should spawn at so it lands above
    /// every existing tile: `after(currentMax)`, or `.first` on an empty
    /// canvas. Replaces the old `max(zIndex) + 1` allocation pattern; no
    /// renormalization pass exists or is needed.
    public static func zPositionAbove(_ tiles: [Tile]) -> FracIndex {
        guard let maxZ = tiles.map(\.zPosition).max() else { return .first }
        return FracIndex.after(maxZ)
    }

    /// Promote `tileId` above every other tile via the fractional index:
    /// `after(currentMax)`. Other tiles are unchanged. If the tile is ALREADY
    /// strictly frontmost, the array is returned untouched — bring-to-front
    /// must never move the front item (the old `max + 1` rewrite churned it,
    /// and at precision exhaustion a rewrite could even LOWER it).
    public static func bringToFront(tileId: UUID, in tiles: [Tile]) -> [Tile] {
        guard let target = tiles.first(where: { $0.id == tileId }) else { return tiles }
        let othersMax = tiles.filter { $0.id != tileId }.map(\.zPosition).max()
        guard let othersMax else { return tiles }                 // only tile — already front
        if target.zPosition > othersMax { return tiles }          // already strictly frontmost
        let promotedPosition = FracIndex.after(othersMax)
        return tiles.map { tile in
            guard tile.id == tileId else { return tile }
            var promoted = tile
            promoted.zPosition = promotedPosition
            return promoted
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

    /// Pans (keeping the current `zoom`) so `worldRect`'s center sits at the
    /// center of the viewport. Used by the hold-leader jump to bring the chosen
    /// tile into view without changing scale; the caller falls back to `fit`
    /// when the rect is too large to fit at the current zoom.
    public static func centeredViewport(worldRect: CGRect, viewportSize: CGSize, zoom: Double) -> CanvasViewport {
        let originX = Double(worldRect.midX) - Double(viewportSize.width) / 2 / zoom
        let originY = Double(worldRect.midY) - Double(viewportSize.height) / 2 / zoom
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

    var touchesTop: Bool {
        self == .top || self == .topLeft || self == .topRight
    }
    var touchesBottom: Bool {
        self == .bottom || self == .bottomLeft || self == .bottomRight
    }
    var touchesLeft: Bool {
        self == .left || self == .topLeft || self == .bottomLeft
    }
    var touchesRight: Bool {
        self == .right || self == .topRight || self == .bottomRight
    }
}

private func clamp<T: Comparable>(_ value: T, to range: ClosedRange<T>) -> T {
    min(max(value, range.lowerBound), range.upperBound)
}

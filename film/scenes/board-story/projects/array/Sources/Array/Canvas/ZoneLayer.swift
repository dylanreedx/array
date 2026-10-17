import AppKit

/// One zone's tiles, in ZONE-LOCAL frames.
final class ZoneLayer {
    let id: UUID
    var origin: CGPoint
    private(set) var tiles: [UUID: TileView] = [:]

    init(id: UUID, origin: CGPoint) {
        self.id = id
        self.origin = origin
    }

    func install(_ view: TileView, frame: CGRect) {
        view.frame = frame.offsetBy(dx: origin.x, dy: origin.y)
        tiles[view.tileId] = view
    }
}

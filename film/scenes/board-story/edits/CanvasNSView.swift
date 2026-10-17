import AppKit

/// The infinite canvas. Tiles live in zones; a zone's tiles are laid out in
/// ZONE-LOCAL coordinates and converted to world space at the model boundary.
final class CanvasNSView: NSView {
    private(set) var viewport = Viewport(x: 0, y: 0, zoom: 1)
    private var zoneLayers: [ZoneLayer] = []
    private var activeZoneId: UUID?

    /// Installs a freshly spawned tile into its zone.
    ///
    /// One target zone for framing AND install: framing against the armed
    /// zone while installing into another displaced the tile by the
    /// difference of the two zone origins (the "tile jump").
    func installProjectTile(_ view: TileView, for tile: Tile, scope: CreationScope?) {
        let targetId = scope?.zoneId ?? activeZoneId
        guard let target = zoneLayers.first(where: { $0.id == targetId }) else { return }
        let frame = TilePlacement.frame(for: tile, in: target)
        target.install(view, frame: frame)
        needsLayout = true
    }

    func setViewport(_ next: Viewport) {
        viewport = next
        syncWorldPlaneToCamera()
    }

    private func syncWorldPlaneToCamera() {
        let transform = CGAffineTransform(scaleX: viewport.zoom, y: viewport.zoom)
            .translatedBy(x: -viewport.x, y: -viewport.y)
        worldPlane.setAffineTransform(transform)
    }

    private let worldPlane = CALayer()
}

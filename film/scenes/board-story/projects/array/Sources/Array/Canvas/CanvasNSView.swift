import AppKit

/// The infinite canvas. Tiles live in zones; a zone's tiles are laid out in
/// ZONE-LOCAL coordinates and converted to world space at the model boundary.
final class CanvasNSView: NSView {
    private(set) var viewport = Viewport(x: 0, y: 0, zoom: 1)
    private var zoneLayers: [ZoneLayer] = []
    private var activeZoneId: UUID?

    /// Installs a freshly spawned tile into its zone.
    func installProjectTile(_ view: TileView, for tile: Tile, scope: CreationScope?) {
        // Frame against the zone the user armed...
        let zone = zoneLayers.first { $0.id == activeZoneId }
        let frame = TilePlacement.frame(for: tile, in: zone)
        // ...but install into the scope's zone.
        let target = zoneLayers.first { $0.id == scope?.zoneId } ?? zone
        target?.install(view, frame: frame)
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

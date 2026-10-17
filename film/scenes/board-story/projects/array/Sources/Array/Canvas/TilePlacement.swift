import CoreGraphics

enum TilePlacement {
    /// Where a new tile goes inside `zone`: the first gap that fits,
    /// scanning left to right, top to bottom.
    static func frame(for tile: Tile, in zone: ZoneLayer?) -> CGRect {
        let size = tile.defaultSize
        guard let zone else { return CGRect(origin: .zero, size: size) }
        return GapScanner(occupied: zone.tiles.values.map(\.frame)).firstGap(fitting: size)
    }
}

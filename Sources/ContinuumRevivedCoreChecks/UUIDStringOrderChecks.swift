import Foundation
import ContinuumRevivedCore

/// `UUID.isOrderedBeforeByString` replaced `uuidString < uuidString` in the
/// auto-layout engine (every drag event sorts members and peers with it) and in
/// `CanvasGeometrySnapshot` (twice per spawn and per geometry commit, over every
/// tile in the workspace). Two things must hold:
///
/// 1. The ORDER is unchanged. Layout tie-breaks, the peer push order and
///    snapshot equality all depend on it, so a different order is a different
///    layout. Checked over random ids and ids that differ only at each nibble,
///    where hex digits cross from '9' to 'A'.
/// 2. A drag no longer pays for strings. Asserted as a ratio against the
///    reflected sort a zone drag's solve used to contain, timed in the same
///    process so host speed cancels (see the teeth below).
func runUUIDStringOrderChecks() {
    var mismatches = 0
    var comparisons = 0
    func compare(_ a: UUID, _ b: UUID) {
        comparisons += 1
        if UUID.isOrderedBeforeByString(a, b) != (a.uuidString < b.uuidString) { mismatches += 1 }
    }
    for _ in 0..<20_000 {
        let a = UUID(), b = UUID()
        compare(a, b); compare(b, a); compare(a, a)
    }
    // Ids equal except for one byte, across every nibble boundary.
    for index in 0..<16 {
        for (x, y) in [(0x09, 0x0A), (0x0A, 0x09), (0x90, 0xA0), (0x9F, 0xA0), (0x00, 0xFF), (0x7F, 0x80)] as [(UInt8, UInt8)] {
            var a = UUID().uuid, b = a
            withUnsafeMutableBytes(of: &a) { $0[index] = x }
            withUnsafeMutableBytes(of: &b) { $0[index] = y }
            compare(UUID(uuid: a), UUID(uuid: b))
        }
    }
    expect(mismatches == 0, "UUID byte order disagrees with uuidString order in \(mismatches) of \(comparisons) comparisons")

    let tiles = (0..<4_000).map { index in
        CanvasTileGeometry(tileId: UUID(), frame: TileFrame(x: Double(index), y: 0, width: 10, height: 10), zoneId: nil)
    }
    let snapshot = CanvasGeometrySnapshot(tiles: tiles, zones: [])
    let reference = tiles.sorted { $0.tileId.uuidString < $1.tileId.uuidString }
    expect(snapshot.tiles.map(\.tileId) == reference.map(\.tileId),
           "CanvasGeometrySnapshot no longer orders tiles by uuidString")

    // The teeth: a zone drag's solve against the sort it used to contain.
    // `resolveOuterCollisions` ordered its peers (every zone and every bare
    // tile) with `String(describing:)`, two reflected strings per comparison,
    // on every pointer event of a zone drag. Here the peers are far away, so
    // nothing is pushed and the sort is most of what a solve does: with it,
    // the solve costs at least the reference sort below (ratio <= 1); without
    // it the solve measured ~10x cheaper in release.
    enum Peer: Hashable { case zone(UUID), tile(UUID) }
    let zoneId = UUID()
    let zone = ZonePlacement(zoneId: zoneId, projectId: nil, origin: ZonePoint(x: 0, y: 0),
                             size: ZoneSize(width: 800, height: 600), color: "teal",
                             collapsed: false, hydrationPolicy: .automatic)
    var zones = [zone]
    var layoutTiles = [CanvasAutoLayoutEngine.LayoutTile(
        id: UUID(), frame: TileFrame(x: 40, y: 80, width: 240, height: 160), zoneId: zoneId)]
    for index in 0..<150 {
        zones.append(ZonePlacement(zoneId: UUID(), projectId: nil,
                                   origin: ZonePoint(x: 5_000 + Double(index) * 1_000, y: 0),
                                   size: ZoneSize(width: 800, height: 600), color: "teal",
                                   collapsed: false, hydrationPolicy: .automatic))
        layoutTiles.append(.init(id: UUID(), frame: TileFrame(x: 5_000 + Double(index) * 1_000, y: 2_000,
                                                              width: 240, height: 160), zoneId: nil))
    }
    let scene = CanvasAutoLayoutEngine.Scene(tiles: layoutTiles, zones: zones)
    var dragged = zone
    dragged.origin.x += 40
    let peers: [Peer] = zones.map { .zone($0.zoneId) } + layoutTiles.filter { $0.zoneId == nil }.map { .tile($0.id) }

    func seconds(_ body: () -> Void) -> Double {
        var best = Double.infinity
        for _ in 0..<5 {
            let start = ContinuousClock.now
            body()
            let elapsed = ContinuousClock.now - start
            best = min(best, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        }
        return best
    }
    let solveCost = seconds {
        _ = CanvasAutoLayoutEngine.solve(scene: scene, mutation: .zone(id: zoneId, placement: dragged),
                                         gap: 16, zonePadding: 16, headerHeight: 32)
    }
    let reflectedSortCost = seconds { _ = peers.sorted { String(describing: $0) < String(describing: $1) } }
    let ratio = reflectedSortCost / max(solveCost, 1e-9)
    print(String(format: "UUIDStringOrder comparisons=%d peers=%d zoneDragSolve=%.3fms reflectedPeerSort=%.3fms ratio=%.1fx",
                 comparisons, peers.count, solveCost * 1000, reflectedSortCost * 1000, ratio))
    expect(ratio >= 3, "a zone drag's solve over \(peers.count) peers costs \(solveCost * 1000) ms, only \(ratio)x cheaper than "
           + "the reflected peer sort it used to contain: the engine is building strings again")
}

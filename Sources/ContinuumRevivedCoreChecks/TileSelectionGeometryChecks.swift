import ContinuumRevivedCore
import CoreGraphics
import Foundation

/// Pure geometry witness; the app witness separately drives real canvas gestures.
func runTileSelectionGeometryChecks() {
    func tile(_ kind: TileKind, _ frame: TileFrame) -> Tile {
        Tile(id: UUID(), kind: kind, title: "selection witness", frame: frame,
             zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
    }
    func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000001 }
    let a = tile(.note, TileFrame(x: -300, y: 200, width: 480, height: 320))
    let b = tile(.browser, TileFrame(x: 280, y: 260, width: 640, height: 440))
    let snapshot = TileSelectionGeometry.Snapshot(tiles: [a, b])!
    expect(snapshot.bounds == TileFrame(x: -300, y: 200, width: 1220, height: 500), "selection union uses world coordinates and gaps")
    let moved = snapshot.translated(byWorldDelta: CGSize(width: 51.25, height: -73.5))!
    expect(moved[a.id] == TileFrame(x: -248.75, y: 126.5, width: 480, height: 320), "group translation preserves first tile size")
    expect(moved[b.id] == TileFrame(x: 331.25, y: 186.5, width: 640, height: 440), "group translation preserves second tile offset")
    expect(snapshot.translated(byWorldDelta: .zero)![a.id] == a.frame, "translation always derives from captured baseline")

    let edges: [ResizeEdge] = [.top, .bottom, .left, .right, .topLeft, .topRight, .bottomLeft, .bottomRight]
    for edge in edges {
        let left: Bool
        let right: Bool
        let top: Bool
        let bottom: Bool
        switch edge {
        case .left: (left, right, top, bottom) = (true, false, false, false)
        case .right: (left, right, top, bottom) = (false, true, false, false)
        case .top: (left, right, top, bottom) = (false, false, true, false)
        case .bottom: (left, right, top, bottom) = (false, false, false, true)
        case .topLeft: (left, right, top, bottom) = (true, false, true, false)
        case .topRight: (left, right, top, bottom) = (false, true, true, false)
        case .bottomLeft: (left, right, top, bottom) = (true, false, false, true)
        case .bottomRight: (left, right, top, bottom) = (false, true, false, true)
        }
        // Double the selection on both active axes, anchoring the opposite edge.
        let delta = CGSize(width: left ? -1220 : 1220, height: top ? -500 : 500)
        let enlarged = snapshot.resized(byWorldDelta: delta, edge: edge)!
        let af = enlarged[a.id]!
        let bf = enlarged[b.id]!
        expect(close(af.width, (left || right) ? 960 : 480), "\(edge) scales active width")
        expect(close(bf.height, (top || bottom) ? 880 : 440), "\(edge) scales active height")
        expect(close(af.x, left ? -1520 : -300), "\(edge) preserves opposite horizontal anchor")
        expect(close(af.y, top ? -300 : 200), "\(edge) preserves opposite vertical anchor")
        expect(close(bf.x - af.x, (left || right) ? 1160 : 580), "\(edge) scales member spacing")
        // Crossing the opposite edge clamps both members to 50%, never flips.
        let shrink = snapshot.resized(byWorldDelta: CGSize(width: left ? 10000 : -10000, height: top ? 10000 : -10000), edge: edge)!
        expect(close(shrink[a.id]!.width, (left || right) ? 240 : 480), "\(edge) clamps common minimum width")
        expect(close(shrink[b.id]!.height, (top || bottom) ? 220 : 440), "\(edge) clamps common minimum height")
        expect(snapshot.resized(byWorldDelta: .zero, edge: edge)![a.id] == a.frame, "\(edge) returns exactly to baseline without drift")
    }
    // The member nearest its minimum limits every member, independently per axis.
    let tight = tile(.managedAgent, TileFrame(x: 1000, y: -700, width: 400, height: 300))
    let mixed = TileSelectionGeometry.Snapshot(tiles: [a, tight])!
    let shrunk = mixed.resized(byWorldDelta: CGSize(width: -100000, height: -100000), edge: .bottomRight)!
    expect(close(shrunk[a.id]!.width, 384) && close(shrunk[a.id]!.height, 256), "largest member minimum ratio limits whole group")
    expect(close(shrunk[tight.id]!.width, 320) && close(shrunk[tight.id]!.height, 240), "limiting member reaches its own kind minimum")
    expect(TileSelectionGeometry.Snapshot(tiles: []) == nil, "empty selection rejected")
    expect(TileSelectionGeometry.Snapshot(tiles: [a, a]) == nil, "duplicate identity rejected")
    var invalid = a
    invalid.frame.x = .nan
    expect(TileSelectionGeometry.Snapshot(tiles: [invalid]) == nil, "nonfinite baseline rejected")
    invalid.frame = TileFrame(x: 0, y: 0, width: 0, height: 10)
    expect(TileSelectionGeometry.Snapshot(tiles: [invalid]) == nil, "zero extent rejected")
    expect(snapshot.translated(byWorldDelta: CGSize(width: CGFloat.infinity, height: 0)) == nil, "nonfinite translation rejected")
    expect(snapshot.resized(byWorldDelta: CGSize(width: 0, height: CGFloat.nan), edge: .bottom) == nil, "nonfinite resize rejected")
    let far = tile(.note, TileFrame(x: Double.greatestFiniteMagnitude * 0.75, y: 0, width: 480, height: 320))
    // Union subtraction must retain positive representable extents as well.
    expect(TileSelectionGeometry.Snapshot(tiles: [far]) == nil, "unrepresentable union extent rejected")
    print("TileSelectionGeometryChecks passed (8 handles, world union, rigid translation, affine spacing, minima, baseline reuse, invalid inputs)")
}

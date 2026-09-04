import Foundation
import ContinuumRevivedCore

func runLayoutPressureChecks() {
    let zoneId = UUID()
    let ids = (0..<4).map { _ in UUID() }
    let zone = ZonePlacement(zoneId: zoneId, projectId: nil,
        origin: ZonePoint(x: 100, y: 100), size: ZoneSize(width: 520, height: 300),
        color: "teal", collapsed: false, hydrationPolicy: .automatic)
    let tiles = [
        CanvasAutoLayoutEngine.LayoutTile(id: ids[0], frame: TileFrame(x: 116, y: 148, width: 100, height: 100), zoneId: zoneId),
        .init(id: ids[1], frame: TileFrame(x: 232, y: 148, width: 140, height: 100), zoneId: zoneId),
        .init(id: ids[2], frame: TileFrame(x: 388, y: 148, width: 200, height: 100), zoneId: zoneId),
        .init(id: ids[3], frame: TileFrame(x: 800, y: 148, width: 100, height: 100), zoneId: nil)
    ]
    let scene = CanvasAutoLayoutEngine.Scene(tiles: tiles, zones: [zone])
    func solve(_ scene: CanvasAutoLayoutEngine.Scene, _ mutation: CanvasAutoLayoutEngine.Mutation) -> CanvasLayoutTransaction {
        CanvasAutoLayoutEngine.solve(scene: scene, mutation: mutation, gap: 16, zonePadding: 16, headerHeight: 32)
    }
    var grown = tiles[0].frame
    grown.width += 160
    let result = solve(scene, .tile(id: ids[0], frame: grown))
    expect(result.tileFrames[ids[1]]?.x == 392, "resize pressure pushes first neighbor by expansion")
    expect(result.tileFrames[ids[2]]?.x == 548, "resize pressure propagates through unequal tiles")
    expect(result.tileFrames[ids[1]]?.width == 140 && result.tileFrames[ids[2]]?.width == 200, "resize preserves neighbor sizes")
    expect(result.tileFrames[ids[3]] == nil, "resize leaves outside tile unchanged")
    expect(result.zonePlacements[zoneId]?.size.width == 664, "resize grows zone around pushed chain")
    let reverse = solve(scene, .tile(id: ids[0], frame: tiles[0].frame))
    expect(reverse.tileFrames.isEmpty && reverse.zonePlacements.isEmpty, "reverse resize returns to gesture baseline")
    // Rotate/reflect the same row to cover pressure from each edge.
    for horizontal in [true, false] {
        for sign in [-1.0, 1.0] {
            var rotated = scene
            for i in rotated.tiles.indices {
                var f = rotated.tiles[i].frame
                if sign < 0 { f.x = 1000 - f.x - f.width }
                if !horizontal { f = TileFrame(x: f.y, y: f.x, width: f.height, height: f.width) }
                rotated.tiles[i].frame = f
            }
            var requested = rotated.tiles[0].frame
            if horizontal { requested.width += 80; if sign < 0 { requested.x -= 80 } }
            else { requested.height += 80; if sign < 0 { requested.y -= 80 } }
            let pushed = solve(rotated, .tile(id: ids[0], frame: requested))
            for i in 1...2 {
                let before = rotated.tiles[i].frame
                let after = pushed.tileFrames[ids[i]] ?? before
                expect(after.width == before.width && after.height == before.height, "all-edge pressure preserves sizes")
                expect(horizontal ? after.x == before.x + sign * 80 && after.y == before.y : after.y == before.y + sign * 80 && after.x == before.x, "all-edge pressure follows dragged edge")
            }
        }
    }
    var sparse = scene
    sparse.globalEnabled = false
    sparse.zones[0].autoLayoutMode = .disabled
    sparse.tiles[1].frame.x += 100
    sparse.tiles[2].frame.x += 200
    let tidy = solve(sparse, .tidy(zoneId: zoneId))
    expect(tidy.tileFrames[ids[1]]?.x == 232 && tidy.tileFrames[ids[2]]?.x == 388, "explicit tidy closes gaps with auto layout disabled")
    expect(tidy.zonePlacements[zoneId]?.size == ZoneSize(width: 504, height: 164), "tidy fits zone to compacted members")
    var compacted = sparse
    for i in compacted.tiles.indices { compacted.tiles[i].frame = tidy.tileFrames[compacted.tiles[i].id] ?? compacted.tiles[i].frame }
    compacted.zones[0] = tidy.zonePlacements[zoneId] ?? zone
    let again = solve(compacted, .tidy(zoneId: zoneId))
    expect(again.tileFrames.isEmpty && again.zonePlacements.isEmpty, "tidy is idempotent")
    expect(compacted.zones[0].autoLayoutMode == .disabled, "explicit tidy preserves disabled mode")
    // A connected U has a genuine empty cavity. Tidy closes excess vertical
    // space while preserving left/right and above/below relations.
    var cavity = scene
    cavity.tiles = [
        .init(id: ids[0], frame: TileFrame(x: 116, y: 148, width: 300, height: 100), zoneId: zoneId),
        .init(id: ids[1], frame: TileFrame(x: 116, y: 400, width: 100, height: 100), zoneId: zoneId),
        .init(id: ids[2], frame: TileFrame(x: 432, y: 148, width: 100, height: 352), zoneId: zoneId)
    ]
    let cavityResult = solve(cavity, .tidy(zoneId: zoneId))
    expect(cavityResult.tileFrames[ids[1]]?.y == 264, "tidy closes a hole in a connected arrangement")
    for i in cavity.tiles.indices { cavity.tiles[i].frame = cavityResult.tileFrames[cavity.tiles[i].id] ?? cavity.tiles[i].frame }
    cavity.zones[0] = cavityResult.zonePlacements[zoneId] ?? zone
    expect(solve(cavity, .tidy(zoneId: zoneId)).tileFrames.isEmpty, "connected compaction is stable")
    var irregular = scene
    let irregularFrames: [[Double]] = [[629,496,150,158],[360,232,160,113],[984,154,74,61],[413,3,164,160],[994,665,87,110],[551,182,98,118],[183,837,141,71],[214,293,129,185]]
    irregular.tiles = irregularFrames.enumerated().map { index, f in
        .init(id: UUID(uuidString: String(format: "07110000-0000-4000-8000-%012d", index))!,
              frame: TileFrame(x: f[0], y: f[1], width: f[2], height: f[3]), zoneId: zoneId)
    }
    let irregularTidy = solve(irregular, .tidy(zoneId: zoneId))
    for i in irregular.tiles.indices { irregular.tiles[i].frame = irregularTidy.tileFrames[irregular.tiles[i].id] ?? irregular.tiles[i].frame }
    irregular.zones[0] = irregularTidy.zonePlacements[zoneId] ?? zone
    let irregularAgain = solve(irregular, .tidy(zoneId: zoneId))
    expect(irregularAgain.tileFrames.isEmpty && irregularAgain.zonePlacements.isEmpty, "irregular tidy reaches its fixed point on the first click")
    let single = solve(.init(tiles: [tiles[0]], zones: [zone]), .tidy(zoneId: zoneId))
    expect(single.tileFrames.isEmpty && single.zonePlacements[zoneId]?.size == ZoneSize(width: 132, height: 164), "one tile fits its zone")
    expect(solve(.init(tiles: [], zones: [zone]), .tidy(zoneId: zoneId)) == CanvasLayoutTransaction(), "empty tidy does nothing")
    // Each corner sends independent pressure into horizontal and vertical lanes.
    for left in [false, true] {
        for top in [false, true] {
            var corner = scene
            corner.tiles = [
                .init(id: ids[0], frame: TileFrame(x: 300, y: 300, width: 100, height: 100), zoneId: zoneId),
                .init(id: ids[1], frame: TileFrame(x: left ? 184 : 416, y: 300, width: 100, height: 100), zoneId: zoneId),
                .init(id: ids[2], frame: TileFrame(x: 300, y: top ? 184 : 416, width: 100, height: 100), zoneId: zoneId)
            ]
            let requested = TileFrame(x: left ? 260 : 300, y: top ? 250 : 300, width: 140, height: 150)
            let pushed = solve(corner, .tile(id: ids[0], frame: requested))
            expect(pushed.tileFrames[ids[1]]?.x == (left ? 144 : 456), "corner pushes horizontal lane")
            expect(pushed.tileFrames[ids[2]]?.y == (top ? 134 : 466), "corner pushes vertical lane")
        }
    }
    let contactStart = TileFrame(x: 0, y: 0, width: 300, height: 300)
    var previousWidth = contactStart.width
    for delta in 1...60 {
        var free = contactStart
        free.width += Double(delta)
        let resisted = MagneticPlacement.resizeContact(free: free, snapped: contactStart, initial: contactStart, edge: .right, zoom: 1)
        expect(resisted.width > previousWidth && resisted.width <= free.width, "resize contact advances smoothly on every input")
        expect(resisted.width >= contactStart.width + Double(delta) * 0.65, "resize resistance never consumes more than 35 percent of motion")
        previousWidth = resisted.width
    }
    let neighbor = MagneticPlacement.Neighbor(id: ids[1], frame: TileFrame(x: 500, y: 200, width: 200, height: 200))
    for zoom in [0.25, 0.5, 1, 2] {
        let exact = 500.0 - 16 - 100
        var free = TileFrame(x: exact - 20 / zoom, y: 200, width: 100, height: 100)
        let first = MagneticPlacement.resolve(free: free, neighbors: [neighbor], previous: nil, gap: 16, zoom: zoom)
        expect(first.target?.frame.x == exact && first.frame.x > free.x && first.frame.x < exact, "magnet acquires and smoothly attracts at every zoom")
        var farDown = free
        farDown.y += 1000 / zoom
        expect(MagneticPlacement.resolve(free: farDown, neighbors: [neighbor], previous: first.target, gap: 16, zoom: zoom).target == nil,
               "sliding beyond a neighbor releases its edge instead of extending it infinitely")
        free.x = exact - 54 / zoom
        let held = MagneticPlacement.resolve(free: free, neighbors: [neighbor], previous: first.target, gap: 16, zoom: zoom)
        expect(held.target?.neighborId == neighbor.id, "magnet retains target beyond acquisition radius")
        free.x = exact - 65 / zoom
        let released = MagneticPlacement.resolve(free: free, neighbors: [neighbor], previous: held.target, gap: 16, zoom: zoom)
        expect(released.target == nil && released.frame == free, "magnet breaks away without changing raw pointer")
    }
    print("layout pressure checks passed")
}

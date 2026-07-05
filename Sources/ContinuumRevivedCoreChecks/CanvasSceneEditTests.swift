import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/61b-canvas-editor.md
// Table-driven checks for CanvasSceneProjection (z-order, membership, tint/glyph
// tokens) and CanvasEditIntent (gesture-end→Op helpers). Executable checks
// (*Checks convention) — no XCTest.

private func canvasFrame(_ x: Double, _ y: Double, _ w: Double = 100, _ h: Double = 80) -> TileFrame {
    TileFrame(x: x, y: y, width: w, height: h)
}

private func canvasTile(id: UUID, kind: TileKind = .terminal, z: FracIndex, zoneId: UUID? = nil) -> Tile {
    Tile(id: id, kind: kind, title: "tile-\(id.uuidString.prefix(4))", frame: canvasFrame(0, 0), zPosition: z, zoneId: zoneId, runtimeRef: nil, metadata: TileMetadata())
}

private func canvasZone(id: UUID, name: String, origin: ZonePoint, size: ZoneSize, color: String, z: FracIndex) -> ZonePlacement {
    ZonePlacement(zoneId: id, projectId: nil, origin: origin, size: size, color: color, collapsed: false, hydrationPolicy: .automatic, name: name, navKey: nil, zPosition: z)
}

func runCanvasSceneProjectionChecks() {
    let tileLow = UUID(uuidString: "61B00000-0000-4000-8000-00000000000A")!
    let tileMid = UUID(uuidString: "61B00000-0000-4000-8000-00000000000B")!
    // Tied zPosition with tileMid — id tie-break decides render order.
    let tileTieLo = UUID(uuidString: "61B00000-0000-4000-8000-00000000000C")!
    let tileTieHi = UUID(uuidString: "61B00000-0000-4000-8000-00000000000D")!
    let zoneAlpha = UUID(uuidString: "61B00000-0000-4000-8000-0000000000A1")!
    let zoneBeta = UUID(uuidString: "61B00000-0000-4000-8000-0000000000B2")!

    let tieZ = FracIndex(value: 0.5)
    let canvasState = CanvasState(
        viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
        tiles: [
            // Deliberately out of z/id order in the source array — the
            // projection must re-sort, never trust array order.
            canvasTile(id: tileMid, kind: .browser, z: FracIndex(value: 0.4), zoneId: zoneAlpha),
            canvasTile(id: tileLow, kind: .terminal, z: FracIndex(value: 0.2)),
            canvasTile(id: tileTieHi, kind: .note, z: tieZ, zoneId: zoneBeta),
            canvasTile(id: tileTieLo, kind: .fileTree, z: tieZ),
        ],
        groups: [],
        lastActiveTileId: nil
    )
    let workspaceDocument = WorkspaceDocument(
        viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
        zones: [
            canvasZone(id: zoneBeta, name: "Beta", origin: ZonePoint(x: 500, y: 0), size: ZoneSize(width: 400, height: 300), color: "amber", z: FracIndex(value: 0.6)),
            canvasZone(id: zoneAlpha, name: "Alpha", origin: ZonePoint(x: 0, y: 0), size: ZoneSize(width: 400, height: 300), color: "mint", z: FracIndex(value: 0.3)),
        ],
        lastActiveZoneId: nil
    )

    let scene = CanvasSceneProjection.scene(canvasState: canvasState, workspaceDocument: workspaceDocument)

    // Zones: zPosition ascending (back to front) — Alpha (0.3) before Beta (0.6).
    expect(scene.zones.map(\.zoneId) == [zoneAlpha, zoneBeta], "CanvasSceneProjection: zones in zPosition order")
    expect(scene.zones.map(\.tintToken) == ["mint", "amber"], "CanvasSceneProjection: zone tint tokens pass through ZonePlacement.color verbatim")

    // Tiles: (zPosition, id) ascending. tileTieLo/tileTieHi share zPosition —
    // id string comparison must decide their relative order.
    let expectedTileOrder = [tileLow, tileMid, tileTieLo, tileTieHi].sorted { $0.uuidString < $1.uuidString }
    // tileLow (0.2) and tileMid (0.4) are NOT tied, so only the tie pair's
    // relative order is decided by id; assert the full expected sequence
    // directly instead of re-deriving it from a sort the test itself trusts.
    let tieOrderIsAscending = tileTieLo.uuidString < tileTieHi.uuidString
    let expectedOrder = tieOrderIsAscending ? [tileLow, tileMid, tileTieLo, tileTieHi] : [tileLow, tileMid, tileTieHi, tileTieLo]
    expect(scene.tiles.map(\.tileId) == expectedOrder, "CanvasSceneProjection: tiles in (zPosition, id) render order, got \(scene.tiles.map(\.tileId))")
    _ = expectedTileOrder

    // Membership resolved from tile.zoneId, world frame passed through.
    expect(scene.tiles.first { $0.tileId == tileMid }?.zoneId == zoneAlpha, "CanvasSceneProjection: membership resolved from tile.zoneId")
    expect(scene.tiles.first { $0.tileId == tileLow }?.zoneId == nil, "CanvasSceneProjection: ambient tile has nil zoneId")
    expect(scene.tiles.first { $0.tileId == tileLow }?.frame == canvasFrame(0, 0), "CanvasSceneProjection: world frame passed through unchanged")

    // Kind glyph tokens.
    expect(scene.tiles.first { $0.tileId == tileMid }?.kindGlyphToken == "globe", "CanvasSceneProjection: browser kind glyph token")
    expect(scene.tiles.first { $0.tileId == tileLow }?.kindGlyphToken == "terminal", "CanvasSceneProjection: terminal kind glyph token")
    for kind in TileKind.allCases {
        expect(!CanvasSceneGlyph.token(for: kind).isEmpty, "CanvasSceneGlyph: every TileKind has a non-empty token (\(kind.rawValue))")
    }

    print("CanvasSceneProjection checks: zones=\(scene.zones.map(\.zoneId.uuidString)) tiles=\(scene.tiles.map(\.tileId.uuidString)) glyphs=\(scene.tiles.map(\.kindGlyphToken))")
}

func runCanvasEditIntentChecks() {
    // moveEnded / resizeEnded: exact frame on drop.
    let tileId = UUID()
    let newFrame = canvasFrame(120, 340, 200, 150)
    expect(CanvasEditIntent.moveEnded(tile: tileId, to: newFrame) == .setTileFrame(id: tileId, frame: newFrame), "CanvasEditIntent.moveEnded: exact setTileFrame op")
    expect(CanvasEditIntent.resizeEnded(tile: tileId, to: newFrame) == .setTileFrame(id: tileId, frame: newFrame), "CanvasEditIntent.resizeEnded: exact setTileFrame op")

    // Zone hit-test: in / out / overlapping-zones-topmost.
    let zoneBack = UUID(uuidString: "61B00000-0000-4000-8000-0000000000C1")!
    let zoneFront = UUID(uuidString: "61B00000-0000-4000-8000-0000000000C2")!
    let overlapping = [
        CanvasSceneZone(zoneId: zoneBack, name: "Back", origin: ZonePoint(x: 0, y: 0), size: ZoneSize(width: 300, height: 300), tintToken: "mint", zPosition: FracIndex(value: 0.3)),
        CanvasSceneZone(zoneId: zoneFront, name: "Front", origin: ZonePoint(x: 100, y: 100), size: ZoneSize(width: 300, height: 300), tintToken: "amber", zPosition: FracIndex(value: 0.7)),
    ]
    expect(CanvasEditIntent.dropTarget(point: ZonePoint(x: 150, y: 150), zones: overlapping) == zoneFront, "CanvasEditIntent.dropTarget: overlapping zones pick the topmost (higher zPosition)")
    expect(CanvasEditIntent.dropTarget(point: ZonePoint(x: 50, y: 50), zones: overlapping) == zoneBack, "CanvasEditIntent.dropTarget: point only inside the back zone")
    expect(CanvasEditIntent.dropTarget(point: ZonePoint(x: 5000, y: 5000), zones: overlapping) == nil, "CanvasEditIntent.dropTarget: point outside every zone is ambient (nil)")
    expect(CanvasEditIntent.setZone(tile: tileId, zoneId: zoneFront) == .setTileZone(tileId: tileId, zoneId: zoneFront), "CanvasEditIntent.setZone: exact setTileZone op")
    expect(CanvasEditIntent.setZone(tile: tileId, zoneId: nil) == .setTileZone(tileId: tileId, zoneId: nil), "CanvasEditIntent.setZone: dropping to ambient clears zoneId")

    // Bring-to-front: FracIndex sorts after prior frontmost; never lowers an
    // already-frontmost tile.
    let tileBack = UUID(uuidString: "61B00000-0000-4000-8000-0000000000D1")!
    let tileFront = UUID(uuidString: "61B00000-0000-4000-8000-0000000000D2")!
    let frontmostZ = FracIndex(value: 0.6)
    let scene = CanvasScene(
        zones: [],
        tiles: [
            CanvasSceneTile(tileId: tileBack, title: "back", frame: canvasFrame(0, 0), zPosition: FracIndex(value: 0.2), zoneId: nil, kindGlyphToken: "terminal"),
            CanvasSceneTile(tileId: tileFront, title: "front", frame: canvasFrame(0, 0), zPosition: frontmostZ, zoneId: nil, kindGlyphToken: "terminal"),
        ]
    )
    guard case let .setTileZIndex(id, z)? = CanvasEditIntent.bringToFront(tile: tileBack, scene: scene) else {
        expect(false, "CanvasEditIntent.bringToFront: expected a setTileZIndex op for the back tile")
        return
    }
    expect(id == tileBack, "CanvasEditIntent.bringToFront: op targets the requested tile")
    expect(z > frontmostZ, "CanvasEditIntent.bringToFront: new z (\(z.value)) sorts strictly after the prior frontmost (\(frontmostZ.value))")
    expect(CanvasEditIntent.bringToFront(tile: tileFront, scene: scene) == nil, "CanvasEditIntent.bringToFront: already-frontmost tile is a no-op (never lowers it)")
    expect(CanvasEditIntent.bringToFront(tile: UUID(), scene: scene) == nil, "CanvasEditIntent.bringToFront: unknown tile is a no-op")

    // Scope predicate, both ways.
    expect(CanvasEditIntent.isEditingPermitted(scope: .operator), "CanvasEditIntent.isEditingPermitted: operator scope may edit")
    expect(CanvasEditIntent.isEditingPermitted(scope: .admin), "CanvasEditIntent.isEditingPermitted: admin scope (superset) may edit")
    expect(!CanvasEditIntent.isEditingPermitted(scope: .observer), "CanvasEditIntent.isEditingPermitted: observer scope may not edit")
    expect(!CanvasEditIntent.isEditingPermitted(scope: []), "CanvasEditIntent.isEditingPermitted: empty scope may not edit")

    print("CanvasEditIntent checks: moveEnded/resizeEnded frame-exact, dropTarget in/out/topmost, bringToFront z=\(z.value) > frontmost=\(frontmostZ.value), scope predicate both ways")
}

// Ticket: docs/38-tickets/61b-canvas-editor.md — REV.2 §1 continuation fix.
// Table checks for `moveDropOps`, the pure ordered op list for a drag-drop
// gesture end: no-membership-change → exactly 1 op; change → 2 ops in order
// [setTileFrame, setTileZone(target)]; drop out of a zone to ambient → 2 ops
// with zoneId nil.
func runCanvasEditIntentMoveDropOpsChecks() {
    let tileId = UUID()
    let zoneId = UUID(uuidString: "61B00000-0000-4000-8000-0000000000E1")!
    let otherZoneId = UUID(uuidString: "61B00000-0000-4000-8000-0000000000E2")!
    let zones = [
        CanvasSceneZone(zoneId: zoneId, name: "Zone", origin: ZonePoint(x: 0, y: 0), size: ZoneSize(width: 300, height: 300), tintToken: "mint", zPosition: FracIndex(value: 0.3)),
    ]

    // No membership change: drop stays inside the tile's current zone —
    // exactly 1 op, the setTileFrame with the exact frame.
    let frameInsideZone = canvasFrame(50, 50, 100, 100)
    let noChangeOps = CanvasEditIntent.moveDropOps(tile: tileId, currentZoneId: zoneId, to: frameInsideZone, zones: zones)
    expect(noChangeOps == [.setTileFrame(id: tileId, frame: frameInsideZone)], "moveDropOps: no membership change yields exactly 1 op (the exact-frame setTileFrame), got \(noChangeOps)")

    // Membership change: drop into a different zone — exactly 2 ops in
    // order [setTileFrame, setTileZone(target)].
    let zonesWithBoth = zones + [
        CanvasSceneZone(zoneId: otherZoneId, name: "Other", origin: ZonePoint(x: 1000, y: 1000), size: ZoneSize(width: 300, height: 300), tintToken: "amber", zPosition: FracIndex(value: 0.4)),
    ]
    let frameInsideOtherZone = canvasFrame(1050, 1050, 100, 100)
    let changeOps = CanvasEditIntent.moveDropOps(tile: tileId, currentZoneId: zoneId, to: frameInsideOtherZone, zones: zonesWithBoth)
    expect(changeOps == [.setTileFrame(id: tileId, frame: frameInsideOtherZone), .setTileZone(tileId: tileId, zoneId: otherZoneId)], "moveDropOps: membership change yields 2 ops in order [setTileFrame, setTileZone(target)], got \(changeOps)")

    // Drop out of a zone to ambient: 2 ops with zoneId nil.
    let frameOutsideEveryZone = canvasFrame(9000, 9000, 100, 100)
    let ambientOps = CanvasEditIntent.moveDropOps(tile: tileId, currentZoneId: zoneId, to: frameOutsideEveryZone, zones: zonesWithBoth)
    expect(ambientOps == [.setTileFrame(id: tileId, frame: frameOutsideEveryZone), .setTileZone(tileId: tileId, zoneId: nil)], "moveDropOps: drop to ambient yields 2 ops with zoneId nil, got \(ambientOps)")

    // No prior zone, drop stays ambient: exactly 1 op.
    let ambientToAmbientOps = CanvasEditIntent.moveDropOps(tile: tileId, currentZoneId: nil, to: frameOutsideEveryZone, zones: zonesWithBoth)
    expect(ambientToAmbientOps == [.setTileFrame(id: tileId, frame: frameOutsideEveryZone)], "moveDropOps: ambient-to-ambient yields exactly 1 op, got \(ambientToAmbientOps)")

    print("CanvasEditIntent.moveDropOps checks: no-change=1op, zone-change=2ops-in-order, to-ambient=2ops-nil-zone, ambient-to-ambient=1op")
}

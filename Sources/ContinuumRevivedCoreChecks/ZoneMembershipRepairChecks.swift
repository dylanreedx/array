import ContinuumRevivedCore
import Foundation

/// M1.10 (`.plans/46`) — `CanvasEngine.resolveZoneMembership`.
///
/// The rule exists because a tile's persisted `zoneId` can name a zone belonging
/// to another project, which is what ordinary dragging produces, and because the
/// membership filter it replaces rendered such a tile **nowhere**. The two
/// properties that matter most are the ones a careless implementation loses:
/// every tile lands somewhere, and no tile moves.
func runZoneMembershipRepairChecks() {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    let zoneOne = UUID()
    let zoneTwo = UUID()
    let foreignZone = UUID()
    let ambientZone = UUID()

    func zone(_ id: UUID, x: Double, y: Double, w: Double = 400, h: Double = 300) -> ZonePlacement {
        ZonePlacement(
            zoneId: id, projectId: UUID(),
            origin: ZonePoint(x: x, y: y), size: ZoneSize(width: w, height: h),
            color: "blue", collapsed: false, hydrationPolicy: .automatic)
    }
    func tile(_ id: UUID, zone: UUID?, x: Double, y: Double) -> Tile {
        var t = Tile(
            id: id, kind: .note, title: "n",
            frame: TileFrame(x: x, y: y, width: 100, height: 80),
            zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        t.zoneId = zone
        return t
    }

    let zones = [zone(zoneOne, x: 0, y: 0), zone(zoneTwo, x: 1000, y: 0)]
    // Every zone THIS document holds — the project's two, plus a zone owned by
    // another project and an ambient one. A stamp naming something outside this
    // set belongs to another workspace and must be left alone (case 9).
    let documentZones: Set<UUID> = [zoneOne, zoneTwo, foreignZone, ambientZone]

    // 1. A stamp this project owns is authoritative, even when the tile sits
    //    geometrically inside the OTHER zone. Membership is a register, not a
    //    hit-test, and re-deriving it from geometry would silently move tiles
    //    between zones every time someone dragged one across a boundary.
    let deliberate = UUID()
    let r1 = CanvasEngine.resolveZoneMembership(
        tiles: [tile(deliberate, zone: zoneOne, x: 1050, y: 50)],
        projectZones: zones, documentZoneIds: documentZones, homeZoneId: zoneOne)
    expect(r1.byZone[zoneOne]?.count == 1, "an owned stamp must win over geometry")
    expect(r1.restamped.isEmpty, "an owned stamp must not be reported as repaired")

    // 2. The field case: another project's zone id. Rescued by geometry.
    let foreign = UUID()
    let r2 = CanvasEngine.resolveZoneMembership(
        tiles: [tile(foreign, zone: foreignZone, x: 1050, y: 50)],
        projectZones: zones, documentZoneIds: documentZones, homeZoneId: zoneOne)
    expect(r2.byZone[zoneTwo]?.first?.id == foreign,
           "a foreign stamp must be rescued into the zone that contains the tile")
    expect(r2.restamped == [foreign], "the rescue must be reported so the caller can persist it")
    expect(r2.byZone[zoneTwo]?.first?.zoneId == zoneTwo, "the rescued tile must carry its new stamp")

    // 3. Position is preserved exactly. This is the promise that stops the repair
    //    from looking like the tiles jumped: local + origin == world.
    let rescued = r2.byZone[zoneTwo]![0]
    let local = CanvasEngine.worldToZoneLocal(rescued.frame, zoneOrigin: zones[1].origin)
    let backToWorld = CanvasEngine.zoneLocalToWorld(local, zoneOrigin: zones[1].origin)
    expect(abs(backToWorld.x - 1050) < 0.001 && abs(backToWorld.y - 50) < 0.001,
           "a rescued tile must render on the pixel it already occupied; got \(backToWorld)")

    // 4. nil and unknown stamps behave the same as foreign ones.
    let unstamped = UUID()
    let unknown = UUID()
    let r4 = CanvasEngine.resolveZoneMembership(
        tiles: [tile(unstamped, zone: nil, x: 50, y: 50),
                tile(unknown, zone: ambientZone, x: 50, y: 50)],
        projectZones: zones, documentZoneIds: documentZones, homeZoneId: zoneTwo)
    expect(r4.byZone[zoneOne]?.count == 2, "nil and unknown stamps rescue by geometry")
    expect(Set(r4.restamped) == Set([unstamped, unknown]), "both must be reported")

    // 5. A tile no zone contains falls to home rather than vanishing.
    let orphan = UUID()
    let r5 = CanvasEngine.resolveZoneMembership(
        tiles: [tile(orphan, zone: nil, x: 5000, y: 5000)],
        projectZones: zones, documentZoneIds: documentZones, homeZoneId: zoneTwo)
    expect(r5.byZone[zoneTwo]?.first?.id == orphan, "an uncontained tile must land in the home zone")

    // 6. NEVER DROP A TILE. The property the old filter violated.
    var many: [Tile] = []
    for i in 0..<40 {
        let stamp: UUID?
        switch i % 3 {
        case 0: stamp = foreignZone
        case 1: stamp = nil
        default: stamp = zoneOne
        }
        many.append(tile(UUID(), zone: stamp, x: Double(i) * 37.0, y: Double(i) * 11.0))
    }
    let r6 = CanvasEngine.resolveZoneMembership(tiles: many, projectZones: zones, documentZoneIds: documentZones, homeZoneId: zoneOne)
    let emitted = r6.byZone.values.flatMap { $0 }.map(\.id)
    expect(emitted.count == many.count, "every tile must be emitted exactly once; got \(emitted.count) of \(many.count)")
    expect(Set(emitted) == Set(many.map(\.id)), "the emitted set must be the input set")

    // 7. A home id that is not one of the project's zones is not trusted.
    let stray = UUID()
    let r7 = CanvasEngine.resolveZoneMembership(
        tiles: [tile(stray, zone: nil, x: 5000, y: 5000)],
        projectZones: zones, documentZoneIds: documentZones, homeZoneId: foreignZone)
    expect(r7.byZone[zoneOne]?.first?.id == stray,
           "a home id outside the project falls back to its first zone, never to a foreign zone")

    // 8. No zones: refuse rather than invent one. Callers guarantee otherwise.
    let r8 = CanvasEngine.resolveZoneMembership(
        tiles: [tile(UUID(), zone: nil, x: 0, y: 0)], projectZones: [], documentZoneIds: documentZones, homeZoneId: zoneOne)
    expect(r8.byZone.isEmpty && r8.restamped.isEmpty, "no zones means no placement")

    // 9. A stamp naming a zone this document does not contain belongs to ANOTHER
    //    WORKSPACE. Leave it: the project's zones can be spread across workspaces,
    //    and rescuing here would drag the tile out of the one that owns it. Found
    //    by --zone-runtime-duplication-check, whose fixture shares one project
    //    across two workspaces.
    let elsewhere = UUID()
    let otherWorkspaceZone = UUID()
    let r9 = CanvasEngine.resolveZoneMembership(
        tiles: [tile(elsewhere, zone: otherWorkspaceZone, x: 50, y: 50)],
        projectZones: zones, documentZoneIds: documentZones, homeZoneId: zoneOne)
    expect(r9.byZone.isEmpty, "a tile belonging to another workspace's zone must not be placed here")
    expect(r9.restamped.isEmpty, "and must not be reported as repaired")
    expect(r9.deferred == [elsewhere], "it must be reported as deferred; got \(r9.deferred)")

    print("ZoneMembershipRepairChecks passed: owned stamps win, foreign/nil/unknown rescue by "
          + "geometry then home, another workspace's zone is left alone, positions survive the "
          + "round trip, and no tile is ever dropped")
}

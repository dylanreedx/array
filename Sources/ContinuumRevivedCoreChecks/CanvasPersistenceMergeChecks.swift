import ContinuumRevivedCore
import Foundation

// Plan: .plans/46 M1.0 — the pure half of the persistence fix.
//
// `CanvasEngine.mergeProjectTilesForPersistence` decides what a project's
// canvas.json receives. Before it, two callers REPLACED the file: the flush path
// wrote the flat `canvasState` (which after a workspace switch holds the DEPARTED
// project's tiles) and the spawn path wrote `tiles(forProjectId:)` (which reads
// installed layers only, dropping every zone below the live tier).
//
// The rule under test is cover-then-replace: a persisted tile may only vanish when
// its OWN zone is installed and it is nonetheless absent. Anything else is carried
// through, because an un-installed zone is not evidence of a deletion.
//
// The wiring — that production actually calls this — is witnessed separately and
// behaviourally by the app leg `--canvas-persistence-model-check`. This half is
// here because it is pure, exhaustive and fast, and because the app leg can only
// afford a couple of shapes.
func runCanvasPersistenceMergeChecks() {
    let zoneA = UUID(uuidString: "00000000-0000-0000-0000-0000000E0001")!
    let zoneB = UUID(uuidString: "00000000-0000-0000-0000-0000000E0002")!

    func tile(_ suffix: String, zone: UUID?, x: Double = 0) -> Tile {
        var t = Tile(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000F\(suffix)")!,
            kind: .note,
            title: "note-\(suffix)",
            frame: TileFrame(x: x, y: 0, width: 100, height: 80),
            zPosition: .fromLegacyRank(1),
            runtimeRef: nil,
            metadata: TileMetadata()
        )
        t.zoneId = zone
        return t
    }

    let a1 = tile("0001", zone: zoneA)
    let a2 = tile("0002", zone: zoneA)
    let b1 = tile("0003", zone: zoneB)
    let b2 = tile("0004", zone: zoneB)

    // 1. An un-installed zone's tiles survive. This is the merged M1.5: zone B is
    //    not covered, so its tiles are carried through untouched even though the
    //    installed set knows nothing about them.
    let survived = CanvasEngine.mergeProjectTilesForPersistence(
        persisted: [a1, a2, b1, b2], installed: [a1, a2], coveredZoneIds: [zoneA])
    expect(survived.map(\.id) == [a1.id, a2.id, b1.id, b2.id],
           "an un-installed zone's tiles must survive a persist, got \(survived.map(\.title))")

    // 2. A deletion inside a COVERED zone is honoured. Without this the merge would
    //    be write-only and closing a tile would never stick.
    let deleted = CanvasEngine.mergeProjectTilesForPersistence(
        persisted: [a1, a2, b1], installed: [a1], coveredZoneIds: [zoneA])
    expect(deleted.map(\.id) == [a1.id, b1.id],
           "a tile removed from an INSTALLED zone must be dropped, got \(deleted.map(\.title))")

    // 3. The installed copy wins for a tile in both — this is how a move persists.
    var movedA1 = a1
    movedA1.frame = TileFrame(x: 999, y: 0, width: 100, height: 80)
    let moved = CanvasEngine.mergeProjectTilesForPersistence(
        persisted: [a1, b1], installed: [movedA1], coveredZoneIds: [zoneA])
    expect(moved.first(where: { $0.id == a1.id })?.frame.x == 999,
           "the installed copy must win for a tile present in both, got \(String(describing: moved.first?.frame.x))")

    // 4. Persisted order is preserved and new tiles append, so a save is a minimal
    //    diff rather than a reshuffle.
    let appended = CanvasEngine.mergeProjectTilesForPersistence(
        persisted: [b1, a1], installed: [a1, a2], coveredZoneIds: [zoneA])
    expect(appended.map(\.id) == [b1.id, a1.id, a2.id],
           "persisted order must be preserved with new tiles appended, got \(appended.map(\.title))")

    // 5. NOTHING covered means purely additive. This is the guard that matters most:
    //    it is the state a controller is in when its project is off screen, and a
    //    subtractive answer here is precisely how a canvas went from nine tiles to
    //    one.
    let nothingInstalled = CanvasEngine.mergeProjectTilesForPersistence(
        persisted: [a1, a2, b1], installed: [], coveredZoneIds: [])
    expect(nothingInstalled.map(\.id) == [a1.id, a2.id, b1.id],
           "with no zone installed the merge must be purely additive, got \(nothingInstalled.count) tiles")

    // 6. A nil-zoneId tile is never dropped. WorkspaceRuntime now stamps adoption at
    //    layer-build time, so a surviving nil means "no zone has ever claimed this"
    //    — undecidable, and the safe answer to an undecidable delete is to keep it.
    let unzoned = tile("0005", zone: nil)
    let keptUnzoned = CanvasEngine.mergeProjectTilesForPersistence(
        persisted: [a1, unzoned], installed: [a1], coveredZoneIds: [zoneA])
    expect(keptUnzoned.map(\.id) == [a1.id, unzoned.id],
           "an unzoned tile must never be dropped, got \(keptUnzoned.map(\.title))")

    // 7. Empty persisted (first ever save) takes the installed set whole.
    let firstSave = CanvasEngine.mergeProjectTilesForPersistence(
        persisted: [], installed: [a1, a2], coveredZoneIds: [zoneA])
    expect(firstSave.map(\.id) == [a1.id, a2.id],
           "a first save must persist the installed set, got \(firstSave.count) tiles")

    print("CanvasPersistenceMergeChecks passed: un-installed zones survive, covered deletions stick")
}

import ContinuumRevivedCore
import ContinuumRevivedSync
import Foundation

// Ticket: docs/38-tickets/05-delete-tombstone.md
// Executable checks for the tombstone vocabulary + delete-wins policy.
// All in-process: no daemon, no network, no wall clock. Prints measured
// values; exits non-zero on the first failure (run-matrix.sh gates on it).

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

// Ticket: docs/38-tickets/55-synctransport-seam.md — I5 structural trap test.
// Must run FIRST, before any other check does real work, so the subprocess
// this spawns re-executes a clean, minimal path (see SyncTransportTests.swift).
await runSyncTransportTrapTestIfRequested()

let replicaA = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
let replicaB = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
let tileT = UUID(uuidString: "0000D001-0000-4000-8000-000000000001")!
let tileA = UUID(uuidString: "0000D0A0-0000-4000-8000-00000000000A")!
let tileB = UUID(uuidString: "0000D0B0-0000-4000-8000-00000000000B")!
let tileC = UUID(uuidString: "0000D0C0-0000-4000-8000-00000000000C")!
let zoneZ = UUID(uuidString: "0000E0A0-0000-4000-8000-00000000000E")!

func logged(_ lamport: UInt64, _ replica: UUID, _ op: Op) -> LoggedOp {
    LoggedOp(opId: OpId(lamport: lamport, replica: replica), op: op)
}

/// The LOCAL TEST-ONLY fold (ticket 05): a dozen lines that pin the
/// delete-wins policy without the production `materialize` (ticket 06).
/// It deliberately UPSERTS on field-set ops — if a field-set for an unknown
/// id could not (re)create an entry, the tombstone guard would be untestable
/// dead weight; here the `isTombstoned` check is the ONLY thing standing
/// between a late field-set and resurrection.
struct FoldedState: Equatable {
    var tileFrames: [UUID: TileFrame] = [:]
    var zoneOrigins: [UUID: ZonePoint] = [:]
}

func localTestFold(_ log: [LoggedOp]) -> FoldedState {
    // Delete-wins: collect ALL tombstones in a pre-pass over the sorted log,
    // then guard every builder mutation — Lamport order of the delete relative
    // to a concurrent field-set is irrelevant by construction.
    let sorted = log.sorted { $0.opId < $1.opId }
    var tombstones = TombstoneSet()
    for op in sorted { tombstones.absorb(op) }

    var state = FoldedState()
    for loggedOp in sorted {
        switch loggedOp.op {
        case .createTile(let id, _, _, let frame, _):
            guard !tombstones.isTombstoned(tileId: id) else { continue }
            state.tileFrames[id] = frame
        case .setTileFrame(let id, let frame):
            guard !tombstones.isTombstoned(tileId: id) else { continue }
            state.tileFrames[id] = frame   // deliberate upsert — see doc above
        case .createZone(let id, _, let origin, _, _, _):
            guard !tombstones.isTombstoned(zoneId: id) else { continue }
            state.zoneOrigins[id] = origin
        case .setZoneOrigin(let id, let origin):
            guard !tombstones.isTombstoned(zoneId: id) else { continue }
            state.zoneOrigins[id] = origin  // deliberate upsert
        default:
            break
        }
    }
    return state
}

let frame1 = TileFrame(x: 0, y: 0, width: 300, height: 200)
let bigFrame = TileFrame(x: 10, y: 10, width: 3000, height: 2000)

// ── Move-vs-delete: a field-set at Lamport 100 cannot resurrect a tile
// deleted at Lamport 5 (the hardest delete-row case in SYNC-MODEL). ──
do {
    let logA = [
        logged(1, replicaA, .createTile(id: tileT, kind: .terminal, title: "t", frame: frame1, zPosition: FracIndex(value: 0.5))),
        logged(5, replicaA, .deleteTile(id: tileT)),
    ]
    let logB = [
        logged(1, replicaA, .createTile(id: tileT, kind: .terminal, title: "t", frame: frame1, zPosition: FracIndex(value: 0.5))),
        logged(100, replicaB, .setTileFrame(id: tileT, frame: bigFrame)),
    ]
    let merged = logA + logB.filter { !logA.contains($0) }
    let folded = localTestFold(merged)
    expect(folded.tileFrames[tileT] == nil, "move-vs-delete: tile T must be absent after the fold (delete at Lamport 5 beats field-set at Lamport 100)")
    // Order-invariance discriminator: reversed arrival, same absence.
    let foldedReversed = localTestFold(merged.reversed())
    expect(foldedReversed == folded, "move-vs-delete: fold is arrival-order invariant")
    // Non-vacuous: WITHOUT the delete, the same field-set DOES apply.
    let noDelete = merged.filter { $0.op != .deleteTile(id: tileT) }
    expect(localTestFold(noDelete).tileFrames[tileT] == bigFrame, "move-vs-delete sanity: without the tombstone the Lamport-100 field-set lands (guard is load-bearing)")
}

// ── Zone variant: deleteZone vs concurrent setZoneOrigin. ──
do {
    let log = [
        logged(1, replicaA, .createZone(id: zoneZ, projectId: nil, origin: ZonePoint(x: 0, y: 0), size: ZoneSize(width: 800, height: 600), name: "Z", color: "mint")),
        logged(4, replicaA, .deleteZone(id: zoneZ)),
        logged(90, replicaB, .setZoneOrigin(id: zoneZ, origin: ZonePoint(x: 500, y: 500))),
    ]
    let folded = localTestFold(log)
    expect(folded.zoneOrigins[zoneZ] == nil, "zone delete-wins: zone Z absent despite the higher-Lamport setZoneOrigin")
}

// ── Live siblings survive beside tombstoned entities (assert by ID). ──
do {
    let log = [
        logged(1, replicaA, .createTile(id: tileA, kind: .terminal, title: "a", frame: frame1, zPosition: FracIndex(value: 0.3))),
        logged(2, replicaA, .createTile(id: tileB, kind: .note, title: "b", frame: frame1, zPosition: FracIndex(value: 0.4))),
        logged(3, replicaA, .createTile(id: tileC, kind: .browser, title: "c", frame: frame1, zPosition: FracIndex(value: 0.5))),
        logged(4, replicaB, .deleteTile(id: tileB)),
    ]
    let folded = localTestFold(log)
    expect(folded.tileFrames[tileA] != nil, "siblings: tile A present")
    expect(folded.tileFrames[tileC] != nil, "siblings: tile C present")
    expect(folded.tileFrames[tileB] == nil, "siblings: tombstoned tile B absent")
    expect(folded.tileFrames.count == 2, "siblings: exactly {A, C} survive")
}

// ── Duplicate delivery of the same delete op is idempotent. ──
do {
    let deleteOp = logged(5, replicaA, .deleteTile(id: tileT))
    var once = TombstoneSet()
    once.absorb(deleteOp)
    var twice = TombstoneSet()
    twice.absorb(deleteOp)
    twice.absorb(deleteOp)
    expect(once == twice, "idempotence: absorbing the same delete twice equals absorbing it once")
    let log = [
        logged(1, replicaA, .createTile(id: tileT, kind: .terminal, title: "t", frame: frame1, zPosition: FracIndex(value: 0.5))),
        deleteOp,
    ]
    expect(localTestFold(log + [deleteOp]) == localTestFold(log), "idempotence: re-delivered delete does not change the folded output")
}

// ── absorb ignores every non-delete op. ──
do {
    var set = TombstoneSet()
    set.absorb(logged(1, replicaA, .createTile(id: tileA, kind: .terminal, title: "a", frame: frame1, zPosition: FracIndex(value: 0.5))))
    set.absorb(logged(2, replicaA, .setTileFrame(id: tileA, frame: bigFrame)))
    set.absorb(logged(3, replicaA, .setZoneSize(id: zoneZ, size: ZoneSize(width: 100, height: 100))))
    set.absorb(logged(4, replicaA, .setTileZone(tileId: tileA, zoneId: zoneZ)))
    set.absorb(logged(5, replicaA, .setTileZIndex(id: tileA, z: FracIndex(value: 0.9))))
    expect(set.tileIds.isEmpty && set.zoneIds.isEmpty, "absorb contract: only deleteTile/deleteZone insert (both sets stay empty)")
    expect(!set.isTombstoned(tileId: tileA) && !set.isTombstoned(zoneId: zoneZ), "absorb contract: lookups agree")
}

// ── CompactionLedger: round-trip + byte-identical canonical encoding. ──
var scannedByteCount = 0
do {
    let ledger = CompactionLedger(
        records: [
            TombstoneRecord(entityId: tileB, deleteOpId: OpId(lamport: 4, replica: replicaB), entityKind: .tile),
            TombstoneRecord(entityId: zoneZ, deleteOpId: OpId(lamport: 4, replica: replicaA), entityKind: .zone),
            TombstoneRecord(entityId: tileT, deleteOpId: OpId(lamport: 5, replica: replicaA), entityKind: .tile),
        ],
        compactedThrough: OpId(lamport: 6, replica: replicaA)
    )
    let encoded = try! JSONCodec.makeOpLogEncoder().encode(ledger)
    let decoded = try! JSONCodec.makeDecoder().decode(CompactionLedger.self, from: encoded)
    expect(decoded == ledger, "ledger: round-trips through the canonical encoder")
    let encodedAgain = try! JSONCodec.makeOpLogEncoder().encode(ledger)
    expect(encoded == encodedAgain, "ledger: canonical encoding is byte-identical across passes (\(encoded.count) bytes)")
    scannedByteCount += encoded.count

    // I5 taint scan over the ledger bytes too (it will be persisted/synced).
    let ledgerJson = String(decoding: encoded, as: UTF8.self)
    for token in ["runtimeRef", "%", "/Users/", "continuum-", "scrollback"] {
        expect(!ledgerJson.contains(token), "ledger I5: no banned token '\(token)'")
    }
}

// ── I5 taint scan over delete-op wire payloads. ──
do {
    let deletes = [
        logged(5, replicaA, .deleteTile(id: tileT)),
        logged(6, replicaB, .deleteZone(id: zoneZ)),
    ]
    for op in deletes {
        let data = try! JSONCodec.makeOpLogEncoder().encode(op)
        let json = String(decoding: data, as: UTF8.self)
        for token in ["runtimeRef", "%", "/Users/", "continuum-", "ssh://", "scrollback", "pid"] {
            expect(!json.contains(token), "delete-op I5: no banned token '\(token)' in \(json)")
        }
        scannedByteCount += data.count
    }
}

print("ContinuumRevivedSyncChecks passed: delete-wins policy pinned (move-vs-delete, zone variant, siblings, idempotence, absorb contract), ledger round-trip byte-identical, I5 scan clean (\(scannedByteCount) bytes scanned)")

// Ticket: docs/38-tickets/06-oplog-apply-compaction.md
runOpLogChecks()
try runOpLogBackendChecks()

print("ContinuumRevivedSyncChecks passed: materialize + compact proven (LWW, tombstone-vs-write, zone/tile convergence, compaction × tombstone boundary, I5 taint scan, I7 round-trip, ProjectStore + WorkspaceStore backend round-trips)")

// Ticket: docs/38-tickets/55-synctransport-seam.md
try await runSyncTransportChecks()
try await runSyncTransportBackendChecks()

// Ticket: docs/38-tickets/58-activity-projection-transport.md
try await runActivityProjectionChecks()

// Ticket: docs/38-tickets/57-cloudkit-transport-impl.md
try await runCloudKitSyncTransportChecks()

// Ticket: docs/38-tickets/61b-canvas-editor.md
try await runSpatialSyncChecks()

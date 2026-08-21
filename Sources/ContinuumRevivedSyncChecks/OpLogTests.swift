import ContinuumRevivedCore
import ContinuumRevivedSync
import Foundation

// Ticket: docs/38-tickets/06-oplog-apply-compaction.md
// Logic checks for `materialize`, `compact`, and `applySnapshot`. All
// in-process: no daemon, no network, no wall-clock ordering (only Lamport).
// Uses the top-level `expect` / `logged` helpers already defined by
// ticket 05's main.swift in this same executable target.

private let repA = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
private let repB = UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002")!

private func opId(_ lamport: UInt64, _ replica: UUID) -> OpId {
    OpId(lamport: lamport, replica: replica)
}

private func permutations<T>(_ items: [T]) -> [[T]] {
    guard items.count > 1 else { return [items] }
    var result: [[T]] = []
    for i in items.indices {
        var rest = items
        let picked = rest.remove(at: i)
        for tail in permutations(rest) {
            result.append([picked] + tail)
        }
    }
    return result
}

// MARK: - Per-field LWW correctness

private func runFieldLWWChecks() {
    let tileFrame1 = TileFrame(x: 0, y: 0, width: 100, height: 100)
    let tileFrameLow = TileFrame(x: 1, y: 1, width: 200, height: 200)
    let tileFrameHigh = TileFrame(x: 9, y: 9, width: 900, height: 900)
    let tileId = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!

    func assertTileFieldLWW<Value: Equatable>(
        _ label: String,
        low: LoggedOp,
        high: LoggedOp,
        extract: (MaterializedState) -> Value?,
        expected: Value
    ) {
        let create = LoggedOp(opId: opId(1, repA), op: .createTile(
            id: tileId, kind: .terminal, title: "t", frame: tileFrame1, zPosition: FracIndex(value: 0.4)
        ))
        for feed in [[create, low, high], [create, high, low]] {
            let result = extract(materialize(ops: feed))
            expect(result == expected, "\(label): higher-OpId write must win regardless of feed order (got \(String(describing: result)))")
        }
    }

    assertTileFieldLWW(
        "setTileFrame LWW",
        low: LoggedOp(opId: opId(2, repA), op: .setTileFrame(id: tileId, frame: tileFrameLow)),
        high: LoggedOp(opId: opId(3, repB), op: .setTileFrame(id: tileId, frame: tileFrameHigh)),
        extract: { $0.canvasState.tiles.first(where: { $0.id == tileId })?.frame },
        expected: tileFrameHigh
    )

    assertTileFieldLWW(
        "setTileZIndex LWW",
        low: LoggedOp(opId: opId(2, repA), op: .setTileZIndex(id: tileId, z: FracIndex(value: 0.2))),
        high: LoggedOp(opId: opId(3, repB), op: .setTileZIndex(id: tileId, z: FracIndex(value: 0.8))),
        extract: { $0.canvasState.tiles.first(where: { $0.id == tileId })?.zPosition },
        expected: FracIndex(value: 0.8)
    )

    assertTileFieldLWW(
        "setTileTitle LWW",
        low: LoggedOp(opId: opId(2, repA), op: .setTileTitle(id: tileId, title: "low")),
        high: LoggedOp(opId: opId(3, repB), op: .setTileTitle(id: tileId, title: "high")),
        extract: { $0.canvasState.tiles.first(where: { $0.id == tileId })?.title },
        expected: "high"
    )

    assertTileFieldLWW(
        "setTileKind LWW",
        low: LoggedOp(opId: opId(2, repA), op: .setTileKind(id: tileId, kind: .note)),
        high: LoggedOp(opId: opId(3, repB), op: .setTileKind(id: tileId, kind: .browser)),
        extract: { $0.canvasState.tiles.first(where: { $0.id == tileId })?.kind },
        expected: .browser
    )

    let zoneId = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
    let zoneOrigin1 = ZonePoint(x: 0, y: 0)
    let zoneSize1 = ZoneSize(width: 800, height: 600)

    func assertZoneFieldLWW<Value: Equatable>(
        _ label: String,
        low: LoggedOp,
        high: LoggedOp,
        extract: (MaterializedState) -> Value?,
        expected: Value
    ) {
        let create = LoggedOp(opId: opId(1, repA), op: .createZone(
            id: zoneId, projectId: nil, origin: zoneOrigin1, size: zoneSize1, name: "z", color: "mint"
        ))
        for feed in [[create, low, high], [create, high, low]] {
            let result = extract(materialize(ops: feed))
            expect(result == expected, "\(label): higher-OpId write must win regardless of feed order (got \(String(describing: result)))")
        }
    }

    assertZoneFieldLWW(
        "setZoneOrigin LWW",
        low: LoggedOp(opId: opId(2, repA), op: .setZoneOrigin(id: zoneId, origin: ZonePoint(x: 1, y: 1))),
        high: LoggedOp(opId: opId(3, repB), op: .setZoneOrigin(id: zoneId, origin: ZonePoint(x: 9, y: 9))),
        extract: { $0.workspaceDocument.zones.first(where: { $0.zoneId == zoneId })?.origin },
        expected: ZonePoint(x: 9, y: 9)
    )

    assertZoneFieldLWW(
        "setZoneSize LWW",
        low: LoggedOp(opId: opId(2, repA), op: .setZoneSize(id: zoneId, size: ZoneSize(width: 10, height: 10))),
        high: LoggedOp(opId: opId(3, repB), op: .setZoneSize(id: zoneId, size: ZoneSize(width: 90, height: 90))),
        extract: { $0.workspaceDocument.zones.first(where: { $0.zoneId == zoneId })?.size },
        expected: ZoneSize(width: 90, height: 90)
    )

    assertZoneFieldLWW(
        "setZoneName LWW",
        low: LoggedOp(opId: opId(2, repA), op: .setZoneName(id: zoneId, name: "low")),
        high: LoggedOp(opId: opId(3, repB), op: .setZoneName(id: zoneId, name: "high")),
        extract: { $0.workspaceDocument.zones.first(where: { $0.zoneId == zoneId })?.name },
        expected: "high"
    )

    assertZoneFieldLWW(
        "setZoneColor LWW",
        low: LoggedOp(opId: opId(2, repA), op: .setZoneColor(id: zoneId, color: "red")),
        high: LoggedOp(opId: opId(3, repB), op: .setZoneColor(id: zoneId, color: "blue")),
        extract: { $0.workspaceDocument.zones.first(where: { $0.zoneId == zoneId })?.color },
        expected: "blue"
    )

    assertZoneFieldLWW(
        "setZoneCollapsed LWW",
        low: LoggedOp(opId: opId(2, repA), op: .setZoneCollapsed(id: zoneId, collapsed: false)),
        high: LoggedOp(opId: opId(3, repB), op: .setZoneCollapsed(id: zoneId, collapsed: true)),
        extract: { $0.workspaceDocument.zones.first(where: { $0.zoneId == zoneId })?.collapsed },
        expected: true
    )

    assertZoneFieldLWW(
        "setZoneProjectId LWW",
        low: LoggedOp(opId: opId(2, repA), op: .setZoneProjectId(id: zoneId, projectId: nil)),
        high: LoggedOp(opId: opId(3, repB), op: .setZoneProjectId(id: zoneId, projectId: tileId)),
        extract: { $0.workspaceDocument.zones.first(where: { $0.zoneId == zoneId })?.projectId },
        expected: tileId
    )

    assertZoneFieldLWW(
        "setZoneAutoLayoutMode LWW",
        low: LoggedOp(opId: opId(2, repA), op: .setZoneAutoLayoutMode(id: zoneId, mode: .disabled)),
        high: LoggedOp(opId: opId(3, repB), op: .setZoneAutoLayoutMode(id: zoneId, mode: .enabled)),
        extract: { $0.workspaceDocument.zones.first(where: { $0.zoneId == zoneId })?.autoLayoutMode },
        expected: ZoneAutoLayoutMode.enabled
    )

    assertZoneFieldLWW(
        "setZonePosition LWW",
        low: LoggedOp(opId: opId(2, repA), op: .setZonePosition(id: zoneId, position: FracIndex(value: 0.2))),
        high: LoggedOp(opId: opId(3, repB), op: .setZonePosition(id: zoneId, position: FracIndex(value: 0.8))),
        extract: { $0.workspaceDocument.zones.first(where: { $0.zoneId == zoneId })?.zPosition },
        expected: FracIndex(value: 0.8)
    )

    print("oplog: per-field LWW correctness pinned for every scalar tile/zone field (both feed orders)")
}

// MARK: - Tombstone wins over concurrent write

private func runTombstoneVsConcurrentWriteChecks() {
    let tileId = UUID(uuidString: "30000000-0000-4000-8000-000000000003")!
    let frame1 = TileFrame(x: 0, y: 0, width: 100, height: 100)
    let bigFrame = TileFrame(x: 10, y: 10, width: 999, height: 999)

    // 2-op case: delete (lower Lamport) vs a concurrent setTileFrame (higher
    // Lamport). The delete must win regardless of the order fed to
    // materialize (materialize always re-sorts by OpId internally).
    let create = LoggedOp(opId: opId(1, repA), op: .createTile(
        id: tileId, kind: .terminal, title: "t", frame: frame1, zPosition: FracIndex(value: 0.5)
    ))
    let delete = LoggedOp(opId: opId(2, repA), op: .deleteTile(id: tileId))
    let concurrentWrite = LoggedOp(opId: opId(50, repB), op: .setTileFrame(id: tileId, frame: bigFrame))

    for perm in permutations([delete, concurrentWrite]) {
        let result = materialize(ops: [create] + perm)
        expect(
            result.canvasState.tiles.first(where: { $0.id == tileId }) == nil,
            "tombstone-vs-write (2-op perm \(perm.map(\.op))): tile must be absent — delete at Lamport 2 beats setTileFrame at Lamport 50"
        )
    }

    // 3-op case: all 3! = 6 orderings of [create, delete, concurrentWrite]
    // fed to materialize must produce the identical (tombstoned) result.
    for perm in permutations([create, delete, concurrentWrite]) {
        let result = materialize(ops: perm)
        expect(
            result.canvasState.tiles.first(where: { $0.id == tileId }) == nil,
            "tombstone-vs-write (3-op perm): tile must be absent under every feed order"
        )
    }

    // Non-vacuous sanity: WITHOUT the delete, the same high-Lamport write DOES land.
    let withoutDelete = materialize(ops: [create, concurrentWrite])
    expect(
        withoutDelete.canvasState.tiles.first(where: { $0.id == tileId })?.frame == bigFrame,
        "tombstone-vs-write sanity: without the delete the Lamport-50 write must apply (guard is load-bearing, not vacuously true)"
    )

    print("oplog: tombstone beats concurrent higher-Lamport write, all 2! and 3! permutations agree")
}

// MARK: - Tile-zone register convergence

private func runTileZoneConvergenceChecks() {
    let tileT = UUID(uuidString: "40000000-0000-4000-8000-000000000004")!
    let zoneX = UUID(uuidString: "40000000-0000-4000-8000-0000000000AA")!
    let zoneY = UUID(uuidString: "40000000-0000-4000-8000-0000000000BB")!
    let origin = ZonePoint(x: 0, y: 0)
    let size = ZoneSize(width: 400, height: 300)

    let setup: [LoggedOp] = [
        LoggedOp(opId: opId(1, repA), op: .createZone(id: zoneX, projectId: nil, origin: origin, size: size, name: "X", color: "mint")),
        LoggedOp(opId: opId(1, repB), op: .createZone(id: zoneY, projectId: nil, origin: origin, size: size, name: "Y", color: "grape")),
        LoggedOp(opId: opId(2, repA), op: .createTile(id: tileT, kind: .terminal, title: "t", frame: TileFrame(x: 0, y: 0, width: 10, height: 10), zPosition: FracIndex(value: 0.5))),
    ]
    // Replica A: setTileZone(T, X) at Lamport 5. Replica B: setTileZone(T, Y) at Lamport 6 (higher — wins).
    let fromA = LoggedOp(opId: opId(5, repA), op: .setTileZone(tileId: tileT, zoneId: zoneX))
    let fromB = LoggedOp(opId: opId(6, repB), op: .setTileZone(tileId: tileT, zoneId: zoneY))

    for feed in [setup + [fromA, fromB], setup + [fromB, fromA]] {
        let result = materialize(ops: feed)
        let tile = result.canvasState.tiles.first(where: { $0.id == tileT })
        expect(tile?.zoneId == zoneY, "tile-zone convergence: higher-Lamport setTileZone(T, Y) must win regardless of delivery order")

        // Membership is derived from `canvasState.tiles`' `zoneId` register —
        // the ONE flat tile store this ticket's op log actually produces.
        // `WorkspaceDocument.ambientTiles` is a SEPARATE, disjoint store
        // (WorkspaceDocument.swift) that `materialize` deliberately leaves
        // empty here, because the op stream carries no information about
        // which tiles are project-scoped vs. workspace-ambient — see the
        // `resolve()` comment in OpLog.swift. Reading membership through
        // `WorkspaceDocument.tiles(forZone:)` here would silently rely on
        // that store being populated, which is exactly the invented,
        // duplicating derivation ticket 06's review rejected.
        let membersOfX = result.canvasState.tiles.filter { $0.zoneId == zoneX }
        let membersOfY = result.canvasState.tiles.filter { $0.zoneId == zoneY }
        expect(!membersOfX.contains(where: { $0.id == tileT }), "tile-zone convergence: zone X's derived member list must not contain T")
        expect(membersOfY.contains(where: { $0.id == tileT }), "tile-zone convergence: zone Y's derived member list must contain T")
        expect(result.workspaceDocument.ambientTiles.isEmpty, "tile-zone convergence: ambientTiles is deliberately left empty by materialize (see resolve()) — it must never silently gain a duplicate copy of T")

        // "At most one zone" is automatic by construction: a tile has exactly
        // one zoneId register, never a membership list, so it cannot appear
        // in two zones' derived lists simultaneously.
        let allMemberships = result.canvasState.tiles.compactMap(\.zoneId).filter { $0 == zoneX || $0 == zoneY }
        expect(allMemberships.count <= 1, "tile-zone convergence: no tile appears in two zones simultaneously")
    }

    print("oplog: tile-zone LWW register converges to the higher-Lamport writer, membership derived correctly from canvasState.tiles' zoneId register (ambientTiles left empty by design)")
}

// MARK: - Zone position sort stability

private func runZonePositionSortChecks() {
    let zoneLo = UUID(uuidString: "50000000-0000-4000-8000-000000000001")!
    let zoneMid = UUID(uuidString: "50000000-0000-4000-8000-000000000002")!
    let zoneHi = UUID(uuidString: "50000000-0000-4000-8000-000000000003")!
    let origin = ZonePoint(x: 0, y: 0)
    let size = ZoneSize(width: 100, height: 100)

    let setup: [LoggedOp] = [
        LoggedOp(opId: opId(1, repA), op: .createZone(id: zoneLo, projectId: nil, origin: origin, size: size, name: "lo", color: "mint")),
        LoggedOp(opId: opId(1, repB), op: .createZone(id: zoneMid, projectId: nil, origin: origin, size: size, name: "mid", color: "grape")),
        LoggedOp(opId: opId(1, repA), op: .createZone(id: zoneHi, projectId: nil, origin: origin, size: size, name: "hi", color: "sky")),
        LoggedOp(opId: opId(2, repA), op: .setZonePosition(id: zoneLo, position: FracIndex(value: 0.25))),
        LoggedOp(opId: opId(2, repB), op: .setZonePosition(id: zoneMid, position: FracIndex(value: 0.5))),
        LoggedOp(opId: opId(2, repA), op: .setZonePosition(id: zoneHi, position: FracIndex(value: 0.75))),
    ]
    // Concurrent reposition of the middle zone: replica A → 0.6 (Lamport 10),
    // replica B → 0.3 (Lamport 11, higher — wins).
    let fromA = LoggedOp(opId: opId(10, repA), op: .setZonePosition(id: zoneMid, position: FracIndex(value: 0.6)))
    let fromB = LoggedOp(opId: opId(11, repB), op: .setZonePosition(id: zoneMid, position: FracIndex(value: 0.3)))

    for feed in [setup + [fromA, fromB], setup + [fromB, fromA]] {
        let result = materialize(ops: feed)
        let positions = result.workspaceDocument.zonesInZOrder.map(\.zPosition.value)
        expect(positions == [0.25, 0.3, 0.75], "zone position sort stability: expected [0.25, 0.3, 0.75], got \(positions)")
        expect(Set(result.workspaceDocument.zones.map(\.zoneId)).count == 3, "zone position sort stability: exactly 3 zones, no duplicates")
    }

    print("oplog: zone position LWW + sort stable at [0.25, 0.3, 0.75] regardless of delivery order")
}

// MARK: - materialize invariants (runtimeRef nil, default viewport)

private func runMaterializeInvariantChecks(sampleOps: [LoggedOp]) {
    let result = materialize(ops: sampleOps)
    expect(result.canvasState.tiles.allSatisfy { $0.runtimeRef == nil }, "materialize invariant: every tile must have runtimeRef == nil")
    expect(result.canvasState.viewport == CanvasViewport(x: 0, y: 0, zoom: 1.0), "materialize invariant: canvasState.viewport must be the synthetic default")
    expect(result.workspaceDocument.viewport == CanvasViewport(x: 0, y: 0, zoom: 1.0), "materialize invariant: workspaceDocument.viewport must be the synthetic default")
    expect(result.workspaceDocument.ambientTiles.isEmpty, "materialize invariant: ambientTiles is deliberately left empty — the op log has no per-project scoping to partition canvasState.tiles against it (see the resolve() comment in OpLog.swift); this pins the decision so a future change to it is deliberate, not silent drift")
    print("oplog: materialize invariants hold (runtimeRef nil on every tile, default viewport, ambientTiles left empty by design) over \(sampleOps.count) ops")
}

// MARK: - Seeded pseudo-random legal op log (deterministic across runs)

/// A tiny deterministic PRNG (splitmix64) — NOT `Int.random`, so the same
/// seed produces the exact same op log on every run. This is required for
/// the dogfood contract: `canonicalBytes` must be byte-identical across two
/// consecutive runs of the check binary.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextInt(_ upperBound: Int) -> Int { Int(next() % UInt64(upperBound)) }
    mutating func nextDouble01() -> Double { Double(next() % 1_000_000) / 1_000_000.0 }
}

/// Builds a 50-op legal log across 3 replicas: 3 zone creates, 5 tile
/// creates, then 42 field-set ops with random targets/fields/values drawn
/// from a fixed seed. Lamport values are assigned 1...50 sequentially (one
/// op per Lamport, round-robin replica) so there is exactly one op at
/// `lamport == 30` — the compaction boundary the round-trip check pins.
private func buildRandomLegalLog(seed: UInt64) -> [LoggedOp] {
    var rng = SplitMix64(seed: seed)
    let replicas = [repA, repB, UUID(uuidString: "CCCCCCCC-0000-4000-8000-000000000003")!]
    let zoneIds = (0..<3).map { UUID(uuidString: String(format: "60000000-0000-4000-8000-%012d", $0))! }
    let tileIds = (0..<5).map { UUID(uuidString: String(format: "70000000-0000-4000-8000-%012d", $0))! }

    var ops: [LoggedOp] = []
    var lamport: UInt64 = 1
    func nextReplica() -> UUID { replicas[Int(lamport - 1) % replicas.count] }
    func append(_ op: Op) {
        ops.append(LoggedOp(opId: opId(lamport, nextReplica()), op: op))
        lamport += 1
    }

    for zoneId in zoneIds {
        append(.createZone(id: zoneId, projectId: nil, origin: ZonePoint(x: 0, y: 0), size: ZoneSize(width: 400, height: 300), name: "zone", color: "mint"))
    }
    for tileId in tileIds {
        append(.createTile(id: tileId, kind: .terminal, title: "tile", frame: TileFrame(x: 0, y: 0, width: 100, height: 100), zPosition: FracIndex(value: 0.5)))
    }

    while ops.count < 50 {
        // Cases 11/12 are `deleteTile`/`deleteZone` — the compaction round-trip
        // check (`runOpLogChecks`) MUST exercise the tombstone-vs-compaction
        // interaction the ticket flags as its most dangerous subtlety, not
        // just plain LWW fields. Ops after a delete that still target the
        // deleted id (from either case below or the earlier field-set cases)
        // are legal no-ops by construction (delete-wins), so this never
        // produces an illegal log.
        switch rng.nextInt(13) {
        case 0: append(.setTileFrame(id: tileIds[rng.nextInt(tileIds.count)], frame: TileFrame(x: rng.nextDouble01() * 500, y: rng.nextDouble01() * 500, width: 100, height: 100)))
        case 1: append(.setTileZIndex(id: tileIds[rng.nextInt(tileIds.count)], z: FracIndex(value: 0.01 + rng.nextDouble01() * 0.98)))
        case 2: append(.setTileTitle(id: tileIds[rng.nextInt(tileIds.count)], title: "t\(lamport)"))
        case 3: append(.setTileKind(id: tileIds[rng.nextInt(tileIds.count)], kind: rng.nextInt(2) == 0 ? .note : .browser))
        case 4: append(.setZoneOrigin(id: zoneIds[rng.nextInt(zoneIds.count)], origin: ZonePoint(x: rng.nextDouble01() * 500, y: rng.nextDouble01() * 500)))
        case 5: append(.setZoneSize(id: zoneIds[rng.nextInt(zoneIds.count)], size: ZoneSize(width: 200 + rng.nextDouble01() * 200, height: 200)))
        case 6: append(.setZoneName(id: zoneIds[rng.nextInt(zoneIds.count)], name: "z\(lamport)"))
        case 7: append(.setZoneCollapsed(id: zoneIds[rng.nextInt(zoneIds.count)], collapsed: rng.nextInt(2) == 0))
        case 8: append(.setZonePosition(id: zoneIds[rng.nextInt(zoneIds.count)], position: FracIndex(value: 0.01 + rng.nextDouble01() * 0.98)))
        case 9: append(.setTileZone(tileId: tileIds[rng.nextInt(tileIds.count)], zoneId: rng.nextInt(2) == 0 ? nil : zoneIds[rng.nextInt(zoneIds.count)]))
        case 10: append(.setLastActiveTile(id: tileIds[rng.nextInt(tileIds.count)]))
        case 11: append(.deleteTile(id: tileIds[rng.nextInt(tileIds.count)]))
        default: append(.deleteZone(id: zoneIds[rng.nextInt(zoneIds.count)]))
        }
    }
    return ops
}

// MARK: - Compaction × tombstone boundary (the ticket's "most dangerous subtlety")

/// Dedicated coverage for the two boundary cases the ticket calls out for
/// compaction specifically — distinct from `runTombstoneVsConcurrentWriteChecks`,
/// which only proves the policy at the plain `materialize()` level, never
/// through `compact`/`applySnapshot`/`materialize(onto:)`:
///
///   1. A delete BELOW the low-water mark drops the entity from the snapshot
///      entirely; a later write (or a stale re-delivered CREATE) for the same
///      id arrives in the tail. Only `CompactedSnapshot.ledger` lets the
///      overlay fold recognize the id as a zombie and refuse to resurrect it.
///   2. A delete IN THE TAIL removes an entity that is still alive in the
///      snapshot — this must win regardless of tail feed order.
private func runCompactionTombstoneBoundaryChecks() {
    let repC = UUID(uuidString: "CCCCCCCC-0000-4000-8000-000000000099")!
    let tileId = UUID(uuidString: "80000000-0000-4000-8000-000000000001")!
    let zoneId = UUID(uuidString: "80000000-0000-4000-8000-000000000002")!
    let frame1 = TileFrame(x: 0, y: 0, width: 100, height: 100)
    let staleFrame = TileFrame(x: 999, y: 999, width: 999, height: 999)
    let origin = ZonePoint(x: 0, y: 0)
    let size = ZoneSize(width: 400, height: 300)

    // Case A: delete BELOW the mark; a higher-Lamport field-set for the SAME
    // id arrives in the tail. No accumulator survives compaction for this id
    // at all (already proven safe by construction, but untested through the
    // compactor before this check existed) — the field-set must stay a no-op.
    do {
        let log: [LoggedOp] = [
            LoggedOp(opId: opId(1, repA), op: .createTile(id: tileId, kind: .terminal, title: "t", frame: frame1, zPosition: FracIndex(value: 0.5))),
            LoggedOp(opId: opId(2, repA), op: .deleteTile(id: tileId)),
        ]
        let result = compact(log: log, through: 10)
        expect(result.snapshot.state.canvasState.tiles.isEmpty, "compaction tombstone A: the tombstoned tile must already be absent from the snapshot itself")
        let tail = [LoggedOp(opId: opId(50, repB), op: .setTileFrame(id: tileId, frame: staleFrame))]
        let overlaid = materialize(onto: result.snapshot.state, baseOpId: result.snapshot.compactionOpId, ledger: result.snapshot.ledger, tail: tail)
        expect(overlaid.canvasState.tiles.first(where: { $0.id == tileId }) == nil, "compaction tombstone A: a higher-Lamport field-set in the tail for a pre-compaction tombstoned tile must not resurrect it")
    }

    // Case B: the dangerous resurrection vector — delete BELOW the mark, then
    // a STALE duplicate createTile (same id, e.g. a retried network delivery)
    // arrives in the tail. Only `CompactedSnapshot.ledger` prevents this.
    do {
        let originalCreate = LoggedOp(opId: opId(1, repA), op: .createTile(id: tileId, kind: .terminal, title: "t", frame: frame1, zPosition: FracIndex(value: 0.5)))
        let log: [LoggedOp] = [
            originalCreate,
            LoggedOp(opId: opId(2, repA), op: .deleteTile(id: tileId)),
        ]
        let result = compact(log: log, through: 10)
        expect(
            result.snapshot.ledger.records.contains(where: { $0.entityId == tileId && $0.entityKind == .tile }),
            "compaction tombstone B: compact() must carry the deleteTile forward into CompactedSnapshot.ledger"
        )
        let overlaid = materialize(onto: result.snapshot.state, baseOpId: result.snapshot.compactionOpId, ledger: result.snapshot.ledger, tail: [originalCreate])
        expect(
            overlaid.canvasState.tiles.first(where: { $0.id == tileId }) == nil,
            "compaction tombstone B: a stale re-delivered createTile for a pre-compaction tombstoned id must NOT resurrect it — CompactionLedger is the only thing preventing this"
        )
    }

    // Case B': same resurrection vector, zone variant.
    do {
        let originalCreate = LoggedOp(opId: opId(1, repA), op: .createZone(id: zoneId, projectId: nil, origin: origin, size: size, name: "z", color: "mint"))
        let log: [LoggedOp] = [
            originalCreate,
            LoggedOp(opId: opId(2, repA), op: .deleteZone(id: zoneId)),
        ]
        let result = compact(log: log, through: 10)
        expect(
            result.snapshot.ledger.records.contains(where: { $0.entityId == zoneId && $0.entityKind == .zone }),
            "compaction tombstone B': compact() must carry the deleteZone forward into CompactedSnapshot.ledger"
        )
        let overlaid = materialize(onto: result.snapshot.state, baseOpId: result.snapshot.compactionOpId, ledger: result.snapshot.ledger, tail: [originalCreate])
        expect(
            overlaid.workspaceDocument.zones.first(where: { $0.zoneId == zoneId }) == nil,
            "compaction tombstone B': a stale re-delivered createZone for a pre-compaction tombstoned id must NOT resurrect it"
        )
    }

    // Case C: delete happens IN THE TAIL, folded onto a snapshot where the
    // tile is still alive. Must win regardless of the tail's feed order.
    do {
        let log: [LoggedOp] = [
            LoggedOp(opId: opId(1, repC), op: .createTile(id: tileId, kind: .terminal, title: "t", frame: frame1, zPosition: FracIndex(value: 0.5))),
        ]
        let result = compact(log: log, through: 10)
        expect(result.snapshot.state.canvasState.tiles.contains(where: { $0.id == tileId }), "compaction tombstone C: tile must still be alive in the snapshot before the tail's delete")

        let deleteInTail = LoggedOp(opId: opId(20, repB), op: .deleteTile(id: tileId))
        let concurrentWriteInTail = LoggedOp(opId: opId(19, repA), op: .setTileFrame(id: tileId, frame: staleFrame))
        for tail in [[deleteInTail, concurrentWriteInTail], [concurrentWriteInTail, deleteInTail]] {
            let overlaid = materialize(onto: result.snapshot.state, baseOpId: result.snapshot.compactionOpId, ledger: result.snapshot.ledger, tail: tail)
            expect(overlaid.canvasState.tiles.first(where: { $0.id == tileId }) == nil, "compaction tombstone C: a delete arriving in the tail must remove a tile still alive in the snapshot, regardless of tail feed order")
        }
    }

    print("oplog: compaction × tombstone boundary proven — delete below the mark survives snapshot+tail (incl. the stale-recreate resurrection guard via CompactionLedger, tile and zone), delete in the tail removes a snapshot-alive entity regardless of feed order")
}

// MARK: - Compaction round-trip + I7 snapshot round-trip + manifest

private func measureMicros(_ block: () -> Void) -> Int {
    let start = DispatchTime.now().uptimeNanoseconds
    block()
    let end = DispatchTime.now().uptimeNanoseconds
    return max(1, Int((end - start) / 1000))
}

func runOpLogChecks() {
    runFieldLWWChecks()
    runTombstoneVsConcurrentWriteChecks()
    runTileZoneConvergenceChecks()
    runZonePositionSortChecks()
    runCompactionTombstoneBoundaryChecks()

    let randomLog = buildRandomLegalLog(seed: 0xC0FFEE)
    expect(randomLog.count == 50, "random legal log must contain exactly 50 ops, got \(randomLog.count)")
    runMaterializeInvariantChecks(sampleOps: randomLog)

    var latencies: [Int] = []
    let lowWaterMark: UInt64 = 30

    // The boundary op (lamport == lowWaterMark) must exist and must not
    // leak into the tail.
    expect(randomLog.contains(where: { $0.opId.lamport == lowWaterMark }), "fixture assumption: exactly one op at lamport == lowWaterMark")

    var fullMaterialized: MaterializedState!
    latencies.append(measureMicros { fullMaterialized = materialize(ops: randomLog) })

    var compactionResult: CompactionResult!
    latencies.append(measureMicros { compactionResult = compact(log: randomLog, through: lowWaterMark) })

    expect(
        !compactionResult.tail.contains(where: { $0.opId == compactionResult.snapshot.compactionOpId }),
        "compaction: the boundary op (compactionOpId) must not be present in the tail"
    )
    expect(
        !compactionResult.tail.contains(where: { $0.opId.lamport <= lowWaterMark }),
        "compaction: no tail op may have lamport <= lowWaterMark"
    )

    // Independent regression guard on `compact` itself (not a tautology):
    // `belowMark` is re-derived here ONLY to check that `compact`'s snapshot
    // actually folded the below-mark ops correctly — this is the assertion
    // that catches `compact` returning an empty/wrong-slice snapshot, which
    // nothing else below would catch because everything else is driven from
    // `compactionResult.snapshot.state` itself.
    let belowMark = randomLog.filter { $0.opId.lamport <= lowWaterMark }
    let independentBelowMarkBytes = try! materialize(ops: belowMark).canonicalEncoded()
    let snapshotStateBytes = try! compactionResult.snapshot.state.canonicalEncoded()
    expect(
        snapshotStateBytes == independentBelowMarkBytes,
        "compaction: snapshot.state must canonically equal an independently computed materialize(ops: belowMark) — guards compact() folding the correct slice, not an empty/wrong one"
    )

    let fullBytes = try! fullMaterialized.canonicalEncoded()

    // Compose the snapshot with its own tail via the overlay primitive
    // (`materialize(onto:baseOpId:tail:)`) — this is driven from
    // `compactionResult.snapshot.state` ALONE, never from `belowMark`, so it
    // actually proves "snapshot + tail" composition rather than smuggling in
    // the full log through a re-derived slice.
    var overlaid: MaterializedState!
    latencies.append(measureMicros {
        overlaid = materialize(onto: compactionResult.snapshot.state, baseOpId: compactionResult.snapshot.compactionOpId, ledger: compactionResult.snapshot.ledger, tail: compactionResult.tail)
    })
    let overlaidBytes = try! overlaid.canonicalEncoded()
    expect(
        fullBytes == overlaidBytes,
        "compaction round-trip: materialize(onto: snapshot.state, tail: snapshot.tail) must canonically encode identically to materialize(full log) — proves snapshot.state is a real, composable base, not just a re-derivation of belowMark"
    )

    // Deliver the tail ops individually to a fresh replica that only has the
    // snapshot (via applySnapshot), and assert it reaches the same state —
    // again composed from `snapshot.state` alone, never `belowMark`.
    let survivingTail = applySnapshot(compactionResult.snapshot, ontop: compactionResult.tail)
    expect(survivingTail == compactionResult.tail, "applySnapshot: a replica whose local log IS the tail must see the entire tail survive")
    var freshReplicaMaterialized: MaterializedState!
    latencies.append(measureMicros {
        freshReplicaMaterialized = materialize(onto: compactionResult.snapshot.state, baseOpId: compactionResult.snapshot.compactionOpId, ledger: compactionResult.snapshot.ledger, tail: survivingTail)
    })
    expect(
        (try! freshReplicaMaterialized.canonicalEncoded()) == fullBytes,
        "applySnapshot round-trip: a fresh replica holding ONLY snapshot.state + surviving tail (no belowMark, no full log) must reach the same state as the full log"
    )

    // applySnapshot boundary correctness: a local op AT the mark must be
    // dropped (already folded), never duplicated into the tail.
    let atMarkOp = randomLog.first(where: { $0.opId.lamport == lowWaterMark })!
    let localLogWithAtMark = compactionResult.tail + [atMarkOp]
    let survivingWithAtMark = applySnapshot(compactionResult.snapshot, ontop: localLogWithAtMark)
    expect(!survivingWithAtMark.contains(atMarkOp), "applySnapshot: an op at exactly the compaction mark must be dropped, not duplicated into the tail")

    // I7: CompactedSnapshot round-trips through JSON and re-materializing
    // from it (i.e. from its already-materialized `state`) is unaffected.
    let snapshotEncoded = try! JSONCodec.makeOpLogEncoder().encode(compactionResult.snapshot)
    let snapshotDecoded = try! JSONCodec.makeDecoder().decode(CompactedSnapshot.self, from: snapshotEncoded)
    expect(snapshotDecoded == compactionResult.snapshot, "I7: CompactedSnapshot round-trips through JSON under ==")
    expect(
        (try! snapshotDecoded.state.canonicalEncoded()) == (try! compactionResult.snapshot.state.canonicalEncoded()),
        "I7: re-materializing from the round-tripped snapshot produces the same canonical bytes"
    )

    // I5 taint scan over ticket 06's new sync surfaces (matching the pattern
    // ticket 05 already applies to its delete-op and ledger bytes): scan the
    // canonical bytes of a full `MaterializedState` AND a `CompactedSnapshot`
    // for banned host-local tokens. `runtimeRef` is checked structurally too
    // (`runMaterializeInvariantChecks` asserts every tile's `runtimeRef ==
    // nil`, and `Tile`'s `encodeIfPresent` means the key is entirely absent
    // when nil) — this scan is the same boundary-hardening belt-and-suspenders
    // check ticket 05 applied, over the two new wire types this ticket adds.
    let taintScanTargets: [(String, Data)] = [("MaterializedState", fullBytes), ("CompactedSnapshot", snapshotEncoded)]
    var taintScannedBytes = 0
    for (label, data) in taintScanTargets {
        let json = String(decoding: data, as: UTF8.self)
        for token in ["runtimeRef", "%", "/Users/", "continuum-", "ssh://", "scrollback", "pid"] {
            expect(!json.contains(token), "I5 taint scan (\(label)): no banned token '\(token)' in canonical bytes")
        }
        taintScannedBytes += data.count
    }

    let canonicalSnapshotBytes = snapshotEncoded.count
    let maxLatency = latencies.max() ?? 1

    // Canonical byte-identity is GATED here, not just printed. The dogfood
    // contract (ticket "How we test it / UX") requires `canonicalBytes` to be
    // stable across two consecutive runs of the same fixture; assert that
    // directly by compacting the SAME log a second time and comparing full
    // byte equality (not just `.count`), and additionally assert stability
    // holds for a shuffled-order same-multiset log — the actual I4 claim for
    // the compaction path, not merely "printing didn't crash twice."
    let compactionResultAgain = compact(log: randomLog, through: lowWaterMark)
    let snapshotEncodedAgain = try! JSONCodec.makeOpLogEncoder().encode(compactionResultAgain.snapshot)
    expect(
        snapshotEncodedAgain == snapshotEncoded,
        "canonical snapshot bytes must be byte-identical (not just same length) across two identical compact() runs on the same log"
    )

    var shuffleRNG = SplitMix64(seed: 0xDEADBEEF)
    let shuffledLog = randomLog.shuffled(using: &shuffleRNG)
    let shuffledCompaction = compact(log: shuffledLog, through: lowWaterMark)
    let shuffledEncoded = try! JSONCodec.makeOpLogEncoder().encode(shuffledCompaction.snapshot)
    expect(
        shuffledEncoded == snapshotEncoded,
        "canonical snapshot bytes must be identical for a shuffled-array-order, same-multiset log — compact()'s own I4 guarantee, not just materialize()'s"
    )

    print("oplog: compaction round-trip proven (snapshot composed with tail via the overlay primitive == full log canonically), I7 snapshot JSON round-trip clean, canonical bytes gated stable across a repeat run and a shuffled-order run, I5 taint scan clean over MaterializedState + CompactedSnapshot (\(taintScannedBytes) bytes scanned)")
    print("oplog.compaction.opsProcessed      = \(randomLog.count)")
    print("oplog.snapshot.canonicalBytes      = \(canonicalSnapshotBytes)")
    print("oplog.materialize.maxLatencyMicros = \(maxLatency)")
}

# Op-log apply & compaction

**Phase 0 — Foundations · the op-log apply and compaction ticket**

## What this delivers

After this ticket, the op-log core is executable: you can hand a sequence of `LoggedOp` values (in any order, from any number of replicas) to `materialize` and receive a deterministic `CanvasState` and `WorkspaceDocument`. You can also compact a long log down to a snapshot plus the tail of ops that followed it, so the log never grows without bound. These two capabilities — apply and compact — are the engine that makes the deterministic op-log a sync primitive rather than just a data structure. Nothing about sync transport, CloudKit, or iOS needs to exist for this ticket to be completed and proven.

The outcome the owner observes: the convergence fuzz written in the preceding ticket now has a real `materialize` and `compact` to drive, and the I4 invariant (any op order, any replica count → byte-identical state) is proven mechanically in-process, with no network and no human eyes.

## How it fits

This ticket is the direct execution layer that the op enum and logged-op envelope ticket defined and the three re-modeling tickets — the membership-as-LWW-register ticket, the z-order-as-fractional-index ticket, and the delete-as-tombstone ticket — made deterministically mergeable. Those four tickets are hard prerequisites: `materialize` only works because every conflict policy has already been resolved into a deterministic rule by those re-models. Without the tombstone, delete-wins is unimplementable; without the tile-level zone register, membership convergence requires array-CRDT machinery we don't have; without the fractional index, z-order reorder requires a list-move algorithm we have no reason to build.

What this ticket unlocks: the convergence fuzz ticket can now run for real rather than against a stub. The sync/observation type split ticket can reference `materialize` as the thing that produces the synced spatial snapshot. Every subsequent phase — session topology, agent awareness, the CloudKit transport — rests on the guarantee that spatial state can be reconstructed correctly from a log, regardless of delivery order.

## The approach

`materialize` takes a multiset of `LoggedOp` values and folds them into the spatial state through a two-pass algorithm: first sort the entire log by `OpId` (Lamport clock as the primary key, `replicaId` UUID as the tie-break, both compared lexicographically), then fold in total order applying each op through a set of pure reducer functions. The sort order is the convergence guarantee — every replica with the same multiset of ops sorts identically and folds identically, producing byte-identical output.

The per-op conflict policies are already decided (D3, locked):

- **Create** is add-wins. A `createTile` or `createZone` op with a fresh UUID never collides; re-delivery is a no-op if the id is already present.
- **Delete** is delete-wins via a tombstone set. A `deleteTile` op adds the tile's UUID to an immutable tombstone set; `materialize` drops any tile present in that set regardless of whether a `setTileFrame` with a higher Lamport also arrived — a concurrent move never resurrects a deleted tile.
- **Scalar field updates** (frame, title, color, collapsed, size, origin) are last-writer-wins per field. The op with the greater `OpId` wins; applying a losing op is a no-op because the fold tracks the winning `OpId` per field.
- **Zone position** (`setZonePosition`) is LWW on a `FracIndex` — a rational number that places the zone between two neighbors without touching other zones. No array-CRDT is needed; `materialize` sorts zones by `(fracIndex, zoneId)` to break ties.
- **Tile zone membership** (`setTileZone`) is LWW on a register on the tile. The tile carries exactly one `zoneId?`; the op with the highest `OpId` wins. "Tile in at most one zone" is automatic by construction — a tile cannot be in two zones because it has one register, not a membership list.

`compact(log, through lowWaterMark) -> (snapshot, tail)` takes the full log and a globally-acknowledged Lamport low-water mark (a `UInt64` representing the highest Lamport at which every replica has confirmed receipt), folds the ops at or below that mark into a snapshot via `materialize`, and returns the snapshot alongside the tail of ops above the mark. The snapshot is a `Codable` struct with the same fields as today's `CanvasState` and `WorkspaceDocument` plus an embedded `compactionOpId` marking where it was taken. A replica that receives a compacted snapshot replaces its local state up to that mark and appends any tail ops it held above it; this is merge-equivalent to replaying the full log because `materialize` is a pure fold over the same total order.

Viewport (`CanvasViewport`) is excluded from sync per D3's locked decision that viewport is camera state, not document state. The `materialize` function produces a synthetic default viewport (x:0, y:0, zoom:1.0); callers that need the real viewport read it from the local device-only store. `runtimeRef` on `Tile` is similarly excluded — the materialized tile always carries `runtimeRef: nil` and the runtime layer rebinds it locally. These two exclusions are where I5 (sync-boundary purity) is enforced by the implementation, not just by the taint scan.

Both `materialize` and `compact` live in a new target (`ContinuumRevivedSync`) that depends on `ContinuumRevivedCore` for the spatial types but carries the op enum, `OpId`, `LoggedOp`, `FracIndex`, and the tombstone machinery. `ContinuumRevivedCore` itself gains no new dependency.

## Where it lives

**New target: `ContinuumRevivedSync`** — added to `Package.swift` as a new `.target` depending on `ContinuumRevivedCore`, zero external dependencies, pure Swift.

**New executable check target: `ContinuumRevivedSyncChecks`** — added to `Package.swift` as a new `.executableTarget` depending on `ContinuumRevivedSync` (and `ContinuumRevivedCore` for the backend fixture round-trip), matching the existing `ContinuumRevivedCoreChecks` shape so it runs with `swift run ContinuumRevivedSyncChecks` and emits a measured-value manifest.

New files in `ContinuumRevivedSync/`:

- `OpLog.swift` — `materialize(ops: [LoggedOp]) -> MaterializedState`, the `MaterializedState` struct (wrapping the rebuilt `CanvasState` + `WorkspaceDocument`), the per-field LWW accumulator, and tombstone application.
- `Compaction.swift` — `compact(log: [LoggedOp], through lowWaterMark: UInt64) -> CompactionResult`, the `CompactionResult` struct (`snapshot: CompactedSnapshot`, `tail: [LoggedOp]`), and `CompactedSnapshot` (a `Codable` snapshot of `MaterializedState` plus `compactionOpId: OpId`).

Existing seams this work touches — read-only, no modification required in this ticket:

- `Sources/ContinuumRevivedCore/CanvasState.swift:3` — `CanvasState` is the target output type; `Tile` at `:39` (the struct the fold produces, with `runtimeRef` at `:45` always set to nil in the materialized output), `TileGroup` at `:190` (produced by `materialize` from `createGroup`/`setGroupScalar` ops).
- `Sources/ContinuumRevivedCore/CanvasEngine.swift:11` — `CanvasEngine` is a static pure-geometry enum; it is not modified here, but the `materialize` output passes through `CanvasEngine` callers downstream.

The op types (`Op`, `OpId`, `LoggedOp`, `FracIndex`, `TileSeed`, `ZoneSeed`) are defined by the op enum and logged-op envelope ticket and refined by the membership-as-LWW-register, z-order-as-fractional-index, and delete-as-tombstone tickets. This ticket depends on all of them being present and finalized.

## Implementation breadcrumbs

```swift
// ContinuumRevivedSync/OpLog.swift

// State accumulated during the fold — internal to materialize.
private struct FoldState {
    // Tombstones: tile or zone ids for which a deleteTile/deleteZone was seen.
    var tombstonedTiles:  Set<UUID> = []
    var tombstonedZones:  Set<UUID> = []
    // Per-tile field tracking: maps tileId → (winningOpId, partial Tile builder).
    var tiles: [UUID: (opId: OpId, builder: TileBuilder)] = [:]
    // Per-zone field tracking: maps zoneId → (winningOpId, partial ZoneBuilder).
    var zones: [UUID: (opId: OpId, builder: ZoneBuilder)] = [:]
    // Zone z-order: maps zoneId → (winningOpId, FracIndex).
    var zonePositions: [UUID: (opId: OpId, pos: FracIndex)] = [:]
}

// The public entry point.
public func materialize(ops: [LoggedOp]) -> MaterializedState {
    // 1. Sort: primary Lamport ascending, tie-break replicaId ascending.
    let sorted = ops.sorted { $0.opId < $1.opId }

    // 2. Fold.
    var state = FoldState()
    for logged in sorted {
        apply(logged, into: &state)
    }

    // 3. Resolve: drop tombstoned ids, assemble final structs.
    return resolve(state)
}

private func apply(_ logged: LoggedOp, into state: inout FoldState) {
    let opId = logged.opId
    switch logged.op {
    case .createTile(let id, let seed):
        // add-wins: only initialise if not already present (higher-opId create
        // arrived first due to total order? impossible — creates have unique ids;
        // re-delivery guard).
        if state.tiles[id] == nil {
            state.tiles[id] = (opId, TileBuilder(seed: seed))
        }

    case .deleteTile(let id):
        state.tombstonedTiles.insert(id)
        // delete-wins: do NOT remove the builder; resolve() will skip tombstoned ids.
        // This ensures a concurrent setTileFrame with higher lamport cannot
        // resurrect the tile — tombstone is checked in resolve(), not here.

    case .setTileFrame(let id, let frame):
        updateTileField(id: id, opId: opId, into: &state) { builder, _ in
            builder.frame = frame
        }

    case .setTileZone(let tile, let zone):
        // LWW on the tile's zone register. Last writer wins.
        updateTileField(id: tile, opId: opId, into: &state) { builder, _ in
            builder.zoneId = zone
        }

    case .setZonePosition(let id, let pos):
        // LWW on the zone's FracIndex position register.
        if let existing = state.zonePositions[id] {
            if opId > existing.opId {
                state.zonePositions[id] = (opId, pos)
            }
        } else {
            state.zonePositions[id] = (opId, pos)
        }

    // … remaining cases (createZone, deleteZone, setZoneOrigin, setZoneSize,
    //   setTileScalar, setZoneScalar) follow the same LWW / tombstone pattern.
    }
}

private func resolve(_ state: FoldState) -> MaterializedState {
    // Tiles: drop tombstoned ids; assemble Tile structs from builders.
    let liveTiles = state.tiles
        .filter { !state.tombstonedTiles.contains($0.key) }
        .map { (_, entry) in entry.builder.build() }  // build() sets runtimeRef = nil

    // Zones: drop tombstoned; sort by (fracIndex, zoneId) for stable z-order.
    let liveZones = state.zones
        .filter { !state.tombstonedZones.contains($0.key) }
        .map { (id, entry) -> (ZoneBuilder, FracIndex) in
            let pos = state.zonePositions[id]?.pos ?? FracIndex.default
            return (entry.builder, pos)
        }
        .sorted { a, b in
            a.1 == b.1
                ? a.0.id.uuidString < b.0.id.uuidString
                : a.1 < b.1
        }
        .map { $0.0.build() }

    // Viewport is always the local-device default — never synced.
    let viewport = CanvasViewport(x: 0, y: 0, zoom: 1.0)

    return MaterializedState(
        canvasState: CanvasState(
            schemaVersion: CanvasState.currentSchemaVersion,
            viewport: viewport,
            tiles: liveTiles,
            groups: [],          // groups derived from tile.groupId register (membership-as-LWW-register ticket)
            lastActiveTileId: nil
        ),
        workspaceDocument: WorkspaceDocument( /* zones assembled here */ )
    )
}
```

```swift
// ContinuumRevivedSync/Compaction.swift

public struct CompactionResult: Codable, Sendable {
    public var snapshot: CompactedSnapshot
    public var tail:     [LoggedOp]
}

public struct CompactedSnapshot: Codable, Sendable {
    public var compactionOpId: OpId          // highest OpId folded into this snapshot
    public var state:          MaterializedState
}

public func compact(log: [LoggedOp], through lowWaterMark: UInt64) -> CompactionResult {
    let below = log.filter { $0.opId.lamport <= lowWaterMark }
    let tail  = log.filter { $0.opId.lamport >  lowWaterMark }

    // The highest opId in `below` is the compaction marker.
    let topOpId = below.max(by: { $0.opId < $1.opId })?.opId
        ?? OpId(lamport: 0, replica: .init())  // empty log edge case

    let snapshot = CompactedSnapshot(
        compactionOpId: topOpId,
        state: materialize(ops: below)
    )
    return CompactionResult(snapshot: snapshot, tail: tail)
}

// Merging a received snapshot into a replica:
public func applySnapshot(
    _ snapshot: CompactedSnapshot,
    ontop localLog: [LoggedOp]
) -> [LoggedOp] {
    // Drop any local ops at or below the snapshot's compactionOpId —
    // they are already folded into the snapshot — and keep only the tail.
    let localTail = localLog.filter { $0.opId > snapshot.compactionOpId }
    // The replica's new effective log is: "start from snapshot.state, then replay localTail."
    // Return localTail; the caller stores (snapshot, localTail) and calls
    // materialize(ops: localTail) layered atop snapshot.state.
    return localTail
}
```

**Canonical encoding for byte-identity (I4).** `MaterializedState` must encode to the same bytes on every replica for the fuzz assertion to hold. Use `JSONEncoder` with `.sortedKeys` output formatting and a fixed `dateEncodingStrategy` (ISO8601). Tiles and zones within the resolved arrays must be sorted by id (UUID string ascending) before encoding — the `resolve()` function returns them in a deterministic order; the encoder must not assume insertion order. Document this encoding contract in a comment on `MaterializedState` so it is never accidentally broken.

## How we test it

### Logic

The check target is `ContinuumRevivedSyncChecks` — a new executable check target (same shape as the existing `ContinuumRevivedCoreChecks`, run with `swift run`) that depends on `ContinuumRevivedSync` and drives `materialize` and `compact` directly with no network, no file system, no clock.

**LWW correctness.** Given two ops with the same tile id and the same field (`setTileFrame`), one with a lower `OpId` and one with a higher, assert that the higher wins regardless of the order the ops are fed to `materialize`. Feed them in both orders. Assert the resulting `Tile.frame` matches the higher-Lamport version. Run this for every scalar field variant.

**Tombstone wins over concurrent write.** Create a tile, then produce a `deleteTile` op with a lower Lamport than a concurrent `setTileFrame` op (so the frame op sorts after the delete in the total order). Assert `materialize` produces no tile with that id. Feed the ops in all permutations (2 ops = 2! = 2 orderings; 3 ops counting the create = 6). Assert all produce the same result with no tile present.

**Tile-zone register convergence.** Model two replicas: replica A emits `setTileZone(tile: T, zone: X)` with Lamport 5, replica B emits `setTileZone(tile: T, zone: Y)` with Lamport 6. Merge both ops (delivering in either order). Assert the materialized tile's `zoneId` equals Y (higher Lamport wins). Assert T does not appear in zone X's derived member list. Assert T appears in zone Y's derived member list. No tile appears in two zones simultaneously.

**Zone position sort stability.** Produce three zones with `FracIndex` values 0.25, 0.5, 0.75. Apply concurrent `setZonePosition` ops from two replicas for the middle zone — replica A sets it to 0.6, replica B sets it to 0.3 (B has a higher Lamport). Assert the final order is zones at 0.25, 0.3, 0.75 with no duplicates. Swap delivery order; assert identical result.

**Compaction round-trip.** Build a log of 50 random legal ops across 3 replicas. Compact at lowWaterMark = 30. Assert `materialize(snapshot.state ops + tail)` equals `materialize(full log)` on canonical encoding. Then deliver the tail ops individually to a fresh replica that only has the snapshot; assert it reaches the same state.

**I7 snapshot round-trip.** Serialize a `CompactedSnapshot` to JSON and deserialize it. Assert the deserialized value equals the original under `==` and that re-materializing from it produces the same output.

### Backend

The backend check exercises `materialize` against a real `ProjectStore`/`WorkspaceStore` round-trip on disk — not a tmux daemon, not a cloud transport. This proves the output of `materialize` is valid input to the existing persistence layer.

Load the real `canvas.json` fixture from a test project (committed to the repo as a fixture file under `ContinuumRevivedSyncChecks/Fixtures/canvas.json`). Derive a set of `LoggedOp` values that, when materialized, reproduce the fixture's tile and zone state (this is a one-time manual derivation; commit it alongside the fixture as `Fixtures/baseline_ops.json`). Run `materialize(ops: baseline_ops)` and assert the resulting `CanvasState` encodes identically to the fixture (minus viewport and runtimeRef, which are excluded). This proves the op-log round-trip is faithful to the existing on-disk format.

Then append a `createTile` op and a `setTileFrame` op and call the real `ProjectStore.saveCanvas` with the materialized result. Assert the saved file round-trips through `ProjectStore.loadCanvas` and produces the same `CanvasState`. This uses the real `AtomicWriter` at `Sources/ContinuumRevivedCore/AtomicWriter.swift` and the real file system — not a mock.

### UX (dogfood snippet)

This ticket has no on-canvas surface; it is a pure-logic layer, so the human-observable result is not a rendered frame but the **baseline budget numbers** the check manifest records — the op count, the canonical snapshot byte count, and the `materialize` latency. Those numbers are the thing a human reads to confirm the engine works and to lock the budget the later convergence soak compares against. `ContinuumRevivedSyncChecks` is a runnable executable check target (same shape as the existing `ContinuumRevivedCoreChecks` / `ContinuumRevivedPerfChecks` targets, which are run with `swift run`), so making this observable is one command — no transport, no session topology, no device.

**Dogfood snippet.** From the repo root, run the sync check target:

```
swift run ContinuumRevivedSyncChecks
```

Among its manifest output, expect it to print exactly three labelled measured-value lines derived from the compaction round-trip check (the 50-op / 3-replica log compacted at `lowWaterMark = 30`) and the canonical encoding of the compacted snapshot — for example:

```
oplog.compaction.opsProcessed      = 50
oplog.snapshot.canonicalBytes      = 4187
oplog.materialize.maxLatencyMicros = 812
```

Observe: `opsProcessed` equals the size of the log fed to the compaction check (50); `canonicalBytes` is a stable non-zero integer that does not change between two consecutive runs of the same fixture (byte-identity — run the command twice and confirm the same number both times); `maxLatencyMicros` is a small positive integer (order of hundreds to low thousands of microseconds on a laptop, never `0`, never a placeholder). A run that prints `opsProcessed = 0`, a `canonicalBytes` that differs between two identical runs, or `{passed:true}` instead of numbers is a failure. This is the same measured-values contract the check manifest carries; running the target is the human-facing window onto it, and these three numbers are the observable baseline every later sync ticket's soak is compared against.

## Execution mode

**Autonomous.** Every check in this ticket is a pure in-process Swift function call — no tmux, no CloudKit, no iOS device, no visual gate. `materialize` and `compact` are deterministic pure functions whose correctness is fully verifiable by the logic checks and the backend round-trip against a committed fixture. The check manifest carries measured values (not `{passed:true}`), and a number either equals the expected canonical encoding or it does not — no human eye is needed to adjudicate it. The dogfood snippet (`swift run ContinuumRevivedSyncChecks`) is the human-facing window onto those same measured values, not a separate visual judgement, so an overnight coder can run this ticket to completion without human involvement while the owner can still eyeball the baseline numbers on demand.

## Done when

- [ ] `ContinuumRevivedSync` is a new Swift package target in `Package.swift`, depending on `ContinuumRevivedCore`, with zero external dependencies, and builds cleanly under Swift 6.0 strict concurrency.
- [ ] `materialize(ops:)` accepts `[LoggedOp]` in any order and returns a `MaterializedState` whose canonical JSON encoding is byte-identical given the same multiset of ops, verified by the LWW and tombstone checks above feeding ops in all permutations.
- [ ] `materialize` always sets `runtimeRef = nil` on every tile and uses the default viewport — confirmed by the logic check asserting those fields on every materialized output.
- [ ] `compact(log:through:)` produces a `CompactionResult` whose snapshot plus tail, when re-materialized, produces the same canonical JSON as materializing the full log — confirmed by the compaction round-trip check.
- [ ] `applySnapshot(_:ontop:)` correctly drops local ops at or below the compaction mark and returns only the surviving tail — confirmed by the logic check delivering a snapshot then appending tail ops and asserting final state equality.
- [ ] The backend check loads the committed `canvas.json` fixture, runs `materialize` over the baseline ops, and saves through the real `ProjectStore.saveCanvas`/`loadCanvas` round-trip without error.
- [ ] `ContinuumRevivedSyncChecks` is a new `.executableTarget` in `Package.swift` and runs via `swift run ContinuumRevivedSyncChecks`.
- [ ] The check manifest records measured values: op count, canonical JSON byte count, and `materialize` latency in microseconds — never `{passed:true}`.
- [ ] Running the dogfood command `swift run ContinuumRevivedSyncChecks` prints the three labelled measured-value lines (`oplog.compaction.opsProcessed`, `oplog.snapshot.canonicalBytes`, `oplog.materialize.maxLatencyMicros`); `opsProcessed = 50`, `canonicalBytes` is identical across two consecutive runs, and `maxLatencyMicros` is a small non-zero integer.
- [ ] No code in `ContinuumRevivedCore` was modified by this ticket (confirmed by a clean `git diff Sources/ContinuumRevivedCore`).

## Depends on / unblocks

This ticket depends on the op enum and logged-op envelope ticket providing `Op`, `OpId`, `LoggedOp`, and `FracIndex` as finalized types. It depends on the membership-as-LWW-register ticket having moved zone membership from `TileGroup.tileIds` to a register on `Tile`, so `materialize` can reconstruct membership from `setTileZone` ops rather than array-mutation ops. It depends on the z-order-as-fractional-index ticket so that `setZonePosition` ops carry a `FracIndex` that `materialize` can sort. It depends on the delete-as-tombstone ticket having defined the delete-wins policy and the tombstone type, so `materialize` can apply it without ambiguity.

This ticket directly unblocks the convergence fuzz ticket, which is the safety gate before any transport code — the fuzz needs a real `materialize` to drive, and it cannot be written meaningfully against a stub. It also unblocks the sync/observation type split ticket, which references `materialize` as the projection that produces the synced spatial snapshot. All subsequent phase tickets that touch spatial state (the CloudKit transport, the activity projection, the iOS observer) rest on the guarantee this ticket establishes.

## Watch out for

**Tombstone ordering is the most dangerous subtlety.** The natural instinct when implementing `apply` is to remove a tile from the builder map when a `deleteTile` op arrives. Do not do this. If the log contains a `setTileFrame` op with a higher Lamport than the `deleteTile` — entirely possible when two replicas acted concurrently and the ops are delivered interleaved — the field update will try to write to a builder that no longer exists and either silently create a ghost tile or crash. The correct implementation adds to the tombstone set in `apply` and only drops the tile in `resolve`, after the full fold is complete. The test that exercises this permutation (tombstone with a higher-Lamport concurrent write, ops delivered in both orders) is the most important single check in the suite. Run it first.

**Canonical encoding must be documented and locked.** The I4 fuzz asserts byte-identical output; that assertion is only meaningful if the encoding is canonical — sorted keys, sorted tile/zone arrays, fixed number formatting. If a future contributor changes `MaterializedState` and forgets to sort the arrays before encoding, the fuzz will produce false positives (both replicas encode non-identically but the check passes because both happen to produce the same non-canonical order). Lock the encoding contract in a comment on `MaterializedState` and a dedicated I7 round-trip check.

**`FracIndex` tie-breaking must be deterministic.** If two zones land on the same fractional position (possible if two replicas concurrently set a zone to the "between A and B" midpoint), the sort in `resolve` must break the tie by `zoneId` (UUID string comparison), not by insertion order or any other unstable key. An unstable tie-break is a silent divergence: both replicas produce different zone orderings from identical op logs, and the I4 fuzz catches it but only if the scenario is in the fuzz.

**`applySnapshot` is not a free merge.** The function that receives a compacted snapshot from a remote replica is not a blind replace — it must drop local ops that are already folded into the snapshot (at or below `compactionOpId`) while keeping local ops that postdate it. Getting the comparison wrong by one (using `<` instead of `<=`) leaves a duplicate op in the tail that, when materialized, may or may not produce a visible error depending on whether it is idempotent for that op type. Createswith-existing-id are idempotent; LWW field sets are also idempotent; but the risk is subtle enough that the compaction round-trip check should explicitly verify the boundary op (the op with `lamport == lowWaterMark`) is not present in the tail.

**Stop if `ContinuumRevivedCore` requires modification.** The entire point of the new `ContinuumRevivedSync` target is to keep the core dependency-free and unmodified. If, during implementation, you find that `materialize` requires adding a method or changing a type in `CanvasState.swift` or any other file under `Sources/ContinuumRevivedCore/`, stop and raise it as a design issue rather than making the change. The correct answer is almost always to add a new type in the sync target that wraps or computes from the core type, not to modify the core.

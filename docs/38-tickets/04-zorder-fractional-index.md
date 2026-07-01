# Z-order as a fractional index

## What this delivers

Today, both tile stacking order and zone front-to-back order are stored as mutable integers — `Tile.zIndex: Int` in `CanvasState` and `zoneZOrder: [UUID]` (an ordered array of references) in `WorkspaceDocument`. Both break under concurrent reorders from two devices: two "bring to front" operations racing on separate replicas can land on the same integer, and concurrent moves within the ordered array can drop or duplicate entries. Neither representation can be made convergent without abandoning the `Int`/array model entirely.

This ticket replaces both with a **fractional index stored as a property of the item**, so a reorder becomes a last-write-wins register update rather than an array mutation. After this lands, the op-log can express a "reorder" as a single `setTileZIndex` or `setZonePosition` operation — a self-contained, convergent field set — and the `materialize` function sorts by that scalar rather than trusting the order of an array. No concurrent reorder can ever produce a duplicate or a missing entry, because position is owned by the thing being positioned, not by a shared slot structure.

The external behavior of the canvas is unchanged: tiles still stack, zones still layer, "bring to front" still works. The change is entirely in how the order is represented and how it survives sync.

## How it fits

This ticket sits squarely in Phase 0 — Foundations. It depends directly on the op enum and the logged-op envelope established in the op enum ticket: the two new ops introduced here (`setTileZIndex(id:z:FracIndex)` and `setZonePosition(id:z:FracIndex)`) are cases in that enum, and the `FracIndex` type is what the op carries as its payload. The store-protocol seam ticket must exist for the migration path at the end to have somewhere clean to land, but the core type work can proceed in parallel with it.

This ticket unblocks the op-log apply and compaction ticket, which needs every spatial field — including z-order — expressed as an op before it can implement `materialize`. It also unblocks the convergence fuzz: the fuzz must be able to generate concurrent reorder ops and assert byte-identical materialized state, which requires this ticket's representation to be in place first. Nothing in Phase 1 or later can proceed with confidence in sync correctness while z-order remains an `Int` + a shared mutable array.

## The approach

Z-order for tiles and zones is unified under one type, `FracIndex`, which represents a position as a `Double` in the open interval (0, 1). The choice of `Double` over a rational fraction is deliberate: IEEE 754 doubles have enough precision for thousands of "halving" operations before any two items become indistinguishable, and the representation is natively `Codable`, natively comparable, and zero-dependency. For a canvas with tens to low hundreds of tiles and zones — the real concurrency profile here — doubles never exhaust their precision.

The fractional-index arithmetic follows one rule: the position of an item inserted or moved between two neighbors is the arithmetic mean of those neighbors' positions. Items at the extreme ends use 0.0 and 1.0 as the virtual boundary sentinels (never stored; just the boundaries of the open interval). A "bring to front" becomes `mean(currentMax, 1.0)`. A "send to back" becomes `mean(0.0, currentMin)`. Inserting between A and B becomes `mean(A.pos, B.pos)`. When two items land on identical positions — the only true tie — the tie breaks deterministically by `zoneId` or `tileId` lexicographic order, making sort order a pure function of the stored values.

The `zoneZOrder: [UUID]` array in `WorkspaceDocument` is kept for backward compatibility with the persisted `canvas.json` format during migration, but it is immediately deprecated: it is decoded on load, converted to `FracIndex` values for each zone, and never written back to disk. After migration, the encoder omits it; the decoder treats its absence as "no legacy order to migrate." `Tile.zIndex: Int` undergoes the same treatment: the existing integer is decoded, converted to a `FracIndex` by distributing the integer ranks evenly across the open interval, and the integer field is replaced by `zPosition: FracIndex` on `Tile`. All existing callers of `CanvasEngine.bringToFront` and `renormalizeZOrder` are updated to use the new fractional operations. The `CanvasEngine` static functions that sort by `zIndex` are updated to sort by `zPosition`.

No new external dependencies are introduced. The entire implementation is pure Swift within `ContinuumRevivedCore`.

## Where it lives

**Primary seams:**

- `Sources/ContinuumRevivedCore/CanvasState.swift` — `Tile` struct at line 39; the `zIndex: Int` field at line 44 is replaced by `zPosition: FracIndex`. The `Tile` initializer at line 48 gains a `zPosition` parameter. The `Codable` conformance for `Tile` (inferred) must be audited so the migration decoder reads the old `zIndex` key and writes the new `zPosition` key.

- `Sources/ContinuumRevivedCore/WorkspaceDocument.swift` — `WorkspaceDocument` struct at line 13; `zoneZOrder: [UUID]` at line 19 is deprecated. `ZonePlacement` at line 147 gains `zPosition: FracIndex`. The custom `Codable` impl at lines 121–144 is updated to decode legacy `zoneZOrder` and distribute positions, omit `zoneZOrder` on encode, and round-trip `ZonePlacement.zPosition`.

- `Sources/ContinuumRevivedCore/CanvasEngine.swift` — `bringToFront(tileId:in:)` at line 603, `renormalizeZOrder(_:)` at line 614, the sort expressions at lines 223, 235, and the `NavigationItem.zIndex: Int` field at line 440 and line 477 — all updated to use `FracIndex`.

**New type — `FracIndex`:**

A new file `Sources/ContinuumRevivedCore/FracIndex.swift` holds the type and its arithmetic. Keep it in `ContinuumRevivedCore` (not a separate module) so it is available to the op enum, the engine, and the store without any cross-target import.

**Op enum additions** (in whichever file the op enum ticket created for the op type):

```
case setTileZIndex(id: UUID, z: FracIndex)
case setZonePosition(id: UUID, z: FracIndex)
```

## Implementation breadcrumbs

### FracIndex.swift

```swift
/// A position in the open interval (0, 1) used for convergent z-ordering.
/// Two items with identical positions are broken by a secondary key (UUID).
public struct FracIndex: Codable, Comparable, Equatable, Hashable, Sendable {
    public let value: Double  // always in (0, 1) exclusive

    /// Validates the range on decode; rejects values outside (0,1).
    public init(value: Double) {
        precondition(value > 0 && value < 1, "FracIndex must be in (0, 1)")
        self.value = value
    }

    /// The position halfway between two neighbors.
    /// `lower` and `upper` are virtual sentinels (0.0, 1.0) or real positions.
    public static func between(_ lower: Double, _ upper: Double) -> FracIndex {
        FracIndex(value: (lower + upper) / 2.0)
    }

    /// Distribute n items evenly across (0, 1), preserving rank order.
    /// Used during migration from integer z-indices.
    public static func distribute(count: Int) -> [FracIndex] {
        guard count > 0 else { return [] }
        let step = 1.0 / Double(count + 1)
        return (1...count).map { FracIndex(value: step * Double($0)) }
    }

    public static func < (lhs: FracIndex, rhs: FracIndex) -> Bool {
        lhs.value < rhs.value
    }
}
```

### Tile migration in CanvasState

The decoder for `Tile` reads the legacy `zIndex` key if `zPosition` is absent, converting by rank:

```swift
// In Tile's manual Codable init (add it):
if let legacyZ = try container.decodeIfPresent(Int.self, forKey: .zIndex) {
    // Deferred: rank-based distribution happens at CanvasState level after all tiles decoded.
    self.zPosition = FracIndex(value: 0.5)  // placeholder; see CanvasState migration below
    self._legacyZIndex = legacyZ
} else {
    self.zPosition = try container.decode(FracIndex.self, forKey: .zPosition)
}
```

At `CanvasState` decode time, after all tiles are in hand:

```swift
let needsMigration = tiles.contains { $0._legacyZIndex != nil }
if needsMigration {
    let sorted = tiles.sorted { ($0._legacyZIndex ?? 0) < ($1._legacyZIndex ?? 0) }
    let positions = FracIndex.distribute(count: sorted.count)
    tiles = zip(sorted, positions).map { (tile, pos) in
        var t = tile; t.zPosition = pos; return t
    }
}
```

### WorkspaceDocument migration for zoneZOrder

```swift
// In WorkspaceDocument.init(from:):
let legacyOrder = try container.decodeIfPresent([UUID].self, forKey: .zoneZOrder) ?? []
var zones = try container.decode([ZonePlacement].self, forKey: .zones)
if !legacyOrder.isEmpty {
    let positions = FracIndex.distribute(count: legacyOrder.count)
    let rankMap: [UUID: FracIndex] = Dictionary(
        uniqueKeysWithValues: zip(legacyOrder, positions)
    )
    zones = zones.map { z in
        var updated = z
        updated.zPosition = rankMap[z.zoneId] ?? FracIndex(value: 0.5)
        return updated
    }
}
self.zones = zones
// zoneZOrder is NOT stored; encode(_:) omits it.
```

### CanvasEngine — updated bringToFront

```swift
public static func bringToFront(tileId: UUID, in tiles: [Tile]) -> [Tile] {
    let maxPos = tiles.map(\.zPosition.value).max() ?? 0.5
    return tiles.map { tile in
        guard tile.id == tileId else { return tile }
        var promoted = tile
        promoted.zPosition = FracIndex.between(maxPos, 1.0)
        return promoted
    }
}
```

The old `renormalizeZOrder` is removed entirely — no renormalization is ever needed, because fractional positions don't have an integer-overflow problem.

### Sort expressions (CanvasEngine hit-test and NavigationItem)

Anywhere `sorted { $0.zIndex > $1.zIndex }` appears, replace with:

```swift
.sorted { lhs, rhs in
    if lhs.zPosition != rhs.zPosition { return lhs.zPosition > rhs.zPosition }
    return lhs.id.uuidString > rhs.id.uuidString  // deterministic tie-break
}
```

`CanvasEngine.NavigationItem.zIndex: Int` becomes `zPosition: FracIndex`; the sort at line 522 of CanvasEngine.swift updates accordingly.

### Op application in materialize

When `materialize(ops:)` processes a `setTileZIndex` op:

```swift
case .setTileZIndex(let id, let z):
    if var tile = state.tiles[id], !state.tombstones.contains(id) {
        tile.zPosition = z
        state.tiles[id] = tile
    }
```

The final sorted render order is derived from `zPosition` alone, never from op arrival order.

## How we test it

### Logic (pure Core checks)

**Round-trip identity.** Encode a `CanvasState` with five tiles at known `FracIndex` values, decode it, assert each tile's `zPosition` is identical to the original (to bit-level equality, not epsilon comparison).

**Migration correctness.** Build a legacy `CanvasState` JSON blob with `zIndex` integers `[3, 1, 99, 2]`. Decode it. Assert the resulting `zPosition` values are strictly increasing in the same rank order as the integers, and that all values fall strictly within (0, 1). Repeat for `WorkspaceDocument` with a legacy `zoneZOrder` array.

**FracIndex arithmetic invariants.** For any pair `(a, b)` with `a.value < b.value`, assert that `FracIndex.between(a.value, b.value)` satisfies `a < result && result < b`. Assert `distribute(count: n)` produces `n` strictly increasing values all in (0, 1). Assert that 1,000 successive `between(currentMax, 1.0)` calls (simulating 1,000 "bring to front" ops) never produce a value outside (0, 1) and each is strictly greater than the previous.

**Tie-break determinism.** Create two tiles with identical `FracIndex` values. Assert that sorting them by `(zPosition, id.uuidString)` produces the same order on every call and that the order is the reverse for two tiles with IDs swapped.

**Op-log convergence sub-case.** Build two replicas, each applying three concurrent `setTileZIndex` ops in opposite orders. Call `materialize` on each log independently. Assert byte-identical `CanvasState` output (this is the I4 fuzz sub-case specific to z-order, run before the full multi-field fuzz lands in the convergence fuzz ticket).

### Backend (real-path / integration)

**Store round-trip with real files.** Using `ProjectStore` against a real temporary directory (not a mock), save a `CanvasState` containing tiles with `FracIndex` positions, then load it back. Assert the loaded state equals the saved state under `Equatable`. Assert the on-disk JSON contains the key `"zPosition"` and does not contain `"zIndex"`.

**Legacy file migration.** Write a hand-crafted `canvas.json` file to disk containing the old `"zIndex"` integer key on each tile (and `"zoneZOrder"` array in the workspace document). Load it through `ProjectStore`. Assert the loaded state contains valid `FracIndex` values in the correct rank order. Assert that a subsequent save produces a file with no `"zIndex"` or `"zoneZOrder"` keys.

**`bringToFront` through the real canvas mutation path.** Using `CanvasEngine.bringToFront`, promote a tile, then call `CanvasEngine.renormalizeZOrder` — assert this function no longer exists and the call site has been removed. Verify the promoted tile's `zPosition` is strictly greater than all other tiles' positions without any renormalization step.

### UX (visual gate + dogfood snippet)

The visual gate lives in the Component Lab. Seed the lab canvas with six overlapping note tiles at known fractional positions. Render the canvas. Capture a snapshot. Assert that the tile with the highest `zPosition` value is the topmost rendered subview in AppKit's layer order — check `canvasNSView.subviews.last` (or the last tile subview before the overlay) matches the expected tile's `id`. This is a non-degenerate visual gate: it tests rendered subview order, not just a stored value.

**Dogfood snippet.** Open the app. Create three note tiles so they overlap at the center of the canvas. Click on the bottommost tile to focus it. Observe: the tile moves to the front (it becomes the topmost rendered tile, covering the others). Open the Component Lab (Cmd-Opt-L), switch to the Affordance Inspector. Confirm the tile's `zPosition` reads as a decimal in the range (0, 1) — specifically a value greater than 0.5 — in the inspector's live metrics panel. Drag one of the other tiles on top of the front tile, then click the buried tile. Confirm it again jumps to front and the inspector updates its `zPosition` to a new value greater than the previous maximum.

## Execution mode

Autonomous. Every check in this ticket runs fully in-process: the logic checks need no UI and no daemon, the backend checks use a real temporary directory on disk (no cloud, no device, no human observer), and the visual gate uses AppKit snapshot comparison within the Component Lab check harness. There is no UX judgment that requires a human eye — the visual gate asserts subview order, which is binary pass/fail. The dogfood snippet is included for developer confidence but the gate itself does not require it to pass CI.

## Done when

- [ ] `FracIndex` type exists in `ContinuumRevivedCore`, is `Codable`, `Comparable`, `Equatable`, `Hashable`, and `Sendable`, and its `between` and `distribute` static functions satisfy all logic checks above.
- [ ] `Tile.zIndex: Int` is removed; `Tile.zPosition: FracIndex` takes its place. The type compiles with no references to the old field outside migration code.
- [ ] `ZonePlacement.zPosition: FracIndex` exists; `WorkspaceDocument.zoneZOrder: [UUID]` is omitted from the encoder and treated as a legacy migration key in the decoder.
- [ ] `CanvasEngine.bringToFront` operates on `FracIndex`. `CanvasEngine.renormalizeZOrder` is deleted. All sort expressions over tile z-order use `(zPosition, id)` as the sort key.
- [ ] All callers of `bringToFront` — in `CanvasNSView`, `TileNSView`, `TileSpawner`, `ContinuumApp`, and the individual tile NSView subclasses — compile without error.
- [ ] `ComponentLab.nextZ()` (line 252) is removed; new tile spawns in the lab receive a `FracIndex` computed via `FracIndex.between(currentMax, 1.0)`.
- [ ] Legacy `canvas.json` files (with `zIndex` integer fields and `zoneZOrder` arrays) load correctly and produce a valid, sorted `CanvasState` / `WorkspaceDocument`. A save-then-load cycle on a migrated document produces no `zIndex` or `zoneZOrder` keys in the output file.
- [ ] All logic checks pass with measured values in the manifest (round-trip identity, migration correctness, arithmetic invariants, tie-break determinism, convergence sub-case). No check records `{passed: true}` without a measured value.
- [ ] Backend store round-trip and legacy migration checks pass against real temporary directories.
- [ ] Visual gate passes: the highest-`zPosition` tile is the topmost AppKit subview in the Component Lab snapshot.
- [ ] The op enum for `setTileZIndex` and `setZonePosition` exists and carries `FracIndex` payloads.

## Depends on / unblocks

This ticket requires the op enum and logged-op envelope to be in place, because the two new op cases (`setTileZIndex`, `setZonePosition`) must be added to that enum. It also assumes the store-protocol seam has defined the file-system write path clearly enough that the migration's "save then load" cycle has a stable target. It does not require the op-log apply and compaction ticket, the convergence fuzz, or any runtime infrastructure — those come after.

It directly unblocks op-log apply and compaction (which must be able to fold `setTileZIndex` and `setZonePosition` ops into materialized state) and the convergence fuzz (which must be able to generate concurrent z-order ops and assert convergence). It also unblocks any future ticket that reads or renders zone or tile stacking order, since the representation change is a prerequisite for correctness there.

## Watch out for

**The precision cliff.** Repeated halvings — each "bring to front" takes the mean of the current maximum and 1.0 — converge toward 1.0 geometrically. After roughly 52 successive bring-to-fronts without any other tile coming to front in between, the `Double` precision is exhausted and two positions become bit-identical. This does not cause a crash; the tie-break on `id` resolves it. But the logic check for 1,000 successive bring-to-fronts must confirm that the values remain distinct for at least the first 50, and must assert that even after exhaustion the sort is still total (the tie-break fires, not an assertion failure). If this becomes a real user-facing problem, a "rebalance" operation (redistributing all positions evenly via `FracIndex.distribute`) can be triggered lazily — but do not implement it speculatively.

**Migration is one-way and irreversible.** Once a `canvas.json` is saved with `zPosition` fields and without `zoneZOrder`, an older build of the app that does not know about `FracIndex` will fail to decode `Tile`. The migration must be gated by the schema version bump in `WorkspaceDocument.currentSchemaVersion` (currently `2` at `WorkspaceDocument.swift:14`). Bump to `3`, validate the version in `validateSchema(at:)` as it already does, and test the "future schema" error path.

**ComponentLab hardcoded `zIndex: 1` literals.** There are several sites in `ComponentLab.swift` (lines 61, 282, 287, 294, 299, 304) and in `ZoneRuntimeController.swift` (lines 332, 447) where `zIndex: 1` is passed to the `Tile` initializer. These must all be updated to pass a computed `FracIndex`. The simplest replacement is `FracIndex.between(0.0, 1.0)` (which yields `0.5`) for static fixtures, and the existing `nextZ()` pattern replaced with a `nextZPosition()` helper that does `FracIndex.between(currentMax, 1.0)`. Missing even one of these sites will cause a compile error, which is the correct failure mode — the type change is self-enforcing.

**The `CanvasEngine.NavigationItem` internal type.** This struct at line 440 has its own `zIndex: Int` field used in the navigation overlay sort at line 522. It is internal to the engine but participates in the same sort logic. Update it in the same commit; leaving it as `Int` while `Tile.zPosition` is `FracIndex` would require a conversion on every hit-test, which is an unnecessary seam for future confusion.

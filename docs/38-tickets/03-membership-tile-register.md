# Membership as a tile-level last-write-wins register

## What this delivers

Today, group-zone membership for ambient tiles lives in `WorkspaceDocument.groupZoneTiles` — a
list of `GroupZoneTiles` structs, each pairing a zone id with a full copy of the tiles it owns
(`WorkspaceDocument.swift:3–11`, `WorkspaceDocument.swift:21`). This structure has two problems
that the op-log sync model cannot live with. First, "which zone owns tile T" is stored in N
different places simultaneously (once per zone that might claim it), making the "a tile belongs to
at most one zone" invariant a constraint you must enforce manually on every write rather than a
property that falls out of the model. Second, the only production write path is a clear
(`setTiles([], forZone:)` in `persistClosedZone`, `ContinuumApp.swift:6334`); there is no
real drag-to-assign path that populates the list, which means the zone's session ownership story
from the session-topology work cannot depend on this write path without building it from scratch.

This ticket re-models group-zone membership as a **last-write-wins register on the tile itself**:
a single nullable `zoneId: UUID?` field on `Tile`. A tile is in exactly one zone (non-nil) or in
no zone (nil, meaning ambient). Concurrent `setTileZone` ops on the same tile converge
automatically to the one with the highest `OpId` — the "a tile is in at most one zone" invariant
is a logical consequence of the type, not a post-merge repair.

**The one structural fact that shapes everything below, stated up front so there is nothing to
guess.** Ambient/group-zone tiles (`ZonePlacement.projectId == nil`, `WorkspaceDocument.swift:104`)
have **no project `CanvasState`**. That is the entire reason `groupZoneTiles` is an *embedded
full-`Tile` list on `WorkspaceDocument`* rather than a filter over some canvas: there is no
ambient/workspace-level `CanvasState` store, and there never was. `WorkspaceStore` persists the
`WorkspaceDocument` alone at `workspaces/<wsId>/canvas.json` (`WorkspaceStore.swift:20`, `:55–63`);
`ProjectStore.loadCanvas()` is strictly per-project (`ProjectStore.swift:112`). So a group-zone
tile's `Tile` record physically lives **inside `WorkspaceDocument`, nowhere else**.

Therefore this ticket does **not** try to put ambient tiles into a canvas that does not exist.
Instead it **re-homes the embedded tiles onto a flat `ambientTiles: [Tile]` list on
`WorkspaceDocument`** and moves membership onto the `zoneId` register carried by each of those
tiles. `groupZoneTiles` (the old grouped-by-zone shape) is deleted; `tiles(forZone:)` becomes a
filter over `ambientTiles` where `tile.zoneId == zone`. The same `Tile.zoneId` field also exists on
project-canvas tiles (in `CanvasState.tiles`), so the op-log's `setTileZone` fold writes one field
name regardless of which store a tile lives in — but the *migration and write path this ticket
delivers touches only `WorkspaceDocument.ambientTiles`, self-contained within one store, no
cross-store join.*

The outcome visible to the system: when the op-log applies a `setTileZone` op to an ambient tile,
the resulting materialized state has exactly one zone per tile, no repair loop needed, and the I4
convergence fuzz can prove it byte-identically across any replica order. The TOPOLOGY spike's
per-workspace ambient session (option a, D15) becomes unblocked, because it no longer depends on a
write path that was clear-only — `ambientTiles` is a real, populated, per-workspace membership
store.

## How it fits

This work sits squarely in Phase 0 (foundations). It depends on the op enum and logged-op
envelope that name `setTileZone` as a first-class op case (D3), and on `Tile.id: UUID` as the
stable key that makes the register possible. It does not depend on any Phase 1 tmux work, so it can
proceed in parallel with or immediately after the op-log core.

What it unblocks is significant. The op-log apply and compaction work needs every hard convergence
case resolved before it can implement the fold; membership was explicitly identified as the hardest
of the three (alongside move-vs-delete tombstones and fractional z-order — `SYNC-MODEL.md`, "Hard
case #3"). The convergence fuzz, which must go RED→GREEN before any transport code is committed,
cannot run until `setTileZone` folds correctly. And the per-workspace ambient session work in
Phase 1 (D15) is listed as conditional on confirming a membership signal; this ticket provides that
signal by giving `ambientTiles` a real write path.

The re-model also directly serves invariant I5 (sync-boundary purity, D3). Because the new `zoneId`
register on `Tile` is a plain `UUID?` — not a runtime handle, not a path, not a pid — it is safe
to carry in the synced spatial payload by construction. The taint scan work that proves I5 will
find nothing to flag in this field. And because the old `GroupZoneTiles` struct (which embedded
full `Tile` values including `runtimeRef`) is **deleted, not shimmed**, there is no derived
projection left that could carry `runtimeRef` toward the boundary — the I5 risk the old shape
carried is removed at the type level rather than scrubbed at runtime.

## The approach

There are two decided moves, both concrete, no open forks:

**Move 1 — add the `zoneId` register to `Tile`.** Add a single nullable `zoneId: UUID?` field to
`Tile` in `CanvasState.swift`. This is the LWW register. Its value is determined by the highest-
`OpId` `setTileZone` op targeting that tile id, exactly as `SYNC-MODEL.md` "Hard case #3 —
membership" specifies. Nil means the tile belongs to no zone (ambient); a non-nil UUID identifies
the zone that owns it. Decode with `decodeIfPresent` so existing `canvas.json` files load without a
migration (existing tiles decode with `zoneId = nil`); encode with `encodeIfPresent`. Bump
`CanvasState.currentSchemaVersion` from 1 to 2.

**Move 2 — re-home ambient tiles onto `WorkspaceDocument.ambientTiles` and derive membership from
the register.** This is the load-bearing change and it is fully specified, not left to the
implementer:

- **Delete the `GroupZoneTiles` struct entirely** (`WorkspaceDocument.swift:3–11`). It is deleted,
  not retained as a shim. This removes the I5 risk it carried (embedded full `Tile` with
  `runtimeRef`) at the type level — there is no fork here, no "may strip / may remove."
- **Replace the stored `groupZoneTiles: [GroupZoneTiles]` property** (`WorkspaceDocument.swift:21`)
  **with a stored `ambientTiles: [Tile]` property** — a flat list of the tiles that live in this
  workspace's group zones. `WorkspaceDocument` already owns these tile records (that is what
  `groupZoneTiles[*].tiles` was); this just flattens the shape so membership rides on each tile's
  `zoneId` instead of the enclosing struct's `zoneId`.
- **`tiles(forZone:)`** becomes a filter over `ambientTiles`: `ambientTiles.filter { $0.zoneId ==
  zoneId }`. No `canvas` parameter, no cross-store join — `WorkspaceDocument` owns `ambientTiles`
  directly, so the signature is unchanged from today (`func tiles(forZone zoneId: UUID) -> [Tile]`).
- **`setTiles(_:forZone:)`** becomes a mutation of `ambientTiles`: set `zoneId = zoneId` on the
  tiles being placed (inserting any not already present), and set `zoneId = nil` on any tile
  previously in that zone but not in the new list. `setTiles([], forZone:)` (the one production
  call, `ContinuumApp.swift:6334`) clears membership by setting those tiles' `zoneId` to nil. The
  signature is **unchanged** (`mutating func setTiles(_ tiles: [Tile], forZone zoneId: UUID)`), so
  the production call-site compiles with a zero-diff call. This resolves the old ticket's open "may
  need a `canvas: inout` parameter" fork: it does not, because the tiles live on the document.

Because `tiles(forZone:)` and `setTiles(_:forZone:)` keep their exact current signatures, **no
caller outside this ticket changes its call shape.** The only ripple is the deletion of the
`GroupZoneTiles` type and the `groupZoneTiles:` initializer argument — a mechanical rename to
`ambientTiles:` at the fixture construction sites listed under "Where it lives."

`SidebarTreeBuilder.tiles(for:)` (`SidebarTree.swift:184–192`) currently reads
`document.tiles(forZone:)` for group zones and uses spatial containment for project zones. After
this change, `tiles(forZone:)` returns the same data (the tiles whose `zoneId` matches), so the
sidebar call-site is unchanged. The spatial containment path for project zones is untouched.

Bump `WorkspaceDocument.currentSchemaVersion` from 2 to 3. The decoder reads the old
`groupZoneTiles` key when `schemaVersion < 3` and flattens it into `ambientTiles` (see Step 3);
`decodeIfPresent` on the new `ambientTiles` key handles the v3 format.

## Where it lives

**Primary file: `Sources/ContinuumRevivedCore/CanvasState.swift`**

- `Tile` struct (`CanvasState.swift:39–65`): add `public var zoneId: UUID?` after `zIndex`
  (line 44). Update the memberwise initializer (add `zoneId: UUID? = nil`), the `Codable`
  conformance (`Tile` uses the synthesized `Codable` today — to add `decodeIfPresent`/
  `encodeIfPresent` you must add an explicit `CodingKeys` + `init(from:)` + `encode(to:)`, mirroring
  the `TileMetadata` pattern at `CanvasState.swift:156–187`), and `Equatable` (automatic since
  `UUID?` is `Equatable`).
- `CanvasState.currentSchemaVersion` (`CanvasState.swift:4`): bump from 1 to 2.
- `CanvasState`'s schema guard is external (`ProjectStore.checkSchema`, called at
  `ProjectStore.swift:114`). No decoder change is needed for backward-compat on `CanvasState`
  itself — `decodeIfPresent` on `Tile.zoneId` means a v1 canvas (no `zoneId` key) decodes with all
  tiles `zoneId = nil`. Confirm `checkSchema` still accepts v1 (it compares `<=` supported, so a v1
  file loading under a v2 build passes; a v2 file under a v1 build is rejected — the desired
  forward-incompat guard).

**Primary file: `Sources/ContinuumRevivedCore/WorkspaceDocument.swift`**

- **Delete** the `GroupZoneTiles` struct (`WorkspaceDocument.swift:3–11`).
- **Replace** the `groupZoneTiles: [GroupZoneTiles]` stored property (`:21`) with
  `public var ambientTiles: [Tile]`. Update the memberwise init (rename the
  `groupZoneTiles: [GroupZoneTiles] = []` parameter to `ambientTiles: [Tile] = []`).
- `tiles(forZone:)` (`:39–41`): `ambientTiles.filter { $0.zoneId == zoneId }`.
- `setTiles(_:forZone:)` (`:43–50`): mutate `ambientTiles` per Move 2 above. Same signature.
- `WorkspaceDocument.currentSchemaVersion` (`:14`): bump from 2 to 3.
- The `Codable` conformance (`:121–145`): the `CodingKeys` enum keeps a `groupZoneTiles` case **for
  the decode-only migration path** and adds an `ambientTiles` case. `init(from:)` reads
  `ambientTiles` via `decodeIfPresent(... ) ?? []`, then if `schemaVersion < 3` also reads the old
  `groupZoneTiles` via `decodeIfPresent([LegacyGroupZoneTiles].self, ...)` and flattens it (Step 3).
  `encode(to:)` writes **only** `ambientTiles` — the old `groupZoneTiles` key is never re-emitted,
  so a re-saved document is clean v3.
- Add a **private** `LegacyGroupZoneTiles` decode-only struct (`{ zoneId: UUID; tiles: [Tile] }`)
  local to the decoder for the migration read. It is not public API; it exists solely to parse the
  pre-v3 on-disk shape. This is the *only* remaining reference to the old grouped shape and it is
  read-only.

**Test file: `Sources/ContinuumRevivedCoreChecks/main.swift`**

- The existing T02 round-trip block (`main.swift:1636–1713`, plus its fixture-construction site
  around `main.swift:5280`) that verifies `groupZoneTiles` round-trips, backward-compat decodes to
  `[]`, and upsert/clear semantics must be rewritten to the `ambientTiles` shape: round-trip
  `ambientTiles` with `zoneId`-stamped tiles; assert an old v2 doc with no `ambientTiles` key
  decodes to `[]`; assert `tiles(forZone:)`/`setTiles` behave over the register.
- New register / migration / convergence / taint checks (see "How we test it").

The self-checks in `ContinuumApp.swift` that construct `WorkspaceDocument` with inline
`groupZoneTiles:` arrays (confirmed 2026-06-30 at `ContinuumApp.swift:4667`, `4679`, `4842`,
`4854`, `5086`) must be updated: replace each `GroupZoneTiles(zoneId: Z, tiles: [t1, t2])` argument
with an `ambientTiles: [t1.with(zoneId: Z), t2.with(zoneId: Z)]` argument (construct the `Tile`
values with `zoneId` set). These are self-check fixtures, not production paths. Grep for
`GroupZoneTiles(` and `groupZoneTiles:` across the whole tree before starting so the full fixture
list is known up front (the six sites above were found on 2026-06-30; re-grep to confirm none were
added since).

## Implementation breadcrumbs

Below is the structural pattern the implementer should follow. These are not complete
implementations — they steer the control flow and the key types.

**Step 1 — Add the field to `Tile`.**

```swift
// CanvasState.swift — inside Tile
public var zoneId: UUID?   // nil = ambient; non-nil = the zone that owns this tile

// Memberwise init gains: zoneId: UUID? = nil
// Tile is currently synthesized-Codable, so add explicit CodingKeys + init(from:) + encode(to:)
// (mirror TileMetadata at CanvasState.swift:156–187):
//   decodeIfPresent(UUID.self, forKey: .zoneId)  → zoneId
//   encodeIfPresent(zoneId, forKey: .zoneId)
```

**Step 2 — Bump schema versions.**

```swift
// CanvasState.currentSchemaVersion = 2   (guarded externally by ProjectStore.checkSchema)
// WorkspaceDocument.currentSchemaVersion = 3
```

**Step 3 — Migration on load: flatten old `groupZoneTiles` into `ambientTiles` with zoneId stamped.**

This is entirely inside `WorkspaceDocument.init(from:)` — self-contained, single store, no canvas
lookup. There is no `canvas.tiles.first(where:)` join anywhere, because ambient tiles never lived
in a canvas: the old list already *held the full Tile values*, so the migration owns them directly.

```swift
// WorkspaceDocument.init(from:)
schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
// ... viewport / zones / zoneZOrder / lastActiveZoneId as today ...

var tiles = try container.decodeIfPresent([Tile].self, forKey: .ambientTiles) ?? []

if schemaVersion < 3 {
    // Read-only legacy parse of the pre-v3 grouped shape and flatten it.
    let legacy = try container.decodeIfPresent([LegacyGroupZoneTiles].self, forKey: .groupZoneTiles) ?? []
    for group in legacy {
        for var t in group.tiles {
            t.zoneId = group.zoneId          // stamp membership onto the tile
            tiles.append(t)                  // re-home into the flat list
        }
    }
}
ambientTiles = tiles
// schemaVersion is stored as decoded; the NEXT save re-emits it as currentSchemaVersion (3)
// via the memberwise value used at save sites, and encode() writes only `ambientTiles`.

// private, decode-only:
private struct LegacyGroupZoneTiles: Decodable {
    let zoneId: UUID
    var tiles: [Tile]
}
```

Note on the `t.zoneId = group.zoneId` line: because the migration owns the full `Tile` value (it
was embedded in the old list), stamping is a direct field write — it does **not** depend on any
other store holding the tile. This is the exact gap that made the old design unimplementable, now
closed by re-homing rather than joining.

**Step 4 — Make `tiles(forZone:)` and `setTiles(_:forZone:)` derive from the register.**

```swift
public func tiles(forZone zoneId: UUID) -> [Tile] {
    ambientTiles.filter { $0.zoneId == zoneId }
}

public mutating func setTiles(_ tiles: [Tile], forZone zoneId: UUID) {
    let newIds = Set(tiles.map(\.id))
    // clear tiles that were in this zone and are no longer in the new list
    for i in ambientTiles.indices where ambientTiles[i].zoneId == zoneId && !newIds.contains(ambientTiles[i].id) {
        ambientTiles[i].zoneId = nil
    }
    // place / re-place the new tiles into this zone
    for tile in tiles {
        if let i = ambientTiles.firstIndex(where: { $0.id == tile.id }) {
            ambientTiles[i].zoneId = zoneId
        } else {
            var t = tile
            t.zoneId = zoneId
            ambientTiles.append(t)
        }
    }
}
// setTiles([], forZone: Z) clears every tile currently in Z (they drop to zoneId = nil,
// remaining ambient-with-no-zone in the list — matching today's "cleared zone" semantics,
// where the tiles are no longer reported under that zone).
```

**Step 5 — Encoder writes only the new shape (no shim to strip).**

```swift
public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)   // currentSchemaVersion at save time
    try container.encode(viewport, forKey: .viewport)
    try container.encode(zones, forKey: .zones)
    try container.encode(zoneZOrder, forKey: .zoneZOrder)
    try container.encodeIfPresent(lastActiveZoneId, forKey: .lastActiveZoneId)
    try container.encode(ambientTiles, forKey: .ambientTiles)     // ONLY the flat list; no groupZoneTiles
}
```

There is no runtime `runtimeRef`-stripping step and no "computed shim" — the old grouped-with-full-
`Tile` projection is gone. `ambientTiles` is the authoritative store; the encoder emits it directly.
I5 is served by the field being a plain `UUID?` and by the deletion of the taint-carrying struct,
not by a scrub. (The I5 taint check below still runs, as belt-and-suspenders, and asserts zero
forbidden tokens — `runtimeRef` values on ambient tiles are still real host handles that must not
reach the sync boundary; the *sync projection*, owned by the op-log work, excludes `runtimeRef` per
`SYNC-MODEL.md`. This ticket's contribution is that the *persistence shape* no longer duplicates
tiles into a second grouped structure.)

**Step 6 — Op-log integration hook (for the op-log apply work that follows).**

The `setTileZone(tile: UUID, zone: UUID?)` case in the `Op` enum (defined by the op-log core work,
D3) folds into the materialized state as a simple `tile.zoneId = zone` assignment keyed by tile id,
with the highest `OpId` winning — for a project tile it writes `CanvasState.tiles[i].zoneId`, for an
ambient tile it writes `WorkspaceDocument.ambientTiles[i].zoneId`. The same field name in both
stores is what lets the fold be one code path. The implementer does not build the op-log apply
function here — only ensure `Tile.zoneId` is the field future apply logic writes. No application
logic or command routing is changed in this ticket.

## How we test it

### Logic (pure Core checks)

All checks run in `ContinuumRevivedCoreChecks` — pure Swift, no daemon, no real files.

**Register semantics.** Construct a `WorkspaceDocument` with three ambient tiles (A, B, C) in
`ambientTiles`, all `zoneId == nil`. Set A's `zoneId` to zone X (via the register directly). Assert
`ambientTiles.first{ $0.id == A }!.zoneId == X`. Set A's `zoneId` to zone Y. Assert `== Y` (LWW).
Set A's `zoneId` to nil. Assert `== nil`. At all points assert B and C stay `nil`. This proves "at
most one zone per tile" is automatic — no repair loop.

**Derived-view consistency.** With A and B both `zoneId == X` in `ambientTiles`, call
`document.tiles(forZone: X)`. Assert it returns exactly `[A, B]` (order-independent by id). Call
`document.setTiles([], forZone: X)`. Assert `tiles(forZone: X)` is now empty and that A and B are
still present in `ambientTiles` with `zoneId == nil`. Then call `setTiles([A], forZone: X)` and
assert `tiles(forZone: X) == [A]` and B stayed nil. This proves the derived view and the write path
agree with the register.

**LWW convergence check.** Simulate two replicas both applying `setTileZone` ops (as plain structs
with fabricated `OpId` values — no real op-log needed yet) targeting the same tile in opposite
order. The fold (apply in ascending `OpId` order, `tile.zoneId = op.zone`) must produce
`zoneId == the value from the higher OpId` regardless of application order. Assert the two replicas'
resulting `ambientTiles` are byte-identical after canonical encode. This is the I4 pre-check for
membership specifically, proving the register is order-insensitive before the full convergence fuzz
runs.

**Round-trip (I7).** Encode a v2 `CanvasState` with mixed `Tile.zoneId` values to JSON, decode,
assert `decoded == original`. Encode a v3 `WorkspaceDocument` with `ambientTiles` carrying mixed
`zoneId` values, decode, assert `decoded == original`. Separately, fabricate an old v1 canvas JSON
(tiles with no `zoneId` key), decode, assert every tile has `zoneId == nil`. This covers both the
backward-compat decode and the current-schema round-trip.

**Old-format migration check (in-memory decode).** Hand-build a `WorkspaceDocument` JSON string at
`schemaVersion: 2` with a **non-empty** `groupZoneTiles` array carrying two tiles (T1, T2) in zone
X and no `ambientTiles` key. Decode it with the real `WorkspaceDocument.init(from:)`. Assert
`ambientTiles` now contains T1 and T2, each with `zoneId == X`. Assert `tiles(forZone: X)` returns
both. Re-encode the decoded document at `currentSchemaVersion` (3), decode the re-encoded JSON, and
assert: the JSON has **no** `groupZoneTiles` key, `schemaVersion == 3`, and the two tiles still
carry `zoneId == X`. This is fully runnable now because the migration owns the tiles directly — no
external canvas is needed for the lookup, which is precisely the gap the re-home closes.

**I5 taint check.** Encode a `Tile` with a non-nil `runtimeRef` (host handle) to JSON. Assert that
the JSON encoding of a `setTileZone` op carrying that tile's *id* contains no occurrence of the
string `"runtimeRef"` and no occurrence of the `RuntimeRef.id` value (the op carries only
`tile: UUID` + `zone: UUID?`). Assert that a `WorkspaceDocument` with `ambientTiles` containing that
tile, when its **sync projection** (the op-log's spatial projection, which excludes `runtimeRef`) is
encoded, contains no `"runtimeRef"`. Record the scanned byte count in the manifest — never
`{passed: true}`.

### Backend (real-path / integration)

The real-path check exercises the actual `WorkspaceStore` persistence machinery — not a fake
encoder, not a fabricated snapshot fed to a private function, but the full save-and-load path that
production uses. Because ambient membership lives entirely in `WorkspaceDocument` / `WorkspaceStore`,
this check needs **only** `WorkspaceStore` — there is no `ProjectStore` join to construct, which is
what makes it runnable as specified.

**Write-then-reload cycle.** Build a real `WorkspaceDocument` whose `ambientTiles` holds two tiles
assigned to a group zone (`zoneId == X`). Call `WorkspaceStore.save`. Read it back with
`WorkspaceStore.load`. Assert the loaded `ambientTiles` carry `zoneId == X`, that
`document.tiles(forZone: X)` returns both, and that `schemaVersion == 3` in the reloaded document.
Then call `document.setTiles([], forZone: X)`, save, reload, and assert `tiles(forZone: X)` is
empty and the tiles remain in `ambientTiles` with `zoneId == nil`. This proves the clear path
survives real I/O.

**Old-file upgrade path.** Write a hand-crafted `workspace canvas.json` at `schemaVersion: 2` with a
**non-empty** `groupZoneTiles` payload (two tiles in zone X) into a temp workspace directory (set
`CONTINUUM_APP_SUPPORT` to the temp dir so `WorkspaceStore` reads/writes there). Call
`WorkspaceStore.load`. Assert the loaded `ambientTiles` have `zoneId == X` populated from the old
`groupZoneTiles` list. Save the loaded document back via `WorkspaceStore.save`; re-read the raw
file bytes and assert they contain `"schemaVersion":3` and no `groupZoneTiles` key. This is the
migration path under the actual `AtomicWriter` I/O, not a decoder unit test, and it is runnable
because the tiles are self-contained in the workspace document.

**Manifest.** The check records `ambientTilesWithZoneId: N`, `ambientTilesWithoutZoneId: M`,
`workspaceSchemaVersion: 2→3`, `canvasSchemaVersion: 1→2`, `migrationRan: true/false`, and
`taintTokensFound: 0` — concrete numbers, never a boolean pass.

### UX (visual gate + dogfood snippet)

This ticket has no UI output of its own — it changes the data model, not what the user sees. The
visual gate is therefore a **non-regression check** using an existing visible surface: the sidebar
tree, which reads `tiles(forZone:)` to show group-zone tile membership.

**Visual gate.** Open the app. Create a group zone (ambient, `projectId == nil`). Add two tiles to
it via the current path that populates ambient membership (`setTiles(_:forZone:)` — note the caveat
below). Observe the sidebar: both tiles must appear as children of the group zone row. This proves
`SidebarTreeBuilder.tiles(for:)` reads the new `zoneId` register via `tiles(forZone:)`. Trigger the
clear path (close the zone via the flow that calls `persistClosedZone`). The sidebar must update to
show no tiles under that zone. This proves `setTiles([], forZone:)` clears the register.

Caveat, stated honestly: there is **no production drag-to-assign path** that populates ambient
membership today (`setTiles` is clear-only in production — `TOPOLOGY.md`, "Current mapping"). So the
"add two tiles to a group zone" step above may have no live gesture to exercise it until the
topology work (D15) lands the write path. If that is the case at implementation time, the visual
gate degrades to: construct a `WorkspaceDocument` fixture with two `ambientTiles` in a zone, drive
`SidebarTreeBuilder.build` with it, and snapshot/assert the tree shows both tiles under the zone —
a real-path render of the production sidebar builder, not a bypass. Do **not** invent a UI gesture;
if none exists, use the fixture-fed real builder and note it in the manifest.

**Dogfood snippet.** Open the app. In the sidebar, expand a group zone that has at least one tile.
The tile row must appear indented under the zone with the tile's title. Navigate away (click a
project zone), then back. Membership is still intact — the tile's `zoneId` was persisted in
`ambientTiles`, reloaded by `WorkspaceStore`, and the sidebar re-derived it via `tiles(forZone:)`.
If the membership display looks identical before and after this ticket lands, the re-model is
transparent to the user.

## Execution mode

**Autonomous.** Every correctness property this ticket delivers — register semantics, LWW
convergence, round-trip, migration, I5 taint, derived-view consistency, real-path store write and
reload — is provable by pure Core logic checks plus a real `WorkspaceStore` integration check run
against the filesystem. All of it is self-contained in `CanvasState` + `WorkspaceDocument` +
`WorkspaceStore` + the checks; **no cross-store join, no `ProjectStore` coupling, and no
undecided fork** remains. No human visual gate is required for the data-model change; the
non-regression sidebar check is an additional dogfood pass documented above (and its fixture-fed
fallback is spelled out so it is runnable even before a drag-to-assign gesture exists). The check
harness can emit pass/fail with measured values, satisfying the verification doctrine without human
intervention.

## Done when

- [ ] `Tile` has a `public var zoneId: UUID?` field, decoded with `decodeIfPresent`, encoded
  with `encodeIfPresent`, and `nil` for all tiles loaded from a pre-v2 `canvas.json`.
- [ ] `CanvasState.currentSchemaVersion` is 2; `WorkspaceDocument.currentSchemaVersion` is 3.
- [ ] `GroupZoneTiles` is **deleted**; `WorkspaceDocument.groupZoneTiles` is replaced by
  `public var ambientTiles: [Tile]`. No public API named `groupZoneTiles` remains.
- [ ] `tiles(forZone:)` returns tiles by filtering `ambientTiles` on `tile.zoneId`, with the same
  signature it has today (no `canvas` parameter).
- [ ] `setTiles(_:forZone:)` writes `tile.zoneId` on `ambientTiles` (placing new tiles, clearing
  removed ones), with the same signature it has today; the one production call
  (`ContinuumApp.swift:6334`) compiles unchanged.
- [ ] The old-format migration path, entirely inside `WorkspaceDocument.init(from:)`, flattens a
  non-empty pre-v3 `groupZoneTiles` payload into `ambientTiles` with each tile's `zoneId` stamped —
  and the in-memory migration check with a **non-empty** legacy payload passes.
- [ ] The re-saved document is clean v3: `encode(to:)` emits `ambientTiles` and never
  `groupZoneTiles`; the round-trip and upgrade checks assert no `groupZoneTiles` key in output.
- [ ] Every ambient tile has `zoneId` pointing at at most one zone — the check asserts this without
  any repair loop.
- [ ] The LWW convergence check (two replicas, opposite op order, byte-identical final
  `ambientTiles`) passes.
- [ ] The I7 round-trip check passes for canvas v2, workspace v3, and the old-format v1/v2 loads.
- [ ] The I5 taint check asserts zero forbidden tokens in `setTileZone` op payloads and in the
  workspace sync projection, with measured byte counts in the manifest.
- [ ] The real-path `WorkspaceStore` write-then-reload check and the old-file upgrade check both
  pass against actual `AtomicWriter` I/O.
- [ ] The existing T02 round-trip assertion in `ContinuumRevivedCoreChecks/main.swift` is updated to
  the `ambientTiles` shape and passes.
- [ ] All self-check fixtures in `ContinuumApp.swift` that constructed `WorkspaceDocument` with
  inline `groupZoneTiles:` arrays are updated to `ambientTiles:` with `zoneId`-stamped tiles, and
  compile. (Re-grep `GroupZoneTiles(` / `groupZoneTiles:` yields zero hits after the change.)
- [ ] `SidebarTreeBuilder` still compiles; `tiles(for:)` calls the unchanged `tiles(forZone:)` API
  and produces the same output as before for existing fixtures.

This is a single falsifiable target. There is **no scope-reduction escape hatch**: the migration
path, the `setTiles` register write, and the deletion of `GroupZoneTiles` all ship together, or the
ticket is not done. (See "Watch out for" for why the previous escape hatch was removable.)

## Depends on / unblocks

This ticket depends on the op enum and logged-op envelope (D3), which define
`setTileZone(tile: zone:)` as a first-class op case and establish the `OpId` type used by the LWW
convergence check. The store-protocol seam (`WorkspaceStore` behind a protocol) is a useful prior
but is **not** required — this ticket mutates the concrete `WorkspaceStore`/`WorkspaceDocument`
directly and the diff is small and self-contained.

What this unblocks is the heart of Phase 0 and the start of Phase 1. The op-log apply and
compaction work cannot finalize the `setTileZone` fold without `Tile.zoneId` existing. The
convergence fuzz cannot run its membership assertions without a `zoneId` to check. The per-workspace
ambient session work (D15) is explicitly conditional on confirming a membership signal; this ticket
provides it by giving `ambientTiles` a real, populated, per-workspace write path. Finally, the taint
scan for sync-boundary purity (I5) will include `Tile.zoneId` in its allow-listed spatial value
types and can use the check written here as a template.

## Watch out for

**The migration is self-contained — that is the whole point.** The old design tried to write
`tile.zoneId` by looking the tile up in a `CanvasState` that does not exist for ambient tiles
(`canvas.tiles.first(where: { $0.id == tile.id })`), which would silently find nothing and lose
membership. This ticket avoids that entirely: the legacy `groupZoneTiles[*].tiles` already *contains*
the full `Tile` values, so migration flattens them into `ambientTiles` and stamps `zoneId` directly.
There is **no** cross-store lookup anywhere in the migration. If you find yourself reaching for a
`CanvasState` inside `WorkspaceDocument.init(from:)`, stop — you have taken the wrong path.

**The old `groupZoneTiles` list was effectively unpopulated in production** (the only write path was
the clear, `setTiles([], ...)`), so most real users load documents where it is empty and every
ambient tile is `nil` — which is correct. But the self-check fixtures in `ContinuumApp.swift` and
the T02 core check **do** construct non-empty legacy payloads, and the migration check
*deliberately* constructs a non-empty one. These prove the flatten path. Verify both the empty and
non-empty migration paths.

**`GroupZoneTiles` embedded full `Tile` values including `runtimeRef` — and it is now deleted.** The
old ticket left "strip `runtimeRef` in a computed shim" as a maybe. There is no shim: the grouped,
taint-carrying projection is gone. The only place a full `Tile` (with `runtimeRef`) now lives for
ambient tiles is `ambientTiles`, which is the persistence store, not a sync projection. The sync
projection that reaches the boundary is owned by the op-log work and excludes `runtimeRef` per
`SYNC-MODEL.md`; the I5 taint check in this ticket asserts that projection is clean.

**Schema bumps must be tested in both directions.** A new build loading an old `canvas.json` (no
`zoneId`) must get `nil` everywhere — not a decode error. A new build loading an old
`workspace canvas.json` (v2, `groupZoneTiles`) must flatten into `ambientTiles`. An old build
loading a new document is correctly rejected by the `<=`-supported schema guards
(`WorkspaceDocument.validateSchema` and `ProjectStore.checkSchema`) with the documented
"unknown future schema" error — confirm both guards still reject a too-new version rather than
silently ignoring the unknown field via `decodeIfPresent`.

**Stop if** implementing this requires changes outside `CanvasState.swift`,
`WorkspaceDocument.swift`, `WorkspaceStore.swift` (if any), `SidebarTree.swift`, the
`ContinuumRevivedCoreChecks` harness, and the `ContinuumApp.swift` self-check fixtures listed above.
The change is deliberately confined to these files — `ambientTiles` living on `WorkspaceDocument`
is what keeps it confined, with no ripple into callers of `tiles(forZone:)` (the signature is
unchanged). If a wider ripple appears, the design has been misread — re-read "The approach" rather
than reducing scope, because there is no partial-ship state that satisfies "Done when."

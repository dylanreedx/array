# Delete as a tombstone

## What this delivers

After this work lands, the sync layer has the two data-model pieces that make deletion convergence-safe: a `deleteTile` and `deleteZone` op in the `Op` enum, and a small `TombstoneSet` value type that collects those deletes in one pass. Alongside them, this ticket defines — as plain `Codable` data types, not as a running compactor — the `TombstoneRecord` and `CompactionLedger` structs that a later compaction step will persist so a tombstone survives compaction. And it writes down, as an executable specification, the delete-wins policy: once a delete op exists for an entity, no concurrent field-set with any Lamport timestamp may resurrect it.

This ticket does **not** author `materialize` or the compactor — those belong to the op-log apply and compaction ticket (ticket six), which folds the log and enforces delete-wins inside the fold. What this ticket delivers is the *vocabulary and the policy* that ticket six consumes: the enum cases it must handle, the tombstone type it must build during the fold, the ledger type it must persist during compaction, and a suite of pure logic tests — driven through a tiny local test-only fold, not the production `materialize` — that pin down exactly what delete-wins means so ticket six has an unambiguous target.

No visible behavior changes for the user. This is a data-model correctness property: tiles and zones close exactly as before, but the delete op and its convergence semantics now exist as sync primitives.

## How it fits

The op enum and logged-op envelope (ticket two in the foundations phase) establishes the `Op` enum, the `OpId` Lamport-plus-replicaId clock, and the `LoggedOp` wrapper. This ticket depends directly on that foundation — tombstones are two new cases in the `Op` enum, and the delete-wins policy is the semantics those cases carry.

The membership-as-a-tile-level-register work (ticket three) and the z-order fractional index work (ticket four) are siblings on the same dependency: all three re-model specific spatial fields to make them convergence-safe. Together, tickets three, four, and five are the three field re-models that must exist before the op-log apply and compaction ticket (ticket six) can implement `materialize` and `compact`. Ticket six is the one place `materialize` lives; it depends on this ticket for the tombstone vocabulary and the delete-wins policy, and its own Done-when carries the `materialize` implementation, the compactor, and the compaction round-trip test. This ticket carries none of those — it carries the enum cases, the `TombstoneSet`, the ledger data types, and the policy tests.

The convergence fuzz (ticket seven) then exercises the whole system — tombstones, registers, and fractional indices — under random op ordering and network chaos, driving the real `materialize` from ticket six. The taint scan (ticket nine) confirms that tombstones, like all op payloads, carry no runtime handle, pid, or pane target.

This is the last of the three field re-models. It is deliberately scoped to *types + policy + logic tests*, because the seam that would let a real close gesture emit a `deleteTile` op through a store does not exist in phase 0 (see "The boundary this ticket does not cross").

## The approach

Deletion is modeled as a `deleteTile(id: UUID)` and `deleteZone(id: UUID)` case in the `Op` enum. The delete-wins policy — the thing this ticket specifies and ticket six implements — is: when the log is folded into state, tombstoned IDs are collected in a single pass *before* any field-setting op is applied, and any field-setting op (move, resize, rename, zIndex, membership) that references a tombstoned ID is dropped, regardless of that op's Lamport timestamp. Once a delete op appears in the log, no subsequent op with a higher `opId` resurrects the entity.

The `TombstoneSet` is the value type that makes the "collect first" step concrete. It wraps a `Set<UUID>` for tiles and a separate `Set<UUID>` for zones and exposes `absorb(_:)` (fold one `LoggedOp` in — inserting the id only for delete cases) and `isTombstoned(tileId:)` / `isTombstoned(zoneId:)` lookups. Ticket six's `materialize` builds a `TombstoneSet` from the sorted log and consults it in its resolve step. This ticket ships `TombstoneSet` and proves it in isolation.

Tombstones are stored in the log like any other `LoggedOp` — they have an `opId` with a Lamport clock and a replicaId, they are sorted into the total order, and they are broadcast to peers exactly like a field-set op. This ticket does not implement that transport; it defines the op so the transport and the fold have something to carry and interpret.

For compaction, this ticket defines the *data types only*. A tombstoned entity may eventually be removed from a compacted snapshot entirely, but the snapshot must retain a small ledger so a peer that reconnects with pre-compaction log entries learns the entity is gone rather than treating the missing entity as a gap. That ledger is `CompactionLedger`, a `Codable` struct of `TombstoneRecord`s (each `{ entityId, deleteOpId, entityKind }`) plus a `compactedThrough` low-water mark. This ticket defines and round-trips those types; the ticket-six compactor is what *populates and consults* them. The "late-arriving create after compaction" behavior is therefore ticket six's test to write (it needs the real compactor) — this ticket only guarantees the ledger type can faithfully carry the record a compactor would need.

`TileGroup` membership (`tileIds`) is not handled here — that is the membership-register ticket's territory. Viewport is not touched. This ticket touches only the lifecycle of tiles and zones as keyed-set members.

## The boundary this ticket does not cross

There is **no store-level tile-mutation seam in phase 0.** `ProjectStore` (`Sources/ContinuumRevivedCore/ProjectStore.swift:76`) is a value struct whose only canvas surface is `saveCanvas(_:)` / `loadCanvas()` — it has no `deleteTile`, no `closeTile`, no `removeTile`, and no action-executor. Ticket one puts it behind the `ProjectStoring` protocol but adds no mutation methods. The only real close paths that exist today are UI-level: `CanvasView.removeTile(id:)`, called from `ComponentLab.swift:157` and `TileSpawner.swift:649`. Those mutate the in-memory canvas and re-save the whole snapshot; they do not emit ops and do not go through any op-log.

The seam where a close gesture *emits a `deleteTile` op through a store* is produced later, when the op-log store implementation is wired behind `ProjectStoring` (op-log apply, ticket six) and when the session-topology close path (`close-tile = kill-window`, ticket nineteen) is built. Because that seam does not exist yet, this ticket does **not** claim a real-path integration test that "drives the executor through the store." It would be untestable, and asserting it would be a happy-path fiction. The honest phase-0 real-path check for this ticket is the existing UI close path continuing to work unchanged (dogfood snippet below) plus the Component Lab visual gate — not a synthetic op-emitting store that no code produces.

## Where it lives

**Primary target — `ContinuumRevivedSync` (created by the op-log apply ticket; this ticket adds to it if it exists, or stubs the target minimally if scheduled first):**

- `Op` enum: add `case deleteTile(id: UUID)` and `case deleteZone(id: UUID)`. This target has no external dependencies and no access to `RuntimeRef` — I5 purity is architectural.
- `TombstoneSet`: a small value type wrapping `Set<UUID>` for tiles and a separate `Set<UUID>` for zones, with `absorb(_:)` and `isTombstoned(...)`.
- `TombstoneRecord` and `CompactionLedger`: `Codable` data types the ticket-six compactor will persist. Defined and round-tripped here; populated and consulted there.

**Read-only context — the spatial types the delete-wins policy governs (no changes here):**

- `CanvasState.swift` (`Sources/ContinuumRevivedCore/CanvasState.swift`): `Tile` at line 39 (keyed by `Tile.id`), `TileGroup` at line 190. The tombstone lives in the op log, never in the `Tile` struct.
- `WorkspaceDocument.swift` (`Sources/ContinuumRevivedCore/WorkspaceDocument.swift`): `ZonePlacement` at line 147 (keyed by `zoneId`), `zoneZOrder: [UUID]` at line 19, `groupZoneTiles` at line 21. These are the fields ticket-six `materialize` must filter for tombstoned zones — noted here so the policy is unambiguous, but the filtering code is ticket six's.

## Implementation breadcrumbs

```swift
// In ContinuumRevivedSync — Op enum additions (builds on ticket 2)
enum Op: Codable, Sendable {
    // ... existing cases from ticket 2 ...
    case deleteTile(id: UUID)    // tombstone: delete-wins vs any concurrent field-set
    case deleteZone(id: UUID)    // tombstone: same policy
}

// TombstoneSet — derived in one pass, never authored directly.
// Ticket 6's materialize builds one of these from the sorted log and consults it
// in its resolve step. This ticket ships the type and proves it in isolation.
struct TombstoneSet {
    var tileIds: Set<UUID> = []
    var zoneIds: Set<UUID> = []

    mutating func absorb(_ op: LoggedOp) {
        switch op.op {
        case .deleteTile(let id):  tileIds.insert(id)
        case .deleteZone(let id):  zoneIds.insert(id)
        default: break
        }
    }

    func isTombstoned(tileId id: UUID) -> Bool { tileIds.contains(id) }
    func isTombstoned(zoneId id: UUID) -> Bool { zoneIds.contains(id) }
}

// CompactionLedger + TombstoneRecord — DATA TYPES ONLY in this ticket.
// The ticket-6 compactor populates `records` and `compactedThrough`; this ticket
// defines the shapes and proves they round-trip to byte-identical JSON.
enum EntityKind: String, Codable, Sendable { case tile, zone }

struct TombstoneRecord: Codable, Sendable {
    var entityId: UUID
    var deleteOpId: OpId
    var entityKind: EntityKind
}

struct CompactionLedger: Codable, Sendable {
    var records: [TombstoneRecord]
    var compactedThrough: OpId  // the Lamport low-water mark of the compaction that wrote this
}
```

The delete-wins invariant that ticket six's `materialize` must uphold, stated here as the policy this ticket owns: **collecting tombstones before folding field-sets means the Lamport ordering of the delete relative to a concurrent field-set is irrelevant.** A field-set with Lamport 100 and a delete with Lamport 5 — both targeting tile T — still produce a tombstone. This is the deliberate delete-wins policy; ticket six must state it in a doc comment on `materialize` and this ticket's logic tests must pin it down before ticket six is written.

The logic tests below drive a **tiny local test-only fold** (a dozen lines: build a `TombstoneSet` from the ops, then filter creates through it) — *not* the production `materialize`, which does not exist until ticket six. This keeps the tombstone-semantics tests authored here and independent of ticket six's timeline, while ticket six re-asserts the same behavior against the real `materialize`.

## How we test it

### Logic (pure Core / Sync checks)

Write these tests before writing `TombstoneSet` — they must fail first. Each test builds a `TombstoneSet` from an in-memory op list and applies the tiny local test-only fold described above (collect tombstones, then filter). None of these tests reference the production `materialize` or a compactor.

**Tombstone absorbs a concurrent field-set, regardless of Lamport order.** Construct a two-replica scenario in memory. Replica A applies `createTile(T)` then `deleteTile(T)`. Replica B applies `createTile(T)` then `setTileFrame(T, bigFrame)` with a Lamport timestamp higher than A's delete. Merge both logs (union of ops), sort by `opId`, build the `TombstoneSet`, run the local fold. Assert: tile T is absent from the folded output. Assert: the higher-Lamport `setTileFrame` did not resurrect T. This is the move-vs-delete case the sync model spike calls the hardest case in the delete row.

**Tombstone absorbs a concurrent zone field-set.** Same pattern for `deleteZone` vs `setZoneOrigin`. Assert the zone is absent from the folded output and would not appear in a `zoneZOrder` derived from the survivors.

**Live tiles survive beside tombstoned ones.** A log with creates for tiles A, B, C and a delete for B. After the local fold: A and C are present, B is absent. Assert by ID, not by count alone.

**Re-delivery of a delete op is idempotent.** Absorb `deleteTile(T)` twice (same `opId`). Assert the `TombstoneSet` is identical to absorbing it once and the fold produces the same output. This is the duplicate-delivery case the fuzz will exercise.

**`TombstoneSet.absorb` ignores non-delete ops.** Absorb a `createTile`, a `setTileFrame`, and a `setZoneSize`. Assert both `Set`s stay empty. This pins the "only delete cases insert" contract that ticket six relies on.

**CompactionLedger round-trip.** Build a `CompactionLedger` with three `TombstoneRecord`s (mixed tile/zone kinds). Encode to JSON with the canonical encoder, decode, assert equal. Assert canonical encoding produces identical bytes on two encode passes (needed for the I7 round-trip and the I4 byte-identity assertion). This tests the *type's* faithfulness only — not a compactor, which does not exist here.

**Taint scan over delete op payloads.** Serialize every `deleteTile` and `deleteZone` op to JSON. Assert the encoded bytes contain no `runtimeRef`, no `%`-prefixed pane target, no `continuum-` session name prefix, no absolute path starting with `/Users/`. This is the I5 check applied to the delete ops specifically.

### Backend (real-path / integration)

There is no op-emitting store seam in phase 0 (see "The boundary this ticket does not cross"), so this ticket has no synthetic executor-through-store integration test — asserting one would be a fiction, because no production code emits a `deleteTile` op yet. The honest real-path check is that the existing UI close path is unaffected by adding the two enum cases and the tombstone types: the `ContinuumRevivedCoreChecks` suite continues to pass with zero regressions, and the app compiles and links clean. The convergence of a delete op through the *real* fold is tested in the op-log apply ticket (ticket six, which owns `materialize`) and stressed under network chaos in the convergence fuzz (ticket seven, which drives the real action path). Those are the tickets that own the seam this integration would require; this ticket does not borrow a seam it does not create.

### UX (visual gate + dogfood snippet)

Tombstoning is invisible to the user by design — but the visual gate confirms that deletion still works correctly end-to-end, and that no ghost tile or zone chrome lingers on the canvas after close.

**Component Lab visual gate.** The Component Lab already renders `CanvasState` from a fixture and already wires `onTileCloseRequested` to `CanvasView.removeTile(id:)` (`ComponentLab.swift:157`). Create a fixture with three tiles; trigger the close of the middle tile through that existing path; assert the canvas renders exactly two tiles. The rendered snapshot (width × height pixels, non-degenerate) is the gate artifact. A snapshot with three tiles is a failure; a blank canvas is a failure; two correctly-positioned tiles is green. This exercises the real UI close path — the path that will *later* emit a `deleteTile` op once ticket six wires the op-log store — without pretending that op path exists today.

**Dogfood snippet.** Open Continuum. Create a project zone with two terminal tiles side by side. Close the left tile using the tile close button (hover the tile header, click the X). Observe: the tile disappears immediately; the right tile remains in its position; the canvas redraws with no ghost frame, no empty slot, and no layout shift on the surviving tile. Resize the app window to confirm the surviving tile reflows normally. This confirms the close path — which will eventually write a `deleteTile` op — behaves correctly through the UI layer even before the op-log transport is live.

## Execution mode

Autonomous. The correctness of tombstone semantics is a pure property: given the same multiset of delete ops, `TombstoneSet` collects the same IDs, and the local test-only fold produces the same absent-entity result every time. The logic tests cover the conflict cases — move-vs-delete, concurrent zone delete, re-delivery, non-delete-ignored, ledger round-trip — without a real tmux daemon, a real iCloud account, or a real device, and without depending on ticket six's `materialize` or compactor. The visual gate runs in the Component Lab against a fixture through the existing close path and produces a rendered snapshot the matrix can checksum. No human eyes, no cloud, no substrate required to verify this ticket.

## Done when

- [ ] `Op.deleteTile(id:)` and `Op.deleteZone(id:)` cases exist in the `ContinuumRevivedSync` target and compile cleanly under `swift build`.
- [ ] `TombstoneSet.absorb(_:)` inserts an id only for `deleteTile`/`deleteZone` and ignores every other op; `isTombstoned(tileId:)` and `isTombstoned(zoneId:)` return correct results.
- [ ] `TombstoneRecord` and `CompactionLedger` are declared as `Codable, Sendable` data types (no compactor logic in this ticket) and round-trip to byte-identical JSON under the canonical encoder.
- [ ] The move-vs-delete logic test passes against the local test-only fold: a `setTileFrame` with Lamport 100 does not resurrect a tile deleted at Lamport 5.
- [ ] All logic tests listed above pass; each has a measured assertion (entity present/absent by ID, `Set` contents, byte-count on canonical encoding) — no `{passed: true}` manifests.
- [ ] The taint scan over delete op payloads passes: no forbidden tokens in encoded bytes.
- [ ] The Component Lab fixture renders exactly two tiles when the middle tile is closed through the existing `onTileCloseRequested`/`removeTile` path; the snapshot artifact is non-degenerate (dimensions > 0, pixel variance > 0).
- [ ] The existing `ContinuumRevivedCoreChecks` suite passes with zero regressions; `swift build` is clean (zero warnings introduced by this ticket).
- [ ] The delete-wins policy — collect-tombstones-before-fold, delete-wins-regardless-of-Lamport — is written down in a doc comment on `TombstoneSet` (and cited by ticket six as the invariant its `materialize` must uphold).

**Explicitly NOT in this ticket's Done-when** (owned by the op-log apply and compaction ticket, ticket six): the `materialize` function; the `compact`/`applySnapshot` compactor; the "late-arriving create after compaction" logic test (needs the real compactor + snapshot); and any test that folds through the production `materialize` or filters `zoneZOrder` inside it. This ticket supplies the vocabulary and policy those tests assert against.

## Depends on / unblocks

This ticket depends on the op enum and logged-op envelope work (ticket two), which supplies the `Op` enum, `OpId` Lamport clock, and `LoggedOp` wrapper that tombstones are built on top of. Without that foundation, there is no enum to extend and no total order to sort before collecting tombstones.

It depends on the `ContinuumRevivedSync` target existing. That target is created by the op-log apply and compaction ticket (ticket six). If this ticket is scheduled before ticket six, it stands up the target minimally (add it to `Package.swift` per ticket six's "Where it lives", depending on `ContinuumRevivedCore`, zero external deps) and adds the enum cases and tombstone types into it; ticket six then fills in `materialize` and the compactor. Either ordering works because the pieces are additive.

This ticket does **not** depend on the store-protocol seam (ticket one). Earlier drafts claimed a backend integration test that drove "the real store through the actual action-executor call path"; no such executor or store-mutation seam exists in phase 0 (verified: `ProjectStore` has only `saveCanvas`/`loadCanvas`; the only close path is the UI-level `CanvasView.removeTile`). That claim is removed. The seam it would require is produced by ticket six (op-log store) and ticket nineteen (close-tile = kill-window), which own their own real-path checks.

This ticket unblocks the op-log apply and compaction work (ticket six): ticket six's `materialize` consumes the `Op` cases and `TombstoneSet` this ticket ships, and its compactor persists the `CompactionLedger` this ticket defines. It also unblocks the convergence fuzz (ticket seven), which generates random `deleteTile`/`deleteZone` ops and must see them produce convergent results through ticket six's fold. Finally, it feeds the taint scan (ticket nine): the I5 guarantee that delete ops carry no forbidden payload is a compile-time property of the `Op` enum's associated values.

## Watch out for

**The resurrection bug is the reason this ticket exists, but the fix lives in ticket six's `materialize`.** The natural (wrong) fold is: sort ops by Lamport, apply each in order, and when you see a delete, remove the entity — because a later higher-Lamport `setTileFrame` then re-inserts it. The correct implementation collects all tombstones in a pre-fold pass and guards every builder mutation. This ticket's job is to make that policy *unambiguous and tested in isolation* (via `TombstoneSet` + the local test-only fold) so that when ticket six writes `materialize`, the target behavior is already pinned by passing tests. Do not try to prevent the resurrection bug by writing `materialize` here — write the policy and the tests that any correct `materialize` must satisfy.

**Do not author the compactor or a compaction behavior test here.** `CompactionLedger` is a data type in this ticket, nothing more. The "compaction discards tombstones and a stale create resurrects the entity" hazard is real, but the test that proves the ledger prevents it needs the actual compactor and snapshot mechanism, which ticket six owns. Landing that test here would require building a compactor this ticket is explicitly not building. Define the ledger so ticket six *can* prevent the hazard; let ticket six prove it does.

**`zoneZOrder` filtering is ticket six's, not this ticket's.** It is easy to reach for "filter tombstoned zones out of `zoneZOrder`" here, but that filter lives inside `materialize`. This ticket only guarantees that a tombstoned zone is *representable* as a tombstone (a `deleteZone` op → a `TombstoneSet` entry). The zone-delete-clears-`zoneZOrder` assertion is ticket six's Done-when.

**Do not add tombstone state to `CanvasState` or `WorkspaceDocument`.** Tombstones live in the op log and the compaction ledger only. The materialized structs represent only live entities. Adding a `tombstonedIds: Set<UUID>` field to `CanvasState` would mix source-of-truth (the log) with derived view (the snapshot) and create a second place that could drift.

**Stop condition.** If the move-vs-delete logic test cannot be made to pass against the local test-only fold within two attempts, stop and surface the specific failing assertion rather than weakening the test. Ticket six and the convergence fuzz depend on this policy being correct; a weakened tombstone test will produce a fuzz that appears to converge but actually hides a resurrection bug.

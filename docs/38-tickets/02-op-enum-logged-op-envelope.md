# Op enum & LoggedOp envelope — the sync identity layer

## What this delivers

After this ticket, Continuum has a complete, self-contained identity layer for its
deterministic op-log sync model: a closed `Op` enum covering every spatial mutation,
a `LoggedOp` envelope that pairs each op with a `(Lamport, replicaId)` clock position,
and an `OpId` type that provides a deterministic total order across all replicas. Every
type is round-trip `Codable` with canonical encoding and carries no wall-clock dependency
whatsoever. Nothing is wired into the running app yet; this ticket produces the pure data
layer that every subsequent sync ticket builds on — the shared vocabulary that makes
convergence provable and boundary purity type-level rather than a convention.

From a system perspective, the payoff is this: the `Op` enum's closed associated-value set
makes `Tile.runtimeRef`, pid values, pane targets, and host-local paths simply
*unrepresentable* in a synced payload. Invariant I5 stops being a runtime assertion and
becomes a compile-time guarantee. That type-level strength is why the op-log was chosen
over a general CRDT Map, and this ticket is where it materializes.

## How it fits

This ticket is the second piece of Phase 0 (foundations) and builds directly on the
store-protocol seam. The store-protocol seam puts the project and workspace persistence
stores behind a protocol, which is what makes the current `CanvasState`
(`Sources/ContinuumRevivedCore/CanvasState.swift:3`) available as a stable materialized
view that the op-log targets without owning. This ticket does not touch the stores or
their protocol — it only defines the types that will later feed them.

What this ticket unblocks is equally important. The membership register ticket (which
re-models group-zone membership from `TileGroup.tileIds` arrays into an LWW register on
the tile) cannot be written until `setTileZone` exists as a real op case with a
well-defined clock. The fractional z-order ticket needs `setZonePosition` with its
`FracIndex` associated value. The delete-as-tombstone ticket needs `deleteTile` and
`deleteZone`. All three of those downstream tickets express their semantics in terms of
the `Op` enum and `OpId` ordering defined here, so they are directly blocked until this
lands. The convergence fuzz (the critical RED→GREEN gate before any transport is
committed) is also blocked, because the fuzz generates and applies `LoggedOp` values —
it cannot run without the envelope type.

## The approach

Define three new types in a new file inside `ContinuumRevivedCore` (no new target, no
new dependency, zero FFI):

1. **`OpId`** — a `struct` with a `lamport: UInt64` and a `replica: UUID`. It conforms to
   `Comparable` via lexicographic `(lamport, replica)` ordering (UUID's raw bytes as the
   tie-breaker, deterministic). `Codable`, `Hashable`, `Sendable`. The total order is what
   makes every replica sort the log identically, which is the mechanical core of I4.

2. **`Op`** — a `Codable`, `Sendable` enum with one case per spatial operation. Associated
   values are drawn exclusively from the spatial value types: `UUID`, `Double`, `Int`,
   `TileFrame`, `ZonePoint`, `ZoneSize`, `FracIndex`, and short `String`s. `RuntimeRef`,
   `TerminalSessionDescriptor`, pids, and any host-local type are simply absent from every
   case — there is no way to construct an `Op` that carries taint.

3. **`LoggedOp`** — a `struct` containing exactly `var opId: OpId` and `var op: Op`,
   both `Codable`, `Sendable`. Nothing else. It is the unit of sync: one record per
   operation, self-contained, orderable, idempotent on replay.

One supporting value type is needed here:

4. **`FracIndex`** — a `Codable`, `Comparable`, `Sendable` struct wrapping a `Double` in
   the range `(0, 1)` exclusive. `between(_ lo: FracIndex, _ hi: FracIndex) -> FracIndex`
   produces the midpoint. Two named boundary anchors handle insertion at the ends, and
   both are **concrete `FracIndex` values inside the open interval, not sentinels** — this
   keeps `between`, `Comparable`, and `Codable` uniform (every `FracIndex`, including the
   anchors, is a real number in `(0, 1)`, so no case in any consumer ever has to special-case
   a magic value):
   - **`FracIndex.first` = `FracIndex(value: 0.25)`** — the anchor to insert *before* the
     current lowest real item. To prepend a new item ahead of an existing lowest item `x`,
     the caller uses `between(.first, x)`; `.first` itself is a valid position when the
     collection is empty or when a single item is placed at the front.
   - **`FracIndex.last` = `FracIndex(value: 0.75)`** — the anchor to insert *after* the
     current highest real item. To append a new item after an existing highest item `x`,
     the caller uses `between(x, .last)`. `.last` is defined as `0.75` (not something ≥ 1)
     precisely so it stays inside `(0, 1)` and `between(x, .last)` is always well-defined
     for any real `x < 0.75`; the append rule is therefore total, deterministic, and needs
     no sentinel branch. (The two anchors `0.25`/`0.75` leave symmetric headroom on both
     ends for the first prepend/append; deeper insertions subdivide from there via
     `between`.)

   When two items land on identical fractions (a degenerate case under extreme
   concurrency), sort breaks ties by the owning id (`zoneId` / `tileId`) — documented and
   deterministic, never random.

No `materialize` function, no apply logic, no store wiring, no transport. This ticket is
precisely scoped: the **envelope and its clock**. Subsequent tickets add the fold, the
register re-models, the tombstone logic, and eventually the transport seam.

The canonical encoding uses `JSONCodec.makeEncoder()` from
`Sources/ContinuumRevivedCore/JSONCodec.swift:4` with `.sortedKeys` already in the
prettyPrinted path. For the op-log's round-trip checks, always use the non-pretty encoder
(the default path at line 8) since key ordering is only guaranteed in the `sortedKeys`
variant — add a dedicated `makeOpLogEncoder()` factory on `JSONCodec` that always forces
`.sortedKeys` regardless of pretty-printing, so canonical encoding is never accidentally
omitted.

## Where it lives

All new symbols live in a single new file:

**`Sources/ContinuumRevivedCore/SpatialOp.swift`** (new file, no new target)

Symbols to define:
- `public struct OpId` — `CanvasState.swift:3` is the reference for what `Codable`
  conformance looks like in this module; follow that pattern exactly.
- `public enum Op` — associated values reference `TileFrame` (`CanvasState.swift:43`,
  defined at `CanvasState.swift:80`), `CanvasViewport` (`CanvasState.swift:27`) is
  intentionally excluded (viewport does not sync per the locked decisions), and
  `RuntimeRef` (`CanvasState.swift:45`) is intentionally absent.
- `public struct LoggedOp`
- `public struct FracIndex`

Supporting change in one existing file:

**`Sources/ContinuumRevivedCore/JSONCodec.swift:3`** — add `makeOpLogEncoder()` as a
new static factory on `JSONCodec`. This is the only modification to an existing file in
this ticket.

Tests live in `ContinuumRevivedCoreChecks` (the existing check target), in a new file
`SpatialOpTests.swift`.

## Implementation breadcrumbs

The following pseudo-code steers the correct pattern. It is not a verbatim
implementation; the real code will have fuller Swift syntax and access modifiers.

```swift
// MARK: - OpId

public struct OpId: Comparable, Codable, Hashable, Sendable {
    public var lamport: UInt64
    public var replica: UUID

    // Total order: lamport first, UUID bytes as tie-breaker.
    // Both components are deterministic across replicas — no wall clock.
    public static func < (lhs: OpId, rhs: OpId) -> Bool {
        if lhs.lamport != rhs.lamport { return lhs.lamport < rhs.lamport }
        // UUID comparison: compare the 16 raw bytes lexicographically.
        return lhs.replica.uuidString < rhs.replica.uuidString
        // Note: uuidString is uppercase and fixed-length, so this IS a
        // stable lexicographic order on the underlying bytes.
    }
}

// MARK: - FracIndex

public struct FracIndex: Comparable, Codable, Sendable {
    // Invariant: 0 < value < 1 (enforced in init with a precondition).
    public var value: Double

    // Boundary anchors. Both are REAL values inside (0, 1), not sentinels:
    //   .first < any typical mid item < .last, with headroom on each end.
    public static let first = FracIndex(value: 0.25)  // insert BEFORE lowest
    public static let last  = FracIndex(value: 0.75)  // insert AFTER highest

    // Produces a value strictly between lo and hi.
    // Callers must ensure lo.value < hi.value; precondition trap in debug.
    public static func between(_ lo: FracIndex, _ hi: FracIndex) -> FracIndex {
        FracIndex(value: (lo.value + hi.value) / 2.0)
    }

    // Append rule (total, deterministic, no sentinel branch):
    //   prepend before existing lowest x  ->  between(.first, x)
    //   append  after  existing highest x ->  between(x, .last)
    //   place into empty collection       ->  .first (or .last; both valid)
    // Because .last = 0.75 < 1, between(x, .last) is well-defined for any
    // real x < 0.75 — the common case — and never needs a >= 1 guard.

    public static func < (lhs: FracIndex, rhs: FracIndex) -> Bool {
        lhs.value < rhs.value
    }

    // Codable: encode as a plain Double — round-trip preserves the value
    // exactly since IEEE 754 Double is what JSONSerialization uses.
}

// MARK: - Op

public enum Op: Codable, Sendable {
    // WIRE FORMAT IS DECIDED, NOT LEFT TO THE IMPLEMENTER (see "Wire format"
    // below): Codable is HAND-WRITTEN. A nested `CodingKeys` enum with an
    // explicit String rawValue per case is the frozen discriminator, and
    // `init(from:)` / `encode(to:)` switch on it. The synthesized conformance
    // is NOT used. The frozen discriminator strings are the table in the
    // "Wire format" section — they are a permanent on-disk API surface.
    // --- Tile lifecycle ---
    case createTile(id: UUID, kind: TileKind, title: String, frame: TileFrame, zIndex: Int)
    case deleteTile(id: UUID)          // delete-wins tombstone; downstream ticket applies

    // --- Zone lifecycle ---
    case createZone(id: UUID, projectId: UUID?, origin: ZonePoint, size: ZoneSize,
                    name: String, color: String)
    case deleteZone(id: UUID)

    // --- Per-field LWW registers on Tile ---
    case setTileFrame(id: UUID, frame: TileFrame)
    case setTileZIndex(id: UUID, zIndex: Int)
    case setTileTitle(id: UUID, title: String)
    case setTileKind(id: UUID, kind: TileKind)
    case setTileCollapsed(id: UUID, collapsed: Bool)

    // --- Per-field LWW registers on Zone ---
    case setZoneOrigin(id: UUID, origin: ZonePoint)
    case setZoneSize(id: UUID, size: ZoneSize)
    case setZoneName(id: UUID, name: String)
    case setZoneColor(id: UUID, color: String)
    case setZoneCollapsed(id: UUID, collapsed: Bool)
    case setZoneProjectId(id: UUID, projectId: UUID?)   // nil = ambient zone

    // --- Z-order (fractional index on zones) ---
    case setZonePosition(id: UUID, position: FracIndex)

    // --- Membership: LWW register ON the tile (not on the zone's array) ---
    // nil = tile is ambient (not in any group zone)
    case setTileZone(tileId: UUID, zoneId: UUID?)

    // --- lastActive pointers (LWW registers) ---
    case setLastActiveTile(id: UUID?)
    case setLastActiveZone(id: UUID?)

    // NOTE: viewport is intentionally absent — it is per-device camera state
    // and explicitly excluded from sync (locked decision D3 / doc-38 E).
    // NOTE: runtimeRef is intentionally absent — it is a host-local handle
    // and its absence here is what makes I5 a compile-time guarantee.
}

// MARK: - LoggedOp

public struct LoggedOp: Codable, Sendable {
    public var opId: OpId
    public var op: Op
}

// MARK: - JSONCodec addition (JSONCodec.swift)

extension JSONCodec {
    /// Returns an encoder suitable for canonical op-log encoding.
    /// Always uses sortedKeys so map-key order is deterministic; never
    /// pretty-prints (the round-trip check compares raw bytes).
    public static func makeOpLogEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
```

## Wire format — DECIDED: hand-written stable discriminators

This is the load-bearing decision this ticket must **close, not punt**, because the
downstream delete-as-tombstone and convergence-fuzz tickets serialize `Op`/`LoggedOp`
values, persist them, and replay them on other replicas. If the on-disk discriminator
were left to Swift's synthesizer, a later refactor (renaming a case, reordering, a
compiler-version change in how associated values nest) could silently invalidate every
stored op. So:

**`Op`'s `Codable` conformance is HAND-WRITTEN.** Do not rely on the synthesized enum
Codable. Define a nested `enum CodingKeys: String, CodingKey` whose rawValue is the
**frozen discriminator string** for each case, plus a nested per-case keyed container for
that case's associated values. `init(from:)` reads the single discriminator key, switches
on it, and decodes the payload; `encode(to:)` mirrors it. An unknown discriminator on
decode **throws** `DecodingError.dataCorrupted` (correct behavior: an old client must
refuse an unknown future op, never silently drop it). This is more verbose than synthesis
and that verbosity is the point — the strings below are a permanent API surface.

**Frozen discriminator table (never change a value in this column; only add rows):**

| `Op` case | Frozen discriminator string | Payload keys (frozen) |
|---|---|---|
| `createTile` | `"createTile"` | `id`, `kind`, `title`, `frame`, `zIndex` |
| `deleteTile` | `"deleteTile"` | `id` |
| `createZone` | `"createZone"` | `id`, `projectId`, `origin`, `size`, `name`, `color` |
| `deleteZone` | `"deleteZone"` | `id` |
| `setTileFrame` | `"setTileFrame"` | `id`, `frame` |
| `setTileZIndex` | `"setTileZIndex"` | `id`, `zIndex` |
| `setTileTitle` | `"setTileTitle"` | `id`, `title` |
| `setTileKind` | `"setTileKind"` | `id`, `kind` |
| `setTileCollapsed` | `"setTileCollapsed"` | `id`, `collapsed` |
| `setZoneOrigin` | `"setZoneOrigin"` | `id`, `origin` |
| `setZoneSize` | `"setZoneSize"` | `id`, `size` |
| `setZoneName` | `"setZoneName"` | `id`, `name` |
| `setZoneColor` | `"setZoneColor"` | `id`, `color` |
| `setZoneCollapsed` | `"setZoneCollapsed"` | `id`, `collapsed` |
| `setZoneProjectId` | `"setZoneProjectId"` | `id`, `projectId` |
| `setZonePosition` | `"setZonePosition"` | `id`, `position` |
| `setTileZone` | `"setTileZone"` | `tileId`, `zoneId` |
| `setLastActiveTile` | `"setLastActiveTile"` | `id` |
| `setLastActiveZone` | `"setLastActiveZone"` | `id` |

The discriminator string is deliberately identical to the current Swift case name so the
table is easy to read, but the binding is now **explicit and frozen** — renaming the Swift
case later leaves the wire string untouched (change the `case` spelling and the `CodingKeys`
rawValue stays put). Payload key names likewise match the associated-value labels and are
frozen. Adding a *new* op is a new row here plus a new `CodingKeys` case; it never touches
an existing row.

Hand-written pattern (pseudo-code — one case shown; every case follows it):

```swift
extension Op {
    private enum CodingKeys: String, CodingKey {
        case createTile, deleteTile, createZone, deleteZone,
             setTileFrame, setTileZIndex, setTileTitle, setTileKind,
             setTileCollapsed, setZoneOrigin, setZoneSize, setZoneName,
             setZoneColor, setZoneCollapsed, setZoneProjectId,
             setZonePosition, setTileZone, setLastActiveTile, setLastActiveZone
        // rawValue == the case name == the FROZEN discriminator string above.
    }
    private enum SetTileFrameKeys: String, CodingKey { case id, frame }
    // ... one payload-key enum per case with associated values ...

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath,
                debugDescription: "Op has no discriminator key"))
        }
        switch key {
        case .setTileFrame:
            let p = try c.nestedContainer(keyedBy: SetTileFrameKeys.self, forKey: .setTileFrame)
            self = .setTileFrame(id: try p.decode(UUID.self, forKey: .id),
                                 frame: try p.decode(TileFrame.self, forKey: .frame))
        // ... every other case, exhaustively ...
        }
        // No `default:` — the switch is exhaustive over CodingKeys, so a new
        // case that forgets a decode arm fails to compile. An unknown STRING
        // (a future op an old client can't name) surfaces as an empty
        // allKeys / a CodingKey the enum can't represent -> the guard/throw
        // above rejects it rather than silently dropping the op.
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .setTileFrame(id, frame):
            var p = c.nestedContainer(keyedBy: SetTileFrameKeys.self, forKey: .setTileFrame)
            try p.encode(id, forKey: .id)
            try p.encode(frame, forKey: .frame)
        // ... every other case, exhaustively ...
        }
    }
}
```

Because every switch above is exhaustive with no `default:`, adding a case to `Op` without
also adding its encode/decode arm is a **compile error**, not a silent data-loss bug — the
same enforced-exhaustiveness discipline the round-trip test relies on.

**On UUID comparison in `OpId`:** `uuidString` produces a canonical uppercase string like
`"6E0D2EBA-…"`, which is fixed-width and character-class-stable (hex digits and
hyphens), so string `<` is equivalent to byte-wise comparison of the UUID. This is
simpler and correct; a raw `uuid_t` tuple comparison is equally valid if preferred.

## How we test it

### Logic (pure Core checks)

All checks are in-process, no daemon, no network, fake clock only. Every assertion
records measured values in its manifest — never `{passed: true}`.

**Round-trip (I7).** For every `Op` case, construct an instance with representative
associated values, encode with `makeOpLogEncoder()`, decode with `makeDecoder()`, and
assert the result is `==` to the original. Cover every case in the enum explicitly — if
a new case is added later and the test is not updated, the exhaustive switch in the test
body will fail to compile. This is the correct failure mode.

**Frozen-discriminator fixture decode (guards wire-format drift).** Decode a **hard-coded
JSON string literal** (not a freshly-encoded value) for at least three representative
cases — one lifecycle (`createTile`), one LWW field-set (`setTileFrame`), and the
membership case (`setTileZone`, whose payload keys are `tileId`/`zoneId`, the one case
whose keys differ from the associated-value id convention). Assert each decodes to the
expected `Op` value under `==`. Because the fixture is a literal string, any future rename
that lets a discriminator or payload key drift makes this test fail loudly instead of
silently following the rename. Also assert that decoding a fixture whose discriminator is
`"setTileFrobnicate"` (a name no case has) **throws** rather than returning a value — the
unknown-op-refusal behavior.

**Ordering.** Assert that `OpId(lamport: 1, replica: A) < OpId(lamport: 2, replica: A)`.
Assert that `OpId(lamport: 2, replica: A) < OpId(lamport: 2, replica: B)` when `A <
B` lexicographically. Assert total order by verifying a shuffled array of `OpId` values
sorts to the expected sequence. Use deterministic fixed UUIDs in the test; no random
seeding needed for ordering correctness.

**FracIndex invariants.** Assert `between(FracIndex(0.25), FracIndex(0.75))` returns
`0.5`. Assert `between(first, first)` traps in debug (precondition). Assert round-trip
via Codable. Assert comparability is transitive over a table of five fixed values.

**I5 structural check.** Write a function `assertNoBannedTypes(_ op: Op)` that mirrors
the op with a reflective approach: encode the op to JSON bytes with `makeOpLogEncoder()`,
then scan the raw string representation for the tokens `"runtimeRef"`, `"%"` (tmux pane
target prefix), `"/Users/"`, `"continuum-"` (session name prefix), `"ssh://"`, and the
`CodingKeys` of `TerminalSessionDescriptor` (`"command"`, `"args"`, `"env"`,
`"scrollback"`). Assert none are present in any encoded `Op` case. Run this over every
case in the round-trip test as a sub-assertion. This is belt-and-suspenders; the real
guarantee is structural (those types are absent from the enum's associated values), but
the scan records measured byte counts in the manifest and will catch a future accidental
regression.

**`makeOpLogEncoder` canonical key order.** Concretely falsifiable, three assertions, no
"when it matters" hand-waving:
1. **Byte-stable across calls.** Encode `LoggedOp(opId: OpId(…), op: .setTileFrame(…))`
   twice with two separate `makeOpLogEncoder()` instances. Assert the two `Data` values
   are byte-identical (`data1 == data2`). This is the core canonical guarantee and is
   directly falsifiable.
2. **Keys are actually sorted.** Take a value with ≥ 2 keys in the *same* container — the
   `frame` and `id` keys inside the `setTileFrame` payload container. Decoding to a
   dictionary would lose order, so assert on the **raw UTF-8 string** of the encoded bytes:
   `"frame"` is lexicographically less than `"id"`, so with `.sortedKeys` the substring
   `"\"frame\""` must appear at an earlier byte offset than `"\"id\""`. Assert
   `bytes.range(of: "\"frame\"") .lowerBound < bytes.range(of: "\"id\"").lowerBound`. This
   is a concrete key-order comparison against a computed-in-the-test expectation, not a
   vague claim.
3. **Same value regardless of encoder.** Encode the same `LoggedOp` with
   `makeEncoder(prettyPrinted: false)` and with `makeOpLogEncoder()`, decode **both** back
   with `makeDecoder()`, and assert the two decoded `LoggedOp` values are `==` to each
   other and to the original. This states the exact expected relationship (both encoders
   are semantically lossless; only the op-log encoder additionally guarantees byte-stable
   canonical ordering) without the unfalsifiable "differs only in key ordering when it
   matters" clause, which is removed.

### Backend (real-path / integration)

This ticket is a pure value-type layer: no I/O, no tmux, no daemon, no network. Per D26
the full three-tier UX-testing contract is scoped to *UX-touching* tickets; a pure
data-layer ticket like this one is **exempt from a UI visual gate** but still owes a
real-path substitute at the backend tier rather than a blank section. The section is
therefore **not empty** — the substitute is stated explicitly:

**Backend-tier stand-in: round-trip through `Data`.** For every `Op` case, encode with
`makeOpLogEncoder()` to `Data`, decode the `Data` back with `makeDecoder()`, and assert
`==` to the original. This is the in-process analogue of the transport path — where an op
arrives as JSON *bytes* from another process — exercising the real hand-written
`init(from:)`/`encode(to:)` on real `Data`, not a hand-wired snapshot. It is labeled in
the test file as the backend-tier stand-in for this data-layer ticket, e.g.
`// Backend stand-in (data-layer ticket): Op round-trips through real Data bytes; the
disk/teardown real-path lives in the convergence-fuzz ticket`.

The *fuller* real-path check — where `LoggedOp` values are written to disk, read back, and
confirmed to survive a client teardown across replicas — lives in the convergence-fuzz
ticket (the RED→GREEN tripwire), which depends on this one. That is the correct home for a
disk/teardown integration test because it needs the `materialize` fold and the fake
transport, neither of which exists yet at this ticket.

### UX (visual gate + dogfood snippet)

This ticket makes no UI change and exposes no app-visible feature, so it is a **data-layer
ticket, UX-exempt** from a *visual* gate under D26 (which scopes the visual-gate + dogfood
contract to UX-touching tickets). The Component Lab visual gate for *sync-derived state*
belongs to the first ticket that surfaces that state in the UI (the activity-surface
ticket, D21); document that with a `// UX visual gate: deferred to the activity-surface
ticket (D21)` comment so a reader knows it is deliberate, not forgotten.

Even though there is no pixel to judge, the section is **not empty** — a concrete,
verifiable dogfood step keeps the ticket honest:

**Dogfood snippet.** From the repo root, run:

```
swift run ContinuumRevivedCoreChecks
```

Watch for the final line `ContinuumRevivedCoreChecks passed`, and directly above it the
I5 manifest line this ticket adds, which must read a real measured value, e.g.
`I5 op-enum scan: 19 cases, 0 forbidden tokens, taint:none (2841 bytes scanned)` — never
`{passed:true}`. Read that `taint:none` entry and confirm the scanned-byte count is
non-zero (a zero-byte scan would be a false green). If any assertion fails, the process
exits non-zero and the failing check name prints to stderr before exit, so a silent false
green is impossible.

## Execution mode

**Autonomous.** Every correctness property this ticket defines is proven by pure in-process
Core checks: the round-trip test exercises `Codable` with no network or daemon, the
ordering test is a pure `Comparable` assertion, and the I5 structural check is a string
scan of encoded bytes. There is no UI change, no tmux interaction, and no CloudKit
dependency. An overnight coding agent can write the code, run the checks, and confirm all
assertions pass without any human eyes or real infrastructure. The convergence fuzz (the
harder end-to-end gate) is a separate ticket that explicitly depends on this one.

## Done when

- [ ] `Sources/ContinuumRevivedCore/SpatialOp.swift` exists and is compiling cleanly
      under Swift 6 strict concurrency (`swift-tools-version 6.0`, `platforms:
      [.macOS(.v14)]` as per `Package.swift`).
- [ ] `OpId` conforms to `Comparable`, `Codable`, `Hashable`, `Sendable`; ordering is
      `(lamport, replica)` lexicographic with no wall clock anywhere in the comparison.
- [ ] `Op` is a closed `Codable Sendable` enum; every case has no associated value drawn
      from `RuntimeRef`, `TerminalSessionDescriptor`, or any host-local handle type.
- [ ] `Op`'s `Codable` is **hand-written** (nested `CodingKeys` with an explicit String
      rawValue per case, exhaustive `init(from:)`/`encode(to:)` with no `default:`), NOT
      synthesized; every discriminator string matches the frozen table in "Wire format".
- [ ] A frozen-discriminator **fixture-decode test** decodes hard-coded JSON string
      literals for `createTile`, `setTileFrame`, and `setTileZone` to the expected `Op`,
      and asserts an unknown discriminator throws.
- [ ] `LoggedOp` is a `Codable Sendable` struct with exactly `opId: OpId` and `op: Op`.
- [ ] `FracIndex` is a `Comparable Codable Sendable` struct; `between` is implemented and
      guarded; both boundary anchors are defined as concrete in-interval values —
      `first == FracIndex(value: 0.25)` and `last == FracIndex(value: 0.75)` — and the
      prepend/append rules (`between(.first, x)` / `between(x, .last)`) are documented in
      the source and covered by a test.
- [ ] `JSONCodec.makeOpLogEncoder()` exists in `JSONCodec.swift`, always uses
      `.sortedKeys`, never pretty-prints.
- [ ] All `Op` cases have explicit round-trip tests with real associated values; the test
      switch is exhaustive (compile fails if a case is missing).
- [ ] Ordering test covers same-lamport/different-replica and different-lamport cases with
      fixed UUIDs.
- [ ] I5 scan runs over every encoded `Op` case and produces a manifest entry recording
      the scanned byte count alongside `taint: none`.
- [ ] `makeOpLogEncoder` canonical-key-order test asserts (1) byte-identical output across
      two calls, (2) a concrete lexicographic key-order comparison on the raw bytes, and
      (3) both encoders decode back to a value `==` the original.
- [ ] Backend-tier stand-in check present and labeled: every `Op` case round-trips through
      real `Data` (encode→bytes→decode) and equals the original.
- [ ] Dogfood snippet holds: `swift run ContinuumRevivedCoreChecks` prints the I5 manifest
      line with a measured non-zero scanned-byte count and `taint:none`, then
      `ContinuumRevivedCoreChecks passed`.
- [ ] No new external dependencies appear in `Package.swift`; `ContinuumRevivedCore` still
      has zero `dependencies:` entries.
- [ ] The build is clean with no warnings under `-strict-concurrency=complete`.

## Depends on / unblocks

This ticket depends on the store-protocol seam having landed, because it references
`TileFrame`, `TileKind`, `ZonePoint`, and `ZoneSize` — types that live in
`ContinuumRevivedCore` and must be stable before `SpatialOp.swift` can import them
without a cycle risk. In practice, those types are already present in `CanvasState.swift`
(see `TileFrame` at line 80, `TileKind` at line 41), so the dependency is on the seam
being merged and the core target building cleanly, not on those types being new.

This ticket directly unblocks three downstream foundation tickets: membership as a
tile-level LWW register (which implements `setTileZone` semantics), z-order as a
fractional index (which implements `setZonePosition` and `FracIndex` application), and
delete as a tombstone (which implements the delete-wins policy for `deleteTile` and
`deleteZone`). It also unblocks the op-log apply and compaction ticket, the convergence
fuzz, and the sync/observation type split — all of which generate or process `LoggedOp`
values.

## Watch out for

**The hardest thing: keeping the frozen wire format actually frozen.** The wire-format
fork is already **closed** in the "Wire format" section — `Op`'s Codable is hand-written
with the explicit frozen discriminator table, not synthesized, precisely because a
synthesized format is fragile across schema evolution (a renamed case or a
compiler-version change in associated-value nesting would silently invalidate every stored
op — a data-loss event). What remains a hazard is *drift*: an implementer editing a case
later and letting the discriminator string track the rename. Guard it two ways. (1) The
frozen discriminator table above is the contract; a `CodingKeys` rawValue must never change
value, only new rows may be added. (2) Add the **JSON-fixture decode test** (see the tests
section): decode a hard-coded JSON string literal — not a freshly-encoded value — for at
least one representative case, and assert it decodes to the expected `Op`. A freshly-encoded
round-trip would silently follow a rename; a frozen string literal will not, so it fails
loudly the moment a discriminator drifts.

**`FracIndex` precision exhaustion.** Repeated `between` calls halve the interval each
time. After roughly 52 calls on the same interval, the midpoint equals one of the
endpoints in IEEE 754 Double arithmetic. The test must include an assertion that after N
`between` calls starting from `(0.25, 0.75)` the result is strictly between the inputs
for reasonable N (say, 40), and that the function does not silently return a boundary
value. The production mitigation for deep-fractional-index exhaustion (re-indexing when
the interval collapses) is a separate concern that belongs to the apply/compaction
ticket, but the test should at least document the limit.

**Wall-clock contamination.** The ban on wall-clock ordering is load-bearing. Search the
`SpatialOp.swift` implementation for any use of `Date`, `CFAbsoluteTime`, `clock()`,
`DispatchTime.now()`, or `ContinuousClock`. There must be none. The check harness should
include a `grep`-level assertion in CI that the file contains no such references — a
comment is insufficient because a future edit could slip one in.

**`ContinuumRevivedCore` must remain dependency-free.** `Package.swift` currently declares
`ContinuumRevivedCore` with no `dependencies:` array. Adding `import` of any external
module (Loro, Automerge, or anything else) in `SpatialOp.swift` would silently satisfy
the compiler but break this invariant, causing the CRDT-fallback story to collapse (the
whole point of the op-log choice is that it is pure Swift). The done criteria includes a
CI check that the `dependencies:` array for `ContinuumRevivedCore` in `Package.swift`
remains empty.

**Do not add `Tile.zoneId` to `CanvasState` in this ticket.** The `setTileZone` op is
defined here as a future-looking type, but the actual re-modeling of `Tile` to carry a
`zoneId: UUID?` field happens in the membership-register ticket that depends on this one.
Defining the op shape now and the model change later is intentional: it keeps this ticket
narrowly scoped to the envelope, and it means the register ticket can be cleanly
diffed without op-type noise mixed in.

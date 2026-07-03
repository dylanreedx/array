# Convergence fuzz: write the I4 RED→GREEN tripwire before any transport

## What this delivers

This ticket establishes the mandatory safety gate for the entire sync program: a seeded,
deterministic, N-replica convergence fuzz that asserts byte-identical state across all
replicas after any combination of random operation ordering, network partitioning, message
reordering, duplication, and offline/reconnect cycles. It runs entirely in-process against
the pure op-log core with no real transport, no real clock, and no real tmux.

When the fuzz goes green, the op-log's deterministic merge is proven, not assumed. If it
cannot be made to go green under the pinned stop rule below, that is the concrete trigger to
measure the Loro linked-app-size delta and fall back to the Loro 1.x MovableList path. Either
outcome is valuable; no outcome is left ambiguous.

The system outcome is that nobody ever commits transport code — CloudKit, WebSocket, or
anything else — before the merge model has been hammered against adversarial message
interleavings. That ordering is the difference between a sync layer that is provably
correct and one that has sync bugs forever.

## How it fits

This ticket sits at the end of the op-log core sequence. It directly depends on the
op-log apply and compaction ticket, which in turn depends on the membership-as-LWW-register,
z-order-as-fractional-index, and delete-as-tombstone re-modeling tickets, which in turn
depend on the op enum and logged-op envelope ticket. All of those must be green and merged
before this fuzz is written, because the fuzz drives the actual `materialize` and `apply`
functions — it is not a mock of the merge, it is the real merge under adversarial
conditions.

What this unblocks: everything in the sync and transport column. The sync/observation type
split ticket, the transport seam ticket, the CloudKit transport implementation, and the
transport fuzz and nightly soak all have this ticket as a prerequisite in their dependency
chain. More broadly, no Phase 1 or later ticket that relies on sync correctness should ship
until this fuzz is green.

## The fuzz parameters (the single normative source)

These four numbers are authoritative for this ticket. Every other section — the breadcrumb,
the "How we test it" section, the Done-when list, and the Loro-fallback stop rule — refers
back to exactly these values. If any two places disagree, this block wins.

- **Seed range: `1 ... 50` inclusive** (50 deterministic seeds).
- **Steps per seed: `200`** (a fixed `stepCount`, identical for every seed).
- **Replica count per seed: `2 ... 5` inclusive**, drawn once per seed from that seed's RNG
  (`Int.random(in: 2 ... 5, using: &rng)`), so the count is itself reproducible from the seed.
- **Compaction probability: 1-in-20 per step** (see the breadcrumb), which the Done-when list
  requires to actually fire in at least 30 of the 50 seeds.

Whenever a later paragraph says "across all seeds" or "the full seed range," it means exactly
`1 ... 50` as pinned here — there is no second, looser range anywhere in this ticket.

## The approach

Write the fuzz as a named block inside
`Sources/ContinuumRevivedCoreChecks/main.swift`, following the same `do { … }` structure
every other check block uses. The fuzz is seeded so that any failing seed reproduces
deterministically and can be bisected. It drives N replicas (N drawn from 2 through 5
inclusive, determined by the seed, per the parameters block above) through 200 random steps,
where each step picks a random replica and a random legal spatial operation against that
replica's current materialized state — create, delete, move, resize, z-order change,
membership change — expressed as calls through the actual `Op` enum and `materialize`
function from the op-log core, never hand-built synthetic states.

Between steps, a fake in-process transport delivers some queued messages in random order,
drops some, duplicates some, and randomly toggles replicas offline. After the 200 steps,
every replica reconnects and the transport drains completely. The fuzz then asserts that the
canonical encoding of each replica's materialized state is byte-identical across every
replica. It also asserts the domain invariants hold on each replica's materialized state:
every tile belongs to at most one zone, no tombstoned id appears in the live tile set, the
zone z-order list is a permutation of live zones, and no orphaned group member references a
deleted tile.

Compaction is exercised inside the fuzz: at a random step a randomly selected replica
compacts its log — folding everything at or below a low-water mark into a snapshot and
keeping only the ops above it — and the fuzz continues. The compacted replica must still
converge byte-identically with non-compacted replicas — this proves that compaction is
merge-equivalent. Crucially, a compacted replica is no longer represented by a bare `[LoggedOp]`
log; it is represented by the pair `(snapshot, tail)`, and its materialized state is computed by
folding the tail atop the snapshot's state. The exact mechanism the fuzz uses for this is fixed
by the op-log apply and compaction ticket and is spelled out in "Where it lives" and the
breadcrumb below — the fuzz does not invent its own snapshot-handling.

The Loro fallback signal is explicit and countable (see the pinned stop rule in "Watch out
for"): if, after the single allowed merge-policy fix, any seed in `1 ... 50` still diverges,
that is the trigger to stop, measure the Loro linked-app-size delta against a real Continuum
`.app` build (not the multi-platform compressed zip), and switch the op-log core to Loro 1.x
with its MovableList. The seam is the same either way; the transport code does not care.

## Where it lives

All new code lives in `Sources/ContinuumRevivedCoreChecks/main.swift`, added as a new
`do { }` block before the final `print("ContinuumRevivedCoreChecks passed")` line at
line 5627. The block imports nothing beyond what is already in scope; it drives the
types from the op-log core tickets (which land in the `ContinuumRevivedSync` target that
depends on `ContinuumRevivedCore`).

The op-log types this fuzz exercises come from the op-log core tickets. Their exact
signatures are owned by those tickets; this ticket consumes them verbatim and must not
redefine them:

- `OpId` (Lamport `UInt64` + `replicaId` UUID, compared lexicographically for a total order)
  — introduced by the op enum ticket
- `Op` (the closed spatial op enum) — introduced by the op enum ticket
- `LoggedOp` (self-contained envelope: `{ opId: OpId, op: Op }`) — introduced by the op enum
  ticket
- `materialize(ops: [LoggedOp]) -> MaterializedState` — introduced by the op-log apply
  ticket. `MaterializedState` wraps the rebuilt `CanvasState` + `WorkspaceDocument`.
  **There is no snapshot parameter**: a full-log replica materializes from its whole log;
  a compacted replica materializes by folding its *tail* atop the *snapshot's state* (below).
- `compact(log: [LoggedOp], through lowWaterMark: UInt64) -> CompactionResult` — introduced by
  the op-log apply and compaction ticket. `CompactionResult` has two members:
  `snapshot: CompactedSnapshot` and `tail: [LoggedOp]`. `CompactedSnapshot` is a `Codable`
  struct carrying the folded `MaterializedState` plus a `compactionOpId: OpId` marking the
  highest op folded in. The low-water mark is a Lamport `UInt64`, **not** an `OpId`.
- `applySnapshot(_ snapshot: CompactedSnapshot, ontop localLog: [LoggedOp]) -> [LoggedOp]` —
  introduced by the same ticket. It drops any local op at or below `snapshot.compactionOpId`
  and returns the surviving tail. A compacted replica's effective state is then
  `materialize(ops:)` applied to that tail, *layered on top of* `snapshot.state`. This is the
  one and only way a compacted replica re-incorporates pre-watermark state into its
  materialized value — the fuzz must use it, not re-fold a truncated log.

The existing spatial types being operated on (read from `CanvasState.swift` lines 3–199 and
`WorkspaceDocument.swift` lines 13–160):
- `CanvasState` (`CanvasState.swift:3`) — `tiles: [Tile]`, `groups: [TileGroup]`,
  `viewport: CanvasViewport`
- `Tile` (`CanvasState.swift:39`) — `id: UUID`, `frame: TileFrame` (`CanvasState.swift:80`),
  `zPosition: FracIndex` (re-modeled from the old `zIndex: Int` by ticket 04), `runtimeRef: RuntimeRef?` (excluded from sync ops by the
  boundary-purity constraint, never appears in an `Op`, always `nil` in materialized output)
- `TileGroup` (`CanvasState.swift:190`) — `id: UUID`, `tileIds: [UUID]` (`:193`, superseded
  by the membership register; the fuzz operates on the re-modeled membership, not this list)
- `WorkspaceDocument` (`WorkspaceDocument.swift:13`) — `zones: [ZonePlacement]` (`:18`),
  `zoneZOrder: [UUID]` (`:19`), re-modeled to fractional-index ops
- `ZonePlacement` (`WorkspaceDocument.swift:147`) — `zoneId: UUID` (`:148`),
  `origin: ZonePoint` (`:150`), `size: ZoneSize` (`:151`)

**Codable is already in place — do not add it, only audit key order.** `WorkspaceDocument`
already conforms to `Codable` via an explicit extension at `WorkspaceDocument.swift:121` with
a hand-written `CodingKeys`; `ZonePlacement` likewise at `WorkspaceDocument.swift:181`; and
`ZonePoint` (`:213`), `ZoneSize` (`:223`), `GroupZoneTiles` (`:3`), `ZoneHydrationPolicy`
(`:233`) all conform to `Codable` in the repo today. `CanvasState` and its members are
Codable as well (they are persisted as `canvas.json`). No ticket needs to add conformance and
this ticket does not add any — the conformances exist. What the canonical-encoding audit in
"Watch out for" checks is *field/key ordering* within those already-present `CodingKeys`, not
the presence of conformance.

The fake in-process transport is defined inline inside the fuzz block — it is a simple
`[String: [LoggedOp]]` queue dictionary, one queue per ordered replica pair, with a
`FakeTransport` struct that implements `goOffline`, `reconnect`, `deliverSome(rng:)`,
and `drainAll`. It is not promoted to a shared type in this ticket; the reusable
`SyncTransport` protocol (the transport abstraction) and its full production fake belong to
the transport seam ticket, not here.

The `CanvasEngine` static functions (`Sources/ContinuumRevivedCore/CanvasEngine.swift:11`)
are not modified by this ticket; the fuzz does not need geometry or coordinate conversion.

## Implementation breadcrumbs

```swift
// -- inside main.swift, before the final print --

// MARK: - convergence fuzz (the I4 tripwire)

do {
    // Deterministic RNG seeded per run; a failing seed reproduces exactly.
    struct LCG: RandomNumberGenerator { /* 64-bit LCG, seeded */ }

    // A replica is EITHER a full log, OR a compacted (snapshot, tail) pair.
    // Modeling both explicitly is what keeps materialization honest post-compaction.
    struct FakeReplica {
        let replicaId: UUID
        var lamport: UInt64 = 0
        var log: [LoggedOp] = []                 // the tail once compacted; the full log until then
        var snapshot: CompactedSnapshot? = nil   // nil until this replica has compacted at least once
        var isOnline: Bool = true

        // Apply one op locally, advancing the Lamport clock.
        mutating func apply(_ op: Op) -> LoggedOp {
            lamport += 1
            let logged = LoggedOp(opId: OpId(lamport: lamport, replica: replicaId), op: op)
            log.append(logged)
            return logged
        }

        // Merge incoming ops; advance clock on receipt; ignore ops already folded into a snapshot.
        mutating func receive(_ incoming: [LoggedOp]) {
            for logged in incoming {
                if let snap = snapshot, logged.opId <= snap.compactionOpId { continue }  // already folded
                if log.contains(where: { $0.opId == logged.opId }) { continue }          // duplicate
                lamport = max(lamport, logged.opId.lamport) + 1
                log.append(logged)
            }
        }

        // Materialize the effective state: fold the tail atop the snapshot's state if compacted,
        // else fold the whole log. This is the ONLY convergence-safe materialization for a
        // compacted replica — a bare materialize(ops: log) would omit all pre-watermark state.
        var materializedState: MaterializedState {
            if let snap = snapshot {
                return materialize(ops: log, ontop: snap.state)   // tail folded atop snapshot state
            } else {
                return materialize(ops: log)
            }
        }
    }

    struct FakeTransport {
        // Pending deliveries: "from-to" -> [LoggedOp]
        var queues: [String: [LoggedOp]] = [:]

        mutating func enqueue(_ op: LoggedOp, from: UUID, to: UUID) {
            queues["\(from)-\(to)", default: []].append(op)
        }

        // Deliver between 0 and queues[key].count messages, GENUINELY shuffled with the seeded RNG.
        // May duplicate with probability dupChance. Must not deliver in enqueue order.
        mutating func deliverSome(rng: inout LCG, dupChance: Double = 0.05) -> [LoggedOp] { … }

        mutating func drainAll() -> [LoggedOp] { /* return + clear all queued ops */ }
    }

    // Generate a random legal Op against the current materialized state of a replica.
    // Legal = not creating a duplicate id, not deleting a non-existent id, etc.
    func randomOp(rng: inout LCG, state: CanvasState) -> Op {
        // Pick from: createTile / deleteTile / setTileFrame / setTileZIndex /
        //            setTileZone / setZoneOrigin / setZoneSize / setZonePosition
        // Weight toward moves (most common real op).
        // If no live tiles exist, force createTile.
        …
    }

    // Run the pinned seed range 1 ... 50.
    for seed: UInt64 in 1 ... 50 {
        var rng = LCG(seed: seed)
        let replicaCount = Int.random(in: 2 ... 5, using: &rng)   // pinned N range, seed-determined
        var replicas = (0 ..< replicaCount).map { _ in FakeReplica(replicaId: UUID()) }
        var transport = FakeTransport()

        let stepCount = 200                                       // pinned step count

        for _ in 0 ..< stepCount {
            // Pick a random online replica.
            guard let idx = replicas.indices.filter({ replicas[$0].isOnline }).randomElement(using: &rng) else { continue }
            let canvas = replicas[idx].materializedState.canvas
            let op = randomOp(rng: &rng, state: canvas)
            let logged = replicas[idx].apply(op)

            // Broadcast to all other replicas via the fake transport.
            for other in replicas.indices where other != idx {
                transport.enqueue(logged, from: replicas[idx].replicaId, to: replicas[other].replicaId)
            }

            // Deliver some queued messages (may be reordered / duped / dropped).
            let delivered = transport.deliverSome(rng: &rng)
            for msg in delivered {
                for r in replicas.indices { replicas[r].receive([msg]) }
            }

            // Randomly toggle one replica offline / back online.
            if Bool.random(using: &rng), let toggle = replicas.indices.randomElement(using: &rng) {
                replicas[toggle].isOnline.toggle()
            }

            // Occasionally compact a random replica (1-in-20 per step — the pinned probability).
            // compact returns (snapshot, tail); store BOTH — never assign a tuple to `log`.
            if Int.random(in: 0 ..< 20, using: &rng) == 0, let ci = replicas.indices.randomElement(using: &rng) {
                // Conservative low-water mark: a Lamport at or below every op this replica has
                // both received AND could have acked. The oldest op's Lamport is always safe here
                // because nothing below it can still be in flight to THIS replica.
                let mark: UInt64 = replicas[ci].log.map { $0.opId.lamport }.min() ?? 0
                let result = compact(log: replicas[ci].log, through: mark)
                replicas[ci].snapshot = result.snapshot   // fold-below-mark state
                replicas[ci].log = result.tail            // ops above the mark
            }
        }

        // Settle: reconnect all, drain transport, equalize logs.
        for i in replicas.indices { replicas[i].isOnline = true }
        let remaining = transport.drainAll()
        for msg in remaining {
            for i in replicas.indices { replicas[i].receive([msg]) }
        }
        // Forward every replica's full effective log to every other replica (simulates full sync).
        // A compacted replica also ships its snapshot; the receiver folds it via applySnapshot.
        for i in replicas.indices {
            if let snap = replicas[i].snapshot {
                for j in replicas.indices where j != i {
                    replicas[j].log = applySnapshot(snap, ontop: replicas[j].log)
                    replicas[j].snapshot = replicas[j].snapshot ?? snap  // adopt if not already compacted past it
                }
            }
            for j in replicas.indices where j != i {
                replicas[j].receive(replicas[i].log)
            }
        }

        // Assert I4: byte-identical canonical encoding of each replica's EFFECTIVE state
        // (tail-folded-atop-snapshot for compacted replicas, full-log fold otherwise).
        let encodings = replicas.map { canonicalEncode($0.materializedState) }
        for enc in encodings.dropFirst() {
            expect(enc == encodings[0], "I4 violated: seed \(seed) — replicas diverged after settle")
        }

        // Assert domain invariants on every replica's materialized state.
        for replica in replicas {
            let canvas = replica.materializedState.canvas
            let liveIds = Set(canvas.tiles.map(\.id))
            // Tombstoned tiles must not appear in the live set (delete-wins).
            let tombstones = replica.log.compactMap { if case .deleteTile(let id) = $0.op { return id } else { return nil } }
            for t in tombstones {
                expect(!liveIds.contains(t), "domain: tombstoned tile \(t) resurrected — seed \(seed)")
            }
            // Each tile appears in at most one zone's derived member list.
            var seenInZone: [UUID: UUID] = [:]  // tileId -> zoneId
            for tile in canvas.tiles {
                if let z = derivedZone(for: tile.id, in: replica) {
                    if let prev = seenInZone[tile.id] {
                        expect(prev == z, "domain: tile \(tile.id) in two zones — seed \(seed)")
                    }
                    seenInZone[tile.id] = z
                }
            }
        }
    }
}
```

Two upstream affordances the breadcrumb assumes, both owned by the op-log apply and
compaction ticket (and used here, not defined here): a `materialize(ops:ontop:)` overload that
folds a tail atop a snapshot's `MaterializedState`, and `applySnapshot(_:ontop:)`. If the
upstream ticket exposes these under slightly different names, this fuzz calls whatever those
tickets actually shipped — the contract is "fold the tail atop the snapshot," not the exact
spelling. The one thing that must never happen is materializing a compacted replica from its
truncated log alone; that would omit pre-watermark state and is the failure gaps 5 and 6 warn
against.

The `canonicalEncode` function takes a `MaterializedState` (the `CanvasState` +
`WorkspaceDocument` pair) and encodes it with `JSONEncoder` using `.sortedKeys` output
formatting and a stable numeric encoding (no locale-dependent floats). This produces the
literal bytes the convergence assertion compares — the "byte-identical" claim is against these
bytes, not against `Equatable` equality, because `Equatable` would not catch a
reordered-but-equal-value struct field if the encoding were non-canonical.

## How we test it

### Logic (pure Core checks)

The fuzz block itself is the logic test. It lives in
`Sources/ContinuumRevivedCoreChecks/main.swift` and runs on every `swift run
ContinuumRevivedCoreChecks` invocation. It covers the pinned parameters: 50 deterministic
seeds (`1 ... 50`), 2–5 replicas each, 200 random steps per seed, with compaction exercised
randomly mid-run at the 1-in-20-per-step probability. Each seed asserts both byte-identity and
domain invariants (no resurrection, membership uniqueness).

A failing seed must print the seed value before the `expect` call terminates the process,
so the reproducer is always one re-run away with `seed = <n>` hard-coded.

One additional targeted logic test validates `canonicalEncode` stability: encode the same
`MaterializedState` twice from two different in-memory representations that are semantically
equal but constructed differently, and assert the bytes are identical. This rules out
hash-map non-determinism leaking into the encoding.

A second targeted logic test validates the compacted-replica materialization path directly:
build one log, compact it at a mid-log low-water mark, then assert that folding the tail atop
the snapshot state produces the *same* canonical bytes as materializing the full uncompacted
log. This is the pointed check that a compacted replica re-incorporates pre-watermark state —
it fails loudly if the snapshot is ever dropped on the floor.

### Backend (real-path / integration)

The backend obligation for this ticket is narrow and proves one specific thing: that the
`materialize` function, when driven through ops that were round-tripped through `Codable`
serialization (JSON encode → decode → re-apply), still produces byte-identical output to
the in-memory path. This is the real-path check because it simulates the actual transport
path, where ops arrive as JSON bytes from a different process.

Concretely: take one completed fuzz run (seed 1), serialize every `LoggedOp` to JSON,
decode them back, pass them to `materialize`, and assert the canonical encoding matches
the in-memory result. This catches any `Codable` round-trip bug in the op types before
transport work begins.

This check also lives in `ContinuumRevivedCoreChecks/main.swift`. It is not a happy-path
bypass: the ops go through the full `JSONEncoder`/`JSONDecoder` round-trip with the real
`Codable` implementation, not a hand-wired snapshot.

### UX (visual gate + dogfood snippet)

The fuzz produces no UI change and runs no UI code. The visual gate is the CI matrix: the
check target must build and exit zero. The non-degenerate gate is the manifest printed by
the check: after the fuzz block, print a one-line manifest recording the number of seeds
run, the number of total steps, the number of compaction events exercised, and — crucially
— the byte length of the canonical encoding for seed 1. A manifest that reads
`convergence fuzz: 50 seeds × 200 steps, 47 compactions, canonical 2841 bytes` is a real
measurement, not `{passed:true}`.

The dogfood snippet is: open the terminal, run `swift run ContinuumRevivedCoreChecks` from
the repo root, and observe the final line `ContinuumRevivedCoreChecks passed` with the
convergence-fuzz manifest line appearing just above it. If any seed diverges, the process
exits non-zero and the failing seed number appears in stderr before the exit — no silent
false green is possible.

## Execution mode

**Autonomous.** The fuzz is pure in-process Swift: a seeded RNG, fake replicas, a fake
transport, and the real `materialize`/`compact`/`applySnapshot` functions from the op-log
core. It requires no real tmux daemon, no real CloudKit account, no real iOS device, no live
agent, no human eyes. The CI matrix is necessary and sufficient — a green matrix exit is the
gate, with the byte-count manifest as the non-degenerate measurement. No visual judgment is
required because the fuzz produces no pixels.

The one place a human decision could theoretically enter — "is the merge close enough, keep
going or fall back to Loro?" — is removed by the countable stop rule in "Watch out for": the
agent decides deterministically (one policy fix allowed; if a seed in `1 ... 50` still
diverges after it, stop and signal fallback). No judgment call remains.

## Done when

- [ ] `swift run ContinuumRevivedCoreChecks` exits zero with all 50 seeds (`1 ... 50`)
  converging and the convergence-fuzz manifest line printed, on both Apple Silicon and Intel
  (x86_64) CI runners.
- [ ] The manifest reports a non-zero byte count for the canonical encoding (not
  `{passed:true}` — a real measured value appears).
- [ ] The Codable round-trip backend check passes: ops serialized to JSON and deserialized
  produce byte-identical canonical output.
- [ ] Compaction is exercised in at least 30 of the 50 fuzz seeds (the manifest counts this),
  and the compacted-replica materialization check (tail folded atop snapshot == full-log fold)
  passes.
- [ ] A deliberate seed-1 regression test is present: the canonical encoding for seed 1 is
  checked against a hard-coded expected byte count (± 0%), so any future change to the
  `Op` enum or `materialize` logic that silently changes the output is caught immediately.
- [ ] If the pinned stop rule fires (below), the ticket exits with a written fallback
  recommendation naming the Loro linked-app-size delta measurement as the immediate next step,
  and no transport work has been merged.

## Depends on / unblocks

Depends directly on the op-log apply and compaction ticket, which provides `materialize`,
`compact`, and `applySnapshot`. That ticket in turn depends on the membership-as-LWW-register
ticket (which re-models `TileGroup.tileIds` into per-tile `setTileZone` ops), the
z-order-as-fractional-index ticket (which re-models `WorkspaceDocument.zoneZOrder` into
`setZonePosition` ops with `FracIndex`), and the delete-as-tombstone ticket. All of those
depend on the op enum and logged-op envelope ticket. This fuzz cannot be written until
every one of those is in place, because the fuzz calls the real merge functions, not stubs.

Unblocks: the sync/observation type split ticket, the sync-transport seam ticket, the
CloudKit transport implementation, the transport fuzz and nightly soak, and by extension the
entire Phase 6 sync and multi-device work. None of those should be started before this fuzz
is green, because a transport built on a diverging merge is a permanent liability.

## Watch out for

**The hardest thing to get right is canonical encoding non-determinism.** `JSONEncoder`
with `.sortedKeys` is deterministic for `Dictionary` keys, but if any `Op` case carries a
type that encodes its own fields via a custom `encode(to:)` without an explicit key order,
the encoded bytes can differ between otherwise-equal values. Before asserting byte
identity, audit every associated value type in the `Op` enum — `TileFrame`, `ZonePoint`,
`ZoneSize`, `FracIndex`, `Scalar` — and confirm each encodes with explicit `CodingKeys` in
a stable order and that floating-point values use a fixed precision strategy (e.g., no
`Double` encoded as-is via `KeyedEncodingContainer.encode(_:forKey:)` without rounding to
a canonical number of significant digits). `ZonePoint` (`WorkspaceDocument.swift:213`) and
`ZoneSize` (`:223`) already conform to `Codable`; `WorkspaceDocument` (`:121`) and
`ZonePlacement` (`:181`) already have hand-written `CodingKeys` — so the audit is verifying
that those existing key declarations impose a stable order and canonical float formatting,
**not** adding conformance (it is already present; see "Where it lives"). The `TileFrame`
struct at `CanvasState.swift:80` uses synthesized `Codable` today; verify field declaration
order is the canonical encoding order, or add an explicit `CodingKeys`.

**Delete-wins is a policy, not a math fact.** The fuzz will go green for either
delete-wins or resurrect-on-edit, as long as the policy is applied consistently. What the
fuzz cannot catch is applying delete-wins in some code paths and resurrect in others
(e.g., if a `setTileFrame` op is applied before the tombstone-check in `materialize`). The
`materialize` function must check the tombstone set before emitting any live tile, regardless
of the Lamport ordering of the incoming ops. Write a targeted single-case check that
applies ops in the order [setTileFrame(A), deleteTile(A), setTileFrame(A) again] and
asserts tile A is not present in the output — this is the move-vs-delete regression, and
it should live as its own named block before the full fuzz.

**The fake transport must not accidentally serialize delivery.** If `deliverSome` always
delivers messages in the order they were enqueued, the fuzz only tests in-order delivery,
which is the easy case. The fake must genuinely shuffle the pending queue subset it
chooses to deliver for each call — use the seeded RNG for this shuffle, so failures
reproduce.

**Compaction watermark semantics must be exact.** Compaction folds all ops with a Lamport
at or below the low-water mark into the snapshot, discards those ops from the log, and keeps
ops above the mark as the tail. If the mark is computed incorrectly (e.g., a mark higher than
some op still in flight to another replica), a compacted replica may discard ops that another
replica receives later, causing divergence. Use a conservative mark that is provably at or
below every op the replica has both received and could have acked; the breadcrumb uses the
oldest-held op's Lamport, which is always safe because nothing below it can still be in flight
to that replica. A compacted replica must always re-incorporate its snapshot via the
`(snapshot, tail)` pair — never materialize from the truncated tail alone.

**Stop condition for the Loro fallback — a single countable rule (this is authoritative).**
The agent gets **exactly one** merge-policy fix attempt. Concretely:
1. Run the full fuzz over seeds `1 ... 50`. If all 50 converge, the ticket is green; stop
   here, no fallback.
2. If any seed diverges, you may apply **one** merge-policy change (one commit, touching the
   merge/`materialize`/reducer logic) to try to fix it. Record the failing seed(s), the
   violated invariant, and the two diverging canonical encodings first.
3. Re-run the full fuzz over seeds `1 ... 50`. If all 50 now converge, the ticket is green.
4. If **any** seed in `1 ... 50` still diverges after that one fix, **stop immediately** and
   signal the Loro fallback: write up the reproduction (seed, violated invariant, the two
   diverging states), name the Loro linked-app-size delta measurement as the immediate next
   step, and merge no transport code.

This is a hard count — one fix attempt, then a binary all-50-converge check — not a judgment
about "non-trivial" patches or a day-of-effort budget. An unattended agent can decide
deterministically whether it is at step 3-green or step 4-fallback with no human input. The
whole point of writing this fuzz first is to get this signal cheaply, before transport code
exists that would need to be reworked.

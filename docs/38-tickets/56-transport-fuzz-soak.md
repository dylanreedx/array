# Transport fuzz & soak: drive convergence through the fake transport and record a latency budget

## What this delivers

The transport seam ticket installs `SyncTransport` as a real protocol and gives the
convergence fuzz its first `FakeSyncTransport` to lean on. This ticket takes that seam
and pushes it hard: it rewires the existing in-fuzz transport simulation to run through
the real `FakeSyncTransport` implementation, then extends the suite with a nightly soak
that runs hundreds of additional random-op / random-network iterations and records two
concrete budgets — the maximum convergence latency across all network topologies (measured
in simulated logical time, not wall time) and the maximum log length seen before
compaction flushes. Those numbers become the baseline that every future change must
defend.

From a system perspective this ticket proves that the merge model and the transport
abstraction fit together correctly: that handing ops to a `SyncTransport.push` call and
receiving them asynchronously via `SyncTransport.subscribe` produces the same byte-
identical outcome that the lower-level in-memory fuzz already demonstrated. The earlier
convergence fuzz proved the op-log core in isolation; this ticket proves the same core
exercised through the real transport seam. Any discrepancy between the two is a bug in
the seam wiring, not in the merge itself — and that distinction is exactly what makes the
split worth having.

## How it fits

This ticket sits directly after the transport seam ticket, which defines the
`SyncTransport` protocol and the `FakeSyncTransport` with its four configurable network
modes (`.reliable`, `.partition`, `.reorder(seed:)`, `.lossy(dropRate:)`). It also
depends on the convergence fuzz, which established the N-replica, seeded, adversarial
convergence check and defined `canonicalEncode`, `materialize`, and `compactLog`. Both
of those must be merged and green before this work begins; the transport fuzz is not a
replacement for the convergence fuzz — it is an additional layer on top of it.

What this ticket unblocks: the CloudKit transport implementation. That ticket commits
real CloudKit code for the first time, and the risk it carries is not the CloudKit API
itself but the assumption that the real delivery path is semantically equivalent to the
fake. The manifest produced by this soak — concrete measured budgets, not `{passed:true}`
— is the baseline against which the CloudKit real-path check is held. Without that
baseline, the CloudKit ticket has no anchor for "convergence latency acceptable."

The connection supervisor also references the transport seam, and the soak's
offline/reconnect scenarios are the in-process stand-in for what the supervisor will
handle against a real network. Passing this soak is a necessary condition before the
supervisor's reconnect state machine is worth specifying in detail.

## The approach

The existing convergence fuzz block in `ContinuumRevivedCoreChecks/main.swift` contains
an inline `FakeTransport` struct that was defined locally for that fuzz, independent of
the `FakeSyncTransport` type defined by the transport seam ticket. This ticket replaces
that inline struct with the real `FakeSyncTransport` from `ContinuumRevivedCore`, then
adds a second, heavier soak block that runs a much larger iteration budget and records
the latency and log-length measurements in the manifest.

The seam-level difference matters: the convergence fuzz previously called `deliverSome`
directly on a local queue struct. The transport-fuzz version calls `transport.push(op)`
to emit an op and receives it via a registered `transport.subscribe` handler — exactly
the interface the CloudKit implementation will use. The fake's internal delivery still
happens synchronously in the check harness (no actual async dispatch), but the call
surface is the real protocol boundary.

The soak runs 500 seeds, 5 replicas each, 400 steps per seed. Network mode is chosen
per-seed from the full `TransportMode` distribution: roughly 30% `.reliable`, 30%
`.reorder`, 20% `.lossy(dropRate: 0.2)`, and 20% `.partition` (with a reconnect after
a partition). At settlement, convergence is asserted byte-identically as before. The
maximum number of logical-time steps between an op's emission and the last replica
receiving it is tracked per-run; the maximum across all 500 seeds is the convergence
latency budget. The maximum log length seen immediately before compaction triggers across
all seeds is the compaction-pressure budget. Both numbers appear in the manifest.

The "nightly" qualifier in the architecture doc refers to the intent that the full
500-seed soak may be too slow for the standard `swift run ContinuumRevivedCoreChecks`
invocation. The implementation gates the soak behind an environment variable:
`CONTINUUM_SOAK=1 swift run ContinuumRevivedCoreChecks` runs the full 500-seed suite;
the standard invocation runs only the first 50 seeds of the soak at 200 steps each (the
same shape as the existing convergence fuzz) so the normal check remains fast. The CI
matrix runs the standard suite on every push; the nightly CI job sets `CONTINUUM_SOAK=1`
and publishes the manifest as an artifact. Both modes assert the same convergence
invariant — only the iteration depth differs.

## Where it lives

All new code is added to `Sources/ContinuumRevivedCoreChecks/main.swift`, which currently
has one entry point and uses `do { }` blocks for each named check suite. The transport
fuzz becomes two new named blocks appended before the final
`print("ContinuumRevivedCoreChecks passed")` line (currently at line 5627 per the
convergence fuzz ticket):

- `// MARK: - I4 transport fuzz (seam-level)` — rewires the existing fuzz replicas to
  push and subscribe through `FakeSyncTransport`; asserts byte-identical convergence
  over 50 seeds × 200 steps. Runs unconditionally.
- `// MARK: - I4 transport soak` — the full 500-seed × 400-step suite gated behind
  `ProcessInfo.processInfo.environment["CONTINUUM_SOAK"] == "1"`; records budgets.

The `FakeSyncTransport` type is imported from `ContinuumRevivedCore`, where the transport
seam ticket defines it at
`Sources/ContinuumRevivedCore/Substrates/SyncTransport.swift` (established by the
injectable substrates ticket). No new files are created; no production code paths are
modified.

Relevant seam symbols used (all defined by prior tickets):

- `SyncTransport` protocol — `push(_: LoggedOp)` and `subscribe(_: @escaping (LoggedOp) -> Void)`
- `FakeSyncTransport` — `.mode: TransportMode`, `.emitted: [LoggedOp]`, `.delivered: [LoggedOp]`
- `TransportMode` — `.reliable`, `.partition`, `.reorder(seed:)`, `.lossy(dropRate:)`
- `LoggedOp`, `OpId`, `Op` — from the op enum ticket
- `materialize([LoggedOp]) -> (CanvasState, WorkspaceDocument)` — from op-log apply ticket
- `compactLog([LoggedOp], watermark: OpId) -> [LoggedOp]` — from op-log apply ticket
- `canonicalEncode(_:) -> Data` — defined in the convergence fuzz block

## Implementation breadcrumbs

```swift
// MARK: - I4 transport fuzz (seam-level)

do {
    // Replica wraps a FakeSyncTransport subscriber and a local log.
    // The key difference from the convergence fuzz: ops travel through
    // FakeSyncTransport.push / subscribe, not a local queue.

    struct TransportReplica {
        let replicaId: UUID
        var lamport: UInt64 = 0
        var log: [LoggedOp] = []
        // Each replica holds its own FakeSyncTransport instance.
        // In a real network, transport is shared; in the fake we connect
        // replica transports by wiring their subscribers to each other's push calls.
        var transport: FakeSyncTransport

        mutating func emit(_ op: Op) -> LoggedOp {
            lamport += 1
            let logged = LoggedOp(opId: OpId(lamport: lamport, replica: replicaId), op: op)
            log.append(logged)
            transport.push(logged)   // ← real seam call
            return logged
        }

        mutating func receive(_ logged: LoggedOp) {
            guard !log.contains(where: { $0.opId == logged.opId }) else { return }
            lamport = max(lamport, logged.opId.lamport) + 1
            log.append(logged)
        }
    }

    // Wire N replicas: each replica's transport.subscribe handler routes to all others.
    // Use a closure capture so the wiring is established at init, not at delivery time.
    func wireReplicas(_ replicas: inout [TransportReplica]) {
        for i in replicas.indices {
            let otherIndices = replicas.indices.filter { $0 != i }
            replicas[i].transport.subscribe { op in
                for j in otherIndices {
                    // Delivery is synchronous in the fake; mode controls drop/reorder.
                    replicas[j].transport.deliver(op)    // internal fake delivery
                }
            }
        }
    }

    var rng = LCG(seed: 99)   // distinct seed from the convergence fuzz

    for seed: UInt64 in 1 ... 50 {
        rng = LCG(seed: seed &+ 10_000)
        let replicaCount = Int.random(in: 2 ... 5, using: &rng)
        // Each replica gets a transport in a randomly selected mode for this seed.
        let mode = randomMode(rng: &rng)
        var replicas = (0 ..< replicaCount).map { _ in
            TransportReplica(
                replicaId: UUID(),
                transport: FakeSyncTransport(mode: mode)
            )
        }
        wireReplicas(&replicas)

        for _ in 0 ..< 200 {
            guard let idx = replicas.indices.randomElement(using: &rng) else { continue }
            let (canvas, _) = materialize(replicas[idx].log)
            let op = randomSpatialOp(rng: &rng, state: canvas)
            replicas[idx].emit(op)
            // Deliver queued messages if mode is reorder/lossy.
            for i in replicas.indices { replicas[i].transport.flush(rng: &rng) }
        }

        // Settle: switch all transports to .reliable and drain.
        for i in replicas.indices {
            replicas[i].transport.mode = .reliable
            replicas[i].transport.flush(rng: &rng)
        }
        // Full log exchange.
        for i in replicas.indices {
            for j in replicas.indices where j != i {
                replicas[j].receive(contentsOf: replicas[i].log)
            }
        }

        // Assert I4 over the seam-level fuzz.
        let encodings = replicas.map { canonicalEncode(materialize($0.log)) }
        for enc in encodings.dropFirst() {
            expect(enc == encodings[0], "I4 transport fuzz: seed \(seed) — seam-level divergence")
        }
    }
}

// MARK: - I4 transport soak

let isSoak = ProcessInfo.processInfo.environment["CONTINUUM_SOAK"] == "1"
let soakSeeds: UInt64 = isSoak ? 500 : 50
let soakSteps = isSoak ? 400 : 200

do {
    var maxConvergenceLatency: UInt64 = 0   // in logical steps (delta between emit lamport and final receive lamport)
    var maxLogLengthBeforeCompaction: Int = 0
    var totalCompactions = 0

    for seed: UInt64 in 1 ... soakSeeds {
        var rng = LCG(seed: seed &+ 20_000)
        let replicaCount = 5
        let mode = soakMode(seed: seed, rng: &rng)  // deterministic mode assignment per seed
        var replicas = (0 ..< replicaCount).map { _ in
            SoakReplica(replicaId: UUID(), transport: FakeSyncTransport(mode: mode))
        }
        wireSoakReplicas(&replicas)

        for step in 0 ..< soakSteps {
            let idx = Int.random(in: 0 ..< replicaCount, using: &rng)
            let (canvas, _) = materialize(replicas[idx].log)
            let op = randomSpatialOp(rng: &rng, state: canvas)
            let emitLamport = replicas[idx].lamport + 1
            replicas[idx].emit(op)

            for i in replicas.indices { replicas[i].transport.flush(rng: &rng) }

            // Measure convergence latency: steps until all replicas have seen this op.
            // Simplified: count additional flush cycles needed until all logs contain the op's opId.
            // This is logical-step count, never wall time.
            var latency: UInt64 = 0
            var opId = OpId(lamport: emitLamport, replica: replicas[idx].replicaId)
            for _ in 0 ..< 50 {   // cap at 50 additional cycles
                if replicas.allSatisfy({ $0.log.contains(where: { $0.opId == opId }) }) { break }
                for i in replicas.indices { replicas[i].transport.flush(rng: &rng) }
                latency += 1
            }
            maxConvergenceLatency = max(maxConvergenceLatency, latency)

            // Occasionally compact a replica and record log length before compaction.
            if step % 80 == 0, let ci = replicas.indices.randomElement(using: &rng) {
                maxLogLengthBeforeCompaction = max(maxLogLengthBeforeCompaction, replicas[ci].log.count)
                let watermark = replicas[ci].log.map(\.opId).min()!
                replicas[ci].log = compactLog(replicas[ci].log, watermark: watermark)
                totalCompactions += 1
            }
        }

        // Settle and assert byte-identical convergence.
        for i in replicas.indices { replicas[i].transport.mode = .reliable }
        for _ in 0 ..< 10 { for i in replicas.indices { replicas[i].transport.flush(rng: &rng) } }
        for i in replicas.indices {
            for j in replicas.indices where j != i { replicas[j].receive(contentsOf: replicas[i].log) }
        }
        let encodings = replicas.map { canonicalEncode(materialize($0.log)) }
        for enc in encodings.dropFirst() {
            expect(enc == encodings[0], "I4 soak: seed \(seed) — diverged after settle")
        }
    }

    // Manifest: concrete measured values, never {passed:true}.
    print("I4 transport soak: \(soakSeeds) seeds × \(soakSteps) steps, maxConvergenceLatency=\(maxConvergenceLatency) logical steps, maxLogBeforeCompaction=\(maxLogLengthBeforeCompaction) ops, totalCompactions=\(totalCompactions)")
}
```

`randomSpatialOp` is the same function established by the convergence fuzz — it picks a
legal op against the current materialized canvas state, weighted toward moves. It must
not be duplicated; extract it to a named function visible to both blocks.

`soakMode` distributes modes across seeds deterministically: seeds 1–150 use
`.reliable`, seeds 151–300 use `.reorder(seed: seed)`, seeds 301–400 use
`.lossy(dropRate: 0.2)`, seeds 401–500 use `.partition` followed by a forced
`.reliable` settle (the partition mode suppresses all delivery during the run steps; the
settle switches to reliable and drains).

## How we test it

### Logic (pure Core checks)

The transport fuzz block (50 seeds × 200 steps) is the logic test. It exercises the
`FakeSyncTransport.push` / `subscribe` boundary as the actual call surface, not a
hand-wired local queue. Every seed asserts byte-identical canonical encoding across all
replicas after settle, plus the same domain invariants the convergence fuzz checks: no
tombstoned tile present, every tile in at most one zone, zone z-order a permutation of
live zones, no orphaned group member.

A targeted regression test within the block covers the seam-specific failure mode: one
replica's transport is put into `.partition` mode for 100 steps, then switched to
`.reliable` and settled. The assertion is that the partitioned replica's state converges
to byte-identity with the others — this is the offline/reconnect case the transport seam
is explicitly designed to handle, and it must not require any special-case code in the
merge logic (the tombstone + LWW + fractional-index model handles it automatically).

### Backend (real-path / integration)

The backend obligation is narrow: prove that the `FakeSyncTransport` satisfies the
`SyncTransport` protocol contract as the transport seam ticket specifies it — that
`push` calls reach every registered subscriber and that `flush` in `.reorder` mode
delivers all ops (just not necessarily in emission order). This is a structural
protocol-conformance check, not a cloud check.

Concretely: instantiate a `FakeSyncTransport` in each mode in turn. In `.reliable`
mode, push three `LoggedOp` values and call `flush`; assert all three appear in `delivered`
in emission order and the subscriber was called three times. In `.partition` mode, push
two ops and call `flush`; assert `delivered` is unchanged. Switch the transport's mode to
`.reliable` and flush again; assert all two ops now appear in `delivered` (they were
buffered, not dropped). In `.reorder(seed: 7)` mode, push five ops and flush; assert all
five appear in `delivered` — sort both sets by `opId` and compare element-wise to
confirm no op was lost, only reordered. In `.lossy(dropRate: 1.0)` mode, push ops and
flush; assert nothing new appears in `delivered`. The partition-then-reliable case above
is the most important: it proves that the fake buffers ops under partition rather than
silently dropping them, which is the precondition for the offline/reconnect convergence
test to mean anything.

This check lives in `ContinuumRevivedCoreChecks/main.swift`. It is not a happy-path
bypass: it uses the real `FakeSyncTransport` implementation, not a stub, and it calls
`push` and `flush` through the actual protocol methods.

### UX (visual gate + dogfood snippet)

There is no user-visible surface in this ticket. The visual gate is the CI matrix for
the standard invocation and the nightly CI artifact for the soak. The manifest printed
by the soak block is the non-degenerate gate: it must show a non-zero
`maxConvergenceLatency` (proving the adversarial modes exercised something), a non-zero
`maxLogBeforeCompaction` (proving compaction was triggered), and a `totalCompactions`
count of at least 60 across 500 seeds.

The dogfood snippet for the standard invocation: open Terminal, `cd` to the repo root,
run `swift run ContinuumRevivedCoreChecks`. Observe that the final output includes both
`I4 transport soak: 50 seeds × 200 steps, maxConvergenceLatency=N logical steps,
maxLogBeforeCompaction=M ops, totalCompactions=K` and the closing
`ContinuumRevivedCoreChecks passed` on the next line, with non-zero values for N, M, and
K. If any seed diverges the process exits non-zero and the failing seed number appears in
stderr; no silent false green is possible. For the full soak:
`CONTINUUM_SOAK=1 swift run ContinuumRevivedCoreChecks` — the manifest values grow
proportionally and are published to the CI artifact.

## Execution mode

**Autonomous.** The entire ticket — transport fuzz, soak, and backend protocol check —
runs in a single pure Swift process with no tmux daemon, no CloudKit account, no real
network, and no iOS device. The `FakeSyncTransport` drives all delivery synchronously
inside the check harness. Time is logical (Lamport), not wall-clock. The seeded RNG
makes every failing seed a deterministic reproducer. The CI matrix is necessary and
sufficient for the standard-invocation suite; the nightly CI job with `CONTINUUM_SOAK=1`
is necessary and sufficient for the full soak. No human eyes are required at any point —
convergence either holds byte-identically or the process exits non-zero.

## Done when

- [ ] `swift run ContinuumRevivedCoreChecks` exits zero with a manifest line reading
  `I4 transport soak: 50 seeds × 200 steps, maxConvergenceLatency=N logical steps,
  maxLogBeforeCompaction=M ops, totalCompactions=K` where N, M, and K are all non-zero.
- [ ] `CONTINUUM_SOAK=1 swift run ContinuumRevivedCoreChecks` exits zero with a
  manifest line showing 500 seeds × 400 steps and non-zero budget values for both
  convergence latency and log length.
- [ ] The inline `FakeTransport` struct from the convergence fuzz block has been removed
  and replaced with the real `FakeSyncTransport`; the convergence fuzz block itself still
  passes with no behavior change.
- [ ] The partition-then-reliable regression test passes: a replica partitioned for 100
  steps and then reconnected converges byte-identically with peers without any
  special-case merge code.
- [ ] The backend protocol-conformance check passes for all four `TransportMode` cases,
  including the partition-buffer-then-reliable delivery case (ops buffered under
  partition must appear after the mode switches to reliable, not be silently dropped).
- [ ] A failing seed prints the seed number to stderr before the process exits non-zero,
  so any regression is a one-command reproducer.
- [ ] The nightly CI job is configured to run with `CONTINUUM_SOAK=1` and publish the
  manifest as a CI artifact (not just to stdout), with the job failing if any of the
  500 seeds diverges.
- [ ] All existing check blocks still pass; no prior behavior is changed.

## Depends on / unblocks

This ticket depends directly on the transport seam ticket, which defines the
`SyncTransport` protocol and the `FakeSyncTransport` with its four `TransportMode`
cases. It also depends on the convergence fuzz, which established `canonicalEncode`,
`materialize`, `compactLog`, and the `randomSpatialOp` helper used by both the
convergence fuzz and the transport fuzz. Both must be merged and green before any code
here is written — the transport fuzz calls the real protocol, not a stub, and the
`randomSpatialOp` function must already exist to be shared.

This ticket directly unblocks the CloudKit transport implementation. The soak manifest
gives that ticket a concrete baseline: the measured max convergence latency in simulated
logical time and the max log length before compaction are the budgets the CloudKit
real-path check is held against (CloudKit's near-real-time delivery of seconds is
acceptable given the fake soak shows convergence within a small number of logical
delivery cycles). Without the soak manifest, the CloudKit ticket has no anchor for
"transport correctness acceptable." The connection supervisor's reconnect state machine
is also directly informed by the partition-then-reliable scenario exercised here.

## Watch out for

**The hardest thing to get right is the `FakeSyncTransport.flush` implementation under
`.partition` mode.** The partition mode must buffer ops, not drop them — the
offline/reconnect convergence test depends entirely on this distinction. If `flush`
silently discards ops under `.partition` and then the mode switches to `.reliable`, the
settle step will appear to converge (because there are no un-delivered ops to cause
divergence), but the test is not actually exercising the reconnect case at all. Verify
by asserting that `transport.buffered.count` is non-zero immediately after the partition
phase and falls to zero after the settle flush.

**The `randomSpatialOp` function must be extracted and shared, not duplicated.** The
convergence fuzz block and both new blocks need the same legal-op generator. Duplicating
it means two code paths can diverge and silently exercise different state spaces. Extract
it to a named function at the top of the check file (outside any `do` block), visible to
all three blocks.

**The convergence latency metric is logical steps, not wall-clock time.** The
architecture bans wall-clock ordering in the sync model (`docs/38-agent-orchestration-
architecture.md:413`), and the same discipline applies here: latency is the number of
additional `flush` cycles needed for all replicas to receive an op, not a
`DispatchTime` measurement. Any attempt to measure wall-clock delivery speed in the
fake is meaningless (the fake is synchronous) and violates the no-wall-clock discipline.

**The soak's `CONTINUUM_SOAK=1` gate must not make the standard suite a happy-path
bypass.** The standard 50-seed × 200-step suite must exercise at least one seed per
network mode — reliable, reorder, lossy, and partition/reconnect. If all 50 standard
seeds land in `.reliable` mode because the mode assignment formula starts with a long
reliable run, the standard CI suite provides no coverage of the adversarial cases. The
mode assignment must distribute across all four modes within the first 50 seeds.

**Stop condition for Loro fallback.** If the transport fuzz finds a seed that cannot be
made to converge after applying any single clear merge-policy fix, do not continue
patching — write up the seed reproduction, the two diverging canonical encodings, and
which domain invariant is violated, then signal the Loro fallback as documented in the
convergence fuzz ticket. The transport fuzz failing is a stronger signal than the
convergence-fuzz failing, because it means the seam wiring is non-deterministic in a
way the pure in-memory fuzz did not catch.

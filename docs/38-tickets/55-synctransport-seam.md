# SyncTransport seam — protocol, adversarial fake, and offline/reconnect scenarios

**Phase 6 — Sync & multi-device · ticket 55 of 74**

## What this delivers

After this ticket, the sync layer has a concrete boundary at the transport. A `SyncTransport` protocol captures the smallest possible surface a real transport must satisfy — deliver a `LoggedOp` to peers, receive a stream of `LoggedOp` values from them, signal connection state, and accept a snapshot for bootstrapping a fresh peer. Nothing in the protocol names CloudKit, WebSockets, or any specific delivery mechanism; those are implementation details that live behind the seam, not on it.

Alongside the protocol sits a `FakeSyncTransport` — a fully adversarial in-process fake that can partition any pair of replicas from each other, reorder queued messages, delay delivery by a synthetic number of ticks, drop messages at a configured rate, and duplicate any message an arbitrary number of times. It can also take a replica offline (buffering all outbound ops) and flood its backlog on reconnect. This fake is the substrate the convergence fuzz ticket runs through: all I4 correctness proofs happen against the fake, never a real network, forever.

The outcome the owner observes: the next ticket — the transport fuzz and soak — can be written immediately, because it has a real transport protocol to program against and a real fake to exercise. Every subsequent Phase 6 ticket that touches a transport (the CloudKit implementation, the activity projection, the connection supervisor) has a concrete protocol to conform to. An implementer of the CloudKit transport cannot accidentally skip the seam; the Swift type system enforces it.

## How it fits

This ticket builds directly on the op-log core — specifically on `LoggedOp`, `OpId`, and `CompactedSnapshot` from the op-log apply and compaction work — and on `ContinuumRevivedSync`, the target where all sync machinery lives. The op-log core established that spatial state is a deterministic fold over a multiset of `LoggedOp` values; this ticket adds the question of how those values move between replicas.

The convergence fuzz proven in the earlier RED→GREEN work exercised `materialize` directly, delivering ops to each in-process replica by direct function call. That was correct for proving the merge logic, but it bypassed the question of transport ordering entirely. This ticket closes that gap: the `FakeSyncTransport` introduces the network adversary the fuzz needs to drive adversarial delivery scenarios, including the partition-then-reconnect flood that is the dominant real-world failure mode.

What this ticket unblocks: the transport fuzz and soak (the next ticket), which runs the convergence proof end-to-end through the fake including random partitions and reconnects. After the fuzz is green, the CloudKit transport implementation can be built knowing the protocol is already battle-tested. The connection supervisor and the activity projection over transport also depend on the protocol being settled here. Nothing in Phase 6 beyond this ticket can be completed without this seam in place.

## The approach

`SyncTransport` is a Swift protocol with `Sendable` and `Actor`-isolation-friendly constraints — callers are Swift concurrency actors, and the protocol's methods are all `async throws`. The protocol has four concerns:

1. **Send** — push a `LoggedOp` (or a batch) outbound, fire-and-forget from the caller's perspective; the transport handles delivery guarantees.
2. **Receive** — an `AsyncSequence` of inbound `LoggedOp` values (from peers) that the sync coordinator consumes in a `for await` loop.
3. **Bootstrap** — send or receive a `CompactedSnapshot` to seed a fresh peer or catch up a lagging replica past its log gap.
4. **Connection state** — an `AsyncSequence` of `ConnectionState` values (`.connected`, `.disconnected(reason:)`, `.reconnecting`) so the connection supervisor and the UI can react to link changes without polling.

The protocol deliberately excludes acknowledgement, retry, and idempotency machinery. Those are the transport's job to implement; the protocol's callers care only about the stream of ops they receive, not about whether the transport deduplicated them (duplicate `LoggedOp` values with the same `OpId` are idempotent in `materialize` — the op-log core already proved this). A real transport like CloudKit upserts by `OpId` as its key, achieving idempotency at its own layer. The fake transport does not deduplicate by default — this is intentional, because duplicating messages is one of the adversarial behaviors the fuzz exploits.

`FakeSyncTransport` is a class (an actor, in practice) that manages a named set of in-process replicas and a directed queue per ordered pair of replicas. Each queue entry carries the `LoggedOp`, a delivery-tick countdown (0 = deliver now, N > 0 = deliver after N `tick()` calls), and a duplicate count (1 = deliver once, N > 1 = deliver N copies). The actor exposes a `tick()` method that the fuzz driver calls on each step of its loop; on each tick, queued messages whose countdown has reached zero are injected into the receiver's inbound sequence. The partition, reorder, delay, drop, and duplicate behaviors are all parameters on the `FakeSyncTransport`'s delivery policy, settable per ordered pair so the fuzz can model asymmetric partitions.

The `goOffline(replica:)` / `reconnect(replica:)` API buffers all outbound ops from the named replica into a hold queue and, on reconnect, floods them into the queues of every other replica at once. This is the model for the dominant real case: a device edits offline, then regains connectivity. The hold-then-flood is the worst case for a merge algorithm — a burst of out-of-order ops all arriving together — and it is the scenario the nightly soak concentrates on.

## Where it lives

All new code lives in `ContinuumRevivedSync`, the target introduced by the op-log work. No files in `Sources/ContinuumRevivedCore/` are modified by this ticket — the seams named below are read-only references.

New files in `Sources/ContinuumRevivedSync/`:

- `SyncTransport.swift` — the `SyncTransport` protocol, the `ConnectionState` enum, a `SyncTransportError` enum for send/receive failures, and the `SyncMessage` enum (wrapping either a `LoggedOp` or a `CompactedSnapshot` for bootstrap).
- `FakeSyncTransport.swift` — the `FakeSyncTransport` actor, the `DeliveryPolicy` struct (per-pair partition flag, reorder flag, delay ticks, drop rate `0.0…1.0`, duplicate count), and the `tick()` / `goOffline(_:)` / `reconnect(_:)` API.

Existing seams this ticket reads but does not modify:

- `Sources/ContinuumRevivedCore/ProjectStore.swift:76` — `ProjectStore` and `AtomicWriter` at `:78` are the persistence layer this transport abstracts above. The transport delivers `LoggedOp` values; the coordinator on the other side decides when to call `saveCanvas`.
- `Sources/ContinuumRevivedCore/WorkspaceStore.swift:29` — `WorkspaceStore.save` at `:55` and `load` at `:59` are similarly downstream of the transport; the seam is clean.
- `Sources/ContinuumRevivedSync/OpLog.swift` — `materialize(ops:)` and `LoggedOp` / `OpId` are the types this transport moves across replicas.
- `Sources/ContinuumRevivedSync/Compaction.swift` — `CompactedSnapshot` is the bootstrap payload; the transport's `bootstrap` channel carries it verbatim.

## Implementation breadcrumbs

```swift
// SyncTransport.swift

public enum ConnectionState: Sendable, Equatable {
    case connected
    case reconnecting
    case disconnected(reason: String)
}

/// A message the transport can carry — either a single op or a compacted snapshot
/// used to bootstrap a fresh/lagging replica.
public enum SyncMessage: Codable, Sendable {
    case op(LoggedOp)
    case snapshot(CompactedSnapshot)
}

/// The transport boundary. Concrete implementations include FakeSyncTransport
/// (in-process, adversarial) and CloudKitSyncTransport (real, Phase 6).
/// All methods are async/throws; callers are Swift concurrency actors.
public protocol SyncTransport: Sendable {
    /// Outbound: push a message to all connected peers. Fire-and-forget — the
    /// transport handles retries, idempotency, and ordering guarantees internally.
    func send(_ message: SyncMessage) async throws

    /// Inbound: a stream of messages received from peers. Consume with `for await`.
    /// The sequence is infinite until the transport is torn down.
    var inbound: AsyncStream<SyncMessage> { get }

    /// Connection state changes. Consume with `for await` to drive the supervisor.
    var connectionState: AsyncStream<ConnectionState> { get }
}
```

```swift
// FakeSyncTransport.swift

/// Per-directed-pair delivery policy. The fuzz sets these before calling tick().
public struct DeliveryPolicy: Sendable {
    public var partitioned: Bool    = false  // no delivery while true
    public var reorder:     Bool    = false  // shuffle the ready-to-deliver set
    public var delayTicks:  Int     = 0      // countdown before delivering
    public var dropRate:    Double  = 0.0    // probability [0,1] of silent drop
    public var duplicates:  Int     = 1      // copies delivered per message (≥1)
}

/// An in-process fake with a named replica set and per-pair directed queues.
public actor FakeSyncTransport {
    public struct ReplicaId: Hashable, Sendable { public let id: UUID }

    // One continuation per replica's inbound AsyncStream.
    private var inboundContinuations: [ReplicaId: AsyncStream<SyncMessage>.Continuation] = [:]
    // Per-pair queues: (sender, receiver) → [(message, tickCountdown, dupCount)]
    private var queues: [[ReplicaId]: [(SyncMessage, Int, Int)]] = [:]
    // Per-replica policies (keyed by (sender, receiver) pair).
    private var policies:  [[ReplicaId]: DeliveryPolicy] = [:]
    // Hold queues for offline replicas.
    private var holdQueues: [ReplicaId: [SyncMessage]] = [:]
    private var offlineReplicas: Set<ReplicaId> = []
    // Seeded RNG for reproducible fuzz runs.
    private var rng: RandomNumberGenerator

    public init(seed: UInt64) {
        // Seed a deterministic RNG so failing scenarios are reproducible.
        self.rng = SeedableRNG(seed: seed)
    }

    /// Register a replica and return its inbound AsyncStream.
    public func makeReplica() -> (ReplicaId, AsyncStream<SyncMessage>) {
        let id = ReplicaId(id: UUID())
        let (stream, continuation) = AsyncStream<SyncMessage>.makeStream()
        inboundContinuations[id] = continuation
        return (id, stream)
    }

    /// Send from `sender` to all other replicas — enqueues per-pair.
    public func send(_ message: SyncMessage, from sender: ReplicaId) {
        if offlineReplicas.contains(sender) {
            holdQueues[sender, default: []].append(message)
            return
        }
        for receiver in inboundContinuations.keys where receiver != sender {
            let pair = [sender, receiver]
            let policy = policies[pair] ?? DeliveryPolicy()
            guard !policy.partitioned else { continue }
            let drop = Double.random(in: 0..<1, using: &rng) < policy.dropRate
            if drop { continue }
            let copies = max(1, policy.duplicates)
            let delay  = max(0, policy.delayTicks)
            for _ in 0..<copies {
                queues[pair, default: []].append((message, delay, 1))
            }
        }
    }

    /// Advance the clock one tick: decrement countdowns and deliver ready messages.
    public func tick() {
        for pair in queues.keys {
            let policy = policies[pair] ?? DeliveryPolicy()
            var ready: [SyncMessage] = []
            queues[pair] = queues[pair]!.compactMap { (msg, countdown, dup) in
                let next = countdown - 1
                if next <= 0 { ready.append(msg); return nil }
                return (msg, next, dup)
            }
            if policy.reorder { ready.shuffle(using: &rng) }
            let receiver = pair[1]
            for msg in ready {
                inboundContinuations[receiver]?.yield(msg)
            }
        }
    }

    /// Buffer all outbound ops from this replica.
    public func goOffline(_ replica: ReplicaId) {
        offlineReplicas.insert(replica)
    }

    /// Flood the held ops into all peer queues, then resume normal delivery.
    public func reconnect(_ replica: ReplicaId) {
        offlineReplicas.remove(replica)
        let held = holdQueues.removeValue(forKey: replica) ?? []
        for message in held {
            send(message, from: replica)
        }
    }

    /// Set the delivery policy for a directed pair.
    public func setPolicy(_ policy: DeliveryPolicy, from sender: ReplicaId, to receiver: ReplicaId) {
        policies[[sender, receiver]] = policy
    }
}
```

```swift
// How the fuzz driver uses FakeSyncTransport:

let transport = FakeSyncTransport(seed: fixedSeed)
var replicas: [(ReplicaId, AsyncStream<SyncMessage>)] = (0..<N).map { _ in
    await transport.makeReplica()
}

// Randomly partition a pair:
await transport.setPolicy(
    DeliveryPolicy(partitioned: true),
    from: replicas[0].0, to: replicas[1].0
)

// Emit an op from replica 0:
let op = LoggedOp(opId: opId, op: .setTileFrame(id: tileId, frame: newFrame))
await transport.send(.op(op), from: replicas[0].0)

// Advance time:
for _ in 0..<ticks { await transport.tick() }

// Heal the partition, go offline, reconnect:
await transport.setPolicy(DeliveryPolicy(), from: replicas[0].0, to: replicas[1].0)
await transport.goOffline(replicas[2].0)
// ... emit ops from other replicas ...
await transport.reconnect(replicas[2].0)
// drain until all inbound streams are idle, then assert convergence
```

The I5 taint scan applies to every `SyncMessage` before it is yielded to the inbound continuation, even in the fake. This makes the scan a structural invariant of the transport layer, not just a test: no message carrying a `runtimeRef`, pane target, or host-local string can transit the fake any more than it could transit CloudKit. The scan runs as a `precondition` in debug builds and as a logged assertion in release builds.

## How we test it

### Logic

All logic checks live in `ContinuumRevivedSyncChecks`, the check target for the sync package. Every check is in-process, with a seeded `FakeSyncTransport` and a fake clock — no file system, no daemon, no network.

**Basic delivery.** Two replicas, default policy (no partitions, no drops, no reorder). Emit three ops from replica A. Call `tick()` until the inbound queues are empty. Assert replica B has received exactly three `SyncMessage.op` values whose `LoggedOp` values are identical to what A sent, in the same order. Assert replica A received nothing (messages are not looped back to the sender).

**Drop semantics.** Set `dropRate = 1.0` on the A→B pair. Emit five ops from A. Call `tick()` twenty times. Assert replica B received zero messages. Set `dropRate = 0.0`. Emit one more op. Call `tick()` five times. Assert B received exactly one message.

**Duplicate semantics.** Set `duplicates = 3`. Emit one op from A. Call `tick()` five times. Assert B received exactly three copies of the op (same `OpId` each time). Then call `materialize` on B's effective log with duplicates present and assert the output is identical to materializing a log with the op present exactly once — proving idempotency holds end-to-end.

**Delay semantics.** Set `delayTicks = 5`. Emit one op from A. Call `tick()` four times and assert B has received nothing. Call `tick()` once more and assert B receives the op on that tick.

**Reorder semantics.** Set `reorder = true`. Emit five ops from A in Lamport order 1, 2, 3, 4, 5 with `delayTicks = 0`. Call `tick()` once (delivering all five, reordered by the seeded RNG). Assert B received all five ops, but not necessarily in Lamport order. Then materialize B's effective log and assert the output is identical to materializing them in original order — proving `materialize`'s sort step absorbs transport reorder.

**Partition and heal.** Partition A from B. Emit three ops from A and two from B. Call `tick()` ten times. Assert A received B's two ops and B received nothing from A (asymmetric partition). Heal the partition. Call `tick()` ten times. Assert B now has A's three ops. Assert materializing each replica's full log (union of all five ops) produces byte-identical state.

**Offline / reconnect flood.** Three replicas. Take replica C offline. Emit six ops: two from A, two from B, two from C (C's go to hold). Call `tick()` ten times. Assert A and B have each other's four ops; C has received nothing. Reconnect C. Call `tick()` until all queues drain. Assert all three replicas have all six ops. Materialize each and assert byte-identical output. This is the dominant real case (device edits offline, reconnects) and is the single most important scenario in the suite.

**I5 on transit.** Attempt to send a `SyncMessage.op` whose associated `LoggedOp` value was constructed by bypassing the op enum (via a test helper that forcibly injects a `runtimeRef` string into the encoded bytes). Assert the transport's `precondition` taint scan fires before the message reaches the inbound continuation. This proves the scan is structural, not optional.

**Bootstrap snapshot.** Emit ten ops on a two-replica setup; compact to a snapshot at lowWaterMark 5. Send the snapshot via `SyncMessage.snapshot` to a fresh third replica that has no prior log. Assert the third replica's effective log (snapshot plus the five tail ops it receives via normal delivery) materializes to the same state as replicas one and two.

### Backend

The backend check exercises the `FakeSyncTransport` with the real `ProjectStore` and `WorkspaceStore` persistence layer on disk — not mocked. The purpose is to prove that ops received via the transport can be materialized and then persisted through the existing store without error, and that the materialized output is identical to what the store can read back.

Concretely: set up two in-process replicas using `FakeSyncTransport`. Replica A starts from the real `canvas.json` fixture committed under `ContinuumRevivedSyncChecks/Fixtures/canvas.json` and emits a `createTile` op plus a `setTileFrame` op. Deliver both to replica B via the fake (default policy, no adversarial behaviors). On delivery, replica B calls `materialize` and then `ProjectStore.saveCanvas` on the result using a real temporary directory (not `FileManager.default` in the app's support directory — use `FileManager.default.temporaryDirectory` for test isolation). Load the saved file back via `ProjectStore.loadCanvas`. Assert the loaded `CanvasState` matches the materialized output field-by-field. Assert `runtimeRef` is `nil` on every tile in the loaded state. Assert the file round-trip is clean — no `AtomicWriter` backup fallback was triggered.

This check uses the real `AtomicWriter` at `Sources/ContinuumRevivedCore/ProjectStore.swift:78`, the real `JSONCodec`, and the real file system. It is the proof that the transport layer and the persistence layer compose correctly end-to-end.

### UX

This ticket has no direct UX surface; it is a pure protocol and fake. The human-visible result — tiles converging across devices after a partition — only manifests once the CloudKit transport and the multi-device Phase 6 work is live. There is no dogfood snippet for this ticket in isolation.

However, the check manifest must record **measured values** and not merely pass/fail booleans: message throughput of the fake transport (ops-per-tick at the N=5 replica scale used in the fuzz), memory footprint of the hold queue after 1,000 ops emitted to an offline replica, and the number of ticks required for the offline/reconnect flood scenario to drain fully. These numbers become the baseline budget the nightly transport fuzz soak compares against.

## Execution mode

**Autonomous.** Every check in this ticket is in-process, seeded, and deterministic: the `FakeSyncTransport` uses a seeded RNG, the clock is advanced by explicit `tick()` calls (no wall time), and the backend check uses a temporary directory that is set up and torn down in the check body. No CloudKit account, no iOS device, no human eye is required to reach a verdict. The check manifest carries measured values; a number either equals the expected baseline or it does not. An overnight coder can run this ticket to completion without human involvement.

## Done when

- [ ] `SyncTransport` protocol is defined in `Sources/ContinuumRevivedSync/SyncTransport.swift` with `send(_:)`, `inbound: AsyncStream<SyncMessage>`, `connectionState: AsyncStream<ConnectionState>`, and compiles cleanly under Swift 6.0 strict concurrency with no `@unchecked Sendable` workarounds.
- [ ] `FakeSyncTransport` implements an actor conforming to the internal needs of the fuzz driver (not `SyncTransport` directly — it is the adversarial substrate, not a conforming transport), with `makeReplica()`, `send(_:from:)`, `tick()`, `goOffline(_:)`, `reconnect(_:)`, and `setPolicy(_:from:to:)`.
- [ ] The I5 taint scan fires as a `precondition` in debug builds on any `SyncMessage` carrying a forbidden token (verified by the adversarial I5 logic check above).
- [ ] All eight logic checks above pass with the seeded RNG producing reproducible results — the same seed produces the same delivery order and the same final state on every run.
- [ ] The backend check round-trips two ops through `FakeSyncTransport` → `materialize` → `ProjectStore.saveCanvas` → `ProjectStore.loadCanvas` without error, with `runtimeRef == nil` on every tile in the loaded state.
- [ ] The check manifest records measured values: fake transport throughput, hold-queue memory at 1,000 ops, and ticks-to-drain for the offline/reconnect scenario — never `{passed:true}`.
- [ ] No files in `Sources/ContinuumRevivedCore/` were modified by this ticket (confirmed by a clean `git diff Sources/ContinuumRevivedCore`).
- [ ] `ContinuumRevivedSync` still has zero external dependencies after this ticket (`Package.swift` dependency list unchanged).

## Depends on / unblocks

This ticket depends on the op-log apply and compaction work providing finalized definitions of `LoggedOp`, `OpId`, `CompactedSnapshot`, and `materialize(ops:)` in `ContinuumRevivedSync`. Those types are the only payload the transport moves; the protocol cannot be defined without them. It depends on the sync/observation type split having confirmed that `LoggedOp` carries spatial ops only — never activity events, pane targets, or runtime references — since that guarantee is what makes the I5 taint scan structurally enforced rather than empirically asserted.

This ticket directly unblocks the transport fuzz and soak (the next Phase 6 ticket), which drives the adversarial convergence proof end-to-end through the `FakeSyncTransport`. It also unblocks the CloudKit transport implementation (which must conform to `SyncTransport`) and the connection supervisor (which consumes `connectionState: AsyncStream<ConnectionState>`). The activity projection over transport similarly depends on the `SyncMessage` enum having a stable shape, since the projection adds an `.activitySnapshot` case to that enum in its own ticket.

## Watch out for

**The seeded RNG must be threaded, not re-seeded.** `FakeSyncTransport` is an actor; calls to `tick()` must use the same `rng` instance across calls rather than re-constructing it from the seed each time. If a caller accidentally re-seeds the RNG at each tick, every tick's reorder/drop decisions are statistically independent of each other rather than forming a reproducible sequence, and a failing seed cannot be reliably reproduced. The seed is only provided to `init`; after that, `rng` is mutated in place on every call that needs randomness.

**`AsyncStream` back-pressure is a fake concern, not a real one.** The `AsyncStream<SyncMessage>` yielded to each replica's inbound consumer has a default `.unbounded` buffering policy in the fake — messages pile up in the buffer if the consumer is slow. In production, a slow consumer facing a burst reconnect flood would need genuine back-pressure. The fake doesn't need to model this, but the protocol must not *prevent* a conforming implementation from applying back-pressure. The `send(_:)` method on `SyncTransport` is `async throws` precisely to allow a conforming transport to `await` back-pressure signals before returning. Do not make it synchronous as a "simplification."

**Do not deduplicate in the fake.** The op-log core is idempotent with respect to duplicate `LoggedOp` values that share an `OpId`: `materialize` folds them to the same result. This idempotency is a tested property of the merge layer, and it only remains proven if the transport actually delivers duplicates. The `FakeSyncTransport` intentionally delivers duplicate messages when `duplicates > 1` is set. An implementer who "helpfully" deduplicates in the fake is hiding a real correctness question: whether the merge layer truly handles duplicates, or whether it just hasn't been tested with them. Let the fuzz find out.

**The hold queue for offline replicas can grow without bound.** In the fake this is fine — a test will never run 10,000 offline ops. In a real transport (CloudKit), you cannot accumulate unbounded outbound ops in memory; you need durable local queuing (a local op-log on disk) with a high-water mark. The `SyncTransport` protocol does not mandate durability of the outbound queue; that is the CloudKit transport's concern. But if the `FakeSyncTransport`'s hold queue is ever used as a template for the CloudKit implementation, the lack of a size bound will cause OOM on long offline periods. Add a size-bound `precondition` in debug builds (`assert(holdQueues[replica]!.count < 10_000, "hold queue overflow — use durable queueing in production transports")`) so the distinction is visible.

**Stop if `SyncTransport` conformance requires modifying core types.** The protocol's `SyncMessage` enum wraps `LoggedOp` and `CompactedSnapshot`; both of those types must already be `Codable` and `Sendable`. If they are not — because a prior ticket left a field non-`Sendable` or non-`Codable` — the fix belongs in the op-log ticket that owns those types, not here. Do not add `@unchecked Sendable` as a workaround; find and fix the underlying non-`Sendable` field.

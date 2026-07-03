import Foundation
import ContinuumRevivedCore

// Ticket: docs/38-tickets/55-synctransport-seam.md
//
// A fully adversarial in-process fake: partitions any pair of replicas,
// reorders queued messages, delays delivery by a synthetic tick count, drops
// messages at a configured rate, and duplicates any message an arbitrary
// number of times. It also takes a replica offline (buffering outbound ops)
// and floods its backlog on reconnect. This is the substrate the convergence
// fuzz (the next ticket) drives; all I4 correctness proofs happen against
// this fake, never a real network.
//
// `FakeSyncTransport` does NOT conform to `SyncTransport` — it is the
// adversarial substrate the fuzz driver programs directly against (via
// `makeReplica`/`send(_:from:)`/`tick()`), not a conforming transport a sync
// coordinator would use. See the ticket's "Done when".

/// Deterministic splitmix64 PRNG. Seeded once at `init` and mutated in place
/// on every subsequent draw — NEVER re-seeded per call (see ticket "Watch out
/// for": re-seeding at every tick would make each tick's reorder/drop
/// decisions independent of one another, defeating reproducibility).
private struct SeedableRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        // A zero seed would make the first splitmix64 round degenerate
        // (0 &+ golden-gamma is still fine, but guard anyway for clarity).
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Per-directed-pair delivery policy. The fuzz sets these before calling
/// `tick()`. `duplicates ≥ 1`; a value `< 1` is clamped up to 1 by `send`.
public struct DeliveryPolicy: Sendable {
    public var partitioned: Bool = false   // no delivery while true
    public var reorder: Bool = false       // shuffle the ready-to-deliver set
    public var delayTicks: Int = 0         // countdown before delivering
    public var dropRate: Double = 0.0      // probability [0,1] of silent drop
    public var duplicates: Int = 1         // copies delivered per message (≥1)

    public init(
        partitioned: Bool = false,
        reorder: Bool = false,
        delayTicks: Int = 0,
        dropRate: Double = 0.0,
        duplicates: Int = 1
    ) {
        self.partitioned = partitioned
        self.reorder = reorder
        self.delayTicks = delayTicks
        self.dropRate = dropRate
        self.duplicates = duplicates
    }
}

/// A queue entry's payload. `.message` is the normal, production-shaped case:
/// every real `send(_:from:)` call enqueues one of these, and `deliver`
/// encodes it via `JSONEncoder` before I5-scanning it — exactly what a
/// conforming real transport would do. `.testOnlyRawTainted` exists solely so
/// the I5 adversarial check can drive genuinely tainted, pre-encoded JSON
/// bytes through the SAME `tick()` → `deliver()` codepath a real message
/// takes (see `deliver`'s doc comment) — `Op`'s hand-written `Codable`
/// conformance makes it structurally impossible to reach that codepath with
/// a legitimately-constructed `SyncMessage` carrying a forbidden key, so this
/// is the only way to prove the scan is wired into `deliver` itself rather
/// than merely callable in isolation.
private enum DeliveryPayload {
    case message(SyncMessage)
    case testOnlyRawTainted(String)
}

/// An in-process fake with a named replica set and per-pair directed queues.
public actor FakeSyncTransport {
    public struct ReplicaId: Hashable, Sendable {
        public let id: UUID
        public init(id: UUID = UUID()) { self.id = id }
    }

    // One continuation per replica's inbound AsyncStream.
    private var inboundContinuations: [ReplicaId: AsyncStream<SyncMessage>.Continuation] = [:]
    // Replica registration order — the ONLY deterministic ordering available
    // across process runs. `ReplicaId` embeds a random `UUID`, so sorting by
    // id (or relying on `Dictionary` iteration, which is seeded per-process
    // and bucket-placement-dependent on those same random ids) produces a
    // DIFFERENT receiver order on every run even for the same seed. `send`
    // and `tick` walk replicas via THIS array instead of `.keys` on any
    // dictionary, so the sequence of `rng` draws per tick is a pure function
    // of (seed, call order) — reproducible across processes (see ticket
    // "Watch out for": a failing seed must be replayable).
    private var replicaOrder: [ReplicaId] = []
    // Per-pair queues: (sender, receiver) → [(payload, tickCountdown, dupCount)].
    // `dupCount` is always 1 in practice — duplicates are expanded into
    // separate queue entries at send time (see `send`) so each copy can be
    // independently delayed/reordered by `tick()`, matching how a real
    // network would deliver duplicate packets as independent events.
    private var queues: [[ReplicaId]: [(payload: DeliveryPayload, countdown: Int, dupCount: Int)]] = [:]
    // Per-pair policies.
    private var policies: [[ReplicaId]: DeliveryPolicy] = [:]
    // Hold queues for offline replicas — outbound only, keyed by sender.
    private var holdQueues: [ReplicaId: [SyncMessage]] = [:]
    private var offlineReplicas: Set<ReplicaId> = []
    // Seeded RNG for reproducible fuzz runs — threaded, never re-seeded.
    private var rng: SeedableRNG
    // Append-only per-receiver delivery log, populated by `deliver()` at the
    // exact moment a message clears the I5 scan and is handed to the inbound
    // continuation. Test-only introspection: lets checks assert exact
    // delivered content/count/order by querying actor state directly
    // instead of racing an externally-drained `AsyncStream` against a
    // wall-clock sleep (the ticket's "Execution mode" requires the clock be
    // advanced only by explicit `tick()` calls, never wall time).
    private var deliveryLog: [ReplicaId: [SyncMessage]] = [:]

    /// A hold queue this large in the FAKE means a test is doing something
    /// unrealistic (see ticket "Watch out for": in a real transport this
    /// would need durable local queuing, not an unbounded in-memory array).
    private static let holdQueueOverflowLimit = 10_000

    public init(seed: UInt64) {
        self.rng = SeedableRNG(seed: seed)
    }

    /// Register a replica and return its inbound `AsyncStream`.
    public func makeReplica() -> (ReplicaId, AsyncStream<SyncMessage>) {
        let id = ReplicaId()
        let (stream, continuation) = AsyncStream<SyncMessage>.makeStream()
        inboundContinuations[id] = continuation
        replicaOrder.append(id)
        return (id, stream)
    }

    /// Send from `sender` to all other registered replicas — enqueues
    /// per-pair. Duplicates are NOT deduplicated (see ticket "Watch out for":
    /// hiding duplicates in the fake would hide a real question about
    /// whether `materialize` truly handles them).
    public func send(_ message: SyncMessage, from sender: ReplicaId) {
        if offlineReplicas.contains(sender) {
            holdQueues[sender, default: []].append(message)
            assert(
                holdQueues[sender]!.count < Self.holdQueueOverflowLimit,
                "hold queue overflow — use durable queueing in production transports"
            )
            return
        }
        // NOTE: `partitioned` is deliberately NOT checked here (unlike drop).
        // A partition means "no delivery for now", not "this message never
        // existed" — the ticket's own "Partition and heal" scenario requires
        // ops sent DURING the partition to arrive once it heals. The message
        // is queued normally and held at delivery time in `tick()` instead
        // (see there) — the same "pause, don't discard" treatment as an
        // offline receiver.
        for receiver in replicaOrder where receiver != sender {
            let pair = [sender, receiver]
            let policy = policies[pair] ?? DeliveryPolicy()
            let drop = Double.random(in: 0..<1, using: &rng) < policy.dropRate
            if drop { continue }
            let copies = max(1, policy.duplicates)
            let delay = max(0, policy.delayTicks)
            for _ in 0..<copies {
                queues[pair, default: []].append((.message(message), delay, 1))
            }
        }
    }

    /// Advance the clock one tick: decrement countdowns and deliver ready
    /// messages. Every message is I5-scanned immediately before it is
    /// yielded to the receiver's inbound continuation — a structural
    /// invariant of this transport, not a test-only convenience (see
    /// `SyncPayloadTaint`).
    ///
    /// A replica that is offline cannot RECEIVE either, not just send: real
    /// offline means no network in either direction (this is what makes the
    /// "offline/reconnect flood" scenario's "C has received nothing while
    /// offline" assertion true — see the ticket's "How we test it"). Any
    /// pair queue whose receiver is currently offline is left completely
    /// untouched here — countdowns pause, not just delivery — and resumes
    /// normal progress once the receiver reconnects. A partitioned pair gets
    /// the same pause treatment (see `send`'s note above).
    public func tick() {
        // Walk (sender, receiver) pairs in `replicaOrder × replicaOrder`
        // rather than `queues.keys` — `Dictionary` iteration order is not
        // stable across process runs (see `replicaOrder`'s doc comment), and
        // `policy.reorder`'s `shuffle(using: &rng)` consumes the SAME
        // threaded `rng` this loop shares with `send`, so processing pairs
        // in a nondeterministic order would make a seed's reorder/drop
        // decisions depend on incidental dictionary layout instead of only
        // on (seed, call sequence).
        for sender in replicaOrder {
            for receiver in replicaOrder where receiver != sender {
                let pair = [sender, receiver]
                guard let entries = queues[pair], !entries.isEmpty else { continue }
                guard !offlineReplicas.contains(receiver) else { continue }
                let policy = policies[pair] ?? DeliveryPolicy()
                guard !policy.partitioned else { continue }
                var ready: [DeliveryPayload] = []
                queues[pair] = entries.compactMap { entry in
                    let next = entry.countdown - 1
                    if next <= 0 { ready.append(entry.payload); return nil }
                    return (entry.payload, next, entry.dupCount)
                }
                if policy.reorder { ready.shuffle(using: &rng) }
                for payload in ready {
                    deliver(payload, to: receiver)
                }
            }
        }
    }

    /// I5 taint scan, then yield — see `SyncPayloadTaint.violations(inEncodedJSON:)`.
    /// This is the ONE place a queued payload becomes a delivered message, for
    /// BOTH real traffic (`.message`, enqueued by `send`) and the adversarial
    /// test-only path (`.testOnlyRawTainted`, enqueued only by
    /// `testOnlyEnqueueTaintedRawEntry`) — there is no second, parallel
    /// delivery function the scan could be wired into instead. That matters
    /// because a real `SyncMessage` can never legitimately encode a forbidden
    /// key (`Op`'s hand-written `Codable` conformance makes it structurally
    /// impossible — see `SyncPayloadTaint`), so proving the scan actually
    /// gates THIS function — not just that the scanner itself traps when
    /// called directly — requires routing adversarial bytes through the same
    /// `tick()` call a real message takes.
    ///
    /// Traps unconditionally, in BOTH debug and release builds (a bare
    /// `preconditionFailure`, not `#if DEBUG`-gated `assert`/`assertionFailure`,
    /// which is why this uses `precondition`-family calls rather than
    /// `assert`-family ones). A prior revision logged-and-silently-dropped
    /// the single tainted message in release builds while continuing normal
    /// operation for every other receiver: that is fail-OPEN, not fail-
    /// closed — one replica would end up applying an op the others silently
    /// never received, permanently breaking the I4 convergence guarantee the
    /// whole op-log core exists to provide, in exchange for the fake staying
    /// "up" after a bug that, by I5's own type-level guarantee, should be
    /// impossible to hit from a legitimate `SyncMessage` in the first place
    /// (see `SyncPayloadTaint`). Crashing loudly is strictly safer than that
    /// silent divergence for a test/fuzz-only substrate with no end user to
    /// protect from a crash.
    private func deliver(_ payload: DeliveryPayload, to receiver: ReplicaId) {
        let json: String
        let message: SyncMessage?
        switch payload {
        case .message(let real):
            guard let data = try? JSONEncoder().encode(real) else { return }
            json = String(decoding: data, as: UTF8.self)
            message = real
        case .testOnlyRawTainted(let rawJSON):
            json = rawJSON
            message = nil
        }
        let violations = SyncPayloadTaint.violations(inEncodedJSON: json)
        guard violations.isEmpty else {
            preconditionFailure("I5 violation: a payload transiting FakeSyncTransport carries forbidden token(s) \(violations) — refusing delivery.")
        }
        // Only `.message` ever reaches here with something to yield —
        // `.testOnlyRawTainted` exists purely to prove the scan above traps
        // before this point; it never represents a legitimate delivery.
        guard let message else { return }
        deliveryLog[receiver, default: []].append(message)
        inboundContinuations[receiver]?.yield(message)
    }

    /// TEST-ONLY: enqueue a raw, already-encoded JSON payload directly into
    /// (`sender`, `receiver`)'s delivery queue, bypassing `Op`/`LoggedOp`/
    /// `SyncMessage` entirely. The NEXT `tick()` call runs `rawEncodedJSON`
    /// through the exact same `deliver()` codepath a real message takes,
    /// countdown and all — proving the I5 scan is structurally wired into
    /// `deliver` itself (a regression that removed the scan from `deliver`
    /// would make this call stop trapping), not merely a pure function that
    /// happens to trap when called directly. This is the "test helper that
    /// forcibly injects ... a string into the encoded bytes" the ticket's
    /// "I5 on transit" check calls for. Never call this from production code;
    /// there is no legitimate `SyncMessage` this could ever represent (see
    /// `DeliveryPayload`).
    public func testOnlyEnqueueTaintedRawEntry(_ rawEncodedJSON: String, from sender: ReplicaId, to receiver: ReplicaId) {
        queues[[sender, receiver], default: []].append((.testOnlyRawTainted(rawEncodedJSON), 0, 1))
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

    // MARK: - Test/measurement introspection (not part of the fuzz-driver API)

    /// Number of ops currently buffered in `replica`'s hold queue (it is
    /// offline). Used by the dogfood manifest's hold-queue measurement.
    public func holdQueueDepth(_ replica: ReplicaId) -> Int {
        holdQueues[replica]?.count ?? 0
    }

    /// Encoded-byte footprint of `replica`'s hold queue — a real measured
    /// value (not a guess) for the dogfood manifest's memory budget.
    public func holdQueueByteFootprint(_ replica: ReplicaId) -> Int {
        guard let held = holdQueues[replica] else { return 0 }
        let encoder = JSONEncoder()
        return held.reduce(0) { total, message in
            total + ((try? encoder.encode(message))?.count ?? 0)
        }
    }

    /// Every message `receiver` has been handed so far, in delivery order.
    /// Backed by `deliveryLog`, populated synchronously inside `deliver()` —
    /// querying this actor method is itself the synchronization point (an
    /// `await` on the actor), so callers get an up-to-date, exact answer
    /// with no `AsyncStream`-draining race and no wall-clock wait required
    /// (see `deliveryLog`'s doc comment).
    public func delivered(to receiver: ReplicaId) -> [SyncMessage] {
        deliveryLog[receiver] ?? []
    }
}

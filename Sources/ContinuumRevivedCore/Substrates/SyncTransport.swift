import Foundation

// Ticket: docs/38-tickets/12-injectable-substrates.md
//
// The op-log push/pull seam for the spatial layer (D3/D4). Exactly two protocol
// requirements. The fake adds a test-only `deliver()` affordance (NOT part of the
// protocol) that flushes queued ops to subscribers according to a network `mode`
// — this is how the convergence fuzz and transport soak (later tickets) drive
// dropped/reordered delivery. The real CloudKit transport delivers continuously
// via CKSubscription pushes; there is no manual flush there.
public enum TransportMode: Sendable {
    case reliable
    case partition                  // drops all ops
    case reorder(seed: UInt64)      // shuffles before delivery
    case lossy(dropRate: Double)    // drops each op with given probability
}

public protocol SyncTransport: Sendable {
    func push(_ op: TransportLoggedOp) async throws
    @discardableResult
    func subscribe(_ onDelivery: @escaping @Sendable (TransportLoggedOp) -> Void) -> SubscriptionToken
}

public struct SubscriptionToken: Hashable, Sendable {
    public let id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

public final class FakeSyncTransport: SyncTransport, @unchecked Sendable {
    public var mode: TransportMode = .reliable
    public private(set) var emitted: [TransportLoggedOp] = []     // everything ever push()ed
    public private(set) var delivered: [TransportLoggedOp] = []   // everything flushed to subscribers
    private var pending: [TransportLoggedOp] = []                  // push()ed but not yet deliver()ed
    private var subscribers: [SubscriptionToken: @Sendable (TransportLoggedOp) -> Void] = [:]

    // Seeded PRNG state backing `.lossy`'s per-op coin flip. `.reorder` takes its
    // own explicit seed per call instead (see `shuffled(_:seed:)`), since a
    // caller may want a specific reorder run reproducible independent of how
    // many `.lossy` draws preceded it. Both paths are splitmix64-based so
    // neither depends on wall-clock or system randomness.
    private var lossyState: UInt64

    public init(lossySeed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        self.lossyState = lossySeed
    }

    // Protocol: push queues the op (does NOT auto-deliver — tests control timing via deliver()).
    public func push(_ op: TransportLoggedOp) async throws {
        emitted.append(op)
        pending.append(op)
    }

    // Protocol: register a subscriber, get a cancellable token.
    @discardableResult
    public func subscribe(_ onDelivery: @escaping @Sendable (TransportLoggedOp) -> Void) -> SubscriptionToken {
        let token = SubscriptionToken()
        subscribers[token] = onDelivery
        return token
    }

    public func cancel(_ token: SubscriptionToken) {
        subscribers[token] = nil
    }

    // TEST-ONLY affordance — NOT part of the SyncTransport protocol. Applies
    // `mode` to the pending queue, appends survivors to `delivered`, and fans
    // them out to every registered subscriber.
    public func deliver() {
        let batch: [TransportLoggedOp]
        switch mode {
        case .reliable:
            batch = pending
        case .partition:
            batch = []
        case .reorder(let seed):
            batch = Self.shuffled(pending, seed: seed)
        case .lossy(let dropRate):
            batch = pending.filter { _ in nextUnit() >= dropRate }
        }
        pending.removeAll()
        for op in batch {
            delivered.append(op)
            for handler in subscribers.values { handler(op) }
        }
    }

    /// Next pseudo-random value in [0, 1), advancing `lossyState` deterministically.
    private func nextUnit() -> Double {
        lossyState = Self.splitmix64Next(lossyState)
        return Double(lossyState >> 11) * (1.0 / Double(1 << 53))
    }

    private static func splitmix64Next(_ state: UInt64) -> UInt64 {
        var z = state &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Deterministic Fisher-Yates shuffle keyed by `seed` — independent of any
    /// prior calls, so the same seed always yields the same permutation.
    private static func shuffled(_ items: [TransportLoggedOp], seed: UInt64) -> [TransportLoggedOp] {
        guard items.count > 1 else { return items }
        var state = seed
        var result = items
        for i in stride(from: result.count - 1, to: 0, by: -1) {
            state = splitmix64Next(state)
            let j = Int(state % UInt64(i + 1))
            result.swapAt(i, j)
        }
        return result
    }
}

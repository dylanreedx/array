import Foundation
import ContinuumRevivedCore

// Ticket: docs/38-tickets/86-relay-sync-transport.md (D4-R1)
//
// The transport-agnostic relay core. Sockets are adapters (slice 2); all
// correctness proofs run against this actor in-process, forever — the same
// doctrine that keeps the I4 fuzz on `FakeSyncTransport` and never a real
// network.
//
// Semantics pinned by `ContinuumRevivedRelayChecks`:
// - `seq` is strictly monotonic, assigned at publish, starting at 1.
// - The hub does NOT dedupe. Duplicate `LoggedOp`s are `materialize`'s job
//   (idempotent by `OpId`), and hiding duplicates here would weaken what the
//   fuzz exercises downstream.
// - Every publish passes the I5 taint gate over its ENCODED bytes before it
//   enters the ring; violations are refused, never delivered.
// - Catch-up is lossless or refused, never silently holey. A published
//   snapshot is authoritative for everything its publisher emitted before
//   it (the desktop publishes `CompactedSnapshot`s compacted from its full
//   log), so "snapshot + every ring entry after it" is a complete feed.
public actor RelayHub {
    /// Maps a bearer token (from the D6 pairing exchange) to what it may do.
    /// Injected so the hub stays free of any identity system.
    public typealias TokenValidator = @Sendable (String) async -> RelayGrant?

    private let ringCapacity: Int
    private let validator: TokenValidator
    private var nextSeq: UInt64 = 1
    private var ring: [RelayEnvelope] = []
    private var latestSnapshot: RelayEnvelope?
    private var subscribers: [UUID: Subscriber] = [:]
    /// Total encoded bytes the I5 gate has scanned on the real publish path.
    /// Checks assert this grows with every publish — proof the gate is wired
    /// into delivery, not just available.
    public private(set) var taintScannedByteCount = 0

    private struct Subscriber {
        let grant: RelayGrant
        let continuation: AsyncStream<RelayEnvelope>.Continuation
    }

    public init(ringCapacity: Int = 512, validator: @escaping TokenValidator) {
        precondition(ringCapacity > 0, "ring must hold at least one envelope")
        self.ringCapacity = ringCapacity
        self.validator = validator
    }

    // MARK: Subscribe

    /// Validates the hello, then returns the welcome plus a stream that
    /// yields the lossless backlog for the client's cursor followed by every
    /// future publish, in hub order. Backlog construction and subscriber
    /// registration happen in one actor turn, so no publish can slip between
    /// them.
    public func subscribe(hello: RelayClientHello) async throws -> (welcome: RelayServerWelcome, stream: AsyncStream<RelayEnvelope>) {
        guard hello.protocolVersion == RelayProtocol.version else {
            throw RelayHelloError.unsupportedProtocolVersion(hello.protocolVersion)
        }
        guard let grant = await validator(hello.token) else {
            throw RelayHelloError.unauthorized
        }
        let backlog = try backlog(for: hello.cursor)
        let sessionId = UUID()
        var continuation: AsyncStream<RelayEnvelope>.Continuation!
        let stream = AsyncStream<RelayEnvelope> { continuation = $0 }
        for envelope in backlog {
            continuation.yield(envelope)
        }
        subscribers[sessionId] = Subscriber(grant: grant, continuation: continuation)
        continuation.onTermination = { _ in
            Task { await self.disconnect(sessionId) }
        }
        return (RelayServerWelcome(sessionId: sessionId, latestSeq: nextSeq - 1), stream)
    }

    public func disconnect(_ sessionId: UUID) {
        subscribers.removeValue(forKey: sessionId)?.continuation.finish()
    }

    public var subscriberCount: Int { subscribers.count }

    // MARK: Publish

    /// Validates scope, runs the I5 gate over the encoded message, assigns
    /// the next seq, and fans out to every live subscriber. Returns the
    /// assigned seq.
    @discardableResult
    public func publish(token: String, message: SyncMessage) async throws -> UInt64 {
        guard let grant = await validator(token) else {
            throw RelayPublishError.unauthorized
        }
        guard grant.canPublish else {
            throw RelayPublishError.scopeForbidsPublish
        }
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(message)
        } catch {
            throw RelayPublishError.encodingFailed(reason: String(describing: error))
        }
        try admitScanningTaint(encodedJSON: String(decoding: encoded, as: UTF8.self))
        return admit(message: message)
    }

    /// Adversarial seam for checks ONLY: feeds pre-encoded bytes to the same
    /// gate `publish` uses, bypassing the type system the way no real
    /// `SyncMessage` can (`Op`'s hand-written Codable makes a forbidden key
    /// structurally impossible — see `SyncPayloadTaint`). Nothing that passes
    /// is admitted to the ring; this seam exists to prove REFUSAL.
    public func scanPreEncodedForChecks(token: String, encodedJSON: String) async throws {
        guard let grant = await validator(token) else {
            throw RelayPublishError.unauthorized
        }
        guard grant.canPublish else {
            throw RelayPublishError.scopeForbidsPublish
        }
        try admitScanningTaint(encodedJSON: encodedJSON)
    }

    // MARK: Internals

    private func admitScanningTaint(encodedJSON: String) throws {
        taintScannedByteCount += encodedJSON.utf8.count
        let violations = SyncPayloadTaint.violations(inEncodedJSON: encodedJSON)
        guard violations.isEmpty else {
            throw RelayPublishError.taintViolation(patterns: violations)
        }
    }

    private func admit(message: SyncMessage) -> UInt64 {
        let envelope = RelayEnvelope(seq: nextSeq, message: message)
        nextSeq += 1
        ring.append(envelope)
        if ring.count > ringCapacity {
            ring.removeFirst(ring.count - ringCapacity)
        }
        if case .snapshot = message {
            latestSnapshot = envelope
        }
        for subscriber in subscribers.values {
            subscriber.continuation.yield(envelope)
        }
        return envelope.seq
    }

    /// The lossless backlog for a cursor, or a thrown refusal — never a feed
    /// with a hole in it.
    ///
    /// - Cursor whose tail is fully inside the ring → exactly the envelopes
    ///   after it.
    /// - Cursor evicted → latest snapshot + the tail after the snapshot, but
    ///   ONLY if that tail is itself fully inside the ring
    ///   (`snapshot.seq + 1 >= ringStart`); otherwise refused.
    /// - Fresh subscriber (nil cursor) → snapshot + tail when a snapshot
    ///   exists; the full ring when the ring still starts at seq 1; refused
    ///   when history was evicted and no snapshot can stand in for it.
    private func backlog(for cursor: UInt64?) throws -> [RelayEnvelope] {
        guard let ringStart = ring.first?.seq else {
            return []
        }
        if let cursor {
            if cursor + 1 >= ringStart {
                return ring.filter { $0.seq > cursor }
            }
            guard let snapshot = latestSnapshot, snapshot.seq + 1 >= ringStart else {
                throw RelayHelloError.cursorUnrecoverable(cursor: cursor, ringStart: ringStart)
            }
            return [snapshot] + ring.filter { $0.seq > snapshot.seq }
        }
        if let snapshot = latestSnapshot, snapshot.seq + 1 >= ringStart {
            return [snapshot] + ring.filter { $0.seq > snapshot.seq }
        }
        guard ringStart == 1 else {
            throw RelayHelloError.cursorUnrecoverable(cursor: 0, ringStart: ringStart)
        }
        return ring
    }
}

import Foundation
import ContinuumRevivedCore

// Ticket: docs/38-tickets/55-synctransport-seam.md
//
// The transport boundary for Phase 6 sync. `SyncTransport` names the
// smallest possible surface a real transport (CloudKit, WebSockets, or
// anything else) must satisfy: deliver a `SyncMessage` to peers, receive a
// stream of `SyncMessage` values from them, and signal connection state.
// Nothing here names CloudKit, WebSockets, or any specific delivery
// mechanism — those live behind this seam, not on it.
//
// NOTE ON NAMING: `Sources/ContinuumRevivedCore/Substrates/SyncTransport.swift`
// (ticket 12, "injectable substrates") already defines a `SyncTransport`
// protocol and `FakeSyncTransport` class with a different, earlier-drafted
// shape (`push`/`subscribe` over an opaque `TransportLoggedOp`). This ticket
// does not modify or remove that file — "no files in
// Sources/ContinuumRevivedCore/ are modified by this ticket" is a hard
// constraint (see the ticket's "Where it lives"). The two same-named types
// live in different modules; callers that need both in one file (e.g. a
// future coordinator) disambiguate with the module prefix
// (`ContinuumRevivedSync.SyncTransport` / `ContinuumRevivedCore.SyncTransport`).
// Reconciling the two is out of this ticket's scope.

/// Connection lifecycle the consumer (connection supervisor / UI) reacts to.
public enum ConnectionState: Sendable, Equatable {
    case connected
    case reconnecting
    case disconnected(reason: String)
}

/// Failures a `SyncTransport` conformance can surface from `send(_:)`.
/// Deliberately narrow: the protocol excludes acknowledgement, retry, and
/// idempotency machinery (that is the transport's job, not the caller's), so
/// there is no per-message ack/nack error — only "could not send at all".
public enum SyncTransportError: Error, Sendable, Equatable {
    case notConnected
    case sendFailed(reason: String)
}

/// A message the transport can carry — either a single op or a compacted
/// snapshot used to bootstrap a fresh/lagging replica. Synthesized `Codable`
/// is intentional here (unlike `Op`'s hand-written wire format): this is an
/// in-flight transport envelope, not a frozen persisted-forever format.
public enum SyncMessage: Codable, Sendable, Equatable {
    case op(LoggedOp)
    case snapshot(CompactedSnapshot)
    case activity(ActivityStreamItem)
    case activitySubscribe(ActivitySubscribeRequest)
    case spatialSubscribe(SpatialSubscribeRequest)
    case approvalResponse(ApprovalResponseRequest)
    case approvalResponseAck(ApprovalResponseAck)
}

/// P2A.8: addressed by AGENT, not by tile. The phone reads this id off an
/// `AgentsBoardRow`/`ApprovalResponseTarget`, both of which are now agent-keyed, so a
/// field named `tileId` here would be carrying an agent id under the old name — the
/// half-migrated state the ticket forbids. Decodes a legacy `tileId` payload for the
/// same reason `AgentActivityEvent` does: historically the two ids were one value.
public struct ApprovalResponseRequest: Codable, Sendable, Equatable {
    public let agentId: UUID
    public let requestId: String
    public let decision: ApprovalDecision

    public init(agentId: UUID, requestId: String, decision: ApprovalDecision) {
        self.agentId = agentId
        self.requestId = requestId
        self.decision = decision
    }

    private enum CodingKeys: String, CodingKey {
        case agentId, tileId, requestId, decision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let agentId = try container.decodeIfPresent(UUID.self, forKey: .agentId) {
            self.agentId = agentId
        } else {
            self.agentId = try container.decode(UUID.self, forKey: .tileId)
        }
        requestId = try container.decode(String.self, forKey: .requestId)
        decision = try container.decode(ApprovalDecision.self, forKey: .decision)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(agentId, forKey: .agentId)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(decision, forKey: .decision)
    }
}

public enum ApprovalResponseOutcome: String, Codable, Sendable, Equatable {
    case resolved
    case stale
    case unauthorized
    case unknownRequest
}

public struct ApprovalResponseAck: Codable, Sendable, Equatable {
    public let requestId: String
    public let outcome: ApprovalResponseOutcome

    public init(requestId: String, outcome: ApprovalResponseOutcome) {
        self.requestId = requestId
        self.outcome = outcome
    }
}

/// Spatial subscription control message — the `.subscribeSpatial` analog of
/// `ActivitySubscribeRequest`. Empty for now: cold connect always serves the
/// full snapshot in v1 (no cursor tonight — ticket 61b banner (a).1); the
/// envelope is synthesized-`Codable`, so adding a cursor later is cheap and
/// unfrozen.
public struct SpatialSubscribeRequest: Codable, Sendable, Equatable {
    public init() {}
}

/// The transport boundary. Concrete implementations include
/// `FakeSyncTransport` (in-process, adversarial — see `FakeSyncTransport.swift`)
/// and `CloudKitSyncTransport` (real, a later Phase 6 ticket). All methods are
/// async/throws; callers are Swift concurrency actors.
public protocol SyncTransport: Sendable {
    /// Outbound: push a message to all connected peers. Fire-and-forget from
    /// the caller's perspective — the transport handles retries, idempotency,
    /// and ordering guarantees internally. `async throws` (not synchronous)
    /// so a conforming transport can `await` back-pressure before returning;
    /// do not make this synchronous "for simplicity" (see ticket "Watch out").
    func send(_ message: SyncMessage) async throws

    /// Inbound: a stream of messages received from peers. Consume with
    /// `for await`. The sequence is infinite until the transport is torn down.
    var inbound: AsyncStream<SyncMessage> { get }

    /// Connection state changes. Consume with `for await` to drive the
    /// connection supervisor and the UI without polling.
    var connectionState: AsyncStream<ConnectionState> { get }
}

/// I5 taint scan — a structural invariant of the transport layer, not just a
/// test. No `SyncMessage` carrying a `runtimeRef`, pane target, or
/// host-local handle may transit any transport (fake or real) any more than
/// it could transit CloudKit. Scoped to JSON *key* patterns — colon-anchored
/// (`"pid":`, not bare `"pid"`) so the scan matches only where the token
/// appears as an actual object key in the encoded output, never as a
/// substring of a free-text VALUE. A bare-quoted pattern like `"pid"` would
/// also match a legitimate user-entered tile titled exactly "pid" (its
/// encoding is `..."title":"pid"...`, which contains the substring `"pid"`)
/// — that false positive was caught in review; the colon anchor fixes it,
/// because JSONEncoder escapes any quote characters embedded inside a
/// String value (`\"`), so a value can never forge an unescaped `"key":`
/// sequence no matter what text a user types.
public enum SyncPayloadTaint {
    public static let forbiddenKeyPatterns: [String] = [
        "\"runtimeRef\":",
        "\"pid\":",
        "\"paneTarget\":",
        "\"scrollback\":",
        "\"tmuxTarget\":",
    ]

    /// Pure detection over already-encoded JSON text. This is the exact
    /// primitive `FakeSyncTransport` wires into its real delivery path, so
    /// exercising it directly proves the same detection logic that runs
    /// structurally in the fake. Takes text (not a `SyncMessage`) because
    /// `Op`'s hand-written `Codable` conformance makes it structurally
    /// IMPOSSIBLE for any real, type-safe `SyncMessage` to encode a
    /// forbidden token as a JSON key — that impossibility is I5's actual
    /// guarantee (the type system already prevents it), not a gap this scan
    /// needs to close. Proving the scan itself (not just "nothing legitimate
    /// trips it") requires feeding it adversarial, already-encoded bytes
    /// that bypass `Op`/`LoggedOp`/`SyncMessage` entirely.
    public static func violations(inEncodedJSON json: String) -> [String] {
        forbiddenKeyPatterns.filter { json.contains($0) }
    }

    /// Convenience: encode a real `SyncMessage` and scan it. In practice
    /// this can never find a violation (see above) — it exists so ad hoc
    /// callers (checks, other module consumers) don't have to encode by
    /// hand.
    public static func violations(in message: SyncMessage) -> [String] {
        guard let data = try? JSONEncoder().encode(message) else { return [] }
        return violations(inEncodedJSON: String(decoding: data, as: UTF8.self))
    }
}

import Foundation
import ContinuumRevivedCore

// Ticket: docs/38-tickets/86-relay-sync-transport.md (D4-R1)
//
// Wire vocabulary for the self-owned relay. Synthesized `Codable` is
// intentional — these are in-flight transport frames, not a frozen
// persisted-forever format (same doctrine as `SyncMessage` itself).
// Nothing here names a delivery mechanism: the frames are carried by
// whatever adapter fronts `RelayHub` (in-process in checks, HTTP long-poll
// or WebSocket in slice 2), and the hub's semantics are identical under all
// of them.

public enum RelayProtocol {
    public static let version = 1
}

/// First frame a client sends. `cursor` is the highest `RelayEnvelope.seq`
/// the client has applied; nil means a fresh subscriber with no history.
public struct RelayClientHello: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var token: String
    public var deviceLabel: String
    public var cursor: UInt64?

    public init(protocolVersion: Int = RelayProtocol.version, token: String, deviceLabel: String, cursor: UInt64?) {
        self.protocolVersion = protocolVersion
        self.token = token
        self.deviceLabel = deviceLabel
        self.cursor = cursor
    }
}

/// The hub's reply to an accepted hello. `latestSeq` is the newest seq the
/// hub had assigned at hello time (0 = nothing published yet); the client's
/// stream begins with the lossless backlog and continues live from there.
public struct RelayServerWelcome: Codable, Sendable, Equatable {
    public var sessionId: UUID
    public var latestSeq: UInt64

    public init(sessionId: UUID, latestSeq: UInt64) {
        self.sessionId = sessionId
        self.latestSeq = latestSeq
    }
}

/// One relayed message. `seq` is assigned by the hub at publish time and is
/// strictly monotonic across the hub's lifetime, starting at 1.
public struct RelayEnvelope: Codable, Sendable, Equatable {
    public var seq: UInt64
    public var message: SyncMessage

    public init(seq: UInt64, message: SyncMessage) {
        self.seq = seq
        self.message = message
    }
}

/// What a validated pairing token is allowed to do. The mapping from token
/// to grant is injected (`RelayHub.TokenValidator`) so the hub never learns
/// about `CompanionAuthService`, keychains, or any identity system — D6's
/// account-less model is the only auth the relay has.
public struct RelayGrant: Sendable, Equatable {
    public var scopes: Scope

    public init(scopes: Scope) {
        self.scopes = scopes
    }

    /// Publishing is the desktop's leg. Observer-scoped grants (the phone)
    /// subscribe only — the same type-level guarantee D5 pins for iOS.
    public var canPublish: Bool {
        scopes.contains(.orchestrationOperate)
    }
}

public enum RelayHelloError: Error, Sendable, Equatable {
    case unauthorized
    case unsupportedProtocolVersion(Int)
    /// The client's cursor fell behind the ring and no published snapshot
    /// can bridge the gap losslessly. The client must clear local state and
    /// reconnect fresh once a snapshot exists; the hub never serves a feed
    /// with a silent hole in it.
    case cursorUnrecoverable(cursor: UInt64, ringStart: UInt64)
}

public enum RelayPublishError: Error, Sendable, Equatable {
    case unauthorized
    case scopeForbidsPublish
    /// I5: the encoded payload matched a forbidden key pattern. Refused,
    /// never delivered — same contract `FakeSyncTransport` enforces.
    case taintViolation(patterns: [String])
    case encodingFailed(reason: String)
}

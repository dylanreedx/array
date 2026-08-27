import Foundation

public enum RelayWire {
    public static let version = 2
    public static let companionCapabilities: Set<RelayCapability> = [
        .readActivity, .readWorkspaces, .readCanvas, .readTranscripts,
        .respondToApprovals, .stopAgents,
    ]
}

public enum RelayCredentialRole: String, Codable, Sendable { case desktop, companion }
public enum RelayCapability: String, Codable, Sendable, CaseIterable {
    case publishState, createPairingGrant, revokeDevices
    case readActivity, readWorkspaces, readCanvas, readTranscripts
    case respondToApprovals, stopAgents
}

public struct RelayEvent: Codable, Sendable, Equatable {
    public var sequence: Int64
    public var kind: String
    public var payload: Data
    public var createdAt: Date
    public init(sequence: Int64 = 0, kind: String, payload: Data, createdAt: Date = .init()) {
        self.sequence = sequence; self.kind = kind; self.payload = payload; self.createdAt = createdAt
    }
}

public struct RelayEventPage: Codable, Sendable, Equatable {
    public var snapshot: RelayEvent?
    public var events: [RelayEvent]
    public var latestSequence: Int64
    public init(snapshot: RelayEvent?, events: [RelayEvent], latestSequence: Int64) {
        self.snapshot = snapshot; self.events = events; self.latestSequence = latestSequence
    }
}

public struct RelayInviteRedemption: Codable, Sendable, Equatable {
    public var code: String; public var deviceLabel: String
    public init(code: String, deviceLabel: String) { self.code = code; self.deviceLabel = deviceLabel }
}
public struct RelayDesktopProvisioning: Codable, Sendable, Equatable {
    public var instanceID: UUID; public var credential: String
    public init(instanceID: UUID, credential: String) { self.instanceID = instanceID; self.credential = credential }
}
public struct RelayPairingGrantRequest: Codable, Sendable, Equatable {
    public var deviceLabel: String
    public init(deviceLabel: String) { self.deviceLabel = deviceLabel }
}
public struct RelayPairingGrant: Codable, Sendable, Equatable {
    public var id: UUID; public var code: String; public var expiresAt: Date
    public init(id: UUID = UUID(), code: String, expiresAt: Date) { self.id = id; self.code = code; self.expiresAt = expiresAt }
}
public struct RelayPairingExchange: Codable, Sendable, Equatable {
    public var code: String; public var deviceLabel: String
    public init(code: String, deviceLabel: String) { self.code = code; self.deviceLabel = deviceLabel }
}
public struct RelayPairingCancellationResponse: Codable, Sendable, Equatable {
    public var id: UUID; public var cancelled: Bool
    public init(id: UUID, cancelled: Bool) { self.id = id; self.cancelled = cancelled }
}
public struct RelayCompanionProvisioning: Codable, Sendable, Equatable {
    public var instanceID: UUID; public var deviceID: UUID; public var credential: String; public var capabilities: Set<RelayCapability>
    public init(instanceID: UUID, deviceID: UUID, credential: String, capabilities: Set<RelayCapability>) {
        self.instanceID = instanceID; self.deviceID = deviceID; self.credential = credential; self.capabilities = capabilities
    }
}
public struct RelayDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID; public var label: String; public var lastSeenAt: Date?; public var capabilities: Set<RelayCapability>
    public init(id: UUID, label: String, lastSeenAt: Date?, capabilities: Set<RelayCapability>) { self.id = id; self.label = label; self.lastSeenAt = lastSeenAt; self.capabilities = capabilities }
}
public enum RelayPushRegistrationKind: String, Codable, Sendable, CaseIterable {
    case apns, widget, liveActivity
    case liveActivityStart = "liveactivity-start"
}
public struct RelayPushRegistrationRequest: Codable, Sendable, Equatable {
    public var kind: RelayPushRegistrationKind; public var token: Data
    public init(kind: RelayPushRegistrationKind, token: Data) { self.kind = kind; self.token = token }
}
public struct RelayPushRegistrationResponse: Codable, Sendable, Equatable {
    public var kind: RelayPushRegistrationKind; public var registered: Bool
    public init(kind: RelayPushRegistrationKind, registered: Bool) { self.kind = kind; self.registered = registered }
}
public struct RelayPublishRequest: Codable, Sendable, Equatable {
    public var kind: String; public var payload: Data; public var isSnapshot: Bool
    public init(kind: String, payload: Data, isSnapshot: Bool = false) { self.kind = kind; self.payload = payload; self.isSnapshot = isSnapshot }
}
public struct RelayCommandRequest: Codable, Sendable, Equatable {
    public var idempotencyKey: UUID; public var kind: String; public var agentID: UUID
    public init(idempotencyKey: UUID, kind: String, agentID: UUID) { self.idempotencyKey = idempotencyKey; self.kind = kind; self.agentID = agentID }
}
public struct RelayCommandReceipt: Codable, Sendable, Equatable {
    public var idempotencyKey: UUID; public var accepted: Bool; public var createdAt: Date
    public init(idempotencyKey: UUID, accepted: Bool, createdAt: Date) { self.idempotencyKey = idempotencyKey; self.accepted = accepted; self.createdAt = createdAt }
}
public struct RelayHealth: Codable, Sendable, Equatable {
    public var status: String; public var schemaVersion: Int
    public init(status: String = "ok", schemaVersion: Int) { self.status = status; self.schemaVersion = schemaVersion }
}
public struct RelayErrorResponse: Codable, Sendable, Equatable {
    public var code: String
    public init(code: String) { self.code = code }
}

public enum RelaySocketFrame: Codable, Sendable, Equatable {
    case authenticate(token: String, cursor: Int64?)
    case welcome(instanceID: UUID, latestSequence: Int64, capabilities: Set<RelayCapability>)
    case event(RelayEvent)
    case publish(RelayPublishRequest)
    case command(RelayCommandRequest)
    case receipt(RelayCommandReceipt)
    case ping
    case pong
    case error(code: String)
}

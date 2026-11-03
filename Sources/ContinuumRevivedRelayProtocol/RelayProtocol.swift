import Foundation

public enum RelayWire {
    public static let version = 2
    /// Populated desktop inventories exceed the original 512 KiB ceiling.
    public static let maximumEventPayloadBytes = 8 * 1024 * 1024
    /// Includes worst-case escaped base64 plus envelope overhead. Bound ingress
    /// separately so an invalid request cannot grow the HTTP accumulator forever.
    public static let maximumRequestBodyBytes = 24 * 1024 * 1024
    public static let maximumEventTailBytes = 16 * 1024 * 1024
    public static let companionCapabilities: Set<RelayCapability> = [
        .readActivity, .readWorkspaces, .readCanvas, .readTranscripts,
        .respondToApprovals, .stopAgents,
    ]
    /// Plan 104 step 3: a phone that asks for it at pairing may also send the
    /// agent a message. Only on request, because a phone build from before
    /// this refuses any credential whose capabilities differ from the set it
    /// knows; granting it to every phone would stop those phones pairing.
    public static let companionMessagingCapabilities: Set<RelayCapability> = companionCapabilities.union([.sendMessages])
}

public enum RelayCredentialRole: String, Codable, Sendable { case desktop, companion }
public enum RelayCapability: String, Codable, Sendable, CaseIterable {
    case publishState, createPairingGrant, revokeDevices
    case readActivity, readWorkspaces, readCanvas, readTranscripts
    case respondToApprovals, stopAgents
    case sendMessages
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
    /// Asks for `sendMessages`. Absent from older phones.
    public var wantsMessages: Bool?
    public init(code: String, deviceLabel: String, wantsMessages: Bool? = nil) {
        self.code = code; self.deviceLabel = deviceLabel; self.wantsMessages = wantsMessages
    }
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
/// A phone asking its Mac to do something. The relay checks the phone's
/// capability for `kind`, records which device sent it, and holds it until the
/// Mac collects it or it expires; it never interprets `payload`.
public struct RelayCommandRequest: Codable, Sendable, Equatable {
    public var idempotencyKey: UUID; public var kind: String; public var agentID: UUID
    public var payload: Data?
    public init(idempotencyKey: UUID, kind: String, agentID: UUID, payload: Data? = nil) {
        self.idempotencyKey = idempotencyKey; self.kind = kind; self.agentID = agentID; self.payload = payload
    }
}
public struct RelayCommandReceipt: Codable, Sendable, Equatable {
    public var idempotencyKey: UUID; public var accepted: Bool; public var createdAt: Date
    public init(idempotencyKey: UUID, accepted: Bool, createdAt: Date) { self.idempotencyKey = idempotencyKey; self.accepted = accepted; self.createdAt = createdAt }
}
public enum RelayCommandKind {
    public static let agentStop = "agent.stop"
    public static let approvalRespond = "approval.respond"
    /// The phone asks for one agent's transcript; the Mac answers by
    /// publishing it encrypted as an ordinary event. Payload:
    /// `CompanionTranscriptRequest` (key id and known version, no content).
    public static let transcriptRequest = "transcript.request"
    /// The phone sends the agent a message. Payload: `CompanionSealedMessage`,
    /// text sealed with a key from the pairing secret; the relay cannot read it.
    public static let agentMessage = "agent.message"
}
public enum RelayCommandLimits {
    /// A command the Mac has not collected by then is never run: a Stop
    /// pressed an hour ago must not land on whatever the agent does now.
    public static let lifetime: TimeInterval = 10 * 60
    /// Answered and expired commands are deleted after this, on the next
    /// command from the same Mac's phones. Far past `lifetime`, so nothing
    /// that could still run is touched; the phone reads a result within
    /// seconds. Without it a phone asking for a transcript every 5 s grows the
    /// table without bound.
    public static let retention: TimeInterval = 24 * 60 * 60
    public static let maximumPayloadBytes = 16 * 1024
    public static let maximumOutcomeBytes = 64
    public static let maximumDetailBytes = 512
    public static let pageSize = 50
}
/// A pending command as the Mac collects it. `deviceID` is the phone the relay
/// authenticated, never a value the phone wrote into the request.
public struct RelayCommand: Codable, Sendable, Equatable {
    public var idempotencyKey: UUID; public var kind: String; public var agentID: UUID
    public var deviceID: UUID?; public var payload: Data?; public var createdAt: Date
    public init(idempotencyKey: UUID, kind: String, agentID: UUID, deviceID: UUID?, payload: Data?, createdAt: Date) {
        self.idempotencyKey = idempotencyKey; self.kind = kind; self.agentID = agentID
        self.deviceID = deviceID; self.payload = payload; self.createdAt = createdAt
    }
}
public struct RelayCommandPage: Codable, Sendable, Equatable {
    public var commands: [RelayCommand]
    public init(commands: [RelayCommand]) { self.commands = commands }
}
/// What the Mac did. `outcome` is the Mac's own word for it (for example
/// `stopped`, `notFound`); the relay stores it once and never reinterprets it.
public struct RelayCommandResult: Codable, Sendable, Equatable {
    public var outcome: String; public var detail: String?
    public init(outcome: String, detail: String? = nil) { self.outcome = outcome; self.detail = detail }
}
public struct RelayCommandStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case pending, completed, expired }
    public var idempotencyKey: UUID; public var kind: String; public var agentID: UUID
    public var state: State; public var outcome: String?; public var detail: String?
    public var createdAt: Date; public var completedAt: Date?
    public init(idempotencyKey: UUID, kind: String, agentID: UUID, state: State, outcome: String? = nil,
                detail: String? = nil, createdAt: Date, completedAt: Date? = nil) {
        self.idempotencyKey = idempotencyKey; self.kind = kind; self.agentID = agentID; self.state = state
        self.outcome = outcome; self.detail = detail; self.createdAt = createdAt; self.completedAt = completedAt
    }
}
public struct RelayHealth: Codable, Sendable, Equatable {
    public var status: String; public var schemaVersion: Int
    public var notificationPolicies: [String]
    public init(status: String = "ok", schemaVersion: Int, notificationPolicies: [String] = []) {
        self.status = status; self.schemaVersion = schemaVersion; self.notificationPolicies = notificationPolicies
    }
    private enum CodingKeys: String, CodingKey { case status, schemaVersion, notificationPolicies }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(String.self, forKey: .status); schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        notificationPolicies = try c.decodeIfPresent([String].self, forKey: .notificationPolicies) ?? []
    }
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

import Foundation

public enum ManagedSessionStatus: String, Codable, Equatable, Sendable {
    case starting
    case running
    case stopped
    case error
}

public struct ManagedAgentSessionRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let tileId: UUID
    public var agentKind: AgentKind
    public var status: ManagedSessionStatus
    public var lastSeenAt: Date
    public var resumeCursor: Data?
    public var runtimePayload: Data?

    public init(
        schemaVersion: Int = ManagedAgentSessionRecord.currentSchemaVersion,
        tileId: UUID,
        agentKind: AgentKind,
        status: ManagedSessionStatus = .starting,
        lastSeenAt: Date,
        resumeCursor: Data? = nil,
        runtimePayload: Data? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.tileId = tileId
        self.agentKind = agentKind
        self.status = status
        self.lastSeenAt = lastSeenAt
        self.resumeCursor = resumeCursor
        self.runtimePayload = runtimePayload
    }

    public struct RuntimePayloadFields: Codable, Equatable, Sendable {
        public var tmuxWindowTarget: String
        public var cwd: String?

        public init(tmuxWindowTarget: String, cwd: String?) {
            self.tmuxWindowTarget = tmuxWindowTarget
            self.cwd = cwd
        }
    }

    public func tmuxWindowTarget() -> String? {
        guard let runtimePayload,
              let fields = try? JSONCodec.makeDecoder().decode(RuntimePayloadFields.self, from: runtimePayload)
        else { return nil }
        return fields.tmuxWindowTarget
    }

    public static func makeRuntimePayload(windowTarget: String, cwd: String?) throws -> Data {
        try JSONCodec.makeEncoder().encode(RuntimePayloadFields(tmuxWindowTarget: windowTarget, cwd: cwd))
    }
}

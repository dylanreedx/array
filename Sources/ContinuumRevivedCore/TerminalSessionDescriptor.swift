import Foundation

public struct TerminalSessionDescriptor: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let tileId: UUID
    public var launchProfileId: String
    public var command: String
    public var args: [String]
    public var cwd: String
    public var env: [String: String]
    public var title: String
    public let createdAt: Date
    public var lastStartedAt: Date
    public var lastExit: TerminalLastExit?
    public var agentDescriptor: AgentDescriptor?

    public init(
        schemaVersion: Int = TerminalSessionDescriptor.currentSchemaVersion,
        id: UUID,
        tileId: UUID,
        launchProfileId: String,
        command: String,
        args: [String],
        cwd: String,
        env: [String: String],
        title: String,
        createdAt: Date,
        lastStartedAt: Date,
        lastExit: TerminalLastExit?,
        agentDescriptor: AgentDescriptor? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.tileId = tileId
        self.launchProfileId = launchProfileId
        self.command = command
        self.args = args
        self.cwd = cwd
        self.env = env
        self.title = title
        self.createdAt = createdAt
        self.lastStartedAt = lastStartedAt
        self.lastExit = lastExit
        self.agentDescriptor = agentDescriptor
    }

    public func restoredForBoot() -> TerminalSessionDescriptor {
        var restored = self
        restored.agentDescriptor = agentDescriptor?.restoredForBoot()
        return restored
    }
}

public enum AgentStatus: String, Codable, Equatable, Sendable {
    case configuring
    case working
    case idle
    case needsAttention
    case done
    case stale
}

public struct AgentDescriptor: Codable, Equatable, Sendable {
    public var agentKind: String
    public var worktreePath: String?
    public var status: AgentStatus
    public var statusUpdatedAt: Date

    public init(agentKind: String, worktreePath: String?, status: AgentStatus, statusUpdatedAt: Date) {
        self.agentKind = agentKind
        self.worktreePath = worktreePath
        self.status = status
        self.statusUpdatedAt = statusUpdatedAt
    }

    public static func configuring(agentKind: String, worktreePath: String?, now: Date) -> AgentDescriptor {
        AgentDescriptor(agentKind: agentKind, worktreePath: worktreePath, status: .configuring, statusUpdatedAt: now)
    }

    public func restoredForBoot(now: Date = Date()) -> AgentDescriptor {
        var restored = self
        restored.status = .stale
        restored.statusUpdatedAt = now
        return restored
    }
}

public struct TerminalLastExit: Codable, Equatable, Sendable {
    public var exitCode: Int32?
    public var signal: Int32?
    public var at: Date

    public init(exitCode: Int32?, signal: Int32?, at: Date) {
        self.exitCode = exitCode
        self.signal = signal
        self.at = at
    }

    private enum CodingKeys: String, CodingKey {
        case exitCode
        case signal
        case at
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(exitCode, forKey: .exitCode)
        try container.encodeIfPresent(signal, forKey: .signal)
        try container.encode(at, forKey: .at)
    }
}

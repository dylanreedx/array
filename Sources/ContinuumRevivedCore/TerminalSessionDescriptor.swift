import Foundation

public struct TerminalSessionDescriptor: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3

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
    /// Display-only scrollback snapshot captured at flush. nil = no snapshot.
    /// Decoded with decodeIfPresent so v1 session files (no scrollback key) still load.
    public var scrollback: String?

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
        agentDescriptor: AgentDescriptor? = nil,
        scrollback: String? = nil
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
        self.scrollback = scrollback
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, tileId, launchProfileId, command, args, cwd, env, title
        case createdAt, lastStartedAt, lastExit, agentDescriptor, scrollback
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(UUID.self, forKey: .id)
        tileId = try container.decode(UUID.self, forKey: .tileId)
        launchProfileId = try container.decode(String.self, forKey: .launchProfileId)
        command = try container.decode(String.self, forKey: .command)
        args = try container.decode([String].self, forKey: .args)
        cwd = try container.decode(String.self, forKey: .cwd)
        env = try container.decode([String: String].self, forKey: .env)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastStartedAt = try container.decode(Date.self, forKey: .lastStartedAt)
        lastExit = try container.decodeIfPresent(TerminalLastExit.self, forKey: .lastExit)
        agentDescriptor = try container.decodeIfPresent(AgentDescriptor.self, forKey: .agentDescriptor)
        scrollback = try container.decodeIfPresent(String.self, forKey: .scrollback)
    }

    public func restoredForBoot(now: Date = Date()) -> TerminalSessionDescriptor {
        var restored = self
        restored.agentDescriptor = agentDescriptor?.restoredForBoot(now: now)
        return restored
    }
}

public enum AgentKind: String, Codable, Equatable, Sendable, CaseIterable {
    case shell
    case claude
    case codex
    case pi
    case managed
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentKind(rawValue: raw) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AgentStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case configuring
    case working
    case idle
    case needsAttention
    case done
    case stale
}

public struct AgentDescriptor: Codable, Equatable, Sendable {
    public var agentKind: AgentKind
    public var worktreePath: String?
    public var status: AgentStatus
    public var statusUpdatedAt: Date
    public var runId: String?

    public init(agentKind: AgentKind, worktreePath: String?, status: AgentStatus, statusUpdatedAt: Date, runId: String? = nil) {
        self.agentKind = agentKind
        self.worktreePath = worktreePath
        self.status = status
        self.statusUpdatedAt = statusUpdatedAt
        self.runId = runId
    }

    public static func configuring(agentKind: AgentKind, worktreePath: String?, now: Date, runId: String? = nil) -> AgentDescriptor {
        AgentDescriptor(agentKind: agentKind, worktreePath: worktreePath, status: .configuring, statusUpdatedAt: now, runId: runId)
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

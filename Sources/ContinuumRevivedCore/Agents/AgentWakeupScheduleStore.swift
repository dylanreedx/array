import Foundation

/// Host-only schedule and queue outbox. Never part of AgentRecord or sync.
public struct AgentWakeupSchedule: Codable, Equatable, Sendable {
    public var id: UUID
    public var agent: AgentID
    public var key: String
    public var prompt: String
    public var startsAt: Date?
    public var nextFireAt: Date?
    public var intervalSeconds: Double?
    public var pendingDelivery: UUID?
    public var lastEnqueued: UUID?

    public init(id: UUID, agent: AgentID, key: String, prompt: String, startsAt: Date?,
                nextFireAt: Date?, intervalSeconds: Double?, pendingDelivery: UUID? = nil, lastEnqueued: UUID? = nil) {
        self.id = id; self.agent = agent; self.key = key; self.prompt = prompt
        self.startsAt = startsAt; self.nextFireAt = nextFireAt; self.intervalSeconds = intervalSeconds
        self.pendingDelivery = pendingDelivery; self.lastEnqueued = lastEnqueued
    }
}

@MainActor
public final class AgentWakeupScheduleStore {
    public private(set) var entries: [AgentWakeupSchedule]
    private let directory: URL
    private let file: URL
    private let writer = AtomicWriter()

    public init(applicationSupportDirectory: URL) throws {
        directory = applicationSupportDirectory.appendingPathComponent("agent-schedules", isDirectory: true)
        file = directory.appendingPathComponent("schedules.json")
        entries = FileManager.default.fileExists(atPath: file.path) ? try writer.read(at: file) : []
    }

    public func replace(_ next: [AgentWakeupSchedule]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try writer.write(next, to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        entries = next
    }
}

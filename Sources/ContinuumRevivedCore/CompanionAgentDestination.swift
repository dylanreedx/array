import Foundation

/// Navigation identity, never authority to execute an agent command.
public struct CompanionAgentDestination: Hashable, Codable, Sendable {
    public let agentID: UUID
    public let taskID: UUID?
    public let runID: UUID?
    public let instanceID: UUID?

    public init?(url: URL, pairedInstanceID: UUID?) {
        guard ["array", "continuum"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.lowercased() == "agent", url.user == nil, url.password == nil,
              url.port == nil, url.fragment == nil,
              url.pathComponents.count == 2,
              let agent = UUID(uuidString: url.lastPathComponent),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = parts.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count else { return nil }
        func identity(_ name: String) -> UUID? { items.first { $0.name == name }?.value.flatMap(UUID.init(uuidString:)) }
        for name in ["task", "run", "instance"] where items.contains(where: { $0.name == name }) {
            guard identity(name) != nil else { return nil }
        }
        let instance = identity("instance")
        if let instance { guard instance == pairedInstanceID else { return nil } }
        agentID = agent; taskID = identity("task"); runID = identity("run"); instanceID = instance
    }
}

/// A relay receipt timestamp is preserved across replay. It is not a new host
/// heartbeat and does not establish that a provider is still executing.
public struct CompanionTaskObservation: Equatable, Sendable {
    public var batch: CompanionTaskSnapshotBatch
    public var publishedAt: Date
    public var sequence: Int64
    public init(batch: CompanionTaskSnapshotBatch, publishedAt: Date, sequence: Int64) {
        self.batch = batch; self.publishedAt = publishedAt; self.sequence = sequence
    }
    public func supersedes(_ previous: CompanionTaskObservation) -> Bool {
        batch.publisherID == previous.batch.publisherID && batch.revision >= previous.batch.revision && sequence > previous.sequence
    }
    public func task(for destination: CompanionAgentDestination) -> CompanionTaskSnapshot? {
        // A legacy agent-only link cannot identify which of its tasks finished.
        guard let id = destination.taskID,
              let task = batch.tasks.first(where: { $0.taskID == id }),
              task.members.contains(where: { $0.agentID == destination.agentID && (destination.runID == nil || $0.runID == destination.runID) }) else { return nil }
        return task
    }
}

public struct CompanionTaskDetail: Equatable, Sendable {
    public let running: Int
    public let queued: Int
    public let blocked: Int
    public let succeeded: Int
    public let uncertain: Bool
    public let summary: String
    public init(task: CompanionTaskSnapshot) {
        running = task.members.filter { $0.state == .running }.count
        queued = task.members.filter { $0.state == .queued }.count
        blocked = task.members.filter { $0.state == .needsInput || $0.state == .needsApproval }.count
        succeeded = task.members.filter { $0.state == .succeeded }.count
        uncertain = !task.membershipComplete || task.members.contains { $0.state == .unknown }
        if uncertain { summary = "Some work is unconfirmed" }
        else if blocked > 0 { summary = "This task needs your attention" }
        else if running + queued > 0 { summary = "Work remains on this task" }
        else if task.members.allSatisfy({ $0.state == .succeeded }) { summary = "This task finished" }
        else if task.members.contains(where: { $0.state == .failed }) { summary = "This task has a failed run" }
        else { summary = "This task stopped" }
    }
}

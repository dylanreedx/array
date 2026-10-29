import Foundation

public struct RelayTaskBatch: Codable, Sendable {
    public var publisherID: UUID
    public var revision: UInt64
    public var tasks: [RelayTaskState]
    public init(publisherID: UUID, revision: UInt64, tasks: [RelayTaskState]) {
        self.publisherID = publisherID; self.revision = revision; self.tasks = tasks
    }
}

public struct RelayNotificationOwnership: Codable, Sendable, Equatable {
    public var publisherID: UUID
    public var revision: UInt64
    public init(publisherID: UUID, revision: UInt64) { self.publisherID = publisherID; self.revision = revision }
}

public struct RelayNotificationOwnershipResponse: Codable, Sendable {
    public var owner: RelayNotificationOwnership?
    public init(owner: RelayNotificationOwnership?) { self.owner = owner }
}

import Foundation
import ContinuumRevivedCollaborationProtocol

/// One replica's accepted state. No runner, checkout mapping or camera lives here.
public struct CollaborationReplica: Sendable {
    public private(set) var document: SharedArea.Document
    public private(set) var scope: Collaboration.Scope
    public private(set) var presenceVersion: UUID?
    public private(set) var presence: [Collaboration.Presence] = []
    public private(set) var hosts: [Collaboration.HostLiveness]?
    public private(set) var serverTime: Date?
    public private(set) var artifactHeads: [Collaboration.Artifact.Head] = []
    /// The relay's recorded members; nil until a relay that sends them answers.
    public private(set) var members: [Collaboration.Member]?
    public init(state: Collaboration.State) throws {
        guard state.document.id == state.scope.area else { throw CollaborationClientError.invalidSequence }
        document = state.document; scope = state.scope
    }
    public mutating func receive(_ page: Collaboration.Updates) throws {
        guard page.scope.area == document.id, page.scope.epoch >= scope.epoch,
              page.after == document.revision, page.nextCursor <= page.through,
              page.nextCursor == (page.events.last?.revision ?? page.after) else { throw CollaborationClientError.invalidSequence }
        var next = document
        for event in page.events {
            guard event.revision == next.revision + 1,
                  event.command.area == next.id, event.command.expectedRevision == next.revision,
                  try next.apply(event.command) == .applied(event.revision) else { throw CollaborationClientError.invalidSequence }
        }
        // Commit the entire received page, never half a malformed page.
        document = next; scope = page.scope; presenceVersion = page.presenceVersion
        presence = page.presence; serverTime = page.serverTime; hosts = page.hosts
        if let heads = page.artifactHeads { artifactHeads = heads }
        if let members = page.members { self.members = members }
    }
    /// Catch up to one fixed high-water mark, then resume live polling.
    public mutating func catchUp(using api: CollaborationAPI) async throws {
        var through: UInt64?
        repeat {
            let page = try await api.updates(area: document.id.rawValue,
                request: .init(after: document.revision, through: through, waitMilliseconds: 0))
            try receive(page)
            if !page.hasMore { return }
            through = page.through
        } while true
    }
}

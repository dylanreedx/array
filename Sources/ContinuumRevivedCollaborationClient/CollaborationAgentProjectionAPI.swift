import Foundation
import ContinuumRevivedCollaborationProtocol

extension CollaborationAPI {
    public func publishAgentProjection(area: UUID, object: UUID, report: Collaboration.AgentProjection.PublishReport) async throws {
        let _: Collaboration.ErrorBody = try await request("POST", "areas/\(area)/agents/\(object)/projection", body: report)
    }
    public func readAgentProjection(area: UUID, object: UUID, cursor: Collaboration.AgentProjection.Cursor?) async throws -> Collaboration.AgentProjection.Read {
        try await request("POST", "areas/\(area)/agents/\(object)/projection/read", body: Collaboration.AgentProjection.ReadRequest(cursor: cursor))
    }
}

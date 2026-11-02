import Foundation
import ContinuumRevivedCollaborationProtocol

extension CollaborationAPI {
    public func publishAgentProjection(area: UUID, object: UUID, report: Collaboration.AgentProjection.PublishReport) async throws {
        let _: Collaboration.ErrorBody = try await request("POST", "areas/\(area)/agents/\(object)/projection", body: report)
    }
    public func readAgentProjection(area: UUID, object: UUID, cursor: Collaboration.AgentProjection.Cursor?) async throws -> Collaboration.AgentProjection.Read {
        try await request("POST", "areas/\(area)/agents/\(object)/projection/read", body: Collaboration.AgentProjection.ReadRequest(cursor: cursor))
    }
    public func publishAgentTranscript(area: UUID, object: UUID, report: Collaboration.AgentTranscript.Publish) async throws {
        let _: Collaboration.ErrorBody = try await request("POST", "areas/\(area)/agents/\(object)/transcript", body: report)
    }
    public func readAgentTranscript(area: UUID, object: UUID, request value: Collaboration.AgentTranscript.ReadRequest) async throws -> Collaboration.AgentTranscript.Read {
        try await request("POST", "areas/\(area)/agents/\(object)/transcript/read", body: value)
    }
}

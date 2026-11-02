import Foundation
import ContinuumRevivedCollaborationProtocol

extension CollaborationAPI {
    public func publishLiveTileState(area: UUID, object: UUID, report: Collaboration.LiveTile.PublishState) async throws {
        let _: Collaboration.ErrorBody = try await request("POST", "areas/\(area)/tiles/\(object)/state", body: report)
    }
    public func appendLiveTileEvent(area: UUID, object: UUID, body: Collaboration.LiveTile.EventBody) async throws -> Collaboration.LiveTile.Appended {
        try await request("POST", "areas/\(area)/tiles/\(object)/events", body: Collaboration.LiveTile.AppendEvent(body: body))
    }
    public func readLiveTile(area: UUID, object: UUID, request value: Collaboration.LiveTile.ReadRequest) async throws -> Collaboration.LiveTile.Read {
        try await request("POST", "areas/\(area)/tiles/\(object)/read", body: value)
    }
}

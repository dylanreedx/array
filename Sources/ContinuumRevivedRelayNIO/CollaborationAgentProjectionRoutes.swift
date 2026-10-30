import Foundation
import NIOHTTP1
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationService

/// `POST areas/{area}/agents/{object}/projection` publishes a host batch;
/// `POST …/projection/read` returns frames after a cursor or a resnapshot.
enum CollaborationAgentProjectionRoutes {
    static func route(head: HTTPRequestHead, body: Data, token: String, store: CollaborationStore) async throws -> Response? {
        let p = head.uri.split(separator: "/").map(String.init)
        guard p.count >= 7, p[2] == "areas", let area = UUID(uuidString: p[3]), p[4] == "agents",
              let object = UUID(uuidString: p[5]), p[6] == "projection", head.method == .POST else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if p.count == 7 {
            try await store.publishAgentProjection(token: token, area: area, object: .init(object),
                report: decoder.decode(Collaboration.AgentProjection.PublishReport.self, from: body))
            return .json(.ok, Collaboration.ErrorBody(code: "observed"))
        }
        if p.count == 8, p[7] == "read" {
            let cursor = try decoder.decode(Collaboration.AgentProjection.ReadRequest.self, from: body).cursor
            return .json(.ok, try await store.readAgentProjection(token: token, area: area, object: .init(object), cursor: cursor))
        }
        return nil
    }
}

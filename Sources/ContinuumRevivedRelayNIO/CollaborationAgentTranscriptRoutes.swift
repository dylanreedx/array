import Foundation
import NIOHTTP1
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationService

/// `/collaboration/v1/areas/{area}/agents/{object}/transcript[/read]`: a
/// published agent's whole transcript (`Collaboration.AgentTranscript`).
/// Additive: no earlier route changes, and the body cap stays 256 KiB.
enum CollaborationAgentTranscriptRoutes {
    static func route(head: HTTPRequestHead, body: Data, token: String, store: CollaborationStore) async throws -> Response? {
        let p = head.uri.split(separator: "/").map(String.init)
        guard p.count >= 7, p[2] == "areas", let area = UUID(uuidString: p[3]), p[4] == "agents",
              let object = UUID(uuidString: p[5]), p[6] == "transcript", head.method == .POST else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        switch p.count {
        case 7:
            try await store.publishAgentTranscript(token: token, area: area, object: object,
                report: decoder.decode(Collaboration.AgentTranscript.Publish.self, from: body))
            return .json(.ok, Collaboration.ErrorBody(code: "observed"))
        case 8 where p[7] == "read":
            return .json(.ok, try await store.readAgentTranscript(token: token, area: area, object: object,
                request: decoder.decode(Collaboration.AgentTranscript.ReadRequest.self, from: body)))
        default:
            return nil
        }
    }
}

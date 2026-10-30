import Foundation
import NIOHTTP1
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationService

enum CollaborationHostLivenessRoutes {
    /// `POST areas/{area}/hosts/{host}/heartbeat` and
    /// `DELETE areas/{area}/hosts/{host}/runs/{generation}`.
    static func route(head: HTTPRequestHead, body: Data, token: String, store: CollaborationStore) async throws -> Response? {
        let p = head.uri.split(separator: "/").map(String.init)
        guard p.count >= 7, p[2] == "areas", let area = UUID(uuidString: p[3]), p[4] == "hosts",
              let host = UUID(uuidString: p[5]) else { return nil }
        if p.count == 7, p[6] == "heartbeat", head.method == .POST {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return .json(.ok, try await store.hostHeartbeat(token: token, area: area, host: .init(host),
                beat: decoder.decode(Collaboration.HostHeartbeat.self, from: body)))
        }
        if p.count == 8, p[6] == "runs", let generation = UUID(uuidString: p[7]), head.method == .DELETE {
            try await store.endHost(token: token, area: area, host: .init(host), generation: generation)
            return .json(.ok, Collaboration.ErrorBody(code: "ended"))
        }
        return nil
    }
}

import Foundation
import NIOHTTP1
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationService

/// `/collaboration/v1/areas/{area}/tiles/{object}/state|events|read`: a shared
/// note, file, diff, browser or terminal (`Collaboration.LiveTile`). Additive:
/// no earlier route changes, and the body cap stays the route table's 256 KiB.
enum CollaborationLiveTileRoutes {
    static func route(head: HTTPRequestHead, body: Data, token: String, store: CollaborationStore) async throws -> Response? {
        let p = head.uri.split(separator: "/").map(String.init)
        guard p.count == 7, p[2] == "areas", let area = UUID(uuidString: p[3]), p[4] == "tiles",
              let object = UUID(uuidString: p[5]), head.method == .POST else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        switch p[6] {
        case "state":
            try await store.publishLiveTileState(token: token, area: area, object: object,
                report: decoder.decode(Collaboration.LiveTile.PublishState.self, from: body))
            return .json(.ok, Collaboration.ErrorBody(code: "observed"))
        case "events":
            return .json(.created, try await store.appendLiveTileEvent(token: token, area: area, object: object,
                request: decoder.decode(Collaboration.LiveTile.AppendEvent.self, from: body)))
        case "read":
            return .json(.ok, try await store.readLiveTile(token: token, area: area, object: object,
                request: decoder.decode(Collaboration.LiveTile.ReadRequest.self, from: body)))
        default:
            return nil
        }
    }
}

import Foundation
import NIOHTTP1
import ContinuumRevivedCollaborationService

/// Operator routes for collaboration, on the admin port only, behind
/// `RELAY_ADMIN_TOKEN` as a bearer token. With no token configured they refuse.
///
///     GET    /collaboration/people          everyone: id, label, device and area counts
///     GET    /collaboration/people/<id>     one person and their memberships
///     DELETE /collaboration/people/<id>     the person, memberships, devices, hosts
///     DELETE /collaboration/areas/<id>      the area and everything in it
///
/// A person whose history sits in an area that stays answers 409
/// `personHasAreas` with those areas; delete them first.
enum CollaborationAdminRoutes {
    struct Blocked: Encodable { let code: String; let areas: [UUID] }

    static func route(head: HTTPRequestHead, store: CollaborationStore?, adminToken: String?) async -> Response? {
        guard head.uri == "/collaboration" || head.uri.hasPrefix("/collaboration/") else { return nil }
        guard let adminToken else { return .error(.forbidden, "adminTokenNotConfigured") }
        guard let header = head.headers.first(name: "authorization"), header.hasPrefix("Bearer "),
              constantTimeEqual(String(header.dropFirst(7)), adminToken) else { return .error(.unauthorized, "unauthorized") }
        guard let store else { return .error(.notFound, "collaborationOff") }
        let parts = head.uri.split(separator: "/").map(String.init)
        do {
            if head.method == .GET, parts == ["collaboration", "people"] { return .json(.ok, try await store.operatorPeople()) }
            guard parts.count == 3, let id = UUID(uuidString: parts[2]) else { return .error(.notFound, "notFound") }
            switch (head.method, parts[1]) {
            case (.GET, "people"): return .json(.ok, try await store.operatorPerson(id))
            case (.DELETE, "people"): return .json(.ok, try await store.operatorDeletePerson(id))
            case (.DELETE, "areas"): return .json(.ok, try await store.operatorDeleteArea(id))
            default: return .error(.notFound, "notFound")
            }
        } catch CollaborationStoreError.unavailable { return .error(.notFound, "notFound") }
        catch CollaborationDeletionError.personHasAreas(let areas) { return .json(.conflict, Blocked(code: "personHasAreas", areas: areas)) }
        catch {
            FileHandle.standardError.write(Data("{\"event\":\"admin_request_failed\",\"error_type\":\"\(String(describing: type(of: error)))\"}\n".utf8))
            return .error(.internalServerError, "storageFailure")
        }
    }

    /// Compares every byte whatever the first difference, so the response time
    /// does not say how much of a guessed token was right.
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var difference = UInt8(x.count == y.count ? 0 : 1)
        for index in 0..<max(x.count, y.count) {
            difference |= (index < x.count ? x[index] : 0) ^ (index < y.count ? y[index] : 0)
        }
        return difference == 0
    }
}

import Foundation
import NIOHTTP1
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationService

enum CollaborationRoutes {
    static func route(head: HTTPRequestHead, body: Data, store: CollaborationStore, clientAddress: String = "unknown") async -> Response {
        if let artifact = await CollaborationArtifactRoutes.route(head: head, body: body, store: store) { return artifact }
        guard body.count <= 262_144 else { return .error(.payloadTooLarge, "payloadTooLarge") }
        do {
            let parts = head.uri.split(separator: "/").map(String.init)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if head.method == .POST, head.uri == "/collaboration/v1/enrollments/redeem" {
                return .json(.created, try await store.redeem(decoder.decode(Collaboration.RedeemEnrollment.self, from: body)))
            }
            // A share link's token is its own admission, as an enrollment code is.
            // First use with no account: a person signs themselves up, limited per address.
            if head.method == .POST, head.uri == "/collaboration/v1/self-enroll" {
                return .json(.created, try await store.selfEnroll(decoder.decode(Collaboration.SelfEnroll.self, from: body), from: clientAddress))
            }
            if head.method == .POST, head.uri == "/collaboration/v1/links/join" {
                return .json(.created, try await store.joinShareLink(decoder.decode(Collaboration.JoinShareLink.self, from: body), from: clientAddress,
                    readsLiveTiles: Collaboration.LiveTile.clientReadsLiveTiles(head.headers.first(name: Collaboration.LiveTile.capabilityHeader))))
            }
            guard let header = head.headers.first(name: "authorization"), header.hasPrefix("Bearer ") else { return .error(.unauthorized, "unauthorized") }
            let token = String(header.dropFirst(7))
            if let handoff = try await CollaborationHandoffRoutes.route(head: head, body: body, token: token, store: store) { return handoff }
            if let liveness = try await CollaborationHostLivenessRoutes.route(head: head, body: body, token: token, store: store) { return liveness }
            if let projection = try await CollaborationAgentProjectionRoutes.route(head: head, body: body, token: token, store: store) { return projection }
            if let tile = try await CollaborationLiveTileRoutes.route(head: head, body: body, token: token, store: store) { return tile }
            // Every store method authenticates again within its read/write transaction.
            if head.method == .GET, head.uri == "/collaboration/v1/self" { return .json(.ok, try await store.identity(token: token)) }
            if head.method == .POST, head.uri == "/collaboration/v1/devices/enrollments" {
                let value = try decoder.decode(Collaboration.DeviceEnrollmentRequest.self, from: body)
                return .json(.created, try await store.enrollDevice(token: token, lifetime: value.lifetime))
            }
            if head.method == .DELETE, parts.count == 4, parts[2] == "devices", let id = UUID(uuidString: parts[3]) {
                try await store.revokeDevice(token: token, device: id)
                return .json(.ok, Collaboration.ErrorBody(code: "revoked"))
            }
            if head.method == .POST, head.uri == "/collaboration/v1/hosts" { return .json(.created, try await store.registerHost(token: token)) }
            if head.method == .POST, head.uri == "/collaboration/v1/areas" { return .json(.created, try await store.createArea(token: token)) }
            if head.method == .POST, head.uri == "/collaboration/v1/links/accept" {
                return .json(.ok, try await store.acceptShareLink(token: token, request: decoder.decode(Collaboration.AcceptShareLink.self, from: body),
                    readsLiveTiles: Collaboration.LiveTile.clientReadsLiveTiles(head.headers.first(name: Collaboration.LiveTile.capabilityHeader))))
            }
            if head.method == .POST, head.uri == "/collaboration/v1/invitations/accept" {
                return .json(.ok, try await store.accept(token: token, code: decoder.decode(Collaboration.AcceptInvitation.self, from: body).code))
            }
            if parts.count >= 4, parts[2] == "areas", let area = UUID(uuidString: parts[3]) {
                if parts.count == 5, parts[4] == "usage", head.method == .POST {
                    try await store.reportUsage(token: token, area: area, report: decoder.decode(Collaboration.UsageReport.self, from: body))
                    return .json(.ok, Collaboration.ErrorBody(code: "observed"))
                }
                if parts.count == 4, head.method == .GET { return .json(.ok, try await store.state(token: token, area: area)) }
                if parts.count == 6, parts[4] == "updates", head.method == .DELETE, let subscription = UUID(uuidString: parts[5]) {
                    try await store.cancelUpdates(token: token, area: area, subscription: subscription)
                    return .json(.ok, Collaboration.ErrorBody(code: "cancelled"))
                }
                if parts.count == 5, parts[4] == "updates", head.method == .POST {
                    return .json(.ok, try await store.updates(token: token, area: area, request: decoder.decode(Collaboration.UpdateRequest.self, from: body)))
                }
                if parts.count == 5, parts[4] == "presence-sessions", head.method == .POST {
                    return .json(.created, try await store.beginPresence(token: token, area: area))
                }
                if parts.count == 5, parts[4] == "presence", head.method == .POST {
                    try await store.publishPresence(token: token, area: area, input: decoder.decode(Collaboration.PresenceInput.self, from: body))
                    return .json(.ok, Collaboration.ErrorBody(code: "observed"))
                }
                if parts.count == 6, parts[4] == "presence-sessions", head.method == .DELETE, let session = UUID(uuidString: parts[5]) {
                    try await store.endPresence(token: token, area: area, session: session)
                    return .json(.ok, Collaboration.ErrorBody(code: "ended"))
                }
                if parts.count == 5, parts[4] == "invitations", head.method == .POST {
                    return .json(.created, try await store.invite(token: token, area: area, request: decoder.decode(Collaboration.InviteRequest.self, from: body)))
                }
                if parts.count == 5, parts[4] == "links", head.method == .POST {
                    return .json(.created, try await store.createShareLink(token: token, area: area, request: decoder.decode(Collaboration.ShareLinkRequest.self, from: body)))
                }
                if parts.count == 5, parts[4] == "links", head.method == .GET {
                    return .json(.ok, try await store.shareLinks(token: token, area: area))
                }
                if parts.count == 6, parts[4] == "links", head.method == .DELETE, let link = UUID(uuidString: parts[5]) {
                    try await store.revokeShareLink(token: token, area: area, link: link)
                    return .json(.ok, Collaboration.ErrorBody(code: "revoked"))
                }
                if parts.count == 8, parts[4] == "links", parts[6] == "people", head.method == .DELETE,
                   let link = UUID(uuidString: parts[5]), let person = UUID(uuidString: parts[7]) {
                    try await store.removeShareLinkPerson(token: token, area: area, link: link, person: person)
                    return .json(.ok, Collaboration.ErrorBody(code: "removed"))
                }
                if parts.count == 5, parts[4] == "commands", head.method == .POST {
                    return .json(.ok, try await store.apply(token: token, area: area, request: decoder.decode(Collaboration.Mutation.self, from: body)))
                }
                if parts.count == 6, parts[4] == "members", head.method == .DELETE, let person = UUID(uuidString: parts[5]) {
                    guard let value = head.headers.first(name: "if-match"), let epoch = Int64(value), epoch > 0 else { return .error(.badRequest, "expectedEpochRequired") }
                    try await store.removeMember(token: token, area: area, person: person, expectedEpoch: epoch)
                    return .json(.ok, Collaboration.ErrorBody(code: "removed"))
                }
            }
            // Do not expose route distinctions to unauthenticated requests.
            _ = try await store.identity(token: token)
            return .error(.notFound, "notFound")
        } catch CollaborationStoreError.unauthorized { return .error(.unauthorized, "unauthorized") }
        catch CollaborationStoreError.unavailable { return .error(.notFound, "notFound") }
        catch CollaborationStoreError.forbidden { return .error(.forbidden, "forbidden") }
        catch CollaborationStoreError.invalidInvitation { return .error(.gone, "invalidInvitation") }
        catch CollaborationStoreError.slugTaken { return .error(.conflict, "slugTaken") }
        catch CollaborationStoreError.rateLimited { return .error(.tooManyRequests, "rateLimited") }
        // 0.7.38 shows this as "the relay … answered with an error (426)";
        // newer clients say "update Array".
        catch CollaborationStoreError.clientTooOld { return .error(.upgradeRequired, "updateRequired") }
        catch CollaborationStoreError.invalidCursor { return .error(.conflict, "resyncRequired") }
        catch CollaborationStoreError.compacted { return .error(.conflict, "snapshotRequired") }
        catch CollaborationStoreError.tooManySubscriptions { return .error(.tooManyRequests, "subscriptionLimit") }
        catch is CancellationError { return .error(.requestTimeout, "cancelled") }
        catch CollaborationStoreError.staleEpoch { return .error(.conflict, "staleEpoch") }
        catch SharedArea.Failure.conflict { return .error(.conflict, "revisionConflict") }
        catch SharedArea.Failure.changedIntent { return .error(.conflict, "changedIntent") }
        catch is DecodingError { return .error(.badRequest, "invalidRequest") }
        catch is SharedArea.Failure { return .error(.badRequest, "invalidCommand") }
        catch CollaborationStoreError.invalidRequest { return .error(.badRequest, "invalidRequest") }
        catch { return .error(.internalServerError, "storageFailure") }
    }
}

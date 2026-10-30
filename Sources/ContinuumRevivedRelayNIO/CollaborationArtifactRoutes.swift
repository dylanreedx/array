import Foundation
import NIOHTTP1
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationService

/// `/collaboration/v1/areas/{a}/artifacts/{o}/…`. Runs before the shared 256 KiB
/// JSON limit because blob uploads are raw bytes with their own 1 MiB limit.
/// Blobs never enter the area operation stream.
enum CollaborationArtifactRoutes {
    static func route(head: HTTPRequestHead, body: Data, store: CollaborationStore) async -> Response? {
        let p = head.uri.split(separator: "/").map(String.init)
        guard p.count >= 6, p[0] == "collaboration", p[1] == "v1", p[2] == "areas", p[4] == "artifacts" else { return nil }
        let isBlobUpload = head.method == .PUT && p.count == 8 && p[6] == "blobs"
        guard body.count <= (isBlobUpload ? Collaboration.Artifact.Limits.blobBytes : 262_144) else { return .error(.payloadTooLarge, "payloadTooLarge") }
        guard let header = head.headers.first(name: "authorization"), header.hasPrefix("Bearer ") else { return .error(.unauthorized, "unauthorized") }
        let token = String(header.dropFirst(7))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        do {
            guard let area = UUID(uuidString: p[3]), let object = UUID(uuidString: p[5]) else { throw CollaborationStoreError.unavailable }
            if isBlobUpload {
                return .json(.created, try await store.uploadArtifactBlob(token: token, area: area, object: object, digest: p[7], bytes: body))
            }
            if p.count == 6, head.method == .GET {
                return .json(.ok, try await store.artifactState(token: token, area: area, object: object))
            }
            if p.count == 7, p[6] == "revisions", head.method == .POST {
                return .json(.created, try await store.publishArtifactRevision(token: token, area: area, object: object,
                    request: decoder.decode(Collaboration.Artifact.PublishRequest.self, from: body)))
            }
            if p.count == 7, p[6] == "reviews", head.method == .POST {
                return .json(.created, try await store.reviewArtifact(token: token, area: area, object: object,
                    request: decoder.decode(Collaboration.Artifact.ReviewRequest.self, from: body)))
            }
            if p.count >= 8, p[6] == "revisions", let revision = UUID(uuidString: p[7]) {
                if p.count == 8, head.method == .GET {
                    return .json(.ok, try await store.artifactRevision(token: token, area: area, object: object, revision: revision))
                }
                if p.count == 9, p[8] == "drift", head.method == .POST {
                    return .json(.ok, try await store.reportArtifactDrift(token: token, area: area, object: object, revision: revision,
                        report: decoder.decode(Collaboration.Artifact.DriftReport.self, from: body)))
                }
                if p.count == 10, p[8] == "blobs", head.method == .GET {
                    let bytes = try await store.artifactBlob(token: token, area: area, object: object, revision: revision, digest: p[9])
                    return Response(status: .ok, contentType: "application/octet-stream", body: bytes,
                                    headers: ["x-array-sha256": p[9], "cache-control": "no-store"])
                }
            }
            // Same answer as an unknown area: do not reveal route shapes.
            _ = try await store.identity(token: token)
            return .error(.notFound, "notFound")
        } catch CollaborationStoreError.unauthorized { return .error(.unauthorized, "unauthorized") }
        catch CollaborationStoreError.unavailable { return .error(.notFound, "notFound") }
        catch CollaborationStoreError.forbidden { return .error(.forbidden, "forbidden") }
        catch CollaborationStoreError.staleEpoch { return .error(.conflict, "staleEpoch") }
        catch CollaborationStoreError.invalidRequest { return .error(.badRequest, "invalidRequest") }
        catch CollaborationArtifactError.hashMismatch { return .error(.badRequest, "hashMismatch") }
        catch CollaborationArtifactError.tooLarge { return .error(.payloadTooLarge, "payloadTooLarge") }
        catch CollaborationArtifactError.quotaExceeded { return .error(.payloadTooLarge, "artifactQuotaExceeded") }
        catch CollaborationArtifactError.missingBlob { return .error(.badRequest, "missingBlob") }
        catch CollaborationArtifactError.invalidManifest { return .error(.badRequest, "invalidManifest") }
        catch CollaborationArtifactError.conflict { return .error(.conflict, "revisionConflict") }
        catch CollaborationArtifactError.changedIntent { return .error(.conflict, "changedIntent") }
        catch is DecodingError { return .error(.badRequest, "invalidRequest") }
        catch is CancellationError { return .error(.requestTimeout, "cancelled") }
        catch { return .error(.internalServerError, "storageFailure") }
    }
}

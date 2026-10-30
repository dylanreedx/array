import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ContinuumRevivedCollaborationProtocol

/// A pinned revision read into memory and verified against its manifest. It
/// carries bytes only; there is no path on this machine it can be written to.
public struct CollaborationArtifactContents: Sendable {
    public let record: Collaboration.Artifact.Record
    /// Keyed by repository-relative path, `included` entries only.
    public let bytes: [String: Data]
    public init(record: Collaboration.Artifact.Record, bytes: [String: Data]) { self.record = record; self.bytes = bytes }
}

extension CollaborationAPI {
    public typealias Artifact = Collaboration.Artifact

    /// Stage every included blob, then publish the manifest that names them.
    /// Retrying with the same capture is idempotent end to end.
    public func publishArtifact(area: UUID, epoch: Int64, capture: Artifact.Capture) async throws -> Artifact.PublishReceipt {
        let object = capture.manifest.object.rawValue
        for entry in capture.manifest.entries where entry.coverage == .included {
            guard let digest = entry.blob, let bytes = capture.blobs[digest] else { throw Artifact.ValidationFailure.invalidManifest("missingCaptureBytes") }
            let _: Artifact.BlobReceipt = try await rawRequest("PUT", "areas/\(area)/artifacts/\(object)/blobs/\(digest)", body: bytes)
        }
        return try await request("POST", "areas/\(area)/artifacts/\(object)/revisions", body: Artifact.PublishRequest(epoch: epoch, manifest: capture.manifest))
    }
    public func artifactState(area: UUID, object: UUID) async throws -> Artifact.State {
        try await request("GET", "areas/\(area)/artifacts/\(object)", body: Optional<Int>.none)
    }
    public func artifactRevision(area: UUID, object: UUID, revision: UUID) async throws -> Artifact.Record {
        try await request("GET", "areas/\(area)/artifacts/\(object)/revisions/\(revision)", body: Optional<Int>.none)
    }
    public func reviewArtifact(area: UUID, object: UUID, request value: Artifact.ReviewRequest) async throws -> Artifact.Review {
        try await request("POST", "areas/\(area)/artifacts/\(object)/reviews", body: value)
    }
    public func reportArtifactDrift(area: UUID, object: UUID, revision: UUID, report: Artifact.DriftReport) async throws -> Artifact.Record {
        try await request("POST", "areas/\(area)/artifacts/\(object)/revisions/\(revision)/drift", body: report)
    }
    /// Raw bytes as served. Callers that display content use `readArtifact`,
    /// which verifies them against the pinned manifest.
    public func artifactBlob(area: UUID, object: UUID, revision: UUID, digest: String) async throws -> Data {
        try await raw("GET", "areas/\(area)/artifacts/\(object)/revisions/\(revision)/blobs/\(digest)", body: nil)
    }

    /// Fetch one pinned revision (or the live latest when `revision` is nil)
    /// and verify the record digest and every blob before returning anything.
    public func readArtifact(area: UUID, object: UUID, revision: UUID? = nil) async throws -> CollaborationArtifactContents {
        let record: Artifact.Record
        if let revision { record = try await artifactRevision(area: area, object: object, revision: revision) }
        else {
            guard let latest = try await artifactState(area: area, object: object).latest else { throw CollaborationClientError.server(status: 404, code: "notFound") }
            record = latest
        }
        try Artifact.verify(record)
        guard record.manifest.object.rawValue == object, revision.map({ $0 == record.manifest.id.rawValue }) ?? true else {
            throw Artifact.ValidationFailure.hashMismatch
        }
        var bytes: [String: Data] = [:]
        for entry in record.manifest.entries where entry.coverage == .included {
            let data = try await artifactBlob(area: area, object: object, revision: record.manifest.id.rawValue, digest: entry.blob!)
            try Artifact.verify(data, for: entry)
            bytes[entry.path] = data
        }
        return .init(record: record, bytes: bytes)
    }

    private func rawRequest<Response: Decodable>(_ method: String, _ path: String, body: Data) async throws -> Response {
        let data = try await raw(method, path, body: body)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data)
    }
    private func raw(_ method: String, _ path: String, body: Data?) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method; request.timeoutInterval = 35
        request.cachePolicy = .reloadIgnoringLocalCacheData; request.httpShouldHandleCookies = false
        if let credential { request.setValue("Bearer \(credential)", forHTTPHeaderField: "authorization") }
        if let body { request.httpBody = body; request.setValue("application/octet-stream", forHTTPHeaderField: "content-type") }
        let (bytes, response) = try await session.data(for: request)
        guard bytes.count <= Artifact.Limits.blobBytes + 65_536 else { throw CollaborationClientError.responseTooLarge }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(Collaboration.ErrorBody.self, from: bytes))?.code ?? "invalidResponse"
            throw CollaborationClientError.server(status: http.statusCode, code: code)
        }
        return bytes
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ContinuumRevivedCollaborationProtocol

public enum CollaborationClientError: Error, Equatable {
    case invalidEndpoint, responseTooLarge, server(status: Int, code: String), invalidSequence
}

/// No implicit production endpoint, provider auth, cookies or global URL cache.
public struct CollaborationAPI: Sendable {
    private let baseURL: URL
    private let credential: String?
    private let session: URLSession
    public init(baseURL: URL, credential: String? = nil, allowsInsecureLoopback: Bool = false) throws {
        let loopback = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(baseURL.host?.lowercased() ?? "")
        guard baseURL.host != nil, baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
              baseURL.scheme == "https" || (baseURL.scheme == "http" && loopback && allowsInsecureLoopback) else { throw CollaborationClientError.invalidEndpoint }
        self.baseURL = baseURL.appendingPathComponent("collaboration/v1")
        self.credential = credential
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        // FoundationNetworking does not consistently dispatch task-specific
        // redirect callbacks. Own the session and enforce policy at its delegate.
        self.session = URLSession(configuration: configuration, delegate: CollaborationNoRedirect.shared, delegateQueue: nil)
    }
    public func redeem(code: String, deviceLabel: String) async throws -> Collaboration.Credential {
        try await request("POST", "enrollments/redeem", body: Collaboration.RedeemEnrollment(code: code, deviceLabel: deviceLabel))
    }
    public func identity() async throws -> Collaboration.Identity { try await request("GET", "self", body: Optional<Int>.none) }
    public func registerHost() async throws -> Collaboration.Host { try await request("POST", "hosts", body: Optional<Int>.none) }
    public func createArea() async throws -> Collaboration.State { try await request("POST", "areas", body: Optional<Int>.none) }
    public func state(area: UUID) async throws -> Collaboration.State { try await request("GET", "areas/\(area)", body: Optional<Int>.none) }
    public func invite(area: UUID, request value: Collaboration.InviteRequest) async throws -> Collaboration.Invitation {
        try await request("POST", "areas/\(area)/invitations", body: value)
    }
    public func accept(code: String) async throws -> Collaboration.Scope { try await request("POST", "invitations/accept", body: Collaboration.AcceptInvitation(code: code)) }
    public func apply(area: UUID, mutation: Collaboration.Mutation) async throws -> Collaboration.Receipt { try await request("POST", "areas/\(area)/commands", body: mutation) }
    public func updates(area: UUID, request value: Collaboration.UpdateRequest) async throws -> Collaboration.Updates {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await request("POST", "areas/\(area)/updates", body: value)
        } onCancel: {
            Task { let _: Collaboration.ErrorBody? = try? await request("DELETE", "areas/\(area)/updates/\(value.subscriptionID)", body: Optional<Int>.none) }
        }
    }
    public func beginPresence(area: UUID) async throws -> Collaboration.PresenceSession { try await request("POST", "areas/\(area)/presence-sessions", body: Optional<Int>.none) }
    public func publishPresence(area: UUID, value: Collaboration.PresenceInput) async throws {
        let _: Collaboration.ErrorBody = try await request("POST", "areas/\(area)/presence", body: value)
    }
    public func endPresence(area: UUID, session: UUID) async throws {
        let _: Collaboration.ErrorBody = try await request("DELETE", "areas/\(area)/presence-sessions/\(session)", body: Optional<Int>.none)
    }
    public func removeMember(area: UUID, person: UUID, epoch: Int64) async throws {
        let _: Collaboration.ErrorBody = try await request("DELETE", "areas/\(area)/members/\(person)", body: Optional<Int>.none, epoch: epoch)
    }
    private func request<Response: Decodable, Body: Encodable>(_ method: String, _ path: String, body: Body?, epoch: Int64? = nil) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method; request.timeoutInterval = 35
        request.cachePolicy = .reloadIgnoringLocalCacheData; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if let credential { request.setValue("Bearer \(credential)", forHTTPHeaderField: "authorization") }
        if let epoch { request.setValue(String(epoch), forHTTPHeaderField: "if-match") }
        if let body { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; request.httpBody = try encoder.encode(body); request.setValue("application/json", forHTTPHeaderField: "content-type") }
        let (bytes, response) = try await session.data(for: request)
        guard bytes.count <= 8_388_608 else { throw CollaborationClientError.responseTooLarge }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? decoder.decode(Collaboration.ErrorBody.self, from: bytes))?.code ?? "invalidResponse"
            throw CollaborationClientError.server(status: http.statusCode, code: code)
        }
        return try decoder.decode(Response.self, from: bytes)
    }
}

/// Endpoint scope is an authority boundary. Refuse redirects before a second
/// origin/scheme can receive a request; callers must configure a new endpoint.
private final class CollaborationNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = CollaborationNoRedirect()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

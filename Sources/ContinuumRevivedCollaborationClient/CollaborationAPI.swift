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
    let baseURL: URL
    let credential: String?
    let session: URLSession
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
    public func createShareLink(area: UUID, request value: Collaboration.ShareLinkRequest) async throws -> Collaboration.ShareLink {
        try await request("POST", "areas/\(area)/links", body: value)
    }
    public func acceptShareLink(slug: String, token: String) async throws -> Collaboration.Scope {
        try await request("POST", "links/accept", body: Collaboration.AcceptShareLink(slug: slug, token: token))
    }
    public func selfEnroll(_ value: Collaboration.SelfEnroll) async throws -> Collaboration.Credential {
        try await request("POST", "self-enroll", body: value)
    }
    public func joinShareLink(_ value: Collaboration.JoinShareLink) async throws -> Collaboration.ShareLinkJoin {
        try await request("POST", "links/join", body: value)
    }
    public func shareLinks(area: UUID) async throws -> [Collaboration.ShareLinkAccess] { try await request("GET", "areas/\(area)/links", body: Optional<Int>.none) }
    public func revokeShareLink(area: UUID, link: UUID) async throws {
        let _: Collaboration.ErrorBody = try await request("DELETE", "areas/\(area)/links/\(link)", body: Optional<Int>.none)
    }
    public func removeShareLinkPerson(area: UUID, link: UUID, person: UUID) async throws {
        let _: Collaboration.ErrorBody = try await request("DELETE", "areas/\(area)/links/\(link)/people/\(person)", body: Optional<Int>.none)
    }
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
    /// Leaves `area` as this person. A relay without the route answers 404.
    public func leaveArea(area: UUID) async throws {
        let _: Collaboration.ErrorBody = try await request("DELETE", "areas/\(area)/membership", body: Optional<Int>.none)
    }
    func request<Response: Decodable, Body: Encodable>(_ method: String, _ path: String, body: Body?, epoch: Int64? = nil) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method; request.timeoutInterval = 35
        request.cachePolicy = .reloadIgnoringLocalCacheData; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "accept")
        // Additive: which areas this client can read (`Collaboration.LiveTile`).
        request.setValue(Collaboration.LiveTile.capability + "," + Collaboration.AgentTranscript.capability,
                         forHTTPHeaderField: Collaboration.LiveTile.capabilityHeader)
        if let credential { request.setValue("Bearer \(credential)", forHTTPHeaderField: "authorization") }
        if let epoch { request.setValue(String(epoch), forHTTPHeaderField: "if-match") }
        if let body { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; request.httpBody = try encoder.encode(body); request.setValue("application/json", forHTTPHeaderField: "content-type") }
        let (bytes, response) = try await boundedData(for: request)
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

extension CollaborationAPI {
    /// One request's bytes, bounded on every platform by the request's own
    /// timeout. On Linux, FoundationNetworking can read a complete
    /// `connection: close` response and still never finish the transfer: the
    /// socket sits in CLOSE_WAIT with nothing unread, the request timeout never
    /// fires, and the awaiting task hangs forever at 0% CPU. There the transfer
    /// runs as a plain data task with our own deadline that cancels it and
    /// throws `.timedOut`; an idempotent GET is retried once. Swift task
    /// cancellation still cancels the transfer (held update reads rely on it).
    func boundedData(for request: URLRequest) async throws -> (Data, URLResponse) {
        #if canImport(FoundationNetworking)
        do { return try await deadlineData(for: request) }
        catch let error as URLError where error.code == .timedOut && request.httpMethod == "GET" && !Task.isCancelled {
            return try await deadlineData(for: request)
        }
        #else
        return try await session.data(for: request)
        #endif
    }

    #if canImport(FoundationNetworking)
    private func deadlineData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let state = DeadlineTransfer()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error { state.finish(continuation, .failure(error)) }
                    else if let data, let response { state.finish(continuation, .success((data, response))) }
                    else { state.finish(continuation, .failure(URLError(.badServerResponse))) }
                }
                state.start(task)
                DispatchQueue.global().asyncAfter(deadline: .now() + request.timeoutInterval + 5) {
                    task.cancel()
                    if state.finish(continuation, .failure(URLError(.timedOut))) {
                        FileHandle.standardError.write(Data("collaboration client: \(request.httpMethod ?? "GET") transfer passed its deadline and was cancelled\n".utf8))
                    }
                }
            }
        } onCancel: { state.cancel() }
    }
    #endif
}

#if canImport(FoundationNetworking)
/// Resumes its continuation exactly once, whichever of completion, deadline
/// or cancellation comes first.
private final class DeadlineTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var finished = false
    private var cancelled = false
    func start(_ value: URLSessionTask) {
        lock.lock(); task = value; let cancelNow = cancelled; lock.unlock()
        if cancelNow { value.cancel() } else { value.resume() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let value = task; lock.unlock()
        value?.cancel()
    }
    @discardableResult
    func finish(_ continuation: CheckedContinuation<(Data, URLResponse), any Error>, _ result: Result<(Data, URLResponse), any Error>) -> Bool {
        lock.lock(); let first = !finished; finished = true; lock.unlock()
        if first { continuation.resume(with: result) }
        return first
    }
}
#endif

/// Endpoint scope is an authority boundary. Refuse redirects before a second
/// origin/scheme can receive a request; callers must configure a new endpoint.
private final class CollaborationNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = CollaborationNoRedirect()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ContinuumRevivedRelayProtocol

public struct HostedRelayClientConfiguration: Sendable, Equatable {
    public static let productionEndpoint = URL(string: "wss://relay.arrayapp.dev/v2/socket")!
    public var endpoint: URL; public var credential: String
    public init(endpoint: URL = Self.productionEndpoint, credential: String) { self.endpoint = endpoint; self.credential = credential }
}

/// Transport-neutral WebSocket state machine. Platform adapters own the socket
/// and feed text frames here, keeping credentials out of feature modules.
public actor HostedRelayClient {
    public enum State: Sendable, Equatable { case disconnected, authenticating, connected(instanceID: UUID), failed(code: String) }
    public private(set) var state: State = .disconnected
    public private(set) var cursor: Int64
    public let configuration: HostedRelayClientConfiguration
    private let encoder: JSONEncoder; private let decoder: JSONDecoder

    public init(configuration: HostedRelayClientConfiguration, cursor: Int64 = 0) {
        self.configuration = configuration; self.cursor = cursor
        encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    }
    public func authenticationFrame() throws -> Data {
        state = .authenticating
        return try encoder.encode(RelaySocketFrame.authenticate(token: configuration.credential, cursor: cursor))
    }
    public func receive(_ data: Data) throws -> RelaySocketFrame {
        let frame = try decoder.decode(RelaySocketFrame.self, from: data)
        switch frame {
        case .welcome(let instanceID, _, _): state = .connected(instanceID: instanceID)
        case .event(let event): cursor = max(cursor, event.sequence)
        case .error(let code): state = .failed(code: code)
        default: break
        }
        return frame
    }
    public func encode(_ frame: RelaySocketFrame) throws -> Data { try encoder.encode(frame) }
    public func disconnected() { state = .disconnected }
}

public struct HostedRelayAPI: Sendable {
    public var baseURL: URL
    private let session: URLSession
    public init(baseURL: URL = URL(string: "https://relay.arrayapp.dev")!, session: URLSession = .shared) { self.baseURL = baseURL; self.session = session }
    public func redeemAlphaInvite(code: String, deviceLabel: String) async throws -> RelayDesktopProvisioning {
        try await request("/v2/invites/redeem", method: "POST", body: RelayInviteRedemption(code: code, deviceLabel: deviceLabel), token: nil)
    }
    public func createPairingGrant(deviceLabel: String, credential: String) async throws -> RelayPairingGrant {
        try await request("/v2/pairing-grants", method: "POST", body: RelayPairingGrantRequest(deviceLabel: deviceLabel), token: credential)
    }
    public func cancelPairingGrant(id: UUID, credential: String) async throws -> RelayPairingCancellationResponse {
        try await request("/v2/pairing-grants/\(id.uuidString)", method: "DELETE", body: Optional<RelayErrorResponse>.none, token: credential)
    }
    public func exchangePairingGrant(code: String, deviceLabel: String) async throws -> RelayCompanionProvisioning {
        try await request("/v2/pairing/exchange", method: "POST", body: RelayPairingExchange(code: code, deviceLabel: deviceLabel), token: nil)
    }
    public func devices(credential: String) async throws -> [RelayDevice] {
        try await request("/v2/devices", method: "GET", body: Optional<RelayErrorResponse>.none, token: credential)
    }
    public func revoke(deviceID: UUID, credential: String) async throws {
        let _: RelayErrorResponse = try await request("/v2/devices/\(deviceID.uuidString)", method: "DELETE", body: Optional<RelayErrorResponse>.none, token: credential)
    }
    public func registerPushToken(_ token: Data, kind: RelayPushRegistrationKind, credential: String) async throws -> RelayPushRegistrationResponse {
        try await request("/v2/push-registrations", method: "POST", body: RelayPushRegistrationRequest(kind: kind, token: token), token: credential)
    }
    public func unregisterPushToken(kind: RelayPushRegistrationKind, credential: String) async throws -> RelayPushRegistrationResponse {
        try await request("/v2/push-registrations/\(kind.rawValue)", method: "DELETE", body: Optional<RelayErrorResponse>.none, token: credential)
    }
    private func request<Response: Decodable, Body: Encodable>(_ path: String, method: String, body: Body?, token: String?) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = method; request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; request.httpBody = try encoder.encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data)
    }
}

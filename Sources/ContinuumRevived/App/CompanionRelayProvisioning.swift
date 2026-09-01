import ContinuumRevivedCore
import Foundation
import Security

struct CompanionRelayDesktopIdentity: Codable, Equatable, Sendable {
    var instanceID: UUID
    var credential: String
}

struct CompanionRelayPairingGrant: Codable, Equatable, Sendable {
    var id: UUID
    var code: String
    var expiresAt: Date
}

struct CompanionRelayDevice: Codable, Equatable, Sendable {
    var id: UUID
    var label: String
    var lastSeenAt: Date?
    var capabilities: Set<String>
}

enum CompanionRelayProvisioningError: Error {
    case invalidEndpoint
    case rejected(status: Int)
    case invalidResponse
    case keychain(OSStatus)
}

/// Production relay configuration is compiled in. Environment overrides exist
/// only for development and tests; credentials never enter UserDefaults.
struct CompanionRelayProvisioning {
    static let productionHTTPOrigin = URL(string: "https://relay.arrayapp.dev")!
    static let productionWebSocket = URL(string: "wss://relay.arrayapp.dev/v2/socket")!

    /// Channel-scoped: a dev build must never read or disturb the prod
    /// credential. See `AppChannel.keychainService`.
    private static var keychainService: String {
        AppChannel.liveKeychainService("dev.arrayapp.companion.relay")
    }
    private static let keychainAccount = "desktop-instance"

    var httpOrigin: URL {
        guard let raw = ProcessInfo.processInfo.environment["ARRAY_RELAY_HTTP_ORIGIN"],
              let override = URL(string: raw),
              ["http", "https"].contains(override.scheme?.lowercased() ?? "") else {
            return Self.productionHTTPOrigin
        }
        return override
    }

    var webSocketEndpoint: URL {
        guard let raw = ProcessInfo.processInfo.environment["ARRAY_RELAY_WEBSOCKET_ENDPOINT"],
              let override = URL(string: raw),
              ["ws", "wss"].contains(override.scheme?.lowercased() ?? "") else {
            return Self.productionWebSocket
        }
        return override
    }

    func loadIdentity() throws -> CompanionRelayDesktopIdentity? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.keychainAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw CompanionRelayProvisioningError.keychain(status) }
        return try JSONDecoder().decode(CompanionRelayDesktopIdentity.self, from: data)
    }

    func redeem(invite: String, deviceLabel: String) async throws -> CompanionRelayDesktopIdentity {
        struct Request: Codable { var code: String; var deviceLabel: String }
        let identity: CompanionRelayDesktopIdentity = try await post(
            path: "/v2/invites/redeem",
            request: Request(code: invite, deviceLabel: deviceLabel),
            bearer: nil
        )
        try saveIdentity(identity)
        return identity
    }

    func createPairingGrant(deviceLabel: String) async throws -> CompanionRelayPairingGrant {
        struct Request: Codable { var deviceLabel: String }
        guard let identity = try loadIdentity() else { throw CompanionRelayProvisioningError.invalidResponse }
        return try await post(
            path: "/v2/pairing-grants",
            request: Request(deviceLabel: deviceLabel),
            bearer: identity.credential
        )
    }

    func cancelPairingGrant(id: UUID) async throws {
        guard let identity = try loadIdentity() else { throw CompanionRelayProvisioningError.invalidResponse }
        let _: PairingCancellationResponse = try await request(
            path: "/v2/pairing-grants/\(id.uuidString)",
            method: "DELETE",
            bearer: identity.credential
        )
    }

    func devices() async throws -> [CompanionRelayDevice] {
        guard let identity = try loadIdentity() else { return [] }
        return try await request(path: "/v2/devices", method: "GET", bearer: identity.credential)
    }

    func revoke(deviceID: UUID) async throws {
        guard let identity = try loadIdentity() else { throw CompanionRelayProvisioningError.invalidResponse }
        let _: RelayResponse = try await request(
            path: "/v2/devices/\(deviceID.uuidString)",
            method: "DELETE",
            bearer: identity.credential
        )
    }

    func health() async -> Bool {
        guard let url = URL(string: "/health", relativeTo: httpOrigin)?.absoluteURL else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    private func saveIdentity(_ identity: CompanionRelayDesktopIdentity) throws {
        let data = try JSONEncoder().encode(identity)
        let key: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.keychainAccount,
        ]
        SecItemDelete(key as CFDictionary)
        var item = key
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw CompanionRelayProvisioningError.keychain(status) }
    }

    private func post<Request: Encodable, Response: Decodable>(
        path: String,
        request body: Request,
        bearer: String?
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: httpOrigin)?.absoluteURL else { throw CompanionRelayProvisioningError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "authorization") }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CompanionRelayProvisioningError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw CompanionRelayProvisioningError.rejected(status: http.statusCode) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data)
    }

    private struct RelayResponse: Decodable { var code: String }
    private struct PairingCancellationResponse: Decodable { var id: UUID; var cancelled: Bool }

    private func request<Response: Decodable>(path: String, method: String, bearer: String) async throws -> Response {
        guard let url = URL(string: path, relativeTo: httpOrigin)?.absoluteURL else { throw CompanionRelayProvisioningError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CompanionRelayProvisioningError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw CompanionRelayProvisioningError.rejected(status: http.statusCode) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data)
    }
}

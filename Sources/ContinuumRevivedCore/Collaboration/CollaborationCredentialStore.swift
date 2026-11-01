import Foundation
import CryptoKit
import Security
import LocalAuthentication
import ContinuumRevivedCollaborationProtocol

public enum CollaborationCredentialStoreError: Error, Equatable {
    case invalidEndpoint, invalidToken, scopeMismatch, corruptRecord
    case unsupportedSchema(Int)
    case vaultFailure(Int32)
}

/// A service base URL, without credentials or an API suffix. Identity and cache
/// scopes use the same canonical spelling so URL aliases cannot split accounts.
public struct CollaborationServiceEndpoint: Hashable, Sendable {
    public let canonicalURL: URL
    public var canonicalString: String { canonicalURL.absoluteString }
    public static let productionURL = URL(string: "https://relay.arrayapp.dev")!
    public static let stagingURL = URL(string: "https://arrayapp-relay-staging.fly.dev")!
    /// Where sharing goes on a Mac with no account yet. Prod-channel builds use
    /// the production relay; every other build (Dev, bare binaries, checks)
    /// uses staging, so a dev build never signs anyone up on production.
    /// `CONTINUUM_COLLABORATION_ENDPOINT` overrides both, and may be plain
    /// http on loopback: the multiplayer preview and local checks use it.
    public static func channelDefault(bundleIdentifier: String?, environment: [String: String]) -> CollaborationServiceEndpoint? {
        if let raw = environment["CONTINUUM_COLLABORATION_ENDPOINT"] {
            return URL(string: raw).flatMap { try? CollaborationServiceEndpoint($0, allowsInsecureLoopback: true) }
        }
        return try? CollaborationServiceEndpoint(bundleIdentifier == AppChannel.prodBundleIdentifier ? productionURL : stagingURL)
    }

    /// The relay as a share link carries it: host, port and path, no scheme.
    public var shareLinkRelay: String {
        var value = canonicalString
        for prefix in ["https://", "http://"] where value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
    /// The endpoint a share link's relay names. Plain http only for loopback,
    /// and only where the caller allows it (local checks).
    public init(shareLinkRelay relay: String, allowsInsecureLoopback: Bool = false) throws {
        guard ShareLinkURL.isValidRelay(relay) else { throw CollaborationCredentialStoreError.invalidEndpoint }
        let host = relay.split(separator: "/", maxSplits: 1).first.map(String.init) ?? relay
        let bare = host.hasPrefix("[") ? String(host.prefix { $0 != "]" }.dropFirst()) : String(host.split(separator: ":").first ?? "")
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(bare.lowercased())
        guard let url = URL(string: (loopback && allowsInsecureLoopback ? "http://" : "https://") + relay) else {
            throw CollaborationCredentialStoreError.invalidEndpoint
        }
        try self.init(url, allowsInsecureLoopback: allowsInsecureLoopback)
    }

    public init(_ url: URL, allowsInsecureLoopback: Bool = false) throws {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), var host = parts.host?.lowercased(),
              !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { throw CollaborationCredentialStoreError.invalidEndpoint }
        if host.hasSuffix("."), !host.contains(":") { host.removeLast() }
        guard !host.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7f }),
              !host.contains(where: { "/\\@?#".contains($0) }) else { throw CollaborationCredentialStoreError.invalidEndpoint }
        if !host.contains(":") {
            guard host.utf8.count <= 253,
                  host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                      !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                          && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
                  }) else { throw CollaborationCredentialStoreError.invalidEndpoint }
        }
        let loopback = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)
        guard scheme == "https" || (scheme == "http" && loopback && allowsInsecureLoopback),
              !host.isEmpty, !host.contains("%"),
              parts.port.map({ (1...65535).contains($0) }) != false else { throw CollaborationCredentialStoreError.invalidEndpoint }
        let path = parts.percentEncodedPath
        guard !path.contains("//") else { throw CollaborationCredentialStoreError.invalidEndpoint }
        var segments: [String] = []
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/\\?#%"))
        for encoded in path.split(separator: "/", omittingEmptySubsequences: true) {
            guard let segment = String(encoded).removingPercentEncoding,
                  segment != ".", segment != "..", !segment.contains("/"), !segment.contains("\\"),
                  !segment.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7f }),
                  let normalized = segment.addingPercentEncoding(withAllowedCharacters: allowed) else { throw CollaborationCredentialStoreError.invalidEndpoint }
            segments.append(normalized)
        }
        parts.scheme = scheme; parts.host = host
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
        parts.percentEncodedPath = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
        guard let canonical = parts.url, canonical.absoluteString.utf8.count <= 2048 else { throw CollaborationCredentialStoreError.invalidEndpoint }
        canonicalURL = canonical
    }
}

public struct CollaborationCredentialScope: Equatable, Sendable {
    public let endpoint: CollaborationServiceEndpoint
    public let identity: Collaboration.Identity
    public init(endpoint: CollaborationServiceEndpoint, identity: Collaboration.Identity) {
        self.endpoint = endpoint; self.identity = identity
    }

    /// An opaque Keychain account name. The payload independently verifies these
    /// fields on read, so moving a valid record to another scope is refused.
    public var storageAccount: String {
        let components = [endpoint.canonicalString, identity.person.rawValue.uuidString, identity.device.uuidString]
        let bytes = Data(components.map { "\($0.utf8.count):\($0)" }.joined().utf8)
        return "collaboration.v1." + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

/// Inject storage explicitly. A fixture can exercise the complete credential
/// contract without constructing or calling the real Keychain adapter.
public protocol CollaborationCredentialVault: Sendable {
    func read(service: String, account: String) throws -> Data?
    func write(_ data: Data, service: String, account: String) throws
    func remove(service: String, account: String) throws
}

public struct CollaborationCredentialStore: Sendable {
    public static let serviceBase = "dev.arrayapp.macos.collaboration-credentials"
    public static func namespace(bundleIdentifier: String?) -> String {
        AppChannel.keychainService(serviceBase, bundleIdentifier: bundleIdentifier)
    }
    public let namespace: String
    private let vault: any CollaborationCredentialVault
    private struct Record: Codable {
        let schema: Int
        let namespace: String
        let endpoint: String
        let identity: Collaboration.Identity
        let token: String
    }

    public init(vault: any CollaborationCredentialVault, bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        self.vault = vault
        namespace = Self.namespace(bundleIdentifier: bundleIdentifier)
    }
    public func save(_ credential: Collaboration.Credential, for scope: CollaborationCredentialScope) throws {
        guard credential.identity == scope.identity else { throw CollaborationCredentialStoreError.scopeMismatch }
        try validate(credential.token)
        // Future or corrupt data is preserved rather than silently overwritten.
        if let previous = try vault.read(service: namespace, account: scope.storageAccount) {
            _ = try decode(previous, for: scope)
        }
        let record = Record(schema: 1, namespace: namespace, endpoint: scope.endpoint.canonicalString,
            identity: credential.identity, token: credential.token)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try vault.write(encoder.encode(record), service: namespace, account: scope.storageAccount)
    }
    public func load(for scope: CollaborationCredentialScope) throws -> Collaboration.Credential? {
        guard let bytes = try vault.read(service: namespace, account: scope.storageAccount) else { return nil }
        return try decode(bytes, for: scope)
    }
    /// Explicit removal affects only this channel/endpoint/person/device item.
    public func remove(for scope: CollaborationCredentialScope) throws {
        try vault.remove(service: namespace, account: scope.storageAccount)
    }
    private func decode(_ data: Data, for scope: CollaborationCredentialScope) throws -> Collaboration.Credential {
        guard data.count <= 16_384 else { throw CollaborationCredentialStoreError.corruptRecord }
        let record: Record
        do { record = try JSONDecoder().decode(Record.self, from: data) }
        catch { throw CollaborationCredentialStoreError.corruptRecord }
        guard record.schema == 1 else { throw CollaborationCredentialStoreError.unsupportedSchema(record.schema) }
        guard record.namespace == namespace, record.endpoint == scope.endpoint.canonicalString,
              record.identity == scope.identity else { throw CollaborationCredentialStoreError.scopeMismatch }
        try validate(record.token)
        return .init(identity: record.identity, token: record.token)
    }
    private func validate(_ token: String) throws {
        guard !token.isEmpty, token.utf8.count <= 4096,
              !token.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7f }) else { throw CollaborationCredentialStoreError.invalidToken }
    }
}

/// Array's own collaboration device credential only. Provider CLI login and
/// companion credentials use their existing owners and are never read here.
public struct KeychainCollaborationCredentialVault: CollaborationCredentialVault {
    private let namespace = AppChannel.liveKeychainService(CollaborationCredentialStore.serviceBase)
    public init() {}

    public func read(service: String, account: String) throws -> Data? {
        var query = try itemQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CollaborationCredentialStoreError.vaultFailure(status) }
        guard let data = result as? Data else { throw CollaborationCredentialStoreError.corruptRecord }
        return data
    }
    public func write(_ data: Data, service: String, account: String) throws {
        let query = try itemQuery(service: service, account: account)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else { throw CollaborationCredentialStoreError.vaultFailure(update) }
        } else if status != errSecSuccess { throw CollaborationCredentialStoreError.vaultFailure(status) }
    }
    public func remove(service: String, account: String) throws {
        let status = SecItemDelete(try itemQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CollaborationCredentialStoreError.vaultFailure(status) }
    }
    private func itemQuery(service: String, account: String) throws -> [String: Any] {
        // A dev adapter refuses a prod namespace before any Security call.
        guard service == namespace else { throw CollaborationCredentialStoreError.scopeMismatch }
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationContext as String: context]
    }
}

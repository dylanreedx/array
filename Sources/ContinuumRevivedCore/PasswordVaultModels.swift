import Foundation

public struct StoredCredentialScope: Codable, Equatable, Hashable, Sendable {
    public var scheme: String
    public var host: String
    public var port: Int?

    public init(scheme: String, host: String, port: Int? = nil) {
        self.scheme = scheme.lowercased()
        self.host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        self.port = port
    }

    public var credentialOrigin: CredentialOrigin { CredentialOrigin(scheme: scheme, host: host, port: port) }
}

public struct WebsiteCredentialMetadata: Codable, Equatable, Sendable {
    public var scope: StoredCredentialScope
    public var account: String
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(scope: StoredCredentialScope, account: String, createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.scope = scope
        self.account = account
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum CredentialAccessReason: String, Codable, Sendable {
    case userApprovedFill
    case userApprovedReveal
    case qaIntegrationCheck
}

public struct SecretString: Equatable, Sendable {
    private let storage: String

    public init(_ value: String) { self.storage = value }

    public func reveal(for reason: CredentialAccessReason) -> String { storage }
}

extension SecretString: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "<redacted-secret>" }
    public var debugDescription: String { "<redacted-secret>" }
}

public enum PasswordVaultError: Error, Equatable, Sendable {
    case notFound
    case duplicateConflict
    case rejectedHTTPStorage
    case invalidScope
    case backendFailure(String)
}

public protocol PasswordVaultService {
    func save(scope: StoredCredentialScope, account: String, password: SecretString) throws
    func update(scope: StoredCredentialScope, account: String, password: SecretString) throws
    func delete(scope: StoredCredentialScope, account: String) throws
    func listMetadata(matching scope: StoredCredentialScope) throws -> [WebsiteCredentialMetadata]
    func retrieve(scope: StoredCredentialScope, account: String, reason: CredentialAccessReason) throws -> SecretString
}

public enum PasswordVaultStoragePolicy {
    public static func validateStorage(scope: StoredCredentialScope, policy: BrowserCredentialPolicy = .default) throws {
        switch scope.scheme {
        case "https":
            return
        case "http":
            guard policy.loopbackHTTPExceptionEnabled,
                  policy.publicHTTPFill == .allow,
                  CredentialOriginMatcher.isLoopbackHost(scope.host) else {
                throw PasswordVaultError.rejectedHTTPStorage
            }
        default:
            throw PasswordVaultError.invalidScope
        }
    }
}

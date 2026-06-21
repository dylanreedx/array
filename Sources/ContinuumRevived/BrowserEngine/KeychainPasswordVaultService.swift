import ContinuumRevivedCore
import Foundation
import Security

final class KeychainPasswordVaultService: PasswordVaultService {
    static let namespaceMarker = "com.continuum-revived.password-vault.v1"
    static let accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String

    private let namespace: String
    private let policy: BrowserCredentialPolicy

    init(namespace: String = KeychainPasswordVaultService.namespaceMarker, policy: BrowserCredentialPolicy = .default) {
        self.namespace = namespace
        self.policy = policy
    }

    func save(scope: StoredCredentialScope, account: String, password: SecretString) throws {
        try PasswordVaultStoragePolicy.validateStorage(scope: scope, policy: policy)
        var query = itemQuery(scope: scope, account: account)
        query[kSecValueData as String] = Data(password.reveal(for: .userApprovedFill).utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { throw PasswordVaultError.duplicateConflict }
        try throwIfFailed(status)
    }

    func update(scope: StoredCredentialScope, account: String, password: SecretString) throws {
        try PasswordVaultStoragePolicy.validateStorage(scope: scope, policy: policy)
        let status = SecItemUpdate(itemQuery(scope: scope, account: account) as CFDictionary, [kSecValueData as String: Data(password.reveal(for: .userApprovedFill).utf8)] as CFDictionary)
        if status == errSecItemNotFound { throw PasswordVaultError.notFound }
        try throwIfFailed(status)
    }

    func delete(scope: StoredCredentialScope, account: String) throws {
        let status = SecItemDelete(itemQuery(scope: scope, account: account) as CFDictionary)
        if status == errSecItemNotFound { throw PasswordVaultError.notFound }
        try throwIfFailed(status)
    }

    func listMetadata(matching scope: StoredCredentialScope) throws -> [WebsiteCredentialMetadata] {
        var query = scopeQuery(scope)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try throwIfFailed(status)
        let rows = result as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let account = row[kSecAttrAccount as String] as? String else { return nil }
            return WebsiteCredentialMetadata(
                scope: scope,
                account: account,
                createdAt: row[kSecAttrCreationDate as String] as? Date,
                updatedAt: row[kSecAttrModificationDate as String] as? Date
            )
        }
    }

    func retrieve(scope: StoredCredentialScope, account: String, reason: CredentialAccessReason) throws -> SecretString {
        _ = reason
        var query = itemQuery(scope: scope, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw PasswordVaultError.notFound }
        try throwIfFailed(status)
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw PasswordVaultError.backendFailure("Keychain returned non-UTF8 data")
        }
        return SecretString(value)
    }

    func countItemsForNamespace() throws -> Int {
        var query = namespaceQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return 0 }
        try throwIfFailed(status)
        return (result as? [[String: Any]])?.count ?? 0
    }

    func deleteAllForNamespace() throws -> Int {
        let count = try countItemsForNamespace()
        let deleteStatus = SecItemDelete(namespaceQuery() as CFDictionary)
        if deleteStatus != errSecItemNotFound { try throwIfFailed(deleteStatus) }
        return count
    }

    private func itemQuery(scope: StoredCredentialScope, account: String) -> [String: Any] {
        var query = scopeQuery(scope)
        query[kSecAttrAccount as String] = account
        return query
    }

    private func namespaceQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: namespace,
            kSecAttrSecurityDomain as String: namespace
        ]
    }

    private func scopeQuery(_ scope: StoredCredentialScope) -> [String: Any] {
        var query = namespaceQuery()
        query[kSecAttrServer as String] = scope.host
        query[kSecAttrProtocol as String] = scope.scheme == "https" ? kSecAttrProtocolHTTPS : kSecAttrProtocolHTTP
        if let port = scope.port { query[kSecAttrPort as String] = port }
        return query
    }

    private func throwIfFailed(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw PasswordVaultError.backendFailure(SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \\(status)") }
    }
}

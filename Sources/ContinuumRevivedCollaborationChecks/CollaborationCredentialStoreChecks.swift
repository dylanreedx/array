import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

private struct CredentialChecksFailure: Error { let label: String }
private enum CredentialVaultFixtureError: Error { case injectedWrite }
private func credentialCheck(_ value: Bool, _ label: String) throws {
    guard value else { throw CredentialChecksFailure(label: label) }
    print("PASS credentials: \(label)")
}
private func credentialRefuses(_ expected: CollaborationCredentialStoreError, _ label: String, _ action: () throws -> Void) throws {
    do { try action(); throw CredentialChecksFailure(label: "expected refusal: \(label)") }
    catch let error as CollaborationCredentialStoreError { try credentialCheck(error == expected, label) }
}

/// Implements the same storage interface as Keychain without touching Security,
/// defaults, app support or any existing credential service.
private final class CredentialMemoryVault: CollaborationCredentialVault, @unchecked Sendable {
    private struct Location: Hashable { let service: String; let account: String }
    private let lock = NSLock()
    private var entries: [Location: Data] = [:]
    private var calls: [String] = []
    private var failWrite = false
    func read(service: String, account: String) throws -> Data? {
        lock.withLock { calls.append(service); return entries[.init(service: service, account: account)] }
    }
    func write(_ data: Data, service: String, account: String) throws {
        try lock.withLock {
            calls.append(service)
            if failWrite { failWrite = false; throw CredentialVaultFixtureError.injectedWrite }
            entries[.init(service: service, account: account)] = data
        }
    }
    func remove(service: String, account: String) throws {
        lock.withLock { calls.append(service); entries.removeValue(forKey: .init(service: service, account: account)) }
    }
    func replace(_ data: Data, service: String, account: String) {
        lock.withLock { entries[.init(service: service, account: account)] = data }
    }
    func raw(service: String, account: String) -> Data? {
        lock.withLock { entries[.init(service: service, account: account)] }
    }
    func failNextWrite() { lock.withLock { failWrite = true } }
    func calledServices() -> [String] { lock.withLock { calls } }
}

func runCollaborationCredentialStoreChecks() throws {
    let alias = try CollaborationServiceEndpoint(URL(string: "HTTPS://RELAY.example:443/team/%61/")!)
    let endpoint = try CollaborationServiceEndpoint(URL(string: "https://relay.example/team/a")!)
    try credentialCheck(alias == endpoint && alias.canonicalString == "https://relay.example/team/a", "URL aliases normalize without splitting credentials")
    let root = try CollaborationServiceEndpoint(URL(string: "https://RELAY.example:443/")!)
    try credentialCheck(root.canonicalString == "https://relay.example", "root and default port normalize")
    let otherEndpoint = try CollaborationServiceEndpoint(URL(string: "https://relay.example/team/b")!)
    try credentialCheck(endpoint != otherEndpoint, "meaningful service base paths remain distinct")
    let loopback = try CollaborationServiceEndpoint(URL(string: "http://localhost:80/")!, allowsInsecureLoopback: true)
    try credentialCheck(loopback.canonicalString == "http://localhost", "loopback HTTP requires explicit opt-in")
    _ = try CollaborationServiceEndpoint(URL(string: "http://[::1]:80/")!, allowsInsecureLoopback: true)
    for value in ["http://localhost", "http://remote.example", "https://user@relay.example", "https://relay.example?x=1", "https://relay.example/#anchor", "https://relay.example/a/../b", "https://relay.example/%2E%2E/b", "https://relay.example/a%2fb", "https://relay.example/a%5cb", "https://relay.example//team", "https://relay.example:99999", "https://bad%20host", "https://relay..example", "https://-relay.example"] {
        if let url = URL(string: value) {
            try credentialRefuses(.invalidEndpoint, "rejects unsafe endpoint form") { _ = try CollaborationServiceEndpoint(url) }
        }
    }
    try credentialRefuses(.invalidEndpoint, "loopback permission cannot allow remote plaintext service") {
        _ = try CollaborationServiceEndpoint(URL(string: "http://remote.example")!, allowsInsecureLoopback: true)
    }

    let vault = CredentialMemoryVault()
    let dev = CollaborationCredentialStore(vault: vault, bundleIdentifier: AppChannel.devBundleIdentifier)
    let prod = CollaborationCredentialStore(vault: vault, bundleIdentifier: AppChannel.prodBundleIdentifier)
    let editor = CollaborationCredentialStore(vault: vault, bundleIdentifier: AppChannel.editorTestBundleIdentifier)
    try credentialCheck(dev.namespace != prod.namespace && editor.namespace != dev.namespace && editor.namespace != prod.namespace,
        "prod, dev and editor-test credentials use different services")
    let bare = CollaborationCredentialStore(vault: vault, bundleIdentifier: nil)
    try credentialCheck(bare.namespace == dev.namespace, "bare binaries use dev credential namespace")
    let identity = Collaboration.Identity(person: .init(), device: UUID())
    let scope = CollaborationCredentialScope(endpoint: endpoint, identity: identity)
    let aliasScope = CollaborationCredentialScope(endpoint: alias, identity: identity)
    let credential = Collaboration.Credential(identity: identity, token: "array-collaboration-device-token-a")
    try dev.save(credential, for: scope)
    let loaded = try dev.load(for: aliasScope)
    try credentialCheck(loaded?.identity == identity && loaded?.token == credential.token, "canonical endpoint and identity round trip")
    try credentialCheck(try prod.load(for: scope)?.token == nil && editor.load(for: scope)?.token == nil, "other channels cannot see dev credential")
    let alternateService = CollaborationCredentialScope(endpoint: otherEndpoint, identity: identity)
    let alternatePerson = CollaborationCredentialScope(endpoint: endpoint, identity: .init(person: .init(), device: identity.device))
    let alternateDevice = CollaborationCredentialScope(endpoint: endpoint, identity: .init(person: identity.person, device: UUID()))
    for distinct in [alternateService, alternatePerson, alternateDevice] {
        try credentialCheck(distinct.storageAccount != scope.storageAccount, "endpoint/person/device contributes to credential account")
        try credentialCheck(try dev.load(for: distinct)?.token == nil, "another service/person/device sees no credential")
    }
    for distinct in [alternatePerson, alternateDevice] {
        try credentialRefuses(.scopeMismatch, "save refuses identity swap") { try dev.save(credential, for: distinct) }
    }
    guard let original = vault.raw(service: dev.namespace, account: scope.storageAccount) else { throw CredentialChecksFailure(label: "saved credential record missing") }
    vault.replace(original, service: dev.namespace, account: alternatePerson.storageAccount)
    try credentialRefuses(.scopeMismatch, "serialized credential moved to another person refuses") { _ = try dev.load(for: alternatePerson) }
    try credentialCheck(vault.raw(service: dev.namespace, account: alternatePerson.storageAccount) == original, "refusal preserves displaced record")
    vault.replace(original, service: dev.namespace, account: alternateService.storageAccount)
    try credentialRefuses(.scopeMismatch, "serialized credential moved to another endpoint refuses") { _ = try dev.load(for: alternateService) }
    vault.replace(original, service: prod.namespace, account: scope.storageAccount)
    try credentialRefuses(.scopeMismatch, "serialized credential copied across channels refuses") { _ = try prod.load(for: scope) }
    try prod.remove(for: scope)
    try credentialCheck(try dev.load(for: scope)?.token == credential.token, "other-channel removal preserves dev account")

    for token in ["", "contains\nnewline", "contains space", String(repeating: "x", count: 4097)] {
        try credentialRefuses(.invalidToken, "invalid bearer token refuses before persistence") {
            try dev.save(.init(identity: identity, token: token), for: scope)
        }
    }
    guard var futureJSON = try JSONSerialization.jsonObject(with: original) as? [String: Any] else { throw CredentialChecksFailure(label: "saved credential is not an object") }
    futureJSON["schema"] = 2
    let future = try JSONSerialization.data(withJSONObject: futureJSON, options: .sortedKeys)
    vault.replace(future, service: dev.namespace, account: scope.storageAccount)
    try credentialRefuses(.unsupportedSchema(2), "future credential schema refuses load") { _ = try dev.load(for: scope) }
    try credentialRefuses(.unsupportedSchema(2), "future credential schema refuses automatic overwrite") { try dev.save(credential, for: scope) }
    try credentialCheck(vault.raw(service: dev.namespace, account: scope.storageAccount) == future, "future credential bytes remain intact")
    let corrupt = Data([0xff, 0x00, 0x02])
    vault.replace(corrupt, service: dev.namespace, account: scope.storageAccount)
    try credentialRefuses(.corruptRecord, "corrupt credential refuses load") { _ = try dev.load(for: scope) }
    try credentialRefuses(.corruptRecord, "corrupt credential refuses automatic overwrite") { try dev.save(credential, for: scope) }
    try credentialCheck(vault.raw(service: dev.namespace, account: scope.storageAccount) == corrupt, "corrupt credential bytes remain intact")
    try dev.remove(for: scope)
    try dev.save(credential, for: scope)
    vault.failNextWrite()
    do {
        try dev.save(.init(identity: identity, token: "replacement-token"), for: scope)
        throw CredentialChecksFailure(label: "expected injected write failure")
    } catch CredentialVaultFixtureError.injectedWrite { print("PASS credentials: vault write failure propagates") }
    try credentialCheck(try dev.load(for: scope)?.token == credential.token, "failed replacement retains original credential")
    try dev.remove(for: scope)
    try dev.remove(for: scope)
    try credentialCheck(try dev.load(for: scope)?.token == nil, "explicit removal is scoped and idempotent")
    try credentialCheck(vault.calledServices().allSatisfy { [dev.namespace, prod.namespace, editor.namespace].contains($0) },
        "credential contract never requests provider or companion namespaces")
    print("Collaboration credential checks passed with an injected memory vault; real Keychain adapter remains unexercised.")
}

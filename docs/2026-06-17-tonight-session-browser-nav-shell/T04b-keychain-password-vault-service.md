# T04b — Keychain PasswordVaultService

Status: implementation-ready
Tag: tonight [browser] [security]
Depends on: T04

## Goal
Add an isolated Continuum-owned website credential vault backed by macOS Keychain, without any WebKit form detection, JavaScript fill, save prompt, or Chrome/password-manager import.

## Implementation decision
Implement only the storage service contract and tests.

Use macOS Keychain Internet Password items:
- `kSecClassInternetPassword`
- `kSecAttrServer` = canonical host
- `kSecAttrProtocol` = HTTPS/HTTP enum where applicable
- `kSecAttrPort` = explicit port where present, especially loopback/dev
- `kSecAttrAccount` = username/account
- optional `kSecAttrPath` only if intentionally path-scoped later; default path is not used for matching
- secret value in `kSecValueData`
- accessibility: prefer `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` unless product explicitly chooses sync later

The vault API must return metadata separately from secrets. Secret retrieval requires an explicit reason such as `.userApprovedFill`.

Keychain vault namespace boundary:
- Continuum must never read, update, delete, or overwrite Keychain items that were not created by Continuum.
- The Keychain item identity/query must include an app-owned namespace marker in addition to website scope/account, or the implementation must use an app-owned generic-password service namespace while storing website scope as metadata.
- If an unowned/pre-existing Keychain item exists for the same website/account, Continuum must treat it as not found or duplicate-conflict; it must not retrieve or mutate it.
- Tests must create a same-scope/same-account unowned fixture item and prove the vault does not read, update, or delete it.

HTTP credential storage policy:
- `save` and `update` must reject public `http://` scopes by default.
- Loopback `http://` storage is allowed only if the T04 loopback exception policy is explicitly enabled.
- LAN/private-network HTTP addresses are never treated as loopback.

## Scope
- New app/security files, likely under `Sources/ContinuumRevived/BrowserEngine/` or a small app service folder:
  - `PasswordVaultService.swift`
  - `KeychainPasswordVaultService.swift`
  - `WebsiteCredential.swift`
- Pure model types may live in `Sources/ContinuumRevivedCore/` if they are AppKit/Security-free:
  - `StoredCredentialScope`
  - `WebsiteCredentialMetadata`
  - `CredentialAccessReason`
- Add isolated tests/checks:
  - fake vault tests in `ContinuumRevivedCoreChecks` if core types are added;
  - app flag `--browser-keychain-vault-check` for real Keychain integration.

## Out of scope / non-goals
- No WebKit user scripts.
- No form metadata detector.
- No fill/save/update prompts.
- No import/export.
- No Chrome, 1Password, Bitwarden, or browser-profile reads.
- No credential values in QA artifacts.

## Product/security policy
API requirements:
- `listMetadata(matching:)` returns origin/account metadata only; never password bytes.
- `retrieve(scope:account:reason:)` returns secret only for explicit allowed reasons.
- `save/update/delete` require canonical credential scope from T04 origin policy.
- Logging of Keychain queries must redact `kSecValueData` and passwords.
- Test credentials use a run-specific account/server namespace and are deleted in `defer`/cleanup.

Suggested API shape:

```swift
struct StoredCredentialScope: Codable, Equatable, Sendable {
    var scheme: String
    var host: String
    var port: Int?
}

struct WebsiteCredentialMetadata: Codable, Equatable, Sendable {
    var scope: StoredCredentialScope
    var account: String
    var createdAt: Date?
    var updatedAt: Date?
}

enum CredentialAccessReason: String, Codable, Sendable {
    case userApprovedFill
    case userApprovedReveal
    case qaIntegrationCheck
}

protocol PasswordVaultService {
    func save(scope: StoredCredentialScope, account: String, password: SecretString) throws
    func update(scope: StoredCredentialScope, account: String, password: SecretString) throws
    func delete(scope: StoredCredentialScope, account: String) throws
    func listMetadata(matching scope: StoredCredentialScope) throws -> [WebsiteCredentialMetadata]
    func retrieve(scope: StoredCredentialScope, account: String, reason: CredentialAccessReason) throws -> SecretString
}
```

`SecretString` / equivalent should avoid accidental `CustomStringConvertible` plaintext output.

## Acceptance criteria
- [ ] Keychain service saves, retrieves, updates, deletes one test credential.
- [ ] Metadata listing does not include password bytes or password debug descriptions.
- [ ] Retrieving a missing credential returns a typed not-found error, not an empty password.
- [ ] Same host with different account stores separate items.
- [ ] Loopback credentials with different ports store separate items.
- [ ] Vault queries are restricted to Continuum-owned items only.
- [ ] Same website/account pre-existing non-Continuum Keychain item is not read, updated, deleted, or overwritten.
- [ ] Public HTTP credential save/update is rejected by default.
- [ ] Loopback HTTP save/update is rejected when the loopback exception is disabled.
- [ ] LAN/private-network HTTP scopes are rejected even when loopback exception tests are enabled.
- [ ] Cleanup removes all test Keychain items created by the check.
- [ ] Manifest and logs do not contain the fixture password.

## Nightly QA contract
Required pure check:

```bash
swift run ContinuumRevivedCoreChecks
```

Required app flag:

```bash
swift run continuum-revived --browser-keychain-vault-check
```

Required artifact:

```text
qa-runs/<timestamp>/browser-keychain-vault/manifest.json
```

Manifest fields:

```json
{
  "check": "browser-keychain-vault",
  "saved": true,
  "retrievedAfterSave": true,
  "updated": true,
  "deleted": true,
  "metadataContainsSecret": false,
  "differentAccountsDistinct": true,
  "localhostPortsDistinct": true,
  "vaultQueriesContinuumOwnedOnly": true,
  "unownedSameScopeItemIgnored": true,
  "unownedSameScopeItemNotMutatedOrDeleted": true,
  "publicHTTPSaveRejectedByDefault": true,
  "loopbackHTTPSaveRejectedWhenExceptionDisabled": true,
  "lanPrivateHTTPRejected": true,
  "usedRealKeychainService": true,
  "storageBackend": "macOSKeychainInternetPassword",
  "accessibility": "kSecAttrAccessibleWhenUnlockedThisDeviceOnly",
  "testNamespace": "...",
  "itemsRemainingAfterCleanup": 0,
  "fixtureSecretAbsentFromManifest": true,
  "fixtureSecretAbsentFromQARunArtifacts": true,
  "cleanupDeletedItems": true
}
```

Reviewer rejection rules:
- Reject if any artifact/log contains the fixture password.
- Reject if `listMetadata` can expose secret values.
- Reject if service stores passwords in workspace files, BrowserState, UserDefaults, or plain JSON.
- Reject if Keychain queries can match or mutate non-Continuum-owned Internet Password items for the same server/account.
- Reject if missing credentials are silently treated as blank passwords.

## Stop conditions
Stop / do not mark Done if:
- T04 guardrail policy/checks are not present;
- Keychain integration requires broad entitlements/signing changes that cannot be verified locally;
- cleanup cannot reliably remove QA credentials;
- implementation starts adding WKWebView detector/fill/save code;
- any test needs real user website credentials.

## Verification commands

```bash
swift build
swift run ContinuumRevivedCoreChecks
swift run continuum-revived --browser-credential-guardrails-check
swift run continuum-revived --browser-keychain-vault-check
```

## Research sources
- Apple Keychain Services: https://developer.apple.com/documentation/security/keychain-services
- `kSecClassInternetPassword`: https://developer.apple.com/documentation/security/ksecclassinternetpassword
- Adding a password to Keychain: https://developer.apple.com/documentation/security/keychain_services/keychain_items/adding_a_password_to_the_keychain
- Keychain item accessibility: https://developer.apple.com/documentation/security/keychain_services/keychain_items/restricting_keychain_item_accessibility
- Research artifact: `.pi/agent-runs/web-research-20260618T014546Z-a73a97/final.md`

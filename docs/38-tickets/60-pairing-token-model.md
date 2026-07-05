# One-time pairing token — issue, exchange, and down-scope

> **NIGHT-3 SCOPING RULING (C-20260705-022 rev.2, orchestrator, 2026-07-05 ~09:45) — binding on
> tonight's attempt; overrides the conflicting storage wording below.** The original C-022 ruling
> (written 00:30, recovered from the interrupted-attempt stash) said "NO GRDB tonight" because Track A
> was rebuilding the Auth stores GRDB-backed in a parallel worktree. That premise is now RESOLVED: the
> ~06:00 merge landed (`6a076ec`), and `Sources/ContinuumRevivedCore/Auth/` is the ticket-54 GRDB
> substrate (`PairingStore`/`SessionStore` on `DatabaseQueue`, `AuthDatabase`, atomic guarded consume,
> 0600 `signing.key` file, `AuthError` in ScopeAuthorization.swift). Revised rules:
>
> 1. **The GRDB-backed substrate IS the base — extend it additively, do not rewrite it.** Keep churn
>    in `PairingStore.swift`/`SessionStore.swift` surgical. Do not rename existing `AuthError` cases
>    (`unknown`/`revoked`/`alreadyUsed`/`expired`/`scopeNotGranted`/`invalidToken`); do not touch
>    `Package.swift` (GRDB dep already present). `SessionStore.exchange(...)` is the accepted home for
>    the exchange — the ticket's free-function packaging is NOT required.
> 2. **Salvage is PRE-APPLIED.** The orchestrator applied the 8 cleanly-applying files from the
>    interrupted attempt (stash@{1} "night3 B1 60-pairing interrupted attempt") to the working tree:
>    `PairingURL.swift` (PairingAlphabet rejection-sampling + fragment-only URL), `Registry.swift`
>    (pairedDevices + decodeIfPresent migration + PairedDeviceEntry), `Scope.isSuperset`,
>    `BootstrapGrant.expiresAt` + AuthRandom→PairingAlphabet delegation, `AuthChecks.swift` (full
>    ticket-60 suite), checks `main.swift` subprocess hook, ComponentLab card, ContinuumApp debug menu.
>    Do NOT pop or drop the stash — it stays for audit. Remaining work:
>    a. **Surgical GRDB store edits** (the two hunks that no longer applied): bootstrap-path TTL-expiry
>       check in `PairingStore.consume` (throw `.expired` when `bootstrapGrant.expiresAt <= clock.now()`,
>       return the grant's real `expiresAt`, keep the constant-time credential compare);
>       `SessionStore.exchange` takes `requested: Scope?` (nil → grant ceiling), default
>       `ttl: 2_592_000` (30 days), guard `grant.scopes.isSuperset(of: effective)`.
>    b. **Adapt the salvaged AuthChecks to the GRDB API**: `restoredSessions:` does not exist —
>       the restart-survival suite must instead share BOTH a temp `signing.key` file AND an on-disk
>       `databaseURL` across the two subprocess invocations (sessions now persist for real via GRDB);
>       drop the obsolete `AuthSession: Codable` conformance need if nothing else requires it. No-arg
>       store inits give isolated in-memory DBs (`AuthDatabase.queue(at: nil)`) — correct for logic checks.
>    c. **Ensure the suite actually gates**: the salvaged main.swift hunk only adds the subprocess
>       early-exit hook — `main.swift` must also CALL the ticket-60 suite so the matrix runs it and
>       prints measured values; confirm in run-matrix output.
> 3. **Signing key stays the existing 0600 on-disk file** (`SessionStore.loadOrCreateSigningKey`) —
>    headless Keychain ACLs across rebuilt unsigned check binaries can wedge the run with interactive
>    prompts. Keychain migration is an owed morning item.
> 4. ALL listed logic checks remain required (100k-sample bias, concurrent single-use race,
>    expired/revoked consume, down-scope trio, HMAC bit-flips, token string round-trip, bootstrap
>    unbounded + TTL-expiry, URL fragment round-trip, Registry pairedDevices decode-migration) in
>    `ContinuumRevivedCoreChecks`, wired into `scripts/run-matrix.sh`.
> 5. **ComponentLab rule applies (Dylan 2026-07-04):** the "Pairing Token" lab card + lab self-check
>    (`#token=` fragment present, `queryItems` nil, credential exactly 12 chars, all chars in the
>    32-symbol alphabet) ships in the same commit. `Debug ▸ Auth ▸ Issue Pairing Token (Observer)` is
>    code-complete; its Console.app look is `visual-gate-owed` (morning checklist).

## What this delivers

When this ticket lands, Continuum has a complete, self-contained pairing-token subsystem living in `ContinuumRevivedCore`. A host process can issue a one-time, short-lived credential — delivered as a URL fragment — that a connecting device exchanges exactly once for a scoped bearer session. The exchange enforces down-scope-only: the session the device receives can only carry a subset of what the pairing token authorized, never more. A token that has been used, expired, or revoked cannot be exchanged again; every one of those failure modes is a typed error, not a silent allow.

The system outcome is that "pair my iPhone as a read-only observer" has a complete, working auth path: the Mac issues a token scoped to `.observer`, renders it as a `continuum://pair#token=<credential>` URL (QR code or AirDrop), the phone exchanges it, and the resulting session is structurally incapable of carrying `orchestrationOperate` or `terminalOperate` — not by runtime check, but by the type the session carries. This is the auth complement to the sync/observation type split: that split keeps runtime handles off the wire; scopes keep capabilities off the untrusted device.

This ticket does not open a socket, does not implement a transport, and does not ship a visible UI flow. It is the cryptographic and authorization spine that everything remote and multi-device builds on top of.

## How it fits

This ticket builds directly on the Scope OptionSet model, which must exist before the pairing token can reference it. `PairingToken.scopes` is typed `Scope`, and the exchange's down-scope enforcement is a single `isSuperset(of:)` call on that type. Without the OptionSet, this ticket cannot compile.

What this ticket unblocks is significant. The WebSocket ticket machinery — the short-lived `wsTicket` that lets a client open a live channel without putting a long-lived bearer in a query string — needs a `Session` to bind to, and sessions only exist after an exchange. The per-message authorization check needs a `Session.scopes` to test against. The iOS pairing UI flow needs a token to render and a URL fragment to encode it in. The control channel itself, whatever transport it rides, needs every incoming connection to present a valid scoped session before any message is authorized. All of that is blocked on this ticket.

The desktop-bootstrap path — where the Mac's own process holds an in-memory administrative grant at launch so it never has to present a pairing credential to itself — is also part of this ticket, because it is the same `PairingStore.consume` path with a seeded, unbounded-use in-memory entry rather than a persisted single-use row.

## The approach

The implementation follows the t3code pairing model exactly, translated into Swift idioms. There are four types: `Scope` (already exists after its own ticket), `PairingToken` (the persisted record of a pairing grant), `PairingStore` (the actor that issues and atomically consumes tokens), and `AuthSession` (a scoped bearer session issued by the exchange). A fifth function, `exchange`, ties them together and is the only public entry point a connecting device ever calls.

**Token generation.** Credentials are 12 characters drawn from a 32-symbol crowd-safe alphabet (`23456789ABCDEFGHJKLMNPQRSTUVWXYZ` — no `0`, `O`, `1`, `I`) using rejection sampling over `SecRandomCopyBytes` to eliminate modulo bias. Each token gets a UUID identifier, a 5-minute TTL computed at issue time, a `scopes` ceiling, an optional human label, and a `consumedAt` field that starts nil. Storage is SQLite via GRDB; the uniqueness invariant is enforced at the DB layer, not in Swift.

**Atomic single-use consume.** The `consume` operation is a single `UPDATE … WHERE credential = ? AND consumedAt IS NULL AND revokedAt IS NULL AND expiresAt > ?` that both checks and marks in one statement. If the statement updates zero rows, the caller reads the row to determine why — expired, already consumed, revoked, or simply not found — and returns a typed error for each case. There is no TOCTOU window; the atomicity is at the SQLite transaction boundary, not in application code.

**Down-scope-only exchange.** After a successful consume, the exchange receives the token's granted `scopes` ceiling and an optional `requested: Scope?` from the connecting device. The rule is: `let effective = requested ?? grant.scopes; guard grant.scopes.isSuperset(of: effective)`. If the device asks for a scope the token did not grant, the exchange fails with `AuthError.scopeNotGranted` before a session is ever issued. A device cannot elevate itself by requesting more than the token carries.

**Session token.** The issued `AuthSession` is a simple value: `id` (UUID), `subject` (opaque string label — there are no user accounts), `scopes`, `expiresAt` (30 days for a bearer session), and `revokedAt`. The bearer token on the wire is `base64url(JSON(claims)) + "." + HMAC-SHA256(payload, signingKey)`. The signing key is 32 random bytes, generated once via `SecRandomCopyBytes` and stored in the macOS Keychain under a stable service+account key. Verification recomputes the HMAC with `CCHmac` and compares using a timing-safe equality loop, then loads the session row to confirm it has not been revoked.

**Desktop-bootstrap grant.** At app launch, `PairingStore` seeds a single in-memory entry with `scopes: .admin`, `remainingUses: .unbounded`, and a 24-hour TTL. This entry is never persisted to SQLite and never travels outside the process. When the Mac's own renderer or a local trusted process exchanges the bootstrap credential, it gets a real session via the same `exchange` function — auth is never bypassed, even on loopback. The distinction from a normal pairing token is that the in-memory entry survives multiple `consume` calls; it is exhausted only by TTL or explicit revocation.

**URL fragment delivery.** The issued token credential is delivered as `continuum://pair#token=<credential>&scopes=<encoded>`. The fragment (`#…`) is never sent to a server — it is only available to the receiving app after the deep link is opened. This is the same pattern t3code uses for `issueStartupPairingUrl`: the secret stays client-side.

## Where it lives

All new types land in `Sources/ContinuumRevivedCore/Auth/`, a new subdirectory. The Auth subdirectory is a sibling of the existing files in `Sources/ContinuumRevivedCore/` (confirmed at `Sources/ContinuumRevivedCore/Registry.swift:1` — the module root). No existing file is modified except one: `Sources/ContinuumRevivedCore/Registry.swift` gains a `pairedDevices: [PairedDeviceEntry]` array field so the host can enumerate active sessions for the "manage paired devices" surface later. This is an additive field with a default of `[]`, preserving Codable compatibility via `decodeIfPresent`.

**New files:**

- `Sources/ContinuumRevivedCore/Auth/AuthErrors.swift` — `AuthError` enum with cases: `tokenNotFound`, `tokenExpired`, `tokenAlreadyUsed`, `tokenRevoked`, `scopeNotGranted`, `sessionNotFound`, `sessionExpired`, `sessionRevoked`, `invalidTokenFormat`, `hmacMismatch`, `unscopedMessage(ControlMessage)`
- `Sources/ContinuumRevivedCore/Auth/PairingToken.swift` — `PairingToken` struct, `PairingAlphabet` enum with `credential(length:)`, `RemainingUses` enum (`.once` / `.unbounded`)
- `Sources/ContinuumRevivedCore/Auth/PairingStore.swift` — `PairingStore` actor, `issue(scopes:ttl:label:)`, `consume(_:)`, `revoke(id:)`, `seedBootstrap(credential:scopes:ttl:)` 
- `Sources/ContinuumRevivedCore/Auth/AuthSession.swift` — `AuthSession` struct, `AuthSessionClaims` (Codable, used for token serialization), `SessionStore` actor with `issue(scopes:subject:ttl:)`, `verify(token:)`, `revoke(id:)`, `revokeAllExcept(id:)`
- `Sources/ContinuumRevivedCore/Auth/PairingExchange.swift` — `exchange(pairingCredential:requested:subject:meta:)` free function tying `PairingStore.consume` → down-scope check → `SessionStore.issue` → token string
- `Sources/ContinuumRevivedCore/Auth/PairingURL.swift` — `PairingURL.issue(credential:scopes:baseScheme:)` returning a `URL` with the credential in the fragment; `PairingURL.parse(_:)` extracting the credential from an incoming deep link
- `Sources/ContinuumRevivedCore/Auth/SigningKeyStore.swift` — `SigningKeyStore` reading and writing a 32-byte key from the macOS Keychain (service: `"continuum.auth.signing"`, account: `"hmac-key"`); `hmacSign(payload:key:)` and `hmacVerify(payload:tag:key:)` using `CommonCrypto`

**Modified file:**

- `Sources/ContinuumRevivedCore/Registry.swift:8` — add `public var pairedDevices: [PairedDeviceEntry]` after `settings`; add `PairedDeviceEntry` struct (id, label, scopes, pairedAt, lastSeenAt) in the same file or a companion `RegistryTypes.swift`

## Implementation breadcrumbs

```swift
// Auth/PairingToken.swift

public struct PairingToken: Codable, Sendable, Identifiable {
    public let id: UUID
    public let credential: String       // 12 chars, PairingAlphabet
    public let scopes: Scope            // ceiling for any exchange
    public let expiresAt: Date
    public let label: String?
    public var consumedAt: Date?        // nil until first successful exchange
    public var revokedAt: Date?
}

enum PairingAlphabet {
    static let symbols = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
    static func credential(length: Int = 12) -> String {
        var out = [Character]()
        let n = symbols.count
        let limit = (256 / n) * n          // reject bytes above this to avoid modulo bias
        while out.count < length {
            var b: UInt8 = 0
            SecRandomCopyBytes(kSecRandomDefault, 1, &b)
            guard Int(b) < limit else { continue }
            out.append(symbols[Int(b) % n])
        }
        return String(out)
    }
}
```

```swift
// Auth/PairingStore.swift

public actor PairingStore {
    private var bootstrapGrant: BootstrapEntry?  // in-memory only, never persisted
    private let db: DatabaseQueue               // GRDB

    // Seed called once at app launch; credential is held by the host process only.
    public func seedBootstrap(credential: String, scopes: Scope, ttl: TimeInterval = 86400) {
        bootstrapGrant = BootstrapEntry(credential: credential, scopes: scopes,
                                        expiresAt: Date().addingTimeInterval(ttl))
    }

    public func issue(scopes: Scope, ttl: TimeInterval = 300, label: String? = nil) throws -> PairingToken {
        let token = PairingToken(id: UUID(), credential: PairingAlphabet.credential(),
                                 scopes: scopes, expiresAt: Date().addingTimeInterval(ttl), label: label)
        try db.write { db in try token.insert(db) }
        return token
    }

    // Returns the token on success; throws AuthError on any failure.
    public func consume(_ credential: String) throws -> PairingToken {
        // Check in-memory bootstrap first (unbounded uses, TTL-only expiry)
        if let b = bootstrapGrant, b.credential == credential {
            guard b.expiresAt > Date() else { throw AuthError.tokenExpired }
            return PairingToken(id: UUID(), credential: credential, scopes: b.scopes,
                                expiresAt: b.expiresAt, label: "desktop-bootstrap")
        }
        // Persisted path: atomic UPDATE … WHERE consumedAt IS NULL AND revokedAt IS NULL AND expiresAt > now
        return try db.write { db -> PairingToken in
            let now = Date()
            let count = try db.execute(sql: """
                UPDATE pairing_token
                SET consumed_at = ?
                WHERE credential = ? AND consumed_at IS NULL AND revoked_at IS NULL AND expires_at > ?
                """, arguments: [now, credential, now])
            guard count == 1 else {
                // Read to distinguish failure modes
                guard let row = try PairingToken.filter(Column("credential") == credential).fetchOne(db)
                else { throw AuthError.tokenNotFound }
                if row.revokedAt != nil  { throw AuthError.tokenRevoked   }
                if row.expiresAt < now   { throw AuthError.tokenExpired   }
                                           throw AuthError.tokenAlreadyUsed
            }
            return try PairingToken.filter(Column("credential") == credential).fetchOne(db)!
        }
    }
}
```

```swift
// Auth/PairingExchange.swift

public func exchange(
    pairingCredential: String,
    requested: Scope?,
    subject: String,
    pairingStore: PairingStore,
    sessionStore: SessionStore
) async throws -> (token: String, session: AuthSession) {
    let grant = try await pairingStore.consume(pairingCredential)   // single-use
    let effective = requested ?? grant.scopes
    guard grant.scopes.isSuperset(of: effective) else {
        throw AuthError.scopeNotGranted                             // down-scope only
    }
    return try await sessionStore.issue(scopes: effective, subject: subject, ttl: .days(30))
}
```

```swift
// Auth/PairingURL.swift

public enum PairingURL {
    static let scheme = "continuum"
    static let host   = "pair"

    // Fragment carries the credential — never hits a server log.
    public static func issue(credential: String, scopes: Scope) -> URL {
        var comps = URLComponents()
        comps.scheme   = scheme
        comps.host     = host
        comps.fragment = "token=\(credential)&scopes=\(scopes.rawValue)"
        return comps.url!
    }

    public static func parse(_ url: URL) -> String? {
        guard url.scheme == scheme, url.host == host,
              let fragment = url.fragment else { return nil }
        return URLComponents(string: "?\(fragment)")?.queryItems?
            .first(where: { $0.name == "token" })?.value
    }
}
```

```swift
// Auth/SigningKeyStore.swift — HMAC-SHA256 over CommonCrypto

import CommonCrypto

func hmacSign(payload: Data, key: Data) -> Data {
    var digest = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
    digest.withUnsafeMutableBytes { digestPtr in
        key.withUnsafeBytes { keyPtr in
            payload.withUnsafeBytes { payloadPtr in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
                       keyPtr.baseAddress, key.count,
                       payloadPtr.baseAddress, payload.count,
                       digestPtr.baseAddress)
            }
        }
    }
    return digest
}

func hmacVerify(payload: Data, tag: Data, key: Data) -> Bool {
    let expected = hmacSign(payload: payload, key: key)
    guard expected.count == tag.count else { return false }
    // Timing-safe comparison — no short-circuit on first mismatch.
    return zip(expected, tag).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
}
```

The session token format mirrors t3code's: `base64url(UTF8(JSON(claims))) + "." + base64url(HMAC-SHA256(payload, signingKey))`. Verification re-splits on the last `.`, recomputes the HMAC, and calls `hmacVerify` before decoding the claims or touching the DB.

## How we test it

### Logic (pure Core checks)

These tests run in `ContinuumRevivedCoreChecks` against an in-memory GRDB database, no app process, no filesystem state.

- **Credential generation is unbiased.** Generate 100,000 credentials via `PairingAlphabet.credential()`. Assert every character is in the 32-symbol alphabet. Assert the character frequency distribution falls within 3 standard deviations of uniform across all 32 symbols — modulo-bias rejection is working if this holds.
- **Consume is single-use.** Issue one token. Call `consume` twice concurrently on 10 Task threads. Assert exactly one succeeds and the rest throw `AuthError.tokenAlreadyUsed`. The atomicity guarantee lives here.
- **Consume fails on expired token.** Issue a token with `ttl: -1` (expires in the past). Assert `consume` throws `AuthError.tokenExpired`.
- **Consume fails on revoked token.** Issue a token, call `revoke(id:)`, assert `consume` throws `AuthError.tokenRevoked`.
- **Down-scope is enforced.** Issue a token with `scopes: .observer` (only `orchestrationRead`). Attempt an exchange requesting `Scope([.orchestrationRead, .orchestrationOperate])`. Assert the exchange throws `AuthError.scopeNotGranted` before issuing any session.
- **Down-scope permits a strict subset.** Same token with `scopes: .operator`. Exchange requesting only `[.orchestrationRead]`. Assert the exchange succeeds and the resulting session carries only `orchestrationRead` — not the full `.operator` set.
- **Exchange with nil requested grants the ceiling.** Issue a token with `scopes: .observer`. Exchange with `requested: nil`. Assert the session carries exactly `.observer`.
- **HMAC round-trip.** Call `hmacSign`, then `hmacVerify` with correct key → `true`. Flip one bit in the tag → `false`. Flip one bit in the payload → `false`. Use a different key → `false`.
- **Token string round-trip.** Issue a session, serialize to token string, verify the token string, assert the recovered claims match the original session ID and scopes.
- **Bootstrap grant is unbounded.** Seed a bootstrap grant. Call `consume` on it 20 times consecutively. Assert all 20 succeed and return the bootstrap scopes.
- **Bootstrap grant expires.** Seed a bootstrap grant with `ttl: -1`. Assert `consume` throws `AuthError.tokenExpired`.
- **URL fragment round-trip.** Issue a pairing URL for a given credential. Parse it back. Assert the recovered credential is identical. Assert the URL's fragment is non-empty and the query component is nil (the secret never lands in `?`).

### Backend (real-path / integration)

These tests run against the real app process with a real GRDB file on disk and the real Keychain (or a test keychain). They must not mock `PairingStore` or `SessionStore`.

- **Signing key survives process restart.** Write a signing key to Keychain in one test, read it back in a second process invocation. Sign a payload with the first key; verify with the key recovered in the second run. Assert verification passes — the session tokens a running app issued remain valid after a quit-and-relaunch.
- **Concurrent exchange race under load.** Spawn 50 concurrent `Task`s each attempting to exchange the same single-use pairing credential. Assert exactly one succeeds; the other 49 all receive `AuthError.tokenAlreadyUsed`. Assert the SQLite database contains exactly one session row for that credential.
- **Desktop bootstrap via exchange.** Simulate app launch: call `seedBootstrap`, run `exchange` with the bootstrap credential and `requested: .admin`, assert the resulting session carries `.admin`. Call `exchange` again with the same credential — assert it still succeeds (unbounded uses), returns a fresh session with a new UUID.
- **Revocation propagates to verify.** Issue a session via exchange. Verify the token — succeeds. Call `sessionStore.revoke(id:)`. Verify the same token again — assert `AuthError.sessionRevoked`.

### UX (visual gate + dogfood)

The visible surface of this ticket is deliberately thin — the pairing URL is issued, and a future ticket renders it as a QR code. What can be gated visually now is the token appearing in the debug/developer menu.

**Visual gate.** Add a hidden developer menu item under `Debug > Auth > Issue Pairing Token (Observer)`. Triggering it calls `pairingStore.issue(scopes: .observer)`, constructs the pairing URL, and logs it to Console.app under the `continuum.auth` subsystem. The gate: the logged URL must contain a `#token=` fragment (not `?token=`), the credential portion must be exactly 12 characters, and every character must be in the crowd-safe alphabet. A reviewer confirms this by eye in Console.app.

**Dogfood snippet.** Open the app → hold ⌥ and open the Debug menu → click "Issue Pairing Token (Observer)" → open Console.app filtered to subsystem `continuum.auth` → see a log line like:

```
[continuum.auth] pairing-url issued: continuum://pair#token=K7P3MXNQ5R2A&scopes=1
```

The credential is 12 characters. The scopes raw value is `1` (the bit for `orchestrationRead` only). The `#` separator is present. No credential appears in the URL's path or query components.

## Execution mode

**Supervised.** The cryptographic logic — HMAC sign/verify, credential generation, atomic consume, down-scope enforcement — is fully deterministic and can be driven to 100% coverage by the logic and backend checks alone. However, the Keychain integration is not exercisable without a real app process and entitlements, and the URL fragment guarantee (confirming the credential truly never appears in the query) is a one-look visual check. The dogfood snippet above is the gate; a matrix alone is insufficient per the verification doctrine.

## Done when

- [ ] `PairingAlphabet.credential()` generates 12-character strings exclusively from the 32-symbol crowd-safe alphabet, verified by the bias test over 100,000 samples.
- [ ] `PairingStore.consume` is atomic: concurrent calls on the same credential produce exactly one success and N-1 `tokenAlreadyUsed` errors, confirmed by the race test under 50 concurrent tasks.
- [ ] `exchange` rejects any requested scope set that is not a subset of the pairing token's ceiling, confirmed by the down-scope unit test.
- [ ] `exchange` with `requested: nil` grants exactly the token's ceiling, no more.
- [ ] HMAC verification returns false when the payload, tag, or key differs by a single bit.
- [ ] Session tokens survive a simulated process restart: a token signed before a relaunch verifies correctly after, confirmed by the Keychain round-trip integration test.
- [ ] The desktop-bootstrap grant accepts multiple `consume` calls without error and expires only by TTL.
- [ ] The pairing URL places the credential in the URL fragment (after `#`), not the query (after `?`).
- [ ] `Registry` gains a `pairedDevices: [PairedDeviceEntry]` field; loading a registry file that omits the field (pre-migration) succeeds and returns an empty array.
- [ ] The dogfood snippet produces a correctly formatted log line with a 12-character, alphabet-valid credential in a `#token=` fragment.
- [ ] All new public types are `Sendable`; `PairingStore` and `SessionStore` are `actor`s with no data races under the Swift concurrency checker.

## Depends on / unblocks

This ticket depends on the Scope OptionSet model. `PairingToken.scopes` is typed `Scope`; the down-scope enforcement is `grant.scopes.isSuperset(of: effective)`. Neither compiles without the OptionSet in place.

This ticket unblocks the WebSocket ticket layer (the short-lived `wsTicket` used to authenticate a channel upgrade without putting a bearer in a query string — that machinery binds to an `AuthSession`, which only exists after an exchange), the per-message authorization check (which tests `session.scopes.contains(requiredScope)` against a live session), the iOS pairing UI flow (which renders the pairing URL as a QR code and handles the returning deep link), and any ticket that needs to enforce "this device may not perform this action" at the type level rather than by convention.

## Watch out for

**The atomic consume is the load-bearing piece.** If `PairingStore.consume` is implemented as read-then-update rather than update-then-read, there is a TOCTOU window where two concurrent callers both see `consumedAt IS NULL`, both proceed, and both succeed. The only correct implementation is the single `UPDATE … WHERE consumedAt IS NULL …` statement that returns a row count. If the row count is not exactly 1, the update did not win the race. Do not implement this as a Swift actor lock around two separate DB calls — the actor lock does not protect against two separate process instances sharing a database file (future remote case).

**The signing key must be Keychain-backed, not on disk.** A key written to the application support directory is readable by any process with the same user identity. The Keychain entry must use `kSecAttrAccessibleAfterFirstUnlock` so it survives app relaunch without requiring the user to unlock, while still being protected at the OS level. Do not generate a fresh key at every launch — session tokens issued before a relaunch would all fail verification.

**The credential must not appear in the URL query.** The URL fragment is stripped by HTTP clients before sending a request; a query parameter is not. Even though Continuum's pairing URL is a deep link and never hits an HTTP server, establishing the fragment-only invariant now means the pattern is safe if it ever does. `PairingURL.issue` should assert in debug builds that `comps.queryItems` is nil.

**CommonCrypto is available on macOS without an import library**, but the compiler needs the `import CommonCrypto` header — confirm the `ContinuumRevivedCore` target has `SWIFT_INCLUDE_PATHS` pointing at the SDK's `CommonCrypto` module map, or use the `CryptoKit` `HMAC<SHA256>` type instead. `CryptoKit.HMAC<SHA256>.isValidAuthenticationCode` is constant-time by contract and removes the manual timing-safe loop. Prefer `CryptoKit` if it is already available in the target; introduce `CommonCrypto` only if it is not.

**Stop condition — scope escalation bug.** If the `isSuperset` call is inverted (`effective.isSuperset(of: grant.scopes)` instead of `grant.scopes.isSuperset(of: effective)`), an observer token can be used to request administrative scope. The down-scope unit test catches this exactly; the test must run before the integration tests, not only as part of the full suite.

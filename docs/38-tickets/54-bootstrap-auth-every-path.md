# Bootstrap auth on every reach path, including loopback

## What this delivers

A clean, uniform auth spine that covers every connection Continuum's process ever makes or
accepts — localhost, SSH-forwarded VPS, and the future iOS observer — without a single
`if (localhost) { skipAuth }` branch. The mechanism is a seeded in-memory bootstrap grant
issued once at app launch; the Mac's own process exchanges it for a real admin-scoped bearer
session exactly like any other client would. From that moment forward, every downstream
connection (a second local client, a remote box reached over `sshForward`, an iOS phone
asking to observe) is authorized against the same `Scope` OptionSet model before it touches
any data or issues any command.

Concretely: by the time this ticket is done, Continuum has a `Scope` OptionSet, a
`BootstrapGrant` that the app process seeds on launch, a `SessionStore` that can mint and
verify scoped HMAC-signed bearer tokens, and a `PairingStore` that can issue and atomically
consume one-time pairing credentials. No connection — not even a loopback socket opened by
the app itself — skips the session check. The iOS observer path (`.observer` scope =
`.orchestrationRead` only) is representable as a type-level guarantee from day one even
though the real iOS client does not yet exist.

## How it fits

This ticket sits in the remote-reach group and builds on two prior decisions. The `Host` /
`RemoteReach` model established by the injectable-substrates work gives us the `Host`
abstraction behind which every reach path (localhost, sshForward, tailscale) is already
represented — this ticket adds the auth layer that sits in front of those paths, so every
reach variant goes through the same gate. The `Scope` OptionSet model is the direct Swift
translation of the t3code pairing pattern documented in the transport-auth-pairing
study (`docs/2026-06-30-t3code-steal/02-transport-auth-pairing.md §2.1`), which this
codebase does not yet have at all.

This ticket unblocks the iOS observer work (which needs the `.observer` scope to already
exist so the observer-only promise is a compile-time property rather than a runtime flag),
the remote-host daemon work (which needs a real session check on every incoming control
message), and any ticket that adds a `sendKeys`, `moveTile`, or `spawnTerminal` control
message (each of which needs a `requiredScope` entry before it can ship). It also unblocks
the `wsTicket` short-lived query token pattern, should the sync transport ever land on
WebSocket — that pattern (mint a 5-minute HMAC token over the authenticated control path,
pass it as a query param on the raw socket upgrade) works naturally once the session layer
here is in place.

Decision D6 in the locked decisions is the authoritative source for the identity model: the
sync leg leans on the iCloud/CloudKit account and builds nothing; the control leg uses
device pairing + scoped sessions and builds everything here. This ticket covers the control
leg only.

## The approach

Stand up four thin types in a new `Auth` group inside `ContinuumRevivedCore`:

1. `Scope` — an `OptionSet` whose cases mirror the read/operate split from the
   transport-auth-pairing study. The five cases cover everything Continuum's control
   channel will ever need: `orchestrationRead`, `orchestrationOperate`, `terminalOperate`,
   `accessRead`, `accessWrite`. Two named bundles — `.observer` (`.orchestrationRead` only)
   and `.admin` (all five) — are the only values granted at launch. No scope is inferred
   from context; authorization is a membership test against the token's frozen scope set.

2. `BootstrapGrant` — a single in-memory, unbounded-use grant seeded at app launch with
   `.admin` scope. This is the exact analogue of t3code's `desktopBootstrapToken` (study
   §1.3, `PairingGrantStore.ts:300`): the grant lives inside the process that already has
   the user's trust, so it does not need to be short-lived. It is never persisted and is
   regenerated fresh on every launch. A client (including the Mac app itself) that holds this
   grant seed may exchange it for a real bearer session.

3. `PairingStore` — a GRDB/SQLite-backed actor that issues one-time pairing credentials
   (12-character, crowd-safe alphabet, CSPRNG, 5-minute TTL) and atomically consumes them on
   exchange. "Atomic" here means a single `UPDATE … WHERE consumed_at IS NULL AND revoked_at
   IS NULL AND expires_at > NOW()` that writes `consumed_at` and returns the row in one
   statement, making double-redemption structurally impossible. The bootstrap grant is
   represented as a special in-memory path inside the same `consume` call: it bypasses the
   DB row and returns `remainingUses: .unbounded` so the renderer can re-exchange after a
   page reload without regenerating the seed.

4. `SessionStore` — an in-memory-first, GRDB-backed store for scoped bearer sessions. A
   session token is `base64url(JSON(claims)) + "." + HMAC-SHA256(payload, signingKey)`.
   Claims carry `sid` (UUID), `sub` (device label string), `scopes` (Scope raw value),
   `iat`, and `exp`. Verification recomputes the HMAC with `timingSafeEqual`, decodes,
   checks `exp`, and loads the session row (must exist and not be revoked). The signing key
   is 32 bytes from `SecRandomCopyBytes`, written atomically to `~/Library/Application
   Support/Continuum/auth/signing.key` with `0600` permissions on first launch and read on
   subsequent launches.

The exchange from a pairing credential (or the bootstrap grant seed) to a scoped session is
a down-scope-only operation: the requested `Scope` must be a subset of what the grant
ceiling allows, otherwise the exchange fails with a typed `AuthError.scopeNotGranted`. This
is the one-line invariant that makes `.observer` a ceiling, not a hint.

Finally, a `requiredScope` table maps every control message type to the `Scope` case it
needs. Any message type not present in the table is a hard error at the call site — not a
silent allow. This is the property that prevents an unscoped message from shipping by
accident.

## Where it lives

All new files go into `Sources/ContinuumRevivedCore/Auth/`. No changes to any existing
file are required; this is net-new surface.

- `Sources/ContinuumRevivedCore/Auth/Scope.swift` — the `Scope` OptionSet, its five cases,
  and the `.observer` / `.admin` named bundles.
- `Sources/ContinuumRevivedCore/Auth/BootstrapGrant.swift` — the in-memory grant value
  type, seeded once at launch with `.admin` scope. Carries a `seed: String` (32 random
  hex bytes) used as the pairing credential for the bootstrap exchange path.
- `Sources/ContinuumRevivedCore/Auth/PairingStore.swift` — the `PairingStore` actor,
  GRDB-backed, with `issue(scopes:ttl:label:)` and `consume(_ credential: String) throws ->
  PairingGrant`.
- `Sources/ContinuumRevivedCore/Auth/SessionStore.swift` — the `SessionStore` actor,
  `issue(scopes:subject:ttl:) -> Session`, `verify(_ token: String) throws -> Session`,
  `revoke(id:)`, and `revokeAll(except:)`.
- `Sources/ContinuumRevivedCore/Auth/AuthError.swift` — the typed error enum shared by all
  auth operations: `.unknown`, `.expired`, `.alreadyUsed`, `.revoked`, `.scopeNotGranted`,
  `.invalidToken`, `.missingScope(Scope)`, `.unscopedMessage`.
- `Sources/ContinuumRevivedCore/Auth/MessageScope.swift` — the `ControlMessage` enum and
  the `requiredScope` table. The `authorize(_ msg: ControlMessage, session: Session) throws`
  function calls `fatalError` (not a recoverable throw) if a message has no entry — a
  missing entry is a programmer error, not a runtime condition.

Existing seams that are NOT changed by this ticket:

- `Sources/ContinuumRevivedCore/TmuxSession.swift:8` — `TmuxSession.sessionName(tileId:)`
  is a pure argv constructor; it has no auth concern and is untouched.
- `Sources/ContinuumRevivedCore/TmuxSession.swift:12` — `TmuxSession.wrap(…)` likewise.
- `Sources/ContinuumRevivedCore/Registry.swift:3` — `Registry` is the persisted canvas
  document; auth sessions are not stored here and the struct is untouched.

## Implementation breadcrumbs

**Scope OptionSet:**

```swift
public struct Scope: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let orchestrationRead    = Scope(rawValue: 1 << 0)
    public static let orchestrationOperate = Scope(rawValue: 1 << 1)
    public static let terminalOperate      = Scope(rawValue: 1 << 2)
    public static let accessRead           = Scope(rawValue: 1 << 3)
    public static let accessWrite          = Scope(rawValue: 1 << 4)

    // Observer = read the activity tree; cannot move tiles, send keys, or manage pairings.
    // This is what an iOS phone gets — a type-level guarantee, not a runtime flag.
    public static let observer: Scope = [.orchestrationRead]
    public static let admin: Scope   = [.orchestrationRead, .orchestrationOperate,
                                         .terminalOperate, .accessRead, .accessWrite]
}
```

**Bootstrap grant seed and exchange:**

```swift
// Seeded once in AppDelegate / App init, held for the process lifetime.
let bootstrapGrant = BootstrapGrant.seed()   // 32 random hex bytes, .admin ceiling

// The Mac app's own process exchanges it immediately for an admin session.
// Re-exchange is allowed (unbounded uses) so a page reload does not require re-seeding.
let (adminToken, adminScopes) = try sessionStore.exchange(
    bootstrapCredential: bootstrapGrant.seed,
    requested: .admin,
    subject: "mac-local",
    pairingStore: pairingStore
)
// adminToken is now stored in-process; every local call presents this token.
```

**PairingStore.consume — the atomic single-use gate:**

```swift
// Bootstrap path: credential == bootstrapGrant.seed
// → returns PairingGrant(scopes: .admin, remainingUses: .unbounded) from memory.
// All other credentials hit the DB:
// UPDATE pairing_grants
//   SET consumed_at = ?
//   WHERE credential = ? AND consumed_at IS NULL
//     AND revoked_at IS NULL AND expires_at > ?
//   RETURNING *
// Zero rows returned → throw .unknown / .expired / .alreadyUsed / .revoked (check which).
```

**SessionStore.verify:**

```swift
func verify(_ token: String) throws -> Session {
    let parts = token.split(separator: ".", maxSplits: 1)
    guard parts.count == 2 else { throw AuthError.invalidToken }
    let payload = String(parts[0])
    let mac     = String(parts[1])
    let expected = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: signingKey)
    guard timingSafeEqual(Data(expected), Data(base64url: mac)) else { throw AuthError.invalidToken }
    let claims = try JSONDecoder().decode(SessionClaims.self, from: Data(base64url: payload))
    guard claims.exp > Date() else { throw AuthError.expired }
    guard let row = db.session(id: claims.sid), row.revokedAt == nil else { throw AuthError.revoked }
    return Session(id: claims.sid, scopes: claims.scopes, subject: claims.sub, expiresAt: claims.exp)
}
```

**requiredScope table and authorize:**

```swift
enum ControlMessage: String {
    case subscribeActivity
    case moveTile, resizeTile, spawnTerminal
    case sendKeys
    case listDevices
    case pairDevice
}

let requiredScope: [ControlMessage: Scope] = [
    .subscribeActivity: .orchestrationRead,
    .moveTile:          .orchestrationOperate,
    .resizeTile:        .orchestrationOperate,
    .spawnTerminal:     .orchestrationOperate,
    .sendKeys:          .terminalOperate,
    .listDevices:       .accessRead,
    .pairDevice:        .accessWrite,
]

func authorize(_ msg: ControlMessage, session: Session) throws {
    guard let need = requiredScope[msg] else {
        fatalError("No scope entry for \(msg) — add one before shipping this message type.")
    }
    guard session.scopes.contains(need) else { throw AuthError.missingScope(need) }
}
```

**App-launch wiring (pseudocode only — the implementer wires this in the real app delegate):**

```
on app launch:
  1. Load or generate signingKey → atomic write to auth/signing.key (0600)
  2. seed = BootstrapGrant.seed()              // 32 random hex, .admin ceiling, in-memory only
  3. pairingStore = PairingStore(db: authDB)   // GRDB at ~/Library/.../Continuum/auth/auth.db
  4. sessionStore = SessionStore(db: authDB, signingKey: signingKey)
  5. (adminToken, _) = try sessionStore.exchange(bootstrapCredential: seed, requested: .admin,
                                                  subject: "mac-local", pairingStore: pairingStore)
  6. Store adminToken in process memory. Pass sessionStore + pairingStore to every service
     that needs to issue or verify tokens.
  // From this point: zero code path reaches a tmux session, project store, or activity
  // stream without first going through sessionStore.verify().
```

## How we test it

### Logic (pure Core checks)

All suites run in `ContinuumRevivedCoreChecks` using the existing `do { … }` block
convention. No subprocess, no network, no disk I/O beyond an in-memory GRDB.

**Scope suite.** Construct `.observer` and `.admin`. Assert `.observer.contains(.orchestrationRead)` is true and `.observer.contains(.orchestrationOperate)` is false. Assert `.admin` is a superset of `.observer`. Construct a `Scope(rawValue:)` round-trip through `Codable` and assert equality. Assert that requesting `.admin` when the grant ceiling is `.observer` throws `AuthError.scopeNotGranted` from the exchange function, and requesting `.observer` when the ceiling is `.admin` succeeds and the returned session carries exactly `.observer`. This is the type-level observer-only guarantee expressed as a concrete failing case.

**BootstrapGrant suite.** Seed a grant. Exchange it for `.admin` — assert the returned scopes equal `.admin`. Exchange it again (unbounded uses) — assert success and that the returned token is distinct from the first (fresh session, new `sid`). Attempt to exchange with `requested: .admin` using a random string that is not the seed — assert `AuthError.unknown`. Attempt to exchange with `requested: [.admin, Scope(rawValue: 1 << 10)]` (a scope outside the ceiling) — assert `AuthError.scopeNotGranted`.

**PairingStore suite.** Using an in-memory GRDB database: issue a token with `.observer` scope and a 300-second TTL. Consume it once — assert success, returned grant has `.observer` scope. Consume the same credential again — assert `AuthError.alreadyUsed`. Issue a second token. Advance a `FakeClock` past its TTL. Attempt to consume — assert `AuthError.expired`. Issue a third token. Revoke it by id. Attempt to consume — assert `AuthError.revoked`. All four error states must be explicitly exercised.

**SessionStore suite.** Issue a session with `.observer` scope. Verify its token — assert returned session carries `.observer`. Mutate one byte of the HMAC portion of the token and assert `AuthError.invalidToken`. Issue a session with a `ttl` of 1 second; advance `FakeClock` by 2 seconds; verify — assert `AuthError.expired`. Revoke the session by id; verify the original (non-expired) token — assert `AuthError.revoked`. Assert `timingSafeEqual` is used (not `==`) by verifying that a timing-unsafe compare of the HMAC bytes would accept a crafted token with a flipped trailing bit — this proves the production path uses the constant-time path.

**MessageScope suite.** For every case of `ControlMessage`, assert that `requiredScope[msg] != nil` — this is the "no unscoped message" invariant expressed as a check that fails at compile time if a new enum case is added without a table entry (achievable by exhaustive switch). Call `authorize(.subscribeActivity, session:)` with a session carrying only `.orchestrationRead` — assert success. Call `authorize(.moveTile, session:)` with the same session — assert `AuthError.missingScope(.orchestrationOperate)`. Call `authorize(.sendKeys, session:)` — assert `AuthError.missingScope(.terminalOperate)`.

### Backend (real-path integration)

The real-path check exercises the full launch-time bootstrap sequence against a real on-disk GRDB database (not in-memory), a real `SecRandomCopyBytes`-derived signing key written to a temp directory, and the full `verify` code path — no bypass of the HMAC or the DB lookup.

Steps, all recorded in the manifest with measured values:

1. Stand up `PairingStore` and `SessionStore` backed by a GRDB database at a temp path.
   Assert the database file is created with permissions `0600`.
2. Seed a `BootstrapGrant`. Exchange it for `.admin`. Assert the returned token round-trips
   through `sessionStore.verify()` and the returned session carries `scopes == .admin`.
   Record `token_length`, `scopes_rawValue`, `session_id` in the manifest.
3. Issue a one-time pairing token via `pairingStore.issue(scopes: .observer, ttl: 300)`.
   Exchange it for `.observer`. Verify the token. Assert scopes equal `.observer`.
   Attempt to exchange the same credential again — assert `AuthError.alreadyUsed`.
   Record `credential_length`, `exchange_ok: true`, `double_exchange_error: "alreadyUsed"`.
4. Attempt `authorize(.moveTile, session: observerSession)` — assert the thrown error is
   `AuthError.missingScope(.orchestrationOperate)`. Record `move_tile_denied: true`.
5. Attempt `authorize(.subscribeActivity, session: observerSession)` — assert success.
   Record `subscribe_activity_allowed: true`.

No manifest field may be `{passed: true}`. Every check records a measured value or a typed
error name.

### UX (visual gate + dogfood snippet)

The auth layer is invisible to the user under normal operation — there is no new UI in this
ticket. The visual gate is a negative check: open the app, create a terminal tile in a
project zone, and confirm the tile appears, accepts keystrokes, and runs commands exactly as
it did before. Any regression in tile spawn (a crash, a blank pane, an unresponsive shell)
means the admin session exchange or the `authorize` gate broke a code path that was
previously auth-free.

Concrete dogfood snippet: launch Continuum → open any existing project → open a terminal
tile → type `echo $TERM` and press Return → see `xterm-256color` (or the configured
terminal type) printed on the next line with no error. If the token exchange wiring broke
the session lifecycle, the pane will either fail to spawn (blank tile with no prompt) or
produce a permission error in the Xcode console. Pass = prompt appears and the echo
command completes normally.

## Execution mode

Autonomous. The logic checks are pure and deterministic, operating against in-memory GRDB
and a `FakeClock`. The real-path check writes to a temp directory and requires only
`SecRandomCopyBytes` (always available on macOS) and GRDB — no cloud account, no SSH host,
no running tmux server, no physical device. The UX gate is a simple functional check (tile
spawns and accepts input) that can be confirmed in a single app launch without a visual
comparison. The full truth of this ticket — that auth is enforced on every path and that
`.observer` cannot carry operate-level scope — is provable by the logic suite alone, making
it safe to run and ship autonomously.

## Done when

- [ ] `Sources/ContinuumRevivedCore/Auth/Scope.swift` exists with the five `OptionSet`
  cases (`orchestrationRead`, `orchestrationOperate`, `terminalOperate`, `accessRead`,
  `accessWrite`) and the `.observer` / `.admin` named bundles.
- [ ] `Scope` is `Codable` and its `rawValue` round-trips through JSON without loss.
- [ ] `Sources/ContinuumRevivedCore/Auth/BootstrapGrant.swift` exists; `BootstrapGrant.seed()`
  returns a new in-memory grant each call; the grant's credential is 64 hex characters from
  `SecRandomCopyBytes`.
- [ ] `Sources/ContinuumRevivedCore/Auth/PairingStore.swift` exists; `consume` is atomic
  (single UPDATE/RETURNING, not a read-then-write); all four error cases (`.unknown`,
  `.expired`, `.alreadyUsed`, `.revoked`) are reachable via distinct DB/memory states and
  are exercised by the logic checks.
- [ ] `Sources/ContinuumRevivedCore/Auth/SessionStore.swift` exists; `verify` uses
  `timingSafeEqual` for the HMAC comparison (not `==`); the signing key is loaded from or
  written to `~/Library/Application Support/Continuum/auth/signing.key` with `0600`
  permissions on first launch.
- [ ] `Sources/ContinuumRevivedCore/Auth/MessageScope.swift` exists; `requiredScope` has an
  entry for every case of `ControlMessage`; `authorize` calls `fatalError` (not a throw) for
  a missing entry.
- [ ] Exchange with `requested` scope that is not a subset of the grant ceiling throws
  `AuthError.scopeNotGranted` — tested in the logic suite.
- [ ] The bootstrap grant supports unbounded re-exchange — the second exchange returns a
  fresh session with the same scopes and no error.
- [ ] All five logic suites pass in `ContinuumRevivedCoreChecks` with no flakiness across
  three consecutive runs.
- [ ] The real-path check passes; the manifest records `token_length`, `scopes_rawValue`,
  `session_id`, `credential_length`, `exchange_ok`, `double_exchange_error`,
  `move_tile_denied`, `subscribe_activity_allowed` — no field is `{passed: true}`.
- [ ] The app builds cleanly; no existing check regresses; a terminal tile spawns and
  accepts keystrokes after the wiring is in place.
- [ ] No code path in `ContinuumRevivedCore` or the app layer contains an
  `if isLocalhost { skip }` or equivalent localhost bypass.

## Depends on / unblocks

This ticket depends on the injectable-substrates work being in place: `FakeClock` is used
in the `SessionStore` expiry checks, and the `Host` abstraction is the reach-path model
that auth sessions will eventually be checked against on each incoming connection. The
GRDB dependency must already be present in `Package.swift` — if it is not, add it as part
of this ticket (the `PairingStore` and `SessionStore` need it; do not defer it).

It directly unblocks the iOS observer work, which cannot ship the observer-only guarantee
without a `Scope.observer` type that is already in production. It also unblocks every
control-channel ticket — `sendKeys`, `moveTile`, `spawnTerminal`, `pairDevice` — each of
which must add an entry to the `requiredScope` table and call `authorize` before it can be
considered complete. The `wsTicket` short-lived query-token pattern (for WebSocket
upgrades that cannot carry an `Authorization` header) builds directly on `SessionStore`
and is a clean follow-on once this ticket is in place.

## Watch out for

**The hardest single thing to get right is the atomic single-use consume in `PairingStore`.**
A naive read-then-write implementation creates a race window where two concurrent exchange
requests both read the token as unconsumed and both succeed, granting two sessions from a
credential that was supposed to be single-use. The correct implementation is a single SQL
statement that writes `consumed_at` as part of the SELECT condition — if zero rows are
affected, the token was already consumed, expired, or revoked. This is not optional; it is
the property that makes pairing secure.

**Do not persist the bootstrap grant seed to disk.** It must be regenerated fresh on every
launch. Its value on disk would be equivalent to a permanent admin credential with no
revocation path, since it carries `.unbounded` uses. If the app needs to hand the seed to a
subprocess, pass it over `fd3` or stdin (as t3code does), never as a command-line argument
or environment variable visible to `ps`.

**The `timingSafeEqual` HMAC comparison is not negotiable.** A `==` comparison on HMAC
bytes leaks the number of correct prefix bytes via timing, which is enough to forge tokens
incrementally given enough requests. Use `CryptoKit`'s constant-time `HMAC.isValidAuthenticationCode`
or an equivalent that does not short-circuit on the first differing byte.

**Stop and investigate if the real-path check creates the signing key file but `stat` shows
permissions other than `0600`.** On macOS, `FileManager.createFile(atPath:contents:attributes:)`
does not reliably honor the `posixPermissions` attribute in all configurations; use
`open(path, O_WRONLY | O_CREAT | O_EXCL, 0600)` (or equivalent via `Foundation.FileManager`
with an explicit `chmod` call immediately after creation) and verify the permissions before
declaring the check passing.

**The `ControlMessage.requiredScope` table must be exhaustively switched at the call site,
not keyed by optional lookup.** If `requiredScope` is a `[ControlMessage: Scope]` dictionary,
add a compile-time exhaustiveness check (e.g. a `switch msg { case .X: … }` that the
compiler warns on if a new case is added without an entry). A missing entry that silently
falls through to `fatalError` at runtime is still better than a silent allow — but a
compile-time warning is better still.

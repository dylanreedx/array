# APNS push service — fire on interruptive/terminal phase entry, deduplicated by state identity

> **RULING BANNER — C-20260705-027 (night3 B6 = 63 push sender + N1–N8 payload builders,
> orchestrator 2026-07-05). Binding; overrides the ticket text below where they conflict. The
> companion spec (`_COMPANION_SPEC.md` §3–§4) supersedes the ticket's 4-category model with the
> N1–N8 taxonomy, and the night-3 amendment supersedes the Keychain story: key config lives at
> `~/.continuum/apns.env` (present tonight: `CONTINUUM_APNS_KEY_PATH` / `CONTINUUM_APNS_KEY_ID` /
> `CONTINUUM_APPLE_TEAM_ID`; note the path value uses `$HOME` — the loader must expand it). The
> `.p8` NEVER enters the repo, is never logged, never appears in a check's printed output.
> Verified code facts as of cb85f2e: `AgentStatus` has NO `.failed` case
> (`TerminalSessionDescriptor.swift:104`: configuring/working/idle/needsAttention/done/stale) —
> the ticket's firing rule is adjusted below; `AgentActivityEvent` already carries
> `tone`/`kind`/`status`/`approvalRequestId` (B5) and `runtimeError`'s message is `[BODY]`-tagged
> (`AgentStatusEngine.swift:343`) so it may NEVER enter a payload; ticket 40's `SessionObserver`
> is NOT built — the production status-transition call site does not exist yet; `PairingURL.scheme
> == "continuum"` (`Auth/PairingURL.swift:26`) is the app's registered scheme and deep links reuse
> it; `ios/Continuum/Resources/Continuum.entitlements` already has `aps-environment: development`;
> the iOS Settings tab is a B8 placeholder; `requiredScope[.respondToApproval] ==
> .orchestrationOperate` (B5's gate — the lock-screen Approve handler routes through it).**
>
> 1. **Scope of B6 (the queue line, not the full ticket):** desktop push SENDER + shared N1–N8
>    payload builders + firing/dedup rules + the morning `--push-test` hook + lab card. NOT tonight:
>    per-category Settings UI + persisted prefs (B8 owns ticket 65 — the sender consults an
>    injectable `PushCategoryPreferences` seam, default = taxonomy defaults); deep-link VALIDATION
>    (B7 owns 64 — B6 only constructs URLs); the simulator suite script (B9); the ticket's
>    `DeviceRegistration` CKRecord / token-over-wire channel (see item 6); Mac-Keychain key storage
>    and the paste-the-key Settings flow (VOID — superseded by apns.env).
> 2. **Taxonomy is shared Core (night-3 shared-code rule):** a closed `PushCategory` enum N1–N8
>    with, per case: a stable category identifier string (used identically by the payload builder
>    and the iOS `UNNotificationCategory` registration — single constant, never two literals),
>    interruption level (N1/N2/N7 time-sensitive, N3/N4 active, N5/N6/N8 passive), default-enabled
>    (N1–N5 on, N6/N8 off), muteable (all except N7 — N7 ALWAYS delivers, the preferences seam is
>    not consulted for it), action ids (N1: approve/deny; N2: open), and deep-link target (N1
>    approval card / N2–N4+N8 agent detail / N5 agents board / N6 status footer / N7 devices) using
>    scheme `PairingURL.scheme`. Builders are pure functions from typed context structs → an APNS
>    JSON payload (`aps.alert` title/body, `aps.category`, `aps["interruption-level"]`, sound,
>    `userInfo` with the deep link and — N1 only — the `approvalRequestId`; spec §3: the approve
>    action carries ONLY the approval id, decisions round-trip through the scope gate). Every
>    payload ≤4 KB, detail/body ≤160 chars, I5-clean.
> 3. **Firing rule (adjusted for the real AgentStatus — no `.failed` case):** entry-edge semantics
>    kept from the ticket. Interruptive/terminal set = {`.needsAttention`, `.done`}. Category
>    classification from the triggering `AgentActivityEvent`: `.needsAttention` entry WITH
>    `approvalRequestId` → N1; `.needsAttention` entry without → N2; `.done` entry with tone !=
>    `.error` → N3; an event with tone `.error` (e.g. kind `runtimeError` / dirty exit) → N4
>    regardless of status-set membership, with body = the FIXED string `"The agent run failed."`
>    (the `[BODY]`-tagged message never crosses; ticket's redaction rule kept). N5–N8 builders
>    exist and are table-checked, but their production triggers (digest timer, 66-supervisor
>    edges, pairing events, reaper) are NOT wired tonight — `publisher-owed`, same as the N1–N4
>    observer call site (ticket 40 not built; do NOT invent a SessionObserver). Dedup per the
>    ticket: identity = state minus timestamp, per-tile map, in-memory only (do not persist),
>    updated only after a 200; 410 → `tokenExpired`, identity NOT updated; 403
>    ExpiredProviderToken → identity NOT updated, fresh JWT next attempt.
> 4. **Sender (`APNSPushService` actor, Core, per the ticket):** config loaded from
>    `~/.continuum/apns.env` ($HOME-expanded; missing/incomplete file → nil config → publish
>    no-ops honestly — this IS the "behind the flag" behavior, no separate flag needed); JWT
>    minted fresh per POST via CryptoKit P256 (`pemRepresentation` of the .p8), never cached;
>    HTTP layer behind an injectable seam so checks exercise the REAL request construction
>    (URL `/3/device/<token>`, `authorization: bearer <jwt>`, `apns-topic:
>    dev.dylanreed.continuum`, `apns-push-type: alert`) without network; environment selectable
>    sandbox|production (the spec's T3 "sandbox" label is corrected here: TestFlight builds
>    register against PRODUCTION APNS — default production, overridable). Device token is
>    config-injected: an optional `CONTINUUM_APNS_DEVICE_TOKEN` line in apns.env (morning: Dylan
>    pastes the token the phone displays). No token → publish no-ops with an honest log line.
> 5. **iOS side (minimal, honest):** request notification authorization +
>    `registerForRemoteNotifications` at app start; register the `UNNotificationCategory` set from
>    the SAME shared taxonomy constants (N1 Approve/Deny with `.authenticationRequired`, N2 Open);
>    on token receipt show it as a copyable row (replace the Settings-tab placeholder body with
>    this one diagnostics row — B8 still owns real Settings; keep the placeholder hint text for
>    the rest). The lock-screen Approve/Deny handler routes through a pure Core helper
>    `handlePushAction(actionId:userInfo:grantedScope:)` that returns a respond-intent ONLY when
>    `authorize(.respondToApproval, …)` passes (spec §4 T1's "scope-gate round-trip against the
>    real authorize() path"), then feeds B5's existing approvalResponse wire path. Token
>    delivery phone→desktop over the wire is NOT built tonight (desktop CK inbound pump is the
>    known publisher-owed gap) — `device-gate-owed` + `publisher-owed`.
> 6. **Morning T3 hook:** a `--push-test` flag on the desktop app that builds one fixture payload
>    per category N1–N8 and fires each through the REAL sender/apns.env/token path, printing the
>    per-category HTTP outcome (or the honest "no device token configured" failure, exit
>    non-zero). NOT wired into the matrix (it goes live against Apple); it is the T3 checklist
>    tool.
> 7. **Checks (matrix-wired, measured values, no `{passed:true}`):** Core tables — (a) payload
>    builder over ALL 8 categories: JSON decodes, category id + interruption level + deep-link
>    userInfo + action ids asserted per case, ≤4 KB, 160-char truncation, N4 fixed-string
>    redaction (feed a hostile `runtimeError` message; assert it does NOT appear anywhere in the
>    encoded payload); run the built payloads through `SyncPayloadTaintScanner` where its API
>    applies; (b) firing-rule table: working→needsAttention(approval id)→N1, →needsAttention(no
>    id)→N2, →done→N3, error-tone→N4, needsAttention→needsAttention same identity no-fire,
>    approval→input refire (identity differs), done→done no-refire; (c) taxonomy invariants:
>    ids unique + non-empty, defaults per spec §3, N7 unmuteable (preferences seam returning
>    false for N7 still sends); (d) JWT signer: ephemeral P256 key, decode header/claims (alg
>    ES256, kid, iss, iat within ±5 s), verify with the public key; (e) dedup/HTTP via the fake
>    seam: identical identity → exactly one request; changed identity → second request; 410 and
>    403 semantics per item 3; request-shape assertions per item 4; (f) apns.env loader: parse a
>    FIXTURE env string (not the real file) incl. $HOME expansion; missing keys → nil config →
>    no-op publish. Plus one gated real-env check: if `~/.continuum/apns.env` exists, load it,
>    assert the real key parses and a JWT signs+verifies — print ONLY the key id/team id, never
>    key material; absent file → print SKIPPED, exit 0.
> 8. **ComponentLab (Dylan's directive — this is a Track-B desktop companion):** a "Push Smoke"
>    lab card rendering all 8 fixture payloads (category, level, title/body, deep link, action
>    ids) plus a firing/dedup outcome line (fire → dedup-suppressed → refire on phase change),
>    with its `--component-lab-check` assertion extended to gate the card (8 rows, N1 shows
>    approve/deny action ids), SAME commit. Patterns: tickets 14/67, B3/B5 cards.
> 9. **Gates:** (a) `swift build` clean; (b) `CONTINUUM_SKIP_SURFACE_CHECKS=1
>    ./scripts/run-matrix.sh` green incl. every new check; (c) `cd ios && xcodegen generate &&
>    xcodebuild -project Continuum.xcodeproj -scheme Continuum -destination 'generic/platform=iOS
>    Simulator' build` clean (`ios/project.yml` + entitlements stay source of truth). Ledger owed
>    tags: `device-gate-owed` (real push to the phone, token paste, lock-screen actions end to
>    end), `publisher-owed` (observer call site 40, N5–N8 triggers, token-over-wire),
>    `visual-gate-owed` (lab card + banner screenshots via B9's simulator suite).

> **RULING BANNER — C-20260705-027 rev.2 (continuation adjudication, orchestrator 2026-07-05
> ~20:30). Run wf_efe8c218-336: round 1 green build + dual rejection; round 2 fixed all 5
> concerns, Claude/Opus reviewer CLEARED, Codex rejected with 4 new concerns; round 3 died on
> the Codex usage limit (reset 20:33) with the tree untouched. The implementation is ALIVE in
> the working tree (uncommitted). All 4 Codex concerns are adjudicated REAL and in-contract;
> one codex-high continuation fixes them, then a FRESH dual review (both reviewers re-run —
> round 2's Claude clear does not carry over). Binding fixes:**
>
> 1. **Identity/payload category desync (APNSPushService.swift:517-539):** the preference and
>    dedup gates key on `identity.category` while the wire carries `payload.category`, and
>    `publish(payload:identity:)` is public — a caller can pass an N7 identity with a muteable
>    payload and bypass the preferences seam. Close the seam at the type level: the service must
>    derive the gating category from the PAYLOAD (single source of truth) — either compute the
>    identity internally from the payload or make the public entry point take the payload alone;
>    a mismatched public (payload, identity) pair must be unrepresentable, not merely unused by
>    fixtures. Add a check proving the gate keys off the payload's category.
> 2. **iOS category registration (ios ContinuumApp.swift:74-81):** register ALL EIGHT
>    `UNNotificationCategory` ids from the shared taxonomy constants — N1 Approve/Deny
>    (`.authenticationRequired`), N2 Open, N3–N8 with empty action sets (rev.1 item 5 named only
>    N1/N2; rev.2 binds the full set — one loop over `PushCategory.allCases`, zero literals).
> 3. **Time-sensitive entitlement:** add `com.apple.developer.usernotifications.time-sensitive`
>    (bool true) to `ios/Continuum/Resources/Continuum.entitlements` — requesting
>    `.timeSensitive` authorization without it does not provision time-sensitive delivery.
>    `project.yml` stays source of truth; regenerate. Real delivery behavior remains
>    `device-gate-owed`.
> 4. **Check honesty (APNSPushServiceTests.swift):** (a) the payload table must assert category
>    id / interruption level / action ids against an INDEPENDENT literal spec map (the spec §3
>    table transcribed as literals in the check), not against `PushCategory`'s own computed
>    properties — as written it is tautological; (b) add a muteable-category suppression case: a
>    false-returning preferences seam suppresses N3 (and the N7 locked-on case stays); (c) assert
>    the deny action id on N1; (d) `runRealAPNSEnvJWTGateCheck` must VERIFY the real-key JWT
>    signature against the key's public key (ruling item 7: "signs+verifies"), not just count
>    three segments — still printing only key id/team id.
> 5. **Gates unchanged (rev.1 item 9).** Continuation is one codex-high fix round + fresh dual
>    review; commit only on green + both clear.

## What this delivers

When an agent managed by Continuum enters a phase that demands the human's attention —
a pending approval, a user-input request, a completed run, or a failed run — the Mac
fires a single, metadata-only APNS push to the registered iOS device. The push arrives
within seconds of the phase transition, carries enough context to identify the tile and
the nature of the interrupt (headline + sanitized detail, ≤160 chars), and deep-links
directly to the agent detail screen. Duplicate fires on the same logical state are
suppressed: if the observer ticks and the state has not meaningfully changed, no second
push is sent. The user can toggle each of the four notification categories independently
(approval / input / completion / failure) through a Settings entry, and those preferences
are persisted.

From the user's perspective: their iPhone buzzes when an agent needs them, nowhere else,
never twice for the same event. They tap, land on the right agent, and either approve or
note that the run finished.

## How it fits

This ticket builds directly on two prior pieces of work and is not buildable without
them.

The `SessionObserver` (the session-observer ticket, ticket 40) is the component that
already watches every live tile and writes a resolved `AgentStatus` into
`AgentDescriptor.status`. The push service is not a second observer — it is a
**downstream consumer** of the observer's status transitions. It listens for the moment
the observer emits a status that is interruptive (`needsAttention`) or terminal (`done`,
`failed`), and acts on that edge.

The `Scope` OptionSet model (settled in decision D6) provides the type-level guarantee
that an iOS-scoped pairing session can receive the push payload but cannot issue
write-back commands unless explicitly granted an approval scope. The push service does
not itself enforce scopes, but the device token registration that feeds it is
scope-gated: an `.observe`-scoped device is registered; an `.observe` device that
later gains approval scope can respond.

What this ticket unblocks is the full "needs you" loop on iOS: once the push fires and
the deep link lands correctly, ticket 64 (the iOS observer agent-detail screen) has a
real trigger to render against, and the approval-response path (managed agents, symmetric
`respondToApproval`) has an entry point from the phone.

## The approach

The push service is a small, focused actor in `ContinuumRevivedCore` — `APNSPushService`
— that owns three responsibilities:

1. **JWT signing.** It holds a reference to the `.p8` ES256 private key loaded from the
   Mac's keychain (stored there at first-run setup, never in a file on disk). On each
   publish call it mints a fresh 5-minute JWT (`iss` = Team ID, `kid` = Key ID, `iat` =
   now) following the APNS token-based connection spec. The key is loaded once at
   actor-init and reused across calls; the JWT is generated fresh per POST because APNS
   requires `iat` to be within ±1 hour of the server's clock and a stale JWT causes a
   silent rejection.

2. **HTTP/2 POST to APNS.** The service uses `URLSession` configured with HTTP/2
   (`httpShouldUsePipelining false`, but the session's `http2Enabled` semantics from
   Foundation ensure multiplexing). It targets `api.push.apple.com` for production or
   `api.sandbox.push.apple.com` for the debug build. Each POST carries the push token
   registered by the iOS companion, the `apns-topic` header set to the app's bundle ID,
   `apns-push-type: alert`, and a ≤4 KB JSON body. The response is checked for a 200; on
   a 410 the device token is considered stale and must be cleared.

3. **Deduplication by state identity.** The service keeps a `lastPublishedIdentity:
   AgentAwarenessIdentity?` per tile. Before sending, it computes the identity of the
   candidate state (the full `AgentAwarenessState` struct minus `updatedAt` — mirroring
   the t3code `agentAwarenessPublishIdentity` pattern from
   `AgentAwarenessRelay.ts:89`/`:382`) and compares it to the stored identity. If equal,
   it skips the POST entirely. It updates the stored identity only after a successful 200.

The service is **not** the entity that watches for status changes. That responsibility
belongs to the observer. The observer's owner (`ZoneRuntimeController`) calls a thin
`AgentPushService` protocol — `func publish(_ state: AgentAwarenessState) async` — when
a status transition crosses the interruptive/terminal threshold. The push service is
simply the live implementation of that protocol; tests use a `FakeAgentPushService` that
records calls.

The firing rule is precise: fire on **entry** into a phase that is either interruptive
(`needsAttention`, which covers both approval-waiting and input-waiting managed agents)
or terminal (`done`, `failed`). "Entry" means the previous status was not already in
that set. Transitioning from `needsAttention` (approval pending) to `needsAttention`
(now input-waiting) is a meaningful change because the identity differs; the dedup
logic handles this correctly because the `phase` field is part of the identity.

The payload is **metadata only** per invariant I5. No transcript body, no tool-call
content, no command arguments are included. The `detail` field is capped at 160
characters and, when the phase is `failed`, its content is replaced with the fixed
string `"The agent run failed."` before it leaves the host — matching the redaction
in `sanitizeRelayAgentActivityState` (`06-agent-ux-approvals-mobile-push.md`,
`relay.ts:112`).

The four notify-category preferences (`notifyOnApproval`, `notifyOnInput`,
`notifyOnCompletion`, `notifyOnFailure`) are persisted in `UserDefaults` with a
Settings UI entry, all defaulting to `true`. The service checks the relevant preference
before firing.

## Where it lives

**New file: `Sources/ContinuumRevivedCore/APNSPushService.swift`**

This file contains:
- `AgentAwarenessState` — the metadata-only push payload struct (`tileId: UUID`,
  `projectTitle: String`, `tileTitle: String`, `phase: AgentPhase`, `headline: String`,
  `detail: String?` (≤160 chars, redacted on failure), `deepLink: String`,
  `updatedAt: Date`).
- `AgentPhase` — a six-case enum: `needsAttention`, `done`, `failed`, `working`,
  `idle`, `configuring`. Maps 1:1 onto `AgentStatus` for the cases relevant to push
  (`AgentStatus` is defined at
  `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:85`).
- `AgentAwarenessIdentity` — `AgentAwarenessState` minus `updatedAt`, `Hashable` and
  `Equatable`; the dedup key.
- `AgentPushService` — a `protocol` with a single `async` method:
  `func publish(_ state: AgentAwarenessState) async throws`.
- `APNSPushService: AgentPushService, Actor` — the live implementation described above.
- `APNSPushConfiguration` — `struct` carrying `keyId: String`, `teamId: String`,
  `bundleId: String`, `deviceToken: String`, `useSandbox: Bool`.
- `APNSJWTSigner` — a small struct that holds the `P256.Signing.PrivateKey` and
  produces a signed JWT string, with no mutable state.

**Modified: `Sources/ContinuumRevivedCore/AgentStatusEngine.swift`**

The engine (`Sources/ContinuumRevivedCore/AgentStatusEngine.swift:3`) is not changed
in structure. The `SessionObserver` (already watching `AgentDescriptor.status`) gains
a call site that, after writing a new `AgentStatus`, checks whether that status
represents an interruptive/terminal entry and, if so, builds an `AgentAwarenessState`
and calls `pushService.publish(state)`. That call site lives in the observer, not the
engine; the engine itself is untouched.

**Modified: `Sources/ContinuumRevivedCore/AgentStatusEngine.swift` — status enum** (no
change; `AgentStatus` at line 85 of
`Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift` already has
`.needsAttention`, `.done`, and other needed cases).

## Implementation breadcrumbs

```swift
// ── AgentAwarenessState (I5-clean; no runtime refs, no transcript) ──────────
struct AgentAwarenessState: Codable, Equatable, Sendable {
    let tileId: UUID
    let projectTitle: String
    let tileTitle: String
    let phase: AgentPhase           // .needsAttention | .done | .failed | …
    let headline: String            // "Approval needed" | "Agent finished" | …
    var detail: String?             // ≤160 chars; nil or "The agent run failed." for .failed
    let deepLink: String            // "continuum://agent/<tileId>"
    let updatedAt: Date
}

// Dedup key: everything that makes one push semantically different from the last.
// updatedAt is NOT included — a re-tick with the same state must not re-fire.
struct AgentAwarenessIdentity: Hashable {
    let tileId: UUID
    let phase: AgentPhase
    let headline: String
    let detail: String?
    let deepLink: String
}
extension AgentAwarenessState {
    var identity: AgentAwarenessIdentity {
        AgentAwarenessIdentity(tileId: tileId, phase: phase,
                               headline: headline, detail: detail, deepLink: deepLink)
    }
    // Sanitize before publish: cap detail, redact failure bodies.
    func sanitized() -> AgentAwarenessState {
        var s = self
        if phase == .failed { s.detail = "The agent run failed." }
        else if let d = s.detail, d.count > 160 { s.detail = String(d.prefix(160)) }
        return s
    }
}

// ── Firing rule (lives in ZoneRuntimeController / SessionObserver ─────────────
// Call after the observer writes a new AgentDescriptor.status:
func maybeFirePush(tileId: UUID, previousStatus: AgentStatus, newStatus: AgentStatus,
                   tile: TileContext) async {
    // Only fire on ENTRY: previous was NOT in the interruptive/terminal set.
    let interruptiveOrTerminal: Set<AgentStatus> = [.needsAttention, .done, .failed]
    guard interruptiveOrTerminal.contains(newStatus),
          !interruptiveOrTerminal.contains(previousStatus) else { return }
    guard notifyPreference(for: newStatus) else { return }   // per-category toggle
    let state = AgentAwarenessState(
        tileId: tileId,
        projectTitle: tile.projectTitle,
        tileTitle: tile.title,
        phase: AgentPhase(newStatus),
        headline: headline(for: newStatus),
        detail: tile.agentDetail,
        deepLink: "continuum://agent/\(tileId.uuidString)",
        updatedAt: Date()
    ).sanitized()
    try? await pushService.publish(state)
}

// ── APNSPushService (actor) ───────────────────────────────────────────────────
actor APNSPushService: AgentPushService {
    private let config: APNSPushConfiguration
    private let signer: APNSJWTSigner
    private var lastPublishedIdentity: [UUID: AgentAwarenessIdentity] = [:]
    private let session: URLSession   // configured for HTTP/2

    func publish(_ state: AgentAwarenessState) async throws {
        let identity = state.identity
        if lastPublishedIdentity[state.tileId] == identity { return }   // dedup

        let jwt = try signer.sign(keyId: config.keyId, teamId: config.teamId)
        let payload = APNSPayload(aps: .init(alert: .init(title: state.headline,
                                                           body: state.detail),
                                              sound: "default"))
        let host = config.useSandbox
            ? "api.sandbox.push.apple.com" : "api.push.apple.com"
        var req = URLRequest(url: URL(string:
            "https://\(host)/3/device/\(config.deviceToken)")!)
        req.httpMethod = "POST"
        req.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        req.setValue(config.bundleId, forHTTPHeaderField: "apns-topic")
        req.setValue("alert", forHTTPHeaderField: "apns-push-type")
        req.httpBody = try JSONEncoder().encode(payload)

        let (_, response) = try await session.data(for: req)
        let status = (response as! HTTPURLResponse).statusCode
        if status == 200 {
            lastPublishedIdentity[state.tileId] = identity
        } else if status == 410 {
            // Device token expired — caller should clear stored token.
            throw APNSError.tokenExpired
        } else {
            throw APNSError.httpStatus(status)
        }
    }
}

// ── JWT signing (stateless struct, CryptoKit P256) ───────────────────────────
struct APNSJWTSigner {
    let privateKey: P256.Signing.PrivateKey

    func sign(keyId: String, teamId: String) throws -> String {
        let header = base64url(json: ["alg": "ES256", "kid": keyId])
        let iat    = Int(Date().timeIntervalSince1970)
        let claims = base64url(json: ["iss": teamId, "iat": iat])
        let signingInput = "\(header).\(claims)".data(using: .utf8)!
        let signature = try privateKey.signature(for: signingInput)
        return "\(header).\(claims).\(base64url(signature.rawRepresentation))"
    }
}
```

The `.p8` key is loaded exactly once at app launch (or at first push-service init)
from the Mac Keychain, stored under a stable service/account label, and handed to
`APNSJWTSigner` as a `P256.Signing.PrivateKey`. It is never written to disk, never
included in the binary, never logged. If the keychain item is absent, the service
initializes with `config = nil` and silently no-ops all `publish` calls until the user
completes setup in Settings.

The device token for the iOS companion reaches the Mac through the same synced
CloudKit private-DB channel that carries the op-log (a second `CKRecord` type,
`DeviceRegistration`, keyed by `deviceId`; written by the iOS app on token receipt,
read by the Mac on push service init). This means no separate endpoint, no pairing
token exchange at this phase — CloudKit identity is sufficient for one person's own
devices (decision D6).

## How we test it

### Logic (pure Core checks)

- Table-driven test over `maybeFirePush`: assert it calls `publish` exactly once when
  transitioning `working → needsAttention`, `working → done`, `working → failed`;
  assert it is a no-op when transitioning `needsAttention → needsAttention` with the
  same identity; assert it fires again when transitioning `needsAttention` (approval) →
  `needsAttention` (input) because the identity differs (the `phase` is the same but the
  `headline` differs).

- Table-driven test over `AgentAwarenessState.sanitized()`: verify that a `failed` state
  has its `detail` replaced with `"The agent run failed."` regardless of the original;
  verify that a detail of 180 chars is truncated to exactly 160; verify that a nil detail
  stays nil on non-failure phases.

- Test over `APNSJWTSigner.sign`: parse the produced JWT string; decode the header
  (`base64url`) and assert `alg == "ES256"` and `kid == testKeyId`; decode the claims
  and assert `iss == testTeamId` and `iat` is within 5 seconds of `Date()`. Verify with
  `P256.Signing.PublicKey.isValidSignature`.

- Test over `APNSPushService` dedup: build a `FakeHTTPSession` that returns 200; call
  `publish` twice with the same `AgentAwarenessState` (different `updatedAt`, same
  identity); assert exactly one HTTP request was recorded. Then call with a state whose
  phase differs; assert a second request fires.

- Test over `APNSPushService` on 410 response: assert `APNSError.tokenExpired` is
  thrown and the stored identity is NOT updated (so a retry with a new token will fire).

- Test over notify-category preference gate: set `notifyOnCompletion = false`; fire a
  `done` transition; assert `FakeAgentPushService.publishCalls.isEmpty`.

### Backend (real-path integration, not bypassed)

The full APNS pipeline requires a real Apple Developer account, a provisioned `.p8` key,
and a physical iOS device — which is why this ticket is tagged `needs-substrate`. The
integration real-path check that can run in CI short of that: wire `APNSPushService` to
a local `http4` or `vapor-test` mock server that accepts the POST and asserts the
request shape — correct `apns-topic` header, correct `authorization: bearer <jwt>`
header, body decodes to a valid `APNSPayload` with a non-empty `aps.alert.title`. Run
this against a generated test `.p8` key (not the real one), confirming the HTTP/2
client produces the expected request with no real-network dependency.

For the real-device path: load the `.p8` from the test keychain entry, hard-code the
sandbox push URL, and fire a push to the registered sandbox device token. Observe the
notification arrive on the device. This is a manual gate run at least once before merge
and is documented in the runbook.

Verify also that the `DeviceRegistration` CKRecord written by the iOS companion is
readable by the Mac's push service: a local CloudKit integration test (using the
iCloud test container, a real signed-in iCloud account) writes the record from an iOS
simulator and asserts the Mac-side reader sees the token within 10 seconds.

### UX (visual gate + dogfood snippet)

Visual gate: in the Component Lab (`ContinuumApp` settings → Component Lab), add a
"Push Smoke" entry that lets the developer inject a synthetic `needsAttention` status
change into a mock tile without running a real agent. The tile in the sandbox should
immediately show an orange border and a `needs you` label in the dock. Confirming that
`APNSPushService.publish` was called (via a `FakeAgentPushService` shim in debug builds
that logs to `os_log`) is the non-degenerate gate — not `bytes > 0` but a log line
reading `[APNSPush] published: <tileId> phase=needsAttention`.

Dogfood snippet: open the app on the Mac with the iOS companion running on a real device
(sandbox build, real Apple ID). Spawn a managed agent tile and, via the Component Lab
debug injection, transition it to `needsAttention`. Within 5 seconds the iOS device
should display a notification banner reading **"Approval needed"** with the tile title
as the subtitle. Tap the banner — the iOS app opens and navigates directly to the agent
detail screen for that tile (the route is `continuum://agent/<tileId>`). A second
injection with the same state fires no second notification. A third injection that
changes the phase to `done` fires a fresh banner reading **"Agent finished"**.

## Execution mode

**needs-substrate.** The JWT signing and request-shape checks run in pure CI against a
fake HTTP server. But proving that APNS actually delivers a notification to a real iOS
device requires a provisioned Apple Developer account (the `.p8` key), the APNS sandbox
endpoint, and a physical device with the Continuum iOS companion installed. The
CloudKit round-trip for device-token delivery also requires a signed-in iCloud account
and access to the private database container. These cannot be faked or mocked into a
passing signal — they require the real substrate. The logic and dedup checks are fully
automatable; the end-to-end push and token delivery steps are run manually by the
implementer and documented in the runbook.

## Done when

- [ ] `APNSPushService` actor compiles and its unit tests pass in CI (JWT signing, dedup
  table, sanitization table, 200/410 response handling, notify-category gate).
- [ ] Mock-server integration test passes: the HTTP/2 POST to the local mock server
  carries the correct `apns-topic`, `authorization: bearer …`, `apns-push-type: alert`
  headers, and a decodable `APNSPayload` with a non-empty `aps.alert.title`.
- [ ] Deep-link format is `continuum://agent/<tileId>` (validated by a regex test on the
  constructed URL).
- [ ] `sanitized()` truncates detail to 160 chars and replaces failure detail with the
  fixed string, verified by the logic table.
- [ ] Dedup: two successive `publish` calls with identical identity produce exactly one
  HTTP request, verified by the fake-session test.
- [ ] Notify-category preferences are persisted in `UserDefaults` with four keys and a
  Settings UI entry; toggling `notifyOnCompletion = false` suppresses a `done`
  transition, verified by the unit test.
- [ ] On a real device (sandbox, manual gate): a synthetic `needsAttention` transition
  produces a notification banner within 5 seconds of the transition; tapping navigates
  to the correct agent screen.
- [ ] A repeated identical transition fires no second notification on the device.
- [ ] The `.p8` key is stored in the Mac Keychain, never written to disk or logged;
  confirmed by a grep of the codebase for the key's expected Base64 prefix.
- [ ] A `410` response from APNS is surfaced as `APNSError.tokenExpired` and logged at
  warning level without crashing.

## Depends on / unblocks

This ticket requires the `SessionObserver` (the session-observer work) to be complete
and actively writing `AgentDescriptor.status` — the push service has no independent
way to detect status transitions, it is downstream of the observer. It also requires
the `Scope` OptionSet (the identity and auth decisions, D6) to exist so that device
registration is typed correctly, though it does not need the full pairing-token
machinery — CloudKit device-token delivery is sufficient at this phase.

The pure status-derivation function work (the `deriveAgentStatus` ticket) must be in
place so that `needsAttention` is a clean signal with a proven priority ordering, not
a heuristic that might fire spuriously. A spurious `needsAttention` that fires a push
destroys trust faster than silence does.

What this ticket unblocks: the iOS observer's agent-detail screen (the ticket that
builds the screen the deep link lands on) has a real entry point. The approval-response
path from the phone (the symmetric `respondToApproval` flow) has a trigger that
actually reaches the user. Completing this ticket closes the last gap between the
desktop observer and the "your agent needs you" experience on iOS.

## Watch out for

**JWT clock skew is the most common silent failure.** APNS requires the `iat` claim
to be within ±1 hour of Apple's clock. A Mac with a drifted clock or a suspended
laptop can produce a stale JWT that APNS rejects with a `403 ExpiredProviderToken`.
The service must mint a new JWT per request (never cache the signed string), and if a
`403` with reason `ExpiredProviderToken` is returned it should log at error level and
**not** update the stored identity — so the next tick attempts again with a fresh JWT.

**A `410 Gone` device token must be cleared immediately.** APNS returns 410 when the
user has uninstalled the iOS app or revoked notification permissions. If the service
keeps sending to a dead token, APNS eventually rate-limits the entire `.p8` key. On
a 410, throw `APNSError.tokenExpired`, clear the stored device token from the CloudKit
`DeviceRegistration` record, and silence further push attempts until a new token arrives.

**Dedup state is in-memory and does not survive restarts.** On app relaunch, the
`lastPublishedIdentity` map is empty, so the next tick after a restart will fire a
push even if the same phase was already notified before the quit. This is intentional
and correct — a relaunch is a meaningful discontinuity, and the user may have acted on
a prior notification they never saw. Do not persist the dedup state.

**The `.p8` key is a single credential covering all apps under the account.** If it is
compromised, every app under the Team ID can have push spoofed against it. It must live
exclusively in the Mac Keychain (Keychain Access service `com.continuum.apns`,
accessible only by the Continuum app's codesign identity). Never log the key, never
include it in crash reports, never write it to a file. The setup flow that prompts the
user to paste or import the `.p8` must zero the in-memory buffer immediately after
loading the key into `P256.Signing.PrivateKey` and saving to Keychain.

**Do not attempt to deliver push from the iOS companion itself.** The push sender must
be the Mac (or the VPS for remote agents), because the Mac is the entity that detects
status transitions authoritatively. The iOS app is an observer; its only write-back is
`respondToApproval`, not a push publisher.

**HTTP/2 is required, not optional.** The APNS HTTP/2 endpoint rejects HTTP/1.1
connections. Verify that `URLSession` is configured with a `URLSessionConfiguration`
that allows HTTP/2 (`httpShouldUsePipelining` has no effect; Apple's `URLSession` on
macOS will negotiate HTTP/2 automatically over TLS to `api.push.apple.com`, but confirm
this with a local proxy trace before declaring the integration test complete).

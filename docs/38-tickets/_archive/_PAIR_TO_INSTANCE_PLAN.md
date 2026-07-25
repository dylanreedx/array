# Pair-to-instance companion refactor plan

Status: **planning / queue amendment, 2026-07-06.** This is a design note for the next companion refactor wave. It is intentionally MVP-shaped: personal/local, Dylan-only, observable, and explicit — not a SaaS auth system.

## Product stance

The phone pairs to **a Continuum instance**, not to iCloud.

Think of the system as:

```text
Continuum Mac instance = owner / source of truth / authority
Phone app              = paired device replica
CloudKit               = optional mailbox/cache/transport
Pairing                = device enrollment, not account login
```

For MVP, the trust model can be simple:

- physical access to the Mac + short-lived QR/token is enough to enroll a phone;
- one local owner user is generated automatically;
- no passwords, OAuth, hosted accounts, orgs, teams, or complex role UI;
- sessions are long-lived until revoked;
- scopes still matter because “observe status” and “operate/approve/move things” are different risks.

CloudKit may remain useful for same-iCloud dogfood, but it must not be identity, ownership, scope, or source of truth.

## Current repo facts

Already present:

- `PairingStore`, `PairingURL`, `SessionStore`, `AuthDatabase`, `Scope`, and scope authorization checks.
- Ticket 60 delivered one-time pairing token mechanics, downscoping, GRDB-backed exchange races, URL fragment handling, and the debug menu token issuer.
- Ticket 57 delivered `CloudKitSyncTransport` as a transport seam implementation.
- Tickets 61a/61b/62 delivered the iOS board/canvas/approval surfaces and CloudKit receiver/sender paths, but they still rely on static/debug scope patterns and publisher/inbound-pump follow-ups.
- Ticket 75 currently frames the missing bridge as “same iCloud account should make the phone work.” That is product-useful for transport, but incomplete as auth.

Still missing:

- desktop-owned persistent companion auth service;
- stable Continuum `instanceId`;
- local owner/device/session records that the app uses in production;
- iOS Keychain-backed paired-session state;
- first-run “pair this phone to this Continuum instance” UX;
- an explicit freshness/offline model for “Mac asleep / canvas stale / showing cached state.”

## MVP target architecture

```text
Desktop Continuum instance
  Auth DB
    instance     stable instanceId + display name
    owner        one generated local user for now
    devices      paired phones/clients + label + scopes + revokedAt
    sessions     signed bearer sessions + expiry/revocation
    pairing      short-lived one-time credentials

  Companion API / local exchange
    POST /pair/exchange      later QR/deep-link exchange
    GET  /instance           instance metadata + freshness capability
    later: /events/stream, /approvals, /canvas/ops

  Sync/transport adapters
    CloudKit adapter         mailbox/snapshot transport for dogfood
    local API / SSE          future explicit foreground realtime path
    APNs                    background notification path only

Phone
  Pairing state
    unpaired → exchanging → paired(session) → revoked/expired
  Reachability/freshness state
    syncing → live → stale → desktopSleeping? → offline
  Keychain
    session token, device id, paired instance id, optional device key
  UI
    capabilities = session.scopes
    freshness = heartbeat/snapshot timestamps
```

The key separation: **pairing state is not connection state**. A phone can be paired but currently stale because the Mac is asleep, offline, or CloudKit is delayed.

## Pairing flow, MVP version

Desktop:

1. Settings/Debug → **Pair phone**.
2. Issue one-time credential, TTL 5–10 minutes.
3. Render QR/deep link and copyable code.
4. After exchange, show paired device label, scope, last seen, revoke.

Phone:

1. First launch shows **Pair this phone to your Continuum instance**.
2. Scan/open `continuum://pair#token=...&instance=...&base=...`.
3. Exchange token with the Mac/local endpoint.
4. Store returned session in Keychain.
5. Enter paired state and start chosen transport.

For MVP, local HTTP with clear “dev/personal only” diagnostics is acceptable if HTTPS/pinning is too much. The architecture should leave room for pinned HTTPS later, but do not let certificate work block the first personal pairing loop.

## Users/auth model

Start with devices, not accounts:

- `ContinuumInstance`: stable id, display name, createdAt.
- `ContinuumUser`: one local owner id, generated at first launch.
- `ContinuumDevice`: id, owner id, label, granted scopes, createdAt, lastSeenAt, revokedAt.
- `CompanionSession`: token/signature claims bound to instanceId, userId, deviceId, scopes, issuedAt, expiresAt, revokedAt.

Default grant: observer. Operator/admin remains explicit from desktop.

## Offline / “canvas asleep” design

Offline will happen constantly: Mac lid closed, app quit, network down, iCloud delayed, phone foregrounded after hours. The phone should feel honest, not broken.

Product language:

- Prefer **“Mac asleep/offline — showing last canvas from 8:14”** when inferred.
- Use **“Canvas asleep”** only as friendly surface copy for the cached canvas mode, not as a security/protocol truth.
- Diagnostics should say exactly what is known: last heartbeat, last spatial snapshot, last activity snapshot, last fetch, last error.

Important rule: the phone usually cannot know the Mac is asleep in real time. It can know either:

1. the desktop explicitly published a best-effort `willSleep`/`goingOffline` hint before sleep/quit; or
2. heartbeats/snapshots stopped and the last data is now old.

So the freshness state should be derived, not guessed.

### Freshness envelope

Every desktop-published companion snapshot/event should carry enough metadata for the phone to decide what it is seeing:

```text
instanceId
publisherId / desktop replica id
bootId or launchId
sequence / watermarks
publishedAt
lastDesktopHeartbeatAt
powerHint: active | willSleep | waking | shuttingDown | unknown
spatialWatermark
activityWatermark
```

The phone records its own `receivedAt` too. UI age is based on both desktop `publishedAt` and local `receivedAt` so we can diagnose CloudKit delivery lag separately from desktop silence.

### State machine

Suggested MVP thresholds:

- `syncing`: paired, transport starting, no initial snapshot yet.
- `live`: heartbeat or snapshot received recently, e.g. < 90 seconds.
- `stale`: cached state exists, but no recent heartbeat/snapshot, e.g. 90 seconds–5 minutes.
- `desktopSleeping`: last explicit hint was `willSleep` / `shuttingDown`, or stale beyond threshold with no errors.
- `offline`: transport/account/network unavailable, session invalid, or no heartbeat for a longer window.

Exact thresholds should be constants in a pure model so they can be tuned without rewiring UI.

### UI behavior

When stale/offline:

- Never blank the canvas if cached data exists.
- Dim/label the canvas: `Showing last canvas · 8:14 AM`.
- Hollow/pause agent status dots; timers switch to `as of` time.
- Disable mutating actions for MVP: canvas edits, approve/deny, terminal operations.
- Do **not** queue approvals or canvas mutations offline in v1; stale approvals are dangerous.
- Pull-to-refresh/manual fetch is allowed and should explain the result.
- If there is no cached data, show `Waiting for your Mac` / `No canvas synced yet`, not a fake empty workspace.

Desktop should publish best-effort lifecycle hints:

- periodic heartbeat while companion sync is enabled;
- `willSleep` on `NSWorkspace.willSleepNotification`;
- `waking` / fresh snapshot on wake;
- `shuttingDown` on app termination when possible.

But the phone must remain correct if those hints never arrive.

## Transport stance

MVP reads/mirror can continue through CloudKit after pairing. Mutations should be more conservative:

- preferred MVP: phone actions use local API with the session token when the Mac is reachable;
- acceptable interim: CloudKit sends fail honestly until authenticated command envelopes exist;
- avoid bearer tokens in CloudKit records;
- if phone-originated CloudKit commands are needed, add signed device envelopes in a later ticket.

## Queue impact

Recommended order now:

1. `79-pair-to-instance-auth-boundary.md` — persistent instance/device/session boundary.
2. `80-companion-offline-freshness.md` — shared freshness/offline model and cached-state UX contract.
3. Pairing exchange + QR/scanner UI — supervised/local-network UX ticket after 79.
4. Rewrite `75-desktop-companion-sync-publisher.md` around paired-device transport and freshness metadata.
5. Resume `76` and `77` dogfood/polish after 75 is updated.

Tickets 75–77 should not be run as originally written without reading this amendment.

## Open questions with MVP defaults

1. **How secure does local exchange need to be?**
   - MVP default: physical QR + short TTL + local personal network is enough. Add pinning later.
2. **How long should sessions live?**
   - MVP default: long-lived, e.g. 90 days or until revoked.
3. **Can observer approve?**
   - MVP default: no. Existing `respondToApproval` requires operator scope; keep it.
4. **Should offline mutations queue?**
   - MVP default: no. Read stale state, disable actions, refresh/retry when live.
5. **Do we remove CloudKit now?**
   - MVP default: no. Keep it behind a boundary, but stop treating iCloud as auth.

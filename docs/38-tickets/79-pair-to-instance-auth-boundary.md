# Pair phone to Continuum instance — auth/session boundary

Status: **done / landed at `cc03cef`, 2026-07-06.** First implementation ticket for `_PAIR_TO_INSTANCE_PLAN.md`. It is MVP/personal, not enterprise auth. It does not remove CloudKit; it makes CloudKit stop being identity.

## Problem statement

The companion app can currently look connected because iCloud/CloudKit works, while still not being explicitly paired to this Continuum instance.

Current shape:

- Desktop has core auth pieces and a debug pairing-token issuer.
- iOS starts CloudKit receiver paths directly once iCloud is available.
- iOS capability scope is still effectively static/debug-derived instead of session-derived.
- There is no persisted production concept of “this iPhone is paired to this Continuum instance as device X with scopes Y.”

For Dylan's MVP, we do not need heavy auth. We do need an explicit local ownership boundary so future CloudKit/API/SSE transports all answer the same question: **which paired device is asking, and what can it do?**

## Outcome

After this ticket:

- Desktop has a persistent `CompanionAuthService` or equivalent service that owns instance, owner, devices, sessions, pairing, verification, and revocation.
- A stable local `instanceId` exists.
- A single local owner user is created automatically.
- Pairing exchange can create a persistent device + session record, even if the QR/local-network UI is still a follow-up.
- iOS has explicit paired-session state backed by Keychain abstraction.
- iOS derives capability scope from the stored paired session.
- CloudKit startup is gated behind paired state; iCloud availability alone is not “paired.”
- Existing debug pairing-token menu behavior still works, but routes through the new service.

## Scope

### In scope

1. **Desktop companion auth service**
   - Add `CompanionAuthService` or equivalent app/Core-facing wrapper around existing `PairingStore`, `SessionStore`, `AuthDatabase`, and signing key material.
   - Persist under the existing app-support auth directory using `AuthDatabase.url(in:)` and `SessionStore.loadOrCreateSigningKey(in:)` discipline.
   - Create/load stable `instanceId` and one local owner id.
   - Expose methods for:
     - issue pairing credential;
     - exchange credential for session/device;
     - verify session token;
     - list devices/sessions;
     - revoke session/device.
   - Replace the desktop app's raw ephemeral debug `PairingStore()` field with this service.

2. **Persistent device/session model**
   - Store paired devices in the auth DB or a Core auth store that is backed by the auth DB.
   - Device/session records must include at least:
     - `instanceId`;
     - `userId`;
     - `deviceId`;
     - label/subject;
     - granted scopes;
     - issued/created timestamps;
     - expiry where applicable;
     - revokedAt where applicable.
   - Registry/UI device lists may cache display info, but auth DB is the security source of truth.

3. **MVP exchange primitive**
   - Provide a pure/service-level exchange API that consumes a credential and returns a companion session payload.
   - It does not need an HTTP server or QR UI yet.
   - It should be easy for the next ticket to expose as `POST /pair/exchange`.

4. **iOS paired-session state**
   - Add an iOS-side model/abstraction:
     - `unpaired`;
     - `paired(instanceId, userId, deviceId, scopes, expiresAt)`;
     - `expired/revoked/unavailable` if later verification fails.
   - Add Keychain-backed storage plus an in-memory fake for checks.
   - Make app capability/scope derive from this session state.
   - Keep any `CONTINUUM_SCOPE_OVERRIDE=operator` escape hatch DEBUG-only and visibly labeled as dogfood override.

5. **Startup gate**
   - If no paired session exists, the iOS app enters an explicit “Pair this phone to your Continuum instance” state instead of trying to look live just because iCloud is available.
   - If paired, CloudKit/transport startup can continue as today, but session/device metadata is available to diagnostics and future envelope work.

6. **Checks**
   - Add/extend executable checks proving:
     - instance id stable across restart;
     - owner id stable across restart;
     - signing key/session verification survives restart;
     - pairing exchange creates exactly one device/session;
     - credential reuse fails;
     - revocation makes verify fail;
     - observer session cannot authorize `.moveTile` / `.respondToApproval`;
     - operator session can authorize `.respondToApproval`;
     - iOS paired-session store maps session scopes to UI capability without CloudKit.

### Out of scope

- QR rendering/scanner UI.
- Local HTTP/HTTPS server.
- Bonjour/manual IP discovery.
- Replacing CloudKit.
- Authenticated CloudKit command envelopes.
- Offline/freshness UI details beyond not conflating unpaired with offline; see ticket 80.
- Full hosted account login, passwords, passkeys, teams, orgs, or multi-user management.

## Files likely touched

- `Sources/ContinuumRevivedCore/Auth/AuthDatabase.swift`
- `Sources/ContinuumRevivedCore/Auth/PairingStore.swift`
- `Sources/ContinuumRevivedCore/Auth/SessionStore.swift`
- `Sources/ContinuumRevivedCore/Auth/PairingURL.swift`
- `Sources/ContinuumRevivedCore/ScopeAuthorization.swift`
- new Core/App auth service/model files as needed
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
- `ios/Continuum/Sources/ContinuumApp.swift`
- `Sources/ContinuumRevivedCoreChecks/AuthChecks.swift`
- `scripts/run-matrix.sh` only for additive check wiring, never weakening existing gates

## Verification

Required gates:

```bash
swift build
CONTINUUM_SKIP_SURFACE_CHECKS=1 ./scripts/run-matrix.sh
```

If `ios/` changes:

```bash
cd ios && xcodegen generate && xcodebuild -project Continuum.xcodeproj -scheme Continuum -destination 'generic/platform=iOS Simulator' build
```

## Done when

- Desktop auth/session/device state is service-owned and persistent.
- Stable `instanceId` and local owner id exist.
- Debug pairing token issue path uses the new service.
- Service-level pairing exchange creates persistent device/session records.
- iOS has explicit paired/unpaired state and a Keychain storage abstraction.
- iOS scope/capability is session-derived.
- iOS no longer treats iCloud availability as pairing.
- Existing auth checks still pass; new checks cover restart/revoke/scope behavior.

## Watch out for

- Do not ship a fake “paired” state just to keep CloudKit screens alive.
- Do not put bearer tokens into CloudKit records.
- Do not make `Registry` the source of truth for security.
- Do not block this ticket on TLS/cert/pinning/QR polish.
- Do not remove CloudKit in this ticket.
- Be honest in UX: unpaired, paired-but-offline, and iCloud-unavailable are different states.

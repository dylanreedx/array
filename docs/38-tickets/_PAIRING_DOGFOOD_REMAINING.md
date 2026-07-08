# Pairing dogfood remaining work — honest handoff

Date: 2026-07-07
Branch at handoff: `main` (ahead of `origin/main` with companion tail commits)

## Why this exists

The auth/freshness/publisher substrate landed, but the product is **not yet end-to-end dogfood-ready** because the phone still has no real way to redeem a pairing token against the Mac.

Do not claim "ready to test everything" until the phone can pair to a Continuum instance and the desktop app can run with a valid CloudKit entitlement.

## Current landed state

Landed locally on `main`:

- `210323e` — ticket 75, paired desktop companion sync publisher substrate.
- `9077c1c` — ticket 76, companion dogfood preflight kit.
- `d289fb6` — ticket 77, canvas mirror polish.
- `4b094da` — progress ledger hash cleanup.

Earlier foundation:

- `cc03cef` — ticket 79, `CompanionAuthService`, pairing/session/device model, iOS paired-session state storage.
- `e8c6841` — ticket 80, `CompanionFreshness`, stale/offline UI/action gates.

## What is missing

### 1. Actual phone-to-Mac token exchange

Mac can issue a pairing token:

- Debug menu: `Debug > Auth > Issue Pairing Token (Observer)`.
- Current behavior logs a `continuum://pair#token=...` URL.

But iOS does not yet have a complete flow to redeem that token against the Mac and save a returned session. The pieces are incomplete:

- iOS shows `Pair this phone` when unpaired.
- iOS can store `PairedCompanionSession` in Keychain.
- `PairingURL.parse` currently extracts only `token` from a URL fragment.
- No reachable Mac pairing endpoint exists.
- No iOS `onOpenURL`/manual pairing screen exists for token redemption.

### 2. A deployable local pairing endpoint

Recommended MVP: a short-lived LAN pairing endpoint on the Mac.

This is only for **pairing bootstrap**. Sync can remain CloudKit after pairing.

Flow:

1. Mac starts a temporary listener only while pairing is active.
2. Mac issues a one-time token through `CompanionAuthService.issuePairingCredential`.
3. Mac displays/copies a URL containing endpoint + token.
4. iPhone opens URL or user pastes it.
5. iPhone POSTs token + device info to Mac endpoint.
6. Mac consumes token exactly once and returns a scoped `PairedCompanionSession` payload.
7. iOS saves session to Keychain and exits unpaired state.
8. Mac stops listener or lets it expire.

Suggested URL shape:

```text
continuum://pair#endpoint=http%3A%2F%2F192.168.1.23%3A49231%2Fpair&token=ABCD1234&scopes=1&instance=<uuid>
```

Suggested request:

```http
POST /pair
Content-Type: application/json

{
  "token": "ABCD1234",
  "deviceName": "Dylan's iPhone",
  "requestedScope": 1
}
```

Suggested response:

```json
{
  "instanceId": "...",
  "userId": "...",
  "deviceId": "...",
  "sessionId": "...",
  "sessionSecret": "...",
  "scopeRawValue": 1,
  "issuedAt": "...",
  "expiresAt": "..."
}
```

Implementation notes:

- Use a random high port.
- Bind only while the pairing sheet/window is open, or for TTL ~5 minutes.
- Token is single-use and short-lived.
- Return only the scoped session, never signing keys or auth DB contents.
- For local dogfood, same Wi-Fi is enough; no port forwarding needed.
- Port forwarding/Tailscale is only needed for off-LAN pairing.
- HTTP over LAN is acceptable for a debug/local MVP if clearly labeled; production should move to TLS/Bonjour/QR/relay hardening.

### 3. Mac pairing UI

Current token is logged, which is not acceptable dogfood UX.

Needed:

- Menu action opens pairing sheet/window.
- Shows pairing URL and Copy button.
- Shows endpoint status, expiry, and paired device count.
- Optional later: QR code.

### 4. iOS pairing UI + URL handler

Needed:

- Register URL scheme in `ios/project.yml` / generated project if not already present.
- Add `.onOpenURL` to parse `continuum://pair`.
- Extend `PairingURL` parsing to read endpoint, token, scopes, instance id.
- Add manual paste field on `PairingRequiredView` as fallback.
- Exchange with Mac endpoint, save returned `PairedCompanionSession`, then call the existing startup/connect path.
- Show honest errors: expired token, unreachable Mac, already used token, scope denied.

### 5. Proper signed macOS CloudKit app

Manual signing with only `codesign --entitlements` is not enough on this machine. The app verifies on disk but launchd/AMFI kills it when the iCloud entitlement is not provisioned:

```text
RBSRequestErrorDomain Code=5 "Launch failed"
NSPOSIXErrorDomain Code=163 "Launchd job spawn failed"
```

A runnable unentitled diagnostic app exists temporarily at:

```text
/tmp/ContinuumRevived-dogfood-unentitled.app
```

It can run health checks with `--allow-unentitled`, but it is **not** real CloudKit proof.

Real CloudKit dogfood requires one of:

- Xcode macOS app target with iCloud capability for `iCloud.dev.dylanreedx.continuum`, signed with Dylan's Apple Development team; or
- `scripts/provisioned-cloudkit-app.sh`, which embeds a valid macOS provisioning profile matching `com.continuum.revived` + `iCloud.dev.dylanreedx.continuum`, signs with the matching Apple Development identity, verifies entitlements/profile, and runs LaunchServices smoke.

Provisioned script path:

```bash
CONTINUUM_CODESIGN_IDENTITY="Apple Development: Dylan Reed (...)" \
CONTINUUM_MACOS_PROVISIONING_PROFILE="$HOME/Downloads/ContinuumRevived.provisionprofile" \
  scripts/provisioned-cloudkit-app.sh \
    --configuration release \
    --output qa-runs/provisioned/ContinuumRevived.app
```

Then dogfood with:

```bash
scripts/companion-dogfood-start.sh \
  --desktop-app qa-runs/provisioned/ContinuumRevived.app \
  --device "Dylan’s iPhone" \
  --publish-fixture-if-empty
```

`--allow-unentitled` remains diagnostics-only and must not be cited as CloudKit proof.

## Suggested next tickets for agents

### Ticket A — LAN pairing endpoint + Mac pairing window

Deliver:

- Mac short-lived pairing listener.
- Pairing URL includes endpoint/token/scope/instance.
- Pairing window/sheet with Copy URL, expiry, listener status.
- Endpoint calls `CompanionAuthService.exchangePairingCredential`.
- Checks for single-use, TTL, requested-scope downscoping/denial, no secret leakage, listener expiry.

### Ticket B — iOS pair URL/manual token flow

Deliver:

- URL scheme registration and `onOpenURL` handler.
- Pairing URL parser extended for endpoint/token/scope/instance.
- Manual paste UI on PairingRequiredView.
- HTTP client exchanges token for session and saves Keychain state.
- Checks with fake exchange client for success/expired/unreachable/replay/scope-denied.
- iOS simulator build required.

### Ticket C — provisioned macOS CloudKit dogfood build

Status: implemented locally by ticket 83 scripts/docs. Supervised proof still requires Dylan's real Apple Development identity/profile.

Delivered:

- `scripts/provisioned-cloudkit-app.sh` builds/signs/diagnoses a provisioned macOS `.app` with valid iCloud entitlement.
- `scripts/companion-dogfood-start.sh` uses that path or clearly instructs when identity/profile provisioning is missing.
- Health check must report `desktopSignedWithICloudEntitlement=true` and app must pass LaunchServices smoke, not just `codesign --verify`.

## Testing sequence after A+B+C

1. Build/launch signed Mac app.
2. Open Mac pairing window, copy URL.
3. Open URL on iPhone or paste into pairing screen.
4. Confirm iOS Settings shows paired instance/session.
5. Run:

```bash
scripts/companion-dogfood-start.sh \
  --desktop-app /path/to/provisioned/ContinuumRevived.app \
  --device "Dylan’s iPhone" \
  --publish-fixture-if-empty
```

6. Verify:
   - Agents tab non-empty.
   - Canvas tab non-empty and fit-all framed.
   - Freshness labels are honest.
   - Mac move updates phone within honest CloudKit cadence or reports fetch needed.
   - Phone action/edit works or produces clear scope/freshness rejection.

## Non-negotiables

- Do not treat same-iCloud as pairing.
- Do not claim SwiftPM/unentitled app as CloudKit proof.
- Do not push transcript bodies, local paths, cwd, pids, tmux pane/window targets, signing keys, raw APNS tokens, or session secrets across CloudKit.
- Do not silently mutate Dylan's real workspace for a fixture.
- Do not declare dogfood complete without real phone pairing and a launchable provisioned CloudKit Mac app.

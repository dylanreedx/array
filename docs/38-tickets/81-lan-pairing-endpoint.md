# 81 — LAN pairing endpoint + Mac pairing window

## Goal
Make the Mac able to bootstrap explicit instance pairing by serving a short-lived local token-redemption endpoint and exposing a usable pairing URL to Dylan.

## Scope
- Add a macOS-only/debug-local pairing server/listener that is active only while pairing is requested, or for a short TTL.
- Issue token via existing `CompanionAuthService.issuePairingCredential`.
- Build a pairing URL containing endpoint, token, scope, and instance id.
- Add Mac UI/menu path that shows/copies the URL and reports expiry/listener status.
- Endpoint accepts token + device info, consumes token exactly once, and returns a session payload suitable for iOS Keychain storage.

## Acceptance
- Same-LAN iPhone can reach `http://<mac-ip>:<port>/pair` during pairing TTL.
- Expired/replayed/invalid token is rejected.
- Listener stops or rejects after TTL/window close.
- No transcript bodies, local paths, signing keys, raw APNS tokens, or unrelated host-local state are returned.
- Deterministic checks cover success, replay, expiration, invalid scope/device input, and URL payload shape.

## Notes
See `_PAIRING_DOGFOOD_REMAINING.md`. This is pairing bootstrap only; CloudKit remains sync transport after pairing.

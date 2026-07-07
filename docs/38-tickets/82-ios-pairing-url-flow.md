# 82 — iOS pairing URL/manual token flow

## Goal
Let the iPhone leave the unpaired state by opening/pasting a Continuum pairing URL, redeeming it against the Mac pairing endpoint, and saving the returned paired session.

## Scope
- Register/verify `continuum://pair` URL handling in the generated iOS project config.
- Extend shared pairing URL parsing to include endpoint, token, scope, and instance id.
- Add iOS `.onOpenURL` handling.
- Add manual paste fallback on the `Pair this phone` screen.
- Add exchange client that POSTs token + device identity to the Mac endpoint and decodes session response.
- Save successful `PairedCompanionSession` to Keychain and reconnect/start existing companion flow.
- Show honest errors for unreachable Mac, expired token, replay, scope denied, malformed URL, and instance mismatch.

## Acceptance
- URL and paste flows can be tested with a fake/local exchange client without CloudKit.
- Successful exchange changes app state from unpaired to paired.
- Failures do not partially save a session.
- iOS simulator build passes after `xcodegen generate`.
- No same-iCloud shortcut is treated as pairing.

## Notes
Depends on ticket 81 endpoint contract for full device proof. Add hermetic checks for parser/client/state behavior.

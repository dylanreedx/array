# 84 — Phone pairing dogfood hardening

## Goal
Make the real iPhone pairing bootstrap reliable enough for TestFlight dogfood: Camera scan should open Continuum, the app should be allowed to reach the Mac LAN pairing endpoint, and Dylan should be able to reset the phone pairing without deleting the app.

## Scope
- Serve a Camera-compatible HTTP landing URL that unwraps to the explicit `continuum://pair` payload.
- Keep the real pairing exchange as a one-time POST to the Mac LAN `/pair` endpoint.
- Improve Mac QR rendering/copy so Camera scans a fresh local HTTP URL instead of an opaque custom scheme.
- Add iOS in-app QR scan fallback, local-network/ATS permissions, retry/backoff, and clearer network errors.
- Add local iOS unpair/reset UI for dogfood iteration.
- Standardize TestFlight build-number format for future agents.

## Acceptance
- iPhone Camera recognizes the QR as an HTTP URL and can hand off to Continuum via the landing page.
- Continuum iOS can POST the one-time token to the Mac LAN endpoint after Local Network permission is granted.
- Paste/manual URL path remains supported.
- Saved paired session can be cleared from Settings without deleting the app.
- Deterministic checks cover HTTP bootstrap URL parsing, landing-page validation, and invalid landing links.
- iOS project metadata includes the URL scheme, camera usage copy, local-network usage copy, and local HTTP allowance.

## Notes
This is pairing bootstrap only. CloudKit remains the post-pairing sync transport and is not identity/authorization. Real CloudKit live-state proof still requires signed/provisioned Mac and TestFlight/device dogfood.

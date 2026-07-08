# 83 — Provisioned macOS CloudKit dogfood build

## Goal
Produce a repeatable macOS app bundle path that launches successfully with a real provisioned iCloud/CloudKit entitlement for `iCloud.dev.dylanreedx.continuum`.

## Problem
Manual `codesign --entitlements` can make the bundle verify on disk, but launchd/AMFI kills it when the entitlement is not provisioned:

```text
RBSRequestErrorDomain Code=5 "Launch failed"
NSPOSIXErrorDomain Code=163 "Launchd job spawn failed"
```

The current unentitled bundle can run diagnostics only with `--allow-unentitled`; it is not CloudKit proof.

## Repeatable path added in this ticket

Use `scripts/provisioned-cloudkit-app.sh`. It builds the SwiftPM app bundle, embeds a supplied macOS provisioning profile, signs with a supplied Apple Development identity, verifies the signed entitlements, verifies the embedded profile authorizes the same bundle id + CloudKit container, runs a LaunchServices smoke check, and captures `--companion-sync-health-check` JSON.

```bash
CONTINUUM_CODESIGN_IDENTITY="Apple Development: Dylan Reed (...)" \
CONTINUUM_MACOS_PROVISIONING_PROFILE="$HOME/Downloads/ContinuumRevived.provisionprofile" \
  scripts/provisioned-cloudkit-app.sh \
    --configuration release \
    --output qa-runs/provisioned/ContinuumRevived.app
```

The profile must be a **macOS** provisioning profile for bundle id `com.continuum.revived` with CloudKit container `iCloud.dev.dylanreedx.continuum`. The script does read-only profile diagnostics via `security cms -D`; it does not mutate certificates, keychains, or provisioning-profile stores.

To inspect a prebuilt app without rebuilding/signing:

```bash
scripts/provisioned-cloudkit-app.sh \
  --diagnose qa-runs/provisioned/ContinuumRevived.app
```

On success, the script writes artifacts under `qa-runs/<timestamp>/provisioned-cloudkit-app/` (or `--artifacts-dir`), including:

- `profile.plist`
- `profile-entitlements.plist`
- `signed-entitlements.plist`
- `codesign-sign.txt` (build mode)
- `codesign-verify.txt`
- `launch-smoke.txt`
- `health.json`
- `manifest.json`

## Dogfood start command

`scripts/companion-dogfood-start.sh` now refuses fake proof for real runs. It accepts a provisioned app directly:

```bash
scripts/companion-dogfood-start.sh \
  --desktop-app qa-runs/provisioned/ContinuumRevived.app \
  --device "Dylan’s iPhone" \
  --publish-fixture-if-empty
```

If `--desktop-app` is omitted, a real run attempts to build/sign the provisioned app at:

```text
qa-runs/<timestamp>/companion-dogfood/ContinuumRevived-provisioned.app
```

using `CONTINUUM_CODESIGN_IDENTITY` and `CONTINUUM_MACOS_PROVISIONING_PROFILE`.

`--allow-unentitled` is still available only for non-proof diagnostics; output will say that `desktopSignedWithICloudEntitlement=false` is not CloudKit proof.

## Failure classes the scripts distinguish

- `unsigned-or-invalid-code-signature` — `codesign --verify` fails.
- `unentitled` — the signature lacks `com.apple.developer.icloud-services=CloudKit` or the expected container.
- `entitlement-present-but-ad-hoc-signed` — entitlement is present but the app is ad-hoc/manual signed; not proof.
- `entitlement-present-but-unprovisioned` — entitlement is present but no `Contents/embedded.provisionprofile` exists; this is the known launch-kill class.
- `entitlement-present-but-profile-missing-cloudkit-container` / `...does-not-match-bundle-id` — profile exists but does not authorize this app/container.
- `entitlement-present-but-unprovisioned-or-launch-killed` — signing/profile checks passed far enough to launch, but LaunchServices smoke failed (the RBS Code=5 / NSPOSIX 163 class or another launch-blocking provisioning mismatch).
- `health-check-unentitled` — app ran but `--companion-sync-health-check` did not report `desktopSignedWithICloudEntitlement=true`.

## Scope
- Decide repeatable path: Xcode macOS target with iCloud capability, or script that embeds a valid macOS provisioning profile and signs with matching Apple Development identity.
- Update docs/scripts so `scripts/companion-dogfood-start.sh --desktop-app <path>` points Dylan at the real provisioned output.
- Ensure health/preflight reports `desktopSignedWithICloudEntitlement=true` for the provisioned app.
- Ensure app actually launches, not merely passes `codesign --verify`.

## Acceptance
- Clear command(s) to build/sign the app.
- Entitlements inspection includes CloudKit container.
- Launch smoke succeeds on Dylan's Mac.
- Dogfood script accepts the app without `--allow-unentitled`.
- Failure messages clearly distinguish unsigned, unentitled, and unprovisioned/launch-killed cases.

## Notes
Physical iPhone CloudKit proof remains supervised, and this ticket does not implement the phone pairing endpoint/UI. This ticket removes the Mac launch/provisioning blocker without claiming same-iCloud or manual codesign as proof.

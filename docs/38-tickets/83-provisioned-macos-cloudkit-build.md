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
Physical iPhone CloudKit proof remains supervised, but this ticket must remove the current Mac launch blocker.

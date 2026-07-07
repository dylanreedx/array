# Morning companion dogfood kit — one-command setup, health checks, and artifacts

Status: **pending after rewritten 75, 2026-07-07.** Follow-up to ticket 75. Do **not** run this as a same-iCloud-only dogfood kit. With `79-pair-to-instance-auth-boundary.md` and `80-companion-offline-freshness.md` landed, this kit should verify: paired Continuum instance, device/session scope, heartbeat/freshness state, cached stale canvas behavior, and signed/entitled transport after the paired publisher lands.

## Problem statement

Even after the desktop publisher exists, the first real iPhone dogfood can still feel broken if setup is manual and invisible. Current likely failure modes:

- desktop launched via SwiftPM instead of signed `.app`;
- desktop and iOS use different CloudKit containers;
- iPhone is installed/running but not receiving data;
- iCloud account is unavailable/restricted on one side;
- no publish/fetch has happened yet;
- no visible canvas fixture exists, so the phone looks empty;
- no screenshots/log bundle exists for debugging after the session.

The user experience goal is: **run one command, open both apps, see a green checklist, and have a non-empty canvas/agent scene ready to verify.**

## What this delivers

A supervised dogfood harness for the companion app:

- `scripts/companion-dogfood-start.sh` builds/launches the signed desktop app with the expected entitlements.
- The script discovers Dylan's connected iPhone, verifies the Continuum app is installed/runnable, and launches it.
- It runs a desktop sync health check: iCloud account, container id, entitlements, latest publish/fetch timestamps.
- It publishes a safe, clearly-labeled **dogfood canvas scene** if the real desktop canvas is empty.
- It starts or points to a visible dummy agent tile/session so the Agents tab is not blank.
- It writes all logs, manifests, and screenshots to `qa-runs/<timestamp>/companion-dogfood/`.
- It prints a short human checklist with exactly what Dylan should tap/observe on the phone.

## Scope

### In scope

1. **One-command launch script**
   - Build or locate the signed desktop `.app`.
   - Refuse to use `.build/debug/continuum-revived` for CloudKit proof unless explicitly passed `--allow-unentitled`.
   - Launch desktop Continuum and record PID/log path.
   - Detect connected iOS devices with `xcrun devicectl list devices`.
   - Launch the installed iOS app by bundle id.

2. **Environment/entitlement preflight**
   - Print expected desktop bundle id, iOS bundle id, CloudKit container id, APNS topic, and team id.
   - Assert desktop and iOS CloudKit containers match the selected dogfood config.
   - Check the desktop binary's entitlements with `codesign -d --entitlements :-`.
   - Check iPhone lock state / connection state where `devicectl` exposes it.

3. **Companion sync health command**
   - Add a desktop app flag or menu action: `--companion-sync-health-check` / `Companion Sync: Health Check`.
   - Output JSON with:
     - `desktopSignedWithICloudEntitlement`
     - `containerIdentifier`
     - `iCloudAccountAvailable`
     - `lastSpatialPublishAt`
     - `lastActivityPublishAt`
     - `lastFetchAt`
     - `lastInboundMessageKind`
     - `lastError`

4. **Dogfood scene seeding**
   - If the current canvas is empty or visually useless, create a local dogfood zone with:
     - one terminal/agent tile;
     - one note tile explaining it is a dogfood fixture;
     - sane viewport/fit-all geometry.
   - The fixture must be obviously removable and must not overwrite Dylan's real project state without confirmation.
   - Prefer a temporary dogfood workspace/project over mutating the user's primary workspace.

5. **Visible dummy agent**
   - Spawn a terminal tile running a harmless long-lived command or a Pi harness role, and mark it as an agent descriptor if the production path supports it.
   - Fallback: publish a sanitized dummy `ActivityLogSnapshot` row labeled `Dogfood Dummy Agent` with an explicit fixture marker, but only when real agent discovery is unavailable.

6. **Artifact capture**
   - Save desktop logs, health JSON, `devicectl` launch JSON, process list excerpts, and optional screenshots.
   - Write `qa-runs/<timestamp>/companion-dogfood/README.md` with pass/fail observations.

### Out of scope

- Implementing the desktop publisher itself; that is ticket 75.
- Fixing every visual defect found during dogfood.
- Shipping fixture data to production users.
- Requiring APNS real pushes before basic canvas/agents sync is green.

## Proposed user flow

```bash
scripts/companion-dogfood-start.sh --device "Dylan’s iPhone" --publish-fixture-if-empty
```

Expected output:

```text
Continuum companion dogfood
✓ desktop app signed with iCloud entitlement
✓ desktop/iOS container: iCloud.dev.dylanreedx.continuum
✓ iCloud account available on desktop
✓ launched desktop Continuum pid=...
✓ launched iPhone Continuum pid=...
✓ published spatial snapshot tileCount=2 zoneCount=1
✓ published activity snapshot agentRows=1

Now on iPhone:
1. Open Agents → confirm Dogfood Dummy Agent appears.
2. Open Canvas → confirm Dogfood Zone + tile appear.
3. Move desktop tile → wait <=10s → confirm iPhone moves.
Artifacts: qa-runs/.../companion-dogfood/
```

## Files likely touched

- `scripts/companion-dogfood-start.sh` — new supervised dogfood driver.
- `Sources/ContinuumRevived/App/ContinuumApp.swift` — app flag/menu entry for health check/publish now if not already added by ticket 75.
- `Sources/ContinuumRevived/App/CompanionDogfoodFixture.swift` — fixture scene builder.
- `Sources/ContinuumRevivedCore/CompanionSyncConfig.swift` — shared constants if introduced by ticket 75.
- `qa-runs/` documentation only via generated artifacts, not committed fixtures.

## Tests / gates

### Autonomous

- Shell script dry-run mode: `scripts/companion-dogfood-start.sh --dry-run` validates required tools and prints intended actions without launching devices.
- Fixture builder check: generates deterministic non-empty canvas/activity snapshots and verifies I5 taint scanner passes.
- Health JSON schema check: required keys exist and failure states are explicit.

### Supervised / needs-substrate

- Run the full script on Dylan's Mac with the physical iPhone connected.
- Confirm the iPhone app launches.
- Confirm Agents and Canvas are non-empty.
- Confirm artifact directory contains logs and health JSON.

## Done when

- Dylan can start the morning test with one command and no manual spelunking.
- The command refuses the known-bad unentitled SwiftPM path for real CloudKit proof.
- The command either publishes the real desktop canvas/agents or creates a clearly labeled dogfood scene.
- The phone shows a non-empty Agents tab and Canvas tab during the session.
- Failures produce actionable diagnostics instead of blank screens.

## Watch out for

- **Do not mutate real workspaces silently.** Fixture setup must be explicit or use a temporary dogfood workspace.
- **Do not fake success.** If CloudKit is unavailable, print that and stop before claiming sync.
- **Do not confuse simulator and physical-phone bundle ids.** Print the launched device and bundle id.
- **Do not leak local paths/transcripts in fixture activity.** Even dogfood fixture data crosses CloudKit.

## Execution mode

**Supervised + needs-substrate.** Dry-run and fixture checks are autonomous, but the ticket only counts as done after Dylan runs the real physical-phone dogfood path and sees the phone populated.

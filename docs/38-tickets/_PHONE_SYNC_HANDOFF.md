# Phone live-sync dogfood — handoff (2026-07-17 session, Dylan + agent)

The goal of the session: manually QA ticket 85 ("phone shows real desktop agent state").
End state: **every Mac-side gate is green and provably publishing to CloudKit; the phone
still shows nothing, and the next debugging step is to iterate against the iOS SIMULATOR
instead of the physical phone** (the phone round-trip — reinstall, relaunch, read the
screen, ask Dylan what he sees — is too slow, and the last observation is unexplained).

## Where you are

- Worktree: `/Users/dylan/Documents/personal/continuum-overnight` (a git worktree of the
  main repo whose primary checkout is `~/Documents/personal/continuum-revived`). Sibling
  agent worktrees exist (`continuum-agent-81`, `-83`).
- Branch: **`main`** at `0d375d2` + a LARGE dirty tree (see below).
  `overnight/agent-orchestration` still exists but is strictly BEHIND main — main is the
  live line now. Do not push anything.
- Commit rule (Dylan's global CLAUDE.md, absolute): plain Conventional Commits under
  Dylan's identity, NO Co-Authored-By / AI-attribution trailers, never touch git config.

## The dirty tree (uncommitted, ~24 files) — three logical clusters

1. **Ticket 85 slice (from the 2026-07-09 session, verified green 2026-07-16):**
   remote-backed phone freshness, post-pair/status-change publish scheduling, Mac/iOS
   sync diagnostics, managed-agent Cmd-K spawn, sanitized managed rows, CLI-terminal
   relabels. Its `_PROGRESS.md` row ("85 … partial … this commit") is staged in the diff.
   Full headless matrix + iOS sim build were re-verified green on 2026-07-16 before any
   of tonight's changes.
2. **This session's Mac-side fixes (all in service of un-blocking CloudKit):**
   - `scripts/provisioned-cloudkit-app.sh`: profile check accepts wildcard
     `icloud-services=*` (Xcode-managed team profiles use it); signing now DERIVES
     app entitlements from the profile — rewrites `icloud-services` `*` →
     `["CloudKit"]` and `icloud-container-environment` array → single string
     (default `Production`, override `CONTINUUM_CLOUDKIT_ENVIRONMENT`); signed-app
     check REFUSES a wildcard signature (CKContainer launch-kills on it).
   - `Sources/ContinuumRevived/App/ContinuumApp.swift`: runtime entitlement check kept
     explicit-only (wildcard in a SIGNATURE = broken app, not a grant); companion
     diagnostics now ALSO append to a file:
     `~/Library/Application Support/continuum-revived/companion-sync.log`
     (see "environment gotchas" — unified log is unreadable on this Mac).
3. **This session's phone-side fixes (THE bug + diagnostics):**
   - `ios/Continuum/Sources/ContinuumApp.swift`: **the root-cause fix** — the iOS app
     NEVER called `fetchChanges()`. The transport's inbound stream is fed only by
     `fetchChanges()`; receivers subscribed to a stream nothing wrote to. Added: stored
     transport + `fetchTask` loop in `AgentsBoardModel.start()` (initial backfill, then
     every 20s), `refreshNow()`, teardown in `tearDownSyncReceivers()`, honest loading
     copy ("Waiting for your Mac to publish…" once paired), and a `lastFetchReport`
     published property + "Last fetch" diagnostics row in Settings.
   - `Sources/ContinuumRevivedSync/CloudKitSyncTransport.swift`:
     `fetchChangesWithReport()` (public, `fetchChanges()` now delegates to it) returning
     "ok records=N batches=M" / "zoneNotFound (…)" so wrong-account is distinguishable
     from no-new-data.
   - `ios/Continuum/Resources/Continuum.entitlements`: added
     `com.apple.developer.icloud-container-environment = Production` (dev-signed iOS
     builds otherwise default to the Development environment and would never see the
     Mac's Production records; TestFlight ignores/re-signs, so it's safe to keep).
   - `ios/project.yml`: `CURRENT_PROJECT_VERSION` bumped 2026070802 → 2026071602
     (convention: YYYYMMDDNN).

Recommendation: commit these as 2–3 commits (ticket-85 slice; Mac provisioning/diagnostic
fixes; phone fetch fix + diagnostics) BEFORE iterating further — tonight proved how easy
it is to lose track of which build contains which fix.

## What is PROVEN working (do not re-litigate)

- Mac publish path, end to end. The entitled app at
  `qa-runs/provisioned/ContinuumRevived.app` publishes spatial+activity snapshots to
  CloudKit container `iCloud.dev.dylanreedx.continuum` (Production, private DB, zone
  `ContinuumSyncZone`) with `lastError=nil`. Evidence: `companion-sync.log` lines with
  reasons `startup` (auto-publish works), `manual-publish`, `managed-agent-spawn` (the
  ticket-85 publish trigger fired when Dylan spawned a managed agent), `manual-fetch`.
  `paired=true`, `pairedDevices=2`, `signedICloud=true`.
- Rebuild command (profile is Xcode-managed, already on disk):
  ```
  CONTINUUM_CODESIGN_IDENTITY="Apple Development: Dylan Reed (DGJTP684C8)" \
  CONTINUUM_MACOS_PROVISIONING_PROFILE="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/22fddb00-f227-45fc-a313-c27614122142.provisionprofile" \
  scripts/provisioned-cloudkit-app.sh --configuration release --output qa-runs/provisioned/ContinuumRevived.app
  rm -rf ~/Applications/ContinuumRevived.app
  ditto qa-runs/provisioned/ContinuumRevived.app ~/Applications/ContinuumRevived.app
  ```
  LAUNCH IT FROM `~/Applications/ContinuumRevived.app` — always. Never from a copy
  inside `~/Documents` (see gotcha 7).
  (That UUID profile = macOS Development, app id `com.continuum.revived`, iCloud container
  granted. If it expires, regenerate by building the dummy project at
  `~/Desktop/test/test.xcodeproj` with `PRODUCT_BUNDLE_IDENTIFIER=com.continuum.revived
  -allowProvisioningUpdates`.)
- Menu actions can be driven headlessly:
  `osascript -e 'tell application "System Events" to tell (first process whose name is
  "continuum-revived") to click menu item "Publish Now" of menu "Companion Sync" of menu
  item "Companion Sync" of menu "Debug" of menu bar 1'` (same for "Fetch Now").
- LAN pairing (QR/paste → token exchange → Keychain) works; it is HOW the phone got
  `paired=true` on the Mac. Pairing is transport-independent of CloudKit.

## The unsolved problem

Phone (physical iPhone 14 Pro, device id `BCD6222C-65C6-5782-87F8-556D278641F1`,
reachable via `xcrun devicectl`) shows: paired, transport `available`, but
`no remote activity snapshot`, `no remote spatial snapshot`, remote-backed live: no —
i.e. the fetch never returns data. AND the final observation of the night is unexplained:

- Build `2026071602` WITH the fetch loop + "Last fetch" Settings row was verified
  installed (`devicectl device info apps` shows 0.1.0 / 2026071602; `strings` on
  `Continuum.app/Continuum.debug.dylib` in `/tmp/continuum-ios-dd/Build/Products/...`
  contains `[companion-fetch]`, `Last fetch`, `Waiting for your Mac to publish`), it was
  launched via `devicectl … launch --console --terminate-existing`, **yet Dylan reports
  the Settings screen shows NO "Last fetch" row**. Unresolved contradiction. Hypotheses,
  in order: (a) the phone UI he was reading was a stale/other instance (the devicectl
  console session later showed "app terminated, exit code 0" — when the console session
  drops, the launched app dies; a home-screen relaunch would run the new build, so this
  is testable), (b) the Settings tab renders a DIFFERT diagnostics section than the one
  patched at ~line 1950 (check: only ONE `diagnosticRow("Latest activity", …)` call
  exists — verify which View owns it and whether it's DEBUG-gated), (c) install silently
  serving an old snapshot despite the listing.
- The #1 SUBSTANTIVE suspect for "no data" (independent of the row mystery): **iCloud
  account mismatch**. The transport uses the PRIVATE CloudKit database — Mac and phone
  must be on the same Apple ID. Mac = `dylreed@hotmail.com` (verified via
  `defaults read MobileMeAccounts`). The phone's Apple ID was NEVER confirmed despite
  repeated asks. `fetchChangesWithReport()` returning
  `zoneNotFound (no ContinuumSyncZone in this account's private DB)` on the phone/sim
  is the definitive wrong-account signature.

UPDATE 2026-07-18: hypothesis (a)/(c) — stale binary — is now the FRONTRUNNER. Two sim
installs today were silently stale because `ls DerivedData/Continuum-*` matches BOTH
this worktree's AND the primary continuum-revived checkout's DerivedData, and the
alphabetically-first (other checkout's) app got installed while the build log said
BUILD SUCCEEDED. The same class of mistake likely happened with the phone install on
the 16th. Never install without the strings gate (see loop below). The physical-phone
retest with a verified binary is still owed; the new gate logging + Files-app-readable
`companion-fetch.log` will name the failing gate in one line.

## Next step (agreed with Dylan): iterate on the iOS SIMULATOR

The simulator removes every observability problem (console visible, no reinstall dance).
An `iPhone 17 Pro` sim (A5593A9C-A811-4EA4-BEEE-D5084F7CDD3C) was already booted.

Loop (VERIFIED 2026-07-18 — the strings gate is mandatory, see gotcha 9):
```
DEV=A5593A9C-A811-4EA4-BEEE-D5084F7CDD3C   # or: booted
DD=/tmp/continuum-sim-dd                    # any EXPLICIT path; never glob DerivedData
cd ios && xcodegen generate
xcodebuild -project Continuum.xcodeproj -scheme Continuum -configuration Debug \
  -destination "id=$DEV" -derivedDataPath "$DD" build
APP="$DD/Build/Products/Debug-iphonesimulator/Continuum.app"
strings "$APP/Continuum.debug.dylib" | grep -c "<some string unique to the new code>" \
  # MUST be ≥1 — abort the install otherwise
xcrun simctl terminate "$DEV" dev.dylanreedx.continuum || true
xcrun simctl install "$DEV" "$APP"
xcrun simctl launch "$DEV" dev.dylanreedx.continuum
DATA=$(xcrun simctl get_app_container "$DEV" dev.dylanreedx.continuum data)
cat "$DATA/Documents/companion-fetch.log"   # the ONLY reliable output channel
```
Console/stdout capture does NOT work here in any form (plain `--console`,
`--console-pty`, `script -q` pty-wrap: all deliver nothing) — read
`companion-fetch.log` instead; it records start() gate outcomes (unpaired /
CKAccountStatus=N / started) and every fetch report.

Sim state as of 2026-07-18: ALREADY PAIRED (pairing survives in the sim keychain
across reinstalls; pairedDevices=1 on the Mac before the phone paired was probably
this sim). Blocked on: Settings → sign into iCloud as **dylreed@hotmail.com**
(CKAccountStatus=3 noAccount until then). If it ever needs re-pairing: Mac menu
Debug → Auth → Pair Phone… copies a camera bootstrap URL
(`http://…/open-continuum-pairing?link=<continuum%3A%2F%2F…>`) to the clipboard;
extract the `link` param and `xcrun simctl openurl "$DEV" "continuum://…"` — the
sim has no camera.

The report string decides everything:
`zoneNotFound` → account/DB mismatch; `FAILED: …` → real CKError; `ok records=N>0` but
no rows → bug downstream in demux/receiver/decode (all in `ContinuumRevivedSync`,
fully unit-testable — see SyncChecks).

Also worth doing early: add a build-number row to the iOS Settings screen (one line —
`Bundle.main.infoDictionary?["CFBundleVersion"]`) so "which build am I looking at" is
never a mystery again.

## Codebase orientation (fast)

Targets (`Package.swift` + `ios/project.yml`):
- `Sources/ContinuumRevivedCore` — pure model/persistence layer. Key: `CanvasState.swift`
  (Tile), `WorkspaceDocument.swift`, `SpatialOp.swift` (frozen-wire `Op`/`OpId`/
  `FracIndex`/`LoggedOp`), stores (`ProjectStore`, `WorkspaceStore`, `AtomicWriter`),
  `CompanionSyncConfig.swift` (container id), `Auth/` (pairing stores,
  `LocalPairingEndpoint`).
- `Sources/ContinuumRevivedSync` — sync layer, pure Swift over Core.
  `CloudKitSyncTransport.swift` is the heart: PRIVATE database, custom zone
  `ContinuumSyncZone`, record types syncOp/activityEvent/activitySnapshot/
  compactedSnapshot; **`fetchChanges()` is the ONLY thing that feeds `inbound`** and the
  app-lifecycle layer owns calling it (doc comment ~line 595). `SyncMessageDemux` fans
  out; `ActivityProjectionReceiver`/`SpatialOpReceiver` consume;
  `DesktopCompanionSyncService` is the Mac-side publisher; `FakeSyncTransport` for tests.
- `Sources/ContinuumRevived` — the AppKit Mac app. `App/ContinuumApp.swift` (~16k lines,
  AppDelegate, all self-checks, companion wiring ~lines 700 + 2440 + 5040 + the
  `appendCompanionSyncLog` file sink), `App/WorkspaceRuntime.swift`, `App/TileSpawner.swift`,
  `Canvas/CanvasNSView.swift`.
- `ios/Continuum/Sources/ContinuumApp.swift` — the ENTIRE iOS app in one SwiftUI file.
  `AgentsBoardModel` (start()/consume()/fetch loop ~lines 240–330), `LoadingBoardView`,
  `PairingRequiredView`, Settings/diagnostics views ~1900+. Regenerate the Xcode project
  with `xcodegen generate` after editing `project.yml`; never edit the `.xcodeproj`.
- Checks doctrine: **NO XCTest.** Everything is `*Checks` executables wired into
  `scripts/run-matrix.sh`. Gate:
  `swift build && CONTINUUM_SKIP_SURFACE_CHECKS=1 ./scripts/run-matrix.sh` (5 surface
  checks print SKIPPED headless — that plus "Matrix passed." is green). Read the LOG, not
  the exit code of a compound command (a mid-matrix FAIL was nearly missed this way).
- Ledgers: `docs/38-tickets/_PROGRESS.md` (per-ticket rows), `_CONFLICT_LOG.md` (rulings;
  read before touching a fenced ticket), `_PAIRING_DOGFOOD_REMAINING.md`, ticket files
  `NN-*.md`. Ticket for this work: `85-phone-live-sync-managed-agent-ux.md`.

## Environment gotchas learned the hard way (all cost real time tonight)

1. **`log show`/`log stream` return NOTHING on this Mac** — even a probe process's
   `Logger` output is invisible. Never rely on unified log here; use the
   `companion-sync.log` file sink (Mac) and sim/`--console-pty` stdout (iOS).
2. **Xcode-managed provisioning profiles use wildcard grants** (`icloud-services=*`,
   environment as an array). Profiles may GRANT wildcards; an app SIGNATURE must claim
   explicit values or CKContainer throws "malformed entitlements" AT LAUNCH (instant
   crash, nothing in logs). The script now derives correct signing entitlements.
3. **CloudKit environments**: TestFlight/App Store = Production always; dev-signed
   builds default to Development unless `icloud-container-environment` says otherwise.
   Mac script default and iOS entitlements are both pinned Production now.
4. **Private DB = same Apple ID on both devices.** Still the unconfirmed variable.
5. Debug iOS builds are a ~92KB stub binary + `Continuum.debug.dylib` — run `strings`
   on the dylib, not the stub, when verifying a build's contents.
6. `devicectl launch --console` buffers the app's stdout (prints may never appear) and
   the app DIES when the console session ends. CORRECTION 2026-07-18: simulator console
   capture is ALSO dead on this Mac (`--console`, `--console-pty`, and `script -q`
   pty-wrapping all deliver zero app output). The only reliable channel is the
   file sink: `<container>/Documents/companion-fetch.log`.
7. The Mac app instance matters — RESOLVED 2026-07-18 after a TCC prompt storm.
   Opening the stale ad-hoc bundle (`qa-runs/dogfood-20260716/…`, now deleted; a June
   copy in `~/Applications` was equally stale) produced an endless loop of
   "access files in your Documents folder" dialogs: macOS keys folder consent to the
   app's code signature, that bundle FAILED `codesign --verify`, so no Allow could ever
   persist — and the app's child processes (1 Hz conductor sqlite3, git, tmux,
   file-tree scans into the repo under ~/Documents) re-prompted on every touch.
   32 dead TCC rows had accumulated (`tccutil reset SystemPolicyDocumentsFolder
   com.continuum.revived` cleared them). Canonical install is now
   `~/Applications/ContinuumRevived.app` (the entitled build, OUTSIDE ~/Documents so
   the bundle itself needs no grant; ditto it there after each rebuild). One Allow on
   first Documents access persists, because the signature verifies and its designated
   requirement is identity-stable across rebuilds. Check
   `ps aux | grep continuum-revived` before trusting a test.
8. TestFlight is NOT needed for self-dogfood — `devicectl`/simulator installs are the
   fast path. The `2026071601` archive in Xcode Organizer is STALE (lacks the fetch fix);
   do not upload it.
9. `~/Library/Developer/Xcode/DerivedData/Continuum-*` matches TWO projects (this
   worktree AND the primary continuum-revived checkout — same project name, different
   path hashes). Globbing it installed the OTHER checkout's stale app twice on
   2026-07-18 while the build said SUCCEEDED. Always build with an explicit
   `-derivedDataPath` AND verify the product with
   `strings <app>/Continuum.debug.dylib | grep -c "<string unique to the new code>"`
   before installing. (Remember: strings on the .debug.dylib, not the stub binary.)
10. iOS app diagnostics live in `<container>/Documents/companion-fetch.log`
    (start() gate outcomes + every fetch report, ISO-8601 stamped). Simulator:
    `xcrun simctl get_app_container <dev> dev.dylanreedx.continuum data` then read
    `Documents/companion-fetch.log`. Physical phone: Files app → On My iPhone →
    Continuum (UIFileSharingEnabled is on in dev builds).

## Open items beyond the sync bug

- Ticket 85 pending list: real provider adapter behind "New Agent…", managed runtime
  event persistence/replay. Plus new from tonight: push(CKSubscription)-triggered fetch
  to replace/augment the 20s poll; surface `lastFetchReport` once the row mystery is
  solved; iOS build-number diagnostics row.
- `_CODEX_AUDIT.md` Tier-2/3/4 items and the supervised GUI matrix pass predate all of
  this and are still owed before any merge to a release line.

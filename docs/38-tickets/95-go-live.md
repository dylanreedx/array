# 95 — Go-live: first external release (friends alpha)

Status: planned 2026-08-09. Nothing in this doc has been started.

## Goal

A friend can open `arrayapp.dev`, click **Download for macOS**, drag Array.app to
Applications, launch it without Gatekeeper warnings, get walked through connecting
`claude` / `codex`, and receive future updates **in-app** — no re-download, no new
install per release.

## Scope of v0

- macOS app only, Apple Silicon (arm64) unless the universal-build question below says otherwise.
- **No CloudKit, no iOS companion, no relay.** Sync stays disabled in the friends build
  (it is already gated behind `CLOUDKIT_ENABLED`). This is what makes provisioning simple:
  a Developer ID app with no restricted entitlements needs **no provisioning profile at all**.
- Small-team relay (queue 92) stays paused. Phone sync is a v0.2+ story.
- No App Store, no sandboxing, no CI. Manual releases are fine at friend scale.

## Current state (audited 2026-08-09)

- Bundle is hand-assembled and unsigned: `scripts/make-app-bundle.sh` (prints
  "unsigned/unprovisioned"); `scripts/check-app-bundle.sh` ad-hoc signs for QA only.
- Identity is still Continuum: bundle id `com.continuum.revived`, executable
  `continuum-revived`, display name "Continuum Revived", v0.1.0 (build 1),
  `LSMinimumSystemVersion` 14.0 (`Packaging/Info.plist`).
- Keychain has only "Apple Development: Dylan Reed (DGJTP684C8)" and "AgentBoard Dev
  Signing". **No Developer ID Application identity exists.**
- No updater: zero Sparkle/appcast/`SUFeedURL` anywhere in `Sources/` or `Packaging/`.
- No `.github/`, no DMG/notarization scripts. `scripts/provisioned-cloudkit-app.sh` is
  Apple-Development dogfood signing for CloudKit proof, not a release pipeline.
- Website (`website/`, Astro, Vercel, `https://arrayapp.dev`): single page, no download
  button; all CTAs point at a GitHub issue template on the private `continuum` repo.
- No onboarding/first-run flow exists in `Sources/`.
- `claude`/`codex` tile launches resolve binaries from the **GUI environment PATH only**
  (`Sources/ContinuumRevivedCore/ToolDetector.swift`,
  `Sources/ContinuumRevived/App/TileSpawner.swift` passes
  `ProcessInfo.processInfo.environment`). Launched from Finder on a fresh machine this
  misses homebrew/nvm/`~/.local/bin` → "claude not found". The repo already contains the
  fix patterns: login-shell PATH capture (`AgentSupervisor.swift` `$SHELL -ilc`),
  well-known-dir fallbacks (`PiAgentRunner.swift`, `TmuxSession.swift`). Claude/codex
  profiles never got that hardening.

## History: the rename has burned us once — read this before Phase 0

Two prior sessions matter. Do not repeat their mistakes.

**1. The surface rename (pi session, 2026-08-06).** The dogfooded "Array.app" was produced
by copying the built bundle (`ditto`), setting `CFBundleDisplayName` to `Array` with
PlistBuddy, and ad-hoc re-signing. Nothing else changed: `CFBundleExecutable` is still
`continuum-revived`, bundle id still `com.continuum.revived`, CloudKit proof unavailable
(ad-hoc build). It *looks* renamed and is release-ready in no dimension. Session
transcript: `~/.pi/agent/sessions/--Users-dylan-Documents-personal-continuum-overnight--/2026-08-06T01-49-29-820Z_019fd4c2-e35c-74a7-ad93-14bc3338da9b.jsonl`.

**2. The two-projects doctrine (claude session `18016ea9`, 2026-08-06).** Continuum → Array
is two separate projects: the local/infra consolidation (done) and the source/identity
migration (not started, ~8,700 occurrences across ~1,200 files). Rules that carry over:

- **Never a global find-replace.** Legacy fixtures, historical docs, and provider-owned
  paths must keep saying Continuum.
- State migration must run before the first Array read on a machine with legacy state
  (identity/storage migration → schema migration → reconciliation → supervisor ready →
  first UI read). That machine is Dylan's only — friends have no legacy state.
- Rename the GitHub repo and reconnect Vercel **last**, never during local work.

**The lesson applied here:** what v0 needs is not the full rebrand. It is the **external
identity cut** — the subset of identity that gets baked into users' machines and into the
update feed. Internal module names (`ContinuumRevived*`) are invisible to users and stay
for now; they migrate later on the careful slice-by-slice plan.

## Locked decisions

1. **Ship as Array.** Target identities (from the 18016ea9 plan): bundle id
   `dev.arrayapp.macos`, app `Array.app`, product/executable `Array`. The bundle id is
   the one thing that cannot cheaply change after friends install — Sparkle refuses
   updates whose bundle id differs, and defaults/Keychain/app-support are keyed on it.
   With zero external users, the cut is the cheapest it will ever be. It happens **before**
   the first external build.
2. **Sparkle 2** for updates (in-app "new version available" prompts, EdDSA-signed appcast).
3. **DMG on GitHub Releases** in a **public releases-only repo** (code repo stays private;
   private-repo release assets are not publicly downloadable; this also defers the repo
   rename per the doctrine above).
4. **CloudKit entitlement omitted** from the friends build → no provisioning profile needed.

## Phase 0 — External identity cut — DONE (2026-08-09)

Only surfaces users can see or that persist on their machines. Everything else keeps its
Continuum name.

Change:
- [x] `Packaging/Info.plist`: `CFBundleIdentifier` → `dev.arrayapp.macos`,
      `CFBundleName`/`CFBundleDisplayName` → `Array`, `CFBundleExecutable` → `Array`.
- [x] `Package.swift`: executable product name → `Array` (module names untouched;
      binary is `.build/<config>/Array`, mechanical path updates applied to all scripts).
- [x] App Support directory → `~/Library/Application Support/Array`
      (`RegistryStore.defaultApplicationSupportDirectory()`, the single anchor every
      store funnels through).
- [x] Bundled defaults domains → `dev.arrayapp.macos` (`DeleteConfirmPolicy`,
      `BrowserRuntimeBudget`, `TerminalSpawnAdmission`; legacy domains left in place,
      read-only). Keychain services → `dev.arrayapp.macos.password-vault.v1`,
      `dev.arrayapp.macos.companion-session`.
- [x] tmux session names → `array-` / `array-view-` / `array-proj-` / `array-ws-`
      (`TmuxSession.swift` + `DefaultWorkspaceMigration` matching + QA probes).
- [x] Project dotdir → `.array` (`ProjectStore`, `ProjectLock`, `ProjectRootResolver`).
- [x] User-visible strings: app menu (About/Hide/Quit Array), window title
      "<name> — Array", project-lock alert, file-tree repair hint, Chrome policy
      reasons, companion pairing display name.
- [x] `scripts/make-app-bundle.sh` / `check-app-bundle.sh`: Array.app, new plist
      assertions; pollution guards now watch legacy Continuum AND new Array
      app-support/defaults entries.

Deferred identity debt (invisible to users; owned by the later module-rename project):
`continuum.*` defaults KEY names (~121 literals), `CONTINUUM_*` env vars, os_log
subsystems (`continuum.companion`, `continuum.auth`), accessibility identifiers,
ComponentLab fixtures, QA temp-dir/suite names, relay LaunchAgents label, CloudKit
container + iOS bundle ids (CloudKit is out of v0 scope), `ContinuumRevived*` modules.

Do NOT change:
- `ContinuumRevived*` module/target names, type names, internal imports.
- Historical docs, QA fixtures, `qa-runs/`, provider-owned paths (`~/.claude`, `~/.pi`,
  `~/.codex`), archived branches.
- The GitHub repo name and Vercel project (deferred; the public releases repo makes this
  a non-blocker).

Dylan's machine: **clean cut chosen (2026-08-09)** — zero migration code. The old
continuum-revived app-support dir, defaults, Keychain items, and `.continuum-revived`
project dirs are left untouched on disk; the Array-identity app simply starts fresh.
Old `continuum-*` tmux sessions are orphaned (kill manually or let them idle).

Verify — results (2026-08-09):
- [x] `swift build` all products passes; `check-app-bundle.sh` harness PASSES end to end
      (Array.app assembly, plist assertions, isolated-HOME self-checks incl.
      `--delete-confirm-policy-defaults-check` from inside the bundle, ad-hoc codesign,
      LaunchServices launch smoke, pollution guards clean).
- [x] Fresh-HOME run creates no continuum-named paths; default registry dir asserted as
      `…/Application Support/Array` by CoreChecks (all pass).
- [x] Isolated self-checks pass: menu contract, project-root resolution, tmux
      persistence/delete lifecycle/ambient workspace, workspace boot, project lock,
      zone project-session naming.
- Known pre-existing failure, NOT from this cut: `--component-lab-check` pixel baselines
  (managed-agent/sidebar renders) fail identically at unmodified HEAD (34 baselines,
  verified by stash + rebuild on 2026-08-09) — queue-90/91 baseline drift on this
  machine. Text assertions inside component-lab (session naming labels) pass.
- Note: `--delete-confirm-policy-defaults-check` by design requires bundle context
  (`Bundle.main.bundleIdentifier`); it fails on the bare binary and passes in the
  bundle harness.

## Phase 1 — Developer ID signing + notarization — DONE (2026-08-09)

- [x] Developer ID Application certificate created via Xcode:
      "Developer ID Application: Dylan Reed (46TTB6J9DZ)". NOTE: the Developer ID
      team is **46TTB6J9DZ**, not the old Apple Development team DGJTP684C8.
- [x] notarytool keychain profile `array-notary` stored
      (apple id dylreed@hotmail.com, team 46TTB6J9DZ, app-specific password).
- [x] `scripts/release-app.sh` written and tested 2026-08-09 (ad-hoc + --skip-notarize
      leg): release build → Array.app → sign inside-out with hardened runtime
      (nested Frameworks loop is Sparkle-ready) → versioned drag-to-install DMG
      (19 MB, `hdiutil` UDZO) → mount + codesign verify. Notarize path implemented
      (notarize app zip → staple app → DMG → sign → notarize → staple → `spctl`
      verify both) but unexercised until the identity + notary profile exist.
- [x] Entitlements for the release build: **none needed** — verified 2026-08-09 by
      ad-hoc signing with `--options runtime` and passing launch smoke,
      `--terminal-tmux-live-integration-check`, and `--terminal-fills-tile-check`
      (Ghostty is statically linked, so no library-validation exposure either).
- [x] Versioning: `release-app.sh --set-version/--set-build` stamps the bundle plist;
      first friends build is 0.2.0 (build 2). `CFBundleVersion` must increase
      monotonically (Sparkle compares it).
- [x] Arch: arm64-only for v0 (verified: release binary is Mach-O arm64). State
      "Apple Silicon" on the site; universal is a later decision.

App icon swapped to the Array mark 2026-08-09: `Packaging/AppIcon.icns` rebuilt from
`website/public/array-logo-dark.svg` (Apple 1024 grid — 824px squircle tile, mark
scaled ~1.67x to read at icon sizes; generator: `brand/make-icon.swift` —
`swift brand/make-icon.swift <logo.svg> <out.iconset>` then `iconutil -c icns`).
The dark tile serves both
appearances; true per-appearance light/dark/tinted icons are a macOS 26 Icon Composer
`.icon` follow-up, deliberately deferred.

First notarized release produced 2026-08-09: `qa-runs/release-0.2.0/Array-0.2.0.dmg`
(19 MB, arm64, v0.2.0 build 2) — app and DMG both notarized + stapled;
`spctl -a` says "accepted, source=Notarized Developer ID" on this machine.

Verify (still open): clean macOS VM or a fresh user account — download the DMG over
HTTP, open, drag, launch. Zero warnings beyond the standard "downloaded from the
internet — Open?" prompt. (Best done with the Phase 3 download URL.)

## Phase 2 — Sparkle 2 auto-update

Ordered plan (planned in detail 2026-08-09). The two repo-specific constraints that
shape it: the bundle is hand-assembled by `make-app-bundle.sh` (no Xcode embed phase),
and the QA matrix runs the **bare** binary, where an updater must stay inert.

1. [ ] **Keys (once, Dylan's machine).** Run Sparkle's `generate_keys` (shipped inside
   the SPM artifact bundle under `.build/artifacts/`). Private EdDSA key → login
   Keychain only ("Private key for signing Sparkle updates"). Public key → Info.plist.
   **Never in the repo.** Back the private key up (Keychain export or
   `generate_keys -x`) — losing it strands every installed copy on its version.
2. [ ] **Dependency.** `Package.swift`: add `sparkle-project/Sparkle` (from: "2.8.0")
   as a dependency of the app target only (`ContinuumRevived`). It ships as a binary
   XCFramework target via SPM.
3. [ ] **Info.plist.** `SUFeedURL` = `https://arrayapp.dev/appcast.xml`,
   `SUPublicEDKey` = <public key from step 1>. Leave `SUEnableAutomaticChecks` unset —
   Sparkle then asks the user for permission on second launch (polite default, and no
   silent network calls on first run).
4. [ ] **Code wiring.** In app startup: create one
   `SPUStandardUpdaterController(startingUpdater:updaterDelegate:userDriverDelegate:)`,
   **gated**: only start when `Bundle.main.bundleIdentifier == "dev.arrayapp.macos"`
   and not in any self-check/QA mode (bare-binary matrix legs and isolated-HOME QA runs
   must never touch the network or spawn Sparkle prompts). Add "Check for Updates…"
   to the app menu in `installMainMenu` (target: updater controller,
   `checkForUpdates(_:)`) — and extend `runMenuContractSelfCheck` to assert it, noting
   the menu contract runs in QA mode where the item exists but the updater is inert.
5. [ ] **Bundle embedding (the fiddly step).** `make-app-bundle.sh`: locate
   `Sparkle.framework` in the macOS slice of the SPM artifact (`.build/artifacts/…`),
   `ditto` it into `Contents/Frameworks/`, and fix rpaths: SwiftPM links the bare
   binary against the absolute artifacts path, so add
   `install_name_tool -add_rpath @executable_path/../Frameworks` (and verify with
   `otool -l`). `check-app-bundle.sh`: assert the framework (and its XPC services) is
   present, and that the launch smoke still passes — that proves the rpath is right.
   `release-app.sh` needs no change: its nested-signing loop already signs
   `*.xpc`/`*.framework` deepest-first under Contents/Frameworks.
6. [ ] **Appcast in the release flow.** Keep every shipped DMG in a local flat
   `releases/` archive dir (source of truth). After staple, run `generate_appcast
   <releases-dir> --download-url-prefix
   https://github.com/dylanreedx/array-releases/releases/download/v<version>/` →
   signs each item with the Keychain key → write `appcast.xml` to `website/public/`
   (deploys with the site on Vercel). Release notes: `sparkle:releaseNotesLink` per
   item, pointing at the releases page (Phase 3).
7. [ ] **End-to-end update test (local).** Build 0.2.0 (build 2) with SUFeedURL
   overridden to `http://localhost:8000/appcast.xml` in the test bundle's plist,
   install to /Applications on the test account, then publish 0.2.1 (build 3) to a
   local `python3 -m http.server` appcast. Confirm: prompt appears, update installs,
   app relaunches as 0.2.1. Sparkle compares `CFBundleVersion` — the monotonic build
   number is the load-bearing field.

Verify (release-blocking): install version N on the clean machine, publish N+1 to the
real feed, confirm the in-app prompt appears and the update installs and relaunches.

Open implementation questions to resolve while building (not blockers):
- Exact artifact path/layout of Sparkle's SPM binary + bundled tools on this SwiftPM
  version — discover at step 2 and pin in the scripts.
- Whether `swift build` needs `--disable-sandbox` quirks for the binary target (no
  indication it will; check on first build).

## Phase 3 — Website download

- [ ] Create the public releases repo (suggestion: `dylanreedx/array-releases`): DMGs as
      GitHub Release assets, release notes as the release body.
- [ ] Download button on `website/src/pages/index.astro`: hero + nav CTA →
      `https://github.com/dylanreedx/array-releases/releases/latest/download/Array.dmg`
      (stable "latest" URL, no per-release site edits).
- [ ] Requirements line under the button: macOS 14+, Apple Silicon; works with Claude
      Code and Codex CLI; needs tmux (see Phase 4 audit — bundle or document it).
- [ ] Keep a "something broken? request access to the group?" link — repoint the existing
      GitHub-issue CTA at the public releases repo's issues.
- [ ] `website/public/appcast.xml` + a minimal `/releases` (or changelog) page fed from
      the same release notes, so "what's new" has a URL.

## Phase 4 — Onboarding + CLI connect/verify

Priority order — the first item is a bug fix that gates everything else:

- [ ] **Fix claude/codex binary resolution.** Resolve via login-shell PATH
      (`$SHELL -ilc`, pattern already in `AgentSupervisor.swift:351`) plus well-known
      fallback dirs (pattern in `PiAgentRunner.swift` / `TmuxSession.swift:174`), cache
      the result, and pass the augmented PATH to spawned tiles in `TileSpawner.swift`.
      Applies to `LaunchProfileRegistry` `.tool` resolution generally.
- [ ] **Dependency audit for a fresh Mac:** tmux is the big one — decide bundle vs
      detect-and-guide (`brew install tmux`). Sweep for other host assumptions (fonts,
      `git`, node for any sidecar).
- [ ] **First-run window** (net-new; shown when no prior state exists):
      1. Welcome + one-paragraph "what Array is".
      2. Environment check with live re-check button: claude ✓/✗, codex ✓/✗, tmux ✓/✗ —
         each ✗ gets install guidance (copy-paste command), not a dead end. Reuse
         `ToolDetector` results; both CLIs optional but at least one encouraged.
      3. Connect/verify: open a real terminal tile per detected CLI so its own
         login/auth flow runs inside Array (`claude` and `codex` handle their own auth;
         v0 does not re-implement auth detection — the honest check is "does the CLI
         start and talk").
      4. Claude notification-hook consent (ticket 42 machinery already exists — this
         becomes its natural home).
      5. Done → drop into a starter workspace.
- [ ] Replace the bare "claude not found on $PATH" restart-placeholder and disabled
      palette rows with a pointer into the environment-check UI.
- [ ] Feedback channel in-app: Help menu → "Report a problem" → public repo issue URL.

## Phase 5 — Release runbook + QA gate

- [ ] Write `RELEASE.md`: bump versions → `scripts/run-matrix.sh` gate →
      `release-app.sh` (build/sign/notarize/staple/DMG) → `generate_appcast` → upload
      release + publish appcast → **update-from-previous-version test on the clean
      machine** → announce to friends.
- [ ] First release through the full pipeline is v0.2.0 build 2.
- [ ] CI (GitHub Actions + certs in secrets) is explicitly deferred until manual releases
      hurt.

## Open decisions

1. Dylan's machine: migrate state or clean cut? (Phase 0; recommendation: clean cut.)
2. arm64-only vs universal for v0? (Phase 1; recommendation: arm64-only, stated on site.)
3. tmux: bundle it or detect-and-guide? (Phase 4; needs a spike on bundling feasibility.)
4. Releases repo name (`array-releases` vs other) — trivial but blocks Phase 3 URLs.

## Non-goals for v0 (explicit)

- CloudKit sync, iOS companion, APNS, small-team relay (queue 92 stays paused, STOP intact).
- Full internal rebrand (module renames) — separate project, slice-by-slice, per the
  18016ea9 plan and `array-rename-two-projects` memory.
- App Store distribution / sandboxing.
- CI/CD automation.

## Order and rough effort

Phases are strictly ordered 0 → 1 → 2 → 3 → 4 → 5; 3 and 4 can overlap once 2 is done.

| Phase | Work | Rough effort |
|---|---|---|
| 0 | External identity cut | 1–2 days |
| 1 | Developer ID + notarization pipeline | ~1 day once cert exists |
| 2 | Sparkle 2 | ~1 day (framework-embedding fiddliness included) |
| 3 | Website download + appcast hosting | ~half day |
| 4 | PATH fix + first-run onboarding | 2–4 days |
| 5 | Runbook + clean-machine verification | ~half day |

Total: about a week of focused work to a v0 friends can download, install cleanly, and
auto-update.

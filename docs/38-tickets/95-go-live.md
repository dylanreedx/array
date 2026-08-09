# 95 — Go-live: first external release (friends alpha)

Status as of 2026-08-09 (end of day):

- **Phase 0 (identity) DONE · Phase 1 (sign/notarize) DONE · Phase 3 (downloads) DONE
  except the appcast (Phase 2 coupling).**
- **Array 0.2.0 (build 2) is live**: notarized + stapled DMG published at
  `dylanreedx/array-releases` release v0.2.0; stable URL
  `https://github.com/dylanreedx/array-releases/releases/latest/download/Array.dmg`
  (asset name is constant across releases — never version it).
- **arrayapp.dev serves the Download button** (hero/nav/access + report-a-problem →
  array-releases issues). Vercel deploys from `dylanreedx/continuum` branch `main`;
  local work happens on `array/integration` and fast-forwards to main.
- Also landed 2026-08-09, outside the original plan: merged the 42-commit managed-agent
  tile production wiring (shared prefix of the `agent/luna-max-implementer-20260809*`
  branches — their three divergent live-tile-prototype TIP commits remain unmerged,
  awaiting Dylan's review); fixed status/context "unknown" via supervisor seeding
  (`contextWindowSnapshot(for:)` seam, telemetry persisted on `AgentRecord`,
  authoritative 0% for zero-turn sessions); finished the identity tail
  (`array-agent-` Pi session ids, check expectations).
- **Verification state**: full build, bundle harness, CoreChecks suite, geometry,
  supervisor/restore/tmux/topology legs all green. Two KNOWN-RED gates, both
  pre-existing (verified failing at pre-work HEAD `566e615`): `--component-lab-check`
  pixel baselines (36 stale; integration waves ran `CONTINUUM_SKIP_SURFACE_CHECKS=1`;
  needs a supervised re-bless with Dylan reviewing diffs) and the
  `--agent-supervisor-check` NAMING section (timing flake, three distinct failure
  messages across runs; the context-seam assertions behind it run once naming is
  fixed — the standalone CoreChecks suite covers the rest).
- **Phase 2 (Sparkle) DONE (2026-08-09, evening)** — implemented and proven end-to-end
  locally: a 0.2.0(2) test install fetched a localhost appcast, EdDSA-validated,
  downloaded the 0.2.1(3) DMG, and swapped the bundle on quit (signature intact after
  swap). Auto-update goes LIVE with the first real 0.2.1 release: publish the DMG,
  run `scripts/generate-appcast.sh`, ship `website/public/appcast.xml`. 0.2.0 users
  make one final manual download; from 0.2.1 on, updates arrive in-app.
- **Phase 4 (PATH fix + onboarding) DONE (2026-08-09, late evening)** — thin-GUI-PATH
  resolution fixed (ToolSearchPath/ToolEnvironment), dependency audit recorded,
  first-run onboarding panel + Help menu (Environment Setup…, Report a Problem…)
  shipped; ticket-42 hook consent deferred (machinery not built yet — correction to
  the plan, which assumed it existed).
- **Array 0.2.1 (build 3) SHIPPED (2026-08-09, evening)** — first appcast-backed
  release; auto-update is LIVE. Notarized + stapled, spctl-clean; v0.2.1 on
  array-releases with both assets (public download verified byte-identical);
  `https://arrayapp.dev/appcast.xml` serving the signed item. Update PROMPT UX
  verified by Dylan on the local feed (prompt → install → relaunch) before shipping.
  0.2.0 installs make one final manual download.
- Remaining: Phase 5 clean-machine pass (fresh install of 0.2.1 from the site on a
  second machine/account — witnesses Gatekeeper, first-run onboarding on a truly
  fresh profile, and the next release's update against the real feed).

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

## Current state (audited 2026-08-09, morning — HISTORICAL; see status above)

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

## Phase 2 — Sparkle 2 auto-update — DONE (2026-08-09, commit 8e3e890)

The two repo-specific constraints that shaped it: the bundle is hand-assembled by
`make-app-bundle.sh` (no Xcode embed phase), and the QA matrix runs the **bare**
binary, where an updater must stay inert.

1. [x] **Keys.** Generated via the artifact's `generate_keys`. Private EdDSA key lives
   ONLY in the login Keychain ("Private key for signing Sparkle updates"). Public key
   `o3eIWuneUYLaNxzh0Z1A8NSAPBnTINnpqprZQLennHE=` is in Info.plist. **Never in the
   repo.** BACKUP still owed by Dylan (Keychain export or `generate_keys -x`) —
   losing it strands every installed copy on its version.
2. [x] **Dependency.** Sparkle 2.9.5 via SPM, app target only. Artifact layout
   (pinned in scripts): `.build/artifacts/sparkle/Sparkle/bin/` (generate_keys,
   generate_appcast, sign_update) + `…/Sparkle.xcframework/macos-arm64_x86_64/`.
   No build quirks; SwiftPM copies the framework next to the bare binary and
   `@loader_path` resolves it, so the QA matrix runs unchanged.
3. [x] **Info.plist.** `SUFeedURL` = `https://arrayapp.dev/appcast.xml` +
   `SUPublicEDKey`. `SUEnableAutomaticChecks` stays UNSET (Sparkle asks on second
   launch) — check-app-bundle.sh FAILS if it ever appears in the plist.
4. [x] **Code wiring.** One gated `SPUStandardUpdaterController` in
   `ContinuumApp.main()` + `updaterPermitted()`: bundle id must be
   `dev.arrayapp.macos`, no `--` argument (covers every self-check flag and the
   launch probe), no `CONTINUUM_APP_SUPPORT`/`CONTINUUM_SMOKE_TEST`/
   `CONTINUUM_QA_FLOW`/`CONTINUUM_COMPONENT_SNAPSHOT` env. "Check for Updates…" in
   the app menu (target: controller; nil target in QA runs = item visible but
   disabled); `runMenuContractSelfCheck` asserts item + selector + inert target.
5. [x] **Bundle embedding.** `make-app-bundle.sh` dittos the framework into
   `Contents/Frameworks/`, adds the `@executable_path/../Frameworks` rpath, then
   re-signs ad hoc (install_name_tool invalidates the linker signature; arm64 won't
   launch otherwise). `check-app-bundle.sh` asserts framework binary, both XPC
   services, Updater.app, Autoupdate, the rpath, and the SUFeedURL/SUPublicEDKey
   keys; the launch smoke proves the rpath behaviorally. `release-app.sh` DID need
   changes: `Autoupdate` is a bare executable the `find` pattern missed, and the
   XPC services need `--preserve-metadata=entitlements` to keep their sandbox
   entitlements across re-signing.
6. [x] **Appcast in the release flow.** `scripts/generate-appcast.sh`: local flat
   `releases/` archive dir (gitignored — starts at the first Sparkle-capable
   version; back it up) → `generate_appcast` (signs with the Keychain key;
   headless Keychain access confirmed working) → canonical `releases/appcast.xml`
   → rewrite step gives each enclosure its per-version URL
   `…/releases/download/v<ver>/Array-<ver>.dmg` + `sparkle:releaseNotesLink` to the
   GitHub release tag → `website/public/appcast.xml` (deploys with the site).
   Per-item rewrite exists because `--download-url-prefix` is global while GitHub
   URLs embed the tag.
7. [x] **End-to-end update test (local, 2026-08-09).** 0.2.0(2) test install
   (SUFeedURL → `http://localhost:8000/appcast.xml`, isolated HOME, real Developer
   ID signature, unnotarized) against a `python3 -m http.server` feed advertising
   0.2.1(3): appcast fetched, EdDSA validated, DMG downloaded, install staged,
   bundle swapped to 0.2.1(3) on quit with signature intact and the real feed URL
   in place. Sparkle compares `CFBundleVersion` — the monotonic build number is
   the load-bearing field.

Verify (release-blocking, still owed — belongs to Phase 5's clean-machine pass):
install version N on the clean machine, publish N+1 to the real feed, confirm the
in-app PROMPT appears (the local proof ran the silent-auto path) and the update
installs and relaunches.

Traps learned (do not re-derive):
- **cfprefsd ignores HOME/CFFIXED_USER_HOME for the standard defaults domain**:
  a test instance launched with an isolated HOME still reads/writes the REAL
  `dev.arrayapp.macos` preferences (Caches/app-support do follow HOME). So Sparkle
  state (SULastCheckTime, SUHasLaunchedBefore, permission answers) is shared
  per-user regardless of HOME isolation, and `defaults write <abs path>` writes to
  the real domain too. The updater gate's env/arg checks are the load-bearing QA
  isolation — never rely on HOME for prefs.
- `generate_appcast` re-uses an existing appcast.xml in the archives dir and only
  appends new items; the site copy is always regenerated from the canonical one.

## Release runbook (v2, appcast era) — supersedes the Phase 1 command alone

1. `scripts/release-app.sh --identity "Developer ID Application: Dylan Reed
   (46TTB6J9DZ)" --notary-profile array-notary --set-version <X.Y.Z> --set-build <N>`
   (build number MUST increase every release — Sparkle compares CFBundleVersion).
2. Copy the stapled `Array-<X.Y.Z>.dmg` into `releases/`.
3. `gh release create v<X.Y.Z>` on `dylanreedx/array-releases` with release notes and
   BOTH assets: `Array.dmg` (constant name — the site's latest-URL depends on it) and
   `Array-<X.Y.Z>.dmg` (appcast permalink).
4. `scripts/generate-appcast.sh` → commit `website/public/appcast.xml` → push `main`
   (Vercel deploys the feed).
5. Spot-check: `curl https://arrayapp.dev/appcast.xml` shows the new item; installed
   previous version sees the update.

## Phase 3 — Website download — DONE (2026-08-09) except appcast

- [x] Public releases repo `dylanreedx/array-releases` created; v0.2.0 published with
      release notes and TWO assets: `Array.dmg` (stable name — the latest-download URL
      depends on it staying constant) and `Array-<version>.dmg` (permalink for the
      future appcast). Download verified byte-identical to the notarized artifact.
- [x] Download button live on arrayapp.dev: hero + nav + access CTAs →
      `https://github.com/dylanreedx/array-releases/releases/latest/download/Array.dmg`.
- [x] Requirements line under the hero button (macOS 14+ · Apple Silicon · free while
      in alpha). tmux bundling/guidance still owned by Phase 4's audit.
- [x] "Report a problem" → array-releases issues (code repo stays private).
- [~] `website/public/appcast.xml`: machinery done (Phase 2 step 6,
      `scripts/generate-appcast.sh`); the file itself ships with the first
      appcast-backed release (0.2.1). "What's new" URLs point at the GitHub release
      tags via `sparkle:releaseNotesLink`, so a site `/releases` page is optional.

## Phase 4 — Onboarding + CLI connect/verify

Priority order — the first item is a bug fix that gates everything else:

- [x] **Fix claude/codex binary resolution** — DONE (2026-08-09). `ToolSearchPath`
      (Core, pure, pinned in CoreChecks) + `ToolEnvironment` (app): synchronous
      bootstrap setenvs well-known install dirs onto PATH before the first
      `ProcessInfo.environment` read (NSProcessInfo caches on first access — that
      ordering is load-bearing), so Ghostty ptys/tmux/Process children inherit the
      fix; a bounded 1s `$SHELL -ilc` probe upgrades to the login-shell PATH after
      launch. TileSpawner resolves through an injectable `environmentProvider` seam.
      Witness: `--tool-path-bootstrap-check` (in check-app-bundle.sh).
- [x] **Dependency audit for a fresh Mac** — DONE (2026-08-09). Hard deps: none
      beyond stock macOS (zsh ships, GhosttyKit statically linked, no custom fonts,
      no direct node spawns). Soft deps, all detect-and-guide via the first-run
      window (no bundling in v0):
      - tmux → terminal-session persistence only; missing tmux currently degrades
        SILENTLY (`TileSpawner.tmuxWrappedProfileIfAvailable`) — surface it in the
        env check. Guidance: `brew install tmux`. (ISC license would allow bundling
        later if guiding annoys.)
      - git → file tree status, diff review, agent worktrees. Fresh Macs have the
        /usr/bin/git CLT shim: first invocation pops the Xcode CLT dialog. Detect
        with `xcode-select -p` (doesn't trigger the dialog); guide to CLT install.
      - claude / codex → optional, at least one encouraged; auth runs inside the
        CLI in a real tile. nvim → optional editor profile.
      - node → not standalone: npm-installed CLIs reach it via their own dirs
        (nvm/volta/bun), which the PATH augmentation covers.
- [x] **First-run window** — DONE (2026-08-09), `OnboardingPanel.swift`. Shown once
      on a fresh profile (empty registry at boot + `continuum.onboarding.shown`
      defaults gate), reopenable via Help → Environment Setup…. Welcome paragraph;
      environment check with live Re-check (claude/codex via augmented PATH, tmux
      via TmuxLocator, git via a CLT presence probe that avoids the Xcode dialog);
      per-CLI "Open a tile" buttons spawn real terminal tiles for the CLI's own
      auth flow. Witness: `--onboarding-panel-check` (matrix-registered; PNG
      artifact under qa-runs/). QA env gate keeps it out of isolated QA profiles.
      CORRECTION to the original plan: ticket 42's hook-consent machinery does NOT
      exist yet (only the status-engine consumer half does) — the consent step is
      deferred until ticket 42 builds the installer/consent store; it slots into
      this panel then.
- [x] Missing-command alert now offers "Environment Setup…" (opens the panel)
      instead of the bare dead end. The restart-placeholder tile text itself is
      unchanged (placeholder-level pointer can follow if it matters in practice).
- [x] Feedback channel in-app — DONE (2026-08-09): Help → Report a Problem… →
      array-releases issues; menu-contract-pinned along with Environment Setup….

## Phase 5 — Release runbook + QA gate

- [x] `RELEASE.md` written (2026-08-09): version bump → release-app.sh →
      archive DMG to `releases/` → gh release (both assets) → generate-appcast.sh →
      commit appcast + push main → spot-checks. (v0.2.0 build 2 already went through
      the pre-appcast pipeline.)
- [ ] **Clean-machine pass (release-blocking, needs a second machine/account):**
      fresh install of version N via the site download, then publish N+1 to the real
      feed and confirm the in-app update PROMPT appears, installs, and relaunches
      (the local Phase 2 proof ran the silent-auto path). Also witnesses first-run
      onboarding on a genuinely fresh profile.
- [ ] CI (GitHub Actions + certs in secrets) is explicitly deferred until manual releases
      hurt.

## Dev/prod channel split — DONE (2026-08-09, post-0.2.1)

The prod copy in /Applications must never share state with dev builds or
agent-driven runs. macOS keys prefs and identity off the bundle id, so the
channel IS the bundle id (`AppChannel` in Core, mappings pinned in CoreChecks):

- **Prod** = exactly `dev.arrayapp.macos` → "Array" app-support dir, prod
  defaults domain, updater eligible. ONLY `release-app.sh` (and the two
  CloudKit dogfood scripts, whose container is bundle-id-tied) produce
  prod-identified bundles.
- **Dev** = everything else — `make-app-bundle.sh` default output (stamped
  `dev.arrayapp.macos.dev`, named "Array Dev") AND the bare `swift build`
  binary (nil bundle id) → "Array Dev" app-support dir, `.dev` defaults
  domain, updater inert (its gate requires the exact prod id).
- The `bundledDefaultsDomain` fallbacks (DeleteConfirmPolicy,
  TerminalSpawnAdmission, BrowserRuntimeBudget) are channel-scoped — a dev
  build can no longer read or leak into prod preferences.
- QA env overrides (`CONTINUUM_APP_SUPPORT` etc.) still win over everything.
- Witness: `--app-support-channel-check` (bare-binary leg in run-matrix.sh;
  per-channel leg in check-app-bundle.sh, which now takes `--channel` and
  asserts identity accordingly and pollution-guards BOTH channels' real dirs).
- Accepted sharing (documented, revisit if it bites): Keychain items
  (password vault, companion session), `~/.continuum` hook/breadcrumb paths,
  the per-user tmux server (separate registries mean each channel only
  reconciles its own sessions; names are UUID-suffixed).
- To seed a dev build with a copy of real state (deliberate act, never
  automatic): `cp -R ~/Library/Application\ Support/Array ~/Library/Application\ Support/Array\ Dev`.

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

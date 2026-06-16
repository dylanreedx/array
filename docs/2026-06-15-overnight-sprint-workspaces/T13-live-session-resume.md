# T13 — Live-session resume: terminal cwd + scrollback, browser `interactionState`

Status: todo
Tag: overnight
Depends on: T12 (bulletproof restore — debounced atomic autosave + crash-safe reload) · Blocks: —

## Goal
Make restored sessions *resumable*, not just re-laid-out. After a quit/reboot/relaunch a
terminal tile re-opens a **fresh shell in the same cwd** with its **scrollback restored
(display-only)**, and a browser tile restores its full WebKit `interactionState`
(back/forward history + scroll position + form field state) — not just the URL. The
honest ceiling: **no live PID survives a quit** (the shell is fresh; the WKWebView is
fresh). This is still "unlike tmux" because it survives a cold reboot from disk.

## Exact scope — files & symbols
- **`Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift`** — add an **optional
  scrollback snapshot** field to the persisted descriptor: `scrollback: String?` (the
  display-only text snapshot captured at flush; nil = none). Bump
  `TerminalSessionDescriptor.currentSchemaVersion` 1 → 2; decode v1 with
  `decodeIfPresent` (→ nil). `restoredForBoot()` keeps `scrollback` as-is. NOTE:
  `cwd` already exists on the descriptor — T13 does NOT add it, it makes the restore path
  *honor* it (see below).
- **`Sources/ContinuumRevivedCore/BrowserState.swift`** — add an **optional**
  `interactionState: Data?` field to `BrowserTile` (the opaque `WKWebView.interactionState`
  blob, base64-coded by `Codable` Data). Bump `BrowserState.currentSchemaVersion` 1 → 2;
  decode v1 with `decodeIfPresent` (→ nil) in the existing custom `init(from:)`; add the
  key to `CodingKeys`. Memberwise `init` gets `interactionState: Data? = nil`.
- **`Sources/ContinuumRevived/App/TileSpawner.swift`**
  - `restartTerminalTile(tileId:)` (~:252) — on restore, **prefer the persisted
    descriptor's `cwd`** over the registry-resolved project-root cwd, and after the fresh
    runtime attaches, **rehydrate the saved `scrollback`** (mechanism: see NEEDS-HUMAN
    gotcha — likely an echo-banner replay through the real shell, gated behind the new
    config). Persist the descriptor back with the carried-forward `cwd`.
  - `writeBrowserTileSnapshotOrThrow(for:)` (~:908) — capture
    `runtime.webView.interactionState` and pass it through to the persisted `BrowserTile`.
  - `upsertBrowserTile(...)` (~:854) — thread an `interactionState: Data?` param into the
    `BrowserTile` it creates/updates.
  - `restartBrowserTile(tileId:)` (~:554) — after creating the fresh runtime, **apply the
    persisted `interactionState`** to the new `WKWebView` (preferring it over a bare
    `loadURL` when present) via a new `WKWebViewBrowserRuntime` restore entry point.
- **`Sources/ContinuumRevived/BrowserEngine/WKWebViewBrowserRuntime.swift`** — add
  `func restoreInteractionState(_ data: Data)` that assigns `webView.interactionState`
  (macOS 12+; the property is non-optional `Any?` typed `interactionState`) and a read
  accessor `var capturedInteractionState: Data?` returning
  `webView.interactionState as? Data`. (WebKit returns/accepts an opaque, archivable
  value; round-trips as `Data`.)
- **`Sources/ContinuumRevived/TerminalEngine/GhosttyTerminalRuntime.swift`** — add the
  scrollback **capture** accessor `var capturedScrollback: String { visibleText() }`
  (reuses the existing `ghostty_surface_read_text` path) and a **replay** entry point
  `func replayScrollback(_ text: String)` whose mechanism is the NEEDS-HUMAN decision
  below. Reuse the existing snapshot infra (`dehydrateForSnapshot`/`rehydrateFromSnapshot`,
  `visibleText()`) — do not invent a parallel snapshot system.
- **`Sources/ContinuumRevivedCore/SessionResumeConfig.swift`** (NEW, Core) — the
  configurable-first knob (mirrors `DragMagnetizeConfig`/`TileGapResolver`): persist a
  `UserDefaults` toggle `continuum.sessionResume.scrollback.enabled` (default `true`) and
  a max-lines cap `continuum.sessionResume.scrollback.maxLines` (default `2000`) so the
  scrollback snapshot is bounded. Static resolvers `scrollbackEnabled(defaults:)`,
  `scrollbackMaxLines(defaults:)`.
- **`Sources/ContinuumRevivedCore/SettingsSchema.swift`** — append two `General`-section
  fields bound to those exact keys (`.toggle` for enabled, `.text` for maxLines). This is
  the "Settings entry" half of configurable-first.
- **`scripts/run-matrix.sh`** + **`Sources/ContinuumRevived/App/ContinuumApp.swift`** arg
  dispatch — register the new `--session-resume-check`.

- **Do NOT touch:**
  - The atomic/debounce autosave layer from **T12** — build *on* it (T13 persists *into*
    the descriptors/BrowserState that T12 flushes; it does not re-implement debounce).
  - Profiles/snapshots (**T14**).
  - Any attempt to keep a real PID / live process alive across quit — out of scope, the
    honest ceiling. `terminate(policy:)` still kills the old PID; restore launches a new
    shell.
  - `WorkspaceDocument` / `ZonePlacement` (T01) and group-zone tile storage (T02).
  - The 4 window-scoped NSEvent monitors; `CanvasEngine` transforms; FocusBroker.
  - The in-process `--terminal-snapshot-tier-check` (same-PID dehydrate/rehydrate) — that
    is a different tier (live snapshot, PID kept) and must stay green unchanged.

## Data / API changes
```swift
// TerminalSessionDescriptor.swift
public static let currentSchemaVersion = 2          // was 1
public var scrollback: String?                      // NEW; nil = no snapshot
// memberwise init gains: scrollback: String? = nil
// decode: scrollback = try container.decodeIfPresent(String.self, forKey: .scrollback)
// (encode always writes scrollback at schema 2; restoredForBoot() preserves it)

// BrowserState.swift — on BrowserTile
public static let currentSchemaVersion = 2          // on BrowserState; was 1
public var interactionState: Data?                  // NEW; nil = none
// memberwise init gains: interactionState: Data? = nil
// CodingKeys gains: case interactionState
// init(from:): interactionState = try container.decodeIfPresent(Data.self, forKey: .interactionState)

// WKWebViewBrowserRuntime.swift
func restoreInteractionState(_ data: Data)          // webView.interactionState = data
var capturedInteractionState: Data? { webView.interactionState as? Data }

// GhosttyTerminalRuntime.swift
var capturedScrollback: String { visibleText() }
func replayScrollback(_ text: String)               // mechanism = NEEDS-HUMAN (gotcha)

// SessionResumeConfig.swift (NEW)
public enum SessionResumeConfig {
    public static let scrollbackEnabledKey = "continuum.sessionResume.scrollback.enabled"
    public static let scrollbackEnabledDefault = true
    public static let scrollbackMaxLinesKey  = "continuum.sessionResume.scrollback.maxLines"
    public static let scrollbackMaxLinesDefault = 2000
    public static func scrollbackEnabled(defaults: UserDefaults = .standard) -> Bool { … }
    public static func scrollbackMaxLines(defaults: UserDefaults = .standard) -> Int { … }
}
```

## The check, written FIRST (spec-as-test) — `--session-resume-check`
NEW app check. Register in `scripts/run-matrix.sh` (after `--terminal-snapshot-tier-check`,
near the other persistence checks) AND in the `CommandLine.arguments` dispatch in
`ContinuumApp.swift` (~:494–800, model on `--browser-restore-state-check`). Live as a
static `AppDelegate.runSessionResumeSelfCheck() throws -> URL` (writes a
`qa-runs/<ts>/session-resume/manifest.json` artifact) so it reaches `TileSpawner`'s
internals exactly like `runBrowserRestoreStateSelfCheck`. It drives the **real production
restore handlers** — `TileSpawner.restartTerminalTile` / `restartBrowserTile` and the real
persist path `writeBrowserTileSnapshotOrThrow` — through a real `ProjectStore` on a temp
dir, with a real `GhosttyRuntimeContext` for the terminal half (same harness the
terminal-snapshot check uses: construct context, attach to a real `TerminalHostView` in an
`NSWindow`, `ghostty_app_tick` the run loop until output appears). It MUST NOT call a pure
helper or assemble the descriptor by hand and assert on that — it persists, **reloads
through `ProjectStore.loadSession` / `loadBrowserState`**, and restarts through the real
spawner, then asserts observable post-restore state.

### Part A — Terminal cwd + scrollback resume (real Ghostty path)
Seed: a temp project root with a child dir `sub/` that exists. Spawn a terminal via the
real spawner / runtime in `projectRoot`, tick until a ready sentinel prints, then drive a
real `cd sub` + a `printf 'con13-line\n'` through `runtime.sendInput`, tick until both the
new cwd and the sentinel are visible. Trigger the real persist (the descriptor flush path
that writes `cwd` + `capturedScrollback`). Read the on-disk descriptor back via
`store.loadSession(id:)`. Then **terminate the old runtime** (old PID dies) and call the
real `restartTerminalTile(tileId:)`; tick the new runtime; capture its `visibleText()` and
its working directory (printf `pwd` into the fresh shell + tick until it prints).
Assertions:
1. **Persisted cwd is the post-`cd` dir:** `store.loadSession(id:).cwd` == `<projectRoot>/sub`
   (NOT the project root) — proves the flush captured the *live* cwd, not the launch cwd.
2. **Persisted scrollback present & bounded:** `descriptor.scrollback != nil`,
   `descriptor.scrollback!.contains("con13-line")`, and its line count
   `<= SessionResumeConfig.scrollbackMaxLines` (default 2000).
3. **Schema migration:** decoding a **hand-written v1 descriptor JSON literal**
   (`schemaVersion:1`, no `scrollback` key) yields `scrollback == nil` and a valid load
   (proves old session files still load).
4. **Old PID is dead:** the pre-restore runtime's `isProcessExitedForSnapshotCheck` ==
   true after `terminate(policy: .force)` (the honest ceiling: no live PID survived).
5. **Fresh shell, same cwd:** after `restartTerminalTile`, the new runtime is a **distinct
   instance** (`newRuntime.id != oldRuntime.id`) and its live `pwd` resolves to
   `<projectRoot>/sub` — proving the fresh shell opened in the persisted cwd, not the
   project root.
6. **Scrollback restored (display):** after restore the new runtime's `visibleText()`
   contains `con13-line` (the saved scrollback line is on screen) — driven by the real
   `replayScrollback`, NOT by reading the descriptor field directly. (See NEEDS-HUMAN
   gotcha: if the replay mechanism is undecided this assertion is the one that may need a
   human design call; the rest of Part A stands without it.)
7. **Config gate honored:** with `continuum.sessionResume.scrollback.enabled = false` in a
   second temp run, `restartTerminalTile` does NOT replay scrollback (new `visibleText()`
   does not contain `con13-line`) yet the cwd still restores (assertion 5 still holds) —
   proves the toggle is wired through the real path, not hardcoded.

### Part B — Browser `interactionState` resume (real WKWebView path)
Seed (mirror `runBrowserRestoreStateSelfCheck`): a `ProjectStore` on a temp root, a
`CanvasState` with one `.browser` tile, a `BrowserState` entry with a `data:` URL that has
a form input. Restart it live via the real `restartBrowserTile`, drive a navigation (load
a second `data:` URL so back-history exists) + set a scroll offset / form value, then call
the real persist path `writeBrowserTileSnapshotOrThrow(for: runtime)`. Reload via
`store.loadBrowserState()`, terminate the runtime, and `restartBrowserTile` again to get a
**fresh** WKWebView, applying the persisted `interactionState`. Assertions:
8. **interactionState captured:** the post-persist `BrowserTile.interactionState != nil`
   and is non-empty `Data` — proving the real persist path captured the WebKit blob.
9. **Schema migration:** decoding a **hand-written v1 BrowserTile JSON literal** (no
   `interactionState` key) yields `interactionState == nil` and loads cleanly.
10. **interactionState applied to fresh view:** after the second `restartBrowserTile`, the
    new runtime is a distinct instance (`newRuntime.id != oldRuntime.id`) and
    `newRuntime.capturedInteractionState != nil`, i.e. `webView.interactionState` was set
    from the persisted blob (probe: after applying + a run-loop tick,
    `webView.canGoBack == true` because the restored history has a back entry — observable
    proof the session, not just the URL, was restored). If `canGoBack` proves flaky in the
    headless harness, fall back to asserting the applied blob round-trips:
    `newRuntime.capturedInteractionState` decodes to the same back/forward depth as the
    saved one.
11. **No live process survived:** the pre-restore browser runtime's `webView` is a
    different object than the post-restore runtime's `webView` (`!==`) — fresh WKWebView,
    no carried-over process.
12. **URL still restored (regression guard):** `newRuntime.url` is the last-committed URL
    from the persisted state (the `interactionState` path does not regress the existing
    URL-restore the `--browser-restore-state-check` guards).

### Part C — Config / Settings wiring
13. **Settings schema entry exists:** `SettingsSchema.sections()` contains a field whose
    `key == SessionResumeConfig.scrollbackEnabledKey` and one whose
    `key == SessionResumeConfig.scrollbackMaxLinesKey` (proves the configurable-first
    Settings half is registered, mirroring how the settings-panel-check inspects schema).
14. **Default resolution:** with no UserDefaults override (use a throwaway
    `UserDefaults(suiteName:)`), `SessionResumeConfig.scrollbackEnabled() == true` and
    `scrollbackMaxLines() == 2000`; with the key set to `false`/`50`, the resolvers return
    the override (proves the default + override path — the "conflict-guard"-equivalent for
    a non-keybinding numeric setting: the resolver is the single source of truth, no
    second hardcoded literal).

Run it → **RED**: it fails to compile (missing `scrollback` / `interactionState` /
`SessionResumeConfig` / restore entry points) — that is the model-shaped RED. The
*behavioral* RED is assertions 1 (cwd today resolves to project root, not the post-`cd`
dir), 6, 8, and 10 (no capture/replay exists). Implement to GREEN.

## Implementation steps
1. Write `--session-resume-check` (Parts A/B/C, all 14 assertions) as
   `AppDelegate.runSessionResumeSelfCheck`; register in `run-matrix.sh` + the arg dispatch.
   Run → confirm RED on the assertions (not just a stray compile error after stubs land).
2. Add `scrollback: String?` to `TerminalSessionDescriptor` (+ schemaVersion 2 +
   `decodeIfPresent`); add `interactionState: Data?` to `BrowserTile` (+ BrowserState
   schemaVersion 2 + `decodeIfPresent` + CodingKeys). Update every construction site the
   compiler flags (grep `TerminalSessionDescriptor(` and `BrowserTile(` — pass `nil`
   default at sites that don't carry it). **RED→GREEN boundary** for the migration
   assertions (3, 9) is right after this step.
3. Add `SessionResumeConfig.swift` + the two `SettingsSchema` fields (assertions 13, 14
   GREEN here).
4. Add `WKWebViewBrowserRuntime.restoreInteractionState` + `capturedInteractionState`;
   thread `interactionState` capture into `writeBrowserTileSnapshotOrThrow` →
   `upsertBrowserTile`, and apply in `restartBrowserTile`. (assertions 8, 10, 11, 12.)
5. Add `GhosttyTerminalRuntime.capturedScrollback` + `replayScrollback`; in
   `restartTerminalTile`, prefer the persisted descriptor's `cwd` over the resolved
   project-root cwd when building the `LaunchProfile`, persist the carried cwd back, and
   replay scrollback gated by `SessionResumeConfig.scrollbackEnabled`. (assertions 1, 5,
   6, 7.) **This is the behavioral GREEN for the terminal half.**
6. `swift build` → run `--session-resume-check` GREEN → run the **full** matrix (this
   touches persistence + the browser/terminal restore paths): especially
   `--browser-restore-state-check`, `--terminal-snapshot-tier-check`,
   `--browser-profile-persistence-check`, `--settings-panel-check`, and (if T12 landed)
   `--persistence-crash-safe-check`. None may regress.

## Acceptance criteria
- [ ] All 14 assertions pass through the real spawner/runtime/store path (no bypass).
- [ ] Terminal resumes in the **persisted post-`cd` cwd**, fresh shell, old PID dead.
- [ ] Terminal scrollback persisted (bounded by maxLines) and replayed when enabled;
      suppressed when the toggle is off — both proven via the real path.
- [ ] Browser `interactionState` captured on the real persist path and applied to a fresh
      WKWebView on restore; URL restore not regressed.
- [ ] v1 session + v1 browser docs still load (migration assertions green).
- [ ] `SessionResumeConfig` has UserDefaults defaults + SettingsSchema entries; resolvers
      are the single source of truth.
- [ ] Full matrix green; `--browser-restore-state-check` + `--terminal-snapshot-tier-check`
      unchanged-green. Commit `feat(persistence): resumable session state — terminal cwd+scrollback, browser interactionState`.

## Verification commands
```
swift build
P=$(mktemp -d); A=$(mktemp -d); CONTINUUM_PROJECT_ROOT=$P CONTINUUM_APP_SUPPORT=$A \
  .build/debug/continuum-revived --session-resume-check; rm -rf "$P" "$A"
swift run ContinuumRevivedCoreChecks    # descriptor/BrowserState round-trip + config defaults
./scripts/run-matrix.sh                 # full, not --fast — this touches persistence + restore
```

## Review rubric
- **Bypass audit (critical):** the check must (a) **reload through `ProjectStore`** between
  persist and restore (not reuse the in-memory descriptor), and (b) restore through the
  **real `restartTerminalTile`/`restartBrowserTile`**. If it constructs the post-restore
  state by hand or asserts on a pure helper's return, REWORK.
- **cwd assertion is the bug-magnet:** assertion 1 must be `<projectRoot>/sub`, NOT the
  project root — and assertion 5 must read the *live* `pwd` of the fresh shell (printf +
  tick), not just re-read the descriptor field. Reverting step 5's cwd-preference line
  must turn assertion 5 RED (the old code resolves to project root).
- **Honest-ceiling assertions present:** old PID dead (4), fresh WKWebView object (11) —
  a check that quietly keeps the old runtime alive is a FAIL (it would be lying about the
  ceiling).
- **interactionState is real, not URL-only:** assertion 10 must prove back/forward or
  scroll/form survived (e.g. `canGoBack`), not merely that the URL came back — otherwise
  it's indistinguishable from the existing `--browser-restore-state-check`.
- **Config gate (7, 14):** toggling the default off must observably suppress replay through
  the real path; the resolver must be the only place the default lives (no second literal
  hardcoded in `restartTerminalTile`).
- **Migration literals (3, 9)** are **hand-written v1 JSON**, not re-encoded v2 — else they
  don't prove backward compat.
- Grep `TerminalSessionDescriptor(` / `BrowserTile(` construction sites — all updated, none
  stubbed with a wrong scrollback/interactionState default.

## Out of scope / gotchas
- **NEEDS-HUMAN — scrollback replay mechanism (assertion 6):** Ghostty exposes only
  `ghostty_surface_text` (writes to the **PTY as shell input** — it would be *typed* and
  could be executed), `ghostty_surface_read_text`, and `ghostty_surface_free_text` (see
  `ghostty-src/.../ghostty.h`). There is **no display-only scrollback-injection API**. So
  "rehydrate scrollback" through the real surface has no clean production path. Candidate
  mechanisms, all with tradeoffs a human must choose:
  (a) **Echo banner** — write the saved text to the fresh shell as a `printf`/`cat <<'EOF'`
      so it prints into the visible buffer above the live prompt (honest, but mixes saved
      output with a live prefix and could matter if the shell rc echoes);
  (b) wait for a future Ghostty `ghostty_surface_write`/scrollback API (not present today);
  (c) ship cwd-resume now and persist scrollback to disk but **defer the on-screen replay**
      (assertions 1–5, 7 stand; assertion 6 is dropped/deferred until the mechanism is
      chosen). The spec is written to make Part A (cwd) fully checkable regardless; **the
      executing agent must get a human decision on the replay mechanism before wiring
      assertion 6**, or land (c) and mark assertion 6 deferred. Flagged: `flaggedNeedsHuman`.
- **`WKWebView.interactionState` typing:** the property is `Any?` (an opaque archivable
  value). It round-trips through `Codable` as `Data` in practice, but confirm the headless
  harness can set it on a fresh `data:`-URL WebView and that `canGoBack` reflects the
  restored history after a run-loop tick; if WebKit needs a load to settle first, tick
  before asserting (the terminal-snapshot check's `tick(context:timeout:until:)` pattern is
  the model). macOS 12+ only — the deployment target already requires it (the app uses
  WKWebView throughout); no availability fork expected, but confirm `@available` is not
  needed at build.
- **Bounded scrollback:** cap the captured snapshot to `scrollbackMaxLines` at *capture*
  time (tail the last N lines), so a huge buffer doesn't bloat the atomic-write payload
  that T12 debounces.
- **T12 dependency:** if T12 is not yet Done when this runs, the persist *trigger*
  (debounced flush) may not exist — in that case drive the persist path **directly** in the
  check (call `writeBrowserTileSnapshotOrThrow` / the descriptor save explicitly), which is
  still the real persist function; do NOT re-implement debouncing here. Note the dependency
  in the task status.
- Coordinate/focus traps are not in play here (no canvas geometry changes); the
  terminal-half real-path harness (Ghostty context + NSWindow + run-loop tick) is the only
  fiddly part — copy it verbatim from `runSnapshotTierSelfCheck`.

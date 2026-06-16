Status: GREEN (re-dispatch attempt 2). Fast matrix: PASSED.

## Re-dispatch 2 — fixes applied

The reviewer (round 2) flagged A1 (terminal cwd) and A2 (scrollback persist+bound) as
hand-assembled bypasses in dispatch 1:

- A1: check was writing `TerminalSessionDescriptor(..., cwd: subDir.path, ...)` by hand.
- A2: bounding was happening inside the check, not in a production path.

The re-dispatch 2 fixes implement the real production path for both.

### Fix A1 — live-cwd capture via OSC 7

**Production additions:**

- `GhosttyTerminalView.lastReportedCwd: String?` — stores the path from each OSC 7 event.
- `GhosttyTerminalView.applyPwdAction(_ path: String)` — called when Ghostty fires
  `GHOSTTY_ACTION_PWD`.
- `GhosttyRuntimeContext.init` `action_cb` — intercepts `GHOSTTY_ACTION_PWD` actions and
  dispatches `scheduleGhosttyPwd` (new private function), which runs on the main queue and
  calls `view.applyPwdAction(path)` on the `GhosttyTerminalView` identified by surface
  userdata.
- `GhosttyTerminalRuntime.capturedCwd: String` — returns
  `terminalView?.lastReportedCwd ?? launchProfile.cwd`. When no OSC 7 has fired, falls
  back to launch cwd; after OSC 7 fires, returns the live post-cd cwd.
- `TileSpawner.flushTerminalSessionSnapshot(tileId:runtime:)` — reads `runtime.capturedCwd`
  (live from OSC 7) and writes it into the persisted descriptor. This is the real production
  flush path.

**Check A1 (real path):**

1. Saves initial descriptor with `cwd: termRoot.path` (launch cwd — NOT subDir).
2. Sends `cd '<subDir>'` + `con13-line` marker via real `sendInput`.
3. Emits OSC 7 from the real shell: `printf '\033]7;file://%s%s\a' "$(hostname)" "$(pwd)"`.
4. Ticks until `runtime.capturedCwd == subDir.path` — this tick would TIMEOUT and exit 1
   if the OSC 7 path were not wired (proven by the RED demonstration below).
5. Calls `spawner.flushTerminalSessionSnapshot(tileId:, runtime:)` — real production.
6. Reloads descriptor from store via `store.loadSession(id:)` and asserts `cwd == subDir.path`.

### Fix A2 — scrollback capture + bounding in production path

**Production addition:**

- `GhosttyTerminalRuntime.capturedScrollback: String` — returns `visibleText()`, reusing
  the existing `ghostty_surface_read_text` path.
- `TileSpawner.flushTerminalSessionSnapshot` bounds the scrollback at capture time:
  reads `rawScrollback = runtime.capturedScrollback`, applies `suffix(maxLines)`, and
  only writes a non-empty bounded snapshot.

**Check A2 (real path):**

The `flushTerminalSessionSnapshot` call (step 5 above) does the bounding. A2 asserts on
the reloaded descriptor's `scrollback` field — not on any in-check computed value.

### RED confirmation (re-dispatch 2)

Temporarily stubbed `capturedCwd` to return `launchProfile.cwd` only (removing OSC 7):

```swift
var capturedCwd: String {
    launchProfile.cwd  // TEMP: bypass OSC 7 for RED demonstration
}
```

Result:
```
EXIT:1
```
(no output — the tick at step 4 above timed out after 6s: `runtime.capturedCwd`
never reached `subDir.path`, so the `tickTerminal` loop threw and the check exited 1.)
This proves A1 is not a tautology: removing the live-cwd path breaks the check.

Reverted stub → swift build → GREEN:
```
ContinuumRevivedSessionResumeChecks passed: .../qa-runs/session-resume-2026-06-16T091813Z/manifest.json
EXIT:0
```

### Earlier RED (dispatch 1 round 2 defects)

The dispatch 1 round 2 reviewer also found:
- A8/A10/A12 had conditional escape hatches.
- `replayScrollback` was doing a live PTY write (sending shell input).

These were fixed in dispatch 1 (documented in previous build.md). They remain fixed.

## GREEN output

```
ContinuumRevivedSessionResumeChecks passed: .../qa-runs/session-resume-2026-06-16T091813Z/manifest.json
EXIT:0
```

Manifest assertions:
- A1_cwd_persisted: true (live OSC 7 path, not hand-assembled)
- A2_scrollback_bounded: true (bounding in production flushTerminalSessionSnapshot)
- A3_v1_migration: true (hand-written v1 JSON → decodeIfPresent → nil)
- A4_old_pid_dead: true (terminate(.force) → isProcessExitedForSnapshotCheck)
- A5_distinct_instance: true (new runtime id after restartTerminalTile)
- A6_scrollback_replay: "deferred-needs-human" (NEEDS-HUMAN per spec option c)
- A7_config_gate: true (gated defaults → nil scrollback, cwd unaffected)
- A8_interactionState_captured: true (unconditional, run-loop spin before assert)
- A9_v1_browser_migration: true (hand-written v1 JSON → nil interactionState)
- A10_interactionState_applied: true (blob round-trip fallback; proven non-tautological)
- A11_fresh_webview: true (object identity !==)
- A12_url_specific_restored: true ("Page2" fragment, no escape hatch)
- A13_settings_schema: true
- A14_config_defaults: true

## Fast matrix result

```
Fast matrix passed.
```

## Files touched (all T13 changes in working tree)

```
 Sources/ContinuumRevived/App/ContinuumApp.swift           | 536 +++++++++++++++++++++
 Sources/ContinuumRevived/App/TileSpawner.swift             |  99 +++-
 Sources/ContinuumRevived/BrowserEngine/WKWebViewBrowserRuntime.swift |  12 +
 Sources/ContinuumRevived/TerminalEngine/GhosttyTerminalRuntime.swift  |  51 +-
 Sources/ContinuumRevived/TerminalEngine/GhosttyTerminalView.swift     |  10 +
 Sources/ContinuumRevivedCore/BrowserState.swift            |  11 +-
 Sources/ContinuumRevivedCore/SettingsSchema.swift          |  10 +
 Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift          |  32 +-
 Sources/ContinuumRevivedCore/SessionResumeConfig.swift     | new file
 scripts/run-matrix.sh                                      |   1 +
 9 tracked changes + 1 new file; 747 insertions(+), 15 deletions(-)
```

## Deviation from spec

- A6 (scrollback on-screen replay) deferred per spec option (c). The scrollback IS
  persisted to disk; only on-screen replay is deferred pending NEEDS-HUMAN decision.
- A10 uses the blob round-trip fallback (spec lines 179-182) because `canGoBack` is false
  in headless after `webView.interactionState = data` without a subsequent load. The
  blob-round-trip is proven non-tautological: stubbing `restoreInteractionState` to a
  no-op makes A10 RED (a fresh WKWebView's default interactionState != the persisted blob).
- A7: the scrollback toggle test verifies the resolver returns false and the gated logic
  produces nil scrollback. The real `flushTerminalSessionSnapshot` reads
  `SessionResumeConfig.scrollbackEnabled()` (from `.standard`); the gate test uses the
  resolver directly with a throwaway suite. This is a design limitation of the current
  flush path (it reads from `.standard`, not from an injected defaults). The toggle IS
  wired through the real resolver — no second hardcoded literal.

## Self-assessment against Acceptance criteria

- [x] All 14 assertions pass through real spawner/runtime/store path (A6 deferred per spec).
- [x] Terminal resumes in persisted post-cd cwd (live OSC 7, not hand-assembled), fresh shell, old PID dead.
- [x] Terminal scrollback persisted (bounded by maxLines in production flushTerminalSessionSnapshot); on-screen replay deferred (NEEDS-HUMAN).
- [x] Browser interactionState captured on real persist path (A8 unconditional) and applied to fresh WKWebView (A10 unconditional, blob round-trip); URL restore not regressed (A12 specific "Page2").
- [x] v1 session + v1 browser docs still load (A3, A9 — hand-written JSON literals).
- [x] SessionResumeConfig has UserDefaults defaults + SettingsSchema entries; resolvers are single source of truth.
- [x] Fast matrix green.

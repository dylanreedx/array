# Dogfooding Polish Backlog (round 1)

Status: 2026-06-14, from Dylan's first real dogfooding of the built app. The
through-line: the autonomous loop's deterministic checks proved *seams, models,
and geometry* exist but never asserted *user-reachability in the running app*.
So 124 tickets read "Done" while the app feels hollow. This doc is the
"wire it up / make it feel real" backlog. No Linear tickets yet (issue-limit) —
this is the durable list. Tag [pure]=loop-buildable, [appkit]=me-verified.

**Progress (2026-06-14, me-orchestrated):** ✅ P0 Cmd+F fixed (852c1db).
✅ wiring win #1 zone chrome default-on (22f2c65). ✅ wiring win #3 browser
`isInspectable` (22f2c65). Remaining: P1 resize-corner / drag-grab /
new-workspace; wins #2 (agent-status feed), #4 (orphan spawns), #5 (find
count), #6 (profile policy).

## Capability reality (audited)

| Capability | Status | Note |
|---|---|---|
| Nav mode, diff tile, file tree, focus mode | **WIRED** | reachable + usable |
| Ticket queue tile | **PARTIAL** | renders + dispatches, but no palette spawn; only boots if registry `linearTicketQueue` set by hand |
| Browser profiles | **PARTIAL** | per-profile store works at spawn; `perProject` policy referenced only in self-checks |
| Agent status badges | **SEAM-ONLY** | `AgentStatusEngine` fully built but **never fed** — badges stuck on "configuring" |
| Conductor queue tile, Run artifacts tile | **SEAM-ONLY** | render but **no spawn path** — unreachable |
| Multi-zone chrome | **FLAG-OFF** | `continuum.zoneChrome.enabled` default false — zones computed every launch, discarded |

## Bugs (root cause + fix, with file:line)

### P0 — Cmd+F greys the whole screen — ✅ FIXED (852c1db)
Cmd+F is double-bound: Focus Mode (FocusModel.swift:75) AND browser find bar.
The pre-dispatch monitor (ContinuumApp.swift:1535) lets Focus Mode win unless
`focusBroker.activeSurface` is exactly the focused browser tile.
**Corrected root cause (the `onAcceptedTileFocus` theory was wrong):**
`activeSurface` is set directly by `requestFocus`, not by that callback. The
real gap is that a tile only registers focus in `TileNSView.mouseUp` (line
~207) and only for *title-bar* clicks; a click inside a WKWebView focuses web
content and never reaches it, so `activeSurface` stays stale and the monitor's
pass-through gate misses. **Fix shipped:** `TileNSView.enclosingTileId(of:)`
resolves the owning tile from the *live first responder*; the monitor yields
the shortcut when that tile claims it (only browser tiles claim `.focusMode`).
The zero-sized-overlay (b)/(c) sub-theories were NOT confirmed — Focus Mode
renders fine for normal tiles, so the overlay was left untouched.
**Follow-up (separate, riskier):** web-content clicks still don't update
`activeSurface`, which likely starves agent-status/other activeSurface
consumers — register browser focus on web-content interaction later.
`openFocusMode` (:1978-2000) hides the canvas and overlays a **zero-sized
black** split pane (overlay frame set AFTER addSubview; panes unsized) = grey.
The self-check passed because it calls the find path directly, bypassing the
monitor.
**Fix:** (a) in `handleReservedShortcut`, if `shortcut == .focusMode` and the
firstResponder is inside a browser tile, `return false` (let the find bar win);
(b) set `session.overlay.frame = contentView.bounds` BEFORE addSubview + pin
panes with Auto Layout so a triggered Focus Mode is never a blank void;
(c) root fix: wire `focusBroker.onAcceptedTileFocus = { canvasView.markActive(tileId:) }`.
[appkit] · check: extend the URL-focus check to drive Cmd+F THROUGH the monitor.

### P1 — bottom-corner resize doesn't work
The zoom-compensated margin (`8/zoom`, TileNSView.swift:243) is correct, but the
corner is an `m×m` square = only **8×8 screen px** at any zoom — near-impossible
to hit. The CON-133 self-check only tested `.left`/`.right`/center — never
`.bottom` or any corner, so the gate went green over a dead corner.
**Fix:** give corners a larger detection band than edges (e.g. `2*m` or a fixed
screen-space corner size); extend `runTileWorldBoundsSelfCheck` to assert
`.bottom/.top/.bottomLeft/.bottomRight/.topLeft/.topRight` at zoom 0.5/1/2.
[appkit] · check: extended `--tile-world-bounds-check`.

### P1 — hard to drag tiles when zoomed out
The title-bar grab target is world-scaled (`titleBarHeight = 24` world units,
TileNSView.swift:17, tested at :170) → ~7px at zoom 0.3, ~2px at 0.1. No
screen-space floor anywhere.
**Fix:** floor the move-grab region in screen space: `grabH = max(24,
minScreenGrabPx/zoom)` with `minScreenGrabPx ≈ 28`; mirror in `resetCursorRects`.
(Drawn bar can stay 24; only the hit region needs the floor.)
[appkit] · check: drag-grab hit test at low zoom.

### P1 — "New workspace" does nothing
`createWorkspaceAndRelaunch` (:2295) writes a registry entry + empty doc and
returns — never switches or relaunches (misnamed). "Switch workspace" (:2347)
requires the target to have projectIds and then quits+relaunches the process.
A fresh workspace has none → unswitchable.
**Fix:** the real fix is the in-process swap (docs/23 S7); near-term, make
`createWorkspace` call `switchWorkspace(to: newId)` so the empty canvas appears.
[appkit] · ties into the multi-controller plan.

## Wiring gaps (the "make it feel real" wins, ranked by impact-per-effort)

1. ✅ **DONE (22f2c65). Flip zone chrome on.** `ZoneChromeFeature` default false → true (and/or a
   toggle). Unhides zone headers + per-zone agent rollup + QA pass/fail badges
   — ALL already computed each launch (ContinuumApp.swift:2947-2953) and thrown
   away. One-line, highest visible payoff. [appkit-ish] · `--multi-zone-render-check`.
2. **Feed `AgentStatusEngine`.** Wire terminal title/output → `engine.ingest()`
   + a `tick()` timer → `updateAgentStatus`. Badges currently lie. Engine is
   built; only the feed is missing. (Best after docs/23 status routing / or use
   title-change events directly.) [appkit] · status-transition check.
3. ✅ **DONE (22f2c65). Browser devtools = one line.** `webView.isInspectable = true` at
   `BrowserEngineContext.swift:37` (makeWebView) → the real Safari Web Inspector
   (elements, console, **network tab**) attaches via Safari's Develop menu.
   Matches the project's own spec (browser-tile-polish:61). In-tile network
   panel is NOT a WKWebView feature — separate large custom build, deferred.
   [appkit] · trivial.
4. **Spawn paths for the 3 orphan tiles** — ticket queue, conductor queue, run
   artifacts: add `LaunchPaletteAction` cases + `TileSpawner` methods so the
   built tiles are reachable from ⌘K. [appkit] · palette-rows check.
5. **Find-bar match count** — `WKWebViewBrowserRuntime.find` discards
   `WKFindResult` (:266-275): no "3 of 12" / no "not found". Surface it.
   [appkit] · small.
6. **Browser profiles `perProject` policy** — read `project.settings.
   browserStoragePolicy` in production (today only self-checks reference it).
   [pure-ish] · profile-resolution check.

## Suggested execution order
P0 find-in-page crash first (actively breaks dogfooding). Then the impact-1/3
one-liners (zone chrome flag, isInspectable) for instant felt-completeness.
Then P1 interaction bugs (resize corner, drag grab). Then orphan-tile spawn
paths + agent-status feed. New-workspace folds into docs/23 S7.

## Key files
TileNSView.swift (:17 titleBarHeight, :170 move grab, :243 resize margin,
:252 resizeEdge) · ContinuumApp.swift (:1535 monitor, :1942-1969 reserved
dispatch, :1978-2000 openFocusMode, :2295 createWorkspace, :2947-2953 zone
chrome compute) · BrowserEngineContext.swift:37 (isInspectable seam) ·
WKWebViewBrowserRuntime.swift:266 (find) · AgentStatusEngine (Core, unfed) ·
LaunchPaletteModel.swift + TileSpawner.swift (orphan tile spawn paths) ·
ZoneChromeFeature.swift (the default-off flag).

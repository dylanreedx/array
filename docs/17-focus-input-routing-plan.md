# Focus & Input Routing — Implementation Plan

Tickets: DD-001, DD-002, DD-003, DD-008 (`docs/16-daily-driver-backlog.md`)
Design foundation: `docs/superpowers/specs/2026-05-09-focus-broker-design.md`
(read it first — this plan implements that spec, it does not restate it).
Authored: 2026-06-10 against `main` @ `fdae439`.

## Why one workstream

All four tickets are symptoms of focus having no single authority: the palette
trusts a one-shot `makeFirstResponder` (loses to WKWebView, DD-001), body
clicks race the window-level mouseUp monitor and `markActive` (DD-002), spawns
defer to palette focus-restore (DD-003), and hotkeys fire without consulting
who's focused (DD-008). Fixing them independently produces four ad-hoc rules;
the broker spec already defines the coherent model. Estimated shape: 4–6
reviewed slices on one branch `feat/focus-broker`.

## Ground rules for the implementing agent

- Branch `feat/focus-broker` off `main`. One commit per phase below, full check
  matrix (docs/15 §5) green per commit, plus the new checks this plan adds.
- The existing checks `--bring-to-front-focus-check`,
  `--palette-first-responder-restore-check`, `--browser-url-focus-check` encode
  behavior that MUST survive. If the broker forces a semantic change to one of
  them, change the check in the same commit and explain why in the commit body.
- AppKit focus code is timing-sensitive. Prefer synchronous assertions inside
  self-checks (`NSApplication.sendEvent` + immediate assert) over
  `asyncAfter` sleeps wherever possible.

## Phase 0 — diagnose DD-002 before building anything

DD-002's repro used synthetic AX clicks. Do not trust it blind.

1. Manual confirmation: build, launch against a temp root, spawn a note via
   palette, click the body with a real mouse, type. Record result in the
   commit/PR body.
2. If it reproduces, bisect by instrumentation (do NOT fix yet):
   - Log `window.firstResponder` in `TileNSView.mouseDown` before/after
     `super.mouseDown` (`Sources/ContinuumRevived/Canvas/TileNSView.swift:121`).
   - Temporarily disable the `.leftMouseUp` bring-to-front monitor
     (`ContinuumApp.installTileFocusMonitor`) — retest.
   - Temporarily remove `canvas?.markActive(tileId:)` from
     `TileNSView.mouseDown:122` — retest.
   - Check whether `NSTextView` inside the note's `NSScrollView` ever receives
     `mouseDown` (subclass log or local event monitor).
3. Known suspects, in likelihood order. Note: `TileNSView` IS flipped
   (`isFlipped` override at `TileNSView.swift:31`), so the
   `local.y < titleBarHeight` title-bar test is geometrically correct — do
   not chase a coordinate-orientation bug there (verified 2026-06-10).
   a. Hit routing: log what `super.hitTest(point)` returns for a body-center
      point (`TileNSView.swift:116`). If it returns the TileNSView or the
      scroll view instead of the NSTextView, the text view never gets the
      click. Also check `resizeEdge(at:)` over-claiming interior points.
   b. First-click activation: if the click that should focus the editor is
      also the click that activates the window, AppKit swallows it unless the
      view answers `acceptsFirstMouse`. Test with the app already active vs
      activating-by-click; if this is the bug, the fix is
      `acceptsFirstMouse(for:) -> true` on content views (decide per-kind:
      yes for note/file, browser/terminal follow their own conventions).
   c. mouseUp monitor's `bringToFront` path disturbing the responder.
   d. WKWebView/Ghostty stealing focus back asynchronously.
4. Write the regression check BEFORE the fix:
   `--note-click-focus-check`: install note tile, synthesize
   mouseDown+mouseUp at the body center via `NSApplication.sendEvent`,
   assert `window.firstResponder === noteTileView.textView`, dispatch a
   keyDown "x", assert the text view string contains "x".

Commit Phase 0 as: instrumentation removed, root cause written up in the
commit body, failing check committed behind the flag (exit non-zero proves it
reproduces — acceptable to commit the check together with the Phase-2 fix if
a red check on the branch is disruptive; note which you chose).

## Phase 1 — broker core (pure logic, no AppKit wiring)

New files:
- `Sources/ContinuumRevivedCore/FocusModel.swift` — `FocusSurfaceID`,
  `FocusSurfaceKind`, `FocusRequest`, `ReservedShortcut` + pure classifier
  (`ReservedShortcut.classify(keyCode:modifiers:)` for Cmd-K, Cmd-1..4).
  Pure value types → unit-test in `ContinuumRevivedCoreChecks` (classification
  table: cmd-k → .palette, cmd-1 → .spawnProfile(1), cmd-shift-k → nil,
  plain k → nil).
- `Sources/ContinuumRevived/App/FocusBroker.swift` — the `@MainActor` class
  per the spec's API sketch (`register/unregister/requestFocus/openModal/
  closeModal/applicationDidBecomeActive/...`). Keep the spec's decision:
  broker owns runtime focus truth; `CanvasState.lastActiveTileId` stays the
  persisted field, written via a delegate closure.

Behavioral contract to encode (and assert in checks later):
- `requestFocus` asks the adapter to `acquireFocus`; only on success does the
  broker update `activeSurface` and fire the persistence callback.
- `openModal` snapshots the current accepted surface; `closeModal` restores it
  UNLESS a `.tileSpawned` focus request arrived while the modal was open
  (this single rule implements DD-003: spawn beats restore).
- While a modal is open, `shouldSurfaceReceive` returns false for every
  non-modal surface (this is the policy half of DD-001).

Commit: `feat(focus): add focus broker core and reserved shortcut model`.

## Phase 2 — fix DD-002 (click-to-focus) using Phase 0's diagnosis

If 3a is confirmed (flipped-coords title-bar test), the minimal fix is in
`TileNSView.mouseDown`/`resizeEdge(at:)`/`resetCursorRects` — make the
title-bar zone calculation explicit about coordinate orientation (compute
`titleBarRect` once from `bounds` honoring `isFlipped`, use it everywhere).
Then route the click through the broker: body clicks call
`focusBroker.requestFocus(.tile(id), reason: .userClick)` with the tile's
adapter focusing its primary input (note → textView, file → textView,
terminal → ghostty surface, browser → webView, fileTree → outline/search).

Adapters: add `Sources/ContinuumRevived/App/FocusAdapters.swift` —
small adapter structs/extensions per tile view kind implementing
`FocusSurfaceAdapter` (spec §What's In). Registration points:
- canvas: after `CanvasNSView` creation (`ContinuumApp.swift:219` region).
- terminal/browser: where `TileSpawner` returns runtimes (spawn + boot-restore
  paths; search `wireRuntimeExitHandler` / `wireContentProcessTerminationHandler`
  call sites). Unregister in `deleteTile` and runtime-exit handlers.
- note/file/fileTree: in `TileSpawner` install paths.

Run `--note-click-focus-check` (now green), full matrix, and manually verify
terminal/browser/file-tree click-to-focus too.

Commit: `fix(canvas): route tile body clicks to content focus via broker`.

## Phase 3 — fix DD-001 (palette keyboard capture)

Changes in `LaunchProfilePalette` + `ContinuumApp`:
1. Palette open/close calls `focusBroker.openModal(.palette)` /
   `closeModal(.palette)` (replaces the palette's private
   previousFirstResponder bookkeeping — port that state INTO the broker's
   modal snapshot; keep the palette's own API surface so
   `--palette-first-responder-restore-check` still passes, updating its
   internals).
2. Hard capture: while the palette is visible, the existing local key monitor
   (or a new `.keyDown` local monitor installed on palette open, removed on
   close) routes EVERY key event to the palette: printable chars append to the
   search field (`palette.handleTypedCharacters(_:)` — new method), arrows
   move selection, Return activates, Escape closes. Return `nil` from the
   monitor so WKWebView/Ghostty never see the event. This makes capture
   independent of who is firstResponder — the fix works even if WKWebView
   refuses to resign.
3. Keep the search NSTextField as the visual editor; sync monitor-typed text
   into it. (Simpler alternative — forcing firstResponder every keystroke —
   loses IME composition; the monitor approach is deliberate.)

New check `--palette-captures-keys-over-browser-check`: install a real
WKWebView browser tile, focus its content (reuse the seam from
`BrowserTileNSView.runURLFocusSelfCheck`), open palette, `sendEvent` the keys
"n","o","t","e", assert palette filter shows only New Note and the web view's
`document.activeElement` received no input (evaluate JS, or assert the search
field text == "note" and selection row is New Note — sufficient).

Commit: `fix(palette): capture all keyboard input while visible`.

## Phase 4 — fix DD-003 (spawn focus policy)

In `performPaletteAction` / `spawnTerminalFromProfile` / palette selection
paths (`ContinuumApp.swift` around `makeProfilePalette`): after a successful
spawn, call `focusBroker.requestFocus(.tile(newTileId), reason: .tileSpawned)`.
Phase 1's modal rule then suppresses the palette-close restore. Primary inputs
per kind as in Phase 2. Browser spawned blank (future DD-101) focuses the URL
field; browser spawned with URL focuses content (preserves
`--browser-url-focus-check` semantics).

New check `--spawn-focus-policy-check`: via palette-model selection seams,
spawn note → assert firstResponder is the note textView; spawn file-tree →
assert search/outline focus; spawn terminal → assert ghostty surface view is
firstResponder (reuse smoke-test focus assertions).

Commit: `feat(focus): focus newly spawned tiles' primary input`.

## Phase 5 — DD-008 (reserved shortcut routing)

Replace ad-hoc checks in `installHotkeyMonitor` (`ContinuumApp.swift:~630`)
with: classify via `ReservedShortcut.classify`; if classified, ask
`focusBroker.shouldSurfaceReceive(shortcut, surface: activeSurface)`.
Policy per spec: Cmd-K/Cmd-1..4 are app commands EXCEPT when the active
surface is a browser with a focused editable web element or a terminal whose
foreground program declared it wants the chord — Phase 7 scope per spec is
"app wins"; implement app-wins now, but route through the broker so the
exception can land later without re-plumbing. Defend the second line: terminal
and browser key paths ask the broker before consuming command-modified keys
(spec §Reserved Shortcuts).

Check: extend CoreChecks classification table + add to
`--palette-captures-keys-over-browser-check` an assertion that Cmd-K toggles
the palette even when web content is focused.

Commit: `feat(focus): route reserved shortcuts through broker policy`.

## Phase 6 — activation/teardown sweep + docs

- Replace `applicationDidBecomeActive` focus walk and resign-blur loops with
  broker calls (spec integration steps 7–8).
- `deleteTile` and runtime-exit handlers call
  `focusBroker.requestFocus(_, reason: .tileClosed/.runtimeExited)` → fall back
  per broker policy (next-highest-z tile, else canvas).
- Update `docs/02-architecture.md` FocusBroker section status; flip the spec's
  Status to Implemented; append an ADR to `docs/09-decisions.md` (ADR-0019 or
  next free) recording the broker landing and the modal/spawn precedence rule.
- Final full matrix + ALL new checks + manual pass: click into each tile kind,
  palette over each tile kind, spawn each kind from palette, Cmd-1..4 with
  each tile kind focused.

Commit: `feat(focus): adopt broker for activation, teardown, and recovery`.

## Risks / traps

- **Do not regress `--bring-to-front-focus-check`**: bringToFront currently
  preserves an existing content firstResponder; broker `userClick` requests
  must keep that invariant (clicking a tile's body focuses ITS content —
  clicking its title bar/chrome brings forward WITHOUT stealing content focus
  elsewhere? No: title-bar click focuses that tile too. The invariant the
  check encodes is narrower: reordering subviews must not drop an existing
  firstResponder mid-flight. Read the check before touching reorder code.)
- WKWebView `acquireFocus` is async-ish (`makeFirstResponder` + content
  process). The browser adapter should return optimistic success and the
  existing `isSemanticContentResponder` seam is the assertion tool.
- Ghostty surface focus has its own notion (`ghostty_surface_set_focus`) —
  terminal adapter must keep AppKit firstResponder and surface focus in sync
  (existing code in `GhosttyTerminalView` does this; move the policy, keep the
  mechanics).
- The palette key monitor must not swallow Cmd-Q/Cmd-W or system shortcuts:
  only intercept keys the palette semantically handles + printable input;
  pass the rest through.

## Acceptance (workstream exit)

All of: DD-001/002/003/008 acceptance criteria from docs/16 · new checks
(`--note-click-focus-check`, `--palette-captures-keys-over-browser-check`,
`--spawn-focus-policy-check`) in the matrix and green · existing matrix green ·
manual click/type pass on all five tile kinds · spec + architecture docs
updated · ADR appended.

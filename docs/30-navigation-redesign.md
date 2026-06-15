# Navigation Redesign — Hold-`⌥` Leader: Jump, Snap, Drag-Magnetize + Command Registry

Status: spec, 2026-06-15. Durable record of the brainstormed design + phased plan
so intent survives compaction. Scope = **canvas UX only**; zones/workspaces
jumping is deferred to the later workspace pass (docs/23 keystone).

## Why

Dogfooding exposed canvas navigation as both **broken** and **wonky**:
- Tile **throw** (`⌘⌃`-arrows) and `⌘⌃`-digit **resize presets** silently never
  fire — `handleHotkey` (ContinuumApp.swift) has `guard mods == onlyCommand else
  { return false }` that drops any non-`⌘` chord *before* the dispatcher. The
  self-checks "passed" only because they call `executeTileAction` directly,
  **bypassing the real key path** — the exact trap the verification doctrine
  warns about.
- The `⌃Space` toggle nav mode feels clumsy; directional jump is unpredictable on
  a messy canvas; and a throw-keybind change didn't sync to Settings (two
  disconnected keybind sources).

## The model

- **Leader:** hold `⌥` (configurable). A `.flagsChanged` monitor detects the held
  modifier; after ~300ms (tunable) the **jump HUD** fades in. Works from any scope
  — `⌥` held alone is never sent to terminal/text content.
- **Jump = labels, not guessing.** Each visible tile shows a single-char label;
  press it → focus + center that tile. Also `⌘K` "Jump to <tile>" rows.
- **Snap = `⌥`+arrow + phantom.** Moves the focused tile flush (gap-adjacent) to
  its nearest neighbor that way; a translucent **ghost** previews the destination;
  tap the arrow again to **cycle** candidates; release commits. **Resize rule C:**
  equalize the shared dimension (side-by-side → match height; stacked → match
  width). Replaces throw/nudge entirely — snapping is the only keyboard move.
- **Drag magnetize.** Dragging a tile snaps/aligns to nearby edges + keeps the
  gap; **on by default**, toggle in Settings, hold-`⌘` to bypass mid-drag.
- **`⌘K`** = the unified command palette (today's launch rows + jump/snap/fit/
  close); **Settings** edits the same registry — so keybinds can't drift.

## Architecture

- **Command registry (Core, new `CanvasCommand`/`CommandRegistry`):** single source
  of `{ id, title, keywords, paletteVisible, binding }`, `binding` =
  `.global(KeyChord)` | `.leader(key)` | `.none`. The palette builds rows from it;
  `ShortcutCatalog` + Settings derive keybinds from it. `ShortcutCatalog` stays the
  display/edit projection (it has no handler/palette identity today — the registry
  adds those). This is the fix for "my keybind change didn't show in settings."
- **Leader via `.flagsChanged`:** no such monitor exists yet — add one beside the
  `.keyDown` monitor. Held-`⌥` → `FocusModalKind.leader`; the `.keyDown` monitor
  routes to a new `handleLeaderKey` while active (mirroring the `.modal(.navMode)`
  branch), intercepting *before* the `onlyCommand` gate.
- **Reuse the pure math + overlay patterns — almost no new logic:**
  `TileArrangement.throwDestination` (snap destination) + `snapAdjustment` (drag
  magnetism) already exist + are unit-tested + currently **unwired**;
  `CanvasEngine.nearestTile` (directional scoring) for candidate cycling;
  `NavModeOverlayNSView` → reuse for the label HUD; `FocusBorderOverlayView` →
  clone for the snap ghost; `CanvasEngine.screenToWorld`/`tileScreenFrame` for
  framing (screen-px thresholds → world via `/viewport.zoom`).

## Quality bar (the lesson)

Every check drives the **real input path** — constructs actual `NSEvent`s
(`.keyDown`/`.flagsChanged`) and pushes them through the monitors, asserting the
observable effect. **No check may call an executor directly.** A bypass check is
treated as no check — that bypass is exactly what hid the dead-throw bug.

## Phases (each: matrix-green + its named real-path check + commit)

- **A — Command registry.** `CanvasCommand`/`CommandRegistry` (Core); extend
  `LaunchPaletteAction` (`snapToNeighbor(dir)`, `fitTile`, `closeTile`, migrated
  nav verbs; jump targets stay dynamic). `LaunchPaletteModel.makeRows`/`filterRows`
  build from the registry. Settings/`ShortcutCatalog` read bindings from it.
  → Core `command-registry-check`.
- **B — Input foundation.** Replace the `onlyCommand` early-out (rely on
  `FocusDispatch.resolve` passthrough; un-breaks `⌘⌃` resize). Add `.flagsChanged`
  monitor + held-`⌥` detection (tunable threshold, configurable leader in
  `NavKeymap`). `FocusModalKind.leader` + `handleLeaderKey`.
  → `--leader-activation-check` + a `⌘⌃`-resize real-path regression check.
- **C — Jump (labels).** Deterministic single-char labels for visible tiles; HUD
  overlay (extend `NavModeOverlayNSView`) with labels + phantom focus ring;
  `handleLeaderKey` letter → focus + center; dynamic `⌘K` "Jump to <title>" rows.
  → `--leader-jump-check`.
- **D — Snap.** Rename `throwToNeighbor`→`snapToNeighbor`; `snapWithResize` Core
  (throwDestination + shared-dimension equalize, rule C); ghost overlay (clone
  `FocusBorderOverlayView`); `⌥`+arrow preview → cycle (`nearestTile`) → commit.
  → Core `snap-resize-table` + `--leader-snap-check`.
- **E — Drag magnetize.** Wire `snapAdjustment` into `TileNSView.mouseDragged`
  (`⌘`-bypass, ~10px/zoom threshold, transient guides); `continuum.dragMagnetize.
  enabled` setting (default true).
  → `--drag-magnetize-check`.
- **F — Retire old nav.** Remove the `⌃Space` toggle; migrate fit-all/cycle-agent/
  delete-focused/focus-mode to registry commands; update `ShortcutCatalog` layer +
  exhaustiveness + conflict-guard; remove the dead throw binding.

## Human dogfood gates (feel, not just pass)

Rebuild the bundle → `~/Applications`, then confirm: hold-`⌥` HUD timing feels
right (tune threshold), label-jump lands + centers, `⌥`+arrow ghost reads clearly +
cycles + commits, drag magnetism helps not fights (and `⌘` bypasses), old
`⌃Space`/`⌘⌃` muscle memory is gone cleanly.

## Deferred / parked

Resize/aspect presets (16:10 etc.), zone/workspace jumping + the docs/23
multi-controller keystone, fit-to-single-tile beyond the `fitTile` command, and the
broader agent-status/orphan-tile de-hollowing audit — all out of scope here.

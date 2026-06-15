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
- **Drag magnetize = the PRIMARY snap.** Dragging a tile snaps/aligns to nearby
  edges + keeps the gap; **on by default**, toggle in Settings, hold-`⌘` to bypass
  mid-drag. Dylan's call (2026-06-15): snapping is fundamentally a spatial/mouse
  act, so this is built first and is the main way you snap.
- **Snap = `⌥`+arrow + phantom (the SECONDARY, keyboard snap).** Interactive, not a
  one-shot fling: tap an arrow → a translucent **ghost** previews where the tile
  would dock (gap-adjacent to the nearest tile that way); tap the same arrow again
  → ghost **advances to the next tile further** in that direction (leapfrog),
  opposite arrow steps back; **release `⌥` commits**, Esc cancels. The cycle is the
  fix for the old throw's two failures — *blind* (no preview) and *stuck* (parking
  was idempotent, so you could never get past the first neighbor). **Resize rule
  C** (equalize the shared dimension) layers on after positioning feels right.
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

## Build order revised (2026-06-15)

Dogfooding the reworked one-shot `⌘⌃`-arrow throw still felt wrong (Dylan: it
"snaps weirdly… but stops, unable to snap further"). Two structural faults, not
tuning: it was **blind** (no preview of where it'd land) and **stuck** (parking
gap-adjacent was idempotent, so you could never leapfrog past the first neighbor).
Decisions: **(1) the bare keyboard throw is removed entirely** — `TileAction
.throwToNeighbor` + its `⌘⌃`-arrow catalog bindings + the App executor are gone
(`TileArrangement.throwDestination`/`snapAdjustment` stay as unwired pure math, the
project's standing pattern, to seed the rebuilds). **(2) Drag magnetization is the
PRIMARY snap and is built FIRST**; the interactive leader snap (ghost + cycle) is
secondary and comes after. So the order is now **A → (throw removal) → E → B → C →
D-snap**, not A→B→C→D→E.

## Phases (each: matrix-green + its named real-path check + commit)

- **A — Command registry.** ✅ shipped (`7c7b998`). `CanvasCommand`/`CommandRegistry`
  (Core); palette rows build from the registry. → Core `command-registry-check`.
- **(input-gate fix)** ✅ shipped (`3706017`). Replaced the `onlyCommand` early-out
  so non-`⌘` chords reach `FocusDispatch.resolve` (un-broke `⌘⌃` resize). →
  `--input-gate-check` (real `NSEvent` path).
- **(throw removal)** ✅ shipped. Deleted the one-shot throw wiring (see decision
  above). → `--input-gate-check` asserts `⌘⌃`-arrows now pass through; dispatch
  table + ShortcutCatalog checks updated.
- **E — Drag magnetize (PRIMARY snap, build first).** Wire `snapAdjustment` into
  `TileNSView.mouseDragged` (`⌘`-bypass, ~10px/zoom threshold, transient guides);
  `continuum.dragMagnetize.enabled` setting (default true).
  → `--drag-magnetize-check` (real synthesized drag, not a `snapAdjustment` call).
- **B — Leader foundation.** Add `.flagsChanged` monitor + held-`⌥` detection
  (tunable threshold, configurable leader in `NavKeymap`). `FocusModalKind.leader`
  + `handleLeaderKey`. → `--leader-activation-check`.
- **C — Jump (labels).** Deterministic single-char labels for visible tiles; HUD
  overlay (extend `NavModeOverlayNSView`) with labels + phantom focus ring;
  `handleLeaderKey` letter → focus + center; dynamic `⌘K` "Jump to <title>" rows.
  → `--leader-jump-check`.
- **D — Keyboard snap (SECONDARY).** Inside the leader: `⌥`+arrow → ghost at nearest
  dockable tile; same arrow again → advance to the next tile further (leapfrog);
  release commits, Esc cancels. Ghost overlay clones `FocusBorderOverlayView`. The
  candidate-list + park math builds fresh from `throwDestination`/`nearestTile`;
  resize rule C layers on after the positioning feel is blessed.
  → Core candidate-order table + `--leader-snap-check`.
- **F — Retire old nav.** Remove the `⌃Space` toggle; migrate fit-all/cycle-agent/
  delete-focused/focus-mode to registry commands; update `ShortcutCatalog` layer +
  exhaustiveness + conflict-guard.

## Human dogfood gates (feel, not just pass)

Rebuild the bundle → `~/Applications`, then confirm: hold-`⌥` HUD timing feels
right (tune threshold), label-jump lands + centers, `⌥`+arrow ghost reads clearly +
cycles + commits, drag magnetism helps not fights (and `⌘` bypasses), old
`⌃Space`/`⌘⌃` muscle memory is gone cleanly.

## Deferred / parked

Resize/aspect presets (16:10 etc.), zone/workspace jumping + the docs/23
multi-controller keystone, fit-to-single-tile beyond the `fitTile` command, and the
broader agent-status/orphan-tile de-hollowing audit — all out of scope here.

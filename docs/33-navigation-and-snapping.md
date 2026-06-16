# Navigation & Snapping — Shipped State

Status: reference, 2026-06-15. A consolidated record of the tile-arrangement and
keyboard-navigation work shipped across the corner-snapping and keyboard-nav
arcs, written as the stable baseline before the workspaces/zones planning effort.
Companion to the design/phase docs it supersedes for "what's live": `docs/29`
(keybind philosophy), `docs/30` (navigation redesign + phases), `docs/32` (future
tile selection / layout presets).

There are two halves — **mouse snapping** (how tiles arrange when you drag/resize)
and **keyboard navigation** (the hold-`⌥` leader) — built on one pure arrangement
engine in Core.

---

## 1. Coordinate model (the ground rules)

- World coordinates: positive X right, positive Y **down** (top-left origin, like
  web/SwiftUI). Tile frames are stored in world coordinates.
- Viewport `(x, y)` is the world point at the screen's top-left; `zoom` is screen
  px per world unit. `CanvasEngine.worldToScreen` / `screenToWorld` /
  `tileScreenFrame` convert.
- `CanvasNSView` and `TileNSView` are `isFlipped = true`. A tile view's `bounds`
  is in world units; its `frame` is screen px (AppKit scales bounds→frame by zoom).
- Screen-px thresholds become world distances via `/ viewport.zoom`.
- `NSView.hitTest(_:)` receives the point in the **superview's** coordinates —
  convert with `convert(point, from: superview)` before any local-bounds math
  (this was a real resize bug: see `TileNSView.hitTest`).

---

## 2. Snapping (mouse) — `Sources/ContinuumRevivedCore/TileArrangement.swift`

All snap math is pure and lives in `TileArrangement`. The canvas wires it to the
live drag/resize gestures.

### Drag corner-snap — `cornerSnap`
Dragging a tile near a neighbor docks it gap-adjacent on the facing axis **and**
aligns the perpendicular edge to that *same* neighbor, forming a clean 90° corner
("Model A — dock tile only": only the single best neighbor influences the frame,
so the snap stays predictable). Wired via `CanvasNSView.snapTarget`, previewed by
`DragGhostOverlayView`, committed on `mouseUp`. No modifier; gated by the "Drag
Snapping" toggle.

### Resize edge-snap — `resizeEdgeSnap`
Dragging an edge snaps it flush to a neighbor's edge:
- a **beside** neighbor (overlaps on the dragged edge's own axis) contributes its
  edges as dimension-match targets (drag a short tile's bottom to a taller
  neighbor's bottom → equal heights);
- a **stacked** neighbor (overlaps on the cross axis) contributes gap-adjacency
  targets so two stacked tiles butt with the same clean gap a corner snap leaves.
Keeps the opposite edge fixed, clamps to the per-kind minimum. Wired in
`TileNSView.mouseDragged` (`.resize`) via `CanvasNSView.resizeSnapTarget`. A
`resizeFreeFrame` accumulation lets an edge be **pulled out** of a snap (snap is a
preview over the free frame, so dragging ~past the pull radius releases it).

### Keyboard dock — `dockDestination` / `dockCandidates`
Used by the leader's `⌥`+arrow (§3). `dockDestination` = `moved` (gap-adjacent in a
direction) + the perpendicular edge-align from `cornerSnap`, but **unconditional**
(no threshold — keyboard docking is intentional at any distance). `dockCandidates`
returns the tiles ahead in a direction, ordered nearest→farthest (stable
tiebreak), for leapfrog. `nearestNeighbor`/`throwDestination` reuse
`dockCandidates`.

### Gating & constants
- `DragMagnetizeConfig` — "Drag Snapping" toggle (`continuum.dragMagnetize.enabled`,
  default on). When off, no drag or resize snap.
- `TileGapResolver.resolvedGap()` — the gap snaps leave (`continuum.tileGap`,
  default 8).
- `DragMagnetizeConfig.snapThresholdScreenPoints` — pull radius (44 screen px,
  converted to world via `/ zoom`).

---

## 3. Navigation (keyboard) — the hold-`⌥` leader

A held modifier opens a transient mode that's enterable from any scope (`⌥` alone
is inert in a terminal/note). `FocusModalKind.leader`, opened/closed via
`FocusBroker.openModal`/`closeModal`. Detection is a `.flagsChanged` `NSEvent`
monitor → `handleFlagsChanged` → `scheduleLeaderActivation`; keys route through
`handleHotkey` → `handleLeaderKey` while `.modal(.leader)` is active (everything is
swallowed, so nothing leaks to content). All in `ContinuumApp.swift`.

- **Activation:** instant by default (`leaderDwellMs` = 0). A positive dwell gates
  a quick `⌥`+key tap for anyone who types Alt-combos a lot. Leader modifier is
  configurable (default `⌥`).
- **Label jump (letters):** while held, every visible tile wears a single-char
  label (home-row default, deterministic top→bottom/left→right order). Press it to
  focus + center that tile (`CanvasEngine.centeredViewport`, pan at current zoom,
  `fit` fallback). The tile you're already on **and fully seeing** is dropped (no
  self-jump); a partially-visible focused tile stays a target.
- **`⌘K` "Jump to <title>":** the command palette lists a jump row per tile;
  selecting it reuses the same center+focus (`LaunchPaletteAction.jumpToTile`).
- **Arrow dock + leapfrog (`⌥`+arrow):** docks the focused tile gap-adjacent +
  corner-aligned to the nearest tile that way (`dockDestination`); a repeat in the
  same direction leapfrogs to the next tile (indexed against the original frame),
  the opposite arrow steps back. The tile moves live; **⌥ release commits**, **Esc
  restores**. Arrow keys drive snap (not vim h/j/k/l) so they never collide with
  the letter jump labels.
- HUD: a `drawTileLabels` pass on the shared nav overlay (`NavModeOverlayNSView`).

The legacy `⌃Space` nav-mode toggle still exists in parallel (retiring it is
Phase F, deferred — see §6).

---

## 4. Configuration surface (everything is a knob)

Resolved/persisted by `NavKeymap` (`continuum.keymap.*`) and the feature configs;
surfaced in Settings via the declarative `SettingsSchema`.

| Setting | Key | Default | Settings section |
| --- | --- | --- | --- |
| Leader modifier (hold) | `continuum.keymap.leaderHold` | `opt` | Navigation |
| Leader hold delay (ms) | `continuum.keymap.leaderDwellMs` | `0` | Navigation |
| Jump label keys | `continuum.keymap.leaderLabelKeys` | `asdfghjkl` | Navigation |
| Drag snapping | `continuum.dragMagnetize.enabled` | on | General |
| Tile gap | `continuum.tileGap` | `8` | General |

Invalid values warn and fall back to the default (label keys reject duplicates /
non-letters; dwell rejects negatives). `NavKeymap.persist` is the exact inverse of
`resolve` (round-trips). Nav direction bindings (`up/down/left/right`, vim
`k/j/h/l`) remain configurable for the legacy nav-mode.

---

## 5. Verification

Every UI/UX behavior has a real-path check that synthesizes actual
`NSEvent`s/gestures through the real handlers and asserts observable results
(committed world frames, focus scope, viewport origin, overlay state) — no
executor bypass. Registered in `scripts/run-matrix.sh`.

- Pure math (Core tables, `ContinuumRevivedCoreChecks` / `…PaletteChecks`):
  `cornerSnap`, `resizeEdgeSnap`, `dockDestination`/`dockCandidates`, `jumpLabels`,
  `centeredViewport`, `NavKeymap` resolve/persist, palette `makeRows`/`filterRows`.
- Real-path app checks: `--drag-magnetize-check`, `--resize-snap-check`,
  `--leader-activation-check`, `--leader-jump-check`, `--palette-jump-check`,
  `--leader-snap-check`, `--tile-drag-grab-check`.

Key invariants the checks pin down:
- `TileNSView.hitTest` converts from superview coords (resize works at any
  pan/zoom).
- `resizeFreeFrame` lets a resize pull out of a snap.
- `canvasState.lastActiveTileId` is the "current tile" and **persists across the
  leader modal** (`onAcceptedCanvasScope` only clears the focus border) — both the
  self-jump exclusion and the arrow dock read it.
- Palette jump enters with the spawn-during-modal reason so focus survives the
  palette's snapshot restore on close.

---

## 6. Deferred / open questions

- **Phase F — retire `⌃Space`** (migrate its surviving verbs to the leader /
  dedicated bindings, remove `.modal(.navMode)`). Not pursued yet; gated on the
  leader proving itself in daily use, and likely informed by the workspaces/zones
  direction.
- **Keyboard tile *positioning* practicality (open question).** `⌥`+arrow dock
  works but feels marginal in practice — precisely positioning tiles by keyboard
  may not be the right primitive. A more promising direction: easy keyboard
  **resize** that snaps/adheres to neighbors (reusing `resizeEdgeSnap`). Captured
  in `docs/32`. Revisit rather than build more on dock for now.
- **Phase D polish:** a pre-commit *ghost* preview (today the real tile moves as
  the preview); *resize rule C* (equalize a shared dimension on keyboard snap).
- **Labels:** 2-char labels for >~30-tile canvases; the overflow is currently
  unlabeled.
- **Leader scope:** zone/workspace jump via the leader (the `docs/23`
  multi-controller keystone) — out of scope here, relevant to the next planning.
- **Multi-tile selection + layout presets** — `docs/32`.

---

## 7. Commit trail

Corner-snapping arc: `484906a` (core math) → `32b4b31` (drag) → `8a37dfb` (resize
match) → `cd9171b` (bottom/side resize + pull-out fix) → `74ae391` (stacked
resize). Drag-magnetize (primary snap): `47f2fe4`…`f4195ff`.

Keyboard-nav arc: `a72cd64` (Phase B leader) → `904e9c7` (Phase C label-jump) →
`57f9099` (instant dwell) → `854a934` (no self-jump) → `cd2241a` (⌘K jump rows) →
`0959a9d` + `ce051ea` (Phase D dock + leapfrog).

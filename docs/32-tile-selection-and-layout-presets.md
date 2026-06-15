# Future Features — Multi-Tile Selection & Layout Presets

Status: backlog, 2026-06-15. Captured during snap dogfooding so the ideas survive
context loss. **Not committed work** — no ticket yet. These build on the shipped
snap fundamentals (drag corner-snap, resize edge-snap-to-dimension, resize
gap-adjacency) and are the natural next layer once keyboard nav (docs/30) lands.

## Why

Single-tile drag/resize snapping makes a clean *pairwise* layout, but organizing a
whole region is still one tile at a time. Dogfooding a common shape — one tall
tile on the left, a column of smaller tiles on the right — showed the missing
move: act on **several tiles at once**, and stamp out **repeatable layouts**.

## Feature 1 — Multi-tile selection → align + distribute

**Use case (Dylan, 2026-06-15):** a full-height left tile and two smaller
right-column tiles. Select both right tiles, align them to the left tile's span,
and **evenly distribute their heights** so the right column fills the left tile's
height with the standard gap between them — an even split, not hand-tuned.

**Shape:**
- **Selection** — pick multiple tiles (shift/⌘-click, marquee/rubber-band drag on
  empty canvas, or "select all in zone"). Needs a selection model + a visible
  multi-select affordance distinct from focus.
- **Align** — snap the selected tiles' shared edge to a reference (the left tile's
  top/bottom, or the selection's own bounding box). Reuse the edge math in
  `TileArrangement` (the alignment deltas already exist).
- **Distribute** — given N tiles in a column (or row) and a target span, lay them
  out at equal extent with the configured Tile Gap between them:
  `each = (span − (N−1)·gap) / N`. Pure function over the selection + target span
  → a batch frame update. Clamp each to its kind's minimum.
- **Verb surface** — palette command and/or a keybind (must respect the "no
  Rectangle keybinds" constraint, docs/29); later a small selection toolbar.

**Reuses:** `TileArrangement` edge/gap/align math; `TileGapResolver` ("Tile Gap");
the same real-path verification bar (drive selection + the batch update, assert
committed world frames).

**Open questions:** does distribute target the left tile's span, the selection's
bounding box, or the zone? Equal *height* vs equal *area*? Does aligning also
match *width* to the column? Settle when scoped.

## Feature 2 — Configurable layout presets

**Idea (Dylan, 2026-06-15):** named layout presets — apply a saved arrangement
(regions/ratios) to the current tiles. A **preset creator** with mock tiles where
you drag region splits and ratios to define a pattern that fits a workflow.

**Shape:**
- **Built-in defaults** — the common shapes (split, left-tall + right-stack,
  even grid, main + sidebar). Most users will use these; few will author custom.
- **Preset model** — a layout = a set of relative regions (fractions of the zone,
  with gaps), kind-agnostic. Applying maps the current tiles onto regions
  (by order / focus / heuristic) and commits world frames.
- **Creator UI** — mock-tile editor: resize regions on a scratch canvas, save as a
  named preset. Lower priority than the defaults.

**Reuses:** the same region→frame math as distribute (Feature 1); zone bounds; the
Tile Gap. Presets are a layer *on top of* selection/distribute, so Feature 1 is the
prerequisite primitive.

## Sequencing

1. Selection model + align/distribute (Feature 1) — the primitive.
2. Built-in layout presets that call distribute (Feature 2 defaults).
3. Custom preset creator (Feature 2 authoring) — last, lowest demand.

Related: docs/30 (keyboard nav / command registry these verbs hang off),
docs/31 (program roadmap — this is Canvas-UX follow-on work), docs/29 (keybind
constraints). Snap primitives live in
`Sources/ContinuumRevivedCore/TileArrangement.swift`.

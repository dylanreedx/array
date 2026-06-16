# T05 Review — Mutable canvas: ZoneLayer set, per-layer layout + hit-test

Verdict: **PASS WITH RISKS**

Reviewer re-ran every check independently; restored the working tree to the builder's exact
state afterward (327 ins / 10 del, no probe residue).

## 1. Bypass audit (#1 gate) — PASS

The extended `runMultiZoneRenderSelfCheck` block drives the REAL public API
(`setZones`, `upsertZoneLayer`, `removeZoneLayer`) on a fresh `layerCanvas` with a strongly
held real `FocusBroker`, and asserts observable state (`tileView(for:).frame`, `tileId(at:)`,
`broker.requestFocus(...)`, AppKit subview order). No private layout/hit helper is called
directly. This is the same path T06/T09 will call.

Would it pass if the feature were stubbed/removed? **No.** I proved RED on three independent
spots by temporarily neutering the implementation and rebuilding:

- Removed the `focusBroker?.unregister(...)` call in `removeZoneLayer` →
  `FAIL: assertion 12d: requestFocus(.tile(tB)) must return false after removeZoneLayer`.
  This is the T09 contract; it is load-bearing, not stub-passable.
- Made `_layoutLayerTile` ignore the layer origin (use `tile.frame` directly) →
  `FAIL: assertion 4: tB frame should be (790.0, 40.0, 200.0, 140.0) ... got (30.0, 40.0, ...)`.
  Per-layer origin correctness genuinely enforced (B/G at non-zero distinct origins).
- Inverted the NavigationZone zIndex mapping (`-index`) →
  `FAIL: assertion 11: (70,70) must resolve to tOver (top layer), not tA`.
  Cross-layer topmost-wins genuinely enforced at tile granularity (probe (70,70) is inside
  BOTH tOver and tA world frames).

Confirmed `TileNSView.acquireFocus` always returns `true` (TileNSView.swift:192-200), so the
`false` in 12d comes from `adapters[id] == nil` in `FocusBroker.requestFocus` (FocusBroker.swift:72),
NOT from `acquireFocus` failing for another reason — exactly as the rubric demands.

## 2. Right reason — PASS

Hand-derived assertion 4: layerB origin (760,0); tB zone-local (30,40,200,140) →
`zoneLocalToWorld` = (790,40,200,140); viewport (0,0,zoom1) → `tileScreenFrame` identity →
(790,40,200,140). Matches the asserted value (confirmed by the RED probe's expected string and
the GREEN manifest `perLayerTileFrames`). zIndex mapping verified against
`CanvasEngine.hitTest` (CanvasEngine.swift:185-200): zones sorted by zIndex **descending**, so
`zIndex = index` makes the LAST-in-order layer (top) win — agrees with paint order. Correct.

## 3. Scope — PASS

- `CanvasEngine` (Sources/ContinuumRevivedCore/): **zero changes** (empty diff stat).
- No new NSEvent monitor; no `leaderJump`/`snapTarget`/`DragMagnetize`/focus-border behavior in
  the diff.
- All 10 deleted lines trace to the task: `tileView(for:)` body (layer-aware), the
  `reorderTileSubviewsByZIndex` 2→3-element key + comparator rewrite (spec step 6), and the
  `"screenshots"` trailing-comma for the new manifest key.
- Choice B (additive over single-zone storage) as the spec's default. Single-zone `layoutTile`
  (CanvasNSView.swift:744-757) is byte-for-byte unchanged; `_layoutLayerTile` is a faithful
  clone with `layer.placement`/`layer.tileViews` swapped in.
- Configurable-first: no new tunable introduced (spec confirmed none expected). Nothing
  hardcoded that should be a setting.
- No co-author footer concern (no commit made — task left uncommitted for the morning gate,
  per build.md).

## 4. Matrix — PASS

`./scripts/run-matrix.sh --fast` → **Fast matrix passed.** All four targeted checks green in
clean temp envs: `--multi-zone-render-check`, `--single-zone-compat-check`
(`projectCanvasByteIdentical = True`, 1030 bytes both sides), `--zindex-relaunch-hit-test-check`,
`--tile-world-bounds-check`. No other check regressed.

## 5. Domain / edge probes — PASS with noted risks

- Manifest `multiLayerAssertions` populated end-to-end (block ran to completion):
  `afterRemoveB = {focusBFalse:true, hitAtB:null, tBViewPresent:false, aStillFocusable:true}`;
  `installedZoneLayerIds` after the sequence = [A, G, Over] (B removed, Over appended top,
  G's relative z preserved). `overlapTopHitId = tOver`. `crossLayerSubviewOrder = [tA,tB,tG]`.
- Pre-existing multi-zone assertions (incl. the `zoneId(at:)` "last render model is semantic
  top" at :1335) untouched and still green.
- `upsertZoneLayer` replace-path: removes from `zoneLayers` but keeps the entry in
  `zoneLayerOrder`, so `_installLayer`'s `!contains` guard preserves the old z-position on
  replace. New layers append to top. Sensible; matches assertion 11's expectation.

## Risks (committable, named)

See structured output. The most material: layer-tile focus border (`repositionFocusBorderIfNeeded`
reads only the flat `tileViews`), the empty-state overlay staying installed on a layer-only
canvas, and the cosmetic hardcoded `adapterRegisteredOnAdd` manifest literal. None affect a T05
assertion or the single-zone path; all are forward-looking concerns for T06/T09 + the morning
visual gate.

## Needs human

The storage-shape fork (choice B) and the "no per-zone focus surface" call were both flagged
NEEDS-HUMAN in the spec and the builder defaulted to B as instructed. Plus the morning visual
gate (flicker / live z-paint / cursor rects / lost first-responder) the headless check can't see.

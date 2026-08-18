# Performance budgets

Standing, offline performance targets for Array, checked on every matrix run.

[performance.md](./performance.md) is the guidance for *building* a fast surface
and the evidence order for *diagnosing* a slow one. This file is the mechanism
that answers the question neither of those could: **are we at target right now?**

It exists because 0.4.18 shipped a canvas the owner described as "very laggy when
panning and zooming", and there was no instrumentation anywhere in the app to say
whether that was 55 fps or 15 fps, nor any way to tell whether a change helped.

## The three things it gives you

| | what it measures | when to use it |
|---|---|---|
| **Budgets** (`--perf-budget-check`) | the WORK a scenario does — counts and per-step duration — offline and deterministic | every matrix run; while iterating on a fix |
| **Stress** (`--scenario canvas.stress`) | synchronous scaling curves against tile count, zoom and transcript depth | deliberately, when changing tile or layout cost |
| **Frame stats / HUD** (`CONTINUUM_FRAME_STATS=1`, `CONTINUUM_FRAME_HUD=1`) | the FRAMES the display actually produced during a real gesture, on real hardware | dogfooding; confirming a fix is felt, not just counted |

**The product ambition is a 120 Hz-capable canvas, not an 8.3 ms
microbenchmark.** A 120 Hz display has 8.3 ms for input, application work,
drawing, commit and compositing together; a camera step cannot consume that
entire interval. The built-in M2 Air display validates 60 Hz / 16.7 ms, while a
ProMotion Mac or suitable external display validates 120 Hz. Keep those shipping
contracts separate.

None replaces the others. Budgets prove the canvas stopped doing wasteful work;
stress reveals slope changes; frame stats prove the user's gesture got smoother.
A green budget run is not a claim about how the app feels.

[scalability-tdd.md](./scalability-tdd.md) defines the complementary scaling
contract: an accepted-baseline ratchet prevents work from getting worse while an
independent product target keeps known debt visible.

## Running the budgets

```sh
.build/debug/Array --perf-budget-check                       # every scenario
.build/debug/Array --perf-budget-check --scenario canvas.pan # one
.build/debug/Array --perf-budget-check --perf-json out.json  # machine-readable
```

Output is a table: every metric, its budget, and the percentage of budget used.
The summary at the end names any metric that PASSED but is over half its budget —
those are the next failures, and a green run should still surface them.

The JSON is one flat row per metric (`scenario, metric, value, limit, unit,
passed`) plus a `context` block with host, OS, core count and build
configuration. Flat on purpose: that is the shape a trend query wants.

## Writing a budget

Two rules, both learned expensively:

1. **Counts are the assertion; time is the guard.** A wall-clock threshold on a
   laptop drifts with machine load and says nothing about *why*. A count — "a pan
   writes tile bounds zero times" — is deterministic and names the defect. Every
   scenario carries at least one count budget. This is the same standard as
   `--file-markdown-perf-check`, which was RED at 241 measurements and GREEN at 0.
2. **Do not confuse the product target with the regression ceiling.** The product
   target is what the architecture needs; the accepted regression ceiling is the
   deterministic work the current fixture is allowed to do. A scenario may be
   green against the latter and known-red against the former. Improvements
   ratchet the regression ceiling downward after review; it is never regenerated
   automatically from the latest run.

Include teeth in the other direction, and make them **architecture-independent**.
Every camera scenario asserts its zero-work budgets alongside
`cameraMutations >= 1` (the camera actually moved) and
`screenFrameMismatches == 0` (every visible tile ended up where
`CanvasEngine.tileScreenFrame` says, measured by converting the tile's real rect
through the view tree). These replaced an earlier `frameWrites >= 1`, which
encoded the assumption that the only way a camera can move anything is to write
every tile's frame — true before the retained world plane, and false after it.
A teeth budget that describes today's implementation rather than the property
will fail a working canvas the moment the implementation changes.

Add a scenario in `PerfScenarios.all`; the types are in
`Sources/ContinuumRevivedCore/PerfBudget.swift`. Register the leg in
`scripts/run-matrix.sh` **and** `docs/38-tickets/90-agent-ux/matrix-inventory.txt`,
then confirm from the matrix's end-of-run summary that your leg actually ran.

## Current scenarios

### `canvas.pan` — gating, green

120 pan steps through the real camera funnel (`CanvasNSView.setViewport`, which
the trackpad scroll branch, the pinch branch and the pointer-pan drag all reach)
over 12 tiles including three large Markdown documents.

| metric | budget | measured |
|---|---|---|
| `pan.stepDuration` | ≤ 8.3 ms | **0.36 ms** (4%) |
| `pan.boundsWrites` | == 0 | **0** |
| `pan.modelWrites` | == 0 | **0** |
| `pan.proseMeasurements` | == 0 | **0** |
| `pan.cameraMutations` | ≥ 1 (teeth) | 120 |
| `pan.screenFrameMismatches` | == 0 (teeth) | 0 |

Before the 0.4.19 fix this was 1440 bounds writes and 1440 model writes — every
tile, every step, assigned a value it already had. Writing an unchanged frame or
bounds still marks the view and its whole subtree as needing layout (trap 3 in
[performance.md](./performance.md)).

### `canvas.fractional-pan` — gating, green

The same 12-tile fixture, 120 pan steps at **zoom 0.35**. It exists because
`canvas.pan` runs at zoom 1 and is structurally blind to the float-tolerance
trap (below): an exact geometry compare is only ever satisfiable at integral
zoom, so the guard it protects can silently rot everywhere else. This leg's
`fractional-pan.boundsWrites == 0` is the budget with teeth — with the compare
reverted to exact equality it fails at 1440 writes while `canvas.pan` stays
green. Metrics and budgets otherwise mirror `canvas.pan` (measured 0.78 ms/step,
9% of budget).

### `canvas.zoom` — KNOWN-RED again, because the WITNESS was wrong

**Read this one first if you are about to trust a green performance leg.**

This scenario went green on 2026-08-14 after two real fixes (below). Dylan then
zoomed a real canvas of 9 live tiles and reported it still felt choppy — while
panning felt great. He was right, and the leg was wrong.

The scenario drives `setViewport` + `layoutSubtreeIfNeeded` on a headless harness
of notes and Markdown documents. It measures **layout**. It never rasterizes,
never composites, and holds no live agent, terminal or browser surface. But a pan
translates content at a fixed scale, while a zoom *changes* scale — so every
layer-backed subtree has to be re-rendered. A 30-second `sample` of the real
gesture:

| cost | samples | what |
|---|---|---|
| `CA::Layer::display_if_needed` | ~2,600 | re-rasterizing at the new scale |
| forced `layoutSubtreeIfNeeded` beneath it | ~960 | the redraw dragging deep tile subtrees |
| chrome floors (`refreshZoomDependentChrome`) | ~380 | the per-step title-bar repaint |
| the camera itself | ~380 | what two slices of work optimised |

The camera was the *third* largest cost and the only one the scenario could see.

**The fix to the witness.** It now counts chrome redraw invalidations, which is
deterministic and headless for the same reason the camera budgets count bounds
writes instead of timing AppKit: the invalidation is the decision we control and
the redraw is its consequence.

| metric | budget | pan | zoom |
|---|---|---|---|
| `chromeRedraws` | ≤ 16 per tile | **0** | **1,392** |
| `tileLayoutInvalidations` | == 0 | 0 | 0 |

`pan` scoring 0 is what makes the zoom number mean something — the counter reads
zero on a gesture that genuinely does not re-rasterize. The bound is stated in
scale BUCKETS because that is the shape the fix must take: chrome and content hold
steady through a pinch and refine when the bucket changes. Quantising the chrome
floor into 1/8 scale buckets measures **132** — verified as a throwaway
experiment, not committed, because it is product-visible (the bar height steps
while zooming). That addresses chrome only; the ~2,600 samples of content
rasterization are Slice 5's semantic-zoom work.

> **Update (2026-08-14, `array/zoom-unify`).** The bucketing shipped as a
> product decision (Dylan approved the stepped bar), at 4 geometric steps per
> octave rounding DOWN (`--tile-drag-grab-check` guards the direction), and the
> close-button floors were bucketed with it — on raw zoom the × glyph re-minted
> an SF Symbol `NSImage` per tile per step below zoom ~1.22, a cost no layout
> counter could see. Measured now: `zoom.chromeRedraws` **1,392 → 144** (bound
> 192), `zoom.tileLayoutPasses` **1,380 → 144**, invalidation probe `C − E`
> **696 → 144**. The leg stays KNOWN-RED because the product target is ~1
> settling layout per tile per gesture and 144 is one per tile per bucket
> crossing; the number is published every run so the remaining gap stays
> visible.

`tileLayoutInvalidations` is 0 on both today — nothing on the camera path calls
`invalidateForCanvasLayout`. It is a standing regression guard, not a live
finding, and it is recorded as such rather than presented as a win.

#### The larger cost, and the hypothesis it refuted

Counting chrome redraws still missed the biggest block. The sample's largest
single item was the window's own display-cycle layout pass recursing through every
mounted tile, and *nothing asked for it*, so an invalidation counter could not see
it. `tileLayoutPasses` counts the traversal ARRIVING instead:

| metric | budget | pan | fractional-pan | zoom |
|---|---|---|---|---|
| `tileLayoutPasses` | ≤ 1 per tile | **0** | **0** | **1,380** |

The standing hypothesis was that this is inherent to the Slice 3 mechanism — that
a pan moves the plane's bounds ORIGIN (a translation) while a zoom changes its
bounds SIZE, which AppKit treats as a resize and propagates through every subtree.
**That is wrong**, and `--canvas-zoom-invalidation-probe-check` is what refuted it.
Over 60 steps on 12 tiles:

| condition | passes | ms/step |
|---|---|---|
| A — bounds origin only (pan shape) | 0 | 0.003 |
| B — bounds **size** only (zoom shape) | **0** | 0.036 |
| E — production `setViewport`, pan (everything but the zoom branch) | **0** | 0.048 |
| C — production `setViewport`, zoom | **696** | 3.075 |
| D — bounds size only, Auto Layout body | 0 | 0.055 |

B and E are the attribution and both are green: changing bounds size costs no tile
layout at all, and neither does the rest of the camera path. `C − E = 696` is
therefore entirely `refreshZoomDependentChrome`, which this program added in
Slice 3 to stop the grab strip going stale and which calls `layoutChrome()` on
every tile on every zoom step. **It is our own invalidation, not the mechanism** —
so the fix is contained, and needs neither `NSScrollView.magnification` (which
would mean re-hosting the canvas) nor semantic-zoom LOD.

Auto Layout is not the trigger but amplifies each pass ~1.5×, which only matters
once the passes are gone.

The two env-gated experiments on `array/zoom-exp` confirm the chain, and show
chrome redraws and layout passes moving 1:1:

| configuration | `chromeRedraws` | `tileLayoutPasses` | `stepDuration` |
|---|---|---|---|
| baseline | 1,392 | 1,380 | 4.99 ms |
| `ARRAY_EXP_CHROME_BUCKETS=1` | 132 | 132 | 5.00 ms |
| `ARRAY_EXP_ZOOM_CACHE=1` | 0 | 0 | 1.68 ms |
| both | 0 | 0 | 1.62 ms |

The zeroes under `ZOOM_CACHE` are partly a fixture artifact — it defers the chrome
refresh to a settle timer that never fires inside the fixture's synchronous loop —
but the 1:1 movement of the first two columns is the causal evidence.

#### What "always render live" costs, as a number

Dylan has ruled out semantic-zoom LOD: tiles must show real content at every zoom.
That is a constraint on the fix, so the ceiling it implies is published here rather
than argued about in the abstract.

- **With the chrome defect present:** 12 tiles cost 3.075 ms/step, i.e. ~0.26 ms
  per mounted tile per zoom step. A 120 Hz frame is 8.3 ms, so zoom saturates at
  roughly **32 tiles** — and that is with the probe's deliberately simple bodies.
- **With the mechanism alone (condition B):** 12 tiles cost 0.036 ms/step, ~0.003
  ms per tile — essentially flat. Extrapolated, the plane itself would not
  saturate a frame until thousands of tiles.

So the constraint looks affordable **once the chrome defect is fixed**, and LOD is
not obviously required to honour it. Two honest caveats: the probe's tiles are
`ManualBody`/`ConstraintBody` stand-ins, not live agent transcripts or WebKit
surfaces; and `canvas.stress` already shows 48 real tiles at 7.9 ms/step for a
**pan**, which is the real upper bound on what "always live" costs today and is a
separate problem from zoom. Revisit the LOD decision against these numbers, not
against the principle.

#### The two real fixes that came before, and still hold



Same canvas, 120 zoom steps walking the scale continuously.

| metric | budget | originally | after the plane | after the inset fix |
|---|---|---|---|---|
| `zoom.stepDuration` | ≤ 8.3 ms | 48.4 ms (584%) | 49.1 ms (592%) | **4.7 ms (57%)** |
| `zoom.boundsWrites` | == 0 | 1,440 | **0** | 0 |
| `zoom.modelWrites` | == 0 | 0 | 0 | 0 |
| `zoom.proseMeasurements` | == 0 | 15,134 | 14,490 | **0** |
| `zoom.cameraMutations` | ≥ 1 (teeth) | — | 240 | 240 |
| `zoom.screenFrameMismatches` | == 0 (teeth) | — | 0 | 0 |

**This leg took two independent fixes, and the middle column is why the second one
was worth measuring rather than assuming.** The plane removed the original cause
completely — `boundsWrites` 1,440 → 0, and `canvas.camera-slope` proves the camera
writes no tile geometry at any tile count — and the wall clock did not move at all.
A second defect had been sitting underneath, fully masked.

That defect: a tile's chrome floors are `max(worldConstant, screenPx / zoom)` so
the move-grab strip stays usable when zoomed out, and
`contentTopInsetWorldHeight` was aliased to that floor. Because `minScreenGrabPx`
(28) is larger than `titleBarHeight` (24), the floor is active for every zoom below
**1.167** — so on this 0.4–1.0 sweep the body was re-framed on literally every
step, and the document reflowed each time.

The fix decouples the inset from the floor: it is now the unfloored
`titleBarHeight`, so a camera move never re-frames a tile body. The visible
consequence is that at low zoom the enlarged grab strip **overlays** the top of the
body instead of pushing it down. Chrome geometry itself is untouched — the strip,
close button and drawn bar keep their screen-px floors, which
`--tile-chrome-scale-check` and `--camera-chrome-redraw-check` still assert.

Two witnesses changed with it, for the same reason the camera anti-teeth changed in
Slice 3: `--tile-chrome-scale-check` and `--tile-world-bounds-check` both asserted
`contentTop == flooredBarHeight`, which encoded the aliasing rather than a property.
They now assert what is actually required — the body's top does not vary across a
zoom sweep (measured from the laid-out views, not re-derived from the property
production lays them out with), the title bar always reaches the body so no
unpainted strip can open, and a zoom never calls `setFrameSize` on the body at all.
That last one is unconditional now; it previously held only while the floor
happened to sit still.

### `canvas.camera-slope` — gating, green

```sh
.build/debug/Array --perf-budget-camera-slope-check
```

The camera's **complexity** witness. The three scenarios above each measure one
fixed canvas, so all three can be green while the camera is still
O(installed tiles) — they never change that number. This one sweeps **installed**
tiles `16 → 128` while holding the **visible** count fixed at 12 (a cluster near
the origin stays on screen; filler tiles sit far outside the viewport at both
zooms), at zoom 1.0 and 0.35, 40 pan steps each.

| metric | budget | before the plane | after |
|---|---|---|---|
| `camera-slope.cameraMutations` | == 320 | 0 | **320** |
| `camera-slope.tileGeometryWrites` | == 0 | 18,720 | **0** |
| `camera-slope.writeSlope` | == 0 | 218.4 | **0** |
| `camera-slope.screenFrameMismatches` | == 0 (teeth) | 0 | 0 |
| `camera-slope.worstStepDuration` | ≤ 8.3 ms | 0.40 ms | **0.004 ms** |

Before the retained world plane, geometry writes per step tracked installed count
exactly — 15 / 31 / 62 / 124 for 16 / 32 / 64 / 128 tiles — and `cameraMutations`
was 0 because nothing applied the camera in one place. Both are now flat: the
camera writes one view's bounds and no tile geometry at all, at any tile count.

`screenFrameMismatches` is the budget with teeth, and it is green today. It
compares every visible tile's ACTUAL rect — converted through whatever view tree
hosts it — against `CanvasEngine.tileScreenFrame`. Without it the three zeroes
above would also be satisfiable by a canvas that stopped moving tiles entirely.
It is deliberately phrased to survive the migration: today a tile's frame IS its
screen rect, afterwards an ancestor's transform produces the same rect from an
unchanged tile frame.

Duration here is a coarse alarm only, **not** the scaling signal: the fixture uses
cheap `DescriptorTileNSView`s so 128 tiles × 8 configurations stays affordable in
the matrix. `canvas.stress` owns the real-content cost curve.

This leg left `MATRIX_KNOWN_RED` when the plane landed. `canvas.zoom` did not —
see below, because its remaining cost turned out to be a different defect.

### `canvas.magnify-slope` — work slopes green, duration slope KNOWN-RED

```sh
.build/debug/Array --perf-budget-magnify-slope-check
```

The same complexity question as `camera-slope`, asked of ZOOM — which
camera-slope structurally cannot ask, because a pan never enters the
zoom-dependent chrome branch. Sweeps installed tiles `16 → 128` with the visible
count pinned at 12, 40 zoom steps per configuration. It exists because
hypothesis 6 of the zoom program ("the chrome refresh is O(visible)") was
**wrong** — it was O(installed), measured at 4/9/19/38 chrome refreshes per step
as installed count grew with visible pinned.

| metric | budget | before visible-only refresh | after |
|---|---|---|---|
| `magnify-slope.chromeRedrawSlope` | == 0 | 33.6 | **0** |
| `magnify-slope.layoutPassSlope` | == 0 | 33.6 | **0** |
| `magnify-slope.durationSlope` | ≤ 0.5 ms | 23.08 ms | **~1.9–2.3 ms, RED** |
| `magnify-slope.worstStepDuration` | ≤ 8.3 ms | 26.75 ms | ~3.5 ms |

The work counters are flat — a zoom step performs the same number of chrome
refreshes and layout passes at 128 installed tiles as at 16. The duration slope
that remains is **AppKit's own view-tree traversal**: any bounds write on the
world plane makes the next layout pass walk every installed subtree, even when
zero tiles get laid out (the invalidation probe's condition B measures the
bounds-size write itself at 0 passes). That residual is not reachable from our
code without culling installed views, which the always-render-live constraint
forbids — so the leg is KNOWN-RED against the product target and publishes the
number every run.

### `canvas.gesture-transition` — gating, green

```sh
.build/debug/Array --perf-budget-gesture-transition-check
```

The seam every pure-gesture scenario is blind to. The complaint that reframed
the zoom program — *"it lags when zooming when you start panning"* — was a
transition defect: deferred zoom work (a settle burst, per-step-re-armed
debounce timers whose fsync-heavy saves detonated ~200 ms after the last camera
step, chrome floors still moving) landing on the first pan frames. Four windows
over the `canvas.pan`/`canvas.zoom` fixture:

| window | drive | what it proves |
|---|---|---|
| P | 60 steady pan steps | the baseline median |
| T | 30 zoom steps → immediately 30 pan steps | the handoff inherits nothing |
| Zc | 30 pure zoom steps over a fixed sequence | the interleave's control |
| I | strict interleave over the SAME zoom sequence | pans between zooms add zero |

| metric | budget | measured |
|---|---|---|
| `gesture-transition.transitionPanChromeRedraws` | == 0 | 0 |
| `gesture-transition.transitionPanLayoutPasses` | == 0 | 0 |
| `gesture-transition.excessChromeRedraws` (I − Zc) | == 0 | 0 (84 == 84) |
| `gesture-transition.excessLayoutPasses` (I − Zc) | == 0 | 0 (84 == 84) |
| `gesture-transition.transitionStepOverhead` | ≤ 1 ms | 0.05 ms |
| `gesture-transition.worstStepDuration` | ≤ 8.3 ms | ~5 ms |

`transitionStepOverhead` is the direct encoding of the complaint: the worst of
the first five pan steps after a zoom, over the steady pan median — the lag was
a spike, and a mean hides a spike. Structural guards throw if the interleave
degenerates (fewer than two distinct zooms, or no actual pan), because every
zero above passes vacuously on a drive that did nothing.

### The unified camera driver's own witnesses

Two correctness legs guard `CanvasCameraDriver` (the display-paced input
pipeline that .plans/22 Slice 2 specified — one owner for scroll pan, Cmd+scroll
zoom, pinch and the pinch glide):

- `--canvas-camera-coalesce-check` — the Slice 2 contract: N input events in
  one display interval cause a bounded number of camera commits and preserve
  the final desired viewport. Control: 6 direct `setViewport` calls count 6
  applies (the counter cannot go blind). Driven: 6 precise scroll events
  through the real `scrollWheel` handler with the driver's clock frozen count
  **2** (leading-edge apply + one coalesced flush) — it was 6 before the
  driver, one full funnel pass per event.
- `--canvas-zoom-momentum-check` — glide mechanics on deterministic time: a
  flick above the engage threshold glides ~46 steps and terminates; a
  deliberate stop stays dead; a new pinch or any EXTERNAL viewport write
  (navigation snap, pointer drag) cancels the glide; the zoom clamp stops it
  in ~2 steps where decay alone takes ~45; and pan input COMPOSES with a live
  glide in ONE commit — the property whose absence was the tracking error a
  hand read as transition lag.

### `transcript.delta` — KNOWN-RED on duration, green on every count

```sh
.build/debug/Array --perf-budget-transcript-delta-check
```

The streaming axis. 20 tail-revision deltas — the shape a streaming answer
actually produces, where the open block's revision advances while its id and
position stay put — over histories of 10 / 100 / 1,000 / 10,000 rows, one entry
per turn with one block in each.

| metric | budget | before | after the row index |
|---|---|---|---|
| `transcript-delta.worstVisitsPerDelta` | ≤ 64 | 10,000 | **1** |
| `transcript-delta.visitSlope` | == 0 | 9,990 | **0** |
| `transcript-delta.fullFlattens` | == 0 | 80 | **0** |
| `transcript-delta.rowsLost` | == 0 (teeth) | 0 | 0 |
| `transcript-delta.deltasWithoutInvalidation` | == 0 (teeth) | 0 | 0 |
| `transcript-delta.worstInvalidatedTopLevel` | ≤ 2 | 1 | 1 |
| `transcript-delta.worstDeltaDuration` | ≤ 8.3 ms | 43.7 ms | **36.3 ms** |

**The fixture's SHAPE is load-bearing, and the first version got it wrong.** It
originally held one entry with `history` blocks, which exercises the row walk but
is structurally blind to any per-delta pass over `document.entries` — and
`prepareToolDetailLifecycle` builds a dictionary over every entry on every delta.
A real transcript is the opposite shape. Switching to one entry per turn made the
measured cost *worse* (36.0 → 43.7 ms), which is the only reason that second pass
was ever visible. A fix validated against the original fixture would have read
greener than the truth.

**Why it is still RED, and why that is the useful part.**
`apply(document:patch:)` took a patch naming its changed nodes and called
`flatten(document)` anyway. The row index fixed that completely — 10,000 block
visits per delta became 1 — and **the wall clock did not move**. This is the same
pattern `canvas.zoom` hit one axis over: an architectural defect masking a second
cost underneath it. A profile of 1,598 main-thread samples at 10,000 rows:

| cost | share | what |
|---|---|---|
| `applyUnscrolled` presentation passes | ~56% | `rowsByID` rebuild, snapshot append, role-change scan, diffable apply |
| `prepareToolDetailLifecycle` | ~35% | a dictionary over every entry, plus block-id sets |
| the incremental path itself | ~8% | **a slot lookup rebuilt over every row — introduced by the fix and removed after the profile named it** |

Both remaining costs are named in `.plans/22` Slice 4 and neither is started.
That last row is worth keeping: the count witness did not watch the new code's own
work, so only the duration alarm caught it. This is exactly the split the two-gate
rule exists for — counts name the defect, duration notices what the counts do not
watch.

**Correctness is a separate leg, deliberately.**
`--transcript-delta-index-oracle-check` exists because every count budget above
still passes if the cheap path rebuilds the WRONG row. It drives the real
`apply(document:patch:)` funnel through ten mutations (tail revision, middle
revision, nested child, entry role change, insert, removal, open reasoning,
reasoning finishing, finished reasoning revising, an unknown id) and after each
asserts the live index is indistinguishable from a from-scratch walk — and
asserts WHICH path ran, so it fails rather than passing perfectly the day the
fast path declines everything.

### `canvas.geometry-hold-probe` — gating, display-dependent, green

```sh
.build/debug/Array --perf-budget-geometry-hold-probe-check
```

The default gating fixture remains 10 real managed-agent tiles and 60 ticks.
Architecture work may reuse the identical harness at larger sizes without
changing the gate:

```bash
PERF_GEOMETRY_HOLD_TILES=50 PERF_GEOMETRY_HOLD_STEPS=12 \
  .build/debug/Array --perf-budget-geometry-hold-probe-check
```

The overrides must be positive; `PERF_GEOMETRY_HOLD_TURNS` can vary transcript
depth. A 2026-08-15 5/10/25/50 sweep measured one-bake medians of
14.56/28.05/70.79/137.89 ms while held p95 stayed at or below 0.12 ms. The
result proves both halves of the architecture: held motion removes the repeated
cascade, and native residency must be bounded because the one final bake still
scales linearly with installed deep subtrees.

### `canvas.surface-host-slope` — gating, display-dependent, green

```sh
.build/debug/Array --perf-budget-surface-host-slope-check
```

The Shape A camera witness for the unbounded-canvas program
(`.plans/34` I15). Four arms over ONE real managed-agent fixture at
5/15/25/50 tiles, ~150 s, ABBA with both observations pooled:

- **native** — real `ManagedAgentTileNSView`, all installed;
- **unculled** — flat layer-hosting surface hosts, all installed;
- **culled** — surface hosts, only the viewport's presentation set installed;
- **parked** — surface hosts for every tile AND every real agent body still
  alive, held in the window but outside `CanvasWorldPlaneView`. This is the
  shippable configuration: an interim `cacheDisplay` producer needs the real
  body to keep laying out and streaming (`.plans/34` I11), and that is only
  affordable if a camera step cannot reach it.

Every step is a real production `CanvasCameraDriver` commit, reached by
inverting the driver's own log-zoom gain, so `isApplying` is true, cursor-rect
housekeeping defers exactly as it does in a gesture, and the visible-tile chrome
refresh is inside the measurement. Surfaces are the real tiles' pixels, baked
once per host through `cacheDisplay` before any clock starts — one DISTINCT bake
per host, so Core Animation cannot collapse the scene onto a shared texture.
Zone chrome is on and the gesture reaches the real overview at zoom 0.2.

**Array-owned CPU per camera step (p50), 2026-08-18:**

| installed | native | unculled | culled | parked |
|---:|---:|---:|---:|---:|
| 5 | 9.39 ms | 0.08 ms | 0.07 ms | 0.07 ms |
| 15 | 30.31 ms | 0.11 ms | 0.07 ms | 0.11 ms |
| 25 | 57.01 ms | 0.14 ms | 0.07 ms | 0.17 ms |
| 50 | 140.57 ms | 0.23 ms | 0.06 ms | 0.19 ms |

`parkedVsNativeRatio` 0.001, `parkedDurationSlope` 0.122 ms over 5 → 50;
`culledVsNativeRatio` 0.000, `culledDurationSlope` -0.014 ms;
`unculledDurationSlope` 0.155 ms. The native arm reproduces the ladder
`.plans/31` published (15.29/30.50/72.46/132.72 ms for the whole pump at
5/10/25/50), which is the precondition for reading any other number here.

The native arm is the noisiest thing in the leg: an earlier run of the same
three arms on the same machine read 9.64/29.00/50.45/111.78 ms, ~25% under the
table above at the top of the sweep. Read the ratios and the slopes, which held
across both runs; do not treat a single native median as a machine constant.

**Array CPU and the Core Animation flush are separate stages, and that is the
point.** The first version of this leg reported one number per step and looked
119% over budget with a 13% late share — while Array's own camera work was
0.07 ms. The whole signal was `CATransaction.flush()`, which can block on the
render server: in the surface arms it stays flat at ~2 ms p50 / ~9–10 ms p95 at
every count, while in the native arm it scales 6.60 → 11.23 → 16.85 ms because
there is genuinely more to commit. `culledFlushP95` and `culledStepP95` are
published, never gated as Array cost, and a returning flush is never called
"presented".

**A parked live body costs nothing measurable.** `parkedVsUnculledRatio` is
0.824 — keeping all 50 real agent bodies alive, laying out and ingesting events
beside the surfaces, is inside the noise of the surfaces alone, and
`parkedTranscriptLayouts` is exactly 0 across every count and both ABBA
observations. A camera step cannot reach a body that is not under the world
plane, which is the whole mechanism. Three teeth stop that zero from being read
as a body that simply died: `parkedStreamingCards` (the ingested event became
transcript content), `parkedBakeColors` (`cacheDisplay` of a body clipped out of
every draw still yields real pixels — 41 distinct sampled colours), and
`parkedStreamingPixelDelta` (a bake taken after the event differs from one taken
before, 6,867 bytes). Together they say the interim `cacheDisplay` producer
exists and is affordable.

`parkedStreamingLayouts` was the first attempt at that liveness tooth and it was
wrong: a content change does not move `AgentTranscriptListView`'s own frame, so
its `layout()` legitimately never runs, and the counter read 0 for a body that
was working fine. `AgentTranscriptListView.enqueue` also gates presentation at
30 Hz, so the model gains its card a frame before the view is asked to show it —
the witness drives `flushPendingVisualUpdate()` (the same call the gate makes)
rather than racing a timer.

Two more findings worth carrying forward:

- **AppKit sends `viewDidChangeBackingProperties` to every installed surface
  host on every camera step** — exactly `hosts x steps` (300 = 5 x 60,
  1500 = 25 x 60). The trap is real; the host owns its layer and applies a
  bucketed scale policy, so `cameraCausedRasterRequests` stays 0.
  `PERF_SURFACE_HOST_NAIVE_SCALE=1` swaps in the naive policy that follows the
  live effective scale and drives that counter to 1,200 — the permanent negative
  witness. It is a witness about the DECISION, not the cost: re-publishing the
  same image barely moves the clock, and a real producer would re-render.
- **With the body gone, chrome is essentially all of Array's camera cost.**
  Sweeping `ARRAY_CHROME_BUCKETS` at 25 tiles: 1 → 15 redraws, 0.08 ms p50;
  4 (shipped) → 50 redraws, 0.07 ms; 16 → 180 redraws, 0.87 ms. This is the
  evidence for moving chrome to a screen-space compositor overlay under Shape B,
  and it also refuted the first hypothesis for the step-time tail — more chrome
  crossings produced FEWER late steps, because the tail was the flush.

Overrides for architecture work, none of which change the gate:
`PERF_SURFACE_HOST_TILE_COUNTS` (ascending, each >= the visible cluster),
`PERF_SURFACE_HOST_VISIBLE`, `PERF_SURFACE_HOST_TURNS`,
`PERF_SURFACE_HOST_STEPS`. The default stops at 50 because every host needs its
own baked surface and a bake needs a real agent tile: 100/200 are reachable but
are a deliberate memory event.

`unculledDurationSlope`'s floor is `-8.3 ms`, not 0, because a slope between two
sub-millisecond medians can legitimately land below zero on noise — a run at
`PERF_SURFACE_HOST_TILE_COUNTS=5,15` reported -0.056 ms and failed a metric that
was only ever meant to be published. A published slope needs a sign-safe floor.

### `--tile-surface-residency-check` — gating, display-dependent, green

```sh
.build/debug/Array --tile-surface-residency-check
```

The production counterpart to `canvas.surface-host-slope`, and the first
production slice of the unbounded-canvas program (`.plans/36`). Everything runs
through the real `CanvasNSView`, the real `CanvasCameraDriver` (transitions
arrive via `noteScrollZoom` -> `onActivityBegin` and `qaMarkSettledNow` ->
`onSettle`), and real `ManagedAgentTileNSView`s. The feature it exercises is OFF
by default (`continuum.tileSurfaceResidency.enabled`, env override
`ARRAY_TILE_SURFACE_RESIDENCY`).

Its subject is not speed. It is the requirement speed has to survive: **a user
must not be able to tell.** What it gates:

- **producer fidelity** — a surface against a native bake of the same body at
  the same instant and resolution, mean channel difference **0.000** against a
  0.25 threshold. `TILE_SURFACE_HALF_SCALE=1` is the negative witness and drives
  it to **1.156**, so the gate fails when it should;
- **sharpness never regresses** — a surface less sharp than the screen needs is
  refused, and the refusal reason is asserted, not inferred;
- **exactly-once input** — a click during the settle window promotes through
  `hitTest` and lands on the real body;
- **streaming through a park** — events ingested while surfaced are in the
  restored transcript;
- **flag off changes nothing** — no demotions, no bakes, an empty park, and the
  native cascade still paid;
- **no stranded state** — removing a tile mid-gesture and switching zones both
  leave the park empty and the store pruned;
- **camera cost** — Array-owned CPU per step, 12 real agent tiles: **24.34 ms
  native -> 0.11 ms surfaced**, gated under one frame.

**The gesture-start transition is published, NOT gated, and that is
deliberate.** It was a gate, it fired at **~4.6x a native step**, and it killed
the "surfaced in motion only" policy. The demote path is timed per call and the
cost is fully attributed: host construction/reuse **0.00 ms**, `setContentView`
(removing the deep body) **2.03 ms/tile**, `park.addSubview` (re-adding it)
**2.80 ms/tile**. That is plain AppKit subtree surgery, so any policy that
reparents per gesture pays it twice per tile per gesture. Keeping it as a gate
would assert a decision rather than protect a behaviour; what the leg protects
is the mechanism, which the next policy reuses unchanged. One guard does remain
on the instrument itself: the breakdown must account for at least 60% of the
commit stage it explains, so a published number cannot quietly become fiction.

Three hypotheses for that transition cost were measured and **refuted**: a fresh
`CALayer` texture upload per gesture (host retention moved it 0.1 ms), an empty
`visibleRect` in the park (sizing the park changed nothing), and the
unconditional forced offscreen pass in `AgentTranscriptListView.layout()`
(gating it moved the native step 0.2 ms — those calls were already nearly free,
and that change was reverted rather than kept for no benefit).

### `canvas.proxy-scene-probe` — OPT-IN, green cost probe; rejected UX

```bash
.build/debug/Array --perf-budget-check --scenario canvas.proxy-scene-probe
```

This is the first supported motion-presentation witness, not the shipping
mechanism. It leaves real managed-agent transcript trees installed and held,
then presents one synthetic tile-shell image per tile beneath one Array-owned
root layer affine. The layer-hosting proxy contains no AppKit subviews. It runs
5/10/25/50 tiles by default; `PERF_PROXY_SCENE_TILE_COUNTS`,
`PERF_PROXY_SCENE_TURNS`, and `PERF_PROXY_SCENE_STEPS` provide positive opt-in
overrides.

The first 60-tick sweep measured proxy p95 at 0.03/0.03/0.04/0.05 ms from 5 to
50 tiles while stepped p95 rose 20.21/38.61/93.24/170.95 ms. Each cell requires
one root mutation per target, zero native bounds writes/layouts during motion,
one final bake, a moving visual witness, exact anchor/world mapping, no AppKit
subviews in the proxy, and zero final camera mismatches. The probe deliberately
does not claim cache/provider fidelity, mixed WKWebView/Ghostty coverage,
interaction routing, or production `CanvasNSView` lifecycle.

A subsequent default-off dogfood integration used those synthetic shells and
was explicitly rejected on 2026-08-16 because visible tiles lost their full
detail during zoom. That production code was removed before commit. Preserve
this scenario only as evidence that an owned root affine is cheap; it is not a
visual design precedent. Any future presenter must retain full transcript,
browser, terminal, zone, status, and chrome detail throughout motion.

The missing real-content A/B for the backing cascade. It builds 10 real
`ManagedAgentTileNSView` subtrees with six transcript turns each, drains their
first render, then runs ABBA over two causal arms with 60 display commits apiece:

- **stepped:** write a distinct world-plane bounds size on every tick;
- **held:** pump the same 60 frames with geometry unchanged, then pay exactly one
  final bounds-size bake.

Both arms run `window.displayIfNeeded()` and `CATransaction.flush()`. The flush is
load-bearing: layer-backed work lands at the transaction commit, and omitting it
would recreate the harness blindness that once reported 144 invalidations and 0
executed draws. The held arm deliberately has no visual presentation mechanism;
this is an upper bound on recoverable geometry/backing work, built before making
that design decision. A raw transform on an AppKit-owned backing layer remains
out of bounds.

Two establishing runs on 2026-08-14:

| arm / metric | run 1 | run 2 |
|---|---:|---:|
| stepped p50 | 31.07 ms | 30.02 ms |
| stepped p95 | 39.47 ms | 37.35 ms |
| stepped frames over 8.3 ms | 100% | 100% |
| held p50 | 0.01 ms | 0.01 ms |
| held p95 | 0.02 ms | 0.01 ms |
| held frames over 8.3 ms | 0% | 0% |
| one final bake p50 | 27.89 ms | 28.36 ms |
| gross recoverable, bake included | **98.5%** | **98.5%** |
| stepped bounds-size writes / transcript layouts | 120 / 1,200 | 120 / 1,200 |
| held-tick bounds-size writes / transcript layouts | 0 / 0 | 0 / 0 |

The shape matches the real-pinch profile: every bounds-size write reaches every
real transcript subtree, and a held tick reaches none. The standing
`heldGestureCostRatio` ceiling is 0.10; both establishing runs measured 0.015,
leaving roughly 6× headroom without turning current timing into a high-water
mark. The count budgets are the attribution: 10 real tiles, 120 stepped writes,
0 held-tick writes, 2 final bakes, 1,200 stepped transcript layouts, 0 held
layouts, and a clean camera oracle after restoring baseline geometry.

This is a display-dependent matrix leg and skips with
`CONTINUUM_SKIP_UI_BASELINES=1`. It is not KNOWN-RED: if the held arm stops
recovering the cascade, the premise for the geometry-hold mechanism has failed
and implementation should pause rather than normalize the result.

### `canvas.scroll-magnification-probe` — OPT-IN, intentionally red

The first supported-presentation experiment after geometry-hold established the
recoverable fraction. It puts the same 10 real managed-agent trees behind a
borderless, scrollerless `NSScrollView` and drives AppKit's documented
magnification API around a fixed anchor. The anchor is exact (`0.000 px` error),
but the performance hypothesis fails:

| metric | run 1 | run 2 |
|---|---:|---:|
| magnification p50 | 36.48 ms | 32.62 ms |
| magnification p95 | 44.43 ms | 43.25 ms |
| frames over 8.3 ms | 100% | 100% |
| transcript layouts over 120 ticks | 1,200 | 1,200 |

The supported live boundary reproduces the backing-properties cascade and is
not the shipping presenter. The same probe measures the fallback compositor
floor: a shallow bitmap proxy runs at **0.04/0.07 ms p50/p95** with zero native
layouts, but fresh gesture-time capture costs **22.07 ms and 24.4 MiB** for a
1600x1000 Retina viewport. It also cannot generically capture WKWebView/Ghostty
pixels or reveal uncaptured world content on zoom-out. Capture-on-pinch is
therefore rejected; the surviving design is a bounded cache prepared while idle.

This scenario has no matrix leg. Its red budgets preserve why the rejected
candidates must not be rediscovered and normalized into production.

### `canvas.stress` — OPT-IN, not in the matrix

```sh
.build/debug/Array --perf-budget-check --scenario canvas.stress
```

48 real `ManagedAgentTileNSView` tiles carrying real multi-turn transcripts,
across 6 real `ZoneLayer`s, panned 60 steps at zoom 0.35. It is opt-in because it
builds a deliberately oversized workspace: slow, memory-hungry, and Array is not
alone on the machine. It maps the synchronous scaling curve, which you measure
deliberately rather than on every commit.

Knobs (all optional): `PERF_STRESS_ZONES`, `PERF_STRESS_TILES_PER_ZONE`,
`PERF_STRESS_TURNS`, `PERF_STRESS_ZOOM`, `PERF_STRESS_STEPS`.

**`stress.tilesLaidOutPerStep` went 48 → 0 with the retained world plane.** It
was the missing presentation-working-set bound stated as a count, and the plane
retired it: a camera step lays out no tiles at all.

**The duration moved the other way, and that is a real tradeoff.** On this
machine the stress pan was ~5.4–6.0 ms/step before the plane and is ~7.4–9.3
ms/step after (median ~7.7, noisy enough that repeated runs matter). All work
counts are zero, so the remaining time is not Array's: a `sample` of the loop
puts **131 of 5,588 samples (2.3%) in the camera** and the rest in AppKit
recursing `_layoutSubtreeWithOldSize:` through 48 deep agent-tile trees, with no
Array frames at the leaves. Any camera write on an ancestor triggers that
traversal — measured at 0.001 ms/step with the write removed entirely, 7.2 ms via
`setBoundsOrigin`, 8.2 ms with a nested content view, and 8.8 ms translating by
frame origin instead. Reducing it is a property of how many and how deep the tile
view trees are, which is Slice 5's bounded presentation working set, not the
camera's.

## The scaling curve

Measured on a debug build, 40 pan steps per row. This is the data that decides
what to optimise next; re-measure it rather than trusting the numbers to age
well.

**Cost scales linearly with TILE COUNT** (~0.11 ms per tile per step):

| tiles | zones | ms/step | ms/tile | fixture observation |
|---|---|---|---|---|
| 8 | 1 | 0.71 | 0.089 | below 8.3 ms |
| 16 | 2 | 1.52 | 0.095 | below 8.3 ms |
| 32 | 4 | 3.27 | 0.102 | below 8.3 ms |
| 48 | 6 | 5.36 | 0.112 | below 8.3 ms |
| 64 | 8 | 7.67 | 0.120 | near 8.3 ms |
| 96 | 12 | 13.96 | 0.145 | above 8.3 ms and rising |

On this reference Mac and this synchronous Debug fixture, the measured mean
crosses 8.3 ms between 64 and 96 tiles. This is evidence of an installed-tile
scaling defect, **not** a shipping FPS ceiling: the loop does not include input,
drawing, CA commit or presentation, and no M2 Air result was measured. Do not
derive a machine policy by multiplying this curve by an estimated CPU ratio.

**Transcript depth is nearly free for this static PAN loop.** This was the
surprise, and it contradicts the obvious camera-cost intuition:

| turns per agent | ms/step |
|---|---|
| 1 | 5.35 |
| 3 | 5.36 |
| 12 | 5.45 |
| 24 | 5.42 |

24× the transcript content costs 1% more in this fixture.
`AgentTranscriptListView` virtualizes materialized views, so this camera step pays
for the tile's view tree rather than all conversation rows. This result says
nothing about live streaming, hydration, memory, timers, image discovery, or
restore. The live update path still performs work proportional to transcript
history; [scalability-tdd.md](./scalability-tdd.md) defines the missing witness.

**Zoom changes the observed cost, but this sweep does not isolate visible
count:**

| zoom | on screen (of 48) | ms/step |
|---|---|---|
| 1.00 | 6 | 2.34 |
| 0.70 | 8 | 4.23 |
| 0.35 | 28 | 5.36 |
| 0.10 | 44 | 4.95 |

Note 0.10 is *faster* than 0.35 with more tiles visible: on-screen count is not
the driver, because **every tile is laid out whether visible or not**. That is
evidence for separating offscreen presentation lifecycle; directly skipping the
old geometry write is unsafe because a tile can remain frozen at its previous
onscreen frame.

### Where the time actually goes

A `sample` of the stress pan loop shows essentially **no Array code at all**:
`CanvasNSView.layoutAllTiles` is 3 samples, `repositionFocusBorderIfNeeded` is 2.
Everything else is AppKit's `-[NSView _layoutSubtreeWithOldSize:]` recursing
~10 levels through each agent tile's view hierarchy.

So the measured per-tile pan cost is **the size of the agent tile's view tree**,
triggered by moving its frame. The second-pass order is:

1. **Stop moving every tile view.** Put world-attached content in one retained
   world-content/clip view, keep screen-fixed overlays outside it, and mutate the
   camera ancestor once. Applying `setBoundsOrigin` directly to the current mixed
   `CanvasNSView` would also translate HUDs and violate origin-zero assumptions.
2. **Virtualize presentation activity.** Offscreen tiles should keep semantic
   state but perform no AppKit applies, timers, animations, image scans or tool
   refreshes until one catch-up apply. Merely skipping a frame write can freeze a
   tile at its previous onscreen position, so geometry culling is not sufficient.
3. **Shrink the common tile tree.** Lazy or dead view removal lowers the linear
   coefficient while the retained-camera seam is being built; it does not make
   the current layout loop constant-time.

### The float-tolerance trap

Worth its own note, because it made things **worse than no optimisation at all**
and it is invisible by inspection.

`applyTileGeometry` skips writes whose value did not change. Written with `!=`
that guard is correct at zoom 1.0 and silently useless everywhere else: AppKit
does not store `bounds` verbatim, it keeps the bounds/frame SCALE and recomputes
the size, so a bounds set to `420` reads back as `420.00000000000006`. The exact
comparison never matches, so the guard rewrote bounds for every tile on every
step — and each write re-marks that tile's whole subtree for layout.

Measured over 48 agent tiles at zoom 0.35: **39.9 ms/step with `!=`, 5.4 ms/step
with a tolerance** — a 7.4× difference that a 12-tile, zoom-1.0 scenario reported
as perfectly green. Compare geometry with a tolerance below one device pixel, and
make sure at least one scenario runs at a zoom that is not 1.

## Frame stats on a real gesture

```sh
CONTINUUM_FRAME_STATS=1 open --env CONTINUUM_PROJECT_ROOT=$HOME/array-scratch \
  "$HOME/Desktop/Array Dev.app"
```

Pan or zoom, then read stderr:

```
[frame-stats] gesture: 143 frames, 138 camera steps @ 120 Hz (8.3 ms budget) —
p50 8.34 ms (120 fps), p95 9.10 ms, worst 24.60 ms, 3 late (2%)
```

A trace is bracketed by camera activity rather than AppKit gesture phases. That
covers every path reaching `setViewport`, but the current recorder does not label
pan versus zoom. Its display link stays alive for the 250 ms quiet settle window
so the gesture can close reliably, while rolling and completed statistics stop
one interval after the tick that observed the final camera step. That following
interval retains AppKit/CA work the camera commit scheduled after the recorder
callback; the remaining smooth idle callbacks are excluded. Keep the missing
gesture label with any published result.

`maximumFramesPerSecond` is the panel maximum, not proof of the current dynamic
ProMotion, low-power, or external-display cadence. The printed reciprocal of p50
is a median-interval shorthand, not achieved average FPS, and the current
"late" threshold of 1.5× cadence intentionally counts hitches rather than every
missed refresh. Use p50/p95/p99/worst and missed-vsync counts from an explicitly
identified display mode before making a shipping claim.

For an on-canvas live readout, add `CONTINUUM_FRAME_HUD=1`. The HUD shows
time-weighted FPS, late-frame share, and p95 over a rolling 30-frame window. It
reuses the recorder above and publishes at most four label changes per second;
there is no second timer, display link, animation, traversal, event handling, or
accessibility presence. Logging and the HUD are independently opt-in; normal
runs instantiate neither recorder nor overlay.

### Clean dogfood split after symbol freeze (2026-08-14/15)

The current `array/zoom-unify` preview was rebuilt from the branch and launched
against the preserved 10-agent workspace with frame logging and the live HUD.
One earlier “laggier” feel check was invalid: the preview predated the symbol
freeze and a separate `--ui-geometry-check` process was consuming 47–85% CPU.
After that process ended and the preview was rebuilt, Dylan's verdict was:
“that feels good, still a little bit” and, with the live HUD, “it barely drops
when panning … as soon as I zoom it goes as low as 30.”

The uncontaminated log has the same bimodal shape as the tripwire profile:

- pan-like gesture: p50/p95 **8.33/8.33 ms**, **3% late**;
- zoom examples: p50/p95 **23.13/33.60 ms**, **59% late**, and
  **22.87/51.04 ms**, **53% late**;
- another zoom retained an 8.33 ms median while p95 reached **53.68 ms** and
  **40%** of frames were late—the reason median-derived “120 FPS” was a
  misleading HUD headline.

The HUD now reports a rolling 30-frame, time-weighted average FPS at 4 Hz, so
stall time lowers the headline immediately. It reuses the recorder's display
link; the HUD owns no timer, animation, traversal, or sampling loop. This live
pan/zoom split is the product witness for the same mechanism the geometry-hold
probe names structurally.

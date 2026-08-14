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
| **Frame stats** (`CONTINUUM_FRAME_STATS=1`) | the FRAMES the display actually produced during a real gesture, on real hardware | dogfooding; confirming a fix is felt, not just counted |

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

### `canvas.zoom` — gating, green (was KNOWN-RED through two distinct causes)

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
pan versus zoom and includes the 250 ms quiet settle tail in its interval sample.
Keep those limitations with any published result.

`maximumFramesPerSecond` is the panel maximum, not proof of the current dynamic
ProMotion, low-power, or external-display cadence. The printed reciprocal of p50
is a median-interval shorthand, not achieved average FPS, and the current
"late" threshold of 1.5× cadence intentionally counts hitches rather than every
missed refresh. Use p50/p95/p99/worst and missed-vsync counts from an explicitly
identified display mode before making a shipping claim.

It is inert unless the variable is set, because anything that can log or present
at boot has to stay quiet in QA runs and in front of users.

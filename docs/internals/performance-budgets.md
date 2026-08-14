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

Include an `atLeast` budget as teeth in the other direction. `canvas.pan` asserts
zero bounds writes AND at least one frame write, so the zero cannot be satisfied
by a canvas that quietly stopped laying anything out.

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
| `pan.frameWrites` | ≥ 1 (teeth) | 1428 |

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

### `canvas.zoom` — KNOWN-RED, published

Same canvas, 120 zoom steps walking the scale continuously.

| metric | budget | measured |
|---|---|---|
| `zoom.stepDuration` | ≤ 8.3 ms | **32.1 ms** (387%) |
| `zoom.boundsWrites` | == 0 | **1440** |
| `zoom.modelWrites` | == 0 | 0 |
| `zoom.proseMeasurements` | == 0 | **5474** |
| `zoom.frameWrites` | ≥ 1 (teeth) | 2880 |

These values are a recorded diagnostic run, not a stable Debug/Release
comparison. The fixture currently waits for one layout pass rather than a
semantic "all rows rendered" barrier, so asynchronous transcript work can change
how much prose exists when timing begins.

**Why it is red, and why that is not a bug to bisect.** A zoom step changes every
tile view's frame SIZE. `setFrameSize` scales `bounds` along with the frame, so
the logical size has to be written back — two geometry writes per tile per step.
AppKit re-lays out each tile's entire subtree, and every Markdown/prose row
re-measures at an intermediate width the tile never renders at. A profile of the
zoom loop puts 11,454 of ~11,965 main-thread samples inside
`-[NSView _layoutSubtreeWithOldSize:]`.

Guarding the assignments does not remove this: the bounds write is genuinely
needed after a size change. Suppressing `autoresizesSubviews` across the pair was
tried and made it **worse** (61.7 ms/step, 12,075 measurements).

The fix is architectural: the camera must stop resizing tile views at all. The
first prototype should keep `CanvasNSView` as a fixed viewport, put world content
inside a clipped document/clip view, and keep screen overlays as a sibling, so
logical tile frames remain stable and the camera changes one ancestor. Do not
directly transform an AppKit-owned backing layer. This is a scoped project—hit
testing, cursor rects, zone chrome and chrome-scale floors read screen coordinates
today—not a patch. The alternatives and escalation criteria are in
[infinite-canvas-rendering-research.md](./infinite-canvas-rendering-research.md).

`--perf-budget-zoom-check` is in `MATRIX_KNOWN_RED` so the number is printed on
every run without masking a `canvas.pan` regression. Remove that entry when the
camera stops resizing tiles.

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

**`stress.tilesLaidOutPerStep` is known-red on purpose.** At the default size
the camera lays out all 48 tiles per step against a visible-set budget of 37
(22 on screen × 1.5 + 4). That is the missing presentation-working-set bound —
the architectural item in [scalability-tdd.md](./scalability-tdd.md), kept
visible as a product target, not a regression to bisect. `stress.boundsWrites`
and `stress.stepDuration` are the regression gates and are green.

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

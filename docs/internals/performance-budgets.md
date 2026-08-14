# Performance budgets

Standing, offline performance targets for Array, checked on every matrix run.

[performance.md](./performance.md) is the guidance for *building* a fast surface
and the evidence order for *diagnosing* a slow one. This file is the mechanism
that answers the question neither of those could: **are we at target right now?**

It exists because 0.4.18 shipped a canvas the owner described as "very laggy when
panning and zooming", and there was no instrumentation anywhere in the app to say
whether that was 55 fps or 15 fps, nor any way to tell whether a change helped.

## The two things it gives you

| | what it measures | when to use it |
|---|---|---|
| **Budgets** (`--perf-budget-check`) | the WORK a scenario does — counts and per-step duration — offline and deterministic | every matrix run; while iterating on a fix |
| **Frame stats** (`CONTINUUM_FRAME_STATS=1`) | the FRAMES the display actually produced during a real gesture, on real hardware | dogfooding; confirming a fix is felt, not just counted |

Neither replaces the other. Budgets prove the canvas stopped doing wasteful work;
frame stats prove the user's gesture got smoother. A green budget run is not a
claim about how the app feels.

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
2. **A budget is a published target, not a high-water mark.** The limit is what
   the product needs — a 120 Hz frame is 8.3 ms — not what the code happens to do
   today. A budget set to "current + 10%" ratchets slowness in and never fails.

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

### `canvas.zoom` — KNOWN-RED, published

Same canvas, 120 zoom steps walking the scale continuously.

| metric | budget | measured |
|---|---|---|
| `zoom.stepDuration` | ≤ 8.3 ms | **32.1 ms** (387%) |
| `zoom.boundsWrites` | == 0 | **1440** |
| `zoom.modelWrites` | == 0 | 0 |
| `zoom.proseMeasurements` | == 0 | **5474** |
| `zoom.frameWrites` | ≥ 1 (teeth) | 2880 |

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

The fix is architectural: the camera must stop resizing tile views at all, and
scale the canvas's own coordinate system instead, so tiles keep constant frames
and a zoom is one geometry change rather than 2 × *n*. That is a scoped project
(hit-testing, cursor rects, zone chrome and the chrome-scale floors all read
screen coordinates today), not a patch. It is listed in
[`.plans/21`](../../.plans/21-canvas-pan-zoom-performance.md) as candidate 6.

`--perf-budget-zoom-check` is in `MATRIX_KNOWN_RED` so the number is printed on
every run without masking a `canvas.pan` regression. Remove that entry when the
camera stops resizing tiles.

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

A gesture is bracketed by camera activity rather than by AppKit gesture phases —
every increment funnels through `setViewport`, and the gesture ends when that goes
quiet — so the trackpad, pinch and pointer-pan paths are all covered identically.

The budget is the display's **own** cadence (`maximumFramesPerSecond`), not an
assumed 60: asserting 60 would call a perfect 120 Hz gesture a failure, and would
call a 45 fps gesture on a 60 Hz external monitor a pass. "Late" counts frames
over 1.5× that cadence — a hitch, not a rounding artifact.

It is inert unless the variable is set, because anything that can log or present
at boot has to stay quiet in QA runs and in front of users.

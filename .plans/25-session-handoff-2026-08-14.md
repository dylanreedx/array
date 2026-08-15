# 25 — Session handoff: one camera, and the cascade that remains (2026-08-14)

Historical status at this handoff: **the unification was built, witnessed, and
Dylan-confirmed** ("they feel unified! nice!") on `array/zoom-unify` — then 8
commits on top of `array/zoom-feel`, pushed. The residual zoom choppiness was
**diagnosed with a stack trace** (AppKit's
per-frame backing-properties cascade), the two next moves are decided, and the
branch needs one clean matrix run and a tuning pass before it merges.

> **Superseded for continuation by [26](26-session-handoff-2026-08-15.md).**
> This file remains the detailed record of the unification/profile session.

> **Continuation update (2026-08-14):** step 1 landed as `574e7f7` (shared,
> template-preserving bitmap SF Symbols; UI probe + geometry probe green). The
> required geometry-hold A/B was then built before any mechanism: two 10-real-
> agent ABBA runs show stepped p50/p95 ~30–31/~37–39 ms and held p50/p95
> ~0.01/~0.01–0.02 ms; one ~28 ms bake included, **98.5% recoverable**. Counts:
> 120 bounds-size writes → 1,200 transcript layouts; held ticks 0 → 0. The
> missing backing-cascade witness is now `canvas.geometry-hold-probe`; next is
> the supported held-zoom presentation design, not another attribution pass.

Prerequisite reading, in order:
1. [24](24-canvas-camera-unification.md) — the program record: the five
   mechanisms, the driver architecture, the numbers, the real-pinch profile.
2. [23](23-canvas-zoom-handoff.md) — the previous handoff; its
   "two problems in one costume" reframe still governs.
3. `docs/internals/performance-budgets.md` — every measured number, including
   the four new scenario sections added this session.

Artifacts from this session (on disk, not in git):
`~/array-worktrees/zoom-unify/qa-runs/zoom-pinch-2026-08-14/` — the 12 s
`sample` of Dylan's real pinch on the driver build (`pinch-sample.txt`), his
frame-stats log (`frame-stats.log`), and the full matrix log (`matrix-run.log`).

---

## Where things stand, in one paragraph

Pan: perfect (unchanged all session, all-zero counters, 0.34 ms/step). The
zoom→pan transition: **fixed** — that was Dylan's reframing insight ("it lags
when zooming when you start panning … they should be unified"), and the
`CanvasCameraDriver` plus the settle-deferred housekeeping removed every seam
mechanism. Zoom mid-gesture: still stalls (33–47% of frames at 40–120 ms with a
perfect 8.33 ms median), and the tripwire profile names the cause precisely:
each per-frame `setBoundsSize` on the world plane fires
`_NSViewHierarchyDidChangeBackingProperties`, and AppKit re-tiles every
NSScrollView, re-solves Auto Layout, re-walks the window layout tree, and
re-rasterizes every SF Symbol vector glyph across all ~10 real agent subtrees —
**every frame**. Our own code is gone from the profile (chrome refresh: 8
samples of 8,963; background save queue: 6).

## The branch, commit by commit

| commit | what |
|---|---|
| `ba4dfba` | Chrome-pass repairs: conditional title-bar z-order (+ `qaChromeZOrderRepairCount`), bucketed close-button floors, shared glyph-image cache; `ARRAY_EXP_ZOOM_CACHE` (placebo + policy leak) and the Timer momentum prototype removed |
| `7e767e9` | **CanvasCameraDriver** — one owner for scroll pan, Cmd+scroll zoom, pinch, glide; ≤1 commit per display interval (leading-edge, so sparse input keeps today's latency); display-linked glide composing with pan around a live anchor; one curve; session stickiness for the pinch→pan handoff over tile content; `setViewport` stays synchronous truth |
| `17e6461` | The post-gesture cliff off the gesture path: settle-deferred cursor rects + delegate, debounced canvas save on a background serial queue (sync flush serializes behind it), marching-ants attach-if-missing |
| `96d07fc` | Matrix registration for `--canvas-camera-coalesce-check` and `--canvas-zoom-momentum-check` |
| `8951073` | `canvas.gesture-transition` — the seam witness (pan-after-zoom inherits 0 chrome / 0 layouts; interleave adds exactly 0 over its pure-zoom control) |
| `ce6db93` | `canvas.raster` (real display pump; pan = 0 draws, zoom = draws == invalidations), `--perf-budget-magnify-slope-check` KNOWN-RED leg, performance-budgets.md sections, .plans/24 |
| `53b872a` | Title-rect origin clamp — the one regression the full matrix caught (bucketed chrome legitimately overflows a 180-world tile at zoom 0.35; the empty title rect's origin sat past the dots) |
| `a7d18b7` | The real-pinch profile recorded in .plans/24 |

## How this session worked — keep doing these

1. **Feel reports are architecture clues.** Dylan's exact wording located the
   defect class both times: "when you start panning" = the transition seam;
   "still choppy but best it's felt" = our work done, platform cost remaining.
   Treat the wording as the clue, not just the sentiment.
2. **Fan out wide before proposing mechanisms.** Dylan explicitly asked for 8
   parallel exploration agents; the fan-out found five confirmed mechanisms,
   two prototype defects, and the written-but-unbuilt Slice 2 spec — none of
   which one-file reading would have surfaced. He wants this mode for feel
   problems.
3. **Build the counter for what nobody is counting, then eliminate
   conditions.** Unchanged from 23, and it paid again: the z-order reorder was
   invisible to every existing counter; the raster witness caught its own
   harness lying on its FIRST run (144 invalidations, 0 executed draws —
   layer-backed `draw(_:)` does not run until `CATransaction.flush()`).
4. **Tripwire profiling.** Dylan cannot pinch on cue across an async chat. A
   background loop that watches the app's CPU and fires `sample` the moment a
   gesture starts means his fingers and the profiler meet without
   coordination. Script shape is in this session's transcript; rebuild it in
   two minutes when needed.
5. **Frame stats give the SHAPE, the sample gives the NAME.**
   `CONTINUUM_FRAME_STATS=1` + `CONTINUUM_FRAME_STATS_FILE` showed
   median-perfect/tail-terrible before any sample ran — that shape (spikes,
   not uniform slowness) constrained the hypothesis space to bursty work.
6. **One leg per flag, KNOWN-RED publishes its number.** The new
   magnify-slope leg is KNOWN-RED on durationSlope alone and prints the AppKit
   traversal residual every run, so the gap cannot silently vanish or grow.

## Decisions Dylan has made (do not re-litigate)

- Chrome bucketing: **ship as default** (shipped; round-DOWN is load-bearing,
  `--tile-drag-grab-check` guards it).
- Momentum: **ship as default** (shipped; constants are provisional one-pass
  values pending his hand-tuning).
- `ARRAY_EXP_ZOOM_CACHE`: dead — it was placebo (suppressed only the tile's
  contentless backing layer) with a policy leak.
- Briefly-soft-content mid-pinch: **pre-approved contingent on profiling** —
  and the profile now justifies it (see next steps).
- Scope: iterate until the entire canvas interactivity feels O(1). Dylan is
  the oracle; witnesses exist to hold wins, not declare them.

## The witness inventory now, and each one's blind spot

- `canvas.pan` / `canvas.fractional-pan` — gating, green, trustworthy.
- `canvas.gesture-transition` — the seam; green. Blind to rasterization.
- `canvas.raster` — chrome rasterization with a REAL display pump; green.
  **Blind to content rasterization** (transcript text, terminal surfaces) and
  runs only when `CONTINUUM_SKIP_UI_BASELINES` is unset (display-dependent).
- `--canvas-camera-coalesce-check` — N-inputs-bounded-commits; green.
- `--canvas-zoom-momentum-check` — glide mechanics on deterministic time; green.
- `canvas.magnify-slope` — work slopes gate at 0; **KNOWN-RED on
  durationSlope** (AppKit traversal, ~2 ms per 112 extra installed tiles).
- `canvas.zoom` — KNOWN-RED at 144 layout passes vs product target 12 (one per
  tile per bucket crossing vs one per gesture).
- `--canvas-zoom-invalidation-probe-check` — KNOWN-RED, same target.
- `canvas.geometry-hold-probe` — 10 real agent tiles, real display/transaction
  pump, ABBA bounds-size stepping versus held ticks plus one bake; green and
  display-dependent. It closes the backing-cascade/real-content blindness with
  a 98.5% recoverable fraction and exact 120→1,200 versus 0→0 write/layout counts.

## Next steps, in order

1. **DONE — Symbol bitmap freeze.** The profile shows SF
   Symbol vector glyphs re-rasterizing per zoom frame
   (`CUINamedVectorGlyph rasterizeImageUsingScaleFactor:` under
   `_NSSimpleImageView updateLayer`). Render each chrome/status symbol once to
   a template-preserving bitmap `NSImage` (bitmaps scale in the compositor;
   templates keep tinting). Sweep the agent-tile chrome image views. The
   ui-probe census watches appearance behavior — run `--ui-probe-check` after.
   Expected: ~10–15% of the commit cost.
2. **The geometry-hold slice (the real fix).** Stop changing the plane's
   bounds-size on every gesture frame: hold real geometry during the pinch,
   present the zoom visually, bake true bounds once at the driver's settle
   (which exists as a single signal precisely for this). One backing cascade
   per gesture instead of ~120/s. Two hard sub-problems, in order:
   - **DONE — Measure the recoverable fraction first:** `canvas.geometry-hold-probe`
     measured 98.5% recoverable including one final bake, twice, on real agent
     tiles with a real display commit.
   - *The presentation mechanism is a design decision.* A raw transform on the
     view-backing layer is the explicitly rejected shortcut
     (infinite-canvas-rendering-research.md, "not adopted by default").
     The supported live-container and gesture-time snapshot candidates have now
     failed (numbers below). The surviving shape is a bounded, precomputed
     Array-owned bitmap/chunk presenter with explicit live-surface fallback.
     Mid-gesture hit-testing reads the HELD geometry while the user sees the
     PRESENTED zoom — reconcile or gate it; the camera-hit oracle defines rest
     correctness.
   Mid-pinch content is scaled-not-relaid (briefly soft) — pre-approved.
3. **Hand-tune the glide and curves with Dylan, then freeze.** Knobs (env,
   tuning-session-only): `ARRAY_ZOOM_GLIDE_HALFLIFE_MS` (55),
   `ARRAY_ZOOM_GLIDE_ENGAGE` (0.35), `ARRAY_ZOOM_GLIDE_FLOOR` (0.02),
   `ARRAY_PINCH_ZOOM_GAIN` (1.0), `ARRAY_SCROLL_ZOOM_GAIN` (0.02),
   `ARRAY_CAMERA_STICKINESS_MS` (300). After sign-off: constants into code,
   env keys deleted.
4. **One clean full matrix, then merge.** The last run (159 legs, 9 KNOWN-RED
   all expected) had exactly one regression — fixed in `53b872a` — so a clean
   run is expected but not yet witnessed. Then merge `array/zoom-unify` →
   `array/integration` under Dylan's identity, no AI trailers. No release.
5. Out of scope, unchanged: `transcript.delta` duration RED (separate
   program); deep-content raster witness.

## The preview app

`~/Desktop/Array Dev scalability.app` on `CONTINUUM_PROJECT_ROOT=
~/array-scratch-canvas-zoom` with `CONTINUUM_APP_SUPPORT=/tmp/zm-sup.lbZTuG`
(reuse it — a fresh support dir mints duplicate agent records for the canvas's
10 managed-agent tiles). Launch with `open --env …`, never the bare
executable; add `CONTINUUM_FRAME_STATS=1` + `CONTINUUM_FRAME_STATS_FILE=<path>`
to record gesture pacing, and `CONTINUUM_FRAME_HUD=1` to show rolling
time-weighted FPS / late share / p95 directly on the canvas. The HUD adds
no timer/display link; it shows a rolling 30-frame, time-weighted summary at
4 Hz so stalls lower the headline FPS instead of hiding behind p50. Kill old instances
**by pid** — every Desktop dev
bundle shares `dev.arrayapp.macos.dev`. Rebuild:
`DEV_APP_PATH="$HOME/Desktop/Array Dev scalability.app" scripts/dev-app.sh
--no-launch` from the worktree, then your own `open --env`.

## Traps this session added (all of 23's still stand)

- **Do not edit Sources while a matrix runs in the same worktree** — its
  `swift run` legs rebuild mid-run and compile your half-edited state. One
  matrix run died this way.
- **Layer-backed `draw(_:)` does not execute under `displayIfNeeded()`** — the
  backing store updates at the CATransaction commit. A harness that wants real
  draws must `CATransaction.flush()`.
- The matrix-inventory lists are ALPHABETICAL; a new leg goes in sorted
  position in BOTH the `check` and `leg` lists.
- `echo ===` breaks zsh (`== not found`). Quote it.
- Sample the POST-GESTURE PAUSE as well as the gesture — the save/reconcile
  cliff never appears in a mid-gesture sample. (Now settle-deferred, but the
  lesson generalizes.)
- The driver's env knobs are read once at canvas init — relaunch to apply.

## Continuation update: presentation candidates measured (2026-08-14)

- A layer-hosting container for native tiles is **not supported**: Apple says
  not to add subviews to a layer-hosting view. It is not an ownership loophole
  for transforming AppKit-created descendant layers.
- `NSScrollView` magnification is **rejected by measurement**. It preserves its
  anchor (0.000 px error) but runs at 32.62/43.25 ms p50/p95 on the 10-agent
  fixture and produces exactly 1,200 transcript layouts across 120 ticks — the
  same cascade through a sanctioned API.
- A fresh whole-viewport snapshot is also **rejected as the mechanism**. Its
  shallow proxy is excellent (0.04/0.07 ms p50/p95, zero native layouts), but
  capture costs 22.07 ms and 24.4 MiB at 1600x1000 Retina, cannot generically
  composite live terminal/browser pixels, and has no newly-exposed coverage on
  zoom-out.
- The next design is therefore narrower: a precomputed, bounded presentation
  cache for capturable tile/zone working sets, plus explicit live-surface
  fallback. Prove update cost, memory, zoom-out coverage, interaction gating,
  and atomic one-bake settle before wiring it into `CanvasNSView`.
- The opt-in `canvas.scroll-magnification-probe` preserves both rejected
  candidate measurements. It is intentionally not a matrix leg and is red on
  the failed live-presentation/capture-start budgets.

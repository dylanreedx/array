# 23 — Canvas zoom handoff (2026-08-14)

Status: **pan is done and confirmed by hand; zoom is not.** Zoom got roughly 5×
cheaper today and Dylan rates it "75% of what panning feels like." The remaining
gap has two causes that are now separately understood, and the last discovery of
the day reframed the whole problem — read "The reframe" before anything else.

Prerequisite reading: [21](21-canvas-pan-zoom-performance.md) (investigation),
[22](22-canvas-scalability-implementation.md) (the staged plan),
[performance-budgets.md](../docs/internals/performance-budgets.md) (every measured
number), [scalability-tdd.md](../docs/internals/scalability-tdd.md) (the contract).

---

## The reframe, and it is the most important thing here

Zoom's problem is **two problems wearing one costume**, and they were conflated
all day:

1. **Throughput.** A zoom step cost real per-tile work. Fixed substantially — see
   below.
2. **Interaction.** A pinch has **no inertia**. `scrollWheel` inherits AppKit's
   momentum phase for free, which is why panning feels "free" and always has.
   `NSEvent` magnification has a `phase` but **macOS never synthesises a momentum
   phase for it**, so a pinch stops dead the instant the fingers stop. Dylan's
   words were "strict", "hard", "muddy" — none of which are words about frame
   time.

A momentum prototype (`ARRAY_EXP_ZOOM_MOMENTUM`) made this concrete, and produced
the sharpest result of the session: **with the glide in place, Dylan could finally
see the lag directly** — "now i feel the lag for real". The interaction fix did
not create lag; it removed the mask. A gesture that ends the moment your fingers
stop hides a stutter that a gliding camera exposes.

**So the next agent needs to work both axes and not mistake one for the other.**

---

## What was measured, in order, and what each attempt cost

This program burned most of a day on three plausible fixes that were each aimed at
the wrong layer. The pattern is worth internalising, because it will repeat:

| # | hypothesis | verdict | how it was settled |
|---|---|---|---|
| 1 | zoom resizes every tile view | **right**, fixed by the retained world plane | `boundsWrites` 1,440 → 0 |
| 2 | remaining cost is the content inset reflowing bodies | **right**, fixed | 49.1 → 4.7 ms, prose measurements 14,490 → 0 |
| 3 | remaining cost is rasterization; cache it | **partly** — helped, not the biggest block | profile: layout pass 3,355 vs rasterization 2,064 |
| 4 | bounds-SIZE is a resize, so AppKit propagates layout | **wrong** | probe: bounds-size alone costs **0** layout passes |
| 5 | it is our own `refreshZoomDependentChrome` | **right** | probe: `C − E = 696`, entirely the chrome branch |
| 6 | it is O(visible) | **wrong, it was O(installed)** | `magnify-slope`: 4/9/19/38 per step at 16/32/64/128 installed, visible pinned at 12 |
| 7 | it is throughput at all | **only half** | momentum prototype exposed lag that was previously masked |

**Every wrong turn was corrected by building a counter for the thing nobody was
counting, then eliminating conditions.** Never by reasoning. Assume the same.

---

## Where the code is

| branch | contents | state |
|---|---|---|
| `array/integration` (`fec0c96`) | layout-pass witness, `--canvas-zoom-invalidation-probe-check`, published diagnosis | merged, matrix green (162 legs, 10 KNOWN-RED) |
| `array/zoom-feel` (`11a21de`) | chrome bucketing, `canvas.magnify-slope`, visible-only chrome refresh, `ARRAY_EXP_ZOOM_CACHE`, `ARRAY_EXP_ZOOM_MOMENTUM` | **pushed, NOT merged — needs review and a product decision** |
| `array/zoom-exp` (`64eb702`) | the original two env experiments | superseded by `zoom-feel`, kept for history |

**`array/zoom-feel` is where the value is.** It has not been through a full matrix
run. Its first commit's chrome bucketing and its second commit's visible-only
refresh are real fixes with all camera oracles green; the two `ARRAY_EXP_*` flags
are prototypes.

## What is measured on `array/zoom-feel`

```
magnify-slope.chromeRedrawSlope   33.6  -> 0        the O(n) is gone
magnify-slope.layoutPassSlope     33.6  -> 0
magnify-slope.durationSlope       23.08 -> 1.91 ms  residual: AppKit tree traversal
magnify-slope.worstStepDuration   26.75 -> 4.83 ms
canvas.zoom  tileLayoutPasses     1,380 -> 144      bucketing; 12 visible tiles
canvas.pan   everything            0, 0.325 ms/step unchanged throughout
```

## The witnesses that exist now, and what each is blind to

- `canvas.pan` / `canvas.fractional-pan` — gating, green. Trustworthy.
- `canvas.zoom` — KNOWN-RED. **Measures layout only. It never rasterizes and
  holds no live agent/terminal/browser tile.** It called zoom "green at 4.7 ms"
  while a real pinch was visibly bad. Do not trust it alone, ever.
- `canvas.magnify-slope` — the O(1)-in-tiles contract for zoom. New today.
- `--canvas-zoom-invalidation-probe-check` — KNOWN-RED, and the most useful leg
  here. Five conditions that isolate *which* part of a camera step costs a layout.
- `--camera-chrome-redraw-check`, `--tile-drag-grab-check`,
  `--tile-chrome-scale-check`, `--tile-world-bounds-check`,
  `--canvas-camera-hit-oracle-check` — correctness. **These earn their keep**: the
  drag-grab check caught a chrome-bucketing version that rounded scale UP and
  silently shrank the move-grab strip below its screen-px floor.

**Nothing witnesses rasterization or real-gesture feel.** That is the single
biggest gap, and it is why `ARRAY_EXP_ZOOM_CACHE` cannot be evaluated by the
matrix — it scores identically with the flag on and off.

---

## Recommended next steps

1. **Profile the `zoom-feel` build during a real pinch** before writing any code.
   `sample <pid> 30`. The dominant block has moved after every single fix.
2. **Decide the two product-visible questions** with Dylan, not for him:
   - chrome bucketing — the title bar steps in size while zooming;
   - `ZOOM_CACHE` — content is briefly soft while the fingers move, sharp at rest.
   He has felt both and called them improvements, but neither has been approved as
   a shipped behaviour.
3. **Build a rasterization witness.** Counting `TitleBarView.draw` invocations and
   layer display passes on a fixture that is actually in a window would close the
   blindness that made `canvas.zoom` lie this morning.
4. **Finish the momentum work as a real interaction**, not a prototype: it is
   `Timer`-driven and should be display-linked, and its decay rate, engage
   threshold and anchor behaviour are one-pass guesses that need tuning by hand.
5. **Reconcile the two zoom curves.** `handlePinch` uses `1 + magnification`;
   Cmd+scroll uses `exp(delta × 0.02)`. They do not agree, and "muddy" may partly
   be that.
6. **Unfinished elsewhere:** `transcript.delta` is green on counts and RED on
   duration; its remaining causes are `applyUnscrolled`'s presentation passes
   (~56%) and `prepareToolDetailLifecycle` (~35%). Untouched.

## Constraints Dylan has set

- **Tiles must always render live.** Semantic-zoom LOD — cheap previews below a
  scale threshold — is rejected. Measured consequence: with the chrome defect
  fixed the plane costs ~0.003 ms/tile/step, so the constraint looks affordable;
  revisit against numbers, never against the principle.
- **Zoom must be O(1) in tiles.** Now true for the work counts; the residual
  1.91 ms duration slope is view-tree traversal.
- No release. Work lands on `array/integration`.

## Traps specific to this area

- **The scenario filter is prefix-matched.** `canvas.zoom-slope` would be swept
  into `--perf-budget-zoom-check`. That is why it is named `canvas.magnify-slope`.
- **`grep -c` exits 1 on zero matches** and will abort a `&&` chain mid-script.
- **zsh does not word-split unquoted parameters**, so `env $FLAGS binary` silently
  passes one malformed argument. It cost a bogus measurement today.
- **Match `ps` patterns carefully**: `/[^ ]*` never matches an app path containing
  spaces, which produced a false "the app is not running" report.
- **All Desktop dev bundles share the bundle id `dev.arrayapp.macos.dev`**, so
  quitting by bundle id kills every running dev app, including Dylan's. Kill by
  pid.
- Two installs must never share one project root (AGENTS.md hazard 10).

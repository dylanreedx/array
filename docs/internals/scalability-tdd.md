# Scalability TDD

Array should not become slower as its canvas, transcripts, or restored workspace
grow. This document turns that requirement into deterministic tests and a staged
performance plan.

It complements [performance.md](./performance.md), which explains how to diagnose
slow surfaces, and [performance-budgets.md](./performance-budgets.md), which
documents the current budget runner. It does not treat a microbenchmark as an FPS
claim.

[infinite-canvas-rendering-research.md](./infinite-canvas-rendering-research.md)
maps primary-source Figma, tldraw, browser, map, game-engine, and Apple techniques
onto Array and defines when to escalate from AppKit to hybrid rendering.

## The contract

"Constant-time tiles" is three separate contracts:

1. **Camera:** pan and zoom geometry work is independent of the total number of
   installed tiles. One camera mutation may still cause compositor work
   proportional to visible pixels and layers.
2. **Streaming:** applying a delta is proportional to the delta and changed
   visible rows, not the complete transcript history.
3. **Lifecycle:** an offscreen tile keeps semantic state current while its
   presentation work approaches zero. Memory stays bounded by admitted live
   surfaces and explicit caches, not every saved tile being fully materialized.

The useful target is therefore `O(camera mutation)`, `O(delta + visible)`, and
`O(active surfaces)`. Claiming literal `O(1)` for rendering, WebKit processes, or
memory would hide costs rather than control them.

Do not collapse semantic activity, heavyweight resource residency, visual LOD,
and interaction pins into one `live/snapshot/cold` value. They are independent:
an offscreen agent can remain semantically live with dormant presentation, while
a focused tile remains editable detail regardless of viewport intersection.

## Two gates, not one

Every scalability scenario has two independent limits:

- **Regression ceiling:** the accepted baseline for the exact fixture. A change
  that does more deterministic work than the baseline is red even when the
  product is already inside its frame target. This is the "never worse than
  today" ratchet.
- **Product target:** the architecture Array needs. A scenario can remain
  known-red against this target while still being protected from regression.

This creates three honest states:

| regression ceiling | product target | meaning |
|---|---|---|
| pass | pass | at target and no regression |
| pass | fail | existing debt did not worsen |
| fail | either | regression; block the change |

Do not automatically rewrite regression ceilings from the latest run. Updating a
ceiling requires a reviewed fixture or intentional policy change, with the old
and new values recorded. Improvements ratchet downward after they are stable.

Wall time is too noisy to be the primary ratchet. Prefer counts of named work;
retain generous duration alarms and track distributions separately.

### Baseline records

The accepted baseline should be a reviewed, versioned manifest rather than a
number copied into an assertion. Each record identifies:

- scenario and fixture version;
- every scale dimension and workload state;
- metric, unit, comparison and accepted regression ceiling;
- independent product target and whether it is known-red;
- source SHA, build configuration, and provenance for measured timing/memory.

Changing or shrinking a fixture creates a new version; it does not silently make
the old gate green. Run old and new fixtures together until the replacement has
failed against the historical defect. When instrumentation changes, overlap the
old and new counters for the same reason.

Use exact or monotonic comparisons for deterministic work (`== 0`, `<= accepted`,
`== 1`) plus an at-least witness where zero could mean the scenario stopped doing
anything. Establish the timing-regression noise band from repeated, paired
Release trials on the same hardware before choosing a percentage; do not invent
a universal tolerance from the current single-pass data.

## Test the slope

A fast point is not evidence of scalability. Each test varies one independent
axis while holding the others fixed, then asserts both the endpoint and the
slope.

### Camera geometry

Hold the visible tile count constant while total installed tiles grow through
`16, 32, 64, 128`. Run both flat and zoned canvases at zoom `1.0` and a
non-integral zoom such as `0.35`.

Per camera step, assert:

- exactly one world-camera mutation after the retained world plane exists;
- zero per-tile frame, bounds, model, or prose-measurement writes;
- N input events inside one display interval cause at most one presentation
  commit while preserving the final desired viewport;
- fixed overlays remain in screen coordinates;
- a focused tile preserves first responder and hit testing;
- the work-count slope against total installed tiles is zero.

Separately vary the visible count. That leg measures unavoidable compositor and
visible-presentation scaling; do not combine it with the installed-count claim.

The current exact-floating-point regression needs a permanent non-1.0 zoom
witness. A zoom-1.0-only fixture cannot detect it. `canvas.fractional-pan` is
that witness; `canvas.camera-slope` adds the installed-count slope.

**A camera witness must compare presentation against the model, not the model
against itself.** Both `CanvasNSView.tileId(at:)` and
`CanvasEngine.hitTest(screenPoint:…)` derive from `canvasState`, so asserting
they agree proves nothing about what is on screen — it is the "re-derives what
production derives" trap. The independent answer comes from the INSTALLED view
geometry: front-to-back over the real tile views, converting the probe point with
`convert(_:from:)` so the whole ancestor chain participates. Two witnesses use
it — `camera-slope.screenFrameMismatches` and `--canvas-camera-hit-oracle-check`
— and both were teeth-verified by removing the camera's frame-origin write, which
takes the first from 0 to 480 mismatches and makes the second report a concrete
model-vs-view-tree disagreement. Note also that `canvas.hitTest(_:)` is the wrong
tool here: it takes a point in the canvas's SUPERVIEW space, and the canvas is
flipped while a window's frame view is not, so passing canvas coordinates probes a
vertically mirrored location and silently returns nil.

### Transcript streaming

Create otherwise identical documents with `10, 100, 1,000, 10,000` rows. Append
one prose delta, mutate one tool row, and settle one turn.

Assert per delta:

- visited entries/blocks/rows are bounded by changed plus visible rows;
- no full-document image scan for a prose-only delta;
- no full flatten or diffable-snapshot rebuild for a content-only edit;
- no tool-detail refresh for a non-tool edit;
- stable header, location, composer, and status views receive zero applies;
- elapsed timers are neither invalidated nor recreated;
- live Markdown parsing work scales with new bytes, not accumulated answer
  length.

The existing 10,000-row view-count check proves view virtualization only. It must
be paired with visit/work counters to prove incremental updates.

### Offscreen presentation

Stream a fixed event sequence into an agent tile outside the viewport.

Assert:

- its semantic document version and terminal state advance correctly;
- it performs zero AppKit presentation applies;
- it starts zero timers, animations, image hydration, and tool-detail tasks;
- moving it onscreen causes exactly one catch-up apply;
- mounted heavy views remain bounded by visible plus halo plus explicit pins;
- an agent can advance beyond the supervisor replay cap without relying on view
  detachment for semantic delivery;
- focus, selection, first responder, and accessibility state survive the
  transition.

`window != nil` is not a viewport-visibility witness. Presentation activity must
be an explicit lifecycle state and must not be implemented by hiding the entire
tile.

### Semantic zoom and presentation working set

Hold visible/pinned count constant while stored tile count grows through `100,
1,000, 10,000, 100,000`. Separately zoom the entire workspace into view, where
ordinary viewport culling has no leverage.

Assert:

- mounted full-detail views are bounded by the working set, not stored tiles;
- overview zoom installs zero heavy native subtrees except explicit interaction
  pins and draws work proportional to visible zones/chunks;
- crossing a readability threshold causes one presentation transition and camera
  jitter inside its hysteresis band causes zero flapping;
- effective LOD and preview scale bucket stay stable during pinch and refine once
  at settle;
- moving inside the activation window's safe region performs no spatial query or
  attachment churn;
- high-velocity motion preloads content before it becomes visible;
- focused, dragged, modal-owning, and AX-active tiles never demote;
- preview decoded bytes stay under budget and return after eviction;
- any spatial accelerator matches the brute-force geometry oracle under
  randomized moves, resizes, overlap, z-order changes, and deletion.

Hydration tier and visual fidelity are different dimensions. Merely making every
geometrically visible tile `.live` recreates the zoomed-out worst case.

### Restore and memory

Restore workspaces with `8, 32, 64` agents and representative terminals and
browsers. Hold transcript size fixed in one leg and vary it in another.

Deterministically assert:

- the first frame is allowed before offscreen heavy tiles are materialized;
- concurrent transcript hydration never exceeds the configured bound;
- visible/focused descriptors are admitted before background descriptors;
- a browser is admitted to the runtime budget before a `WKWebView` is created;
- an initially cold zone remains navigable and can become live after camera
  movement;
- browser and terminal runtime counts return to baseline after tile deletion,
  zone release, and window close;
- WebKit handlers, timers, Ghostty surfaces, and controller references have
  deallocation witnesses.

Measure both restore high-water and post-settle recovery. App RSS alone is not a
browser memory budget: record app `phys_footprint` and the WebKit process
coalition.

### Idle/background work

For a fixed canvas with no user or provider activity, assert counts over a fixed
logical interval:

- no transcript presentation or header/location timer reconstruction;
- no offscreen Core Animation loops;
- no subprocess polling whose source state has not changed;
- timer and task counts are proportional only to admitted active surfaces.

Wall-clock wakeups and energy still require Instruments on real hardware, but
deterministic ownership and scheduling counters catch most regressions earlier.
Drive timer and scheduler assertions with an injected clock/executor so the
normal matrix does not wait on real time.

## The witness vocabulary

Add counters at the point work is requested, not around an implementation detail
that an optimization can bypass accidentally. The initial vocabulary should
cover:

| area | counters |
|---|---|
| camera | camera mutations, tile frame/bounds/model writes, cursor rebuilds, tile subtree layouts |
| transcript | entries/blocks/rows visited, rows flattened, snapshots rebuilt, Markdown bytes reparsed |
| presentation | tile/header/status/location applies, image scans, tool-detail refreshes |
| lifecycle | active/offscreen tiles, timers created, animations started, catch-up applies |
| LOD | effective band, tier transitions, threshold flaps, preview refinements |
| restore | descriptors loaded, heavy tiles materialized, hydrations in flight, first-frame boundary |
| runtimes | live/admitted browser and terminal runtimes, handlers, surfaces, teardown completions |
| memory | app footprint, coalition footprint, restore high-water, settled and post-teardown footprint |

Counters reset at an explicit scenario boundary and are reported alongside the
fixture dimensions. A count without `total`, `visible`, `history`, `delta`,
`zoom`, and state dimensions is not a scalability result.

Every optimization needs a teeth test: temporarily restore the old behavior and
observe the intended witness fail. For the camera tolerance guard, replacing the
tolerant comparison with exact equality must fail the non-integral-zoom scenario.

## Test pyramid

### Per change: deterministic Debug gates

Keep these small enough for the normal matrix:

- camera invariants at zoom `1.0` and `0.35`;
- one-row updates at short and 10,000-row histories;
- offscreen semantic/presentation separation;
- LOD hysteresis and one settle refinement;
- bounded restore concurrency;
- runtime teardown/deallocation.

Counts are authoritative here. A coarse duration ceiling detects catastrophic
mistakes but should have enough margin not to flake on a shared laptop.

### Deliberate or scheduled: scaling sweeps

Run the full installed/visible/history/restore matrices in a production-equivalent
Release build. Repeat trials, randomize their order, record host/build/OS/power
state, and publish raw per-trial results rather than only a mean.

Use these sweeps to detect a changed slope and to propose a lower regression
ceiling. Do not infer a hardware capacity limit by multiplying another Mac's
result.

### Shipping evidence: real hardware and real presentation

At minimum:

- M2 MacBook Air, 8 GB, built-in 60 Hz display;
- M2 MacBook Air, 16 GB, for the memory tier;
- a reference ProMotion Mac, plus an M2 Air on a 120 Hz external display if
  literal 120 Hz support is a requirement.

Use real trackpad pan and pinch gestures with a mixed canvas: streaming agents,
terminals producing output, one or two admitted browsers, multiple zones, and
ordinary colleague background load as a separate contention leg.

Report frame intervals and presentation rate (`p50`, `p95`, `p99`, worst and
missed-vsync count), signposted main-thread camera time, CPU, energy/wakeups,
time-to-first-interactive-frame, restore high-water, settled memory, and teardown
recovery. Reciprocal median frame interval alone is not achieved FPS.

The built-in M2 Air panel can validate locked 60 fps, not visible 120 fps. Keep
the 60 Hz and 120 Hz acceptance contracts separate and reserve headroom for
input, drawing, AppKit commit, and compositing rather than allowing the camera
microstep to consume the whole frame.

## Rough implementation sequence

No phase begins by deleting an existing gate. New witnesses land red against the
product target and green against the accepted regression ceiling before the
corresponding architecture changes.

1. **Make the harness trustworthy.** Add production-equivalent delegate effects,
   semantic fixture-settle barriers, repeated samples, gesture labels, and
   separate active-gesture versus settle-tail frame statistics.
2. **Freeze today's work.** Add the non-integral camera, transcript-history,
   offscreen, restore-concurrency, and teardown counters and publish their
   accepted baselines.
3. **Try bounded native experiments.** Add explicit viewport clipping, submit the
   newest camera state once per real display interval, and measure a
   gesture-cached redraw policy with one crisp settle repaint. Keep only wins on
   the weakest hardware and do not apply layer policies recursively by default.
   > **Realized 2026-08-14** (`array/zoom-unify`, .plans/24/25): display-paced
   > submission is `CanvasCameraDriver` — input accumulates, at most one
   > `setViewport` per display interval (leading-edge, so sparse input keeps
   > per-event latency), witnessed by `--canvas-camera-coalesce-check` (6
   > events in one interval: 6 applies before, 2 after). The pinch glide,
   > gesture-settle signal, and one shared zoom curve live in the same driver.
   > The gesture-cached redraw half is NOT done: the real-pinch profile shows
   > the remaining cost is AppKit's per-frame backing-properties cascade under
   > the plane's bounds-size change — the geometry-hold slice in .plans/25/26.
   > A real 10-agent A/B measured 98.5% recoverable with held geometry. The
   > strongest supported live alternative, NSScrollView magnification, still
   > produced 1,200 transcript layouts and 32–44 ms frames; gesture-time bitmap
   > capture also failed its start-latency/coverage/live-surface contract. The
   > remaining implementation is a precomputed, byte-bounded tile/zone proxy
   > cache with one native bake at settle.
4. **Retain the world once.** Split screen overlays from a nested world-content
   or clip view; make camera movement one ancestor mutation. Keep logical tile
   frames stable and prove hit testing, focus, cursor rects, overlays, spawning,
   and framing. Do not transform an AppKit-owned backing layer directly.
5. **Make streaming incremental.** Preserve real reducer patches, maintain row
   indexes incrementally, avoid full snapshots for content edits, and make live
   Markdown append-oriented.
6. **Add semantic zoom and presentation lifecycle.** Wire readability bands to
   lightweight summary/detail implementations with hysteresis. Use a screen-space,
   velocity-aware halo; coalesce offscreen semantic state and suspend
   presentation-only timers, animations, parsing, image work, and tool refreshes
   until one catch-up apply. Preserve focus and AX pins.
7. **Bound ownership and restore.** Fix browser/terminal teardown, admit before
   creation, show the first frame from descriptors, and hydrate with bounded,
   visibility-prioritized concurrency.
8. **Add overview aggregation only if needed.** Replace many detail trees with
   zone/coarse-chunk HLOD using custom AppKit drawing, bounded preview caches, or
   `CATiledLayer`. Keep native interactive islands above it.
9. **Use a hybrid GPU overview only if evidence requires it.** Enter this phase
   only when the bounded AppKit/HLOD system still misses the M2 Air target and
   profiles identify overview drawing or GPU submission as the remaining cost.
10. **Lower the coefficient.** Lazy-build common-hidden attachment/status
   subtrees, consolidate duplicate chrome/timers, and bound measurement caches.
11. **Ratchet and validate.** Lower accepted ceilings after each stable win, run
   the hardware matrix, and record what remains known-red against the product
   target.

This ordering prevents a locally faster implementation from hiding a worse
scaling slope, and prevents today's known debt from silently becoming the
definition of success.

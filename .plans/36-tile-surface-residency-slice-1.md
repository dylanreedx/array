# 36 — Slice 1: tile surface residency, and why "in motion only" is refuted

Date: 2026-08-18

The first production slice of the unbounded-canvas program. **Read
`.plans/37-next-always-surfaced-residency.md` first** — it carries the current
state and what is next. Then this file, then `.plans/34` for the design and its
ledger.

**Status: built, flag OFF by default, leg GREEN and wired into the matrix — and
its own witness REFUTED the residency policy it was built around.** The
mechanism is proven fast and pixel-exact and is kept; "surfaced in motion only"
is abandoned on measurement. Both halves are below.

## What was built

| file | role |
|---|---|
| `Sources/ContinuumRevivedCore/TileSurfaceResidencyConfig.swift` | the flag, `defaultEnabled = false`, `ARRAY_TILE_SURFACE_RESIDENCY` env override |
| `Sources/ContinuumRevived/Canvas/TileSurfaceHostView.swift` | layer-hosting surface body; owns `viewDidChangeBackingProperties` with a bucketed `contentsScale` |
| `Sources/ContinuumRevived/Canvas/TileSurfaceStore.swift` | one surface per tile + revision; the `cacheDisplay` producer; `TILE_SURFACE_HALF_SCALE` degradation |
| `TileNSView` (+) | `demoteBodyToSurface` / `promoteBodyToNative`, `surfaceableBody`/`surfaceContentRevision` hooks (nil by default), `hitTest` promotion |
| `ManagedAgentTileNSView` (+) | the only family that opts in |
| `CanvasCameraDriver` (+) | `onActivityBegin`, symmetric with `onSettle` |
| `CanvasNSView` (+) | the park, the two transitions, per-step sharpness enforcement, cleanup, counters |
| `TileSurfaceResidencyChecks.swift` | the witness, `--tile-surface-residency-check` |

The policy implemented: **native at rest, surfaced in motion.** Settled means
every tile mounts its real body, so the app at rest is what it is today; moving
means each tile with a fresh, sharp-enough surface swaps its body for it while
the real body is parked outside the world plane.

## What is proven

- **Steady-state camera cost, in production code.** 12 real agent tiles, Array
  CPU per step p50: **26.82 ms native → 0.17 ms surfaced** (0.006x). The probe's
  result reproduces through the real `CanvasNSView`, the real
  `CanvasCameraDriver`, and real `ManagedAgentTileNSView`s.
- **The producer is pixel-exact.** Surface vs a native bake of the same body at
  the same instant and the same resolution: mean channel difference **0.000**.
  Under `TILE_SURFACE_HALF_SCALE=1` it is **1.156** against a 0.25 threshold, so
  the gate has teeth in both directions.
- **Streaming survives parking**, and content ingested mid-gesture is in the
  restored transcript.
- **A click during the settle window is not swallowed** — `hitTest` promotes
  before AppKit delivers.
- **Nothing is stranded**: removing a tile mid-gesture and switching zones both
  leave the park empty and the store pruned.
- **Sharpness cannot regress.** Enforced per step, not at gesture start — see
  the bug below.

## Why "in motion only" is refuted

`checkCost` fired the kill condition the plan named in advance, and the cost is
now fully attributed rather than guessed. 12 tiles:

| stage | native | surfaced |
|---|---|---|
| commit (contains the demote loop) | 3.00 ms | **61.78 ms** |
| layout | 24.75 ms | **55.36 ms** |
| display | 0.12 ms | 2.35 ms |
| **transition total** | **27.86 ms** | **119.49 ms** |

Entering motion costs **~4.3x one native camera step**, i.e. a visible hitch at
the exact moment the user starts to zoom — and it is paid on **every gesture**,
twice (in and out of the park). At 50 tiles it extrapolates to roughly half a
second. That is precisely the "when I start X" seam that `feel-symptoms-are-
architecture-clues` says to treat as the architecture talking.

**The cause, measured per call.** The demote path is now timed at each of its
three steps, accumulated across the transition:

| demote step | cost over 12 tiles | per tile |
|---|---:|---:|
| host construction / reuse | **0.00 ms** | 0.00 ms |
| `setContentView(host)` (removes the deep body) | **24.40 ms** | 2.03 ms |
| `park.addSubview(body)` (re-adds it) | **33.59 ms** | 2.80 ms |

That sums to the 58.22 ms commit stage, so the transition is explained, not
inferred. It is **plain AppKit subtree surgery**: removing a deep tile body from
one parent and adding it to another costs ~2.0 ms and ~2.8 ms respectively, per
tile, per direction. Host retention works perfectly (0.00 ms) and is kept.

**Any policy that reparents per gesture therefore pays ~4.8 ms per tile per
gesture, twice.** That is structural, and it is what kills the policy — not a
mechanism that could be tuned.

**Three hypotheses of mine were measured and refuted on the way**, which is
worth recording because each sounded right:

- *Refuted:* a fresh `CALayer` texture upload per gesture. Retaining the host
  across gestures moved the transition 0.1 ms (115.57 → 115.49).
- *Refuted:* an empty `visibleRect` in the park making collection-view layout
  pathological. Giving the park a real size changed nothing (113.82).
- *Refuted:* the unconditional forced offscreen pass in
  `AgentTranscriptListView.layout()` — two
  `collectionView.layoutSubtreeIfNeeded()` calls, `transcriptLayout.prepare()`,
  and a reposition loop over every visible item, running on every pass. Gating
  all of it on its inputs having changed moved the native camera step by 0.2 ms
  (24.72 → 24.91) and the layout stage by 0.4 ms. Those calls really were nearly
  free, exactly as their own comments claimed, and the ~960 profile samples in
  "the forced subtree layout" belong to **AppKit's own** `NSWindow
  _layoutViewTree`, not to that block. **The change was reverted** — a streaming
  hot path does not get touched for no measured benefit.
- *Also learned while trying:* gating that pass is not even safe naively.
  `ComponentLab` hosts a transcript in a windowless view and calls `layout()`
  several times in a row, depending on later passes to finish what the first
  could not. Any memoisation there has to be "retry until it sticks", or the
  P5.5 failure (rows and attributes present, live hosts zero) returns.

So the remaining native cost is `super.layout()` — the constraint solve AppKit
runs because the backing-property cascade marked the view dirty. The only way
out of it is not being in the cascade, which is what surfacing does. The
architecture was right; the layout cost is not separately fixable at this level.

**Why the probe missed it.** `canvas.surface-host-slope`'s parked arm installs
its arrangement *before* the clock starts, so it measured the steady state and
never the transition. The transition is what this check added, and it is the
whole finding.

## A production bug this found

`cameraGestureWillMove` fires from `onActivityBegin`, which runs **before** the
first commit — so the zoom it sees is the one the gesture is leaving, not the
one it is heading for. A tile admitted as sharp-enough at zoom 1.0 was still
surfaced two steps into a zoom to 2.0, showing exactly the soft text this design
promises never to show. Fixed by enforcing sharpness **per step** in
`setViewport`, over a maintained `surfacedTiles` set (O(surfaced), never a view-
tree walk — the lesson `visibleTileViews` already records). The guarantee is now
"sharp in every frame" rather than "sharp when the gesture started", which is
strictly better.

## Two witness bugs worth remembering

Both are the same mistake, and both would have produced a confident wrong
answer: **a counter keyed on where a view LIVES, measuring a mechanism whose
whole job is to move views between trees.**

- `canvas.qaTotalTranscriptLayoutPassCount` walks the world plane, so it drops
  to 0 when tiles are surfaced. That reads like proof and is blindness. The park
  walk is the honest gate.
- Rooting a layout-pass count at the tile view under-counts after demotion (the
  body has left), giving a **negative** delta of -72 for 12 tiles; rooting it at
  the park over-counts, reporting each parked body's whole history as if it had
  just happened (**84** for 12 tiles). The truth is **12**, one per tile, and it
  needs a root that does not move: `surfaceableBody`.

## The leg is green, and wired

The transition cost is **published, not gated**. It was a gate, it fired, and it
did its job. Keeping it would assert a decision rather than protect a behaviour:
the policy is abandoned, so there is no regression left in that number to catch.

What the leg still gates is the **mechanism**, which the next policy reuses
unchanged — producer fidelity, the sharpness refusal, exactly-once input through
`hitTest`, streaming through a park, flag-off inertness, no stranded bodies, and
the per-step cost. Plus one guard on the instrument itself: the demote breakdown
must still account for ≥60% of the commit stage it claims to explain, so a
published number cannot quietly become fiction.

`run-matrix.sh` gained one leg beside `--perf-budget-surface-host-slope-check`,
behind the same `CONTINUUM_SKIP_UI_BASELINES` guard (additive only — two program
checks pin that script's text verbatim). Inventory regenerated: 354 records.

## A stale belief this program was carrying

`.plans/35` recorded that the full matrix could not be run while Dylan uses
Array, because CoreChecks drives real tmux on the default socket. **That is true
of bare `swift run ContinuumRevivedCoreChecks` and false of the matrix.**
`scripts/run-matrix.sh:9-22` creates a disposable `TMUX_TMPDIR`, exports it
before any leg runs, unsets `TMUX`/`TMUX_PANE`, and traps cleanup — added
precisely because of the 2026-08-12 incidents. The belief cost this program
several sessions of deferred verification.

## Where this leaves the architecture

The measurement inverts the plan's premise. "Native at rest, surfaced in motion"
was chosen because it has almost no UX discrepancy surface — and it is the
variant whose reparenting cost is paid per gesture. **Always-surfaced (I5,
already approved) pays that cost once per tile per interaction instead**, and
interactions are rare next to camera gestures. So the cheap shape is the one
with the bigger discrepancy list, and the discrepancies have to be earned
individually rather than avoided wholesale.

The one way forward that the evidence leaves open:

**Always-surfaced (I5), with promotion on interaction.** It reparents a tile at
most twice per *interaction* instead of twice per *gesture*, and interactions
are rare next to camera gestures — which is exactly the cost structure the
demote breakdown demands. Everything built here is reused unchanged: the host,
the store, the producer, the park, `hitTest` promotion, the sharpness rule, and
the whole witness.

What it costs is that the discrepancy table in `.plans/36`'s plan has to be
**earned item by item** rather than avoided wholesale, each with its own
witness: cursor rects over a surfaced transcript, drag-select, IME in the
composer, tooltips and context menus, the accessibility tree (Q8, still open),
and anything that walks the view hierarchy. `TileNSView.updateTrackingAreas` and
`mouseEntered` already exist and are the natural promotion trigger for "the tile
under the pointer is always real".

Two dead ends, recorded so nobody spends the session again: attacking the
transcript's forced offscreen pass (refuted above), and looking for a cheaper
reparent (the cost is AppKit's, split evenly between remove and add, with
nothing of ours in between — host construction measures 0.00 ms).

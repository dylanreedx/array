# 35 — Unbounded canvas: Shape A confirmed, session handoff

Date: 2026-08-18

**SUPERSEDED as the entry point by `.plans/37-next-always-surfaced-residency.md`**,
which carries the state after slice 1 shipped. Kept for the measurement record
below.

This is the orientation/handoff for the unbounded-canvas rendering program after
the first implementation step. Read it before `.plans/34`, then read `.plans/34`
in full — it is the live design document and its decision ledger is the source
of truth for what is settled.

## Repository state at handoff

- branch: `array/integration`; HEAD: **`10c49c2`** ("Add tile surface
  residency behind a default-off flag") — 13 files, 2,664 insertions, 0
  deletions, committed 2026-08-18 after a full green matrix. The tracked tree is
  CLEAN; everything this program wrote to source, scripts and `docs/internals`
  is in that commit.

- untracked and user-owned, preserve all of them: `.plans/17`–`.plans/21`,
  `.plans/29`–`.plans/36`,
  `docs/38-tickets/96-agent-sidebar-product-redesign/_DESIGN.md`,
  `docs/internals/iteration-time.md`.

**Dylan has not been asked whether to commit.** The work is additive and green;
offer the commit, do not make it unprompted.

## Document map

| doc | role |
|---|---|
| `.plans/31` | evidence record — the released 0.5.0 failure, frozen |
| `.plans/32` | target architecture — six ownership layers, D1–D16 |
| `.plans/33` | testing architecture — three gates, five tiers, T1–T23 |
| `.plans/34` | **implementation design, LIVE** — ownership maps, boundary contracts, decision ledger I1–I16 |
| `.plans/35` | this file — state, results, what is next |
| `docs/internals/performance-budgets.md` | the published `canvas.surface-host-slope` numbers |

## Decisions Dylan approved this session

Recorded in `.plans/34` Part XI. All four came from explicit answers, not
inference.

- **I5 — retained scene authoritative at rest AND in motion** for Array-owned
  families. Removes the global settle bake; the only shape with no tile ceiling.
  Its bill: accessibility, IME, selection and drag must be *earned*, because
  today they come free from the very view tree a retained scene stops mounting.
- **I4 — native residual plane.** Browser and terminal stay in today's
  scale-changing `CanvasWorldPlaneView` until their pixel producers exist. In
  the real workspace that is 2 tiles of 20, so the first credible result needs
  neither a WebKit snapshot fidelity study nor a Ghostty frame API.
- **I11 — streaming is streaming.** Animating content never freezes during a
  gesture; the strict reading, **no size exemption**. This makes fragment-level,
  off-main production a *correctness* requirement, which promotes I2 (per-block
  display lists) to load-bearing and adds I16.
- **I15 — Shape A first (scene-in-plane).** Surface hosts are `TileNSView`
  subclasses at world frames whose *content view* changed; Shape B
  (scene-beside-plane, one root transform, world plane retired) is the
  destination, reached when the flat-tree traversal becomes the binding cost.

Still open, with defaults recorded in `.plans/34` Part XII so they do not block:
**Q3** where Array-owned rendering stops (discovered, not chosen — start at
promote-on-everything and measure), **Q4** cold-region appearance (hold the
previous complete scene; already strictly better than today's
`switchWorkspace`), **Q8** accessibility during the transition (hinges on
whether anyone uses Array with VoiceOver today; prove `AXScene` on the simplest
family first).

## What was built

One new opt-in perf scenario and matrix leg. **No production behaviour
changed.**

```sh
.build/debug/Array --perf-budget-surface-host-slope-check       # ~150s, 31 budgets
```

`PerfScenarios.canvasSurfaceHostSlope()` plus a nested
`PerfScenarios.TileSurfaceProbeView: TileNSView` — chrome, close button, grab
strip, resize edges, cursor rects, focus adapter and z-order all inherited
untouched; only the body is a layer-hosting view carrying an Array-owned layer.
Four arms over ONE real managed-agent fixture at 5/15/25/50 tiles, ABBA with
**both observations pooled**:

- **native** — real `ManagedAgentTileNSView`, all installed;
- **unculled** — surface hosts, all installed;
- **culled** — surface hosts, viewport presentation set only;
- **parked** — surface hosts for every tile AND every real agent body still
  alive, in the window but outside `CanvasWorldPlaneView`. **This is the
  shippable configuration**: an interim `cacheDisplay` producer needs the real
  body to keep laying out and streaming (I11), and that is only affordable if a
  camera step cannot reach it.

Four properties that make it a witness rather than a benchmark:

1. **Every step is a real production `CanvasCameraDriver` commit**, reached by
   inverting the driver's own log-zoom gain against an injected clock
   (`nowProvider`). So `isApplying` is true, cursor-rect housekeeping defers as
   it does in a gesture, the visible-tile chrome refresh is inside the
   measurement, and the harness computes no geometry of its own.
2. **Surfaces are the real tiles' pixels**, baked once per host through
   `cacheDisplay` before any clock starts — one DISTINCT bake per host so Core
   Animation cannot collapse the scene onto a shared texture. A blank bake
   throws (`VisualSnapshot.metrics(of:).isBlank` as a smoke floor).
3. **Zone chrome on, gesture to zoom 0.2** — the real overview, with
   translucency and rounded masks in the composite. Every earlier probe omitted
   both and stopped at 0.45.
4. **Array CPU and the CA flush are separate stages.** See the correction below;
   this is the single most important methodological property of the leg.

## The result: Shape A is confirmed

**Array-owned CPU per camera step (p50), 2026-08-18, Debug:**

| installed | native | unculled | culled | parked |
|---:|---:|---:|---:|---:|
| 5 | 9.39 ms | 0.08 ms | 0.07 ms | 0.07 ms |
| 15 | 30.31 ms | 0.11 ms | 0.07 ms | 0.11 ms |
| 25 | 57.01 ms | 0.14 ms | 0.07 ms | 0.17 ms |
| 50 | **140.57 ms** | 0.23 ms | 0.06 ms | **0.19 ms** |

- `parkedVsNativeRatio` **0.001**, `parkedDurationSlope` 0.122 ms over 5 → 50,
  `parkedArrayCpuP95` 1.329 ms against an 8.3 ms budget, 0% late;
- `parkedVsUnculledRatio` **0.824** — keeping fifty real agents alive beside the
  surfaces is inside the noise of the surfaces alone;
- `culledVsNativeRatio` 0.000, `culledDurationSlope` -0.014 ms,
  `unculledDurationSlope` 0.155 ms;
- the native arm reproduces `.plans/31`'s published ladder
  (15.29/30.50/72.46/132.72 ms for the whole pump at 5/10/25/50), which is the
  precondition for reading any other number in the run.

**Do not treat a single native median as a machine constant.** An earlier run of
the same three arms on the same machine read 9.64/29.00/50.45/111.78 ms — ~25%
under the table above at the top of the sweep. The ratios and slopes held across
both runs; the native arm is the noisiest thing in the leg.

## Five things the run changed in the design

**1. Culling is NOT what buys it — replacing the BODY is.** The unculled arm
keeps every host installed and still slopes only 0.190 ms over 5 → 50. The
flat-tree traversal is nearly free at these counts, so I9's presentation-set
machinery is a lever for far larger installed counts (where `magnify-slope`'s ~2
ms per 112 shallow tiles lives), **not a prerequisite**. The first production
slice is therefore smaller than `.plans/34` Part VIII assumed.

**2. Array CPU vs `CATransaction.flush()` inverts the conclusion.** An earlier
version of this leg reported one number per step and read **119% over budget
with a 13% late share** — while Array's own camera work was 0.07 ms. The whole
signal was the flush blocking on the render server: flat at ~2 ms p50 / ~9–10 ms
p95 across every count in the surface arms, but scaling 6.60 → 11.23 → 16.85 ms
in the native arm where there is genuinely more to commit. `culledFlushP95` and
`culledStepP95` are published, never gated as Array cost, and a returning flush
is never called "presented".

**3. The `contentsScale` trap is real and the mitigation works.** AppKit sends
`viewDidChangeBackingProperties` to every installed surface host on **every**
camera step — exactly `hosts x steps` (300 = 5x60, 1500 = 25x60). The host owns
its layer and applies a bucketed policy, so `cameraCausedRasterRequests` is 0.
`PERF_SURFACE_HOST_NAIVE_SCALE=1` swaps in the naive policy that follows the
live effective scale and drives it to 1,200 — a permanent, re-runnable negative
witness. Recorded in the code: that arm witnesses the **decision**, not the cost
(re-publishing the same `CGImage` barely moves the clock; a real producer would
re-render).

**4. With the body gone, chrome is essentially ALL of Array's camera cost.**
Sweeping `ARRAY_CHROME_BUCKETS` at 25 tiles: 1 → 15 redraws / 0.08 ms p50; 4
(shipped) → 50 / 0.07 ms; 16 → 180 / **0.87 ms**. This is the evidence for
moving chrome to a screen-space compositor overlay under Shape B, and it also
refuted the first hypothesis for the step-time tail — more chrome crossings
produced FEWER late steps, because the tail was the flush.

**5. A parked live body costs nothing, so the interim producer exists and the
production slice no longer waits on I2.** `parkedTranscriptLayouts` is exactly 0
at every count and in both ABBA observations — a camera step cannot reach a body
that is not under the world plane, which is the whole mechanism. Three teeth
stop that zero from meaning "the body died": `parkedStreamingCards` (an ingested
event became transcript content), `parkedBakeColors` (`cacheDisplay` of a body
clipped out of every draw still yields 41 distinct colours), and
`parkedStreamingPixelDelta` (a bake after the event differs from one before by
6,867 bytes). I6 (parking, never demounting) moves from provisional to
**approved + measured**.

Two lessons from getting that witness wrong first:

- **`AgentTranscriptListView.qaLayoutPassCount` is the right signal for a CAMERA
  change and the wrong one for a CONTENT change.** New content does not move
  that view's own frame, so `layout()` legitimately never runs; the counter read
  0 for a body that was working perfectly, and "parking kills streaming" was
  about to get written down. `enqueue` also gates presentation at 30 Hz, so the
  model gains a card a frame before the view is asked to show it — the witness
  calls `flushPendingVisualUpdate()` (the gate's own call) rather than racing a
  timer.
- **A published slope needs a sign-safe floor.** `unculledDurationSlope` was
  `.atLeast(0)`, and a 5,15 run reported -0.056 ms — two sub-millisecond medians
  ordered the other way by noise — failing a metric never meant to gate at all.
  Its floor is now `-8.3 ms`.

## A production question this surfaced — NOT fixed, NOT established

`_installLayer` (the `setZones` path, `CanvasNSView.swift:2758`) never sets
`tileView.canvas`. Only `install(tileView:for:)` (`:710`) and
`installProjectTile` (`:2736`) do. With `canvas` nil:

- every chrome floor collapses to its unfloored constant
  (`grabHeightInLocalCoordinates` → 24 instead of `max(24, 28/bucket)`,
  `closeButtonWorldSize` → 14, `closeGlyphWorldPointSize` → 9);
- the zoom-dependent chrome refresh is a no-op;
- `TileNSView`'s `guard let canvas` paths in `mouseDown`/`mouseDragged` — tile
  drag and resize — cannot run.

The probe found it by measuring **0 chrome redraws** across a gesture that
should cross ~9 buckets, and now sets `view.canvas` itself. Whether production
tiles restored through `setZones` are actually affected is **unestablished** —
tile dragging visibly works in Array, so something else may set it, or the flat
path may own the tiles that matter. This needs its own red-then-green witness
before anyone concludes anything. Do not "fix" it from this note alone.

## Reproducing everything

```sh
swift build --product Array

# the green run (default 5/15/25/50, ~90s)
.build/debug/Array --perf-budget-surface-host-slope-check

# the negative witness — MUST fail on cameraCausedRasterRequests (1200 vs 0)
PERF_SURFACE_HOST_NAIVE_SCALE=1 .build/debug/Array \
  --perf-budget-surface-host-slope-check

# chrome is now the whole Array-side cost
for b in 1 4 16; do ARRAY_CHROME_BUCKETS=$b PERF_SURFACE_HOST_TILE_COUNTS=25 \
  .build/debug/Array --perf-budget-surface-host-slope-check; done

# faster iteration
PERF_SURFACE_HOST_TILE_COUNTS=5,15 PERF_SURFACE_HOST_STEPS=20 \
  .build/debug/Array --perf-budget-surface-host-slope-check
```

Overrides: `PERF_SURFACE_HOST_TILE_COUNTS` (ascending, each >= the visible
cluster), `PERF_SURFACE_HOST_VISIBLE` (default 5), `PERF_SURFACE_HOST_TURNS`
(6), `PERF_SURFACE_HOST_STEPS` (60), `PERF_SURFACE_HOST_NAIVE_SCALE`.

The default stops at 50 because every host needs its own baked surface and a
bake needs a real agent tile — 100/200 are reachable but are a deliberate memory
event (`docs/internals/performance.md`).

## Verification status — read this before claiming the leg is covered

Done and green, and the gate now prints it:

- **`scripts/run-matrix.sh` — RUN and PASSED**, 2026-08-18: **172 legs**, 11
  KNOWN-RED all documented and expected, **zero unexpected failures**, zero
  stale allowlist passes, no build errors. Both new legs printed IN the summary
  and passed: `--perf-budget-surface-host-slope-check` (31 budgets, 0 over) and
  `--tile-surface-residency-check`. This closes the program's oldest open item —
  the surface-host leg's matrix reporting had been unverified since it was
  written.
- the two legs individually, plus the fidelity negative witness
  (`TILE_SURFACE_HALF_SCALE=1` fails on exactly the intended budget) and the
  raster negative witness (`PERF_SURFACE_HOST_NAIVE_SCALE=1` drives
  `cameraCausedRasterRequests` to 1,200);
- `./scripts/check-matrix-inventory.sh` — 354 records, nothing removed;
- `./scripts/check-agent-tile-ux-program.sh` and
  `./scripts/check-sidebar-native-ux-program.sh` — both pass, and they pin
  `run-matrix.sh` lines verbatim, so the new leg is additive-only.

Dylan's `/Applications/Array.app` stayed up throughout (17h51m uptime at the
end). The matrix is safe to run alongside it — see the correction below.

## Hazards specific to this work

1. **Never run the matrix or CoreChecks while Array is open** (CLAUDE.md; memory
   `tmux-checks-kill-live-app`).
2. **The `contentsScale` trap.** Any real surface host MUST own
   `viewDidChangeBackingProperties` and apply a bucketed policy. AppKit fires
   that callback once per host per camera step; a naive implementation that
   follows the effective scale re-derives every surface every step and would
   show a *green* geometry counter over a *red* gesture.
3. **The `layer.tileViews` aliasing trap.** `setZones` removes the views it
   finds in `layer.tileViews`, so mutating that dictionary *before* calling it
   removes the incoming set and orphans the outgoing one — leaving the previous
   set installed and being laid out. This made the probe's first run report all
   three arms as identical; `surfaceArmTranscriptLayouts == 0` is the tooth that
   caught it. Remove explicitly, then swap.
4. **Never fold Array CPU and the CA flush into one number**, and never call a
   returning flush "presented".
5. Debug, never `--configuration release`, for iteration (`scripts/dev-app.sh`).

## Where to go next

The result makes the next step smaller than the design assumed (finding 1
above). In rough order of value:

1. **The first production slice: an agent tile body as a surface, behind a
   default-off flag.** Now fully unblocked — the parked arm proved every
   precondition. No presentation-set machinery, no culling, no chunking, and no
   display list: `cacheDisplay` of a parked body is a working producer. The
   pieces, in dependency order:

   - **`TileSurfaceHostView`** — the probe's `SurfaceBodyView` promoted to
     production: layer-hosting, owns `viewDidChangeBackingProperties`, applies a
     bucketed `contentsScale`. Copy it; do not re-derive it.
   - **The park** — one container owned by `CanvasNSView`, a sibling of
     `worldPlane`, zero-sized so AppKit clips its children out of every draw
     without `isHidden` (which would also stop the layout that keeps streaming
     alive). The probe's version is the reference.
   - **`AppKitCaptureProducer`** — `cacheDisplay` of the parked body at the
     tile's resolution bucket → `CGImage`. Proven to yield real pixels from a
     clipped-out view.
   - **A revision model** — when to re-bake. `AgentDocument.version` is the
     semantic revision and the transcript's 30 Hz gate is already the natural
     cadence; the bucket is the resolution revision. `AgentBlockMeasureKey` is
     the shape to copy (I3).
   - **Promotion** — a demoted tile must become native for interaction.
     Side-effecting `hitTest(_:)` makes it lossless (AppKit hit-tests before
     delivery, I7), so a click or scroll lands on the promoted native body.
   - **Policy** — which tiles are surfaced. The measurement supports the
     aggressive rule (everything except the tile holding first responder or the
     pointer) because promotion is lossless; a zoom threshold is the
     conservative alternative that leaves a gesture's high-zoom part native.
     **Not settled** — this is the one product-shaped choice in the slice.
   - **Its witness** — surfaced/native pixel equivalence at rest, camera CPU
     with the flag on, exactly-once input across a promotion, and streaming
     continuity while surfaced.
2. **Prove I2 at one block.** `AgentBlockRendering` already has
   `measure(block:width:context:)` and
   `updateAccessibility(view:block:context:)` as pure functions of `(block,
   context)`. Add `displayList(block:width:context:)` alongside them for ONE
   renderer and pixel-diff it against the native backend in both appearances at
   1x and 2x. `AgentBlockMeasureKey` is already the revision vector (I3).
3. **Chrome to a screen-space overlay** — now the whole remaining Array-side
   lever, and quantified.
4. **Settle the `_installLayer`/`canvas` question** with its own witness.
5. **The unanswered platform question is still WindowServer/GPU**, not Array
   CPU. Array's camera work is 0.10 ms; the flush is ~2 ms p50 / ~9–10 ms p95
   and flat. Doc 31 item 11 and doc 33's T18 want synchronised whole-system
   evidence before anyone claims end-to-end smoothness. **Nothing measured so
   far is a presentation result.**

## Paste-ready continuation prompt

```text
Continue Array's unbounded-canvas rendering program.

Read in this order:
  .plans/35-session-handoff-2026-08-18.md   (state, results, hazards, next steps)
  .plans/34-unbounded-canvas-implementation-design.md   (LIVE design + ledger I1-I16)
Then .plans/31 / .plans/32 / .plans/33 as needed for evidence, target architecture,
and test architecture. docs/internals/performance-budgets.md has the published
canvas.surface-host-slope numbers.

Repository: /Users/dylan/Documents/personal/Array
Branch: array/integration @ ce493d2. FIVE TRACKED FILES ARE MODIFIED AND
UNCOMMITTED (additive: the new canvas.surface-host-slope probe, its flag, its
matrix leg, the regenerated inventory, and the published budgets doc). Preserve
every untracked .plans/ and docs/ file.

Approved decisions (details in .plans/34 Part XI): I5 retained scene authoritative
at rest and in motion; I4 native residual plane for browser/terminal; I11 strict
streaming (animating content never freezes, no size exemption); I15 Shape A
(scene-in-plane) first, Shape B as the destination.

Measured 2026-08-18 and published: Shape A confirmed. Array-owned CPU per camera
step p50 at 5/15/25/50 real agent tiles went 9.39/30.31/57.01/140.57 ms native to
0.07/0.11/0.17/0.19 ms with a flat surface body and every real agent still alive
in a park (parkedVsNativeRatio 0.001, slope 0.122 ms). Culling is NOT what buys
it - replacing the body is (unculled slope 0.155 ms), so the presentation-set and
chunking machinery is not a prerequisite. With the body gone, CHROME is
essentially all of Array's remaining camera cost. The
CATransaction flush is compositor sync, flat in surface arms and scaling in the
native arm - never fold it into Array CPU and never call it "presented".

NOT verified: the full scripts/run-matrix.sh run, because CoreChecks drives real
tmux on the default socket and would kill Dylan's live Array terminals. The leg's
matrix reporting is therefore unconfirmed - finish it in an isolated worktree or
when Dylan is not working in Array, and ask first.

A fourth arm then proved the SHIPPABLE configuration: surface hosts in the plane
with every real agent body still alive in a park outside it. parkedVsNativeRatio
0.001, parkedVsUnculledRatio 0.824 (live bodies cost nothing), and
parkedTranscriptLayouts exactly 0 - a camera step cannot reach a parked body -
with three liveness teeth proving the body is quiet rather than dead, including
that cacheDisplay of a clipped-out view still yields real pixels that change when
one streaming event arrives. So the interim cacheDisplay producer EXISTS and the
production slice does not wait on I2.

Next best work: the first production slice (an agent tile body as a surface behind
a default-off flag). See .plans/35 "Where to go next" item 1 for its pieces in
dependency order. The one unsettled choice inside it is the surfacing POLICY -
aggressive (everything but first-responder/pointer, lossless via hitTest
promotion) vs a zoom threshold. Then chrome to a screen-space overlay, then prove
I2's per-block display list on ONE renderer against the native oracle. Open
questions Q3/Q4/Q8 have recorded defaults in .plans/34 Part XII and do not block.

Hazards: never run the matrix/CoreChecks while Array is open; any surface host must
own viewDidChangeBackingProperties with a bucketed contentsScale policy (AppKit
fires it once per host per camera step); setZones removes the views it finds in
layer.tileViews, so remove explicitly BEFORE swapping that dictionary or the
previous arm stays installed.

Do not commit, rebase, or modify production source beyond what Dylan authorises.
```

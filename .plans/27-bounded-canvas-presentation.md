# 27 — Bounded canvas presentation for 5–50+ mixed tiles

Date: 2026-08-15

Status: architecture and measurement contract. This replaces the all-or-nothing
opaque-live fallback in `.plans/26`; it does not replace `.plans/24`'s camera
driver or the evidence in `.plans/25`/`.plans/26`.

## 2026-08-16 product ruling: full detail is non-negotiable

Dylan rejected the synthetic shell presenter immediately: “we need full detail
when zooming.” The default-off production experiment was removed before any
commit. The detailed preview was rebuilt and reopened without it.

This supersedes every “soft summary,” generic shell, label-only, or missing
browser/terminal fallback proposed below. A motion presenter is eligible only
if every visible tile retains its full visual content during zoom. A
pixel-faithful frozen representation may be investigated, but abstracting or
replacing transcript, browser, terminal, zone, title, status, or chrome content
is not an acceptable performance tradeoff. If a tile cannot provide full-detail
pixels, the architecture—not that tile's fidelity—must change.

## Outcome

Zoom cannot be made pan-like by further tuning the camera driver. The driver is
already display-paced and pan is the control. The remaining repeated work is an
AppKit consequence of changing the live world plane's bounds size: every zoom
frame propagates backing changes through every installed native subtree.

The target is therefore a dual presentation architecture:

1. The semantic world and desired camera remain live and authoritative.
2. Resting, interactive native views are one presentation of that world.
3. During camera motion, an Array-owned, noninteractive compositor may present
   only full-detail, pixel-faithful tile content and receives one root affine per
   frame.
4. The native world is baked once behind that presenter at settle.
5. Native residency/LOD is bounded separately so that the one bake does not
   become a 50-tile main-thread cliff.

This is O(1) in **camera mutations** and bounded in presentation working set. It
cannot be literally O(1) in visible pixels or live external surfaces.

## Evidence already established

- Dylan's clean dogfood control: pan holds cadence while zoom falls as low as
  about 30 FPS on the same 10-agent canvas.
- Real active-zoom examples: 22–28 ms median frames, 33–51 ms p95, roughly
  47–59% late. Pan examples remain at the 8.33 ms display cadence.
- The repeated stack begins at `CanvasWorldPlaneView.setBoundsSize`, then enters
  `_NSViewHierarchyDidChangeBackingProperties`, nested `NSScrollView` tiling,
  Auto Layout, and native subtree rasterization.
- `canvas.geometry-hold-probe`, using 10 real managed-agent tiles with six-turn
  transcripts and a real display/CA flush, measured stepped frames around
  30–31/37–39 ms p50/p95 versus held frames around 0.01/0.02 ms. It recovered
  98.5% of gesture cost even after charging one final bake.
- A 2026-08-15 agent-tree slope run (ABBA, 12 ticks/arm, six turns per agent)
  established that the final bake is linear too:

  | agents | stepped p50 | stepped p95 | one-bake p50 | held p95 |
  |---:|---:|---:|---:|---:|
  | 5 | 15.29 ms | 19.46 ms | 14.56 ms | 0.12 ms |
  | 10 | 30.50 ms | 36.23 ms | 28.05 ms | 0.07 ms |
  | 25 | 72.46 ms | 110.86 ms | 70.79 ms | 0.02 ms |
  | 50 | 132.72 ms | 210.26 ms | 137.89 ms | 0.06 ms |

  Held ticks caused zero transcript layouts at every size. Stepped ticks caused
  exactly one transcript layout per installed agent per camera write (120, 240,
  600, and 1,200 across the two stepped observations). This promotes bounded
  native residency from a conditional follow-up to a required part of the
  25–50-tile design.
- `canvas.proxy-scene-probe` then tested the proposed motion boundary directly:
  the same real 5/10/25/50 agent trees remained installed behind an image-only,
  layer-hosting proxy with one shared synthetic shell image per tile and one
  owned root affine per camera tick. Across 60 ticks:

  | agents | stepped p50/p95 | proxy p50/p95 | one bake |
  |---:|---:|---:|---:|
  | 5 | 16.37/20.21 ms | 0.02/0.03 ms | 14.79 ms |
  | 10 | 31.91/38.61 ms | 0.02/0.03 ms | 29.17 ms |
  | 25 | 75.21/93.24 ms | 0.02/0.04 ms | 71.08 ms |
  | 50 | 145.19/170.95 ms | 0.03/0.05 ms | 133.72 ms |

  Every size produced exactly 60 root mutations for 60 targets, zero native
  bounds writes/tile layouts/transcript layouts during proxy motion, one bake,
  zero anchor/world-mapping error, and zero final camera mismatches. This proves
  the supported scene shape itself is flat through 50 layers. It does not yet
  prove capture cost, coverage, mixed live providers, or production lifecycle.
- AppKit `NSScrollView` magnification reproduced the cascade and was rejected.
- A freshly captured whole-viewport proxy transformed cheaply, but synchronous
  capture cost 22.07 ms and 24.4 MiB at 1600x1000 Retina, could not reveal newly
  exposed world, and could not generically capture WKWebView/Ghostty.

Do not begin another driver-tuning or attribution pass before testing the
bounded presenter.

## Correction to the previous live-surface rule

`.plans/26` proposed denying held presentation whenever a visible installed
`BrowserTileNSView` or `TerminalTileNSView` had no exact cached bitmap. That
cannot satisfy the product workload. A representative canvas containing 15
agents, 5 browsers, and 5 shells would almost always take the slow fallback for
the entire gesture.

The current rule is:

- Every visible tile must remain fully detailed throughout zoom.
- Generic shells, semantic summaries, label-only fallbacks, and missing live
  pixels are rejected, even for a short gesture.
- One missing browser/terminal raster still must not force the entire canvas
  back to per-frame native bounds stepping; instead, it disproves that presenter
  design until an exact supported source exists.
- Unknown future surface classes fail closed with an explicit reason, counter,
  and visible development diagnostic; they must not silently disable the fast
  path.

Specific providers:

- Array/AppKit tiles: idle `cacheDisplay` capture, chunked and budgeted.
- Managed agents: full transcript, title, status, composer, and chrome pixels;
  streaming freshness and motion capture must be proven without degrading the
  visible representation.
- WKWebView: public asynchronous `takeSnapshot`, prepared while idle. Array
  chrome remains separately renderable.
- Ghostty: exact GPU pixels require a supported Ghostty readback seam. The
  text/theme/grid summary is rejected. Screen recording is not an acceptable
  dependency.

The native view must contain the latest semantic state after settle, and the
motion representation must remain visually complete before it.

## Motion presenter

Use a dedicated click-through and accessibility-ignored layer-hosting view that
contains **only Array-owned CALayers and images**. It never hosts, reparents, or
transforms an AppKit-created backing layer. That keeps the rejected
`worldPlane.layer.transform` shortcut rejected.

Before admission, build a shallow scene from cached tile/zone chunks in world
coordinates and pin every admitted cache entry until the gesture ends. During
the gesture:

- `canvasState.viewport` is the desired camera truth.
- The native `worldPlane` remains at an explicit baked viewport.
- Native bounds/frame writes, chrome refresh, view conversion, layout, capture,
  and cache generation are prohibited.
- The only presentation mutation is one disabled-actions root affine.

For baked camera `B = (bx, by, bz)` and desired camera
`D = (dx, dy, dz)`:

```text
q = dz / bz
translation = ((bx - dx) * dz, (by - dy) * dz)
presented = q * baked + translation
```

This composes pinch, Cmd-scroll zoom, glide, changing anchors, and the sticky
pinch-to-pan handoff without freezing the initial anchor.

At settle, keep the proxy visible, apply `D` to the native plane exactly once,
pump/flush the real display transaction, refresh chrome and screen overlays
once, and only then remove the proxy. A cache/coverage failure during motion is
a presenter-design failure: it must not substitute a summary, omit content, or
oscillate the whole gesture between presenter and native stepping.

## Interaction contract

While held, AppKit descendant geometry describes `B` while semantic hit testing
describes `D`. Ordinary interaction cannot cross that split.

- Camera gestures continue through the existing window-level routing.
- Mouse-down, drag/drop, and accessibility interaction force a synchronous bake
  before AppKit chooses a native descendant.
- Initial shipping policy disables held presentation while VoiceOver or Switch
  Control is active; a later lightweight accessibility mirror may replace that
  fallback. Do not expose stale native AX frames under a moving proxy.
- Do not bake from recursive `hitTest`.
- Focused/first-responder identity is pinned through the gesture.
- Screen-fixed overlays either derive from model world frames plus `D`, or stay
  hidden until bake; they must never use stale `NSView.convert` geometry.
- The final native screen-frame and independent hit oracle must be exact before
  the proxy is removed.

## Cache and memory model

Full-resolution, per-tile Retina caches do not scale. Default tile sizes imply
approximately 5.1 MiB per agent, 10 MiB per browser, and 8 MiB per terminal at
2x. The 15/5/5 example is about 166 MiB for one full-resolution copy before
variants or overhead.

Start with these explicit bounds:

- Resolution is a measured fidelity contract, not a pre-approved tradeoff.
  Begin experiments at one proxy pixel per screen point only if pixel comparison
  proves that it retains full visible detail across the supported zoom range;
  otherwise raise the capture bucket or reject that cache shape.
- Scale buckets spaced by `sqrt(2)`; retain at most one last-good raster per tile
  plus one replacement in flight, never a permanent pyramid.
- Split captures larger than 512x512 proxy pixels into 1 MiB decoded chunks with
  a one-pixel gutter.
- Default decoded-byte target 48 MiB; hard cap 64 MiB; shrink to 24 MiB on memory
  pressure and purge on critical pressure.
- Account decoded bytes exactly as `pixelsWide * pixelsHigh * 4`; compressed file
  size is not a memory budget.
- Preload envelope begins at 25% beyond each viewport edge. At 1600x1000 and 1x,
  that is about 13.7 MiB of dense RGBA coverage; a 50% margin is about 24.4 MiB.
- Cache preparation waits for at least 250 ms of input/camera quiet, performs at
  most one chunk and at most 1 ms of main-thread work per display interval, and
  aborts immediately when interaction begins. Only one WK snapshot may be in
  flight initially.

Hard cache identity is `(tileID, worldSize, appearanceEpoch, scaleBucket,
providerKind)`. Move and z-order do not invalidate pixels. Content changes are
soft dirty: retain the last-good image while a replacement is prepared. Resize,
appearance/backing-scale changes, and provider replacement are hard dirty.
Freeze the admitted revision for the gesture and reveal all queued semantic
updates after settle.

The first presenter probe must compare two bounded scene shapes rather than
assuming one:

- provider-owned 512px chunks (initially at most 16–32 resident presentation
  layers); and
- one or two precomposed, viewport-sized gesture sheets prepared while idle.

Both sit below one owned root transform. Reject a workspace-sized atlas: its
memory and update cost scale with world extent. Measure CA flush/render-server
cost and transient double-buffer memory before selecting chunks or sheets; do
not synchronously precompose either at gesture start.

For 5–50 tiles, one linear admission scan is simpler and cheap enough. Do not put
the current `CanvasEntityIndex` spatial queries on the frame path: they still
filter and sort the complete entity set. Consider a uniform grid only if a
5/50/250/1000 query slope exceeds 0.25 ms. Admission and coverage never run per
display tick.

## The second boundary: resting native residency

Geometry hold removes repeated work but does not make the final bake constant.
Ten real agent tiles already cost about 28 ms for one bake; a crude linear
50-agent extrapolation is about 140 ms. The proxy can prevent a visual jump, but
it cannot hide a main-thread freeze from input or the frame recorder.

The measured bake slope already fails that boundary: 25 agents cost 70.79 ms
and 50 agents cost 137.89 ms at the median. Therefore the presenter may land as
an opt-in motion proof, but it cannot be called the 25–50-tile solution until it
also uses a bounded mounted-native working set:

- Keep semantic activity independent from presentation residency.
- Keep focused, first-responder, dragged, modal-owning, and AX-active tiles
  pinned at editable detail.
- Present overview/readable tiles as pixel-faithful full-detail rasters instead
  of full native trees; summaries remain rejected.
- Mount full native trees only for the readable/editable viewport plus a small
  halo; demount incrementally behind the motion proxy.
- Reuse `ReadabilityPolicy`, `HydrationTier`, `ZoneHydrationOrchestrator`,
  `BrowserRuntimeBudget`, and the focus broker rather than creating a competing
  lifecycle model.

This is the mechanism that makes the **one bake** bounded when many projects or
50+ tiles exist. It follows the motion presenter; it is not optional if the bake
slope fails.

## Required mixed-workload witness

The current 10-agent fixture is an attribution witness, not the product capacity
test. Add a display-dependent opt-in scenario with these counts and the 3:1:1
composition:

| total | agents | browsers | terminals |
|---:|---:|---:|---:|
| 5 | 3 | 1 | 1 |
| 15 | 9 | 3 | 3 |
| 25 | 15 | 5 | 5 |
| 50 | 30 | 10 | 10 |

Run two placements:

- **packed/fit:** every tile intersects the zoom-out preload region;
- **fixed-visible:** 5 or 12 stay visible while the remainder are far away, to
  separate visible compositor cost from installed-tree slope.

Use six-turn real managed-agent transcripts, local deterministic WKWebViews, and
real isolated Ghostty surfaces. If real Ghostty cannot run safely in the harness,
that cell remains an explicit dogfood gate; do not silently substitute a cheap
view. Run quiescent sweeps for all sizes and live-churn sweeps at 25 and 50 with
streaming agents, two bounded-output terminals, and an animated local page.

For each cell, compare presenter OFF/ON in ABBA order after warmup, with at least
five observations per arm. Drive the same 2-second zoom-out and zoom-in, center
and corner anchors, pinch-to-pan, glide, and settle. Keep per-run distributions;
do not pool them into one flattering average. Profile one 25- and one 50-tile
OFF/ON run only after counters prove each arm exercised the intended mechanism.

## Counters required before mechanism tuning

- gesture kind and phase: active, forced bake, settle bake;
- observed cadence, p50/p95/p99/worst, missed-vsync severity, and apply-to-flush;
- presenter requested/eligible/activated and explicit denial reason;
- cached, exact-provider, uncovered, and unknown-provider counts by installed view
  class;
- requested/available coverage, holes, pinned entries, decoded-byte high-water,
  evictions, preparation slice duration, and captures begun during interaction;
- proxy root mutations, bounds-size writes, native tile/transcript layouts,
  executed draws, chrome refreshes, and mode transitions during active motion;
- soft/hard invalidations, admitted revision age, and latest revision visible
  after bake;
- bake count/duration, interaction-forced bake count/latency, and whether the
  proxy survived through the real display flush;
- per-frame anchor error, exposed/blank pixels, final viewport mismatch,
  screen-frame mismatch, and semantic/AppKit hit mismatch.

The current frame recorder also needs two corrections before these numbers gate
the design: preserve the first camera step, and report active motion separately
from the smooth 250 ms quiet tail. The tail currently dilutes the completed
gesture distribution.

## Acceptance and rejection gates

Correctness is binary:

- zero blank/exposed pixels in admitted coverage;
- anchor error at most one device pixel;
- zero native bounds-size writes/layouts/transcript layouts/captures during held
  motion;
- exactly one root affine mutation per presented camera commit;
- exactly one native bake after a normal held gesture;
- zero mode oscillations and zero proxy removals before the baked flush;
- no stale semantic update after settle;
- zero final viewport, screen-frame, or hit-test mismatches;
- cache high-water never exceeds the hard cap.

Performance is relative to pan on the same fixture and run:

- zoom average FPS at least 90% of pan;
- zoom p95 no more than one display cadence above pan;
- zoom late share no more than five percentage points above pan and at most 10%;
- p99 at most three display cadences;
- at least 75% fewer missed-vsync intervals than presenter OFF;
- from 5 to 50 tiles, proxy mutations stay exactly one per commit and active
  p95 grows by no more than 2.1 ms;
- enabling an idle presenter changes pan average FPS by less than 5%, pan p95 by
  less than 1 ms, and pan late share by less than two percentage points while
  background preparation is active.

The packed 25-tile mixed case must admit the presenter for at least 95% of warm
gestures with **no whole-gesture opaque-surface fallback**. An agent-only success
is not the zoom fix.

Treat settle separately: initial targets are at most 50 ms p95 for 25 tiles and
100 ms for 50. If active motion is flat but the 50-tile settle misses, report the
capacity boundary and build bounded native residency; do not call it O(1).

## Implementation order

1. **Done:** correct the frame recorder's first-step and settle-tail accounting
   without adding another timer/display link.
2. **Done for agents:** measure native active/bake slopes through 50 real agent
   trees. The mixed 5/15/25/50 browser/terminal fixture is still owed.
3. **Done as a cost witness, rejected as UX:** the synthetic proxy scene proved
   one affine per tick and flat motion cost, then Dylan rejected its loss of
   detail. No production presenter code from that experiment remains.
4. Run the redraw-policy/backing-reuse matrix on the full native tree. This is
   the smallest supported experiment that might preserve the exact current
   pixels while reducing raster work; stop if layout/scroll tiling remains over
   budget.
5. Isolate agents, WKWebViews, and Ghostty surfaces at 1/5/10 or 1/5/15 counts,
   including installed-offscreen controls, before choosing a presentation
   architecture.
6. Prove exact pixel sources independently: AppKit capture, public asynchronous
   `WKWebView.takeSnapshot`, and either a supported Ghostty pixel/readback seam
   or a verified exact `cacheDisplay` result. A semantic terminal summary is not
   an alternative.
7. Only if those sources satisfy the full-detail contract, build the idle cache,
   byte accounting, bounded chunk/sheet scheduler, and mixed-workload presenter.
8. Measure the final bake and add bounded native residency with pixel-faithful
   stand-ins if 25–50 mounted trees still block the main thread.
9. Dogfood on the preserved project with the live HUD. Dylan's feel report and
   pixel fidelity are product gates.
10. Only after all gates pass: default the mechanism, remove experiment
    switches, ratchet budgets, and hand-tune glide constants. The present branch
    may merge with the known residual zoom cost documented; this future program
    is not a prerequisite for shipping the already-confirmed camera/sidebar work.

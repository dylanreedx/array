# 28 — Zoom performance investigation handoff

Date: 2026-08-17

Status: attribution is complete enough to pause. The unified camera, sidebar
redesign, symbol freeze, live frame HUD, measurement probes, and recorder
corrections are merge candidates. Native full-detail zoom is still a known
performance limitation and remains a later program; no degraded-detail motion
presenter is shipping.

Read first: `.plans/27-bounded-canvas-presentation.md`, then `.plans/26`,
`.plans/25`, and `.plans/24` for the evidence chain.

## Product decision that controls the next attempt

Dylan requires full visual detail while zooming. The default-off synthetic shell
presenter was rejected immediately and removed before commit. Generic shells,
semantic summaries, missing browser/terminal bodies, or label-only substitutes
are not valid optimizations. A pixel-faithful frozen image remains an experiment,
not an approved product tradeoff; it must prove detail, coverage, freshness, and
interaction behavior before it can become a mechanism.

## Why pan is smooth and zoom is not

Pan and zoom share the same input routing, display-paced `CanvasCameraDriver`,
and `CanvasNSView.setViewport` funnel. They diverge at one AppKit operation:

- pan changes `CanvasWorldPlaneView.bounds.origin` at a constant points-to-pixels
  ratio, so Core Animation can translate existing backing stores;
- zoom changes `CanvasWorldPlaneView.bounds.size`, changing the ancestor scale.

That size write enters `_NSViewHierarchyDidChangeBackingProperties` and fans out
through every mounted native descendant, including offscreen-but-installed
trees. AppKit retiles nested `NSScrollView`/`NSClipView` hierarchies, revisits
intrinsic sizes and Auto Layout/`NSStackView`, lays out transcript collections,
redraws native content, and commits the layer tree. Clipping limits pixels; it
does not stop the descendant traversal.

The camera math is O(1). The current native presentation is approximately
O(mounted subtree complexity) for every zoom frame.

## Numbers to retain

The clean user-facing control is pan at roughly the 8.33 ms display cadence with
about 3% late frames; zoom on the same real-agent canvas reaches roughly
23–51 ms frames, 47–59% late, and about 30 FPS in the live HUD.

The real managed-agent slope witness measured:

| agents | stepped p50 | stepped p95 | one bake | held p95 |
|---:|---:|---:|---:|---:|
| 5 | 15.29 ms | 19.46 ms | 14.56 ms | 0.12 ms |
| 10 | 30.50 ms | 36.23 ms | 28.05 ms | 0.07 ms |
| 25 | 72.46 ms | 110.86 ms | 70.79 ms | 0.02 ms |
| 50 | 132.72 ms | 210.26 ms | 137.89 ms | 0.06 ms |

Held ticks caused zero transcript layouts. Stepped ticks caused one transcript
layout per installed agent per bounds-size write. The standalone owned-layer
proxy cost witness stayed around 0.02–0.05 ms through 50 image layers, proving
that one root affine is cheap, but its synthetic visuals are explicitly not a
product design.

## Heavy areas, in order

1. AppKit backing-property propagation plus native layer redisplay.
2. Nested transcript scroll/collection tiling and layout.
3. Auto Layout, stack views, intrinsic text measurement, composer/header/footer
   geometry, and visible TextKit renderers.
4. Core Animation display/commit of the resulting dirty layer tree.
5. Browser and terminal remote/GPU surfaces: plausible additional cost, but not
   yet isolated quantitatively. The strongest existing slope is agent-only.

Explicit Array chrome refresh, camera math, persistence, hydration reconcile,
and SF Symbol rasterization are not the residual root cause. Symbol bitmaps did
remove a real secondary cost. Driver coalescing already limits camera mutation to
display pace; presenting fewer expensive frames would create staircase motion,
not solve the cost of each frame.

## Surface-specific facts

- Managed-agent tiles are especially deep: transcript scroll/collection views,
  nested command/code scroll views, TextKit, stacks, constraints, composer,
  status, and chrome.
- `WKWebView.takeSnapshot` is the public asynchronous exact-image seam for normal
  browser content. Animated/video/WebGL fidelity and capture latency still need
  current-machine tests. The existing browser live budget is six; overflow uses
  an 80x60 placeholder, which is a separate full-detail capacity issue.
- Ghostty already renders into IOSurface-backed layers and Array intentionally
  keeps its terminal grid stable during camera zoom. The bundled C ABI has no
  supported pixel/readback export. `cacheDisplay` deserves a direct pixel test
  because upstream Ghostty uses it for drag previews; otherwise an explicit
  retained-IOSurface/copy API must be added or upstreamed. Text reconstruction
  is not pixel-faithful and is rejected.

## Best next experiments, in order

1. **Native backing reuse/redraw policy A/B.** On the real detailed tree compare
   current behavior with carefully scoped `.onSetNeedsDisplay`/cached-content
   policies. Count backing notifications, scroll/layout passes, executed draws,
   CA flush, and pixel differences. This may reduce raster cost; reject it as the
   main fix if the layout cascade remains over budget.
2. **Tile-family isolation.** Measure agent-only, browser-only, terminal-only,
   and 15-agent/5-browser/5-terminal scenes, with visible and offscreen-installed
   placements. Profile app, WebContent/GPU, and WindowServer together.
3. **Exact pixel-source tests.** Establish latency, fidelity, decoded bytes,
   revision freshness, and accelerated-content gaps for AppKit, WKWebView, and
   Ghostty independently before building any cache/presenter.
4. **Bounded live-island slope.** If exact frozen pixels are acceptable and
   available for most content, measure 0/1/2/5 truly live native islands over an
   exact-pixel background. Reject if even one island recreates the global cost.
5. **Native residency.** The one-bake slope proves that a 25–50-tile design must
   bound mounted native trees, not merely visible ones. Keep semantic runtimes
   alive, pin focused/IME/drag/modal/AX tiles, and use pixel-faithful stand-ins
   for nonresident views. This is a large state-machine change and comes only
   after exact pixel sources exist.
6. **Strategic flattening.** If AppKit cannot reuse detailed backing cheaply,
   replace deep agent transcript/chrome subtrees with a custom virtualized
   renderer and promote only active controls to native views. This preserves
   detail but is the largest engineering path.

## Dead ends that stay dead

- Directly transform an AppKit-owned backing layer or reparent its child layers.
- Put native NSView subtrees inside a layer-hosting view.
- NSScrollView magnification; the real-tree probe reproduced the same cascade.
- Synchronous whole-viewport capture at pinch start: measured 22.07 ms and
  24.4 MiB at 1600x1000 Retina, lacks zoom-out coverage, and is not a generic
  live-surface solution.
- Generic shells/summaries or semantic terminal reconstruction.
- More camera coalescing, quantized zoom, or glide tuning as a performance fix.
- ScreenCaptureKit/private IOSurface scraping without a new explicit product
  decision about permissions and unsupported dependencies.

## Measurement method

For every experiment use matched ABBA arms, warm the fixture, pump
`window.displayIfNeeded()` plus `CATransaction.flush()`, retain raw per-run
distributions, and count the causal work before profiling it. A faster result is
invalid unless the arm proves the expected bounds writes/layouts/draws occurred
or did not occur, and a pixel oracle proves full detail was retained. Compare
against pan on the same display/run; the HUD is the user-facing symptom meter,
not the attribution tool.

The frame recorder now preserves the first camera step and excludes the smooth
250 ms quiet tail while retaining the interval after the final delivered step,
where AppKit/CA work can land. It still does not label pan versus zoom and uses
the display's maximum refresh rate as its cadence reference.

## Merge boundary

It is acceptable to merge the current product work with the residual native
zoom limitation documented as known debt. The merge does not claim zoom is
finished or O(1), and it must not include the rejected synthetic presenter.
Before merging, verify the focused checks and one clean full matrix, then merge
the sidebar and zoom histories into `array/integration` under Dylan's identity,
with no AI trailers. This creates an integration/prod candidate; it is not a
release to `main`, an appcast update, or an installation over `/Applications/Array.app`.

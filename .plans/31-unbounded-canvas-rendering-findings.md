# 31 — Unbounded canvas rendering findings

Date: 2026-08-17

Status: evidence record. This document freezes the current understanding of the
released Array 0.5.0 canvas rendering failure. It is not an implementation plan
and does not authorize a rendering mechanism.

Companion architecture document:
`.plans/32-unbounded-canvas-target-architecture.md`.

Evidence chain:

1. `.plans/24-canvas-camera-unification.md`
2. `.plans/25-session-handoff-2026-08-14.md`
3. `.plans/27-bounded-canvas-presentation.md`
4. `.plans/28-session-handoff-2026-08-17.md`
5. `.plans/29-real-workspace-rendering-investigation.md`
6. `.plans/30-session-handoff-2026-08-17-unbounded-canvas.md`

Repository state while this record was written:

- branch: `array/integration`;
- HEAD: `ce493d276d7691bcd874ac1b1329f92dd7447454`;
- released as Array 0.5.0;
- no source files were changed during the investigations consolidated here;
- existing untracked planning and design files remain user-owned.

## Product direction that constrains every conclusion

- Array has no desired tile-count ceiling. The 5/15/25/50 cells are
  measurement points, not product capacity limits.
- Projects may accumulate many zones and many more than fifty semantic tiles.
- Every visible tile must retain its real visual content during zoom. Generic
  shells, label-only cards, summaries, or missing browser/terminal bodies are
  rejected.
- Full detail does not require maximum-resolution storage for the entire world.
  It requires complete real content at the resolution physically demanded by
  the viewport, with explicit contracts for temporary softness and freshness.
- Pan is already smooth. Zoom should feel comparably immediate.
- The current AppKit composition is evidence, not a boundary on what Array may
  become.
- Architecture understanding and implementation planning are separate. This
  record performs the former only.

## Executive finding

Array's camera math is cheap. The released zoom presentation path is expensive
because it changes the effective scale of the native semantic view hierarchy on
every presented camera step.

Pan changes only `CanvasWorldPlaneView.bounds.origin`. Zoom changes
`CanvasWorldPlaneView.bounds.size = viewportSize / zoom`. The bounds-size write
enters AppKit's backing-property propagation and reaches every installed native
descendant: scroll and clip views, collection layouts, TextKit, stack views,
constraints, and layer display. It may also trigger remote-surface and Core
Animation/WindowServer consequences; those stages remain unapportioned.

The durable architectural conclusion is:

> Camera motion must not mutate the effective scale of the live semantic native
> hierarchy.

The evidence does **not** yet establish which downstream consequence accounts
for most of the released one-FPS failure. Geometry hold simultaneously removes
Array layout work, AppKit backing traversal, backing-store allocation,
rasterization, Core Animation graph work, texture/IOSurface churn, and possible
WindowServer/GPU synchronization. Those stages remain to be apportioned.

## The production workload

The saved workspace corresponding to the supplied screenshot contains:

- four expanded zones plus one unzoned tile;
- twenty tiles total;
- twelve managed agents;
- six file tiles;
- one live browser;
- one live terminal;
- zone tile counts of 5, 1, 11, and 2, plus the unzoned agent;
- approximately 14.1 million square world points of tile content;
- an overview around zoom 0.2 with nearly the complete scene visible.

Released Array 0.5.0 can show a rolling result near 1 FPS during zoom while pan
remains smooth. This is the minimum faithful baseline, not a stress case.

The HUD is a time-weighted summary of display-link callback intervals. It is a
valid main-thread-starvation and feel signal, but not a direct record of
WindowServer presentation timestamps. A single extreme stall can depress the
rolling value. Raw intervals are required to distinguish sustained one-second
steps from mostly 30–50 ms steps interrupted by a catastrophic tail.

“Full detail” has four independent contracts throughout this record:

1. pixel completeness;
2. resolution fidelity;
3. temporal freshness;
4. native interaction and accessibility.

Brief exact-but-frozen pixels during a gesture were discussed as a possible
contract, not blanket-approved. They are categorically different from a shell,
but still require an explicit freshness decision.

## What is proven

### One native scale write fans out through installed descendants

The camera path is unified and display-paced. Pan and zoom diverge at the world
plane operation:

```text
pan   -> bounds.origin changes -> constant points-to-pixels ratio
zoom  -> bounds.size changes   -> ancestor effective scale changes
```

AppKit responds to zoom by propagating backing changes through installed
descendants. Clipping reduces visible pixels; it does not make installed native
subtrees absent from this traversal.

### Native zoom cost scales with mounted agent complexity

On homogeneous six-turn managed-agent trees:

| agents | stepped p50 | stepped p95 | one bake | held p95 |
|---:|---:|---:|---:|---:|
| 5 | 15.29 ms | 19.46 ms | 14.56 ms | 0.12 ms |
| 10 | 30.50 ms | 36.23 ms | 28.05 ms | 0.07 ms |
| 25 | 72.46 ms | 110.86 ms | 70.79 ms | 0.02 ms |
| 50 | 132.72 ms | 210.26 ms | 137.89 ms | 0.06 ms |

Stepped writes caused exactly one transcript layout per installed agent per
write. Held ticks caused no transcript layouts. Including one final native bake,
geometry hold recovered approximately 98.5% of the measured ten-agent gesture
cost.

This proves a scaling law in the current presentation architecture. It does not
prove that transcript layout itself consumed 98.5% of wall time.

### The measured Array-owned affine path is cheap

One owned root affine through 5/10/25/50 synthetic image layers measured
approximately 0.02–0.05 ms for the Array-side mutation, display pump, and
`CATransaction.flush()`, with zero native tile or transcript layouts. This proves
that this prepared-layer camera path is inexpensive at the measured counts. It
does not by itself measure end-to-end WindowServer/GPU presentation latency.

The synthetic shell visuals used in that cost witness were rejected as a
product design. The cost result remains valid; the visuals do not.

### One final native bake scaled approximately linearly in the measured range

Holding native geometry only during a gesture does not solve the resting
architecture. The one-bake median rose from roughly 15 ms at five agents to
roughly 138 ms at fifty. A gesture-only proxy can hide pixels during the bake,
but it cannot hide main-thread input starvation.

### Several presentation shortcuts are closed

Closed by platform contract or direct measurement:

- transforming or reparenting AppKit-owned backing layers;
- putting native NSView subtrees inside a layer-hosting view;
- `NSScrollView` magnification, which reproduced the same layout cascade;
- synchronous whole-viewport capture at gesture start;
- additional camera coalescing, quantization, or curve tuning as the root fix;

Rejected by the product fidelity contract:

- generic shells, summaries, or incomplete live-surface fallbacks;
- semantic reconstruction of terminal pixels.

Falsified inference:

- assuming Metal automatically fixes content production.

Policy-gated rather than technically disproven:

- unsupported/private surface scraping or screen capture without a separate
  product decision.

Fresh whole-viewport capture measured 22.07 ms and 24.4 MiB at 1600×1000
Retina, provided no newly exposed zoom-out coverage, and could not generically
include WKWebView/Ghostty pixels. Once prepared, the shallow proxy transformed
cheaply; acquisition and coverage rejected capture-on-pinch as the mechanism.

### The real-pinch profile identified the cascade shape

The 8,963-sample ten-agent pinch profile showed a perfect 8.33 ms median but
33–47% of frames stalling around 40–120 ms. The stack entered
`_NSViewHierarchyDidChangeBackingProperties`, scroll-view tiling, Auto Layout,
TextKit/collection work, and layer display; approximately 52% of sampled main-
thread time sat within CA commits. This names a bursty cascade, not one uniformly
slow camera calculation.

The pre-freeze profile observed SF Symbol rerasterization. Commit `574e7f7`
froze canvas-descendant symbols into shared template-preserving bitmaps before
the released 0.5.0 HEAD. It proves part of the historical cascade and improved
feel, but it is not a candidate explanation for the released real-workspace
one-FPS gap.

## Why previous fixtures did not reproduce production

- `canvas.stress` drove pan and omitted a faithful display/CA zoom path.
- `canvas.raster` used cheap descriptor tiles.
- `canvas.zoom` used notes and Markdown shapes unrelated to the real workspace.
- `canvas.geometry-hold-probe` used homogeneous six-turn agents.
- `canvas.proxy-scene-probe` measured the affine using synthetic images.
- No fixture combined the real four-zone topology, production-shaped histories,
  Source and Preview files, WKWebView, Ghostty, overview zoom, live churn,
  Release configuration, and synchronized multi-process profiling.

The six-turn agent slope predicts poor zoom, but not the released one-FPS
result. The remaining gap is real and unapportioned.

## Managed-agent findings

These are ranked investigation candidates. Except where explicitly noted, they
are source-proven mechanisms but not measured shares of production time.

### Streaming presentation can remain proportional to total history

The 30 Hz visual scheduler is latest-wins and arms only while an update is
pending. It is not an idle 30 Hz tax. However, accepted updates can still perform
whole-document work on the main actor:

- build sets across all entries;
- recursively scan blocks for managed images;
- compare lifecycle and block identity across history;
- flatten the complete document;
- rebuild old/new row dictionaries;
- apply visible hosts and force native layout.

Several long-history agents may therefore create bursty presentation convoys on
the same main actor and transaction path as camera commits. Final/boundary
updates may flush synchronously.

Source areas:

- `ManagedAgentTileNSView.swift` ingestion and transcript synchronization;
- `AgentTranscriptUpdateScheduler.swift` coalescing;
- `AgentTranscriptListView.swift` `applyCoalesced`, lifecycle reconciliation,
  flattening, and layout.

Required evidence: per-agent visits and duration for ingestion, image hydration,
lifecycle comparison, flattening, visible-host updates, scheduler flushes, and
layout, correlated with raw slow frames across fixed-visible histories of
6/100/500/2,000 or another census-derived ladder.

### Active gyro animation graphs are rebuilt on ancestor layout

`DualPlaneGyroTiltedThinkingIndicatorView.layout()` removes live animations and
reconciliation recreates them. One rebuild creates:

- three nodes;
- four animated key paths per node;
- 145 samples per key path;
- twelve animations and approximately 1,740 values.

This is a direct zoom-by-visible-gyro multiplier. It is more conditional than a
raw active-agent count: the gyro is shown only for a particular running state
when the latest assistant/reasoning stream is not open.

Required evidence: exact visible-gyro census and 0/1/2/4/8/12 count slope,
including animation construction and CA commit time. Preserve the exact
animation while guarding only unchanged local geometry and mode.

### Transcript layout force-drives the live collection path

`AgentTranscriptListView.layout()`:

- calls `collectionView.layoutSubtreeIfNeeded()` twice;
- explicitly invokes layout preparation;
- reframes visible items;
- reconciles collection document height.

The comments justify this for offscreen baselines and Component Lab, but the
same path runs in live windows.

`AgentTranscriptLayout.layoutAttributesForElements(in:)` filters the complete
monotonic attribute array. The prepare path has useful width/count fast paths,
so neither operation should be declared large without timing.

Required evidence: nested layout calls, prepare recomputations, attributes
visited, visible items reframed, and time by history depth. The decisive A/B
separates offscreen materialization from live-window layout.

### Composer TextKit repeats identity work

Every composer layout reaches `ComposerHeightController`, which calls TextKit
layout, recomputes usage, writes scroller policy, and scrolls selection into
view even when text, width, font, and selection are unchanged.

Required evidence: key work by width/content/font/selection revision and count
`ensureLayout`, used-rect queries, scroller writes, and selection scrolling.

### Image backing callbacks can create cancel/re-request churn

`AgentImageCellView.viewDidChangeBackingProperties()` cancels the thumbnail
request, clears the image, and schedules layout. The request key uses the actual
window backing scale, which does not change during canvas zoom.

A zoom cascade can therefore produce repeated cancellation, identical requests,
cache/decode callbacks, image replacement, and further layout.

Required evidence: old/new thumbnail keys, identical request counts, cache hits,
decodes, completions, image clears, and memory/allocation effects.

### Collapsed bodies remain installed

Collapsed command output retains its scroll/text subtree. Expanded-once then
collapsed reasoning may retain body hosts and continue measurement/frame/layout
work.

Required evidence: census retained collapsed descendants and text bytes, then
compare identical collapsed pixels with presentation bodies detached versus
retained.

### Identity frame writes amplify TextKit and scroll work

`AssistantProseView` already documents and guards the fact that assigning an
unchanged `NSTextView` frame can trigger glyph-bounds work. Several other
renderers assign frames and force nested layout without equivalent guards.

Required evidence: changed versus identity frame writes by renderer class and
the downstream layout/glyph work they induce.

### Hidden shell trees increase every agent's base coefficient

Before transcript rows, an idle agent source-installs approximately:

- seventeen stack views;
- four scroll views;
- two collection views;
- one composer text view.

Empty attachment/file rails are hidden rather than absent. A legacy status tree
remains hidden inside production composition for appearance census coverage.

These are likely coefficient and residency costs, not a standalone explanation
for catastrophic tails.

## Non-agent findings

### File Source and Markdown Preview are different performance families

A Source tile is relatively shallow. Markdown Preview eagerly creates one
native renderer view per semantic block, up to 400. Each may contain its own
TextKit, stack, or scroll subtree.

The Preview implementation already caches width-sensitive measurements and
guards identical row frames. The open risk is AppKit backing traversal and
rasterization through hundreds of correctly cached descendants.

The production census must report Source/Preview, block count, renderer-kind
histogram, native descendant/layer/constraint count, and maximum depth.

Tile body and chrome may require separate presentation. Current title bars,
close controls, and status elements use screen-space floors and discrete zoom
buckets. Scaling one whole-tile image can preserve body pixels while violating
chrome geometry and sharpness.

### WKWebView cost may be external to Array

The live browser contains AppKit chrome and a remote `WKWebView`. Work may occur
in Array, WebContent, the WebKit GPU process, Core Animation, or WindowServer.
The existing browser snapshot tier is an 80×60 placeholder and provides no
evidence for an exact presentation design.

`WKWebView.takeSnapshot` is the public asynchronous point-in-time source. Static
page fidelity is plausible; video, WebGL, canvas animation, selection, fixed
content, latency, and freshness require direct tests.

### Ghostty receives unchanged content-scale callbacks

`GhosttyTerminalView.viewDidChangeBackingProperties()` unconditionally calls
`ghostty_surface_set_content_scale` using the window backing scale. Pixel-size
application is guarded; content scale is not.

The same-scale no-op A/B is narrow and pixel-identical. It must count Ghostty
draw/present activity, surface reconciliation, grid and pixel size, and resource
turnover.

The apparent occlusion/visibility Boolean mismatch requires a deterministic red
witness before correction.

Ghostty uses an IOSurface-backed, triple-buffered renderer. A permanent scene
needs a supported completed-frame lease/copy/blit interface or retained native
parking. Retaining an internal layer or IOSurface is not a safe contract.

### Zone chrome is probably secondary but cheap to isolate

Four large, rounded, translucent zone surfaces increase raster area, blending,
and overdraw. They are not explicitly invalidated on every camera commit, so
direct Array drawing is unlikely to explain one-second frames by itself.

An exact captured-zone versus live-zone A/B isolates native hierarchy/raster/
update work while preserving similar composition. A separate diagnostic opaque
or effects-disabled arm is required to isolate alpha blending and overdraw.

### O(all tiles) camera loops are not today's one-FPS cause

`visibleTileViews` scans installed world-plane children on every camera commit,
and focus/attention overlays are updated. At twenty to fifty tiles this is
unlikely to account for the failure.

It must not survive as the principle for an unbounded renderer. Future camera
work should use an immutable gesture presentation set and spatial page/chunk
queries rather than semantic-tile scans.

### Long-running memory/resource churn may produce catastrophic tails

Potential multipliers include:

- hundreds of Markdown renderer trees;
- WebContent and GPU resources;
- Ghostty IOSurfaces;
- tile and zone masks/backings;
- image cancel/decode cycles;
- transient replacement surfaces and double buffering;
- compressed memory, page faults, or allocator contention.

Cold, warm, and long-soak trials must capture RSS, dirty/compressed memory,
allocation rate, IOSurface/texture high-water, and page faults alongside frame
intervals.

## Important red-team corrections

### Do not over-attribute the gyro

The code defect is direct, but visible gyro count is conditional and may be low
while agents stream. Measure the actual count and timing.

### Do not over-attribute O(history)

Whole-history paths are poor scaling principles and must be removed from hot
presentation, but a few hundred lightweight comparisons may remain tiny. Treat
them as candidates until durations correlate with slow frames.

### Do not call every agent scheduler a permanent 30 Hz timer

The timer is one-shot and pending-update driven. The risk is synchronized active
flushes and main-actor convoys.

### Geometry hold does not separate layout from raster and allocation

A diagnostic decomposition must compare:

1. normal bounds-size stepping with the live hierarchy;
2. the same step with Array layout/update callbacks suppressed while identical
   native layers remain installed;
3. held geometry under identical semantic churn.

If arm two remains slow, AppKit backing/raster/resource work dominates the leaf
hotspots.

### Absolute zoom and direction may expose allocation thresholds

Run equivalent gestures centered around approximately 0.15, 0.2, 0.25, 0.5,
1.0, and 2.0 in both directions. The real overview may cross backing, chrome,
or texture thresholds absent from another range.

### Family costs may interact

Single-family subtraction assumes additivity. Measure pairwise interactions on
matched durations:

```text
I(A, B) = T(A+B) - T(A) - T(B) + T(baseline)
```

Useful interactions include active agents × history, agents × churn, Markdown ×
scale, WK × Ghostty, transparency × remote surfaces, and churn × camera.

### Pixel-identical replacements need three residency states

For each family compare:

1. native visible and installed;
2. exact surface visible while the native tree remains installed/subscribed,
   with explicit controls for whether the native tree is still drawable versus
   raster-suppressed-but-installed;
3. exact surface visible while the native tree is parked outside the
   scale-changing hierarchy, with subscription/runtime state controlled
   separately.

An opaque overlay alone does not suppress native drawing and only adds overlay
cost; hiding or changing opacity may also alter traversal. The drawable and
raster-suppressed controls are required before claiming separate attribution of
live raster/composition, installed hierarchy traversal, and semantic/runtime
activity.

## State-ownership findings

A permanent renderer cannot treat existing `detach()` methods as a uniform
residency interface.

### Managed agents

`ManagedAgentTileNSView.detach()` cancels its subscription. Supervisor replay is
capped at 500 events, while the view owns substantial current projection and
presentation state. Normal surface/native switching must initially park and
retain the view without calling `detach()`.

State currently tied to views includes:

- transcript projection/version lineage;
- disclosure state;
- scroll anchor;
- collection and partial text selection;
- image/tool detail presentation;
- composer focus, TextKit, completion, and IME state.

These eventually need view-independent agent projection, reader, and composer
sessions.

### Browser

The browser runtime already has a useful parking seam: its WKWebView can be
removed from a host while the runtime and WebView survive. Termination/recreate
is a deeper, lower-fidelity memory-pressure tier, not normal camera residency.

Browser tab chrome, find state, URL editing state, and presentation revisions
still need ownership outside `BrowserTileNSView`.

### Terminal

Current terminal detach removes the `GhosttyTerminalView` and clears the
runtime's strong reference. Source inspection does not establish a clean,
explicit surface close on that path, creating an unresolved lifetime hazard in
addition to losing accessible interactive state. Persisted process/cwd
information cannot reconstruct exact grid, scrollback
viewport, selection, alternate-screen, cursor, buffers, or IME state.

Normal residency requires either a long-lived surface/view owned above its host
or a supported Ghostty presentation/interaction seam.

### Files

File content is reloadable from its current source under normal conditions, but
the source may change or disappear externally. Exact visual/state reconstruction
requires an owned content revision/snapshot plus a session-level
`FilePresentationState` for mode, Source selection/scroll, Markdown anchor,
parsed presentation, and pending reveal.

### Accessibility

Pixels provide no semantic accessibility. A permanent renderer requires stable
semantic accessibility elements, camera-derived screen frames, actions, focus
synchronization, and suppression of duplicate nodes while native presentation
owns a tile.

Array-owned agents/files can derive this from semantic documents. WKWebView and
Ghostty likely need tile-level proxies that promote and pin the native runtime
for rich accessibility.

## Current architecture implications

The investigation supports six independently selectable ownership layers:

1. semantic/runtime state;
2. revisioned render description;
3. family-specific pixel production;
4. spatial/resolution cache;
5. camera compositor;
6. native interaction and accessibility bridge.

The evidence suggests layer five may already be inexpensive in Core Animation.
The unsolved center is layers two through four and six.

The strongest current architecture hypothesis is:

- optimize native tiles as necessary hygiene;
- extract renderer-neutral revisioned snapshots/display lists;
- use heterogeneous pixel producers by tile family;
- make a permanent, resolution-paged spatial scene authoritative for visual
  presentation;
- materialize or retain native views only for interaction requiring them;
- progressively make Array-owned agents/files renderer-interactive;
- begin with Core Animation composition;
- compare Metal only with identical surfaces if CA/WindowServer misses.

This is a hypothesis to design and validate, not an implementation decision.

## Required target scaling laws

Let `S` be semantic tile count. The architecture should target:

```text
semantic storage       O(S)
camera CPU             O(visible presentation chunks), independent of NSView depth
GPU camera work        O(viewport pixels x overdraw)
visible pixel work     O(changed input + dirty screen-demand pixels/fragments)
surface memory         O(viewport + overscan + adjacent resolution demand)
native work            O(interaction-pinned native views)
```

Semantic/runtime update cost still exists for offscreen state, and pinned
browser/terminal/native runtimes retain their own buffers outside the surface
memory expression. One permanently resident compositor layer per semantic tile
is not an unbounded design. Overview presentation eventually needs sparse,
on-demand page/chunk aggregation. Viewport-culled or pooled per-tile surfaces
may remain useful for dynamic content; the final scene may be heterogeneous.

## Comparative architecture evidence

Nyx reports the combination of eliminating whole-area repaint, temporary GPU
promotion during canvas motion, memoized tile/WebView updates, and tolerance for
terminal reflow jitter. This supports a two-track strategy—local content
stability plus compositor-owned motion—but does not prove that Array's native
hierarchy can be cheaply relaid out.

## Evidence required before committing to a target mechanism

1. Raw released-production zoom and pan distributions.
2. Privacy-safe structural census and isolated fixture parity.
3. Faithful Release reproduction of the four-zone/twenty-tile failure.
4. Active-agent/history/churn factorial attribution.
5. Native layout versus backing/raster/allocation/CA decomposition.
6. Source versus Markdown Preview family slopes.
7. Synchronized Array/WebContent/GPU/WindowServer evidence.
8. Ghostty same-scale callback witness.
9. Exact pixel-source fidelity/freshness/latency for AppKit, WK, and Ghostty.
10. Exact three-state family replacement arms.
11. Exact-surface CA scene at 20/50/100/500 presentation chunks.
12. Pinned native-island slopes and first-interaction correctness.
13. Later architecture validation: state-preserving park/promote prototype.
14. Later architecture validation: production-faithful custom agent renderer
    comparison.
15. Cold cache, rapid reversal, display transition, memory pressure, AX, IME,
    overlap, and long-soak adversarial results.

## Primary references

- Figma, “Building a professional design tool on the web”:
  https://www.figma.com/blog/building-a-professional-design-tool-on-the-web/
- Figma, “Keeping Figma fast”:
  https://www.figma.com/blog/keeping-figma-fast/
- Figma, “Figma rendering: Powered by WebGPU”:
  https://www.figma.com/blog/figma-rendering-powered-by-webgpu/
- Figma, “Building accessibility into a canvas-based product”:
  https://www.figma.com/blog/building-accessibility-into-a-canvas-based-product/
- Chromium, “GPU Accelerated Compositing in Chrome”:
  https://www.chromium.org/developers/design-documents/gpu-accelerated-compositing-in-chrome/
- Nyx changelog:
  https://getnyx.dev/changelog/
- Apple, Core Animation Programming Guide:
  https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/

## Final finding

Array's performance problem is not that a two-dimensional affine transform is
hard. It is that the affine is currently expressed by resizing an ancestor of a
collection of complete native mini-applications.

The investigation has established the architectural boundary to change. It has
not yet apportioned the production failure or selected the final mechanisms on
the far side of that boundary. The companion target-architecture document turns
this evidence into a system model without converting it into an implementation
plan.

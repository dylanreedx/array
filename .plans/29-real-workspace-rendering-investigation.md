# 29 — Real-workspace zoom rendering investigation

Date: 2026-08-17

Status: investigation record and decision framework. No rendering mechanism is
authorized or implemented by this document. The released native zoom path is
known to fail the real workspace; the next work begins with a faithful baseline,
not another optimization guess.

Read with `.plans/28`, `.plans/27`, and `.plans/24` for the previous evidence.

## The production failure is real

Dylan's released 0.5.0 workspace falls as low as roughly 1 FPS during zoom while
pan remains smooth. The prior release-confidence fixtures did not represent this
workspace. They were useful attribution probes, but they were not product
capacity tests.

The saved production layout corresponding to the supplied screenshot contains:

- four expanded zones plus one unzoned tile;
- 20 tiles total: 12 managed agents, 6 file tiles, 1 live browser, and 1 live
  terminal;
- zone tile counts of 5, 1, 11, and 2, plus the unzoned agent;
- approximately 14.1 million square world points of tile content;
- a packed overview around zoom 0.2 in which nearly the complete multi-zone
  working set is visible simultaneously.

This is the **minimum realistic fixture**, not a stress case. The intended
capacity remains 5–50+ mixed tiles and may include 15 agents, 5 browsers, and 5
terminals across several projects.

## Why pan and zoom diverge

Both inputs travel through the same display-paced `CanvasCameraDriver` and
`CanvasNSView.setViewport` funnel. The camera math is constant-time. The paths
diverge at `CanvasWorldPlaneView.applyCamera`:

- pan changes only `bounds.origin`, preserving the points-to-pixels ratio;
- zoom changes `bounds.size = viewportSize / zoom`, changing the effective
  scale of the ancestor containing every mounted tile view.

AppKit responds to the scale change by propagating backing-property changes
through the installed native hierarchy. That reaches nested scroll and clip
views, collection layouts, TextKit, stack views, constraints, intrinsic-size
queries, view drawing, layer display, and the Core Animation transaction.
Clipping reduces drawn pixels; it does not stop this descendant traversal.

The released presentation cost is therefore approximately:

```text
camera calculation                  O(1)
per-frame native zoom presentation  O(sum of mounted subtree complexity)
```

Agent-only data fits approximately `4.30 + 2.60 * mountedAgents` milliseconds
per zoom step (`R² = .998`) for the six-turn synthetic fixture. That predicts
about 20 FPS for 18 comparable agent trees, not the observed 1 FPS. The remaining
gap is important and unmeasured: deeper production transcripts, six file
`NSTextView`/`NSScrollView` trees, four simultaneous live zones, WKWebView,
Ghostty, live churn, long-running state, and WindowServer/GPU work. None may be
declared dominant until the real-layout profile apportions them.

## Why the old benchmarks gave false confidence

- `canvas.stress` creates many real agents but drives **pan**, not zoom, and does
  not pump a real display/Core Animation transaction.
- `canvas.raster` pumps display and Core Animation but uses twelve cheap
  descriptor tiles rather than real product subtrees.
- `canvas.zoom` uses three Markdown and nine note tiles and is structurally
  unrelated to the production workspace.
- `canvas.geometry-hold-probe` proves the bounds-size cascade with one zone and
  ten homogeneous six-turn agents. It is an attribution witness, not a capacity
  test.
- `canvas.proxy-scene-probe` proves one owned affine is cheap through fifty image
  layers, but its synthetic shell visuals were correctly rejected.
- No standing fixture combines multiple zones, real agent transcript shapes,
  file tiles, live WKWebViews, real Ghostty surfaces, very low overview zoom,
  streaming content, a real display pump, and Release configuration.
- The HUD reports the symptom. It does not identify whether the delay belongs to
  AppKit layout, drawing, WebContent, Ghostty, Core Animation, WindowServer, GPU,
  memory pressure, or another process.

## What high-performance canvases actually do

The consistent pattern across Figma, tldraw, Blender, Houdini, and Apple's Core
Animation model is that camera motion operates on renderer-owned presentation
state, not by repeatedly scaling a deep semantic UI hierarchy.

### Figma

Figma explicitly found HTML/SVG unsuitable for its canvas because DOM access has
substantial baggage, those systems are optimized for scrolling rather than
zooming, and geometry can be re-tessellated after each scale change. It built a
tile-based retained GPU renderer with its own scene/document model, compositor,
text layout, and render tree. Its newer WebGPU backend batches resource uploads
and draw submission. Its performance program uses end-to-end tests with real
GPUs, real hardware classes, stress documents, profiles, and production rollout
telemetry.

Figma also demonstrates the cost of renderer ownership: because the canvas does
not use the browser DOM for presentation, Figma had to build a synchronized
accessibility mirror.

### tldraw

tldraw remains DOM/React-based, but its shapes are much lighter than Array's
mini-application tiles. It maintains a spatial index, removes offscreen shapes
from rendering, uses fine-grained reactive updates, caches geometry, buckets
image resolution, and deliberately freezes zoom-dependent values during camera
motion before catching them up at settle.

### Blender and Houdini

Their interactive viewports use renderer-owned GPU data, caching, batching,
culling, instancing, explicit resolution/detail budgets, and interaction modes.
They do not attempt to preserve an unlimited hierarchy of native widgets at full
evaluation cost during navigation.

### Consequence for Array

Array's current design is structurally opposite: the camera changes the scale of
the semantic/native view hierarchy itself. The likely destination separates the
semantic world, presentation snapshots/display lists, renderer-owned camera
transform, and a bounded set of live native interaction islands.

## “Full detail” is four contracts

Do not collapse these into one phrase:

1. **Pixel completeness:** every currently visible glyph, image, control, browser
   pixel, terminal pixel, zone, status, and chrome element is present.
2. **Resolution fidelity:** those pixels have enough resolution for the current
   and anticipated zoom, without obvious softness.
3. **Temporal freshness:** streaming tokens, terminal cursor/output, browser
   animation/video/WebGL, indicators, and selection continue updating during the
   gesture.
4. **Interaction and accessibility:** hit testing, selection, focus, IME,
   drag/drop, menus, and accessibility geometry remain live during the gesture.

An exact frozen raster can satisfy the first two while failing the latter two.
That is categorically different from the rejected synthetic shell, but it still
requires an explicit product ruling and evidence.

There is an additional fidelity trap: tile title bars and close controls use
screen-space floors that change in quantized zoom buckets. A single whole-tile
image transformed with the camera would scale that chrome instead of retaining
its current screen-space behavior. A faithful compositor likely separates body
pixels from Array-rendered chrome, or uses independently bucketed chrome
presentation.

## Surface facts by tile family

### Array/AppKit content

Managed agents, source/file views, Markdown, diff, file tree, queue tiles, notes,
and Array chrome are candidates for `cacheDisplay` or direct renderer-owned
display lists. They still require pixel comparisons for CALayer animations,
attachments, caret/selection, scrollers, partial visibility, appearance, and
different backing scales.

The transcript collection already virtualizes rows, so historical turn count is
not identical to resident NSView count. The mounted agent tile nevertheless has
a deep outer tree and receives the ancestor backing/layout propagation on every
zoom frame.

### WKWebView

Generic AppKit `cacheDisplay` does not reliably composite the remote/GPU web
surface. The supported source is asynchronous `WKWebView.takeSnapshot` with an
explicit rect, target width, and `afterScreenUpdates` policy. Static content may
be captured exactly; video, WebGL, canvas animation, fixed content, selection,
latency, and revision freshness need direct tests. Browser chrome is separate.

The existing browser snapshot tier is not evidence of a solution: its default
snapshot is an 80x60 placeholder with a caption.

### Ghostty

Ghostty renders into a custom IOSurface-backed layer and triple-buffers three
IOSurfaces. Upstream Ghostty itself uses `bitmapImageRepForCachingDisplay` plus
`cacheDisplay` for a drag image, so exact terminal capture is testable rather
than assumed impossible.

A stronger supported integration may require a Ghostty API that acquires a
stable current IOSurface or copies/blits it into Array-owned storage. Merely
retaining `layer.contents` may remain live or be overwritten as the triple buffer
is reused. Never scrape or reparent Ghostty's backing layer as a production
shortcut.

Read-only source inspection also found a likely independent bug: Array appears
to forward `setSnapshotOccluded(true)` into a Ghostty API whose Boolean is named
and implemented as `visible`, reversing dehydration/rehydration throttling. This
needs an isolated red witness before any correction.

## Candidate architectures

### 1. Incremental AppKit backing reuse

Apply supported redraw policies such as `.onSetNeedsDisplay` to carefully scoped
Array-owned views so AppKit stretches cached backing during a brief scale change,
then redraw once at settle.

This is the smallest experiment and preserves native semantics, but it may only
remove drawing while leaving backing propagation, scroll tiling, intrinsic size,
and Auto Layout above budget. It is a coefficient reduction, not yet a new
scaling law.

### 2. Strategic native flattening

Replace deep managed-agent/file presentation subtrees with a small number of
custom-drawn, virtualized surfaces while keeping native editors/controls for
active interaction. This reduces the AppKit descendant multiplier and improves
resting memory and the final bake. It can migrate one tile family at a time.

It remains proportional to the number of visible native surfaces, which is
acceptable if fifty shallow surfaces remain inside the frame budget.

### 3. Full-detail Core Animation compositor

Keep semantic/native views authoritative but hold their geometry during camera
motion. Present exact, resolution-bucketed Array-owned image surfaces under one
root camera affine. This is the closest route to pan-like motion: the existing
synthetic probe already measured the root affine at roughly 0.02–0.05 ms through
fifty layers.

The difficult work is not composition. It is producing exact current pixels,
bounding memory and coverage, separating zoom-stable chrome, handling freshness,
and transitioning interaction/accessibility safely.

### 4. Hybrid compositor with bounded native islands

Present most content through exact surfaces; keep only focused, editing,
first-responder, IME, drag/modal, accessibility-active, or necessarily live
browser/terminal tiles as screen-space native islands outside any scale-changing
ancestor. Hit testing uses the semantic scene and promotes a tile before native
dispatch when required.

This is the strongest likely end-state, but it requires first-class separation
of semantic activity, runtime residency, visual residency, and interaction
pinning. Today `ManagedAgentTileNSView.detach()` cancels its subscription and
several presentation states live inside view objects, so views are not yet safely
disposable.

### 5. Metal compositor

Metal provides explicit textures, batching, atlases, dirty-region uploads, and
one camera uniform. It does **not** acquire WebKit/Ghostty pixels, extract state
from NSViews, implement text layout, preserve IME/focus/selection/drag/drop, or
create accessibility semantics.

Core Animation has already demonstrated sub-budget composition for fifty image
layers. Metal should be compared against the same exact texture scene only after
native traversal is removed. Replacing a 0.05 ms stage cannot recover a 30–1000
ms AppKit frame.

### 6. Full content renderer rewrite

A Figma-like renderer would own a retained scene graph, invalidation domains,
text shaping/layout and glyph caches, clipping/scrolling, selection, links,
hover, controls, hit testing, focus/IME bridges, drag/drop, menus, and an
accessibility mirror. WKWebView and Ghostty would still require native islands or
supported shared-surface integrations.

The safe rewrite boundary is presentation, not the semantic/runtime core.
`CanvasState`, tile/zone geometry, `CanvasEngine`, `AgentDocument`, supervisor and
runtime records, drafts, browser state, and terminal processes are largely
reusable. Extract immutable revisioned `TileRenderSnapshot`s and presentation
state first, then run old and new renderers behind the same semantic actions.

A flag-day rewrite is the highest-risk path. The decisive prototype is one
production-faithful custom managed-agent tile—including mixed transcript rows,
streaming, selection, links, composer, appearance, Retina sharpness, and
accessibility—measured at 5/15/30/50 equivalents. If that cannot preserve behavior
and outperform a flattened native tile, a whole-canvas rewrite will not rescue it.

## The benchmark that must exist before architecture selection

### Production census/export

Add an explicit, privacy-safe, user-triggered export that records no transcript,
browser, terminal, or file contents. It should contain:

- zone placement and dimensions;
- tile kind, frame, concrete installed view class, live/snapshot state;
- transcript block-type counts and materialized row counts;
- per-tile NSView/layer/constraint count and maximum subtree depth;
- viewport, window, display/backing scale/cadence, build configuration;
- runtime activity and presentation revision counts.

Copy the sanitized manifest into isolated QA support; never point a development
fixture at production state.

### Required fixture cells

1. Exact screenshot baseline: 4 zones, 20 tiles, 12 agents / 6 files / 1 browser /
   1 terminal, packed overview near zoom 0.2.
2. Capacity matrix:

   | total | agents | browsers | terminals |
   |---:|---:|---:|---:|
   | 5 | 3 | 1 | 1 |
   | 15 | 9 | 3 | 3 |
   | 25 | 15 | 5 | 5 |
   | 50 | 30 | 10 | 10 |

   Add file/note surfaces as separately reported ancillary load.
3. Placements: packed/fit, fixed 5 or 12 visible with the rest offscreen but
   installed, 4-zone screenshot topology, and scaled 6/10-zone topology.
4. Zooms: 1.0, 0.35, and approximately 0.10–0.20 overview; center and corner
   anchors; zoom-in/out; pinch-to-pan; glide; settle.
5. Content: light/medium/heavy real-shaped transcripts; static and animated
   local WK pages; real isolated Ghostty output; source and Markdown files.
6. Phases: cold restore, first frame, warm idle, quiescent gesture, and live
   churn at 25/50 with streaming agents, terminal output, and animated web.
7. Run deterministic display-paced gestures and separately capture real trackpad
   tripwire profiles. Tight synchronous loops remain mechanism probes, not FPS
   evidence.

### Per-trial evidence

- raw frame intervals, observed cadence, time-weighted FPS, p50/p95/p99/worst,
  missed-vsync severity, and active/settle separation;
- camera input events and presented commits;
- apply/layout/display/CA-flush signposts;
- bounds-size/origin writes, backing notifications, layouts, transcript prepares,
  actual draws, chrome work, provider updates;
- installed, visible, materialized, and live-runtime counts per class;
- app/WebContent/GPU/WindowServer CPU, GPU time, memory high-water, allocations,
  energy/wakeups;
- anchor, blank-pixel, viewport, screen-frame, hit, focus, and accessibility
  correctness;
- git SHA, Release/Debug, OS/hardware/RAM, screen size/Hz/scale, power/thermal,
  fixture hash/seed, and individual trial artifact.

Use warmup, matched ABBA arms, at least five observations, raw per-run
distributions, and paired pan on the exact same fixture. Profile only after
counters prove the intended path ran. Run capacity conclusions in Release on
real target hardware; Debug remains a structural gate.

## Decision gates

1. Reproduce the 1 FPS production shape with the isolated 20-tile fixture.
2. Apportion the frame among AppKit layout/backing, drawing, WebKit, Ghostty, CA,
   WindowServer/GPU, and memory pressure.
3. Run the narrow redraw-policy A/B. Stop treating it as a solution if native
   traversal remains over budget.
4. Prove AppKit, WKWebView, and Ghostty exact pixel sources independently.
5. Decide whether exact-but-frozen gesture pixels satisfy the product contract,
   or temporal freshness is mandatory for some/all tile families.
6. Compare Core Animation and Metal using the **same** exact source surfaces.
7. Measure 0/1/2/5 live native islands by family.
8. Prototype a production-faithful flattened/custom agent tile.
9. Choose the smallest architecture that meets the real 20-tile baseline and the
   mixed 50-tile capacity gate without losing pixels, correctness, or input.

The current architecture bet—not a decision—is a hybrid exact-surface
compositor plus bounded native islands and strategic custom flattening of
Array-owned heavy tiles. Metal is conditional on Core Animation becoming the
next measured bottleneck. A full content renderer remains a staged option, not a
flag-day rewrite.

## Primary references

- Figma, “Building a professional design tool on the web”:
  https://www.figma.com/blog/building-a-professional-design-tool-on-the-web/
- Figma, “Keeping Figma fast”:
  https://www.figma.com/blog/keeping-figma-fast/
- Figma, “Figma rendering: Powered by WebGPU”:
  https://www.figma.com/blog/figma-rendering-powered-by-webgpu/
- Figma, “Building accessibility into a canvas-based product”:
  https://www.figma.com/blog/building-accessibility-into-a-canvas-based-product/
- tldraw performance documentation:
  https://github.com/tldraw/tldraw/blob/main/apps/docs/content/sdk-features/performance.mdx
- Apple Core Animation Programming Guide, performance and layer setup:
  https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/ImprovingAnimationPerformance/ImprovingAnimationPerformance.html
  https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/SettingUpLayerObjects/SettingUpLayerObjects.html
- SideFX Houdini viewport/display performance documentation:
  https://www.sidefx.com/docs/houdini/ref/windows/displayopts_3d

## Product correction: there is no tile-count limit

The product goal is not "support up to 50 tiles." The canvas must remain useful
as projects, zones, agents, browsers, terminals, files, and future surface types
continue to accumulate. The 5/15/25/50 matrix is a measurement ladder, not a
product cap.

Similarly, a bounded set of mounted native `NSView` trees is an implementation
technique, not a limit on visible or semantic tiles. An unbounded semantic scene
may contain and display arbitrarily many tiles through renderer-owned
presentation data while only the tiles that currently require native AppKit
interaction are materialized as native views.

The target should be stated precisely:

```text
semantic tile count             not product-limited
visible detailed tiles          constrained only by pixels/memory, not NSView count
camera-frame CPU work           independent of native subtree depth/count
camera-frame GPU work           bounded by viewport pixels, overdraw, and visible chunks
native interaction residency    demand-driven, never a user-visible tile limit
```

"O(1) zoom" is shorthand for an O(1)-feeling camera funnel: one owned camera
state change with no per-frame native layout, capture, TextKit, WebKit snapshot,
or terminal readback. It does not mean the GPU shades zero pixels or that a
spatial query has no dependence on visible presentation chunks.

## Nyx was added to the comparison set

Nyx is an Electron/React application whose agent and terminal tiles use
`xterm.js` plus `node-pty`, whose editor uses Monaco, and whose browser uses an
Electron `<webview>`. Its own changelog documents both local component fixes and
the structural camera boundary:

- a 20-plus-tile canvas used to re-render every tile when one tile was touched;
  it now updates only the touched tile;
- stable callbacks and memoized webview styles stopped unrelated parent renders
  from reattaching listeners/restyling the webview;
- terminal fitting tolerates plus/minus one cell so subpixel jitter does not
  reflow xterm;
- canvas motion removed whole-area repaints and temporally promotes tiles to the
  GPU during motion;
- at lower zoom, terminal pixels use a composited layer; at higher zoom, DOM
  rendering restores vector sharpness.

Source: https://getnyx.dev/changelog/

Nyx therefore does not prove that a deep semantic hierarchy can be cheaply
re-laid-out at every zoom step. It proves the same two-track strategy Array now
needs:

```text
stable/memoized tile content boundaries
                  +
renderer/compositor-owned camera motion
```

Chromium already owns retained raster tiles and can scale them on the compositor
while new resolution tiles raster asynchronously. Array must build an equivalent
supported ownership boundary rather than expecting AppKit's view hierarchy to
behave like Chromium's compositor.

Reference:
https://www.chromium.org/developers/design-documents/gpu-accelerated-compositing-in-chrome/

## Managed-agent tile deep audit

The earlier profile established managed agents as a strong multiplier, but it
did not decompose the tile. A new read-only audit found substantial exact-UI
coefficient work that should be removed even though it cannot change the native
bounds-stepping scaling law by itself.

### Fixed shell anatomy

Before transcript row hosts, one idle managed-agent tile source-installs roughly:

- 17 `NSStackView`s;
- 4 `NSScrollView`s (transcript, composer, image rail, file-reference rail);
- 2 `NSCollectionView`s;
- one composer `NSTextView`.

Fifteen agents therefore imply roughly 255 stacks, 60 scroll views, and 30
collection views before visible transcript TextKit/renderers. Fifty imply
roughly 850/200/100. These are source-derived counts and need a runtime census,
but they explain why one ancestor backing-scale callback fans out so widely.

### Ranked exact-UI findings

1. **Active gyro animation graph rebuild.** The production transcript-tail
   `DualPlaneGyroTiltedThinkingIndicatorView.layout()` removes and recreates its
   animations whenever it is active. Each rebuild creates 12 keyframe
   animations (three nodes times position/scale/opacity/z) with 145 values each,
   about 1,740 sampled values per active agent per layout. Zoom forces those
   layouts. The quiescent synthetic fixture did not represent many simultaneously
   working agents, so this is a plausible production-only amplifier and must be
   the first narrow A/B. Preserve the exact animation; rebuild only if local
   bounds or motion mode actually changes.
2. **Composer TextKit identity work.** `AgentComposerView.layout()` always calls
   `ComposerHeightController`, which calls `ensureLayout`, updates scroller
   state, sizes the text view, and scrolls the selection into view even when
   width/text/font/selection are unchanged. Cache by width bucket plus
   content/font revision; selection scrolling belongs to a selection/content
   change, not an ancestor zoom layout.
3. **Eager hidden attachment trees.** Empty composers still instantiate and
   install the image rail (`NSScrollView` + `NSCollectionView`) and file rail
   (`NSScrollView` + `NSStackView`). Lazily mount them only while they contain
   content.
4. **Hidden legacy location/status composition.** A multi-stack
   `AgentLocationStatusView` remains hidden inside every production tile solely
   for appearance census coverage. Remove it from production composition and
   instantiate it independently in the probe.
5. **Image backing callback churn.** `AgentImageCellView` treats every ancestor
   `viewDidChangeBackingProperties` as a real display-scale change: it cancels
   the request, clears the exact image, and relayouts. Its key uses the unchanged
   `window.backingScaleFactor`. Guard on the actual key/scale.
6. **Forced live transcript traversal.** `AgentTranscriptListView.layout()`
   calls `collectionView.layoutSubtreeIfNeeded()` twice and explicitly prepares
   and reframes visible items. The comments justify this for offscreen
   baselines/Component Lab, but it also runs in live windows. Split the offscreen
   materialization path from the normal display path.
7. **Identical child frame writes.** Most block renderers unconditionally assign
   child frames and several then force nested layout. `AssistantProseView`
   already guards unchanged `NSTextView` frames because they trigger a glyph
   bounds pass. Apply the same measured discipline across code, command output,
   user prompt, reasoning, plan/diff/approval/error/image, header, and composer.
8. **Collapsed bodies remain expensive.** Collapsed command output retains its
   `NSScrollView`/`NSTextView`. Expanded-once then collapsed reasoning can still
   measure/frame/force-layout hidden body hosts. Detach/rebuild or skip the body
   entirely while collapsed.
9. **Visible-range query scans total history.** `AgentTranscriptLayout` stores
   monotonic attributes but `layoutAttributesForElements(in:)` filters the whole
   array. Use binary search/range lookup so retiling scales with visible rows,
   not full transcript history.
10. **Streaming overlaps camera priority.** Every list has a 30 Hz presentation
    timer. During a few-second camera gesture, semantic ingestion can continue
    while native visual application coalesces to the newest revision. This must
    be a presentation-priority policy, never event loss.
11. **Fixed chrome is over-composed.** Header/status/composer/footer contain many
    nested stacks and constraints. Manual layout/custom-drawn static chrome can
    preserve exact pixels and accessibility while reducing final-bake, capture,
    idle, and promoted-island cost.

These fixes help active zoom, resting CPU/memory, streaming, exact-surface
production, native promotion latency, and any final native bake. They are worth
doing. They cannot make per-frame `worldPlane.bounds.size` mutation independent
of mounted native descendants.

Key source anchors:

- `Sources/ContinuumRevived/Canvas/AgentActivity/ThrobberCandidates/TiltedVariations/DualPlaneGyroTiltedThinkingIndicatorView.swift`
- `Sources/ContinuumRevived/Canvas/AgentComposer/ComposerHeightController.swift`
- `Sources/ContinuumRevived/Canvas/AgentComposer/AgentComposerView.swift`
- `Sources/ContinuumRevived/Canvas/AgentTranscript/AgentTranscriptListView.swift`
- `Sources/ContinuumRevived/Canvas/AgentTranscript/AgentTranscriptLayout.swift`
- `Sources/ContinuumRevived/Canvas/AgentTranscript/Renderers/ImageRenderer.swift`
- `Sources/ContinuumRevived/Canvas/ManagedAgentTileNSView.swift`

## Non-agent production areas remain open

The old 8,963-sample pinch did not contain file-tile, WKWebView, or Ghostty
symbols. It cannot apportion the saved 20-tile workspace's 1 FPS result.

### File tiles

A Source tile is a relatively shallow `NSScrollView`/`NSTextView`. A Markdown
Preview can mount up to 400 semantic block views, each with its own renderer and
TextKit structure. One substantial Preview may outweigh several Source tiles.
The production census must record Source/Preview mode, block count, mounted
descendants, and file size instead of treating all six files as one family.

### Ghostty

`GhosttyTerminalView.viewDidChangeBackingProperties()` unconditionally calls
`ghostty_surface_set_content_scale` with the unchanged window backing scale,
then requests surface-size reconciliation. The size application is guarded; the
content-scale call is not. Build a same-scale no-op A/B and count Ghostty draw
and present activity.

Upstream Ghostty uses AppKit view caching for a drag image and renders into a
triple-buffered IOSurface-backed Metal layer. Exact capture is therefore
testable. Truly live compositor pixels need an explicit supported completed
frame lease/copy API; retaining or reparenting an internal layer/IOSurface is not
a production contract.

The suspected Array occlusion-Boolean inversion needs a deterministic red
witness before correction.

### WKWebView

The browser shell contains ordinary AppKit chrome plus a remote live WKWebView.
The unknown cost may reside in WebContent, the GPU process, or WindowServer and
will not appear in an Array-only profile. `takeSnapshot` is the public
point-in-time source; live video/WebGL/canvas/selection fidelity and concurrency
need current-platform tests. There is no documented continuous WebKit texture
stream.

### Zone chrome and canvas loops

Four large translucent zone surfaces may add raster/blending/overdraw, though
the earlier homogeneous profile suggests direct zone drawing is secondary.
`visibleTileViews` still scans installed world-plane children every camera
commit. Twenty to fifty rectangle tests are unlikely to explain one-second
frames, but a renderer-owned future must use a spatial index and immutable
gesture presentation set rather than accidentally retaining O(all tiles) scans,
z-order rebuilds, cache checks, chrome updates, or accessibility updates.

## Expanded architecture space

No architecture below is a decision yet. The next architect should remain free
to combine or replace them as evidence develops.

### A. Radically optimized native tiles

Flatten stacks/constraints, remove dormant descendants, guard identity work,
use viewport-oriented TextKit 2/custom drawing, and simplify static row
presentation. This can dramatically reduce idle, streaming, native promotion,
capture, and settle cost. It is allowed to win outright if the faithful Release
50-plus fixture unexpectedly meets the camera gates. It is not assumed to do
so.

### B. Gesture-only exact surface compositor

Maintain exact detailed surfaces while idle; during pinch/glide hold native
geometry and transform one Array-owned Core Animation root. At settle, bake the
native world once behind the surfaces and atomically reveal it. This is the
smallest supported camera-boundary proof. Its known weakness is the all-native
settle cliff.

### C. Permanent exact surface scene plus native interaction plane

Keep renderer-owned presentation authoritative both during and after camera
motion. Every semantic tile remains visible through complete resolution-paged
surfaces. Native views are demand-materialized for focus, scrolling, selection,
IME, drag/drop, modal, or accessibility interaction. This removes the global
settle bake and makes native residency an implementation cache, never a tile
limit.

Start by parking retained whole views off-window so local state survives. True
demounting comes only after projection/viewport/disclosure/browser/terminal
state moves into view-independent sessions. `ManagedAgentTileNSView.detach()`
is not a residency seam: it cancels subscription and supervisor replay is
capped at 500 events.

### D. Renderer-neutral scene and strategic custom tile renderer

Extract immutable revisioned `TileRenderSnapshot`s/display lists from semantic
state. Keep the current native backend as the fidelity oracle. Build a shallow
TextKit 2/Core Graphics backend for Array-owned agent/file/read surfaces, while
native editors/controls are promoted as interaction overlays. This removes
capture dependency and deep AppKit residency without rewriting supervisor,
documents, persistence, camera geometry, browser sessions, or PTYs.

Candidate seam:

```text
AgentDocument + PresentationState
        -> TileRenderSnapshot
        -> {NativeBackend | TextKit/CGBackend}
        -> {CoreAnimationScene | optional MetalScene}
```

### E. Metal compositor or full retained renderer

Metal image composition is a contained backend option if Core Animation is
measured to fail with the same prebuilt exact surfaces. A full Metal renderer is
a much larger Figma-class project: scene graph, display lists, text/glyph/image
resources, clipping/scrolling, hit regions, selection, native editor islands,
drag/drop, menus, and accessibility mirror. It remains a legitimate ambitious
direction, not a forbidden one, but it must be staged behind renderer-neutral
semantic snapshots so Array can run native and new backends side by side.

Metal does not by itself acquire WKWebView/Ghostty pixels or preserve
IME/accessibility. Conversely, Core Animation moving 50 image layers at
0.02-0.05 ms suggests composition may already be cheap enough. Compare them
only with identical immutable source surfaces.

### F. Spatial chunks, clipmaps, and unlimited worlds

Do not build a giant workspace bitmap. Use a spatial scene index plus bounded
screen-demand presentation:

- complete low-resolution overview coverage;
- viewport/overscan chunks at the current and adjacent resolution buckets;
- geometric resolution hysteresis and direction-aware prefetch;
- dirty-region/page replacement rather than whole-world recapture;
- pinned last-complete parents so cache misses become temporary softness, never
  holes or shells;
- byte-accounted CPU/GPU/transient working sets;
- incremental z-order and dirty queues;
- no scan of every semantic tile on a camera tick.

This is how the architecture supports unlimited semantic tiles: presentation
work is driven by viewport pixels and spatial demand, not total tile count.

## Surface memory and fidelity model

Surface density in physical pixels per world point should follow the current
screen demand, not maximum possible zoom. For the saved approximately 14.1M
world-square-point layout:

- a single full 2x RGBA copy is approximately 225 MB raw;
- overview demand around zoom 0.2 is approximately 9 MB raw;
- replacements, mip levels, CPU/GPU duplication, effects, and native runtime
  buffers multiply those values.

Therefore cache entire low-resolution overview parents and page high-resolution
regions near the viewport. Never allocate maximum-zoom whole-tile textures for
all tiles.

"Full detail" remains four distinct contracts: pixel completeness, current
resolution, temporal freshness, and native interaction/accessibility. The user
requires all visual content to remain present; brief camera-motion freezing was
discussed as potentially acceptable because zoom lasts seconds, but it is not a
blanket approval for missing detail or permanently stale tiles.

Tile body and chrome likely need separate representation because current
title/close/status chrome has screen-space floors and discrete zoom buckets.
Independent tile captures also require effect padding and careful treatment of
shadows, transparency, vibrancy, overlaps, fractional pixels, color space, and
appearance/backing changes.

## Interaction and accessibility findings

A permanent surface scene needs a tested native-island state machine:

```text
surface
  -> prewarming/promoting (surface remains visible)
  -> native interactive (pin reasons own residency)
  -> demoting capture (native remains visible)
  -> surface
```

The first transcript wheel/click must promote before normal AppKit dispatch and
deliver the original event exactly once. Camera stickiness keeps pinch
follow-through as camera input; the first ordinary wheel after the session
scrolls the transcript. Do not synthesize broad raw events unless a narrow
exactly-once witness proves it.

Pin reasons include first responder, marked text, pointer/selection tracking,
native drag/drop, browser/terminal responder, accessibility focus, modal, menu,
and popover ownership. Native views should initially be parked, not destroyed.

Overlapping native/surface z-order is nontrivial. A simple single surface host
behind arbitrary native islands is wrong because a lower-z promoted tile can
paint above a higher-z surface. Explore one frontmost ordinary island, surface
z-bands/replicas around islands, masks, or a renderer-native interaction model.
Do not silently change z-order on transcript scroll merely to avoid the problem.

Pixels provide no automatic accessibility. A permanent renderer requires stable
semantic `NSAccessibilityElement` proxies/mirror geometry or must keep native
presentation at rest and treat assistive interaction as an immediate camera
settle barrier. This is the same class of renderer ownership cost Figma paid.

## Adversarial risks and alternate branches

The favored hybrid remains only a hypothesis. It fails if any of these cannot be
resolved:

- exact surface production runs on the camera critical path;
- continuous streaming causes capture starvation/backlog;
- browser/terminal accelerated pixels cannot be obtained under the required
  freshness contract;
- memory multiplies through full-resolution copies and transient replacements;
- a smooth gesture ends in a 100-1000 ms global native settle bake;
- native islands cannot preserve first event, selection, IME, drag/drop,
  popovers, arbitrary overlap, or accessibility;
- hidden O(all tiles) cache/visibility/z/AX work returns to every camera tick;
- the app main thread remains starved by streaming, capture, native layout, or
  remote callbacks even though the root affine itself is cheap;
- CA/WindowServer/GPU fill rate, masks, transparency, shadows, or uploads become
  the next bottleneck;
- cold cache, display-scale/appearance transition, rapid zoom reversal, or
  memory pressure exposes holes.

Alternate branches remain open:

- custom TextKit 2/CoreText rendering for Array-owned tiles if AppKit capture is
  the producer bottleneck;
- explicit upstream Ghostty frame lease/copy API;
- bounded-cadence WK snapshots or a product-approved native-browser policy;
- Metal image compositor if identical-surface CA composition fails;
- full retained renderer if renderer ownership is justified;
- strategic native flattening if a persistent surface model fails interaction
  or accessibility gates.

## Research coverage and where to dive deeper

The latest research was deliberately split across eight questions:

1. managed-agent transcript/layout hot paths;
2. managed-agent shell/composer/status hierarchy;
3. AppKit/Core Animation redraw/rasterization limitations;
4. non-agent saved-workspace contributors;
5. exact full-detail surface acquisition/cache design;
6. offscreen/native residency and state ownership;
7. custom renderer/Core Animation/Metal escalation boundaries;
8. interaction, IME, drag/drop, overlap, accessibility, and adversarial failure
   modes.

The most valuable deeper dives are now:

1. faithful Release reproduction of the saved 20-tile failure with synchronized
   Array/WebContent/GPU/WindowServer evidence;
2. active-gyro/composer/image/hidden-tree agent A/Bs;
3. Source versus 400-block Markdown Preview family slope;
4. Ghostty same-scale callback and exact-frame-source witness;
5. WK static/animated/video/WebGL snapshot fidelity and latency;
6. exact AppKit tile capture latency/fidelity under streaming and selection;
7. overview clipmap/resolution/memory simulation on the saved world geometry;
8. prebuilt exact-surface CA scene on 20/50/100/500 presentation chunks;
9. permanent-compositor promotion/IME/overlap/AX prototype;
10. production-faithful TextKit 2/custom managed-agent tile backend;
11. same-texture Core Animation versus Metal comparison only if CA misses;
12. long-soak cold-cache/memory-pressure/live-churn testing.

No implementation was made during this research. The purpose is to preserve the
full design space and give the next architect evidence, seams, and explicit
unknowns rather than a predetermined narrow answer.

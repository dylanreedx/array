# Infinite-canvas rendering research

Research pass: 2026-08-14. Sources are primary engineering documentation from
Figma, tldraw, Chromium, Apple, Mapbox, and game engines, plus Array's current
source. This is an architecture option set, not authorization to implement it.

## Outcome

Figma does not demonstrate that an indefinitely large native view hierarchy can
be fast. Figma bypassed the browser's ordinary DOM/SVG rendering path and built a
retained, tile-based GPU renderer with its own scene graph, compositor, and text
layout. That is evidence that custom rendering can raise the ceiling; it is not
evidence that Array should begin with a Metal rewrite.

The nearer-term model for Array is a hybrid used by infinite canvases and games:

- one retained camera mutation;
- a durable semantic world model independent of installed views;
- a bounded, spatially selected presentation working set;
- incremental dirty domains and batched updates;
- discrete level of detail (LOD) with hysteresis;
- cheap summaries or aggregate impostors at overview scale;
- native interactive views only where their behavior is useful;
- an evidence-triggered custom overview renderer if AppKit remains the measured
  bottleneck.

The architecture should make total saved tile count mostly irrelevant to a
camera gesture. It cannot make visible pixels, live WebKit/Ghostty surfaces, or
memory literally constant.

## What mature systems actually do

### Figma: own the render tree, load dependencies on demand

Figma's original renderer is not a large collection of HTML controls. Its team
describes HTML/SVG as optimized for scrolling rather than zooming and 2D canvas
as immediate-mode; Figma built a retained tile-based WebGL engine and its own
DOM/compositor/text layout instead. See [Building a professional design tool on
the web](https://www.figma.com/blog/building-a-professional-design-tool-on-the-web/).

Later Figma work supplies more transferable techniques:

- [Keeping Figma fast](https://www.figma.com/blog/keeping-figma-fast/) describes
  realistic end-to-end scenarios, baseline comparison, older physical machines,
  and time-slicing work so local interaction wins over remote rendering. Some
  plausible optimizations helped new machines but harmed weaker ones.
- [Dynamic page loading](https://www.figma.com/blog/speeding-up-file-load-times-one-page-at-a-time/)
  loads the selected page plus explicit dependencies, defers derivable sublayers,
  and shadow-validates the dependency planner before relying on it. Figma reports
  70% fewer client nodes in memory and 33% fewer users hitting out-of-memory.
- [Incremental frame loading](https://www.figma.com/blog/incremental-frame-loading/)
  chunks background work and skips rendering metadata for content that is not
  shown. Background work can still lock a single UI thread if completions are not
  budgeted.
- [Improving the layers panel](https://www.figma.com/blog/improving-performance-in-the-layers-panel/)
  separates a cheap ordered-ID pass from expensive data computed only for the
  visible rows. Lazy derived properties invalidate affected subtrees, and a
  rope-like structurally shared representation avoids an O(n²) cache.
- [Figma's WebGPU renderer](https://www.figma.com/blog/figma-rendering-powered-by-webgpu/)
  batches uploads and render passes, caches reusable GPU bindings, benchmarks by
  device class, and retains a fallback. Moving to a lower-level API alone was not
  assumed to be a win.

Array's transcript update path resembles the old layers-panel failure: it has
view virtualization but still reconstructs and scans complete derived data.
Array's restore resembles the old eager file load: it materializes content the
user may not visit before producing the first frame.

### tldraw: bound the working set and stabilize zoom

tldraw's [performance architecture](https://tldraw.dev/sdk-features/performance)
documents spatial-index viewport culling, dependency-granular reactive updates,
batched store changes, cached geometry, a stable/debounced effective zoom during
camera motion, discrete visual LOD, stepped image resolution, and interaction
p95 telemetry. Its [culling policy](https://tldraw.dev/sdk-features/culling)
keeps document state while excluding most offscreen presentation and protects
selected/editing shapes.

The policies transfer; the exact browser mechanism does not. tldraw can set
offscreen DOM to `display: none`. Array must not blindly use `isHidden`, which can
affect first responder, accessibility, animations, and heavyweight surfaces.
Array needs explicit presentation residency and pins.

### Maps and games: chunks, HLOD, and separate update costs

Mapbox publishes an explicit model in which render cost is a constant plus
per-source, per-layer, and per-vertex work. Its [performance guidance](https://docs.mapbox.com/help/troubleshooting/mapbox-gl-js-performance/)
uses vector tiles to load only visible features, simplifies geometry by zoom,
groups compatible layers, and changes feature state without reparsing geometry.
This is the same separation Array needs between camera, geometry, content,
status, and interaction changes.

Game engines add the answer for zoomed-out canvases where viewport culling stops
helping:

- [Godot visibility ranges](https://docs.godotengine.org/en/stable/tutorials/3d/visibility_ranges.html)
  replace groups of detailed objects with an aggregate HLOD representation and
  use hysteresis to prevent threshold oscillation.
- [Unity Tilemap Renderer](https://docs.unity3d.com/2021.3/Documentation/Manual/class-TilemapRenderer.html)
  batches by spatial chunks with chunk-level culling.
- [Godot's GPU guidance](https://docs.godotengine.org/en/stable/tutorials/performance/gpu_optimization.html)
  warns that one giant batch sacrifices culling granularity. Array should prefer
  zone/coarse-world chunks over one workspace-sized overview layer.
- Apple's [SpriteKit node guidance](https://developer.apple.com/documentation/spritekit/maximizing-node-drawing-performance)
  says automatic offscreen culling still enumerates attached nodes; removing
  dormant nodes from the scene graph is fastest. Bounding drawing without
  bounding the presentation tree is insufficient.

An R-tree fits variable-sized world rectangles and originated partly for CAD,
but the [original R-tree paper](https://www2.eecs.berkeley.edu/Pubs/TechRpts/1983/205.html)
is a reason to prototype, not to add complexity prematurely. Compare the current
metadata scan, a simple spatial grid, and an R-tree under Array's real counts.

### Apple: use AppKit boundaries deliberately

Array's root canvas is layer-backed, which makes its descendants layer-backed.
Apple documents several constraints that shape the safe path:

- [`NSClipView`](https://developer.apple.com/documentation/appkit/nsclipview) and
  [`NSScrollView`](https://developer.apple.com/documentation/appkit/nsscrollview)
  provide a document-view boundary, clipping, bounds-origin scrolling, and
  magnification. They preserve AppKit coordinate conversion and hit testing
  better than mutating backing layers directly. Apple does not promise their
  work is O(1) in descendant count, so this remains a measured prototype.
- Apple says not to directly mutate geometry/transform properties of an
  AppKit-owned backing layer because the layer and view can desynchronize. See
  [Animating your content](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/CreatingBasicAnimations/CreatingBasicAnimations.html).
- [`clipsToBounds`](https://developer.apple.com/documentation/appkit/nsview/clipstobounds)
  should be explicit at the viewport boundary. Clipping reduces drawing but does
  not stop layout, timers, semantic work, or render-server traversal.
- AppKit's [`layerContentsRedrawPolicy`](https://developer.apple.com/documentation/appkit/nsview/layercontentsredrawpolicy-swift.property)
  deserves a narrow experiment. The default `.duringViewResize` recaches during
  geometry changes; `.onSetNeedsDisplay` can manipulate cached content during a
  pinch and redraw visible content once at settle. Temporary blur, native
  controls, WebKit, and Ghostty make recursive application unsafe.
- A view-bound [`CADisplayLink`](https://developer.apple.com/documentation/appkit/nsview/displaylink%28target%3Aselector%3A%29)
  exposes the real presentation cadence. Accumulate input continuously but
  submit at most the newest desired camera state per display interval; do not
  replay obsolete intermediate viewports or force a fixed 60 Hz tick.
- [`NSCollectionView`](https://developer.apple.com/documentation/appkit/nscollectionview)
  is Apple precedent for creating views on demand and recycling offscreen ones.
  It is not a ready-made two-dimensional canvas layout.
- [`CATiledLayer`](https://developer.apple.com/documentation/quartzcore/catiledlayer)
  can asynchronously cache multi-resolution static background, zone, or preview
  tiles. It is not a host for live controls, WKWebView, Ghostty, focus, or
  accessibility.
- [`NSAccessibilityElement`](https://developer.apple.com/documentation/appkit/nsaccessibilityelement-swift.class)
  can preserve lightweight semantic proxies for content without an NSView. A
  proxy must reveal/materialize the real tile while preserving VoiceOver focus.

Figma's custom canvas required a separately cached and surgically updated
[accessibility tree and mirror DOM](https://www.figma.com/blog/building-accessibility-into-a-canvas-based-product/).
That is an important cost of a full custom renderer, not a reason to omit
accessibility.

## Array's reusable seams and gaps

Array already has useful pieces:

- [`CanvasEngine`](../../Sources/ContinuumRevivedCore/CanvasEngine.swift) owns
  pure world/screen geometry.
- [`ReadabilityPolicy`](../../Sources/ContinuumRevivedCore/ReadabilityPolicy.swift)
  defines `overviewLabelOnly`, `readableSummary`, and `editableDetail` bands.
- [`HydrationTier`](../../Sources/ContinuumRevivedCore/WorkspaceDocument.swift)
  defines `live`, `snapshot`, and `cold`.
- [`ZoneHydrationOrchestrator`](../../Sources/ContinuumRevivedCore/ZoneHydrationOrchestrator.swift)
  already considers visibility, focus pinning, a preload margin, and a global
  live-zone budget.
- [`CanvasEntityIndex`](../../Sources/ContinuumRevivedCore/CanvasEntityIndex.swift)
  provides stable entity identity and world rectangles behind an API that could
  later hide a spatial accelerator.
- Browser snapshot tiles and Ghostty snapshot occlusion already demonstrate
  kind-specific resource demotion.
- `AgentSupervisor`, rather than `ManagedAgentTileNSView`, already owns agent
  semantics, which is the right direction for unmountable presentation.
- `FocusBroker` centralizes interaction ownership needed for residency pins.

The current seams are incomplete:

- Readability bands are not used by production tile rendering.
- Zone hydration applies mostly to browser replacement; agents, terminals, and
  other native tile trees remain installed.
- Hydration, runtime lifetime, presentation fidelity, and semantic activity are
  treated too much like one state.
- A logical `ZoneLayer` is not an AppKit container, transform, clipping, or
  batching boundary; tile views remain direct canvas children.
- Initial restore fully constructs saved tiles before the first window.
- `ManagedAgentTileNSView.detach()` cancels event delivery, so it cannot be used
  as presentation culling; reattachment only has capped supervisor history.
- Navigation and focus currently depend on concrete installed views. Unmounting
  requires a view-independent catalog and semantic focus/accessibility proxies.
- `CanvasEntityIndex` queries still scan/filter/sort all entities. Preserve the
  API, but accelerate only after counters show candidate scanning is material.

## Separate the state axes

Do not expand `live/snapshot/cold` until it means everything. A tile planner
should return four independent decisions:

| axis | examples |
|---|---|
| semantic activity | agent/session/process continues, pauses, or stops |
| resource residency | WKWebView, Ghostty surface, full AppKit tree, snapshot, descriptor |
| presentation LOD | overview label, readable summary, editable detail |
| interaction pin | focused, first responder, dragged, modal-owning, AX-active |

An offscreen working agent can remain semantically active while retaining only a
coalesced document patch and no animated presentation. A browser may be
snapshotted and unload WebKit. A terminal may keep tmux/process state while
Ghostty's surface is occluded. A focused tile remains full-detail regardless of
geometry.

The target architecture is:

```text
semantic world model + stable IDs
        │
        ├── dirty-domain versions and incremental patches
        ├── view-independent navigation / hit / accessibility catalog
        └── spatial working-set planner
                 │
                 ├── interactive AppKit islands (bounded + pinned)
                 ├── lightweight summary views / cached proxies
                 ├── zone or chunk overview renderer
                 └── dormant descriptors (no presentation tree)

fixed CanvasNSView viewport
        ├── clipped world document plane (one camera mutation)
        └── screen-space overlay plane
```

## Presentation tiers

### Editable detail

Use the complete native subtree for tiles whose on-screen size supports reliable
interaction, plus focus/drag/modal/accessibility pins. Transcript, composer,
terminal, browser, editing, and native accessibility remain available.

### Readable summary

Use a lightweight shell containing title, semantic status, attention/progress,
and perhaps the last useful line. Do not construct transcript collection views,
attachment rails, WebKit/Ghostty surfaces, image hydration, per-tile animations,
or elapsed timers.

### Overview / zone HLOD

At overview zoom, one zone/coarse-chunk representation replaces many tile
subtrees. Draw rectangles, labels, and status colors in a bounded pass. Keep
urgent status/attention in a small separately updated overlay so streaming does
not regenerate a large frozen bitmap.

### Cold

Retain model, identity, world geometry, navigation, status, and accessibility
metadata only. There is no installed presentation subtree.

Use hysteresis around every LOD/residency threshold. Hold effective LOD and
preview resolution stable during an active pinch, then refine once at settle.

The activation window should have an inner safe region and a larger preload
halo. Requery only after the viewport leaves the safe region. Size the halo in
screen space and bias it by camera velocity; a fixed world-unit margin becomes
too large or too small as zoom changes. Focused, selected, editing, dragged,
modal-owning, and AX-active tiles are unconditional pins.

## Dirty domains and caches

Use explicit versions instead of a general "tile changed" signal:

| domain | invalidates |
|---|---|
| geometry | spatial index, hit regions, navigation geometry |
| content | affected transcript/note/browser content |
| status | summary and overview badges |
| interaction | focus, hover, selection, drag overlays |
| presentation | the last applied representation and scale bucket |

A prose token must not invalidate geometry, spatial selection, z-order, or
unchanged chrome. A camera change must not imply content damage. A status badge
must not rebuild a transcript.

Preview caches should use `contentVersion × discreteScaleBucket`, be generated or
refined after settle, and be bounded by decoded bytes with an LRU. One large
Retina bitmap can cost tens of megabytes, so item-count budgets and blanket
rasterization are inadequate. Use `WKWebView.takeSnapshot` for browser content;
generic AppKit `cacheDisplay` cannot capture every heavyweight surface.

## Escalation ladder

Each rung has an exit test. Do not proceed merely because the next technology is
more sophisticated.

### L0 — establish render truth

Measure real pan/pinch in Release on the M2 Air with Animation Hitches and actual
display-link cadence. Separate input/layout/display/commit from render-server/GPU
time. Add dirty-domain, mounted-view, LOD-transition, candidate-query, attachment,
and memory-byte counters.

Exit when the bottleneck and scaling slope are reproducible.

### L1 — low-risk AppKit experiments

- Explicit viewport clipping.
- Submit the latest camera state once per display interval.
- Gate presentation-only timers and animations.
- Test `.onSetNeedsDisplay` during pinch with one crisp visible settle redraw.
- Preserve real patches and stop unrelated UI invalidation.

Keep only experiments that improve the weakest target hardware without breaking
focus, WebKit, Ghostty, or visual fidelity.

### L2 — retained camera plane

Create a fixed viewport, a clipped world document/clip view, and a sibling
screen-overlay plane. Keep authoritative world coordinates in `CanvasEngine` and
logical tile frames stable. A bounded/rebased AppKit document frame may be needed
for an effectively infinite world.

Exit only when camera geometry work is structurally flat as installed tiles grow
and hit testing, cursor rects, overlays, spawning, framing, and focus remain
correct. `NSScrollView` magnification is a prototype, not a performance promise.

### L3 — bounded presentation working set

Wire readability bands into real presentation, add spatially selected
visible/near/cold working sets, kind-specific resource policy, AX proxies, focus
pins, pooling/reuse, and one catch-up apply. Shadow-run the tiered planner against
eager behavior before enabling eviction.

Exit when mounted heavy views, active animations/timers, and live browser/terminal
surfaces remain bounded independently of total saved tiles, with no blank frames
or navigation/focus loss.

### L4 — overview aggregation

Render readable summaries and zone/coarse-chunk HLOD using custom AppKit drawing,
cached previews, or `CATiledLayer`. Keep interactive native islands above it.

Exit when zooming the entire workspace into view costs proportional to visible
zones/chunks rather than every tile and cache bytes remain within budget.

### L5 — hybrid GPU overview, only if evidence requires it

Use Metal/Core Animation for distant cards, connectors, zone chrome, and cached
textures while mounting native AppKit islands for visible/focused interactive
tiles. A full Figma-style renderer would also require custom text, selection,
input, focus, hit testing, accessibility, and embedded-surface integration.

Enter only if L0–L4 still miss the M2 Air target and profiles identify overview
drawing/render-server/GPU submission—not transcript semantics, WebKit memory, or
AppKit island commits—as the remaining bottleneck.

## Research-derived regression witnesses

Add these to [Scalability TDD](./scalability-tdd.md) as the corresponding seams
land:

- With fixed visible/pinned count, stored tiles can grow from 100 to 100,000
  without increasing mounted heavy view count.
- At overview zoom with every tile geometrically visible, full native subtrees
  are zero except explicit pins; work scales with visible zones/chunks.
- Camera jitter inside the safe halo performs no spatial query or mount churn.
- A high-velocity pan materializes before content enters the viewport and shows
  no blank frame.
- LOD threshold crossings cause one transition; hysteresis prevents flapping.
- During pinch, effective LOD and preview bucket remain stable and refine once at
  settle.
- N input events inside one display interval cause at most one camera commit and
  preserve the final desired viewport.
- A transcript-only delta causes zero geometry, spatial-index, culling, sort, or
  unrelated chrome work.
- An offscreen agent advances beyond the supervisor's replay cap with zero
  presentation work and exactly one catch-up apply; this is teeth against using
  `detach()` as culling.
- An initially cold zone can become live and remains navigable before mounting.
- Browser live count never transiently exceeds budget, including during restore.
- Terminal demotion occludes its surface without stopping its semantic process;
  reactivation restores focus and input.
- Unmounted tiles remain in navigation, z-order, selection, and accessibility
  metadata; focused and AX-active tiles never demote.
- Preview decoded bytes never exceed budget and return after eviction.
- Spatial-accelerator results match the brute-force oracle under randomized
  moves, resizes, deletes, overlaps, and z-order changes.
- Hybrid overview hit testing, backing-scale output, focus rings, labels, and AX
  semantics match the native oracle at every tier boundary.

## Techniques explicitly not adopted by default

- **Viewport culling alone:** fails when zoom-out makes every tile visible.
- **Blanket `isHidden`:** can break focus/accessibility and does not define
  heavyweight resource lifetime.
- **One giant batch:** saves submissions but destroys culling granularity.
- **Rasterize every live tile:** trades layout for large bitmap memory, blur, and
  constant invalidation from streaming/WebKit/terminal content.
- **Raw transforms on AppKit-owned backing layers:** unsupported synchronization
  boundary.
- **Recursive asynchronous drawing:** NSView hierarchy mutation and heavyweight
  controls remain main-thread work; custom drawing must be thread-safe.
- **A fixed 60 Hz camera tick:** adds latency and wastes ProMotion; pace to the
  actual display callback.
- **A full ECS rewrite:** dense metadata, stable IDs, dirty sets, and pure planners
  provide the relevant benefits without forcing AppKit objects into an ECS.
- **Dirty rectangles as the camera fix:** they reduce drawing, not per-tile
  layout/subtree traversal.
- **Metal as the plan:** it cannot fix WebKit process memory, semantic transcript
  scans, or live native island cost. It is the final overview-rendering fallback.

The guiding rule is simple: first bound how much presentation exists, then make
that presentation cheap, and only replace the rendering backend if measured
evidence says the bounded version still cannot meet the hardware target.

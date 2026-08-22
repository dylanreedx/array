# 32 — Unbounded canvas target architecture

Date: 2026-08-17

Status: architecture discussion draft. This document describes the system Array
is considering as its rendering destination. It deliberately excludes
implementation phases, ticket breakdowns, migration order, estimates, and
commit plans. Those belong in a separate implementation plan after the
architecture is understood and agreed.

Evidence record:
`.plans/31-unbounded-canvas-rendering-findings.md`.

## Purpose

Define an architecture in which:

- semantic tile count is not product-limited;
- every visible tile retains its real detailed content during camera motion;
- zoom feels like pan because camera motion does not relayout semantic native UI;
- content freshness, pixel resolution, native interaction, and accessibility
  are explicit independently controlled contracts;
- agent, file, browser, terminal, and future tile families may use different
  pixel-production mechanisms behind one scene contract;
- Array can progressively own more rendering without a flag-day rewrite;
- Core Animation and Metal remain interchangeable compositor backends rather
  than definitions of the product architecture.

## Non-goals of this document

This document does not decide:

- the first code change;
- branch or worktree organization;
- milestones, phases, tickets, or estimates;
- which current hotspot is fixed first;
- whether the final compositor is Core Animation or Metal;
- exact memory constants or refresh frequencies;
- whether every native tile family is eventually replaced;
- whether gesture-time pixels may be briefly frozen.

It defines the target concepts and the questions that must be answered before
implementation planning.

## Status vocabulary

- **Product contract** — behavior Array must preserve.
- **Evidence constraint** — boundary established by source, measurement, or
  platform contract.
- **Proposed target** — architectural direction being evaluated with Dylan.
- **Open decision** — unresolved choice that this walkthrough must settle.
- **Candidate mechanism** — illustrative way to satisfy a contract, not an
  implementation commitment.

## Glossary

- **Complete** — every real visible element is present; no summary, shell, or
  hole.
- **Exact surface** — complete pixels for declared revisions, resolution, color
  space, and coverage; not automatically current, interactive, or accessible.
- **Admitted coverage** — a viewport/transition envelope declared ready with
  complete real pixels.
- **Surface** — immutable completed pixels or a backend resource representing
  them.
- **Fragment** — independently dirty render-description or pixel-production unit.
- **Chunk/page** — spatial presentation unit that may aggregate semantic objects.
- **Overview parent** — lower-resolution complete coverage for an admitted
  region, retained while sharper children are prepared.
- **Native island/aperture** — native interactive presentation composited with
  the retained scene.
- **Parking** — retaining runtime/view identity outside the scale-changing
  hierarchy.
- **Demounting** — destroying or reconstructing native presentation from
  view-independent state.
- **Runtime residency** — whether an external execution/rendering runtime such
  as WebView or Ghostty surface is alive.
- **Presentation revision** — revision of visual state such as disclosure,
  selection, scroll, or hover.

## Product contract

### No architectural tile-count ceiling

Array may contain arbitrarily many semantic tiles and zones. A finite machine
cannot keep maximum-resolution GPU resources or native view trees for an
arbitrary world. The architecture therefore bounds resources by spatial and
pixel demand rather than rejecting semantic objects.

```text
semantic existence       not product-limited
runtime execution        suspendable/evictable by explicit family policy
pixel presentation       driven by admitted viewport coverage
pixel resolution         driven by projected screen demand
native interactivity     pinned by active correctness requirements
```

Durable browser/terminal identity does not imply an arbitrarily large number of
live WebContent processes, Ghostty surfaces, or external GPU buffers. Runtime
residency is independent from semantic, pixel, and interaction residency.

### Real detail remains visible

The presentation system may change representation, resolution, or freshness.
It may not replace real content with a synthetic summary.

Allowed representation examples:

- the actual transcript pixels at overview resolution;
- the actual browser snapshot pixels;
- the actual terminal frame pixels;
- the same semantic text drawn by an Array-owned renderer;
- a last-complete lower-resolution page while a sharper page is produced.

Rejected representation examples:

- generic agent shells;
- labels standing in for bodies;
- reconstructed terminal text instead of terminal pixels;
- browser placeholders;
- missing or blank tiles;
- semantic summaries substituted for actual content.

### Four independent fidelity dimensions

Every design decision must state its contract for:

1. **Pixel completeness** — all currently visible content is represented.
2. **Resolution fidelity** — representation is sharp enough for projected
   screen demand and anticipated motion.
3. **Temporal freshness** — representation age under streaming, animation,
   terminal output, browser activity, and selection.
4. **Interaction and accessibility** — hit testing, focus, IME, selection,
   drag/drop, menus, and assistive semantics.

Calling a surface “exact” refers to pixel completeness at a particular revision
and resolution. It does not automatically promise current time, interactivity,
or accessibility.

## North-star invariant

> A camera frame may change camera presentation state. It may not synchronously
> perform semantic reduction, TextKit layout, NSView layout, WebKit snapshotting,
> terminal readback, image decoding, or native subtree capture.

Equivalently:

> Tiles do not hear the camera move.

Content systems respond to content and local interaction. Resolution producers
respond asynchronously to screen demand. The presentation scene responds to the
camera.

## Target scaling laws

Let:

- `S` be total semantic tiles;
- `C` be presentation chunks intersecting the viewport/overscan;
- `P` be viewport pixels;
- `D` be changed semantic input plus dirty demanded pixels/fragments;
- `I` be native interaction-pinned tiles.

The target is:

```text
semantic storage          O(S)
camera CPU                O(C), with no dependence on NSView subtree depth
camera GPU                O(P x overdraw)
content production        O(D), without traversal of unchanged history
presentation-surface memory O(viewport + overscan + adjacent resolution buckets)
native presentation work  O(I)
```

`C` means spatial/screen-space chunks, not one chunk per visible semantic tile.
Pinned browser, terminal, and native runtimes retain separately budgeted
resources outside the presentation-surface expression.
`O(1) zoom` is product shorthand for a camera path whose cost does not scale
with total semantic count, transcript history, Markdown block count, or mounted
native descendants. It does not mean the GPU shades no pixels or that a spatial
query contains zero elements.

## Architecture overview

```text
Semantic/runtime state
        |
        v
Revisioned render descriptions + presentation state
        |
        v
Family-specific producers
  - Array display-list/text renderer
  - AppKit capture where appropriate
  - WK snapshot/native policy
  - Ghostty completed-frame source
        |
        v
Spatial/resolution scene
  - sparse complete parents for admitted regions
  - viewport/overscan detail
  - dirty queues and revision arbitration
        |
        v
Compositor-owned camera
  - Core Animation eligible
  - Metal backend if evidence earns it
        |
        +----------------------+
        |                      |
        v                      v
Visible detailed pixels   Native interaction + AX bridge
```

The architecture has six ownership layers. They are separable choices, not a
single AppKit-versus-Metal decision.

## Layer 1 — Semantic and runtime state

### Responsibility

Own what the workspace *is*, independent of how it is currently presented:

- tile and zone identity/geometry/z-order;
- agent document and runtime state;
- browser sessions and tabs;
- terminal processes/sessions;
- file identity and content;
- durable drafts and user actions;
- semantic selection/disclosure where it should survive presentation changes.

### Required properties

- Stable identity independent of NSView identity.
- Revisioned changes.
- Snapshot-plus-tail subscription without history loss.
- No dependency on current camera scale.
- No assumption that a native tile view is installed.
- Semantic actions can be issued by native or renderer-owned interaction.

### Target state objects

Names are conceptual rather than implementation commitments.

#### AgentProjectionSession

Owns:

- the complete current `AgentDocument`;
- reducer/version lineage;
- status/descriptor facts;
- image and tool resource facts;
- a durable snapshot-plus-tail subscription;
- the newest semantic and render-admitted revisions.

It lives above any `ManagedAgentTileNSView`. Removing a view never stops semantic
truth from advancing.

#### AgentReaderState

Owns presentation behavior that must survive backend/residency changes:

- semantic top-row anchor and offset;
- stick-to-latest and jump state;
- expanded/collapsed disclosure by stable block ID;
- selected block IDs;
- optional partial text selection by block ID;
- read-surface scroll position and hover/focus facts where appropriate.

#### AgentComposerSession

Owns:

- durable draft and attachments;
- selection/caret restoration facts;
- prompt history;
- pending submission presentation;
- completion query/path;
- focus/IME pin reason;
- explicit undo restoration policy.

Native TextKit remains authoritative for live marked text and editing until a
different editor architecture is explicitly chosen.

#### BrowserPresentationSession

Owns:

- durable runtime identity and optional resident WebView;
- tab model and active tab;
- chrome/title/loading revision;
- find state;
- URL editing presentation;
- snapshot revision and freshness facts;
- native pin reasons such as dialog, input, media, or accessibility focus.

#### TerminalPresentationSession

Owns:

- durable PTY/tmux/runtime identity and optional resident execution/runtime;
- optional long-lived Ghostty surface or supported surface lease owner;
- current completed-frame revision;
- native focus/IME/selection/mouse-capture pin facts;
- presentation visibility/occlusion state.

Destroy/recreate is a deeper memory-pressure policy, not normal camera behavior.

#### FilePresentationState

Owns:

- content/fingerprint and semantic document;
- Source/Preview mode;
- Source offsets and selected UTF-16 range;
- Markdown semantic anchor and offset;
- render-description revision;
- theme/appearance revision;
- pending reveal.

## Layer 2 — Revisioned render descriptions

### Responsibility

Translate semantic/runtime state into immutable renderer-neutral presentation
descriptions. This is the no-regrets seam between current native UI and future
renderers.

Conceptual form:

```text
SemanticState + PresentationState
    -> TileRenderSnapshot / DisplayList
    -> NativeBackend | ArrayRendererBackend
```

### Required content

A render description may include:

- stable tile and node IDs;
- semantic and presentation revisions;
- local geometry and clipping;
- text runs, fonts, colors, attachments, and image resource handles;
- draw commands or family-specific immutable payloads;
- scroll/disclosure/selection presentation state;
- hit regions and semantic actions;
- animation clocks/parameters rather than rebuilt animation graphs;
- accessibility roles, labels, order, state, and actions;
- dirty bounds and resource dependencies.

### Required properties

- Immutable and safe to consume off the producer's mutation path.
- Deterministic for the same state/revision.
- Incremental: producing a new streamed revision must not deep-copy or traverse
  total history when only a small suffix changed.
- Backend-neutral: no embedded NSView identity, CALayer ownership, or Metal
  texture as semantic truth.
- Monotonic revision publication.
- Stale asynchronous results are rejected.
- Native and custom renderers may coexist as fidelity oracles for one snapshot.

### Revision model

Each publication distinguishes:

- `semanticRevision` — authoritative content state;
- `presentationRevision` — disclosure, selection, scroll, hover, or local UI;
- `styleEpoch` — appearance, font, color space, backing scale;
- `resourceRevision` — images, browser frame, terminal frame;
- `resolutionBucket` — output density request.

The exact representation may differ. Dependencies affecting one atomic visual
unit must publish compatibly; independent components may intentionally have
different freshness. A publication carries a compatibility vector or scene
generation describing which revisions are safe together. Stale work is rejected
per dependency, and tile/chunk replacement is atomic without requiring unrelated
clocks to be equal.

## Layer 3 — Family-specific pixel producers

One universal capture API is not required. Every family conforms to a common
publication contract while retaining an appropriate source mechanism.

### Common producer contract

Input:

- render description or external runtime;
- target world rect;
- target resolution bucket;
- appearance/style epoch;
- cancellation token and priority;
- requested freshness class.

Output:

- immutable completed surface or display-list fragment;
- exact covered world rect including effect padding;
- pixel dimensions, scale, color space, alpha mode;
- semantic/presentation/resource revisions represented;
- production timestamp and source timestamp;
- decoded/GPU byte accounting;
- optional hit/AX metadata;
- completion status or explicit unsupported reason.

### Array-owned agents and files

Target direction:

- renderer-neutral block descriptions;
- TextKit 2 viewport fragments and/or Core Text/Core Graphics drawing;
- custom-drawn static chrome;
- renderer-owned selection, disclosure, scrolling, links, and hit regions for
  read surfaces;
- native composer/editor islands as one candidate editing policy;
- animations driven by stable clocks/parameters rather than graph recreation in
  layout.

The current native backend remains a fidelity oracle. A custom backend is
eligible only when it reproduces a production-faithful tile, not a simplified
card.

### AppKit capture

Useful for static or transitional Array-owned content where capture is faithful
and off the camera path. It is not the universal long-term producer because:

- capture can be expensive;
- it retains dependence on native residency;
- remote/GPU surfaces may be absent;
- streaming capture can become a producer bottleneck.

### WKWebView

Candidate policies:

- asynchronous public snapshots for noninteractive presentation;
- bounded-cadence snapshots for content whose product freshness contract allows
  them;
- retained parked WebView runtime;
- native pinning for text input, dialogs, selection, media/fullscreen,
  accessibility focus, or cases where snapshot fidelity is insufficient.

There is no assumption of a public continuous WebKit texture stream. Static,
animated, canvas, WebGL, video, fixed content, and selection must be classified
by evidence.

### Ghostty

Preferred presentation source:

- a supported stable completed-IOSurface lease;
- or a supported copy/blit into Array-owned storage;
- with clear lifetime and triple-buffer semantics.

Retained parking of the actual surface/view is a candidate exact-state policy
when a supported completed-frame source is unavailable. Reconstructing terminal
text is not an exact pixel producer.

## Layer 4 — Spatial and resolution scene

### Responsibility

Maintain complete visible presentation while bounding work and memory by
viewport demand.

### Scene organization

The scene may combine:

- per-tile surfaces for dynamic or independently dirty content;
- spatial page/chunk surfaces for cold overview regions;
- compositor-owned vector primitives for zones, backgrounds, selection, and
  chrome;
- sparse, on-demand low-resolution parents for admitted regions;
- high-resolution viewport and overscan children;
- live native apertures for interaction.

One permanently resident layer per semantic tile is not the final unbounded
design. The compositor
must be able to aggregate distant/tiny semantic tiles into spatial presentation
chunks while retaining their actual pixels.

### Spatial index

The renderer owns an index over:

- semantic bounds and z-order;
- presentation chunks and their coverage;
- dirty regions;
- resolution availability;
- interaction hit regions;
- native residency/pin state.

Camera commits query an immutable presentation set prepared before or between
frames. They do not scan or reorder all semantic tiles every tick.

### Scene publication transaction

Each admitted workspace presentation has an immutable `sceneGeneration` (name
conceptual). Geometry, z-order, chunk coverage, hit regions, selection overlays,
native-aperture ownership, and accessibility geometry publish from the same
generation. Paint, hit testing, and AX never observe different halves of one
workspace mutation.

### Resolution model

Resolution follows projected physical demand:

```text
requested pixels per world point ~= display scale x camera zoom
```

Use geometric buckets with hysteresis rather than requesting a new raster for
every fractional zoom change.

For admitted and predicted regions, the scene retains:

- a last-complete lower-resolution parent;
- the current target bucket around viewport/overscan;
- an adjacent likely bucket for rapid motion;
- direction-aware prefetch;
- optional vector/display-list source for sharper rerasterization.

The hierarchy is sparse, on-demand, and evictable. “Overview” never means a
permanent fixed-resolution bitmap of all world area.

A missing high-resolution child causes temporary softness, never a blank region
or synthetic summary.

### Cold-entry and transition admission

A newly opened workspace, teleport, large zoom-out, cache purge, device loss,
or memory-pressure recovery may have no prior complete parent for the requested
region. The renderer must not admit an incomplete viewport and then call its
holes a cache miss.

Candidate admission policies include retaining the previous complete scene,
making the transition atomic only after complete demanded coverage exists, or
preparing a complete lower-resolution target envelope before revealing it.
“No blanks” applies to visible admitted coverage; the walkthrough must decide
the product behavior while a new envelope is being admitted.

### Dirty model

Dirty state is expressed by region and revision, not “redraw the tile because
the camera changed.”

Examples:

- new streaming suffix dirties transcript tail fragments;
- cursor blink dirties a small terminal region or publishes a new external
  frame;
- browser snapshot replaces its body surface;
- selection changes dirty selection overlays;
- tile movement changes spatial placement without invalidating tile pixels;
- z-order changes scene ordering without regenerating pixels;
- appearance/backing change hard-invalidates applicable resources.

### Effects and chunk boundaries

The scene owns cross-chunk composition rules for shadows, masks, transparency,
selection outlines, popovers, and overlaps. Producers declare effect padding;
the scene expands dirty and coverage dependencies across page seams so movement
or z-order changes cannot leave clipped shadows or stale overlap pixels.

### Cache and memory

Memory is byte-accounted across:

- CPU decoded surfaces;
- GPU surfaces/textures;
- transient replacements;
- native runtime resources;
- external IOSurfaces;
- atlases/pages and fragmentation.

Eviction preserves complete coverage where physically possible:

1. discard superseded/in-flight work;
2. discard unused high-resolution children;
3. retain last-complete overview parents;
4. reduce overscan and adjacent buckets;
5. apply explicit deeper runtime-residency policies separately.

No architecture claim is valid if it budgets only compressed image bytes or
ignores CPU/GPU duplication and replacement high-water.

### Sensitive surface lifetime

Transcript, browser, terminal, and file pixels are sensitive data. The cache
contract defines workspace/session scope, whether surfaces may reach disk,
purge on close/deletion/logout/provider replacement, CPU/GPU/transient-copy
lifetime, protected content that cannot be snapshotted, and diagnostics that
never export pixel content.

## Layer 5 — Compositor-owned camera

### Responsibility

Map world presentation to the viewport without notifying semantic/native tile
subtrees of scale changes.

### Camera frame contract

One camera commit may:

- update one root transform/uniform;
- update viewport clipping;
- switch an already-prepared immutable presentation set at a page/LOD boundary;
- update compositor-owned screen overlays;
- issue renderer-owned hit/AX geometry updates from model data.

It may not:

- resize the live world-plane NSView hierarchy;
- capture a native view;
- snapshot a WebView;
- read back a terminal;
- decode an image;
- reduce an agent document;
- run TextKit layout;
- build animation keyframes;
- synchronously prepare missing resolution.

### Core Animation versus Metal

Core Animation is an eligible compositor because the measured Array-side affine
through fifty prepared images is far below frame budget. This is not yet an
end-to-end WindowServer/GPU presentation result.

Metal is an interchangeable backend candidate when identical-surface evidence
shows CA/WindowServer misses due to:

- layer/transaction count;
- overdraw or masks;
- texture upload behavior;
- atlas/page management;
- frame pacing;
- effects or batching requirements.

Metal is not the target architecture by itself. It does not solve semantic
snapshots, text production, WK/Ghostty frame acquisition, IME, selection, or
accessibility.

## Layer 6 — Native interaction and accessibility bridge

### Responsibility

Preserve native behaviors where they are genuinely required without making the
native hierarchy the visual camera scene.

### Interaction state machine

```text
surface-presented
    -> prewarming/promoting (surface remains visible)
    -> native-interactive (pin reasons own residency)
    -> demoting/capturing (native remains visible)
    -> surface-presented
```

The initiating click, wheel, key, drag, or accessibility action must be
delivered exactly once.

### Native pin reasons

- first responder;
- marked text/IME composition;
- caret or partial text selection;
- pointer tracking or native drag/drop;
- browser/terminal native responder;
- dialog, menu, popover, or modal ownership;
- browser media/fullscreen/download/file chooser;
- terminal mouse capture or alternate-screen interaction;
- accessibility focus;
- any transition for which lossless state transfer is unproven.

### Pinned-island camera problem

A native view placed outside the world transform must still follow camera
position and apparent size. Per-frame native frame resizing may recreate
backing/layout cost for each island.

Therefore the architecture does not assume that a small native count is free.
It must define one or more policies:

- demote to an already-current surface before camera motion when safe;
- tolerate and budget a very small number of pinned islands;
- temporarily constrain unsupported interaction during camera ownership;
- use a frontmost native aperture;
- make Array-owned read interaction renderer-native;
- find a supported native presentation boundary that does not recreate subtree
  scaling cost.

This is a core design question, not later polish.

### Parking versus demounting

Parking is the current-state-compatible semantic contract:

- remove a native tile from the scale-changing world plane;
- retain the same view/runtime/session object;
- keep required semantic subscriptions alive;
- host it outside camera-induced backing propagation;
- do not destroy state unless the tile family's explicit deeper policy permits
  it.

Current family `detach()` methods are not interchangeable:

- agent detach cancels subscription and risks the 500-event replay cap;
- browser host detach preserves the WebView/runtime;
- terminal detach releases the runtime's view reference without a proven clean
  surface-lifetime contract and loses accessible interactive state;
- files are reloadable from current source under normal conditions, but exact
  reconstruction requires an owned content revision plus presentation state.

True demount is allowed only when relevant state has a view-independent owner.

## Z-order and overlapping tiles

One native plane above one surface plane is incorrect when a lower-z native
island overlaps a higher-z surface.

Candidate contracts:

1. Promotion uses Array's existing semantic bring-to-front behavior and permits
   one frontmost ordinary native aperture.
2. The surface scene is split into z-bands around native islands.
3. Native islands are clipped/masked by higher surface geometry.
4. An overlap-connected stack is promoted together.
5. Array-owned interaction becomes renderer-native, reducing islands.

Menus, popovers, drags, and native child windows complicate every option. The
chosen contract must preserve both semantic paint order and hit order at every
visible pixel.

## World coordinates and numerical precision

An unbounded semantic world also requires geometric scaling independent of
rendering resources. The architecture must define:

- persisted coordinate range and precision;
- camera-relative or floating-origin conversion for CA/Metal float precision;
- stable snapping and hit testing at distant coordinates and deep zoom;
- deterministic conversion among semantic world, presentation chunk, viewport,
  screen, native-island, and accessibility coordinates;
- rebase behavior that never changes persisted geometry or visible placement;
- effect-padding and pixel-rounding rules across resolution buckets.

No renderer backend may silently narrow the semantic coordinate range.

## Accessibility architecture

### AX scene mirror

Renderer-owned presentation requires semantic accessibility independent of
pixels and NSView identity.

The scene mirror owns:

- stable accessibility IDs;
- role, label, value, state, and actions;
- semantic child order;
- selection/focus state;
- world geometry transformed to screen geometry by the current camera;
- incremental updates by semantic/presentation revision;
- promotion actions for richer native interaction;
- suppression of duplicate nodes while native presentation owns a tile.

### Family policy

- Array agents/files can derive semantic AX from render descriptions.
- Native composer/editor islands expose native text accessibility while active.
- Browser and terminal may use tile-level semantic proxies that promote
  and pin the native runtime for rich native accessibility.
- Accessibility focus is a residency pin and must survive camera motion and
  presentation transitions.

Accessibility is part of the renderer contract, not a post-performance add-on.

## Scheduling and temporal behavior

### Two clocks

The architecture separates:

1. **Camera/input clock** — immediate, display-paced, immutable presentation.
2. **Content-production clock** — revision-driven, coalesced, cancellable, and
   prioritized by projected pixel demand.

Semantic ingestion continues independently. Visual application may supersede
intermediate revisions while preserving final semantic state.

### Backpressure and overload

Every producer lane has bounded queues, supersession, cancellation, and
family-aware fairness. Superseded intermediate revisions need not be rasterized,
but semantic state is never lost.

The architecture defines quantitative maximum admitted staleness by family and
state. Under endless streaming or many animated external tiles, displayed
revisions continue advancing within that bounded age; visibility cannot require
global quiescence. Work is coalesced by semantic change and projected pixel
demand.

### Priority order

Conceptual priority:

1. input and camera commit;
2. first-interaction promotion and native correctness;
3. visible missing-coverage prevention;
4. visible stale/low-resolution replacement;
5. overscan and predicted-direction preparation;
6. offscreen overview maintenance;
7. speculative or deep-cache production.

Camera motion never waits for lower lanes.

### Animation

Renderer-owned animations use stable clocks and parameters. Layout or camera
changes do not rebuild sampled animation graphs.

Animations may be represented as:

- compositor uniforms/properties;
- dirty-region frame publications;
- external producer frames;
- native motion only while an interaction island owns presentation.

Temporal freshness is expressed quantitatively by family and state, not by the
word “live.”

## Correctness invariants

### Camera and coverage

- no blank/exposed pixels in visible admitted coverage;
- world-to-screen anchor error at most one device pixel;
- no camera-frame native layout/capture/readback;
- no stale presentation-set mutation mid-frame;
- correct rapid reversal and zoom-out coverage;
- exact final semantic viewport.

### Revision correctness

- every atomic visual unit satisfies its declared revision compatibility vector;
- stale asynchronous production never replaces a newer result;
- last-complete content stays visible until an atomic replacement;
- final semantic revision eventually becomes visible;
- a camera gesture never loses semantic events.

### Interaction correctness

- first event delivered exactly once;
- semantic and visual hit testing agree;
- focus, marked text, selection, drag, modal, and AX pins are respected;
- park/promote preserves state;
- native and surface paint/hit z-order agree;
- no duplicate accessibility nodes or focus loss.

When visible pixels intentionally lag semantic truth, hit testing and actions
are interpreted against the represented presentation revision. Before dispatch,
the system either promotes/reconciles to a compatible state or applies an action
whose stable semantic target still exists. Queued promotion events preserve
order, coordinate mapping, and cancellation, and the initiating event remains
exactly once.

### Resource correctness

- CPU, GPU, external-surface, and transient bytes are accounted;
- memory pressure does not create holes;
- repeated park/promote does not leak subscriptions, observers, WebContent
  processes, Ghostty surfaces, layers, or views;
- display scale, appearance, color space, and device loss produce coherent
  invalidation and fallback.

## Architecture failure modes

The target hypothesis is invalid or must be narrowed if:

- surface production enters the camera critical path;
- exact browser/terminal pixels cannot meet the agreed fidelity/freshness
  contract;
- pinned native islands recreate the global zoom cost;
- interaction promotion is perceptible or loses the initiating event;
- state cannot survive parking/demotion;
- z-order cannot be preserved for overlaps;
- accessibility semantics regress;
- continuous streaming creates an unbounded dirty backlog;
- duplicate native and surface production overwhelms the main thread;
- memory scales with total world area at maximum resolution;
- one permanently resident layer per semantic tile recreates total-count camera
  work;
- CA/WindowServer fill, masks, uploads, or transactions miss even with exact
  immutable surfaces;
- cold cache or memory pressure exposes blanks;
- custom Array rendering cannot reproduce production tile behavior.

Failure of one producer or interaction policy does not automatically invalidate
all six layers. The architecture permits family-specific native retention,
custom rendering, or backend choices.

## Explicitly open design decisions for walkthrough

These are the questions to decide with Dylan before implementation planning.

During the walkthrough, each decision becomes a ledger entry with:

- decision statement and product effect;
- viable options or combinations;
- current lean, if any;
- evidence required and what would invalidate the choice;
- dependencies on other decisions;
- Dylan's decision and rationale.

The options below are not assumed mutually exclusive unless the discussion
explicitly makes them so.

### D1 — Authoritative resting presentation

Options:

- native at rest, retained surfaces only during camera motion;
- permanent retained scene at rest and during motion;
- family-specific authority, with Array-owned content retained and selected
  external surfaces native.

Current architectural lean: permanent retained presentation provides the cleanest
unbounded scaling and removes the global settle bake, but must earn interaction,
freshness, and AX correctness.

### D2 — Gesture-time temporal freshness

For each family, decide acceptable age during a several-second zoom:

- agents streaming;
- terminal output/cursor;
- browser static page;
- browser CSS/canvas/WebGL/video;
- indicators and selection.

Pixel completeness is non-negotiable. Temporal age remains a separate product
decision.

### D3 — Renderer-neutral boundary shape

Decide whether the primary seam is:

- high-level immutable family snapshots;
- a common display list;
- semantic block snapshots plus family backends;
- a hybrid in which external producers publish surfaces directly.

Current lean: semantic/family snapshots with a shared scene publication
contract. Do not force WK/Ghostty through an Array display list.

### D4 — Array-owned text renderer scope

Choose the intended ownership range:

- static/read-only transcript and Markdown only;
- read interaction including scrolling, links, disclosure, selection, and copy;
- chrome and controls;
- editable composer eventually;
- full tile including all editing.

Current lean: renderer-owned read surfaces and chrome, with native text editing
until a separate editor decision.

### D5 — Native-island policy

Choose among:

- one frontmost aperture;
- multiple budgeted islands;
- family-specific maximums;
- camera demotion when safe plus pins when not;
- broader renderer-native interaction.

The decision must include the per-frame geometry strategy for pinned islands.

### D6 — Overlap contract

Decide whether promotion always brings a tile to front, whether lower-z native
interaction is supported, and how surfaces interleave with native popovers and
drags.

### D7 — Accessibility depth while surfaced

Choose:

- full semantic AX mirror for Array-owned content;
- tile-level proxy plus native promotion;
- mixed depth by zoom/readability;
- assistive-technology policy during active camera motion.

### D8 — Browser freshness policy

Classify static, animated, canvas/WebGL/video, input, selection, dialogs, and
media. Decide when snapshots are sufficient and when native residency is
mandatory.

### D9 — Ghostty integration contract

Choose the acceptable supported boundary:

- retained parked native surface;
- upstream/current-library completed-frame lease;
- explicit copy/blit API;
- native-only policy for particular interactive states.

### D10 — Surface granularity

Choose empirically among:

- per-tile surfaces;
- fixed spatial pages;
- zone sheets;
- viewport sheets;
- hybrid dynamic tiles plus cold overview pages.

The choice depends on update locality, z-order, layer count, capture/raster cost,
and memory—not only camera timing.

### D11 — Compositor backend threshold

Define what exact-surface evidence would cause Array to choose Metal over Core
Animation. Until that threshold is crossed, compositor API choice remains open.

### D12 — State durability boundary

For scroll, selection, disclosure, hover, completion, undo, browser interaction,
and terminal state, decide which must survive:

- surface/native switching;
- view parking;
- native view destruction;
- app relaunch;
- memory-pressure eviction.

Different durability tiers are legitimate but must be explicit.

### D13 — Cold-entry admission

Decide what remains visible while a newly opened, teleported, zoomed-out, or
purged region gains complete real coverage, and what event makes the new scene
generation admissible.

### D14 — External runtime residency

For browsers and terminals, decide suspension, occlusion, process/surface
budgets, background execution, crash recovery, and memory-pressure teardown
independently from semantic and pixel residency.

### D15 — World precision and overload

Choose the persisted coordinate/precision model and the camera-relative
conversion contract. Define per-family queue bounds, fairness, supersession,
and maximum admitted staleness under continuous activity.

### D16 — Sensitive surface policy

Decide whether retained pixels may reach disk, when CPU/GPU copies are purged,
how protected browser/media content behaves, and what workspace-close/deletion
guarantees apply.

## Proposed architecture statement

Subject to resolving D1–D16, the working target hypothesis is:

> Array owns an unbounded semantic world and a revisioned, renderer-neutral
> presentation model. Tile families publish complete real visual content through
> heterogeneous producers into a spatial, resolution-paged retained scene.
> Camera motion transforms that scene without relayout or capture. Native views
> are retained or materialized only for interaction and accessibility states that
> require native systems, while Array-owned read surfaces may own interaction
> directly. Content production is dirty-region-driven,
> cancellable, and subordinate to input. Core Animation is an eligible
> compositor; Metal is a backend escalation if identical-surface evidence earns
> it. If D1 selects a different resting authority, the retained-scene statement
> must be revised before it becomes the agreed target.

This statement intentionally specifies ownership and behavior, not an
implementation sequence.

## Walkthrough protocol

Review this document in the following conceptual order, without converting the
conversation into task planning:

1. Confirm product/fidelity and cold-entry contracts.
2. Resolve authoritative resting presentation (D1).
3. Confirm semantic/runtime/pixel/interaction residency distinctions.
4. Confirm the north-star camera invariant and scaling laws.
5. Resolve renderer boundary and Array-owned interaction (D3/D4).
6. Resolve freshness, external producers, and overload (D2/D8/D9/D14/D15).
7. Resolve native islands, overlap, and stale-hit semantics (D5/D6).
8. Resolve accessibility depth (D7).
9. Resolve scene granularity, coordinate precision, cache, and cold admission
   (D10/D13/D15).
10. Resolve durability and sensitive-surface lifetime (D12/D16).
11. Define the compositor backend threshold (D11).
12. Record answers to D1–D16 with rationale and required evidence.

Only after that walkthrough should a separate document translate the agreed
architecture into experiments, migration stages, and implementation work.

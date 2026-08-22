# 34 — Unbounded canvas implementation design

Date: 2026-08-17

Status: **implementation-design discussion draft, v1.** This document turns the
system model in `.plans/32` into a concrete refactor shape: what objects exist,
who owns what state, what crosses each boundary, and which decisions materially
change the code. It is deliberately not a ticket breakdown, a phase order, or an
estimate. Those come after Dylan and I agree the shape below is right.

Companions:

- `.plans/35-session-handoff-2026-08-18.md` — **read first**: repository state
  (five uncommitted tracked files), the measured Shape A result, hazards, and
  next steps;
- `.plans/31-unbounded-canvas-rendering-findings.md` — evidence record;
- `.plans/32-unbounded-canvas-target-architecture.md` — target system model;
- `.plans/33-unbounded-canvas-testing-and-measurement-architecture.md` — how any
  claim below is proven.

Repository state while writing: branch `array/integration`, HEAD `ce493d2`
(Array 0.5.0). Everything in Part II is read-only inspection with file/line
anchors so it can be re-checked. **The design pass itself modified no source**;
the measurement step that followed it (see `.plans/35`) added the
`canvas.surface-host-slope` probe, its check flag, its matrix leg, the
regenerated inventory, and the published budgets section — additive,
uncommitted, and no production behaviour change.

## How to read this

Every design claim carries one of these labels, and they are not
interchangeable:

- **[proven]** — measured, or directly readable in the source cited.
- **[source]** — a mechanism the source establishes, whose *cost share* is not
  measured.
- **[hypothesis]** — a strong architectural belief with a named kill condition.
- **[product]** — Dylan's call, not an engineering derivation.
- **[platform-open]** — depends on an Apple/WebKit/Ghostty capability nobody has
  confirmed on this machine yet.
- **[experiment]** — the thing that would settle it.

Each major design choice ends with a compact block:

```text
owns:        which object holds the state
scales with: what makes it more expensive
streaming:   behaviour while agents/terminals/browsers are live
fidelity:    pixel / resolution / freshness / interaction+AX consequence
fails:       what happens when it goes wrong
instead:     alternatives kept alive
kill:        evidence that would invalidate it
status:      approved | provisional | open
```

---

# Part I — What 31–33 actually describe, in one paragraph

Array's tile views are four things at once: **semantic subscribers**, **layout
engines**, **pixel producers**, and **interaction/accessibility targets**. The
camera is currently expressed as a geometry change on their shared ancestor, so
every camera step forces all four jobs to re-run for every mounted tile. Docs
31–33 propose separating the third job from the other three and pointing the
camera at it alone. The six "layers" in `.plans/32` are the consequence of that
one separation, not six independent projects.

That reframing is the whole design, and it is worth stating in the form that
survives contact with the code:

> **A tile's pixels must become a first-class, addressable, revisioned object
> that is not the tile's view.**

Everything downstream — snapshots, producers, scene, compositor, native islands,
AX mirror — exists to make that sentence safe.

---

# Part II — Current ownership map (source-verified)

## II.1 The camera path today

```text
NSEvent (scroll / magnify / pointer drag)
   └─ CanvasCameraDriver                    Canvas/CanvasCameraDriver.swift
        accumulates, coalesces to display pace, owns glide + settle
        └─ CanvasNSView.setViewport(_:)     Canvas/CanvasNSView.swift:1294
             ├─ canvasState.viewport = …            (model write)
             ├─ frameRecorder?.noteCameraStep()
             ├─ syncWorldPlaneToCamera()            CanvasNSView.swift:274
             │    └─ CanvasWorldPlaneView.applyCamera(…)
             │         Canvas/CanvasWorldPlaneView.swift:96
             │         bounds.origin = pan      → cheap
             │         bounds.size   = zoom     → AppKit backing cascade
             ├─ for view in visibleTileViews { refreshZoomDependentChrome() }
             │    CanvasNSView.swift:318, TileNSView.swift:702
             ├─ repositionTrackingOverlaysForCamera()
             └─ (on non-driver writes) cursor rects, save/hydration debounce
```

The driver is genuinely good and is **not** the problem: it is display-paced,
leading-edge, latest-wins, composes pan+zoom+glide around one live anchor, and
funnels everything through one synchronous `setViewport`. It should survive the
refactor essentially unchanged — it becomes the input owner for a compositor
camera instead of for a view's bounds. [proven]

## II.2 The world plane's two properties that already encode the future

`CanvasWorldPlaneView` is a single view whose `frame` is the viewport rect and
whose `bounds` is the camera. Two of its properties are load-bearing and are
exactly the ones a compositor scene would want:

- `autoresizesSubviews = false` — tiles keep **world** frames; a camera step
  never writes a tile frame.
- `clipsToBounds = true` — the bounds *are* the visible world region, so
  clipping is viewport clipping for free.

Its own doc comment already records the measurement that matters here: with a
forced synchronous layout, a camera write costs **7.2–8.8 ms/step regardless of
which view or which property is written**, and a profile put only 2.3% of
samples in the camera itself. The cost is the traversal, not the write. [proven,
CanvasWorldPlaneView.swift:29-50]

## II.3 Tile geometry has two models, not one

There is no single tile-geometry source of truth:

- `canvasState.tiles` — flat, WORLD frames, owns the active project at boot;
- `CanvasNSView.ZoneLayer.tiles` — ZONE-LOCAL frames, owns the active project
  once `setZones` has run (CanvasNSView.swift:2528, :2551).

`qaTotalInstalledTileCount` exists precisely because a camera step pays for both
(CanvasNSView.swift:263). This is the same hazard CLAUDE.md lists as #9.
[proven]

**Consequence for this design:** "the renderer owns a spatial index" (doc 32,
layer 4) presumes one geometry model to index. Today there isn't one. Unifying
tile geometry is a real prerequisite, not a detail.

## II.4 Chrome is *already* camera-dependent, deliberately

`TileNSView` has screen-space floors expressed in world units, quantised into
geometric zoom buckets:

- `grabHeightInLocalCoordinates` = `max(24, 28 / bucket(zoom))` (:642)
- `closeButtonWorldSize` = `max(14, 22 / bucket(zoom))` (:712)
- `closeGlyphWorldPointSize` = `max(9, 11 / bucket(zoom))` (:722)
- `chromeScaleBucket(for:)` — geometric, 4 steps/octave, rounds **down** (:661)

and the body is explicitly protected from them:

- `contentTopInsetWorldHeight` = the *unfloored* 24 pt, "so it does not change
  with the camera… Aliasing the inset to it re-framed the body on each step and
  reflowed the document." (:673-681)

This is the single most useful thing the source told me. Array has already
discovered — and paid for — the body/chrome split. Chrome must hear the camera;
the body must not. [proven]

## II.5 Agent tile ownership

```text
AgentSupervisor ──subscription──► ManagedAgentTileNSView  (2,293 lines)
      ├─ AgentTranscriptListView (1,638 lines)
      │    ├─ NSCollectionView + AgentTranscriptLayout
      │    ├─ rows / rowsByID / rowPositions / entryIndexByID
      │    ├─ disclosureStateStore, scrollController
      │    └─ AgentBlockHostView ─► AgentBlockRendering
      ├─ AgentComposerView + ComposerHeightController
      ├─ image rail (NSScrollView + NSCollectionView)
      ├─ file rail (NSScrollView + NSStackView)
      └─ header / status / legacy hidden status tree
```

Facts that constrain the design:

- **The semantic model is already renderer-neutral.** `AgentDocument` →
  `AgentEntry` → `AgentBlock`, with stable `AgentNodeID`s, per-node `revision`,
  a reducer, and `AgentDocumentPatch`. It lives in
  `ContinuumRevivedAgentContent` with no AppKit dependency. This is the input a
  render description needs, and it exists. [proven]
- **`AgentBlockRendering` is already a per-family producer protocol**
  (AgentBlockRenderer.swift:~306): `makeView() / update(view:block:context:) /
  measure(block:width:context:) -> CGFloat /
  updateAccessibility(view:block:context:)`. `measure` and `updateAccessibility`
  are *already* pure functions of `(block, context)`; only their output type is
  AppKit. [proven]
- **`AgentBlockMeasureKey` is already a revision-compatibility vector**
  (AgentBlockMeasurementCache.swift:16): `id, kind, entryRole, revision,
  widthBucket, appearance, contentSizePolicy, presentationRevision`. That is
  content revision + presentation revision + style epoch + a resolution-ish
  bucket, keyed per node, and it works today. [proven]
- **`ManagedAgentTileNSView.detach()` is not a residency seam** (:462): it
  cancels the subscription, tears down streaming markup, resets compact status
  projection, unbinds composer/completion/tool-detail. Supervisor replay is
  capped at 500 events. Parking must not call it. [proven]
- The transcript **is** virtualised (NSCollectionView materialises visible rows
  only), but `AgentTranscriptLayout.layoutAttributesForElements(in:)` filters
  the complete attribute array (:54), and `AgentTranscriptListView.layout()`
  drives `layoutSubtreeIfNeeded()` twice plus an explicit `prepare()` and a
  visible-item reframe loop, in live windows as well as offscreen probes
  (:1012-1051). [proven]

## II.6 File tile ownership — and the family nobody has been sizing

`FileMarkdownDocumentView` **mounts every parsed block eagerly**, up to
`maximumRenderedBlocks = 400` (:143), each one a renderer view from the *same*
`AgentBlockRendererRegistry.production` the transcript uses (:196). There is no
virtualisation. `measureIfNeeded` re-measures **all** rows on any width change
(:263) and `layout()` frames all of them (:277).

So a *single* Markdown Preview tile can carry more mounted TextKit views than
several agents, and it hits its own truncation wall — "Preview stops here — N
more block(s) in this file" — which is already a shipping fidelity compromise.
[proven]

Two consequences: per-agent cost models understate the real workspace, and a
retained-surface architecture would eventually *remove* the 400-block cap rather
than merely make it faster.

## II.7 Browser and terminal ownership

- `BrowserRuntime.attach(to:)/detach()`; `WKWebViewBrowserRuntime.detach()` is
  `webView.removeFromSuperview(); hostView = nil` (:365) — the WebView and the
  runtime survive. **This is already a clean parking seam.** [proven]
- `GhosttyTerminalRuntime.detach()` is `terminalView?.removeFromSuperview();
  terminalView = nil` (:87) — the runtime drops its only strong reference to the
  view and there is no explicit surface close on that path. Confirms doc 31's
  lifetime hazard. [proven]
- `GhosttyTerminalRuntime` already has `dehydrateForSnapshot()` /
  `rehydrateFromSnapshot()` calling `setSnapshotOccluded(…)` (:95-105) — a
  residency seam that exists but whose Boolean polarity doc 31 flags as
  suspicious. [source]
- `GhosttyTerminalView.viewDidChangeBackingProperties()` unconditionally calls
  `ghostty_surface_set_content_scale(surface, scale, scale)` with the *window*
  backing scale, which canvas zoom does not change (:94-100). [proven]

## II.8 Array already has a viewport-demand residency planner

This is the most under-appreciated fact in the whole investigation.

```text
CanvasNSView viewport change
  └─ WorkspaceRuntime.onViewportChanged()          WorkspaceRuntime.swift:692
       └─ (debounced) reconcileHydration()                          :714
            ├─ ZoneHydrationOrchestrator.plan(zones:viewport:…)
            │    Core/ZoneHydrationOrchestrator.swift:38
            │    per-zone tier from CanvasEngine.hydrationTier,
            │    then a global maxLive budget with pins
            │    (pinnedLive policy, focusedTileZone) and
            │    proximity-to-viewport-centre eviction order
            ├─ ZoneRuntimeController.setTier(…)   ZoneRuntimeController:524
            │    .live → hydrateToLive() ; .snapshot/.cold → dehydrate()
            └─ enforceBrowserRuntimeBudget()        (LRU over live WebViews)
```

`HydrationTier` is `{ live, snapshot, cold }`
(Core/WorkspaceDocument.swift:359).

So the **control plane** for demand-driven residency — plan, tier, pin, budget,
proximity eviction, apply — already ships. What it lacks is a **faithful demoted
presentation**: `dehydrate` swaps in `BrowserSnapshotTileNSView` with
`placeholderSnapshotImage()`, an 80×60 grey rectangle
(ZoneRuntimeController.swift:579). That is precisely the rejected shell.

**This reframes the work.** We are not building a residency system from zero. We
are (a) giving the existing one a pixel-faithful demoted representation, and (b)
refining its granularity from *zone* to *tile / spatial chunk*. That is a much
smaller and much better-precedented job than doc 32 implies.

## II.9 Focus and accessibility ownership

- `FocusBroker` + `FocusSurfaceAdapter` (FocusBroker.swift:6) already indirect
  "which surface has focus" away from NSView first-responder identity, with
  register/unregister/acquire/release, modal snapshots, and reserved-shortcut
  routing. This is a real pin-reason seam waiting to be used. [proven]
- **Accessibility is 100% emergent from the native view tree.** 557
  `setAccessibility*` call sites app-wide; `CanvasNSView` and `TileNSView`
  between them have four, all on the close button. Every meaningful AX node in a
  tile is produced by a renderer writing into the very NSView subtree a retained
  scene would unmount. [proven]

That last point deserves to be blunt: **AX is not a layer we add on top of the
new renderer. Today's AX *is* the tree we are proposing to stop mounting.**

## II.10 Measurement seams that already exist

- `CanvasFrameRecorder` — display-link-bracketed gesture stats, camera-step
  marking, honest late-frame counting against real cadence. Keeps per-gesture
  intervals but computes and discards. [proven]
- `PerfScenarios` — `canvas.pan/zoom/camera-slope/magnify-slope/raster/
  gesture-transition/geometry-hold-probe/proxy-scene-probe/
  scroll-magnification-probe/stress`, with `PerfBudget` exact counts + duration
  guards, ABBA in the hold probe, and a `pump()` that layouts, displays, **and**
  `CATransaction.flush()`es.
- Camera correctness oracle: `qaTileScreenFrameMismatchCount`
  (CanvasNSView.swift:~330) recomputes every tile's screen rect from the model
  and compares against the real view tree — and its comment already says it is
  phrased to survive a retained-plane migration.
- `worldPlane.qaBoundsSizeWriteCount` — the exact forbidden-work counter for the
  camera invariant.

---

# Part III — Contradictions, missing state, dangerous assumptions

These are the corrections this source pass produced. They change the design, not
just the prose.

## C1 — "98.5% recovered" is a floor measurement, not a camera measurement

In `canvasGeometryHoldProbe` the *held* arm does not call `applyCamera` at all;
it only `pump()`s (PerfScenarios.swift:~1240). So `held p95 ≈ 0.02–0.12 ms` is
**"cost of a pump with nothing dirty"** — the lower bound of *any* presentation
architecture. The proxy probe separately measured a root affine over synthetic
image layers at 0.02–0.05 ms.

Together they bound the answer from below. **Neither measured a prepared scene
of production pixel volume actually moving.** A real overview frame at
1600×1000@2× with translucent zone chrome, rounded masks, shadows and 20 tile
surfaces is a WindowServer/GPU question that has never been asked.

> **The single most important missing experiment is not in docs 31–33's list in
> that form:** build the exact-surface CA scene at production pixel volume and
> real overview zoom, and measure end-to-end. Doc 31 item 11 asks for
> "20/50/100/500 presentation chunks"; it should also pin *pixel volume,
> translucency, masks and shadows*, because those are what CA/WindowServer
> actually charges for.

## C2 — Doc 32's north-star invariant is contradicted by shipping behaviour

"Tiles do not hear the camera move" is false today **on purpose**: chrome floors
are screen-space and bucketed (II.4), and `setViewport` calls
`refreshZoomDependentChrome()` on every visible tile precisely because of it.

The invariant is right about *bodies* and wrong about *chrome*. The design must
say so explicitly, and the resolution is not "make chrome camera-independent"
(that breaks the affordance floors Dylan's `--tile-drag-grab-check` protects) —
it is **move chrome into the compositor in screen space**, where a floor is just
a constant and no rasterisation is triggered by crossing a bucket.

## C3 — Accessibility is the tree we are unmounting

See II.9. Doc 32 lists an "AX scene mirror" as a layer-6 responsibility but does
not say where its content comes from. The source answers it:
`AgentBlockRendering.updateAccessibility(view:block:context:)` is already a pure
function of `(block, context)` that happens to write into a view. Converting it
to return a description is the *smallest possible* first move toward a mirror,
and it is testable against the native tree it replaces.

## C4 — The cost model is per-*mounted-view*, not per-agent

Markdown Preview mounts up to 400 renderer views with no virtualisation (II.6).
Six file tiles of unknown mode were treated as one family in every fixture so
far. A 20-tile workspace with two heavy Previews may have more mounted TextKit
views than twelve agents. Any fixture that claims parity must classify Source vs
Preview and count mounted blocks.

## C5 — The revision model already exists at block granularity

`AgentBlockMeasureKey` (II.5) is the compatibility vector doc 32 asks for. The
design should **promote that key shape**, not invent a parallel one. Concretely,
the tile-level vector is the same fields plus `resolutionBucket` and
`resourceRevision`.

## C6 — Residency has a control plane already (II.8)

Doc 32's D14/D1 read as greenfield. They are not. The existing planner's *shape*
— pure planner in Core, tier applied by a controller, pins, budget, proximity
ordering — is the right shape and should be generalised rather than replaced.

## C7 — There is no single tile-geometry model to index (II.3)

Prerequisite, not detail.

## C8 — The camera's O(installed) scan disappears rather than gets an index

Doc 31 says `visibleTileViews` "must not survive as the principle." True, but
the replacement is not "the same loop over a spatial index" — if chrome becomes
compositor-owned screen-space geometry, **the loop has no reason to exist**. Its
only current job is `refreshZoomDependentChrome`.

## C9 — Terminal demount is currently unsafe (II.7)

Parking is the only proven terminal residency. Any design that assumes
destroy/recreate for terminals is assuming a surface-lifetime contract that does
not exist in the code we ship.

## C10 — The scaling law as stated hides the streaming cost

Doc 32 writes `content production O(D)`. Under twelve live agents, `D` is
"everything that is streaming", continuously. Camera cheapness does not reduce
it. The honest pair of statements is:

```text
camera cost  becomes independent of tile count, history, and view depth
content cost becomes independent of the camera
```

Both are wins. Only the first is free. The second is bounded by an explicit
staleness policy, and the policy has a natural shape (see D-F): **a tile that
projects to 40×25 screen pixels does not need 30 Hz surface updates.**
Resolution demand and freshness demand are the same signal.

## C11 — Seven tile families are missing from the analysis

`TileKind` has 11 cases (Core/CanvasState.swift:163); there are ~16 `TileNSView`
subclasses. Docs 31–33 discuss agents, files, browser, terminal. Missing:
`note`, `fileTree` (NSOutlineView), `ticketQueue`, `conductorQueue`,
`diffReview`, `runArtifacts`, `browserInspector`, plus the three
snapshot/restart placeholder tiles. All are AppKit-only, so a default family
policy probably covers them — but "probably" needs to be written down, not
discovered late.

## C12 — Pinned islands during motion may *be* the failure, not a residual

Doc 32 treats the pinned-island geometry problem as "a core design question."
Worth sharpening: a pinned `WKWebView` re-framed once per display interval is a
remote-surface resize per frame. There is a real possibility that **one** pinned
island costs more than the twenty tiles we removed. This argues for a default of
*demote-during-motion*, and for discovering the island cost early with N=1
rather than late with N=20.

---

# Part IV — Proposed ownership map

```text
┌─ SEMANTIC / RUNTIME ─────────────────── mostly exists today ───────────┐
│ AgentDocument (+reducer/patch)  BrowserRuntime  TerminalRuntime        │
│ file bytes + fingerprint        CanvasState/Tile/ZonePlacement         │
└───────────────────────────────┬────────────────────────────────────────┘
                                │  new: view-independent presentation state
┌─ PRESENTATION STATE ──────────▼──────── new, small, plain structs ─────┐
│ AgentReaderState  AgentComposerSession  FilePresentationState          │
│ BrowserPresentationSession  TerminalPresentationSession                │
└───────────────────────────────┬────────────────────────────────────────┘
                              │  B1: TileRenderSnapshot (immutable, revisioned)
┌─ FAMILY PRODUCERS ────────────▼───────── heterogeneous by design ──────┐
│ ArrayDisplayListProducer │ AppKitCaptureProducer │ WKSnapshotProducer  │
│ (agents, files, notes,   │ (fileTree, queues,    │ GhosttyFrameProducer│
│  markdown, diff…)        │  diff, misc AppKit)   │                     │
└───────────────────────────────┬────────────────────────────────────────┘
                                │  B2: TileSurface (immutable pixels + metadata)
┌─ PRESENTATION SCENE ──────────▼──── spatial index + cache + policy ────┐
│ tile/chunk placement · z-order · dirty queues · resolution buckets     │
│ last-complete parents · eviction · native-aperture registry            │
└───────────────────────────────┬────────────────────────────────────────┘
                                │  B3: SceneGeneration (atomic publication)
┌─ COMPOSITOR ──────────────────▼──── Array-owned CALayer tree ──────────┐
│ world layer  : one root transform  (body surfaces, world space)        │
│ chrome layer : screen space        (title bars, close, affordances)    │
│ overlay layer: screen space        (focus, marquee, nav, HUD)          │
└──────────┬─────────────────────────────────────┬───────────────────────┘
           │ B4: hit/geometry                    │ B5: AX geometry
┌──────────▼─────────────┐          ┌────────────▼──────────────────────┐
│ InteractionBridge      │          │ AXScene                            │
│ park/promote/demote    │          │ elements from render descriptions  │
│ pin reasons (FocusBroker)         │ frames via camera; suppressed      │
│ exactly-once via hitTest          │ while native owns the tile         │
└────────────────────────┘          └────────────────────────────────────┘
```

Three new boundaries. Everything else is either existing code moved or existing
code left alone.

---

# Part V — Boundary contracts

## B1 — `TileRenderSnapshot`: the renderer-neutral description

Renderer-neutral, immutable, `Sendable`, no AppKit identity, no
`CALayer`/`MTLTexture` as truth.

```text
TileRenderSnapshot
  tileID            stable Tile UUID
  family            TileKind + concrete family discriminator
  worldFrame        TileFrame (Double), body only
  zPosition         FracIndex
  revisions         RevisionVector   (see below)
  chrome            ChromeDescription      — title, status, close, affordances
  body              BodyDescription
                      .displayList(TileDisplayList)   Array-owned families
                      .external(ExternalSourceHandle) browser / terminal
                      .unavailable(reason)            restart/error tiles
  hit               [HitRegion]  (world-local rects → semantic targets)
  ax                AXNodeDescription tree
  effectPadding     EdgeInsets (shadows, focus ring, overlap bleed)
  resources         [ResourceDependency]  (image IDs, external frame IDs)
```

`RevisionVector` is `AgentBlockMeasureKey` promoted to the tile level (C5):

```text
RevisionVector
  semanticRevision      content truth        (AgentDocument.version, file
                                              fingerprint, tab/nav generation)
  presentationRevision  disclosure/selection/scroll/hover
  resourceRevision      images, external frames
  styleEpoch            appearance, token theme, font, colour space, backing
  resolutionBucket      requested device pixels per world point
  sceneGeneration       which atomic workspace publication this belongs to
```

Compatibility rule: a **tile** is replaced atomically only when every dependency
in its own vector is satisfiable together. Independent tiles may legitimately
sit at different freshness. Stale producer output is rejected per dependency,
never by requiring global clock equality.

### `TileDisplayList` for Array-owned families

Per-node, not per-tile — because the block boundary already exists and already
carries revisions:

```text
TileDisplayList
  nodes: [DisplayNode]           in paint order, stable AgentNodeID keys
  DisplayNode
    id, kind, localRect, revision
    content: .textRun([GlyphRun]) | .rect | .path | .image(ResourceID)
           | .separator | .disclosure(state) | .control(ControlDescription)
    clip, effects
    ax: AXNodeDescription?
    hit: [HitRegion]
```

**Why per-node.** `AgentBlockRendering.measure` and `.updateAccessibility` are
already `(block, context) -> value` (II.5). Adding
`displayList(block:width:context:) -> DisplayNode` alongside them gives:

- incrementality for free — the existing `AgentBlockMeasureKey` keys it;
- one implementation serving the agent transcript, Markdown Preview, note tiles,
  and diff summaries, because they share
  `AgentBlockRendererRegistry.production`;
- a fidelity oracle at the smallest possible unit: for one block, native render
  vs display-list render, pixel-compared, in both appearances and both scales;
- eventual removal of Preview's 400-block cap.

```text
owns:        AgentDocument/file content own semantics; renderers own the
             mapping; nothing view-shaped is truth
scales with: changed blocks × width buckets, never total history
streaming:   a new tail block dirties one node and the tail fragment
fidelity:    per-block native/list equivalence is directly testable
fails:       a family without a display-list backend falls back to
             AppKitCaptureProducer; correctness unaffected, cost differs
instead:     whole-tile display list; whole-tile capture only
kill:        per-block list rendering cannot reproduce a production block's
             pixels in both appearances at 1x and 2x
status:      provisional — the strongest candidate, needs a real block prototype
```

## B2 — `TileSurface`: what a producer publishes

```text
TileSurface
  tileID, revisions (the vector actually represented)
  coveredWorldRect        including effectPadding
  pixelSize, scale, colourSpace, alphaMode
  backing                 IOSurface | CGImage | CALayer contents handle
  producedAt, sourceAt    (freshness = now - sourceAt)
  byteCost                CPU + GPU accounted separately
  status                  complete | partial(reason) | unsupported(reason)
```

Producer input: `(snapshot | external runtime, targetWorldRect,
resolutionBucket, styleEpoch, freshnessClass, priority, cancellationToken)`.

Invariants: completion is immutable; cancellation is idempotent; cancelled or
stale output can never publish; failure leaves the last complete compatible
surface in place.

## B3 — `SceneGeneration`: atomic publication

One immutable generation carries **geometry, z-order, chunk coverage, hit
regions, native-aperture ownership, and AX geometry together**. Paint, hit test
and AX can never observe different halves of one workspace mutation. This is
what makes "semantic hit and visual hit agree" a structural property instead of
a discipline.

## B4 — Camera frame contract

A camera commit may: write one root transform; update viewport clip; swap to an
**already-prepared** scene generation at a page/LOD boundary; update
screen-space chrome and overlay geometry.

It may not: resize the native world hierarchy; capture; snapshot; read back;
decode; reduce; run TextKit; build animation keyframes; synchronously prepare
missing resolution.

Positive teeth (all already have precedent): a mutation occurred, presentation
moved, `qaTileScreenFrameMismatchCount == 0`, exact final viewport,
`qaBoundsSizeWriteCount == 0` during motion.

## B5 — Interaction bridge

State machine:

```text
surfaced ─promote─► promoting ─► native ─demote─► demoting ─► surfaced
                        ▲                              │
                        └──────── pin held ◄───────────┘
```

**Exactly-once delivery has a clean answer the docs do not state.** AppKit calls
`hitTest(_:)` on the view hierarchy *before* delivering a mouse or scroll event.
So the compositor host's `hitTest` can:

1. classify the point against the current `SceneGeneration`;
2. if the hit needs native and `NSApp.currentEvent` is a real
   down/scroll/right-down, **synchronously unpark** the tile's native view into
   the host at the correct screen frame and `layoutSubtreeIfNeeded()`;
3. return `nativeView.hitTest(convertedPoint)`.

AppKit then delivers the original event to that descendant, once, with no
synthesis. No `NSApp.sendEvent`, no nonce replay, no double-dispatch.

Known hazards, all testable: `hitTest` also runs for cursor rects, tooltips and
`mouseMoved`, so promotion must be gated on the current event type; keyboard
never hit-tests, so keyboard promotion runs through the existing `FocusBroker`
path (`acquireFocus`), which already reaches the tile view; drag destinations
are per-view, so the host must register drag types and promote on
`draggingEntered`.

Because step 2 must be *synchronous and fast*, this argues strongly for
**parking, not demounting**, as the normal residency state.

```text
owns:        InteractionBridge owns transitions; FocusBroker owns pin reasons
scales with: number of concurrently pinned islands, not tile count
streaming:   unaffected
fidelity:    the initiating event is delivered by AppKit, not re-created
fails:       promotion too slow → visible hitch on first click; measurable as
             promotionLatency and gated
instead:     event replay with a nonce; promote-on-hover; always-native at rest
kill:        synchronous unpark of a heavy agent tile exceeds ~8 ms
status:      provisional — strongest candidate, needs a first-click witness
```

## B6 — AX scene

`AXScene` owns stable AX element identity per (tile, node), derives screen
frames from world geometry through the current camera, updates incrementally by
revision, and **atomically suppresses its nodes for a tile while that tile's
native view is promoted** so nothing is duplicated.

Content source: `AgentBlockRendering.accessibility(block:context:) ->
AXNodeDescription`, the pure sibling of today's `updateAccessibility`. The
migration is honest because the native tree remains available as the oracle: for
one tile, walk both and compare role/label/value/order/actions/frames.

---

# Part VI — Family policies

**Decided 2026-08-17 (Dylan):** retained scene is authoritative at rest *and*
in motion for Array-owned families; browser and terminal stay in a native
residual plane until their producers are proven. See Part XI, I4/I5.

| family | producer | resting authority | notes |
|---|---|---|---|
| managedAgent | display list | retained | shares registry with files |
| file (Source) | display list or capture | retained | one TextView, shallow |
| file (Preview) | display list | retained | removes the 400-block cap |
| note | display list | retained | NSTextView editing → native island |
| fileTree | capture | retained | NSOutlineView; capture is faithful |
| queues / artifacts / diff / inspector | capture | retained | AppKit-only |
| snapshot / restart placeholders | display list | retained | trivial |
| browser | WK snapshot **[platform-open]** | **native residual** | below |
| terminal | Ghostty frame **[platform-open]** | **native residual** | below |

## I4 — The native residual plane (decided)

> **Keep `CanvasWorldPlaneView` alive.** It continues to receive the bounds-size
> zoom, but only tiles whose family has no proven pixel producer remain in it.
> Every other tile presents from the retained scene.

Consequences:

- zoom cost becomes `O(tiles with unproven producers)` — in the real workspace
  that is **2 of 20**, not 20;
- no WKWebView snapshot fidelity result and no Ghostty frame API are needed to
  get most of the win;
- migration is **per family**, incrementally, with the old path as a live A/B
  control on the same canvas;
- it directly de-risks C12: we learn the pinned-island cost at N=1 and N=2
  instead of discovering it at N=20;
- browser and terminal keep *perfect* fidelity, freshness, interaction and
  accessibility for free, because they are literally today's tiles.

### Shape A — scene-in-plane (decided)

Two sibling planes cannot interleave arbitrarily, and doc 32's D6 treats that as
a hard problem. It is only hard if the scene lives *beside* the world plane.
Dylan chose the other shape:

> **Surface hosts are `NSView`s at world frames, installed as ordinary children
> of `CanvasWorldPlaneView` — exactly where tile views live today.**

The consequence is smaller than it first looks, and this is the best news in the
document. A surface host does not replace `TileNSView`; it replaces
`TileNSView`'s **content view**:

```text
TileNSView                       unchanged
  ├─ TitleBarView                unchanged   (title, dots, close, buckets)
  ├─ CornerOverlayView           unchanged
  ├─ AffordanceOverlayView       unchanged
  └─ contentView  ◄── setContentView(TileSurfaceView) instead of the deep body
```

So `TileSurfaceNSView: TileNSView` inherits, for free and unmodified:

- chrome, close button, status pill, context menu;
- move-grab strip, resize edges, corner brackets, drag ghosts, snapping;
- `hitTest`, cursor rects, `TileAffordanceMetrics`;
- `FocusSurfaceAdapter` registration and `FocusBroker` participation;
- z-order via `reorderTileSubviewsByZIndex`;
- the camera oracle `qaTileScreenFrameMismatchCount`, unchanged;
- `installProjectTile` / `install(tileView:for:)`, unchanged.

**Only the body becomes a surface.** That is the smallest possible entry into
this architecture, and it means the body/chrome split (I1) is not a new
subsystem — it is `setContentView` with a different argument.

### What Shape A does *not* buy, stated honestly

- The camera still writes `worldPlane.bounds.size`, so AppKit still traverses
  the hierarchy. The traversal is now over a **flat** tree — no scroll views, no
  TextKit, no Auto Layout, no collection layouts — so it is `O(installed views)`
  with a small constant rather than `O(mounted native complexity)`. It is not
  zero, and it is not the `O(1)` camera doc 32 describes. [hypothesis]
- Chrome keeps its zoom buckets and keeps hearing the camera through
  `refreshZoomDependentChrome`. That is fine: `layoutChrome` compares frames
  before writing, `invalidateChrome` fires only when a bucket boundary is
  crossed (~9 times across a 1.0→0.2 gesture at 4 steps/octave, not per frame),
  and the SF Symbol freeze in `574e7f7` already removed the per-step image mint.
  Moving chrome to a screen-space overlay is a **later optimisation, not a
  prerequisite** — which is a real correction to what I wrote in v1.

### The trap Shape A must not fall into

A bounds-size change updates descendants' effective rasterisation scale, and
AppKit's default response is to update `layer.contentsScale` and invalidate
backing. On a layer-hosting view the layer is ours, so
`viewDidChangeBackingProperties()` must apply **our** bucketed resolution policy
rather than AppKit's per-step scale.

Miss that override and every zoom step re-rasterises every surface — the same
failure wearing a new costume, and it would show up as a *good* geometry-hold
number with a *bad* real gesture. This needs a deterministic red-then-green
witness before any surface ships: count producer invocations caused by camera
commits, and require exactly zero. [source]

### Shape B remains the destination

One layer-hosting host, one root transform, world plane retired, pure `O(1)`
camera. It becomes available once the residual plane is empty, and at that point
the z-order problem no longer exists because there is only one plane. The
trigger for going there is evidence, not ambition: **Shape A's flat-tree
traversal becoming the binding cost at realistic installed counts.**

```text
owns:        CanvasNSView owns the plane; TileSurfaceNSView owns its host layer;
             scene owns bucket policy and dirty regions
scales with: Shape A: installed view count (flat) + viewport pixels
streaming:   residual tiles keep today's behaviour exactly, good and bad
fidelity:    residual tiles are today's tiles — perfect on all four contracts
fails:       a missed contentsScale override re-rasterises every surface per
             step, and every existing counter would still look green
instead:     Shape B first (rejected: loses z-order, hit test, chrome, focus
             registration and the install path all at once)
kill:        flat-tree traversal at ~200 installed hosts is already over budget,
             forcing Shape B before the residual plane can be emptied
status:      **approved** (I4 + Q6)
```

**A census question worth answering cheaply:** in real saved layouts, do
browser/terminal tiles ever overlap another tile? Under Shape A the answer no
longer gates the design, but it still tells us how urgent Shape B is.

---

# Part VII — Scene, camera, scheduling, memory

## D-A — Body and chrome are separate presentations

Directly from II.4: chrome floors are screen-space and bucketed, and
`contentTopInsetWorldHeight` already protects the body from them on purpose.

**Under Shape A this is nearly free, and v1 overclaimed it.** The split is
`TileNSView.setContentView(TileSurfaceView)`: chrome stays exactly as it is —
native, bucketed, shallow — and only the body becomes a surface. Chrome keeps
hearing the camera through `refreshZoomDependentChrome`, and that is acceptable
because `layoutChrome` compares frames before writing and `invalidateChrome`
fires only at bucket boundaries (~9 per 1.0→0.2 gesture, not per frame).

The later optimisation — chrome as a screen-space compositor overlay, floors as
plain constants, `refreshZoomDependentChrome` and the `visibleTileViews` loop
gone (C8) — belongs with Shape B, where there is a screen-space layer to put it
in. Recording it here so C8 is not read as a Shape A promise.

```text
owns:        TileNSView owns chrome (unchanged); scene owns the body surface
scales with: chrome: visible tiles × bucket crossings, not frames
             body: dirty area
streaming:   status pills dirty chrome only; never the body surface
fidelity:    chrome is literally today's chrome, so pixel-identical by
             construction; the body is what has to prove itself
fails:       body/chrome seam misaligns by a subpixel at fractional zoom —
             caught by the existing screen-frame oracle
instead:     screen-space chrome from day one (deferred to Shape B); scale
             chrome with the body (rejected: breaks the affordance floors)
kill:        chrome bucket crossings turn out to be per-frame in a real gesture
             rather than ~9 per gesture
status:      **approved in Shape A form** (I1)
```

## D-D — Per-tile surfaces first; page chunks behind a projection threshold

Doc 32 correctly says one permanent layer per semantic tile is not an unbounded
design. But that is a statement about the *limit*, not the *first 200 tiles*.

Proposed rule:

```text
projected tile area >= T screen pixels  → its own surface
projected tile area <  T                → aggregated into a spatial page
                                          surface with its neighbours
offscreen beyond overscan               → no surface; last-complete parent only
```

`T` is measurable, not guessed. This keeps chunk complexity behind a threshold
that never triggers in normal use and always triggers in deep overview.

```text
owns:        PresentationScene owns index, chunk assignment, eviction
scales with: visible chunk count and viewport pixels; never total tiles
streaming:   a streaming tile above T keeps its own surface, so its dirty
             region never invalidates a neighbour
fidelity:    aggregation happens only where a tile projects to a few pixels
fails:       thrash at the threshold → hysteresis, same pattern as resolution
             buckets
instead:     always per-tile; always fixed pages; zone sheets; viewport sheets
kill:        a real deep-overview workspace produces so many above-T tiles that
             per-tile layer count itself becomes the CA bottleneck
status:      provisional
```

## D-E — Coordinates: `Double` model, camera-relative compositor floats

`TileFrame` and `CanvasViewport` are already `Double`
(Core/CanvasState.swift:196, :64) — good. The scene publishes
**camera-relative** rects per generation, so CA/Metal float precision never sees
an absolute world coordinate. Rebasing changes nothing persisted and nothing
visible.

```text
owns:        CanvasState owns absolute Double geometry; scene owns rebase
scales with: nothing
fails:       a rebase mid-gesture shifts pixels → covered by the anchor-error
             gate (≤ 1 device pixel) already specified in doc 33
status:      approved in principle — cheap now, expensive to retrofit
```

## D-F — Freshness: streaming is streaming (decided)

**Decided (Dylan):** complete-but-briefly-stale pixels are acceptable during a
gesture only for content that is not animating, and *animating* is read
**strictly** — streaming is streaming regardless of projected size. No
perceptibility threshold. If a tile's content is advancing, its pixels advance,
even at overview zoom.

I proposed a size-derived exemption in v1. Dropping it is the better call, and
working through the arithmetic shows it is also the *cheaper* design, because it
removes a policy knob without adding real load.

### Why the strict reading is affordable

The load is bounded by the **viewport**, not by the tile count — you can only
see so much at once, and a tile's contribution to production is its projected
area, which is exactly what shrinks when many tiles are visible.

```text
overview (zoom 0.2), 12 streaming agents
  each tile ≈ 600×450 world pt → 120×90 pt → 240×180 device px @2x
  12 tiles ≈ 0.52 M device px   ≈ 16% of a 1600×1000@2x viewport
  at the existing 30 Hz coalesce ≈ 15.5 M px/s
  (a full-viewport 60 Hz repaint is ≈ 192 M px/s)

zoom 1.0, 3 streaming agents visible
  each tile ≈ 1200×900 device px
  3 tiles ≈ 3.2 M device px ≈ one viewport
  — but at zoom 1.0 only 2–4 tiles fit, so the sum is viewport-bounded again
```

So the honest bound is:

```text
streaming production ≤ O(viewport pixels × coalesced update rate)
                       independent of how many tiles are streaming
```

That is a *better* scaling statement than the size-threshold version, and it
needs no new policy. It also repairs C10's objection directly: twelve streaming
agents cannot cost twelve tiles' worth of production, because twelve visible
tiles are each small by construction.

Two things must be true for that bound to hold, and both are design work:

**(a) Production must be fragment-level, not whole-tile.** A streaming tail
appends at the bottom of a transcript. If the surface is one bitmap per tile,
appending re-rasterises the whole tile and the numbers above are wrong by the
ratio of tile area to tail area. If the surface is fragmented — per row, or per
band — it re-rasterises the changed band only.

> **This promotes I2 from "provisional, nice for incrementality" to
> load-bearing.** Under the loose reading, whole-tile AppKit capture might have
> sufficed for streaming agents at overview. Under the strict reading it does
> not, and the per-block display list becomes required rather than preferred.

**(b) Production must leave the main actor.** `AgentDocument` and `AgentBlock`
are `Codable, Equatable, Sendable`
(AgentDocument.swift:103, AgentBlock.swift:292), so a display list can be built
and rasterised off the main thread from an immutable snapshot. Glyph
runs resolve on the producer; Core Graphics/Core Text drawing into an
Array-owned bitmap or IOSurface happens on a producer queue; only the finished
immutable surface is handed back. The camera thread never waits.

This is the single most important enabling fact in the codebase for the strict
reading, and it is already true. [proven]

### What gets cheaper rather than more expensive

- **The gyro indicator goes from worst offender to nearly free.** Today
  `DualPlaneGyroTiltedThinkingIndicatorView.layout()` tears down and rebuilds 12
  keyframe animations (~1,740 sampled values) on every zoom-induced layout.
  As a renderer-owned animation it is a compositor property driven by a stable
  clock: it keeps animating through the gesture at essentially no cost, which is
  *both* what the strict reading demands and a large win.
- **Terminal cursor blink and browser animation are free**, because I4 leaves
  both families in the residual plane where they behave exactly as today.
- **Semantic ingestion is unchanged.** Only visual application coalesces, which
  `AgentTranscriptUpdateScheduler` already does at 30 Hz, latest-wins,
  one-shot, pending-driven. No event is ever lost.

### What remains open

Not "may it be stale", which is settled — but the coalesce rate itself. 30 Hz is
today's number for a native apply; a fragment rasterise may afford more or
demand less. Doc 33's T9 still applies: observe real distributions before
pinning a constant.

```text
owns:        scene owns dirty regions and demand; producers own cadence and run
             off-main; AgentDocument owns truth
scales with: viewport pixels × coalesced rate × (dirty area / tile area)
streaming:   advancing content always advances; no size exemption
fidelity:    no visible freeze on anything that is moving
fails:       whole-tile surfaces would break the bound — fragment production is
             a correctness requirement here, not an optimisation
instead:     size-derived exemption (rejected by Dylan); freeze-all during
             gesture (rejected); uniform full-rate production (unnecessary)
kill:        fragment-level off-main production cannot hit the coalesce rate for
             a large focused streaming tile at zoom 1.0
status:      **approved** (I11). Coalesce rate open (T9).
```

## D-G — Camera lifecycle

```text
gesture begins   scene freezes its presentation set for the gesture;
                 producers switch to camera-priority scheduling
each commit      one root transform + chrome/overlay geometry + possible swap
                 to an already-prepared generation
reversal         prepared generations are cached by bucket, so reversing
                 re-uses rather than re-produces
settle           no global bake — the retained scene is already authoritative
                 for surfaced families; only residual-plane tiles bake
cold admission   see below
```

**No global settle bake** is the single biggest architectural advantage of a
retained resting authority over a gesture-only proxy, and it is worth being
explicit: the one-bake slope in doc 31 (15 ms at 5 agents → 138 ms at 50) is a
*gesture-only* architecture's tax, not a retained one's.

**Cold admission** (doc 32's D13): the proposal is *retain the previous complete
generation until the new one is complete*, with a low-resolution complete
envelope produced first. Concretely, for a teleport this means the old view
stays for a beat and then the new region appears complete — never a partially
filled canvas. This is a **[product]** decision about what that beat feels like.

## D-H — Memory

Real numbers from doc 29 on Dylan's workspace geometry: 14.1M world square
points; one full 2× copy ≈ 225 MB; overview demand at zoom 0.2 ≈ 9 MB; a
1600×1000@2× viewport is ~12.8 MB.

So **memory is not the frightening part** — a viewport plus 2× overscan plus one
adjacent bucket is tens of megabytes, and the existing byte-accounted LRU shape
handles it. The frightening part is **producer throughput** (C10) and
**transient replacement high-water** during rapid resolution changes. Both are
scheduling problems, and doc 33 already requires reporting them.

---

# Part VIII — Migration shape (not a schedule)

The property that makes this safe is that **the native tree stays as the
oracle** at every boundary, and each boundary can be extracted with the old path
still running:

```text
B1 extraction    produce TileRenderSnapshots from live state and assert they
                 round-trip: native render vs snapshot-derived render, pixel
                 and AX compared, while production still uses the native path
B2 extraction    produce TileSurfaces from snapshots and display them in a
                 probe window only; compare to cacheDisplay of the live tile
B3/B4            introduce surface hosts for ONE family as world-frame
                 children of the existing plane (Shape A), chrome first,
                 with every other family untouched beside it
B5/B6            promote/demote and AX for that one family, with the native
                 tile still installed as the comparison target
family migration each family moves independently; the residual plane holds
                 browser and terminal, so there is never a flag day
Shape B          the world plane retires only when the residual plane is empty
                 and the flat-tree traversal is proven to be the binding cost
```

Two things this buys that a rewrite does not:

- every intermediate state is shippable and reversible;
- doc 33's "reference renderer must be independent of the candidate" is
  satisfied structurally, because the reference *is* the shipping renderer.

The prerequisite that has to land before any of it: **one tile-geometry model**
(C7).

---

# Part IX — Failure and recovery

| event | required behaviour |
|---|---|
| WebContent crash | residual/native tile shows existing restart tile; scene unaffected |
| Ghostty surface loss | parked view retained; process/session survives; no scene hole |
| producer failure | last complete compatible surface stays visible; reason recorded |
| memory pressure | evict high-res children first, retain last-complete parents; never a hole |
| cache purge / device loss | cold-admission path (D-G), previous generation retained |
| display 1x↔2x, colour space, appearance | styleEpoch bump → hard invalidate, re-produce at new bucket; camera unaffected |
| workspace switch | old generation retained until the new one is complete |
| teardown | scene generation dropped atomically; pins released; no orphan surfaces |
| promotion failure | remain surfaced, log the reason, do not lose the event |

---

# Part X — Observability seams (architectural, not scheduled)

Doc 33 asks for counters; the design has to *place* them. Proposed seams, all of
which are cheap field increments on objects that already exist or are introduced
above:

- `CanvasCameraDriver` — inputs received / coalesced / discarded, desired vs
  committed revision (extend existing fields).
- `CanvasWorldPlaneView.qaBoundsSizeWriteCount` — already exists; becomes the
  primary forbidden-work counter for surfaced families.
- `PresentationScene` — spatial queries, visible/admitted chunks, coverage
  holes, bucket transitions with hysteresis, cache hit/miss/evict, byte
  accounting by class.
- Producer base — begin/end/cancel/supersede, dirty-vs-produced area,
  source-to-visible age, byte cost.
- `AgentBlockMeasurementCache` — already keyed correctly; add
  hit/miss/invalidate by cause.
- `InteractionBridge` — promote/demote/cancel, pin acquire/release by reason,
  promotion latency, first-event delivery count (must be exactly 1).
- `AXScene` — node create/remove/update, focus transitions, suppression events.
- `CanvasFrameRecorder` — retain raw intervals and attach camera/scene revision
  per interval (today it computes and discards).

---

# Part XI — Decision ledger

| id | decision | status |
|---|---|---|
| I1 | Body and chrome are separate presentations (Shape A: `setContentView`) | **approved** |
| I2 | Render description per-block for Array families, per-tile external | **load-bearing** (via I11) |
| I3 | Promote `AgentBlockMeasureKey` shape to the tile RevisionVector | provisional |
| I4 | Native residual plane for families without a proven producer | **approved** |
| I5 | Retained scene authoritative at rest and in motion | **approved**; slice 1 tried the narrower "native at rest" variant and measurement sent it back here (`.plans/36`) |
| I6 | Parking, never demounting, as the normal residency state | **approved + measured**; per-GESTURE parking refuted, see `.plans/36` |
| I7 | Exactly-once via side-effecting `hitTest` promotion | **shipped + witnessed** (`.plans/36`) |
| I8 | AX from `accessibility(block:context:)`, native tree as oracle | provisional |
| I9 | Per-tile surfaces above a projected-area threshold; pages below | provisional — deferred, culling is not on the critical path (see Part XI) |
| I10 | `Double` world model, camera-relative floats at the compositor | approved in principle |
| I11 | Streaming is streaming — animating content never freezes, no size exemption | **approved** |
| I12 | Generalise `ZoneHydrationOrchestrator` rather than replace it | provisional |
| I13 | Unify the two tile-geometry models as a prerequisite | provisional |
| I14 | Core Animation first; Metal only on identical-surface evidence | provisional |
| I15 | Shape A (scene-in-plane) first; Shape B when traversal binds | **approved + measured** |
| I16 | Display-list production and rasterisation run off the main actor | **required** (via I11) |

## What the approved decisions cost us, stated plainly

**I5** is the ambitious choice and buys the most: no global settle bake, no
mounted-view cost at rest, and the only shape with no tile ceiling. Its bill is
that accessibility, IME, selection and drag must be *earned* — they are not
consequences of the design, they are work with their own witnesses, and today
they come free from the very tree we stop mounting (C3).

**I4** is what makes I5 affordable: the two hardest producers leave the critical
path entirely, so the first credible end-to-end result needs neither a WebKit
snapshot fidelity study nor a Ghostty frame API.

**I15 (Shape A)** is what makes I5 *small*. Because a surface host is a
`TileNSView` subclass whose content view changed, the first migration touches
one tile class and nothing else — not the camera, not z-order, not hit testing,
not the install path, not chrome, not focus registration. The price is that the
camera is not yet `O(1)`; it is a flat-tree traversal, and its cost at realistic
installed counts is the thing that decides when Shape B becomes necessary.

**I11 (strict streaming)** is the tightest of the four, and it changed the
design
rather than just constraining it. It makes fragment-level, off-main production a
**correctness requirement** rather than an optimisation — which in turn promotes
I2 to load-bearing and adds I16. The arithmetic says it is affordable because
production is viewport-bounded, not tile-bounded, but that bound is only real if
(a) and (b) in D-F both hold.

## The one measurement that gated everything — ANSWERED 2026-08-18

All four approved decisions rested on one unmeasured quantity:

> What does a camera step cost when the world plane's children are flat
> layer-hosting surface hosts instead of deep native tiles?

`canvas.surface-host-slope` (`--perf-budget-surface-host-slope-check`, published
in `docs/internals/performance-budgets.md`) answers it. Three arms over one real
managed-agent fixture, every step a real production `CanvasCameraDriver` commit,
surfaces baked from the real tiles' own pixels one per host, zone chrome on,
gesture to zoom 0.2.

**Array-owned CPU per camera step (p50):**

| installed | native | unculled | culled |
|---:|---:|---:|---:|
| 5 | 9.64 ms | 0.08 ms | 0.08 ms |
| 15 | 29.00 ms | 0.09 ms | 0.09 ms |
| 25 | 50.45 ms | 0.13 ms | 0.10 ms |
| 50 | 111.78 ms | 0.27 ms | 0.10 ms |

`culledVsNativeRatio` 0.001. `culledDurationSlope` 0.029 ms over 5 → 50. The
native arm reproduces `.plans/31`'s published ladder, which is what makes the
rest admissible. **Shape A is confirmed.** [proven]

### Four things the run changed in this document

**1. Culling is not what buys it — replacing the BODY is.** The unculled arm
holds every host installed and still has a slope of only 0.190 ms over 5 → 50.
So at these counts the flat-tree traversal is nearly free, and I9's culling
threshold is a lever for much larger installed counts (where
`magnify-slope`'s ~2 ms per 112 shallow tiles lives), not a prerequisite. That
makes the first production slice smaller than Part VIII assumed: **a surface
host does not need the scene's presentation-set machinery to be worth
shipping.**

**2. Array CPU and the CA flush must be separate stages, or the result
inverts.** The first version of this witness reported one number per step and
read 119% over budget with a 13% late share — while Array's own camera work was
0.07 ms. The
whole signal was `CATransaction.flush()` blocking on the render server: flat at
~2 ms p50 / ~9–10 ms p95 across every count in the surface arms, and scaling
6.60 → 11.23 → 16.85 ms in the native arm because there is genuinely more to
commit. Doc 33's "never call a returning flush *presented*" is not pedantry; it
is the difference between confirming and rejecting this architecture.

**3. The `contentsScale` trap is real, and the mitigation works.** AppKit sends
`viewDidChangeBackingProperties` to every installed surface host on every camera
step — exactly `hosts x steps` (300 = 5 x 60, 1500 = 25 x 60). The host owns its
layer and applies a bucketed policy, so `cameraCausedRasterRequests` is 0;
`PERF_SURFACE_HOST_NAIVE_SCALE=1` drives it to 1,200 as the permanent negative
witness. Caveat recorded in the code: that arm is a witness about the DECISION,
not the cost. [proven]

**4. With the body gone, chrome is essentially all of Array's camera cost.**
Sweeping `ARRAY_CHROME_BUCKETS` at 25 tiles: 1 → 15 redraws / 0.08 ms p50;
4 (shipped) → 50 / 0.07 ms; 16 → 180 / 0.87 ms. So D-A's deferral of
screen-space chrome to Shape B is right for sequencing but chrome is now the
**whole** remaining Array-side lever. It also refuted my first hypothesis for
the step-time tail: more chrome crossings produced FEWER late steps, because the
tail was the flush and not the chrome.

**5. A parked live body costs nothing measurable, so I6 is settled and the
interim producer exists.** A fourth arm (`parked`) installs a surface host for
every tile AND keeps every real agent body alive in the window but outside
`CanvasWorldPlaneView`. Array-owned p50 is 0.07/0.11/0.17/**0.19** ms at
5/15/25/50 against 9.39/30.31/57.01/**140.57** ms native —
`parkedVsNativeRatio` 0.001, `parkedDurationSlope` 0.122 ms — and
`parkedVsUnculledRatio` is **0.824**, i.e. keeping fifty live agents laying out
and ingesting events beside the surfaces is inside the noise of the surfaces
alone. `parkedTranscriptLayouts` is exactly 0 at every count and in both ABBA
observations: a camera step cannot reach a body that is not under the world
plane. Three teeth stop that zero from meaning "the body died" —
`parkedStreamingCards` (the event became transcript content),
`parkedBakeColors` (`cacheDisplay` of a body clipped out of every draw still
yields 41 distinct colours), and `parkedStreamingPixelDelta` (a bake after the
event differs from one before by 6,867 bytes). Together: **the interim
`cacheDisplay` producer is available and affordable, so the first production
slice no longer waits on I2.** [proven]

The first attempt at that liveness tooth was wrong in an instructive way. It
counted `AgentTranscriptListView.qaLayoutPassCount`, which is the right signal
for a *camera* change and the wrong one for a *content* change: new content does
not move that view's own frame, so its `layout()` legitimately never runs, and
the counter read 0 for a body that was working perfectly. `enqueue` also gates
presentation at 30 Hz, so the model gains its card a frame before the view is
asked to show it. The pixel-delta form is narrower and is the property the
producer actually depends on. Recorded because "the counter said zero" was, for
an hour, about to become "parking kills streaming".

### What slice 1 measured, and what it cost the design

`.plans/36` built the first production slice: agent tile bodies as surfaces
while the camera moves, native at rest, behind a default-off flag. Two results.

**The mechanism holds in production.** 12 real agent tiles through the real
canvas, driver and tile views: Array CPU per camera step p50 **26.82 ms native
-> 0.17 ms surfaced**. The producer is pixel-exact against a native bake of the
same body at the same instant — mean channel difference **0.000**, and **1.156**
under the deliberate half-resolution injection, so the fidelity gate has teeth.
[proven]

**The residency POLICY does not.** Entering motion costs ~119 ms against a
native step's ~28 ms, on every gesture, twice per tile. The demote path is timed
per call and the cost is fully attributed, not inferred: host construction/reuse
0.00 ms, `setContentView` (removing the deep body) 2.03 ms/tile,
`park.addSubview` (re-adding it) 2.80 ms/tile. It is plain AppKit subtree
surgery with nothing of ours in between, so any policy that reparents per
gesture pays it twice per tile per gesture. Three hypotheses were measured and
REFUTED: a per-gesture `CALayer` texture upload (host retention moved it 0.1
ms), an empty `visibleRect` in the park (sizing the park changed nothing), and
the unconditional forced offscreen pass in `AgentTranscriptListView.layout()`
(gating it moved the native step 0.2 ms — those calls were already nearly free,
and the change was reverted rather than kept for no benefit). [proven, cause
included]

The consequence for this document: **I5's always-surfaced shape is not the risky
option, it is the affordable one.** Slice 1 deliberately narrowed to "native at
rest" because that shape has almost no UX discrepancy surface — and that is
exactly the shape that pays the reparenting bill per gesture rather than per
interaction. The discrepancy list in `.plans/36` therefore has to be earned item
by item (cursor rects, selection, IME, tooltips, AX/Q8, tree-walkers) rather
than avoided wholesale. The "unless the reparenting cost is removable" escape is
now closed: it is AppKit's own subtree cost, split evenly between remove and
add, measured per call.

### A production observation this surfaced, not fixed

`_installLayer` — the `setZones` path — never sets `tileView.canvas`. Only
`install(tileView:for:)` (CanvasNSView.swift:710) and `installProjectTile`
(:2736) do. With `canvas` nil, every chrome floor collapses to its unfloored
constant (`grabHeightInLocalCoordinates` → 24 instead of
`max(24, 28/bucket)`), so the zoom-dependent chrome refresh is a no-op and
`TileNSView`'s drag/resize paths that `guard let canvas` cannot run. The probe
found it because it measured 0 chrome redraws across a gesture that should cross
~9 buckets, and sets `view.canvas` itself. Whether production tiles restored
through `setZones` are affected is **not established** and is out of scope here
—
worth its own witness before anyone concludes anything.

# Part XII — Open questions

## Answered

- **Resting authority** → retained scene at rest and in motion (I5).
- **Browser/terminal** → native residual plane until producers exist (I4).
- **Gesture freshness** → animating content never freezes; strict reading, no
  size exemption (I11).
- **Scene shape** → Shape A, scene-in-plane, first (I15).

## Not blocking — defaults recorded, revisit when there is something to look at

The remaining three do not need answers to continue designing. Each has a
default that is either strictly better than today or discoverable from data, so
they are recorded here as *deferred with a stated default* rather than left
open.

### Q3 — Where does Array-owned rendering stop? → **discovered, not chosen**

The rule that makes this self-answering:

> Anything a user can do to a surfaced tile without promoting is
> renderer-owned. Everything else promotes.

So the design starts at the **minimum** — read-only surfaces, every interaction
promotes — and pulls work into the renderer only where promotion turns out to be
too frequent or too visible. That is a measurement, not an architecture choice,
and the measurement is `promotionLatency` plus promotion frequency.

There is even a version of it answerable **today, before any of this exists**: a
dogfood counter for how often a user interacts with a *non-focused* tile. If the
answer is "rarely, and always deliberately", promote-on-everything is fine and
Array never needs to own selection or scrolling. If wheel-over-an-unfocused-
transcript is common, renderer-owned scrolling moves up.

Default recorded: minimum renderer ownership (read-only surfaces + today's
native chrome), expand on evidence.

### Q4 — Cold region before complete → **default is already strictly better**

This only matters for teleport, workspace switch, and cache purge — never for
normal pan/zoom, which always has a last-complete parent.

And Array already has a behaviour here: `switchWorkspace` tears down and
rebuilds
tile views, so today a switch reveals tiles progressively and uncontrolledly.
**Retaining the previous complete scene until the new one is complete is
unambiguously better than that**, with no feel question attached. The only
genuinely open sub-question — whether the transition gets a fade, a spinner, or
nothing — is a visual detail best judged against a running build.

Default recorded: hold the previous complete generation, reveal the new one
complete, no transition treatment until there is something to look at.

### Q8 — Accessibility during the transition → **one fact decides it**

The fact: is anyone using Array with VoiceOver today? It is a friends alpha, so
the likely answer is no.

- If no: the gate is "AX parity before the retained scene becomes the default
  for a family", the flag defaults off, and transition risk is zero.
- If yes: the gate is stricter and `AXScene` has to lead rather than follow.

Either way it is a per-family ship gate, not a design blocker. The one design
consequence worth recording now: **which family first exercises the AX boundary
matters more than when.** Proving `AXScene` on a note tile or a Source file —
shallow, few nodes, easy to diff against the native tree — de-risks it far
better
than starting with an agent transcript, which is the hardest AX surface in the
app.

Default recorded: `AXScene` proven on the simplest family first; retained-scene
default-off per family until that family's AX diffs clean against its native
tree.

---

## What this document does not yet contain

Deliberately deferred until the questions above are answered:

- concrete type signatures beyond the sketches in Part V;
- the z-band algorithm for I4;
- the promotion/demotion timing policy constants;
- eviction ordering beyond doc 32's five-step sketch;
- anything resembling a phase, milestone, ticket, or estimate.

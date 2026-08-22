# 30 — Unbounded canvas rendering architecture handoff

Date: 2026-08-17

Repository state at handoff:

- branch: `array/integration`;
- HEAD: `ce493d276d7691bcd874ac1b1329f92dd7447454` (`Release Array 0.5.0`);
- `origin/main`, `origin/array/integration`, and local `main` point at that
  release commit;
- no source changes were made during this investigation;
- existing untracked planning/design files remain user-owned;
- `.plans/29-real-workspace-rendering-investigation.md` is the comprehensive
  research record and this file is the orientation/handoff.

Read first:

1. `.plans/29-real-workspace-rendering-investigation.md` — complete current
   investigation, architecture space, new hot spots, risks, references, and dive
   map.
2. `.plans/28-session-handoff-2026-08-17.md` — pre-release zoom attribution and
   measured native slopes.
3. `.plans/27-bounded-canvas-presentation.md` — historical presentation probes;
   its use of "bounded" must not be misread as a product tile limit.
4. `.plans/24-canvas-camera-unification.md` and
   `.plans/25-session-handoff-2026-08-14.md`, for the real AppKit stack and
   earlier evidence chain.

## Dylan's standing direction

- There is no desired product tile limit. Five/fifteen/twenty-five/fifty are
  measurement points, not supported-capacity ceilings.
- Projects may accumulate many zones and many more than fifty tiles. The
  architecture should be driven by spatial demand and viewport pixels, not
  total semantic tile count.
- Pan is already smooth. Zoom must feel comparably immediate.
- Every tile's real visual content must remain present while zooming. Synthetic
  shells, semantic summaries, missing browser/terminal bodies, or label-only
  substitutes are rejected.
- Do not confuse complete frozen pixels for a few seconds with fake summaries.
  Pixel completeness, resolution, freshness, and interaction remain separate
  contracts to discuss explicitly.
- Dylan wants to learn and co-architect, not merely receive a narrow finished
  recommendation. Keep the design space open, explain tradeoffs, and test
  ambitious alternatives rather than treating current AppKit constraints as a
  reason to give up.
- No implementation mechanism was authorized by the last discussion. Continue
  architecture/research and agree on experiments first.

## Production failure to reproduce

Released 0.5.0 can fall near 1 FPS while zooming Dylan's real workspace; pan
remains smooth. The saved layout corresponding to the screenshot contains:

- four expanded zones plus one unzoned tile;
- twenty tiles: twelve managed agents, six file tiles, one browser, one terminal;
- zone counts 5, 1, 11, 2, plus one unzoned agent;
- approximately 14.1M square world points of tile content;
- overview around zoom 0.2 with nearly the entire scene visible.

This is the minimum faithful baseline, not a stress case.

Previous fixtures did not reproduce it:

- `canvas.stress` had many agents but measured pan and omitted display/CA flush;
- `canvas.zoom` used cheap note/document shapes;
- geometry-hold used ten homogeneous six-turn agents;
- the synthetic layer proxy proved affine cost only and its shells were rejected;
- no fixture combines real zone topology, production-shaped agents/files,
  WKWebView, Ghostty, low overview zoom, live churn, Release, and multi-process
  profiling.

## Proven causal mechanism

Both pan and zoom use the display-paced unified `CanvasCameraDriver` and
`CanvasNSView.setViewport`.

- pan writes only `CanvasWorldPlaneView.bounds.origin`;
- zoom writes `bounds.size = viewportSize / zoom`.

The size write changes the ancestor points-to-pixels ratio. AppKit propagates
backing changes through every mounted native descendant, retiles scroll views,
revisits TextKit/collection layout/Auto Layout/stacks, redraws layers, and commits
the tree. Clipping does not remove descendants from this traversal.

Measured six-turn agent slope:

| agents | stepped p50 | stepped p95 | one bake | held p95 |
|---:|---:|---:|---:|---:|
| 5 | 15.29 ms | 19.46 ms | 14.56 ms | 0.12 ms |
| 10 | 30.50 ms | 36.23 ms | 28.05 ms | 0.07 ms |
| 25 | 72.46 ms | 110.86 ms | 70.79 ms | 0.02 ms |
| 50 | 132.72 ms | 210.26 ms | 137.89 ms | 0.06 ms |

Stepped writes caused one transcript layout per installed agent. Held geometry
caused none. One Array-owned root affine through fifty image layers measured
roughly 0.02-0.05 ms. Camera math is already cheap; native presentation is not.

The 1 FPS production result is not explained by the quiescent slope and remains
unapportioned.

## Important new local findings

Agent optimization should proceed as a parallel exact-UI workstream:

1. Active gyro indicator rebuilds 12 keyframe animations/~1,740 values per
   active agent per zoom-induced layout. This may be a major production-only
   amplifier.
2. Composer reruns TextKit layout/scroller/selection work on identity layouts.
3. Empty attachment/file rails retain scroll/collection/stack trees.
4. Hidden legacy status remains installed for test census.
5. Image cells cancel and re-request identical thumbnails on every ancestor
   backing callback despite unchanged window scale.
6. Transcript layout force-drives collection layout twice on every layout for an
   offscreen-fixture requirement.
7. Most renderers assign identical child frames without guards.
8. Collapsed command/reasoning bodies can retain and lay out hidden native trees.
9. visible transcript attribute lookup scans total history.
10. per-tile streaming presentation can collide with camera priority.

These fixes help zoom coefficient, resting CPU/memory, surface production,
promotion, and settle. They cannot make native bounds-stepping independent of
mounted tile count.

Non-agent unknowns:

- Markdown Preview may mount up to 400 semantic block/TextKit views; classify
  the six file tiles by Source/Preview and descendant/block count.
- Ghostty receives an unchanged content-scale call on every ancestor backing
  callback; build a no-op-same-scale A/B. Upstream uses view caching for drag
  images and an IOSurface Metal renderer, but a safe live frame API is absent.
- WKWebView cost may live in WebContent/GPU/WindowServer and was absent from the
  old app-only sample.
- four large translucent zone views may add raster/blending, probably secondary.
- explicit `visibleTileViews` O(N) scan is tiny at 20-50 but must not survive as
  a camera-hot-path principle for an unbounded renderer.

## Architecture space — do not collapse prematurely

### 1. Optimized native scene

Give native AppKit every legitimate chance through the exact agent/file/Ghostty
fixes, shallow/manual chrome, TextKit 2 viewport rendering, dormant subtree
removal, and redraw-policy probes. Allow it to win if faithful Release evidence
passes. Do not assume coefficient work changes the hierarchy propagation law.

### 2. Exact retained-surface Core Animation camera

Use versioned complete tile-body surfaces, compositor-owned chrome/zones, a
spatial scene index, resolution buckets/clipmaps, and one Array-owned root camera
transform. Native geometry remains fixed. This most directly matches Nyx and
Chromium's compositor behavior through supported macOS ownership.

### 3. Permanent surface scene plus native interaction views

Keep every semantic/visible tile without a product cap. Present all full-detail
pixels from the renderer. Materialize native views only for interaction and
state that actually requires AppKit/WebKit/Ghostty controls. This eliminates the
global settle bake. A native-residency budget is an internal cache analogous to
view recycling, never a visible tile limit.

Start with retained parked views to preserve state. True demounting requires
moving agent projection/disclosure/scroll, browser chrome/tab, terminal surface,
file mode/selection, and focus adapters out of NSView ownership.

### 4. Renderer-neutral tile snapshots and custom Array tile renderer

Extract `TileRenderSnapshot`/display-list data from `AgentDocument`, stable IDs,
presentation state, tokens, and actions. Keep native and new backends side by
side. Prototype TextKit 2 fragment layers/Core Graphics for a production-faithful
agent tile, with native composer/editor islands. This may remove capture cost,
native residency, and final-bake scaling for Array-owned content.

### 5. Metal

Metal image composition is justified only if Core Animation fails on the same
prebuilt exact surfaces. Full Metal content rendering remains a legitimate
larger architecture if Array wants Figma-class renderer ownership. Reuse the
semantic/runtime core; do not rewrite it. WebKit/Ghostty pixel sources,
interaction, IME, and accessibility remain separate problems.

### 6. Unlimited-world spatial rendering

Use spatial indexes, low-resolution complete overview parents, high-resolution
viewport/overscan chunks, dirty queues, resolution hysteresis, direction-aware
prefetch, and byte-accounted LRU. Camera frames operate on an immutable gesture
presentation set. Never allocate maximum-resolution copies of the entire world
or scan every semantic tile per tick.

The real layout is roughly 225 MB for one raw full 2x workspace copy but only
roughly 9 MB at overview screen demand. Resolution paging is essential.

## Interaction/AX constraints to carry forward

- A surface is presentation, never the transcript's semantic owner.
- Managed agent views cannot currently be destroyed safely; supervisor replay is
  capped at 500 and view-local state is extensive.
- The first wheel/click on a surface tile must promote/reveal native interaction
  and deliver that initiating event exactly once.
- Focus, IME, selection/drag, browser/terminal responder, modal/popover, and AX
  focus pin native state.
- Arbitrary overlaps make native-island z-order hard; explore one frontmost
  island, z bands/replicas, masks, or renderer-native interaction.
- Pixels have no automatic accessibility. A permanent renderer needs stable
  semantic AX proxies/mirror geometry or an explicit native-at-rest/settle
  policy for assistive interaction.
- Do not hide a smooth motion result behind a 100-1000 ms final native bake.
- Main-thread streaming/capture can starve even a cheap compositor transform;
  camera/local input must outrank background presentation production.

## Where to dive next

1. Build the privacy-safe saved-layout census/export and faithful Release F0
   fixture. Reproduce the 1 FPS feel before judging architectures.
2. Add counters and run isolated active-gyro, composer, image, hidden-tree,
   collapsed-body, and forced-layout A/Bs.
3. Apportion files/WK/Ghostty/zones using live versus pixel-identical captured
   arms; profile Array, WebContent/GPU, and WindowServer together.
4. Prove exact surface acquisition/freshness/latency independently for AppKit,
   WKWebView, and Ghostty.
5. Simulate/measure resolution-paged cache coverage and memory on the real world
   geometry, including cold start, reversal, backing/appearance changes, and
   pressure.
6. Replace the rejected shells in the cost probe with exact prebuilt surfaces and
   test CA camera-only motion at 20/50/100/500 chunks.
7. Prototype the permanent scene and one native interaction transition:
   transcript first wheel, exact geometry/pixels, state preserved, no global
   bake.
8. Prototype one complete renderer-neutral heavy agent tile with native and
   TextKit 2/CG backends.
9. Compare CA/Metal only with identical surfaces if CA itself misses.
10. Red-team streaming agents, terminal output, animated browsers, arbitrary
    overlaps, IME, drag/drop, VoiceOver, 60/120 Hz, memory pressure, and long
    soak.

## Explored/rejected versus merely unproven

Rejected by evidence or platform contract:

- synthetic shells/summaries/missing content;
- direct transform or reparenting of AppKit-owned backing layers;
- native NSView subtrees inside a layer-hosting view;
- `NSScrollView` magnification (same real-tree cascade);
- synchronous whole-viewport capture at pinch start;
- camera coalescing/quantization/glide tuning as the root fix;
- assuming Metal alone fixes content production.

Unproven and still open:

- how far exact agent/file/native fixes move the real F0 workspace;
- exact AppKit surface capture under rich live states;
- WK snapshot fidelity for animated/accelerated content;
- Ghostty exact capture and supported live frame export;
- whole-viewport sheet versus per-tile/page/zone clipmap organization;
- permanent compositor/native interaction semantics;
- custom TextKit 2/CoreText/CG agent renderer;
- Core Animation versus Metal at exact production surface scale;
- full retained renderer migration.

## Paste-ready continuation prompt

```text
Handoff: continue the unbounded Array canvas rendering architecture investigation.

Read first:
  .plans/30-session-handoff-2026-08-17-unbounded-canvas.md
  .plans/29-real-workspace-rendering-investigation.md
Then read .plans/28, .plans/27, .plans/25, and .plans/24 for the evidence chain.

Repository: /Users/dylan/Documents/personal/Array
Branch/HEAD at handoff: array/integration @ ce493d2 (released Array 0.5.0).
No source changes were made in the latest research; preserve unrelated untracked
planning/design files.

Product direction: do not impose a tile-count limit. The 5/15/25/50 cells are
measurement points, not capacity ceilings. All real tile detail must remain visible
during zoom; synthetic shells/summaries are rejected. Pan is smooth, released zoom
can fall near 1 FPS on the real 4-zone/20-tile layout, and Dylan wants to learn and
co-architect an ambitious solution rather than prematurely narrow the design.

Proven mechanism: per-frame CanvasWorldPlaneView.bounds.size changes trigger an
AppKit backing/layout/raster cascade through every mounted native descendant. Held
native geometry removes ~98.5% of the measured 10-agent gesture cost; one owned root
affine is ~0.02-0.05 ms through 50 image layers. The quiescent agent fixture does not
explain the real 1 FPS workspace.

New hot spots to investigate immediately: active gyro animation graph rebuilt on
every zoom-induced layout; composer TextKit remeasured on identity layouts; hidden
attachment/file rails and legacy status subtrees; identical image thumbnail reloads
on unchanged backing scale; transcript double forced-layout; collapsed hidden bodies;
unguarded renderer frame writes; O(total-history) attribute filtering; streaming UI
application overlapping camera priority. Also isolate Markdown Preview, WKWebView,
Ghostty same-scale callbacks, zone chrome, WebContent/GPU, and WindowServer.

Keep the architecture space open:
  1. radically optimized native tiles;
  2. exact retained-surface Core Animation camera;
  3. permanent detailed surface scene with demand-native interaction views;
  4. renderer-neutral TileRenderSnapshot/display-list boundary;
  5. custom TextKit 2/Core Graphics agent/file renderer;
  6. Metal image compositor or full retained renderer if earned by evidence;
  7. spatial indexes, clipmaps/resolution buckets, dirty queues, and unlimited
     semantic tiles driven by viewport pixel demand.

Nyx is now in the comparison set: its changelog attributes smooth canvas motion to
eliminating whole-area repaint, temporal GPU promotion, memoized tile/webview updates,
and xterm reflow tolerance. It supports the combination of local tile optimization
plus compositor-owned motion, not a claim that deep UI relayout is cheap.

Do not implement a mechanism before a faithful Release reproduction and exact source
probes, but do not treat current AppKit architecture as the boundary of what Array can
become. Explain alternatives and tradeoffs to Dylan, identify what evidence would kill
or validate each, and stay constructive/ambitious. The next best concrete work is the
privacy-safe real-layout census/fixture plus active-agent/non-agent attribution, then
exact surface-source and renderer prototypes.
```

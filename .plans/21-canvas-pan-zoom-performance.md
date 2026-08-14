# 21 — Canvas pan/zoom performance

Status: **TOLERANT CAMERA GUARD LANDED, WITNESSED AT FRACTIONAL ZOOM.** The
exact-compare defect in the committed pan guard is fixed and gated by the new
`canvas.fractional-pan` matrix leg (RED at 1440 bounds writes under exact
equality, GREEN at 0 with the tolerance); `canvas.stress` (opt-in) maps the
scaling curve and keeps the missing presentation-working-set bound visible as
a known-red product target. The staged structural plan (retained world plane,
streaming, LOD) is `.plans/22` and awaits approval.
A standing performance-budget framework now exists:
[docs/internals/performance-budgets.md](../docs/internals/performance-budgets.md).
The scalability witnesses and staged plan are in
[docs/internals/scalability-tdd.md](../docs/internals/scalability-tdd.md).
The primary-source Figma/game/map/Apple research and escalation criteria are in
[docs/internals/infinite-canvas-rendering-research.md](../docs/internals/infinite-canvas-rendering-research.md).

## Second-pass correction (2026-08-13)

The original investigation found a real camera defect, but it mixed a static
camera microbenchmark with broader claims about agent-tile scalability. Preserve
the measurements below as history, with these corrections:

- The exact-comparison version in commit `347c169` is not the pan fix at zooms
  other than 1. The tolerant comparison currently in the worktree is the version
  that changes `stress.boundsWrites` from 2,880 to zero.
- The observed scaling curve is synchronous AppKit/layout throughput on one
  reference Mac. It is not a presented-frame trace and does not establish M2 Air
  ceilings. The proposed 30/48/64 limits were extrapolations, not measurements.
- Transcript depth is nearly free only for the static pan loop. Live streaming
  repeatedly scans and reconstructs the complete transcript, including an empty
  patch followed by flatten/diff/snapshot work, full image discovery, growing
  Markdown reparsing, and per-event stable-UI/timer churn.
- Offscreen tiles continue presentation scheduling, timers, animations, and tool
  work because being attached to a window is treated as visibility.
- Directly changing `CanvasNSView.bounds.origin` is unsafe: the view contains
  both world-attached content and screen-fixed overlays, and several gesture,
  visibility, HUD, and hit-test paths assume an origin-zero screen coordinate
  space. The retained-camera seam should be a nested world-content/clip view plus
  a separate screen-overlay plane.
- Restore materializes every tile before the first window is shown and launches
  transcript hydration without a global concurrency limit. Browser pop-up and
  controller-close paths also lack complete runtime registration/teardown.
- The current harness is valuable for deterministic work counts, but its timing
  fixtures omit production delegate churn, real input, drawing, CA commit and
  presentation. Its frame recorder also cannot yet support a shipping-FPS claim.

### Revised outcome

The goal is not a fixed maximum tile count. It is three bounded scaling
contracts:

1. Camera geometry is independent of total installed tiles.
2. Streaming work is proportional to the delta and changed visible rows, not
   transcript history.
3. Offscreen presentation is dormant while semantic state remains current.

Memory and compositor work still scale with admitted active surfaces and visible
pixels. Those costs must be bounded rather than described as literally constant.

### Rough sequence

1. Make the existing harness production-equivalent enough to trust and add
   deterministic counters for the missing scaling axes.
2. Publish dual gates: an accepted-baseline ceiling that cannot regress and a
   separate known-red product target.
3. Land the tolerant camera guard and the unbounded announcement-retain fix with
   teeth tests.
4. Introduce the nested retained world plane and prove one camera mutation with
   zero per-tile geometry writes.
5. Preserve reducer patches and make transcript rows, Markdown, images, and tool
   details incremental.
6. Add an explicit presentation-active lifecycle for offscreen/overview tiles.
7. Bound restore concurrency and close the browser/terminal ownership gaps.
8. Reduce common tile-tree cost, consolidate timers, then validate Release builds
   on real M2 Air 8 GB/16 GB and ProMotion hardware.

No code change should begin without a red witness for its intended complexity or
ownership property. Each stable improvement lowers the accepted regression
ceiling; existing debt remains visible against the independent product target.

## Infinite-canvas research addendum (2026-08-14)

Figma is not evidence that Chrome can cheaply host an unbounded tree of ordinary
interactive views. Figma built a retained tile-based GPU renderer and its own
scene graph, compositor, text layout, and later accessibility mirror. Its more
immediately transferable ideas are dynamic dependency-aware loading, windowed
derived computation, time-sliced work, device-specific testing, and a strict
baseline comparison.

tldraw, map renderers, and game engines add the missing presentation strategy:
spatially select a bounded working set, stabilize zoom-dependent detail during a
gesture, and replace detailed objects with progressively cheaper summaries or
zone/chunk HLOD at overview scale. Viewport culling alone is insufficient because
zooming out eventually makes the whole workspace visible.

Array already has useful seams: `ReadabilityPolicy`, `HydrationTier`,
`ZoneHydrationOrchestrator`, `CanvasEntityIndex`, browser snapshot views, Ghostty
snapshot occlusion, supervisor-owned agent semantics, and centralized
`FocusBroker`. They are not wired into one presentation system today. In
particular, hydration is largely browser-only, readability bands do not change
production rendering, cold zones lack a complete cold-to-live path, and agent
view `detach()` stops semantic event delivery.

Do not combine everything into one tier enum. Plan four independent axes:

1. semantic activity;
2. heavyweight resource residency;
3. visual presentation LOD;
4. focus/drag/modal/accessibility pins.

The evidence-gated escalation ladder is now:

1. **Render truth:** real Release traces on the M2 Air, actual display cadence,
   and commit/render separation.
2. **Bounded AppKit experiments:** explicit clipping, display-paced camera
   submission, presentation-only timer/animation gating, and a narrow cached
   redraw-policy zoom experiment.
3. **Retained camera:** fixed viewport, clipped world document plane, and sibling
   screen overlay. Do not transform an AppKit-owned backing layer directly.
4. **Bounded presentation:** real readability LOD, spatial working set,
   velocity-aware preload halo, focus/AX pins, kind-specific browser/terminal/
   agent resource policy, and view-independent navigation.
5. **Overview HLOD:** zone/coarse-chunk summaries with bounded preview caches and
   native interactive islands.
6. **Hybrid GPU overview:** Metal/Core Animation only if the bounded AppKit/HLOD
   design still misses the M2 Air target and profiles identify overview drawing
   or GPU submission as the remaining bottleneck.

This explicitly rejects blanket `isHidden`, rasterizing every live tile, one
workspace-sized batch, a fixed 60 Hz camera tick, raw transforms on AppKit-owned
layers, and Metal as a substitute for fixing transcript scans or WebKit memory.

## Outcome (2026-08-13)

**What the profile said.** The hypothesis was half right, and the half that was
wrong mattered.

- Pan was never the expensive gesture: **0.36 ms/step** over 12 tiles, 4% of a
  120 Hz frame, even before the fix. It was doing 1440 pointless bounds writes
  and 1440 pointless model writes, but they were cheap because a pan changes
  only the frame ORIGIN.
- Zoom is the whole problem: **32 ms/step**, ~4x over budget, and **5474 prose
  re-measurements** where pan does zero. A `sample` of the zoom loop put
  **11,454 of ~11,965** main-thread samples inside
  `-[NSView _layoutSubtreeWithOldSize:]`.
- Hypothesis 3 was right about the symptom but wrong about the cause. Zoom does
  thrash the width-keyed caches — but not because the tile's logical width
  changes (it never does). `setFrameSize` scales `bounds` along with the frame,
  so the logical size must be written back, and the subtree is laid out twice
  per tile per step at an intermediate width it never renders at.
- Hypothesis 2 (culling) was not needed: at 12 tiles the pan pass is 4% of
  budget. Culling would attack a cost that is not there.

**What was fixed.** `applyTileGeometry` writes only what changed and moves origin
and size separately, so a pan performs no subtree layout at all. `canvas.pan` is
green and gating; teeth-tested by reverting the guard (PASS -> FAIL at 1440
bounds writes / 1080 model writes).

**What was NOT achieved.** Zoom. Guarding cannot remove its second geometry
write, because after a size change the bounds restore is genuinely needed.
Suppressing `autoresizesSubviews` across the pair was tried and made it worse
(61.7 ms/step, 12,075 measurements). The remaining fix is candidate 6 below: the
camera must stop resizing tile views and scale the canvas's own coordinate
system instead. `--perf-budget-zoom-check` is in `MATRIX_KNOWN_RED` so the number
is published on every run without masking a pan regression.

**Not measured:** a live 120 Hz frame trace of a real ZOOM gesture. The frame
recorder works end-to-end on a real pan; synthetic Cmd+scroll does not drive the
zoom branch, so that number needs a human hand on the trackpad.

## Stress testing changed the answer (same day)

The above was measured at 12 tiles in one zone at zoom 1.0, and that scenario was
**too small and too zoomed-in to be honest**. Adding `canvas.stress` — 48 real
managed-agent tiles with real transcripts across 6 real `ZoneLayer`s at zoom
0.35 — found a defect the green scenario could not see:

**The `!=` in the "skip unchanged writes" guard is silently useless at any zoom
other than 1.** AppKit keeps the bounds/frame SCALE and recomputes bounds from
it, so `420` reads back as `420.00000000000006`. The guard therefore rewrote
bounds for every tile on every step, and each write re-marked that tile's entire
subtree — worse than shipping no guard at all.

- 48 agent tiles, zoom 0.35, pan: **39.9 ms/step -> 5.4 ms/step (7.4x)** once the
  comparison used a tolerance below one device pixel.
- `stress.boundsWrites`: 2880 -> 0.

The reference scaling curve, the static-pan transcript-depth sweep, and where the
measured time goes (inside AppKit's `_layoutSubtreeWithOldSize:` recursion,
almost none in Array's own code) are documented in
[docs/internals/performance-budgets.md](../docs/internals/performance-budgets.md).

**Historical next step:** this pass originally proposed culling off-screen
geometry. The second pass above supersedes that recommendation with the nested
world plane and presentation-lifecycle work. `stress.tilesLaidOutPerStep` remains
useful evidence about the old geometry path, not the target architecture.

---

Original brief follows.

Status: **INVESTIGATION — nothing implemented, hypothesis unverified**

Owner: a fresh agent. This file is the whole brief; you should not need the
session it came from.

## The report

Dylan, power-using 0.4.18 (build 24) on `~/Documents/personal`:

> "it's a little laggy zooming around rn"
> "i gravely need to improve overall performance when using the canvas... it is
> very laggy when panning and zooming"

Target: hold **60fps** during pan and zoom on a real working canvas. **120fps**
is the stated ideal (ProMotion — every frame must land in 8.3ms).

Ship target: **0.4.19, build 25**, alongside two commits already on
`array/integration` (`882316d` file attachments, `dbc9f05` self-hosting guard).
Runbook is [RELEASE.md](../RELEASE.md).

## What is already measured — do not re-derive

All of this was taken on the live production app (pid 1473, 0.4.18 build 24)
while Dylan was working. Facts, with how they were obtained:

| Fact | Evidence |
|---|---|
| The app is **completely idle at rest** | `sample <pid> 6` — main thread in `mach_msg2_trap` for **5318 of 5318** samples. The cost is entirely inside the gesture. |
| Not thermally throttled | `pmset -g therm` — no thermal or performance warning level recorded. A hot-bag incident that day was a red herring. |
| Overall CPU is healthy at rest | 6m42s cumulative CPU over 46m33s wall (~14% of one core), 356 MB RSS, 13 threads. |
| **There is no frame instrumentation anywhere** | `grep -rn "CADisplayLink\|CVDisplayLink\|frameDuration" Sources/ContinuumRevived/` → **zero hits**. Nothing in the app measures frame time, so no change can currently be proven to help. |
| Browser tiles are live | the sample shows a `WebCore: Scrolling` thread. |

**The `%CPU` trap:** the FIRST sample from `ps -o %cpu` or `top` is a
since-launch average and will read ~90% on a long-lived process. It is an
artifact. Use `ps -o time=` (cumulative CPU) or the SECOND `top -l 2` sample.
This nearly produced a false "spike" finding.

## The code path (read, not guessed)

`CanvasNSView.setViewport(_:)` runs on **every camera step** — every pan
increment, every zoom increment:

```swift
func setViewport(_ viewport: CanvasViewport) {
    canvasState.viewport = viewport
    // "Camera movement should reposition/scale existing tile layers, not mark
    //  every tile's content dirty."
    layoutAllTiles(invalidateTileDisplay: false)
    discardCursorRects()
    window?.invalidateCursorRects(for: self)
    delegate?.canvasDidChange(self)
}
```

`layoutAllTiles` iterates **every tile in the flat collection AND every tile in
every `ZoneLayer`**, plus zone chrome and the nav overlay:

```swift
private func layoutAllTiles(invalidateTileDisplay: Bool = true) {
    layoutZoneChromeViews()
    for tile in canvasState.tiles { layoutTile(tile, ...) }
    for layer in zoneLayers {
        for tile in layer.tiles { _layoutLayerTile(tile, in: layer, ...) }
        if let chrome = layer.chrome { chrome.frame = ...; chrome.needsDisplay = true }
    }
    navModeOverlayView?.needsDisplay = true
}
```

and `layoutTile` assigns unconditionally, per tile, per frame:

```swift
let rect = CanvasEngine.tileScreenFrame(tile.frame, viewport: canvasState.viewport)
view.isHidden = membershipPlacement(of: tile.id)?.collapsed == true
view.frame  = rect                                             // scaled screen rect
view.bounds = NSRect(0, 0, tile.frame.width, tile.frame.height) // logical size
view.tile   = tile
```

Note the design is *right in spirit*: `bounds` stays at the tile's logical size
while `frame` carries the scaled screen rect, so AppKit does the zoom scaling.
`invalidateTileDisplay: false` deliberately avoids dirtying content.

## Hypothesis — UNVERIFIED, test it before writing code

Three suspected costs, in order of confidence:

1. **Unchanged assignments still cost.** During a *pan*, `view.bounds` is
   assigned the same value every frame and `view.tile` is re-assigned every
   frame. Assigning an unchanged frame still marks a view `needsLayout` and
   makes it re-measure — **this exact bug, one level down, was 0.4.17**:
   `AssistantProseView.layout()` re-assigning unchanged text-view frames took
   the app to 98.6% CPU, and `if pair.1.frame != frame { pair.1.frame = frame }`
   took it to 0%. See the 0.4.17 row in [docs/VERSIONING.md](../docs/VERSIONING.md).
2. **No culling.** Every tile is laid out whether or not it is on screen. Cost
   is O(all tiles), and Dylan's canvas is large (51 agent records exist).
3. **Zoom misses every measurement cache.** The caches added in 0.4.16
   (`FileMarkdownDocumentView` block heights) and 0.4.17
   (`AssistantProseRenderer` row heights) are **keyed by width**. Panning keeps
   width constant so they hit; **zooming changes width every frame, so every
   frame is a total cache miss and a full text re-measure** — attributed-string
   rebuilds, TextKit glyph bounds. This predicts zoom being materially worse
   than pan, and worse still with agent/markdown tiles on screen.

Secondary suspects: `discardCursorRects()` + `invalidateCursorRects` per camera
step; zone chrome and nav overlay `needsDisplay = true` per step.

## FIRST TASK — measure a real gesture

Do this before writing any production code. Two failed diagnoses on 2026-08-12
came from reasoning about plausible causes instead of reading a profile; the
profile named the exact method in seconds, twice. The order is documented in
[docs/internals/performance.md](../docs/internals/performance.md).

Ask Dylan to pan and zoom continuously for ~20s, and during it:

```sh
P=$(pgrep -f "Array.app/Contents/MacOS/Array" | head -1)
sample $P 20 -file /tmp/canvas-gesture.txt
```

Then read the **main thread** tree (`DispatchQueue_1: com.apple.main-thread`).
What you are looking for:

- `layoutAllTiles` / `layoutTile` / `_layoutLayerTile` frame counts;
- anything under them that measures text — `AssistantProseRenderer.measure`,
  `AgentTextStyleResolver.append`, `CodeTextView.measuredCodeSize`,
  `_boundingRectForGlyphRange`, `replacingOccurrences`;
- `invalidateCursorRects` / `discardCursorRects`;
- WebKit/browser work triggered by resize.

If the stack does not implicate `layoutAllTiles`, **the hypothesis above is
wrong — say so and follow the profile instead.** Reporting a failed theory is a
result, not a setback.

Prefer profiling the **dev app** (`~/Desktop/Array Dev.app` on
`~/array-scratch`) once you can reproduce it there, so you are not dependent on
Dylan's working session. Reproduce with a canvas holding several agent tiles and
at least one Markdown file tile — the expensive content is the point.

## Candidate fixes, cheapest first

Do not do all of these. Measure, then take the smallest set that moves the
number.

1. **Skip unchanged assignments** in `layoutTile` / `_layoutLayerTile`:
   `if view.frame != rect { view.frame = rect }`, same for `bounds`, and avoid
   re-assigning `view.tile` when it is unchanged. Mirrors the 0.4.17 fix.
2. **Cull off-screen tiles** — skip layout for tiles whose screen frame does not
   intersect the canvas bounds. Watch the correctness edge: a culled tile must
   still be laid out when it scrolls back in, and `isHidden` bookkeeping must
   stay right.
3. **Coalesce cursor-rect invalidation** to gesture end rather than per step.
4. **Rasterize heavy tiles during a gesture** — `layer.shouldRasterize = true`
   on entry, `false` on settle. GPU scales a bitmap instead of re-laying-out
   content. Reversible, and the standard trick.
5. **Quantize the measurement cache key** (or key by content and scale the
   result) so a zoom does not thrash `AssistantProseRenderer` /
   `FileMarkdownDocumentView`.
6. **The real architecture, if the above is not enough:** do not re-layout
   content during a gesture at all. Lay tiles out once at logical size, apply
   zoom as a transform on the canvas container layer (GPU compositing, constant
   cost), and re-layout once when the gesture settles. This is what every canvas
   app converges on. It is a project, not a patch — scope it separately if the
   cheap wins land under 16.7ms.

## The witness standard

**Counts, not stopwatches.** A wall-clock assertion on a shared laptop is a
flake generator; a count is deterministic. The precedent is
`--file-markdown-perf-check`, which asserts *"20 relayouts at an unchanged width
cost ZERO prose row measurements"* — RED at 241, GREEN at 0. Use QA counters in
the same shape as `AssistantProseRenderer.qaMeasurementCount`.

Assertions worth writing:

- N pan steps at constant zoom cost **zero** `bounds` assignments and zero text
  measurements.
- Tiles outside the viewport are **not** laid out during a camera step.
- A zoom step measures at most once per tile per distinct width, not once per
  frame.

Consider also landing **frame instrumentation** (a `CADisplayLink` recording
frame intervals behind a debug flag). Without it, nobody can answer "are we at
60?" — which is the question that started this. That is arguably the most
valuable single artifact of this work.

Register any new `--*-check` flag in `scripts/run-matrix.sh` **and** the
committed inventory (`docs/38-tickets/90-agent-ux/matrix-inventory.txt`), then
confirm from the matrix's end-of-run summary that your leg actually ran.

## Hard constraints

- **Never rebuild, quit, or point anything at `/Applications/Array.app`.** That
  is Dylan's live workspace on `~/Documents/personal`. Use
  `scripts/dev-app.sh` (~16s, debug) driving `~/Desktop/Array Dev.app` on
  `~/array-scratch`.
- **Never run `scripts/run-matrix.sh` or `ContinuumRevivedCoreChecks` while
  Dylan is using Array** unless you supply an isolated tmux namespace. Three
  CoreChecks sections plus one app leg drive a REAL tmux server; on the default
  socket that kills his terminal tiles, which closes the last window, which
  quits the app — a clean exit with no crash report. It happened twice on
  2026-08-12. As of 0.4.18 they share a fail-closed gate (`TmuxIsolation`) and
  `run-matrix.sh` exports a disposable `TMUX_TMPDIR`, but confirm rather than
  assume. See the AGENTS.md section "Never touch the live tmux server from
  automated checks".
- Debug builds only while iterating. `--configuration release` is
  whole-module optimization: ~6 minutes per edit.
- Never `CONTINUUM_UPDATE_BASELINES=1`.
- Do not touch `AgentRadialContextMeterView.swift`, and do not disturb
  `.plans/17`, `.plans/18`, `.plans/19`, `.plans/20` or
  `docs/internals/iteration-time.md` — all untracked, all owned elsewhere.

## Out of scope

- `.plans/18` center-aware tile spawning (placement, not frame rate)
- `.plans/19` context clearing/compaction
- `.plans/20` directional navigation presets
- Any camera animation, auto-layout, or tile rearrangement

## Definition of done

1. A profile of a real gesture naming the actual cost, reported before any fix.
2. A fix whose witness is RED before and GREEN after, teeth-tested by reverting
   the fix and watching the check fail.
3. Frame-time evidence that pan and zoom hold 60fps on a representative canvas
   (several agent tiles + a Markdown tile), with the measurement method stated.
4. A dogfood observation in `~/Desktop/Array Dev.app`, reported **separately**
   from the automated checks. A green count check alone does not prove the
   gesture feels better.
5. An honest statement of what was NOT achieved — particularly if 120fps is out
   of reach without the layer-transform architecture.

# 22 — Canvas scalability implementation plan

Status: **SLICE 1′ AND SLICE 3 LANDED AND COMPLETE.** `canvas.zoom` is now
gating-green at 4.7 ms/step: the retained world plane removed the camera's
per-tile cost, and decoupling the content inset from the chrome floor removed the
second cause it exposed. `--perf-budget-zoom-check` has left `MATRIX_KNOWN_RED`,
which is back to its 7 pre-existing entries. Stage 0 (the tolerant camera guard with its fractional-zoom witness,
the opt-in `canvas.stress` scenario, and the two ownership-leak fixes) landed
ahead of this plan. Slices 4–8 still reshape transcript streaming or the
presentation lifecycle and do not begin until Dylan approves each one.

## Slice 3 landed (2026-08-14) — and split canvas.zoom's cause in two

`CanvasNSView` is now a fixed viewport over a clipped `CanvasWorldPlaneView`
whose bounds carry the camera, with screen-fixed overlays as siblings. Tiles and
zone chrome hold world frames a camera step never touches.

**Delivered against the exit criteria:**

| criterion | result |
|---|---|
| camera work flat vs installed tiles | `camera-slope.writeSlope` 218.4 → **0** |
| one camera mutation per step | `cameraMutations` 0 → **320/320** |
| zero per-tile geometry writes | 18,720 → **0** |
| `canvas.zoom` boundsWrites | 1,440 → **0** |
| `stress.tilesLaidOutPerStep` | 48 → **0** |
| hit-test / z-order / focus / spawn oracles | all green |
| `--perf-budget-camera-slope-check` off KNOWN-RED | done |
| `--perf-budget-zoom-check` off KNOWN-RED | done, in a follow-up — see below |

**The exit criterion that needed a second fix.** Removing the camera's per-tile
cost exposed a second, independent cause of zoom expense hidden underneath it:
a tile's chrome floors are `max(worldConstant, screenPx / zoom)`, and
`contentTopInsetWorldHeight` was aliased to that floor, so the tile's content
re-framed and reflowed on every step. 49.1 ms/step and 14,490 prose measurements
with `boundsWrites` at zero — the same symptom, a different disease.

Dylan chose the decoupling over quantising the floor, and it landed on
2026-08-14: `contentTopInsetWorldHeight` is now the unfloored `titleBarHeight`,
so an enlarged low-zoom grab strip overlays the top of the body rather than
pushing it down. **49.1 → 4.7 ms/step, 14,490 → 0 prose measurements**, with the
chrome floors themselves untouched. `--perf-budget-zoom-check` left
`MATRIX_KNOWN_RED` in the same commit that turned it green.

Two things that surfaced doing it, both worth keeping:

- **The floor is active far more often than "when zoomed out" suggests.**
  `minScreenGrabPx` (28) exceeds `titleBarHeight` (24), so it binds for every
  zoom below **1.167** — the whole 0.4–1.0 fixture sweep, not an edge case.
- **Two more witnesses encoded the implementation rather than the property.**
  `--tile-chrome-scale-check` and `--tile-world-bounds-check` both asserted
  `contentTop == flooredBarHeight` and so failed a correct canvas, exactly like
  the `frameWrites >= 1` anti-teeth did in Slice 3. They now assert
  zoom-invariance of the body's top (measured across the sweep from laid-out
  views, not re-derived), that the bar always reaches the body, and that a zoom
  never calls `setFrameSize` on a body — the last unconditionally, where it
  previously held only while the floor happened to sit still.

Quantising the floor into zoom buckets with hysteresis remains the right move
later, as part of Slice 5's LOD work where hysteresis belongs anyway.

**A second measured tradeoff, recorded not smoothed.** The `canvas.stress` pan
duration regressed from ~5.4–6.0 to ~7.4–9.3 ms/step even though every work
count went to zero. A `sample` puts 131 of 5,588 samples in the camera and the
rest in AppKit recursing `_layoutSubtreeWithOldSize:` through 48 deep agent-tile
trees, with no Array frames at the leaves. Any camera write on an ancestor
triggers that traversal: 0.001 ms/step with the write removed entirely, 7.2 ms
via `setBoundsOrigin`, 8.2 ms with a nested content view, 8.8 ms translating by
frame origin. Reducing it means fewer and shallower mounted tile trees — Slice 5.

## Slice 1 was deliberately narrowed (2026-08-14)

Dylan chose the canvas-zoom axis, so Slice 1 shipped as **Slice 1′: the camera
witnesses only.** Recorded here rather than silently shrunk:

- **Cut:** the transcript counters (rows visited, snapshots rebuilt, Markdown
  bytes reparsed) and the 100/10,000-row delta fixtures. They duplicate the
  parallel performance-framework program's Phase 7, which specifies them more
  fully (fail-closed baseline records, `knownRedAgainstTarget` instead of a new
  `MATRIX_KNOWN_RED` entry). Whichever program owns the harness owns them; this
  one must not build them twice.
- **Cut:** the offscreen-presentation fixtures. They belong to Slice 5, which is
  not approved.
- **Kept and landed:** `CameraLayoutStats.cameraMutations`; the gating
  `canvas.camera-slope` scenario (installed 16→128, visible count held at 12,
  zoom 1.0 and 0.35) under its own `--perf-budget-camera-slope-check` leg name so
  it cannot mask a pan regression; and `--canvas-camera-hit-oracle-check`, the
  model-vs-installed-geometry oracle recorded while the pre-plane code is still
  the reference.
- **Not adopted:** an accepted-baseline *record* mechanism. Slice 1 originally
  implied one; the perf-framework program's Phase 2 specifies it properly, so
  these two scenarios keep inline budgets and their reds live in
  `MATRIX_KNOWN_RED` under the existing convention instead.

The contract every slice is held to
([scalability-tdd.md](../docs/internals/scalability-tdd.md)):

1. **Camera** — pan/zoom geometry work independent of installed tiles: one
   ancestor mutation.
2. **Streaming** — applying a delta is O(delta + changed visible rows), never
   O(transcript history).
3. **Lifecycle** — offscreen presentation approaches zero work while semantic
   state stays current; memory bounded by admitted surfaces.

Two gates per scenario: an accepted regression ceiling that gates, and an
independent product target that may stay known-red. Counts are the primary
witnesses; wall time is a coarse alarm; no baseline is ever regenerated from
the latest run. **Every slice lands its RED witness before its code.**

Seams to REUSE, never duplicate: `CanvasEngine` (pure world/screen geometry),
`ReadabilityPolicy` (LOD bands), `HydrationTier` (`WorkspaceDocument`),
`ZoneHydrationOrchestrator` (visibility + budget + pinning),
`CanvasEntityIndex` (stable IDs + world rects), `AgentSupervisor` (agent
semantics live here, not in views), `FocusBroker` (interaction pins).

Standing prohibitions (from the research doc, carried verbatim): no direct
mutation of AppKit-owned backing layers; no blanket `isHidden`; no
`ManagedAgentTileNSView.detach()` as culling (it cancels semantic event
delivery); no fixed 60 Hz camera tick; no rasterize-everything; no Metal until
L0–L4 evidence demands it.

---

## Slice 1 — Witness vocabulary and slope fixtures (L0, non-structural)

> **DELIVERED, NARROWED — see the header.** The camera half landed as Slice 1′
> (`cameraMutations`, `canvas.camera-slope`, `--canvas-camera-hit-oracle-check`).
> The transcript and offscreen halves below are **not** this program's work; they
> are recorded here as the original intent only.

**What:** the counters and fixtures every later slice is judged by.

- `Sources/ContinuumRevivedCore/PerfBudget.swift` + a new
  `Sources/ContinuumRevivedCore/PerfCounters.swift`: named counter registry
  for the scalability-tdd vocabulary — camera (mutations, per-tile
  frame/bounds/model writes, cursor rebuilds, subtree layouts — extending the
  existing `CameraLayoutStats`), transcript (entries/rows visited, rows
  flattened, snapshots rebuilt, Markdown bytes reparsed), presentation
  (applies, image scans, tool-detail refreshes), lifecycle (timers created,
  catch-up applies). Counters increment where work is *requested*, not inside
  an implementation detail an optimization can bypass.
- `Sources/ContinuumRevived/App/PerfScenarios.swift`: slope fixtures. Camera
  invariants with installed tiles swept 16/32/64/128 (visible count held
  constant), flat and zoned, at zoom 1.0 and 0.35; a transcript-delta fixture
  (append one prose delta / mutate one tool row / settle one turn at 10 and
  10,000-row histories) counting rows flattened and visited; an
  offscreen-streaming fixture (fixed event sequence into a tile outside the
  viewport) counting presentation applies and timers.
- Semantic settle barriers replace single-layout-pass waits (the
  `canvas.zoom` fixture's documented weakness), so counts start from a
  settled document.

**RED first:** the transcript fixture is expected RED against the product
target immediately — `AgentTranscriptListView.apply(document:patch:)` calls
`flatten(document)` on every patch, so `rowsFlattened` scales with history.
Publish it KNOWN-RED with an accepted ceiling at today's measured counts.
Same for the offscreen fixture (timers/applies continue offscreen today).
**Teeth:** each new counter gets a deliberate-work probe (drive one unit of
the counted work, expect exactly that count).
**Rollback boundary:** counters and fixtures only — no production behavior
change; revert is deleting the scenario.
**Dependencies:** none; parallel with anything. **Exit:** slope fixtures run
in the matrix, ceilings published, and the known-red targets printed per run.

## Slice 2 — Low-risk AppKit experiments (L1, keep only measured wins)

**What:** four independent, individually revertible experiments in
`Sources/ContinuumRevived/Canvas/CanvasNSView.swift`:

1. Explicit `clipsToBounds` at the viewport boundary.
2. Display-paced camera submission: accumulate input, submit the newest
   viewport at most once per display interval via a view-bound
   `CADisplayLink` (`displayLink(target:selector:)`) — never a fixed tick,
   never replaying stale intermediate viewports.
3. Coalesce `discardCursorRects()`/`invalidateCursorRects` to gesture settle
   rather than per camera step.
4. A narrow `layerContentsRedrawPolicy = .onSetNeedsDisplay` experiment for
   the pinch gesture with one crisp settle repaint — not applied recursively;
   WebKit/Ghostty/native controls excluded.

**RED first:** the N-inputs-one-commit witness (N input events inside one
display interval → at most one presentation commit, final viewport
preserved) lands RED before experiment 2.
**Teeth:** revert each experiment; its witness fails.
**Rollback boundary:** each experiment is one commit, droppable alone; a
dropped experiment records its measured result in performance-budgets.md.
**Dependencies:** Slice 1 counters. Experiments are parallel to each other.
**Exit:** keep only what improves the weakest target hardware (M2 Air 8 GB)
without breaking focus, WebKit, Ghostty, or fidelity — measured, not argued.

## Slice 3 — The retained world plane (L2) — FIRST STRUCTURAL SLICE

**What:** the camera stops resizing tile views; this retires KNOWN-RED #8
(`--perf-budget-zoom-check`).

- `CanvasNSView` becomes a fixed viewport owning two children: a clipped
  **world content plane** (document/clip view; candidate `NSClipView` — a
  prototype, not a performance promise) holding zone layers and tile views at
  stable logical frames, and a sibling **screen overlay plane** (nav-mode
  overlay, HUDs, focus border, chrome-scale floors) that never scales.
- A camera step becomes one mutation of the world plane (bounds
  origin/transform of the plane — never a direct backing-layer transform).
  `CanvasEngine` remains the single world/screen coordinate authority;
  `layoutAllTiles`'s per-tile `applyTileGeometry` loop disappears from the
  camera path (tiles keep logical frames; the plane carries pan and zoom).
- Hit testing, cursor rects, zone chrome, spawn placement
  (`TileSpawner.makeProjectTilePlacement`, `installProjectTile`), drag,
  marquee, and the membership/collapse paths all read screen coordinates
  today — each converts through the plane, behind `CanvasEngine` helpers.
  An effectively infinite world may need a bounded, occasionally rebased
  document frame; rebase happens at rest, never mid-gesture.

**RED first:** the Slice 1 camera invariant "exactly one world-camera
mutation, zero per-tile frame/bounds writes per step, slope zero against
installed tiles" lands KNOWN-RED against today's per-tile loop, with the
existing gates (`canvas.pan`, `canvas.fractional-pan`) as the regression
ceiling that must never dip during the migration.
**Teeth:** revert the plane wiring → the one-mutation witness fails;
`zoom.boundsWrites`/`zoom.proseMeasurements` return to their published reds.
**Correctness witnesses (all must be green before the old path is deleted):**
hit-test oracle (screen point → tile identity matches the pre-plane answer
across zoom/pan sweeps), focus/first-responder preservation on a focused
tile through a camera step, overlay screen-fixedness, spawn placement
parity, cursor-rect correctness at settle.
**Rollback boundary:** the plane lands behind a build-time flag with the old
path intact until every correctness witness is green in a full matrix run;
one commit deletes the old path at the end.
**Dependencies:** Slice 1 (witnesses), Slice 2's display pacing is
complementary but not required. **Not parallel** with Slices 5/7 (same file).
**Exit:** camera geometry work structurally flat 16→128 installed tiles at
zoom 1.0 and 0.35; `--perf-budget-zoom-check` leaves `MATRIX_KNOWN_RED`;
real-gesture frame stats on the M2 Air improve or hold.

## Slice 4 — Incremental transcript streaming (parallel with Slice 3)

**What:** applying a delta stops reconstructing the document's derived state.

- `Sources/ContinuumRevived/Canvas/AgentTranscript/AgentTranscriptListView.swift`:
  `apply(document:patch:)` currently ignores the patch's locality and calls
  `flatten(document)`; maintain the row index incrementally from
  `AgentDocumentPatch` (the reducer already emits real patches —
  `AgentDocumentReducer.apply(_:) -> AgentDocumentPatch`), rebuilding only
  affected top-level nodes. Diffable snapshots are built from the incremental
  index, not a full re-flatten.
- Image discovery runs only for patches that can contain images; tool-detail
  refresh only for tool-row changes; header/location/composer/status views
  receive zero applies for a prose-only delta; elapsed timers are neither
  invalidated nor recreated by a delta
  (`AgentTranscriptUpdateScheduler`, `ManagedAgentTileNSView` header).
- Live Markdown parsing becomes append-oriented at the
  `StreamingMarkupBuffer`/`MarkdownAgentMarkupParser` seam: reparse new bytes
  plus the open block, not the accumulated answer.

**RED first:** Slice 1's transcript fixture (rows flattened per one-row delta
at 10 vs 10,000-row history; Markdown bytes reparsed per appended byte) is
already KNOWN-RED; this slice turns it green.
**Teeth:** restore the unconditional `flatten(document)` call → fixture fails
at history-proportional counts.
**Rollback boundary:** keep the full-flatten path as the fallback for
non-local patches (identity reconciliation, restore) — the incremental path
must prove equivalence via an oracle witness (incremental row index ==
from-scratch flatten after every fixture step) before the fallback narrows.
**Dependencies:** Slice 1. Independent of Slice 3 (different files) — safe to
run in parallel. **Exit:** delta cost bounded by changed+visible rows at
10,000-row history; equivalence oracle green; no stable-UI churn per event.

## Slice 5 — Presentation lifecycle and semantic-zoom LOD (L3)

**What:** presentation activity becomes an explicit state, and readability
bands drive real rendering. Four independent axes — semantic activity,
resource residency, presentation LOD, interaction pins — never one enum.

- A tile planner (new, `Sources/ContinuumRevivedCore/`, pure and testable)
  consumes viewport + `CanvasEntityIndex` + `ReadabilityPolicy` +
  `FocusBroker` pins and returns per-tile decisions; generalize
  `ZoneHydrationOrchestrator`'s visibility/budget/pin logic rather than
  duplicating it.
- `ManagedAgentTileNSView` (then terminal/browser/note tiles) gains a
  presentation-dormant state: semantic document keeps advancing through
  `AgentSupervisor` (never via `detach()`), while AppKit applies, timers,
  animations, image hydration, and tool refreshes suspend until exactly one
  catch-up apply on activation. `window != nil` stops being treated as
  visibility.
- Activation window: screen-space, velocity-biased halo with an inner safe
  region (requery only when the viewport leaves it); hysteresis on every
  band threshold; focused/dragged/modal/AX-active tiles are unconditional
  pins.

**RED first:** the offscreen fixture (zero presentation applies / zero timers
offscreen; exactly one catch-up apply; advance past the supervisor replay
cap without view detachment) and the LOD fixtures (one transition per
threshold crossing, zero flapping under jitter, stable band during pinch,
one refine at settle) land KNOWN-RED first.
**Teeth:** disable the dormant state → offscreen applies return; force
`detach()`-based culling in a probe → the replay-cap witness fails (this is
the explicit anti-`detach()` teeth).
**Rollback boundary:** planner shadow-runs against eager behavior (decisions
logged, not enforced) until its witnesses are green; enforcement is a
separate commit per tile kind.
**Dependencies:** Slices 1, 3 (the plane defines "visible"), 4 (catch-up
apply builds on incremental streaming). **Exit:** mounted heavy views,
timers, and live surfaces bounded independently of stored tiles
(100→100,000 sweep); no blank frames on high-velocity pan; focus/AX
preserved across transitions.

## Slice 6 — Restore and ownership bounds (parallelizable after Slice 1)

**What:** restore admits before it materializes; every runtime has a
deallocation witness.

- First frame from descriptors: initially cold zones render navigable
  placeholders before heavy tiles exist; visible/focused descriptors admit
  first; transcript hydration behind a global concurrency bound.
- Browser admission precedes `WKWebView` creation (extend
  `WorkspaceRuntime.enforceBrowserRuntimeBudget` to an admit-before-create
  gate); close the remaining ownership gap .plans/21 names —
  controller-close paths — with teardown witnesses (runtime counts return to
  baseline after tile deletion, zone release, window close; WebKit handlers,
  Ghostty surfaces, timers deallocate).
- Migrate the popup spawn off `canvasView.install` + `saveCanvas`
  (hazard 9) onto `installProjectTile`/`makeProjectTilePlacement`, with the
  landed `--browser-target-blank-check` extended to assert zone-correct
  placement.

**RED first:** restore fixture (8/32/64 agents) counting heavy tiles
materialized before first frame and peak concurrent hydrations — KNOWN-RED
today (restore materializes everything up front). Teardown witnesses RED
against the known controller-close leak.
**Teeth:** revert the concurrency bound → the peak-hydrations count fails.
**Rollback boundary:** admission gates land per runtime kind.
**Dependencies:** Slice 1 only. **Exit:** first-frame-before-materialization
witnessed; runtime counts return to baseline; restore high-water and settled
footprint published.

## Slice 7 — Zone HLOD overview (L4, only if Slice 5's exit misses target)

Zone/coarse-chunk aggregate rendering (custom AppKit drawing or
`CATiledLayer` for static content only) replaces many detail subtrees at
overview zoom; urgent status stays in a small separately-updated overlay;
preview caches keyed `contentVersion × discreteScaleBucket`, bounded by
decoded bytes with LRU, refined at settle; `WKWebView.takeSnapshot` for
browser content. Native interactive islands stay above. **Enter only if**
the zoom-the-workspace-into-view witness still fails on the M2 Air after
Slice 5. Exit: overview cost proportional to visible zones/chunks; cache
bytes within budget; hit-test/AX parity with the native oracle.

## Slice 8 — Hybrid GPU overview (L5, evidence-triggered)

Metal/Core Animation for distant cards/connectors/zone chrome only. **Enter
only if** L0–L4 still miss the M2 Air target AND profiles put the remaining
cost in overview drawing/render-server/GPU submission — not transcript
semantics, WebKit memory, or AppKit island commits. Not planned further
here on purpose.

---

## Order and parallelism

```
Slice 1 (harness)  ──►  Slice 2 (L1 experiments, each droppable)
        │
        ├──►  Slice 3 (retained world plane)  ──►  Slice 5 (lifecycle/LOD)  ──►  Slice 7? ──► Slice 8?
        ├──►  Slice 4 (incremental streaming) ──┘
        └──►  Slice 6 (restore/ownership)
```

Slices 3, 4, 6 can run as parallel streams after Slice 1; Slice 5 needs 3
and 4. Each slice lowers its accepted ceiling only after its win is stable
across repeated Release trials, and hardware validation (M2 Air 8/16 GB,
one ProMotion reference) closes each structural slice.

## Recommended first structural move

Slice 3, the retained world plane, immediately after Slice 1's witnesses
exist: it is the only change that retires the zoom KNOWN-RED, it is the seam
every later presentation decision hangs off, and its risk is bounded by the
flag-guarded dual path plus the correctness oracles above.

# 38 — Slice 2: quiet-surfaced residency (Option A), built

Date: 2026-08-18

Read `.plans/37` first for how we got here (Step 0's measurements and the fork
Dylan ruled on), then this file. `.plans/34` holds the design and its ledger.

**Status: built behind the same default-off flag, leg GREEN, `scripts/run-matrix.sh`
GREEN — 172 legs, 11 expected KNOWN-RED, zero failures, both surface legs printed
in the summary. NOT COMMITTED.** The policy inverts slice 1's axis and every piece
of slice 1's mechanism is reused unchanged.

One note on that run: the FIRST attempt reported **exit code 0 with a summary
saying `Matrix FAILED: 1 leg(s) regressed`** — `--composer-image-components-check`.
It was not this work. `ComposerSubmissionProbeSink.accept` increments its counter at
entry and then suspends 100 ms, while the witness sends, sleeps **20 ms** and
requires the count to be 1: it needs the composer's async submission task to reach
the sink inside a 20 ms window, on a machine that had just run 100+ app legs. It
passes 5/5 in isolation (including under the matrix's own env), that witness builds
a bare `AgentComposerView` rather than a managed tile, and the re-run passed it.
**Left alone deliberately** — widening that sleep or adding the leg to
`MATRIX_KNOWN_RED` would weaken a witness that once caught every pasted image being
silently discarded. If it recurs, widening the 20 ms wait is the fix (the assertion
is `== 1`, so more time makes it stronger, not weaker).

## The rule

> A tile keeps its real body while it is **live**, and renders from a surface
> while it is **quiet**.

Live is any of four things, and the reason is recorded per tile
(`qaLastResidencyDecision`) so a witness asserts the rule rather than an outcome:

1. it holds the first responder (`containsResponder`, which sees into the park);
2. the pointer has **rested** inside it for `pointerRestDelay` (0.15 s);
3. it is animating on its own clock — `surfaceIsAnimating`;
4. its content changed within `contentQuietDelay` (1 s).

Otherwise it is surfaced. Nothing is keyed on the camera any more, with one
exception in each direction: **demotions are suppressed while the camera moves**
(a demote sweep mid-gesture is what killed slice 1), and **sharpness is enforced
per camera step** so a surface never outlives the density the screen needs.

## What was added

| file | role |
|---|---|
| `Canvas/TileResidencyPolicy.swift` | the rule as a pure function of timestamps — witnessable with no canvas, window, or camera |
| `CanvasNSView` (+) | `evaluateTileResidency()`, `surfaceIfAdmissible`, the 10 Hz heartbeat, `viewDidMoveToWindow`, injected clock and pointer |
| `TileNSView` (+) | `surfaceIsAnimating`, `containsResponder`, `final promoteForIncomingFocus()` |
| `ManagedAgentTileNSView` (+) | the animating signal, the status-aware revision, the ingest epoch |
| `CanvasCameraDriver` | `isSettled`; `onActivityBegin` REMOVED (slice 1's hook, now orphaned) |
| `TileSurfaceResidencyChecks` | eleven witnesses, rewritten for this policy |

Reused unchanged: `TileSurfaceHostView`, `TileSurfaceStore`, the `cacheDisplay`
producer, the park, `hitTest` promotion, `TileSurface.isSharpEnough`,
`TileSurfaceResidencyConfig`.

## What the numbers say

12 real agent tiles, Array-owned CPU per camera step:

| arm | p50 |
|---|---:|
| every tile native (today's canvas) | 28.6 ms |
| Option A, 0 live | 0.16 ms |
| Option A, 1 live | 3.46 ms |
| Option A, 3 live | 8.52 ms |
| Option A, 6 live | 18.45 ms |

**Marginal cost is ~2.9–3.0 ms per live tile** (gated at 3.5 ms as a regression
bound). So an 8.3 ms frame holds ~2.8 live tiles and a 16.7 ms frame ~5.5. The
crossing costs ~4.5–5.6 ms to demote and ~4.8–5.4 ms to promote, per tile, paid
per quiet<->live crossing instead of twice per gesture.

**The honest reading: this is a large win with a known ceiling.** A canvas of
quiet agents costs nothing to move (0.16 ms against 28.6 ms). A canvas where six
agents are streaming at once costs 18 ms a step — better than today's 28.6 ms, but
not a 120 Hz gesture. That per-tile cost is AppKit's constraint solve over a real
transcript, marked dirty by the plane's bounds cascade; it is the same cost today's
canvas pays for every tile, and getting under it means a live tile not being an
AppKit view tree in the cascade at all. **That is I2/I4, and it is the next
architectural question, not a tuning knob.**

## Two production discrepancies this found, both fixed

Both are the same shape: something the user can SEE changing that the freshness
rule could not.

- **Status-only changes.** `surfaceContentRevision` was `model.document.version`
  alone, but `.turnStarted`/`.turnCompleted` move the compact status row between
  "Working" and "Done" and start/stop the elapsed tick without necessarily adding a
  card. A quiet tile would sit showing a status it no longer had. Now a mix of the
  document version and a counter over every ingested event. Over-counting is free —
  an ingested event also makes the tile live.
- **Self-animation.** A tile repaints on its own clock with no events at all: the
  elapsed reading counting up during a long tool call. `surfaceIsAnimating`
  (`compactStatusTickTimer?.isValid`) is that exact condition and is now a native
  clause, so "quiet" means "not changing" rather than "no events arrived".

## A third discrepancy, found by reviewing the diff rather than by a failure

**An appearance change left every surfaced tile showing a light-mode picture.**
`TileSurfaceRevision` carries `appearanceName`; switching to dark mode ingests
nothing, animates nothing and touches no content, so all four liveness clauses
still said "quiet" and nothing promoted. It is the one way a surface can go stale
without its tile going live, and the policy had no path for it.

Fixed by promoting any already-surfaced tile whose stored surface no longer
matches `currentSurfaceRevision`, attributed separately
(`qaSurfaceStalePromotionCount`) so the witness asserts the REASON. Witnessed
red-then-green: with the promotion disabled the leg reports "an appearance change
left 4 tiles showing a light-mode picture".

The same path covers a surfaced tile being resized programmatically, since
`bodySize` is in the revision too.

**Dead code this change created, removed:** `refreshTileSurfaces()` and
`qaBakeAllSurfaces()`. Both were slice 1's bake passes; Option A bakes inside
`surfaceIfAdmissible`, so neither had a production caller left. The parked-bake
gate now drives `evaluateTileResidency()` instead — which is the better subject
anyway, being what production actually calls.

## The accessibility gap (Q8), measured then closed

The one gap the pointer clause does not cover: VoiceOver walks the hierarchy with
no pointer and no focus, so nothing else would ever have promoted the tile. Two
designs were on the table and **the measurement chose between them**:

- a parked body is NOT invisible to accessibility. It is still in the window's view
  tree, so a screen reader reaches the transcript — at `{{0, 1132}, {420, 90}}`
  while its tile sits at `{{40, 640}, {420, 300}}`. Wrong place, wrong size,
  detached from its owner, and the height collapsed by the same degenerate clip that
  freezes its pixels. So "substitute the parked subtree" was never viable: AX frames
  are what a VoiceOver cursor is drawn on;
- `accessibilityChildren()` is called **zero** times in normal operation — a full
  run of settles, evaluations and six camera steps, with no AX client attached. So
  promoting there costs nothing when nobody is reading.

Closed with both halves: `TileSurfaceParkView` returns no accessibility children
(a parked body is reachable only through its tile), and
`TileNSView.accessibilityChildren` hands the body back before returning, the same
trade `hitTest` makes for input. An `.accessibility` liveness clause keeps it native
while the client keeps reading — without it, every query would promote and every
pass 100 ms later would demote, churning the AX tree under the user at ~5 ms a
cycle. Witnessed red-then-green on both halves, and the witness asserts the frames,
not just the structure.

## The `acquireFocus` bug `.plans/37` predicted

Confirmed, and worse than described: **every** tile family overrides
`acquireFocus`, and most return before calling `super` —
`ManagedAgentTileNSView` targets its composer's text view directly. So a
base-class fix is invisible to the family that needs it. Worse still, while
surfaced that composer is inside the PARKED body, and AppKit will make a parked
view first responder quite happily: the user types into something clipped out of
every draw and sees nothing. Fixed with `final func promoteForIncomingFocus()`,
called at the top of the managed-agent override, and witnessed
(`checkFocusNeverLandsOnAPicture`).

## One instrument bug worth remembering

`residencyPointerProvider?() ?? window?.mouseLocationOutsideOfEventStream`
silently collapses a doubly-optional: an installed provider RETURNING nil ("the
pointer is nowhere near this canvas") is indistinguishable from no provider at
all, so it fell through to the real cursor. A check was reading **Dylan's actual
mouse position** and promoting whichever fixture tile it happened to sit over —
which presented as "5 of 6 tiles surfaced" and would have been intermittent
forever. Spelled out as an `if let` now.

## Still to earn, in order

1. **The discrepancy checklist rows nothing witnesses yet** (`.plans/37` Step 2):
   cursor rects over a surfaced transcript, drag-select, IME in the composer,
   tooltips and context menus, the accessibility tree (Q8 — the untested idea is
   promotion on AX access, the way `hitTest` promotion works for input), and
   anything that walks the view hierarchy expecting to find a body. Under Option A
   a surfaced tile at rest is the NORMAL state, so each of these is now an ordinary
   path rather than a corner.
2. **The 10 Hz heartbeat is fine for a flag and wrong for a default.** The pass
   itself is microseconds (a `UInt64` compare and a rect test per tile), but a timer
   that never sleeps keeps waking an idle app, which this codebase deliberately
   avoids elsewhere (`syncCompactStatusTick`: "an idle canvas schedules nothing").
   The shape that replaces it: notify on ingest instead of polling for it, one-shot
   timers for the quiet delay, and mouse tracking for the pointer clause.

   **On `tileView.canvas` (the standing open item), narrowed by reading rather than
   fixed from a note:** `install(tileView:for:)` and `installProjectTile` both set
   it; `_installLayer` does not, and neither does `WorkspaceRuntime`, which builds
   the views it hands over. But those are `DescriptorTileNSView` placeholders ("real
   hydration is T08"), and hydration re-installs through the paths that DO set it —
   which is why production drag, resize and zoom-dependent chrome all work, since
   every one of those reads `canvas?.viewport.zoom`. So the gap is real but confined
   to pre-hydration descriptor tiles. **This residency design deliberately does not
   depend on it** — liveness is polled from tile-local counters, so a nil `canvas`
   cannot silently disable the policy for exactly the tiles that matter. An
   event-driven heartbeat WOULD depend on it, and needs that witness first.
3. **Memory — bounded, with the lever chosen deliberately.** Real workspace
   numbers, from the dogfood build's own log rather than extrapolation: **10.4 MB
   per surface** for a large agent body, so six tiles held **62 MB**. Bounded at
   `maxSurfaceBytes` (256 MB) by promoting the FARTHEST tiles, plus dropping a stale
   surface outright on promotion. Evicting means promoting: the host holds the same
   `CGImage` the store does, so dropping the store entry alone frees nothing. The
   two rejected levers, recorded because they look cheaper than they are: baking
   off-screen tiles at lower density trades memory for reparenting churn while
   panning (every tile entering the lead rect gets promoted for softness, then
   re-baked when it goes quiet), and lowering density everywhere trades memory for
   visible softness. Neither fits "can't notice any disadvantages".

   **Eviction alone thrashes, and the witness caught it.** The pass bakes, the
   budget evicts the farthest, and 100 ms later those tiles are still quiet and get
   baked again — forever. Measured with the pre-bake refusal removed: 10 passes
   baked 40 more surfaces on a canvas where nothing changed, ~40 bakes and 40
   reparents a second of pure waste. So the budget is checked BEFORE baking (one
   multiplication: pixels x 4) and the eviction pass is only the safety net for a
   body that grew or a budget that shrank. It never fired in the dogfood build —
   256 MB against a workspace holding 7 to 62 MB.
4. **Dogfood behind the flag** — DONE as a build: `scripts/dev-app.sh --env
   ARRAY_TILE_SURFACE_RESIDENCY=1` launches the preview app with the flag on (the
   `--env` pass-through was added for exactly this; `open` starts a detached process
   that inherits nothing from the calling shell). `CanvasNSView` logs edge-triggered
   to `continuum.canvas:residency`, so
   `log show --last 5m --predicate 'subsystem == "continuum.canvas"' --style compact`
   shows the policy working in a real app. First real-world evidence, on
   `~/array-scratch`: `surfaced 7 of 8 eligible tiles, 7050 KB of surfaces`, and on a
   heavier canvas `surfaced 6 of 6 eligible tiles, 62415 KB` — which is where the
   10.4 MB-per-surface number came from. **What is still owed is Dylan actually
   using it** and reporting whether anything feels off. (`ARRAY_TILE_SURFACE_RESIDENCY=1`) on the preview
   app, and count how many tiles are actually live at once in real use. That is the
   number the headroom above is measured against, and it is still an estimate.
5. **Then decide on I2/I4** for the live-tile cost, with a real live-tile count in
   hand rather than a guess.

## The dogfood verdict and the real-gesture investigation (2026-08-18 evening)

Dylan ran the release build, flag on, and reported it **unusably laggy, "pretty
much no difference"** flag on or off. He is right, and the instrumentation added
for exactly this moment attributed it.

**The felt cost is in-process, after `setViewport`.** Per-gesture logging of the
WHOLE frame (a run-loop observer at order 3,000,000, after CA's commit) against
the camera slice alone: camera p50 1.5–10 ms, **frame p50 172–647 ms** on the bad
gestures. Cadence gaps matched the frame cost, so the display link was starved by
main-thread work, not by the compositor. WindowServer stayed at ~30–50% while the
app hit 80%+.

**A 60-second `sample` during his gestures named the work:** ~30,000 samples in
CoreText text SHAPING, reached from exactly two places —
`AssistantProseView.layout()` → `NSStringDrawing` (transcript prose re-measuring;
this view's own comment records a 0.4.16 incident: 90 s at 96% CPU in this
method), and `FileMarkdownDocumentView.BodyView.measureIfNeeded(width:)` (the
markdown FILE tile — a family that never opted into surfacing). Plus ~6,600
samples in NSTrackingArea updates. The transcript collection view itself was
nearly absent (~100), so this is NOT the layout pass slice 1 fought — it is text
measurement.

**Why the flag made no difference, measured:** the bad gestures ran with **0 of 8
agents surfaced.** The residency log shows all 8 surfaced at 20:35:11, all
promoted at 20:35:12.995 (he zoomed IN → sharpness refused every surface), and
**0 surfaced for the next 36 seconds** — because `surfaceIfAdmissible` only baked
when the REVISION was stale, and zoom is not in the revision. A fresh-but-too-soft
surface was refused forever. Fixed: too-soft now triggers a re-bake at the current
zoom exactly as stale does, witnessed red-then-green ("after settling zoomed IN,
quiet tiles must re-bake at the new zoom"), plus a convergence gate. The byte
estimate also now includes the zoom (an in-plane bake's density carries the
camera; without it a zoomed-in bake was under-counted by zoom squared).

**And why it STILL would not have been enough:** the one gesture with 7 of 8
surfaced measured frame p50 647 ms, because his canvas is 8 agents + 3 file
tiles + 2 notes + 1 file tree — and the markdown file tiles re-measure regardless.

**The trigger, named by the instrument and FIXED:** the width really does move —
by up to **±1.3 pt**, identically in both views (`prose 599.6->600.9`,
`markdown 639.6->640.9`; same delta on different tiles). That is pixel snapping at
the EFFECTIVE scale, which includes the zoom: at zoom ~0.4 one device pixel is
~1.25 world points, so AppKit's scroll machinery re-rounds interior widths on
every zoom step. Both caches guarded at 0.5 pt, so each jiggle re-shaped the whole
document — one 8-step zoom caused **4,310 prose measurements** and 569 ms frames,
while the gestures whose widths held still ran at 7 ms with 0 measurements (i.e.
the residency policy itself was already working; the jiggle was the remaining
lag).

Fixed with `AssistantProseView.measureWidthHysteresis = 2.0` — wider than a
device pixel at any zoom — applied at both measure sites, with rows laid out at
the MEASURED width so wrap geometry always matches what was measured and nothing
can clip. Witnessed in `--file-markdown-perf-check` (the check that already owns
this anti-pattern): the live session's exact jiggle sequence must measure ZERO
for both markdown and prose, and a real width change must still re-measure. Red
with the old 0.5 pt guard: 915 blocks re-measured. Green with the fix.

**Round two, from his "OK but not perfect" (frames 569 ms -> 49 ms, still ~20 fps
during a gesture that began all-native):**

- **Mid-gesture demotion, rate-limited.** The blanket "no demotions while moving"
  meant a gesture that started all-native stayed all-native to its last frame — a
  real 96-step zoom ran every step over eight native transcripts because the
  previous zoom-in had promoted them. Now: two demotions per evaluation pass while
  panning or zooming OUT (a ~5 ms demote beats a ~3 ms/frame native tile after two
  frames), zero while zooming IN (a bake at the current zoom is refused one step
  later — thrash). Witnessed in both directions.
- **File and note tiles opted in.** The markdown file tile was the single heaviest
  body in the profile and could never surface. Its opt-in tracks `activeBody`
  (this family swaps `contentView` between Preview/Source/message, and while
  surfaced `contentView` is the host), guards every swap with
  `promoteForIncomingFocus()` (teeth: removing the guard strands the parked body,
  and the witness says so), and bumps a revision epoch on load/mode/theme. Notes
  bump theirs on `textDidChange`; editing keeps them native via the focus clause
  anyway. Both families' `acquireFocus` overrides promote first — they target
  inner text views directly, so the base-class fix alone was again not enough.

**Round three verdict, on the seeded 89-tile workspace (2026-08-18 late):
"usable, some pretty bad choppy hiccups, solid progress."** The numbers agree on
both halves. Good gestures at 83 surfaced: frame p50 **12.8–14.9 ms with 60–79
tiles visible** — a canvas that was arithmetically impossible native (~89 × 3 ms
≈ 270 ms/frame). Hysteresis is fully holding (markdown passes 0 on every gesture).

**The hiccups' signature, for the next session.** Every bad gesture (frame p50
103–240 ms, one 1.65 s gap) shows `prose measures 25–271` with the `-1.0->`
trigger and `rows 0->N`: transcript rows being MATERIALIZED mid-gesture — fresh
`AssistantProseView.apply` + measure, not a cache miss. The worst one also shows
`83 -> 64 surfaced`: a zoom-in **promote storm**. `enforceSurfaceSharpness`
promotes every insufficiently-sharp tile in the lead rect in ONE camera step,
unbounded, and each promoted body then materialises collection-view rows for its
new viewport and measures them.

Next round, in order:

1. **The promote storm — RULED AND SHIPPED (2026-08-19).** Dylan deferred the
   call ("idk what do you suggest") and took the recommendation: **never hitch,
   brief soft edges.** Rationale: every felt complaint this program has ever
   logged is chop, never softness; mid-gesture blur on moving content is nearly
   invisible while a whole-canvas stall never is; and center-out ordering keeps
   the tile he is zooming TOWARD sharp almost immediately. Implemented as:
   `enforceSurfaceSharpness` collects too-soft tiles and promotes at most
   `maxSharpnessPromotionsPerStep` (1) per camera step, ordered
   on-screen-before-lead-rect then nearest-the-gesture-anchor
   (`CanvasCameraDriver.anchor`, now `private(set)`), deferrals counted in
   `qaSurfaceSharpnessDeferredCount`; a settled one-shot writer (nav snap,
   restore) is uncapped because there are no later steps to spread across and a
   hitch with no motion behind it is invisible. The settled heartbeat catches
   deferred tiles up at `maxSharpnessCatchUpPromotionsPerPass` (2) per pass in
   `evaluateTileResidency` — promote only; the existing too-soft re-bake path
   returns them sharp — because a storm moved to the settle edge is still a
   storm. Witness: `checkSharpnessNeverRegresses` rewritten as
   `checkSharpnessConvergesWithoutAStorm` — RED on the old code ("one zoom-in
   step promoted 6 tiles"), GREEN after; asserts the per-step cap, the
   spend-the-whole-budget floor, observable deferral, nearest-anchor ordering,
   per-pass catch-up cap including the settle edge's own pass, full
   re-surface-sharp convergence, and bake stability. If edge softness ever
   bothers him in practice, the higher-density pre-bake layers ON TOP of this —
   additive, not a rework. Re-measure item 5's camera-slice spikes now that
   storms are gone.
2. **Row materialisation cost.** A promoted body pays `apply` + measure for every
   row entering its visible rect; whether that can be pre-warmed at bake time (the
   body IS laid out to be baked) or cached across promote/demote cycles is the
   question. This is also the road that eventually leads to I2.
3. **Browser tiles** — the one family still fully native (WKWebView; a remote
   layer tree, so `cacheDisplay` may not capture it — needs its own producer
   investigation before opting in).
4. **Desktop-switch (space-switch) lag, reported by Dylan on the 89-tile canvas.**
   Memory looked sane to him (≈85 MB of surfaces, inside the 256 MB cap). A space
   switch is WindowServer re-compositing the window during the animation, and the
   window now carries ~85 large image layers. Two levers already queued bear on
   it: drop surfaces for far-off-screen tiles (resident image bytes + compositor
   work for nothing visible — the eviction mechanism exists, it just is not
   distance-triggered yet), and replace the 10 Hz heartbeat (a timer that never
   sleeps keeps the process semi-awake through system animations).
5. Still unattributed: ~6,600 NSTrackingArea samples, chrome-bucket redraws (6–14
   per gesture), and the production camera slice occasionally spiking (p95 61–179
   ms on promote-storm gestures — likely the storms themselves, re-measure after 1
   is fixed).

## The stress harness (`--seed-stress-workspace-check`)

Built this session at Dylan's request and used for the verdict above: seeds a
REAL workspace through production parts — agents spawned via `AgentSupervisor`
into the channel-split `AgentStore` (harness .pi, exact catalogue-verified model,
`tileId` bound at spawn), real `PiAgentRunner` turns under the production-derived
session id so the app resumes them, tiles appended to the real canvas document in
the existing zone, markdown file tiles over generated four-tier documents,
browser tiles by url. Env: `STRESS_AGENTS/BROWSERS/MD/MODEL/THINKING/CONCURRENCY`,
`STRESS_SKIP_PROMPTS=1`. Refuses a held `.array/lock`; refuses a model id not
verbatim in pi's live catalogue. NOT a matrix leg — real quota, needs pi login.
First full run: 150/150 luna-low turns, 0 failed, 8 concurrent, ~$0.80.

Hazard found building it: **a spawn without `displayName` starts async name
generation, whose timeout cleanup kills its process GROUP** — in a headless
context that is also where the chat turns live; the first smoke lost every turn
to it (piFailed exit 15 = SIGTERM). Named spawns avoid the generator entirely.

Instrument gotchas recorded: `log show` hides `.debug` messages unless `--debug`
is passed (the staleness diagnostic is debug-level); and judging feel on a debug
build wasted a round — `scripts/dev-app.sh --release` exists now.

## Hazards carried forward

- The matrix isolates its own tmux; bare `CoreChecks` does not. Check ancestry
  BEFORE starting a run (`ps -o ppid=,comm=` up the chain), not after.
- Judge a matrix run by its end-of-run summary, never its exit code — and never
  edit source while it runs (that reports `exit 0` with no summary at all).
- Do not touch `AgentTranscriptListView.layout()` for performance. Measured,
  refuted, reverted.
- A counter keyed on where a view LIVES is blind to a mechanism whose whole job is
  moving views between trees. Root at `surfaceableBody`.

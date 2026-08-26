# Agent tile / transcript — wrap-up findings, 2026-08-25

State at the time of writing: worktree `~/array-worktrees/transcript-ux`, branch
`array/transcript-ux`, HEAD `591bfada`. Full matrix GREEN at that commit —
**181 legs, 6 expected KNOWN-RED, no unexpected passes, no real failures.**

This document is the consolidated output of eight parallel read-only
investigations Dylan commissioned ("use up to 8 sub agents here to help, don't
start anything yet brainstorm with me, we will plan after"), plus one live
observation he made while they ran. **Nothing here has been fixed.** It exists so
the picture survives context compaction.

Dylan's framing, verbatim, and it governs the whole performance section:

> "performance is key we spent A LOT of time on optimization and we can't throw
> it all away BUT we have made good improvements to the UI/UX of transcripts and
> agent tiles altogether so we need to optimize our improvements nothing is
> impossible we have full capabilities here"

So: **keep the UX, make it cheap.** Nothing below proposes reverting a visible
improvement to recover speed.

---

## 0. What shipped today (7 commits, all witnessed, matrix green)

| commit | what |
|---|---|
| `0ca3240d` | T1 — the tail keeps its liveness signal through streaming |
| `5857c0bf` | T2/T4 — one row says each thing once; glyph vocabulary |
| `e5c520ce` | T3 — folded durations became spans, not sums |
| `ae0457ac` | T5 — pi's spawn verbs actually offered (roled agents) |
| `458e3551` | T6.1/T6.4 — `delegate_agent` recognised; completed-message replay |
| `fb768ca6` | T6 — the delegated child's run tailed into the child's transcript |
| `404a3f32` | the `#if os(macOS)` guard fix the iOS build caught |
| `591bfada` | T7 — a refused spawn names the directory a role would go in |

---

## 1. DEFECTS INTRODUCED TODAY — highest priority, all mine

### 1.1 HIGH, PROVEN — a live-tailed pi child emits its whole answer TWICE

`AgentSupervisor.swift:2562` builds every `ObservedRunBinding`'s translator with
`replayingCompletedMessages: true`, and that translator serves the **live** tail
in `ingestObservedRunUpdate` (`:2600-2625`) — not only the replay of a finished
run.

A pre-rewrite `events.jsonl` carries **both** forms: `message_update` →
`text_delta` (streamed) and a `message_end` holding the full text. The probe
measured 24 `message_update` lines in a live run, stripped only at completion.
The tail polls at 0.25 s and the fixture's own timeline leaves ~3 s between the
child's assistant `message_end` and `finished`, so production reads the file
while both are present.

Proven by compiling a driver against this branch's `ContinuumRevivedCore`:

```
replay=false -> [assistant:Hello ][assistant:world.]
replay=true  -> [assistant:Hello ][assistant:world.][assistant:Hello world.]
```

**Why the witness cannot catch it:** `Fixtures/pi-delegate-run-events.jsonl`
contains **zero** `message_update` lines — it is deliberately the post-compaction
shape. So the check only ever exercises the half where the flag is correct.

**This is the same trap recorded that morning in the T2 ledger entry** (a witness
whose surface cannot produce the defect), repeated hours later on a different
ticket. The lesson did not generalise.

*Shape of the fix:* the flag must be a property of the READ, not of the binding —
off while the run is live, on only for a post-completion catch-up read. And the
fixture must gain a pre-rewrite variant, or the fix is unwitnessed too.

### 1.2 HIGH — "Worked for Ns" on a turn header measures TIME-TO-FIRST-TOKEN

`AgentTranscriptListView.swift:2477-2490`. `turnSpan` is
`max(createdAt) − min(createdAt)` over the turn's entries. **`createdAt` is
stamped on `.beginEntry`** — verified directly at
`AgentDocumentReducer.swift:52-57`, `createdAt: createdAtProvider()` inside the
`.beginEntry` case.

The last entry of a turn is the assistant reply, so its `createdAt` is the moment
of the **first token**. The entire streaming duration is excluded.

For the common no-tool turn (user prompt + one reply) the header now reads
roughly the time-to-first-token: a 60 s answer that took 2.5 s to start says
"Worked for 2.5s" while the settled tail a few rows below says "Worked for 62s" —
**the exact contradiction the T3 doc comment claims to have fixed.** It is also
strictly worse than before for that case: the old sum printed *no* duration
there; the new span prints a *wrong* one.

*Shape of the fix:* a turn's end is not its last entry's start. Either use the
last entry's last-updated instant, or take the turn end from the same
`turnCompleted` instant the settled tail already uses (which is the number that
is right).

### 1.3 HIGH, OBSERVED LIVE BY DYLAN — the gyro spins after the agent is done

Dylan, while the agents ran: **"the agent is done but i still see it."**

`refreshTranscriptThinkingIndicator` (`ManagedAgentTileNSView.swift:1731-1758`)
derives `statusIsActive` from `attachedAgentID && agentSource &&
eventSubscription != nil && descriptor.status == .working &&
agentSource.isRunning(agentID)`, and visibility is re-derived only when that
function runs (9 call sites, all event/status driven).

T1 replaced `statusIsActive && !latestStreamIsVisible` with `statusIsActive`
alone. The removed term was an **accidental safety net**: a turn that ended
without the descriptor flipping out of `.working` still had an open assistant
entry as its last entry, so `latestStreamIsVisible` was true and the tail was
hidden. Without it, the same stall spins forever.

So T1 converted "silently hidden on a stall" into "spins forever on a stall".
The stall itself is pre-existing; the visible symptom is new.

*Shape of the fix:* the indicator needs a liveness authority that cannot get
stuck — a settle/timeout path, or a re-derivation on the events that actually
end a turn, rather than trusting a descriptor that can go stale.

### 1.4 MEDIUM — the tail cursor is a line index into a file whose identity can change

`AgentSupervisor.swift:2607`. Truncation is detected by **line count only**
(`events.count < consumedEventCount`). The completion rewrite is temp-file +
rename with different content, so whenever the rewritten file is not *shorter*
than the cursor, `events[cursor..<count]` slices the NEW file at an offset
computed from the OLD one.

Scenario: the child writes 30 lines; debounce (0.5 s) + the 4 reads/s cap mean
Array has consumed 6 when the run completes and compacts to 12; `12 > 6`, so
lines 6..11 of the compacted file are delivered as new — re-delivering the head
of the run, and (with 1.1) the full prose again.

The T6 witness only exercises the rewrite when the cursor is already past the
rewritten length.

*Shape of the fix:* the inode. `.systemFileNumber` costs the same syscalls the
stat gate already makes, and is strictly better than the shrink test.

### 1.5 MEDIUM — `echoNamesFile` hides EVERY same-basename file

`AgentToolDetailStore.swift:950` / `:979`. Suppression is `echo.contains(basename)`
per file. With `affectedFiles = [/a/src/index.ts, /b/lib/index.ts]`, `pureSummary`
titles the row "Edited index.ts" and **both** file lines are dropped — the row can
no longer say which two files, and the second is invisible even expanded.
Same-basename sets are the norm (`index.ts`, `mod.rs`, `__init__.py`, `page.tsx`).

Substring collisions too: a row whose action line is "Ran npm test" suppresses an
affected file named `test`.

The new CoreChecks leg covers only the single-file case.

### 1.6 MEDIUM — an observed-run watcher never stops if the run goes quiet

`stopObservedRuns(for:)` has exactly one caller — `stop(id)`
(`AgentSupervisor.swift:2433`), the user-initiated stop. **Not** archive, not
natural turn completion, not teardown. A binding closes only when a NEW snapshot
arrives, and a snapshot arrives only when the directory signature changes. If the
child is `kill -9`'d, or the extension dies before writing a terminal `run.json`,
the directory stops changing → `closed` never set → a 0.25 s `DispatchSourceTimer`
stats that run for the app's lifetime and the child tile stays mid-turn until
relaunch.

### 1.7 MEDIUM-LOW — a run bound to a child that was never minted buffers forever

`bindObservedRun` (`:2549`) checks only that the PARENT exists.
`adoptObservedChild` refuses past `maxChildrenPerParent = 4`, so a 5th
`delegate_agent` mints no child — but its `tool_execution_end` still binds a run
and starts a watcher. `deliverSubagentEvent` then appends every event to
`pendingSubagentEvents[childID]`, which nothing drains for a child that will
never exist.

### 1.8 LOW — a parent's watcher is handed every other parent's open run ids

`AgentSupervisor.swift:2580`: `let watched = Set(observedRunBindings.filter {
!$0.value.closed }.keys)` is global, not filtered to this parent. Harmless today
(foreign directories don't exist under this root and the `isDirectory` guard
skips them; `refreshObservedRunWatchers` corrects it next tick) — but it also
means a stopped-then-rebound run can never restart tailing, because
`bindObservedRun` early-returns on an existing binding without re-arming.

### 1.9 LOW — glyph needle substring collisions

`ToolCallRenderer.swift:376-399`. Dropping the trailing spaces makes `"cat"` match
`locate`/`relocate`. Delegation-first means any MCP tool whose name contains
`agent` or `task` (e.g. `mcp__linear__create_task`) renders as `person.2`.

### Attacks that FAILED (verified clean — do not re-investigate)

- Empty `lines` crashing a caller: the `lines[0]` risk was correctly removed;
  `ToolCallView.apply` never indexes.
- `turnRange` missing on a projection path: the only `.turn` header site sets it.
- `definesNoRoles` doing a main-actor filesystem scan per spawn: it is
  `ordered.isEmpty` over already-scanned data, and the commit REDUCED registry
  construction from one-per-resolve to one shared instance.
- The new refusal naming the wrong directory for claude/codex: unreachable for
  both (claude returns at `adoptObservedChild`, codex is refused earlier).
- `runnerConfig(spawnDepth:)` call sites passing a wrong 0: every `spawnDepth: 0`
  is inside checks; the one production site uses `depth(of: id)`.
- `ObservedRunHandle.validated` escaping the run store: no escape constructible.
- `deliverSubagentEvent` landing events on the wrong thread id: rewritten via
  `withThreadId`.

### Could not verify

- Whether pi really silently filters an uninstalled tool name. **T5.2 rests on
  this**, and it is asserted only in prose. If wrong, every roled pi agent now
  sends a `--tools` list naming a tool the user may not have.
- Whether a pre-rewrite `message_end` carries the assistant content (1.1's
  remaining assumption).
- Findings 1.6, 1.8, 1.9 are reasoned from code, not observed at runtime.

---

## 2. PERFORMANCE

### 2.1 THE STRUCTURAL FINDING — the transcript perf gate measures a path production never runs

**Verified directly.** `grep` for production callers of `apply(document:patch:)`
outside checks/probes returns **none**.

Production streams:
`ManagedAgentTileNSView.swift:2097` → `enqueue(document:patch:final:)` with
**`AgentDocumentPatch.empty(...)`** → `applyCoalesced` (`AgentTranscriptListView.swift:860`),
whose own comment reads *"No patch here: this path derives its own changed set by
comparing against the cached rows, so the full walk is the only correct option."*

`applyCoalesced` does a full `flatten(document)`, an O(rows) `oldIndexes`
dictionary, an O(rows) changed-diff, an O(rows) moved-scan, and — because
`flatten` sets `pendingIncrementalRowIDs = nil` — a full `rowsByID` rebuild plus
a full `rebuildDisplayProjection()` (5-6 more whole-history walks).

`--perf-budget-transcript-delta-check` drives the INCREMENTAL seam
(`PerfScenarios.swift:996`). Its `fullFlattens 0` / `worstHistoryScansPerDelta 0`
are **true of the seam it drives and false of production**.

**Consequence: the headline 50.2 ms → 5.7 ms win was banked on a seam nothing
calls.** Same failure shape CLAUDE.md hazard 9 records for
`WorkspaceRuntime.install(into:)`.

**Second blindness:** the fixture builds `.opaque` blocks, all `role: .assistant`
(`PerfScenarios.swift:951-957`). No `.user` row ⇒ `startsTurn` never true ⇒
`turnRanges` returns one range ⇒ `foldTurns` early-returns ⇒ **turn headers,
`clusterSummaryText`, turn chrome and every tool-detail path are never exercised.**
Today's T3 changes are invisible to the gate by construction.

**Nothing else in this section is verifiable until this is fixed.**

### 2.2 Measured numbers (3 runs, tight spread ±0.05 ms)

`--perf-budget-transcript-delta-check` PASSES: worstDeltaDuration
**5.556 / 5.543 / 5.646 ms** vs 8.3 budget. All count budgets 0. Duration still
clearly linear in history (7.4× for 10× rows) — which the count budgets cannot see.

Other legs: `canvas.pan` PASS 0.448 ms; `canvas.fractional-pan` PASS 0.394 ms;
`--perf-budget-camera-slope-check` PASS 0.041 ms.

KNOWN-RED, with movement since the 2026-08-21 audit:

| leg | audit | today | |
|---|---|---|---|
| `zoom.tileLayoutPasses` | 144 | 144 | flat (budget 12) |
| `zoom.stepDuration` | 4.7 ms | 4.74-6.8 ms | flat-ish |
| `magnify-slope.durationSlope` | 1.917 ms | **2.377-2.465 ms** | **WORSE +24%** |
| `gesture-transition.worstStep` | 10.175 ms | 9.23-12.27 ms | flapping |

`magnify-slope` is the only genuinely degraded number, and its **work slopes are
exactly zero** — same chrome refreshes and same layout passes at 16 and at 128
installed tiles, while wall clock grows 1.12 → 3.50 ms/step. That is AppKit's own
per-installed-subtree traversal, not Array's code. The invalidation probe
measures the multiplier: **a constraint-based tile body costs 2.24× a manual one
at identical (zero) layout passes.**

`zoom.transcriptLayoutPasses = 0` — the zoom problem is NOT the transcript's.

**The caveat that outranks all of it:** `PerfScenarios.all` contains **no
agent-tile scenario**. Every zoom leg runs on `DescriptorTileNSView` note and
markdown fixtures. The canvas Dylan actually pinches — live working agent tiles
with running indicators — has no witness at all.

### 2.3 The gyro — mechanism, cost, and the cheap version

`DualPlaneGyroTiltedThinkingIndicatorView`.

**Steady state is pure render-server**: no timer, no `CADisplayLink`, no per-frame
delegate, implicit actions nulled. Main thread idle. 6 CALayers, 12
`CAKeyframeAnimation`s (4 per node × 3 nodes), 7.20 s master, `repeatCount = .infinity`.

**The cost is the rebuild.** `layout()` (`:189-197`) calls
`removeCompositorAnimations()`, which **deliberately defeats** the "only build if
missing" guard immediately below it. Every layout pass therefore rebuilds all 12:
`Metrics.nodeSampleCount = 144` ⇒ 145 samples × 3 nodes ≈ **435 trig
evaluations** and ≈ **1,740 boxed allocations**, plus 5 `CGPath` rebuilds, on the
main thread. This is trap #2 in `docs/internals/performance.md` (measurement
inside `layout()`) in a form the doc did not anticipate: keyframe synthesis.

**It also rebuilds on every superview move.** `AgentTranscriptListView.swift:19-39`
`install()` does `removeFromSuperview()` then `addSubview()`; `prepareForReuse`
(`:41-47`) the same. The tail item re-installs on **every diffable snapshot
apply** — i.e. every new tool row or block during a turn.

**T1's change was duration only, not mechanics** — but it multiplied the above by
turn length: the gyro used to stop at the first token.

**`canAnimate` (`:263-271`) misses:** window **occlusion**
(`TileNSView.windowOcclusionChanged` exists at `:188-192`, fed from
`CanvasNSView.swift:3643`, and `ManagedAgentTileNSView` does not override it),
**app inactive** (`CanvasNSView` already suspends marching ants on
`didResignActive` — nothing routes it here), **off-viewport**, **unfocused**,
**mid-gesture**. Parking is moot because `surfaceIsAnimating`
(`ManagedAgentTileNSView.swift:383`) pins every working tile `.native`.

N working tiles ⇒ 6N layers / 12N infinite animations, no shared driver, **plus**
one independent instance per working sidebar row (`AgentInbox96CellView.swift:640`).

**Cheap version, identical pixels:** (1) build once — production bounds are pinned
18×18 by two constant constraints — and park with `layer.speed = 0` /
`timeOffset`, resuming by re-anchoring `beginTime`; (2) hoist the keyframe arrays
to `static let`; optionally collapse the 3 position tracks into one
`transform.rotation.z` on a tilt-affine container, pixel-identical because
`projectedPoint` has no perspective term; (3) route the four missing inputs into
one `setAnimationSuspended(_:)` — occlusion is the highest value and the plumbing
already exists.

### 2.4 `RunArtifactsWatcher` — measured, and 75-300× improvable

Own serial queue (not main), one watcher per parent, torn down when no run is
open, allowlisted by run id. **Idle tick costs ~0.10 ms** (4 `attributesOfItem`) —
there IS a stat gate.

**When anything changed, the read is total.** `readEventsJSONL` does
`Data(contentsOf:)` → `split` → `JSONSerialization` **per line, every time**. No
seek, no byte offset, no content cache.

Measured (real reader compiled verbatim, `swiftc -O`, best-of-5, warm cache):

| file | events | `-O` |
|---|---|---|
| 1 MB | 4,658 | 20.1 ms |
| 5 MB | 23,183 | **96.5 ms** |
| 20 MB | 92,719 | **389.3 ms** |

~19 ms/MB, linear. At 5 MB the split is I/O 0.45 ms (0.5%), `split` 41.9 ms,
`JSONSerialization` 37.3 ms — **82% is split+parse, not I/O.** Peak RSS ≈17× file
size (93 MB @ 5 MB), transient but re-incurred twice a second.

**Derived: a 5 MB `events.jsonl` costs ≈193 ms of CPU per wall second — ~19% of a
core, continuously.**

Main-thread work is correctly O(new events) and gated, so this is background
burn, not a main-thread stall.

**Cheap version:** a 64 KB tail with the identical per-line parse costs
**1.19-1.29 ms regardless of file size** — ~75× and ~300× better; ~2.6 ms/s
instead of ~193 ms/s. Sound because the file is append-only during the run and
rewritten by rename at completion (stated at `AgentSupervisor.swift:2602-2606`).
Add `.systemFileNumber` to the existing signature (same syscalls) and tail from a
byte cursor only while inode unchanged and size non-decreasing. **The cursor must
stop at the last `\n`** — the line-count cursor gets partial-line safety free, a
byte cursor does not.

**NOTE: unreleased.** The supervisor wiring landed today in `fb768ca6`;
`git merge-base --is-ancestor fb768ca6 main` says no. **This is not what Dylan is
feeling now.**

### 2.5 What today's transcript changes cost

- **`clusterSummaryText` went from O(members) to O(members + turn length)** (the
  new `turnRange` loop, `:2481`, blame `e5c520ce`) and runs **per apply** for
  every visible header (`refreshVisibleClusterHeaders`, called at `:1112` on every
  apply), not per header creation. But `foldTurns` only emits turn headers for
  turns BEFORE the last — settled by construction — so **every execution after the
  first produces the identical string.** Memoise per header id.
- **`presentedToolBlock` has no memo** and runs inside the layout height closure,
  and `AgentTranscriptLayout.prepare()` calls `measuredHeight` for EVERY item.
  `invalidate(changedIDs:)` nulls the width bucket, defeating the fast path — so
  one row's height change re-runs the presenter for every tool row in the whole
  transcript.
- **The superseded-row fold** (`:2319`, `bcd64589`) adds an O(rows) walk in
  `rebuildDisplayProjection` — correctly off the patch path, therefore on the
  production path.

### 2.6 Pre-existing O(all rows) work (NOT from today)

| site | cadence | cheap version |
|---|---|---|
| `Set(toolDetailIDByBlockID.values)` + compare, `:1025-1026` (uncounted) | every apply | revision counter |
| turn-chrome hasher in `layout()`, `:1423-1426` (from `6926044b8`, 08-23) | **per display cycle** | one `projectionRevision` counter |
| `boundarySignature`, `:470-489`, run **before** prepare's fast-path guard | per `prepare()` | same counter |
| `measurementCache.invalidate(id:)` → `heights.filter` over an **unbounded, never-evicted** cache | per changed row per delta | secondary index |
| `transcriptID(at:)` linear scan, `:796-798` | every fold/disclosure/theme apply | binary search (already y-sorted) |
| `turnStartRowsByEntry` linear scan, `:1885` | **every `mouseMoved`** | binary search |
| `AgentSupervisor.swift:4969` `var buffer = history[id] ?? []` | per delivered event, at token rate | CoW copy of up to 500 events |

Benchmarked hash shape: 0.018 ms @ 1,000 ids, 0.22 ms @ 10,000 — plausibly
0.5-2 ms of the debug 5.5 ms.

**`replayCap = 500` bounds exactly one thing** — the in-memory multicast replay
buffer. Because `contentDelta` is per token, that is often a few hundred tokens,
NOT 500 rows. It does not bound the live `AgentDocument`, the persisted
transcript, `rehydratedTranscripts`, or any per-row index. **A long-running
attached tile is unbounded.**

Virtualisation IS real (diffable data source, 3 reuse identifiers,
`prepareForReuse` drops the renderer subview; `UIProbeGeometry.swift:6530` caps
live hosts < 100). **But height computation is not virtualised** and
`layoutAttributesForElements(in:)` is an O(all rows) filter per scroll query.

### 2.7 Zoom, where the cost actually is

`CanvasNSView.setViewport(_:)` per step:
- `syncWorldPlaneToCamera()` — O(1), guarded.
- **`updateDocumentRelationshipOverlay()`** (`:1854-1899`) — **O(installed tiles)
  per camera step with no `documentLinks.isEmpty` early-out**; a dictionary CoW
  copy plus a walk of every zone layer's tileViews, producing zero output on a
  canvas with no links. Also writes a **full-viewport-sized layer frame every
  step** (`worldPlane.bounds.size` changes per step; at zoom 0.2 on 1600×1000
  that is an 8000×5000 pt layer resized per step).
- `updateContextualAgentLineageGeometry()` — **already fixed**, has an
  `isEmpty` guard now.
- **`for view in visibleTileViews { view.refreshZoomDependentChrome() }`
  (`:2855`) — the 144 passes.** The invalidation probe attributes ALL of them
  here: origin-only 0 passes, size-only 0 passes, production-minus-zoom 0 passes.
- `enforceSurfaceSharpness()` — O(surfaced), maintained set.
- `navModeOverlayView?.needsDisplay = true` — one full-viewport overlay
  invalidated per step whenever nav mode is on.

**Not on the path (verified):** no `CATransaction.flush()` in `Sources/` outside
checks. **`layerContentsRedrawPolicy` is set NOWHERE in `Sources/`** — so AppKit's
default `.duringViewResize` applies to those full-viewport overlays. Untested
hypothesis, one-line probe.

`CanvasNSView` acquired its first-ever `NSLayoutConstraint`s (audit F9) at the
ROOT of the tree — three permanently-installed toast constraints. The
`"NSLayoutConstraint … exceeds internal limits"` warning fired live in a fixture
with **no toast showing**.

**Cheap versions:** the relationship overlay does not need to be a
viewport-sized view that resizes with the camera — it can be a fixed-size sibling
INSIDE `worldPlane` drawing in world coordinates, so the camera moves it for free
exactly as it moves tiles. Same lines, zero per-step frame write, zero per-step
index build. For the traversal: widen the existing gesture hold from "no
residency crossings" to "surfaced subtrees structurally frozen during a gesture".

**The free first probe, no build, no window:**
`log stream --predicate 'subsystem == "continuum.canvas" && category == "gesture"'`
then pinch — `logGestureCost()` (`:2911-2947`) already prints steps, camera
p50/p95, frame p50/p95, gap p50/p95, surfaced, visible, chrome redraws, prose
measures. `frame p95 − camera p95` is the whole question. Compare with agents
idle vs three mid-turn.

**Also:** newest Array diagnostic report is `2026-08-21`, i.e. BEFORE the
transcript wave. "No new report" is itself a finding — this is a per-frame tax,
not a runaway loop.

---

## 3. HONESTY PROBLEMS — advertise-then-refuse

All share one shape: Array offers a capability and then declines it.

### 3.1 `spawn_agent` lies to the model
The extension is inert by design and returns `spawned: <role>` whatever Array
decides. The model believes every delegation succeeded and reasons about children
that do not exist. **This is the root of Dylan's "it failed but then it looks like
it worked."** Fixing it requires the extension to report Array's answer back — a
design change, not a patch.

### 3.2 The cap error, wrong in four ways
Dylan's screenshot: `spawn_agent refused: this agent already has 4 child agents
(cap 4)` on a **claude** agent.

1. **Wrong tool name.** `refuseSpawn` (`:2949-2952`) hardcodes
   `SpawnRequest.toolName` = `"spawn_agent"`. Claude's verb is `Agent`. **The
   harness IS available** — the function already guards on the record, which
   carries it, and every caller holds the record.
2. **Claims to prevent what already happened.** For an observed child the caps
   bind in `adoptObservedChild` (`:2786-2798`), and the code's own comment two
   lines above the dispatch says *"an OBSERVED child is not a spawn at all.
   claude has already started it inside itself… there is nothing to launch — only
   a record to mint."* Array declines to mint; claude is never signalled; the 5th
   child runs invisibly.
3. **It leaks.** `pendingSubagentEvents` has **no eviction, no cap, no TTL, no
   clear on stop/delete**. With `--forward-subagent-text` on, the entire
   transcript of the un-minted child accumulates for the process lifetime.
4. **The stated justification does not apply.** The caps' doc says *"every one of
   them is a Pi process"* — false for an observed claude child, which
   `adoptObservedChild` concedes costs *"no process"*.

**And the "4 spawn + 4 fan-out saturates the sidebar's 8" reasoning is WRONG.**
Fan-out is *subtracted from* the same cap (`:3157-3160`,
`cap = min(cap, maxChildrenPerParent - children.count)`), explicitly so a fan-out
cannot route around it. **One parent can never exceed 4 children by any route**,
so the presentation cap of 8 is at most half-used. `InboxSort`'s own doc says the
8 is *"a presentation cap, deliberately separate from the supervisor's spawn
cap"*, and `RelationshipGeometryChecks:178-184` pins it as **two parents' worth**.

**Proactive enforcement exists on pi only.** `runnerConfig` withholds the verb at
the cap so the model never proposes what it cannot have.
`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` appears 3× in this repo — **all prose,
never code**. Claude's child environment is `PiAgentRunner.childEnvironment()`
verbatim (PATH + the managed marker); `claudeRunnerConfig` sets no env and no
extraArgs. Claude's own default depth is 3; **no breadth control is recorded
anywhere**.

**A second refusal is misdescribed:** `adoptObservedChild` reuses
`.roleUnresolved` for a missing `tool_use_id` (`:2780-2784`), so a claude user can
see *"the requested role is not defined in this project"* when nothing about roles
was wrong.

**The witnesses could never have caught the mis-naming**: the cap checks assert
against `"\(SpawnRequest.toolName) refused"` — they interpolate the same wrong
constant, and run against a pi parent. The one claude-parent spawn witness never
approaches either cap.

**Enforce vs. merely-decline-to-record — 2 of 11 reachable outcomes (3 counting
the misused `.roleUnresolved`) are refusals-to-record dressed as prevention, and
all of them are on claude.** `.unknownParent` can never render at all
(`refuseSpawn` returns before delivering when the record is missing).

### 3.3 Steering advertised and refused
`PiRpcSessionCapabilities.full` contains `"steer"`, so `canSteer` is true and
`workingDraftIntent` prefers `.steer` over `.queue` — and `accept` returns
`.refused(.unsupported)` (`AgentSupervisor.swift:4104-4107`). **With the rpc flag
on, mid-turn Enter loses the message entirely.**

### 3.4 `/compact` refused on pi even when the rpc runner is bound
`AgentSupervisor.swift:4630-4634` switches on `records[id]?.harness`,
contradicting its own doc comment three lines above which says capability *"comes
from the BOUND runner"*.

### 3.5 Dead buttons
`performV2RenderAction` handles image actions, `.openLocalFile`, `.revealAgent`,
`.submitResponse`, then `default: return`. So:
- **Clicking an `https://` link in a transcript does nothing** — and the "Open
  Link" context-menu item fires into that same dead sink. There is no
  `NSWorkspace.shared.open` fallback either.
- **"Open Review" on diff rows does nothing** (`.openDiff` unhandled, and
  `.diffReview` has no spawn route at all).
- `.retry` on error notices does nothing.
- **NOT dead:** the Copy buttons work — `ToolCallView.copyEntireOutput` and
  `CodeBlockView.copyEntireBlock` both write the pasteboard directly; only the
  `.copy` notification is unhandled, which is harmless.

---

## 4. UI/UX — the two asks

### 4.1 The subagent chip is fully wired; the failure is silent

`AgentReferenceChipView` is an `NSButton` with target/action set unconditionally,
`isEnabled` never touched, no `hitTest` override, no swallowing ancestor, and the
whole 28pt row is the click target. It reaches
`.revealAgent` → `performV2RenderAction` → `onRevealAgent` →
`revealAgentFromInbox` — **literally the same function the sidebar row calls, with
the same argument.** So "sidebar works, transcript doesn't" cannot be a handler
difference.

Two candidate causes, both silent:
- The render context is still the default `.disabled` no-op sink
  (`AgentBlockRenderer.swift:113`) — the real actions arrive only if
  `updateRenderContext` ran. `AgentBlockHostView` also deadens closures from an
  older `actionGeneration` on reuse, with no log.
- `revealAgentFromInbox` returns `false` at `ContinuumApp.swift:9177` or `:9178`
  and **both callers discard the Bool.** `:9178` depends on
  `focusTileFromSidebar` returning true — **the camera can jump and this can
  still return false**, in which case reopen, focus, the lineage overlay and the
  sidebar reload are all skipped, silently.
- Tiles whose agent was deleted never get `onRevealAgent` bound at all
  (`ContinuumApp.swift:11744-11753` early return).

**Zero witnesses for the interaction.** `grep .revealAgent(` across all checks:
no hits. Nothing drives a chip press and asserts a tile appeared.

**Gaps for "a nice UI/UX to view a subagent tile":**
1. No feedback on a failed reveal (both guards silent, both Bools discarded).
2. No pressed/hover/target affordance — T2/T4 removed the fill this morning
   (`layer?.backgroundColor = nil`) without adding a hover state, so it no longer
   looks clickable.
3. No handling of the already-open case — re-jumps the camera, no pulse, no toggle.
4. **No lineage in the child tile.** No parent name, no "child of X" crumb, no
   back-link. The only signal is a bootstrap prose line injected at spawn
   (`TileSpawner.swift:1547-1550`, *"Watching this subagent…"*) which scrolls away
   and does not exist on a restored tile.
5. The read-only story is **subtractive only** — composer and footer hidden
   (`:2210-2211`), leaving a gap; nothing positively says "mirrored, read-only".
6. `parentAgentID` is **thrown away** at `ContinuumApp.swift:11825`.
7. Lineage is ephemeral and undiscoverable — appears only as a side effect of a
   reveal, cleared by the next one.
8. **No placement intent** — a child lands wherever a new tile would, so the
   lineage arrow can span the whole canvas.
9. No inline preview — no hover card, popover, or in-transcript expansion.

### 4.2 Open file / link as tile — nearly free

**The route already exists and is witnessed** (`FileOpenChecks.swift:768-830`):
`RichInlineTextView.activateLink` → `.openLocalFile` → `onOpenLocalFile` →
`AgentLocalFileOpener` (containment-checked against the agent's live cwd) →
`WorkspaceRuntime.openDocument` → `TileSpawner.spawnFile` →
`makeProjectTilePlacement` + `installProjectTile`. Hazard 9 satisfied.
`FileOpenPlacement.beside(tileId:)` and `DocumentOpenRequest.sourceAgentId` exist
— "beside the agent that mentioned it" is already built. `FileTileNSView.reveal(line:column:)`
exists.

**The absolute paths are already in the view layer**:
`AgentTranscriptListView.toolDetailsByID[…].affectedFiles` is `[URL]`, populated
from `AgentRuntimeObservation.toolActivity`, block-addressable via
`toolDetailIDByBlockID`. **No I5 widening required for either files or URLs.**
`url` also survives whole on `AgentToolDetailRecord.arguments` (whereas `path` is
reduced to a basename at the translator).

**What is missing:** (a) any right-click menu on a transcript ROW — only
sub-row link and image menus exist; (b) an action that means "open this row's
target" without handing a path to a renderer (the privacy invariant: the path may
not travel through a renderer, an `AgentBlock` payload, or `AgentDocument`); (c) a
browser analogue of `AgentLocalFileOpener` — no host-side resolve+authorize+spawn
unit; `spawnBrowserFromPalette` does no policy check beyond `URL(string:) != nil`.

---

## 5. THE STYLING COMPLAINTS

### 5.1 Bash short output clipped — we already fixed this and did not propagate it

Commit `b5ff292f` (2026-08-21) fixed exactly this on `CodeBlockRenderer`.
**`ToolCallView`'s output pane and `CommandOutputView` never inherited it.**

The pane is NOT fixed-height — it is content-derived with **zero slack**: one line
= 17 pt glyphs + 8 pt inset × 2 = **33 pt exactly**.

- `scrollerStyle` is **never set** → follows the system → **legacy** scrollers
  when "always show scroll bars" is on → ~15 pt taken from a 33 pt pane → glyphs
  at y=8…25 in an 18 pt viewport = **the clipped top half**.
- Output is measured at **unbounded width** (`widthTracksTextView = false`), so the
  line never wraps and the horizontal bar always shows for that date string.
- **Feedback loop:** horizontal bar shrinks height → the 33 pt document is now
  taller than the viewport → vertical bar becomes genuinely needed → eats width →
  worse.
- `hasVerticalScroller = true` is set once at construction and **never
  reconsidered**.

**What the code block does instead:** forces `scrollerStyle = .overlay` (costs
0 pt of viewport); starts `hasVerticalScroller = false` and toggles it per-layout
only when `measuredCodeSize.height > contentSize.height + 0.5`; and forwards
`scrollWheel` to the parent when it has no scroller so a short block is not a dead
patch.

### 5.2 The "Thought" body — the bold is the model's, the padding is ours

**Reasoning renders through the EXACT same prose path as an assistant answer.**
`renderer(for:entryRole:)` special-cases only `.user`; everything else falls to
`AssistantProseRenderer`. **There is no de-emphasis for reasoning anywhere.**

The bold is the source markdown: providers emit whole reasoning items as
`**Planning sports updates**`, and `AgentTranscriptProjection.swift:434-471`
deliberately inserts a `\n\n` block boundary before each such whole-emphasis
chunk. So the paragraph's entire inline content is `.strong` → 13 pt bold body.
(If the provider emits `### …` instead, `headingLadder` makes levels 1/4/5/6 bold
too — level 4 is a 13 pt bold line indistinguishable from bold prose.)

**The geometry is ours and it aligns with nothing:**
- Body at x = **12** inside the disclosure (24 absolute) while its own title is at
  x = **72** — a **60 pt** disagreement between a heading and the prose it
  introduces. A tool row's detail line deliberately hangs at exactly its title's x.
- vs assistant prose (`horizontalReadingInset = 0`, drawing at 12 absolute):
  **+12 pt**, reintroducing one level up the inset the prose comment says it removed.
- `bodyTopSpacing = 2` above the first paragraph vs `bodyBlockSpacing = 8`
  between paragraphs — **4× tighter above than between**.
- The 24 pt disclosure/icon controls overhang the 18 pt header by 3 pt top and
  bottom, into that 2 pt gap.

**The bare "Thought" with no duration is deliberate**: a span < 1 s renders the
bare title, because "Thought for 0s" read as a bug.

---

## 6. DEBT INVENTORY

### 6.1 Ledger tables that are stale TODAY (provable from code)
A stale table is how work gets done twice — the A8 correction already said so.

1. The ledger's own KNOWN-RED paragraph (lines 497-502) lists
   `--perf-budget-transcript-delta-check` and says *"do not add a tenth"* — that
   leg was REMOVED from the allowlist by G0. Obeying the ledger would re-silence a
   fixed leg.
2. Slice 0 table — 4 rows TODO for done work; promises a leg
   `--workspace-rehydration-check` that does not exist (shipped as
   `--zone-tile-hydration-check`).
3. Slice 1b table — all 6 TODO; 1b.6 closed 240 lines below.
4. Slice 4 table — 4a.1/4a.2/4a.3/4b.1 TODO; all landed as M1.7/M1.8/M1.9.
5. Rows 1d.1/1d.2 TODO; both shipped (`DiffSummaryRenderer` uses
   `GitDiffParser.parse`, truncates with "+N more lines", pools file labels).
6. Row 1h.1 claims "Zero conformers exist" — false; but the residual is WORSE
   than stated: **10 of 12 still unconformed**, including `ToolCallView`,
   `CodeBlockView`, `CommandOutputView`, `AgentPlanView`, `AgentDiffSummaryView`,
   `AgentErrorNoticeView`, `AgentReferenceChipView`, `AgentUnknownBlockView`.
7. Milestone table reads **"8 done of 109"** — actively misleading.
8. `.plans/43` line 5 still reads *"No implementation started."*
9. `docs/38-tickets/90-agent-ux/_QUEUE.md:120-129` still queues P5.1-P5.10
   (pi rpc client, abort, compact, steer) as pending — **a loop obeying that file
   would rebuild `PiRpcTransport`.**
10. `docs/38-tickets/95-go-live.md:40-62` says the KNOWN-RED set "is 10" and
    enumerates legs no longer in it. It is 9, and membership differs.
11. `AgentSupervisor.swift:4619-4626` doc comment says capability *"comes from the
    BOUND runner"* and *"Every compiled runner today is one-shot"* — **both false**
    since `PiRpcAgentRunner`/`CodexAppServerTransport` exist.
12. `.plans/48` records one item that **did not reproduce** (`ChoiceListView`'s
    swallowed bare Enter) which ledger row 3a.5 **still lists as a TODO ticket** —
    a ticket that would be "fixed" by finding nothing wrong.

### 6.2 Witness gaps
- **`agentReference` chip live status** — the check stubs the subscription
  (`subscribe: { _, _ in nil }`) and hand-calls `apply` again. Production's actual
  mechanism (`addTurnCapabilitiesObserver` filtered on `changedID`,
  `removeTurnCapabilitiesObserver` on reuse/deinit) has **zero** coverage. A chip
  that never repaints, or one leaked observer per chip reuse, both pass.
- **Transcript rehydration after relaunch** — witnessed by a
  `contains("ManagedTranscriptRehydrator.rehydrate(")` **source scan**. Rename a
  method and it fails; break the behaviour and it does not.
- **Array's own persisted transcript has exactly ONE production reader** — the
  companion sync wiring. The desktop tile re-derives from the provider's session
  file. X.1's "effectively write-only" is only half closed.
- **`secondaryActions` / `allowedWorkingDraftIntents`: zero production consumers**,
  confirmed. `ComposerActionButton` never reads `secondaryActions`. So nobody can
  discover queue/steer; Enter mid-turn silently queues and nothing said it would.
- **`ComposerQueuedMessageRailView` and `ComposerReplyOptionRailView` are
  `TokenThemed` and in NO census** (`tokenAdoptedOwners`), no Lab card. Hazard 8
  violated for the composer's two newest surfaces; dark-mode correctness
  unwitnessed.
- **`--component-lab-check` and `--ui-baseline-check` are BOTH KNOWN-RED and both
  skipped under `CONTINUUM_SKIP_UI_BASELINES=1`** — which the last three matrix
  runs used. `ComponentLab.runTranscriptReviewCheck` holds the row floors for
  every review state added by T2/S1 and **has never executed in a gating run.**
  `run-matrix.sh:657-659` says out loud that adding assertions to
  `--component-lab-check` means they never run — a written-down policy of adding
  assertions to a dead leg. **This is why Dylan's eyes found this week's defects
  instead of a leg.**

### 6.3 `MATRIX_KNOWN_RED` — 9 entries
`--component-lab-check`, `--ui-baseline-check` (both pixel gates, awaiting a
supervised bless, no comment in the script), `--nav-mode-check` (real small defect,
unowned, its paired leg was deleted), `--perf-budget-zoom-check`,
`--canvas-zoom-invalidation-probe-check`, `--perf-budget-magnify-slope-check`
(real product targets), `--perf-budget-gesture-transition-check`,
`--tile-surface-residency-check` (host calibration),
`scripts/check-root-docs.sh`.

**`check-root-docs.sh` exactly:** 9 markers missing from README.md —
`Continuum Revived`, `macOS 14`, `scripts/prepare-ghosttykit.sh`,
`./scripts/run-matrix.sh`, `qa/run-autonomous.sh --scope changed`, `qa-runs`,
`docs/20-product-vision.md`, `docs/21-agent-workflow.md`, `do not push`.
Present: `SwiftPM`, `swift build`, `scripts/check-app-bundle.sh`, `docs/README.md`.
The script's comment claims ONE marker conflicts with the identity rule; only that
one does. The other **eight** are contributor-workflow pointers that moved to
`AGENTS.md`/`CONTRIBUTING.md` — **the check is asking the wrong FILE**. The fix is
to re-point eight and drop the codename one, not to delete the check, which is a
real link-rot gate.

### 6.4 The two named loose ends
- **`tiles.managedAgent-560x560-{aqua,darkAqua}.png`** — last blessed
  `394b8224`, **2026-08-03**. Everything since 2026-08-22 changed what that card
  draws (rhythm, row geometry, clustering, folding, diffstat, one shared text
  column, rowSpacing 12→8, tool rows 36→28). **They cannot possibly match, and no
  current differing fraction exists anywhere** because the gate is both KNOWN-RED
  and skipped. You cannot even quote the number Dylan would be asked to bless.
- **claude's `slash_commands`** — worse than "unwired": **never read**.
  `ClaudeEventTranslator.swift:101-124` handles `subtype == "init"` by extracting
  `session_id` and `cwd` and nothing else; `slash_commands` does not appear in the
  file. `AgentSessionCommandCapabilities.advertisedNames` defaults nil and is
  never non-nil in production. 47 discovered commands, the `skills` list and the
  `agents` list arrive every turn and are dropped; the honest "this agent doesn't
  have that command" refusal is dead code.

### 6.5 Harness matrix
| | claude | codex | pi |
|---|---|---|---|
| transport | one-shot only; 4d.1 (`--input-format stream-json`) TODO | app-server behind `CONTINUUM_CODEX_TRANSPORT`; still process-per-send | rpc behind `CONTINUUM_PI_TRANSPORT`; off because the `message` payload key was source-read, never driven |
| stop | shipped (signal) | shipped (`turn/interrupt` then group kill) | shipped |
| steer | none (queues) | **stub** — `CodexAgentRunner` does not conform to `AgentSessionRunning` | **advertised and refused** (3.3) |
| queue | shipped (Array-side) | shipped | shipped |
| commands | classifier shipped; discovery unwired (6.4) | `unavailable` — correct | `unavailable`, **wrongly so under rpc** (3.4) |
| compaction | shipped | not mapped | boundary only; pre-compaction history unrecoverable by design |
| subagents | shipped; known open decision — the `result` frame leaks child cost into the parent, so a consumer treating `result` as the parent's turn cost double-counts | **no-op**, `observeSpawnRequests` still a stub | shipped this week (T5/T6/T7), with the T7 caveat that the refusal lies to the model |

**Both new transports ship OFF.** Consequence nobody wrote down: **every
capability they unlock is dead in the shipping build**, and the composer will
advertise pi's steering the moment somebody exports the flag.

---

## 7. SEQUENCING — proposed, not agreed

Dylan has NOT approved an order. My recommendation, and the reasoning:

1. **The three correctness defects introduced today** (1.1 double prose, 1.2 wrong
   turn duration, 1.3 gyro spins after done). These are live, user-visible, and
   mine.
2. **Make the perf gate drive production** (2.1). Until it does, every
   optimisation below is unverifiable — and the 5.7 ms number is the proof of what
   happens otherwise. Also add a `.user` row to the fixture, and an agent-tile
   scenario to `PerfScenarios.all`.
3. **The cheap-version optimisations** (2.3-2.6), in cost order: gyro
   build-once/park + occlusion gate; watcher tail read; `clusterSummaryText`
   memo; the two per-display-cycle hash walks; the `mouseMoved` scan.
4. **Honesty** (3.1-3.5): the cap semantics for observed children, the tool name,
   the leak, `.activateLink`.
5. **Polish** (5.1 propagate the code-block scroller fix; 5.2 reasoning geometry
   and de-emphasis; 4.1 chip affordance + non-silent failure).
6. **Debt** (6.1 stale tables at minimum — they actively mislead).

### Open questions that are Dylan's, not mine
- **Do we fix the perf gate before optimising?** (I think yes.)
- **Caps on observed children: raise, remove, or tell the truth?** For a child
  that already exists, "refused" is the wrong word regardless.
- **How much of the debt do we take in this wrap-up?**
- **T5.2 revisit:** Array names a third-party tool (`delegate_agent`) in its own
  allowlist. Required for Dylan's "both", one commit, one revert — and it rests on
  an unverified claim that pi silently filters unknown tool names.

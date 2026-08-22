# Performance audit: what the 0.5.2 → 0.5.8 feature wave cost us

**Date:** 2026-08-21 · **HEAD:** `736cb93` (Release Array 0.5.8) · **Baseline:** `80bcd3c9` (0.5.1, the unbounded-canvas close-out)
**Method:** 8 parallel investigators over the diff, plus one measurement run of every perf leg on this host. Everything below is either measured, read off code with `file:line`, or explicitly labelled a hypothesis.

---

## The one-paragraph answer

Your instinct is right, and it is more specific than "auto-layout might be naive." The performance program that ended at 0.5.1 bought its wins by making **one rule** true: *work must not be proportional to tile count on any path that repeats per display cycle or per input event.* Every feature that shipped in the four days since — jelly auto-layout, canvas undo transactions, document relationship links, subagent lineage, semantic transcript persistence, the nested-code-block fix — broke that rule in a different place. None of them broke residency itself: the residency machinery is **byte-identical** to 0.5.1. What broke is everything residency assumed was cheap. And the two perf gates that would have caught it — `--perf-budget-gesture-transition-check` and `--tile-surface-residency-check` — were both moved into `MATRIX_KNOWN_RED` during this same window, attributed to "host calibration," so the wave landed with the alarms off.

There is no architectural crisis here. Swift/AppKit is not the problem, and the shape of the fix is small: about six surgical changes, five of which are one-to-ten lines, plus one real piece of work on the auto-layout solver.

---

## Timeline: what happened, in order

| Release | Date | What landed | Perf consequence |
|---|---|---|---|
| 0.5.1 | 08-19 | Unbounded-canvas close-out (residency, gesture hold, byte budget) | The good state. Camera step O(1). Gates green. |
| 0.5.2–0.5.5 | 08-19/20 | Agent identity, live elapsed time, sidebar/transcript observability | Mostly clean (see "what's actually well built") |
| 0.5.6 | 08-21 | Markdown documents, **document relationship links**, canvas undo/redo, composer completions | `updateDocumentRelationshipOverlay()` enters the camera path. `gesture-transition` goes from ~5 ms green to 8.9–10.2 ms and is marked KNOWN-RED. |
| 0.5.7 | 08-21 | **Jelly auto-layout** (11 commits), **subagent lineage**, semantic transcripts + encrypted sync | `updateContextualAgentLineageGeometry()` enters the camera path. Auto-layout ships **on by default**, solving per mouse event. Residency leg 4.86 ms, marked KNOWN-RED. |
| 0.5.8 | 08-21 | Nested code-block scroll fix, transcript lifecycle, schema v6 | Overlay gains its O(installed-tiles) index build. `gesture-transition` 10.80–11.35 ms. Residency leg 5.04 ms. |

The regression curve on `gesture-transition` maps 1:1 onto the two overlays entering `syncWorldPlaneToCamera()`. That is the strongest single piece of evidence in this document, and it is why I do not accept the "macOS 26.6.1 host calibration" attribution as written: **0.5.7 → 0.5.8 is the same host, and the number moved +1.5 ms on code alone.** No control run of 0.5.1 on the current OS is recorded anywhere.

---

## Measured state, right now, on this host

Every perf leg was run (build 19.7 s incremental; fixture windows order off-screen at −60000, so nothing took your display).

**Failing — all six already in `MATRIX_KNOWN_RED`, none a new regression:**

| Leg | Metric | Measured | Budget | Note |
|---|---|---|---|---|
| `perf-budget-zoom` | `tileLayoutPasses` | 144 | ≤ 12 | long-standing |
| `perf-budget-magnify-slope` | `durationSlope` | 1.917 ms | ≤ 0.5 ms | |
| `perf-budget-transcript-delta` | `worstDeltaDuration` | 37.31 ms | ≤ 8.3 ms | 450% |
| `perf-budget-gesture-transition` | `worstStepDuration` | **10.175 ms** | ≤ 8.3 ms | **regressed in this window** |
| `tile-surface-residency` | marginal cost/live tile | **4.66 ms** | ~3.5 ms gate | 5.04 → 4.66, improving |
| `canvas-zoom-invalidation-probe` | production zoom | 144 passes | ≤ 12 | |

**Passing, but with the least headroom — this is where the next stutter comes from:**

| Metric | Used | Note |
|---|---|---|
| `zoom.chromeRedraws` 144 / 192 | **75%** | one more chrome invalidation site per bucket crossing blows it |
| `stress.stepDuration` 5.413 / 8.3 ms | **65%** | 0.1128 ms per tile per step ⇒ crosses at ~64 tiles |
| `surface-host.armPassDrift` 1.168 / 2 | 58% | instrument guard, not product cost |
| `surface-host.parkedDurationSlope` 0.256 / 0.5 ms | 51% | half the headroom of the culled config |
| `transcript-delta.worstInvalidatedTopLevel` 1 / 2 | 50% | one extra invalidated row is the whole margin |

Pure pan is still excellent: `canvas.pan` 0.364 ms (4% of budget), `camera-slope` 0.036 ms (0%). **The pan path is not your stutter.** The stutter is in gestures that are not pan, and in per-second background work.

---

## Findings, ranked by expected felt impact

### F1 — Auto-layout solves, and re-lays-out the entire canvas, once per mouse-move event

`CanvasAutoLayoutConfig.defaultEnabled = true`, `.immediately` (`Sources/ContinuumRevivedCore/CanvasAutoLayoutConfig.swift:11-12`) — on for everyone, including your prod install.

`TileNSView.mouseDragged` (`:781` move, `:799` resize) and the zone equivalents (`CanvasNSView.swift:4840`, `:4886`) call `updateTile` → `applyAutoLayout` (`:1970`) → `CanvasAutoLayoutEngine.solve` → `applyLayoutTransaction` (`:337-388`) on **every NSEvent**. Measured cost of one `solve()`, benchmarked standalone:

| tiles in the dragged zone | release build, resize | **debug build, resize** (what you run) |
|---|---|---|
| 4 | 0.36 ms | — |
| 8 | 1.74 ms | **12.7 ms** |
| 12 | 4.40 ms | **30.9 ms** |
| 16 | 11.79 ms | **94.4 ms** |
| 24 | 40.33 ms | — |

Cost scales with **members of the one affected zone**, not canvas size. Tile *moves* are ~1000× cheaper (0.03 ms) — which is exactly why *some* areas stutter and others don't.

Three compounding causes:

1. **`pack()` is ~O(n⁴) and allocates per candidate.** `CanvasAutoLayoutEngine.swift:637-690`: per tile it forms the full cross product of 2k+1 candidate x/y positions (`:678`) and validates each against `Array(placed.values)` — **that array is constructed inside the filter closure** (`:679`), so it allocates once per candidate. Instrumented: 215,237 `valid()` calls (≈ allocations) for one resize event at 16 tiles.
2. **A fixed 39× multiplier.** One `solve()` calls `pack()` up to 39 times: gap/padding bisections (`:184-212`, 26 packs), `minimumFeasibleSize` (`:599`/`:608`, 36), `shrinkNeighborsAndPack` (`:538-557`, 13, each with a full dictionary copy at `:522`), `expandZoneAndPack` (`:578-588`, up to 31). `minimumFeasibleSize` runs on every non-resize zone mutation whether or not the first pack succeeded.
3. **`applyLayoutTransaction` calls `layoutAllTiles()` per event** (`:369`). Pre-jelly this path laid out exactly one tile (`f5c9408^` line 1220: `layoutTile(tile)`). `layoutAllTiles` visits every flat tile *and* every zone-layer tile calling `invalidateForCanvasLayout()` — and the codebase already prices that: *"on a 12-tile canvas costs 14,490 prose re-measurements per zoom sweep — the exact cost the plane exists to remove"* (`TileNSView.swift:1031-1034`). The camera path was fixed to avoid it; the drag path reintroduced it. Same call also re-runs both overlays (F2) and the transaction is deliberately widened to **every** tile and zone (`:325-334`), then resolved with `firstIndex(where:)` + a nested `zoneLayers.first(where:)` per entry — O(T² + T²·Z) closure evaluations per event, ~16k at 89 tiles.

Plus a felt-motion bug on top of the CPU: `:373-388` wraps the displaced tiles in a 0.14 s `NSAnimationContext` group, **snapping each back to its old origin first** (`:379`). At 60–120 events/s that animation never completes and restarts from the interpolated position every event — and it defeats the "skip unchanged frame writes" guard at `:4384-4393`, because an animating view's origin is never equal to the target.

**Symptom:** resizing a tile, or moving/resizing a zone, that has ≥8 siblings is choppy-to-frozen; pushed neighbours rubber-band instead of tracking. Tile moves feel fine. This is the single largest finding.

### F2 — The camera step is no longer O(1) in tile count

`syncWorldPlaneToCamera()` — the function whose own comment reads *"This is the whole camera application — one view's bounds"* — now ends with two calls added since 0.5.1 (`CanvasNSView.swift:908-909`, verified directly):

- **`updateDocumentRelationshipOverlay()`** (`:1695-1727`, landed 0.5.6, index build added 0.5.8). Before it ever consults `documentLinks`, it writes `documentRelationshipOverlay.frame = worldPlane.bounds` and then does `var viewsByTileId = tileViews` followed by a walk of every `zoneLayers[].tileViews` inserting each one (`:1701-1707`). **There is no early-out on `documentLinks.isEmpty`** — which is the state of essentially every canvas. So: a full dictionary CoW copy plus one hash insert per zone tile, per camera step, for zero output. Two independent investigators found this without seeing each other's work. The comment 240 lines above it (`:2663-2670`) documents this exact anti-pattern as *already having been removed once*.
- **`updateContextualAgentLineageGeometry()`** (`:1605-1620`, landed 0.5.7). Writes `overlay.frame = worldPlane.bounds` **unconditionally** (`:1610`) on a full-viewport view — while `CanvasWorldPlaneView.swift:47-52` states that `autoresizesSubviews = false` exists precisely so no subview frame is written per step. `AgentLineageOverlayView.swift:7-9` then has three `didSet { needsDisplay = true }` with **no `oldValue != newValue` diff** (its sibling `DocumentRelationshipOverlayView.swift:44-51` does have the diff) — two unconditional full-view invalidations per step.

**Hypothesis worth one probe:** the overlay's frame size is `viewportSize / zoom`, the subtree is layer-backed, and no `layerContentsRedrawPolicy` is set anywhere in `Sources` — so AppKit's default `.duringViewResize` marks it for display on every size change. At zoom 0.2 on a 1600×1000 viewport that is an 8000×5000 pt layer being resized per zoom step. That would explain a chunk of the residual zoom choppiness currently attributed to the AppKit backing cascade.

**The witness codifies the cost instead of forbidding it.** `FileOpenChecks.swift:757-762` *asserts* that a camera step performs 65 `tileIndexVisits` and 65 `linkEvaluations` — per-step O(tiles) as the contract. And it can't even see the worst of it: it calls `setViewport(largeCanvas.viewport)` with the **same** viewport (so no frame write happens) and builds its canvas via the flat `install` path (so the `zoneLayers` loop never runs and the CoW copy never triggers).

### F3 — The residency gesture hold does not cover direct manipulation

The hold — Dylan's ruling, the thing that took 738 crossings to zero — is keyed on exactly one predicate: `cameraDriver.isSettled` (`CanvasNSView.swift:2949` `demotionBudget`, `:2969` `sharpnessCatchUpBudget`, `:2983` `visibleBakeBudget`, and `slimBudget`). **A tile or zone drag does not move the camera.** So throughout a drag the camera reads *settled* and residency runs at full authority: unlimited demotions, 4 + 12 bakes per pass, 2 catch-up promotes, 2 slims, at 10 Hz.

That was harmless when a drag moved one tile. Now `db9ff7e` ("Transfer in-zone resize pressure between tiles") means a resize changes every neighbour's `bodySize` → `currentSurfaceRevision` mismatch → the stale branch at `:3053-3086` fires `promoteBodyToNative()` + `tileSurfaceStore.drop()` for each, then re-bakes them on a later pass. A 2 s resize drag ⇒ ~20 passes × N neighbours × (~5 ms reparent + 1.7–7 ms bake), on the main thread, interleaved with F1's solver.

**Symptom:** dragging in a populated zone stutters *and* neighbours visibly flip blur↔sharp. The 738-crossing pathology, relocated from camera gestures to pointer gestures.

### F4 — Per-second main-thread work that nothing sleeps

| Site | Interval | Per tick |
|---|---|---|
| `FileTileNSView.swift:572-578` | **1 s** | `refreshFromDisk()` → `FilePreview.load` — `fileExists` + 2 `resourceValues`/`attributesOfItem` + `Data(contentsOf:)` of the **whole file (≤1 MB)** + a null-byte scan of the whole buffer + a full UTF-8 String alloc + a full String compare. **No mtime/size short-circuit.** |
| `ConductorQueueTileNSView.swift:28` | **1 s** | `Process()` on `/usr/bin/sqlite3` with `while process.isRunning { Thread.sleep(0.02) }` — a synchronous subprocess spawn and blocking spin **on the main actor** — then a fresh `NSStackView` + one `NSTextField` per task, replacing the content view. |

Both are `.common` runloop mode, so they fire **inside** pan/zoom gestures. Both survive every sleep mechanism we built: residency parks a body into a view that keeps its window (`CanvasNSView.swift:1168-1173`), so `window != nil` stays true; and `d94ac3f`'s "let the canvas sleep while its window cannot be seen" doesn't reach either timer, so an open markdown tile keeps reading disk while Array is buried on another Space. The `ConductorQueue` one is the worst single pattern found in the audit — both perf-doc traps in one tick — and is conditional only on such a tile existing.

### F5 — Every geometry commit does 2–3 synchronous atomic writes on the main thread

`commitGeometryEdit` → `persistGeometrySnapshot` (`CanvasNSView.swift:1774`, `:1916-1930`) → `ContinuumApp.persistLayoutTransaction` (`:12608-12683`), inline on the mouseUp / Cmd+Z call stack: `registryStore.loadOrEmpty()` twice (`:12614`, `:12638`), `WorkspaceStore.load()` (`:12622`), `projectStore.tryLoadCanvas()` per project zone (`:12647` — **re-reads canvas.json from disk**, decodes, sanitizes), `saveCanvas` per changed project (`:12664`), then `scheduleZoneLayoutSave` immediately followed by `flushPendingSave()` (`:12667-12669`) — **the debounce is created and defeated on the next line.** Then `notifyGeometrySnapshotApplied` (`:1936-1947`) fires `onZoneMoved` → `persistMovedZone`, which loads and saves the workspace document **again**, and `canvasDidChange` → `scheduleCanvasSave` writes canvas.json a **third** time 200 ms later.

Each `AtomicWriter.write` (`AtomicWriter.swift:55-77`) is: pretty-printed JSON encode → **a full decode of the bytes it just encoded, to validate** (`:61`) → `copyItem` of the old file into `backups/` → temp write → `fsync(file)` → `rename` → `fsync(dir)` → `contentsOfDirectory` + sort + prune of a *shared* backups dir (111 files in the scratch root today). `ZoneRuntimeController.swift:606-612` prices one such write at *"tens of milliseconds"* and exists specifically to keep it off main — and this path bypasses its queue, so two writers now race on canvas.json with no ordering.

Net per tile-drag release: ≥3 JSON reads + 2 synchronous atomic writes on main (4 fsyncs, 2 file copies, 2 dir enumerations) + 1 off-main write 200 ms later. Per **zone** drag: 3 synchronous writes, 6 fsyncs. Every Cmd+Z takes the identical path.

Also: because auto-layout is on, `beginGeometryEdit` (`:1752-1756`) captures **all** workspace tiles instead of the one dragged, twice per gesture, and `persistGeometrySnapshot` then encodes all of them (`:1920-1922`) resolved by nested `firstIndex(where:)` — O(N²) bookkeeping for a one-tile nudge.

**Symptom:** a hitch the instant you let go of a tile, and Cmd+Z stuttering instead of scrubbing. Distinct from, and additive to, F1's during-drag stutter.

### F6 — Uncached full-text measurement re-entered `layout()` in 0.5.8

`CodeBlockRenderer.swift:137-146` (`b5ff292`): `CodeBlockView.layout()` calls `CodeTextView.measuredCodeSize(codeTextView.string)`, then `sizeDocument(toFit:)` which calls it **again** (`CodeTextView.swift:134-135`), plus a `scrollView.layoutSubtreeIfNeeded()` at `:139` and conditionally again at `:144`, and toggles `hasVerticalScroller` from inside layout. `measuredCodeSize` (`:142-157`) has **no cache**: a `boundingRect` of the entire code string at `greatestFiniteMagnitude` width plus a full-string newline `reduce`. This is the exact function the perf doc names by name as the trap. Before 0.5.8 it ran once per layout; now twice. Same pattern pre-exists in `CommandOutputRenderer.swift:171-172`/`:287`/`:292`.

Because layout passes are driven by pan/zoom/tile-move rather than by content, this is paid **per visible code block, per layout pass, per native tile** — and F3 guarantees streaming agent tiles stay native.

Related, in the same subsystem: `AgentTranscriptLayout.prepare()` is O(all rows) and is invalidated on essentially every 33 ms streaming flush (`AgentTranscriptListView.swift:812-815`); `applyCoalesced` (`:657-660`) rebuilds five O(N) structures per flush including a deep `old.content != row.content` compare over every row — the exact shape `ManagedAgentTileNSView.swift:1883-1897` documents as *removed* from the tile ("long sessions stalled the main thread"); `CompletedReasoningDisclosureView.measuredHeight` (`:149-170`) allocates a fresh `AgentBlockHostView` with an empty measurement cache per measurement; `AgentBlockMeasurementCache.invalidate(id:)` (`:59`) rebuilds the whole dictionary via `filter` per changed id per flush, with `widthQuantum: 1` so a tile resize mints a new entry per row per pixel and nothing evicts.

**Good news:** the transcript **is** genuinely virtualized (`NSCollectionView` + diffable data source, one item per *visible* row). The "one view per content item" trap is not the problem here. Nor is nesting: `b5ff292` subclassed the existing scroll view rather than adding one.

### F7 — Every agent event re-reads the entire on-disk world, three times over, on main

`scheduleAgentSurfacePush(debounce: 0.5)` fires on each semantic runtime event (`ContinuumApp.swift:12048`) → `pushAgentSurfaces()` → `reloadWorkspaceSidebar(rebuildAgentActivity: false)`. Despite the `false` — whose doc comment claims it exists so we don't walk every store a second time — that call still performs, synchronously on main: **3 registry decodes, 2× per-workspace document decodes, 2× per-project canvas reads + decode + `sanitizePersistedCanvas`, and a session-directory enumeration + per-session JSON decode per project**, then a full `outlineView.reloadData()`. Up to ~2 Hz whenever any agent is emitting. The canvas JSON is the largest document the app persists.

The same path runs on **both** `applicationDidBecomeActive` and `applicationDidResignActive` (`:13567`, `:13575`) — plus `rebuildAgentActivitySnapshot()`, a fourth registry load. Cmd-Tab out and back = 2 full rebuilds. This is the successor to the ~0.4 s git-spawn freeze: `d5efe66` correctly moved the `rev-parse` spawns off-main and left the store reads in place.

**The witness is blind by construction:** `--agent-incremental-refresh-check` deletes the temp project root and *then* calls `pushAgentSurfaces`, so every one of those reads fails silently to empty and the check passes. It witnesses snapshot integrity, not read count.

Two lighter items in the same area: `AgentInboxView.swift:3732-3738` reloads **all** row indexes on a 30 s settle nudge rather than visible ones; and `:1872-1880` does up to 5 `localizedLowercase` allocations + `localizedCaseInsensitiveContains` per row on every push when a search query is active.

### F8 — Transcript persistence is O(turns²), unconditional, and nothing can read it

`AgentTranscriptStore.saveSnapshot` (`Sources/ContinuumRevivedCore/Agents/AgentTranscriptStore.swift:58-74`) writes the **entire** `AgentDocument` plus a fresh journal — two `AtomicWriter.write` calls, so **4 fsyncs, 2 full-file backup copies, 2 backups-dir enumerations, and ~2× document-size of JSON encode + decode**, per save. Nothing appends; the incremental `append`/journal path (`:79-104`) exists with **no production caller**. Turn *k* rewrites the whole document, so cumulative bytes ≈ O(turns²) — a 100-turn/600 KB transcript costs ~1.8 MB of disk traffic per save at the end, ~90 MB over the session, per agent. Three O(nodes) validation passes run per save (`AgentDocument.swift:147-181` allocates an interpolated path String per node; `AtomicWriter`'s verify-decode re-runs the per-entry markup validation).

It is wired for **every** managed agent tile with no gate (`ContinuumApp.swift:11621-11633`), while its only consumer — the companion `transcriptDocument` provider (`:8324-8331`) — is behind a relay/pairing gate that is off in the alpha, and the desktop never rehydrates a persisted transcript into a tile. **So in the alpha this is 100% cost for 0% benefit.** One shared actor serializes the whole fleet; at 6 agents the demand is ~48 fsyncs/s against one serial consumer.

Threading is otherwise correct (the actor keeps encode/crypto off main; crypto is one `ChaChaPoly.seal` with per-channel HKDF, not per-event). The main-thread residue is ~30 `Task` create+cancel pairs per second per agent from the debounce (`:11623-11624`).

Retention is unbounded: `remove` (`:138`) has no caller, so Application Support accumulates ~3× every transcript ever written.

### F9 — `CanvasNSView` acquired its first Auto Layout constraints

`grep -c NSLayoutConstraint` on `80bcd3c9:CanvasNSView.swift` = **0**; HEAD has three, pinning the auto-layout undo toast (`:1185-1189`), installed permanently in `init` regardless of whether the toast shows. The canvas root now hosts an `NSISEngine`, so every display cycle that dirties the canvas runs a constraint solve at the top of a tree that was pure manual layout — and `CanvasWorldPlaneView.swift:39-41` records that the camera profile is *"131 of 5,588 samples in the camera itself; the rest is AppKit recursing `_layoutSubtreeWithOldSize:`"*. Mechanism is concrete, magnitude unmeasured. This is also the **cheapest available control experiment** for the "OS vs code" question on F1's KNOWN-RED gate: replace three constraints with manual positioning and re-run the leg.

### F10 — Coverage: the new subsystems are invisible to the gate

`PerfScenarios.all` is exactly 13 scenarios: 12 `canvas.*` (all camera) plus `transcript.delta`. **There is no direct-manipulation scenario at all** — no tile-move, tile-resize, zone-move or zone-resize budget. The entire path F1, F3 and F5 live on cannot be seen.

| Feature | Perf scenario | Correctness leg |
|---|---|---|
| jelly / zone auto-layout | **none** | `--jelly-auto-layout-check` — 2–3 tiles per zone, no timing |
| canvas undo/redo transactions | **none** | `--canvas-undo-check` exists but is **not registered in `run-matrix.sh`** *and* stubs out the persistence path entirely (`:1917` returns early with no `onLayoutCommitted`) |
| semantic transcript persistence + sync | **none** | correctness on a 1-entry document, exercising the `append` path production never calls |
| subagent lineage reveal | **none** | none |
| nested code-block scrolling | **none** | none — the markdown fixture has no nested scrollers |
| document relationship links | **none** | schema-migration only; the one cost witness asserts 65/step as the contract |
| directory-aware markdown | render axis covered | `--file-markdown-perf-check` green (0 pan measurements) |

Also unregistered anywhere: `--agent-completion-semantic-check`, `--tool-detail-check`, `--browser-tab-restore-check`, `--image-supervisor-check`.

---

## What's actually well built (so we don't touch it)

Worth stating plainly, because it constrains the fix list:

- **Residency is intact.** `evaluateTileResidency`, `enforceSurfaceSharpness`, `requiredSurfaceScale`, `surfaceIfAdmissible`, `bakeWouldFit`, `enforceSurfaceMemoryBudget`, `cameraGestureDidSettle` are **byte-identical** to 0.5.1. Invariants (b) one density decision point, (c) 256 MB degrade-not-refuse, (d) parked bodies hidden, (e) no git spawns on activation — **all hold**.
- **The `refusedBudget` suspicion from the close-out is REFUTED.** It increments at exactly one site, at most once per eligible tile per pass, with two drivers (the 10 Hz timer and the settle edge). 10 Hz × 83 tiles = 49,800/min, which fully explains the observed 47k. Passes are **not** running faster than 10 Hz. What the counter actually means: revisions churn faster than `maxBakesPerPass` can absorb, so the canvas never converges. The fix direction is bake throughput and churn reduction, not pass rate.
- **Transcripts are virtualized.** `NSCollectionView` + diffable data source, one item per visible row.
- **Live elapsed time / relative age is exemplary.** Arms only when a *visible* row has a clock, picks 1 s vs 60 s by whether any clock is live, sets `tolerance`, tears down with the window, and each tick does a targeted cell update — no rebuild, no `reloadData`.
- **Readiness probing, provider commands, catalogue probes, session observation, draft persistence, completion providers** are all off-main, throttled, or cancellable. `2f5ea9e` and `2ecd1af` are clean.
- **The markdown document view learned the 0.4.15 lessons**: bounded at 400 blocks, measurement cached with width hysteresis, frames written only on change, height via `intrinsicContentSize`. Its witness asserts **0** measurements across 30 relayouts, and it passes.
- **The uncommitted working-tree diff is perf-neutral.** `AgentSupervisor.swift:12221-12269` is inside a `--*-check` body; `ManagedAgentTileNSView.swift:2269` is a QA forwarder; `AgentComposerFooterView.swift:222-262` adds work only on a user click.

---

## Proposal

Four phases. Phase 0 and 1 are where the felt wins are; I'd expect Phase 0 alone to remove most of what you're noticing.

### Phase 0 — One-line and near-one-line wins (half a day)

Each is small, independently verifiable, and touches nothing structural.

1. **Early-out `updateDocumentRelationshipOverlay` on `documentLinks.isEmpty`** before the index build (`CanvasNSView.swift:1701`). Restores O(1) camera steps for every canvas without links, i.e. almost all of them. *(F2)*
2. **Diff-guard `AgentLineageOverlayView`'s three `didSet`s** (`AgentLineageOverlayView.swift:7-9`), matching its sibling. *(F2)*
3. **Extend the residency hold to direct manipulation.** Add an "auto-layout gesture in flight / `beginGeometryEdit` open" predicate alongside `cameraDriver.isSettled` at `CanvasNSView.swift:2949`, `:2969`, `:2983`, and for `slimBudget`. Restores the gesture contract to what it was meant to mean. *(F3)*
4. **Gate `FileTileNSView`'s poll on mtime+size** before reading bytes (`:198`), and stop the timer when the body is parked or the canvas is asleep. *(F4)*
5. **Move `ConductorQueueReader.read()` off the main thread** and diff the snapshot before rebuilding the view tree (`ConductorQueueTileNSView.swift:28-44`). *(F4)*
6. **Cache `CodeTextView.measuredCodeSize` by (string, width)** and stop measuring twice per `layout()` (`CodeBlockRenderer.swift:137-146`). Same for `CommandOutputRenderer`. *(F6)*
7. **Gate transcript persistence** on the same condition that decides whether a companion could ever read it (`ContinuumApp.swift:11621`). Removes F8 entirely from the alpha at zero feature cost. *(F8)*
8. **Fix the load-bearing wrong comment** at `CanvasNSView.swift:1170-1178`, which argues the park is clipped-not-hidden — the opposite of what the code does. One investigator in this very audit read it and concluded invariant (d) was broken.

### Phase 1 — The auto-layout drag path (2–3 days)

The only phase with real design content.

1. **Hoist `Array(placed.values)` out of the filter closure** and keep `placed` as an array (`CanvasAutoLayoutEngine.swift:679`). Removes ~200k allocations per event with zero behaviour change. Do this first; it may be enough to reveal what else matters.
2. **Cut the 39× multiplier**: skip the gap/padding bisections and `minimumFeasibleSize` when the first `pack()` succeeds, and cache the bisection result for the duration of a gesture (the zone size changes by a few points per event).
3. **Coalesce the solve to at most one per display interval.** `CanvasCameraDriver` already exists for exactly this on the camera path; the drag path should borrow it rather than solving per NSEvent.
4. **Stop calling `layoutAllTiles()` from `applyLayoutTransaction`** (`:369`) — lay out only the tiles the transaction changed, and drop the absolute-scene widening in favour of tracking last-applied frames. Also guard `layoutZoneChromeViews`'s unconditional frame write (`:1312`) and stop double-calling it and `updateContextualAgentLineageGeometry` from `updateTile` (`:1975-1976`).
5. **Fix the displacement animation** (`:373-388`): don't snap displaced tiles back to their old origin every event. Either drive one continuous animation per gesture or write frames directly during the drag and animate only on settle.

**Open question for you:** should auto-layout stay `defaultEnabled = true` while Phase 1 is in flight? It is on for every alpha user right now, and F1 is worst exactly where the feature is most useful (a populated zone). I'd keep it on and fix it rather than flip the default — but flag it, because flipping it is the instant mitigation if the alpha is complaining.

### Phase 2 — Persistence discipline (1–2 days)

1. **One write per gesture, off main.** Route `persistLayoutTransaction` through `ZoneRuntimeController`'s existing `canvasSaveQueue` and debounce, instead of bypassing both. Removes the two-writer race on canvas.json as a side effect (a correctness fix, not just perf). *(F5)*
2. **Stop the double workspace-document write on zone moves** (`persistLayoutTransaction` then `persistMovedZone`). *(F5)*
3. **Give `AtomicWriter` a fast variant** without the verify-decode and per-save backup copy for high-frequency stores, or make the backup copy async. *(F5, F8)*
4. **Memoize the per-push snapshot in `reloadWorkspaceSidebar`** — thread one registry/documents/canvases read through `buildAgentInboxRows` and `buildWorkspaceSidebarTree` instead of reading 3×/2×/2× within one synchronous call. Removes roughly half of F7's IO with no behaviour change, before touching the harder question of caching across pushes. *(F7)*
5. **Don't rebuild agent surfaces on `applicationDidResignActive`** at all, and make the become-active path incremental. *(F7)*
6. **Narrow the transaction capture** so a one-tile nudge captures one tile, not the whole workspace (`CanvasNSView.swift:1752-1756`). *(F5)*

### Phase 3 — Close the witness gap (1–2 days, do it alongside Phase 1)

Per non-negotiable #2, none of the above is verified until the gate reports it. Counters, not stopwatches, wherever possible.

1. **A `canvas.direct-manipulation` perf scenario** — tile move, tile resize, zone move, zone resize, with a **tiles-per-zone axis (4/8/16)** per `scalability-tdd.md`. Assert: `pack()` calls per event, `valid()` calls per event, tiles invalidated per event, scene builds per gesture, and step duration. This is the gate that would have caught F1 on day one.
2. **An atomic-write counter witness**: assert `writes == 1` and `storeLoads == 0` per gesture. Today it is 2–3 plus a fourth 200 ms later.
3. **Register `--canvas-undo-check` in `run-matrix.sh`** (and the inventory), and make it drive the real `onLayoutCommitted` instead of returning early at `:1917`.
4. **Invert `FileOpenChecks.swift:757-762`**: assert a camera step costs **0** relationship work when nothing about the links changed, and drive it with a *changing* viewport on a **zone-layer** canvas so the frame write and the CoW copy are actually observable.
5. **A saves/bytes/fsyncs-per-turn assertion** for transcript persistence, since document size is the axis that grows.
6. **A sidebar-push read-count assertion**: an event-driven `pushAgentSurfaces` performs **zero** registry/canvas/session reads. Fix `--agent-incremental-refresh-check` so it stops deleting the tree it's supposed to be reading.
7. **The control run that settles F1's KNOWN-RED attribution**: revert F9's three constraints to manual positioning, re-run `--perf-budget-gesture-transition-check`, and record the number. If the leg comes back green, the "host calibration" note in `performance-budgets.md` is wrong and both KNOWN-RED entries should come off.

### Then: re-audit the two KNOWN-RED entries

`--perf-budget-gesture-transition-check` and `--tile-surface-residency-check` should not stay KNOWN-RED on an unverified host-calibration story while their own data shows a code-driven move. After Phases 0–1, re-run both. If they're still red, the OS story deserves a real control run (build 0.5.1 on this host) rather than a note.

---

## Probes worth running before committing to Phase 1

Cheap, and each could redirect the plan:

- `sample` a real tile-resize drag in a populated zone. F1 predicts `CanvasAutoLayoutEngine` frames; F3 predicts interleaved bake/promote frames. Which dominates decides the ordering of Phase 0.3 vs Phase 1.
- `sample` a real pan with 2–3 agents streaming. F6 predicts `CodeBlockView.layout` / `AgentTranscriptListView.layout` frames, mirroring the 0.4.16 `AssistantProseView.layout()` profile.
- `/usr/bin/time -l` peak RSS across a zoom-out sweep, to test the overlay-backing-store hypothesis in F2.
- Count `documentRelationshipOverlay` frame writes across a *changing*-viewport sweep on a zone-layer canvas. Predicted: one per step; contract: zero.

---

## Sources

- `.plans/40-unbounded-canvas-2026-08-19-close-out.md` — the baseline architecture and its stated invariants
- `.plans/39-blur-to-sharp-transition-diagnosis.md`, `.plans/34-unbounded-canvas-implementation-design.md`
- `docs/internals/performance.md` (the four traps), `docs/internals/performance-budgets.md` (published values and the KNOWN-RED notes), `docs/internals/scalability-tdd.md`
- `git log 80bcd3c9..736cb93`, function-body diffs of the residency implementation, and the measurement run tabulated above

---
---

# Part II — Preventing the next wave

Part I is a cleanup list. This part is the more important question: *why did four days of good features erode four weeks of good performance work, and what mechanism stops that?* The honest answer is that Array's performance standards are **documented but not executable**. `docs/internals/performance.md` names all four traps that Part I found. It was not read, or was read and not applied, by every one of the features that broke them. A standard that depends on being read is not a standard — especially in a codebase where most of the work is done by agents who arrive with no memory of the last session.

## The frame-budget idea, stated correctly

The Syntax reference is [episode 1029, "The Workflow of the Future With Zed"](https://syntax.fm/show/1029/the-workflow-of-the-future-with-zed) with Nathan Sobo (Zed, now also DeltaDB/Delta). The line worth stealing is his statement of the goal:

> "the goal was you receive a keystroke, and you have pixels on the next v sync of the display, so there's zero perceptible lag."

That is an **invariant, not an average.** It says nothing about p50 or "it feels fast" — it says *the next vsync, every time*. And the reason Zed built GPUI at all was the failure mode of not having that guarantee: Sobo describes staring at the Chrome profiler "looking at all these little slices of time that I have no idea what's going on inside of and watching the garbage collector run." The enemy was never mean cost. It was **unpredictable spikes he had no control over**. Zed's [engineering](https://zed.dev/blog/videogame) [posts](https://zed.dev/blog/120fps) frame the same thing as consistency over peak optimization: 8.33 ms per frame at 120 Hz, borrowed from how game engines hold a constant frame rate rather than chasing a best case.

I could not find him stating a specific "reserve X% of the frame" rule, so I won't attribute one. But the headroom idea you remembered is real, it is standard game-engine practice, and it turns out to be **exactly the thing Array's budgets get wrong.**

### Array budgets the whole frame and calls it a budget

`PerfScenarios.swift:35` — `static let frameBudgetMs = 8.3`. Fifteen metrics assert `.atMost(frameBudgetMs)`. And the rationale written next to one of them (`:3267`) already knows the problem:

> "a camera step runs once per display refresh; at 120 Hz the whole frame is 8.3 ms, **and the canvas is not the only thing in it**"

The reasoning is correct and the constant contradicts it. Three consequences visible in Part I's measured table:

1. **`canvas.stress` at 5.413 ms reads as "65% of budget, passing."** It is actually consuming 65% of the *entire display frame* — before the compositor, WindowServer, or anything else in the app gets a cycle. There is no frame left. A green leg is describing a dropped frame.
2. **The CA flush isn't in the budget at all.** The residency leg publishes `flush p50` at 3.85 ms (0 live) to **16.63 ms** (all native) — the flush alone is 2× the whole frame in the native case. It is published, deliberately not gated (correctly: it isn't Array CPU). But that means the sum of what we gate and what we publish exceeds the frame while every gate is green.
3. **`gesture-transition` at 10.175 ms** is only 23% over a budget that was already 100% of the frame. Against a realistic share it is ~2.5× over. The leg being "slightly red" understates it badly.

**Proposal P1 — retarget the budget to a share of the frame, and make the frame math close.**

Replace the single `frameBudgetMs = 8.3` with an explicit split:

```
displayFrameMs      = 8.3   // 120 Hz, the physical deadline
arrayShareMs        = 4.0   // what Array's own main-thread work may use
compositorReserveMs = 4.3   // WindowServer + CA flush + everything not ours
```

Gate Array-owned stages against `arrayShareMs`, keep publishing the flush, and add **one new assertion that no individual gate has: `arrayStage + measuredFlush ≤ displayFrameMs`.** That single check is the one that would have said "this doesn't close" at any point in the last month, and no current leg can say it. This is also the direct actionable form of the Zed idea: don't ask "did we fit the frame," ask "did we leave room for the part we don't control."

Expect this to turn several currently-green legs red on day one. That is the point — it's re-baselining against a number that was always the real one. Do it as a deliberate, documented re-baseline with a control run, not silently (see P5).

## What large orgs actually do, and which parts transfer

Array is one person plus agents, on a canvas app, with a hand-rolled offline gate. Most big-company perf machinery (perf on-call rotations, A/B'd metric dashboards, fleet telemetry) doesn't transfer. Four things do, and they're the four that map onto Part I's failures:

**1. Regression gating per *change*, not per *release*.** The industry-standard move is that a diff which regresses a budget cannot land — the gate runs on the change, and a waiver requires an owner and a recorded reason. Array's matrix runs at release time, so 0.5.6 / 0.5.7 / 0.5.8 each shipped, and the gate's response was to absorb the failures into KNOWN-RED. Fourteen commits landed between the last green state and the first observation.

**2. Machine-independent perf tests: count operations, don't time them.** Wall-clock is noisy and host-dependent — which is precisely the ambiguity that let "macOS 26.6.1 host calibration" become a plausible-sounding explanation for a real code regression. Counters are deterministic and cannot be blamed on the host: *allocations per event, layout passes per step, store reads per push, fsyncs per gesture, `pack()` calls per mutation.* Array already knows this ("counters, not stopwatches" is the perf doc's own advice) but the newest budgets are durations. **Every finding in Part I would have been caught by a counter.** F1 = `pack()` calls per event. F2 = tile visits per camera step. F5 = writes per gesture. F7 = store reads per push.

**3. Architectural tests that fail when someone joins a hot path.** This is the highest-leverage idea available to Array and it's cheap. F2 happened because two people independently added a call to the end of `syncWorldPlaneToCamera()` — a function whose own comment says *"This is the whole camera application — one view's bounds."* A comment can't stop that. An **allowlist check** can.

**4. Standards enforced at the point of change, by a machine.** Google/Meta-style CODEOWNERS on hot files, required templates, automated reminders. Array's analogue: the hot files are known and small, and the enforcement surface is CLAUDE.md plus a gate.

## The mechanisms, concrete

Ordered by leverage per hour of work.

### P2 — Hot-path allowlists (the structural fix for F2)

Add a self-check that pins the **exact set of calls** the camera path is permitted to make. Implementation is a few lines: instrument `syncWorldPlaneToCamera` and its callees with a debug-only "path budget" counter, and assert the census — *a camera step performs exactly: 1 bounds write, 0 tile visits, 0 subview frame writes, 0 dictionary allocations.* Anyone (human or agent) who adds a call to the camera path gets a RED leg naming their function, and has to either make it O(1) or register it with a rationale.

Do the same for two other paths that Part I shows are now hot and unguarded:
- **the drag path** (`mouseDragged` → `updateTile` → `applyAutoLayout`): assert solver calls, tiles invalidated, and scene builds per event
- **the commit path** (`mouseUp` → `persistLayoutTransaction`): assert store reads == 0 and atomic writes == 1 per gesture

This is the same technique as the existing `tokenAdoptedOwners` census for `TokenThemed` views (hazard 8) — a pattern this codebase already trusts, applied to performance instead of theming. That precedent matters: it means the idea needs no new infrastructure and no new discipline, just a second census.

### P3 — Counters as the default currency for new budgets

Convert the new-feature budgets to counts, and require counts for anything added from here. A duration budget is a *last* resort, for things where the count genuinely isn't the cost (rasterization, the flush). Concretely, the six counter assertions Part I implies:

| Counter | Contract | Today |
|---|---|---|
| `pack()` calls per drag event | ≤ 1 | 39 |
| tile index visits per camera step | 0 | 65+ (asserted as 65!) |
| store loads per agent-surface push | 0 | ~3 registry + 2×W + 2×P |
| atomic writes per geometry gesture | 1 | 2–3, plus a 4th at +200 ms |
| full-text measurements per layout pass | 0 | 2 per code block |
| transcript bytes written per turn | O(turn), not O(session) | O(session) |

Each is a one-number assertion, immune to host variance, and each names its own violation in the failure message.

### P4 — Make witness registration and witness *teeth* automatic

Two failure modes from Part I, both mechanically preventable:

- **Unregistered witnesses.** `--canvas-undo-check`, `--agent-completion-semantic-check`, `--tool-detail-check`, `--browser-tab-restore-check`, `--image-supervisor-check` exist and are invoked by nothing. Fix: a meta-check that enumerates `--*-check` flags from `ContinuumApp.swift`, diffs against `run-matrix.sh` + `check-app-bundle.sh`, and **fails on any flag in neither**, with an explicit opt-out list for the deliberate ones (`--*-live-check`, `--seed-stress-workspace-check`). This is ~20 lines of shell and it permanently closes a hazard CLAUDE.md already calls out as having cost a session.
- **Toothless witnesses.** `--agent-incremental-refresh-check` deletes the project root and *then* calls `pushAgentSurfaces`, so all of F7's disk reads fail silently to empty and it passes. `--canvas-undo-check` never assigns `onLayoutCommitted`, so it stubs out the entire persistence path it appears to cover. `FileOpenChecks.swift:757` asserts the O(tiles) cost *as the contract*. The rule that catches all three: **a witness is only trusted if its RED state has been observed** — the author must record, in a comment next to the assertion, the mutation that makes it fail. Non-negotiable #2 already says "RED before the fix, GREEN after"; what's missing is that the RED proof isn't *durable*, so a witness can silently rot into vacuous truth. A one-line `// RED when: <mutation>` convention next to each assertion makes rot visible during review.

### P5 — KNOWN-RED becomes a debt register, not a drawer

The current list is genuinely well-documented — each entry carries a real rationale, and that's better than most projects manage. The problem is that it has no *pressure*. It went from 7 entries (0.4.13) to 10, and the two added in this window are precisely the gates that watch Part I's findings. Add three required fields per entry:

- **owner** — who is responsible for it going green
- **expiry** — a version by which it must be green or re-justified
- **control run** — for any leg blamed on the host/OS, the recorded measurement of a *known-good build on the current host*. Without that, "host calibration" is a hypothesis, not a finding.

And one hard rule, which the current process implies but doesn't enforce: **a perf leg may not enter KNOWN-RED in the same release that made it red.** If a release turns a gate red, that's a regression to fix or to explicitly accept in writing — never a bookkeeping change slipped in alongside the feature. Make the matrix print the KNOWN-RED count and diff it against the committed expectation, so growth is loud.

Immediate application: `--perf-budget-gesture-transition-check` and `--tile-surface-residency-check` have no control run, and F9 (the three new constraints on `CanvasNSView`) is a ~30-minute experiment that would produce one.

### P6 — A short, executable performance contract in CLAUDE.md

`docs/internals/performance.md` is the right document and it is too long to be reliably read by an agent mid-task. CLAUDE.md is the file that *is* always read. It should carry a compressed contract — five or six lines, phrased as prohibitions with the enforcing check named:

> **The performance contract.** Before adding a call to the camera path, a drag path, or any `layout()`: (1) nothing may be O(tiles) per display cycle or per input event — enforced by `--camera-path-census-check`; (2) no text measurement in `layout()` without a (content, width) cache; (3) no unconditional frame write — compare first; (4) no synchronous disk IO or subprocess spawn on the main thread; (5) no repeating timer that doesn't sleep when its tile is parked or its window is hidden; (6) a new tile, renderer, or per-frame path ships with a **counter** budget, not a duration. Full reasoning and the history behind each: `docs/internals/performance.md`.

Every single Part I finding violates one of those six lines. That's the test of whether the list is the right length.

### P7 — Make "it feels choppy" produce data

The audit's methodology memory is emphatic that feel beats the leg: `canvas.zoom` measured 4.7 ms green while a real pinch was choppy, and four architectural hypotheses were wrong before counters found the cause. Both times, the expensive part was that your report had no data attached.

Array already has the pattern — the residency log prints every crossing with full attribution specifically so "the next 'it feels wrong' session starts from data." Extend it: a lightweight always-on frame-time histogram plus a "worst frame in the last 10 s, with the stage that owned it" line, dumped by a keystroke or a `--*-check`-style flag. Then a report becomes "here's the histogram" instead of a week of hypotheses. This is the single highest-value item for *your* time as opposed to the gate's correctness.

### P8 — The agent-specific bit

This project is unusually agent-driven, and Part I is partly a story about that. Three adjustments:

- **Executable > documented.** An agent will reliably obey a failing check and unreliably obey a paragraph. Every standard we care about should have a leg. P2/P3/P4 are that translation.
- **Perf legs must be *cheap* to run.** The full matrix is too slow to run per change, so nobody does. Carve out a fast `scripts/run-perf-gate.sh` (the counter legs only — they're deterministic and quick) that an agent is *instructed* to run before claiming a feature is done. Counters make this possible; durations wouldn't.
- **A feature isn't done until its counter budget exists.** Part I's F10 table is seven features with zero perf scenarios between them. Make the scenario part of the definition of done, the way a witness already is for behaviour. The `--jelly-auto-layout-check` case is instructive: a witness *was* written, it just measured correctness at 2–3 tiles per zone — below the scale where any of F1 is observable. **Scale axis is part of the budget**, per `scalability-tdd.md`: 4/8/16 tiles per zone, not "a couple."

## Sequencing

P1 (retarget the budget) and P2 (camera-path census) are the two that change outcomes; do them alongside Part I's Phase 0. P4 (registration meta-check) is 20 lines and closes a known hazard permanently — do it immediately, it's the cheapest item in this document. P3 grows naturally as Phase 3's witnesses get written. P5 and P6 are process, and worth doing in the same sitting as the Part I re-audit. P7 is the one to do when you next feel something and can't name it.

## Open questions for discussion

1. **Is 4.0 ms the right Array share?** It's a guess anchored on the flush measurements (3.85 ms at 0 live tiles). We could derive it instead: measure the flush across the real configurations, take a high percentile, and define `arrayShareMs = displayFrameMs − p95(flush)`. That's more honest and it moves when residency changes, which is arguably correct.
2. **Do we gate at 120 Hz or 60 Hz?** Everything above assumes 8.3 ms. The residency leg reports fitting 1.7 live tiles at 120 Hz and 3.5 at 60 Hz — a big difference in how much the current architecture can carry. If the honest target for a canvas of live agent tiles is 60 Hz, saying so changes several budgets and is better than quietly missing 120.
3. **How much red are we willing to see on day one of P1?** Re-baselining against a share of the frame will light up legs that have been green for weeks. I'd rather see the true number and carry explicit debt than keep a green board that doesn't close, but it's a real cost and it's your call.

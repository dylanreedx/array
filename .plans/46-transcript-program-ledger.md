# 46 — Transcript program ledger

**The tracking document for the program planned in
`~/.claude/plans/plans-45-transcript-program-handoff-pro-reactive-otter.md`.**

Opened 2026-08-22 at `09de0b0` (0.5.10). One row per ticket. Update the status
column in the same commit as the work — a row that says DONE without a witness
name is not done.

Companion documents: `.plans/42` (evidence), `.plans/43` (design argument),
`.plans/45` (the original handoff). `.plans/41` (zone lifecycle) and `.plans/44`
(performance audit) belong to other agents; see S0.6.

## Status vocabulary

| status | meaning |
|---|---|
| `TODO` | not started |
| `RED` | the witness exists and fails for the right reason; fix not written |
| `WIP` | fix in progress |
| `GREEN` | witness passes, leg prints in a real matrix run |
| `SEEN` | GREEN **and** looked at in `Array Dev.app` — the only terminal state |
| `BLOCKED` | waiting on a named ticket or a decision |
| `DROPPED` | deliberately not doing; reason recorded in Notes |

A ticket reaches `SEEN` only after `scripts/dev-app.sh` against a root no other
agent is using, with a screenshot compared against the previous slice.

---

## Progress — by milestone

Reordered 2026-08-22 to the approved milestone sequence. Everything lands on
`array/integration`; each milestone fast-forwards to `main` and ships a release.
Slice-numbered ticket tables below keep their original ids; the map says which
milestone owns each.

| # | milestone | owns | tickets | done | est. |
|---|---|---|---|---|---|
| **M1** | Scene integrity + honest Stop | S0.1–S0.6, 4a.1–4a.5, 4b.1, +3 new | 12 | 3 | 2–3 d |
| **M2** | pi rpc transport | new: turn-state split, P5.1, P5.2, P5.10 | 8 | 0 | 3–4 d |
| **M3** | pi capability harvest | P5.3, P5.7, P5.6, P5.8, P5.4/5.5, P5.9 | 6 | 0 | 3–4 d |
| **M4** | Fixtures, tool supply, delta duration | 1a.1–1a.4, 1b.1–1b.6, 1c.0(revised), X.1 | 12 | 0 | 3–4 d |
| **M5** | The visible overhaul | 1c.1–1c.9, 1d.*, 1e.*, 1f.*, 1g.1, 1h.* | 26 | 12 | 4–6 d |
| **M6** | Dead air remainder | 2.1–2.9 | 9 | 0 | 2 d |
| **M7** | claude + codex parity | 4d.1, 4d.3, 3a.*, 3b.*, 3c.*, 3d.1 | 16 | 0 | 4–6 d |
| **M8** | Note/file linkage | 5a.*, 5b.*, 5c.* | 13 | 0 | 2–3 d |
| — | Probe P | P.1–P.5 | 5 | 5 | **done** |
| — | cross-cutting | X.2, X.3 | 2 | 0 | folded into M1/M4 |
| | **total** | | **109** | **8** | |

### Order rationale

Stop losing work → give pi the transport that turns six built-but-unreachable
renderers on → then supply, then pixels, then the remaining harnesses.

**M2 before the visible work costs about a week and is still right:** rpc emits
byte-identical event objects (same `session.subscribe`, same `toJsonEvent`), so
`PiEventTranslator` survives ~350 of 356 lines and the UI work does **not** land
on a changed contract. M2+M3 convert `ApprovalDockView`, the steer/queue chips,
`.queued`, `TurnOutcome.interrupted`, `/compact` and the cost meter from dead
code into working features — the program's whole thesis. And M2 removes pi's
per-turn process spawn, shrinking M6.

### Three plan corrections that moved tickets (2026-08-22)

1. **`flatten()` is already fixed.** `a19ed1a` landed the incremental row index;
   all count budgets are green. Only `worstDeltaDuration` is red (36.3 ms), and
   the cost is ~56% `applyUnscrolled` + ~35% `prepareToolDetailLifecycle`.
   `run-matrix.sh:618-626` is stale; `performance-budgets.md:429-478` is right.
   Ticket 1c.0 is rewritten as M4.3.
2. **`.staticCard` fixtures would redden two legs** — a missing baseline is a
   failure by design, so 15 states would owe 30 committed PNGs. Extending
   `AgentTranscriptReviewState` costs nothing. Ticket 1a.2 rewritten as M4.1.
3. **The hydration seam cannot return views.** `restartTerminalTile`,
   `restartBrowserTile` and `restartFileTreeTile` all require the tile to already
   be in the canvas model. It becomes a post-`setZones` pass reusing
   `installProjectTile`. Also: `WorkspaceRuntime.install` is check-only, so three
   loops matter, not four. Ticket S0.2 rewritten as M1.2.

### Known gap left open by M1.2 (2026-08-22)

**Ambient (project-less) zones keep their placeholders.** The hydrator resolves a
note body, a repository root and a conductor root from
`workspaceRuntime.controller(for: projectId)`, and an ambient zone has no project
and therefore no controller. Its tiles live in the workspace document's own
`ambientTiles` register instead of a project store. Everything in a *project* zone
hydrates. Not folded into M1.2 because it needs a different source of truth, not a
different loop.

### Two hazards found while sizing, now owned by M1

- **Duplicate terminal runtimes.** A project surviving a switch keeps its
  controller and `controller.runtimes` while `setZones` destroys the views;
  re-running `restartTerminalTile` mints a second `GhosttyTerminalRuntime` on the
  same tmux window via `existingWindowTarget`. → M1.3
- **A pre-existing leak.** A workspace change never calls
  `ManagedAgentTileNSView.detach()`, so the event subscription, three observer
  tokens and `locationStaleTimer` orphan on every switch. → M1.4
- Note `AgentSupervisor.replayCap = 500`: a rebuilt agent tile replays at most
  the last 500 events.

---

## M5 partial — the rhythm slice, out of order (2026-08-23)

Dylan asked for the transcript to look better and chose to take the **visible**
half now rather than after M2/M3. That is a deliberate resequencing, and it is
safe in one specific way: every ticket below is pure rendering, so none of them
can repeat this programme's defining mistake of shipping a renderer with no
producer. The single exception is the hover timestamp, which is why **T1 builds
its producer first**.

Shipped: T1, T2, 1e.1–1e.9, 1c.2, 1h.3. Not in this slice: 1b, 1c.1/1c.3–1c.9,
1d, 1f, 1g, 1h.1, 1h.2.

**Four existing witnesses pinned the defects rather than the behaviour**, and
each was corrected rather than relaxed — the same shape as M1.10's corrections:

| leg | what it pinned | corrected to |
|---|---|---|
| `--ui-geometry-check` | `horizontalReadingInset == Inset.card.left` | the clip/escape invariant against whatever the inset is |
| `MarkupParserChecks` | a GFM table must parse to `.fencedCode` | cells, per-column alignment, retained source |
| `UIProbeCompletedReasoningDisclosure` | the deferred renderer's safe label | the real splitter role and label |
| `ComponentLab.runTranscriptReviewCheck` | — | new states get row floors only; every structural assertion moved to a leg that RUNS (this one sits inside KNOWN-RED `--component-lab-check`) |

**Two things only looking at it caught**, neither reachable from an assertion
that was passing at the time:

1. A turn is a user prompt **and its reply**. Treating every entry change as a
   boundary drew a rule between a prompt and its own answer — the transcript
   grew a line after every message. "The gaps differ" was true of that too.
2. Headings had no extra air above them, so a section title floated midway
   between two paragraphs and read as belonging to the one it ended.

**One witness of mine had no teeth and was caught by teeth-verifying it**: the
hanging-indent assertion asked whether SOME row carried an indent, which the
blockquote satisfied on its own, so it stayed green with list indents entirely
disabled.

**Still open on this seam, recorded not fixed:** `AgentDiffSummaryView` keeps
`rebuildFileLabels()` (destroys and recreates up to 8 `NSTextField`s on every
apply, called unconditionally) and measures with `boundingRect` inside
`layout()` — 1d.2 and the rest of 1h.3. And 1h.1's twelve `TokenThemed`
conformances are untouched; the two views born in this slice
(`ThematicBreakView`, `AgentTableView`) do conform and are swept.

---

## M1 ticket order

Work in this order; each row names the legs to run for that landing.

**Re-scoped 2026-08-22** after sizing M1 properly against `d5561c2`. Three
changes: a new **M1.0** goes ahead of everything (it is the only defect here that
destroys a file rather than a view); **M1.5 merged into it**, being the same bug
on the other call path; and **M1.8 stayed in M1 at full scope** after Dylan
rejected deferring it — see the plan's §2.7. Sizing is by blast radius, never by
engineer-days.

| step | ticket | status / affected legs |
|---|---|---|
| 1 | **M1.0** `--canvas-persistence-model-check` + one persistence reader | **GREEN 2026-08-22** — was RED with `pb-leak: ... a canvas change after the switch wrote 3 of them into it`. Fixed by `CanvasEngine.mergeProjectTilesForPersistence` (Core, pure, 7 cases in `CanvasPersistenceMergeChecks`) behind `CanvasNSView.canvasStateForPersistence(projectId:base:persistedTiles:)`. **All three** stale-flat-model readers routed through it: `flushCanvasSave`/`flushCanvasSaveOffMain`, `persistProjectCanvas`, and `hydrateToLive`'s browser filter. `WorkspaceRuntime` now STAMPS adopted `zoneId` at layer-build time so the merge has no undecidable nil case. Act 3 covers the merged M1.5 truncation and was teeth-verified by restoring `state.tiles = tiles` (fails: `pa-truncation: ... dropped 2 tile(s)`). **A base/persisted split was needed:** flush must base on the LIVE canvasState or pan/zoom stops persisting — caught by `--zone-save-isolation-check` and `--workspace-runtime-install-check`, both of which went red first. 10 affected legs green; inventory 364 (CoreChecks 88→89).  **Amended 2026-08-22 while writing M1.3's leg:** the flat-scene branch of `canvasStateForPersistence` was over-broad. `flatCompatibilitySceneActive` stays true until the first workspace SWITCH, so it was still true after `setZones` had installed a project's layers — and persisting the flat `canvasState` at that point writes whatever it happens to hold, which for a canvas built empty and populated purely through layers is **nothing**. `--zone-runtime-duplication-check` watched all three of its tiles vanish from `canvas.json` during `install`. The branch now also requires the project to have no installed layers (`installedZoneIds(forProjectId:).isEmpty`); once layers own it, they are the model. |
| 2 | **M1.1** `--zone-tile-hydration-check` | **RED 2026-08-22** (`d5561c2`) — `act1: noteTileB must be a live tile after switching to WB, not a DescriptorTileNSView placeholder; got DescriptorTileNSView`. The preceding `viewB != nil` resolve assertion PASSES, proving it fails for the hydration defect and not a lookup. Registered at `run-matrix.sh:588`. Drives production wiring via `AppDelegate.configureWorkspaceRuntimeHooks()` (extracted in this ticket) rather than substituting its own closures. |
| 3 | **M1.2** two-phase hydration; Phase A before `setZones`, never via `installProjectTile` | **GREEN 2026-08-22** — `--zone-tile-hydration-check` now passes: *2 workspace switches, every installed tile hydrated to a live view (note + managed agent), and no agent was minted*. `WorkspaceRuntime.hydrateZoneLayerTiles` hook (optional, so `PerfScenarios` keeps cheap descriptors) called at `install`, `switchWorkspace` and `_addProjectZone`, in both phases. Phase A assigns real views into `layer.tileViews` before `setZones`, so `_installLayer` wires them exactly as it wires placeholders — no `installProjectTile`, no auto-layout, no persist. Phase B runs after `attachActiveControllerUI` builds the spawner. Everything resolves through `controller(for: projectId)`, NOT the active project, so one project's notes cannot render in another's tiles. New `CanvasNSView.withAutoLayoutSuppressed` guards `arrangeAutoLayoutAfterSpawn`. 18 legs green. |
| 4 | **M1.2b** never mint an agent while hydrating | **GREEN 2026-08-22**, teeth-verified. Phase B wires a managed-agent tile only when `agentSupervisor.agent(forTile:)` already resolves. Removing that guard makes the leg fail with *hydrating an unbound managed-agent tile must not create an agent; the supervisor now holds 1 record(s)* — so the mint hazard was real, not theoretical. New `qaManagedAgentCount` accessor. |
| 5 | **M1.3** one runtime per tile across a workspace round trip | **GREEN 2026-08-22**, teeth-verified twice. New leg `--zone-runtime-duplication-check` (real `GhosttyRuntimeContext`, dispatched after `ghostty_init()`; the name deliberately avoids the `--terminal-tmux-` prefix so it keeps the matrix's tmux-off injection). **The fix changed on contact with the fixture.** The plan said *skip* a tile whose controller already holds a runtime; that keeps the count at one and leaves a dead `DescriptorTileNSView` on screen — trading this defect for the one M1.2 just fixed. The surviving runtime cannot be reused either: `setZones` destroyed its host view and `GhosttyTerminalRuntime.attach(to:)` builds a NEW `GhosttyTerminalView`, so re-hosting spawns a second surface. So Phase B now **retires** the orphan (`detach` + `terminate(.force)` + drop from the controller) and restarts — one runtime, a live tile, and with tmux on the session re-binds to the persisted window. Both alternatives were run: removing the retirement fails with *T1 must still have exactly ONE runtime after a round trip; got 2*, and the plan's skip fails with *T1 must come back as a live terminal tile, not a placeholder*. **The leg also found a live data-loss bug in M1.0's own fix** — see row 1's amendment. Fixture shape: ONE project shared by two workspaces (the case `switchWorkspace` is explicitly written for — *"so shared controllers stay alive"*), one zone each, two round trips. It asserts per-tile counts, live view classes, `webViewCreationCountForQA` as an engine-side oracle, and **no accumulation** across the second trip. It deliberately does NOT assert the departed zone's orphaned runtime away — that is M1.4's sweep — but pins the total as stable so the leak cannot grow. |
| 6 | **M1.3b** a spawner per live controller, so Phase B reaches every zone | **GREEN 2026-08-22**, teeth-verified. New leg `--zone-spawner-coverage-check`: a workspace with TWO project zones, only one active. Reverting `attachActiveControllerUI` to its single-spawner shape fails it with *the NON-ACTIVE zone's terminal must hydrate to a live tile, not a DescriptorTileNSView placeholder*. **The split is deliberate:** every live controller now gets a `TileSpawner` (a per-project factory, safe to hold anywhere), but only the active one gets `attachUI` — which starts a session observer and a tmux reaper and takes the shared `focusBroker` callbacks. New `ZoneRuntimeController.attachSpawner(_:canvasView:)` is that subset, and the leg asserts the subset contract explicitly via a new `qaHoldsProcessWideAttachments`: the cheapest way to make the coverage assertion green would be to call `attachUI` on everything, which is a worse bug — N tmux reapers on one server. **The three omitted construction inputs are threaded**: `browserProfiles` (loaded live from the registry — a spawner built after a switch previously resolved browser profiles against the built-in default alone, a live inconsistency with boot), plus `defaults` and `tmuxPathResolver`/`tmuxControlFactory` as injectable `spawnerDefaults` / `spawnerTmuxPathResolver` / `spawnerTmuxControlFactory` on `WorkspaceRuntime`. That last pair is the prerequisite the plan named: until now no check could neutralize tmux on the switch path, and the new leg uses them for real. 14 affected legs green; inventory 366 → 368. **M1.6 is now unblocked.** |
| 7 | **M1.4** `detach()` sweep before `setZones` | **GREEN 2026-08-22**, teeth-verified. New leg `--zone-tile-detach-sweep-check`; removing the sweep fails it with *a workspace switch must cancel the agent tile's event subscription; 1 subscriber(s) remain*. The seam is a new overridable `TileNSView.prepareForRemovalFromScene()`, called from **both** `setZones`'s teardown loop and `retireFlatCompatibilityScene` (the boot scene's agent tiles leak identically), overridden only by `ManagedAgentTileNSView`. Three new `qa` accessors on `AgentSupervisor` — only the event subscription was observable before. The leg asserts a **delta** on `qaTurnCapabilityObserverCount` because that dictionary is app-wide, and its failure message names why it is the worst of the four: flat and un-keyed, so a leaked entry fires for every agent in the app. The two per-agent counts assert absolute zero, since they prune their inner map. Preconditions assert the tile really attached first, and a third act switches BACK and requires exactly one of each — a sweep that detached without letting the tile re-attach would read as fixed and leave the agent tile deaf. Polls with `waitUntil` because `onTermination` hops through a `Task { @MainActor }`. 15 legs green; inventory 368 → 370. The plan's `--agent-observer-independence-check` was correctly identified as a different meaning of "observer" and is untouched (still green). |
| 8 | **M1.6** reveal a cross-project agent into its OWN project | **GREEN 2026-08-22**, teeth-verified. New leg `--inbox-reveal-project-check`; forcing the fallback branch fails it with *the revealed tile must land in the AGENT'S zone (Zb, project Pb) ... it landed in Za/Pa*. New `spawnerAndScope(forProject:)` — the sibling of `spawnerForFilesystemCreation()` keyed on a supplied project id rather than on `resolvedCreationScope()`. **Two things had to move together:** `spawnManagedAgent` frames and installs against `creationScopeProvider()?.zoneId`, so using the right store while leaving the active zone in place would install into one project's layer and persist into another's — worse than the defect, and it would satisfy a layer-only assertion. The reveal overrides `explicitCreationScopeOverride` for the duration, which is the existing seam `presentCreationScopePicker` already uses. The leg asserts BOTH the landing zone and which `canvas.json` received the tile, plus that the record still names its own project and the tile is bound to THIS agent. Behavioural on purpose: the pre-existing coverage is a source scan (`TileSpawner.swift:1841`) that stays green while the behaviour is inverted. `--cross-project-agents-check` was left alone as the plan required — its discriminating property is having no canvas at all. When the agent's project has no live zone the fallback remains, with a corrected stderr message; refusing is rejected by P3.9's negative-test ledger item 7. Inventory 370 → 372. |
| 9 | **M1.7** a stop is `.interrupted`, not `.failed` | **GREEN 2026-08-22**, teeth-verified three ways. Landed together with M1.9 behind one leg, `--agent-stop-outcome-check`, because the fix and the runner seam that can observe it are the same change. New `AgentRunStopped` in Core, thrown by all three runners when the stop flag is set. **pi had no flag at all**; claude's and codex's existed and were read only to suppress a *retry* / *self-heal* that sat AFTER the throws (claude `:291`/`:297`, codex `:257`/`:269`/`:282`) — every one of those now consults it first. **The supervisor keeps its own record of having called `stop(_:)`**, which is what closes the race the plan named: `stop` delivers `.sessionStateChanged(.stopped)` synchronously while the throw arrives later on the global queue's hop back, so a runner that decided to throw a plain error microseconds earlier would still overwrite the stopped state. It also covers any runner that has not adopted `AgentRunStopped`. Cleared on the next `send`, so a stop cannot go on laundering later failures — act 4 pins that. Teeth: removing the mapping fails act 1 (*recorded as .interrupted, not runtimeError*), removing the race guard fails act 2, and laundering EVERY error fails act 3 (*a genuine failure that nobody stopped must still be a failure*). **Not done here, and deliberately:** claude reports an *acknowledged* `control_request` interrupt as `error_during_execution`, which `ClaudeEventTranslator:255` maps to `.failed`. Array does not send that request yet — M7.1 does — so the fix belongs there. |
| 10 | **M1.8** whole process group, with escalation; the machinery moved to Core | **GREEN 2026-08-22**, teeth-verified three ways. New `ProcessGroupChild` in `ContinuumRevivedCore/AgentProviders/`, witnessed by `runProcessGroupChildChecks()` in CoreChecks (89 → 90 suites). All three runners spawn through it instead of Foundation `Process`, whose `terminate()` signals ONE pid — so every shell, MCP server and tool subprocess an agent launched survived a Stop. **`AgentNameOneShot` is now a client**, not the owner: its spawn and its SIGTERM → grace → SIGKILL escalation both come from the shared helper, and what stayed behind is genuinely one-shot-specific (the hard timeout, the bounded readers, the deliberate refusal to block). Its three-scenario grandchild gate is green through the new path. One escalation routine, two graces as VALUES: `Grace.interactive` 0.15s, `Grace.harness` 2.0s. **Two real bugs found while landing it.** (a) The first cut left the dup2 SOURCE descriptors open in the child, so a provider closing fd 0 did not close the pipe, the parent's write never got EPIPE, and the one-shot's input-failure path waited out its whole timeout — caught by `--agent-supervisor-check`. (b) The grandchild fixture used `( … )` and `$$`, which inside a subshell expands to the PARENT's pid: it recorded the leader and "proved" the grandchild died by watching the leader die, and stayed GREEN with the group kill replaced by a per-pid one. Only teeth-verification found that; the fixture is now a separate `sh -c`, and its two waits are bounded against the grandchild's own sleep so neither can pass by racing. **The session-file assertion the grace decision owed is in**: a child that traps SIGTERM and writes its session must still finish inside the interactive grace, complete and naming the same session — the failure message says the grace is too short rather than inviting the assertion's removal. Teeth: per-pid signal fails the whole-group case, no SIGKILL fails the escalation case, zero grace fails the session case. `--managed-agent-live-check` (a real claude CLI, real session continuity) passes through the new spawn. |
| 11 | **M1.9** the stop witness with teeth | **GREEN 2026-08-22**, landed with M1.7 under `--agent-stop-outcome-check`. The plan asked for "a runner that actually throws on stop", which is impossible: `AgentRunning.stop()` is declared non-throwing and is called unqualified, so a throwing `stop()` would mean changing the protocol and every conformer — and it is not production's shape either. What ships is a `stopError` parameter on `ScriptedAgentRunner`, thrown **after** `released.wait()` returns. Its existing `runError` is thrown before `run` ever blocks, so it could model "failed to start" and nothing else — which is exactly why all seven `supervisor.stop(_:)` checks were green while a Stop was being recorded as a failure. No protocol change; slots into the existing `makeRunner:` seam. |
| — | full matrix, then release | **The iOS build leg earned its keep.** `ProcessGroupChild` lives in Core, which the iOS target builds, and `posix_spawn_file_actions_addchdir_np` is explicitly UNAVAILABLE on iOS — the macOS build, every app leg and all of CoreChecks were green and only `xcodebuild` caught it. Gated behind `#if os(macOS)`, with an honest `workingDirectoryUnsupported` refusal elsewhere rather than silently running in the wrong directory. The matrix halts on a failed build by design, so the first run stopped there and nothing after it had run. Judge the re-run by its end-of-run summary.  **Full matrix GREEN 2026-08-22 (second run): `Matrix passed`, 176 legs, zero real failures.** Six expected KNOWN-RED. `CONTINUUM_SKIP_UI_BASELINES=1` was set, so the two display-dependent baseline legs did not run — no baseline was touched and `CONTINUUM_UPDATE_BASELINES` was never set. One thing to decide, NOT acted on: the run reports `--perf-budget-gesture-transition-check` as a KNOWN-RED that PASSED and asks for its removal from `MATRIX_KNOWN_RED`. Nothing in M1 touches the gesture path, and `.plans/44` records these perf gates as having been silenced on an unverified host story — one passing run is not evidence a host-dependent budget is stable, so it is left in place and flagged rather than quietly un-silenced. `MATRIX_KNOWN_RED` is otherwise untouched. **Release not run** — that is Dylan's call, not a gate. |

---

## M1.10 / M1.11 — the milestone was dead on arrival (2026-08-23)

M1 was built as an isolated dev app and driven by hand for the first time.
Switching workspaces did not change the canvas, and ⌘K did nothing in a newly
created workspace. **One root cause, and it invalidated most of M1.**

`WorkspaceRuntime.canvasView` is written in exactly one place,
`install(into:appRegistry:)`, and **no production code had ever called it** since
`93c68f43` introduced the method in June. Every canvas call in `switchWorkspace`
optional-chained through nil. The document, the registry and the toolbar header
changed; the canvas did not.

So **M1.0, M1.2, M1.2b, M1.3, M1.3b, M1.4 and M1.6 never executed in the shipping
app.** Their witnesses were green because each one calls `install(into:)` itself
before asserting — the exact failure this programme exists to stop, committed at
scale and not noticed until someone clicked. Only M1.7/M1.9 and M1.8 were ever
live. Both defects were pre-existing, verified identical at `09de0b0`; the dead
code was mine.

| step | ticket | status |
|---|---|---|
| 12 | **M1.10** production owns the scene | **GREEN 2026-08-23**, `--workspace-scene-owner-check`, RED first on `qaHasCanvas`. Boot stays flat — deliberately, so a defect on the switch path is cleared by relaunching. Four hazards had to be closed before the turn-on was safe: **Model B** (`liveZones`) is the zone *interaction* model, not just chrome, and `setZones` never wrote it — layers would have shipped unmovable, unresizable, unrenameable zones; **chrome** orphaned and double-drew; **frame spaces** differ and every `canvas.json` in the field is WORLD, so an unconverted layer install teleports every tile by the zone origin; and **foreign `zoneId` stamps are ordinary**, so the old membership filter would have rendered one real project's 89 tiles nowhere. New pure `CanvasEngine.resolveZoneMembership` rescues them position-preservingly. `switchWorkspace` now throws instead of silently doing the document half. |
| 13 | **M1.11** an empty workspace is not a dead end | **GREEN 2026-08-23**, `--empty-workspace-creation-check`, teeth-verified twice. The palette opens with no active controller and offers "Add Project…"; choosing a project also gives it a zone and a spawner; `tileSpawner` stops falling back to a departed project's boot spawner; note/browser/open-file/diff-review refuse audibly. |

**Three things existing witnesses caught while this landed, each a real design
error rather than a fixture problem.** `--zone-runtime-duplication-check`: the
first rescue rule was too eager and pulled tiles out of another workspace's zone
— a project's zones can span workspaces, so a stamp naming a zone this document
does not contain is now deferred. `--workspace-sidebar-actions-check`: narrowing
`liveZones` to the installed layers made zones below the live tier vanish from
framing and hit-testing. `--palette-browser-spawn-check`: gating spawns on "no
scope" broke boot-only fixtures; the real signal is "no spawner".

**Two expectations were corrected rather than relaxed.**
`--workspace-runtime-install-check` pinned adaptive chrome for a layer, which
contradicts the decision Model B already implements (a zone renders at its
STORED frame so the visible rectangle IS the grab target).
`--spawn-placement-check` pinned zone-local frames on disk; every file in the
field is world, and the flat boot path reads it as world.

`AGENTS.md` hazard 9 corrected again: yesterday it said "fixed" when the truth
was "unreachable".

---

---

## Probe P — settle the steering protocol

No code. Foreground only: two background subagents attempting this were orphaned
by host restarts and produced nothing. Deliverable is captured JSONL appended to
`.plans/43` §4d-pre, not prose.

| id | probe | result | status | evidence |
|---|---|---|---|---|
| P.1 | claude stdin message mid-turn | **QUEUE, not steering.** 76 s essay turn, B sent at t=12.6 s, all 12,997 chars written unaffected, B replayed at t=81.2 s as its own turn | **SEEN** | `probes/45-steering/claude-stdin-queue-{short,long}.jsonl` |
| P.2 | claude `control_request{interrupt}` | **Real, acknowledged in 1 ms.** `control_response{success, still_queued: []}`; turn truncated 12,997→5,378 chars; CLI authors `[Request interrupted by user]`; **result is `error_during_execution`, `is_error: true`**; the queue then drains | **SEEN** | `probes/45-steering/claude-control-interrupt.jsonl` |
| P.3 | pi `--mode rpc` | **31 commands incl. `steer` (mid-turn, before the next LLM call), `follow_up` (queue), `abort()` (clean, awaited), `compact`, `fork`, `get_commands`, `get_session_stats`.** pi is the most capable harness and Array uses none of it | **SEEN** | quoted in `.plans/43` §4d-pre from pi's own `rpc-mode.js` / `agent-session.d.ts` |
| P.4 | codex `app-server` | **`turn/steer` (with an `expectedTurnId` precondition), `turn/interrupt`, `thread/compact/start`, `thread/fork`.** `ThreadSourceKind` includes `subAgentThreadSpawn` — subagent work is a first-class thread. **Schema only; no session run** | **SEEN** (schema), subagent claim UNVERIFIED | `probes/45-steering/codex-appserver-protocol.json` |
| P.5 | pi signal table | superseded by P.3 — the fix is `abort()`, not a different signal. Prior measurement stands for the one-shot mode Array ships: SIGINT→130, SIGTERM→143, **no session file written** | **SEEN** | `.plans/43` §4c |

### What Probe P changed

1. **All three harnesses have real interrupt; two have real mid-turn steering
   (pi, codex). Array runs the one mode of each that exposes none of it.** This
   inverts 42/43's assumption that claude was the steering-capable harness.
2. **Ticket 4a.3 got more important, not less.** claude reports a *clean,
   acknowledged, user-requested* interrupt as `is_error: true` /
   `error_during_execution`, so `ClaudeEventTranslator.swift:255`
   (`isError ? .failed : .completed`) maps it to `.failed`. The `stopRequested`
   flag is mandatory on the **clean protocol path**, not only for signals.
3. **Stop is two verbs, confirmed by all three.** An interrupt cancels the
   *turn*; the queue drains afterwards. Cancelling the queue is separate.
4. **`system/init` arrives per turn, not per session** — good for ticket 3a.2's
   "discover, don't hardcode".
5. **New tickets 4d.1–4d.3** below: the mode migrations. Each is a
   translator/transport rewrite, not a flag.

| id | ticket | detail | status |
|---|---|---|---|
| 4d.1 | claude → `--input-format stream-json` | move the prompt off argv onto framed stdin; adopt `control_request{interrupt}` for Stop; consume `still_queued`; render `[Request interrupted by user]` as a harness-authored row. Cheapest of the three | TODO |
| 4d.2 | pi → `--mode rpc` | a new translator. Unlocks `steer`, `follow_up`, `abort`, `compact`, `fork`, `get_commands`, `get_session_stats` — i.e. slices 3a, 3b, 3c and 4 at once. Biggest capability payoff | TODO |
| 4d.3 | codex → `app-server` | a new transport. Unlocks `turn/steer`, `turn/interrupt`, `thread/fork`, and possibly first-class subagent threads. **Verify the subagent claim by running app-server before designing on it** | TODO |

**Hygiene:** `timeout` does not exist on this macOS — python3/perl or
background+kill. Fresh `/tmp` dir, never inside a git repo under the project.
Never modify `~/.codex/config.toml`, `~/.claude/settings.json`,
`~/.pi/agent/settings.json` — flags and `-c` only. Never touch tmux. Render
evidence, not claims.

---

## Slice 0 — scene integrity (blocking)

A workspace switch replaces every tile with a title-label placeholder, and
`openDocument` calls `switchWorkspace` itself. `persistProjectCanvas` then
rewrites the project's canvas file from installed layers only.

| id | ticket | producer / change | witness | status |
|---|---|---|---|---|
| S0.1 | the witness, RED first | — | new leg `--workspace-rehydration-check`: drive real `switchWorkspace`, assert `tileView(for:)` is not `DescriptorTileNSView`, responds to a transcript update, exposes a composer | TODO |
| S0.2 | real hydration on every zone-layer build | extract `ContinuumApp.swift:4053-4075` into an injectable `TileViewHydrator`; call from all four descriptor loops — `WorkspaceRuntime.swift:229-234`, `:361-365`, `:393-396`, `:680-684` | S0.1 goes GREEN | TODO |
| S0.3 | stop `persistProjectCanvas` truncating | `TileSpawner.swift:2213-2232` — merge over persisted `state.tiles` rather than replacing; `tiles(forProjectId:)` at `CanvasNSView.swift:5214-5220` reads installed layers only | new leg `--project-canvas-truncation-check` | TODO |
| S0.4 | stop misfiling a revealed cross-project agent tile | `attachTileToAgentFromInbox` (`ContinuumApp.swift:9465-9486`) → use `spawnerForFilesystemCreation()` (`:13432`); stamp scope from the agent record, not `creationScopeProvider` (`TileSpawner.swift:1474, :1501-1505`) | extend `--cross-project-agents-check` | TODO |
| S0.5 | correct `CLAUDE.md` hazard 9 in place | all four named spawns are migrated; the stale-path spawn is `spawnRunArtifacts` (`TileSpawner.swift:2246, :2262`) plus `spawnDiffReviewFromPalette` (`ContinuumApp.swift:13491-13512`); the `:1422` citation is in the **renovation plan**, not `CLAUDE.md` | doc change; no leg | **SEEN** 2026-08-22 |
| S0.6 | hand `.plans/41` its overlap | 41's C and E fixed by `ecf3bf3`; D **inverted** — `retireFlatCompatibilityScene()` clears `zoneRenderModels` (`CanvasNSView.swift:5051-5066`) and nothing repopulates it; A/B untouched and bear on document links | doc change; no leg | **SEEN** 2026-08-22 — appended to `.plans/41` |

**Exit:** both new legs print in a real matrix run; a workspace switch followed
by a link click leaves every tile live; a spawn in one zone does not shrink the
canvas file. Seen in a two-zone scratch project.

---

## Slice 1a — fixtures and gates (invisible)

Correction that shapes this slice: `agent.transcript.review` owns no committed
PNG baseline (eight sweeps guard on `.staticCard`), **but** four bespoke callers
do cover it and two of them gate — `UIProbePixels.swift:489-511` (non-blank,
text-rect floors, contrast spread) and `ComponentLab.swift:4008` (row-count
minimums). The two image-comparing legs, `--component-lab-check` and
`--ui-baseline-check`, are both `MATRIX_KNOWN_RED`.

| id | ticket | change | witness | status |
|---|---|---|---|---|
| 1a.1 | extend the review-state matrix | `AgentTranscriptReviewState` (`ComponentLab.swift:53-59`) 5 → full set: preparing, provider wait, thinking, tool work, writing, input wait, failure, stop, completion; tool cluster; folded turn; expanded turn; edit-with-diff; table; thematic break; heading ladder h1–h6; 10,000-entry perf fixture. Documents from `LabFixtures.transcriptReviewDocument(_:)` (`:99`), hosted by `AgentTranscriptReviewSurface` (`:897`), which owns a real list view — keep it production, not a mock | — | TODO |
| 1a.2 | route them into the sweeps that run | per-state `.staticCard` at 320/480/640/900 in both appearances; keep the `.reviewSurface` knob card; extend `UIProbePixels.swift:489-511` to the full matrix; extend `runTranscriptReviewCheck` row minimums; add states to `UITourCheck.swift:151-155` | `--ui-pixel-check` covers every state | TODO |
| 1a.3 | register the legs properly | 4 coupled edits: dispatch in `ContinuumApp.main()` (`:1463-1473`); `run_app_check` line in `run-matrix.sh`; regenerate `docs/38-tickets/90-agent-ux/matrix-inventory.txt` with `CONTINUUM_UPDATE_MATRIX_INVENTORY=1`; classify only if genuinely red | new legs print in a real run | TODO |
| 1a.4 | record the transcript perf number | re-run `--perf-budget-transcript-delta-check`; currently 37.31 ms / 8.3 ms with `worstInvalidatedTopLevel` 1 of 2 | number recorded here | TODO |

---

## Slice 1b — tool data capture (invisible)

Verified: the sole production `recordEnd` call
(`AgentTranscriptListView.swift:1522`) passes status only, so `output`,
`exitCode` and `duration` are permanently nil, and
`AgentToolDetailPresenter.expanded(_:)` is called only by checks.

**Never widen `AgentRuntimeEvent`** — I5 sync boundary. `AgentToolDetailStore`
is the sanctioned channel, pre-authorized by
`plan-managed-agent-tile-polish.md` §12.3. Keep the fail-closed redactor and
every `AgentToolDetailLimits` cap.

| id | ticket | producer | status |
|---|---|---|---|
| 1b.1 | widen the observation | `AgentRuntimeObservation.toolActivity` / `AgentObservedActivity` carry sanitized arguments, output, exit code, `endedAt` | TODO |
| 1b.2 | claude translator | `ClaudeEventTranslator.swift:265-302` keeps only a path whitelist (`bash` has `pathKeys = []`). Capture `old_string`/`new_string`, `tool_result` content, `is_error`. `input_json_delta` dropped at `:139-140` | TODO |
| 1b.3 | codex translator | fix literals `"Shell"` (`:130`) and `"Edit"` (`:147`); read `changes[]`; surface the `default:`-swallowed types (`mcp_tool_call`, `web_search`, `todo_list`, `collab_tool_call`) at minimum behind a debug log. Pinned to codex 0.145.0; installed 0.148.0 | TODO |
| 1b.4 | pi translator | already holds the whole `args` object (`PiEventTranslator.swift:288-311`); capture `apply_patch` args and exit codes | TODO |
| 1b.5 | the call site | `AgentTranscriptListView.swift:1522` passes `output`, `exitCode`, `endedAt` | TODO |
| 1b.6 | the witness | extend `--tool-detail-check` to drive a **real translator event sequence** into the store and assert `expanded(_:)` yields non-nil `exitCodeText` and `timingText`. Today `UIProbeToolDetail.swift:85/122` hand-writes the record, which is why it passes while production is empty | TODO |

**Exit:** `--tool-detail-check` RED before, GREEN after, failing for the real
reason. Nothing visible yet.

---

## Slice 1c–1h — the visible overhaul

| id | ticket | detail | status |
|---|---|---|---|
| 1c.0 | delta path precondition | `run-matrix.sh:618-627` records the cause: `apply(document:patch:)` calls `flatten(document)` regardless of the patch — 36 ms for one revised tail row on 10,000. Fix, then take the leg off KNOWN-RED | **DONE** 2026-08-24 — see G0 below; leg off KNOWN-RED |
| 1c.1 | row geometry | one 32pt row; reserved trailing status column so text never reflows; reserved leading glyph column | **DONE** S4.0–4.2 (`0105c3cf`) |
| 1c.2 | per-tool iconography | **GREEN 2026-08-23** (pulled into the visual milestone by Dylan; no 1b dependency). `ToolCallView.symbolName(forToolNamed:)` matches on substrings because the three harnesses disagree on casing and wording for the same operation; an unknown name keeps the wrench, so a new provider tool degrades to today's behaviour rather than to a blank column. |
| 1c.3 | status as a glyph | completed uses foreground colour, not green — only failures pull the eye | **DONE** S4.0–4.2 (`0105c3cf`) |
| 1c.4 | summary/title dedup | `ToolCallRenderer.swift:105` compares only against `presentation.label`, so `Edit` / `Edited Foo.swift` both render | **DONE** S4.0–4.2 (`0105c3cf`) |
| 1c.5 | cluster consecutive tool calls | one group with a hairline gutter instead of N stacked cards | **DONE** S4.3 (`c2ceb9dd`) |
| 1c.6 | detail while running | `presentedToolBlock` returns early at `AgentTranscriptListView.swift:1354-1356`, second gate `:1394-1396` | **DONE** S1–S3 (`bbc3d086`) |
| 1c.7 | distrust provider status | sniff `exited with exit code N`, `ENOENT`, "no such file" — providers report `completed` on failing commands | TODO |
| 1c.8 | expanded body as fields | render `AgentToolDetailExpandedPresentation` as an argument table, output pane, exit code, duration. `CommandOutputView` (`CommandOutputRenderer.swift:39`) is that pane and is dead code — give it its first production caller | **DONE** S1–S3 (`bbc3d086`) |
| 1c.9 | surface truncation flags | `truncatedByBytes`, `truncatedByLines`, `redacted`. Never silently truncate | **DONE** S1–S3 (`bbc3d086`) |
| 1d.1 | inline diff | reuse `GitDiffParser.parse` (`GitDiffEngine.swift:236`, pure) and `DiffReviewTileNSView.render(_:theme:)` (`:317`, static+pure). Bounded with a visible "+N more lines" | TODO |
| 1d.2 | do not copy the freeze pattern | `AgentDiffSummaryView.rebuildFileLabels()` (`DiffSummaryRenderer.swift:188-200`) removes and recreates up to 8 `NSTextField`s on **every** apply, called unconditionally from `:90` | TODO |
| 1d.3 | measure-key correctness | any per-row indent must enter `AgentBlockMeasureKey` or a nested row reuses a top-level row's cached height at the wrong width | TODO |
| T1 | `AgentEntry.createdAt` | **GREEN 2026-08-23**, teeth-verified. The producer for the hover time, landed BEFORE the thing that draws it. Optional and `decodeIfPresent`, so every transcript already on disk still loads; the provider defaults to `{ nil }` so the reducer stays a pure function of its mutations and no existing witness flapped; `AgentTranscriptProjection(threadId:)` (production) opts in, its injected-clock sibling does not. Witnessed in CoreChecks against the PRODUCTION construction path, since the field existing is not the same as the shipping path filling it in | GREEN |
| T2 | review-state matrix | **GREEN 2026-08-23**. Six new `AgentTranscriptReviewState`s routed into `UIProbePixels` (the only transcript pixel gate that is not KNOWN-RED) and `UITourCheck` (advisory PNGs at 4 widths × 2 appearances — the review mechanism for the whole milestone). No `.staticCard`: a missing baseline is a failure by design, so new static cards would owe committed PNGs and redden two more legs | GREEN |
| 1e.1 | inter-turn separation | **GREEN 2026-08-23**, `--transcript-rhythm-check`, teeth-verified. `AgentTranscriptLayout.spacingBefore` is an index-keyed closure beside the existing `measuredHeight` one; `Row` gained `entryID` (it lived only in `rowPositions`, which the layout cannot see). **A turn is a user prompt AND its reply** — the first cut treated every entry change as a boundary and put a rule between a prompt and its own answer. No assertion caught that; the rendered tour did. The `prepare()` fast path gained a boundary signature, or a row whose entry changed without the count changing returns stale geometry. Rule + hover time are ONE `CAShapeLayer` and ONE `CATextLayer`, never a view per turn (trap 1). |
| 1e.2 | hanging indents | **GREEN 2026-08-23**, teeth-verified. New `AgentProseTextStyle` carries `headIndent`/`firstLineHeadIndent` through resolve→append→appendText AND through `measuredHeight`; no transcript text previously set `.paragraphStyle` at all. Markers are DRAWN from cached attributed strings, not sub-viewed. **The first version of the witness had no teeth** — it asked whether SOME row had an indent, which the quote satisfied alone, so it stayed green with list indents entirely disabled. It now counts rows and distinct depths. |
| 1e.3 | heading ladder | **GREEN 2026-08-23**. Six rungs out of THREE usable sizes: `Typography` has only `titleL` 18 / `title` 15 / `body` 13 above `label`, and `minimumLadderStep = 2.0` is itself gated, so 14 and 16 cannot be slotted in — the ladder is size + weight + colour + space-above. The witness counts distinct rendered (size/weight/colour) triples read off the first glyph, because a witness phrased as "the renderer receives the level" agrees with a renderer that receives it and discards it, which is what it did. |
| 1e.4 | fewer fills | **GREEN 2026-08-23**. Fill dropped (to `nil`, never `.clear` — hazard 8) on `ToolCallView` and `AgentImageGalleryView`; `CommandOutputView` moved to `codeSurface` because it IS code; code/diff/plan/approval keep theirs per `_DESIGN.md` §11. |
| 1e.5 | Error ≠ Notice | **GREEN 2026-08-23**. Error keeps the artifact fill and gains an `AgentLineRole.attention` outline — the one case §11 permits a strong semantic line; notice gives up both and sits on the tile body. Witness compares painted fill/border signatures, not title strings. |
| 1e.6 | align the left edge | **GREEN 2026-08-23**, teeth-verified (24 vs 12). One constant: `horizontalReadingInset` 12 → 0, since the layout already insets every row by `contentInsets.left`. **`--ui-geometry-check` pinned the constant itself** to `Inset.card.left` — an expectation encoding the old decision; corrected to assert the clip/escape invariant against whatever the inset is, with the alignment promise moved into the new leg. |
| 1e.7 | table renderer | **GREEN 2026-08-23**. New `AgentBlockKind.table` + `AgentTablePayload` (header, rows, per-column alignment, retained source). Six enumeration sites updated — the compiler found each one. Cells are DRAWN, not sub-viewed (a 3×20 table would be 60 TextKit stacks in one row); every measurement is in `measure(...)`, never `layout()`; each cell's contribution to the column solve is capped at 220pt so one long cell cannot produce the unbounded measurement `performance.md` names. **`MarkupParserChecks` pinned `Table → .fencedCode`** — an expectation that encoded the fallback; corrected to assert cells, alignment and retained source. |
| 1e.8 | thematic breaks | **GREEN 2026-08-23**. `.thematicBreak` was parsed and in `builtInKinds` but matched no registry branch, falling to `AgentDeferredBlockRenderer` — a bare `NSView` measuring 24pt, a 48pt hole with row spacing either side. New `ThematicBreakRenderer`. **`UIProbeCompletedReasoningDisclosure` pinned the deferred renderer's safe label**, i.e. asserted the feature was unimplemented; corrected to the real splitter role. |
| 1e.9 | `Opacity.receded` | **GREEN 2026-08-23**. Applied to settled (`.completed`) tool rows — §11's "completed routine work recedes". A failure never recedes. Not stacked with a secondary colour: 0.88 is derived to sit just above the AA break-even at 0.8724, and `--ui-contrast-check` is the catcher. |
| 1f.1 | turn folding | `Worked for 1m 12s · 8 tools · 2 agents`, preserving the terminal assistant message. Never fold a streaming turn; auto-expand a turn interrupted in-session. **Land on top of 1c.5** — folding without clustering re-derives the grouping twice | TODO |
| 1f.2 | running-turn windowing | show the last tool row, hide the rest behind `+N previous tool calls` | TODO |
| 1f.3 | fixed chrome heights | fold, toggle and tool rows, so scrolling back through unmeasured content does not jump | TODO |
| 1g.1 | live-work row | preparing → provider wait → thinking → tool work → writing → input wait → failure → stop → completion, with elapsed and a working Stop. **States come from the phase machine Slice 2 fixes** — will look right and behave wrong until then. Do not ship as done | TODO |
| 1h.1 | `TokenThemed` ×12 | `ToolCallView`, `CodeBlockView`, `AgentErrorNoticeView`, `AgentPlanView`, `AgentDiffSummaryView`, `AgentRequestView`, `CommandOutputView`, `UserPromptView`, `AgentReferenceChipView`, `AgentUnknownBlockView`, `ImageRenderer.swift:146/580`, `FileReferenceRenderer.swift:100`. **Zero** conformers exist under `Canvas/AgentTranscript/`, so `UIProbeAppearance.swift:128` and the source scan at `:570-583` have never seen any of them. Each needs conformance + a `tokenAdoptedOwners` entry with a ticket comment + paint in both appearances + `nil` at rest, never `.clear` | TODO |
| 1h.2 | lineage overlay token | `AgentLineageOverlayView.swift:27` uses raw `NSColor.controlAccentColor.withAlphaComponent(0.34)` | TODO |
| 1h.3 | `ToolCallView.layout()` | **GREEN 2026-08-23**. All five frames now go through an `if view.frame != frame` guard and each `intrinsicContentSize` is read once. `AgentDiffSummaryView.layout()` has the identical shape plus a `boundingRect` measurement inside `layout()` — **not** fixed here, still open. |

---

## Slice 2 — dead air / feel

Count/ordering witnesses only, never a stopwatch. Measured baseline (pi 0.84.1,
trivial prompt): first byte 0.62 s at `session`, `turn_start` ~1.5 s, total
11.7 s — the indicator is suppressed for that window, bounded by model latency,
so it widens with real work.

| id | ticket | detail | status |
|---|---|---|---|
| 2.1 | the missing witness, RED first | `AgentFirstPaintChecks.swift:139-148` hand-builds `AgentTileTurnSnapshot(state: .starting, …)`; `updateTurnFacts` and `turnSnapshot(for:)` are never called. Drive the real `[.ready, .running, .turnStarted]` and assert `.starting` throughout | TODO |
| 2.2 | stop clearing `submittedAt` | `AgentSupervisor.swift:3994-3998` **and** `:3985-3989`, each with a dedented duplicate | TODO |
| 2.3 | `.running`-without-turn needs a phase | `AgentCompactStatusPhaseAdapter.swift:236-241` returns `.unknown`, so even with 2.2 the words go blank | TODO |
| 2.4 | seed compact-status facts on `send` | not only `attach` (`ManagedAgentTileNSView.swift:1128`) | TODO |
| 2.5 | `persist(record)` off the main actor | called `AgentSupervisor.swift:2042`, defined `:4080-4104`; `@MainActor` + synchronous + `withAgentStoreLock` (`:1880-1905`, blocking cross-process `flock(LOCK_EX)`) + two `fsync`s | TODO |
| 2.6 | queue during readiness `.checking` | the first message after launch is currently dropped, not delayed | TODO |
| 2.7 | sticky indicator across tool boundaries | every text→tool→text transition calls `closeStreamingRun()`, flips `latestStreamIsVisible`, toggles the gyro, and triggers a full apply + layout | TODO |
| 2.8 | consume `system/status status:"requesting"` | a genuine pre-token ack discarded at `ClaudeEventTranslator.swift:71-72` | TODO |
| 2.9 | cache `RoleRegistry`; `git rev-parse` off-main | main-actor directory walk + frontmatter parse per pi turn; `refreshBranchContext` at turn end | TODO |

---

## Slice 3 — commands, compaction, `/clear`

`AgentSupervisor.accept` (`:3322-3332`) serializes every non-`.cli` command to
`"/name args"` and sends it as an ordinary user turn. Nothing switches on
`surface == .array`.

| id | ticket | detail | status |
|---|---|---|---|
| 3a.1 | the three-tier engine | Array-owned (`/clear`, `/new`, `/fork`, `/status`, `/diff`, `/help`) → a system row Array authors; harness-delegated (`/compact`, `/context`, `/model`) → a harness-authored control row reconciled against `system/status`; skill/template → a normal user turn | TODO |
| 3a.2 | discover, don't hardcode | claude publishes `slash_commands` (47 here, incl. project-local), `skills`, `agents` on `system/init`. Keep 40/64/13 only as the pre-first-turn fallback | TODO |
| 3a.3 | `<local-command-stdout>` discriminator | plus `num_turns: 0` and zero usage, so CLI control output stops rendering as an assistant turn | TODO |
| 3a.4 | one command, two appearances | the popover path skips the optimistic echo; the typed path does not | TODO |
| 3a.5 | bare Enter swallowed | `focusedID` starts nil (`ChoiceListView.swift:107`) | TODO |
| 3a.6 | disable with a reason | never silently degrade a command into prose | TODO |
| 3b.1 | consume `compact_boundary` | open the `subtype == "init"` gate at `ClaudeEventTranslator.swift:71-72`; metadata gives `trigger`, `pre_tokens`, `post_tokens`, `cumulative_dropped_tokens`, `duration_ms`, preserved uuids | TODO |
| 3b.2 | first-class compaction block kind | not the `Notice` variant — depends on 1e.5 | TODO |
| 3b.3 | occupancy from `post_tokens` | the ring holds the pre-compaction percentage until the next turn completes. Also unblocks `automaticCompaction` (`TokenUsageSnapshot`, rendered at `AgentCompactStatusPresentation.swift:564-565`, hardcoded nil by all three translators) | TODO |
| 3b.4 | render the handoff collapsed | attributed to the harness; distinguish `manual` from automatic | TODO |
| 3b.5 | stop discarding `compaction` lines | `PiSessionTranscriptReader` loses the boundary *and* the pre-compaction history on rehydration | TODO |
| 3c.1 | `/clear` session identity | claude/pi session ids are pure functions of the agent UUID (`AgentSupervisor.swift:1029, :1039`) — needs a changed derivation or `--fork-session` | TODO |
| 3c.2 | `/clear` stale state | `record.lastContextWindow` re-seeds as `.stale`-but-numeric; the tile is permanently named after the slash command if `/clear` is the first prompt (`displayNameSource` leaves `.sentinel`); subagent chips keep resolving | TODO |
| 3d.1 | delegation, per-harness honesty | pi: install/ship `continuum-spawn-agent.ts`, pass `-e`, allowlist. claude: `--forward-subagent-text`, stop dropping `parent_tool_use_id` frames (`ClaudeEventTranslator.swift:118-121`, used `:92/:96/:100` — note `result` at `:103` is **not** filtered), key on the `Task` tool_use id. codex: re-probe on `multi_agent_v2`; surface `collab_tool_call`. **The claude half is the largest visible product per line of diff in the program** — consider pulling forward if Slice 1 runs long | TODO |

---

## Slice 4 — steering and interruption

Shape decided by Probe P. 4a and 4b are unambiguous wins regardless.

| id | ticket | detail | status |
|---|---|---|---|
| 4a.1 | pi gets a `stopRequested` flag | `PiAgentRunner.swift:290-292` terminates with no flag anywhere in the file; `:280-282` throws unconditionally | TODO |
| 4a.2 | check the flag **before** the throw, all three | claude throws `:291`, reads flag `:293`, second unguarded throw `:297`. Codex throws `:257` and `:267-270` with no consult at all | TODO |
| 4a.3 | emit `turnCompleted(outcome: .interrupted)` | activates eleven existing consumers, incl. the unreachable `APNSPushService.swift:283-285` branch — **pressing Stop currently pushes "agent failed" to the phone** | TODO |
| 4a.4 | the witness | drive a runner that actually throws on stop; assert not `.failed`, `didFail == false`, no error block, `latestTerminalEvent.outcome == .interrupted`. All seven stop checks drive `ScriptedAgentRunner` whose `stop()` (`AgentSupervisor.swift:4219-4222`) cannot throw | TODO |
| 4a.5 | a signalled pi loses the turn | measured: the session dir is created and left empty; the next run with the same `--session-id` says "No project session found… creating a new session". Silently discards continuity while Array still shows the history. Worse than the reported bug and currently invisible | TODO |
| 4b.1 | signal the process group with escalation | reuse `cleanupProcessGroup` (`AgentSupervisor.swift:660-688`), `killProcessGroup` (`:823`), `processGroupGrace = 0.15` (`:280`), `POSIX_SPAWN_SETPGROUP` (`:613-614`). No runner uses `setpgid`; all three use Foundation `Process` + `terminate()`, so tool subprocesses survive | TODO |
| 4c.1 | type-ahead as a queued message | `canSend = !occupied && state.acceptsNewTurn` with `occupied = runners[id] != nil` (`:3253-3264`); `sendStop` hardcodes `canSteer: false, canQueue: false` (`AgentComposerIntent.swift:207-209`) while `AgentComposerPresentation.swift:72-76` already implements the chips; `.queued` is rendered and unreachable; `AgentComposerDraftStore` already holds one in-flight submission with a lease/journal/recovery protocol | TODO — P.1 answered: claude queues, pi/codex steer |
| 4c.2 | fix the silent Enter | `workingDraftIntent` returns nil (`AgentComposerIntent.swift:238-245`) and `AgentComposerView.swift:617` drops it. Enter **with an attachment** bypasses that (`:606-612`), forces `.sendPrompt`, is refused `.turnNotReady`, and rolls back the optimistic bubble | TODO |

---

## Slice 5 — note / file linkage

| id | ticket | detail | status |
|---|---|---|---|
| 5a.1 | overlay bounds origin | `updateDocumentRelationshipOverlay()` sets `frame = worldPlane.bounds` (`CanvasNSView.swift:1701-1702`, init `:1171`) and passes raw world frames (`:1720-1721`). `CanvasWorldPlaneView` carries the pan in `bounds.origin` (`:112`). `setBoundsOrigin` appears nowhere for the overlay — a world point *q* lands at *q + pan* | TODO |
| 5a.2 | scale the stroke by zoom | `lineWidth = 1` in world units at alpha 0.18 (`DocumentRelationshipOverlayView.swift:61-62`) — at zoom 0.35 that is ~0.35 device points at 18% opacity | TODO |
| 5a.3 | re-run the pixel witness off-origin | built at `FileOpenChecks.swift:1132-1136` as `CanvasViewport(x: 0, y: 0, zoom: 1)` and never re-set — the one camera at which the bug is invisible. Witness at `:982-1002` | TODO |
| 5a.4 | give the lineage overlay a witness | geometry is **correct** (`overlay.convert(parent.bounds, from: parent)`); it has zero coverage and one trigger | TODO |
| 5b.1 | refresh after the boot tile walk | `refreshDocumentRelationships()` has four call sites (`WorkspaceRuntime.swift:411, :546, :582, :711`); the provider is assigned at `ContinuumApp.swift:3991`, the tile walk at `:4053`. Connectors and "N references" chips are invisible on every cold launch | TODO |
| 5b.2 | fix the relaunch witness ordering | `FileOpenChecks.swift:1063` sets the provider **after** installing tiles — the correct order production does not use | TODO |
| 5c.1 | `.revealed` must move the camera | `focusSpawnedTile` never does; `revealTileForWork` does `framedViewportForTileJump` + `setViewport` | TODO |
| 5c.2 | resolve against the checkout root | `cwd = checkoutRoot + homeRelativePath` (`AgentSupervisor.swift:1656-1659`, `AgentLocationSnapshot.swift:68-73`), so a subfolder Home breaks every repo-root-relative path | TODO |
| 5c.3 | percent-decode non-`file:` destinations | decoding happens only in the `file:` branch (`AgentLocalFileLink.swift:53-63`) — `[doc](My%20File.md)` looks for a file literally named `My%20File.md` | TODO |
| 5c.4 | `displayOnly` links must look inert | `AgentTextStyleResolver.swift:104-111` underlines every link but adds `.link` only for `openExternally | openInternally | openLocalFile`. Underlining something unclickable is the lie | TODO |
| 5c.5 | end the silent refusal | replace stderr-only (`ContinuumApp.swift:13319-13322`) with a quiet inline affordance — keeps the "not a modal" instinct, ends the silence. Note this reverses plan 15's own requirement | TODO |
| 5c.6 | wire `onOpenLocalFile` in the respawn-suppressed branch | or visibly mark a dead-transcript tile read-only | TODO |
| 5c.7 | extend the link witness | drive `AppDelegate.openAgentLocalFile` rather than its own closure (`FileOpenChecks.swift:833-843` diverges on **both** root and project id); assert viewport containment | TODO |

**5d — consolidation notes, not yet tickets.** Markdown is a presentation mode
of `.file` and of `.note`'s Preview, reusing `FileMarkdownDocumentView`.
Document identity does no case folding, so `README.md` / `readme.md` yield two
tiles on APFS. `DocumentAgentLink` has no path, note id, source tile id, label
or line. `convertNoteToDocument` is destructive and unlinked, and its
`.reusedExisting` branch deletes the note while returning a different tile's id.
Links live on `WorkspaceDocument` in Application Support while the tile record
lives in the project's `.array` canvas. `emphasized` reads
`canvasState.lastActiveTileId`, which `retireFlatCompatibilityScene()` nils.

---

## Cross-cutting

| id | ticket | detail | status |
|---|---|---|---|
| X.1 | every persisted transcript is effectively write-only | `TileSpawner.swift:1477` mints `managed-<uuid>`; `installInitialManagedAgentTile` uses the **default** `threadId = "thread-main"` (`ManagedAgentTileNSView.swift:227`); the sole reader hardcodes `"thread-main"` (`ContinuumApp.swift:8335-8342`). So a spawned agent is unreadable until relaunch, then writes a different key and its earlier snapshots stay orphaned forever. `recover(...)` and `remove(agentID:sessionID:)` have **no production callers**. The store's own check picks its own key — the witness must drive the production writer *and* the production reader | TODO |
| X.2 | cross-project child tile install | a child whose `projectId` differs is installed into the active project with only a stderr warning (`ContinuumApp.swift:9456-9459`). S0.4 covers the reveal path; this is the other half | TODO |
| X.3 | companion stays paused | a transport with no cargo; the phone path cannot work until X.1. Revisit only after the desktop has the intended feel | TODO |

---

## Standing verification doctrine

- Judge `run-matrix.sh` by its **end-of-run summary**, never the exit code.
  Confirm every new leg prints. Never add a KNOWN-RED silently. Two program
  checks pin that script's text verbatim with `grep -Fxc`, one locking its first
  four lines; `check-matrix-inventory.sh` reads a renamed wrapper as deleted
  checks.
- Never guess a `--*-check` flag — an unknown one falls through the cascade and
  boots the full app. Enumerate from `ContinuumApp.swift`.
- Every witness drives the **real** entry point. Assert counts and ordering.
- `performance.md` is binding, and its traps live in this exact code.
- Keep the transcript's virtualization.
- New themed views: `TokenThemed` + `tokenAdoptedOwners` + both appearances +
  `nil` at rest.
- Never touch the live tmux server.
- **Look at it.** `scripts/dev-app.sh` against `~/array-scratch`, never
  `/Applications/Array.app` or `~/Documents/personal`.
- Commits under Dylan's identity only. No AI-attribution trailers.

## Known-red context to carry

`MATRIX_KNOWN_RED` at `09de0b0`: `--component-lab-check`, `--ui-baseline-check`,
`--nav-mode-check`, `--perf-budget-zoom-check`,
`--canvas-zoom-invalidation-probe-check`, `--perf-budget-magnify-slope-check`,
`--perf-budget-transcript-delta-check`, `--perf-budget-gesture-transition-check`,
`--tile-surface-residency-check`. Do not bisect these as regressions; do not add
a tenth.

## Follow-on: `.plans/47` (2026-08-23)

M1.10 made the workspace scene real. Hand-driving that build immediately found
what it could not: the zone new tiles land in never followed the user. Creating
a second zone moved `activeController` but not `activeProjectZoneId`, and
because `.zone` outranks `.recentExplicit`, correcting it in the scope picker
was overruled on the next spawn. Turning arming on then exposed a latent
frame/install split in every spawn path. See
[47-zone-targeted-creation.md](47-zone-targeted-creation.md); new legs
`--zone-arming-check` and CoreChecks `runCameraArmedZoneChecks`.

The lesson is M1.12's, repeated: **a ticket is not done until the behaviour has
been seen by hand.** 178 green legs preceded both of these findings.

## Redo milestone — real supply (S1–S3), 2026-08-24

Dylan rejected the rhythm milestone (`6926044b`) on sight: rows rendered
`search` / `searching` / `✓ Completed` with nothing else, "In progress" went
stale, nothing showed timing. Plan:
`~/.claude/plans/plans-45-transcript-program-handoff-pro-reactive-otter.md`.

**S1 — the replay fixture.** Committed
`Sources/ContinuumRevivedCoreChecks/Fixtures/claude-websearch-turn.jsonl` — a
scrubbed REAL claude capture (78 frames), taken with the EXACT production argv
(`-p --output-format stream-json --verbose --include-partial-messages`). The
first capture lacked `--include-partial-messages` and replayed to a document
with no reasoning and no prose at all — the fixture must match the runner's
argv or it witnesses a stream production never sees. New review state
`.realClaudeTurn` replays it through `ClaudeEventTranslator` →
`AgentTranscriptProjection` (pinned runToken, stepped clock), routed into
UIProbePixels, UITourCheck, ComponentLab row floors, and
`--transcript-rhythm-check`. New witness `checkRealClaudeTurn` asserts Dylan's
complaints verbatim: query visible (not the gerund), zero in-progress after the
complete stream, "Thought for" on reasoning rows, a duration suffix on a tool
row. Observed RED at every one of those before the fixes; teeth-verified after.

**S2 — translators stop discarding.** `AgentRuntimeObservation.toolDetail`
(+ `AgentToolDetailObservation`, caps at construction) on the host-local side
channel; the location projector explicitly ignores it. Claude emits whitelisted
fields at `tool_use` (query/url/pattern/basename/description — `Bash.command`
NEVER) and a bounded `tool_result` preview; pi emits args-whitelisted fields,
result text previews, and `ts` instants (both events — the end branch emitted
nothing before); codex emits the INTEGER exit code + `aggregated_output`
preview, all `changes[]` basenames, and stops swallowing
`mcp_tool_call`/`web_search`/`todo_list` (rows now exist). Witnesses: sentinel
command strings asserted absent from the detail channel in all three backend
checks; `AgentWhatProjectionChecks` re-pinned to the split contract (patterns
and result previews sanctioned host-locally; command/edit/reasoning bodies
forbidden everywhere). Teeth: nulling the claude preview flipped the witness.

**S3 — the host feeds the store.** C2a fixed (activity merges files only; a
gerund can never win the name merge — `.toolActivity` starts carry the item
title and a nil timestamp). `captureRuntimeObservation` consumes `.toolDetail`;
pending observations hold a LIST per identity; `.ended` details buffer and fold
into ONE `recordEnd(output/exitCode/endedAt/status)` at `.itemCompleted`.
`presentedToolBlock` drops both in-progress early-returns (live detail) and
swaps the EPHEMERAL copy's name to `AgentToolDetailPresenter.collapsed`'s
actionLine; duration rides a presentation-only non-Codable payload field
(`presentedTrailingDetailText`, excluded from CodingKeys — I5). The presenter
quotes queries ("Searched for “…”"), adds a Fetched branch and a
description-as-sentence fallback, and capitalizes the fallback name (C6).
Reasoning durations derive from document createdAt spans in the list view
(next-entry boundary, nil never fabricated) — "Thought for Ns" renders (C5b).
`--tool-detail-check` now ALSO drives a real translator sequence through the
host capture path into the store (ledger 1b.6 closed): claude fixture for
actionLine/timing/preview, codex frames for the integer exit code.

Corrected expectations (defect-pins, not relaxations): quoted search summary in
`AgentToolDetailStoreChecks`; the geometry disclosure probe's record gains an
exit code because the action-first title absorbs the disclosure's first line.

Legs run green: rhythm, tool-detail (24), ui-geometry, ui-probe, ui-pixel,
delta-index-oracle, agent-supervisor, agent-first-paint,
agent-incremental-refresh, CoreChecks. Full matrix + gallery gate still owed
before any release (S7); S4 row/cluster + T3 corrections, S5 sweep, S6 tail
un-stomp next.

## Redo milestone — S4.0–S4.2 (turn corrections, action-first row, expanded pane), 2026-08-24

**S4.0 — T3 corrections.** `startsTurn` drops the previous-role clause
(consecutive queued prompts are distinct turns — fixture gained the u4/u5
case, teeth: restoring the clause flips the witness); `interTurnSpacing`
20 → `Space.xl * 2` (32) and the witness floor raised from 1.5× to 2× (teeth:
20 fails it); the hover witness now drives the REAL `mouseMoved` hit-test via
`qaHoverAtPointForChecks` + `qaTurnStartPointForChecks` (the entryID bypass is
gone); `checkTurnSeparation` gains a `.realClaudeTurn` pass (a single exchange
paints zero rules).

**S4.1 — action-first row.** The presented title is the sentence; the semantic
tool NAME survives on `presentedToolNameText` (presentation-only, non-Codable)
for the icon, tooltip and AX label. Trailing column reads "2.1s ✓" on
completed rows; failures keep their attention label. The view suppresses the
disclosure's first line when it repeats the title.

**S4.2 — expanded pane.** `presentedOutputText`/`presentedOutputNote`
(non-Codable, I5) carry the store's sanitized bounded output to the row;
expanding reveals a `CommandOutputTextView` pane (exact selection, copy
button) with truncation/redaction surfaced as a note. Never `.commandOutput`
blocks. The `.realClaudeTurn` fixture now folds its observations through a
REAL `AgentToolDetailStore` (real sanitizer, real merge; actor bridged
synchronously in fixture construction) and seeds the surface via
`seedStoreSanitizedToolDetails` — the untrusted-provider closure path
deliberately re-redacts URL-bearing output and is the wrong seam for store
snapshots. Witness: expanding the WebSearch row must reveal >40 chars of
result text; teeth-verified by severing the output feed.

Legs green after: rhythm, tool-detail, ui-geometry, delta-index-oracle,
ui-probe, ui-pixel, agent-first-paint, CoreChecks. Next: S4.3 clustering
(highest risk, lands behind its own witness), then S5/S6/S7.

## Redo milestone — S4.3 clustering, 2026-08-24

Dylan's design 2, landed as the recorded approach A: a display projection
(`AgentTranscriptClusterPlanner`, pure, O(rows) per visual apply) between
`rows` and the diffable snapshot, with a synthetic header item
(`AgentToolClusterHeaderItem`, fixed height, no fill — off the TokenThemed
census like the tail label). `rows == flatten(document)` untouched. Runs =
maximal consecutive `.toolCall`/`.commandOutput` rows, never crossing
`startsTurn`, split at failures (failures always plain); runs of 1 never
cluster; live runs render "N earlier steps" + plain live rows; the streaming
last turn holds its fold (t3 adoption: fold decisions key on turn lifecycle).
Cluster identity = first member's block ID; expansion state in
`disclosureStateStore`, surviving settling. Snapshot from `displayIDs` with
folded members ABSENT, re-applies guarded by `lastAppliedDisplayIDs`
(`qaVisualApplyCount == 1` held). All index-based sites moved to display
indexes: layout closures (signature hashes the display sequence incl. member
counts), tail item index, scroll anchors (a folded member's anchor maps to
its header), turn chrome, copy (a collapsed header contributes members'
copyBlocks), AX children. Header text re-drives directly as durations arrive
(`refreshVisibleClusterHeaders`), never via snapshot reload.

Witness `checkClustering` on `.recededWork` (3 consecutive settled tools + a
failure): exactly one header, "N steps · … ✓" line, the failed tool stays a
plain row, expand restores exactly 3 member rows to the snapshot, collapse
refolds, `qaClusterProjectionMismatch` nil at every step, semantic row count
untouched. Teeth: replacing the planner with identity flipped it RED. The
`.realClaudeTurn` state asserts zero headers (its tools are separated by
reasoning — a run never crosses a non-tool row; the plan's assumption that the
capture's searches would fold was wrong and the witness moved fixtures).

Full guarded sweep green: rhythm, ui-geometry, delta-index-oracle,
tool-detail, ui-probe, ui-pixel, agent-first-paint, agent-incremental-refresh,
agent-supervisor, CoreChecks.

## Redo milestone — S5 + S6 (honest status, live feel), 2026-08-24

**S5 — the turn-end sweep (C3).** `AgentTranscriptProjection.turnCompleted`
stops discarding the outcome: every itemID still in `activeItemIDs` gets
`completeBlock` (completed turns → `.completed`; failed/interrupted/cancelled
→ `.interrupted`) + `finishEntry`, and the set clears. Mirrored into the host
detail feed: identities awaiting an end get a status-only `recordEnd` at
`.turnCompleted` so the trailing glyph agrees. Witness
`runTurnEndSweepChecks` (CoreChecks, both call paths): the committed capture
TRUNCATED before its last tool_result, then `turnCompleted(.interrupted)` →
zero in-progress, the swept block reads interrupted, entries all finished; a
completed turn sweeps to completed. Teeth: emptying the sweep loop flipped it.

**S6 — live feel (C4 + C5, design 3).**
- Un-stomp: `refreshTranscriptThinkingIndicator` respects the optimistic
  window — while `pendingOptimisticSubmissionID != nil` the indicator stays
  on; the synchronize path used to re-derive from `descriptor.status ==
  .working` (not yet flipped) and kill it. Witness
  `checkOptimisticWindowSurvivesSynchronize` drives the REAL send → refresh
  sequence on a real tile; teeth: deleting the guard flipped it.
- Live verb: the tile derives a verb from the latest `.toolDetail` started
  observation ("Searching “…”", "Fetching …", "Editing Foo.swift", claude's
  Bash description) and the tail reads "verb · elapsed" on tool phases —
  store-sourced, cleared when the item ends.
- "Thought for Ns" shipped in S3's slice (document-derived createdAt spans).
- "Worked for Ns": at `turnCompleted` the tile measures submit → completion
  (`submittedAt` anchor — provider events alone undercount; t3's finding) and
  the tail row settles to the words without the gyro
  (`setSettledTailStatus`); interruptions read "You stopped after Ns" (t3's
  wording). The next send reclaims the row. Formatter carve-outs pinned
  ("4.3s", 9.97→"10s", "1m 15s").

Full guarded sweep green (rhythm, geometry, oracle, tool-detail, probe,
pixel, first-paint, incremental-refresh, supervisor, CoreChecks).

## Redo milestone — S7 gallery iteration 1, 2026-08-24

`scripts/transcript-gallery.py` pairs two `--ui-tour-check` runs into one
self-contained page (semantic-transcript surface, both appearances, data-URI
images). Iteration 1 published as a PRIVATE artifact:

- **URL (stable across iterations):**
  https://claude.ai/code/artifact/5a4f0368-43cc-440d-bfeb-28b374091c68
- before: `6926044b` (the rejected milestone, rendered from a worktree)
- after: `58336c09` (redo S1–S6)
- gallery published → **Dylan verdict: PENDING.** No release cut, no push to
  `main`, until this gallery (or a later iteration at the same URL) is
  approved. Live checkpoint: `~/Desktop/Array Transcript.app` rebuilt at
  `58336c09` on `~/array-transcript-verify` for a real hand-driven turn.

## Matrix run at `b6dca039`, 2026-08-24 (~02:30, display asleep)

181 legs. Expected KNOWN-RED held (6 of the listed set ran). Five failures —
`--terminal-tmux-live-integration-check`, `--terminal-theme-fidelity-check`,
`--terminal-snapshot-tier-check`, `--terminal-fills-tile-check`,
`--session-resume-check` — are ENVIRONMENTAL, not regressions: bisected by
rebuilding `6926044b` (yesterday's green matrix) in a worktree and rerunning
two of them — identical failures ("spawned terminal surface missing",
timeouts). `system_profiler` reported **Display Asleep: Yes**; these legs
spawn real Metal-backed Ghostty surfaces. Every transcript/agent leg is
green. Two follow-ups before any release:

1. One clean matrix run with the display awake (gated behind the gallery
   verdict anyway).
2. The summary flagged `--perf-budget-gesture-transition-check` as a
   KNOWN-RED that PASSED. Do NOT remove it from `MATRIX_KNOWN_RED` on this
   evidence — a perf gate passing on an idle 2 AM machine with the display
   asleep is not proof it is fixed (`.plans/44` context). Re-judge on the
   awake rerun.

## Gallery iteration 1 → Dylan's verdict, and the fixes, 2026-08-24

**Verdict on iteration 1: rejected, three specific complaints.** All three were
real and all three are fixed with witnesses that would have caught them.

1. **"no padding on the left of the user input box."** `UserPromptView` painted
   its fill from x=0 and laid its prose out from x=0 too, so the first glyph sat
   on the corner radius. Now a `Space.l` gutter both sides, and the prose
   MEASURES against the inset width (or a padded bubble clips its last line).
   New witness `checkFilledSurfacesPadTheirText` asserts the property for the
   whole CLASS of filled surfaces — user bubble, code, plan, diff, approval,
   command output — in one shared coordinate space, on three fixtures. Teeth:
   reverting the inset flips it, naming the view and the text run.
   Two measurement traps it had to handle: an `NSTextView` carries its padding
   as `textContainerInset` (its bounds do NOT show it), and hidden/empty labels
   keep stale `.zero` frames — both produced false positives first.
2. **"transcript review and changes might be too big."** The plan and diff
   cards were 40pt headers with 28–32pt rows and 16pt bottom insets. Diff card
   ~186pt → ~133pt (28% smaller), plan ~152pt → ~120pt (21%); both titles drop
   from a 15pt `.title` to a `.label` — the steps and the numbers are the
   subject, "Plan"/"Changes" is a label.
3. **"i want a proper diff styling."** The diff row was one concatenated string
   (`"Foo.swift   +42 −3"`) in the body font. Now a real diffstat: the path in
   monospace with MIDDLE truncation (a long path keeps its filename), `+42` in
   `accentDone` and `−3` in `accentFailed` as separate runs with monospaced
   digits so columns align, and a proportional add/remove bar
   (`AgentDiffStatBar`, git `--stat` style, not `TokenThemed` — it owns no
   background and the parent card assigns its two colours). Witness
   `checkDiffStatDensity`: one name label AND one stat label AND one bar per
   file, ≥2 distinct colours inside the stat runs, both counts present, every
   bar's share in (0,1], and ≤60pt of card per changed file. Teeth: painting
   removals with the additions colour flips it.

**Two defect-pinning assertions corrected, not relaxed** (both in
`UIProbeGeometry`, both pinning the exact flush layout that caused complaint 1):
`view.proseView.frame.minX == view.bounds.minX` → a SYMMETRIC gutter of at
least `Space.s` (the intent was "not a right-aligned percentage bubble", which
a symmetric inset satisfies); and `proseWidth / surfaceWidth >= 0.99` → the
prose spans exactly `surfaceWidth - 2 * horizontalInset` (the intent was "the
full readable measure, not a narrow chat bubble").

**Gallery iteration 2** adds a THIRD column: the last SHIPPED release
(`6926044b~1`), because iteration 1 compared only against the milestone Dylan
had already rejected — "the redo from before doesn't look much different" is
exactly right when the baseline is itself the rejected work. Same artifact URL.

Legs green after: rhythm (incl. both new witnesses), ui-geometry, oracle,
tool-detail, ui-probe, ui-pixel, first-paint, incremental-refresh, supervisor,
CoreChecks.

## Gallery iteration 2, 2026-08-24 — and two defects only the RENDER caught

Same URL. Baseline changed on purpose: iteration 1 compared against
`6926044b`, the milestone Dylan had already rejected, so "the redo from before
doesn't look much different at all" was a correct reading of a useless
comparison. Iteration 2 compares against **0.5.10** (`6926044b~1`) — the
release his workspace app actually runs.

**Reading the render, not the constants, found two defects the green legs did
not.** Both are now witnessed:

1. **The removal counts were clipped off every diff row** ("+84" rendered,
   "−19" did not). Cause: `intrinsicContentSize` on an `NSTextField` built from
   an EMPTY string does not reliably re-derive when `attributedStringValue` is
   assigned afterwards, and the under-measured frame clipped with
   `.byClipping`. Fixed by measuring `attributedStringValue.size()` directly
   and right-aligning the run. Witness: every stat label's frame must fit its
   own string. Teeth: halving the width flips it ("23.5pt wide but its text
   '+84 −19' needs 47.0pt").
2. **Every tool row echoed its own query** — "Searched for “recent sports
   headline”" followed by "query: recent sports headline" underneath.
   `observableDisclosureText` now skips an argument whose value already
   appears in the action sentence. Witness: no disclosure line may repeat a
   value already in the row's title. Teeth: removing the guard flips it,
   quoting both strings.

Also from looking: the diff card's title became a real uppercase eyebrow in
the secondary colour, so the summary sentence is the thing being read rather
than competing with a shrunken headline.

**The lesson, again, and it is the program's oldest one:** the legs were green
in both cases. `checkDiffStatDensity` asserted colours, counts and per-file
height and still passed with the numbers clipped in half, because it never
asked whether the frame FIT. A witness asserts what you thought to ask; the
render answers what you didn't.

Gallery iteration 2 published → **Dylan verdict: PENDING.**

## Dylan's live-app review, 2026-08-24 (four findings, all real)

He drove `~/Desktop/Array Transcript.app` on a real turn. Four complaints, and
the two most serious were only reachable AFTER a click — which is why every
still, and every green leg, had missed them. The tour now photographs the
OPENED transcript (`makeExpandedSemanticTranscript` → `*-expanded` shots) so
that state is reviewable at all.

1. **"expanding thoughts DO NOT WORK ... weird ass artifacting."** Root cause,
   found by instrumenting rather than guessing: `AgentBlockHostView` pins its
   renderer view to its own edges with CONSTRAINTS, which puts the host in the
   layout engine — and `reconcileBody` positioned those hosts by FRAME. The
   engine solved them back to 0×0 on the next pass (keeping the origin from the
   autoresizing mirror), so an expanded thought measured tall, drew nothing,
   and rendered its 1pt-wide text as the vertical dashes in his screenshot.
   Every other install of that view in the transcript uses constraints; this
   one now does too (a vertical constraint stack + per-host height constraints
   updated from the shared measurement cache only when the value changes).
   Diagnostic that found it: `passes=3 lastBodyWidth=408 frames=[(0,0,0,0),
   (0,40,0,0), (0,80,0,0)]` — the loop ran, with the right width, and the
   frames were still zero.
2. **"the spacing is still so WEIRD."** Three separate causes: the disclosure
   text repeated "Duration: 4.0s" under a row whose trailing column already
   read "4.0s ✓" (same echo class as the query line); the detail line hung
   from the row's left edge instead of its title's x; and reasoning rows
   reserved a disclosure column but no ICON column, so thoughts started 32pt
   left of the searches between them. Rows of every kind now share one text
   column, witnessed by `checkRowsShareOneTextColumn` (teeth: reverting the
   icon column reports `[52.0, 84.0]`).
3. **"too much vertical spacing ... spread out too much."** `rowSpacing`
   12 → 8 (`AssistantProseView` already uses 8 between its own sub-rows, so 12
   made every row gap wider than the paragraph gaps inside a reply), tool rows
   36 → 28, reasoning headers 36 → 24, detail bottom inset 12 → 4. The turn
   boundary carries separation instead, now at 4× the row gap.
4. **"expanding summarized actions should also look way nicer."** Expanded
   cluster members indent behind a hairline rail
   (`presentedIsClusterMember` → `ToolCallView.clusterRail`), so the group
   survives being opened; the expanded output pane sits on the code surface,
   indented to the text column, instead of floating full-bleed. The bucket
   noun for unknown tools is "tool", not "step" — "3 steps · 2 reads, 1 step"
   read as a counting error.

**Plus a supply bug his screenshot exposed:** his rows said "Thought", not
"Thought for 6s", while every fixture said the latter.
`ManagedAgentTileNSView` built its model through
`ManagedAgentTranscriptModel(threadId:monotonicNow:)`, which constructed the
projection's INJECTED-clock initializer, whose `wallClockNow` defaults to
`{ nil }` — so no entry in any LIVE transcript ever carried a `createdAt`: no
reasoning durations, and the hover-revealed send time never appeared on
anything the user had actually done. Fixed by defaulting that init to a real
clock; the four equality checks that need byte-identical documents now pass
`{ nil }` explicitly. Witness `checkLiveDocumentsCarryTimestamps` drives the
PRODUCTION model. Teeth: restoring the nil default flips it.

The pattern worth keeping: three of these six defects were found by opening a
PNG and looking, and one by printing internal geometry. The legs were green
for all of them.

## Stability pass (the flicker's real causes), 2026-08-24

Dylan: "the transcript is also super buggy, hard to read and keep track of the
responses, some flickering... Codex is so smooth." An investigation traced the
mechanisms before anything was animated. Four landed; the animation itself is
NOT done (see the open list below).

1. **The live fold was deleting the row under the reader.** My own S4.3 bug:
   the live branch folded when `earlier.count >= 1`, and the `tailStreaming`
   guard sits AFTER that branch so it never applied to a live run. Every time
   tool k completed and tool k+1 went live, the row being read was removed and
   replaced by "1 earlier step" — one hard shift per tool call, mid-turn, with
   `animatingDifferences: false`. Threshold is now 3.
2. **The fold decision keyed on a boolean that flips several times per turn.**
   `tailStreaming` was the thinking indicator's visibility, and the indicator
   hides whenever an assistant/reasoning entry is open and returns between
   streams — so the last turn's runs folded and unfolded with it. Replaced by
   an explicit `setTurnInFlight(_:)`, written once per turn boundary by the
   tile (turnStarted / turnCompleted / runtimeError / optimistic send /
   refusal).
3. **The tail path re-applied the snapshot unconditionally**, bypassing the
   identity guard `applyUnscrolled` has, and was not behind the 30Hz
   scheduler — a full re-prepare per indicator flip. It now uses the same
   guard, with the tail's own id folded into the identity so both paths agree.
4. **Every apply scheduled a tool-detail refresh**, which invalidated the
   measurement cache for EVERY tool row — a second, ungated geometry mutation
   per 30Hz apply, one main-thread hop out of phase with the coalesced one.
   Now it refreshes only when the set of bound identities changes, and
   invalidates only the blocks whose store `updatedAt` actually moved.
   (Dropping it outright broke `--tool-detail-check`: a path that binds an
   identity and applies a document with NO runtime events — a restored tile,
   and that probe — has no other trigger. Caught and fixed before commit.)

Not yet done, in the recommended order: the actual motion (implicit
`NSAnimationContext` at the house's 0.14s/easeOut over a final model state, so
every synchronous count/geometry gate still reads settled values), a
reduce-motion provider in the injected shape the sidebar uses, and
`updateRenderContext` wrapping itself in `applyPreservingReaderAnchor` (the one
path with no anchor policy at all).

Gates that constrain the motion work, for whoever picks it up:
`qaVisualApplyCount == 1`, `qaLastInvalidatedTopLevelCount == 1`,
prepare-pass delta ≤ 3 over 5,000 deltas, anchor restores within 0.5pt, and
`animatingDifferences` must stay false (the diffable apply would go async and
break the synchronous cluster assertions).

## Motion, and choices you can click (2026-08-24)

Dylan: "let's start with the finishing touches for UX, i want to take a lot of
the UX from codex and how smooth the transcript feels" — plus "handle some
parsing of the response like selecting options rather than typing options IF
possible… i dont want to go too crazy".

### 1. The motion the stability pass deliberately left undone

`AgentTranscriptMotion` is now the transcript's whole motion vocabulary, and it
holds to two rules that are the reason it is allowed to exist next to these
gates:

- **Presentation only.** Every animation is a `CABasicAnimation` whose
  `toValue` is the value the model ALREADY holds. Nothing assigns `alphaValue`,
  a frame or a constraint, so a synchronous read straight after the call
  returns the settled value and `--ui-geometry-check`, the appearance census
  and the delta oracle see exactly what they saw before. No snapshot is
  touched, so `animatingDifferences` stays `false` and
  `qaVisualApplyCount == 1` holds.
- **Off unless production turns it on.** `isEnabled` defaults to `false`;
  `applicationDidFinishLaunching` sets it, after the whole `--*-check` cascade
  and after the component-snapshot early exit. Every self-check leg, pixel
  baseline and tour render therefore photographs a motionless transcript. A
  frame caught mid-fade would be a flapping baseline, and a flapping fixture is
  a bug here, never a tolerance to widen.

What actually moves: a display item the reader has NOT seen before fades up
(0.18s easeOut); a tool row resolving its status settles (0.16s); a revealed
tool-output pane and an expanded reasoning body fade into the room the
remeasure just made. Row HEIGHT still changes in one step — the custom layout
owns that, and the reader's anchor is preserved across it. Softening the
content is what reads as "the row opened".

Two rules learned from the witness rather than guessed:

- **The first apply is history, not arrival.** Arrived IDs are seeded wholesale
  on the first apply, so a restored transcript materializes settled. Dissolving
  a whole opened tile into view would have been a worse jump than the one this
  milestone removed.
- **Settle on a STATUS change, never on the trailing text.** Keyed on text, every
  completed row blinked a second time when its duration arrived from the
  host-local detail store — not a state change, and exactly the noise being
  removed. The witness caught this: it reported two `NSTextField`s animating on
  a first render.

Also landed: `updateRenderContext` now wraps itself in
`applyPreservingReaderAnchor`. It was the one geometry-mutating path in the
transcript with NO anchor policy — it drops the whole measurement cache, so a
theme or appearance change mid-read dropped the reader wherever the raw offset
landed.

Witness: `checkMotionIsPresentationOnly` in `--transcript-rhythm-check`, on the
replayed real claude turn. Asserts all four halves of the bargain (off by
default, on it animates, the model stays settled mid-flight, first apply never
animates). Teeth-verified by removing the reasoning-body fade →
RED "expanding a reasoning disclosure with motion enabled ran no animation".

### 2. Selecting options instead of typing them

`AgentReplyOptionDetector` (in AgentContent, pure) reads a SETTLED assistant
turn and returns the choices it offered; `ComposerReplyOptionRailView` shows
them as chips above the editor, and pressing one writes the text into the
composer through `insertCompletion` — the same primitive a completion uses, so
the observer fires, the draft is journaled, and the send path sees nothing
special.

**What this deliberately is NOT.** It does not mint a `.question` block, build
an `AgentRequestPayload`, or resolve anything. A request is a request because a
harness OPENED one and is holding it (`.requestOpened` / `.userInputRequested`);
prose that happens to contain a list is not that, and dressing it up as one
would fabricate a response contract no harness offered — the same rule
`AgentTranscriptProjection` already states about empty choice lists. Pressing a
chip sends nothing: the user still sends, so a wrong detection costs a word to
delete rather than a turn. (The provider-request path remains unbound in
production; `onProviderResponse` is still bound only in checks. That is Queue
90 / M7 and untouched here.)

Detection reads STRUCTURE, not characters: the parser already produced a list
block with item children. The rules are narrow on purpose, because a false
positive puts words in the user's mouth at the one surface where a stray click
reaches a real agent — the last two meaningful blocks must be a paragraph that
asks (a question mark, or one of a small set of explicit invitations) followed
by a list of 2-4 short single-line items with distinct labels, and the entry
must be `.finished`. An item's chip is its leading phrase: "**Rewrite it** —
keeps the API" chips to "Rewrite it".

The offer withdraws whenever there is a draft (it would otherwise be poised to
overwrite what the user is writing) and whenever a turn is working (the
question it belongs to has already been answered by whatever was just sent).

Witnesses, deliberately split:

- `runReplyOptionChecks` (`ContinuumRevivedAgentContentChecks`) drives real
  Markdown through the real parser — a hand-built block tree would let the
  detector agree with a shape the parser never produces. Most of its
  assertions are NEGATIVE, each naming a reply a looser rule would have
  decorated: a summary list, a list above the prose, five items, one item, an
  essay item, two items that chip to the same label, a mid-stream turn, and a
  question the user has already answered. Teeth-verified by removing the
  question gate → RED on the summary list.
- `checkReplyOptionsReachTheComposer` (`--agent-first-paint-check`) drives a
  REAL tile with real runtime events (`turnStarted` → `contentDelta` →
  `turnCompleted`) and asserts the chips reach the composer, that mid-stream
  they do not, that pressing one fills the draft, starts no turn, and
  withdraws the offer. Teeth-verified by neutering the tile's refresh → RED
  "a settled turn that asked and listed offered []". This half is the one the
  pure leg cannot see: a perfect detector rendering nothing is precisely the
  failure the tool-detail vocabulary sat in for months.

Green: `--transcript-rhythm-check`, `--ui-geometry-check`,
`--transcript-delta-index-oracle-check`, `--agent-first-paint-check`,
`--tool-detail-check`, `--agent-incremental-refresh-check`, `--ui-probe-check`,
`--ui-pixel-check`, `--agent-supervisor-check`, `ContinuumRevivedCoreChecks`,
`ContinuumRevivedAgentContentChecks`. No new `--*-check` flag, so
`matrix-inventory.txt` is unchanged.

Noted, not fixed: laying a managed agent tile out offscreen logs one
`NSLayoutConstraint … exceeds internal limits`. It reproduces with the reply
rail empty, so it is a pre-existing tile-layout condition this new witness is
merely the first in that leg to surface.

## G0 — the delta budget re-measured, and a regression this milestone caused (2026-08-24)

The first item of the new program (`~/.claude/plans/plans-45-…`, M0) was to
re-measure `--perf-budget-transcript-delta-check`, because the published 36.3 ms
and its 56%/35%/8% attribution predated the 2026-08-24 churn reduction that
landed on exactly the two paths it blamed.

**The number moved the wrong way.** Measured in an isolated worktree, debug (the
configuration the matrix uses), four consecutive runs at HEAD: 50.202, 50.595,
50.365, 51.232 ms — under 2% spread, so this is a deterministic number, not host
noise. Every COUNT budget stays green (visitSlope 0, 1 visit/delta,
fullFlattens 0, worstInvalidatedTopLevel 1).

**Bisected, one build per commit, same machine, same session:**

| commit | what landed | worst delta @10k |
|---|---|---|
| `09de0b0` | 0.5.10, before the redo | **36.394 ms** ← reproduces the published number exactly |
| `bbc3d086` | S1–S3, real tool-detail supply | 42.967 ms (**+6.6**) |
| `0105c3cf` | S4.0–4.2, action-first row | 43.535 ms (+0.5) |
| `c2ceb9dd` | **S4.3, clustering** | 52.979 ms (**+9.5**) |
| `8a42d708` | stability pass | 53.994 ms (+1.0) |
| `e8a49cf2` | motion + reply options | 50.202 ms (**−3.8**) |

So the redo added **+17.6 ms** and today's work gave back 3.8. Two causes, both
per-apply passes over the whole history:

1. **`rebuildDisplayProjection()` — the larger half.** It is O(rows) once per
   visual apply, which the S4.3 design accepted explicitly on the grounds that
   "the scheduler already coalesces 5,000 deltas into one apply, so no per-delta
   O(history) pass." That reasoning is right for a burst and **wrong for this
   scenario and for slow streaming**: 20 deltas here are 20 applies, and each one
   pays the full walk. The mistake was reading the coalescer as an amortiser when
   it only bounds the worst case.
2. **The S1–S3 supply path — +6.6 ms** before any clustering existed, i.e. the
   presentation/lifecycle work over every entry.

**Consequences for the program.** 1c.0 is not the "threshold conversation" the
plan hoped for; it is real work, and it should be pulled forward rather than left
until M9. Both of the milestones that add to this path — M3 (inline diffs, which
adds a parse and a body) and M6 (up to 16 concurrent child streams) — would be
built on top of a budget already 6× over. The fix direction for both causes is
the same: make the per-apply pass proportional to what changed, not to history.

Method note for whoever repeats this: measure in a worktree with its own
`.build`, debug configuration, and take at least three runs. The scenario is
`PerfScenarios.transcriptDelta` and the shape is load-bearing — one entry per
turn with one block each.


---

## G0 — the delta path stops walking the history (2026-08-24, M0)

**A8 first.** The Slice 1c–1h table above marked 1c.0, 1c.1, 1c.3–1c.6, 1c.8 and
1c.9 `TODO` while all seven had shipped in the S1–S7 sections of this same file. A
stale table is how work gets done twice; corrected in this commit.

### What was wrong

`--perf-budget-transcript-delta-check` had been KNOWN-RED on wall clock for months
while every count budget stayed green. Re-measuring found the number had moved the
WRONG way. Debug configuration, isolated worktree, one build per commit, same
machine, worst of 20 tail-revision deltas at 10,000 rows:

| commit | what landed | worst delta |
|---|---|---|
| `09de0b0` | before the redo | 36.394 ms |
| `bbc3d086` | S1–S3 supply | 42.967 (+6.6) |
| `0105c3cf` | S4.0–4.2 row | 43.535 (+0.5) |
| `c2ceb9dd` | **S4.3 clustering** | 52.979 (+9.5) |
| `8a42d708` | stability pass | 53.994 (+1.0) |
| `e8a49cf2` | motion | 50.202 (−3.8) |

Four consecutive runs at `e8a49cf2`: 50.202 / 50.595 / 50.365 / 51.232 — under 2%
spread, so deterministic, not host noise.

**The reasoning error, recorded so it is not repeated.** S4.3 justified an O(rows)
`rebuildDisplayProjection()` per visual apply on the grounds that "the scheduler
already coalesces 5,000 deltas into one apply". That is true of a BURST and false
of slow streaming: twenty deltas arriving a second apart are twenty applies and
each paid the full walk. **A coalescer bounds the worst case; it does not
amortise.**

### The witness came first, and it is a COUNT

`transcript-delta.worstHistoryScansPerDelta`, limit `.exactly(0)`, committed RED at
**6** in `5cba885d` with the fix unwritten and the commit message saying so.
`recordHistoryScan(_:)` is called at each offending pass so a failure names which.
A millisecond threshold could not have done this job: it had been red for months
and named nothing, and "a content-only delta walks the history zero times" cannot
be satisfied by a fast machine.

### The nine passes

Six the counter watched, all in `applyUnscrolled` unless noted:

1. the reasoning-entry diff — only needed to purge disclosure state for REMOVED
   reasoning entries, and the incremental index refuses every structural patch, so
   on that path the removed set is provably empty. Skipped.
2. the `rowsByID` rebuild — patched at the changed slots.
3. `rebuildDisplayProjection()` — the planner's `RowFact`s are now cached.
   A content-only delta recomputes the changed slots and their successors
   (`startsTurn` reads `rows[index - 1]`), COMPARES them, and replans only when a
   fact or the tail-streaming flag actually moved. Facts are compared rather than
   assumed stable because a tool row's STATUS is a projection input and a
   content-only delta changes it.
4. the role-change scan — restricted to the rebuilt rows; no other row can carry a
   new role, by identity.
5. the `newIDs` array — `changedTopLevelIDs.intersection(newIDs)` became a filter
   on `rowsByID`, whose key set is exactly `rows.map(\.id)`.
6. `prepareToolDetailLifecycle` (called from `apply`) — a restricted pass that
   examines only the entries a content-only patch could have touched and patches
   the cache instead of rebuilding it. It refuses anything it cannot verify and
   falls back to the full pass.

Three more the counter did **not** watch, caught by the duration alarm afterwards
at 12.807 ms — worth recording, because it is the second time this axis has shown
that a count witness is blind to work it was not taught about:

7. `let oldRowsByID = rowsByID` was free while the dictionary was about to be
   REPLACED, and became a 10,000-key copy-on-write the moment the patched path
   mutated it in place. It now captures only the rows that can differ.
8. the diffable snapshot was built on every apply and applied only when the
   display identity moved. Now it is built inside that branch.
9. the identity itself was a CONCATENATED array (`displayIDs + [tailID]`), so
   comparing it allocated and walked the whole display sequence every delta. The
   tail flag is now kept beside the list instead of inside it, which hits Array's
   shared-buffer fast path whenever the projection was skipped.
10. `captureTurnTimes` rebuilt both date maps over every entry on every apply. A
    content-only patch cannot add, remove or reorder an entry, so the only way
    they go stale is an updated entry whose `createdAt` moved — which costs the
    changed set to check.

### Result

| | before | after |
|---|---|---|
| `worstHistoryScansPerDelta` | 6 | **0** |
| worst delta @ 10,000 rows | 50.202 ms | **5.749 ms** |
| scaling 10 / 100 / 1k / 10k | 0.37 / 0.73 / 4.8 / 50.2 | 0.34 / 0.42 / 0.75 / 5.75 |

`--perf-budget-transcript-delta-check` is **removed from `MATRIX_KNOWN_RED` in this
commit** — a listed leg that passes is reported as a stale allowlist.

Green in the same run: `--transcript-delta-index-oracle-check` (the live index is
still indistinguishable from a full walk), `--transcript-rhythm-check`,
`--ui-geometry-check` (including the 10,000-row virtualization and the 5,000-delta
coalescing cases), `check-agent-tile-ux-program.sh`,
`check-sidebar-native-ux-program.sh`.

**Why this had to come first.** M3 adds a diff parse and a body to this path and M6
adds up to 16 concurrent child streams. Building either on a budget 6× over is how
the app becomes unusable and subagents get blamed for it.

---

## Probes — 2026-08-24 (M0)

Three probes ran in throwaway `/tmp` dirs. No user dotfile was touched, no tmux
server was contacted, and every capture below is scrubbed.

### C1 — a real claude subagent stream (committed as a fixture)

`Sources/ContinuumRevivedCoreChecks/Fixtures/claude-subagent-turn.jsonl`, 55
lines, captured with production argv **plus** `--forward-subagent-text`:

```
claude -p --output-format stream-json --verbose --include-partial-messages \
       --forward-subagent-text "<prompt>"
```

Every open question C0 rested on is now answered by evidence rather than by
Anthropic's docs:

- **`parent_tool_use_id` is non-null on 4 frames**, all carrying ONE value, and
  that value is exactly the `id` of the parent's `tool_use` block whose `name` is
  `Agent`. Stable across every frame of that child. The four are the child's own
  `user` text, `assistant` tool_use, `user` tool_result and `assistant` text — so
  with the flag on, a child transcript is complete, not tool-calls-only.
- **`input` carries `subagent_type`, `prompt`, `description` and
  `run_in_background`**, and the content block carries a sibling
  `caller: {"type":"direct"}`. C7 publishes `subagent_type` (a role id) and never
  `prompt`.
- **The terminal `tool_result` carries a `tool_use_result` sidecar** with
  `agentId`, `agentType`, `resolvedModel`, `totalDurationMs`, `totalTokens`, a
  full `usage` breakdown and `toolStats`. That is where a child's isolated cost
  lives.
- **The `result` frame leaks child cost into the parent.** Its `modelUsage` is a
  COMBINED parent+child total per model, so a consumer that treats `result` as
  "this turn's parent cost" double-counts the subagent. `case "result"` at
  `ClaudeEventTranslator.swift:102` is the one unfiltered case; C7 owes it a
  decision, and the honest source for a child's cost is the sidecar above.
- **`capabilities`** = `["interrupt_receipt_v1", "interrupt_cancel_queued_v1",
  "msg_lifecycle_v1"]`. Feature-detect from this, never from a version string.
- **A `system/task_started` frame carries `spawn_depth`**, so Claude Code models
  depth explicitly and Array can read it rather than infer it.
- Weakness to respect: depth 1 only, one child, so the fixture cannot witness a
  nested `parent_tool_use_id` chain or two siblings of one parent call.

### B5.0 — does a headless CLI interpret a leading slash?

The answer differs per harness, which settles B5's design: the classifier must be
per-harness, and the prose fallback is a REGRESSION on two of three.

| harness | verdict | evidence |
|---|---|---|
| claude 2.1.241 | **INTERPRETS** | `/help`, `/status`, `/compact` return `model: "<synthetic>"` with `input_tokens: 0`, `output_tokens: 0`, `total_cost_usd: 0` — no model call. `/definitelynotacommand` → `"Unknown command: …"`. Several commands answer `"… isn't available in this environment."` |
| codex 0.148.0 | **PASSES AS PROSE** | a real turn: 113,485 input / 654 output tokens, the model ran web searches and answered conversationally about what it can help with |
| pi 0.84.1 | **PASSES AS PROSE** | a real turn, real cost, tool calls investigating "what is pi", conversational reply |

So Array's current serialize-and-send costs a codex or pi user a paid turn and a
wrong answer for every slash command they type. It is not a neutral fallback.
claude's own refusals (`/help`, `/status`, `/compact` in `-p`) must also not be
presented as working.

Flags confirmed verbatim in `claude --help` on 2.1.241: `--forward-subagent-text`
(documented as "only works with --print and --output-format=stream-json"),
`--agents <json>`, `--bare`, `--fork-session`, `--input-format <text|stream-json>`.
`codex app-server --help` self-labels `[experimental]` in its first line and
carries `daemon`, `proxy`, `generate-ts`, `generate-json-schema` subcommands.
`pi --help` documents `--mode <text|json|rpc>` and nothing further about rpc.

### pi rpc — and a correction to the data-loss story

The important finding **overturns the framing in `.plans/48` §4.2**. pi's
persistence is not a property of the mode or of the signal handler. It is
`SessionManager._persist()` (`session-manager.js:717-751`), shared by json and rpc
alike, and it is gated on a watermark:

> until a session's file entries contain at least one prior **assistant** message,
> every completed entry is held in memory only and nothing is written to disk —
> not even the session file. Once the session has ever produced one assistant
> message, every subsequent completed message is written with a **synchronous**
> `appendFileSync`, inline, before the event even reaches stdout.

Measured: a fresh rpc session signalled right after the `prompt` ack exits 143
with **no session file at all** — identical to one-shot. A session that already
had one assistant message kept every new message on disk under both SIGTERM and
SIGINT, and resumed cleanly afterwards.

Also measured: **rpc registers handlers for SIGTERM and SIGHUP only**. SIGINT
kills it raw, with no `dispose()`.

Consequences for M4 and for B1:

1. **B1's interim notice must be NARROWED, not deleted at M4.** The exposure is
   the first turn of a brand-new session, in both modes. A long-lived rpc session
   crosses the watermark once, early, and then loses at most the single in-flight
   message.
2. Array must not expect SIGINT to clean anything up in rpc mode.
3. `abort` is awaited and answers `{"type":"response","command":"abort","success":true}`;
   the process stays healthy and accepts the next `prompt` on the same connection.
4. `steer` is documented in `agent-session.js:986` as delivered *after* the
   current assistant turn finishes executing its tool calls, before the next LLM
   call — so it is turn-boundary steering, not mid-tool interruption. Do not
   promise the latter in the UI.
5. **The event stream really is the same function.** Both `modes/print-mode.js`
   and `modes/rpc/rpc-mode.js` import `toJsonEvent` from `modes/json-event.js`.
   Live diff of one prompt through both modes: identical types and identical key
   sets. rpc adds two protocol-only frame types, `response` and
   `extension_ui_request`, and omits print-mode's `session` header record (the
   same data is reachable via `get_state`). **`PiEventTranslator` needs exactly
   one change: ignore those two new top-level frame types.**
6. The vocabulary is 31 commands, not 32: `prompt steer follow_up abort
   new_session get_state set_model cycle_model get_available_models
   set_thinking_level cycle_thinking_level get_available_thinking_levels
   set_steering_mode set_follow_up_mode compact set_auto_compaction set_auto_retry
   abort_retry bash abort_bash get_session_stats export_html switch_session fork
   clone get_fork_messages get_entries get_tree get_last_assistant_text
   set_session_name get_messages get_commands`. Note `get_commands` returns the
   session's SLASH commands, not this vocabulary.
7. `RpcSessionState` = `{model?, thinkingLevel, isStreaming, isCompacting,
   steeringMode, followUpMode, sessionFile?, sessionId, sessionName?,
   autoCompactionEnabled, messageCount, pendingMessageCount}`.

Caveat on what was measurable: this account currently returns an immediate 400
("Third-party apps now draw from extra usage, not plan limits") for pi model
calls, so multi-second tool-use turns could not be driven. Q1 and Q2 were
measured around that with a preflight-ack race and with resumed sessions; Q3 is
source-read.

---

## Codex — the decision, settled by measurement (2026-08-24)

`.plans/48` §4.3 was right about the shape and wrong about the risk, in both
directions. A driven probe (codex-cli 0.148.0, ChatGPT auth, throwaway `/tmp`,
no user dotfile touched) settles it.

**The bug we were designing around does not reproduce.** #33267's "Encrypted
function output content could not be decrypted or decoded" did not occur.
`codex exec --json -c features.multi_agent_v2=true` ran clean on this auth, and
so did V1. Delegation genuinely happens — the child wrote real files, confirmed
on disk.

**And `exec --json` still cannot see any of it.** Every distinct frame across
three runs: `thread.started`, `turn.started`, `item.started`, `item.completed`,
`turn.completed`, with item types `agent_message`, `collab_tool_call`,
`command_execution`. The `collab_tool_call` frame is, verbatim and identically in
V1 and V2:

```json
{"type":"item.started","item":{"id":"item_1","type":"collab_tool_call","tool":"wait",
 "sender_thread_id":"<uuid>","receiver_thread_ids":[],"prompt":null,
 "agents_states":{},"status":"in_progress"}}
```

`receiver_thread_ids` and `agents_states` stayed **empty while real subagent work
was happening underneath**, and the child's file write never appeared as an item
event at all. So our original probe's "empty wait" reading was not a
misconfiguration after all — it is what this transport always shows. Setting the
feature flag buys Array **nothing**, which is the same conclusion the closed
`ThreadItemDetails` enum predicted, now measured rather than inferred.

**`app-server` does see it, and it is more real than "[experimental]" suggests.**
Driven end to end over stdio: `initialize` → `thread/start` → `turn/start` →
`turn/completed` → `thread/read`, with a genuine child thread running.

- `subAgentActivity` is a real `ThreadItem` variant: `{type, kind, agentThreadId,
  agentPath, id}`. **Its `kind` enum is `started | interacted | interrupted` —
  there is no `completed`.** `.plans/48` claimed four values; that was wrong.
- `thread/list` accepts `sourceKinds`, whose enum is `cli, vscode, exec,
  appServer, subAgent, subAgentThreadSpawn, subAgentReview, subAgentCompact,
  subAgentOther, unknown`. Filtering by `parentThreadId` returned the child.
- `thread/read` with `includeTurns` returns the child's turns including its
  `subAgentActivity` items.
- The handshake **requires** `capabilities: {"experimentalApi": true}`; without it
  `thread/start.multiAgentMode` is refused `-32600 requires experimentalApi
  capability`. And `multiAgentMode` is `explicitRequestOnly | proactive |
  {custom: String}` — **not** `"v2"`. The CLI feature flag and the per-thread mode
  are two separate knobs.
- Ownership, confirmed live against a running child rather than read out of a
  test suite: `turn/start` and `turn/steer` are both refused with exactly
  `-32600 direct app-server input is not allowed for multi-agent v2 sub-agents`,
  while `thread/read`, `thread/list` and `turn/interrupt` are allowed
  (`turn/interrupt` failed only on a deliberately wrong `turnId`, naming the real
  one).

**The ordering hazard is real and Array would hit it immediately.** Timestamped:

```
857797  turn/completed   thread=PARENT      <- the parent's turn closes
861409  item/started     commandExecution  thread=CHILD
872237  item/started     fileChange        thread=CHILD   (the real write)
878213  turn/completed   thread=CHILD
```

The child's work arrived **20 seconds after** the parent's `turn/completed`.
`CodexAgentRunner.emit()` treats `turnCompleted` as terminal and fires it at
process exit, so a naive port truncates or misfiles every late child event.

### So the codex arm is a RUNNER rewrite, not a flag

`CodexEventTranslator` is adaptable — 9 handled shapes, most needing renames.
Three need genuinely new mapping: `agent_message`/`reasoning` **stream real token
deltas** on app-server (`item/agentMessage/delta`) rather than arriving whole, so
the translator's "the whole reply arrives at once" comment is architecturally
false there; token usage arrives as a **separate** `thread/tokenUsage/updated`
notification correlated by `threadId`/`turnId` instead of inline on
`turn.completed`; and eight item kinds have no coverage at all today
(`subAgentActivity`, `collabAgentToolCall`, `dynamicToolCall`, `imageView`,
`sleep`, `imageGeneration`, `entered/exitedReviewMode`, `contextCompaction`) —
safely dropped by the `default:` discipline, but that is also why codex shows
nothing.

`CodexAgentRunner` is the hard part, and its premise is what breaks:

1. **Process-per-turn.** `runOnce()` spawns a fresh `codex exec` and blocks on
   `spawned.wait()` (`:389`). app-server is one long-lived connection for the
   agent's whole life. Everything downstream assumes "process exit == turn done".
2. **The terminal-event gate** (`:451-457`) is precisely the ordering hazard.
3. **Resume** relaunches `codex exec resume <thread_id>` and self-heals on
   **stderr text matching** (`isUnknownSessionFailure`, `:85-88`). app-server has
   no relaunch, and failure is a JSON-RPC code, not stderr text.
4. **`stop()`** SIGTERMs a process group (`:302-309`); the analogue is
   `turn/interrupt` over the live connection.
5. **`observeSpawnRequests`** (`:311-313`) is a no-op whose comment — "Codex has
   no `spawn_agent` side channel" — is now measurably false.

That rewrite is the same one that brings `turn/steer` and `turn/interrupt` to
Program B, so codex's subagent arm and codex's steering arm are one piece of
work, not two.

**De-risking step, taken first:** a single-agent app-server parity harness that
runs a non-delegating session end to end and diffs its event shapes against the
existing `CodexEventTranslator` fixture corpus — answering "is app-server really a
superset for the path we already ship" without touching production.

## Codex app-server parity harness — the de-risking step, taken (2026-08-24)

Built the harness the previous section called for, without touching
`CodexAgentRunner` or `CodexEventTranslator` (both stayed read-only). Verdict:
**single-agent parity holds.** app-server carries a strict superset of the 9
event shapes the exec-based translator already maps, for the non-delegating
path Array ships today. The two restructures already named in the decision
section (streamed deltas, separated token usage) are confirmed live and are
restructures, not gaps; a third restructure (`turn.failed` folding into
`turn/completed`) is confirmed too. The ordering hazard is confirmed live and
independently reproducible — not a one-off.

### The harness

`scripts/codex-appserver-capture.py` drives one `codex app-server` process over
stdio: `initialize` (`capabilities.experimentalApi: true`, otherwise
`thread/start`'s `multiAgentMode` field is refused `-32600`) → `initialized` →
`thread/start` → `turn/start` → poll for the **parent thread's own**
`turn/completed` (keying on any `turn/completed` conflates a delegating child's
completion with the parent's — the harness's own first version had this bug) →
an extra `--drain` window for late child activity → `thread/read`. Raw
send/recv frames land in an NDJSON capture file with wall-clock timestamps.

Exact argv, mirroring what `CodexAgentRunner.processArguments` already passes
to `codex exec` (`-c approval_policy=never`, `-c sandbox_mode=workspace-write`,
never touching `~/.codex/config.toml`):

```
codex -c approval_policy=never -c sandbox_mode=workspace-write app-server [--enable multi_agent_v2]
```

(`app-server` takes no `--experimental` flag of its own — that flag belongs to
`generate-json-schema`; `app-server` itself needs nothing beyond the `-c`
overrides and `--enable` for the delegating capture.) Model: `gpt-5.6-sol`
(fully-qualified slug read from `~/.codex/models_cache.json`, never a partial
pattern). Run against codex-cli 0.148.0, ChatGPT subscription auth, throwaway
`/tmp` cwds.

One correction the harness needed mid-flight: `thread/start` **mints its own
thread id** in the response (`result.thread.id`) — it does not accept a
client-supplied one. The first probe run was 100% `-32600 thread not found`
because it sent a locally generated UUID to `turn/start`.

### Two committed fixtures

- `Sources/ContinuumRevivedCoreChecks/Fixtures/codex-appserver-single-agent.jsonl`
  (108 lines) — one turn: run a shell command, then edit a file with the
  file-editing tool (not a shell redirect), report both. Exercises
  `commandExecution`, `fileChange`, `reasoning` (empty — reasoning text never
  streamed live here either, same as exec), `agentMessage` streaming, and
  `thread/tokenUsage/updated`.
- `Sources/ContinuumRevivedCoreChecks/Fixtures/codex-appserver-delegating-turn.jsonl`
  (61 lines) — a real `--enable multi_agent_v2` delegation: parent spawns
  exactly one subagent to run a slow shell command in the background and
  finishes its own turn without waiting. Contains real `subAgentActivity`
  (`kind: started`) and `collabAgentToolCall` items, and the late child
  completion.
- `Sources/ContinuumRevivedCoreChecks/Fixtures/codex-exec-single-agent-parity.jsonl`
  (11 lines) — the SAME two-step task captured separately through
  `codex exec --json`, for the equivalence check below. Not byte-identical to
  the app-server fixture (the model is not deterministic across two live
  runs) — that's why the equivalence check is structural.

All three scrubbed: home paths → `/tmp/fixture`, every thread/turn/item id
(UUID-shaped or `msg_`/`call_`/`exec-`/`item_`-prefixed) → a stable fake kept
internally consistent (the delegating fixture's parent→child link still
resolves after scrubbing — parent mints thread `...0001`, child is
`...0004`), machine hostname/installation id scrubbed. Grepped clean of
`/Users/`/`dylan` after scrubbing.

### The ordering hazard, reproduced on demand

Not just present in the original measurement — reliably reproducible by
prompting the parent to spawn a background subagent and finish its own turn
without waiting. Timestamped from the committed fixture's original capture:

```
turn/started    parent
item/started    subAgentActivity   parent   (kind: started)
turn/started    child
turn/completed  parent                                    <- parent's turn closes
item/started    commandExecution   child
item/completed  commandExecution   child    (~12s later)  <- the real work
turn/completed  child                        (~16s later)
```

### Parity table — the 9 shapes `CodexEventTranslator` handles today

| exec frame | app-server frame(s) | mapping |
|---|---|---|
| `thread.started` | `thread/started` (notification) | rename — same role, id lives one level deeper (`params.thread.id` vs `thread_id`) |
| `turn.started` | `turn/started` | rename; app-server's `turn.id` is a real server-minted id — nothing to synthesize/salt, unlike exec's per-process `runToken` scheme |
| `item.started` (`command_execution`) | `item/started` (`commandExecution`) | rename (snake_case → camelCase); same fields plus extras (`cwd`, `processId`, `source`, `commandActions`) not needed for the mapping |
| `item.completed` (`command_execution`) | `item/completed` (`commandExecution`) | rename; `exitCode`/`aggregatedOutput` keys renamed camelCase, same semantics |
| `item.started` (`file_change`) | `item/started` (`fileChange`) | rename; `changes[].path` is the identical field shape |
| `item.completed` (`file_change`) | `item/completed` (`fileChange`) | rename |
| `item.completed` (`agent_message`, whole text) | `item/started` (inert) → N × `item/agentMessage/delta` → `item/completed` (text NOT re-emitted) | **restructure** — real streaming replaces exec's "whole reply arrives at once" (that comment in `CodexEventTranslator` is architecturally false on this transport) |
| `item.completed` (`reasoning`) | same delta/complete shape as `agentMessage`, keyed by the same `item/agentMessage/delta` method | **restructure**, unconfirmed live either side (reasoning text never streamed in either transport during any capture here) |
| `turn.completed` (usage inline) | `turn/completed` (no usage) + separate `thread/tokenUsage/updated` (`threadId`/`turnId`-correlated) | **restructure** — usage is unbundled from turn completion, and arrives MORE OFTEN (after every tool call, not just at turn end); `tokenUsage.total` is the same cumulative-accounting figure exec's `usage.input_tokens`/`output_tokens` already are |
| `turn.failed` (standalone frame, `error.code`) | `turn/completed` with `turn.status == "failed"` and `turn.error` inline | **restructure** — no standalone failure frame; folds into the same notification success uses |

Not part of this ticket's scope (single-agent only), but visible on the wire
and worth naming for the next ticket: `subAgentActivity`, `collabAgentToolCall`
(both confirmed live, shapes captured in the delegating fixture),
`dynamicToolCall`, `imageView`, `sleep`, `imageGeneration`,
`entered/exitedReviewMode`, `contextCompaction` (none observed live). Also
unmapped and out of scope: `turn/diff/updated`, `account/rateLimits/updated`,
`mcpServer/startupStatus/updated`, `remoteControl/status/changed`,
`thread/status/changed` — none carry timeline-relevant content.

**A genuine improvement, not implemented here:** `thread/tokenUsage/updated`
also carries `tokenUsage.last` (this request's own tokens, not cumulative) and
`modelContextWindow` in the SAME notification — exact context occupancy
without cross-referencing the rollout log the way `CodexRolloutTelemetry` has
to for exec. Left as a noted opportunity; mapping it would widen scope beyond
the 9 shapes this ticket committed to.

### The translator sketch and its witness

`Sources/ContinuumRevivedCore/AgentProviders/CodexAppServerEventTranslator.swift`
— pure, same I5 discipline as `CodexEventTranslator` (command bodies, tool
output, and paths never cross into an `AgentRuntimeEvent`; generic titles
`"Shell"`/`"Edit"`), same `AgentRuntimeObservation` side channel for the
host-local detail store. Does not widen `AgentRuntimeEvent`. Covers the 6
single-agent-relevant shapes above (leaves the file-edit and command-execution
resolution logic byte-identical to exec's in spirit); does not attempt the two
unconfirmed/out-of-scope reasoning and delegation shapes.

`Sources/ContinuumRevivedCoreChecks/CodexAppServerParityChecks.swift`, wired at
the tail of `main.swift`, in three parts:

1. **Mapping pins** — synthetic app-server JSON-RPC lines (SECRET-marked
   command/output/path/diff/error-body strings) through the new translator,
   asserting each of the 9 shapes maps as the table above says, and that none
   of the secrets cross into an encoded `AgentRuntimeEvent` or even the
   whitelisted observation channel.
2. **Single-agent parity equivalence** — replays
   `codex-exec-single-agent-parity.jsonl` through the EXISTING
   `CodexEventTranslator` and `codex-appserver-single-agent.jsonl` through the
   NEW translator, reduces both to a `NormalizedShape` sequence (session/turn/
   item event kinds, consecutive `contentDelta`s of the same stream collapsed
   to one block, `tokenUsageUpdated` excluded and checked for presence
   separately — both restructures are named above, so this equivalence
   is honest about not requiring exact-count agreement on them) and asserts
   the two sequences are IDENTICAL. They are: 13 normalized events on each
   side. `expect(!execEvents.isEmpty && !appServerEvents.isEmpty, …)` guards
   against the comparison being vacuously true.
3. **The ordering-hazard witness** — a `NaiveTerminalGateTranslator` built
   inline in the checks file (mirrors `CodexAgentRunner.emit()`'s real
   terminal-event gate, per the decision section above: "treats turnCompleted
   as terminal and fires it at process exit") replays the delegating fixture
   and is asserted to DROP the child's late `commandExecution` completion and
   see only one `turn/completed` — **RED**, demonstrated, not hypothetical.
   The real `CodexAppServerEventTranslator`, which has no such gate (every
   method switches independently, keyed by the `threadId` the frame itself
   carries), replays the same fixture and is asserted to keep the child's
   completion and report BOTH turn completions — **GREEN**.

**Teeth-verified**, both directions: flipping the `commandExecution`
completed/failed mapping turned the mapping-pin check red (`FAIL: a zero-exit
commandExecution item/completed must map to .completed`), reverted after
confirming; reintroducing a real "stop after the primary thread's
turn/completed" gate into the actual translator (temporarily) turned the
mapping-pin check red too (a second `turn/completed` in the same test got
silently dropped) — proving the gate's absence is load-bearing, not
incidental — reverted after confirming. `swift run ContinuumRevivedCoreChecks`
green on the reverted state, extending the existing leg (no new matrix leg
added).

### Verdict

Single-agent parity holds cleanly. The three restructures are real but
mechanical (rename + re-shape, no lost information for the path Array ships
today). Nothing here changes the M7/4d.3 conclusion that codex's arm is a
**runner rewrite, not a flag** — `CodexAgentRunner`'s process-per-turn model,
its terminal-event gate, its stderr-text resume-failure detection, and its
no-op `observeSpawnRequests` all still need to change together, and that work
is still gated on Program B (steering) per the decision section. What this
ticket buys: the rewrite is no longer a leap of faith about whether app-server
can carry what exec already carries — it demonstrably can, for the
non-delegating path, and the one hazard that would silently corrupt a
delegating session (the parent-closes-before-child ordering) is now pinned by
a fixture and a witness instead of a paragraph.

---

## M0–M2 landings — 2026-08-24

One section per landing, newest last. Commit hashes are on `array/transcript-ux`.

### `a4ec37ef` — G0, the delta path (see the G0 section above)

### `c5831e5d` — C1's capture and the three probe findings (see Probes above)

### `4eb92ef9` + `88d00168` — C3, one stable transcript key

The writer was the TILE's thread id (`"managed-<tileId>"`) and the only reader
asked for the literal `"thread-main"`, so the companion had **never once** found
a transcript — two ends of one channel that never named the same thing. Fixing
the reader to match the writer would not have been enough: revealing an existing
agent mints a fresh tile id, so every reveal orphaned the previous directory.
The key itself was unstable.

`AgentTranscriptStore.canonicalSessionID(for:)` is the key, deliberately the same
string `AgentSupervisor.sessionId(for:)` hands pi as `--session-id` so the two
cannot drift into two names for one conversation. The tile keeps its own thread
id — a runtime event-routing concept, legitimately per-tile; what it stops being
is the name of a file on disk.

`migrateLegacySessionDirectories()` **adopts, never wipes.** The legacy session id
is read out of the archive because the directory name is an FNV-1a hash and is not
invertible; recovery goes through the ordinary `load` so an uncompacted journal
survives; and the document is rewritten under the canonical key, which also
rewrites the `sessionID` field INSIDE both files — without that, `load` refuses
the migrated transcript with `identityMismatch`. **A rename alone is not a
migration here.** Where a reveal left several directories the newest wins by its
own `savedAt` and the losers are quarantined. Idempotent. Runs detached at launch,
on the interactive path only.

Witness teeth: stubbing the migration call fails on "both legacy agents must be
adopted under the canonical key". The newest-wins clause later had to be made
deterministic (`8e6e35bd`) — it was failing about two runs in three because the
store re-snapshots on compaction with `Date()`, so the seed's timestamp depended
on whether compaction happened to fire. **A witness for an ordering rule must not
itself depend on ordering luck.**

### `983282f2` — C0b, one role concept and three roots

All three harnesses declare roles as a directory of markdown files with YAML
frontmatter and differ only in the dot-dir, so `RoleRegistry` takes a harness and
reads `.pi/agents`, `.claude/agents` or `.codex/agents`. The default stays pi.

`toolsArguments(roleId:allowingSpawn:)` is C8's fourth blocker — the one that
would have made shipping the other three still ship a dead feature. All twelve
`.pi/agents/*.md` roles declare a `tools:` allowlist and none lists
`spawn_agent`, so pi denied the verb to every roled agent even with the extension
loaded. Array appends it, at Array's own depth cap, rather than twelve markdown
files being hand-edited into tracking a code-level limit they cannot see.
**Withholding beats refusing after the fact: the model never proposes what it
cannot have** — the same shape as `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`.

### `0969f281` — `ItemKind` stops throwing away the event that carried it

A `String`-raw enum with a synthesized decoder threw on a value it had not heard
of. These values are persisted in activity events and cross to the companion, so
that is data loss: an older build meeting a newer kind loses the **event**, not
the field. It mattered now because both B6.2 (`.compaction`) and C7 (`.subagent`)
add a case, and adding one to the old shape would have reopened it on every
install that had not updated. `AgentContextWindowFreshness` in the same file had
already solved it; `ItemKind` now agrees.

### `5e4ac132` + `65643eb2` — C8, pi spawning reaches the model

Four independent blockers, all four or nothing. The extension is bundled
(`Sources/ContinuumRevivedCore/Resources/PiExtensions/`), `make-app-bundle.sh`
copies the generated resource bundle into `Contents/Resources` — placing it at the
app's top level makes `codesign` refuse to seal the executable, verified
empirically — an idempotent installer writes it to `~/.pi/agent/extensions/`
(confirmed as pi's auto-discovery root by reading `dist/core/resource-loader.js`),
and `pi --help` confirms `--extension, -e <path>`.

Two corrections during the ticket, both worth keeping. `processArguments` is
documented **pure so the matrix can pin it**, and the first version made it read
the host's home directory — the resolution moved to `Config.extensionPaths` with
an impure default, the same pattern the file already uses for `model`/`thinking`.
And a `-e` pointing at a file that does not exist would fail a pi launch for a
feature the user is not using, so `installedExtensionPaths()` resolves to `[]`
when the file is absent.

The installer's call site is `applicationDidFinishLaunching`, **not** beside
`ToolEnvironment.bootstrap()`: that runs only on the interactive path, after the
whole `--*-check` cascade, so no self-check leg can write into the developer's
real `~/.pi`. Deliberately not witnessed: whether the file reached the real home
directory. That is host state, and asserting it would make the matrix depend on a
home directory.

### `4dd62163` — B7.0, and it is sharper than the handoff said

`/clear` alone was **accidentally** safe: `SecretRedactor.removeLocalPathReferences`
eats it whole as path-shaped text. But a command WITH ARGUMENTS gets only its verb
eaten, so `/compact focus on the auth work` named the tile *"focus on the auth
work"* and set `displayNameSource` to `.prompt` — which disarms the naming funnel
permanently, so no later real prompt could ever rename it.

The guard goes in `visibleNamingText` because that is the only place that can
still tell; by the time the shared resolver sees the prompt, the verb has already
been redacted away. **A rule inherited from a side effect is not a rule.**

### `8e6e35bd` — B5's classifier, and compaction reaching the ring

`AgentCommandExecutionPlanner` resolves an invocation to `arrayOwned`,
`harnessDelegated`, `skillTemplate` or `unavailable(reason:)`. Capability comes
from the BOUND RUNNER, never `record.harness`. Discovery narrows only once it has
happened — claude's `slash_commands` arrives per turn, so refusing on a nil list
would disable every command until the first turn ran.

B6.1's `compact_boundary` event could not reach the context ring: it was tagged
`.unknown("claudeCompactBoundary")` because the enum lived in a file that ticket
could not touch, and `AgentContextOccupancy.promptTokens` returns nil for
`.unknown` — so the correctness fix was a **no-op**. The case is now named and
authoritative. Worth recording as a pattern: *a ticket scoped away from the file
it needs will find a way to look finished.*

### `9759887c` — C2, the two fan-out bugs that hid each other

`harness:` was a parameter of `fanOut` never forwarded to `spawn`, so every child
silently ran the SETTINGS default regardless of what the caller asked for or what
the parent was running. And `fanOut` never emitted `.childAgentSpawned`, so a
child got durable parentage in the record and no chip in the parent's transcript.
`handleSpawnRequest` had always emitted it; the two spawn paths simply disagreed,
and each bug made the other harder to notice. The witness asks for a harness that
is deliberately **not** the settings default, so a regression reads as a real
difference rather than an accidental match.

### `f575ed1e` — C7, translator half

An `Agent` (formerly `Task`) call is claude announcing a child it has **already
started inside itself**, so the request is `observedOnly`: Array may watch that
child and must never claim to run it. That distinction comes from the request
rather than from a harness name, which keeps it true during a migration.

The announcement is keyed by the `tool_use` id, because that is the value every
one of the child's frames carries in `parent_tool_use_id`. **A child announcement
Array cannot re-identify later is not worth minting.**

`subagent_type` joins the tool-detail whitelist (a role id, and role ids are
publishable); `prompt` on the same tool stays out. `Agent`/`Task` reached
`.commandExecution` through `default:`, which it is not.

The witness first asserts the FIXTURE carries non-null `parent_tool_use_id`
frames — a fixture-backed check whose fixture is empty witnesses nothing.

---

## M4–M6 landings — 2026-08-24 (continued)

### `9c3be0b3` + `87c79afb` — codex reaches app-server, opt-in

Single-agent parity holds: all 9 shapes `CodexEventTranslator` handles map to
app-server frames — 6 renames, 3 real restructures, no gaps. The three
restructures are worth naming because each breaks an assumption the exec
translator states out loud: `agent_message`/`reasoning` **stream** as
`item/agentMessage/delta` rather than arriving whole, so "the whole reply arrives
at once" is architecturally false there; token usage arrives as a **separate**
`thread/tokenUsage/updated` correlated by `threadId`/`turnId`; and `turn.failed`
folds into `turn/completed` with inline error info.

`CONTINUUM_CODEX_TRANSPORT=app-server` opts in; `exec` stays the default and the
anti-cheat baseline. Two RED→GREEN findings from the ticket's own checks:
app-server sends **no `thread/started` on `thread/resume`** (only on
`thread/start`), unlike exec which re-emits it on every resume — so a resumed
turn's session-ready events never fired until the notification was synthesized;
and `run()` could hang forever if the process died before posting
`turn/completed`, because nothing else could unblock the completion semaphore.

Deliberately NOT achieved: one long-lived process for the agent's whole life.
`AgentSupervisor` builds a fresh runner per send, which is the seam B2.2 below
opens. Subagent mapping stays a no-op; only the comment claiming codex has no
side channel was corrected, since that is now measurably false.

### `a903f424` — pi's rpc session transport

One long-lived `pi --mode rpc` child, `{id}`-correlated commands, and the event
stream forwarded unchanged. **`PiEventTranslator`'s entire diff is two ignored
frame types** (`response`, `extension_ui_request`) — which is exactly why pi went
first and claude second.

The ticket's teeth surfaced a real latent bug: the transport's EOF handler did not
clear `readabilityHandler`, so process exit busy-spun.

One field was inferred rather than driven — the `prompt`/`steer` payload's text
key — because the M0 probe could not run a real multi-second turn on this
account's billing. **Now confirmed as `message` against pi's own
`dist/modes/rpc/rpc-types.d.ts`**, which also documents `images?: ImageContent[]`
on the same commands (how attachments will ride) and
`streamingBehavior?: "steer" | "followUp"` on `prompt`. Confirmed-by-declaration
is not the same as driven, so the transport still defaults off.

### `98ab78ba` — B2.2, the seam both migrations stopped at

Neither transport could reach the supervisor, for the same reason: a fresh runner
per send and no notion of one that outlives a turn. `AgentSessionRunning` is a
REFINEMENT of `AgentRunning`, so the three one-shot runners do not conform and
compile untouched, keeping `.sendStop(...)` as their floor.

The load-bearing part is where capabilities come from: **the bound runner, never
`record.harness`.** A harness-name table lies for the entire migration window,
when pi-one-shot and pi-rpc are both live in one build — so a pi tile advertises
Steer when it is running on rpc and does not when it is running one-shot, from the
same record.

### `24a80cea` — B1, narrowed to what was measured

The notice fires only for pi, and only before the session has crossed pi's
persistence watermark. The narrowness IS the design: a notice that fired on every
Stop would be ignored, and being ignored is the same as being absent. Three
negative cases carry most of the witness.

It survives M4 rather than dying with it — rpc's SIGTERM/SIGHUP handlers looked
like the fix, but persistence is gated by the watermark in both modes.

### `31e9b3a6` + `2da3dd35` — A4, turn folding

`turnRanges(facts:)` extracted first as a pure no-op with a byte-identical-output
witness, committed alone; then `foldTurns` as a second pass over the same `[Item]`
list. It reuses `AgentToolClusterHeaderItem` via a new `Header.scope`, so **no new
view type**, and it runs only on the existing `factsChanged` replan path — not on
every delta. Delta budget after: 5.9–7.0 ms against 8.3.

### `6e7e2e00` — A6, and an honest stop

`AgentRequestView` conformed; floors re-measured 196/175 → 198/177.
**`ToolCallView` deliberately left unconformed**: its slots paint only
conditionally and the fixture's single tool call trips neither, so conforming it
today would trade one red for another. That is the audit the ticket asked for
doing its job.

### A7 — the gesture leg stays KNOWN-RED, and the re-judgement was not trustworthy

`--perf-budget-gesture-transition-check` was re-run three times: **pass, 10.461 ms,
9.835 ms** against an 8.3 ms budget. It still flaps, so the `MATRIX_KNOWN_RED`
entry stays.

But the honest note is that the machine had three agents building concurrently
during those runs, which makes any wall-clock leg untrustworthy in both
directions. **Re-judge this one on a quiet machine before acting on it either
way** — the same lesson the 02:30 run taught when five terminal failures bisected
to an asleep display rather than to the milestone. Its structural budgets are
green, which is the part that carries information.

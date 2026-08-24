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
| 1c.0 | delta path precondition | `run-matrix.sh:618-627` records the cause: `apply(document:patch:)` calls `flatten(document)` regardless of the patch — 36 ms for one revised tail row on 10,000. Fix, then take the leg off KNOWN-RED | TODO |
| 1c.1 | row geometry | one 32pt row; reserved trailing status column so text never reflows; reserved leading glyph column | TODO |
| 1c.2 | per-tool iconography | **GREEN 2026-08-23** (pulled into the visual milestone by Dylan; no 1b dependency). `ToolCallView.symbolName(forToolNamed:)` matches on substrings because the three harnesses disagree on casing and wording for the same operation; an unknown name keeps the wrench, so a new provider tool degrades to today's behaviour rather than to a blank column. |
| 1c.3 | status as a glyph | completed uses foreground colour, not green — only failures pull the eye | TODO |
| 1c.4 | summary/title dedup | `ToolCallRenderer.swift:105` compares only against `presentation.label`, so `Edit` / `Edited Foo.swift` both render | TODO |
| 1c.5 | cluster consecutive tool calls | one group with a hairline gutter instead of N stacked cards | TODO |
| 1c.6 | detail while running | `presentedToolBlock` returns early at `AgentTranscriptListView.swift:1354-1356`, second gate `:1394-1396` | TODO |
| 1c.7 | distrust provider status | sniff `exited with exit code N`, `ENOENT`, "no such file" — providers report `completed` on failing commands | TODO |
| 1c.8 | expanded body as fields | render `AgentToolDetailExpandedPresentation` as an argument table, output pane, exit code, duration. `CommandOutputView` (`CommandOutputRenderer.swift:39`) is that pane and is dead code — give it its first production caller | TODO |
| 1c.9 | surface truncation flags | `truncatedByBytes`, `truncatedByLines`, `redacted`. Never silently truncate | TODO |
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

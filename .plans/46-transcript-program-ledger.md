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
| **M5** | The visible overhaul | 1c.1–1c.9, 1d.*, 1e.*, 1f.*, 1g.1, 1h.* | 26 | 0 | 4–6 d |
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

## M1 ticket order

Work in this order; each row names the legs to run for that landing.

| step | ticket | affected legs |
|---|---|---|
| 1 | **M1.1** new `--zone-tile-hydration-check` | **RED 2026-08-22** — `act1: noteTileB must be a live tile after switching to WB, not a DescriptorTileNSView placeholder; got DescriptorTileNSView`. The preceding `viewB != nil` resolve assertion PASSES, which is what proves it fails for the hydration defect and not a lookup. Registered at `run-matrix.sh:588`; inventory regenerated to 362 records. Drives production wiring via `AppDelegate.configureWorkspaceRuntimeHooks()` (extracted in this ticket) rather than substituting its own closures. |
| 2 | **M1.2** `hydrateInstalledZoneTiles` after `setZones` | new leg, `--workspace-switch-check`, `--workspace-runtime-install-check`, `--zone-hydration-lifecycle-check`, `--multi-zone-render-check` |
| 3 | **M1.3** skip tiles with a live runtime | new leg, `--terminal-tmux-persistence-check`, `--browser-lru-budget-check` |
| 4 | **M1.4** `detach()` sweep before `setZones` | new leg, `--agent-restore-check`, `--agent-observer-independence-check` |
| 5 | **M1.5** `persistProjectCanvas` merge + `--project-canvas-truncation-check` | new leg, `--workspace-boot-persistence-check`, `--zone-save-isolation-check` |
| 6 | **M1.6** `spawnerForFilesystemCreation()` on inbox attach | `--cross-project-agents-check`, `--managed-agent-model-spawn-check` |
| 7 | **M1.7/M1.8/M1.9** stop-is-not-a-failure + process group + teeth | `--agent-supervisor-check`, `--strict-agent-harness-check`, `--managed-agent-live-check`, new stop witness |
| — | full matrix, then release | judged by the end-of-run summary |

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
| 1c.2 | per-tool iconography | resolved in the **normalizer**, not the view: terminal / square.and.pencil / eye / globe / wrench / bubble.left → SF Symbols in the renderer. Replaces the hardcoded `wrench.and.screwdriver` at `ToolCallRenderer.swift:66` | TODO |
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
| 1e.1 | inter-turn separation | `rowSpacing = 12` (`AgentTranscriptLayout.swift:11`) separates collection rows; prose already uses `blockSpacing = 8` (`AssistantProseRenderer.swift:43`). The missing tier is turn→turn (~20 + a turn marker) | TODO |
| 1e.2 | hanging indents | move `"• "` / `"› "` out of the text run into a gutter | TODO |
| 1e.3 | heading ladder | `AssistantProseRenderer.swift:211-219` gives every one of h1–h6 `textRole: .title`; level is used only for the AX value (`:88`) | TODO |
| 1e.4 | fewer fills | only code, diff, plan and approval keep a fill | TODO |
| 1e.5 | Error ≠ Notice | currently pixel-identical; precondition for Slice 3, where a compaction notice must not read as a failure | TODO |
| 1e.6 | align the left edge | artifact fills start at 12pt, prose at 24pt | TODO |
| 1e.7 | table renderer | `MarkdownAgentMarkupParser.swift:163` maps `Table` → `.fencedCode`, payload at `:291-302`. Also a `performance.md` known-slow: a wide table is one enormous single-line measurement at unbounded width. Fix both together | TODO |
| 1e.8 | thematic breaks | render as 24pt of nothing today | TODO |
| 1e.9 | `Opacity.receded` | 0.88 exists, no renderer applies it | TODO |
| 1f.1 | turn folding | `Worked for 1m 12s · 8 tools · 2 agents`, preserving the terminal assistant message. Never fold a streaming turn; auto-expand a turn interrupted in-session. **Land on top of 1c.5** — folding without clustering re-derives the grouping twice | TODO |
| 1f.2 | running-turn windowing | show the last tool row, hide the rest behind `+N previous tool calls` | TODO |
| 1f.3 | fixed chrome heights | fold, toggle and tool rows, so scrolling back through unmeasured content does not jump | TODO |
| 1g.1 | live-work row | preparing → provider wait → thinking → tool work → writing → input wait → failure → stop → completion, with elapsed and a working Stop. **States come from the phase machine Slice 2 fixes** — will look right and behave wrong until then. Do not ship as done | TODO |
| 1h.1 | `TokenThemed` ×12 | `ToolCallView`, `CodeBlockView`, `AgentErrorNoticeView`, `AgentPlanView`, `AgentDiffSummaryView`, `AgentRequestView`, `CommandOutputView`, `UserPromptView`, `AgentReferenceChipView`, `AgentUnknownBlockView`, `ImageRenderer.swift:146/580`, `FileReferenceRenderer.swift:100`. **Zero** conformers exist under `Canvas/AgentTranscript/`, so `UIProbeAppearance.swift:128` and the source scan at `:570-583` have never seen any of them. Each needs conformance + a `tokenAdoptedOwners` entry with a ticket comment + paint in both appearances + `nil` at rest, never `.clear` | TODO |
| 1h.2 | lineage overlay token | `AgentLineageOverlayView.swift:27` uses raw `NSColor.controlAccentColor.withAlphaComponent(0.34)` | TODO |
| 1h.3 | `ToolCallView.layout()` | `ToolCallRenderer.swift:132-163` assigns all five frames unconditionally **and** reads `intrinsicContentSize` four times per pass (`:145, :148, :154, :155`) — `performance.md` traps 2 and 3 together, on every display cycle | TODO |

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

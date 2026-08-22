# 43 — Agent tile transcript: UX overhaul proposal

Date: 2026-08-22

Status: **proposal for discussion.** No implementation started. Evidence and
citations live in [`42-agent-tile-transcript-ux-brainstorm.md`](42-agent-tile-transcript-ux-brainstorm.md);
this document is the sequenced plan built on it and is the one to keep editing.

Decisions taken so far (Dylan, 2026-08-22):

- **User messages stay full-measure.** Not right-aligned bubbles. Differentiate
  with a quiet fill plus a gutter marker. This resolves the contradiction
  between `_DESIGN.md` §11 and the renovation handoff in favour of the charter,
  and `UserPromptRenderer.swift:63-64` already encodes it.
- **Ship order: (1) UI overhaul including tool rows, (2) dead air / feel,
  (3) commands and what commands actually do — compaction, agents.**

---

# Corrections — verified against `09de0b0`, 2026-08-22

**Read this before relying on any claim below it.** Every item was checked
directly against HEAD while turning this proposal into an implementation plan.
The ticket breakdown now lives in
[`46-transcript-program-ledger.md`](46-transcript-program-ledger.md); the
sequenced plan lives in
`~/.claude/plans/plans-45-transcript-program-handoff-pro-reactive-otter.md`.
This document remains the design argument.

**Also: the working tree is clean.** The warning about another agent holding
uncommitted edits in `AgentSupervisor.swift` / `AgentComposerFooterView.swift` /
`ManagedAgentTileNSView.swift` no longer applies.

## The visual-witness story in §1a is wrong in both directions

§1a says `agent.transcript.review` is a `.reviewSurface` so *"every baseline
sweep skips it"*, and treats that as the reason the previous session worked
blind. Half right.

- **Confirmed.** Eight sweeps guard on `.staticCard` and `continue` past
  everything else — `UIProbeBaseline.swift:327`, `UIProbeContrast.swift:350`,
  `UIProbe.swift:265/300/318`, `UIProbeAppearance.swift:258/1349`,
  `UIProbePixels.swift:451`. The transcript owns **no committed PNG baseline**.
- **Missed.** Four bespoke callers of `LabCatalog.makeTranscriptReviewSurface`
  do cover it, and two of them gate:
  - `UIProbePixels.swift:489-511` renders `.mixed/.activeTool/.failedTool/
    .approval` × both appearances and **asserts** non-blank bitmaps, per-render
    text-rect floors and contrast spread. Runs in the matrix; green.
  - `ComponentLab.swift:4008` (`runTranscriptReviewCheck`) asserts per-state
    minimum row counts.
  - `UIProbeAppearance.swift:1965` covers `.mixed`.
  - `UITourCheck.swift:151-155/195` renders every state at 320/480/640/900 in
    both appearances into `qa-runs/<ts>/tour/` with a self-describing
    `index.md` — **advisory only**; `run-matrix.sh:434` captures its status and
    does not propagate it.
- **Also missed.** The two legs that *do* compare images,
  `--component-lab-check` and `--ui-baseline-check`, are **both in
  `MATRIX_KNOWN_RED`**, deferred to a supervised Retina-Main visual gate.

**Consequence:** converting to `.staticCard` routes the transcript into a sweep
family whose pixel half is already parked. Do it for the contrast, appearance
and geometry sweeps, but the gate that actually bites is the probe family, and
extending it is cheap.

## The transcript's own performance gate is silenced

`--perf-budget-transcript-delta-check` is in `MATRIX_KNOWN_RED`
(`run-matrix.sh:138`), measured in `.plans/44` at **37.31 ms against an 8.3 ms
budget — 450% over**, with `worstInvalidatedTopLevel` at 1 of 2. Neither this
document nor `42` mentions it, and both plan a tool-row rewrite on top of it.

`run-matrix.sh:618-627` names the cause: `apply(document:patch:)` **calls
`flatten(document)` anyway**, so one revised tail row on a 10,000-row transcript
costs 36 ms. Bounded and fixable, not a mystery.

## §5e is worse than described, and `persistProjectCanvas` is elsewhere

- **Four** descriptor-only loops, not two: `WorkspaceRuntime.swift:229-234`
  (`install`), `:361-365` (`addZone`), `:393-396` (`makeAmbientZoneLayer`),
  `:680-684` (`switchWorkspace`). Only the first carries the "T08" comment.
- The `installInitial*` family is **eleven** functions, each called exactly once
  from the boot switch at `ContinuumApp.swift:4053-4075`, reachable only from
  `applicationDidFinishLaunching`.
- `persistProjectCanvas` is **`TileSpawner.swift:2213-2232`**, not
  `CanvasNSView`, with **ten call sites** (`:327, :667, :916, :1000, :1030,
  :1094, :1177, :1451, :1532, :1917`). `:2222` reads
  `canvasView.tiles(forProjectId:)`, which at `CanvasNSView.swift:5214-5220`
  reads **installed zone layers only** — no flat fallback, no persisted source.
  The data loss is confirmed.
- The bad `TileSpawner.swift:1422` citation is in the **renovation plan**
  (`~/.claude/plans/we-had-a-codex-mighty-hinton.md`), not `CLAUDE.md`.
  `CLAUDE.md` hazard 9 has now been corrected in place; see `.plans/46` S0.5.

## The write-only transcript is subtler than "write-only"

Both halves of the claim are true, but the writer's key depends on the
construction site:

- `TileSpawner.swift:1477` mints `managed-<uuid>` → tiles spawned this session
  are **never readable**.
- `installInitialManagedAgentTile` (`ContinuumApp.swift:6324`) constructs
  `ManagedAgentTileNSView(tile:)` with the **default**
  `threadId = "thread-main"` (`ManagedAgentTileNSView.swift:227`) → boot-restored
  tiles happen to write the key the sole reader looks for
  (`ContinuumApp.swift:8335-8342`).

So an agent's snapshots are orphaned until a relaunch re-installs its tile, at
which point it starts writing a *different* key and the earlier ones stay
orphaned forever. Also: `AgentTranscriptStore.recover(...)` and
`remove(agentID:sessionID:)` have **no production callers**, so journals are
never replayed and nothing ever deletes a transcript directory.

## Smaller corrections

| claim in this document | correction |
|---|---|
| `composeIsBusy` "declared and never read" | Read at `ManagedAgentTileNSView.swift:2181` via `qaComposeEnabled`. Only a QA probe reads it — the substance holds, the wording does not. |
| claude throws `:293`, flag `:294` | Throws `:291`, flag read `:293`; a second throw at `:297` is unguarded. **Codex is worse:** `:257` and `:267-270` throw with no `stopRequested` consult at all. |
| `.runtimeError` carries `String(describing: error)` | It passes through `SecretRedactor.redactLocalDiagnostics` first (`AgentSupervisor.swift:2074-2079`). The user still sees `piFailed(exitCode: 15, …)`. |
| `submittedAt` cleared once, mis-indented | **Twice.** `:3994-3998` and `:3985-3989`, each with a dedented duplicate. |
| `rowSpacing = 12` used for everything | 12 separates **collection rows** (`AgentTranscriptLayout.swift:11/45`); inside one prose block rows use `AssistantProseView.blockSpacing = Space.m = 8` (`AssistantProseRenderer.swift:43/196`). Intra/inter-block already differ — the missing tier is **inter-turn**. |
| ten row views lack `TokenThemed` | **Twelve.** Add `ImageRenderer.swift:146/580` and `FileReferenceRenderer.swift:100`. There are **zero** conformers anywhere under `Canvas/AgentTranscript/`. |
| the link witness passes the project root | It diverges on **two** axes — `checkoutRoot: checkout` *and* `projectId:` (`FileOpenChecks.swift:833-843`). |
| the connector pixel witness sits at `:748` | The viewport is built at `FileOpenChecks.swift:1132-1136` as `CanvasViewport(x: 0, y: 0, zoom: 1)` and never re-set; the witness is `:982-1002`. |
| `isSubagentFrame` drops everything | It filters `stream_event` (`:92`), `assistant` (`:96`) and `user` (`:100`). **`result` (`:103`) is not filtered.** |
| §5e "probably fix before Slice 1" | **Decided:** promoted to Slice 0, ahead of everything. |

## Open questions, resolved

1. Split Slice 1 into invisible (1a+1b) and visible (1c–1h)? **Yes**, shipping
   separately.
2. Pull the `submittedAt` fix forward? **No** — the live-work row is built in 1g
   and explicitly labelled as behaving wrong until Slice 2 lands.
3. Clustering with folding, or separate? **Clustering first (1c.5), folding on
   top (1f.1)** — folding without clustering re-derives the grouping twice.
4. Inline diff only, or a "reveal in diff tile" affordance? **Inline only for
   now**; `AgentDiffPayload.canOpenReview` stays unset until someone asks for it.
5. Companion paused until the write-only key is fixed? **Yes** (ledger X.3).
6. Promote §5e and/or the claude-subagent slice? **§5e yes, to Slice 0.** The
   claude-subagent slice stays in 3d, flagged as the largest visible product per
   line of diff and the first thing to pull forward if Slice 1 runs long.

Also settled: the steering-protocol probe (§4d-pre) runs in the **foreground**,
before Slice 4 is designed.

---

Prior art that stays authoritative: `~/.claude/plans/we-had-a-codex-mighty-hinton.md`
(the renovation plan), `docs/38-tickets/91-agent-tile-ux/_DESIGN.md` (the visual
charter), `docs/38-tickets/99-transcript-subagents-renovation-handoff.md` (the
post-mortem), `docs/38-tickets/90-agent-ux/P5.6-compact.md`.

---

# Part 0 — What actually exists for subagents in the tiles

Recorded because the premise "the work was only on the companion" is not
accurate, and the real gap is a different one.

## Read this first: none of it is visible to the user

Everything in the table below is **code that exists, is wired, and is
unreachable in practice**. No subagent chip has ever appeared in Dylan's tile and
none can, because no harness emits the event that creates the block:

- `ClaudeAgentRunner.observeSpawnRequests` — empty body, comment: *"The handler is
  accepted for seam parity and **never fires**."* (`:316`)
- `CodexAgentRunner.observeSpawnRequests` — empty body, same comment (`:300`)
- pi's `continuum-spawn-agent.ts` is **not installed**
  (`~/.pi/agent/extensions/` lacks it), Array never passes `-e`
  (`PiAgentRunner.swift` has no `"-e"`), and the tool is in no role's `--tools`
  allowlist

So "the skeleton exists" and "the feature works" are different claims, and only
the first is true. Read the table as *what will not need rebuilding*, not as
*what shipped*.

## Built, on the desktop, and dormant

| piece | where |
|---|---|
| Semantic contract — `AgentBlockKind.agentReference`, `AgentReferencePayload` (child id, parent id, relationship, spawn name, timestamp, provider source item id, provider) | `AgentBlock.swift:65, 269-301, 324` |
| Runtime event `childAgentSpawned` | `AgentStatusEngine.swift:494` |
| Durable parentage — `parentAgentID`, `parentRelativeOrdinal`, `nextChildOrdinal` | `AgentRecord.swift:234` |
| Projection mints exactly one chip per child, deduped by `referencedAgentIDs` | `AgentTranscriptProjection.swift:40, 163-188` |
| **Inline chip in the parent transcript** — 38pt button, registered in the frozen production renderer registry | `Renderers/AgentReferenceRenderer.swift`, `AgentBlockRendererRegistry.swift:33, 66-67` |
| **Chip activation spawns the child's tile** and reveals it, via the *correct* zone-aware path (`installProjectTile`) | `ManagedAgentTileNSView.swift:1946-1948` → `ContinuumApp.swift:11189-11191` → `revealAgentFromInbox` → `TileSpawner.spawnManagedAgentForExistingAgent` → `TileSpawner.swift:1517` |
| **Canvas lineage connector** — bezier + arrowhead, refreshed on camera writes, cleared on `removeTile` | `AgentLineageOverlayView.swift`, `CanvasNSView.swift:1326-1342, 667, 1774-1776` |
| **Sidebar hierarchy — complete and matrix-gated.** `parentId`/`depth`, depth-first sort with child immediately after parent, `indentPerLevel = Space.xl`, `InboxDisclosureButton`, `ChildRollup` summaries, 8-child fan-out cap with `FanoutRemainder`, `descendantBlockers` so a live child holds its parent out of History | `AgentInboxRow`, `InboxSort.sortForInbox`, `AgentInboxView.swift:699-703, 2403-2409` |
| Spawn governance — `maxSpawnDepth 2`, `maxChildrenPerParent 4`, `maxFanOutBatch 4`; a refused spawn renders as a failed tool item in the parent | `AgentSupervisor.swift:2185, 2188, 2458, 2305-2330` |
| Pi spawn detection end to end — `spawn_agent` tool call → `SpawnRequest.parse` → real child process with its own session, worktree, stream | `PiEventTranslator.swift:107-111`, `AgentSupervisor.swift:2056-2058, 2239, 2280-2290` |
| `AgentCapabilities` (`transcript`, `observesStatus`, `canStop`, `providerObserved`, `locallyManaged`) — the right primitive for per-harness honesty | `AgentRecord.swift:156-197` |
| Per-agent transcript store, snapshot + journal + recovery | `Agents/AgentTranscriptStore.swift` |
| Checks — projection dedupe, record round-trip, inbox nesting, `--agent-supervisor-check`, `--agent-fanout-check`, `--managed-agent-model-spawn-check` (asserts reveal never mints an agent) | various |

So: chip → tile → connector → sidebar tree → durable parentage → caps → pi
detection. That is not a companion-only story.

## What is genuinely missing — and it is *not* mostly UI

1. **Supply is zero on all three harnesses right now.**
   - **pi** — `continuum-spawn-agent.ts` is not installed
     (`~/.pi/agent/extensions/` lacks it), Array never passes `-e`, and the tool
     is not in any role's `--tools` allowlist. The detection path is complete and
     unreachable.
   - **claude** — subagents really run, but `ClaudeEventTranslator.isSubagentFrame`
     **drops** every `parent_tool_use_id != nil` frame
     (`ClaudeEventTranslator.swift:118-121`, used at `:92, :96, :100`), and
     `ClaudeAgentRunner.observeSpawnRequests` is an empty stub (`:316`).
     `--forward-subagent-text` is never passed.
   - **codex** — `CodexAgentRunner.observeSpawnRequests` is an empty stub
     (`:300`). `collab_tool_call` *is* on the exec stream but `spawn` was not
     reachable in either probe (see 42, Part I §3). `AgentCommandCatalog.swift:367-368`
     advertises `/agent` and `/subagents` with nothing behind them.
2. **A child with no tile has no persisted transcript.** Persistence is driven
   from the tile's `onSemanticTranscriptUpdated`
   (`ManagedAgentTileNSView.swift:1917-1919`), so an unrevealed child writes
   nothing.
3. **The chip carries no live status.** By design the payload has none — status
   is meant to be resolved from `agentID` at render time so ticks never rewrite
   history. That resolution is not implemented.
4. **The lineage overlay is one ephemeral edge**, single-optional
   (`CanvasNSView.swift:82`), cleared by the next reveal — not a graph. It also
   has **no witness at all**. Its geometry, however, is **correct** — it converts
   via `overlay.convert(parent.bounds, from: parent)`. The pan-offset defect is
   `DocumentRelationshipOverlayView`'s, not this one; see §5a.
5. **`AgentCapabilities` is unused**, so the UI cannot yet be honest about a
   read-only claude child vs. an ownable pi child.
6. Live adjacent hazard: if a child's `projectId` differs from the active
   project, its tile is installed into the **active** project anyway with only a
   stderr warning (`ContinuumApp.swift:9456-9459`).

## What did go to the companion

The last session's bulk: `transcriptRead`/`agentStop` scopes, the message
vocabulary, the Curve25519/HKDF/ChaChaPoly envelope, `TranscriptProjectionSender`
/ `Receiver`, the iOS semantic renderer and child navigation — roughly 982 lines
that had **zero production callers on either platform** at handoff. `63c935a`
later wired the desktop sender and iOS receiver lifecycle, but iOS still ignores
encrypted envelopes and the only child data the phone gets is a parent
breadcrumb plus a Stop button.

**And it cannot work anyway**, because of the bug in 42 Part IV: production tiles
write transcripts under `sessionID = "managed-<tileId>"`
(`TileSpawner.swift:1477`) while the sole reader hardcodes `"thread-main"`
(`ContinuumApp.swift:8326-8330`). Every persisted transcript is write-only.

**Honest summary:** desktop got the skeleton and it is a good skeleton. The
companion got a transport with no cargo. Neither got supply, status, or a graph.

---

# Slice 1 — UI overhaul, including tool rows

Goal: the tile reads like a document, and tool work reads like work.

## 1a. Fixtures before pixels (precondition, not optional)

`agent.transcript.review` is a `.reviewSurface`, which means **every baseline
sweep skips it**. Converting it and adding per-phase `.staticCard` fixtures is
the first task, so the visual work is pixel-gated from the start. This is the
single control that prevents repeating the session that wrote 2,267 lines of
transcript UI blind.

Fixtures needed: preparing, provider wait, thinking, tool work, writing, input
wait, failure, stop, completion; tool rows in each status; a tool cluster; a
folded turn; an expanded turn; an edit with a diff; a table; a 10,000-entry
performance fixture. Both `.aqua` and `.darkAqua`, at 320/480/640/900pt per
`_DESIGN.md` §12.

## 1b. Data capture — the part of "tool rows" that isn't UI

The edit rows cannot show a diff because **no diff exists in the data** (42 Part
V). This must land inside slice 1 or the redesigned rows have nothing to draw.

- Widen `AgentRuntimeObservation.toolActivity` / `AgentObservedActivity` to carry
  the bounded fields `AgentToolDetailStore` already accepts: sanitized
  arguments, output text, exit code, `endedAt`.
- Populate them in all three translators. Today production `recordEnd` passes
  status only, so `output`, `exitCode` and therefore `duration` are always nil.
- Capture edit before/after: claude's `old_string`/`new_string`, codex's
  `changes[]`, pi's `apply_patch` args.
- **Never widen `AgentRuntimeEvent`** — that is the I5 sync boundary. The
  host-local, non-`Codable`, TTL-scoped `AgentToolDetailStore` is the sanctioned
  channel and this is pre-authorized by `plan-managed-agent-tile-polish.md` §12.3.
- Keep the fail-closed redactor and every `AgentToolDetailLimits` cap.
- Fix codex's literal tool names (`"Shell"`, `"Edit"`) and surface the item types
  its `default:` branch currently swallows (`mcp_tool_call`, `web_search`,
  `todo_list`, `collab_tool_call`) — at minimum behind a debug log so the next
  schema change is visible rather than invisible. The translator is pinned
  against codex 0.145.0; the installed CLI is 0.148.0.

## 1c. The tool row

Replace the card with a line:

```
[glyph 20] Edit  ·  AgentTranscriptListView.swift            ⌄   ✓ 8.2s
```

- One 32pt row, reserved trailing status column so text never reflows when
  status lands, reserved leading glyph column.
- **Per-tool iconography** resolved in the *normalizer*, not the view (terminal /
  square.and.pencil / eye / globe / wrench / bubble.left), mapped to SF Symbols
  in the renderer. One `wrench.and.screwdriver` for everything is the single
  biggest cheap win.
- Status as a glyph, and **completed uses foreground colour, not green** — only
  failures should pull the eye.
- **Stop the summary restating the title.** Dedup against the title, not just the
  status label.
- **Consecutive tool calls cluster** into one group with a hairline gutter
  instead of N stacked rounded cards.
- **Show detail while running.** `presentedToolBlock` currently returns early for
  `.pending`/`.inProgress` (`AgentTranscriptListView.swift:1356-1358`), so an
  active tool is name+status only — exactly when you are watching it.
- **Distrust provider status**: sniff `exited with exit code N`, `ENOENT`, "no
  such file". Providers report `completed` on failing commands.
- Expanded body renders `AgentToolDetailExpandedPresentation` as *fields* — an
  argument table, an output pane, exit code and duration — not 12 newline-joined
  lines. `CommandOutputView` already exists for the output pane and is currently
  dead code.
- Surface the store's honest truncation flags (`truncatedByBytes`,
  `truncatedByLines`, `redacted`). Never silently truncate.

## 1d. Inline diffs

`GitDiffParser.parse` is a pure Core unified-diff parser and
`DiffReviewTileNSView.render(_:theme:)` is already `static` and pure with theme
as a parameter. Reuse both for a compact inline diff inside an expanded edit row,
bounded with a visible "+N more lines".

**Do not** copy `AgentDiffSummaryView.rebuildFileLabels()`, which destroys and
recreates up to 8 `NSTextField`s on every `apply` — the exact pattern that froze
the app in 0.4.16. Bounded view count per row, all measurement through
`AgentBlockMeasurementCache`, and any per-row indent must enter
`AgentBlockMeasureKey` or a nested row will reuse a top-level row's cached height
at the wrong width.

## 1e. Document rhythm

- **Three separations instead of one.** `rowSpacing = 12` is currently used for
  paragraph→paragraph, list-item→list-item and turn→turn alike. Introduce
  intra-block (~4), inter-block (~8), inter-turn (~20 + a turn marker).
- **Hanging indents.** Move `"• "` and `"› "` out of the text run into a gutter
  so wrapped lines align and a bullet stops looking like a blockquote.
- **A heading ladder that ladders.** All six levels currently render `.title` 15
  semibold; `#` and `######` are identical.
- **Fewer fills.** Nine row kinds paint `AgentSurfaceRole.artifact` at radius 8
  with no border. Only code, diff, plan and approval should keep a fill.
- **Error and Notice must stop being pixel-identical** — a compaction notice
  currently looks like a failure. This matters for slice 3.
- **Align the left edge.** Artifact fills start at 12pt, prose text at 24pt, so
  card edges and prose never share an edge.
- **Tables get a renderer.** `Table` currently maps to `.fencedCode` and dumps
  raw pipes as monospace; the parser's own comment calls it "the common case".
- **Thematic breaks** render as 24pt of nothing today.
- Consider actually using `Opacity.receded` (0.88), which exists and no renderer
  applies, for settled routine work.

## 1f. Turn structure

- A settled turn folds to `Worked for 1m 12s · 8 tools · 2 agents`, preserving
  the terminal assistant message, expanding to authored commentary, errors,
  requests, diffs and child milestones. Never fold a turn with a streaming
  message; auto-expand a turn interrupted in-session.
- While a turn runs, show the last tool row and hide the rest behind
  `+N previous tool calls`.
- Fixed heights for chrome rows (fold, toggle, tool row) so scrolling back
  through unmeasured content doesn't jump.

## 1g. The live-work row — designed here, wired in slice 2

One row spanning preparing → provider wait → thinking → tool work → writing →
input wait → failure → stop → completion, with elapsed time and a working Stop.

**Flagged dependency:** its *states* come from the phase machine that slice 2
fixes. Build the row and its fixtures here; expect it to look right and behave
wrong until slice 2 lands. Say so out loud rather than shipping it as done.

## 1h. Hazard 8 cleanup, unavoidable while in here

Every transcript row view paints `layer.backgroundColor` and **none declares
`TokenThemed`** — `ToolCallView`, `CodeBlockView`, `AgentErrorNoticeView`,
`AgentPlanView`, `AgentDiffSummaryView`, `AgentRequestView`, `CommandOutputView`,
`UserPromptView`, `AgentReferenceChipView`, `AgentUnknownBlockView`. They are
invisible to the appearance census. Each needs conformance, a
`tokenAdoptedOwners` entry with a ticket comment, paint in both an
appearance-sweep and an adopted surface in both appearances, and `nil` at rest —
never `.clear`. `AgentLineageOverlayView` uses raw `NSColor.controlAccentColor`.

Also `ToolCallView.layout()` assigns all five frames unconditionally every pass.

---

# Slice 2 — Dead air / feel

Full evidence in 42 Part II. Ordered by felt impact, each with a
count/ordering witness rather than a stopwatch.

1. **Write the missing witness first, RED.** Drive the *real* sequence
   `[.sessionStateChanged(.ready), .sessionStateChanged(.running), .turnStarted]`
   through `updateTurnFacts` and assert `turnSnapshot(for:)` stays `.starting`
   throughout. Today's `AgentFirstPaintChecks` builds synthetic snapshots by
   hand, which is why the regression is invisible.
2. **Stop clearing `submittedAt` on `.ready` before a turn exists**
   (`AgentSupervisor.swift:3994-3998`, including the mis-indented duplicate).
   This is the "glyph appears, disappears, loader returns" bug, and it is
   per-harness: one gap on codex, two on pi, none visible on claude.
3. **Give `.running`-without-turn a real phase.**
   `AgentCompactStatusPhaseAdapter.swift:232-236` returns `.unknown`, so even
   with (2) fixed the words go blank.
4. **Seed compact-status facts on `send`**, not only `attach`
   (`ManagedAgentTileNSView.swift:1128`), so the footer and elapsed tick run
   during the spawn window.
5. **Get `persist(record)` off the main actor** (`AgentSupervisor.swift:2043`).
   It takes a cross-process `flock(LOCK_EX)` plus two `fsync`s before the runner
   is dispatched — this is the "hangs longer with no loader at all" case, and it
   recurs on every persist-worthy lifecycle event.
6. **Queue during readiness `.checking`, never refuse.** The first message after
   launch is currently *dropped*, not delayed.
7. **Make the indicator sticky across tool boundaries.** Every text→tool→text
   transition closes the streaming run, flips `latestStreamIsVisible`, toggles
   the gyro and triggers a full datasource apply + layout.
8. **Consume claude's `system/status status:"requesting"`** as a real
   provider-accepted phase — a genuine pre-token ack Array currently discards.
9. Cache `RoleRegistry` (main-actor directory walk + frontmatter parse per pi
   turn) and get `refreshBranchContext`'s synchronous `git rev-parse` off the
   main thread at turn end.

---

# Slice 3 — Commands, and what commands actually do

## 3a. A real command engine

Today the catalog and popover are good and the engine does not exist:
`AgentSupervisor.accept` (`:3322-3332`) serializes every non-`.cli` command to
`"/name args"` and sends it as an ordinary user turn. Nothing switches on
`surface == .array`.

Three tiers, where the tier decides who authors the reply:

| tier | examples | mechanism | transcript treatment |
|---|---|---|---|
| **Array-owned** | `/clear`, `/new`, `/fork`, `/status`, `/diff`, `/help` | Array performs it; never reaches the CLI as text | a system row authored by Array |
| **Harness-delegated** | `/compact`, `/context`, `/model` | forwarded, reply attributed to the **harness**, reconciled against `system/status` | a harness-authored control row, visually distinct from user and assistant |
| **Skill / template** | `/deep-research`, `/code-review`, pi prompt templates | genuinely a user turn | a normal user turn |

- **Discover, don't hardcode.** Claude publishes `slash_commands` (47 here,
  including project-local), `skills`, and `agents` on `system/init`. Keep the
  hardcoded 40/64/13 baselines only as the pre-first-turn fallback.
- **Use `<local-command-stdout>…</local-command-stdout>`** plus
  `num_turns: 0` / zero usage as the discriminator so CLI control output stops
  rendering as an assistant turn.
- Fix the two cheap bugs now: the popover path skips the optimistic echo while
  the typed path doesn't (one command, two appearances), and bare Enter is
  swallowed because `focusedID` starts nil.
- A command Array cannot perform is **disabled with a reason**, never silently
  degraded into prose.

## 3b. Compaction as an observed event

`ClaudeEventTranslator.swift:71-72` gates `system` to `subtype == "init"`. Open
it and consume `compact_boundary`, whose metadata gives `trigger`, `pre_tokens`,
`post_tokens`, `cumulative_dropped_tokens`, `duration_ms` and the preserved
message uuids.

- Insert a **first-class compaction entry** — a new block kind, not the `Notice`
  variant that is pixel-identical to an error (fixed in slice 1e).
- **Set occupancy from `post_tokens`.** Today the ring holds the pre-compaction
  percentage until the next turn completes, so it is confidently wrong for the
  whole interval. Plan 19 listed proving exactly this; the witness was never
  written. Also unblocks `automaticCompaction`, which exists on
  `TokenUsageSnapshot`, is rendered by
  `AgentCompactStatusPresentation.swift:564-565`, and is hardcoded `nil` by all
  three translators.
- **Array's transcript stays complete.** The handoff is content, not noise —
  render it collapsed and attributed to the harness, since it is the CLI
  re-seeding its own context rather than the agent addressing you.
- Distinguish `manual` from automatic in the copy.
- Stop `PiSessionTranscriptReader` discarding `compaction` lines on rehydration,
  which currently loses the boundary *and* the pre-compaction history on
  relaunch.

## 3c. `/clear` as a session operation

Every piece of state that goes stale is tabulated in 42 Part IV. The ones that
will bite:

- claude/pi session ids are pure functions of the agent UUID
  (`AgentSupervisor.swift:1029, 1039`), so there is no id to rotate — a real
  `/clear` needs a changed derivation or `--fork-session`.
- `record.lastContextWindow` persists the pre-clear reading and re-seeds the
  meter as `.stale`-but-numeric after relaunch.
- **If `/clear` is the first prompt in a fresh tile, the tile is permanently
  named after the slash command** — `displayNameSource` leaves `.sentinel` and
  never re-arms.
- Subagent chips keep resolving after the parent's CLI has forgotten the
  children exist.

## 3d. Agents / delegation

Sequenced after commands because delegation is best expressed *as* a command,
and because the honest capability differs per harness. `AgentCapabilities`
already exists for this and is unused.

| harness | honest capability | work to get there |
|---|---|---|
| **pi** | a real child process Array owns — full transcript, Stop, resume | install/ship `continuum-spawn-agent.ts`, pass `-e`, allowlist the tool. Detection is already complete |
| **claude** | read-only reconstruction; no child session id, nothing to resume or stop | pass `--forward-subagent-text`, stop dropping `parent_tool_use_id` frames, key the child on the `Task` tool_use id |
| **codex** | nothing reachable in `exec` today | re-probe when `multi_agent_v2` flips; meanwhile surface `collab_tool_call` rather than swallowing it |

Rules:
- A child with `canStop: false` shows no Stop. A `.readOnly` child says so rather
  than offering a composer. Uniform presentation with inert controls is the
  companion's failure mode.
- **Render evidence, not claims.** In both codex probes the model reported file
  contents it never read, having spawned nobody, and was accidentally right.
- Resolve chip status live from `agentID`; keep the payload status-free so ticks
  never rewrite history.
- Persist a child's transcript without requiring a tile.
- The lineage overlay's geometry is fine; what it lacks is any witness at all and
  any trigger other than an inbox reveal whose parent still has a live tile. Give
  it both before promoting it to a graph. (The pan-offset bug is the *document*
  overlay's — §5a.)

---

# Slice 4 — Steering and interruption

Added 2026-08-22 after Dylan reported two coupled complaints: he cannot send a
follow-up while a turn runs (only a big red Stop), and stopping pi mid-response
reports a failure.

**Both have one root cause: Array runs every harness as a one-shot process.** A
fresh `claude -p … <prompt-as-argv>` / `pi -p --mode json …` /
`codex exec --json …` per turn, with codex's stdin explicitly wired to
`/dev/null`. A one-shot process has nowhere to receive a second message, and no
protocol through which to be told to stop — so Stop can only be a signal, and a
signalled process is indistinguishable from a crashed one at the process
boundary.

## 4a. The pi stop-shows-failure bug

Confirmed at HEAD. Three lines:

```swift
// PiAgentRunner.swift:290-292
public func stop() {
    queue.sync { process?.terminate() }      // SIGTERM, direct child only
}
// PiAgentRunner.swift:280-282
if process.terminationStatus != 0 {
    throw RunError.piFailed(exitCode: process.terminationStatus, stderr: errText)
}
```

SIGTERM ⇒ `terminationStatus == 15` ⇒ throw ⇒ `sendPrepared` catches it
(`AgentSupervisor.swift:2073-2079`) and calls
`deliver(.runtimeError(threadId:message:))` with
`String(describing: error)`. The literal string
**`piFailed(exitCode: 15, stderr: …)`** is rendered as a red error row.

**Pi has no `stopRequested` flag at all.** Claude and codex have one
(`ClaudeAgentRunner.swift:263`, `CodexAgentRunner.swift:237`) but it only
suppresses the *retry / self-heal spawn* — the throw at
`ClaudeAgentRunner.swift:293` happens **before** `stopRequested` is consulted at
`:294`. A stopped claude turn escapes a failure row only when its stderr happens
to match `retryIsWarranted`. Those flags are accidental mitigations, not stop
handling.

Downstream, `.runtimeError` is a hard failure everywhere: `facts.didFail = true`,
`record.failedAt`, a terminal event with `outcome: .runtimeError`, a
`kind: .error` block in the document, `compactStatusTurn = .completed(.failed)`,
and an inbox row with `exclamationmark.triangle.fill`.

Two further consequences:

- **You see "Stopped", then a failure.** `stop()` delivers
  `.sessionStateChanged(.stopped)` synchronously
  (`AgentSupervisor.swift:2156-2170`); milliseconds later the background thread's
  `.runtimeError` flips the same agent to `.failed`.
- **Pressing Stop pushes "agent failed" to the phone.**
  `PushFiringRuleTable.classify` (`APNSPushService.swift:281-284`) has a correct
  branch — *"Stopping a run is not success and is not a failure notification"* —
  and it is **unreachable**. `TurnOutcome.interrupted`/`.cancelled` exist and
  every consumer handles them (`AgentLocationProjector.swift:105-106`,
  `AgentInbox96CellView.swift:533/619`, `ManagedTranscriptCardProjection.swift:176`);
  **no producer emits them**, because a killed process never emits `turn_end`.
- **Only the direct child is signalled.** No `setpgid` in any runner, no process
  group, no grace period, no SIGKILL escalation — so tool subprocesses pi spawned
  survive. The app already does this correctly elsewhere
  (`AgentSupervisor.swift:658-690`: SIGTERM to `-pid`, `processGroupGrace = 0.15`,
  then SIGKILL, then `waitpid`); it is simply not on the Stop path.

### Witness gap

Every stop check drives a `ScriptedAgentRunner` whose `stop()` merely signals a
semaphore and **never throws**, so no check reproduces the real
`terminationStatus != 0 → throw → .runtimeError` chain. **Nothing anywhere
asserts that a deliberate stop is not a failure** — no assertion of
`state != .failed`, `didFail == false`, absence of an error block, or
`latestTerminalEvent.outcome == .interrupted`. That is what let this ship green.

## 4b. There is no queue, and Enter is a silent no-op

- `canSend` is `!occupied && state.acceptsNewTurn` where
  `occupied = runners[id] != nil` (`AgentSupervisor.swift:3250-3266`). So send is
  disabled for the **entire runner lifetime**, including the drain window after
  `.turnCompleted` and before `clearRunner`.
- `AgentTurnCapabilities.sendStop` hardcodes `canSteer: false, canQueue: false`
  (`AgentComposerIntent.swift:207-209`). `AgentComposerPresentation.resolve`
  already has the steer/queue chips implemented behind those flags
  (`AgentComposerPresentation.swift:72-76`) — the UI is waiting for a producer.
- `AgentTileOperationalState.queued` exists and is **unreachable in production**;
  every construction site is a check or fixture. Consumers already render it
  ("Queued").
- `sendPrepared` refuses a second prompt with only a stderr `warn`
  (`AgentSupervisor.swift:1984-1991`), citing a deferred ticket "P5.7-steer-follow-up".
- **The composer text stays editable while working** (`ComposerTextView.swift:62`,
  never flipped; `composeIsBusy` at `ManagedAgentTileNSView.swift:2082` is
  declared and never read) and the draft is persisted. So you *can* type ahead —
  pressing Enter just returns `nil` from `workingDraftIntent`
  (`AgentComposerIntent.swift:238-245`) and does **nothing, with no feedback**.
  Worse, Enter *with an attachment* forces `.sendPrompt`, which reaches the
  supervisor, is refused `.turnNotReady`, and rolls back the optimistic bubble.

`AgentComposerDraftStore` already holds and restores one in-flight submission
with a lease/journal/recovery protocol — it is the natural home for a queued
follow-up, but nothing would replay it as a turn.

## 4c. Measured: pi cannot be stopped cleanly by any signal

Run on this machine, 2026-08-22, pi 0.84.1. `pi -p --mode json --session-id X`
with a long prompt, signalled after 5s:

| signal | exit code | stdout captured | session file written |
|---|---|---|---|
| `SIGINT` | **130** | 0 bytes | **none** |
| `SIGTERM` | **143** | 0 bytes | **none** |

Three conclusions, all consequential:

1. **Changing the signal does not fix the bug.** Neither SIGINT nor SIGTERM
   yields exit 0, so Array's `terminationStatus != 0 → throw` fires either way.
   The `stopRequested` flag in §4d item 1 is therefore **mandatory, not
   optional** — there is no signal that makes the existing code behave.
2. **A signalled pi loses the entire turn.** The session directory
   `~/.pi/agent/sessions/--private-tmp-pi-sig-probe--/` was **created and left
   empty** — no `.jsonl` at all. A subsequent run with the same `--session-id`
   printed `Warning: No project session found with id 'probe-term-001'; creating
   a new session with that id.` So stopping a pi turn does not merely produce a
   spurious error row — **it silently discards the conversation's continuity**,
   and the next turn starts from nothing while Array's own transcript still shows
   the prior history. This is a worse bug than the one reported, and it is
   invisible today.
3. Nothing is emitted on stdout before the kill in that window, so there is no
   provider terminal event to reinterpret as "stopped" — the host must author
   the interrupted outcome itself.

### Measured pi event ordering (the dead-air gap, quantified)

From a clean `pi -p --mode json` run of a trivial prompt (`Reply with exactly:
OK`), time-to-first-byte **0.62s**, total **11.7s**, with this line order:

```
{"type":"session", …}        ← 0.62s  → .sessionStateChanged(.ready)   ← indicator HIDDEN
{"type":"agent_start"}                → .sessionStateChanged(.running) ← still hidden
{"type":"turn_start"}        ← ~1.5s  → .turnStarted                   ← indicator returns
{"type":"message_start", role:"user"} …
{"type":"message_update", …text_delta…}
{"type":"turn_end"} / {"type":"agent_end"}
```

So on pi the indicator is suppressed from ~0.6s to ~1.5s on a *trivial* prompt —
and that window is bounded by model latency, not by pi's startup, so it widens
with real work. This is a directly measured instance of the §2 bug rather than an
inferred one, and it confirms the three-separate-stdout-lines analysis.

Incidental: pi's user message is echoed back on the stream
(`message_start` with `role:"user"`), unlike claude. Worth knowing for the
optimistic-echo reconciliation in Slice 2.

## 4d-pre. Provider-side steering mechanisms

**RESOLVED 2026-08-22, foreground probes on this machine.** claude 2.1.240,
pi 0.84.1, codex-cli 0.148.0. Raw capture in the session scratchpad
(`p1.jsonl`, `p1b.jsonl`, `p2.jsonl`); the schema dump came from
`codex app-server generate-json-schema --out`.

### The headline: all three harnesses have real steering. Array uses the one mode of each that does not.

| harness | Array runs | steering exists? | where |
|---|---|---|---|
| **claude** | `-p --output-format stream-json`, prompt as **argv** | interrupt yes, mid-turn steer **no** | `control_request` on `--input-format stream-json` stdin |
| **pi** | `-p --mode json` | **yes — an explicit `steer` distinct from `follow_up`** | `--mode rpc` |
| **codex** | `exec --json`, stdin `/dev/null` | **yes — `turn/steer` and `turn/interrupt`** | `app-server` |

### claude — a queue, plus a real acknowledged interrupt

**A second stdin user message is a QUEUE, not steering.** Measured twice.
The decisive run: prompt A was a 2,000-word essay that streamed for **76
seconds**; message B was written to stdin at **t=12.6s**, 64 seconds before the
turn ended. The model wrote all **12,997 characters** unaffected. B was replayed
at t=81.2s — *after* turn 1's `result` — and ran as its own turn.

```
 0.005  IN   A: essay
 4.635  OUT  user/          (A replayed)
12.641  IN   B: "STOP. Abandon the essay… reply PINEAPPLE"
78.696  OUT  assistant/     len=12997   ← A completed in full
78.716  OUT  result/success num_turns=1 dur_ms=76312
78.724  OUT  system/init                ← the session re-inits PER TURN
81.181  OUT  user/          (B replayed)
82.235  OUT  assistant/     'PINEAPPLE'
82.256  OUT  result/success num_turns=1
```

**But `control_request` interrupt is real, acknowledged, and immediate.**

```
31.059  IN   B: queued follow-up ("what is 2+2?")
32.569  IN   C: {"type":"control_request","request_id":"interrupt-…",
                 "request":{"subtype":"interrupt"}}
32.570  OUT  control_response {"subtype":"success","response":{"still_queued":[]}}   ← 1 ms
32.575  OUT  assistant/  len=5378  tail='…destroyed the French'   ← truncated mid-sentence
32.591  OUT  user/  '[Request interrupted by user]'               ← the CLI authors this
32.593  OUT  result/error_during_execution num_turns=2 is_error=TRUE
34.663  OUT  user/  (B replayed)  →  35.549 assistant '4'          ← the queue DRAINS
```

Five consequences, all load-bearing:

1. **The interrupt aborts the turn mid-stream** — 5,378 chars against 12,997 for
   the same prompt uninterrupted.
2. **An acknowledged, user-requested interrupt still reports
   `is_error: true`** with subtype `error_during_execution`. So
   `ClaudeEventTranslator.swift:255` (`isError ? .failed : .completed`) would map
   a clean protocol interrupt to `.failed`. **The `stopRequested` flag in §4d
   item 1 is mandatory on the CLEAN path too, not only for signals.** This
   generalises the fix well beyond "Stop sends SIGTERM".
3. **The CLI authors `[Request interrupted by user]` as a `user` message.** That
   is the transcript row Array should render — harness-authored, not an error.
4. **`still_queued: []`** and the queued message *ran afterwards*. So an
   interrupt cancels the **turn**, not the **queue** —
   `interrupt_cancel_queued_v1` is a separate operation, which is exactly the
   two-verb Stop in §4d item 4.
5. **`system/init` is emitted PER TURN**, not once per session. Good news for
   §3a's "discover, don't hardcode": the command/skill/agent manifest re-arrives
   every turn.

Binary corroboration: `control_request` appears 104× and `control_response` 83×
in the CLI, and the response type is documented in-binary as *"Result of an
interrupt operation. Advertised by the `interrupt_receipt_v1` capability on
`system/init`; older CLIs send an empty success response with no `still_queued`
field."*

### pi — the most capable harness of the three, and Array uses none of it

`--mode rpc` speaks `{"type":…, "command":…, "id":…}` (not JSON-RPC; an
unrecognised call returns `{"success":false,"error":"Unknown command: …"}`).
Its command vocabulary, read from
`dist/modes/rpc/rpc-mode.js` and `dist/core/agent-session.d.ts`:

```
abort  abort_bash  abort_retry  bash  clone  compact  cycle_model
cycle_thinking_level  export_html  follow_up  fork  get_available_models
get_available_thinking_levels  get_commands  get_entries  get_fork_messages
get_last_assistant_text  get_messages  get_session_stats  get_state  get_tree
new_session  prompt  set_auto_compaction  set_auto_retry  set_follow_up_mode
set_model  set_session_name  set_steering_mode  set_thinking_level  steer
switch_session
```

The two that settle the product question, quoted from pi's own type
declarations:

- **`steer(text, images?)`** — *"Queue a steering message while the agent is
  running. Delivered after the current assistant turn finishes executing its
  tool calls, **before the next LLM call**."* That is **genuine steering**: the
  model sees it inside the same run.
- **`followUp(text, images?)`** — *"Queue a follow-up message to be processed
  after the agent finishes. Delivered only when the agent has no more tool calls
  or steering messages."* That is **a queue**.
- **`abort()`** — *"Abort current operation and wait for agent to become idle."*
  A clean, awaited abort: **no signal, no non-zero exit, and no lost session
  file** — which is the direct answer to §4c's finding that a signalled pi writes
  no session file at all.

Both queues are inspectable (`getSteeringMessages()`, `getFollowUpMessages()`)
and both have an `"all" | "one-at-a-time"` mode. `steeringMode` and
`followUpMode` are reported by `get_state`.

**This inverts an assumption running through 42 and 43**, which treated claude as
the steering-capable harness and pi's rpc mode as unknown. It is the other way
round. `steer` / `follow_up` / `abort` map **one-to-one** onto Array's
already-built-and-unreachable `canSteer` / `canQueue` /
`AgentTileOperationalState.queued` / `TurnOutcome.interrupted`.

Also directly relevant to other slices: `compact` + `set_auto_compaction`
(§3b), `fork` / `clone` / `new_session` / `switch_session` (§3c `/clear` — this
is the missing "changed derivation or `--fork-session`"), `get_commands` (§3a
discovery), and `get_session_stats` (the context meter).

### codex — `turn/steer` and `turn/interrupt` exist in `app-server`

`codex app-server generate-json-schema --out <dir>` emits the full protocol
without running anything. `ClientRequest` declares, among 268 constants:

```
turn/start   turn/steer   turn/interrupt
thread/start  thread/resume  thread/fork  thread/rollback  thread/compact/start
thread/read   thread/list    thread/inject_items  thread/goal/{get,set,clear}
```

- **`TurnSteerParams`** — `{ threadId, expectedTurnId, input[], clientUserMessageId? }`,
  where `expectedTurnId` is documented as a *"Required active turn id
  precondition. The request fails when it does not match the currently active
  turn."* Mid-turn steering with optimistic concurrency.
- **`TurnInterruptParams`** — `{ threadId, turnId }`.
- **`ThreadCompactStartParams`** — `{ threadId }`.
- **`ThreadForkParams`** — fork by `threadId` or by path.

**And on subagents:** `ThreadSourceKind` enumerates
`cli | vscode | exec | appServer | subAgent | subAgentReview | subAgentCompact |
subAgentThreadSpawn | subAgentOther | unknown`. So in app-server a subagent's
work is a **first-class thread with its own id**, enumerable via `thread/list`
and readable via `thread/read` — the renovation plan's "outcome 1", reached
through app-server rather than `exec`. **Caveat, stated honestly: this is read
from the declared schema. No app-server session was run and no subagent thread
was observed.** Confirm before designing on it. `codex features list` still shows
`multi_agent_v2` stable/false.

### What this means for the slice

The question 43 posed — *"real steering or merely queued? they justify different
UI"* — has a per-harness answer, and `AgentCapabilities` is exactly the
primitive for it:

| harness | interrupt | mid-turn steer | queue | cost to Array |
|---|---|---|---|---|
| claude | yes, acknowledged, ~1 ms | **no** | yes, drains after interrupt | switch the prompt from argv to `--input-format stream-json` |
| pi | yes, clean `abort()` | **yes** (`steer`) | yes (`follow_up`) | switch `--mode json` → `--mode rpc`: a new translator |
| codex | yes (`turn/interrupt`) | **yes** (`turn/steer`) | via `thread/inject_items` | switch `exec` → `app-server`: a new transport |

So the UI should offer **Steer** where the harness can steer and **Queue**
where it cannot, driven by capabilities — never uniform controls with silently
inert behaviour. And Stop becomes two verbs wherever the harness distinguishes
them, which all three now demonstrably do.

**Sequencing consequence:** moving a harness off its one-shot mode is a
translator/transport rewrite, not a flag. Keep §4d items 1 and 2 (the
`stopRequested` flag and the process-group kill) as the near-term fix for the
mode Array ships today — item 1 is now *more* necessary, because claude reports
even a clean interrupt as `is_error: true`. Treat the mode migrations as their
own slice, cheapest first: claude (a flag plus stdin framing), then pi (rpc
translator, biggest capability payoff), then codex (app-server transport).

## 4d. Proposed shape

Independent of the protocol answer, two changes are unambiguous wins:

1. **A stop must not be a failure.** Give pi a `stopRequested` flag; check it
   **before** the non-zero-exit throw in all three runners; emit
   `turnCompleted(outcome: .interrupted)` instead of `.runtimeError`. This
   activates code paths that already exist and are already handled everywhere —
   including the unreachable "don't push a failure notification" branch. Witness:
   drive a runner that actually throws on stop and assert the turn is not
   `.failed` and no error block is appended.
2. **Signal the process group with escalation**, reusing the existing
   `processGroupGrace` helper, so pi's tool subprocesses die with it. Prefer
   SIGINT if the probe shows the CLIs finalize their session file on it.

Then, once the protocol is known:

3. **Type-ahead becomes a first-class queued message** with a visible pending
   state — the same feature as steering, differing only in whether the harness
   accepts it mid-turn. Flip `canQueue`, produce `.queued`, replay from the draft
   store. The presentation layer is already built.
4. **Stop splits into two verbs** — *interrupt the turn* vs *cancel what I
   queued* — which is what `interrupt_cancel_queued_v1` implies claude already
   distinguishes.
5. Per-harness honesty again: if pi's rpc mode has no interrupt, its Stop stays a
   (correct, group-wide, non-failing) signal and the UI says so rather than
   implying parity.

---

# Slice 5 — Note / file tile linkage to the transcript

**PENDING** — four probes running on: transcript link detection and activation
(why 2 of 3 links opened and one silently did nothing), the visual-linkage
overlays and whether any is production-reachable, zone/scoping interaction with
document-tile spawning, and the note/document tile identity and link model.

Known starting points: `ecf3bf3` "Fix workspace switching and linked document
focus" landed in 0.5.10 and is the prime suspect for the "recent scoping
changes" Dylan sensed; `edb68e8` covered document links across the schema v6
migration; `.plans/15-file-opening-markdown-preview.md` is the original spec; and hazard 9's
two-model split is a candidate source of a silent no-op.

**Already established (see Part 5a below): the missing visual linkage is a pan-offset
bug in `DocumentRelationshipOverlayView`, not a scoping regression, and `ecf3bf3`
is exonerated.**

## 5a. Why you see no document connectors

`CanvasNSView.updateDocumentRelationshipOverlay()` assigns
`documentRelationshipOverlay.frame = worldPlane.bounds`
(`CanvasNSView.swift:1701-1702`, and at init `:1171`) and then hands the overlay
segments built from raw **world** frames (`source.frame`, `target.frame`,
`:1720-1721`).

`CanvasWorldPlaneView` carries the camera in its own *bounds*:
`bounds.origin` **is** the pan and `bounds.size` is `viewportSize / zoom`
(`CanvasWorldPlaneView.swift:100-121`). A subview's frame is expressed in the
superview's bounds space, so `frame = worldPlane.bounds` makes the overlay
correctly *cover* the visible world rect — but the overlay's own `bounds` stays
`(0, 0, size)`, and **no `setBoundsOrigin` is ever applied to it** (verified: the
call appears nowhere in `CanvasNSView.swift`).

Consequence: a world point *q* drawn at local *q* lands at world *q + pan*.

- At viewport `(0, 0)` the connectors are correct.
- Panned, every connector is displaced by exactly the pan vector.
- Panned by more than one viewport, the whole route falls outside the overlay's
  own bounds, drawing is clipped, and **nothing renders at all**.

On an infinite canvas the camera is essentially never at the origin, so the
practical result is: no connectors, ever. Compounding it cosmetically, the stroke
is `lineWidth = 1` in *world* units at alpha **0.18** unemphasized
(`DocumentRelationshipOverlayView.swift:58-60`) — at zoom 0.35 that is ~0.35
device points at 18% opacity, i.e. invisible even where correctly placed.

**Two claims recorded earlier in this program were wrong and are retracted:**
the overlay *does* override `isFlipped` (`DocumentRelationshipOverlayView.swift:52`,
matching the flipped plane, so there is no vertical mirroring), and its Bézier
does *not* draw backwards when the document sits left of the agent — `route(for:)`
computes both `rightGap` and `leftGap` and flips the facing edges and handle sign
(`:76-90`), which is explicitly asserted at `FileOpenChecks.swift:608-613`.
`Segment` genuinely has no kind/direction field, but that is harmless while only
one relationship kind exists.

`AgentLineageOverlayView` geometry is **correct** — it uses
`overlay.convert(parent.bounds, from: parent)`
(`CanvasNSView.swift:1616-1617`), which accounts for the frame origin. The pan
bug is specific to the document overlay's raw world-frame segments.

### Why the witness missed it

Coverage is better than "a segment count" but blind in exactly the wrong axis:

- `checkDocumentRelationshipGeometry()` (`FileOpenChecks.swift:585-635`) asserts
  real geometry — facing edges, handles inside the gap, vertical case, overlap
  escape, non-finite rejection — but only against the **pure static
  `route(for:)` function**. It never touches a view, a frame, or a camera.
- There is even a **pixel** witness (`:983-1002`) requiring accent-ward pixels
  inside the route's x-corridor in both appearances. But its harness canvas sits
  at viewport `(0, 0, zoom 1)` (`:748`) — the one camera at which the bug is
  invisible — and its corridor compares world route x-values against
  canvas-space pixels, which is only valid at pan 0 / zoom 1.
- `checkDocumentRelationshipStabilityAndCost()`'s only camera call is
  `setViewport(largeCanvas.viewport)` (`:756`), an identity re-apply of the same
  zero viewport.

So the fix is a two-part change plus one witness: give the overlay a bounds
origin (or convert segments into overlay space), scale the stroke by zoom, and
**re-run the existing pixel witness at a non-zero pan and a non-unit zoom.**

### Why lineage is also invisible

`showContextualAgentLineage` fires from exactly one production trigger:
`revealAgentFromInbox` (`ContinuumApp.swift:9042-9048`), and only when the child's
parent agent *also* currently has a live tile. There is no lineage on spawn, on
selection, or persistently, it is a single optional edge cleared by the next
reveal, and it has **zero check coverage**.

### `ecf3bf3` is exonerated

It touched `ContinuumApp.swift`, `WorkspaceRuntime.swift` and `CanvasNSView.swift`
but changed **nothing** in `DocumentAgentLink`, `documentLinks`,
`setDocumentRelationships`, `updateDocumentRelationshipOverlay`, or either overlay
view. What it actually did: made `openDocument` resolve the owning project from
the source tile / durable `DocumentLocation`, switch workspace if needed, and set
the active creation scope before spawning — so **more** links get created than
before, since the open previously failed with "no project open". It also added
`flatCompatibilitySceneActive` / `retireFlatCompatibilityScene()` gating.

One inconsistency worth noting rather than fixing blind:
`updateDocumentRelationshipOverlay()` reads `tileViews` **directly and ungated**
(`CanvasNSView.swift:1703`), which is benign only because retirement empties that
dictionary. If retirement were ever skipped while the flag flipped, the overlay
would index views the rest of the app considers gone.

### The link model, for the record

`DocumentAgentLink { agentId, documentTileId, createdAt, updatedAt }`
(`DocumentLocation.swift:107-119`), stored on **`WorkspaceDocument.documentLinks`**
(`:26`) — not `CanvasState` — with dedup on min-createdAt / max-updatedAt
(`:68-80`), persisted through `WorkspaceStore.save`. Schema v5 introduced durable
agent-to-document relationships; HEAD is v8. `edb68e8` ("Cover document links
across schema v6 migration") touched **only** the checks file — no production
model change. The link keys the document by **tile UUID**, so it survives
relaunch only as long as the tile id does; durable path identity lives separately
on `tile.metadata.documentLocation`.

## 5b. Why one link in three did nothing

There is no single bug; there are **five distinct silent no-ops**, ranked by how
likely each is to be the one observed. What unites them is a deliberate design
decision:

```swift
// ContinuumApp.swift:13319-13322
if case let .refused(reason) = result {
    // A link that resolves to nothing is content, not an error worth a
    // modal: the agent may be naming a file it has not written yet.
    fputs("Agent local-file link did not resolve inside \(record.cwd): \(reason)\n", stderr)
    return false
}
```

Every resolver refusal is **stderr-only, by design**. The reasoning is sound —
the agent may be naming a file it hasn't written — but the effect is that a large
family of failures is indistinguishable from a dead click. Note this *reverses*
plan 15's own requirement: *"If tile creation itself cannot proceed… the
initiating surface should show a small user-facing error instead of only beeping
or writing to stderr."* That is honoured for `openDocument` failures
(`presentFileOpenFailure`, `ContinuumApp.swift:13291-13299`) and explicitly not
for the agent-link path.

### The five, ranked

1. **The file was already open, off-screen.** `spawnFileImpl` dedupes against
   `canvasView.allWorkspaceTiles()` — workspace-wide, any zone, collapsed or
   off-screen — and returns `.alreadyOpen` with the comment *"it is not moved"*
   (`TileSpawner.swift:2153-2155`). That maps to `.revealed` →
   `focusSpawnedTile` → `focusBroker.enterScope(...)`
   (`ContinuumApp.swift:11330-11332`), and **`focusSpawnedTile` never moves the
   camera.** Compare `revealTileForWork` (`:12321-12334`), which does
   `framedViewportForTileJump` + `setViewport`. So the click transfers keyboard
   focus to a tile you cannot see and the visible canvas does not change. Before
   `ecf3bf3`, not even a focus border appeared, because focus borders read the
   flat-only `tileViews[...]`.

2. **The path didn't resolve inside the agent's `cwd`.** Production resolves
   against `AgentRecord.cwd` (`ContinuumApp.swift:13312`), and **`cwd` is the
   agent's *Home* root — `checkoutRoot + homeRelativePath`** — not the project
   root. So for an agent whose Home is a subfolder, every repo-root-relative
   path the model writes (`Sources/App.swift`, `docs/x.md`) resolves under the
   subfolder and fails `.notARegularFile`. Same bucket: a worktree agent naming
   an absolute path in the main checkout (`.outsideCheckout`), a directory link,
   a file not yet written, and a **percent-encoding bug** — decoding happens only
   in the `file:` branch (`AgentLocalFileLink.swift:53-63`), so
   `[doc](My%20File.md)` looks for a file literally named `My%20File.md`.

3. **The link was underlined but never clickable.** `AgentTextStyleResolver`
   adds `.underlineStyle` + `.agentLinkDestination` to **every** link, but adds
   `.link` — the attribute that produces the pointing-hand cursor and makes
   NSTextView call `clickedOnLink` — **only** for
   `openExternally | openInternally | openLocalFile` (`:104-111`, verified). A
   `displayOnly` link therefore looks identical to a working one and the click is
   swallowed with no action, no stderr, nothing. `displayOnly` includes
   **`~/Documents/notes.md`** (`AgentLink.swift:111-114` rejects `~`-prefixed),
   any destination containing a space, a bare word with no dot
   (`[readme](readme)`), `notes.md#section`, Windows-ish paths, and
   `file://host/…`. Right-click offers no escape hatch either — the "Open File"
   menu item is gated on the same dispositions.

4. **`onOpenLocalFile` was never wired.** `performV2RenderAction` optional-chains
   it (`ManagedAgentTileNSView.swift:1940-1945`), so a nil closure is a total
   no-op. Two ways to get there: the **respawn-suppressed** branch of
   `wireManagedAgentTile` (`ContinuumApp.swift:11547-11565`) returns after wiring
   only `onSubmitPrompt` — so a tile whose agent you deleted still shows its
   restored transcript with **every file link permanently dead** — and
   `records[agentID]` being absent (`:13310`), which returns `false` without even
   an stderr line.

5. **It opened, but not where you were looking.** After a workspace switch,
   `retireFlatCompatibilityScene()` makes `zoneId(containing:)` return nil and
   `projectTiles()` return `[]` for a flat-scene tile. Agent tiles are still in
   the unmigrated flat model (hazard 9), so `sourceZoneId` → nil → `targetZoneId`
   → nil → `spawnFileImpl`'s anchor is nil → `.beside` degrades to automatic
   placement with `tile.zoneId = nil` and no camera move
   (`TileSpawner.swift:2151-2172`).

### Detection is stricter than you'd guess

Only **explicit Markdown links** are ever clickable. There is no bare-path
autolinking anywhere in the tree, and inline code can never be a link — so
`Sources/Foo.swift:42` in prose or in backticks is not clickable at all. That
matches plan 15's stated scope, but it means "why did this path not work" is
sometimes "it was never a link."

Navigation suffixes support `path:line`, `path:line:col` and `#L42`/`#L42C8`
(`AgentLink.swift:128-159`), stripping at most two trailing all-digit segments —
so `App.swift:42:8:3` mis-parses, and a real filename ending in `:2` is misread.

### The witness looks strong and misses all five

`--agent-local-file-link-check` is genuinely good: it ingests real assistant
Markdown, calls the real `activateLink` at a real character index, and asserts a
real `FileTileNSView` loaded the sentinel with the selection on line 3. But:

- it **wires its own `agentView.onOpenLocalFile` closure**
  (`FileOpenChecks.swift:833-846`) and therefore never executes
  `AppDelegate.openAgentLocalFile` — so the `records[agentID]` guard, the use of
  `record.cwd`, and `record.projectId` are all unwitnessed;
- it passes `checkoutRoot: checkout` (the **project root**) where production
  passes `record.cwd` (the **Home root**), so cause #2 cannot be caught;
- it asserts only `focusBroker.activeSurface == .tile(fileTileId)` — **nothing
  asserts the tile is on-screen or in the viewport**, so causes #1 and #5 are
  invisible to it;
- it asserts the no-feedback-on-refusal behaviour as *correct*.

This is the same shape as §5a: a check that drives a real path but is blind in
the one axis where the defect lives — there, the camera; here, the entry point
and the viewport.

### Proposed repair

- Make `.revealed` **move the camera**, reusing `revealTileForWork`'s
  `framedViewportForTileJump`, so "already open" is never indistinguishable from
  "nothing happened."
- Resolve against the **checkout root**, not the Home root, or try Home first and
  fall back to the checkout — and make the witness pass `record.cwd` so the
  divergence is catchable.
- Percent-decode non-`file:` destinations.
- **Give a `displayOnly` link a different visual treatment.** Underlining
  something unclickable is the lie. Either style it as inert or make `~` and
  spaces resolvable.
- Replace stderr-only refusal with a quiet inline affordance on the link itself
  (a tooltip or a subtle strike), keeping the "not a modal" instinct while
  ending the silence.
- Wire `onOpenLocalFile` in the respawn-suppressed branch, or visibly mark a
  dead-transcript tile as read-only.
- Extend the witness: assert viewport containment after activation, and drive
  `AppDelegate.openAgentLocalFile` rather than a substitute closure.

## 5c. Second independent cause: connectors are never refreshed after a cold launch

`refreshDocumentRelationships()` has exactly **four** call sites
(`WorkspaceRuntime.swift`):

| line | trigger |
|---|---|
| `:411` | `documentAgentTileIdsProvider` `didSet` |
| `:546` | inside `openDocument`, when a link is created |
| `:582` | link removal |
| `:711` | `switchWorkspace` |

The provider is assigned during boot at `ContinuumApp.swift:3991`, whose `didSet`
fires immediately — but the tile-install walk happens **after** (`:4045+`), and
agent records may not be restored yet either. So the one refresh at launch
computes segments against an empty canvas, gets `[]`, and **nothing ever refreshes
again**: there is no call after tile installation, after agent restore, or after
zone hydration.

Result: on every cold launch the links are on disk and correct, and both the
connectors *and* the file tiles' "N references" chips are **invisible until you
happen to open another linked document or switch workspaces**.

This is independent of the pan bug in §5a and compounds with it. Together they
fully explain "there is still no visual linkage": the segments are usually never
computed, and when they are, they are drawn displaced by the pan or clipped away
entirely.

The relaunch witness cannot catch it — `FileOpenChecks.swift:1063` sets the
provider **after** installing tiles, i.e. in the correct order that production
does not use.

**Fix:** call `refreshDocumentRelationships()` after the boot tile-install walk
and after agent restore, and make the relaunch witness set the provider before
installing tiles, matching production.

## 5d. Consolidation notes for the note/document surfaces

Structural facts worth designing against:

- **There is no separate "document preview" tile kind.** Markdown is a
  *presentation mode* of `.file` (`FilePreview.presentation`) and also of
  `.note`'s Preview mode, which reuses the same `FileMarkdownDocumentView`. That
  duplication is the first consolidation target.
- **Document identity is a canonical absolute path**, workspace-wide, restricted
  to `kind == .file` (`TileSpawner.swift:2147-2155`). Canonicalization handles
  `/var` vs `/private/var`, `..` and relative paths, but **there is no case
  folding** — so on a case-insensitive APFS volume `README.md` and `readme.md`
  yield two tiles for one file. Dedupe also ignores `documentLocation.scope`, and
  a file already open as a **note** is invisible to the lookup.
- **The link model is one relationship, one direction, and no notes.**
  `DocumentAgentLink { agentId, documentTileId, createdAt, updatedAt }` — no
  path, no note id, no source tile id, no label, no line. A note cannot link to
  anything and nothing can link to a note; the only writer is `openDocument` when
  the request carries `sourceAgentId` (`WorkspaceRuntime.swift:539-548`).
- **The only surfaced direction is the inverse of the stored one.** The file tile
  lists "referenced by N agents" with a "Reveal agent N" menu
  (`FileTileNSView.swift:274-296`); the agent tile has **no** affordance listing
  its documents.
- **Note→document conversion is destructive, lossy and unlinked.**
  `convertNoteToDocument` (`TileSpawner.swift:1960-2018`) writes the body to a
  file, mutates the tile in place to `.file`, and deletes the note body and index
  entry. No link, no provenance. In the `.reusedExisting` branch it deletes the
  note while returning a *different* tile's id — so anything keyed on the note's
  id (focus history, group membership, lineage) now points at someone else's
  tile.
- **Cross-store split.** Links live on the `WorkspaceDocument` in Application
  Support; the document tile record lives in the project's `.array` canvas.
  Move a project between workspaces and every link to its file tiles is
  orphaned — nothing prunes dangling `documentTileId`s on load
  (`WorkspaceDocument.swift:271` only dedupes).
- **Two identity fields for one file** — legacy `metadata.filePath` and
  `metadata.documentLocation.path`, with a `??` fallback at both dedupe sites.
- **A link to an unattached agent renders nothing and offers no way back.**
  `updateDocumentRelationshipOverlay` skips any link whose agent has no
  `record.tileId`, which is exactly the running-and-unattached state after a tile
  close.
- **`emphasized` is driven by the retired flat model.** It reads
  `canvasState.lastActiveTileId` (`CanvasNSView.swift:1705`), which
  `retireFlatCompatibilityScene()` nils (`:5063`) — so connector emphasis can go
  permanently dead after a workspace switch.
- **Two more tile kinds still use the buggy flat path:**
  `spawnDiffReviewFromPalette` (`ContinuumApp.swift:13491-13512`) and
  `spawnRunArtifacts` (`TileSpawner.swift:2245-2261`) use `canvasView.install`
  instead of `installProjectTile`. Spawned after a workspace switch, they are
  visible but absent from `tileView(for:)`, `allWorkspaceTiles()`,
  `navigationTileSnapshots()` and `tileRecord(for:)`, persisted into the retired
  flat canvas, and lost on relaunch.
- **`installNoteTile` drops metadata:** it rebuilds `TileMetadata` with 5 of 19
  fields (`TileSpawner.swift:1932-1939`), losing `documentLocation`,
  `filesystem*`, `worktreeId`, `reviewId`, then saves the canvas.

### Coverage gaps to close alongside

Nothing asserts: a link activated while the target is **off-viewport** moves the
camera; connectors and reference chips exist **immediately after a cold launch's
tile-install walk**; any note participation in links; dedupe on a
case-insensitive filesystem; or that a diff-review / run-artifacts tile spawned
**after** a workspace switch is still reachable.

## 5e. The real regression: a workspace switch turns every tile into a dead placeholder

This is the most consequential finding in the investigation and it should
probably be fixed before any of Slice 1.

Both `WorkspaceRuntime.install` (`:229-234`) and `WorkspaceRuntime.switchWorkspace`
(`:680-684`) build a ZoneLayer's tile views like this:

```swift
// Build tile views (descriptor views — headless safe; real hydration is T08).
var tileViews: [UUID: TileNSView] = [:]
for tile in memberTiles {
    let view = DescriptorTileNSView(tile: tile)
    tileViews[tile.id] = view
}
```

Real views are only ever built by the `installInitial*` family, and
`installInitialManagedAgentTile` has **exactly one production call site** — the
boot tile walk (`ContinuumApp.swift:4074`). There is no post-switch rehydration
anywhere; the comment names it as unfinished work ("T08").

So at boot the descriptor layer is immediately overwritten by real views and
everything works. **After the first in-process workspace switch, the tiles in
the rebuilt layers are `DescriptorTileNSView` placeholders** — no transcript, no
composer, no links, nothing to click.

### Why this reads as a recent regression

Before `ecf3bf3`, the flat `tileViews` table survived a switch and
`tileView(for:)` consulted it first, so a boot-project tile still resolved to its
**real** view. `ecf3bf3` added `retireFlatCompatibilityScene()`, which empties
that table and gates every accessor behind `flatCompatibilitySceneActive`. The
latent descriptor-only defect therefore became *live*: the real views are gone
and only placeholders remain.

`ecf3bf3` is still a correct change on its own terms — and §5a stands, it did not
break the connectors. But it did convert a dormant hazard into an observable one,
which is almost certainly the "recent scoping changes with agent tiles and zones"
instinct. Note the trap: `openDocument` **itself** now calls `switchWorkspace`
when a link's owning project lives in another workspace (`:486-500`), so clicking
one cross-workspace link can be what kills the tiles the *next* link lived in.

### Two further hazards on the same seam

- **Data loss.** `persistProjectCanvas` writes
  `state.tiles = canvasView.tiles(forProjectId:)`, and that helper reads
  **installed layers only** (`CanvasNSView.swift:5214-5219`). So a link spawn
  that persists a project whose other zones are not hydrated **erases those
  tiles from the project's canvas file.** This is on the "correct" path and has
  no witness.
- **Cross-project misfiling on the agent-reveal path.** `spawnManagedAgent`
  stamps `filesystemProjectId` / `filesystemCheckoutRootPath` from the
  `creationScopeProvider` — i.e. the *active zone* — not from the agent record
  (`TileSpawner.swift:1471, 1524-1531`). So a revealed child of a different
  project gets a tile whose persisted scope metadata claims the wrong project.
  `spawnerForFilesystemCreation()` exists and does the right thing, but
  `attachTileToAgentFromInbox` uses the plain `tileSpawner` property instead.

### Corrections to CLAUDE.md hazard 9

Hazard 9's claim that *"terminal, note, browser, and agent spawns have NOT been
migrated yet"* is **out of date — all four are migrated** and use
`installProjectTile` / `makeProjectTilePlacement`. The single remaining
production spawn on the stale path is **`spawnRunArtifacts`**
(`TileSpawner.swift:2246, 2262`), which hazard 9 does not mention;
`makePlacement` now has exactly one caller. `materializeDiffReviewTile` is
boot-only flat. The two-model description itself is still accurate.

The hazard's citation of `TileSpawner.swift:1422` for "a ZoneLayer rebuild turns
`.managedAgent` tiles into dead descriptor placeholders" is wrong — that line is
`configureBrowserRuntime`, and `TileSpawner.swift` contains no occurrence of
`Descriptor`. **The substance of the claim is true**, but it lives in
`WorkspaceRuntime.swift:229-234` and `:680-684`, and it applies to *every* tile
kind, not only `.managedAgent`. Worth correcting in place, since agents read that
file as ground truth.

### Overlap with `.plans/41`

`41` was written pre-`ecf3bf3`. Its findings **C** (flat tiles contaminate
`navigationTileSnapshots`; stale flat record shadows the layer record) and **E**
(stale `canvasState.lastActiveTileId` reactivates an old location) are **now
fixed** by that commit — worth telling its author. Its finding **D** (zone
navigation tied to `zoneRenderModels`) is **not fixed and is arguably inverted**:
`retireFlatCompatibilityScene` clears `zoneRenderModels` and neither `setZones`
nor `_installLayer` repopulates it, so post-switch Cmd+K rows and
`fitZoneToViewport`'s first lookup see an empty array — previously stale, now
empty. Its findings **A** and **B** (a closed zone remains a Cmd+K destination;
`closeZone` never calls `removeZoneLayer`) are untouched and bear directly on
document links, since a "closed" project zone can still be the zone
`openDocument` activates.

`41`'s recommended repair — one authoritative current-scene projection plus one
runtime-owned close transaction — is also the right home for the ungated flat
read in `updateDocumentRelationshipOverlay`, the `tiles(forProjectId:)`
truncation above, and the target-zone/active-zone sibling mismatch in
`makeProjectTilePlacement`.

Also present and working: `FileTileNSView.setReferencedAgentTiles`
(`FileTileNSView.swift:274-291`) puts an "N references" label with a
"Reveal agent N" menu in the document tile's title bar
(wired `CanvasNSView.swift:1635-1640`). So there *is* a functioning textual
back-reference; it is the drawn connector that is broken.

---

# Cross-cutting: fix regardless of slice

- **Every persisted transcript is write-only.** Production writes
  `sessionID = "managed-<tileId>"`; the sole reader hardcodes `"thread-main"`.
  The store's own check picks its own key, so it cannot catch this.
  `AgentSupervisor.archive` also orphans the transcript directory forever.
- Child tiles whose `projectId` differs from the active project are installed
  into the active project anyway, with only a stderr warning.

---

# Verification doctrine

- Judge `scripts/run-matrix.sh` by its **end-of-run summary**, never the exit
  code. Confirm every new leg actually prints. No new KNOWN-RED silently.
- Every witness drives the **real** entry point. `AgentFirstPaintChecks` is the
  counterexample to imitate nobody: three green cases over hand-built snapshots
  while production is broken.
- Assert counts and ordering, not wall-clock.
- `performance.md` is binding: bounded view count per row, no measurement in
  `layout()`, no unconditional frame assignment, no self-sizing during own
  layout, `.legacy` scrollers tested, visible notice on any truncation, measured
  in both themes because heights are cached.
- New themed views: `TokenThemed` + `tokenAdoptedOwners` with a ticket comment +
  painted in both appearances + `nil` at rest.
- **Look at it.** Per slice: `scripts/dev-app.sh` against a root no other agent
  is using, screenshot the fixture gallery and the live tile, compare against the
  previous slice. A slice is not done until it has been seen.

---

# Open questions

1. Slice 1 is large. Split it into 1a-1b (fixtures + data capture, no visible
   change) and 1c-1h (the visible overhaul), so the first lands verifiable and
   invisible?
2. The live-work row spans slices 1 and 2 by construction. Accept that, or pull
   just the `submittedAt` fix forward into slice 1 so the row is honest on
   arrival? It is a two-line change plus a witness.
3. Tool-call clustering changes turn structure, which interacts with turn
   folding (1f). Do both together or is folding a separate slice?
4. Does the inline diff need a "reveal in diff tile" affordance, or is bounded
   inline enough? `AgentDiffPayload.canOpenReview` exists and the projection
   never sets it true.
5. Companion: confirm it stays paused until the write-only key bug is fixed and
   the desktop has the intended feel.

# 42 — Agent tile transcript UX: dead air, commands, compaction, tool fidelity

Date: 2026-08-22

Status: **brainstorming / architecture discussion draft.** No implementation has
started. Findings below come from `main` at `736cb93` plus live CLI probes run on
this machine. Not yet a ticket breakdown or an approved plan.

Concurrent work to avoid: another agent holds uncommitted edits in
`AgentSupervisor.swift`, `AgentComposerFooterView.swift` and
`ManagedAgentTileNSView.swift` (harness-pick atomicity), and `.plans/41` is a
separate zone-lifecycle investigation. Nothing here was edited.

Prior art this supersedes nothing of, and must be read with:

- `~/.claude/plans/we-had-a-codex-mighty-hinton.md` — the transcript renovation
  plan. Still correct. This document adds the empirical CLI layer it lacked, and
  the command/compaction dimension it did not cover.
- `docs/38-tickets/99-transcript-subagents-renovation-handoff.md` — the
  post-mortem of the session that did not deliver it.
- `docs/38-tickets/91-agent-tile-ux/_DESIGN.md` — the visual charter.
- `docs/38-tickets/90-agent-ux/P5.6-compact.md` — the open `/compact` ticket.

---

# Part I — Empirical: what the harnesses actually offer

Everything in this section was observed, not inferred. Versions on this machine:
pi 0.84.1, claude 2.1.239, codex-cli 0.148.0.

## 1. Claude Code publishes a control channel Array discards

`ClaudeEventTranslator.swift:71-72` gates the `system` type to
`subtype == "init"` and returns `[]` for everything else. That one line discards:

| event | payload |
|---|---|
| `system/status status:"requesting"` | fires **before** the model call — a real pre-token ack |
| `system/status status:"compacting"` | compaction started |
| `system/status compact_result:"success"\|"failed"` | outcome, with `compact_error` |
| `system/compact_boundary` | see below |
| `rate_limit_event` | five-hour window state, `resetsAt`, overage status |

`compact_boundary.compact_metadata`, captured verbatim:

```json
{ "trigger": "manual", "pre_tokens": 24858, "post_tokens": 2289,
  "cumulative_dropped_tokens": 22569, "duration_ms": 37616,
  "preserved_segment": { "head_uuid": "…", "anchor_uuid": "…", "tail_uuid": "…" },
  "preserved_messages": { "all_uuids": ["…"] } }
```

And `system/init` is a full capability manifest, not just a session id:
`slash_commands` (47 on this machine, including project-local ones), `skills`
(16), `agents` (`["claude","Explore","general-purpose","Plan",
"statusline-setup"]`), `terminal_slash_commands`, `capabilities`
(`["interrupt_receipt_v1","interrupt_cancel_queued_v1","msg_lifecycle_v1"]`),
`model`, `permissionMode`, `memory_paths`, `messaging_socket_path`.

## 2. `/compact` already works on a claude tile — Array cannot see it

Observed sequence for `claude -p "/compact" --resume <sid>` on a session with
history:

```
system/status  status:"compacting"
system/status  compact_result:"success"
system/init                                   ← session re-initialized
system/compact_boundary                       ← the marker, with metadata above
user  "This session is being continued from a previous conversation…"  (7,116 chars)
user  "<local-command-stdout>Compacted </local-command-stdout>"
result num_turns:0, usage all zeros
```

Three consequences that change the design:

1. **The handoff Dylan saw was the compaction summary**, and it is a **`user`**
   message, not an assistant one. The agent was not talking to him; the CLI was
   re-seeding its own context and he was shown the machinery.
2. **`<local-command-stdout>…</local-command-stdout>` is the discriminator**
   between CLI-authored output and model output. Corroborated by `num_turns: 0`
   and all-zero usage.
3. On an empty session the refusal (`"Not enough messages to compact."`) is
   delivered as an `assistant` text block. So today Array would render CLI
   control output as if the model said it. That is a fidelity bug independent of
   any redesign.

## 3. Codex: the collaboration schema is real, spawning is not reachable

`codex features list` shows `multi_agent` **stable/true** (default on),
`multi_agent_v2` stable/false, `collaboration_modes` removed/true.

`collab_tool_call` items **do** appear on `codex exec --json`, with exactly the
shape the renovation plan hypothesized:

```json
{ "type":"collab_tool_call", "tool":"wait",
  "sender_thread_id":"01a02778-72b2-7a30-a334-383076b6c95b",
  "receiver_thread_ids":[], "prompt":null, "agents_states":{},
  "status":"completed" }
```

But across two runs in a throwaway repo whose `AGENTS.md` explicitly authorized
and required delegation — one of them with `[agents.reader]` supplied via `-c`
overrides — the model only ever received `wait`. `receiver_thread_ids` stayed
empty and `agents_states` stayed `{}`. **`spawn_agent` was never available.**

So the plan's Phase 0 experiment resolves to: the *stream contract* is outcome 1
(durable thread ids would arrive on the stream we already parse), but the
*capability* is currently outcome 3 in `codex exec` — only the wait half is
exposed. Do not design Codex delegation on the assumption that `spawn` is
reachable; re-probe when `multi_agent_v2` flips.

Caution worth recording: in both runs codex confidently reported
`a.txt: alpha` / `b.txt: beta` having never read either file and having spawned
nobody. It inferred contents from the filenames and happened to be right. **If
Array ever renders a delegated result, it must render the evidence, not the
claim.**

## 4. Pi

`--mode rpc` exists and Array does not use it (`PiAgentRunner.swift:59-65` uses
`--mode json`). Pi's slash vocabulary resolves against `--skill` and
`--prompt-template` discovery. Pi has no native subagent primitive; `spawn_agent`
is Array's own invention via an inert extension, and that extension is **not
installed on this machine** (`~/.pi/agent/extensions/` lacks
`continuum-spawn-agent.ts`), nor is it `-e`-loaded, nor allowlisted. So even the
model cannot delegate today.

Separately, `~/.pi/agent/extensions/harness-agents` is an unrelated third-party
delegation system with its own `delegate_agent` tool and run store. Array does
not read it. It parses the same `.pi/agents` frontmatter but additionally
requires `description`, which Array does not — a silent-divergence trap.

---

# Part II — Dead air: the actual causes, in felt order

## The bug: `.ready` destroys the spawn-window anchor

`turnSnapshot(for:)` reaches `.starting` only when
`runners[id] != nil && facts.submittedAt != nil`
(`AgentSupervisor.swift:3237`). `updateTurnFacts` clears `submittedAt` on
`.ready` (`AgentSupervisor.swift:3994-3998`, with a mis-indented duplicated
assignment). The field's own doc comment states the intended invariant —
*"Cleared by the same transitions that clear `turnStartedAt`"* — and that is
precisely the flaw, because `.ready` arrives **before** the turn.

All three translators emit it first, but with different line structure, which is
why this feels random:

| harness | stdout structure | visible result |
|---|---|---|
| **codex** | `thread.started` → `[.ready, .running]`; `turn.started` on a **later line** | indicator dies at `thread.started`, header flips to "Idle", returns at `turn.started`. **One real gap = first-response latency.** |
| **pi** | `session`→`.ready`; `agent_start`→`.running`; `turn_start`→`.turnStarted`, three separate lines | **two gaps** |
| **claude** | `system/init` returns all three in one batch (`ClaudeEventTranslator.swift:85-89`) | three main-queue hops drain in one runloop turn; probably never paints the hidden state |

Each event gets its own `DispatchQueue.main.async`
(`AgentSupervisor.swift:2071`), so claude coalesces and codex/pi do not. **The
same tile behaves differently per harness.** Dylan lives in codex sessions.

Secondary flicker, all harnesses: `AgentTranscriptProjection.mutations` calls
`closeStreamingRun()` on `.itemStarted`, so every text→tool→text boundary flips
`latestStreamIsVisible` and toggles the gyro — each toggle running a full
diffable-datasource apply + `invalidateForStructureChange()` +
`layoutSubtreeIfNeeded()`.

## The other cause: blocking main-thread I/O in the send path

`sendPrepared` calls `persist(record)` **on the main actor**
(`AgentSupervisor.swift:2043`), which does `withAgentStoreLock` →
`flock(LOCK_EX)` across processes → `AtomicWriter` → two `fsync`s. The UI cannot
repaint during it, and it is unbounded under contention. This is the "sometimes
it hangs longer with no loader at all" case. The same path fires again on every
persist-worthy lifecycle event, several of which land in the first second.

Also on the send path: for a role-bearing pi agent, `makeRunner` does a
main-actor directory walk plus frontmatter parse of `.pi/agents`
(`AgentSupervisor.swift:1131-1137`).

## The dropped-message case

`sendRefusal` **refuses outright** while model-catalogue readiness is
`.checking` — up to 5s after launch. The first message after opening Array is
not slow, it is discarded, with the draft restored. Queue it instead.

## The witness gap that let this in

`AgentFirstPaintChecks` exists and is in the matrix
(`scripts/run-matrix.sh:530`), but all three of its cases construct
`AgentTileTurnSnapshot(state: .starting, …)` **by hand**. Nothing drives the real
sequence `[.ready, .running, .turnStarted]` through `updateTurnFacts` and asserts
the snapshot stays `.starting`. This is the known "witness re-derives what
production derives" failure mode: the leg is green while production is broken.

**Proposed repair order** (each with a count/ordering witness, not a stopwatch):

1. Stop clearing `submittedAt` on `.ready` before a turn exists. Add the missing
   witness first, driving real events. RED, then fix.
2. Give `.running`-without-turn a real phase in
   `AgentCompactStatusPhaseAdapter` so the words don't go blank
   (`AgentCompactStatusPhaseAdapter.swift:232-236` returns `.unknown`).
3. Seed compact-status facts on `send`, not only `attach`
   (`ManagedAgentTileNSView.swift:1128`), so the footer and elapsed tick run
   during the spawn window.
4. Get `persist` off the main actor (or after runner dispatch).
5. Queue during `.checking` instead of refusing.
6. Make the gyro sticky across tool boundaries rather than recomputed per event.
7. Consume claude's `system/status status:"requesting"` as a real
   provider-accepted phase.

---

# Part III — Slash commands: a menu with no engine

`9fb1284` (2026-08-20) added a genuinely good catalog and popover:
`AgentCommandCatalog.swift` (~120 commands, four surfaces, availability and
disabled-reasons), typed `AgentCommandInvocation`, resource discovery over
`.claude/{skills,commands,plugins}` / `.pi/{skills,prompts,extensions}` /
`.codex/skills`, and `.array/commands/*.json` manifests.

**There is no execution path.** `AgentSupervisor.accept`
(`AgentSupervisor.swift:3322-3332`) refuses `.cli` and otherwise calls
`nativeSlashText` and sends the literal string as an ordinary user turn. Nothing
in the tree switches on `surface == .array` — grep for `case .array` yields only
a popover icon. So `/clear`, `/help`, `/status`, `/diff` are prose.

Three bugs that are cheap and worth fixing regardless of direction:

1. **One command, two appearances.** Accepting the popover row bypasses
   `submitBoundIntent`, so `previewPrompt` is never computed and the optimistic
   echo never fires — but typing `/compact` then Esc-then-Enter *does* echo.
   Identical bytes, two different transcripts.
2. **Bare Enter is swallowed.** `focusedID` starts nil
   (`ChoiceListView.swift:107`) and `perform` returns `true` unconditionally
   (`ChoicePopoverController.swift:398-403`), so you must arrow onto a row first
   or nothing happens.
3. **`automaticCompaction` can never render.** The field exists on
   `TokenUsageSnapshot`; all three translators hardcode `nil`. The UI is already
   wired for it (`AgentCompactStatusPresentation.swift:564-565`).

## Proposed taxonomy — the answer to "what is a slash command to these agents"

There is no shared slash layer across the three harnesses, so there cannot be one
pass-through. Three tiers, and a command's tier decides who authors the reply:

| tier | examples | mechanism | transcript treatment |
|---|---|---|---|
| **Array-owned** | `/clear`, `/new`, `/fork`, `/status`, `/diff`, `/help` | Array performs it; **never reaches the CLI as text** | a system row authored by Array |
| **Harness-delegated** | `/compact`, `/context`, `/model`, claude's other 44 | forwarded as today, but the reply attributed to the **harness** and reconciled against `system/status` | a harness-authored control row, visually distinct from both user and assistant |
| **Skill / template** | `/deep-research`, `/code-review`, pi prompt templates | genuinely a user turn | a normal user turn |

Two structural improvements:

- **Discover, don't hardcode.** Claude publishes `slash_commands`, `skills` and
  `agents` on `system/init`. The hardcoded 40/64/13 baselines will drift and
  cannot see a project's own commands. Keep the baselines as the pre-first-turn
  fallback; replace them with the manifest once `init` arrives.
- **Refuse honestly.** A command Array cannot actually perform should be
  disabled with a reason, exactly as `.cli` rows already are — not silently
  degraded into prose. The current failure mode is the same "negotiating
  forever" dishonesty the companion was criticised for.

---

# Part IV — Compact and clear: who owns the transcript's truth

## The divergence, precisely

After the CLI compacts, Array's document keeps the full pre-compaction history
(the reducer is append-only; compaction produces no mutation). The CLI's working
context holds a summary. Array's transcript is a **superset with no boundary
marker**. The handoff summary lands as an ordinary turn, indistinguishable from
any other.

On relaunch the divergence **flips and becomes lossy**: rehydration reads the
provider `.jsonl` tail (80 messages / 512 KB), and `PiSessionTranscriptReader`
explicitly skips `compaction` lines. So the restored tile shows neither the
pre-compaction history nor the boundary — while the full original sits unread on
disk.

## Position

**Array's transcript stays complete and grows a visible boundary.** The handoff
is content; deleting it would be worse than showing it. But the *context meter*
and the *resume path* must follow the CLI, not the transcript. Concretely:

- Consume `compact_boundary` → insert a first-class compaction entry (a new
  block kind, not the `Notice` variant of `AgentErrorNoticeView`, which is
  pixel-identical to an error).
- Set occupancy authoritatively from `post_tokens`. Today the ring holds the
  pre-compaction percentage until the *next* turn completes, so it is
  confidently wrong for the whole interval. Plan 19 listed proving exactly this
  case; the witness was never written.
- Render the handoff summary as *collapsed* by default, attributed to the
  harness, since it is machinery rather than conversation.
- Distinguish `trigger: "manual"` from auto-compaction in the copy.

## `/clear`

Today `/clear` is prose. If it were real, the state that would go stale is
enumerated below, and **none of it currently resets**:

| state | should | does |
|---|---|---|
| Array `AgentDocument` + `snapshot.json` | boundary entry (not truncation) | nothing |
| visible transcript rows | divider | nothing |
| context meter | 0% / unknown | nothing until next turn |
| `record.lastContextWindow` on disk | invalidate | persists pre-clear reading, re-seeds as `.stale`-but-numeric |
| replay buffer (cap 500) | drop | nothing |
| subagent chips | orphan/annotate — the parent CLI no longer knows them | still render, still resolve |
| tile title | keep or re-derive | **if `/clear` is the first prompt in a fresh tile, the tile is permanently named after the slash command** — `displayNameSource` leaves `.sentinel` and never re-arms |
| cumulative telemetry | boundary | keeps climbing across it |

Note claude/pi session ids are pure functions of the agent UUID
(`AgentSupervisor.swift:1029`, `:1039`), so there is no id to rotate. A real
`/clear` requires either changing that derivation or using `--fork-session`.

## Unrelated bug found on the way: every persisted transcript is write-only

Production tiles write under `sessionID = "managed-<tileId>"`
(`TileSpawner.swift:1477`). The only reader — the phone-sync document provider —
hardcodes `"thread-main"` (`ContinuumApp.swift:8326-8330`), which is the
`ManagedAgentTileNSView` *default* parameter no production tile uses. So
`AgentTranscriptStore` has been accumulating snapshots nothing ever reads, and
this is also why the companion transcript fetch returns nil. The store's own
check picks its own key, so it structurally cannot catch this. Separately,
`AgentSupervisor.archive` deletes the record and orphans the transcript
directory forever.

---

# Part V — Tool rows and the missing diff

## The diff is a data-capture problem, not a rendering one

`grep` for `old_string` / `new_string` / `structuredPatch` has **zero**
production hits. All three translators discard tool inputs at parse time under
the I5 sync-boundary invariant:

- **claude** — `tool_use.input` goes only to a path-key whitelist
  (`file_path`/`notebook_path`/`path`) to extract a `URL`;
  `old_string`/`new_string`/`content` are dropped
  (`ClaudeEventTranslator.swift:266-302`). `input_json_delta` discarded.
  `tool_result` reads only `tool_use_id` and `is_error`.
- **codex** — `file_change` reads only `changes[0].path`; title is the literal
  `"Edit"`; `changes[]` content never read.
- **pi** — has the whole `args` object and keeps operation + one path key.

Worse: production `recordEnd` always passes `output: nil, exitCode: nil,
endedAt: nil`, so **duration and exit code are structurally unrenderable**, and
`CommandOutputView` — a complete scrollable output pane with a copy button — is
**dead code**, because no translator emits `contentDelta(.commandOutput)`.

The sanctioned fix already exists and is already wired: `AgentToolDetailStore` is
host-local, non-`Codable`, never synced, TTL-scoped, with bounded limits and a
fail-closed redactor. It models `arguments`, `output`, `exitCode`,
`startedAt`/`endedAt`, `duration`, `affectedFiles`, and
`AgentToolDetailPresenter.expanded(_:)` already produces a complete presentation
nothing renders. It is simply being fed empty arguments. Widening **it** — never
`AgentRuntimeEvent` — is explicitly pre-authorized
(`plan-managed-agent-tile-polish.md` §12.3).

For rendering, two reusable pieces exist: `GitDiffParser.parse` is a pure
Core-level unified-diff parser, and `DiffReviewTileNSView.render(_:theme:)` is
already `static` and pure with theme as a parameter.

## Why the rows look bad — specific causes, not taste

From the shipped baseline
(`docs/38-tickets/91-agent-tile-ux/baselines/semantic-transcript-mixed-480x720-darkAqua.png`):

1. **Nine row kinds are the same box** — tool call, command output, plan, diff,
   approval, error, notice, unknown, subagent chip, image, file rail all paint
   `AgentSurfaceRole.artifact` at radius 8 with no border. The only
   discriminators are a 15pt-vs-11pt title, an optional glyph, and a 9pt grey
   status word. A one-line tool call gets the same visual weight as an entire
   plan.
2. **Error and Notice are pixel-identical** but for one word. A compaction
   notice will look like a failure.
3. **One `wrench.and.screwdriver` for every tool.**
4. **The summary restates the title** — `Edit` on line one, `Edited Foo.swift`
   on line two — because `pureSummary` is dedup'd only against the *status*
   label, not the title.
5. **Status is caption text `"✓ Completed"`**, not a reserved glyph column, so
   text reflows when status lands.
6. **`presentedToolBlock` returns early for `.inProgress`**
   (`AgentTranscriptListView.swift:1356-1358`), so a running tool shows only
   name + status — exactly when you are staring at it.
7. **There is no unit larger than a block.** `rowSpacing = 12` and nothing
   overrides it, so paragraph→paragraph, turn→turn and error→tool are all 12pt.
   List items are separate rows at that same spacing, which is why bullet lists
   read as loose as paragraphs.
8. **Bullets and quote markers are inline text** (`"• "`, `"› "`), so wrapped
   lines run under the marker instead of hanging in a gutter — and a bullet and
   a blockquote are nearly indistinguishable.
9. **All six heading levels render at `.title` 15 semibold.** `#` and `######`
   are identical, and against 13pt body that is a very weak hierarchy.
10. **Artifact fills start at 12pt, prose text at 24pt**, so card edges and
    prose never share a left edge.
11. **Markdown tables have no renderer** — `Table` maps to `.fencedCode` and the
    raw pipe source is dumped as monospace. The parser's own comment says
    "Assistant replies use tables constantly — the common case."
12. **Thematic breaks render as 24pt of nothing.**
13. `Opacity.receded` (0.88) exists and no renderer uses it, so "completed work
    recedes" is unimplemented.

## Two live hazards in this code

- `ToolCallView` paints `layer.backgroundColor` but **does not declare
  `TokenThemed`** — its fill is invisible to the appearance census (hazard 8).
  The same is true of `CodeBlockView`, `AgentErrorNoticeView`, `AgentPlanView`,
  `AgentDiffSummaryView`, `AgentRequestView`, `CommandOutputView`,
  `UserPromptView`, `AgentReferenceChipView`, `AgentUnknownBlockView` — every
  transcript row view.
- `AgentDiffSummaryView.rebuildFileLabels()` removes and recreates up to 8
  `NSTextField`s on every `apply` — the pattern that froze the app in 0.4.16. Do
  not copy it for diff lines.
- `ToolCallView.layout()` assigns all five frames unconditionally every pass
  (performance.md trap 3).

---

# Part VI — Subagents and manual delegation

The sidebar tree, `AgentRecord.parentAgentID`, depth caps, child rollups,
`agentReference` chips, reveal, and a one-edge canvas lineage overlay all exist
and work. **What is missing is supply**, and per Part I the supply is currently
zero on all three harnesses on this machine.

Correction to a hazard: `CLAUDE.md` hazard 9 says agent spawns still use the
buggy flat path. For the *subagent reveal* path that is stale —
`revealAgentFromInbox` → `attachTileToAgentFromInbox` →
`TileSpawner.spawnManagedAgentForExistingAgent` → `installProjectTile`
(`TileSpawner.swift:1517`) is on the correct side. A live adjacent hazard
remains: if the child's `projectId` differs from the active project, its tile is
installed into the **active** project anyway with only a stderr warning
(`ContinuumApp.swift:9456-9459`).

Real hazard for persistence: a subagent with no tile never fires
`onSemanticTranscriptUpdated`, so it **has no persisted transcript at all** until
a human clicks its chip.

Position on manual delegation: it is worth supporting, but capability-honestly
per harness, and **not before Parts II–V**. `AgentCapabilities` already exists
for exactly this and is otherwise unused.

| harness | honest capability today |
|---|---|
| pi | a real child process Array owns — full transcript, stop, resume — **once the extension is installed and allowlisted** |
| claude | read-only reconstruction from `--forward-subagent-text` + `parent_tool_use_id`; no child session id, nothing to resume or stop. `ClaudeEventTranslator.isSubagentFrame` currently **drops** these frames; `observeSpawnRequests` is an empty stub |
| codex | nothing reachable in `exec` today (Part I §3). Re-probe on `multi_agent_v2` |

A child with `canStop: false` must show no Stop; a `.readOnly` child must say so
rather than offering a composer. The alternative — uniform presentation with
silently inert controls — is the companion's failure mode again.

---

# Part VII — Design direction to decide

The charter (`_DESIGN.md` §11) already says the right thing: *"fewer nested
fills"*, *"the transcript should read like a document, not a wall of cards"*.
The shipped baseline is a wall of cards. The gap is execution, not intent.

Direction I would argue for:

- **Prose is the page; artifacts are insets.** Only genuinely
  block-like content (code, diff, plan, approval) earns a fill. A tool call is a
  *line*, not a card: reserved glyph column, name, muted detail, chevron,
  reserved trailing status glyph, on one 32pt row with a hairline gutter — and
  consecutive tool calls cluster into one group rather than stacking cards.
- **A real vertical rhythm.** Three separations instead of one 12pt for
  everything: intra-block (~4), inter-block (~8), inter-turn (~20 plus a
  turn-level marker). List items must not use the inter-turn gap.
- **Hanging indents.** Move bullets/quote markers out of the text run into a
  gutter so wrapped lines align.
- **A heading ladder that ladders.** At minimum h1/h2 distinct from body by more
  than 2pt and a weight.
- **One live-work row** spanning preparing → provider wait → thinking → tool
  work → writing → input wait → failure → stop → completion, with elapsed and a
  working Stop; and a settled turn folding to `Worked for 1m 12s · 8 tools ·
  2 agents`.
- **Tables get a renderer.** It is the common case and it currently degrades to
  monospace pipes.

## Decisions I need from you

1. **User messages: right-aligned or not?** The renovation handoff asks for
   *"clearer right-aligned user messages"*; `_DESIGN.md` §11 and
   `UserPromptRenderer.swift:63-64` explicitly forbid becoming *"right-aligned
   chat bubbles"*. This contradiction is unresolved and blocks the turn-structure
   work. My lean: keep full-measure, differentiate by a quiet fill plus a gutter
   marker, not by alignment.
2. **Ship order.** My lean is dead air first (Part II) — it is what you feel
   without reading a diff, it is a handful of small changes, and the witness gap
   is embarrassing. Then tool-row data capture + rows (Part V), then commands
   (Part III), then compaction (Part IV), then delegation (Part VI).
3. **Do commands and compaction ship together?** They are coupled: `/compact` is
   the most valuable delegated command and its correctness depends on consuming
   `compact_boundary`. I would do Part III's taxonomy and Part IV's boundary as
   one slice.
4. **Fixtures first?** The renovation plan requires per-phase `.staticCard`
   fixtures *before* visual changes, and notes `agent.transcript.review` is a
   `.reviewSurface` today, hence skipped by every baseline sweep. Converting it
   is the precondition for not working blind. Confirm that is in scope for slice
   one.
5. **Companion:** stay paused? The handoff recommends desktop-first, and the
   write-only transcript key bug means the phone path cannot work regardless.

---

# Verification notes for whoever implements this

- Judge `scripts/run-matrix.sh` by its end-of-run summary, never the exit code.
  Confirm any new leg actually prints. Do not add KNOWN-RED silently.
- Every new witness must drive the **real** entry point. The `AgentFirstPaintChecks`
  failure above is the canonical counterexample: synthetic snapshots passed while
  production regressed.
- Assert counts and ordering, not wall-clock.
- Every new themed view: declare `TokenThemed`, register in
  `tokenAdoptedOwners` with a ticket comment, paint in both an appearance-sweep
  surface and an adopted surface in both `.aqua` and `.darkAqua`, and paint
  `nil` at rest — never `.clear`.
- `performance.md` is binding: bounded view count per row, no measurement in
  `layout()`, no unconditional frame assignment, no self-sizing during own
  layout, test `.legacy` scrollers, visible notice on any truncation.
- Look at it. A slice is not done until it has been seen against the fixture
  gallery and the live tile.

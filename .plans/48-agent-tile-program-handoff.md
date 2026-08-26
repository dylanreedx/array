# 48 — Agent tile: transcript, UX, and native harness capabilities

> **SUPERSEDED IN PART, 2026-08-24 (same day).** The program in this file was
> then executed. **`.plans/46` is the current record** — read its "M0–M2
> landings", "M4–M6 landings", "Probes" and "Codex" sections before acting on
> anything below.
>
> What this file still gets right: §4's harness capability survey, §7's
> verification doctrine, §8's traps. What it gets wrong, corrected by
> measurement rather than by argument:
>
> - **§5's delta budget is history.** The nine per-delta history walks are gone;
>   50.202 ms → 5.749 ms, and the leg is off `MATRIX_KNOWN_RED`.
> - **§4.2's pi data-loss story was too broad.** Persistence is gated by an
>   assistant-message watermark shared by json and rpc, so the exposure is the
>   first turn of a new session, not every stop.
> - **§4.3's codex risk was wrong in both directions.** #33267 does not
>   reproduce here and delegation genuinely works — and `exec --json` still
>   cannot see any of it, measured with the child's file write confirmed on disk
>   and absent from the stream. `SubAgentActivityKind` has no `completed`;
>   `multiAgentMode` is `explicitRequestOnly | proactive | {custom}`, not `"v2"`.
> - **B7.0 was sharper than described.** `/clear` alone is accidentally safe; a
>   command with ARGUMENTS named the tile after its arguments.
> - **One item did not reproduce at all**: `ChoiceListView`'s swallowed bare
>   Enter. Its init already falls back to the first enabled item.


**The single handoff for finishing the agent tile.** Written 2026-08-24 at
`5cba885d` on `array/transcript-ux`, after a session that shipped the transcript
redo, reviewed it live with Dylan three times, and then planned everything that
remains.

Read this file, then `~/.claude/plans/plans-45-transcript-program-handoff-pro-reactive-otter.md`
(the approved program plan, milestones M0–M9). This file is the *state and the
evidence*; that file is the *sequence*. `.plans/46` is the running ledger —
append one section per landing, in the same commit as the landing.

Dylan's standing instruction for the next session, verbatim:

> "i want to tackle the entire thing... if it takes a 3 hour long entire session
> do it! ... delegate sonnet 5 medium agents to tackle well established tasks"

and

> "I SAID NOT TO STOP UNTIL WE ARE DONE"

**Do not stop to ask between milestones.** Decisions that were genuinely his have
already been taken and are recorded in §2. Everything else is an engineering
call — make it, witness it, and record it in `.plans/46`.

---

## 0. How to run the next session

The shape that works here, measured from this project's own longest session
(`4fda3dc5`: 5.5h unbroken, 24.1h active, 27MB, 1,559 Bash + 547 Edit calls):

- **Hold the plan in a task list.** That session used 30 `TaskCreate` and 53
  `TaskUpdate` calls. Structure that survives hours has to live outside the
  context window.
- **Delegate well-established tickets whole**, not just research. That session
  delegated 15 agents including *"Implement transcript rehydration"* and
  *"Implement codex backend and toggle"*. Give a sonnet agent a ticket with: the
  exact files and line cites from this document, the witness it must write, the
  RED reason, the teeth, and the legs to run. Keep the main loop for the work
  that needs the whole picture — the hot transcript path, anything touching the
  gates.
- **Do the ordinary edits yourself.** Bash and Edit dominated that session; the
  agents were for breadth, not for avoiding work.
- **Never leave the worktree dirty across a compaction.** Commit WIP with an
  honest message that says what is unfinished, like `5cba885d` does.

### The build and preview setup (already provisioned)

```
worktree   ~/array-worktrees/transcript-ux    branch array/transcript-ux
app        ~/Desktop/Array Transcript.app     dev channel
project    ~/array-transcript-verify
store      ~/array-transcript-verify-store
```

Rebuild and relaunch:

```sh
cd ~/array-worktrees/transcript-ux
DEV_APP_PATH="$HOME/Desktop/Array Transcript.app" \
DEV_PROJECT_ROOT="$HOME/array-transcript-verify" \
./scripts/dev-app.sh --env CONTINUUM_APP_SUPPORT="$HOME/array-transcript-verify-store"
```

`/Applications/Array.app` is Dylan's workspace on `~/Documents/personal`. Never
rebuild it, never quit it, never point anything at its root. `ThirdParty/` is
gitignored, so a fresh worktree needs `./scripts/prepare-ghosttykit.sh` once.

**Verify a launch AFTER the tool call returns** (`pgrep -lf "Array Transcript.app"`),
because `open --env` detaches and a direct exec dies with the agent's shell.

---

## 1. Where the tree is

Branch `array/transcript-ux` in the worktree; `array/integration` in the main
checkout is at `e8a49cf2`. Nothing is pushed to `main`. No release is cut.

| commit | what |
|---|---|
| `09de0b0` | 0.5.10 — the release before all of this |
| `bbc3d086` | S1–S3 real tool-detail supply |
| `0105c3cf` | S4.0–4.2 turn corrections + action-first row |
| `c2ceb9dd` | S4.3 clustering |
| `58336c09` | S5+S6 honest status, live feel |
| `b6dca039` | S7 gallery builder |
| `3a4ac2c5` | gallery iteration 2 fixes |
| `8a814cb0` | expanded thoughts render; one text column |
| `dc4a44ac` | tool queries for any tool; real reasoning durations |
| `8a42d708` | stability pass — the flicker's four real causes |
| `e8a49cf2` | motion + clickable reply options |
| `d410ebbe` | ledger: the delta-budget bisect |
| `5cba885d` | **RED count witness for the delta path; fix NOT written** |

---

## 2. Decisions Dylan has already made — do not re-litigate

1. **User message loses its card.** Drop the fill, keep a ~2pt rule down the left
   edge. He chose this from previews.
2. **The rule is a new grey `AgentLineRole.authorship`** resolving to the
   existing `LineToken.border`. He picked it over blue `accentWorking` and over
   a lighter card.
3. **Persistence gets fixed properly, first** — one agent-stable key, a migration
   for existing on-disk transcripts, and persistence that does not require a
   tile.
4. **All three harnesses** — claude, pi and codex. Not two.
5. **Plan everything up front**, then implement without stopping.
6. Reply-option chips fill the composer and **do not send**. Shipped.

Open, and genuinely his when it arrives: whether to spend a codex `app-server`
transport rewrite (see §4.3). Everything else is yours.

---

## 3. What shipped in the transcript redo

The milestone Dylan rejected on sight (`6926044b`) was replaced by S1–S7. What
the tile does now that it did not before:

**Real supply.** All three translators emit `.toolDetail` observations over the
host-local `AgentRuntimeObservation` channel into `AgentToolDetailStore`. Tool
rows show the actual query, pattern, url, file basename or description. The
whitelist is **key-driven, not tool-driven** — that is why it survived claude
renaming `Task` to `Agent`.

**Action-first rows.** One 28pt line: icon, "Searched for …", and a reserved
trailing column reading `2.1s ✓`. Tool name lives in the icon, tooltip and AX
label. Settled rows take `Opacity.receded`; failures never recede.

**Clustering.** Consecutive settled tool rows fold behind one synthetic header
("6 steps · 5 searches, 1 fetch · 12.4s ✓") via a display projection between
`rows` and the diffable snapshot. `rows == flatten(document)` is untouched.
Failures never fold. A live run folds only the members before the first live one,
and only at threshold 3.

**Honest status.** `AgentTranscriptProjection.turnCompleted` sweeps every still-
active item with an outcome-mapped status instead of discarding the outcome.
Nothing says "In progress" forever any more.

**Live feel.** The optimistic send indicator survives the next synchronize;
"Thought for Ns"; "Worked for 27s" / "You stopped after 27s" on settle.

**Stability.** Four real causes of the flicker Dylan reported, none of them
missing animation — most importantly that the live fold triggered at one
completed row, so a row was deleted under the reader on every tool call.

**Motion.** `AgentTranscriptMotion` — presentation-only `CABasicAnimation`s
ending on the value the model already holds, off unless the interactive launch
path turns them on, so every pixel baseline still photographs a settled frame.

**Reply options.** `AgentReplyOptionDetector` reads a settled assistant turn's
trailing question-plus-list and the composer offers the choices as chips.
Structure-based, deliberately narrow, and it never sends.

### Lessons this milestone paid for

- **Green legs were insufficient at every stage.** Three defects were found only
  by opening a rendered PNG (clipped diff counts, echoed query lines, misaligned
  rows), one by instrumenting geometry (0×0 hosts), one by Dylan driving the real
  app (the nil live clock), and one by a pre-existing check catching a crude fix.
- **A fixture captured with the wrong argv witnesses a stream production never
  sees.** The first capture lacked `--include-partial-messages` and had no
  reasoning or prose at all.
- **A witness that asserts source text stays green while the behaviour inverts.**
- **`AgentBlockHostView` constrains its own subview**, so frame-placing it lets
  Auto Layout solve it to 0×0 keeping the origin. Frames like `(0, y, 0, 0)` mean
  the engine, not your arithmetic.

---

## 4. Native harness capabilities — the complete picture

This is the section that changes the most decisions, and most of it was
established *today* by probing the installed CLIs and reading upstream source.
Where an older plan document disagrees, this is right and it is stale.

**Installed versions on this machine:** claude **2.1.241**, pi **0.84.1**,
codex-cli **0.148.0** (newest published 0.149.1, tagged 2026-08-24).

### 4.0 What Array uses today, and what it leaves on the table

Every harness is run as a **one-shot process per turn**. That single fact causes
both of Dylan's steering complaints:

| | claude | pi | codex |
|---|---|---|---|
| Array runs | `claude -p --output-format stream-json --verbose --include-partial-messages`, prompt as **argv**, stdin `.inherit` | `pi -p --mode json --model … --thinking …`, stdin `.inherit` | `codex exec --json --skip-git-repo-check -c approval_policy=never -c sandbox_mode=… -m …`, stdin **`/dev/null`** |
| the mode that has steering | `--input-format stream-json` (stdin framing) | `--mode rpc` | `app-server` |
| interrupt | `control_request{interrupt}`, ~1 ms, acknowledged | `abort()` | `turn/interrupt` |
| mid-turn steer | **no** — a second stdin message is a QUEUE | **yes** — `steer()` | `turn/steer` |
| queue | yes, drains after an interrupt | yes — `follow_up()` | `thread/inject_items` |

`ProcessGroupChild` already supports piped stdin and exposes the write handle
(`:55-57, 69, 90-106, 204`) — that plumbing landed with M1.8, so claude's
migration needs no new process work.

### 4.1 claude — subagents are fully observable, and Array drops every frame

**The mechanism, confirmed by Anthropic's own docs** (`code.claude.com/docs/en/headless`,
"Follow subagent messages"):

> Messages from subagents appear in the stream as `assistant` and `user` messages
> whose `parent_tool_use_id` field is the ID of the tool call that spawned the
> subagent. Messages from the main conversation carry `null` in that field.

- **By default the stream carries the subagent's `tool_use` and `tool_result`
  blocks.** So Array *already receives* what a subagent did — and throws it away
  at `ClaudeEventTranslator.isSubagentFrame` (`:118-121`), used at `:92`
  (stream_event deltas), `:96` (assistant tool_use), `:100` (user tool_result).
  `case "result"` at `:102` is **not** filtered.
- **`--forward-subagent-text` is real and is in the installed binary.**
  `claude --help` on 2.1.241 lists `--forward-subagent-text  Forward subagent
  text and thinking`. Env twin `CLAUDE_CODE_FORWARD_SUBAGENT_TEXT`. Requires
  v2.1.211+. It adds the subagent's text and thinking blocks "so you can
  reconstruct each subagent's transcript". **An earlier plan proposed cutting
  this as a fabrication. That was wrong** — it is how a child transcript gets its
  prose.
- **Nesting is rebuildable at every depth.** A nested subagent's messages carry
  the id of the Agent tool call that spawned it, so following the ids rebuilds
  the tree. Requires v2.1.219+.
- **The tool is `Agent`, formerly `Task`.** Input: `subagent_type` (required),
  `prompt`, `model`, `isolation: "worktree"`. Array's key-driven whitelist
  (`toolDetailFields:337-364`) is why the rename did not break detection — but it
  carries only `description`, so `subagent_type` is dropped today. Add it (a role
  id, publishable). **Never add `prompt`** — a model-authored command body.
- **`itemKind(forTool:):438-447`** sends `Agent`/`Task` to `.commandExecution`
  through `default:`. It is not a command execution.
- **Depth is controllable by Array.** Default 3 below the main conversation;
  `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` on the child environment makes the
  `Agent` tool be **withheld** at the limit. Better than refusing after the fact —
  the model never proposes what it cannot have.
- **Roles live in `.claude/agents/*.md`** with frontmatter `name`, `description`,
  `tools`, `disallowedTools`, `model`, `permissionMode`, `maxTurns`, `skills`,
  `mcpServers`, `hooks`, `memory`, `background`, `effort`, `isolation`, `color`,
  `initialPrompt`. Also `--agents <json>` to inject for one session.
- **`system/init` arrives PER TURN** and carries `slash_commands`, `skills`,
  `agents`, and a `capabilities` array (e.g. `interrupt_receipt_v1`,
  `interrupt_cancel_queued_v1`). **Feature-detect from that array, do not compare
  version strings.** Array reads this line and discards all of it.
- **A clean interrupt still reports `is_error: true`** (probe-captured in
  `.plans/probes/45-steering/claude-control-interrupt.jsonl`), so
  `ClaudeEventTranslator.swift:255`'s `isError ? .failed : .completed` would map a
  clean protocol interrupt to a failure. The CLI authors `[Request interrupted by
  user]` as a **user** message — render it as harness-authored, not as the user's
  words. `still_queued: []` came back while the queued message ran afterwards, so
  **interrupt cancels the turn, not the queue.**
- **Signals:** SIGTERM on `claude -p` exits 143 and records **no result** for the
  in-flight turn; **SIGINT ends the turn**; resuming continues the unfinished
  one. Array currently sends SIGTERM via `terminateGroup`.
- `--bare` skips discovery of hooks, skills, commands, subagents, plugins, MCP,
  memory and CLAUDE.md — relevant if Array ever wants reproducible child runs.

**There is no committed claude subagent capture in the repo.** The websearch
fixture's 56 `parent_tool_use_id` values are all null; the three steering probes
have zero; the only non-null instance is a synthetic literal at
`ClaudeAgentBackendChecks.swift:38`. **Capturing one is the first ticket of the
subagent work.**

### 4.2 pi — the most capable harness, and Array uses none of it

- `PiAgentRunner.observeSpawnRequests:312-314` is **real**;
  `PiEventTranslator:43/:101-112` parses `spawn_agent` out of
  `tool_execution_start` into a `SpawnRequest`; `AgentSupervisor:2053-2055` wires
  it per turn; `handleSpawnRequest:2268-2332` does caps, role resolution, spawn,
  and emits `.childAgentSpawned`. **The detection path is complete.**
- It is unreachable for **four independent reasons**, and fixing three of them
  ships nothing:
  1. `Resources/PiExtensions/continuum-spawn-agent.ts` **is committed** (2,218 B)
     but `Package.swift` has zero `Resources` references, so it is not bundled.
  2. No installer exists anywhere in `scripts/`; it is not in
     `~/.pi/agent/extensions/`.
  3. `PiAgentRunner.processArguments:59-65` never passes `-e`.
  4. **All twelve `.pi/agents/*.md` roles declare a `tools:` allowlist and none
     lists `spawn_agent`** — so it is denied for every roled agent even once
     loaded. Fix in `RoleRegistry.toolsArguments`, not by hand-editing twelve
     files that must then track a code-level cap.
- **`--mode rpc`** (not JSON-RPC). Commands are JSON lines
  `{id?, type: "prompt"|"steer"|"follow_up"|"abort"|…}`; replies are
  `{id?, type:"response", command, success, data?}`. 32 commands including
  `abort abort_bash abort_retry bash clone compact cycle_model follow_up fork
  get_commands get_session_stats get_state new_session prompt set_auto_compaction
  set_steering_mode steer switch_session`.
- **The event stream is byte-identical to json mode.** `dist/modes/rpc/rpc-mode.js:265-266`
  publishes through the same `toJsonEvent`. **`PiEventTranslator` survives the
  migration untouched** — this is why pi goes first, not claude.
- `steer(text)` is genuine mid-turn steering ("delivered after the current
  assistant turn finishes executing its tool calls, before the next LLM call").
  `followUp(text)` is a queue. `abort()` is clean and awaited — no signal, no
  lost session file.
- `RpcSessionState` carries `isStreaming`, `isCompacting`, `pendingMessageCount`,
  `steeringMode`, `followUpMode`, `sessionFile`, `sessionId`.
- **rpc installs SIGTERM/SIGHUP handlers** (`rpc-mode.js:274-287`) that one-shot
  mode does not, so it plausibly persists its session even when signalled. Probe
  this; the answer decides whether the interim warning below can be deleted.

**The live data-loss bug.** Measured 2026-08-22: SIGINT → exit 130, SIGTERM →
exit 143, **both with 0 bytes of stdout and no session file written**. The
session directory is created and left empty; a rerun with the same
`--session-id` reports no session found and starts fresh. **So stopping pi
silently discards the whole conversation** — and M1.7 made that quieter by
replacing the error row with a clean "Interrupted". Until rpc lands, say it out
loud in the transcript at the moment of loss.

### 4.3 codex — subagents ship, but not on the transport Array uses

This is the most-corrected item in the whole program. Two earlier conclusions
were both wrong; here is the settled version.

**Multi-agent is real and finished.** `codex features list` on this machine:

```
multi_agent        stable   true
multi_agent_v2     stable   false
```

`stable` is the maturity; `false` is the default. Enabling V2 exposes
`spawn_agent`, `send_message`, `followup_task`, `wait_agent`, `list_agents`,
`close_agent` (and `interrupt_agent` in some builds). Enable per-invocation with
`-c features.multi_agent_v2=true` — **never** by writing the user's
`~/.codex/config.toml`. `CodexAgentRunner`'s argv builder (`:118-135`) already
passes three `-c` overrides, so that part is one line.

**Our original probe was invalid.** It configured `[agents.reader]` and concluded
spawn was unavailable. In `spec_plan.rs`, agent roles only control
`expose_agent_type` — whether the `agent_type` *parameter* appears on an
already-registered tool. Tool registration is gated solely by
`collab_tools_enabled`. Declaring a role **cannot** cause the tool to be offered.

**But `codex exec --json` cannot see subagent work at all.**
`codex-rs/exec/src/exec_events.rs::ThreadItemDetails` is a **closed enum**:
`AgentMessage | Reasoning | CommandExecution | FileChange | McpToolCall |
CollabToolCall | WebSearch | TodoList | Error`. No `SubAgentActivity` variant, no
variant carrying child-thread items. Therefore:

- Under **V2**, subagent activity is emitted as
  `SubAgentActivity{kind, agentThreadId, agentPath}` and the exec mapper **drops
  it**. Setting the flag gives Array nothing.
- Under **V1** (already on), `collab_tool_call` gives delegation metadata only —
  `{tool, sender_thread_id, receiver_thread_ids, prompt, agents_states, status}`.
  Never the child's tool calls, commands, diffs or output. Its exec projection is
  also lossy: `CollabAgentTool::ResumeAgent => CollabTool::Wait`.
  `receiver_thread_ids: []` and `agents_states: {}` — what our probe saw — is the
  *correct* shape for a `wait` with no live agents.
- **Headless V2 is a known hard failure.** Issue #33267 (2026-07-15, open, no
  maintainer reply): `codex exec` + `multi_agent_v2` → *"Encrypted function output
  content could not be decrypted or decoded"*, 100% reproducible; TUI and Desktop
  fine.
- Two further gates: the model catalogue's own `multi_agent_version` can force
  V1/Disabled independent of flags, and there is an undocumented account gate —
  first-party multi-agent works on ChatGPT-authenticated providers and not on
  API-key `model_providers` (#37858, #37859).

**Real observability exists only on `app-server`**, and it is better supported
than "[experimental]" suggests: a ~1700-line README, official Python
(`pip install openai-codex`) and TypeScript SDKs, and three first-party consumers
— the VS Code extension (`clientInfo: {"name": "codex_vscode"}`), the TUI itself,
and 0.149.0's new daemon-backed `codex agents` dashboard.

What it offers: `subAgentActivity` items (`kind ∈ started|interacted|interrupted|completed`,
with `agentThreadId`, `agentPath`); `thread/list` filtered by
`sourceKinds: ["subAgentThreadSpawn"]` with `parentThreadId`/`ancestorThreadId`;
`thread/read` with `includeTurns` for a child's full transcript; plus
`turn/steer` and `turn/interrupt` for Program B.

Constraints to design around, all from the app-server test suite:

- On a V2 child, `turn/start`, `turn/steer`, `thread/inject_items`,
  `thread/settings/update`, `thread/goal/set|clear`, `thread/compact/start`,
  `thread/rollback`, `review/start` and `mcpServer/tool/call` are **rejected**
  with `-32600 direct app-server input is not allowed for multi-agent v2
  sub-agents`. Allowed: `turn/interrupt`, `thread/read`, `thread/list`,
  `thread/goal/get`.
- **A child's `item/completed` is attributed to the parent turn that spawned it
  and may arrive AFTER that turn's `turn/completed`.** A host must not close the
  turn on `turn/completed`.
- `turn/steer` needs `expectedTurnId`, from `turn/start`'s response or the
  `turn/started` notification.
- `thread/archive`/`thread/delete` cascade to spawned descendants; `SessionEnd`
  hooks run only for root threads.
- Roles: `[agents.<name>]` in config.toml accepts **only** `description`,
  `config_file`, `nickname_candidates` (unknown keys are a config error), plus
  auto-discovery from `~/.codex/agents/` and `.codex/agents/`. Role files are
  **TOML** with `name`, `description`, `developer_instructions` (a third-party
  guide claiming Markdown is wrong). `agent_max_depth` defaults to 3.

**So the codex decision is:** adopting subagents means migrating
`CodexAgentRunner` from `exec --json` to `app-server`. That is a transport
rewrite — and it is the *same* rewrite that brings `turn/steer` and
`turn/interrupt`. It is the one open question for Dylan. The recommended shape is
to migrate the **single-agent** path first (app-server is a strict superset of
`exec` capability) and keep subagents behind a flag until #33267 closes and the
account gate is confirmed.

### 4.4 The convergence worth building on

All three declare roles the same way, and Array already parses one of them:

| | claude | pi | codex |
|---|---|---|---|
| roles | `.claude/agents/*.md` | `.pi/agents/*.md` | `.codex/agents/*.{md,toml}` |
| spawn verb | `Agent` (ex-`Task`) | `spawn_agent` | `spawn_agent` |
| spawn args | `subagent_type`, `prompt`, `model`, `isolation` | `role`, `prompt`, `isolated` | `agent_type`, `task_name`, `message`, `model` |
| worktree isolation | `isolation: "worktree"` | `isolated: true` | inherits parent sandbox |
| depth cap | 3, env-settable | n/a | 3, `agent_max_depth` |

`RoleRegistry` (`Sources/ContinuumRevivedCore/Agents/RoleRegistry.swift`) already
reads `.pi/agents` frontmatter for `name`/`tools`/`model`/`reasoning`. Generalize
it to a per-harness directory: one concept, three roots. `SpawnRequest.role` and
claude's `subagent_type` are the same field.

---

## 5. The delta budget — the finding that reorders the program

**Start the next session here.** This is the only work with a half-written state.

`--perf-budget-transcript-delta-check` has been KNOWN-RED on wall clock for
months while every *count* budget stayed green. Re-measuring it (M0's first item)
found the number had moved the wrong way, and a bisect named the cause exactly.
Debug configuration, isolated worktree, one build per commit, same machine:

| commit | what landed | worst delta @10k rows |
|---|---|---|
| `09de0b0` | before the redo | **36.394 ms** ← reproduces the published number |
| `bbc3d086` | S1–S3 supply | 42.967 (**+6.6**) |
| `0105c3cf` | S4.0–4.2 row | 43.535 (+0.5) |
| `c2ceb9dd` | **S4.3 clustering** | 52.979 (**+9.5**) |
| `8a42d708` | stability pass | 53.994 (+1.0) |
| `e8a49cf2` | motion | 50.202 (**−3.8**) |

Four consecutive runs at HEAD: 50.202 / 50.595 / 50.365 / 51.232 ms — under 2%
spread, so this is deterministic, not host noise. Scaling is linear in history
(0.37 / 0.73 / 4.8 / 50.2 ms at 10 / 100 / 1k / 10k) **despite the row index
reporting 1 node visited per delta.** The index is incremental; the presentation
half is not.

**The reasoning error, recorded so it is not repeated.** S4.3 justified an
O(rows) `rebuildDisplayProjection()` per visual apply on the grounds that "the
scheduler already coalesces 5,000 deltas into one apply". That is true for a
burst and false for slow streaming: 20 deltas are 20 applies and each pays the
full walk. The coalescer bounds the worst case; it does not amortise.

### What is already committed (`5cba885d`)

A **count** witness, because a millisecond threshold on shared hardware
manufactures flakes and "a content-only delta walks history zero times" cannot be
satisfied by a fast machine:

- `AgentTranscriptListView.qaHistoryScanCount` + `recordHistoryScan(_:)`, called
  at each offending pass.
- `PerfScenarios`: `Sample.historyScansPerDelta` and a new budget
  `transcript-delta.worstHistoryScansPerDelta`, limit `.exactly(0)`.
- **Currently RED at 6.**
- `pendingIncrementalRowIDs: Set<AgentNodeID>?` — the rows the incremental index
  actually rebuilt — is wired from `incrementallyIndexed` (both success returns)
  through to `applyUnscrolled`, and cleared by `flatten`. Nil means "structural,
  rebuild everything", so any new decline path stays correct by default.
- The dead `let oldIDs = rows.map(\.id)` (computed, then `_ = oldIDs`) is deleted.
- `--transcript-delta-index-oracle-check` and `--ui-geometry-check` both pass.

**The fix is not written.** The six scans, in `applyUnscrolled` unless noted:

| # | pass | fix |
|---|---|---|
| 1 | reasoning-entry diff (`oldReasoningEntries` + `newReasoningIDs`) | only needed to purge disclosure state for REMOVED reasoning entries; skip entirely when `pendingIncrementalRowIDs != nil` |
| 2 | `rowsByID = Dictionary(...)` rebuild | patch only the changed rows |
| 3 | `rebuildDisplayProjection()` | cache `displayFacts`; patch changed slots (and slot+1 for `startsTurn`); if no fact changed and `turnIsInFlight` is unchanged, skip `plan()` and every map it builds |
| 4 | role-change scan | restrict to the rebuilt rows |
| 5 | `newIDs = rows.map(\.id)` | replace `changedTopLevelIDs.intersection(newIDs)` with a filter on `rowsByID` |
| 6 | `prepareToolDetailLifecycle` (called from `apply`, not `applyUnscrolled`) | builds a dictionary of **whole entries** every apply and then computes block-id sets for every tracked entry. Restrict to `patch.updated` when `patch.inserted/removed/moved` are all empty |

Watch: the projection's facts depend on tool-row **status**, which a content-only
delta can change — that is why facts are patched and compared rather than assumed
stable. And `--transcript-delta-index-oracle-check` asserts the live index is
indistinguishable from a full walk; it must stay green through all six.

**Then:** re-measure, and if the wall clock lands under 8.3 ms remove
`--perf-budget-transcript-delta-check` from `MATRIX_KNOWN_RED` in the same
commit — a listed leg that passes is reported as a stale allowlist.

**Why this comes first:** M3 (inline diffs) adds a parse and a body to this path,
and M6 (subagents) adds up to 16 concurrent child streams. Building either on a
budget 6× over is how the app becomes unusable and subagents get blamed.

---

## 6. The programs, in one page each

Full detail is in the approved plan file. This is the index and the traps.

### Program A — transcript UI closeout

- **A1 user-turn rule.** New `AgentLineRole.authorship` → `LineToken.border`
  (no new token *value*, so `DesignTokenChecks:198-212`'s pinned table does not
  move); new `LineWidth.rule = 2.0`; drawn as a **subview**, not a border (four
  edges) and not a sublayer (invisible to `ownedColorSlots`, which walks views);
  `UserPromptView` becomes `TokenThemed` in the same ticket.
  **Geometry is forced, not chosen:** `AssistantProseRenderer.swift:51` sets
  `horizontalReadingInset == 0`, so the shared text column *is* the row's leading
  edge and there is nowhere inside the row to hang a rule. Rule at
  `bounds.minX`, prose at `+ LineWidth.rule + Space.m` (+10pt), trailing inset 0.
  Seven witnesses to correct, one of which nobody listed:
  `checkUserPromptRenderer:7374-7379`'s height identity breaks once user prose
  measures against a different width than assistant prose.
  `UIProbePixels.fillBandLuminance:542-586` is **dead code** — delete it.
  Amend `_DESIGN.md` §11 in place (hazard 5), which currently says user prompts
  use a quiet fill and restricts strong lines to selection/focus/approval/error.
  Two baselines move; agents may not bless them.
- **A2 before A3.** `AgentDiffSummaryView.rebuildFileLabels()` rebuilds up to 24
  `NSTextField`s per apply and `layout():132-196` runs
  `attributedStringValue.size()` per file row. Fix exactly as 1h.3 did for
  `ToolCallView`. Doing A3 first means doing A2 twice.
- **A3 inline diffs.** Reuse `GitDiffEngine.parse` (`:236`) and
  `DiffReviewTileNSView.render(_:theme:)` (`:317`) — both pure and token-painted.
  One view for the body, not one per line. Cache the parse by
  `(blockID, revision)`. **`AgentBlockMeasureKey` has no indent field** — any
  per-row indent must enter it.
- **A4 turn folding.** Extract `turnRanges(facts:)` as a pure no-op refactor with
  a byte-identical-output witness first; then a second `plan()` pass at turn
  granularity over the same `[Item]` list.
- **A5 live-work row: CUT.** Nine phases over an adapter that still returns
  `.unknown` ships a row that lies. Consolation: elapsed on the existing
  text-only tail label.
- **A6 `TokenThemed`.** Nine left after A1 (`ThematicBreakRenderer:49` and
  `TableRenderer:52` already conform — the ledger is stale). Audit which appear
  in `appearance.managedAgentTile` **before** conforming any, or
  `declaredConformers()` reds for a conformer never swept.

### Program B — steering and commands

- **Done already (M1.7/M1.8):** `stopRequested` before every throw on all three
  runners, `AgentRunStopped`, supervisor produces `.interrupted`,
  process-group terminate with escalation, `AgentStopOutcomeChecks.swift`.
- **B2.1 split turn state from runner binding** — `AgentTurnPhase` in
  `TurnFacts`. Today `occupied = runners[id] != nil` (`:3285`), so a
  session-lifetime runner would make `canSend` false forever. Bit-identical for
  one-shot runners. **Both migrations need it; do it under pi so claude inherits
  it working.**
- **B2.2 `AgentSessionRunning: AgentRunning`** refinement — do not widen
  `AgentRunning`. **Capabilities come from the bound runner, never from
  `record.harness`**, which lies for the whole migration window.
- **B3 order: pi, then claude, codex last/open.** pi's translator survives
  untouched; claude's "cheap flag" forces a translator change.
- **B4 Array owns the queue.** Neither claude nor pi exposes a cancel-queue verb,
  so write-ahead makes "cancel what I queued" unimplementable. Reverse the
  prohibition comment at `:1980-1987` *in the same commit*, with the reason.
  **The UI is not already built** — `secondaryActions` has zero consumers outside
  its own file; there is real work in a secondary-affordance row and pending
  chips. Ship the attachment bug fix first (`AgentComposerView.swift:623-628`).
- **B5 commands, three tiers.** Probe first whether `claude -p` interprets a
  leading slash — it decides whether "disable with a reason" is an improvement or
  a regression. Tier A replies via `AgentTranscriptProjection.appendNotice`
  (`:370-406`) — no new event, no I5 pressure.
- **B6 compaction.** Occupancy from `post_tokens` first, alone. Then the block
  kind — and **`ItemKind` is `String`-raw Codable with a synthesized decoder
  (`AgentStatusEngine.swift:223-232`), so an unknown case throws.** Make it
  lenient in the same ticket or it is a data-loss bug in a one-line diff.
- **B7 `/clear`.** Ship the naming trap alone today (a command invocation must
  never feed the naming funnel). Then store `AgentRecord.providerSessionId`
  instead of deriving; `claude --help` confirms `--fork-session` exists and
  invents an id Array cannot predict.

### Program C — subagents

- **C0 the nesting decision.** Nesting is **already solved** for owned children:
  `childAgentSpawned` is an `AgentRuntimeEvent` and `agentReference` is a durable
  block that persists and syncs. The question only bit for claude's `Agent`
  subagents, and the answer is **mint a real read-only `AgentRecord`** with a
  deterministic `AgentID` from `(parentAgentID, tool_use_id)` and
  `capabilities: .observedReadOnly`. Feasible: `makeAgent(id:...)` (`:1589`) takes
  an explicit id and only sends when a prompt is supplied.
  **Never widen `AgentRuntimeEvent`** — it buys something already owned.
- **C1 capture** a real claude subagent stream with `--forward-subagent-text`.
  Gates C7.
- **C2 two `fanOut` bugs** — `harness:` (`:2544`) never forwarded to `spawn`
  (`:2569-2579`), and `fanOut` never emits `.childAgentSpawned` so fan-out
  children get parentage but no chip. Small, no decisions, proves the chip
  pipeline. Do it first.
- **C3 re-key persistence + migrate.** Writer is the tile's `threadId`
  (`"managed-<tileId>"`, `TileSpawner.swift:1492`); the only reader hardcodes
  `"thread-main"` (`ContinuumApp.swift:8452-8459`). Worse, the key is per-**tile**,
  so `spawnManagedAgentForExistingAgent:1665-1670` orphans the directory on every
  reveal. Adopt `AgentSupervisor.sessionId(for:)` (`:1022-1024`).
- **C4 persist without a tile** — the sole `saveSnapshot` call site is inside
  `wireManagedAgentTile`, and at 16 children tile-less is the common case.
- **C5 `AgentCapabilities` becomes load-bearing** — its first real use. Gate the
  composer and Stop for `.observedReadOnly`.
- **C6 scale the delta path before C7.** See §5.
- **C7 claude supply**, **C8 pi installation** (all four parts or nothing),
  **C9 codex** (see §4.3), **C10 chip live status** (resolve at render time;
  assert the `AgentDocument` bytes are byte-identical before and after — that is
  the teeth on "status never rewrites history"), **C11 lineage at N>1 edges**
  (extend `--relationship-geometry-check`, which **does** exist contrary to
  `.plans/43`), **C12 refusal honesty**.
- **Scale is four numbers:** depth 2 × 4 children × fan-out 4 = **16** live
  streams; `boundedForInbox` caps at 8 visible children, which 4+4 saturates
  exactly; the lineage overlay is one edge; the delta budget is 6× over.
  **The rule: the parent transcript is an index, not a mirror.**

---

## 7. Verification — non-negotiable

- **RED first, for the real reason. Teeth-verify by reverting the fix.** A
  witness must drive the PRODUCTION entry point; one that re-derives what
  production derives passes while production is broken.
- **Never assert that source contains a string.** That has already let a reviewer
  invert the exact behaviour a check claimed to guard.
- **The gating transcript leg is `--transcript-rhythm-check`.**
  `--component-lab-check` and `--ui-baseline-check` are both KNOWN-RED, so
  assertions added there read as coverage and never run.
- **Prefer counts to milliseconds.** §5 is the cautionary tale in both
  directions: the wall clock was red for months and told nobody anything; the
  count found the regression in one run.
- **A new matrix leg costs five coupled edits:** check fn + flag dispatch in
  `ContinuumApp.swift`; a `run_app_check` line in `scripts/run-matrix.sh`;
  optionally a `MATRIX_KNOWN_RED` entry while red; regenerate
  `docs/38-tickets/90-agent-ux/matrix-inventory.txt` with
  `CONTINUUM_UPDATE_MATRIX_INVENTORY=1 ./scripts/run-matrix.sh`; and the `count`
  floor if it lives in a `*Checks/main.swift`. Two program checks pin lines of
  `run-matrix.sh` verbatim with `grep -Fxc`.
- **Remove your own KNOWN-RED entry in the commit that makes the leg green.**
- **Full matrix per milestone**, judged by its end-of-run summary, **with the
  display awake** — the 02:30 run's five terminal failures bisected to an asleep
  display, not to the milestone.
- **`CONTINUUM_UPDATE_BASELINES=1` is forbidden.** State which baselines move and
  the measured differing fraction; hand the supervised Retina-Main bless to
  Dylan.
- **A ticket is not done until the behaviour has been seen on live data.** Every
  visual defect in the last milestone was found that way and none by a leg.

## 8. Traps that have already cost time here

1. `AgentBlockHostView` constrains its own subview — place it with constraints,
   never frames.
2. A capture taken with the wrong argv witnesses a stream production never sees.
3. `grep -q` on a piped process under `set -o pipefail` kills the producer.
4. Guessing a `--*-check` flag boots the full app and hangs the shell. Enumerate:
   `grep -oE '\-\-[a-z0-9-]+-check' Sources/ContinuumRevived/App/ContinuumApp.swift | sort -u`
5. Never run tmux, CoreChecks real-tmux coverage, or an app tmux self-check
   against the default socket while Array may be running.
6. Two installs on one project root share `<root>/.array/` and the last writer
   wins. Give each install its own root.
7. Probe hygiene: throwaway `/tmp` dirs only, never inside the repo, never modify
   `~/.codex/config.toml`, `~/.claude/settings.json`, `~/.pi/agent/settings.json`.
   Scrub paths, session ids, cwd and tool lists before committing a capture.
8. `.plans/46`'s Slice 1c–1h status table is **stale** — 1c.1, 1c.3–1c.6, 1c.8
   and 1c.9 all landed. Fix it in the first commit, because a stale table is how
   work gets done twice.

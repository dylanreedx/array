# Agent State Readers — grounded spec (Claude Code · Codex · Pi)

**Design spike, 2026-06-30.** Implements Decision **C** of
`docs/38-agent-orchestration-architecture.md` ("observe uniformly, detect not declare").
This is a spec for implementing agents; it does **not** modify repo code. All on-disk
facts below were verified by direct inspection of the author's real `~/.claude`,
`~/.codex`, `~/.pi` on 2026-06-30 (schema only — no message bodies were read or stored).

Legend for confidence: **[VERIFIED]** = read off this machine's disk / repo source;
**[WEB]** = from public docs (cited, dated); **[GUESS]** = inference, flagged as such and
gated behind golden fixtures (I6).

---

## Goal

Populate the **existing** `AgentDescriptor.status` (`AgentStatus` enum:
`configuring | working | idle | needsAttention | done | stale`,
`Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:85`) for each terminal
tile, by reading each agent's **own** on-disk session/run store — never by scraping
terminal output. Three thin `AgentStateReader`s (Claude, Codex, Pi) each:

```
detect(processName)        -> Bool        // from tmux pane_current_command
locate(pid, cwd, runId?)   -> URL?        // the agent's own session/run store
read(URL)                  -> AgentSnapshot   // {status, title?, mode?, asOf, detail?}
```

A per-project `SessionObserver` (lives in `ZoneRuntimeController`) runs detection,
drives the matching reader, maps to `AgentStatus`, and writes
`AgentDescriptor.status` — the field the whole UI (`SidebarTreeBuilder`,
`CanvasNSView` rollup) already consumes. The readers are the **source** the design
calls "missing" (`docs/38` §"The gap").

**The one hard invariant (I5):** readers extract metadata only — event *type*, mode,
title, timestamps, status enums — and **never** message bodies, prompts, tool inputs,
or code. See [Privacy spec](#privacy-spec).

**Existing scaffolding to reuse (don't reinvent):** the repo already ships
`RunArtifactsWatcher` (`Sources/ContinuumRevivedCore/RunArtifactsWatcher.swift`) — a
debounced, rate-limited (`maxReadsPerSecond`, `debounceInterval`) directory watcher
keyed by **runId**, with `RunArtifactsReader.read(runDirectory:)`. It already implements
the "watch the file, debounce, budget reads" pattern §C prescribes; the Pi reader is
largely a generalization of it, and the watch discipline transfers to Claude/Codex.

---

## Claude reader

### Store & structure [VERIFIED]

```
~/.claude/
  sessions/<pid>.json            # process-id-keyed liveness + pid→sessionId link  (mode 0700 dir)
  projects/<encode(cwd)>/<sessionId>.jsonl   # the per-session event stream (append-only)  (mode 0600 files)
  settings.json                  # carries a `hooks` block (push option; see Push)
```

- `~/.claude/projects/` contains one directory per project cwd, named by the
  `encode(cwd)` transform. **`encode(cwd)` = replace every `/` and `.` with `-`.**
  [VERIFIED] — this repo's dir is `-Users-dylan-Documents-personal-continuum-revived`
  (leading `/` → leading `-`); a worktree path containing `/.claude/worktrees/...`
  appears as `...-ms--claude-worktrees-...` — the **double dash** is `/` + `.` both
  mapping to `-`, which confirms the `.`→`-` rule directly.
- Each `<sessionId>.jsonl` is the append-only event log; its filename stem is the
  session UUID. (This very session's stream is
  `…/-Users-dylan-Documents-personal-continuum-revived/0228e334-….jsonl`.)
- Sibling per-session subdirectories (e.g. `<sessionId>/`) and a `memory/` dir exist;
  ignore them for status.

### Linkage: pane → session [VERIFIED — this is the clean, exact link]

`~/.claude/sessions/<pid>.json` is keyed by **process id** (filenames observed:
`38649.json`, `59991.json`, `70921.json`) and its JSON carries **both** `pid` and
`sessionId`:

`sessions/<pid>.json` keys [VERIFIED]: `pid`(number), `sessionId`(string), `cwd`(string),
`startedAt`(number), `procStart`(string), `version`(string), `peerProtocol`(number),
`kind`(string), `entrypoint`(string), `status`(string), `updatedAt`(number),
`statusUpdatedAt`(number), `name`(string|null).

So the link is exact and collision-free:

```
tmux pane pid  →  ~/.claude/sessions/<pid>.json  →  .sessionId  +  .cwd
               →  ~/.claude/projects/<encode(.cwd)>/<sessionId>.jsonl   (event stream)
```

No cwd-guessing is needed because the pid file gives you the sessionId directly. Use
`.cwd` from the pid file (not the tmux pane cwd) to build the `encode(cwd)` directory
name, so OSC-7 drift can't desync the path.

**Two status sources, ranked:**
1. **`sessions/<pid>.json` `.status` + `.statusUpdatedAt`** — cheapest; a single small
   file the CLI maintains. Observed `.status` values **[VERIFIED]**: `busy`, `idle`.
   (Enum likely larger; treat unknown values as `idle`/unknown, never `working`.)
2. **The `<sessionId>.jsonl` tail** — richer (mode, title, tool-loop state). Read this
   for `needsAttention`/`done`/title; fall back to it when the pid file's status is
   coarse.

### Event-stream schema [VERIFIED]

Distinct top-level `type` values across this repo's Claude streams (counts from a
~6 MB stream):

| `type` | meaning (metadata only) | status relevance |
|---|---|---|
| `assistant` | model turn; carries `.message.stop_reason` ∈ {`end_turn`,`tool_use`} | **primary working/idle signal** |
| `user` | user turn **or** tool result (`toolUseResult` key present, `.message.content[].type == "tool_result"`) | tool-loop progress |
| `permission-mode` | `.permissionMode` ∈ {`bypassPermissions`, …} | mode field |
| `mode` | `.mode` ∈ {`normal`, …} | mode field |
| `ai-title` | `.aiTitle` (string) | **title source** |
| `agent-name` | agent name breadcrumb | label fallback |
| `last-prompt` | bookkeeping | — |
| `attachment` | attachment bookkeeping | — |
| `system` | `.subtype` ∈ {`turn_duration`,`away_summary`} (turn_duration carries `durationMs`,`messageCount`,`pendingBackgroundAgentCount`) | turn-boundary signal |
| `file-history-snapshot` | editor snapshot bookkeeping | — |
| `queue-operation` | queued-prompt bookkeeping | — |

Key sub-shapes [VERIFIED]:
- `assistant` → `.message` keys: `content, diagnostics, id, model, role, stop_details,`
  `stop_reason, stop_sequence, type, usage`. `.message.content[].type` ∈
  {`text`, `thinking`, `tool_use`}. **`.message.stop_reason` ∈ {`end_turn`,`tool_use`}.**
- `user` (tool result variant) has top-level `toolUseResult` + `sourceToolAssistantUUID`;
  `.message.content[].type == "tool_result"`.
- `user` (typed prompt variant) has `permissionMode` (`bypassPermissions`) +
  `promptSource` (`typed`) + `origin`.
- `ai-title` keys: `{aiTitle, sessionId, type}`.
- Most events carry `timestamp` (ISO-8601 string); control events (`mode`,
  `permission-mode`, `ai-title`, the `leafUuid` summary line) **lack** `timestamp` —
  do not rely on per-line timestamps for recency; use **file mtime** as the clock.

### Status mapping — Claude [mostly VERIFIED shapes; thresholds GUESS]

Drive from the **last meaningful event** in the `.jsonl` (skip the timestamp-less
control lines `mode`/`permission-mode`/`ai-title` when finding "last meaningful"), cross-checked
with file mtime and the pid file's `.status`:

| Observed signal | → `AgentStatus` | Confidence |
|---|---|---|
| last `assistant` has `stop_reason == tool_use`, and no later `user`/`tool_result` yet, mtime fresh | `working` | shape VERIFIED; "fresh" threshold GUESS |
| trailing `assistant(tool_use)` → `user(tool_result)` pairs, mtime fresh | `working` (active tool loop) | VERIFIED shape |
| last `assistant` has `stop_reason == end_turn`, mtime fresh (< idle window) | `idle` (turn done, awaiting user) | VERIFIED shape; window GUESS |
| pid file `.status == "busy"` | `working` | VERIFIED value |
| pid file `.status == "idle"` | `idle` | VERIFIED value |
| **pending permission prompt** (see caveat) | `needsAttention` | **GUESS — unconfirmed** |
| process gone (pid dead / no pid file) **and** last event `end_turn` | `done` | inference |
| file mtime older than **staleWindow** (default **900 s**) with process alive | `idle` | threshold GUESS |
| reader cannot parse / unknown status value | `idle` (never fabricate `working`) | policy (I6) |
| restored from boot before first read | `stale` (already done by `restoredForBoot()`) | VERIFIED in repo |

**`needsAttention` caveat — the single biggest unknown.** This machine runs Claude in
`bypassPermissions` mode, so **no pending-permission event was observable**. Whether a
blocked permission prompt surfaces as a distinct `.jsonl` event/field, or only as
`sessions/<pid>.json` `.status`, is **unconfirmed**. Treat `needsAttention` as
**hook-driven** (the `Notification` hook, see Push) as the reliable path; any
`.jsonl`-derived `needsAttention` must be proven against a golden fixture captured in
default (non-bypass) permission mode before it ships. Until then, do **not** emit
`needsAttention` from file parsing — under-claim to `working`/`idle`.

Recommended thresholds (all user-configurable per `docs/29`/TDD memory; values are
starting defaults, not law): `freshWorkingWindow = 30 s`, `idleWindow = 120 s`,
`staleWindow = 900 s`.

### Title / label — Claude [VERIFIED]

`.aiTitle` from the **last** `ai-title` event in the stream. Fallback: `agent-name`
event, then the pid file `.name` (string|null). The title is a short human label and
is I5-safe to surface (it is a label, not a body) — but treat it as display metadata,
never sync it raw if uncertain.

---

## Codex reader

### Store & structure [VERIFIED]

```
~/.codex/
  sessions/YYYY/MM/DD/rollout-<ISO8601>-<uuid>.jsonl   # the event stream, date-bucketed
  session_index.jsonl                                  # {id, thread_name, updated_at} — PARTIAL/STALE (see below)
  archived_sessions/                                   # archived rollouts
  config.toml                                          # SKIPPED (secrets) — has auth-adjacent keys
  auth.json                                            # SKIPPED (secrets/tokens) — NEVER read
```

- Rollout filename: `rollout-<YYYY-MM-DDThh-mm-ss>-<session-uuid>.jsonl` (timestamp
  uses `-` separators, not `:`). 238 rollout files on this machine. All sampled across
  May→June use the **same** `{type, timestamp, payload}` line format [VERIFIED] — format
  is stable across CLI versions observed.
- `session_index.jsonl` schema [VERIFIED]: **only** `{id, thread_name, updated_at}` per
  line (128 lines). `id` is uuid-shaped; `updated_at`/`thread_name` are strings.

### Linkage: pane → session — **THE CONFIRMED ANSWER** [VERIFIED]

> **There is NO pid- or tty-keyed link for Codex.** `session_index.jsonl` contains
> **no** `pid`/`tty`/`term`/`pane`/`proc` key (confirmed by key-name search). The only
> identity in a rollout is the embedded `session_meta.payload.id` + `payload.cwd`.

Worse, **`session_index.jsonl` is stale and partial**: its newest `updated_at` is
`2026-06-10`, while rollouts on disk run to `2026-06-26`; the index has 128 entries vs
238 rollout files; and the most-recent rollout's `session_meta.payload.id`
(`019f04c8-…`) is **absent** from the index. **Do not treat `session_index.jsonl` as the
primary link.** It is at best a name lookup for older sessions.

**Robust linkage = recency-by-mtime + cwd from `session_meta`** (validated by a
throwaway scratchpad experiment, see Sources):

```
1. From the tile: cwd (OSC-7 pane_current_path) and the pane-start time.
2. Scan ~/.codex/sessions/**/rollout-*.jsonl newest-first by FILE MTIME.
3. For each, read ONLY line 1 (always `session_meta`); compare .payload.cwd == tile.cwd.
4. First (most-recent) match wins → that rollout is this tile's session.
5. Liveness/status from that rollout's tail + its mtime.
```

**Collision risk is real and must be handled** [VERIFIED]: 21 distinct rollouts share
cwd `selectus-ms` on this machine. cwd alone is ambiguous; "most-recent mtime for that
cwd" disambiguates, but if two Codex tiles run in the **same cwd** simultaneously they
are indistinguishable from files alone (both map to the newest rollout). Mitigations,
in order: (a) record the rollout's mtime/`session_meta.timestamp` at the moment the tile
spawns and prefer the rollout created **after** pane start; (b) accept one-of-N
ambiguity and show `codex (running)` without per-session deep status; (c) if Codex ever
gains a `--session-id`/env handle at launch, capture it like Pi's runId. Never guess a
specific status onto the wrong session.

### Rollout event schema [VERIFIED]

Line format: `{type, timestamp, payload}`. `type` ∈
{`session_meta`, `turn_context`, `event_msg`, `response_item`}.

- `session_meta.payload` keys: `id, timestamp, cwd, originator, cli_version, source,`
  `thread_source, model_provider, base_instructions(obj), git(obj)`. **cwd + id live
  here.**
- `turn_context.payload` keys: `turn_id, cwd, current_date, timezone, approval_policy,`
  `sandbox_policy(obj), permission_profile(obj), model, personality,`
  `collaboration_mode(obj), realtime_active(bool), effort, summary`. **`approval_policy`
  is the Codex analog of Claude's permission-mode; `model`/`effort` are mode metadata.**
- `event_msg.payload.type` ∈ {`task_started`, `agent_message`, `token_count`,
  `user_message`, `turn_aborted`} [VERIFIED].
- `response_item.payload.type` ∈ {`function_call`, `function_call_output`, `message`,
  `reasoning`} [VERIFIED] — `function_call`/`function_call_output` are the tool-loop pair.

### Status mapping — Codex [shapes VERIFIED; mapping GUESS]

Drive from the **last** `event_msg.payload.type` / `response_item.payload.type` plus
file mtime:

| Observed tail signal | → `AgentStatus` | Confidence |
|---|---|---|
| last event `event_msg/task_started` then ongoing `response_item` activity, mtime fresh | `working` | shape VERIFIED |
| trailing `response_item/function_call` → `function_call_output` pairs, mtime fresh | `working` (tool loop) | shape VERIFIED |
| last event `event_msg/agent_message` then quiescent, mtime within idle window | `idle` (turn produced output, awaiting user) | GUESS |
| last event `event_msg/turn_aborted` | `idle` or `done` (turn cancelled) | shape VERIFIED; which one GUESS |
| mtime older than **staleWindow** | `idle`/`stale` | threshold GUESS |
| `turn_context.payload.approval_policy` requires approval **and** a tool call is pending with no output | `needsAttention` | **GUESS — unconfirmed; no pending-approval fixture observed** |
| no rollout matched / unparseable | unknown → `idle` (or `shell` if not detected as codex) | policy (I6) |

Codex has **no explicit status field** (unlike Pi). All Codex status is inferred from
event tails + mtime, so it is the **least authoritative** of the three and most
dependent on golden fixtures. Same default windows as Claude.

### Title / label — Codex [VERIFIED—partial]

- `session_index.jsonl` `.thread_name` is the closest to a human title, **but** the
  index is stale/partial, so it is often missing for the active session.
- `turn_context.payload.summary` (string) may carry a short summary — **GUESS** that it
  is label-suitable; treat as body-adjacent until a fixture proves it is short/safe.
- Pragmatic fallback: derive a label from `session_meta.payload.cwd` basename + model,
  e.g. `codex · <repo> · <model>`. No reliable title event was confirmed.

---

## Pi reader

### Store & structure [VERIFIED] — two roots, both matter

**(a) Single-shot agent runs** (`pi -p` style; also what Continuum's own harness writes):
```
<root>/agent-runs/<runId>/
    run.json            # authoritative status + metadata
    output.json         # final extracted result (schemaVersion'd)
    events.jsonl        # lifecycle event stream
    final.md summary.md system-prompt*.md   # human artifacts (system-prompt* = 0600)
```
Two roots host this:
- `~/.pi/agent-runs/<runId>/` — global CLI runs. [VERIFIED on disk]
- **`<projectRoot>/.pi/agent-runs/<runId>/`** — **Continuum's own harness writes here**,
  via `pathlib.Path.cwd()/'.pi'/'agent-runs'/run_id`
  (`Sources/ContinuumRevivedCore/HarnessRoleRun.swift:108`,
  `Sources/ContinuumRevived/App/ContinuumApp.swift:3812`). The reader **must check the
  project-local `.pi/agent-runs/` first**, then `~/.pi/agent-runs/`.

**(b) Overnight orchestration runs:**
```
~/.pi/overnight-runs/<project>/
    latest -> run-<UTCstamp>     # SYMLINK to the newest run dir  [VERIFIED]
    run-<YYYYMMDDThhmmss>/
        status.json   # explicit orchestration state
        events.jsonl  # iteration lifecycle
        report.md tickets/ watches/ logs/
```

### Linkage: → run — **EXACT via runId** [VERIFIED]

`AgentDescriptor.runId` is already set at spawn (`TileSpawner.swift:139-144`) by
`HarnessRoleRunBuilder.makeRunId(roleId:now:suffix:)`
(`HarnessRoleRun.swift:73`), whose format is
**`<roleId>-yyyyMMdd'T'HHmmss'Z'-<6-char-suffix>`**. That string is **literally the run
directory name** on disk — e.g. `code-reviewer-20260611T124657Z-884e9d`,
`explorer-20260611T123946Z-0b619a`. So:

```
AgentDescriptor.runId  →  <projectRoot>/.pi/agent-runs/<runId>/   (then ~/.pi/agent-runs/<runId>/)
                          read run.json / events.jsonl
```

For overnight runs the link is `project name → overnight-runs/<project>/latest`
(resolve the symlink) → `status.json`. `run.json` also carries its own `pid` (number)
[VERIFIED], giving a secondary liveness check.

### Schemas [VERIFIED — keys + value types only]

`agent-runs/<runId>/run.json`:
`id`(str = runId), `role`(str = agentKind, observed {`code-reviewer`,`explorer`}),
**`status`**(str), `task`(str = the human label), `cwd`(str), `createdAt`/`updatedAt`/
`startedAt`/`endedAt`(str ISO), `model`(str), `reasoning`(str), `tools`(array),
`tmux`(null), `parentRunId`(null), `chainStep`(num), `artifacts`(obj), `pid`(num).

`agent-runs/<runId>/output.json`:
`schemaVersion`(num), `runId`(str), `role`(str), `task`(str), `status`(str), `cwd`(str),
`model`(str), `reasoning`(str), `tools`(arr), `createdAt`/`startedAt`/`endedAt`/
`extractedAt`(str), `artifacts`(obj), `final`(obj), `stderr`(obj). **`final`/`stderr`
are result bodies — do NOT read for status; status is in `.status`.**

`agent-runs/<runId>/events.jsonl` event `type` enum [VERIFIED]: `started`, `session`,
`agent_start`, `turn_start`, `tool_execution_start`, `tool_execution_update`,
`tool_execution_end`, `turn_end`, `message_start`, `message_end`, `agent_end`,
`finished`. Lifecycle event shapes (keys only): `started` →
`{type, ts, pid, command, args}`; `turn_start` → `{type, ts}`; `finished` →
`{type, ts, exitCode, signal, status}`.

`overnight-runs/<project>/run-*/status.json`:
**`state`**(str), `reason`(str), `repo`(str), `branch`(str), `startHead`/`currentHead`
(str), `runDir`(str), `promptFile`/`queueFile`(str), `pushMode`(str), `piModel`/
`piProvider`/`piThinking`(str), `iterations`(num), `softFailures`(num), `updatedAt`(str).
Observed `.state` ∈ {`running`, `stopped`} [VERIFIED]. `.reason` sub-status observed
{`queue-empty`, `iteration-1`, `matrix-failure-needs-human`, `refuse-main`,
`harness-malformed-output`, and **free-text** like `"W06 matrix failed: …"`}. **`.reason`
can contain free text** → see Privacy spec (truncate / allowlist, do not surface raw).
`overnight events.jsonl` types [VERIFIED]: `start`, `iteration-start`, `iteration-end`,
`continue`, `watch-archived`, `stop`, plus config breadcrumbs.

### Status mapping — Pi [mostly VERIFIED — Pi is the authoritative one]

**Single-shot run** — `run.json` `.status` is explicit; map it directly. Observed value:
`done`. Full enum is undocumented (only completed runs on disk), so map known +
default-safe:

| `run.json` `.status` (or inferred) | → `AgentStatus` | Confidence |
|---|---|---|
| `done` / `completed` / `finished` / `success` | `done` | `done` VERIFIED; synonyms GUESS |
| `running` / `in_progress` / `active` | `working` | GUESS (no in-flight run on disk) |
| `pending` / `queued` / `starting` | `configuring` | GUESS |
| `failed` / `error` / `aborted` | `done` (terminal) + surface error in `detail` | GUESS |
| `.endedAt` empty/missing **and** pid alive | `working` | inference from nullability shape |
| any unknown `.status` | derive from `events.jsonl` tail (below), else `idle` | policy |

Cross-check / fallback via `events.jsonl` tail [VERIFIED shapes]: last event
`finished`/`agent_end` ⇒ `done`; last event in {`turn_start`, `tool_execution_start`,
`message_start`} with no matching `*_end` and mtime fresh ⇒ `working`; between turns,
mtime fresh ⇒ `idle`.

**Overnight run** — `status.json` `.state` is explicit:

| `status.json` `.state` (+ `.reason`) | → `AgentStatus` | Confidence |
|---|---|---|
| `running` | `working` | VERIFIED value |
| `stopped` + `.reason` ∈ {`matrix-failure-needs-human`, `refuse-main`} | `needsAttention` | state VERIFIED; reason→attention mapping GUESS |
| `stopped` + `.reason == queue-empty` | `done` | GUESS |
| `stopped` + other reason | `done` (or `idle` if `.updatedAt` recent) | GUESS |

Pi is the **only** agent with a first-class status field, so its mapping is the most
trustworthy; the residual GUESSes are the *value enums* (we only saw `done`/`running`/
`stopped`), not the *mechanism*.

### Title / label — Pi [VERIFIED]

`run.json` `.task` (string) is the human label for a single-shot run; `.role` gives the
agentKind. For overnight, label from `<project>` + `status.json` `.branch`. **`.task` may
echo a chunk of the original prompt** → truncate to a short label and treat as
body-adjacent (Privacy spec).

---

## Unified `AgentSnapshot`

A reader's `read()` returns this transport-neutral, body-free shape. (Proposed; mirrors
the existing `RunArtifactsSnapshot` discipline.)

```swift
public enum AgentKind: String, Codable, Sendable {   // §C: detected, not free-typed
    case shell, claude, codex, pi, unknown
}

public struct AgentSnapshot: Codable, Equatable, Sendable {
    public var kind: AgentKind
    public var status: AgentStatus        // maps to AgentDescriptor.status (the existing enum)
    public var title: String?             // short human label (ai-title / run.json.task / thread_name); truncated
    public var mode: String?              // permission/approval mode: bypassPermissions | normal | <approval_policy>
    public var asOf: Date                 // the evidence clock = file mtime (NOT wall-clock now)
    public var detail: String?            // short, allowlisted reason (e.g. overnight .reason, truncated) — never a body
    public var evidence: Evidence         // for I6 soundness: what backed this status
    public struct Evidence: Codable, Equatable, Sendable {
        public var source: String         // "claude:sessions/pid.json" | "claude:jsonl-tail" | "codex:rollout-tail" | "pi:run.json" | "pi:status.json" | "hook"
        public var lastEventType: String? // enum value only, never content
        public var mtimeAgeSeconds: Double
    }
}
```

**How each reader fills it:**

| field | Claude | Codex | Pi (single-shot) | Pi (overnight) |
|---|---|---|---|---|
| `status` | jsonl tail + pid `.status` | rollout tail + mtime | `run.json.status` | `status.json.state` |
| `title` | last `ai-title.aiTitle` | `session_index.thread_name` (often nil) → cwd basename | `run.json.task` (truncated) | `<project>`+`branch` |
| `mode` | last `permission-mode.permissionMode` | `turn_context.approval_policy` | n/a | `status.json.pushMode` |
| `asOf` | `<sessionId>.jsonl` mtime | rollout mtime | `run.json` mtime | `status.json.updatedAt`/mtime |
| `detail` | nil (or hook reason) | nil | error tail summary (allowlisted) | `status.json.reason` (truncated) |
| `evidence.lastEventType` | last meaningful `.type` | last `payload.type` | last `events.jsonl.type` | last overnight event `type` |

The `SessionObserver` writes `snapshot.status` → `AgentDescriptor.status` and
`snapshot.asOf` → `AgentDescriptor.statusUpdatedAt`; `kind` → a detected `agentKind`.
`title`/`mode`/`detail` feed the sidebar/rollup rendering.

---

## Status-mapping tables

Consolidated decision tables are inline per reader above (Claude, Codex, Pi). The
cross-cutting rules (I6 "status soundness"):

1. **`working`/`done` require fresh, positive evidence.** A stale file (mtime beyond
   `staleWindow`) never yields `working`.
2. **Unknown ⇒ never `working`.** Unparseable / unknown status value / no-store-found
   collapses to `idle` (if detected as an agent) or `shell`/`unknown` (if not), per §C.
3. **`needsAttention` is conservative.** Only the **hook** path (Claude `Notification`)
   and Pi's explicit `needsAttention`-reason states emit it today. File-derived
   `needsAttention` for Claude/Codex stays **disabled** until a golden fixture captured
   in a permission-prompting state proves the signal.
4. **The clock is `asOf = file mtime`, not `Date.now()`** — consistent with the
   workflow `Date.now()` ban (MEMORY: TDD/configurable-first). Staleness = `now − asOf`.
5. All windows (`freshWorkingWindow`, `idleWindow`, `staleWindow`) are
   **user-configurable** with persisted defaults + a Settings entry (per `docs/29` and
   the configurable-first doctrine), not hardcoded.

---

## Detection

`tmux display -p -t <win> '#{pane_current_command}'` → foreground process `comm`. Map:

| `pane_current_command` | → `AgentKind` | Confidence / caveat |
|---|---|---|
| `claude` | `claude` | **[VERIFIED]** `claude` is a native Mach-O arm64 binary at `~/.local/bin/claude`; `ps comm` shows `claude`. Reliable. |
| `pi` | `pi` | **[VERIFIED]** `pi` is a `#!/usr/bin/env node` script, **but** it sets `process.title`, so `ps comm` shows `pi` (8 live procs observed as `pi`, not `node`). Reliable on this version. |
| `codex` **or** `node` | `codex` (probe to confirm) | **[VERIFIED]** `codex` is a `#!/usr/bin/env node` script; whether `comm` reads `codex` or `node` is impl/version-dependent and **could not be confirmed live** (no codex running). **Caveat: treat bare `node` as ambiguous** — confirm by probing for a recent matching-cwd rollout (the Codex linkage) before classifying; otherwise leave as `shell`/`unknown`. |
| `zsh`/`bash`/`fish`/login shell | `shell` | a plain shell; running-vs-idle from pid liveness only |
| anything else | `unknown` | shows in tree as `unknown`, no deep status |

**Wrapper caveats** [VERIFIED reasoning]:
- Node-shim CLIs (`#!/usr/bin/env node`) normally report `comm == node` unless they set
  `process.title`. **Pi does; Codex's behavior is unconfirmed** → the `node`-ambiguity
  rule above is mandatory for Codex.
- tmux reports the **foreground** process of the pane. If the agent is launched under a
  login shell that stays foreground (rare) or a debugger/`watch` wrapper, `comm` is the
  wrapper, not the agent — fall back to the cwd-store probe (Codex/Pi) or pid-file lookup
  (Claude `sessions/<pid>.json`).
- Detection is the *kind* classifier only; **status never comes from `comm`**.

---

## Push (hooks)

Per §C, "push beats poll": watch the store with FSEvents, and for Claude also support an
explicit hook breadcrumb. The repo's `RunArtifactsWatcher` already demonstrates the
debounced/budgeted watch (`maxReadsPerSecond`, `debounceInterval`,
`RunArtifactsWatcher.swift:64-119`) — reuse that discipline for all three readers.

### Claude Code hooks [VERIFIED schema on disk + WEB for the event list]

Config schema (verified against this machine's `~/.claude/settings.json` and the repo's
`.claude/settings.json`): top-level `hooks` is a map **event-name → array of
`{matcher, hooks: [{type, command, …}]}`**.

```jsonc
"hooks": {
  "<EventName>": [
    { "matcher": "Bash|Edit|*",            // string|regex; tool/event filter
      "hooks": [ { "type": "command", "command": "…", "timeout": 600 } ] }
  ]
}
```
[VERIFIED] inner hook entry keys: `{type, command}` (type value `command`); entry keys
`{matcher, hooks}`; matcher is a string. This machine has `PreCompact` configured
globally; the repo has `PostToolUse` + `PreCompact`.

**Available hook events** [WEB — official docs, https://code.claude.com/docs/en/hooks,
fetched 2026-06-30] — the page documents 29 events:
`SessionStart, Setup, UserPromptSubmit, UserPromptExpansion, PreToolUse,
PermissionRequest, PermissionDenied, PostToolUse, PostToolUseFailure, PostToolBatch,
Notification, MessageDisplay, SubagentStart, SubagentStop, TaskCreated, TaskCompleted,
Stop, StopFailure, TeammateIdle, InstructionsLoaded, ConfigChange, CwdChanged,
FileChanged, WorktreeCreate, WorktreeRemove, PreCompact, PostCompact, Elicitation,
ElicitationResult`. The hook `type` field also supports `command|http|mcp_tool|prompt|
agent` per the docs.

> Note: secondary blogs (morphllm, claudefa.st) cite "12" or "30" events; trust the
> official reference (29, dated above). The list is version-unstable — re-verify on
> upgrade.

**Events relevant to status (the breadcrumb set):**

| Hook event | Fires when | → status signal |
|---|---|---|
| `Stop` | Claude finishes responding (turn end) | `idle`/`done` |
| `StopFailure` | turn ends due to API error | `done` + error detail |
| `Notification` | Claude sends a notification (incl. **permission prompts / waiting on input**) | **`needsAttention`** — the reliable source |
| `SessionStart` / `SessionEnd` | session begin/resume / end | liveness anchor, capture pid→sessionId |
| `PostToolUse` | after a tool succeeds | confirms `working` (tool loop live) |
| `PermissionRequest` | a permission dialog appears | **`needsAttention`** (stronger than Notification) |
| `UserPromptSubmit` | user submits a prompt | transition idle→working |

A Continuum-installed hook would write a tiny breadcrumb (event name + sessionId +
timestamp — **no prompt/tool content**) to a file the observer watches. **Installing into
the user's `~/.claude/settings.json` requires explicit consent** (§C open item); the
read-only FSEvents watch over `<sessionId>.jsonl` is the zero-consent default, with hooks
as an opt-in upgrade for `needsAttention` latency/accuracy.

### Codex / Pi push equivalents

- **Codex:** no documented hook system found [WEB search did not surface one]. Push =
  **FSEvents on the matched `rollout-*.jsonl`** (it appends on every action). No
  explicit breadcrumb mechanism. **[GUESS that none exists — flag for re-check.]**
- **Pi:** no hook system, but the run dir is itself the push surface — FSEvents on
  `agent-runs/<runId>/{run.json,events.jsonl}` and `overnight-runs/<project>/latest/
  status.json`. `RunArtifactsWatcher` already does exactly this for agent-runs; extend
  it to overnight `status.json`.

---

## Golden-fixture plan (I6)

Capture **redacted** real files as test fixtures under
`Tests/Fixtures/agent-readers/<agent>/<scenario>/`. Redaction is mandatory: keep
structure + enum values + timestamps; **scrub every free-text/body field to a fixed
placeholder** (see Privacy spec for the exact field list). Each fixture pairs a captured
`pane_current_command` value with the store file(s), replayed through the reader.

**Claude** (`projects/<encode>/…jsonl` + `sessions/<pid>.json`):
- `claude-working` — stream ending in `assistant(stop_reason=tool_use)` + a trailing
  `user(tool_result)` pair; pid file `.status=busy`. Assert: `status==working`,
  `evidence.lastEventType=="assistant"`, `mode` parsed, `title` from `ai-title`.
- `claude-idle` — stream ending in `assistant(stop_reason=end_turn)`; pid `.status=idle`.
  Assert `status==idle`.
- `claude-done` — pid file absent (process gone) + last event `end_turn`. Assert `done`.
- `claude-needsAttention` — **MUST be captured in default (non-bypass) permission mode**
  with a real pending `PermissionRequest`/`Notification` (this machine couldn't produce
  it). Until captured, the reader's `needsAttention`-from-file path stays unimplemented;
  the hook-breadcrumb fixture covers it instead.
- `claude-encode-cwd` — assert `encode(cwd)` maps `/`→`-` and `.`→`-` (use the
  `…--claude-worktrees…` double-dash case).
- `claude-stale` — fresh-parse but mtime beyond `staleWindow`. Assert not `working`.

**Codex** (`rollout-*.jsonl` + a `session_index.jsonl` slice):
- `codex-working` — rollout ending in `response_item/function_call` →
  `function_call_output`. Assert `working`, `mode` from `turn_context.approval_policy`.
- `codex-idle` — rollout ending in `event_msg/agent_message`, mtime within idle window.
- `codex-aborted` — rollout ending in `event_msg/turn_aborted`. Assert the chosen
  mapping (idle/done) — pin it.
- `codex-linkage` — a `sessions/` tree with **two** rollouts sharing one cwd + one with a
  different cwd. Assert: locate(cwd) returns the **most-recent-by-mtime** matching
  rollout; assert the 21-collision behavior is deterministic.
- `codex-index-stale` — a `session_index.jsonl` whose newest entry predates the rollout
  on disk. Assert the reader does **not** depend on the index for the active session.

**Pi** (`agent-runs/<runId>/{run.json,output.json,events.jsonl}` +
`overnight-runs/<project>/{latest,run-*}/status.json`):
- `pi-runid-link` — assert `makeRunId` output (`<role>-<UTCstamp>-<6char>`) equals the
  run-dir basename; assert the reader checks **project-local `.pi/` before `~/.pi/`**.
- `pi-done` — `run.json.status=done`, `events.jsonl` ending `finished`. Assert `done`,
  `title` from `.task` (redacted), `kind=pi`.
- `pi-working` — synthesized `run.json` with empty `.endedAt` + `events.jsonl` ending
  `tool_execution_start`. Assert `working`.
- `pi-overnight-running` — `status.json.state=running`. Assert `working`,
  `detail`/`title` from project+branch.
- `pi-overnight-needsHuman` — `status.json.state=stopped`,
  `.reason=matrix-failure-needs-human`. Assert `needsAttention`; assert `.reason`
  truncated/allowlisted (the free-text `"W06 …"` reason must be scrubbed in the fixture).
- `pi-latest-symlink` — `latest -> run-<ts>`; assert the reader resolves the symlink.

**Shared parse assertions for every fixture:** (1) reader emits a valid `AgentSnapshot`;
(2) `status` matches expected; (3) **no scrubbed-placeholder string ever appears in any
field other than where bodies were redacted** (a taint check — proves the reader never
read a body field); (4) round-trips (I7) — `AgentSnapshot` serialize→deserialize→equal.

---

## Privacy spec

Binds I5 ("transcript content must never cross the sync boundary") at the reader layer.

**Readers MAY read:** file/dir **names**; JSON/JSONL **key names**; the **enum value** of
`type`/`subtype`/`status`/`state`/`stop_reason`/`payload.type`/`mode`/`permissionMode`/
`approval_policy`/`pushMode`/`role`/`reason`; **timestamps**; **counts**
(`messageCount`, `iterations`, `softFailures`); the short **title/label** fields
(`ai-title.aiTitle`, `run.json.task`, `session_index.thread_name`) — **truncated to ~80
chars** and treated as display metadata.

**Readers MUST NOT read or persist (body fields):** any `.message.content` (Claude),
`response_item`/`event_msg` payload text and `agent_message`/`user_message` bodies
(Codex), `output.json` `.final`/`.stderr` and `final.md`/`summary.md`/`report.md` bodies
(Pi), `base_instructions`, `system-prompt*.md`, tool inputs/outputs (`toolUseResult`,
`function_call*` args), or **any free-text reason** verbatim (`status.json.reason` can be
free text → truncate to a short allowlisted code; if it isn't a known code, drop it).

**Readers MUST NEVER open (secrets — skip entirely):** `~/.codex/auth.json`,
secret keys in `~/.codex/config.toml`, `~/.claude/.credentials*`, `daemon-auth*`,
`~/.claude/daemon*`, anything token-bearing. The readers only ever touch the specific
store files enumerated per agent; everything else under these roots is out of scope.

**Staying I5-clean:** `AgentSnapshot` carries no pid, no pane target, no host-local
handle, no body — only `{kind, status, title?, mode?, asOf, detail?, evidence}`. The
join keys (pid, runId, cwd, rollout path) are **observer-local** and never enter the
snapshot or the synced payload. The I5 taint scan asserts the synced payload excludes
pid/pane-target/host handle; the reader's contribution is excluded **by shape**. Titles
are truncated; `detail` is allowlisted codes only. The golden-fixture taint assertion
(above, #3) proves at test time that no body field was read.

---

## Open questions & version-stability risks

**Per agent:**

- **Claude:**
  1. `needsAttention` from files is **unconfirmed** (machine runs bypass mode); the
     `Notification`/`PermissionRequest` hook is the only proven source. *[blocking for the
     `needsAttention` file path]*
  2. Full `sessions/<pid>.json` `.status` enum unknown (only `busy`/`idle` seen).
  3. Hook-install consent UX (write into user's `settings.json`?) — §C open.
  4. `.jsonl` schema is version-unstable (this machine: CLI `2.1.193`–`2.1.195`); the
     29-event hook list will drift. Golden fixtures + re-verify on upgrade.

- **Codex:**
  1. **Confirmed: no pid/tty link** — linkage is recency+cwd with a real **collision
     risk** (21 rollouts share one cwd). Same-cwd concurrent Codex tiles are
     file-indistinguishable. *[the riskiest linkage of the three]*
  2. `session_index.jsonl` is **stale/partial** (16 days behind, 128 vs 238) — cannot be
     the primary link. Why it lags is unknown.
  3. No explicit status field → all status is inferred; `turn_aborted`→idle-vs-done and
     all `needsAttention` (`approval_policy`) mappings are **GUESS**, fixture-gated.
  4. No hook/push API found; FSEvents-on-rollout only. Title source is weak.
  5. `pane_current_command` may be `node` (unconfirmed) — node-ambiguity rule required.

- **Pi:**
  1. **Two roots** (project-local `<root>/.pi/agent-runs` vs `~/.pi/agent-runs`) — reader
     must check both; Continuum's own harness writes project-local.
  2. `run.json` `.status` and overnight `.state` enums only partially observed (`done`,
     `running`, `stopped`); in-flight/`failed`/`pending` mappings are GUESS.
  3. `status.json.reason` can be **free text** → truncate/allowlist.
  4. Most authoritative of the three (explicit status fields) and lowest risk.

**Cross-cutting:** all three formats are **undocumented and version-unstable** (accepted
cost per §C). Mitigation is the golden-fixture suite (I6) + the "unknown ⇒ never
`working`" floor + per-agent re-verification on tool upgrades. The observer must carry
the existing `RunArtifactsWatcher`-style **budget/debounce** so many tiles can't thrash.

---

## Sources

**Repo (file:line):**
- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift:85` — `AgentStatus` enum;
  `:94` — `AgentDescriptor` (`agentKind, worktreePath, status, statusUpdatedAt, runId`);
  `:113` — `restoredForBoot()` → `stale`.
- `docs/38-agent-orchestration-architecture.md` §C (`:203`–`:288`), verified store table
  (`:222`–`:233`), invariants I5/I6 (`:383`/`:384`), per-layer I6 fixtures (`:397`).
- `Sources/ContinuumRevivedCore/HarnessRoleRun.swift:73` — `makeRunId` format
  `<role>-yyyyMMddTHHmmssZ-<6char>`; `:108` — Pi run dir `cwd()/.pi/agent-runs/<runId>`.
- `Sources/ContinuumRevived/App/TileSpawner.swift:139-144` — `runId` set on
  `AgentDescriptor` at spawn (`agentKind: role.id`).
- `Sources/ContinuumRevived/App/ContinuumApp.swift:3809-3812` — project-local
  `.pi/agent-runs/<runId>` path.
- `Sources/ContinuumRevivedCore/RunArtifactsWatcher.swift:64-119` — existing debounced,
  rate-limited (`maxReadsPerSecond`, `debounceInterval`) runId-keyed watcher;
  `RunArtifactsReader.read(runDirectory:)`.

**Real on-disk stores (schema verified 2026-06-30, no bodies read):**
- `~/.claude/sessions/<pid>.json` (e.g. `38649.json`,`59991.json`,`70921.json`) — pid +
  sessionId + cwd + status(`busy`/`idle`).
- `~/.claude/projects/-Users-dylan-Documents-personal-continuum-revived/<sessionId>.jsonl`
  — event-type enum, `assistant.message.stop_reason` ∈ {`end_turn`,`tool_use`},
  `ai-title.aiTitle`, `permission-mode.permissionMode`.
- `~/.claude/settings.json` + repo `.claude/settings.json` — `hooks` map structure.
- `~/.codex/session_index.jsonl` (`{id, thread_name, updated_at}`; stale to 2026-06-10) +
  `~/.codex/sessions/2026/MM/DD/rollout-*.jsonl` (`{type,timestamp,payload}`;
  `session_meta.payload.cwd/id`, `turn_context.payload.approval_policy`,
  `event_msg.payload.type`, `response_item.payload.type`).
- `~/.pi/agent-runs/<role>-<ts>-<hash>/{run.json,output.json,events.jsonl}` — `run.json`
  `status`/`task`/`role`/`pid`; `events.jsonl` lifecycle enum.
- `~/.pi/overnight-runs/continuum-revived/{latest→run-*,run-*}/status.json` — `state`
  ∈ {`running`,`stopped`}, `reason`, `pushMode`.
- Throwaway linkage experiment (scratchpad, not committed):
  `scratchpad/codex_link_probe.sh` — validated recency+cwd resolves a unique rollout and
  surfaced the 21-rollout same-cwd collision.

**Web (cited + dated):**
- Claude Code hooks reference — https://code.claude.com/docs/en/hooks (fetched
  2026-06-30): 29 hook events; `hooks.<Event> = [{matcher, hooks:[{type, command,…}]}]`;
  hook `type` ∈ `command|http|mcp_tool|prompt|agent`.
- Codex CLI session/rollout format — https://github.com/openai/codex/discussions/3827 and
  https://developers.openai.com/codex/cli/reference (accessed 2026-06-30): rollouts under
  `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, metadata header line + event lines,
  resume appends to the same file, `/status` shows approval policy.

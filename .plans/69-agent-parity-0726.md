# 0.7.26 — agent tiles that feel first-party

Bench: `.worktrees/0726-agent-parity`, branch `array/0726-agent-parity` off
`809bc17d` (0.7.25 build 76). Next build is 77. Ticket benches branch from this
one and merge back into it; nothing lands on `array/integration` until the
matrix has run on the merged bench.

Goal: every managed agent — Claude, Codex, Pi — behaves the same in a tile:
an honest context meter, steering plus a visible queue with force-send, a
readable session title, and the same canvas/delegation tools.

## Findings (2026-10-06 investigation, four reports)

### Context meter (T1)
1. Claude on `claude-opus-5-5` has no window: the tile looks the window up in
   pi's models-store only (`ManagedAgentTileNSView.swift:2019-2038`), which
   lacks the model. The ring falls back to a count — "8" mid-turn (input+output
   of one assistant frame, cache excluded), the run SUM (~1.1M) at turn end.
   Claude states the window itself: `result.modelUsage[model].contextWindow`.
2. The compaction epoch guard drops Claude's own post-compaction snapshot:
   compaction-succeeded bumps `contextEpoch` before the `.claudeCompactBoundary`
   snapshot arrives stamped with the old epoch (`AgentSupervisor.swift:6516`,
   `:6534`). The supervisor's stand-in reading is never delivered as an event,
   so the tile keeps the pre-compaction %. `--agent-compaction-ui-check`
   asserts the drop (`AgentCompactionUIChecks.swift:72-80`) — it pins the bug.
3. Codex app-server (production) never maps `tokenUsage.last` /
   `modelContextWindow` (`CodexAppServerEventTranslator.swift:423-435`): no
   live meter.
4. Pi/Codex settings-only snapshots REPLACE the tile's reading (ring blanks to
   unknown each turn; the policy tick vanishes on the next usage snapshot).
5. Pi `compaction_end` never updates the ring.
6. In-turn compaction can leave the agent stuck "compacting" if no terminal
   event arrives.
Design: one Core reducer owns occupancy. Inputs: per-request prompt tokens
(Claude `message_start` input+cache, Codex `last`, Pi `message_end`), a
provider-stated window (persisted per resolved model), policy (merged), and
compaction phase/after. Cumulative figures feed cost only. The tile renders.

### Titles (T2)
claude ≥ 2.1.278 no longer writes `ai-title` in headless sessions (0 of ~1,900
since). Claude never reaches the generated rung. The generated rung is ALWAYS
pi with a hard-coded model (`AgentSupervisor.swift:204`, breaks non-negotiable
#5) and its capability probe runs `$SHELL -ilc` with a 1.0s timeout that
Dylan's shell (1.6–2.1s) always misses, cached for the app's life — so zero
generated names exist in any store, for any harness. Design: each harness
titles with its own CLI + login, resolved like its runner, model = the agent's
own catalogue id. Bench `0721-naming` is salvage-only (fixtures, reader seam).

### Canvas + MCP (T3)
Claude/Codex get 6 MCP tools; pi gets 12 + spawn/wait. No delegate, message,
inspect, find, reveal or wait over MCP (`WorkspaceMCPToolCatalog.swift:63-147`,
`RoleRegistry.swift:88`). No `instructions` in MCP initialize, no
`--append-system-prompt`. `context()` advertises operations the caller has no
tool for. The MCP token sits in claude's env (leaked via `env` in session
f7809f62). Error replies lack `isError`. Approval runs in `main.sync` under a
60s URLSession default. The check pins the reduced six names.

### Steering + queue (T5)
Claude and Codex queue; Pi's composer emits `.steer` and the supervisor refuses
it silently (`AgentSupervisor.swift:5437-5440`). Queue rail: remove + clear
only; `resumeQueue` has no UI caller. Stop always kills the process group.
All three CLIs steer natively (claude stream-json input, consumed at next tool
boundary, verified live; codex `turn/steer` + `turn/interrupt`; pi `steer`,
`follow_up`, `abort`, `queue_update`). Claude's per-turn process also kills
every background job and background subagent at turn end
(`ClaudeAgentRunner.swift:538`) — a persistent stream-json process fixes both.

### Subagent chips (T4)
One full-width transcript row per reference; chips stack. Want flex-wrap.
Chips render `Name ·` with no visible state — status label missing/clipped.

## Tickets
- T1 context meter single owner (+ compaction delivery) — all three providers
- T2 per-harness session titles
- T3 MCP parity for Claude/Codex (catalog, instructions, honest context, token
  out of env, isError, approval timeout)
- T4 subagent chips flex-wrap + status label
- T5 steering, queue rail, force-send, interrupt-not-kill; persistent Claude
  process (decisions below)

## Decisions
(recorded when Dylan answers)

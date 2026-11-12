# Orchestration release (plan 116)

What the orchestration head adds to Managed mode, what is on and off by
default, and how to turn each switch on. Written for the 0.7.48 release
head, `array/orchestration-release`. Defaults below were read from code, not
from plan documents.

## What is in

- **Run ledger** (`docs/internals/managed-run-ledger.md`): an append-only,
  local record of tasks, delegations, turns and reports. It records no prompt,
  brief or report text. Every human submission to a top-level agent opens or
  joins a task, Managed or not.
- **Host-checked evidence, shadow**: what the host itself saw a helper change,
  computed with git on the ledger's background queue. Nothing reads it to
  decide anything.
- **Token telemetry**: tokens by type for each task, kept on this Mac.
- **Settings ▸ Usage** (`docs/internals/settings-usage-page.md`): the first
  slice of a usage page that reads the ledger.
- **Helper liveness**: `agent.inspect` reports a helper's liveness state.
- **Lead brief delivery**: the Managed lead's brief now goes out on resume,
  compact, clear and fork, and again after a mode switch, not only at
  startup. A compact after a mode switch launches fresh, so the lead keeps its
  workspace tools.
- **Read cap removed**: a Managed lead no longer stops after 3 reads, searches
  or commands per request. Only edit tools are refused.
- **Lead tools loaded up front** (`docs/internals/managed-lead-tool-loading.md`):
  a Claude Managed lead gets `array_status`, `array_delegate` and
  `array_message_agent` loaded at start. The brief also tells a lead to follow
  up a helper with `array_message_agent`.
- **Delegation options**: optional `effort` and `contract` on
  `array_delegate`, plus an overlap advisory in the result. A contract never
  refuses a delegation.
- **Project standards on demand** (`docs/internals/project-standards-on-demand.md`):
  `array_standards`, offered only in a checkout that has `docs/standards`.
- **Personal rules and reply rules**: launch seams for both, switched off.
- **Stalled-helper alert**: switched off.
- **Replay rig** (`benchmarks/replay/`): offline benchmark machinery and the
  live pilot driver. It is never run by the app.
- **Gate pre-pass** (`scripts/gate-prepass.py`): an offline report of which
  checks a change should rerun. It is wired to nothing.
- **Launch timing leg**: `--managed-launch-timing-check`, targeted only.

## On by default, and why each is safe for daily use

| What | Why it is safe |
|---|---|
| Run ledger | Recording only. The calling thread does one queue hand-off (about 12 µs per submission, 6 µs per delegation or report). Encoding and file I/O happen on a utility queue. No setting gates it. |
| Host evidence, shadow | Recording only, on the ledger's queue. Nothing acts on it. |
| Token telemetry (`agents.tokenTelemetry.enabled`) | Recording only, local, never uploaded. Turning it off stops new records and deletes nothing. |
| Helper liveness | A field in `agent.inspect` and a 30-second sweep. With the stall alert off, the lead is told what it was told before. |
| Settings ▸ Usage | **User-visible**: a new Settings section. It reads the ledger only when opened, on a background queue. |
| New Settings rows (Reply rules, Personal rules, stall alert, Token usage) | **User-visible**: rows only. The switches behind them default as listed. |
| Brief on resume, compact, clear, fork and mode switch | **Changes what an agent receives**: the brief arrives in more places, with one added sentence about `array_message_agent`. It fixes a lead left without its tools after `/compact`. |
| Read cap removed | **Changes what an agent receives**: a lead is no longer refused after 3 looks per request. Edits stay blocked. |
| Lead tools loaded up front | **Changes what an agent receives**: about 2,900 more start-up tokens for a Claude Managed lead only. It saves the turn a lead spent loading the tools before its first delegation. |
| `effort` and `contract` in the delegate schema | **Changes what an agent receives**: a longer delegate tool description for every agent. Both parameters are optional. |
| Live effort list | A stored effort the CLI no longer lists is left out of the launch, so the CLI uses its own default instead of failing. |
| `array_standards` | Offered only where `docs/standards` exists, and the Array repo has none. The presence test is a name listing with no file reads. |

## Off by default

| Switch | Setting | How to turn it on |
|---|---|---|
| Reply rules | `agents.replyRules.enabled` | Settings ▸ Agents ▸ Reply rules ▸ "Give every agent Array's reply rules". Applies from each agent's next launch. |
| Personal rules | `agents.personalRules.enabled`, `agents.personalRules.path` | Settings ▸ Agents ▸ Personal rules: turn on "Give Codex and Pi agents my rules" and give the full path of a short rules file. Claude reads its own instructions and is left alone. |
| Stalled-helper alert | `agents.managedMode.stallAlerts` | Settings ▸ Agents ▸ Managed mode ▸ "Tell the lead only when a helper is stuck". |

Each stays off until a measured run shows it helps (`.plans/116-agent-standards/HANDOFF.md`, gap A2).

## Launch time

`--managed-launch-timing-check` times a fresh Managed Claude lead from the
composer's `accept(.sendPrompt)` to its CLI session process starting, and a
helper from `agent.delegate` dispatch to its CLI starting. It uses a fake
CLI and asserts nothing about time. On a quiet machine, lead medians were
33.5 to 34.8 ms on origin/array/integration and 33.8 to 37.0 ms on this head,
and helper medians were about 78 ms on both. One launch-path cost was found
and removed: the lead's tool pin rewrote its MCP files on the main thread just
before the runner wrote them again.

## Not included

- `array/agent-standards`: drafts, plans and study evidence. Two plan files
  quote the owner's private instructions and client project terms. Adding
  `docs/standards` would also switch `array_standards` on, with unadopted
  drafts, for every agent working in this repo.
- `array/slim-layer-checks`, `array/helper-launch-probes`: not adopted.
- `array/live-usage-fixes`, `array/agent-store-stalls`: perf work outside this
  programme, with uncommitted work still in their benches.

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
  slice of a usage page that reads the ledger. It can delete one task's or
  all local usage records, after a confirmation; the ledger writer does the
  delete.
- **Lead checkout watch** (`docs/internals/managed-run-ledger.md`): FSEvents on
  a Managed lead's checkout records the files its own shell calls change, and
  the lead's hook receipts reach the ledger.
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
- **Strict lead**: a Managed Claude lead whose shell cannot write inside its
  checkout, so changes go to helpers. Proven live for Claude, switched off.
  Codex leads are not covered and launch as before.
- **Stalled-helper alert**: switched off.
- **Replay rig** (`benchmarks/replay/`): offline benchmark machinery and the
  live pilot driver. It is never run by the app.
- **Gate pre-pass** (`scripts/gate-prepass.py`): an offline report of which
  checks a change should rerun. It is wired to nothing.
- **Launch timing leg**: `--managed-launch-timing-check`, targeted only.

## On by default, and why each is safe for daily use

| What | Why it is safe |
|---|---|
| Run ledger | Recording only, nothing shown. The calling thread does one queue hand-off: 12 µs median per submission, 6 µs per delegation or report. A whole submission with recording on against off: +37 µs median (95% CI −166 to +334 µs). Encoding and file I/O happen on a utility queue. No setting gates it. |
| Host evidence, shadow | Recording only, nothing shown, nothing acts on it. Main thread: one hop per helper tool event and two `realpath` calls per delegation; git runs on the ledger's queue. |
| Lead checkout watch | Recording only, nothing shown. One FSEvents stream per lead checkout, delivered on its own queue; classification and git run on the watch's queue. |
| Token telemetry (`agents.tokenTelemetry.enabled`) | Recording only, local, never uploaded. Turning it off stops new records and deletes nothing. |
| Helper liveness | A field in `agent.inspect`; nothing shown to the user. With the stall alert off, the lead is told what it was told before. Main thread: classification runs inside the existing 30-second watchdog sweep. Over 2,000 finished helpers one sweep took 8.7 to 10.9 ms, against 5.4 to 5.8 ms on origin/array/integration. |
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
| Strict lead (Claude only) | `agents.strictLead.enabled`; `ARRAY_STRICT_LEAD=1` overrides | `defaults write dev.arrayapp.macos agents.strictLead.enabled -bool YES`, or launch Array with `ARRAY_STRICT_LEAD=1`. Applies at the lead's next turn. |

Each stays off until a measured run shows it helps (`.plans/116-agent-standards/HANDOFF.md`, gap A2).

## Measured cost

`--managed-launch-timing-check` (targeted only, no time assertions) drives
the production paths with a fake Claude CLI that answers at once, so the
numbers are Array's own. The same file built on origin/array/integration and
on this head; three alternating rounds of 20 samples on a quiet machine.
Medians, with p95 in brackets:

| Path | origin/array/integration | this head |
|---|---|---|
| Lead launch: composer submit to CLI start | 33.5–35.2 ms (43–53) | 33.5–34.9 ms (39–45) |
| First reply: submit to first assistant text Array delivers | 60.2–63.8 ms (70–92) | 61.4–63.3 ms (68–78) |
| `agent.delegate` to helper CLI start | 73.8–75.5 ms (75–96) | 74.3–77.0 ms (79–85) |
| Helper result to the lead's next turn | 125.8–130.2 ms (133–139) | 127.4–130.5 ms (132–142) |
| Watchdog sweep, 2,000 finished helpers (main thread, every 30 s) | 5.4–5.8 ms | 8.7–10.9 ms |

The four request paths are unchanged within run-to-run noise. One
launch-path cost was found and removed on the way: the lead's tool pin
rewrote its MCP files on the main thread just before the runner wrote them
again. The watchdog sweep is the one path that got slower.

## Not included

- `array/agent-standards`: drafts, plans and study evidence. Two plan files
  quote the owner's private instructions and client project terms. Adding
  `docs/standards` would also switch `array_standards` on, with unadopted
  drafts, for every agent working in this repo.
- `array/slim-layer-checks`, `array/helper-launch-probes`: not adopted.
- `array/live-usage-fixes`, `array/agent-store-stalls`: perf work outside this
  programme, with uncommitted work still in their benches.
- Strict mode for Codex leads: its sandbox profile cannot be pinned on resume,
  so it is not shipped (`ManagedStrictLead.swift`).

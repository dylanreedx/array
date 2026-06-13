# Agent status signal sources spike (CON-81)

Status: finding, 2026-06-13

## Question

Continuum agent tiles need status without lying. The spike asked what Claude Code, Codex CLI, plain shells, and the pi harness expose: OSC/title/notification signals, hooks/status files, output cadence, or explicit run artifacts.

## Local evidence captured

Artifacts:

- `qa-runs/con-81/local-evidence.log`
- `qa-runs/con-81/grep-evidence.log`
- scout: `.pi/agent-runs/code-scout-20260613T162533Z-8f3fd0/final.md`

Observed tool versions on this machine:

```text
claude: 2.1.177 (Claude Code)
codex: codex-cli 0.135.0
pi: 0.79.2
```

Claude Code help exposes structured non-interactive streams:

- `--output-format=stream-json`
- `--include-hook-events`
- `--input-format=stream-json`
- `--json-schema`
- `--settings`
- `--bare` explicitly skips hooks/plugins/MCP, proving hooks are part of the normal path.

Codex help exposes hooks as an execution/trust concept (`--dangerously-bypass-hook-trust`) and non-interactive `codex exec`, but the local help output did not show a stable status stream analogous to Claude's `stream-json`.

The pi harness already writes explicit structured artifacts under `.pi/agent-runs/<runId>/`: `run.json`, `events.jsonl`, `final.md`, `summary.md`, `output.json`, and stderr. A freshly captured scout run had `run.json.status = "done"`, timestamps, role, task, cwd, pid, and artifact paths.

## Current Continuum seams

Repo inspection found these already-landed building blocks:

- `Sources/ContinuumRevivedCore/TerminalSessionDescriptor.swift` defines `AgentStatus` (`configuring`, `working`, `idle`, `needsAttention`, `done`, `stale`) and `AgentDescriptor`.
- `Sources/ContinuumRevivedCore/ProjectStore.swift` restores persisted agent descriptors as `.stale` until fresh evidence arrives.
- `Sources/ContinuumRevivedCore/RunArtifactsReader.swift` tolerantly reads pi `run.json`, `events.jsonl`, and `final.md`.
- `docs/superpowers/specs/2026-06-harness-bridge-contract.md` freezes the pi artifact contract and requires tolerant readers.
- `docs/08-risk-register.md` warns that wrong inferred agent status is worse than simple running/exited status.

The missing piece is not parsing; it is a conservative reconciliation policy from explicit artifacts/signals into `AgentDescriptor.status` or a derived display status.

## Signal priority recommendation

Use this order. Lower layers must never override higher layers with optimistic claims.

1. **Explicit run artifact binding (highest confidence).** If an agent tile is bound to a pi run id, derive status from `run.json` + `events.jsonl` + final artifact validity. `done` is clean only when `final.md` exists and is not `(no output)`.
2. **CLI structured streams / hooks.** Claude Code `stream-json` with hook events is the best direct CLI path. A hook/status-file convention can emit `working`, `idle`, or `needsAttention` without scraping the TUI. Codex needs a follow-up implementation spike before claiming parity; local help only proves hook infrastructure exists, not a status schema.
3. **Terminal lifecycle.** Runtime exit, shell exit, and child status are useful for `done`/failure/terminal-dead warnings, but process exit is not equivalent to task success.
4. **OSC/title/bell/notifications.** Useful as hints only after CON-128 routes libghostty actions. Titles and notifications can say what the CLI wants to display, not a guaranteed work state.
5. **Output cadence / prompt heuristics (lowest confidence).** Use only as `stale`/activity hints with hysteresis. Never claim `idle` or `needsAttention` solely from quiet output.

## Proposed status mapping for pi-bound tiles

| Evidence | Display status |
|---|---|
| `run.json.status` queued/running | `working` |
| done + valid non-empty `final.md` | `done` |
| done + missing or `(no output)` final | `needsAttention` / warning |
| failed/killed | `needsAttention` |
| unknown status or malformed run.json | `stale` with warning |
| restored descriptor with no fresh bound run | `stale` |

## Follow-up implementation notes

- Add a deterministic Core mapper over `RunArtifactsReader` snapshots before any UI badge work.
- Add a run binding (`runId` or run directory) to agent descriptors when the tile is spawned by the harness bridge; do not guess by terminal title.
- Preserve raw/unknown statuses for tooltips so harness evolution does not break the canvas.
- Treat `final.md` evidence integrity exactly like docs/22: missing or `(no output)` is not a clean success.

## Open gaps

- Real interactive Claude/Codex OSC/title captures were not performed in this overnight unit; local CLI help and pi run artifacts were captured instead. CON-128 should provide the libghostty event stream needed for OSC/title observation.
- Codex-specific status hooks need a focused follow-up once a concrete hook schema is chosen.

## Conclusion

Build E10 status on explicit pi artifacts and CLI hook/stream outputs first. Keep OSC/title/output-cadence as honest hints, not truth. This avoids the Nyx-style fragile TUI-scraping failure mode and matches Continuum's evidence rules.

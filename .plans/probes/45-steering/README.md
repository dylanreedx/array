# Probe P — steering protocol captures, 2026-08-22

Raw evidence behind `.plans/43` §4d-pre. Versions: claude 2.1.240, pi 0.84.1,
codex-cli 0.148.0. Run in throwaway `/tmp` dirs, never inside a git repo, with
no provider config modified.

| file | what it shows |
|---|---|
| `claude-stdin-queue-short.jsonl` | a stdin user message sent mid-stream runs as the NEXT turn (count-to-60 completed unaffected) |
| `claude-stdin-queue-long.jsonl` | **the decisive one.** 76-second essay turn; B sent at t=12.6s; all 12,997 chars written; B replayed at t=81.2s as its own turn |
| `claude-control-interrupt.jsonl` | `control_request{subtype:interrupt}` → `control_response{success, still_queued: []}` in 1 ms; turn truncated to 5,378 chars; CLI authors `[Request interrupted by user]`; **result is `error_during_execution` with `is_error: true`**; the queued message then drains normally |
| `codex-appserver-protocol.json` | `turn/steer`, `turn/interrupt`, `thread/compact/start`, `thread/fork` param shapes plus the full method list and `ThreadSourceKind` (which includes `subAgentThreadSpawn`) |
| `*.py` | the drivers, so any claim here can be re-run |

pi's vocabulary was read from its installed package, not captured here:
`dist/modes/rpc/rpc-mode.js` (the `command` switch) and
`dist/core/agent-session.d.ts` (the `steer` / `followUp` / `abort` doc
comments). See §4d-pre for the quotes.

**Not observed, do not design on it:** no codex `app-server` session was run and
no subagent thread was seen. The `subAgentThreadSpawn` finding is from the
declared schema only.

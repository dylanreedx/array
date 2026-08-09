# 01 — CLI backends for managed agents

Status: planned, not started. Owner decision recorded in
`docs/internals/providers.md` ("current lean: CLI backends"); green-light
pending.

## Problem

Managed agent tiles are 100% pi-backed, and pi is a host-installed npm CLI
(plus node) that alpha users don't know and don't have. Today a machine
without pi silently has no managed agents, and the model catalogue is only as
wide as pi's authed providers.

## Direction

Introduce an agent-backend abstraction under `AgentSupervisor` so a managed
tile can run on whichever runtime the machine actually has:

- **pi** (`PiAgentRunner`, today's path) — preferred when installed: richest
  multi-provider catalogue.
- **claude CLI** — `claude -p --output-format stream-json` (headless
  streaming JSON; sessions via `--resume`).
- **codex CLI** — `codex exec --json`.

Selection: pi if present, else the authed CLI matching the requested model's
provider; surfaced in the composer (model list becomes the union of what the
present backends can run).

## Why not bundle pi

Bundling means shipping a node runtime (~100MB+), adopting pi's update
cadence into our releases, a license review — and it still would not solve
provider auth, which stays a CLI login either way (owner rule: never API
keys). Bundling remains the fallback if CLI backends prove too limiting.

## Shape of the work (rough)

1. Extract a `ManagedAgentBackend` protocol from `PiAgentRunner`'s surface
   (run/stop, event stream, session id, model listing, auth readiness).
2. `ClaudeCLIBackend`: translate claude's stream-json events into
   `AgentRuntimeEvent`s (the PiEventTranslator pattern).
3. `CodexCLIBackend`: same over `codex exec --json`.
4. Backend registry + selection policy + composer/model-catalogue union.
5. Onboarding rows update: managed agents "ready" when ANY backend is.
6. Witnesses per backend: fixture event streams → translator checks; a
   supervised live leg per CLI (the ticket-91 live-check pattern).

## Open questions

- Session resume semantics parity across backends (pi sessions vs claude
  `--resume` vs codex).
- Tool-permission prompts: how each CLI's approval flow surfaces in a
  headless tile.
- Context-window telemetry parity (`contextWindowUpdated` events exist for
  pi; claude/codex equivalents need mapping).

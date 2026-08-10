# 01 — CLI backends for managed agents

Status: **claude backend SHIPPED (2026-08-09)** — steps 2, 4 (claude half), 5
(claude half), 6 (claude half) done. Codex CLI backend and the formal
`ManagedAgentBackend` protocol extraction (step 1, 3) remain. Owner decision
recorded in `docs/internals/providers.md` ("current lean: CLI backends").

## What shipped (claude backend)

The endgame reason: **teammates never learn what pi is, and Claude models on
pi cost extra usage** — the claude CLI runs on the user's own Claude
subscription. Compliance-checked (see `docs/internals/providers.md`): local
spawning of the real `claude` binary under the user's own login is Anthropic's
sanctioned pattern; the bans targeted token extraction / API proxying (pi's
anthropic path is the API route), never CLI orchestration.

- `ClaudeEventTranslator` (Core) — pure `claude -p --output-format
  stream-json` → `AgentRuntimeEvent`, mirroring `PiEventTranslator`
  (I5-by-construction, sub-agent frames skipped, deltas-not-bodies).
- `ClaudeAgentRunner` (Core, macOS) — the impure half, mirroring
  `PiAgentRunner`. **Session continuity is derived, not stored**: the agent's
  own UUID is the claude session id; every run tries `--resume <uuid>` and,
  on the "No conversation found" failure (instant, no API call — verified
  live), retries once with `--session-id <uuid>`. Self-healing both ways, no
  record field.
- `ClaudeCLIBackend` (Core) — pure routing policy (`routesToClaude`: anthropic
  models → claude when installed, else pi), model-arg stripping, effort
  mapping, `auth status --json` parse.
- `AgentSupervisor.productionRunner(for:)` — the routing factory; the default
  `makeRunner`. `claudeRunner`/`claudeRunnerConfig` mirror the pi pair; the
  source-scan ownership check now covers both runner types.
- `AgentModelCatalog` — the claude aliases UNION into the catalogue (pi's list
  is never wiped); probe now also runs `claude auth status`. **iOS gate fix**:
  the probe machinery is now `#if os(macOS)` (it always needed to be — the
  pre-existing ungated `Process` use was silently reding the iOS matrix leg).
- Onboarding — a "Claude models (Claude Code)" row (own-login readiness);
  pi's anthropic row reworded as the metered fallback.
- Witnesses: `runClaudeAgentBackendChecks` (CoreChecks — mapping, gate, argv,
  routing, catalog union, all with a RED-verified teeth test) +
  `--claude-agent-live-check` (supervised two-turn codeword continuity, the
  pi-live-check twin; needs claude installed + a GUI session).

## Remaining shape of the work (rough)

1. Extract a `ManagedAgentBackend` protocol from `PiAgentRunner`'s surface
   (run/stop, event stream, session id, model listing, auth readiness). The
   two runners already share the `AgentRunning` seam; this is the tidy-up.
2. ~~`ClaudeCLIBackend`: translate claude's stream-json events~~ — DONE.
3. `CodexCLIBackend`: same over `codex exec --json`. Lower priority — no
   teammate uses codex.
4. ~~Backend registry + selection policy + composer/model-catalogue union~~ —
   DONE for claude (`productionRunner` + catalogue union).
5. ~~Onboarding rows update~~ — DONE for claude.
6. ~~Witnesses per backend~~ — DONE for claude.

## Open questions (still live)

- Tool-permission prompts: both backends currently run
  `--dangerously-skip-permissions` / pi's role tools with no approval flow in
  the headless tile. A surfaced approval dock is owed for BOTH, not a claude
  regression.
- Context-window OCCUPANCY parity: claude's `result.usage` is per-turn
  aggregate (mapped to `.claudeResultUsage`, non-authoritative for
  occupancy), same limitation as pi's `.piMessageUsage`. Real occupancy would
  need `--include-partial-messages` context tracking or claude's
  `getContextUsage` control (only via the Agent SDK, not the raw CLI).
- Model catalogue depth: shipped with claude's three curated aliases
  (opus/sonnet/haiku "latest"). A fuller per-model list would need
  `claude`'s own model catalogue (no stable JSON flag today).

## Compliance research (2026-08-09) — the load-bearing finding

The whole claude-backend bet rests on this being safe, so the research is
recorded here permanently rather than left in a chat.

**Verdict: local spawning of the real `claude` binary under the user's own
subscription login is SANCTIONED.** The 2025-26 ban wave targeted one root
cause — third-party harnesses that received/extracted the subscription OAuth
token and sent API requests AS the harness backend (with spoofed
client-identity headers), arbitraging a $200 Max plan into $1,000+ of API
usage (the opencode/OpenClaw controversy). Anthropic's own remediation for
those tools was to switch to spawning the real `claude` binary locally — which
they explicitly support. Production orchestrators doing exactly this
(Conductor, Crystal, claude-squad, Vibe Kanban) operate unbanned.

- The Agent SDK path (`@anthropic-ai/claude-agent-sdk` making direct calls) is
  documented as API-key-only for developers — that is what t3code uses, and it
  is the route Array deliberately does NOT take. Array shells out to the CLI,
  which does its own OAuth, so we never hold a token.
- pi's anthropic path IS an API route, but pi owns its own credentials via its
  own `/login` — Array never touches them. It is metered separately from a
  Claude subscription, which is the second reason to prefer the CLI.
- Codex under a ChatGPT subscription login is MORE permissive (OpenAI endorses
  local orchestration); GPT-5.5 is subscription-only, so the CLI path is the
  only way to reach it programmatically.

**Guardrails Array keeps (all satisfied by the shipped code):** never extract,
read, cache, or proxy the OAuth token; spawn the real binary; never set
`ANTHROPIC_API_KEY` or spoof client headers; never override `HOME` (it
relocates the macOS keychain lookup so the CLI can't find its login —
`ClaudeAgentRunner` augments only `PATH`); one human user per login; let the
binary self-identify and keep its telemetry.

Sources (retrieved 2026-08-09): code.claude.com/docs legal-and-compliance +
automation (headless mode); The Register 2026-02-20 ban clarification;
VentureBeat 2026-06 OpenClaw reinstatement; developers.openai.com/codex/auth.

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

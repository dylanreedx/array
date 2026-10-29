# Agent providers

Two distinct ways Array runs an agent — don't conflate them:

## 1. CLI tiles (claude, codex)

A terminal tile running the CLI interactively (`LaunchProfileRegistry`
profiles `claude` / `codex`). The CLI owns everything: its login (OAuth in
its own flow), its model choice (`/model` inside claude), its session. Array
contributes the augmented PATH (`ToolEnvironment` — Finder launches see
user-level installs) and state readers that observe the running CLI to drive
tile status. Verification is behavioral: the CLI starts and talks. Array
never parses provider auth state — an explicit v0 decision (go-live doc,
Phase 4).

## 2. Managed agent tiles (strict harness ownership)

Headless runs are owned by the `AgentHarness` persisted on each `AgentRecord`:
Claude Code constructs only `ClaudeAgentRunner`, Codex constructs only
`CodexAgentRunner`, and Pi constructs only `PiAgentRunner`. Availability and
authentication validate that selection; they never route to a different CLI. Settings
seed new records only, while existing agents keep their harness across relaunches.

Each harness owns its catalogue, display names, context windows, readiness, session
format, transcript reader, auth/config, telemetry and side channels. Pi therefore
retains role `--tools` and spawn observations even when it runs an
`openai-codex/*` model. Provider auth is always the selected CLI.s own login —
never API keys (owner rule).

- **Model catalogue**: `AgentModelCatalog` publishes immutable per-harness snapshots. Pi membership comes only from its bounded `--list-models` probe; Claude and Codex use their authenticated native catalogues. Production never flattens them for selection. QA fixtures are deterministic presentation seeds, not authentication evidence.
- **Readiness**: `pi auth check --provider X --json --no-refresh` and `claude
  auth status --json`, surfaced as onboarding rows.
- **Permissions**: a headless run has nobody to answer a CLI permission
  prompt, so every managed agent runs with full access. Claude gets
  `--permission-mode bypassPermissions` on fresh, resumed and forked
  sessions (`ClaudeAgentRunner.processArguments`); Codex gets
  `sandbox_mode=danger-full-access` + `approval_policy=never` on its launch,
  thread and turn requests. Array's workspace grants (Free / Ask first) are a
  separate layer that still gates Array's own tools.

### Compliance — why local claude spawning is safe

Anthropic's enforcement (2025-26 ban wave) targeted third-party harnesses that
EXTRACT the subscription OAuth token and call the API themselves with spoofed
client headers (opencode-style) — pi's anthropic path is an API route, but pi
holds its own credentials, not ours. **Spawning the real `claude` binary
locally under the user's own login is the sanctioned pattern** — Anthropic's
own recommended workaround, and what Conductor/Crystal/claude-squad do
unbanned. Array's guardrails, kept deliberately: never touch or read the
credential/keychain token; never set `ANTHROPIC_API_KEY` or spoof headers;
never override `HOME` (it relocates the keychain lookup — the CLI would report
"not logged in"); one human user per login; let the binary self-identify and
keep its telemetry. Same posture applies to codex under a ChatGPT login (more
permissive). See the full research in
[.plans/01-provider-cli-backends.md](../../.plans/01-provider-cli-backends.md).

## Onboarding surface

The Environment Setup panel (first run + Help menu) probes: claude + Claude
Code auth, codex, pi (install guidance), per-provider pi auth (CLI login
guidance), tmux, git CLT. `OnboardingPanel.liveProbes` is the single source.

## Still open

- **codex CLI backend** — `codex exec --json`, same pattern, lower priority
  (no teammate uses codex). Plan:
  [.plans/01-provider-cli-backends.md](../../.plans/01-provider-cli-backends.md).
- **Formal `ManagedAgentBackend` protocol** — the two runners share the
  `AgentRunning` seam today; a richer backend protocol (model listing, auth
  readiness) is the tidy-up once codex lands.
- **Approval flow** — both backends run without a tool-approval dock in the
  headless tile (claude `--permission-mode bypassPermissions`, codex full
  access, pi role tools).

## Cross-harness delegation

`array_delegate` accepts optional `harness` (`Claude Code`, `Codex`, `Pi`) and
`model`. With neither, the child inherits the parent's harness and model. A
new harness without a model uses that CLI catalogue's `seedModel` (its reported
default, or its first listed model). Explicit models must be exact, fully
qualified entries in the selected harness's live catalogue. `provider` remains
a legacy alias; conflicting selectors are invalid requests.

The API returns structured `unsupported` errors before creation for uninstalled,
signed-out, checking or unavailable harnesses, unknown models, and fresh
account-wide exhausted usage windows with future resets. Missing quota telemetry
is unknown; model-specific windows do not establish account-wide exhaustion.
No selection silently falls back to another CLI. Runner-reported failures after
creation remain visible through the child's transcript and operation result.

Children use the supervisor's existing spawn path, caps, parent link, tools,
grants, transcript chip, result handle and tile attachment, regardless of their
parent's harness. `array_message_agent` and MCP `wait_agents` resolve by agent
identity and operation handle. The offline
`--workspace-api-cross-harness-delegation-check` drives the production mount and
workspace API with catalogue fixtures and scripted runners; it performs no real
model turns. The shared pi/MCP tool catalogue describes these selectors to all
three harnesses.

Live delegation acceptance is separately opt-in and spends real provider usage:
`ARRAY_DELEGATION_LIVE=1 scripts/check-cross-harness-live.sh`. It is never part of
the default matrix. It mounts an isolated workspace without opening a window and
uses the production supervisor, runner factory and workspace MCP host with the
user's signed-in CLIs. Catalogue membership is live-probed; named Haiku/mini
models are preferred when offered. Exact catalogue ids can be selected using
`ARRAY_DELEGATION_LIVE_CLAUDE_MODEL` / `ARRAY_DELEGATION_LIVE_CODEX_MODEL` /
`ARRAY_DELEGATION_LIVE_PI_MODEL`. Add `ARRAY_DELEGATION_LIVE_PI=1` for Claude → Pi.
`ARRAY_DELEGATION_LIVE_OUT` chooses the evidence directory. The witness requires
actual child replies, parent tool calls and answers, selected record identities,
and delegation chips; a cross-harness follow-up asks the child's own runner for
a second answer. Missing auth, unavailable models and exhausted usage fail visibly.

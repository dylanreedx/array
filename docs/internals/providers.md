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

## 2. Managed agent tiles (claude CLI or pi)

Headless runs driven by `AgentSupervisor` → a runner behind the `AgentRunning`
seam. `AgentSupervisor.productionRunner(for:)` (the default `makeRunner`)
routes each agent to the runtime the machine actually has:

- **claude CLI** (`ClaudeAgentRunner`) — for `anthropic/*` models when the
  `claude` binary is installed. Spawns the user's own `claude -p
  --output-format stream-json` headlessly; the binary does its own
  subscription OAuth. **This is the preferred anthropic path**: it runs on the
  user's Claude subscription (no extra metering) and needs no pi. Session
  continuity is DERIVED, not stored — the agent's UUID is the claude session
  id; each run tries `--resume <uuid>`, and the first-ever turn's "No
  conversation found" failure (instant, no API call) retries once as
  `--session-id <uuid>`.
- **pi** (`PiAgentRunner`) — for everything else (`@earendil-works/pi-coding-agent`,
  host-installed npm CLI, needs node — NOT bundled). Multi-provider runtime;
  provider auth happens inside pi via `/login <provider>` (OAuth). Its
  anthropic path is an API route (metered separately) and is the fallback only
  when `claude` is absent.

Provider auth is always the CLI's own login — never API keys (owner rule).

- **Model catalogue**: `AgentModelCatalog` probes `pi --list-models` once per
  real-app launch (bounded, pi lists only authed providers) AND `claude auth
  status --json` (union in the claude alias models when signed in). Ids are
  exact `provider/model` strings — `--model` takes a pattern and partial ids
  fuzzy-match (P0.10). QA never probes and sees the frozen fallback in
  `AgentModelConfig.fallbackModelOptions`. The probe machinery is `#if
  os(macOS)` (it spawns `Process`); the pure parse/options surface is shared.
- **Readiness**: `pi auth check --provider X --json --no-refresh` and `claude
  auth status --json`, surfaced as onboarding rows.

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
  headless tile (claude `--dangerously-skip-permissions`, pi role tools).

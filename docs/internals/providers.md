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

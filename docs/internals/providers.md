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

## 2. Managed agent tiles (pi)

Headless runs driven by `AgentSupervisor` → `PiAgentRunner` through **pi**
(`@earendil-works/pi-coding-agent`, host-installed npm CLI, needs node — NOT
bundled). pi is a multi-provider agent runtime; provider auth happens inside
pi via `/login <provider>` (OAuth — never API keys, owner rule).

- **Model catalogue**: `AgentModelCatalog` probes `pi --list-models` once per
  real-app launch (bounded); pi lists only models whose provider is authed.
  Ids are exact `provider/model` strings — `--model` takes a pattern and
  partial ids fuzzy-match (P0.10). QA never probes and sees the frozen
  fallback in `AgentModelConfig.fallbackModelOptions`.
- **Readiness**: `pi auth check --provider X --json --no-refresh`, surfaced
  as onboarding rows.

## Onboarding surface

The Environment Setup panel (first run + Help menu) probes: claude, codex,
pi (install guidance), per-provider pi auth (CLI login guidance), tmux, git
CLT. `OnboardingPanel.liveProbes` is the single source.

## Open fork (owner decision pending)

Friends don't know pi. Either bundle pi+node with Array, or teach managed
agents to use the CLIs users already install as backends
(`claude -p --output-format stream-json`, `codex exec --json`), preferring pi
when present. Current lean: CLI backends. Plan:
[.plans/01-provider-cli-backends.md](../../.plans/01-provider-cli-backends.md).

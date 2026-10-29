# 101 — Design options: accounts and usage limits

Research and design round, 2026-10-29. Nothing is built. Probes ran on
claude 2.1.312, codex-cli 0.165.0, pi 1.4.0, read-only against the real logins.
Every account experiment used throwaway dirs under `/tmp`. No login was changed.

## What we measured

### 1. Which account each CLI is using

- **Claude.** `claude auth status --json` gives `email`, `orgId`, `orgName`,
  `subscriptionType` (`max`) and `configDirectory`. Array already runs it for
  readiness (`AgentModelCatalog.swift:517`) and throws the identity away.
  Inside a live session, the `get_status` control request returns the same rows
  (login method "Claude Max account", organisation, email) with no model turn.
- **Codex.** App-server `account/read` returns `{type: chatgpt, email,
  planType}`. Measured here: `prolite`, a different email from Claude's. It also
  pushes `account/updated` when the login changes. `codex login status` only
  says "Logged in using ChatGPT", with no identity.
- **Pi.** `pi auth check --provider openai-codex --json` returns
  `{status: ready, authType: oauth}`: readiness only, with no identity and no
  limits. Pi keeps its own OAuth in `~/.pi/agent/auth.json`, separate from the
  codex CLI's login, even though both spend ChatGPT credits.
- **Noticing a change made outside Array.** A Claude login rewrites
  `~/.claude.json` (the `oauthAccount` block) and the keychain item. A Codex
  login rewrites `$CODEX_HOME/auth.json` and the app-server says
  `account/updated`. So: watch those files, re-run the identity probe on
  app activation and at every turn start, and compare `orgId`/email. This is
  cheap: one `auth status` call takes about 0.3s.

### 2. Two Claude accounts on one Mac: yes, through separate config dirs

- From the CLI's own source (2.1.312): the keychain service name is
  `Claude Code-credentials` for the default dir. When `CLAUDE_CONFIG_DIR` is
  set, it becomes `Claude Code-credentials-<first 8 hex of sha256(dir)>`. So
  each config dir has its own keychain item.
- Measured: a fresh `CLAUDE_CONFIG_DIR=/tmp/…/claude-b` reports
  `loggedIn: false` while the default dir stays signed in as the Max account. So
  the two do not share a login.
- **Not proven end to end.** A second real login was not created, because that
  needs Dylan's team credentials in a browser. The isolation is shown from the
  read side and the source; the write side is inferred.
- One more env var exists: `CLAUDE_SECURESTORAGE_CONFIG_DIR` separates the
  keychain item from the config dir. With it, one config dir (sessions,
  settings) can use another dir's login. Measured: it read the Max token from a
  different config dir. But `auth status` then shows `email: null`, because the
  email is cached in the config dir's `.claude.json`, not in the keychain. It is
  undocumented. Use it only if separate config dirs prove too painful.

### 3. Where the 5h and weekly figures come from today

- Reader: `ClaudeEventTranslator` turns stream-json `rate_limit_event` into
  `AgentAccountQuota.claudeSnapshot` (`AgentAccountQuota.swift`). Codex's
  `account/rateLimits/updated` goes through `codexSnapshot`. `AgentSupervisor`
  files the result **by harness** (`accountQuotas[harness]`, line ~1993) and
  persists it to `account-quotas.json`. The hover panel is that snapshot's
  `detailText`, shown as a plain tooltip.
- So today a reading exists only after a turn runs, and there is one reading
  per CLI, never one per account.
- **Claude can be read on demand, per account, with no turn.** The
  `get_usage` control request (marked experimental) with `skip_behaviors: true`
  returned live data: `five_hour 16% (resets 22:10Z)`, `seven_day 7%`,
  `extra_usage 37%`, plus `subscription_type`. Run inside a config dir, it reads
  that dir's account. For a signed-out dir it returned no windows.
- **Codex can too.** `account/rateLimits/read` returned the weekly window
  (`usedPercent 50`, 10080 min), credits (`balance "0"`, `hasCredits false`) and
  `accountId`, with no turn. This plan has no 5-hour window, so Codex shows
  weekly only.
- **Pi exposes nothing.** It has no limits and no identity. Array can only say
  "pi uses your ChatGPT login (openai-codex)".

### 4. What switching mid-run can safely mean

- Each managed Claude agent is one long-lived `claude -p --input-format
  stream-json` process (`ClaudeAgentRunner.swift:175`). Its login is fixed for
  the life of that process. So a switch means: let the current turn finish, end
  the process, then respawn it in the new account's config dir with `--resume`.
  **Turn boundary only.**
- Measured: session lookup is scoped to the config dir. Resuming an id that
  lives only in dir B, from dir C, gives "No conversation found". After copying
  the `.jsonl` into C's `projects/<cwd-slug>/`, `--resume` under the real Max
  login recalled the codeword planted in the copied conversation
  (`PELICAN-7`). **The conversation survives a switch if Array copies the
  session file first.** It is the same session id, and the file keeps growing
  in the new dir.
- Costs of a switch: the prompt cache is per account, so the first turn
  re-reads the whole context against the new account's limit (273k tokens on
  today's agent). Subagent sidecar files and tool-result spill files also live
  under the session dir and must be copied with it (not measured).
- Codex to Claude stays a fresh start, as it is today. Switching account is
  never a reason to switch CLI.

### 5. What to do near a limit

| Behaviour | Good | Risk |
|---|---|---|
| Warn | Never surprises; no new machinery | Overnight agents still stall; nobody is there to read the warning |
| Suggest a switch | One click, at a turn boundary; Dylan decides | Same overnight gap; one more control near the composer |
| Auto-switch to the account with headroom | Overnight work keeps going | Spends the **team** plan on personal work (or the reverse), which is an employer policy and data question; re-reads the cache on the new account; can flap near thresholds; silent unless shown loudly |

## The options

### Option 1 — Name it and warn (one login per CLI)

- Account model: unchanged. One login per CLI. Array shows **which** account
  each CLI is signed into, and polls `get_usage` / `account/rateLimits/read`
  so the figures are live without waiting for a turn.
- Switching: Array opens the CLI's own login in a terminal tile. Every agent of
  that CLI moves together, and Array restarts each one at its next turn
  boundary so none keeps the old login.
- Near a limit: amber at 25% left, red at 10% left, plus an Array alert once
  per window.
- Image: `option-1-quiet-pills.png`.

### Option 2 — Pinned accounts, suggested switch (recommended)

- Account model: Array knows **accounts**, not credentials. Each account is a
  config dir. "Personal" is the default `~/.claude`. "Work" is a dir Array owns
  under Application Support, signed in once through
  `CLAUDE_CONFIG_DIR=… claude auth login` in a terminal tile. Each workspace has
  a default account and each agent inherits it, so Dylan rarely chooses.
- Switching: from the hover card, "Use Work for this agent". It applies at the
  turn boundary: copy the session file, respawn with `--resume`.
- Near a limit: the row offers "Work next turn?" when the other account has
  headroom. It never switches by itself.
- Settings stay shared: the Work dir symlinks `settings.json`, `CLAUDE.md`,
  `agents/`, `skills/`, `commands/` back to `~/.claude`, so the two accounts do
  not drift (needs a check in the build).
- Image: `option-2-account-bars.png`.

### Option 3 — Auto-route by headroom

- Option 2's account model, plus a per-workspace "auto-switch at turn end". At
  each turn start Array picks the default account unless its 5h or weekly is
  over the line, and moves back after the reset.
- The row is one capsule naming the account currently in use. The card says
  when and why it moved.
- Image: `option-3-account-gauge.png`.

## The images

Each PNG shows light and dark, the normal state with the hover card open, and
the near-limit state. They were drawn by Array's own `AgentStatusPillView`,
`AgentRadialContextMeterView`, surface/text/line/accent tokens, `Space`,
`Radius`, `Inset` and type roles, inside a mock compose strip. Every figure is
"left", not "used", because remaining is what Dylan asked to see. The render
source is kept as `render-options.swift.txt` and is not compiled.

- `option-1-quiet-pills.png` — today's pills, reworded to `% left`; the card
  names the account and gives 5h and weekly the same bar-plus-reset layout.
- `option-2-account-bars.png` — an account chip (`Max`) and two bar pills; the
  card adds the other account's two bars and the switch action.
- `option-3-account-gauge.png` — one capsule: account, two stacked bars, both
  numbers; the near-limit frame shows it after an automatic move to Work.

## Recommendation: Option 2

- It answers the night of 2026-10-28: the agents' account is visible on every
  tile, not hidden in a CLI.
- Dylan mostly won't think about it: the workspace default carries the choice.
  5h and weekly remaining are always on the row, and both get the same layout
  in the card.
- It keeps the human decision on **which employer's plan pays**. Option 3 can
  be added later as a per-workspace switch on the same machinery, once Dylan
  has decided whether personal and team work may mix.
- It is the smallest option that makes two accounts real. Option 1 still forces
  one global login.

## What a build of Option 2 would change

1. Core: an `AgentAccount` value (id, label, harness, config dir path, cached
   identity: email, org, plan). Stored in app-level state, channel-split, never
   in `.array/`. It holds no tokens.
2. `AgentRecord` gets an optional `accountId`; the workspace gets a default.
   Classify both keys in `WorkspaceAPIExposure`.
3. `ClaudeAgentRunner.childEnvironment` sets `CLAUDE_CONFIG_DIR` for a
   non-default account. The comment there says not to touch it; that changes,
   with the reason.
4. Account identity probe per config dir (`auth status --json`). Re-run it on
   app activation, at turn start, and when `.claude.json` changes.
5. Quota keyed by **account**, not harness: `accountQuotas[accountId]`. Polled
   through `get_usage` (Claude) and `account/rateLimits/read` (Codex) on a slow
   timer while any agent of that account is visible, and still updated from
   `rate_limit_event`. `account-quotas.json` gains the key; old files migrate
   by harness to the default account.
6. Switch at turn boundary: copy the session `.jsonl` (and its sidecar dir)
   into the target dir's `projects/<slug>/`, end the process, respawn with
   `--resume`.
7. "Add account" opens a terminal tile running the CLI's own login with the new
   config dir. Settings symlinks are created at the same time.
8. UI: the account chip and bar pills in `AgentCompactStatusRowView`, and the
   hover card replacing the plain tooltip (both are new `TokenThemed` views:
   hazard 8 applies). The switch action uses `ChoiceButton` /
   `ChoicePopoverController`.
9. Near-limit alert: a new path in `docs/internals/notification-paths.md`.

## Witnesses it would need

- CoreChecks: the `get_usage` parser (fraction vs percent, `extra_usage`,
  missing windows, signed out) against a captured fixture from 2.1.312.
- CoreChecks: quota keyed by account. Two accounts on one harness never
  overwrite each other; old `account-quotas.json` migrates.
- CoreChecks: the switch plan copies the session file and resumes with the
  same id. Assert the file exists in the target dir and the respawn argv has
  `--resume <id>` and the new `CLAUDE_CONFIG_DIR`.
- CoreChecks: the runner environment sets `CLAUDE_CONFIG_DIR` only for a
  non-default account, and never sets `HOME`.
- App self-check: a switch requested mid-turn waits for the turn end, driven
  through the real runner seam with a fixture CLI.
- App self-check: the row and hover card in light and dark, in an
  appearance-sweep surface and an adopted surface (ui-probe census).
- App self-check: the near-limit alert fires once per window and stays quiet
  in QA.
- Live acceptance (manual, Dylan): sign the Work account into its own dir and
  confirm `auth status` names it while Personal is unchanged.

## Unproven

- A second real Claude login in a separate config dir. Isolation is proven from
  the read side and the CLI source, not by an actual second sign-in.
- Whether Team plans report the same `five_hour` / `seven_day` windows as Max.
- Copying subagent and tool-result sidecar files with a session.
- How long `get_usage` keeps working: the CLI marks it experimental, and
  `get_status` is internal.
- Whether symlinked settings behave with `claude` writing to `settings.json`.
- `CLAUDE_SECURESTORAGE_CONFIG_DIR` beyond one read.

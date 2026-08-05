# pi harness inventory — night-2 facts + morning cleanup list

Explored 2026-08-05. Facts the night supervisor needs are at top; the cleanup list is a MORNING
task — nothing here gets deleted tonight.

## The wake mechanism ("delegated agent wake up")

pi core has **no** cron/daemon/scheduler. The feature lives in the locally-authored
`~/.pi/agent/extensions/harness-agents/` extension:

- `delegate_agent` tool params: `background`, `wakeOnComplete`, `scheduleCheck`, `expectedMinutes`
  (implies scheduleCheck), `repeatMinutes` (default 5), `wakeWhenAllDone`, `wakeOnFailure`,
  `wakeOnStale`, `wakeOnPartialAtDeadline`. Wait clamp: **[60s, 4h]**.
- Recommended shape (from its own WATCHES.md): `{ background: true, scheduleCheck: true,
  expectedMinutes: 5, repeatMinutes: 3 }`.
- **Watches are in-session state, not a daemon** — they wake the running parent session's turn
  loop. If the supervisor session exits, watches do nothing. The supervisor must be an
  INTERACTIVE session that stays open all night.
- Slash commands: `/agents /agent-run /agent-dispatch /agent-status /agent-log /agent-output
  /agent-watch <id> --in 10m --repeat 3m /agent-watches /agent-unwatch /agent-kill /agent-tmux`.
- Run artifacts: `<project>/.pi/agent-runs/<id>/{run.json, events.jsonl, stdout.log, stderr.log,
  final.md, summary.md, output.json}`.
- **Known gotcha (documented in ~/.pi/agent/SYSTEM.md):** a missing or `(no output)` `final.md`
  means the run FAILED (e.g. 429) even when status says `done`. Re-dispatch; never count it as a
  completed step.
- Delegated runs execute as `pi --mode json -p --no-session` subprocesses. Model/thinking come
  from the agent definition, NOT a dispatch flag — for luna-max workers, the direct `pi`
  subprocess dispatch in the handoff doc is the proven path; use delegate watches for PACING if
  preferred, not for model control.

## Facts that matter unattended

- **Defaults are already the supervisor's**: `settings.json` has `defaultModel gpt-5.6-sol`,
  `defaultThinkingLevel max`, `defaultProjectTrust always`. Plain `pi` in the repo IS a sol-max
  session.
- **`max` thinking is valid only on gpt-5.6-{sol,luna,terra}**; on 5.4/5.5 it silently clamps to
  `xhigh`. `minimal` remaps to `low` on all Codex models.
- **Cost asymmetry**: sol 5/30 per Mtok in/out; luna 0.2/1.2. The sol supervisor is 25× luna on
  input — keep the supervisor's own reading lean; let luna do the long work.
- **Retry tolerance is thin**: defaults `retry.maxRetries 3`, `baseDelayMs 2000` → ~14s of total
  backoff before `pi -p` exits nonzero. `fetch failed`/500/429 ARE retryable; quota/billing errors
  fail fast by design. **Leave `retry.provider.maxRetries` at 0** (SDK retries can swallow
  usage-limit errors). Highest-value overnight knob: raise `retry.maxRetries` to 5 and
  `baseDelayMs` to 4000 in `~/.pi/agent/settings.json`, and REVERT it in the morning.
- `mcp.json` declares the `plan` MCP server as `lifecycle: eager` (60s timeout) — every pi launch
  dials it. Worst case it stalls startup a minute; harmless otherwise. Do NOT use `-ne` on the
  supervisor (it would drop harness-agents and the wake tooling).
- Loop logs: `~/.pi/sidebar-native-ux-loop-control/continuum-overnight/`; run artifacts:
  `~/.pi/sidebar-native-ux-runs/continuum-overnight/run-*/`; auth: OAuth in `~/.pi/agent/auth.json`.

## Morning cleanup list (owner's call; touch nothing tonight)

**Agents (`~/.pi/agent/agents/`)** — 8 defined, 3 bake a model into their identity:

- `sol-code-reviewer.md` + `luna-code-reviewer.md` — byte-for-byte near-identical, only `model:`
  differs; the loops pass `--model` explicitly anyway. **Collapse to one `code-reviewer` and
  delete the pair.**
- `vesper.md` — "root master coordinator", no `tools:`/`model:` frontmatter (unlike every sibling),
  and hard-codes a dead cross-project reference to `SAVORO-AGENT-HIERARCHY.md`. **Rewrite or
  retire.**
- `luna-program-auditor.md` — load-bearing for the queue programs but misnamed; rename off the
  model prefix.
- `web-research.md` — declares `tools: search, scrape`, which only exist if the `firecrawl`
  extension loads; silently degrades otherwise.
- Keep as-is: `code-reviewer.md`, `explorer.md`, `implementer.md`.

**Extensions:**

- `disabled-extensions/` — `flow-title.ts`, `saturn-splash/`, `welcome-splash-20260605163709/`:
  all abandoned June experiments. **Highest-confidence deletions.**
- `firecrawl/` vendors a full 36-package `node_modules/` inside the config dir (which is a git
  repo); `harness-agents/node_modules/` same pattern. Consider `.gitignore` + reinstall-on-demand.
- `harness-agents/` carries 5 stale June design docs (`AGENT-REALTIME-DESIGN.md`,
  `AGENT-WATCH-TDD-PLAN.md`, `DX-OVERHAUL.md`, `COORDINATION.md`, `SMOKE.md`) — archive.
- `welcome.ts` is likely dead already (`quietStartup: true`); `status-line.ts`,
  `image-preview-editor/` are interactive-only; `handoff.ts` overlaps AGENTS.md guidance.
- `context-guard/` — verify it still does anything; README is bigger than the code.

**Stale state:**

- Broken `latest` symlinks: `~/.pi/agent-tile-ux-runs/latest` and `~/.pi/overnight-runs/latest`
  point at pre-reorganization paths (real runs live one level deeper, per-repo).
- Old run trees: `~/.pi/agent-runs/{code-reviewer,explorer,web-research}-2026061*/2026070*`,
  `~/.pi/overnight-runs/{continuum-c,continuum-fixes,continuum-revived}`,
  `~/.pi/agent-tile-ux-prep/`, `~/.pi/small-team-relay-runs/` (one July run).
- `~/.pi/agent/pi-crash.log` (114 KB, stale since June), `AGENT-PROMPT-AUDIT.md` (June one-off),
  two `.DS_Store`, empty `~/.pi/worktrees/`.

**Script generations (repo `scripts/`):** three forks of the same pi loop —
`agent-tile-ux-loop.sh` (q91) → `small-team-relay-loop.sh` (q92) → `sidebar-native-ux-loop.sh`
(q94, current, carries the dead-worker and verdict-parser fixes). Plus the older
`overnight-loop.sh` (July generation) and the non-pi `agent-ux-loop.sh` /
`overnight-orchestration-loop.sh` / `codex-primary-loop.sh`. After queue 94 closes, fold the fixes
back into one canonical loop and retire the forks.

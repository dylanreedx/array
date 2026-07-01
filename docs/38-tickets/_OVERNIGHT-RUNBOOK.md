# Overnight Execution Loop — Resume Runbook

Purpose: let the driving session resume the Ralph execution loop **deterministically from
durable state** (git + the progress file) — robust to context compaction or a session
restart. The conversation is NOT the source of truth; this file + `_PROGRESS.md` + git are.

## Prerequisite
Phase-1 authoring is done when `docs/38-tickets/README.md` exists with an
**"Overnight-executable set"** (the `autonomous`-tagged tickets in dependency order).
If it's not there yet, authoring is still running — wait for the completion notification;
do not start.

## Models & effort (per user directive)
- **Implementer = `sonnet`** — the alias resolves to the latest Sonnet, **Sonnet 5**
  (released 2026-06-30). Effort is **varied per ticket**, read from the ticket's
  Execution-mode section: pure/mechanical tickets (Phase-0 op-log, enums, pure derivation)
  run at **low**; integration/topology/reader tickets run at **medium**; anything touching
  many seams at once runs at **high**. Default when unstated: **low** (tickets are authored
  zero-guessing, so low is the design target).
- **Reviewers = dual-model.** Every diff is reviewed by **both** Claude/Opus (the internal
  Workflow review stage) **and** GPT-5.5 via the Codex CLI as an independent cross-reference:
  `codex exec --json -m gpt-5.5 --sandbox read-only "<review the staged diff against
  docs/38-tickets/<ticket>.md; list correctness/guessing/pattern gaps as JSON>"`.
  Commit only when **matrix is green AND both reviewers clear** (or every raised concern is
  resolved). If Claude and Codex disagree, treat the union of concerns as blocking.

## Operating contract (the loop's rules)
- **Scope:** only `autonomous`-tagged tickets, in dependency order. `supervised` /
  `needs-substrate` → skip, list them for the morning report.
- **Per iteration = one internal Workflow:** implement (`sonnet`, per-ticket effort) →
  `swift build` + `./scripts/run-matrix.sh` → **Opus review + Codex gpt-5.5 cross-review**
  of the diff → bounded fix attempts if red/rejected → commit only if green **and both
  reviewers clear**. **No fake-green** — if it can't be honestly verified, stop that ticket,
  log why, move on.
- **Unit:** one ticket per iteration, or a few tightly-coupled small ones consolidated.
- **Commits:** one per ticket, plain `type(scope): summary`, **no co-authoring footer**.
  **Local only — never push.**
- **Branch:** `overnight/agent-orchestration` (cut after the planning docs are committed).
  Never `main`, never `feature/component-lab`.
- **Driver:** the bash harness `scripts/overnight-orchestration-loop.sh` (forked from the
  proven `overnight-loop.sh`). It runs one fresh `claude -p` (Sonnet 5) per ticket, each of
  which runs the internal per-ticket Workflow. State is git + `_PROGRESS.md`; it survives
  this session dying. Per-run artifacts live under `~/.pi/overnight-runs/continuum-revived/
  run-<stamp>/` (`status.json`, `events.jsonl`, `report.md`, `logs/iter-*.log`).
- **Resilience:** an iteration that breaks (unfixable build, workflow failure) is logged and
  the ticket is **skipped**, loop continues (`LOOP: CONTINUE skipped:<ticket>`). Usage-limit
  / provider errors trigger a 45-min back-off and retry (`MAX_SOFT_FAIL` consecutive → halt).
  A per-iteration timeout watchdog kills a hung iteration. `touch STOP` halts cleanly.

## The moving parts (file map)
- `scripts/overnight-orchestration-loop.sh` — the driver (loop, artifacts, guards, back-off).
- `scripts/overnight-orchestration-prompt.md` — what each `claude -p` iteration does: load
  state → pick the next ready `autonomous` ticket → run the Workflow → record → emit a
  `LOOP:` token.
- `scripts/overnight-iteration-wf.js` — the per-ticket internal Workflow: implement (Sonnet 5
  @ per-ticket effort) → `swift build` + `./scripts/run-matrix.sh` → parallel Opus + Codex
  gpt-5.5 review of the diff → commit iff all green and both clear.
- `docs/38-tickets/_PROGRESS.md` — the durable per-ticket ledger (source of truth for "done").

## Where it runs
An **isolated git worktree** at `/Users/dylan/Documents/personal/continuum-overnight`, on
branch `overnight/agent-orchestration` (based off `feature/component-lab` HEAD, so the tickets
match the tree they were authored against). The primary checkout stays clean on
`feature/component-lab`. Review the worktree in the morning; merge to `main` when ready.

## Launch / resume protocol
The loop is stateless across restarts — starting and resuming are the **same command**,
run from inside the worktree:
1. `cd /Users/dylan/Documents/personal/continuum-overnight` (clean tree, planning docs committed).
2. `caffeinate -is ./scripts/overnight-orchestration-loop.sh`
   (dry-run one ticket first with `MAX_ITER=1 ...`, inspect the commit + the run log, then
   launch the full run).
3. The harness + the iteration prompt derive remaining work from `_PROGRESS.md` + `git log`,
   so a re-run simply picks up the next not-done ticket. `touch STOP` to halt.

## `_PROGRESS.md` row format
`| <ticket filename> | done|skipped|in-progress | <commit hash or -> | matrix: green|red|n/a | <note> |`

## Stop conditions
Queue drained · usage exhausted · too many consecutive failures. On stop: finalize
`docs/38-tickets/MORNING-REPORT.md` (done / skipped / commits / what needs the owner).

## Guardrails (never violate)
Autonomous-only · local commits, no push · no co-authoring · no fake-green · matrix green
AND both reviewers (Opus + Codex gpt-5.5) clear before commit · stay on the overnight branch.

# Handoff — agent-orchestration overnight execution (2026-07-01 ~20:31 EDT)

Written because we're about to hit usage limits. This lets a fresh session (or Dylan) pick up
cold. Companion docs: [`_OVERNIGHT-RUNBOOK.md`](_OVERNIGHT-RUNBOOK.md) (resume mechanics),
[`_PROGRESS.md`](_PROGRESS.md) (per-ticket ledger), and memory `overnight-execution-run-state`.

## TL;DR
- **Two layers of process.** (1) A **detached bash loop** (`scripts/overnight-orchestration-loop.sh`,
  running under `caffeinate`) drives tickets autonomously — it is **self-healing across usage
  limits** (detects the quota signature, sleeps 45 min, retries; `MAX_SOFT_FAIL=10`). It keeps
  running even if the monitoring Claude session dies. (2) A **monitoring Claude session** (me) checks
  on it every ~20–30 min via `ScheduleWakeup` and intervenes on bugs. The monitor is what the usage
  limit interrupts — **not** the loop.
- **When the limit hits:** the loop's in-flight `claude -p` iteration fails → harness quota-sleeps
  45 min → resumes after reset. Nothing to do but let it ride, OR `touch STOP` in the worktree to
  halt cleanly. The monitor session can resume later from this doc + `_PROGRESS.md` + `git log`.

## Where everything lives
- **Worktree (all work happens here):** `/Users/dylan/Documents/personal/continuum-overnight`,
  branch `overnight/agent-orchestration` (based off `feature/component-lab`). **Primary checkout**
  `/Users/dylan/Documents/personal/continuum-revived` stays clean on `feature/component-lab` — do
  not run the loop there.
- **Harness:** `scripts/overnight-orchestration-loop.sh` (driver), `-prompt.md` (per-iteration
  instructions), `overnight-iteration-wf.js` (the per-ticket Workflow: implement→build+matrix→
  review→commit with 3-round self-repair).
- **Tickets:** `docs/38-tickets/*.md` (74). Queue + ledger: `README.md`, `_PROGRESS.md`.
- **Run artifacts:** `~/.pi/overnight-runs/continuum-overnight/run-*/` (`status.json`,
  `events.jsonl`, `report.md`, `logs/iter-*.log`).
- **Rejected attempts:** **11 stashes** (`git -C <worktree> stash list`) — salvage material for the
  skipped tickets.

## Model config (Dylan's chosen mapping)
- **Fable 5 orchestrates** each iteration (`CLAUDE_MODEL=fable` in loop.sh → `claude -p --model fable`).
- **Sonnet 5 implements** (`model:'sonnet'` in wf.js implement/fix stages).
- **Reviewers: real Opus + GPT-5.5 via Codex CLI** (`model:'opus'` + `codex exec -m gpt-5.5`), both
  must clear to commit.

## Status right now (20:31 EDT)
- **Done (committed):** `01-store-protocol-seam` (`c71d601`), `02-op-enum-logged-op-envelope` (`a4cba75`).
  ⚠️ Both still owe a **supervised full-matrix pass** (see Verification below).
- **Skipped — DYLAN'S HANDS (do NOT let the loop retry):** `03-membership-tile-register`,
  `04-zorder-fractional-index`, `05-delete-tombstone`. Migration re-models with real correctness
  bugs *and* a scope tension (the correct fix needs edits their own "Stop if" fences forbid). Per-
  ticket bug notes are in `_PROGRESS.md`.
- **pending-retry (loop is re-driving now, unblocked by today's fixes):** `08-sync-observation-type-split`
  (in progress, ~32 min into its attempt as of writing), `10-session-topology-snapshot`,
  `12-injectable-substrates`.
- **Blocked (deps unmet):** 06, 07, 09, 11, 13 (depend on skipped tickets) — auto-skip fast.
- **Not yet reached:** 14–74 (topology, de-mirror, readers 31–43, activity surface, remote, sync,
  managed agents). The **readers/pure-fn block (31–43)** is the next big *additive* stretch and
  should be productive if 08/10/12 land.

## Punch-list — what's resolved vs OPEN
RESOLVED + committed today:
1. **Headless environment blocker** → the matrix's terminal-surface checks time out headless; the
   loop now runs with `CONTINUUM_SKIP_SURFACE_CHECKS=1` (skips 4 surface-rendering checks, deferred
   to a supervised GUI matrix pass). `run-matrix.sh` change committed.
2. **Verification-harness policy** (`417b77c`): the repo has **no XCTest** — all checks are `*Checks`
   executables run by `run-matrix.sh`. The loop now **enforces** this (implement + both reviewers)
   and **rejects XCTest** and any diff that weakens `run-matrix.sh`.
3. **Ticket 10 ruling** (`feded6b`): empty/whitespace input = a **zero-session snapshot**, not an
   error. `emptyInput` removed.
4. **Ticket 12 ruling** (`feded6b`): **reuse ticket 02's `OpId`**; name the transport envelope
   **`TransportLoggedOp { opId; payload: Data }`** (ticket 02 already owns `LoggedOp`).

**OPEN — needs Dylan (the last item, not yet discussed):**
- **03/04/05 migration scope fences.** These re-model existing types (`Tile.zoneId`, z-order→
  `FracIndex`, delete→tombstone) and migrate call sites, but the *correct* fix requires editing
  files the ticket's own "Stop if" fence forbids (e.g. `ProjectStore.saveCanvas` for the schema
  re-stamp). Decision needed: **loosen each ticket's scope fence** to permit the required edits (and
  specify the schema-version/migration contract), or **re-partition** the schema-bump into its own
  ticket. This is a real design call — walk through it with Dylan; don't automate.

## Hard-won lessons (bugs found + fixed — all on the branch)
- Implementer was pointed at the wrong repo checkout → fixed (`eb7d4fe`).
- Loop livelocked re-picking a skipped head-of-queue ticket → skipped tickets are never re-attempted;
  halt on repeated same-ticket skip (`05d6e64`).
- `claude -p` kills background tasks (the Workflow) at 600 s → `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`
  (`4db0cf1`).
- LOOP token missed when the model wrapped it in markdown backticks → parser strips them (`a5daf4b`).
- Workflow `args` can arrive as a string → wf.js parses it; ticket path passed as a real object.
- A **pre-existing repo bug**: a check `exit(1)`'d on a schema mismatch and silently skipped half the
  matrix suite on every run → fixed (`f42102a`). Worth Dylan's awareness.
- **Pattern:** pure/additive tickets commit; anything invasive (migration/schema/wiring) surfaces
  real bugs that the multi-model review correctly refuses to fake-green. The loop is an excellent
  **bug-finder**; it commits the tractable tickets and honestly flags the rest.

## Liveness heuristic (don't misread a stall)
The orchestrator `claude -p` **sleeps at ~0.1% CPU while its subagents do the work** — low CPU is NOT
a stall. Judge liveness by the newest subagent transcript mtime under
`~/.claude/projects/-Users-dylan-Documents-personal-continuum-overnight/*/subagents/workflows/wf_*/agent-*.jsonl`.
A real stall = no subagent transcript change for ~15+ min AND no `swift build`/`codex` process AND a
static worktree. (Iterations legitimately run 30–60+ min with the 3-round self-repair.)

## Verification model (important nuance)
The loop's matrix is **headless** — it skips the 4 terminal-surface checks. So a loop commit is
"green on everything runnable headless." Each committed ticket **owes a supervised full-matrix pass**
on a GUI-capable machine: `cd <worktree> && git stash any-dirt && ./scripts/run-matrix.sh` (NO
`CONTINUUM_SKIP_SURFACE_CHECKS`). Tickets 01 and 02 currently owe this. Run it before merging to
`main`.

## How to resume
- **Check on the loop:** read the newest `~/.pi/overnight-runs/continuum-overnight/run-*/status.json`
  + `report.md`, and `git -C <worktree> log --oneline` (new `feat`/`fix` commits = tickets landed).
- **If the loop stopped and should continue:** `cd <worktree> && caffeinate -is
  ./scripts/overnight-orchestration-loop.sh` — it resumes from `_PROGRESS.md` (skips done + skipped +
  the migration tickets). Confirm `model=fable` in its start banner.
- **To halt cleanly:** `touch <worktree>/STOP`.
- **Resume the MONITOR session:** re-read this file + `_PROGRESS.md` + memory; `ScheduleWakeup` ~30 min
  to keep checking. Do NOT re-attempt 03/04/05. Do NOT resume the paused authoring workflow
  `wf_d8919787-218`.

## Next actions in priority order
1. Let the loop finish validating **08/10/12** (should commit now — first productive commits since
   hardening). Report which land.
2. On any commit, run the **supervised full matrix** to cover the deferred surface checks.
3. Let the loop roll into the **readers/pure-fn block (31–43)** — the next productive stretch.
4. With Dylan: settle the **03/04/05 scope fences** (the OPEN decision), then reset those to
   pending-retry so the loop (or Dylan) can complete them.
5. Before merging to `main`: full supervised matrix on the whole branch; review the 11 stashes for
   salvage; decide whether to merge the whole branch or cherry-pick.

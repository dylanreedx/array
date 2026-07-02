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
- **Reviewers for the new runner:** **Fable 5** is the Claude-side reviewer/adjudicator; **GPT-5.5 via Codex CLI** is the independent cross-reviewer. Both review lanes must clear to commit.

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

---

## Update — dry-run packetization + ZERO-Workflow preparation (2026-07-01 ~20:50 EDT)

This section supersedes the older “loop is self-healing across usage limits” assumption above for the
current run. The active Fable iteration hit a provider/session limit and the harness stopped, not slept:

- Run: `~/.pi/overnight-runs/continuum-overnight/run-20260701T195840`
- Status: `stopped`, reason `harness-malformed-output`
- Log tail: `You've hit your session limit · resets 10:10pm (America/Toronto)`
- Why: the quota regex looked for `usage limit` but this provider emitted `session limit`, so the loop
  did not classify it as provider quota.
- `STOP` is present in the worktree intentionally. Remove it only when deliberately starting a new loop.

Current tree state must be handled before any new implementation attempt:

```text
A Sources/ContinuumRevivedCore/ActivityStore.swift
A Sources/ContinuumRevivedCore/AgentActivityEvent.swift
A Sources/ContinuumRevivedCoreChecks/ActivityStoreTests.swift
M Sources/ContinuumRevivedCoreChecks/main.swift
```

Treat this as a `dirty-attempt` for ticket 08. Do not start a fresh ticket until Fable/Dylan chooses one
of: continue the attempt after reset, stash it as a rejected attempt, or discard it explicitly.

### Dry-run subagents dispatched

Read-only agents inspected the first ten tickets and the current orchestration harness. Artifacts:

- `explorer-20260702T004047Z-4090dd` — tickets 01–05 implementor packets and 03/04/05 conflict split
  plan. Final: `.pi/agent-runs/explorer-20260702T004047Z-4090dd/final.md`
- `explorer-20260702T004047Z-c55974` — tickets 06–10 path maps, acceptance gates, dependency blockers,
  and ambiguities. Final: `.pi/agent-runs/explorer-20260702T004047Z-c55974/final.md`
- `code-reviewer-20260702T004047Z-7f156b` — deterministic QA packet + conflict taxonomy. Final:
  `.pi/agent-runs/code-reviewer-20260702T004047Z-7f156b/final.md`
- `code-reviewer-20260702T004047Z-286ce7` — ZERO-Workflow handoff format and recovery statuses. Final:
  `.pi/agent-runs/code-reviewer-20260702T004047Z-286ce7/final.md`

### New companion docs created

- [`_CONFLICT_LOG.md`](_CONFLICT_LOG.md) — reason-code taxonomy and initial entries for 03, 04, 05,
  current dirty 08, stale 10 ruling, and dependency-blocked 06/07/09.
- [`_IMPLEMENTOR_PACKETS_01-10.md`](_IMPLEMENTOR_PACKETS_01-10.md) — digestible per-ticket packets for
  the first ten tickets. These **supplement** the original tickets; they do not remove or weaken any
  original directive.

### Key conclusion from the dry run

Use richer states than `done/skipped/pending`:

```text
done
done-headless
dirty-attempt
conflicted-needs-amendment
blocked-dep
verification-conflict
stale-doc-conflict
terminal-skip
provider-quota
harness-fail
```

For the first ten tickets:

- 01/02 are genuinely done, with supervised GUI matrix debt.
- 03/04 are `conflicted-needs-amendment`: correct fixes require scope/schema migration decisions and
  should be split before unattended retry.
- 05 is mostly retryable, but needs file-hygiene and scope guards; do not drift into ticket 06.
- 06/07 are `blocked-dep` until 03/04/05 semantics land.
- 08 is `dirty-attempt` right now.
- 09 is `blocked-dep` on 08 and needs a geometry-integer taint clarification.
- 10 is retryable only with the explicit ruling: empty/whitespace tmux output is a zero-session snapshot;
  no `ParseError.emptyInput`.

### ZERO-Workflow direction

Dylan's current preference: the next overnight runner should be Ralph-style shell orchestration with
visible subprocesses and logs, **not** Claude `Workflow(...)` inside a session. Fable 5 should act as the
outer adjudicator/selector/classifier and Claude-side reviewer; Sonnet 5 should remain the default Claude implementer when available; GPT-5.5 can be used as a low/medium implementation fallback because the packets are now explicit, and should remain the independent cross-reviewer. The new review lane is Fable + GPT-5.5 only. Every
stage should append durable JSONL events and a QA packet.

Do not resume `scripts/overnight-iteration-wf.js` for the redesigned loop unless Dylan explicitly opts
back into the legacy Workflow-based harness.

Minimum next implementation work before a full overnight run:

1. Classify or preserve the current dirty ticket-08 attempt.
2. Patch provider-limit detection to include `session limit` if continuing the legacy harness.
3. Build a no-Workflow Ralph iteration script with explicit stages:
   select → implement → build → matrix → Fable review → GPT-5.5 review → Fable adjudicate/repair →
   commit or conflict-log.
4. Teach the selector to read `_CONFLICT_LOG.md` and `_IMPLEMENTOR_PACKETS_01-10.md`.
5. Split/amend 03/04/05 before retrying them unattended.

### Local visual plan for morning review

A local-files Agent-Native Plan was created for the full morning scope. It is repo-owned/local-only
(no hosted Plan DB write) and validated with `plan local verify`.

- Plan folder: `docs/38-tickets/visual-plan-morning-scope/`
- Source: `docs/38-tickets/visual-plan-morning-scope/plan.mdx`
- URL file: `docs/38-tickets/visual-plan-morning-scope/.plan-url`
- Local bridge PID file: `docs/38-tickets/visual-plan-morning-scope/.plan-serve.pid`
- Serve log: `docs/38-tickets/visual-plan-morning-scope/.plan-serve.log`

Open the URL from `.plan-url` in Chrome/Chromium/Edge while the local bridge is running. If the bridge
is not running, restart it from the worktree:

```bash
npx @agent-native/core@latest plan local serve \
  --dir docs/38-tickets/visual-plan-morning-scope \
  --port 47832 \
  --url-file docs/38-tickets/visual-plan-morning-scope/.plan-url
```


### Overnight throughput target and model schedule

Dylan's target is aggressive: by morning, all **autonomous and unblocked** tickets should be either
committed or honestly classified, unless provider/session usage limits stop the run. Do not count
`supervised`, `needs-substrate`, or dependency-blocked tickets as implementable unattended work; those
should be packeted/deferred with clear reason codes instead of fake-greened.

Preferred lane schedule:

1. **Reset → ~12:30am:** Fable selects/reviews/adjudicates; Sonnet implements high-risk or Claude-native
   tickets; GPT-5.5 can implement low-risk packets if Claude quota is tight.
2. **~12:30am → ~4:30am:** GPT-5.5 fallback implementation lane for low/medium well-packeted tickets;
   Fable checks in periodically for selection/classification when quota allows.
3. **~4:30am → ~8:15am:** Fable wrap-up/audit/morning report; avoid starting risky migrations late.
4. **8:15am → 8:45am:** Dylan review window: inspect done count, conflicts, dirty state, and supervised
   GUI matrix debt.

Throughput expectation: 08/10/05 are the immediate targets; 03/04 must be split; 06/07/09 remain blocked
until their dependencies land. The success metric is not “all 74 literally implemented,” because the
set includes supervised and needs-substrate tickets; it is “all unattended-safe work landed or classified.”

### Immediate runner patch (Fable review + quota regex)

The legacy harness has been patched enough to resume ticket 08 if Dylan chooses the fast path tonight:

- `scripts/overnight-iteration-wf.js`: Claude-side review lane now uses **Fable** instead of Opus.
- `scripts/overnight-orchestration-prompt.md`: reviewer wording now says **Fable + GPT-5.5**.
- `scripts/overnight-orchestration-loop.sh`: provider regex now catches `session limit` as quota/provider failure.

Caveat: this is still the **legacy Workflow-based harness**. It is not the final ZERO-Workflow Ralph
runner. Use it only if the priority is to pick up ticket 08 quickly tonight.

To resume the dirty 08 attempt with the patched legacy harness, use the fast path only after confirming
this is intentional:

```bash
cd /Users/dylan/Documents/personal/continuum-overnight
rm -f STOP
ALLOW_DIRTY=1 caffeinate -is ./scripts/overnight-orchestration-loop.sh
```

Why `ALLOW_DIRTY=1`: ticket 08 has an interrupted uncommitted attempt in the tree, and the goal is to
continue/classify that attempt rather than start from a clean checkout.

### Packetizing the remaining tickets

Read-only explorer agents have been dispatched to packetize tickets 11–74 in six chunks. When they
finish, synthesize their finals into additional implementor packet docs (for example
`_IMPLEMENTOR_PACKETS_11-20.md`, etc.) and update `_CONFLICT_LOG.md` with any newly discovered blockers.

### Packetization complete for all tickets

The remaining packetization agents completed and their final outputs were consolidated into:

- `_IMPLEMENTOR_PACKETS_11-74.md`

Together with `_IMPLEMENTOR_PACKETS_01-10.md`, every ticket now has a supplemental implementor packet or packetization notes. These are not replacements for the original tickets; they are routing/acceptance summaries for unattended agents.

Important blockers discovered in 11–74 packetization:

- 11 depends on reader/evidence types; medium autonomous if dependency/ruling is clear.
- 12 is high-risk foundational substrate work; must follow the `TransportLoggedOp` ruling.
- 15/16 overlap on `tmuxWindowTarget`; avoid duplicate schema/capture ownership.
- 17/25/26 have supervised or real-terminal gates; logic can run, full done needs dogfood/substrate.
- 31–43 are a coherent additive reader/status pipeline and likely a productive unattended stretch after 08/10/12.
- 44–47 are supervised UI surface tickets; backend/check portions can land, visual completion needs human pass.
- 48/54 are autonomous remote/auth foundations; 49–53 need SSH/remote substrate or supervised proof.
- 55/56/58/59 are autonomous sync/auth vocabulary candidates; 57/61–64 need CloudKit/iOS/APNS substrate; 60/65 have supervised gates.
- 66/67/70/74 are autonomous managed-tier candidates with canonical-type risks; 68/69 need sidecar/ACP substrate; 71–73 are supervised UI tickets.
- Before 67–73, create/confirm a managed-tier canonical types decision: `AgentRuntimeEvent`, `ApprovalDecision`, request id type, and local-only/body-carrying payload rules.

### Correction — GPT-5.5 is an implementation fallback, not read-only only

If Claude/Fable hits a session limit, do **not** interpret the downtime as read-only-only. The intended
fallback is:

1. Let the Claude/Fable loop sleep until its parsed reset time.
2. If the working tree is clean, or the current dirty attempt has been stashed/classified, use
   **Codex/GPT-5.5 to implement low/medium, well-packeted autonomous tickets**.
3. Continue to use GPT-5.5 for independent review/audit as well.
4. Do not let GPT-5.5 mix diffs into an unresolved dirty Fable attempt; classify/stash first.
5. When Fable resets, Fable resumes selection/review/adjudication and audits GPT-5.5-produced commits.

The phrase “read-only audits and prep” was too conservative; GPT-5.5 should be a real implementation
fallback where the packet quality and risk level make that safe.

### PR permission update

Dylan grants conditional permission for the final overnight orchestrator to push and open a GitHub PR if the branch reaches a coherent review state: all autonomous/unblocked tickets are landed or honestly classified, matrix/build status is documented, the tree is clean, and the morning report is complete.

Remote: `https://github.com/dylanreedx/continuum`

Rules: do not merge; do not push dirty/mixed failed-attempt diffs; do not claim supervised/needs-substrate tickets are done without evidence; PR body must include done commits, conflicts/reason codes, matrix/headless debt, mobile/TestFlight readiness, architecture walkthrough, and reviewer guide.

### 2026-07-02 model routing update — Fable unavailable, Opus primary

Dylan reports Fable is no longer available. The loop has been adapted so Claude orchestration/review defaults to **Opus**, while implementation remains delegated to **Sonnet 5** and fallback implementation/review remains **Codex/GPT-5.5**.

Changed files:

- `scripts/overnight-orchestration-loop.sh`
  - `CLAUDE_MODEL` default changed from `fable` to `opus`.
  - `CLAUDE_REVIEW_MODEL` exported, default `opus`.
- `scripts/overnight-iteration-wf.js`
  - Claude review agent now uses `CLAUDE_REVIEW_MODEL` instead of hard-coded `fable`.
  - Sonnet implementer and Codex/GPT-5.5 reviewer remain unchanged.
- `scripts/overnight-orchestration-prompt.md`
  - reviewer wording updated to Opus-by-default via `CLAUDE_REVIEW_MODEL` + GPT-5.5.

Continuation command should remove `STOP` only when Dylan wants the background loop to run again.

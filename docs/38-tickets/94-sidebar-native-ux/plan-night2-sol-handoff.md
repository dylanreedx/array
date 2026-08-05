# Night 2 handoff — Sol supervises, Luna implements, sidebar by morning

Written 2026-08-05 ~02:20Z (≈22:20 local). The owner sleeps; a `pi` session running
**openai-codex/gpt-5.6-sol at max** supervises the night. This document is the supervisor's
contract. The copy-paste prompt is in `plan-night2-sol-prompt.md` beside this file.

## Where the program stands

- **20 of 40 done**, HEAD `758b7f0`, branch `overnight/agent-ux`, local only.
- **P3.5 is mid-flight**: a repair-pass candidate sits UNCOMMITTED in the tree across
  `AgentTileStatePresenter.swift`, `AgentInboxRow.swift`, `AgentInventory.swift`,
  `CoreChecks/main.swift`. Review round 1 returned five findings (all real — vocabulary unused in
  production, phone path untouched, four-surface proof missing, I5 asserted by a print, witness not
  auditable); worker pass 2 addressed them; **review round 2 was killed mid-run by the owner's stop,
  not by a verdict**. Artifacts: `~/.pi/sidebar-native-ux-runs/continuum-overnight/run-20260804T214008/tasks/iteration-001-P3.5-status-vocabulary-unification.md/`
  (`candidate-2.diff`, `review-request-2.md` ready to re-run).
- **The loop is stopped and stays stopped.** `docs/38-tickets/94-sidebar-native-ux/STOP` is armed as
  an interlock. The loop cannot run the rest of the night anyway: every remaining autonomous ticket
  sits behind the supervised gate P3.6 in `_QUEUE.md` dependency order, and the loop refuses tickets
  whose deps aren't `done`. **The night runs in hand-drive mode** — the same worker/review/matrix/
  ledger/commit cycle, driven directly (exact commands below), with the dependency deviation recorded
  per ledger note. Precedent: the focus-session plan's "dependency deviation, stated deliberately"
  and ruling R4.
- **Gates are the owner's.** P3.6, P5.6, P7.1 are prepared, never marked done, never inferred from
  silence. P3.6's materials are complete in `qa-runs/p3.6-gate/` (REVIEW.md + gate.sh + the
  before-snapshot of the owner's own seven stale records).

## The night's goal, honestly stated

The owner asked for "the sidebar done before 6 AM" and separately for "10 tickets in 10 hours".
Three of the remaining 20 tickets are supervised gates only the owner can pass, so *done-done* by
6 AM is structurally impossible. The 10-ticket night that IS possible, and is the target:

**Land P3.5, then all of Phase 4 (P4.1–P4.5) and all of Phase 5's autonomous tickets (P5.1–P5.5),
with P3.6/P5.6 gate materials refreshed — ~31 of 40 by 6 AM, leaving the owner gates + Phase 6.**
Phase 6 (P6.1–P6.6) is the stretch; the plan's cut list says P5.2–P5.5 are cuttable and Phase 6 is
not, so if a choice is forced late in the night, prefer starting Phase 6 over polishing P5 extras.

## Schedule — check the clock at every step boundary

Times are local (UTC-4). At each boundary run `date` and compare. **Behind by more than one slot →
apply the cut order immediately** rather than hoping: drop P5.5, then P5.4, then P5.2 (P5.1 and
P5.3 stay; Phase 6 preferred over the dropped ones if time reappears).

| By | Landed |
|---|---|
| 23:00 | P3.5 (finish the interrupted review, repair if needed, matrix, commit) |
| 23:15 | P3.6 gate materials refreshed (gate.sh checks re-run against HEAD; do NOT mark done) |
| 00:30 | P4.1 + P4.2 — **one worker pass, one commit, two ledger rows** (same seam: sentinel + seed in `send(_:to:)`) |
| 01:15 | P4.3 rename guard |
| 02:00 | P4.4 derived child naming |
| 02:45 | P4.5 generated name via ruling R7 (below) |
| 03:30 | P5.1 custom row context menu |
| 04:15 | P5.2 filter band |
| 05:00 | P5.3 bulk bar · P5.4 keyboard traversal (batch if small) |
| 05:40 | P5.5 resize persistence |
| 06:00 | P5.6 + P7.1 gate-prep notes, morning review doc updated, tree clean, history read |

Budget per ticket ≈ 40–45 min: Luna max worker 25–35, Sol medium review 5–8, matrix 7 (run the
review WHILE the matrix runs — the reviewer is read-only and never builds).

## Model and thinking assignments — the owner's explicit calls

- **Supervisor (you): sol at max.**
- **Implementation workers: `openai-codex/gpt-5.6-luna --thinking max`** — the owner's standing
  preference, reaffirmed tonight.
- **Reviews: `openai-codex/gpt-5.6-sol --thinking medium`** — reviews read a diff; medium reviews
  caught every real defect today (an unfrozen freeze, a widened gate, vacuous witnesses) at a third
  of the wall clock. R6 stands for reviews.

## Rigor calibration — efficient, not gutted

The owner's words: "testing can be too rigorous at times… no need to overcomplicate." What that
means here, precisely:

- **One review round by default, two maximum.** Reviewer instructions: blocking correctness only,
  at most three findings, no style, no out-of-scope hardening. After round two, fix the remaining
  findings yourself if they are mechanical (equality-vs-prefix class), record everything in the
  ledger note, and land. Do not burn a third round-trip on assertion phrasing.
- **The packet's required negative witness only** — one mutation, and make it AUDITABLE up front so
  no reviewer bounces it: record the mutated line, the exact red message, exit code, and the
  restore sha256. P3.5's round 1 was rejected partly for an unauditable witness; the fix costs
  three lines of evidence.
- **A witness must live in a matrix-wired check.** `--managed-agent-live-check` is live-only and
  NOT in the matrix — an assertion there proves nothing (this bit us tonight; the mutation stayed
  green). When in doubt: mutate production, run the flag directly, demand red.
- **Full matrix ONCE per ticket**, `CONTINUUM_SKIP_SURFACE_CHECKS=1 CONTINUUM_SKIP_UI_BASELINES=1`,
  immediately before commit. Never re-run it for doc-only changes.
- **What never softens** (these are rails, not rigor): floors, tolerances, counts, contrast
  requirements, I5, the truncation table's rot-both-ways discipline, and baselines — no blessing,
  ever, tonight. Moved renders are recorded in the ledger note and wait for the P3.6/P5.6 gates.

## Ruling R7 — P4.5 implements against `pi` (owner-directed)

R3 blocked P4.5 because its specified `codex exec` CLI is never spawned in this repo. The owner has
since directed all 40 tickets be completed. P4.5 therefore implements the one-shot name generation
through the same provider CLI everything else uses: a **short-lived `pi` one-shot** (no session
persistence, output parsed as the candidate name, sanitized through the existing rename guard from
P4.3, best-effort per design decision 9 — a failure degrades to the P4.2 seed, never blocks). Record
this ruling in the P4.5 ledger note. Design decision 9 already makes naming best-effort, so the
substitution changes the vehicle, not the contract.

## First five minutes — resilience tuning (revert in the morning)

Today's provider failures (`fetch failed`, Codex 500s) exceeded pi's default ~14s of retry
tolerance (`retry.maxRetries 3`, `baseDelayMs 2000`). Before the first ticket, edit
`~/.pi/agent/settings.json`: set `"retry": {"maxRetries": 5, "baseDelayMs": 4000}` — and leave
`retry.provider.maxRetries` alone at 0 (SDK-level retries can swallow usage-limit errors; that
warning is pi's own). Note the change in the morning doc so the owner can revert it. Cost
awareness while you're there: you (sol) are 25× luna on input tokens — read summaries and diffs,
not transcripts; let luna do the long reading.

## Hand-drive mechanics — exact, proven tonight

Worker (per ticket; `$T` = a fresh task dir you create under the newest run dir):

```bash
cd /Users/dylan/Documents/personal/continuum-overnight
R=~/.pi/sidebar-native-ux-runs/continuum-overnight/run-night2; mkdir -p $R/tasks
T=$R/tasks/<TICKET>.md-dir; mkdir -p "$T/worker-session-1"
{ echo "[sidebar harness]"; echo "TICKET=<TICKET>.md";
  echo "PACKET=$PWD/docs/38-tickets/94-sidebar-native-ux/<TICKET>.md";
  echo "TASK_DIR=$T"; echo "PASS=1"; echo;
  cat scripts/sidebar-native-ux-prompt.md; } > "$T/worker-prompt-1.md"
nohup caffeinate -is sh -c "pi --approve --model openai-codex/gpt-5.6-luna --thinking max \
  --session-dir '$T/worker-session-1' --name night2-<TICKET>-w1 --mode text \
  -p '@$T/worker-prompt-1.md' > '$T/worker-1.md' 2> '$T/worker-1.stderr'; \
  echo \"exit \$?\" >> '$T/worker-1.stderr'" >/dev/null 2>&1 &
```

- **Liveness by open file handle, never argv** (`pi` masks argv):
  `for p in $(pgrep -x pi); do lsof -p $p 2>/dev/null | grep -q "$T/worker-1.md" && echo alive; done`
- **Pacing — two sanctioned patterns.** (a) Bounded waits: `while <alive>; do sleep 60; done`
  against the slot's deadline; check `date` when it finishes. (b) The harness-agents wake
  scheduler you already own: dispatch via `delegate_agent` with
  `{background: true, scheduleCheck: true, expectedMinutes: 30, repeatMinutes: 5}` and let the
  watch wake your turn. Caveats that are already documented in your own SYSTEM.md and verified
  tonight: watches are IN-SESSION (they die if you exit — stay open all night); a missing or
  `(no output)` final.md means the run FAILED even when status says done (re-dispatch, never count
  it); and delegated runs take model/thinking from the AGENT DEFINITION, not a dispatch flag — so
  for luna-max workers use the direct `pi` subprocess above, and reserve delegate/watches for
  pacing and monitoring.
- A worker that DIES with tracked changes present is a transport failure, not a quality failure —
  proceed to review (today's provider 500 cost 35 min of finished work before this rule existed).
- Review: `git diff --binary > "$T/candidate-1.diff"`, write a review request naming the packet,
  diff, and the R2 fence-allowance purposes (copy the shape from
  `run-20260804T203550/tasks/iteration-001-P3.4-*/review-request-2.md`), then
  `pi --no-approve --model openai-codex/gpt-5.6-sol --thinking medium --tools read,grep,find,ls …`.
  Last line must be exactly `DECISION: APPROVE` or `DECISION: REWORK`.
- Ledger: flip the row `pending → done` with `this commit`, a REAL ISO UTC timestamp, and a note
  carrying: what shipped, review rounds and findings, witness evidence (mutation → exact red →
  restore hash), matrix exit, moved-baseline count, and `ahead of gate P3.6 per focus-session plan`
  (P4/P5 tickets) or `ahead of gate P5.6` (Phase 6). Then
  `./scripts/check-sidebar-native-ux-program.sh --check` MUST pass before committing.
- Commit via `./scripts/sidebar-native-ux-safe-commit.sh -m "feat(sidebar): <slug>…" <files>` —
  the loop is stopped so it will not refuse. **One commit per ticket** (P4.1+P4.2 share one).

## Hard rails — verbatim, non-negotiable

Never push. Never `git reset`, `clean`, or `stash`. Commits are the owner's identity with **no
trailers of any kind — no Co-Authored-By, nothing**. Never author under any other identity. Never
run an app instance or the boot probe while the owner's instance runs
(`pgrep -f 'Continuum Revived.app/Contents/MacOS'` first — refuse if present). Never bless a
baseline (Retina check is red anyway; all blessing belongs to the owner's gates). Never lower a
floor, a tolerance, or a count to pass. Never mark a supervised gate done; never infer approval
from silence. Never edit `_QUEUE.md` order, the program guard, or queue 91's closed work. The
`STOP` file stays where it is; do not start the loop.

## Today's traps, so the night doesn't rediscover them

1. **Vacuous assertions are the house defect.** Today alone: a witness in an unwired check, a
   propagation check over disjoint sets, a `hasPrefix` hiding AppKit clipping, an oracle deriving
   its expectation from the code under test. Every new assertion: ask "what mutation makes this
   red?" and run that mutation.
2. **The truncation table rots both ways** — a healed key left in the table is as red as a new
   truncation unrecorded. Widths move only with evidence; the per-row lane pattern
   (`elapsedColumnWidth(unconfirmed:)`) exists so a rare form never taxes every row.
3. **Offscreen materialization**: size the subtree BEFORE applying rows; open the shelf before
   content; drive `layoutForQA()` twice around `layoutSubtreeIfNeeded()`.
4. **Drawable width** = measured need for the exact string and font + 4 pt `Metrics.cellTextInset`;
   never `stringValue`, never a bare frame.
5. **Fence stalls**: the R2 allowance (forced call site / deliberately-moved assertion / false
   summary line in `ContinuumApp.swift`/`AgentSupervisor.swift`) is implemented in the prompt AND
   the reviewer brief. `ComponentLab.swift`'s P0.3 corpus stays pinned — synthetic rows live in
   checks, never in the corpus.
6. **Provider flakiness**: Codex 500s and `fetch failed` happened repeatedly. Retry a dead pass
   once; if the provider is down twice in a row, sleep 10 minutes and retry before escalating to a
   parked note in the morning doc.

## End of night (by 06:00), whatever the count

1. Tree clean, every commit `feat(sidebar):`/`fix(sidebar):`/`docs(sidebar):`, no WIP noise —
   read `git log --oneline 758b7f0..HEAD` and make sure it tells the morning story.
2. Update `plan-morning-review.md`: what landed, what was cut and why, the two gates' walk-through
   pointers (`qa-runs/p3.6-gate/`, and a new `qa-runs/p5.6-gate/` if P5 landed), moved-baseline
   inventory awaiting blessing, and anything a reviewer flagged that was consciously deferred.
3. Leave the loop stopped and STOP armed; the owner decides the day plan.

## Harness inventory (from tonight's exploration)

See `plan-night2-pi-inventory.md` beside this file — pi capabilities, flags, and the agent/extension
cleanup list the owner asked for. Cleanup is a MORNING task; touch nothing tonight.

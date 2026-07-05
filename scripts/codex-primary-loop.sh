#!/usr/bin/env bash
# codex-primary-loop.sh — GPT-5.5/Codex-PRIMARY driver for usage-lean daytime runs.
# No Claude calls inside: Codex selects the next eligible ticket from the ledger,
# implements, builds, runs the matrix, and commits; then THIS script independently
# re-runs swift build + the matrix as an objective gate and reverts any commit that
# does not hold (Codex cannot fake-green past it). Failed/aborted attempts are
# recorded as skipped ledger rows by the driver so selection advances instead of
# livelocking. Fable/Claude steers only from the outside (overwatch session).
#
# Usage (repo root, overnight branch, clean tree):
#   CODEX_EFFORT=medium caffeinate -is ./scripts/codex-primary-loop.sh
# Stop: `touch STOP` (checked between iterations).

set -uo pipefail
cd "$(dirname "$0")/.."

MAX_ITER="${MAX_ITER:-20}"
STOP_FILE="${STOP_FILE:-STOP}"
CODEX_MODEL="${CODEX_MODEL:-gpt-5.5}"
# Retry tickets carry precise rulings but are the hard end of the queue: medium.
CODEX_EFFORT="${CODEX_EFFORT:-medium}"
# Auto-escalation: a ticket that fails at CODEX_EFFORT gets ONE retry at this effort
# before the driver records the skip and moves on. (Failure = no commit, or commit
# reverted by the objective gate. The skip row is deferred on first failure, so the
# next selection re-picks the same ticket.)
CODEX_ESCALATE_EFFORT="${CODEX_ESCALATE_EFFORT:-high}"
CODEX_ITER_TIMEOUT_SECONDS="${CODEX_ITER_TIMEOUT_SECONDS:-3600}"
EXPECTED_BRANCH="${EXPECTED_BRANCH:-overnight/agent-orchestration}"
export CONTINUUM_SKIP_SURFACE_CHECKS="${CONTINUUM_SKIP_SURFACE_CHECKS:-1}"

ROOT_PI_DIR="${ROOT_PI_DIR:-$HOME/.pi}"
REPO_NAME="$(basename "$(git rev-parse --show-toplevel)")"
STAMP="$(date +%Y%m%dT%H%M%S)"
RUN_DIR="$ROOT_PI_DIR/overnight-runs/$REPO_NAME/codex-run-$STAMP"
LOG_DIR="$RUN_DIR/logs"
mkdir -p "$LOG_DIR" .pi/overnight-logs
printf '%s\n' "$RUN_DIR" > .pi/overnight-logs/latest-run.txt

branch="$(git branch --show-current)"
if [ "$branch" != "$EXPECTED_BRANCH" ]; then
  echo "[codex-loop] ERROR: expected branch $EXPECTED_BRANCH, got $branch" >&2; exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "[codex-loop] ERROR: working tree dirty; clean it first" >&2; exit 1
fi
if ! command -v codex >/dev/null 2>&1; then
  echo "[codex-loop] ERROR: codex CLI not found" >&2; exit 1
fi

# Driver-side skip ledger row: keeps selection moving without a Claude orchestrator.
record_skip() {
  local ticket="$1" note="$2"
  [ -z "$ticket" ] && ticket="(unknown)"
  printf '| %s | skipped | - | - | codex-primary: %s |\n' "$ticket" "$note" >> docs/38-tickets/_PROGRESS.md
  git add docs/38-tickets/_PROGRESS.md
  git commit -q -m "docs(tickets): mark $ticket skipped (codex-primary driver)" || true
}

# macOS bash 3.2: heredoc nested in $() mis-parses apostrophes/backticks; use read -d ''.
read -r -d '' PROMPT <<'CODEXEOF' || true
You are the GPT-5.5 PRIMARY implementer for the Continuum agent-orchestration program (usage-lean
daytime mode — no Claude models available). Implement exactly ONE ticket end-to-end and commit it.
Repository: current working directory (git worktree, branch overnight/agent-orchestration).
Local commits ONLY — NEVER push.

STEP 1 — SELECT. Read, in order: docs/38-tickets/_PROGRESS.md (NOTE: rows in later "Reset ..." sections
SUPERSEDE earlier rows for the same ticket — a ticket whose newest row is `pending-retry` is ELIGIBLE
even if an older row says skipped); docs/38-tickets/_CONFLICT_LOG.md (retry rulings C-20260701-007/-008,
C-20260703-019/-020 are binding; C-20260703-016 for ticket 56 and C-20260703-017 for ticket 66 said
"do not attempt until 07 lands" — ticket 07 HAS now landed at ce3a87f, so treat those two blocks as
dep-cleared: 56 is eligible once 07 is in git log, and 66 once 56 lands); docs/38-tickets/README.md
(Overnight-executable set); the RETRY RULING BANNER at the top of the chosen ticket file; the relevant
implementor packet (_IMPLEMENTOR_PACKETS_01-10.md / _IMPLEMENTOR_PACKETS_11-74.md).
Pick the FIRST ticket that is: (a) not done (newest ledger row + no matching commit in `git log`);
(b) not skipped in its NEWEST row (pending-retry = eligible); (c) all dependencies done in git;
(d) autonomous. NEVER attempt: 27, 30, 38, 39, 40, 41, 69, 70 (supervised / unbuilt-substrate /
dep-blocked-on-unbuilt). Expected order right now: 09 (if not already committed), 58, 74, 56, 66.
If NO ticket qualifies, print exactly `CODEX_TICKET: none` and STOP without changing anything.

STEP 2 — IMPLEMENT fully per the ticket + its retry-ruling banner (the banner SUPERSEDES conflicting
ticket text). Prior rejected attempts are in `git stash list` — inspect with `git stash show -p <ref>`
and salvage what survives the review findings; do NOT blindly `stash pop`. Stay within the ticket's
scope fences except where a banner/ruling explicitly loosens them.

STEP 3 — VERIFY. This repo has NO XCTest; all checks are Swift EXECUTABLE `*Checks` targets wired into
scripts/run-matrix.sh. Add checks there. NEVER write XCTest. NEVER edit scripts/run-matrix.sh to weaken
or skip anything (additive new check lines are fine). Run `swift build` until clean, then
`./scripts/run-matrix.sh` (CONTINUUM_SKIP_SURFACE_CHECKS=1 is set: surface checks print "SKIPPED
(headless)" and the matrix still ends "Matrix passed" — that is green and expected).

STEP 4 — COMMIT only if build is clean AND the matrix passed. One ticket = one commit, plain
Conventional-Commits message (`type(scope): summary`) — NO Co-Authored-By, NO AI attribution.
`git add -A` (include new files). Append a `| <ticket> | done | <short-hash> | matrix: green (headless)
| gpt-5.5 primary; pending Fable audit |` row to docs/38-tickets/_PROGRESS.md and fold it into the same
commit via `git commit --amend --no-edit`. Then print `CODEX_TICKET: <ticket-filename>` and
`CODEX_RESULT: committed`.
If you CANNOT make it honestly green: do NOT commit; `git reset --hard HEAD` and `git clean -fd` to a
pristine tree; print `CODEX_TICKET: <ticket-filename>` then `CODEX_RESULT: skipped:<one-line reason>`.
NEVER fake-green. NEVER weaken a check.
CODEXEOF

# Optional external prompt (e.g. a night-specific fix queue) overrides the built-in one.
if [ -n "${CODEX_PROMPT_FILE:-}" ] && [ -r "$CODEX_PROMPT_FILE" ]; then
  PROMPT="$(cat "$CODEX_PROMPT_FILE")"
  echo "[codex-loop] using prompt file: $CODEX_PROMPT_FILE"
fi

echo "[codex-loop] start $(date) — run dir $RUN_DIR (model=$CODEX_MODEL effort=$CODEX_EFFORT, escalate=$CODEX_ESCALATE_EFFORT)"

RETRY_PENDING=""   # ticket that failed once and is owed an escalated retry
for i in $(seq 1 "$MAX_ITER"); do
  if [ -f "$STOP_FILE" ]; then echo "[codex-loop] STOP file present; halting."; break; fi
  OUT="$LOG_DIR/iter-$i.log"
  pre_head="$(git rev-parse HEAD)"
  effort="$CODEX_EFFORT"
  if [ -n "$RETRY_PENDING" ]; then
    effort="$CODEX_ESCALATE_EFFORT"
    echo "[codex-loop] escalated retry for $RETRY_PENDING at effort=$effort"
  fi
  echo "[codex-loop] === iteration $i/$MAX_ITER $(date) (effort=$effort) ==="

  codex exec --model "$CODEX_MODEL" -c model_reasoning_effort="$effort" \
    --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$PROMPT" >"$OUT" 2>&1 &
  pid=$!
  ( sleep "$CODEX_ITER_TIMEOUT_SECONDS"
    if kill -0 "$pid" 2>/dev/null; then
      echo "[codex-loop] iteration timeout" >> "$OUT"
      kill -TERM "$pid" 2>/dev/null || true; sleep 10; kill -KILL "$pid" 2>/dev/null || true
    fi ) &
  wd=$!
  wait "$pid"; rc=$?
  kill "$wd" 2>/dev/null || true

  ticket="$(grep -m1 '^CODEX_TICKET: ' "$OUT" | sed 's/^CODEX_TICKET: //' | tr -d '[:space:]')"
  post_head="$(git rev-parse HEAD)"
  echo "[codex-loop] rc=$rc ticket='${ticket:-?}' (log: $OUT)"

  if [ "$ticket" = "none" ]; then
    echo "[codex-loop] queue drained."; break
  fi

  # On failure: first strike defers the skip (so the next iteration re-picks the
  # ticket at CODEX_ESCALATE_EFFORT); second strike on the same ticket records it.
  handle_failure() {
    local reason="$1"
    if [ "$RETRY_PENDING" = "$ticket" ]; then
      record_skip "$ticket" "$reason (after escalated $CODEX_ESCALATE_EFFORT retry)"
      RETRY_PENDING=""
    else
      echo "[codex-loop] first failure for $ticket — will retry escalated at $CODEX_ESCALATE_EFFORT"
      RETRY_PENDING="$ticket"
    fi
  }

  if [ "$post_head" != "$pre_head" ]; then
    if [ -n "$(git status --porcelain)" ]; then
      git reset --hard "$pre_head" >/dev/null 2>&1 || true; git clean -fd >/dev/null 2>&1 || true
      echo "[codex-loop] dirty tree alongside commit — distrusted, reverted."
      handle_failure "dirty tree after commit; reverted"
      continue
    fi
    if swift build >/dev/null 2>&1 && ./scripts/run-matrix.sh >/dev/null 2>&1; then
      echo "[codex-loop] VERIFIED: $(git log -1 --oneline)"
      RETRY_PENDING=""
    else
      git reset --hard "$pre_head" >/dev/null 2>&1 || true; git clean -fd >/dev/null 2>&1 || true
      echo "[codex-loop] objective build/matrix gate FAILED — reverted."
      handle_failure "objective build/matrix gate failed post-commit; reverted"
    fi
  else
    git reset --hard "$pre_head" >/dev/null 2>&1 || true; git clean -fd >/dev/null 2>&1 || true
    handle_failure "attempt did not commit (rc=$rc); see $(basename "$OUT")"
  fi
done

echo "[codex-loop] finished $(date). Commits this run:"
git log --oneline | head -8

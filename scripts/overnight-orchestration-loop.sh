#!/usr/bin/env bash
# overnight-orchestration-loop.sh — Ralph-style driver for the agent-orchestration
# program. Forked from overnight-loop.sh; same observability + resilience, but each
# iteration is a fresh headless Claude Code (`claude -p`, Sonnet 5) that runs the
# internal per-ticket Workflow (implement -> swift build + matrix -> Fable + Codex
# gpt-5.5 dual review -> commit). State lives in git + docs/38-tickets/_PROGRESS.md.
#
# Usage from repo root, on the overnight branch, tree clean:
#   caffeinate -is ./scripts/overnight-orchestration-loop.sh
#
# Stop it: `touch STOP` in the repo root (checked between iterations and during
# quota sleep), or Ctrl-C. Tune with MAX_ITER=n. Dry-run one ticket: MAX_ITER=1.

set -uo pipefail
cd "$(dirname "$0")/.."

MAX_ITER="${MAX_ITER:-60}"
MAX_SOFT_FAIL="${MAX_SOFT_FAIL:-10}"
PROMPT_FILE="${PROMPT_FILE:-scripts/overnight-orchestration-prompt.md}"
QUEUE_FILE="${QUEUE_FILE:-docs/38-tickets/README.md}"
STOP_FILE="${STOP_FILE:-STOP}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/continuum-backups}"
# Fallback only. When Claude prints `resets 10:10pm (America/Toronto)`,
# the loop parses that wall-clock reset and sleeps exactly until reset + buffer.
# If no reset time is present, retry soon instead of burning a fixed 45 minutes.
QUOTA_SLEEP="${QUOTA_SLEEP:-300}"
QUOTA_RESET_BUFFER_SECONDS="${QUOTA_RESET_BUFFER_SECONDS:-90}"
SLEEP_CHECK_SECONDS="${SLEEP_CHECK_SECONDS:-60}"
ITER_TIMEOUT_SECONDS="${ITER_TIMEOUT_SECONDS:-9000}"
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"
ALLOW_MAIN="${ALLOW_MAIN:-0}"
EXPECTED_BRANCH="${EXPECTED_BRANCH:-overnight/agent-orchestration}"
PUSH_MODE="${PUSH_MODE:-local-only}"
# Orchestrator model: Fable 5 drives each iteration (picks the ticket, runs the
# implement workflow, coordinates reviews, decides commit/skip). The IMPLEMENTER
# stays Sonnet 5 (set in overnight-iteration-wf.js); reviewers stay Fable + Codex.
CLAUDE_MODEL="${CLAUDE_MODEL:-fable}"
CLAUDE_EFFORT="${CLAUDE_EFFORT:-medium}"
# `claude -p` kills still-running background tasks after this many ms (default
# 600000 = 10 min). The per-ticket Workflow runs as a background task and a real
# ticket routinely needs longer than 10 min (implement + build + matrix + dual
# review), so the default silently terminated the Workflow mid-run and produced
# no LOOP token. 0 = wait indefinitely; the ITER_TIMEOUT_SECONDS watchdog below
# is the real outer bound on a hung iteration.
export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-0}"
# The overnight loop runs headless (no terminal surface for Ghostty), so the
# matrix's surface-rendering checks time out. Skip them in the loop's matrix; a
# supervised full-matrix pass on a GUI host covers them. Propagates to the
# implement agent's `./scripts/run-matrix.sh` invocation.
export CONTINUUM_SKIP_SURFACE_CHECKS="${CONTINUUM_SKIP_SURFACE_CHECKS:-1}"
ROOT_PI_DIR="${ROOT_PI_DIR:-$HOME/.pi}"
PROJECT_LOG_DIR="${PROJECT_LOG_DIR:-.pi/overnight-logs}"
# GPT-5.5/Codex implementation fallback. When Fable is rate-limited, don't just idle:
# implement eligible low/medium autonomous tickets via Codex during the reset window.
# Codex implements + builds + runs matrix + commits (one ticket per commit, clean history,
# no AI footer); the loop then INDEPENDENTLY re-verifies build+matrix and reverts the commit
# if the objective gate does not hold. Only ever runs on a clean tree. Fable audits these
# commits when it resumes (they are marked "gpt-5.5 fallback; pending Fable audit" in _PROGRESS.md).
CODEX_FALLBACK="${CODEX_FALLBACK:-1}"
CODEX_MODEL="${CODEX_MODEL:-gpt-5.5}"
# The implementor packets are detailed enough that GPT-5.5 can run at low reasoning effort.
CODEX_EFFORT="${CODEX_EFFORT:-low}"
CODEX_ITER_TIMEOUT_SECONDS="${CODEX_ITER_TIMEOUT_SECONDS:-3600}"
# Minimum remaining reset-window (seconds) needed to START another Codex attempt.
CODEX_MIN_BUDGET_SECONDS="${CODEX_MIN_BUDGET_SECONDS:-900}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
REPO_NAME="$(basename "$REPO_ROOT")"
STAMP="$(date +%Y%m%dT%H%M%S)"
RUN_ROOT="${RUN_ROOT:-$ROOT_PI_DIR/overnight-runs/$REPO_NAME}"
RUN_DIR="$RUN_ROOT/run-$STAMP"
LOG_DIR="$RUN_DIR/logs"
EVENTS_FILE="$RUN_DIR/events.jsonl"
STATUS_FILE="$RUN_DIR/status.json"
REPORT_FILE="$RUN_DIR/report.md"

mkdir -p "$LOG_DIR" "$BACKUP_DIR" "$PROJECT_LOG_DIR"
ln -sfn "$RUN_DIR" "$RUN_ROOT/latest" 2>/dev/null || true
ln -sfn "$RUN_DIR" "$PROJECT_LOG_DIR/latest" 2>/dev/null || true
printf '%s\n' "$RUN_DIR" > "$PROJECT_LOG_DIR/latest-run.txt"

START_HEAD="$(git rev-parse HEAD)"
CURRENT_BRANCH="$(git branch --show-current)"
STOP_REASON="running"
ITERATIONS=0
failures=0
PREV_SKIP_TOKEN=""

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g'
}
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

append_event() {
  local event="$1"; shift || true
  local message="${1:-}"
  printf '{"ts":"%s","event":"%s","iteration":%s,"message":"%s"}\n' \
    "$(now_utc)" "$(json_escape "$event")" "${ITERATIONS:-0}" "$(json_escape "$message")" >> "$EVENTS_FILE"
}

write_status() {
  local state="$1"
  local reason="${2:-$STOP_REASON}"
  local head
  head="$(git rev-parse HEAD 2>/dev/null || true)"
  cat > "$STATUS_FILE" <<EOF
{
  "state": "$(json_escape "$state")",
  "reason": "$(json_escape "$reason")",
  "repo": "$(json_escape "$REPO_NAME")",
  "branch": "$(json_escape "$CURRENT_BRANCH")",
  "startHead": "$(json_escape "$START_HEAD")",
  "currentHead": "$(json_escape "$head")",
  "runDir": "$(json_escape "$RUN_DIR")",
  "promptFile": "$(json_escape "$PROMPT_FILE")",
  "queueFile": "$(json_escape "$QUEUE_FILE")",
  "pushMode": "$(json_escape "$PUSH_MODE")",
  "claudeModel": "$(json_escape "$CLAUDE_MODEL")",
  "claudeEffort": "$(json_escape "$CLAUDE_EFFORT")",
  "iterations": $ITERATIONS,
  "softFailures": $failures,
  "updatedAt": "$(now_utc)"
}
EOF
}

write_report() {
  local head
  head="$(git rev-parse HEAD 2>/dev/null || true)"
  {
    echo "# Overnight orchestration run report"
    echo
    echo "- Run dir: \`$RUN_DIR\`"
    echo "- Started: \`$STAMP\`"
    echo "- State/reason: \`$STOP_REASON\`"
    echo "- Repo: \`$REPO_NAME\`"
    echo "- Branch: \`$CURRENT_BRANCH\`"
    echo "- Start HEAD: \`$START_HEAD\`"
    echo "- Current HEAD: \`$head\`"
    echo "- Prompt: \`$PROMPT_FILE\`"
    echo "- Queue: \`$QUEUE_FILE\`"
    echo "- Push mode: \`$PUSH_MODE\`"
    echo "- Claude model: \`$CLAUDE_MODEL\` effort \`$CLAUDE_EFFORT\`"
    echo "- Iterations: \`$ITERATIONS\`"
    echo "- Soft failures: \`$failures\`"
    echo
    echo "## Iteration LOOP tokens"
    find "$LOG_DIR" -maxdepth 1 -type f -name 'iter-*.log' -print | sort -V | xargs -I{} grep -hE '^LOOP: ' {} 2>/dev/null | sed 's/^/- /' || true
    echo
    echo "## Commits since start"
    git log --oneline "$START_HEAD"..HEAD 2>/dev/null | sed 's/^/- /' || true
  } > "$REPORT_FILE"
}

stop_run() {
  STOP_REASON="$1"
  append_event "stop" "$STOP_REASON"
  write_status "stopped" "$STOP_REASON"
  write_report
}

sleep_interruptible() {
  local total="$1"
  local slept=0
  while [ "$slept" -lt "$total" ]; do
    if [ -f "$STOP_FILE" ]; then
      append_event "stop-file-during-sleep" "$STOP_FILE"
      return 1
    fi
    local chunk="$SLEEP_CHECK_SECONDS"
    local remaining=$((total - slept))
    if [ "$remaining" -lt "$chunk" ]; then chunk="$remaining"; fi
    sleep "$chunk"
    slept=$((slept + chunk))
  done
  return 0
}

quota_sleep_seconds_from_log() {
  local out="$1"
  local reset
  reset="$(grep -Eio 'resets[[:space:]]+[0-9]{1,2}:[0-9]{2}[[:space:]]*(am|pm)[[:space:]]*\(America/Toronto\)' "$out" 2>/dev/null | tail -1 | sed -E 's/^resets[[:space:]]+//I; s/[[:space:]]*\(America\/Toronto\)//I' | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
  if [ -z "$reset" ]; then
    printf '%s\n' "$QUOTA_SLEEP"
    return 0
  fi

  local now today target seconds
  now="$(TZ=America/Toronto date +%s)"
  today="$(TZ=America/Toronto date +%Y-%m-%d)"
  target="$(TZ=America/Toronto date -j -f '%Y-%m-%d %I:%M%p' "$today $reset" +%s 2>/dev/null || true)"
  if [ -z "$target" ]; then
    printf '%s\n' "$QUOTA_SLEEP"
    return 0
  fi
  if [ "$target" -le "$now" ]; then
    target=$((target + 86400))
  fi
  seconds=$((target - now + QUOTA_RESET_BUFFER_SECONDS))
  if [ "$seconds" -lt 30 ]; then seconds=30; fi
  printf '%s\n' "$seconds"
}

run_claude_iteration() {
  local iter="$1"
  local out="$2"
  local prompt
  prompt="$(cat <<EOF
[overnight-orchestration harness]
QUEUE_FILE=$QUEUE_FILE
RUN_DIR=$RUN_DIR
PUSH_MODE=$PUSH_MODE
EXPECTED_BRANCH=$CURRENT_BRANCH
EXPECTED_COMMIT_GRANULARITY=one-ticket-per-commit
EOF
)
$(cat "$PROMPT_FILE")"

  local claude_args=(-p --dangerously-skip-permissions --model "$CLAUDE_MODEL")
  if [ -n "$CLAUDE_EFFORT" ]; then claude_args+=(--effort "$CLAUDE_EFFORT"); fi
  claude "${claude_args[@]}" "$prompt" >"$out" 2>&1 &
  local pid=$!
  local watchdog=""
  if [ "$ITER_TIMEOUT_SECONDS" -gt 0 ]; then
    (
      sleep "$ITER_TIMEOUT_SECONDS"
      if kill -0 "$pid" 2>/dev/null; then
        echo "[loop] iteration timeout after ${ITER_TIMEOUT_SECONDS}s" >> "$out"
        kill -TERM "$pid" 2>/dev/null || true
        sleep 15
        kill -KILL "$pid" 2>/dev/null || true
      fi
    ) &
    watchdog=$!
  fi
  wait "$pid"
  local rc=$?
  if [ -n "$watchdog" ]; then kill "$watchdog" 2>/dev/null || true; fi
  return "$rc"
}

# Implement ONE eligible low/medium autonomous ticket via GPT-5.5/Codex while Fable is
# rate-limited. Codex selects, implements, builds, runs the matrix, and commits. This
# function then re-verifies the result objectively (bash-side build + matrix) and REVERTS
# the commit if it does not hold up — Codex cannot fake-green past this gate. Returns:
#   0 = a real, verified commit landed
#   1 = no verified commit (reverted to clean, or nothing produced)
#   2 = precondition failed (dirty tree) — do not attempt
run_codex_fallback() {
  local out="$1"
  local pre_head
  pre_head="$(git rev-parse HEAD)"

  # Never mix a Codex attempt into a dirty tree (e.g. an unresolved Fable attempt).
  if [ -n "$(git status --porcelain)" ]; then
    append_event "codex-fallback-skip" "tree dirty; not starting codex implementer"
    return 2
  fi

  local prompt
  # macOS bash 3.2 mis-parses a heredoc nested in $(...) when the body has apostrophes/backticks
  # (which this prompt does). `read -r -d ''` takes the quoted heredoc directly, so the body stays
  # literal; -d '' reads to NUL (never present) and returns non-zero at EOF, hence `|| true`.
  read -r -d '' prompt <<'CODEXEOF' || true
You are the GPT-5.5 implementation fallback for the Continuum agent-orchestration overnight loop,
running while the Fable/Claude model is rate-limited. Implement exactly ONE ticket end-to-end and commit it.
Repository: the current working directory (a git worktree on branch overnight/agent-orchestration).
Local commits ONLY — NEVER push.

STEP 1 — SELECT. Read, in order: docs/38-tickets/_PROGRESS.md ; docs/38-tickets/_CONFLICT_LOG.md ;
docs/38-tickets/README.md (its "Overnight-executable set" lists autonomous tickets in dependency order) ;
docs/38-tickets/_IMPLEMENTOR_PACKETS_01-10.md and _IMPLEMENTOR_PACKETS_11-74.md.
Pick the FIRST ticket that is ALL of: (a) not marked done in _PROGRESS.md and has no matching commit in
`git log`; (b) not marked skipped; (c) NOT listed open/terminal-skip in _CONFLICT_LOG.md; (d) all
dependencies done; (e) classified low or medium effort WITH a full implementor packet; (f) autonomous
(NOT supervised / needs-substrate / iOS / CloudKit / APNS). Do NOT attempt tickets 03, 04, 05, 06, 07,
08, 09, 10, or 12 — they are conflicted, dependency-blocked, or human-owned. If NO ticket qualifies,
print exactly `CODEX_TICKET: none` and STOP without changing anything.

STEP 2 — IMPLEMENT it fully per its packet + the ticket contract. For a compile-enforced migration,
migrate ALL call sites (a compatibility shim that leaves old call sites working is a FAILURE, not a
convenience). Stay within the ticket's scope/file fences.

STEP 3 — VERIFY. This repo has NO XCTest and run-matrix.sh does NOT run `swift test`. All checks are
Swift EXECUTABLE targets (`*Checks`, e.g. ContinuumRevivedCoreChecks) wired into scripts/run-matrix.sh.
Add your checks to the relevant `*Checks` target and wire them into scripts/run-matrix.sh. NEVER write
XCTestCase / `import XCTest` / a Tests target (nothing runs it). NEVER edit scripts/run-matrix.sh to
weaken or skip a check. Then run `swift build` until clean, then `./scripts/run-matrix.sh`. The
environment sets CONTINUUM_SKIP_SURFACE_CHECKS=1, so the matrix prints "SKIPPED (headless): ...surface
checks" and still ends with "Matrix passed" — that is green and expected; do not try to force those.

STEP 4 — COMMIT, only if `swift build` is clean AND the matrix passed. One ticket = one commit. Use a
plain Conventional-Commits message `type(scope): summary` — NO body footer, NO Co-Authored-By, NO AI
attribution of any kind. `git add -A` (include new files). Then append a row to
docs/38-tickets/_PROGRESS.md marking the ticket done with the short commit hash and the note
"gpt-5.5 fallback; pending Fable audit", and `git commit --amend --no-edit` to fold that row into the
same commit. Finally print `CODEX_TICKET: <ticket-filename>` then `CODEX_RESULT: committed`.
If you CANNOT make it honestly green: do NOT commit; run `git reset --hard HEAD` and `git clean -fd`
to leave a pristine tree; print `CODEX_TICKET: <ticket-filename>` then `CODEX_RESULT: skipped:<reason>`.
NEVER fake-green. NEVER weaken a check to pass.
CODEXEOF

  local pid watchdog rc
  codex exec --model "$CODEX_MODEL" -c model_reasoning_effort="$CODEX_EFFORT" \
    --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$prompt" >"$out" 2>&1 &
  pid=$!
  ( sleep "$CODEX_ITER_TIMEOUT_SECONDS"
    if kill -0 "$pid" 2>/dev/null; then
      echo "[loop] codex fallback timeout after ${CODEX_ITER_TIMEOUT_SECONDS}s" >> "$out"
      kill -TERM "$pid" 2>/dev/null || true; sleep 15; kill -KILL "$pid" 2>/dev/null || true
    fi ) &
  watchdog=$!
  wait "$pid"; rc=$?
  kill "$watchdog" 2>/dev/null || true

  local post_head
  post_head="$(git rev-parse HEAD)"

  # No new commit: ensure the tree is pristine regardless of what Codex left behind.
  if [ "$post_head" = "$pre_head" ]; then
    if [ -n "$(git status --porcelain)" ]; then
      git reset --hard "$pre_head" >/dev/null 2>&1 || true
      git clean -fd >/dev/null 2>&1 || true
    fi
    append_event "codex-fallback-nocommit" "rc=$rc (no ticket committed)"
    return 1
  fi

  # A commit exists. If Codex left leftover dirt alongside it, distrust the whole attempt.
  if [ -n "$(git status --porcelain)" ]; then
    git reset --hard "$pre_head" >/dev/null 2>&1 || true
    git clean -fd >/dev/null 2>&1 || true
    append_event "codex-fallback-revert" "dirty tree after commit; reverted to $pre_head"
    return 1
  fi

  # Objective gate: the LOOP re-runs build + matrix; trust the commit only if THIS passes.
  if swift build >/dev/null 2>&1 && ./scripts/run-matrix.sh >/dev/null 2>&1; then
    append_event "codex-fallback-commit" "$(git rev-parse --short HEAD) $(git log -1 --format=%s)"
    git bundle create "$BACKUP_DIR/continuum-rolling.bundle" --all 2>/dev/null || true
    return 0
  fi
  git reset --hard "$pre_head" >/dev/null 2>&1 || true
  git clean -fd >/dev/null 2>&1 || true
  append_event "codex-fallback-revert" "objective build/matrix gate failed; reverted to $pre_head"
  return 1
}

append_event "start" "run dir $RUN_DIR"
write_status "running" "running"
write_report

# Preflight
if [ ! -f "$PROMPT_FILE" ]; then
  echo "[loop] ERROR: prompt file missing: $PROMPT_FILE" >&2
  stop_run "missing-prompt-file"; exit 1
fi
if [ ! -f "$QUEUE_FILE" ]; then
  echo "[loop] ERROR: queue file missing (has authoring finished?): $QUEUE_FILE" >&2
  stop_run "missing-queue-file"; exit 1
fi
if ! command -v claude >/dev/null 2>&1; then
  echo "[loop] ERROR: claude CLI not found on PATH" >&2
  stop_run "missing-claude-cli"; exit 1
fi
if ! command -v codex >/dev/null 2>&1; then
  echo "[loop] WARN: codex CLI not found — the gpt-5.5 cross-review will fail closed (tickets skipped)" >&2
  append_event "missing-codex-cli" "codex not on PATH"
fi
if [ -n "$EXPECTED_BRANCH" ] && [ "$CURRENT_BRANCH" != "$EXPECTED_BRANCH" ]; then
  echo "[loop] ERROR: expected branch '$EXPECTED_BRANCH', got '$CURRENT_BRANCH'" >&2
  stop_run "wrong-branch"; exit 1
fi
if [ "$CURRENT_BRANCH" = "main" ] && [ "$ALLOW_MAIN" != "1" ]; then
  echo "[loop] ERROR: refusing to run on main (set ALLOW_MAIN=1 to override)" >&2
  stop_run "refuse-main"; exit 1
fi
if [ "$ALLOW_DIRTY" != "1" ] && [ -n "$(git status --porcelain)" ]; then
  echo "[loop] ERROR: working tree is dirty; commit/stash setup first or set ALLOW_DIRTY=1" >&2
  git status --short >&2
  stop_run "dirty-tree-preflight"; exit 1
fi

echo "[loop] start $(date) — run dir $RUN_DIR"
echo "[loop] branch=$CURRENT_BRANCH model=$CLAUDE_MODEL effort=$CLAUDE_EFFORT prompt=$PROMPT_FILE queue=$QUEUE_FILE pushMode=$PUSH_MODE"
echo "[loop] backing up all refs"
git bundle create "$BACKUP_DIR/continuum-$STAMP-start.bundle" --all 2>/dev/null \
  || echo "[loop] WARN: start bundle failed"
append_event "backup-start" "$BACKUP_DIR/continuum-$STAMP-start.bundle"

for i in $(seq 1 "$MAX_ITER"); do
  ITERATIONS="$i"
  write_status "running" "iteration-$i"
  write_report

  if [ -f "$STOP_FILE" ]; then
    echo "[loop] STOP file present; halting."
    stop_run "stop-file"; break
  fi

  echo "[loop] === iteration $i/$MAX_ITER $(date) ==="
  append_event "iteration-start" "$i/$MAX_ITER"
  OUT="$LOG_DIR/iter-$STAMP-$i.log"

  run_claude_iteration "$i" "$OUT"
  rc=$?

  # Extract the control token even if the model wrapped it in markdown backticks
  # or placed it mid-line. `\140` is octal for backtick (a literal backtick here
  # would open a nested command substitution). Take the last occurrence.
  token="$(tr -d '\140' < "$OUT" | grep -oE 'LOOP: (CONTINUE|STOP).*' | tail -1 || true)"
  echo "[loop] rc=$rc token='${token:-none}' (log: $OUT)"
  tail -3 "$OUT" | sed 's/^/[iter] /'
  append_event "iteration-end" "rc=$rc token=${token:-none} log=$OUT"
  write_status "running" "post-iteration-$i"
  write_report

  if grep -q "\[loop\] iteration timeout" "$OUT"; then
    echo "[loop] iteration timed out; halting."
    stop_run "iteration-timeout"; break
  fi

  # Usage-limit / provider degradation: back off and retry the same ticket.
  if grep -qiE 'usage limit|session limit|rate limit|status code 429|overloaded|quota' "$OUT" \
     || [[ "$token" == "LOOP: STOP provider-failure"* ]]; then
    failures=$((failures + 1))
    if [ "$failures" -ge "$MAX_SOFT_FAIL" ]; then
      echo "[loop] $MAX_SOFT_FAIL consecutive quota/provider failures; halting."
      stop_run "provider-failure-window"; break
    fi
    quota_sleep="$(quota_sleep_seconds_from_log "$OUT")"
    echo "[loop] quota/provider failure #$failures/$MAX_SOFT_FAIL — Fable window down ~${quota_sleep}s"
    append_event "quota-sleep" "failure $failures/$MAX_SOFT_FAIL for ${quota_sleep}s"
    quota_deadline=$(( $(date +%s) + quota_sleep ))

    # Don't idle through the reset window: implement eligible tickets via GPT-5.5/Codex.
    # Each attempt is one committed-and-verified (or reverted) ticket. A productive attempt
    # resets the soft-failure counter so a long-but-productive Fable outage never trips the halt.
    if [ "$CODEX_FALLBACK" = "1" ] && command -v codex >/dev/null 2>&1; then
      while : ; do
        [ -f "$STOP_FILE" ] && break
        remaining=$(( quota_deadline - $(date +%s) ))
        [ "$remaining" -lt "$CODEX_MIN_BUDGET_SECONDS" ] && break
        if [ -n "$(git status --porcelain)" ]; then
          append_event "codex-fallback-skip" "tree dirty; deferring to Fable on reset"
          break
        fi
        CODEX_OUT="$LOG_DIR/codex-$STAMP-$(date +%H%M%S).log"
        echo "[loop] Fable down — GPT-5.5 fallback implementer (window ~${remaining}s)"
        run_codex_fallback "$CODEX_OUT"; cfr=$?
        [ "$cfr" -eq 0 ] && failures=0
        write_status "running" "codex-fallback"; write_report
        if grep -q '^CODEX_TICKET: none' "$CODEX_OUT" 2>/dev/null; then
          append_event "codex-fallback-drained" "no eligible low/medium autonomous ticket"
          break
        fi
      done
    fi

    remaining=$(( quota_deadline - $(date +%s) ))
    if [ "$remaining" -gt 0 ]; then
      echo "[loop] sleeping ${remaining}s until Fable reset"
      if ! sleep_interruptible "$remaining"; then
        echo "[loop] STOP file present during quota sleep; halting."
        stop_run "stop-file"; break
      fi
    fi
    continue
  fi

  if [ -z "$token" ]; then
    echo "[loop] no LOOP token and no quota signature; halting."
    stop_run "harness-malformed-output"; break
  fi

  failures=0
  git bundle create "$BACKUP_DIR/continuum-rolling.bundle" --all 2>/dev/null \
    || echo "[loop] WARN: rolling bundle failed"

  case "$token" in
    "LOOP: STOP"*)
      echo "[loop] iteration requested stop: $token"
      stop_run "${token#LOOP: STOP }"; break ;;
    "LOOP: CONTINUE skipped:"*)
      # Livelock guard: the same ticket skipped twice in a row means the
      # queue-selection logic is re-picking a blocked ticket. Halt rather
      # than burn iterations. (The iteration prompt should not re-pick a
      # skipped ticket; this is the backstop if it does.)
      if [ "$token" = "$PREV_SKIP_TOKEN" ]; then
        echo "[loop] same ticket skipped twice consecutively; halting: $token"
        stop_run "repeated-skip:${token#LOOP: CONTINUE skipped:}"; break
      fi
      PREV_SKIP_TOKEN="$token"
      append_event "continue" "$token" ;;
    "LOOP: CONTINUE"*)
      PREV_SKIP_TOKEN=""
      append_event "continue" "$token" ;;
    *)
      echo "[loop] unrecognized LOOP token; halting: $token"
      stop_run "unrecognized-loop-token"; break ;;
  esac
done

if [ "$STOP_REASON" = "running" ]; then
  stop_run "max-iterations-or-complete"
fi

echo "[loop] finished $(date)."
echo "[loop] run dir: $RUN_DIR"
echo "[loop] status: $STATUS_FILE"
echo "[loop] report: $REPORT_FILE"
echo "[loop] events: $EVENTS_FILE"

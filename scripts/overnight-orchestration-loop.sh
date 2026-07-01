#!/usr/bin/env bash
# overnight-orchestration-loop.sh — Ralph-style driver for the agent-orchestration
# program. Forked from overnight-loop.sh; same observability + resilience, but each
# iteration is a fresh headless Claude Code (`claude -p`, Sonnet 5) that runs the
# internal per-ticket Workflow (implement -> swift build + matrix -> Opus + Codex
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
QUOTA_SLEEP="${QUOTA_SLEEP:-2700}"
SLEEP_CHECK_SECONDS="${SLEEP_CHECK_SECONDS:-60}"
ITER_TIMEOUT_SECONDS="${ITER_TIMEOUT_SECONDS:-9000}"
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"
ALLOW_MAIN="${ALLOW_MAIN:-0}"
EXPECTED_BRANCH="${EXPECTED_BRANCH:-overnight/agent-orchestration}"
PUSH_MODE="${PUSH_MODE:-local-only}"
# Orchestrator model: Fable 5 drives each iteration (picks the ticket, runs the
# implement workflow, coordinates reviews, decides commit/skip). The IMPLEMENTER
# stays Sonnet 5 (set in overnight-iteration-wf.js); reviewers stay Opus + Codex.
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
  if grep -qiE 'usage limit|rate limit|status code 429|overloaded|quota' "$OUT" \
     || [[ "$token" == "LOOP: STOP provider-failure"* ]]; then
    failures=$((failures + 1))
    if [ "$failures" -ge "$MAX_SOFT_FAIL" ]; then
      echo "[loop] $MAX_SOFT_FAIL consecutive quota/provider failures; halting."
      stop_run "provider-failure-window"; break
    fi
    echo "[loop] quota/provider failure #$failures/$MAX_SOFT_FAIL — sleeping ${QUOTA_SLEEP}s then retrying"
    append_event "quota-sleep" "failure $failures/$MAX_SOFT_FAIL for ${QUOTA_SLEEP}s"
    if ! sleep_interruptible "$QUOTA_SLEEP"; then
      echo "[loop] STOP file present during quota sleep; halting."
      stop_run "stop-file"; break
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

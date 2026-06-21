#!/usr/bin/env bash
# overnight-loop.sh — local-doc Ralph-style driver: fresh pi master per ticket.
#
# No Linear is required. State lives in git + QUEUE_FILE. Each iteration handles
# one ticket and should create one organized commit.
#
# Usage from repo root, after committing/stashing setup changes:
#   caffeinate -is ./scripts/overnight-loop.sh
#
# Stop it: touch STOP in repo root (checked between iterations and during quota
# sleep), or Ctrl-C. Tune with MAX_ITER=n.

set -uo pipefail
cd "$(dirname "$0")/.."

MAX_ITER="${MAX_ITER:-40}"
MAX_SOFT_FAIL="${MAX_SOFT_FAIL:-10}"
PROMPT_FILE="${PROMPT_FILE:-scripts/overnight-local-docs-prompt.md}"
QUEUE_FILE="${QUEUE_FILE:-docs/2026-06-17-tonight-session-browser-nav-shell/04-local-implementation-queue.md}"
STOP_FILE="${STOP_FILE:-STOP}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/continuum-backups}"
QUOTA_SLEEP="${QUOTA_SLEEP:-2700}"
SLEEP_CHECK_SECONDS="${SLEEP_CHECK_SECONDS:-60}"
ITER_TIMEOUT_SECONDS="${ITER_TIMEOUT_SECONDS:-7200}"
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"
ALLOW_MAIN="${ALLOW_MAIN:-0}"
EXPECTED_BRANCH="${EXPECTED_BRANCH:-}"
PUSH_MODE="${PUSH_MODE:-local-only}"
CLEAR_WATCHES="${CLEAR_WATCHES:-1}"
ROOT_PI_DIR="${ROOT_PI_DIR:-$HOME/.pi}"
PROJECT_LOG_DIR="${PROJECT_LOG_DIR:-.pi/overnight-logs}"
ENV_FILE="${ENV_FILE:-.env}"
LOAD_DOTENV="${LOAD_DOTENV:-1}"
PI_MODEL="${PI_MODEL:-}"
PI_PROVIDER="${PI_PROVIDER:-}"
PI_THINKING="${PI_THINKING:-}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
REPO_NAME="$(basename "$REPO_ROOT")"
STAMP="$(date +%Y%m%dT%H%M%S)"
RUN_ROOT="${RUN_ROOT:-$ROOT_PI_DIR/overnight-runs/$REPO_NAME}"
RUN_DIR="$RUN_ROOT/run-$STAMP"
LOG_DIR="$RUN_DIR/logs"
WATCH_ARCHIVE_DIR="$RUN_DIR/watches"
TICKET_ARTIFACT_DIR="$RUN_DIR/tickets"
EVENTS_FILE="$RUN_DIR/events.jsonl"
STATUS_FILE="$RUN_DIR/status.json"
REPORT_FILE="$RUN_DIR/report.md"

mkdir -p "$LOG_DIR" "$WATCH_ARCHIVE_DIR" "$TICKET_ARTIFACT_DIR" "$BACKUP_DIR" "$PROJECT_LOG_DIR"
ln -sfn "$RUN_DIR" "$RUN_ROOT/latest" 2>/dev/null || true
ln -sfn "$RUN_DIR" "$PROJECT_LOG_DIR/latest" 2>/dev/null || true
printf '%s\n' "$RUN_DIR" > "$PROJECT_LOG_DIR/latest-run.txt"

START_HEAD="$(git rev-parse HEAD)"
CURRENT_BRANCH="$(git branch --show-current)"
STOP_REASON="running"
ITERATIONS=0
failures=0

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
  "piModel": "$(json_escape "$PI_MODEL")",
  "piProvider": "$(json_escape "$PI_PROVIDER")",
  "piThinking": "$(json_escape "$PI_THINKING")",
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
    echo "# Overnight run report"
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
    echo "- Pi model: \`${PI_MODEL:-default}\`"
    echo "- Pi provider: \`${PI_PROVIDER:-default}\`"
    echo "- Pi thinking: \`${PI_THINKING:-default}\`"
    echo "- Iterations: \`$ITERATIONS\`"
    echo "- Soft failures: \`$failures\`"
    echo
    echo "## Logs"
    find "$LOG_DIR" -maxdepth 1 -type f -name 'iter-*.log' -print | sort -V | sed 's/^/- /'
    echo
    echo "## LOOP tokens"
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

archive_watch_file() {
  local label="$1"
  local path="$2"
  if [ -f "$path" ]; then
    local dest="$WATCH_ARCHIVE_DIR/${label}-iter${ITERATIONS}-watches.json"
    cp "$path" "$dest" 2>/dev/null || true
    rm -f "$path"
    append_event "watch-archived" "$label:$path -> $dest"
  fi
}

clear_stray_watches() {
  [ "$CLEAR_WATCHES" = "1" ] || return 0
  archive_watch_file "project" ".pi/agent-runs/.scheduler/watches.json"
  archive_watch_file "root" "$HOME/.pi/agent-runs/.scheduler/watches.json"
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

run_pi_iteration() {
  local iter="$1"
  local out="$2"
  local prompt
  prompt="$(cat <<EOF
[overnight-loop harness]
QUEUE_FILE=$QUEUE_FILE
RUN_DIR=$RUN_DIR
PUSH_MODE=$PUSH_MODE
NO_LINEAR=1
EXPECTED_COMMIT_GRANULARITY=one-ticket-per-commit
EOF
)
$(cat "$PROMPT_FILE")"

  local pi_args=(-p --approve --session-id "overnight-$STAMP-$iter" -n "overnight-$iter")
  if [ -n "$PI_PROVIDER" ]; then pi_args+=(--provider "$PI_PROVIDER"); fi
  if [ -n "$PI_MODEL" ]; then pi_args+=(--model "$PI_MODEL"); fi
  if [ -n "$PI_THINKING" ]; then pi_args+=(--thinking "$PI_THINKING"); fi
  pi "${pi_args[@]}" "$prompt" >"$out" 2>&1 &
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

load_dotenv_key() {
  local key="$1"
  local file="$2"
  local line=""
  local value=""
  [ "$LOAD_DOTENV" = "1" ] || return 0
  [ -z "${!key:-}" ] || return 0
  [ -f "$file" ] || return 0
  line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" | tail -1 || true)"
  [ -n "$line" ] || return 0
  value="${line#*=}"
  value="${value%$'\r'}"
  # Strip one layer of simple shell-style quotes; never echo the value.
  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi
  export "$key=$value"
}

load_dotenv_key "OPENAI_API_KEY" "$ENV_FILE"

append_event "start" "run dir $RUN_DIR"
write_status "running" "running"
write_report

# Preflight
if [ ! -f "$PROMPT_FILE" ]; then
  echo "[loop] ERROR: prompt file missing: $PROMPT_FILE" >&2
  stop_run "missing-prompt-file"
  exit 1
fi
if [ ! -f "$QUEUE_FILE" ]; then
  echo "[loop] ERROR: queue file missing: $QUEUE_FILE" >&2
  stop_run "missing-queue-file"
  exit 1
fi
if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "[loop] WARN: OPENAI_API_KEY is not set; expected in environment or $ENV_FILE" >&2
  append_event "missing-openai-api-key" "OPENAI_API_KEY unavailable"
else
  append_event "openai-api-key-loaded" "OPENAI_API_KEY available (value redacted)"
fi
if [ -n "$EXPECTED_BRANCH" ] && [ "$CURRENT_BRANCH" != "$EXPECTED_BRANCH" ]; then
  echo "[loop] ERROR: expected branch '$EXPECTED_BRANCH', got '$CURRENT_BRANCH'" >&2
  stop_run "wrong-branch"
  exit 1
fi
if [ "$CURRENT_BRANCH" = "main" ] && [ "$ALLOW_MAIN" != "1" ]; then
  echo "[loop] ERROR: refusing to run on main (set ALLOW_MAIN=1 to override)" >&2
  stop_run "refuse-main"
  exit 1
fi
if [ "$ALLOW_DIRTY" != "1" ] && [ -n "$(git status --porcelain)" ]; then
  echo "[loop] ERROR: working tree is dirty; commit/stash setup first or set ALLOW_DIRTY=1" >&2
  git status --short >&2
  stop_run "dirty-tree-preflight"
  exit 1
fi

clear_stray_watches

echo "[loop] start $(date) — run dir $RUN_DIR"
echo "[loop] branch=$CURRENT_BRANCH prompt=$PROMPT_FILE queue=$QUEUE_FILE pushMode=$PUSH_MODE"
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
    stop_run "stop-file"
    break
  fi

  echo "[loop] === iteration $i/$MAX_ITER $(date) ==="
  append_event "iteration-start" "$i/$MAX_ITER"
  OUT="$LOG_DIR/iter-$STAMP-$i.log"

  clear_stray_watches

  run_pi_iteration "$i" "$OUT"
  rc=$?

  token="$(grep -E '^LOOP: ' "$OUT" | tail -1 || true)"
  echo "[loop] rc=$rc token='${token:-none}' (log: $OUT)"
  tail -3 "$OUT" | sed 's/^/[master] /'
  append_event "iteration-end" "rc=$rc token=${token:-none} log=$OUT"
  write_status "running" "post-iteration-$i"
  write_report

  if grep -q "\[loop\] iteration timeout" "$OUT"; then
    echo "[loop] iteration timed out; halting."
    stop_run "iteration-timeout"
    break
  fi

  if grep -qiE 'usage limit|has-credits: false|status code 429' "$OUT" \
     || [[ "$token" == "LOOP: STOP provider-failure"* ]]; then
    failures=$((failures + 1))
    if [ "$failures" -ge "$MAX_SOFT_FAIL" ]; then
      echo "[loop] $MAX_SOFT_FAIL consecutive quota/provider failures; halting."
      stop_run "provider-failure-window"
      break
    fi
    echo "[loop] quota/provider failure #$failures/$MAX_SOFT_FAIL — sleeping ${QUOTA_SLEEP}s then retrying"
    append_event "quota-sleep" "failure $failures/$MAX_SOFT_FAIL for ${QUOTA_SLEEP}s"
    if ! sleep_interruptible "$QUOTA_SLEEP"; then
      echo "[loop] STOP file present during quota sleep; halting."
      stop_run "stop-file"
      break
    fi
    continue
  fi

  if [ -z "$token" ]; then
    echo "[loop] no LOOP token and no quota signature; halting."
    stop_run "harness-malformed-output"
    break
  fi

  failures=0
  git bundle create "$BACKUP_DIR/continuum-rolling.bundle" --all 2>/dev/null \
    || echo "[loop] WARN: rolling bundle failed"

  case "$token" in
    "LOOP: STOP"*)
      echo "[loop] master requested stop: $token"
      stop_run "${token#LOOP: STOP }"
      break
      ;;
    "LOOP: CONTINUE"*)
      append_event "continue" "$token"
      ;;
    *)
      echo "[loop] unrecognized LOOP token; halting: $token"
      stop_run "unrecognized-loop-token"
      break
      ;;
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

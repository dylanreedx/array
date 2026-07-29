#!/usr/bin/env bash
# Fresh-worker loop for docs/38-tickets/91-agent-tile-ux.
# Start/stop/status through scripts/agent-tile-ux-loopctl.sh, not ad-hoc nohup.

set -uo pipefail
cd "$(dirname "$0")/.."

PROGRAM_DIR="${PROGRAM_DIR:-docs/38-tickets/91-agent-tile-ux}"
PROMPT_FILE="${PROMPT_FILE:-scripts/agent-tile-ux-prompt.md}"
QUEUE_FILE="${QUEUE_FILE:-$PROGRAM_DIR/_QUEUE.md}"
LEDGER_FILE="${LEDGER_FILE:-$PROGRAM_DIR/_LEDGER.md}"
STOP_FILE="${STOP_FILE:-$PROGRAM_DIR/STOP}"
EXPECTED_BRANCH="${EXPECTED_BRANCH:-overnight/agent-ux}"
MAX_ITER="${MAX_ITER:-60}"
MAX_PROVIDER_FAILURES="${MAX_PROVIDER_FAILURES:-6}"
ITER_TIMEOUT_SECONDS="${ITER_TIMEOUT_SECONDS:-9000}"
TELEMETRY_SECONDS="${TELEMETRY_SECONDS:-60}"
QUOTA_SLEEP_SECONDS="${QUOTA_SLEEP_SECONDS:-300}"
PI_WORKER_MODELS="${PI_WORKER_MODELS:-openai-codex/gpt-5.6-sol openai-codex/gpt-5.6-luna}"
PI_THINKING="${PI_THINKING:-medium}"
ROOT_PI_DIR="${ROOT_PI_DIR:-$HOME/.pi}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/continuum-backups}"
CONTROL_DIR="${CONTROL_DIR:-$ROOT_PI_DIR/agent-tile-ux-loop-control/$(basename "$(git rev-parse --show-toplevel)")}"

export CONTINUUM_SKIP_SURFACE_CHECKS="${CONTINUUM_SKIP_SURFACE_CHECKS:-1}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
REPO_NAME="$(basename "$REPO_ROOT")"
BRANCH="$(git branch --show-current)"
START_HEAD="$(git rev-parse HEAD)"
STAMP="$(date +%Y%m%dT%H%M%S)"
RUN_ROOT="${RUN_ROOT:-$ROOT_PI_DIR/agent-tile-ux-runs/$REPO_NAME}"
RUN_DIR="$RUN_ROOT/run-$STAMP"
LOG_DIR="$RUN_DIR/logs"
STATUS_FILE="$RUN_DIR/status.json"
TELEMETRY_FILE="$RUN_DIR/telemetry.json"
EVENTS_FILE="$RUN_DIR/events.jsonl"
REPORT_FILE="$RUN_DIR/report.md"
TASKS_DIR="$RUN_DIR/tasks"

ITERATION=0
ITERATION_PID=""
ITERATION_LOG=""
STOP_REASON="running"
PROVIDER_FAILURES=0

mkdir -p "$LOG_DIR" "$TASKS_DIR" "$RUN_ROOT" "$BACKUP_DIR" "$CONTROL_DIR"
ln -sfn "$RUN_DIR" "$RUN_ROOT/latest" 2>/dev/null || true
printf '%s\n' "$RUN_DIR" > "$CONTROL_DIR/latest-run.txt"
printf '%s\n' "$$" > "$CONTROL_DIR/loop.pid"

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g'; }

# Owner-authorized website work may coexist only while it remains untracked.
# Every tracked change, including anything below website/, remains visible/fatal.
unexpected_status() {
  git status --porcelain | awk '
    $1 == "??" && ($2 == "website/" || $2 ~ /^array-logo[^/]*\.svg$/) { next }
    { print }
  '
}

worker_model_for_iteration() {
  local models=($PI_WORKER_MODELS) count index
  count=${#models[@]}; [ "$count" -gt 0 ] || return 1
  index=$(( (ITERATION - 1) % count ))
  printf '%s\n' "${models[$index]}"
}

review_model_for_worker() {
  case "$1" in
    *gpt-5.6-sol) printf '%s\n' openai-codex/gpt-5.6-luna ;;
    *) printf '%s\n' openai-codex/gpt-5.6-sol ;;
  esac
}

atomic_write() {
  local target="$1" tmp
  tmp="$(mktemp "${target}.tmp.XXXXXX")" || return 1
  cat > "$tmp"
  mv "$tmp" "$target"
}

append_event() {
  local kind="$1" message="${2:-}"
  printf '{"ts":"%s","event":"%s","iteration":%s,"message":"%s"}\n' \
    "$(now_utc)" "$(json_escape "$kind")" "$ITERATION" "$(json_escape "$message")" >> "$EVENTS_FILE"
}

ledger_heartbeat() {
  grep '^last-touch ' "$LEDGER_FILE" 2>/dev/null | tail -1 || true
}

write_status() {
  local state="$1" reason="${2:-$STOP_REASON}" head dirty
  head="$(git rev-parse HEAD 2>/dev/null || true)"
  dirty=false; [ -n "$(unexpected_status 2>/dev/null)" ] && dirty=true
  atomic_write "$STATUS_FILE" <<EOF
{
  "state": "$(json_escape "$state")",
  "reason": "$(json_escape "$reason")",
  "updatedAt": "$(now_utc)",
  "repo": "$(json_escape "$REPO_NAME")",
  "branch": "$(json_escape "$BRANCH")",
  "startHead": "$(json_escape "$START_HEAD")",
  "currentHead": "$(json_escape "$head")",
  "dirty": $dirty,
  "iteration": $ITERATION,
  "iterationPid": "$(json_escape "$ITERATION_PID")",
  "iterationLog": "$(json_escape "$ITERATION_LOG")",
  "providerFailures": $PROVIDER_FAILURES,
  "runDir": "$(json_escape "$RUN_DIR")",
  "ledgerHeartbeat": "$(json_escape "$(ledger_heartbeat)")"
}
EOF
}

newest_source_epoch() {
  local newest=0 file stamp
  while IFS= read -r file; do
    [ -f "$file" ] || continue
    case "$file" in
      Sources/*|Package.swift|scripts/run-matrix.sh)
        stamp="$(stat -f %m "$file" 2>/dev/null || echo 0)"
        [ "$stamp" -gt "$newest" ] && newest="$stamp" ;;
    esac
  done <<EOF
$({ git ls-files; find Sources -type f -print 2>/dev/null; } | sort -u)
EOF
  printf '%s\n' "$newest"
}

write_telemetry() {
  local log_epoch=0 log_size=0 child_list head dirty
  if [ -n "$ITERATION_LOG" ] && [ -f "$ITERATION_LOG" ]; then
    log_epoch="$(stat -f %m "$ITERATION_LOG" 2>/dev/null || echo 0)"
    log_size="$(stat -f %z "$ITERATION_LOG" 2>/dev/null || echo 0)"
  fi
  child_list=""
  if [ -n "$ITERATION_PID" ]; then
    child_list="$(pgrep -P "$ITERATION_PID" 2>/dev/null | tr '\n' ',' | sed 's/,$//' || true)"
  fi
  head="$(git rev-parse HEAD 2>/dev/null || true)"
  dirty=false; [ -n "$(unexpected_status 2>/dev/null)" ] && dirty=true
  atomic_write "$TELEMETRY_FILE" <<EOF
{
  "observedAt": "$(now_utc)",
  "loopPid": $$,
  "iterationPid": "$(json_escape "$ITERATION_PID")",
  "childPids": "$(json_escape "$child_list")",
  "iterationLogMtime": $log_epoch,
  "iterationLogBytes": $log_size,
  "newestTrackedSourceMtime": $(newest_source_epoch),
  "head": "$(json_escape "$head")",
  "dirty": $dirty,
  "ledgerHeartbeat": "$(json_escape "$(ledger_heartbeat)")"
}
EOF
}

write_report() {
  atomic_write "$REPORT_FILE" <<EOF
# Agent-tile UX loop report

- State: \`$STOP_REASON\`
- Run: \`$RUN_DIR\`
- Branch: \`$BRANCH\`
- Start HEAD: \`$START_HEAD\`
- Current HEAD: \`$(git rev-parse HEAD 2>/dev/null || true)\`
- Iterations: \`$ITERATION\`
- Provider failures: \`$PROVIDER_FAILURES\`
- Updated: \`$(now_utc)\`

## Commits since start

$(git log --oneline "$START_HEAD"..HEAD 2>/dev/null || true)

## Control tokens

$(find "$LOG_DIR" -type f -name 'iter-*.log' -print 2>/dev/null | sort | xargs grep -hE 'LOOP: (CONTINUE|STOP)' 2>/dev/null || true)
EOF
}

stop_run() {
  STOP_REASON="$1"
  append_event stop "$STOP_REASON"
  write_status stopped "$STOP_REASON"
  write_telemetry
  write_report
}

cleanup() {
  rm -f "$CONTROL_DIR/loop.pid"
}
trap cleanup EXIT
trap 'touch "$STOP_FILE"; append_event signal "termination requested"' INT TERM

preflight() {
  [ -f "$PROMPT_FILE" ] || { echo "missing prompt: $PROMPT_FILE" >&2; return 1; }
  [ -f "$QUEUE_FILE" ] || { echo "missing queue: $QUEUE_FILE" >&2; return 1; }
  [ -f "$LEDGER_FILE" ] || { echo "missing ledger: $LEDGER_FILE" >&2; return 1; }
  ./scripts/check-agent-tile-ux-program.sh || { echo "agent-tile program structure is invalid" >&2; return 1; }
  [ ! -f "$STOP_FILE" ] || { echo "program STOP is present: $STOP_FILE" >&2; return 1; }
  [ "$BRANCH" = "$EXPECTED_BRANCH" ] || { echo "expected $EXPECTED_BRANCH, got $BRANCH" >&2; return 1; }
  [ "$BRANCH" != main ] || { echo "refusing main" >&2; return 1; }
  [ -z "$(unexpected_status)" ] || { echo "working tree/index has non-website changes" >&2; unexpected_status >&2; return 1; }
  command -v pi >/dev/null 2>&1 || { echo "pi CLI missing" >&2; return 1; }
  pi --list-models gpt-5.6 2>/dev/null | grep -Fq gpt-5.6-sol || { echo "gpt-5.6-sol unavailable" >&2; return 1; }
  pi --list-models gpt-5.6 2>/dev/null | grep -Fq gpt-5.6-luna || { echo "gpt-5.6-luna unavailable" >&2; return 1; }
  if [ -f /tmp/list-displays.swift ]; then
    display_state="$(swift /tmp/list-displays.swift 2>/dev/null || true)"
    printf '%s\n' "$display_state" | grep -Eq 'builtin=true main=true' || {
      echo "built-in Retina display must be Main for deterministic UI baselines" >&2; return 1;
    }
  fi
  return 0
}

run_iteration() {
  local output="$1" prompt watchdog="" monitor="" rc worker_model review_model task_dir session_dir stdout_log stderr_log
  worker_model="$(worker_model_for_iteration)" || return 1
  review_model="$(review_model_for_worker "$worker_model")"
  task_dir="$TASKS_DIR/iteration-$(printf '%03d' "$ITERATION")"
  session_dir="$task_dir/worker-session"
  stdout_log="$task_dir/stdout.log"
  stderr_log="$task_dir/stderr.log"
  mkdir -p "$session_dir" "$task_dir/reviewer-session"
  cat > "$task_dir/task.json" <<EOF
{"iteration":$ITERATION,"workerModel":"$(json_escape "$worker_model")","reviewModel":"$(json_escape "$review_model")","thinking":"$(json_escape "$PI_THINKING")","startedAt":"$(now_utc)","beforeHead":"$(git rev-parse HEAD)"}
EOF
  prompt="[agent-tile-ux harness]
QUEUE_FILE=$QUEUE_FILE
LEDGER_FILE=$LEDGER_FILE
RUN_DIR=$RUN_DIR
TASK_DIR=$task_dir
EXPECTED_BRANCH=$BRANCH
EXPECTED_COMMIT_GRANULARITY=one-ticket-per-commit
WORKER_MODEL=$worker_model
REVIEW_MODEL=$review_model
REVIEW_THINKING=$PI_THINKING

$(cat "$PROMPT_FILE")"

  pi --approve --model "$worker_model" --thinking "$PI_THINKING" \
    --session-dir "$session_dir" --name "agent-tile-$ITERATION" --mode text -p "$prompt" \
    > "$stdout_log" 2> "$stderr_log" &
  ITERATION_PID=$!
  write_status running "iteration-$ITERATION"
  write_telemetry

  (
    while kill -0 "$ITERATION_PID" 2>/dev/null; do
      sleep "$TELEMETRY_SECONDS"
      kill -0 "$ITERATION_PID" 2>/dev/null || break
      write_telemetry
    done
  ) & monitor=$!

  if [ "$ITER_TIMEOUT_SECONDS" -gt 0 ]; then
    (
      sleep "$ITER_TIMEOUT_SECONDS"
      if kill -0 "$ITERATION_PID" 2>/dev/null; then
        echo "[loop] iteration timeout after ${ITER_TIMEOUT_SECONDS}s" >> "$stderr_log"
        kill -TERM "$ITERATION_PID" 2>/dev/null || true
        sleep 15
        kill -KILL "$ITERATION_PID" 2>/dev/null || true
      fi
    ) & watchdog=$!
  fi

  wait "$ITERATION_PID"; rc=$?
  [ -n "$monitor" ] && kill "$monitor" 2>/dev/null || true
  [ -n "$watchdog" ] && kill "$watchdog" 2>/dev/null || true
  cat "$stdout_log" "$stderr_log" > "$output"
  printf '{"iteration":%s,"workerModel":"%s","reviewModel":"%s","thinking":"%s","finishedAt":"%s","exitCode":%s}\n' \
    "$ITERATION" "$(json_escape "$worker_model")" "$(json_escape "$review_model")" "$(json_escape "$PI_THINKING")" "$(now_utc)" "$rc" > "$task_dir/result.json"
  ITERATION_PID=""
  write_telemetry
  return "$rc"
}

validate_iteration_commit() {
  local before_head="$1" token="$2" ticket changed allowed path fence fence_prefix fence_suffix middle path_allowed subject count state task_dir
  ticket="${token#LOOP: CONTINUE }"
  ticket="${ticket#skipped:}"
  case "$ticket" in P*.md) ;; *) echo "invalid ticket in CONTINUE token: $ticket" >&2; return 1 ;; esac
  [ -f "$PROGRAM_DIR/$ticket" ] || { echo "token names missing packet: $ticket" >&2; return 1; }

  count="$(git rev-list --count "$before_head"..HEAD)"
  [ "$count" = 1 ] || { echo "iteration must create exactly one commit, created $count" >&2; return 1; }
  subject="$(git log -1 --format=%s)"
  printf '%s\n' "$subject" | grep -Eq '^(feat|fix|refactor|test|docs|chore|perf)\(agent-tile\): .+' || {
    echo "invalid ticket commit subject: $subject" >&2; return 1;
  }

  state="$(grep -F "| \`$ticket\` |" "$LEDGER_FILE" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3}')"
  task_dir="$TASKS_DIR/iteration-$(printf '%03d' "$ITERATION")"
  [ -s "$task_dir/review-final.md" ] || { echo "missing durable independent review" >&2; return 1; }
  [ -s "$task_dir/staged.diff" ] || { echo "missing staged review diff" >&2; return 1; }
  find "$task_dir/reviewer-session" -type f -size +0c -print -quit 2>/dev/null | grep -q . || {
    echo "missing reviewer session log" >&2; return 1;
  }
  grep -Eq '^DECISION: APPROVE$' "$task_dir/review-final.md" || {
    echo "independent review did not approve" >&2; return 1;
  }
  case "$token:$state" in
    *skipped:*:blocked) ;;
    *skipped:*) echo "skipped ticket must be ledger state blocked, got $state" >&2; return 1 ;;
    *:done) ;;
    *) echo "completed ticket must be ledger state done, got $state" >&2; return 1 ;;
  esac

  allowed="$(sed -n '/^## Files$/,/^The file fence/p' "$PROGRAM_DIR/$ticket" | sed -nE 's/^- `([^`]+)`.*/\1/p')"
  changed="$(git diff-tree --no-commit-id --name-only -r HEAD)"
  printf '%s\n' "$changed" | grep -Fqx "$LEDGER_FILE" || {
    echo "ticket commit did not update $LEDGER_FILE" >&2; return 1;
  }
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ "$path" = "$LEDGER_FILE" ] && continue
    path_allowed=0
    while IFS= read -r fence; do
      [ -n "$fence" ] || continue
      case "$fence" in
        *'*'*)
          # Packet fences currently permit one pathname-style `*` for a
          # direct-child family such as Fixtures/*.md. Unlike a bare `case`
          # glob, this deliberately refuses to let `*` cross `/`.
          fence_prefix="${fence%%\**}"
          fence_suffix="${fence#*\*}"
          case "$fence_suffix" in *'*'*) continue ;; esac
          case "$path" in
            "$fence_prefix"*"$fence_suffix")
              middle="${path#"$fence_prefix"}"
              middle="${middle%"$fence_suffix"}"
              case "$middle" in */*) ;; *) path_allowed=1; break ;; esac
              ;;
          esac
          ;;
        *) [ "$path" = "$fence" ] && { path_allowed=1; break; } ;;
      esac
    done <<FENCES
$allowed
FENCES
    [ "$path_allowed" = 1 ] || {
      echo "ticket commit changed path outside packet fence: $path" >&2; return 1;
    }
  done <<EOF
$changed
EOF
  return 0
}

if ! preflight; then
  stop_run preflight-failed
  exit 1
fi

git bundle create "$BACKUP_DIR/continuum-agent-tile-$STAMP-start.bundle" --all >/dev/null 2>&1 || \
  append_event backup-warning "start bundle failed"
append_event start "$RUN_DIR"
write_status running starting
write_telemetry
write_report

echo "[loop] agent-tile UX start: $RUN_DIR"
echo "[loop] branch=$BRANCH models=$PI_WORKER_MODELS thinking=$PI_THINKING"

for ITERATION in $(seq 1 "$MAX_ITER"); do
  if [ -f "$STOP_FILE" ]; then stop_run stop-file; break; fi

  ITERATION_LOG="$LOG_DIR/iter-$STAMP-$ITERATION.log"
  BEFORE_ITERATION_HEAD="$(git rev-parse HEAD)"
  append_event iteration-start "$ITERATION"
  write_status running "iteration-$ITERATION"
  run_iteration "$ITERATION_LOG"; rc=$?

  token="$(tr -d '\140' < "$ITERATION_LOG" | grep -oE 'LOOP: (CONTINUE|STOP)[^[:cntrl:]]*' | tail -1 || true)"
  printf '%s\n' "${token:-none}" > "$TASKS_DIR/iteration-$(printf '%03d' "$ITERATION")/control-token.txt"
  append_event iteration-end "rc=$rc token=${token:-none}"
  echo "[loop] iteration=$ITERATION rc=$rc token='${token:-none}' log=$ITERATION_LOG"
  tail -4 "$ITERATION_LOG" 2>/dev/null | sed 's/^/[iter] /'

  if grep -q '\[loop\] iteration timeout' "$ITERATION_LOG"; then stop_run iteration-timeout; break; fi

  if grep -qiE 'usage limit|session limit|rate limit|status code 429|overloaded|quota|ENOTFOUND|unable to connect|connection (reset|refused)|network error|fetch failed' "$ITERATION_LOG"; then
    PROVIDER_FAILURES=$((PROVIDER_FAILURES + 1))
    if [ -n "$(unexpected_status)" ]; then stop_run dirty-after-provider-failure; break; fi
    if [ "$(git rev-parse HEAD)" != "$BEFORE_ITERATION_HEAD" ]; then stop_run provider-failure-after-unvalidated-commit; break; fi
    if [ "$PROVIDER_FAILURES" -ge "$MAX_PROVIDER_FAILURES" ]; then stop_run provider-failure-window; break; fi
    append_event provider-backoff "failure $PROVIDER_FAILURES sleeping ${QUOTA_SLEEP_SECONDS}s"
    sleep "$QUOTA_SLEEP_SECONDS"
    continue
  fi

  PROVIDER_FAILURES=0
  if [ -z "$token" ]; then stop_run harness-malformed-output; break; fi

  case "$token" in
    "LOOP: CONTINUE"*)
      if [ -n "$(unexpected_status)" ]; then stop_run dirty-after-continue; break; fi
      if ! validate_iteration_commit "$BEFORE_ITERATION_HEAD" "$token"; then stop_run invalid-ticket-commit; break; fi
      git bundle create "$BACKUP_DIR/continuum-agent-tile-rolling.bundle" --all >/dev/null 2>&1 || true
      append_event continue "$token" ;;
    "LOOP: STOP"*)
      if [ -n "$(unexpected_status)" ]; then stop_run dirty-after-stop; break; fi
      if [ "$(git rev-parse HEAD)" != "$BEFORE_ITERATION_HEAD" ]; then stop_run unexpected-commit-before-stop; break; fi
      stop_run "${token#LOOP: STOP }"
      break ;;
    *) stop_run unrecognized-loop-token; break ;;
  esac
  write_status running "post-iteration-$ITERATION"
  write_report
done

if [ "$STOP_REASON" = running ]; then stop_run max-iterations; fi

echo "[loop] finished: $STOP_REASON"
echo "[loop] status: $STATUS_FILE"
echo "[loop] report: $REPORT_FILE"

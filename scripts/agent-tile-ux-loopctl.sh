#!/usr/bin/env bash
# Conservative lifecycle and liveness view for agent-tile-ux-loop.sh.

set -uo pipefail
cd "$(dirname "$0")/.."

PROGRAM_DIR="${PROGRAM_DIR:-docs/38-tickets/91-agent-tile-ux}"
STOP_FILE="${STOP_FILE:-$PROGRAM_DIR/STOP}"
ROOT_PI_DIR="${ROOT_PI_DIR:-$HOME/.pi}"
CONTROL_DIR="${CONTROL_DIR:-$ROOT_PI_DIR/agent-tile-ux-loop-control/$(basename "$(git rev-parse --show-toplevel)")}"
LOOP_SCRIPT="${LOOP_SCRIPT:-./scripts/agent-tile-ux-loop.sh}"
SUPERVISOR_LOG="$CONTROL_DIR/supervisor.log"
EXPECTED_BRANCH="${EXPECTED_BRANCH:-overnight/agent-ux}"
STALE_SECONDS="${STALE_SECONDS:-2100}"

mkdir -p "$CONTROL_DIR"

pid_value() { [ -f "$CONTROL_DIR/loop.pid" ] && cat "$CONTROL_DIR/loop.pid" 2>/dev/null || true; }
pid_live() { local p; p="$(pid_value)"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
latest_run() { [ -f "$CONTROL_DIR/latest-run.txt" ] && cat "$CONTROL_DIR/latest-run.txt" 2>/dev/null || true; }
json_number() {
  local file="$1" key="$2"
  sed -nE "s/.*\"$key\"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p" "$file" 2>/dev/null | head -1
}
json_string() {
  local file="$1" key="$2"
  sed -nE "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" "$file" 2>/dev/null | head -1
}

start_loop() {
  if pid_live; then echo "agent-tile loop already running (pid $(pid_value))"; return 0; fi
  if [ -f "$STOP_FILE" ]; then
    echo "refusing start: $STOP_FILE is present; run '$0 arm' after reviewing preconditions" >&2
    return 2
  fi
  local branch
  branch="$(git branch --show-current)"
  [ "$branch" = "$EXPECTED_BRANCH" ] || { echo "wrong branch: $branch" >&2; return 2; }
  [ -z "$(git status --porcelain)" ] || { echo "refusing dirty tree/index" >&2; git status --short >&2; return 2; }
  if pgrep -f 'agent-(ux|tile-ux)-loop\.sh|claude -p.*agent-tile-ux' >/dev/null 2>&1; then
    echo "another agent UX loop/worker appears active; refusing a second writer" >&2
    pgrep -fl 'agent-(ux|tile-ux)-loop\.sh|claude -p.*agent-tile-ux' >&2 || true
    return 2
  fi
  : > "$SUPERVISOR_LOG"
  nohup caffeinate -is "$LOOP_SCRIPT" >> "$SUPERVISOR_LOG" 2>&1 &
  local launcher=$!
  printf '%s\n' "$launcher" > "$CONTROL_DIR/launcher.pid"
  sleep 3
  if pid_live; then
    echo "started agent-tile UX loop (pid $(pid_value))"
    echo "log: $SUPERVISOR_LOG"
    return 0
  fi
  echo "loop did not stay up; inspect $SUPERVISOR_LOG" >&2
  tail -30 "$SUPERVISOR_LOG" >&2 || true
  return 3
}

status_loop() {
  local run status telemetry loop_pid now log_epoch source_epoch log_age source_age progress_age
  run="$(latest_run)"; loop_pid="$(pid_value)"; now="$(date +%s)"
  echo "program: 91-agent-tile-ux"
  echo "branch:  $(git branch --show-current)"
  echo "loop:    $(pid_live && echo "running pid=$loop_pid" || echo stopped)"
  echo "STOP:    $([ -f "$STOP_FILE" ] && echo present || echo absent)"
  echo "tree:    $([ -z "$(git status --porcelain)" ] && echo clean || echo DIRTY)"
  echo "run:     ${run:-none}"

  [ -n "$run" ] || return 10
  status="$run/status.json"; telemetry="$run/telemetry.json"
  if [ -f "$status" ]; then
    echo "state:   $(json_string "$status" state) / $(json_string "$status" reason)"
    echo "iter:    $(json_number "$status" iteration) pid=$(json_string "$status" iterationPid)"
    echo "updated: $(json_string "$status" updatedAt)"
  else
    echo "state:   missing status.json"
  fi

  log_epoch="$(json_number "$telemetry" iterationLogMtime)"
  source_epoch="$(json_number "$telemetry" newestTrackedSourceMtime)"
  if [ -z "$log_epoch" ] || [ -z "$source_epoch" ]; then
    echo "signals: unavailable/incomplete telemetry — stale classification withheld"
    progress_age=0
  else
    log_age=$((now - log_epoch)); source_age=$((now - source_epoch))
    progress_age="$log_age"; [ "$source_age" -lt "$progress_age" ] && progress_age="$source_age"
    echo "signals: iteration-log-age=${log_age}s tracked-source-age=${source_age}s"
  fi
  echo "ledger:  $(grep '^last-touch ' "$PROGRAM_DIR/_LEDGER.md" 2>/dev/null | tail -1)"

  local work_children
  work_children="$(pgrep -fl 'swift-build|swift-frontend|run-matrix|xcodebuild|codex exec|ContinuumRevived.*Checks' 2>/dev/null || true)"
  if [ -n "$work_children" ]; then
    echo "work:    active build/test/review child"
    printf '%s\n' "$work_children" | sed 's/^/         /'
  else
    echo "work:    no build/test/review child observed"
  fi

  if pid_live; then
    if [ "$progress_age" -gt "$STALE_SECONDS" ] && [ -z "$work_children" ]; then
      echo "result:  STALE CANDIDATE — inspect iteration log and child tree; do not blind-restart"
      echo "children:"
      ps -o pid,ppid,etime,%cpu,command -ax | awk -v p="$loop_pid" '$1==p || $2==p {print}' | sed 's/^/         /'
      return 11
    fi
    echo "result:  running; progress or quiet-within-threshold"
    return 0
  fi

  if [ -n "$(git status --porcelain)" ]; then
    echo "result:  STOPPED DIRTY — preserve and inspect before restart"
    git status --short | sed 's/^/         /'
    return 12
  fi
  local reason
  reason="$(json_string "$status" reason)"
  case "$reason" in
    supervised-required:*) echo "result:  supervised review required"; return 20 ;;
    queue-drained) echo "result:  queue drained"; return 0 ;;
    *) echo "result:  stopped cleanly; inspect reason before restart"; return 10 ;;
  esac
}

stop_loop() {
  touch "$STOP_FILE"
  echo "stop requested through $STOP_FILE; current iteration may finish before exit"
}

arm_loop() {
  if pid_live; then echo "refusing to arm while loop is running" >&2; return 2; fi
  rm -f "$STOP_FILE"
  echo "program armed; STOP removed"
}

restart_loop() {
  if pid_live; then
    local iter run status iter_pid
    run="$(latest_run)"; status="$run/status.json"; iter_pid="$(json_string "$status" iterationPid)"
    if [ -n "$iter_pid" ] && kill -0 "$iter_pid" 2>/dev/null; then
      echo "refusing restart: iteration child $iter_pid is live" >&2
      return 2
    fi
    echo "refusing restart: loop process is still live; use stop and wait" >&2
    return 2
  fi
  [ -z "$(git status --porcelain)" ] || { echo "refusing restart: tree/index dirty" >&2; return 2; }
  [ ! -f "$STOP_FILE" ] || { echo "refusing restart: STOP present; review then arm" >&2; return 2; }
  start_loop
}

show_logs() {
  local run
  run="$(latest_run)"
  if [ "${1:-}" = "--follow" ]; then tail -F "$SUPERVISOR_LOG"; return; fi
  echo "== supervisor =="; tail -80 "$SUPERVISOR_LOG" 2>/dev/null || true
  if [ -n "$run" ]; then
    echo "== latest iteration =="
    local latest
    latest="$(find "$run/logs" -type f -name 'iter-*.log' -print 2>/dev/null | sort -V | tail -1)"
    [ -n "$latest" ] && tail -120 "$latest" || true
  fi
}

case "${1:-status}" in
  start) start_loop ;;
  status) status_loop ;;
  stop) stop_loop ;;
  arm) arm_loop ;;
  restart) restart_loop ;;
  logs) show_logs "${2:-}" ;;
  *) echo "usage: $0 {arm|start|status|logs [--follow]|stop|restart}" >&2; exit 2 ;;
esac

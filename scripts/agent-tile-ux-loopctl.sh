#!/usr/bin/env bash
# Small lifecycle wrapper for agent-tile-ux-loop.sh.

set -uo pipefail
cd "$(dirname "$0")/.."

PROGRAM_DIR="${PROGRAM_DIR:-docs/38-tickets/91-agent-tile-ux}"
STOP_FILE="$PROGRAM_DIR/STOP"
EXPECTED_BRANCH="${EXPECTED_BRANCH:-overnight/agent-ux}"
ROOT_PI_DIR="${ROOT_PI_DIR:-$HOME/.pi}"
CONTROL_DIR="${CONTROL_DIR:-$ROOT_PI_DIR/agent-tile-ux-loop-control/$(basename "$(git rev-parse --show-toplevel)")}"
LOOP_SCRIPT="${LOOP_SCRIPT:-./scripts/agent-tile-ux-loop.sh}"
SUPERVISOR_LOG="$CONTROL_DIR/supervisor.log"
mkdir -p "$CONTROL_DIR"

pid_value() { [ -f "$CONTROL_DIR/loop.pid" ] && cat "$CONTROL_DIR/loop.pid" 2>/dev/null || true; }
pid_live() { local pid; pid="$(pid_value)"; [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }
latest_run() { [ -f "$CONTROL_DIR/latest-run.txt" ] && cat "$CONTROL_DIR/latest-run.txt" 2>/dev/null || true; }
json_string() {
  local file="$1" key="$2"
  sed -nE "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" "$file" 2>/dev/null | head -1
}
unexpected_status() {
  git status --porcelain | awk '
    $1 == "??" && ($2 == "website/" || $2 ~ /^array-logo.*[.]svg$/) { next }
    { print }
  '
}

start_loop() {
  if pid_live; then echo "already running: pid $(pid_value)"; return 0; fi
  [ ! -f "$STOP_FILE" ] || { echo "STOP is present; run '$0 arm' first" >&2; return 2; }
  [ "$(git branch --show-current)" = "$EXPECTED_BRANCH" ] || { echo "wrong branch" >&2; return 2; }
  [ -z "$(unexpected_status)" ] || { echo "tracked/non-authorized changes present" >&2; unexpected_status >&2; return 2; }
  : > "$SUPERVISOR_LOG"
  nohup caffeinate -is "$LOOP_SCRIPT" >> "$SUPERVISOR_LOG" 2>&1 &
  printf '%s\n' "$!" > "$CONTROL_DIR/launcher.pid"
  sleep 3
  if pid_live; then
    echo "started: pid $(pid_value)"
    echo "log: $SUPERVISOR_LOG"
  else
    echo "loop did not stay up" >&2
    tail -60 "$SUPERVISOR_LOG" >&2 || true
    return 3
  fi
}

status_loop() {
  local run status pid child
  run="$(latest_run)"; pid="$(pid_value)"
  echo "branch: $(git branch --show-current)"
  echo "loop:   $(pid_live && echo "running pid=$pid" || echo stopped)"
  echo "STOP:   $([ -f "$STOP_FILE" ] && echo present || echo absent)"
  if [ -n "$(unexpected_status)" ]; then
    echo "tree:   DIRTY"
    unexpected_status | sed 's/^/        /'
  else
    echo "tree:   clean except authorized untracked website/logos"
  fi
  echo "run:    ${run:-none}"
  [ -n "$run" ] || return 0
  status="$run/status.json"
  echo "state:  $(json_string "$status" state) / $(json_string "$status" detail)"
  echo "ticket: $(json_string "$status" ticket)"
  echo "head:   $(json_string "$status" head)"
  echo "update: $(json_string "$status" updatedAt)"
  child="$(json_string "$status" childPid)"
  if [ -n "$child" ] && kill -0 "$child" 2>/dev/null; then
    echo "child:  $(ps -o pid=,ppid=,etime=,%cpu=,comm= -p "$child" 2>/dev/null)"
    pgrep -P "$child" 2>/dev/null | while read -r descendant; do
      ps -o pid=,ppid=,etime=,%cpu=,comm= -p "$descendant" 2>/dev/null | sed 's/^/        /'
    done
  else
    echo "child:  none active"
  fi
  echo "recent:"
  tail -12 "$run/events.log" 2>/dev/null | sed 's/^/        /' || true
}

show_logs() {
  local run
  run="$(latest_run)"
  if [ "${1:-}" = --follow ]; then tail -F "$SUPERVISOR_LOG"; return; fi
  tail -100 "$SUPERVISOR_LOG" 2>/dev/null || true
  [ -z "$run" ] || find "$run/tasks" -type f \( -name 'worker-*.md' -o -name 'review-final-*.md' \) -print | sort | tail -6
}

case "${1:-status}" in
  arm) rm -f "$STOP_FILE"; echo "armed" ;;
  start|restart) start_loop ;;
  status) status_loop ;;
  stop) touch "$STOP_FILE"; echo "STOP armed; loop exits between tickets" ;;
  logs) show_logs "${2:-}" ;;
  *) echo "usage: $0 {arm|start|restart|status|logs [--follow]|stop}" >&2; exit 2 ;;
esac

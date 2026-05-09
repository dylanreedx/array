#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "qa/flows/lib.sh is a shared library and must be sourced." >&2
  exit 2
fi

set -euo pipefail

QA_FLOW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QA_ROOT="$(cd "$QA_FLOW_DIR/../.." && pwd)"
QA_RUNS_ROOT="${CONTINUUM_RUNS_DIR:-$QA_ROOT/qa-runs}"
QA_APP="${CONTINUUM_APP:-$QA_ROOT/.build/debug/continuum-revived}"
QA_APP_PID=""
QA_FLOW_NAME=""
QA_RUN_DIR=""
QA_MANIFEST_EVENTS=""
QA_STARTED_AT=""
QA_FINISHED=0

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    return 1
  fi
}

require_external_drivers() {
  require_command osascript
  require_command screencapture
  require_command cliclick
}

begin_flow() {
  QA_FLOW_NAME="$1"
  QA_STARTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  local timestamp
  timestamp="$(date -u +"%Y%m%dT%H%M%SZ")"
  QA_RUN_DIR="$QA_RUNS_ROOT/${QA_FLOW_NAME}-${timestamp}"
  mkdir -p "$QA_RUN_DIR"
  QA_MANIFEST_EVENTS="$QA_RUN_DIR/.events.jsonl"
  : > "$QA_MANIFEST_EVENTS"
  trap flow_abort ERR INT TERM
  echo "QA run: $QA_RUN_DIR"
}

flow_abort() {
  local exit_code=$?
  trap - ERR INT TERM
  if [[ -n "$QA_RUN_DIR" && "$QA_FINISHED" -eq 0 ]]; then
    append_event "flow-aborted" "fail" "" "flow exited with status ${exit_code}"
    write_manifest fail || true
  fi
  if [[ -n "$QA_APP_PID" && "${CONTINUUM_QA_KEEP_APP:-0}" != "1" ]]; then
    kill "$QA_APP_PID" >/dev/null 2>&1 || true
    wait "$QA_APP_PID" >/dev/null 2>&1 || true
  fi
  exit "$exit_code"
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

append_event() {
  local step="$1"
  local status="$2"
  local png="${3:-}"
  local notes="${4:-}"
  local at
  at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  local escaped_step escaped_status escaped_png escaped_notes escaped_at
  escaped_step="$(printf "%s" "$step" | json_escape)"
  escaped_status="$(printf "%s" "$status" | json_escape)"
  escaped_png="$(printf "%s" "$png" | json_escape)"
  escaped_notes="$(printf "%s" "$notes" | json_escape)"
  escaped_at="$(printf "%s" "$at" | json_escape)"
  printf '{"step":%s,"status":%s,"png":%s,"notes":%s,"at":%s}\n' \
    "$escaped_step" "$escaped_status" "$escaped_png" "$escaped_notes" "$escaped_at" >> "$QA_MANIFEST_EVENTS"
}

capture_step() {
  local step="$1"
  local notes="${2:-}"
  local png_name
  png_name="$(printf "%02d-%s.png" "$(wc -l < "$QA_MANIFEST_EVENTS" | tr -d " ")" "$(slug "$step")")"
  if screencapture -x "$QA_RUN_DIR/$png_name"; then
    append_event "$step" "pass" "$png_name" "$notes"
  else
    append_event "$step" "fail" "" "screencapture failed: $notes"
    return 1
  fi
}

write_manifest() {
  local status="$1"
  local finished_at
  finished_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  python3 - "$QA_FLOW_NAME" "$QA_STARTED_AT" "$finished_at" "$status" "$QA_MANIFEST_EVENTS" > "$QA_RUN_DIR/manifest.json" <<'PY'
import json
import sys

flow, started_at, finished_at, status, events_path = sys.argv[1:]
events = []
with open(events_path, "r", encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if line:
            events.append(json.loads(line))
json.dump(
    {
        "flow": flow,
        "startedAt": started_at,
        "finishedAt": finished_at,
        "status": status,
        "events": events,
    },
    sys.stdout,
    indent=2,
    sort_keys=True,
)
sys.stdout.write("\n")
PY
}

finish_flow() {
  local status="$1"
  trap - ERR INT TERM
  QA_FINISHED=1
  write_manifest "$status"
  if [[ -n "$QA_APP_PID" && "${CONTINUUM_QA_KEEP_APP:-0}" != "1" ]]; then
    kill "$QA_APP_PID" >/dev/null 2>&1 || true
    wait "$QA_APP_PID" >/dev/null 2>&1 || true
  fi
  if [[ "$status" == "pass" ]]; then
    echo "QA flow passed: $QA_RUN_DIR"
  else
    echo "QA flow failed: $QA_RUN_DIR" >&2
    return 1
  fi
}

launch_continuum() {
  local in_process_flow="${1:-}"
  if [[ ! -x "$QA_APP" ]]; then
    echo "Continuum executable not found or not executable: $QA_APP" >&2
    echo "Run swift build or set CONTINUUM_APP." >&2
    return 1
  fi
  mkdir -p "$QA_RUN_DIR/capture"
  if [[ -n "$in_process_flow" ]]; then
    CONTINUUM_SMOKE_TEST=1 \
      CONTINUUM_QA_FLOW="$in_process_flow" \
      CONTINUUM_QA_CAPTURE="$QA_RUN_DIR/capture" \
      "$QA_APP" &
  else
    CONTINUUM_QA_CAPTURE="$QA_RUN_DIR/capture" "$QA_APP" &
  fi
  QA_APP_PID="$!"
  sleep "${CONTINUUM_QA_BOOT_DELAY:-1.0}"
}

window_bounds() {
  osascript <<'APPLESCRIPT'
tell application "System Events"
  set matches to windows of processes whose name contains "continuum-revived"
  if (count of matches) is 0 then error "continuum-revived window not found"
  tell item 1 of matches
    set p to position
    set s to size
    return (item 1 of p as text) & "," & (item 2 of p as text) & "," & (item 1 of s as text) & "," & (item 2 of s as text)
  end tell
end tell
APPLESCRIPT
}

set_window_bounds() {
  local left="$1"
  local top="$2"
  local width="$3"
  local height="$4"
  osascript "$left" "$top" "$width" "$height" <<'APPLESCRIPT'
on run argv
  set leftPos to item 1 of argv as integer
  set topPos to item 2 of argv as integer
  set targetWidth to item 3 of argv as integer
  set targetHeight to item 4 of argv as integer
  tell application "System Events"
    set matches to windows of processes whose name contains "continuum-revived"
    if (count of matches) is 0 then error "continuum-revived window not found"
    tell item 1 of matches
      set position to {leftPos, topPos}
      set size to {targetWidth, targetHeight}
    end tell
  end tell
end run
APPLESCRIPT
}

click_center_of_window() {
  local bounds left top width height x y
  bounds="$(window_bounds)"
  IFS=',' read -r left top width height <<< "$bounds"
  x=$((left + width / 2))
  y=$((top + height / 2))
  cliclick "c:${x},${y}"
}

drag_window_center_by() {
  local dx="$1"
  local dy="$2"
  local bounds left top width height start_x start_y end_x end_y
  bounds="$(window_bounds)"
  IFS=',' read -r left top width height <<< "$bounds"
  start_x=$((left + width / 2))
  start_y=$((top + height / 2))
  end_x=$((start_x + dx))
  end_y=$((start_y + dy))
  cliclick "m:${start_x},${start_y}" "dd:${start_x},${start_y}" "dm:${end_x},${end_y}" "du:${end_x},${end_y}"
}

cmd_k() {
  cliclick kd:cmd t:k ku:cmd
}

escape_key() {
  cliclick kp:esc
}

quit_app_with_osascript() {
  osascript <<'APPLESCRIPT'
tell application "System Events"
  set matches to processes whose name contains "continuum-revived"
  repeat with appProcess in matches
    tell appProcess to keystroke "q" using command down
  end repeat
end tell
APPLESCRIPT
}

diagnostic_snapshot() {
  local output="$1"
  local report_dir="$HOME/Library/Logs/DiagnosticReports"
  if [[ -d "$report_dir" ]]; then
    find "$report_dir" -maxdepth 1 -type f -name '*continuum-revived*' -print | sort > "$output"
  else
    : > "$output"
  fi
}

slug() {
  printf "%s" "$1" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]_-' '-' | sed -E 's/^-+//; s/-+$//; s/^$/capture/'
}

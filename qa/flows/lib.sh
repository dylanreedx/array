#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "qa/flows/lib.sh is a shared library and must be sourced." >&2
  exit 2
fi

set -euo pipefail

QA_FLOW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QA_ROOT="$(cd "$QA_FLOW_DIR/../.." && pwd)"
QA_RUNS_ROOT="${CONTINUUM_RUNS_DIR:-$QA_ROOT/qa-runs}"
QA_APP="${CONTINUUM_APP:-$QA_ROOT/.build/debug/Array}"
QA_APP_PID=""
QA_WINDOW_ID=""
QA_CAFFEINATE_PID=""
QA_FLOW_NAME=""
QA_RUN_DIR=""
QA_MANIFEST_EVENTS=""
QA_STARTED_AT=""
QA_FINISHED=0
QA_ASSERTIONS=0
QA_LAUNCHED_AT_EPOCH=""

canonical_path() {
  python3 - "$1" <<'PY'
import os,sys
print(os.path.realpath(os.path.abspath(sys.argv[1])))
PY
}

validate_isolated_path() {
  local label="$1" raw="$2" allowed_root="$3" canonical allowed
  [[ "$raw" == /* && "$allowed_root" == /* ]] || { echo "$label must be absolute" >&2; return 1; }
  canonical="$(canonical_path "$raw")"
  allowed="$(canonical_path "$allowed_root")"
  [[ "$canonical" != "/" && "$canonical" != "$allowed" && "$canonical" == "$allowed/"* ]] || {
    echo "$label escapes allowed root: $canonical (allowed $allowed)" >&2; return 1;
  }
  printf '%s\n' "$canonical"
}

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
  if [[ -n "${CONTINUUM_QA_RUN_DIR:-}" ]]; then
    [[ "$CONTINUUM_QA_RUN_DIR" == /* ]] || { echo "CONTINUUM_QA_RUN_DIR must be absolute" >&2; return 2; }
    QA_RUN_DIR="$CONTINUUM_QA_RUN_DIR"
  else
    QA_RUN_DIR="$QA_RUNS_ROOT/${QA_FLOW_NAME}-${timestamp}"
  fi
  mkdir -p "$QA_RUN_DIR"
  QA_MANIFEST_EVENTS="$QA_RUN_DIR/.events.jsonl"
  : > "$QA_MANIFEST_EVENTS"
  trap flow_abort ERR INT TERM
  if command -v caffeinate >/dev/null 2>&1; then
    caffeinate -dimsu -w "$$" &
    QA_CAFFEINATE_PID="$!"
  fi
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
  cleanup_flow_resources
  exit "$exit_code"
}

cleanup_flow_resources() {
  if [[ -n "$QA_CAFFEINATE_PID" ]]; then
    kill "$QA_CAFFEINATE_PID" >/dev/null 2>&1 || true
    wait "$QA_CAFFEINATE_PID" >/dev/null 2>&1 || true
    QA_CAFFEINATE_PID=""
  fi
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
  if capture_app_window "$QA_RUN_DIR/$png_name"; then
    append_event "$step" "pass" "$png_name" "$notes"
  else
    append_event "$step" "fail" "" "screencapture failed: $notes"
    return 1
  fi
}

assert_flow() {
  local step="$1"
  local notes="$2"
  shift 2
  if "$@"; then
    QA_ASSERTIONS=$((QA_ASSERTIONS + 1))
    append_event "$step" "pass" "" "$notes"
  else
    append_event "$step" "fail" "" "$notes"
    return 1
  fi
}

assert_file_nonempty() {
  local path="$1"
  [[ -s "$path" ]]
}

assert_app_window_present() {
  window_bounds >/dev/null
}

assert_no_new_diagnostics() {
  local before="$1"
  local after="$2"
  local output="$3"
  comm -13 "$before" "$after" > "$output"
  [[ ! -s "$output" ]]
}

write_manifest() {
  local status="$1"
  local finished_at
  finished_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  python3 - "$QA_FLOW_NAME" "$QA_STARTED_AT" "$finished_at" "$status" "$QA_ASSERTIONS" "$QA_MANIFEST_EVENTS" > "$QA_RUN_DIR/manifest.json" <<'PY'
import json
import sys

flow, started_at, finished_at, status, assertions, events_path = sys.argv[1:]
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
        "assertions": int(assertions),
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
  if [[ "$status" == "pass" && "$QA_ASSERTIONS" -eq 0 ]]; then
    append_event "assertion-contract" "fail" "" "flow attempted to pass without a positive machine assertion"
    status="fail"
  fi
  trap - ERR INT TERM
  QA_FINISHED=1
  write_manifest "$status"
  if [[ -n "$QA_APP_PID" && "${CONTINUUM_QA_KEEP_APP:-0}" != "1" ]]; then
    kill "$QA_APP_PID" >/dev/null 2>&1 || true
    wait "$QA_APP_PID" >/dev/null 2>&1 || true
  fi
  cleanup_flow_resources
  if [[ "$status" == "pass" ]]; then
    echo "QA flow passed: $QA_RUN_DIR"
  elif [[ "$status" == "DISPLAY_DEFERRED" ]]; then
    echo "QA flow DISPLAY_DEFERRED: $QA_RUN_DIR" >&2
    return 3
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
  rm -f "$QA_RUN_DIR/capture/manifest.json"
  QA_LAUNCHED_AT_EPOCH="$(date +%s)"
  local app_args=()
  if [[ -n "${CONTINUUM_QA_PROJECT_GRANT_KEY:-}" ]]; then
    app_args+=("-${CONTINUUM_QA_PROJECT_GRANT_KEY}" YES)
  fi
  if [[ -n "$in_process_flow" ]]; then
    CONTINUUM_SMOKE_TEST=1 \
      CONTINUUM_QA_FLOW="$in_process_flow" \
      CONTINUUM_QA_CAPTURE="$QA_RUN_DIR/capture" \
      "$QA_APP" "${app_args[@]}" &
  else
    CONTINUUM_QA_CAPTURE="$QA_RUN_DIR/capture" "$QA_APP" "${app_args[@]}" &
  fi
  QA_APP_PID="$!"
  wait_for_app_window "${CONTINUUM_QA_READY_TIMEOUT:-20}"
}

resolve_window_id_for_pid() {
  swift - "$QA_APP_PID" <<'SWIFT'
import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let candidates = windows.filter {
  ($0[kCGWindowOwnerPID as String] as? Int32) == pid &&
  ($0[kCGWindowLayer as String] as? Int) == 0 &&
  (($0[kCGWindowAlpha as String] as? Double) ?? 0) > 0
}
func area(_ w: [String: Any]) -> Double {
  let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
  return (b["Width"] as? Double ?? 0) * (b["Height"] as? Double ?? 0)
}
guard let window = candidates.max(by: { area($0) < area($1) }),
      area(window) > 0,
      let id = window[kCGWindowNumber as String] as? UInt32 else { exit(1) }
print(id)
SWIFT
}

wait_for_app_window() {
  local timeout="$1" deadline
  deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$QA_APP_PID" 2>/dev/null; then
      echo "launched app PID $QA_APP_PID exited before window readiness" >&2
      return 1
    fi
    if QA_WINDOW_ID="$(resolve_window_id_for_pid 2>/dev/null)" && [[ -n "$QA_WINDOW_ID" ]]; then
      append_event "window-ready" "pass" "" "pid=$QA_APP_PID cgWindowID=$QA_WINDOW_ID"
      return 0
    fi
    sleep 0.1
  done
  echo "timed out waiting for named readiness app-window(pid=$QA_APP_PID) after ${timeout}s" >&2
  append_event "window-ready" "fail" "" "readiness_timeout pid=$QA_APP_PID timeout=${timeout}s"
  return 1
}

wait_for_named_readiness() {
  local name="$1" path="$2" timeout="${3:-20}" deadline
  deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if [[ -f "$path" && ! -L "$path" && "$(stat -f %m "$path")" -ge "${QA_LAUNCHED_AT_EPOCH:-0}" ]]; then
      append_event "$name" "pass" "" "named readiness file: $path"
      return 0
    fi
    sleep 0.1
  done
  append_event "$name" "fail" "" "readiness_timeout missing: $path"
  return 1
}

assert_window_owned_by_pid() {
  local actual
  actual="$(swift - "$QA_WINDOW_ID" <<'SWIFT'
import CoreGraphics
import Foundation
let wanted = UInt32(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
guard let w = windows.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == wanted }),
      let pid = w[kCGWindowOwnerPID as String] else { exit(1) }
print(pid)
SWIFT
)"
  [[ "$actual" == "$QA_APP_PID" ]]
}

capture_app_window() {
  local output="$1"
  [[ -n "$QA_WINDOW_ID" ]] || return 1
  assert_window_owned_by_pid || return 1
  screencapture -x -o -l"$QA_WINDOW_ID" "$output" || return 1
  [[ -s "$output" ]] || return 1
  local width height
  width="$(sips -g pixelWidth "$output" 2>/dev/null | awk '/pixelWidth/{print $2}')"
  height="$(sips -g pixelHeight "$output" 2>/dev/null | awk '/pixelHeight/{print $2}')"
  local bounds _left _top point_width point_height
  bounds="$(window_bounds)"
  IFS=',' read -r _left _top point_width point_height <<< "$bounds"
  [[ "${width:-0}" -eq $((point_width * 2)) && "${height:-0}" -eq $((point_height * 2)) && $(stat -f %z "$output") -gt 4096 ]]
}

window_bounds() {
  swift - "$QA_WINDOW_ID" <<'SWIFT'
import CoreGraphics
import Foundation
let wanted = UInt32(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
guard let window = windows.first(where: { ($0[kCGWindowNumber as String] as? UInt32) == wanted }),
      let bounds = window[kCGWindowBounds as String] as? [String: Any],
      let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"] else { exit(1) }
print("\(x),\(y),\(width),\(height)")
SWIFT
  return
  osascript <<'APPLESCRIPT' 2>/dev/null || swift - <<'SWIFT'
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
import CoreGraphics
import Foundation
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let candidates = windows.filter { window in
  let owner = (window[kCGWindowOwnerName as String] as? String ?? "").lowercased()
  let layer = window[kCGWindowLayer as String] as? Int ?? -1
  return layer == 0 && owner.contains("continuum-revived")
}
let window = candidates.max { lhs, rhs in
  func area(_ window: [String: Any]) -> Double {
    guard let bounds = window[kCGWindowBounds as String] as? [String: Any] else { return 0 }
    let width = bounds["Width"] as? Double ?? 0
    let height = bounds["Height"] as? Double ?? 0
    return width * height
  }
  return area(lhs) < area(rhs)
}
guard let bounds = window?[kCGWindowBounds as String] as? [String: Any],
      let x = bounds["X"] as? Double,
      let y = bounds["Y"] as? Double,
      let width = bounds["Width"] as? Double,
      let height = bounds["Height"] as? Double else {
  fputs("continuum-revived window not found\n", stderr)
  exit(1)
}
print("\(Int(x)),\(Int(y)),\(Int(width)),\(Int(height))")
SWIFT
}

set_window_bounds() {
  local left="$1"
  local top="$2"
  local width="$3"
  local height="$4"
  if osascript - "$QA_APP_PID" "$left" "$top" "$width" "$height" <<'APPLESCRIPT' 2>/dev/null; then
on run argv
  set targetPID to item 1 of argv as integer
  set leftPos to item 2 of argv as integer
  set topPos to item 3 of argv as integer
  set targetWidth to item 4 of argv as integer
  set targetHeight to item 5 of argv as integer
  tell application "System Events"
    set targetProcess to first process whose unix id is targetPID
    tell window 1 of targetProcess
      set position to {leftPos, topPos}
      set size to {targetWidth, targetHeight}
    end tell
  end tell
end run
APPLESCRIPT
    return 0
  fi

  # Fallback for hosts without System Events/AX trust: use CGWindow bounds for
  # measurement and cliclick to drag the lower-right resize corner.
  local bounds current_left current_top current_width current_height start_x start_y end_x end_y
  bounds="$(window_bounds)"
  IFS=',' read -r current_left current_top current_width current_height <<< "$bounds"
  start_x=$((current_left + current_width - 6))
  start_y=$((current_top + current_height - 6))
  end_x=$((current_left + width - 6))
  end_y=$((current_top + height - 6))
  cliclick "m:${start_x},${start_y}" "dd:${start_x},${start_y}" "dm:${end_x},${end_y}" "du:${end_x},${end_y}"
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
  osascript - "$QA_APP_PID" <<'APPLESCRIPT'
on run argv
tell application "System Events"
  set appProcess to first process whose unix id is (item 1 of argv as integer)
  tell appProcess to keystroke "q" using command down
end tell
end run
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

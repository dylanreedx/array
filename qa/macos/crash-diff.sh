#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: qa/macos/crash-diff.sh before|after|diff <run-dir>" >&2
  exit 2
fi

MODE="$1"
RUN_DIR="$2"
CRASH_DIR="$RUN_DIR/crash"
mkdir -p "$CRASH_DIR"

REPORT_DIRS=(
  "$HOME/Library/Logs/DiagnosticReports"
  "/Library/Logs/DiagnosticReports"
)

snapshot() {
  local out="$1"
  : > "$out"
  for dir in "${REPORT_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    find "$dir" -maxdepth 1 -type f \( \
      -iname 'continuum-revived*.crash' -o \
      -iname 'continuum-revived*.ips' -o \
      -iname 'ContinuumRevived*.crash' -o \
      -iname 'ContinuumRevived*.ips' \
    \) -print 2>/dev/null || true
  done | sort >> "$out"
}

case "$MODE" in
  before)
    snapshot "$CRASH_DIR/before.txt"
    ;;
  after)
    snapshot "$CRASH_DIR/after.txt"
    ;;
  diff)
    [[ -f "$CRASH_DIR/before.txt" ]] || snapshot "$CRASH_DIR/before.txt"
    [[ -f "$CRASH_DIR/after.txt" ]] || snapshot "$CRASH_DIR/after.txt"
    comm -13 "$CRASH_DIR/before.txt" "$CRASH_DIR/after.txt" > "$CRASH_DIR/new.txt" || true
    if [[ -s "$CRASH_DIR/new.txt" ]]; then
      cat > "$CRASH_DIR/verdict.json" <<EOF
{
  "name": "crash-diff",
  "status": "failed",
  "newReportsFile": "crash/new.txt"
}
EOF
      echo "New Continuum crash reports detected:" >&2
      cat "$CRASH_DIR/new.txt" >&2
      exit 1
    else
      cat > "$CRASH_DIR/verdict.json" <<EOF
{
  "name": "crash-diff",
  "status": "passed",
  "newReportsFile": "crash/new.txt"
}
EOF
    fi
    ;;
  *)
    echo "unknown mode: $MODE" >&2
    exit 2
    ;;
esac

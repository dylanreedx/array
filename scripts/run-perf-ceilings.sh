#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

CONFIGURATION="${CONTINUUM_PERF_CONFIGURATION:-debug}"
if [[ "$CONFIGURATION" != debug && "$CONFIGURATION" != release ]]; then
  echo "CONTINUUM_PERF_CONFIGURATION must be debug or release (got: $CONFIGURATION)" >&2
  exit 2
fi

APP="${CONTINUUM_PERF_APP:-$ROOT_DIR/.build/$CONFIGURATION/Array}"
BASELINE="${CONTINUUM_QA_PERF_BASELINE:-$ROOT_DIR/qa/perf-baseline.json}"
RUN_ID="${CONTINUUM_PERF_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
OUT_ROOT="${CONTINUUM_PERF_OUT:-$ROOT_DIR/qa-runs/$RUN_ID/perf}"
IFS=' ' read -r -a FLOWS <<< "${CONTINUUM_PERF_FLOWS:-canvas-drag-resize terminal-stress-10 palette-leak-check}"

run() {
  printf '\n==> %s\n' "$*"
  "$@"
}

isolation_root=
active_app_pid=

cleanup_isolation() {
  if [[ -n "$isolation_root" && -d "$isolation_root" ]]; then
    rm -rf -- "$isolation_root"
  fi
  isolation_root=
}

handle_signal() {
  local signal=$1
  trap - "$signal"
  if [[ -n "$active_app_pid" ]]; then
    kill -s "$signal" "$active_app_pid" 2>/dev/null || true
    wait "$active_app_pid" 2>/dev/null || true
    active_app_pid=
  fi
  cleanup_isolation
  kill -s "$signal" "$$"
}

trap cleanup_isolation EXIT
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM

if [[ -n "${CONTINUUM_PERF_APP:-}" ]]; then
  if [[ ! -x "$APP" ]]; then
    echo "CONTINUUM_PERF_APP is not executable: $APP" >&2
    exit 1
  fi
  resolved_app=$(realpath "$APP")
  case "$resolved_app" in
    */.build/debug/*)
      app_configuration=debug
      ;;
    */.build/release/*)
      app_configuration=release
      ;;
    *)
      app_configuration=
      ;;
  esac
  if [[ -n "$app_configuration" && "$app_configuration" != "$CONFIGURATION" ]]; then
    echo "CONTINUUM_PERF_APP resolves to $resolved_app, which conflicts with requested $CONFIGURATION configuration" >&2
    exit 1
  fi
else
  run swift build -c "$CONFIGURATION"
fi

run swift run -c "$CONFIGURATION" ContinuumRevivedPerfChecks

mkdir -p "$OUT_ROOT"

for flow in "${FLOWS[@]}"; do
  flow_out="$OUT_ROOT/$flow"
  isolation_root=$(mktemp -d "${TMPDIR:-/tmp}/continuum-perf-isolation.XXXXXX")
  project_root="$isolation_root/project"
  app_support="$isolation_root/app-support"
  mkdir -p "$project_root" "$app_support"
  mkdir -p "$flow_out"

  printf '\n==> perf flow %s (artifacts: %s)\n' "$flow" "$flow_out"
  set +e
  CONTINUUM_SMOKE_TEST=1 \
    CONTINUUM_QA_FLOW="$flow" \
    CONTINUUM_QA_PERF="$flow_out" \
    CONTINUUM_QA_PERF_BASELINE="$BASELINE" \
    CONTINUUM_PROJECT_ROOT="$project_root" \
    CONTINUUM_APP_SUPPORT="$app_support" \
    "$APP" &
  active_app_pid=$!
  wait "$active_app_pid"
  app_status=$?
  active_app_pid=
  set -e
  cleanup_isolation
  if [[ $app_status -ne 0 ]]; then
    echo "perf flow $flow failed with exit status $app_status" >&2
    exit "$app_status"
  fi
  if [[ ! -f "$flow_out/perf-report.json" ]]; then
    echo "perf flow $flow did not write $flow_out/perf-report.json" >&2
    exit 1
  fi
done

node - "$OUT_ROOT" <<'NODE'
const fs = require('fs');
const path = require('path');
const root = process.argv[2];
const required = new Set(['launch-time', 'drag-latency-p95', 'memory-at-10-tiles', 'palette-leak-delta']);
let failed = false;
for (const flow of fs.readdirSync(root).sort()) {
  const reportPath = path.join(root, flow, 'perf-report.json');
  if (!fs.existsSync(reportPath)) continue;
  const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
  for (const metric of report.metrics || []) {
    required.delete(metric.key);
    console.log(`${flow}: ${metric.key}=${metric.value} ${metric.unit}`);
  }
  for (const finding of report.findings || []) {
    failed = true;
    console.error(`PERF FINDING: ${flow}: ${finding.metric} ${finding.value} > ${finding.limit} ${finding.unit}`);
  }
}
if (required.size) {
  failed = true;
  console.error(`Missing required perf metrics: ${Array.from(required).sort().join(', ')}`);
}
if (failed) process.exit(1);
NODE

printf '\nPerf ceilings passed. Artifacts: %s\n' "$OUT_ROOT"

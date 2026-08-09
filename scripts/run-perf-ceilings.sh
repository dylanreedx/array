#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

APP="${CONTINUUM_PERF_APP:-.build/debug/Array}"
BASELINE="${CONTINUUM_QA_PERF_BASELINE:-$ROOT_DIR/qa/perf-baseline.json}"
RUN_ID="${CONTINUUM_PERF_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
OUT_ROOT="${CONTINUUM_PERF_OUT:-$ROOT_DIR/qa-runs/$RUN_ID/perf}"
IFS=' ' read -r -a FLOWS <<< "${CONTINUUM_PERF_FLOWS:-canvas-drag-resize terminal-stress-10 palette-leak-check}"

run() {
  printf '\n==> %s\n' "$*"
  "$@"
}

run swift run ContinuumRevivedPerfChecks

if [[ -n "${CONTINUUM_PERF_APP:-}" ]]; then
  if [[ ! -x "$APP" ]]; then
    echo "CONTINUUM_PERF_APP is not executable: $APP" >&2
    exit 1
  fi
else
  run swift build
fi

mkdir -p "$OUT_ROOT"

for flow in "${FLOWS[@]}"; do
  flow_out="$OUT_ROOT/$flow"
  project_root=$(mktemp -d "${TMPDIR:-/tmp}/continuum-perf-project.XXXXXX")
  app_support=$(mktemp -d "${TMPDIR:-/tmp}/continuum-perf-appsupport.XXXXXX")
  mkdir -p "$flow_out"

  printf '\n==> perf flow %s (artifacts: %s)\n' "$flow" "$flow_out"
  set +e
  CONTINUUM_SMOKE_TEST=1 \
    CONTINUUM_QA_FLOW="$flow" \
    CONTINUUM_QA_PERF="$flow_out" \
    CONTINUUM_QA_PERF_BASELINE="$BASELINE" \
    CONTINUUM_PROJECT_ROOT="$project_root" \
    CONTINUUM_APP_SUPPORT="$app_support" \
    "$APP"
  status=$?
  set -e
  rm -rf "$project_root" "$app_support"
  if [[ $status -ne 0 ]]; then
    echo "perf flow $flow failed with exit status $status" >&2
    exit "$status"
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

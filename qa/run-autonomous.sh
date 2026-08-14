#!/usr/bin/env bash
set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# CoreChecks contains real-tmux coverage. Never let an autonomous run inherit
# Array's live/default socket: give every invocation a disposable namespace and
# remove only that namespace when the run ends.
QA_TMUX_TMPDIR=$(mktemp -d /tmp/array-autonomous-tmux.XXXXXX)
export TMUX_TMPDIR="$QA_TMUX_TMPDIR"
unset TMUX TMUX_PANE
trap 'rm -rf "$QA_TMUX_TMPDIR"' EXIT

SCOPE="changed"
FLOW=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)
      if [[ $# -lt 2 || "${2:-}" == --* ]]; then
        echo "missing value for --scope" >&2
        exit 2
      fi
      SCOPE="$2"
      shift 2
      ;;
    --flow)
      if [[ $# -lt 2 || "${2:-}" == --* ]]; then
        echo "missing value for --flow" >&2
        exit 2
      fi
      FLOW="$2"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="qa-runs/$RUN_ID"
mkdir -p "$RUN_DIR/build" "$RUN_DIR/checks" "$RUN_DIR/smoke"

HEAD_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
GIT_STATUS="$(git status --short 2>/dev/null || true)"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

printf '%s\n' "$GIT_STATUS" > "$RUN_DIR/git-status.txt"
printf '%s\n' "$HEAD_SHA" > "$RUN_DIR/head.txt"

TOTAL=0
PASSED=0
FAILED=0
FAILED_NAMES=()

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

run_gate() {
  local name="$1"
  local dir="$2"
  shift 2
  mkdir -p "$RUN_DIR/$dir"
  TOTAL=$((TOTAL + 1))
  local start end duration exit_code
  start=$(date +%s)
  echo "==> $name"
  (
    echo "# $name"
    echo "# command: $*"
    echo "# started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    "$@"
  ) > "$RUN_DIR/$dir/stdout.log" 2> "$RUN_DIR/$dir/stderr.log"
  exit_code=$?
  end=$(date +%s)
  duration=$((end - start))
  cat > "$RUN_DIR/$dir/verdict.json" <<EOF
{
  "name": "$name",
  "status": "$([[ $exit_code -eq 0 ]] && echo passed || echo failed)",
  "exitCode": $exit_code,
  "durationSeconds": $duration,
  "stdout": "$dir/stdout.log",
  "stderr": "$dir/stderr.log"
}
EOF
  if [[ $exit_code -eq 0 ]]; then
    PASSED=$((PASSED + 1))
    echo "PASS $name"
  else
    FAILED=$((FAILED + 1))
    FAILED_NAMES+=("$name")
    echo "FAIL $name (exit $exit_code)"
  fi
}

run_gate "swift-build" "build/swift-build" swift build
run_gate "core-checks" "checks/core" swift run ContinuumRevivedCoreChecks
run_gate "palette-checks" "checks/palette" swift run ContinuumRevivedPaletteChecks
run_gate "file-tree-checks" "checks/file-tree" swift run ContinuumRevivedFileTreeChecks
run_gate "package-targets" "checks/package-targets" node scripts/check-package-targets.js
run_gate "qa-flow-definitions" "checks/qa-flow-definitions" node scripts/check-qa-flows.js
run_gate "diff-whitespace" "checks/diff-whitespace" git diff --check
if [[ -n "$FLOW" ]]; then
  if [[ ! "$FLOW" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "Invalid QA flow name (expected basename with letters, digits, _ or -): $FLOW" >&2
    exit 2
  fi
  FLOW_SCRIPT="qa/flows/${FLOW}.sh"
  if [[ ! -x "$FLOW_SCRIPT" ]]; then
    echo "Unknown or non-executable QA flow: $FLOW_SCRIPT" >&2
    exit 2
  fi
  run_gate "qa-flow-${FLOW}" "flows/${FLOW}" "$FLOW_SCRIPT"
else
  run_gate "smoke" "smoke/default" env CONTINUUM_SMOKE_TEST=1 .build/debug/continuum-revived
fi

COMPLETED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VERDICT="passed"
if [[ $FAILED -ne 0 ]]; then
  VERDICT="failed"
fi

FAILED_JSON="$(printf '%s\n' "${FAILED_NAMES[@]:-}" | python3 -c 'import json,sys; xs=[l for l in sys.stdin.read().splitlines() if l]; print(json.dumps(xs))')"
DIRTY_JSON="$(printf '%s' "$GIT_STATUS" | json_escape)"

cat > "$RUN_DIR/manifest.json" <<EOF
{
  "runId": "$RUN_ID",
  "head": "$HEAD_SHA",
  "dirtyStatus": $DIRTY_JSON,
  "scope": "$SCOPE",
  "flow": "$FLOW",
  "startedAt": "$STARTED_AT",
  "completedAt": "$COMPLETED_AT",
  "gatesPassed": $PASSED,
  "gatesTotal": $TOTAL,
  "failedGates": $FAILED_JSON,
  "verdict": "$VERDICT"
}
EOF

{
  echo "# QA Verdict: $VERDICT"
  echo
  echo "- Run: $RUN_DIR"
  echo "- Head: $HEAD_SHA"
  echo "- Scope: $SCOPE"
  if [[ -n "$FLOW" ]]; then echo "- Flow: $FLOW"; fi
  echo "- Gates: $PASSED/$TOTAL passed"
  echo
  if [[ $FAILED -ne 0 ]]; then
    echo "## Failed gates"
    for name in "${FAILED_NAMES[@]}"; do
      echo "- $name"
    done
    echo
  fi
  echo "## Dirty status at run start"
  if [[ -n "$GIT_STATUS" ]]; then
    printf '```text\n%s\n```\n' "$GIT_STATUS"
  else
    echo "Clean"
  fi
  echo
  echo "## Artifact contract"
  echo
  echo "Each gate directory contains stdout.log, stderr.log, and verdict.json."
} > "$RUN_DIR/verdict.md"

echo "QA $VERDICT: $PASSED/$TOTAL gates passed"
echo "Run: $RUN_DIR"

if [[ $FAILED -ne 0 ]]; then
  exit 1
fi
exit 0

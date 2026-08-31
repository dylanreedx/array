#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
RUNNER="$ROOT_DIR/scripts/run-perf-ceilings.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/array-perf-runner-contract.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file=$1
  local expected=$2
  grep -F -- "$expected" "$file" >/dev/null || fail "$file does not contain: $expected"
}

make_fixture() {
  local fixture=$1
  mkdir -p "$fixture/scripts" "$fixture/bin"
  cp "$RUNNER" "$fixture/scripts/run-perf-ceilings.sh"
  chmod +x "$fixture/scripts/run-perf-ceilings.sh"
  cat >"$fixture/bin/swift" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$SWIFT_LOG"
if [[ ${1:-} == build ]]; then
  configuration=debug
  while [[ $# -gt 0 ]]; do
    if [[ $1 == -c ]]; then configuration=$2; shift 2; else shift; fi
  done
  mkdir -p ".build/$configuration"
  cp "$FAKE_APP_TEMPLATE" ".build/$configuration/Array"
  chmod +x ".build/$configuration/Array"
fi
SH
  chmod +x "$fixture/bin/swift"
  cat >"$fixture/fake-app" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$0" >>"$APP_LOG"
mkdir -p "$CONTINUUM_QA_PERF"
cat >"$CONTINUUM_QA_PERF/perf-report.json" <<'JSON'
{"metrics":[
  {"key":"launch-time","value":1,"unit":"ms"},
  {"key":"drag-latency-p95","value":1,"unit":"ms"},
  {"key":"memory-at-10-tiles","value":1,"unit":"bytes"},
  {"key":"palette-leak-delta","value":0,"unit":"bytes"}
],"findings":[]}
JSON
if [[ ${FAKE_APP_MODE:-} == interrupt ]]; then
  printf '%s\n%s\n' "$CONTINUUM_PROJECT_ROOT" "$CONTINUUM_APP_SUPPORT" >"$ISOLATION_LOG"
  : >"$APP_READY"
  sleep 2
elif [[ ${FAKE_APP_MODE:-} == fail ]]; then
  printf '%s\n%s\n' "$CONTINUUM_PROJECT_ROOT" "$CONTINUUM_APP_SUPPORT" >"$ISOLATION_LOG"
  exit 42
fi
SH
  chmod +x "$fixture/fake-app"
}

run_fixture() {
  local fixture=$1
  shift
  (
    cd "$fixture"
    PATH="$fixture/bin:$PATH" \
      SWIFT_LOG="$fixture/swift.log" \
      APP_LOG="$fixture/app.log" \
      FAKE_APP_TEMPLATE="$fixture/fake-app" \
      CONTINUUM_PERF_FLOWS="contract" \
      CONTINUUM_PERF_OUT="$fixture/out" \
      "$@" "$fixture/scripts/run-perf-ceilings.sh"
  )
}

debug_fixture="$TEST_ROOT/default-debug"
make_fixture "$debug_fixture"
run_fixture "$debug_fixture" env
assert_contains "$debug_fixture/swift.log" "run -c debug ContinuumRevivedPerfChecks"
assert_contains "$debug_fixture/swift.log" "build -c debug"
assert_contains "$debug_fixture/app.log" "/.build/debug/Array"

release_fixture="$TEST_ROOT/explicit-release"
make_fixture "$release_fixture"
run_fixture "$release_fixture" env CONTINUUM_PERF_CONFIGURATION=release
assert_contains "$release_fixture/swift.log" "run -c release ContinuumRevivedPerfChecks"
assert_contains "$release_fixture/swift.log" "build -c release"
assert_contains "$release_fixture/app.log" "/.build/release/Array"

invalid_fixture="$TEST_ROOT/invalid"
make_fixture "$invalid_fixture"
if run_fixture "$invalid_fixture" env CONTINUUM_PERF_CONFIGURATION=profile >"$invalid_fixture/result.log" 2>&1; then
  fail "invalid configuration was accepted"
fi
assert_contains "$invalid_fixture/result.log" "CONTINUUM_PERF_CONFIGURATION must be debug or release"

conflict_fixture="$TEST_ROOT/conflict"
make_fixture "$conflict_fixture"
mkdir -p "$conflict_fixture/.build/debug"
cp "$conflict_fixture/fake-app" "$conflict_fixture/.build/debug/Array"
if run_fixture "$conflict_fixture" env CONTINUUM_PERF_CONFIGURATION=release CONTINUUM_PERF_APP="$conflict_fixture/.build/debug/Array" >"$conflict_fixture/result.log" 2>&1; then
  fail "release configuration accepted a debug app"
fi
assert_contains "$conflict_fixture/result.log" "conflicts with requested release configuration"

symlink_fixture="$TEST_ROOT/symlink-conflict"
make_fixture "$symlink_fixture"
mkdir -p "$symlink_fixture/.build/debug" "$symlink_fixture/aliases"
cp "$symlink_fixture/fake-app" "$symlink_fixture/.build/debug/Array"
ln -s "$symlink_fixture/.build/debug/Array" "$symlink_fixture/aliases/Array"
if run_fixture "$symlink_fixture" env CONTINUUM_PERF_CONFIGURATION=release CONTINUUM_PERF_APP="$symlink_fixture/aliases/Array" >"$symlink_fixture/result.log" 2>&1; then
  fail "release configuration accepted a symlink to a debug app"
fi
assert_contains "$symlink_fixture/result.log" "conflicts with requested release configuration"

interrupt_fixture="$TEST_ROOT/interrupt-cleanup"
make_fixture "$interrupt_fixture"
mkdir -p "$interrupt_fixture/tmp"
: >"$interrupt_fixture/outside-owned-roots"
(
  cd "$interrupt_fixture"
  exec env \
    PATH="$interrupt_fixture/bin:$PATH" \
    SWIFT_LOG="$interrupt_fixture/swift.log" \
    APP_LOG="$interrupt_fixture/app.log" \
    FAKE_APP_TEMPLATE="$interrupt_fixture/fake-app" \
    CONTINUUM_PERF_FLOWS=contract \
    CONTINUUM_PERF_OUT="$interrupt_fixture/out" \
    TMPDIR="$interrupt_fixture/tmp" \
    FAKE_APP_MODE=interrupt \
    ISOLATION_LOG="$interrupt_fixture/isolation.log" \
    APP_READY="$interrupt_fixture/app-ready" \
    "$interrupt_fixture/scripts/run-perf-ceilings.sh"
) >"$interrupt_fixture/result.log" 2>&1 &
runner_pid=$!
for _ in {1..100}; do
  [[ -f "$interrupt_fixture/app-ready" ]] && break
  kill -0 "$runner_pid" 2>/dev/null || fail "runner exited before interruption readiness"
  sleep 0.02
done
[[ -f "$interrupt_fixture/app-ready" ]] || fail "fake app did not reach interruption readiness"
kill -TERM "$runner_pid"
set +e
wait "$runner_pid"
interrupt_status=$?
set -e
[[ $interrupt_status -eq 143 ]] || fail "SIGTERM exit was $interrupt_status instead of 143"
while IFS= read -r owned_root; do
  [[ "$owned_root" == "$interrupt_fixture/tmp/"* ]] || fail "isolation escaped test TMPDIR: $owned_root"
  [[ ! -e "$owned_root" ]] || fail "interrupted runner leaked isolation root: $owned_root"
done <"$interrupt_fixture/isolation.log"
[[ -f "$interrupt_fixture/outside-owned-roots" ]] || fail "cleanup deleted a path outside owned isolation roots"

failure_fixture="$TEST_ROOT/failure-cleanup"
make_fixture "$failure_fixture"
mkdir -p "$failure_fixture/tmp"
: >"$failure_fixture/outside-owned-roots"
set +e
run_fixture "$failure_fixture" env \
  TMPDIR="$failure_fixture/tmp" \
  FAKE_APP_MODE=fail \
  ISOLATION_LOG="$failure_fixture/isolation.log" \
  >"$failure_fixture/result.log" 2>&1
failure_status=$?
set -e
[[ $failure_status -eq 42 ]] || fail "app failure exit was $failure_status instead of 42"
while IFS= read -r owned_root; do
  [[ "$owned_root" == "$failure_fixture/tmp/"* ]] || fail "failure isolation escaped test TMPDIR: $owned_root"
  [[ ! -e "$owned_root" ]] || fail "failed runner leaked isolation root: $owned_root"
done <"$failure_fixture/isolation.log"
[[ -f "$failure_fixture/outside-owned-roots" ]] || fail "failure cleanup deleted a path outside owned isolation roots"

echo "Performance runner configuration contract passed."

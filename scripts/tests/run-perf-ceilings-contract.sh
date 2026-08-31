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

echo "Performance runner configuration contract passed."

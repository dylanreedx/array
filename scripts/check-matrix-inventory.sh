#!/usr/bin/env bash
set -euo pipefail

# Ticket P0.11: the matrix may never lose a check.
#
# "Never weaken the matrix" is the program's central rule, but nothing enforced
# it — an unattended worker under pressure could delete or comment out a check
# to get green. This leg makes the inventory of checks a committed artifact:
# every `--*-check` flag and every leg in run-matrix.sh, plus the number of
# `run*Checks()` calls in each `*Checks` main. A disappearance or a decreased
# count is red and names what went missing. Growth is fine and prints.
#
# Blessing a removal (or a rename, which reads as a deletion + an addition) is
# an explicit committed diff:
#   CONTINUUM_UPDATE_MATRIX_INVENTORY=1 ./scripts/run-matrix.sh
#
# This script is itself a normal matrix leg, so deleting it also removes a
# `leg` record from the inventory and trips the guard.

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

MATRIX_FILE=scripts/run-matrix.sh
BUNDLE_FILE=scripts/check-app-bundle.sh
INVENTORY_FILE=docs/38-tickets/90-agent-ux/matrix-inventory.txt

for required in "$MATRIX_FILE" "$BUNDLE_FILE"; do
  if [[ ! -f "$required" ]]; then
    printf 'FAIL: missing %s — a matrix source file is gone.\n' "$required" >&2
    exit 1
  fi
done

# Every check flag the matrix names, deduped: the same flag can appear both in
# an `if` branch and in the loud SKIPPED message that documents the skip.
#
# Every grep that feeds a pipe is `|| true`: `pipefail` is on, and a grep that
# legitimately matches nothing (a target with no run*Checks() calls) must not
# abort the script — "found nothing" is a comparison result, reported below,
# not a script error.
#
# Comments are stripped before extracting flags: commenting a leg out already
# drops its `leg` record, and a flag left alive by the prose above it would make
# the two records disagree about the same removal.
matrix_source() {
  { grep -vE '^[[:space:]]*#' "$MATRIX_FILE" || true; } | sed -E 's/[[:space:]]#.*//'
}

collect_flags() {
  { matrix_source | grep -ohE -- '--[a-z0-9][a-z0-9-]*-check\b' || true; } |
    sort -u |
    sed 's/^/check /'
}

# Every invoked leg, with any leading environment assignments stripped so that
# e.g. `CLOUDKIT_ENABLED=0 run swift run ...` stays one stable record even if
# the env prefix changes.
collect_legs() {
  { matrix_source | grep -ohE '^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(run|run_app_check|run_ios_build)([[:space:]].*)?$' || true; } |
    sed -E 's/^[[:space:]]+//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)+//' |
    sort -u |
    sed 's/^/leg /'
}

# How many check suites each `*Checks` executable actually runs. Counts call
# sites in the target's main, so deleting a `runFooChecks()` line from a main
# lowers the count and turns this leg red even though no matrix leg vanished.
#
# `//` comments are stripped first: the threat model is "delete OR comment out a
# check to get green", and a raw token grep would happily keep counting
# `// try await runOpLogChecks()`. `func run...Checks` declarations are excluded
# too, so moving a suite's body into a main can't inflate the floor.
collect_counts() {
  local main target count
  for main in Sources/*Checks/main.swift; do
    [[ -f "$main" ]] || continue
    target=$(basename "$(dirname "$main")")
    count=$(sed -E 's|//.*||' "$main" |
      { grep -vE '^[[:space:]]*(public[[:space:]]+)?func[[:space:]]' || true; } |
      { grep -ohE 'run[A-Za-z0-9_]*Checks\(\)' || true; } |
      wc -l | tr -d ' ')
    printf 'count %s %s\n' "$target" "$count"
  done | sort
}

# Beyond the packet's letter, inside its goal: `run scripts/check-app-bundle.sh`
# is one matrix leg that fans out to its own `self_checks` array, and two of
# those (--menu-contract-check, --delete-confirm-policy-defaults-check) run
# nowhere else. Without this they could be deleted while every run-matrix.sh
# record stayed intact. Scoped tightly to that one array, so a reshaped array
# reads as a disappearance — which is the safe direction to fail. `#` comments
# are stripped first for the same reason as the Swift counts: a flag left behind
# in a trailing comment must not keep its record alive.
collect_bundle_checks() {
  { grep -ohE -- 'self_checks=\(.*\)' "$BUNDLE_FILE" || true; } |
    sed -E 's|#.*||' |
    { grep -ohE -- '--[a-z0-9][a-z0-9-]*-check\b' || true; } |
    sort -u |
    sed 's/^/bundle-check /'
}

generate() {
  collect_flags
  collect_legs
  collect_bundle_checks
  collect_counts
}

current=$(mktemp "${TMPDIR:-/tmp}/continuum-matrix-inventory.XXXXXX")
trap 'rm -f "$current"' EXIT
generate > "$current"

if [[ "${CONTINUUM_UPDATE_MATRIX_INVENTORY:-0}" == "1" ]]; then
  cp "$current" "$INVENTORY_FILE"
  printf 'Matrix inventory regenerated: %s (%s records). Commit it with the change that grew or renamed a check.\n' \
    "$INVENTORY_FILE" "$(wc -l < "$INVENTORY_FILE" | tr -d ' ')"
  exit 0
fi

if [[ ! -f "$INVENTORY_FILE" ]]; then
  printf 'FAIL: missing %s — regenerate with CONTINUUM_UPDATE_MATRIX_INVENTORY=1 ./scripts/run-matrix.sh\n' \
    "$INVENTORY_FILE" >&2
  exit 1
fi

failures=0
grew=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# Committed record -> must still hold. `check`/`leg` are presence records;
# `count` is a floor.
while IFS= read -r record; do
  [[ -n "$record" ]] || continue
  case "$record" in
    count\ *)
      read -r _ target expected <<<"$record"
      actual=$({ grep -E "^count $target " "$current" || true; } | awk '{print $3}')
      if [[ -z "$actual" ]]; then
        fail "check suite target disappeared from the matrix inventory: $target (expected at least $expected run*Checks() call(s))"
      elif (( actual < expected )); then
        fail "$target now runs $actual run*Checks() call(s), down from $expected — a check suite was removed"
      fi
      ;;
    *)
      if ! grep -Fqx -- "$record" "$current"; then
        fail "matrix lost a committed entry: $record"
      fi
      ;;
  esac
done < "$INVENTORY_FILE"

if (( failures > 0 )); then
  printf 'The matrix inventory shrank. Restore the missing check(s). If the removal is intentional (e.g. a rename), bless it in the same commit with: CONTINUUM_UPDATE_MATRIX_INVENTORY=1 ./scripts/run-matrix.sh\n' >&2
  exit 1
fi

while IFS= read -r record; do
  [[ -n "$record" ]] || continue
  case "$record" in
    count\ *) continue ;;
  esac
  if ! grep -Fqx -- "$record" "$INVENTORY_FILE"; then
    printf 'inventory grew: %s\n' "$record"
    grew=$((grew + 1))
  fi
done < "$current"

while IFS= read -r record; do
  read -r _ target actual <<<"$record"
  expected=$({ grep -E "^count $target " "$INVENTORY_FILE" || true; } | awk '{print $3}')
  if [[ -z "$expected" ]]; then
    printf 'inventory grew: count %s %s (new check suite target)\n' "$target" "$actual"
    grew=$((grew + 1))
  elif (( actual > expected )); then
    printf 'inventory grew: count %s %s -> %s\n' "$target" "$expected" "$actual"
    grew=$((grew + 1))
  fi
done < <(grep '^count ' "$current" || true)

if (( grew > 0 )); then
  printf 'inventory grew by %d record(s) — regenerate and commit: CONTINUUM_UPDATE_MATRIX_INVENTORY=1 ./scripts/run-matrix.sh\n' "$grew"
fi

printf 'Matrix inventory checks passed (%s committed records).\n' "$(wc -l < "$INVENTORY_FILE" | tr -d ' ')"

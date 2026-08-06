#!/usr/bin/env bash
# Structural guard for docs/38-tickets/91-agent-tile-ux authoring.
#
# Ticket P0.1: this leg is the program's own contract. File presence was never
# enough — a packet can exist and still disagree with the row that schedules it.
# So the queue is validated against each packet's own header (id, phase,
# dependency line, execution mode), the ledger against a fixed state vocabulary
# with one unique row per packet and no forged bookkeeping on work that has not
# run, and the matrix wiring that keeps this leg running at all.
#
# Running it with no arguments first runs the self-test: the live program is
# copied into a temporary root, mutated there, and this same script must go red
# with a named error for every failure mode it claims to catch. The live
# queue/ledger/packets are never written. `--check` runs only the structural
# check and is what the self-test's child invocations use.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DIR="docs/38-tickets/91-agent-tile-ux"
QUEUE="$DIR/_QUEUE.md"
LEDGER="$DIR/_LEDGER.md"
MATRIX="scripts/run-matrix.sh"
INVENTORY="docs/38-tickets/90-agent-ux/matrix-inventory.txt"
failures=0
fail() { echo "agent-tile-program check failed: $*" >&2; failures=$((failures + 1)); }

trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
valid_utc_timestamp() {
  local parsed
  parsed="$(LC_ALL=C date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" || return 1
  [ "$parsed" = "$1" ]
}

check_program() {
  for f in "$DIR/_DESIGN.md" "$DIR/_RUNBOOK.md" "$QUEUE" "$LEDGER" scripts/agent-tile-ux-prompt.md scripts/agent-tile-ux-loop.sh scripts/agent-tile-ux-loopctl.sh scripts/check-retina-main.swift; do
    [ -f "$f" ] || fail "missing $f"
  done

  grep -Fq '**The canvas is the session switcher.**' "$DIR/_DESIGN.md" || fail "design lost canvas/session ownership"
  grep -Fq '**Provider current work is passive and read-only.**' "$DIR/_DESIGN.md" || fail "design lost passive current-work rule"
  grep -Fq '**Autonomy is the default.**' "$DIR/_DESIGN.md" || fail "design regained a Continuum approval gate"
  grep -Fq '**No context tile.**' "$DIR/_DESIGN.md" || fail "design regained a context tile"
  grep -Fq '`P5.3-provider-current-work-projection.md`' "$QUEUE" || fail "queue lost provider current-work projection"
  grep -Fq 'PI_WORKER_MODEL="${PI_WORKER_MODEL:-openai-codex/gpt-5.6-luna}"' scripts/agent-tile-ux-loop.sh || fail "loop lost Luna implementation role"
  grep -Fq 'PI_WORKER_THINKING="${PI_WORKER_THINKING:-high}"' scripts/agent-tile-ux-loop.sh || fail "loop lost Luna high thinking"
  grep -Fq 'PI_MONITOR_MODEL="${PI_MONITOR_MODEL:-openai-codex/gpt-5.6-sol}"' scripts/agent-tile-ux-loop.sh || fail "loop lost Sol monitor role"
  grep -Fq 'PI_MONITOR_THINKING="${PI_MONITOR_THINKING:-xhigh}"' scripts/agent-tile-ux-loop.sh || fail "loop lost Sol xhigh thinking"
  grep -Fq 'a REWORK verdict is the reconciliation packet' scripts/agent-tile-ux-loop.sh || fail "loop lost bounded monitor reconciliation"
  grep -Fq 'MAX_REPAIR_PASSES="${MAX_REPAIR_PASSES:-2}"' scripts/agent-tile-ux-loop.sh || fail "loop lost bounded repair budget"
  grep -Fq 'reviewer-session-' scripts/agent-tile-ux-loop.sh || fail "loop lost durable reviewer sessions"
  grep -Fq 'DECISION: APPROVE' scripts/agent-tile-ux-loop.sh || fail "loop lost independent approval gate"
  grep -Fq 'first_eligible_ticket' scripts/agent-tile-ux-loop.sh || fail "loop lost first-eligible enforcement"
  grep -Fq 'run_final_checks' scripts/agent-tile-ux-loop.sh || fail "loop lost harness-owned final checks"
  grep -Fq 'update_ledger_done' scripts/agent-tile-ux-loop.sh || fail "loop lost targeted harness-owned ledger update"
  grep -Fq 'swift scripts/check-retina-main.swift' scripts/agent-tile-ux-loop.sh || fail "loop lost mandatory durable display preflight"
  grep -Fq 'The shell harness—not you—owns queue selection, ledger state' scripts/agent-tile-ux-prompt.md || fail "worker regained queue or ledger ownership"
  grep -Fq 'Never run `git add`, `git commit`' scripts/agent-tile-ux-prompt.md || fail "worker prompt lost git prohibition"

  rows="$(grep -E '^\| [0-9]+ \| `P[0-9]+\.[0-9]+-[^`]+\.md` \|' "$QUEUE" 2>/dev/null || true)"
  count="$(printf '%s\n' "$rows" | grep -c '^|' | tr -d ' ')"
  [ "$count" = 50 ] || fail "expected 50 queue rows, found $count"

  seen_ids=""
  seen_files=""
  expected_index=1
  supervised=""

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    index="$(printf '%s' "$row" | awk -F'|' '{gsub(/ /,"",$2); print $2}')"
    file="$(printf '%s' "$row" | awk -F'|' '{gsub(/^[ \t]*`|`[ \t]*$/,"",$3); print $3}')"
    deps="$(printf '%s' "$row" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$4); print $4}')"
    execution="$(printf '%s' "$row" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$5); print $5}')"
    id="${file%%-*}"
    phase="${id#P}"
    phase="${phase%%.*}"

    [ "$index" = "$expected_index" ] || fail "row index $index, expected $expected_index"
    expected_index=$((expected_index + 1))
    [ -f "$DIR/$file" ] || fail "queue packet missing: $file"
    printf '%b' "$seen_ids" | grep -qx "$id" && fail "duplicate ticket id: $id"
    printf '%b' "$seen_files" | grep -qx "$file" && fail "duplicate ticket file: $file"

    # Dependencies must already have been seen, so a forward reference and a
    # cycle are the same failure and neither can hide behind row order.
    if [ "$deps" = "—" ]; then
      :
    elif [ -z "$deps" ]; then
      fail "$id dependency cell is empty; use — for no dependencies"
    else
      printf '%s\n' "$deps" | grep -Eq '^P[0-9]+\.[0-9]+(, P[0-9]+\.[0-9]+)*$' ||
        fail "$id dependency cell has invalid grammar: [$deps]"
      old_ifs="$IFS"; IFS=','; dep_seen=""
      for dep in $deps; do
        dep="$(trim "$dep")"
        printf '%b' "$dep_seen" | grep -Fqx "$dep" && fail "$id repeats dependency: $dep"
        dep_seen="${dep_seen}${dep}\n"
        printf '%b' "$seen_ids" | grep -Fqx "$dep" || fail "$id dependency is missing or not earlier: $dep"
      done
      IFS="$old_ifs"
    fi

    case "$execution" in
      autonomous) ;;
      supervised) supervised="${supervised}${id}\n" ;;
      *) fail "$id has invalid execution mode: $execution" ;;
    esac

    if [ -f "$DIR/$file" ]; then
      for heading in '## Goal' '## Files' '## Approach' '## Done when' '## Verify' '## Watch out'; do
        grep -Fxq "$heading" "$DIR/$file" || fail "$file missing $heading"
      done

      # The packet header is the packet's own claim about how it is scheduled.
      # Every field of it has to agree with the row that schedules it, or queue
      # and packet drift apart with nothing to notice.
      title="$(head -n 1 "$DIR/$file")"
      case "$title" in
        "# $id — "*) ;;
        *) fail "$file title does not start with '# $id — ': $title" ;;
      esac

      # Metadata is a fixed five-line packet header, not a phrase that may
      # happen to appear later in prose or an implementation sketch.
      packet_phase="$(sed -n '3p' "$DIR/$file")"
      case "$packet_phase" in
        "Phase: $phase · "*) ;;
        *) fail "$file phase header disagrees with id $id: [$packet_phase]" ;;
      esac

      packet_execution="$(sed -n '4p' "$DIR/$file")"
      [ "$packet_execution" = "Execution: **$execution**" ] ||
        fail "$file execution header [$packet_execution] disagrees with queue [$execution]"

      packet_deps="$(sed -n '5p' "$DIR/$file")"
      [ "$packet_deps" = "Depends on: $deps" ] ||
        fail "$file dependency header [$packet_deps] disagrees with queue [Depends on: $deps]"
      grep -Fq "| \`$file\` |" "$LEDGER" || fail "$file missing ledger row"
    fi

    seen_ids="${seen_ids}${id}\n"
    seen_files="${seen_files}${file}\n"
  done <<EOF
$rows
EOF

  actual_supervised="$(printf '%b' "$supervised" | sed '/^$/d')"
  expected_supervised="$(printf 'P3.12\nP4.10\nP5.5\n')"
  [ "$actual_supervised" = "$expected_supervised" ] || fail "supervised gates changed: [$actual_supervised]"

  packet_count="$(find "$DIR" -maxdepth 1 -type f -name 'P*.md' ! -name 'PAUSED-*.md' | wc -l | tr -d ' ')"
  [ "$packet_count" = 50 ] || fail "expected 50 packet files, found $packet_count"

  # Ledger: one row per packet, a state from the runbook's vocabulary, and no
  # bookkeeping that claims work which has not happened.
  ledger_rows="$(grep -E '^\| `P[0-9]+\.[0-9]+-[^`]+\.md` \|' "$LEDGER" || true)"
  ledger_count="$(printf '%s\n' "$ledger_rows" | grep -c '^|' | tr -d ' ')"
  [ "$ledger_count" = 50 ] || fail "expected 50 ledger rows, found $ledger_count"

  seen_ledger=""
  in_progress_count=0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    lfile="$(printf '%s' "$row" | awk -F'|' '{gsub(/^[ \t]*`|`[ \t]*$/,"",$2); print $2}')"
    lstate="$(trim "$(printf '%s' "$row" | awk -F'|' '{print $3}')")"
    lcommit="$(trim "$(printf '%s' "$row" | awk -F'|' '{print $4}')")"
    lupdated="$(trim "$(printf '%s' "$row" | awk -F'|' '{print $5}')")"

    printf '%b' "$seen_ledger" | grep -qx "$lfile" && fail "duplicate ledger row: $lfile"
    seen_ledger="${seen_ledger}${lfile}\n"
    [ -f "$DIR/$lfile" ] || fail "ledger row has no packet: $lfile"

    case "$lstate" in
      pending)
        [ "$lcommit" = "—" ] || fail "$lfile is pending but records commit [$lcommit]"
        [ "$lupdated" = "—" ] || fail "$lfile is pending but records date [$lupdated]"
        ;;
      in-progress)
        in_progress_count=$((in_progress_count + 1))
        [ "$lcommit" = "—" ] || fail "$lfile is in-progress but records commit [$lcommit]"
        valid_utc_timestamp "$lupdated" || fail "$lfile is in-progress without a real ISO UTC update: [$lupdated]"
        ;;
      blocked)
        [ "$lcommit" = "—" ] || fail "$lfile is blocked but records commit [$lcommit]"
        valid_utc_timestamp "$lupdated" || fail "$lfile is blocked without a real ISO UTC update: [$lupdated]"
        ;;
      done)
        [ "$lcommit" = "this commit" ] || fail "$lfile is done without the required 'this commit' marker: [$lcommit]"
        valid_utc_timestamp "$lupdated" || fail "$lfile is done without a real ISO UTC update: [$lupdated]"
        ;;
      *) fail "$lfile has invalid ledger state: $lstate" ;;
    esac
  done <<EOF
$ledger_rows
EOF
  [ "$in_progress_count" -le 1 ] || fail "ledger has $in_progress_count in-progress rows; at most one is valid"

  # This leg may not quietly remove itself: it has to stay wired into the matrix
  # and stay recorded in the committed matrix inventory.
  if [ -f "$MATRIX" ]; then
    bash -n "$MATRIX" || fail "matrix shell syntax is invalid"
    # This direct relative invocation is locked into the four-line executable
    # prefix, before a function, conditional, group, PATH lookup, or matrix
    # helper can disable or swallow it. The later `run` invocation remains for
    # normal leg reporting and the legacy matrix inventory.
    matrix_prefix="$(sed -n '1,4p' "$MATRIX")"
    expected_matrix_prefix="$(printf '%s\n' \
      '#!/usr/bin/env bash' \
      'set -euo pipefail' \
      '' \
      '"$(dirname "$0")/check-agent-tile-ux-program.sh" --check')"
    [ "$matrix_prefix" = "$expected_matrix_prefix" ] ||
      fail "matrix must invoke the agent-tile program check in its locked executable prefix"
    matrix_leg_count="$(grep -Fxc 'run scripts/check-agent-tile-ux-program.sh' "$MATRIX" || true)"
    [ "$matrix_leg_count" = 1 ] ||
      fail "matrix must retain exactly one reported agent-tile program leg, found $matrix_leg_count"
  else
    fail "missing $MATRIX"
  fi
  if [ -f "$INVENTORY" ]; then
    grep -Fqx 'leg run scripts/check-agent-tile-ux-program.sh' "$INVENTORY" ||
      fail "matrix inventory lost the agent-tile program leg"
  else
    fail "missing $INVENTORY"
  fi
}

# --- self-test ---------------------------------------------------------------
#
# Each case mutates a throwaway copy of the program and requires this script to
# go red there with a named error. A case that passes, or that fails for a
# different reason than the one it names, is itself a failure — that is what
# makes these negative witnesses rather than decoration.

mutate_missing_packet() { rm "$DIR/P2.5-fenced-code-blocks.md"; }
mutate_missing_ledger_row() { sed -i '' '/`P1.4-document-reducer.md` |/d' "$LEDGER"; }
mutate_duplicate_ledger_row() {
  grep -F '| `P1.4-document-reducer.md` |' "$LEDGER" >> "$LEDGER"
  sed -i '' '/`P1.5-runtime-event-projection.md` |/d' "$LEDGER"
}
mutate_empty_dependency() {
  sed -i '' 's/`P0.2-agent-content-target.md` | P0.1 |/`P0.2-agent-content-target.md` |  |/' "$QUEUE"
  sed -i '' 's/^Depends on: P0.1$/Depends on: /' "$DIR/P0.2-agent-content-target.md"
}
mutate_forward_dependency() {
  sed -i '' 's/`P1.1-document-schema.md` | P0.5 |/`P1.1-document-schema.md` | P2.1 |/' "$QUEUE"
  sed -i '' 's/^Depends on: P0.5$/Depends on: P2.1/' "$DIR/P1.1-document-schema.md"
}
mutate_trailing_empty_dependency() {
  sed -i '' 's/`P0.2-agent-content-target.md` | P0.1 |/`P0.2-agent-content-target.md` | P0.1, |/' "$QUEUE"
  sed -i '' 's/^Depends on: P0.1$/Depends on: P0.1,/' "$DIR/P0.2-agent-content-target.md"
}
mutate_duplicate_dependency() {
  sed -i '' 's/`P0.2-agent-content-target.md` | P0.1 |/`P0.2-agent-content-target.md` | P0.1, P0.1 |/' "$QUEUE"
  sed -i '' 's/^Depends on: P0.1$/Depends on: P0.1, P0.1/' "$DIR/P0.2-agent-content-target.md"
}
mutate_regex_dependency() {
  sed -i '' 's/`P0.2-agent-content-target.md` | P0.1 |/`P0.2-agent-content-target.md` | P0[.]1 |/' "$QUEUE"
  sed -i '' 's/^Depends on: P0.1$/Depends on: P0[.]1/' "$DIR/P0.2-agent-content-target.md"
}
mutate_cyclic_dependency() {
  sed -i '' 's/`P0.2-agent-content-target.md` | P0.1 |/`P0.2-agent-content-target.md` | P0.3 |/' "$QUEUE"
  sed -i '' 's/`P0.3-semantic-tile-tokens.md` | P0.1 |/`P0.3-semantic-tile-tokens.md` | P0.2 |/' "$QUEUE"
  sed -i '' 's/^Depends on: P0.1$/Depends on: P0.3/' "$DIR/P0.2-agent-content-target.md"
  sed -i '' 's/^Depends on: P0.1$/Depends on: P0.2/' "$DIR/P0.3-semantic-tile-tokens.md"
}
mutate_downgraded_supervised_gate() {
  sed -i '' 's/`P3.12-transcript-supervised-review.md` | P3.11 | supervised |/`P3.12-transcript-supervised-review.md` | P3.11 | autonomous |/' "$QUEUE"
  sed -i '' 's/^Execution: \*\*supervised\*\*$/Execution: **autonomous**/' "$DIR/P3.12-transcript-supervised-review.md"
}
mutate_misleading_execution_text() {
  sed -i '' 's/^Execution: \*\*supervised\*\*$/Execution: **autonomous**/' "$DIR/P3.12-transcript-supervised-review.md"
  printf '\nExecution: **supervised**\n' >> "$DIR/P3.12-transcript-supervised-review.md"
}
mutate_missing_heading() { sed -i '' 's/^## Verify$/## Checks/' "$DIR/P2.2-inline-markup-runs.md"; }
mutate_packet_dependency_drift() { sed -i '' 's/^Depends on: P0.1$/Depends on: P0.4/' "$DIR/P0.2-agent-content-target.md"; }
mutate_packet_dependency_label_removed() { sed -i '' 's/^Depends on: P0.1$/P0.1/' "$DIR/P0.2-agent-content-target.md"; }
mutate_packet_phase_drift() { sed -i '' 's/^Phase: 1 · /Phase: 3 · /' "$DIR/P1.2-stable-node-identity.md"; }
mutate_packet_title_drift() { sed -i '' '1s/^# P1.3 /# P1.7 /' "$DIR/P1.3-mutation-patch-vocabulary.md"; }
mutate_ledger_fields() {
  local target="$1" state="$2" commit="$3" updated="$4" tmp
  tmp="${LEDGER}.tmp"
  awk -F'|' -v OFS='|' -v target="$target" -v state="$state" -v commit="$commit" -v updated="$updated" '
    {
      key = $2
      gsub(/^[[:space:]]*`|`[[:space:]]*$/, "", key)
      if (key == target) {
        $3 = " " state " "
        $4 = " " commit " "
        $5 = " " updated " "
        found = 1
      }
      print
    }
    END { if (!found) exit 1 }
  ' "$LEDGER" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$LEDGER"
}
mutate_invalid_ledger_state() {
  mutate_ledger_fields P0.4-transcript-fixture-corpus.md shipped — 2026-07-28T00:00:00Z
}
mutate_forged_pending_commit() {
  mutate_ledger_fields P0.5-compatibility-pipeline-harness.md pending deadbee —
}
mutate_forged_done_metadata() {
  mutate_ledger_fields P0.5-compatibility-pipeline-harness.md done garbage garbage
}
mutate_invalid_calendar_timestamp() {
  mutate_ledger_fields P0.5-compatibility-pipeline-harness.md blocked — 2026-99-99T99:99:99Z
}
mutate_multiple_in_progress_rows() {
  mutate_ledger_fields P1.4-document-reducer.md in-progress — 2026-07-29T10:00:00Z
  mutate_ledger_fields P1.5-runtime-event-projection.md in-progress — 2026-07-29T10:00:01Z
}
mutate_unwired_matrix_leg() {
  sed -i '' '4c\
# agent-tile program check removed
' "$MATRIX"
}
mutate_nonblocking_matrix_leg() {
  sed -i '' '4c\
"$(dirname "$0")/check-agent-tile-ux-program.sh" --check || true
' "$MATRIX"
}
mutate_disabled_matrix_block() {
  sed -i '' '4c\
if false; then\
"$(dirname "$0")/check-agent-tile-ux-program.sh" --check\
fi
' "$MATRIX"
}
mutate_disabled_matrix_group() {
  sed -i '' '4c\
false && {\
"$(dirname "$0")/check-agent-tile-ux-program.sh" --check\
}
' "$MATRIX"
}
mutate_inventory_record_removed() {
  sed -i '' '\|^leg run scripts/check-agent-tile-ux-program.sh$|d' "$INVENTORY"
}

self_test() {
  local tmp base out st cases_run=0 cases_failed=0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/agent-tile-program-selftest.XXXXXX")" || {
    echo "agent-tile-program self-test: cannot create temp dir" >&2
    return 1
  }
  trap 'rm -rf "$tmp"' EXIT

  base="$tmp/base"
  mkdir -p "$base/$DIR" "$base/scripts" "$base/$(dirname "$INVENTORY")"
  cp "$DIR"/*.md "$base/$DIR/"
  cp "$INVENTORY" "$base/$INVENTORY"
  cp "$MATRIX" "$base/$MATRIX"
  cp "$0" "$base/scripts/check-agent-tile-ux-program.sh"
  cp scripts/agent-tile-ux-prompt.md scripts/agent-tile-ux-loop.sh scripts/agent-tile-ux-loopctl.sh scripts/check-retina-main.swift "$base/scripts/"
  chmod +x "$base/scripts/check-agent-tile-ux-program.sh"

  run_case() {
    local name="$1" expect="$2" mutate="$3" work
    cases_run=$((cases_run + 1))
    work="$tmp/case-$cases_run"
    cp -R "$base" "$work"
    ( cd "$work" && "$mutate" )
    out="$("$work/scripts/check-agent-tile-ux-program.sh" --check 2>&1)"
    st=$?
    if [ "$st" -eq 0 ]; then
      echo "agent-tile-program self-test: case '$name' passed the check but must fail" >&2
      cases_failed=$((cases_failed + 1))
    elif ! printf '%s' "$out" | grep -Fq "$expect"; then
      echo "agent-tile-program self-test: case '$name' failed for the wrong reason" >&2
      printf '  wanted: %s\n  got: %s\n' "$expect" "$out" >&2
      cases_failed=$((cases_failed + 1))
    fi
    rm -rf "$work"
  }

  # The unmutated copy must be green, or none of the cases below prove anything.
  out="$("$base/scripts/check-agent-tile-ux-program.sh" --check 2>&1)"
  st=$?
  if [ "$st" -ne 0 ]; then
    echo "agent-tile-program self-test: the unmutated fixture is red" >&2
    printf '%s\n' "$out" >&2
    cases_failed=$((cases_failed + 1))
  fi

  run_case 'missing packet file' \
    'queue packet missing: P2.5-fenced-code-blocks.md' mutate_missing_packet
  run_case 'missing ledger row' \
    'P1.4-document-reducer.md missing ledger row' mutate_missing_ledger_row
  run_case 'duplicate ledger row' \
    'duplicate ledger row: P1.4-document-reducer.md' mutate_duplicate_ledger_row
  run_case 'empty dependency cell' \
    'dependency cell is empty; use — for no dependencies' mutate_empty_dependency
  run_case 'forward dependency' \
    'P1.1 dependency is missing or not earlier: P2.1' mutate_forward_dependency
  run_case 'trailing empty dependency' \
    'dependency cell has invalid grammar: [P0.1,]' mutate_trailing_empty_dependency
  run_case 'duplicate dependency' \
    'repeats dependency: P0.1' mutate_duplicate_dependency
  run_case 'regex-shaped nonexistent dependency' \
    'dependency cell has invalid grammar: [P0[.]1]' mutate_regex_dependency
  run_case 'cyclic dependency' \
    'P0.2 dependency is missing or not earlier: P0.3' mutate_cyclic_dependency
  run_case 'downgraded supervised gate' \
    'supervised gates changed' mutate_downgraded_supervised_gate
  run_case 'misleading execution text outside header' \
    'execution header [Execution: **autonomous**] disagrees with queue [supervised]' mutate_misleading_execution_text
  run_case 'missing required heading' \
    'P2.2-inline-markup-runs.md missing ## Verify' mutate_missing_heading
  run_case 'packet dependency line drift' \
    'dependency header [Depends on: P0.4] disagrees with queue [Depends on: P0.1]' mutate_packet_dependency_drift
  run_case 'packet dependency label removed' \
    'dependency header [P0.1] disagrees with queue [Depends on: P0.1]' mutate_packet_dependency_label_removed
  run_case 'packet phase drift' \
    'phase header disagrees with id P1.2' mutate_packet_phase_drift
  run_case 'packet title id drift' \
    "title does not start with '# P1.3 — '" mutate_packet_title_drift
  run_case 'invalid ledger state' \
    'has invalid ledger state: shipped' mutate_invalid_ledger_state
  run_case 'forged commit on a pending row' \
    'is pending but records commit' mutate_forged_pending_commit
  run_case 'forged done metadata' \
    "is done without the required 'this commit' marker" mutate_forged_done_metadata
  run_case 'invalid calendar timestamp' \
    'is blocked without a real ISO UTC update' mutate_invalid_calendar_timestamp
  run_case 'multiple in-progress rows' \
    'ledger has 2 in-progress rows; at most one is valid' mutate_multiple_in_progress_rows
  run_case 'unwired matrix prefix' \
    'locked executable prefix' mutate_unwired_matrix_leg
  run_case 'nonblocking matrix prefix' \
    'locked executable prefix' mutate_nonblocking_matrix_leg
  run_case 'disabled matrix control block' \
    'locked executable prefix' mutate_disabled_matrix_block
  run_case 'disabled matrix boolean group' \
    'locked executable prefix' mutate_disabled_matrix_group
  run_case 'inventory record removed' \
    'matrix inventory lost the agent-tile program leg' mutate_inventory_record_removed

  rm -rf "$tmp"
  trap - EXIT

  if [ "$cases_failed" -gt 0 ]; then
    echo "agent-tile-program self-test: $cases_failed of $cases_run case(s) did not go red as required" >&2
    return 1
  fi
  echo "agent-tile-program self-test: ok ($cases_run negative cases red, live program untouched)"
  return 0
}

case "${1:---self-test}" in
  --check)
    check_program
    ;;
  --self-test)
    self_test || failures=$((failures + 1))
    check_program
    ;;
  *)
    echo "usage: $0 [--check|--self-test]" >&2
    exit 2
    ;;
esac

if [ "$failures" -gt 0 ]; then
  echo "agent-tile-program check: $failures failure(s)" >&2
  exit 1
fi

echo "agent-tile-program check: ok (50 packets, dependency order valid, 3 supervised gates)"

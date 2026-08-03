#!/usr/bin/env bash
# Structural guard for docs/38-tickets/94-sidebar-native-ux.
# P0.1 keeps the authoring contract executable and proves its negative paths
# against throwaway copies before any sidebar implementation packet runs.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DIR="docs/38-tickets/94-sidebar-native-ux"
QUEUE="$DIR/_QUEUE.md"
LEDGER="$DIR/_LEDGER.md"
MATRIX="scripts/run-matrix.sh"
INVENTORY="docs/38-tickets/90-agent-ux/matrix-inventory.txt"
EXPECTED_TICKETS=40
failures=0

fail() {
  echo "sidebar-native-ux program check failed: $*" >&2
  failures=$((failures + 1))
}

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

valid_utc_timestamp() {
  local parsed
  parsed="$(LC_ALL=C date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" || return 1
  [ "$parsed" = "$1" ]
}

check_program() {
  local required file rows count seen_ids seen_files seen_queue_files expected_index supervised
  local row index deps execution id phase packet_phase packet_execution packet_deps title
  local old_ifs dep dep_seen actual_supervised expected_supervised packet_count
  local ledger_rows ledger_count seen_ledger in_progress_count lfile lstate lcommit lupdated
  local queue_shadow_rows ledger_shadow_rows
  local matrix_prefix expected_matrix_prefix matrix_leg_count agent_leg_count sidebar_prefix
  local inventory_leg_count

  for required in \
    "$DIR/_DESIGN.md" "$DIR/_RUNBOOK.md" "$QUEUE" "$LEDGER" \
    scripts/sidebar-native-ux-prompt.md scripts/sidebar-native-ux-loop.sh \
    scripts/sidebar-native-ux-loopctl.sh scripts/check-retina-main.swift \
    scripts/check-agent-tile-ux-program.sh "$MATRIX" "$INVENTORY"; do
    [ -f "$required" ] || fail "missing $required"
  done

  # The locked decisions are the program. Losing one of these lines means a
  # packet can be authored against an architecture the owner never approved.
  grep -Fq '**Surface is reserved for interaction.**' "$DIR/_DESIGN.md" || fail "design lost the interaction-only surface rule"
  grep -Fq "**The row's subject is its name.**" "$DIR/_DESIGN.md" || fail "design lost the name-first sacrifice order"
  grep -Fq '**One owner answers what an agent is doing.**' "$DIR/_DESIGN.md" || fail "design lost single status ownership"
  grep -Fq '**An unobserved agent is unconfirmed, never working.**' "$DIR/_DESIGN.md" || fail "design lost the unconfirmed rule"
  grep -Fq '**Persisted state is evidence, never liveness.**' "$DIR/_DESIGN.md" || fail "design lost the reconciliation premise"
  grep -Fq '**A name is never an identifier.**' "$DIR/_DESIGN.md" || fail "design lost the naming rule"
  grep -Fq '**No stock AppKit chrome in the sidebar.**' "$DIR/_DESIGN.md" || fail "design lost the custom-chrome rule"
  grep -Fq '**Activity never reorders the list.**' "$DIR/_DESIGN.md" || fail "design lost the frozen ordering rule"
  grep -Fq '**Lifecycle is derived, never stored.**' "$DIR/_DESIGN.md" || fail "design lost the derived-lifecycle rule"
  grep -Fq '**Children stay visible; fan-out is bounded.**' "$DIR/_DESIGN.md" || fail "design lost the fan-out decision"
  grep -Fq '**I5 remains absolute.**' "$DIR/_DESIGN.md" || fail "design lost the I5 boundary"

  # Implementation model is an owner decision, not a loop default to drift.
  grep -Fq 'PI_WORKER_MODELS="${PI_WORKER_MODELS:-openai-codex/gpt-5.6-luna}"' scripts/sidebar-native-ux-loop.sh || fail "loop lost the pinned Luna implementation model"
  grep -Fq 'PI_THINKING="${PI_THINKING:-max}"' scripts/sidebar-native-ux-loop.sh || fail "loop lost max thinking for implementation"
  grep -Fq 'openai-codex/gpt-5.6-sol' scripts/sidebar-native-ux-loop.sh || fail "loop lost the opposite-model reviewer"
  grep -Fq 'MAX_REPAIR_PASSES="${MAX_REPAIR_PASSES:-2}"' scripts/sidebar-native-ux-loop.sh || fail "loop lost bounded repair budget"
  grep -Fq 'DECISION: APPROVE' scripts/sidebar-native-ux-loop.sh || fail "loop lost independent review gate"
  grep -Fq 'first_eligible_ticket' scripts/sidebar-native-ux-loop.sh || fail "loop lost dependency selection"
  grep -Fq 'validate_scope' scripts/sidebar-native-ux-loop.sh || fail "loop lost file-fence validation"
  grep -Fq 'run_final_checks' scripts/sidebar-native-ux-loop.sh || fail "loop lost harness final checks"
  grep -Fq 'update_ledger_done' scripts/sidebar-native-ux-loop.sh || fail "loop lost targeted ledger update"
  grep -Fq 'feat(sidebar):' scripts/sidebar-native-ux-loop.sh || fail "loop lost sidebar commit subject"
  grep -Fq 'Continuum Revived.app/Contents/MacOS' scripts/sidebar-native-ux-loop.sh || fail "loop lost the owner-instance preflight refusal"
  grep -Fq 'swift scripts/check-retina-main.swift' scripts/sidebar-native-ux-loop.sh || fail "loop lost the display preflight"

  grep -Fq 'The shell harness—not you—owns queue selection, ledger state' scripts/sidebar-native-ux-prompt.md || fail "worker regained queue/ledger ownership"
  grep -Fq 'Never run `git add`, `git commit`' scripts/sidebar-native-ux-prompt.md || fail "worker prompt lost git prohibition"
  grep -Fq '220, 280, and 320 pt' scripts/sidebar-native-ux-prompt.md || fail "worker prompt lost the shipping-width rule"
  grep -Fq 'never from a frame alone' scripts/sidebar-native-ux-prompt.md || fail "worker prompt lost the drawable-width rule"
  grep -Fq 'Do **not** bless a visual baseline' scripts/sidebar-native-ux-prompt.md || fail "worker prompt lost the baseline prohibition"

  bash -n scripts/sidebar-native-ux-loop.sh || fail "loop shell syntax invalid"
  bash -n scripts/sidebar-native-ux-loopctl.sh || fail "loopctl shell syntax invalid"

  # The loop's ticket lookups intentionally use the complete filename token,
  # but a shadow occurrence appended to an otherwise canonical row would still
  # match those lookups. Validate both the complete row shape and the exact
  # number of ticket occurrences, so a duplicate cannot change queue execution
  # or ledger state after this guard has passed.
  queue_shadow_rows="$(awk '
    function ticket_occurrences(line, rest, count) {
      rest = line
      count = 0
      while (match(rest, /`P[0-9]+\.[0-9]+-[^`]+\.md`/)) {
        count++
        rest = substr(rest, RSTART + RLENGTH)
      }
      return count
    }
    {
      occurrences = ticket_occurrences($0)
      if (occurrences > 0 &&
          (occurrences != 1 ||
           $0 !~ /^\| [0-9]+ \| `P[0-9]+\.[0-9]+-[^`]+\.md` \| [^|]* \| (autonomous|supervised) \|$/)) {
        print NR
      }
    }
  ' "$QUEUE")"
  [ -z "$queue_shadow_rows" ] ||
    fail "queue ticket row must contain exactly one ticket occurrence and canonical columns at line(s): $(printf '%s' "$queue_shadow_rows" | tr '\n' ' ')"

  ledger_shadow_rows="$(awk '
    function ticket_occurrences(line, rest, count) {
      rest = line
      count = 0
      while (match(rest, /`P[0-9]+\.[0-9]+-[^`]+\.md`/)) {
        count++
        rest = substr(rest, RSTART + RLENGTH)
      }
      return count
    }
    {
      occurrences = ticket_occurrences($0)
      if (occurrences > 0 &&
          (occurrences != 1 ||
           $0 !~ /^\| `P[0-9]+\.[0-9]+-[^`]+\.md` \| [^|]* \| [^|]* \| [^|]* \| [^|]* \|$/)) {
        print NR
      }
    }
  ' "$LEDGER")"
  [ -z "$ledger_shadow_rows" ] ||
    fail "ledger ticket row must contain exactly one ticket occurrence and canonical columns at line(s): $(printf '%s' "$ledger_shadow_rows" | tr '\n' ' ')"

  rows="$(grep -E '^\| [0-9]+ \| `P[0-9]+\.[0-9]+-[^`]+\.md` \|' "$QUEUE" 2>/dev/null || true)"
  count="$(printf '%s\n' "$rows" | grep -c '^|' | tr -d ' ')"
  [ "$count" = "$EXPECTED_TICKETS" ] || fail "expected $EXPECTED_TICKETS queue rows, found $count"

  seen_ids=""
  seen_files=""
  seen_queue_files=""
  expected_index=1
  supervised=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    index="$(printf '%s' "$row" | awk -F'|' '{gsub(/ /,"",$2); print $2}')"
    file="$(printf '%s' "$row" | awk -F'|' '{gsub(/^[ \t]*`|`[ \t]*$/,"",$3); print $3}')"
    deps="$(trim "$(printf '%s' "$row" | awk -F'|' '{print $4}')")"
    execution="$(trim "$(printf '%s' "$row" | awk -F'|' '{print $5}')")"
    id="${file%%-*}"
    phase="${id#P}"; phase="${phase%%.*}"

    [ "$index" = "$expected_index" ] || fail "row index $index, expected $expected_index"
    expected_index=$((expected_index + 1))
    [ -f "$DIR/$file" ] || fail "queue packet missing: $file"
    printf '%b' "$seen_ids" | grep -Fqx "$id" && fail "duplicate ticket id: $id"
    printf '%b' "$seen_files" | grep -Fqx "$file" && fail "duplicate ticket file: $file"
    seen_queue_files="${seen_queue_files}${file}\n"

    # Dependencies must already have been seen, so a forward reference and a
    # cycle are the same failure and neither can hide behind row order.
    if [ "$deps" = "—" ]; then
      :
    elif [ -z "$deps" ]; then
      fail "$id dependency cell is empty; use — for no dependencies"
    else
      printf '%s\n' "$deps" | grep -Eq '^P[0-9]+\.[0-9]+(, P[0-9]+\.[0-9]+)*$' || fail "$id invalid dependency grammar: [$deps]"
      old_ifs="$IFS"; IFS=','; dep_seen=""
      for dep in $deps; do
        dep="$(trim "$dep")"
        printf '%b' "$dep_seen" | grep -Fqx "$dep" && fail "$id repeats dependency: $dep"
        dep_seen="${dep_seen}${dep}\n"
        printf '%b' "$seen_ids" | grep -Fqx "$dep" || fail "$id dependency missing/not earlier: $dep"
      done
      IFS="$old_ifs"
    fi

    case "$execution" in
      autonomous) ;;
      supervised) supervised="${supervised}${id}\n" ;;
      *) fail "$id invalid execution mode: $execution" ;;
    esac

    if [ -f "$DIR/$file" ]; then
      for required in '## Goal' '## Context and design direction' '## Files' '## Approach' \
        '### Implementation sketch' '## Done when' '## Verify' '## Watch out'; do
        grep -Fxq "$required" "$DIR/$file" || fail "$file missing $required"
      done
      title="$(head -n 1 "$DIR/$file")"
      case "$title" in
        "# $id — "*) ;;
        *) fail "$file title does not start with '# $id — ': $title" ;;
      esac
      packet_phase="$(sed -n '3p' "$DIR/$file")"
      case "$packet_phase" in
        "Phase: $phase · "*) ;;
        *) fail "$file phase header disagrees with id $id: [$packet_phase]" ;;
      esac
      packet_execution="$(sed -n '4p' "$DIR/$file")"
      [ "$packet_execution" = "Execution: **$execution**" ] || fail "$file execution header [$packet_execution] disagrees with queue [$execution]"
      packet_deps="$(sed -n '5p' "$DIR/$file")"
      [ "$packet_deps" = "Depends on: $deps" ] || fail "$file dependency header [$packet_deps] disagrees with queue [Depends on: $deps]"
      grep -Fq "| \`$file\` |" "$LEDGER" || fail "$file missing ledger row"
      # Every packet has to be verifiable on its own. A runnable block keeps a
      # packet from passing the guard while silently dropping its check command.
      grep -Fq '```bash' "$DIR/$file" || fail "$file has no runnable verify block"
    fi

    seen_ids="${seen_ids}${id}\n"
    seen_files="${seen_files}${file}\n"
  done <<EOF
$rows
EOF

  actual_supervised="$(printf '%b' "$supervised" | sed '/^$/d')"
  expected_supervised="$(printf 'P1.5\nP3.6\nP5.6\nP7.1\n')"
  [ "$actual_supervised" = "$expected_supervised" ] || fail "supervised gates changed: [$actual_supervised]"

  packet_count="$(find "$DIR" -maxdepth 1 -type f -name 'P*.md' | wc -l | tr -d ' ')"
  [ "$packet_count" = "$EXPECTED_TICKETS" ] || fail "expected $EXPECTED_TICKETS packet files, found $packet_count"

  ledger_rows="$(grep -E '^\| `P[0-9]+\.[0-9]+-[^`]+\.md` \|' "$LEDGER" 2>/dev/null || true)"
  ledger_count="$(printf '%s\n' "$ledger_rows" | grep -c '^|' | tr -d ' ')"
  [ "$ledger_count" = "$EXPECTED_TICKETS" ] || fail "expected $EXPECTED_TICKETS ledger rows, found $ledger_count"
  seen_ledger=""; in_progress_count=0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    lfile="$(printf '%s' "$row" | awk -F'|' '{gsub(/^[ \t]*`|`[ \t]*$/,"",$2); print $2}')"
    lstate="$(trim "$(printf '%s' "$row" | awk -F'|' '{print $3}')")"
    lcommit="$(trim "$(printf '%s' "$row" | awk -F'|' '{print $4}')")"
    lupdated="$(trim "$(printf '%s' "$row" | awk -F'|' '{print $5}')")"
    printf '%b' "$seen_ledger" | grep -Fqx "$lfile" && fail "duplicate ledger row: $lfile"
    seen_ledger="${seen_ledger}${lfile}\n"
    [ -f "$DIR/$lfile" ] || fail "ledger row has no packet: $lfile"
    printf '%b' "$seen_queue_files" | grep -Fqx "$lfile" || fail "ledger row is not in queue: $lfile"
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

  # Queue 91 owns the first four executable lines. This program is appended at
  # line five, before setup can hide or swallow a structural failure. Its
  # normal `run` leg is separate so the inventory and matrix output record one
  # ordinary leg, just as the queue-91 guard does.
  if [ -f "$MATRIX" ]; then
    bash -n "$MATRIX" || fail "matrix shell syntax invalid"
    matrix_prefix="$(sed -n '1,4p' "$MATRIX")"
    expected_matrix_prefix="$(printf '%s\n' \
      '#!/usr/bin/env bash' \
      'set -euo pipefail' \
      '' \
      '"$(dirname "$0")/check-agent-tile-ux-program.sh" --check')"
    [ "$matrix_prefix" = "$expected_matrix_prefix" ] || fail "queue-91 locked executable prefix changed"

    sidebar_prefix="$(sed -n '5p' "$MATRIX")"
    [ "$sidebar_prefix" = '"$(dirname "$0")/check-sidebar-native-ux-program.sh" --check' ] ||
      fail "matrix must invoke sidebar program check immediately after queue-91 prefix"

    matrix_leg_count="$(grep -Fxc 'run scripts/check-sidebar-native-ux-program.sh' "$MATRIX" || true)"
    [ "$matrix_leg_count" = "1" ] || fail "matrix must retain exactly one reported sidebar program leg, found $matrix_leg_count"
    agent_leg_count="$(grep -Fxc 'run scripts/check-agent-tile-ux-program.sh' "$MATRIX" || true)"
    [ "$agent_leg_count" = "1" ] || fail "matrix lost the reported agent-tile program leg"
  else
    fail "missing $MATRIX"
  fi

  if [ -f "$INVENTORY" ]; then
    inventory_leg_count="$(grep -Fxc 'leg run scripts/check-sidebar-native-ux-program.sh' "$INVENTORY" || true)"
    [ "$inventory_leg_count" = "1" ] || fail "matrix inventory must record exactly one sidebar program leg, found $inventory_leg_count"
    grep -Fqx 'leg run scripts/check-agent-tile-ux-program.sh' "$INVENTORY" ||
      fail "matrix inventory lost the agent-tile program leg"
  else
    fail "missing $INVENTORY"
  fi
}

# --- throwaway-copy self-test helpers ---------------------------------------
# These helpers only mutate a copied case. They deliberately avoid `git
# checkout` and never write the live queue, ledger, or packets.
sed_edit() {
  local file="$1"; shift
  local tmp="${file}.sidebar-selftest.tmp"
  if ! sed "$@" "$file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$file"
}

mutate_missing_packet() {
  rm "$DIR/P0.2-sidebar-check-seam.md"
}

mutate_duplicate_id() {
  sed_edit "$QUEUE" -e '/P0\.2-sidebar-check-seam\.md/s/P0\.2-sidebar-check-seam\.md/P0.1-program-contract.md/'
}

mutate_shadow_queue_row() {
  grep -F '| 10 | `P1.5-containment-supervised-review.md` |' "$QUEUE" |
    sed -e 's/| supervised |/| autonomous |/' -e 's/^/ /' >> "$QUEUE"
}

mutate_extra_queue_ticket_cell() {
  sed_edit "$QUEUE" -e '/| 2 | `P0.2-sidebar-check-seam.md` |/s/$/ | `P1.5-containment-supervised-review.md` |/'
}

mutate_shadow_ledger_row() {
  grep -F '| `P1.5-containment-supervised-review.md` |' "$LEDGER" |
    sed 's/^/ /' >> "$LEDGER"
}

mutate_extra_ledger_ticket_cell() {
  sed_edit "$LEDGER" -e '/| `P0.2-sidebar-check-seam.md` |/s/$/ | `P1.5-containment-supervised-review.md` |/'
}

mutate_missing_ledger_row() {
  sed_edit "$LEDGER" -e '\|`P0.2-sidebar-check-seam.md`|d'
}

mutate_duplicate_ledger_row() {
  grep -F '| `P0.2-sidebar-check-seam.md` |' "$LEDGER" >> "$LEDGER"
}

mutate_empty_dependency() {
  sed_edit "$QUEUE" -e '/P0\.2-sidebar-check-seam\.md/s/| P0\.1 |/|  |/'
  sed_edit "$DIR/P0.2-sidebar-check-seam.md" -e 's/^Depends on: P0.1$/Depends on: /'
}

mutate_forward_dependency() {
  sed_edit "$QUEUE" -e '/P0\.2-sidebar-check-seam\.md/s/| P0\.1 |/| P0.3 |/'
  sed_edit "$DIR/P0.2-sidebar-check-seam.md" -e 's/^Depends on: P0.1$/Depends on: P0.3/'
}

mutate_trailing_empty_dependency() {
  sed_edit "$QUEUE" -e '/P0\.2-sidebar-check-seam\.md/s/| P0\.1 |/| P0.1, |/'
  sed_edit "$DIR/P0.2-sidebar-check-seam.md" -e 's/^Depends on: P0.1$/Depends on: P0.1,/'
}

mutate_duplicate_dependency() {
  sed_edit "$QUEUE" -e '/P0\.2-sidebar-check-seam\.md/s/| P0\.1 |/| P0.1, P0.1 |/'
  sed_edit "$DIR/P0.2-sidebar-check-seam.md" -e 's/^Depends on: P0.1$/Depends on: P0.1, P0.1/'
}

mutate_regex_dependency() {
  sed_edit "$QUEUE" -e '/P0\.2-sidebar-check-seam\.md/s/| P0\.1 |/| P0[.]1 |/'
  sed_edit "$DIR/P0.2-sidebar-check-seam.md" -e 's/^Depends on: P0.1$/Depends on: P0[.]1/'
}

mutate_cyclic_dependency() {
  sed_edit "$QUEUE" -e '/P0\.2-sidebar-check-seam\.md/s/| P0\.1 |/| P0.3 |/'
  sed_edit "$QUEUE" -e '/P0\.3-row-fixture-corpus\.md/s/| P0\.2 |/| P0.2 |/'
  sed_edit "$DIR/P0.2-sidebar-check-seam.md" -e 's/^Depends on: P0.1$/Depends on: P0.3/'
}

mutate_queue_execution_mismatch() {
  sed_edit "$QUEUE" -e '/P0\.2-sidebar-check-seam\.md/s/| autonomous |/| supervised |/'
}

mutate_packet_execution_mismatch() {
  sed_edit "$DIR/P0.2-sidebar-check-seam.md" -e '4s/autonomous/supervised/'
}

mutate_misleading_execution_text() {
  sed_edit "$DIR/P1.5-containment-supervised-review.md" -e '4s/supervised/autonomous/'
  printf '\nExecution: **supervised**\n' >> "$DIR/P1.5-containment-supervised-review.md"
}

mutate_missing_heading() {
  sed_edit "$DIR/P0.2-sidebar-check-seam.md" -e 's/^## Verify$/## Checks/'
}

mutate_missing_verify_block() {
  sed_edit "$DIR/P0.2-sidebar-check-seam.md" -e 's/^```bash$/```text/'
}

mutate_packet_dependency_drift() {
  sed_edit "$DIR/P0.2-sidebar-check-seam.md" -e 's/^Depends on: P0.1$/Depends on: P0.4/'
}

mutate_packet_dependency_label_removed() {
  sed_edit "$DIR/P0.2-sidebar-check-seam.md" -e 's/^Depends on: P0.1$/P0.1/'
}

mutate_packet_phase_drift() {
  sed_edit "$DIR/P1.2-interaction-fill-ladder.md" -e '3s/Phase: 1 · /Phase: 3 · /'
}

mutate_packet_title_drift() {
  sed_edit "$DIR/P1.3-header-shelf-hairlines.md" -e '1s/^# P1.3 /# P1.7 /'
}

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
  mutate_ledger_fields P0.4-inbox-geometry-gate.md shipped — 2026-08-03T00:00:00Z
}

mutate_forged_pending_commit() {
  mutate_ledger_fields P0.5-row-token-vocabulary.md pending deadbee —
}

mutate_forged_pending_timestamp() {
  mutate_ledger_fields P0.5-row-token-vocabulary.md pending — 2026-08-03T00:00:00Z
}

mutate_forged_in_progress_commit() {
  mutate_ledger_fields P0.4-inbox-geometry-gate.md in-progress deadbee 2026-08-03T00:00:00Z
}

mutate_invalid_in_progress_timestamp() {
  mutate_ledger_fields P0.4-inbox-geometry-gate.md in-progress — 2026-99-99T99:99:99Z
}

mutate_forged_blocked_commit() {
  mutate_ledger_fields P0.4-inbox-geometry-gate.md blocked deadbee 2026-08-03T00:00:00Z
}

mutate_invalid_blocked_timestamp() {
  mutate_ledger_fields P0.4-inbox-geometry-gate.md blocked — 2026-99-99T99:99:99Z
}

mutate_forged_done_metadata() {
  mutate_ledger_fields P0.5-row-token-vocabulary.md done garbage garbage
}

mutate_invalid_done_timestamp() {
  mutate_ledger_fields P0.5-row-token-vocabulary.md done 'this commit' 2026-99-99T99:99:99Z
}

mutate_multiple_in_progress_rows() {
  mutate_ledger_fields P0.4-inbox-geometry-gate.md in-progress — 2026-08-03T00:00:00Z
  mutate_ledger_fields P0.5-row-token-vocabulary.md in-progress — 2026-08-03T00:00:01Z
}

mutate_downgraded_p1_5() {
  sed_edit "$QUEUE" -e '/P1\.5-containment-supervised-review\.md/s/| supervised |/| autonomous |/'
  sed_edit "$DIR/P1.5-containment-supervised-review.md" -e '4s/supervised/autonomous/'
}

mutate_downgraded_p3_6() {
  sed_edit "$QUEUE" -e '/P3\.6-status-supervised-review\.md/s/| supervised |/| autonomous |/'
  sed_edit "$DIR/P3.6-status-supervised-review.md" -e '4s/supervised/autonomous/'
}

mutate_downgraded_p5_6() {
  sed_edit "$QUEUE" -e '/P5\.6-interaction-supervised-review\.md/s/| supervised |/| autonomous |/'
  sed_edit "$DIR/P5.6-interaction-supervised-review.md" -e '4s/supervised/autonomous/'
}

mutate_downgraded_p7_1() {
  sed_edit "$QUEUE" -e '/P7\.1-final-supervised-acceptance\.md/s/| supervised |/| autonomous |/'
  sed_edit "$DIR/P7.1-final-supervised-acceptance.md" -e '4s/supervised/autonomous/'
}

mutate_unwired_matrix_prefix() {
  sed_edit "$MATRIX" -e '5s|.*|# sidebar program check removed|'
}

mutate_nonblocking_matrix_prefix() {
  sed_edit "$MATRIX" -e '5s#.*#"$(dirname "$0")/check-sidebar-native-ux-program.sh" --check || true#'
}

mutate_disabled_matrix_prefix() {
  sed_edit "$MATRIX" -e '5s|.*|if false; then|'
}

mutate_queue_91_prefix() {
  sed_edit "$MATRIX" -e '4s|.*|# agent-tile program check removed|'
}

mutate_reported_matrix_leg() {
  sed_edit "$MATRIX" -e '\|^run scripts/check-sidebar-native-ux-program.sh$|d'
}

mutate_inventory_record_removed() {
  sed_edit "$INVENTORY" -e '\|^leg run scripts/check-sidebar-native-ux-program.sh$|d'
}

snapshot_live_program() {
  local file
  find "$DIR" -maxdepth 1 -type f \( -name '_QUEUE.md' -o -name '_LEDGER.md' -o -name 'P*.md' \) -print | sort |
    while IFS= read -r file; do
      shasum -a 256 "$file"
    done
}

self_test() {
  local tmp base out st cases_run=0 cases_failed=0 name expect mutate work before after
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sidebar-native-ux-program-selftest.XXXXXX")" || {
    echo "sidebar-native-ux program self-test: cannot create temp dir" >&2
    return 1
  }
  trap 'rm -rf "$tmp"' EXIT

  before="$tmp/live-before"
  after="$tmp/live-after"
  snapshot_live_program > "$before"

  base="$tmp/base"
  mkdir -p "$base/$DIR" "$base/scripts" "$base/$(dirname "$INVENTORY")"
  cp "$DIR"/*.md "$base/$DIR/"
  cp "$INVENTORY" "$base/$INVENTORY"
  cp "$MATRIX" "$base/$MATRIX"
  cp "$0" "$base/scripts/check-sidebar-native-ux-program.sh"
  cp scripts/check-agent-tile-ux-program.sh \
    scripts/sidebar-native-ux-prompt.md scripts/sidebar-native-ux-loop.sh \
    scripts/sidebar-native-ux-loopctl.sh scripts/check-retina-main.swift "$base/scripts/"
  chmod +x "$base/scripts/check-sidebar-native-ux-program.sh"

  run_case() {
    local case_name="$1" case_expect="$2" case_mutate="$3" case_work
    cases_run=$((cases_run + 1))
    case_work="$tmp/case-$cases_run"
    cp -R "$base" "$case_work"
    if ! ( cd "$case_work" && "$case_mutate" ); then
      echo "sidebar-native-ux program self-test: case '$case_name' mutation failed" >&2
      cases_failed=$((cases_failed + 1))
    fi
    out="$("$case_work/scripts/check-sidebar-native-ux-program.sh" --check 2>&1)"
    st=$?
    if [ "$st" -eq 0 ]; then
      echo "sidebar-native-ux program self-test: case '$case_name' passed the check but must fail" >&2
      cases_failed=$((cases_failed + 1))
    elif ! printf '%s' "$out" | grep -Fq "$case_expect"; then
      echo "sidebar-native-ux program self-test: case '$case_name' failed for the wrong reason" >&2
      printf '  wanted: %s\n  got: %s\n' "$case_expect" "$out" >&2
      cases_failed=$((cases_failed + 1))
    else
      printf "sidebar-native-ux program self-test: %s red (%s)\n" "$case_name" "$case_expect"
    fi
    rm -rf "$case_work"
  }

  # The unmutated copy must be green, or none of the cases below prove anything.
  out="$("$base/scripts/check-sidebar-native-ux-program.sh" --check 2>&1)"
  st=$?
  if [ "$st" -ne 0 ]; then
    echo "sidebar-native-ux program self-test: the unmutated fixture is red" >&2
    printf '%s\n' "$out" >&2
    cases_failed=$((cases_failed + 1))
  fi

  run_case 'missing packet file' \
    'queue packet missing: P0.2-sidebar-check-seam.md' mutate_missing_packet
  run_case 'duplicate ticket id' \
    'duplicate ticket id: P0.1' mutate_duplicate_id
  run_case 'shadow queue ticket row' \
    'queue ticket row must contain exactly one ticket occurrence and canonical columns' mutate_shadow_queue_row
  run_case 'extra ticket cell on canonical queue row' \
    'queue ticket row must contain exactly one ticket occurrence and canonical columns' mutate_extra_queue_ticket_cell
  run_case 'shadow ledger ticket row' \
    'ledger ticket row must contain exactly one ticket occurrence and canonical columns' mutate_shadow_ledger_row
  run_case 'extra ticket cell on canonical ledger row' \
    'ledger ticket row must contain exactly one ticket occurrence and canonical columns' mutate_extra_ledger_ticket_cell
  run_case 'missing ledger row' \
    'P0.2-sidebar-check-seam.md missing ledger row' mutate_missing_ledger_row
  run_case 'duplicate ledger row' \
    'duplicate ledger row: P0.2-sidebar-check-seam.md' mutate_duplicate_ledger_row
  run_case 'empty dependency cell' \
    'dependency cell is empty; use — for no dependencies' mutate_empty_dependency
  run_case 'forward dependency' \
    'P0.2 dependency missing/not earlier: P0.3' mutate_forward_dependency
  run_case 'trailing empty dependency' \
    'invalid dependency grammar: [P0.1,]' mutate_trailing_empty_dependency
  run_case 'duplicate dependency' \
    'repeats dependency: P0.1' mutate_duplicate_dependency
  run_case 'regex-shaped dependency' \
    'invalid dependency grammar: [P0[.]1]' mutate_regex_dependency
  run_case 'cyclic dependency' \
    'P0.2 dependency missing/not earlier: P0.3' mutate_cyclic_dependency
  run_case 'queue/packet execution mismatch' \
    'P0.2-sidebar-check-seam.md execution header' mutate_queue_execution_mismatch
  run_case 'packet execution mismatch' \
    'P0.2-sidebar-check-seam.md execution header' mutate_packet_execution_mismatch
  run_case 'misleading execution text outside header' \
    'P1.5-containment-supervised-review.md execution header [Execution: **autonomous**] disagrees with queue [supervised]' mutate_misleading_execution_text
  run_case 'missing required heading' \
    'P0.2-sidebar-check-seam.md missing ## Verify' mutate_missing_heading
  run_case 'missing runnable verify block' \
    'P0.2-sidebar-check-seam.md has no runnable verify block' mutate_missing_verify_block
  run_case 'packet dependency line drift' \
    'P0.2-sidebar-check-seam.md dependency header [Depends on: P0.4] disagrees with queue [Depends on: P0.1]' mutate_packet_dependency_drift
  run_case 'packet dependency label removed' \
    'P0.2-sidebar-check-seam.md dependency header [P0.1] disagrees with queue [Depends on: P0.1]' mutate_packet_dependency_label_removed
  run_case 'packet phase drift' \
    'P1.2-interaction-fill-ladder.md phase header disagrees with id P1.2' mutate_packet_phase_drift
  run_case 'packet title id drift' \
    "title does not start with '# P1.3 — '" mutate_packet_title_drift
  run_case 'invalid ledger state' \
    'has invalid ledger state: shipped' mutate_invalid_ledger_state
  run_case 'forged commit on pending row' \
    'is pending but records commit' mutate_forged_pending_commit
  run_case 'forged timestamp on pending row' \
    'is pending but records date' mutate_forged_pending_timestamp
  run_case 'forged commit on in-progress row' \
    'is in-progress but records commit' mutate_forged_in_progress_commit
  run_case 'invalid in-progress timestamp' \
    'is in-progress without a real ISO UTC update' mutate_invalid_in_progress_timestamp
  run_case 'forged commit on blocked row' \
    'is blocked but records commit' mutate_forged_blocked_commit
  run_case 'invalid blocked timestamp' \
    'is blocked without a real ISO UTC update' mutate_invalid_blocked_timestamp
  run_case 'forged done metadata' \
    "is done without the required 'this commit' marker" mutate_forged_done_metadata
  run_case 'invalid done timestamp' \
    'is done without a real ISO UTC update' mutate_invalid_done_timestamp
  run_case 'multiple in-progress rows' \
    'ledger has 2 in-progress rows; at most one is valid' mutate_multiple_in_progress_rows
  run_case 'downgraded P1.5 supervised gate' \
    'supervised gates changed' mutate_downgraded_p1_5
  run_case 'downgraded P3.6 supervised gate' \
    'supervised gates changed' mutate_downgraded_p3_6
  run_case 'downgraded P5.6 supervised gate' \
    'supervised gates changed' mutate_downgraded_p5_6
  run_case 'downgraded P7.1 supervised gate' \
    'supervised gates changed' mutate_downgraded_p7_1
  run_case 'unwired sidebar matrix prefix' \
    'matrix must invoke sidebar program check immediately after queue-91 prefix' mutate_unwired_matrix_prefix
  run_case 'nonblocking sidebar matrix prefix' \
    'matrix must invoke sidebar program check immediately after queue-91 prefix' mutate_nonblocking_matrix_prefix
  run_case 'disabled sidebar matrix prefix' \
    'matrix must invoke sidebar program check immediately after queue-91 prefix' mutate_disabled_matrix_prefix
  run_case 'queue-91 prefix changed' \
    'queue-91 locked executable prefix changed' mutate_queue_91_prefix
  run_case 'reported sidebar matrix leg removed' \
    'matrix must retain exactly one reported sidebar program leg' mutate_reported_matrix_leg
  run_case 'inventory record removed' \
    'matrix inventory must record exactly one sidebar program leg' mutate_inventory_record_removed

  snapshot_live_program > "$after"
  if ! cmp -s "$before" "$after"; then
    echo "sidebar-native-ux program self-test: live queue, ledger, or packet bytes changed" >&2
    cases_failed=$((cases_failed + 1))
  else
    echo "sidebar-native-ux program self-test: live queue, ledger, and packet bytes unchanged"
  fi

  rm -rf "$tmp"
  trap - EXIT

  if [ "$cases_failed" -gt 0 ]; then
    echo "sidebar-native-ux program self-test: $cases_failed of $cases_run case(s) did not go red as required" >&2
    return 1
  fi
  echo "sidebar-native-ux program self-test: ok ($cases_run negative cases red, live program untouched)"
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
  echo "sidebar-native-ux program check: $failures failure(s)" >&2
  exit 1
fi

echo "sidebar-native-ux program check: ok ($EXPECTED_TICKETS packets, dependency order valid, 4 supervised gates; self-test and matrix wiring enforced)"

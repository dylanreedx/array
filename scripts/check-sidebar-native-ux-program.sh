#!/usr/bin/env bash
# Bootstrap structural guard for docs/38-tickets/94-sidebar-native-ux.
# P0.1 hardens this with throwaway-copy mutation self-tests and matrix wiring.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DIR="docs/38-tickets/94-sidebar-native-ux"
QUEUE="$DIR/_QUEUE.md"
LEDGER="$DIR/_LEDGER.md"
EXPECTED_TICKETS=40
failures=0
fail() { echo "sidebar-native-ux program check failed: $*" >&2; failures=$((failures + 1)); }
trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
valid_utc_timestamp() {
  local parsed
  parsed="$(LC_ALL=C date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" || return 1
  [ "$parsed" = "$1" ]
}

check_program() {
  local required file rows count seen_ids seen_files expected_index supervised
  local row index deps execution id phase packet_phase packet_execution packet_deps title
  local old_ifs dep dep_seen actual_supervised expected_supervised packet_count
  local ledger_rows ledger_count seen_ledger in_progress_count lfile lstate lcommit lupdated

  for required in \
    "$DIR/_DESIGN.md" "$DIR/_RUNBOOK.md" "$QUEUE" "$LEDGER" \
    scripts/sidebar-native-ux-prompt.md scripts/sidebar-native-ux-loop.sh \
    scripts/sidebar-native-ux-loopctl.sh scripts/check-retina-main.swift; do
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

  rows="$(grep -E '^\| [0-9]+ \| `P[0-9]+\.[0-9]+-[^`]+\.md` \|' "$QUEUE" 2>/dev/null || true)"
  count="$(printf '%s\n' "$rows" | grep -c '^|' | tr -d ' ')"
  [ "$count" = "$EXPECTED_TICKETS" ] || fail "expected $EXPECTED_TICKETS queue rows, found $count"

  seen_ids=""
  seen_files=""
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
      case "$title" in "# $id — "*) ;; *) fail "$file title does not start with '# $id — ': $title" ;; esac
      packet_phase="$(sed -n '3p' "$DIR/$file")"
      case "$packet_phase" in "Phase: $phase · "*) ;; *) fail "$file phase header disagrees with $id: [$packet_phase]" ;; esac
      packet_execution="$(sed -n '4p' "$DIR/$file")"
      [ "$packet_execution" = "Execution: **$execution**" ] || fail "$file execution header [$packet_execution] disagrees with queue [$execution]"
      packet_deps="$(sed -n '5p' "$DIR/$file")"
      [ "$packet_deps" = "Depends on: $deps" ] || fail "$file dependency header [$packet_deps] disagrees with queue [Depends on: $deps]"
      grep -Fq "| \`$file\` |" "$LEDGER" || fail "$file missing ledger row"
      # Every packet has to be verifiable on its own, and the shipping-width rule
      # is what stops a sidebar assertion from proving nothing at 220 pt.
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
}

case "${1:---check}" in
  --check) check_program ;;
  *) echo "usage: $0 --check" >&2; exit 2 ;;
esac

if [ "$failures" -gt 0 ]; then
  echo "sidebar-native-ux program check: $failures failure(s)" >&2
  exit 1
fi

echo "sidebar-native-ux program check: ok ($EXPECTED_TICKETS packets, dependency order valid, 4 supervised gates; P0.1 still owns mutation self-tests + matrix wiring)"

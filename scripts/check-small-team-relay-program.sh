#!/usr/bin/env bash
# Bootstrap structural guard for docs/38-tickets/92-small-team-relay.
# P0.1 hardens this with throwaway-copy mutation self-tests and matrix wiring.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DIR="docs/38-tickets/92-small-team-relay"
QUEUE="$DIR/_QUEUE.md"
LEDGER="$DIR/_LEDGER.md"
failures=0
fail() { echo "small-team-relay program check failed: $*" >&2; failures=$((failures + 1)); }
trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
valid_utc_timestamp() {
  local parsed
  parsed="$(LC_ALL=C date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" || return 1
  [ "$parsed" = "$1" ]
}

check_program() {
  local required file rows count seen_ids seen_files expected_index supervised
  local row index deps execution id phase packet_phase packet_execution packet_deps title

  for required in \
    "$DIR/_DESIGN.md" "$DIR/_RUNBOOK.md" "$DIR/_DECISIONS.md" "$DIR/_ACTION_ITEMS.md" \
    "$DIR/plan.mdx" "$QUEUE" "$LEDGER" \
    scripts/small-team-relay-prompt.md scripts/small-team-relay-loop.sh scripts/small-team-relay-loopctl.sh; do
    [ -f "$required" ] || fail "missing $required"
  done

  grep -Fq '**Persist before broadcast.**' "$DIR/_DESIGN.md" || fail "design lost persist-before-broadcast"
  grep -Fq '**Execution hosts remain final authorities.**' "$DIR/_DESIGN.md" || fail "design lost host authority"
  grep -Fq '**Typed privileged protocol.**' "$DIR/_DESIGN.md" || fail "design lost typed privileged protocol"
  grep -Fq '### Class C — host-only secrets/runtime' "$DIR/_DESIGN.md" || fail "design lost Class-C boundary"
  grep -Fq 'approximately $5/month or less' "$DIR/_DESIGN.md" || fail "design lost honest budget target"
  grep -Fq 'Do not update or depend on the hosted visual plan.' scripts/small-team-relay-prompt.md || fail "worker prompt regained hosted-plan dependency"
  grep -Fq 'The shell harness—not you—owns queue selection, ledger state' scripts/small-team-relay-prompt.md || fail "worker regained queue/ledger ownership"
  grep -Fq 'Never run `git add`, `git commit`' scripts/small-team-relay-prompt.md || fail "worker prompt lost git prohibition"
  grep -Fq 'openai-codex/gpt-5.6-sol openai-codex/gpt-5.6-luna' scripts/small-team-relay-loop.sh || fail "loop lost Sol/Luna pair"
  grep -Fq 'MAX_REPAIR_PASSES="${MAX_REPAIR_PASSES:-2}"' scripts/small-team-relay-loop.sh || fail "loop lost bounded repair budget"
  grep -Fq 'DECISION: APPROVE' scripts/small-team-relay-loop.sh || fail "loop lost independent review gate"
  grep -Fq 'first_eligible_ticket' scripts/small-team-relay-loop.sh || fail "loop lost dependency selection"
  grep -Fq 'validate_scope' scripts/small-team-relay-loop.sh || fail "loop lost file-fence validation"
  grep -Fq 'run_final_checks' scripts/small-team-relay-loop.sh || fail "loop lost harness final checks"
  grep -Fq 'update_ledger_done' scripts/small-team-relay-loop.sh || fail "loop lost targeted ledger update"
  grep -Fq 'feat(relay):' scripts/small-team-relay-loop.sh || fail "loop lost relay commit subject"

  bash -n scripts/small-team-relay-loop.sh || fail "loop shell syntax invalid"
  bash -n scripts/small-team-relay-loopctl.sh || fail "loopctl shell syntax invalid"

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
    deps="$(trim "$(printf '%s' "$row" | awk -F'|' '{print $4}')")"
    execution="$(trim "$(printf '%s' "$row" | awk -F'|' '{print $5}')")"
    id="${file%%-*}"
    phase="${id#P}"; phase="${phase%%.*}"

    [ "$index" = "$expected_index" ] || fail "row index $index, expected $expected_index"
    expected_index=$((expected_index + 1))
    [ -f "$DIR/$file" ] || fail "queue packet missing: $file"
    printf '%b' "$seen_ids" | grep -Fqx "$id" && fail "duplicate ticket id: $id"
    printf '%b' "$seen_files" | grep -Fqx "$file" && fail "duplicate ticket file: $file"

    if [ "$deps" = "—" ]; then
      :
    elif [ -z "$deps" ]; then
      fail "$id dependency cell empty"
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
      for required in '## Goal' '## Context and design direction' '## Files' '## Approach' '### Implementation sketch' '## Done when' '## Verify' '## Watch out'; do
        grep -Fxq "$required" "$DIR/$file" || fail "$file missing $required"
      done
      title="$(head -n 1 "$DIR/$file")"
      case "$title" in "# $id — "*) ;; *) fail "$file title disagrees with $id" ;; esac
      packet_phase="$(sed -n '3p' "$DIR/$file")"
      case "$packet_phase" in "Phase: $phase · "*) ;; *) fail "$file phase header disagrees with $id: [$packet_phase]" ;; esac
      packet_execution="$(sed -n '4p' "$DIR/$file")"
      [ "$packet_execution" = "Execution: **$execution**" ] || fail "$file execution header [$packet_execution] disagrees with queue [$execution]"
      packet_deps="$(sed -n '5p' "$DIR/$file")"
      [ "$packet_deps" = "Depends on: $deps" ] || fail "$file dependency header [$packet_deps] disagrees with queue [$deps]"
      grep -Fq "| \`$file\` |" "$LEDGER" || fail "$file missing ledger row"
    fi

    seen_ids="${seen_ids}${id}\n"
    seen_files="${seen_files}${file}\n"
  done <<EOF
$rows
EOF

  actual_supervised="$(printf '%b' "$supervised" | sed '/^$/d')"
  expected_supervised="$(printf 'P3.10\nP4.9\nP5.7\n')"
  [ "$actual_supervised" = "$expected_supervised" ] || fail "supervised gates changed: [$actual_supervised]"

  packet_count="$(find "$DIR" -maxdepth 1 -type f -name 'P*.md' | wc -l | tr -d ' ')"
  [ "$packet_count" = 50 ] || fail "expected 50 packet files, found $packet_count"

  ledger_rows="$(grep -E '^\| `P[0-9]+\.[0-9]+-[^`]+\.md` \|' "$LEDGER" 2>/dev/null || true)"
  ledger_count="$(printf '%s\n' "$ledger_rows" | grep -c '^|' | tr -d ' ')"
  [ "$ledger_count" = 50 ] || fail "expected 50 ledger rows, found $ledger_count"
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
        [ "$lcommit" = "—" ] || fail "$lfile pending with commit"
        [ "$lupdated" = "—" ] || fail "$lfile pending with timestamp"
        ;;
      in-progress)
        in_progress_count=$((in_progress_count + 1))
        [ "$lcommit" = "—" ] || fail "$lfile in-progress with commit"
        valid_utc_timestamp "$lupdated" || fail "$lfile in-progress without valid UTC timestamp"
        ;;
      blocked)
        [ "$lcommit" = "—" ] || fail "$lfile blocked with commit"
        valid_utc_timestamp "$lupdated" || fail "$lfile blocked without valid UTC timestamp"
        ;;
      done)
        [ "$lcommit" = "this commit" ] || fail "$lfile done without this commit marker"
        valid_utc_timestamp "$lupdated" || fail "$lfile done without valid UTC timestamp"
        ;;
      *) fail "$lfile invalid ledger state: $lstate" ;;
    esac
  done <<EOF
$ledger_rows
EOF
  [ "$in_progress_count" -le 1 ] || fail "ledger has $in_progress_count in-progress rows"
}

case "${1:---check}" in
  --check) check_program ;;
  *) echo "usage: $0 --check" >&2; exit 2 ;;
esac

if [ "$failures" -gt 0 ]; then
  echo "small-team-relay program check: $failures failure(s)" >&2
  exit 1
fi

echo "small-team-relay program check: ok (50 packets, dependency order valid, 3 supervised gates; P0.1 still owns mutation self-tests + matrix wiring)"

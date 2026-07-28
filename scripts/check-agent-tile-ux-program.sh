#!/usr/bin/env bash
# Structural guard for docs/38-tickets/91-agent-tile-ux authoring.
set -uo pipefail
cd "$(dirname "$0")/.."

DIR="docs/38-tickets/91-agent-tile-ux"
QUEUE="$DIR/_QUEUE.md"
LEDGER="$DIR/_LEDGER.md"
failures=0
fail() { echo "agent-tile-program check failed: $*" >&2; failures=$((failures + 1)); }

for f in "$DIR/_DESIGN.md" "$DIR/_RUNBOOK.md" "$QUEUE" "$LEDGER" scripts/agent-tile-ux-prompt.md scripts/agent-tile-ux-loop.sh scripts/agent-tile-ux-loopctl.sh; do
  [ -f "$f" ] || fail "missing $f"
done

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

  [ "$index" = "$expected_index" ] || fail "row index $index, expected $expected_index"
  expected_index=$((expected_index + 1))
  [ -f "$DIR/$file" ] || fail "queue packet missing: $file"
  printf '%b' "$seen_ids" | grep -qx "$id" && fail "duplicate ticket id: $id"
  printf '%b' "$seen_files" | grep -qx "$file" && fail "duplicate ticket file: $file"

  if [ "$deps" != "—" ]; then
    old_ifs="$IFS"; IFS=','
    for dep in $deps; do
      dep="$(printf '%s' "$dep" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      printf '%b' "$seen_ids" | grep -qx "$dep" || fail "$id dependency is missing or not earlier: $dep"
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
      grep -Fq "$heading" "$DIR/$file" || fail "$file missing $heading"
    done
    grep -Fq "Execution: **$execution**" "$DIR/$file" || fail "$file execution disagrees with queue"
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

packet_count="$(find "$DIR" -maxdepth 1 -type f -name 'P*.md' | wc -l | tr -d ' ')"
[ "$packet_count" = 50 ] || fail "expected 50 packet files, found $packet_count"
ledger_count="$(grep -cE '^\| `P[0-9]+\.[0-9]+-[^`]+\.md` \|' "$LEDGER" || true)"
[ "$ledger_count" = 50 ] || fail "expected 50 ledger rows, found $ledger_count"

if [ "$failures" -gt 0 ]; then
  echo "agent-tile-program check: $failures failure(s)" >&2
  exit 1
fi

echo "agent-tile-program check: ok (50 packets, dependency order valid, 3 supervised gates)"

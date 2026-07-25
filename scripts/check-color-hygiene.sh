#!/usr/bin/env bash
set -euo pipefail

# Ticket P1.7: colour hygiene, made mechanical.
#
# Without enforcement the colour debt regenerates — it already has, three times
# over (`AgentsBoardProjection` colorTokens, iOS `AppColors`, `zoneTint` are
# three parallel vocabularies). Two rules, both grep-shaped:
#
#   1. RAW      — no raw colour construction in a view:
#                 NSColor(red:/srgbRed:/calibratedRed:/white:, Color(red:,
#                 UIColor(red:.
#   2. SEMANTIC — no Apple/SwiftUI semantic colour (.labelColor,
#                 .secondaryLabelColor, .tertiaryLabelColor, .separatorColor,
#                 .primary, .secondary, Color(.tertiaryLabel)) in a file that
#                 also paints its own hardcoded fill. That combination is the
#                 exact pattern that produced tonight's black-on-dark bug: an
#                 Aqua-resolved label drawn onto a dark-only literal fill.
#
# Every violation that exists today is listed, one line at a time, in
#   docs/38-tickets/90-agent-ux/color-hygiene-allowlist.txt
# with a reason and the ticket that removes it. The gate is red on any violation
# that is NOT allowlisted, and equally red on an allowlist entry whose line no
# longer exists — so the list cannot rot into a rubber stamp.
#
# Deliberately NO bless/regenerate env var. Every other committed-artifact gate
# in this repo has one (baselines, matrix inventory) because those artifacts
# legitimately change. This one only ever shrinks: an allowlist that a worker
# can regenerate is exactly the theatre the ticket warns about. `--print-violations`
# prints the records for a human to paste, which still forces a reason and an
# owner to be typed by hand.

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

ALLOWLIST_FILE=docs/38-tickets/90-agent-ux/color-hygiene-allowlist.txt
SCAN_DIRS=(
  Sources/ContinuumRevived/Canvas
  Sources/ContinuumRevived/App
  ios/Continuum/Sources
)

# Fixture and witness surfaces construct colours on purpose: the component Lab
# is a catalogue of canned cards, the UIProbe family renders and measures them,
# and *Checks files assert against literal colours. Excluded by path with this
# comment rather than by several hundred allowlist lines (P1.7 "Watch out").
EXCLUDE_RE='/(ComponentLab|UIProbe[A-Za-z]*|UITourCheck|UITestSupport)\.swift$|Checks\.swift$'

# Broader than the six literal spellings the ticket lists, because a lint that
# only knows one spelling of a constructor is a lint you can walk around:
# `NSColor.init(red:`, `SwiftUI.Color(red:`, a component label the list happens
# not to name (`displayP3Red:`, `calibratedWhite:`), and the multi-line form
# (`NSColor(` with its arguments on the following lines) all construct exactly
# the same raw colour. Measured against today's tree, every one of these
# additions matches zero extra lines — they close routes, they do not reclassify
# existing code.
RAW_COMPONENTS='red|srgbRed|calibratedRed|deviceRed|displayP3Red|white|calibratedWhite|deviceWhite|genericGamma22White|hue'
RAW_RE="(SwiftUI\.|AppKit\.|UIKit\.)?(NS|UI)?Color(\.init)?\([[:space:]]*(${RAW_COMPONENTS}):|(SwiftUI\.|AppKit\.|UIKit\.)?(NS|UI)?Color(\.init)?\([[:space:]]*$"
# Same reasoning on the semantic side: the ticket names `Color(.tertiaryLabel)`,
# so the platform spellings of the same colours (`Color(.label)`,
# `UIColor.secondaryLabel`) belong to the rule it is describing. The scan covers
# iOS, where those are the idiomatic form.
SEMANTIC_RE='\.labelColor|\.secondaryLabelColor|\.tertiaryLabelColor|\.quaternaryLabelColor|\.separatorColor|\.primary\b|\.secondary\b|Color\(\.(label|secondaryLabel|tertiaryLabel|quaternaryLabel|separator)\)|(NS|UI)Color\.(label|secondaryLabel|tertiaryLabel|quaternaryLabel|separator)\b'
# Where a colour lands as a fill. `.background(` covers the SwiftUI form where
# the literal is bound to a palette constant first (iOS `AppColors`).
FILL_SINK_RE='backgroundColor|fillColor|setFill|\.fill\(|drawsBackground|\.background\('

PRINT_ONLY=0
if [[ $# -gt 0 ]]; then
  case "$1" in
    --print-violations)
      PRINT_ONLY=1
      shift
      ;;
    -h|--help)
      cat <<'USAGE'
Usage: scripts/check-color-hygiene.sh [--print-violations]

Fails when a raw colour, or an Apple semantic colour on a hardcoded fill, is not
listed in docs/38-tickets/90-agent-ux/color-hygiene-allowlist.txt — and when an
allowlisted line no longer exists.

--print-violations prints today's violation records (path:count:text, one per
line) instead of checking. Paste an entry into the allowlist ONLY above a
`# <reason> · owner: <ticket>` comment line.
USAGE
      exit 0
      ;;
    *)
      printf 'check-color-hygiene: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
fi
if [[ $# -gt 0 ]]; then
  printf 'check-color-hygiene: unexpected extra arguments: %s\n' "$*" >&2
  exit 2
fi

for dir in "${SCAN_DIRS[@]}"; do
  if [[ ! -d "$dir" ]]; then
    printf 'FAIL: missing scan directory %s — the gate would silently cover less.\n' "$dir" >&2
    exit 1
  fi
done

scan_files() {
  find "${SCAN_DIRS[@]}" -name '*.swift' | { grep -vE "$EXCLUDE_RE" || true; } | LC_ALL=C sort
}

# Numbered lines with whole-line comments dropped: a commented-out example must
# not count as a violation, and the prose in this repo's headers quotes these
# very patterns. A trailing comment on a live line is left alone on purpose —
# stripping `//` would also cut URLs out of string literals.
file_lines() {
  { grep -n '' "$1" || true; } | { grep -vE '^[0-9]+:[[:space:]]*//' || true; }
}

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/continuum-color-hygiene.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT
RECORDS="$WORK_DIR/records"
: > "$RECORDS"

while IFS= read -r file; do
  [[ -n "$file" ]] || continue
  lines=$(file_lines "$file")
  [[ -n "$lines" ]] || continue

  raw_hits=$(printf '%s\n' "$lines" | { grep -E "$RAW_RE" || true; })
  if [[ -n "$raw_hits" ]]; then
    printf '%s\n' "$raw_hits" | while IFS= read -r hit; do
      printf 'raw\t%s\t%s\n' "$file" "$hit" >> "$RECORDS"
    done
  fi

  # Rule 2 only bites where both halves of the trap are present in one file.
  # Herestring, not `printf | grep -q`: grep -q exits on its first match, the
  # writer takes SIGPIPE, and `pipefail` then reports the pipeline as failed even
  # though the pattern DID match — which would drop rule-2 records at random.
  if [[ -n "$raw_hits" ]] && grep -qE "$FILL_SINK_RE" <<<"$lines"; then
    semantic_hits=$(printf '%s\n' "$lines" | { grep -E "$SEMANTIC_RE" || true; })
    if [[ -n "$semantic_hits" ]]; then
      printf '%s\n' "$semantic_hits" | while IFS= read -r hit; do
        printf 'semantic\t%s\t%s\n' "$file" "$hit" >> "$RECORDS"
      done
    fi
  fi
done < <(scan_files)

# One record per distinct (path, line text): path<TAB>text<TAB>count<TAB>where<TAB>rule.
# The key is a single line's own text, never a file or a glob, so an allowlist
# entry can only ever excuse that one line. `count` keeps duplicated lines
# honest — two identical dark fills in one file need both.
AGG="$WORK_DIR/aggregated"
awk -F'\t' '
  {
    rule = $1
    path = $2
    rest = $3
    for (i = 4; i <= NF; i++) rest = rest "\t" $i
    colon = index(rest, ":")
    lineno = substr(rest, 1, colon - 1)
    text = substr(rest, colon + 1)
    # Tab is the field separator here, so it may not survive inside a key: a tab
    # in a Swift string literal would shift every field after text and quietly
    # make the exact-line comparison inexact. Normalised to a space on BOTH
    # sides (see the allowlist parser), so the comparison stays total.
    gsub(/\t/, " ", text)
    gsub(/^[ ]+|[ ]+$/, "", text)
    key = path "\t" text
    count[key] += 1
    where[key] = (where[key] == "" ? path ":" lineno : where[key] ", " path ":" lineno)
    kind[key] = rule
  }
  END {
    for (k in count) printf "%s\t%d\t%s\t%s\n", k, count[k], where[k], kind[k]
  }
' "$RECORDS" | LC_ALL=C sort > "$AGG"

if (( PRINT_ONLY == 1 )); then
  awk -F'\t' '{ printf "%s:%d:%s\n", $1, $3, $2 }' "$AGG"
  exit 0
fi

if [[ ! -f "$ALLOWLIST_FILE" ]]; then
  printf 'FAIL: missing %s — the allowlist is a committed artifact; deleting it is not a way to green.\n' \
    "$ALLOWLIST_FILE" >&2
  exit 1
fi

failures=0
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# Parse the allowlist: every entry must sit directly under a comment line that
# names a reason and an owning ticket, and the excused text must itself be one
# of the two banned patterns. Both rules exist so an entry cannot be widened
# into a file- or glob-scoped pass.
ALLOWED="$WORK_DIR/allowed"
: > "$ALLOWED"
prev_comment=""
lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))
  case "$line" in
    ''|'#'*)
      prev_comment="$line"
      continue
      ;;
  esac

  entry_path=${line%%:*}
  rest=${line#*:}
  entry_count=${rest%%:*}
  entry_text=${rest#*:}
  entry_text=${entry_text//$'\t'/ }   # matches the aggregate's normalisation

  if [[ -z "$entry_path" || -z "$entry_text" || ! "$entry_count" =~ ^[0-9]+$ ]]; then
    fail "$ALLOWLIST_FILE:$lineno is not a path:count:text entry: $line"
    prev_comment=""
    continue
  fi
  if [[ "$prev_comment" != '#'* ]] || [[ "$prev_comment" != *'owner: '* ]]; then
    fail "$ALLOWLIST_FILE:$lineno has no '# <reason> · owner: <ticket>' comment directly above it: $line"
  fi
  if ! grep -qE "$RAW_RE|$SEMANTIC_RE" <<<"$entry_text"; then
    fail "$ALLOWLIST_FILE:$lineno excuses text that is not a banned colour pattern (allowlist entries are line-scoped, never wholesale): $entry_text"
  fi
  printf '%s\t%s\t%s\n' "$entry_path" "$entry_text" "$entry_count" >> "$ALLOWED"
  prev_comment=""
done < "$ALLOWLIST_FILE"

LC_ALL=C sort -o "$ALLOWED" "$ALLOWED"

# Three ways to be red, all in one pass over the two maps:
#   not on the list           → a new violation, named with file:line
#   on the list, wrong count  → an occurrence was added
#   on the list, not in tree  → a stale entry, so the list cannot rot
COMPARISON="$WORK_DIR/comparison"
awk -F'\t' -v allowlist="$ALLOWLIST_FILE" '
  NR == FNR { allowed[$1 "\t" $2] = $3; next }
  {
    key = $1 "\t" $2
    if (!(key in allowed)) {
      printf "new %s colour violation at %s: %s\n", $5, $4, $2
      next
    }
    seen[key] = 1
    if (allowed[key] + 0 != $3 + 0) {
      printf "%s colour violation count changed at %s: allowlist says %s, tree has %s — %s\n", \
        $5, $4, allowed[key], $3, $2
    }
  }
  END {
    for (k in allowed) {
      if (!(k in seen)) {
        split(k, parts, "\t")
        printf "stale allowlist entry (%s): %s no longer contains: %s\n", allowlist, parts[1], parts[2]
      }
    }
  }
' "$ALLOWED" "$AGG" | LC_ALL=C sort > "$COMPARISON"

while IFS= read -r problem || [[ -n "$problem" ]]; do
  [[ -n "$problem" ]] || continue
  fail "$problem"
done < "$COMPARISON"

if (( failures > 0 )); then
  printf 'Colour hygiene failed with %d problem(s). Fix the colour (adopt a DesignTokens value) — do not widen the allowlist.\n' \
    "$failures" >&2
  exit 1
fi

printf 'Colour hygiene passed: %d allowlisted violation line(s), 0 new.\n' "$(wc -l < "$ALLOWED" | tr -d ' ')"

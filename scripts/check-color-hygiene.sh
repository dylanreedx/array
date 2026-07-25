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

# ---------------------------------------------------------------------------
# Rule 3 (P1.8): exactly ONE status→appearance mapping.
#
# `StatusChipPresenter` is it. Before P1.8 there were six, with three
# disagreeing glyph sets: `configuring` was purple in the tile, teal on the
# board and invisible-grey in the sidebar, and `◌` meant *stale* in the sidebar
# but *configuring* in the tile. Nothing about the allowlist above could have
# caught that — `.systemPurple` is not a raw colour construction — so this rule
# is the one that keeps the duplicates from growing back.
#
# NO allowlist, deliberately: the ticket's done-criterion is one mapping, so
# there is no legitimate second one to excuse. Scope is the whole of Sources and
# ios (the board map lived in Core, outside SCAN_DIRS above), minus the presenter
# itself and the *Checks suites, which enumerate statuses to assert against.
#
# Honest limit: this catches a status→COLOUR line and a status→GLYPH line, which
# is what all six duplicates were. A status→label map has no distinguishable
# greppable signature (`case .done: return "done"` is indistinguishable from any
# other string switch), so `runStatusChipChecks` totality plus review covers it.
# No `\b` and no multibyte bracket expression in these three: they are handed to
# awk, whose POSIX ERE reads `\b` as a backspace (so the pattern would match
# nothing at all and the rule would be silently inert — it was, for one revision)
# and whose bracket expressions are byte-oriented. Word boundary is spelled as an
# explicit character class, and the glyph set as alternation.
STATUS_CASE_RE='case[[:space:]]+\.(configuring|working|idle|needsAttention|done|stale)([^A-Za-z0-9_]|$)'
STATUS_COLOUR_RE='system[A-Z]|(NS|UI)?Color|colorToken|[Ll]abelColor|textColor|\.tint'
STATUS_GLYPH_RE='"(◆|●|✓|◌|○|◍|◐)'
PRESENTER=Sources/ContinuumRevivedAgentUI/StatusChip.swift

if [[ ! -f "$PRESENTER" ]]; then
  fail "missing $PRESENTER — the single status→appearance mapping cannot be verified"
else
  # A WINDOW, not a single line: `case .working:` with `return .systemBlue` on
  # the next line is the same duplicate map, and a one-line grep walks straight
  # past it. Each status case carries its following two lines with it, so both
  # the inline and the broken-over-lines spelling are caught. (Two lines is the
  # observed shape of every map this ticket deleted; a switch case whose colour
  # is four lines down is beyond grep and belongs to review.)
  duplicate_maps=$(
    find Sources ios -name '*.swift' \
      | { grep -vE "StatusChip\.swift$|Checks\.swift$" || true; } \
      | LC_ALL=C sort \
      | while IFS= read -r file; do
          [[ -n "$file" ]] || continue
          awk -v f="$file" -v caseRe="$STATUS_CASE_RE" -v hitRe="$STATUS_COLOUR_RE|$STATUS_GLYPH_RE" '
            { line[NR] = $0 }
            END {
              for (i = 1; i <= NR; i++) {
                if (line[i] !~ caseRe) continue
                window = line[i]
                for (j = i + 1; j <= i + 2 && j <= NR; j++) window = window " ⏎ " line[j]
                if (window ~ hitRe) printf "%s:%d:%s\n", f, i, window
              }
            }
          ' "$file"
        done
  )
  if [[ -n "$duplicate_maps" ]]; then
    while IFS= read -r hit; do
      [[ -n "$hit" ]] || continue
      fail "second status→appearance mapping (only $PRESENTER may map AgentStatus to a glyph or a colour): $hit"
    done <<<"$duplicate_maps"
  fi
fi

# ---------------------------------------------------------------------------
# Rule 4 (P1.12): on iOS, exactly ONE place resolves a token's theme.
#
# `AppColors.statusAccent(for:)` resolved every status hue `for: .dark` because
# the phone painted its own dark-only fills. Deleting the fills is only half the
# fix: any call site can still write `.resolved(for: .dark)` and pin itself back
# to one appearance, and unlike a raw literal that reads as perfectly reasonable
# code. So theme resolution belongs to the bridge, which reads
# `@Environment(\.colorScheme)` — the trait SwiftUI keeps correct on its own.
#
# NO allowlist, same reasoning as rule 3: the done-criterion is one resolution
# point. Constructing a `TokenTheme` FROM a colour scheme is not a pin and is not
# matched; naming `.light`/`.dark`, or calling `resolved(for:)`, is.
#
# Observed red with this code (P1.12), restoring the exact line P1.8 left behind:
#   FAIL: token theme resolved outside ios/Continuum/Sources/DesignTokens+SwiftUI.swift
#     (a call site that names a theme cannot follow the appearance):
#     ios/Continuum/Sources/ContinuumApp.swift:1214: .foregroundStyle(Color(chip: display.accent.resolved(for: .dark)))
# and with the bridge file deleted:
#   FAIL: missing ios/Continuum/Sources/DesignTokens+SwiftUI.swift — iOS's single
#     theme-resolution point cannot be verified
#
# Rule 4 also owns the EXPLICIT-COLOUR-SPACE constructor, because rule 1
# deliberately does not match it: `Color(.sRGB, red:…)` is the correct spelling
# for the bridge (ticket 87 watch-out #1 — the tokens' ratios were measured in
# sRGB, so a device-RGB `Color(red:…)` would be the wrong colour), which means
# rule 1 must let it through, which in turn leaves it as the one raw-colour
# spelling a call site could use to walk around the bridge entirely. Legal in the
# bridge, banned everywhere else under `ios/Continuum/Sources`, no allowlist —
# the same shape as the theme-pin rule above and for the same reason.
#
# Observed red with this code (P1.12), the bypass the bridge's own comment names:
#   FAIL: raw colour constructed outside ios/Continuum/Sources/DesignTokens+SwiftUI.swift
#     (the explicit-colour-space form rule 1 must allow for the bridge is not a
#     licence for a call site):
#     ios/Continuum/Sources/ContinuumApp.swift:1961: private let panelLiteral = Color(.sRGB, red: 0.10, green: 0.11, blue: 0.14, opacity: 1)
IOS_BRIDGE=ios/Continuum/Sources/DesignTokens+SwiftUI.swift
THEME_PIN_RE='resolved\(for:|TokenTheme\.(light|dark)'
# Anchored on the COLOUR-SPACE ARGUMENT, not on the constructor name. The first
# version of this pattern keyed on `Color(` and the vacuity guard below caught it
# immediately: the bridge's own line is `self.init(.sRGB, red:…)` inside an
# `extension Color`, so a `Color(`-anchored rule matched neither the bridge nor a
# call site spelling it `Color.init(.sRGB, …)`. Every initialiser that takes a
# colour space is a raw colour construction whoever writes it.
IOS_COLOURSPACE_RE='\([[:space:]]*\.(sRGB|sRGBLinear|displayP3|extendedSRGB)[[:space:]]*,|(SwiftUI\.)?Color(\.init)?\([[:space:]]*(cgColor|colorSpace):'

if [[ ! -f "$IOS_BRIDGE" ]]; then
  fail "missing $IOS_BRIDGE — iOS's single theme-resolution point cannot be verified"
else
  colourspace_hits=$(
    find ios/Continuum/Sources -name '*.swift' \
      | { grep -vF "$IOS_BRIDGE" || true; } \
      | LC_ALL=C sort \
      | while IFS= read -r file; do
          [[ -n "$file" ]] || continue
          file_lines "$file" | { grep -E "$IOS_COLOURSPACE_RE" || true; } \
            | while IFS= read -r hit; do printf '%s:%s\n' "$file" "$hit"; done
        done
  )
  if [[ -n "$colourspace_hits" ]]; then
    while IFS= read -r hit; do
      [[ -n "$hit" ]] || continue
      fail "raw colour constructed outside $IOS_BRIDGE (the explicit-colour-space form rule 1 must allow for the bridge is not a licence for a call site): $hit"
    done <<<"$colourspace_hits"
  fi
  # Vacuity guard, per rule 5's lesson: the bridge must itself contain the
  # spelling this rule bans elsewhere. If it stops doing so, the pattern has
  # drifted off the source and the ban above is matching nothing anywhere.
  if ! file_lines "$IOS_BRIDGE" | grep -qE "$IOS_COLOURSPACE_RE"; then
    fail "$IOS_BRIDGE no longer constructs an explicit-colour-space Color — rule 4's raw-colour ban would pass vacuously"
  fi

  theme_pins=$(
    find ios/Continuum/Sources -name '*.swift' \
      | { grep -vF "$IOS_BRIDGE" || true; } \
      | LC_ALL=C sort \
      | while IFS= read -r file; do
          [[ -n "$file" ]] || continue
          file_lines "$file" | { grep -E "$THEME_PIN_RE" || true; } \
            | while IFS= read -r hit; do printf '%s:%s\n' "$file" "$hit"; done
        done
  )
  if [[ -n "$theme_pins" ]]; then
    while IFS= read -r hit; do
      [[ -n "$hit" ]] || continue
      fail "token theme resolved outside $IOS_BRIDGE (a call site that names a theme cannot follow the appearance): $hit"
    done <<<"$theme_pins"
  fi
fi

# ---------------------------------------------------------------------------
# Rule 5 (P1.12): the zone-tint registries agree, name for name.
#
# A zone's tint is USER configuration (P1.11's ruling: mapping someone's "mint"
# onto `accentDone` would change what they picked), so it is the one colour
# vocabulary that is deliberately NOT a DesignTokens value — which means nothing
# above this line can catch the two platforms disagreeing about it. They did: iOS
# knew "amber"/"teal"/"pink"/"green", which the desktop registry does not have,
# so the Mac painted its teal fallback where the phone painted orange, teal, pink
# and green, and iOS fell back to grey where the desktop falls back to teal.
#
# Both switches have the same shape (`case "<name>": return <system colour>`,
# then `default:`), so the pairs are extractable and comparable. The colour is
# normalised across platform spellings — `NSColor.systemMint` and `.mint` are the
# same hue — and the `default:` arm is compared as a pair of its own, since a
# fallback is what silently renders an unknown name.
#
# Observed red with this code (P1.12), one witness per direction of drift:
#   iOS "orange" renamed back to "amber"  → "> amber=orange" and "< orange=orange"
#   iOS "mint" repainted `.green`         → "< mint=mint" and "> mint=green"
#   the DESKTOP registry gaining "pink"   → "< pink=pink"
#   the iOS signature renamed so the extraction stops matching →
#     FAIL: zone-tint registry not found in ios/Continuum/Sources/ContinuumApp.swift
#       — rule 5 would pass vacuously
# The last one is the load-bearing witness: rule 3 was silently inert for one
# revision, and a source-shape comparison that quietly matches nothing is the same
# failure with a green exit code.
ZONE_DESKTOP=Sources/ContinuumRevived/Canvas/CanvasNSView.swift
ZONE_IOS=ios/Continuum/Sources/ContinuumApp.swift

zone_registry() {
  local file=$1 signature=$2
  awk -v sig="$signature" '
    index($0, sig) { inside = 1; next }
    inside {
      trimmed = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", trimmed)
      if (trimmed == "}") exit
      if (match(trimmed, /^case[[:space:]]+"[^"]+"[[:space:]]*:[[:space:]]*return[[:space:]]+/)) {
        name = trimmed
        sub(/^case[[:space:]]+"/, "", name)
        sub(/".*$/, "", name)
      } else if (match(trimmed, /^default[[:space:]]*:[[:space:]]*return[[:space:]]+/)) {
        name = "default"
      } else {
        next
      }
      colour = trimmed
      sub(/^.*return[[:space:]]+/, "", colour)
      # Platform spellings of the same hue: NSColor.systemMint / UIColor.systemMint
      # / Color.mint / .mint all normalise to "mint".
      sub(/^(NS|UI|SwiftUI\.)?Color\./, "", colour)
      sub(/^\./, "", colour)
      sub(/^system/, "", colour)
      print tolower(name) "=" tolower(colour)
    }
  ' "$file"
}

if [[ ! -f "$ZONE_DESKTOP" || ! -f "$ZONE_IOS" ]]; then
  fail "missing a zone-tint registry file ($ZONE_DESKTOP / $ZONE_IOS) — the two platforms cannot be compared"
else
  desktop_zones=$(zone_registry "$ZONE_DESKTOP" 'static func color(named name: String)' | LC_ALL=C sort)
  ios_zones=$(zone_registry "$ZONE_IOS" 'func zoneTint(for token: String)' | LC_ALL=C sort)
  # An empty side means the extraction stopped matching the source, which would
  # make this rule silently inert — the failure mode rule 3 already suffered once.
  if [[ -z "$desktop_zones" ]]; then
    fail "zone-tint registry not found in $ZONE_DESKTOP — rule 5 would pass vacuously"
  elif [[ -z "$ios_zones" ]]; then
    fail "zone-tint registry not found in $ZONE_IOS — rule 5 would pass vacuously"
  elif [[ "$desktop_zones" != "$ios_zones" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      fail "zone-tint registries disagree ($ZONE_DESKTOP vs $ZONE_IOS): $line"
    done < <(diff <(printf '%s\n' "$desktop_zones") <(printf '%s\n' "$ios_zones") | { grep -E '^[<>]' || true; })
  fi
fi

if (( failures > 0 )); then
  printf 'Colour hygiene failed with %d problem(s). Fix the colour (adopt a DesignTokens value) — do not widen the allowlist.\n' \
    "$failures" >&2
  exit 1
fi

printf 'Colour hygiene passed: %d allowlisted violation line(s), 0 new; 1 status→appearance mapping; 1 iOS colour bridge (theme resolution + explicit-colour-space construction); %d zone tints agreeing across platforms.\n' \
  "$(wc -l < "$ALLOWED" | tr -d ' ')" \
  "$(printf '%s\n' "$desktop_zones" | wc -l | tr -d ' ')"

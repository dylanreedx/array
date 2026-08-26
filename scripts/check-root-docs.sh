#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

failures=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

require_file() {
  local file="$1"
  [[ -f "$file" ]] || fail "missing $file"
}

require_marker() {
  local file="$1" marker="$2"
  if [[ ! -f "$file" ]]; then
    return
  fi
  grep -Fqi -- "$marker" "$file" || fail "$file is missing required marker: $marker"
}

reject_regex() {
  local file="$1" regex="$2" label="$3"
  if [[ ! -f "$file" ]]; then
    return
  fi
  if grep -Eiq -- "$regex" "$file"; then
    fail "$file contains forbidden current-workflow phrase: $label"
  fi
}

check_line_count() {
  local file="$1" max_lines="$2"
  if [[ ! -f "$file" ]]; then
    return
  fi
  local lines
  lines=$(wc -l < "$file" | tr -d ' ')
  if (( lines > max_lines )); then
    fail "$file has $lines lines; expected <= $max_lines for quick orientation"
  fi
}

check_local_links() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    return
  fi

  perl -ne 'while (/\[[^\]]*\]\(([^)]+)\)/g) { print "$1\n" }' "$file" |
    while IFS= read -r raw_link; do
      local target="${raw_link%%#*}"
      target="${target%%[[:space:]]*}"
      [[ -n "$target" ]] || continue
      case "$target" in
        http://*|https://*|mailto:*) continue ;;
      esac
      if [[ "$target" = /* ]]; then
        [[ -e "$target" ]] || printf 'missing link in %s: %s\n' "$file" "$raw_link"
      else
        [[ -e "$(dirname "$file")/$target" ]] || printf 'missing link in %s: %s\n' "$file" "$raw_link"
      fi
    done
}

require_file README.md
require_file CONTRIBUTING.md

# This gate is real link-rot protection, and it spent a long time KNOWN-RED for
# a reason that was never about link rot: it was asking the WRONG FILE. Eight of
# its nine failing markers are contributor-workflow pointers that moved to
# CONTRIBUTING.md, and the ninth was the old codename, which the identity rule
# (AGENTS.md, non-negotiable 4) forbids in anything a user reads. Deleting the
# check would have thrown away the gate to silence the symptom.
for marker in \
  "macOS 14" \
  "SwiftPM" \
  "scripts/prepare-ghosttykit.sh" \
  "swift build" \
  "scripts/run-matrix.sh" \
  "scripts/check-app-bundle.sh" \
  "docs/README.md"; do
  require_marker README.md "$marker"
done

# Moved here from the README list: these describe how a contributor WORKS, not
# how the project is oriented, and CONTRIBUTING.md is where they actually live.
for marker in \
  "qa/run-autonomous.sh --scope changed" \
  "qa-runs" \
  "docs/20-product-vision.md" \
  "docs/21-agent-workflow.md" \
  "Linear" \
  "source of truth" \
  "no ticket, no code" \
  "main" \
  "do not push" \
  "one writer" \
  "evidence" \
  "reviewer gate" \
  "Do not weaken" \
  "git stash" \
  "not the primary queue"; do
  require_marker CONTRIBUTING.md "$marker"
done

for file in README.md CONTRIBUTING.md docs/README.md; do
  reject_regex "$file" 'integration/phase-6-reintegration' 'old integration branch workflow'
  reject_regex "$file" 'source of truth for what to work on' 'historical DD backlog as source of truth'
  reject_regex "$file" 'conductor[^\n]{0,40}(is|as|the)[^\n]{0,40}primary queue' 'conductor presented as primary queue'
  reject_regex "$file" 'push to (the )?remote' 'remote push instruction'
  reject_regex "$file" 'stash-based handoff' 'stash handoff instruction'
done

check_line_count README.md 150
check_line_count CONTRIBUTING.md 200

link_errors=$(mktemp "${TMPDIR:-/tmp}/continuum-root-doc-links.XXXXXX")
check_local_links README.md > "$link_errors"
check_local_links CONTRIBUTING.md >> "$link_errors"
check_local_links docs/README.md >> "$link_errors"
if [[ -s "$link_errors" ]]; then
  cat "$link_errors" >&2
  failures=$((failures + 1))
fi
rm -f "$link_errors"

if (( failures > 0 )); then
  exit 1
fi

printf 'Root docs checks passed.\n'

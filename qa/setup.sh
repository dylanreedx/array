#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "qa/setup.sh requires macOS because the external QA flows use cliclick, osascript, and screencapture." >&2
  exit 1
fi

missing=0

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required to install cliclick. Install Homebrew, then run: brew install cliclick" >&2
  missing=1
elif ! command -v cliclick >/dev/null 2>&1; then
  echo "cliclick is missing. Installing with: brew install cliclick"
  brew install cliclick
fi

for tool in osascript screencapture python3 caffeinate sips; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is missing from PATH." >&2
    missing=1
  fi
done

if ! command -v cliclick >/dev/null 2>&1; then
  echo "cliclick is still unavailable after setup." >&2
  missing=1
fi

cat <<'EOF'

Accessibility permission is required before flow scripts can click, type, drag, or resize windows.
Open System Settings > Privacy & Security > Accessibility and enable the terminal app or runner process that starts qa/flows/*.sh.

Verified commands:
  - cliclick
  - osascript
  - screencapture
  - python3
  - caffeinate
  - sips
EOF

if [[ "$missing" -ne 0 ]]; then
  exit 1
fi

echo "QA external driver setup passed."

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="${1:-/tmp/array-cursor-contrast}"
mkdir -p "$output"
xcrun swiftc -parse-as-library Sources/ContinuumRevivedAgentUI/*.swift \
  Sources/ContinuumRevived/App/Collaboration/SharedCursorDrawing.swift \
  scripts/checks/SharedCursorContrastCheck.swift -o "$output/cursor-contrast-check"
"$output/cursor-contrast-check" "$output"

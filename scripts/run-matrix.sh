#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

run() {
  printf '\n==> %s\n' "$*"
  "$@"
}

run swift build
run swift run ContinuumRevivedCoreChecks
run swift run ContinuumRevivedPaletteChecks
run .build/debug/continuum-revived --palette-duplicate-root-check
run .build/debug/continuum-revived --palette-first-responder-restore-check
run .build/debug/continuum-revived --browser-url-focus-check
run .build/debug/continuum-revived --palette-browser-spawn-check
run .build/debug/continuum-revived --palette-captures-keys-over-browser-check
run .build/debug/continuum-revived --zindex-relaunch-hit-test-check
run .build/debug/continuum-revived --bring-to-front-focus-check
run .build/debug/continuum-revived --note-click-focus-check
run .build/debug/continuum-revived --browser-restore-state-check
run .build/debug/continuum-revived --note-file-tile-spawn-check
run .build/debug/continuum-revived --file-tree-boot-persistence-check
run git diff --check

printf '\nMatrix passed.\n'

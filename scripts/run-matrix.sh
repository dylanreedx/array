#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

run() {
  printf '\n==> %s\n' "$*"
  "$@"
}

run_app_check() {
  local project_root app_support status
  project_root=$(mktemp -d "${TMPDIR:-/tmp}/continuum-matrix-project.XXXXXX")
  app_support=$(mktemp -d "${TMPDIR:-/tmp}/continuum-matrix-appsupport.XXXXXX")

  printf '\n==> CONTINUUM_PROJECT_ROOT=%s CONTINUUM_APP_SUPPORT=%s %s\n' \
    "$project_root" \
    "$app_support" \
    "$*"

  set +e
  CONTINUUM_PROJECT_ROOT="$project_root" \
    CONTINUUM_APP_SUPPORT="$app_support" \
    "$@"
  status=$?
  set -e

  rm -rf "$project_root" "$app_support"
  return "$status"
}

run swift build
run swift run ContinuumRevivedCoreChecks
run swift run ContinuumRevivedPaletteChecks
run swift run ContinuumRevivedFileTreeChecks
run swift run ContinuumRevivedPerfChecks
run_app_check .build/debug/continuum-revived --palette-duplicate-root-check
run_app_check .build/debug/continuum-revived --palette-first-responder-restore-check
run_app_check .build/debug/continuum-revived --browser-url-focus-check
run_app_check .build/debug/continuum-revived --browser-ui-delegate-check
run_app_check .build/debug/continuum-revived --browser-target-blank-check
run_app_check .build/debug/continuum-revived --browser-download-check
run_app_check .build/debug/continuum-revived --browser-auth-challenge-check
run_app_check .build/debug/continuum-revived --palette-browser-spawn-check
run_app_check .build/debug/continuum-revived --spawn-focus-policy-check
run_app_check .build/debug/continuum-revived --focus-broker-activation-check
run_app_check .build/debug/continuum-revived --nav-mode-check
run_app_check .build/debug/continuum-revived --palette-captures-keys-over-browser-check
run_app_check .build/debug/continuum-revived --zindex-relaunch-hit-test-check
run_app_check .build/debug/continuum-revived --single-zone-compat-check
run_app_check .build/debug/continuum-revived --multi-zone-render-check
run_app_check .build/debug/continuum-revived --agent-status-check
run_app_check .build/debug/continuum-revived --tile-world-bounds-check
run_app_check .build/debug/continuum-revived --bring-to-front-focus-check
run_app_check .build/debug/continuum-revived --note-click-focus-check
run_app_check .build/debug/continuum-revived --browser-restore-state-check
run_app_check .build/debug/continuum-revived --browser-profile-persistence-check
run_app_check .build/debug/continuum-revived --note-file-tile-spawn-check
run_app_check .build/debug/continuum-revived --run-artifacts-tile-check
run_app_check .build/debug/continuum-revived --zone-hydration-lifecycle-check
run_app_check .build/debug/continuum-revived --zone-save-isolation-check
run_app_check .build/debug/continuum-revived --add-zone-check
run_app_check .build/debug/continuum-revived --browser-lru-budget-check
run_app_check .build/debug/continuum-revived --spawn-placement-check
run_app_check .build/debug/continuum-revived --spawn-rate-limit-check
run_app_check .build/debug/continuum-revived --file-tree-boot-persistence-check
run_app_check .build/debug/continuum-revived --ticket-queue-tile-check
run_app_check .build/debug/continuum-revived --conductor-queue-tile-check
run_app_check .build/debug/continuum-revived --agent-input-check
run_app_check .build/debug/continuum-revived --diff-tile-check
run_app_check .build/debug/continuum-revived --file-tree-hardening-check
run_app_check .build/debug/continuum-revived --viewport-sanitize-check
run_app_check .build/debug/continuum-revived --project-lock-check
run_app_check .build/debug/continuum-revived --project-root-resolution-check
run_app_check .build/debug/continuum-revived --project-picker-resolution-check
run_app_check .build/debug/continuum-revived --terminal-snapshot-tier-check
run_app_check .build/debug/continuum-revived --stray-window-audit-check
run scripts/check-app-bundle.sh --configuration debug
run scripts/check-root-docs.sh
run git diff --check

printf '\nMatrix passed.\n'

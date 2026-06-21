#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

FAST=0
if [[ $# -gt 0 ]]; then
  case "$1" in
    --fast)
      FAST=1
      shift
      ;;
    -h|--help)
      cat <<'USAGE'
Usage: scripts/run-matrix.sh [--fast]

Runs the project verification matrix. --fast skips the slower packaging bundle
probe and keeps the build/check/app-flag/git hygiene gates used by the opt-in
pre-commit hook.
USAGE
      exit 0
      ;;
    *)
      echo "run-matrix: unknown argument: $1" >&2
      exit 2
      ;;
  esac
fi
if [[ $# -gt 0 ]]; then
  echo "run-matrix: unexpected extra arguments: $*" >&2
  exit 2
fi

run() {
  printf '\n==> %s\n' "$*"
  "$@"
}

run_app_check() {
  local project_root app_support status
  local tmux_args=()
  project_root=$(mktemp -d "${TMPDIR:-/tmp}/continuum-matrix-project.XXXXXX")
  app_support=$(mktemp -d "${TMPDIR:-/tmp}/continuum-matrix-appsupport.XXXXXX")

  case " $* " in
    *" --terminal-tmux-"*|*" --terminal-theme-fidelity-check"*) ;;
    *) tmux_args=(-continuum.terminal.tmux.enabled NO -continuum.terminal.tmux.path "") ;;
  esac

  printf '\n==> CONTINUUM_PROJECT_ROOT=%s CONTINUUM_APP_SUPPORT=%s %s' \
    "$project_root" \
    "$app_support" \
    "$*"
  if [[ ${#tmux_args[@]} -gt 0 ]]; then
    printf ' %q' "${tmux_args[@]}"
  fi
  printf '\n'

  set +e
  if [[ ${#tmux_args[@]} -gt 0 ]]; then
    CONTINUUM_PROJECT_ROOT="$project_root" \
      CONTINUUM_APP_SUPPORT="$app_support" \
      "$@" "${tmux_args[@]}"
  else
    CONTINUUM_PROJECT_ROOT="$project_root" \
      CONTINUUM_APP_SUPPORT="$app_support" \
      "$@"
  fi
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
run_app_check .build/debug/continuum-revived --settings-panel-check
run_app_check .build/debug/continuum-revived --keybind-edit-check
run_app_check .build/debug/continuum-revived --browser-url-focus-check
run_app_check .build/debug/continuum-revived --browser-ui-delegate-check
run_app_check .build/debug/continuum-revived --browser-element-context-check
run_app_check .build/debug/continuum-revived --browser-target-blank-check
run_app_check .build/debug/continuum-revived --browser-download-check
run_app_check .build/debug/continuum-revived --browser-auth-challenge-check
run_app_check .build/debug/continuum-revived --palette-browser-spawn-check
run_app_check .build/debug/continuum-revived --spawn-focus-policy-check
run_app_check .build/debug/continuum-revived --focus-broker-activation-check
run_app_check .build/debug/continuum-revived --nav-mode-check
run_app_check .build/debug/continuum-revived --leader-activation-check
run_app_check .build/debug/continuum-revived --leader-jump-check
run_app_check .build/debug/continuum-revived --leader-zone-jump-check
run_app_check .build/debug/continuum-revived --palette-jump-check
run_app_check .build/debug/continuum-revived --palette-zone-check
run_app_check .build/debug/continuum-revived --leader-snap-check
run_app_check .build/debug/continuum-revived --palette-captures-keys-over-browser-check
run_app_check .build/debug/continuum-revived --zindex-relaunch-hit-test-check
run_app_check .build/debug/continuum-revived --single-zone-compat-check
run_app_check .build/debug/continuum-revived --unified-model-boot-check
run_app_check .build/debug/continuum-revived --workspace-boot-persistence-check
run_app_check .build/debug/continuum-revived --zone-move-unified-check
run_app_check .build/debug/continuum-revived --multi-zone-render-check
run_app_check .build/debug/continuum-revived --zone-create-gesture-check
run_app_check .build/debug/continuum-revived --zone-autoname-check
run_app_check .build/debug/continuum-revived --zone-rename-inline-check
run_app_check .build/debug/continuum-revived --zone-create-encloses-check
run_app_check .build/debug/continuum-revived --zone-breakout-check
run_app_check .build/debug/continuum-revived --zone-close-keep-delete-check
run_app_check .build/debug/continuum-revived --zone-chrome-zorder-check
run_app_check .build/debug/continuum-revived --zone-resize-check
run_app_check .build/debug/continuum-revived --zone-adaptive-bounds-check
run_app_check .build/debug/continuum-revived --agent-status-check
run_app_check .build/debug/continuum-revived --tile-world-bounds-check
run_app_check .build/debug/continuum-revived --tile-drag-grab-check
run_app_check .build/debug/continuum-revived --tile-chrome-scale-check
run_app_check .build/debug/continuum-revived --resize-dimensions-hud-check
run_app_check .build/debug/continuum-revived --bring-to-front-focus-check
run_app_check .build/debug/continuum-revived --note-click-focus-check
run_app_check .build/debug/continuum-revived --focus-scope-dispatch-check
run_app_check .build/debug/continuum-revived --reserved-dispatch-check
run_app_check .build/debug/continuum-revived --tile-action-check
run_app_check .build/debug/continuum-revived --input-gate-check
run_app_check .build/debug/continuum-revived --drag-magnetize-check
run_app_check .build/debug/continuum-revived --resize-snap-check
run_app_check .build/debug/continuum-revived --browser-note-action-check
run_app_check .build/debug/continuum-revived --focus-border-check
run_app_check .build/debug/continuum-revived --browser-restore-state-check
run_app_check .build/debug/continuum-revived --browser-inspector-tile-shell-check
run_app_check .build/debug/continuum-revived --browser-inspector-dom-tree-check
run_app_check .build/debug/continuum-revived --browser-inspector-console-check
run_app_check .build/debug/continuum-revived --browser-inspector-styles-check
run_app_check .build/debug/continuum-revived --browser-inspector-network-lite-check
run_app_check .build/debug/continuum-revived --browser-inspector-link-lifecycle-check
run_app_check .build/debug/continuum-revived --browser-inspector-actions-check
run_app_check .build/debug/continuum-revived --browser-profile-persistence-check
run_app_check .build/debug/continuum-revived --note-file-tile-spawn-check
run_app_check .build/debug/continuum-revived --run-artifacts-tile-check
run_app_check .build/debug/continuum-revived --zone-hydration-lifecycle-check
run_app_check .build/debug/continuum-revived --zone-save-isolation-check
run_app_check .build/debug/continuum-revived --zone-registry-refcount-check
run_app_check .build/debug/continuum-revived --workspace-runtime-install-check
run_app_check .build/debug/continuum-revived --workspace-switch-check
run_app_check .build/debug/continuum-revived --workspace-profile-check
run_app_check .build/debug/continuum-revived --add-zone-check
run_app_check .build/debug/continuum-revived --browser-lru-budget-check
run_app_check .build/debug/continuum-revived --zone-tier-transition-check
run_app_check .build/debug/continuum-revived --spawn-placement-check
run_app_check .build/debug/continuum-revived --focus-mode-check
run_app_check .build/debug/continuum-revived --spawn-rate-limit-check
run_app_check .build/debug/continuum-revived --file-tree-boot-persistence-check
run_app_check .build/debug/continuum-revived --persistence-crash-safe-check
run_app_check .build/debug/continuum-revived --ticket-queue-tile-check
run_app_check .build/debug/continuum-revived --conductor-queue-tile-check
run_app_check .build/debug/continuum-revived --agent-input-check
run_app_check .build/debug/continuum-revived --diff-tile-check
run_app_check .build/debug/continuum-revived --file-tree-hardening-check
run_app_check .build/debug/continuum-revived --viewport-sanitize-check
run_app_check .build/debug/continuum-revived --project-lock-check
run_app_check .build/debug/continuum-revived --project-root-resolution-check
run_app_check .build/debug/continuum-revived --project-picker-resolution-check
run_app_check .build/debug/continuum-revived --terminal-tmux-persistence-check
run_app_check .build/debug/continuum-revived --terminal-tmux-delete-lifecycle-check
run_app_check .build/debug/continuum-revived --terminal-tmux-live-integration-check
run_app_check .build/debug/continuum-revived --terminal-theme-fidelity-check
run_app_check .build/debug/continuum-revived --terminal-snapshot-tier-check
run_app_check .build/debug/continuum-revived --terminal-fills-tile-check
run_app_check .build/debug/continuum-revived --session-resume-check
run_app_check .build/debug/continuum-revived --stray-window-audit-check
if [[ "$FAST" -eq 0 ]]; then
  run scripts/check-app-bundle.sh --configuration debug
else
  printf '\n==> skipping scripts/check-app-bundle.sh --configuration debug (--fast)\n'
fi
run scripts/check-root-docs.sh
run git diff --check

if [[ "$FAST" -eq 1 ]]; then
  printf '\nFast matrix passed.\n'
else
  printf '\nMatrix passed.\n'
fi

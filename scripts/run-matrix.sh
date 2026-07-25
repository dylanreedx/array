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

# Ticket P0.1: compile the iOS app, not just the macOS package. Core is shared
# with the phone, so an iOS-only break (e.g. `Process`, which does not exist on
# iOS) has to turn the matrix red here instead of reaching the owner. xcodebuild
# is chatty, so capture the log and print it only when the build fails — the
# same shape as every other leg's failure output. Skips loudly (never silently)
# on a machine with no Xcode; that is the only condition it is gated on.
run_ios_build() {
  local log status
  local cmd=(
    xcodebuild
    -project ios/Continuum.xcodeproj
    -scheme Continuum
    -sdk iphonesimulator
    -destination 'generic/platform=iOS Simulator'
    build
  )

  if ! command -v xcodebuild >/dev/null 2>&1; then
    printf '\n==> SKIPPED (no xcodebuild on PATH): iOS app build — install Xcode to cover the shared-Core-on-iOS gate.\n'
    return 0
  fi

  # Print the exact argv that runs, so the log can never drift from the command.
  printf '\n==>'
  printf ' %q' "${cmd[@]}"
  printf '\n'
  log=$(mktemp "${TMPDIR:-/tmp}/continuum-matrix-ios.XXXXXX")

  set +e
  "${cmd[@]}" >"$log" 2>&1
  status=$?
  set -e

  if [[ "$status" -ne 0 ]]; then
    printf 'iOS build FAILED (exit %d). Full log: %s\n' "$status" "$log"
    cat "$log"
    return "$status"
  fi

  printf 'iOS build succeeded.\n'
  rm -f "$log"
  return 0
}

# Ticket P0.11: first leg, so a matrix that lost a check goes red before it
# spends minutes building. The guard is a normal leg, so deleting it removes its
# own inventory record and trips the same gate.
run scripts/check-matrix-inventory.sh
# Ticket P1.7: colour hygiene. A pure grep lint over the view layers, so it runs
# before the build for the same reason as the inventory guard — a new raw colour
# should be named in seconds, not after a full build. Red on any raw colour or
# any Apple semantic colour on a hardcoded fill that is not line-scoped in
# docs/38-tickets/90-agent-ux/color-hygiene-allowlist.txt, and equally red when
# an allowlisted line disappears, so the list cannot rot.
run scripts/check-color-hygiene.sh
run swift build
run_ios_build
run swift run ContinuumRevivedCoreChecks
# Ticket P1.1: the shared agent-UI module's own leg. It links AgentUI alone, so
# it also proves the dependency direction — a token that reaches back into Core
# cannot compile here. StatusChip's assertions moved here from
# ContinuumRevivedCoreChecks unchanged.
run swift run ContinuumRevivedAgentUIChecks
run swift run ContinuumRevivedSyncChecks
# Ticket 86 (D4-R1): relay hub core — auth/scope, lossless catch-up, I5 gate.
run swift run ContinuumRevivedRelayChecks
# Ticket 57: gated real-CloudKit backend leg. Skips gracefully (exit 0,
# cloudkit_available=false in the manifest) unless CLOUDKIT_ENABLED=1 is set
# — never set in this matrix; the real leg is device-gate-owed. Explicitly
# forced to 0 here (round-3 reviewer concern #3) so this invocation can never
# accidentally go live against a real, unentitled CKContainer just because
# CLOUDKIT_ENABLED=1 happens to be exported in the ambient shell environment
# the matrix runs in.
CLOUDKIT_ENABLED=0 run swift run ContinuumRevivedSyncIntegrationChecks
run swift run ContinuumRevivedPaletteChecks
run swift run ContinuumRevivedFileTreeChecks
run swift run ContinuumRevivedPerfChecks
run_app_check .build/debug/continuum-revived --companion-sync-health-check
run_app_check .build/debug/continuum-revived --push-payload-dump-check
run_app_check .build/debug/continuum-revived --palette-duplicate-root-check
run_app_check .build/debug/continuum-revived --palette-first-responder-restore-check
run_app_check .build/debug/continuum-revived --settings-panel-check
run_app_check .build/debug/continuum-revived --component-lab-check
# Ticket P0.2: the UIProbe substrate every later phase-0 gate layers on — asserts a
# component really renders at the requested size in the requested NSAppearance, and
# that .aqua vs .darkAqua produce different pixels.
run_app_check .build/debug/continuum-revived --ui-probe-check
# Ticket P0.3: geometry gates over the probed managed-agent tile — width-fill ratios,
# card/model parity, no zero-size or ambiguous views, no clipping at the tile minimum
# width, and a non-vacuous scrolled-to-bottom assertion, in both appearances.
run_app_check .build/debug/continuum-revived --ui-geometry-check
# Ticket P0.4, wired by P1.6: WCAG contrast over the REAL view tree in both
# appearances — every text/background and border/fill pair the lab surfaces render.
# Built in P0.4 and deliberately left unwired: it was red on 177 of 446 pairs while
# the app still painted literals. P1.10/P1.11 adopted the tokens (177 -> 78 -> 11)
# and P1.6 closed the last 11, so it is a gate now. There is no allowlist and no
# exemption: a failing pair means the colour is wrong.
run_app_check .build/debug/continuum-revived --ui-contrast-check
# Ticket P0.5: numeric pixel probes over the probed managed-agent tile — a label's
# rect must be modulated (text that never drew is flat) and a border band must
# differ from the fill inside it, in both appearances. Flatness only; WCAG ratios
# are --ui-contrast-check's business.
run_app_check .build/debug/continuum-revived --ui-pixel-check
# Ticket P0.6: committed PNG baselines for every static Component Lab card in both
# appearances. Catches regressions nobody wrote an assertion for; blessing is
# explicit (CONTINUUM_UPDATE_BASELINES=1 ./scripts/run-matrix.sh) and never implicit.
run_app_check .build/debug/continuum-revived --ui-baseline-check
# Ticket P0.9: the advisory tour — a labelled contact sheet of the agent surfaces
# (managed-agent tile in four states x three widths, transcript cards at three
# widths, status chips, sidebar, settings) in both appearances, written to
# qa-runs/<ts>/tour/ with an index.md.
#
# NOT a gate, by packet instruction: its exit status is captured and reported, never
# propagated, so it can never fail the matrix. The check itself contains no visual
# assertion either, so the only thing it can complain about is mechanical (a surface
# fixture vanished, a render threw, artifacts unwritable) — which is why the warning
# below is loud rather than silent. If it fails the build on aesthetics, workers
# start "fixing" screenshots instead of bugs.
ui_tour_status=0
run_app_check .build/debug/continuum-revived --ui-tour-check || ui_tour_status=$?
if [[ "$ui_tour_status" -ne 0 ]]; then
  printf '\nrun-matrix: WARNING — the advisory UI tour exited %d (see above). It does NOT gate the matrix; the deterministic UI gates are --ui-probe/geometry/pixel/baseline-check.\n' "$ui_tour_status"
fi
run_app_check .build/debug/continuum-revived --ui-test-support-check
# Ticket P2A.3: the supervisor owns the runners, not the tile — a scripted runner
# (no Pi, no network) fans one agent's event sequence out to two live subscribers
# and one late one, stop terminates a blocked runner, and the record persists.
# Also source-scans Sources/ContinuumRevived so no view can construct its own
# PiAgentRunner and become a second owner.
run_app_check .build/debug/continuum-revived --agent-supervisor-check
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
run_app_check .build/debug/continuum-revived --workspace-sidebar-shell-check
run_app_check .build/debug/continuum-revived --workspace-sidebar-default-visible-check
run_app_check .build/debug/continuum-revived --workspace-sidebar-actions-check
run_app_check .build/debug/continuum-revived --workspace-sidebar-live-status-check
run_app_check .build/debug/continuum-revived --workspace-top-bar-check
run_app_check .build/debug/continuum-revived --browser-profile-persistence-check
run_app_check .build/debug/continuum-revived --note-file-tile-spawn-check
run_app_check .build/debug/continuum-revived --run-artifacts-tile-check
run_app_check .build/debug/continuum-revived --zone-hydration-lifecycle-check
run_app_check .build/debug/continuum-revived --zone-save-isolation-check
run_app_check .build/debug/continuum-revived --zone-project-session-naming-check
run_app_check .build/debug/continuum-revived --zone-lazy-resume-check
run_app_check .build/debug/continuum-revived --zone-registry-refcount-check
run_app_check .build/debug/continuum-revived --agent-message-bus-check
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
run_app_check .build/debug/continuum-revived --topology-migration-check
run_app_check .build/debug/continuum-revived --terminal-tmux-persistence-check
run_app_check .build/debug/continuum-revived --new-tile-cwd-check
run_app_check .build/debug/continuum-revived --terminal-tmux-delete-lifecycle-check
run_app_check .build/debug/continuum-revived --terminal-tmux-ambient-workspace-check
run_app_check .build/debug/continuum-revived --session-observer-check
run_app_check .build/debug/continuum-revived --terminal-tmux-observer-check
run_app_check .build/debug/continuum-revived --terminal-tmux-observer-wiring-check
# These five render a real terminal/Ghostty surface and time out in a headless
# sandbox ("waiting for initial real terminal surface"; --session-resume-check
# ticks ghostty_app_tick until real output appears and times out identically
# when the display is asleep/locked — proven at base commit edf2486 with no
# ticket code in the tree, 2026-07-02). Set
# CONTINUUM_SKIP_SURFACE_CHECKS=1 to skip them (they belong to the supervised
# visual gate — run the full matrix on a GUI host to cover them). Not fake-green:
# they are deferred to where they can actually run, and the skip is printed loudly.
if [[ "${CONTINUUM_SKIP_SURFACE_CHECKS:-0}" == "1" ]]; then
  printf '\n==> SKIPPED (headless, CONTINUUM_SKIP_SURFACE_CHECKS=1): --terminal-tmux-live-integration-check, --terminal-theme-fidelity-check, --terminal-snapshot-tier-check, --terminal-fills-tile-check, --session-resume-check — surface-rendering checks deferred to the supervised GUI matrix pass.\n'
else
  run_app_check .build/debug/continuum-revived --terminal-tmux-live-integration-check
  run_app_check .build/debug/continuum-revived --terminal-theme-fidelity-check
  run_app_check .build/debug/continuum-revived --terminal-snapshot-tier-check
  run_app_check .build/debug/continuum-revived --terminal-fills-tile-check
  run_app_check .build/debug/continuum-revived --session-resume-check
fi
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

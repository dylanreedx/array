#!/usr/bin/env bash
set -euo pipefail

"$(dirname "$0")/check-agent-tile-ux-program.sh" --check
"$(dirname "$0")/check-sidebar-native-ux-program.sh" --check
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
# Program 91 setup: keep the 50-ticket agent-tile queue, dependency order,
# packet structure, ledger rows, and supervised review gates from drifting.
run scripts/check-agent-tile-ux-program.sh
run scripts/check-sidebar-native-ux-program.sh
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
# Ticket 91/P0.2: the semantic agent-content module's own leg. It links
# AgentContent alone, so it proves the dependency direction the same way the
# AgentUI leg does, and it scans the module's sources and both manifest target
# blocks so a forbidden import or declared dependency is red before it is ever
# used. Fast and pure: no app bundle, no display, no provider process.
run swift run ContinuumRevivedAgentContentChecks
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
run_app_check .build/debug/Array --companion-sync-health-check
run_app_check .build/debug/Array --push-payload-dump-check
run_app_check .build/debug/Array --palette-duplicate-root-check
run_app_check .build/debug/Array --palette-first-responder-restore-check
run_app_check .build/debug/Array --settings-panel-check
run_app_check .build/debug/Array --onboarding-panel-check
# Channel split: the bare binary must resolve the DEV store ("Array Dev").
run_app_check .build/debug/Array --app-support-channel-check
if [[ "${CONTINUUM_SKIP_UI_BASELINES:-0}" == "1" ]]; then
  printf '\n==> SKIPPED (display-dependent, CONTINUUM_SKIP_UI_BASELINES=1): --component-lab-check — baseline comparison deferred to a supervised Retina-Main visual gate.\n'
else
  run_app_check .build/debug/Array --component-lab-check
fi
# Ticket P0.2: the UIProbe substrate every later phase-0 gate layers on — asserts a
# component really renders at the requested size in the requested NSAppearance, and
# that .aqua vs .darkAqua produce different pixels.
run_app_check .build/debug/Array --ui-probe-check
# Ticket P0.3: geometry gates over the probed managed-agent tile — width-fill ratios,
# card/model parity, no zero-size or ambiguous views, no clipping at the tile minimum
# width, and a non-vacuous scrolled-to-bottom assertion, in both appearances.
run_app_check .build/debug/Array --ui-geometry-check
# Ticket P0.4, wired by P1.6: WCAG contrast over the REAL view tree in both
# appearances — every text/background and border/fill pair the lab surfaces render.
# Built in P0.4 and deliberately left unwired: it was red on 177 of 446 pairs while
# the app still painted literals. P1.10/P1.11 adopted the tokens (177 -> 78 -> 11)
# and P1.6 closed the last 11, so it is a gate now. There is no allowlist and no
# exemption: a failing pair means the colour is wrong.
run_app_check .build/debug/Array --ui-contrast-check
# Ticket P0.5: numeric pixel probes over the probed managed-agent tile — a label's
# rect must be modulated (text that never drew is flat) and a border band must
# differ from the fill inside it, in both appearances. Flatness only; WCAG ratios
# are --ui-contrast-check's business.
run_app_check .build/debug/Array --ui-pixel-check
# Ticket P0.6: committed PNG baselines for every static Component Lab card in both
# appearances. Catches regressions nobody wrote an assertion for; blessing is
# explicit (CONTINUUM_UPDATE_BASELINES=1 ./scripts/run-matrix.sh) and never implicit.
if [[ "${CONTINUUM_SKIP_UI_BASELINES:-0}" == "1" ]]; then
  printf '\n==> SKIPPED (display-dependent, CONTINUUM_SKIP_UI_BASELINES=1): --ui-baseline-check — baseline comparison deferred to a supervised Retina-Main visual gate.\n'
else
  run_app_check .build/debug/Array --ui-baseline-check
fi
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
run_app_check .build/debug/Array --ui-tour-check || ui_tour_status=$?
if [[ "$ui_tour_status" -ne 0 ]]; then
  printf '\nrun-matrix: WARNING — the advisory UI tour exited %d (see above). It does NOT gate the matrix; the deterministic UI gates are --ui-probe/geometry/pixel/baseline-check.\n' "$ui_tour_status"
fi
run_app_check .build/debug/Array --ui-test-support-check
# Ticket P2A.3: the supervisor owns the runners, not the tile — a scripted runner
# (no Pi, no network) fans one agent's event sequence out to two live subscribers
# and one late one, stop terminates a blocked runner, and the record persists.
# Also source-scans Sources/ContinuumRevived so no view can construct its own
# PiAgentRunner and become a second owner.
run_app_check .build/debug/Array --agent-supervisor-check
# P2A.7: agents persisted by a previous launch are adopted at boot — idle, with
# their identity/model/role intact, the tiled one re-resolved from its tileId and
# carrying a previous-session notice — and a prompt is what starts them again.
run_app_check .build/debug/Array --agent-restore-check
# P2D.6: selecting N queue rows starts one isolated agent per row. Three rows in a
# real temp repo get three worktrees, three branches and their own prompts;
# completing one checks off exactly its row; six items past the cap start four and
# report the two deferred; a repeat is refused; and the item→agent mapping survives
# a second supervisor built over the same store.
run_app_check .build/debug/Array --agent-fanout-check
# P2B.2: the inbox lists agents from EVERY project. Two temp project roots hold a
# legacy managed-session record each and a third registry entry points at a root
# that is gone; `currentManagedAgentActivities()` publishes both with no canvas
# and no workspace runtime (observer-independence, P2B.8).
run_app_check .build/debug/Array --cross-project-agents-check
# P2B.4: the sidebar tree, the canvas tile badge + zone rollup, the dock attention
# count and the companion payload all read ONE `ActivityLogSnapshot`. Five agents
# across two projects (one managed, one headless, one shell that is not an agent)
# agree after a single `applyObserverStatuses`, and a flipped status moves all four.
run_app_check .build/debug/Array --agent-inventory-wiring-check
# P2B.6: the canvas sweep never erases a badge it has no entry for. A managed tile
# with a live view and nothing on disk keeps the status its own ingest set across
# two observer sweeps; an entry that says `idle` still clears a terminal's badge.
run_app_check .build/debug/Array --observer-sweep-badge-check
# P2B.7: an agent's own event folds into the held snapshot with no disk read — the
# fixture is DELETED from disk before the event is fed, and the bystander agent
# survives untouched — while the change-set names exactly the agents that moved.
run_app_check .build/debug/Array --agent-incremental-refresh-check
# P2B.8: with no ZoneRuntimeController and no canvas, every agent is still listed
# from disk with its persisted status and marked as unobserved; a live view or
# observer status overrides the file and clears the mark.
run_app_check .build/debug/Array --agent-observer-independence-check
run_app_check .build/debug/Array --keybind-edit-check
run_app_check .build/debug/Array --browser-url-focus-check
run_app_check .build/debug/Array --browser-ui-delegate-check
run_app_check .build/debug/Array --browser-element-context-check
run_app_check .build/debug/Array --browser-target-blank-check
run_app_check .build/debug/Array --browser-download-check
run_app_check .build/debug/Array --browser-auth-challenge-check
run_app_check .build/debug/Array --palette-browser-spawn-check
run_app_check .build/debug/Array --spawn-focus-policy-check
run_app_check .build/debug/Array --focus-broker-activation-check
run_app_check .build/debug/Array --nav-mode-check
run_app_check .build/debug/Array --leader-activation-check
run_app_check .build/debug/Array --leader-jump-check
run_app_check .build/debug/Array --leader-zone-jump-check
run_app_check .build/debug/Array --palette-jump-check
run_app_check .build/debug/Array --palette-zone-check
run_app_check .build/debug/Array --leader-snap-check
run_app_check .build/debug/Array --palette-captures-keys-over-browser-check
run_app_check .build/debug/Array --zindex-relaunch-hit-test-check
run_app_check .build/debug/Array --single-zone-compat-check
run_app_check .build/debug/Array --unified-model-boot-check
run_app_check .build/debug/Array --workspace-boot-persistence-check
run_app_check .build/debug/Array --zone-move-unified-check
run_app_check .build/debug/Array --multi-zone-render-check
run_app_check .build/debug/Array --zone-create-gesture-check
run_app_check .build/debug/Array --zone-autoname-check
run_app_check .build/debug/Array --zone-rename-inline-check
run_app_check .build/debug/Array --zone-create-encloses-check
run_app_check .build/debug/Array --zone-breakout-check
run_app_check .build/debug/Array --zone-close-keep-delete-check
run_app_check .build/debug/Array --zone-chrome-zorder-check
run_app_check .build/debug/Array --zone-resize-check
run_app_check .build/debug/Array --zone-adaptive-bounds-check
run_app_check .build/debug/Array --agent-status-check
run_app_check .build/debug/Array --tile-world-bounds-check
run_app_check .build/debug/Array --tile-drag-grab-check
run_app_check .build/debug/Array --tile-chrome-scale-check
run_app_check .build/debug/Array --resize-dimensions-hud-check
run_app_check .build/debug/Array --bring-to-front-focus-check
run_app_check .build/debug/Array --note-click-focus-check
# P5.5 correction: the same click-focus contract for the v2 agent composer — the
# broker steal, an editor-glyph click, and a padding-ring click all land in the editor.
run_app_check .build/debug/Array --agent-tile-click-focus-check
# Queue 91 P3.7/P3.S1: the real Home action policy rejects file, missing,
# non-file, and stale registered roots without mutating the agent; the native
# menu switches from Change Home to New Agent Here after work/history exists.
run_app_check .build/debug/Array --location-action-surface-check
run_app_check .build/debug/Array --focus-scope-dispatch-check
run_app_check .build/debug/Array --reserved-dispatch-check
run_app_check .build/debug/Array --tile-action-check
run_app_check .build/debug/Array --input-gate-check
run_app_check .build/debug/Array --drag-magnetize-check
run_app_check .build/debug/Array --resize-snap-check
run_app_check .build/debug/Array --browser-note-action-check
run_app_check .build/debug/Array --focus-border-check
run_app_check .build/debug/Array --browser-restore-state-check
run_app_check .build/debug/Array --browser-inspector-tile-shell-check
run_app_check .build/debug/Array --browser-inspector-dom-tree-check
run_app_check .build/debug/Array --browser-inspector-console-check
run_app_check .build/debug/Array --browser-inspector-styles-check
run_app_check .build/debug/Array --browser-inspector-network-lite-check
run_app_check .build/debug/Array --browser-inspector-link-lifecycle-check
run_app_check .build/debug/Array --browser-inspector-actions-check
run_app_check .build/debug/Array --agent-inbox-check
# Queue 94 P0.2: offscreen sidebar probe — per-label drawable-vs-needed width at
# 220/280/320 pt in both appearances, materialized before rows are applied.
run_app_check .build/debug/Array --sidebar-ux-check
run_app_check .build/debug/Array --workspace-sidebar-shell-check
run_app_check .build/debug/Array --workspace-sidebar-default-visible-check
run_app_check .build/debug/Array --workspace-sidebar-actions-check
run_app_check .build/debug/Array --workspace-sidebar-live-status-check
run_app_check .build/debug/Array --workspace-top-bar-check
run_app_check .build/debug/Array --browser-profile-persistence-check
run_app_check .build/debug/Array --note-file-tile-spawn-check
run_app_check .build/debug/Array --run-artifacts-tile-check
run_app_check .build/debug/Array --zone-hydration-lifecycle-check
run_app_check .build/debug/Array --zone-save-isolation-check
run_app_check .build/debug/Array --zone-project-session-naming-check
run_app_check .build/debug/Array --zone-lazy-resume-check
run_app_check .build/debug/Array --zone-registry-refcount-check
run_app_check .build/debug/Array --agent-message-bus-check
run_app_check .build/debug/Array --workspace-runtime-install-check
run_app_check .build/debug/Array --workspace-switch-check
run_app_check .build/debug/Array --workspace-profile-check
run_app_check .build/debug/Array --add-zone-check
run_app_check .build/debug/Array --browser-lru-budget-check
run_app_check .build/debug/Array --zone-tier-transition-check
run_app_check .build/debug/Array --spawn-placement-check
run_app_check .build/debug/Array --focus-mode-check
run_app_check .build/debug/Array --spawn-rate-limit-check
run_app_check .build/debug/Array --file-tree-boot-persistence-check
run_app_check .build/debug/Array --persistence-crash-safe-check
run_app_check .build/debug/Array --ticket-queue-tile-check
run_app_check .build/debug/Array --conductor-queue-tile-check
run_app_check .build/debug/Array --agent-input-check
run_app_check .build/debug/Array --diff-tile-check
run_app_check .build/debug/Array --file-tree-hardening-check
run_app_check .build/debug/Array --viewport-sanitize-check
run_app_check .build/debug/Array --project-lock-check
run_app_check .build/debug/Array --project-root-resolution-check
run_app_check .build/debug/Array --project-picker-resolution-check
run_app_check .build/debug/Array --topology-migration-check
run_app_check .build/debug/Array --terminal-tmux-persistence-check
run_app_check .build/debug/Array --new-tile-cwd-check
run_app_check .build/debug/Array --terminal-tmux-delete-lifecycle-check
run_app_check .build/debug/Array --terminal-tmux-ambient-workspace-check
run_app_check .build/debug/Array --session-observer-check
run_app_check .build/debug/Array --terminal-tmux-observer-check
run_app_check .build/debug/Array --terminal-tmux-observer-wiring-check
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
  run_app_check .build/debug/Array --terminal-tmux-live-integration-check
  run_app_check .build/debug/Array --terminal-theme-fidelity-check
  run_app_check .build/debug/Array --terminal-snapshot-tier-check
  run_app_check .build/debug/Array --terminal-fills-tile-check
  run_app_check .build/debug/Array --session-resume-check
fi
run_app_check .build/debug/Array --stray-window-audit-check
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

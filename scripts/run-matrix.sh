#!/usr/bin/env bash
set -euo pipefail

"$(dirname "$0")/check-agent-tile-ux-program.sh" --check
"$(dirname "$0")/check-sidebar-native-ux-program.sh" --check
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

# AGENTS.md, "Never touch the live tmux server from automated checks": several
# legs drive a REAL tmux server. On the DEFAULT socket that is the one hosting a
# running Array's terminal tiles, and pulling its sessions kills those tiles,
# which closes the last window, which quits the app — a clean exit with no crash
# report, indistinguishable from a crash. That happened twice on 2026-08-12.
#
# Give the whole matrix a disposable socket namespace of its own, exported before
# any leg runs so every child inherits it, and drop an inherited client env so a
# run started from inside tmux cannot be mistaken for the isolated server. The
# CoreChecks section fails closed without this, so it also keeps that coverage.
MATRIX_TMUX_TMPDIR=$(mktemp -d /tmp/array-matrix-tmux.XXXXXX)
export TMUX_TMPDIR="$MATRIX_TMUX_TMPDIR"
unset TMUX TMUX_PANE
trap 'rm -rf "$MATRIX_TMUX_TMPDIR"' EXIT

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

# A non-app leg (checks executable or hygiene script) that must NOT abort the run.
# Builds keep using `run`, because a failed build makes every later result
# meaningless — but one red checks executable must not hide the other seventeen.
run_leg() {
  local status
  printf '\n==> %s\n' "$*"
  set +e
  "$@"
  status=$?
  set -e
  matrix_classify "$(matrix_leg_name "$@")" "$status"
}

# Legs documented as KNOWN-RED in docs/38-tickets/95-go-live.md and the dogfood
# playbook. They are EXPECTED to fail; anything else failing is a regression.
#
# Why this list exists: the app legs used to be bare calls under `set -e`, so the
# FIRST known-red aborted the run. On 2026-08-12 that meant a real
# `scripts/run-matrix.sh` reached 4 of 135 app legs — everything past
# `--palette-first-responder-restore-check` was dead code, which is how
# `--composer-image-components-check` sat in this file failing from the day it was
# written without anyone noticing. Two documented reds must cost two results, not
# a hundred and thirty.
MATRIX_KNOWN_RED=(
  --component-lab-check
  --ui-baseline-check
  --agent-supervisor-check
  --nav-mode-check
  --palette-first-responder-restore-check
  # RE-RED on 2026-08-14, and it is the witness that changed, not the code. This
  # leg went green when the content inset stopped reflowing tile bodies, and Dylan
  # then reported that a real pinch over 9 live tiles still felt choppy while
  # panning felt great. He was right and the scenario was wrong: it drives
  # setViewport + layoutSubtreeIfNeeded on a headless harness, so it measures
  # LAYOUT and never rasterizes — but a zoom changes SCALE, and re-rendering
  # layer-backed content at the new scale is the cost that dominates. A 30-second
  # sample of the real gesture put ~2,600 samples in CA::Layer::display_if_needed
  # and ~960 in the forced subtree layout beneath it, against ~380 in the camera.
  # The scenario now counts chrome redraw invalidations, which pan scores 0 on and
  # zoom scores 1,392 on against a bucket-shaped bound of 192. Quantising the
  # chrome floor into 1/8 scale buckets takes it to 132 (measured, not committed —
  # it is product-visible). That only addresses chrome; the content rasterization
  # is Slice 5's semantic-zoom work. Published in
  # docs/internals/performance-budgets.md; do NOT bisect it as a regression.
  --perf-budget-zoom-check
  # The diagnosis behind the zoom leg above, published RED as its own product
  # target: a camera gesture may cost each tile about one settling layout, never
  # one per step. Its OTHER conditions are green and are the attribution — a
  # bounds-origin step, a bounds-size step, and the whole production camera path
  # minus the zoom branch all cost zero tile layouts. Goes green when the chrome
  # floor stops changing on every zoom step.
  --canvas-zoom-invalidation-probe-check
  # The streaming axis's product target. Still RED, but NOT for the reason it was
  # published: the incremental row index (.plans/22 Slice 4) took the delta from
  # 10,000 block visits to 1, with fullFlattens 0 and slope 0, and the wall clock
  # did not move — exactly the pattern the retained world plane hit one axis over.
  # Every COUNT budget is green; only worstDeltaDuration is over. A profile puts
  # the remaining 36 ms in two other per-delta O(history) passes that the row
  # index never touched: prepareToolDetailLifecycle rebuilding a dictionary over
  # every entry (~35%), and applyUnscrolled's presentation passes — the rowsByID
  # rebuild, the snapshot append, the role-change scan (~56%). Both are named in
  # Slice 4 and neither is started. Published in
  # docs/internals/performance-budgets.md; do NOT bisect it as a regression.
  --perf-budget-transcript-delta-check
  # Inherited reds, not independent ones. `ContinuumRevivedPaletteChecks` prints
  # its own model assertions and THEN shells out to the app's
  # --palette-first-responder-restore-check, so it cannot be green while that
  # leg is red. `check-root-docs.sh` demands 9 README markers from the
  # pre-65d420a doc taxonomy, one of which ("Continuum Revived") now
  # contradicts the user-visible-identity rule. Both must leave this list the
  # moment their cause is fixed — the report calls out an entry that passes.
  "swift run ContinuumRevivedPaletteChecks"
  scripts/check-root-docs.sh
)
# Advisory legs whose status the caller captures itself (`|| var=$?`); these must
# keep returning their real status or that handling silently stops working.
MATRIX_ADVISORY=(
  --ui-tour-check
)
MATRIX_UNEXPECTED_FAILURES=()
MATRIX_KNOWN_RED_OBSERVED=()
MATRIX_KNOWN_RED_UNEXPECTED_PASS=()
MATRIX_LEGS_RUN=0

matrix_leg_name() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --*-check) printf '%s' "$arg"; return 0 ;;
    esac
  done
  printf '%s' "$*"
}

matrix_list_contains() {
  local needle=$1; shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

# Records one leg's outcome and returns 0 so the run continues. The ONLY exception
# is an advisory leg, whose real status its caller captures itself.
matrix_classify() {
  local leg=$1 status=$2
  MATRIX_LEGS_RUN=$((MATRIX_LEGS_RUN + 1))

  if matrix_list_contains "$leg" "${MATRIX_ADVISORY[@]}"; then
    return "$status"
  fi

  if matrix_list_contains "$leg" "${MATRIX_KNOWN_RED[@]}"; then
    if [[ $status -ne 0 ]]; then
      MATRIX_KNOWN_RED_OBSERVED+=("$leg")
      printf 'KNOWN-RED (documented, expected): %s exited %d — continuing.\n' "$leg" "$status"
    else
      MATRIX_KNOWN_RED_UNEXPECTED_PASS+=("$leg")
      printf 'KNOWN-RED PASSED: %s — the allowlist in this script is stale.\n' "$leg"
    fi
    return 0
  fi

  if [[ $status -ne 0 ]]; then
    MATRIX_UNEXPECTED_FAILURES+=("$leg")
    printf 'FAILED: %s exited %d — recorded; the matrix continues so one regression cannot hide the rest.\n' \
      "$leg" "$status"
  fi
  return 0
}

# Prints the verdict and decides the exit code. Known-reds are reported apart from
# regressions, and a known-red that PASSES is called out too — a stale allowlist
# silently re-hides whatever it still covers.
matrix_report() {
  local label=$1
  printf '\n---- %s: %d leg(s) run ----\n' "$label" "$MATRIX_LEGS_RUN"

  if [[ ${#MATRIX_KNOWN_RED_OBSERVED[@]} -gt 0 ]]; then
    printf 'KNOWN-RED, expected (%d): %s\n' \
      "${#MATRIX_KNOWN_RED_OBSERVED[@]}" "${MATRIX_KNOWN_RED_OBSERVED[*]}"
  fi

  if [[ ${#MATRIX_KNOWN_RED_UNEXPECTED_PASS[@]} -gt 0 ]]; then
    printf 'KNOWN-RED that PASSED — remove from MATRIX_KNOWN_RED in this script (%d): %s\n' \
      "${#MATRIX_KNOWN_RED_UNEXPECTED_PASS[@]}" "${MATRIX_KNOWN_RED_UNEXPECTED_PASS[*]}"
  fi

  if [[ ${#MATRIX_UNEXPECTED_FAILURES[@]} -gt 0 ]]; then
    printf 'FAILED (%d):\n' "${#MATRIX_UNEXPECTED_FAILURES[@]}"
    local leg
    for leg in "${MATRIX_UNEXPECTED_FAILURES[@]}"; do
      printf '  - %s\n' "$leg"
    done
    printf '\n%s FAILED: %d leg(s) regressed. Their output is above, in order.\n' \
      "$label" "${#MATRIX_UNEXPECTED_FAILURES[@]}"
    return 1
  fi

  printf '\n%s passed.\n' "$label"
  return 0
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

  matrix_classify "$(matrix_leg_name "$@")" "$status"
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
run_leg scripts/check-matrix-inventory.sh
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
run_leg scripts/check-color-hygiene.sh
run swift build
run_ios_build
run_leg swift run ContinuumRevivedCoreChecks
# Ticket P1.1: the shared agent-UI module's own leg. It links AgentUI alone, so
# it also proves the dependency direction — a token that reaches back into Core
# cannot compile here. StatusChip's assertions moved here from
# ContinuumRevivedCoreChecks unchanged.
run_leg swift run ContinuumRevivedAgentUIChecks
# Ticket 91/P0.2: the semantic agent-content module's own leg. It links
# AgentContent alone, so it proves the dependency direction the same way the
# AgentUI leg does, and it scans the module's sources and both manifest target
# blocks so a forbidden import or declared dependency is red before it is ever
# used. Fast and pure: no app bundle, no display, no provider process.
run_leg swift run ContinuumRevivedAgentContentChecks
run_leg swift run ContinuumRevivedSyncChecks
# Ticket 86 (D4-R1): relay hub core — auth/scope, lossless catch-up, I5 gate.
run_leg swift run ContinuumRevivedRelayChecks
# Ticket 57: gated real-CloudKit backend leg. Skips gracefully (exit 0,
# cloudkit_available=false in the manifest) unless CLOUDKIT_ENABLED=1 is set
# — never set in this matrix; the real leg is device-gate-owed. Explicitly
# forced to 0 here (round-3 reviewer concern #3) so this invocation can never
# accidentally go live against a real, unentitled CKContainer just because
# CLOUDKIT_ENABLED=1 happens to be exported in the ambient shell environment
# the matrix runs in.
CLOUDKIT_ENABLED=0 run swift run ContinuumRevivedSyncIntegrationChecks
run_leg swift run ContinuumRevivedPaletteChecks
run_leg swift run ContinuumRevivedFileTreeChecks
run_leg swift run ContinuumRevivedPerfChecks
run_app_check .build/debug/Array --companion-sync-health-check
run_app_check .build/debug/Array --push-payload-dump-check
run_app_check .build/debug/Array --palette-duplicate-root-check
# Ordered HERE, ahead of the KNOWN-RED restore leg below: this script is
# `set -euo pipefail` with bare calls, so it aborts at the first red leg and
# everything after it never runs. A witness the gate cannot reach never runs at all.
run_app_check .build/debug/Array --strict-agent-harness-check
run_app_check .build/debug/Array --managed-agent-model-spawn-check
run_app_check .build/debug/Array --palette-first-responder-restore-check
run_app_check .build/debug/Array --settings-panel-check
run_app_check .build/debug/Array --onboarding-panel-check
run_app_check .build/debug/Array --provider-model-picker-check
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
run_app_check .build/debug/Array --agent-display-name-check
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
run_app_check .build/debug/Array --tile-reveal-work-check
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
run_app_check .build/debug/Array --camera-chrome-redraw-check
run_app_check .build/debug/Array --resize-dimensions-hud-check
run_app_check .build/debug/Array --bring-to-front-focus-check
run_app_check .build/debug/Array --note-click-focus-check
# P5.5 correction: the same click-focus contract for the v2 agent composer — the
# broker steal, an editor-glyph click, and a padding-ring click all land in the editor.
run_app_check .build/debug/Array --agent-tile-click-focus-check
# The composer's paste/drop intake: image decoding, thumbnail cache, attachment
# rail, cross-agent rebind isolation, and the shared mixed image/file-reference
# route through the real managed attachment store. It shipped with 44fbe73 but
# was never wired here, so a full matrix went green over a red witness.
run_app_check .build/debug/Array --composer-image-components-check
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
# .plans/15: opening a project file resolves the ACTIVE project/zone at invocation
# time. Before the repair, an open after an in-process workspace switch installed
# into the departed zone's model and persisted through the boot project's store.
run_app_check .build/debug/Array --file-open-active-context-check
# .plans/15: a .md/.markdown tile renders natively and keeps a Preview/Source
# switch; every other file keeps the monospaced horizontally scrolling source view.
run_app_check .build/debug/Array --file-markdown-preview-check
# .plans/15: an explicit local-file link in an agent's answer opens beside that
# agent, resolved against ITS checkout — and cannot reach outside it.
run_app_check .build/debug/Array --agent-local-file-link-check
# .plans/15: one AppKit view per semantic block is ruinous for a big file — 546 KB
# of Markdown built 12,000 TextKit stacks, 1.39 GB resident, and the process died.
# Preview is budgeted and says where it stopped, and a relayout re-measures nothing.
run_app_check .build/debug/Array --file-markdown-perf-check
# Standing performance budgets (docs/internals/performance-budgets.md). The pan
# leg gates: a camera pan must cost no bounds write, no tile-model write and no
# text re-measurement, over a canvas of large Markdown tiles. The zoom leg is
# KNOWN-RED on purpose — its number is published every run so the gap stays
# visible while the camera still resizes tile views.
run_app_check .build/debug/Array --perf-budget-check --scenario canvas.pan
run_app_check .build/debug/Array --perf-budget-zoom-check
# The fractional-pan leg gates the float-tolerance trap: AppKit keeps the
# bounds/frame SCALE and recomputes bounds from it, so at any zoom != 1 an
# exact "skip unchanged writes" compare reads 420 back as 420.00000000000006
# and rewrites every tile's bounds on every step — worse than no guard at all.
# The zoom-1 pan leg above is structurally blind to that defect; this leg pans
# the same fixture at zoom 0.35 and must stay at zero bounds writes.
run_app_check .build/debug/Array --perf-budget-check --scenario canvas.fractional-pan
# The camera COMPLEXITY witness, KNOWN-RED on purpose and for the same
# architectural reason as the zoom leg: it sweeps installed tiles 16→128 with the
# visible count held fixed, and today every installed tile takes a frame write on
# every camera step, so the work grows with tiles the user cannot see. It goes
# green with the retained world plane (.plans/22 Slice 3), which is also when both
# it and --perf-budget-zoom-check leave MATRIX_KNOWN_RED.
run_app_check .build/debug/Array --perf-budget-camera-slope-check
# The STREAMING axis of the scalability contract, KNOWN-RED on purpose and for
# the same shape of reason as the camera legs: the cost driver is history length,
# so a fixture that never varies it can sit green while a delta is linear in the
# conversation. apply(document:patch:) receives a real AgentDocumentPatch naming
# the changed nodes and then calls flatten(document) anyway, walking every entry
# and every block — measured at 10,000 nodes and 36 ms for ONE revised tail row
# on a 10,000-row transcript, while the same run reports it invalidated exactly
# 1 top-level row. The locality is already known and thrown away. Goes green with
# .plans/22 Slice 4, which is also when it leaves MATRIX_KNOWN_RED.
run_app_check .build/debug/Array --perf-budget-transcript-delta-check
# WHY a zoom lays out every tile when a pan lays out none. Both gestures move the
# same single ancestor through the same setViewport funnel, so the difference had
# to be isolated rather than assumed — and the standing hypothesis, that AppKit
# treats the plane's bounds-SIZE change as a resize and propagates needsLayout,
# turned out to be wrong. Measured: bounds-origin 0 passes, bounds-SIZE 0 passes,
# the whole production camera path minus the zoom branch 0 passes, the production
# ZOOM 696 over 60 steps on 12 tiles. The cost is entirely refreshZoomDependentChrome,
# which is our own per-tile-per-step call, not the camera mechanism. KNOWN-RED
# against that product target until the chrome floor stops moving every step.
run_app_check .build/debug/Array --canvas-zoom-invalidation-probe-check
# The Slice 2 contract (.plans/22): N input events inside one display interval
# cause a bounded number of camera commits and preserve the final desired
# viewport. The control condition drives 6 direct setViewport calls and must
# count 6 applies (the counter cannot go blind); the driven condition sends 6
# precise scroll events through the REAL scrollWheel handler with the driver's
# clock frozen and must land at most 2 (leading-edge apply + one coalesced
# flush). Before CanvasCameraDriver, the driven condition measured 6.
run_app_check .build/debug/Array --canvas-camera-coalesce-check
# The pinch glide's mechanics, on deterministic time: a flick above the engage
# threshold glides and terminates on its own; a deliberate stop stays dead; a
# new pinch or an EXTERNAL viewport write (navigation snap, pointer drag)
# cancels the glide; the zoom clamp stops it in ~2 steps where decay alone
# would take ~45; and pan input COMPOSES with a live glide in ONE commit —
# the property whose absence was the zoom→pan transition lag.
run_app_check .build/debug/Array --canvas-zoom-momentum-check
# The correctness oracle for the incremental row index, and the reason the cheap
# path is allowed to exist. transcript.delta measures what a delta COSTS and is
# structurally blind to a fast path that is cheap and WRONG — every count budget
# in it passes if the wrong row is rebuilt. This drives the real
# apply(document:patch:) funnel through local and structural mutations and, after
# each one, asserts the live index is indistinguishable from a from-scratch walk.
# It also asserts WHICH path ran, so the day the fast path declines everything the
# oracle fails instead of passing perfectly with the feature gone.
run_app_check .build/debug/Array --transcript-delta-index-oracle-check
# The camera's correctness oracle, recorded BEFORE the retained world plane so it
# can mean something afterwards: two independent mechanisms — the model
# (CanvasEngine over world rects) and the installed view geometry (front-to-back,
# through AppKit's own conversion) — must name the same tile at every point of a
# pan/zoom sweep, and paint order must follow the model's z-order. This is the
# gate that catches a plane whose transform is subtly wrong while the model stays
# right. GREEN today and must stay green.
run_app_check .build/debug/Array --canvas-camera-hit-oracle-check
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
run_app_check .build/debug/Array --terminal-tmux-no-mirror-check
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
run_leg scripts/check-root-docs.sh
run git diff --check

if [[ "$FAST" -eq 1 ]]; then
  matrix_report "Fast matrix"
else
  matrix_report "Matrix"
fi

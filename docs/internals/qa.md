# QA: the matrix, self-checks, witnesses

The culture in one line: **a change without a deterministic witness is not
verified.** RED before the fix, GREEN after, runnable offline.

## The layers

1. **Checks executables** — one SwiftPM target per leg
   (`ContinuumRevivedCoreChecks` is the big one; AgentUI/AgentContent/Sync/
   Relay/Palette/Perf/FileTree have their own so dependency direction is
   compile-enforced). Pure logic, fixtures, no display.
2. **App self-checks** — `--*-check` flags handled in `ContinuumApp.main()`
   before AppKit runs; each prints `…Checks passed` and exits. UI-level ones
   (settings panel, onboarding panel) drive real NSViews, assert behavior,
   render a non-blank snapshot, write a PNG artifact under `qa-runs/`, and
   leak-check their window.
3. **Bundle harness** — `scripts/check-app-bundle.sh`: assembles a bundle
   (dev channel default, `--channel prod` for releases), asserts identity +
   Sparkle embedding + rpath, runs the self-check legs against the bundled
   binary under isolated env, launch-smokes via LaunchServices, and
   pollution-guards the REAL app-support dirs and defaults plists (both
   channels).
4. **The matrix** — `scripts/run-matrix.sh` runs all of it, plus the iOS
   build of shared Core. `run_app_check` gives each app leg fresh
   `CONTINUUM_PROJECT_ROOT`/`CONTINUUM_APP_SUPPORT` temp dirs.

## Isolation rules

- Env overrides (`CONTINUUM_APP_SUPPORT`, isolated HOME) isolate files —
  but NOT the standard defaults domain (cfprefsd routes per-user). Channel
  identity and explicit `UserDefaults(suiteName:)` are the only prefs
  isolation.
- Anything that can present UI or touch the network at boot must be gated
  out of QA runs: the updater and onboarding gates are the pattern
  (`--` args, `CONTINUUM_*` env, bundle id).

## KNOWN-RED gates

Documented in `docs/38-tickets/95-go-live.md` (verified pre-existing at their
recorded HEAD): `--component-lab-check` pixel baselines (~36 stale, need a
supervised re-bless) and the `--agent-supervisor-check` naming-section timing
flake. Do not bisect them as regressions; do not add new known-reds without
recording bisect evidence the same way.

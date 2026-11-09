# Checks out of the release app: measured first slice

Base c476ced9; local branch array/checks-out-of-app. No push or landing.

## Change and remaining scope

SwiftPM defines ARRAY_CHECKS for debug. Ordinary release omits three pure-check
files and their six main() dispatch branches: TranscriptRhythmChecks (2,902
lines), AgentFirstPaintChecks (2,852), FileOpenChecks (1,992): 7,746 lines total.
Debug uses the identical witness bodies against the same production entry points.
Production implementations are unchanged. Explicit release witness builds can
opt in with -Xswiftc -DARRAY_CHECKS.

A compile-time flag avoids copying production code or expanding internal access
across a separate target. Full extraction was deliberately stopped at a small
slice: probe/lab code has production references (Component Lab uses
SidebarScreenshotChecks), and inline AppDelegate checks need separate boundaries.
TileSurfaceResidencyChecks also serves AppThemeChecks and
CanvasZoomInvalidationProbeChecks, so it remains compiled. Most of the estimated
100k lines and the main cascade remain. This is not completion of full gating.

Release rejects the six omitted flags through the existing unknown-check guard:
exit 1 before normal startup. Other existing checks remain available, including
the bundle verifier's eight checks. A made-up --unknown-witness-check also exits 1.

The release packaging lock's re-exec lost already-parsed arguments and failed
'--output <path> is required' before compilation. Preserving original argv fixes
that observed blocker. The same packaging command then succeeded.

## Measurements

Same machine, /usr/bin/time -p. Output ~/array-scratch/checks-out-of-app/{Before,After}.app.
Command scripts/make-app-bundle.sh --configuration release --channel prod --output <scratch>.

| Measurement | Before | After final slice |
|---|---:|---:|
| Release bundle build wall seconds | 1115.32 | 771.12 |
| Raw .build/release/Array bytes | 150802488 | 149747112 |
| One-comment edit in ContinuumApp.swift, incremental debug seconds | 36.41 | 57.43 |

Binary reduction: 1055376 bytes (about 1.01 MiB, 0.70%). No incremental debug
improvement demonstrated. Initial debug was 119.99s; candidate gated debug 86.05s.
A four-file candidate's incremental debug took 39.44s before narrowing scope.

These release times are NOT a controlled clean before/after comparison:
- Before was a fresh worktree with dependency resolution and no build products.
- Two unrelated Swift builds started during the baseline; Array and Chrome also
  consumed CPU. No matrix overlapped either release build.
- After removed release products but an unsuccessful compile warmed dependencies;
  final retry rebuilt the app with those dependencies retained.
A quiet-machine, equally clean comparison remains unverified; do not claim the
observed wall-time difference as a speedup attributable to this patch.

## Verification

- Final debug build: PASS; git diff --check: PASS.
- Ten targeted debug legs: 9 PASS. Rhythm, active-context file open, Markdown perf,
  local-file links, Markdown preview, gesture telemetry, first paint, workspace API
  open and app-support channel passed. Surface residency FAILED: 'flag off must
  still pay the native cascade — a gesture that laid nothing out was not a gesture'.
  Cause unresolved; its implementation is unchanged in the final patch.
- Final release build: PASS (771.12s).
- check-app-bundle.sh --configuration release --channel prod --bundle <After.app>:
  PASS, including signature verification, self-checks and LaunchServices probe.
- All six omitted flag strings have zero occurrences in release strings output;
  all six flag invocations and an unknown flag return 1 without booting.
- Overall strings search for '-check': 796 matching lines. Zero overall check
  strings is NOT achieved by this partial slice.
- Detached full matrix: PASS, 429 legs, 1821s (30m21s), zero unexpected failures.
  One expected KNOWN-RED: --empty-workspace-creation-check (palette omits the
  registered Beta project). All six gated branches explicitly PASS in its report.
  CoreChecks passed in 212s. Display baselines skipped as requested; surface
  residency was skipped too, so the targeted failure remains unresolved.
- Matrix notes: app-theme surface-cache witness and shared-agent baseline
  comparison skipped with display checks; iOS preview uses labeled fixture frames.

Full matrix invocation: env -u ARRAY_AGENT_ID -u TMUX -u TMUX_PANE TERM=xterm-256color
CONTINUUM_SKIP_UI_BASELINES=1 caffeinate -u -i scripts/run-matrix.sh </dev/null,
detached with a new session. CONTINUUM_ARRAY_MANAGED_AGENT was preserved. Matrix
verified its disposable tmux socket; targeted checks disabled tmux and isolated
project/app-support dirs. No default tmux socket or /Applications app was touched.

Two unsuccessful release attempts preceded the final build: missing residency
check dependencies (160.95s), then input modified during build (894.18s), caused
by removing the residency gates after the compiler started. The final build ran
with production sources unchanged throughout. These times are not after results.

Packaging performed its standard ad hoc signing. No Developer ID signing,
notarization, release assets, new verifier tooling, stash or git config changes.
Evidence is archived at ~/array-scratch/checks-out-of-app/evidence; the worktree
bench is returned after commits, leaving this local branch available for review.

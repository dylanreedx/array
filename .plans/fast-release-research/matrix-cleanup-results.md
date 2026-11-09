# Matrix cleanup result — 2026-11-07

Branch: `array/matrix-cleanup`, based on `origin/array/integration` at `d41dad04`.
Timed code revision: `e3c46da0`. Nothing pushed. No release build was run.

The complete matrix reported **428 legs in 1,694.27 seconds (28m14s)**, compared
with the supplied audit's **55–68 minutes**. That is roughly 49–58% less wall
time. This is one measured full run, not a green gate: **422 passed, 1 advisory
passed, 1 expected KNOWN-RED, 4 unexpected failures**. The process exited 1.

All **424 scheduled workers** reported, in addition to 4 common preflight legs.
All **83 awake commands** appear in the results in queue order. CoreChecks passed
in 211 seconds; navigation, both multiplayer journeys, live terminal checks,
character performance and the real dev-bundle probe passed. Mac debug and arm64
simulator builds passed. The full run printed no focus-theft failure and released
its shared lock afterward.

## Changes

Restored the bare CoreChecks run (observed size pin 1639 → 1636), removed its
blocking source scans and 49 duplicate default arms. Fixed zone search ranking
and stale navigation fixture setup/auto-layout assumptions. Retired nine
unreliable legs and the three program-pin scripts, plus the audited source-text
assertions. Film scenes are opt-in with `CONTINUUM_CHECK_FILM_SCENES=1`.
Inventory changes now report removals and additions.

Independent legs run up to six at a time here (default derived from core count;
`ARRAY_MATRIX_JOBS` overrides). Display/focus/performance/browser/terminal legs
run serially afterward. `--awake-only` and `--skip-awake` select the groups.
Builds and fixture assembly precede scheduled legs; checks use prebuilt binaries.
Logs and per-leg wall seconds are retained, with JSON `leg`, `status`, `seconds`.

The matrix holds an exclusive `fcntl.flock` on the **regular file**
`${ARRAY_MATRIX_LOCK:-/tmp/array-matrix.lock}` for the entire run, matching the
release-build guard's lock. A second matrix was observed refusing startup while
the detached run held it. Directory paths are refused. Awake preflight runs
before builds and again before the serial group. Real awake/unlocked state was
accepted; simulated locked, sleeping and missing-console states were refused by
the production preflight code. No display lock or sleep was induced on Dylan's Mac.

The simulator build uses `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`. `CLAUDE.md` (the
`AGENTS.md` symlink target) now describes proof during development, bug-class
nightly coverage, justified removals, production-path/outcome requirements, the
single remaining KNOWN-RED, runner modes, and measured 12–16 minute release builds.

## Remaining red

| Leg | Observed cause |
| --- | --- |
| CLI fixture hygiene | Installed Claude 2.1.319 has no committed context-meter capture. |
| `--managed-codex-launch-check` | Recorded free-mode argv differs from the fixture's hand-maintained `previousArguments`. |
| `--agent-presence-check` | Accepted Claude/Codex steers appear once in the rail and once in the transcript; reproduced in one isolated rerun. |
| `--agent-stop-outcome-check` | Stopping Pi before session persistence shows no discarded-conversation notice; reproduced in one isolated rerun. |
| `--empty-workspace-creation-check` (KNOWN-RED) | Empty-workspace palette omits the registered Beta project. |

The argv mismatch was not diagnosed beyond its failing contract; no product
regression is inferred solely from that assertion. The four unexpected failures
remain visible and were not added to KNOWN-RED.

## Verification and limits

The run was detached with Python `start_new_session`, `caffeinate -u -i`,
`CONTINUUM_SKIP_UI_BASELINES=1`, `TERM=xterm-256color`, null stdin, and
`ARRAY_AGENT_ID`, `TMUX`, `TMUX_PANE` removed. The managed-agent marker was not
overridden. Matrix tmux checks used the verified disposable namespace only.
Neither `/Applications/Array.app` nor `~/Desktop/Array Dev.app` was changed.

Targeted builds/checks covered CoreChecks, Array, PaletteChecks, SyncChecks and
AgentContentChecks; zone ranking was RED then GREEN. The navigation check is
GREEN in the actual full run. Runner smoke checks verified continue-on-red,
mode selection and multiple serial jobs after an stdin-reading child. Shell
syntax and diff hygiene passed. Bench inventory ran at pickup and completion.

An initial timing attempt ran only 347 legs because a child consumed the awake
queue's stdin. **Its 20m35s is invalid as a full-run timing.** Worker null stdin
and queued-versus-launched accounting fixed this, with a behavioral regression
probe, before the complete 428-leg run above.

UI cache/shared-agent baseline comparisons were skipped under the requested
baseline flag; no baseline was updated. The preview transport proof uses fixtures,
not a live simulator. The iOS result is a simulator compile, not device QA.

Evidence: `/Users/dylan/array-scratch/matrix-cleanup-evidence-20261107T160241Z/`.
`results/results.json` contains all 428 outcomes. `run.log`, `status.json`,
per-worker logs/status/timings, build logs, isolated reruns and runner smoke
results are retained there. The incomplete attempt is labeled separately.

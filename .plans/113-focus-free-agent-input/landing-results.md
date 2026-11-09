# Integration landing verification

Baseline: origin/array/integration c476ced9. Program source: array/pointer-isolation c115be79.

The debug build passed. The full matrix ran once under caffeinate -u and the noexc wrapper, with ARRAY_AGENT_ID unset, stdin closed, TERM=xterm-256color and CONTINUUM_SKIP_UI_BASELINES=1. The inherited managed-agent crash guard stayed intact. The matrix isolated tmux itself.

Full matrix: 441 legs, 432 pass, 1 advisory, 1 expected known-red, 7 failures; wall time 2725 seconds. Expected known-red: empty-workspace-creation (missing Beta palette fixture). Advisory: ui-tour. The matrix rebuilt checks products and its bundle leg passed. UI baseline comparisons were skipped as requested. Real-key/foreground proof was not authorized or run.

Failure classification and follow-up:

- CoreChecks: just-under-cap safe rows exceeded 100 ms (152 ms). Plain origin reproduced the same failure at 267 ms. Pre-existing; unchanged.
- browser-automation-engine: trusted keydown assertion inherited the new default. Made its Stage 1 mode explicit. Rebuilt; rerun passed. Plain origin also passed.
- workspace-api-browser: full run reported document epoch and unloaded-zone reload errors. Rerun under caffeinate passed all scenarios. Plain origin independently failed the hand-over sheet page/profile assertion. No product change made for these transient/pre-existing failures.
- perf-budget-transcript-delta: 9.6 ms against 8.3 ms in full run; failed on both plain origin and landing reruns. Pre-existing; unchanged.
- character-perf: idle/zoom layout/draw comparisons failed on both plain origin and landing reruns. Pre-existing; unchanged.
- terminal-tmux-ambient-workspace: malformed-pane compensation assertion raced Task.detached cleanup. Plain origin passed repeated runs, while landing failed reproducibly. Fixed the existing fake/witness to signal completion and wait at most one second before inspecting its log. Product behavior unchanged. Rebuilt; three reruns passed.
- terminal-tmux-live-integration: pane cwd failed to become changed; reproduced on both plain origin and landing in a private tmux namespace. Pre-existing; unchanged.

No failures were added to MATRIX_KNOWN_RED. Matrix conflicts retained integration's parallel/awake runner and the program's targeted modes and browser legs; regenerated its literal-invocation inventory. Default focus-free input enabled with existing availability-based Stage 1 fallback. Existing off-mode witnesses remain explicit.

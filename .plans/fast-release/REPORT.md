# Fast release integration

Branch `array/fast-release`, based on origin/array/integration `d41dad04` (0.7.44). No push or release.

Merged `array/matrix-cleanup` (73eaaf62) and `array/release-tip-channel`. The matrix and release builder now hold one exclusive regular-file flock at `${ARRAY_MATRIX_LOCK:-/tmp/array-matrix.lock}` for their process lifetimes. No duplicate process guard. `--update-channel-check` is registered in the independent group (it uses a private defaults suite and an inert updater).

## Baseline verdicts

All four failures predate this merge and were present in 0.7.44. The three Swift checks and relevant production files were compared with d41dad04 and were byte-identical before fixes; the merged baseline executable reproduced the two product failures and the Codex fixture failure. This was not a separate whole-repository build of d41dad04.

- Presence: product defect. Claude/Codex accepted steers appeared in both rail and transcript. Consumed steers now leave the rail synchronously before publishing the transcript, while durable receipt retirement continues asynchronously.
- Pi stop: product defect. Stop published interruption before the runner unwound and reported loss. Stop now publishes the loss notice before interruption, deduplicates the later unwind, and resets notice ownership for each new runner. Existing assistant/persistence watermark suppresses the warning. The production stop witness also asserts exactly one notice.
- Managed Codex launch: stale fixture. Commit f367cba5 deliberately added the result-delivery environment setting so a helper result has one delivery channel. Expected argv omitted ARRAY_WORKSPACE_RESULT_DELIVERY. Updated only the fixture to match that intended production contract.
- CLI hygiene: missing fixture. Captured installed Claude 2.1.319 through `scripts/capture-cli-fixtures.sh capture-model sonnet`; `capture-cli-fixtures.sh check` passes for Claude 2.1.319, Codex 0.165.0 and Pi 1.4.0. Raw captures use the script's scrubber.

## Execution notes

Only targeted checks; no full matrix. Commands remove ARRAY_AGENT_ID/TMUX/TMUX_PANE, use null stdin, TERM=xterm-256color, disposable TMUX_TMPDIR, isolated app support/project roots. No default tmux connection. Managed-agent marker retained.

Initial debug build failed because source was edited during compilation; restored baseline source and rebuilt successfully. Initial Codex attempts exposed missing array-workspace-mcp, then missing isolation; built the helper and reran under isolation to observe the actual `free argv changed` baseline failure. The initial release-lock probe omitted required --output and failed argument validation; corrected probe refused the held lock before invoking Swift. No release configuration build ran.

Lock contention probes and bash syntax passed. Full matrix intentionally left to lead. Bench inventory ran at pickup and completion; this bench is retained for the lead to land the committed branch.

## Final targeted results

PASS: `--agent-presence-check`, `--agent-stop-outcome-check`, `--managed-codex-launch-check`, `--update-channel-check`. See `fixed-results.json` and `fixed-*.log`. Baseline logs retain the corresponding red outcomes. CLI fixture hygiene, shell syntax, shared-lock contention and diff hygiene passed.

Preview rebuilt and launched with `scripts/dev-app.sh` after confirming no matrix process. Rendered Settings → General → Update channel in Neutral (dark) and Stone (light). ChoiceButton's type, right-edge alignment, corner shape and contrast match the Settings controls; no visual fix required. Captured only Dev window 629508, whose owner PID 46367 resolved to `~/Desktop/Array Dev.app`:

- `.plans/fast-release/update-channel-dark.png`
- `.plans/fast-release/update-channel-light.png`

System Events confused the duplicate Array process names; switched to verified Dev PID, activated via bundle path, and drove the visible Settings UI using native mouse/key events. Preview remains on its scratch root, showing General in the light appearance.

No remaining targeted red. Full matrix, release build, publishing and push deliberately not run.

# Session handoff verification — 2026-10-21

Review checkout: `.worktrees/session-handoff`, branch `array/session-handoff`,
starting at `0ee1b82b`. Integration remains at `77f1a237`. No commit, merge,
push, worktree removal or release is part of this review.

## Review follow-ups

Reviewed the ownership, transcript, Terminal-face lifecycle, shell `/exit`,
message-envelope and title-band fixes merged after `b05e5282` against the
17 findings saved by the Claude session. Five additional defects were found:

- **Adoption can outrun history.** Move here / Copy instead exposed sending
  before their background restore finished. Hold sends and face switches until
  the restore lands, seed the supervisor before its first own turn, and notify
  tiles opened during the read. `--external-session-move-check` now asserts the
  hold and history ordering for tiles opened during adoption and after sending.
  The new hold assertion failed on the previous implementation.
- **Direct forks were never found.** Without tmux, the face looked for a live
  status file naming its original session. Copy already has a new session by
  then. Resolve the process by its own agent/Terminal-face tags instead.
  `--agent-face-flip-check` now forks with and without tmux, checks adoption of
  the fork id, preservation of the source bytes, and one copy of its turns.
  The direct variant failed on the previous implementation with only the
  source id followed.
- **An ended nonresident face remained saved.** Clear its mounted/warm models
  and saved canvas metadata at face completion, under the owning controller
  or a temporary project lock, after draining queued canvas writes. Keep the
  supervisor hold until that completion has finished.
  `--agent-paused-elsewhere-check` now checks the saved tile of the other
  workspace after its face ends; that assertion failed before this fix.

- **The feature broke the iOS build.** The shared `ClaudeTerminalFace`
  exposed `PiAgentRunner.ResolvedCommand` and called the session reader's
  macOS-only local path locator. Guard those two local CLI entry points with
  `#if os(macOS)` while keeping the face state and pure helpers shared. The
  iOS gate reproduced both missing-symbol errors, then built successfully for
  the generic iOS Simulator after the guards.

- **Wrapped subagent chips opened no child.** Refreshing live status in the
  feature made delegation chips wrap, exposing pre-existing mixed hit-test
  coordinates in both the row and its buttons. A native press reached a
  different chip at a negative local y. Both now normalize AppKit's
  superview-coordinate point exactly once. The switch check now clicks three
  wrapped chips inside an offset row and asserts the corresponding child ids;
  its hit assertion was RED before the correction and the corrected check
  passed: three native clicks revealed the three expected child ids. Both full-day film scenes
  failed at picker adoption on the feature; the pre-feature full-day-v2 scene
  passed in full (350 seconds), proving a feature regression.

The face-flip fixture also needed to bring the intended tile to the front
before clicking: its overlapping equal-z tiles intermittently routed a click
to an earlier tile. Added failure diagnostics retain the actual face/watch ids.

## Verification

- Full `caffeinate -di scripts/run-matrix.sh`: **331 reported legs**,
  **316 passed, 12 documented KNOWN-RED, 3 initially unexpected failures**.
  The normal macOS build, generic iOS Simulator build, film build, inventory
  (669 records), colour hygiene, root docs and dev bundle validation passed.
- The film failure was the new wrapped-chip regression described above.
  After correction, `full-day.json` passed in full (225 s) and
  `full-day-v2.json` passed in full (333 s). The third scene using chip pointer
  targets (`v2-smoke-day.json`) passed on the final binary too (32 s). The
  other nine scenes passed in the matrix and contain no chip pointer actions.
- The switch leg was killed by signal 9 when the executable was replaced
  during a rebuild. The matrix was then stopped until builds completed.
  The corrected switch check passed independently, including 24 band
  configurations, cached band measurements, and three native wrapped-chip
  clicks. No debug instrumentation remains.
- The remaining unexpected gate is `scripts/capture-cli-fixtures.sh check`:
  captures are absent for installed Claude 2.1.306, Codex 0.163.0, Pi 1.3.0.
  The same check failed for the same missing files at pre-feature `77f1a237`.
  No captures were fabricated or model calls made to update them.
- Final changed-path rerun: switch, message cards, full face flip (tmux and
  direct forks), paused-elsewhere and Move here all passed. Shell handoff
  passed both independently and in the matrix. Discovery and agent-message
  transcript checks passed in the matrix. The standalone transcript
  rehydration check passed after rebuilding CoreChecks.
- The twelve documented reds were bare CoreChecks' canonical-byte baseline,
  component-lab, UI-baseline, nav-mode, empty-workspace-creation,
  palette-captures-keys-over-browser, note-click-focus, agent-tile-click-focus,
  perf-budget-zoom, file-tile-zoom, perf-budget-gesture-transition and
  perf-budget-magnify-slope. Their classifications were not changed.
- The real-model context-compaction check is opt-in and was not enabled.
  `git diff --check` passed. Bench inventory was rerun from the canonical
  checkout; benches were retained because this work has not been landed.

Every automated tmux verification used a disposable namespace with TMUX and
TMUX_PANE unset, and verified the private socket. App/project state was
isolated. The production Array process remained alive under its original pid.
No production app bundle was rebuilt or relaunched.

Intermediate build failures corrected: one build rejected a check source
modified while compiling; another caught private workspace-runtime access
from a separate extension. The first matrix halted at the macOS-only CLI type
in Core; a follow-up iOS build caught its local-path helper too. All subsequent
builds passed after those corrections. Existing Swift concurrency/deprecation
and libghostty missing-symbol warnings remain in build output.

Artifacts, exact commands and logs:
`qa-runs/2026-10-21-codex-handoff-review/` (ignored, disposable). The original
331-leg summary is retained verbatim in `matrix2.log`; its three historical
failures are not relabelled. Follow-up results are recorded separately in
`chip-green/results.jsonl` and `array-handoff-codex-final-films.jsonl`.

## Provider scope

The Terminal face is Claude-only. Codex discovery/restore remain present;
Codex has no per-process session-status file, so its Terminal switch remains
hidden. Codex pause history still has no own-turn mark and begins at discovery's
file offset; this is deferred under Dylan's original Codex-later scope.

## Compact Terminal toggle follow-up

Dylan requested a smaller, optional header control, visible by default with a
hide option. The paired Array / Terminal segments are replaced by one square
Terminal icon. Chat remains the starting face. The active icon returns to
chat; the pending icon cancels a waiting flip. Settings → Agents → Show
Terminal toggle updates existing tiles immediately and applies to newly opened
tiles. The menu, shortcut and accessibility action remain available when
hidden; an active Terminal face retains its return control.

Witnesses and preview:

- RED: `--agent-face-switch-check` rejected the old two-control header at
  320pt / normal zoom. A second RED rejected the missing Agents setting.
- GREEN: updated switch check clicks the same icon in both directions across
  24 width/canvas-zoom/page-zoom configurations, preserves the 22px hit floor,
  verifies hide/reopen/reset and the active return control, and measures zero
  new label measurements during zoom.
- The initial replacement run reached an obsolete end-of-check assertion
  expecting labels at 480/900pt. Updated that assertion to require one icon
  at all three normal widths; the final switch check passed.
- GREEN: face-flip (including clicking the pending toggle to cancel), tile
  chrome scaling, Settings modal, managed-agent page zoom and shell handoff.
- Visually inspected the 320pt and 480pt header PNGs from the final check.
- `scripts/dev-app.sh` rebuilt and launched the debug preview at
  `~/Desktop/Array Dev.app`, pinned to `~/array-scratch`. Its process survived
  the build shell. The production Array process remained alive.
- Follow-up full matrix log: `qa-runs/compact-face-toggle/matrix.log`.
  The final gate result is recorded below.

Logs for both REDs and the GREEN runs are under
`qa-runs/compact-face-toggle/`. No Git staging, commit, merge or push performed.

Follow-up gate observations:

- macOS and generic iOS Simulator builds passed. The film gate ran all twelve
  scenes: eleven passed, including both full-day scenes and the chip-pointer
  smoke-day scene. `v2-smoke/v2-smoke.json` failed at `99-open-beside` with
  `open placement: production presented no camera reveal (unavailable)`.
  An unchanged single-scene rerun failed identically. The same scene bytes
  against the previously built pre-feature `77f1a237` binary failed with the
  same assertion (`film-smoke-baseline.log`), establishing that this failure
  also exists before the handoff feature and compact toggle under the current
  host conditions. No scene expectations, API behavior or allowlists changed.

Final follow-up gate: **331 legs reported; 317 passed, 12 documented
KNOWN-RED, and 2 additional failures** (`scripts/check-film-scenes.sh` and
`scripts/capture-cli-fixtures.sh check`). The film failure reproduces at
pre-feature `77f1a237` as above; the missing captures are the same installed
Claude 2.1.306 / Codex 0.163.0 / Pi 1.3.0 fixtures already reproduced at that
baseline in the earlier review. All 280 app checks completed, with only the
documented app reds. Both compact-toggle witnesses passed inside the matrix,
as did Settings, UI geometry, page zoom, shell handoff, and bundle validation.
No new failure remains attributable to this UI change. The full gate remains
red for those existing issues; its allowlist and expectations are unchanged.

`git diff --check` and the final bench inventory passed/ran respectively.
The bench remains in place with uncommitted work; no Git mutation was requested.
The shared Desktop preview was overwritten by another build during the gate
(the replacement lacked the new setting); `scripts/dev-app.sh` was rerun after
verification to restore this tested handoff checkout on `~/array-scratch`.

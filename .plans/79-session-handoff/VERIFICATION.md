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

## Idle-session discovery and onboarding follow-up

Dylan requested findable idle sessions, onboarding for both existing-session
and new-session users, optional tmux, and an updated preview. Review started
from `452ef528`; this follow-up has not staged, committed, merged or pushed.

- Sidebar scopes now select location independently of activity. This workspace
  and project scopes retain their idle sessions; All agents and This Mac include
  all discovered sessions, including folders not registered as projects.
  Discovery still requires a live process: this does not add closed-session
  history to the sidebar.
- Getting Started adds “Open a Claude Code session in Array.” After discovery,
  it offers a chooser across this Mac (including idle sessions), plus a new
  Claude session action. With no existing sessions, Start opens a new owned
  Claude chat using the live catalogue. Choosing existing work opens the
  production read-only watch tile and explains Move here / Copy.
- The owned-session introduction offers the real Try Terminal action. Chat is
  still the initial face. Missing tmux is a neutral optional suggestion in
  environment setup, with an explanation that persistence across Array quits
  is its benefit; neither onboarding path requires it.

Verification:

- RED: the production sidebar witness rejected hidden idle sessions, and the
  onboarding witness rejected the missing Getting Started task.
- GREEN: sidebar location scopes and All agents; live discovery refresh;
  chooser entries for idle sessions in another workspace and an unregistered
  folder; cancelled folder consent; a selection that closed while the menu
  was open; opening the real watch tile; and creating exactly one Claude
  chat despite Pi being the ambient harness, with tmux disabled.
- GREEN: the introduction's real Try Terminal action mounts a Ghostty face
  with tmux disabled and returns to the same chat. Fresh-install, full face
  flip and face-switch checks also passed in focused runs.
- The deeper Terminal witness initially crashed because onboarding checks
  ran before global Ghostty initialization. Moved that check after the same
  bootstrap used by the face checks; the final onboarding, sidebar and
  fresh-install rerun passed. An earlier compile error from an omitted enum
  case was corrected before those runs.
- Rendered both empty and existing-session cards. Corrected button clipping
  by constraining the task stack and wrapping the title; final PNGs and native
  button-bounds assertions passed.
- `scripts/dev-app.sh` rebuilt and launched the debug Desktop preview on
  `~/array-scratch`; its process survived the launching shell. Native UI
  inspection found 13 open Claude sessions, including idle sessions, in the
  actual chooser alongside Start a new Claude Code session. Opened and
  dismissed the menu without selecting a real session. Production Array
  remained running under its original PID.
- In the full matrix, macOS and generic iOS Simulator builds passed. All twelve
  film scenes passed (995 s), including both full-day scenes and the smoke scene
  that failed in the preceding compact-toggle run. No film code or expectation
  changed in this follow-up.
- The matrix exposed an older core discovery assertion requiring idle sessions
  to be hidden. Updated it to require all six known busy/idle workspace rows,
  exclude the two outside-folder rows, and retain every row under All agents.
  Rebuilt only `ContinuumRevivedCoreChecks`, leaving the app executable unchanged.
  Discovery and onboarding-foundation checks both passed in the
  independent `discovery-green/` rerun. The original matrix failure remains in
  its log, rather than being relabelled as a pass.

Final gate: **331 legs reported; 317 passed, 12 documented KNOWN-RED, and 2
failures**, exit 1. The two failures were the old discovery assertion corrected
above and the same absent installed-CLI captures (Claude 2.1.306, Codex 0.163.0,
Pi 1.3.0) already reproduced at the pre-feature baseline in the earlier review.
All 280 app checks completed, including onboarding, the updated external-session
sidebar, face switch/flip, watch, Move here, shell handoff and fresh install,
with only the documented app reds. Dev bundle assembly, launch probe, signature
validation, root docs and `git diff --check` passed. No baseline or known-red
allowlist was changed. The full matrix was not repeated after the test-only
discovery assertion correction; its discovery and onboarding-foundation reruns
passed independently on the final checks executable.

Coverage limits: real-model context compaction was not opted into; remote-reach's
ssh-wrapped tmux attach backend skipped because there was no controlling terminal
for its pty; CloudKit integration skipped because CLOUDKIT_ENABLED was not set
and this dev bundle is unprovisioned. These are unrelated to the changed flows.

The final Desktop preview still contains both the new onboarding row and the
compact Terminal-toggle setting, and remained running as PID 85990. Production
Array remained PID 41344. The canonical checkout's final bench inventory reports
this bench as dirty and unlanded; it was retained. Changes remain unstaged and
uncommitted. The pre-existing untracked `-continuum.terminal.tmux.enabled/`
directory was left untouched.

Artifacts and logs: `qa-runs/claude-onboarding/`, including `red/`,
`bootstrap-green/results.jsonl`, `getting-started-0.png`,
`getting-started-3.png`, `preview.log` and `matrix.log`. Automated tmux checks
use disposable namespaces, unset inherited TMUX/TMUX_PANE, and verify their
private socket before use. No default tmux server is used by checks.

## Sidebar metadata icon alignment

Dylan's screenshot showed the host icon below the directory icon. The existing
AppKit baseline readings appeared equal, so a baseline-only assertion passed
while the rendered defect remained. A check of the native image cells' visible
ink caught the host 2.25pt below the folder (RED in `ink-red/`).

The row now aligns the host's visible glyph center to the folder/favicon's
visible glyph center. Symbol images and their measured offsets are cached;
measurement happens when an image changes, never inside `layout()`. Existing
folder/text baseline alignment and metadata spacing are retained.

- `swift build --product Array` passed.
- `--external-sessions-sidebar-check` passed, including visible icon-center and
  folder/text baseline assertions across the terminal and app-window host rows.
- `--sidebar-screenshot-check` passed, covering the existing width and appearance
  sweep; inspected the final production-sidebar PNG against the RED image.
- `--sidebar-ux-check` passed, including the 220/280/320pt Aqua/Dark Aqua checks.
- `scripts/dev-app.sh` rebuilt and launched the Desktop preview on
  `/Users/dylan/array-scratch`; a separate tool call verified the new alignment
  implementation in the bundle and the surviving preview process. Production
  Array remained PID 41344.
- The full matrix was not repeated for this macOS sidebar-only layout change;
  the preceding full-gate result above is unchanged historical evidence.
  No baseline was updated, and no Git staging/commit/merge/push was performed.

Logs and RED/GREEN images: `qa-runs/sidebar-icon-alignment/`. All targeted checks
used verified private tmux sockets with inherited TMUX/TMUX_PANE unset.

## Array-native session chooser

Dylan rejected the stock session dropdown and required Array styling/components
for future features. Added that explicit rule to `AGENTS.md`. This chooser now
uses the existing `ChoicePopoverController` / `ChoiceListView`, with a heading,
session titles above quieter project/activity/host details, conversation icons,
and Start a new Claude Code session first. Existing sessions remain read-only
on entry, with the explanation in the fixed footer.

Extended the shared popover's existing header configuration for a caller-owned
symbol and accessibility label (file pickers keep their prior defaults). Long
completion lists now size to whole rows rather than leaving a clipped title
fragment against the footer. Settling Getting Started's layout before opening
also prevents its changing discovery copy from moving the anchor and immediately
dismissing the panel.

Verification:

- RED: `--onboarding-panel-check` rejected the previous stock menu, requiring
  the actual shared Array choice surface.
- GREEN on the final binary: onboarding-panel, choice-geometry,
  completion-awareness, fresh-install, ui-probe, zone-cancel-menu and
  managed-agent-page-zoom checks (all seven exit 0). The onboarding check opens
  the real panel, exercises a 13-session scrolling list, Home/End visibility,
  Escape dismissal, folder-consent cancellation, stale selection, opening a
  real watch tile, Return on Start with sessions present, and the empty-list
  Start / Try Terminal path with tmux off.
- Captured and inspected the actual Array component in light and dark. The
  final viewport assertion requires eight complete rows above the footer.
- Native inspection found the shared list/row NSViews were absent from the
  accessibility tree despite their configured roles/children. Marked those
  views as accessibility elements and added a native-property assertion.
  Rebuilt and repeated all seven checks successfully. In the final running
  preview, computer-use inspection saw the named list, Start row and all 13
  real session rows; Escape restored focus to Choose without selecting one.
- Intermediate build failure: an internal Core host-classification helper was
  inaccessible from the app; removed that dependency and used the shared
  conversation icon. The first custom-panel check exposed the anchor-layout
  dismissal above; it passed after settling layout before presentation.
- macOS debug build, root-doc checks, colour hygiene (0 new violations), and
  `git diff --check` passed. The full matrix/iOS build were not repeated for
  this macOS UI change; the earlier full-gate results remain historical.
- `scripts/dev-app.sh` rebuilt/relaunched the Desktop preview on
  `/Users/dylan/array-scratch`; a separate tool call verified the surviving
  process and the final code markers. Production Array remained PID 41344.
  Final canonical bench inventory was run; the dirty/unlanded bench remains.
  No Git staging, commit, merge, push or baseline update was performed.

Artifacts: `qa-runs/array-session-chooser/`, including `red/`,
`accessibility-green/results.jsonl`, `chooser-light.png`, `chooser-dark.png`,
and `preview-final.log`. Targeted checks used verified disposable tmux sockets
with inherited TMUX/TMUX_PANE unset.

### Session age in the Array chooser (2026-10-21)

Added an activity age at the start of each existing-session subtitle, keeping
it visible ahead of the project/status/host metadata. Working sessions say
`Active now`; missing activity timestamps say `Activity time unknown`; future
timestamps from clock skew clamp to `just now`. The shared `ChoiceItem` now
accepts an optional tooltip, exposed as both native hover text and accessibility
help, containing exact opened/activity dates with the local timezone.

Claude discovery supplies `lastActivity` from `statusUpdatedAt` (or `updatedAt`)
and `startedAt` from the session record (falling back to process start). The
tooltip explains that activity reflects the latest Claude status update and
that opened may mean a resumed conversation. It deliberately does not label
the process/session start as the conversation's creation date.

- RED: rebuilt Array and ran `--onboarding-panel-check`; exit 1 because the
  existing rows lacked activity ages and exact hover/accessibility dates.
- GREEN: rebuilt Array and ran onboarding-panel, choice-geometry,
  completion-awareness, fresh-install, ui-probe, zone-cancel-menu and
  managed-agent-page-zoom checks; all seven exit 0. The onboarding witness
  checks actual rendered/native row properties for old activity, busy status,
  missing timestamps and clock skew, alongside the existing real chooser flows.
- Inspected the captured light and dark chooser renders. Root-doc checks,
  colour hygiene (27 existing allowlisted lines, 0 new) and `git diff --check`
  passed. Full matrix/iOS were not repeated for this macOS-only follow-up.
- Rebuilt the Desktop preview with `scripts/dev-app.sh`, pinned to
  `/Users/dylan/array-scratch`. A separate post-launch check verified preview
  PID 20339 and the new timing strings in its binary; production remained
  PID 41344. Native inspection of the running preview exposed all 13 real
  session ages and their exact opened/activity dates through accessibility.
  Inspected its live chooser screenshot and left that chooser open for review.
  No Git staging/commit/push/merge or baseline
  changes. Canonical bench inventory retained the dirty/unlanded bench.

Artifacts: `qa-runs/session-age/red/`, `green/results.jsonl`,
`chooser-light.png`, `chooser-dark.png`, and `preview.log`. All targeted
checks used verified private disposable tmux sockets, with inherited
TMUX/TMUX_PANE unset.

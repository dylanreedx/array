# Stage 3: default-off backend, Tier A evidence, pending Tier B

Work is on `array/focus-free-backend` in the focus-safe-input bench, based on d6802caf. Implementation commits: 125b8900 (scheduling), 32aa46ff (gated backend and production witnesses), bc3a544d (guarded real-key check), df23e552 (preserve select refusal guidance). No pushes, preview app, main-checkout edits or integration changes. Host: macOS 27.0.1 (26A434).

## What is enabled

`BrowserAutomation.focusFreeInputEnabled` is internal and defaults to false. Only explicit check entry points enable it. There is no Settings UI or normal-launch environment override. With it false, Stage 1 delivery, restoration, focus interruption, scheduling and mounted-scene rules remain in use.

With it true and the suppression selector available, agent native delivery is scoped with `_setShouldSuppressFirstResponderChanges:` throughout the action, including suspension points. It does not save/restore the host responder. Text uses the witnessed edit-command route, selection/shortcuts use editor-specific routes, and unrelated composer changes no longer stop typing. Native events never pass through the user's composer. A user event in the driven tile still causes durable takeover, including nested native delivery. Missing suppression capability uses Stage 1 and reports it; no activation fallback exists.

Background scheduling changes also require this switch. Availability-checked getters/setters save and restore the original preferences and inactive scheduling policy with ownership. Snapshots explicitly warn that hidden requestAnimationFrame may remain frozen.

The workspace API can resolve a parked browser through its exact live runtime and owning project without switching or arming the active scene. Parked URL and handback metadata persist to that project's tile. A lease pins a warm scene through cache pressure; capacity is temporarily soft while leases remain, with later switches trimming it. Explicit Return renews the lease before the required fresh snapshot, including a switch in that interval. Closing ends the runtime identity and prevents replacement targeting. BrowserActionQueue.swift was not changed.

## Tier A: faked key window only

These mount through AppDelegate.mountWorkspaceSceneAtBoot, call production tools, and send user events through NSApp.sendEvent. BrowserFakedKeyCheckWindow overrides isKeyWindow; the app is inactive and off-screen. They are not real key-state proof. Responder tracing covers actions throughout, including transient changes. The real subclass does not override key state.

Existing `--browser-focus-restoration-check` with QA-only `ARRAY_FOCUS_FREE_TIER_A=1` passed:

- Numeric replay replaces 1 with 3 and then 12, Tab commits application state, trusted events are observed, and the following user key lands in the composer.
- A user key during native click reaches the composer; no transient responder borrow occurs.
- All 100 agent characters reach the page while five concurrent user keys reach the sibling managed-agent composer, with zero transient borrow.
- Actual vendored React controlled-input state, CodeMirror 6 document state and ProseMirror document state pass selection/replacement, Undo, rerender and concurrent composer typing. React native form submission is observed once. CodeMirror Enter inserts a newline; ProseMirror Enter splits the paragraph and Cmd-B adds a bold mark; Tab is exercised.
- A handler rejecting agent text yields unknown effects and fresh-snapshot guidance instead of false success.
- A Monaco-classification fixture refuses caret clicks and Undo before dispatch. This is negative classification coverage, not an actual Monaco compatibility test.
- Synthetic canvas pan, automatic off-camera zone, zone/workspace switches, parking, subsequent parked typing/navigation and persisted URL all retain the intended runtime.
- Return followed immediately by a workspace switch and parked snapshot clears the durable fence and resumes typing.
- Actual budget pressure evicts a spare runtime and preserves leased in-flight typing. Closing stops the old prefix and the old identity cannot affect its replacement.

Final detailed output: `/tmp/stage3-complete-tier_a.log` (exit 0).

Other targeted legs:

| Leg | Result |
| --- | --- |
| Debug Array build, actual process exit | PASS; latest `/tmp/stage3-final-confirm-build.log`, exit 0 |
| Background scheduling | PASS; scoped acceleration/restoration, hidden rAF remains frozen |
| Normal Stage 1 focus restoration | PASS; `/tmp/stage3-complete-stage1.log` |
| Browser automation engine | PASS in targeted matrix |
| Durable takeover, experimental nested delivery | PASS; `/tmp/stage3-complete-nested.log` |
| Durable takeover, normal Stage 1 | PASS; `/tmp/stage3-complete-normal.log` |
| Native select preflight, experimental and normal | PASS; `/tmp/stage3-select-final-1.log`, `/tmp/stage3-select-final-0.log` |
| Workspace browser API | PASS; `/tmp/stage3-api-final-tree.log`, includes 15 hardening scenarios |
| Tier B without authorization variable | Expected refusal, exit 1, no activation; `/tmp/stage3-complete-refusal.log` |
| Matrix shell syntax, committed inventory, diff whitespace | PASS; inventory reports 1035 records |

The targeted `--browser-scheduling` matrix ran once: 8 legs, 7 passes, 1 failure. The failure was an obsolete API witness expecting focus refusal from press_key with a foreign responder. The Stage 1 baseline already permits that route. Replaced the assertion with observed delivery to the intended page exactly once and zero delivery to the foreign browser. The API leg subsequently passed. Later fixture expansions and select correction were rerun as individual targeted legs, not a full matrix. Experimental variants use existing flags and are registered in the matrix; Tier B is deliberately absent.

Normal mode still transiently borrows first responder during an ordinary click and restores the original composer. Its witness reports `responderBorrowObserved=true, originalResponderAfterAction=true`. Unrelated focus loss mid-type still stops the prefix and reports partial effects, deliveredCharacters, observe-before-new-action and a required fresh snapshot. Experimental Tier A reports no borrow and completes agent typing across unrelated user focus changes.

## Red controls and corrections

- Switch off: numeric replay fails the transient-borrow assertion (`/tmp/stage3-tier-red.log`).
- Disable immediately before React/CodeMirror/ProseMirror: intended user composer input reaches the browser and takeover stops agent input after a prefix (`/tmp/stage3-react-controls.log`, `stage3-cm-controls.log`, `stage3-pm-controls.log`).
- Disable at pan/zone/workspace phase: corresponding controls fail (`/tmp/stage3-control-pan.log`, `stage3-control-zone.log`, `stage3-control-workspace.log`).
- Mounted-only API lookup: workspace-switch action returns outcome_unknown (`/tmp/stage3-on-controls.log`).
- No warm lease pin: capacity eviction loses runtime after three characters (`/tmp/stage3-warm-red.log`).
- No parked metadata persistence: navigation loads but returns outcome_unknown when mounted URL update fails (`/tmp/stage3-parked-nav-red.log`).
- No immediate Return lease: switch before fresh snapshot loses browser identity (`/tmp/stage3-handoff-red.log`).
- Native-depth monitor exclusion: user tile key during native click is ignored (`/tmp/stage3-nested-red.log`, `stage3-nested-faked-red.log`).
- Remove final text readback validation: application rejects the input but tool falsely succeeds (`/tmp/stage3-retention-red.log`).
- Monaco classification before HTML SELECT check: correct no-dispatch outcome but wrong refusal guidance (`/tmp/stage3-select-guidance-red.log`). Reordered the checks; both modes now pass.

Late switch-off controls for eviction and closing passed. They are regression coverage of existing identity/lease protections, not newly demonstrated red fixes. One intermediate handback run failed because the tracing fixture counted a deliberate user browser-focus phase as agent borrowing; the fixture now first asserts the earlier trace, disarms only for that deliberate setup, then re-arms for agent work. That intermediate failure is not product evidence.

## Tier B: build and refusal proven; authorized run pending

`--browser-focus-free-real-key-check` uses the native NSWindow key state with no override. It refuses before setup or activation unless ARRAY_ALLOW_REAL_KEY_PROOF=1. It must only be run by the lead during a moment Dylan approves. It has never been run here with that variable set.

It activates an off-screen borderless check window, verifies actual native key state, traces responder changes throughout numeric/click/type cases, prints per-case pass/fail and restores the previous frontmost application. An independent 28-second watchdog attempts restoration and exits; SIGALRM forces exit at 29 seconds even if restoration blocks. These activated paths are built but untested until the authorized run. The check is not a normal matrix leg.

Exact command for that approved moment only:

```sh
cd /Users/dylan/Documents/personal/Array/.worktrees/focus-safe-input
unset ARRAY_AGENT_ID ARRAY_FOCUS_FREE_TIER_A ARRAY_FOCUS_FREE_RED_CONTROL
TERM=xterm-256color \
CONTINUUM_PROJECT_ROOT="$(mktemp -d /tmp/array-tier-b-project.XXXXXX)" \
CONTINUUM_APP_SUPPORT="$(mktemp -d /tmp/array-tier-b-state.XXXXXX)" \
ARRAY_ALLOW_REAL_KEY_PROOF=1 \
/tmp/exc-probe/noexc .build/debug/Array --browser-focus-free-real-key-check \
  -continuum.terminal.tmux.enabled NO -continuum.terminal.tmux.path '' </dev/null
```

## Limits and open work

Real key-state acceptance is pending; the normal backend stays off. Real pointer coexistence and real IME were not tested. Tier B covers the three core cases only, not every editor and lifecycle case under real activation. Missing-selector fallback is availability-checked but not exercised on an OS lacking it.

React's tested route uses edit SelectAll/Undo. CodeMirror uses keyDown Cmd-A because edit SelectAll is known to fail. ProseMirror uses direct keyDown Cmd-B; performKeyEquivalent is not the route. Monaco caret placement and Undo remain explicitly unsupported. Arbitrary editors, Headless UI structural remounts and the entire plan's replay inventory are not newly proven. Vendor fixtures are offline copies in Resources/FocusInputFixtures with licenses; no product-facing editor dependency is introduced.

DOM readback proves the witnessed input/model effects, not arbitrary application semantics. Unverifiable delivery is reported honestly. Hidden rAF remains frozen. Universal native-popup lifetime, arbitrary delayed/cached showPicker and page behaviors beyond the existing select preflight boundary remain an open gap; no universal popup guarantee is claimed.

All app/build children used /tmp/exc-probe/noexc. App runs unset ARRAY_AGENT_ID, use /dev/null and TERM=xterm-256color, isolated QA state and disabled/disposable tmux. No synthetic system events, live tiles, standard-default writes or full matrix. Keep this bench for the pending lead-run Tier B proof.

## Prepared LaunchServices retry (not activated)

The first approved bare-binary Tier B attempt exited 1 before any core case:
all three reported `Tier B real key-window setup failed`. External frontmost
readings stayed on the same Array ASN. This gives no suppression result.

The retry logs setup state to `ARRAY_REAL_KEY_LOG_PATH`: active state, activation
policy, frontmost application/PID, native key-window identity, canBecomeKey, and
elapsed/wait times before and after policy, finishLaunching, activation, and
makeKey. It uses a regular app policy and waits at most one second for activation
and one second for key state. No fake key-window override is used.

LaunchServices can foreground the bundle before main, so the command captures the
previous frontmost PID before launching and passes it explicitly. If the check
never foregrounded itself and that previous app remains frontmost, restoration is
reported as unnecessary. Otherwise restoration is attempted and verified by PID,
regardless of the activation request's completion Bool. The 28-second watchdog
and independent 29-second hard exit remain.

The dedicated bundle is prepared with `scripts/dev-app.sh --no-launch`,
DEV_APP_PATH under ~/array-scratch/apps, and a unique bundle ID. It does not replace
the shared preview. The command below removes this extra bundle after termination.
It has NOT been launched; approval for the first run does not authorize this one.

This flag exits before normal application delegate boot and its folder grants.
Ghostty's global bootstrap precedes the flag, but this fixture passes nil Ghostty
and creates no terminal runtime/config UI. The fixture mounts temp projects;
CONTINUUM_PROJECT_ROOT and CONTINUUM_APP_SUPPORT also point at fresh /tmp paths.
No Array folder or Ghostty configuration prompt is on this path. LaunchServices
and operating-system UI remain untested until the approved retry.

After a fresh explicit approval, execute this single compound command once:

```sh
(
  set -eu
  tier_b_app="$HOME/array-scratch/apps/Array Tier B.app"
  tier_b_previous="$(lsappinfo info -only pid "$(lsappinfo front)" | sed -nE 's/.*pid = ([0-9]+).*/\1/p')"
  test -n "$tier_b_previous"
  test -d "$tier_b_app"
  tier_b_project="$(mktemp -d /tmp/array-tier-b-project.XXXXXX)"
  tier_b_state="$(mktemp -d /tmp/array-tier-b-state.XXXXXX)"
  trap 'rm -rf "$tier_b_app"' EXIT
  open -n -W     --env ARRAY_AGENT_ID=     --env ARRAY_FOCUS_FREE_TIER_A=0     --env ARRAY_FOCUS_FREE_RED_CONTROL=0     --env TERM=xterm-256color     --env "CONTINUUM_PROJECT_ROOT=$tier_b_project"     --env "CONTINUUM_APP_SUPPORT=$tier_b_state"     --env ARRAY_ALLOW_REAL_KEY_PROOF=1     --env "ARRAY_REAL_KEY_PREVIOUS_PID=$tier_b_previous"     --env ARRAY_REAL_KEY_LOG_PATH=/tmp/stage3-tier-b-launchservices.log     "$tier_b_app" --args --browser-focus-free-real-key-check     -continuum.terminal.tmux.enabled NO -continuum.terminal.tmux.path ''
  cat /tmp/stage3-tier-b-launchservices.log
)
```

On screen, the test app briefly becomes the foreground application (menu bar and
possibly Dock identity change); the fixture window stays off-screen. The previous
app is returned to the front before exit. Native activation, actual case outcomes,
and restoration are still unproven; no further activated run has occurred.
The experimental delivery switch remains off by default.

Preparation verification: debug dev-app --no-launch exited 0 (73 seconds),
including both Swift product builds and bundle assembly. Deep/strict codesign
verification passed. The bundle has no quarantine attribute (only provenance).
Bare-executable refusal with ARRAY_ALLOW_REAL_KEY_PROOF unset exited 1 and wrote
the expected REFUSED message to /tmp/stage3-tier-b-refusal-diagnostics.log.
No open invocation, activation, or approved core case was run during preparation.

## Review follow-up: strict input retention

Production-tool contenteditable witnesses failed before the fix:
truncated 220/240-character replacement and rejected insertion both returned
success (/tmp/stage3-review-retention-red.log). After the fix both report
outcome_unknown with partial effects, a fresh snapshot requirement, and verified
retained counts 220 and 0 respectively. Full multiline/whitespace-normalized text
and a subsequent insertion pass, as do actual React, CodeMirror and ProseMirror
models (/tmp/stage3-review-retention-green.log). A detached editor clone preserves
selection paragraph context; verification no longer truncates either side or
accepts any change. Destroyed/unknown selection context still reports unknown
effects rather than inventing a retained count. Known counts use the existing
deliveredCharacters field and the error explains retention versus dispatch.

Debug build exited 0. Faked-key focus check passed with the switch on; Stage 1
switch-off focus check passed (/tmp/stage3-review-retention-0.log). No app activated.

## Review follow-up: submission verification

Both reset-on-submit and navigate-on-submit production-tool witnesses failed
before reordering (/tmp/stage3-review-submit-red2.log), despite observing exactly
one trusted submission. The reset case produced a retention error; navigation
lost the old document's verification state. A fixture-only correction carries
the submission record in the destination URL because file navigation can clear
window.name; the earlier navigation fixture exception was not a product result.

The action now verifies text and captures its value before Enter, then sends the
key without querying the old field afterward. Normal post-action settling remains
best-effort. The value is the pre-submission readback; the summary distinguishes
Enter dispatch from application outcome. Both forms now return committed effects,
and same-key retries return committed without a second submit, with the switch
on AND off (/tmp/stage3-review-submit-green-1.log and -0.log). Full editor,
retention and lifecycle checks also passed in the on leg. Debug build exited 0.
No activated check ran; the default switch is unchanged.

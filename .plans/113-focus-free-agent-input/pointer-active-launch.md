> RETIRED after the approved run: do not rerun this launch. Cooperative restoration returned false and was not confirmed. Current checks make no automatic-restoration claim; the old preparation text below is historical. Atomic buffering has been removed. Use the hands-on preview steps in pointer-manual-test.md instead.

# Guarded active-pointer proof — prepared, never activated

This is a preparation result, not a passing active-pointer claim. The dedicated debug bundle is `~/array-scratch/apps/Array Pointer Proof.app`, bundle ID `dev.arrayapp.macos.pointer-proof`. No activated run occurred during preparation. Each run needs Dylan's explicit approval. The command removes the bundle when that one run ends.

The new `--browser-pointer-real-active-check` refuses without `ARRAY_ALLOW_REAL_KEY_PROOF=1`, before fixture setup or activation. It requires the external previous-frontmost PID captured before LaunchServices foregrounds the bundle. The real-key window is `BrowserFocusCheckWindow` (native isKeyWindow, no fake override); its constrainFrameRect keeps it off-screen during resizing and makeKey. The check requires the native key window, active app, self frontmost PID and a frame outside every screen.

It uses the mounted workspace, production browser tools and queue. All pointer input is in-process NSEvent through NSApp.sendEvent. No CGEvents, system posting or pointer warps are created. A legacy public tracking rect supplies a real exit tracking tag. Pages contain no selects or native pickers; the draggable fixture cancels dragstart to avoid starting a native dragging session.

Cases print PASS, FAIL or KILLED:

- Unowned browser: trusted move and CSS hover must work with the candidate disabled AND enabled. If this cannot be stimulated, hover controls fail rather than produce false KILLED results.
- CSS hover menu and mouseleave dropdown: establish an agent-opened menu, deliver move/exit to the driven tile, then click its item. A red control must receive an effective pointer stimulus. A surviving red control is KILLED; a failure is replayed with the candidate filter. Runtime, parent and control generation are checked too.
- Atomic click: move, threshold-crossing drag and a click into the unowned browser are interleaved at the engine's down/up seam. Page state must show exactly one agent click, no drag/selection and adjacent down/up; the user click must reach its intended browser exactly once. Effective surviving controls are KILLED. A failing control is replayed with scoped buffering and replay after mouseup.
- Deliberate takeover: click and key in the driven tile during native delivery must count immediately and durably fence tools with candidates both off and on. The buffered key must reach its page exactly once; explicit handback and fresh snapshot reset each case.

The candidate filter and atomic buffering are internal `_pointerFilterForChecks` / `_atomicClicksForChecks` switches, both false in normal launches. Only this guarded experiment enables them. `focusFreeInputEnabled` still defaults false; this check temporarily uses its true backend. No automatic adoption of a speculative production fix occurs. After the approved log, remove any candidate whose mechanism is KILLED and retain/adopt only demonstrated red-to-green behavior. The new active flag is deliberately excluded from the unattended matrix, like the existing real-key check.

Restoration uses the public macOS 14 cooperative handoff: NSApp.yieldActivation(to:) followed by previous.activate(from:options:), then verifies the previous PID before exit. The existing Tier B real-key check now uses this same handoff. This replaces its unsupported background-only activation request; actual restoration proof remains pending the approved run. Cases have a 23-second budget, a background watchdog requests restoration and exits at 26 seconds, and an independent SIGALRM exits at 29 seconds. Normal completion allows up to one second for PID-verified restoration.

## One approved launch

Run this compound command once, only after Dylan approves that activation. It captures the prior PID before open, uses separate temporary project and app-support dirs, preserves the log and removes its own bundle afterward. `open -W` does not propagate the app's status, so the command also requires the final success marker after printing the per-case log.

```sh
(
  set -eu
  pointer_app="$HOME/array-scratch/apps/Array Pointer Proof.app"
  pointer_previous="$(lsappinfo info -only pid "$(lsappinfo front)" | sed -nE 's/.*pid = ([0-9]+).*/\1/p')"
  test -n "$pointer_previous"
  test -d "$pointer_app"
  pointer_project="$(mktemp -d /tmp/array-pointer-project.XXXXXX)"
  pointer_state="$(mktemp -d /tmp/array-pointer-state.XXXXXX)"
  trap 'rm -rf "$pointer_app" "$pointer_project" "$pointer_state"' EXIT
  open -n -W \
    --env ARRAY_AGENT_ID= --env TERM=xterm-256color \
    --env "CONTINUUM_PROJECT_ROOT=$pointer_project" \
    --env "CONTINUUM_APP_SUPPORT=$pointer_state" \
    --env ARRAY_ALLOW_REAL_KEY_PROOF=1 \
    --env "ARRAY_REAL_KEY_PREVIOUS_PID=$pointer_previous" \
    --env ARRAY_REAL_KEY_LOG_PATH=/tmp/array-pointer-active.log \
    "$pointer_app" --args --browser-pointer-real-active-check \
    -continuum.terminal.tmux.enabled NO -continuum.terminal.tmux.path ''
  cat /tmp/array-pointer-active.log
  grep -Fxq 'PASS: active pointer proof complete' /tmp/array-pointer-active.log
)
```

Expect the menu bar/Dock identity and keyboard focus to move briefly to the proof app. The test window stays off-screen. The check attempts to return the prior application before exit and logs PID confirmation. Leave the keyboard idle during the run. Total target is under about 30 seconds (29-second hard deadline starts inside the check). No actual foreground/restoration/hover/atomicity result is asserted yet.

## Preparation verification

- Initial debug compile failed actor-isolation checking in nested local helpers; explicitly MainActor-isolated helpers corrected it. Subsequent debug build exited 0: `/tmp/pointer-active-build2.log` (101.86s).
- `scripts/dev-app.sh --no-launch`, own bundle path/ID/name, through `/tmp/exc-probe/noexc /bin/bash`: exited 0 twice, `/tmp/pointer-active-bundle-build.log` (88s) and final `/tmp/pointer-active-bundle-final.log` (47s). No release build or launch.
- Final deep/strict codesign verification exited 0; Info.plist reads `dev.arrayapp.macos.pointer-proof`.
- Bare `.build/debug/Array` and the actual bundle executable, without the guard variable, both exited 1 with REFUSED and no activation: `/tmp/pointer-active-refusal.log`, `/tmp/pointer-active-bundle-refusal.log`.
- Normal inactive durable-takeover checks passed with focus-free backend off/on after the final native-delivery change: `/tmp/pointer-active-final-baseline-0.log`, `-1.log`. Explicit temporary project/app-support dirs, ARRAY_AGENT_ID unset, TERM=xterm-256color, /dev/null stdin, `/tmp/exc-probe/noexc`, tmux disabled. No full matrix or real-key/active check with the guard enabled was run.
- `git diff --check` passed. The bundle and bench are deliberately retained for the approved launch. No push.

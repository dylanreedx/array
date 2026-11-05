# Stage 3 progress: scheduling proven, input proof blocked

Branch: array/focus-free-backend, created from d6802caf in the focus-safe-input bench. No preview, main-checkout edits, integration-branch changes, pushes or live input.

## Delivered independently

BrowserAutomation scopes background scheduling preferences to the existing engagement lease. Both private setters and their getters must exist before changing anything. Original flag values and the public inactiveSchedulingPolicy are saved and restored when engagement ends, including detach. Browser snapshots report whether acceleration is active/unavailable/inactive and explicitly warn that requestAnimationFrame can remain frozen on hidden pages.

The production-mounted --browser-background-scheduling-check calls the workspace tools, creates a real page interval, reads its counters, sends takeover via NSApp.sendEvent, and asserts restoration of both private preferences and the public policy. RED before: 7 ticks in a one-second interval, hidden rAF 0. GREEN: 78 ticks, rAF delta 0, hidden. The targeted matrix observed 77 ticks. This proves timer acceleration and takeover restoration on this host, not universal scheduling, real focus independence or rAF progress. Missing-selector behavior has not been exercised on an OS lacking these selectors.

New leg is registered in scripts/run-matrix.sh and the inventory. --browser-scheduling is a small existing-matrix mode for this leg plus durable takeover, with its own debug build. No full matrix.

## Input gate blocked at fixture setup

The strengthened production witness removed the isKeyWindow override, required both the real NSWindow.isKeyWindow and NSApp.keyWindow, and tracked responder changes throughout the numeric replay. Setup failed before any browser input:

    fixture did not establish a real AppKit key window: native=false app=nil active=false

Public makeKey(), becomeKey(), accessory activation policy, finishLaunching(), and running the check through NSApplication.run() did not establish key state in this inactive offscreen process. No activate call, nonactivating-panel keyboard capture, key-state override or system event posting was used to force a pass. The failure is fixture/environment setup, NOT evidence that suppression fails in a real key window. No valid red/green backend or editor result was obtained.

A scoped, availability-checked suppression candidate was built, but this prerequisite prevented testing it. Its unproven diff is preserved at /tmp/stage3-unproven-input.patch. It is NOT integrated or committed. Existing Stage 1 delivery and focus witnesses remain unchanged. An asynchronous question asks whether an isolated graphical login session is available. A valid safe real-key-window environment is required before continuing the dependent adoption.

Consequently ordinary agent native input still borrows first responder on this branch, and unrelated mid-type focus changes still have Stage 1 partial outcome_unknown semantics. No Stage 3 focus independence claim is made.

## Remaining work and editor limits

The requested production editor, concurrent typing/click, numeric, camera-pan, zone/workspace-switch, parking/eviction and closing/replacement acceptance tests remain unproven. Input routes, save/restore removal and continued typing across user focus changes are not integrated. Real pointer coexistence and real IME remain untested.

From the Stage 2 report only (not new production proof): React requires edit SelectAll/Undo rather than native Cmd-A; CodeMirror requires keyDown SelectAll because edit SelectAll fails; ProseMirror uses direct Cmd-B rather than performKeyEquivalent; Headless UI has only its tested option/query workflow, not general structural remount compatibility; Monaco undo/caret routes failed. None has passed the required real-key production acceptance here.

Lifecycle source audit: WorkspaceAPIService+Browser.swift browserScopeTarget (line 45) requires a tile in the mounted scene; ownership reads in the queued action (around line 616) also use canvasProvider. WorkspaceRuntime protects existing lease tile IDs in currentProtectedBrowserTileIds (line 2792), including budget eviction, and parks layers across workspace switches. These are source findings, not proof that in-flight input survives switches or normal eviction. They still need the requested production behavioral witnesses and targeted fixes.

## Runs

- Debug builds: successful builds checked by their own exit code. An initial compile caught the Swift rename makeKeyWindow -> makeKey; corrected before running that binary.
- Input fixture attempts: /tmp/stage3-red.log, /tmp/stage3-keywindow.log, /tmp/stage3-accessory.log, /tmp/stage3-launch.log, /tmp/stage3-eventloop.log. All failed the prerequisite, before input assertions.
- Scheduling RED: /tmp/stage3-scheduling-red.log.
- Scheduling GREEN: /tmp/stage3-scheduling-green.log.
- First targeted matrix: its three behavioral/inventory legs passed, but its new wrapper then referenced an undefined MATRIX_STATUS. The wrapper was corrected to the existing exit-$? pattern; the final run is /tmp/stage3-scheduling-matrix-final.log.
- No full matrix, preview, real pointer or real IME run.

All app/build children used /tmp/exc-probe/noexc. App runs unset ARRAY_AGENT_ID, use stdin /dev/null and TERM=xterm-256color. Matrix owns its disposable tmux namespace; ad hoc legs disable tmux. Fixture state is isolated and no .standard defaults are written.

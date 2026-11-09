# Input-path focus audit

READ IN SOURCE — Audited release commit `d41dad0486829bb2b92cdbf08ee49d3d75279fdb` on 2026-11-05 using git show/git grep. All source locations below refer to that commit, not the working tree. No product edits, builds, UI checks, live tile interaction, tmux, synthetic system input, or matrix runs were performed. Only this research file was created. No fresh behavioral measurements or vendor-document claims are made.

## Ranked findings

1. **READ IN SOURCE — Browser typing can restore an obsolete composer focus after Dylan clicks elsewhere.** `BrowserEngine/BrowserAutomation.swift:254–256` captures the window first responder and restores it on leaving the action body if this browser's `userInputCount` is unchanged. The body yields repeatedly (`266`, `281`, `287`). The counter only notices events whose hit view/responder ancestry belongs to this browser or its registered tile surface (`629–648`, `151–154`). Clicking and typing in another agent's composer therefore does not invalidate restoration. `restore` calls `window.makeFirstResponder(oldResponder)` (`500–501`). This is a concrete race in the source; **GUESS — it accounts for a substantial part of Dylan's observed cross-tile focus theft**, pending a controlled witness. It also explains why an isolated click probe with no concurrent user interaction looked safe. Restoration is incidental protection, not required to deliver input; its guard is too narrow for protecting the whole window.

2. **READ IN SOURCE — Browser native input is direct, but it still invokes WebKit's native control machinery.** `deliverClick` calls `webView.mouseDown` and `mouseUp` synchronously (`483–497`), and `deliverKey` calls `webView.keyDown/keyUp` (`512–527`). There is no select-specific automation path in the executor: dropdowns use this same click/key route. **GUESS — a native SELECT popup enters WebKit/AppKit tracking, presenting UI outside the tile and interacting with real user events.** That is the strongest candidate for floating dropdowns and interrupted menu selection, but native framework tracking and popup lifetime are not proven by Array's Swift source. No claim that the source alone identifies the exact AppKit mechanism is justified.

3. **READ IN SOURCE — Focus restoration is also unconditional after press_key and click.** `pressKey:323–324` and `deliverClick:489–496` restore the saved responder. Ordinary synchronous execution has no Swift suspension between capture and restore in those paths. **GUESS — nested event tracking/reentrancy from a dropdown could allow a real focus change during those intervals, making those restores stale as well.** This is weaker than the demonstrated asynchronous opportunity in type. Do not claim every ordinary key press has the same race as typing.

4. **READ IN SOURCE — Real interaction with the target browser deliberately aborts agent control.** The local monitor increments the browser counter and invokes takeover (`623–645`); `WorkspaceAPIService+Browser.swift:137–155` releases ownership/lease and schedules hydration reconciliation. `BrowserActionQueue.swift:198–214,218–224` rejects queued or completed-in-flight results after the counter changes. This directly explains failures when Dylan actually clicks/types in the automated browser. **GUESS — cross-tile failures may also follow focus theft redirecting later real keystrokes into that browser, or native popup tracking.** A click elsewhere alone should not trigger this browser monitor according to the explicit ancestry test. That portion of the symptom remains unexplained behaviorally.

5. **READ IN SOURCE — Permission UI is window-wide.** Browser handover and domain approvals call `NSAlert.beginSheetModal(for: canvasWindow)` (`App/ContinuumApp.swift:22719,22735`), through service callbacks (`7346–7352`). This blocks normal interaction with the parent while pending. It is required by the current approval presentation, not by WKWebView input itself. It explains approval-time interruption, not recurring local clicks with no approval prompt.

## End-to-end tool routing

READ IN SOURCE — Shared route: MCP host loopback listener queues authenticated work onto main (`App/WorkspaceMCPHost.swift:46–55,72 onward`), handler enters `WorkspaceAPIService.handleMCPRequest:341–374`, then `dispatchAsync:417–432`. Browser calls go to `dispatchBrowserAction` or `dispatchBrowserOpen` in `WorkspaceAPIService+Browser.swift`. Authorization resolves the explicit installed tile/project; the action queue serializes per tile and fences permissions, runtime identity, deadlines and user input (`+Browser:480–510`; `BrowserActionQueue:198–224`). `BrowserActionExecutor.perform:9–104` converts requests into these calls:

| Tool | Actual delivery and outcome |
|---|---|
| array_browser_click | Executor 33–36 → engine 222–244 → isolated-world target lookup/hit check → direct NSEvent mouseDown/up 483–497. Ref target scrolls DOM element into view first. |
| array_browser_type | Executor 38–39 → engine 250–292 → trusted native click on editable ref, DOM focus verification, optional DOM selection, per-character direct NSEvent keyDown/up; optional Enter. No ref means current DOM focus. |
| array_browser_press_key | Executor 40–41 → engine 297–334 → parsed key/modifiers → direct keyDown/up. Cmd+A instead calls `webView.selectAll(nil)` at 329. |
| array_browser_scroll | Executor 42–43 → engine 337–348 → isolated-world JS scrollIntoView or window.scrollBy. No physical wheel event. |
| array_browser_wait_for | Executor 44–53 → engine 357–389 → host-side 100ms polling of isolated-world probe; idle also checks webView.isLoading. |
| array_browser_snapshot | Executor 29–32 → engine 159–169 → isolated-world DOM outline; updates ref generation. No screenshot or focus call. |
| array_browser_take_screenshot | Executor 54–57 → engine 175–205 → WKWebView.takeSnapshot through helper at 698 onward; optional ref crop, bitmap encoding off main. No screen capture or camera reveal. |
| array_browser_evaluate | Executor 58–61 → engine 210–217 → callAsyncJavaScript in PAGE world. Script is agent supplied and can itself focus DOM elements, scroll, open URLs or otherwise mutate the page. |
| array_browser_navigate | Executor 75–90 → runtime.navigateForAgent under navigation approval → engine.waitFor(.idle). Reload of dead runtime is separately rebuilt in service before navigation. |
| array_browser_open | +Browser 695 onward, spawn at 810 → TileSpawner.spawnAgentBrowser 1306–1313 → spawnBrowserImpl 1091–1190: creates Agents-profile WKWebView/runtime/tile, installs beside caller in explicit zone, persists, loads blank; service installs gate/lease and routes requested URL through executor navigation. No implicit reveal call here. |
| array_browser_console | Executor 62–74 reads bounded console buffer only. Included for completeness. |

READ IN SOURCE — DOM target lookup calls `scrollIntoView({block:'center',inline:'center',behavior:'instant'})` (`BrowserAutomationScript.swift:229–235`); clear selects input contents or contenteditable children (`260–264`); scroll executes `scrollIntoView` / `window.scrollBy` (`267–275`). These alter page scroll/selection, not canvas camera/selection. They are required by the current ref-click/clear implementation, not proof that all future input engines require them.

## Simulator action routing

READ IN SOURCE — `array_device_act` follows the same MCP service ingress, then `dispatchAsync:417–419` → `WorkspaceAPIService+Device.swift` decode/bounds/idempotency at `400–435` → `IOSPreviewAutomationSessions.act:110–146`. Observation pixels are converted to normalized raw framebuffer coordinates using orientation at `116–129`. It calls runtime.acknowledgedAction at 138 → `IOSPreviewRuntime.swift:207–210` → session implementation `433–438` → action-channel request ID and WebSocket tag 0x20 (`445–456`).

READ IN SOURCE — `Resources/IOSPreview/bridge.cjs:12–13` constructs native `SimCapture(device)` and `SimHID(device)`. Serialized jobs execute `action:121–155`: tap/swipe uses hid.touch begin/move/end, key uses hid.key, home uses hid.button, rotate uses hid.orientation. Text uses `/usr/bin/xcrun simctl pbcopy <device>` with text on stdin (`62–68`), then simulator HID Command+V (`73–78`). Thus text changes the simulator pasteboard; it does not invoke the host's keyboard paste path in this adapter. Native addon internals were not audited here, so host pasteboard propagation through simulator settings remains unverified.

READ IN SOURCE — The adapter rejects held contact/keys at `bridge:123`, cancels swipe continuation on controller loss/rotation at `135`, releases held input at `141,152`, and reports uncertain partial effects. The explicit Swift/JS action path contains no call to makeFirstResponder, window activation, pointer warp, CGEvent posting or NSApp.sendEvent. **GUESS — it should be independent of host keyboard focus;** that is not a new measured guarantee about the native addon. Device takeover and native action failures can still interrupt a run by design.

## Side effects and non-effects inventory

All entries in this table are READ IN SOURCE; requirements are implementation requirements unless stated otherwise. Paths are under Sources/ContinuumRevived.

| Location at d41dad04 | Effect; required or incidental |
|---|---|
| BrowserEngine/BrowserAutomation.swift:500–501; callers 256,324,496 | makeFirstResponder(saved responder). Incidental attempt to preserve focus; can overwrite newer user choice. |
| same:265–268 | Real click establishes page editing focus, then checks focusedIs. Required by chosen trusted typing mechanism; earlier probe reports JS-only focus unreliable. Does not explicitly make browser the host first responder. |
| same:329; BrowserAutomationScript:260–264 | Page selection for Cmd+A / clear. Required for current semantics. |
| BrowserAutomationScript:233,271,274 | Page scroll/reveal. Required for current target delivery and requested scrolling. No canvas reveal. |
| BrowserAutomation:470–480 | Input requires webView.window and live runtime. Hidden→visible transition gets 50ms delay; does not unhide or order a window itself. No explicit key-window requirement. |
| same:663–665 | Hidden app, invisible/occluded window, hidden ancestor classify timeout as throttled. Diagnostic dependency, no activation. |
| same:623–645,651–657 | Local event observation, browser-local quiet wait, takeover. Intentional policy; no global event tap/post. |
| App/WorkspaceAPIService+Browser:137–155 | Takeover changes control state and schedules hydration reconciliation with rearmForCamera:false. Intentional policy, not input necessity. |
| App/ContinuumApp:22719,22735 | Window-modal approval sheets. Required by current approval UI only. |
| App/TileSpawner:1164,1176,3107–3109; Canvas/CanvasNSView:8291–8335 | Tile installation, z ordering, zone growth, sidebar notification and optional auto-layout arrangement. Required to mount/persist browser, incidental to subsequent input; opening can move sibling tiles through auto-layout. No focus/zone arming/reveal call in this spawn body. |
| App/ContinuumApp:7367–7374 | Control chip actions install callbacks; revealAgent is invoked by the chip's user action, not each automated action. |
| BrowserEngine/WKWebViewBrowserRuntime:880–881 | runtime.focus explicitly makes webView first responder. It exists but no call to focus() is in the audited executor; do not attribute it to every browser action. |
| same:1442 | makeKeyAndOrderFront is in a check fixture, not production input delivery. |
| Canvas/BrowserTileNSView:490,516,731 | Find/address-field focus from tile UI methods. No call from the action executor identified. |

READ IN SOURCE — Targeted searches of the engine, service, executor and simulator adapter found no NSEvent.mouseLocation, CGWarp, global event posting, NSApp.activate, makeKey/orderFront, cursor-setting, canvas selection, setActiveZone or camera/reveal call in direct action delivery. This is a bounded negative result, not an exhaustive proof about WebKit/AppKit or native SimHID internals. `NSLayoutConstraint.activate` and tab-model activate are not app activation.

## What still needs a witness

GUESS — The minimum useful next behavioral witness is a long browser type while a second text view becomes first responder: assert both the new responder and its typed text survive. Current browser-local input fencing cannot establish this guarantee. A separate SELECT click → real user action elsewhere → agent ArrowDown/Enter/cancel sequence is needed to observe native menu ownership, event routing and popup cleanup. Neither was run because this research forbids opening windows or synthetic input on Dylan's screen.

READ IN SOURCE — The existing 2026-10-24 `research/wkwebview-feasibility.md` reports prior direct clicks preserving another responder and trusted typing after a real field click; it also records earlier focus conclusions being overturned. Those are historical MEASURED reports, not measurements repeated here. The file's recommendation to restore focus does not establish concurrency safety.

READ IN SOURCE — Local HEAD materially differs: `git diff d41dad04 HEAD --stat` shows BrowserAutomation.swift, BrowserAutomationScript.swift, BrowserActionExecutor.swift, BrowserActionQueue.swift and WorkspaceAPIService+Browser.swift removed, with WKWebViewBrowserRuntime and device/session changes. Auditing current files would therefore describe another implementation. Working tree is extensively dirty; no existing changes were modified.

READ IN SOURCE — Checks performed: commit presence verified; release sources inspected with git show/nl and git grep; release-versus-HEAD diff inventory inspected; prior README/HANDOFF/S3 progress/probe notes read in part. One initial unquoted shell glob search failed with zsh “no matches found”; subsequent quoted git path searches supplied the intended results. No behavioral check was attempted, so none passed or failed. The native addon implementation, arbitrary evaluate script effects, and full transitive WebKit native popup behavior remain unverified.

# Pointer isolation investigation (partial)

Bench: `.worktrees/pointer-isolation`, branch `array/pointer-isolation`, base `0533e3f0`. No push, preview launch, live tile input, CGEvent posting, pointer warp, activation, standard-default writes, tmux or full matrix.

## Findings

1. **Hover theft — UNTESTED.** The engine monitor excludes passive pointer events. Real mouse tracking can therefore reach WebKit independently of direct agent delivery. The prior research reports no page mousemove/hover in its inactive off-screen probe. That is no proof of isolation or of theft. CSS hover, mouseleave dropdown and tooltip interleavings still need new behavioral witnesses.
2. **Native select tracking — UNTESTED.** Stage 1 preflight recognizes HTML selects and associated labels, including the active key target. That source inspection does not establish universal popup prevention: arbitrary callbacks, delayed/cached showPicker remain a documented gap. No new native-menu tracking experiment ran here.
3. **Down/up split — UNTESTED.** deliverClick calls down then up synchronously, but nested framework tracking can reenter. The existing experimental witness interleaves an in-tile key through NSApp.sendEvent during click and confirms immediate durable takeover. Mouse drags and clicks between down/up were not tested here; atomicity is not established.
4. **Canvas hover side effects — UNTESTED.** TileNSView forwards entered/exited to relationship hover and completion-hover hooks. Canvas residency independently samples mouseLocationOutsideOfEventStream and stamps pointer-rest liveness. Filtering NSEvents alone would not cover that reader. No browser surface-swap or runtime-state witness ran here.
5. **Real-pointer readers — UNTESTED.** Canvas residency uses the real window pointer absent its existing checks provider. wakeAgentChromeUnderPointer also samples it, but explicitly targets ManagedAgentTileNSView. BrowserAutomation direct click geometry uses the requested CSS position and view conversions. No exhaustive WebKit cursor/read audit or behavior claim.
6. **False scroll takeover — PROVEN, fixed for camera-session follow-through.** After pinch/zoom, CanvasCameraDriver.isCameraSessionActive keeps precise scroll routed to the camera even over web content. BrowserAutomation independently hit-tested it and durably revoked the browser lease. The monitor now recognizes that same camera-session condition before takeover, independent of local-monitor order. Ordinary in-tile scroll after the session still takes over. Phase-only, momentum, modifier changes and Space/Cmd pointer pans remain UNTESTED; this is not a universal scroll-routing claim.

## Witness and build evidence

Extended the existing matrix-registered `--browser-durable-takeover-check` with mounted workspace/tools/queue behavior: start a camera zoom session, send a synthetic scroll through NSApp.sendEvent over the browser, assert unchanged input generation; end the camera session and assert in-tile scroll takes over. Existing checks assert durable fencing and handback. The matrix already invokes this flag with both backend settings; no new flag or verifier was introduced. Full matrix intentionally not run.

- Initial debug build exit 0: `/tmp/pointer-build.log` (176.25s). Updated-witness build exit 0: `/tmp/pointer-red-build.log`.
- RED before production fix: `/tmp/pointer-red.log`, exit 1 at camera-follow-through assertion. This first run omitted explicit CONTINUUM_APP_SUPPORT isolation and read the dev registry during restore (including stale project records); no production state was targeted. Do not repeat that omission.
- An isolated run started before the replacement binary finished linking also failed the same assertion: `/tmp/pointer-green-0.log`. It exercised the old binary and is additional red evidence, not a green result.
- Fixed debug build actual exit 0: `/tmp/pointer-green-build.log` (53.60s).
- GREEN after confirmed build: `/tmp/pointer-final-0.log`, exit 0, default backend; `/tmp/pointer-final-1.log`, exit 0, focus-free backend. Explicit unique /tmp app-support/project dirs, ARRAY_AGENT_ID unset, TERM=xterm-256color, stdin /dev/null and `/tmp/exc-probe/noexc`; tmux disabled. No display failure requiring caffeinate retry.
- `git diff --check` passed.
- `scripts/benches.sh` ran at pickup; inventory reported 157 benches needing a look and none safe to return. This unlanded bench must remain available for the lead.

## Remaining work

The requested investigation is incomplete. Passive pointer filtering, atomic click protection and universal popup prevention have NOT been implemented. The other five hypotheses need production-path red witnesses before changes. A physical-mouse test still needs a separately authorized safe setup to verify hover/dropdown/tooltip behavior and actual trackpad phase/momentum routing; synthetic off-screen events alone cannot establish real-pointer coexistence. focusFreeInputEnabled still defaults false. No private API was added.


## Follow-up investigation (2026-11-06)

At 829fac8a, the broad isolation request remained incomplete. Two scroll mechanisms were proven and fixed. No passive-pointer filter or click-atomicity change remained in that tree. No private API or default-switch change was added.

### Hypothesis dispositions

| Hypothesis | Disposition | Evidence and limit |
| --- | --- | --- |
| 1. Hover theft | UNTESTED for real-pointer behavior | New local CSS :hover/click-open dropdown, mouseleave closure, tooltip and draggable/selection-text fixture runs through mounted production tools in both modes. Synthetic mouseMoved/leftMouseDragged go through NSApp.sendEvent and window.sendEvent at two positions; synthetic enter/exit go through NSApp. Observed events=[], hover=false, open=true in both modes; subsequent agent choice click reaches the intended option once. Thus no successful hover stimulation, no red theft witness, and no justified isolation fix. Synthetic enter/exit use trackingNumber=0, not a genuine WebKit tracking-area owner: they cannot establish real tracking-exit behavior. Native tooltip presentation was not verified. |
| 2. Native select tracking | KILLED for the tested direct activation routes; UNTESTED globally | Existing preflight check now also covers character key b on a focused select. Space, ArrowDown, Alt+ArrowDown, Enter, character typing, ref/coordinate/label clicks and select typing all refuse before the guarded native boundary in both modes. Immediate/delayed showPicker callbacks attached to refused select clicks never run. Arbitrary callbacks on other elements, cached/delayed showPicker and unrelated evaluate code are READ IN SOURCE gaps; no universal prevention is present. No actual native menu was opened. |
| 3. Down/up split | UNTESTED | Temporary page-event experiment interleaved NSApp userKey through the existing during-click seam. Page observed mousedown,mouseup,click and NO keydown. The assertion requiring page keydown after mouseup failed because there was no page keydown at all (/tmp/pointer-atomic-red.log). This is failed stimulation, not a proven product race or atomicity result. That temporary assertion was removed. Actual mouse-down/up and drag-threshold interleavings during native click remain unverified. |
| 4. Canvas hover side effects | KILLED for the synthetic fixture; UNTESTED for genuine tracking/real-pointer effects | Final fixture asserts the same live runtime identity, web-view parent, first responder and control generation after synthetic moves, drags, enter/exit and the next click. Both modes pass. READ IN SOURCE: BrowserTileNSView does not override surfaceableBody/farParkableBody (base returns nil), so generic bitmap residency does not surface its body. Completion-hover wake requires a managed-agent signal/record. These do not prove absence of every real tracking effect. |
| 5. Real-pointer readers | UNTESTED in WebKit; no direct reader found in Array browser input | READ IN SOURCE: BrowserAutomation builds clicks from requested CSS coordinates, page zoom and view conversion, not NSEvent.mouseLocation. No mouseLocation/mouseLocationOutsideOfEventStream read was found in BrowserEngine or BrowserTileNSView. Canvas residency samples the real pointer but skips browser bodies lacking surfaceableBody; wakeAgentChromeUnderPointer explicitly wakes managed-agent views. WebKit internal cursor/last-pointer behavior is not proven by this audit. |
| 6. False scroll takeover | PROVEN and fixed (two mechanisms) | Camera-session follow-through fixed in 74f4d09d. Zero-displacement phase/momentum events after camera expiry fixed in 3f8851bc. Nonzero ordinary in-tile scroll still takes over. Synthetic CG scroll phase values 1/2/4/8 map to NSEvent began/changed/ended/cancelled; momentum 1/2/3 maps to began/changed/ended. All are exercised during active camera sessions; zero-delta forms are exercised after settle in both modes. Plain-pan gesture ownership across changing hit targets and Cmd/Space chrome pans remain untested. |

### Follow-up runs and corrections

- A proposed passive filter was committed in 8d888b12 and explicitly reverted in 6963eb4f. The initial window-sendEvent spy ran before local-monitor processing; its red result was invalid as a filtering witness. A later local-monitor spy depended on unspecified monitor ordering: it passed intermittently and failed in the experimental mode. No claim of a proven passive filter survives these experiments.
- The first proposed filter build failed Swift Sendable checking when an NSEvent escaped MainActor.assumeIsolated. A later fixture build failed because its source was edited during compilation. Both were corrected; those failed builds are not final validation.
- Actual zero-delta RED: /tmp/pointer-phase-red.log, exit 1 at zero-delta scroll phase takeover. The preceding nonzero phase/momentum camera-session cases passed in that run.
- Fixed build: /tmp/pointer-phase-green-build.log, exit 0 (49.70s). Four targeted runs all exited 0: /tmp/pointer-phase-final-durable-takeover-0.log, -1.log; /tmp/pointer-phase-final-native-select-preflight-0.log, -1.log. Native boundary hook stops unsafe dispatch, including in red controls; no picker tracked the real pointer.
- Final expanded fixture build: /tmp/pointer-fixture-final-build.log, exit 0 (46.46s). Final durable-takeover runs with backend off/on: /tmp/pointer-fixture-final-0.log and -1.log, both exit 0. These include the synthetic dropdown/runtime fixture and all phase/momentum checks. No product changes followed those four native/phase runs; only fixture and documentation changes followed.
- All final runs used unique temporary app-support/project dirs, unset ARRAY_AGENT_ID, TERM=xterm-256color, /dev/null stdin, /tmp/exc-probe/noexc and disabled tmux. No display failure was classified as a product regression. No full matrix was run. Existing matrix registrations for durable-takeover and native-select-preflight already exercise both modes.

Physical-pointer coexistence, genuine tracking-area exit delivery, native tooltip lifetime, mouse drag/click interleaving within native down/up and arbitrary native-popup lifetime still require a safely isolated experiment that can actually deliver those events to WebKit. They cannot be called fixed on this evidence. Preserve this bench for continuation; no push or live-app input occurred.


## Guarded active proof prepared (not run)

See [pointer-active-launch.md](pointer-active-launch.md) for the dedicated bundle, exact one-run LaunchServices command, per-case red/green/KILLED contract, cooperative foreground restoration, watchdogs and preparation results. The candidates are check-only and default false. The inactive conclusions above remain the current behavioral evidence; no activation was performed during preparation.


## Approved active result and atomic removal (2026-11-08)

`/tmp/array-pointer-active.log`: native active/key setup passed, synthetic hover stimulus was zero, and the split-click control was KILLED: one clean agent click, no drag/selection, and one intended user click. The atomic buffering/replay candidate has been removed. No active check was rerun. The deliberate-key failure occurred with candidates=false, before any buffering could be enabled. Its event counter is under investigation separately.


Restoration follow-up: the approved active log again showed requested=false and no PID restoration before exit. No working public route has been established here. Both active check implementations now explicitly report that foreground restoration is unsupported, and no longer emit PASS/restored claims or attempt the unsuccessful cooperative handoff. No activated check was rerun.

## READ IN SOURCE: why the synthetic hover result is inconclusive

Read upstream WebKit main on 2026-11-08; this is not a source/binary version match or a traced rejecting branch on the installed framework. The approved log measured zero DOM mousemoves, not zero entries into native WebKit.

[WKWebViewMac.mm](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/mac/WKWebViewMac.mm) forwards mouseDown/up/dragged and keyDown, but has no public mouseMoved/entered/exited forwarding methods. Its simulation methods use a separate internal route. A plain synthetic mouseMoved sent to a window therefore does not recreate WebKit's real tracking delivery.

[WebViewImpl.mm](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/mac/WebViewImpl.mm) gives its primary tracking area to WKMouseTrackingObserver, an NSObject rather than the WKWebView. Its options include mouseMoved, entered/exited, cursorUpdate and inVisibleRect, normally activeInKeyWindow. The observer hit-tests for the topmost descendant before forwarding moves/enters; exits depend on its previous topmost state. mouseMoved additionally rejects ignore flags and, for a first-responder view, coordinates outside visibleRect. Making an off-screen window active/key does not put the physical pointer into those tracking areas. Which AppKit/installed-WebKit guard rejected our synthetic stimulus was not measured; attributing the result specifically to an empty visibleRect would be unjustified.

Ordinary real hover disturbance requires the physical pointer over the driven tile or crossing its boundary. Moving around an unrelated tile does not continuously deliver ordinary hover moves to this page. This is NOT an absolute “only while currently over it” guarantee: captured drags/exit state can outlive departure, and [EventHandler.cpp](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/page/EventHandler.cpp) schedules synthetic hover updates from cached last-known coordinates after layout/scroll, guarded by page visibility/activity. Modifier handling in WebViewImpl can also sample the window's real mouse location. No real-mouse interference mechanism was proven by the failed synthetic stimulus.

## Deliberate key diagnosis: check counter doubled, not the native key

The approved failure happened with candidates=false, before any atomic buffering could be enabled. The click-only case left a once-keydown listener attached to document. Replacing body did not remove it. The following key case reset the shared takeKeys variable and added a second listener, so one key could increment it twice.

The exact registration sequence was reproduced in the inactive Tier A key-window fixture at the production click seam, delivering one native NSEvent via window.sendEvent. RED `/tmp/pointer-key-counter-red.log`: actual trusted page keydowns=1, field value=q, check counter=2; exit 1. The shared probe now replaces/removes its own listener. GREEN `/tmp/pointer-key-counter-green.log`: actual=1, value=q, counter=1, unchanged after a further settling read; exit 0. Build logs `/tmp/pointer-key-counter-red-build.log` and `-green-build.log` both exit 0. This is a check bug, not a demonstrated product lost/doubled/late key. The approved log itself omitted the count; its exact numeric value was not recorded. No active run was repeated.

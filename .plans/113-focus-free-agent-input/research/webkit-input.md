# WKWebView input without the real keyboard focus

Research 2026-11-05. No product changes. Release code read at **d41dad04**; upstream WebKit source fetched from main today, so source conclusions are not a binary/version match guarantee.

## Recommendation

**GUESS (engineering recommendation):** Build the next isolated experiment around direct NSEvent delivery with `_setShouldSuppressFirstResponderChanges:YES`, and `_executeEditCommand:argument:completion:` for text operations that must survive responder loss. These are promising private APIs, not a complete solution ready to ship. Keep the agent's live view isolated from the user's responder and mouse streams; a separately rendered presentation is a candidate, not something this probe validated. A public-only implementation cannot currently claim the requested input semantics from these results.

**MEASURED:** Suppressing first-responder changes allowed a trusted click followed by trusted typing while another NSTextView remained first responder, the window was not key, and the app was inactive. This overturns any universal claim that typing always needs real AppKit focus. However, the page still reported `document.hasFocus() == false` and `input.matches(':focus') == false`; no focus event fired on the suppressed click. Pages that depend on focus semantics remain a hard case.

**MEASURED:** Explicitly making the web view first responder and then transferring ownership back to the sibling caused a trusted blur and subsequent keys stopped editing. Merely suppressing future responder requests does not repair that transition. User activity independence therefore needs isolation, not restoration after stealing focus.

## Safe setup and artifacts

**MEASURED:** Host macOS 27.0.1 (26A434), Apple Swift 6.3.3. Probes compiled with Xcode's MacOSX26.5 SDK. All files/executables are under `/tmp/focus-free-wk/`. Windows were borderless at (-20000,-20000), 800×600, accessory app, never activated and never made key. `orderFront(nil)` was used only at the off-screen coordinates; first responder was explicitly a sibling NSTextView before testing. Every printed state had app active=false and window key=false. No system event posting or pointer changes, no live tile, no tmux, no matrix, no /Applications/Array modifications.

**MEASURED:** `/tmp/exc-probe/noexc` was absent. Read the required crash memory and compiled a tiny replacement `/tmp/focus-free-wk/noexc` that clears inherited Mach exception ports before exec. All Swift builds/runs used it. This is a safety wrapper, not new verifier tooling.

**MEASURED:** Initial stalls were a probe bug: importing Darwin made zero-argument `pause()` resolve to POSIX pause rather than the Swift helper with a default argument. Sampling the process showed `__sigsuspend`. Renamed the helper `spin` and reran. Discard initial output files as input evidence. An initial SPI invocation also failed with Swift's escaping-block runtime check; corrected the function pointer type to an escaping block and reran successfully. Neither failure is a WebKit defect.

Corrected evidence: `main.swift` → `final-output.txt`; `suppress.swift` → `suppress-output.txt`; `spi.swift` → `spi-output.txt`; `hover.swift` → `final-hover-output.txt`; `timer.swift` → `timer-output.txt`; `composition2.swift` → `composition-output2.txt`; SDK compiler output `sdk27.txt`. Earlier composition run `composition-output.txt` tested after explicit responder loss. Throwaway source remains reproducible on this machine; this note does not treat the 2026-10-24 results as fresh measurements.

## 1. Input routes and focus observations

**MEASURED, ordinary WKWebView:** Direct mouseDown/mouseUp on a text field worked and produced trusted mouseover, mouseenter, mousedown, mouseup and click. It also changed the window's first responder from the sibling to WKWebView and fired trusted focus. The window remained non-key and app inactive. `document.hasFocus()` and `:focus` were false throughout. Thus an inactive window does not prevent the responder theft inside that window.

**MEASURED:** Direct keyDown after that click inserted `q`, with trusted keydown, beforeinput and input. `insertText("INS")` inserted text and fired trusted beforeinput/input. JS `document.execCommand('insertText',false,'EXEC')` did likewise. These tests were initially with WKWebView first responder; see suppression results for the unfocused case. KeyUp routing was not independently retested; the probe's key helper sends keyDown only.

**MEASURED:** JS `f.focus()` alone also moved first responder to WKWebView and fired trusted focus while document focus and the :focus selector remained false. Calling it is not a safe public bypass for AppKit focus.

**MEASURED, suppression enabled:** `_setShouldSuppressFirstResponderChanges:YES` before input kept the sibling first responder across trusted field clicks, keyDown typing, public `insertText`, JS execCommand, and JS focus. Value sequence was empty → q → qINS → qINSEXEC. Beforeinput/input were trusted; keydown was trusted. The suppressed click did not fire focus; document focus and :focus remained false. Explicit blur/focus scripting in this state did not emit focus/blur in the tested sequence.

**MEASURED:** After an ordinary focus/blur cycle and restoring the sibling, `_executeEditCommand("InsertText", "SPI")` changed value SET → SETSPI with trusted beforeinput/input while the sibling stayed first responder. The selector exists on this installed WebKit. Its completion is asynchronous; the function pointer must accept an escaping block. Tested only InsertText, not every editing command.

**READ IN SOURCE:** WKWebView.mm's `_executeEditCommand:argument:completion:` forwards to WebPageProxy::executeEditCommand. Its completion currently reports YES after the callback; do not treat that Bool as proof the DOM actually changed. Inspect page outcome. WKWebViewPrivate.h declares `_setShouldSuppressFirstResponderChanges:`; PageClientImpl::makeFirstResponder returns early when suppression is enabled.

**MEASURED:** `f.value='SET'; f.dispatchEvent(new InputEvent('input',...))` worked with sibling ownership, no focus/blur, and untrusted input. This preserves actual focus but does not reproduce keyboard, selection, native editing or trusted-event semantics. React native prototype setters, contenteditable and framework reconciliation were not retested.

**MEASURED:** WKWebView does not publicly conform to NSTextInputClient in the 26.5 Swift SDK: the static cast and replacementRange insertText overload fail to compile. It does respond at runtime to `setMarkedText:selectedRange:replacementRange:`. See the final composition addendum below. Real OS IME candidate UI, input-source switching and dead-key interpretation were not exercised because the probe must never acquire real keyboard focus. No claim of complete IME support is justified.

## 2. Activity state: where it comes from

**READ IN SOURCE:** WebPageProxy::updateActivityState rebuilds IsFocused, WindowIsActive, IsVisible and IsInWindow from PageClient answers. In mac/PageClientImplMac.mm:

- IsFocused delegates to WebViewImpl::isFocused, which compares `[view window].firstResponder` with the view, with temporary become/resign guards.
- WindowIsActive checks activeWindow.isKeyWindow or equality with NSApp.keyWindow.
- IsVisible checks window presence, hidden ancestors, window visibility and window-server occlusion (with a background-text-extraction exception).
- IsInWindow is activeWindow presence. Active view/window can be a thumbnail or move-preparation target.

**READ IN SOURCE:** Key-window, order-on/off-screen and responder transitions notify WebPageProxy to refresh those flags. DOM focused element, page focus flags and AppKit first responder are related but distinct; the measurements above demonstrate that editing can occur while the document says unfocused.

**READ IN SOURCE:** The examined private WKWebView header exposes `_inputDelegate`, but it is not an independent keyboard-focus setter. `_retainActiveFocusedState` appears in an iOS-specific region, not a demonstrated macOS mechanism. No WKPageSetFocused or independent activity setter was found in the examined current WKPage.cpp/WKPagePrivate.h; the latter exposes a testing activity-update dispatcher. This is a bounded search, not proof no internal API exists anywhere.

**GUESS:** Overriding NSView.window to return a facade, or lying from an NSWindow.firstResponder/isKeyWindow override, might influence these queries but can also corrupt coordinate, input-context and responder bookkeeping. No such facade was tested. Suppressing responder changes is narrower and has actual positive evidence; it does not force IsFocused or WindowIsActive true.

Source links: [PageClientImplMac.mm](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/mac/PageClientImplMac.mm), [WebViewImpl.mm](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/mac/WebViewImpl.mm), [WebPageProxy.cpp](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/WebPageProxy.cpp), [WKWebViewPrivate.h](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebViewPrivate.h), [WKWebView.mm](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebView.mm).

## 3. User activity mid-action

**MEASURED:** Ordinary click with sibling transfer inserted between down/up still delivered mouseup and click, but emitted blur. Following direct keyDown produced trusted keydown with no beforeinput/input and no value change. Explicit transfer between a completed click and typing had the same outcome.

**MEASURED:** With suppression from the start, calling makeFirstResponder(sibling) between down/up was a no-op because it already owned focus. Click and following typing still worked. Once the probe explicitly assigned WKWebView real ownership and then moved away again, suppression did not prevent blur and keys stopped editing.

**READ IN SOURCE (release d41dad04):** BrowserAutomation.swift deliverClick saves/restores first responder, deliverKey dispatches NSEvent to WKWebView, and requireInputControl rejects a changed userInputCount. A local monitor watches real input. This intentionally interrupts input; it cannot meet “Dylan's activity never breaks an agent run” without a different isolation policy. Saving/restoring focus is itself an observable focus cycle.

## 4. WebKit automation / safaridriver

**READ IN SOURCE:** `_WKAutomationSession` and `_WKAutomationDelegate` are private host integration APIs. The delegate permits automation and receives a request for a session/configuration. The session header exposes configuration, delegate, pairing, termination and event tagging, not a public `click`/`type` API. Protocol dispatch and process-pool wiring would need additional private integration.

**READ IN SOURCE:** WebAutomationSessionMac.mm's event-delivery loop calls `[window makeKeyAndOrderFront:nil]` then `page.makeFirstResponder()` before `[window sendEvent:event]`. It separately invokes `_simulateMouseMove:` because normal mouseMoved is not forwarded into the implementation. This source path violates the required focus policy directly. I did not instantiate a complete automation session because its measured input test could make a window key, contrary to probe rules.

**GUESS:** Private API use alone does not establish whether a developer-ID application will pass notarization. No notarization submission, restricted-entitlement determination, sandbox validation or shipping compatibility test was performed. Do not promise this route is shippable or entitlement-free. The source-level focus behavior already rules out using it unchanged.

[Automation implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Automation/mac/WebAutomationSessionMac.mm), [session header](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/_WKAutomationSession.h), [host delegate](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/_WKAutomationDelegate.h).

## 5. Hover and real-pointer interaction

**MEASURED:** public mouseMoved and private `_simulateMouseMove:` at the field produced no page events and `:hover` false in the inactive off-screen window. A direct click did produce trusted mouseover/mouseenter, so click entry is not equivalent to standalone hover support. Native tooltip display and `_simulateMouseEnter:` were not tested.

**READ IN SOURCE:** WebViewImpl::mouseMoved has ignore flags and a visible-rect guard when the view owns first responder, then forwards a move internally. Automation has a special forwarding path. These facts do not by themselves explain this off-screen failure.

**GUESS:** The page has one effective pointer hover state; mixing user and agent moves into one live page is likely to replace it rather than provide two independent cursors. No real-pointer conflict test was performed, since moving the user's pointer is prohibited and an off-screen view cannot safely reproduce a real pointer over the same view. Use an isolated input target and test actual pointer coexistence separately with explicit safe setup.

## 6. Background work and scheduling

**MEASURED:** A 10 ms interval in the off-screen hidden page increased 8→10 over two seconds. rAF stayed at 1. Public preferences.inactiveSchedulingPolicy=.none yielded 10→12; NSProcessInfo userInitiated + latencyCritical activity yielded 12→14. Neither fixed DOM timer throttling or rAF.

**MEASURED:** With .none still enabled, disabling both `_setHiddenPageDOMTimerThrottlingEnabled:` and `_setPageVisibilityBasedProcessSuppressionEnabled:` increased ticks 14→113 over two seconds (about 50/s); rAF still 1 and visibility still hidden. `_setHiddenPageCSSAnimationSuspensionEnabled:` was absent. The two private switches were combined, so this does not identify the minimum effective setting or guarantee normal frame-rate scheduling.

**READ IN SOURCE:** A clipped or zoomed tile is not inherently hidden under PageClient's visibility checks: hidden ancestors and window occlusion matter. Covered windows can be reported invisible; merely attaching an off-screen visible view did not escape hidden-page policy in the probe.

**GUESS:** Agent waits need wall-clock deadlines and observable DOM conditions, and must account for rAF-driven apps remaining frozen. Covered, minimized, detached, canvas-zoomed and scrolled-away states were not independently remeasured here. Prior snapshots were reviewed but not retested. The private timer result does not solve those cases comprehensively.

## 7. macOS 27 additions and compilation

**MEASURED:** MacOSX27.0.sdk is installed under CommandLineTools and includes WKContentWorldConfiguration, WKJSHandle and WKDOMNodeSnapshot headers. A Swift typecheck against it fails while loading Swift: SDK built with Swift 6.4, installed compiler 6.3.3. The default xcrun SDK lookup also fails; the explicit Xcode 26.5 SDK worked for probes. No product build was attempted.

**READ IN SOURCE (installed public SDK headers):** WKContentWorldConfiguration offers closed-shadow-root access and enables JS handles/node snapshots. These are useful targeting/reference capabilities, not a demonstrated public per-view keyboard or pointer driver. The new Swift surface cannot currently be adopted with this installed compiler/SDK pairing.

**VENDOR DOCS:** Safari 27 adds Safari MCP and asks users to enable remote automation/external agents in Safari. This is a Safari tool, not evidence that embedded WKWebView gained a focus-free native input API. [WebKit's Safari 27 announcement](https://webkit.org/blog/18325/webkit-features-for-safari-27-0/).

## 8. Route ranking for the next experiment

Ranking is **GUESS** (engineering preference); individual evidence cells are labeled.

| Route | Works with sibling first responder? | Trusted? | Surface | Fragility / remaining gap |
|---|---|---|---|---|
| Direct NSEvent + suppress-responder SPI | MEASURED yes, click then keyDown | MEASURED yes | Public event delivery + private suppression | Page reports unfocused; focus/blur fidelity, real responder transitions, hover and IME incomplete |
| `_executeEditCommand` InsertText | MEASURED yes after responder loss | MEASURED beforeinput/input true | Private | Text operation only; no physical key sequence; validate DOM, not completion Bool |
| `insertText` / execCommand with suppression | MEASURED yes | MEASURED beforeinput/input true | Public/legacy JS plus private suppression | No key event; other editors and selection need testing; execCommand is legacy |
| Value setter + InputEvent | MEASURED yes | MEASURED false | Public JS | Framework/native editing, focus expectations and trusted gates differ |
| Direct NSEvent without suppression | MEASURED click works but takes responder; keys stop editing after blur | MEASURED yes | Public | Violates real focus isolation in this test |
| `_simulateMouseMove` | MEASURED no events or hover in off-screen setup | Not established | Private | Not a working standalone background hover route here |
| WebKit automation event delivery | Not safely run; READ IN SOURCE makes window key/front and page responder | Not measured here | Private host/protocol API | Directly conflicts with focus requirement; notarization/entitlements unverified |

**GUESS:** Hard cases left before a shipping claim: focus-driven editors, real IME/candidates, key shortcuts/selection, native dropdowns and tooltip UI, hover under concurrent real mouse movement, rAF-only applications, multiple views/windows, cross-frame/shadow targeting and navigation-induced focus changes. Dropdown selection was not retested. Separate host input and rendered presentation remains the most useful architecture question to resolve next.

## Composition addendum

**MEASURED:** In `composition2.swift`, without ever explicitly assigning WKWebView first responder, suppression plus a trusted click/key sequence left the sibling owning focus. Runtime `setMarkedText("仮", selectedRange:1..1, replacementRange:NSNotFound)` inserted marked text and emitted trusted compositionstart, compositionupdate, beforeinput and input. `insertText("確")` replaced it and emitted trusted beforeinput/input and compositionend. App inactive, window non-key, sibling first responder, document.hasFocus=false and :focus=false throughout. This demonstrates an unfocused composition delivery path, not integration with a real input method or candidate panel.

**MEASURED:** In `composition.swift`, after explicitly assigning and then removing actual WKWebView responder ownership, setMarkedText produced neither text nor composition events. Subsequent insertText still inserted committed text with trusted beforeinput/input, without compositionend. Composition depends on more than the presence of the runtime selector.

**MEASURED:** All corrected probe processes exited; no probe executable remained running at final inspection. The task worktree stayed clean. Research output was written at the requested canonical repository path, outside this worktree; no commit or push was made.

# macOS background desktop input: Codex, Claude, Cua

Research date: 2026-11-05. Research only; no product edits, app launches, screenshots of user windows, synthetic input, tmux, or matrix runs.

Labels: **MEASURED** = observed tool output, including static binary inspection, not necessarily runtime behavior. **READ IN SOURCE** = code or bundled documentation read. **VENDOR DOCS** = vendor statement, not independently tested. **GUESS** = inference/recommendation or unresolved possibility. Outside sources are linked beside claims. Local evidence paths are supplied explicitly.

## Findings that affect the decision

- **VENDOR DOCS:** Background Mac desktop control is real product behavior in both vendors' documentation. OpenAI describes background work and Claude says macOS 15+ defaults to background windows without taking the user's pointer or keyboard. This does not establish simultaneous independent interaction with the *same* app or window. [OpenAI](https://learn.chatgpt.com/docs/computer-use), [Claude](https://support.claude.com/en/articles/14128542-let-claude-use-your-computer-in-cowork).
- **GUESS:** Preserving the physical cursor is weaker than preserving all user state. Targeted events can change a background app's internal key window, DOM focused element, selection, and scroll position. Array needs a tile-scoped input contract, not simply a second cursor.
- **READ IN SOURCE:** Earlier Array research already established the stronger in-process route: direct events to the owned WKWebView, page inspection in an isolated content world, and WebKit snapshots. Read `.plans/80-browser-computer-use/README.md`, `research/wkwebview-feasibility.md`, `research/cua.md`, `research/t3-history-and-codex-native-cu.md`, and `.plans/64-codex-computer-use-handoff.md` in the canonical repository. These are prior reports, not new runtime measurements.

## OpenAI Codex / ChatGPT on Mac

**VENDOR DOCS:** The supported experience is background scoped work on Mac, app-by-app approval, and separate Screen Recording and Accessibility grants to Codex Computer Use. Browser development tasks should prefer the built-in browser. App approvals and TCC permissions are separate controls. Windows uses foreground control instead. [Computer Use](https://learn.chatgpt.com/docs/computer-use).

**VENDOR DOCS:** The user can watch a picture-in-picture preview of the active app. OpenAI warns against two computer-use tasks in the same app simultaneously, and supports an optional Mac locked-use mode. That warning directly limits any interpretation of “user activity never breaks an agent run.” [Use your computer](https://learn.chatgpt.com/use-cases/use-your-computer-with-codex).

**MEASURED:** This Mac has `/Applications/ChatGPT.app`, whose resources contain `cua_node/lib/node_modules/@oai/sky/`. There was no separate Codex.app in the top-level /Applications listing. The package includes:

- `Codex Computer Use.app/Contents/MacOS/SkyComputerUseService`
- `Contents/SharedSupport/SkyComputerUseClient.app/.../SkyComputerUseClient`
- an installer, authorization plugin, and `CUALockScreenGuardian.app`
- `docs/sky-window2-api.md` and separate full-desktop API docs.

**READ IN SOURCE:** Bundled `sky-window2-api.md` exposes window-addressed `type_text` (current focus in that window) and coordinate-addressed scroll. A window API is different from a global pointer API, but its presence does not prove the native delivery implementation. Local path: `/Applications/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules/@oai/sky/docs/sky-window2-api.md`. Public product reference: [Computer Use](https://learn.chatgpt.com/docs/computer-use).

**MEASURED:** `strings` on SkyComputerUseService returned a Swift `SCContentFilter` reference. The initially slow combined inspection eventually completed: `nm -u` on the service imports `AXUIElementPerformAction`, `AXUIElementSetAttributeValue`, `SCContentFilter`, `SCScreenshotManager`, `SCStream` and `SCStreamConfiguration`. The client imports ScreenCaptureKit screenshot/filter classes. A separate eight-second bounded attempt timed out. These imports establish available AX mutation and capture mechanisms, but do **not** establish the per-action route or `CGEventPostToPid` / private SkyLight posting as Codex's implementation.

**GUESS:** Codex has AX mutation and ScreenCaptureKit dependencies, but its exact action ladder remains unknown in this investigation. The name “Sky” is not evidence of use of Apple's SkyLight. It would be incorrect to say Codex uses the Cua recipe merely because both offer background control. No own-cursor overlay implementation was established; the documented PiP preview is established. Covered-window capture is consistent with the SCContentFilter reference, but hidden/minimized/other-Space behavior was not measured.

## Claude Desktop

**VENDOR DOCS:** On macOS 15+, background windows are the default, the physical pointer and keyboard remain available, and Claude generally waits while the user types. Full-screen access requires permission the first time per session; a Full control setting also exists. Claude prioritizes connectors, then browser tools, then screen interaction. This is materially different from assuming every task uses the classic foreground screenshot/click loop. [Claude Help](https://support.claude.com/en/articles/14128542-let-claude-use-your-computer-in-cowork).

**MEASURED:** The installed module is `/Applications/Claude.app/Contents/Resources/app.asar.unpacked/node_modules/@ant/claude-swift/build/Release/computer_use.node`. `nm -u` imports `AXUIElementPerformAction`, `AXUIElementSetAttributeValue`, AX inspection functions, CGEvent inspection/event-tap functions, `SCScreenshotManager`, and `SCStreamConfiguration`. `otool -L` links AppKit, ApplicationServices, CoreGraphics, ScreenCaptureKit and `@rpath/libComputerUseSwift.dylib`.

**MEASURED:** Its strings include the private SkyLight framework path, `SLPSSetFrontProcessWithOptions`, and screenshot failure messages naming `SCContentFilter` and `SCScreenshotManager`.

**GUESS:** This supports a hybrid AX/capture/private-activation implementation, but imports and strings cannot show which actions execute which route. I did not establish Claude's use of `SLEventPostToPid` or public `CGEventPostToPid`, nor prove that the private activation symbol is on the background path. Covered-window capture is plausible; minimized/hidden support and cursor overlay behavior remain unverified. The installed dylib was not located in the inspected bundle tree; its code was not read. TCC control/capture grants should be treated separately from Claude's documented per-app consent; the exact installed grant attribution was not inspected.

## Public implementation evidence: Cua and focus without raising

**READ IN SOURCE:** Cua's mouse implementation explicitly prefers private `SLEventPostToPid`, with public PID posting as fallback, stamps a window-local point and window-routing fields, and distinguishes background delivery from global HID desktop clicks. Its targeted scroll implementation primes mouse tracking, stamps the target window and PID, then posts via both SkyLight and the public PID route. This is a *different recipe* from an unadorned `postToPid` scroll. It also retains legacy duplicate-delivery paths, so copying it indiscriminately risks duplicate AppKit events. [mouse.rs](https://raw.githubusercontent.com/trycua/cua/main/libs/cua-driver/rust/crates/platform-macos/src/input/mouse.rs).

**READ IN SOURCE:** Cua's SkyLight bridge dynamically resolves private symbols. Keyboard delivery attaches `SLSEventAuthenticationMessage`; the stated purpose is acceptance by Chromium-like targets. Its exact-window priming reads focus back and refuses keys when routing cannot be established. The target app's internal focused window can change even while the user's foreground app stays put. [skylight.rs](https://raw.githubusercontent.com/trycua/cua/main/libs/cua-driver/rust/crates/platform-macos/src/input/skylight.rs), [keyboard.rs](https://raw.githubusercontent.com/trycua/cua/main/libs/cua-driver/rust/crates/platform-macos/src/input/keyboard.rs).

**VENDOR DOCS:** Cua exposes a session-owned visual agent cursor separately from the user's cursor; Linux parallel drags use MPX/XI2 virtual master pointers. Its browser background mode refuses routes that would activate Chromium. Thus multi-cursor presentation and multi-input isolation are distinct features, and Linux MPX is not proof of a Mac equivalent. [Pointer/cursor/browser](https://cua.ai/docs/cua-driver/reference/mcp-tools/pointer-cursor-and-browser).

**GUESS:** A private focus-without-raise recipe is not enough for Array's requirement: “without raising” concerns window stacking, whereas frontmost process, key window and responder are separate state. `SLPSPostEventRecordTo` and `_SLPSSetFrontProcessWithOptions` should not be represented as public independent-seat APIs. This investigation did not find those symbols in the fetched current yabai `window.c`/`window_manager.c`; attributing an exact current yabai recipe remains unverified. [Inspected window source](https://raw.githubusercontent.com/koekeishiya/yabai/master/src/window.c), [manager source](https://raw.githubusercontent.com/koekeishiya/yabai/master/src/window_manager.c).

**READ IN SOURCE:** The earlier Array Cua note records that bare `postToPid` scroll was silently dropped unless frontmost. Current Cua source attempts more elaborate background scrolling, but source comments cannot overturn that measurement. **GUESS:** Keep the memory's scope narrow: it describes the tested path, not a theorem that no background scroll can ever work. No macOS 26/27 confirmation was performed. **MEASURED:** `sw_vers` here reports macOS 27.0.1, build 26A434; merely being on that OS does not verify delivery.

## Seeing covered windows

**VENDOR DOCS:** ScreenCaptureKit captures selected displays, apps or windows through content filters rather than requiring one full-screen framebuffer. [Apple WWDC22](https://developer.apple.com/videos/play/wwdc2022/10156/).

**GUESS:** Window-content capture is the relevant primitive for covered windows; it does not by itself guarantee fresh rendering from a minimized, hidden, suspended, or parked view. Treat covered, off-Space, minimized, app-hidden, and absent-from-window as separate test cases. Neither the binary evidence nor the vendor pages read here proves all of them.

## Technique comparison

**GUESS unless a source label is named:** These are engineering expectations, not newly witnessed behavior. “Trusted” has three meanings that must not be conflated: permission to control an app; OS event authentication; and a web page's `Event.isTrusted`.

| Technique | Real pointer | Foreground/key window | Trusted/acceptance | Covered / hidden | Permissions | Private API |
|---|---|---|---|---|---|---|
| AX perform action / set supported value | No physical movement | Action-specific; focus setters change target focus | Semantic AX operation, not a DOM trusted-input promise | Depends on target's live AX implementation | Accessibility cross-process | Public AX; target-dependent |
| Plain public PID event posting | Usually avoids global pointer motion | May need target key-window state; cannot assume no activation | Target-dependent; some apps drop it | Covered is possible in principle; hidden unresolved | Accessibility/control authorization | Public transport, routing reliability unresolved |
| Cua private PID route + window stamps | Background route intends no pointer movement | Can prime target app's internal key window | Cua adds authentication for keys; no universal acceptance guarantee | Source targets background windows; hidden not established here | Prior Array Cua report: Accessibility + Screen Recording | Yes; dynamic lookup does not guarantee future compatibility |
| SLPS focus/activation recipes | Not inherently pointer motion | Can change focus/front process; no-raise is insufficient | Not a general input/trust mechanism | Not a capture solution | Control permission; exact recipe-dependent | Yes, fragile undocumented contract |
| Global HID events, activate/raise, then restore | Can move/interfere; restore races user | Foreground takeover | Often accepted; still target-dependent | Must expose/activate relevant target | Accessibility; capture separately | Public posting possible |
| Owned WKWebView direct NSEvent | No system pointer necessary | Must avoid changing NSWindow first responder | Prior Array report witnessed trusted clicks/typing | Prior report saw hidden snapshots; input attachment requirements differ | No cross-process TCC for own view | Public AppKit/WebKit entry points; behavior needs witnesses |
| Owned DOM operation | No | DOM focus/selection may change | Script-dispatched events generally differ from trusted native input | Subject to page lifecycle/throttling | No cross-process TCC | Public WebKit JS execution |
| Separate VM/session | Host pointer can remain independent | Guest owns its foreground/key state | Normal guest input path | Guest display independent of host occlusion; lifecycle matters | VM/runtime-specific | Can use public virtualization; implementation-dependent |

## Consequences for Array and ranked ideas

1. **GUESS — highest value:** Keep browser driving in-process and enforce independent tile state. Do not activate Array, make its window key, pan/reveal the camera, or borrow a global input queue. Audit native dropdowns/popups and key equivalents alongside click/type/scroll; those are likely escape seams. Prior Array feasibility reports are evidence of possibility, not evidence that every current production path obeys the contract.
2. **GUESS:** Make observation and routing exact: tile identity + generation, DOM ref freshness, window-local geometry, page postconditions, and no camera change. Test user typing in another tile and in another app during each action. A “restore focus afterward” workaround has an interference interval and can steal a newer user choice.
3. **GUESS:** Borrow Cua's refusal and verification discipline for a later whole-computer phase. Prefer AX semantic operations, prove exact window routing, report unverifiable/no-op outcomes honestly, and never silently escalate to foreground. Private SkyLight delivery belongs behind a separately maintained optional compatibility layer.
4. **GUESS:** For a strong “user activity never breaks the run” promise in desktop apps, offer an isolated desktop/VM. Same-app agents share app state even with independent cursors; background targeting alone cannot make a shared document independent.
5. **READ IN SOURCE:** Earlier Array research found built-in Codex CU advertised inside managed sessions and attempts to inspect Array itself, with approval failures. Its browser backends were separate from Array's WKWebView. **GUESS:** This is a plausible contributing route, not a diagnosis of Dylan's current session. Audit effective plugin policy and tool-call provenance in the implementation stream; keep built-in whole-app CU disabled for tile automation. A whole-window tool targeting Array bypasses tile isolation and can conflict with user responders even without moving the pointer.
6. **GUESS — avoid:** Bare PID events as a universal solution; global HID plus cursor/focus restoration; private SLPS activation inside browser tools; and claiming an overlay cursor proves isolation.

## Checks, limits and reproducibility

**MEASURED:** Read-only commands used: `rg --files`, `rg -n`, `cat`, `sed`, `ls`, `sw_vers`, `/usr/bin/strings`, `/usr/bin/nm -u`, `/usr/bin/otool -L`, plus Python subprocess wrappers. No credentials, token stores or session transcripts were opened. Earlier research reports were read as historical evidence only.

**MEASURED:** One bounded Codex service symbol inspection timed out; the first combined binary-inspection process later completed successfully, adding the AX/capture evidence above. A final process check found no remaining nm/python3 process matching the search. Claude symbol inspection and both vendors' string inspection succeeded. An initial worktree-relative research lookup failed because the files are in the canonical repository. A glob for browser Input/Automation filenames matched nothing. Cua `input/scroll.rs`, yabai `process.c`, and the attempted Apple AX reference URL failed to fetch; the scroll implementation was subsequently found in `mouse.rs`. No new verifier tooling was built.

**GUESS / unverified:** Exact Codex posting API, exact per-action Claude delivery ladder, fresh capture of hidden/minimized windows, browser `isTrusted` under external routes, and background scroll on macOS 26/27 remain unresolved. Live behavioral checks were deliberately skipped under the task's no-input/no-live-tile rules. No claim in this report upgrades a source comment or a binary import into a runtime measurement.

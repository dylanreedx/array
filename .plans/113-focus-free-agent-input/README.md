# Focus-free agent input — 2026-11-05

Keep browser automation inside Array on WKWebView. First fix stale focus restoration, native dropdown handling and ownership/retry contracts without private API. Then use a throwaway prototype to determine whether WebKit can support the editors Array needs while Dylan keeps typing and moving elsewhere. Adopt only what passes, with explicit compatibility gaps. Agent work must preserve Dylan's keyboard focus, pointer and camera; deliberately entering a driven tile gives him control until he explicitly hands it back.

Labels: **MEASURED** means observed evidence in the linked report, with its limits; **READ IN SOURCE** means inspected implementation; **VENDOR DOCS** means a vendor statement; **GUESS** marks proposed design or an unverified inference. Stage requirements below are **GUESS (design)**, adopted as this plan's direction, rather than claims of implemented behavior. Release source baseline is `d41dad04` (0.7.44).

## Evidence and decisions

**READ IN SOURCE:** Browser typing saves a responder across awaits, while its restore guard notices only input inside that browser. Click and press_key also restore responders; nested menu tracking can make their synchronous appearance misleading. Ownership takeover is not durable, bare refs can be reused in a new document, and browser approvals use parent-window sheets. See [focus audit](research/focus-audit.md), [action lifetime and sharing](research/interruption-design.md), and [popup paths](research/dropdown-popups.md). **GUESS:** These are credible failure paths; they do not establish which caused Dylan's cross-tile incident.

**MEASURED:** [Session forensics](research/run-forensics.md) extracted 1,165 direct calls and 110 structured errors from **23 Claude session logs only**. Nested Codex calls were excluded. Intentional QA failures are included. Eight errors mention control change/takeover/expiry; logs cannot prove Dylan's gestures caused them. The cross-tile failure and floating dropdown have not been reproduced.

**MEASURED — separate reliability item:** Missing project/installed-tile context caused **32 failed browser opens**; **22 calls timed out**, versus eight control-change/expiry errors. These failure counts exceed focus-related symptoms in this sample; they are not counts of distinct blocked runs. **GUESS (design):** Track open-context/residency recovery and timeout diagnosis alongside this program, with explicit recovery results and no implicit fallback to another project. Focus isolation alone will not fix them.

**GUESS (decision):** Stay on WKWebView and Array's in-process input path. Do not import external desktop-control techniques from Codex, Claude Desktop or Cua; whole-computer control is a separate later opt-in. Their evidence is background context in [desktop control](research/codex-computer-use.md) and [browser architectures](research/claude-browser.md), not implementation direction here. Agent-only Chromium would test a different engine from the user's page and require maintaining two engines. Reconsider Chromium only if Stage 2 fails on editors that matter, as a whole-browser-engine decision. Bundle size, memory, helper packaging, signing, security-update and integration costs in claude-browser.md are **GUESS**, unmeasured cost notes.

## Stage 1 — public API fixes and contracts

All items are **GUESS (design)**; none requires the Stage 2 private APIs.

- Fix BrowserAutomation restoration for type, click and press_key: never restore over a focus change the action did not itself make. Cover every await and nested tracking interval. Browser-local input count is insufficient; establish provenance for responder changes. This fixes stale restoration but does not by itself prove absence of transient focus theft.
- Add a first-class select action that lists options and selects by value. Snapshots expose labels, values, selected/disabled state, groups and multiplicity; duplicate values need explicit disambiguation. Validate atomically and read back DOM **and application state** after reconciliation. Scripted input/change events are not trusted native input. Custom ARIA combobox/listbox widgets retain their widget interaction path; they are not HTML SELECTs.
- Stop agent actions opening native select menus and guarantee no agent-owned popup outlives an action. Cover ref/coordinate/label clicks, keys, frames, immediate and delayed showPicker, cancellation, navigation and teardown. Own callbacks by page/control/action identity and complete them exactly once. **READ IN SOURCE:** The popup report establishes no universal public suppression hook. **GUESS (design):** Unsupported paths must fail before dispatch; a best-effort Escape/defer is insufficient. If public APIs cannot enforce the boundary for arbitrary page behavior, record that as an unmet Stage 1 exit condition rather than claiming the guarantee.
- Preserve per-tile FIFO and one writer. Bind actions to runtime/tab/document/control epochs. User interaction inside the driven tile pauses mutations durably; explicit tile-local “Return to agent” and a fresh snapshot hand back control. Other composers, tiles, camera gestures and workspace navigation never count as takeover. Multiple agents transfer writer ownership explicitly at a quiescent boundary; readers do not alter ownership or another reader's comparison baseline.
- Qualify refs so navigation, reload, tab replacement and back/forward cannot alias an old ref to a new node. Revalidate identity, focus target and geometry at dispatch.
- Separate takeover, queue expiry, partial completion and unknown outcome. Return action identity, effects (none/partial/committed/unknown), retry guidance and snapshot requirement. Timeout after dispatch must say effects may have happened. Preserve uncertain deduplication records; same-key transport retry must not replay input. A new key is not permission to blindly repeat submit, click, append-type or evaluate.
- **Open question:** Do the window-wide domain/handover approval sheets explain an interruption Dylan encounters? If so, replace their presentation with an existing styled, tile-scoped approval surface while retaining authorization. Never silently approve to avoid a sheet.

**GUESS (witness obligation):** Stage 1 owes red-before/green-after production-path witnesses for restoration, semantic select/application state, popup lifetime, durable takeover, ref identity and result/retry semantics. It does not exit by claiming complete focus independence; that is the next gate.

## Stage 2 — throwaway compatibility gate

**MEASURED:** [WebKit probes](research/webkit-input.md) found `_setShouldSuppressFirstResponderChanges:YES` allowed trusted click/key typing while a sibling retained first responder in an inactive, non-key window. `_executeEditCommand` InsertText also edited after responder loss. However, **document.hasFocus() and :focus remained false**, and a suppressed click emitted no focus event. Ordinary focus borrowing followed by restoration emitted blur and stopped subsequent key editing. These are narrow probe results, not editor compatibility.

**GUESS (prototype):** Test suppression plus edit-command delivery in an isolated off-screen harness against a React controlled input, CodeMirror or Monaco, ProseMirror, and a custom combobox that closes on blur. Include selection, clear/replace, shortcuts, submit, rerender, navigation and composition; distinguish simulated composition from actual IME support. Test real-pointer coexistence in a safely isolated, explicitly controlled setup. Off-screen synthetic mouse events alone do not prove that case. No live Array tile or Dylan's workspace is a test target.

**GUESS (pass bar):** Every required editor workflow must update application state correctly without transient responder theft, activation, pointer/camera movement, lost real-user input, blur-induced closure, escaped popup or misdirected agent text. Exercise concurrent user input through real `NSApp.sendEvent` paths and verify throughout the action, including yields and nested loops. Verify actual DOM/editor state and event behavior, not an edit-command completion Bool. Page-reported lack of focus is the principal compatibility risk: if an editor needs real focus and fails, the prototype fails that editor. No foreground fallback or visible tile picture swap can turn failure into a pass.

**GUESS (risk framing):** Array ships Developer ID outside the App Store; private API is an OS compatibility, fragility and update risk here, rather than an App Store review risk. The probe does not establish shipping/notarization compatibility. Record supported OS behavior and fail closed when selectors or semantics change.

## Stage 3 — adopt the passing approach

**GUESS (design):** Integrate only the Stage 2 route that passed, behind availability checks and explicit capability outcomes. Keep actual page/runtime ownership independent of the mounted canvas; protect in-flight work through zone/workspace switches, parking and normal eviction. Closing a tile ends its identity; no input may continue into a replacement. Preserve bounded wall-clock waits and reconcile sleep/wake before further input.

**MEASURED:** In webkit-input.md, public `inactiveSchedulingPolicy = .none` and a process activity assertion did not fix hidden timers or rAF. With .none still enabled, jointly disabling `_setHiddenPageDOMTimerThrottlingEnabled:` and `_setPageVisibilityBasedProcessSuppressionEnabled:` raised timer ticks to roughly 50/s; **requestAnimationFrame stayed frozen**. The switches were tested together, not independently. **GUESS (design):** Adopt scoped, availability-checked scheduling controls only with production lifecycle witnesses; restore them when agent ownership ends. rAF-dependent applications remain a known gap, not a solved scheduling case.

**GUESS (design):** Show quiet ownership/activity and optional agent cursor feedback inside the tile only. Use existing Array styling and Choice components, no one-sided border/accent edge, global overlay or visible picture swap. Verify light and dark. Stage 3 owes all applicable replay cases below through the integrated production backend and every supported lifecycle state.

## Merged replay and witness inventory

**GUESS (test design):** These merge the eight recorded-workflow sequences in [run forensics](research/run-forensics.md#workarounds-and-replay-requirements) and twelve cases in [interruption design](research/interruption-design.md#required-production-path-witnesses). Recorded workflows are evidence; adding concurrent user activity is a proposed test. “1” means Stage 1 owns the contract regression; “2” the isolated backend gate; “3” integrated acceptance.

| Replay sequence | Required witness | Stage |
|---|---|---|
| Authenticated remote form: snapshot → field → type → submit → wait; user types in another composer during click or clicks it during typing | Login redirects and fresh refs work; correct submit once; every real key reaches the new composer; no transient/stale focus restore, including press_key | 1, 2, 3 |
| User pans during type; zooms during click | Agent target/effects remain correct; user's camera intent survives | 1, 2, 3 |
| Switch zone/workspace during click/type/wait | Original runtime continues without reveal or mounted-scene scope failure | 3 |
| Native select → pick → dependent request/state; user types elsewhere, interrupts before/during/between open/choose | No native popup; options/duplicate/disabled/multiple semantics and final application state correct; no API-save bypass | 1, 2, 3 |
| Custom ARIA combobox/listbox closes on blur | Real widget workflow completes without lost state or fake SELECT handling | 2, 3 |
| Numeric field: existing 1 → key 3 → Tab; then keys 1,2 → Tab | Values persist as 3 and 12; selection/key semantics preserved | 2, 3 |
| PDF print URL → coordinate click → End/PageUp/PageDown/arrows → screenshot | Actual document viewport changes; screenshot and other composer remain correct | 2, 3 |
| Long fetch/print evaluate → poll → text/screenshot, including timeout | Result distinguishes possible effects; no blind mutating retry | 1, 3 |
| Shared user-owned browser: authorize → navigate → user enters tile during type → snapshot → explicit handback | Prefix effects identified; user click/key wins; queued and new mutations stay paused; unrelated typing never revokes | 1, 2, 3 |
| User scrolls driven tile or changes tab/profile during click | Takeover/document epochs fence later input and stale geometry | 1, 3 |
| Two agents mutate one tile, with concurrent readers | One writer; unauthorized agent rejected; explicit transfer waits for quiescence; reads preserve identity/baselines | 1, 3 |
| Navigate between snapshot/click; remove/cover node; script changes field focus during text | Old ref never aliases; wrong field/node receives no remaining input | 1, 2, 3 |
| Remove browser during wait; close/evict/park at typing yields | Explicit recoverable state; no post-close input or replacement-target delivery; parking preserves supported work | 1, 3 |
| Hide/occlude/deactivate/sleep during action; real pointer moves elsewhere | No activation or pointer interference; wake reconciles deadlines; timer/rAF limits reported honestly | 2, 3 |
| Retry same key during/after expiry, timeout, takeover and restart | At most one dispatch within declared retry scope; conflicts reject; unknown stays unknown; queued expiry says no effects | 1, 3 |
| Device observe → act → observe while user works elsewhere | Simulator target/orientation and outcomes remain independent; browser changes cause no device regression | 3 |

**GUESS (verification requirement):** Production witnesses mount through `AppDelegate.mountWorkspaceSceneAtBoot`, call production tools/service/queue/backend and send user events through `NSApp.sendEvent`. Assert responder/focus broker, composer text, page values/event logs, key window, pointer, camera, epochs, queue results, popup absence and main-thread progress throughout. Use isolated QA state and disposable pages, never the live app/project. Register behavioral witnesses in the matrix and confirm each runs in its final report; source-string checks and after-the-fact focus restoration do not count. Stage 2 remains a throwaway harness experiment; its pass must be repeated through production paths in Stage 3.

## Remaining uncertainties

**GUESS / unresolved:** Public APIs have not established universal popup prevention; the Stage 2 focus-dependent editor and real-pointer gate has not run; rAF remains frozen in the measured setup. Native menu reentrancy is supported by upstream source, but the installed floating-menu failure is unreproduced. Earlier favorable focus observations and newer blur/suppression probes use different sequences and do not establish a universal guarantee. External-vendor implementation details and Chromium costs remain bounded source evidence or guesses. No new research, tooling, behavioral checks or product changes were performed while merging this plan.

## Open gaps

- Real-pointer hover can disturb a page while the physical pointer is over a driven tile; see [pointer-isolation.md](pointer-isolation.md).
- Script-opened or delayed native pickers remain unsupported.
- requestAnimationFrame may remain frozen on hidden pages.
- Monaco caret and undo remain unsupported.
- Next: investigate the 32 failed opens and 22 timeouts recorded in research/run-forensics.md.

# Browser agents without desktop input capture

Research date: 2026-11-05. Research only; no apps launched, live tiles driven, synthetic system input, builds, tmux, matrix, commits or pushes.

## Main finding

**READ IN SOURCE:** Claude Desktop's built-in browser uses Electron WebContentsView and CDP input, rather than posting mouse and keyboard events to macOS. The shipped code provides unusually direct evidence for the architecture Array wants. Source: `/Applications/Claude.app/Contents/Resources/app.asar`, version **4.4212.0**, `.vite/build/index.chunk-m4oMImJ-.js`. Outside product reference: [Anthropic built-in browser documentation](https://support.claude.com/en/articles/16607400-use-the-built-in-browser-in-claude-cowork).

**GUESS (engineering conclusion):** Array needs two distinct guarantees: input addressed to a particular page without desktop focus, and isolation from the user's changes to that same page. CDP solves much of the first; it does not give two independent DOM focus states or two simultaneous users of one document. Agent-owned tiles plus explicit takeover are still necessary.

## Claude in Chrome: actual shipped mechanism

**READ IN SOURCE:** I downloaded the published extension package, version **1.0.105**, into memory and inspected its JavaScript. This is the published package, not proof of which extension version Dylan has installed. The local Chrome code directory was access-blocked; I did not bypass that protection or open profile data. Reproduction source: [Google update endpoint for extension fcoeoabgfenejglbffodgkkbkcdhcgfn](https://clients2.google.com/service/update2/crx?response=redirect&prodversion=140.0&acceptformat=crx3&x=id%3Dfcoeoabgfenejglbffodgkkbkcdhcgfn%26uc).

**READ IN SOURCE:** In `assets/mcpPermissions---wcR9fj.js`, clicks use CDP mouse press/release, scrolling uses wheel input, typing uses key dispatch with insertText fallback. Native selects use selectedIndex plus scripted change/input events. Background operation enables focus emulation; it includes screenshot-based hidden-page drawing and temporary audio muting. A phantom cursor is a content-script overlay. Beforeunload dialogs default to dismissal unless navigation requests acceptance; other JS dialogs are tracked as open. Same-tab user interference protection was not established. `assets/sidepanel-LN-2qpM0.js` contains a captureVisibleTab path that activates the target tab and focuses its window; its reachability from each agent tool is unverified. Thus the package contains both background input and focus-taking UI paths. Source: [published package](https://clients2.google.com/service/update2/crx?response=redirect&prodversion=140.0&acceptformat=crx3&x=id%3Dfcoeoabgfenejglbffodgkkbkcdhcgfn%26uc).

**VENDOR DOCS:** Chrome's debugger transport addresses commands to a tab ID and supports the Input and Emulation domains. CDP explicitly provides simulation of an active, focused page. This separates browser target focus from desktop activation. Sources: [debugger API](https://developer.chrome.com/docs/extensions/reference/api/debugger), [focus emulation protocol definition](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Emulation.pdl), [Input API](https://chromedevtools.github.io/devtools-protocol/tot/Input/).

**GUESS (inference from those APIs):** These page-directed commands need not warp the OS pointer, activate Chrome, or redirect keys physically typed into another app. Switching away from the agent's tab need not change the target of subsequent commands. Background rendering, throttling, screenshots and popups remain separate engineering problems; focus emulation is not a blanket guarantee for all browser UI.

**VENDOR DOCS:** Claude confines multi-tab work to its tab group, and users can add tabs to that group. [Claude in Chrome](https://claude.com/claude-in-chrome).

**READ IN SOURCE:** Chrome displays an extension debugging infobar through `ExtensionDevToolsInfoBarDelegate`; cancellation invokes registered callbacks. This is browser chrome, independent of the extension's page cursor. [Chromium implementation](https://raw.githubusercontent.com/chromium/chromium/main/chrome/browser/extensions/api/debugger/extension_dev_tools_infobar_delegate.cc).

**GUESS:** The user can therefore see a debugging banner, the Claude tab group, and page-local cursor feedback while retaining the real pointer. I did not visually verify colours, current banner wording, cursor animation, or same-tab arbitration. Do not claim Claude guarantees interruption-free simultaneous interaction with the same page.

## Claude Desktop built-in browser

**VENDOR DOCS:** Cowork opens its browser in a side panel. It has separate browser state and does not require the user's normal browser; Anthropic describes it as having the same browsing capabilities as Claude in Chrome. [Built-in browser documentation](https://support.claude.com/en/articles/16607400-use-the-built-in-browser-in-claude-cowork).

**READ IN SOURCE:** The installed app creates browser panes using Electron `WebContentsView`, with sandbox and context isolation enabled and Node integration disabled. Browser pane preferences include `focusOnNavigation: false` and `disableDialogs: true`. Per-tab records contain `cdpTools`, navigation/document epochs, tool activity and background-live state. The same bundle recognizes `Claude_Browser__` tool names. Source: app.asar path/version above; [Electron WebContentsView](https://www.electronjs.org/docs/latest/api/web-contents-view).

**READ IN SOURCE:** Its CDP tools send mousePressed/mouseReleased for clicks, mouseMoved for hover, mouseWheel with deltas for scroll, `Input.insertText` for text, and paired keyDown/keyUp commands for keys. A guard runs before mouse presses and between multiple presses; the code distinguishes stopping a new action from finishing an already-held input. Chromium is supplied by Electron, so the pane is not WKWebView. Source: same shipped bundle; [Electron debugger API](https://www.electronjs.org/docs/latest/api/debugger).

**READ IN SOURCE:** I did not find `setFocusEmulationEnabled` in this main chunk. That negative search does not establish that Electron's pane needs none or that another component never sends it. I did not fully trace built-in dropdown/dialog handling or the complete MCP dispatch chain. The confirmed facts are pane construction and concrete CDP input methods, not a runtime test of every `mcp__Claude_Browser__*` action.

## Other implementations worth copying

**READ IN SOURCE:** Playwright's Chromium page initialization enables focus emulation for main frames unless default overrides are skipped. Its selectOptions implementation validates a native select, changes option selection in injected JavaScript, and emits DOM events. It does not have to open an OS select popup. These are different mechanisms: protocol input for physical-style actions, semantic DOM operations for selection. Sources: [crPage.ts](https://raw.githubusercontent.com/microsoft/playwright/main/packages/playwright-core/src/server/chromium/crPage.ts), [injectedScript.ts](https://raw.githubusercontent.com/microsoft/playwright/main/packages/injected/src/injectedScript.ts).

**READ IN SOURCE:** Puppeteer's Chromium keyboard and mouse implementation sends CDP Input commands. Its ElementHandle.select evaluates in the element's context, selects options and dispatches input/change. A select operation therefore does not imply that an automation system can drive native popup UI. Sources: [Input.ts](https://raw.githubusercontent.com/puppeteer/puppeteer/main/packages/puppeteer-core/src/cdp/Input.ts), [ElementHandle.ts](https://raw.githubusercontent.com/puppeteer/puppeteer/main/packages/puppeteer-core/src/api/ElementHandle.ts).

**READ IN SOURCE:** Chrome DevTools MCP recently changed focus emulation to occur when a page is explicitly targeted. That is a useful scope rule: merely attaching a tool should not change the behavior of every open user page. [Official changelog](https://github.com/ChromeDevTools/chrome-devtools-mcp/blob/main/CHANGELOG.md).

**VENDOR DOCS:** Vercel agent-browser now documents a Rust daemon that communicates directly with Chrome over CDP, replacing its earlier Node/Playwright dependency. Do not assume the older research's implementation details remain current. [Official changelog](https://agent-browser.dev/changelog).

**VENDOR DOCS:** Perplexity advertises background assistants and browser automation. Its public descriptions establish a product interaction model, not the exact private input plumbing. [Comet background assistants](https://www.perplexity.ai/changelog/what-we-shipped-october-3rd). **GUESS:** Calling that plumbing CDP without source would overstate the evidence.

**VENDOR DOCS:** Atlas is now documented as transitioning into ChatGPT browser-based agent work. Current ChatGPT browser documentation describes a built-in browser and an extension for existing Chromium tabs; ChatGPT agent separately offers takeover of its virtual browser. These are separate surfaces and should not be conflated with OS computer use. Sources: [Atlas transition](https://help.openai.com/en/articles/20001371), [browser documentation](https://learn.chatgpt.com/docs/browser), [agent takeover](https://help.openai.com/en/articles/11752874-chatgpt-agent). **GUESS:** None of these pages establishes Atlas's private dispatch method; I did not inspect Atlas binaries.

## CDP versus public WKWebView

**READ IN SOURCE:** Public WKWebView exposes navigation, JavaScript evaluation/content worlds, snapshots and host UI delegation. Its public header does not expose a CDP-like trusted-input dispatcher or active-page focus emulation switch. This is an API-surface finding, not proof that all focus-free AppKit event delivery is impossible. [WKWebView public header](https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKWebView.h).

**READ IN SOURCE:** WebKit internally has a substantially richer automation session: browsing-context and frame handles, mouse/keyboard interactions, interaction sequences and cancellation, element geometry, script evaluation and screenshots. This establishes that WebKit has browser-level automation machinery; it does not make that machinery a supported public API for an arbitrary shipping WKWebView embedder. [WebAutomationSession.h](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Automation/WebAutomationSession.h). The separate WebKit helper should determine access and practical constraints.

**READ IN SOURCE (prior Array research, not remeasured):** `.plans/80-browser-computer-use/research/wkwebview-feasibility.md` records direct trusted AppKit clicks followed by typing succeeding without moving a sibling text view's first responder, alongside conflicting script-focus/editing behavior. The README subsequently proposed first-responder restoration. Those observations do not establish a public per-page focus-emulation contract or race-free coexistence with user typing. The earlier research and `.plans/64-codex-computer-use-handoff.md` were read as background; no probes were repeated.

## Chromium option and recommendation

**READ IN SOURCE:** CEF exposes browser-host key, mouse and wheel delivery and DevTools methods, enabling protocol control without launching external Chrome. [CEF browser host header](https://raw.githubusercontent.com/chromiumembedded/cef/master/include/cef_browser.h). **GUESS:** This supplies the architectural primitive Array lacks publicly in WKWebView, but still requires witnesses for hidden rendering, focus, dialogs and user coexistence.

**GUESS (cost assessment):** Embedding CEF makes Array responsible for shipping a Chromium framework, resources and subprocess helpers; expect a material bundle/download increase and additional renderer/GPU memory. Exact size and RAM depend on build, architectures and page workload and were not measured. Signing/notarization must cover the nested framework and helpers; Chromium security updates become Array release work. Supporting both engines doubles browser integration, profile, permission, download and automation testing. The [CEF build distribution](https://cef-builds.spotifycdn.com/index.html) and [official repository](https://github.com/chromiumembedded/cef) show a separately distributed engine, not a small Swift input adapter.

**GUESS (recommendation):** Do not add CEF only for agents while keeping user tiles on WebKit: that violates the supplied one-engine rule and makes the tested page different from the user's page. First await the WebKit helper's evidence. If public WKWebView cannot meet the hard no-focus/no-interference contract, choose an explicit whole-browser-engine migration to Chromium, with CEF as a candidate. Do not describe focus borrowing plus restoration as meeting that contract: a transient focus transfer can still intercept a user's keystroke.

## Concrete design ideas

All items below are **GUESS (recommendations inferred from the evidence above)**.

- Copy target-addressed commands and page-local input state; never use the global pointer, global key stream or camera reveal as an input prerequisite.
- Keep agent-owned tiles separate from user activity. Viewing another tile must not revoke the agent's lease; clicking its actual page should trigger explicit takeover or an input shield. Two actors editing one DOM cannot be made independent by focus emulation alone.
- Copy semantic native-select operations with clear event semantics. Avoid opening native menus just to select a value. Custom JS dropdowns still require their real widget interaction path.
- Copy page-local phantom cursor and ownership indication. The real mouse must remain Dylan's.
- Scope focus emulation/liveness overrides to leased pages; remove them at lease end. Retain per-target audio policy, eviction protection and hidden rendering checks.
- Treat dialogs as per-page tool state. Expose pending dialog type and bounded accept/dismiss operations; do not present a blocking host-window sheet during unattended input.
- Serialize each target's actions; maintain explicit key/button state and cancellation cleanup. Revalidate document generation and target geometry before committing a click.
- Avoid hidden fallbacks that activate windows or tabs to capture screenshots. Return a specific unsupported/temporarily unavailable result when the no-focus contract cannot be met.
- Verify the contract while a separate text view receives user input, the pointer stays fixed, camera stays fixed, the target is offscreen, and a different app is active. A check that restores focus afterward cannot witness absence of transient theft.

## Verification limits

**MEASURED:** Read-only package inspection and HTTP retrieval succeeded. Local Chrome folder listing failed with `Operation not permitted`. An initial Playwright injectedScript URL returned 404; the relocated `packages/injected/src/injectedScript.ts` succeeded. The old CEF wiki URL returned 404; the repository/header sources succeeded instead. Requested output-file creation succeeded.

**MEASURED:** No behavioral input checks were run, intentionally. Same-tab simultaneous user input, minimized Chrome, native popup interaction, complete Claude Desktop MCP dispatch, exact CEF bundle/RAM costs and render appearance remain unverified. No new verifier tooling was built.

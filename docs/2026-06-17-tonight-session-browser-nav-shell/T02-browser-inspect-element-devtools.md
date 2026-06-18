# T02 — WKWebView Web Inspector developer enablement

Status: implementation-ready
Tag: tonight [browser] [developer-tools]
Depends on: —

## Goal
Replace the vague “Open DevTools / Inspect Element” browser ticket with the public WKWebView-supported path: make embedded browser webviews inspectable only when an explicit developer preference is enabled, and document that users open Safari Web Inspector from Safari’s Develop menu.

## Implementation decision
Continuum is WKWebView-backed. Public API supports `WKWebView.isInspectable`; it does **not** provide a reliable public app API to programmatically open Safari Web Inspector for a specific webview or inspect an element at a click point.

Implement this ticket as:
- `BrowserInspectionPolicy` resolving an explicit developer opt-in;
- `BrowserEngineContext.makeWebView(storageGroupId:)` applying `webView.isInspectable` behind availability and policy;
- deterministic app check proving default-off and opt-in behavior.

Do **not** implement Chromium/Electron DevTools, embedded DevTools panels, detached DevTools windows, or right-click inspect-at-point in this ticket.

## Scope
- `Sources/ContinuumRevivedCore/` or `Sources/ContinuumRevived/BrowserEngine/`
  - add `BrowserInspectionPolicy` with default-off resolution.
- `Sources/ContinuumRevived/BrowserEngine/BrowserEngineContext.swift`
  - accept/resolve the policy;
  - set `webView.isInspectable` only when enabled and available.
- `Sources/ContinuumRevived/App/TileSpawner.swift`
  - also apply `BrowserInspectionPolicy` to `spawnBrowserForNewWindow`, because that path creates a child `WKWebView(frame:configuration:)` directly and bypasses `BrowserEngineContext.makeWebView`.
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
  - add app flag `--browser-inspection-policy-check`.
- Optional docs/help copy near browser docs if there is an existing developer settings/help surface.

## Out of scope / non-goals
- No “Open DevTools” command that claims to open Safari Web Inspector directly.
- No “Inspect Element” context menu.
- No custom DOM hit-testing tool.
- No Chromium/Electron security settings; this app is not Electron.
- No default production inspectability.

## Product / UX policy
Policy defaults:
- Default: `isInspectable == false`.
- Enable only via explicit developer opt-in, e.g. UserDefaults key `continuum.browser.webInspectorEnabled` and/or env var `CONTINUUM_BROWSER_WEB_INSPECTOR=1` for QA.
- Label any UI/help honestly: “Enable Safari Web Inspector for browser tiles,” not “Open DevTools.”
- Manual instructions: with Safari Develop menu enabled, inspect the Continuum webview from Safari → Develop.

Security policy:
- Do not leave `webView.isInspectable = true` hardcoded in production.
- T04 password/autofill work must assume inspectability is off by default; if a developer enables it, docs must warn that Web Inspector can inspect DOM/storage/network and execute scripts in page context.

## Acceptance criteria
- [ ] `BrowserEngineContext.makeWebView` no longer hardcodes `webView.isInspectable = true`.
- [ ] Default policy creates non-inspectable webviews.
- [ ] Explicit opt-in creates inspectable webviews on supported macOS/WebKit versions.
- [ ] `target=_blank` child webviews created by `TileSpawner.spawnBrowserForNewWindow` follow the same inspection policy as normal browser webviews.
- [ ] Unsupported OS versions degrade safely without crash.
- [ ] User-facing/dev-facing wording says Safari Web Inspector must be opened manually.
- [ ] No code path claims to programmatically open Web Inspector or inspect at point.

## Nightly QA contract
Required app flag:

```bash
swift run continuum-revived --browser-inspection-policy-check
```

Required regression flags:

```bash
swift run continuum-revived --browser-url-focus-check
swift run continuum-revived --browser-ui-delegate-check
```

Required artifact:

```text
qa-runs/<timestamp>/browser-inspection-policy/manifest.json
```

Manifest fields:

```json
{
  "check": "browser-inspection-policy",
  "supportsInspectableAPI": true,
  "defaultInspectable": false,
  "optInInspectableWhenSupported": true,
  "optInAttemptDidNotCrash": true,
  "targetBlankChildInspectableFollowsPolicy": true,
  "unconditionalInspectableAssignments": [],
  "programmaticInspectorOpenAPIs": [],
  "defaultSource": "defaults/env",
  "manualSafariDevelopVerification": "PENDING"
}
```

Manual verification, marked PENDING unless performed:
- On macOS 13.3+ with Safari Develop menu enabled, run with `CONTINUUM_BROWSER_WEB_INSPECTOR=1` and confirm the page appears under Safari → Develop.
- Run without opt-in and confirm it does not appear / active inspection closes after disable.

Reviewer rejection rules:
- Reject if the ticket reintroduces `webView.isInspectable = true` as an unconditional default.
- Reject if the action label says “Open DevTools” but only toggles inspectability.
- Reject if the implementation uses private APIs, AppleScript, or UI scripting to control Safari Web Inspector.

## Stop conditions
Stop / do not mark Done if:
- a public API for programmatic open/inspect-at-point cannot be cited and the implementation tries anyway;
- the app check cannot distinguish default-off from opt-in;
- inspectability is enabled for password/autofill tests without an explicit warning and redaction plan;
- artifact omits OS availability/default policy evidence.

## Verification commands

```bash
swift build
swift run ContinuumRevivedCoreChecks
swift run continuum-revived --browser-inspection-policy-check
swift run continuum-revived --browser-url-focus-check
swift run continuum-revived --browser-ui-delegate-check
```

## Research sources
- Apple `WKWebView.isInspectable`: https://developer.apple.com/documentation/webkit/wkwebview/isinspectable
- WebKit “Enabling the inspection of web content in apps”: https://webkit.org/blog/13936/enabling-the-inspection-of-web-content-in-apps/
- Research artifact: `.pi/agent-runs/web-research-20260618T014546Z-7952f3/final.md`

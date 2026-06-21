# T03 — Browser Inspector console log bridge

Status: implementation-ready, depends on T01

## Goal
The Inspector Tile Console panel shows console messages from the linked browser tile without requiring Safari.

## Implementation decision
Inject a logging bridge into browser pages that wraps `console.log/info/warn/error/debug` and forwards structured log events to the app. First slice is display-only: no arbitrary JS evaluation.

## Scope
- Capture console level, message text, timestamp, URL if available.
- Display newest 500 messages in Console panel.
- Clear button clears panel buffer for that inspector/browser relationship.
- Redact obvious secrets before writing artifacts.

## Out of scope
- Arbitrary JS eval prompt.
- Breakpoints.
- Source maps.
- Persisting console logs across app restarts.

## Code seams
- `WKWebViewBrowserRuntime` / `BrowserEngineContext` for user script + message handler.
- `BrowserTileNSView` to expose console event stream.
- `BrowserInspectorTileNSView` Console panel.
- `SecretRedactor` from credential work.

## JS bridge sketch

```js
(function() {
  if (window.__continuumConsoleBridgeInstalled) return;
  window.__continuumConsoleBridgeInstalled = true;
  const levels = ['log', 'info', 'warn', 'error', 'debug'];
  for (const level of levels) {
    const original = console[level];
    console[level] = function(...args) {
      try {
        window.webkit.messageHandlers.continuumConsole.postMessage({
          level,
          args: args.map(a => String(a)).join(' '),
          href: location.href,
          ts: Date.now()
        });
      } catch (_) {}
      return original.apply(console, args);
    }
  }
})();
```

## Deterministic checks
Add app flag:

```text
--browser-inspector-console-check
```

It must load a real WKWebView page that emits log/warn/error and verify:
- events reach app buffer;
- panel can clear buffer;
- max buffer cap enforced;
- secrets are redacted in artifact.

## QA artifact

```text
qa-runs/<timestamp>/browser-inspector-console/manifest.json
```

Required fields:
- `realWKWebViewMessageHandler: true`
- `levelsCaptured: ["log", "warn", "error"]`
- `bufferCap: 500`
- `clearWorked: true`
- `artifactSecretFree: true`

## Stop conditions
Stop if adding the message handler conflicts with existing WebKit delegates or content worlds. Do not implement eval as workaround.

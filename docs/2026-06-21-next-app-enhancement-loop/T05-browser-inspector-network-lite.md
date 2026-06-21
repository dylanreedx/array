# T05 — Browser Inspector Network-lite request log

Status: conditional implementation-ready, depends on T01

## Goal
The Inspector Tile Network panel shows a useful, honest request/navigation log for the linked browser tile.

## Implementation decision
Implement Network-lite using app-observable WebKit delegate events and navigation/resource policy hooks already available. Do not claim full Chrome DevTools Network parity.

## Scope
- Capture main-frame navigation start/commit/finish/fail.
- Capture target-blank child creation events if already observable.
- Capture downloads if existing download delegate emits events.
- Show method as `unknown` unless known; do not fake HTTP method/status if WebKit does not expose it.

## Out of scope
- Full subresource waterfall.
- Response bodies/headers.
- Timing breakdown.
- Request replay.

## Code seams
- `WKWebViewBrowserRuntime`
- existing browser delegates/checks for auth/download/target blank
- `BrowserInspectorTileNSView` Network panel

## Data model

```swift
struct BrowserNetworkLiteEvent: Codable, Equatable {
    var id: UUID
    var tileId: UUID
    var kind: String // navigationStarted, committed, finished, failed, downloadStarted, childOpened
    var url: String
    var timestamp: Date
    var statusCode: Int? // nil unless known
    var errorDescription: String?
}
```

## Deterministic checks
Add app flag:

```text
--browser-inspector-network-lite-check
```

It must load a real data URL or local fixture page and verify main navigation events are captured in order. If using local HTTP server is already available, capture a successful http navigation and one failing navigation.

## QA artifact

```text
qa-runs/<timestamp>/browser-inspector-network-lite/manifest.json
```

Required fields:
- `mainNavigationStarted: true`
- `mainNavigationFinishedOrCommitted: true`
- `unsupportedSubresourceWaterfallDocumented: true`
- `noFakeStatusCodes: true`

## Stop conditions
Stop if implementation starts inventing method/status/header data. The panel must label unknown fields honestly.

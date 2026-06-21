# T02 — Browser Inspector DOM tree snapshot and element highlight

Status: implementation-ready, depends on T01

## Goal
The Inspector Tile Elements panel shows a DOM tree snapshot for the linked browser tile and can highlight a selected element in the browser tile.

## Implementation decision
Use safe JavaScript evaluation in the linked `WKWebView` to collect a bounded DOM snapshot. Do not use private WebKit inspector APIs.

Snapshot model:

```swift
struct BrowserDOMNodeSnapshot: Codable, Equatable, Identifiable {
    var id: String        // stable-ish generated path, e.g. "0/1/3"
    var tagName: String
    var nodeName: String
    var idAttribute: String?
    var className: String?
    var textPreview: String?
    var childCount: Int
    var depth: Int
}
```

Limit snapshot to max 800 nodes and max depth 32.

## Scope
- Elements panel renders tree rows with tag/id/class/text preview.
- Refresh button collects DOM snapshot from linked browser runtime.
- Selecting a row highlights the element in the browser tile for 1500ms using an injected overlay.
- Artifact proves real WKWebView path, not static fixture only.

## Out of scope
- Editing DOM.
- CSS box model visualization.
- Shadow DOM deep support beyond best-effort note.
- iframe cross-origin DOM inspection.

## Code seams
- `BrowserTileNSView` — expose safe QA/product hook to evaluate JS for inspector.
- `WKWebViewBrowserRuntime` — may need async JS eval wrapper.
- `BrowserInspectorTileNSView` — Elements panel UI.
- `TileSpawner` app check infrastructure.

## JavaScript sketch

```js
(() => {
  const maxNodes = 800;
  const maxDepth = 32;
  const out = [];
  function pathFor(parentPath, index) { return parentPath === '' ? String(index) : parentPath + '/' + index; }
  function walk(node, depth, path) {
    if (out.length >= maxNodes || depth > maxDepth) return;
    if (node.nodeType !== Node.ELEMENT_NODE) return;
    const el = node;
    out.push({
      id: path,
      tagName: el.tagName.toLowerCase(),
      nodeName: el.nodeName,
      idAttribute: el.id || null,
      className: el.className || null,
      textPreview: (el.innerText || '').trim().slice(0, 80),
      childCount: el.children.length,
      depth
    });
    Array.from(el.children).forEach((child, i) => walk(child, depth + 1, pathFor(path, i)));
  }
  walk(document.documentElement, 0, '0');
  return JSON.stringify({ nodes: out, truncated: out.length >= maxNodes });
})()
```

Highlight sketch:

```js
(() => {
  const path = "$NODE_PATH".split('/').map(Number).slice(1);
  let el = document.documentElement;
  for (const i of path) el = el?.children?.[i];
  if (!el) return false;
  const r = el.getBoundingClientRect();
  // create fixed overlay div with pointer-events none; remove after timeout
  return true;
})()
```

## Deterministic checks
Add app flag:

```text
--browser-inspector-dom-tree-check
```

Must load a real data URL in WKWebView with nested elements, spawn inspector, refresh DOM, select known node, and verify:
- snapshot includes expected tags/classes/text;
- node cap metadata exists;
- highlight JS returns true for selected node;
- missing/deleted linked browser yields disconnected panel, not crash.

## QA artifact

```text
qa-runs/<timestamp>/browser-inspector-dom-tree/manifest.json
```

Required fields:
- `realWKWebViewEvaluated: true`
- `nodeCount`
- `truncated`
- `expectedNodeFound: true`
- `highlightReturnedTrue: true`
- `crossOriginIframeSupport: "out-of-scope"`

## Stop conditions
Stop if JS evaluation cannot safely target the live browser tile without exposing arbitrary eval to users. Do not add a user-facing JS console in this ticket.

# T04 — Browser Inspector computed styles panel

Status: implementation-ready, depends on T02

## Goal
Selecting an element in the Elements panel shows useful computed CSS properties in a Styles panel.

## Implementation decision
Use the DOM node path from T02 and JavaScript `getComputedStyle` to return a whitelist of properties. Do not attempt full DevTools CSS editing.

## Scope
- Add Styles panel data model.
- On selected DOM node, fetch computed styles for whitelisted properties.
- Show layout summary: bounding rect, display, position, size, margin, padding, color, background, font.
- Empty state if no element selected.

## Out of scope
- Editing CSS.
- Matched rules/source locations.
- Pseudo-elements.

## Property whitelist
At minimum:

```text
display, position, width, height, margin-top/right/bottom/left,
padding-top/right/bottom/left, color, background-color,
font-family, font-size, font-weight, line-height, z-index, overflow
```

## Code seams
- Shared inspector JS helper from T02.
- `BrowserInspectorTileNSView` Styles panel.
- App check in `TileSpawner` or `ContinuumApp`.

## Deterministic checks
Add app flag:

```text
--browser-inspector-styles-check
```

It must load a real page with known inline styles, select a known DOM node, and verify computed style values match expected normalized values.

## QA artifact

```text
qa-runs/<timestamp>/browser-inspector-styles/manifest.json
```

Required fields:
- `selectedNodeFound: true`
- `computedStyleFetched: true`
- `expectedColorMatched: true`
- `expectedDisplayMatched: true`
- `styleEditing: "out-of-scope"`

## Stop conditions
Stop if T02 node identity is too unstable for style lookup; fix T02 identity before adding styles.

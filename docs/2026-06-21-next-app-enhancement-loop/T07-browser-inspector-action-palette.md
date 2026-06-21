# T07 — Palette/menu actions for in-app inspector

Status: implementation-ready, depends on T01 and T06

## Goal
Users can discover and open the in-app inspector from the keyboard/action system without remembering hidden UI.

## Implementation decision
Add actions to existing tile action/palette infrastructure. Do not add a global sidebar or new command system.

## Scope
- Browser tile action: `Open Inspector Tile`.
- Global palette action when focused tile is browser: `Open Inspector for Focused Browser`.
- Inspector tile action: `Reveal Inspected Browser`.
- Settings copy clarifies Safari Web Inspector vs Continuum Inspector Tile:
  - Safari Web Inspector setting remains for advanced native WebKit inspection.
  - Continuum Inspector Tile opens inside Continuum and has limited Elements/Console/Styles/Network-lite panels.

## Out of scope
- Replacing Safari Web Inspector setting.
- Arbitrary JS console.

## Code seams
- `TileActionCatalog`
- `LaunchPaletteModel`
- `SettingsSchema` / settings UI text
- `ContinuumApp.handlePaletteAction` or equivalent

## Deterministic checks
Add/extend palette checks to verify actions appear only in correct focus contexts and invoke the same spawn/reveal path as T06.

## QA artifact

```text
qa-runs/<timestamp>/browser-inspector-actions/manifest.json
```

Required fields:
- `browserActionVisible: true`
- `nonBrowserActionHidden: true`
- `focusedBrowserPaletteActionWorked: true`
- `settingsCopyDistinguishesSafariAndContinuumInspector: true`

## Stop conditions
Stop if action plumbing requires broad palette redesign.

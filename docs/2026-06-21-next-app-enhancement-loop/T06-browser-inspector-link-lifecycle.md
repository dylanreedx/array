# T06 — Inspector/browser link lifecycle and focus behavior

Status: implementation-ready, depends on T01–T03

## Goal
Make the inspector tile relationship feel intentional: focus, deletion, duplication, and browser reload behavior are deterministic.

## Implementation decision
Keep narrow one-way relationship: inspector tile references browser tile. Browser tile does not own inspector tile. Multiple inspectors may inspect the same browser tile only if this falls out naturally; otherwise prevent duplicates for this slice.

## Scope
- If browser tile is deleted, inspector tile is deleted/closed automatically.
- If browser tile is duplicated/restored, inspector remains linked to original tile id only.
- Inspector header includes `Reveal browser tile` button that pans/focuses linked browser tile.
- Browser tile context/action menu includes `Open Inspector Tile`.
- If an inspector already exists for that browser tile, focus/reveal existing inspector instead of creating duplicate.

## Out of scope
- Generic connected tile graph.
- Bidirectional deletion cascade.
- Multiple synchronized inspectors for one browser tile.

## Deterministic checks
Add app flag:

```text
--browser-inspector-link-lifecycle-check
```

Verify:
- open inspector twice focuses existing tile;
- reveal browser changes focus/viewport to browser tile;
- deleting browser deletes/closes inspector;
- reloading browser updates header URL/title when events arrive;
- app restart preserves link.

## QA artifact

```text
qa-runs/<timestamp>/browser-inspector-link-lifecycle/manifest.json
```

Required fields:
- `duplicateInspectorPrevented: true`
- `revealBrowserWorked: true`
- `deleteBrowserDeletedInspector: true`
- `restartPreservedLink: true`

## Stop conditions
Stop if lifecycle requires broad focus/camera rewrites. Use existing focus/reveal APIs only.

# T01 — Browser Inspector Tile shell and persistence

Status: implementation-ready after Dylan accepts the narrow relationship model

## Goal
Add a first-class in-app Browser Inspector Tile that can be opened for a specific browser tile and persists its relationship across app restarts.

## Implementation decision
Do **not** build generic connected tiles. Add a narrow, explicit relationship:

```swift
struct BrowserInspectorState: Codable, Equatable {
    var inspectorTileId: UUID
    var inspectedBrowserTileId: UUID
    var selectedPanel: BrowserInspectorPanel
    var createdAt: Date
    var updatedAt: Date
}

enum BrowserInspectorPanel: String, Codable {
    case elements
    case console
    case styles
    case network
}
```

Persistence can live in the existing workspace/browser state store if that is simplest, but it must be typed and testable. If adding `TileKind.browserInspector` is too invasive, implement as a normal tile with metadata marker `inspectorForBrowserTileId` only if the codebase already supports metadata-driven tile variants cleanly.

## Scope
- Add inspector tile representation.
- Add basic `BrowserInspectorTileNSView` with header:
  - inspected tile title/url if available;
  - disconnected state if missing;
  - panel segmented control: Elements / Console / Styles / Network.
- Persist and restore inspector tile relationship.
- No DOM/console/network functionality yet; panels may show empty placeholders.

## Out of scope
- Safari/WebKit native inspector embedding.
- Generic connected tile graph.
- JS evaluation console.
- Network capture implementation.

## Code seams
Likely files/symbols:
- `Sources/ContinuumRevivedCore/BrowserState.swift`
- `Sources/ContinuumRevivedCore/CanvasCommand.swift`
- `Sources/ContinuumRevivedCore/TileAction.swift`
- `Sources/ContinuumRevivedCore/TileActionCatalog.swift`
- `Sources/ContinuumRevived/App/TileSpawner.swift`
- `Sources/ContinuumRevived/Canvas/CanvasNSView.swift`
- new: `Sources/ContinuumRevived/Canvas/BrowserInspectorTileNSView.swift`

## UX policy
- Title: `Inspector — <browser title or hostname>`.
- If inspected browser tile is deleted: delete/close the inspector tile automatically as part of the same lifecycle operation.
- Default selected panel: Elements.
- Inspector tile minimum size: 520×360.

## Pseudo-code

```swift
func spawnInspector(for browserTileId: UUID) throws -> Tile {
    guard canvasState.tile(id: browserTileId)?.kind == .browser else { throw notBrowser }
    let inspectorTile = Tile(kind: .browserInspector, metadata: .init(inspectedBrowserTileId: browserTileId))
    canvas.add(inspectorTile, near: browserTile)
    saveCanvas()
    return inspectorTile
}
```

## Deterministic checks
Add app flag:

```text
--browser-inspector-tile-shell-check
```

It must verify:
- browser tile can spawn inspector tile;
- inspector tile persists across save/load;
- selected panel persists;
- deleted browser tile deletes/closes its inspector tile, not crash;
- no Safari/WebInspector/private API is called.

## QA artifact
Write:

```text
qa-runs/<timestamp>/browser-inspector-tile-shell/manifest.json
```

Required fields:
- `spawnedForBrowserTile: true`
- `relationshipPersisted: true`
- `panelSelectionPersisted: true`
- `deletedBrowserDeletesInspector: true`
- `usesNativeSafariInspector: false`

## Stop conditions
Stop without committing if adding a tile kind requires a broad schema migration touching unrelated tile systems. Write a handoff with the smallest viable alternative.

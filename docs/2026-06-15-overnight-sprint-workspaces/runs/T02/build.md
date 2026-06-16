Task: T02 — Group-zone tile storage in the workspace store
Builder: cheap implementation model (claude-sonnet-4-6)
Branch: overnight/workspaces-zones

## Summary

Added `GroupZoneTiles` struct and `groupZoneTiles: [GroupZoneTiles]` field to `WorkspaceDocument`, with explicit `Codable` conformance using `decodeIfPresent ?? []` for backward compatibility, plus `tiles(forZone:)` and `setTiles(_:forZone:)` accessors. Added 8-assertion Core check block in `ContinuumRevivedCoreChecks/main.swift` driving the real `WorkspaceStore` persistence path.

## Files touched

- `Sources/ContinuumRevivedCore/WorkspaceDocument.swift` — added `GroupZoneTiles` struct; added `groupZoneTiles` field + defaulted init param; replaced synthesized `Codable` with explicit `Codable` extension using `decodeIfPresent ?? []`; added `tiles(forZone:)` and `setTiles(_:forZone:)` accessors.
- `Sources/ContinuumRevivedCoreChecks/main.swift` — added `// MARK: - Group-zone tile storage (T02)` block (8 assertions) between `WorkspaceStore` and `DefaultWorkspaceMigration` MARKs.

## git diff --stat

```
Sources/ContinuumRevivedCore/WorkspaceDocument.swift   |  56 ++++++-
Sources/ContinuumRevivedCoreChecks/main.swift          | 175 +++++++++++++++++++++
2 files changed, 229 insertions(+), 2 deletions(-)
```

## RED output (compile failure — missing members)

```
error: value of type 'WorkspaceDocument' has no member 'setTiles'
error: value of type 'WorkspaceDocument' has no member 'tiles'
error: value of type 'WorkspaceDocument' has no member 'groupZoneTiles'
```
(6 compile errors in main.swift referencing the not-yet-implemented API — confirmed RED before any implementation)

## GREEN output

```
Build complete! (7.12s)
ContinuumRevivedCoreChecks passed
```
All 8 assertions passed.

## Fast matrix result

```
Fast matrix passed.
```

## Deviations from spec

None. All 8 assertions implemented exactly as specified. Equatable stays synthesized (not hand-written) — the new `groupZoneTiles` field is automatically included. Schema version not bumped (T01 already set it to 2; this is a decode-optional addition). No SettingsSchema change (no new binding introduced — T08 owns group defaults). No ProjectStore/CanvasState/Tile/runtime/AppKit files touched.

## Self-assessment against Acceptance criteria

- [x] `WorkspaceDocument.groupZoneTiles: [GroupZoneTiles]` exists; `GroupZoneTiles` reuses existing `Tile` model (no new tile fields, no `tile.zoneId`).
- [x] Group-zone tiles round-trip through `WorkspaceStore.save`/`.load` (real disk path), equal and order-preserved, with zone-local frames intact (assertion 2: `t1.frame.x == 40`).
- [x] A project zone has no `groupZoneTiles` entry; no `ProjectStore` canvas written by workspace save (isolation assertions 3a, 3b, 4c).
- [x] A v2 workspace doc with no `groupZoneTiles` key decodes to `[]` (assertion 5, full AtomicWriter path via `store.load()`).
- [x] `setTiles` upserts (no duplicate zone rows — assertion 7) and an empty list removes the entry (assertion 6).
- [x] No ProjectStore/CanvasState/Tile/runtime/AppKit files touched; no SettingsSchema change.
- [x] Fast matrix green.
- [ ] Commit `feat(zones): group-zone tile storage in the workspace store` — left for orchestrator per instructions (do NOT git add/commit).

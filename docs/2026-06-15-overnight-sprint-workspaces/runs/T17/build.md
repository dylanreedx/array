## T17 Build Summary

**Status:** GREEN — all checks pass, matrix clean.

### Files touched
- `Sources/ContinuumRevivedCore/LaunchPaletteModel.swift` — added `LaunchPaletteAction.jumpToZone(UUID)` + `.createZone`, `JumpZoneRow` struct, `LaunchPaletteRow.jumpToZone(JumpZoneRow)` with all arms, `makeRows(jumpZones:)` parameter and append order.
- `Sources/ContinuumRevivedCore/WorkspaceDocument.swift` — added `appendGroupZone(name:zoneId:defaultSize:gap:color:)` mirroring `appendProjectZone`.
- `Sources/ContinuumRevivedCore/DefaultGroupZoneName.swift` — NEW file: `DefaultGroupZoneName` resolver (`userDefaultsKey = "continuum.zone.defaultGroupName"`, `fallback = "Zone"`, `.resolve()` reads `UserDefaults.standard`).
- `Sources/ContinuumRevivedCore/SettingsSchema.swift` — added `DefaultGroupZoneName` `.text` field in General section.
- `Sources/ContinuumRevived/App/LaunchProfilePalette.swift` — added `jumpZones` param to `show(...)`, `.jumpToZone` arms to `selectedDisplayNameForQA`, `tableView(_:viewFor:row:)`, and `commitSelection()`; added `filteredDisplayNamesForQA` QA accessor.
- `Sources/ContinuumRevived/App/ContinuumApp.swift` — added `--palette-zone-check` arg dispatch, `jumpZones` wiring in `openProfilePalette`, `.jumpToZone`/`.createZone` arms in `performPaletteAction`, `jumpToZoneFromPalette`, `firstTileInZone` helper, `createGroupZoneFromPalette`, `navSelectedZoneIdForQA` QA accessor, and `runPaletteZoneSelfCheck` static method.
- `Sources/ContinuumRevivedCoreChecks/main.swift` — added `DefaultGroupZoneName.userDefaultsKey` to conflict-guard `expectedKeys` set; updated `palette static action rows` assertion to permit `makeRows`-appended `.createZone`.
- `Sources/ContinuumRevivedPaletteChecks/main.swift` — added Part A Core table assertions (assertions 1–6); updated existing row-order tests to include `"Create Zone…"` in expected arrays; added `--palette-zone-check` to the app check invocation loop.
- `scripts/run-matrix.sh` — registered `--palette-zone-check` after `--palette-jump-check`.

### git diff --stat
```
Sources/ContinuumRevived/App/ContinuumApp.swift    | 266 ++++++++++++++++++++-
Sources/ContinuumRevived/App/LaunchProfilePalette.swift |  12 +-
Sources/ContinuumRevivedCore/LaunchPaletteModel.swift  |  31 ++-
Sources/ContinuumRevivedCore/SettingsSchema.swift  |   5 +
Sources/ContinuumRevivedCore/WorkspaceDocument.swift   |  28 +++
Sources/ContinuumRevivedCoreChecks/main.swift      |   7 +-
Sources/ContinuumRevivedPaletteChecks/main.swift   |  55 ++++-
scripts/run-matrix.sh                              |   1 +
8 files changed, 388 insertions(+), 17 deletions(-)
(+ 1 new file: Sources/ContinuumRevivedCore/DefaultGroupZoneName.swift)
```

### RED output (compile RED — Core table)
```
error: emit-module command failed with exit code 1
/Sources/ContinuumRevivedPaletteChecks/main.swift:89:17: error: cannot find 'JumpZoneRow' in scope
```
This confirmed the check was genuinely RED before implementation.

### GREEN output
```
ContinuumRevivedPaletteZoneChecks passed: .../qa-runs/2026-06-16T122823Z/palette-zone/manifest.json
```

### --fast matrix result
```
Fast matrix passed.
```
All checks green, no regressions.

### Deviations from spec

1. **Existing palette test updates**: The spec's `makeRows` always appends `[LaunchPaletteRow.action(.createZone)]`, which changed the row count/order in all existing palette tests. Updated 5 existing assertions in `ContinuumRevivedPaletteChecks/main.swift` and 1 in `ContinuumRevivedCoreChecks/main.swift` to account for `"Create Zone…"` being always present. This is correct behavior per spec; the existing tests pre-dated T17.

2. **Nav-mode check update**: The `--nav-mode-check` at :8307 previously asserted `selectedDisplayNameForQA.contains("Review Zone")`, which broke because jump-to-zone rows now also match the "zone" query and appear first. Updated to use a new `filteredDisplayNamesForQA` QA accessor (added to `LaunchProfilePalette`) and checks that "Review Zone" is present anywhere in filtered rows rather than being first-selected. Added `filteredDisplayNamesForQA` to `LaunchProfilePalette` as a minimal QA accessor.

3. **`firstTileInZone` helper**: Added as a private helper on `AppDelegate` to find a tile inside a zone's world rect (used by `jumpToZoneFromPalette`). This is within scope as it is called only from `jumpToZoneFromPalette`.

4. **`createGroupZoneFromPalette` workspace resolution**: When `workspaceRuntime?.workspaceId` is nil (check scenario uses no runtime), the function falls back to `registry.lastActiveWorkspaceId`. This correctly exercises the real persistence path without requiring a full `WorkspaceRuntime` setup.

### Acceptance criteria self-assessment

- [x] `LaunchPaletteAction.jumpToZone(UUID)` + `.createZone` with displayName + filterTokens; `JumpZoneRow` + `LaunchPaletteRow.jumpToZone` mirror the tile-jump.
- [x] `makeRows(jumpZones:)` appends zone-jump rows then Create Zone action, AFTER tile-jump rows, BEFORE workspaces/projects (Core assertions 1 + 6 green).
- [x] `--palette-zone-check` drives the REAL `performPaletteAction` inside an open `.palette` modal for BOTH jump and create; jump viewport == hand-derived `fitZoneToViewport`, focus survives `closeModal`, unknown-zone is a no-op.
- [x] Create-zone writes a group zone (`projectId == nil`, configured name, gap origin) to the active workspace's `WorkspaceDocument` on disk; registry `projectIds` unchanged; no controller spun.
- [x] `DefaultGroupZoneName` default + Settings field + conflict-guard coverage shipped.
- [x] No leader zone-jump / sidebar / tile-jump-row refactor; `addProjectZone` left intact.
- [x] `swift run ContinuumRevivedPaletteChecks` + `--palette-zone-check` + `./scripts/run-matrix.sh --fast` all green.

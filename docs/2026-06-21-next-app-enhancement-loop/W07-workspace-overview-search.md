# W07 — Workspace overview/search command

Status: implementation-ready, depends on W01/W02

## Goal
Add a keyboard-first overview/search command for workspaces, zones, and tiles using the same model as the sidebar.

## Implementation decision
Extend existing palette rows; do not build a new omnibar.

## Scope
- Palette mode/search rows include workspace, zone, and tile rows.
- Selecting row uses same action code as sidebar W02.
- Search matches workspace name, zone name/project name, tile title/type/url where safe.
- Browser URLs in artifacts must be fixture-only or redacted.

## Out of scope
- Fuzzy ranking overhaul.
- Semantic search.
- Recent/frequent ranking.

## Code seams
- `LaunchPaletteModel`
- `LaunchProfilePalette`
- sidebar tree/view model
- W02 row action handler

## Deterministic check
Add app flag:

```text
--workspace-overview-search-check
```

Verify query results and selection paths for workspace/zone/tile.

## QA artifact

```text
qa-runs/<timestamp>/workspace-overview-search/manifest.json
```

Required fields:
- `workspaceSearchWorked: true`
- `zoneSearchWorked: true`
- `tileSearchWorked: true`
- `selectionUsesSidebarActionPath: true`
- `artifactSecretFree: true`

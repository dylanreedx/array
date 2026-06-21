# W02 — Sidebar row actions: switch, focus, reveal

Status: implementation-ready, depends on W01

## Goal
Clicking workspace sidebar rows performs predictable navigation: switch workspaces, focus zones, and focus tiles.

## Implementation decision
Reuse existing workspace switch and leader/palette jump/focus plumbing. Do not create a new navigation engine.

## Scope
- Workspace row click switches workspace.
- Current-workspace zone row click pans/focuses zone.
- Current-workspace tile row click pans/focuses tile.
- Non-current zone/tile row click switches workspace, then focuses target if it still exists.
- Row selection follows the active/focused workspace/zone/tile.

## Out of scope
- Drag/drop.
- Multi-select.
- Renaming inline.
- Context menus; W05 can add polish.

## Code seams
- `WorkspaceRuntime.switchWorkspace(to:)`
- `CanvasNSView` focus/jump APIs from T06/T07/T08/A09/A10 work
- `LaunchPaletteModel` jump rows as reference behavior
- `FocusHistory` if active tile selection should update previous navigation

## Pseudo-code

```swift
func sidebarDidSelect(row: WorkspaceSidebarRow) {
    switch row.kind {
    case .workspace(let id): switchWorkspace(id)
    case .zone(let workspaceId, let zoneId):
        switchIfNeeded(workspaceId) { focusZone(zoneId) }
    case .tile(let workspaceId, let tileId):
        switchIfNeeded(workspaceId) { focusTile(tileId) }
    }
}
```

## Deterministic check
Add app flag:

```text
--workspace-sidebar-actions-check
```

Verify:
- current workspace tile row focuses tile and updates focus state;
- current workspace zone row frames zone;
- non-current workspace row switches workspace;
- non-current tile row switches then focuses tile;
- missing target after switch produces safe no-op/error row state, not crash.

## QA artifact

```text
qa-runs/<timestamp>/workspace-sidebar-actions/manifest.json
```

Required fields:
- `workspaceSwitchFromRowWorked: true`
- `currentZoneFocusWorked: true`
- `currentTileFocusWorked: true`
- `crossWorkspaceTileFocusWorked: true`
- `missingTargetHandled: true`

## Stop conditions
Stop if existing focus APIs cannot target a zone/tile after workspace switch. Write a small follow-up ticket for focus API repair rather than inventing another focus path.

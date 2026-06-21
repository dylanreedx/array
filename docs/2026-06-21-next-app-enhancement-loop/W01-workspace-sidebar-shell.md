# W01 — Render workspace sidebar shell from existing model

Status: implementation-ready after Dylan confirms left-dock/default-visible decision

## Goal
Add a persistent left workspace sidebar that renders the workspace hierarchy using existing workspace/sidebar data, so users can see workspaces, zones, and tiles without opening the palette.

## Implementation decision
Use existing `SidebarTree` if it still exists and is appropriate. If it no longer compiles or is stale, create the smallest equivalent view model in core and document why.

Sidebar is a left dock inside the main window, not a floating panel.

## Scope
- Add a sidebar container to the main app layout.
- Render rows:
  - workspace rows;
  - zone/project rows under expanded workspace;
  - tile rows under zones.
- Current workspace is expanded and visually selected.
- Non-current workspaces are collapsed by default.
- Add disclosure toggles for workspace and zone rows.
- Persist sidebar width and hidden/visible setting.

## Out of scope
- Click-to-focus behavior beyond row selection; W02 owns actions.
- Agent status glyphs; W03 owns status.
- Search/filter; W07 owns overview/search.
- Drag/drop hierarchy edits.

## Code seams
Likely files/symbols:
- `Sources/ContinuumRevivedCore/SidebarTree.swift` if present
- `Sources/ContinuumRevived/App/WorkspaceRuntime.swift`
- `Sources/ContinuumRevived/App/ContinuumApp.swift`
- `Sources/ContinuumRevived/Canvas/CanvasNSView.swift`
- new `Sources/ContinuumRevived/App/WorkspaceSidebarView.swift` or equivalent AppKit view
- `SettingsSchema` for sidebar visibility/width if needed

## UX policy
- Width default: 280 px.
- Minimum width: 220 px.
- Maximum width: 420 px.
- Toggle command: `View > Show Workspace Sidebar`.
- Keyboard default: do not add a new global shortcut unless existing menu/keybind system has an obvious slot; action must still be command-palette discoverable.

## Deterministic check
Add app flag:

```text
--workspace-sidebar-shell-check
```

It must seed two workspaces with zones/tiles and verify:
- sidebar renders both workspaces;
- current workspace expanded;
- non-current workspace collapsed;
- row counts match seeded model;
- width/visibility persistence round-trips.

## QA artifact

```text
qa-runs/<timestamp>/workspace-sidebar-shell/manifest.json
```

Required fields:
- `workspaceRowsRendered`
- `currentWorkspaceExpanded: true`
- `nonCurrentWorkspaceCollapsed: true`
- `zoneRowsRendered`
- `tileRowsRendered`
- `widthPersistenceWorked: true`
- `visibilityPersistenceWorked: true`

## Stop conditions
Stop if main window layout requires a broad rewrite. Instead, implement the sidebar as a toggled split-view shell with minimal integration and document follow-up.

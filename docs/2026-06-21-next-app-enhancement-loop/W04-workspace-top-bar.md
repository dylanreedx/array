# W04 — Workspace top bar / current workspace identity

Status: implementation-ready

## Goal
Add a lightweight top workspace bar so users always know what workspace they are in and whether workspace state is saved.

## Implementation decision
Build a small top bar, not a full toolbar redesign.

## Scope
- Show current workspace name.
- Show project count and zone count.
- Show save state: `Saved`, `Saving…`, `Unsaved changes`, or `Save failed` if existing save controller can expose it.
- Quick actions:
  - switch workspace;
  - rename workspace;
  - toggle sidebar.

## Out of scope
- Global command center redesign.
- Breadcrumb for every tile.
- Sync/cloud status.

## Code seams
- `WorkspaceRuntime.workspaceId`
- `WorkspaceStore` / registry lookup for workspace names
- `WorkspaceDocumentSaveController`
- `ContinuumApp` main window layout

## Deterministic check
Add app flag:

```text
--workspace-top-bar-check
```

Verify workspace name/counts render and update after switch/rename/save events.

## QA artifact

```text
qa-runs/<timestamp>/workspace-top-bar/manifest.json
```

Required fields:
- `currentWorkspaceNameRendered: true`
- `countsRendered: true`
- `switchUpdatedName: true`
- `renameUpdatedName: true`
- `saveStateRendered: true`

## Stop conditions
If save controller has no observable state, render only workspace identity/counts and document save-state follow-up; do not fake save status.

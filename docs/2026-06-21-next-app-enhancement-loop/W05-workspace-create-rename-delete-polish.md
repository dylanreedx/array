# W05 — Workspace create/rename/delete polish

Status: implementation-ready

## Goal
Make workspace management feel like a product feature, not a hidden registry implementation.

## Implementation decision
Use existing palette/project picker actions where possible, but expose them from sidebar/top bar and add deterministic confirmation behavior.

## Scope
- Create workspace action from sidebar/top bar.
- Rename workspace action with validation.
- Delete workspace action with confirmation.
- Empty workspace behavior is explicit and visible.
- Cannot delete last workspace without creating/selecting replacement.

## Out of scope
- Workspace templates.
- Import/export.
- Cloud sync.

## UX policy
- Empty name invalid.
- Duplicate name allowed only if existing app already allows it; otherwise reject with inline message.
- Delete copy must say whether projects/tiles are deleted or only workspace membership/document. Ticket must preserve current data semantics and state them in artifact.

## Deterministic check
Add app flag:

```text
--workspace-management-polish-check
```

Verify create, rename, invalid rename, delete confirmation, delete cancel, and last-workspace protection.

## QA artifact

```text
qa-runs/<timestamp>/workspace-management-polish/manifest.json
```

Required fields:
- `createWorked: true`
- `renameWorked: true`
- `invalidRenameRejected: true`
- `deleteCancelPreservedWorkspace: true`
- `deleteConfirmRemovedWorkspace: true`
- `lastWorkspaceProtected: true`

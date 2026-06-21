# W06 — Workspace switch transition and restore polish

Status: implementation-ready

## Goal
Switching workspaces should feel deterministic: save departing state, restore target viewport/focus, and avoid visual confusion.

## Implementation decision
Audit and polish existing `WorkspaceRuntime.switchWorkspace(to:)`; do not rewrite workspace runtime.

## Scope
- Departing workspace viewport/focus saved before switch.
- Target workspace viewport restored.
- Last focused tile/zone restored if still valid.
- If target focus missing, focus canvas and frame workspace bounds.
- Add a brief non-blocking transition label: `Switched to <Workspace>`.

## Out of scope
- Animated workspace zoom/portal transitions.
- Multi-window workspaces.

## Code seams
- `WorkspaceRuntime.switchWorkspace(to:)`
- `WorkspaceDocumentSaveController`
- `CanvasNSView.setViewport` / focus APIs
- existing workspace switch checks

## Deterministic check
Add/extend app flag:

```text
--workspace-switch-polish-check
```

Verify two workspace round trip preserves viewport and valid focus, and gracefully handles deleted focused tile.

## QA artifact

```text
qa-runs/<timestamp>/workspace-switch-polish/manifest.json
```

Required fields:
- `departingViewportSaved: true`
- `targetViewportRestored: true`
- `lastFocusRestored: true`
- `deletedFocusFallbackWorked: true`
- `transitionLabelShown: true`

# W03 — Sidebar live updates and agent status glyphs

Status: implementation-ready, depends on W01

## Goal
The workspace sidebar updates as workspaces/zones/tiles change and shows existing agent status rollups so users can see what needs attention.

## Implementation decision
Reuse existing agent status rollup data. Do not build a new status pipeline.

## Scope
- Sidebar refreshes when:
  - workspace switches;
  - zone added/renamed/deleted;
  - tile added/renamed/deleted;
  - agent status rollup changes if existing notification/polling exists.
- Show glyph/status text for zone/tile rows:
  - working;
  - needs attention;
  - done;
  - stale;
  - unknown/no agent.

## Out of scope
- Starting/stopping agents from sidebar.
- Detailed agent logs.
- Notification center.

## Code seams
- Existing `AgentStatusRollup` / zone chrome draw path
- `WorkspaceRuntime` callbacks
- `CanvasNSView` tile lifecycle notifications
- `WorkspaceSidebarView`

## Deterministic check
Add app flag:

```text
--workspace-sidebar-live-status-check
```

Verify seeded status changes update row view model without rebuilding app/window.

## QA artifact

```text
qa-runs/<timestamp>/workspace-sidebar-live-status/manifest.json
```

Required fields:
- `tileCreateUpdatedSidebar: true`
- `tileDeleteUpdatedSidebar: true`
- `zoneRenameUpdatedSidebar: true`
- `agentStatusGlyphsRendered: true`
- `noNewStatusPipeline: true`

## Stop conditions
Stop if no reliable status source exists outside drawing code. Produce a follow-up ticket to extract status view model first.

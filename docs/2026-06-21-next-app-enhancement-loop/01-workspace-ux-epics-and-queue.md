# Workspace UX epics and queue

Status: draft for Dylan review

## Why this exists

We are behind on workspace UI/UX. The underlying workspace model/runtime exists, and a sidebar model was previously sketched, but the product still feels like a canvas plus palette commands rather than a durable workspace home.

Existing evidence:
- `docs/35-observability-sidebar.md` says `SidebarTree` exists but is not rendered.
- Workspace switching is palette-first, not visible/persistent.
- Workspace runtime and switching exist in `WorkspaceRuntime`.
- Project/workspace picker exists, but it is launch-time/modal, not everyday navigation.

## Product direction

Build a persistent workspace home surface in small slices:

1. A left workspace sidebar that answers: where am I, what workspaces/zones/tiles exist, and what needs attention?
2. A workspace top bar that answers: what workspace am I in, is it saved/syncing, and what quick actions exist?
3. Better workspace switching and creation flows.
4. A lightweight overview/search layer after the sidebar exists.

## Explicit product decisions for first loop

- Sidebar form: left dock, persistent, resizable, toggleable.
- Default visibility: on by default for now; user can hide with a menu/keybinding.
- Hierarchy: Workspace → Zone/Project → Tile. Do not add another project grouping level unless needed by data model.
- Scope shown: all workspaces, current workspace expanded by default; non-current workspaces collapsed.
- Click behavior:
  - workspace row: switch workspace;
  - zone row in current workspace: pan/focus zone;
  - tile row in current workspace: pan/focus tile;
  - zone/tile row in non-current workspace: switch workspace, then focus target if target still exists.
- Agent status: show existing rollup/glyph if available; otherwise no new status system.

## Tickets

1. W01 — Render workspace sidebar shell from existing model
2. W02 — Sidebar row actions: switch/focus/reveal
3. W03 — Sidebar live updates and agent status glyphs
4. W04 — Workspace top bar / current workspace identity
5. W05 — Workspace create/rename/delete polish
6. W06 — Workspace switch transition and restore polish
7. W07 — Workspace overview/search command
8. W08 — Final workspace UX audit/dogfood

## Non-goals for first loop

- No minimap.
- No global graph of connected tiles.
- No cloud sync.
- No drag/drop rearranging workspace hierarchy in sidebar.
- No visual redesign of every tile chrome.

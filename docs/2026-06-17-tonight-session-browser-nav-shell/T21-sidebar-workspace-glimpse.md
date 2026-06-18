# T21 — Sidebar workspace glimpse

Status: draft
Tag: tonight [sidebar] [workspace] [observability]
Depends on: T19

## Goal
Create a sidebar that lets the user glimpse into the current and other workspaces: workspaces → zones → tiles, with focus and status context. This is the persistent context surface, not a full overview mode.

## Product role
The sidebar answers: **“What is inside this workspace, and what else is nearby?”**

It complements:
- top session bar = where can I go?
- `Cmd-K` = go there now;
- canvas = do the work.

## Desired behavior
Default shape:
- Active workspace expanded.
- Other recent workspaces visible/collapsed with status summaries.
- User can expand another workspace to peek at zones/tiles without switching if data is available cheaply.
- Clicking a workspace switches.
- Clicking a zone/tile in another workspace switches, then jumps/focuses.

Example:

```text
Workspaces
  Continuum Revived  ●2
    Browser Work
      Browser — localhost:3000
      Shell — continuum-revived · main
    Notes
      Note — Browser overhaul

  Selectus  ⚠1
    QR Review
      Agent — done
      Browser — staging
```

## Scope
- Audit/extend `SidebarTree` from workspace→zones to workspace→zones→tiles if needed.
- Include row identity, row kind, title, subtitle, color, nav key, status, current/focused flags.
- Add row activation mapping:
  - workspace row → switch workspace;
  - zone row → switch if needed, then jump/fit zone;
  - tile row → switch if needed, then focus/center tile.
- Build sidebar UI only after model/action seams are tested.
- Persist sidebar width and collapsed/expanded state if small enough; otherwise defer.

## Non-goals
- No global Mission Control overview yet.
- No heavy screenshots/previews.
- No requirement to hydrate cold workspaces just to show a glimpse.
- No bespoke navigation path; reuse palette/leader/camera focus primitives.

## Acceptance criteria
- [ ] Sidebar model exposes workspace rows with active workspace marked.
- [ ] Active workspace expands to zones and tiles.
- [ ] Other workspaces can appear collapsed with status summaries.
- [ ] Row activation maps to shared switch/jump/focus commands.
- [ ] Active/focused tile row updates with focus changes.
- [ ] Sidebar can be toggled/collapsed without losing state.
- [ ] Accessibility identifiers are stable for rows.

## Verification
- Core model checks for tree building and row activation.
- AppKit/AX check for rendered rows if stable; otherwise manual transcript.
- Human dogfood: can identify current workspace, focused tile, and one other active session without opening palette.

## TDD sketch
Sidebar tree model:

```swift
let tree = SidebarTreeBuilder.build(
    registry: registryWithWorkspaces,
    documents: workspaceDocuments,
    currentWorkspaceId: continuum,
    focusedTileId: shellTile,
    statusProvider: fakeStatus
)

expect(tree.workspaces.count == 2, "sidebar includes multiple workspaces")
expect(tree.workspace(id: continuum)?.isCurrent == true, "current workspace marked")
expect(tree.workspace(id: continuum)?.zones.count == 2, "current workspace exposes zones")
expect(tree.workspace(id: continuum)?.zones[0].tiles.contains(where: { $0.id == shellTile }), "zone exposes tile rows")
expect(tree.tile(id: shellTile)?.isFocused == true, "focused tile row marked")
expect(tree.workspace(id: selectus)?.status == .needsAttention(count: 1), "other workspace exposes status summary")
```

Row action resolver:

```swift
expect(SidebarRowAction.resolve(.workspace(selectus), currentWorkspaceId: continuum) == [.switchWorkspace(selectus)])
expect(SidebarRowAction.resolve(.zone(zoneB, workspaceId: selectus), currentWorkspaceId: continuum) == [.switchWorkspace(selectus), .jumpToZone(zoneB)])
expect(SidebarRowAction.resolve(.tile(tileB, zoneId: zoneB, workspaceId: selectus), currentWorkspaceId: continuum) == [.switchWorkspace(selectus), .jumpToTile(tileB)])
```

Accessibility oracle:

```swift
expect(SidebarAccessibility.id(for: .workspace(continuum)) == "WorkspaceSidebar.Row.Workspace.\(continuum.uuidString)")
expect(SidebarAccessibility.id(for: .zone(zoneA)) == "WorkspaceSidebar.Row.Zone.\(zoneA.uuidString)")
expect(SidebarAccessibility.id(for: .tile(tileA)) == "WorkspaceSidebar.Row.Tile.\(tileA.uuidString)")
```

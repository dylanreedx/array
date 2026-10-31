# Part 2: the shared area as a canvas zone

Branch `array/mp-canvas-zone`, bench
`.worktrees/multiplayer-shared-area-as-a-can-9a25f560`, base `array/collaboration-finish`
(c7131f8f). Design: `.plans/105-collaboration/IN-CANVAS.md` option A (committed on the
design bench as 5fb4315e).

Status: IN PROGRESS. This file is the coordination point for parts 1, 3 and 4.
The API section below is the contract. It will not change shape without a note here.

## API for part 3: `createSharedZone(fromTiles:)`

It lives on `WorkspaceRuntime`, which owns the workspace document and the mounted
canvas. File: `Sources/ContinuumRevived/App/WorkspaceRuntime+SharedZone.swift`.

```swift
struct SharedZoneConversion: Equatable {
    let zoneId: UUID                       // the new shared zone (a projectless ZonePlacement)
    let areaId: UUID                       // SharedArea.Document.id.rawValue
    /// Each lent tile's frame inside the area. Pass it straight to
    /// SharedArea.Position(rect:) when you admit the tile's item.
    let areaFrames: [UUID: SharedArea.Rect]
}

enum SharedZoneError: Error, Equatable {
    case noTiles
    case tileNotInstalled(UUID)     // not in an installed project ZoneLayer of this workspace
    case terminalStaysPrivate(UUID) // terminals are never shared
    case alreadyShared(UUID)        // the tile is already lent to a shared zone
    case areaAlreadyOpen(UUID)      // this workspace already has a zone for the area
}

extension WorkspaceRuntime {
    /// Moves the tiles out of their project zone into a new shared zone's layer.
    /// The views are moved, not rebuilt, so agent runners and subscriptions keep running.
    @discardableResult
    func createSharedZone(fromTiles tileIds: [UUID], areaId: UUID, name: String) throws -> SharedZoneConversion

    /// After you admit a lent tile as an item, bind them. Moves of the tile then
    /// send `.place` for that object, and the zone draws no second projection of it.
    func bindSharedTile(_ tileId: UUID, to object: SharedArea.ID<SharedArea.Object>, inZone zoneId: UUID)

    /// Reverses the conversion: every lent tile goes back to its home zone at its
    /// pre-share frame, with the same view. The shared zone and its anchor leave
    /// the workspace document. Use it when the share is cancelled or stopped.
    func cancelSharedZone(_ zoneId: UUID) throws
}
```

### What it does

- The shared zone is a `ZonePlacement` with `projectId == nil` and
  `sharedAreaId == areaId`, stored in the workspace document. It sits to the right of
  the tiles' source zone. `setActiveZone` refuses it, because it has no project.
- Every tile keeps its relative arrangement inside the new zone.
- **The project keeps its pre-share record.** While a tile is lent, the project's
  `canvas.json` keeps the record it had before the share, and nothing the share does
  is written there: moves and resizes in the area are shared operations only. That
  record is the return address. It is also why a crash or quit mid-share loses
  nothing: at the next launch the tile is simply back in its home zone.
- Terminals are refused, because terminals stay private.

### What it does not do

It does not create an area, publish items or make a link. That is your flow: create
or open the area, call `createSharedZone`, admit one item per tile at
`areaFrames[tile]`, then call `bindSharedTile` for each. If the publication fails, call
`cancelSharedZone`.

## Opening an existing area on the canvas (parts 1 and 4)

`AppDelegate.openSharedAreaZone(controller:person:area:accountID:)` replaces the old
`showSharedArea(...)` window. It reuses this workspace's zone for the area, or creates
one beside the viewport, and reveals it. A link handler (part 1) should call it once the
area is admitted.

## Notes for the other parts

- Part 4 (full access): the zone's teammate agent view shows the read-only footer and
  Ask for control today. When the `promptAgent` capability lands, the footer should
  become a composer. The footer's single switch point is
  `SharedAreaZoneAgentView.footerMode`.

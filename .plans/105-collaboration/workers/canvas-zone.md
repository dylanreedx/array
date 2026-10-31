# Part 2: the shared area as a canvas zone

Branch `array/mp-canvas-zone`, bench
`.worktrees/multiplayer-shared-area-as-a-can-9a25f560`, base `array/collaboration-finish`
(c7131f8f). Design: `.plans/105-collaboration/IN-CANVAS.md` option A (committed on the
design bench as 5fb4315e).

Status: IN PROGRESS. This file is the coordination point for parts 1, 3 and 4.
The API section below is the contract. It will not change shape without a note here.

## API for part 3: `createSharedZone(fromTiles:name:)` (the one call)

Coordinator decision, 31 October: part 2 owns the whole sender side in one call.
It is on `AppDelegate`, in `Sources/ContinuumRevived/App/Collaboration/SharedAreaZoneSession.swift`:

```swift
struct SharedZoneShare: Equatable {
    let areaId: UUID                                      // the new area
    let zoneId: UUID                                      // its zone on this canvas
    let objects: [UUID: SharedArea.ID<SharedArea.Object>] // tile -> object, source-bound tiles only
}

extension AppDelegate {
    /// Creates the area, publishes the tiles by kind (part 1's
    /// shareLinks.publish(selection:intoArea:)), opens the area's zone here,
    /// moves the tiles into it (same views, runners kept), binds each published
    /// tile to its object and lays the objects out where the tiles now sit.
    func createSharedZone(fromTiles tileIds: [UUID], name: String) async throws -> SharedZoneShare

    /// Undo: what it published leaves the area (when reachable), the tiles go
    /// home at their pre-share frames with their own views, the zone is removed.
    func cancelSharedZone(areaId: UUID) async
}
```

Then mint the link with part 1's `shareLinks.createShareLink(area: share.areaId, slug:lifetime:)`.

- It refuses before anything leaves the Mac. Errors are
  `WorkspaceRuntime.SharedZoneError`: `.noTiles`, `.tileNotInstalled(id)`,
  `.terminalStaysPrivate(id)` (terminals stay private), `.alreadyShared(id)`, `.noCanvas`.
  Sign-in and publish errors come through as part 1's `ShareLinkFailure`.
- Notes are lent into the zone too. They publish as discussion, which has no source
  binding, so they are not in `objects`; the zone's dock shows the discussion.
- The project keeps each lent tile's pre-share record in its `canvas.json`. Nothing the
  area does to a lent tile is written there, and after a crash or quit the tile is simply
  back in its home zone.

Lower level, if you need it: `WorkspaceRuntime.createSharedZone(fromTiles:areaId:name:)`
(lend into an area's zone, no network), `bindSharedTile(_:to:inZone:)`,
`cancelSharedZone(_ zoneId:)`, in `WorkspaceRuntime.swift`, "Shared area zones".

## Opening an area (parts 1 and 4)

Every open goes through `AppDelegate.openSharedArea(controller:person:area:model:)`, as
on `array/collaboration-finish`. It now returns `SharedAreaZoneSession?` and opens the area
in its zone on the canvas: this workspace's zone for the area, or a new one to the right of
everything else. It reveals the zone, never arms it, and starts the publishing host. No
shared window opens any more. `qaSharedAreaWindows` is gone; use `qaSharedAreaZoneSessions`.

## Notes for the other parts

- Part 4 (full access) is integrated. A teammate's agent in the zone is
  `SharedAreaZoneAgentView`. Its `SharedAgentLiveView` (with part 4's composer) fills
  the tile, and there is no read-only footer and no Ask for control. A footer shows
  only when the host is offline ("Dylan's Mac is offline · showing the last update…")
  or on the owner's own canvas ("open its own tile to prompt it"); see `footerMode`.
  `openSharedArea` sets `session.prompter = host.handoff.model`, and every zone agent
  view's `live.prompter` follows it.
- "Hand agent off…" is not wired in the zone. The brief retires the handoff window from
  the user path, and part 4's note asks to keep it as an explicit action. These two
  conflict, so it's left to the coordinator.

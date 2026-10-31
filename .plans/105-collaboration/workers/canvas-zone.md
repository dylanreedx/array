# Part 2: the shared area as a canvas zone

Branch `array/mp-canvas-zone`, bench
`.worktrees/multiplayer-shared-area-as-a-can-9a25f560`, base `array/collaboration-finish`
(c7131f8f). Design: `.plans/105-collaboration/IN-CANVAS.md` option A (committed on the
design bench as 5fb4315e).

Status: DONE at 990a0c76 (tip after this receipt is in the coordinator message). Gate green. Receipt at the end.
This file is the coordination point for parts 1, 3 and 4.

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

## Receipt

Base: `array/collaboration-finish` 2f95fd77 (part 1 and part 4 merged).

### What a person sees

- An area opens as a zone on their own canvas, never a window. Every route comes through
  `openSharedArea`: the hub's Open, a share link, `createSharedZone`, and the File menu's
  Share entries when an area is already open.
- The zone is Model B chrome with a shared variant. On the right of its header are a quiet
  `Shared` pill, a live dot with "Live · hosted by Dylan", and avatars in each person's
  colour. The host is purple; there is never blue and never red.
- A teammate's agent is read in place: their colour as a hairline and a chip, "Dylan's · on
  Dylan's Mac", and part 4's composer under the live view. My own published agent reads
  "Yours · shared".
- The dock inside the zone's right edge holds the area's agreement, pinned with its current
  revision and Endorse, then the whole thread, then the reply field. It is the scene's own
  agreement panel, reader and composer.
- Follow: click an avatar. The canvas camera centres on that person's view of the area,
  with a frame and a "Following Dylan · Stop · esc" pill in their colour. esc, any pan or
  zoom, or the pill stops it.
- Host offline: the zone dims with a dashed edge and the host's avatar greys. Their agent
  keeps its place, dimmed and dashed, with "Dylan's Mac is offline · Showing the last
  update, 4 min ago". Nothing falls back to this Mac.

### Hazard 9 fit

- One zone-chrome owner. The area's zone is a `ZonePlacement` with no project and a
  `sharedAreaId` (classified `internal` in `WorkspaceAPIExposure`). It lives in the
  workspace document and is drawn, moved, resized, renamed and closed by Model B like any
  zone.
- It has no `ZoneLayer`. Its contents are the scene, mounted as a world-plane body at the
  zone's WORLD rect, with items at their area-local positions (world = zone origin + local).
- `setActiveZone` refuses it, a drop never adopts a tile into it, and nothing in it is
  written to a project's `canvas.json`.
- A lent tile's project keeps its pre-share record (`tilesInWorldFrames(forProjectId:)`),
  so the cover-then-replace rule is untouched and a crash loses nothing.

### Windows

- The scene window is gone from the user path; `SharedAreaWindowController` is kept only
  because the window-scene witnesses construct it.
- The handoff window is no longer reachable from the user path.
- The hub remains the place to sign in (and part 1's no-relay links sign in through its
  Connect). Opening an area from it lands the zone.
- The capture review is still `SharedAreaCaptureWindowController`. Part 3's popover
  replaces it.

### Witnesses

`--shared-area-zone-check` (new, in `run-matrix.sh`'s collaboration block and the full
matrix). 34 assertions.
- It mounts through `WorkspaceInvariantsFixture` → `mountWorkspaceSceneAtBoot`, and opens
  the area through `openSharedArea`'s own route.
- Pointer input goes through `NSApp.sendEvent` on a window that reports itself key, with
  first mouse accepted, as `CanvasPointerPathChecks` does.
- Frames are asserted as WORLD rects against the zone's world rect.

What it checks:
- the projectless anchor in the workspace document
- Model B chrome
- the body at the zone's WORLD rect, and each agent view at zone origin + area position
- `setActiveZone` refuses the zone, and a click inside it arms nothing
- the dock pins revision 2 and reads the whole thread; Endorse lands
- a header drag sends `.place`, and no project's `canvas.json` changes
- a project tile dragged into the zone (it is inside the zone mid-drag) stays in its
  project zone and publishes nothing; no `canvas.json` names the shared zone
- `createSharedZone` lends a tile with the same view at zone origin + area frame; it can't
  be lent twice; binding hides the projection
- the lent tile's drag shares `.place`, and a teammate's `.place` moves it
- the lent tile's project keeps its pre-share record; cancel returns the same view to the
  same WORLD frame and removes the zone and its session
- follow from the header avatar: the camera centres on Dylan's view, the pill and frame
  show, `interactionGeneration` does not move, and it tracks him; esc, a trackpad pan and
  the pill each stop it
- budget: 20 cursor-only frames repaint neither the header nor an agent view
- offline: the agent keeps its place, dimmed, "Dylan's · offline", "4 min ago"; the zone
  is dashed and his avatar is grey; back online, the edge is solid again

Teeth: each mutation below turned the leg RED at the assertion it targets, then was reverted.

| mutation | RED at |
|---|---|
| drop lent tiles' home records from persistence | "keeps the pre-share record unchanged" |
| follow frames call `onUserCameraChange` | "the interaction generation does not move" |
| body framed 34 pt low | "exactly the zone's WORLD rect" |
| no dashed edge when the host is offline | "the zone dims with a dashed edge" |
| agent view repaints on every refresh | presence budget (agent 2→4) |
| lent-tile drop not shared | "the lent tile's move reaches the area" |
| cancel retires the view instead of returning it | "same view, same WORLD frame" |
| `setActiveZone` arms a shared zone | "setActiveZone refuses the shared zone" |

The drop-refusal assertion has no mutation of its own. The refusal comes from the existing
same-project rule in `reevaluateLayerMembership`; my code adds the shared-zone guard on the
flat and seed paths, which are boot-only.

Existing witnesses that now run through the zone:
- `ShareLinkAppChecks`: the sender shares through `createSharedZone`, which is asserted,
  including a byte-identical project file. Each receiver is a mounted workspace, and the
  link lands as a projectless zone in the world plane, reopening in the same zone. The
  undo is asserted.
- `SharedAreaCaptureChecks`: the hub's destination is the zone, not a window.
- Census: `CollaborationAppearanceSurfaces` adds `sharedAreaZone`, `sharedAreaZoneOffline`
  and `sharedAreaZoneFollow`. They render in light and dark, every new view class is
  covered, and I looked at all six pictures.

The window-scene witnesses (geometry, presence, agreement, freshness, accessibility,
budgets) still mount `SharedAreaSceneView` in `.window` presentation. They witness the
geometry ledger, drafts, presence and follow logic the zone reuses unchanged. The
zone-only paths (identity draw camera, canvas-driven follow, dock, agent views) are what
`--shared-area-zone-check` covers.

### Gate (one run, under the lock, isolated TMUX_TMPDIR and CONTINUUM_APP_SUPPORT, CONTINUUM_SKIP_UI_BASELINES=1)

- `scripts/run-matrix.sh --collaboration` at 990a0c76: passed, 13 legs. That covers the
  collaboration checks, service checks, `--collaboration-native-check`,
  `--collaboration-full-access-check`, `--shared-area-zone-check`, `--ui-probe-check`,
  `--menu-contract-check`, usage telemetry, the pair script, both relay suites and the
  Linux relay build. One note: ui-probe skips its display-dependent theme cache.
- Zone and canvas legs I touched, all exit 0:
  - zone: `--zone-layer-move-check`, `--zone-arming-check`, `--zone-presentation-check`,
    `--zone-save-isolation-check`, `--zone-runtime-duplication-check`,
    `--zone-close-keep-delete-check`, `--zone-move-unified-check`, `--zone-resize-check`,
    `--zone-chrome-zorder-check`, `--zone-breakout-check`
  - workspace and canvas: `--workspace-scene-owner-check`, `--canvas-pointer-path-check`,
    `--retired-flat-write-check`, `--multi-zone-render-check`
  - CoreChecks: `--workspace-api-exposure-check`

### Open

- **Hand agent off… in the zone**: not wired. The brief retires the handoff window, and
  part 4 asks to keep it as an explicit action. Coordinator's call.
- **Reopening at launch**: a shared zone's anchor survives a relaunch, but its body appears
  only when the area is opened again (hub, link or share). Lent tiles are back home by then.
- **Resizing a lent tile** in the area is not shared; moving is.
- **Workspace switch**: lent tiles go home first. The departing workspace's area body
  leaves the canvas, but its session is not yet closed on switch.
- **My own avatar** is drawn with the initial of "You".

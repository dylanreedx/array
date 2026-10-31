# Multiplayer part 3: share entry points and the share popover

Bench `.worktrees/multiplayer-share-button-tool-an-cb2e24e6`, branch
`array/mp-share-entry`, base `array/collaboration-finish` c7131f8f. Design:
`IN-CANVAS.md` "Round 2" (5fb4315e), sheets `in-canvas/share-link-*.png`
panels 1 to 5 and 8.

## What a person can now do

- **Share one agent from its header.** A quiet Share button sits left of the
  status pill on every managed-agent tile (`TileNSView` band, beside ⋯). It is
  the first thing a narrow band gives up; the sidebar still offers Share.
- **Share it from the sidebar.** Hovering a row shows Share with Snooze and
  Settle. The row menu leads with Share…. Both bring the agent's tile into view
  and anchor the popover to the tile, not the row.
- **The Share tool.** A Share button beside Zone on the toolbar, a "Share…"
  palette row, and S while the canvas has the keyboard. With 2+ tiles already
  selected it shares them; otherwise it arms the tool. The tool shows a hint
  pill and draws a dashed marquee with a count pill at the pointer. Tiles it
  *fully* covers get a selection ring as the drag goes, even a single tile, and
  no group box or handles. Release opens the popover on those tiles. Terminals
  stay private: a marquee over only terminals keeps the tool armed and says so.
- **One popover** (`ShareLinkPopoverView`, hosted by `ChoicePopoverController`),
  built from `ComposerActionButton` (Copy link / Copied / New link), `ChoiceButton`
  (Works once / Until revoked) and `ChoiceAccessoryButton` (Remove, Revoke). For an
  area it lists the tiles in reading order. It shows the `arrayapp.dev/s/` prefix
  with an editable slug, the lifetime, the people with access (opened time, full
  access, Remove), and Revoke link, which becomes "Revoke everyone's access" once
  someone holds access. A spent Works-once link reads Used, with New link.

## How sharing runs: in place, never parked

This follows the lead's contract decision of 2026-10-31. `ShareLinkSession` keeps
one session per set of tiles, so reopening the popover shows the same link.

1. **Opening the popover shares nothing.** No area, no link, no tile moves.
   This is deliberate, so a stray click on Share costs nothing.
2. **The first Copy shares.**
   - It calls part 2's `createSharedZone(fromTiles:name:)`, which makes the
     area, publishes and binds the tiles, opens the area, and lends the
     sender's tiles to its zone. A single agent's zone is named after the
     agent; an area's after its slug.
   - It then calls part 1's `createShareLink(area:slug:lifetime:)` on that
     area, and writes the URL to the pasteboard.
   - If minting fails, for example a taken slug (409 `slugTaken`), the popover
     shows part 1's own sentence, `cancelSharedZone(areaId:)` puts the tiles
     back, and nothing is copied.
   - Nothing waits on the Collaboration window.
3. **Later Copies** copy the same link. If the slug or lifetime changed, they
   revoke it and mint a new one on the same area.
4. **Lifetime** changes on a live, unopened link revoke it and mint again.
   Once someone holds access, a lifetime change applies only to the next link,
   because reissuing would revoke them.
5. **Revoke** calls `revokeLink(area:link:)`, which removes everyone it
   admitted. **Remove** calls `removeAccess(area:link:person:)`. **New link**
   mints on the same area.
6. Reopening refreshes `listAccess(area:)`. A `used` row shows Used and the
   people it admitted who are still active.

The share target is the actual selection, each tile keyed by its owning
project (`AppDelegate.shareTarget(tileIds:origin:)`), in canvas reading order.
The first tile names the slug.

## Parts 1 and 2

- **Part 1 is wired for real.** `ShareLinkCoordinator` (`AppDelegate.shareLinks`)
  conforms to `ShareLinkServing` with an empty extension: the protocol is its
  own signatures.
- **Part 2 is not on `array/collaboration-finish` yet.** Production uses
  `PendingSharedZones`, which refuses with "Shared zones are not in this build
  yet. Nothing was shared." A first Copy therefore fails plainly in this
  branch's build and mints no link.
- **When part 2 merges:**
  - delete this branch's `SharedZoneShare` (part 2 declares the same type, so
    the duplicate fails the build at that exact spot);
  - add `extension AppDelegate: SharedZoneCreating {}`; the protocol is part
    2's `createSharedZone(fromTiles:name:)` and `cancelSharedZone(areaId:)`;
  - set `sharedZoneCreator = self`, or default it in `shareEntry`.

## Not built, and why

- **The multi-tile selection bar.** There is none in this codebase: no canvas
  selection bar exists to add Share… to. The palette's Share… and the toolbar
  Share cover a selection (2+ selected tiles share directly). A bar would be a
  new surface the sheets do not show.
- **A ⋯ button on sidebar rows, and a shortcut hint in the row menu.** Rows
  have no ⋯ today, and `ChoiceItem` has no shortcut field. Share sits with the
  existing hover actions, and the row menu item has no hint rather than a
  hint that binds nothing.
- **The toolbar's Share stays unlit while the tool is armed.** It routes
  through the palette action rather than the toolbar's own Zone arming.

## Witness

`ShareEntryChecks`, a stage of `--collaboration-native-check` ("share entry
points and popover"). It mounts production (`mountWorkspaceSceneAtBoot`), with
three managed agents and a note, and fakes for parts 1 and 2. Copy writes to a
private named pasteboard. Every press is `NSApp.sendEvent`:

- A header Share click opens the popover for that agent, hanging from the
  button, and opening shares nothing.
- A refused mint (`slugTaken`) is shown in the popover, the zone is cancelled
  on its area, and the pasteboard stays empty.
- Copy makes A a one-tile zone named after it, then mints on that zone's area
  with the slug and Works once. The URL lands on the pasteboard and the button
  reads Copied.
- A real press opens the lifetime list inside the popover (child-panel
  ownership). Until revoked revokes the unopened link and reissues through the
  controller.
- Revoke calls `revokeLink`, and the popover offers New link.
- The sidebar's hover Share opens the popover anchored to the tile. A
  right-click menu leads with Share…, and choosing it opens the popover for that
  agent.
- Share is on the toolbar with S and in the palette. S, sent to the canvas,
  arms the tool.
- A marquee rings exactly one fully covered tile mid-drag (drawn ring count 1,
  no handles), then exactly A and B, never the partly covered note. Release
  opens the area popover on `.tiles([A, B])`.
- The area's Copy makes A and B, in reading order, the shared zone and mints
  on its area.
- Reopened over a used link, the popover shows Used, Sam, Remove and New link.
  Remove calls `removeAccess`, and New link mints on the same area.

Mutations, each RED at its own leg (results below).

MUTATIONS_PLACEHOLDER

Stills: STILLS_PLACEHOLDER

Gate: GATE_PLACEHOLDER

Defects the witness caught while it was being written:

- A Remove left the session "working" forever, so the popover froze. `run` now
  restores the phase whatever the body did.
- A marquee over one tile drew no ring, because the overlay only drew for 2+
  tiles. The first assertion checked a hidden flag and passed. Marquee mode now
  draws rings only, for any count, and the witness counts drawn rings.

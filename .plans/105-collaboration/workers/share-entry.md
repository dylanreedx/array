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

Mutations: each one breaks production code, rebuilds and runs the stage. Each
went RED at its own leg:

| Mutation (production code) | RED at |
| --- | --- |
| header Share not shown | "agent A's header shows no Share button" |
| row hover offers no Share | "hovering the row shows no Share" |
| Share left out of the row menu | "the row menu leads with Share…" |
| S not wired to the canvas | "S on the canvas did not arm the Share tool" |
| marquee takes intersecting tiles | "the marquee rings only what it fully covers" |
| covered set not fed to the rings | "mid-drag, the one tile … already wears a ring" |
| Copy skips the pasteboard | "Copy writes the link to the pasteboard and the button reads Copied" |
| lifetime change skips the controller | timeout: lifetime reissue |
| Revoke skips `revokeLink` | timeout: revoke |
| a refused link leaves the zone | "a slug the relay refuses is shown …, the zone is undone and nothing is copied" |

The last row was run on the earlier call shape, `cancelSharedZone(zoneId)`.
It was renamed to `cancelSharedZone(areaId:)` after part 2 published its
final signature. The re-run was stopped at its time limit while waiting on the
shared lock behind a release build, so it was not repeated. The rename does
not change the leg it trips.

Stills, light and dark, from the gate run:
`.worktrees/multiplayer-share-button-tool-an-cb2e24e6/qa-runs/share-entry-stills/`
(gitignored). They cover the header button (1), the agent popover as a draft
(2), refused for a taken slug (2b), copied (3) and revoked (4), the marquee
with rings, count pill and hint (5), the area popover alone and anchored to its
tiles (6), and a used link with Sam, Remove and Revoke everyone's access (7).
The canvas stills composite the popover's panel where it sits.

Gate, run once under `.worktrees/.locks/app-build.sh` at the tip below, with an
isolated `TMUX_TMPDIR` and `CONTINUUM_APP_SUPPORT` and
`CONTINUUM_SKIP_UI_BASELINES=1`:

- `scripts/run-matrix.sh --collaboration`: 12 legs, passed. The native check
  printed 26 `PASS share entry` lines.
- `--sidebar-ownership-check`, `--agent-inbox-check`, `--floating-toolbar-check`,
  `--canvas-pointer-path-check`, `--tile-multiselect-check`,
  `--agent-face-switch-check`, `--workspace-sidebar-actions-check` and
  `--external-sessions-sidebar-check`: all exit 0.
- `ContinuumRevivedPaletteChecks`: exit 0, with Share… added to the expected
  rows.
- `ContinuumRevivedCoreChecks --onboarding-foundation-check` (the product
  registry, including the new `share.area` command and its fixed canvas `S`):
  exit 0.

Defects the witness caught while it was being written:

- A Remove left the session "working" forever, so the popover froze. `run` now
  restores the phase whatever the body did.
- A marquee over one tile drew no ring, because the overlay only drew for 2+
  tiles. The first assertion checked a hidden flag and passed. Marquee mode now
  draws rings only, for any count, and the witness counts drawn rings.

## A real Share against a local relay (after parts 2 and 3 merged)

`ShareEntryChecks` drives the popover against recorders for parts 1 and 2.
`ShareEntryRelayChecks`, the next stage of `--collaboration-native-check`,
drives the real thing. On branch `array/mp-share-real-witness`, off
`array/collaboration-finish` cfbbe5a1:

- **The relay.** It starts `continuum-relay` from beside the Array binary on
  loopback, with its own databases and keys, as
  `scripts/check-collaboration-pair.py` does. It enrolls the sender with
  `continuum-relay --collaboration-enroll`.
- **The account.** The production `CollaborationAccountController` enrolls
  over HTTP. Only its credential vault is in memory.
- **The production services.** The check installs them as is:
  `AppDelegate.shareLinks` and the delegate's own `SharedZoneCreating`. Copy
  goes to a private pasteboard.
- **A real header Share click, then Copy, through `NSApp.sendEvent`.** It
  asserts that:
  - the agent's tile becomes a projectless shared zone with its own view;
  - no runner is built, and the record stays bound to its tile;
  - the relay's area holds the agent as an observation;
  - the relay's link, with its slug and token, is on the pasteboard (it now
    carries the relay, `…?r=127.0.0.1:<port>#<token>`);
  - the relay lists the link as active.
- **A slug collision.** A second agent's share uses the first link's slug. It
  asserts that:
  - the relay refuses with 409, and the popover shows `slugTaken`;
  - the tile is back in its home zone with the same view and the same world
    frame;
  - no shared zone is left behind, and the first share is untouched;
  - the pasteboard still holds the first link.
- **Mutations, both RED at "the refused share puts the tile back in its home
  zone, same view, same frame":**
  - the session skips `cancelSharedZone` after a refused mint;
  - `AppDelegate.cancelSharedZone` skips `closeSharedAreaZone`.

`ShareEntryChecks.mountScene` is now shared by both stages.
`qaInstallShareEntry` takes optional services, and an omitted one stays
production.

Gate at 77b307c6, once under `.worktrees/.locks/app-build.sh`, with an isolated
`TMUX_TMPDIR` and `CONTINUUM_APP_SUPPORT` and `CONTINUUM_SKIP_UI_BASELINES=1`:
`scripts/run-matrix.sh --collaboration` ran 14 legs and passed. The native
check printed 11 `PASS share entry (relay)` lines and 26 `PASS share entry`
lines.

## Walkthrough defects fixed (branch array/mp-share-popover-fixes)

The real-flow walkthrough (`.worktrees/mp-preview/.plans/105-collaboration/WALKTHROUGH.md`)
found three popover defects. A fourth showed up while witnessing them.

1. **VoiceOver could not reach Copy link or the lifetime.**
   - Cause: `ComposerActionButton` and `ChoiceButton` are cell-less NSControls.
     Setting a role does not make such a view an accessibility element, so the
     tree showed their inner labels but never the buttons.
   - Fix: both components now call `setAccessibilityElement(true)`, and
     `ComposerActionButton` answers `accessibilityPerformPress`.
   - This is a fix in the shared components, so the composer's buttons are
     exposed too.
   - Witness: `ShareEntryChecks` leg 9 walks the popover panel's
     accessibility tree. It finds "Copy link" as a button and "Link lifetime"
     as a pop-up button reading "Works once". Pressing Copy through
     accessibility shares and copies, and pressing the lifetime opens its list.
2. **The popover hung off the canvas.**
   - Cause: a visible window *flies* its camera to a revealed tile
     (`navigateViewport`). The sidebar's Share presented immediately, so the
     popover hung from where the tile was. Placement used the whole screen, so
     the component clamped it to the screen edge, over the sidebar.
   - Fix: the popover now waits for the camera to settle. It is placed within
     the canvas's visible rect, through `ChoicePopoverController`'s own
     slide-and-flip region, so the toolbar is avoided too.
   - Witness, leg 10: the canvas sits beside a 320 pt rail, above a 240 pt
     strip.
     - Agent B starts off the canvas's left edge, and the reveal is forced to
       fly as in a visible window (`navigationFlightOverrideForQA`). The
       popover lies wholly inside the canvas and hangs from B's title bar.
     - Agent A's title bar sits just above the canvas's bottom edge. Its header
       Share flips the popover above the tile, inside the canvas.
3. **A TLS or transport failure said "Try it again".**
   - Fix: `ShareLinkOpener.message(for:relay:)` now maps `URLError` causes to
     plain words that name the relay:
     - offline;
     - a secure connection could not be made;
     - the relay could not be reached;
     - any other network failure.
   - Also: 404 means the link does not exist there, and other statuses name
     the relay and the code.
   - A spent and a revoked link share the relay's deliberate 410, so both say
     "already used, revoked or not valid".
   - Witness: `ShareEntryRelayChecks` drives the production opener with a
     newcomer's own account against the local relay.
     - TLS against the plain-HTTP relay gives the secure-connection message.
     - A closed port gives "could not reach the relay at 127.0.0.1:<port>".
     - The Works-once link admits its first newcomer.
     - A second newcomer gets the spent message, and a revoked link gets the
       same.
4. **The header popover closed when the tile's chrome rested.**
   - Cause: the popover was anchored to the band's Share button. When the
     pointer leaves a tile, its chrome rests and the drawn renderer detaches
     the band controls. A popover whose anchor leaves the window closes, so
     moving onto the popover closed it.
   - Fix: it now hangs from the tile itself, at the button's rect
     (`TileNSView.titleBarShareAnchor`).
   - Witness: with the popover open, `restChromeIfIdle()` with the pointer
     outside. The controls are drawn, the button is out of the window, and the
     popover is still open.

Mutations, each RED at its own leg:

| Mutation | RED at |
| --- | --- |
| Copy button not an accessibility element | "Copy link is not in the accessibility tree" (the tree lists only static text) |
| present before the reveal lands | "the popover hangs from the revealed tile's title bar, not from where the tile was" |
| place against the window, not the canvas | "near the canvas's bottom edge the popover flips above the tile and stays inside the canvas" |
| `URLError` mapping disabled | "a link whose relay answers without TLS says the secure connection failed", which got "Array could not open this share link. Try it again." |
| anchor to the detachable Share button | "the popover stays open when the tile's chrome rests" |

### Walkthrough round 2 (same branch)

5. **Share did nothing on an agent that was already shared.**
   - Cause: `shareTarget` skipped every tile whose zone has no project, and a
     shared zone has none.
   - Fix: a tile lent to a shared zone (`CanvasNSView.lentTile`) now resolves
     to that zone's `sharedAreaId`, and Share opens the area.
     - If the session that shared it is still alive, the popover shows its link.
     - Otherwise, for example after a relaunch, a fresh session opens in the
       new `.existing(area:)` phase. Only creation returns a token, so it shows
       the area's live links by slug, everyone admitted, New link, and a Revoke
       that ends every link on the area.
   - The Revoke for a link in hand now also ends the area's other links, so
     "Revoke everyone's access" means everyone.
   - Witness (`ShareEntryRelayChecks` leg 4): after the real share and a fresh
     coordinator, as after a relaunch, A's header Share on the lent tile opens
     the area's popover. It shows the live link and "Revoke link", and Copy
     reads "New link".
6. **An open popover never noticed a join.**
   - Fix: while open, it re-reads `listAccess(area:)` every two seconds
     (`ShareEntryCoordinator.accessRefreshInterval`). The refresh is
     area-wide: people across every link, deduplicated, inactive ones dropped.
   - Witness (leg 5), with the popover open:
     - Sam opens the Works-once link through the production opener.
     - Without reopening, the popover lists Sam with Remove and offers
       "Revoke everyone's access".
     - Priya is refused as spent.
     - New link mints a second link on the area.
     - Revoke everyone's access leaves every link revoked and Sam inactive on
       the relay.

| Mutation | RED at |
| --- | --- |
| `shareTarget` ignores lent tiles | "the header Share opened no popover" (the walkthrough's bug) |
| the open popover reads access once | timeout: "the open popover sees Sam join" |

Gate at a52d6f95, once under the lock, with an isolated `TMUX_TMPDIR` and
`CONTINUUM_APP_SUPPORT` and `CONTINUUM_SKIP_UI_BASELINES=1`.

- **`scripts/run-matrix.sh --collaboration`: 13 of 14 legs passed.** The
  native check printed 35 `PASS share entry` and 21 `PASS share entry (relay)`
  lines.
- **The one failure was `--shared-area-zone-check`,** in its host-offline
  stage: "back online, the edge is solid again". This is part 2's
  host-liveness timing, and this branch does not touch it. Re-run alone under
  the lock, it passed twice in a row, so it is flaky, not a regression.
- **Legs that read accessibility trees or drive the band and composer, exit
  0:**
  - `--agent-native-menu-check`, `--agent-tile-rename-check`
  - `--canvas-background-render-check`, `--canvas-background-settings-check`
  - `--managed-agent-page-zoom-check`
  - `--composer-key-routing-check`, `--composer-outline-check`
  - `--agent-face-switch-check`, `--canvas-pointer-path-check`
- **`--tile-surface-residency-check` fails, and the failure is pre-existing.**
  The message is "flag off must still pay the native cascade — a gesture that
  laid nothing out was not a gesture". I built the base 856e105e's sources in
  this bench, and it fails identically there. It is not on `MATRIX_KNOWN_RED`.

## Share on a lent agent, on the merged tip (branch array/mp-share-lent-header, off 9faf1156)

On `collaboration-finish` 9faf1156, the leg "the header Share opened no
popover" failed for an already-shared agent. These are the measurements, taken
before any change, and the two fixes they led to.

- **The failing press never reached a tile.**
  - The lent agent was at zoom 1, and its Share's centre was 14 points down,
    not in any resize band (`resizeEdge` nil).
  - The window's `hitTest` at that point returned nil: the tile was off
    screen.
  - `canvas.centerOnTile` had done nothing. `navigationTileSnapshots()` walks
    project `ZoneLayer`s only, so a lent tile cannot be navigated to.
  - The same gap made the sidebar's Share and reveal refuse a lent agent in
    the product (`revealAgentFromInbox` returns false).
  - On 856e105e the shared zone happened to sit in view, so the gap went
    unseen.
  - **Fix:** navigation snapshots now include each shared layer's lent tiles,
    at the zone origin plus the area frame.
- **The resize band does cover Share's top**, as the zone builder said. The
  edge-before-controls ordering predates c8e7679a.
  - Measured on 360-wide agent tiles: Share starts about 3 to 3.6 points below
    the top edge, and the band is 8 screen points deep. So Share's top 5 points
    at zoom 1, and more as the camera pulls out, pressed into a resize. That is
    a lent resize since c8e7679a, and a selection resize before it.
  - Share is hidden below zoom 0.85 on these tiles, so "half of Share at 0.5"
    applies only to wider tiles.
  - **Fix:** in `TileNSView.hitTest`, a point in an edge band that lies on a
    band control (anything except ×, which keeps its own rule) goes to the
    title bar, unless the edge is a corner.
  - In drawn mode the bar takes the press and hands it on, as it always has.
    The rest of each edge still resizes.

Witnesses, in the `ShareEntryRelayChecks` leg 3b, through `NSApp.sendEvent`
with a fresh coordinator:

- The production row action's Share reveals the lent agent and opens its
  area's popover.
- At the lowest zoom from 0.5 where Share shows (0.85), a press midway between
  Share's top and the band's bottom opens the popover. That holds for the lent
  agent and for a home agent.
- A right-edge drag on the lent agent at zoom 0.5 still resizes it in the
  area: 360 to 480.
- Leg 4's header Share on the lent tile passes again.

| Mutation | RED at |
| --- | --- |
| lent tiles left out of navigation | "the sidebar's Share reveals a lent agent rather than refusing" |
| the resize band beats header controls | "a press on the top of a lent agent's Share, inside the resize band, opens the popover" |

Gate at ff97bc78, once under the lock, with an isolated `TMUX_TMPDIR` and
`CONTINUUM_APP_SUPPORT` and `CONTINUUM_SKIP_UI_BASELINES=1`.

- **`scripts/run-matrix.sh --collaboration`: 13 of 14 legs passed.** The
  native check printed 35 `PASS share entry` and 25 `PASS share entry (relay)`
  lines.
- **`--shared-area-zone-check` failed once inside the matrix,** at a presence
  repaint budget: "the cursor overlay is what repaints for them". It passed
  when run alone later in the same gate, with the same binary. The previous
  gate failed it at a different stage, host offline, which also passed alone.
  Both are timing budgets in part 2's zone, not this change.
- **Exit 0:** `--canvas-pointer-path-check`, `--tile-multiselect-check`,
  `--agent-native-menu-check`, `--agent-tile-rename-check`,
  `--shared-area-zone-check` (alone) and `--floating-toolbar-check`.
- **`--agent-face-switch-check` fails, and the failure is pre-existing on the
  merged tip.** The message is "keyboard toggle: Ghostty's layer is still in
  the window's tree after its surface was freed". I built 9faf1156's own
  sources in this bench, and it failed there twice, identically. It passed at
  856e105e.

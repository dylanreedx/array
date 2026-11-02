# Share every tile kind

1 November 2026. Bench `.worktrees/multiplayer-share-browser-termin-55d526a6`,
branch `array/mp-share-kinds`, on `array/mp-portal` (99b6782e), itself on
`origin/array/integration` b0689628 (0.7.38).

Before this, only agents shared. A shared browser was dropped silently in
0.7.37, and the shared format knew only agent, file or diff snapshot,
discussion and agreement. Now a note, a file, a diff, a browser and a terminal
each share on their own from the header's Share icon, and land as one tile on
the guest's canvas, the same way a mode A agent does. The portal (mode B,
`array/mp-portal`) shows the same kinds through the same contract.

## What each kind does

| Kind | Host publishes | Guest sees | Guest can |
| --- | --- | --- | --- |
| Note | Its text as a sequence CRDT (`Collaboration.NoteText`), every keystroke as ops | An editor | Edit it with the host, live. Both people's edits survive, in the same order on both Macs. |
| File | The saved text, re-read when the file changes (cap 200 KB, text only) | The text, read only, re-drawn on every save | Read |
| Diff | The tile's git diff, re-run every 2 s, re-published when it changed (cap 200 KB) | The coloured diff, live | Read |
| Browser, public URL | URL, title, and pictures | The same URL, loaded in a browser on the guest's own Mac, following the host's navigation | Use the page with their own logins |
| Browser, localhost, LAN, file, or a page that will not load for the guest | URL, title, and pictures: WebKit snapshots as JPEG, at most 8 a second, only while the host's tile is on screen and only when the page changed, each under 180 KB | The host's page as pictures, marked "Dylan's browser" | Click and scroll; both land on the host's page |
| Terminal | The bytes its tmux pane wrote, at most 60 frames a second on a stream lane, and its screen as VT for anyone joining or behind ([114-terminal-sharing](../114-terminal-sharing/README.md)); its visible text when it is not in tmux | "Dylan's Terminal": a read-only Ghostty surface in the host's colours, at the host's grid | Scroll back. Typing is host-only; the relay refuses input to a terminal. |

Sharing a terminal needs a second press: the first Copy shows "This
terminal's output may contain secrets…" and publishes nothing; the button
becomes "Share anyway".

Everything else cannot be shared yet, and says so. The popover lists each such
selected tile as "<kind> · <title> can't be shared yet: <reason>"
(`AppDelegate.shareExclusion(for:origin:)`):

- file tree: it browses this Mac's disk;
- iOS preview: the simulator runs on this Mac and has no mirror yet;
- inspector: it inspects a page on this Mac;
- ticket and conductor queues: they read this Mac's ticket sources;
- board: not shared yet;
- run artifacts: they stay on this Mac;
- someone else's shared agent or tile: only its owner can share it.

In an area share (the portal) browsers go as their page or a still, and
terminals as a card that carries nothing. Nothing is dropped silently any more: `ShareTarget.excluded` holds
every selected tile that does not go, and `ShareLinkSession.publishedTileIDs`
what did.

## The contract (for the portal)

### On the relay: one item, one lane

- The area holds the tile as one `SharedArea.Item` of kind **`.liveTile`**,
  with a `Source` (owner, host, binding) exactly like an agent observation.
  The service admits it under the same rule: the owner's registered host.
- Its content travels on its own lane, `Collaboration.LiveTile`
  (`Sources/ContinuumRevivedCollaborationProtocol/CollaborationLiveTile.swift`),
  under `/collaboration/v1/areas/{area}/tiles/{object}/`:
  - `POST state`: the owner's host writes the latest whole `State` (kind,
    generation, revision, payload). Only the device that hosts the item, as
    its owner. A newer revision replaces the older.
  - `POST events`: any member with `.discuss` appends an `EventBody`
    (`noteOps`, `browserClick`, `browserScroll`). The relay stamps author and
    sequence. Input to a kind that takes none from guests (file, diff,
    terminal) is refused with 403.
  - `POST read`: any member long-polls (up to 25 s) for a newer state and the
    events after a cursor. An unchanged state is omitted.
- Both live in the relay's memory only: nothing durable, no migration. A relay
  restart drops the lane; the host republishes within 10 s, and note edits are
  idempotent CRDT ops.
- Request bodies stay under the existing 256 KiB cap: a state's payload is at
  most 240 KiB, an event 128 KiB. No new transport.

**Backwards compatibility.** Every route, table and document field that
existed is unchanged. `.liveTile` is a new `SharedArea.Kind` case, and a
0.7.38 client cannot decode an area that holds one.

- **What 0.7.38 sends.** Nothing that names its version or what it can read:
  no header, and no field in `links/join` or `links/accept`. The default
  User-Agent carries the build number, but every dev build reports build 1,
  so it cannot tell old from new.
- **The signal.** Every client from this branch sends
  `x-array-collaboration-capabilities: live-tile` with every request
  (`Collaboration.LiveTile.capabilityHeader`). Old relays ignore it.
- **The refusal.** `links/join` and `links/accept` to an area that holds a
  live tile, without that header, answer **426 `updateRequired`**. The check
  sits inside the join transaction, before anyone is created or admitted and
  before a "Works once" link is spent.
- **What a 0.7.38 user sees.** 0.7.38 words relay errors by status only, and
  its own sentences for 404, 410 and 429 would all be untrue here. So it shows
  its generic line: "Array could not open the link: the relay at … answered
  with an error (426). Try it again later." Before this it was admitted, the
  link was spent, and it then said "You were admitted, but the shared
  workspace could not load."
- **Newer clients** that meet a 426 say "This share needs a newer version of
  Array. Update Array, then open the link again. The link still works."
- Areas with no live tile (one agent, or a portal's agents and artifacts)
  open for 0.7.38 exactly as before.
- **Witnesses.** `--live-tile-only` drives raw old-style joins and accepts at
  the real routes; it fails if the refusal is removed. Driven by hand,
  `check-multiplayer-journey.py --old-guest ReleaseJourney` opens a live-tile
  link in the real 0.7.38 app (bundles built at b0689628) against a local relay.

### On the host: `SharedAreaHostSession` hosts every kind

- Publish: `ShareLinkCoordinator.publish(selection:intoArea:live: true)`.
  With `live`, agents go as observations and notes, files, diffs, browsers and
  terminals as `.liveTile`. Without it (the 0.7.37 zone) nothing changes.
- Host: any `SharedAreaHostSession` whose `liveTileSources` is set hosts each
  `.liveTile` binding it owns with a `LiveTileHost` and a kind's
  `LiveTileSource` (`AppDelegate.makeLiveTileSource`). `startHostingSharedAgent`
  sets it, so a portal that hosts its area through that call gets every kind.
  Heartbeats, liveness and relaunch resume are the agent's.

### Inside a portal

Rebased onto `array/mp-portal`. The portal keeps its own contract
([PORTAL-CONTRACT.md](PORTAL-CONTRACT.md)): every non-agent tile is an
`artifact` item, read only for the guest. `Portal/SharedPortalLiveKinds.swift`
implements its note, file, diff and browser kinds and draws them with the same
`LiveTileBodyView` (read only, "Still" for a private page). Terminals are the
portal's "stays on Dylan's Mac" card. Live two-way editing and browser input
are what sharing a tile on its own adds.

### On the guest: `LiveTileBodyView` renders one item

- `LiveTileBodyView(kind:hostName:)`, then `attach(controller:object:)` with a
  connected `SharedAreaController`. It reads the lane, draws the kind, and
  sends this person's input. `inputEnabled = false` when sharing stopped.
- The `.sharedTile` tile (`SharedTileNSView`) is one body plus the
  owner tab, offline footer and placeholder. A portal places one body per
  item at the item's frame. The body draws at whatever size it is given.

### Guest tile: `.sharedTile`

- New `TileKind.sharedTile`. It persists only `TileMetadata.sharedTile`, a
  `SharedAgentTileReference` with `liveKind` set (area, object, host name,
  host person, account). `WorkspaceAPIExposure`: `.internal`.
- Spawned by `TileSpawner.spawnSharedTile` through one target zone (hazard 9),
  built by `makeHydratedTileView` and the boot walk.
- Hazard 10: an install with no account, another account, or an older build
  that does not know the kind shows a placeholder and opens no connection.

## Witnesses

- `scripts/check-multiplayer-journey.py --relay local --only kinds`: two real
  apps on a local relay. For each kind the host shares it from the header,
  the guest opens the link, a host change appears on the guest, and the
  guest's action reaches the host: a note edit merges both ways (including
  two edits at one spot), a browser click lands on the host's page, the
  terminal refuses the guest's typing at the view and at the relay. Then an
  area selection holding a file tree lists it with its reason.
- `ContinuumRevivedCollaborationChecks --note-text-only`: the CRDT converges
  under random concurrent edits in any delivery order, keeps both of two edits
  at one spot, and round-trips its snapshot.
- `ContinuumRevivedCollaborationChecks --live-tile-only`: the relay lane
  against a real local relay: owner-only state, read-only terminal, guest
  note ops and browser input accepted, cursor, floor, and removal.
- `Array --shared-tile-render-check`: each kind's guest body rendered in light
  and dark, off screen.
- `Array --portal-kinds-check`: the note, file, diff and browser kinds through
  the portal contract on a mounted canvas, light and dark.

## Honest limits

- A "signed-in" public page is detected only when it fails for the guest
  (401/403 or no load); the guest then falls back to the host's pictures.
- Pictures stop while the host's tile is off screen or parked: the guest keeps
  the last one.
- Click coordinates assume page zoom 1 on the host.
- Note cursors and selections of the other person are not drawn (nice to have).
- The public-URL leg of the journey needs network; offline it prints a NOTE.

# Portal contract: what a shared tile kind implements

1 November 2026. Mode B of [SHARE-REDESIGN.md](SHARE-REDESIGN.md).
Branch `array/mp-portal`, bench `.worktrees/mp-portal`.

The portal lead owns the portal tile and agents in it. A sibling helper owns
the other kinds: notes, files and diffs, browsers, terminals. This page is
the line between the two. The Swift side of it compiles and is committed:

- `Sources/ContinuumRevivedCore/Collaboration/SharedPortal.swift`: wire types.
- `Sources/ContinuumRevived/App/Collaboration/Portal/SharedPortalKind.swift`:
  the protocol, the item view base class, the host and guest contexts.
- `Sources/ContinuumRevived/App/Collaboration/Portal/SharedPortalKinds.swift`:
  the catalog, one line per kind, and the fallback kind.
- `Sources/ContinuumRevived/App/Collaboration/Portal/SharedPortalAgentKind.swift`:
  the reference implementation (agents).

If something here is wrong for your kind, say so in this file (a short
"Sibling notes" section at the end) rather than working around it.

## The idea in five lines

1. A portal is an ordinary shared area. **The relay needs no change.**
2. Agents are `agentObservation` items, as in mode A.
3. Every other shared tile is one `artifact` item. Its revisions are its
   content: the first is the snapshot, each later one a delta.
4. One more `artifact` item, the **manifest**, names each item's kind and
   title. Its object ID is the area's own ID.
5. Where a tile sits is the document's `.place` geometry: the host's world
   frame minus the portal's origin. The portal publishes it, never a kind.

## Who owns what

| | Portal (lead) | Kind (you) |
| --- | --- | --- |
| Creating the area, links, access, revoke | yes | |
| Admitting items, the manifest, titles | yes | you supply `publishedTitle` |
| Positions and moves (`.place`) | yes | |
| "Add to share" | yes | |
| Host liveness, offline, stopped | yes, works out the state | you draw it (`apply(state:)`) |
| Cursors and follow | yes | |
| Guest camera (pan, zoom, fit) | yes | |
| Rate limits, dedupe, retries, conflicts | yes | |
| What content a tile publishes, and when | | yes |
| How the guest draws it | | yes |
| Guest actions on your kind (approve a diff) | gives you `guest.review` | yes |

## The protocol

```swift
@MainActor
protocol SharedPortalKind {
    var itemKind: SharedPortal.ItemKind { get }
    // Host
    func shareRow(for tile: Tile) -> SharedPortalShareRow          // popover row
    func publishedTitle(for tile: Tile) -> String                   // guest's title
    func snapshot(tile: Tile, host: SharedPortalHostContext) async throws -> SharedArtifactProducer.Draft?
    func observe(tile: UUID, host: SharedPortalHostContext,
                 publish: @escaping @MainActor (SharedArtifactProducer.Draft) -> Void) -> (any SharedPortalObservation)?
    // Guest
    func makeView(entry: SharedPortal.Entry, guest: SharedPortalGuestContext) -> SharedPortalItemView
}
```

### Host side

- **`snapshot`** runs once, at Copy, and again when the tile is added with
  "Add to share". Return nil for a kind that sends no content (terminals).
  Do slow work (git, WebKit snapshots) off the main actor and await it.
- **`observe`** starts when the share is live and stops (`cancel()`) when it
  is revoked, the tile closes, or the app quits. Call `publish` whenever the
  content may have changed; you need no debounce of your own. The portal:
  - drops a draft whose `contentDigest` equals the last one sent;
  - keeps only the newest while a send is out;
  - sends at most one revision per item every `SharedPortalHost.minimumInterval`
    (0.5 s), and the newest always goes in the end.
- **A draft** is `SharedArtifactProducer.Draft`. Two ways to make one:
  - **Portal payload** (notes, browsers): `SharedPortal.jsonDraft(value, name:
    "note", extra: [...])` or `SharedPortal.payloadDraft([name: Data])`. Entries
    land under `array-portal/` as `text/plain`. Binary content (a still)
    travels base64 in an entry whose name ends `.b64`.
  - **Real git capture** (files, diffs): `SharedArtifactSource.resolve(...)` then
    `.draft()`, as the shared zone did. These keep their real paths, so the
    existing artifact reader and the review route work unchanged.
- **Limits** are the relay's: 1 MiB an entry, 8 MiB a revision, 64 MiB for the
  whole area over its life. Each revision costs its bytes again. A still of a
  browser should be a JPEG-sized PNG, well under 1 MiB, and not resent while
  the page is unchanged.
- **`SharedPortalHostContext`** gives you `tile(id)` (record, world frame),
  `tileView(id)` (the live view when hydrated), `projectRoot(forTile:)` and
  `app` (the `AppDelegate`) for anything else.
- **Privacy.** A kind decides what leaves the Mac. Terminals send nothing
  but a position and the title "Terminal". Nothing sends a path outside the
  project, an environment, a credential or a cookie.

### Guest side

- **`makeView`** returns a `SharedPortalItemView` subclass. The portal:
  - sizes it in **host points**: `bounds.size` is the host tile's size and
    `frame` is that rect at the portal's zoom, so AppKit scales your drawing.
    Never assume `bounds == frame`;
  - calls `apply(contents:)` with the latest revision, read and verified,
    each time the head changes (never per frame). Nil until the first one
    arrives; always nil for a kind that publishes none;
  - calls `apply(state:)` with `.live`, `.offline(lastSeen:)` or
    `.stopped(reason)`. The base class dims offline and stopped. Keep
    drawing the last content you were given;
  - shows your `hoverActions` while the pointer is over the item;
  - reads `qaFacts` for the witness (below).
- **The guest cannot change the host's tiles.** No editing, no moving, no
  typing into a host's terminal. Clicks your view handles itself are fine
  (scrolling a note, Approve on a diff, a public page in a browser).
- **`SharedPortalGuestContext`** gives you `controller` (the area), `hostName`,
  `hostColour`, and `review(object:revision:verdict:note:)` for diffs.
- Use Array's tokens (`SurfaceToken`, `TextToken`, `LineToken`, `NSFont.token`)
  and shared components. A view that conforms to `TokenThemed` owes hazard 8
  (`UIProbeAppearance.swift`); the portal's appearance sweep renders every
  kind, so register your owner there.
- `SharedPortalCardView` is a titled card with one line of text; subclass it
  for placeholder states if it helps.

## What each kind delivers

Step numbers are SHARE-REDESIGN.md's mode B acceptance steps.

| Kind | Host publishes | Guest shows | `qaFacts` the journey asserts | Steps |
| --- | --- | --- | --- | --- |
| Agent (lead) | `agentObservation`, mode A's projection | live projection, read-only; hover "Open beside" | `transcript`, `editable: "false"` | 3, 7 |
| Note | text on each save | the text, live, read-only | `text`, `editable: "false"` | 5 |
| File | a `.files` git capture on save | the file, newest revision | `revision` (sequence), `text` | B2 |
| Diff | a diff git capture on change | the diff; Approve and Request changes | `revision`, `reviewed` | B2 |
| Browser, public URL | `{url, mode: "live"}` | the page, loaded on the guest's Mac | `mode: "live"`, `url` | 6 |
| Browser, localhost or private | `{url, mode: "still"}` + a still picture | the still, marked "Still" | `mode: "still"`, `badge: "Still"` | 6 |
| Terminal | nothing | "Terminal stays on Dylan's Mac" | `message` | 1, 2, 6 |

"Public" means `http(s)` to a host that is not loopback, not `.local`, not a
private or link-local address, and has no credentials in the URL. Anything
else is private and goes as a still. Cookies and sessions never travel.

The fallback kind (`SharedPortalFallbackKind`) already covers terminals
correctly and every other kind as a title-only card, so the portal works
end to end before each kind lands.

## Where your code goes

- One file per kind under `Sources/ContinuumRevived/App/Collaboration/Portal/`,
  for example `SharedPortalNoteKind.swift`.
- Replace that kind's `SharedPortalFallbackKind(...)` line in
  `SharedPortalKinds.kind(for:)` with yours. Leave the `.agent` line alone.
- Checks: a `--portal-<kind>-check` app leg per kind, registered in
  `scripts/run-matrix.sh` by **adding lines only** (some lines are pinned
  verbatim by other checks) and in
  `docs/38-tickets/90-agent-ux/matrix-inventory.txt`. Drive the real
  `snapshot`/`observe` on a real tile and the real `makeView` →
  `apply(contents:)` path, light and dark, offscreen, never taking focus.
- The two-app journey (`scripts/check-multiplayer-journey.py`, mode B) is the
  lead's; it asserts your `qaFacts` keys above through the real relay.

## Wire details, for reference

- Manifest: object ID = area ID, `artifact` kind, placed at
  `SharedPortal.manifestRect` (1 pt at the area origin, never drawn). Each
  revision is `SharedPortal.Manifest` as `array-portal/portal.json`.
- An area is a portal when it holds the manifest item
  (`SharedPortal.isPortal`). A single `agentObservation` item and nothing else
  is still mode A.
- A 0.7.37/0.7.38 shared zone (no manifest) opens as a portal too: agents as
  agents, `discussion`/`agreement` items as notes, artifacts as files or diffs.
- Unknown `ItemKind` raw values decode as `.unknown` and draw as a card.
- Positions: `SharedPortal.areaRect(world:origin:)`. The origin is the top-left
  of the frames chosen at Copy, and never moves afterwards.
- Cursors: area coordinates on the existing cursor lane, sent only while the
  pointer is over a shared tile.

## Sibling notes

(Add yours here.)

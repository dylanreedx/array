# Multiplayer part 1: share links

Bench `.worktrees/mp-share-links`, branch `array/mp-share-links`, base
`array/collaboration-finish` c7131f8f. Design: `IN-CANVAS.md`, "Round 2".

## The API for parts 2 and 3

Code against this. It is the contract; the receipt below says what is built
and witnessed.

Round 2 (lead decision, 31 October): part 2 owns the sender side.
`createSharedZone(fromTiles:name:)` creates the area, publishes and binds the
tiles, and opens the zone. Share links only mint and manage links on an area
that already exists.

The app owns one `ShareLinkCoordinator`, `AppDelegate.shareLinks`, on the main
actor. It is created on first use, so starting Array still reads no
collaboration credential.

```swift
// Sources/ContinuumRevived/App/Collaboration/ShareLinkCoordinator.swift
@MainActor
final class ShareLinkCoordinator {
    /// Mints a link on an existing area. Creates, publishes and opens nothing.
    /// The link carries the sender's relay. Throws ShareLinkFailure.slugTaken
    /// when a live link on the relay already uses the slug.
    func createShareLink(area: UUID, slug: String, lifetime: Collaboration.ShareLinkLifetime) async throws -> Collaboration.ShareLink

    /// "New link" for an area that is already shared (panel 5). Same as createShareLink.
    func newLink(area: UUID, slug: String, lifetime: Collaboration.ShareLinkLifetime) async throws -> Collaboration.ShareLink

    /// Revokes the link and removes everyone it admitted.
    func revokeLink(area: UUID, link: UUID) async throws

    /// Removes one person admitted through the link. They cannot reopen it.
    func removeAccess(area: UUID, link: UUID, person: SharedArea.ID<SharedArea.Person>) async throws

    /// Every link on the area with its status and the people it admitted.
    func listAccess(area: UUID) async throws -> [Collaboration.ShareLinkAccess]

    /// The one entry point for array://, array-dev:// and https://arrayapp.dev/s/
    /// links. A refusal is presented, never silent.
    @discardableResult
    func open(_ url: URL) async -> ShareLinkOpenOutcome

    /// Publish-by-kind, handed to part 2 to call after it creates the area:
    /// agents as live observations, notes as discussion, diffs and files as
    /// snapshots; terminals and other kinds stay private. No review window.
    /// Returns source tile id -> published object for every source-bound item
    /// (agents and snapshots). Note items have no source binding in the domain,
    /// so they are not in the map.
    @discardableResult
    func publish(selection: SharedAreaPublication.Selection, intoArea area: UUID) async throws -> [UUID: SharedArea.ID<SharedArea.Object>]
}

enum ShareLinkOpenOutcome: Equatable {
    case opened(area: UUID)
    case refused(String)     // user-facing sentence, also shown in the app
    case cancelled           // sign-in or the name prompt was dismissed
}
```

Protocol types, `ContinuumRevivedCollaborationProtocol/CollaborationShareLinks.swift`:

```swift
extension Collaboration {
    enum ShareLinkLifetime: String, Codable { case once, untilRevoked }   // "Works once" / "Until revoked"
    struct ShareLink {            // returned once, at creation; the only value holding the token
        let id: UUID; let area: SharedArea.ID<SharedArea.Area>; let slug: String
        let token: String; let lifetime: ShareLinkLifetime; let createdAt: Date
        let relay: String?        // filled by the creating client from its endpoint
        var url: URL      // https://arrayapp.dev/s/<slug>?r=<relay>#<token>  (what Copy link copies)
        var appURL: URL   // array://s/<slug>?r=<relay>#<token>
    }
    struct ShareLinkAccess {      // listAccess rows; never carries the token
        enum Status: String { case active, used, revoked }
        let id: UUID; let area: SharedArea.ID<SharedArea.Area>; let slug: String
        let lifetime: ShareLinkLifetime; let status: Status; let createdAt: Date
        let people: [ShareLinkPerson]
    }
    struct ShareLinkPerson { let person: SharedArea.ID<SharedArea.Person>; let label: String; let admittedAt: Date; let active: Bool }
}
enum ShareLinkURL {
    static let webPrefix: String               // "arrayapp.dev/s/", the fixed part of the field
    static let appScheme = "array", devAppScheme = "array-dev"
    static func isValidSlug(_: String) -> Bool  // a-z 0-9 and single hyphens, 1-64
    static func suggestedSlug(from title: String) -> String
    static func parse(_ url: URL) -> (slug: String, token: String, relay: String?)?
}
```

Rules the service enforces:
- The slug is unique per relay among live links. A revoked or spent link
  frees its slug.
- The token is 32 random bytes, base64url, and is stored only as a hash.
- Whoever opens a valid link gets the `editor` role. Prompting is part 4.
- A valid token doubles as an enrollment. Someone with no account on the relay
  joins with only a display name, and gets a person and a device admitted to
  that one area. Nothing else on the relay is granted.
- "Works once" is spent by the first accept or join. The person it admitted can
  open it again to get back in; nobody else can.
- "Until revoked" admits any number of people.
- Revoke works on both kinds and removes everyone admitted through the link.
- A person removed from a link cannot rejoin through that link.
- A link dies when its creator loses the owner role or their device is revoked.

## Receipt

31 October 2026. Round 2 follows the lead's five decisions.

### What is built

Service (`ContinuumRevivedCollaborationService/CollaborationShareLinks.swift`):
- A new migration `collaboration-share-links-v1` adds two tables, `share_links`
  and `share_link_admissions`.
- A partial unique index keeps slugs unique among live links.
- `CollaborationStoreError.slugTaken` maps to HTTP 409 `slugTaken`.
- Accept and join share one validity check (`liveLink`) and one admission
  (`admit`).
- `joinShareLink` creates the person (with the display name as label), their
  first device and credential, and the admission, all in one transaction.
- `removeMember` also closes that person's link admissions on the area, so a
  person removed by any route cannot walk back in through an until-revoked link.
- Revoke and remove both bump the area epoch, as `removeMember` does.

Routes (`CollaborationRoutes.swift`):
- `POST /collaboration/v1/links/join` is unauthenticated. The link token is the
  admission, the same way an enrollment code is for `enrollments/redeem`.
- These are behind the device bearer:
  - `POST /collaboration/v1/areas/{area}/links` creates a link.
  - `GET /collaboration/v1/areas/{area}/links` lists links. Owner only.
  - `DELETE /collaboration/v1/areas/{area}/links/{link}` revokes one.
  - `DELETE /collaboration/v1/areas/{area}/links/{link}/people/{person}`
    removes one person.
  - `POST /collaboration/v1/links/accept` admits through a link.

Client: `CollaborationAPI` has the six calls.

Core:
- `CollaborationAccountTransport` gains the six calls. Default implementations
  refuse with 404, so existing fakes compile unchanged.
- `CollaborationAccountController`:
  - `createShareLink` stamps the link with the account's relay
    (`CollaborationServiceEndpoint.shareLinkRelay`: host, port and path, no
    scheme).
  - `joinShareLink(endpoint:slug:token:displayName:deviceLabel:)` saves the new
    device credential and selects the account exactly as `enroll` does, then
    loads the area and remembers it under the slug.
  - `acceptShareLink`, `shareLinks`, `revokeShareLink` and
    `removeShareLinkPerson`.
- `CollaborationServiceEndpoint(shareLinkRelay:)` builds an https endpoint from
  a link's relay. Plain http is allowed only for loopback, and only where the
  caller allows it, which is local checks.
- `ShareLinkOpener` runs the receiving flow. For a link with a relay:
  1. Use this Mac's account on that relay, if it has one.
  2. Otherwise ask for a display name and join through the token.
  For a link without a relay, the old flow stays: a remembered account, or the
  hub's sign-in. Either way it then admits and opens.

App:
- `Packaging/Info.plist` registers `array`.
- `scripts/make-app-bundle.sh` stamps Dev bundles to `array-dev`. Film and
  custom-id bundles get no URL type at all.
- `scripts/check-app-bundle.sh` asserts the scheme: `array` for prod,
  `array-dev` for dev.
- `AppDelegate.application(_:open:)` routes `array://s/...`, `array-dev://s/...`
  and `https://arrayapp.dev/s/...` to `shareLinks.open`. Other URLs are ignored.
- The newcomer's name prompt is an `NSAlert` sheet on the canvas window with
  one field, "Your name", prefilled with the macOS full name. Its buttons are
  Join and Cancel, and it says which relay you join through. Nothing else is
  asked: no code, no password, no key.
- Inline hub sign-in remains only for links without a relay.
- A refusal shows as an `NSAlert` sheet on the main window.
- `AppDelegate.collaborationAccountModel()` keeps one account model for the hub
  and share links.
- `openSharedArea(controller:person:area:model:)` is the single open path, used
  by the hub and by a received link. Part 2 swaps what it opens from a window
  to the zone.
- `--collaboration-native-check` deadline raised from 45s to 90s. The journey
  runs in 34-42s.

Website:
- `website/src/pages/s/index.astro`, plus a Vercel rewrite from `/s/:slug` to
  `/s`.
- The page reads the slug from the path, the relay from `?r=`, and the token
  from the fragment, which the site never receives.
- It opens `array://` at once and as its primary button. It also offers the
  Mac DMG and a smaller "Open in Array Dev" link (`array-dev://`).
- 4 unit tests are in `src/lib/share-links.test.ts`.
- Committed locally, not pushed.

### Witnesses

All of them run inside existing legs. No inventory records were added.

`ContinuumRevivedCollaborationChecks`, `runShareLinkChecks`: 27 checks. They use
production account controllers, the production `ShareLinkOpener` and the real
NIO routes over HTTP. They cover:
- the link carries its relay, and parses in both forms
- single-use is spent after one accept, and its person can reopen it
- an until-revoked link admits two people
- revoke cuts both, and only them
- a revoked link refuses newcomers and does not readmit
- a wrong token is refused and shows as refused
- a link without its token is refused as incomplete
- a slug collision is refused across owners
- a spent link's slug is free again
- an editor cannot mint a link
- removing one person blocks only them
- **a fresh client with no account joins through the link alone, picking only a
  display name**: it becomes an editor, is listed on the link, reopens with its
  saved device, and is cut by revoke
- joining through a spent link, with a wrong token, or after dismissing the
  name prompt saves no account and admits nothing
- a link without a relay falls back to the existing sign-in

`ContinuumRevivedCollaborationServiceChecks`: the boundary audit probes the 4
new area routes. A non-member gets the same answer for a real area as for a
random one, 26 routes in all.

`Array --collaboration-native-check`, stage "share links", `ShareLinkAppChecks`:
9 checks.
- `publish(selection:intoArea:)` from a mounted workspace selection publishes
  the agent as an observation and the note as discussion, with no review
  window, and maps the agent tile to its object.
- `createShareLink(area:)` only mints. It creates, publishes and opens nothing,
  and the link carries the relay.
- A slug collision comes back as `ShareLinkFailure.slugTaken`.
- A signed-out Mac given an https link through AppKit `application(_:open:)`
  sees one name sheet (no hub, no enrollment code), then joins, admits and
  opens the area.
- `array://` and `array-dev://` reach the same entry point and reuse the saved
  account.
- A wrong token puts a refusal sheet on the canvas window.
- Unrelated URLs are not routed.
- A link without a relay signs in through the hub's Connect.

Mutations. Each was applied, rebuilt and run, and each went RED. Round 1:

| Mutation | Red check |
|---|---|
| Drop the single-use spend | "a single-use link is spent after one accept" |
| Spend until-revoked links too | "an until-revoked link admits two people" |
| Revoke without cutting admissions | "revoke cuts both people…" |
| Accept by slug without the token | "a wrong token is refused…" |
| Skip the slug check | the collision returned 500 `storageFailure` instead of 409, and the run threw |
| URL handler routes nothing | the inline sign-in check |
| The coordinator's open does nothing | an area-open check |
| Refusal presenter does nothing | "the refusal is shown on the canvas window" |

Round 2:

| Mutation | Red check |
|---|---|
| Opener ignores the link's relay | "a fresh client with no account joins through the link alone…" |
| Join creates the person without admitting them | "a fresh client with no account joins through the link alone…" |
| Minted link carries no relay | "the link is arrayapp.dev/s/<slug>?r=<relay>#<token>…" |
| The app never asks for the name | "a signed-out Mac joins from an https://arrayapp.dev/s/ link alone…" |
| `array-dev://` not routed | "array:// and array-dev:// reach the same entry point…" |

Gate run (round 2): `scripts/run-matrix.sh --collaboration`, once, under
`.worktrees/.locks/app-build.sh`, with an isolated `TMUX_TMPDIR` and
`CONTINUUM_APP_SUPPORT`, `TMUX`/`TMUX_PANE` unset, and
`CONTINUUM_SKIP_UI_BASELINES=1`. Result: "Collaboration matrix (targeted)
passed", 11 legs, at ca489a8d plus the bundle and website commits. The log
shows all 27 `PASS share links:` lines, all 9 `PASS share links (app)` lines,
and the boundary audit's 26 routes. The Linux relay leg is green, including the
new join route. The one note is the existing `--ui-probe-check` display skip.

### Round 3 (31 October)

**Join rate limit** (cb1b3732):
- `POST /links/join` allows 10 joins per link and 30 per client address in a
  rolling hour. Over either limit the relay returns 429 `rateLimited` and
  creates nothing, because the check runs inside the join's transaction before
  any insert.
- Only joins that would succeed count.
- Each join is logged in `share_link_joins`, keyed by link and by a hash of the
  address. Rows older than the window are pruned on every join. The log is
  durable, so a relay restart does not reset the counts.
- Overrides: `RELAY_COLLABORATION_LINK_JOINS_PER_LINK`,
  `RELAY_COLLABORATION_LINK_JOINS_PER_ADDRESS` and
  `RELAY_COLLABORATION_LINK_JOIN_WINDOW_SECONDS`. A malformed value fails
  startup, the same rule as the existing retention overrides.
- The address is the socket peer, unless `RELAY_CLIENT_ADDRESS_HEADER` names a
  trusted proxy header. `fly.toml` now sets `fly-client-ip`: behind Fly's proxy
  every socket peer is the proxy, so without it the per-address limit would be
  one global limit. This is a config edit only; nothing was deployed.
- The app shows a refused link's 429 in plain words: "Too many people joined
  through this link recently…".
- Documented in `docs/internals/collaboration.md`.

Witness: 3 more checks in `runShareLinkChecks`, over real HTTP against a second
relay with limits of 3 per link and 5 per address, behind a test header that
stands in for `fly-client-ip`.
- The 4th join through a link returns 429 from any address, and adds no person
  and no admission. People are counted with `operatorPeople()`.
- An address's limit spans links and leaves other addresses alone.
- A rate-limited newcomer through the production `ShareLinkOpener` sees the
  message, and no account is saved.

| Mutation | Red check |
|---|---|
| No per-link limit | "a link's join limit answers 429…" |
| No per-address limit | "an address's join limit spans links…" |
| Proxy header ignored, so the socket peer is used | "an address's join limit spans links…" |

**The /s page, rendered headless.** Steps:
1. `astro build`.
2. Serve `dist/` from a throwaway local server that applies the `vercel.json`
   rule through `path-to-regexp`, the same matcher family Vercel uses.
3. Drive headless Chromium. No visible window, no focus taken.

Every response from the local server has its
`window.location.href =` rewritten to record the hand-off instead of following
it, so no `array://` link was ever opened. The first two attempts did not
rewrite the page's inlined script. The hand-off ran and the navigation stalled.
No installed build registers `array://` yet, and `/Applications/Array.app` kept
its pid, so nothing was opened.

19 checks PASSED:
- The rule `/s/:slug` → `/s` matches `/s/checkout-redesign` and `/s/team-2`.
  It does not match `/s/a/b`, `/s/`, `/s`, `/share/x` or `/docs/s/x`.
- `/s/<slug>?r=<relay>#<token>` is served through the rewrite and hands off
  to exactly `array://s/<slug>?r=<relay>#<token>`.
- "Open in Array" is shown first and links to `array://`. "Download Array for
  Mac" is second and points at the latest `Array.dmg`. "Open in Array Dev"
  links to `array-dev://`.
- The title names the slug.
- No request carries the token.
- A link without its token hands off nothing, says so, and still offers the DMG.

The script and the light and dark screenshots are in
`qa-runs/share-page/` on the bench (ignored, not committed). The site has no dark
theme, so both captures look the same, the same as `/pair`. The real Vercel
rewrite is still unproven until a preview deploy.

### Open, for the lead

- **Universal link: later, per your decision.** `https://arrayapp.dev/s/...`
  reaches the app only through the website's hand-off. The later step is
  Associated Domains on the Mac, plus an AASA `/s/*` entry; the AASA file today
  covers only `/pair`.
- **A link can point a newcomer at any relay.** That is inherent in carrying
  `r=`. The name sheet says which relay it is, and credentials are scoped per
  endpoint, so nothing from another relay is exposed. A malicious link could
  still enroll someone on a stranger's relay.
- **An until-revoked link can mint unlimited people.** The relay has no rate
  limit on joins. Revoking stops it.
- **The website page was not opened in a browser.** It was built and its
  hand-off logic unit-tested. The Vercel rewrite is untested locally, because
  `astro preview` does not apply `vercel.json`.
- **`check-app-bundle.sh` was not run here.** Its new scheme assertion runs in
  the full matrix's bundle leg, not in `--collaboration`. The PlistBuddy stamping
  was checked on a copy of `Info.plist`.

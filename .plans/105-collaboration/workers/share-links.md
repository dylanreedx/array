# Multiplayer part 1: share links

Bench `.worktrees/mp-share-links`, branch `array/mp-share-links`, base
`array/collaboration-finish` c7131f8f. Design: `IN-CANVAS.md`, "Round 2".

## The API for part 3 (share entry points and popover)

Code against this. It is the contract; the receipt below says what is built
and witnessed.

The app owns one `ShareLinkCoordinator`, `AppDelegate.shareLinks`, on the main
actor. It is created on first use, so starting Array still reads no
collaboration credential.

```swift
// Sources/ContinuumRevived/App/Collaboration/ShareLinkCoordinator.swift
@MainActor
final class ShareLinkCoordinator {
    /// Creates a new area named by the slug, publishes the selection into it
    /// (agents as live observations, notes as discussion, diffs/files as
    /// snapshots, terminals and other kinds left out), mints the link and opens
    /// the area for the sender. Signs in inline first when needed.
    /// Throws ShareLinkFailure.slugTaken when the slug is live elsewhere on the relay.
    func createShareLink(selection: SharedAreaPublication.Selection, slug: String,
                         lifetime: Collaboration.ShareLinkLifetime) async throws -> Collaboration.ShareLink

    /// "New link" for an area that is already shared (panel 5).
    func newLink(area: UUID, slug: String, lifetime: Collaboration.ShareLinkLifetime) async throws -> Collaboration.ShareLink

    /// Revokes the link and removes everyone it admitted.
    func revokeLink(area: UUID, link: UUID) async throws

    /// Removes one person admitted through the link. They cannot reopen it.
    func removeAccess(area: UUID, link: UUID, person: SharedArea.ID<SharedArea.Person>) async throws

    /// Every link on the area with its status and the people it admitted.
    func listAccess(area: UUID) async throws -> [Collaboration.ShareLinkAccess]

    /// The one entry point for array://s/<slug>#<token> and
    /// https://arrayapp.dev/s/<slug>#<token>: parse, sign in inline when needed,
    /// admit, then open the area. A refusal is presented, never silent.
    @discardableResult
    func open(_ url: URL) async -> ShareLinkOpenOutcome
}

enum ShareLinkOpenOutcome: Equatable {
    case opened(area: UUID)
    case refused(String)     // user-facing sentence, also shown in the app
    case cancelled           // sign-in was dismissed
}
```

Protocol types, `ContinuumRevivedCollaborationProtocol/CollaborationShareLinks.swift`:

```swift
extension Collaboration {
    enum ShareLinkLifetime: String, Codable { case once, untilRevoked }   // "Works once" / "Until revoked"
    struct ShareLink {            // returned once, at creation; the only value holding the token
        let id: UUID; let area: SharedArea.ID<SharedArea.Area>; let slug: String
        let token: String; let lifetime: ShareLinkLifetime; let createdAt: Date
        var url: URL      // https://arrayapp.dev/s/<slug>#<token>  (what Copy link copies)
        var appURL: URL   // array://s/<slug>#<token>
    }
    struct ShareLinkAccess {      // listAccess rows; never carries the token
        enum Status: String { case active, used, revoked }
        let id: UUID; let area: SharedArea.ID<SharedArea.Area>; let slug: String
        let lifetime: ShareLinkLifetime; let status: Status; let createdAt: Date
        let people: [ShareLinkPerson]
    }
    struct ShareLinkPerson { let person: SharedArea.ID<SharedArea.Person>; let label: String; let admittedAt: Date; let active: Bool }
    enum ShareLinkURL {
        static let webPrefix: String               // "arrayapp.dev/s/", the fixed part of the field
        static func isValidSlug(_: String) -> Bool  // a-z 0-9 and single hyphens, 1-64
        static func suggestedSlug(from title: String) -> String
        static func parse(_ url: URL) -> (slug: String, token: String)?
    }
}
```

Rules the service enforces:
- The slug is unique per relay among live links. A revoked or spent link
  frees its slug.
- The token is 32 random bytes, base64url, and is stored only as a hash.
- Whoever opens a valid link gets the `editor` role. Prompting is part 4.
- "Works once" is spent by the first accept. The person it admitted can open it
  again to get back in; nobody else can.
- "Until revoked" admits any number of people.
- Revoke works on both kinds and removes everyone admitted through the link.
- A person removed from a link cannot rejoin through that link.
- A link dies when its creator loses the owner role or their device is revoked.

## Receipt

31 October 2026.

### What is built

Service (`ContinuumRevivedCollaborationService/CollaborationShareLinks.swift`):
- A new migration `collaboration-share-links-v1` adds two tables, `share_links`
  and `share_link_admissions`.
- A partial unique index keeps slugs unique among live links.
- `CollaborationStoreError.slugTaken` maps to HTTP 409 `slugTaken`.
- `removeMember` now also closes that person's link admissions on the area, so
  a person removed by any route cannot walk back in through an until-revoked
  link.
- Revoke and remove both bump the area epoch, as `removeMember` does.

Routes (`CollaborationRoutes.swift`), all behind the device bearer:
- `POST /collaboration/v1/areas/{area}/links` creates a link.
- `GET /collaboration/v1/areas/{area}/links` lists links and their people.
  Owner only.
- `DELETE /collaboration/v1/areas/{area}/links/{link}` revokes it.
- `DELETE /collaboration/v1/areas/{area}/links/{link}/people/{person}` removes
  one person.
- `POST /collaboration/v1/links/accept` admits through a link.

Client: `CollaborationAPI` has the five calls.

Core:
- `CollaborationAccountTransport` gains the five calls. Default implementations
  refuse with 404, so existing fakes compile unchanged.
- `CollaborationAccountController` gains `createShareLink`, `acceptShareLink`
  (it remembers the area under the slug), `shareLinks`, `revokeShareLink` and
  `removeShareLinkPerson`.
- `ShareLinkOpener` runs the receiving flow: parse, then sign in (a remembered
  account first, else the injected inline sign-in), then admit, then open.

App:
- `Packaging/Info.plist` registers `CFBundleURLTypes` for `array`.
- `AppDelegate.application(_:open:)` routes `array://s/...` and
  `https://arrayapp.dev/s/...` to `shareLinks.open`. Other URLs are ignored.
- `ShareLinkCoordinator` holds the API above.
- Inline sign-in presents the hub's existing Connect, retitled "Sign in to open
  the shared link". It resumes on the hub's new `onConnected` callback, and
  closing the hub cancels.
- A refusal shows as an `NSAlert` sheet on the main window.
- `AppDelegate.collaborationAccountModel()` keeps one account model for the hub
  and share links.
- The hub's open-area callback body moved, unchanged, into
  `openSharedArea(controller:person:area:model:)`, the single open path. Part 2
  replaces what that opens: a window today, the in-canvas zone later.

Website:
- `website/src/pages/s/index.astro`, plus a Vercel rewrite from `/s/:slug` to
  `/s`.
- The page reads the slug from the path and the token from the fragment, opens
  `array://s/<slug>#<token>`, and offers the Mac DMG.
- Unit tests are in `src/lib/share-links.test.ts`.
- Committed locally, not pushed.

### Witnesses

All of them run inside existing legs. No inventory records were added.

`ContinuumRevivedCollaborationChecks`, `runShareLinkChecks`: 21 checks. They use
production account controllers, the production `ShareLinkOpener` and the real
NIO routes over HTTP. They cover:
- single-use is spent after one accept
- the person a single-use link admitted can reopen it
- an until-revoked link admits two people
- revoke cuts both, and only them
- a revoked link refuses newcomers and does not readmit the people it admitted
- a wrong token is refused and shows as refused
- a link without its token is refused as incomplete
- a slug collision is refused across owners
- a spent link's slug is free again
- an editor cannot mint a link
- removing one person blocks only them
- inline sign-in for a first-time receiver, and dismissing it admits nothing
- `listAccess` status and people

`ContinuumRevivedCollaborationServiceChecks`: the boundary audit probes the 4
new area routes. A non-member gets the same answer for a real area as for a
random one, 26 routes in all.

`Array --collaboration-native-check`, new stage "share links", `ShareLinkAppChecks`:
- `shareLinks.createShareLink` from a mounted workspace selection publishes the
  agent as an observation and the note as discussion, with no review window,
  and opens the sender's area.
- A slug collision comes back as `ShareLinkFailure.slugTaken`.
- AppKit `application(_:open:)` with an https link on a signed-out Mac signs in
  inline through the hub's Connect, admits, and opens the area.
- An `array://` link reaches the same entry point.
- A wrong token puts a refusal sheet on the canvas window.
- Unrelated `array://` and `arrayapp.dev` URLs are not routed.

Mutations. Each was applied, rebuilt and run, and each went RED:

| Mutation | Red check |
|---|---|
| Drop the single-use spend | "a single-use link is spent after one accept" |
| Spend until-revoked links too | "an until-revoked link admits two people" |
| Revoke without cutting admissions | "revoke cuts both people…" |
| Accept by slug without the token | "a wrong token is refused…" |
| Skip the slug check | the collision returned 500 `storageFailure` instead of 409, and the run threw |
| URL handler routes nothing | "…signs in inline…, then admits" |
| The coordinator's open does nothing | "the sender's area opens through the same path as the hub" (the same closure the receiver uses) |
| Refusal presenter does nothing | "a wrong token is refused and the refusal is shown on the canvas window" |

Gate run: `scripts/run-matrix.sh --collaboration`, once, under
`.worktrees/.locks/app-build.sh`, with an isolated `TMUX_TMPDIR` and
`CONTINUUM_APP_SUPPORT`, `TMUX`/`TMUX_PANE` unset, and
`CONTINUUM_SKIP_UI_BASELINES=1`. Result: "Collaboration matrix (targeted)
passed", 11 legs. The log shows all 21 `PASS share links:` lines, all 10
`PASS share links (app)` lines, and the boundary audit's 26 routes. The Linux
relay leg (`check-relay-linux.sh`) is green. The one note is the existing
`--ui-probe-check` display skip.

### Open, for the lead

- **A brand-new person cannot onboard from a link alone.** The link carries no
  relay address, and the existing sign-in needs a relay URL plus an enrollment
  code from `provisionPerson`, which is an operator seam with no public route.
  So "sign in inline" works only for someone already enrolled, or someone who
  has been handed a code. Self-serve enrollment from a link is a relay
  decision, not built here.
- **A slug collision leaves an empty area.** `createShareLink` creates the area
  before it mints the link, so a taken slug leaves an empty owned area behind,
  remembered under that slug. A failed publish revokes the link but also keeps
  the area.
- **Prod and Dev both claim `array://`.** LaunchServices picks one installed
  copy. On a Mac with both, a click may open the other one.
- **No universal link.** `https://arrayapp.dev/s/...` reaches the app only
  through the website's hand-off. Associated Domains and an AASA `/s/*` entry
  are the later step; the AASA file today covers only `/pair`.
- **The website page was not opened in a browser.** It was built and its hand-off
  logic unit-tested. The Vercel rewrite is untested locally, because
  `astro preview` does not apply `vercel.json`.
- **The native check is close to its deadline.** `--collaboration-native-check`
  ran in 34-42s against its own 45s limit. The share-link stage takes about 1s;
  the hover-usage stage alone takes about 13s.

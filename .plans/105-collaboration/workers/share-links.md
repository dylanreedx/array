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

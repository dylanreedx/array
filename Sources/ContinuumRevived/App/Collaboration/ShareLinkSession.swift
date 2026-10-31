import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

// Round 2 of .plans/105-collaboration/IN-CANVAS.md: share one agent or a dragged
// area by link, in place. Nothing here waits on the Collaboration window.

/// What one share hands over: the selected tiles, keyed by their owning
/// project as the canvas selected them.
struct ShareTarget: Equatable {
    struct Item: Equatable {
        let key: SharedAreaPublication.SourceKey
        let title: String
        let kind: TileKind
    }
    enum Origin: Equatable { case agent, area }

    let workspaceID: UUID
    let origin: Origin
    let items: [Item]

    var keys: Set<SharedAreaPublication.SourceKey> { Set(items.map(\.key)) }
    var tileIDs: [UUID] { items.map(\.key.tileID) }
    /// One agent's zone is named after the agent; an area's after its slug.
    var name: String {
        if origin == .agent, let agent = items.first { return agent.title }
        return "Shared area"
    }
}

extension Collaboration.ShareLinkLifetime {
    var title: String { self == .once ? "Works once" : "Until revoked" }
    var detail: String { self == .once ? "Spent when someone opens it" : "Works until you revoke it" }
}

/// Part 1 (`ShareLinkCoordinator`, `AppDelegate.shareLinks`): links on an area
/// that already exists. Part 2 has made and published the area by then.
@MainActor
protocol ShareLinkServing: AnyObject {
    func createShareLink(area: UUID, slug: String, lifetime: Collaboration.ShareLinkLifetime) async throws -> Collaboration.ShareLink
    func revokeLink(area: UUID, link: UUID) async throws
    func removeAccess(area: UUID, link: UUID, person: SharedArea.ID<SharedArea.Person>) async throws
    func listAccess(area: UUID) async throws -> [Collaboration.ShareLinkAccess]
}

extension ShareLinkCoordinator: ShareLinkServing {}

/// What part 2's conversion hands back: the zone the tiles now live in, and
/// the area it created, published and bound them to. Part 2 declares the same
/// type (with each tile's object); when it merges this copy must go.
struct SharedZoneShare: Equatable {
    let zoneId: UUID
    let areaId: UUID
}

/// Part 2 (array/mp-canvas-zone): `createSharedZone(fromTiles:name:)` makes the
/// area, publishes and binds the tiles, opens it, and moves the sender's tiles
/// into its zone. `cancelSharedZone` puts them back. Signatures are part 2's
/// own, so `AppDelegate` conforms once it lands.
@MainActor
protocol SharedZoneCreating: AnyObject {
    func createSharedZone(fromTiles tileIds: [UUID], name: String) async throws -> SharedZoneShare
    func cancelSharedZone(areaId: UUID) async
}

/// One share, from the first Copy to Revoke. Nothing is shared until Copy, so
/// a popover opened and dismissed publishes nothing and moves no tile.
@MainActor
final class ShareLinkSession {
    enum Phase: Equatable {
        case draft
        case working
        case live(Collaboration.ShareLink)
        /// A "Works once" link someone has opened.
        case used(Collaboration.ShareLink)
        case revoked(area: UUID)
    }

    let target: ShareTarget
    private let links: ShareLinkServing
    private let zones: SharedZoneCreating
    private let pasteboard: NSPasteboard

    private(set) var phase: Phase = .draft
    private(set) var slug: String
    private(set) var lifetime: Collaboration.ShareLinkLifetime = .once
    private(set) var people: [Collaboration.ShareLinkPerson] = []
    /// The link on the pasteboard is the current one.
    private(set) var copied = false
    private(set) var failure: String?
    var onChange: (() -> Void)?

    init(target: ShareTarget, links: ShareLinkServing, zones: SharedZoneCreating, pasteboard: NSPasteboard) {
        self.target = target; self.links = links; self.zones = zones; self.pasteboard = pasteboard
        slug = ShareLinkURL.suggestedSlug(from: target.origin == .agent ? target.name : target.items.first?.title ?? "shared area")
    }

    var link: Collaboration.ShareLink? {
        switch phase {
        case .live(let link), .used(let link): return link
        default: return nil
        }
    }
    var area: UUID? {
        switch phase {
        case .live(let link), .used(let link): return link.area.rawValue
        case .revoked(let area): return area
        default: return nil
        }
    }
    var isWorking: Bool { phase == .working }

    func setSlug(_ raw: String) {
        let next = ShareLinkURL.suggestedSlug(from: raw)
        guard next != slug else { onChange?(); return }
        slug = next
        copied = false
        onChange?()
    }

    /// Before a link exists this only picks what Copy mints. A live link nobody
    /// has opened is replaced, so the one people hold has the lifetime shown.
    /// Once someone holds access it applies to the next link: replacing the
    /// link would revoke them.
    func setLifetime(_ next: Collaboration.ShareLinkLifetime) async {
        guard next != lifetime, !isWorking else { return }
        lifetime = next
        guard case .live(let current) = phase, people.isEmpty else { copied = false; onChange?(); return }
        await run {
            try await self.links.revokeLink(area: current.area.rawValue, link: current.id)
            self.phase = .live(try await self.links.createShareLink(area: current.area.rawValue, slug: self.slug, lifetime: next))
            self.copied = false
        }
    }

    /// The first Copy shares: part 2 turns the tiles into the shared zone (and
    /// with it the area), then part 1 mints the link. A link that cannot be
    /// minted, say a taken name, puts the tiles back. Later Copies copy the same
    /// link, or a fresh one on the same area when the name or lifetime changed.
    func copy() async {
        guard !isWorking else { return }
        if case .live(let link) = phase, link.slug == slug, link.lifetime == lifetime {
            write(link); return
        }
        await run {
            if case .live(let stale) = self.phase {
                try await self.links.revokeLink(area: stale.area.rawValue, link: stale.id)
                let link = try await self.links.createShareLink(area: stale.area.rawValue, slug: self.slug, lifetime: self.lifetime)
                self.phase = .live(link)
                self.write(link)
                return
            }
            let zone = try await self.zones.createSharedZone(fromTiles: self.target.tileIDs, name: self.zoneName)
            let link: Collaboration.ShareLink
            do {
                link = try await self.links.createShareLink(area: zone.areaId, slug: self.slug, lifetime: self.lifetime)
            } catch {
                await self.zones.cancelSharedZone(areaId: zone.areaId)
                throw error
            }
            self.phase = .live(link)
            self.write(link)
        }
    }

    /// After a "Works once" link is spent, or after Revoke: a fresh link for
    /// the same area.
    func newLink() async {
        let spent: Bool
        switch phase {
        case .used, .revoked: spent = true
        default: spent = false
        }
        guard spent, let area else { return }
        await run {
            self.people = []
            self.phase = .live(try await self.links.createShareLink(area: area, slug: self.slug, lifetime: self.lifetime))
            self.copied = false
        }
    }

    /// Ends the link and everyone's access through it.
    func revoke() async {
        guard let link else { return }
        await run {
            try await self.links.revokeLink(area: link.area.rawValue, link: link.id)
            self.people = []
            self.phase = .revoked(area: link.area.rawValue)
            self.copied = false
        }
    }

    func remove(_ person: Collaboration.ShareLinkPerson) async {
        guard let link else { return }
        await run {
            try await self.links.removeAccess(area: link.area.rawValue, link: link.id, person: person.person)
            self.people.removeAll { $0.person == person.person }
        }
    }

    /// Who the link has admitted. A spent single-use link reads as Used.
    func refreshAccess() async {
        guard let link, !isWorking else { return }
        do {
            guard let row = try await links.listAccess(area: link.area.rawValue).first(where: { $0.id == link.id }) else { return }
            people = row.people.filter(\.active)
            switch row.status {
            case .used: phase = .used(link); copied = false
            case .revoked: phase = .revoked(area: link.area.rawValue); copied = false
            case .active: break
            }
            onChange?()
        } catch {
            failure = "Who has access could not be read. Try again in a moment."
            onChange?()
        }
    }

    private var zoneName: String { target.origin == .agent ? target.name : Self.title(fromSlug: slug) }

    private func write(_ link: Collaboration.ShareLink) {
        pasteboard.clearContents()
        pasteboard.setString(link.url.absoluteString, forType: .string)
        copied = true
        failure = nil
        onChange?()
    }

    private func run(_ body: @escaping () async throws -> Void) async {
        let resume = phase
        phase = .working
        failure = nil
        onChange?()
        do { try await body() }
        catch { failure = Self.message(for: error) }
        // A body that moved no phase (Remove), or one that failed, leaves the
        // popover where it was.
        if phase == .working { phase = resume }
        onChange?()
    }

    static func message(for error: any Error) -> String {
        if let failure = error as? ShareFailure { return failure.message }
        if let described = (error as? LocalizedError)?.errorDescription { return described }
        return "Sharing could not finish. Nothing was copied; try again."
    }

    static func title(fromSlug slug: String) -> String {
        let words = slug.split(separator: "-").map(String.init)
        guard let first = words.first else { return "Shared area" }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }
}

/// Until part 2 lands on this branch, production cannot make a shared zone.
enum ShareFailure: Error, Equatable {
    case zonesUnavailable
    var message: String {
        switch self {
        case .zonesUnavailable: return "Shared zones are not in this build yet. Nothing was shared."
        }
    }
}

/// Production's stand-in for part 2 until it merges: it refuses plainly, so
/// Share never mints a link for tiles that were not shared.
@MainActor
final class PendingSharedZones: SharedZoneCreating {
    func createSharedZone(fromTiles tileIds: [UUID], name: String) async throws -> SharedZoneShare {
        throw ShareFailure.zonesUnavailable
    }
    func cancelSharedZone(areaId: UUID) async {}
}

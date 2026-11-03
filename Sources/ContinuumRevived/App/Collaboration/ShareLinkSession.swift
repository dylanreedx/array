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
        /// Mode B: what the portal does with it ("Live", "Still", "Stays private").
        var badge: String? = nil
    }
    /// A selected tile that this share leaves out, and why: the popover lists
    /// it as "can't be shared yet", so nothing is ever dropped silently.
    struct Excluded: Equatable {
        let tileID: UUID
        let title: String
        let kind: TileKind
        let reason: String
    }
    /// `agent` and `tile` are the header's Share on one tile; `area` is the
    /// Share tool or a multi-tile selection.
    enum Origin: Equatable { case agent, tile, area }

    let workspaceID: UUID
    let origin: Origin
    let items: [Item]
    /// The area these tiles are already lent to, when they are: Share then
    /// opens that area's links and people instead of starting a new share.
    var area: UUID? = nil
    var excluded: [Excluded] = []

    var keys: Set<SharedAreaPublication.SourceKey> { Set(items.map(\.key)) }
    var tileIDs: [UUID] { items.map(\.key.tileID) }
    /// Mode A: one agent is shared on its own, with no zone and nothing moved.
    var isSingleAgent: Bool { items.count == 1 && items.first?.kind == .managedAgent }
    /// One note, file, diff, browser or terminal, shared live on its own.
    var isSingleLiveTile: Bool {
        origin != .area && items.count == 1 && items.first.map { SharedAreaPublication.liveKind(for: $0.kind) != nil } == true
    }
    /// A terminal's output may hold secrets: sharing it needs a second press.
    /// A portal shows a terminal as a card and sends none of it.
    var needsTerminalConfirmation: Bool { origin != .area && items.contains { $0.kind == .terminal } }
    /// One agent's zone is named after the agent; an area's after its slug.
    var name: String {
        if origin != .area, let agent = items.first { return agent.title }
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

/// What part 2's conversion hands back: the area, the zone the tiles now live
/// in, and the shared object each source-bound tile became.
typealias SharedZoneShare = AppDelegate.SharedZoneShare

/// Part 2: `createSharedZone(fromTiles:name:)` makes the area, publishes and
/// binds the tiles, opens it, and moves the sender's tiles into its zone.
/// `cancelSharedZone` puts them back. `AppDelegate` conforms.
@MainActor
protocol SharedZoneCreating: AnyObject {
    func createSharedZone(fromTiles tileIds: [UUID], name: String) async throws -> SharedZoneShare
    func cancelSharedZone(areaId: UUID) async
    /// Mode A (`.plans/105-collaboration/SHARE-REDESIGN.md`): publish one agent
    /// into a new area and host it, with no zone and no tile moved. Returns the area.
    func shareAgent(tile: UUID, name: String) async throws -> UUID
    func cancelAgentShare(area: UUID) async
    /// Explicit revocation also removes the persisted host and visible sharing state.
    func stopSharing(area: UUID) async throws
    /// Mode B (`Portal/SharedPortalHost.swift`): publish the tiles into a new
    /// area where they sit, as one portal, with no zone and no tile moved.
    func sharePortal(tiles: [UUID], name: String) async throws -> UUID
    /// The same, with terminals the person opted in to stream live
    /// (`.plans/114-terminal-sharing`).
    func sharePortal(tiles: [UUID], name: String, liveTerminals: Set<UUID>) async throws -> UUID
    func cancelPortalShare(area: UUID) async
    /// The same for a note, file, diff, browser or terminal
    /// (`.plans/105-collaboration/SHARE-KINDS.md`): one live tile, its own area.
    func shareLiveTile(tile: UUID, name: String) async throws -> UUID
}

extension SharedZoneCreating {
    /// Recorders written before mode B keep the zone path.
    func sharePortal(tiles: [UUID], name: String) async throws -> UUID { try await createSharedZone(fromTiles: tiles, name: name).areaId }
    func cancelPortalShare(area: UUID) async { await cancelSharedZone(areaId: area) }
    func sharePortal(tiles: [UUID], name: String, liveTerminals: Set<UUID>) async throws -> UUID {
        try await sharePortal(tiles: tiles, name: name)
    }
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
        /// Already shared, but this Mac does not hold a link's token (only its
        /// creation returns one): the area's links and people, Revoke and New link.
        case existing(area: UUID)
    }

    let target: ShareTarget
    private let links: ShareLinkServing
    private let zones: SharedZoneCreating
    private let pasteboard: NSPasteboard

    private(set) var phase: Phase = .draft
    /// A revoked link alone does not mean the tile's host was turned off.
    private var sharingStopped = false
    private(set) var slug: String
    private(set) var lifetime: Collaboration.ShareLinkLifetime = .once
    private(set) var people: [Collaboration.ShareLinkPerson] = []
    /// Every link on the area, as the relay last listed them.
    private(set) var accessRows: [Collaboration.ShareLinkAccess] = []
    /// The area's links that still admit someone.
    var liveRows: [Collaboration.ShareLinkAccess] { accessRows.filter { $0.status == .active } }
    /// The link on the pasteboard is the current one.
    private(set) var copied = false
    /// A terminal share's first Copy shows the warning; the second shares.
    private(set) var confirmingTerminal = false
    /// Mode B: the terminals opted in to stream live, each past its own
    /// warning (`.plans/114-terminal-sharing`). Every other terminal is a card.
    private(set) var liveTerminals: Set<UUID> = []
    /// The terminal whose row shows the warning, waiting for its second press.
    private(set) var confirmingLiveTerminal: UUID?
    /// The tiles the first Copy actually published, for the check that every
    /// selected tile was either published or listed as left out.
    private(set) var publishedTileIDs: [UUID] = []
    private(set) var failure: String?
    var onChange: (() -> Void)?

    init(target: ShareTarget, links: ShareLinkServing, zones: SharedZoneCreating, pasteboard: NSPasteboard) {
        self.target = target; self.links = links; self.zones = zones; self.pasteboard = pasteboard
        slug = ShareLinkURL.suggestedSlug(from: target.origin != .area ? target.name : target.items.first?.title ?? "shared area")
        if let area = target.area { phase = .existing(area: area) }
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
        case .existing(let area): return area
        case .revoked(let area): return sharingStopped ? nil : area
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
            do {
                self.phase = .live(try await self.links.createShareLink(area: current.area.rawValue, slug: self.slug, lifetime: next))
            } catch {
                self.phase = .revoked(area: current.area.rawValue)
                throw error
            }
            self.copied = false
        }
    }

    /// The first Copy shares: part 2 turns the tiles into the shared zone (and
    /// with it the area), then part 1 mints the link. A link that cannot be
    /// minted, say a taken name, puts the tiles back. Later Copies copy the same
    /// link, or a fresh one on the same area when the name or lifetime changed.
    /// A terminal row's button, before Copy: the first press shows the
    /// secrets warning, the second opts the terminal in to stream live, and a
    /// press on a live one makes it a private card again.
    /// Before Copy only: what a dismissed popover opted in is forgotten.
    func forgetTerminalOptIns() {
        guard phase == .draft else { return }
        liveTerminals = []; confirmingLiveTerminal = nil
    }

    func toggleLiveTerminal(_ tile: UUID) {
        guard phase == .draft, target.origin == .area, target.items.contains(where: { $0.key.tileID == tile && $0.kind == .terminal }) else { return }
        if liveTerminals.contains(tile) { liveTerminals.remove(tile) }
        else if confirmingLiveTerminal == tile { liveTerminals.insert(tile); confirmingLiveTerminal = nil }
        else { confirmingLiveTerminal = tile }
        onChange?()
    }

    func copy() async {
        guard !isWorking else { return }
        if case .live(let link) = phase, link.slug == slug, link.lifetime == lifetime {
            write(link); return
        }
        if target.needsTerminalConfirmation, phase == .draft, !confirmingTerminal {
            // Nothing is published: the popover now says what a terminal can
            // show, and the same button shares on its second press.
            confirmingTerminal = true
            onChange?()
            return
        }
        let previous = phase
        await run {
            if case .live(let stale) = previous {
                try await self.links.revokeLink(area: stale.area.rawValue, link: stale.id)
                let link: Collaboration.ShareLink
                do {
                    link = try await self.links.createShareLink(area: stale.area.rawValue, slug: self.slug, lifetime: self.lifetime)
                } catch {
                    self.phase = .revoked(area: stale.area.rawValue)
                    throw error
                }
                self.phase = .live(link)
                self.write(link)
                return
            }
            let link: Collaboration.ShareLink
            if self.target.isSingleLiveTile, let tile = self.target.tileIDs.first {
                // One note, file, diff, browser or terminal: the same as one
                // agent. Nothing moves, no zone is made.
                let area = try await self.zones.shareLiveTile(tile: tile, name: self.zoneName)
                do {
                    link = try await self.links.createShareLink(area: area, slug: self.slug, lifetime: self.lifetime)
                } catch {
                    await self.zones.cancelAgentShare(area: area)
                    throw error
                }
                self.publishedTileIDs = [tile]
            } else if self.target.isSingleAgent, let tile = self.target.tileIDs.first {
                // One agent: nothing on this canvas moves and no zone is made.
                let area = try await self.zones.shareAgent(tile: tile, name: self.zoneName)
                do {
                    link = try await self.links.createShareLink(area: area, slug: self.slug, lifetime: self.lifetime)
                } catch {
                    await self.zones.cancelAgentShare(area: area)
                    throw error
                }
                self.publishedTileIDs = [tile]
            } else {
                // Mode B: one portal. Nothing on this canvas moves, no zone is made.
                let area = try await self.zones.sharePortal(tiles: self.target.tileIDs, name: self.zoneName,
                                                            liveTerminals: self.liveTerminals.intersection(self.target.tileIDs))
                do {
                    link = try await self.links.createShareLink(area: area, slug: self.slug, lifetime: self.lifetime)
                } catch {
                    await self.zones.cancelPortalShare(area: area)
                    throw error
                }
                // Every listed tile goes in; a terminal as a card that carries nothing.
                self.publishedTileIDs = self.target.tileIDs
            }
            self.sharingStopped = false
            self.phase = .live(link)
            self.write(link)
        }
    }

    /// A spent link gets a replacement on the same hosted area. Explicit
    /// revocation ended the host, so sharing again creates a fresh area.
    func newLink() async {
        if case .revoked = phase, sharingStopped {
            // The old area no longer has a host. Share anew before minting a link.
            phase = .draft
            await copy()
            return
        }
        let spent: Bool
        switch phase {
        case .used, .revoked, .existing: spent = true
        default: spent = false
        }
        guard spent, let area else { return }
        await run {
            self.people = []
            self.phase = .live(try await self.links.createShareLink(area: area, slug: self.slug, lifetime: self.lifetime))
            self.copied = false
        }
    }

    /// Ends the link in hand and every other link on the area that still
    /// admits or holds someone, and everyone's access through them.
    func revoke() async {
        guard let area else { return }
        let currentLink = link
        await run {
            // Read the relay now: another popover may have minted a link since
            // our last poll. A read/revoke failure must not claim sharing is off.
            let rows = try await self.links.listAccess(area: area)
            var ids = rows.filter { $0.status != .revoked }.map(\.id)
            if let link = currentLink, !ids.contains(link.id) { ids.append(link.id) }
            for id in ids { try await self.links.revokeLink(area: area, link: id) }
            try await self.zones.stopSharing(area: area)
            self.people = []
            self.accessRows = []
            self.publishedTileIDs = []
            self.sharingStopped = true
            self.phase = .revoked(area: area)
            self.copied = false
        }
    }

    func remove(_ person: Collaboration.ShareLinkPerson) async {
        guard let area, let link = link?.id ?? accessRows.first(where: { $0.people.contains { $0.person == person.person } })?.id else { return }
        await run {
            try await self.links.removeAccess(area: area, link: link, person: person.person)
            self.people.removeAll { $0.person == person.person }
        }
    }

    /// Who the area's links have admitted, as the relay lists them now. A
    /// spent single-use link reads as Used. The open popover calls this on a
    /// short interval, so a join shows without reopening it.
    func refreshAccess() async {
        guard let area, !isWorking else { return }
        do {
            let rows = try await links.listAccess(area: area)
            guard !isWorking, self.area == area else { return }
            accessRows = rows
            var seen = Set<SharedArea.ID<SharedArea.Person>>()
            people = rows.filter { $0.status != .revoked }.flatMap(\.people)
                .filter { $0.active && seen.insert($0.person).inserted }
            if let link, let row = rows.first(where: { $0.id == link.id }) {
                switch row.status {
                case .used: phase = .used(link); copied = false
                case .revoked: phase = .revoked(area: area); copied = false
                case .active: break
                }
            }
            onChange?()
        } catch {
            failure = "Who has access could not be read. Try again in a moment."
            onChange?()
        }
    }

    private var zoneName: String { target.origin != .area ? target.name : Self.title(fromSlug: slug) }

    private func write(_ link: Collaboration.ShareLink) {
        pasteboard.clearContents()
        copied = pasteboard.setString(link.url.absoluteString, forType: .string)
        failure = copied ? nil : "The link could not be copied. Try again."
        onChange?()
    }

    private func run(_ body: @escaping () async throws -> Void) async {
        let resume = phase
        phase = .working
        copied = false
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
        if let described = (error as? LocalizedError)?.errorDescription { return described }
        return "Sharing could not finish. Nothing was copied; try again."
    }

    static func title(fromSlug slug: String) -> String {
        let words = slug.split(separator: "-").map(String.init)
        guard let first = words.first else { return "Shared area" }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }
}

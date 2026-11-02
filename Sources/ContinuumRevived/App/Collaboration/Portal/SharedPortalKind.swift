import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

// The protocol a shared tile kind implements to appear in a portal
// (`.plans/105-collaboration/PORTAL-CONTRACT.md`). The portal owns the area,
// admission, geometry, the manifest, liveness, revoke, cursors and the
// guest's camera. A kind owns only its content: what the host publishes for
// one of its tiles, and how the guest draws it.

/// What one shared tile is doing, as the guest's portal sees it. The portal
/// works this out once and hands it to every item; a kind only draws it.
enum SharedPortalItemState: Equatable {
    case live
    /// The host's Mac is offline: show the last content, dimmed.
    case offline(lastSeen: Date?)
    /// Sharing stopped (revoked, removed, or the tile left the share). Nothing
    /// new arrives; what already arrived stays until the portal is closed.
    case stopped(String)
}

/// How a tile of this kind appears in the host's share popover before Copy.
struct SharedPortalShareRow: Equatable {
    /// False keeps the tile off the relay entirely (no item, no position).
    let included: Bool
    /// Short badge beside the title: "Live", "Still", "Stays private".
    let badge: String
}

/// A guest action shown when the pointer is over an item ("Open beside").
struct SharedPortalHoverAction {
    let title: String
    let symbolName: String
    let perform: @MainActor () -> Void
}

/// Stops a host-side observation. The portal calls `cancel` when the share
/// stops, the tile closes, or the app quits.
@MainActor
protocol SharedPortalObservation: AnyObject {
    func cancel()
}

/// A closure-backed observation, for kinds that only hold a notification token.
@MainActor
final class SharedPortalBlockObservation: SharedPortalObservation {
    private var onCancel: (() -> Void)?
    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    func cancel() { onCancel?(); onCancel = nil }
}

/// Host-side services, one per portal this Mac shares.
@MainActor
final class SharedPortalHostContext {
    weak var app: AppDelegate?
    /// The shared area (the portal).
    let area: UUID
    init(app: AppDelegate?, area: UUID) { self.app = app; self.area = area }

    /// The tile's current record, with its WORLD frame.
    func tile(_ id: UUID) -> Tile? {
        guard let canvas = app?.canvasView, var tile = canvas.tileRecord(for: id) else { return nil }
        tile.frame = canvas.worldFrame(forTileFrame: tile.frame, tileId: id)
        return tile
    }
    /// The tile's live view, when it is hydrated.
    func tileView(_ id: UUID) -> TileNSView? { app?.canvasView?.tileView(for: id) }
    /// The project root that owns the tile, for kinds that read files.
    func projectRoot(forTile id: UUID) -> URL? {
        guard let app, let canvas = app.canvasView, let tile = tile(id), let zone = tile.zoneId,
              let project = canvas.projectId(forZone: zone) else { return nil }
        return app.sharedAreaRuntime?.controller(for: project)?.projectRoot
    }
}

/// Guest-side services, one per portal tile.
@MainActor
final class SharedPortalGuestContext {
    let controller: SharedAreaController
    private(set) var hostName: String
    private(set) var hostColour: NSColor
    /// "Open beside": lifts an agent out as a mode A tile beside the portal.
    var openBeside: (SharedArea.ID<SharedArea.Object>) -> Void = { _ in }

    init(controller: SharedAreaController, hostName: String, hostColour: NSColor) {
        self.controller = controller; self.hostName = hostName; self.hostColour = hostColour
    }
    func update(hostName: String, hostColour: NSColor) { self.hostName = hostName; self.hostColour = hostColour }

    /// Approve or request changes on a diff revision. Runs on the relay's
    /// existing review route; the host is never asked to run anything.
    func review(object: SharedArea.ID<SharedArea.Object>, revision: SharedArea.ID<Collaboration.Artifact.RevisionTag>,
                verdict: Collaboration.Artifact.Verdict, note: String = "") async throws -> Collaboration.Artifact.Review {
        guard let transport = controller.artifactTransport, let epoch = controller.scope?.epoch else {
            throw SharedPortalError.notConnected
        }
        return try await transport.reviewArtifact(object: object.rawValue,
            request: .init(epoch: epoch, revision: revision, verdict: verdict, note: note))
    }
}

enum SharedPortalError: Error, Equatable { case notConnected, nothingToShare, notHosted, alreadyShared }

/// One guest-side item. The portal sizes it in HOST points: `bounds.size` is
/// the host tile's size, and `frame` is that rect at the portal's zoom, so
/// AppKit scales the drawing. Never assume `bounds == frame`.
@MainActor
class SharedPortalItemView: NSView {
    let entry: SharedPortal.Entry
    weak var guest: SharedPortalGuestContext?
    private(set) var itemState: SharedPortalItemState = .live
    override var isFlipped: Bool { true }

    init(entry: SharedPortal.Entry, guest: SharedPortalGuestContext) {
        self.entry = entry; self.guest = guest
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The item's latest content revision, read and verified by the portal.
    /// Called when the head changes, never per frame. Nil until the first
    /// revision arrives, and always nil for a kind that publishes none.
    func apply(contents: CollaborationArtifactContents?) {}

    /// Live, offline or stopped. The base class dims offline and stopped.
    func apply(state: SharedPortalItemState) {
        itemState = state
        let dim: Bool
        switch state { case .live: dim = false; case .offline, .stopped: dim = true }
        alphaValue = dim ? 0.55 : 1
    }

    /// Actions offered while the pointer is over this item.
    var hoverActions: [SharedPortalHoverAction] { [] }

    /// What a witness reads: plain facts about what is on screen ("mode":
    /// "still", "text": the note's text, "editable": "false"). Keys are the
    /// kind's own; the portal adds "kind" and "title".
    var qaFacts: [String: String] { [:] }
}

/// The contract. One value per item kind, listed in `SharedPortalKinds`.
@MainActor
protocol SharedPortalKind {
    var itemKind: SharedPortal.ItemKind { get }

    // MARK: Host

    /// The popover row for a tile of this kind.
    func shareRow(for tile: Tile) -> SharedPortalShareRow
    /// The title the guest sees. Kinds whose titles could leak (terminals)
    /// return a generic one.
    func publishedTitle(for tile: Tile) -> String
    /// The content at share time, or nil for a kind that sends none. Runs on
    /// the main actor; do slow reads off it and await them.
    func snapshot(tile: Tile, host: SharedPortalHostContext) async throws -> SharedArtifactProducer.Draft?
    /// Watches the tile and calls `publish` with new content when it changes.
    /// Call it as often as you like: the portal drops drafts equal to the last
    /// one it sent, keeps only the newest while a send is out, and sends at
    /// most one per object every `SharedPortalHost.minimumInterval`.
    func observe(tile: UUID, host: SharedPortalHostContext,
                 publish: @escaping @MainActor (SharedArtifactProducer.Draft) -> Void) -> (any SharedPortalObservation)?

    // MARK: Guest

    func makeView(entry: SharedPortal.Entry, guest: SharedPortalGuestContext) -> SharedPortalItemView
}

extension SharedPortalKind {
    func shareRow(for tile: Tile) -> SharedPortalShareRow { .init(included: true, badge: "Live") }
    func publishedTitle(for tile: Tile) -> String { tile.title }
}

/// The host side's publishing rules, shared by every kind.
enum SharedPortalHost {
    /// At most one content revision per item this often; the newest always
    /// goes in the end.
    static let minimumInterval: Duration = .milliseconds(500)
    /// Moves are sent at most this often while a tile is dragged.
    static let placeInterval: Duration = .milliseconds(250)
}

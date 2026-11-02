import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// A terminal in a portal (`.plans/114-terminal-sharing`, `PORTAL-CONTRACT.md`).
///
/// Private by default: a card that says it stays on the host's Mac, and
/// nothing of it on the relay. Opted in, one terminal at a time and past the
/// secrets warning (the share popover's row, or "Add to share" pressed twice),
/// it joins the portal's area as a `.liveTile` item instead of an artifact:
/// the same item, stream lane and renderer as a terminal shared on its own.
/// The host's portal session hosts it with `TerminalLiveSource`; the guest's
/// item draws it with `LiveTileBodyView`, read only.
@MainActor
struct SharedPortalTerminalKind: SharedPortalKind {
    let itemKind: SharedPortal.ItemKind = .terminal

    func shareRow(for tile: Tile) -> SharedPortalShareRow { .init(included: true, badge: "Stays private") }
    func publishedTitle(for tile: Tile) -> String { "Terminal" }
    /// Neither the card nor the live terminal publishes artifact content: the
    /// live one has its own lane.
    func snapshot(tile: Tile, host: SharedPortalHostContext) async throws -> SharedArtifactProducer.Draft? { nil }
    func observe(tile: UUID, host: SharedPortalHostContext,
                 publish: @escaping @MainActor (SharedArtifactProducer.Draft) -> Void) -> (any SharedPortalObservation)? { nil }

    func makeView(entry: SharedPortal.Entry, guest: SharedPortalGuestContext) -> SharedPortalItemView {
        let live = guest.controller.document?.items.contains { $0.id == entry.object && $0.kind == .liveTile } == true
        return live ? SharedPortalTerminalItemView(entry: entry, guest: guest)
                    : SharedPortalCardView(entry: entry, guest: guest, message: "Terminal stays on \(guest.hostName)'s Mac")
    }
}

/// An opted-in terminal: the host's terminal, live, in its place in the portal.
@MainActor
final class SharedPortalTerminalItemView: SharedPortalItemView {
    let body: LiveTileBodyView

    override init(entry: SharedPortal.Entry, guest: SharedPortalGuestContext) {
        body = LiveTileBodyView(kind: .terminal, hostName: guest.hostName)
        super.init(entry: entry, guest: guest)
        body.inPortal = true
        body.inputEnabled = false
        addSubview(body)
        if guest.controller.status == .connected { body.attach(controller: guest.controller, object: entry.object) }
        setAccessibilityLabel(SharedTerminalTitle.title(hostName: guest.hostName, hostTitle: ""))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        body.frame = bounds
    }

    override func apply(state: SharedPortalItemState) {
        super.apply(state: state)
        switch state {
        case .live:
            if !body.isReading, let guest, guest.controller.status == .connected { body.attach(controller: guest.controller, object: entry.object) }
        case .offline: break
        case .stopped: body.stop()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { body.stop() }
        else if case .live = itemState, let guest, guest.controller.status == .connected { body.attach(controller: guest.controller, object: entry.object) }
    }

    override var qaFacts: [String: String] {
        var facts: [String: String] = ["mode": "live", "title": SharedTerminalTitle.title(hostName: guest?.hostName ?? "", hostTitle: "")]
        if let mirror = body.qaTerminalMirror {
            facts["text"] = mirror.qaScreenRows
            facts["grid"] = mirror.qaGrid.map { "\($0.columns)x\($0.rows)" } ?? ""
            facts["hostGrid"] = "\(mirror.columns)x\(mirror.rows)"
            facts["lane"] = mirror.laneState
        } else {
            facts["text"] = body.qaText
        }
        return facts
    }
}

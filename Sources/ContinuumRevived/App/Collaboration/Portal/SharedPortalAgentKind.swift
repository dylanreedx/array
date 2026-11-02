import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

/// The reference kind: an agent. Unlike every other kind it is not an
/// artifact. The host publishes it as an `agentObservation`, exactly as mode A
/// does, so its projection, prompts, names and receipts are mode A's. The
/// guest watches it in the portal; "Open beside" lifts it out as a mode A tile,
/// which is where prompting happens. Nothing is typed at portal scale.
@MainActor
struct SharedPortalAgentKind: SharedPortalKind {
    var itemKind: SharedPortal.ItemKind { .agent }

    func shareRow(for tile: Tile) -> SharedPortalShareRow { .init(included: true, badge: "Live") }
    /// Agents need no artifact: the portal admits them through the agent
    /// publication path, and the host session streams their projection.
    func snapshot(tile: Tile, host: SharedPortalHostContext) async throws -> SharedArtifactProducer.Draft? { nil }
    func observe(tile: UUID, host: SharedPortalHostContext,
                 publish: @escaping @MainActor (SharedArtifactProducer.Draft) -> Void) -> (any SharedPortalObservation)? { nil }
    func makeView(entry: SharedPortal.Entry, guest: SharedPortalGuestContext) -> SharedPortalItemView {
        SharedPortalAgentItemView(entry: entry, guest: guest)
    }
}

/// An agent inside a portal: the owner's live projection, read-only, under a
/// title bar. Hovering offers "Open beside".
@MainActor
final class SharedPortalAgentItemView: SharedPortalItemView {
    let live: SharedAgentLiveView
    private let title = NSTextField(labelWithString: "")

    convenience override init(entry: SharedPortal.Entry, guest: SharedPortalGuestContext) {
        self.init(entry: entry, guest: guest, read: nil)
    }
    /// `read` stands in for the relay in the render check only.
    init(entry: SharedPortal.Entry, guest: SharedPortalGuestContext, read: SharedAgentLiveView.Reader?) {
        live = SharedAgentLiveView(controller: guest.controller, read: read)
        super.init(entry: entry, guest: guest)
        title.font = .token(.label); title.lineBreakMode = .byTruncatingTail
        title.stringValue = entry.title
        addSubview(title); addSubview(live)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("\(entry.title), \(guest.hostName)'s agent")
        applyAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The document changed: keep reading this agent while it is shared.
    func show(in document: SharedArea.Document?) {
        guard case .live = itemState else { return }
        if live.object != entry.object || !live.isPolling { live.show(object: entry.object, in: document) }
    }
    override func apply(state: SharedPortalItemState) {
        super.apply(state: state)
        switch state {
        case .live: live.ended = nil; live.hostOnline = true
        case .offline: live.hostOnline = false
        case .stopped(let text): live.ended = text; live.stop()
        }
    }
    func stop() { live.stop() }

    override var hoverActions: [SharedPortalHoverAction] {
        guard case .stopped = itemState else {
            return [.init(title: "Open beside", symbolName: "rectangle.portrait.and.arrow.right") { [weak self] in
                guard let self else { return }
                self.guest?.openBeside(self.entry.object)
            }]
        }
        return []
    }
    override var qaFacts: [String: String] {
        ["transcript": live.transcriptText, "status": live.statusText, "editable": String(live.offersComposer)]
    }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 14, y: 10, width: max(0, bounds.width - 28), height: 18)
        let body = NSRect(x: 12, y: 36, width: max(0, bounds.width - 24), height: max(0, bounds.height - 46))
        if live.frame != body { live.frame = body }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyAppearance() }
    private func applyAppearance() {
        title.textColor = TextToken.textPrimary.color.nsColor(in: self)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        SurfaceToken.tileBody.color.nsColor(in: self).setFill(); card.fill()
        LineToken.borderStrong.color.nsColor(in: self).setStroke(); card.lineWidth = 1; card.stroke()
        LineToken.separator.color.nsColor(in: self).setFill()
        NSRect(x: 0, y: 32, width: bounds.width, height: 1).fill()
    }
}

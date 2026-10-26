import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// An agent tile's header drag, watching for a reference drop. The move itself
/// is the ordinary live move — auto-layout, magnet, swap, slide in between.
/// Only while the pointer is over another agent's composer or the middle of its
/// body (`agentReferenceDropRegions`) does the drag read as a reference: the
/// dragged tile goes back to rest, that agent's composer lights, and a card
/// rides the pointer. ⌥ keeps it a move.
///
/// Regions are measured where each agent rested when the drag began, so a swap
/// or push preview can never pull the recipient out from under the pointer.
@MainActor
final class AgentReferenceDrag {
    private struct Candidate {
        weak var view: ManagedAgentTileNSView?
        /// World rectangles, at rest.
        let regions: [CGRect]
    }

    let reference: AgentPromptReference
    /// The dragged tile's world frame at rest, where it waits while referencing.
    let restFrame: TileFrame
    private weak var source: ManagedAgentTileNSView?
    /// Topmost first.
    private let candidates: [Candidate]
    private(set) weak var recipient: ManagedAgentTileNSView?
    private var card: AgentReferenceDragCard?

    init?(source: ManagedAgentTileNSView) {
        guard let canvas = source.canvas, let reference = source.agentReferenceForDragging else { return nil }
        candidates = canvas.tileViewsInVisualOrder.reversed().compactMap { view in
            guard let target = view as? ManagedAgentTileNSView, target !== source,
                  target.acceptsAgentReference(reference) else { return nil }
            let rest = canvas.worldFrame(forTileFrame: target.tile.frame, tileId: target.tile.id)
            let regions = target.agentReferenceDropRegions.map { $0.offsetBy(dx: rest.x, dy: rest.y) }
            return regions.isEmpty ? nil : Candidate(view: target, regions: regions)
        }
        guard !candidates.isEmpty else { return nil }
        self.reference = reference
        self.source = source
        restFrame = canvas.worldFrame(forTileFrame: source.tile.frame, tileId: source.tile.id)
    }

    /// The agent a release at `worldPoint` would reference, if any.
    func recipient(atWorld worldPoint: CGPoint, event: NSEvent) -> ManagedAgentTileNSView? {
        guard !event.modifierFlags.contains(.option), let source, !source.hasRetiredFromScene else { return nil }
        guard let view = candidates.first(where: { $0.regions.contains { $0.contains(worldPoint) } })?.view,
              view.window === source.window, !view.hasRetiredFromScene,
              view.acceptsAgentReference(reference) else { return nil }
        return view
    }

    func setRecipient(_ next: ManagedAgentTileNSView?) {
        guard next !== recipient else { return }
        recipient?.setAgentReferenceDropHighlight(false)
        recipient = next
        next?.setAgentReferenceDropHighlight(true)
        if next == nil { card?.isHidden = true }
    }

    /// The card beside the pointer, topmost on the canvas.
    func showCard(atWindowPoint windowPoint: NSPoint, in canvas: NSView) {
        let card = self.card ?? AgentReferenceDragCard(name: reference.displayName, tint: source?.identityColor)
        self.card = card
        if card.superview !== canvas || canvas.subviews.last !== card {
            canvas.addSubview(card, positioned: .above, relativeTo: nil)
        }
        let point = canvas.convert(windowPoint, from: nil)
        card.setFrameOrigin(NSPoint(x: point.x + 14, y: canvas.isFlipped ? point.y + 14 : point.y - 14 - card.frame.height))
        card.isHidden = false
    }

    func end() {
        setRecipient(nil)
        card?.removeFromSuperview()
        card = nil
    }
}

/// What rides the pointer while an agent header drag is over a reference
/// target: the "@" the composer's reference chips wear, in the dragged agent's
/// identity colour when it has one, then "Reference" and the agent's name.
/// Screen-sized at every zoom; never takes a click.
@MainActor
final class AgentReferenceDragCard: NSView {
    static let height: CGFloat = 30
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let name: String
    private let tint: NSColor?

    init(name: String, tint: NSColor?) {
        self.name = name
        self.tint = tint
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        icon.image = CanvasSymbolImage.image(named: "at.circle.fill", pointSize: 17, weight: .semibold)
        icon.imageScaling = .scaleNone
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(icon)
        addSubview(label)
        setAccessibilityElement(false)
        applyColors()
        let side: CGFloat = 20
        let text = label.fittingSize
        let textWidth = min(260, ceil(text.width))
        frame.size = NSSize(width: 6 + side + 5 + textWidth + 12, height: Self.height)
        icon.frame = NSRect(x: 6, y: (Self.height - side) / 2, width: side, height: side)
        label.frame = NSRect(x: 6 + side + 5, y: (Self.height - text.height) / 2, width: textWidth, height: ceil(text.height))
        layer?.cornerRadius = min(Self.height / 2, CornerRole.pill.cgRadius())
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        layer?.backgroundColor = SurfaceToken.overlay.color.cgColor(in: self)
        layer?.borderColor = AgentLineRole.focusRing.color.cgColor(in: self)
        layer?.shadowColor = NSColor.shadowColor.cgColor
        icon.contentTintColor = tint ?? AgentLineRole.focusRing.color.nsColor(in: self)
        let text = NSMutableAttributedString(string: "Reference ", attributes: [
            .font: NSFont.systemFont(ofSize: 12.5),
            .foregroundColor: TextToken.textSecondary.color.nsColor(in: self)])
        text.append(NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: TextToken.textPrimary.color.nsColor(in: self)]))
        label.attributedStringValue = text
    }

    var qaText: String { label.stringValue }
}

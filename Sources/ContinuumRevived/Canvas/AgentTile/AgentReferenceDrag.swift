import AppKit
import ContinuumRevivedCore

/// An agent tile's header drag, watching for a reference drop. The move itself
/// is the ordinary live move — auto-layout, magnet, swap, slide in between.
/// Only while the pointer is over another agent's composer or the middle of its
/// body (`agentReferenceDropRegions`) does the drag read as a reference: the
/// dragged tile goes back to rest, that agent's composer lights, and a label
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
    }

    func end() { setRecipient(nil) }
}

import AppKit
import ContinuumRevivedCore

/// One ordinary agent-header drag, before its destination is known. Geometry
/// stays at the gesture baseline so the layout solver cannot move a recipient
/// out from under the pointer. A composer drop is a reference; any other drop
/// hands the accumulated pointer delta to the existing move/swap implementation.
@MainActor
final class AgentTileReferenceMove {
    private struct Candidate {
        weak var view: ManagedAgentTileNSView?
        let tileFrame: NSRect
    }

    private static weak var tracking: AgentTileReferenceMove?
    private weak var source: ManagedAgentTileNSView?
    private weak var canvas: CanvasNSView?
    private weak var highlighted: ManagedAgentTileNSView?
    private let candidates: [Candidate]
    private let initialFrame: TileFrame
    let reference: AgentPromptReference
    let start: NSPoint
    private(set) var moved = false

    init?(source: ManagedAgentTileNSView, event: NSEvent) {
        guard let canvas = source.canvas,
              !event.modifierFlags.contains(.option),
              let reference = source.agentReferenceForDragging else { return nil }
        let candidates = canvas.tileViewsInVisualOrder.reversed().compactMap { view -> Candidate? in
            guard let target = view as? ManagedAgentTileNSView, target !== source,
                  target.acceptsAgentReference(reference),
                  target.agentReferenceComposerFrameInWindow != nil else { return nil }
            return Candidate(view: target, tileFrame: target.convert(target.bounds, to: nil))
        }
        guard !candidates.isEmpty else { return nil }
        self.source = source
        self.canvas = canvas
        self.reference = reference
        self.candidates = candidates
        initialFrame = canvas.worldFrame(forTileFrame: source.tile.frame, tileId: source.tile.id)
        start = event.locationInWindow
        Self.tracking = self
    }

    static func isTracking(in window: NSWindow?) -> Bool {
        tracking != nil && tracking?.source?.window === window
    }

    func recipient(at event: NSEvent) -> ManagedAgentTileNSView? {
        guard moved, !event.modifierFlags.contains(.option), let source, let canvas,
              source.canvas === canvas, !source.hasRetiredFromScene,
              source.agentReferenceForDragging?.agentID == reference.agentID else { return nil }
        let point = canvas.convert(event.locationInWindow, from: nil)
        guard canvas.bounds.contains(point), let topTileID = canvas.tileId(at: point) else { return nil }
        return candidates.first { candidate in
            guard let view = candidate.view, view.canvas === canvas,
                  view.tile.id == topTileID,
                  !view.hasRetiredFromScene, view.window === source.window,
                  view.acceptsAgentReference(reference),
                  let frame = view.agentReferenceComposerFrameInWindow else { return false }
            // A changed scene invalidates the old drop region rather than
            // referencing an agent that moved into it during the gesture.
            return view.convert(view.bounds, to: nil) == candidate.tileFrame && frame.contains(event.locationInWindow)
        }?.view
    }

    func update(with event: NSEvent) {
        guard let canvas else { return }
        let dx = event.locationInWindow.x - start.x
        let dy = start.y - event.locationInWindow.y
        if !moved, hypot(dx, dy) < 3 { return }
        if !moved { canvas.window?.makeFirstResponder(canvas) }
        moved = true
        let recipient = recipient(at: event)
        if highlighted !== recipient {
            highlighted?.setAgentReferenceDropHighlight(false)
            highlighted = recipient
            recipient?.setAgentReferenceDropHighlight(true)
        }
        var preview = initialFrame
        preview.x += dx / canvas.viewport.zoom
        preview.y += dy / canvas.viewport.zoom
        canvas.showDragGhost(at: preview,
            label: recipient == nil ? reference.displayName : "Reference \(reference.displayName)",
            detail: recipient == nil ? "Drop on a composer to reference · elsewhere to move" : "Release to add to draft",
            opaqueLabel: true)
    }

    func cancel() {
        highlighted?.setAgentReferenceDropHighlight(false)
        highlighted = nil
        canvas?.hideDragGhost()
        if Self.tracking === self { Self.tracking = nil }
    }
}

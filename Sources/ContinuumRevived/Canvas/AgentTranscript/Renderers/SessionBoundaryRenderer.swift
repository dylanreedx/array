import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// `.plans/79-session-handoff`: "In Terminal · 2 turns" — the turns below were
/// taken outside this tile (`mocks/2-one-tile-two-faces.png`, bottom right). A
/// thin rule either side of a centred glyph and label: the compaction
/// boundary's structure, so it reuses that view rather than a second one.
@MainActor
final class SessionBoundaryRenderer: AgentBlockRendering {
    let kind: AgentBlockKind = .sessionBoundary

    func makeView() -> NSView {
        let view = CompactionBoundaryView(frame: .zero)
        view.identifier = NSUserInterfaceItemIdentifier("agent.sessionBoundary")
        return view
    }

    func update(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? CompactionBoundaryView,
              case .sessionBoundary(let payload) = block.payload else { return }
        view.apply(text: payload.text, phase: nil, context: context, symbolName: payload.symbolName)
    }

    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat {
        CGFloat(context.pageZoom.scaled(28))
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard case .sessionBoundary(let payload) = block.payload else { return }
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.staticText)
        view.setAccessibilityLabel(payload.text)
    }
}

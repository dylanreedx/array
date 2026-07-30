import AppKit
import ContinuumRevivedAgentContent

@MainActor
final class QuestionRenderer: AgentBlockRendering {
    let kind: AgentBlockKind = .question

    func makeView() -> NSView { AgentRequestView(mode: .question) }

    func update(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AgentRequestView, case let .question(payload) = block.payload else { return }
        view.apply(blockID: block.id, payload: payload, context: context)
    }

    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat {
        guard case let .question(payload) = block.payload else { return 0 }
        return AgentRequestView.measuredHeight(payload: payload, width: width)
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AgentRequestView, case let .question(payload) = block.payload else { return }
        view.applyAccessibility(payload: payload)
    }
}

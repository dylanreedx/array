import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import Foundation

/// Pure presentation for a completed reasoning entry. It consumes only the
/// provider-neutral semantic entry, an optional caller-attested duration, and a
/// disclosure-state seam keyed by the entry identity. It never parses provider
/// strings, invents a reasoning summary, or reads runtime/provider state.
struct CompletedReasoningDisclosurePresentation: Equatable {
    let entryID: AgentNodeID
    let bodyBlocks: [AgentBlock]
    let title: String
    let accessibilityLabel: String
    let accessibilityValue: String
    let isExpanded: Bool

    var hasBody: Bool { !bodyBlocks.isEmpty }
}

enum CompletedReasoningDisclosurePresenter {
    static let collapsedDefaultExpanded = false
    static let baseTitle = "Thought"

    static func presentation(
        for entry: AgentEntry?,
        authoritativeDuration: TimeInterval?,
        actions: AgentRenderActions
    ) -> CompletedReasoningDisclosurePresentation? {
        guard let entry,
              entry.role == .reasoning,
              entry.lifecycle == .finished,
              !entry.blocks.isEmpty
        else { return nil }
        let expanded = actions.isExpanded(blockID: entry.id, default: collapsedDefaultExpanded)
        let title = title(authoritativeDuration: authoritativeDuration)
        return CompletedReasoningDisclosurePresentation(
            entryID: entry.id,
            bodyBlocks: entry.blocks,
            title: title,
            accessibilityLabel: title,
            accessibilityValue: expanded ? "Expanded" : "Collapsed",
            isExpanded: expanded
        )
    }

    static func title(authoritativeDuration: TimeInterval?) -> String {
        guard let authoritativeDuration,
              authoritativeDuration.isFinite,
              authoritativeDuration >= 0
        else { return baseTitle }
        return "\(baseTitle) for \(AgentElapsedFormatter.elapsedLabel(authoritativeDuration))"
    }
}

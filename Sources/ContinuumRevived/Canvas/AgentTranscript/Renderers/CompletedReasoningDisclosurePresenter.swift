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
            bodyBlocks: entry.blocks.map(deemphasised),
            title: title,
            accessibilityLabel: title,
            accessibilityValue: expanded ? "Expanded" : "Collapsed",
            isExpanded: expanded
        )
    }

    /// Strips a provider's whole-paragraph bold from a reasoning body.
    ///
    /// Reasoning renders through the same prose path as an assistant answer, with
    /// no de-emphasis anywhere — and providers emit a reasoning item's own section
    /// heading as `**Planning sports updates**`, which
    /// `AgentTranscriptProjection` deliberately splits into its own block. The
    /// result is a paragraph whose ENTIRE inline content is strong, rendered as
    /// 13pt bold body text. Dylan: "the 'thought' expanded details look like
    /// shit, it's bolded".
    ///
    /// Only the whole-paragraph case is touched, and only for reasoning. A bolded
    /// PHRASE inside a sentence is the model emphasising something and is left
    /// exactly as written; this row already draws its own "Thought" title, so a
    /// second heading rendered as bold prose is duplication, not emphasis.
    private static func deemphasised(_ block: AgentBlock) -> AgentBlock {
        guard case let .paragraph(inlines) = block.payload,
              inlines.count == 1,
              case let .strong(children) = inlines[0],
              !children.isEmpty
        else { return block }
        var flattened = block
        flattened.payload = .paragraph(children)
        return flattened
    }

    static func title(authoritativeDuration: TimeInterval?) -> String {
        guard let authoritativeDuration,
              authoritativeDuration.isFinite,
              authoritativeDuration >= 0
        else { return baseTitle }
        return "\(baseTitle) for \(AgentElapsedFormatter.elapsedLabel(authoritativeDuration))"
    }
}

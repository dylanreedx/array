import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// Text-size inputs that can change layout without changing semantic content.
/// Callers should derive `scaleBucket` from their effective content-size policy;
/// keeping it explicit prevents accessibility-sized measurements reusing standard
/// rows.
struct AgentContentSizePolicy: Hashable {
    var scaleBucket: Int

    static let standard = AgentContentSizePolicy(scaleBucket: 100)
}

struct AgentBlockMeasureKey: Hashable {
    let id: AgentNodeID
    let kind: AgentBlockKind
    let revision: UInt64
    let widthBucket: Int
    let appearance: TokenTheme
    let contentSizePolicy: AgentContentSizePolicy
}

/// Width-aware renderer measurement cache. Measurements are semantic-revision
/// scoped: an ID alone is never enough to reuse a height.
@MainActor
final class AgentBlockMeasurementCache {
    private var heights: [AgentBlockMeasureKey: CGFloat] = [:]
    private let widthQuantum: CGFloat

    init(widthQuantum: CGFloat = 1) {
        precondition(widthQuantum > 0 && widthQuantum.isFinite)
        self.widthQuantum = widthQuantum
    }

    func height(
        for block: AgentBlock,
        width: CGFloat,
        context: AgentRenderContext,
        contentSizePolicy: AgentContentSizePolicy = .standard,
        renderer: any AgentBlockRendering
    ) -> CGFloat {
        let key = makeKey(
            block: block,
            width: width,
            appearance: context.appearance,
            contentSizePolicy: contentSizePolicy
        )
        if let cached = heights[key] { return cached }
        let measured = max(0, renderer.measure(block: block, width: width, context: context))
        heights[key] = measured
        return measured
    }

    func invalidate(id: AgentNodeID) {
        heights = heights.filter { $0.key.id != id }
    }

    func removeAll() {
        heights.removeAll(keepingCapacity: true)
    }

    var cachedMeasurementCount: Int { heights.count }

    private func makeKey(
        block: AgentBlock,
        width: CGFloat,
        appearance: TokenTheme,
        contentSizePolicy: AgentContentSizePolicy
    ) -> AgentBlockMeasureKey {
        let finiteWidth = width.isFinite ? max(0, width) : 0
        return AgentBlockMeasureKey(
            id: block.id,
            kind: block.kind,
            revision: block.revision,
            widthBucket: Int((finiteWidth / widthQuantum).rounded()),
            appearance: appearance,
            contentSizePolicy: contentSizePolicy
        )
    }
}

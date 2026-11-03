import Foundation
import ContinuumRevivedAgentContent
import ContinuumRevivedCore

/// A published agent's presented tool and diff blocks, computed from values
/// frozen on the main actor, so the walk can run anywhere
/// (`AgentSupervisor.sharedTranscriptToolDetails`). What it presented and the
/// diff line counts it parsed go back to the supervisor's caches.
struct SharedToolBlockScan: Sendable {
    /// The capture the presentation came from; nil for an agent with none.
    let capture: AgentTranscriptCanvasToolDetail?
    let presentation: AgentTranscriptCanvasToolDetail.Presentation?
    let diffLineCounts: [AgentNodeID: (revision: UInt64, count: Int)]

    struct Result: Sendable {
        var blocks: [AgentNodeID: AgentBlock] = [:]
        var presented: [AgentNodeID: AgentTranscriptCanvasToolDetail.Presentation.Cached] = [:]
        var diffLineCounts: [AgentNodeID: (revision: UInt64, count: Int)] = [:]
    }

    func run(_ entries: [AgentEntry]) -> Result {
        let hidden = AgentTranscriptCanvasView.foldDelegations(entries).superseded
        var result = Result()
        func visit(_ block: AgentBlock, in entry: AgentEntry) {
            guard !hidden.contains(block.id) else { return }
            var presented = block
            if let presentation {
                switch presentation.present(block, in: entry) {
                case .unchanged, .fallback: break
                case let .cached(value): presented = value
                case let .fresh(value, cached): presented = value; result.presented[block.id] = cached
                }
            }
            if case var .diff(diff) = presented.payload {
                if !diff.text.isEmpty {
                    let cached = diffLineCounts[block.id]
                    let count = cached?.revision == block.revision ? cached!.count
                        : GitDiffParser.parse(diff.text).files.flatMap(\.hunks).reduce(0) { $0 + $1.lines.count }
                    if cached?.revision != block.revision { result.diffLineCounts[block.id] = (block.revision, count) }
                    diff.presentedTotalLines = count
                }
                presented.payload = .diff(diff); result.blocks[block.id] = presented
                return
            } else if case .toolCall = block.payload {
                result.blocks[block.id] = presented
                return
            }
            block.children.forEach { visit($0, in: entry) }
        }
        entries.forEach { entry in entry.blocks.forEach { visit($0, in: entry) } }
        return result
    }
}

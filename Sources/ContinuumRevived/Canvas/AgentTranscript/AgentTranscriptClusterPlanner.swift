import Foundation
import ContinuumRevivedAgentContent

/// `.plans/45` S4.3 — the display projection between the semantic `rows` and
/// the diffable snapshot. Dylan's decision 2: consecutive completed tool calls
/// cluster to one line ("6 steps · 5 searches, 1 fetch · 12.4s ✓"); while a
/// run is live, the tail row stays plain under an "N earlier steps" header;
/// failures never fold.
///
/// This is a PURE function over per-row facts. It deliberately does not touch
/// `rows == flatten(document)` — the two rejected alternatives (flatten-level
/// cluster rows, renderer-level 0pt rows) broke the equivalence oracle and the
/// row-gap witness respectively; the record is in the plan. Rebuilt O(rows)
/// once per visual apply, never per delta.
enum AgentTranscriptClusterPlanner {
    struct RowFact: Equatable {
        /// A top-level `.toolCall` / `.commandOutput` row.
        let isToolRow: Bool
        /// `.failed` / `.interrupted` / `.cancelled` — always renders plain and
        /// splits the run.
        let isFailure: Bool
        /// `.pending` / `.inProgress` — the live tail of a run renders plain.
        let isLive: Bool
        /// The row begins a new turn (a run never crosses this).
        let startsTurn: Bool
        /// The row's top-level node ID (block or reasoning entry).
        let id: AgentNodeID
    }

    struct Header: Equatable {
        /// Stable while members append: derived from the FIRST member's ID, so
        /// the snapshot keeps the header instance and only member IDs churn.
        let id: AgentNodeID
        /// Semantic row indexes the header REPRESENTS (folded out of the
        /// snapshot when collapsed; rendered after the header when expanded).
        let memberIndexes: [Int]
        let isLive: Bool
        let isExpanded: Bool
    }

    enum Item: Equatable {
        case row(Int)
        case header(Header)
    }

    static func headerID(forFirstMember id: AgentNodeID) -> AgentNodeID {
        AgentNodeID(rawValue: "__cluster__\(id.rawValue)") ?? id
    }

    /// - Parameters:
    ///   - tailStreaming: the transcript's thinking indicator is up — the LAST
    ///     turn is still producing output, and folding must not flicker through
    ///     that window (t3 adoption: fold decisions key on turn lifecycle, not
    ///     transient row state). Runs in earlier turns still fold.
    static func plan(
        facts: [RowFact],
        tailStreaming: Bool,
        isExpanded: (AgentNodeID) -> Bool
    ) -> [Item] {
        var items: [Item] = []
        items.reserveCapacity(facts.count)
        let lastTurnStart = facts.lastIndex(where: { $0.startsTurn }) ?? 0

        var index = 0
        while index < facts.count {
            let fact = facts[index]
            guard fact.isToolRow, !fact.isFailure else {
                items.append(.row(index))
                index += 1
                continue
            }
            // Collect the maximal run: consecutive tool rows, same turn, no
            // failures (a failure terminates the run and renders plain).
            var run: [Int] = [index]
            var next = index + 1
            while next < facts.count,
                  facts[next].isToolRow,
                  !facts[next].isFailure,
                  !facts[next].startsTurn {
                run.append(next)
                next += 1
            }
            defer { index = next }

            let liveIndex = run.firstIndex { facts[$0].isLive }
            if let liveIndex {
                // Live run: everything before the first live member folds under
                // an "N earlier steps" header; the live rows render plain.
                let earlier = Array(run[..<liveIndex])
                if earlier.count >= 1 {
                    items.append(.header(Header(
                        id: headerID(forFirstMember: facts[earlier[0]].id),
                        memberIndexes: earlier,
                        isLive: true,
                        isExpanded: isExpanded(headerID(forFirstMember: facts[earlier[0]].id))
                    )))
                    if isExpanded(headerID(forFirstMember: facts[earlier[0]].id)) {
                        items.append(contentsOf: earlier.map(Item.row))
                    }
                }
                items.append(contentsOf: run[liveIndex...].map(Item.row))
                continue
            }

            // Settled run in the STREAMING last turn: hold the fold until the
            // turn settles, so rows never vanish mid-stream.
            if tailStreaming, run[0] >= lastTurnStart {
                items.append(contentsOf: run.map(Item.row))
                continue
            }

            // Runs of 1 never cluster.
            guard run.count >= 2 else {
                items.append(.row(run[0]))
                continue
            }

            let id = headerID(forFirstMember: facts[run[0]].id)
            let expanded = isExpanded(id)
            items.append(.header(Header(
                id: id, memberIndexes: run, isLive: false, isExpanded: expanded
            )))
            if expanded {
                items.append(contentsOf: run.map(Item.row))
            }
        }
        return items
    }
}

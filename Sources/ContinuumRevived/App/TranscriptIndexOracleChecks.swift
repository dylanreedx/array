import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// The correctness oracle for the transcript's incremental row index.
///
/// `transcript.delta` measures what a delta COSTS. It cannot see whether the
/// cheap path is right: every count budget in it would still pass if
/// `incrementallyIndexed` rebuilt the wrong row, kept a stale provider identity,
/// or left a position pointing at a neighbour. Cheap and wrong is exactly the
/// failure mode a cost witness is blind to.
///
/// So this drives the REAL `apply(document:patch:)` funnel through a sequence of
/// mutations and, after every one, asserts the live index is indistinguishable
/// from a from-scratch walk of the same document. The full walk stays the
/// reference implementation; the fast path has to match it exactly.
///
/// It also asserts WHICH path ran. Without that, the oracle passes trivially the
/// day `incrementallyIndexed` starts declining everything — equivalence would be
/// perfect and the feature would be gone.
///
/// Gated on `--transcript-delta-index-oracle-check`.
@MainActor
enum TranscriptIndexOracleChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    private static func id(_ value: String) -> AgentNodeID { AgentNodeID(rawValue: value)! }

    private static func block(
        _ name: String,
        revision: UInt64 = 1,
        children: [AgentBlock] = []
    ) -> AgentBlock {
        AgentBlock(
            id: id(name), revision: revision,
            kind: AgentBlockKind(rawValue: "fixture-opaque")!,
            payload: .opaque(AgentOpaquePayload(debugLabel: "\(name)-r\(revision)", value: .null)),
            children: children
        )
    }

    private static func entry(
        _ name: String,
        revision: UInt64 = 1,
        role: AgentEntryRole = .assistant,
        lifecycle: AgentEntryLifecycle = .finished,
        blocks: [AgentBlock]
    ) -> AgentEntry {
        AgentEntry(
            id: id(name), revision: revision, role: role,
            provenance: .localNotice(reason: "index oracle"),
            lifecycle: lifecycle, blocks: blocks
        )
    }

    static func run() throws {
        let list = AgentTranscriptListView()
        list.frame = NSRect(x: 0, y: 0, width: 360, height: 260)
        let host = NSView(frame: list.frame)
        host.addSubview(list)
        list.autoresizingMask = [.width, .height]

        var version: UInt64 = 0
        var fullFlattensBefore = 0

        /// Apply one mutation through the real funnel and assert equivalence.
        /// `expectsFullWalk` records which path the change is supposed to take, so
        /// a fast path that quietly stopped engaging fails here rather than
        /// passing for the wrong reason.
        func step(
            _ label: String,
            entries: [AgentEntry],
            inserted: [AgentNodeID] = [],
            updated: [AgentNodeID] = [],
            removed: [AgentNodeID] = [],
            moved: [AgentNodeID] = [],
            expectsFullWalk: Bool
        ) throws {
            version += 1
            let document = AgentDocument(version: version, entries: entries)
            fullFlattensBefore = list.qaFullFlattenCount
            try list.apply(
                document: document,
                patch: try AgentDocumentPatch(
                    fromVersion: version - 1, toVersion: version,
                    inserted: inserted, updated: updated, removed: removed, moved: moved
                )
            )
            host.layoutSubtreeIfNeeded()

            let walked = list.qaFullFlattenCount > fullFlattensBefore
            try expect(
                walked == expectsFullWalk,
                "\(label): expected \(expectsFullWalk ? "the full walk" : "the incremental path")"
                + " but took \(walked ? "the full walk" : "the incremental path")"
            )
            if let mismatch = list.qaIndexEquivalenceMismatch(for: document) {
                throw Failure(message: "\(label): \(mismatch)")
            }
        }

        // A nested child so the oracle covers an update that arrives addressed to a
        // block which is NOT itself a row, and must rebuild its owning row.
        let nested = block("oracle-nested")
        var alpha = entry("oracle-entry-a", blocks: [block("oracle-a1"), block("oracle-a2", children: [nested])])
        var beta = entry("oracle-entry-b", blocks: [block("oracle-b1")])

        // 1. First load: nothing cached, so the full walk is the only option.
        try step("initial load", entries: [alpha, beta],
                 inserted: [id("oracle-a1"), id("oracle-a2"), id("oracle-b1")],
                 expectsFullWalk: true)
        try expect(list.qaSemanticRowCount == 3, "initial load should present 3 rows, got \(list.qaSemanticRowCount)")

        // 2. Tail revision — the streaming shape, and the one that must be cheap.
        beta = entry("oracle-entry-b", revision: 2, blocks: [block("oracle-b1", revision: 2)])
        try step("tail revision", entries: [alpha, beta],
                 updated: [id("oracle-b1"), id("oracle-entry-b")], expectsFullWalk: false)

        // 3. A MIDDLE row, to prove the position index is not just "the last one".
        alpha = entry("oracle-entry-a", revision: 2,
                      blocks: [block("oracle-a1", revision: 2), block("oracle-a2", children: [nested])])
        try step("middle revision", entries: [alpha, beta],
                 updated: [id("oracle-a1"), id("oracle-entry-a")], expectsFullWalk: false)

        // 4. A nested child changes. The patch names the CHILD, which owns no row;
        //    its owning top-level row has to be the thing that rebuilds.
        let revisedNested = block("oracle-nested", revision: 2)
        alpha = entry("oracle-entry-a", revision: 3,
                      blocks: [block("oracle-a1", revision: 2), block("oracle-a2", children: [revisedNested])])
        try step("nested child revision", entries: [alpha, beta],
                 updated: [id("oracle-nested"), id("oracle-a2"), id("oracle-entry-a")], expectsFullWalk: false)

        // 5. An entry's ROLE changes. Every row in it presents differently, so this
        //    must decline to the full walk rather than patch rows in place.
        alpha = entry("oracle-entry-a", revision: 4, role: .user,
                      blocks: [block("oracle-a1", revision: 2), block("oracle-a2", children: [revisedNested])])
        try step("entry role change", entries: [alpha, beta],
                 updated: [id("oracle-entry-a")], expectsFullWalk: true)

        // 6. An insert changes row ORDER, which is what the full walk is for.
        alpha = entry("oracle-entry-a", revision: 5, role: .user,
                      blocks: [block("oracle-a1", revision: 2), block("oracle-a3"),
                               block("oracle-a2", children: [revisedNested])])
        try step("insert in the middle", entries: [alpha, beta],
                 inserted: [id("oracle-a3")], expectsFullWalk: true)
        try expect(list.qaSemanticRowCount == 4, "after insert should present 4 rows, got \(list.qaSemanticRowCount)")

        // 7. And a removal.
        alpha = entry("oracle-entry-a", revision: 6, role: .user,
                      blocks: [block("oracle-a1", revision: 2), block("oracle-a2", children: [revisedNested])])
        try step("removal", entries: [alpha, beta],
                 removed: [id("oracle-a3")], expectsFullWalk: true)
        try expect(list.qaSemanticRowCount == 3, "after removal should present 3 rows, got \(list.qaSemanticRowCount)")

        // 8. Reasoning: OPEN reasoning is not a row at all, so it appearing and then
        //    finishing is structural in both directions.
        let reasoningOpen = entry("oracle-entry-r", role: .reasoning,
                                  lifecycle: .open(markupBlockID: nil), blocks: [block("oracle-r1")])
        try step("open reasoning arrives", entries: [alpha, beta, reasoningOpen],
                 inserted: [id("oracle-r1")], expectsFullWalk: true)
        try expect(
            list.qaSemanticRowCount == 3,
            "open reasoning must not present a row; got \(list.qaSemanticRowCount)"
        )

        let reasoningFinished = entry("oracle-entry-r", revision: 2, role: .reasoning,
                                      lifecycle: .finished, blocks: [block("oracle-r1")])
        try step("reasoning finishes", entries: [alpha, beta, reasoningFinished],
                 updated: [id("oracle-entry-r")], expectsFullWalk: true)
        try expect(
            list.qaSemanticRowCount == 4,
            "finished reasoning must present one row; got \(list.qaSemanticRowCount)"
        )

        // 9. A finished reasoning row revising its body IS local.
        let reasoningRevised = entry("oracle-entry-r", revision: 3, role: .reasoning,
                                     lifecycle: .finished, blocks: [block("oracle-r1", revision: 2)])
        try step("finished reasoning revises", entries: [alpha, beta, reasoningRevised],
                 updated: [id("oracle-r1"), id("oracle-entry-r")], expectsFullWalk: false)

        // 10. An id the view has never indexed cannot be patched in place.
        try step("unknown id", entries: [alpha, beta, reasoningRevised],
                 updated: [id("oracle-never-seen")], expectsFullWalk: true)

        list.removeFromSuperview()
    }
}

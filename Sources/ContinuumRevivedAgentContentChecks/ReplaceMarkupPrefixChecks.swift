import ContinuumRevivedAgentContent
import Foundation

/// A streamed reply replaces its entry's blocks on every parse. The reducer used to
/// validate, hash, reconcile and re-index the WHOLE entry each time; it now skips the
/// leading blocks the reply left untouched. Both reducers below take the same
/// sequence: every patch and document must be identical, and the work the fast one
/// does must stay bounded by what changed, not by the reply.
func runReplaceMarkupPrefixChecks() {
    let entry = AgentNodeID(rawValue: "entry:prefix")!
    let parser = MarkdownAgentMarkupParser()

    var sections: [String] = []
    for i in 1...30 {
        sections.append("## Step \(i)\n\nParagraph \(i) with `code` and **bold**.")
        sections.append("- item a \(i)\n- item b\n  - nested")
        sections.append("```swift\nlet v\(i) = \(i)\n```")
        sections.append("| k | v |\n|---|---|\n| a | \(i) |")
    }
    let reply = sections.joined(separator: "\n\n")

    func makeReducer(fast: Bool) -> AgentDocumentReducer {
        var reducer = AgentDocumentReducer()
        reducer.replaceMarkupSkipsUnchangedPrefix = fast
        do { _ = try reducer.apply(.beginEntry(id: entry, role: .assistant, provenance: .localNotice(reason: "prefix"))) }
        catch { fail("prefix witness: beginEntry failed: \(error)") }
        return reducer
    }
    var legacy = makeReducer(fast: false)
    var fast = makeReducer(fast: ProcessInfo.processInfo.environment["WITNESS_FORCE_FULL_REDUCER"] == nil)
    var cache = AgentStreamingParseCache()
    var previous: [AgentBlock] = []
    var soFar = ""
    var legacyNodes: UInt64 = 0, fastNodes: UInt64 = 0
    var lateLegacy: UInt64 = 0, lateFast: UInt64 = 0
    let chunk = 7
    var cursor = reply.startIndex
    var step = 0
    while cursor < reply.endIndex {
        let end = reply.index(cursor, offsetBy: chunk, limitedBy: reply.endIndex) ?? reply.endIndex
        soFar += reply[cursor..<end]
        cursor = end
        step += 1
        let parse = parser.parseIncremental(soFar, entryID: entry, previous: previous, cache: &cache)
        previous = parse.blocks
        let legacyBefore = legacy.metrics.reindexedNodes, fastBefore = fast.metrics.reindexedNodes
        let a = Result { try legacy.apply(.replaceMarkup(entryID: entry, blocks: parse.blocks)) }
        let b = Result { try fast.apply(.replaceMarkup(entryID: entry, blocks: parse.blocks)) }
        switch (a, b) {
        case let (.success(x), .success(y)):
            expect(x == y, "replaceMarkup patch diverged at step \(step): \(x) vs \(y)")
        case let (.failure(x), .failure(y)):
            expect("\(x)" == "\(y)", "replaceMarkup error diverged at step \(step)")
        default:
            fail("replaceMarkup succeeded on one reducer and failed on the other at step \(step)")
        }
        expect(legacy.document == fast.document, "document diverged at step \(step)")
        legacyNodes += legacy.metrics.reindexedNodes - legacyBefore
        fastNodes += fast.metrics.reindexedNodes - fastBefore
        lateLegacy = legacy.metrics.reindexedNodes - legacyBefore
        lateFast = fast.metrics.reindexedNodes - fastBefore
    }
    expect(step > 150, "prefix witness must stream many replacements; got \(step)")
    expect(lateLegacy > 400, "the whole-entry pass must re-index the entire reply at the end; got \(lateLegacy)")
    expect(lateFast * 20 < lateLegacy,
           "replaceMarkup must re-index O(changed tail), not O(reply): last step \(lateFast) vs \(lateLegacy) nodes")
    expect(fastNodes * 10 < legacyNodes, "total re-indexed nodes must drop by 10x: \(fastNodes) vs \(legacyNodes)")

    // A tail node may not reuse the ID of a kept prefix node: same error either way.
    for useFast in [false, true] {
        var reducer = makeReducer(fast: useFast)
        let first = AgentBlock(id: AgentNodeID(rawValue: "b:one")!, kind: .paragraph, payload: .paragraph([.text("one")]))
        let second = AgentBlock(id: AgentNodeID(rawValue: "b:two")!, kind: .paragraph, payload: .paragraph([.text("two")]))
        _ = try? reducer.apply(.replaceMarkup(entryID: entry, blocks: [first, second]))
        let clash = AgentBlock(id: first.id, kind: .paragraph, payload: .paragraph([.text("clash")]))
        do {
            _ = try reducer.apply(.replaceMarkup(entryID: entry, blocks: [first, clash]))
            fail("a tail block reusing a prefix block's ID must be rejected (fast: \(useFast))")
        } catch let error as AgentDocumentMutationError {
            guard case let .duplicateNodeID(id) = error, id == first.id else {
                fail("wrong error for a prefix ID clash (fast: \(useFast)): \(error)")
            }
        } catch { fail("unexpected error type (fast: \(useFast)): \(error)") }
    }
    print("Replace-markup prefix checks passed: \(step) streamed replacements identical to the whole-entry pass; last step re-indexed \(lateFast) vs \(lateLegacy) nodes; total \(fastNodes) vs \(legacyNodes)")
}

import Foundation
import ContinuumRevivedAgentContent

// Exact frozen pre-fix matcher/helpers from parser SHA63463a70…56c9d8.
// Independent old algorithm; never calls the new reconciliation path.
private struct LegacyMarkdownIdentityOracle {
    func reconcileIdentities(_ current: [AgentBlock], with previous: [AgentBlock]) -> [AgentBlock] {
        var exactMatches: [Int: Int] = [:]
        var reservedPrevious: Set<Int> = []

        for currentIndex in current.indices {
            if let previousIndex = previous.indices.first(where: {
                !reservedPrevious.contains($0) && semanticallyEqual(current[currentIndex], previous[$0])
            }) {
                exactMatches[currentIndex] = previousIndex
                reservedPrevious.insert(previousIndex)
            }
        }

        // Exact completed-node matches own their previous identities before a
        // newly inserted positional node is considered. Structural generated
        // IDs can otherwise collide when a sibling is inserted before one of
        // those matches, making the newcomer appear to steal the old node.
        var reservedIDs = Set(exactMatches.values.map { previous[$0].id })
        return current.indices.map { currentIndex in
            if let previousIndex = exactMatches[currentIndex] {
                return adoptingIdentity(current[currentIndex], from: previous[previousIndex])
            }
            if previous.indices.contains(currentIndex),
               !reservedPrevious.contains(currentIndex),
               previous[currentIndex].kind == current[currentIndex].kind {
                reservedPrevious.insert(currentIndex)
                reservedIDs.insert(previous[currentIndex].id)
                return adoptingIdentity(current[currentIndex], from: previous[currentIndex])
            }
            if currentIndex == current.startIndex,
               let previousIndex = previous.indices.first(where: {
                   !reservedPrevious.contains($0) && previous[$0].kind == current[currentIndex].kind
               }) {
                reservedPrevious.insert(previousIndex)
                reservedIDs.insert(previous[previousIndex].id)
                return adoptingIdentity(current[currentIndex], from: previous[previousIndex])
            }
            var block = current[currentIndex]
            if reservedIDs.contains(block.id) {
                block = replacingIdentity(
                    block,
                    with: blockID(entryID: block.id, stableKey: "inserted.\(currentIndex)")
                )
            }
            reservedIDs.insert(block.id)
            return block
        }
    }

    private func semanticallyEqual(_ lhs: AgentBlock, _ rhs: AgentBlock) -> Bool {
        lhs.kind == rhs.kind && lhs.payload == rhs.payload &&
            lhs.children.count == rhs.children.count &&
            zip(lhs.children, rhs.children).allSatisfy { semanticallyEqual($0.0, $0.1) }
    }

    private func adoptingIdentity(_ block: AgentBlock, from previous: AgentBlock) -> AgentBlock {
        AgentBlock(
            id: previous.id,
            revision: block.revision,
            kind: block.kind,
            sourceRange: block.sourceRange,
            payload: block.payload,
            children: reconcileIdentities(block.children, with: previous.children)
        )
    }

    private func replacingIdentity(_ block: AgentBlock, with id: AgentNodeID) -> AgentBlock {
        AgentBlock(
            id: id,
            revision: block.revision,
            kind: block.kind,
            sourceRange: block.sourceRange,
            payload: block.payload,
            children: block.children
        )
    }

    private func blockID(entryID: AgentNodeID, stableKey: String) -> AgentNodeID {
        if let child = entryID.childID(stableKey: stableKey) { return child }

        var first: UInt64 = 0xcbf29ce484222325
        var second: UInt64 = 0x84222325cbf29ce4
        for byte in entryID.rawValue.utf8 {
            first = (first ^ UInt64(byte)) &* 0x100000001b3
            second = (second ^ UInt64(byte)) &* 0x9e3779b185ebca87
        }
        let digest = String(format: "%016llx%016llx", first, second)
        return AgentNodeID(rawValue: "markdown-entry:\(digest)/\(stableKey)")!
    }
}

private final class ParserIdentityWorkCount: @unchecked Sendable {
    private let lock = NSLock()
    private var visits = 0
    func add(_ value: Int) { lock.lock(); visits += value; lock.unlock() }
    func reset() { lock.lock(); visits = 0; lock.unlock() }
    var total: Int { lock.lock(); defer { lock.unlock() }; return visits }
}

func runParserIdentityPrefixChecks() {
    let id = AgentNodeID(rawValue: "entry:identity-prefix-check")!
    let ordinary = MarkdownAgentMarkupParser()
    let work = ParserIdentityWorkCount()
    let parser = MarkdownAgentMarkupParser(reconciliationWork: { work.add($0) })
    let oracle = LegacyMarkdownIdentityOracle()
    var cases = 0
    func check(_ source: String, previous: [AgentBlock]) {
        let provisional = ordinary.parse(source, entryID: id, previous: [])
        let expected = oracle.reconcileIdentities(provisional.blocks, with: previous)
        let actual = parser.parse(source, entryID: id, previous: previous)
        expect(actual.blocks == expected && actual.diagnostics == provisional.diagnostics,
               "actual parser differs from frozen legacy identity oracle case \(cases)")
        cases += 1
    }
    let corpus = ["", "same\n\nsame", "a\n\nb\n\na", "# Heading\n\nbody",
                  "- one\n- two\n\n> quote", "```swift\nlet x=1\n```\n\nafter",
                  "|a|b|\n|-|-|\n|c|d|", "**café** 日本語\n\n[link](https://example.com)"]
    for before in corpus {
        let previous = ordinary.parse(before, entryID: id, previous: []).blocks
        for after in corpus { check(after, previous: previous) }
    }
    for n in [128, 512, 2048] {
        let paragraphs = (0..<n).map { "MEM_\($0) café 日本語 " + String(repeating: "ordered content ", count: 8) }
        let source = paragraphs.joined(separator: "\n\n")
        let previous = ordinary.parse(source, entryID: id, previous: []).blocks
        for (name, changed) in [("unchanged", source), ("append", source + "\n\nnew tail"),
                                ("edit-tail", paragraphs.dropLast().joined(separator: "\n\n") + "\n\nedited tail")] {
            work.reset()
            check(changed, previous: previous)
            let visits = work.total
            expect(visits > 0 && visits <= 4*n+4,
                   "identity-prefix \(name) n=\(n): actual candidate visits \(visits), bound \(4*n+4)")
            print("PARSER_IDENTITY_WORK name=\(name) paragraphs=\(n) visits=\(visits)")
        }
    }
    print("Parser identity prefix checks passed: actual parser, \(cases) complete AST/legacy-oracle cases, bounded common-prefix work; ambiguous suffix retains original fallback")
}

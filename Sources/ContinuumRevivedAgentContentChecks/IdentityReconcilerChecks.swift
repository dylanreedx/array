import ContinuumRevivedAgentContent
import Foundation

private func identityCheckID(_ raw: String) -> AgentNodeID { AgentNodeID(rawValue: raw)! }

private func identityReconcile(previous: [AgentBlock], parsed: [AgentBlock]) -> AgentNodeIdentityReconciliation {
    do { return try AgentNodeIdentityReconciler.reconcile(previous: previous, parsed: parsed) }
    catch { fail("unexpected reconciliation error: \(error)") }
}

private func sameIDTree(_ lhs: [AgentBlock], _ rhs: [AgentBlock]) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
        $0.0.id == $0.1.id && sameIDTree($0.0.children, $0.1.children)
    }
}

func runIdentityReconcilerChecks() {
    let firstID = identityCheckID("block:first")
    let tailID = identityCheckID("block:tail")
    let first = AgentBlock(id: firstID, revision: 2, kind: .paragraph, payload: .paragraph([.text("first")]))
    let tail = AgentBlock(id: tailID, revision: 0, kind: .paragraph, payload: .paragraph([.text("draft")]))
    let appended = AgentBlock(id: identityCheckID("provisional:first"), kind: .paragraph, payload: .paragraph([.text("first")]))
    let changedTail = AgentBlock(id: identityCheckID("provisional:tail"), kind: .paragraph, payload: .paragraph([.text("draft now complete")]))
    let result = identityReconcile(previous: [first, tail], parsed: [appended, changedTail])
    expect(result.blocks.map(\.id) == [firstID, tailID], "reconciliation must preserve stable IDs for an edited tail")
    expect(result.blocks[0].revision == 2, "unchanged prefix must not receive a new revision")
    expect(result.blocks[1].revision == 1 && result.patch.updated == [tailID], "changed tail must increment revision and be updated")
    expect(result.patch.inserted.isEmpty && result.patch.removed.isEmpty, "editing a tail is not an insertion or removal")

    let openCode = AgentBlock(id: tailID, revision: 4, kind: .fencedCode,
                              payload: .fencedCode(.init(language: "swift", code: "let x = 1", isComplete: false)))
    let closedCode = AgentBlock(id: identityCheckID("new-code"), kind: .fencedCode,
                                payload: .fencedCode(.init(language: "swift", code: "let x = 1\n", isComplete: true)))
    let codeResult = identityReconcile(previous: [openCode], parsed: [closedCode])
    expect(codeResult.blocks[0].id == tailID && codeResult.blocks[0].revision == 5,
           "incomplete-to-complete code must reuse identity and increment revision")

    let repeatedA = AgentBlock(id: identityCheckID("repeat-a"), kind: .paragraph, payload: .paragraph([.text("same")]))
    let repeatedB = AgentBlock(id: identityCheckID("repeat-b"), kind: .paragraph, payload: .paragraph([.text("same")]))
    let repeated = identityReconcile(previous: [repeatedA, repeatedB], parsed: [
        AgentBlock(id: identityCheckID("new-a"), kind: .paragraph, payload: .paragraph([.text("same")])),
        AgentBlock(id: identityCheckID("new-b"), kind: .paragraph, payload: .paragraph([.text("same")]))
    ])
    expect(repeated.blocks.map(\.id) == [repeatedA.id, repeatedB.id], "repeated paragraphs must match by occurrence, not body-only identity")

    let repeatedAppend = identityReconcile(previous: [repeatedA], parsed: [
        AgentBlock(id: identityCheckID("same-a"), kind: .paragraph, payload: .paragraph([.text("same")])),
        AgentBlock(id: identityCheckID("same-b"), kind: .paragraph, payload: .paragraph([.text("same")]))
    ])
    expect(repeatedAppend.blocks.map(\.id) == [repeatedA.id, identityCheckID("same-b")],
           "appending an equal repeated sibling must preserve the completed prefix and allocate at the tail")

    // Semantic uniqueness reserves old identities even when an insertion is at
    // the leading or middle position; only the inserted node is fresh.
    let uniqueA = AgentBlock(id: identityCheckID("unique-a"), kind: .paragraph, payload: .paragraph([.text("A")]))
    let uniqueB = AgentBlock(id: identityCheckID("unique-b"), kind: .paragraph, payload: .paragraph([.text("B")]))
    let uniqueC = AgentBlock(id: identityCheckID("unique-c"), kind: .paragraph, payload: .paragraph([.text("C")]))
    let uniqueInsertion = identityReconcile(previous: [uniqueA, uniqueB, uniqueC], parsed: [
        AgentBlock(id: identityCheckID("new-leading"), kind: .heading, payload: .heading(level: 2, content: [.text("new")])),
        AgentBlock(id: identityCheckID("a"), kind: .paragraph, payload: .paragraph([.text("A")])),
        AgentBlock(id: identityCheckID("b"), kind: .paragraph, payload: .paragraph([.text("B")])),
        AgentBlock(id: identityCheckID("c"), kind: .paragraph, payload: .paragraph([.text("C")]))
    ])
    expect(uniqueInsertion.blocks.map(\.id) == [identityCheckID("new-leading"), uniqueA.id, uniqueB.id, uniqueC.id],
           "a semantically unique leading insertion must not steal a completed identity")
    expect(uniqueInsertion.patch.inserted == [identityCheckID("new-leading")],
           "a unique leading insertion must report only its fresh root")

    let middleInsertion = identityReconcile(previous: [uniqueA, uniqueB, uniqueC], parsed: [
        AgentBlock(id: identityCheckID("a2"), kind: .paragraph, payload: .paragraph([.text("A")])),
        AgentBlock(id: identityCheckID("new-middle"), kind: .heading, payload: .heading(level: 2, content: [.text("new")])),
        AgentBlock(id: identityCheckID("b2"), kind: .paragraph, payload: .paragraph([.text("B")])),
        AgentBlock(id: identityCheckID("c2"), kind: .paragraph, payload: .paragraph([.text("C")]))
    ])
    expect(middleInsertion.blocks.map(\.id) == [uniqueA.id, identityCheckID("new-middle"), uniqueB.id, uniqueC.id],
           "a semantically unique middle insertion must not steal the edited tail identity")

    // Compatibility belongs only to the actual parsed tail. A unique middle
    // insertion must stay fresh while the edited open tail retains B's identity.
    let openA = AgentBlock(id: identityCheckID("open-a"), revision: 6, kind: .paragraph,
                           payload: .paragraph([.text("A")]))
    let openB = AgentBlock(id: identityCheckID("open-b"), revision: 4, kind: .paragraph,
                           payload: .paragraph([.text("B draft")]))
    let tailAfterInsertion = identityReconcile(
        previous: [openA, openB],
        parsed: [
            AgentBlock(id: identityCheckID("parsed-a"), revision: 0, kind: .paragraph,
                       payload: .paragraph([.text("A")])),
            AgentBlock(id: identityCheckID("unique-insertion"), kind: .heading,
                       payload: .heading(level: 2, content: [.text("inserted")])),
            AgentBlock(id: identityCheckID("parsed-b"), kind: .paragraph,
                       payload: .paragraph([.text("B edited")]))
        ])
    let insertionID = identityCheckID("unique-insertion")
    expect(tailAfterInsertion.blocks.map(\.id) == [openA.id, insertionID, openB.id],
           "only the actual parsed tail may adopt the previous open-tail identity")
    expect(tailAfterInsertion.blocks[0].revision == openA.revision,
           "A must retain its identity and revision after a unique insertion")
    expect(tailAfterInsertion.blocks[2].revision == openB.revision + 1,
           "B must retain its identity and increment revision when edited")
    expect(tailAfterInsertion.patch.inserted == [insertionID] && tailAfterInsertion.patch.updated == [openB.id],
           "patches must identify the fresh insertion and edited B tail")
    expect(tailAfterInsertion.patch.removed.isEmpty && tailAfterInsertion.patch.moved == [openB.id],
           "middle insertion plus edited tail must report B as moved, not removed")

    // A completed sibling is not eligible for compatibility matching. The
    // edited open tail may retain B, but the unrelated insertion must remain
    // fresh rather than borrowing B's identity.
    let unrelatedInsertion = identityReconcile(
        previous: [repeatedA, repeatedB],
        parsed: [
            AgentBlock(id: identityCheckID("unrelated"), kind: .heading, payload: .heading(level: 2, content: [.text("new")])),
            AgentBlock(id: identityCheckID("old-a"), kind: .paragraph, payload: .paragraph([.text("same")])),
            AgentBlock(id: identityCheckID("edited-tail"), kind: .paragraph, payload: .paragraph([.text("changed")]))
        ])
    expect(unrelatedInsertion.blocks.map(\.id) == [identityCheckID("unrelated"), repeatedA.id, repeatedB.id],
           "a semantically unique insertion must not steal a completed or edited-tail identity")
    expect(unrelatedInsertion.patch.inserted == [identityCheckID("unrelated")] &&
           unrelatedInsertion.patch.updated == [repeatedB.id],
           "fresh unique insertion and edited tail update must both be reported")

    // Delimiter-driven Markdown shape changes are still one open semantic node.
    let headingTail = identityReconcile(
        previous: [AgentBlock(id: tailID, revision: 7, kind: .paragraph, payload: .paragraph([.text("title")]))],
        parsed: [AgentBlock(id: identityCheckID("heading-provisional"), kind: .heading,
                            payload: .heading(level: 2, content: [.text("title")]))]
    )
    expect(headingTail.blocks[0].id == tailID && headingTail.blocks[0].revision == 8,
           "an open paragraph-to-heading reparse must retain identity and advance revision")

    // A maximum-length provisional ID can collide with an old completed node;
    // allocating the newcomer must stay bounded and must not force-unwrap an
    // oversized position-derived candidate.
    let longID = identityCheckID(String(repeating: "x", count: 512))
    let longTail = AgentBlock(id: identityCheckID("long-tail"), kind: .paragraph,
                              payload: .paragraph([.text("tail")]))
    let boundedInsertion = identityReconcile(
        previous: [AgentBlock(id: longID, kind: .paragraph, payload: .paragraph([.text("old")])), longTail],
        parsed: [AgentBlock(id: longID, kind: .heading, payload: .heading(level: 2, content: [.text("inserted")])),
                 AgentBlock(id: identityCheckID("tail-now"), kind: .paragraph, payload: .paragraph([.text("tail")]))]
    )
    expect(boundedInsertion.blocks[0].id != longID && boundedInsertion.blocks[0].id.rawValue.utf8.count <= 512,
           "colliding maximum-length provisional IDs must allocate a bounded fresh identity")

    // Newly inserted subtrees report every descendant, matching the reducer's
    // patch convention used by incremental consumers.
    let nested = AgentBlock(id: identityCheckID("new-list"), kind: .list,
                            payload: .list(.init(ordered: false)), children: [
        AgentBlock(id: identityCheckID("new-item"), kind: .listItem, payload: .listItem, children: [
            AgentBlock(id: identityCheckID("new-paragraph"), kind: .paragraph, payload: .paragraph([.text("nested")]))
        ])
    ])
    let nestedResult = identityReconcile(previous: [], parsed: [nested])
    expect(Set(nestedResult.patch.inserted) == Set([identityCheckID("new-list"), identityCheckID("new-item"), identityCheckID("new-paragraph")]),
           "inserting a subtree must report its root and every descendant")

    // Exercise this reconciler—not the parser's private compatibility helper—at
    // every scalar boundary. The final IDs must converge to the unchunked parse.
    let parser = MarkdownAgentMarkupParser()
    let source = "same\n\nsame\n\n```swift\nlet value = 1\n```\n\nafter"
    let entryID = identityCheckID("entry:identity-chunks")
    let baseline = parser.parse(source, entryID: entryID, previous: []).blocks
    let scalars = Array(source.unicodeScalars)
    for split in 0...scalars.count {
        var previous: [AgentBlock] = []
        let prefix = String(String.UnicodeScalarView(scalars[..<split]))
        let suffix = String(String.UnicodeScalarView(scalars[split...]))
        for sourceAtStep in [prefix, prefix + suffix] {
            let provisional = parser.parse(sourceAtStep, entryID: entryID, previous: []).blocks
            previous = identityReconcile(previous: previous, parsed: provisional).blocks
        }
        expect(sameIDTree(previous, baseline), "identity reconciliation must converge recursively at scalar split \(split)")
    }
    var scalarPrevious: [AgentBlock] = []
    for end in 1...scalars.count {
        let sourceAtStep = String(String.UnicodeScalarView(scalars[..<end]))
        let provisional = parser.parse(sourceAtStep, entryID: entryID, previous: []).blocks
        scalarPrevious = identityReconcile(previous: scalarPrevious, parsed: provisional).blocks
    }
    expect(sameIDTree(scalarPrevious, baseline), "one-scalar chunks must converge recursively to the unchunked IDs")

    do {
        _ = try AgentNodeIdentityReconciler.reconcile(
            previous: [AgentBlock(id: tailID, revision: .max, kind: .paragraph, payload: .paragraph([.text("old")] ))],
            parsed: [AgentBlock(id: identityCheckID("overflow-new"), kind: .paragraph, payload: .paragraph([.text("new")] ))]
        )
        fail("reconciliation revision overflow must be a recoverable public error")
    } catch AgentNodeIdentityReconciler.Error.revisionOverflow(let id, let current) {
        expect(id == tailID && current == .max, "revision overflow must identify the node and current revision")
    } catch { fail("reconciliation overflow returned an unexpected error: \(error)") }

    expect(result.blocks[1].id != changedTail.id, "provisional IDs must not replace the open tail")

    // Keep the final-code gate mutation-sensitive: these assertions inspect the
    // production implementation that this executable links, rather than a
    // second local algorithm or a comment-only witness.
    let reconcilerURL = repoRoot.appendingPathComponent("Sources/ContinuumRevivedAgentContent/AgentNodeIdentityReconciler.swift")
    guard let reconcilerSource = try? String(contentsOf: reconcilerURL, encoding: .utf8) else {
        fail("cannot read the production reconciler for its final-code gate")
    }
    expect(reconcilerSource.contains("throw Error.revisionOverflow"), "production reconciliation must throw its public revision error")
    expect(reconcilerSource.contains("try insertFresh"), "production reconciliation must recursively allocate inserted subtrees")
    expect(!reconcilerSource.contains("preconditionFailure"), "production reconciliation must not abort on recoverable overflow")
    print("Identity reconciliation checks passed: prefix stability, tail revisions, compatible code closure, repeated-node insertion, subtree patches, and chunk convergence")
}

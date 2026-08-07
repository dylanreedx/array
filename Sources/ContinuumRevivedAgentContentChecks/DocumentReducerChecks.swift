import ContinuumRevivedAgentContent
import Foundation

private func reducerID(_ raw: String) -> AgentNodeID {
    guard let id = AgentNodeID(rawValue: raw) else { fail("invalid reducer fixture ID: \(raw)") }
    return id
}

private func paragraphText(_ block: AgentBlock) -> String? {
    guard case let .paragraph(inlines) = block.payload else { return nil }
    return inlines.compactMap { if case let .text(value) = $0 { return value }; return nil }.joined()
}

func runDocumentReducerChecks() {
    let entryID = reducerID("entry:reducer")
    let toolID = reducerID("block:tool")

    do {
        var reducer = AgentDocumentReducer()
        let begin = try reducer.apply(.beginEntry(id: entryID, role: .assistant,
                                                   provenance: .providerItem(provider: "fixture", itemID: "turn")))
        expect(begin.inserted == [entryID], "beginEntry must insert its stable ID")
        _ = try reducer.apply(.appendMarkup(entryID: entryID, delta: "hello "))

        // A reducer reconstructed from the semantic snapshot must extend the
        // same open block and emit the same next patch.
        var reconstructed = AgentDocumentReducer(document: reducer.document)
        let expectedPatch = try reducer.apply(.appendMarkup(entryID: entryID, delta: "world"))
        let reconstructedPatch = try reconstructed.apply(.appendMarkup(entryID: entryID, delta: "world"))
        expect(reconstructed.document == reducer.document && reconstructedPatch == expectedPatch,
               "open-stream continuation must be fully reconstructible from AgentDocument")
        let markupID = reducer.document.entries[0].blocks[0].id
        expect(paragraphText(reducer.document.entries[0].blocks[0]) == "hello world",
               "appendMarkup must preserve raw deltas without parsing")

        let tool = AgentBlock(id: toolID, revision: 77, kind: .toolCall,
                              payload: .toolCall(.init(name: "search", status: .inProgress)))
        let insertion = try reducer.apply(.upsertStructured(entryID: entryID, block: tool))
        expect(insertion.inserted == [toolID] && reducer.document.entries[0].blocks[1].revision == 0,
               "new structured nodes must be inserted with normalized revisions")
        _ = try reducer.apply(.appendMarkup(entryID: entryID, delta: " after"))
        let trailingMarkupID = reducer.document.entries[0].blocks[2].id
        expect(reducer.document.entries[0].blocks.map(\.id) == [markupID, toolID, trailingMarkupID],
               "interleaved assistant text and structured blocks must preserve order")
        let toolUpdate = AgentBlock(id: toolID, revision: .max, kind: .toolCall,
                                    payload: .toolCall(.init(name: "search", summary: "still running", status: .inProgress)))
        _ = try reducer.apply(.upsertStructured(entryID: entryID, block: toolUpdate))
        _ = try reducer.apply(.appendMarkup(entryID: entryID, delta: " again"))
        expect(reducer.document.entries[0].blocks.count == 3 &&
               reducer.document.entries[0].blocks[2].id == trailingMarkupID &&
               paragraphText(reducer.document.entries[0].blocks[2]) == " after again",
               "updating an earlier structured block must not lose the reconstructible open-markup owner")
        _ = try reducer.apply(.completeBlock(id: toolID, status: .completed))
        guard case let .toolCall(completed) = reducer.document.entries[0].blocks[1].payload else {
            fail("typed tool payload disappeared")
        }
        expect(completed.status == .completed, "completeBlock must update typed lifecycle state")

        let finish = try reducer.apply(.finishEntry(id: entryID))
        expect(finish.updated == [entryID] && reducer.document.entries[0].lifecycle == .finished,
               "finishEntry must persist finished semantic state")
        let finishedSnapshot = reducer.document
        var finishedCopy = AgentDocumentReducer(document: finishedSnapshot)
        do {
            _ = try finishedCopy.apply(.appendMarkup(entryID: entryID, delta: " forbidden"))
            fail("append-after-finish must fail after snapshot reconstruction")
        } catch let error as AgentDocumentMutationError {
            expect(error == .entryFinished(entryID: entryID, operation: .appendMarkup),
                   "append-after-finish must report the finished entry")
        }
        do {
            _ = try reducer.apply(.completeBlock(id: toolID, status: .completed))
            fail("block completion after finish must fail")
        } catch let error as AgentDocumentMutationError {
            expect(error == .entryFinished(entryID: entryID, operation: .completeBlock),
                   "finish must freeze structured status as well as markup")
        }
        do {
            _ = try reducer.apply(.finishEntry(id: entryID))
            fail("duplicate finish must fail")
        } catch let error as AgentDocumentMutationError {
            expect(error == .duplicateFinish(entryID: entryID), "duplicate finish must remain explicit")
        }
        expect(reducer.document == finishedSnapshot, "failed post-finish mutations must be atomic")
    } catch { fail("valid reducer sequence failed: \(error)") }

    do {
        // Codable must preserve the lifecycle seam and reject an open marker
        // that does not identify the entry's final paragraph.
        let valid = AgentDocument(entries: [AgentEntry(id: entryID, role: .assistant,
            provenance: .localNotice(reason: "roundtrip"), lifecycle: .finished)])
        let roundTrip = try JSONDecoder().decode(AgentDocument.self, from: JSONEncoder().encode(valid))
        expect(roundTrip == valid, "finished entry lifecycle must round-trip through Codable")
        let missing = reducerID("block:missing-open")
        let invalid = AgentDocument(entries: [AgentEntry(id: entryID, role: .assistant,
            provenance: .localNotice(reason: "invalid"), lifecycle: .open(markupBlockID: missing))])
        expect((try? JSONDecoder().decode(AgentDocument.self, from: JSONEncoder().encode(invalid))) == nil,
               "Codable must reject an open-markup marker not backed by the semantic tree")
    } catch { fail("entry lifecycle Codable check failed: \(error)") }

    do {
        var nested = AgentDocumentReducer()
        let nestedEntry = reducerID("entry:nested")
        let parentID = reducerID("block:parent")
        let childID = reducerID("block:child")
        let futureID = reducerID("block:future")
        _ = try nested.apply(.beginEntry(id: nestedEntry, role: .assistant, provenance: .localNotice(reason: "nested")))
        let child = AgentBlock(id: childID, kind: .toolCall,
                               payload: .toolCall(.init(name: "nested", status: .inProgress)))
        let parent = AgentBlock(id: parentID, revision: 90, kind: .plan,
                                payload: .plan(.init(status: .inProgress)), children: [child])
        _ = try nested.apply(.upsertStructured(entryID: nestedEntry, block: parent))
        let before = nested.document
        let completion = try nested.apply(.completeBlock(id: childID, status: .completed))
        expect(completion.updated.contains(parentID) && completion.updated.contains(childID),
               "nested completion must patch and revise its ancestors")
        try nested.document.validateIdentityInvariants(previous: before)

        let beforeNestedUpsert = nested.document
        let metricsBeforeNestedUpsert = nested.metrics
        let updatedChild = AgentBlock(
            id: childID,
            revision: .max,
            kind: .toolCall,
            payload: .toolCall(.init(name: "nested", summary: "indexed child update", status: .completed))
        )
        let nestedPatch = try nested.apply(.upsertStructured(entryID: nestedEntry, block: updatedChild))
        expect(Set(nestedPatch.updated) == Set([nestedEntry, parentID, childID]) && nestedPatch.updated.count == 3 &&
               nested.document.entries[0].blocks[0].children[0].id == childID,
               "upsertStructured must update an indexed nested block in place and revise its ancestors")
        expect(nested.metrics.indexedBlockLookups - metricsBeforeNestedUpsert.indexedBlockLookups == 1 &&
               nested.metrics.blockPathSteps - metricsBeforeNestedUpsert.blockPathSteps == 1 &&
               nested.metrics.reindexedNodes - metricsBeforeNestedUpsert.reindexedNodes == 2,
               "a nested leaf upsert must use one indexed lookup, one path step, and reindex only the old/new leaf")
        try nested.document.validateIdentityInvariants(previous: beforeNestedUpsert)

        let containerID = reducerID("block:inserted-container")
        let completedChild = nested.document.entries[0].blocks[0].children[0]
        let reparented = AgentBlock(
            id: parentID,
            revision: .max,
            kind: .plan,
            payload: .plan(.init(status: .inProgress)),
            children: [AgentBlock(id: containerID, revision: .max, kind: .quote,
                                  payload: .quote, children: [completedChild])]
        )
        let reparentPatch = try nested.apply(.upsertStructured(entryID: nestedEntry, block: reparented))
        expect(reparentPatch.inserted == [containerID] && reparentPatch.moved == [childID] &&
               nested.document.entries[0].blocks[0].children[0].revision == 0 &&
               nested.document.entries[0].blocks[0].children[0].children[0].revision == completedChild.revision,
               "inserted ancestors must normalize only new revisions while preserving moved child identity")

        let beforeDeepUpdate = nested.document
        var deepChild = completedChild
        deepChild.payload = .toolCall(.init(name: "nested", summary: "deep indexed update", status: .completed))
        let deepPatch = try nested.apply(.upsertStructured(entryID: nestedEntry, block: deepChild))
        expect(Set(deepPatch.updated) == Set([nestedEntry, parentID, containerID, childID]) &&
               deepPatch.updated.count == 4,
               "deep existing-block upserts must report every changed ancestor exactly once")
        expect(nested.document.version == beforeDeepUpdate.version + 1,
               "a valid deep upsert must commit exactly once")
        try nested.document.validateIdentityInvariants(previous: beforeDeepUpdate)

        let future = AgentBlock(id: futureID, kind: AgentBlockKind(rawValue: "provider.future-card")!,
                                payload: .opaque(.init(debugLabel: "future", value: .object(["v": .integer(2)]))))
        _ = try nested.apply(.upsertStructured(entryID: nestedEntry, block: future))
        expect(nested.document.entries[0].blocks.last?.id == futureID,
               "opaque future structured blocks must survive reduction")
        let beforeSourceOnly = nested.document
        var sourceOnly = future
        sourceOnly.sourceRange = AgentSourceRange(lowerBound: 4, upperBound: 8)
        let sourcePatch = try nested.apply(.upsertStructured(entryID: nestedEntry, block: sourceOnly))
        expect(sourcePatch.isEmpty &&
               nested.document.entries[0].revision == beforeSourceOnly.entries[0].revision,
               "source-range-only upserts must not claim a visible entry revision")
        try nested.document.validateIdentityInvariants(previous: beforeSourceOnly)

        do {
            _ = try nested.apply(.completeBlock(id: childID, status: .inProgress))
            fail("completed block must reject a backwards status transition")
        } catch let error as AgentDocumentMutationError {
            expect(error == .invalidStatusTransition(blockID: childID, from: .completed, to: .inProgress),
                   "backwards status transition must identify the block and both states")
        }
        do {
            _ = try nested.apply(.completeBlock(id: reducerID("block:unknown"), status: .completed))
            fail("completion of an unknown block must fail")
        } catch let error as AgentDocumentMutationError {
            expect(error == .unknownBlock(blockID: reducerID("block:unknown"), operation: .completeBlock),
                   "unknown completion must remain explicit")
        }

        let paragraphID = reducerID("block:statusless")
        _ = try nested.apply(.upsertStructured(entryID: nestedEntry, block: AgentBlock(
            id: paragraphID, kind: .paragraph, payload: .paragraph([.text("not completable")]))))
        let beforeInvalidCompletion = nested.document
        // Required negative witness: temporarily allowing `.completed` through the
        // reducer's status-bearing-payload guard, then running this checks target,
        // exited 1 with `FAIL: statusless completion must identify the unsupported block`.
        do {
            _ = try nested.apply(.completeBlock(id: paragraphID, status: .completed))
            fail("statusless blocks must reject completion")
        } catch let error as AgentDocumentMutationError {
            expect(error == .statusUnavailable(blockID: paragraphID),
                   "statusless completion must identify the unsupported block")
        }
        expect(nested.document == beforeInvalidCompletion,
               "rejected statusless completion must leave the document atomic")
    } catch { fail("nested reducer checks failed: \(error)") }

    do {
        var removal = AgentDocumentReducer()
        let first = reducerID("entry:remove-first")
        let removedEntry = reducerID("entry:remove-middle")
        let last = reducerID("entry:remove-last")
        let lastRoot = reducerID("block:last-root")
        let lastChild = reducerID("block:last-child")
        for id in [first, removedEntry, last] {
            _ = try removal.apply(.beginEntry(id: id, role: .assistant, provenance: .localNotice(reason: "remove")))
        }
        _ = try removal.apply(.upsertStructured(entryID: last, block: AgentBlock(
            id: lastRoot, kind: .quote, payload: .quote,
            children: [AgentBlock(id: lastChild, kind: .paragraph, payload: .paragraph([.text("child")]))])))
        let removalPatch = try removal.apply(.removeEntry(id: removedEntry))
        expect(removalPatch.moved == [lastChild, lastRoot, last].sorted { $0.rawValue < $1.rawValue },
               "removeEntry must move every surviving entry and descendant whose transcript position shifted")
        expect(removal.document.entries.map(\.id) == [first, last],
               "removeEntry must preserve surviving transcript order")
    } catch { fail("remove-entry patch checks failed: \(error)") }

    do {
        var fast = AgentDocumentReducer()
        let fastEntry = reducerID("entry:performance")
        _ = try fast.apply(.beginEntry(id: fastEntry, role: .assistant, provenance: .localNotice(reason: "budget")))
        for _ in 0..<10_000 { _ = try fast.apply(.appendMarkup(entryID: fastEntry, delta: "x")) }
        expect(fast.document.version == 10_001 && paragraphText(fast.document.entries[0].blocks[0])?.count == 10_000,
               "10,000 streaming mutations must be retained and versioned")

        // Streamed text must land in BOUNDED runs. A single ever-growing run is
        // never uniquely referenced while a snapshot is live, so every chunk
        // copies the whole answer-so-far and one long response costs O(length²)
        // to assemble — the shape that made a long turn degrade while total
        // session length did not matter. Assert the representation that keeps
        // each append constant-cost, and assert it in a way one run would fail:
        // a lone 10,000-byte run trivially exceeds the cap.
        guard case let .paragraph(streamedRuns) = fast.document.entries[0].blocks[0].payload else {
            fail("streaming markup must project as a paragraph")
        }
        let runLengths = streamedRuns.map { run -> Int in
            if case let .text(value) = run { return value.utf8.count }
            return 0
        }
        let cap = AgentDocumentReducer.maximumStreamingRunUTF8Length
        let oversized = runLengths.filter { $0 > cap }
        expect(oversized.isEmpty,
               "no streamed run may exceed \(cap) UTF-8 bytes; found \(oversized.count) oversized run(s) \(oversized.prefix(3))")
        expect(runLengths.count == (10_000 + cap - 1) / cap && runLengths.reduce(0, +) == 10_000,
               "10,000 streamed bytes must split into \((10_000 + cap - 1) / cap) bounded runs preserving every byte; measured \(runLengths.count) run(s) totalling \(runLengths.reduce(0, +))")

        // A provider delta is not guaranteed to be one byte or smaller than the
        // cap. One large, multibyte delta must be split at valid scalar boundaries
        // while preserving its exact source and the same per-run bound.
        var largeDeltaReducer = AgentDocumentReducer()
        let largeDeltaEntry = reducerID("entry:large-stream-delta")
        _ = try largeDeltaReducer.apply(.beginEntry(
            id: largeDeltaEntry,
            role: .assistant,
            provenance: .localNotice(reason: "large delta")
        ))
        let largeDelta = String(repeating: "é", count: cap) + "tail"
        _ = try largeDeltaReducer.apply(.appendMarkup(entryID: largeDeltaEntry, delta: largeDelta))
        guard case let .paragraph(largeDeltaRuns) = largeDeltaReducer.document.entries[0].blocks[0].payload else {
            fail("one large streaming delta must project as a paragraph")
        }
        let largeDeltaRunLengths = largeDeltaRuns.compactMap { run -> Int? in
            if case let .text(value) = run { return value.utf8.count }
            return nil
        }
        expect(largeDeltaRunLengths.allSatisfy { $0 <= cap },
               "one large multibyte provider delta must not create a run above \(cap) UTF-8 bytes; measured \(largeDeltaRunLengths)")
        expect(paragraphText(largeDeltaReducer.document.entries[0].blocks[0]) == largeDelta,
               "splitting a large multibyte delta must preserve its exact source")

        // Populate many siblings, then repeatedly update one existing block.
        // Rebuilding the document-wide index on every upsert makes this witness
        // quadratic and exceed the focused budget.
        for number in 0..<2_000 {
            let id = reducerID("block:perf-\(number)")
            _ = try fast.apply(.upsertStructured(entryID: fastEntry, block: AgentBlock(
                id: id, kind: .notice, payload: .notice(.init(message: [.text("0")])))))
        }
        let hotID = reducerID("block:perf-1999")
        let metricsBeforeHotUpdates = fast.metrics
        for number in 1...4_000 {
            _ = try fast.apply(.upsertStructured(entryID: fastEntry, block: AgentBlock(
                id: hotID, revision: .max, kind: .notice,
                payload: .notice(.init(message: [.text("\(number)")])))))
        }
        let indexedLookups = fast.metrics.indexedBlockLookups - metricsBeforeHotUpdates.indexedBlockLookups
        let pathSteps = fast.metrics.blockPathSteps - metricsBeforeHotUpdates.blockPathSteps
        let reindexedNodes = fast.metrics.reindexedNodes - metricsBeforeHotUpdates.reindexedNodes
        expect(indexedLookups == 4_000 && pathSteps == 0 && reindexedNodes == 8_000,
               "4,000 existing top-level upserts must use 4,000 indexed lookups, 0 path steps, and reindex only 8,000 leaf instances; measured \(indexedLookups)/\(pathSteps)/\(reindexedNodes)")
    } catch { fail("indexed reducer budget failed: \(error)") }

    print("Document reducer checks passed: reconstructible lifecycle, minimal patches, invalid transitions, and indexed 10k workload")
}

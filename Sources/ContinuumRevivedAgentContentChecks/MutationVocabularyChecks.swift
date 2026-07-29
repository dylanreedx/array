import ContinuumRevivedAgentContent
import Foundation

// Ticket: docs/38-tickets/91-agent-tile-ux/P1.3-mutation-patch-vocabulary.md

private func mutationID(_ raw: String) -> AgentNodeID {
    guard let id = AgentNodeID(rawValue: raw) else { fail("invalid mutation fixture ID: \(raw)") }
    return id
}

private func requireMutationSendable<T: Sendable>(_: T.Type) { }

func runMutationVocabularyChecks() {
    requireMutationSendable(AgentDocumentMutation.self)
    requireMutationSendable(AgentDocumentPatch.self)
    requireMutationSendable(AgentDocumentMutationError.self)

    let entryID = mutationID("entry:turn-7")
    let blockA = mutationID("block:a")
    let blockB = mutationID("block:b")
    let blockC = mutationID("block:c")
    let paragraph = AgentBlock(
        id: blockA,
        kind: .paragraph,
        payload: .paragraph([.text("A semantic update")])
    )

    let mutations: [AgentDocumentMutation] = [
        .beginEntry(id: entryID, role: .assistant, provenance: .providerItem(provider: "fixture", itemID: "turn-7")),
        .appendMarkup(entryID: entryID, delta: "streamed **markup**"),
        .upsertStructured(entryID: entryID, block: paragraph),
        .completeBlock(id: blockA, status: .completed),
        .finishEntry(id: entryID),
        .removeEntry(id: entryID),
    ]
    let encoded = try! JSONEncoder().encode(mutations)
    let decoded = try! JSONDecoder().decode([AgentDocumentMutation].self, from: encoded)
    expect(decoded == mutations, "all six mutation forms must survive a typed Codable round trip")

    let operations: [AgentDocumentMutationOperation] = [
        .beginEntry, .appendMarkup, .upsertStructured, .completeBlock, .finishEntry, .removeEntry,
    ]
    expect(Set(operations.map(\.rawValue)).count == 6,
           "every mutation form must have a distinct operation key for explicit errors")

    let explicitErrors: [AgentDocumentMutationError] = [
        .duplicateBegin(entryID: entryID),
        .unknownEntry(entryID: entryID, operation: .appendMarkup),
        .unknownBlock(blockID: blockA, operation: .completeBlock),
        .duplicateNodeID(id: blockA),
        .invalidStatusTransition(blockID: blockA, from: .completed, to: .inProgress),
        .documentVersionOverflow(current: .max),
        .nodeRevisionOverflow(id: blockA, current: .max),
    ]
    expect(Set(explicitErrors.map(String.init(describing:))).count == explicitErrors.count,
           "invalid references, duplicate begins/IDs, transitions, and overflows must remain explicit errors")

    do {
        let patch = try AgentDocumentPatch(
            fromVersion: 40,
            toVersion: 41,
            inserted: [blockA],
            updated: [blockC, blockB],
            moved: [blockC]
        )
        expect(patch.inserted == [blockA] && patch.updated == [blockB, blockC] && patch.moved == [blockC],
               "patch IDs must be deterministically sorted while allowing a moved node to update")
        expect(!patch.isEmpty, "a patch with stable-ID changes must not report empty")
    } catch {
        fail("a valid deterministic patch unexpectedly failed: \(error)")
    }

    do {
        let empty = try AgentDocumentPatch.empty(fromVersion: 9)
        expect(empty.fromVersion == 9 && empty.toVersion == 10 && empty.isEmpty,
               "a successful semantic no-op must advance document version exactly once with no node changes")
    } catch {
        fail("a valid empty patch unexpectedly failed: \(error)")
    }

    for (from, to) in [(UInt64(5), UInt64(5)), (5, 7), (.max, .max)] {
        do {
            _ = try AgentDocumentPatch(fromVersion: from, toVersion: to)
            fail("patch version \(from)→\(to) must fail because it does not advance exactly once")
        } catch let error as AgentDocumentPatch.ValidationError {
            guard case .versionDidNotAdvanceExactlyOnce = error else {
                fail("invalid patch version returned the wrong error: \(error)")
            }
        } catch { fail("invalid patch version returned an unexpected error: \(error)") }
    }

    do {
        _ = try AgentDocumentPatch(fromVersion: 1, toVersion: 2, inserted: [blockA, blockA])
        fail("duplicate stable IDs in one patch section must fail")
    } catch let error as AgentDocumentPatch.ValidationError {
        expect(error == .duplicateID(section: .inserted, id: blockA),
               "duplicate patch IDs must identify their section and stable ID")
    } catch { fail("duplicate patch IDs returned an unexpected error: \(error)") }

    do {
        _ = try AgentDocumentPatch(fromVersion: 1, toVersion: 2, inserted: [blockA], removed: [blockA])
        fail("contradictory structural patch changes must fail")
    } catch let error as AgentDocumentPatch.ValidationError {
        expect(error == .contradictoryStructuralChange(id: blockA, first: .inserted, second: .removed),
               "contradictory patch changes must identify both sections deterministically")
    } catch { fail("contradictory patch changes returned an unexpected error: \(error)") }

    do {
        _ = try AgentDocumentPatch.empty(fromVersion: .max)
        fail("an empty patch must fail rather than wrap the document version")
    } catch let error as AgentDocumentPatch.ValidationError {
        guard case .versionDidNotAdvanceExactlyOnce = error else {
            fail("empty-patch overflow returned the wrong error: \(error)")
        }
    } catch { fail("empty-patch overflow returned an unexpected error: \(error)") }

    print("Mutation vocabulary checks passed: 6 mutations, 7 explicit errors, deterministic stable-ID patches")
}

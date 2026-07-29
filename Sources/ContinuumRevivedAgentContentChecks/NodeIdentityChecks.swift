import ContinuumRevivedAgentContent
import Foundation

// Ticket: docs/38-tickets/91-agent-tile-ux/P1.2-stable-node-identity.md

private func identityID(_ raw: String) -> AgentNodeID {
    guard let id = AgentNodeID(rawValue: raw) else { fail("invalid identity fixture: \(raw)") }
    return id
}

func runNodeIdentityChecks() {
    let entryID = identityID("entry:provider-item-7")
    guard let keyed = entryID.childID(stableKey: "paragraph:first") else { fail("stable child key must allocate") }
    expect(keyed == entryID.childID(stableKey: "paragraph:first"), "the same stable child key must reuse its ID")
    expect(keyed != entryID.childID(stableKey: "paragraph:second"), "distinct stable child keys must not collide")
    let nestedScope = entryID.childID(stableKey: "x")!
    expect(entryID.childID(stableKey: "x/child-key:y") != nestedScope.childID(stableKey: "y"),
           "child-key encoding must keep nested scopes collision-free")
    expect(entryID.childID(stableKey: "") == nil && entryID.childID(stableKey: "bad\nkey") == nil,
           "empty and control-containing stable keys must fail closed")

    var allocator = AgentNodeID.ChildAllocator(scope: entryID)!
    let first = allocator.id(for: "provider-block-a")
    let second = allocator.id(for: "provider-block-b")
    expect(first != nil && second != nil && first != second, "new stable keys receive distinct child IDs")
    expect(allocator.id(for: "provider-block-a") == first, "inserting another child must not change an existing assigned ordinal")
    expect(allocator.assignedKeys == ["provider-block-a", "provider-block-b"], "allocator exposes only assigned stable keys")
    let persisted = try! JSONEncoder().encode(allocator)
    var restored = try! JSONDecoder().decode(AgentNodeID.ChildAllocator.self, from: persisted)
    expect(restored.id(for: "provider-block-a") == first && restored.id(for: "provider-block-b") == second,
           "persisted reconciliation must preserve existing IDs")
    expect(restored.id(for: "inserted-before-existing") != first && restored.id(for: "inserted-before-existing") != second,
           "a newly inserted child must not renumber persisted children")
    let longScope = AgentNodeID(rawValue: String(repeating: "x", count: AgentNodeID.maxDerivedScopeBytes + 1))!
    expect(longScope.childID(stableKey: "child") == nil && AgentNodeID.ChildAllocator(scope: longScope) == nil,
           "derived child scopes must fail closed before exceeding the ID bound")
    let malformedAllocator = Data("{\"scope\":\"entry:scope\",\"ordinals\":{\"a\":0,\"b\":0},\"nextOrdinal\":1}".utf8)
    do {
        _ = try JSONDecoder().decode(AgentNodeID.ChildAllocator.self, from: malformedAllocator)
        fail("duplicate persisted child ordinals must fail decoding")
    } catch { }

    do {
        let unchangedRevision = try AgentNodeRevision.next(current: 4, visibleContentChanged: false)
        let changedRevision = try AgentNodeRevision.next(current: 4, visibleContentChanged: true)
        expect(unchangedRevision == 4, "non-visible metadata changes must not increment revision")
        expect(changedRevision == 5, "visible semantic changes must increment revision exactly once")
        do {
            _ = try AgentNodeRevision.next(current: UInt64.max, visibleContentChanged: true)
            fail("revision overflow must fail explicitly")
        } catch AgentNodeRevision.Error.overflow { }
    } catch { fail("revision policy unexpectedly failed: \(error)") }

    let blockID = identityID("block:tool")
    let oldBlock = AgentBlock(
        id: blockID,
        revision: 0,
        kind: .toolCall,
        sourceRange: AgentSourceRange(lowerBound: 0, upperBound: 4),
        payload: .toolCall(.init(name: "read", status: .inProgress))
    )
    let newBlock = AgentBlock(
        id: blockID,
        revision: 1,
        kind: .toolCall,
        sourceRange: AgentSourceRange(lowerBound: 0, upperBound: 99),
        payload: .toolCall(.init(name: "read", status: .completed))
    )
    let oldDocument = AgentDocument(entries: [AgentEntry(id: entryID, role: .assistant, provenance: .providerItem(provider: "fixture", itemID: "7"), blocks: [oldBlock])])
    let newDocument = AgentDocument(entries: [AgentEntry(id: entryID, revision: 1, role: .assistant, provenance: .providerItem(provider: "fixture", itemID: "7"), blocks: [newBlock])])
    do {
        try newDocument.validateIdentityInvariants(previous: oldDocument)
    } catch {
        fail("status-only semantic changes should validate as one revision: \(error)")
    }

    let completedBlock = AgentBlock(id: identityID("block:completed"), revision: 4, kind: .paragraph, payload: .paragraph([.text("Earlier result")]))
    let openOld = AgentBlock(id: identityID("block:open"), revision: 0, kind: .paragraph, payload: .paragraph([.text("Streaming")]))
    let openNew = AgentBlock(id: identityID("block:open"), revision: 1, kind: .paragraph, payload: .paragraph([.text("Streaming text appended")]))
    let streamingOld = AgentDocument(entries: [AgentEntry(id: entryID, revision: 5, role: .assistant, provenance: .providerItem(provider: "fixture", itemID: "7"), blocks: [completedBlock, openOld])])
    let streamingNew = AgentDocument(entries: [AgentEntry(id: entryID, revision: 6, role: .assistant, provenance: .providerItem(provider: "fixture", itemID: "7"), blocks: [completedBlock, openNew])])
    do {
        try streamingNew.validateIdentityInvariants(previous: streamingOld)
    } catch { fail("streaming append must preserve completed block identity while revising the open paragraph: \(error)") }
    expect(streamingNew.entries[0].blocks[0].id == streamingOld.entries[0].blocks[0].id && streamingNew.entries[0].blocks[0].revision == streamingOld.entries[0].blocks[0].revision,
           "completed block ID and revision must remain unchanged during an open-block update")
    expect(streamingNew.entries[0].blocks[1].id == streamingOld.entries[0].blocks[1].id && streamingNew.entries[0].blocks[1].revision == streamingOld.entries[0].blocks[1].revision + 1 && streamingNew.entries[0].blocks[1].payload != streamingOld.entries[0].blocks[1].payload,
           "open paragraph append must retain ID, change visible text, and increment revision")

    var duplicate = newDocument
    duplicate.entries[0].blocks.append(newBlock)
    do {
        try duplicate.validateIdentityInvariants()
        fail("duplicate IDs must fail validation")
    } catch let error as AgentDocument.IdentityValidationError {
        guard case let .duplicate(id, firstPath, secondPath) = error else { fail("duplicate IDs returned the wrong error: \(error)") }
        expect(id == blockID && firstPath == "entries[0].blocks[0]" && secondPath == "entries[0].blocks[1]",
               "duplicate error must include both node paths")
    } catch { fail("duplicate IDs returned an unexpected error: \(error)") }

    var malformedPrevious = oldDocument
    malformedPrevious.entries[0].blocks.append(oldBlock)
    do {
        try newDocument.validateIdentityInvariants(previous: malformedPrevious)
        fail("duplicate IDs in a previous snapshot must fail validation")
    } catch let error as AgentDocument.IdentityValidationError {
        guard case .duplicate = error else { fail("malformed previous snapshot returned the wrong error: \(error)") }
    } catch { fail("malformed previous snapshot returned an unexpected error: \(error)") }

    var changedWithoutRevision = newDocument
    changedWithoutRevision.entries[0].blocks[0].revision = 0
    do {
        try changedWithoutRevision.validateIdentityInvariants(previous: oldDocument)
        fail("visible changes without a revision increment must fail validation")
    } catch let error as AgentDocument.IdentityValidationError {
        guard case .changedWithoutRevision = error else { fail("revision witness returned the wrong error: \(error)") }
    } catch { fail("revision witness returned an unexpected error: \(error)") }

    print("AgentNodeID checks passed: stable keys, reconciled ordinals, uniqueness paths, and revision semantics")
}

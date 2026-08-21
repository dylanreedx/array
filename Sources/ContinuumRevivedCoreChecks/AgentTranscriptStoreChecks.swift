import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

func runAgentTranscriptStoreChecks() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("array-transcript-store-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let agentID = AgentID(rawValue: UUID(uuidString: "A2000000-0000-4000-8000-000000000001")!)
    let sessionID = "provider/session with unsafe path separators"
    let store = AgentTranscriptStore(root: root, compactionMutationCount: 3)
    try await store.saveSnapshot(agentID: agentID, sessionID: sessionID, document: AgentDocument())

    let entryID = AgentNodeID(rawValue: "entry.persisted")!
    let blockID = AgentNodeID(rawValue: "block.persisted")!
    _ = try await store.append(
        .beginEntry(id: entryID, role: .assistant, provenance: .localNotice(reason: "store-check")),
        agentID: agentID,
        sessionID: sessionID
    )
    _ = try await store.append(
        .upsertStructured(entryID: entryID, block: AgentBlock(
            id: blockID,
            kind: .paragraph,
            payload: .paragraph([.text("durable transcript")])
        )),
        agentID: agentID,
        sessionID: sessionID
    )
    _ = try await store.append(.finishEntry(id: entryID), agentID: agentID, sessionID: sessionID)

    let restored = try await store.load(agentID: agentID, sessionID: sessionID)
    expect(restored?.entries.count == 1 && restored?.entries.first?.id == entryID,
           "transcript store must restore a compacted semantic entry")
    if case .paragraph([.text("durable transcript")])? = restored?.entries.first?.blocks.first?.payload {
        // Exact portable body recovered.
    } else {
        expect(false, "transcript store lost the semantic body during journal compaction")
    }

    let unexpectedSessionPath = root.appendingPathComponent(agentID.rawValue.uuidString)
        .appendingPathComponent(sessionID)
    expect(!FileManager.default.fileExists(atPath: unexpectedSessionPath.path),
           "provider session IDs must not be used as filesystem paths")

    try await store.remove(agentID: agentID, sessionID: sessionID)
    let removed = try await store.load(agentID: agentID, sessionID: sessionID)
    expect(removed == nil,
           "transcript removal must remove snapshot and journal")
    print("Agent transcript store checks passed: atomic snapshot, journal replay/compaction, safe session path, and removal")
}

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

    try await runAgentTranscriptKeyMigrationChecks()
}

/// C3 — the transcript key is the AGENT's, and existing history moves to it.
///
/// The writer used to be the TILE's thread id (`"managed-<tileId>"`) and the only
/// reader asked for the literal `"thread-main"`, so nothing ever loaded. Worse,
/// revealing an existing agent mints a fresh tile id, so each reveal orphaned the
/// previous directory. Fixing the reader to match the writer would not have been
/// enough: the key itself was unstable.
///
/// Every assertion below drives the production store. Migration MOVES history; it
/// never wipes, and it is idempotent.
func runAgentTranscriptKeyMigrationChecks() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("array-transcript-migrate-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentTranscriptStore(root: root, compactionMutationCount: 3)

    func seed(_ agentID: AgentID, sessionID: String, text: String) async throws {
        let entryID = AgentNodeID(rawValue: "entry.\(text)")!
        try await store.saveSnapshot(agentID: agentID, sessionID: sessionID, document: AgentDocument())
        _ = try await store.append(
            .beginEntry(id: entryID, role: .assistant, provenance: .localNotice(reason: "migration-check")),
            agentID: agentID, sessionID: sessionID)
        _ = try await store.append(
            .upsertStructured(entryID: entryID, block: AgentBlock(
                id: AgentNodeID(rawValue: "block.\(text)")!,
                kind: .paragraph,
                payload: .paragraph([.text(text)])
            )), agentID: agentID, sessionID: sessionID)
        _ = try await store.append(.finishEntry(id: entryID), agentID: agentID, sessionID: sessionID)
    }

    func bodyText(_ document: AgentDocument?) -> String? {
        guard case let .paragraph(spans)? = document?.entries.first?.blocks.first?.payload,
              case let .text(value)? = spans.first else { return nil }
        return value
    }

    // 1. One legacy per-tile directory is ADOPTED, with its journal replayed.
    let solo = AgentID(rawValue: UUID(uuidString: "A3000000-0000-4000-8000-000000000001")!)
    let soloLegacy = "managed-\(UUID().uuidString)"
    try await seed(solo, sessionID: soloLegacy, text: "solo history")
    let canonical = AgentTranscriptStore.canonicalSessionID(for: solo)
    let beforeMigration = try await store.load(agentID: solo, sessionID: canonical)
    expect(beforeMigration == nil,
           "C3 precondition: nothing is stored under the canonical key before migrating")

    // 2. Two legacy directories: the NEWEST conversation wins, the other is
    //    quarantined rather than deleted. A transcript is the user's own record.
    let duplicated = AgentID(rawValue: UUID(uuidString: "A3000000-0000-4000-8000-000000000002")!)
    try await seed(duplicated, sessionID: "managed-\(UUID().uuidString)", text: "older reveal")
    try await Task.sleep(for: .milliseconds(30))
    try await seed(duplicated, sessionID: "managed-\(UUID().uuidString)", text: "newest reveal")

    let report = try await store.migrateLegacySessionDirectories()

    expect(report.adopted.contains(solo) && report.adopted.contains(duplicated),
           "C3: both legacy agents must be adopted under the canonical key")
    let adoptedSolo = try await store.load(agentID: solo, sessionID: canonical)
    expect(bodyText(adoptedSolo) == "solo history",
           "C3: an adopted transcript must load under the canonical key with its body intact")
    let adoptedDuplicated = try await store.load(
        agentID: duplicated,
        sessionID: AgentTranscriptStore.canonicalSessionID(for: duplicated))
    expect(bodyText(adoptedDuplicated) == "newest reveal",
           "C3: the newest legacy transcript wins when a reveal orphaned earlier ones")
    expect(report.quarantined[duplicated] == 1,
           "C3: a losing legacy transcript is quarantined, never deleted")

    let quarantined = (try? FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent(duplicated.rawValue.uuidString).path)) ?? []
    expect(quarantined.contains { $0.hasPrefix("quarantine-") },
           "C3: the quarantined directory must still exist on disk")

    // 3. Idempotent: a second run moves nothing and loses nothing.
    let second = try await store.migrateLegacySessionDirectories()
    expect(second.adopted.isEmpty,
           "C3: migration must be idempotent — a second run adopts nothing")
    expect(second.alreadyCanonical.contains(solo),
           "C3: a migrated agent reports as already canonical on the second run")
    let afterSecondRun = try await store.load(agentID: solo, sessionID: canonical)
    expect(bodyText(afterSecondRun) == "solo history",
           "C3: a second migration run must not disturb an adopted transcript")

    print("Agent transcript key migration checks passed: adoption with journal replay, newest-wins with quarantine, and idempotence")
}

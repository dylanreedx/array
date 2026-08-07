import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore

@MainActor
extension UIProbeGeometry {
    /// Focused host-local disclosure gate. It proves missing/ambiguous identity
    /// fails closed, while an explicitly bound immutable scope renders, and a
    /// store-expired snapshot is evicted before it can be presented again.
    static func runToolDetailChecks() async throws -> Int {
        func id(_ value: String) -> AgentNodeID { AgentNodeID(rawValue: value)! }
        let itemID: AgentToolDetailID = "tool-disclosure-check"
        let turnOne = AgentToolDetailScope(
            agentID: "tool-check-agent", threadID: "tool-check-thread",
            turnID: "turn-one", provider: "runtime"
        )!
        let turnTwo = AgentToolDetailScope(
            agentID: "tool-check-agent", threadID: "tool-check-thread",
            turnID: "turn-two", provider: "runtime"
        )!
        let priorIdentity = AgentToolDetailKey(scope: turnOne, providerItemID: itemID)
        let currentIdentity = AgentToolDetailKey(scope: turnTwo, providerItemID: itemID)
        let blockID = id("tool-disclosure-block")
        let entryID = id("tool-disclosure-entry")
        let block = AgentBlock(
            id: blockID, revision: 1, kind: .toolCall,
            payload: .toolCall(AgentToolCallPayload(
                name: "semantic-tool", summary: "Completed", status: .completed
            ))
        )
        let entry = AgentEntry(
            id: entryID, revision: 1, role: .assistant,
            provenance: .providerItem(provider: "runtime", itemID: itemID.rawValue),
            blocks: [block]
        )
        let document = AgentDocument(version: 1, entries: [entry])
        let record = AgentToolDetailRecord(
            identity: currentIdentity, toolName: "read", status: .completed,
            updatedAt: Date(timeIntervalSinceReferenceDate: 4_000)
        )

        // A prior transcript entry must not inherit a mutable/current turn.
        let priorList = AgentTranscriptListView(toolDetailProvider: { key in
            key == currentIdentity ? record : nil
        })
        priorList.bindToolDetailIdentity(priorIdentity, to: entryID)
        try priorList.apply(
            document: document,
            patch: try AgentDocumentPatch(fromVersion: 0, toVersion: 1, inserted: [blockID])
        )
        guard priorList.qaPresentedToolSummary(for: blockID) == "Completed" else {
            throw GeometryError(message: "cross-turn/current-scope fallback rendered a prior entry with the current detail")
        }

        // A complete immutable binding is the only route that may disclose.
        let boundList = AgentTranscriptListView(toolDetailProvider: { key in
            key == currentIdentity ? record : nil
        })
        boundList.bindToolDetailIdentity(currentIdentity, to: entryID)
        try boundList.apply(
            document: document,
            patch: try AgentDocumentPatch(fromVersion: 0, toVersion: 1, inserted: [blockID])
        )
        guard boundList.qaPresentedToolSummary(for: blockID)?.contains("Tool") == true else {
            throw GeometryError(message: "explicit immutable tool identity did not disclose the completed detail")
        }

        final class ManualClock: @unchecked Sendable {
            var value: Date
            init(_ value: Date) { self.value = value }
            func now() -> Date { value }
            func advance(_ seconds: TimeInterval) { value = value.addingTimeInterval(seconds) }
        }
        let clock = ManualClock(Date(timeIntervalSinceReferenceDate: 5_000))
        let store = AgentToolDetailStore(clock: clock.now, timeToLive: 10)
        let expiringRecord = AgentToolDetailRecord(
            identity: currentIdentity, toolName: "read", status: .completed,
            updatedAt: clock.now()
        )
        // Store the sanitized record through its normal capture boundary.
        _ = await store.recordStart(AgentToolDetailStart(
            identity: currentIdentity, toolName: expiringRecord.toolName
        ))
        _ = await store.recordEnd(AgentToolDetailEnd(
            identity: currentIdentity, status: .completed
        ))
        let expiringList = AgentTranscriptListView(toolDetailStore: store)
        expiringList.bindToolDetailIdentity(currentIdentity, to: entryID)
        try expiringList.apply(
            document: document,
            patch: try AgentDocumentPatch(fromVersion: 0, toVersion: 1, inserted: [blockID])
        )
        await expiringList.qaWaitForToolDetailRefresh()
        guard expiringList.qaPresentedToolSummary(for: blockID)?.contains("Tool") == true else {
            throw GeometryError(message: "fresh store detail was not presentable before expiry")
        }
        clock.advance(11)
        _ = await store.expireNow()
        guard expiringList.qaPresentedToolSummary(for: blockID) == "Completed" else {
            throw GeometryError(message: "expired list-level tool snapshot remained presentable")
        }

        // Hostile witness: an explicitly TTL-bound provider has no actor store,
        // but must still use the injected clock and refresh the rendered snapshot.
        let noStoreRecord = AgentToolDetailRecord(
            identity: currentIdentity, toolName: "read", status: .completed,
            updatedAt: clock.now()
        )
        let noStoreExpiringList = AgentTranscriptListView(
            toolDetailProvider: { key in key == currentIdentity ? noStoreRecord : nil },
            toolDetailClock: clock.now,
            toolDetailTimeToLive: 10
        )
        noStoreExpiringList.bindToolDetailIdentity(currentIdentity, to: entryID)
        try noStoreExpiringList.apply(
            document: document,
            patch: try AgentDocumentPatch(fromVersion: 0, toVersion: 1, inserted: [blockID])
        )
        guard noStoreExpiringList.qaPresentedToolSummary(for: blockID)?.contains("Tool") == true else {
            throw GeometryError(message: "fresh no-store TTL-bound provider detail was not presentable")
        }
        clock.advance(11)
        noStoreExpiringList.refreshToolDetailPresentation()
        guard noStoreExpiringList.qaPresentedToolSummary(for: blockID) == "Completed" else {
            throw GeometryError(message: "no-store TTL-bound provider detail ignored injected-clock expiry/refresh")
        }

        // Hostile witness: an entry binding is lifecycle immutable. A conflicting
        // rebind must not alter the identity used by a refreshed rendered snapshot.
        let firstRecord = AgentToolDetailRecord(
            identity: priorIdentity, toolName: "first-tool", status: .completed,
            updatedAt: clock.now()
        )
        let secondRecord = AgentToolDetailRecord(
            identity: currentIdentity, toolName: "second-tool", status: .completed,
            updatedAt: clock.now()
        )
        let immutableList = AgentTranscriptListView(toolDetailProvider: { key in
            switch key {
            case priorIdentity: return firstRecord
            case currentIdentity: return secondRecord
            default: return nil
            }
        })
        immutableList.bindToolDetailIdentity(priorIdentity, to: entryID)
        try immutableList.apply(
            document: document,
            patch: try AgentDocumentPatch(fromVersion: 0, toVersion: 1, inserted: [blockID])
        )
        guard immutableList.qaPresentedToolSummary(for: blockID)?.contains("first-tool") == true else {
            throw GeometryError(message: "initial immutable host-local identity did not render")
        }
        guard !immutableList.bindToolDetailIdentity(currentIdentity, to: entryID) else {
            throw GeometryError(message: "conflicting host-local rebind was not rejected")
        }
        immutableList.refreshToolDetailPresentation()
        guard immutableList.qaPresentedToolSummary(for: blockID)?.contains("first-tool") == true else {
            throw GeometryError(message: "conflicting host-local rebind retroactively changed rendered identity")
        }

        // Hostile witness: removal/reset must purge the old binding and its
        // disclosure/expiry state before the same entry ID is reused.
        let reusedIdentity = currentIdentity
        let reusedBlockID = id("tool-disclosure-reused-block")
        let reusedEntry = AgentEntry(
            id: entryID, revision: 3, role: .assistant,
            provenance: .providerItem(provider: "runtime", itemID: reusedIdentity.providerItemID.rawValue),
            blocks: [AgentBlock(
                id: reusedBlockID, revision: 1, kind: .toolCall,
                payload: .toolCall(AgentToolCallPayload(name: "semantic-tool", summary: "Completed", status: .completed))
            )]
        )
        let resetList = AgentTranscriptListView(toolDetailProvider: { key in
            switch key {
            case priorIdentity: return firstRecord
            case currentIdentity: return secondRecord
            default: return nil
            }
        })
        resetList.bindToolDetailIdentity(priorIdentity, to: entryID)
        try resetList.apply(
            document: document,
            patch: try AgentDocumentPatch(fromVersion: 0, toVersion: 1, inserted: [blockID])
        )
        let replacementEntry = AgentEntry(
            id: entryID, revision: 2, role: .assistant,
            provenance: entry.provenance, blocks: [block]
        )
        try resetList.apply(
            document: AgentDocument(version: 2, entries: [replacementEntry]),
            patch: try AgentDocumentPatch(fromVersion: 1, toVersion: 2, updated: [entryID, blockID])
        )
        guard resetList.qaPresentedToolSummary(for: blockID) == "Completed" else {
            throw GeometryError(message: "same-ID entry replacement inherited old host-local identity/cache state")
        }
        try resetList.apply(
            document: AgentDocument(version: 3, entries: []),
            patch: try AgentDocumentPatch(fromVersion: 2, toVersion: 3, removed: [entryID, blockID])
        )
        try resetList.apply(
            document: AgentDocument(version: 4, entries: [reusedEntry]),
            patch: try AgentDocumentPatch(fromVersion: 3, toVersion: 4, inserted: [reusedEntry.id, reusedBlockID])
        )
        guard resetList.qaPresentedToolSummary(for: reusedBlockID) == "Completed" else {
            throw GeometryError(message: "reused entry ID inherited removed host-local identity/cache state")
        }
        return 8
    }
}

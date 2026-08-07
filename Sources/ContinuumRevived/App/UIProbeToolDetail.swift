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
        return 3
    }
}

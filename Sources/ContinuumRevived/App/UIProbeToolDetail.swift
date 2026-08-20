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
        guard boundList.qaPresentedToolSummary(for: blockID)?.contains("Read file") == true else {
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
            identity: currentIdentity, toolName: expiringRecord.toolName,
            affectedFiles: [URL(fileURLWithPath: "/Users/private/project/Sources/Agent.swift")]
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
        guard let storedDisclosure = expiringList.qaPresentedToolSummary(for: blockID),
              storedDisclosure.contains("Read Agent.swift"),
              storedDisclosure.contains("Read: …/Sources/Agent.swift"),
              !storedDisclosure.contains("/Users/private") else {
            throw GeometryError(message: "fresh store detail did not disclose its abbreviated affected file before expiry")
        }

        // File changes use the Changes renderer rather than ToolCallRenderer,
        // but must receive the same host-local target without mutating/syncing
        // the semantic diff payload.
        let writeBlockID = id("write-disclosure-block")
        let writeEntryID = id("write-disclosure-entry")
        let writeItemID: AgentToolDetailID = "write-disclosure-check"
        let writeIdentity = AgentToolDetailKey(scope: turnTwo, providerItemID: writeItemID)
        let writeBlock = AgentBlock(
            id: writeBlockID, revision: 1, kind: .diff,
            payload: .diff(AgentDiffPayload(text: "write", summary: "write"))
        )
        let writeEntry = AgentEntry(
            id: writeEntryID, revision: 1, role: .assistant,
            provenance: .providerItem(provider: "runtime", itemID: writeItemID.rawValue),
            blocks: [writeBlock]
        )
        _ = await store.recordStart(AgentToolDetailStart(
            identity: writeIdentity, toolName: "write",
            affectedFiles: [URL(fileURLWithPath: "/Users/private/project/Sources/Written.swift")]
        ))
        _ = await store.recordEnd(AgentToolDetailEnd(identity: writeIdentity, status: .completed))
        let writeList = AgentTranscriptListView(toolDetailStore: store)
        writeList.bindToolDetailIdentity(writeIdentity, to: writeEntryID)
        try writeList.apply(
            document: AgentDocument(version: 1, entries: [writeEntry]),
            patch: try AgentDocumentPatch(fromVersion: 0, toVersion: 1, inserted: [writeBlockID])
        )
        await writeList.qaWaitForToolDetailRefresh()
        guard writeList.qaPresentedDiffFiles(for: writeBlockID)?.map(\.displayName)
                == ["…/Sources/Written.swift"],
              case let .diff(semanticWritePayload) = writeBlock.payload,
              semanticWritePayload.files.isEmpty else {
            throw GeometryError(message: "file-change card did not compose one abbreviated host-local write target")
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
        guard noStoreExpiringList.qaPresentedToolSummary(for: blockID)?.contains("Read file") == true else {
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
        let resetReplacementBlockID = id("tool-disclosure-reset-replacement-block")
        let replacementBlock = AgentBlock(
            id: resetReplacementBlockID, revision: 1, kind: .toolCall,
            payload: .toolCall(AgentToolCallPayload(
                name: "semantic-tool", summary: "Completed", status: .completed
            ))
        )
        let replacementEntry = AgentEntry(
            id: entryID, revision: 2, role: .assistant,
            provenance: entry.provenance, blocks: [replacementBlock]
        )
        try resetList.apply(
            document: AgentDocument(version: 2, entries: [replacementEntry]),
            patch: try AgentDocumentPatch(
                fromVersion: 1, toVersion: 2,
                updated: [entryID, blockID, resetReplacementBlockID]
            )
        )
        guard resetList.qaPresentedToolSummary(for: resetReplacementBlockID) == "Completed" else {
            throw GeometryError(message: "different-block entry replacement inherited old host-local identity/cache state")
        }
        try resetList.apply(
            document: AgentDocument(version: 3, entries: []),
            patch: try AgentDocumentPatch(fromVersion: 2, toVersion: 3, removed: [entryID, resetReplacementBlockID])
        )
        try resetList.apply(
            document: AgentDocument(version: 4, entries: [reusedEntry]),
            patch: try AgentDocumentPatch(fromVersion: 3, toVersion: 4, inserted: [reusedEntry.id, reusedBlockID])
        )
        guard resetList.qaPresentedToolSummary(for: reusedBlockID) == "Completed" else {
            throw GeometryError(message: "reused entry ID inherited removed host-local identity/cache state")
        }

        // Hostile witness: an ordinary assistant tool has persistent disclosure
        // state even without provider identity/cache. Replacement and removal
        // must clear that subtree before its entry/block IDs are reused.
        let ordinaryEntryID = id("ordinary-tool-entry")
        let ordinaryBlockID = id("ordinary-tool-block")
        let ordinaryReplacementBlockID = id("ordinary-tool-replacement-block")
        func ordinaryBlock(
            _ blockID: AgentNodeID,
            revision: UInt64,
            summary: String,
            status: AgentItemStatus
        ) -> AgentBlock {
            AgentBlock(
                id: blockID, revision: revision, kind: .toolCall,
                payload: .toolCall(AgentToolCallPayload(
                    name: "ordinary-tool", summary: summary, status: status
                ))
            )
        }
        func ordinaryEntry(_ revision: UInt64, blocks: [AgentBlock]) -> AgentEntry {
            AgentEntry(
                id: ordinaryEntryID, revision: revision, role: .assistant,
                provenance: .localNotice(reason: "ordinary assistant tool"), blocks: blocks
            )
        }
        let ordinaryList = AgentTranscriptListView()
        let ordinaryInitial = ordinaryEntry(
            1,
            blocks: [ordinaryBlock(ordinaryBlockID, revision: 1, summary: "Working", status: .inProgress)]
        )
        try ordinaryList.apply(
            document: AgentDocument(version: 1, entries: [ordinaryInitial]),
            patch: try AgentDocumentPatch(fromVersion: 0, toVersion: 1, inserted: [ordinaryBlockID])
        )
        ordinaryList.qaSetDisclosureState(for: ordinaryBlockID, expanded: true)
        guard ordinaryList.qaDisclosureState(for: ordinaryBlockID) == true else {
            throw GeometryError(message: "ordinary tool disclosure fixture did not establish persistent expanded state")
        }
        // RED witness: the ordinary tool keeps its entry and block IDs while
        // status/summary/revision change from active to completed. The explicit
        // user choice must survive this content-only update.
        let ordinaryCompleted = ordinaryEntry(
            2,
            blocks: [ordinaryBlock(ordinaryBlockID, revision: 2, summary: "Completed in 2s", status: .completed)]
        )
        try ordinaryList.apply(
            document: AgentDocument(version: 2, entries: [ordinaryCompleted]),
            patch: try AgentDocumentPatch(
                fromVersion: 1, toVersion: 2,
                updated: [ordinaryEntryID, ordinaryBlockID]
            )
        )
        guard ordinaryList.qaDisclosureState(for: ordinaryBlockID) == true else {
            throw GeometryError(message: "same-ID ordinary tool content update discarded explicit disclosure state")
        }
        let ordinaryReplacement = ordinaryEntry(
            3,
            blocks: [ordinaryBlock(ordinaryReplacementBlockID, revision: 3, summary: "Completed", status: .completed)]
        )
        try ordinaryList.apply(
            document: AgentDocument(version: 3, entries: [ordinaryReplacement]),
            patch: try AgentDocumentPatch(
                fromVersion: 2, toVersion: 3,
                updated: [ordinaryEntryID, ordinaryBlockID, ordinaryReplacementBlockID]
            )
        )
        guard ordinaryList.qaDisclosureState(for: ordinaryBlockID) == nil,
              ordinaryList.qaDisclosureState(for: ordinaryEntryID) == nil else {
            throw GeometryError(message: "ordinary tool replacement retained disclosure state without provider detail")
        }
        try ordinaryList.apply(
            document: AgentDocument(version: 4, entries: []),
            patch: try AgentDocumentPatch(fromVersion: 3, toVersion: 4, removed: [ordinaryEntryID, ordinaryReplacementBlockID])
        )
        let ordinaryReused = ordinaryEntry(
            4,
            blocks: [ordinaryBlock(ordinaryBlockID, revision: 4, summary: "Completed", status: .completed)]
        )
        try ordinaryList.apply(
            document: AgentDocument(version: 5, entries: [ordinaryReused]),
            patch: try AgentDocumentPatch(fromVersion: 4, toVersion: 5, inserted: [ordinaryEntryID, ordinaryBlockID])
        )
        guard ordinaryList.qaDisclosureState(for: ordinaryBlockID) == nil,
              ordinaryList.qaDisclosureState(for: ordinaryEntryID) == nil else {
            throw GeometryError(message: "reused ordinary tool entry/block IDs inherited disclosure state")
        }

        // Mixed-entry replacement witness: a stable non-tool sibling must not
        // make a removed tool look like a selective child update. The
        // host-local immutable identity and provider record are populated before
        // the replacement so the new block has something real to leak if the
        // owning entry is not purged.
        let mixedEntryID = id("mixed-tool-entry")
        let mixedParagraphID = id("mixed-stable-paragraph")
        let mixedOldToolID = id("mixed-old-tool")
        let mixedNewToolID = id("mixed-new-tool")
        let mixedItemID: AgentToolDetailID = "mixed-provider-item"
        let mixedClock = ManualClock(Date(timeIntervalSinceReferenceDate: 6_000))
        let mixedScope = AgentToolDetailScope(
            agentID: "mixed-agent", threadID: "mixed-thread",
            turnID: "mixed-turn", provider: "runtime"
        )!
        let mixedIdentity = AgentToolDetailKey(scope: mixedScope, providerItemID: mixedItemID)
        let mixedRecord = AgentToolDetailRecord(
            identity: mixedIdentity, toolName: "old-provider-tool", status: .completed,
            updatedAt: mixedClock.now()
        )
        let mixedList = AgentTranscriptListView(
            toolDetailProvider: { key in key == mixedIdentity ? mixedRecord : nil },
            toolDetailClock: mixedClock.now,
            toolDetailTimeToLive: 10
        )
        mixedList.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        let mixedHost = NSView(frame: mixedList.frame)
        mixedHost.addSubview(mixedList)
        mixedList.autoresizingMask = [.width, .height]
        mixedList.bindToolDetailIdentity(mixedIdentity, to: mixedEntryID)
        func mixedParagraph(_ revision: UInt64, _ text: String) -> AgentBlock {
            AgentBlock(
                id: mixedParagraphID, revision: revision, kind: .paragraph,
                payload: .paragraph([.text(text)])
            )
        }
        func mixedTool(_ blockID: AgentNodeID, revision: UInt64, name: String, summary: String) -> AgentBlock {
            AgentBlock(
                id: blockID, revision: revision, kind: .toolCall,
                payload: .toolCall(AgentToolCallPayload(
                    name: name, summary: summary, status: .completed
                ))
            )
        }
        func mixedEntry(_ revision: UInt64, blocks: [AgentBlock]) -> AgentEntry {
            AgentEntry(
                id: mixedEntryID, revision: revision, role: .assistant,
                provenance: .providerItem(provider: "runtime", itemID: mixedItemID.rawValue),
                blocks: blocks
            )
        }
        let mixedInitial = mixedEntry(1, blocks: [
            mixedParagraph(1, "stable paragraph"),
            mixedTool(mixedOldToolID, revision: 1, name: "old-semantic-tool", summary: "old-semantic-summary")
        ])
        try mixedList.apply(
            document: AgentDocument(version: 1, entries: [mixedInitial]),
            patch: try AgentDocumentPatch(fromVersion: 0, toVersion: 1, inserted: [mixedEntryID, mixedParagraphID, mixedOldToolID])
        )
        await mixedList.qaWaitForToolDetailRefresh()
        guard mixedList.qaPresentedToolSummary(for: mixedOldToolID)?.contains("old-provider-tool") == true else {
            throw GeometryError(message: "mixed replacement fixture did not establish the old runtime provider detail")
        }
        mixedList.qaSetDisclosureState(for: mixedOldToolID, expanded: true)
        guard mixedList.qaDisclosureState(for: mixedOldToolID) == true else {
            throw GeometryError(message: "mixed replacement fixture did not establish old disclosure state")
        }
        let mixedReplacement = mixedEntry(2, blocks: [
            mixedParagraph(2, "stable paragraph revised"),
            mixedTool(mixedNewToolID, revision: 2, name: "new-semantic-tool", summary: "new-semantic-summary")
        ])
        try mixedList.apply(
            document: AgentDocument(version: 2, entries: [mixedReplacement]),
            patch: try AgentDocumentPatch(
                fromVersion: 1, toVersion: 2,
                updated: [mixedEntryID, mixedParagraphID, mixedOldToolID, mixedNewToolID]
            )
        )
        await mixedList.qaWaitForToolDetailRefresh()
        guard mixedList.qaDisclosureState(for: mixedOldToolID) == nil,
              mixedList.qaDisclosureState(for: mixedNewToolID) == nil,
              mixedList.qaDisclosureState(for: mixedEntryID) == nil,
              mixedList.qaPresentedToolSummary(for: mixedNewToolID) == "new-semantic-summary" else {
            throw GeometryError(message: "mixed tool replacement retained old disclosure, runtime identity, or provider cache")
        }
        mixedHost.layoutSubtreeIfNeeded()
        mixedList.layoutSubtreeIfNeeded()
        let mixedAX = mixedList.qaVisibleAccessibilityText.joined(separator: " ")
        guard mixedAX.contains("new-semantic-tool"), !mixedAX.contains("old-semantic-tool") else {
            throw GeometryError(message: "mixed replacement left the old tool AX label on the replacement host: \(mixedAX)")
        }
        mixedClock.advance(11)
        mixedList.refreshToolDetailPresentation()
        guard mixedList.qaPresentedToolSummary(for: mixedNewToolID) == "new-semantic-summary" else {
            throw GeometryError(message: "mixed replacement allowed an expired old provider record to reach the new tool")
        }

        // Stable sibling update witness: changing the paragraph and the tool's
        // semantic payload while retaining both IDs is not a tool removal. The
        // explicit disclosure and immutable provider identity must survive.
        let stableEntryID = id("stable-sibling-entry")
        let stableParagraphID = id("stable-sibling-paragraph")
        let stableToolID = id("stable-sibling-tool")
        let stableItemID: AgentToolDetailID = "stable-sibling-provider-item"
        let stableScope = AgentToolDetailScope(
            agentID: "stable-sibling-agent", threadID: "stable-sibling-thread",
            turnID: "stable-sibling-turn", provider: "fixture"
        )!
        let stableIdentity = AgentToolDetailKey(scope: stableScope, providerItemID: stableItemID)
        let stableRecord = AgentToolDetailRecord(
            identity: stableIdentity, toolName: "stable-provider-tool", status: .completed,
            updatedAt: mixedClock.now()
        )
        let stableList = AgentTranscriptListView(
            toolDetailProvider: { key in key == stableIdentity ? stableRecord : nil },
            toolDetailClock: mixedClock.now, toolDetailTimeToLive: 60
        )
        func stableEntry(_ revision: UInt64, paragraph: String, summary: String) -> AgentEntry {
            AgentEntry(
                id: stableEntryID, revision: revision, role: .assistant,
                provenance: .providerItem(provider: "fixture", itemID: stableItemID.rawValue),
                blocks: [
                    AgentBlock(
                        id: stableParagraphID, revision: revision, kind: .paragraph,
                        payload: .paragraph([.text(paragraph)])
                    ),
                    AgentBlock(
                        id: stableToolID, revision: revision, kind: .toolCall,
                        payload: .toolCall(AgentToolCallPayload(
                            name: "stable-semantic-tool", summary: summary, status: .completed
                        ))
                    )
                ]
            )
        }
        stableList.bindToolDetailIdentity(stableIdentity, to: stableEntryID)
        let stableInitial = stableEntry(1, paragraph: "stable one", summary: "stable summary one")
        try stableList.apply(
            document: AgentDocument(version: 1, entries: [stableInitial]),
            patch: try AgentDocumentPatch(fromVersion: 0, toVersion: 1, inserted: [stableEntryID, stableParagraphID, stableToolID])
        )
        guard stableList.qaPresentedToolSummary(for: stableToolID)?.contains("stable-provider-tool") == true else {
            throw GeometryError(message: "stable sibling fixture did not establish immutable provider identity")
        }
        stableList.qaSetDisclosureState(for: stableToolID, expanded: true)
        let stableUpdated = stableEntry(2, paragraph: "stable two", summary: "stable summary two")
        try stableList.apply(
            document: AgentDocument(version: 2, entries: [stableUpdated]),
            patch: try AgentDocumentPatch(
                fromVersion: 1, toVersion: 2,
                updated: [stableEntryID, stableParagraphID, stableToolID]
            )
        )
        guard stableList.qaDisclosureState(for: stableToolID) == true,
              stableList.qaPresentedToolSummary(for: stableToolID)?.contains("stable-provider-tool") == true else {
            throw GeometryError(message: "same-ID sibling update discarded disclosure or immutable provider identity")
        }
        return 18
    }
}

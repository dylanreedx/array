import Foundation

/// The complete content-level write vocabulary for an agent document.
///
/// Mutations describe semantic intent only. Parsing, provider execution, view
/// state, scrolling, selection, and focus belong to other layers.
public enum AgentDocumentMutation: Codable, Equatable, Sendable {
    case beginEntry(
        id: AgentNodeID,
        role: AgentEntryRole,
        provenance: AgentProvenance
    )
    case appendMarkup(entryID: AgentNodeID, delta: String)
    case upsertStructured(entryID: AgentNodeID, block: AgentBlock)
    case completeBlock(id: AgentNodeID, status: AgentItemStatus)
    case finishEntry(id: AgentNodeID)
    case removeEntry(id: AgentNodeID)
}

/// Identifies the operation that produced an invalid reference without
/// retaining provider data or introducing a rendering concern.
public enum AgentDocumentMutationOperation: String, Codable, Equatable, Sendable {
    case beginEntry
    case appendMarkup
    case upsertStructured
    case completeBlock
    case finishEntry
    case removeEntry
}

/// Errors reducers must use for invalid mutation references and transitions.
/// Invalid input is never represented by a successful empty patch.
public enum AgentDocumentMutationError: Error, Equatable, Sendable {
    case duplicateBegin(entryID: AgentNodeID)
    case unknownEntry(entryID: AgentNodeID, operation: AgentDocumentMutationOperation)
    case unknownBlock(blockID: AgentNodeID, operation: AgentDocumentMutationOperation)
    case duplicateNodeID(id: AgentNodeID)
    case entryFinished(entryID: AgentNodeID, operation: AgentDocumentMutationOperation)
    case duplicateFinish(entryID: AgentNodeID)
    case statusUnavailable(blockID: AgentNodeID)
    case invalidStatusTransition(blockID: AgentNodeID, from: AgentItemStatus, to: AgentItemStatus)
    case documentVersionOverflow(current: UInt64)
    case nodeRevisionOverflow(id: AgentNodeID, current: UInt64)
}

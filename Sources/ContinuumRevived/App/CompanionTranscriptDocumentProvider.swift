import ContinuumRevivedCore
import ContinuumRevivedSync
import Foundation

/// The canonical transcript source used by the desktop companion service.
enum CompanionTranscriptDocumentProvider {
    static func make(store: AgentTranscriptStore) -> DesktopCompanionSyncService.TranscriptDocumentProvider {
        { rawAgentID in
            let agentID = AgentID(rawValue: rawAgentID)
            let sessionID = AgentTranscriptStore.canonicalSessionID(for: agentID)
            guard let document = try? await store.load(agentID: agentID, sessionID: sessionID) else { return nil }
            return (sessionID: sessionID, document: document)
        }
    }
}

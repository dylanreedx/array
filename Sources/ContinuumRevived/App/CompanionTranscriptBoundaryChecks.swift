import ContinuumRevivedCore
import Foundation

/// Exercise the same document provider closure the companion service receives.
/// Service construction and transport wiring are outside this check's scope.
@MainActor
enum CompanionTranscriptBoundaryChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    static func verify(
        store: AgentTranscriptStore,
        agentID: AgentID,
        expected: [String],
        excluded: [String]
    ) async throws {
        let provider = CompanionTranscriptDocumentProvider.make(store: store)
        guard await provider(UUID()) == nil else {
            throw Failure(description: "companion provider returned a document for an unknown agent")
        }
        guard let result = await provider(agentID.rawValue),
              result.sessionID == AgentTranscriptStore.canonicalSessionID(for: agentID) else {
            throw Failure(description: "companion provider did not return the agent's canonical archive")
        }
        let text = result.document.entries.map { AgentTranscriptCopyController.plainText(for: $0.blocks) }
            .joined(separator: "\n")
        for marker in expected {
            let count = text.components(separatedBy: marker).count - 1
            guard count == 1 else {
                throw Failure(description: "companion provider returned marker \(marker) \(count) times")
            }
        }
        for marker in excluded where text.contains(marker) {
            throw Failure(description: "companion provider exposed local-only marker \(marker)")
        }
    }
}

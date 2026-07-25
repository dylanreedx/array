import ContinuumRevivedAgentUI
import Foundation
import ContinuumRevivedCore

@MainActor
protocol AgentTileTextEndpoint: AnyObject {
    var readVisibleText: String { get }
    @discardableResult func sendInsertedText(_ text: String) -> Bool
    func sendReturn()
}

enum AgentTileInputError: Error, Equatable, CustomStringConvertible {
    case notAnAgent
    case busy(status: AgentStatus)
    case insertionFailed

    var description: String {
        switch self {
        case .notAnAgent:
            return "target session is not an agent"
        case let .busy(status):
            return "refusing to send prompt to agent with status \(status.rawValue)"
        case .insertionFailed:
            return "terminal rejected inserted text"
        }
    }
}

enum AgentTileInput {
    static func canSend(to status: AgentStatus) -> Bool {
        status == .idle || status == .needsAttention
    }

    @MainActor
    @discardableResult
    static func send(
        prompt: String,
        descriptor: AgentDescriptor?,
        to endpoint: AgentTileTextEndpoint
    ) throws -> String {
        guard let descriptor else { throw AgentTileInputError.notAnAgent }
        guard canSend(to: descriptor.status) else { throw AgentTileInputError.busy(status: descriptor.status) }
        guard endpoint.sendInsertedText(prompt) else { throw AgentTileInputError.insertionFailed }
        endpoint.sendReturn()
        return endpoint.readVisibleText
    }
}

import Combine
import ContinuumRevivedAgentUI
import Foundation

/// Decision F seam: the app-level agent-to-agent message bus. No real
/// implementation exists yet; `NullAgentMessageBus` is the only live wiring.
/// See docs/38-tickets/74-agent-message-bus-seam.md.
public struct AgentBusMessage: Codable, Equatable, Sendable {
    public let senderTileId: UUID
    /// Lamport clock value, not wall-clock time.
    public let logicalTime: UInt64
    public let payload: AgentBusPayload

    public init(senderTileId: UUID, logicalTime: UInt64, payload: AgentBusPayload) {
        self.senderTileId = senderTileId
        self.logicalTime = logicalTime
        self.payload = payload
    }
}

public enum AgentBusPayload: Codable, Equatable, Sendable {
    case attentionChanged(tileId: UUID, status: AgentStatus)
    case progressNote(text: String)
    case delegateTask(description: String, replyTo: UUID)
}

public protocol AgentMessageBus: AnyObject {
    /// Post a message to all current subscribers. Returns immediately.
    func post(_ message: AgentBusMessage)

    /// Subscribe to messages. The handler is called on an unspecified queue;
    /// callers must dispatch if they need a specific context.
    @discardableResult
    func subscribe(handler: @escaping (AgentBusMessage) -> Void) -> AnyCancellable
}

public final class NullAgentMessageBus: AgentMessageBus {
    public init() {}
    public func post(_ message: AgentBusMessage) {}
    public func subscribe(handler: @escaping (AgentBusMessage) -> Void) -> AnyCancellable {
        AnyCancellable {}
    }
}

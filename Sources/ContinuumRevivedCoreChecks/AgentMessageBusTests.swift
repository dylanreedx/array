import Combine
import ContinuumRevivedCore
import Foundation

func runAgentMessageBusTests() {
    // 1. Null bus never delivers.
    do {
        let bus = NullAgentMessageBus()
        var callCount = 0
        let token = bus.subscribe { _ in callCount += 1 }
        bus.post(AgentBusMessage(
            senderTileId: UUID(),
            logicalTime: 1,
            payload: .progressNote(text: "hello")
        ))
        expect(callCount == 0, "NullAgentMessageBus must never deliver a posted message to a subscriber")
        _ = token
    }

    // 2. Status engine routes attention from bus.
    do {
        let tileId = UUID()
        var engine = AgentStatusEngine(initialStatus: .idle)
        let attentionMessage = AgentBusMessage(
            senderTileId: tileId,
            logicalTime: 1,
            payload: .attentionChanged(tileId: tileId, status: .needsAttention)
        )
        let returned = engine.ingestBusMessage(attentionMessage)
        expect(returned == .needsAttention, "ingestBusMessage(.attentionChanged) must return .needsAttention")
        expect(engine.status == .needsAttention, "ingestBusMessage(.attentionChanged) must update engine.status")

        let progressMessage = AgentBusMessage(
            senderTileId: tileId,
            logicalTime: 2,
            payload: .progressNote(text: "foo")
        )
        let unchanged = engine.ingestBusMessage(progressMessage)
        expect(unchanged == .needsAttention, "ingestBusMessage(.progressNote) must not change status")
        expect(engine.status == .needsAttention, "ingestBusMessage(.progressNote) must leave engine.status unchanged")

        let delegateMessage = AgentBusMessage(
            senderTileId: tileId,
            logicalTime: 3,
            payload: .delegateTask(description: "do the thing", replyTo: UUID())
        )
        let stillUnchanged = engine.ingestBusMessage(delegateMessage)
        expect(stillUnchanged == .needsAttention, "ingestBusMessage(.delegateTask) must not change status")
        expect(engine.status == .needsAttention, "ingestBusMessage(.delegateTask) must leave engine.status unchanged")
    }

    // 3. A conforming non-null bus posts and delivers to subscribers.
    do {
        final class RecordingAgentMessageBus: AgentMessageBus {
            private var handlers: [(AgentBusMessage) -> Void] = []
            private(set) var received: [AgentBusMessage] = []
            func post(_ message: AgentBusMessage) {
                received.append(message)
                for handler in handlers { handler(message) }
            }
            func subscribe(handler: @escaping (AgentBusMessage) -> Void) -> AnyCancellable {
                handlers.append(handler)
                return AnyCancellable {}
            }
        }

        let bus = RecordingAgentMessageBus()
        var delivered: [AgentBusMessage] = []
        let token = bus.subscribe { delivered.append($0) }
        let message = AgentBusMessage(senderTileId: UUID(), logicalTime: 1, payload: .progressNote(text: "hi"))
        bus.post(message)
        expect(bus.received == [message], "a conforming bus records posted messages")
        expect(delivered == [message], "a conforming bus delivers posted messages to its subscribers")
        _ = token
    }

    // 4. Message round-trips through Codable for all three payload variants.
    do {
        let tileId = UUID()
        let replyTo = UUID()
        let messages: [AgentBusMessage] = [
            AgentBusMessage(senderTileId: tileId, logicalTime: 10, payload: .attentionChanged(tileId: tileId, status: .working)),
            AgentBusMessage(senderTileId: tileId, logicalTime: 11, payload: .progressNote(text: "40% complete")),
            AgentBusMessage(senderTileId: tileId, logicalTime: 12, payload: .delegateTask(description: "subtask", replyTo: replyTo))
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for message in messages {
            let data = try! encoder.encode(message)
            let decoded = try! decoder.decode(AgentBusMessage.self, from: data)
            expect(decoded == message, "AgentBusMessage must Codable round-trip for payload \(message.payload)")
        }
    }

    print("runAgentMessageBusTests passed")
}

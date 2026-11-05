import Foundation

/// App-server 0.165's userMessage.clientId echoes clientUserMessageId.
/// An item/started or item/completed for that exact thread/turn is evidence
/// that the input entered provider history, not that a model sampled it.
/// RPC acknowledgments and text equality are deliberately insufficient.
public struct CodexSteerReceiptTracker: Sendable {
    private struct Binding: Sendable { var thread: String; var turn: String }
    private var pending: [UUID: Binding] = [:]
    public init() {}
    public mutating func register(_ id: UUID, thread: String, turn: String) {
        pending[id] = Binding(thread: thread, turn: turn)
    }
    public mutating func remove(_ id: UUID) { pending[id] = nil }
    public mutating func applied(line: String) -> UUID? {
        guard let data = line.data(using: .utf8),
              let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = frame["method"] as? String, ["item/started", "item/completed"].contains(method),
              let params = frame["params"] as? [String: Any],
              let item = params["item"] as? [String: Any], item["type"] as? String == "userMessage",
              let clientID = item["clientId"] as? String, let id = UUID(uuidString: clientID),
              let binding = pending[id], params["threadId"] as? String == binding.thread,
              params["turnId"] as? String == binding.turn else { return nil }
        pending[id] = nil
        return id
    }
    public mutating func takeUnconfirmed(thread: String? = nil, turn: String? = nil) -> [UUID] {
        let ids = pending.compactMap { id, binding in
            (thread == nil || thread == binding.thread) && (turn == nil || turn == binding.turn) ? id : nil
        }
        for id in ids { pending[id] = nil }
        return ids
    }
}

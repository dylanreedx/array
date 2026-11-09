import Foundation

/// Effects describe host dispatch, not whether a website accepted a business operation.
/// Deduplication is bounded to retrySessionId; a new session/key is never permission
/// to repeat an uncertain submit, click, append-type or evaluation.
public struct BrowserActionResult: Codable, Equatable, Sendable {
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case actionId, retrySessionId, state, effects, retry, freshSnapshotRequired, deliveredCharacters
    }
    public enum State: String, Codable, Sendable { case completed, rejected, takeover, queueExpired = "queue_expired", partial, outcomeUnknown = "outcome_unknown" }
    public enum Effects: String, Codable, Sendable { case none, partial, committed, unknown }
    public enum Retry: String, Codable, Sendable { case none, observeBeforeNewAction = "observe_before_new_action", waitForHandback = "wait_for_handback", sameKeyOnly = "same_key_only" }
    public var actionId: String
    public var retrySessionId: String
    public var state: State
    public var effects: Effects
    public var retry: Retry
    public var freshSnapshotRequired: Bool
    public var deliveredCharacters: Int?
    public init(actionId: String = "", retrySessionId: String = "", state: State, effects: Effects, retry: Retry,
                freshSnapshotRequired: Bool, deliveredCharacters: Int? = nil) {
        self.actionId = actionId; self.retrySessionId = retrySessionId; self.state = state; self.effects = effects
        self.retry = retry; self.freshSnapshotRequired = freshSnapshotRequired; self.deliveredCharacters = deliveredCharacters
    }
}

import Foundation

/// One published agent's delivered usage events, mapped onto ledger
/// observations. Each harness keeps its own counter semantics:
///
/// - Codex reports a cumulative total per provider thread (`input` already
///   contains `cached_input`). A fork's parent (codex `forkedFromId`), or else
///   the agent's previous thread, is the new thread's baseline.
/// - Claude reports one figure per result. The translator's result identity
///   makes a re-reported result count once, and its subagent-inclusive share
///   replaces the main-conversation `usage`. Per-request assistant frames are
///   context occupancy and never reach this type.
/// - Pi reports per message, identified by response id and timestamp.
public struct SharedAreaUsageNormalizer: Sendable {
    public enum Outcome: Sendable {
        case record(SharedAreaUsageLedger.Observation)
        /// The event cannot be attributed to a stable counter; coverage is partial.
        case unattributable
    }
    private let source: String
    private let harness: AgentHarness?
    private let startedAt: Date
    private let freshSession: Bool
    private var currentTurn: String?
    private var freshTurn = false
    private var lastCodexSession: String?

    /// `providerSessionAtStart` is the agent's Codex thread when observation
    /// began: a thread first captured afterwards started here, so its whole
    /// total belongs to the observed period.
    public init(source: String, harness: AgentHarness?, startedAt: Date, providerSessionAtStart: String?) {
        self.source = source; self.harness = harness; self.startedAt = startedAt
        freshSession = providerSessionAtStart == nil
    }

    public mutating func turnStarted(_ turn: String) {
        currentTurn = turn; freshTurn = true
    }

    public mutating func usage(_ value: TokenUsageSnapshot, providerSession: String?, thread: String,
                               latestTurnAt: Date?, receivedAt: Date) -> Outcome? {
        guard value.inputTokens >= 0, value.outputTokens >= 0 else { return nil }
        let counter: String
        let initialToday: Bool
        var inheritsFrom: String?
        switch harness {
        case .some(.codex):
            let session = providerSession ?? thread
            counter = SharedAreaUsageLedger.privateCounter(["codex", session])
            // Codex names a fork's parent directly; otherwise a thread replacing
            // the agent's previous one is taken to have inherited it.
            if let parent = value.accountingForkedFrom, parent != session {
                inheritsFrom = SharedAreaUsageLedger.privateCounter(["codex", parent])
            } else if let previous = lastCodexSession, previous != session {
                inheritsFrom = SharedAreaUsageLedger.privateCounter(["codex", previous])
            }
            lastCodexSession = session
            initialToday = freshSession
        case .some(.claudeCode):
            let identity = value.accountingObservationID
                ?? currentTurn ?? latestTurnAt.map { String($0.timeIntervalSince1970) } ?? "unattributed"
            counter = SharedAreaUsageLedger.privateCounter([source, "claude", identity])
            initialToday = freshTurn
        case .some(.pi):
            guard let message = value.accountingObservationID else { return .unattributable }
            counter = SharedAreaUsageLedger.privateCounter([source, "pi", message])
            initialToday = value.observedAt.map { $0 >= startedAt } ?? freshTurn
        case nil:
            return .unattributable
        }
        let input = value.accountingInputTokens ?? value.inputTokens
        let output = value.accountingOutputTokens ?? value.outputTokens
        guard input >= 0, output >= 0 else { return nil }
        return .record(.init(counter: counter, input: UInt64(input), output: UInt64(output),
            observedAt: value.observedAt ?? receivedAt, initialBelongsToToday: initialToday, inheritsFrom: inheritsFrom))
    }
}

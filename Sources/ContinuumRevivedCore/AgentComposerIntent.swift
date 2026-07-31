import Foundation

/// A request produced by the composer. Intents are provider-neutral values: the
/// tile presents them and an action sink decides whether the current runtime can
/// execute them. In particular, steer and queue are not implemented by replaying
/// or delaying a normal send.
public enum AgentComposerIntent: Equatable, Sendable {
    case send(String)
    case stop
    case steer(String)
    case queue(String)
    case command(String)
}

/// Explicit turn state supplied by the supervisor. This must come from turn
/// lifecycle state, never inferred from process liveness.
public enum AgentTurnExecutionState: Equatable, Sendable {
    case ready
    case working
}

/// Provider-neutral facts about what the bound runtime can execute now.
public struct AgentTurnCapabilities: Equatable, Sendable {
    public var canSend: Bool
    public var canStop: Bool
    public var canSteer: Bool
    public var canQueue: Bool

    public init(
        canSend: Bool = false,
        canStop: Bool = false,
        canSteer: Bool = false,
        canQueue: Bool = false
    ) {
        self.canSend = canSend
        self.canStop = canStop
        self.canSteer = canSteer
        self.canQueue = canQueue
    }

    /// The conservative capability floor for today's send/stop runtime. Future
    /// provider seams must opt into steer or queue explicitly.
    public static func sendStop(canSend: Bool, canStop: Bool) -> Self {
        Self(canSend: canSend, canStop: canStop, canSteer: false, canQueue: false)
    }
}

/// Pure intent selection, deliberately separate from labels, icons and runtime
/// execution. The primary control stops a working turn when that operation is
/// available; draft submission while working uses only an explicit steer/queue
/// capability and otherwise produces no intent.
public struct AgentComposerIntentState: Equatable, Sendable {
    public var executionState: AgentTurnExecutionState
    public var capabilities: AgentTurnCapabilities

    public init(executionState: AgentTurnExecutionState, capabilities: AgentTurnCapabilities) {
        self.executionState = executionState
        self.capabilities = capabilities
    }

    public func primaryIntent(draft: String) -> AgentComposerIntent? {
        switch executionState {
        case .ready:
            let prompt = Self.normalized(draft)
            return capabilities.canSend && !prompt.isEmpty ? .send(prompt) : nil
        case .working:
            return capabilities.canStop ? .stop : nil
        }
    }

    /// Intent for Enter while a turn is already working. Steer has precedence
    /// when both future capabilities are present; queue remains independently
    /// discoverable through `allowedWorkingDraftIntents`.
    public func workingDraftIntent(draft: String) -> AgentComposerIntent? {
        guard executionState == .working else { return nil }
        let prompt = Self.normalized(draft)
        guard !prompt.isEmpty else { return nil }
        if capabilities.canSteer { return .steer(prompt) }
        if capabilities.canQueue { return .queue(prompt) }
        return nil
    }

    public var allowedWorkingDraftIntents: Set<AgentComposerWorkingDraftIntent> {
        guard executionState == .working else { return [] }
        var result: Set<AgentComposerWorkingDraftIntent> = []
        if capabilities.canSteer { result.insert(.steer) }
        if capabilities.canQueue { result.insert(.queue) }
        return result
    }

    private static func normalized(_ draft: String) -> String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum AgentComposerWorkingDraftIntent: Hashable, Sendable {
    case steer
    case queue
}

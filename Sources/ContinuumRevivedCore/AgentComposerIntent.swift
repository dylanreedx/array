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

/// The sink owns execution and reports whether it actually took responsibility
/// for an intent. A composer must not clear its draft before `.accepted`.
@MainActor
public protocol AgentTileActionSink: AnyObject {
    func accept(_ intent: AgentComposerIntent, for agentID: AgentID) async -> IntentAcceptance
}

public enum IntentAcceptance: Equatable, Sendable {
    case accepted
    case refused(IntentRefusal)
}

public enum IntentRefusal: String, Equatable, Sendable {
    case unknownAgent
    case unsupported
    case turnNotReady
    case noTurnInProgress
    case emptyDraft
}

/// Provider response shape compiled at the provider-neutral seam. The current
/// runtime exposes fixed approval decisions only. In particular, an empty choice
/// list is not evidence of freeform or optional-note support.
public enum AgentRequestResponseMode: Equatable, Sendable {
    case fixedChoice([String])
    case freeform
    case optionalNote(choices: [String])
}

/// The explicit unresolved provider request that a needs-action presentation can
/// reveal. Prompt and choices come from runtime records, never assistant prose.
public struct AgentPendingRequest: Equatable, Sendable {
    public var requestID: String
    public var prompt: String
    public var responseMode: AgentRequestResponseMode

    public init(requestID: String, prompt: String, responseMode: AgentRequestResponseMode) {
        self.requestID = requestID
        self.prompt = prompt
        self.responseMode = responseMode
    }
}

/// Explicit turn state supplied by the supervisor. This must come from turn
/// lifecycle state, never inferred from process liveness.
public enum AgentTurnExecutionState: Equatable, Sendable {
    case ready
    case working
}

/// Complete provider-neutral state consumed by the tile presenter and composer.
/// `needsAction` necessarily carries the request the UI must reveal; it cannot be
/// represented by an orphan attention badge.
public enum AgentTileOperationalState: Equatable, Sendable {
    case ready
    case working
    case queued
    case needsAction(AgentPendingRequest)
    case failed(message: String?)
    case restored
}

public struct AgentTileTurnSnapshot: Equatable, Sendable {
    public var state: AgentTileOperationalState
    public var capabilities: AgentTurnCapabilities

    public init(state: AgentTileOperationalState, capabilities: AgentTurnCapabilities) {
        self.state = state
        self.capabilities = capabilities
    }

    public var executionState: AgentTurnExecutionState {
        switch state {
        case .working, .queued, .needsAction:
            return .working
        case .ready, .failed, .restored:
            return .ready
        }
    }
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

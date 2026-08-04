import ContinuumRevivedAgentUI
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
    /// WHICH of the two things this request wants — an approval the adapter is
    /// holding open, or an answer to a question (P3.3).
    ///
    /// EXPLICIT, and never inferred from `responseMode`: a `userInputRequested`
    /// event compiles to `.fixedChoice([])` because the runtime advertises no
    /// freeform capability, and an approval whose adapter offered no decisions
    /// would compile to the same empty list. Sniffing the choice list would
    /// therefore classify a real approval as a question the first time a provider
    /// sent one with no choices. The producing event knows the answer; it says so.
    ///
    /// `PendingRequest` is the desktop row vocabulary's word for this fact
    /// (`ContinuumRevivedAgentUI`), reused rather than redefined so the tile's
    /// request and the row's state cannot disagree about what a hand raised means.
    public var kind: PendingRequest

    public init(
        requestID: String,
        prompt: String,
        responseMode: AgentRequestResponseMode,
        kind: PendingRequest
    ) {
        self.requestID = requestID
        self.prompt = prompt
        self.responseMode = responseMode
        self.kind = kind
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

    /// One word per case, hand-listed because `needsAction` and `failed` carry
    /// associated values and the enum therefore cannot be `CaseIterable` (design
    /// C8). This switch has NO `default`, so a seventh case is a compile error
    /// here as well as in `InboxState.state(forSnapshot:)` — and the check that
    /// counts these names is what catches a case added to this table without being
    /// given a row meaning.
    public var kindName: String {
        switch self {
        case .ready: return "ready"
        case .working: return "working"
        case .queued: return "queued"
        case .needsAction: return "needsAction"
        case .failed: return "failed"
        case .restored: return "restored"
        }
    }
}

public struct AgentTileTurnSnapshot: Equatable, Sendable {
    public var state: AgentTileOperationalState
    public var capabilities: AgentTurnCapabilities
    /// When the turn now in flight actually started, or nil when none is.
    ///
    /// P3.3: this is the ONLY honest anchor for an elapsed reading, and its absence
    /// was the 158-hour bug. With no stamped start the inbox measured from the
    /// oldest event in the ring's trailing working run, and for an agent restored
    /// from disk that run is a synthetic draft stamped `record.lastSeenAt` — the
    /// SPAWN instant. A week-old agent that had just been handed a prompt therefore
    /// read "158h".
    ///
    /// The invariant, held by `AgentSupervisor.updateTurnFacts`: non-nil exactly
    /// while the supervisor's execution fact is `.working`. Stamped on
    /// `.turnStarted`, cleared by every transition that returns execution to
    /// `.ready` (`.turnCompleted`, `.runtimeError`, a session state change). A bare
    /// `Date` is host-neutral, so it is I5-safe to hold beside state that a
    /// presenter reads (§5.2).
    public var turnStartedAt: Date?

    public init(
        state: AgentTileOperationalState,
        capabilities: AgentTurnCapabilities,
        turnStartedAt: Date?
    ) {
        self.state = state
        self.capabilities = capabilities
        self.turnStartedAt = turnStartedAt
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

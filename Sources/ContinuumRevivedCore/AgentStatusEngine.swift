import Foundation

public struct AgentStatusEngine: Equatable, Sendable {
    public enum Signal: Equatable, Sendable {
        case explicit(AgentStatus)
        case terminalTitle(String)
        case outputActivity
        case promptObserved
    }

    public struct Configuration: Equatable, Sendable {
        public var workingHysteresis: TimeInterval
        public var staleTimeout: TimeInterval

        public init(workingHysteresis: TimeInterval = 5, staleTimeout: TimeInterval = 300) {
            self.workingHysteresis = workingHysteresis
            self.staleTimeout = staleTimeout
        }
    }

    public private(set) var status: AgentStatus
    public private(set) var statusUpdatedAt: Date
    private var explicitStatus: AgentStatus?
    private var explicitUpdatedAt: Date?
    private var inferredStatus: AgentStatus?
    private var inferredUpdatedAt: Date?
    private var lastSignalAt: Date
    private let configuration: Configuration

    public init(initialStatus: AgentStatus = .configuring, now: Date = Date(), configuration: Configuration = Configuration()) {
        self.status = initialStatus
        self.statusUpdatedAt = now
        self.lastSignalAt = now
        self.configuration = configuration
    }

    public mutating func ingest(_ signal: Signal, at now: Date = Date()) -> AgentStatus {
        switch signal {
        case .explicit(let explicit):
            lastSignalAt = now
            explicitStatus = explicit
            explicitUpdatedAt = now
        case .terminalTitle(let title):
            if let titleStatus = Self.statusInferred(fromTitle: title) {
                lastSignalAt = now
                inferredStatus = titleStatus
                inferredUpdatedAt = now
            }
        case .outputActivity:
            lastSignalAt = now
            if explicitStatus == nil {
                inferredStatus = .working
                inferredUpdatedAt = now
            }
        case .promptObserved:
            lastSignalAt = now
            if explicitStatus == nil {
                inferredStatus = .idle
                inferredUpdatedAt = now
            }
        }
        recompute(at: now)
        return status
    }

    public mutating func tick(at now: Date = Date()) -> AgentStatus {
        recompute(at: now)
        return status
    }

    private mutating func recompute(at now: Date) {
        let next: AgentStatus
        if let explicitStatus {
            next = explicitStatus
        } else if now.timeIntervalSince(lastSignalAt) >= configuration.staleTimeout {
            next = .stale
        } else if let inferredStatus {
            if status == .working,
               inferredStatus == .idle,
               let inferredUpdatedAt,
               now.timeIntervalSince(inferredUpdatedAt) < configuration.workingHysteresis {
                next = .working
            } else {
                next = inferredStatus
            }
        } else {
            next = status
        }

        if next != status {
            status = next
            statusUpdatedAt = now
        }
    }

    public static func statusInferred(fromTitle title: String) -> AgentStatus? {
        let lowercased = title.lowercased()
        if lowercased.contains("needs attention") || lowercased.contains("waiting for input") || lowercased.contains("needs you") {
            return .needsAttention
        }
        if lowercased.contains("done") || lowercased.contains("complete") || lowercased.contains("completed") {
            return .done
        }
        if lowercased.contains("working") || lowercased.contains("running") || lowercased.contains("thinking") {
            return .working
        }
        if lowercased.contains("idle") || lowercased.contains("ready") {
            return .idle
        }
        return nil
    }
}

public struct StatusSignals: Equatable, Sendable {
    public var agentKind: AgentKind
    public var hasPendingApproval: Bool
    public var hasPendingUserInput: Bool
    public var hookBreadcrumbPresent: Bool
    public var hookBreadcrumbAge: TimeInterval?
    public var isError: Bool
    public var isStarting: Bool
    public var isRunning: Bool
    public var isCompleted: Bool
    public var engineStatus: AgentStatus

    public init(
        agentKind: AgentKind,
        hasPendingApproval: Bool = false,
        hasPendingUserInput: Bool = false,
        hookBreadcrumbPresent: Bool = false,
        hookBreadcrumbAge: TimeInterval? = nil,
        isError: Bool = false,
        isStarting: Bool = false,
        isRunning: Bool = false,
        isCompleted: Bool = false,
        engineStatus: AgentStatus = .idle
    ) {
        self.agentKind = agentKind
        self.hasPendingApproval = hasPendingApproval
        self.hasPendingUserInput = hasPendingUserInput
        self.hookBreadcrumbPresent = hookBreadcrumbPresent
        self.hookBreadcrumbAge = hookBreadcrumbAge
        self.isError = isError
        self.isStarting = isStarting
        self.isRunning = isRunning
        self.isCompleted = isCompleted
        self.engineStatus = engineStatus
    }
}

extension StatusSignals {
    public static let hookFreshnessWindow: TimeInterval = AgentStatusEngine.Configuration().staleTimeout
}

public func deriveAgentStatus(signals: StatusSignals) -> AgentStatus {
    if signals.hasPendingApproval {
        return .needsAttention
    }

    if signals.hasPendingUserInput {
        return .needsAttention
    }

    if signals.agentKind == .claude,
       signals.hookBreadcrumbPresent,
       let age = signals.hookBreadcrumbAge,
       age < StatusSignals.hookFreshnessWindow {
        return .needsAttention
    }

    if signals.isError {
        return .idle
    }

    if signals.isStarting {
        return .configuring
    }

    if signals.isRunning {
        return .working
    }

    if signals.isCompleted {
        return .done
    }

    if signals.engineStatus == .stale {
        return .stale
    }

    return .idle
}

public enum AgentSessionState: String, Codable, Equatable, Sendable {
    case starting
    case ready
    case running
    case waiting
    case stopped
    case error
}

public enum TurnOutcome: String, Codable, Equatable, Sendable {
    case completed
    case failed
    case interrupted
    case cancelled
}

public enum ItemKind: String, Codable, Equatable, Sendable {
    case commandExecution
    case fileChange
    case mcpToolCall
    case webSearch
    case assistantMessage
    case reasoning
    case plan
    case error
}

public enum ItemStatus: String, Codable, Equatable, Sendable {
    case inProgress
    case completed
    case failed
    case declined
}

public enum ApprovalKind: String, Codable, Equatable, Sendable {
    case commandExecutionApproval
    case applyPatchApproval
    case toolUserInput
}

public enum ApprovalDecision: String, Codable, Equatable, Sendable {
    case approve
    case approveForSession
    case decline
}

public enum ContentStreamKind: String, Codable, Equatable, Sendable {
    case assistant
    case reasoning
    case commandOutput
}

public struct UserInputQuestion: Codable, Equatable, Sendable {
    public var key: String
    public var prompt: String

    public init(key: String, prompt: String) {
        self.key = key
        self.prompt = prompt
    }
}

public struct TokenUsageSnapshot: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var totalCostUsd: Double?

    public init(inputTokens: Int, outputTokens: Int, totalCostUsd: Double?) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalCostUsd = totalCostUsd
    }
}

public struct AgentSession: Codable, Equatable, Sendable {
    public var threadId: String
    public var providerSessionId: String?

    public init(threadId: String, providerSessionId: String?) {
        self.threadId = threadId
        self.providerSessionId = providerSessionId
    }
}

public struct AgentSessionStartInput: Codable, Equatable, Sendable {
    public var cwd: String
    public var systemPrompt: String?
    public var env: [String: String]
    public var resumeThreadId: String?

    public init(cwd: String, systemPrompt: String? = nil, env: [String: String] = [:], resumeThreadId: String? = nil) {
        self.cwd = cwd
        self.systemPrompt = systemPrompt
        self.env = env
        self.resumeThreadId = resumeThreadId
    }
}

public struct AgentSendTurnInput: Codable, Equatable, Sendable {
    public var threadId: String
    public var text: String

    public init(threadId: String, text: String) {
        self.threadId = threadId
        self.text = text
    }
}

public struct AgentTurnStartResult: Codable, Equatable, Sendable {
    public var turnId: String

    public init(turnId: String) {
        self.turnId = turnId
    }
}

public struct UserInputAnswers: Codable, Equatable, Sendable {
    public var answers: [String: String]

    public init(answers: [String: String]) {
        self.answers = answers
    }
}

public enum AgentRuntimeEvent: Codable, Equatable, Sendable {
    case sessionStateChanged(AgentSessionState)
    case turnStarted(threadId: String, turnId: String)
    case turnCompleted(threadId: String, turnId: String, outcome: TurnOutcome, errorMessage: String?) // [BODY]
    case itemStarted(threadId: String, itemId: String, kind: ItemKind, title: String?) // [BODY]
    case itemCompleted(threadId: String, itemId: String, kind: ItemKind, status: ItemStatus)
    case contentDelta(threadId: String, turnId: String, streamKind: ContentStreamKind, delta: String) // [BODY]
    case requestOpened(threadId: String, requestId: String, kind: ApprovalKind)
    case requestResolved(threadId: String, requestId: String, decision: String)
    case userInputRequested(threadId: String, requestId: String, questions: [UserInputQuestion])
    case userInputResolved(threadId: String, requestId: String)
    case tokenUsageUpdated(threadId: String, snapshot: TokenUsageSnapshot)
    case runtimeError(threadId: String?, message: String) // [BODY]

    private enum CodingKeys: String, CodingKey {
        case type
        case state
        case threadId
        case turnId
        case outcome
        case errorMessage
        case itemId
        case kind
        case title
        case status
        case streamKind
        case delta
        case requestId
        case decision
        case questions
        case snapshot
        case message
    }

    private enum Discriminator: String, Codable {
        case sessionStateChanged
        case turnStarted
        case turnCompleted
        case itemStarted
        case itemCompleted
        case contentDelta
        case requestOpened
        case requestResolved
        case userInputRequested
        case userInputResolved
        case tokenUsageUpdated
        case runtimeError
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Discriminator.self, forKey: .type) {
        case .sessionStateChanged:
            self = .sessionStateChanged(try container.decode(AgentSessionState.self, forKey: .state))
        case .turnStarted:
            self = .turnStarted(
                threadId: try container.decode(String.self, forKey: .threadId),
                turnId: try container.decode(String.self, forKey: .turnId)
            )
        case .turnCompleted:
            self = .turnCompleted(
                threadId: try container.decode(String.self, forKey: .threadId),
                turnId: try container.decode(String.self, forKey: .turnId),
                outcome: try container.decode(TurnOutcome.self, forKey: .outcome),
                errorMessage: try container.decodeIfPresent(String.self, forKey: .errorMessage)
            )
        case .itemStarted:
            self = .itemStarted(
                threadId: try container.decode(String.self, forKey: .threadId),
                itemId: try container.decode(String.self, forKey: .itemId),
                kind: try container.decode(ItemKind.self, forKey: .kind),
                title: try container.decodeIfPresent(String.self, forKey: .title)
            )
        case .itemCompleted:
            self = .itemCompleted(
                threadId: try container.decode(String.self, forKey: .threadId),
                itemId: try container.decode(String.self, forKey: .itemId),
                kind: try container.decode(ItemKind.self, forKey: .kind),
                status: try container.decode(ItemStatus.self, forKey: .status)
            )
        case .contentDelta:
            self = .contentDelta(
                threadId: try container.decode(String.self, forKey: .threadId),
                turnId: try container.decode(String.self, forKey: .turnId),
                streamKind: try container.decode(ContentStreamKind.self, forKey: .streamKind),
                delta: try container.decode(String.self, forKey: .delta)
            )
        case .requestOpened:
            self = .requestOpened(
                threadId: try container.decode(String.self, forKey: .threadId),
                requestId: try container.decode(String.self, forKey: .requestId),
                kind: try container.decode(ApprovalKind.self, forKey: .kind)
            )
        case .requestResolved:
            self = .requestResolved(
                threadId: try container.decode(String.self, forKey: .threadId),
                requestId: try container.decode(String.self, forKey: .requestId),
                decision: try container.decode(String.self, forKey: .decision)
            )
        case .userInputRequested:
            self = .userInputRequested(
                threadId: try container.decode(String.self, forKey: .threadId),
                requestId: try container.decode(String.self, forKey: .requestId),
                questions: try container.decode([UserInputQuestion].self, forKey: .questions)
            )
        case .userInputResolved:
            self = .userInputResolved(
                threadId: try container.decode(String.self, forKey: .threadId),
                requestId: try container.decode(String.self, forKey: .requestId)
            )
        case .tokenUsageUpdated:
            self = .tokenUsageUpdated(
                threadId: try container.decode(String.self, forKey: .threadId),
                snapshot: try container.decode(TokenUsageSnapshot.self, forKey: .snapshot)
            )
        case .runtimeError:
            self = .runtimeError(
                threadId: try container.decodeIfPresent(String.self, forKey: .threadId),
                message: try container.decode(String.self, forKey: .message)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sessionStateChanged(let state):
            try container.encode(Discriminator.sessionStateChanged, forKey: .type)
            try container.encode(state, forKey: .state)
        case .turnStarted(let threadId, let turnId):
            try container.encode(Discriminator.turnStarted, forKey: .type)
            try container.encode(threadId, forKey: .threadId)
            try container.encode(turnId, forKey: .turnId)
        case .turnCompleted(let threadId, let turnId, let outcome, let errorMessage):
            try container.encode(Discriminator.turnCompleted, forKey: .type)
            try container.encode(threadId, forKey: .threadId)
            try container.encode(turnId, forKey: .turnId)
            try container.encode(outcome, forKey: .outcome)
            try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        case .itemStarted(let threadId, let itemId, let kind, let title):
            try container.encode(Discriminator.itemStarted, forKey: .type)
            try container.encode(threadId, forKey: .threadId)
            try container.encode(itemId, forKey: .itemId)
            try container.encode(kind, forKey: .kind)
            try container.encodeIfPresent(title, forKey: .title)
        case .itemCompleted(let threadId, let itemId, let kind, let status):
            try container.encode(Discriminator.itemCompleted, forKey: .type)
            try container.encode(threadId, forKey: .threadId)
            try container.encode(itemId, forKey: .itemId)
            try container.encode(kind, forKey: .kind)
            try container.encode(status, forKey: .status)
        case .contentDelta(let threadId, let turnId, let streamKind, let delta):
            try container.encode(Discriminator.contentDelta, forKey: .type)
            try container.encode(threadId, forKey: .threadId)
            try container.encode(turnId, forKey: .turnId)
            try container.encode(streamKind, forKey: .streamKind)
            try container.encode(delta, forKey: .delta)
        case .requestOpened(let threadId, let requestId, let kind):
            try container.encode(Discriminator.requestOpened, forKey: .type)
            try container.encode(threadId, forKey: .threadId)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(kind, forKey: .kind)
        case .requestResolved(let threadId, let requestId, let decision):
            try container.encode(Discriminator.requestResolved, forKey: .type)
            try container.encode(threadId, forKey: .threadId)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(decision, forKey: .decision)
        case .userInputRequested(let threadId, let requestId, let questions):
            try container.encode(Discriminator.userInputRequested, forKey: .type)
            try container.encode(threadId, forKey: .threadId)
            try container.encode(requestId, forKey: .requestId)
            try container.encode(questions, forKey: .questions)
        case .userInputResolved(let threadId, let requestId):
            try container.encode(Discriminator.userInputResolved, forKey: .type)
            try container.encode(threadId, forKey: .threadId)
            try container.encode(requestId, forKey: .requestId)
        case .tokenUsageUpdated(let threadId, let snapshot):
            try container.encode(Discriminator.tokenUsageUpdated, forKey: .type)
            try container.encode(threadId, forKey: .threadId)
            try container.encode(snapshot, forKey: .snapshot)
        case .runtimeError(let threadId, let message):
            try container.encode(Discriminator.runtimeError, forKey: .type)
            try container.encodeIfPresent(threadId, forKey: .threadId)
            try container.encode(message, forKey: .message)
        }
    }
}

public protocol AgentAdapter: Sendable {
    var providerKind: AgentKind { get }
    func startSession(_ input: AgentSessionStartInput) async throws -> AgentSession
    /// Sends a new user turn or steers an already-running turn, depending on adapter state.
    func sendTurn(_ input: AgentSendTurnInput) async throws -> AgentTurnStartResult
    func interruptTurn(threadId: String, turnId: String?) async throws
    func stopSession(threadId: String) async throws
    func respondToRequest(threadId: String, requestId: String, decision: ApprovalDecision) async throws
    func respondToUserInput(threadId: String, requestId: String, answers: UserInputAnswers) async throws
    func hasSession(threadId: String) async -> Bool
    var events: AsyncStream<AgentRuntimeEvent> { get }
}

public func deriveStatusSignals(
    from events: [AgentRuntimeEvent],
    threadId: String,
    engineStatus: AgentStatus
) -> StatusSignals {
    var sessionState: AgentSessionState = .ready
    var latestTurnOutcome: TurnOutcome?
    var pendingApprovalIds = Set<String>()
    var pendingUserInputIds = Set<String>()

    for event in events {
        switch event {
        case .sessionStateChanged(let state):
            sessionState = state
        case .turnCompleted(let tid, _, let outcome, _) where tid == threadId:
            latestTurnOutcome = outcome
        case .requestOpened(let tid, let requestId, _) where tid == threadId:
            pendingApprovalIds.insert(requestId)
        case .requestResolved(let tid, let requestId, _) where tid == threadId:
            pendingApprovalIds.remove(requestId)
        case .userInputRequested(let tid, let requestId, _) where tid == threadId:
            pendingUserInputIds.insert(requestId)
        case .userInputResolved(let tid, let requestId) where tid == threadId:
            pendingUserInputIds.remove(requestId)
        default:
            break
        }
    }

    return StatusSignals(
        agentKind: .managed,
        hasPendingApproval: !pendingApprovalIds.isEmpty,
        hasPendingUserInput: !pendingUserInputIds.isEmpty,
        hookBreadcrumbPresent: false,
        hookBreadcrumbAge: nil,
        isError: sessionState == .error || latestTurnOutcome == .failed,
        isStarting: sessionState == .starting,
        isRunning: sessionState == .running || sessionState == .waiting,
        isCompleted: latestTurnOutcome == .completed,
        engineStatus: engineStatus
    )
}

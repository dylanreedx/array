import Foundation

/// The one answer to "is my message being worked on, and what is it doing?"
///
/// Before this existed four derivations answered it independently — the
/// supervisor's turn facts, the tile's own liveness latch, the compact status
/// row's session/turn facts, and the row/badge status — and the latest event
/// won. A provider SESSION event could therefore rewrite a USER-INTENT fact:
/// codex's `thread/started` and pi's session header both report "ready" before
/// the turn starts, which cleared the submission and painted Idle with Send
/// disabled for the whole spawn window (`.plans/70`, report C §2.1).
///
/// The rules, all enforced here and nowhere else:
///
/// - A submission is ARMED at Return (`arm(at:)`), and only moves forward:
///   `starting` → working (`thinking` / `tool` / `writing`) → terminal
///   (`settled` / `failed`). A session event never moves it backwards.
/// - A turn the provider starts on its own (no arm) opens its own submission,
///   so an unsolicited or mirrored turn reads the same as a prompted one.
/// - The first terminal fact of a submission wins, except that a failure
///   outranks a settle. A runner throw delivers a runtime error AND a closing
///   failed turn; that is one failure, not two.
/// - Who ended a turn is recorded (`SettleCause`), so a crash or a provider
///   interrupt never reads as the user's own Stop.
///
/// The shape is what a transcript "work strip" needs: a phase, a clock
/// anchored at Return, a step count, the last tool, error text, and how long
/// the provider has been silent.
public struct AgentTurnPresence: Equatable, Sendable {
    public enum SettleCause: String, Equatable, Sendable {
        /// The provider finished the turn.
        case completed
        /// The user stopped it (Stop, or a force send's interrupt).
        case stoppedByUser
        /// The CLI exited or vanished without finishing the turn.
        case processLost
        /// The provider ended the turn early with no Stop from the user.
        case interrupted
    }

    /// A tool the turn opened: what kind of step it is, and the provider's own
    /// title for it (a tool name, a command line, a path — host-local, never
    /// synced).
    public struct Tool: Equatable, Sendable {
        public let itemID: String
        public let kind: ItemKind
        public let title: String?

        public init(itemID: String, kind: ItemKind, title: String?) {
            self.itemID = itemID
            self.kind = kind
            self.title = title
        }

        /// One plain word for the step, provider-neutral.
        public var name: String {
            switch kind {
            case .commandExecution: return "command"
            case .fileChange: return "edit"
            case .mcpToolCall: return "tool"
            case .webSearch: return "search"
            case .subagent: return "subagent"
            case .unknown(let raw): return raw.isEmpty ? "tool" : raw
            case .assistantMessage, .reasoning, .plan, .error, .compaction: return kind.rawValue
            }
        }
    }

    public enum Phase: Equatable, Sendable {
        /// Nothing submitted, or the agent has never run.
        case idle
        /// Armed at Return; the provider has not started the turn yet.
        case starting
        /// The turn is running and the provider is thinking (or has said
        /// nothing more specific yet).
        case thinking
        /// A tool is open.
        case tool(Tool)
        /// The provider is writing its answer.
        case writing
        case settled(SettleCause)
        case failed(message: String?)

        /// 0 idle, 1 starting, 2 working, 3 terminal. A submission only climbs.
        var rank: Int {
            switch self {
            case .idle: return 0
            case .starting: return 1
            case .thinking, .tool, .writing: return 2
            case .settled, .failed: return 3
            }
        }

        public var isLive: Bool { rank == 1 || rank == 2 }
        public var isWorking: Bool { rank == 2 }
        public var isTerminal: Bool { rank == 3 }
    }

    /// A provider retry the turn is waiting on ("Retrying (2/5) in 3s").
    public struct Retry: Equatable, Sendable {
        public let attempt: Int
        public let maxAttempts: Int?
        public let delay: TimeInterval?
        public let observedAt: Date

        public init(attempt: Int, maxAttempts: Int?, delay: TimeInterval?, observedAt: Date) {
            self.attempt = attempt
            self.maxAttempts = maxAttempts
            self.delay = delay
            self.observedAt = observedAt
        }
    }

    private struct OpenTool: Equatable, Sendable {
        let tool: Tool
        let startedAt: Date
    }

    /// Bumped by every arm; lets a reader tell two submissions apart.
    public private(set) var submission: UInt64 = 0
    public private(set) var phase: Phase = .idle
    /// Return, for an armed submission; the provider's start for one it began.
    public private(set) var submittedAt: Date?
    /// The provider's own turn start (the earliest, if it repeats one).
    public private(set) var turnStartedAt: Date?
    public private(set) var settledAt: Date?
    /// The last time the provider said anything while the turn was live.
    public private(set) var lastProviderActivityAt: Date?
    /// Tools opened during this submission.
    public private(set) var stepCount = 0
    /// The most recently opened tool of this submission, kept after it closes.
    public private(set) var lastTool: Tool?
    /// The submission's error, verbatim from the provider/runner (redacted by
    /// the caller), if it failed.
    public private(set) var errorText: String?
    public private(set) var retry: Retry?
    /// What a `starting` submission is waiting on, when Array knows ("Waiting
    /// for Claude Code to finish starting"). Cleared once the turn moves on.
    public private(set) var startupDetail: String?
    private var openTools: [OpenTool] = []
    private var stopRequested = false

    public init() {}

    public var isLive: Bool { phase.isLive }
    public var isWorking: Bool { phase.isWorking }

    /// THE clock for this submission: Return when it was armed, the provider's
    /// start when the provider began it on its own.
    public var startedAt: Date? { submittedAt ?? turnStartedAt }

    /// When the tool now in the phase opened, for a live per-step clock.
    public var currentToolStartedAt: Date? {
        guard case let .tool(tool) = phase else { return nil }
        return openTools.last(where: { $0.tool.itemID == tool.itemID })?.startedAt
    }

    /// How long the provider has said nothing, while the turn is live.
    public func quietInterval(now: Date) -> TimeInterval? {
        guard isLive, let anchor = lastProviderActivityAt ?? turnStartedAt ?? submittedAt else { return nil }
        return max(0, now.timeIntervalSince(anchor))
    }

    /// Return → settle, for a settled submission.
    public var settledDuration: TimeInterval? {
        guard phase.isTerminal, let settledAt, let startedAt else { return nil }
        return max(0, settledAt.timeIntervalSince(startedAt))
    }

    public var settleCause: SettleCause? {
        if case let .settled(cause) = phase { return cause }
        return nil
    }

    // MARK: - Inputs

    /// The user pressed Return and the prompt was accepted. Opens a new
    /// submission whatever the previous one's state.
    public mutating func arm(at now: Date) {
        submission &+= 1
        phase = .starting
        submittedAt = now
        turnStartedAt = nil
        settledAt = nil
        lastProviderActivityAt = nil
        stepCount = 0
        lastTool = nil
        errorText = nil
        retry = nil
        startupDetail = nil
        openTools = []
        stopRequested = false
    }

    /// Names what a starting submission is waiting on (nil clears it).
    public mutating func noteStartupDetail(_ detail: String?) {
        guard phase == .starting else { return }
        startupDetail = detail
    }

    /// The user asked the live turn to stop. Remembered so the turn's end
    /// reads as theirs; a turn that ends without this was not.
    public mutating func noteStopRequested() {
        if isLive { stopRequested = true }
    }

    /// The provider said it is retrying. Cleared by its next real output.
    public mutating func noteRetry(_ retry: Retry) {
        guard isLive else { return }
        self.retry = retry
        lastProviderActivityAt = retry.observedAt
    }

    /// Provider output that carries no event (a stderr line, a heartbeat).
    public mutating func noteProviderActivity(at now: Date) {
        guard isLive else { return }
        lastProviderActivityAt = now
    }

    /// The process behind a live turn is gone. Terminal, and not the user's.
    public mutating func settleProcessLost(message: String?, at now: Date) {
        guard isLive else { return }
        if let message { errorText = message }
        settle(.settled(stopRequested ? .stoppedByUser : .processLost), at: now)
    }

    public mutating func reduce(_ event: AgentRuntimeEvent, at now: Date) {
        switch event {
        case .turnStarted:
            // A turn nobody armed (an unsolicited, promoted or mirrored one) is
            // its own submission — but a repeated start inside a live one is not.
            if !isLive { arm(at: now) }
            if phase == .starting { phase = .thinking }
            startupDetail = nil
            turnStartedAt = turnStartedAt.map { min($0, now) } ?? now
            retry = nil
            lastProviderActivityAt = now
        case let .contentDelta(_, _, streamKind, _):
            guard advanceToWorking(at: now) else { return }
            retry = nil
            if openTools.isEmpty {
                switch streamKind {
                case .assistant: phase = .writing
                case .reasoning: phase = .thinking
                case .commandOutput: break
                }
            }
        case let .itemStarted(_, itemID, kind, title):
            guard advanceToWorking(at: now) else { return }
            retry = nil
            if kind.isPresenceTool {
                let tool = Tool(itemID: itemID, kind: kind, title: title)
                openTools.removeAll { $0.tool.itemID == itemID }
                openTools.append(OpenTool(tool: tool, startedAt: now))
                stepCount += 1
                lastTool = tool
                phase = .tool(tool)
            } else if openTools.isEmpty {
                switch kind {
                case .assistantMessage: phase = .writing
                case .reasoning, .plan: phase = .thinking
                default: break
                }
            }
        case let .itemCompleted(_, itemID, _, _):
            guard isLive else { return }
            lastProviderActivityAt = now
            guard openTools.contains(where: { $0.tool.itemID == itemID }) else { return }
            openTools.removeAll { $0.tool.itemID == itemID }
            if let open = openTools.last {
                phase = .tool(open.tool)
            } else if case .tool = phase {
                // Between steps the provider is deciding what to do next.
                phase = .thinking
            }
        case let .turnCompleted(_, _, outcome, errorMessage):
            guard !phase.isTerminal else { return }
            switch outcome {
            case .completed:
                settle(.settled(.completed), at: now)
            case .failed:
                if let errorMessage { errorText = errorMessage }
                settle(.failed(message: errorText), at: now)
            case .interrupted, .cancelled:
                settle(.settled(stopRequested ? .stoppedByUser : .interrupted), at: now)
            }
        case let .runtimeError(_, message):
            // A runner can fail after its turn completed (a non-zero exit after
            // the result line): that is news, and it outranks the settle. A
            // second report of the same failure is not.
            if case .failed = phase, errorText == message { return }
            errorText = message
            settle(.failed(message: message), at: settledAt ?? now)
        case let .sessionStateChanged(state):
            switch state {
            case .error:
                if case .failed = phase { return }
                settle(.failed(message: errorText), at: settledAt ?? now)
            case .stopped:
                guard isLive else { return }
                settle(.settled(stopRequested ? .stoppedByUser : .interrupted), at: now)
            case .ready, .running, .starting, .waiting:
                // Process/session state. It may say the provider is alive; it
                // can never say the user's submission is over or not yet sent.
                if isLive { lastProviderActivityAt = now }
            }
        case .requestOpened, .requestResolved, .userInputRequested, .userInputResolved,
             .tokenUsageUpdated, .contextWindowUpdated, .compactionChanged,
             .childAgentSpawned, .semanticSignal:
            if isLive { lastProviderActivityAt = now }
        }
    }

    // MARK: - Private

    /// Content or a step means the turn is running, whether or not the provider
    /// announced a start first. False when no submission is live.
    private mutating func advanceToWorking(at now: Date) -> Bool {
        guard isLive else { return false }
        if phase == .starting {
            phase = .thinking
            startupDetail = nil
            turnStartedAt = turnStartedAt ?? now
        }
        lastProviderActivityAt = now
        return true
    }

    private mutating func settle(_ terminal: Phase, at now: Date) {
        phase = terminal
        settledAt = now
        openTools = []
        retry = nil
        startupDetail = nil
        stopRequested = false
        if submittedAt == nil, turnStartedAt == nil { submittedAt = now }
    }
}

public extension ItemKind {
    /// A step the provider runs on the user's behalf — what a work strip counts.
    var isPresenceTool: Bool {
        switch self {
        case .commandExecution, .fileChange, .mcpToolCall, .webSearch, .subagent, .unknown:
            return true
        case .assistantMessage, .reasoning, .plan, .error, .compaction:
            return false
        }
    }
}

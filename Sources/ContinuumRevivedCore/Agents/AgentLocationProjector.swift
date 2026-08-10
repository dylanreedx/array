import Foundation

// Queue 91 P2 — private runtime observations and the canonical host-local
// Home / Where / What projector. These types carry filesystem URLs, so they are
// intentionally not Codable and must never replace AgentRuntimeEvent or
// AgentActivityEvent at a sync boundary.

/// Private provider evidence that is richer than the shared runtime stream.
/// A provider adapter may report its explicit cwd and whitelisted tool targets;
/// it may not place raw args, command bodies, prompts, results, or provider
/// routing identifiers in this value.
public enum AgentRuntimeObservation: Equatable, Sendable {
    case workingDirectory(URL, observedAt: Date)
    case toolActivity(itemId: String, activity: AgentObservedActivity)
    /// A provider-minted session/thread id captured from the live stream (codex
    /// mints its own `thread_id` on `thread.started` with no flag to set it).
    /// It rides this host-local side channel rather than an `AgentRuntimeEvent`
    /// because the supervisor rebinds every event's threadId to the agent's own
    /// derived id before delivery — so the captured id could not survive on an
    /// event. The supervisor persists it to `AgentRecord.codexThreadId` to
    /// resume the same thread later. Not a location fact: the projector ignores
    /// it.
    case threadId(String)
}

/// Deterministically folds private provider observations and normalized runtime
/// lifecycle events into one host-local location snapshot. It does not own or
/// alter the existing lifecycle classifier.
public struct AgentLocationProjector: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var staleAfter: TimeInterval

        public init(staleAfter: TimeInterval = 30) {
            self.staleAfter = max(0, staleAfter)
        }
    }

    public let home: AgentHome
    public private(set) var whereDirectory: URL
    public private(set) var lastUsefulActivity: AgentObservedActivity?

    private let configuration: Configuration
    private var currentActivity: AgentObservedActivity?
    private var lastWhereObservedAt: Date?
    private var locallyObservedItemIds: Set<String> = []

    public init(
        home: AgentHome,
        whereDirectory: URL,
        configuration: Configuration = Configuration()
    ) {
        self.home = home
        self.whereDirectory = whereDirectory.standardizedFileURL
        self.configuration = configuration
    }

    /// Ingest private host-only evidence. A tool target changes What only; Where
    /// changes only through the explicit working-directory case.
    public mutating func ingest(_ observation: AgentRuntimeObservation) {
        switch observation {
        case .workingDirectory(let directory, let observedAt):
            guard lastWhereObservedAt.map({ observedAt >= $0 }) ?? true else { return }
            whereDirectory = directory.standardizedFileURL
            lastWhereObservedAt = observedAt

        case .toolActivity(let itemId, let activity):
            locallyObservedItemIds.insert(itemId)
            setActivity(activity, useful: true)

        case .threadId:
            // A provider session id is host-local persistence state, not a Home
            // / Where / What fact. The supervisor persists it; the projector has
            // nothing to fold in.
            break
        }
    }

    /// Ingest the existing normalized lifecycle stream without copying any body
    /// fields into What. Raw error/reasoning/assistant text is intentionally ignored.
    public mutating func ingest(_ event: AgentRuntimeEvent, at now: Date) {
        switch event {
        case .sessionStateChanged(let state):
            switch state {
            case .starting, .running:
                setLifecycle(.thinking, at: now)
            case .ready, .waiting:
                setLifecycle(.waiting, at: now)
            case .stopped:
                setLifecycle(.interrupted, at: now)
            case .error:
                setLifecycle(.failed, at: now)
            }

        case .turnStarted:
            locallyObservedItemIds.removeAll(keepingCapacity: true)
            setLifecycle(.thinking, at: now)

        case .turnCompleted(_, _, let outcome, _):
            locallyObservedItemIds.removeAll(keepingCapacity: true)
            switch outcome {
            case .completed:
                setLifecycle(.completed, at: now)
            case .failed:
                setLifecycle(.failed, at: now)
            case .interrupted, .cancelled:
                setLifecycle(.interrupted, at: now)
            }

        case .itemStarted(_, let itemId, let kind, let title):
            // Pi's private observation is emitted first on the same serial queue.
            // Do not immediately overwrite its path-bearing activity with the
            // generic normalized event for the same item.
            guard locallyObservedItemIds.remove(itemId) == nil else { return }
            setActivity(AgentObservedActivity(
                operation: Self.operation(for: kind, title: title),
                targetPath: nil,
                startedAt: now,
                updatedAt: now,
                evidenceSource: .lifecycleEvent), useful: true)

        case .itemCompleted(_, let itemId, _, let status):
            locallyObservedItemIds.remove(itemId)
            switch status {
            case .failed, .declined:
                setLifecycle(.failed, at: now)
            case .completed:
                setLifecycle(.thinking, at: now)
            case .inProgress:
                break
            }

        case .contentDelta(_, _, let streamKind, _):
            // Observe only the shape, never the body. Repeated deltas deduplicate
            // semantically in setActivity and therefore do not churn timestamps.
            switch streamKind {
            case .assistant, .reasoning:
                setLifecycle(.thinking, at: now)
            case .commandOutput:
                setLifecycle(.running, at: now)
            }

        case .requestOpened, .userInputRequested:
            setLifecycle(.waiting, at: now)

        case .requestResolved, .userInputResolved:
            setLifecycle(.thinking, at: now)

        case .runtimeError:
            setLifecycle(.failed, at: now)

        case .tokenUsageUpdated, .contextWindowUpdated:
            break
        }
    }

    /// Current projection at a caller-supplied clock. Expiry removes only What;
    /// Home, Where, lifecycle state, and the retained last useful tool activity
    /// remain independently owned facts.
    public func snapshot(at now: Date) -> AgentLocationSnapshot {
        let visible: AgentObservedActivity?
        if let currentActivity,
           now.timeIntervalSince(currentActivity.updatedAt) < configuration.staleAfter {
            visible = currentActivity
        } else {
            visible = nil
        }
        return AgentLocationSnapshot(
            home: home,
            whereDirectory: whereDirectory,
            what: visible,
            whatExpiresAt: visible.map {
                $0.updatedAt.addingTimeInterval(configuration.staleAfter)
            },
            lastUsefulWhat: lastUsefulActivity)
    }

    private mutating func setLifecycle(_ operation: AgentObservedActivity.Operation, at now: Date) {
        setActivity(AgentObservedActivity(
            operation: operation,
            targetPath: nil,
            startedAt: now,
            updatedAt: now,
            evidenceSource: .lifecycleEvent), useful: false)
    }

    private mutating func setActivity(_ activity: AgentObservedActivity, useful: Bool) {
        guard currentActivity.map({ activity.updatedAt >= $0.updatedAt }) ?? true else { return }
        guard !Self.sameMeaning(currentActivity, activity) else { return }
        currentActivity = activity
        if useful { lastUsefulActivity = activity }
    }

    private static func sameMeaning(
        _ lhs: AgentObservedActivity?,
        _ rhs: AgentObservedActivity
    ) -> Bool {
        guard let lhs else { return false }
        return lhs.operation == rhs.operation
            && lhs.targetPath == rhs.targetPath
            && lhs.evidenceSource == rhs.evidenceSource
    }

    private static func operation(
        for kind: ItemKind,
        title: String?
    ) -> AgentObservedActivity.Operation {
        if let title {
            switch title.lowercased() {
            case "read", "cat":
                return .reading
            case "edit", "write", "multiedit", "apply_patch", "applypatch":
                return .editing
            case "bash", "shell", "run", "exec", "execute_command":
                return .running
            case "grep", "find", "ls", "glob", "search", "web_search", "websearch", "web":
                return .searching
            default:
                break
            }
        }
        switch kind {
        case .fileChange:
            return .editing
        case .webSearch:
            return .searching
        case .reasoning, .assistantMessage, .plan:
            return .thinking
        case .error:
            return .failed
        case .commandExecution, .mcpToolCall:
            return .inspecting
        }
    }
}

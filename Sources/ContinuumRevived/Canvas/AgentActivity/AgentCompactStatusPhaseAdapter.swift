import ContinuumRevivedCore
import Foundation

/// Provider-neutral runtime facts consumed by the compact status phase adapter.
///
/// This is intentionally a compiled seam, not a second provider state machine.
/// The coordinator that owns the managed-agent event stream must provide:
/// - the latest session state and its authoritative start instant (when known);
/// - the latest turn state, turn/stream start, and terminal outcome instant;
/// - the current, non-expired `AgentObservedActivity` tool fact; and
/// - whether an approval/user-input interaction is pending and when it began.
///
/// `AgentRuntimeEvent` currently has no timestamps. Receipt time must not be
/// passed as a phase anchor. Until the coordinator supplies a provider/runtime
/// timestamp, this adapter returns a phase with a nil `phaseStartedAt` rather
/// than fabricating elapsed time. Tool facts can already carry their
/// host-local, provider-observation `startedAt` through `AgentLocationSnapshot`.
struct AgentCompactStatusPhaseFacts: Equatable {
    struct Session: Equatable {
        let state: AgentSessionState
        /// The instant this session state began, if the runtime supplied one.
        let startedAt: Date?

        init(state: AgentSessionState, startedAt: Date? = nil) {
            self.state = state
            self.startedAt = startedAt
        }
    }

    enum Turn: Equatable {
        case active(startedAt: Date?, stream: ContentStreamKind?, streamStartedAt: Date?)
        /// `phaseStartedAt` is the instant the terminal phase began, not the
        /// turn's original start. It is nil when the runtime omitted it.
        case completed(outcome: TurnOutcome, phaseStartedAt: Date?)
    }

    enum Interaction: Equatable {
        case pending(startedAt: Date?)
        case clear
    }

    let session: Session?
    let turn: Turn?
    let currentActivity: AgentObservedActivity?
    let currentActivityExpiresAt: Date?
    let interaction: Interaction?

    init(
        session: Session? = nil,
        turn: Turn? = nil,
        currentActivity: AgentObservedActivity? = nil,
        currentActivityExpiresAt: Date? = nil,
        interaction: Interaction? = nil
    ) {
        self.session = session
        self.turn = turn
        self.currentActivity = currentActivity
        self.currentActivityExpiresAt = currentActivityExpiresAt
        self.interaction = interaction
    }

    /// Build the seam from the existing host-local location projector. A
    /// missing/expired `What` remains missing; `lastUsefulWhat` is never used
    /// as current activity because that would turn stale context into a claim.
    init(
        session: Session? = nil,
        turn: Turn? = nil,
        location: AgentLocationSnapshot,
        interaction: Interaction? = nil
    ) {
        self.init(
            session: session,
            turn: turn,
            currentActivity: location.what,
            currentActivityExpiresAt: location.whatExpiresAt,
            interaction: interaction)
    }
}

/// Result of resolving runtime facts. A nil phase is deliberate unknown state;
/// callers must not coerce it to `.thinking` or use its nil anchor as `now`.
struct AgentCompactStatusPhaseResolution: Equatable {
    let phase: AgentCompactActivityPhase?
    let phaseStartedAt: Date?
    let safeToolLabel: String?
    let evidence: String

    var isKnown: Bool { phase != nil }

    /// Bridge for the later tile composition pass. Unknown stays unavailable
    /// instead of silently becoming a visually precise activity label.
    var activityInput: AgentCompactActivityInput? {
        guard let phase else { return nil }
        return AgentCompactActivityInput(
            phase: phase,
            phaseStartedAt: phaseStartedAt,
            safeToolLabel: safeToolLabel,
            evidenceNote: evidence)
    }

    static let unknown = AgentCompactStatusPhaseResolution(
        phase: nil,
        phaseStartedAt: nil,
        safeToolLabel: nil,
        evidence: "No authoritative session, turn, interaction, or current-tool phase fact.")
}

/// Stateful, deterministic adapter for live compact-row phase and elapsed-time
/// inputs. It only changes the phase anchor on a phase transition, and never
/// uses the caller's clock as an anchor.
struct AgentCompactStatusPhaseAdapter {
    private var lastPhase: AgentCompactActivityPhase?
    private var lastPhaseStartedAt: Date?
    private(set) var resolution: AgentCompactStatusPhaseResolution = .unknown

    init() {}

    mutating func update(
        _ facts: AgentCompactStatusPhaseFacts,
        now: Date
    ) -> AgentCompactStatusPhaseResolution {
        let candidate = Self.resolve(facts, now: now)
        if candidate.phase != lastPhase {
            lastPhase = candidate.phase
            lastPhaseStartedAt = candidate.phaseStartedAt
        } else if lastPhaseStartedAt == nil, let candidateStartedAt = candidate.phaseStartedAt {
            // A later authoritative fact may fill an anchor that was absent;
            // repeated same-phase events may never replace an existing anchor.
            lastPhaseStartedAt = candidateStartedAt
        }

        resolution = AgentCompactStatusPhaseResolution(
            phase: lastPhase,
            phaseStartedAt: lastPhaseStartedAt,
            safeToolLabel: candidate.safeToolLabel,
            evidence: candidate.evidence)
        return resolution
    }

    mutating func reset() {
        lastPhase = nil
        lastPhaseStartedAt = nil
        resolution = .unknown
    }

    private static func resolve(
        _ facts: AgentCompactStatusPhaseFacts,
        now: Date
    ) -> AgentCompactStatusPhaseResolution {
        let currentActivity: AgentObservedActivity?
        if let activity = facts.currentActivity,
           facts.currentActivityExpiresAt.map({ now < $0 }) ?? true {
            currentActivity = activity
        } else {
            currentActivity = nil
        }

        // Terminal facts win over all lower-confidence activity facts. A stale
        // tool observation can never hide an explicit failure/interruption.
        if case let .completed(outcome, phaseStartedAt)? = facts.turn {
            return terminal(outcome, phaseStartedAt: phaseStartedAt, evidence: "Latest turn outcome is authoritative.")
        }
        if let session = facts.session {
            switch session.state {
            case .error:
                return result(.failed, startedAt: session.startedAt, evidence: "Session is in an error state.")
            case .stopped:
                return result(.interrupted, startedAt: session.startedAt, evidence: "Session is stopped.")
            default:
                break
            }
        }

        // A failed/interrupted tool is terminal evidence in its own right.
        if let activity = currentActivity,
           activity.operation == .failed || activity.operation == .interrupted {
            return activityResult(activity)
        }

        if case let .pending(startedAt)? = facts.interaction {
            return result(.waiting, startedAt: startedAt, evidence: "An approval or user-input interaction is pending.")
        }

        // Specific tool/message observations outrank a generic active-turn
        // fact. Generic lifecycle thinking/waiting observations do not: they
        // must not hide a more precise assistant or reasoning stream.
        if let activity = currentActivity,
           isSpecificActivity(activity.operation) {
            return activityResult(activity)
        }

        if case let .active(startedAt, stream, streamStartedAt)? = facts.turn {
            switch stream {
            case .assistant:
                return result(.responding, startedAt: streamStartedAt ?? startedAt, evidence: "Assistant response stream is active.")
            case .reasoning:
                return result(.thinking, startedAt: streamStartedAt ?? startedAt, evidence: "Reasoning stream is active.")
            case .commandOutput:
                return result(.running, startedAt: streamStartedAt ?? startedAt, evidence: "Command output stream is active.")
            case nil:
                // An active turn without an explicit stream does not identify
                // thinking, responding, or tool work. Keep it explicitly
                // unknown rather than fabricating a Thinking phase.
                return .unknown
            }
        }

        if let activity = currentActivity {
            return activityResult(activity)
        }

        if let session = facts.session {
            switch session.state {
            case .starting:
                return result(.starting, startedAt: session.startedAt, evidence: "Session is starting.")
            case .waiting:
                return result(.waiting, startedAt: session.startedAt, evidence: "Session is waiting.")
            case .ready:
                return result(.ready, startedAt: nil, evidence: "Session is ready.")
            case .running:
                // Running alone does not distinguish thinking, responding, or
                // tool work. Keep the phase unknown until the coordinator gives
                // an active turn/stream or current-tool fact.
                return .unknown
            case .stopped, .error:
                // Handled above; exhaustive for future enum additions.
                break
            }
        }

        return .unknown
    }

    private static func isSpecificActivity(_ operation: AgentObservedActivity.Operation) -> Bool {
        switch operation {
        case .reading, .editing, .running, .searching, .messaging:
            return true
        case .thinking, .waiting, .completed, .interrupted, .failed, .inspecting:
            return false
        }
    }

    private static func activityResult(_ activity: AgentObservedActivity) -> AgentCompactStatusPhaseResolution {
        let phase = AgentCompactActivityPhase(operation: activity.operation)
        guard let phase else { return .unknown }
        let evidence: String
        switch activity.evidenceSource {
        case .toolEvent: evidence = "Current tool observation is authoritative."
        case .lifecycleEvent: evidence = "Current runtime lifecycle observation is authoritative."
        case .hostAction: evidence = "Current host action observation is authoritative."
        }
        return result(
            phase,
            startedAt: phase == .ready ? nil : activity.startedAt,
            safeToolLabel: activity.targetPath?.lastPathComponent,
            evidence: evidence)
    }

    private static func terminal(
        _ outcome: TurnOutcome,
        phaseStartedAt: Date?,
        evidence: String
    ) -> AgentCompactStatusPhaseResolution {
        switch outcome {
        case .completed:
            return result(.ready, startedAt: nil, evidence: evidence)
        case .failed:
            return result(.failed, startedAt: phaseStartedAt, evidence: evidence)
        case .interrupted, .cancelled:
            return result(.interrupted, startedAt: phaseStartedAt, evidence: evidence)
        }
    }

    private static func result(
        _ phase: AgentCompactActivityPhase,
        startedAt: Date?,
        safeToolLabel: String? = nil,
        evidence: String
    ) -> AgentCompactStatusPhaseResolution {
        AgentCompactStatusPhaseResolution(
            phase: phase,
            phaseStartedAt: startedAt,
            safeToolLabel: safeToolLabel,
            evidence: evidence)
    }
}

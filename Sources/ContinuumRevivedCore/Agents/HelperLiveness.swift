import Foundation

/// What a delegated or messaged helper is doing, as the host observes it
/// (`.plans/116` part 20, liveness step). Observation only: nothing stops,
/// restarts, interrupts or messages a helper because of this value, and its
/// lead is never told about it unprompted.
///
/// Signals, all of which the host already has:
/// - **In a turn**: the presence status is `working` (or `needsAttention`).
/// - **Last progress**: the watchdog's progress clock — a hook receipt, a
///   transcript delta or item, a status change, a declared status.
/// - **Live children**: the jobs `AgentProcessTracker` already lists for the
///   agent (processes under its CLI, at least `minimumJobAge` old). A tool
///   call running a build is one of these, foreground or background.
/// - **Open tool calls**: tool items the bound runner's own stream started and
///   has not ended (the supervisor's `openToolItems`). They close on their end,
///   on the turn's end, or when the runner's process ends.
public enum HelperLiveness: String, Codable, Equatable, Sendable {
    /// In a turn, and progress arrived within `quietAfter`.
    case working
    /// In a turn and quiet, but a process it started is still running: a real
    /// build or test run. Not stalled.
    case waitingOnChild
    /// In a turn and quiet, no live child, but a tool call it started has not
    /// returned: a long MCP call, a web search, a subagent. Not stalled.
    case waitingOnToolCall
    /// In a turn, quiet for `quietAfter` or longer, nothing it started is
    /// running and no tool call is open. Waiting on nothing the host can see.
    case stalled
    /// Blocked on an explicit request (an approval or other needs-you).
    case blocked
    /// Not in a turn. A finished helper is never stalled.
    case finished

    /// Quiet this long, with nothing running, reads as stalled. A classifier,
    /// never a limit: nothing is stopped, refused or delayed by it.
    public static let defaultQuietAfter: TimeInterval = 2 * 60

    public static func classify(
        inTurn: Bool, blocked: Bool, lastProgressAt: Date, liveChildren: Int,
        openToolCalls: Int, now: Date, quietAfter: TimeInterval
    ) -> HelperLiveness {
        guard inTurn else { return .finished }
        if blocked { return .blocked }
        if now.timeIntervalSince(lastProgressAt) < quietAfter { return .working }
        if liveChildren > 0 { return .waitingOnChild }
        return openToolCalls > 0 ? .waitingOnToolCall : .stalled
    }

    /// Waiting on something the host can see still running.
    public var isWaiting: Bool { self == .waitingOnChild || self == .waitingOnToolCall }
}

/// One helper's liveness and the evidence it was read from.
public struct HelperLivenessFact: Codable, Equatable, Sendable {
    public var state: HelperLiveness
    /// When the helper entered `state`.
    public var since: Date
    /// The last progress the host observed from the helper itself.
    public var lastProgressAt: Date
    /// How many processes it started are still running.
    public var liveChildren: Int
    /// How many tool calls it started have not returned.
    public var openToolCalls: Int

    public init(state: HelperLiveness, since: Date, lastProgressAt: Date, liveChildren: Int, openToolCalls: Int) {
        self.state = state
        self.since = since
        self.lastProgressAt = lastProgressAt
        self.liveChildren = liveChildren
        self.openToolCalls = openToolCalls
    }
}

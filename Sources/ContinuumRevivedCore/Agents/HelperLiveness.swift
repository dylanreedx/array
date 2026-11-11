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
public enum HelperLiveness: String, Codable, Equatable, Sendable {
    /// In a turn, and progress arrived within `quietAfter`.
    case working
    /// In a turn and quiet, but a process it started is still running: a real
    /// build or test run. Not stalled.
    case waitingOnChild
    /// In a turn, quiet for `quietAfter` or longer, and nothing it started is
    /// running. Waiting on nothing the host can see. A long MCP call reads
    /// this way too: the host sees no process for it.
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
        now: Date, quietAfter: TimeInterval
    ) -> HelperLiveness {
        guard inTurn else { return .finished }
        if blocked { return .blocked }
        if now.timeIntervalSince(lastProgressAt) < quietAfter { return .working }
        return liveChildren > 0 ? .waitingOnChild : .stalled
    }
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

    public init(state: HelperLiveness, since: Date, lastProgressAt: Date, liveChildren: Int) {
        self.state = state
        self.since = since
        self.lastProgressAt = lastProgressAt
        self.liveChildren = liveChildren
    }
}

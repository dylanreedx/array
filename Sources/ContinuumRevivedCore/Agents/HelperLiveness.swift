import Foundation

/// What a delegated or messaged helper is doing, as the host observes it
/// (`.plans/116` part 20, liveness step). Nothing stops, restarts, interrupts
/// or messages a helper because of this value. With Settings ▸ Agents ▸
/// Managed mode ▸ "Tell the lead only when a helper is stuck" on, it decides
/// when its lead hears (see `docs/internals/notification-paths.md`).
///
/// Signals, all of which the host already has:
/// - **In a turn**: the presence status is `working` (or `needsAttention`).
/// - **Last progress**: the watchdog's progress clock — a hook receipt, a
///   transcript delta or item, a status change, a declared status.
/// - **Live children**: the jobs `AgentProcessTracker` already lists for the
///   agent (processes under its CLI, at least `minimumJobAge` old) that
///   started during its current turn. A dev server left from an earlier turn
///   does not count.
/// - **Open tool calls**: tool items the bound runner's own stream started and
///   has not ended (the supervisor's `openToolItems`). They close on their end,
///   on the turn's end, or when the runner's process ends.
/// - **Sub-helpers**: Array helpers it delegated or messaged that are in a
///   turn, and provider subagent items it has open.
/// - **Model silence**: whether the harness streams anything the host counts
///   as progress while its model reasons (`reasoningStreams(for:)`).
public enum HelperLiveness: String, Codable, Equatable, Sendable {
    /// In a turn, and progress arrived within `quietAfter`.
    case working
    /// Starting, queued, compacting or waiting out a provider retry: busy, not
    /// on a tool. Never stalled, however quiet.
    case busy
    /// In a turn and quiet, but a helper it started (an Array helper or a
    /// provider subagent) is still in a turn. Its own liveness speaks for it.
    case waitingOnHelper
    /// In a turn and quiet, but a process it started this turn is still
    /// running: a real build or test run. Not stalled.
    case waitingOnChild
    /// In a turn and quiet, no live child, but a tool call it started has not
    /// returned: a long MCP call, a web search. Not stalled.
    case waitingOnToolCall
    /// In a turn and quiet with its process alive and nothing open, on a
    /// harness whose model streams nothing the host sees while it reasons
    /// (Codex, Pi). Quiet here is not evidence of a stall.
    case waitingOnModel
    /// In a turn, quiet for `quietAfter` or longer, nothing it started is
    /// running, no tool call is open and its model would be streaming if it
    /// were thinking. Waiting on nothing the host can see.
    case stalled
    /// Blocked on an explicit request (an approval or other needs-you).
    case blocked
    /// Not in a turn. A finished helper is never stalled.
    case finished

    /// Quiet this long, with nothing running, reads as stalled. A classifier,
    /// never a limit: nothing is stopped, refused or delayed by it.
    public static let defaultQuietAfter: TimeInterval = 2 * 60

    public static func classify(
        inTurn: Bool, blocked: Bool, busy: Bool = false, lastProgressAt: Date,
        subHelpers: Int = 0, liveChildren: Int, openToolCalls: Int, modelSilent: Bool = false,
        now: Date, quietAfter: TimeInterval
    ) -> HelperLiveness {
        guard inTurn else { return .finished }
        if blocked { return .blocked }
        if busy { return .busy }
        if now.timeIntervalSince(lastProgressAt) < quietAfter { return .working }
        if subHelpers > 0 { return .waitingOnHelper }
        if liveChildren > 0 { return .waitingOnChild }
        if openToolCalls > 0 { return .waitingOnToolCall }
        return modelSilent ? .waitingOnModel : .stalled
    }

    /// Waiting on a process or tool call the host can see still running.
    public var isWaiting: Bool { self == .waitingOnChild || self == .waitingOnToolCall }

    /// Whether a harness streams events the host counts as progress while its
    /// model reasons, from the recorded provider streams:
    /// - Claude Code: yes. `thinking_delta` frames (e.g.
    ///   `Fixtures/claude-websearch-turn.jsonl`) become reasoning deltas.
    /// - Codex: no. A reasoning item opens and closes with nothing between
    ///   (`Fixtures/codex-appserver-*.jsonl`), and the translator emits nothing
    ///   for either end.
    /// - Pi: no recorded evidence. No recorded Pi stream holds a
    ///   `thinking_delta`, so a quiet model turn is not read as a stall.
    /// `--helper-liveness-check` replays those fixtures against this table.
    public static func reasoningStreams(for harness: AgentHarness) -> Bool {
        switch harness {
        case .claudeCode: return true
        case .codex, .pi: return false
        }
    }
}

/// One helper's liveness and the evidence it was read from.
public struct HelperLivenessFact: Codable, Equatable, Sendable {
    public var state: HelperLiveness
    /// When the helper entered `state`.
    public var since: Date
    /// The last progress the host observed from the helper itself. Quiet is
    /// always measured from here.
    public var lastProgressAt: Date
    /// How many processes it started this turn are still running.
    public var liveChildren: Int
    /// How many tool calls it started have not returned.
    public var openToolCalls: Int
    /// How many helpers it started are still in a turn.
    public var subHelpers: Int
    /// One word for what it is busy with or waiting on: `compacting`,
    /// `retrying`, a command's first word or a tool's name. Never arguments.
    public var detail: String?

    public init(state: HelperLiveness, since: Date, lastProgressAt: Date, liveChildren: Int, openToolCalls: Int,
                subHelpers: Int = 0, detail: String? = nil) {
        self.state = state
        self.since = since
        self.lastProgressAt = lastProgressAt
        self.liveChildren = liveChildren
        self.openToolCalls = openToolCalls
        self.subHelpers = subHelpers
        self.detail = detail
    }
}

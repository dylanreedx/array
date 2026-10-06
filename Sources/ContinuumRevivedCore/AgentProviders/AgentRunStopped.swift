import Foundation

/// The error a runner throws when its `run` unwound because someone pressed
/// Stop. M1.7 (`.plans/46`).
///
/// `AgentRunning.stop()` is declared non-throwing and cannot itself report
/// anything. What actually happens on a Stop is that `stop()` SIGTERMs the child
/// and **`run()` then throws as a consequence**: the CLI exits non-zero and the
/// runner raises its own `RunError` on the way out. The supervisor caught that,
/// delivered `.runtimeError`, and the turn was recorded as `.failed`, persisted,
/// and pushed to the user's phone as "agent failed". Every one of the eleven
/// consumers of `TurnOutcome.interrupted` was already correct; there was simply
/// no producer.
///
/// A distinct type rather than a flag on the existing errors, because the
/// supervisor has to tell the two apart at a `catch` it does not otherwise
/// inspect, and because each runner has its own `RunError`.
public struct AgentRunStopped: Error, CustomStringConvertible, Sendable {
    /// What the CLI said on the way out, kept for the transcript but NOT treated
    /// as a failure. A SIGTERM'd CLI usually says something alarming.
    public let detail: String?

    public init(detail: String? = nil) {
        self.detail = detail
    }

    public var description: String {
        guard let detail, !detail.isEmpty else { return "the turn was stopped" }
        return "the turn was stopped (\(detail))"
    }
}

/// T5 — a steer the runner could not hand to the provider: no turn is live, the
/// turn kind refuses steering (codex review/compact), or the provider rejected
/// the frame. The supervisor keeps the message HELD rather than losing it, so it
/// runs as the next turn instead.
public struct AgentSteerNotAccepted: Error, CustomStringConvertible, Sendable {
    public let reason: String

    public init(_ reason: String) {
        self.reason = reason
    }

    public var description: String { "steer not accepted (\(reason))" }
}

/// T5 — what became of a steer a runner accepted. `consumed` is the provider's
/// own receipt (claude's replay, pi's queue drain, codex's `turn/steer`
/// response); `returned` means the provider dropped it unread (pi's queue cleared
/// at an interrupt), so the supervisor holds it again.
public enum AgentSteerDisposition: Equatable, Sendable {
    case consumed
    case returned
}

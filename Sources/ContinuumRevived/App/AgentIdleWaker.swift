import Foundation
import ContinuumRevivedCore

/// Wakes an agent whose turn ended while something it started was still
/// running, and nudges one that promised future action with nothing running.
///
/// Nothing here polls. Exits arrive from `AgentProcessTracker.onJobsEnded` (its
/// kqueue exit sources); the nudge is one timer armed per turn end. Delivery is
/// the supervisor's own send path, injected as `deliver`.
@MainActor
final class AgentIdleWaker {
    /// Exits inside this window are one wake.
    var batchWindow: TimeInterval = 5
    /// How long an idle promise is given before the nudge.
    var nudgeDelay: TimeInterval = 180

    /// Not in a turn, not paused, nothing queued: a turn can start now.
    var isIdle: (AgentID) -> Bool = { _ in false }
    /// The CLI itself holds a background task or schedule for this agent and
    /// will start its own turn when it finishes, so Array must not.
    var cliTracksBackgroundWork: (AgentID) -> Bool = { _ in false }
    /// Jobs of this agent that are running now.
    var liveJobs: (AgentID) -> Int = { _ in 0 }
    /// The reply the turn ended with.
    var lastReply: (AgentID) -> String? = { _ in nil }
    /// This turn filed an `array_report`.
    var filedReport: (AgentID) -> Bool = { _ in false }
    /// Starts one turn carrying `text`. Returns whether it was accepted.
    var deliver: (AgentID, String) -> Bool = { _, _ in false }

    private var pending: [AgentID: [AgentBackgroundJob]] = [:]
    private var batchTimers: [AgentID: Task<Void, Never>] = [:]
    private var nudgeTimers: [AgentID: Task<Void, Never>] = [:]
    /// The turn that just ended was one of ours; it never earns a nudge, so a
    /// nudge cannot beget a nudge.
    private var ownTurn: Set<AgentID> = []

    private(set) var wakeCount = 0
    private(set) var nudgeCount = 0

    /// QA only: `CONTINUUM_QA_IDLE_WAKER_OFF=1` is the 0.7.56 behaviour, so one
    /// binary shows `--idle-waker-check` RED and GREEN.
    static let disabled = ProcessInfo.processInfo.environment["CONTINUUM_QA_IDLE_WAKER_OFF"] == "1"

    static let nudgeText = "Nothing is running for you and nothing will wake you. Run the next step now, or report."

    /// Phrases that promise a later action.
    static func promisesLater(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["i'll check", "i will check", "i'll wait", "i will wait", "when it finishes", "once it finishes",
                "when the build", "once the build", "waiting on", "waiting for", "check again", "check back",
                "i'll come back", "i'll follow up", "will report back", "in a few minutes", "in 4 minutes"]
            .contains { t.contains($0) }
    }

    // MARK: Exits

    func jobsEnded(_ agent: AgentID, _ jobs: [AgentBackgroundJob]) {
        guard !Self.disabled, isIdle(agent), !cliTracksBackgroundWork(agent) else { return }
        pending[agent, default: []] += jobs
        guard batchTimers[agent] == nil else { return }
        let delay = batchWindow
        batchTimers[agent] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flushWake(agent)
        }
    }

    private func flushWake(_ agent: AgentID) {
        batchTimers[agent] = nil
        let jobs = pending.removeValue(forKey: agent) ?? []
        // Re-checked at fire time: the CLI may have woken itself in the window.
        guard !jobs.isEmpty, isIdle(agent), !cliTracksBackgroundWork(agent) else { return }
        let now = Date()
        let lines = jobs.map { job -> String in
            let secs = Int(now.timeIntervalSince(job.startedAt))
            return "`\(String(job.label.prefix(80)))` finished (exit status not observed) after \(Self.duration(secs))."
        }
        let text = (jobs.count == 1
            ? "Your background command " + lines[0]
            : "Your background commands finished:\n" + lines.map { "- " + $0 }.joined(separator: "\n"))
            + " Continue."
        if deliver(agent, text) {
            wakeCount += 1
            ownTurn.insert(agent)
            cancelNudge(agent)
        }
    }

    static func duration(_ seconds: Int) -> String {
        seconds >= 120 ? "\(seconds / 60) min" : "\(max(seconds, 0)) s"
    }

    // MARK: Idle promises

    /// Call when a turn has ended and the runner slot is free.
    func turnEnded(_ agent: AgentID) {
        cancelNudge(agent)
        if Self.disabled || ownTurn.remove(agent) != nil { return }
        guard let reply = lastReply(agent), Self.promisesLater(reply) else { return }
        let delay = nudgeDelay
        nudgeTimers[agent] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.fireNudge(agent)
        }
    }

    private func fireNudge(_ agent: AgentID) {
        nudgeTimers[agent] = nil
        guard isIdle(agent), liveJobs(agent) == 0, !cliTracksBackgroundWork(agent), !filedReport(agent) else { return }
        if deliver(agent, Self.nudgeText) {
            nudgeCount += 1
            ownTurn.insert(agent)
        }
    }

    private func cancelNudge(_ agent: AgentID) {
        nudgeTimers.removeValue(forKey: agent)?.cancel()
    }
}

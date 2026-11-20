import Foundation
import ContinuumRevivedCore

/// Wakes an agent whose turn ended while something it started was still
/// running. (A phrase-matched "nudge" for idle promises was removed: it fired
/// on quoted text and was visible to the person.)
///
/// Nothing here polls. Exits arrive from `AgentProcessTracker.onJobsEnded` (its
/// kqueue exit sources). Delivery is the supervisor's own send path, injected
/// as `deliver`.
@MainActor
final class AgentIdleWaker {
    /// Exits inside this window are one wake.
    var batchWindow: TimeInterval = 5

    /// Not in a turn, not paused, nothing queued: a turn can start now.
    var isIdle: (AgentID) -> Bool = { _ in false }
    /// The CLI itself holds a background task or schedule for this agent and
    /// will start its own turn when it finishes, so Array must not.
    var cliTracksBackgroundWork: (AgentID) -> Bool = { _ in false }
    /// Starts one turn carrying `text`. Returns whether it was accepted.
    var deliver: (AgentID, String) -> Bool = { _, _ in false }

    private var pending: [AgentID: [AgentBackgroundJob]] = [:]
    private var batchTimers: [AgentID: Task<Void, Never>] = [:]

    private(set) var wakeCount = 0

    /// QA only: `CONTINUUM_QA_IDLE_WAKER_OFF=1` is the 0.7.56 behaviour, so one
    /// binary shows `--idle-waker-check` RED and GREEN.
    static let disabled = ProcessInfo.processInfo.environment["CONTINUUM_QA_IDLE_WAKER_OFF"] == "1"

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
        }
    }

    static func duration(_ seconds: Int) -> String {
        seconds >= 120 ? "\(seconds / 60) min" : "\(max(seconds, 0)) s"
    }
}

import AppKit
import ContinuumRevivedAgentContent

/// Main-thread visual update gate. Streaming producers may submit many semantic
/// snapshots, but the list is presented at most once per display interval.
@MainActor
final class AgentTranscriptUpdateScheduler {
    static let maximumVisualUpdatesPerSecond = 30
    private let interval: TimeInterval = 1.0 / 30.0
    private var timer: Timer?
    private var pending: (() -> Void)?
    private(set) var visualApplyCount = 0
    /// QA: every visual apply, across all transcripts.
    static private(set) var qaTotalVisualApplies = 0

    /// Whether an apply now would be seen. A transcript scrolled off the canvas or
    /// parked keeps its latest snapshot and looks again later, so an agent
    /// streaming out of view costs no layout or text measurement. Measured with 8
    /// agents streaming (`.plans/84`, benchmark): visual applies were a quarter of
    /// the main thread, half of them for tiles nobody could see.
    var isPresentable: (() -> Bool)?
    /// How soon an unseen transcript looks again; it bounds how stale a tile panned
    /// into view can be.
    static let unseenRecheckInterval: TimeInterval = 0.25
    /// QA: timed applies skipped because the transcript was not on screen.
    static private(set) var qaUnseenDeferrals = 0

    func schedule(_ update: @escaping () -> Void, final: Bool = false) {
        pending = update // latest snapshot wins; semantic source remains authoritative
        if ProcessInfo.processInfo.environment["CONTINUUM_P3_11_NEGATIVE_WITNESS"] == "1" {
            // Deterministic fault injection: recreates one visual apply per token
            // so the 5,000-delta geometry bound must fail red.
            flush()
        } else if final {
            flush()
        } else {
            armTimer()
        }
    }

    /// A transcript off screen keeps its latest snapshot and looks again shortly,
    /// applying once it can be seen: nobody can see the layout it would pay for.
    private func flushUnlessHeld() {
        if pending != nil, let isPresentable, !isPresentable() {
            Self.qaUnseenDeferrals += 1
            armTimer(after: Self.unseenRecheckInterval)
            return
        }
        flush()
    }

    func flush() {
        timer?.invalidate()
        timer = nil
        guard let update = pending else { return }
        pending = nil
        visualApplyCount += 1
        Self.qaTotalVisualApplies += 1
        update()
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        pending = nil
    }

    private func armTimer(after delay: TimeInterval? = nil) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: delay ?? interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.timer = nil
                self?.flushUnlessHeld()
            }
        }
    }
}

import Foundation

/// Runs `action` on the main queue at most once per window, within `delay` of
/// the FIRST request since it last ran.
///
/// The sidebar's agent-surface push used a trailing debounce instead: every
/// request cancelled the pending push and restarted the 0.5 s wait. Streamed
/// agent activity arrives faster than that, so while an agent streamed the push
/// never ran, and a parent dispatching subagents showed its stack only once the
/// stream paused (.plans/81-live-performance). A request here never moves a
/// pending run later; a shorter one may pull it earlier.
@MainActor
final class CoalescedPush {
    typealias Schedule = (_ deadline: DispatchTime, _ work: DispatchWorkItem) -> Void

    private let now: () -> DispatchTime
    private let schedule: Schedule
    private let action: () -> Void
    private var pending: (deadline: DispatchTime, work: DispatchWorkItem)?

    init(
        now: @escaping () -> DispatchTime = { .now() },
        schedule: @escaping Schedule = { DispatchQueue.main.asyncAfter(deadline: $0, execute: $1) },
        action: @escaping () -> Void
    ) {
        self.now = now
        self.schedule = schedule
        self.action = action
    }

    func request(within delay: TimeInterval) {
        let deadline = now() + delay
        if let pending, pending.deadline <= deadline { return }
        pending?.work.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = nil
                self.action()
            }
        }
        pending = (deadline, work)
        schedule(deadline, work)
    }
}

/// `--sidebar-push-coalescing-check`: a stream of requests every 100 ms must
/// still push within the 0.5 s window, on a simulated clock.
enum CoalescedPushChecks {
    @MainActor
    static func run() throws -> String {
        struct Failure: Error, CustomStringConvertible { let description: String }
        var clock = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        var queued: [(deadline: DispatchTime, work: DispatchWorkItem)] = []
        var pushes: [Double] = []
        let start = clock
        func seconds(_ time: DispatchTime) -> Double {
            Double(time.uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        }
        let push = CoalescedPush(
            now: { clock },
            schedule: { queued.append(($0, $1)) },
            action: { pushes.append(seconds(clock)) })
        func advance(to target: DispatchTime) {
            while let next = queued.filter({ !$0.work.isCancelled && $0.deadline <= target })
                .min(by: { $0.deadline < $1.deadline }) {
                clock = next.deadline
                queued.removeAll { $0.work === next.work }
                next.work.perform()
            }
            clock = target
        }

        // An agent streaming for 3 s, one activity event every 100 ms.
        for step in 0..<30 {
            advance(to: start + .milliseconds(step * 100))
            push.request(within: 0.5)
        }
        advance(to: start + .milliseconds(3_000))
        guard let first = pushes.first, first <= 0.5 + 1e-9 else {
            throw Failure(description: "a 3 s stream of activity every 100 ms first pushed the sidebar at "
                + "\(pushes.first.map { String(format: "%.2f s", $0) } ?? "never") — it must push within 0.5 s")
        }
        guard pushes.count >= 5 else {
            throw Failure(description: "a 3 s stream pushed the sidebar \(pushes.count) times — it must keep pushing about every 0.5 s")
        }
        // A burst still coalesces: ten requests inside one window push once.
        let before = pushes.count
        for step in 0..<10 {
            advance(to: start + .milliseconds(5_000 + step * 10))
            push.request(within: 0.5)
        }
        advance(to: start + .milliseconds(6_000))
        guard pushes.count - before == 1 else {
            throw Failure(description: "ten requests inside one window pushed \(pushes.count - before) times — they must coalesce into one")
        }
        // A shorter request pulls a pending push earlier and never later.
        advance(to: start + .milliseconds(7_000))
        push.request(within: 0.5)
        push.request(within: 0.05)
        advance(to: start + .milliseconds(7_100))
        guard let last = pushes.last, abs(last - 7.05) < 1e-6 else {
            throw Failure(description: "a 50 ms request behind a pending 0.5 s push fired at \(pushes.last.map { String(format: "%.3f s", $0) } ?? "never") — it must pull the push to 7.050 s")
        }
        return String(format: "SidebarPushCoalescingChecks passed: a 3 s stream first pushed at %.2f s and %d times in all; a burst coalesced into one push", first, before)
    }
}

import ContinuumRevivedCore
import Foundation

/// Session-only leases. Runtime lookup stays dynamic so a replaced or evicted
/// WebKit view is never held alive by the ledger.
@MainActor
final class BrowserLeaseLedger {
    static let duration: TimeInterval = 10 * 60
    static let idleSweepDuration: TimeInterval = 30 * 60
    typealias ExpiryScheduler = (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private struct Lease {
        let owner: AgentID
        var lastAction: Date?
        var timerId: UUID?
        var sweepSince: Date?
        var sweepTimerId: UUID?
    }
    var onEngagementChanged: ((UUID, AgentID, Bool) -> Void)?
    private var leases: [UUID: Lease] = [:]
    private var observedTurnState: [AgentID: Bool] = [:]
    private let runtime: @MainActor (UUID) -> WKWebViewBrowserRuntime?
    private let isRunning: @MainActor (AgentID) -> Bool
    private let now: @MainActor () -> Date
    private let scheduleExpiry: ExpiryScheduler
    private let scheduleSweep: ExpiryScheduler
    private let closeIdle: @MainActor (UUID, AgentID) -> Bool

    init(runtime: @escaping @MainActor (UUID) -> WKWebViewBrowserRuntime?,
         isRunning: @escaping @MainActor (AgentID) -> Bool,
         now: @escaping @MainActor () -> Date = Date.init,
         scheduleExpiry: @escaping ExpiryScheduler = { delay, callback in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) { callback() }
         },
         scheduleSweep: @escaping ExpiryScheduler = { delay, callback in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) { callback() }
         },
         closeIdle: @escaping @MainActor (UUID, AgentID) -> Bool = { _, _ in false }) {
        self.runtime = runtime
        self.isRunning = isRunning
        self.now = now
        self.scheduleExpiry = scheduleExpiry
        self.scheduleSweep = scheduleSweep
        self.closeIdle = closeIdle
    }

    /// Track a host-verified owner on hydration, before its first action.
    @discardableResult
    func track(tileId: UUID, owner: AgentID, sweepEligible: Bool = false) -> Bool {
        if let lease = leases[tileId], lease.owner != owner { return false }
        guard let browser = runtime(tileId), !browser.isTerminated else { return false }
        if leases[tileId] == nil { leases[tileId] = Lease(owner: owner, lastAction: nil, timerId: nil, sweepSince: nil, sweepTimerId: nil) }
        if sweepEligible, leases[tileId]?.sweepSince == nil {
            leases[tileId]?.sweepSince = now()
            scheduleSweepTimer(tileId, after: Self.idleSweepDuration)
        }
        refresh(tileId)
        return true
    }

    /// A successful admission to the action path renews the lease.
    @discardableResult
    func touch(tileId: UUID, owner: AgentID, sweepEligible: Bool = false) -> Bool {
        guard track(tileId: tileId, owner: owner, sweepEligible: sweepEligible) else { return false }
        if sweepEligible { leases[tileId]?.sweepSince = now() }
        leases[tileId]?.lastAction = now()
        refresh(tileId)
        // One timer per tile, even when an agent makes many actions. When it
        // fires it reschedules only the remaining time after a renewal.
        if leases[tileId]?.timerId == nil { scheduleTimer(tileId, after: Self.duration) }
        return true
    }

    func protectedTileIds() -> Set<UUID> {
        Set(leases.compactMap { id, lease in held(lease) && runtime(id)?.isTerminated == false ? id : nil })
    }

    func runningTileIds() -> Set<UUID> {
        Set(leases.compactMap { id, lease in
            (observedTurnState[lease.owner] ?? isRunning(lease.owner)) && runtime(id)?.isTerminated == false ? id : nil
        })
    }

    /// Call when the supervisor reports a turn start/end; no residency polling.
    func agentStatusChanged(_ owner: AgentID) {
        for (tileId, lease) in leases where lease.owner == owner {
            refresh(tileId)
            if !(observedTurnState[owner] ?? isRunning(owner)), let since = lease.sweepSince, lease.sweepTimerId == nil {
                scheduleSweepTimer(tileId, after: max(0, Self.idleSweepDuration - now().timeIntervalSince(since)))
            }
        }
    }

    /// Supervisor events are authoritative even before the runner is retired.
    @discardableResult
    func observeTurn(_ owner: AgentID, running: Bool) -> Bool {
        guard leases.values.contains(where: { $0.owner == owner }) else { return false }
        observedTurnState[owner] = running
        agentStatusChanged(owner)
        return true
    }

    func release(tileId: UUID) {
        let owner = leases.removeValue(forKey: tileId)?.owner
        if let browser = runtime(tileId), !browser.isTerminated {
            browser.automation.isEngaged = false
        }
        if let owner { onEngagementChanged?(tileId, owner, false) }
        if let owner, !leases.values.contains(where: { $0.owner == owner }) {
            observedTurnState[owner] = nil
        }
    }

    private func scheduleSweepTimer(_ tileId: UUID, after delay: TimeInterval) {
        let timerId = UUID()
        leases[tileId]?.sweepTimerId = timerId
        scheduleSweep(delay) { [weak self] in self?.sweepTimerFired(tileId, timerId: timerId) }
    }

    private func sweepTimerFired(_ tileId: UUID, timerId: UUID) {
        guard let lease = leases[tileId], lease.sweepTimerId == timerId, let since = lease.sweepSince else { return }
        leases[tileId]?.sweepTimerId = nil
        let remaining = Self.idleSweepDuration - now().timeIntervalSince(since)
        if remaining > 0 { scheduleSweepTimer(tileId, after: remaining); return }
        guard !(observedTurnState[lease.owner] ?? isRunning(lease.owner)) else { return }
        if closeIdle(tileId, lease.owner) {
            release(tileId: tileId)
        } else if leases[tileId]?.sweepSince != nil {
            // A focused tile or an unavailable project may become eligible later.
            scheduleSweepTimer(tileId, after: 5 * 60)
        }
    }

    private func scheduleTimer(_ tileId: UUID, after delay: TimeInterval) {
        let timerId = UUID()
        leases[tileId]?.timerId = timerId
        scheduleExpiry(delay) { [weak self] in self?.timerFired(tileId, timerId: timerId) }
    }

    private func timerFired(_ tileId: UUID, timerId: UUID) {
        guard let lease = leases[tileId], lease.timerId == timerId else { return }
        if let lastAction = lease.lastAction {
            let remaining = Self.duration - now().timeIntervalSince(lastAction)
            if remaining > 0 {
                scheduleTimer(tileId, after: min(remaining, Self.duration))
                return
            }
        }
        leases[tileId]?.timerId = nil
        refresh(tileId)
    }

    private func held(_ lease: Lease) -> Bool {
        (observedTurnState[lease.owner] ?? isRunning(lease.owner)) || lease.lastAction.map { now().timeIntervalSince($0) < Self.duration } == true
    }

    private func refresh(_ tileId: UUID) {
        guard let lease = leases[tileId], let browser = runtime(tileId), !browser.isTerminated else { return }
        let engaged = held(lease)
        if browser.automation.isEngaged != engaged {
            browser.automation.isEngaged = engaged
            onEngagementChanged?(tileId, lease.owner, engaged)
        }
    }
}

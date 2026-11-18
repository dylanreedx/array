import AppKit
import ContinuumRevivedCore

/// One answer to "may non-visual main-thread work run right now?".
///
/// While the camera moves or a geometry gesture is active (the signals
/// `CanvasNSView.isCameraInMotion` / `isGeometryGestureActive` already own), work
/// that is not on screen waits and runs in order once the gesture has ended. That
/// is transcript ingest for agents nobody can see, sidebar pushes, FSEvents
/// callbacks, the canvas-save snapshot and the markup timers of hidden tiles.
///
/// Rules every caller keeps:
/// - Nothing is lost or reordered. A caller that holds events keeps them in its
///   own FIFO and flushes that FIFO, in order, before it applies anything newer.
/// - Visible work is never deferred. Only callers whose subject is not on screen
///   ask `agentIsVisible`, and a visible agent streams exactly as before.
/// - Boundaries (turn end, requests, errors) are never held: the caller flushes
///   its backlog and applies the boundary at once.
///
/// No pending work, no timer: the settle poll runs only while something waits.
@MainActor
final class FrameGovernor {
    static let shared = FrameGovernor()

    /// A witness switch: off, every `shouldDefer()` answers false (the pre-governor
    /// behaviour), so one binary can measure both arms.
    var isEnabled = true
    /// Seconds of quiet after the last gesture signal before the backlog drains.
    var settleDelay: TimeInterval = 0.15

    private var interactionProvider: (() -> Bool)?
    private var visibleAgentsProvider: (() -> Set<AgentID>)?
    private var lastActiveUptime: TimeInterval = -.infinity
    private var visibleCache: (uptime: TimeInterval, ids: Set<AgentID>)?
    private let visibleCacheLifetime: TimeInterval = 0.1

    private struct Hook { let owner: ObjectIdentifier; let run: () -> Void }
    private var drainHooks: [Hook] = []
    private var keyedWork: [(key: AnyHashable, work: () -> Void)] = []
    private var settleTimer: Timer?
    private var draining = false

    // QA tallies for `--gesture-defer-check`.
    private(set) var qaDeferredCount = 0
    private(set) var qaDrainedCount = 0
    private(set) var qaDrainCount = 0
    var qaHasPending: Bool { !keyedWork.isEmpty || pendingOwners > 0 }
    private var pendingOwners = 0

    /// Binds the signals to one canvas. Weak: the canvas may go away.
    func adopt(canvas: CanvasNSView) {
        interactionProvider = { [weak canvas] in
            guard let canvas else { return false }
            return canvas.isCameraInMotion || canvas.isGeometryGestureActive
        }
        visibleAgentsProvider = { [weak canvas] in
            guard let canvas else { return [] }
            return Set(canvas.visibleTileViews.compactMap { ($0 as? ManagedAgentTileNSView)?.attachedAgentID })
        }
        visibleCache = nil
    }

    /// True while a gesture is active, and for `settleDelay` after the last
    /// moment it was seen active while work still waits (so work that arrives
    /// between the gesture's end and the drain cannot overtake the backlog).
    func shouldDefer() -> Bool {
        guard isEnabled, let interactionProvider else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if interactionProvider() {
            lastActiveUptime = now
            return true
        }
        return qaHasPending && now - lastActiveUptime < settleDelay
    }

    /// Whether the agent has a tile on screen. Cached for 100 ms: the visible set
    /// changes at pan speed, an event arrives per delta.
    func agentIsVisible(_ id: AgentID) -> Bool {
        guard let visibleAgentsProvider else { return true }
        let now = ProcessInfo.processInfo.systemUptime
        if let cache = visibleCache, now - cache.uptime < visibleCacheLifetime { return cache.ids.contains(id) }
        let ids = visibleAgentsProvider()
        visibleCache = (now, ids)
        return ids.contains(id)
    }

    /// Keyed, latest wins: the work runs once at the drain, in the order its key
    /// was first deferred. Returns false (run it now) when no gesture is active.
    @discardableResult
    func deferKeyed(_ key: AnyHashable, _ work: @escaping () -> Void) -> Bool {
        guard shouldDefer() else { return false }
        if let index = keyedWork.firstIndex(where: { $0.key == key }) {
            keyedWork[index].work = work
        } else {
            keyedWork.append((key, work))
        }
        qaDeferredCount += 1
        armSettlePoll()
        return true
    }

    /// An owner keeping its own ordered backlog says so here, so the poll runs and
    /// `run` is called at the drain. Registering twice for one owner is one hook.
    func noteDeferred(owner: AnyObject, run: @escaping () -> Void) {
        qaDeferredCount += 1
        let id = ObjectIdentifier(owner)
        if !drainHooks.contains(where: { $0.owner == id }) { drainHooks.append(Hook(owner: id, run: run)) }
        pendingOwners = drainHooks.count
        armSettlePoll()
    }

    /// An owner flushed its backlog on its own (a boundary, a read, visibility).
    func noteFlushed(owner: AnyObject, count: Int) {
        qaDrainedCount += count
        drainHooks.removeAll { $0.owner == ObjectIdentifier(owner) }
        pendingOwners = drainHooks.count
        if !qaHasPending { settleTimer?.invalidate(); settleTimer = nil }
    }

    private func armSettlePoll() {
        guard settleTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollSettled() }
        }
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    private func pollSettled() {
        guard !shouldDefer() else { return }
        settleTimer?.invalidate()
        settleTimer = nil
        drain()
    }

    /// Runs everything that waited: owners' backlogs first (each in its own main
    /// hop, so a display tick can land between two agents' flushes), then keyed work.
    func drain() {
        guard !draining else { return }
        draining = true
        qaDrainCount += 1
        let hooks = drainHooks
        drainHooks.removeAll()
        pendingOwners = 0
        let keyed = keyedWork
        keyedWork.removeAll()
        qaDrainedCount += keyed.count
        var index = 0
        func step() {
            if index < hooks.count {
                let hook = hooks[index]
                index += 1
                hook.run()
                DispatchQueue.main.async { MainActor.assumeIsolated { step() } }
            } else {
                for item in keyed { item.work() }
                draining = false
                if qaHasPending { armSettlePoll() }
            }
        }
        step()
    }

    /// QA: the governor's state back to a fresh one for the next arm.
    func qaReset() {
        settleTimer?.invalidate(); settleTimer = nil
        drainHooks.removeAll(); keyedWork.removeAll(); pendingOwners = 0
        qaDeferredCount = 0; qaDrainedCount = 0; qaDrainCount = 0
        lastActiveUptime = -.infinity; visibleCache = nil; draining = false
    }
}

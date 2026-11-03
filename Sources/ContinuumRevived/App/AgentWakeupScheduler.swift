import Foundation
import ContinuumRevivedCore

/// Array owns these timers. Native Claude Cron jobs remain CLI-owned; they
/// are never copied here, which would deliver two copies of every wakeup.
@MainActor
final class AgentWakeupScheduler {
    let store: AgentWakeupScheduleStore
    weak var owner: AgentSupervisor?
    private var timer: Timer?
    private var ticking = false
    private var stopped = false

    init(store: AgentWakeupScheduleStore, owner: AgentSupervisor) {
        self.store = store; self.owner = owner
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                do { try await self?.tick() }
                catch { self?.owner?.scheduleDeliveryFailed(error) }
            }
        }
    }

    isolated deinit { timer?.invalidate() }

    func stop() { stopped = true; timer?.invalidate(); timer = nil }

    func tick(now: Date = Date()) async throws {
        guard !stopped, !ticking, let owner else { return }
        ticking = true
        defer { ticking = false }
        for original in store.entries {
            guard !stopped, let saved = store.entries.first(where: { $0.id == original.id }),
                  owner.canDeliverScheduledWakeup(to: saved.agent) else { continue }
            var job = saved
            if job.pendingDelivery == nil {
                guard let due = job.nextFireAt, due <= now else { continue }
                // One outstanding wakeup per schedule. Missed intervals coalesce.
                if let last = job.lastEnqueued, await owner.hasQueuedWakeup(last, for: job.agent) { continue }
                guard store.entries.contains(job) else { continue }
                job.pendingDelivery = UUID()
                job.nextFireAt = job.intervalSeconds.map { now.addingTimeInterval($0) }
                try replace(job)
            }
            guard let occurrence = job.pendingDelivery else { continue }
            // Durable outbox precedes durable queue. Nothing drains before the
            // receipt is saved, so a restart can retry with this same message id.
            try await owner.stageScheduledWakeup(occurrence, text: job.prompt, for: job.agent)
            guard !stopped else { return }
            guard let current = store.entries.first(where: { $0.id == job.id }), current.pendingDelivery == occurrence else {
                await owner.discardScheduledWakeup(occurrence, for: job.agent)
                continue
            }
            job.pendingDelivery = nil; job.lastEnqueued = occurrence
            try replace(job)
            owner.finishScheduledAdmission(occurrence)
            await owner.releaseScheduledWakeups(for: job.agent, knownIDs: knownIDs(for: job.agent))
        }
        // Includes the crash window after queue receipt but before queue drain.
        for agent in Set(store.entries.map(\.agent)) where owner.canDeliverScheduledWakeup(to: agent) {
            await owner.releaseScheduledWakeups(for: agent, knownIDs: knownIDs(for: agent))
        }
    }

    private func replace(_ job: AgentWakeupSchedule) throws {
        try store.replace(store.entries.map { $0.id == job.id ? job : $0 })
    }

    private func knownIDs(for agent: AgentID) -> Set<UUID> {
        Set(store.entries.filter { $0.agent == agent }.flatMap { [$0.pendingDelivery, $0.lastEnqueued].compactMap { $0 } })
    }
}

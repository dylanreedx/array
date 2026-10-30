import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// Lives with the publishing host session, not a tile/window. Only explicit
/// local publication bindings are eligible; no prompt, path or transcript leaves.
@MainActor
final class SharedAreaUsageCollector {
    private let supervisor: AgentSupervisor
    private let bindings: () -> [SharedAreaLocalSourceBinding]
    private let ledger: SharedAreaUsageLedger
    private let startedAt: Date
    private var observer: UUID?
    private var normalizers: [AgentID: SharedAreaUsageNormalizer] = [:]
    /// Codex threads of the agents published when observation began. An agent
    /// published later has no entry, so its first total is never attributed today.
    private var sessionsAtStart: [AgentID: String?] = [:]
    private var knownReporting: Set<AgentID> = []
    private var queue: Task<Void, Never>?
    private(set) var lastError: (any Error)?
    var onChange: (() -> Void)?

    init(supervisor: AgentSupervisor, bindings: @escaping () -> [SharedAreaLocalSourceBinding],
         directory: URL, host: SharedArea.ID<SharedArea.Host>, now: Date = Date()) throws {
        self.supervisor = supervisor; self.bindings = bindings; self.startedAt = now
        ledger = try SharedAreaUsageLedger(directory: directory, host: host)
        for id in ownedAgents() { sessionsAtStart[id] = supervisor.records[id]?.codexThreadId }
        observer = supervisor.addDeliveredEventObserver { [weak self] id, event in self?.receive(id, event) }
    }
    func stop() {
        if let observer { supervisor.removeDeliveredEventObserver(observer) }
        observer = nil
    }
    func settle() async { await queue?.value }
    func snapshot() async throws -> Collaboration.UsageSnapshot {
        await queue?.value
        let agents = ownedAgents(), running = agents.filter { supervisor.isRunning($0) }.count
        let partial = lastError != nil || !agents.isSubset(of: knownReporting)
        let ledger = ledger
        return try await Task.detached {
            try ledger.snapshot(coveredAgents: agents.count, runningAgents: running, partial: partial)
        }.value
    }
    private func ownedAgents() -> Set<AgentID> {
        Set(bindings().compactMap { binding in
            guard let id = binding.agentID, let record = supervisor.records[id], record.projectId == binding.projectID else { return nil }
            return id
        })
    }
    private func receive(_ id: AgentID, _ event: AgentRuntimeEvent) {
        guard ownedAgents().contains(id), let record = supervisor.records[id] else { return }
        let sessionAtStart: String? = if let known = sessionsAtStart[id] { known } else { record.codexThreadId ?? "published-later" }
        var normalizer = normalizers[id] ?? SharedAreaUsageNormalizer(source: id.rawValue.uuidString,
            harness: record.harness, startedAt: startedAt, providerSessionAtStart: sessionAtStart)
        defer { normalizers[id] = normalizer }
        switch event {
        case .turnStarted(_, let turn):
            normalizer.turnStarted(turn)
        case .tokenUsageUpdated(let thread, let value):
            switch normalizer.usage(value, providerSession: record.codexThreadId, thread: thread,
                                    latestTurnAt: record.latestTurnAt, receivedAt: Date()) {
            case nil: return
            case .unattributable?:
                lastError = SharedAreaUsageLedger.Failure.invalidObservation; onChange?()
            case .record(let observation)?:
                let prior = queue, ledger = ledger
                queue = Task { [weak self] in
                    await prior?.value
                    do {
                        _ = try await Task.detached { try ledger.record(observation) }.value
                        self?.knownReporting.insert(id)
                    } catch { self?.lastError = error }
                    self?.onChange?()
                }
            }
        default: break
        }
    }
}

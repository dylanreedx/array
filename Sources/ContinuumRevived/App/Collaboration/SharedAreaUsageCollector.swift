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
    private var currentTurns: [AgentID: String] = [:]
    private var freshTurns: Set<AgentID> = []
    private var newCodexSessions: Set<AgentID> = []
    private var knownReporting: Set<AgentID> = []
    private var queue: Task<Void, Never>?
    private(set) var lastError: (any Error)?
    var onChange: (() -> Void)?

    init(supervisor: AgentSupervisor, bindings: @escaping () -> [SharedAreaLocalSourceBinding],
         directory: URL, host: SharedArea.ID<SharedArea.Host>, now: Date = Date()) throws {
        self.supervisor = supervisor; self.bindings = bindings; self.startedAt = now
        ledger = try SharedAreaUsageLedger(directory: directory, host: host)
        for id in ownedAgents() where supervisor.records[id]?.codexThreadId == nil { newCodexSessions.insert(id) }
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
        switch event {
        case .turnStarted(_, let turn):
            currentTurns[id] = turn; freshTurns.insert(id)
        case .tokenUsageUpdated(let thread, let value):
            guard value.inputTokens >= 0, value.outputTokens >= 0 else { return }
            let source = id.rawValue.uuidString
            let counter: String
            let initialToday: Bool
            switch record.harness {
            case .some(.codex):
                counter = SharedAreaUsageLedger.privateCounter(["codex", record.codexThreadId ?? thread])
                initialToday = newCodexSessions.contains(id)
            case .some(.claudeCode):
                let turn = currentTurns[id] ?? record.latestTurnAt.map { String($0.timeIntervalSince1970) } ?? "unattributed"
                counter = SharedAreaUsageLedger.privateCounter([source, "claude", turn])
                initialToday = freshTurns.contains(id)
            case .some(.pi):
                guard let message = value.accountingObservationID else {
                    lastError = SharedAreaUsageLedger.Failure.invalidObservation; onChange?(); return
                }
                counter = SharedAreaUsageLedger.privateCounter([source, "pi", message])
                initialToday = value.observedAt.map { $0 >= startedAt } ?? freshTurns.contains(id)
            case nil:
                lastError = SharedAreaUsageLedger.Failure.invalidObservation; onChange?(); return
            }
            let input = value.accountingInputTokens ?? value.inputTokens
            guard input >= 0 else { return }
            let observation = SharedAreaUsageLedger.Observation(counter: counter, input: UInt64(input), output: UInt64(value.outputTokens),
                observedAt: value.observedAt ?? Date(), initialBelongsToToday: initialToday)
            let prior = queue, ledger = ledger
            queue = Task { [weak self] in
                await prior?.value
                do {
                    _ = try await Task.detached { try ledger.record(observation) }.value
                    self?.knownReporting.insert(id)
                } catch { self?.lastError = error }
                self?.onChange?()
            }
        default: break
        }
    }
}

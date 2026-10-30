import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

@MainActor
enum SharedAreaUsageCollectorChecks {
    private struct Failure: Error { let message: String }
    static func run() async throws {
        guard let support = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] else {
            throw Failure(message: "isolated support required")
        }
        let root = URL(fileURLWithPath: support).appendingPathComponent("usage-provider-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("agents"))
        let ids = [AgentID(rawValue: UUID()), AgentID(rawValue: UUID())], project = UUID()
        for id in ids {
            var record = AgentRecord(id: id, displayName: "Usage fixture", harness: .codex,
                model: "scripted/usage", thinking: "none", cwd: root.path, projectId: project,
                createdAt: Date(), lastActivityAt: Date())
            record.codexThreadId = "same-provider-session"
            try store.upsert(record)
        }
        var executors = 0
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in
            executors += 1; return ScriptedAgentRunner(script: [])
        })
        _ = supervisor.restore()
        let host = SharedArea.ID<SharedArea.Host>()
        let bindings = ids.map { SharedAreaLocalSourceBinding(object: .init(), binding: .init(), host: host,
            projectID: project, agentID: $0) }
        let collector = try SharedAreaUsageCollector(supervisor: supervisor, bindings: { bindings }, directory: root, host: host)
        defer { collector.stop() }
        for id in ids {
            supervisor.qaDeliver(.tokenUsageUpdated(threadId: AgentSupervisor.threadId(for: id),
                snapshot: .init(inputTokens: 100, outputTokens: 20, totalCostUsd: nil)), to: id)
        }
        supervisor.qaDeliver(.tokenUsageUpdated(threadId: AgentSupervisor.threadId(for: ids[1]),
            snapshot: .init(inputTokens: 140, outputTokens: 40, totalCostUsd: nil)), to: ids[1])
        let value = try await collector.snapshot()
        guard value.inputTokens == 140, value.outputTokens == 40, value.coveredAgents == 2,
              value.partial, executors == 0 else {
            throw Failure(message: "two local records duplicated one cumulative provider session")
        }
        print("PASS usage provider adapter: two published records of one Codex session share a durable high-water counter without another executor")
        // The session's cumulative total then goes DOWN in a newer report (a
        // counter reset): the lower value is the new baseline, so later growth
        // counts once and nothing is subtracted or re-added.
        supervisor.qaDeliver(.tokenUsageUpdated(threadId: AgentSupervisor.threadId(for: ids[0]),
            snapshot: .init(inputTokens: 30, outputTokens: 5, totalCostUsd: nil)), to: ids[0])
        supervisor.qaDeliver(.tokenUsageUpdated(threadId: AgentSupervisor.threadId(for: ids[0]),
            snapshot: .init(inputTokens: 70, outputTokens: 9, totalCostUsd: nil)), to: ids[0])
        let reset = try await collector.snapshot()
        guard reset.inputTokens == 180, reset.outputTokens == 44, reset.partial else {
            throw Failure(message: "a Codex counter reset counted \(reset.inputTokens)/\(reset.outputTokens), want 180/44 and partial")
        }
        print("PASS usage provider adapter: a Codex counter reset re-baselines through the production collector (180 / 44, partial)")
    }
}

import ContinuumRevivedCore
import Foundation

/// Exercises the real supervisor's quota observation fan-out. A quota belongs
/// to the account the emitting agent is using, including a live runner still
/// finishing on its old account during a switch.
@MainActor
final class AgentQuotaFanoutProbe {
    struct Failure: Error, CustomStringConvertible { let description: String }

    private let supervisor: AgentSupervisor
    private var counts: [AgentID: Int] = [:]
    private var tokens: [(AgentID, UUID)] = []

    init(supervisor: AgentSupervisor, agents: [AgentID]) {
        self.supervisor = supervisor
        for agent in agents { add(agent) }
    }

    func add(_ agent: AgentID) {
        counts[agent] = 0
        let token = supervisor.addRuntimeObservationObserver(for: agent) { [weak self] observation in
            guard case .accountQuota = observation else { return }
            self?.counts[agent, default: 0] += 1
        }
        tokens.append((agent, token))
    }

    func remove(_ agent: AgentID) {
        for (id, token) in tokens where id == agent { supervisor.removeRuntimeObservationObserver(token, for: id) }
        tokens.removeAll { $0.0 == agent }
    }

    func stop() {
        for (agent, token) in tokens { supervisor.removeRuntimeObservationObserver(token, for: agent) }
        tokens.removeAll()
    }

    func verify(source: AgentID, snapshot: AgentAccountQuotaSnapshot, expected: Set<AgentID>, label: String) throws {
        for id in counts.keys { counts[id] = 0 }
        supervisor.qaObserveSharedTranscript(.accountQuota(snapshot), for: source)
        let actual = Set(counts.compactMap { $0.value == 1 ? $0.key : nil })
        let unexpectedMultiplicity = counts.values.contains { $0 > 1 }
        guard actual == expected, !unexpectedMultiplicity else {
            throw Failure(description: "\(label): expected \(expected.count) matching observers, got \(actual.count); multiple delivery: \(unexpectedMultiplicity)")
        }
        for id in expected where supervisor.account(forAgent: id) != nil {
            guard supervisor.accountQuota(for: id) == snapshot else {
                throw Failure(description: "\(label): a matching observer did not see the stored account quota")
            }
        }
    }
}

/// Many unrelated agents must not receive the provider's quota observation;
/// every observer sharing its account still must. No provider process is run.
@MainActor
func runAgentQuotaFanoutChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("quota-fanout-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root.appendingPathComponent("support")))
    defer { supervisor.stopAll() }
    func spawn(_ harness: AgentHarness) -> AgentID {
        supervisor.spawn(role: nil, prompt: nil, cwd: root, harness: harness,
                         model: "fixture/exact-model", thinking: "low")
    }
    let first = spawn(.claudeCode), second = spawn(.claudeCode)
    let other = (0..<32).map { _ in spawn(.codex) }
    let pi = spawn(.pi)
    let probe = AgentQuotaFanoutProbe(supervisor: supervisor, agents: [first, second] + other + [pi])
    defer { probe.stop() }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let claude = AgentAccountQuotaSnapshot(harness: .claudeCode,
        windows: [.init(kind: .fiveHour, utilization: 0.2)], observedAt: now, source: .claudeUsageRequest)
    let codex = AgentAccountQuotaSnapshot(harness: .codex,
        windows: [.init(kind: .fiveHour, utilization: 0.3)], observedAt: now, source: .codexRateLimitsRead)
    let piQuota = AgentAccountQuotaSnapshot(harness: .pi,
        windows: [.init(kind: .fiveHour, utilization: 0.1)], observedAt: now, source: .unknown("fixture"))
    try probe.verify(source: first, snapshot: claude, expected: [first, second], label: "Claude quota")
    try probe.verify(source: other[0], snapshot: codex, expected: Set(other), label: "Codex quota")
    try probe.verify(source: first, snapshot: claude, expected: [first, second], label: "repeated Claude quota")
    guard supervisor.qaQuotaLastRoutingInspections == 2 else {
        throw AgentQuotaFanoutProbe.Failure(description: "steady Claude quota must inspect only its two recipients; inspected \(supervisor.qaQuotaLastRoutingInspections)")
    }
    try probe.verify(source: pi, snapshot: piQuota, expected: [pi], label: "quota from a provider without an account mapping")
    let newAgent = spawn(.claudeCode)
    probe.add(newAgent)
    try probe.verify(source: first, snapshot: claude, expected: [first, second, newAgent], label: "new same-account observer")
    let afterAddInspections = supervisor.qaQuotaLastRoutingInspections
    try probe.verify(source: first, snapshot: claude, expected: [first, second, newAgent], label: "stable quota after observer addition")
    guard supervisor.qaQuotaLastRoutingInspections == 3 else {
        throw AgentQuotaFanoutProbe.Failure(description: "steady quota after addition must inspect its three recipients")
    }
    probe.remove(newAgent)
    try probe.verify(source: first, snapshot: claude, expected: [first, second], label: "removed observer")
    let afterRemoveInspections = supervisor.qaQuotaLastRoutingInspections
    try probe.verify(source: first, snapshot: claude, expected: [first, second], label: "stable quota after observer removal")
    guard supervisor.qaQuotaLastRoutingInspections == 2 else {
        throw AgentQuotaFanoutProbe.Failure(description: "steady quota after removal must inspect its two recipients")
    }
    print("Agent quota fan-out checks passed: 35 callbacks → 2 for Claude; steady 2 routing inspections, first after add/remove \(afterAddInspections)/\(afterRemoveInspections)")
}

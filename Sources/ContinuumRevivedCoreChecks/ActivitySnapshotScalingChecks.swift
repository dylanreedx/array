import Foundation
import ContinuumRevivedCore

private struct SnapshotScalingFailure: Error, CustomStringConvertible { let description: String }

/// Live-usage profile, 2026-11-12 (.plans/110-native-refresh-inventory/MORNING.md,
/// cost #3): the activity fold copied the whole per-agent dictionary for every
/// event, because each caller still held the snapshot it passed in. With 2,228
/// agents that made a rebuild (`AgentInventory.snapshot`, run by every structural
/// sidebar refresh and every app switch) quadratic in agents, and every live
/// event (`AgentsBoardProjection.appendLocal`) linear in them.
///
/// Measured as SCALING, not as a fixed budget: the same work at 4× the agents.
/// Linear costs about 4× for the rebuild and about 1× per event; the copying
/// fold measured 8–9× and 3–4× in a debug build (the quadratic part is not yet
/// dominant at 575 agents), the in-place one about 4.5× and 1×.
func runActivitySnapshotScalingChecks() throws -> String {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let replica = UUID()
    func records(_ count: Int) -> [AgentRecord] {
        (0..<count).map { index in
            AgentRecord(
                id: AgentID(rawValue: UUID()), displayName: "Agent \(index)",
                model: AgentModelConfig.defaultModel, thinking: AgentModelConfig.defaultThinking,
                cwd: "/tmp/qa", createdAt: now, lastActivityAt: now, tileId: nil)
        }
    }
    func best(_ runs: Int = 5, _ body: () -> Void) -> Double {
        (0..<runs).map { _ in
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }.min() ?? 0
    }

    // 1 · A full rebuild, as `rebuildAgentActivitySnapshot` calls it.
    let small = records(575), large = records(2_300)
    func rebuild(_ agents: [AgentRecord]) -> ActivityLogSnapshot {
        AgentInventory.snapshot(
            terminalDescriptors: [], liveStatuses: [:], agents: agents,
            activityByAgent: [:], replicaId: replica, now: now)
    }
    let rebuildSmall = best { _ = rebuild(small) }
    let rebuildLarge = best { _ = rebuild(large) }
    let rebuildRatio = rebuildLarge / max(rebuildSmall, 0.001)
    guard rebuild(large).byAgent.count == large.count else {
        throw SnapshotScalingFailure(description: "fixture: the rebuild lost agents")
    }

    // 2 · Live events, as `ingestAgentActivityIncrementally` folds them: the app
    // also keeps the previous push's snapshot (`agentActivityChangeBase`).
    let events = 2_000
    func ingest(into seed: ActivityLogSnapshot, agents: [AgentRecord]) -> Double {
        best {
            var snapshot = seed
            let changeBase = snapshot
            for index in 0..<events {
                let draft = AgentActivityEventDraft(
                    agentId: agents[index % agents.count].id.rawValue, runId: nil, tone: .tool,
                    kind: "tool.bash", status: .working, summary: "Started bash",
                    occurredAt: now.addingTimeInterval(Double(index)))
                AgentsBoardProjection.appendLocal(draft, into: &snapshot, replicaId: replica)
            }
            precondition(changeBase.byAgent.count == agents.count && snapshot.snapshotSequence > changeBase.snapshotSequence)
        }
    }
    let ingestSmall = ingest(into: rebuild(small), agents: small)
    let ingestLarge = ingest(into: rebuild(large), agents: large)
    let ingestRatio = ingestLarge / max(ingestSmall, 0.001)

    let summary = String(
        format: "rebuild %.1f → %.1f ms (×%.1f for 4× agents); %d live events %.1f → %.1f ms (×%.1f)",
        rebuildSmall, rebuildLarge, rebuildRatio, events, ingestSmall, ingestLarge, ingestRatio)
    var failures: [String] = []
    if rebuildRatio > 6.5 { failures.append("a rebuild grows with agents²") }
    if ingestRatio > 2 { failures.append("a live event grows with the agent count") }
    guard failures.isEmpty else {
        throw SnapshotScalingFailure(description: "ActivitySnapshotScaling RED: " + failures.joined(separator: "; ") + " — " + summary)
    }
    return "ActivitySnapshotScalingChecks passed: " + summary
}

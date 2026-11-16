import ContinuumRevivedCore
import Foundation

/// `--agent-streaming-cost-check`: two calls a managed agent tile makes on every
/// streamed event, each measured against the work it used to repeat per call.
/// Both sides are timed in the same run, so a loaded Mac slows them together.
///
/// - The status row's detail text formatted its timestamp through a new
///   `ISO8601DateFormatter` per call (8% of the main thread at 24 agents).
/// - `CodexCLIBackend.transportOverride()` copied the whole process environment
///   to read one variable (2.5%).
func runAgentStreamingCostChecks() {
    let checkout = URL(fileURLWithPath: "/Users/example/continuum", isDirectory: true)
    let home = AgentHome(projectId: UUID(uuidString: "91000000-0000-4000-8000-000000000777")!,
                         projectRoot: checkout, checkoutRoot: checkout)
    let now = Date(timeIntervalSince1970: 1_800_000_000.75)
    let read = AgentObservedActivity(
        operation: .reading, targetPath: checkout.appendingPathComponent("Sources/Agent.swift"),
        startedAt: now, updatedAt: now, evidenceSource: .toolEvent)
    let snapshot = AgentLocationSnapshot(home: home, whereDirectory: checkout, what: read)

    // Same text as the formatter it replaced: GMT, whole seconds, `Z`.
    let presented = AgentLocationStatusPresenter.present(snapshot, projectName: "Continuum")
    let expectedStamp = ISO8601DateFormatter().string(from: now)
    expect(presented.detailText.contains(expectedStamp),
           "status detail must keep the ISO 8601 timestamp \(expectedStamp); got \(presented.detailText)")

    let presentCost = streamingCostNanos(200) {
        _ = AgentLocationStatusPresenter.present(snapshot, projectName: "Continuum")
    }
    let formatterCost = streamingCostNanos(200) { _ = ISO8601DateFormatter().string(from: now) }
    expect(presentCost < formatterCost * 0.5,
           "presenting a status with an activity must cost under half of building one ISO8601DateFormatter: "
           + "present \(Int(presentCost)) ns, formatter \(Int(formatterCost)) ns")

    // The override still answers from the live environment, and an explicit map wins.
    let key = "CONTINUUM_CODEX_TRANSPORT"
    let previous = getenv(key).map { String(cString: $0) }
    defer { if let previous { setenv(key, previous, 1) } else { unsetenv(key) } }
    setenv(key, "exec", 1)
    expect(CodexCLIBackend.transportOverride() == .exec, "a live CONTINUUM_CODEX_TRANSPORT=exec must select exec")
    expect(CodexCLIBackend.transportOverride(environment: [:]) == .appServer, "an explicit empty environment must win")
    unsetenv(key)
    expect(CodexCLIBackend.transportOverride() == .appServer, "no override must select the app server")

    let overrideCost = streamingCostNanos(2_000) { _ = CodexCLIBackend.transportOverride() }
    let environmentCost = streamingCostNanos(2_000) { _ = ProcessInfo.processInfo.environment }
    expect(overrideCost < environmentCost * 0.5,
           "reading the transport override must cost under half of one environment copy: "
           + "override \(Int(overrideCost)) ns, environment \(Int(environmentCost)) ns")

    print("Agent streaming cost checks passed: status present \(Int(presentCost)) ns vs formatter \(Int(formatterCost)) ns; "
          + "transport override \(Int(overrideCost)) ns vs environment copy \(Int(environmentCost)) ns")
}

/// Best of seven batches, nanoseconds per call.
private func streamingCostNanos(_ calls: Int, _ body: () -> Void) -> Double {
    var best = Double.infinity
    for _ in 0..<7 {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<calls { body() }
        best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / Double(calls))
    }
    return best
}

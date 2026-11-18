import ContinuumRevivedCore
import Foundation

/// `--agent-streaming-cost-check`: a call a managed agent tile makes on every
/// streamed event, measured against the work it used to repeat per call.
/// Both sides are timed in the same run, so a loaded Mac slows them together.
///
/// - `CodexCLIBackend.transportOverride()` copied the whole process environment
///   to read one variable (2.5%).
func runAgentStreamingCostChecks() {
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

    print("Agent streaming cost checks passed: transport override \(Int(overrideCost)) ns vs environment copy \(Int(environmentCost)) ns")
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

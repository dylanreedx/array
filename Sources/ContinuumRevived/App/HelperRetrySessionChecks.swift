import AppKit
import ContinuumRevivedCore
import Foundation

/// 2026-11-20: a lead's only restart tool, `array_delegate retryOf`, minted a
/// NEW agent (new session, new worktree) for a helper whose Claude session was
/// perfectly resumable, and left the old agent holding its queue and pause: a
/// later Resume would have run its held message beside the replacement.
///
/// Production supervisor, runner (scripted `claude` on PATH) and spawn path:
/// 1. the continuation `retryOf` performs on a failed helper with a session
///    (`canContinueSessionForRetry` + `continueSessionForRetry`, the two calls
///    the delegation service makes) runs THAT agent: same id, no new record,
///    the conversation resumed (`--resume`), the lead's new text delivered;
///    the service wiring itself is witnessed in `--workspace-api-delegation-check`;
/// 2. an eligibility refusal (another model asked) means a fresh helper, and
///    the supervisor's one spawn path supersedes the old one: it names its
///    replacement (persisted) and its queued messages are cancelled instead of
///    waiting for a Resume.
@MainActor
func runHelperRetrySessionChecks() async throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        guard condition else { throw Failure(description: "helper-retry-session: " + message()) }
    }
    func waitFor(_ message: @autoclosure () -> String, timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(description: "helper-retry-session: " + message())
    }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("helper-retry-session-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    let claudeBin = root.appendingPathComponent("claude-bin", isDirectory: true)
    _ = try AgentSteeringQAFakes.install(.claude, in: claudeBin)
    let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    setenv("PATH", "\(claudeBin.path):\(originalPath)", 1)
    defer { setenv("PATH", originalPath, 1) }
    let personalClaude = root.appendingPathComponent("personal-claude", isDirectory: true)
    try fm.createDirectory(at: personalClaude.appendingPathComponent("projects"), withIntermediateDirectories: true)
    let cwd = root.appendingPathComponent("project", isDirectory: true)
    try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
    let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("support", isDirectory: true))
    let supervisor = AgentSupervisor(
        store: store, makeRunner: AgentSupervisor.productionRunner,
        submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: root, debounceInterval: 0))
    supervisor.personalClaudeDirectory = personalClaude
    supervisor.personalCodexDirectory = root.appendingPathComponent("personal-codex", isDirectory: true)
    supervisor.accountUsageReader = { _ in nil }
    defer { supervisor.stopAll() }

    let model = "anthropic/claude-haiku-4-5-20251001"
    let lead = supervisor.spawn(role: nil, prompt: nil, cwd: cwd, harness: .claudeCode, model: model, thinking: "low")
    func helper(_ name: String) -> AgentID {
        supervisor.spawn(role: nil, prompt: nil, cwd: cwd, harness: .claudeCode, model: model, thinking: "low",
                         parentAgentID: lead, displayName: name)
    }
    func received(_ needle: String) -> Bool {
        AgentSteeringQAFakes.receivedFrames(in: claudeBin).contains { frame in
            guard let data = try? JSONSerialization.data(withJSONObject: frame) else { return false }
            return String(decoding: data, as: UTF8.self).contains(needle)
        }
    }

    // 1. A failed helper with a session: the retry continues THAT agent.
    let old = helper("Old")
    try require(supervisor.send("CRASH", to: old), "first send refused")
    try await waitFor("the helper must fail") {
        !supervisor.isRunning(old) && supervisor.records[old]?.latestTerminalEvent?.outcome == .failed
    }
    try await waitFor("a failed helper is retryable") { supervisor.mayRetry(old, from: lead) }
    let records = supervisor.records.count
    try require(supervisor.canContinueSessionForRetry(old, harness: .claudeCode, model: nil, effort: nil),
                "a failed Claude helper with a session must be continuable")
    try require(!supervisor.canContinueSessionForRetry(old, harness: .claudeCode, model: "anthropic/claude-other", effort: nil),
                "another model is a different helper, not a continuation")
    try require(!supervisor.canContinueSessionForRetry(old, harness: .codex, model: nil, effort: nil),
                "another CLI is a different helper, not a continuation")
    try require(supervisor.continueSessionForRetry(old, prompt: "Continue repair SAMESESSION"), "the continuation was refused")
    try await waitFor("the lead's text reaches the old session") { received("SAMESESSION") }
    try await waitFor("the continued turn settles") {
        !supervisor.isRunning(old) && supervisor.records[old]?.latestTerminalEvent?.outcome == .succeeded
    }
    try require(supervisor.records.count == records, "the continuation created another record")
    try require(supervisor.records[old]?.supersededBy == nil, "a continued helper must not be marked superseded")
    let session = AgentSupervisor.claudeSessionId(for: old)
    let mine = AgentSteeringQAFakes.argvLog(in: claudeBin).filter { $0.argv.contains(session) }
    try require(mine.last?.argv.contains("--resume") == true, "the continuation must resume the same Claude session, got \(String(describing: mine.last?.argv))")

    // 2. A fresh helper replacing a stopped one supersedes it.
    let held = helper("Held")
    try require(supervisor.send("SLOW", to: held), "slow send refused")
    try await waitFor("the helper is running") { supervisor.isRunning(held) }
    supervisor.stop(held)
    try await waitFor("the helper stops") { !supervisor.isRunning(held) }
    try require(supervisor.sendAgentMessage("held for the old helper", from: lead, to: held), "message to the stopped helper refused")
    try await waitFor("the stopped helper's queue holds the message") { supervisor.queuedMessages(for: held).count == 1 }
    guard let fresh = supervisor.handleSpawnRequest(
        SpawnRequest(role: nil, prompt: "Take over", isolated: false), from: lead,
        childSelection: AgentLaunchSelection(harness: .claudeCode, model: model, thinking: "low"),
        retryOf: held, originalBrief: "Take over") else {
        throw Failure(description: "helper-retry-session: the replacement spawn was refused")
    }
    try require(fresh != held, "a spawned replacement is another agent")
    try require(supervisor.records[held]?.supersededBy == fresh, "the replaced helper must name its replacement")
    let stored = try store.load(id: held)
    try require(stored?.supersededBy == fresh, "supersededBy must be persisted")
    try await waitFor("the replaced helper's queue must be cancelled") { supervisor.queuedMessages(for: held).isEmpty }
    print("helper-retry-session-check: PASS")
}

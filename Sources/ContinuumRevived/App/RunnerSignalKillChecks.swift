import AppKit
import ContinuumRevivedCore
import Foundation

/// 2026-11-20 hotfix: SIGTERM on a runner was relaunched with --resume within
/// seconds (the queue sweep's "idle runner, queued work, no hold"). Drives the
/// production supervisor and runner (fake `claude`): an agent with queued work
/// has its CLI killed from outside; it must stay down, its queue held as
/// interrupted, however many sweeps pass.
@MainActor
func runRunnerSignalKillChecks() async throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        guard condition else { throw Failure(description: message()) }
    }
    func waitFor(_ message: @autoclosure () -> String, timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(description: message())
    }

    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("runner-signal-\(UUID().uuidString)", isDirectory: true)
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

    let supervisor = AgentSupervisor(
        store: AgentStore(applicationSupportDirectory: root.appendingPathComponent("support", isDirectory: true)),
        makeRunner: AgentSupervisor.productionRunner,
        submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: root, debounceInterval: 0))
    supervisor.personalClaudeDirectory = personalClaude
    supervisor.personalCodexDirectory = root.appendingPathComponent("personal-codex", isDirectory: true)
    supervisor.accountUsageReader = { _ in nil }
    supervisor.queueSweepInterval = 0.2
    defer { supervisor.stopAll() }

    let model = "anthropic/claude-haiku-4-5-20251001"
    let id = supervisor.spawn(role: nil, prompt: nil, cwd: cwd, harness: .claudeCode, model: model, thinking: "low", displayName: "Victim")
    try require(supervisor.send("HOLD work", to: id), "send refused: \(supervisor.sendRefusal(for: id) ?? "?")")
    try await waitFor("the turn is running") { supervisor.isRunning(id) && AgentSteeringQAFakes.latestPid(in: claudeBin) != nil }
    var queued = await supervisor.accept(.queue(.init("queued behind the running turn")), for: id)
    for _ in 0..<150 where queued != .accepted {
        try await Task.sleep(for: .milliseconds(20))
        queued = await supervisor.accept(.queue(.init("queued behind the running turn")), for: id)
    }
    try require(queued == .accepted, "second prompt queues, got \(queued)")
    let spawnsBefore = AgentSteeringQAFakes.spawnCount(in: claudeBin)
    guard let pid = AgentSteeringQAFakes.latestPid(in: claudeBin) else { throw Failure(description: "no runner pid") }

    kill(pid, SIGTERM)
    try await waitFor("the killed runner's turn ends") { !supervisor.isRunning(id) }
    for _ in 0..<8 {
        try await Task.sleep(for: .milliseconds(300))
        supervisor.sweepQueues(now: Date().addingTimeInterval(3600 * Double(Int.random(in: 1...1000))))
    }
    let spawnsAfter = AgentSteeringQAFakes.spawnCount(in: claudeBin)
    print("runner-signal-kill-check: spawns \(spawnsBefore) -> \(spawnsAfter), running=\(supervisor.isRunning(id)), paused=\(supervisor.isQueuePaused(for: id))")
    try require(spawnsAfter == spawnsBefore && !supervisor.isRunning(id), "a runner killed by a signal Array did not send must not be relaunched")
    try require(supervisor.isQueuePaused(for: id), "its queue is held as interrupted")
    print("runner-signal-kill-check: PASS")
}

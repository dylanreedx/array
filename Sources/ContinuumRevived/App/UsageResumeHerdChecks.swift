import AppKit
import ContinuumRevivedCore
import Foundation

/// 2026-11-20 hotfix: one successful turn freed every usage-paused agent, ~16
/// cold-cache resumes in 3 minutes. Drives the production supervisor, runner
/// (fake `claude`) and resume clock with 4 leads and 12 helpers paused on one
/// account, then opens the window:
/// 1. exactly 2 leads resume, 0 helpers, however many ticks pass;
/// 2. the next resume waits for a fresh reading under 60%, and a reading at
///    70% does not free it;
/// 3. helpers with a live lead never resume by themselves, and each lead is
///    told once which helpers Array left paused.
@MainActor
func runUsageResumeHerdChecks() async throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        guard condition else { throw Failure(description: message()) }
    }
    func waitFor(_ message: @autoclosure () -> String, timeout: TimeInterval = 30, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(description: message())
    }

    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("usage-herd-\(UUID().uuidString)", isDirectory: true)
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
    supervisor.accountFallbackPreference = false
    supervisor.helperCompletionEnabled = { _ in true }
    var now = Date()
    supervisor.usagePauseNow = { now }
    supervisor.helperCompletionNow = { now }
    supervisor.usageResumeStagger = 20
    defer { supervisor.stopAll() }

    let account = supervisor.activeAccount(for: .claudeCode)
    let folder = account.configDirectory ?? "<default>"
    func exhaust(_ on: Bool) throws {
        try (on ? folder + "\n" : "").write(to: claudeBin.appendingPathComponent("exhausted.txt"), atomically: true, encoding: .utf8)
    }
    try "You've hit your 5-hour limit · resets 1:40am (America/Toronto)"
        .write(to: claudeBin.appendingPathComponent("limit-line.txt"), atomically: true, encoding: .utf8)

    let model = "anthropic/claude-haiku-4-5-20251001"
    let leads = (0..<4).map { i in
        supervisor.spawn(role: nil, prompt: nil, cwd: cwd, harness: .claudeCode, model: model, thinking: "low", displayName: "Lead \(i)")
    }
    var helpers: [AgentID] = []
    for (i, lead) in leads.enumerated() {
        for j in 0..<3 {
            helpers.append(supervisor.spawn(role: nil, prompt: nil, cwd: cwd, harness: .claudeCode, model: model, thinking: "low",
                                            parentAgentID: lead, displayName: "Helper \(i).\(j)"))
        }
    }
    let other = supervisor.spawn(role: nil, prompt: nil, cwd: cwd, harness: .claudeCode, model: model, thinking: "low")

    try exhaust(true)
    for id in helpers + leads {
        try require(supervisor.send("PLAIN task", to: id), "send refused: \(supervisor.sendRefusal(for: id) ?? "?")")
        try await waitFor("every agent pauses on usage") { !supervisor.isRunning(id) && supervisor.usagePause(for: id) != nil }
        now.addTimeInterval(1)
    }
    now.addTimeInterval(30)
    await supervisor.flushHelperCompletions()

    // The window opens: one agent on the account succeeds.
    try exhaust(false)
    let before = supervisor.usageResumeLogForQA.count
    try require(supervisor.send("PLAIN open", to: other), "the unrelated agent refused")
    try await waitFor("the window opening resumes a lead") { supervisor.usageResumeLogForQA.count > before }
    for _ in 0..<10 {
        now.addTimeInterval(supervisor.usageResumeStagger + 1)
        supervisor.runUsageResumeTick()
        try await Task.sleep(for: .milliseconds(150))
        try await waitFor("resumed turns settle") { (leads + helpers + [other]).allSatisfy { !supervisor.isRunning($0) } }
    }
    func who(_ id: AgentID) -> String {
        leads.firstIndex(of: id).map { "lead \($0)" } ?? helpers.firstIndex(of: id).map { "helper \($0)" } ?? "other"
    }
    var resumed = Array(supervisor.usageResumeLogForQA.dropFirst(before))
    print("usage-resume-herd-check: after the opening resumed \(resumed.map(who))")
    try require(resumed.count == 2 && resumed.allSatisfy { leads.contains($0) },
                "a window opening resumes exactly 2 leads and 0 helpers, got \(resumed.map(who))")
    try require(helpers.allSatisfy { supervisor.usagePause(for: $0) != nil }, "every helper stays paused, one Resume click away")

    // The lead was told, once, which helpers Array left paused.
    try await waitFor("a lead is told which helpers were left paused") {
        leads.contains { lead in
            supervisor.queuedMessages(for: lead).contains { $0.text.contains("left these helpers paused") }
                || AgentSteeringQAFakes.receivedFrames(in: claudeBin).contains { frame in
                    guard let data = try? JSONSerialization.data(withJSONObject: frame) else { return false }
                    return String(decoding: data, as: UTF8.self).contains("left these helpers paused")
                }
        }
    }

    // 2. A stale-or-high reading frees nothing; a fresh one under 60% frees one.
    func reading(_ used: Double) -> AgentAccountUsageProbe.Reading {
        .init(identity: AgentAccountIdentity(harness: .claudeCode, email: "me@example.com", organizationName: "Me",
                                             organizationId: "org-me", plan: "max", observedAt: now),
              quota: AgentAccountQuotaSnapshot(harness: .claudeCode,
                  windows: [AgentQuotaWindow(kind: .fiveHour, utilization: used, resetsAt: now.addingTimeInterval(3 * 3600))],
                  observedAt: now, source: .claudeUsageRequest, accountId: account.id))
    }
    now.addTimeInterval(supervisor.usageResumeStagger + 1)
    supervisor.applyAccountUsageReading(reading(0.70), accountId: account.id)
    supervisor.runUsageResumeTick()
    try await Task.sleep(for: .milliseconds(300))
    try require(supervisor.usageResumeLogForQA.count == before + 2, "a reading at 70% resumes no one")
    now.addTimeInterval(supervisor.usageResumeStagger + 1)
    supervisor.applyAccountUsageReading(reading(0.40), accountId: account.id)
    supervisor.runUsageResumeTick()
    try await waitFor("a fresh reading under 60% resumes the next lead") { supervisor.usageResumeLogForQA.count == before + 3 }
    try await waitFor("it settles") { (leads + [other]).allSatisfy { !supervisor.isRunning($0) } }
    now.addTimeInterval(supervisor.usageResumeStagger + 1)
    supervisor.runUsageResumeTick()
    try await Task.sleep(for: .milliseconds(300))
    try require(supervisor.usageResumeLogForQA.count == before + 3, "one fresh reading frees one resume, got \(supervisor.usageResumeLogForQA.dropFirst(before).map(who))")
    resumed = Array(supervisor.usageResumeLogForQA.dropFirst(before))
    try require(resumed.allSatisfy { leads.contains($0) } && helpers.allSatisfy { supervisor.usagePause(for: $0) != nil },
                "helpers never auto-resume, got \(resumed.map(who))")
    print("usage-resume-herd-check: PASS")
}

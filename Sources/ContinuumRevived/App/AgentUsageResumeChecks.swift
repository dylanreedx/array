import AppKit
import ContinuumRevivedCore
import Foundation

/// Usage resume, build-plan steps 2-5 (`~/array-scratch/sidebar-round/status-redesign/README.md`).
///
/// Before: a Claude helper whose account ran out ended "Claude Code reported an
/// error without details", read Failed, its lead was told "failed", and
/// nothing ever resumed it. A Codex stop read "paused" for days after Codex had
/// succeeded again (Box 1: the paused state came from the account's live
/// reading, never from the agent).
///
/// Drives the PRODUCTION runner (the fake `claude` on PATH ends every turn on
/// an exhausted account folder the way claude 2.1.32x does), the production
/// supervisor, its helper-completion courier and its resume clock:
/// 1. the stop is a per-agent usage pause on the agent's own account, with the
///    reset, delivered as interrupted, never failed;
/// 2. the lead is told "paused for Claude usage until …" and that a message resumes it;
/// 3. a later success on the same account ends every pause on it (the Nov 16
///    shape) and resumes them staggered, oldest first, one at a time;
/// 4. each resume is the SAME session on the SAME harness, a continuation, and
///    the lead hears "resumed";
/// 5. a stated reset resumes it by itself, once; a reading at 99% frees
///    nothing, one under it does; the toggle off waits; Stop clears.
@MainActor
func runAgentUsageResumeChecks() async throws {
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
    let root = fm.temporaryDirectory.appendingPathComponent("usage-resume-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    let claudeBin = root.appendingPathComponent("claude-bin", isDirectory: true)
    let codexBin = root.appendingPathComponent("codex-bin", isDirectory: true)
    _ = try AgentSteeringQAFakes.install(.claude, in: claudeBin)
    // A codex on PATH too: a usage stop must never move work to another CLI.
    _ = try AgentSteeringQAFakes.install(.codex, in: codexBin)
    let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    setenv("PATH", "\(claudeBin.path):\(codexBin.path):\(originalPath)", 1)
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
    supervisor.helperCompletionEnabled = { _ in true }
    var now = Date()
    supervisor.usagePauseNow = { now }
    supervisor.helperCompletionNow = { now }
    supervisor.usageResumeStagger = 20
    defer { supervisor.stopAll() }
    var failedTerminals: [AgentID] = []
    let observer = supervisor.addDeliveredEventObserver { id, event in
        if case .turnCompleted(_, _, .failed, _) = event { failedTerminals.append(id) }
    }
    defer { supervisor.removeDeliveredEventObserver(observer) }

    let account = supervisor.activeAccount(for: .claudeCode)
    let folder = account.configDirectory ?? "<default>"
    func exhaust(_ on: Bool) throws {
        try (on ? folder + "\n" : "").write(to: claudeBin.appendingPathComponent("exhausted.txt"), atomically: true, encoding: .utf8)
    }
    let line = "You've hit your 5-hour limit · resets 1:40am (America/Toronto)"
    try line.write(to: claudeBin.appendingPathComponent("limit-line.txt"), atomically: true, encoding: .utf8)
    func continuations() -> Int {
        AgentSteeringQAFakes.receivedFrames(in: claudeBin).filter { frame in
            let content = (frame["message"] as? [String: Any])?["content"]
            let text = (content as? String) ?? ((content as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()) ?? ""
            return text.contains(AgentSupervisor.usageContinuationPrompt)
        }.count
    }
    func received(_ needle: String) -> Bool {
        AgentSteeringQAFakes.receivedFrames(in: claudeBin).contains { frame in
            guard let data = try? JSONSerialization.data(withJSONObject: frame) else { return false }
            return String(decoding: data, as: UTF8.self).contains(needle)
        }
    }
    let model = "anthropic/claude-haiku-4-5-20251001"
    let lead = supervisor.spawn(role: nil, prompt: nil, cwd: cwd, harness: .claudeCode, model: model, thinking: "low")
    let helpers = (0..<2).map { i in
        supervisor.spawn(role: nil, prompt: nil, cwd: cwd, harness: .claudeCode, model: model, thinking: "low",
                         parentAgentID: lead, displayName: "Helper \(i)")
    }
    let other = supervisor.spawn(role: nil, prompt: nil, cwd: cwd, harness: .claudeCode, model: model, thinking: "low")

    // 1. The stop: a pause on the agent's own account, never Failed.
    try exhaust(true)
    for (i, helper) in helpers.enumerated() {
        try require(supervisor.send("PLAIN task \(i)", to: helper), "helper \(i) refused: \(supervisor.sendRefusal(for: helper) ?? "?")")
        try await waitFor("helper \(i) must stop paused on usage") { !supervisor.isRunning(helper) && supervisor.usagePause(for: helper) != nil }
        now.addTimeInterval(1)
    }
    for helper in helpers {
        let pause = supervisor.usagePause(for: helper)!
        try require(pause.harness == .claudeCode && pause.accountId == account.id && pause.stop.window == "5-hour"
                        && pause.resetsAt != nil && pause.stop.message == line,
                    "the pause must name the agent's own account, the 5-hour window, the reset and the CLI's line, got \(pause)")
        try require(supervisor.records[helper]?.latestTerminalEvent?.outcome == .interrupted,
                    "a usage stop is delivered interrupted, got \(String(describing: supervisor.records[helper]?.latestTerminalEvent?.outcome))")
        try require(supervisor.sidebarFailureDetail(for: helper) == line, "the sidebar reads the CLI's own line")
    }
    try require(failedTerminals.isEmpty, "no subscriber may hear a failed turn for a usage stop, got \(failedTerminals)")
    try require(supervisor.helperProviderRetryCounts.values.allSatisfy { $0 == 0 }, "a usage stop is not a transient retry")

    // 2. The lead hears the truth.
    now.addTimeInterval(30)
    await supervisor.flushHelperCompletions()
    // A lead's helper is not resumed by the reset alone, so the lead is told
    // the reset time and that its message resumes it (`--usage-hold-truth-check`).
    let pausedNotice = "finished: paused for Claude usage until "
    try await waitFor("the lead must be told its helpers paused for Claude usage") {
        received(pausedNotice) || supervisor.queuedMessages(for: lead).contains { $0.text.contains(pausedNotice) }
    }
    try require(!received("finished: failed") && !supervisor.queuedMessages(for: lead).contains { $0.text.contains("finished: failed") },
                "the lead must never be told a usage stop failed")
    // The lead's own turn on the spent account pauses too (drained in 3).
    try await waitFor("the lead's own turn settles") { !supervisor.isRunning(lead) }

    // The mechanics below are for agents Array resumes by itself: a helper with a
    // live lead never is (`--usage-resume-herd-check`), so orphan these.
    for helper in helpers { supervisor.qaDetachFromParent(helper) }

    // 3. The Nov 16 shape: a later success on the SAME account ends the pauses.
    try exhaust(false)
    let before = supervisor.usageResumeLogForQA.count
    try require(supervisor.send("PLAIN unrelated", to: other), "the unrelated agent refused")
    try await waitFor("one success on the account must resume the oldest pause") {
        supervisor.usageResumeLogForQA.count == before + 1
    }
    try require(supervisor.usageResumeLogForQA[before] == helpers[0], "the oldest stop resumes first, got \(supervisor.usageResumeLogForQA)")
    try await Task.sleep(for: .milliseconds(300))
    try require(supervisor.usageResumeLogForQA.count == before + 1 && supervisor.usagePause(for: helpers[1]) != nil,
                "resumes are staggered: the second waits, got \(supervisor.usageResumeLogForQA)")
    try await waitFor("helper 0's continuation must finish") { !supervisor.isRunning(helpers[0]) }
    now.addTimeInterval(supervisor.usageResumeStagger + 1)
    supervisor.runUsageResumeTick()
    try await waitFor("after the stagger the next pause resumes") {
        supervisor.usageResumeLogForQA.count >= before + 2 && supervisor.usagePause(for: helpers[1]) == nil
    }
    try await waitFor("every resumed turn settles") { helpers.allSatisfy { !supervisor.isRunning($0) } }
    for helper in helpers {
        try require(supervisor.usagePause(for: helper) == nil && supervisor.records[helper]?.latestTerminalEvent?.outcome == .succeeded,
                    "a resumed helper finishes its continuation, got \(String(describing: supervisor.records[helper]?.latestTerminalEvent?.outcome))")
    }
    try require(continuations() >= 2, "each resume is a continuation turn, got \(continuations())")
    // The lead's own turn stopped on the same account: the success freed it too.
    // Drain it, then stop waking it so later helper turns cannot move the counts.
    if supervisor.usagePause(for: lead) != nil {
        now.addTimeInterval(supervisor.usageResumeStagger + 1)
        supervisor.runUsageResumeTick()
        try await waitFor("the lead's own pause resumes too") { supervisor.usagePause(for: lead) == nil }
    }
    try await waitFor("the lead settles") { !supervisor.isRunning(lead) }
    supervisor.helperCompletionEnabled = { _ in false }

    // 4. Same session, same harness, same account folder; never a fresh one.
    let log = AgentSteeringQAFakes.argvLog(in: claudeBin)
    for helper in helpers {
        let session = AgentSupervisor.claudeSessionId(for: helper)
        let mine = log.filter { $0.argv.contains(session) }
        try require(!mine.isEmpty, "the helper's session must appear in the CLI's argv")
        let fresh = log.filter { entry in
            guard let i = entry.argv.firstIndex(of: "--session-id"), i + 1 < entry.argv.count else { return false }
            return entry.argv[i + 1] == session
        }
        try require(fresh.count <= 1, "a resume must never mint the session again (--session-id), got \(fresh.count)")
        try require(mine.allSatisfy { $0.configDir == folder }, "a resume must stay on the agent's own account folder")
    }
    try require(AgentSteeringQAFakes.spawnCount(in: codexBin) == 0, "a usage stop must never start another CLI")
    try require(supervisor.records[helpers[0]]?.harness == .claudeCode, "the harness never changes")

    // 5a. A stated reset resumes it by itself, exactly once.
    try exhaust(true)
    let waiter = helpers[0]
    try require(supervisor.send("PLAIN later", to: waiter), "waiter refused")
    try await waitFor("the waiter pauses again") { !supervisor.isRunning(waiter) && supervisor.usagePause(for: waiter) != nil }
    guard let reset = supervisor.usagePause(for: waiter)?.resetsAt else { throw Failure(description: "no reset on the waiter") }
    try exhaust(false)
    let atReset = supervisor.usageResumeLogForQA.count
    now = reset.addingTimeInterval(-60)
    supervisor.runUsageResumeTick()
    try await Task.sleep(for: .milliseconds(200))
    print("agent-usage-resume-check: before the reset resumed \(supervisor.usageResumeLogForQA.dropFirst(atReset).count) (\(supervisor.usageResumeLogForQA.dropFirst(atReset).map { $0 == lead ? "lead" : $0 == other ? "other" : "helper" })); open pauses \(supervisor.usagePauses.map { "\($0.key == lead ? "lead" : "helper"):reset=\($0.value.resetsAt.map { "\(Int($0.timeIntervalSince(now)))s" } ?? "none"):auto=\($0.value.resumesAutomatically)" })")
    try require(!supervisor.usageResumeLogForQA.dropFirst(atReset).contains(waiter),
                "the waiter must not resume before its reset — resumed \(supervisor.usageResumeLogForQA.dropFirst(atReset).map { $0 == lead ? "lead" : $0 == other ? "other" : helpers.firstIndex(of: $0).map { "helper \($0)" } ?? "?" }), pauses \(supervisor.usagePauses.keys.map { $0 == lead ? "lead" : helpers.firstIndex(of: $0).map { "helper \($0)" } ?? "?" })")
    now = reset.addingTimeInterval(supervisor.usageResumeStagger + 2)
    supervisor.runUsageResumeTick()
    supervisor.runUsageResumeTick()
    try await waitFor("at the reset the waiter resumes by itself") { supervisor.usageResumeLogForQA.dropFirst(atReset).contains(waiter) }
    try await waitFor("its continuation finishes") { !supervisor.isRunning(waiter) }
    supervisor.runUsageResumeTick()
    try require(supervisor.usageResumeLogForQA.filter { $0 == waiter }.count == 2,
                "one resume per pause, got \(supervisor.usageResumeLogForQA)")

    // 5b. A probe at 99% frees nothing (Codex's stop reads 99%); one under it does.
    try exhaust(true)
    let probed = helpers[1]
    try require(supervisor.send("PLAIN probe", to: probed), "probe helper refused")
    try await waitFor("the probed helper pauses") { !supervisor.isRunning(probed) && supervisor.usagePause(for: probed) != nil }
    try exhaust(false)
    supervisor.setUsageAutoResume(true, for: probed)
    let stoppedAt = supervisor.usagePause(for: probed)!.stoppedAt
    func reading(_ used: Double) -> AgentAccountUsageProbe.Reading {
        .init(identity: AgentAccountIdentity(harness: .claudeCode, email: "me@example.com", organizationName: "Me",
                                             organizationId: "org-me", plan: "max", observedAt: now),
              quota: AgentAccountQuotaSnapshot(harness: .claudeCode,
                  windows: [AgentQuotaWindow(kind: .fiveHour, utilization: used, resetsAt: reset.addingTimeInterval(86_400))],
                  observedAt: stoppedAt.addingTimeInterval(120), source: .claudeUsageRequest, accountId: account.id))
    }
    let atProbe = supervisor.usageResumeLogForQA.count
    // The clock only moves forward: past the last resume's stagger.
    now = now.addingTimeInterval(supervisor.usageResumeStagger + 1)
    supervisor.applyAccountUsageReading(reading(0.99), accountId: account.id)
    // The supervisor's own store saves the reading beside the agent store, so
    // a relaunch restores it (it used to resolve only from an env var).
    try require(fm.fileExists(atPath: root.appendingPathComponent("support/account-quotas.json").path),
                "a usage reading must be saved beside the agent store")
    try await Task.sleep(for: .milliseconds(300))
    try require(supervisor.usagePause(for: probed) != nil && !supervisor.usageResumeLogForQA.dropFirst(atProbe).contains(probed),
                "a 99% reading is still used up")
    supervisor.applyAccountUsageReading(reading(0.40), accountId: account.id)
    try await waitFor("a reading under 100% resumes the pause") { supervisor.usageResumeLogForQA.dropFirst(atProbe).contains(probed) }
    try await waitFor("its continuation finishes") { !supervisor.isRunning(probed) }

    // 5c. Resume automatically off: the reset passes and it waits; Stop clears.
    try exhaust(true)
    try require(supervisor.send("PLAIN manual", to: probed), "manual helper refused")
    try await waitFor("the manual helper pauses") { !supervisor.isRunning(probed) && supervisor.usagePause(for: probed) != nil }
    supervisor.setUsageAutoResume(false, for: probed)
    let atManual = supervisor.usageResumeLogForQA.count
    now = now.addingTimeInterval(86_400 * 2)
    supervisor.runUsageResumeTick()
    try await Task.sleep(for: .milliseconds(200))
    try require(!supervisor.usageResumeLogForQA.dropFirst(atManual).contains(probed) && supervisor.usagePause(for: probed)?.resumesAutomatically == false,
                "with Resume automatically off nothing resumes")
    supervisor.stop(probed)
    try require(supervisor.usagePause(for: probed) == nil, "Stop clears the pause")
    try exhaust(false)
    func who(_ id: AgentID) -> String {
        id == lead ? "lead" : id == other ? "other" : helpers.firstIndex(of: id).map { "helper \($0)" } ?? "?"
    }
    print("agent-usage-resume-check: resume order \(supervisor.usageResumeLogForQA.map(who))")
    print("agent-usage-resume-check: PASS")
}

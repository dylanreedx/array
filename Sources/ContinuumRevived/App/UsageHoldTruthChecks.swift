import AppKit
import ContinuumRevivedCore
import Foundation

/// 2026-11-25: a helper hit Work's 5-hour limit. Array told its lead it had
/// moved the helper to Personal "and is resuming it there", then seconds later
/// that usage was back and it had left the helper paused "until you message
/// it". Both of the lead's messages came back "held" for usage, and only a
/// `retryOf` moved it. The resume tick held every helper with a live lead,
/// whatever the failover notice or the note promised, and a message never
/// counted as the lead's ask.
///
/// Production supervisor, runner (fake `claude`, exhausted per account folder)
/// and resume clock; one lead, one helper:
/// 1. the failover account has room: the helper resumes there by itself, and
///    the lead is never told it was left paused;
/// 2. usage is back and the helper was held for its lead: the lead's message
///    is delivered, not held, and resumes it on its own session;
/// 3. no account has room: the message is held, and the hold says when the
///    helper resumes;
/// 4. the same sender sends newer instructions, then a retryOf resumes it:
///    the held messages ride the retry turn as one note and never replay.
@MainActor
func runUsageHoldTruthChecks() async throws {
    struct Failure: Error, CustomStringConvertible { let description: String }
    func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        guard condition else { throw Failure(description: message()) }
    }
    func waitFor(_ message: @autoclosure () -> String, timeout: TimeInterval = 25, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(description: message())
    }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("usage-hold-truth-\(UUID().uuidString)", isDirectory: true)
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
    supervisor.helperCompletionEnabled = { _ in true }
    var now = Date()
    supervisor.usagePauseNow = { now }
    supervisor.helperCompletionNow = { now }
    supervisor.usageResumeStagger = 20
    defer { supervisor.stopAll() }

    let personal = AgentAccount.defaultAccount(for: .claudeCode)
    let work = try supervisor.addAccount(harness: .claudeCode, label: "Work")
    func folder(_ a: AgentAccount) -> String { a.configDirectory ?? "<default>" }
    func exhaust(_ accounts: [AgentAccount]) throws {
        try accounts.map { folder($0) + "\n" }.joined()
            .write(to: claudeBin.appendingPathComponent("exhausted.txt"), atomically: true, encoding: .utf8)
    }
    try "You've hit your 5-hour limit · resets 1pm (America/Toronto)"
        .write(to: claudeBin.appendingPathComponent("limit-line.txt"), atomically: true, encoding: .utf8)
    func reading(_ account: AgentAccount, _ used: Double) {
        supervisor.applyAccountUsageReading(
            .init(identity: AgentAccountIdentity(harness: .claudeCode, email: "\(account.id)@example.com", organizationName: account.label,
                                                 organizationId: "org-\(account.id)", plan: "max", observedAt: now),
                  quota: AgentAccountQuotaSnapshot(harness: .claudeCode,
                      windows: [AgentQuotaWindow(kind: .fiveHour, utilization: used, resetsAt: now.addingTimeInterval(86_400))],
                      observedAt: now, source: .claudeUsageRequest, accountId: account.id)),
            accountId: account.id)
    }
    func received(_ needle: String) -> Bool {
        AgentSteeringQAFakes.receivedFrames(in: claudeBin).contains { frame in
            guard let data = try? JSONSerialization.data(withJSONObject: frame) else { return false }
            return String(decoding: data, as: UTF8.self).contains(needle)
        }
    }
    func leadHeard(_ lead: AgentID, _ needle: String) -> Bool {
        received(needle) || supervisor.queuedMessages(for: lead).contains { $0.text.contains(needle) }
    }
    let model = "anthropic/claude-haiku-4-5-20251001"
    let lead = supervisor.spawn(role: nil, prompt: nil, cwd: cwd, harness: .claudeCode, model: model, thinking: "low")
    let helper = supervisor.spawn(role: nil, prompt: nil, cwd: cwd, harness: .claudeCode, model: model, thinking: "low",
                                  parentAgentID: lead, displayName: "Sticky header helper")
    func state() -> String {
        "pause=\(supervisor.usagePause(for: helper) != nil) running=\(supervisor.isRunning(helper)) override=\(String(describing: supervisor.accountOverrides[helper])) queue=\(supervisor.queuedMessages(for: helper).count) outcome=\(String(describing: supervisor.records[helper]?.latestTerminalEvent?.outcome))"
    }

    // 1. Work spent, Personal has room: the helper moves AND resumes there.
    reading(personal, 0.20)
    try require(supervisor.switchAccount(to: work.id) == .switched(finishingTurns: 0), "Work is the account in use")
    try exhaust([work])
    let before = supervisor.usageResumeLogForQA.count
    try require(supervisor.send("PLAIN header task", to: helper), "helper send refused")
    try await waitFor("the helper moves off Work; \(state())") { supervisor.accountOverrides[helper] == personal.id }
    try await waitFor("the moved helper resumes on Personal by itself; \(state())") {
        supervisor.usageResumeLogForQA.dropFirst(before).contains(helper)
    }
    try await waitFor("its continuation succeeds; \(state())") {
        !supervisor.isRunning(helper) && supervisor.usagePause(for: helper) == nil
            && supervisor.records[helper]?.latestTerminalEvent?.outcome == .succeeded
    }
    let mine = AgentSteeringQAFakes.argvLog(in: claudeBin).filter { $0.argv.contains(AgentSupervisor.claudeSessionId(for: helper)) }
    try require(mine.last?.configDir == folder(personal) && mine.last?.argv.contains("--resume") == true,
                "it resumes the same session signed in as Personal, got \(String(describing: mine.last))")
    now.addTimeInterval(30)
    await supervisor.flushHelperCompletions()
    try require(!leadHeard(lead, "left these helpers paused"),
                "a helper Array moved to an account with room must not be reported left paused")
    print("usage-hold-truth-check: 1 failover resumes: PASS")

    // 2. Usage back on its own account; the helper waits for its lead, and the
    //    lead's message is the ask that resumes it.
    supervisor.accountFallbackPreference = false
    // A person's switch away and back clears the automatic move.
    try require(supervisor.switchAccount(to: personal.id) == .switched(finishingTurns: 0), "switch to Personal")
    try require(supervisor.switchAccount(to: work.id) == .switched(finishingTurns: 0), "back on Work")
    try require(supervisor.accountOverrides[helper] == nil, "a person's switch clears the move")
    try exhaust([work])
    try require(supervisor.send("PLAIN second task", to: helper), "helper send refused")
    try await waitFor("the helper pauses on Work; \(state())") { !supervisor.isRunning(helper) && supervisor.usagePause(for: helper) != nil }
    now.addTimeInterval(30)
    await supervisor.flushHelperCompletions()
    guard let reset = supervisor.usagePause(for: helper)?.resetsAt else { throw Failure(description: "no reset on the helper's pause") }
    try exhaust([])
    now = reset.addingTimeInterval(5)
    let atReset = supervisor.usageResumeLogForQA.count
    supervisor.runUsageResumeTick()
    try await waitFor("the lead is told usage is back and the helper waits for it") { leadHeard(lead, "left these helpers paused") }
    try require(supervisor.usagePause(for: helper) != nil && !supervisor.usageResumeLogForQA.dropFirst(atReset).contains(helper),
                "the reset alone does not resume a helper with a live lead; \(state())")
    // 2026-11-25 3:50 PM: the pause notice said "Array resumes it at 3:50 PM",
    // and at 3:50 Array left it paused. The notice must say what happens.
    try require(!leadHeard(lead, "finished: paused for Claude usage; Array resumes it at"),
                "a lead's helper must not be promised a resume at the reset it will not get")
    try await waitFor("the pause notice must tell the lead its message resumes the helper") {
        leadHeard(lead, "Array does not resume a lead's helper by itself: message it")
    }
    let asked = supervisor.deliverAgentMessage("GO-AHEAD-FROM-LEAD", from: lead, to: helper, hops: 1)
    try require(asked.delivery != .held && asked.delivery != .refused,
                "the lead's message is the resume the note promised, got \(asked.delivery) \(supervisor.agentMessageHoldReason(for: helper, sender: lead) ?? "")")
    try await waitFor("the message resumes the helper on its session and runs; \(state())") {
        supervisor.usageResumeLogForQA.dropFirst(atReset).contains(helper) && received("GO-AHEAD-FROM-LEAD")
    }
    try await waitFor("it settles; \(state())") { !supervisor.isRunning(helper) && supervisor.queuedMessages(for: helper).isEmpty }
    print("usage-hold-truth-check: 2 a lead message resumes: PASS")

    // 3. Every account spent: the message is held and says when.
    supervisor.accountFallbackPreference = nil
    reading(personal, 0.99); reading(work, 1.0)
    // Case 2 moved the clock past the stated reset; the CLI's "resets 1pm" is
    // read against the real clock, so return to it for a reset still ahead.
    now = Date()
    try exhaust([work, personal])
    try require(supervisor.send("PLAIN third task", to: helper), "helper send refused")
    try await waitFor("the helper pauses with every account spent; \(state())") {
        !supervisor.isRunning(helper) && supervisor.usagePause(for: helper) != nil
    }
    try require(supervisor.accountOverrides[helper] == nil, "nothing to move to; \(state())")
    try require((supervisor.usagePause(for: helper)?.resetsAt ?? .distantPast) > now, "the spent pause's reset is still ahead; \(state())")
    guard let spentReset = supervisor.usagePause(for: helper)?.resetsAt else { throw Failure(description: "no reset on the spent pause") }
    let atSpent = supervisor.usageResumeLogForQA.count
    let held = supervisor.deliverAgentMessage("WAIT-FOR-RESET", from: lead, to: helper, hops: 1)
    try require(held.delivery == .held, "with no account at room the message is held, got \(held.delivery); resumed=\(supervisor.usageResumeLogForQA.dropFirst(atSpent).contains(helper)) reset=\(spentReset.timeIntervalSince(now)) \(state())")
    let why = supervisor.agentMessageHoldReason(for: helper, sender: lead) ?? "<not held>"
    let clock = AgentUsagePause.clock(spentReset, now: now)
    try require(why.contains("usage limit") && why.contains("resumes it at \(clock)"),
                "the hold must say when the helper resumes (\(clock)), got: \(why)")
    try await Task.sleep(for: .milliseconds(300))
    try require(!received("WAIT-FOR-RESET") && supervisor.usageResumeLogForQA.count == atSpent,
                "a held message must not run into a spent account; \(state())")
    print("usage-hold-truth-check: 3 no room holds with a time: PASS")

    // 4. The same sender sends newer instructions, then resumes it with a
    //    retry. The held messages ride the retry turn as a note and never
    //    replay afterwards as turns of their own.
    try require(supervisor.deliverAgentMessage("NEWER-INSTRUCTION", from: lead, to: helper, hops: 1).delivery == .held,
                "the newer message is held too")
    func frames(_ needle: String) -> [String] {
        AgentSteeringQAFakes.receivedFrames(in: claudeBin).compactMap { frame in
            guard let data = try? JSONSerialization.data(withJSONObject: frame) else { return nil }
            let text = String(decoding: data, as: UTF8.self)
            return text.contains(needle) ? text : nil
        }
    }
    try exhaust([])
    try require(supervisor.canContinueSessionForRetry(helper, harness: .claudeCode, model: nil, effort: nil),
                "retryOf can continue the helper's session; \(state())")
    try require(supervisor.continueSessionForRetry(helper, prompt: "RETRY-BRIEF"), "the retry was refused; \(state())")
    try await waitFor("the retry turn settles with nothing left to replay; \(state())") {
        !supervisor.isRunning(helper) && supervisor.queuedMessages(for: helper).isEmpty
            && supervisor.records[helper]?.latestTerminalEvent?.outcome == .succeeded
    }
    try await Task.sleep(for: .milliseconds(500))
    try require(!supervisor.isRunning(helper), "no turn starts after the retry; \(state())")
    for needle in ["WAIT-FOR-RESET", "NEWER-INSTRUCTION"] {
        let carried = frames(needle)
        try require(carried.count == 1 && carried[0].contains("RETRY-BRIEF") && carried[0].contains("held while you were paused"),
                    "\(needle) rides the retry turn as a note, once, got \(carried.count) frame(s): \(carried.map { String($0.prefix(600)) })")
    }
    print("usage-hold-truth-check: 4 a retry carries held messages, no replay: PASS")
    print("usage-hold-truth-check: PASS")
}

import AppKit
import ContinuumRevivedCore
import Foundation

/// 2026-11-20 incident: three Claude helpers held the Work account when it hit
/// its 5-hour limit (resets 06:40Z) while Array had already moved to Personal
/// (21%). The pause belonged to Work, so the Work-keyed clears (a success or a
/// reading on Work, or its reset) could not fire for 3 hours, though every
/// agent's next launch signs in as the account in use.
///
/// Drives the production supervisor, runner (fake `claude`, exhausted per
/// account folder) and resume clock with two real accounts:
/// 1. a pause on Work ends when the account in use becomes Personal: the SAME
///    session resumes, signed in as Personal, with a continuation turn;
/// 2. the leg that must NOT resume: a pause on the account still in use waits
///    for its reset, so a spent account is never looped on.
@MainActor
func runUsagePauseAccountSwitchChecks() async throws {
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
    final class Logins: @unchecked Sendable {
        private let lock = NSLock()
        private var byAccount: [String: AgentAccountIdentity] = [:]
        func set(_ id: String, _ identity: AgentAccountIdentity) { lock.withLock { byAccount[id] = identity } }
        func read(_ account: AgentAccount) -> AgentAccountUsageProbe.Reading? {
            .init(identity: lock.withLock { byAccount[account.id] }, quota: nil)
        }
    }

    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("usage-account-switch-\(UUID().uuidString)", isDirectory: true)
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

    let logins = Logins()
    let supervisor = AgentSupervisor(
        store: AgentStore(applicationSupportDirectory: root.appendingPathComponent("support", isDirectory: true)),
        makeRunner: AgentSupervisor.productionRunner,
        submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: root, debounceInterval: 0))
    supervisor.personalClaudeDirectory = personalClaude
    supervisor.personalCodexDirectory = root.appendingPathComponent("personal-codex", isDirectory: true)
    supervisor.accountUsageReader = { logins.read($0) }
    // This leg witnesses the account-in-use rule alone; automatic fallback is witnessed apart.
    supervisor.accountFallbackPreference = false
    var now = Date()
    supervisor.usagePauseNow = { now }
    supervisor.usageResumeStagger = 20
    defer { supervisor.stopAll() }

    let personal = AgentAccount.defaultAccount(for: .claudeCode)
    let work = try supervisor.addAccount(harness: .claudeCode, label: "Work")
    logins.set(personal.id, AgentAccountIdentity(harness: .claudeCode, email: "me@example.com", organizationName: "Me",
                                                 organizationId: "org-me", plan: "max", observedAt: now))
    logins.set(work.id, AgentAccountIdentity(harness: .claudeCode, email: "me@example.com", organizationName: "Team",
                                             organizationId: "org-team", plan: "team", observedAt: now))
    supervisor.refreshAccountUsage(harness: .claudeCode, minimumInterval: 0)
    try await waitFor("both logins must be read") {
        supervisor.accountIdentity(accountId: personal.id) != nil && supervisor.accountIdentity(accountId: work.id) != nil
    }
    let personalFolder = personal.configDirectory ?? "<default>"
    let workFolder = work.configDirectory ?? "<default>"
    func exhaust(_ folders: [String]) throws {
        try folders.map { $0 + "\n" }.joined().write(to: claudeBin.appendingPathComponent("exhausted.txt"), atomically: true, encoding: .utf8)
    }
    try "You've hit your 5-hour limit · resets 1:40am (America/Toronto)"
        .write(to: claudeBin.appendingPathComponent("limit-line.txt"), atomically: true, encoding: .utf8)

    let model = "anthropic/claude-haiku-4-5-20251001"
    let helper = supervisor.spawn(role: nil, prompt: nil, cwd: cwd, harness: .claudeCode, model: model, thinking: "low",
                                  displayName: "Helper")

    // 1. The pause is on Work; the account in use then becomes Personal.
    try require(supervisor.switchAccount(to: work.id) == .switched(finishingTurns: 0), "switch to Work")
    try exhaust([workFolder])
    try require(supervisor.send("PLAIN on work", to: helper), "send refused: \(supervisor.sendRefusal(for: helper) ?? "?")")
    try await waitFor("the helper must pause on Work's usage") { !supervisor.isRunning(helper) && supervisor.usagePause(for: helper) != nil }
    try require(supervisor.usagePause(for: helper)?.accountId == work.id,
                "the pause names Work, got \(String(describing: supervisor.usagePause(for: helper)?.accountId))")
    let before = supervisor.usageResumeLogForQA.count
    now.addTimeInterval(60)
    supervisor.runUsageResumeTick()
    try await Task.sleep(for: .milliseconds(300))
    try require(supervisor.usageResumeLogForQA.count == before && supervisor.usagePause(for: helper) != nil,
                "while Work is still the account in use, its pause waits for the reset")
    try require(supervisor.switchAccount(to: personal.id) == .switched(finishingTurns: 0), "switch back to Personal")
    try await waitFor("switching to an account with room must resume the pause on the new account") {
        supervisor.usageResumeLogForQA.dropFirst(before).contains(helper)
    }
    try await waitFor("the continuation finishes") { !supervisor.isRunning(helper) }
    try require(supervisor.usagePause(for: helper) == nil && supervisor.records[helper]?.latestTerminalEvent?.outcome == .succeeded,
                "the resumed helper finishes, got \(String(describing: supervisor.records[helper]?.latestTerminalEvent?.outcome))")
    let session = AgentSupervisor.claudeSessionId(for: helper)
    let log = AgentSteeringQAFakes.argvLog(in: claudeBin).filter { $0.argv.contains(session) }
    guard let last = log.last else { throw Failure(description: "the CLI never saw the helper's session") }
    try require(last.configDir == personalFolder, "the resume signs in as the account now in use (\(personalFolder)), got \(last.configDir)")
    try require(last.argv.contains("--resume"), "the resume continues the same conversation, got \(last.argv)")

    // 2. A pause on the account STILL in use never resumes early.
    try exhaust([personalFolder, workFolder])
    try require(supervisor.send("PLAIN on personal", to: helper), "second send refused")
    try await waitFor("the helper pauses on Personal") { !supervisor.isRunning(helper) && supervisor.usagePause(for: helper) != nil }
    let atSecond = supervisor.usageResumeLogForQA.count
    now.addTimeInterval(60)
    supervisor.runUsageResumeTick()
    try await Task.sleep(for: .milliseconds(300))
    try require(supervisor.usageResumeLogForQA.count == atSecond && supervisor.usagePause(for: helper) != nil,
                "a pause on the account in use waits for its reset, never loops")
    print("usage-pause-account-switch-check: PASS")
}

/// Automatic account fallback and the truth told to leads (2026-11-20: the perf
/// lead read ONE account's limit as global and restarted three helpers while
/// the lead itself and other helpers were fine on another account).
///
/// Production supervisor, runner (fake `claude`, exhausted per account folder),
/// helper-completion courier and resume clock, with four QA accounts and fake
/// usage readings (Personal 50%, Spare 20%, Alt 96%, Work the spent one):
/// 1. a stop on Work moves EVERY agent paused on Work (also the ones that
///    stopped while the setting was off) to the account with the most headroom,
///    skipping any at 95%, and resumes each on the same session signed in as
///    it, staggered; one quiet notice line per tile;
/// 2. the lead is told whose limit it was and that Array moved the helper;
/// 3. all accounts spent: nothing moves, the pause waits for its reset and
///    the lead hears no other account has room;
/// 4. setting off: nothing moves; the lead is told another account has room.
@MainActor
func runUsageAccountFallbackChecks() async throws {
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
    let root = fm.temporaryDirectory.appendingPathComponent("usage-account-fallback-\(UUID().uuidString)", isDirectory: true)
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
    let spare = try supervisor.addAccount(harness: .claudeCode, label: "Spare")
    let alt = try supervisor.addAccount(harness: .claudeCode, label: "Alt")
    func folder(_ a: AgentAccount) -> String { a.configDirectory ?? "<default>" }
    func exhaust(_ folders: [String]) throws {
        try folders.map { $0 + "\n" }.joined().write(to: claudeBin.appendingPathComponent("exhausted.txt"), atomically: true, encoding: .utf8)
    }
    try "You've hit your 5-hour limit · resets 1:40am (America/Toronto)"
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
    reading(personal, 0.50); reading(spare, 0.20); reading(alt, 0.96)

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
    let helpers = (0..<3).map { i in
        supervisor.spawn(role: nil, prompt: nil, cwd: cwd, harness: .claudeCode, model: model, thinking: "low",
                         parentAgentID: lead, displayName: "Helper \(i)")
    }
    var notices: [AgentID: [String]] = [:]
    for helper in helpers {
        _ = supervisor.addLocalNoticeObserver(for: helper) { notices[helper, default: []].append("\($0.title) | \($0.body)") }
    }
    try require(supervisor.switchAccount(to: work.id) == .switched(finishingTurns: 0), "Work is the account in use")
    try exhaust([folder(work)])

    // 4 first: setting off, a stop moves nothing and the lead is told who has room.
    supervisor.accountFallbackPreference = false
    for helper in helpers.prefix(2) {
        try require(supervisor.send("PLAIN off \(helper.rawValue.uuidString.prefix(4))", to: helper), "send refused")
        try await waitFor("helper pauses on Work") { !supervisor.isRunning(helper) && supervisor.usagePause(for: helper) != nil }
        now.addTimeInterval(1)
    }
    try require(supervisor.accountOverrides.isEmpty, "with the setting off nothing moves, got \(supervisor.accountOverrides)")
    now.addTimeInterval(30)
    await supervisor.flushHelperCompletions()
    try await waitFor("the lead must hear it was Work's limit and that Spare has room") {
        leadHeard(lead, "That is account Work's limit only: Spare has room")
    }

    // 1. A later stop with the setting on moves EVERY agent paused on Work, to Spare.
    supervisor.accountFallbackPreference = nil
    let before = supervisor.usageResumeLogForQA.count
    try require(supervisor.send("PLAIN on", to: helpers[2]), "send refused")
    try await waitFor("the third helper pauses on Work") { supervisor.accountOverrides[helpers[2]] != nil }
    for helper in helpers {
        try require(supervisor.accountOverrides[helper] == spare.id,
                    "\(helper.rawValue.uuidString.prefix(4)) must move to Spare (most headroom; Alt at 96% skipped), got \(String(describing: supervisor.accountOverrides[helper]))")
    }
    try await waitFor("the first move resumes") { supervisor.usageResumeLogForQA.count > before }
    for round in 1..<helpers.count {
        try await waitFor("each resume settles") { helpers.allSatisfy { !supervisor.isRunning($0) } }
        now.addTimeInterval(supervisor.usageResumeStagger + 1)
        supervisor.runUsageResumeTick()
        try await waitFor("resume \(round + 1) of \(helpers.count) starts") { supervisor.usageResumeLogForQA.count >= before + round + 1 }
    }
    try await waitFor("every resumed turn settles; state \(helpers.map { "\(supervisor.records[$0]?.latestTerminalEvent.map { "\($0.outcome)" } ?? "none")/pause=\(supervisor.usagePause(for: $0) != nil)/running=\(supervisor.isRunning($0))/queue=\(supervisor.queuedMessages(for: $0).count)" }) log=\(supervisor.usageResumeLogForQA.count - before)") {
        helpers.allSatisfy { !supervisor.isRunning($0) && supervisor.records[$0]?.latestTerminalEvent?.outcome == .succeeded }
    }
    for helper in helpers {
        try require(supervisor.usagePause(for: helper) == nil && supervisor.records[helper]?.latestTerminalEvent?.outcome == .succeeded,
                    "a moved helper finishes its continuation, got \(String(describing: supervisor.records[helper]?.latestTerminalEvent?.outcome))")
        let session = AgentSupervisor.claudeSessionId(for: helper)
        let mine = AgentSteeringQAFakes.argvLog(in: claudeBin).filter { $0.argv.contains(session) }
        try require(mine.last?.configDir == folder(spare) && mine.last?.argv.contains("--resume") == true,
                    "the move resumes the same session signed in as Spare, got \(String(describing: mine.last))")
        try require(notices[helper]?.contains { $0.hasPrefix("Moved to Spare | Work is at its limit") } == true,
                    "one quiet line in the tile, got \(notices[helper] ?? [])")
        try require(notices[helper]?.count == 1, "exactly one line, got \(notices[helper] ?? [])")
    }

    // 2. A helper that stops after the move is told, as the lead reads it.
    now.addTimeInterval(30)
    await supervisor.flushHelperCompletions()
    try require(leadHeard(lead, "then Array moved it to Spare") && leadHeard(lead, "one account's limit, not all of Claude"),
                "the lead must hear Work's limit and that Array moved the helper")

    // 3. Every account spent: nothing moves, the pause waits for the reset.
    reading(personal, 0.97); reading(spare, 0.99); reading(work, 1.0)
    try require(supervisor.switchAccount(to: personal.id) == .switched(finishingTurns: 0), "switch to Personal clears every move")
    try require(supervisor.accountOverrides.isEmpty, "a person's switch clears automatic moves")
    try exhaust([folder(work), folder(personal), folder(spare), folder(alt)])
    let helper = helpers[0]
    let atAll = supervisor.usageResumeLogForQA.count
    try require(supervisor.send("PLAIN all spent", to: helper), "send refused")
    try await waitFor("the helper pauses with every account spent") { !supervisor.isRunning(helper) && supervisor.usagePause(for: helper) != nil }
    now.addTimeInterval(60)
    supervisor.runUsageResumeTick()
    try await Task.sleep(for: .milliseconds(300))
    try require(supervisor.accountOverrides[helper] == nil && supervisor.usageResumeLogForQA.count == atAll && supervisor.usagePause(for: helper) != nil,
                "with every account spent the pause stays until its reset; override \(String(describing: supervisor.accountOverrides[helper])), resumed \(supervisor.usageResumeLogForQA.count - atAll), pause \(String(describing: supervisor.usagePause(for: helper)))")
    await supervisor.flushHelperCompletions()
    now.addTimeInterval(30)
    await supervisor.flushHelperCompletions()
    try await waitFor("the lead hears no other account has room") { leadHeard(lead, "no other Claude account has room") }
    print("usage-account-fallback-check: PASS")
}

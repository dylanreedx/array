import ContinuumRevivedCore
import Foundation

/// .plans/101 slice 1 — live limits and identity, read with no model turn.
///
/// Every reply here is a capture from the real CLIs on 2026-10-29 (claude
/// 2.1.312, codex-cli 0.165.0), sanitised: no real email, org or account id.
///
/// - (A) `get_usage`: `utilization` is a PERCENT on this request (11 means
///   11%), unlike `rate_limit_event`'s fraction; `resets_at` is ISO-8601 with
///   microseconds; `extra_usage` is credit, not a window; a signed-out dir has
///   no windows and reads as nil.
/// - (B) Identity: `auth status --json` and codex `account/read` name the
///   login and plan; signed out is nil.
/// - (C) Codex `account/rateLimits/read` reads through the notification's
///   parser: a 10080-minute primary is WEEKLY, and there is no 5-hour window.
/// - (D) The REAL spawn: a fake claude speaks `auth status` and `get_usage`;
///   the probe must pass the account's config dir as `CLAUDE_CONFIG_DIR`,
///   remove an inherited one for the default account, never set `HOME`, and
///   never ask a signed-out dir for usage.
func runAgentAccountUsageChecks() {
    let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
    func fixture(_ name: String) -> String {
        let url = fixturesDir.appendingPathComponent(name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            fputs("FAIL: account-usage fixture missing at \(url.path)\n", stderr)
            Foundation.exit(1)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func object(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }
    let observedAt = Date(timeIntervalSince1970: 1_793_400_000)

    // (A) get_usage.
    let usageLine = fixture("claude-2.1.312-get-usage.json")
    let parsed = AgentAccountUsageProbe.parseClaudeUsage(controlResponseLine: usageLine, observedAt: observedAt)
    let usage = parsed ?? nil
    expect(usage?.harness == .claudeCode && usage?.source == .claudeUsageRequest,
           "account-usage: get_usage must read as a claude on-demand reading, got \(String(describing: usage))")
    let fiveHour = usage?.window(.fiveHour)
    let weekly = usage?.window(.sevenDay)
    expect(fiveHour?.utilization.map { abs($0 - 0.11) < 0.0001 } == true,
           "account-usage: get_usage utilization is a percent; 11 must be 11% (0.11), got \(String(describing: fiveHour?.utilization))")
    expect(weekly?.utilization.map { abs($0 - 0.14) < 0.0001 } == true,
           "account-usage: the weekly window must read 14% used, got \(String(describing: weekly?.utilization))")
    expect(fiveHour?.resetsAt == ISO8601DateFormatter().date(from: "2026-10-30T03:40:00+00:00"),
           "account-usage: a microsecond ISO reset must parse to its instant, got \(String(describing: fiveHour?.resetsAt))")
    expect(usage?.windows.map(\.kind) == [.fiveHour, .sevenDay],
           "account-usage: only the 5-hour and weekly windows are windows; extra_usage and the scoped rows are not, got \(String(describing: usage?.windows.map(\.kind)))")
    expect(usage?.credits?.planLabel == "max",
           "account-usage: the plan rides along with the reading")
    let signedOut = AgentAccountUsageProbe.parseClaudeUsage(
        controlResponseLine: fixture("claude-2.1.312-get-usage-signed-out.json"), observedAt: observedAt)
    expect(signedOut != nil && signedOut! == nil,
           "account-usage: a signed-out dir's answer is the answer, with no reading — never a row of zeros")
    expect(AgentAccountUsageProbe.parseClaudeUsage(
            controlResponseLine: #"{"type":"system","subtype":"hook_started"}"#, observedAt: observedAt) == nil,
           "account-usage: a frame that is not the get_usage answer must not end the read")

    // (B) Identity.
    let claudeIdentity = AgentAccountIdentity.claude(
        authStatusJSON: Data(fixture("claude-2.1.312-auth-status.json").utf8), observedAt: observedAt)
    expect(claudeIdentity?.email == "personal@example.com"
            && claudeIdentity?.organizationId == "00000000-0000-4000-8000-000000000001"
            && claudeIdentity?.planDisplayName == "Max",
           "account-usage: auth status must name the login and its plan, got \(String(describing: claudeIdentity))")
    expect(AgentAccountIdentity.claude(
            authStatusJSON: Data(#"{"loggedIn":false,"authMethod":"none"}"#.utf8), observedAt: observedAt) == nil,
           "account-usage: a signed-out claude has no identity")
    let codexIdentity = AgentAccountIdentity.codex(
        accountReadResult: object(fixture("codex-0.165-account-read.json"))["result"] as? [String: Any] ?? [:],
        observedAt: observedAt)
    expect(codexIdentity?.email == "chatgpt@example.com" && codexIdentity?.planDisplayName == "Pro Lite",
           "account-usage: codex account/read must name the login and plan, got \(String(describing: codexIdentity))")
    expect(AgentAccountIdentity.codex(accountReadResult: ["account": NSNull()], observedAt: observedAt) == nil,
           "account-usage: a signed-out codex has no identity")

    // (C) Codex on demand.
    let codexQuota = AgentAccountQuota.codexReadSnapshot(
        rateLimitsReadResult: object(fixture("codex-0.165-rate-limits-read.json"))["result"] as? [String: Any] ?? [:],
        observedAt: observedAt)
    expect(codexQuota?.source == .codexRateLimitsRead
            && codexQuota?.window(.sevenDay)?.utilization.map { abs($0 - 0.51) < 0.0001 } == true
            && codexQuota?.window(.fiveHour) == nil,
           "account-usage: codex's 10080-minute primary is weekly at 51% and there is no 5-hour window, got \(String(describing: codexQuota))")
    expect(codexQuota?.credits?.balance == "0" && codexQuota?.credits?.hasCredits == false,
           "account-usage: codex credits stay verbatim")

    // (D) The real spawn against a fake claude.
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("account-usage-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let authFile = root.appendingPathComponent("auth.json")
    let usageFile = root.appendingPathComponent("usage.jsonl")
    try? fixture("claude-2.1.312-auth-status.json").write(to: authFile, atomically: true, encoding: .utf8)
    try? (usageLine + "\n").write(to: usageFile, atomically: true, encoding: .utf8)
    let log = root.appendingPathComponent("calls.txt")
    let fake = root.appendingPathComponent("claude")
    // Signed in only for the default dir and for `work`; any other dir is
    // signed out, like a real fresh config dir.
    try? """
    #!/bin/sh
    echo "argv=$* dir=${CLAUDE_CONFIG_DIR:-<default>} home=$HOME" >> '\(log.path)'
    case "${CLAUDE_CONFIG_DIR:-}" in
      ""|*/work) signed=1 ;;
      *) signed=0 ;;
    esac
    if [ "$1" = auth ]; then
      if [ $signed = 1 ]; then cat '\(authFile.path)'; exit 0; fi
      echo '{"loggedIn":false,"authMethod":"none"}'; exit 1
    fi
    read -r request
    case "$request" in *'"subtype":"get_usage"'*) ;; *) exit 3 ;; esac
    echo '{"type":"system","subtype":"hook_started"}'
    cat '\(usageFile.path)'
    sleep 30
    """.write(to: fake, atomically: true, encoding: .utf8)
    _ = chmod(fake.path, 0o755)
    let command = PiAgentRunner.ResolvedCommand(executable: fake.path, prefixArgs: [])

    setenv("CLAUDE_CONFIG_DIR", "/tmp/inherited-should-not-leak", 1)
    defer { unsetenv("CLAUDE_CONFIG_DIR") }
    let started = Date()
    let defaultReading = AgentAccountUsageProbe.readClaude(
        command: command, configDirectory: nil, timeout: 10, now: { observedAt })
    let elapsed = Date().timeIntervalSince(started)
    expect(defaultReading.identity?.email == "personal@example.com"
            && defaultReading.quota?.window(.fiveHour)?.utilization.map { abs($0 - 0.11) < 0.0001 } == true,
           "account-usage: the default account must read its identity and 5-hour window through the real pipes, got \(defaultReading)")
    expect(elapsed < 5, "account-usage: the read must return on the answer, not wait for the CLI to exit (took \(elapsed)s)")

    let workDir = root.appendingPathComponent("work").path
    let workReading = AgentAccountUsageProbe.readClaude(
        command: command, configDirectory: workDir, timeout: 10, now: { observedAt })
    expect(workReading.quota?.window(.sevenDay) != nil,
           "account-usage: a named account dir must be read too, got \(workReading)")
    let freshReading = AgentAccountUsageProbe.readClaude(
        command: command, configDirectory: root.appendingPathComponent("fresh").path, timeout: 10, now: { observedAt })
    expect(freshReading.identity == nil && freshReading.quota == nil,
           "account-usage: a signed-out dir reads as nothing, got \(freshReading)")

    let calls = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
    expect(calls.count == 5,
           "account-usage: auth+usage for each signed-in dir and auth only for the signed-out one (5 calls), got \(calls)")
    expect(calls.prefix(2).allSatisfy { $0.contains("dir=<default>") },
           "account-usage: the default account must REMOVE an inherited CLAUDE_CONFIG_DIR, got \(calls.prefix(2))")
    expect(calls.dropFirst(2).prefix(2).allSatisfy { $0.contains("dir=\(workDir) ") },
           "account-usage: a named account must run with its own CLAUDE_CONFIG_DIR, got \(calls)")
    expect(calls.allSatisfy { $0.hasSuffix("home=\(home)") },
           "account-usage: HOME must never change, got \(calls)")
    expect(calls.filter { $0.contains("get_usage") || $0.contains("--input-format stream-json") }
            .allSatisfy { $0.contains("--no-session-persistence") && $0.contains("disableAllHooks") },
           "account-usage: the usage read must leave no session and run no hooks, got \(calls)")
    expect(!calls.last!.contains("stream-json"),
           "account-usage: a signed-out dir must not be asked for usage, got \(calls.last!)")
    expect(freshReading.signedOut && !defaultReading.signedOut,
           "account-usage: only the CLI answering loggedIn:false marks an account signed out")
    let silent = root.appendingPathComponent("claude-silent")
    try? "#!/bin/sh\nsleep 30\n".write(to: silent, atomically: true, encoding: .utf8)
    _ = chmod(silent.path, 0o755)
    let timedOut = AgentAccountUsageProbe.readClaude(
        command: PiAgentRunner.ResolvedCommand(executable: silent.path, prefixArgs: []),
        configDirectory: nil, timeout: 1, now: { observedAt })
    expect(timedOut.identity == nil && !timedOut.signedOut,
           "account-usage: a CLI that never answers says nothing about sign-in, got \(timedOut)")

    // (E) Slice 2 — the account store. An id, a label, a harness, a folder:
    // nothing that could be a credential, and the defaults never written.
    let support = root.appendingPathComponent("support", isDirectory: true)
    let accountStore = AgentAccountStore(applicationSupportDirectory: support)
    let work = accountStore.makeClaudeAccount(label: "Work", existing: [])
    let work2 = accountStore.makeClaudeAccount(label: "Work", existing: [work])
    expect(work.id == "claude.work" && work2.id == "claude.work-2",
           "account-usage: account ids are the label's slug, numbered past a taken one, got \(work.id), \(work2.id)")
    expect(work.configDirectory == support.appendingPathComponent("accounts/claude.work/claude").path,
           "account-usage: an added account's folder lives under Array's Application Support, got \(String(describing: work.configDirectory))")
    let codexWork = accountStore.makeAccount(harness: .codex, label: "Work", existing: [work])
    expect(codexWork.id == "codex.work"
            && codexWork.configDirectory == support.appendingPathComponent("accounts/codex.work/codex").path,
           "account-usage: a Codex account is its own CODEX_HOME under Application Support, got \(codexWork)")
    do {
        try accountStore.save(.init(
            accounts: [AgentAccount.defaultAccount(for: .claudeCode), work, codexWork],
            active: [AgentHarness.claudeCode.rawValue: work.id]))
    } catch {
        expect(false, "account-usage: saving accounts failed: \(error)")
    }
    expect(accountStore.load() == .init(accounts: [work, codexWork], active: [AgentHarness.claudeCode.rawValue: work.id]),
           "account-usage: only added accounts and the account in use per CLI are stored, got \(accountStore.load())")
    let stored = (try? Data(contentsOf: support.appendingPathComponent("accounts.json")))
        .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    let keys = Set(((stored?["accounts"] as? [[String: Any]])?.first ?? [:]).keys)
    expect(keys == ["id", "label", "harness", "configDirectory"],
           "account-usage: an account record holds an id, label, harness and folder only, got \(keys.sorted())")

    // (F) The Work folder shares settings with Personal, and NOTHING that
    // belongs to a login or a session.
    let personalDir = root.appendingPathComponent("personal-claude", isDirectory: true)
    try? fm.createDirectory(at: personalDir.appendingPathComponent("agents"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: personalDir.appendingPathComponent("skills"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: personalDir.appendingPathComponent("projects"), withIntermediateDirectories: true)
    for name in ["settings.json", "CLAUDE.md", ".claude.json", ".credentials.json", "history.jsonl"] {
        try? "{}".write(to: personalDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let workDirURL = URL(fileURLWithPath: work.configDirectory!, isDirectory: true)
    let linked = (try? AgentAccountSetup.prepareClaudeConfigDirectory(workDirURL, sharingFrom: personalDir)) ?? []
    expect(Set(linked) == ["settings.json", "CLAUDE.md", "agents", "skills", "projects"],
           "account-usage: the shared items that exist are linked (commands is absent here), got \(linked)")
    for name in linked {
        let destination = try? fm.destinationOfSymbolicLink(atPath: workDirURL.appendingPathComponent(name).path)
        expect(destination == personalDir.appendingPathComponent(name).path,
               "account-usage: \(name) must link back to the personal folder, got \(String(describing: destination))")
    }
    let present = Set((try? fm.contentsOfDirectory(atPath: workDirURL.path)) ?? [])
    expect(present.isDisjoint(with: [".claude.json", ".credentials.json", "history.jsonl"]),
           "account-usage: login state and history must never be shared, found \(present.sorted())")
    try? "{\"theme\":\"dark\"}".write(to: workDirURL.appendingPathComponent("settings.json"), atomically: false, encoding: .utf8)
    expect((try? String(contentsOf: personalDir.appendingPathComponent("settings.json"), encoding: .utf8)) == "{\"theme\":\"dark\"}",
           "account-usage: a settings edit through Work is the one shared settings file")
    let ownDir = root.appendingPathComponent("own-settings", isDirectory: true)
    try? fm.createDirectory(at: ownDir, withIntermediateDirectories: true)
    try? "own".write(to: ownDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
    let ownLinked = (try? AgentAccountSetup.prepareClaudeConfigDirectory(ownDir, sharingFrom: personalDir)) ?? []
    expect(!ownLinked.contains("settings.json")
            && (try? String(contentsOf: ownDir.appendingPathComponent("settings.json"), encoding: .utf8)) == "own",
           "account-usage: a file the account already has is never replaced")
    expect(((try? AgentAccountSetup.prepareClaudeConfigDirectory(workDirURL, sharingFrom: personalDir)) ?? ["x"]).isEmpty,
           "account-usage: preparing twice links nothing new")

    // (I) Slice 3 — moving a conversation between accounts. Shared
    // `projects/` (the normal case) needs nothing; a folder with its own
    // `projects/` gets the session file and its sidecar folder copied in.
    let sessionId = "11111111-2222-4333-8444-555555555555"
    let sessionCwd = "/Users/example/Projects/array"
    let slug = ClaudeAgentStateReader.encodeCwd(sessionCwd)
    let personalSessions = personalDir.appendingPathComponent("projects/\(slug)", isDirectory: true)
    try? fm.createDirectory(at: personalSessions.appendingPathComponent("\(sessionId)/subagents"), withIntermediateDirectories: true)
    try? "turn 1\n".write(to: personalSessions.appendingPathComponent("\(sessionId).jsonl"), atomically: true, encoding: .utf8)
    try? "child\n".write(to: personalSessions.appendingPathComponent("\(sessionId)/subagents/agent-1.jsonl"), atomically: true, encoding: .utf8)
    expect((try? AgentAccountSetup.ensureSessionVisible(
            sessionId: sessionId, cwd: sessionCwd, from: personalDir, to: workDirURL)) == .shared
            && fm.fileExists(atPath: workDirURL.appendingPathComponent("projects/\(slug)/\(sessionId).jsonl").path),
           "account-usage: through the shared projects/, Work already sees Personal's conversation")
    let ownProjects = root.appendingPathComponent("own-projects", isDirectory: true)
    try? fm.createDirectory(at: ownProjects.appendingPathComponent("projects/\(slug)"), withIntermediateDirectories: true)
    try? "stale\n".write(to: ownProjects.appendingPathComponent("projects/\(slug)/\(sessionId).jsonl"), atomically: true, encoding: .utf8)
    let moved = try? AgentAccountSetup.ensureSessionVisible(
        sessionId: sessionId, cwd: sessionCwd, from: personalDir, to: ownProjects)
    expect(moved == .copied
            && (try? String(contentsOf: ownProjects.appendingPathComponent("projects/\(slug)/\(sessionId).jsonl"), encoding: .utf8)) == "turn 1\n"
            && fm.fileExists(atPath: ownProjects.appendingPathComponent("projects/\(slug)/\(sessionId)/subagents/agent-1.jsonl").path),
           "account-usage: a folder with its own projects/ gets the current session and its sidecars, replacing a stale copy (got \(String(describing: moved)))")
    expect((try? AgentAccountSetup.ensureSessionVisible(
            sessionId: "no-such-session", cwd: sessionCwd, from: personalDir, to: ownProjects)) == .missing,
           "account-usage: a session that does not exist yet is reported missing, not invented")

    // (J) The runner's environment: CLAUDE_CONFIG_DIR only for an added
    // account, an inherited one removed for the default, HOME never touched.
    setenv("CLAUDE_CONFIG_DIR", "/tmp/inherited", 1)
    let workEnv = ClaudeAgentRunner.childEnvironment(workspaceMCP: nil, configDirectory: work.configDirectory)
    let personalEnv = ClaudeAgentRunner.childEnvironment(workspaceMCP: nil, configDirectory: nil)
    unsetenv("CLAUDE_CONFIG_DIR")
    expect(workEnv["CLAUDE_CONFIG_DIR"] == work.configDirectory && personalEnv["CLAUDE_CONFIG_DIR"] == nil
            && workEnv["HOME"] == ProcessInfo.processInfo.environment["HOME"]
            && personalEnv["HOME"] == ProcessInfo.processInfo.environment["HOME"],
           "account-usage: the runner sets CLAUDE_CONFIG_DIR for Work only and never HOME")

    // (K) Codex: a Codex account's home shares config and sessions, never
    // auth.json; the runner and the probe pass CODEX_HOME for it.
    let personalCodex = root.appendingPathComponent("personal-codex", isDirectory: true)
    try? fm.createDirectory(at: personalCodex.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    for name in ["config.toml", "AGENTS.md", "auth.json", "history.jsonl"] {
        try? "x".write(to: personalCodex.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let codexHomeURL = URL(fileURLWithPath: codexWork.configDirectory!, isDirectory: true)
    let codexLinked = (try? AgentAccountSetup.prepareDirectory(
        codexHomeURL, sharing: AgentAccountSetup.sharedItems(for: .codex), from: personalCodex)) ?? []
    expect(Set(codexLinked) == ["config.toml", "AGENTS.md", "sessions"]
            && !fm.fileExists(atPath: codexHomeURL.appendingPathComponent("auth.json").path),
           "account-usage: a Codex home shares config, instructions and sessions, never auth.json, got \(codexLinked)")
    let codexEnv = CodexAgentRunner.childEnvironment(workspaceMCP: nil, codexHome: codexWork.configDirectory)
    expect(codexEnv["CODEX_HOME"] == codexWork.configDirectory
            && codexEnv["HOME"] == ProcessInfo.processInfo.environment["HOME"],
           "account-usage: the Codex runner passes the account's CODEX_HOME and never HOME")
    expect(AgentAccountSetup.codexSignInArguments(for: codexWork, codexExecutable: "/opt/bin/codex")
            == ["CODEX_HOME=\(codexWork.configDirectory!)", "/opt/bin/codex", "login"],
           "account-usage: Codex Work signs in with codex login in its own home")

    // (G) Readings filed by ACCOUNT: two logins on one CLI never overwrite
    // each other, and a file from before accounts restores to the default.
    let quotaDir = root.appendingPathComponent("quota", isDirectory: true)
    try? fm.createDirectory(at: quotaDir, withIntermediateDirectories: true)
    let future = Date().addingTimeInterval(3_600)
    func reading(_ used: Double, accountId: String? = nil) -> AgentAccountQuotaSnapshot {
        AgentAccountQuotaSnapshot(
            harness: .claudeCode,
            windows: [AgentQuotaWindow(kind: .fiveHour, utilization: used, resetsAt: future)],
            observedAt: Date(), source: .claudeUsageRequest, accountId: accountId)
    }
    let quotaStore = AgentAccountQuotaStore(applicationSupportDirectory: quotaDir)
    quotaStore.save([AgentAccount.defaultAccountId(for: .claudeCode): reading(0.16), work.id: reading(0.40)])
    let both = quotaStore.restore(now: Date())
    expect(both[AgentAccount.defaultAccountId(for: .claudeCode)]?.window(.fiveHour)?.utilization == 0.16
            && both[work.id]?.window(.fiveHour)?.utilization == 0.40,
           "account-usage: Personal and Work readings must both survive, got \(both.mapValues { $0.window(.fiveHour)?.utilization })")
    let legacyDir = root.appendingPathComponent("legacy", isDirectory: true)
    try? fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)
    struct LegacyPayload: Encodable { var snapshots: [AgentAccountQuotaSnapshot] }
    let legacyData = try? JSONCodec.makeEncoder().encode(LegacyPayload(snapshots: [reading(0.33)]))
    expect(legacyData.map { !String(decoding: $0, as: UTF8.self).contains("accountId") } == true,
           "account-usage: the legacy fixture must carry no accountId")
    try? legacyData?.write(to: legacyDir.appendingPathComponent("account-quotas.json"))
    let migrated = AgentAccountQuotaStore(applicationSupportDirectory: legacyDir).restore(now: Date())
    expect(migrated.keys.sorted() == [AgentAccount.defaultAccountId(for: .claudeCode)]
            && migrated.values.first?.window(.fiveHour)?.utilization == 0.33,
           "account-usage: a reading saved before accounts belongs to the default account, got \(migrated.keys.sorted())")

    // (H) Sign-in is Claude's own login, in the account's folder.
    expect(AgentAccountSetup.claudeSignInArguments(for: work, claudeExecutable: "/opt/bin/claude")
            == ["CLAUDE_CONFIG_DIR=\(work.configDirectory!)", "/opt/bin/claude", "auth", "login", "--claudeai"],
           "account-usage: Work signs in with claude auth login in its own folder")
    expect(AgentAccountSetup.claudeSignInArguments(
            for: AgentAccount.defaultAccount(for: .claudeCode), claudeExecutable: "/opt/bin/claude")
            == ["/opt/bin/claude", "auth", "login", "--claudeai"],
           "account-usage: Personal signs in with no folder override")

    print("AgentAccountUsage checks passed: get_usage reads percent windows with ISO resets, ignores extra_usage, and a signed-out answer is no reading; auth status and codex account/read name the login and plan; codex rateLimits/read is weekly-only; the real spawn reads the default and a named dir with CLAUDE_CONFIG_DIR set or removed, HOME untouched, no session left and no usage asked of a signed-out dir; only an answered loggedIn:false reads as signed out; added accounts store an id, label, harness and folder only; the Work folder links settings, CLAUDE.md, agents, skills, commands and projects back to Personal and never login state or history; a switch finds the conversation through the shared projects/ or copies it and its sidecars into a folder with its own; the runner sets CLAUDE_CONFIG_DIR for an added account only and never HOME; readings are filed by account and an old file migrates to the default; sign-in is claude auth login in the account's folder")
}

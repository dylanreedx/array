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

    print("AgentAccountUsage checks passed: get_usage reads percent windows with ISO resets, ignores extra_usage, and a signed-out answer is no reading; auth status and codex account/read name the login and plan; codex rateLimits/read is weekly-only; the real spawn reads the default and a named dir with CLAUDE_CONFIG_DIR set or removed, HOME untouched, no session left and no usage asked of a signed-out dir")
}

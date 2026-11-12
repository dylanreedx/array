import AppKit
import ContinuumRevivedCore
import Foundation

/// `.plans/116` gaps 20 and 21, and part 1's strict lead. A Managed Claude
/// lead runs through the production runner and translator over a CLI double
/// that replays recorded Bash frame shapes and really changes the files they
/// describe, in a temporary git checkout. The ledger file the host wrote is
/// read back.
///
/// - `seen`: the lead's own shell writes are recorded (modified, added,
///   deleted), a build into an ignored directory and a read-only command are
///   not, a write while the first helper (same checkout) has a turn open is
///   `ambiguous`, and the helper's own writes are never the lead's.
@MainActor
enum LeadCheckoutChecks {
    typealias Step = HelperEvidenceChecks.Step
    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw WorkspaceAgentReportChecks.Failure(description: "lead-checkout: " + message) }
    }

    /// The helper-evidence double, plus `{"__delete": path}`.
    /// A helper's brief quotes its lead's request, so the LAST `FRAMES-x` names its own.
    static let claude = HelperEvidenceChecks.claude.replacingOccurrences(
        of: "        if '__write' in o:", with: "        if '__delete' in o: os.unlink(o['__delete'])\n        elif '__sleep' in o: time.sleep(o['__sleep'])\n        elif '__write' in o:")
        .replacingOccurrences(of: "    f = re.search(r'FRAMES-([a-z0-9]+)', json.dumps(o))\n",
                              with: "    f = ([None] + list(re.finditer(r'FRAMES-([a-z0-9]+)', json.dumps(o))))[-1]\n")

    static func frames(_ steps: [Step], root: URL, deleting: [String: String] = [:]) throws -> String {
        var frames: [[String: Any]] = []
        for step in steps {
            var some = HelperEvidenceChecks.claudeFrames([step], root: root)
            if case let .shell(id, _, _, _) = step, let path = deleting[id] { some.insert(["__delete": path], at: 1) }
            // A real lead's next call waits on a model turn; one second stands in.
            frames += (frames.isEmpty ? [] : [["__sleep": 1.0]]) + some
        }
        let lines = try frames.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        return lines.joined(separator: "\n") + "\n"
    }

    static func run() async throws {
        let section = ProcessInfo.processInfo.environment["CONTINUUM_LEAD_CHECKOUT_CASE"]
        if section == nil || section == "seen" { try await seen() }
        if section == nil || section == "hooks" { try await hooks() }
        if section == nil || section == "strict" || section == "strict-claude" { try await strictClaude() }
        if section == nil || section == "strict" || section == "strict-codex" { try await strictCodex() }
    }

    /// How the switch is set for one bench.
    enum Switch { case off, defaults, environment }
    static func set(_ value: Switch, _ b: WorkspaceAgentReportChecks.Bench) -> () -> Void {
        let old = ProcessInfo.processInfo.environment[ManagedStrictLead.environmentKey]
        switch value {
        case .off: unsetenv(ManagedStrictLead.environmentKey)
        case .defaults: unsetenv(ManagedStrictLead.environmentKey); b.settings.set(true, forKey: ManagedStrictLead.enabledKey)
        case .environment: setenv(ManagedStrictLead.environmentKey, "1", 1)
        }
        return { if let old { setenv(ManagedStrictLead.environmentKey, old, 1) } else { unsetenv(ManagedStrictLead.environmentKey) } }
    }

    /// The one `--settings` value a real launch passed, parsed.
    static func settings(_ argv: [String]) throws -> [String: Any] {
        guard let index = argv.lastIndex(of: "--settings"), index + 1 < argv.count,
              let object = try JSONSerialization.jsonObject(with: Data(argv[index + 1].utf8)) as? [String: Any] else {
            throw WorkspaceAgentReportChecks.Failure(description: "lead-checkout: no --settings in \(argv)")
        }
        return object
    }

    /// Part 1's strict lead, Claude: the production launch of a Managed lead
    /// carries the CLI's sandbox, denying writes in its checkout, only when the
    /// switch is on (by its defaults key or its environment variable), and
    /// never for the lead's helper.
    static func strictClaude() async throws {
        for condition in [Switch.off, .defaults, .environment] {
            let b = try ManagedModeChecks.bench("lead-strict")
            defer { b.tearDown() }
            let restore = set(condition, b)
            defer { restore() }
            let (lead, root) = try HelperEvidenceChecks.prepare(b)
            let supervisor = b.supervisor
            try expect(await supervisor.accept(.sendPrompt(AgentPrompt("HOLD-strict")), for: lead) == .accepted, "lead submission refused")
            try await AgentPresenceChecks.eventually("lead-checkout: strict lead did not start", timeout: 20) { supervisor.isRunning(lead) }
            let reply = try await WorkspaceAgentReportChecks.call(b.configuration(for: lead), "array_delegate", [
                "task": "HOLD-strictchild", "title": "Child", "harness": "Claude Code",
                "model": ManagedModeChecks.model, "idempotencyKey": UUID().uuidString])
            guard let raw = (reply.reply["result"] as? [String: Any])?["childAgentId"] as? String, let uuid = UUID(uuidString: raw) else {
                throw WorkspaceAgentReportChecks.Failure(description: "lead-checkout: strict delegation failed: \(reply.reply)")
            }
            let child = AgentID(rawValue: uuid)
            try await AgentPresenceChecks.eventually("lead-checkout: strict child did not launch", timeout: 20) {
                (try? ManagedModeChecks.argv(b, child)) != nil
            }
            let leadSettings = try settings(ManagedModeChecks.argv(b, lead))
            let childSettings = try settings(ManagedModeChecks.argv(b, child))
            let sandbox = leadSettings["sandbox"] as? [String: Any]
            if condition == .off {
                try expect(sandbox == nil, "the switch is off but the lead launched sandboxed: \(sandbox ?? [:])")
            } else {
                let denied = Set(((sandbox?["filesystem"] as? [String: Any])?["denyWrite"] as? [String]) ?? [])
                try expect(sandbox?["enabled"] as? Bool == true && sandbox?["failIfUnavailable"] as? Bool == true
                           && sandbox?["allowUnsandboxedCommands"] as? Bool == false,
                           "\(condition): the lead's sandbox is not on, required and closed: \(sandbox ?? [:])")
                try expect(denied.contains(root.resolvingSymlinksInPath().path) && denied.contains(supervisor.records[lead]!.checkoutRoot),
                           "\(condition): the lead's checkout is not denied for writing: \(denied)")
                try expect(leadSettings["hooks"] != nil, "\(condition): the strict lead lost its hooks")
            }
            try expect(childSettings["sandbox"] == nil, "\(condition): the lead's helper launched sandboxed")
            for marker in ["release-strict", "release-strictchild"] { try Data().write(to: root.appendingPathComponent(marker)) }
        }
        print("Lead strict Claude passed: off by default the lead launches with no sandbox; on by \(ManagedStrictLead.enabledKey) or \(ManagedStrictLead.environmentKey) its one --settings carries the CLI sandbox, required, with no unsandboxed escape and its checkout denied for writing, hooks kept; its helper never sandboxed")
    }

    /// Codex is not covered by the switch: with it on by either name, a Managed
    /// Codex lead launches exactly as with it off (frozen argv, full access
    /// pinned on thread and turn), because nothing can pin a strict profile on
    /// resume (`ManagedStrictLead`).
    static func strictCodex() async throws {
        for condition in [Switch.off, .defaults, .environment] {
            let b = try ManagedCodexChecks.bench()
            let restoreRun = ManagedCodexChecks.runEnvironment(b)
            let restore = set(condition, b)
            defer { b.tearDown(); restoreRun(); restore() }
            let lead = try await ManagedCodexChecks.delegate(b, mode: "managed")
            try await ManagedModeChecks.settled(b, lead)
            let session = try ManagedCodexChecks.thread(b, lead)
            guard let launch = ManagedCodexChecks.rows(b, kind: "launch", session: session).last,
                  let argv = launch["argv"] as? [String],
                  let thread = (launch["request"] as? [String: Any])?["params"] as? [String: Any],
                  let turn = (ManagedCodexChecks.rows(b, kind: "turn", session: session).last?["request"] as? [String: Any])?["params"] as? [String: Any] else {
                throw WorkspaceAgentReportChecks.Failure(description: "lead-checkout: Codex launch, thread or turn not recorded")
            }
            try expect(argv == (try ManagedCodexChecks.previousArguments(b.configuration(for: lead))), "Codex \(condition): the launch argv changed")
            try expect(thread["sandbox"] as? String == "danger-full-access" && (turn["sandboxPolicy"] as? [String: Any])?["type"] as? String == "dangerFullAccess",
                       "Codex \(condition): full access is no longer pinned: \(thread) \(turn)")
        }
        print("Lead strict Codex passed: off and on by either name, a Managed Codex lead's argv, thread and turn are unchanged (Codex is not covered by the switch)")
    }

    /// Gap 21: each hook a Managed lead's CLI runs reaches the ledger as one
    /// compact row, through the real hook binary and the production handler.
    static func hooks() async throws {
        let b = try ManagedModeChecks.bench("lead-hooks")
        defer { b.tearDown() }
        let (lead, root) = try HelperEvidenceChecks.prepare(b)
        let supervisor = b.supervisor
        try expect(await supervisor.accept(.sendPrompt(AgentPrompt("HOLD-hooks")), for: lead) == .accepted, "lead submission refused")
        try await AgentPresenceChecks.eventually("lead-checkout: lead did not start", timeout: 20) { supervisor.isRunning(lead) }
        let reply = try await WorkspaceAgentReportChecks.call(b.configuration(for: lead), "array_delegate", [
            "task": "HOLD-child", "title": "Child", "harness": "Claude Code",
            "model": ManagedModeChecks.model, "idempotencyKey": UUID().uuidString])
        guard let raw = (reply.reply["result"] as? [String: Any])?["childAgentId"] as? String, let uuid = UUID(uuidString: raw) else {
            throw WorkspaceAgentReportChecks.Failure(description: "lead-checkout: delegation failed: \(reply.reply)")
        }
        let child = AgentID(rawValue: uuid)
        func send(_ agent: AgentID, _ body: [String: Any]) async throws {
            let config = try b.configuration(for: agent)
            let text = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
            // Off main, so the production handler can answer on main meanwhile.
            let arguments = [WorkspaceAgentHook.subcommand, "--endpoint", config.endpoint, "--agent-id", agent.rawValue.uuidString,
                             "--token-file", config.tokenFilePath]
            let helper = b.helper
            let status = await Task.detached { () -> (Int32, String) in
                let process = Process(), input = Pipe(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: helper)
                process.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                environment[PiAgentRunner.arrayHostedEnvironmentKey] = "1"
                process.environment = environment
                process.standardInput = input; process.standardOutput = output
                guard (try? process.run()) != nil else { return (-1, "") }
                input.fileHandleForWriting.write(Data(text.utf8))
                try? input.fileHandleForWriting.close()
                let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                return (process.terminationStatus, printed)
            }.value
            try expect(status.0 == 0, "the hook command failed: \(status)")
        }
        let session = "hooks-session"
        try await send(lead, ["hook_event_name": "SessionStart", "source": "startup", "session_id": session])
        try await send(lead, ["hook_event_name": "UserPromptSubmit", "session_id": session, "prompt": "SECRET-HOOK-PROMPT"])
        try await send(lead, ["hook_event_name": "PreToolUse", "session_id": session, "tool_name": "Bash",
                        "tool_input": ["command": "SECRET-HOOK-CMD"]])
        try await send(lead, ["hook_event_name": "PostToolUse", "session_id": session, "tool_name": "Bash",
                        "tool_input": ["command": "SECRET-HOOK-CMD"], "tool_response": ["stdout": "SECRET-HOOK-OUT"]])
        try await send(lead, ["hook_event_name": "SECRET-HOOK-EVENT", "session_id": session])
        try await send(child, ["hook_event_name": "PreToolUse", "session_id": "child", "tool_name": "Bash", "tool_input": ["command": "true"]])
        supervisor.runLedger.drain()

        let ledgerURL = AgentStore(smokeTest: false).layout.applicationSupportDirectory.appendingPathComponent("run-ledger/ledger.jsonl")
        let text = (try? String(contentsOf: ledgerURL, encoding: .utf8)) ?? ""
        let rows = ManagedRunLedgerChecks.rows(ledgerURL, "hook")
        let task = ManagedRunLedgerChecks.rows(ledgerURL, "taskOpened", agent: lead).first?["task"] as? String
        var failures: [String] = []
        func check(_ ok: Bool, _ message: @autoclosure () -> String) { if !ok { failures.append(message()) } }
        let leadRows = rows.filter { $0["agent"] as? String == lead.rawValue.uuidString }
        check(leadRows.map { $0["hook"] as? String ?? "" } == ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "other"],
              "hooks recorded: \(leadRows.map { $0["hook"] ?? "nil" })")
        check(leadRows.map { $0["outcome"] as? String ?? "" } == ["context", "none", "none", "none", "none"],
              "outcomes recorded: \(leadRows.map { $0["outcome"] ?? "nil" })")
        check(leadRows.allSatisfy { $0["task"] as? String == task && $0["harness"] as? String == AgentHarness.claudeCode.rawValue },
              "hook rows not under the lead's task and harness: \(leadRows)")
        check(!rows.contains { $0["agent"] as? String == child.rawValue.uuidString }, "a helper's hook was recorded as a lead's")
        for secret in ["SECRET-HOOK-PROMPT", "SECRET-HOOK-CMD", "SECRET-HOOK-OUT", "SECRET-HOOK-EVENT", session, "You are an Array Managed lead"]
        where text.contains(secret) { check(false, "ledger stores \(secret)") }
        for row in ManagedRunLedgerChecks.rows(ledgerURL) {
            check(Set(row.keys).isSubset(of: ManagedRunLedgerChecks.allowedKeys), "unexpected row keys: \(row.keys.sorted())")
        }
        for marker in ["release-hooks", "release-child"] { try Data().write(to: root.appendingPathComponent(marker)) }
        if !failures.isEmpty { throw WorkspaceAgentReportChecks.Failure(description: "lead-checkout hooks:\n- " + failures.joined(separator: "\n- ")) }
        print("Lead hooks passed: five hook receipts of a Managed lead, through the real hook binary, each one ledger row under its task: event named (an unknown event as other), Array's answer as the outcome (the brief as context), no prompt, command, output, session or brief text; a helper's hook not recorded")
    }

    static func seen() async throws {
        let b = try ManagedModeChecks.bench("lead-checkout")
        defer { b.tearDown() }
        let (lead, root) = try HelperEvidenceChecks.prepare(b)
        try expect(claude.contains("__delete") && claude.contains("finditer(r'FRAMES"), "the Claude double changed shape")
        try claude.write(to: b.binDir.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        let ignore = root.appendingPathComponent(".gitignore")
        try (try String(contentsOf: ignore, encoding: .utf8) + ".build/\n").write(to: ignore, atomically: true, encoding: .utf8)
        for arguments in [["add", "-A"], ["commit", "-q", "-m", "ignore builds"]] { try HelperEvidenceChecks.git(arguments, root) }
        let supervisor = b.supervisor
        func wait(_ message: String, timeout: TimeInterval = 20, _ condition: @escaping @MainActor () -> Bool) async throws {
            try await AgentPresenceChecks.eventually("lead-checkout: " + message, timeout: timeout, condition)
        }
        var ended = Set<String>()
        _ = supervisor.addRuntimeObservationObserver(for: lead) { observation in
            if case let .toolDetail(call, detail) = observation, detail.phase == .ended { ended.insert(call) }
        }
        func marker(_ name: String) throws { try Data().write(to: root.appendingPathComponent(name)) }

        // Turn 1, no helper: the lead edits through its shell.
        try frames([.shellWrite("w1", "python3 -c SECRET-CMD", "Sources/Eps.swift"),
                    .shellWrite("w2", "cat > docs/new.md <<EOF", "docs/new.md"),
                    .shell("d1", "rm docs/notes.md", exit: 0),
                    .shellWrite("b1", "swift build", ".build/debug/out.o"),
                    .shell("g1", "git status --short", exit: 0)],
                   root: root, deleting: ["d1": "docs/notes.md"])
            .write(to: root.appendingPathComponent("frames-solo.jsonl"), atomically: true, encoding: .utf8)
        try marker("go-solo")
        try expect(await supervisor.accept(.sendPrompt(AgentPrompt("FRAMES-solo HOLD-solo SECRET-PROMPT")), for: lead) == .accepted,
                   "lead submission refused")
        try await wait("solo frames not observed") { ended.contains("toolu_g1") }
        try marker("release-solo")
        try await wait("solo turn did not end") { !supervisor.isRunning(lead) }

        // Turn 2: the first helper shares the lead's checkout and has a turn open
        // while the lead's shell writes.
        try expect(await supervisor.accept(.sendPrompt(AgentPrompt("FRAMES-busy HOLD-busy")), for: lead) == .accepted,
                   "second submission refused")
        try await wait("lead did not start") { supervisor.isRunning(lead) }
        let reply = try await WorkspaceAgentReportChecks.call(b.configuration(for: lead), "array_delegate", [
            "task": "FRAMES-shared HOLD-shared SECRET-BRIEF", "title": "Shared", "harness": "Claude Code",
            "model": ManagedModeChecks.model, "idempotencyKey": UUID().uuidString])
        guard !reply.isError, let raw = (reply.reply["result"] as? [String: Any])?["childAgentId"] as? String,
              let uuid = UUID(uuidString: raw) else {
            throw WorkspaceAgentReportChecks.Failure(description: "lead-checkout: delegation failed: \(reply.reply)")
        }
        let helper = AgentID(rawValue: uuid)
        let helperRoot = URL(fileURLWithPath: supervisor.records[helper]!.checkoutRoot)
        try expect(helperRoot.resolvingSymlinksInPath() == root.resolvingSymlinksInPath(), "the first helper does not share the lead's checkout")
        try await wait("helper did not start") { supervisor.isRunning(helper) }
        try frames([.shellWrite("t1", "sed -i '' s/a/b/ Sources/Theta.swift", "Sources/Theta.swift")], root: root)
            .write(to: root.appendingPathComponent("frames-busy.jsonl"), atomically: true, encoding: .utf8)
        try marker("go-busy")
        try await wait("busy frames not observed") { ended.contains("toolu_t1") }
        try marker("release-busy")
        try await wait("busy turn did not end") { !supervisor.isRunning(lead) }

        // The helper's own shell write, after the lead's calls ended.
        var helperEnded = false
        _ = supervisor.addRuntimeObservationObserver(for: helper) { observation in
            if case let .toolDetail(call, detail) = observation, detail.phase == .ended, call == "toolu_h1" { helperEnded = true }
        }
        try frames([.shellWrite("h1", "echo b >> Sources/Beta.swift", "Sources/Beta.swift")], root: root)
            .write(to: root.appendingPathComponent("frames-shared.jsonl"), atomically: true, encoding: .utf8)
        try marker("go-shared")
        do { try await wait("helper frames not observed") { helperEnded } }
        catch {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            let argv = (try? String(contentsOf: root.appendingPathComponent("managed-argv.jsonl"), encoding: .utf8)) ?? ""
            throw WorkspaceAgentReportChecks.Failure(description: "\(error): helper running \(supervisor.isRunning(helper)), files \(names.sorted()), launches \(argv.split(separator: "\n").count), helper cwd \(supervisor.records[helper]?.cwd ?? "")")
        }
        try marker("release-shared")
        try await wait("helper and lead did not settle", timeout: 40) { !supervisor.isRunning(helper) && !supervisor.isRunning(lead) }
        supervisor.runLedger.drain()

        let ledgerURL = AgentStore(smokeTest: false).layout.applicationSupportDirectory.appendingPathComponent("run-ledger/ledger.jsonl")
        let text = (try? String(contentsOf: ledgerURL, encoding: .utf8)) ?? ""
        if ProcessInfo.processInfo.environment["LEAD_CHECKOUT_DUMP"] != nil { print("lead \(lead.rawValue) helper \(helper.rawValue)\n" + text) }
        let rows = ManagedRunLedgerChecks.rows(ledgerURL, "leadCheckoutChanged")
        let summary = rows.map { row in
            "\((row["source"] as? String ?? "").split(separator: "/").last ?? "") \((row["evidence"] as? [String: String])?["by"] ?? "") \(row["changed"] as? [String: Int] ?? [:]) \(row["paths"] as? [String] ?? [])"
        }.joined(separator: "\n  ")
        func row(_ call: String) -> [String: Any]? { rows.first { ($0["source"] as? String)?.hasSuffix("/toolu_" + call) == true } }
        var failures: [String] = []
        func check(_ ok: Bool, _ message: @autoclosure () -> String) { if !ok { failures.append(message()) } }
        func expectRow(_ call: String, _ changed: [String: Int], _ paths: [String], by: String) {
            guard let row = row(call) else { return check(false, "\(call): no row recorded") }
            check(row["agent"] as? String == lead.rawValue.uuidString, "\(call): row not on the lead: \(row)")
            check(row["changed"] as? [String: Int] == changed, "\(call): changed \(row["changed"] ?? "nil"), expected \(changed)")
            check(row["paths"] as? [String] == paths, "\(call): paths \(row["paths"] ?? "nil"), expected \(paths)")
            check((row["evidence"] as? [String: String])?["by"] == by, "\(call): attributed \(row["evidence"] ?? "nil"), expected \(by)")
        }
        expectRow("w1", ["modified": 1, "added": 0, "deleted": 0], ["Sources/Eps.swift"], by: "lead")
        expectRow("w2", ["modified": 0, "added": 1, "deleted": 0], ["docs/new.md"], by: "lead")
        expectRow("d1", ["modified": 0, "added": 0, "deleted": 1], ["docs/notes.md"], by: "lead")
        expectRow("t1", ["modified": 1, "added": 0, "deleted": 0], ["Sources/Theta.swift"], by: "ambiguous")
        check(row("b1") == nil, "a build into an ignored directory was recorded")
        check(row("g1") == nil, "a read-only command was recorded")
        check(!rows.contains { ($0["paths"] as? [String] ?? []).contains("Sources/Beta.swift") }, "the helper's own write was charged to the lead")
        check(rows.count == 4, "expected four rows, found \(rows.count)")
        let task = ManagedRunLedgerChecks.rows(ledgerURL, "taskOpened", agent: lead).first?["task"] as? String
        check(row("w1")?["task"] as? String == task, "the row is not under the lead's task")
        for secret in ["SECRET-CMD", "SECRET-PROMPT", "SECRET-BRIEF", "python3", "sed -i", root.path, root.resolvingSymlinksInPath().path]
        where text.contains(secret) { check(false, "ledger stores \(secret)") }
        for row in ManagedRunLedgerChecks.rows(ledgerURL) {
            check(Set(row.keys).isSubset(of: ManagedRunLedgerChecks.allowedKeys), "unexpected row keys: \(row.keys.sorted())")
        }
        if !failures.isEmpty { throw WorkspaceAgentReportChecks.Failure(description: "lead-checkout:\n- " + failures.joined(separator: "\n- ") + "\nrows:\n  " + summary) }
        print("Lead checkout seen passed: the lead's own shell modify, add and delete recorded as the lead's with checkout-relative paths; an ignored build and a read-only command not recorded; a write while the shared first helper had a turn open recorded ambiguous; the helper's own write never the lead's; no command, prompt or absolute path stored")
    }
}

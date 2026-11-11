import AppKit
import ContinuumRevivedCore
import Foundation

/// `.plans/116` part 8 step 1: shadow evidence of what a helper ran and edited.
/// A Managed Claude lead delegates one Claude and one Codex helper through the
/// production MCP binary into a temporary git checkout carrying a coverage
/// manifest in the gate pre-pass's format. Each helper's CLI double replays
/// provider frames in the recorded fixture shapes through the production runner
/// and translator; the helper files its report through `array_report`. The
/// whole run happens twice, recording on and off, and what the lead receives
/// must be the same bytes in the same order.
@MainActor
enum HelperEvidenceChecks {
    typealias Bench = WorkspaceAgentReportChecks.Bench
    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw WorkspaceAgentReportChecks.Failure(description: "helper-evidence: " + message) }
    }

    /// The ledger's Claude double, plus: every user message it receives is
    /// logged per session, and `FRAMES-x` replays `frames-x.jsonl` after init
    /// once `go-x` exists, then consumes the file: a wake quotes the brief.
    static let claude = ManagedRunLedgerChecks.script
        .replacingOccurrences(of: "    if o.get('type') != 'user': continue\n",
                              with: "    if o.get('type') != 'user': continue\n    open('inputs-' + sid + '.jsonl', 'a').write(line)\n")
        .replacingOccurrences(of: "    m = re.search(r'HOLD-([a-z0-9]+)', json.dumps(o))\n",
                              with: "    f = re.search(r'FRAMES-([a-z0-9]+)', json.dumps(o))\n    if f:\n        while not os.path.exists('go-' + f.group(1)): time.sleep(.02)\n    if f and os.path.exists('frames-' + f.group(1) + '.jsonl'):\n        for frame in open('frames-' + f.group(1) + '.jsonl'): print(frame.replace('SESSION', sid).strip(), flush=True)\n        os.rename('frames-' + f.group(1) + '.jsonl', 'replayed-' + f.group(1) + '.jsonl')\n    m = re.search(r'HOLD-([a-z0-9]+)', json.dumps(o))\n")

    /// The repository's Codex app-server double, plus `FRAMES-x` replay.
    static func codex() throws -> String {
        let source = try String(contentsOfFile: "scripts/fixtures/codex-hook-cli.py", encoding: .utf8)
        let anchor = "            hook('PreToolUse', 'apply_patch')\n"
        try expect(source.contains(anchor), "codex double changed shape")
        return source.replacingOccurrences(of: anchor, with: anchor + """
                    frames = re.search(r'FRAMES-([a-z0-9]+)', json.dumps(message))
                    if frames:
                        while not os.path.exists('go-' + frames.group(1)): time.sleep(.02)
                        for frame in open('frames-' + frames.group(1) + '.jsonl'): emit(json.loads(frame.replace('SESSION', session_id)))
                        os.rename('frames-' + frames.group(1) + '.jsonl', 'replayed-' + frames.group(1) + '.jsonl')

        """)
    }

    static let secrets = ["SECRET-CONTENT", "SECRET-DIFF", "SECRET-ARG", "SECRET-OUTPUT", "SECRET-PROMPT",
                          "SECRET-BRIEF", "SECRET-REPORT", "SECRET-CHECK", "/bin/zsh", "aggregatedOutput"]
    /// Words only the stored evidence uses. No agent may ever receive them.
    static let evidenceWords = ["evidence-alpha-check", "evidence-gamma-check", "evidence-delta-check",
                                "helperEvidence", "unmapped", "checkIncomplete", "notReportedByHarness"]

    static let manifest = """
    {"version": 1, "mappedLegs": 3, "checks": [
      {"invocation": ".build/debug/Array --evidence-alpha-check", "covers": ["Sources/Alpha.swift", "Sources/B*.swift"],
       "checkFiles": ["Sources/AlphaChecks.swift"], "owner": "fixture", "reason": "fixture"},
      {"invocation": ".build/debug/Array --evidence-gamma-check", "covers": ["Sources/**/Gamma.swift"],
       "checkFiles": ["Sources/GammaChecks.swift"], "owner": "fixture", "reason": "fixture"},
      {"invocation": ".build/debug/Array --evidence-delta-check", "covers": ["Sources/Delta.swift"],
       "checkFiles": ["Sources/DeltaChecks.swift"], "owner": "fixture", "reason": "fixture"}
    ], "targetedOnly": [], "exceptions": []}
    """

    /// One helper's turn: edit Alpha, 140 unrelated shell calls (past the old
    /// 128-receipt ring), run the alpha check, edit Beta (alpha covers it),
    /// edit Gamma and start the gamma check without it finishing, write Delta
    /// with no delta run, and edit an unmapped document.
    enum Step { case edit(String, String), write(String, String), shell(String, String, ends: Bool) }
    static let steps: [Step] = [.edit("e1", "Sources/Alpha.swift")]
        + (0..<70).map { .shell("n\($0)", "ls -la", ends: true) }
        + [.shell("c1", ".build/debug/Array --evidence-alpha-check SECRET-ARG", ends: true),
           .edit("e2", "Sources/Beta.swift"), .edit("e3", "Sources/Gamma.swift"),
           .shell("c2", ".build/debug/Array --evidence-gamma-check", ends: false),
           .write("e4", "Sources/Delta.swift"), .edit("e5", "docs/notes.md")]

    /// Claude stream-json frames in the recorded fixture shapes
    /// (claude-background-result-turn.jsonl: Bash tool_use and its tool_result;
    /// claude-subagent-turn.jsonl: a `file_path` input, here on Edit and Write).
    static func claudeFrames(root: URL) -> [[String: Any]] {
        func use(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] {
            ["type": "assistant", "parent_tool_use_id": NSNull(), "session_id": "SESSION",
             "message": ["model": "claude-haiku-5-5", "id": "msg_" + id, "type": "message", "role": "assistant",
                         "content": [["type": "tool_use", "id": "toolu_" + id, "name": name, "input": input]]]]
        }
        func result(_ id: String, _ text: String) -> [String: Any] {
            ["type": "user", "parent_tool_use_id": NSNull(), "session_id": "SESSION",
             "message": ["role": "user", "content": [["tool_use_id": "toolu_" + id, "type": "tool_result", "content": text, "is_error": false]]]]
        }
        return steps.flatMap { step -> [[String: Any]] in
            switch step {
            case let .edit(id, path):
                return [use(id, "Edit", ["file_path": root.appendingPathComponent(path).path, "old_string": "a", "new_string": "SECRET-CONTENT"]),
                        result(id, "The file has been updated.")]
            case let .write(id, path):
                return [use(id, "Write", ["file_path": root.appendingPathComponent(path).path, "content": "SECRET-CONTENT"]),
                        result(id, "File created successfully.")]
            case let .shell(id, command, ends):
                let started = use(id, "Bash", ["command": command, "description": "Run"])
                return ends ? [started, result(id, "SECRET-OUTPUT")] : [started]
            }
        }
    }

    /// Codex app-server frames in the recorded shapes of
    /// codex-appserver-single-agent.jsonl (commandExecution with `exitCode`,
    /// fileChange with `changes[].path` and `diff`). Beta and Gamma share one call.
    static func codexFrames(root: URL) -> [[String: Any]] {
        func item(_ method: String, _ item: [String: Any]) -> [String: Any] {
            ["method": method, "params": ["item": item, "threadId": "SESSION", "turnId": "fixture-turn"]]
        }
        func change(_ id: String, _ paths: [String], _ status: String) -> [String: Any] {
            ["id": "exec-" + id, "type": "fileChange", "status": status,
             "changes": paths.map { ["diff": "SECRET-DIFF\n", "kind": ["type": "update"], "path": root.appendingPathComponent($0).path] }]
        }
        func command(_ id: String, _ text: String, completed: Bool) -> [String: Any] {
            ["id": "exec-" + id, "type": "commandExecution", "command": "/bin/zsh -lc '\(text)'", "cwd": root.path,
             "commandActions": [["command": text, "type": "unknown"]], "processId": "1", "source": "unifiedExecStartup",
             "aggregatedOutput": completed ? "SECRET-OUTPUT\n" : NSNull(), "durationMs": completed ? 0 : NSNull(),
             "exitCode": completed ? 0 : NSNull(), "status": completed ? "completed" : "inProgress"]
        }
        var frames: [[String: Any]] = []
        var index = 0
        while index < steps.count {
            switch steps[index] {
            case let .edit(id, path) where path == "Sources/Beta.swift":
                guard case let .edit(_, gamma) = steps[index + 1] else { fatalError() }
                frames += [item("item/started", change(id, [path, gamma], "inProgress")), item("item/completed", change(id, [path, gamma], "completed"))]
                index += 1
            case let .edit(id, path), let .write(id, path):
                frames += [item("item/started", change(id, [path], "inProgress")), item("item/completed", change(id, [path], "completed"))]
            case let .shell(id, text, ends):
                frames.append(item("item/started", command(id, text, completed: false)))
                if ends { frames.append(item("item/completed", command(id, text, completed: true))) }
            }
            index += 1
        }
        return frames
    }

    struct Outcome {
        var leadInputs: String
        var reportReplies: [String]
        var ledger: String
        var rows: [[String: Any]]
        var helpers: [AgentHarness: AgentID]
        var root: URL
        var roots: [URL]
    }

    static func run() async throws {
        let on = try await scenario(recording: true)
        let off = try await scenario(recording: false)
        var failures: [String] = []
        func check(_ ok: Bool, _ message: String) { if !ok { failures.append(message) } }

        for harness in [AgentHarness.claudeCode, .codex] {
            let rows = on.rows.filter { $0["kind"] as? String == "helperEvidence" && $0["agent"] as? String == on.helpers[harness]!.rawValue.uuidString }
            check(rows.count == 1, "\(harness.rawValue): expected one evidence row, found \(rows.count)")
            guard let row = rows.first else { continue }
            let files = Dictionary(uniqueKeysWithValues: (row["files"] as? [[String: Any]] ?? []).map { ($0["path"] as? String ?? "", $0) })
            func fact(_ path: String) -> [String: Any] { files[path] ?? [:] }
            // Edit after the last check run: stale.
            check(fact("Sources/Beta.swift")["status"] as? String == "before"
                  && fact("Sources/Beta.swift")["check"] as? String == "--evidence-alpha-check",
                  "\(harness.rawValue): an edit after the last covering check was not recorded as before it: \(fact("Sources/Beta.swift"))")
            // Check after the last edit, 140 calls after that edit: fresh.
            check(fact("Sources/Alpha.swift")["status"] as? String == "after"
                  && fact("Sources/Alpha.swift")["check"] as? String == "--evidence-alpha-check",
                  "\(harness.rawValue): a check after the last edit was not recorded as after it: \(fact("Sources/Alpha.swift"))")
            let exit = fact("Sources/Alpha.swift")["exit"] as? String
            check(harness == .codex ? exit == "0" : (exit == "unknown" && fact("Sources/Alpha.swift")["exitReason"] as? String == "notReportedByHarness"),
                  "\(harness.rawValue): exit status \(exit ?? "nil") is not what the recorded fixtures prove")
            // A covering check that never finished: unknown with its reason, not a failure.
            check(fact("Sources/Gamma.swift")["status"] as? String == "unknown" && fact("Sources/Gamma.swift")["reason"] as? String == "checkIncomplete",
                  "\(harness.rawValue): an unfinished check was not unknown: \(fact("Sources/Gamma.swift"))")
            check(fact("Sources/Delta.swift")["status"] as? String == "none",
                  "\(harness.rawValue): a covered file with no run was not none: \(fact("Sources/Delta.swift"))")
            check(fact("docs/notes.md")["status"] as? String == "unmapped",
                  "\(harness.rawValue): a file the manifest does not map was not unmapped: \(fact("docs/notes.md"))")
            check(files.count == 5, "\(harness.rawValue): expected five edited files, got \(files.keys.sorted())")
            check((row["evidence"] as? [String: String])?["manifest"] == "present", "\(harness.rawValue): manifest not read")
        }
        // Recording off records nothing; the lead's input and the report replies are the same bytes in the same order.
        check(!off.rows.contains { $0["kind"] as? String == "helperEvidence" }, "evidence recorded with recording off")
        // The envelope's key order differs run to run with recording either way;
        // what the lead's model receives is each message's content, in order.
        func received(_ log: String) -> String {
            log.split(separator: "\n").compactMap { line in
                ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])
                    .flatMap { ($0["message"] as? [String: Any])?["content"] as? String }
            }.joined(separator: "\n<next>\n")
        }
        let leadOn = canonical(received(on.leadInputs), [on.root] + on.roots)
        let leadOff = canonical(received(off.leadInputs), [off.root] + off.roots)
        check(!leadOn.isEmpty && leadOn == leadOff, "the lead received different input with recording on and off:\n\(leadOn)\n----\n\(leadOff)")
        check(on.reportReplies.map { canonical($0, [on.root] + on.roots) } == off.reportReplies.map { canonical($0, [off.root] + off.roots) },
              "array_report replied differently with recording on and off")
        // Nothing is shown to any agent: no evidence word in what the lead or a helper received.
        for text in [on.leadInputs] + on.reportReplies {
            for word in evidenceWords where text.contains(word) { check(false, "an agent received evidence text \(word)") }
        }
        // The stored file holds no prompt, content, diff, output or command text, and no absolute path.
        for secret in secrets + ([on.root] + on.roots).flatMap({ [$0.path, $0.resolvingSymlinksInPath().path] }) where on.ledger.contains(secret) {
            check(false, "ledger stores \(secret)")
        }
        for row in on.rows {
            check(Set(row.keys).isSubset(of: ManagedRunLedgerChecks.allowedKeys), "unexpected row keys: \(row.keys.sorted())")
        }
        if !failures.isEmpty { throw WorkspaceAgentReportChecks.Failure(description: "helper-evidence:\n- " + failures.joined(separator: "\n- ")) }
        print("Helper evidence passed: Claude and Codex, edit after check recorded before, check after edit recorded after past 140 calls, unfinished check unknown, unrun check none, unmapped file unmapped, Codex exit 0 observed and Claude exit unknown, lead input and report replies byte-identical with recording off, no evidence shown to any agent, no prompt/content/diff/command stored")
        try await timing()
    }

    /// Times are zeroed, UUIDs and the checkout root renamed, so two runs compare.
    static func canonical(_ text: String, _ roots: [URL]) -> String {
        var text = text
        for (index, root) in roots.enumerated().sorted(by: { $0.element.path.count > $1.element.path.count }) {
            text = text.replacingOccurrences(of: root.resolvingSymlinksInPath().path, with: "ROOT\(index)")
                .replacingOccurrences(of: root.path, with: "ROOT\(index)")
        }
        let uuid = try! NSRegularExpression(pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
        var names: [String: String] = [:], out = "", last = text.startIndex
        for match in uuid.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let range = Range(match.range, in: text)!
            let id = text[range].uppercased()
            if names[id] == nil { names[id] = "id\(names.count)" }
            out += text[last..<range.lowerBound] + names[id]!
            last = range.upperBound
        }
        text = out + text[last...]
        return text
    }

    static func prepare(_ b: Bench) throws -> (lead: AgentID, root: URL) {
        let cli = b.binDir.appendingPathComponent("claude")
        try claude.write(to: cli, atomically: true, encoding: .utf8)
        let codexCLI = b.binDir.appendingPathComponent("codex")
        try codex().write(to: codexCLI, atomically: true, encoding: .utf8)
        for url in [cli, codexCLI] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .codex, readiness: .ready, models: [ManagedCodexChecks.model]))
        let supervisor = b.supervisor, lead = b.f.agentId
        try b.f.delegate.reconciledManagedSessionSource.reconcile(
            registry: b.f.delegate.registryStore!.loadOrEmpty(), reason: .continuumRestarted, now: Date())
        try expect(supervisor.setProviderSettings(agentID: lead, harness: .claudeCode, model: ManagedModeChecks.model), "could not select lead harness")
        ManagedSettingChecks.write(AgentManagedModeConfig.enabledKey, true, b)
        try expect(supervisor.effectiveMode(for: lead) == .managed, "lead is not a Managed lead")
        let root = URL(fileURLWithPath: supervisor.records[lead]!.checkoutRoot)
        try expect(WorkspaceAgentReportChecks.isTemporary(root), "checkout is not temporary: \(root.path)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try manifest.write(to: root.appendingPathComponent(HelperEvidence.Manifest.relativePath), atomically: true, encoding: .utf8)
        for path in ["Sources/Alpha.swift", "Sources/Beta.swift", "Sources/Gamma.swift", "docs/notes.md"] {
            try "a\n".write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        for arguments in [["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "fixture"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.currentDirectoryURL = root
            git.arguments = ["-c", "user.name=fixture", "-c", "user.email=fixture@invalid", "-c", "commit.gpgsign=false"] + arguments
            try git.run(); git.waitUntilExit()
            try expect(git.terminationStatus == 0, "git \(arguments[0]) failed")
        }
        return (lead, root)
    }

    /// A helper's frames name paths in its own checkout, which may be a worktree.
    static func start(_ name: String, helper: AgentID, _ supervisor: AgentSupervisor) throws -> URL {
        let root = URL(fileURLWithPath: supervisor.records[helper]!.checkoutRoot)
        let frames = name == "codex" ? codexFrames(root: root) : claudeFrames(root: root)
        let lines = try frames.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("frames-\(name).jsonl"), atomically: true, encoding: .utf8)
        try Data().write(to: root.appendingPathComponent("go-\(name)"))
        return root
    }

    static func scenario(recording: Bool) async throws -> Outcome {
        let b = try ManagedModeChecks.bench("helper-evidence")
        defer { b.tearDown() }
        let restoreCodex = ManagedCodexChecks.runEnvironment(b)
        defer { restoreCodex() }
        let (lead, root) = try prepare(b)
        let supervisor = b.supervisor
        supervisor.qaRunLedgerRecording = recording
        defer { supervisor.qaRunLedgerRecording = true }
        func wait(_ message: String, timeout: TimeInterval = 20, _ condition: @escaping @MainActor () -> Bool) async throws {
            try await AgentPresenceChecks.eventually("helper-evidence: " + message, timeout: timeout, condition)
        }
        func leadInputs() -> String {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            return names.filter { $0.hasPrefix("inputs-") }.sorted()
                .compactMap { try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
                .first { $0.split(separator: "\n").first.map { $0.contains("HOLD-lead") && !$0.contains("array-agent-message") } == true } ?? ""
        }

        try expect(await supervisor.accept(.sendPrompt(AgentPrompt("HOLD-lead SECRET-PROMPT")), for: lead) == .accepted, "lead submission refused")
        try await wait("lead did not start") { supervisor.isRunning(lead) }
        var helpers: [AgentHarness: AgentID] = [:]
        var replies: [String] = []
        var lastEditSeen = Set<AgentID>()
        var roots: [AgentHarness: URL] = [:]
        // Both parts are delegated while the lead's task is open, then the lead's turn ends.
        let roster = [(AgentHarness.claudeCode, "claude", ManagedModeChecks.model), (.codex, "codex", ManagedCodexChecks.model)]
        for (harness, name, model) in roster {
            let reply = try await WorkspaceAgentReportChecks.call(b.configuration(for: lead), "array_delegate", [
                "task": "HOLD-\(name) FRAMES-\(name) SECRET-BRIEF", "title": "Evidence \(name)",
                "harness": harness == .codex ? "Codex" : "Claude Code", "model": model, "idempotencyKey": UUID().uuidString])
            guard !reply.isError, let result = reply.reply["result"] as? [String: Any],
                  let raw = result["childAgentId"] as? String, let uuid = UUID(uuidString: raw) else {
                throw WorkspaceAgentReportChecks.Failure(description: "helper-evidence: \(name) delegation failed: \(reply.reply)")
            }
            let helper = AgentID(rawValue: uuid)
            helpers[harness] = helper
            _ = supervisor.addRuntimeObservationObserver(for: helper) { observation in
                if case let .toolActivity(call, _) = observation, call.hasSuffix("e5") { lastEditSeen.insert(helper) }
            }
        }
        try Data().write(to: root.appendingPathComponent("release-lead"))
        try await wait("lead turn did not end") { !supervisor.isRunning(lead) }
        for (harness, name, _) in roster {
            let helper = helpers[harness]!
            // The frames have reached the host once the last edit is observed.
            let helperRoot = try start(name, helper: helper, supervisor)
            roots[harness] = helperRoot
            try await wait("\(name) frames not observed") { lastEditSeen.contains(helper) }
            let report = try await WorkspaceAgentReportChecks.call(b.configuration(for: helper), "array_report", [
                "summary": "SECRET-REPORT-\(name)", "checks": [["what": "SECRET-CHECK", "result": "pass"]]])
            try expect(!report.isError, "\(name) report refused: \(report.reply)")
            replies.append(String(decoding: try JSONSerialization.data(withJSONObject: report.reply, options: [.sortedKeys]), as: UTF8.self))
            let before = leadInputs().split(separator: "\n").count
            if harness == .codex { try Data().write(to: URL(fileURLWithPath: ManagedCodexChecks.log(b).path + ".release")) }
            else { try Data().write(to: helperRoot.appendingPathComponent("release-\(name)")) }
            // A wake that quotes the brief holds the lead's double on the same name.
            try Data().write(to: root.appendingPathComponent("release-\(name)"))
            try Data().write(to: root.appendingPathComponent("go-\(name)"))
            do { try await wait("\(name) result did not reach the lead", timeout: 40) { leadInputs().split(separator: "\n").count > before } }
            catch { throw WorkspaceAgentReportChecks.Failure(description: "\(error) recording=\(recording) lead running=\(supervisor.isRunning(lead)) helper running=\(supervisor.isRunning(helper)) helperRoot=\(helperRoot.path) root=\(root.path) inputs=\(leadInputs().suffix(800))") }
            do { try await wait("lead did not settle after \(name)") { !supervisor.isRunning(lead) && !supervisor.isRunning(helper) } }
            catch { throw WorkspaceAgentReportChecks.Failure(description: "\(error) lead running=\(supervisor.isRunning(lead)) helper running=\(supervisor.isRunning(helper)) inputs=\(leadInputs().suffix(1500))") }
        }
        supervisor.runLedger.drain()
        let ledgerURL = AgentStore(smokeTest: false).layout.applicationSupportDirectory.appendingPathComponent("run-ledger/ledger.jsonl")
        let ledger = (try? String(contentsOf: ledgerURL, encoding: .utf8)) ?? ""
        return Outcome(leadInputs: leadInputs(), reportReplies: replies, ledger: ledger,
                       rows: ManagedRunLedgerChecks.rows(ledgerURL), helpers: helpers, root: root, roots: Array(roots.values))
    }

    /// Prints the report path with observation on and off; asserts nothing about time.
    static func timing() async throws {
        let b = try ManagedModeChecks.bench("helper-evidence-timing")
        defer { b.tearDown() }
        let (lead, root) = try prepare(b)
        let supervisor = b.supervisor
        try expect(await supervisor.accept(.sendPrompt(AgentPrompt("HOLD-lead")), for: lead) == .accepted, "timing submission refused")
        let reply = try await WorkspaceAgentReportChecks.call(b.configuration(for: lead), "array_delegate", [
            "task": "HOLD-claude FRAMES-claude", "title": "Timing", "harness": "Claude Code",
            "model": ManagedModeChecks.model, "idempotencyKey": UUID().uuidString])
        guard let raw = (reply.reply["result"] as? [String: Any])?["childAgentId"] as? String, let uuid = UUID(uuidString: raw) else {
            throw WorkspaceAgentReportChecks.Failure(description: "helper-evidence: timing delegation failed")
        }
        let helper = AgentID(rawValue: uuid)
        var seen = false
        _ = supervisor.addRuntimeObservationObserver(for: helper) { observation in
            if case let .toolActivity(call, _) = observation, call.hasSuffix("e5") { seen = true }
        }
        let helperRoot = try start("claude", helper: helper, supervisor)
        try await AgentPresenceChecks.eventually("timing frames", timeout: 20) { seen }
        supervisor.runLedger.drain()
        let report = AgentReport(summary: "timing", checks: [.init(what: "timing", result: .pass)], findings: [])
        var on: [Double] = [], off: [Double] = []
        defer { supervisor.qaRunLedgerRecording = true }
        for pair in 0..<108 {
            for enabled in (pair % 2 == 0 ? [false, true] : [true, false]) {
                supervisor.qaRunLedgerRecording = enabled
                let start = DispatchTime.now().uptimeNanoseconds
                let filed = supervisor.fileReport(report, for: helper, at: Date())
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1000
                try expect(filed, "timing report refused")
                if pair >= 8 { if enabled { on.append(elapsed) } else { off.append(elapsed) } }
                supervisor.runLedger.drain()
            }
        }
        func describe(_ name: String, _ values: [Double]) {
            let s = values.sorted()
            print(String(format: "helper-evidence timing report %@ n=%d median=%.2f p95=%.2f us", name, s.count,
                         s[s.count / 2], s[Int(ceil(Double(s.count) * 0.95)) - 1]))
        }
        describe("observation off", off); describe("observation on", on)
        try Data().write(to: root.appendingPathComponent("release-lead"))
        try Data().write(to: helperRoot.appendingPathComponent("release-claude"))
        print("Helper evidence timing printed (no timing assertions)")
    }
}

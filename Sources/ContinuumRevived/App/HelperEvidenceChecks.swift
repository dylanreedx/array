import AppKit
import ContinuumRevivedCore
import Foundation

/// `.plans/116` part 8 step 1: shadow evidence of what a helper ran and edited.
/// A Managed Claude lead delegates four helpers through the production MCP
/// binary into a temporary git repository whose baseline commit carries a
/// coverage manifest in the gate pre-pass's format: one shares the lead's
/// checkout, a Claude and a Codex helper replay every sequence below in their
/// own worktrees, and a fourth leaves the record unverifiable. CLI doubles
/// replay provider frames in the recorded fixture shapes through the production
/// runners and translators, and really change the files the frames describe.
///
/// The whole run happens twice, recording on and off. Both must match what the
/// lead received from the code before this change, recorded in
/// `scripts/fixtures/helper-evidence-lead-expected.txt`.
@MainActor
enum HelperEvidenceChecks {
    typealias Bench = WorkspaceAgentReportChecks.Bench
    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw WorkspaceAgentReportChecks.Failure(description: "helper-evidence: " + message) }
    }

    static let manifestPath = "scripts/check-coverage-manifest.json"
    static let expectedPath = "scripts/fixtures/helper-evidence-lead-expected.txt"

    /// Replays `frames-x.jsonl` once `go-x` exists, then consumes it (a wake
    /// quotes the brief). A `{"__write": path}` line changes that file.
    static let replay = """
    def replay(name, out):
        while not os.path.exists('go-' + name): time.sleep(.02)
        if not os.path.exists('frames-' + name + '.jsonl'): return
        for frame in open('frames-' + name + '.jsonl'):
            o = json.loads(frame)
            if '__write' in o:
                os.makedirs(os.path.dirname(o['__write']) or '.', exist_ok=True)
                open(o['__write'], 'a').write('changed\\n')
            else: out(o)
        os.rename('frames-' + name + '.jsonl', 'replayed-' + name + '.jsonl')

    """

    /// The ledger's Claude double, plus: every user message it receives is
    /// logged per session, and `FRAMES-x` replays.
    static let claude = ManagedRunLedgerChecks.script
        .replacingOccurrences(of: "def emit(o):", with: replay + "def emit(o):")
        .replacingOccurrences(of: "    if o.get('type') != 'user': continue\n",
                              with: "    if o.get('type') != 'user': continue\n    open('inputs-' + sid + '.jsonl', 'a').write(line)\n")
        .replacingOccurrences(of: "    m = re.search(r'HOLD-([a-z0-9]+)', json.dumps(o))\n",
                              with: "    f = re.search(r'FRAMES-([a-z0-9]+)', json.dumps(o))\n    if f: replay(f.group(1), lambda frame: print(json.dumps(frame).replace('SESSION', sid), flush=True))\n    m = ([None] + list(re.finditer(r'HOLD-([a-z0-9]+)', json.dumps(o))))[-1]\n")

    /// The repository's Codex app-server double, plus `FRAMES-x` replay.
    static func codex() throws -> String {
        let source = try String(contentsOfFile: "scripts/fixtures/codex-hook-cli.py", encoding: .utf8)
        let anchor = "            hook('PreToolUse', 'apply_patch')\n"
        try expect(source.contains(anchor) && source.contains("def emit(value):"), "codex double changed shape")
        return source.replacingOccurrences(of: "def emit(value):", with: replay + "def emit(value):")
            .replacingOccurrences(of: anchor, with: anchor + """
                    frames = re.search(r'FRAMES-([a-z0-9]+)', json.dumps(message))
                    if frames: replay(frames.group(1), lambda frame: emit(json.loads(json.dumps(frame).replace('SESSION', session_id))))

        """)
    }

    static let secrets = ["SECRET-CONTENT", "SECRET-DIFF", "SECRET-ARG", "SECRET-OUTPUT", "SECRET-PROMPT",
                          "SECRET-BRIEF", "SECRET-REPORT", "SECRET-CHECK", "/bin/zsh", "sed -i", "git status", "aggregatedOutput"]
    /// Words only the stored evidence uses. No agent may ever receive them.
    static let evidenceWords = ["evidence-alpha-check", "check-theta.py", "helperEvidence", "editNotObserved",
                                "orderUnknown", "possibleRun", "buildFreshnessUnknown", "shellAfterCheck"]

    static func entry(_ invocation: String, _ covers: [String], _ checkFiles: [String] = []) -> String {
        let quoted = { (list: [String]) in list.map { "\"\($0)\"" }.joined(separator: ", ") }
        return #"{"invocation": "\#(invocation)", "covers": [\#(quoted(covers))], "checkFiles": [\#(quoted(checkFiles))], "owner": "fixture", "reason": "fixture"}"#
    }
    static let manifest = """
    {"version": 1, "mappedLegs": 10, "checks": [
      \(entry(".build/debug/Array --evidence-alpha-check", ["Sources/Alpha.swift", "Sources/B*.swift"], ["Sources/AlphaChecks.swift"])),
      \(entry(".build/debug/Array --evidence-iota-check", ["Sources/Iota.swift", "Sources/Kappa.swift"])),
      \(entry(".build/debug/Array --evidence-zeta-check", ["Sources/**/Zeta.swift"])),
      \(entry(".build/debug/Array --evidence-mu-check", ["Sources/Mu.swift"])),
      \(entry(".build/debug/Array --evidence-delta-check", ["Sources/Delta.swift"])),
      \(entry(".build/debug/Array --evidence-gamma-check", ["Sources/Gamma.swift"])),
      \(entry(".build/debug/Array --evidence-rho-check", ["Sources/Rho.swift"])),
      \(entry("bash scripts/check-eta.sh", ["Sources/Eta.swift"])),
      \(entry("python3 scripts/check-theta.py", ["Sources/Theta.swift"])),
      \(entry("python3 scripts/check-omicron.py", ["Sources/Omicron.swift"])),
      \(entry("make lambda", ["Sources/Lambda.swift"]))
    ], "targetedOnly": [], "exceptions": []}
    """

    enum Step {
        case edit(String, String)
        case shell(String, String, exit: Int?, ends: Bool = true)
        /// A shell call that really writes a file the host never sees edited.
        case shellWrite(String, String, String)
        /// Claude only: an in-process subagent edits a file.
        case subagent(String, String)
        /// Claude: one message holding these calls; Codex runs them in turn.
        case batch([Step])
        /// Codex only: file changes naming several paths each, all started
        /// before any completes.
        case multiEdit([(String, [String])])
        case report(String)
    }

    /// Every sequence of the review, in one helper turn.
    static let sequences: [Step] = [
        .shellWrite("w1", "sed -i '' 's/a/b/' Sources/Eps.swift", "Sources/Eps.swift"),
        .subagent("s1", "Sources/Sub.swift"),
        .edit("z1", "Sources/Zeta.swift"),
        .shell("z2", "grep -n -- '--evidence-zeta-check' Sources/Zeta.swift", exit: 0),
        .shell("z3", "false && .build/debug/Array --evidence-zeta-check SECRET-ARG", exit: 1),
        .edit("e1", "Sources/Eta.swift"),
        .shell("e2", "bash -n scripts/check-eta.sh", exit: 0),
        .shell("e3", "sh other/check-eta.sh", exit: 0),
        .edit("m1", "Sources/Mu.swift"),
        .shell("m2", ".build/debug/Array --evidence-mu-check", exit: 127),
        .edit("r1", "Sources/Rho.swift"),
        .shell("r2", "swift build --product ContinuumRevivedCoreChecks", exit: 0),
        .shell("r3", ".build/debug/Array --evidence-rho-check", exit: 0),
        .multiEdit([("x1", ["docs/nu.md", "docs/xi.md"]), ("x2", ["docs/nu.md", "docs/pi.md"])]),
        .batch([.edit("i1", "Sources/Iota.swift"), .shell("i2", ".build/debug/Array --evidence-iota-check", exit: 0),
                .edit("i3", "Sources/Kappa.swift")]),
        .edit("o1", "Sources/Omicron.swift"),
        .shell("o2", "python3 scripts/check-omicron.py", exit: 0),
        .shell("o3", "git status", exit: 0),
        .edit("f1", manifestPath),
        .edit("f2", "Sources/AlphaChecks.swift"),
        .edit("l1", "Sources/Lambda.swift"),
        .edit("n1", "docs/notes.md"),
        .edit("d1", "Sources/Delta.swift"),
        .edit("t1", "Sources/Theta.swift"),
        .edit("a1", "Sources/Alpha.swift"),
        .shell("b1", "swift build", exit: 0),
        .shell("t2", "python3 scripts/check-theta.py", exit: 0),
        .shell("a2", ".build/debug/Array --evidence-alpha-check", exit: 0),
        .edit("b2", "Sources/Beta.swift"),
        .report("zz"),
    ]
    /// Shares the lead's checkout: an otherwise clean pass is still unknown.
    static let shared: [Step] = [.edit("t1", "Sources/Theta.swift"), .shell("t2", "python3 scripts/check-theta.py", exit: 0), .report("zz")]
    /// A check still running, a call still running, no report call seen, git gone.
    static let unverifiable: [Step] = [
        .edit("g1", "Sources/Gamma.swift"), .shell("g2", ".build/debug/Array --evidence-gamma-check", exit: nil, ends: false),
        .edit("t1", "Sources/Theta.swift"), .shell("t2", "python3 scripts/check-theta.py", exit: 0),
        .shell("zz", "sleep 600", exit: nil, ends: false),
    ]

    /// Claude stream-json in the recorded shapes: Bash tool_use/tool_result
    /// (claude-background-result-turn.jsonl), a `file_path` input
    /// (claude-subagent-turn.jsonl) on Edit, the Agent call and its child's
    /// `parent_tool_use_id` frames (claude-subagent-turn.jsonl).
    static func claudeFrames(_ steps: [Step], root: URL) -> [[String: Any]] {
        func use(_ ids: [(String, String, [String: Any])], parent: String? = nil) -> [String: Any] {
            ["type": "assistant", "parent_tool_use_id": parent ?? NSNull(), "session_id": "SESSION",
             "message": ["model": "claude-haiku-5-5", "id": "msg_" + ids[0].0, "type": "message", "role": "assistant",
                         "content": ids.map { ["type": "tool_use", "id": "toolu_" + $0.0, "name": $0.1, "input": $0.2] }]]
        }
        func result(_ id: String, _ text: String, error: Bool = false, parent: String? = nil) -> [String: Any] {
            ["type": "user", "parent_tool_use_id": parent ?? NSNull(), "session_id": "SESSION",
             "message": ["role": "user", "content": [["tool_use_id": "toolu_" + id, "type": "tool_result", "content": text, "is_error": error]]]]
        }
        func call(_ step: Step) -> (String, String, [String: Any])? {
            switch step {
            case let .edit(id, path):
                return (id, "Edit", ["file_path": root.appendingPathComponent(path).path, "old_string": "a", "new_string": "SECRET-CONTENT"])
            case let .shell(id, command, _, _), let .shellWrite(id, command, _):
                return (id, "Bash", ["command": command, "description": "Run"])
            case let .report(id):
                return (id, "mcp__array_workspace__array_report", ["summary": "SECRET-REPORT"])
            default: return nil
            }
        }
        func effects(_ step: Step) -> [[String: Any]] {
            switch step {
            case let .edit(_, path), let .shellWrite(_, _, path): return [["__write": path]]
            default: return []
            }
        }
        func ending(_ step: Step) -> [[String: Any]] {
            switch step {
            case let .edit(id, _): return [result(id, "The file has been updated.")]
            case let .shellWrite(id, _, _): return [result(id, "(Bash completed with no output)")]
            case let .shell(id, _, exit, ends):
                guard ends else { return [] }
                if let exit, exit != 0 { return [result(id, "Exit code \(exit)\nSECRET-OUTPUT", error: true)] }
                return [result(id, "SECRET-OUTPUT")]
            default: return []
            }
        }
        return steps.flatMap { step -> [[String: Any]] in
            switch step {
            case let .subagent(id, path):
                let child = "\(id)c"
                return [use([(id, "Agent", ["description": "Edit", "prompt": "SECRET-PROMPT-SUB", "subagent_type": "general-purpose"])]),
                        use([(child, "Edit", ["file_path": root.appendingPathComponent(path).path, "old_string": "a", "new_string": "SECRET-CONTENT"])], parent: "toolu_" + id),
                        ["__write": path],
                        result(child, "The file has been updated.", parent: "toolu_" + id),
                        result(id, "Done.")]
            case let .batch(steps):
                return [use(steps.compactMap(call))] + steps.flatMap(effects) + steps.flatMap(ending)
            case .multiEdit: return []
            default:
                return [use([call(step)!])] + effects(step) + ending(step)
            }
        }
    }

    /// Codex app-server frames in the recorded shapes of
    /// codex-appserver-single-agent.jsonl (commandExecution with `exitCode`,
    /// fileChange with `changes[].path`) and codex-appserver-mcp-delegate.jsonl
    /// (mcpToolCall). Codex runs a batch's calls one after another.
    static func codexFrames(_ steps: [Step], root: URL) -> [[String: Any]] {
        func item(_ method: String, _ item: [String: Any]) -> [String: Any] {
            ["method": method, "params": ["item": item, "threadId": "SESSION", "turnId": "fixture-turn"]]
        }
        func change(_ id: String, _ paths: [String], _ status: String) -> [String: Any] {
            ["id": "exec-" + id, "type": "fileChange", "status": status,
             "changes": paths.map { ["diff": "SECRET-DIFF\n", "kind": ["type": "update"], "path": root.appendingPathComponent($0).path] }]
        }
        func command(_ id: String, _ text: String, exit: Int?) -> [String: Any] {
            let done = exit != nil
            return ["id": "exec-" + id, "type": "commandExecution", "command": "/bin/zsh -lc '\(text.replacingOccurrences(of: "'", with: "'\\''"))'",
                    "cwd": root.path, "commandActions": [["command": text, "type": "unknown"]], "processId": "1", "source": "unifiedExecStartup",
                    "aggregatedOutput": done ? "SECRET-OUTPUT\n" : NSNull(), "durationMs": done ? 0 : NSNull(),
                    "exitCode": exit ?? NSNull(), "status": done ? (exit == 0 ? "completed" : "failed") : "inProgress"]
        }
        return steps.flatMap { step -> [[String: Any]] in
            switch step {
            case let .edit(id, path):
                return [item("item/started", change(id, [path], "inProgress")), ["__write": path], item("item/completed", change(id, [path], "completed"))]
            case let .multiEdit(edits):
                return edits.map { item("item/started", change($0.0, $0.1, "inProgress")) }
                    + Set(edits.flatMap(\.1)).sorted().map { ["__write": $0] }
                    + edits.map { item("item/completed", change($0.0, $0.1, "completed")) }
            case let .shell(id, text, exit, ends):
                return [item("item/started", command(id, text, exit: nil))] + (ends ? [item("item/completed", command(id, text, exit: exit ?? 0))] : [])
            case let .shellWrite(id, text, path):
                return [item("item/started", command(id, text, exit: nil)), ["__write": path], item("item/completed", command(id, text, exit: 0))]
            case let .batch(steps): return codexFrames(steps, root: root)
            case .subagent: return []
            case let .report(id):
                return [item("item/started", ["type": "mcpToolCall", "id": "exec-" + id, "server": "array_workspace", "tool": "array_report",
                                              "status": "inProgress", "arguments": ["summary": "SECRET-REPORT"], "result": NSNull(), "error": NSNull()])]
            }
        }
    }

    struct Helper { var name: String; var harness: AgentHarness; var steps: [Step]; var id: AgentID? = nil; var root: URL? = nil }

    struct Outcome {
        var received: String
        var replies: [String]
        var ledger: String
        var rows: [[String: Any]]
        var helpers: [Helper]
        var roots: [URL]
        /// Each edit activity the translator reported, by call.
        var activities: [AgentID: [String: AgentObservedActivity]]
    }

    static func run() async throws {
        let mode = ProcessInfo.processInfo.environment["CONTINUUM_HELPER_EVIDENCE_CASE"]
        if mode == "expected" {
            // Prints what the lead receives, for recording against the code before the change.
            let base = try await scenario(recording: true)
            print("EXPECTED-BEGIN\n" + expectation(base) + "\nEXPECTED-END")
            return
        }
        let on = try await scenario(recording: true)
        let off = try await scenario(recording: false)
        var failures: [String] = []
        func check(_ ok: Bool, _ message: @autoclosure () -> String) { if !ok { failures.append(message()) } }

        func row(_ name: String) -> [String: Any] {
            let id = on.helpers.first { $0.name == name }!.id!.rawValue.uuidString
            let rows = on.rows.filter { $0["kind"] as? String == "helperEvidence" && $0["agent"] as? String == id }
            check(rows.count == 1, "\(name): expected one evidence row, found \(rows.count)")
            return rows.first ?? [:]
        }
        func files(_ row: [String: Any]) -> [String: [String: Any]] {
            Dictionary((row["files"] as? [[String: Any]] ?? []).map { ($0["path"] as? String ?? "", $0) }, uniquingKeysWith: { a, _ in a })
        }
        func expectFact(_ name: String, _ facts: [String: [String: Any]], _ path: String, _ status: String,
                        reasons: Set<String>? = nil, exactly: Bool = false, _ why: String) {
            let fact = facts[path] ?? [:]
            let got = Set(fact["reasons"] as? [String] ?? [])
            let ok = fact["status"] as? String == status
                && (reasons.map { exactly ? got == $0 : $0.isSubset(of: got) } ?? true)
            check(ok, "\(name): \(why): \(path) \(fact)")
        }

        for name in ["claude", "codex"] {
            let row = row(name), facts = files(row), claude = name == "claude"
            let summary = row["evidence"] as? [String: String] ?? [:]
            expectFact(name, facts, "Sources/Eps.swift", "editNotObserved", "a shell write the host never saw edited looked clean")
            if claude { expectFact(name, facts, "Sources/Sub.swift", "editNotObserved", "a subagent's edit looked clean") }
            expectFact(name, facts, "Sources/Zeta.swift", "unknown", reasons: ["possibleRun"], exactly: true, "grep or a guarded command counted as a run")
            expectFact(name, facts, "Sources/Eta.swift", "unknown", reasons: ["possibleRun"], exactly: true, "a syntax check or a same-named script counted as a run")
            expectFact(name, facts, "Sources/Mu.swift", "none", "a check that failed to start counted as a run")
            if claude {
                expectFact(name, facts, "Sources/Iota.swift", "orderUnknown", "a check inside one batch with the edit was ordered")
                expectFact(name, facts, "Sources/Kappa.swift", "orderUnknown", "an edit later in the check's batch was recorded as before or after")
            } else {
                expectFact(name, facts, "Sources/Iota.swift", "unknown", reasons: ["buildFreshnessUnknown"], "a binary check with no rebuild counted as fresh")
                expectFact(name, facts, "Sources/Kappa.swift", "before", "an edit after the check was not before")
            }
            expectFact(name, facts, "Sources/Omicron.swift", "unknown", reasons: ["shellAfterCheck"], exactly: true, "a shell after the check left it after")
            expectFact(name, facts, "Sources/Lambda.swift", "unknown", reasons: ["manifestUnparsed"], exactly: true, "an unparsed manifest entry read as unmapped")
            expectFact(name, facts, "docs/notes.md", "unmapped", "an unmapped file was not unmapped")
            expectFact(name, facts, "Sources/Delta.swift", "none", "a covered file with no run was not none")
            expectFact(name, facts, "Sources/Theta.swift", "after", "a script check after the last edit was not after")
            check(facts["Sources/Theta.swift"]?["exit"] as? String == (claude ? "unknown" : "0"), "\(name): Theta exit is not what the harness reported")
            if claude { expectFact(name, facts, "Sources/Alpha.swift", "unknown", reasons: ["buildFreshnessUnknown"], exactly: true, "a run after a build with no reported exit counted as fresh") }
            else { expectFact(name, facts, "Sources/Alpha.swift", "after", "a check after a rebuild that exited 0 was not after") }
            check(facts["Sources/Alpha.swift"]?["checkFilesChanged"] as? Bool == true, "\(name): an edit to the check's own file was not recorded")
            if claude { expectFact(name, facts, "Sources/AlphaChecks.swift", "unknown", reasons: ["buildFreshnessUnknown"], exactly: true, "a check file's edit was not covered by its check") }
            else { expectFact(name, facts, "Sources/AlphaChecks.swift", "after", "a check file's edit was not covered by its check") }
            expectFact(name, facts, "Sources/Rho.swift", "unknown", reasons: ["buildFreshnessUnknown"], "a build of another product counted as a rebuild of the check's binary")
            check(facts["Sources/Alpha.swift"]?["check"] as? String == ".build/debug/Array --evidence-alpha-check", "\(name): check identity not the baseline manifest's")
            expectFact(name, facts, "Sources/Beta.swift", "before", "an edit after the last check was not before")
            expectFact(name, facts, manifestPath, "unmapped", "the helper's manifest edit remapped its own files")
            check(summary["manifestChanged"] == "true" && summary["manifest"] == "baseline" && summary["manifestUnparsedEntries"] == "1",
                  "\(name): manifest facts wrong: \(summary)")
            check(summary["changes"] == "git" && summary["checkout"] == "own" && summary["reportCallObserved"] == "true", "\(name): record facts wrong: \(summary)")
        }
        // Codex names several paths in one file change: every one is an observed
        // edit, and a second change differing only in its other paths leaves the
        // location activity as it was, so nothing downstream sees a change.
        let codexFacts = files(row("codex"))
        for path in ["docs/nu.md", "docs/xi.md", "docs/pi.md"] {
            expectFact("codex", codexFacts, path, "unmapped", "a file change's other path was not an observed edit")
        }
        // The translator's own two activities, through the production projector.
        let codexHelper = on.helpers.first { $0.name == "codex" }!
        let reported = on.activities[codexHelper.id!] ?? [:]
        if let first = reported["exec-x1"], let second = reported["exec-x2"], let root = codexHelper.root {
            check(first.otherTargets.map(\.lastPathComponent) == ["xi.md"] && second.otherTargets.map(\.lastPathComponent) == ["pi.md"]
                  && first.targetPath == second.targetPath, "codex: file change activities not as replayed: \(first) \(second)")
            var projector = AgentLocationProjector(home: AgentHome(projectId: nil, projectRoot: root, checkoutRoot: root), whereDirectory: root)
            projector.ingest(.toolActivity(itemId: "exec-x1", activity: first))
            let now = second.updatedAt.addingTimeInterval(1)
            let before = projector.snapshot(at: now)
            projector.ingest(.toolActivity(itemId: "exec-x2", activity: second))
            let after = projector.snapshot(at: now)
            check(before.what?.otherTargets == first.otherTargets && after.what?.otherTargets == first.otherTargets && after == before,
                  "codex: a change differing only in other paths changed the location snapshot: \(String(describing: before.what)) -> \(String(describing: after.what))")
        } else {
            check(false, "codex: file change activities not observed: \(reported.keys.sorted())")
        }
        let sharedRow = row("shared")
        expectFact("shared", files(sharedRow), "Sources/Theta.swift", "unknown", reasons: ["sharedCheckout"], exactly: true, "a shared checkout gave after")
        let lost = row("lost"), lostFacts = files(lost), lostSummary = lost["evidence"] as? [String: String] ?? [:]
        check(lostSummary["changes"] == "unavailable" && lostSummary["changesReason"] == "gitFailed", "lost: git failure not recorded: \(lostSummary)")
        check(lostSummary["reportCallObserved"] == "false", "lost: observations in flight left no marker: \(lostSummary)")
        expectFact("lost", lostFacts, "Sources/Theta.swift", "unknown",
                   reasons: ["changesUnverifiable", "observationsInFlight", "callStillRunning"], "an unverifiable record gave after")
        expectFact("lost", lostFacts, "Sources/Gamma.swift", "unknown", reasons: ["checkIncomplete"], "an unfinished check was not unknown")

        // Recording off records nothing.
        check(!off.rows.contains { $0["kind"] as? String == "helperEvidence" }, "evidence recorded with recording off")
        // What the lead receives, and what array_report answers, are the base behaviour's, on and off.
        let expected = (try? String(contentsOfFile: expectedPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        check(!expected.isEmpty, "no recorded expectation at \(expectedPath)")
        for (label, outcome) in [("on", on), ("off", off)] {
            let got = expectation(outcome).trimmingCharacters(in: .whitespacesAndNewlines)
            check(got == expected, "recording \(label): the lead's input or the report replies differ from the base behaviour:\n\(got)\n---- expected\n\(expected)")
        }
        // Nothing is shown to any agent.
        for text in [on.received] + on.replies {
            for word in evidenceWords where text.contains(word) { check(false, "an agent received evidence text \(word)") }
        }
        // The stored file holds no prompt, content, diff, output or command text, and no absolute path.
        for secret in secrets + on.roots.flatMap({ [$0.path, $0.resolvingSymlinksInPath().path] }) where on.ledger.contains(secret) {
            check(false, "ledger stores \(secret)")
        }
        for row in on.rows {
            check(Set(row.keys).isSubset(of: ManagedRunLedgerChecks.allowedKeys), "unexpected row keys: \(row.keys.sorted())")
        }
        if !failures.isEmpty { throw WorkspaceAgentReportChecks.Failure(description: "helper-evidence:\n- " + failures.joined(separator: "\n- ")) }
        print("Helper evidence passed: Claude and Codex: unobserved shell and subagent edits recorded editNotObserved; grep, guarded, syntax-check and same-named-script commands are possible runs; a failed start is no run; one Claude batch is orderUnknown; no rebuild, a rebuild of another product or no reported build exit is buildFreshnessUnknown; a check file's edit is covered by its check; every path of a Codex file change is an observed edit and other paths alone change no location activity; a shell after the check, a shared checkout, git failure, a call still running and no report call seen each block after; manifest read from the baseline with its edit, check-file edit and unparsed entry recorded; lead input and report replies match the base behaviour on and off; nothing shown to any agent; nothing sensitive stored")
        try await timing()
    }

    /// What the lead's model received (message contents, in order) and what
    /// array_report answered, with ids, roots and times made comparable.
    static func expectation(_ outcome: Outcome) -> String {
        let received = outcome.received.split(separator: "\n").compactMap { line in
            ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])
                .flatMap { ($0["message"] as? [String: Any])?["content"] as? String }
        }
        return canonical((received + outcome.replies).joined(separator: "\n<next>\n"), outcome.roots)
    }

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
        return out + text[last...]
    }

    static func git(_ arguments: [String], _ root: URL) throws {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.currentDirectoryURL = root
        git.arguments = ["-c", "user.name=fixture", "-c", "user.email=fixture@invalid", "-c", "commit.gpgsign=false"] + arguments
        git.standardOutput = FileHandle.nullDevice
        try git.run(); git.waitUntilExit()
        try expect(git.terminationStatus == 0, "git \(arguments[0]) failed")
    }

    /// One git command's trimmed output; throws when it fails.
    static func gitOutput(_ arguments: [String], _ root: URL) throws -> String {
        let git = Process(), out = Pipe()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.currentDirectoryURL = root
        git.arguments = arguments
        git.standardOutput = out; git.standardError = FileHandle.nullDevice
        try git.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        git.waitUntilExit()
        try expect(git.terminationStatus == 0, "git \(arguments[0]) failed")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
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
        for path in ["Sources/Alpha.swift", "Sources/Beta.swift", "Sources/Gamma.swift", "Sources/Delta.swift", "Sources/Eta.swift",
                     "Sources/Theta.swift", "Sources/Iota.swift", "Sources/Kappa.swift", "Sources/Zeta.swift", "Sources/Mu.swift",
                     "Sources/Omicron.swift", "Sources/Lambda.swift", "Sources/Rho.swift", "Sources/Eps.swift", "Sources/AlphaChecks.swift",
                     "docs/notes.md", "scripts/check-eta.sh", "scripts/check-theta.py", "scripts/check-omicron.py", manifestPath] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (path == manifestPath ? manifest : "a\n").write(to: url, atomically: true, encoding: .utf8)
        }
        try "frames-*\nreplayed-*\ngo-*\nrelease-*\ninputs-*\nmanaged-argv.jsonl\n".write(
            to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        for arguments in [["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "fixture"]] { try git(arguments, root) }
        return (lead, root)
    }

    /// A helper's frames name paths in its own checkout, which may be a worktree.
    static func start(_ helper: Helper, _ supervisor: AgentSupervisor) throws -> URL {
        let root = URL(fileURLWithPath: supervisor.records[helper.id!]!.checkoutRoot)
        let frames = helper.harness == .codex ? codexFrames(helper.steps, root: root) : claudeFrames(helper.steps, root: root)
        let lines = try frames.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent("frames-\(helper.name).jsonl"), atomically: true, encoding: .utf8)
        try Data().write(to: root.appendingPathComponent("go-\(helper.name)"))
        return root
    }

    static func scenario(recording: Bool) async throws -> Outcome {
        let b = try ManagedModeChecks.bench("helper-evidence")
        defer { b.tearDown() }
        let restoreCodex = ManagedCodexChecks.runEnvironment(b)
        defer { restoreCodex() }
        let (lead, root) = try prepare(b)
        // Only a strict lead's first helper shares its checkout.
        b.settings.set(true, forKey: ManagedStrictLead.enabledKey)
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
        // Every part is delegated while the strict lead's task is open. The first
        // shares the lead's checkout; the rest overlap it and get their own worktrees.
        var helpers = [Helper(name: "shared", harness: .claudeCode, steps: shared),
                       Helper(name: "claude", harness: .claudeCode, steps: sequences),
                       Helper(name: "codex", harness: .codex, steps: sequences),
                       Helper(name: "lost", harness: .claudeCode, steps: unverifiable)]
        var seen: [AgentID: Set<String>] = [:]
        var activities: [AgentID: [String: AgentObservedActivity]] = [:]
        for index in helpers.indices {
            let helper = helpers[index]
            let reply = try await WorkspaceAgentReportChecks.call(b.configuration(for: lead), "array_delegate", [
                "task": "HOLD-\(helper.name) FRAMES-\(helper.name) SECRET-BRIEF", "title": "Evidence \(helper.name)",
                "harness": helper.harness == .codex ? "Codex" : "Claude Code",
                "model": helper.harness == .codex ? ManagedCodexChecks.model : ManagedModeChecks.model, "idempotencyKey": UUID().uuidString])
            guard !reply.isError, let result = reply.reply["result"] as? [String: Any],
                  let raw = result["childAgentId"] as? String, let uuid = UUID(uuidString: raw) else {
                throw WorkspaceAgentReportChecks.Failure(description: "helper-evidence: \(helper.name) delegation failed: \(reply.reply)")
            }
            let id = AgentID(rawValue: uuid)
            helpers[index].id = id
            _ = supervisor.addRuntimeObservationObserver(for: id) { observation in
                switch observation {
                case let .toolActivity(call, activity):
                    seen[id, default: []].insert(call)
                    activities[id, default: [:]][call] = activity
                case let .toolDetail(call, _): seen[id, default: []].insert(call)
                default: break
                }
            }
        }
        try Data().write(to: root.appendingPathComponent("release-lead"))
        try await wait("lead turn did not end") { !supervisor.isRunning(lead) }
        var replies: [String] = []
        for index in helpers.indices {
            let helper = helpers[index], id = helper.id!
            let helperRoot = try start(helper, supervisor)
            helpers[index].root = helperRoot
            try await wait("\(helper.name) frames not observed") { seen[id]?.contains { $0.hasSuffix("zz") } == true }
            // The fourth helper's checkout loses its repository before it reports:
            // a broken gitdir pointer, so git cannot fall back to an enclosing repo.
            let gitFile = helperRoot.appendingPathComponent(".git")
            let pointer = helper.name == "lost" ? try String(contentsOf: gitFile, encoding: .utf8) : ""
            if helper.name == "lost" { try "gitdir: /nonexistent/helper-evidence\n".write(to: gitFile, atomically: true, encoding: .utf8) }
            let report = try await WorkspaceAgentReportChecks.call(b.configuration(for: id), "array_report", [
                "summary": "SECRET-REPORT-\(helper.name)", "checks": [["what": "SECRET-CHECK", "result": "pass"]]])
            try expect(!report.isError, "\(helper.name) report refused: \(report.reply)")
            replies.append(String(decoding: try JSONSerialization.data(withJSONObject: report.reply, options: [.sortedKeys]), as: UTF8.self))
            supervisor.runLedger.drain()
            if helper.name == "lost" { try pointer.write(to: gitFile, atomically: true, encoding: .utf8) }
            let before = leadInputs().split(separator: "\n").count
            if helper.harness == .codex { try Data().write(to: URL(fileURLWithPath: ManagedCodexChecks.log(b).path + ".release")) }
            else { try Data().write(to: helperRoot.appendingPathComponent("release-\(helper.name)")) }
            // A wake quotes the brief, so the lead's double waits on the same names.
            for marker in ["release-", "go-"] { try Data().write(to: root.appendingPathComponent(marker + helper.name)) }
            do { try await wait("\(helper.name) result did not reach the lead", timeout: 40) { leadInputs().split(separator: "\n").count > before } }
            catch { throw WorkspaceAgentReportChecks.Failure(description: "\(error): lead running \(supervisor.isRunning(lead)), helper running \(supervisor.isRunning(id)), lead input \(leadInputs().suffix(600))") }
            try await wait("lead did not settle after \(helper.name)") { !supervisor.isRunning(lead) && !supervisor.isRunning(id) }
        }
        supervisor.runLedger.drain()
        let ledgerURL = AgentStore(smokeTest: false).layout.applicationSupportDirectory.appendingPathComponent("run-ledger/ledger.jsonl")
        let ledger = (try? String(contentsOf: ledgerURL, encoding: .utf8)) ?? ""
        return Outcome(received: leadInputs(), replies: replies, ledger: ledger, rows: ManagedRunLedgerChecks.rows(ledgerURL),
                       helpers: helpers, roots: [root] + helpers.compactMap(\.root), activities: activities)
    }

    /// Prints the report path with recording on and off; asserts nothing about time.
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
        let helper = Helper(name: "claude", harness: .claudeCode, steps: sequences, id: AgentID(rawValue: uuid))
        var seen = false
        _ = supervisor.addRuntimeObservationObserver(for: helper.id!) { observation in
            if case let .toolDetail(call, _) = observation, call.hasSuffix("zz") { seen = true }
        }
        let helperRoot = try start(helper, supervisor)
        try await AgentPresenceChecks.eventually("timing frames", timeout: 20) { seen }
        supervisor.runLedger.drain()
        let report = AgentReport(summary: "timing", checks: [.init(what: "timing", result: .pass)], findings: [])
        var on: [Double] = [], off: [Double] = []
        defer { supervisor.qaRunLedgerRecording = true }
        for pair in 0..<108 {
            for enabled in (pair % 2 == 0 ? [false, true] : [true, false]) {
                supervisor.qaRunLedgerRecording = enabled
                let start = DispatchTime.now().uptimeNanoseconds
                let filed = supervisor.fileReport(report, for: helper.id!, at: Date())
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
        describe("recording off", off); describe("recording on", on)
        try Data().write(to: root.appendingPathComponent("release-lead"))
        try Data().write(to: helperRoot.appendingPathComponent("release-claude"))
        print("Helper evidence timing printed (no timing assertions)")
    }
}

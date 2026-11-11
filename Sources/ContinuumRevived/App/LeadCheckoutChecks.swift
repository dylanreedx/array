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
        try await seen()
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

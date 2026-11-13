import AppKit
import ContinuumRevivedCore
import Foundation

/// `.plans/117` part 2 stage one: a helper's changes to check files it did not
/// create and its contract did not give it are recorded as
/// `protectedPathChanged` rows, and nothing else changes.
///
/// A Managed Claude lead delegates two Claude helpers through the production
/// MCP binary into a temporary git repository. The first shares the lead's
/// checkout, which holds untracked and dirty check files at delegation; the
/// second overlaps it and gets its own worktree, with a contract. CLI doubles
/// replay provider frames through the production runner and translator, and
/// really change, create and delete the files the frames describe. Each
/// helper reports through `array_report`, the production evidence path.
@MainActor
enum HelperProtectedPathsChecks {
    typealias Step = HelperEvidenceChecks.Step
    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw WorkspaceAgentReportChecks.Failure(description: "helper-protected-paths: " + message) }
    }

    /// The evidence check's Claude double, plus `{"__delete": path}`.
    static func claude() throws -> String {
        let anchor = "        if '__write' in o:"
        let base = HelperEvidenceChecks.claude
        try expect(base.contains(anchor), "claude double changed shape")
        return base.replacingOccurrences(of: anchor, with: "        if '__delete' in o: os.remove(o['__delete'])\n        elif '__write' in o:")
    }

    static let manifest = """
    {"version": 1, "mappedLegs": 1, "checks": [
      \(HelperEvidenceChecks.entry(".build/debug/Array --protected-alpha-check", ["Sources/Alpha.swift"], ["Sources/AlphaSpec.swift"]))
    ], "targetedOnly": [], "exceptions": []}
    """

    /// Committed at the baseline.
    static let committed = [
        "Sources/AlphaChecks/Neighbour.swift", "Sources/AlphaChecks/Gone.swift", "Sources/App/HelperFooChecks.swift",
        "Sources/OwnedChecks/Mine.swift", "Sources/OwnedChecks/Locked.swift", "scripts/check-shared.py",
        "docs/frozen.md", "Sources/Plain.swift", "Sources/Alpha.swift", "Sources/AlphaSpec.swift",
        "Sources/BetaChecks/Dirty.swift", "Sources/BetaChecks/DirtyEdited.swift", "Sources/BetaChecks/ByLead.swift",
        "scripts/run-matrix.sh", "scripts/checks/probe.py", "Sources/App/BrowserFooCheck.swift", "scripts/test-foo.sh",
        "scripts/fixtures/claude-turn.jsonl", "docs/tickets/baselines/tile.png", "Sources/Checker.swift",
        "Sources/AlphaChecks/Renamed.swift", "docs/never/old.md", "Sources/AlphaChecks/Silent.swift", "Sources/AlphaChecks/Lost.swift",
    ]
    /// In the lead's checkout at delegation, never committed.
    static let untracked = ["scripts/tests/untracked_check.py", "scripts/tests/untracked_gone.py", "scripts/tests/untouched.py"]

    /// The contract the worktree helper gets: an owned directory written in
    /// another case, a shared check, and `mustNotTouch` inside the owned
    /// directory, on a plain file and on a directory the helper adds to.
    static let contract: [String: Any] = [
        "owns": ["sources/ownedchecks"], "shared": ["scripts/check-shared.py"],
        "mustNotTouch": ["Sources/OwnedChecks/Locked.swift", "docs/frozen.md", "docs/never"],
    ]

    /// A step that really deletes `path` through a shell call the host sees
    /// only as a command.
    enum Action { case step(Step), delete(String, String) }

    static let own: [Action] = [
        .step(.edit("n1", "Sources/AlphaChecks/Neighbour.swift")),       // neighbouring check: modified
        .step(.edit("h1", "Sources/App/HelperFooChecks.swift")),         // an app *Checks.swift: modified
        .step(.shellWrite("w1", "sed -i '' 's/a/b/' Sources/AlphaSpec.swift", "Sources/AlphaSpec.swift")),  // manifest checkFiles, no edit seen
        .delete("d1", "Sources/AlphaChecks/Gone.swift"),                 // deleted
        .step(.edit("a1", "Sources/AlphaChecks/NewCheck.swift")),        // a new check: never
        .step(.edit("o1", "Sources/OwnedChecks/Mine.swift")),            // owned, other case: no
        .step(.edit("s1", "scripts/check-shared.py")),                   // shared: no
        .step(.edit("l1", "Sources/OwnedChecks/Locked.swift")),          // mustNotTouch inside owns: yes
        .step(.edit("f1", "docs/frozen.md")),                            // mustNotTouch, not a check: yes
        .step(.edit("v1", "docs/never/new.md")),                         // new file under mustNotTouch: never
        .step(.edit("p1", "Sources/Plain.swift")),                       // not a check: no
        .step(.edit("rm1", "scripts/run-matrix.sh")),                    // the matrix registry: modified
        .step(.edit("ck1", "scripts/checks/probe.py")),                  // scripts/checks/: modified
        .step(.edit("sc1", "Sources/App/BrowserFooCheck.swift")),        // an app *Check.swift: modified
        .step(.edit("tt1", "scripts/test-foo.sh")),                      // scripts/test-*: modified
        .step(.edit("fx1", "scripts/fixtures/claude-turn.jsonl")),       // a recorded CLI fixture: modified
        .step(.edit("bl1", "docs/tickets/baselines/tile.png")),          // a pixel baseline: modified
        .step(.edit("cr1", "Sources/Checker.swift")),                    // not *Check.swift: no
        .step(.edit("nv1", "docs/never/old.md")),                        // existing file under a mustNotTouch directory: yes
        .step(.report("zz")),
    ]
    /// Never reports: swept when its turn ends.
    static let silentSteps: [Action] = [
        .step(.edit("q1", "Sources/AlphaChecks/Silent.swift")),
        .step(.shell("zz", "true", exit: 0)),
    ]
    /// Its checkout loses git before it reports; git is back before its turn ends.
    static let lostSteps: [Action] = [
        .step(.edit("g1", "Sources/AlphaChecks/Lost.swift")),
        .step(.report("zz")),
    ]
    static let sharedSteps: [Action] = [
        .step(.edit("u1", "scripts/tests/untracked_check.py")),          // untracked before delegation: modified
        .delete("u2", "scripts/tests/untracked_gone.py"),                // untracked before delegation: deleted
        .step(.edit("t1", "Sources/BetaChecks/DirtyEdited.swift")),      // tracked, dirty before delegation: modified
        .step(.report("zz")),
    ]

    /// Expected rows, `helper|path|outcome|reason|attribution|trigger`.
    static let expected: Set<String> = [
        "own|Sources/AlphaChecks/Neighbour.swift|modified|checkFile|observedEdit|report",
        "own|Sources/App/HelperFooChecks.swift|modified|checkFile|observedEdit|report",
        "own|Sources/AlphaSpec.swift|modified|checkFile|git|report",
        "own|Sources/AlphaChecks/Gone.swift|deleted|checkFile|git|report",
        "own|Sources/OwnedChecks/Locked.swift|modified|mustNotTouch|observedEdit|report",
        "own|docs/frozen.md|modified|mustNotTouch|observedEdit|report",
        "own|docs/never/old.md|modified|mustNotTouch|observedEdit|report",
        "own|scripts/run-matrix.sh|modified|checkFile|observedEdit|report",
        "own|scripts/checks/probe.py|modified|checkFile|observedEdit|report",
        "own|Sources/App/BrowserFooCheck.swift|modified|checkFile|observedEdit|report",
        "own|scripts/test-foo.sh|modified|checkFile|observedEdit|report",
        "own|scripts/fixtures/claude-turn.jsonl|modified|checkFile|observedEdit|report",
        "own|docs/tickets/baselines/tile.png|modified|checkFile|observedEdit|report",
        // A staged `git mv` of a check: its old path is deleted (rename detection off).
        "own|Sources/AlphaChecks/Renamed.swift|deleted|checkFile|git|report",
        // A second report after another write to the same path adds nothing;
        // a third after deleting it adds the deletion.
        "own|Sources/AlphaChecks/Neighbour.swift|deleted|checkFile|observedEdit|report",
        "shared|scripts/tests/untracked_check.py|modified|checkFile|sharedObservedEdit|report",
        "shared|scripts/tests/untracked_gone.py|deleted|checkFile|unattributed|report",
        "shared|Sources/BetaChecks/DirtyEdited.swift|modified|checkFile|sharedObservedEdit|report",
        // Written by the test standing in for the lead, in the shared checkout.
        "shared|Sources/BetaChecks/ByLead.swift|modified|checkFile|unattributed|report",
        // No report: the end of its turn sweeps it.
        "silent|Sources/AlphaChecks/Silent.swift|modified|checkFile|observedEdit|turnEnded",
        // Git unreadable at the report: one unknown row and no judgement; the
        // sweep at the end of the turn, with git back, records the change.
        "lost||unknown|changesUnverifiable||report",
        "lost|Sources/AlphaChecks/Lost.swift|modified|checkFile|observedEdit|turnEnded",
    ]

    static func frames(_ actions: [Action], root: URL) -> [[String: Any]] {
        actions.flatMap { action -> [[String: Any]] in
            switch action {
            case let .step(step): return HelperEvidenceChecks.claudeFrames([step], root: root)
            case let .delete(id, path):
                var frames = HelperEvidenceChecks.claudeFrames([.shell(id, "rm \(path)", exit: 0)], root: root)
                frames.insert(["__delete": path], at: 1)
                return frames
            }
        }
    }

    static func write(_ text: String, _ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func readOnlyIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a", "checks/Existing.swift", in: root)
        for args in [["init", "-q"], ["add", "."], ["commit", "-qm", "fixture"]] { try HelperEvidenceChecks.git(args, root) }
        let base = try HelperEvidenceChecks.gitOutput(["rev-parse", "HEAD"], root).trimmingCharacters(in: .whitespacesAndNewlines)
        var detector = HelperProtectedPaths(root: root, base: base, shared: false, contract: nil)
        try write("changed", "checks/Existing.swift", in: root)
        let index = root.appendingPathComponent(".git/index").path
        let before = try FileManager.default.attributesOfItem(atPath: index)
        let changes = detector.sweep()
        let after = try FileManager.default.attributesOfItem(atPath: index)
        try expect(changes.contains { $0.path == "checks/Existing.swift" }, "read-only sweep missed edit")
        try expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date && before[.systemFileNumber] as? UInt64 == after[.systemFileNumber] as? UInt64, "sweep replaced or refreshed git index")
    }
    static func defaultOff() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a", "checks/Existing.swift", in: root)
        for args in [["init", "-q"], ["add", "."], ["commit", "-qm", "fixture"]] { try HelperEvidenceChecks.git(args, root) }
        let base = try HelperEvidenceChecks.gitOutput(["rev-parse", "HEAD"], root).trimmingCharacters(in: .whitespacesAndNewlines)
        let ledger = ManagedRunLedger(support: root)
        let lead = UUID(), child = UUID()
        let before = HelperProtectedPaths.gitInvocations.withLock { $0 }
        ledger.submission(agent: lead, project: nil, mode: "managed")
        ledger.delegated(parent: lead, child: child, source: "off", root: root.path, base: base)
        ledger.drain()
        try write("changed", "checks/Existing.swift", in: root)
        ledger.helperEvidence(agent: child, at: Date())
        ledger.ended(agent: child, turn: "off", outcome: .completed)
        ledger.drain()
        try expect(ledger.qaProtectionCount == 0, "default-off protection allocated state")
        let rows = ManagedRunLedgerChecks.rows(root.appendingPathComponent("run-ledger/ledger.jsonl"))
        try expect(HelperProtectedPaths.gitInvocations.withLock { $0 } == before, "default-off protection invoked git")
        try expect(!rows.contains { $0["kind"] as? String == "protectedPathChanged" }, "default-off protection recorded rows")
    }
    static func run() async throws {
        try defaultOff()
        try readOnlyIndex()
        let b = try ManagedModeChecks.bench("helper-protected-paths")
        defer { b.tearDown() }
        b.settings.set(true, forKey: ManagedChooser.enabledKey)
        let cli = b.binDir.appendingPathComponent("claude")
        try claude().write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let supervisor = b.supervisor, lead = b.f.agentId
        try b.f.delegate.reconciledManagedSessionSource.reconcile(
            registry: b.f.delegate.registryStore!.loadOrEmpty(), reason: .continuumRestarted, now: Date())
        try expect(supervisor.setProviderSettings(agentID: lead, harness: .claudeCode, model: ManagedModeChecks.model), "could not select lead harness")
        ManagedSettingChecks.write(AgentManagedModeConfig.enabledKey, true, b)
        try expect(supervisor.effectiveMode(for: lead) == .managed, "lead is not a Managed lead")
        try expect(supervisor.qaRunLedgerRecording, "run ledger recording is off by default")
        let root = URL(fileURLWithPath: supervisor.records[lead]!.checkoutRoot)
        try expect(WorkspaceAgentReportChecks.isTemporary(root), "checkout is not temporary: \(root.path)")

        for path in committed { try write("a\n", path, in: root) }
        try write(manifest, HelperEvidenceChecks.manifestPath, in: root)
        try write("frames-*\nreplayed-*\ngo-*\nrelease-*\ninputs-*\nmanaged-argv.jsonl\n", ".gitignore", in: root)
        for arguments in [["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "fixture"]] { try HelperEvidenceChecks.git(arguments, root) }
        // The lead's own work at delegation: untracked checks and a dirty one.
        for path in untracked { try write("a\n", path, in: root) }
        try write("lead\n", "Sources/BetaChecks/Dirty.swift", in: root)
        try write("lead\n", "Sources/BetaChecks/DirtyEdited.swift", in: root)

        func wait(_ message: String, timeout: TimeInterval = 20, _ condition: @escaping @MainActor () -> Bool) async throws {
            try await AgentPresenceChecks.eventually("helper-protected-paths: " + message, timeout: timeout, condition)
        }
        func leadInputs() -> String {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            return names.filter { $0.hasPrefix("inputs-") }.sorted()
                .compactMap { try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
                .first { $0.split(separator: "\n").first.map { $0.contains("HOLD-lead") && !$0.contains("array-agent-message") } == true } ?? ""
        }

        try expect(await supervisor.accept(.sendPrompt(AgentPrompt("HOLD-lead")), for: lead) == .accepted, "lead submission refused")
        try await wait("lead did not start") { supervisor.isRunning(lead) }
        // The first helper shares the lead's checkout; the second overlaps it
        // and gets its own worktree.
        let helpers: [(name: String, actions: [Action], contract: [String: Any]?)] = [
            ("shared", sharedSteps, nil), ("own", own, contract), ("silent", silentSteps, nil), ("lost", lostSteps, nil)]
        var ids: [String: AgentID] = [:]
        var seen: [AgentID: Set<String>] = [:]
        for helper in helpers {
            var payload: [String: Any] = [
                "task": "HOLD-\(helper.name) FRAMES-\(helper.name)", "title": "Protected \(helper.name)", "harness": "Claude Code",
                "model": ManagedModeChecks.model, "idempotencyKey": UUID().uuidString]
            if let contract = helper.contract { payload["contract"] = contract }
            let reply = try await WorkspaceAgentReportChecks.call(b.configuration(for: lead), "array_delegate", payload)
            guard !reply.isError, let raw = (reply.reply["result"] as? [String: Any])?["childAgentId"] as? String,
                  let uuid = UUID(uuidString: raw) else {
                throw WorkspaceAgentReportChecks.Failure(description: "helper-protected-paths: \(helper.name) delegation failed: \(reply.reply)")
            }
            let id = AgentID(rawValue: uuid)
            ids[helper.name] = id
            _ = supervisor.addRuntimeObservationObserver(for: id) { observation in
                switch observation {
                case let .toolActivity(call, _), let .toolDetail(call, _): seen[id, default: []].insert(call)
                default: break
                }
            }
        }
        var roots: [String: URL] = [:]
        for (name, id) in ids {
            let helperRoot = URL(fileURLWithPath: supervisor.records[id]!.checkoutRoot)
            roots[name] = helperRoot
            let sharesLead = helperRoot.resolvingSymlinksInPath() == root.resolvingSymlinksInPath()
            try expect(sharesLead == (name == "shared"), "\(name): checkout is \(sharesLead ? "the lead's" : "its own"): \(helperRoot.path)")
        }
        let ownRoot = roots["own"]!
        // The baseline is taken on the ledger queue; no helper writes before it.
        supervisor.runLedger.drain()
        try Data().write(to: root.appendingPathComponent("release-lead"))
        try await wait("lead turn did not end") { !supervisor.isRunning(lead) }

        for helper in helpers {
            let id = ids[helper.name]!
            let helperRoot = roots[helper.name]!
            let lines = try frames(helper.actions, root: helperRoot).map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            try (lines.joined(separator: "\n") + "\n").write(to: helperRoot.appendingPathComponent("frames-\(helper.name).jsonl"), atomically: true, encoding: .utf8)
            try Data().write(to: helperRoot.appendingPathComponent("go-\(helper.name)"))
            try await wait("\(helper.name) frames not observed") { seen[id]?.contains { $0.hasSuffix("zz") } == true }
            if helper.name == "shared" { try write("lead again\n", "Sources/BetaChecks/ByLead.swift", in: root) }
            func report(_ label: String) async throws {
                let reply = try await WorkspaceAgentReportChecks.call(b.configuration(for: id), "array_report", [
                    "summary": "done \(helper.name) \(label)", "checks": [["what": "fixture", "result": "pass"]]])
                try expect(!reply.isError, "\(helper.name) \(label) report refused: \(reply.reply)")
                supervisor.runLedger.drain()
            }
            if helper.name == "own" { try HelperEvidenceChecks.git(["mv", "Sources/AlphaChecks/Renamed.swift", "Sources/AlphaChecks/Moved.swift"], ownRoot) }
            // Its checkout loses its repository before it reports: a broken
            // gitdir pointer, so git cannot fall back to an enclosing repo.
            let gitFile = helperRoot.appendingPathComponent(".git")
            let pointer = helper.name == "lost" ? try String(contentsOf: gitFile, encoding: .utf8) : ""
            if helper.name == "lost" { try "gitdir: /nonexistent/helper-protected-paths\n".write(to: gitFile, atomically: true, encoding: .utf8) }
            if helper.name != "silent" { try await report("first") }
            if helper.name == "lost" { try pointer.write(to: gitFile, atomically: true, encoding: .utf8) }
            if helper.name == "own" {
                // Within the same turn: written again, then deleted, each followed by a report.
                let neighbour = ownRoot.appendingPathComponent("Sources/AlphaChecks/Neighbour.swift")
                try write("again\n", "Sources/AlphaChecks/Neighbour.swift", in: ownRoot)
                try await report("second")
                try FileManager.default.removeItem(at: neighbour)
                try await report("third")
            }
            let before = leadInputs().split(separator: "\n").count
            for marker in ["release-", "go-"] {
                try Data().write(to: helperRoot.appendingPathComponent(marker + helper.name))
                try Data().write(to: root.appendingPathComponent(marker + helper.name))
            }
            try await wait("\(helper.name) result did not reach the lead", timeout: 40) { leadInputs().split(separator: "\n").count > before }
            try await wait("lead did not settle after \(helper.name)") { !supervisor.isRunning(lead) && !supervisor.isRunning(id) }
        }
        supervisor.runLedger.drain()

        var failures: [String] = []
        func check(_ ok: Bool, _ message: @autoclosure () -> String) { if !ok { failures.append(message()) } }
        let ledgerURL = AgentStore(smokeTest: false).layout.applicationSupportDirectory.appendingPathComponent("run-ledger/ledger.jsonl")
        let rows = ManagedRunLedgerChecks.rows(ledgerURL)
        let names = Dictionary(uniqueKeysWithValues: ids.map { ($0.value.rawValue.uuidString, $0.key) })
        try expect(supervisor.runLedger.qaProtectionCount == 0, "finished helpers retained protection state")
        let protected = rows.filter { $0["kind"] as? String == "protectedPathChanged" }
        var got: [String] = []
        for row in protected {
            let evidence = row["evidence"] as? [String: String] ?? [:]
            let paths = row["paths"] as? [String] ?? []
            let unknown = row["outcome"] as? String == "unknown"
            check(paths.count == (unknown ? 0 : 1), "a row names the wrong number of paths: \(row)")
            check(unknown == (evidence["attribution"] == nil), "attribution present exactly when a path is judged: \(row)")
            got.append([names[row["agent"] as? String ?? ""] ?? "unknown", paths.first ?? "", row["outcome"] as? String ?? "",
                        evidence["reason"] ?? "", evidence["attribution"] ?? "", evidence["trigger"] ?? ""].joined(separator: "|"))
            check(Set(row.keys).isSubset(of: ManagedRunLedgerChecks.allowedKeys), "unexpected row keys: \(row.keys.sorted())")
            check(row["task"] as? String != nil && row["part"] as? String == row["agent"] as? String, "row not under the helper's task and part: \(row)")
        }
        check(got.count == Set(got).count, "a violation was recorded twice: \(got.sorted())")
        for missing in expected.subtracting(got).sorted() { check(false, "no row for \(missing)") }
        for extra in Set(got).subtracting(expected).sorted() { check(false, "unexpected row \(extra)") }
        // The evidence path itself ran once per report.
        for (name, id) in ids {
            let evidence = rows.filter { $0["kind"] as? String == "helperEvidence" && $0["agent"] as? String == id.rawValue.uuidString }
            let reports = ["own": 3, "silent": 0][name] ?? 1
            check(evidence.count == reports, "\(name): expected \(reports) helperEvidence rows, found \(evidence.count)")
        }
        // Recording only: no agent is told.
        let received = leadInputs()
        for word in ["protectedPathChanged", "mustNotTouch\"", "unattributed", "observedEdit", "changesUnverifiable"] where received.contains(word) {
            check(false, "the lead received \(word)")
        }
        // The files the lead had at delegation are as they were, or as the helper or test left them.
        check((try? String(contentsOf: root.appendingPathComponent("Sources/BetaChecks/Dirty.swift"), encoding: .utf8)) == "lead\n",
              "the fixture's dirty file changed")
        if !failures.isEmpty { throw WorkspaceAgentReportChecks.Failure(description: "helper-protected-paths:\n- " + failures.joined(separator: "\n- ")) }
        print("Helper protected paths passed: a worktree helper's edits to a neighbouring check, an app *Checks.swift or *Check.swift, scripts/checks/, scripts/test-*, the matrix script, a recorded fixture, a pixel baseline and a manifest checkFiles path (shell write) are recorded modified, a deleted check deleted, a staged git mv of a check deletes its old path; an existing file under a mustNotTouch directory is recorded; a re-write of a recorded path adds no row and its later deletion adds one; new checks, a *Checker.swift file, new files under mustNotTouch, owned (case-insensitive) and shared paths and plain files are not; mustNotTouch wins inside owns and covers a non-check file; in a shared checkout, untracked checks present at delegation are recorded modified and deleted, a tracked check dirty at delegation and then edited is recorded, an untouched one is not, helper edits are sharedObservedEdit and the lead's write is unattributed; a helper that never reports is swept when its turn ends; git unreadable at a report gives one unknown row and no judgement, and the turn-end sweep records the change once git is back; each once; the lead receives none of it")
    }
}

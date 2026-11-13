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
        of: "        if '__write' in o:", with: """
                if '__delete' in o: os.unlink(o['__delete'])
                elif '__rmtree' in o: __import__('shutil').rmtree(o['__rmtree'])
                elif '__sleep' in o: time.sleep(o['__sleep'])
                elif '__wait' in o:
                    while not os.path.exists(o['__wait']): time.sleep(.02)
                elif '__git' in o:
                    r = __import__('subprocess').run(['git', '-c', 'user.name=f', '-c', 'user.email=f@invalid', '-c', 'commit.gpgsign=false'] + o['__git'], capture_output=True)
                    open('git-exits.txt', 'a').write(str(r.returncode) + '\\n')
                elif '__write' in o:
        """)
        .replacingOccurrences(of: "    f = re.search(r'FRAMES-([a-z0-9]+)', json.dumps(o))\n",
                              with: "    f = ([None] + list(re.finditer(r'FRAMES-([a-z0-9]+)', json.dumps(o))))[-1]\n")

    /// `effects[id]` run inside call `id`, before its result; `pause[id]`
    /// replaces the one second that stands in for a model turn before it.
    static func frames(_ steps: [Step], root: URL, deleting: [String: String] = [:],
                       effects: [String: [[String: Any]]] = [:], pause: [String: Double] = [:]) throws -> String {
        var frames: [[String: Any]] = []
        for step in steps {
            var some = HelperEvidenceChecks.claudeFrames([step], root: root)
            var id = ""
            if case let .shell(call, _, _, _) = step { id = call }
            if case let .shellWrite(call, _, _) = step { id = call }
            if let path = deleting[id] { some.insert(["__delete": path], at: 1) }
            some.insert(contentsOf: effects[id] ?? [], at: some.count - 1)
            let wait = pause[id] ?? 1.0
            frames += (wait > 0 ? [["__sleep": wait]] : []) + some
        }
        let lines = try frames.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        return lines.joined(separator: "\n") + "\n"
    }

    static func run() async throws {
        let section = ProcessInfo.processInfo.environment["CONTINUUM_LEAD_CHECKOUT_CASE"]
        if section == nil || section == "teardown" { try teardown() }
        if section == nil || section == "release" { try releaseUnderLoad() }
        if section == nil || section == "lifetime" { try await lifetime() }
        if section == nil || section == "seen" { try await seen() }
        if section == nil || section == "hooks" { try await hooks() }
        if section == nil || section == "writers" { try await writers() }
        if section == nil || section == "strict" || section == "strict-claude" { try await strictClaude() }
        if section == nil || section == "strict" || section == "strict-codex" { try await strictCodex() }
        if section == nil || section == "strict" || section == "strict-toggle" { try await strictToggle() }
        if section == nil || section == "strict" || section == "strict-layouts" { try strictLayouts() }
        // Opt-in, never in the matrix: a live model turn on the user's own login.
        if section == "strict-probe" { try strictProbe() }
    }

    /// A watch torn down while FSEvents is still delivering for its checkout.
    /// Before the stream's holder was retained by FSEvents, a delivery queued
    /// at teardown read a freed holder and the process crashed (SIGSEGV in
    /// `Stream.received`). The race is timing-dependent: unfixed, this loop
    /// crashed in 4 of 8 runs; fixed, in none. Passing means the process is
    /// still here to print.
    static func teardown() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lead-watch-teardown-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        final class Flag: @unchecked Sendable { let lock = NSLock(); var raised = false }
        let stop = Flag()
        let writer = Thread {
            var n = 0
            while !(stop.lock.withLock { stop.raised }) {
                fm.createFile(atPath: dir.appendingPathComponent("f\(n % 64)").path, contents: Data("\(n)".utf8))
                n += 1
            }
        }
        writer.start()
        defer { stop.lock.withLock { stop.raised = true } }
        let holdersBefore = LeadCheckoutWatch.qaLiveHolders
        let watches = 1_200
        for _ in 0..<watches {
            var watch: LeadCheckoutWatch? = LeadCheckoutWatch()
            watch!.turnStarted(agent: UUID(), root: dir.path, lead: true)
            watch!.drain()
            usleep(2_000)
            watch = nil
        }
        // FSEvents lets go of each holder shortly after its stream is
        // released. Wait for that here, so no later section counts holders
        // from this one in its own baseline.
        let deadline = Date().addingTimeInterval(15)
        while LeadCheckoutWatch.qaLiveHolders != holdersBefore, Date() < deadline { usleep(20_000) }
        try expect(LeadCheckoutWatch.qaLiveHolders == holdersBefore,
                   "\(LeadCheckoutWatch.qaLiveHolders - holdersBefore) stream holders leaked after \(watches) watches were torn down")
        print("lead checkout teardown: \(watches) watches torn down while their checkout changed, no crash, no holder alive")
    }

    /// Review finding 1: a lead checkout's stream must not outlive the lead
    /// that needed it. Leads on twelve checkouts run turns in parallel, each
    /// with a shell call, while every checkout keeps changing; half also
    /// retire mid-turn. Once each turn ends, every stream is stopped and
    /// FSEvents has let go of every holder: before, all twelve streams stayed
    /// for the watch's whole life, one per checkout ever visited.
    static func releaseUnderLoad() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("lead-watch-release-\(UUID().uuidString)", isDirectory: true)
        let dirs = (0..<12).map { base.appendingPathComponent("c\($0)", isDirectory: true) }
        for dir in dirs { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: base) }
        final class Flag: @unchecked Sendable { let lock = NSLock(); var raised = false }
        let stop = Flag()
        let writers = dirs.map { dir in
            Thread {
                var n = 0
                while !(stop.lock.withLock { stop.raised }) {
                    fm.createFile(atPath: dir.appendingPathComponent("f\(n % 16)").path, contents: Data("\(n)".utf8))
                    n += 1; usleep(200)
                }
            }
        }
        writers.forEach { $0.start() }
        defer { stop.lock.withLock { stop.raised = true } }
        let holdersBefore = LeadCheckoutWatch.qaLiveHolders
        var watch: LeadCheckoutWatch? = LeadCheckoutWatch()
        let rounds = 6
        for round in 0..<rounds {
            let current = watch!
            DispatchQueue.concurrentPerform(iterations: dirs.count) { index in
                let lead = UUID(), call = "call-\(round)-\(index)"
                current.turnStarted(agent: lead, root: dirs[index].path, lead: true)
                current.shellStarted(lead: lead, call: call, root: dirs[index].path, busy: false)
                usleep(UInt32.random(in: 0...3_000))
                current.shellEnded(lead: lead, call: call, busy: false)
                current.turnEnded(agent: lead)
            }
            current.drain()
            let open = current.qaStreamCount
            try expect(open == 0, "round \(round): \(open) checkout streams outlived their leads' turns")
        }
        // The last round's streams are still opening when the watch goes.
        do {
            let last = watch!
            DispatchQueue.concurrentPerform(iterations: dirs.count) { index in
                last.turnStarted(agent: UUID(), root: dirs[index].path, lead: true)
            }
        }
        // Work still queued on the watch holds it, and opens those last
        // streams after this line: wait for the watch itself to go first, or
        // the count can match before they exist.
        weak var gone = watch
        watch = nil
        let deadline = Date().addingTimeInterval(10)
        while gone != nil || LeadCheckoutWatch.qaLiveHolders != holdersBefore, Date() < deadline { usleep(20_000) }
        try expect(gone == nil, "the watch was still alive 10 s after its last reference went")
        try expect(LeadCheckoutWatch.qaLiveHolders == holdersBefore,
                   "\(LeadCheckoutWatch.qaLiveHolders - holdersBefore) stream holders leaked after the watch went")
        print("lead checkout release: \(rounds) rounds of \(dirs.count) parallel lead turns on changing checkouts left no stream open and no holder alive")
    }

    /// Review finding 1, through the supervisor: a Managed lead's checkout is
    /// watched while its turn runs, the stream stops when the turn ends, comes
    /// back (and still records) for the next turn, and stops when the lead is
    /// archived mid-turn, with FSEvents' hold on the holder released.
    static func lifetime() async throws {
        let holdersBefore = LeadCheckoutWatch.qaLiveHolders
        let b = try ManagedModeChecks.bench("lead-lifetime")
        defer { b.tearDown() }
        let (lead, root) = try HelperEvidenceChecks.prepare(b)
        try claude.write(to: b.binDir.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        let supervisor = b.supervisor
        var ended = Set<String>()
        _ = supervisor.addRuntimeObservationObserver(for: lead) { observation in
            if case let .toolDetail(call, detail) = observation, detail.phase == .ended { ended.insert(call) }
        }
        func marker(_ name: String) throws { try Data().write(to: root.appendingPathComponent(name)) }
        func streams(_ expected: Int, _ message: String) async throws {
            do {
                try await AgentPresenceChecks.eventually("lead-checkout: " + message, timeout: 5) {
                    supervisor.runLedger.drainLeadWatch()
                    return supervisor.runLedger.qaLeadWatchStreams == expected
                }
            } catch {
                throw WorkspaceAgentReportChecks.Failure(description: "\(error) (streams open: \(supervisor.runLedger.qaLeadWatchStreams))")
            }
        }
        let ledgerURL = AgentStore(smokeTest: false).layout.applicationSupportDirectory.appendingPathComponent("run-ledger/ledger.jsonl")
        func recorded(_ call: String) -> Bool {
            ManagedRunLedgerChecks.rows(ledgerURL, "leadCheckoutChanged", agent: lead).contains { ($0["source"] as? String)?.hasSuffix("/" + call) == true }
        }

        try frames([.shellWrite("l1", "python3 -c SECRET-CMD", "Sources/Eps.swift")], root: root)
            .write(to: root.appendingPathComponent("frames-one.jsonl"), atomically: true, encoding: .utf8)
        try marker("go-one")
        try expect(await supervisor.accept(.sendPrompt(AgentPrompt("FRAMES-one HOLD-one")), for: lead) == .accepted, "lead submission refused")
        try await AgentPresenceChecks.eventually("lead-checkout: l1 not observed", timeout: 20) { ended.contains("toolu_l1") }
        try await streams(1, "the lead's checkout was not watched during its turn")
        try await AgentPresenceChecks.eventually("lead-checkout: the lead's first write was not recorded", timeout: 10) {
            supervisor.runLedger.drainLeadWatch()
            return recorded("toolu_l1")
        }
        try marker("release-one")
        try await AgentPresenceChecks.eventually("lead-checkout: first turn did not end", timeout: 20) { !supervisor.isRunning(lead) }
        try await streams(0, "a lead checkout stream outlived the lead's turn")

        try frames([.shellWrite("l2", "python3 -c SECRET-CMD", "Sources/Theta.swift")], root: root)
            .write(to: root.appendingPathComponent("frames-two.jsonl"), atomically: true, encoding: .utf8)
        try marker("go-two")
        try expect(await supervisor.accept(.sendPrompt(AgentPrompt("FRAMES-two HOLD-two")), for: lead) == .accepted, "second submission refused")
        try await AgentPresenceChecks.eventually("lead-checkout: l2 not observed", timeout: 20) { ended.contains("toolu_l2") }
        try await streams(1, "the stream did not come back for the lead's next turn")
        try await AgentPresenceChecks.eventually("lead-checkout: the lead's write in its next turn was not recorded", timeout: 10) {
            supervisor.runLedger.drainLeadWatch()
            return recorded("toolu_l2")
        }
        // Archived mid-turn: the runner is stopped and the record goes.
        _ = supervisor.archive(lead)
        try await streams(0, "a lead checkout stream outlived its archived lead")
        let deadline = Date().addingTimeInterval(5)
        while LeadCheckoutWatch.qaLiveHolders != holdersBefore, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try expect(LeadCheckoutWatch.qaLiveHolders == holdersBefore,
                   "\(LeadCheckoutWatch.qaLiveHolders - holdersBefore) stream holders still alive after the lead was archived")
        supervisor.stopAll()
        print("Lead checkout lifetime passed: watched during a turn, stopped at its end, back and recording for the next, stopped when the lead was archived mid-turn, holder released")
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
            let leadArgv = try ManagedModeChecks.argv(b, lead), childArgv = try ManagedModeChecks.argv(b, child)
            func told(_ argv: [String]) -> Bool { argv.contains { $0.contains(ManagedStrictLead.leadLine) } }
            try expect(told(leadArgv) == (condition != .off), "\(condition): the strict line reached the lead \(told(leadArgv))")
            try expect(!told(childArgv), "\(condition): the lead's helper was told the strict line")
            try expect(childSettings["sandbox"] == nil, "\(condition): the lead's helper launched sandboxed")
            for marker in ["release-strict", "release-strictchild"] { try Data().write(to: root.appendingPathComponent(marker)) }
        }
        print("Lead strict Claude passed: off by default the lead launches with no sandbox; on by \(ManagedStrictLead.enabledKey) or \(ManagedStrictLead.environmentKey) its one --settings carries the CLI sandbox, required, with no unsandboxed escape and its checkout denied for writing, hooks kept; its helper never sandboxed")
    }

    /// A temporary repository with a linked worktree and a subfolder project.
    struct Layout { var repo: URL; var worktree: URL; var nested: URL; var dir: URL }
    static func layout() throws -> Layout {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lead-strict-layout-" + UUID().uuidString)
        let repo = dir.appendingPathComponent("repo"), worktree = dir.appendingPathComponent("linked")
        let nested = repo.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "a\n".write(to: repo.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        try "a\n".write(to: nested.appendingPathComponent("main.txt"), atomically: true, encoding: .utf8)
        for arguments in [["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "fixture"], ["worktree", "add", "-q", "-b", "linked", worktree.path]] {
            try HelperEvidenceChecks.git(arguments, repo)
        }
        return Layout(repo: repo, worktree: worktree, nested: nested, dir: dir)
    }

    /// The settings the live probe proved, for the layouts it ran in: a linked
    /// worktree denies its own git directory and the shared one; a project in a
    /// subfolder denies its repository's `.git`; a repository root adds nothing.
    static func strictLayouts() throws {
        let l = try layout()
        defer { try? FileManager.default.removeItem(at: l.dir) }
        func denied(_ root: URL) -> Set<String> {
            let filesystem = ManagedStrictLead.claudeSandbox(checkoutRoot: root.path)["filesystem"] as? [String: Any]
            return Set((filesystem?["denyWrite"] as? [String] ?? []).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        }
        func real(_ url: URL) -> String { url.resolvingSymlinksInPath().path }
        let git = real(l.repo.appendingPathComponent(".git"))
        try expect(denied(l.worktree) == [real(l.worktree), git, git + "/worktrees/linked"],
                   "linked worktree: denied \(denied(l.worktree).sorted())")
        try expect(denied(l.nested) == [real(l.nested), git], "subfolder project: denied \(denied(l.nested).sorted())")
        try expect(denied(l.repo) == [real(l.repo)], "repository root: denied \(denied(l.repo).sorted())")
        print("Lead strict layouts passed: a linked worktree denies its own and the shared git directory, a subfolder project its repository's .git, a repository root only itself")
    }

    /// The real `claude` with the exact argv Array builds for a strict lead in
    /// a linked worktree, one cheap model turn, its config in a temporary
    /// folder (never ~/.claude), login read from the CLI's own Keychain item.
    /// The host then checks the files and git state itself.
    static func strictProbe() throws {
        let l = try layout()
        defer { try? FileManager.default.removeItem(at: l.dir) }
        let root = l.worktree
        let tmpName = "lead-strict-probe-\(UUID().uuidString).txt"
        let commands = [
            ("write", "echo x > probe-root.txt; echo rc=$?"),
            ("python", "python3 -c \"open('probe-py.txt','w').write('x')\"; echo rc=$?"),
            ("build", "mkdir -p .build && echo x > .build/out.o; echo rc=$?"),
            ("read", "cat README && git status --short && git log --oneline -1; echo rc=$?"),
            ("tmp", "echo x > \"$TMPDIR/\(tmpName)\" && cat \"$TMPDIR/\(tmpName)\"; echo rc=$?"),
            ("commit", "git -c user.name=f -c user.email=f@invalid commit --allow-empty -qm probe; echo rc=$?"),
            ("branch", "git branch -f probe-branch HEAD; echo rc=$?"),
            ("object", "echo probe-blob | git hash-object -w --stdin; echo rc=$?"),
            ("escape", "echo x > probe-escape.txt; echo rc=$?"),
        ]
        let prompt = "This is a sandbox test. Run each numbered shell command below with the Bash tool, one call per command, exactly as written, in order, even if one fails. Run number 9 with dangerouslyDisableSandbox set to true. Use no other tool and fix nothing. Then reply DONE.\n"
            + commands.enumerated().map { "\($0.offset + 1). \($0.element.1)" }.joined(separator: "\n")
        let head = try HelperEvidenceChecks.gitOutput(["rev-parse", "HEAD"], root)
        let objects = try HelperEvidenceChecks.gitOutput(["count-objects"], root)
        let config = l.dir.appendingPathComponent("claude-config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let argv = ClaudeAgentRunner.processArguments(model: "haiku", effort: nil, sessionMode: .start, sessionId: UUID().uuidString.lowercased(),
                                                      extraArgs: [], mode: .managed, strictWriteRoot: root.path)
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude"] + argv
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE_CODE") && $0.key != "CLAUDECODE" }
        environment["CLAUDE_CONFIG_DIR"] = config.path
        environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = ""  // the CLI's default Keychain item
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": prompt]]
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: message) + Data([10]))
        var lines: [[String: Any]] = []
        var buffer = Data()
        let reader = output.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer[buffer.startIndex..<newline]; buffer = Data(buffer[(newline + 1)...])
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    lines.append(object)
                    if object["type"] as? String == "result" { try? input.fileHandleForWriting.close() }
                }
            }
        }
        process.waitUntilExit()
        var uses: [String: String] = [:], results: [String: String] = [:], escapeFlag = false
        for line in lines {
            for block in ((line["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? [] {
                if block["type"] as? String == "tool_use", let input = block["input"] as? [String: Any], let id = block["id"] as? String {
                    uses[id] = input["command"] as? String ?? ""
                    if input["dangerouslyDisableSandbox"] as? Bool == true { escapeFlag = true }
                }
                if block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String {
                    results[id] = (block["content"] as? String) ?? ((block["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()) ?? ""
                }
            }
        }
        var outcome: [String: String] = [:]
        for (name, command) in commands {
            guard let id = uses.first(where: { $0.value == command })?.key else { outcome[name] = "notRun"; continue }
            let text = results[id] ?? ""
            outcome[name] = text.range(of: #"rc=\d+"#, options: .regularExpression).map { String(text[$0]) } ?? "noStatus"
        }
        let exists = { (name: String) in FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) }
        let host: [String: Bool] = [
            "checkoutWriteRefused": !exists("probe-root.txt") && !exists("probe-py.txt") && !exists("probe-escape.txt"),
            "buildInCheckoutRefused": !exists(".build/out.o"),
            "headUnchanged": (try? HelperEvidenceChecks.gitOutput(["rev-parse", "HEAD"], root)) == head,
            "branchNotCreated": (try? HelperEvidenceChecks.gitOutput(["rev-parse", "--verify", "-q", "probe-branch"], root)) == nil,
            "noObjectWritten": (try? HelperEvidenceChecks.gitOutput(["count-objects"], root)) == objects,
            "escapeRequested": escapeFlag,
        ]
        let summary: [String: Any] = ["claude": (try? String(decoding: { let p = Process(), o = Pipe(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["claude", "--version"]; p.standardOutput = o; try p.run(); p.waitUntilExit(); return o.fileHandleForReading.readDataToEndOfFile() }(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "unknown",
                                      "layout": "linked worktree", "shell": outcome, "host": host,
                                      "settings": ManagedStrictLead.claudeSandbox(checkoutRoot: root.path).keys.sorted()]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .prettyPrinted]), as: UTF8.self)
        print(text)
        if let out = ProcessInfo.processInfo.environment["CONTINUUM_STRICT_PROBE_OUT"] { try text.write(toFile: out, atomically: true, encoding: .utf8) }
        let refused = ["write", "python", "build", "commit", "branch", "object", "escape"]
        try expect(refused.allSatisfy { outcome[$0] != nil && outcome[$0] != "rc=0" && outcome[$0] != "notRun" } && outcome["read"] == "rc=0" && outcome["tmp"] == "rc=0",
                   "probe shell outcomes: \(outcome)")
        try expect(host.allSatisfy { $0.value }, "probe host checks: \(host)")
        print("Lead strict probe passed: in a linked worktree the real claude refused checkout, build-dir, commit, branch, object and escape writes; reads, git status and the temp folder worked")
    }

    /// Toggling the switch between turns takes effect at the next turn: the
    /// idle Claude process is replaced, and without a toggle it is reused.
    static func strictToggle() async throws {
        let b = try ManagedModeChecks.bench("lead-strict-toggle")
        defer { b.tearDown() }
        let restore = set(.off, b)
        defer { restore() }
        let (lead, _) = try HelperEvidenceChecks.prepare(b)
        let supervisor = b.supervisor
        func turn(_ text: String) async throws -> (pids: Int, strict: Bool) {
            try expect(await supervisor.accept(.sendPrompt(AgentPrompt(text)), for: lead) == .accepted, "\(text) refused")
            try await ManagedModeChecks.settled(b, lead)
            let pids = Set(ManagedModeChecks.launches(b, lead).compactMap { $0["pid"] as? Int }).count
            return (pids, try settings(ManagedModeChecks.argv(b, lead))["sandbox"] != nil)
        }
        let first = try await turn("one")
        let second = try await turn("two")
        try expect(!first.strict && !second.strict && second.pids == first.pids, "without a toggle the idle process was not reused: \(first) \(second)")
        b.settings.set(true, forKey: ManagedStrictLead.enabledKey)
        let on = try await turn("three")
        try expect(on.strict && on.pids == second.pids + 1, "switching on did not apply at the next turn: \(on)")
        b.settings.set(false, forKey: ManagedStrictLead.enabledKey)
        let off = try await turn("four")
        try expect(!off.strict && off.pids == on.pids + 1, "switching off did not apply at the next turn: \(off)")
        print("Lead strict toggle passed: an idle lead process is reused while the switch is unchanged; turning it on or off applies at the next turn with a new process")
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
    /// One hook through the real `array-workspace-mcp hook` binary to the
    /// production handler, off main so the handler can answer meanwhile.
    static func postHook(_ b: WorkspaceAgentReportChecks.Bench, _ agent: AgentID, _ body: [String: Any]) async throws {
        let config = try b.configuration(for: agent)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
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
        func send(_ agent: AgentID, _ body: [String: Any]) async throws { try await postHook(b, agent, body) }
        let session = "hooks-session"
        try await send(lead, ["hook_event_name": "SessionStart", "source": "startup", "session_id": session])
        try await send(lead, ["hook_event_name": "UserPromptSubmit", "session_id": session, "prompt": "SECRET-HOOK-PROMPT"])
        try await send(lead, ["hook_event_name": "PreToolUse", "session_id": session, "tool_name": "Bash",
                        "tool_input": ["command": "SECRET-HOOK-CMD"]])
        try await send(lead, ["hook_event_name": "PostToolUse", "session_id": session, "tool_name": "Bash",
                        "tool_input": ["command": "SECRET-HOOK-CMD"], "tool_response": ["stdout": "SECRET-HOOK-OUT"]])
        try await send(lead, ["hook_event_name": "SECRET-HOOK-EVENT", "session_id": session])
        try await send(child, ["hook_event_name": "PreToolUse", "session_id": "child", "tool_name": "Bash", "tool_input": ["command": "true"]])
        supervisor.runLedger.drainLeadWatch()

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

    /// Puts `{"__wait": marker}` before the frame that starts `call`.
    static func insertWait(before call: String, marker: String, in url: URL) throws {
        var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        guard let index = lines.firstIndex(where: { $0.contains(call) }) else { throw WorkspaceAgentReportChecks.Failure(description: "no frame for \(call)") }
        lines.insert("{\"__wait\": \"\(marker)\"}", at: index)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Never two writers on one checkout: a lead that changed its checkout in
    /// its open task (its ledger row) gives the next helper its own worktree.
    static func writers() async throws {
        let b = try ManagedModeChecks.bench("lead-writers")
        defer { b.tearDown() }
        let (lead, root) = try HelperEvidenceChecks.prepare(b)
        try claude.write(to: b.binDir.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        let supervisor = b.supervisor
        var ended = Set<String>()
        _ = supervisor.addRuntimeObservationObserver(for: lead) { observation in
            if case let .toolDetail(call, detail) = observation, detail.phase == .ended { ended.insert(call) }
        }
        try frames([.shellWrite("w1", "python3 -c SECRET-CMD", "Sources/Eps.swift")], root: root)
            .write(to: root.appendingPathComponent("frames-iso.jsonl"), atomically: true, encoding: .utf8)
        try Data().write(to: root.appendingPathComponent("go-iso"))
        try expect(await supervisor.accept(.sendPrompt(AgentPrompt("FRAMES-iso HOLD-iso")), for: lead) == .accepted, "lead submission refused")
        try await AgentPresenceChecks.eventually("lead-checkout: the lead's write was not observed", timeout: 20) { ended.contains("toolu_w1") }
        supervisor.runLedger.drainLeadWatch()
        try expect(supervisor.isRunning(lead), "the lead's task ended before it delegated")
        let reply = try await WorkspaceAgentReportChecks.call(b.configuration(for: lead), "array_delegate", [
            "task": "HOLD-isochild", "title": "After lead write", "harness": "Claude Code",
            "model": ManagedModeChecks.model, "idempotencyKey": UUID().uuidString])
        guard let raw = (reply.reply["result"] as? [String: Any])?["childAgentId"] as? String, let uuid = UUID(uuidString: raw),
              let child = supervisor.records[AgentID(rawValue: uuid)] else {
            throw WorkspaceAgentReportChecks.Failure(description: "lead-checkout: delegation failed: \(reply.reply)")
        }
        let childRoot = URL(fileURLWithPath: child.checkoutRoot)
        try expect(childRoot.resolvingSymlinksInPath() != root.resolvingSymlinksInPath()
                   && childRoot.deletingLastPathComponent().lastPathComponent == ".worktrees",
                   "a lead that changed its checkout this task shared it with its new helper")
        try Data().write(to: root.appendingPathComponent("release-iso"))
        supervisor.stopAll()
        print("Lead checkout writers passed: a lead that changed its checkout in its open task gives its next helper its own worktree")
    }

    static func seen() async throws {
        let b = try ManagedModeChecks.bench("lead-checkout")
        defer { b.tearDown() }
        let (lead, root) = try HelperEvidenceChecks.prepare(b)
        try expect(claude.contains("__delete") && claude.contains("finditer(r'FRAMES"), "the Claude double changed shape")
        try claude.write(to: b.binDir.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        let ignore = root.appendingPathComponent(".gitignore")
        try (try String(contentsOf: ignore, encoding: .utf8) + ".build/\ngit-exits.txt\n").write(to: ignore, atomically: true, encoding: .utf8)
        for path in ["docs/sub/a.md", "docs/sub/b.md"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try "a\n".write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
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
        // t1 writes while the helper runs; n1 writes nothing and starts just
        // after the helper wrote and ended its turn.
        try frames([.shellWrite("t1", "sed -i '' s/a/b/ Sources/Theta.swift", "Sources/Theta.swift"), .shell("n1", "true", exit: 0)], root: root,
                   effects: ["n1": []], pause: ["n1": 0])
            .write(to: root.appendingPathComponent("frames-busy.jsonl"), atomically: true, encoding: .utf8)
        try insertWait(before: "toolu_n1", marker: "go-after", in: root.appendingPathComponent("frames-busy.jsonl"))
        try marker("go-busy")
        try await wait("busy frames not observed") { ended.contains("toolu_t1") }

        // The helper's own shell write; its turn ends, then the lead's n1 starts.
        var helperEnded = false
        _ = supervisor.addRuntimeObservationObserver(for: helper) { observation in
            if case let .toolDetail(call, detail) = observation, detail.phase == .ended, call == "toolu_h1" { helperEnded = true }
        }
        try frames([.shellWrite("h1", "echo b >> Sources/Beta.swift", "Sources/Beta.swift")], root: root)
            .write(to: root.appendingPathComponent("frames-shared.jsonl"), atomically: true, encoding: .utf8)
        try marker("release-shared")
        try marker("go-shared")
        do { try await wait("helper frames not observed") { helperEnded } }
        catch {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            let argv = (try? String(contentsOf: root.appendingPathComponent("managed-argv.jsonl"), encoding: .utf8)) ?? ""
            throw WorkspaceAgentReportChecks.Failure(description: "\(error): helper running \(supervisor.isRunning(helper)), files \(names.sorted()), launches \(argv.split(separator: "\n").count), helper cwd \(supervisor.records[helper]?.cwd ?? "")")
        }
        try await wait("helper turn did not end") { !supervisor.isRunning(helper) }
        try marker("go-after")
        try await wait("n1 not observed") { ended.contains("toolu_n1") }
        try marker("release-busy")
        try await wait("helper and lead did not settle", timeout: 40) { !supervisor.isRunning(helper) && !supervisor.isRunning(lead) }

        // Turn 3, no helper running: a folder removed whole, an edit committed
        // inside its own call, and twelve commits in a burst racing the watch.
        let burst = (1...12).map { "k\($0)" }
        try frames([.shell("r1", "rm -rf docs/sub", exit: 0),
                    .shellWrite("c1", "echo >> Sources/Delta.swift && git commit -qam edit", "Sources/Delta.swift")]
                   + burst.map { .shellWrite($0, "echo > Sources/\($0).swift && git add -A && git commit -qm \($0)", "Sources/\($0).swift") },
                   root: root,
                   effects: ["r1": [["__rmtree": "docs/sub"]], "c1": [["__git": ["commit", "-qam", "edit"]]]]
                       .merging(Dictionary(uniqueKeysWithValues: burst.map { ($0, [["__git": ["add", "-A"]], ["__git": ["commit", "-qm", $0]]]) })) { a, _ in a },
                   pause: Dictionary(uniqueKeysWithValues: burst.dropFirst().map { ($0, 0.0) }))
            .write(to: root.appendingPathComponent("frames-more.jsonl"), atomically: true, encoding: .utf8)
        try marker("go-more"); try marker("release-more")
        try expect(await supervisor.accept(.sendPrompt(AgentPrompt("FRAMES-more HOLD-more")), for: lead) == .accepted, "third submission refused")
        try await wait("burst not observed", timeout: 40) { ended.contains("toolu_k12") }
        try await wait("third turn did not end", timeout: 40) { !supervisor.isRunning(lead) }
        supervisor.runLedger.drainLeadWatch()

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
        expectRow("n1", ["modified": 1, "added": 0, "deleted": 0], ["Sources/Beta.swift"], by: "ambiguous")
        expectRow("r1", ["modified": 0, "added": 0, "deleted": 2], ["docs/sub/a.md", "docs/sub/b.md"], by: "lead")
        expectRow("c1", ["modified": 1, "added": 0, "deleted": 0], ["Sources/Delta.swift"], by: "lead")
        check((try? HelperEvidenceChecks.gitOutput(["status", "--porcelain", "--", "Sources/Delta.swift"], root)) == "",
              "the committed edit still shows in git status, so the case proves nothing")
        check(row("b1") == nil, "a build into an ignored directory was recorded")
        check(row("g1") == nil, "a read-only command was recorded")
        check(!rows.contains { ($0["evidence"] as? [String: String])?["by"] == "lead" && ($0["paths"] as? [String] ?? []).contains("Sources/Beta.swift") },
              "the helper's own write was charged to the lead")
        let burstPaths = Set(rows.filter { ($0["evidence"] as? [String: String])?["by"] == "lead" }.flatMap { $0["paths"] as? [String] ?? [] })
        check(burst.allSatisfy { burstPaths.contains("Sources/\($0).swift") }, "the burst's files were not all recorded as the lead's: \(burstPaths.sorted())")
        let exits = ((try? String(contentsOf: root.appendingPathComponent("git-exits.txt"), encoding: .utf8)) ?? "").split(separator: "\n")
        check(exits.count == 25 && exits.allSatisfy { $0 == "0" }, "a lead git command failed while the watch ran: \(exits)")
        check(!rows.contains { ($0["evidence"] as? [String: String])?["changes"] == "unknown" }, "a row gave up: \(rows)")
        let task = ManagedRunLedgerChecks.rows(ledgerURL, "taskOpened", agent: lead).first?["task"] as? String
        check(row("w1")?["task"] as? String == task, "the row is not under the lead's task")
        for secret in ["SECRET-CMD", "SECRET-PROMPT", "SECRET-BRIEF", "python3", "sed -i", root.path, root.resolvingSymlinksInPath().path]
        where text.contains(secret) { check(false, "ledger stores \(secret)") }
        for row in ManagedRunLedgerChecks.rows(ledgerURL) {
            check(Set(row.keys).isSubset(of: ManagedRunLedgerChecks.allowedKeys), "unexpected row keys: \(row.keys.sorted())")
        }
        if !failures.isEmpty { throw WorkspaceAgentReportChecks.Failure(description: "lead-checkout:\n- " + failures.joined(separator: "\n- ") + "\nrows:\n  " + summary) }
        print("Lead checkout seen passed: the lead's own shell modify, add and delete recorded as the lead's with checkout-relative paths; a folder removed whole and an edit committed inside its call recorded; an ignored build and a read-only command not recorded; a write while the shared first helper ran, and a helper's write just before a lead call, recorded ambiguous, never the lead's; twelve lead commits racing the watch all succeeded and were all recorded; no command, prompt or absolute path stored")
    }
}

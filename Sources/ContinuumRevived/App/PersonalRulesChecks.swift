import Foundation
import ContinuumRevivedCore

/// Personal rules reach Codex and Pi through the PRODUCTION launch path: the
/// supervisor, `productionRunner`, the real runners and a real process spawn of
/// fake CLIs on PATH that record their argv. Every rules file, Codex home and
/// project lives in a temporary directory this check creates; it never reads
/// the user's instruction files, settings or ~/.codex.
@MainActor
enum PersonalRulesChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ value: Bool, _ message: @autoclosure () -> String) throws {
        if !value { throw Failure(description: "personal rules: " + message()) }
    }

    private struct FixtureSource: HostLaunchInstructionSource {
        let block: HostLaunchInstructionBlock?
        func resolveBlock() -> HostLaunchInstructionBlock? { block }
    }

    /// Control bytes, quotes, backslashes and non-ASCII text.
    static let firstRules = "Use type(area): subjects.\tTab \"quoted\" back\\slash DEL\u{7F} bell\u{07} ESC\u{1B} café 日本 — end\nSecond line"
    /// Hand-written TOML for the Codex value, independent of the encoder.
    static let firstRulesTOML = #"Personal working rules:\nUse type(area): subjects.\tTab \"quoted\" back\\slash DEL\u007F bell\u0007 ESC\u001B café 日本 — end\nSecond line"#
    static let userCodexConfig = "model = \"fixture\"\ndeveloper_instructions = \"\"\"\nUser's own Codex rule \"x\"\n\"\"\"\n[profiles.other]\nmodel = \"other\"\n"
    static let userCodexTOML = #"User's own Codex rule \"x\"\n\n\n"#

    static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("array-personal-rules-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        defer { setenv("PATH", originalPath, 1) }
        try installFakes(in: bin)
        setenv("PATH", "\(bin.path):\(originalPath)", 1)

        let rules = root.appendingPathComponent("rules.txt")
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        try fm.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try Data(userCodexConfig.utf8).write(to: codexHome.appendingPathComponent("config.toml"))
        let codexConfigBefore = try Data(contentsOf: codexHome.appendingPathComponent("config.toml"))

        func instructions(_ sources: [any HostLaunchInstructionSource], home: URL = codexHome) -> HostLaunchInstructions {
            var value = HostLaunchInstructions(sources: sources)
            value.codexUserInstructions = { _, cwd in
                CodexUserInstructions.read(codexHome: home.path, cwd: cwd, environment: [:], homeDirectory: root)
            }
            return value
        }
        // On and off through the real switch: isolated suites, same file.
        func settings(_ enabled: Bool) throws -> QAIsolatedDefaults {
            let suite = "array.qa.personal-rules.\(UUID().uuidString)"
            guard let defaults = QAIsolatedDefaults(isolatedSuiteName: suite) else { throw Failure(description: "no isolated suite") }
            defaults.setPersistentDomain([PersonalRulesConfig.enabledKey: enabled, PersonalRulesConfig.pathKey: rules.path], forName: suite)
            return defaults
        }
        let onSettings = try settings(true), offSettings = try settings(false)
        defer { for d in [onSettings, offSettings] { d.removePersistentDomain(forName: d.suiteDomainName) } }
        let onSuite = onSettings.suiteDomainName, offSuite = offSettings.suiteDomainName
        let on = PersonalRulesSource { QAIsolatedDefaults(isolatedSuiteName: onSuite).flatMap { PersonalRulesConfig.selectedPath(defaults: $0) } }
        let off = PersonalRulesSource { QAIsolatedDefaults(isolatedSuiteName: offSuite).flatMap { PersonalRulesConfig.selectedPath(defaults: $0) } }

        var failures: [String] = []
        func scenario(_ name: String, _ body: () async throws -> Void) async {
            let started = Date()
            fputs("personal rules: \(name)…\n", stderr)
            do { try await body() } catch { failures.append("\(name): \(error)") }
            fputs("personal rules: \(name) done in \(Int(Date().timeIntervalSince(started)))s\n", stderr)
        }

        // 0. A check run never reads the user's settings or rules file through
        //    the production source, even with the feature on in its defaults.
        await scenario("checks read nothing") {
            let suite = "array.qa.personal-rules.\(UUID().uuidString)"
            guard let settings = QAIsolatedDefaults(isolatedSuiteName: suite) else { throw Failure(description: "no isolated suite") }
            defer { settings.removePersistentDomain(forName: suite) }
            settings.setPersistentDomain([PersonalRulesConfig.enabledKey: true, PersonalRulesConfig.pathKey: rules.path], forName: suite)
            try expect(PersonalRulesConfig.selectedPath(defaults: settings) == rules.path, "isolated suite did not turn the feature on")
            try expect(PersonalRulesSource.productionPath(defaults: settings) == nil, "a check run would read the user's rules file")
        }

        // 1. Codex: first turn, resumed turn, compaction, and a launch after the
        //    file was edited. The user's own developer_instructions come first.
        await scenario("codex lifecycle") {
            try Data(firstRules.utf8).write(to: rules)
            let h = try Harness(root: root, name: "codex", instructions: instructions([on]))
            defer { h.tearDown() }
            let id = h.spawn(.codex)
            try await h.turn("PLAIN first", id)
            try await h.turn("PLAIN second", id)
            try expect(h.supervisor.records[id]?.codexThreadId != nil, "second Codex turn had no stored thread to resume")
            _ = await h.supervisor.accept(.compact(AgentCompactionRequest()), for: id)
            try await h.settle(id)
            let expected = "developer_instructions=\"" + userCodexTOML + firstRulesTOML + "\""
            let launches = h.launches(cli: "codex", owner: id)
            try expect(launches.count == 3, "expected first, resumed and compaction launches, saw \(launches.count)")
            try expect(h.frames(owner: id).contains { $0["method"] as? String == "thread/resume" }, "no resumed Codex thread")
            try expect(h.frames(owner: id).contains { $0["method"] as? String == "thread/compact/start" }, "no Codex compaction")
            for (index, argv) in launches.enumerated() {
                try expect(argv.filter { $0.hasPrefix("developer_instructions=") } == [expected],
                           "Codex launch \(index + 1) argv \(argv.filter { $0.contains("developer_instructions") })")
            }
            try Data("Edited rules for Codex".utf8).write(to: rules)
            try await h.turn("PLAIN after edit", id)
            let edited = h.launches(cli: "codex", owner: id).last ?? []
            try expect(edited.filter { $0.hasPrefix("developer_instructions=") } ==
                       ["developer_instructions=\"" + userCodexTOML + "Personal working rules:\\nEdited rules for Codex\""],
                       "Codex launch after the edit did not carry the edited file")
        }

        // 2. Pi RPC: an idle runner is reused (no relaunch, so the session keeps
        //    the rules it was launched with); after the idle runner is reaped the
        //    next launch reads the edited file; a restored agent's compaction
        //    launch carries the rules too.
        await scenario("pi lifecycle") {
            try Data(firstRules.utf8).write(to: rules)
            let h = try Harness(root: root, name: "pi", instructions: instructions([on]), idle: 2)
            defer { h.tearDown() }
            let id = h.spawn(.pi)
            try await h.turn("PLAIN one", id)
            try await h.turn("PLAIN two", id)
            try expect(h.launches(cli: "pi", owner: id).count == 1, "the idle Pi runner was not reused")
            try Data("Edited rules for Pi".utf8).write(to: rules)
            try await Task.sleep(for: .milliseconds(2600))
            try await h.turn("PLAIN three", id)
            var launches = h.launches(cli: "pi", owner: id)
            try expect(launches.count == 2, "the reaped Pi runner did not relaunch, saw \(launches.count)")
            try expect(appended(launches[0]) == ["Personal working rules:\n" + firstRules], "first Pi launch: \(appended(launches[0]))")
            try expect(appended(launches[1]) == ["Personal working rules:\nEdited rules for Pi"], "Pi launch after the edit: \(appended(launches[1]))")
            let restored = try h.restart()
            _ = await restored.accept(.compact(AgentCompactionRequest()), for: id)
            try await h.settle(id)
            launches = h.launches(cli: "pi", owner: id)
            try expect(launches.count == 3 && h.frames(owner: id).contains { $0["type"] as? String == "compact" },
                       "restored Pi compaction did not launch, saw \(launches.count)")
            try expect(appended(launches[2]) == ["Personal working rules:\nEdited rules for Pi"], "Pi compaction launch: \(appended(launches[2]))")
        }

        // 3. A real retryOf, for a Pi and a Codex helper: the failed helper and
        //    its retry both launch with the rules.
        await scenario("retryOf") {
            try Data("Retry rules".utf8).write(to: rules)
            let h = try Harness(root: root, name: "retry", instructions: instructions([on]))
            defer { h.tearDown() }
            let parent = h.spawn(.pi)
            for (harness, cli) in [(AgentHarness.pi, "pi"), (.codex, "codex")] {
                let selection = AgentLaunchSelection(harness: harness, model: Harness.model(harness), thinking: "low")
                guard let failed = h.supervisor.handleSpawnRequest(
                    SpawnRequest(role: nil, prompt: "CRASH helper", isolated: false), from: parent, childSelection: selection) else {
                    throw Failure(description: "\(cli) helper spawn refused")
                }
                try await h.eventually("\(cli) helper did not fail") { h.supervisor.mayRetry(failed, from: parent) }
                guard let retry = h.supervisor.handleSpawnRequest(
                    SpawnRequest(role: nil, prompt: "PLAIN retry", isolated: false), from: parent, childSelection: selection,
                    retryOf: failed, originalBrief: "PLAIN retry") else {
                    throw Failure(description: "\(cli) retry refused")
                }
                try expect(h.supervisor.records[retry]?.delegationContext?.retryOf == failed, "\(cli) retry lost retryOf")
                try await h.eventually("\(cli) retry did not launch") { !h.launches(cli: cli, owner: retry).isEmpty }
                for id in [failed, retry] {
                    let argv = h.launches(cli: cli, owner: id).first ?? []
                    let ok = harness == .pi
                        ? appended(argv) == ["Personal working rules:\nRetry rules"]
                        : argv.filter { $0.hasPrefix("developer_instructions=") }
                            == ["developer_instructions=\"" + userCodexTOML + "Personal working rules:\\nRetry rules\""]
                    try expect(ok, "\(cli) \(id == retry ? "retry" : "failed helper") launched without the rules: \(argv)")
                }
            }
        }

        // 4. A launch with no earlier read at all: the source and supervisor exist
        //    before the file does; the first launch must still carry it.
        await scenario("first launch") {
            let late = root.appendingPathComponent("late-rules.txt")
            let fresh = PersonalRulesSource { late.path }
            let h = try Harness(root: root, name: "first", instructions: instructions([fresh]))
            defer { h.tearDown() }
            let id = h.spawn(.pi)
            try Data("Late rules".utf8).write(to: late)
            try await h.turn("PLAIN now", id)
            try expect(appended(h.launches(cli: "pi", owner: id).first ?? []) == ["Personal working rules:\nLate rules"],
                       "the first launch went without the rules")
            try expect(fresh.lastOutcome == .loaded(words: 2), "outcome after the first launch: \(String(describing: fresh.lastOutcome))")
        }

        // 5. Claude parity, on and off; Codex and Pi off. Each launch's argv must
        //    equal the base launch's element by element.
        await scenario("parity") {
            try Data(firstRules.utf8).write(to: rules)
            for harness in [AgentHarness.claudeCode, .codex, .pi] {
                let variants: [(String, HostLaunchInstructions)] = harness == .claudeCode
                    ? [("on", instructions([on])), ("off", instructions([off]))]
                    : [("off", instructions([off]))]
                let base = try await firstLaunch(harness, root: root, instructions: instructions([]))
                try expect(!base.isEmpty, "\(harness) base did not launch")
                for (name, variant) in variants {
                    let argv = try await firstLaunch(harness, root: root, instructions: variant)
                    try expect(argv == base, "\(harness) \(name) argv differs from base:\n\(argv)\nvs\n\(base)")
                }
            }
        }

        // 6. A user Codex setting Array cannot read with confidence: no host
        //    text for that launch (argv equals base) and the reason is recorded.
        await scenario("unreadable codex setting") {
            try Data(firstRules.utf8).write(to: rules)
            let profiled = root.appendingPathComponent("codex-profiled", isDirectory: true)
            try fm.createDirectory(at: profiled, withIntermediateDirectories: true)
            try Data("[profiles.work]\ndeveloper_instructions = \"theirs\"\n".utf8).write(to: profiled.appendingPathComponent("config.toml"))
            let guarded = instructions([on], home: profiled)
            let argv = try await firstLaunch(.codex, root: root, instructions: guarded)
            let base = try await firstLaunch(.codex, root: root, instructions: instructions([]))
            try expect(argv == base, "Codex launch replaced an unreadable user setting: \(argv)")
            try expect(guarded.codexNote.value?.contains("cannot read") == true, "no reason recorded: \(String(describing: guarded.codexNote.value))")
        }

        // 7. The user's own Codex setting, read-only, in each form.
        await scenario("codex config reader") {
            let cases: [(String, CodexUserInstructions)] = [
                ("model = \"x\"\n", .none),
                ("developer_instructions = \"a\\tb \\\"q\\\" \\u00e9\" # note\n", .text("a\tb \"q\" é")),
                ("developer_instructions = 'C:\\raw'\n", .text("C:\\raw")),
                ("developer_instructions = '''\nline one\nline two'''\n", .text("line one\nline two")),
                ("notify = \"\"\"\n[not a table]\n\"\"\"\ndeveloper_instructions = \"after\"\n", .text("after")),
                ("[profiles.p]\ndeveloper_instructions = \"x\"\n", .unknown("")),
                ("profiles.p.developer_instructions = \"x\"\n", .unknown("")),
                ("developer_instructions = \"\"\"\nline \\\n  joined\"\"\"\n", .unknown("")),
                ("developer_instructions = \"x\"\ndeveloper_instructions = \"y\"\n", .unknown("")),
                ("developer_instructions = 3\n", .unknown("")),
            ]
            for (index, (text, want)) in cases.enumerated() {
                let got = CodexUserInstructions.parse(text)
                let same: Bool
                switch (got, want) {
                case (.unknown, .unknown): same = true
                default: same = got == want
                }
                try expect(same, "reader case \(index): got \(got)")
            }
            let project = root.appendingPathComponent("project/sub", isDirectory: true)
            try fm.createDirectory(at: project.deletingLastPathComponent().appendingPathComponent(".codex"), withIntermediateDirectories: true)
            try fm.createDirectory(at: project, withIntermediateDirectories: true)
            try Data("developer_instructions = \"project\"\n".utf8)
                .write(to: project.deletingLastPathComponent().appendingPathComponent(".codex/config.toml"))
            if case .unknown = CodexUserInstructions.read(codexHome: codexHome.path, cwd: project, environment: [:], homeDirectory: root) {} else {
                throw Failure(description: "a project Codex layer's key was ignored")
            }
            try expect(CodexUserInstructions.read(codexHome: root.appendingPathComponent("none").path, cwd: root, environment: [:], homeDirectory: root) == .none,
                       "a missing Codex config is not .none")
        }

        // 8. The seam: a fixture second block keeps its own identity and lands
        //    after the personal block in ONE option per harness, at launch.
        await scenario("second block") {
            try Data("Seam rules".utf8).write(to: rules)
            let second = FixtureSource(block: HostLaunchInstructionBlock(name: "fixture-second", label: "Fixture second", text: "two / \"quoted\""))
            let h = try Harness(root: root, name: "seam", instructions: instructions([on, second, on, second]))
            defer { h.tearDown() }
            let pi = h.spawn(.pi), codex = h.spawn(.codex)
            try await h.turn("PLAIN seam", pi)
            try await h.turn("PLAIN seam", codex)
            let joined = "Personal working rules:\nSeam rules\n\nFixture second:\ntwo / \"quoted\""
            try expect(appended(h.launches(cli: "pi", owner: pi).first ?? []) == [joined], "Pi seam order or count")
            try expect((h.launches(cli: "codex", owner: codex).first ?? []).filter { $0.hasPrefix("developer_instructions=") }
                       == ["developer_instructions=\"" + userCodexTOML + #"Personal working rules:\nSeam rules\n\nFixture second:\ntwo / \"quoted\""# + "\""],
                       "Codex seam order or count")
            try expect(second.resolveBlock()?.text == "two / \"quoted\"", "rendering changed a source")
        }

        // 9. Outcomes kept as readable state, and the status shown by the switch.
        await scenario("outcomes") {
            func outcome(_ name: String, _ data: Data?) -> HostInstructionOutcome? {
                let file = root.appendingPathComponent(name)
                if let data { try? data.write(to: file) }
                let source = PersonalRulesSource { file.path }
                _ = source.resolveBlock()
                return source.lastOutcome
            }
            try expect(outcome("absent", nil) == .missing, "missing")
            try expect(outcome("blank", Data(" \n\t".utf8)) == .empty, "empty")
            try expect(outcome("big", Data(repeating: 65, count: PersonalRulesSource.byteLimit + 1)) == .tooLarge, "too large")
            try expect(outcome("latin", Data([0xC3, 0x28])) == .invalidText, "invalid UTF-8")
            try expect(outcome("nul", Data("a\0b".utf8)) == .invalidText, "NUL")
            try expect(outcome("ok", Data("one two three".utf8)) == .loaded(words: 3), "loaded")
            let locked = root.appendingPathComponent("locked")
            try Data("secret".utf8).write(to: locked)
            try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
            let lockedSource = PersonalRulesSource { locked.path }
            _ = lockedSource.resolveBlock()
            try expect(lockedSource.lastOutcome == .unreadable, "unreadable: \(String(describing: lockedSource.lastOutcome))")
            try expect(PersonalRulesToggleRow.status(source: lockedSource, instructions: instructions([lockedSource]))
                        == HostInstructionOutcome.unreadable.summary, "switch status does not show the outcome")
            try expect(PersonalRulesToggleRow.status(source: off, instructions: instructions([off])).hasPrefix("Not read yet"),
                       "switch status before any launch")
        }

        try expect(try Data(contentsOf: codexHome.appendingPathComponent("config.toml")) == codexConfigBefore, "the Codex config was changed")
        try expect(try fm.contentsOfDirectory(atPath: codexHome.path) == ["config.toml"], "a file was written in the Codex home")
        if !failures.isEmpty { throw Failure(description: failures.joined(separator: "\n")) }
        print("Personal rules checks passed: production launches for Codex (first, resumed, compaction, edited) and Pi RPC (reuse, reaped relaunch, edited, restored compaction), retryOf for both, first launch with no earlier read, Claude parity on/off, Codex and Pi off parity, the user's Codex setting joined or left alone, TOML escaping, a fixture second block, outcomes and the switch status")
    }

    // MARK: - Helpers

    /// Every `--append-system-prompt` value in a Pi argv.
    static func appended(_ argv: [String]) -> [String] {
        argv.indices.filter { argv[$0] == "--append-system-prompt" && $0 + 1 < argv.count }.map { argv[$0 + 1] }
    }

    /// The first launch of a fresh agent, with its own id and root normalised.
    static func firstLaunch(_ harness: AgentHarness, root: URL, instructions: HostLaunchInstructions) async throws -> [String] {
        let h = try Harness(root: root, name: "parity-\(UUID().uuidString)", instructions: instructions)
        defer { h.tearDown() }
        let id = h.spawn(harness)
        try await h.turn("PLAIN parity", id)
        let cli = harness == .claudeCode ? "claude" : harness == .codex ? "codex" : "pi"
        let raw = id.rawValue.uuidString
        return (h.launches(cli: cli, owner: id).first ?? []).map {
            $0.replacingOccurrences(of: raw, with: "<id>").replacingOccurrences(of: raw.lowercased(), with: "<id>")
                .replacingOccurrences(of: h.work.path, with: "<work>")
        }
    }

    /// The steering fakes, plus a per-spawn argv log naming the owning agent, a
    /// resumable Codex thread, and compaction replies for Codex and Pi.
    static func installFakes(in bin: URL) throws {
        for harness in [AgentSteeringQAFakes.Harness.claude, .codex, .pi] {
            let file = try AgentSteeringQAFakes.install(harness, in: bin)
            var source = try String(contentsOf: file, encoding: .utf8)
            func patch(_ old: String, _ new: String) throws {
                guard source.contains(old) else { throw Failure(description: "fake \(harness) changed: \(old)") }
                source = source.replacingOccurrences(of: old, with: new)
            }
            try patch("    json.dump(sys.argv[1:], f)\n", """
                    json.dump(sys.argv[1:], f)
                with open(os.path.join(HERE, "launches.jsonl"), "a") as f:
                    f.write(json.dumps({"cli": os.path.basename(__file__), "owner": os.environ.get(\(String(reflecting: AgentProcessAttribution.ownerEnvironmentKey)), ""), "argv": sys.argv[1:]}) + "\\n")
                def record(line):
                    with open(os.path.join(HERE, "stdin.jsonl"), "a") as f:
                        f.write(json.dumps({"owner": os.environ.get(\(String(reflecting: AgentProcessAttribution.ownerEnvironmentKey)), ""), "frame": json.loads(line)}) + "\\n")

                """)
            try patch("def record(line):\n    with open(os.path.join(HERE, \"stdin.jsonl\"), \"a\") as f:\n        f.write(line.rstrip(\"\\n\") + \"\\n\")\n", "")
            switch harness {
            case .codex:
                try patch("    elif method == \"turn/interrupt\":", """
                    elif method == "thread/resume":
                        reply(obj, {"thread": {"id": params.get("threadId") or THREAD}})
                    elif method == "thread/compact/start":
                        reply(obj, {})
                        item = {"type": "contextCompaction", "id": "compaction-1"}
                        out({"method": "item/started", "params": {"threadId": params.get("threadId"), "turnId": "compact-turn", "item": item}})
                        out({"method": "item/completed", "params": {"threadId": params.get("threadId"), "turnId": "compact-turn", "item": item}})
                        out({"method": "turn/completed", "params": {"threadId": params.get("threadId"), "turn": {"id": "compact-turn", "status": "completed"}}})
                    elif method == "turn/interrupt":
                """)
            case .pi:
                try patch("    elif kind == \"get_commands\":", """
                    elif kind == "compact":
                        respond(obj, data={})
                        out({"type": "compaction_start", "reason": "manual"})
                        out({"type": "compaction_end", "result": {"tokensBefore": 1000, "estimatedTokensAfter": 100, "firstKeptEntryId": "e1"}, "aborted": False})
                    elif kind == "get_commands":
                """)
            case .claude: break
            }
            try source.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    @MainActor
    final class Harness {
        let root: URL
        let work: URL
        let bin: URL
        let instructions: HostLaunchInstructions
        let idle: TimeInterval
        var supervisor: AgentSupervisor

        static func model(_ harness: AgentHarness) -> String {
            harness == .claudeCode ? "anthropic/claude-haiku-4-5-20251001" : "openai-codex/gpt-5.6-sol"
        }

        init(root base: URL, name: String, instructions: HostLaunchInstructions, idle: TimeInterval = AgentSupervisor.defaultIdleRunnerTimeout) throws {
            bin = base.appendingPathComponent("bin", isDirectory: true)
            root = base.appendingPathComponent("run-\(name)", isDirectory: true)
            work = root.appendingPathComponent("work", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            self.instructions = instructions
            self.idle = idle
            supervisor = Self.supervisor(root: root, instructions: instructions, idle: idle)
        }

        static func supervisor(root: URL, instructions: HostLaunchInstructions, idle: TimeInterval) -> AgentSupervisor {
            AgentSupervisor(
                store: AgentStore(applicationSupportDirectory: root),
                makeRunner: { AgentSupervisor.productionRunner(for: $0, hostInstructions: instructions) },
                submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: root, debounceInterval: 0),
                idleRunnerTimeout: idle)
        }

        /// Stops everything and restores the agents into a new supervisor.
        func restart() throws -> AgentSupervisor {
            supervisor.stopAll()
            supervisor = Self.supervisor(root: root, instructions: instructions, idle: idle)
            supervisor.restore()
            return supervisor
        }

        func spawn(_ harness: AgentHarness) -> AgentID {
            supervisor.spawn(role: nil, prompt: nil, cwd: work, harness: harness, model: Self.model(harness), thinking: "low")
        }

        func eventually(_ message: String, timeout: TimeInterval = 15, _ condition: @MainActor () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw Failure(description: message)
        }

        func settle(_ id: AgentID) async throws {
            try await Task.sleep(for: .milliseconds(100))
            try await eventually("agent did not settle") { !self.supervisor.isRunning(id) }
        }

        func turn(_ text: String, _ id: AgentID) async throws {
            try PersonalRulesChecks.expect(supervisor.send(text, to: id), "send refused: \(text)")
            try await eventually("turn did not start: \(text)") {
                self.frames(owner: id).contains { ($0["message"] as? String ?? "").contains(text)
                    || "\(($0["params"] as? [String: Any])?["input"] ?? "")".contains(text)
                    || "\(($0["message"] as? [String: Any])?["content"] ?? "")".contains(text) }
            }
            try await settle(id)
        }

        func launches(cli: String, owner: AgentID) -> [[String]] {
            lines("launches.jsonl").filter { $0["cli"] as? String == cli && $0["owner"] as? String == AgentProcessAttribution.ownerTag(for: owner) }
                .compactMap { $0["argv"] as? [String] }
        }

        func frames(owner: AgentID) -> [[String: Any]] {
            lines("stdin.jsonl").filter { $0["owner"] as? String == AgentProcessAttribution.ownerTag(for: owner) }
                .compactMap { $0["frame"] as? [String: Any] }
        }

        private func lines(_ name: String) -> [[String: Any]] {
            guard let text = try? String(contentsOf: bin.appendingPathComponent(name), encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        }

        func tearDown() { supervisor.stopAll() }
    }
}

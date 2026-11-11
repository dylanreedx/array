import Foundation
import ContinuumRevivedCore

/// Array's reply rules (`ReplyStandard`) reach every Array-run agent through the
/// PRODUCTION launch path: the supervisor, `productionRunner`, the real runners
/// and a real spawn of fake CLIs that log each argv with its owning agent (the
/// personal-rules harness). Claude, Codex and Pi; solo, lead and helper; first,
/// resumed, retried, compaction and idle-reuse launches. Every file and setting
/// lives in a temporary directory or an isolated suite this check creates.
@MainActor
enum ReplyRulesChecks {
    typealias Harness = PersonalRulesChecks.Harness
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ value: Bool, _ message: @autoclosure () -> String) throws {
        if !value { throw Failure(description: "reply rules: " + message()) }
    }

    /// The rules as they travel inside Codex's TOML basic string, written
    /// without the encoder: the text has no control or backslash characters, so
    /// only its quotes change.
    static let textTOML = ReplyStandard.text.replacingOccurrences(of: "\"", with: #"\""#)
    static let personalText = "Personal rule: use type(area) subjects."

    enum Shape: CaseIterable, CustomStringConvertible {
        case claudeTools, claudeBare, codex, pi
        var harness: AgentHarness { self == .codex ? .codex : self == .pi ? .pi : .claudeCode }
        var cli: String { self == .codex ? "codex" : self == .pi ? "pi" : "claude" }
        var description: String {
            switch self {
            case .claudeTools: return "Claude with workspace tools"
            case .claudeBare: return "Claude without workspace tools"
            case .codex: return "Codex"
            case .pi: return "Pi"
            }
        }
    }

    static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("array-reply-rules-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        defer { setenv("PATH", originalPath, 1) }
        try PersonalRulesChecks.installFakes(in: bin)
        setenv("PATH", "\(bin.path):\(originalPath)", 1)

        let rules = root.appendingPathComponent("rules.txt")
        try Data(personalText.utf8).write(to: rules)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        try fm.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try Data(PersonalRulesChecks.userCodexConfig.utf8).write(to: codexHome.appendingPathComponent("config.toml"))
        let workspace = WorkspaceMCPConfiguration(serverExecutable: "/fixture/server", endpoint: "http://localhost/fixture",
                                                  agentID: "fixture", token: "fixture", directory: root)

        // Both switches through their real keys, in isolated suites.
        var suites: [QAIsolatedDefaults] = []
        defer { for d in suites { d.removePersistentDomain(forName: d.suiteDomainName) } }
        func suite(reply: Bool, personal: Bool) throws -> String {
            let name = "array.qa.reply-rules.\(UUID().uuidString)"
            guard let defaults = QAIsolatedDefaults(isolatedSuiteName: name) else { throw Failure(description: "no isolated suite") }
            defaults.setPersistentDomain([ReplyStandard.enabledKey: reply, PersonalRulesConfig.enabledKey: personal,
                                          PersonalRulesConfig.pathKey: rules.path], forName: name)
            suites.append(defaults)
            return name
        }
        func instructions(_ name: String) -> HostLaunchInstructions {
            var value = HostLaunchInstructions.production(
                reply: ReplyStandardSource { QAIsolatedDefaults(isolatedSuiteName: name).map { ReplyStandard.isEnabled(defaults: $0) } ?? false },
                personal: PersonalRulesSource { QAIsolatedDefaults(isolatedSuiteName: name).flatMap { PersonalRulesConfig.selectedPath(defaults: $0) } })
            value.codexUserInstructions = { _, cwd in
                CodexUserInstructions.read(codexHome: codexHome.path, cwd: cwd, environment: [:], homeDirectory: root)
            }
            return value
        }
        let replyOnly = instructions(try suite(reply: true, personal: false))
        let both = instructions(try suite(reply: true, personal: true))
        let off = instructions(try suite(reply: false, personal: false))
        var base = HostLaunchInstructions(sources: [])
        base.codexUserInstructions = off.codexUserInstructions

        func harness(_ shape: Shape, _ name: String, _ instructions: HostLaunchInstructions, idle: TimeInterval = AgentSupervisor.defaultIdleRunnerTimeout) throws -> Harness {
            try Harness(root: root, name: "\(name)-\(shape.cli)-\(UUID().uuidString)", instructions: instructions, idle: idle,
                        workspaceMCP: shape == .claudeTools ? workspace : nil)
        }

        var failures: [String] = []
        func scenario(_ name: String, _ body: () async throws -> Void) async {
            let started = Date()
            fputs("reply rules: \(name)…\n", stderr)
            do { try await body() } catch { failures.append("\(name): \(error)") }
            fputs("reply rules: \(name) done in \(Int(Date().timeIntervalSince(started)))s\n", stderr)
        }

        // 0. The switch is off by default, sits beside the personal-rules switch,
        //    and a check run never reads the user's own setting.
        await scenario("switch") {
            let name = try suite(reply: false, personal: false)
            guard let empty = QAIsolatedDefaults(isolatedSuiteName: name) else { throw Failure(description: "no isolated suite") }
            empty.removeObject(forKey: ReplyStandard.enabledKey)
            try expect(!ReplyStandard.isEnabled(defaults: empty), "on with no setting")
            let groups = SettingsSchema.sections().flatMap(\.groups)
            guard let index = groups.firstIndex(where: { group in group.rows.contains { row in
                if case let .toggle(key, _, isOn) = row.field { return key == ReplyStandard.enabledKey && !isOn }
                return false
            } }) else {
                throw Failure(description: "no Settings switch defaulting to off")
            }
            try expect(groups.indices.contains(index + 1) && groups[index + 1].id == "agents.personalRules",
                       "the switch is not beside the personal-rules switch")
            guard let on = QAIsolatedDefaults(isolatedSuiteName: try suite(reply: true, personal: false)) else { throw Failure(description: "no isolated suite") }
            try expect(ReplyStandard.isEnabled(defaults: on), "the isolated suite did not switch it on")
            try expect(!ReplyStandardSource.productionEnabled(defaults: on), "a check run would read the user's setting")
        }

        // 1. A solo agent's lifecycle. Claude and Pi: first launch, a turn on the
        //    idle runner (no relaunch), a relaunch after it is reaped (Claude
        //    resumes), and a restored agent's compaction launch. Codex: first,
        //    resumed and compaction launches.
        for shape in Shape.allCases {
            await scenario("solo \(shape)") {
                let h = try harness(shape, "solo", replyOnly, idle: 2)
                defer { h.tearDown() }
                let id = h.spawn(shape.harness)
                try await h.turn("PLAIN one", id)
                try await h.turn("PLAIN two", id)
                if shape == .codex {
                    try expect(h.frames(owner: id).contains { $0["method"] as? String == "thread/resume" }, "no resumed Codex thread")
                } else {
                    try expect(h.launches(cli: shape.cli, owner: id).count == 1, "the idle runner was not reused")
                    try await Task.sleep(for: .milliseconds(2600))
                    try await h.turn("PLAIN three", id)
                    let launches = h.launches(cli: shape.cli, owner: id)
                    try expect(launches.count == 2, "the reaped runner did not relaunch, saw \(launches.count)")
                    if shape.harness == .claudeCode { try expect(launches[1].contains("--resume"), "the relaunch did not resume") }
                }
                let compacting = try shape == .codex ? h.supervisor : h.restart()
                _ = await compacting.accept(.compact(AgentCompactionRequest()), for: id)
                try await h.settle(id)
                try expect(h.frames(owner: id).contains { frame in
                    frame["method"] as? String == "thread/compact/start" || frame["type"] as? String == "compact"
                        || "\((frame["message"] as? [String: Any])?["content"] ?? "")".contains("/compact")
                }, "no compaction reached the CLI")
                let launches = h.launches(cli: shape.cli, owner: id)
                try expect(launches.count == 3, "expected three launches, saw \(launches.count)")
                for (index, argv) in launches.enumerated() { try verify(argv, shape, "launch \(index + 1)") }
            }
        }

        // 2. A lead: the same agent in Managed mode.
        for shape in Shape.allCases {
            await scenario("lead \(shape)") {
                let h = try harness(shape, "lead", replyOnly)
                defer { h.tearDown() }
                let id = h.spawn(shape.harness)
                try expect(h.supervisor.setMode(.managed, for: id), "Managed mode refused")
                try await h.turn("PLAIN lead", id)
                try expect(h.supervisor.records[id]?.mode == .managed, "not a lead")
                try verify(h.launches(cli: shape.cli, owner: id).first ?? [], shape, "lead launch")
            }
        }

        // 3. A helper and a real retryOf: the failed helper and its retry both
        //    launch with the rules.
        for shape in Shape.allCases {
            await scenario("helper and retry \(shape)") {
                let h = try harness(shape, "helper", replyOnly)
                defer { h.tearDown() }
                let parent = h.spawn(.pi)
                let selection = AgentLaunchSelection(harness: shape.harness, model: Harness.model(shape.harness), thinking: "low")
                guard let failed = h.supervisor.handleSpawnRequest(
                    SpawnRequest(role: nil, prompt: "CRASH helper", isolated: false), from: parent, childSelection: selection) else {
                    throw Failure(description: "helper spawn refused")
                }
                try expect(h.supervisor.records[failed]?.parentAgentID == parent, "not a helper")
                try await h.eventually("helper did not fail") { h.supervisor.mayRetry(failed, from: parent) }
                guard let retry = h.supervisor.handleSpawnRequest(
                    SpawnRequest(role: nil, prompt: "PLAIN retry", isolated: false), from: parent, childSelection: selection,
                    retryOf: failed, originalBrief: "PLAIN retry") else {
                    throw Failure(description: "retry refused")
                }
                try expect(h.supervisor.records[retry]?.delegationContext?.retryOf == failed, "retry lost retryOf")
                try await h.eventually("retry did not launch") { !h.launches(cli: shape.cli, owner: retry).isEmpty }
                for (label, id) in [("failed helper", failed), ("retry", retry)] {
                    let launches = h.launches(cli: shape.cli, owner: id)
                    try expect(!launches.isEmpty, "\(label) never launched")
                    for argv in launches { try verify(argv, shape, label) }
                }
            }
        }

        // 4. Both switches on: Array's block, then the personal block, each
        //    intact, in one option; the user's own Codex text still first.
        //    Claude never gets the personal block.
        for shape in Shape.allCases {
            await scenario("both blocks \(shape)") {
                let h = try harness(shape, "both", both)
                defer { h.tearDown() }
                let id = h.spawn(shape.harness)
                try await h.turn("PLAIN both", id)
                try verify(h.launches(cli: shape.cli, owner: id).first ?? [], shape, "both on", personal: shape.harness != .claudeCode)
            }
        }

        // 5. The switch is read at launch: the session process exits on its
        //    own (EXITIDLE), the switch is turned off, and the next launch (a
        //    new runner, since the supervisor keeps a Claude runner only while
        //    its process lives) goes without.
        await scenario("claude switch per launch") {
            let name = try suite(reply: true, personal: false)
            let h = try harness(.claudeBare, "toggle", instructions(name))
            defer { h.tearDown() }
            let id = h.spawn(.claudeCode)
            try await h.turn("EXITIDLE on", id)
            QAIsolatedDefaults(isolatedSuiteName: name)?.setPersistentDomain(
                [ReplyStandard.enabledKey: false], forName: name)
            try await Task.sleep(for: .milliseconds(800))
            try await h.turn("PLAIN off", id)
            let launches = h.launches(cli: "claude", owner: id)
            try expect(launches.count == 2, "expected two launches, saw \(launches.count)")
            try verify(launches[0], .claudeBare, "launch while on")
            try expect(PersonalRulesChecks.appended(launches[1]).isEmpty, "the launch after switching off still carried it")
        }

        // 5b. Claude's resume self-heal: the runner's `--resume` launch fails
        //     and the same runner relaunches with `--session-id`. Both carry it.
        await scenario("claude resume self-heal") {
            let h = try harness(.claudeBare, "selfheal", replyOnly)
            defer { h.tearDown() }
            let id = h.spawn(.claudeCode)
            try await h.turn("EXITIDLE first", id)
            let reject = bin.appendingPathComponent("reject-resume")
            try Data().write(to: reject)
            defer { try? fm.removeItem(at: reject) }
            try await Task.sleep(for: .milliseconds(800))
            try await h.turn("PLAIN healed", id)
            let launches = h.launches(cli: "claude", owner: id)
            try expect(launches.count == 3 && launches[1].contains("--resume") && launches[2].contains("--session-id"),
                       "expected first, a rejected resume and a fresh relaunch, saw \(launches.map { $0.filter { $0.hasPrefix("--resume") || $0.hasPrefix("--session-id") } })")
            for (index, argv) in launches.enumerated() { try verify(argv, .claudeBare, "launch \(index + 1)") }
        }

        // 5c. The two Codex launches that get no host text record why, and the
        //     reply-rules switch shows it: a user Codex setting Array cannot
        //     read, and instruction text already in the launch's arguments that
        //     cannot be decoded.
        await scenario("codex no-text cases") {
            let profiled = root.appendingPathComponent("codex-profiled", isDirectory: true)
            try fm.createDirectory(at: profiled, withIntermediateDirectories: true)
            try Data("[profiles.work]\ndeveloper_instructions = \"theirs\"\n".utf8).write(to: profiled.appendingPathComponent("config.toml"))
            var unreadable = instructions(try suite(reply: true, personal: false))
            unreadable.codexUserInstructions = { _, cwd in
                CodexUserInstructions.read(codexHome: profiled.path, cwd: cwd, environment: [:], homeDirectory: root)
            }
            let h = try harness(.codex, "notext", unreadable)
            defer { h.tearDown() }
            let id = h.spawn(.codex)
            try await h.turn("PLAIN unreadable", id)
            let argv = h.launches(cli: "codex", owner: id).first ?? []
            try expect(!argv.isEmpty && !argv.contains { $0.contains("developer_instructions") }, "an unreadable user setting was replaced: \(argv)")
            try expect(ReplyRulesToggleRow.status(instructions: unreadable)?.contains("cannot read") == true,
                       "unreadable setting: switch status \(String(describing: ReplyRulesToggleRow.status(instructions: unreadable)))")

            let undecodable = instructions(try suite(reply: true, personal: false))
            guard let record = h.supervisor.records[id] else { throw Failure(description: "no Codex record") }
            var config = AgentSupervisor.codexRunnerConfig(for: record, hostInstructions: undecodable)
            config.extraArgs = ["-c", "developer_instructions=not a TOML string"]
            try expect(config.resolvedExtraArgs() == config.extraArgs, "undecodable instructions were replaced")
            try expect(ReplyRulesToggleRow.status(instructions: undecodable)?.contains("could not be read") == true,
                       "undecodable instructions: switch status \(String(describing: ReplyRulesToggleRow.status(instructions: undecodable)))")
            config.extraArgs = []
            try expect(config.resolvedExtraArgs().contains { $0.hasPrefix("developer_instructions=") }
                       && ReplyRulesToggleRow.status(instructions: undecodable) == nil, "a good launch did not clear the reason")
        }

        // 6. Both switches off: every launch argv equals the base (no host
        //    sources at all) element by element, solo and lead.
        for shape in Shape.allCases {
            await scenario("off parity \(shape)") {
                for managed in [false, true] {
                    let expected = try await firstLaunch(shape, managed: managed, harness: { try harness(shape, "base", base) })
                    try expect(!expected.isEmpty, "base did not launch")
                    let argv = try await firstLaunch(shape, managed: managed, harness: { try harness(shape, "off", off) })
                    try expect(argv == expected, "\(managed ? "lead" : "solo") argv differs from base:\n\(argv)\nvs\n\(expected)")
                }
            }
        }

        if !failures.isEmpty { throw Failure(description: failures.joined(separator: "\n")) }
        print("Reply rules checks passed (\(ReplyStandard.wordCount) words): default off beside personal rules; once per launch on Claude with and without workspace tools, Codex and Pi, for solo (first, idle reuse, resumed, compaction), lead, helper and retryOf; joined in one option, Array's block before the personal one and after the user's own Codex text; read at each launch, including Claude's resume self-heal; both off equals the base argv")
    }

    // MARK: - Helpers

    /// The block is intact, in the one option its harness reads, exactly once.
    static func verify(_ argv: [String], _ shape: Shape, _ what: String, personal: Bool = false) throws {
        let label = "\(shape) \(what)"
        try expect(!argv.isEmpty, "\(label): no launch")
        switch shape {
        case .claudeTools:
            try expect(PersonalRulesChecks.appended(argv) == [WorkspaceMCPConfiguration.agentGuidance + "\n\n" + ReplyStandard.block],
                       "\(label): one --append-system-prompt with the guidance then the block, got \(PersonalRulesChecks.appended(argv))")
        case .claudeBare:
            try expect(PersonalRulesChecks.appended(argv) == [ReplyStandard.block],
                       "\(label): one --append-system-prompt with the block, got \(PersonalRulesChecks.appended(argv))")
        case .pi:
            let tail = personal ? "\n\nPersonal working rules:\n" + personalText : ""
            try expect(PersonalRulesChecks.appended(argv) == [ReplyStandard.block + tail],
                       "\(label): one --append-system-prompt, got \(PersonalRulesChecks.appended(argv))")
        case .codex:
            let tail = personal ? #"\n\nPersonal working rules:\n"# + personalText : ""
            let expected = "developer_instructions=\"" + PersonalRulesChecks.userCodexTOML + ReplyStandard.label + #":\n"# + textTOML + tail + "\""
            let got = argv.filter { $0.hasPrefix("developer_instructions=") }
            try expect(got == [expected], "\(label): one developer_instructions, user text first, got \(got)")
        }
        let needle = shape == .codex ? textTOML : ReplyStandard.text
        let count = argv.map { $0.components(separatedBy: needle).count - 1 }.reduce(0, +)
        try expect(count == 1, "\(label): the block appears \(count) times")
    }

    /// The first launch of a fresh agent, with its own id and root normalised.
    static func firstLaunch(_ shape: Shape, managed: Bool, harness make: () throws -> Harness) async throws -> [String] {
        let h = try make()
        defer { h.tearDown() }
        let id = h.spawn(shape.harness)
        if managed { try expect(h.supervisor.setMode(.managed, for: id), "Managed mode refused") }
        try await h.turn("PLAIN parity", id)
        let raw = id.rawValue.uuidString
        return (h.launches(cli: shape.cli, owner: id).first ?? []).map {
            $0.replacingOccurrences(of: raw, with: "<id>").replacingOccurrences(of: raw.lowercased(), with: "<id>")
                .replacingOccurrences(of: h.work.path, with: "<work>")
        }
    }
}

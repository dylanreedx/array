import Foundation
import ContinuumRevivedCore

@MainActor
enum PersonalRulesChecks {
    static func run() async throws {
        func expect(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "PersonalRulesChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rules.txt")
        let text = "Use type(area): imperative subjects. Never push unless told. Never add AI attribution."
        try Data(text.utf8).write(to: file)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        func source(_ path: String, enabled: Bool = true) async -> PersonalRulesSource {
            let s = PersonalRulesSource(environment: ["CONTINUUM_PERSONAL_RULES_ENABLED": enabled ? "1" : "0", "CONTINUUM_PERSONAL_RULES_FILE": path])
            for _ in 0..<500 where s.status == "loading" { try? await Task.sleep(for: .milliseconds(10)) }
            return s
        }
        let on = await source(file.path)
        let off = await source(file.path, enabled: false)
        var record = AgentRecord(id: AgentID(rawValue: UUID()), displayName: "fixture", model: "fixture/model", thinking: "medium", cwd: root.path, createdAt: Date(timeIntervalSince1970: 0), lastActivityAt: Date(timeIntervalSince1970: 0))
        for thread in [nil, "resumed-fixture"] as [String?] {
            record.codexThreadId = thread
            let codex = AgentSupervisor.codexRunnerConfig(for: record, personalRules: on)
            let baseline = AgentSupervisor.codexRunnerConfig(for: record, personalRules: off)
            for mode in [CodexCLIBackend.SessionMode.fresh, .resume] {
                let args = CodexCLIBackend.processArguments(model: codex.model, effort: codex.effort, sessionMode: mode, threadId: thread, cwdPath: root.path, extraArgs: codex.extraArgs, prompt: AgentPrompt("fixture task"))
                try expect(args.filter { $0.contains(text) }.count == 1, "Codex rules not delivered once")
            }
            try expect(baseline.extraArgs.isEmpty, "off changed Codex")
            let pi = AgentSupervisor.runnerConfig(for: record, spawnDepth: 1, personalRules: on)
            let args = PiAgentRunner.processArguments(model: pi.model, thinking: pi.thinking, sessionId: pi.sessionId, extraArgs: pi.extraArgs, prompt: "fixture task", extensionPaths: [])
            try expect(args.filter { $0.contains(text) }.count == 1, "Pi rules not delivered once")
            try expect(AgentSupervisor.runnerConfig(for: record, spawnDepth: 1, personalRules: off).extraArgs.isEmpty, "off changed Pi")
        }
        let rpc = AgentSupervisor.runnerConfig(for: record, spawnDepth: 1, personalRules: on)
        let rpcArgs = PiRpcAgentRunner.processArguments(model: rpc.model, thinking: rpc.thinking, sessionId: rpc.sessionId, extraArgs: rpc.extraArgs, extensionPaths: [])
        try expect(rpcArgs.filter { $0.contains(text) }.count == 1, "Pi RPC rules not delivered once")
        let server = AgentSupervisor.codexRunnerConfig(for: record, personalRules: on)
        try expect(CodexCLIBackend.appServerArguments(extraArgs: server.extraArgs).filter { $0.contains(text) }.count == 1, "Codex app-server rules not delivered once")
        var observed: [AgentHarness: [Int]] = [:]
        try await runWorkspaceAPIDelegationChecks(crossHarness: true, inspectLaunch: { launch in
            guard launch.record.parentAgentID != nil, let harness = launch.record.harness else { return }
            let args: [String]
            switch harness {
            case .codex:
                args = CodexCLIBackend.appServerArguments(extraArgs: AgentSupervisor.codexRunnerConfig(for: launch.record, personalRules: on).extraArgs)
            case .pi:
                let c = AgentSupervisor.runnerConfig(for: launch.record, spawnDepth: launch.spawnDepth, personalRules: on)
                args = PiRpcAgentRunner.processArguments(model: c.model, thinking: c.thinking, sessionId: c.sessionId, extraArgs: c.extraArgs, extensionPaths: [])
            case .claudeCode:
                // Claude never consumes this source; its existing frozen-argv witness guards parity.
                args = []
            }
            observed[harness, default: []].append(args.filter { $0.contains(text) }.count)
        })
        for harness in [AgentHarness.codex, .pi, .claudeCode] {
            try expect(!(observed[harness] ?? []).isEmpty, "API did not launch fixture helper")
            try expect(observed[harness]!.allSatisfy { $0 == (harness == .claudeCode ? 0 : 1) }, "API helper rules count changed")
        }
        let missing = await source(root.appendingPathComponent("absent").path)
        try expect(missing.status == "unavailable" && missing.arguments(codex: true).isEmpty, "missing must continue")
        try Data(repeating: 65, count: PersonalRulesSource.byteLimit + 1).write(to: root.appendingPathComponent("large"))
        let large = await source(root.appendingPathComponent("large").path)
        try expect(large.status == "oversized" && large.arguments(codex: false).isEmpty, "oversize silently truncated")
        try expect(try Data(contentsOf: file) == Data(text.utf8), "source changed")
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        try expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date, "source metadata changed")
        print("Personal rules checks passed: production config and argv, Codex fresh/resume, Pi, default off, missing, oversized, source unchanged")
    }
}

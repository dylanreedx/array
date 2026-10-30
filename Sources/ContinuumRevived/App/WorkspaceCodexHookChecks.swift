import AppKit
import ContinuumRevivedCore
import Foundation

@MainActor
enum WorkspaceCodexHookChecks {
    static func run() throws {
        let bench = try WorkspaceAgentReportChecks.makeBench(label: "codex-hook")
        defer { bench.tearDown() }
        let supervisor = bench.supervisor
        let parent = bench.f.agentId
        let child = try bench.delegate("CODEX-HOOK-CHILD")
        AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .codex, readiness: .ready,
            models: [WorkspaceAgentReportChecks.model]))
        for id in [parent, child] {
            try WorkspaceAgentReportChecks.expect(supervisor.setProviderSettings(agentID: id, harness: .codex), "fixture must own Codex records")
        }
        let config = try bench.configuration(for: child)
        let parentConfig = try bench.configuration(for: parent)
        let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("scripts/fixtures/codex-hook-cli.py")
        let codex = bench.binDir.appendingPathComponent("codex")
        try FileManager.default.copyItem(at: fixture, to: codex)
        let oldTransport = ProcessInfo.processInfo.environment["CONTINUUM_CODEX_TRANSPORT"]
        setenv("CONTINUUM_CODEX_TRANSPORT", "app-server", 1)
        defer {
            if let oldTransport { setenv("CONTINUUM_CODEX_TRANSPORT", oldTransport, 1) } else { unsetenv("CONTINUUM_CODEX_TRANSPORT") }
        }
        final class Completion: @unchecked Sendable {
            let lock = NSLock(); var done = false; var error: String?
        }
        let completion = Completion()
        let runner = CodexAgentRunner(config: .init(model: "fixture", cwd: bench.binDir, workspaceMCP: config))
        DispatchQueue.global().async {
            var failure: String?
            do { try runner.run(prompt: "scripted Codex turn") { _ in } } catch { failure = String(describing: error) }
            completion.lock.withLock { completion.error = failure; completion.done = true }
        }
        let deadline = Date().addingTimeInterval(30)
        while !completion.lock.withLock({ completion.done }), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        defer { runner.stop() }
        try WorkspaceAgentReportChecks.expect(completion.lock.withLock { completion.done && completion.error == nil },
            "scripted Codex runner failed: \(completion.lock.withLock { completion.error } ?? "timeout")")
        let receipts = supervisor.hookReceipts[child] ?? []
        try WorkspaceAgentReportChecks.expect(receipts.map(\.event) == WorkspaceAgentHook.codexEvents,
            "real runner hook commands did not reach host ring: \(receipts)")
        try WorkspaceAgentReportChecks.expect(receipts.allSatisfy { $0.harness == .codex && $0.sessionID == "fixture-session" }, "host must assign harness and retain session")
        try WorkspaceAgentReportChecks.expect(supervisor.hookReceipts[parent] == nil, "child hooks leaked onto parent")

        func body(_ event: String = "Stop", turn: String = "t1", native: String = "native", active: Bool = false, words: Int = 451) throws -> String {
            var payload: [String: Any] = ["session_id": "codex-session", "turn_id": turn,
                "hook_event_name": event, "stop_hook_active": active,
                "last_assistant_message": WorkspaceAgentReportChecks.words(words), "model": "fixture", "permission_mode": "never",
                "cwd": "/tmp/fixture", "transcript_path": "/tmp/fixture-rollout"]
            if event == "SubagentStop" { payload["agent_id"] = native; payload["agent_type"] = "default" }
            return String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        }
        func invoke(_ config: WorkspaceMCPConfiguration, _ body: String, endpoint: String? = nil, marker: Bool = true) throws -> [String: Any]? {
            let result = try WorkspaceHookBridgeChecks.runHook(bench.helper, endpoint: endpoint ?? config.endpoint,
                agentID: config.agentID, tokenFile: config.tokenFilePath, body: body, marker: marker)
            try WorkspaceAgentReportChecks.expect(result.status == 0, "hook must always exit zero")
            if result.stdout.isEmpty { return nil }
            return try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        }
        func silent(_ output: [String: Any]?, _ label: String) throws {
            try WorkspaceAgentReportChecks.expect(output == nil, "\(label) must be silent: \(String(describing: output))")
        }
        func blocked(_ output: [String: Any]?, _ label: String) throws {
            try WorkspaceAgentReportChecks.expect(output?["decision"] as? String == "block" && output?["reason"] as? String != nil,
                "\(label) needs Codex's block/reason: \(String(describing: output))")
        }
        try silent(try invoke(config, body()), "setting off")
        bench.settings.set(true, forKey: AgentShortReportConfig.enabledKey)
        try silent(try invoke(config, body(active: true)), "stop_hook_active before any reservation")
        try silent(try invoke(config, body(words: 450)), "450-word boundary")
        try blocked(try invoke(config, body()), "451-word child Stop")
        try silent(try invoke(config, body()), "host once-per-turn, even if CLI omits active flag")
        try silent(try invoke(config, body(active: true)), "continuation")
        try blocked(try invoke(config, body(turn: "t2")), "new turn")
        try silent(try invoke(parentConfig, body(turn: "t2")), "top-level Stop")
        try blocked(try invoke(parentConfig, body("SubagentStop")), "native child")
        try silent(try invoke(parentConfig, body("SubagentStop")), "native duplicate")
        try blocked(try invoke(parentConfig, body("SubagentStop", native: "other-native")), "independent native child")
        try silent(try invoke(config, body(turn: "t3"), marker: false), "no Array marker")
        let down = "http://127.0.0.1:\(try WorkspaceHookBridgeChecks.unusedLoopbackPort())/workspace-mcp"
        try silent(try invoke(config, body(turn: "t3"), endpoint: down), "endpoint down")
        bench.settings.set(false, forKey: AgentShortReportConfig.enabledKey)
        try silent(try invoke(config, body(turn: "t3")), "setting switched off")
        print("Codex host hook checks passed: seven real binary receipts, authenticated harness, block once per turn/child, active/off/boundary/no-marker/down silence")
    }
}

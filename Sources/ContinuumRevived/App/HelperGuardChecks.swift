import AppKit
import ContinuumRevivedCore

@MainActor
enum HelperGuardChecks {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        try WorkspaceAgentReportChecks.expect(condition(), message)
    }

    static func hook(_ bench: WorkspaceAgentReportChecks.Bench, _ id: AgentID,
                     tool: String, command: String? = nil, exit: Int? = nil, interrupted: Bool = false) throws {
        let config = try bench.configuration(for: id)
        var payload: [String: Any] = ["hook_event_name": "PostToolUse", "tool_name": tool]
        if let command { payload["tool_input"] = ["command": command] }
        var response: [String: Any] = ["stdout": "", "stderr": "", "interrupted": interrupted]
        if let exit { response["exit_code"] = exit }
        payload["tool_response"] = response
        let body = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let result = try WorkspaceHookBridgeChecks.runHook(bench.helper, endpoint: config.endpoint, agentID: config.agentID,
                                                         tokenFile: config.tokenFilePath, body: body, marker: true)
        try expect(result.status == 0, "hook command failed")
        WorkspaceHookBridgeChecks.drainMain()
    }

    static func runCommandEvidence() async throws {
        let bench = try WorkspaceAgentReportChecks.makeBench(label: "helper-command-evidence")
        defer { bench.tearDown() }
        let supervisor = bench.supervisor
        let parentConfig = try bench.configuration(for: bench.f.agentId)
        let cases: [(String, AgentCommandEvidence.Outcome)] = [
            ("fresh", .observed), ("stale", .stale), ("failed", .observedFailed),
            ("absent", .notObserved), ("unknown", .notObserved), ("shell-edit", .stale),
            ("masked", .notObserved), ("codex", .observed), ("interrupted", .notObserved)]
        for (name, expected) in cases {
            let child = try bench.delegate("HOLD-\(name)")
            let ready = await waitUntil(timeout: 10, pollInterval: 0.02) { supervisor.isRunning(child) }
            try expect(ready, "child did not start")
            try hook(bench, child, tool: "Edit")
            if name != "absent" {
                try hook(bench, child, tool: name == "codex" ? "functions.exec_command" : "Bash",
                         command: name == "masked" ? "swift test || true" : "swift test",
                         exit: name == "unknown" ? nil : (name == "failed" ? 1 : 0), interrupted: name == "interrupted")
            }
            if name == "stale" { try hook(bench, child, tool: "Write") }
            if name == "shell-edit" { try hook(bench, child, tool: "Bash", command: "echo fix > source.swift", exit: 0) }
            let config = try bench.configuration(for: child)
            let filed = try await WorkspaceAgentReportChecks.call(config, "array_report", [
                "summary": "Finished", "checks": [["what": "swift test", "result": "pass"]]])
            try expect(!filed.isError, "report was refused")
            let evidence = supervisor.records[child]?.lastReport?.report.commandEvidence
            try expect(evidence?.count == 1 && evidence?.first?.outcome == expected, "\(name): wrong stored evidence \(String(describing: evidence))")
            for observation in evidence ?? [] {
                try expect(observation.detail.hasPrefix("Array saw") && !observation.detail.contains("verified")
                    && !observation.detail.contains("proof"), "stored command evidence overclaims")
            }
            let stored = try AgentStore(smokeTest: false).loadAll().first { $0.id == child }
            try expect(stored?.lastReport == supervisor.records[child]?.lastReport, "evidence did not persist")
            try Data().write(to: URL(fileURLWithPath: supervisor.records[child]!.cwd).appendingPathComponent("release.flag"))
            let settled = await waitUntil(timeout: 15, pollInterval: 0.02) { !supervisor.isRunning(child) }
            try expect(settled, "child did not settle")
            let handle = supervisor.records[child]!.spawnResultHandle!
            let waited = try await WorkspaceAgentReportChecks.call(parentConfig, "wait_agents", ["handles": [handle], "timeoutSeconds": 2])
            let entries = (waited.reply["result"] as? [String: Any])?["agents"] as? [[String: Any]]
            let report = entries?.first?["report"] as? [String: Any]
            try expect(report != nil, "wait_agents lost the report")
            let flags = report?["commandEvidence"] as? [[String: Any]]
            if expected == .observed {
                try expect(flags == nil, "observed evidence must not add context to wait_agents")
            } else {
                try expect(flags?.count == 1 && flags?.first?["outcome"] as? String == expected.rawValue, "\(name): wait_agents lost the flag")
                let text = flags?.first?["detail"] as? String ?? ""
                try expect(text.hasPrefix("Array saw") && !text.contains("verified") && !text.contains("proof") && text.split(separator: " ").count < 25,
                           "command wording is too strong or too long")
            }
        }
        let report = AgentReport(summary: "Root", checks: [.init(what: "swift test", result: .pass)])
        try expect(supervisor.fileReport(report, for: bench.f.agentId), "root report refused")
        try expect(supervisor.records[bench.f.agentId]?.lastReport?.report == report, "root agent was changed")
    }
}

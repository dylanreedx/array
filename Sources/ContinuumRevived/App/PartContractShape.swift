import AppKit
import ContinuumRevivedCore
import Foundation

/// What a delegation WITHOUT a contract produces, for Claude and Codex helpers:
/// the CLI argv, the first prompt the CLI received, the helper record's keys,
/// its delegation context and its name. Runtime ids, ports and temporary or
/// build paths are replaced by placeholders so two runs compare exactly.
///
/// Uses only APIs that predate contracts, so the same file builds at the base
/// commit: `scripts/fixtures/part-contract-omitted-shape.json` was captured
/// there, and `--part-contract-check` compares today's shape with it.
@MainActor
enum PartContractShape {
    static func capture() async throws -> [String: Any] {
        let b = try HelperRetryWorktreeChecks.bench("part-contract-shape"); defer { b.tearDown() }
        // The fakes hold any prompt containing HOLD; keep the lead's name neutral.
        _ = b.supervisor.rename(agentID: b.f.agentId, to: "Lead")
        let fixture = try String(contentsOf: URL(fileURLWithPath: "scripts/fixtures/codex-hook-cli.py"), encoding: .utf8)
            .replacingOccurrences(of: "    elif method == 'turn/start':\n", with: "    elif method == 'turn/start':\n        record(dict(kind='turn', session=session_id, request=message))\n")
        let codex = b.binDir.appendingPathComponent("codex")
        try fixture.write(to: codex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
        AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .codex, readiness: .ready, models: [ManagedCodexChecks.model]))
        let restore = ManagedCodexChecks.runEnvironment(b); defer { restore() }

        func delegate(_ harness: String, _ model: String) async throws -> AgentID {
            try HelperRetryWorktreeChecks.child(await WorkspaceAgentReportChecks.call(b.configuration(for: b.f.agentId), "array_delegate", [
                "task": "part O", "harness": harness, "model": model, "idempotencyKey": UUID().uuidString]))
        }
        func settle(_ id: AgentID) async throws {
            try await AgentPresenceChecks.eventually("shape helper did not settle", timeout: 20) {
                !b.supervisor.isRunning(id) && b.supervisor.records[id]?.latestTerminalEvent != nil
            }
        }
        func text(_ value: Any) -> [String] {
            switch value {
            case let s as String: return [s]
            case let a as [Any]: return a.flatMap(text)
            case let d as [String: Any]: return d.keys.sorted().flatMap { text(d[$0]!) }
            default: return []
            }
        }
        func shape(_ id: AgentID, argv: [String], prompt: String) throws -> [String: Any] {
            let record = b.supervisor.records[id]!
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let keys = (try JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any])?.keys.sorted() ?? []
            let context = String(decoding: try encoder.encode(record.delegationContext), as: UTF8.self)
            return ["argv": argv.map(normalize), "prompt": normalize(prompt), "recordKeys": keys,
                    "delegationContext": normalize(context), "displayName": normalize(record.humanDisplayName)]
        }

        let claude = try await delegate("Claude Code", ManagedModeChecks.model)
        let claudeCapture = try await HelperRetryWorktreeChecks.capture(b, claude)
        try await settle(claude)
        let codexChild = try await delegate("Codex", ManagedCodexChecks.model)
        try await settle(codexChild)
        let launch = ManagedCodexChecks.rows(b, kind: "launch").first {
            ($0["argv"] as? [String])?.contains { $0.contains(codexChild.rawValue.uuidString) } == true
        }
        guard let launch, let session = launch["session"] as? String,
              let turn = ManagedCodexChecks.rows(b, kind: "turn", session: session).first else {
            throw WorkspaceAgentReportChecks.Failure(description: "part-contract shape: the Codex helper's launch and first turn were not recorded")
        }
        let input = ((turn["request"] as? [String: Any])?["params"] as? [String: Any])?["input"] ?? []
        return [
            "claude": try shape(claude, argv: claudeCapture["argv"] as? [String] ?? [], prompt: text(claudeCapture["prompt"] ?? "").joined(separator: "\n")),
            "codex": try shape(codexChild, argv: launch["argv"] as? [String] ?? [], prompt: text(input).joined(separator: "\n")),
        ]
    }

    static func normalize(_ value: String) -> String {
        var text = value
        let temp = FileManager.default.temporaryDirectory.path
        for (path, name) in [(Bundle.main.executablePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? "", "<bin>"),
                             (FileManager.default.currentDirectoryPath, "<repo>"), ("/private" + temp, "<tmp>"), (temp, "<tmp>")]
        where !path.isEmpty {
            text = text.replacingOccurrences(of: path, with: name)
            text = text.replacingOccurrences(of: path.replacingOccurrences(of: "/", with: "\\/"), with: name)
        }
        for (pattern, name) in [("[0-9A-Fa-f]{8}[-_][0-9A-Fa-f]{4}[-_][0-9A-Fa-f]{4}[-_][0-9A-Fa-f]{4}[-_][0-9A-Fa-f]{12}", "<uuid>"),
                                ("127\\.0\\.0\\.1:[0-9]+", "127.0.0.1:<port>"), ("<tmp>/*", "<tmp>/"),
                                // Codex hook trust hashes cover the per-run endpoint and ids above.
                                ("sha256:[0-9a-f]{64}", "sha256:<hash>")] {
            text = text.replacingOccurrences(of: pattern, with: name, options: .regularExpression)
        }
        return text
    }
}

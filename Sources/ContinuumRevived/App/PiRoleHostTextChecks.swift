import Foundation
import ContinuumRevivedCore

/// Production role resolution, spawn, runner factory and RPC transport; only
/// the CLI is doubled. Observes delivery, not CLI-loaded project/role content
/// or model obedience. All authored files belong to the disposable fixture.
@MainActor
enum PiRoleHostTextChecks {
    typealias Harness = PersonalRulesChecks.Harness
    static func run(root: URL, instructions: HostLaunchInstructions, expected: [String], label: String) async throws -> [[String]] {
        AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .pi, readiness: .ready, models: [Harness.model(.pi)]))
        let h = try Harness(root: root, name: "pi-role-\(label)", instructions: instructions)
        defer { h.tearDown() }
        let role = "host-context-role"
        let directory = h.work.appendingPathComponent(".pi/agents", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let roleFile = directory.appendingPathComponent("\(role).md")
        let roleText = "---\nname: \(role)\nmodel: \(Harness.model(.pi))\nreasoning: low\ntools: read, bash\n---\nROLE-CONTEXT remains project-owned.\n"
        let projectFile = h.work.appendingPathComponent("AGENTS.md")
        let projectText = "PROJECT-CONTEXT remains project-owned.\n"
        try roleText.write(to: roleFile, atomically: true, encoding: .utf8)
        try projectText.write(to: projectFile, atomically: true, encoding: .utf8)
        let parent = h.spawn(.pi)
        _ = h.supervisor.rename(agentID: parent, to: "Context lead")
        let selection = AgentLaunchSelection(harness: .pi, model: Harness.model(.pi), thinking: "low")
        func spawn(_ task: String, retry: AgentID? = nil) throws -> AgentID {
            guard let child = h.supervisor.handleSpawnRequest(
                SpawnRequest(role: role, prompt: task, isolated: false), from: parent,
                childSelection: selection, retryOf: retry, originalBrief: task) else {
                throw ReplyRulesChecks.Failure(description: "Pi role \(label): spawn refused")
            }
            return child
        }
        func containsTask(_ task: String, _ id: AgentID) -> Bool {
            h.frames(owner: id).contains { ($0["message"] as? String ?? "").contains(task) }
        }
        func expect(_ value: Bool, _ why: String) throws {
            try ReplyRulesChecks.expect(value, "Pi role \(label): \(why)")
        }
        let firstTask = "PLAIN role-context first"
        let child = try spawn(firstTask)
        try await h.eventually("role first task not delivered") { containsTask(firstTask, child) }
        try await h.settle(child)
        try expect(h.launches(cli: "pi", owner: child).count == 1, "first launch missing")
        _ = try h.restart()
        try await h.turn("PLAIN role-context resumed", child)
        let resumed = h.launches(cli: "pi", owner: child)
        func option(_ argv: [String], _ name: String) -> String? {
            guard let i = argv.firstIndex(of: name), argv.indices.contains(i + 1) else { return nil }
            return argv[i + 1]
        }
        try expect(resumed.count == 2 && option(resumed[0], "--session-id") != nil
                   && option(resumed[0], "--session-id") == option(resumed[1], "--session-id"), "restore lost session continuity")
        // Compact the RUNNING RPC session, rather than only inspecting a
        // restored compaction launch. The fake emits production-shaped events.
        _ = await h.supervisor.accept(.compact(AgentCompactionRequest()), for: child)
        try await h.settle(child)
        try expect(h.frames(owner: child).filter { $0["type"] as? String == "compact" }.count == 1,
                   "compaction did not reach the role session")
        try await h.turn("PLAIN role-context after compact", child)
        try expect(h.launches(cli: "pi", owner: child).count == 2, "compaction replaced the live session")
        _ = try h.restart()
        try await h.turn("PLAIN role-context restored after compact", child)
        try expect(h.launches(cli: "pi", owner: child).count == 3, "post-compaction restore did not relaunch")

        let failed = try spawn("CRASH role-context helper")
        try await h.eventually("role crash task not delivered") { containsTask("CRASH role-context helper", failed) }
        try await h.eventually("role helper did not become retryable") { h.supervisor.mayRetry(failed, from: parent) }
        let retried = try spawn("PLAIN role-context retry", retry: failed)
        try await h.eventually("role retry task not delivered") { containsTask("PLAIN role-context retry", retried) }
        try await h.settle(retried)
        try expect(h.supervisor.records[retried]?.delegationContext?.retryOf == failed, "retry lineage lost")

        var result: [[String]] = []
        for id in [child, failed, retried] {
            guard let record = h.supervisor.records[id] else { throw ReplyRulesChecks.Failure(description: "missing role record") }
            try expect(record.role == role && record.harness == .pi && record.parentAgentID == parent
                       && record.model == Harness.model(.pi) && record.thinking == "low"
                       && URL(fileURLWithPath: record.checkoutRoot).standardizedFileURL == h.work.standardizedFileURL,
                       "role, harness, project, parent or provider settings changed")
            let launches = h.launches(cli: "pi", owner: id)
            try expect(!launches.isEmpty, "role helper never launched")
            let log = try String(contentsOf: h.bin.appendingPathComponent("launches.jsonl"), encoding: .utf8)
            let rows = log.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
                .filter { $0["owner"] as? String == AgentProcessAttribution.ownerTag(for: id) && $0["cli"] as? String == "pi" }
            try expect(rows.count == launches.count && rows.allSatisfy { row in
                (row["cwd"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() == h.work.resolvingSymlinksInPath() } ?? false
            }, "actual process cwd lost the project")
            for argv in launches {
                try expect(PersonalRulesChecks.appended(argv) == expected, "role host text missing, duplicated or reordered: \(PersonalRulesChecks.appended(argv))")
                let tools = Set((option(argv, "--tools") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                try expect(tools.contains("read") && tools.contains("bash") && tools.contains("array_workspace_context")
                           && tools.contains("array_report"), "role tools or Array bridge tools lost")
                try expect(option(argv, "--model") == Harness.model(.pi) && option(argv, "--thinking") == "low", "launch provider selection changed")
                result.append(argv.map {
                    $0.replacingOccurrences(of: h.root.path, with: "<run>")
                        .replacingOccurrences(of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", with: "<id>", options: .regularExpression)
                })
            }
        }
        try expect(result.count == 5, "expected first, resume, post-compact restore, failure and retry launches")
        try expect(try String(contentsOf: roleFile, encoding: .utf8) == roleText
                   && String(contentsOf: projectFile, encoding: .utf8) == projectText, "project or role file was rewritten")
        return result
    }
}

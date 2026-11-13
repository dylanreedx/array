import AppKit
import ContinuumRevivedCore

/// Real delegation -> persisted child -> production Pi RPC process, offline.
@MainActor
enum HelperContextDietChecks {
    static func writeFailures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diet-write-failure-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = QAIsolatedDefaults(isolatedSuiteName: "diet-write-failure." + UUID().uuidString)!
        defer { defaults.removePersistentDomain(forName: defaults.suiteDomainName) }
        defaults.set(true, forKey: HelperContextDiet.enabledKey)
        AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .pi, readiness: .ready,
            models: [WorkspaceAgentReportChecks.model]))
        let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("support"))
        var runnerStarts = 0, rejected = 0
        let supervisor = AgentSupervisor(store: store,
            makeRunner: { _ in runnerStarts += 1; return ScriptedAgentRunner(script: []) },
            upsertRecord: { record in
                if record.parentAgentID != nil && record.delegationContext?.contextDietRequested == true {
                    rejected += 1
                    throw WorkspaceAgentReportChecks.Failure(description: "injected policy write failure")
                }
                try store.upsert(record)
            })
        defer { supervisor.stopAll() }
        supervisor.configureManagedMode(defaults: defaults)
        let parent = supervisor.spawn(role: nil, prompt: nil, cwd: root, harness: .pi,
            model: WorkspaceAgentReportChecks.model, thinking: "high")
        let child = supervisor.handleSpawnRequest(SpawnRequest(role: nil, prompt: "NEVER-RUN-POLICY", isolated: false), from: parent)
        try WorkspaceAgentReportChecks.expect(rejected == 1, "failure injection must reach actual policy persistence")
        try WorkspaceAgentReportChecks.expect(child == nil, "failed policy write must refuse delegation, never report a child")
        try WorkspaceAgentReportChecks.expect(runnerStarts == 0 && supervisor.records.count == 1, "refused allocation must launch and publish nothing")
        let durable = try store.loadAll()
        let durableParent = try store.load(id: parent)
        try WorkspaceAgentReportChecks.expect(durable.count == 1 && durableParent?.nextChildOrdinal == 1, "failed atomic claim must retain only parent and its ordinal")
    }

    static func run() async throws {
        try writeFailures()
        if ProcessInfo.processInfo.environment["CONTINUUM_DIET_WRITE_FAILURE_ONLY"] == "1" { return }
        let b = try WorkspaceAgentReportChecks.makeBench(label: "helper-diet")
        defer { b.tearDown() }
        let key = "agents.helpers.contextDiet"
        let script = WorkspaceAgentReportChecks.fakePi.replacingOccurrences(
            of: "import json, os, sys, threading, time",
            with: "import json, os, sys, threading, time\nwith open('diet-launches.jsonl', 'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')")
        let compactScript = script.replacingOccurrences(of: "    else:\n        emit", with:
            "    elif kind == \"compact\":\n        emit({\"type\":\"compaction_start\"})\n        emit({\"type\":\"response\",\"id\":cmd.get(\"id\"),\"command\":\"compact\",\"success\":True,\"data\":{}})\n        emit({\"type\":\"compaction_end\",\"result\":{\"summary\":\"synthetic compact\"}})\n    else:\n        emit")
        try compactScript.write(to: b.binDir.appendingPathComponent("pi"), atomically: true, encoding: .utf8)
        func args(_ id: AgentID) async throws -> [String] {
            let r = b.supervisor.records[id]!
            let session = AgentSupervisor.sessionId(for: id)
            let file = URL(fileURLWithPath: r.cwd).appendingPathComponent("diet-launches.jsonl")
            func captured() -> [String]? {
                guard let d = try? Data(contentsOf: file) else { return nil }
                return d.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String] }.last { $0.contains(session) }
            }
            try await AgentPresenceChecks.eventually("diet process did not launch", timeout: 15) { captured() != nil }
            return captured()!
        }
        let baseline = try b.delegate("diet-off")
        let off = try await args(baseline)
        try WorkspaceAgentReportChecks.expect(!off.contains("--no-skills"), "diet defaults off")
        b.settings.set(true, forKey: key)
        let firstReply = b.f.api.dispatch(agentId: b.f.agentId, requestId: "diet-on", op: "agent.delegate",
            payload: ["task": "diet-on", "title": "diet-on", "idempotencyKey": "diet-on",
                      "contract": ["decisions": ["KEEP-PROJECT-HAZARD"], "checks": ["offline-diet"]]])
        guard case .result(let firstResult) = firstReply,
              let firstRaw = firstResult["childAgentId"]?.string, let firstUUID = UUID(uuidString: firstRaw) else {
            throw WorkspaceAgentReportChecks.Failure(description: "diet delegation refused: \(firstReply)")
        }
        let child = AgentID(rawValue: firstUUID)
        let on = try await args(child)
        try WorkspaceAgentReportChecks.expect(on.contains("--no-skills"), "enabled helper must disable Pi automatic skill discovery")
        try WorkspaceAgentReportChecks.expect(!on.contains("--no-context-files") && !on.contains("--no-extensions"), "keep project rules and host tools")
        let r = b.supervisor.records[child]!
        let restored = try JSONDecoder().decode(AgentRecord.self, from: JSONEncoder().encode(r))
        b.settings.set(false, forKey: key)
        let config = AgentSupervisor.runnerConfig(for: restored, spawnDepth: 1)
        try WorkspaceAgentReportChecks.expect(config.resolvedExtraArgs().contains("--no-skills"), "restore retains child policy after default changes")
        let parentConfig = AgentSupervisor.runnerConfig(for: b.supervisor.records[b.f.agentId]!, spawnDepth: 0)
        try WorkspaceAgentReportChecks.expect(!parentConfig.resolvedExtraArgs().contains("--no-skills"), "lead unaffected")
        try WorkspaceAgentReportChecks.expect(restored.delegationContext?.brief.contains("diet-on") == true, "task brief retained")
        try WorkspaceAgentReportChecks.expect(HelperContextDiet.status(for: restored)?.personalMemoryExclusion == "unknown", "never claim memory exclusion")
        for harness in [AgentHarness.claudeCode, .codex] {
            var unsupported = restored
            unsupported.harness = harness
            try WorkspaceAgentReportChecks.expect(HelperContextDiet.status(for: unsupported)?.automaticSkillDiscovery == "unsupported"
                && HelperContextDiet.arguments(for: unsupported).isEmpty, "unsupported harness must not receive a speculative override")
        }
        try await AgentPresenceChecks.eventually("helper did not settle", timeout: 15) { !b.supervisor.isRunning(child) }
        try WorkspaceAgentReportChecks.expect(restored.delegationContext?.contract?.decisions == ["KEEP-PROJECT-HAZARD"], "contract retained")
        try WorkspaceAgentReportChecks.expect(b.supervisor.send("DIET-RETRY-HOLD", to: child), "resume refused")
        try await AgentPresenceChecks.eventually("resumed helper did not start", timeout: 15) { b.supervisor.isRunning(child) }
        b.supervisor.stop(child)
        let retryReply = b.f.api.dispatch(agentId: b.f.agentId, requestId: "diet-retry", op: "agent.delegate",
            payload: ["task": "diet-retry", "title": "diet-retry", "retryOf": child.rawValue.uuidString, "idempotencyKey": "diet-retry"])
        guard case .result(let result) = retryReply,
              let raw = result["childAgentId"]?.string, let uuid = UUID(uuidString: raw) else {
            throw WorkspaceAgentReportChecks.Failure(description: "retry refused: \(retryReply)")
        }
        let retried = AgentID(rawValue: uuid)
        let retryArgs = try await args(retried)
        try WorkspaceAgentReportChecks.expect(retryArgs.contains("--no-skills"), "retry inherits ON despite new default OFF")
        let inspect = b.f.api.dispatch(agentId: b.f.agentId, requestId: "diet-inspect", op: "agent.inspect", payload: ["agentId": child.rawValue.uuidString])
        guard case .result(let projection) = inspect else {
            throw WorkspaceAgentReportChecks.Failure(description: "diet inspect refused")
        }
        try WorkspaceAgentReportChecks.expect(projection["contextDiet"]?.object?["personalMemoryExclusion"]?.string == "unknown", "inspection must expose unknown memory exclusion")
        b.supervisor.stopAll()
        let runner = AgentSupervisor.productionRunner(for: AgentRunnerLaunch(record: restored, spawnDepth: 1))
        defer { runner.stop() }
        try await Task.detached {
            try runner.run(prompt: AgentPrompt("restored-task"), onEvent: { _ in })
            guard let compacting = runner as? AgentCompactionRunning else {
                throw WorkspaceAgentReportChecks.Failure(description: "restored production Pi runner cannot compact")
            }
            try compacting.compact(AgentCompactionRequest(), onEvent: { _ in })
            try runner.run(prompt: AgentPrompt("post-compact-task"), onEvent: { _ in })
        }.value
        let resumed = try await args(child)
        try WorkspaceAgentReportChecks.expect(resumed.contains("--no-skills"), "actual restored process retains discovery policy after compaction")
        print("helper-context-diet: real delegated Pi process; off/on, contract, project tools, restore/resume/compact/retry, unsupported scope and lead separation passed")
    }
}

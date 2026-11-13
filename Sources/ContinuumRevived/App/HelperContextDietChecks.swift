import AppKit
import ContinuumRevivedCore

private final class DietCleanupBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    func signal() { lock.withLock { finished = true } }
    var done: Bool { lock.withLock { finished } }
}

/// Real delegation -> persisted child -> production Pi RPC process, offline.
@MainActor
enum HelperContextDietChecks {
    private struct FixtureHostRules: HostLaunchInstructionSource {
        func resolveBlock() -> HostLaunchInstructionBlock? {
            HostLaunchInstructionBlock(name: "diet-witness", label: "Synthetic host rules", text: "KEEP-HOST-RULES")
        }
    }

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

    static func mcpWriteFailure(isolated: Bool = false) async throws {
        var rejected = 0, runnerStarts = 0
        var faultStore: AgentStore?
        let b = try WorkspaceAgentReportChecks.makeBench(label: "diet-mcp-write-failure-\(isolated)", configureDelegate: { delegate in
            let store = AgentStore(smokeTest: false)
            faultStore = store
            delegate.agentSupervisor = AgentSupervisor(store: store,
                makeRunner: { _ in runnerStarts += 1; return ScriptedAgentRunner(script: []) },
                upsertRecord: { record in
                    if record.parentAgentID != nil && record.delegationContext?.contextDietRequested == true {
                        rejected += 1
                        throw WorkspaceAgentReportChecks.Failure(description: "injected MCP snapshot write failure")
                    }
                    try store.upsert(record)
                })
        })
        defer { b.tearDown() }
        b.settings.set(true, forKey: HelperContextDiet.enabledKey)
        let repo = URL(fileURLWithPath: b.supervisor.records[b.f.agentId]!.checkoutRoot)
        var worktreesBefore = "", branchesBefore = ""
        if isolated {
            try HelperRetryWorktreeChecks.repository(repo)
            AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .claudeCode, readiness: .ready, models: [ManagedModeChecks.model]))
            try WorkspaceAgentReportChecks.expect(b.supervisor.setProviderSettings(agentID: b.f.agentId, harness: .claudeCode, model: ManagedModeChecks.model), "isolated fault lead harness refused")
            try WorkspaceAgentReportChecks.expect(b.supervisor.setMode(.managed, for: b.f.agentId), "isolated fault lead mode refused")
            b.settings.set(true, forKey: "agents.managedMode.isolateEveryHelper")
            worktreesBefore = try HelperRetryWorktreeChecks.git(repo, ["worktree", "list", "--porcelain"])
            branchesBefore = try HelperRetryWorktreeChecks.git(repo, ["for-each-ref", "--format=%(refname)", "refs/heads"])
        }
        let before = Set(b.supervisor.records.keys)
        let ordinal = b.supervisor.records[b.f.agentId]!.nextChildOrdinal
        let startedBefore = runnerStarts
        let reply = try await WorkspaceAgentReportChecks.call(b.configuration(for: b.f.agentId), "array_delegate",
            ["task": "MCP-POLICY-MUST-NOT-START", "title": "MCP failure", "harness": "Pi", "model": WorkspaceAgentReportChecks.model, "idempotencyKey": "diet-mcp-write-failure"])
        try WorkspaceAgentReportChecks.expect(rejected == 1, "MCP write-failure witness must reach the production writer")
        try WorkspaceAgentReportChecks.expect(reply.isError && WorkspaceAgentReportChecks.errorCode(reply) != nil,
            "MCP must return an error for failed policy persistence, never successful delegation: \(reply.reply)")
        try WorkspaceAgentReportChecks.expect((reply.reply["result"] as? [String: Any])?["childAgentId"] == nil,
            "MCP refusal must not publish a child id")
        try WorkspaceAgentReportChecks.expect(Set(b.supervisor.records.keys) == before && runnerStarts == startedBefore,
            "MCP refusal must create no child record or task runner")
        let durable = try faultStore!.loadAll()
        let parent = try faultStore!.load(id: b.f.agentId)
        try WorkspaceAgentReportChecks.expect(Set(durable.map(\.id)) == before && parent?.nextChildOrdinal == ordinal,
            "MCP refusal must retain durable records and ordinal")
        if isolated {
            try await AgentPresenceChecks.eventually("isolated failed allocation leaked prepared worktree or branch", timeout: 8) {
                (try? HelperRetryWorktreeChecks.git(repo, ["worktree", "list", "--porcelain"])) == worktreesBefore
                    && (try? HelperRetryWorktreeChecks.git(repo, ["for-each-ref", "--format=%(refname)", "refs/heads"])) == branchesBefore
            }
            let container = repo.appendingPathComponent(".worktrees")
            let remaining = (try? FileManager.default.contentsOfDirectory(atPath: container.path)) ?? []
            try WorkspaceAgentReportChecks.expect(remaining.isEmpty, "unowned prepared checkout directory must also be removed")
        }
        print("helper-context-diet MCP persistence refusal: actual MCP error, no child id, task, durable child or ordinal advance")
    }

    static func ownershipPreservation(_ mode: String) async throws {
        let barrier = DietCleanupBarrier()
        var captured: AgentRecord?
        var storage: AgentStore?
        var blockedDirectory: URL?
        var loopDirectory: URL?
        var savedDirectory: URL?
        let b = try WorkspaceAgentReportChecks.makeBench(label: "diet-owner-" + mode, configureDelegate: { delegate in
            let store = AgentStore(smokeTest: false)
            store.waitForBackupMigration()
            storage = store
            delegate.agentSupervisor = AgentSupervisor(store: store,
                makeRunner: { _ in ScriptedAgentRunner(script: []) },
                upsertRecord: { record in
                    if record.parentAgentID == nil {
                        if mode == "durable" && record.nextChildOrdinal > 1 {
                            throw WorkspaceAgentReportChecks.Failure(description: "injected parent high-water refusal")
                        }
                        try store.upsert(record); return
                    }
                    captured = record
                    let checkout = URL(fileURLWithPath: record.checkoutRoot)
                    try Data("CHECKOUT-OWNERSHIP-SENTINEL".utf8).write(to: checkout.appendingPathComponent("preserve.txt"))
                    if mode == "memory" { try store.upsert(record); return }
                    if mode == "durable" { try store.upsert(record); return }
                    if mode == "denied" || mode == "loop" || mode == "corrupt" { try store.upsert(record) }
                    if mode == "denied" {
                        blockedDirectory = store.layout.agentsDirectory
                        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.layout.agentsDirectory.path)
                    } else if mode == "loop" {
                        let original = store.layout.agentsDirectory
                        let saved = original.appendingPathExtension("saved")
                        try FileManager.default.moveItem(at: original, to: saved)
                        loopDirectory = original; savedDirectory = saved
                        try FileManager.default.createSymbolicLink(atPath: original.path, withDestinationPath: original.lastPathComponent)
                    } else if mode == "corrupt" {
                        try Data("CORRUPT-OWNER-SENTINEL".utf8).write(to: store.layout.agentFile(id: record.id))
                    } else if mode == "remove-failure" {
                        blockedDirectory = checkout.deletingLastPathComponent()
                        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blockedDirectory!.path)
                    }
                    throw WorkspaceAgentReportChecks.Failure(description: "injected ownership state: " + mode)
                })
            delegate.agentSupervisor.qaPreparedCheckoutCleanupFinished = { barrier.signal() }
        })
        defer { b.tearDown() }
        func restoreAccess() throws {
            if let blocked = blockedDirectory {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path)
                blockedDirectory = nil
            }
            if let original = loopDirectory, let saved = savedDirectory {
                try FileManager.default.removeItem(at: original)
                try FileManager.default.moveItem(at: saved, to: original)
                loopDirectory = nil; savedDirectory = nil
            }
        }
        defer { try? restoreAccess() }
        let repo = URL(fileURLWithPath: b.supervisor.records[b.f.agentId]!.checkoutRoot)
        try HelperRetryWorktreeChecks.repository(repo)
        let nested = repo.appendingPathComponent("unrelated-nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try HelperRetryWorktreeChecks.repository(nested)
        let nestedHead = try HelperRetryWorktreeChecks.git(nested, ["rev-parse", "HEAD"])
        AgentModelCatalog.shared.resetForQA(snapshot: .init(harness: .claudeCode, readiness: .ready, models: [ManagedModeChecks.model]))
        try WorkspaceAgentReportChecks.expect(b.supervisor.setProviderSettings(agentID: b.f.agentId, harness: .claudeCode, model: ManagedModeChecks.model), "ownership lead harness")
        try WorkspaceAgentReportChecks.expect(b.supervisor.setMode(.managed, for: b.f.agentId), "ownership lead mode")
        b.settings.set(true, forKey: HelperContextDiet.enabledKey)
        b.settings.set(true, forKey: "agents.managedMode.isolateEveryHelper")
        let reply = try await WorkspaceAgentReportChecks.call(b.configuration(for: b.f.agentId), "array_delegate",
            ["task": "OWNERSHIP-PRESERVATION", "title": "ownership", "harness": "Pi", "model": WorkspaceAgentReportChecks.model, "idempotencyKey": "owner-" + mode])
        try await AgentPresenceChecks.eventually("ownership cleanup barrier " + mode, timeout: 15) { barrier.done }
        guard let child = captured, let store = storage else { throw WorkspaceAgentReportChecks.Failure(description: "ownership fault not reached") }
        if mode == "denied" {
            try WorkspaceAgentReportChecks.expect(store.ownershipPresence(id: child.id) == .indeterminate(EACCES), "actual inaccessible store must report EACCES")
        } else if mode == "loop" {
            try WorkspaceAgentReportChecks.expect(store.ownershipPresence(id: child.id) == .indeterminate(ELOOP), "actual looping store must report ELOOP")
        } else if mode == "corrupt" || mode == "durable" || mode == "memory" {
            try WorkspaceAgentReportChecks.expect(store.ownershipPresence(id: child.id) == .present, "existing owner file must never count as absent")
        } else {
            try WorkspaceAgentReportChecks.expect(store.ownershipPresence(id: child.id) == .absent, "unwritten record must report ENOENT")
        }
        try restoreAccess()
        let checkout = URL(fileURLWithPath: child.checkoutRoot)
        let trees = try HelperRetryWorktreeChecks.git(repo, ["worktree", "list", "--porcelain"])
        let branches = try HelperRetryWorktreeChecks.git(repo, ["for-each-ref", "--format=%(refname)", "refs/heads"])
        if mode == "nested-absent" {
            try WorkspaceAgentReportChecks.expect(!FileManager.default.fileExists(atPath: checkout.path) && !trees.contains(checkout.path), "definitive ENOENT must retire only the prepared checkout")
            try WorkspaceAgentReportChecks.expect(!branches.contains(child.worktreeBranch ?? "UNEXPECTED"), "unowned branch must retire")
        } else {
            try WorkspaceAgentReportChecks.expect(FileManager.default.fileExists(atPath: checkout.appendingPathComponent("preserve.txt").path), "unknown or owned checkout must survive: " + mode)
            try WorkspaceAgentReportChecks.expect(trees.contains(checkout.path) && branches.contains(child.worktreeBranch ?? "UNEXPECTED"), "preserved/failed-removal checkout must retain registration and branch: " + mode)
        }
        if mode == "corrupt" {
            try WorkspaceAgentReportChecks.expect((try? Data(contentsOf: store.layout.agentFile(id: child.id))) == Data("CORRUPT-OWNER-SENTINEL".utf8), "corrupt owner bytes must remain unchanged")
        }
        let afterNestedHead = try HelperRetryWorktreeChecks.git(nested, ["rev-parse", "HEAD"])
        try WorkspaceAgentReportChecks.expect(afterNestedHead == nestedHead && FileManager.default.fileExists(atPath: nested.appendingPathComponent("tracked.txt").path), "unrelated nested repository must survive")
        try WorkspaceAgentReportChecks.expect(mode == "memory" ? !reply.isError : reply.isError, "ownership scenario must keep truthful MCP outcome: " + mode)
        print("helper diet ownership preservation passed: " + mode)
    }

    static func run() async throws {
        if let mode = ProcessInfo.processInfo.environment["CONTINUUM_DIET_OWNERSHIP_CASE"] {
            try await ownershipPreservation(mode); return
        }
        for mode in ["denied", "loop", "corrupt", "durable", "memory", "remove-failure", "nested-absent"] {
            try await ownershipPreservation(mode)
        }
        if ProcessInfo.processInfo.environment["CONTINUUM_DIET_MCP_ISOLATED_FAILURE_ONLY"] == "1" {
            try await mcpWriteFailure(isolated: true); return
        }
        if ProcessInfo.processInfo.environment["CONTINUUM_DIET_MCP_WRITE_FAILURE_ONLY"] == "1" {
            try await mcpWriteFailure(); return
        }
        try writeFailures()
        try await mcpWriteFailure()
        try await mcpWriteFailure(isolated: true)
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
        func hasWorkspaceExtension(_ args: [String]) -> Bool {
            args.indices.contains { i in args[i] == "-e" && i + 1 < args.count && args[i + 1].hasSuffix("/continuum-workspace-tools.ts") }
        }
        try WorkspaceAgentReportChecks.expect(hasWorkspaceExtension(off) && hasWorkspaceExtension(on), "actual baseline and diet processes must load workspace extension")
        let promptLog = URL(fileURLWithPath: b.supervisor.records[child]!.cwd).appendingPathComponent("prompts.log")
        try await AgentPresenceChecks.eventually("contract did not reach the actual helper prompt", timeout: 15) {
            (try? String(contentsOf: promptLog, encoding: .utf8))?.contains("KEEP-PROJECT-HAZARD") == true
        }
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
        try WorkspaceAgentReportChecks.expect(hasWorkspaceExtension(retryArgs), "retry process retains workspace extension")
        let runner = AgentSupervisor.productionRunner(for: AgentRunnerLaunch(record: restored, spawnDepth: 1),
            hostInstructions: HostLaunchInstructions(sources: [FixtureHostRules()]))
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
        try WorkspaceAgentReportChecks.expect(hasWorkspaceExtension(resumed) && resumed.contains { $0.contains("KEEP-HOST-RULES") }, "actual restored process retains workspace extension and host injection")
        print("helper-context-diet: real delegated Pi process; off/on, contract, project tools, restore/resume/compact/retry, unsupported scope and lead separation passed")
    }
}

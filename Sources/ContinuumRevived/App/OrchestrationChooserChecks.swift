import AppKit
import ContinuumRevivedCore

/// Production composer -> actual Claude argv -> authenticated MCP service ->
/// supervisor -> disposable CLI helpers. No provider calls or live project state.
@MainActor
enum OrchestrationChooserChecks {
    typealias Bench = WorkspaceAgentReportChecks.Bench
    static func expect(_ value: Bool, _ message: String) throws {
        try WorkspaceAgentReportChecks.expect(value, "chooser: " + message)
    }
    static func bench(_ name: String) async throws -> Bench {
        let b = try HelperRetryWorktreeChecks.bench("chooser-" + name)
        let root = try HelperRetryWorktreeChecks.managedRepository(b)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try #"{"checks":[{"invocation":"check-feature","covers":["Sources/**"],"checkFiles":["checks/Neighbour.swift"]}]}"#.write(to: root.appendingPathComponent("scripts/check-coverage-manifest.json"), atomically: true, encoding: .utf8)
        let cli = b.binDir.appendingPathComponent("claude")
        let script = try String(contentsOf: cli, encoding: .utf8).replacingOccurrences(
            of: "    if 'HOLD' in json.dumps(o)",
            with: "    if 'EXIT-WITHOUT-RESULT' in json.dumps(o): sys.exit(0)\n    if 'HOLD' in json.dumps(o)")
        try script.write(to: cli, atomically: true, encoding: .utf8)
        _ = b.supervisor.rename(agentID: b.f.agentId, to: "Chooser lead")
        b.settings.set(true, forKey: ManagedChooser.enabledKey)
        try b.f.delegate.reconciledManagedSessionSource.reconcile(
            registry: b.f.delegate.registryStore!.loadOrEmpty(), reason: .continuumRestarted, now: Date())
        try expect(await b.supervisor.accept(.sendPrompt(AgentPrompt("HOLD-lead")), for: b.f.agentId) == .accepted, "composer refused lead")
        _ = try await HelperRetryWorktreeChecks.capture(b, b.f.agentId)
        try await AgentPresenceChecks.eventually("chooser request did not start", timeout: 15) {
            b.supervisor.chooserRequests[b.f.agentId]?.turnIDs.isEmpty == false
        }
        try await AgentPresenceChecks.eventually("coverage snapshot did not load", timeout: 5) { ManagedChooserCoverage.shared.status(root: root.path) == "partial" }
        return b
    }
    static func config(_ b: Bench) throws -> WorkspaceMCPConfiguration {
        // The same launch seam that selected the actual runner's tool set.
        let id = b.f.agentId
        guard let config = b.supervisor.runnerLaunch(for: id, record: b.supervisor.records[id]!).workspaceMCP,
              config.chooser else { throw WorkspaceAgentReportChecks.Failure(description: "chooser missing from production launch") }
        return config
    }
    static func plan(_ b: Bench, choice: String, reason: String = "independent file changes", paths: [[String]] = []) async throws -> [String: Any] {
        let payload: [String: Any] = ["choice": choice, "reason": reason, "parts": paths.enumerated().map { i, paths in
            ["title": "part \(i + 1)", "contract": ["owns": paths, "shared": [], "mustNotTouch": [], "checks": []]] as [String: Any]
        }]
        let reply = try await WorkspaceAgentReportChecks.call(config(b), "array_plan", payload)
        try expect(!reply.isError, "production MCP array_plan rejected: \(reply.reply)")
        return reply.reply["result"] as? [String: Any] ?? [:]
    }
    static func run() async throws {
        for (name, choice, paths, disjoint) in [
            ("solo", "solo", [[String]](), true),
            ("split", "split", [["Sources/A.swift"], ["Sources/B.swift"]], true),
            ("overlap", "split", [["Sources"], ["sources/A.swift"]], false),
            ("one", "split", [["Sources/A.swift"]], true),
        ] {
            let b = try await bench(name); defer { b.tearDown() }
            var visible: [String] = []
            let notice = b.supervisor.addLocalNoticeObserver(for: b.f.agentId) { visible.append($0.body) }
            defer { b.supervisor.removeLocalNoticeObserver(notice, for: b.f.agentId) }
            _ = b.supervisor.declareStatus(.init(now: "prior", next: "keep-next", needsYou: "keep-attention", declaredAt: Date()), for: b.f.agentId)
            let answer = try await plan(b, choice: choice, paths: paths)
            try expect(b.supervisor.records[b.f.agentId]?.declaredStatus?.next == "keep-next" && b.supervisor.records[b.f.agentId]?.declaredStatus?.needsYou == "keep-attention", "choice erased declared next/attention")
            let line = choice == "solo" ? "Solo: independent file changes" : "Split into \(paths.count): independent file changes"
            try expect(answer["line"] as? String == line, "incorrect visible line")
            try expect(b.supervisor.records[b.f.agentId]?.declaredStatus?.now == line, "choice not rendered via production status")
            try expect(answer["ownsDisjoint"] as? Bool == disjoint, "incorrect ownership verdict")
            try expect(answer["unownedCheckFiles"] as? [String] == ["checks/Neighbour.swift"], "production plan omitted unowned checks")
            if choice == "split" {
                let parts = answer["parts"] as? [[String: Any]] ?? []
                try expect(parts.first?["registeredChecks"] as? [String] == ["check-feature"], "production plan omitted registered coverage")
            }
            try expect((answer["advisory"] != nil) == (name == "one"), "one-part advice wrong")
            try expect(b.supervisor.chooserRequests[b.f.agentId]?.latched == false, "declaration latched without an implementation effect")
            if name == "solo" {
                let root = b.supervisor.records[b.f.agentId]!.checkoutRoot
                let files = (0..<80).map { "checks/File-\($0).swift" }
                let manifest: [String: Any] = ["checks": [["invocation": "check-many", "covers": ["Sources/**"], "checkFiles": files]]]
                try JSONSerialization.data(withJSONObject: manifest).write(to: URL(fileURLWithPath: root).appendingPathComponent("scripts/check-coverage-manifest.json"))
                ManagedChooserCoverage.shared.prepare(root: root)
                try await AgentPresenceChecks.eventually("manifest refresh stayed stale", timeout: 5) { ManagedChooserCoverage.shared.unowned(root: root, contracts: []).count == 80 }
                let bounded = try await plan(b, choice: choice, paths: paths)
                try expect((bounded["unownedCheckFiles"] as? [String])?.count == 32 && bounded["unownedCheckFileCount"] as? Int == 80, "plan coverage output not bounded with explicit total")
            }
            let repeated = try await plan(b, choice: choice, paths: paths)
            try expect(repeated["requestId"] as? String == answer["requestId"] as? String, "repeat changed request")
            try expect(visible == [line], "choice did not render exactly once through the live transcript notice seam")
            let context = try await WorkspaceAgentReportChecks.call(config(b), "array_workspace_context", [:])
            let contextResult = context.reply["result"] as? [String: Any] ?? [:]
            try expect((contextResult["capabilities"] as? [String])?.contains("agent.plan") == true, "context omitted the launched chooser operation")
            let conflict = b.f.api.dispatch(agentId: b.f.agentId, requestId: UUID().uuidString,
                op: "agent.plan", payload: ["choice": "solo", "reason": "contradictory later declaration"])
            if case .error = conflict {} else { throw WorkspaceAgentReportChecks.Failure(description: "chooser allowed second choice") }
            let argv = try ManagedModeChecks.argv(b, b.f.agentId)
            try expect(!argv.contains("Edit,Write,MultiEdit,NotebookEdit,ListAgents"), "solo launch still statically bans edits")
            // Read the server configuration captured by the CLI at launch,
            // not a fresh configuration reconstructed by the witness.
            let tools = try ManagedModeChecks.listedTools(ManagedModeChecks.claudeServer(b, b.f.agentId))
            let pinned = tools.first { $0["name"] as? String == "array_plan" }?["_meta"] as? [String: Any]
            try expect(pinned?["anthropic/alwaysLoad"] as? Bool == true, "array_plan schema not pinned on actual lead config")
            if name == "solo" { try await delegationIntentDelivery(b, tools: tools) }
            b.supervisor.runLedger.drain()
            let ledger = AgentStore(smokeTest: false).layout.applicationSupportDirectory.appendingPathComponent("run-ledger/ledger.jsonl")
            let rows = ManagedRunLedgerChecks.rows(ledger, "plan", agent: b.f.agentId)
            try expect(rows.count == 1, "choice not recorded exactly once: \(rows)")
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
            try expect(!encoded.contains("independent file changes") && !encoded.contains("part 1"), "plan prose leaked into ledger")
        }
        try coverage()
        try await handoffCounts()
        try await retryMetric()
        print("PASS chooser plan: solo, split, overlap, one-part advice, idempotency, visible status, pinned schema and one ledger row")
    }
    static func delegationIntentDelivery(_ b: Bench, tools: [[String: Any]]) async throws {
        let hook = try await ManagedModeChecks.hook(b, b.f.agentId,
            ["hook_event_name": "SessionStart", "source": "startup", "session_id": UUID().uuidString])
        let brief = hook["additionalContext"] as? String ?? ""
        let description = tools.first { $0["name"] as? String == "array_delegate" }?["description"] as? String ?? ""
        var failures: [String] = []
        if !brief.contains(ManagedModeChecks.expectedChooserDelegationIntent) {
            failures.append("SessionStart did not deliver the Managed delegation intent")
        }
        if !description.contains(ManagedModeChecks.expectedChooserDelegationIntent) {
            failures.append("the launched MCP delegate description omitted the Managed delegation intent")
        }
        if description.contains(ManagedModeChecks.originalDelegationIntent) {
            failures.append("the launched chooser MCP delegate description retained the user-request-only restriction")
        }
        try expect(failures.isEmpty, failures.joined(separator: "; "))
    }
    static func coverage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chooser-coverage-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try #"{"checks":[{"invocation":"check-A","covers":["Sources/Feature/**"],"checkFiles":["checks/A.swift"]},{"invocation":"check-B","covers":["Other.swift"],"checkFiles":["checks/B.swift"]}]}"#.write(to: root.appendingPathComponent("scripts/check-coverage-manifest.json"), atomically: true, encoding: .utf8)
        ManagedChooserCoverage.shared.prepare(root: root.path)
        let deadline = Date().addingTimeInterval(5)
        while ManagedChooserCoverage.shared.status(root: root.path) == "loading" && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        try expect(ManagedChooserCoverage.shared.checks(root: root.path, owns: ["Sources/Feature/A.swift"]) == ["check-A"], "manifest coverage missing")
        try expect(ManagedChooserCoverage.shared.unowned(root: root.path, contracts: [.init(owns: ["checks/A.swift"])]) == ["checks/B.swift"], "unowned check set wrong")
        try FileManager.default.removeItem(at: root.appendingPathComponent("scripts/check-coverage-manifest.json"))
        ManagedChooserCoverage.shared.prepare(root: root.path)
        let refreshDeadline = Date().addingTimeInterval(5)
        while ManagedChooserCoverage.shared.refreshing(root: root.path) && Date() < refreshDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        try expect(ManagedChooserCoverage.shared.checks(root: root.path, owns: ["sources/feature/A.swift"]) == ["check-A"], "failed refresh discarded good case-insensitive coverage")
    }
    static func lifecycle() async throws {
        let b = try await bench("lifecycle"); defer { b.tearDown() }
        b.supervisor.helperCompletionEnabled = { _ in false }
        let lead = b.f.agentId, original = b.supervisor.chooserRequests[b.f.agentId]!.id
        let originalTurn = b.supervisor.chooserRequests[lead]!.turnIDs.first!
        _ = try await plan(b, choice: "split", paths: [["A.swift"], ["B.swift"]])
        let read = try await WorkspaceAgentReportChecks.call(config(b), "array_delegate", ["task": "HOLD review", "title": "review", "readOnly": true, "idempotencyKey": UUID().uuidString])
        let reviewer = try HelperRetryWorktreeChecks.child(read)
        try expect(b.supervisor.chooserRequests[lead]?.latched == false, "read-only helper closed latch")
        let (a, _) = try await PartContractChecks.delegate(b, "HOLD A", contract: ["owns": ["A.swift"]])
        try expect(b.supervisor.chooserRequests[lead]?.latched == true, "first implementation effect did not latch")
        let (c, _) = try await PartContractChecks.delegate(b, "HOLD B", contract: ["owns": ["B.swift"]])
        _ = try await HelperRetryWorktreeChecks.capture(b, a)
        _ = try await HelperRetryWorktreeChecks.capture(b, c)
        try expect(b.supervisor.isRunning(a) && b.supervisor.isRunning(c), "two implementation parts not alive concurrently")
        try expect(b.supervisor.chooserRequests[lead]?.id == original, "delegation replaced task")
        // Session hooks and user steering are not new requests.
        _ = try await ManagedModeChecks.hook(b, lead, ["hook_event_name": "SessionStart", "source": "compact", "session_id": "chooser-compact"])
        try expect(b.supervisor.chooserRequests[lead]?.id == original && b.supervisor.chooserRequests[lead]?.latched == true, "compaction reset latch")
        try await HelperRetryWorktreeChecks.finish(b, lead)
        try expect(b.supervisor.chooserRequests[lead]?.latched == true, "intermediate lead end reopened active parts")
        // A new user task resets its declaration, while unfinished writes remain fenced.
        try expect(await b.supervisor.accept(.sendPrompt(AgentPrompt("HOLD-next")), for: lead) == .accepted, "next user task refused")
        try await AgentPresenceChecks.eventually("next request did not start", timeout: 15) { b.supervisor.chooserRequests[lead]?.id != original }
        let next = b.supervisor.chooserRequests[lead]!.id
        try expect(b.supervisor.chooserRequests[lead]?.latched == true && b.supervisor.chooserRequests[lead]?.plan == nil, "new user task dropped outstanding implementation fence")
        b.supervisor.qaDeliver(.turnCompleted(threadId: "fixture", turnId: originalTurn, outcome: .completed, errorMessage: nil), to: lead)
        try expect(b.supervisor.chooserRequests[lead]?.id == next, "late root terminal closed newer request")
        try await HelperRetryWorktreeChecks.finish(b, a)
        try expect(b.supervisor.chooserRequests[lead]?.latched == true, "first helper reopened before last part")
        try await HelperRetryWorktreeChecks.finish(b, c)
        try expect(b.supervisor.chooserRequests[lead]?.latched == false, "last helper did not reopen integration")
        try await HelperRetryWorktreeChecks.finish(b, reviewer)
        try expect(b.supervisor.chooserRequests[lead]?.id == next && b.supervisor.chooserRequests[lead]?.latched == false, "late read-only helper modified next task")
        let followup = try await WorkspaceAgentReportChecks.call(config(b), "array_message_agent", ["agentId": a.rawValue.uuidString, "text": "HOLD followup", "idempotencyKey": UUID().uuidString])
        try expect(!followup.isError, "implementation follow-up refused: \(followup.reply)")
        try await AgentPresenceChecks.eventually("follow-up did not relatch", timeout: 15) { b.supervisor.isRunning(a) && b.supervisor.chooserRequests[lead]?.latched == true }
        b.supervisor.stop(a)
        try expect(b.supervisor.chooserRequests[lead]?.latched == false, "stopping helper left latch closed")
        let (archived, _) = try await PartContractChecks.delegate(b, "HOLD archive", contract: ["owns": ["C.swift"]])
        _ = try await HelperRetryWorktreeChecks.capture(b, archived)
        try expect(b.supervisor.chooserRequests[lead]?.latched == true, "new helper not fenced")
        _ = b.supervisor.archive(archived)
        try expect(b.supervisor.chooserRequests[lead]?.latched == false, "archived helper left latch closed")
        let (silent, _) = try await PartContractChecks.delegate(b, "EXIT-WITHOUT-RESULT", contract: ["owns": ["D.swift"]])
        try await AgentPresenceChecks.eventually("silent process exit left a write fence", timeout: 15) {
            !b.supervisor.isRunning(silent) && b.supervisor.chooserRequests[lead]?.latched == false
        }
        try await restart()
        print("PASS chooser lifecycle: read-only exemption, concurrent fanout, compaction, carry active writes across new task, late terminal, all helpers, follow-up relatch, stop, archive and silent process exit")
    }
    static func restart() async throws {
        let b = try await bench("restart"); defer { b.tearDown() }
        let lead = b.f.agentId
        let (child, _) = try await PartContractChecks.delegate(b, "HOLD restart-helper", contract: ["owns": ["Restart.swift"]])
        _ = try await HelperRetryWorktreeChecks.capture(b, child)
        try expect(b.supervisor.records[child]?.delegationContext?.chooserWriteInProgress == true, "implementation recovery marker absent before helper work")
        let support = AgentStore(smokeTest: false).layout.applicationSupportDirectory
        let image = b.binDir.appendingPathComponent("restart-image"), project = b.binDir.appendingPathComponent("restart-project")
        try FileManager.default.copyItem(at: support, to: image)
        let oldRoot = b.supervisor.records[lead]!.checkoutRoot
        try FileManager.default.copyItem(at: URL(fileURLWithPath: oldRoot), to: project)
        let store = AgentStore(applicationSupportDirectory: image)
        for var record in try store.loadAll() {
            if record.cwd.hasPrefix(oldRoot) { record.cwd = project.path + record.cwd.dropFirst(oldRoot.count) }
            if record.checkoutRoot.hasPrefix(oldRoot) { record.checkoutRoot = project.path + record.checkoutRoot.dropFirst(oldRoot.count) }
            record.projectRoot = project.path
            try store.upsert(record)
        }
        let fresh = AgentSupervisor(store: store)
        fresh.configureManagedMode(defaults: b.settings)
        fresh.workspaceToolsPermission = { .free }
        _ = fresh.restore()
        defer { fresh.stopAll() }
        let host = WorkspaceMCPHost()
        let service = WorkspaceAPIService(runtime: b.f.api.runtimeProvider, canvas: b.f.api.canvasProvider,
            focusBroker: b.f.api.focusBrokerProvider, supervisor: fresh, registryStore: b.f.api.registryStoreProvider,
            epoch: UUID().uuidString, approvalHandler: { _ in .deny })
        host.setHandler { request, completion in service.handleMCPRequest(request, completion: completion) }
        fresh.workspaceMCPConfigurationProvider = { id, _, standards in
            host.configuration(for: id, serverExecutable: b.helper, projectStandards: standards)
        }
        guard let cold = host.configuration(for: lead, serverExecutable: b.helper, projectStandards: false) else {
            throw WorkspaceAgentReportChecks.Failure(description: "cold host configuration absent")
        }
        // The actual restored LEAD, before it is relaunched, cannot acknowledge old policy.
        try expect(try await hookFailure(cold, token: cold.tokenFilePath)["permissionDecision"] as? String == "deny", "restored lead without a launch acknowledged policy")
        try expect(await fresh.accept(.sendPrompt(AgentPrompt("HOLD restart-lead")), for: lead) == .accepted, "restored lead refused resume")
        try await AgentPresenceChecks.eventually("restored lead request not started", timeout: 15) { fresh.chooserRequests[lead]?.turnIDs.isEmpty == false }
        guard let warm = fresh.runnerLaunch(for: lead, record: fresh.records[lead]!).workspaceMCP else {
            throw WorkspaceAgentReportChecks.Failure(description: "resumed host configuration absent")
        }
        try expect(fresh.chooserHookPolicy(for: fresh.records[lead]!) == "latched", "resume forgot unresolved helper writer")
        try expect(try await hookFailure(warm, token: warm.tokenFilePath)["permissionDecision"] as? String == "deny", "resumed lead could write beside orphan helper")
        fresh.stop(child) // explicit host stop resolves the conservatively retained writer
        try expect(fresh.chooserHookPolicy(for: fresh.records[lead]!) == "open", "explicit stop did not release restored fence")
        try expect(try store.load(id: child)?.delegationContext?.chooserWriteInProgress == false, "resolved fence was not persisted")
    }
    static func handoffCounts() async throws {
        for (label, planned, actual, expected) in [("declaredtwo", true, 1, 1), ("unplannedtwo", false, 2, 0)] {
            let b = try await bench(label); defer { b.tearDown() }
            b.supervisor.helperCompletionEnabled = { _ in false }
            if planned { _ = try await plan(b, choice: "split", paths: [["A.swift"], ["B.swift"]]) }
            var helpers: [AgentID] = []
            for index in 0..<actual {
                let (id, _) = try await PartContractChecks.delegate(b, "HOLD metric \(index)", contract: ["owns": ["part-\(index).swift"]])
                _ = try await HelperRetryWorktreeChecks.capture(b, id)
                helpers.append(id)
            }
            for id in helpers { try await HelperRetryWorktreeChecks.finish(b, id) }
            try await HelperRetryWorktreeChecks.finish(b, b.f.agentId)
            b.supervisor.runLedger.drain()
            let url = AgentStore(smokeTest: false).layout.applicationSupportDirectory.appendingPathComponent("run-ledger/ledger.jsonl")
            try expect(ManagedRunLedgerChecks.rows(url, "oneHelperHandoff", agent: b.f.agentId).count == expected, "handoff count followed declared plan instead of actual delegations")
        }
    }

    static func retryMetric() async throws {
        let b = try await bench("retrymetric"); defer { b.tearDown() }
        b.supervisor.helperCompletionEnabled = { _ in false }
        let (old, _) = try await PartContractChecks.delegate(b, "PRIOR-BRIEF", contract: ["owns": ["A.swift"]])
        try await AgentPresenceChecks.eventually("metric helper did not fail", timeout: 15) { !b.supervisor.isRunning(old) && b.supervisor.records[old]?.latestTerminalEvent?.outcome == .failed }
        let (retry, _) = try await PartContractChecks.delegate(b, "retry same part", retry: old)
        try await AgentPresenceChecks.eventually("metric retry did not settle", timeout: 15) { !b.supervisor.isRunning(retry) && b.supervisor.records[retry]?.latestTerminalEvent != nil }
        try await HelperRetryWorktreeChecks.finish(b, b.f.agentId)
        b.supervisor.runLedger.drain()
        let url = AgentStore(smokeTest: false).layout.applicationSupportDirectory.appendingPathComponent("run-ledger/ledger.jsonl")
        try expect(ManagedRunLedgerChecks.rows(url, "implementationDelegated", agent: b.f.agentId).count == 2
            && ManagedRunLedgerChecks.rows(url, "oneHelperHandoff", agent: b.f.agentId).count == 1, "retry counted as an independent implementation part")
    }
    static func policy() async throws {
        let b = try await bench("policy"); defer { b.tearDown() }
        let lead = b.f.agentId
        func decision(_ agent: AgentID, _ tool: String, huge: Bool = false) async throws -> [String: Any] {
            try await ManagedModeChecks.hook(b, agent, ["hook_event_name": "PreToolUse", "tool_name": tool,
                "tool_input": ["command": huge ? String(repeating: "x", count: WorkspaceAgentHook.maxPostedPayloadBytes + 1) : "printf changed > chooser-edited.txt"]])
        }
        func edit(_ agent: AgentID, _ tool: String) async throws -> Bool {
            let c = agent == lead ? try config(b) : try b.configuration(for: agent)
            let file = URL(fileURLWithPath: b.supervisor.records[agent]!.checkoutRoot).appendingPathComponent("chooser-edited.txt")
            try? FileManager.default.removeItem(at: file)
            let script = #"""
            import json, pathlib, subprocess, sys
            hook = json.loads(sys.argv[1])
            result = subprocess.run(hook, input=json.dumps(dict(hook_event_name='PreToolUse', tool_name=sys.argv[3], tool_input=dict(file_path=sys.argv[2], command='printf changed > file'))), text=True, capture_output=True)
            body = json.loads(result.stdout) if result.stdout.strip() else {}
            if result.returncode == 2 or body.get('hookSpecificOutput', {}).get('permissionDecision') == 'deny':
                print('denied')
            elif sys.argv[3] == 'Bash':
                subprocess.run(['/bin/sh', '-c', 'printf changed > "$1"', 'chooser', sys.argv[2]], check=True)
                print('wrote')
            else:
                pathlib.Path(sys.argv[2]).write_text('changed')
                print('wrote')
            """#
            var hook = [c.serverExecutable, "hook", "--endpoint", c.endpoint, "--agent-id", c.agentID, "--token-file", c.tokenFilePath]
            if c.chooser { hook += ["--fail-closed", "1"] }
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", script, String(decoding: try JSONSerialization.data(withJSONObject: hook), as: UTF8.self), file.path, tool]
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            process.environment = ProcessInfo.processInfo.environment.merging([PiAgentRunner.arrayHostedEnvironmentKey: "1"]) { _, new in new }
            try process.run()
            try await AgentPresenceChecks.eventually("tool CLI did not settle", timeout: 10) { !process.isRunning }
            try expect(process.terminationStatus == 0, "tool CLI failed")
            let wrote = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "wrote"
            try expect(wrote == FileManager.default.fileExists(atPath: file.path), "tool outcome disagrees with filesystem")
            return wrote
        }
        try expect(try await edit(lead, "Edit"), "solo edit failed")
        let (child, _) = try await PartContractChecks.delegate(b, "HOLD implementation", contract: ["owns": ["chooser-edited.txt"]])
        _ = try await HelperRetryWorktreeChecks.capture(b, child)
        try expect(!(try await edit(lead, "Edit")), "latched edit succeeded")
        try expect(!(try await edit(lead, "Bash")), "latched shell write succeeded")
        try expect(try await edit(child, "Edit"), "helper edit failed")
        try expect(try await decision(lead, "Bash", huge: true)["permissionDecision"] as? String == "deny", "trimmed tool input bypassed latch")
        try expect(try await decision(lead, "mcp__other__write")["permissionDecision"] as? String == "deny", "unknown MCP route bypassed latch")
        try expect(try await decision(lead, "Read")["permissionDecision"] == nil, "read-only native tool refused")
        try expect(try await decision(lead, "mcp__array_workspace__wait_agents")["permissionDecision"] == nil, "authenticated result collection refused")
        let configuration = try config(b)
        let failed = try await hookFailure(configuration, token: "/nonexistent-array-chooser-token")
        try expect(failed["permissionDecision"] as? String == "deny", "hook transport failed open")
        let childConfig = try b.configuration(for: child)
        try expect(try await hookFailure(childConfig, token: childConfig.tokenFilePath)["permissionDecision"] as? String == "deny", "host without chooser policy acknowledged an orphan")
        try expect(try await hookFailure(configuration, token: configuration.tokenFilePath, body: "{malformed")["permissionDecision"] as? String == "deny", "malformed hook failed open")
        let silent = try WorkspaceHookBridgeChecks.SilentListener(); defer { silent.close() }
        try expect(try await hookFailure(configuration, token: configuration.tokenFilePath, endpoint: "http://127.0.0.1:\(silent.port)/workspace-mcp")["permissionDecision"] as? String == "deny", "host timeout failed open")
        let nonTool = try await hookFailure(configuration, token: "/nonexistent-array-chooser-token", body: #"{"hook_event_name":"SessionStart","source":"resume"}"#)
        try expect(nonTool["permissionDecision"] as? String == "deny", "invalid token was not rejected before reading event input")
        let hung = try await hookFailure(configuration, token: configuration.tokenFilePath, keepInputOpen: true)
        try expect(hung["exitCode"] as? Int == 2, "hung stdin failed open")
        let invalid = try await hookFailure(configuration, token: "/nonexistent-array-chooser-token", keepInputOpen: true)
        try expect(invalid["permissionDecision"] as? String == "deny", "token guard waited for stdin")
        try await HelperRetryWorktreeChecks.finish(b, child)
        try expect(try await edit(lead, "Edit"), "integration edit stayed closed")
        print("PASS chooser policy: solo edits, latched edits/shell/unknown/oversize refused, helper edits, missing-token fail closed, integration reopens")
    }
    static func hookFailure(_ config: WorkspaceMCPConfiguration, token: String, endpoint: String? = nil,
                            body: String = #"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#, keepInputOpen: Bool = false) async throws -> [String: Any] {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: config.serverExecutable)
        process.arguments = ["hook", "--endpoint", endpoint ?? config.endpoint, "--agent-id", config.agentID, "--token-file", token, "--fail-closed", "1"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment.merging([PiAgentRunner.arrayHostedEnvironmentKey: "1"]) { _, new in new }
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(body.utf8))
        if !keepInputOpen { try input.fileHandleForWriting.close() }
        defer { try? input.fileHandleForWriting.close() }
        try await AgentPresenceChecks.eventually("failed hook did not exit", timeout: 5) { !process.isRunning }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus == 2 { return ["permissionDecision": "deny", "exitCode": 2] }
        if data.isEmpty { return [:] }
        let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return reply["hookSpecificOutput"] as? [String: Any] ?? [:]
    }
}

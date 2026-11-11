import AppKit
import ContinuumRevivedCore

/// `.plans/116` part 4: a contract on `array_delegate`, driven through the real
/// MCP helper, the production `agent.delegate` and supervisor spawn, into a
/// disposable Claude CLI that records each launch's argv and first prompt.
/// No model or network is used.
@MainActor
enum PartContractChecks {
    typealias Checks = HelperRetryWorktreeChecks
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        try WorkspaceAgentReportChecks.expect(condition(), "part-contract: " + message)
    }

    static func run() async throws {
        let b = try Checks.bench("part-contract"); defer { b.tearDown() }
        // The fake CLI holds any prompt containing HOLD, and a helper's prompt
        // carries its lead's name: keep that name free of it.
        try expect(b.supervisor.rename(agentID: b.f.agentId, to: "Lead"), "lead rename refused")
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }

        func delegate(_ task: String, contract: [String: Any]? = nil, retry: AgentID? = nil) async throws -> (AgentID, [String: Any]) {
            var payload: [String: Any] = ["task": task, "title": "part", "harness": "Claude Code",
                                          "model": ManagedModeChecks.model, "idempotencyKey": UUID().uuidString]
            if let contract { payload["contract"] = contract }
            if let retry { payload["retryOf"] = retry.rawValue.uuidString }
            let reply = try await WorkspaceAgentReportChecks.call(b.configuration(for: b.f.agentId), "array_delegate", payload)
            return (try Checks.child(reply), reply.reply["result"] as? [String: Any] ?? [:])
        }
        /// Every string the CLI received in its first user message, joined.
        func firstPrompt(_ id: AgentID) async throws -> (text: String, argv: [String]) {
            let capture = try await Checks.capture(b, id)
            func strings(_ value: Any) -> [String] {
                switch value {
                case let s as String: return [s]
                case let a as [Any]: return a.flatMap(strings)
                case let d as [String: Any]: return d.keys.sorted().flatMap { strings(d[$0]!) }
                default: return []
                }
            }
            return (strings(capture["prompt"] ?? "").joined(separator: "\n"), capture["argv"] as? [String] ?? [])
        }
        func contract(_ id: AgentID) -> AgentDelegationContract? { b.supervisor.records[id]?.delegationContext?.contract }
        func occurrences(_ needle: String, _ haystack: String) -> Int { haystack.components(separatedBy: needle).count - 1 }
        let header = "Contract from your lead"

        // 1. Stored with the brief, normalized, and told once.
        let registry = "scripts/run-matrix.sh"
        let contractA: [String: Any] = [
            "owns": ["./Sources/Feature/A.swift", "docs/feature-a/", registry],
            "mustNotTouch": ["Package.swift"], "checks": ["--feature-a-check"],
            "decisions": ["overlap is advisory"], "costLimit": "no main-thread work", "report": "commit hashes"]
        let expectedA = AgentDelegationContract(
            owns: ["Sources/Feature/A.swift", "docs/feature-a", registry], mustNotTouch: ["Package.swift"],
            checks: ["--feature-a-check"], decisions: ["overlap is advisory"], costLimit: "no main-thread work", report: "commit hashes")
        let (a, aResult) = try await delegate("HOLD part A", contract: contractA)
        check(contract(a) == expectedA, "stored contract \(String(describing: contract(a))) != \(expectedA)")
        check(b.supervisor.records[a]?.delegationContext?.brief == "HOLD part A", "the brief must stay the task alone")
        check(aResult["ownershipOverlaps"] == nil, "a first helper has no sibling to overlap: \(aResult)")
        let aPrompt = try await firstPrompt(a)
        check(occurrences(header, aPrompt.text) == 1 && occurrences(expectedA.promptText, aPrompt.text) == 1,
              "the first prompt must carry the contract exactly once: \(aPrompt.text)")

        // 2. Overlap with a live sibling is advice in the result; the delegation still happens.
        let (bId, bResult) = try await delegate("HOLD part B", contract: ["owns": ["Sources/Feature", registry]])
        let overlaps = bResult["ownershipOverlaps"] as? [[String: Any]] ?? []
        check(overlaps.count == 1 && overlaps.first?["agentId"] as? String == a.rawValue.uuidString
              && overlaps.first?["paths"] as? [String] == ["Sources/Feature/A.swift"]
              && (overlaps.first?["title"] as? String)?.isEmpty == false,
              "B must be told A owns Sources/Feature/A.swift, and nothing about the shared registry: \(bResult)")
        check(b.supervisor.isRunning(bId) && contract(bId)?.owns == ["Sources/Feature", registry],
              "the overlapping delegation must still start with its own contract")

        // 3. A shared registry alone is no overlap.
        let (c, cResult) = try await delegate("HOLD part C", contract: ["owns": [registry, "Sources/ContinuumRevived/App/ContinuumApp.swift"]])
        check(cResult["ownershipOverlaps"] == nil, "shared registries must not be advised: \(cResult)")

        // 4. A finished sibling is no overlap.
        for id in [a, bId, c] { try await Checks.finish(b, id) }
        let (d, dResult) = try await delegate("part D", contract: ["owns": ["Sources/Feature/A.swift"]])
        check(dResult["ownershipOverlaps"] == nil, "finished siblings must not be advised: \(dResult)")
        _ = try await firstPrompt(d)

        // 5. A retry inherits the stopped helper's contract; its own wins.
        func failed(_ task: String, _ body: [String: Any]) async throws -> AgentID {
            let (id, _) = try await delegate("HOLD " + task, contract: body)
            _ = try await Checks.capture(b, id)
            b.supervisor.stop(id)
            try await AgentPresenceChecks.eventually("stopped helper is not retryable", timeout: 15) { b.supervisor.mayRetry(id, from: b.f.agentId) }
            return id
        }
        let e = try await failed("part E", ["owns": ["Sources/E.swift"], "checks": ["--e-check"]])
        let (inherited, _) = try await delegate("Continue E", retry: e)
        let inheritedPrompt = try await firstPrompt(inherited)
        check(contract(inherited) == contract(e) && contract(e) != nil, "a retry must inherit the failed helper's contract: \(String(describing: contract(inherited)))")
        check(occurrences(header, inheritedPrompt.text) == 1 && inheritedPrompt.text.contains("Sources/E.swift"),
              "the retry's prompt must carry the inherited contract once: \(inheritedPrompt.text)")
        let e2 = try await failed("part E2", ["owns": ["Sources/E2.swift"]])
        let (overridden, _) = try await delegate("Continue E2", contract: ["owns": ["Sources/F.swift"]], retry: e2)
        let overriddenPrompt = try await firstPrompt(overridden)
        check(contract(overridden) == AgentDelegationContract(owns: ["Sources/F.swift"]), "an explicit contract on a retry must win: \(String(describing: contract(overridden)))")
        check(occurrences(header, overriddenPrompt.text) == 1 && !overriddenPrompt.text.contains("Sources/E2.swift"),
              "the retry's prompt must carry only its own contract: \(overriddenPrompt.text)")

        // 6. Omitted: the record and the CLI launch are what they were before contracts.
        let (o, oResult) = try await delegate("part O")
        let (w, _) = try await delegate("part O", contract: ["owns": ["Sources/O.swift"]])
        let oLaunch = try await firstPrompt(o), wLaunch = try await firstPrompt(w)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(b.supervisor.records[o]!)) as? [String: Any]
        let contextKeys = Set((encoded?["delegationContext"] as? [String: Any] ?? [:]).keys)
        check(contract(o) == nil && contextKeys.isSubset(of: ["brief", "baseHead", "retryOf", "createdWorktree", "checkoutNotice"]) && contextKeys.contains("brief"),
              "an omitted contract must leave today's record keys, got \(contextKeys.sorted())")
        check(oResult["ownershipOverlaps"] == nil, "an omitted contract must add nothing to the result")
        let wContract = contract(w)?.promptText ?? "missing"
        check(oLaunch.text == wLaunch.text.replacingOccurrences(of: "\n\n" + wContract, with: "") && !oLaunch.text.contains(header),
              "an omitted contract must leave the first prompt as the task alone: \(oLaunch.text)")
        // Each helper's own session and agent ids are the only expected difference.
        func sessionless(_ id: AgentID, _ argv: [String]) -> [String] {
            let sid = AgentSupervisor.claudeRunnerConfig(for: b.supervisor.records[id]!).sessionId
            let agent = id.rawValue.uuidString
            return argv.map {
                $0.replacingOccurrences(of: sid, with: "SESSION").replacingOccurrences(of: agent, with: "AGENT")
                    .replacingOccurrences(of: agent.replacingOccurrences(of: "-", with: "_"), with: "AGENT")
            }
        }
        let oArgv = sessionless(o, oLaunch.argv), wArgv = sessionless(w, wLaunch.argv)
        check(!oArgv.isEmpty && oArgv.count == wArgv.count && zip(oArgv, wArgv).allSatisfy { $0 == $1 },
              "a contract must not change argv; differing \(zip(oArgv, wArgv).filter { $0 != $1 }), lengths \(oArgv.count)/\(wArgv.count)")

        // 7. Malformed paths are a schema error, and nothing starts.
        let before = b.supervisor.records.count
        for bad in ["/etc/passwd", "../outside.swift"] {
            let reply = try await WorkspaceAgentReportChecks.call(b.configuration(for: b.f.agentId), "array_delegate", [
                "task": "bad", "harness": "Claude Code", "model": ManagedModeChecks.model,
                "idempotencyKey": UUID().uuidString, "contract": ["owns": [bad]]])
            check(WorkspaceAgentReportChecks.errorCode(reply) == "invalid_request", "\(bad) must be refused as invalid_request: \(reply.reply)")
        }
        check(b.supervisor.records.count == before, "a refused contract must create no helper")

        // 8. Restart: a new supervisor over the same store reads the contract back.
        for (name, id) in [("d", d), ("inherited", inherited), ("overridden", overridden), ("o", o), ("w", w)] {
            let phase = String(describing: b.supervisor.turnPresence(for: id)?.phase)
            try await AgentPresenceChecks.eventually("helper \(name) did not settle (\(phase))", timeout: 15) { !b.supervisor.isRunning(id) }
        }
        let restarted = AgentSupervisor(store: AgentStore(smokeTest: false))
        defer { restarted.stopAll() }
        _ = restarted.restore()
        check(restarted.records[a]?.delegationContext?.contract == expectedA
              && restarted.records[overridden]?.delegationContext?.contract == AgentDelegationContract(owns: ["Sources/F.swift"])
              && restarted.records[o] != nil && restarted.records[o]?.delegationContext?.contract == nil,
              "the contract must survive a restart: \(String(describing: restarted.records[a]?.delegationContext))")

        try expect(failures.isEmpty, "\n" + failures.joined(separator: "\n"))
        print("Part contract checks passed: stored and told once, survives restart, retry inherits and an explicit one wins, live overlap advised and delegation kept, shared registry and finished sibling not advised, omitted keeps record keys, prompt and argv, malformed paths refused")
    }
}

import AppKit
import ContinuumRevivedCore

/// Real MCP -> delegation -> supervisor -> Claude runner argv/stdin/cwd. Git
/// repositories and scripted CLIs are disposable; no model or network is used.
@MainActor
enum HelperRetryWorktreeChecks {
    typealias Bench = WorkspaceAgentReportChecks.Bench
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        try WorkspaceAgentReportChecks.expect(condition(), "helper-retry-worktree: " + message)
    }

    static func bench(_ name: String) throws -> Bench {
        let b = try ManagedModeChecks.bench(name)
        let capture = b.binDir.appendingPathComponent("capture-").path
        var script = ManagedModeChecks.fakeClaude
        script = script.replacingOccurrences(of: "        if 'HOLD' in json.dumps(o):", with: "        if 'HOLD' in json.dumps(o) and 'Retry context' not in json.dumps(o):")
        script = script.replacingOccurrences(of: "'managed-release'", with: "'managed-release-'+sid")
        // Multiline Swift literals strip indentation, so match without it.
        script = script.replacingOccurrences(of: "if 'HOLD' in json.dumps(o):", with: "if 'HOLD' in json.dumps(o) and 'Retry context' not in json.dumps(o):")
        script = script.replacingOccurrences(of: "    emit({'type':'system'", with: "    with open(\(String(reflecting: capture))+sid+'.json', 'w') as f: json.dump({'cwd':os.getcwd(), 'prompt':o, 'argv':args}, f)\n    emit({'type':'system'")
        script = script.replacingOccurrences(of: "'subtype':'success','is_error':False", with: "'subtype':('error_during_execution' if 'PRIOR-BRIEF' in json.dumps(o) and 'Retry context' not in json.dumps(o) else 'success'),'is_error':('PRIOR-BRIEF' in json.dumps(o) and 'Retry context' not in json.dumps(o))")
        try script.write(to: b.binDir.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        return b
    }

    @discardableResult
    static func git(_ root: URL, _ args: [String]) throws -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = args
        p.currentDirectoryURL = root; p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        try expect(p.terminationStatus == 0, "git \(args) exited \(p.terminationStatus)")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func repository(_ root: URL) throws {
        try git(root, ["init", "-q"])
        try ".array/\n.worktrees/\nmanaged-argv.jsonl\nmanaged-release*\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "initial\n".write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try git(root, ["add", ".gitignore", "tracked.txt"])
        try git(root, ["commit", "-qm", "test: seed disposable helper repository"])
    }

    static func request(_ b: Bench, parent: AgentID? = nil, task: String, title: String = "fix ledger", retry: AgentID? = nil, key: String = UUID().uuidString) async throws -> WorkspaceAgentReportChecks.ToolReply {
        var payload: [String: Any] = ["task": task, "title": title, "harness": "Claude Code", "model": ManagedModeChecks.model, "idempotencyKey": key]
        if let retry { payload["retryOf"] = retry.rawValue.uuidString }
        return try await WorkspaceAgentReportChecks.call(b.configuration(for: parent ?? b.f.agentId), "array_delegate", payload)
    }

    static func child(_ reply: WorkspaceAgentReportChecks.ToolReply) throws -> AgentID {
        guard !reply.isError, let result = reply.reply["result"] as? [String: Any],
              let raw = result["childAgentId"] as? String, let uuid = UUID(uuidString: raw) else {
            throw WorkspaceAgentReportChecks.Failure(description: "delegate failed: \(reply.reply)")
        }
        return AgentID(rawValue: uuid)
    }

    static func capture(_ b: Bench, _ id: AgentID) async throws -> [String: Any] {
        let sid = AgentSupervisor.claudeRunnerConfig(for: b.supervisor.records[id]!).sessionId
        let file = b.binDir.appendingPathComponent("capture-\(sid).json")
        try await AgentPresenceChecks.eventually("script did not receive the first prompt", timeout: 15) {
            (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) } != nil
        }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    }

    static func finish(_ b: Bench, _ id: AgentID) async throws {
        let sid = AgentSupervisor.claudeRunnerConfig(for: b.supervisor.records[id]!).sessionId
        try Data().write(to: URL(fileURLWithPath: b.supervisor.records[id]!.cwd).appendingPathComponent("managed-release-" + sid))
        try await AgentPresenceChecks.eventually("helper did not settle", timeout: 15) {
            !b.supervisor.isRunning(id) && b.supervisor.records[id]?.latestTerminalEvent != nil
        }
    }

    static func retry() async throws {
        let b = try bench("helper-retry"); defer { b.tearDown() }
        let root = URL(fileURLWithPath: b.supervisor.records[b.f.agentId]!.checkoutRoot)
        try repository(root)
        let brief = "HOLD PRIOR-BRIEF repair the ledger " + Array(repeating: "earlier", count: 600).joined(separator: " ")
        let old = try child(await request(b, task: brief))
        _ = try await capture(b, old)
        let refused = try await request(b, task: "retry running", retry: old)
        try expect(WorkspaceAgentReportChecks.errorCode(refused) == "invalid_request", "running retry was accepted")
        // Includes staged, unstaged, untracked and committed changes since spawn.
        try "changed\n".write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try git(root, ["add", "tracked.txt"])
        try git(root, ["commit", "-qm", "test: retain helper progress"])
        for i in 0..<20 { try "work".write(to: root.appendingPathComponent(String(format: "new-%02d.txt", i)), atomically: true, encoding: .utf8) }
        try "staged".write(to: root.appendingPathComponent("a-staged.txt"), atomically: true, encoding: .utf8)
        try git(root, ["add", "a-staged.txt"])
        try "unstaged".write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        let filed = try await WorkspaceAgentReportChecks.call(b.configuration(for: old), "array_report", [
            "summary": "REPORT-SUMMARY retained ledger work", "checks": [["what": "FAILED-CHECK swift test", "result": "fail"]],
            "findings": [["level": "issue", "text": "FINDING ledger mismatch"]], "next": "NEXT repair the balance"])
        try expect(!filed.isError, "report refused")
        try await finish(b, old)
        try expect(b.supervisor.records[old]?.latestTerminalEvent?.outcome == .failed, "scripted failure did not become a failed helper")
        let foreign = try child(await request(b, task: "foreign parent"))
        _ = try await capture(b, foreign)
        let foreignReply = try await request(b, parent: foreign, task: "steal retry", retry: old)
        try expect(WorkspaceAgentReportChecks.errorCode(foreignReply) == "invalid_request", "foreign retry was accepted")
        try await AgentPresenceChecks.eventually("successful helper did not settle") { !b.supervisor.isRunning(foreign) }
        let successfulReply = try await request(b, task: "retry success", retry: foreign)
        try expect(WorkspaceAgentReportChecks.errorCode(successfulReply) == "invalid_request", "successful retry was accepted")
        let key = UUID().uuidString
        let retried = try child(await request(b, task: "Continue repair", retry: old, key: key))
        let replayed = try child(await request(b, task: "Continue repair", retry: old, key: key))
        try expect(retried == replayed, "transport replay created another retry")
        let seen = try await capture(b, retried)
        let prompt = String(decoding: try JSONSerialization.data(withJSONObject: seen["prompt"]!), as: UTF8.self)
        for marker in ["PRIOR-BRIEF", "a-staged.txt", "new-00.txt", "REPORT-SUMMARY", "FAILED-CHECK", "FINDING", "NEXT", old.rawValue.uuidString, "more omitted"] {
            try expect(prompt.contains(marker), "retry prompt lost \(marker)")
        }
        let stored = try AgentStore(smokeTest: false).load(id: retried)
        try expect(stored?.delegationContext?.retryOf == old && stored?.delegationContext?.brief == "Continue repair", "retry provenance not persisted")
        let files = try WorktreeManager().changedFiles(repo: root, since: b.supervisor.records[old]?.delegationContext?.baseHead)
        try expect(files.contains("tracked.txt") && files.contains("a-staged.txt"), "git baseline lost committed/staged/unstaged names")
        let handoff = AgentDelegationContext.handoff(from: b.supervisor.records[old]!, changedFiles: files)
        try expect(handoff.split(whereSeparator: \.isWhitespace).count <= 300 && handoff.count <= 4800, "handoff cap exceeded")
        // The ACTUAL runner prompt must carry the bounded text, once.
        let encodedHandoff = String(decoding: try JSONEncoder().encode(handoff), as: UTF8.self).dropFirst().dropLast()
        try expect(prompt.contains(String(encodedHandoff)), "runner did not receive the exact bounded handoff")
        try expect(b.supervisor.records[old]?.lastReport != nil && FileManager.default.fileExists(atPath: root.appendingPathComponent("new-00.txt").path), "retry removed earlier work")
        let held = try child(await request(b, task: "HOLD stopped helper"))
        _ = try await capture(b, held)
        b.supervisor.stop(held)
        try expect(b.supervisor.mayRetry(held, from: b.f.agentId), "stopped helper not eligible")
        let stoppedRetry = try child(await request(b, task: "Continue stopped work", retry: held))
        _ = try await capture(b, stoppedRetry)
        print("Helper retry checks passed: real first prompt, git names/report/caps, running and foreign refusals, stopped retry, idempotency and persistence")
    }

    static func worktrees() async throws {
        let b = try bench("helper-worktrees"); defer { b.tearDown() }
        let root = URL(fileURLWithPath: b.supervisor.records[b.f.agentId]!.checkoutRoot)
        try repository(root)
        try expect(b.supervisor.setMode(.managed, for: b.f.agentId), "lead mode refused")
        let first = try child(await request(b, task: "HOLD first helper"))
        let firstCapture = try await capture(b, first)
        try expect(WorktreeManager.resolved(URL(fileURLWithPath: firstCapture["cwd"] as! String)) == WorktreeManager.resolved(root), "first helper left shared checkout")
        let head = try git(root, ["rev-parse", "HEAD"])
        let secondReply = try await request(b, task: "HOLD second helper", title: "Fix ledger totals")
        let second = try child(secondReply), secondCapture = try await capture(b, second)
        let secondRoot = URL(fileURLWithPath: secondCapture["cwd"] as! String)
        try expect(secondRoot != root && secondRoot.deletingLastPathComponent().lastPathComponent == ".worktrees", "concurrent managed helper did not get a worktree")
        try expect(secondRoot.lastPathComponent.hasPrefix("fix-ledger-totals-"), "slug did not use the task title")
        let secondHead = try git(secondRoot, ["rev-parse", "HEAD"])
        try expect(secondHead == head, "worktree did not start from lead HEAD")
        try expect((secondReply.reply["result"] as? [String: Any])?["checkoutRoot"] as? String == b.supervisor.records[second]?.checkoutRoot, "result omitted actual checkout")
        let third = try child(await request(b, task: "HOLD third helper", title: "Fix ledger totals"))
        let thirdCapture = try await capture(b, third)
        try expect(thirdCapture["cwd"] as? String != secondCapture["cwd"] as? String, "same title reused a checkout")
        // A managed lead IN a worktree cuts from its HEAD, not the main HEAD,
        // and puts children beside its own tree rather than nesting containers.
        try expect(b.supervisor.setMode(.managed, for: second), "nested lead mode refused")
        try "branch-only".write(to: secondRoot.appendingPathComponent("branch-only.txt"), atomically: true, encoding: .utf8)
        try git(secondRoot, ["add", "branch-only.txt"])
        try git(secondRoot, ["commit", "-qm", "test: advance isolated lead head"])
        let nestedHead = try git(secondRoot, ["rev-parse", "HEAD"])
        let nestedFirst = try child(await request(b, parent: second, task: "HOLD nested first"))
        _ = try await capture(b, nestedFirst)
        let nestedSecond = try child(await request(b, parent: second, task: "HOLD nested second"))
        let nestedCapture = try await capture(b, nestedSecond)
        let nestedRoot = URL(fileURLWithPath: nestedCapture["cwd"] as! String)
        try expect(nestedRoot.deletingLastPathComponent() == secondRoot.deletingLastPathComponent(), "nested worktree container")
        let actualNestedHead = try git(nestedRoot, ["rev-parse", "HEAD"])
        try expect(actualNestedHead == nestedHead && nestedHead != head, "isolated lead HEAD was ignored")
        try "retained".write(to: secondRoot.appendingPathComponent("dirty.txt"), atomically: true, encoding: .utf8)
        try await finish(b, second)
        try expect(FileManager.default.fileExists(atPath: secondRoot.appendingPathComponent("dirty.txt").path), "completion deleted dirty worktree")
        let thirdRoot = URL(fileURLWithPath: b.supervisor.records[third]!.checkoutRoot)
        try "retained".write(to: thirdRoot.appendingPathComponent("dirty.txt"), atomically: true, encoding: .utf8)
        b.supervisor.stop(third)
        let archive = b.supervisor.archive(third)
        try expect(archive.worktreeRemoved == nil && archive.worktreeRetained != nil
            && FileManager.default.fileExists(atPath: thirdRoot.appendingPathComponent("dirty.txt").path), "archive deleted helper worktree")
        try expect(b.supervisor.setMode(.free, for: b.f.agentId), "free mode refused")
        let free = try child(await request(b, task: "HOLD free helper"))
        let freeCapture = try await capture(b, free)
        try expect(WorktreeManager.resolved(URL(fileURLWithPath: freeCapture["cwd"] as! String)) == WorktreeManager.resolved(root), "free delegation changed checkout")
        print("Helper worktree checks passed: real runner cwd, first shared, concurrent distinct/title slugs, nested lead HEAD, dirty retention and free unchanged")
        b.supervisor.stopAll()

        let n = try bench("helper-nongit"); defer { n.tearDown() }
        try expect(n.supervisor.setMode(.managed, for: n.f.agentId), "non-git lead mode refused")
        let n1 = try child(await request(n, task: "HOLD first non-git")); _ = try await capture(n, n1)
        let n2Reply = try await request(n, task: "HOLD second non-git")
        let n2 = try child(n2Reply); _ = try await capture(n, n2)
        try expect(n.supervisor.records[n1]?.checkoutRoot == n.supervisor.records[n2]?.checkoutRoot, "non-git did not share")
        try expect(((n2Reply.reply["result"] as? [String: Any])?["checkoutNotice"] as? String)?.contains("not a git repository") == true, "non-git fallback was silent")
        let nRoot = URL(fileURLWithPath: n.supervisor.records[n1]!.checkoutRoot)
        try git(nRoot, ["init", "-q"])
        let count = n.supervisor.records.count
        let unborn = try await request(n, task: "no HEAD must not silently share")
        try expect(WorkspaceAgentReportChecks.errorCode(unborn) == "unsupported" && n.supervisor.records.count == count,
                   "git failure silently fell back to shared checkout")
        print("Helper non-git fallback checks passed: shared runner cwd with explicit result notice; unborn git HEAD refuses")
    }
}

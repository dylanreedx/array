import AppKit
import ContinuumRevivedCore
import Foundation

/// `.plans/102` P1: the hook bridge, Claude side, observation only. The real
/// `array-workspace-mcp hook` binary against the PRODUCTION listener and
/// handler (`mountWorkspaceSceneAtBoot` wires `workspaceMCPHost` to
/// `WorkspaceAPIService.handleMCPRequest`), over a real `AgentSupervisor`.
///
/// - Outside Array (no marker) the command exits 0 at once and the app records
///   nothing.
/// - Array down or silent: exit 0 within the post timeout, nothing on stdout.
/// - A recorded SubagentStart/SubagentStop pair (claude 2.1.312, P0 p4) arrives
///   as two receipts on the calling agent, and nothing else about that agent
///   changes: record, status, transcript, children.
/// - A wrong token, another agent's token, or none at all records nothing.
@MainActor
enum WorkspaceHookBridgeChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    /// Verbatim stdin from `p0-claude-evidence/hooks.jsonl` (p4, the `tiny`
    /// subagent), home directory renamed.
    static let subagentStart = #"{"session_id": "37e85ba0-1530-440d-8017-867d34b452b4", "transcript_path": "/Users/qa/.claude/projects/-private-tmp-array-p0-claude-proj/37e85ba0-1530-440d-8017-867d34b452b4.jsonl", "cwd": "/private/tmp/array-p0-claude/proj", "prompt_id": "24ca0f59-014f-4423-b736-cbe44673d9ea", "agent_id": "a8b6a5e972481a99f", "agent_type": "tiny", "hook_event_name": "SubagentStart"}"#
    static let subagentStop = #"{"session_id": "37e85ba0-1530-440d-8017-867d34b452b4", "transcript_path": "/Users/qa/.claude/projects/-private-tmp-array-p0-claude-proj/37e85ba0-1530-440d-8017-867d34b452b4.jsonl", "cwd": "/private/tmp/array-p0-claude/proj", "prompt_id": "24ca0f59-014f-4423-b736-cbe44673d9ea", "permission_mode": "bypassPermissions", "agent_id": "a8b6a5e972481a99f", "agent_type": "tiny", "effort": {"level": "high"}, "hook_event_name": "SubagentStop", "stop_hook_active": false, "agent_transcript_path": "/Users/qa/.claude/projects/-private-tmp-array-p0-claude-proj/37e85ba0-1530-440d-8017-867d34b452b4/subagents/agent-a8b6a5e972481a99f.jsonl", "last_assistant_message": "TINY-OK", "background_tasks": [], "session_crons": []}"#

    struct HookRun { let status: Int32; let stdout: Data; let seconds: TimeInterval }

    /// Runs the hook command as Claude would: the body on stdin, nothing else.
    /// The run loop keeps turning so the host can answer on main meanwhile.
    static func runHook(_ helper: String, endpoint: String, agentID: String, tokenFile: String,
                        body: String, marker: Bool) throws -> HookRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = [WorkspaceAgentHook.subcommand, "--endpoint", endpoint,
                             "--agent-id", agentID, "--token-file", tokenFile]
        var environment = ProcessInfo.processInfo.environment
        environment[PiAgentRunner.arrayHostedEnvironmentKey] = marker ? "1" : nil
        process.environment = environment
        let input = Pipe(); let output = Pipe()
        process.standardInput = input; process.standardOutput = output
        let started = Date()
        try process.run()
        input.fileHandleForWriting.write(Data(body.utf8))
        try input.fileHandleForWriting.close()
        let deadline = started.addingTimeInterval(10)
        while process.isRunning, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        if process.isRunning { process.terminate(); throw Failure(description: "the hook command was still running after 10 s") }
        let seconds = Date().timeIntervalSince(started)
        return HookRun(status: process.terminationStatus,
                       stdout: output.fileHandleForReading.readDataToEndOfFile(), seconds: seconds)
    }

    /// Lets main answer anything still queued from the listener's thread.
    static func drainMain() {
        let deadline = Date().addingTimeInterval(0.2)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    static func run() throws {
        guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil,
              Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
            throw Failure(description: "hook bridge check requires isolated CONTINUUM_APP_SUPPORT and a dev binary")
        }
        let f = try WorkspaceAPIChecks.makeFixture()
        defer { f.tearDown() }
        let supervisor = f.delegate.qaAgentSupervisor
        guard let helper = AppDelegate.workspaceMCPExecutablePath() else {
            throw Failure(description: "array-workspace-mcp is not beside the app binary — build the package, not just the Array product")
        }
        guard let config = f.delegate.workspaceMCPHost.configuration(for: f.agentId, serverExecutable: helper) else {
            throw Failure(description: "the production MCP host issued no registration")
        }
        try config.materialize()
        let agentText = f.agentId.rawValue.uuidString

        // What must not move.
        let recordsBefore = supervisor.records
        let statusBefore = supervisor.derivedStreamStatus(for: f.agentId)
        let rowStatusBefore = supervisor.presenceRowStatus(for: f.agentId)
        let runningBefore = supervisor.isRunning(f.agentId)
        let transcriptBefore = supervisor.transcriptDocumentProjection(for: f.agentId)
        let childrenBefore = supervisor.children(of: f.agentId)
        try expect(supervisor.hookReceipts.isEmpty, "a fresh supervisor has receipts: \(supervisor.hookReceipts)")

        // (a) Outside Array: the same real endpoint and token, no marker.
        let inert = try runHook(helper, endpoint: config.endpoint, agentID: agentText, tokenFile: config.tokenFilePath,
                                body: subagentStart, marker: false)
        drainMain()
        try expect(inert.status == 0 && inert.stdout.isEmpty, "without the marker the hook must exit 0 silently: \(inert)")
        try expect(inert.seconds < 1.5, "without the marker the hook must exit at once, took \(inert.seconds) s")
        try expect(supervisor.hookReceipts.isEmpty, "without the marker the hook contacted Array: \(supervisor.hookReceipts)")

        // (b) Array down: nothing listening, then a listener that never answers.
        let closedPort = try Self.unusedLoopbackPort()
        let down = try runHook(helper, endpoint: "http://127.0.0.1:\(closedPort)/workspace-mcp", agentID: agentText,
                               tokenFile: config.tokenFilePath, body: subagentStart, marker: true)
        try expect(down.status == 0 && down.stdout.isEmpty, "with Array down the hook must exit 0 silently: \(down)")
        try expect(down.seconds < WorkspaceAgentHook.postTimeoutSeconds + 1, "with Array down the hook took \(down.seconds) s")
        let silent = try SilentListener()
        defer { silent.close() }
        let slow = try runHook(helper, endpoint: "http://127.0.0.1:\(silent.port)/workspace-mcp", agentID: agentText,
                               tokenFile: config.tokenFilePath, body: subagentStart, marker: true)
        try expect(slow.status == 0 && slow.stdout.isEmpty, "with Array silent the hook must exit 0 silently: \(slow)")
        try expect(slow.seconds < WorkspaceAgentHook.postTimeoutSeconds + 1,
                   "with Array silent the hook must give up within its timeout, took \(slow.seconds) s")

        // (c) Refused: a wrong token, another agent's token, no token.
        let wrongToken = f.tempRoot.appendingPathComponent("wrong.token")
        try Data("not-the-token".utf8).write(to: wrongToken)
        let stranger = AgentID(rawValue: UUID())
        guard let strangerConfig = f.delegate.workspaceMCPHost.configuration(for: stranger, serverExecutable: helper) else {
            throw Failure(description: "no registration for the second agent")
        }
        try strangerConfig.materialize()
        for (label, tokenFile) in [("a wrong token", wrongToken.path), ("another agent's token", strangerConfig.tokenFilePath)] {
            let refused = try runHook(helper, endpoint: config.endpoint, agentID: agentText, tokenFile: tokenFile,
                                      body: subagentStart, marker: true)
            drainMain()
            try expect(refused.status == 0 && refused.stdout.isEmpty, "a refused hook must still exit 0 silently (\(label)): \(refused)")
            try expect(supervisor.hookReceipts.isEmpty, "\(label) was accepted: \(supervisor.hookReceipts)")
        }
        let noToken = try Self.post(config.endpoint, [
            "schema": WorkspaceAPISchema.v1, "kind": "request", "requestId": "no-token", "agentId": agentText,
            "op": WorkspaceAgentHook.op, "payload": ["hook_event_name": "SubagentStart"],
        ])
        try expect((noToken["error"] as? [String: Any])?["code"] as? String == "permission_denied",
                   "a hook post without a token must be refused: \(noToken)")
        try expect(supervisor.hookReceipts.isEmpty, "a tokenless post was recorded: \(supervisor.hookReceipts)")

        // (d) The recorded pair arrives, on the right agent.
        for body in [subagentStart, subagentStop] {
            let delivered = try runHook(helper, endpoint: config.endpoint, agentID: agentText, tokenFile: config.tokenFilePath,
                                        body: body, marker: true)
            try expect(delivered.status == 0 && delivered.stdout.isEmpty, "a delivered hook must exit 0 silently: \(delivered)")
            try expect(delivered.seconds < WorkspaceAgentHook.postTimeoutSeconds, "a delivered hook took \(delivered.seconds) s")
        }
        drainMain()
        let receipts = supervisor.hookReceipts[f.agentId] ?? []
        try expect(Set(supervisor.hookReceipts.keys) == [f.agentId],
                   "receipts landed on the wrong agent: \(supervisor.hookReceipts.keys)")
        try expect(receipts.map(\.event) == ["SubagentStart", "SubagentStop"]
                   && receipts.allSatisfy { $0.subagentID == "a8b6a5e972481a99f" && $0.subagentType == "tiny"
                                            && $0.sessionID == "37e85ba0-1530-440d-8017-867d34b452b4" && $0.toolName == nil },
                   "the recorded pair did not arrive as two subagent receipts: \(receipts)")

        // (e) Observation only.
        try expect(supervisor.records == recordsBefore, "a hook receipt changed an agent record")
        try expect(supervisor.derivedStreamStatus(for: f.agentId) == statusBefore
                   && supervisor.presenceRowStatus(for: f.agentId) == rowStatusBefore
                   && supervisor.isRunning(f.agentId) == runningBefore, "a hook receipt changed the agent's status")
        try expect(supervisor.transcriptDocumentProjection(for: f.agentId) == transcriptBefore,
                   "a hook receipt changed the agent's transcript")
        try expect(supervisor.children(of: f.agentId) == childrenBefore, "a hook receipt created a child")

        // The ring is bounded.
        for index in 0..<(AgentHookReceipt.ringCapacity + 5) {
            let reply = f.api.handleMCPRequest([
                "agentId": agentText, "requestId": "ring-\(index)", "op": WorkspaceAgentHook.op,
                "payload": ["hook_event_name": "PreToolUse", "tool_name": "Bash", "session_id": "ring"],
            ])
            try expect(reply["status"] as? String == "ok", "a hook post was not acknowledged: \(reply)")
        }
        let ring = supervisor.hookReceipts[f.agentId] ?? []
        try expect(ring.count == AgentHookReceipt.ringCapacity && ring.allSatisfy { $0.event == "PreToolUse" },
                   "the receipt ring is not bounded to \(AgentHookReceipt.ringCapacity): \(ring.count)")

        // Not a model-facing tool: the MCP catalogue and the pi bridge's
        // operation list do not carry it.
        try expect(!WorkspaceMCPToolCatalog.tools.contains { $0.operation.rawValue == WorkspaceAgentHook.op }
                   && WorkspaceAPIOp(rawValue: WorkspaceAgentHook.op) == nil,
                   "the hook operation must never be a workspace tool")
        if case .error(let error) = f.api.dispatch(agentId: f.agentId, requestId: "pi-hook", op: WorkspaceAgentHook.op,
                                                    payload: ["hook_event_name": "Stop"]) {
            try expect(error.code == .unsupported, "the pi bridge's dispatch must refuse the hook op: \(error)")
        } else {
            throw Failure(description: "the pi bridge's dispatch accepted the hook op")
        }
    }

    static func unusedLoopbackPort() throws -> UInt16 {
        let listener = try SilentListener()
        let port = listener.port
        listener.close()
        return port
    }

    /// One HTTP POST to the endpoint, with main turning while it waits.
    static func post(_ endpoint: String, _ body: [String: Any]) throws -> [String: Any] {
        guard let url = URL(string: endpoint) else { throw Failure(description: "bad endpoint \(endpoint)") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        final class Box: @unchecked Sendable { var data: Data?; var done = false }
        let box = Box()
        URLSession.shared.dataTask(with: request) { data, _, _ in
            DispatchQueue.main.async { box.data = data; box.done = true }
        }.resume()
        let deadline = Date().addingTimeInterval(10)
        while !box.done, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        guard let data = box.data, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(description: "no reply from the endpoint")
        }
        return object
    }

    /// A loopback socket that listens and never answers: an app that is busy.
    final class SilentListener {
        let fd: Int32
        let port: UInt16
        init() throws {
            let socketFD = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard socketFD >= 0, bound == 0, listen(socketFD, 8) == 0 else { throw Failure(description: "could not open a loopback listener") }
            var actual = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &actual) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
            }
            fd = socketFD
            port = UInt16(bigEndian: actual.sin_port)
        }
        func close() { Darwin.close(fd) }
    }
}

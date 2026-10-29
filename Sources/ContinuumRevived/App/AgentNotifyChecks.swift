import AppKit
import ContinuumRevivedCore
import Foundation

/// `agent.notify` through the production `WorkspaceAPIService.dispatch`, over a
/// mounted workspace, into a production `AgentSupervisor` and its task ledger.
/// Only the runners are scripted, held mid-turn the way a tool call finds them.
/// What the relay then decides is witnessed by `ContinuumRevivedRelayChecks`.
@MainActor
enum AgentNotifyChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(description: message) }
    }

    static func run() async throws -> String {
        guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil,
              Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
            throw Failure(description: "agent-notify check requires isolated CONTINUUM_APP_SUPPORT and a dev binary")
        }
        let f = try WorkspaceAPIChecks.makeFixture()
        defer { f.tearDown() }
        let root = f.tempRoot.appendingPathComponent("notify-agents", isDirectory: true)
        var runners: [ScriptedAgentRunner] = []
        let supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root), makeRunner: { _ in
            let runner = ScriptedAgentRunner(script: [.turnStarted(threadId: "t", turnId: "turn-\(runners.count)")], holdUntilStopped: true)
            runners.append(runner); return runner
        })
        defer { for runner in runners { runner.stop() } }
        var pushes = 0
        supervisor.onCompanionTasksChanged = { pushes += 1 }
        var delivery = AgentNotifyResult.PhoneDelivery.relayWithoutTaskAlerts
        let api = WorkspaceAPIService(
            runtime: { f.runtime }, canvas: { f.canvas }, focusBroker: { nil }, supervisor: supervisor,
            registryStore: { nil }, epoch: "notify-check", approvalHandler: { _ in .deny },
            companionNotifyDelivery: { delivery })
        let config = AgentModelConfig.resolvedFromDefaults()
        let agent = supervisor.spawn(role: nil, prompt: nil, cwd: f.pbRoot, model: config.model, thinking: config.thinking,
                                     projectId: f.projectPb, projectRoot: f.pbRoot)
        _ = supervisor.setWorkspaceToolsEnabled(agentID: agent, true)

        var serial = 0
        func notify(_ reason: Any, _ message: Any = "Which database should I use?", key: String? = nil, as caller: AgentID? = nil) -> WorkspaceAPIService.Reply {
            serial += 1
            var payload: [String: Any] = ["reason": reason, "message": message]
            if let key { payload["idempotencyKey"] = key }
            return api.dispatch(agentId: caller ?? agent, requestId: "notify-\(serial)", op: "agent.notify", payload: payload)
        }
        func result(_ reply: WorkspaceAPIService.Reply) throws -> [String: AnyHashableJSON] {
            guard case let .result(value) = reply else { throw Failure(description: "expected a result, got \(reply)") }
            return value
        }
        func refused(_ reply: WorkspaceAPIService.Reply, _ code: WorkspaceAPIError.Code) throws -> Bool {
            guard case let .error(value) = reply else { return false }
            return value.code == code
        }
        func members() throws -> [CompanionTaskSnapshot.Member] { try supervisor.companionTaskSnapshot().tasks.flatMap(\.members) }
        func run(of id: AgentID) throws -> CompanionTaskSnapshot.Member? { try members().last { $0.agentID == id.rawValue && $0.state != .succeeded } }
        func wait(_ what: String, _ predicate: () throws -> Bool) async throws {
            for _ in 0..<250 { if try predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
            throw Failure(description: "timed out: \(what)")
        }

        // Not mid-turn: nothing to hold, and the agent is told so.
        let idle = try result(notify("needs_input", key: "idle"))
        let membersBefore = try members()
        try expect(idle["outcome"]?.string == "unavailable" && membersBefore.isEmpty, "an idle agent records nothing")

        // Mid-turn: the request holds the agent's own run and publishes.
        try expect(supervisor.send("private task prompt", to: agent), "accepted user turn")
        try await wait("turn running") { try runners.first?.runCount == 1 && run(of: agent)?.state == .running }
        let before = pushes
        let first = try result(notify("needs_input", key: "k1"))
        let expectedID = WorkspaceAPIService.attentionRequestID(agentId: agent, key: "k1")
        try expect(first["outcome"]?.string == "recorded" && first["reason"]?.string == "needs_input", "needs_input is recorded: \(first)")
        try expect(first["phoneDelivery"]?.string == "relayWithoutTaskAlerts"
                   && first["explanation"]?.string?.contains("no phone alert will arrive") == true,
                   "the result is honest that this relay cannot alert: \(first)")
        try expect(try run(of: agent)?.state == .needsInput && run(of: agent)?.requestID == expectedID, "the run needs input under the hashed request id")
        try expect(pushes > before, "the change is published")

        // Idempotency, conflicts, coalescing and validation.
        let replay = try result(notify("needs_input", key: "k1"))
        try expect(replay == first, "a retry with the same key returns the same result")
        try expect(try refused(notify("needs_input", "Something else entirely", key: "k1"), .idempotencyConflict), "same key, different request is a conflict")
        let revision = try supervisor.companionTaskSnapshot().revision
        delivery = .taskAlerts
        let second = try result(notify("needs_input", "Also, which region?", key: "k2"))
        try expect(try second["outcome"]?.string == "coalesced" && supervisor.companionTaskSnapshot().revision == revision,
                   "a second request in one turn is coalesced and writes nothing")
        try expect(try refused(notify("needs_input", "   "), .invalidRequest), "an empty message is refused")
        try expect(try refused(notify("milestone"), .invalidRequest), "an unknown reason is refused")
        try expect(try refused(notify("needs_input", String(repeating: "x", count: 501)), .invalidRequest), "an over-long message is refused")

        // The turn ends: the agent is waiting on the user, not done.
        try expect(runners[0].emit(.turnCompleted(threadId: "t", turnId: "turn-0", outcome: .completed, errorMessage: nil)), "turn end emitted")
        runners[0].releaseRunAfterStop()
        try await wait("turn ended") { !supervisor.isRunning(agent) }
        let waiting = try members().first { $0.agentID == agent.rawValue }
        try expect(waiting?.state == .needsInput && waiting?.requestID == expectedID, "after the turn the run still needs the user, never succeeded")

        // The user's answer continues the same task.
        try expect(supervisor.send("private answer", to: agent), "accepted answer")
        try await wait("answer running") { runners.count == 2 && runners[1].runCount == 1 }
        let task = try supervisor.companionTaskSnapshot().tasks.first { $0.members.contains { $0.runID == waiting?.runID } }
        try expect(task?.members.count == 2
                   && task?.members.contains { $0.runID == waiting?.runID && $0.state == .succeeded } == true
                   && task?.members.contains { $0.parentRunID == waiting?.runID && $0.state == .running } == true,
                   "the answer settles the wait and joins the same task: \(String(describing: task))")

        // completed never alerts by itself, and withdraws only this turn's request.
        let done = try result(notify("completed", "Picked Postgres and finished the migration."))
        try expect(try done["outcome"]?.string == "coalesced" && run(of: agent)?.state == .running,
                   "completed is folded into the task's own completion: \(done)")
        _ = try result(notify("needs_input", key: "k3"))
        let withdrawn = try result(notify("completed", "Never mind, I found it."))
        try expect(try withdrawn["explanation"]?.string?.hasPrefix("Your earlier request for the user was withdrawn.") == true
                   && run(of: agent)?.state == .running, "completed withdraws this turn's own request")

        // The agent's words and key go nowhere near the published metadata.
        let wire = String(decoding: try JSONEncoder().encode(supervisor.companionTaskSnapshot()), as: UTF8.self)
        try expect(!wire.contains("database") && !wire.contains("Postgres") && !wire.contains("k1"), "message and key stay off the wire")

        // The workspace context advertises the op and records it.
        let context = try result(api.dispatch(agentId: agent, requestId: "notify-context", op: "workspace.context", payload: [:]))
        try expect(context["capabilities"]?.array?.contains { $0.string == "agent.notify" } == true, "context advertises agent.notify without a prompt")
        try expect(context["recentOperations"]?.array?.contains { $0.object?["op"]?.string == "agent.notify" } == true, "recent operations include agent.notify")
        return "Agent notify checks passed: idle refusal, held run, honest delivery, idempotency/conflict/coalescing/validation, turn end waits, answer continues the task, completed folds and withdraws, privacy, context"
    }
}

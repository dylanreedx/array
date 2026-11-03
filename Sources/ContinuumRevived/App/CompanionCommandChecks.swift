import AppKit
import ContinuumRevivedCore
import ContinuumRevivedSync
import Foundation

/// What a phone's Stop and Approve do once they reach this Mac, through the
/// production `AgentSupervisor`: Stop is the composer's Stop and says when
/// there was nothing to stop; Approve reaches only a request the agent has
/// open. The runner is a fake that records what it was handed. The relay leg
/// (`ContinuumRevivedRelayChecks`) witnesses delivery to these actions.
@MainActor
enum CompanionCommandChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }

    static func run() async throws -> String {
        guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil,
              Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
            throw Failure(description: "companion-command check requires isolated CONTINUUM_APP_SUPPORT and a dev binary")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-companion-commands-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var runners: [ProviderRequestResponseChecks.RespondingRunner] = []
        let supervisor = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root.appendingPathComponent("agents")), makeRunner: { _ in
            let runner = ProviderRequestResponseChecks.RespondingRunner(); runners.append(runner); return runner
        })
        defer { for runner in runners { runner.stop() } }
        let config = AgentModelConfig.resolvedFromDefaults()
        let agent = supervisor.spawn(role: nil, prompt: nil, cwd: root, model: config.model, thinking: config.thinking,
                                     projectId: UUID(), projectRoot: root)
        func wait(_ what: String, _ predicate: () -> Bool) async throws {
            for _ in 0..<250 { if predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
            throw Failure(description: "timed out: \(what)")
        }

        try expect(await CompanionCommandActions.stop(UUID(), supervisor: supervisor) == .notFound, "an agent this Mac does not have is notFound")
        let idle = await CompanionCommandActions.stop(agent.rawValue, supervisor: supervisor)
        try expect(idle == .notRunning, "an idle agent is not claimed stopped: \(idle)")

        // The phone's message starts the turn as typed text would.
        try expect(await CompanionCommandActions.send(UUID(), text: "hi", supervisor: supervisor) == .notFound, "a message to an unknown agent is notFound")
        try expect(await CompanionCommandActions.send(agent.rawValue, text: "   ", supervisor: supervisor) == .empty, "a blank message is refused")
        let sent = await CompanionCommandActions.send(agent.rawValue, text: "hello from the phone", supervisor: supervisor)
        try expect(sent == .accepted, "an idle agent takes the phone's message: \(sent)")
        try await wait("turn running") { supervisor.isRunning(agent) }
        try expect(runners.first?.prompts == ["hello from the phone"], "the agent ran exactly the phone's words: \(runners.first?.prompts ?? [])")
        let busy = await CompanionCommandActions.send(agent.rawValue, text: "and this", supervisor: supervisor)
        try expect(busy == .busy, "a running turn refuses a second message instead of queueing it: \(busy)")
        try expect(runners.first?.prompts.count == 1, "the refused message did not reach the agent")
        supervisor.qaDeliver(.requestOpened(threadId: "t", requestId: "r1", kind: .commandExecutionApproval), to: agent)
        try expect(CompanionCommandActions.respond(agent.rawValue, requestID: "nope", decision: .accept, supervisor: supervisor) == .unknownRequest,
                   "a request the agent does not have open is refused")
        try expect(CompanionCommandActions.respond(agent.rawValue, requestID: "r1", decision: .decline, supervisor: supervisor) == .sent,
                   "an open request takes the phone's answer")
        try await wait("answer delivered") { runners.first?.delivered.count == 1 }
        try expect(runners[0].delivered[0].0 == "r1" && runners[0].delivered[0].1 == .decline, "the runner got the phone's decision for that request")

        let stopped = await CompanionCommandActions.stop(agent.rawValue, supervisor: supervisor)
        try expect(stopped == .stopped, "a running turn is stopped: \(stopped)")
        try await wait("turn ended") { !supervisor.isRunning(agent) }
        try expect(supervisor.records[agent] != nil, "Stop ends the turn, not the agent")
        try expect(await CompanionCommandActions.stop(agent.rawValue, supervisor: supervisor) == .notRunning, "a second Stop finds nothing to stop")
        return "Companion command checks passed: phone message runs once on an idle agent and is refused while busy (unknown/blank refused), unknown agent notFound, idle agent notRunning, open request takes the phone's decision, closed request refused, running turn stopped through the composer path, agent kept"
    }
}

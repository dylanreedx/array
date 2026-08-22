import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// M1.7 / M1.9 (`.plans/46`) — a stop is a stop, not a failure.
///
/// `AgentRunning.stop()` is declared non-throwing and reports nothing. What
/// production actually does on Stop is SIGTERM the child, after which `run()`
/// throws because the CLI exited non-zero — and the supervisor turned that into
/// `.runtimeError` → `didFail` → `.failed`, persisted it, and pushed it to the
/// user's phone as "agent failed". Every one of the eleven consumers of
/// `TurnOutcome.interrupted` was already correct
/// (`AgentSupervisor:3968`, `ManagedAgentActivityBridge:46`,
/// `AgentLocationProjector:105`, `APNSPushService:283`). There was simply **no
/// producer**: every production `turnCompleted` hard-coded `.completed` or
/// `.failed`.
///
/// **Why seven green stop checks never caught it.** All seven drive a
/// `ScriptedAgentRunner` whose `stop()` only bumps a counter and signals a
/// semaphore, after which `run` falls through to a normal return. Its one error
/// seam, `runError`, is thrown *before* `run` ever blocks, so it can model
/// "failed to start" and nothing else. No existing check could observe the throw
/// at all. M1.9 adds `stopError` — thrown after `released.wait()` returns — which
/// is production's shape exactly, needs no protocol change, and slots into the
/// existing `makeRunner:` injection seam.
///
/// **Three acts, because there are three ways to get this wrong.** A runner that
/// names the stop (the new `AgentRunStopped`); a runner that throws a plain error
/// after a stop, which is the race the plan named — `stop` delivers
/// `.sessionStateChanged(.stopped)` synchronously while the throw arrives later
/// on the global queue's hop back, so the error used to overwrite the stopped
/// state; and a genuine failure with no stop at all, which must still read as
/// failed. Without the third act the cheapest way to pass would be to call every
/// error an interruption.
@MainActor
enum AgentStopOutcomeChecks {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        var localizedDescription: String { message }
    }

    private struct PlainRunnerError: Error, CustomStringConvertible {
        var description: String { "claude exited with code 143" }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    private static func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    static func run() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("continuum-agent-stop-outcome-\(UUID().uuidString)", isDirectory: true)
        let cwd = root.appendingPathComponent("work", isDirectory: true)
        // The harness/model pair the app itself would use. A hard-coded id is
        // refused by strict harness ownership -- "Claude Code cannot run
        // anthropic/claude-sonnet-4-5" -- which is the point of that rule.
        let config = AgentModelConfig.resolvedFromDefaults()
        try fileManager.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        /// One act. Builds a supervisor over its own store, sends a prompt into a
        /// runner that blocks, then stops (or lets it fail) and reports what the
        /// supervisor recorded.
        func runAct(
            name: String,
            stopError: Error?,
            runError: Error? = nil,
            stopIt: Bool
        ) throws -> (
            outcome: AgentTerminalOutcome?,
            state: AgentTileOperationalState?,
            runner: ScriptedAgentRunner,
            supervisor: AgentSupervisor,
            id: AgentID
        ) {
            let storeRoot = root.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: storeRoot, withIntermediateDirectories: true)
            let store = AgentStore(applicationSupportDirectory: storeRoot)
            let runner = ScriptedAgentRunner(
                script: [.turnStarted(threadId: "stop-\(name)", turnId: "stop-\(name)#1")],
                holdUntilStopped: true,
                runError: runError,
                stopError: stopError
            )
            let supervisor = AgentSupervisor(store: store, makeRunner: { _ in runner })
            let id = supervisor.spawn(
                role: nil, prompt: nil, cwd: cwd,
                model: config.model, thinking: config.thinking)

            try expect(supervisor.send("go", to: id),
                       "\(name): the prompt must be accepted")
            try expect(waitUntil { supervisor.turnSnapshot(for: id)?.state == .working },
                       "\(name): the turn must be in flight before it is stopped; state is "
                       + "\(String(describing: supervisor.turnSnapshot(for: id)?.state))")

            if stopIt { supervisor.stop(id) }

            // `completedRuns` is the only witness that the blocked `run` actually
            // RETURNED — `isRunning` proves a dictionary entry went away and nothing
            // about the blocked call.
            try expect(waitUntil { runner.completedRuns == 1 },
                       "\(name): the blocked run must have returned; completedRuns is "
                       + "\(runner.completedRuns)")
            try expect(waitUntil { supervisor.records[id]?.latestTerminalEvent != nil },
                       "\(name): a terminal event must have been recorded")

            return (supervisor.records[id]?.latestTerminalEvent?.outcome,
                    supervisor.turnSnapshot(for: id)?.state,
                    runner, supervisor, id)
        }

        // === ACT 1: the runner names the stop. ===
        let act1 = try runAct(name: "named", stopError: AgentRunStopped(detail: "terminated"), stopIt: true)
        try expect(act1.runner.stopCount == 1,
                   "act1: stop() must have reached the runner exactly once; got \(act1.runner.stopCount)")
        try expect(act1.supervisor.isRunning(act1.id) == false,
                   "act1: the agent must not still be running")
        try expect(act1.outcome == .interrupted,
                   "act1: a stopped turn must be recorded as .interrupted, not "
                   + "\(String(describing: act1.outcome)). `.failed` here is what got persisted and "
                   + "pushed to the user's phone as \"agent failed\".")
        try expect(act1.state != nil,
                   "act1: the agent must still have a turn snapshot")
        if case .failed = act1.state! {
            throw Failure(message: "act1: a stopped agent must not read as failed; state is \(act1.state!)")
        }

        // === ACT 2: the runner throws a PLAIN error after the stop. This is the
        // race: `stop` delivers `.sessionStateChanged(.stopped)` synchronously
        // while the throw arrives later, so the error used to overwrite it. It also
        // covers any runner that has not adopted `AgentRunStopped`. ===
        let act2 = try runAct(name: "plain", stopError: PlainRunnerError(), stopIt: true)
        try expect(act2.outcome == .interrupted,
                   "act2: a plain error thrown as a CONSEQUENCE of a stop must still be recorded as "
                   + ".interrupted — the supervisor knows it asked for the stop; got "
                   + "\(String(describing: act2.outcome))")
        if case .failed = act2.state! {
            throw Failure(message: "act2: the stop must win over the error; state is \(act2.state!)")
        }

        // === ACT 3: a real failure, with no stop. It must STILL be a failure.
        // Without this act, calling every error an interruption would pass. ===
        let storeRoot = root.appendingPathComponent("genuine", isDirectory: true)
        try fileManager.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        let failStore = AgentStore(applicationSupportDirectory: storeRoot)
        let failRunner = ScriptedAgentRunner(script: [], runError: PlainRunnerError())
        let failSupervisor = AgentSupervisor(store: failStore, makeRunner: { _ in failRunner })
        let failID = failSupervisor.spawn(
            role: nil, prompt: nil, cwd: cwd,
            model: config.model, thinking: config.thinking)
        try expect(failSupervisor.send("go", to: failID), "act3: the prompt must be accepted")
        try expect(waitUntil { failSupervisor.records[failID]?.latestTerminalEvent != nil },
                   "act3: a terminal event must have been recorded")
        try expect(failSupervisor.records[failID]?.latestTerminalEvent?.outcome == .runtimeError,
                   "act3: a genuine failure that nobody stopped must still be a failure; got "
                   + "\(String(describing: failSupervisor.records[failID]?.latestTerminalEvent?.outcome))")
        guard let failState = failSupervisor.turnSnapshot(for: failID)?.state else {
            throw Failure(message: "act3: the failed agent must still have a turn snapshot")
        }
        guard case .failed = failState else {
            throw Failure(message: "act3: an unstopped failure must read as failed; state is \(failState)")
        }

        // === ACT 4: a new prompt clears the previous turn's stop, so the NEXT
        // failure is not laundered into an interruption forever. ===
        let act4Runner = ScriptedAgentRunner(script: [], runError: PlainRunnerError())
        let act4Store = AgentStore(
            applicationSupportDirectory: root.appendingPathComponent("relapse", isDirectory: true))
        var runners: [ScriptedAgentRunner] = [
            ScriptedAgentRunner(
                script: [.turnStarted(threadId: "relapse", turnId: "relapse#1")],
                holdUntilStopped: true,
                stopError: AgentRunStopped()),
            act4Runner
        ]
        let act4Supervisor = AgentSupervisor(store: act4Store, makeRunner: { _ in runners.removeFirst() })
        let act4ID = act4Supervisor.spawn(
            role: nil, prompt: nil, cwd: cwd,
            model: config.model, thinking: config.thinking)
        try expect(act4Supervisor.send("first", to: act4ID), "act4: the first prompt must be accepted")
        try expect(waitUntil { act4Supervisor.turnSnapshot(for: act4ID)?.state == .working },
                   "act4: the first turn must be in flight")
        act4Supervisor.stop(act4ID)
        try expect(waitUntil { act4Supervisor.records[act4ID]?.latestTerminalEvent?.outcome == .interrupted },
                   "act4: the first turn must be interrupted; got "
                   + "\(String(describing: act4Supervisor.records[act4ID]?.latestTerminalEvent?.outcome))")
        try expect(waitUntil { act4Supervisor.send("second", to: act4ID) },
                   "act4: a second prompt must be accepted after the stop")
        try expect(waitUntil { act4Supervisor.records[act4ID]?.latestTerminalEvent?.outcome == .runtimeError },
                   "act4: the SECOND turn genuinely failed and must be recorded as a failure — the "
                   + "previous turn's stop must not keep laundering errors; got "
                   + "\(String(describing: act4Supervisor.records[act4ID]?.latestTerminalEvent?.outcome))")

        print("AgentStopOutcomeChecks: a named stop, a plain error after a stop, a genuine "
              + "unstopped failure and a failure after a stop were each recorded correctly")
    }
}

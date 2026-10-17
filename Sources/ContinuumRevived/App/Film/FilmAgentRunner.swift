// Film harness: the runner a film agent's real composer send is handed to.
//
// In a `--film` run `AppDelegate.agentSupervisor` is built with `FilmAgentRunner.make`
// instead of `AgentSupervisor.productionRunner`, so a user's send takes production's
// whole path (composer -> `onSubmitPrompt` -> `AgentSupervisor.send`: record, transcript
// echo, `runners[id]`, the tile's user bubble, the cleared draft, `onAcceptedBoardTask`)
// and arrives here instead of at a claude/codex/pi process. Nothing is ever launched.
//
// `run` blocks its supervisor thread for the whole turn, exactly as a CLI process does,
// so the tile shows a turn in flight (Stop, Working). The scene drives the turn with its
// `turn`/`say`/`tool` verbs as before; its `turn: done` completes THROUGH this runner's
// `onEvent` (`complete(with:)`), the way a CLI reports its result, so the supervisor
// sees a reported completion and never appends "exited without reporting a result".
// Compiled only into the film build (`scripts/film-capture.sh`, -DARRAY_FILM).
#if ARRAY_FILM
import ContinuumRevivedCore
import Foundation

final class FilmAgentRunner: AgentRunning, @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var live: [AgentID: FilmAgentRunner] = [:]

    /// `AppDelegate`'s runner factory: the film runner in a film process (a `--film`
    /// run, or the `--film-scene-check` child, whose scenes send through real composers
    /// too: `FilmScene.isRequested`), else exactly `AgentSupervisor.productionRunner`.
    static func runner(for launch: AgentRunnerLaunch) -> AgentRunning {
        FilmScene.isRequested ? make(launch) : AgentSupervisor.productionRunner(for: launch)
    }

    /// The factory `AppDelegate` hands the supervisor in a film run.
    static func make(_ launch: AgentRunnerLaunch) -> AgentRunning {
        let runner = FilmAgentRunner(agentID: launch.record.id)
        registryLock.withLock { live[launch.record.id] = runner }
        return runner
    }

    /// The runner holding `agentID`'s send in flight, if a real send is in flight.
    static func inFlight(for agentID: AgentID) -> FilmAgentRunner? {
        registryLock.withLock { live[agentID].flatMap { $0.isRunning ? $0 : nil } }
    }

    /// Every prompt a real composer send handed a film runner, per agent, in order
    /// (witness only: a follow-up on a finished agent reaches a fresh turn).
    static func prompts(for agentID: AgentID) -> [String] {
        registryLock.withLock { promptLog[agentID] ?? [] }
    }
    nonisolated(unsafe) private static var promptLog: [AgentID: [String]] = [:]

    /// Releases every runner still holding a turn (end of the film).
    static func releaseAll() {
        let runners = registryLock.withLock { Array(live.values) }
        for runner in runners { runner.stop() }
    }

    let agentID: AgentID
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var onEvent: (@Sendable (AgentRuntimeEvent) -> Void)?
    private var running = false
    private var stopped = false
    private(set) var prompts: [AgentPrompt] = []

    init(agentID: AgentID) { self.agentID = agentID }

    var isRunning: Bool { lock.withLock { running } }

    func run(prompt: AgentPrompt, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        lock.withLock {
            self.onEvent = onEvent
            running = true
            prompts.append(prompt)
        }
        Self.registryLock.withLock { Self.promptLog[agentID, default: []].append(prompt.text) }
        finished.wait()
        let wasStopped = lock.withLock { () -> Bool in
            running = false
            self.onEvent = nil
            return stopped
        }
        if wasStopped { throw AgentRunStopped(detail: "film") }
    }

    /// The turn's end, reported as the CLI would report it, then the process "exits".
    func complete(with events: [AgentRuntimeEvent]) {
        let handler = lock.withLock { onEvent }
        for event in events { handler?(event) }
        finished.signal()
    }

    func stop() {
        let wasRunning = lock.withLock { () -> Bool in
            stopped = true
            return running
        }
        if wasRunning { finished.signal() }
    }

    func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {}
    func observeRuntimeObservations(_ handler: @escaping @Sendable (AgentRuntimeObservation) -> Void) {}
}
#endif

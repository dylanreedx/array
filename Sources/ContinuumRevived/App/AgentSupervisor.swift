import AppKit
import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P2A.3-agent-supervisor.md
//
// THE AGENT IS THE ENTITY; A TILE IS ONE VIEW OF IT (locked decision, _RUNBOOK.md).
//
// What this file moves: `AppDelegate.managedAgentRunners` was `[UUID: PiAgentRunner]`
// keyed by TILE, and the runner was constructed inside the tile's own
// `onSubmitPrompt` closure. The view was therefore the de-facto owner — the
// dictionary entry existed only because a tile asked for it, and every consumer of
// the event stream was that one tile's `ingest`. `AgentSupervisor` is the
// app-lifetime owner instead: it holds the runner, persists the `AgentRecord`
// (P2A.1) through `AgentStore` (P2A.2), and MULTICASTS the event stream.
//
// The multicast is the load-bearing half, not a convenience. A single-consumer
// stream makes the consumer the owner by construction: there is nowhere for the
// events to go once it is gone, so tearing the view down has to tear the agent
// down too. With a fan-out, a tile is one subscriber among several (inventory,
// phone mirror, a second tile after P2A.5's re-attach) and closing it is just one
// `onTermination`. `events(for:)` follows `ActivityStore.subscribe()`'s
// snapshot-then-tail contract for the same reason it does: a subscriber that
// attaches late must see the history before the tail, or a re-attached tile would
// render a transcript that starts mid-turn.
//
// NOT here, deliberately:
// · `PiAgentRunner` is untouched — Phase 5 replaces it with the RPC client, and a
//   rewrite here would collide with that.
// · Nothing is restored at init. The store may already hold records from a previous
//   launch; adopting them is P2A.7 (`restore-on-relaunch`), so within one session
//   `agent(forTile:)` dedupes and across launches it does not.
// · Attach / detach as an operation is P2A.5. This file only gets the ownership out
//   of the view so that ticket has something to move.

/// The runner seam. `PiAgentRunner`'s two entry points, named as a protocol so the
/// matrix can drive the supervisor with a scripted runner instead of Pi (no
/// network, no provider auth, no wall-clock). The production path still constructs
/// a real `PiAgentRunner` — `AgentSupervisor.piRunner(for:)` is the only place in
/// the app that constructs one, and `runAgentSupervisorChecks` asserts that by
/// reading the source.
protocol AgentRunning: AnyObject, Sendable {
    /// Blocking: runs one prompt to completion, streaming events to `onEvent` as
    /// they arrive. Called off the main thread by `send`.
    func run(prompt: String, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws
    func stop()
}

extension PiAgentRunner: AgentRunning {}

@MainActor
final class AgentSupervisor {
    /// How much of an agent's event history a late subscriber replays. Capped
    /// because `contentDelta` arrives per token, so an uncapped history is an
    /// uncapped buffer for the lifetime of the app. A re-attached tile therefore
    /// shows the recent transcript, not the whole one; the durable transcript is
    /// not this buffer's job.
    static let replayCap = 500

    private let store: AgentStore
    private let makeRunner: (AgentRecord) -> AgentRunning
    private let warn: (String) -> Void

    /// The records this supervisor owns, in memory. `AgentStore` is the durable
    /// copy; this is the live one.
    private(set) var records: [AgentID: AgentRecord] = [:]
    /// The runner for the prompt currently in flight, if any. One per agent: Pi is
    /// one process per prompt with a stable `--session-id`, so a finished runner is
    /// dropped and the next `send` makes a new one.
    private var runners: [AgentID: AgentRunning] = [:]
    private var subscribers: [AgentID: [UUID: AsyncStream<AgentRuntimeEvent>.Continuation]] = [:]
    private var history: [AgentID: [AgentRuntimeEvent]] = [:]

    init(
        store: AgentStore,
        makeRunner: @escaping (AgentRecord) -> AgentRunning = AgentSupervisor.piRunner,
        warn: @escaping (String) -> Void = { fputs($0 + "\n", stderr) }
    ) {
        self.store = store
        self.makeRunner = makeRunner
        self.warn = warn
    }

    // MARK: - Identity

    /// The thread every event for this agent carries. Provider adapters synthesize
    /// their own thread ids (Pi uses its live session id, and a fresh one per
    /// process), so the supervisor restamps each event with the AGENT's thread
    /// before fan-out: all consumers then see one consistent stream regardless of
    /// how many runner processes produced it. A consumer that filters on its own
    /// thread — the managed-agent tile does — rebinds again on the way in, exactly
    /// as the pre-supervisor wiring did.
    nonisolated static func threadId(for id: AgentID) -> String {
        "agent-\(id.rawValue.uuidString)"
    }

    /// Stable Pi session id, so prompts CONTINUE the same conversation. Keyed on
    /// the agent, not the tile (it was `continuum-<tileId>`): the conversation
    /// belongs to the agent, and a tile is one view of it.
    nonisolated static func sessionId(for id: AgentID) -> String {
        "continuum-agent-\(id.rawValue.uuidString)"
    }

    /// THE production runner, and the only `PiAgentRunner(` construction in the app.
    nonisolated static func piRunner(for record: AgentRecord) -> AgentRunning {
        PiAgentRunner(config: PiAgentRunner.Config(
            model: record.model,
            thinking: record.thinking,
            cwd: URL(fileURLWithPath: record.cwd, isDirectory: true),
            sessionId: sessionId(for: record.id)
        ))
    }

    // MARK: - Lifecycle

    /// Creates an agent, persists it, and (when `prompt` is non-empty) runs that
    /// first prompt. `tileId` is a VIEW BINDING, not identity — `nil` is a headless
    /// agent (P2A.6).
    func spawn(
        role: String?,
        prompt: String?,
        cwd: URL,
        model: String,
        thinking: String,
        projectId: UUID? = nil,
        tileId: UUID? = nil
    ) -> AgentID {
        let now = Date()
        let id = AgentID(rawValue: UUID())
        let record = AgentRecord(
            id: id,
            displayName: role ?? model,
            role: role,
            model: model,
            thinking: thinking,
            cwd: cwd.path,
            projectId: projectId,
            createdAt: now,
            lastActivityAt: now,
            tileId: tileId
        )
        records[id] = record
        persist(record)
        if let prompt, !prompt.isEmpty {
            send(prompt, to: id)
        }
        return id
    }

    /// Runs `prompt` on the agent's own runner, off the main thread (`run` blocks).
    /// Events hop back via `DispatchQueue.main.async` — FIFO, which is what keeps
    /// the fan-out ordered; a `Task { @MainActor }` per event would not be.
    func send(_ prompt: String, to id: AgentID) {
        guard var record = records[id] else {
            warn("AgentSupervisor.send: no agent \(id.rawValue.uuidString)")
            return
        }
        // ONE RUNNER PER AGENT, refused rather than replaced (from the
        // cross-review). Assigning over `runners[id]` would leave the first process
        // running and unreachable by `stop`, with two Pi processes on the same
        // `--session-id` writing the same conversation. Refusing is safe for the UI
        // — the tile latches `promptInFlight` and disables its compose row for the
        // duration, so a user cannot reach this — and it is the honest answer for a
        // programmatic caller (P2D's orchestrator): queueing or steering a live turn
        // is `P5.7-steer-follow-up`'s, and inventing it here would be a second
        // answer to supersede.
        if let inFlight = runners[id] {
            warn("AgentSupervisor.send: agent \(id.rawValue.uuidString) already has a prompt in flight (\(type(of: inFlight))); dropping \(prompt.count) chars")
            return
        }
        record.lastActivityAt = Date()
        records[id] = record
        persist(record)

        let runner = makeRunner(record)
        runners[id] = runner
        let threadId = Self.threadId(for: id)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try runner.run(prompt: prompt) { event in
                    let bound = event.withThreadId(threadId)
                    DispatchQueue.main.async { self?.deliver(bound, to: id) }
                }
            } catch {
                let message = String(describing: error)
                fputs("AgentSupervisor: runner failed for agent \(id.rawValue.uuidString): \(message)\n", stderr)
                DispatchQueue.main.async {
                    self?.deliver(.runtimeError(threadId: threadId, message: message), to: id)
                }
            }
            DispatchQueue.main.async { self?.clearRunner(runner, for: id) }
        }
    }

    /// Terminates the in-flight runner and records the stop on the agent's stream.
    /// `.sessionStateChanged(.stopped)` is what the tile's status derivation reads,
    /// and it is persist-worthy, so the stored record's `lastActivityAt` moves too.
    func stop(_ id: AgentID) {
        guard records[id] != nil else {
            warn("AgentSupervisor.stop: no agent \(id.rawValue.uuidString)")
            return
        }
        runners[id]?.stop()
        runners[id] = nil
        deliver(.sessionStateChanged(.stopped), to: id)
    }

    /// The agent bound to a tile, if this session spawned one. In-memory only —
    /// nothing is loaded from the store at init, so this dedupes a re-wire within a
    /// launch and NOT across launches (P2A.7).
    func agent(forTile tileId: UUID) -> AgentID? {
        records.values.first(where: { $0.tileId == tileId })?.id
    }

    /// True while a prompt is in flight. Exposed for the checks and for P2A.5,
    /// which must know whether detaching a view leaves work running.
    func isRunning(_ id: AgentID) -> Bool {
        runners[id] != nil
    }

    // MARK: - Multicast

    /// Snapshot-then-tail, per `ActivityStore.subscribe()`: the buffered history is
    /// yielded before the subscriber is registered, so it cannot miss an event that
    /// arrives during attach and cannot see the tail before the history.
    func events(for id: AgentID) -> AsyncStream<AgentRuntimeEvent> {
        let replay = history[id] ?? []
        return AsyncStream { continuation in
            for event in replay {
                continuation.yield(event)
            }
            let token = UUID()
            subscribers[id, default: [:]][token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.removeSubscriber(token, for: id) }
            }
        }
    }

    func subscriberCount(for id: AgentID) -> Int {
        subscribers[id]?.count ?? 0
    }

    private func removeSubscriber(_ token: UUID, for id: AgentID) {
        subscribers[id]?.removeValue(forKey: token)
        if subscribers[id]?.isEmpty == true { subscribers.removeValue(forKey: id) }
    }

    private func deliver(_ event: AgentRuntimeEvent, to id: AgentID) {
        var buffer = history[id] ?? []
        buffer.append(event)
        if buffer.count > Self.replayCap {
            buffer.removeFirst(buffer.count - Self.replayCap)
        }
        history[id] = buffer

        if var record = records[id] {
            record.lastActivityAt = Date()
            records[id] = record
            // Only lifecycle-shaped events reach the disk. `contentDelta` arrives
            // per token and every write is an AtomicWriter write (temp file +
            // fsync + read-back), so persisting all of them would put a synchronous
            // fsync per token on the main thread.
            if Self.isPersistWorthy(event) { persist(record) }
        }

        for continuation in (subscribers[id] ?? [:]).values {
            continuation.yield(event)
        }
    }

    nonisolated static func isPersistWorthy(_ event: AgentRuntimeEvent) -> Bool {
        switch event {
        case .sessionStateChanged, .turnStarted, .turnCompleted, .runtimeError:
            return true
        case .itemStarted, .itemCompleted, .contentDelta, .requestOpened,
             .requestResolved, .userInputRequested, .userInputResolved, .tokenUsageUpdated:
            return false
        }
    }

    private func clearRunner(_ runner: AgentRunning, for id: AgentID) {
        // Identity-checked: a `send` that started while the previous prompt was
        // finishing must not have its runner cleared by the old one's completion.
        if runners[id] === runner { runners[id] = nil }
    }

    private func persist(_ record: AgentRecord) {
        do {
            try store.upsert(record)
        } catch {
            warn("AgentSupervisor: could not persist agent \(record.id.rawValue.uuidString): \(error)")
        }
    }
}

// MARK: - Self-check

/// A runner that emits a fixed script instead of spawning Pi. `holdUntilStopped`
/// blocks `run` after the script until `stop()` arrives, which is how the stop path
/// is exercised without a real process.
final class ScriptedAgentRunner: AgentRunning, @unchecked Sendable {
    private let script: [AgentRuntimeEvent]
    private let holdUntilStopped: Bool
    private let released = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stopCountStorage = 0
    private var runCountStorage = 0
    private var completedRunStorage = 0
    private var promptsStorage: [String] = []

    init(script: [AgentRuntimeEvent], holdUntilStopped: Bool = false) {
        self.script = script
        self.holdUntilStopped = holdUntilStopped
    }

    var stopCount: Int { lock.withLock { stopCountStorage } }
    var runCount: Int { lock.withLock { runCountStorage } }
    /// Incremented only once `run` has actually RETURNED. The distinction is the
    /// point (from the cross-review): `stop` clears `runners[id]` synchronously, so
    /// `isRunning == false` proves a dictionary entry went away and nothing about
    /// the blocked call. This counter is the only witness that the runner exited.
    var completedRuns: Int { lock.withLock { completedRunStorage } }
    var prompts: [String] { lock.withLock { promptsStorage } }

    func run(prompt: String, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        lock.withLock {
            runCountStorage += 1
            promptsStorage.append(prompt)
        }
        for event in script { onEvent(event) }
        if holdUntilStopped { released.wait() }
        lock.withLock { completedRunStorage += 1 }
    }

    func stop() {
        lock.withLock { stopCountStorage += 1 }
        released.signal()
    }
}

/// Gated on `--agent-supervisor-check`.
///
/// Deterministic and offline: a `ScriptedAgentRunner` replaces Pi, so what is under
/// test is the supervisor's ownership and fan-out, not a provider. Waits go through
/// P0.8's `waitUntil`, which suspends on a main-queue timer rather than spinning a
/// nested RunLoop — the events arrive by `DispatchQueue.main.async`, which a nested
/// RunLoop starves.
@MainActor
func runAgentSupervisorChecks() async throws {
    struct CheckError: Error, CustomStringConvertible {
        let description: String
    }
    func fail(_ message: String) -> CheckError { CheckError(description: message) }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-agent-supervisor-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentStore(applicationSupportDirectory: root)
    let config = AgentModelConfig.resolvedFromDefaults()
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

    // The script is deliberately a real turn shape with DISTINCT events, so
    // "in order" is checkable and a dropped or reordered event is named.
    let scriptThread = "provider-thread"
    let script: [AgentRuntimeEvent] = [
        .sessionStateChanged(.running),
        .turnStarted(threadId: scriptThread, turnId: "t1"),
        .contentDelta(threadId: scriptThread, turnId: "t1", streamKind: .assistant, delta: "one"),
        .contentDelta(threadId: scriptThread, turnId: "t1", streamKind: .assistant, delta: "two"),
        .itemStarted(threadId: scriptThread, itemId: "i1", kind: .commandExecution, title: "ls"),
        .itemCompleted(threadId: scriptThread, itemId: "i1", kind: .commandExecution, status: .completed),
        .turnCompleted(threadId: scriptThread, turnId: "t1", outcome: .completed, errorMessage: nil),
        .sessionStateChanged(.ready)
    ]

    // MARK: 1 · two consumers, one agent, every event in order

    let runner = ScriptedAgentRunner(script: script)
    let supervisor = AgentSupervisor(store: store, makeRunner: { _ in runner })
    let agentId = supervisor.spawn(
        role: "reviewer",
        prompt: nil,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking,
        tileId: UUID()
    )
    let expected = script.map { $0.withThreadId(AgentSupervisor.threadId(for: agentId)) }

    // Both subscribers attach BEFORE the prompt, which is the tile's real ordering.
    let inboxA = EventInbox()
    let inboxB = EventInbox()
    let streamA = supervisor.events(for: agentId)
    let streamB = supervisor.events(for: agentId)
    let taskA = Task { @MainActor in for await event in streamA { inboxA.append(event) } }
    let taskB = Task { @MainActor in for await event in streamB { inboxB.append(event) } }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { supervisor.subscriberCount(for: agentId) == 2 }) else {
        throw fail("both subscribers should be registered; got \(supervisor.subscriberCount(for: agentId))")
    }

    supervisor.send("first prompt", to: agentId)
    guard await waitUntil(timeout: 10, pollInterval: 0.02, {
        inboxA.events.count == script.count && inboxB.events.count == script.count
    }) else {
        throw fail("subscribers did not both receive all \(script.count) events — A got \(inboxA.events.count), B got \(inboxB.events.count)")
    }
    if let divergence = firstDivergence(inboxA.events, expected) {
        throw fail("subscriber A received the wrong sequence \(divergence)")
    }
    if let divergence = firstDivergence(inboxB.events, expected) {
        throw fail("subscriber B received the wrong sequence \(divergence)")
    }
    // Restamping is not cosmetic: every consumer must see the AGENT's thread, not
    // the provider's. A vacuity guard, since the script uses a different one.
    guard AgentSupervisor.threadId(for: agentId) != scriptThread else {
        throw fail("the script's thread id matches the agent's, so restamping is untested")
    }
    guard case let .turnStarted(threadId, _) = inboxA.events[1], threadId == AgentSupervisor.threadId(for: agentId) else {
        throw fail("delivered events are not restamped with the agent's thread id")
    }
    guard runner.runCount == 1, runner.prompts == ["first prompt"] else {
        throw fail("the supervisor should have run the prompt exactly once; runCount \(runner.runCount), prompts \(runner.prompts)")
    }

    // MARK: 2 · the record persists, without a tile being involved

    guard let persisted = try store.load(id: agentId) else {
        throw fail("no record persisted for the spawned agent at \(store.layout.agentFile(id: agentId).path)")
    }
    guard persisted.role == "reviewer", persisted.model == config.model, persisted.thinking == config.thinking else {
        throw fail("persisted record lost its spawn parameters: role \(String(describing: persisted.role)), model \(persisted.model), thinking \(persisted.thinking)")
    }
    guard persisted.cwd == cwd.path else {
        throw fail("persisted record's cwd is \(persisted.cwd), expected \(cwd.path)")
    }
    guard supervisor.records[agentId]?.lastActivityAt ?? .distantPast > persisted.createdAt else {
        throw fail("lastActivityAt did not advance past createdAt while events were delivered")
    }
    // SPAWN itself must persist, not just the first `send`. Found by the negative
    // test: dropping `persist` from `spawn` left the assertion above green, because
    // `send` writes too — so a headless agent that is never prompted (P2A.6) would
    // exist only in memory and vanish on relaunch.
    let unpromptedId = supervisor.spawn(
        role: nil,
        prompt: nil,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking
    )
    guard let unprompted = try store.load(id: unpromptedId) else {
        throw fail("an agent spawned with no prompt was not persisted — spawn must write, not just send")
    }
    guard unprompted.tileId == nil, unprompted.role == nil else {
        throw fail("the headless spawn persisted a tile binding or role it was not given: tileId \(String(describing: unprompted.tileId)), role \(String(describing: unprompted.role))")
    }
    guard supervisor.isRunning(unpromptedId) == false else {
        throw fail("a spawn with no prompt should not start a runner")
    }

    // MARK: 3 · a LATE subscriber replays the history (snapshot-then-tail)

    let inboxC = EventInbox()
    let streamC = supervisor.events(for: agentId)
    let taskC = Task { @MainActor in for await event in streamC { inboxC.append(event) } }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { inboxC.events.count == script.count }) else {
        throw fail("a subscriber attaching after the turn should replay the history; got \(inboxC.events.count) of \(script.count)")
    }
    if let divergence = firstDivergence(inboxC.events, expected) {
        throw fail("the replayed history is not the delivered sequence \(divergence)")
    }

    // MARK: 4 · stop terminates the runner, and the record reflects it

    let blocking = ScriptedAgentRunner(script: [.turnStarted(threadId: scriptThread, turnId: "t2")], holdUntilStopped: true)
    let stopSupervisor = AgentSupervisor(store: store, makeRunner: { _ in blocking })
    let stopAgentId = stopSupervisor.spawn(
        role: nil,
        prompt: "long running",
        cwd: cwd,
        model: config.model,
        thinking: config.thinking
    )
    let inboxD = EventInbox()
    let streamD = stopSupervisor.events(for: stopAgentId)
    let taskD = Task { @MainActor in for await event in streamD { inboxD.append(event) } }
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { inboxD.events.count == 1 }) else {
        throw fail("the spawn prompt should have run: got \(inboxD.events.count) events")
    }
    guard stopSupervisor.isRunning(stopAgentId) else {
        throw fail("a blocked runner should still be held as in-flight before stop")
    }
    let beforeStop = try store.load(id: stopAgentId)?.lastActivityAt ?? .distantPast

    stopSupervisor.stop(stopAgentId)
    guard blocking.stopCount == 1 else {
        throw fail("stop did not reach the runner; stopCount \(blocking.stopCount)")
    }
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { inboxD.events.contains(.sessionStateChanged(.stopped)) }) else {
        throw fail("subscribers did not see .sessionStateChanged(.stopped) after stop")
    }
    // The blocked `run` must actually RETURN, or the agent is stopped in name only.
    // Asserted on the runner's own post-return counter, not on `isRunning`: `stop`
    // clears `runners[id]` synchronously, so `isRunning == false` is true the
    // instant stop is called and proves nothing about the blocked call.
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { blocking.completedRuns == 1 }) else {
        throw fail("the blocked run() never returned after stop — completedRuns \(blocking.completedRuns)")
    }
    guard stopSupervisor.isRunning(stopAgentId) == false else {
        throw fail("the supervisor still holds a runner for a stopped agent")
    }

    // A second prompt while one is in flight must NOT replace the runner: the first
    // process would keep running, unreachable by `stop`, on the same session id.
    let concurrent = ScriptedAgentRunner(script: [], holdUntilStopped: true)
    let concurrentSupervisor = AgentSupervisor(store: store, makeRunner: { _ in concurrent })
    let busyId = concurrentSupervisor.spawn(
        role: nil,
        prompt: "occupy the runner",
        cwd: cwd,
        model: config.model,
        thinking: config.thinking
    )
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { concurrent.runCount == 1 }) else {
        throw fail("the first prompt did not start; runCount \(concurrent.runCount)")
    }
    concurrentSupervisor.send("second prompt while busy", to: busyId)
    // WAIT for the violation rather than reading `runCount` straight after `send`:
    // `run` is invoked on a background queue, so an immediate read is green even
    // when a second runner was started. Found by the negative test — deleting the
    // refusal passed until this became a windowed assertion.
    guard await waitUntil(timeout: 1.0, pollInterval: 0.02, { concurrent.runCount > 1 }) == false else {
        throw fail("a second send started a second runner for a busy agent: runCount \(concurrent.runCount), prompts \(concurrent.prompts)")
    }
    guard concurrent.prompts == ["occupy the runner"] else {
        throw fail("a second send reached the runner for a busy agent: prompts \(concurrent.prompts)")
    }
    guard concurrentSupervisor.isRunning(busyId) else {
        throw fail("the refused send dropped the in-flight runner")
    }
    concurrentSupervisor.stop(busyId)
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { concurrent.completedRuns == 1 }) else {
        throw fail("the occupying runner did not exit after stop")
    }
    guard let afterStop = try store.load(id: stopAgentId)?.lastActivityAt else {
        throw fail("no persisted record for the stopped agent")
    }
    guard afterStop > beforeStop else {
        // Reference intervals, not formatted dates: the difference is sub-second, so
        // a `Date` description would print the two as the same string.
        throw fail("the stored record did not reflect the stop: lastActivityAt \(afterStop.timeIntervalSinceReferenceDate) is not after \(beforeStop.timeIntervalSinceReferenceDate)")
    }

    // MARK: 5 · the production path still constructs a PiAgentRunner…

    guard let record = supervisor.records[agentId] else {
        throw fail("the supervisor lost the record it spawned")
    }
    guard AgentSupervisor.piRunner(for: record) is PiAgentRunner else {
        throw fail("the default runner factory does not produce a PiAgentRunner")
    }

    // MARK: …6 · and no VIEW constructs one

    let (constructionSites, scannedFiles) = try piRunnerConstructionSites()
    guard scannedFiles > 0 else {
        throw fail("the source scan found no Swift files — it is looking in the wrong place")
    }
    guard constructionSites == ["App/AgentSupervisor.swift"] else {
        throw fail("PiAgentRunner is constructed outside AgentSupervisor.swift: \(constructionSites.sorted()) (the supervisor owns the runner; a view that makes its own is a second owner and will double-spawn)")
    }

    // MARK: 7 · a TILE is a subscriber (P2A.4), and detaching it leaves the agent running

    let tileReport = try await checkTileIsASubscriber(store: store, config: config, cwd: cwd, fail: fail)

    for task in [taskA, taskB, taskC, taskD] { task.cancel() }
    print("AgentSupervisor: \(script.count) events fanned out to 2 live + 1 late subscriber, spawn persisted headless, stop made a blocked run() return, a send on a busy agent refused, \(scannedFiles) source files scanned for stray runner construction; \(tileReport)")
}

/// A runner factory that hands out one scripted runner per `send`, in order. The
/// supervisor makes a new runner per prompt, so a single shared script cannot say
/// "this turn emits three events and the next two".
@MainActor
private final class ScriptedRunnerQueue {
    private(set) var handedOut: [ScriptedAgentRunner] = []
    private var pending: [ScriptedAgentRunner]

    init(_ runners: [ScriptedAgentRunner]) { pending = runners }

    func next(_ record: AgentRecord) -> AgentRunning {
        let runner = pending.isEmpty ? ScriptedAgentRunner(script: []) : pending.removeFirst()
        handedOut.append(runner)
        return runner
    }
}

/// The tile as a pure view over an agent's stream: attach replays the history,
/// live events keep arriving, and `detach()` cancels the subscription and nothing
/// else. Drives the real `ManagedAgentTileNSView` — a stand-in would prove nothing
/// about the view that ships.
///
/// Seven negative tests observed red at exit 1 with the final code, six of them
/// production edits to `ManagedAgentTileNSView.attach/detach`:
/// · `let bound = event` (no rebinding to the tile's thread) →
///   `FAIL: the replayed history did not reach the transcript:` (the model filters
///   on its own thread, so an unbound event renders nothing)
/// · the `attachedAgentID == agentID` early return deleted — re-attach WHILE STILL
///   ATTACHED, which is the live re-wire the app's three call sites can do →
///   `FAIL: re-attaching the same agent replayed its history again: 6 events`
/// · `detach()` no longer cancelling →
///   `FAIL: detach did not remove the tile's subscription; 2 subscribers remain`
/// · `if replayingIntoAProjection { resetProjection() }` deleted →
///   `FAIL: attaching to a second agent did not reset the projection: the tile
///   holds 8 events, expected 2`
/// · that same guard narrowed to `projectedAgentID != agentID`, which is what the
///   first draft shipped and the cross-review caught — DETACH then re-attach the
///   SAME agent →
///   `FAIL: re-attaching after a detach did not replay the history exactly once:
///   the tile holds 13 events, the agent's history is 7`
/// · `resetProjection` leaving the stack's arranged subviews in place →
///   `FAIL: the card stack holds 4 views for 2 cards — a reset left stale arranged
///   subviews`
/// · and, at this call site, a `supervisor.stop(agentId)` next to `tile.detach()`
///   standing in for a detach that killed its agent →
///   `FAIL: detaching the tile stopped the agent — a tile is one view of an agent,
///   not its owner`
@MainActor
private func checkTileIsASubscriber(
    store: AgentStore,
    config: AgentModelConfig.Resolution,
    cwd: URL,
    fail: (String) -> Error
) async throws -> String {
    let provider = "provider-thread"
    // Turn 1: three events, one of them assistant text, so "shows all 3" is
    // checkable as rendered content and not only as a count.
    let turnOne: [AgentRuntimeEvent] = [
        .sessionStateChanged(.running),
        .contentDelta(threadId: provider, turnId: "t1", streamKind: .assistant, delta: "alpha"),
        .turnCompleted(threadId: provider, turnId: "t1", outcome: .completed, errorMessage: nil)
    ]
    // Turn 2: two more.
    let turnTwo: [AgentRuntimeEvent] = [
        .contentDelta(threadId: provider, turnId: "t2", streamKind: .assistant, delta: "beta"),
        .turnCompleted(threadId: provider, turnId: "t2", outcome: .completed, errorMessage: nil)
    ]
    // Turn 3 blocks, so the agent is provably still working when the tile detaches.
    let blocking = ScriptedAgentRunner(script: [.turnStarted(threadId: provider, turnId: "t3")], holdUntilStopped: true)
    let queue = ScriptedRunnerQueue([
        ScriptedAgentRunner(script: turnOne),
        ScriptedAgentRunner(script: turnTwo),
        blocking
    ])
    let supervisor = AgentSupervisor(store: store, makeRunner: { queue.next($0) })
    let tileId = UUID()
    let agentId = supervisor.spawn(
        role: nil,
        prompt: nil,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking,
        tileId: tileId
    )
    // An independent subscriber, so "the supervisor still receives events" after
    // detach is observed on the stream rather than inferred from the runner.
    let probe = EventInbox()
    let probeStream = supervisor.events(for: agentId)
    let probeTask = Task { @MainActor in for await event in probeStream { probe.append(event) } }
    defer { probeTask.cancel() }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { supervisor.subscriberCount(for: agentId) == 1 }) else {
        throw fail("the probe subscriber did not register")
    }

    // The turn runs with NO tile attached — the history the tile will replay has to
    // exist before it does, or "replay" is indistinguishable from "tail".
    supervisor.send("first prompt", to: agentId)
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { probe.events.count == turnOne.count }) else {
        throw fail("turn 1 did not complete before the tile attached; probe has \(probe.events.count) of \(turnOne.count)")
    }

    let tile = ManagedAgentTileNSView(tile: Tile(
        id: tileId,
        kind: .managedAgent,
        title: "agent",
        frame: TileFrame(x: 0, y: 0, width: 520, height: 320),
        zPosition: .fromLegacyRank(1),
        runtimeRef: nil,
        metadata: TileMetadata(launchProfileId: "managed")
    ))
    tile.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
    guard tile.ingestedEvents.isEmpty else {
        throw fail("a fresh tile already holds \(tile.ingestedEvents.count) events")
    }

    tile.attach(agentID: agentId, supervisor: supervisor)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { tile.ingestedEvents.count == turnOne.count }) else {
        throw fail("attaching a tile did not replay the agent's history: the tile holds \(tile.ingestedEvents.count) of \(turnOne.count) events")
    }
    guard tile.attachedAgentID == agentId else {
        throw fail("the tile did not record which agent it is attached to")
    }
    // Replay is not a counter: the transcript has to RENDER the history.
    guard tile.qaTranscriptText.contains("alpha") else {
        throw fail("the replayed history did not reach the transcript: \(tile.qaTranscriptText)")
    }
    // Rebinding at the boundary (the model filters on the tile's own thread), so a
    // supervisor-stamped event must arrive carrying the TILE's thread id.
    guard AgentSupervisor.threadId(for: agentId) != tile.wiringThreadId else {
        throw fail("the agent's thread id equals the tile's, so the rebinding is untested")
    }
    guard case let .turnCompleted(boundThread, _, _, _) = tile.ingestedEvents[2], boundThread == tile.wiringThreadId else {
        throw fail("ingested events were not rebound to the tile's thread id: \(tile.ingestedEvents[2])")
    }
    // Idempotent: re-attaching the same agent must not replay a second time.
    tile.attach(agentID: agentId, supervisor: supervisor)
    guard await waitUntil(timeout: 1.0, pollInterval: 0.02, { tile.ingestedEvents.count != turnOne.count }) == false else {
        throw fail("re-attaching the same agent replayed its history again: \(tile.ingestedEvents.count) events")
    }
    guard supervisor.subscriberCount(for: agentId) == 2 else {
        throw fail("expected the probe plus one tile subscription; got \(supervisor.subscriberCount(for: agentId))")
    }

    // Live tail: two more events reach the attached tile.
    supervisor.send("second prompt", to: agentId)
    let afterTurnTwo = turnOne.count + turnTwo.count
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { tile.ingestedEvents.count == afterTurnTwo }) else {
        throw fail("live events did not continue to arrive: the tile holds \(tile.ingestedEvents.count) of \(afterTurnTwo)")
    }
    guard tile.qaTranscriptText.contains("alpha"), tile.qaTranscriptText.contains("beta") else {
        throw fail("the transcript lost the replay or missed the tail: \(tile.qaTranscriptText)")
    }

    // Detach while a prompt is IN FLIGHT, which is the case the locked decision is
    // about: closing a view of a working agent must not kill it.
    supervisor.send("third prompt", to: agentId)
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { tile.ingestedEvents.count == afterTurnTwo + 1 }) else {
        throw fail("the third turn's first event did not reach the tile")
    }
    guard supervisor.isRunning(agentId) else {
        throw fail("the blocking runner should be in flight before the tile detaches")
    }

    tile.detach()
    guard tile.attachedAgentID == nil else {
        throw fail("detach left the tile bound to \(String(describing: tile.attachedAgentID))")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { supervisor.subscriberCount(for: agentId) == 1 }) else {
        throw fail("detach did not remove the tile's subscription; \(supervisor.subscriberCount(for: agentId)) subscribers remain")
    }
    guard supervisor.isRunning(agentId) else {
        throw fail("detaching the tile stopped the agent — a tile is one view of an agent, not its owner")
    }
    guard blocking.completedRuns == 0, blocking.stopCount == 0 else {
        throw fail("detaching the tile reached the runner: completedRuns \(blocking.completedRuns), stopCount \(blocking.stopCount)")
    }

    // The agent's stream is still live, and the detached tile is off it.
    let tileEventsAtDetach = tile.ingestedEvents.count
    let probeAtDetach = probe.events.count
    supervisor.stop(agentId)
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { probe.events.count > probeAtDetach }) else {
        throw fail("the supervisor stopped delivering events to its remaining subscriber after the tile detached")
    }
    guard probe.events.last == .sessionStateChanged(.stopped) else {
        throw fail("the remaining subscriber did not see the stop: \(String(describing: probe.events.last))")
    }
    guard tile.ingestedEvents.count == tileEventsAtDetach else {
        throw fail("a detached tile kept ingesting: \(tile.ingestedEvents.count) events, was \(tileEventsAtDetach)")
    }
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { blocking.completedRuns == 1 }) else {
        throw fail("the agent's blocked run() never returned after stop")
    }

    // Re-attaching the SAME agent after a detach (from the cross-review, which found
    // this double-ingesting): the replay is the whole conversation and the tile still
    // holds the part of it that it ingested before detaching, so `attach` has to
    // reset the projection rather than append a second copy of it.
    let historyCount = probe.events.count
    tile.attach(agentID: agentId, supervisor: supervisor)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { tile.ingestedEvents.count == historyCount }) else {
        throw fail("re-attaching after a detach did not replay the history exactly once: the tile holds \(tile.ingestedEvents.count) events, the agent's history is \(historyCount)")
    }
    let alphaCards = tile.qaTranscriptText.components(separatedBy: "alpha").count - 1
    guard alphaCards == 1 else {
        throw fail("re-attaching after a detach duplicated the transcript (\(alphaCards) copies of the first reply): \(tile.qaTranscriptText)")
    }
    // The reset has to reach the view hierarchy, not just the model behind it.
    guard tile.qaRenderedCardCount == tile.transcriptCardCount else {
        throw fail("the card stack holds \(tile.qaRenderedCardCount) views for \(tile.transcriptCardCount) cards — a reset left stale arranged subviews")
    }
    tile.detach()

    // Attaching the SAME view to a DIFFERENT agent shows that agent's conversation,
    // not both of them concatenated.
    let otherTurn: [AgentRuntimeEvent] = [
        .contentDelta(threadId: provider, turnId: "t1", streamKind: .assistant, delta: "gamma"),
        .turnCompleted(threadId: provider, turnId: "t1", outcome: .completed, errorMessage: nil)
    ]
    let otherQueue = ScriptedRunnerQueue([ScriptedAgentRunner(script: otherTurn)])
    let otherSupervisor = AgentSupervisor(store: store, makeRunner: { otherQueue.next($0) })
    let otherAgentId = otherSupervisor.spawn(
        role: nil,
        prompt: "other prompt",
        cwd: cwd,
        model: config.model,
        thinking: config.thinking,
        tileId: tileId
    )
    let otherProbe = EventInbox()
    let otherStream = otherSupervisor.events(for: otherAgentId)
    let otherTask = Task { @MainActor in for await event in otherStream { otherProbe.append(event) } }
    defer { otherTask.cancel() }
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { otherProbe.events.count == otherTurn.count }) else {
        throw fail("the second agent's turn did not complete; got \(otherProbe.events.count) of \(otherTurn.count)")
    }
    tile.attach(agentID: otherAgentId, supervisor: otherSupervisor)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { tile.ingestedEvents.count == otherTurn.count }) else {
        throw fail("attaching to a second agent did not reset the projection: the tile holds \(tile.ingestedEvents.count) events, expected \(otherTurn.count)")
    }
    guard tile.qaTranscriptText.contains("gamma"), !tile.qaTranscriptText.contains("alpha"), !tile.qaTranscriptText.contains("beta") else {
        throw fail("the tile mixed two agents' transcripts: \(tile.qaTranscriptText)")
    }
    tile.detach()

    return "a tile replayed \(turnOne.count) history events on attach, tailed \(turnTwo.count) more, detached without stopping an in-flight turn, and re-attached to a second agent without mixing transcripts"
}

/// Main-actor collector for a subscriber task. A class so the collecting closure
/// does not have to be `inout`-capturing.
@MainActor
final class EventInbox {
    private(set) var events: [AgentRuntimeEvent] = []
    func append(_ event: AgentRuntimeEvent) { events.append(event) }
}

/// `nil` when the two sequences match, otherwise the first index that differs and
/// both labels there — the useful half of a sequence mismatch, since a full dump of
/// two eight-event arrays makes the reader do the diff.
@MainActor
private func firstDivergence(_ actual: [AgentRuntimeEvent], _ expected: [AgentRuntimeEvent]) -> String? {
    guard actual != expected else { return nil }
    for index in 0..<max(actual.count, expected.count) {
        let got = index < actual.count ? eventLabel(actual[index]) : "<nothing>"
        let want = index < expected.count ? eventLabel(expected[index]) : "<nothing>"
        if got != want {
            return "— at index \(index) got \(got), expected \(want) (\(actual.count) of \(expected.count) events)"
        }
    }
    return "— \(actual.count) events vs \(expected.count) expected"
}

/// A short label per event, so a sequence mismatch prints readably. The thread id
/// is part of the label because restamping is one of the things under test — a
/// label without it turns "the wrong thread" into an unexplained mismatch.
private func eventLabel(_ event: AgentRuntimeEvent) -> String {
    switch event {
    case let .sessionStateChanged(state): return "session:\(state.rawValue)"
    case let .turnStarted(threadId, turnId): return "turnStarted:\(turnId)@\(threadId)"
    case let .turnCompleted(threadId, turnId, outcome, _): return "turnCompleted:\(turnId):\(outcome.rawValue)@\(threadId)"
    case let .itemStarted(threadId, itemId, _, _): return "itemStarted:\(itemId)@\(threadId)"
    case let .itemCompleted(threadId, itemId, _, status): return "itemCompleted:\(itemId):\(status.rawValue)@\(threadId)"
    case let .contentDelta(threadId, _, _, delta): return "delta:\(delta)@\(threadId)"
    case let .requestOpened(threadId, requestId, _): return "requestOpened:\(requestId)@\(threadId)"
    case let .requestResolved(threadId, requestId, _): return "requestResolved:\(requestId)@\(threadId)"
    case let .userInputRequested(threadId, requestId, _): return "userInputRequested:\(requestId)@\(threadId)"
    case let .userInputResolved(threadId, requestId): return "userInputResolved:\(requestId)@\(threadId)"
    case let .tokenUsageUpdated(threadId, snapshot): return "tokenUsage:\(snapshot.inputTokens)/\(snapshot.outputTokens)@\(threadId)"
    case let .runtimeError(threadId, message): return "runtimeError:\(message)@\(threadId ?? "-")"
    }
}

/// Every file under `Sources/ContinuumRevived` that constructs a `PiAgentRunner`,
/// as paths relative to that root. Source-scanned for the same reason
/// `UIProbeAppearance.declaredConformers()` is: Swift cannot enumerate this at
/// runtime, the matrix runs from the repo root, and a missing directory is a loud
/// failure rather than a silent pass. The done-criterion "no `PiAgentRunner` is
/// constructed by a view" is otherwise only assertable by reading the diff.
private func piRunnerConstructionSites() throws -> (sites: Set<String>, scannedFiles: Int) {
    struct ScanError: Error, CustomStringConvertible { let description: String }
    let scanRoot = "Sources/ContinuumRevived"
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let root = cwd.appendingPathComponent(scanRoot, isDirectory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw ScanError(description: "no \(scanRoot) directory at \(root.path) (working directory \(cwd.path)) — run this check from the repo root")
    }
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
        throw ScanError(description: "could not enumerate \(root.path)")
    }
    // `PiAgentRunner(config:` and `PiAgentRunner.init(` — construction, not the
    // type being named in a signature, a comment or an `is` test.
    let pattern = try NSRegularExpression(pattern: "PiAgentRunner\\s*(\\.init)?\\s*\\(")
    var sites: Set<String> = []
    var scanned = 0
    for case let url as URL in walker where url.pathExtension == "swift" {
        let source = try String(contentsOf: url, encoding: .utf8)
        scanned += 1
        let stripped = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        guard pattern.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)) != nil else { continue }
        let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
        sites.insert(relative)
    }
    return (sites, scanned)
}

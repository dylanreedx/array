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
// · Nothing is restored at INIT. `restore()` (P2A.7) is an explicit call the app
//   makes at boot, before it walks the canvas, so a test can construct a supervisor
//   over a populated store and still observe the pre-restore state.
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
    /// P2C.1's `git worktree` wrapper, used only by the isolated `spawn`. Not
    /// injectable: the checks exercise the failure path with a real failure (a `cwd`
    /// that is not a repository), so a fake would test less than the real thing.
    private let worktrees = WorktreeManager()

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

    // MARK: - Restore (P2A.7)

    /// What one `restore()` adopted, so the caller reports numbers instead of
    /// guessing at them.
    struct RestoreReport {
        /// Adopted into `records`, in `AgentStore.loadAll()` order.
        var restored: [AgentID] = []
        /// Records whose `cwd` no longer exists on disk. Marked, not adopted, and
        /// never deleted — the directory may be a detached worktree that comes back,
        /// and throwing away a user's agent because a path moved is not this call's
        /// decision to make.
        var stale: [AgentID] = []
        /// Already live in this session, so the in-memory copy was left alone.
        var skipped: [AgentID] = []
    }

    /// The agents this supervisor adopted from a previous launch. Read by
    /// `wireManagedAgentTile`, which shows a "previous session" notice for them: the
    /// desktop transcript lives only in the view, so a restored agent's tile is empty
    /// even though its conversation is not.
    private(set) var restoredIDs: Set<AgentID> = []
    /// Records `restore()` refused to adopt because their project root is gone. Kept
    /// so the Phase 3 inbox can surface them rather than have them silently missing.
    private(set) var staleIDs: Set<AgentID> = []

    /// Adopts every record `AgentStore` holds into `records`.
    ///
    /// NO PROVIDER PROCESS IS STARTED, which is the whole shape of this method: a
    /// relaunched agent is idle until the user sends a prompt, and auto-resuming N
    /// processes at launch is both surprising and expensive. Nothing is lost by
    /// waiting — Pi's `--session-id` is derived from the agent id (`sessionId(for:)`),
    /// so the next prompt continues the same conversation.
    ///
    /// A record whose `cwd` no longer exists is MARKED AND SKIPPED (the packet's
    /// watch-out): adopting it would put an agent in the inbox whose every `send`
    /// spawns a process into a missing directory.
    @discardableResult
    func restore(fileManager: FileManager = .default) -> RestoreReport {
        var report = RestoreReport()
        let stored: [AgentRecord]
        do {
            stored = try store.loadAll()
        } catch {
            warn("AgentSupervisor.restore: could not read the agent store: \(error)")
            return report
        }
        for record in stored {
            // An agent this session already owns wins over the stored copy: `records`
            // is the live one and the store trails it by at most one persist. This is
            // also what makes `restore()` safe to call twice.
            if records[record.id] != nil {
                report.skipped.append(record.id)
                continue
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: record.cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
                staleIDs.insert(record.id)
                report.stale.append(record.id)
                warn("AgentSupervisor.restore: skipping agent \(record.id.rawValue.uuidString) — its project root \(record.cwd) no longer exists")
                continue
            }
            records[record.id] = record
            // A root that came back stops being stale. Without this an agent marked
            // on an earlier sweep would read as both stale and live to the Phase 3
            // inbox (from the cross-review).
            staleIDs.remove(record.id)
            restoredIDs.insert(record.id)
            report.restored.append(record.id)
        }
        return report
    }

    /// True for an agent that came back from a previous launch rather than being
    /// spawned in this one. A durable fact about the agent: it stays true once the
    /// agent runs again.
    func wasRestored(_ id: AgentID) -> Bool { restoredIDs.contains(id) }

    /// Whether a view attaching to this agent should show the "previous session"
    /// placeholder: it came back from a previous launch AND has produced nothing
    /// since, so the replay it is about to receive is empty.
    ///
    /// Narrower than `wasRestored` on purpose (from the cross-review). A restored
    /// agent that has since been prompted has a real transcript to replay, and a tile
    /// re-wired to it — P2A.5's re-attach, Phase 3's "open in tile" — would otherwise
    /// print the placeholder underneath it.
    func needsPreviousSessionNotice(_ id: AgentID) -> Bool {
        restoredIDs.contains(id) && (history[id]?.isEmpty ?? true)
    }

    // MARK: - Lifecycle

    /// Creates an agent, persists it, and (when `prompt` is non-empty) runs that
    /// first prompt. `tileId` is a VIEW BINDING, not identity — `nil` is a headless
    /// agent (P2A.6).
    ///
    /// The agent works in `cwd` — today's behaviour, and the unchanged default. The
    /// isolated form below is a separate, THROWING entry point rather than a defaulted
    /// `isolated:` parameter on this one: only isolation can fail, and folding it in
    /// here would make every existing caller handle an error its call can never raise.
    func spawn(
        role: String?,
        prompt: String?,
        cwd: URL,
        model: String,
        thinking: String,
        projectId: UUID? = nil,
        tileId: UUID? = nil
    ) -> AgentID {
        makeAgent(
            id: AgentID(rawValue: UUID()),
            role: role,
            prompt: prompt,
            cwd: cwd,
            worktreeBranch: nil,
            model: model,
            thinking: thinking,
            projectId: projectId,
            tileId: tileId
        )
    }

    /// P2C.2 — spawn that can opt into its own checkout.
    ///
    /// `isolated: true` runs `git worktree add` against `cwd` (the project root) and
    /// gives the agent `<repo>/.worktrees/<slug>` on `agent/<slug>`: the record's `cwd`
    /// IS the worktree, so `piRunner(for:)` — which reads `record.cwd` — starts Pi
    /// there, and `worktreeBranch` records which branch the work lands on. `false` is
    /// exactly the call above.
    ///
    /// A worktree that cannot be created FAILS THE SPAWN. No agent, no record, no
    /// fallback to the main checkout: falling back would silently put a supposedly
    /// isolated agent in the shared tree, which is the clobbering 2C exists to
    /// prevent, and the caller would never learn it.
    func spawn(
        role: String?,
        prompt: String?,
        cwd: URL,
        model: String,
        thinking: String,
        projectId: UUID? = nil,
        tileId: UUID? = nil,
        isolated: Bool
    ) throws -> AgentID {
        // The id is minted HERE, before anything is created, because the slug is
        // derived from it — `WorktreeManager.slug` id-suffixes so two agents given the
        // same role and prompt do not land on one directory and one branch.
        let id = AgentID(rawValue: UUID())
        var workingDirectory = cwd
        var branch: String?
        if isolated {
            let worktree = try worktrees.add(
                repo: cwd,
                slug: WorktreeManager.slug(role: role, prompt: prompt, id: id)
            )
            workingDirectory = worktree.path
            branch = worktree.branch
        }
        return makeAgent(
            id: id,
            role: role,
            prompt: prompt,
            cwd: workingDirectory,
            worktreeBranch: branch,
            model: model,
            thinking: thinking,
            projectId: projectId,
            tileId: tileId
        )
    }

    private func makeAgent(
        id: AgentID,
        role: String?,
        prompt: String?,
        cwd: URL,
        worktreeBranch: String?,
        model: String,
        thinking: String,
        projectId: UUID?,
        tileId: UUID?
    ) -> AgentID {
        let now = Date()
        let record = AgentRecord(
            id: id,
            displayName: role ?? model,
            role: role,
            model: model,
            thinking: thinking,
            cwd: cwd.path,
            worktreeBranch: worktreeBranch,
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

    /// Stops every agent with a prompt in flight. The app calls this when it quits
    /// (`applicationWillTerminate`), which is P2A.6's watch-out: a headless agent has
    /// no tile to close and no surface to stop it from until the Phase 3 inbox, so
    /// without this its Pi process outlives the session that started it. Iterates a
    /// snapshot because `stop` mutates `runners`.
    func stopAll() {
        for id in Array(runners.keys) { stop(id) }
    }

    // MARK: - View binding (P2A.5)

    /// Binds an agent to a tile. `AgentRecord.tileId` is WHERE THE AGENT IS BEING
    /// SHOWN, not who owns it, so this is the only thing attaching a view changes:
    /// no runner is started, stopped or replaced.
    ///
    /// One tile shows one agent, so an agent claiming a tile another agent still
    /// claims unbinds that other one. Without it `agent(forTile:)` — a
    /// `first(where:)` over the records — would answer nondeterministically after
    /// Phase 3's "open in tile" retargets a tile, and the losing agent would keep a
    /// stale binding that says it is visible when it is not.
    func attach(agentID id: AgentID, to tileId: UUID) {
        guard var record = records[id] else {
            warn("AgentSupervisor.attach: no agent \(id.rawValue.uuidString)")
            return
        }
        for (otherId, other) in records where otherId != id && other.tileId == tileId {
            var displaced = other
            displaced.tileId = nil
            records[otherId] = displaced
            persist(displaced)
        }
        guard record.tileId != tileId else { return }
        record.tileId = tileId
        records[id] = record
        persist(record)
    }

    /// Unbinds the view and NOTHING ELSE: the runner keeps running, the record stays
    /// in the store, and the agent's stream keeps delivering to its other
    /// subscribers. This is what closing a tile does (`AppDelegate.deleteTile`) —
    /// closing a tile is closing a window, not ending the work (locked decision).
    /// Ending the work is `stop(_:)`, which only a deliberate action calls.
    func detachView(agentID id: AgentID) {
        guard var record = records[id] else {
            warn("AgentSupervisor.detachView: no agent \(id.rawValue.uuidString)")
            return
        }
        guard record.tileId != nil else { return }
        record.tileId = nil
        records[id] = record
        persist(record)
    }

    /// The agent bound to a tile. Reads `records`, which `restore()` (P2A.7)
    /// repopulates from the store at boot — so this dedupes a re-wire within a launch
    /// AND across launches, and a restored tile finds its own agent instead of
    /// spawning a second one over the top of it.
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
    private var liveHandler: (@Sendable (AgentRuntimeEvent) -> Void)?

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
            liveHandler = onEvent
        }
        for event in script { onEvent(event) }
        if holdUntilStopped { released.wait() }
        lock.withLock {
            completedRunStorage += 1
            liveHandler = nil
        }
    }

    /// Emits one more event from the turn that is CURRENTLY BLOCKED in `run`, i.e.
    /// from a runner the supervisor still holds. `false` when no run is in flight, so
    /// a check cannot mistake "the agent produced nothing" for "the agent was gone".
    /// P2A.5 needs it: proving a detached agent still delivers to the supervisor takes
    /// an event produced AFTER the detach, and `send` is (correctly) refused while a
    /// prompt is in flight.
    func emit(_ event: AgentRuntimeEvent) -> Bool {
        guard let handler = lock.withLock({ liveHandler }) else { return false }
        handler(event)
        return true
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

    // MARK: 8 · closing a tile is closing a window, not ending the work (P2A.5)

    let detachReport = try await checkDetachOutlivesItsTile(store: store, config: config, cwd: cwd, fail: fail)

    // MARK: 9 · an agent exists and runs with no tile at all (P2A.6)

    let headlessReport = try await checkHeadlessAgents(store: store, config: config, cwd: cwd, fail: fail)

    // MARK: 10 · an isolated spawn works in its own checkout (P2C.2)

    let isolationReport = try await checkIsolatedSpawn(config: config, fail: fail)

    for task in [taskA, taskB, taskC, taskD] { task.cancel() }
    print("AgentSupervisor: \(script.count) events fanned out to 2 live + 1 late subscriber, spawn persisted headless, stop made a blocked run() return, a send on a busy agent refused, \(scannedFiles) source files scanned for stray runner construction; \(tileReport); \(detachReport); \(headlessReport); \(isolationReport)")
}

/// Gated on `--agent-restore-check` (P2A.7).
///
/// The records are written straight to an `AgentStore` in a temp root — nothing in
/// this process ever held them — so `restore()` is observed adopting state it did not
/// create, which is exactly what a relaunch is. The provider is a
/// `ScriptedAgentRunner` behind `ScriptedRunnerQueue`, so "no agent auto-started"
/// is asserted as ZERO RUNNERS EVER CONSTRUCTED rather than as a nil dictionary
/// entry.
///
/// What stays a source scan, and why: the two production sites are the boot walk in
/// `startWorkspace` and `wireManagedAgentTile`, both `AppDelegate` methods over a
/// live canvas, window and workspace runtime — the same reason
/// `managedAgentCloseBranchSource` and `paletteAgentSpawnBranch` are scans. The
/// ORDERING is the load-bearing half there (restore must precede the tile walk, or
/// the walk spawns a fresh agent over a surviving record), so it is asserted as a
/// line ordering, not read off the diff.
@MainActor
func runAgentRestoreChecks() async throws {
    struct CheckError: Error, CustomStringConvertible {
        let description: String
    }
    func fail(_ message: String) -> CheckError { CheckError(description: message) }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-agent-restore-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentStore(applicationSupportDirectory: root)
    let config = AgentModelConfig.resolvedFromDefaults()
    let liveCwd = FileManager.default.currentDirectoryPath
    // Never created, so the stale-record branch is about a genuinely missing
    // directory and not about permissions.
    let missingCwd = root.appendingPathComponent("gone-project-root", isDirectory: true).path

    // MARK: 1 · the previous launch's records, written by nothing in this process

    let createdAt = Date(timeIntervalSinceReferenceDate: 700_000_000)
    let tileId = UUID()
    let projectId = UUID()
    let tiled = AgentRecord(
        id: AgentID(rawValue: UUID()),
        displayName: "reviewer",
        role: "reviewer",
        model: config.model,
        thinking: config.thinking,
        cwd: liveCwd,
        projectId: projectId,
        createdAt: createdAt,
        lastActivityAt: createdAt.addingTimeInterval(30),
        tileId: tileId
    )
    let headless = AgentRecord(
        id: AgentID(rawValue: UUID()),
        displayName: config.model,
        model: config.model,
        thinking: config.thinking,
        cwd: liveCwd,
        createdAt: createdAt.addingTimeInterval(1),
        lastActivityAt: createdAt.addingTimeInterval(2)
    )
    let orphaned = AgentRecord(
        id: AgentID(rawValue: UUID()),
        displayName: "orphan",
        model: config.model,
        thinking: config.thinking,
        cwd: missingCwd,
        createdAt: createdAt.addingTimeInterval(3),
        lastActivityAt: createdAt.addingTimeInterval(4),
        tileId: UUID()
    )
    for record in [tiled, headless, orphaned] { try store.upsert(record) }

    let turn: [AgentRuntimeEvent] = [
        .sessionStateChanged(.running),
        .contentDelta(threadId: "provider-thread", turnId: "t1", streamKind: .assistant, delta: "resumed"),
        .turnCompleted(threadId: "provider-thread", turnId: "t1", outcome: .completed, errorMessage: nil)
    ]
    let queue = ScriptedRunnerQueue([ScriptedAgentRunner(script: turn)])
    let supervisor = AgentSupervisor(store: store, makeRunner: { queue.next($0) })
    // Vacuity guard: if a supervisor adopted the store at init, everything below
    // would pass while saying nothing about `restore()`.
    guard supervisor.records.isEmpty else {
        throw fail("a fresh supervisor already holds \(supervisor.records.count) record(s), so restore() is not what adopts them")
    }

    // MARK: 2 · restore adopts the live records and MARKS the stale one

    let report = supervisor.restore()
    guard report.restored.count == 2, Set(report.restored) == Set([tiled.id, headless.id]) else {
        throw fail("restore adopted \(report.restored.map { $0.rawValue.uuidString }), expected exactly the tiled and headless agents")
    }
    guard report.stale == [orphaned.id] else {
        throw fail("restore did not skip the agent whose project root is gone: stale \(report.stale.map { $0.rawValue.uuidString })")
    }
    guard report.skipped.isEmpty else {
        throw fail("restore skipped \(report.skipped.count) record(s) as already-live on a supervisor that held none")
    }
    guard supervisor.records[orphaned.id] == nil, supervisor.staleIDs.contains(orphaned.id) else {
        throw fail("the stale agent was adopted rather than marked and skipped")
    }
    // Marked, not destroyed: the directory may be a worktree that comes back.
    guard try store.load(id: orphaned.id) != nil else {
        throw fail("restore deleted the stale agent's record; skipping is not removing")
    }

    // Identity, model and role come back intact — the point of restoring at all.
    guard let restoredTiled = supervisor.records[tiled.id] else {
        throw fail("the tiled agent is not in supervisor.records after restore")
    }
    guard restoredTiled.displayName == "reviewer",
          restoredTiled.role == "reviewer",
          restoredTiled.model == config.model,
          restoredTiled.thinking == config.thinking,
          restoredTiled.cwd == liveCwd,
          restoredTiled.projectId == projectId,
          restoredTiled.createdAt == createdAt,
          restoredTiled.tileId == tileId else {
        throw fail("the restored record lost its identity: \(restoredTiled)")
    }
    guard supervisor.records[headless.id]?.tileId == nil else {
        throw fail("the headless agent came back with a tile binding: \(String(describing: supervisor.records[headless.id]?.tileId))")
    }
    // The conversation is continuable because the Pi session id is derived from the
    // agent id, which is what survived. Asserted, since "history is not lost"
    // depends on it entirely.
    guard AgentSupervisor.sessionId(for: tiled.id) == "continuum-agent-\(tiled.id.rawValue.uuidString)" else {
        throw fail("the restored agent's Pi session id is not derived from its id: \(AgentSupervisor.sessionId(for: tiled.id))")
    }
    // THE REASON THE BOOT WALK NEEDS THIS: the tile finds its own agent instead of
    // spawning a second one over the top of a surviving record.
    guard supervisor.agent(forTile: tileId) == tiled.id else {
        throw fail("a restored tile does not resolve to its agent, so wiring it would spawn a duplicate")
    }

    // MARK: 3 · nothing auto-started

    guard queue.handedOut.isEmpty else {
        throw fail("restore constructed \(queue.handedOut.count) runner(s) — a relaunched agent must be idle until prompted")
    }
    for (label, id) in [("tiled", tiled.id), ("headless", headless.id)] {
        guard supervisor.isRunning(id) == false else {
            throw fail("the restored \(label) agent has a live runner")
        }
    }

    // MARK: 4 · the tiled one gets a view, and it says where it stands

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
    tile.attach(agentID: tiled.id, supervisor: supervisor)
    guard tile.attachedAgentID == tiled.id else {
        throw fail("the restored agent's tile is not attached to it: \(String(describing: tile.attachedAgentID))")
    }
    guard supervisor.wasRestored(tiled.id) else {
        throw fail("the restored agent does not report as restored, so the tile cannot know to place the notice")
    }
    // The replay is empty by construction — the supervisor's history buffer is
    // in-memory and this process never ran a turn for this agent — which is exactly
    // why the notice exists. Asserted so "the placeholder stands in for a transcript
    // that is genuinely absent" is a measurement rather than a claim.
    guard tile.ingestedEvents.isEmpty, tile.transcriptCardCount == 0 else {
        throw fail("a restored agent replayed \(tile.ingestedEvents.count) event(s) into \(tile.transcriptCardCount) card(s); the notice would be covering for nothing")
    }
    guard supervisor.needsPreviousSessionNotice(tiled.id) else {
        throw fail("a restored agent with no history does not ask for the previous-session notice")
    }
    // The status a fresh tile starts at, and the one it must NOT keep for a restored
    // agent: `configuring` reads as "still starting up" for something that is simply
    // idle. The pre-assertion is the vacuity guard for the post-assertion below.
    guard tile.currentAgentStatus == .configuring else {
        throw fail("a just-built tile is \(tile.currentAgentStatus), so the status assertion below proves nothing")
    }
    tile.showPreviousSessionNotice()
    guard tile.currentAgentStatus == .idle else {
        throw fail("a restored agent's tile shows \(tile.currentAgentStatus) — a relaunched agent is idle until it is prompted")
    }
    guard tile.qaTranscriptText.contains(ManagedAgentTileNSView.previousSessionNoticeText) else {
        throw fail("the previous-session notice did not reach the transcript: \(tile.qaTranscriptText)")
    }
    guard tile.qaRenderedCardCount == tile.transcriptCardCount, tile.transcriptCardCount == 1 else {
        throw fail("the notice rendered \(tile.qaRenderedCardCount) view(s) for \(tile.transcriptCardCount) card(s)")
    }
    // Re-wiring the same tile happens (three call sites), so the notice must not stack.
    tile.showPreviousSessionNotice()
    guard tile.transcriptCardCount == 1 else {
        throw fail("a second notice stacked up: \(tile.transcriptCardCount) cards")
    }
    // Vacuity guard on `wasRestored`: an agent spawned in THIS session must not get
    // the notice, or every tile would carry it.
    let freshId = supervisor.spawn(
        role: nil,
        prompt: nil,
        cwd: URL(fileURLWithPath: liveCwd, isDirectory: true),
        model: config.model,
        thinking: config.thinking
    )
    guard supervisor.wasRestored(freshId) == false else {
        throw fail("an agent spawned in this session reports as restored")
    }

    // MARK: 5 · a prompt starts it, and the conversation continues from there

    let inbox = EventInbox()
    let stream = supervisor.events(for: headless.id)
    let task = Task { @MainActor in for await event in stream { inbox.append(event) } }
    defer { task.cancel() }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { supervisor.subscriberCount(for: headless.id) == 1 }) else {
        throw fail("the subscriber did not register on the restored agent")
    }
    supervisor.send("continue please", to: headless.id)
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { inbox.events.count == turn.count }) else {
        throw fail("a prompt to a restored agent did not run: \(inbox.events.count) of \(turn.count) events")
    }
    guard queue.handedOut.count == 1, queue.handedOut[0].prompts == ["continue please"] else {
        throw fail("the restored agent's prompt did not reach a runner: \(queue.handedOut.map(\.prompts))")
    }
    guard try store.load(id: headless.id)?.lastActivityAt ?? .distantPast > headless.lastActivityAt else {
        throw fail("running a restored agent did not move its stored lastActivityAt")
    }
    // Having run, it no longer wants the placeholder — but it is still a restored
    // agent. The two answers are deliberately different (see
    // `needsPreviousSessionNotice`).
    guard supervisor.wasRestored(headless.id), supervisor.needsPreviousSessionNotice(headless.id) == false else {
        throw fail("a restored agent that has produced a transcript still asks for the previous-session placeholder")
    }
    // Continuity is only real if the resumed prompt carries the SAME Pi session id,
    // and that id survives because it is derived from the agent id. Asserted on the
    // production argument builder, not on a string this check formats.
    let resumeArgs = PiAgentRunner.processArguments(
        model: config.model,
        thinking: config.thinking,
        sessionId: AgentSupervisor.sessionId(for: headless.id),
        extraArgs: [],
        prompt: "continue please"
    )
    guard resumeArgs.contains("--session-id"),
          resumeArgs.contains(AgentSupervisor.sessionId(for: headless.id)),
          !resumeArgs.contains("--no-session") else {
        throw fail("a restored agent's prompt would not resume its Pi session: \(resumeArgs)")
    }
    // HONEST LIMIT: this shows the flag and the id the production path composes. That
    // Pi then RESUMES that conversation is the provider's behaviour and needs the
    // supervised `--managed-agent-live-check`, not this leg.

    // MARK: 6 · restoring twice does not clobber the live copy

    // A doctored copy back to disk stands in for "the store is behind memory". The
    // live record must win, or a second restore would undo work this session did.
    var doctored = headless
    doctored.displayName = "stale name from disk"
    try store.upsert(doctored)
    let second = supervisor.restore()
    guard Set(second.skipped) == Set([tiled.id, headless.id, freshId]) else {
        throw fail("a second restore did not treat the live records as already-owned: skipped \(second.skipped.count)")
    }
    guard second.restored.isEmpty else {
        throw fail("a second restore re-adopted \(second.restored.count) record(s)")
    }
    guard supervisor.records[headless.id]?.displayName == config.model else {
        throw fail("a second restore clobbered the live record with the stored copy: \(String(describing: supervisor.records[headless.id]?.displayName))")
    }
    guard supervisor.records.count == 3 else {
        throw fail("restoring twice duplicated records: \(supervisor.records.count)")
    }

    // MARK: 7 · no double-restore out of the OTHER store (the packet's watch-out)

    // `ManagedAgentSessionRecord` still exists for terminal/tmux agents. A record
    // there must not conjure a supervised agent, or a tmux agent would come back
    // twice — once as a pane and once as a Pi agent.
    let projectRoot = root.appendingPathComponent("project", isDirectory: true)
    let managedSessionStore = ManagedAgentSessionStore(projectRoot: projectRoot)
    let tmuxTileId = UUID()
    try managedSessionStore.upsert(ManagedAgentSessionRecord(
        tileId: tmuxTileId,
        agentKind: .managed,
        lastSeenAt: Date()
    ))
    guard try managedSessionStore.load(tileId: tmuxTileId) != nil else {
        throw fail("the managed-session record did not persist, so the double-restore assertion proves nothing")
    }
    let beforeThirdRestore = supervisor.records.count
    _ = supervisor.restore()
    guard supervisor.records.count == beforeThirdRestore else {
        throw fail("a restore adopted records from outside AgentStore: \(supervisor.records.count) vs \(beforeThirdRestore)")
    }
    guard supervisor.agent(forTile: tmuxTileId) == nil else {
        throw fail("a ManagedAgentSessionRecord produced a supervised agent — an agent must not be restored from both stores")
    }
    tile.detach()

    // MARK: 8 · a project root that comes back stops being stale

    // The stale mark is not a tombstone: a detached worktree can be re-created, and
    // the agent must then come back like any other. Found by the cross-review, which
    // caught `staleIDs` never being cleared.
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: missingCwd, isDirectory: true),
        withIntermediateDirectories: true
    )
    let recovered = supervisor.restore()
    guard recovered.restored == [orphaned.id] else {
        throw fail("an agent whose project root came back was not adopted: restored \(recovered.restored.count), stale \(recovered.stale.count)")
    }
    guard supervisor.records[orphaned.id] != nil, supervisor.staleIDs.contains(orphaned.id) == false else {
        throw fail("the recovered agent is still marked stale, so the inbox would show it as both live and gone")
    }

    // MARK: 9 · the production wiring: restore runs BEFORE the tile walk…

    let bootLines = try continuumAppLineIndices([
        "let agentRestore = agentSupervisor.restore()",
        "for tile in canvasState.tiles {",
        "installInitialManagedAgentTile(tile, in: canvasView)"
    ])
    guard bootLines[0] < bootLines[1], bootLines[1] < bootLines[2] else {
        throw fail("restore() does not run before the boot tile walk (lines \(bootLines)) — the walk would spawn a fresh agent over each surviving record")
    }

    // …and a restored agent's tile is told to say so.
    let wiring = try paletteAgentSpawnBranch("private func wireManagedAgentTile(_ tileId: UUID) {")
    guard wiring.contains("needsPreviousSessionNotice("), wiring.contains("showPreviousSessionNotice()") else {
        throw fail("wireManagedAgentTile does not place the previous-session notice, so a restored agent renders as a blank tile:\n\(wiring)")
    }

    print("AgentRestore: 2 of 3 stored agents adopted with no runner (1 marked stale for a missing project root, adopted once that root came back), the tiled one re-resolved from its tileId and took a view showing idle plus a previous-session notice, a prompt then started it with --session-id and retired its placeholder, and restoring four times neither duplicated, clobbered, nor pulled from ManagedAgentSessionStore")
}

/// The line index of each of `needles` in `ContinuumApp.swift`, in the order given.
/// Used to assert an ORDERING between two production statements — a scan, for the
/// same reason `paletteAgentSpawnBranch` is one, and an ordering is the one property
/// a body-contains scan cannot see.
private func continuumAppLineIndices(_ needles: [String]) throws -> [Int] {
    struct ScanError: Error, CustomStringConvertible { let description: String }
    let path = "Sources/ContinuumRevived/App/ContinuumApp.swift"
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(path)
    guard let source = try? String(contentsOf: url, encoding: .utf8) else {
        throw ScanError(description: "could not read \(path) — run this check from the repo root")
    }
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map {
        $0.trimmingCharacters(in: .whitespaces)
    }
    return try needles.map { needle in
        guard let index = lines.firstIndex(of: needle) else {
            throw ScanError(description: "no line `\(needle)` in \(path) — it moved or was renamed, and this scan is now blind")
        }
        return index
    }
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

/// P2A.5: the tile-close path in full. A tile is attached to a running agent, a
/// prompt is left IN FLIGHT, and then exactly what `AppDelegate.deleteTile`'s
/// `.managedAgent` branch does happens — `supervisor.detachView` plus
/// `tile.detach()` — after which the agent must still be running, still listed with
/// no tile binding, and still delivering. Stopping is then shown to be the separate
/// deliberate action that DOES end it.
///
/// The production branch itself is source-scanned rather than executed
/// (`managedAgentCloseBranchSource`); the precedent is `piRunnerConstructionSites`
/// above. `deleteTile` is an `AppDelegate` method over a live `canvasView`,
/// `workspaceRuntime`, focus broker and canvas save — and it reads
/// `DeleteConfirmPolicy`, which under `.always` runs an `NSAlert` modal — so
/// executing it headlessly needs an app-level harness that does not exist and that
/// this packet's `## Files` does not name. What the scan buys is that "never as a
/// side effect of closing a tile" is asserted rather than claimed about a diff; what
/// it does not cover is the rest of that branch's ordering (the
/// `managedSessionStore.delete`, `removeTile`, focus recovery and canvas flush that
/// already shipped), which stays the cross-review's and the owner's to read.
///
/// Negative tests observed red at exit 1 with the final code (production edits
/// except where noted):
/// · `detachView` not clearing `record.tileId` →
///   `FAIL: closing the tile left the persisted record claiming tile …`
/// · `detachView` clearing only the in-memory record (no `persist`) →
///   the same failure, since the assertion reads the store, not `records`
/// · `agentSupervisor.stop(agentId)` added next to `detachView` in `deleteTile` →
///   `FAIL: deleteTile's .managedAgent branch stops the agent: …`
/// · the `detachView` call deleted from `deleteTile` →
///   `FAIL: deleteTile's .managedAgent branch never detaches the agent's view …`
/// · `attach` not unbinding the tile's previous agent →
///   `FAIL: two agents claim tile …`
/// · (check-local vacuity witness, from the cross-review) the reaper's stale record
///   written at `Date()` instead of `.distantPast` →
///   `FAIL: the reaper sweep did not fire, so it proves nothing about a detached
///   agent: []`
/// · `attach` not persisting →
///   `FAIL: attach did not persist the tile binding: nil, expected …` (the assertion
///   reads the STORE after every bind, so an in-memory-only binding is red at the
///   first one)
@MainActor
private func checkDetachOutlivesItsTile(
    store: AgentStore,
    config: AgentModelConfig.Resolution,
    cwd: URL,
    fail: (String) -> Error
) async throws -> String {
    let provider = "provider-thread"
    let firstTurn: [AgentRuntimeEvent] = [
        .sessionStateChanged(.running),
        .contentDelta(threadId: provider, turnId: "t1", streamKind: .assistant, delta: "alpha"),
        .turnCompleted(threadId: provider, turnId: "t1", outcome: .completed, errorMessage: nil)
    ]
    // The second turn blocks, so the agent is provably mid-work when its tile closes.
    let blocking = ScriptedAgentRunner(script: [.turnStarted(threadId: provider, turnId: "t2")], holdUntilStopped: true)
    let queue = ScriptedRunnerQueue([ScriptedAgentRunner(script: firstTurn), blocking])
    let supervisor = AgentSupervisor(store: store, makeRunner: { queue.next($0) })

    // Spawned with NO tile, then bound by `attach` — the operation P2A.5 adds, and
    // the one Phase 3's "open in tile" will reach.
    let agentId = supervisor.spawn(
        role: nil,
        prompt: nil,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking
    )
    let tileId = UUID()
    supervisor.attach(agentID: agentId, to: tileId)
    let boundTileId = try store.load(id: agentId)?.tileId
    guard boundTileId == tileId else {
        throw fail("attach did not persist the tile binding: \(String(describing: boundTileId)), expected \(tileId)")
    }
    guard supervisor.agent(forTile: tileId) == agentId else {
        throw fail("the attached agent is not the one found for its tile")
    }

    let probe = EventInbox()
    let probeStream = supervisor.events(for: agentId)
    let probeTask = Task { @MainActor in for await event in probeStream { probe.append(event) } }
    defer { probeTask.cancel() }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { supervisor.subscriberCount(for: agentId) == 1 }) else {
        throw fail("the probe subscriber did not register")
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
    tile.attach(agentID: agentId, supervisor: supervisor)

    supervisor.send("first prompt", to: agentId)
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { tile.ingestedEvents.count == firstTurn.count }) else {
        throw fail("the first turn did not reach the attached tile: \(tile.ingestedEvents.count) of \(firstTurn.count)")
    }
    // The first runner has to be RELEASED before the next send, or the second prompt
    // is (correctly) refused as concurrent: `run` returning and the supervisor
    // clearing `runners[id]` are one main-queue hop apart.
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { supervisor.isRunning(agentId) == false }) else {
        throw fail("the first turn's runner was never released")
    }
    supervisor.send("second prompt", to: agentId)
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { supervisor.isRunning(agentId) && blocking.runCount == 1 }) else {
        throw fail("the blocking turn did not start; runCount \(blocking.runCount)")
    }

    // THE CLOSE PATH, exactly as `deleteTile`'s `.managedAgent` branch runs it.
    supervisor.detachView(agentID: agentId)
    tile.detach()

    guard let afterClose = try store.load(id: agentId) else {
        throw fail("closing the tile removed the agent's record from the store — the agent is the entity, the tile is one view of it")
    }
    guard afterClose.tileId == nil else {
        throw fail("closing the tile left the persisted record claiming tile \(String(describing: afterClose.tileId))")
    }
    guard supervisor.agent(forTile: tileId) == nil else {
        throw fail("the closed tile still resolves to an agent")
    }
    guard supervisor.records[agentId] != nil else {
        throw fail("closing the tile dropped the agent from the supervisor's live records")
    }
    guard supervisor.isRunning(agentId) else {
        throw fail("closing the tile stopped the agent's in-flight turn")
    }
    guard blocking.stopCount == 0, blocking.completedRuns == 0 else {
        throw fail("closing the tile reached the runner: stopCount \(blocking.stopCount), completedRuns \(blocking.completedRuns)")
    }

    // Events still flow to the supervisor, from the turn that is still running.
    let probeAtClose = probe.events.count
    let tileAtClose = tile.ingestedEvents.count
    guard blocking.emit(.contentDelta(threadId: provider, turnId: "t2", streamKind: .assistant, delta: "beta")) else {
        throw fail("the detached agent's runner is no longer in flight, so post-close delivery is untestable")
    }
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { probe.events.count == probeAtClose + 1 }) else {
        throw fail("an event produced after the tile closed did not reach the supervisor's remaining subscriber")
    }
    guard case let .contentDelta(threadId, _, _, delta) = probe.events[probeAtClose],
          delta == "beta",
          threadId == AgentSupervisor.threadId(for: agentId) else {
        throw fail("the post-close event arrived wrong: \(probe.events[probeAtClose])")
    }
    guard tile.ingestedEvents.count == tileAtClose else {
        throw fail("the closed tile kept ingesting: \(tile.ingestedEvents.count) events, was \(tileAtClose)")
    }

    // THE IDLE REAPER (the packet's watch-out). What this asserts, exactly: a real
    // `SessionPruner.sweep()` over a maximally stale binding covering the closed
    // tile issues a tmux `detachSession` and NO kill, and leaves the detached
    // agent running with its record intact. That is the whole of the reaper's
    // mutating surface, and a supervisor agent is a Pi process the supervisor holds
    // rather than a tmux pane, so there is nothing for it to reap.
    //
    // The binding is built with the PRODUCTION expression
    // (`ZoneRuntimeController.startReaper`'s `managedSessionStore.load(tileId:)?
    // .lastSeenAt`, ~:350) over a real `ManagedAgentSessionRecord` written stale, so
    // the `lastSeenAt` path the watch-out names is the one under test. What stays
    // unexercised is `startReaper`'s own wiring, which needs a live
    // `ZoneRuntimeController`; it contributes only `sessionName`/`tileIds`/
    // `lastSeenAt` to this same sweep.
    let reaperProjectRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-agent-supervisor-reaper-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: reaperProjectRoot) }
    let managedSessionStore = ManagedAgentSessionStore(projectRoot: reaperProjectRoot)
    try managedSessionStore.upsert(ManagedAgentSessionRecord(
        tileId: tileId,
        agentKind: .managed,
        lastSeenAt: .distantPast
    ))
    guard let staleLastSeenAt = try managedSessionStore.load(tileId: tileId)?.lastSeenAt else {
        throw fail("the stale managed-session record did not persist, so the reaper binding is not the production one")
    }
    let tmux = InMemoryTmuxControl()
    let binding = SessionPruner.SessionBinding(
        sessionName: "continuum-agent-supervisor-check",
        tileIds: [tileId],
        lastSeenAt: staleLastSeenAt
    )
    let pruner = SessionPruner(
        tmuxControl: tmux,
        clock: SystemClock(),
        bindingSource: { [binding] in [binding] },
        activitySnapshotSource: { nil }
    )
    await pruner.sweep()
    guard tmux.log.contains(.detachSession(name: binding.sessionName)) else {
        throw fail("the reaper sweep did not fire, so it proves nothing about a detached agent: \(tmux.log)")
    }
    let reaperKills = tmux.log.filter {
        if case .killSession = $0 { return true }
        if case .killWindow = $0 { return true }
        return false
    }
    guard reaperKills.isEmpty else {
        throw fail("the reaper killed something for an idle binding: \(reaperKills)")
    }
    guard supervisor.isRunning(agentId), try store.load(id: agentId) != nil else {
        throw fail("an idle reaper sweep reaped a detached, still-running agent")
    }

    // Re-attach to a DIFFERENT tile: the agent is rebindable after its first view
    // closed, and the replay carries the work it did while unattached.
    let secondTileId = UUID()
    supervisor.attach(agentID: agentId, to: secondTileId)
    let reboundTileId = try store.load(id: agentId)?.tileId
    guard reboundTileId == secondTileId else {
        throw fail("re-attaching did not persist the new tile binding: \(String(describing: reboundTileId))")
    }
    let secondTile = ManagedAgentTileNSView(tile: Tile(
        id: secondTileId,
        kind: .managedAgent,
        title: "agent",
        frame: TileFrame(x: 0, y: 0, width: 520, height: 320),
        zPosition: .fromLegacyRank(1),
        runtimeRef: nil,
        metadata: TileMetadata(launchProfileId: "managed")
    ))
    secondTile.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
    let historyCount = probe.events.count
    secondTile.attach(agentID: agentId, supervisor: supervisor)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { secondTile.ingestedEvents.count == historyCount }) else {
        throw fail("a new tile did not replay the surviving agent's history: \(secondTile.ingestedEvents.count) of \(historyCount)")
    }
    guard secondTile.qaTranscriptText.contains("alpha"), secondTile.qaTranscriptText.contains("beta") else {
        throw fail("the re-attached transcript lost the work done before or after the close: \(secondTile.qaTranscriptText)")
    }

    // One tile shows one agent: binding a second agent to that tile unbinds the first.
    let otherAgentId = supervisor.spawn(
        role: nil,
        prompt: nil,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking
    )
    supervisor.attach(agentID: otherAgentId, to: secondTileId)
    let claimants = supervisor.records.values.filter { $0.tileId == secondTileId }.map(\.id)
    guard claimants == [otherAgentId] else {
        throw fail("two agents claim tile \(secondTileId): \(claimants.map { $0.rawValue.uuidString })")
    }
    guard try store.load(id: agentId)?.tileId == nil else {
        throw fail("the displaced agent's persisted record still claims the tile it lost")
    }
    guard supervisor.isRunning(agentId) else {
        throw fail("being displaced from a tile stopped the agent")
    }

    // …and stopping IS the thing that ends it — a separate deliberate action, which
    // leaves the record in place (stopped, not deleted).
    supervisor.stop(agentId)
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { blocking.completedRuns == 1 }) else {
        throw fail("stop did not make the surviving agent's blocked run() return: completedRuns \(blocking.completedRuns)")
    }
    guard blocking.stopCount == 1, supervisor.isRunning(agentId) == false else {
        throw fail("stop did not reach the runner: stopCount \(blocking.stopCount), isRunning \(supervisor.isRunning(agentId))")
    }
    guard try store.load(id: agentId) != nil else {
        throw fail("stopping an agent deleted its record; stopped is a state, not a removal")
    }
    secondTile.detach()

    // The production branch: it detaches, and it does not stop.
    let branch = try managedAgentCloseBranchSource()
    guard branch.contains("detachView(") else {
        throw fail("deleteTile's .managedAgent branch never detaches the agent's view — a closed tile would leave the agent claiming a tile that no longer exists:\n\(branch)")
    }
    guard branch.contains(".detach()") else {
        throw fail("deleteTile's .managedAgent branch does not detach the tile's own subscription:\n\(branch)")
    }
    let stopPattern = try NSRegularExpression(pattern: "\\.stop\\s*\\(")
    guard stopPattern.firstMatch(in: branch, range: NSRange(branch.startIndex..., in: branch)) == nil else {
        throw fail("deleteTile's .managedAgent branch stops the agent: closing a tile must not end the work (locked decision); stopping is a deliberate action:\n\(branch)")
    }

    return "a tile closed on an in-flight turn without stopping it (record kept, tileId cleared, events still delivered, an idle sweep could not reach it), the agent re-attached to a new tile and was displaced from it by a second agent, and only stop() ended the turn"
}

/// P2A.6: an agent exists and RUNS with no tile at all.
///
/// The count is DERIVED from `ZoneHydrationBudgetConfig.defaultMaxLiveZones`, not
/// picked: the packet's reason for headless agents is that the hydration budget caps
/// live zones, so this runs two more agents than that budget allows and each one is
/// provably mid-turn at the same time.
///
/// What "no tile exists in `CanvasState`" is asserted as: a real `CanvasState` is
/// carried alongside the supervisor and the invariant NO RECORD CLAIMS A TILE THE
/// CANVAS DOES NOT HAVE is checked both while every agent is headless and after one
/// of them is bound to a tile that IS on the canvas. A headless spawn that quietly
/// invented a `tileId` is red on it. The production palette branch is source-scanned
/// separately (`paletteAgentSpawnBranch`), because the only way a tile reaches
/// `CanvasState` in this app is `TileSpawner`, which needs a live `CanvasNSView` —
/// the same reason `managedAgentCloseBranchSource` below is a scan.
///
/// Negative tests observed red at exit 1 with the final code, production edits except
/// where noted:
/// · `spawnHeadlessAgentFromPalette` calling `spawnSupervisedAgent(tileId: UUID())` →
///   `FAIL: the headless spawn branch does not pass `tileId: nil` …`
/// · `spawnHeadlessAgentFromPalette` calling `spawnManagedAgentFromPalette()` as well →
///   `FAIL: the headless spawn branch reaches the tile spawner …`. This one PASSED
///   against the first draft of `tileMakers` and is why `spawnManagedAgent` is in the
///   pattern: delegating to the managed path creates a tile without naming the spawner.
/// · the `case .newHeadlessAgent:` dispatch deleted from `performPaletteAction` →
///   a compile error (the switch is exhaustive), so the reachability assertion below
///   is about the REGISTRY and the palette rows, which are what ⌘K reads
/// · the `agent.newHeadless` `CanvasCommand` removed →
///   `FAIL: ⌘K cannot reach a headless spawn: no agent.newHeadless in CommandRegistry`
/// · `spawnHeadlessAgentFromPalette` spawning with no prompt (the first draft, which
///   the cross-review caught: a record nothing can reach and nothing running) →
///   `FAIL: the headless spawn branch does not collect and pass a first prompt …`
/// · `spawnSupervisedAgent` passing `prompt: nil` through to the supervisor →
///   `FAIL: the app's spawn helper drops the prompt …`
/// · `applicationWillTerminate` not calling `stopAll` →
///   `FAIL: quitting does not stop the agents …`
/// · `stopAll` iterating no runners (`for id in [] `, check-local mutation) →
///   `FAIL: stopAll did not make the headless agents' blocked run()s return: 0 of 6`
/// · a headless record's `tileId` set by hand to a tile the canvas does not hold
///   (check-local vacuity witness for the invariant) →
///   `FAIL: a record claims tile … which is not on the canvas`
@MainActor
private func checkHeadlessAgents(
    store: AgentStore,
    config: AgentModelConfig.Resolution,
    cwd: URL,
    fail: (String) -> Error
) async throws -> String {
    let provider = "provider-thread"
    let headlessCount = ZoneHydrationBudgetConfig.defaultMaxLiveZones + 2

    // ⌘K reachability, executed rather than scanned: the palette builds its static
    // rows from `CommandRegistry`, so these two assertions are the whole path from
    // the command id to a row a user can pick.
    guard CommandRegistry.all().contains(where: { $0.id == "agent.newHeadless" && $0.action == .newHeadlessAgent }) else {
        throw fail("⌘K cannot reach a headless spawn: no agent.newHeadless in CommandRegistry: \(CommandRegistry.all().map(\.id))")
    }
    guard LaunchPaletteModel.makeRows(profiles: []).contains(.action(.newHeadlessAgent)) else {
        throw fail("the headless spawn command is not a palette row")
    }

    // Each agent gets its own blocking runner, so "six agents are running at once" is
    // observed on six live turns rather than inferred from six records.
    let scripted = (0 ..< headlessCount).map { _ in
        ScriptedAgentRunner(script: [.turnStarted(threadId: provider, turnId: "t1")], holdUntilStopped: true)
    }
    let queue = ScriptedRunnerQueue(scripted)
    let supervisor = AgentSupervisor(store: store, makeRunner: { queue.next($0) })

    // A canvas with NO tiles on it, carried through the whole section.
    var canvasState = CanvasState(
        viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
        tiles: [],
        groups: [],
        lastActiveTileId: nil
    )
    func expectNoRecordClaimsAMissingTile(_ stage: String) throws {
        for record in supervisor.records.values {
            guard let claimed = record.tileId else { continue }
            guard canvasState.tiles.contains(where: { $0.id == claimed }) else {
                throw fail("\(stage): a record claims tile \(claimed) which is not on the canvas (\(canvasState.tiles.count) tile(s)) — an agent must not invent a view binding")
            }
        }
    }

    var headless: [AgentID] = []
    var inboxes: [AgentID: EventInbox] = [:]
    var tasks: [Task<Void, Never>] = []
    defer { for task in tasks { task.cancel() } }
    for index in 0 ..< headlessCount {
        // Spawned WITH its first prompt, which is what the ⌘K branch does (a headless
        // agent has no compose row, so the run has to start at spawn) — not
        // spawn-then-send, which would leave "the production path never runs anything"
        // green. Found by the cross-review.
        let id = supervisor.spawn(
            role: nil,
            prompt: "work \(index)",
            cwd: cwd,
            model: config.model,
            thinking: config.thinking
        )
        headless.append(id)
        let inbox = EventInbox()
        inboxes[id] = inbox
        // Attaches after the prompt, so the event is seen through the replay — the
        // headless agent's history exists whether or not anything is listening.
        let stream = supervisor.events(for: id)
        tasks.append(Task { @MainActor in for await event in stream { inbox.append(event) } })
        guard await waitUntil(timeout: 5, pollInterval: 0.02, { supervisor.subscriberCount(for: id) == 1 }) else {
            throw fail("headless agent \(index) has no subscriber")
        }
    }

    // Running, tile-less, and persisted that way.
    for (index, id) in headless.enumerated() {
        guard await waitUntil(timeout: 10, pollInterval: 0.02, { supervisor.isRunning(id) }) else {
            throw fail("headless agent \(index) is not running — a tile-less agent must still run")
        }
        guard supervisor.records[id]?.tileId == nil else {
            throw fail("headless agent \(index) has a tile binding: \(String(describing: supervisor.records[id]?.tileId))")
        }
        guard let persisted = try store.load(id: id) else {
            throw fail("headless agent \(index) was not persisted — it must survive without a tile")
        }
        guard persisted.tileId == nil else {
            throw fail("headless agent \(index) persisted a tile binding: \(String(describing: persisted.tileId))")
        }
        // Events flow with nothing rendering them.
        guard await waitUntil(timeout: 10, pollInterval: 0.02, { inboxes[id]?.events.count == 1 }) else {
            throw fail("headless agent \(index) delivered no events: \(inboxes[id]?.events.count ?? -1)")
        }
        guard inboxes[id]?.events.first == .turnStarted(threadId: AgentSupervisor.threadId(for: id), turnId: "t1") else {
            throw fail("headless agent \(index)'s event arrived wrong: \(String(describing: inboxes[id]?.events.first))")
        }
    }
    guard canvasState.tiles.isEmpty else {
        throw fail("the canvas gained a tile from \(headlessCount) headless spawns: \(canvasState.tiles.count)")
    }
    try expectNoRecordClaimsAMissingTile("all headless")
    guard queue.handedOut.count == headlessCount, scripted.allSatisfy({ $0.runCount == 1 }) else {
        throw fail("not every headless agent got its own runner: \(queue.handedOut.count) handed out, runCounts \(scripted.map(\.runCount))")
    }

    // ATTACH A TILE to one of them (the P2A.4 path): the tile replays the history the
    // agent accumulated while it had no view.
    let subject = headless[0]
    // The queue hands runners out in `send` order, which is the spawn order above, so
    // the first one belongs to `headless[0]` — asserted by the runCount check above.
    let subjectRunner = queue.handedOut[0]
    guard subjectRunner.emit(.contentDelta(threadId: provider, turnId: "t1", streamKind: .assistant, delta: "headless work")) else {
        throw fail("the subject agent's runner is not in flight, so its history cannot grow before the tile attaches")
    }
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { inboxes[subject]?.events.count == 2 }) else {
        throw fail("the headless agent's second event never arrived: \(inboxes[subject]?.events.count ?? -1)")
    }
    let tileId = UUID()
    let tile = Tile(
        id: tileId,
        kind: .managedAgent,
        title: "agent",
        frame: TileFrame(x: 0, y: 0, width: 520, height: 320),
        zPosition: .fromLegacyRank(1),
        runtimeRef: nil,
        metadata: TileMetadata(launchProfileId: "managed")
    )
    canvasState.tiles.append(tile)
    let view = ManagedAgentTileNSView(tile: tile)
    view.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
    supervisor.attach(agentID: subject, to: tileId)
    view.attach(agentID: subject, supervisor: supervisor)
    let historyCount = inboxes[subject]?.events.count ?? 0
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { view.ingestedEvents.count == historyCount }) else {
        throw fail("attaching a tile to a headless agent did not replay its history: the tile holds \(view.ingestedEvents.count) of \(historyCount)")
    }
    guard view.qaTranscriptText.contains("headless work") else {
        throw fail("the work the agent did while headless did not reach the transcript: \(view.qaTranscriptText)")
    }
    guard try store.load(id: subject)?.tileId == tileId else {
        throw fail("attaching a tile to a headless agent did not persist the binding")
    }
    try expectNoRecordClaimsAMissingTile("one attached")
    guard canvasState.tiles.count == 1, supervisor.records.count >= headlessCount else {
        throw fail("\(supervisor.records.count) agent(s) against \(canvasState.tiles.count) tile(s) — the point of a headless agent is that those two numbers are independent")
    }
    view.detach()

    // STOPPABILITY (the packet's watch-out): a headless agent has no tile to close,
    // so `stopAll` — which the app runs on quit — is the only thing that can reach
    // its process. Asserted on the runners' own post-return counter, so it proves the
    // blocked `run()`s exited rather than that a dictionary was emptied.
    supervisor.stopAll()
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { scripted.allSatisfy { $0.completedRuns == 1 } }) else {
        throw fail("stopAll did not make the headless agents' blocked run()s return: \(scripted.filter { $0.completedRuns == 1 }.count) of \(headlessCount)")
    }
    guard scripted.allSatisfy({ $0.stopCount == 1 }) else {
        throw fail("stopAll did not reach every runner: \(scripted.map(\.stopCount))")
    }
    guard headless.allSatisfy({ supervisor.isRunning($0) == false }) else {
        throw fail("the supervisor still holds a runner after stopAll")
    }
    for (index, id) in headless.enumerated() {
        guard try store.load(id: id) != nil else {
            throw fail("stopAll deleted headless agent \(index)'s record; stopped is a state, not a removal")
        }
    }

    // The production wiring: the palette branch spawns WITHOUT a tile, the managed
    // branch (the vacuity guard for the same patterns) spawns WITH one, and quitting
    // stops the agents.
    let headlessBranch = try paletteAgentSpawnBranch("private func spawnHeadlessAgentFromPalette() {")
    let managedBranch = try paletteAgentSpawnBranch("private func spawnManagedAgentFromPalette() {")
    // `spawnManagedAgent` is in the pattern because of the negative test: a headless
    // branch that simply CALLS the managed one creates a tile without naming the
    // spawner, and the first draft of this pattern passed that mutation.
    let tileMakers = try NSRegularExpression(pattern: "tileSpawner|spawner\\.|spawnManagedAgent|wireManagedAgentTile|install\\(tileView")
    func makesATile(_ body: String) -> Bool {
        tileMakers.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil
    }
    guard makesATile(managedBranch) else {
        throw fail("the managed spawn branch matches none of the tile-creating patterns, so the check below proves nothing:\n\(managedBranch)")
    }
    guard !makesATile(headlessBranch) else {
        throw fail("the headless spawn branch reaches the tile spawner — a headless agent is one with no tile:\n\(headlessBranch)")
    }
    guard headlessBranch.contains("tileId: nil") else {
        throw fail("the headless spawn branch does not pass `tileId: nil`:\n\(headlessBranch)")
    }
    // …and it must actually RUN. `spawn` only starts a runner for a non-empty prompt,
    // so a branch that spawns with `prompt: nil` would leave a record no surface can
    // reach and nothing running — the done-criterion is "a RUNNING agent with no
    // tile". The cross-review caught exactly that in the first draft.
    guard headlessBranch.contains("promptForAgentTask("), headlessBranch.contains("prompt: prompt") else {
        throw fail("the headless spawn branch does not collect and pass a first prompt, so it spawns an agent that never runs:\n\(headlessBranch)")
    }
    let spawnHelper = try paletteAgentSpawnBranch("private func spawnSupervisedAgent(tileId: UUID?, prompt: String? = nil) -> AgentID {")
    guard spawnHelper.contains("prompt: prompt") else {
        throw fail("the app's spawn helper drops the prompt, so the headless agent would not run:\n\(spawnHelper)")
    }
    let terminate = try paletteAgentSpawnBranch("func applicationWillTerminate(_ notification: Notification) {")
    guard terminate.contains("stopAll()") else {
        throw fail("quitting does not stop the agents, so a headless agent's process outlives the session:\n\(terminate)")
    }

    return "\(headlessCount) agents ran concurrently with no tile (two past the \(ZoneHydrationBudgetConfig.defaultMaxLiveZones)-zone hydration budget), each persisted with tileId nil and delivering events, one then took a tile and replayed the work it did headless, and stopAll made every blocked run() return"
}

/// A runner factory that records the `cwd` of every record it is handed. The record
/// is what `AgentSupervisor.piRunner(for:)` reads to build `PiAgentRunner.Config`, so
/// this is the working directory the real provider process would start in.
@MainActor
private final class SpawningCwdRecorder {
    private(set) var cwds: [String] = []
    private let runner: ScriptedAgentRunner

    init(_ runner: ScriptedAgentRunner) { self.runner = runner }

    func make(_ record: AgentRecord) -> AgentRunning {
        cwds.append(record.cwd)
        return runner
    }
}

/// P2C.2 — an isolated spawn works in its OWN checkout.
///
/// Runs against a temp `git init` repository created here and deleted after. The real
/// repository is never a `git worktree add` target — P2C.1's explicit trap, inherited.
///
/// Four properties:
///   1. An isolated spawn's record has `cwd` inside `<repo>/.worktrees/` and
///      `worktreeBranch` set, and GIT agrees both exist (`git worktree list`).
///   2. The runner is handed that directory, and the branch actually checked out
///      there is the agent's own — asserted with `git rev-parse --abbrev-ref HEAD`
///      inside the cwd the runner was constructed with, so "the agent works on its own
///      branch" is a git fact rather than a string comparison against the same
///      constant the code built. The PRODUCTION factory is asserted too
///      (`PiAgentRunner.Config.cwd`), since an injected runner cannot witness it.
///   3. A non-isolated spawn against the same repo is UNCHANGED: `cwd` is the project
///      root, `worktreeBranch` is nil, and no new worktree appears.
///   4. NO FALLBACK, the packet's load-bearing rule. Two real `add` failures — a `cwd`
///      that is not a repository, and a `.worktrees` path occupied by a file — must
///      throw out of `spawn` and leave NO agent behind, in memory or on disk. A silent
///      fallback would put a supposedly isolated agent in the shared tree.
///
/// Negative tests observed red at exit 1 with the final code:
/// · `spawn(isolated:)` ignoring `isolated` (always `cwd`, no worktree) →
///   `FAIL: an isolated spawn's cwd … is not inside …/.worktrees/`
/// · setting `worktreeBranch: nil` on the isolated path →
///   `FAIL: an isolated agent's record does not name its branch`
/// · catching the `add` failure and falling back to `cwd` →
///   `FAIL: a failed worktree (not a repository) did not fail the spawn — the agent
///    landed in the main checkout …`
/// · `piRunner(for:)` building its `Config` with a fixed cwd instead of `record.cwd` →
///   `FAIL: the production runner would start Pi in /Users/dylan, not the agent's
///    worktree …`
@MainActor
private func checkIsolatedSpawn(
    config: AgentModelConfig.Resolution,
    fail: (String) -> Error
) async throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-isolated-spawn-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let repo = root.appendingPathComponent("repo", isDirectory: true)
    try makeIsolatedSpawnRepo(at: repo)
    let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("support", isDirectory: true))

    // MARK: 1–2 · the isolated agent's own checkout

    let runner = ScriptedAgentRunner(script: [.sessionStateChanged(.ready)])
    let recorder = SpawningCwdRecorder(runner)
    let supervisor = AgentSupervisor(store: store, makeRunner: { recorder.make($0) })
    let isolatedId = try supervisor.spawn(
        role: "implementer",
        prompt: "fix auth",
        cwd: repo,
        model: config.model,
        thinking: config.thinking,
        isolated: true
    )
    guard let isolated = supervisor.records[isolatedId] else {
        throw fail("the supervisor lost the isolated agent it spawned")
    }
    let container = repo.appendingPathComponent(WorktreeManager.containerDirectoryName, isDirectory: true)
    guard isolated.cwd.hasPrefix(container.path + "/") else {
        throw fail("an isolated spawn's cwd \(isolated.cwd) is not inside \(container.path)/")
    }
    guard let branch = isolated.worktreeBranch else {
        throw fail("an isolated agent's record does not name its branch")
    }
    guard branch.hasPrefix(WorktreeManager.branchPrefix) else {
        throw fail("an isolated agent's branch \(branch) is not under \(WorktreeManager.branchPrefix)")
    }
    let slug = URL(fileURLWithPath: isolated.cwd).lastPathComponent
    guard branch == WorktreeManager.branchName(slug: slug) else {
        throw fail("the branch \(branch) does not match the worktree directory \(slug)")
    }
    // The role and the prompt are both in the slug, so a spawn that dropped either
    // from the derivation would produce a directory no one can identify.
    guard slug.hasPrefix("implementer-fix-auth-") else {
        throw fail("the worktree directory \(slug) is not derived from the agent's role and prompt")
    }

    // Git's own view, not the manager's return value: `list` re-reads the repository.
    let manager = WorktreeManager()
    let listed = try manager.list(repo: repo)
    guard listed.contains(where: {
        isolatedSpawnResolved($0.path) == isolatedSpawnResolved(URL(fileURLWithPath: isolated.cwd)) && $0.branch == branch
    }) else {
        throw fail("git does not know about the agent's worktree: \(listed.map { "\($0.path.path)@\($0.branch ?? "detached")" })")
    }

    // …and the runner was pointed at it. The recorder captures what
    // `AgentSupervisor.piRunner(for:)` reads (`record.cwd`), and the branch is read
    // back out of that directory with git.
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { recorder.cwds.count == 1 }) else {
        throw fail("the isolated spawn's prompt never reached a runner: \(recorder.cwds)")
    }
    guard recorder.cwds == [isolated.cwd] else {
        throw fail("the runner was constructed for \(recorder.cwds) rather than the worktree \(isolated.cwd)")
    }
    let checkedOut = try runIsolatedSpawnGit(["rev-parse", "--abbrev-ref", "HEAD"], in: URL(fileURLWithPath: isolated.cwd))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard checkedOut == branch else {
        throw fail("the directory the runner works in is on branch \(checkedOut), not the agent's \(branch)")
    }
    // The PRODUCTION factory, not the recorder: an injected runner cannot witness
    // what `PiAgentRunner.Config.cwd` would be, so a regression in `piRunner(for:)`
    // would pass everything above (from the cross-review).
    guard let production = AgentSupervisor.piRunner(for: isolated) as? PiAgentRunner else {
        throw fail("the default runner factory does not produce a PiAgentRunner for an isolated agent")
    }
    guard production.config.cwd.path == isolated.cwd else {
        throw fail("the production runner would start Pi in \(production.config.cwd.path), not the agent's worktree \(isolated.cwd)")
    }

    // MARK: 3 · a non-isolated spawn is exactly what it was

    let plainId = supervisor.spawn(
        role: "reviewer",
        prompt: nil,
        cwd: repo,
        model: config.model,
        thinking: config.thinking
    )
    guard let plain = supervisor.records[plainId] else {
        throw fail("the supervisor lost the non-isolated agent it spawned")
    }
    guard plain.cwd == repo.path, plain.worktreeBranch == nil else {
        throw fail("a non-isolated spawn changed: cwd \(plain.cwd) branch \(plain.worktreeBranch ?? "nil") — it must stay the project root with no branch")
    }
    guard try manager.list(repo: repo).count == listed.count else {
        throw fail("a non-isolated spawn created a worktree")
    }

    // MARK: 4 · a worktree that cannot be created FAILS THE SPAWN

    /// Returns the error `spawn` raised, so the caller can be specific about it where
    /// the manager owns the failure. ANY error is accepted here rather than only a
    /// `WorktreeError`: the container-creation failure below surfaces as Foundation's
    /// own `NSFileWriteFileExistsError`, and re-typing it would mean editing P2C.1's
    /// manager for a ticket that is about the spawn path.
    func expectNoFallback(_ label: String, cwd: URL) throws -> Error {
        let before = supervisor.records.count
        var leaked: AgentID?
        var thrown: Error?
        do {
            leaked = try supervisor.spawn(
                role: "implementer",
                prompt: "fix auth",
                cwd: cwd,
                model: config.model,
                thinking: config.thinking,
                isolated: true
            )
        } catch {
            thrown = error
        }
        if let leaked {
            throw fail("a failed worktree (\(label)) did not fail the spawn — the agent landed in the main checkout \(supervisor.records[leaked]?.cwd ?? "?")")
        }
        guard let thrown else {
            throw fail("a failed worktree (\(label)) neither threw nor returned an agent")
        }
        guard supervisor.records.count == before else {
            throw fail("a failed isolated spawn (\(label)) left \(supervisor.records.count - before) agent(s) behind in memory")
        }
        guard try store.loadAll().count == before else {
            throw fail("a failed isolated spawn (\(label)) persisted a record")
        }
        return thrown
    }

    let notARepo = root.appendingPathComponent("not-a-repo", isDirectory: true)
    try FileManager.default.createDirectory(at: notARepo, withIntermediateDirectories: true)
    let notARepoError = try expectNoFallback("not a repository", cwd: notARepo)
    guard (notARepoError as? WorktreeManager.WorktreeError) == .invalidRepository(notARepo.path) else {
        throw fail("an isolated spawn into a non-repository reported \(notARepoError) rather than .invalidRepository")
    }

    // A real repository whose `.worktrees` path is occupied by a FILE: the failure is
    // in creating the container, i.e. past the repository check, which is where a
    // fallback would be most tempting.
    let blocked = root.appendingPathComponent("blocked", isDirectory: true)
    try makeIsolatedSpawnRepo(at: blocked)
    try "not a directory\n".write(
        to: blocked.appendingPathComponent(WorktreeManager.containerDirectoryName),
        atomically: true,
        encoding: .utf8
    )
    _ = try expectNoFallback(".worktrees occupied by a file", cwd: blocked)

    supervisor.stopAll()
    return "an isolated spawn ran in .worktrees/\(slug) on \(branch) (git agrees, and that is the branch checked out in the runner's cwd), a non-isolated spawn stayed in the project root with no branch, and two real worktree failures each threw out of spawn leaving no agent"
}

/// A temp repository with one commit — `git worktree add` needs a HEAD. The `-c`
/// identity keeps the check independent of the host's global git config, as
/// `WorktreeManagerChecks` does for the same reason.
private func makeIsolatedSpawnRepo(at root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try runIsolatedSpawnGit(["init", "-q", "-b", "main"], in: root)
    try "seed\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try runIsolatedSpawnGit(["add", "README.md"], in: root)
    try runIsolatedSpawnGit([
        "-c", "user.email=qa@continuum.test",
        "-c", "user.name=Continuum QA",
        "commit", "-q", "--no-gpg-sign", "-m", "seed",
    ], in: root)
}

@discardableResult
private func runIsolatedSpawnGit(_ arguments: [String], in directory: URL) throws -> String {
    struct GitError: Error, CustomStringConvertible { let description: String }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw GitError(description: "git \(arguments.joined(separator: " ")) failed (\(process.terminationStatus)): \(String(data: errData, encoding: .utf8) ?? "")")
    }
    return String(data: outData, encoding: .utf8) ?? ""
}

/// macOS temp directories live under a `/var` symlink to `/private/var`, and git
/// reports the RESOLVED path in `worktree list --porcelain`.
private func isolatedSpawnResolved(_ url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path
}

/// The body of one `AppDelegate` method, comments stripped. Bounded by the closing
/// brace at the method's own four-space indentation. Same precedent, and same reason,
/// as `managedAgentCloseBranchSource` below: these methods need a live canvas and a
/// running app to execute.
private func paletteAgentSpawnBranch(_ signature: String) throws -> String {
    struct ScanError: Error, CustomStringConvertible { let description: String }
    let path = "Sources/ContinuumRevived/App/ContinuumApp.swift"
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(path)
    guard let source = try? String(contentsOf: url, encoding: .utf8) else {
        throw ScanError(description: "could not read \(path) — run this check from the repo root")
    }
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == signature }) else {
        throw ScanError(description: "no `\(signature)` in \(path) — it was renamed or removed, and this scan is now blind")
    }
    var body: [String] = []
    for line in lines[(start + 1)...] {
        if line == "    }" { break }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { continue }
        body.append(line)
    }
    guard !body.isEmpty else {
        throw ScanError(description: "`\(signature)` scanned as an empty body")
    }
    return body.joined(separator: "\n")
}

/// The lines of `AppDelegate.deleteTile`'s `case .managedAgent:` branch, comments
/// stripped. Source-read for the same reason `piRunnerConstructionSites` is: the
/// branch needs a canvas, a workspace runtime and a modal-capable app to execute, so
/// "closing a tile never stops the agent" is otherwise only assertable by reading the
/// diff. Bounded by indentation (the branch's own `case` is at eight spaces) rather
/// than by a closing brace, since the branch contains nested blocks.
private func managedAgentCloseBranchSource() throws -> String {
    struct ScanError: Error, CustomStringConvertible { let description: String }
    let path = "Sources/ContinuumRevived/App/ContinuumApp.swift"
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(path)
    guard let source = try? String(contentsOf: url, encoding: .utf8) else {
        throw ScanError(description: "could not read \(path) — run this check from the repo root")
    }
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let functionStart = lines.firstIndex(where: { $0.contains("func deleteTile(id: UUID) {") }) else {
        throw ScanError(description: "no `func deleteTile(id: UUID)` in \(path)")
    }
    guard let branchStart = lines[functionStart...].firstIndex(where: { $0 == "        case .managedAgent:" }) else {
        throw ScanError(description: "no `case .managedAgent:` in deleteTile — the close path moved, and this scan is now blind")
    }
    var body: [String] = []
    for line in lines[(branchStart + 1)...] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !line.hasPrefix("         ") && !trimmed.isEmpty { break }
        if trimmed.hasPrefix("//") { continue }
        body.append(line)
    }
    guard !body.isEmpty else {
        throw ScanError(description: "deleteTile's .managedAgent branch scanned as empty")
    }
    return body.joined(separator: "\n")
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

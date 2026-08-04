import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
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
    /// P2D.2 — the local-only `spawn_agent` side channel. Separate from `onEvent`
    /// because a `SpawnRequest` carries the call's ARGUMENTS, which may never enter
    /// `AgentRuntimeEvent` (I5); set by `send` before the prompt runs.
    func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void)
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
    /// P2C.4: the branch each agent's working directory is on. Cached because the
    /// tile header that renders it re-lays out on every streamed token, and a
    /// `git rev-parse` per render is a process launch per token.
    private let checkedOutBranches = CheckedOutBranchCache()

    /// The records this supervisor owns, in memory. `AgentStore` is the durable
    /// copy; this is the live one.
    private(set) var records: [AgentID: AgentRecord] = [:]
    /// The runner for the prompt currently in flight, if any. One per agent: Pi is
    /// one process per prompt with a stable `--session-id`, so a finished runner is
    /// dropped and the next `send` makes a new one.
    private var runners: [AgentID: AgentRunning] = [:]
    private var subscribers: [AgentID: [UUID: AsyncStream<AgentRuntimeEvent>.Continuation]] = [:]
    private var history: [AgentID: [AgentRuntimeEvent]] = [:]

    /// Provider facts used by the v2 tile. Deliberately separate from `runners`:
    /// a provider process may remain alive while its turn is ready, and that must
    /// never paint Working. `runners` is consulted only when deciding whether the
    /// current send/stop transport can accept an action.
    private struct TurnFacts {
        var execution: AgentTurnExecutionState = .ready
        var failureMessage: String?
        var didFail = false
        var pendingRequests: [String: AgentPendingRequest] = [:]
        var requestOrder: [String] = []
        /// P3.3: when the turn now in flight started. THE anchor for every elapsed
        /// reading, and the fact the supervisor was not keeping — without it the
        /// sidebar measured from the event ring, whose oldest working event for a
        /// restored agent is a synthetic draft stamped at the SPAWN instant (the
        /// 158-hour reading). Non-nil exactly while `execution == .working`.
        var turnStartedAt: Date?
    }
    private var turnFacts: [AgentID: TurnFacts] = [:]

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
        PiAgentRunner(config: runnerConfig(for: record))
    }

    /// What the production runner is built with. Split out of `piRunner(for:)` so the
    /// matrix can read it — the runner itself exposes nothing.
    ///
    /// P2D.3: the role's `tools` reaches Pi from HERE, derived from the record's role
    /// id and its working directory, rather than from a new persisted field: role
    /// files are tracked in the repository, so an isolated agent's worktree carries
    /// the same `.pi/agents` its project does, and editing a role file takes effect on
    /// the next run instead of being frozen at spawn time.
    nonisolated static func runnerConfig(for record: AgentRecord) -> PiAgentRunner.Config {
        let cwd = URL(fileURLWithPath: record.cwd, isDirectory: true)
        // `model`/`thinking` come from the RECORD: the role already decided them at
        // spawn time (`handleSpawnRequest`), and a role file edited since must not
        // silently move a running agent's provider settings. Only the tool list is
        // read live, and via `toolsArguments` rather than `resolve` (cross-review):
        // resolving would also validate the role's model/reasoning, so a typo in a
        // field this call ignores would silently drop the agent's `--tools`.
        return PiAgentRunner.Config(
            model: record.model,
            thinking: record.thinking,
            cwd: cwd,
            sessionId: sessionId(for: record.id),
            extraArgs: RoleRegistry(projectRoot: cwd).toolsArguments(roleId: record.role)
        )
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
        parentAgentID: AgentID? = nil,
        sourceItemId: String? = nil,
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
            parentAgentID: parentAgentID,
            sourceItemId: sourceItemId,
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
        parentAgentID: AgentID? = nil,
        sourceItemId: String? = nil,
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
            parentAgentID: parentAgentID,
            sourceItemId: sourceItemId,
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
        parentAgentID: AgentID? = nil,
        sourceItemId: String? = nil,
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
            parentAgentID: parentAgentID,
            sourceItemId: sourceItemId,
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
        // P4.4: a user message is the plainest real activity there is, so a settle
        // does not survive it. Before the runner starts, because this write is the
        // same one `persist` below carries — the clear must not wait for the first
        // event to come back.
        clearSettleOnActivity(&record)
        records[id] = record
        persist(record)

        let runner = makeRunner(record)
        runners[id] = runner
        notifyTurnCapabilitiesChanged(id)
        // P2D.2: an agent asking for another agent arrives here, out of band from
        // the event stream. Hopped to the main actor like the events are, and for
        // the same reason — the handler mutates supervisor state.
        runner.observeSpawnRequests { [weak self] request in
            DispatchQueue.main.async { self?.handleSpawnRequest(request, from: id) }
        }
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
        notifyTurnCapabilitiesChanged(id)
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

    // MARK: - Orchestration (P2D.2)

    /// How deep a chain of spawns may go. The root agent a human started is depth 0,
    /// the worker it asks for is depth 1, and that worker's own worker is depth 2 —
    /// which is the last one: an agent already at the cap cannot spawn.
    ///
    /// A cap exists because the request is MODEL-AUTHORED (the packet's watch-out): a
    /// prompt that tells a worker to delegate produces workers that delegate, and
    /// every one of them is a Pi process. Nothing else in the app bounds that.
    static let maxSpawnDepth = 2
    /// How many children one parent may have. Same reason, the other axis: a single
    /// turn can emit as many tool calls as the model likes.
    static let maxChildrenPerParent = 4

    /// Why a `spawn_agent` call did not produce an agent. Carries counts and caps
    /// only — never the request's `prompt` or a path — because the refusal is
    /// SURFACED IN THE PARENT'S TRANSCRIPT, which is an `AgentRuntimeEvent`, i.e. the
    /// far side of the boundary `SpawnRequest` stays off (I5).
    enum SpawnRefusal: Equatable {
        case unknownParent
        case depthCapped(depth: Int, cap: Int)
        case childCapped(children: Int, cap: Int)
        case worktreeFailed
        /// P2D.3 — the request named a role this project does not define, or defines
        /// with a model/thinking value Pi would have to guess at.
        case roleUnresolved
        /// What the parent's transcript says. `worktreeFailed` deliberately does not
        /// name the git error: `WorktreeManager`'s failures quote paths. `roleUnresolved`
        /// deliberately does not name the role id either — not because an id is unsafe
        /// (it is not; P2D.3's watch-out says ids may be published) but because the
        /// P2D.2 witness holds the requested role out of every event on the parent's
        /// stream, and a reason that echoes it would be the one hole in that.
        var reason: String {
            switch self {
            case .unknownParent:
                return "the requesting agent is not known to this session"
            case let .depthCapped(depth, cap):
                return "spawn depth \(depth) exceeds the cap of \(cap)"
            case let .childCapped(children, cap):
                return "this agent already has \(children) child agents (cap \(cap))"
            case .worktreeFailed:
                return "its isolated checkout could not be created"
            case .roleUnresolved:
                return "the requested role is not defined in this project"
            }
        }
    }

    /// Turns an observed `spawn_agent` call into a real child agent.
    ///
    /// THE TOOL CALL IS THE API (P2D.1): the extension is inert, so this is the only
    /// place a child is created. The child inherits the parent's project always, and
    /// the parent's model and thinking level unless the ROLE it was asked for declares
    /// its own (P2D.3) — a `code-scout` runs what `.pi/agents/code-scout.md` says it
    /// runs. A role id this project does not define is REFUSED, not defaulted: the
    /// orchestrator asked for a specific worker, and quietly starting a generic one
    /// would answer a question nobody asked.
    ///
    /// `parentAgentID` is set on the child's record, which is what makes P2D.4's
    /// nesting and P2D.5's roll-up possible from the store alone.
    ///
    /// Returns nil on a refusal, having said so in the parent's transcript.
    @discardableResult
    func handleSpawnRequest(_ request: SpawnRequest, from parentId: AgentID) -> AgentID? {
        guard let parent = records[parentId] else {
            return refuseSpawn(.unknownParent, for: parentId)
        }
        let depth = depth(of: parentId) + 1
        guard depth <= Self.maxSpawnDepth else {
            return refuseSpawn(.depthCapped(depth: depth, cap: Self.maxSpawnDepth), for: parentId)
        }
        let siblings = children(of: parentId).count
        guard siblings < Self.maxChildrenPerParent else {
            return refuseSpawn(.childCapped(children: siblings, cap: Self.maxChildrenPerParent), for: parentId)
        }
        // The role resolves against the PROJECT's registry, not the parent's possibly
        // isolated checkout — and after the caps, so a request that was going to be
        // refused anyway is refused for the reason that actually stopped it.
        let projectRoot = Self.repositoryRoot(of: parent)
        let resolvedRole: RoleRegistry.Resolution
        do {
            resolvedRole = try RoleRegistry(projectRoot: projectRoot).resolve(
                roleId: request.role,
                inheriting: AgentModelConfig.Resolution(model: parent.model, thinking: parent.thinking)
            )
        } catch {
            warn("AgentSupervisor.handleSpawnRequest: child of \(parentId.rawValue.uuidString) not spawned: \(error)")
            return refuseSpawn(.roleUnresolved, for: parentId)
        }
        do {
            return try spawn(
                role: request.role,
                prompt: request.prompt,
                cwd: projectRoot,
                model: resolvedRole.model,
                thinking: resolvedRole.thinking,
                projectId: parent.projectId,
                parentAgentID: parentId,
                isolated: request.isolated
            )
        } catch {
            // The isolated spawn refuses to fall back to the shared checkout (P2C.2),
            // so a failed worktree is a failed spawn — reported, not downgraded.
            warn("AgentSupervisor.handleSpawnRequest: child of \(parentId.rawValue.uuidString) not spawned: \(error)")
            return refuseSpawn(.worktreeFailed, for: parentId)
        }
    }

    /// Says the refusal on the parent's own stream, so an orchestrator's transcript
    /// shows the ask being declined rather than silently producing nothing.
    ///
    /// Shaped as a failed tool item because that is what it is — the parent called a
    /// tool and the tool's effect did not happen — and because the bridge already
    /// renders `.itemCompleted(.failed)` on the timeline while collapsing the title to
    /// a safe token on the way to the phone.
    private func refuseSpawn(_ refusal: SpawnRefusal, for parentId: AgentID) -> AgentID? {
        warn("AgentSupervisor: refusing \(SpawnRequest.toolName) from \(parentId.rawValue.uuidString) — \(refusal.reason)")
        guard records[parentId] != nil else { return nil }
        let itemId = "spawn-refused-\(UUID().uuidString)"
        let thread = Self.threadId(for: parentId)
        deliver(.itemStarted(
            threadId: thread,
            itemId: itemId,
            kind: .error,
            title: "\(SpawnRequest.toolName) refused: \(refusal.reason)"
        ), to: parentId)
        deliver(.itemCompleted(
            threadId: thread,
            itemId: itemId,
            kind: .error,
            status: .failed
        ), to: parentId)
        return nil
    }

    /// The agents this one spawned.
    func children(of id: AgentID) -> [AgentID] {
        records.values.filter { $0.parentAgentID == id }.map(\.id)
    }

    /// How many parents this agent has above it. Bounded by the record count so a
    /// store that somehow describes a cycle terminates instead of hanging the app.
    func depth(of id: AgentID) -> Int {
        var depth = 0
        var current = records[id]?.parentAgentID
        var seen: Set<AgentID> = [id]
        while let parent = current, !seen.contains(parent), depth <= records.count {
            seen.insert(parent)
            depth += 1
            current = records[parent]?.parentAgentID
        }
        return depth
    }

    /// The repository a child should be isolated FROM: the parent's own working
    /// directory, unless the parent is itself in an agent worktree, in which case it
    /// is the repository that worktree was created from.
    ///
    /// Without the second half a child of an isolated parent would get
    /// `<repo>/.worktrees/<parent>/.worktrees/<child>` — a worktree nested inside a
    /// worktree, which git allows and nothing else in this codebase expects (P2C.3's
    /// cleanup identifies an agent checkout by its `.worktrees/` container, and keeps
    /// its own guard because it DELETES; this one only chooses where to add).
    static func repositoryRoot(of record: AgentRecord) -> URL {
        let cwd = URL(fileURLWithPath: record.cwd, isDirectory: true)
        guard record.worktreeBranch != nil,
              cwd.deletingLastPathComponent().lastPathComponent == WorktreeManager.containerDirectoryName
        else {
            return cwd
        }
        return cwd.deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: - Fan-out (P2D.6)

    /// One selected work item: the identifier the source surface knows it by (a
    /// Linear row's `ENG-214`, a conductor task id) and the prompt its agent runs.
    struct FanOutItem: Equatable {
        let id: String
        let prompt: String

        init(id: String, prompt: String) {
            self.id = id
            self.prompt = prompt
        }
    }

    /// Why one selected item did not get an agent. Kept apart from `deferred`
    /// because they are different answers: deferred means "not yet, the batch is
    /// full", refused means "not at all".
    enum FanOutRefusal: Equatable {
        /// An agent from an earlier fan-out is already working this item. Spawning a
        /// second would give one row two isolated checkouts and two answers.
        case alreadyRunning(AgentID)
        /// `git worktree add` failed. Per P2C.2 the spawn fails rather than falling
        /// back to the shared checkout — N agents in one tree is what 2C exists to
        /// prevent, and a fan-out is the case that makes it certain.
        case worktreeFailed

        var reason: String {
            switch self {
            case .alreadyRunning:
                return "an agent is already working on it"
            case .worktreeFailed:
                return "its isolated checkout could not be created"
            }
        }
    }

    /// What one `fanOut` actually did. Every item is in exactly one of the three
    /// lists, which is the packet's no-silent-truncation rule made checkable:
    /// `launched.count + deferred.count + refused.count == items.count`.
    struct FanOutReport: Equatable {
        var launched: [(itemId: String, agentId: AgentID)] = []
        /// Past the cap. Still selected, still yours to run — nothing was started
        /// for them and nothing pretended otherwise.
        var deferred: [String] = []
        var refused: [(itemId: String, refusal: FanOutRefusal)] = []
        /// The cap this batch was held to. Reported so the surface can say what
        /// stopped it rather than inventing a number.
        var cap: Int = 0

        /// One line for the surface that asked. Names counts and the cap only — no
        /// prompt text, no path.
        var summary: String {
            var parts = ["started \(launched.count)"]
            if !deferred.isEmpty { parts.append("deferred \(deferred.count) past the cap of \(cap)") }
            if !refused.isEmpty { parts.append("refused \(refused.count)") }
            return parts.joined(separator: " · ")
        }

        static func == (lhs: FanOutReport, rhs: FanOutReport) -> Bool {
            lhs.cap == rhs.cap
                && lhs.deferred == rhs.deferred
                && lhs.launched.count == rhs.launched.count
                && zip(lhs.launched, rhs.launched).allSatisfy { $0 == $1 }
                && lhs.refused.count == rhs.refused.count
                && zip(lhs.refused, rhs.refused).allSatisfy { $0 == $1 }
        }
    }

    /// How many agents ONE fan-out may start. Selecting thirty rows must not start
    /// thirty Pi processes and thirty worktrees; the rest come back as `deferred`.
    /// Same value as `maxChildrenPerParent`, and for the same reason — this is the
    /// human-authored twin of that model-authored cap.
    static let maxFanOutBatch = 4

    /// Called when an agent that was fanned out for an item finishes a turn
    /// successfully: `(itemId, agentId)`. The source surface checks the item off —
    /// the supervisor does not know what "done" means for a Linear row or a
    /// conductor task, and guessing would put queue semantics in here.
    var onFanOutItemCompleted: ((String, AgentID) -> Void)?

    /// Observers of turn-capability changes that no runtime event carries: the
    /// runner slot being taken or freed. The Pi process prints its terminal events
    /// before it exits, so the slot frees strictly after the last event a view will
    /// ever ingest — without this seam a view's cached `turnSnapshot` stays
    /// `canSend == false` forever (P5.5 live finding). Observers re-read
    /// `turnSnapshot(for:)`; nothing is fabricated onto the event stream. Token
    /// per observer because every attached agent tile subscribes.
    private var turnCapabilityObservers: [UUID: (AgentID) -> Void] = [:]

    @discardableResult
    func addTurnCapabilitiesObserver(_ observe: @escaping (AgentID) -> Void) -> UUID {
        let token = UUID()
        turnCapabilityObservers[token] = observe
        return token
    }

    func removeTurnCapabilitiesObserver(_ token: UUID) {
        turnCapabilityObservers[token] = nil
    }

    private func notifyTurnCapabilitiesChanged(_ id: AgentID) {
        for observe in turnCapabilityObservers.values { observe(id) }
    }

    /// Items whose agent has reported a completed turn, so a surface that rebuilds
    /// its rows (or one that attaches after the fact) can still draw them checked.
    private(set) var completedFanOutItems: Set<String> = []

    /// N items in, one agent per item out, each with the item's own prompt and —
    /// when `isolated` — its own worktree.
    ///
    /// Siblings by default: `parentAgentID` is nil, because a human selecting rows
    /// is not an agent. Passing one makes them children of the orchestrator that
    /// asked, and the batch is then ALSO held to whatever room that parent has left
    /// under `maxChildrenPerParent` — otherwise a fan-out would be the way around a
    /// cap that `handleSpawnRequest` enforces one spawn at a time.
    @discardableResult
    func fanOut(
        items: [FanOutItem],
        role: String?,
        cwd: URL,
        model: String,
        thinking: String,
        projectId: UUID? = nil,
        parentAgentID: AgentID? = nil,
        isolated: Bool = true
    ) -> FanOutReport {
        var report = FanOutReport()
        var cap = Self.maxFanOutBatch
        if let parentAgentID {
            cap = min(cap, max(0, Self.maxChildrenPerParent - children(of: parentAgentID).count))
        }
        report.cap = cap

        for item in items {
            // The refusal is decided BEFORE the cap, so an item that was never going
            // to run does not consume a slot a runnable one could have used.
            if let existing = agent(forSourceItem: item.id) {
                report.refused.append((item.id, .alreadyRunning(existing)))
                continue
            }
            guard report.launched.count < cap else {
                report.deferred.append(item.id)
                continue
            }
            do {
                let id = try spawn(
                    role: role,
                    prompt: item.prompt,
                    cwd: cwd,
                    model: model,
                    thinking: thinking,
                    projectId: projectId,
                    parentAgentID: parentAgentID,
                    sourceItemId: item.id,
                    isolated: isolated
                )
                report.launched.append((item.id, id))
            } catch {
                warn("AgentSupervisor.fanOut: no agent for item \(item.id): \(error)")
                report.refused.append((item.id, .worktreeFailed))
            }
        }
        return report
    }

    /// The live agent working an item, if any. Derived from the RECORDS rather than
    /// a runtime map, so it still answers after a relaunch has restored them.
    /// Archived agents are excluded: the item is free again once its agent is gone.
    func agent(forSourceItem itemId: String) -> AgentID? {
        records.values.first { $0.sourceItemId == itemId && $0.archivedAt == nil }?.id
    }

    /// The item this agent was fanned out for.
    func sourceItem(of id: AgentID) -> String? { records[id]?.sourceItemId }

    // MARK: - Archive / cleanup (P2C.3)

    /// What one `archive` did, so the caller reports facts instead of assuming the
    /// happy path ran. Every field is a decision that could have gone the other way.
    struct ArchiveReport {
        /// True when a prompt was in flight and had to be terminated.
        var wasRunning = false
        /// The worktree that is now gone from disk.
        var worktreeRemoved: URL?
        /// The worktree still on disk, and why it was left there.
        var worktreeRetained: (path: URL, reason: String)?
        /// The branch that was deleted because it held nothing the repo does not have.
        var branchDeleted: String?
        /// The branch kept because deleting it would have discarded the agent's
        /// commits, and why.
        var branchRetained: (branch: String, reason: String)?
        /// False only when the store refused; the in-memory record is always dropped.
        var recordDeleted = false

        var summary: String {
            var parts: [String] = []
            if wasRunning { parts.append("stopped a live runner") }
            if let worktreeRemoved { parts.append("removed \(worktreeRemoved.lastPathComponent)") }
            if let worktreeRetained { parts.append("kept worktree \(worktreeRetained.path.lastPathComponent) (\(worktreeRetained.reason))") }
            if let branchDeleted { parts.append("deleted \(branchDeleted)") }
            if let branchRetained { parts.append("KEPT \(branchRetained.branch) (\(branchRetained.reason))") }
            if parts.isEmpty { parts.append("nothing to clean up") }
            return parts.joined(separator: ", ")
        }
    }

    /// The agent leaves: its runner stops, its worktree goes away, and its record is
    /// deleted from memory and from the store.
    ///
    /// This is NOT what closing a tile does — that is `detachView` (P2A.5), and the
    /// locked decision is that closing a tile never ends the work. Only a deliberate
    /// archive/delete reaches here.
    ///
    /// The branch is deleted ONLY when `WorktreeManager.isMerged` says the repository
    /// already has everything on it. Otherwise the branch is kept and NAMED in the
    /// report: discarding an agent's commits silently is worse than leaving a branch
    /// behind for a human to look at. A dirty worktree is likewise retained rather than
    /// force-removed — the uncommitted edits are work too, and no diff has been
    /// captured yet (that is P2C.5).
    ///
    /// P4.1 owns the `archived` lifecycle state; this is only the cleanup the
    /// archive/delete action performs.
    @discardableResult
    func archive(_ id: AgentID) -> ArchiveReport {
        var report = ArchiveReport()
        guard let record = records[id] else {
            warn("AgentSupervisor.archive: no agent \(id.rawValue.uuidString)")
            return report
        }
        // Stopped BEFORE the record is deleted, and that order is load-bearing: `stop`
        // delivers `.sessionStateChanged(.stopped)`, which is persist-worthy, so a stop
        // after the delete would write the record straight back.
        if runners[id] != nil {
            report.wasRunning = true
            stop(id)
        }
        // THE DURABLE DELETE COMES FIRST (from the cross-review). Removing a worktree
        // for a record that is still on disk is the worst combination available: the
        // next launch restores an agent whose checkout is gone. If the store refuses,
        // nothing is cleaned up and the agent stays exactly where it was.
        do {
            try store.delete(id: id)
            report.recordDeleted = true
        } catch {
            warn("AgentSupervisor.archive: could not delete agent \(id.rawValue.uuidString), so nothing was cleaned up: \(error)")
            return report
        }
        cleanUpWorktree(of: record, into: &report)

        records.removeValue(forKey: id)
        history.removeValue(forKey: id)
        turnFacts.removeValue(forKey: id)
        for continuation in (subscribers[id] ?? [:]).values { continuation.finish() }
        subscribers.removeValue(forKey: id)
        restoredIDs.remove(id)
        // P3.3: the read-state goes with the agent. A stale entry would make a
        // recycled id read as unread, and a focused-then-archived agent would keep
        // the focus armed against nothing.
        unread.remove(id)
        if focusedAgentID == id { focusedAgentID = nil }
        return report
    }

    // Ticket: docs/38-tickets/90-agent-ux/P3.15-wire-destructive-row-actions.md
    //
    // KEPT OUT OF `archive` ON PURPOSE. Archiving is the agent's cleanup and says
    // nothing about a tile; suppressing a respawn is a statement about the TILE, made
    // by the surface that deleted the agent. Folding it into `archive` would also make
    // every internal caller (P2C.3's cleanup, a fan-out teardown) leave tombstones
    // behind for tiles nobody deleted.

    /// Record that this tile's agent was deleted by a person, so restoring the canvas
    /// does not mint a replacement (`AppDelegate.wireManagedAgentTile`).
    func suppressAgentRespawn(forTile tileId: UUID) {
        var tiles = store.loadDeletedAgentTiles()
        guard tiles.insert(tileId).inserted else { return }
        do {
            try store.setDeletedAgentTiles(tiles)
        } catch {
            warn("AgentSupervisor.suppressAgentRespawn: could not record the deletion of tile \(tileId.uuidString): \(error)")
        }
    }

    func isAgentRespawnSuppressed(forTile tileId: UUID) -> Bool {
        store.loadDeletedAgentTiles().contains(tileId)
    }

    /// The other direction, for the one gesture that undoes it: submitting a prompt in
    /// a tile whose agent was deleted is asking for an agent there again.
    func allowAgentRespawn(forTile tileId: UUID) {
        var tiles = store.loadDeletedAgentTiles()
        guard tiles.remove(tileId) != nil else { return }
        do {
            try store.setDeletedAgentTiles(tiles)
        } catch {
            warn("AgentSupervisor.allowAgentRespawn: could not clear the deletion of tile \(tileId.uuidString): \(error)")
        }
    }

    /// Removes an isolated agent's checkout, keeping anything unmerged.
    ///
    /// The repository is DERIVED from the record: an isolated `cwd` is
    /// `<repo>/.worktrees/<slug>`, so the repo is two components up. That derivation is
    /// checked rather than assumed — a record whose `cwd` is not inside the container
    /// gets nothing removed, because the alternative is running `git worktree remove`
    /// on somebody's project root.
    private func cleanUpWorktree(of record: AgentRecord, into report: inout ArchiveReport) {
        guard let branch = record.worktreeBranch else { return }
        let worktree = URL(fileURLWithPath: record.cwd, isDirectory: true)
        let container = worktree.deletingLastPathComponent()
        guard container.lastPathComponent == WorktreeManager.containerDirectoryName else {
            report.worktreeRetained = (worktree, "cwd is not inside \(WorktreeManager.containerDirectoryName)/")
            report.branchRetained = (branch, "the worktree could not be identified")
            warn("AgentSupervisor.archive: \(record.id.rawValue.uuidString) claims branch \(branch) but its cwd \(record.cwd) is not an agent worktree; leaving both alone")
            return
        }
        let repo = container.deletingLastPathComponent()

        do {
            // Git's own view: a worktree it no longer knows about must not be handed to
            // `worktree remove`, which fails on it, and the branch decision below is
            // still worth making.
            let known = try worktrees.list(repo: repo).contains {
                WorktreeManager.resolved($0.path) == WorktreeManager.resolved(worktree)
            }
            if known {
                try worktrees.remove(repo: repo, path: worktree, force: false)
                report.worktreeRemoved = worktree
            } else {
                report.worktreeRetained = (worktree, "git does not know this worktree")
            }
        } catch {
            // `git worktree remove` refuses a dirty tree. Retained, not forced.
            report.worktreeRetained = (worktree, String(describing: error))
            report.branchRetained = (branch, "its worktree is still on disk")
            warn("AgentSupervisor.archive: could not remove worktree \(worktree.path): \(error)")
            return
        }

        do {
            guard try worktrees.isMerged(repo: repo, branch: branch) else {
                report.branchRetained = (branch, "it has commits the repository does not")
                return
            }
            try worktrees.deleteBranch(repo: repo, branch: branch)
            report.branchDeleted = branch
        } catch {
            report.branchRetained = (branch, String(describing: error))
            warn("AgentSupervisor.archive: could not delete branch \(branch): \(error)")
        }
    }

    /// Worktrees under `<repo>/.worktrees/` with no agent record behind them.
    ///
    /// The known set is the union of the live records and everything still in the
    /// store, which is the load-bearing part: `restore()` MARKS a record whose `cwd` is
    /// missing and does not adopt it (P2A.7), so an in-memory-only set would call that
    /// agent's worktree an orphan and `repair` would prune the one thing that could
    /// still bring it back.
    func orphanWorktrees(repo: URL) throws -> [WorktreeManager.Orphan] {
        try worktrees.orphans(repo: repo, knownAgents: knownAgentDirectories())
    }

    /// Reports the orphans, removes the ones that hold no work, and prunes.
    func repairWorktrees(repo: URL) throws -> WorktreeManager.RepairReport {
        try worktrees.repair(repo: repo, knownAgents: knownAgentDirectories())
    }

    enum CleanupRefusal: Error, CustomStringConvertible {
        case unreadableAgentStore(String)

        var description: String {
            switch self {
            case let .unreadableAgentStore(detail):
                return "refusing to classify worktrees as orphans: \(detail)"
            }
        }
    }

    /// Every directory an agent record claims, live or stored.
    ///
    /// THROWS RATHER THAN NARROWING (from the cross-review). Repair DELETES checkouts,
    /// so an incomplete known set is not a degraded answer, it is a destructive one:
    /// every agent missing from it becomes an orphan. Both ways the set can come up
    /// short are refusals here, not warnings.
    ///
    /// The second one is the subtle one. `AgentStore.loadAll` deliberately SKIPS a
    /// record it cannot decode — correct for the inbox, which must not go down over one
    /// bad file, and silently wrong for this caller. The `.json` file count is the
    /// witness that nothing was skipped.
    private func knownAgentDirectories() throws -> Set<String> {
        let stored = try store.loadAll()
        let directory = store.layout.agentsDirectory
        var files: [URL] = []
        if FileManager.default.fileExists(atPath: directory.path) {
            files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }
        }
        guard files.count == stored.count else {
            throw CleanupRefusal.unreadableAgentStore(
                "\(files.count) record file(s) in \(directory.lastPathComponent)/ but only \(stored.count) could be read, so an agent could be mistaken for an orphan"
            )
        }
        return Set(records.values.map(\.cwd)).union(stored.map(\.cwd))
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

    // MARK: - Rename (P3.13)

    /// The longest name an agent may carry. A label, not a sentence: it is drawn in
    /// one truncating line and it crosses to the phone inside
    /// `AgentInventory.safeSummary`, where anything over 512 characters is a
    /// `transcriptBody` taint (`SyncPayloadTaintScanner`).
    static let maximumDisplayNameLength = 60

    /// User text, made into a label. Whitespace and newlines collapse to single
    /// spaces, the result is capped, and an ABSOLUTE PATH keeps only its last
    /// component — this name is published in a synced summary, and a leading `/` or
    /// `~` is how a filesystem path starts.
    ///
    /// The test is "starts a path", NOT the four prefixes `SyncPayloadTaintScanner`
    /// names (`/Users/`, `/home/`, `~/`, `/var/folders/`): copying that list here would
    /// be two copies of one rule that can drift, and it would also let `/tmp/…` or
    /// `/Volumes/…` through — a path the scanner happens not to catch is still not a
    /// name. A slash INSIDE the text is left alone, because `fix/parser` is a label
    /// people really use. (Both halves raised in cross-review.)
    ///
    /// nil for a name with nothing left in it, which the caller must read as "keep the
    /// previous one".
    static func sanitizedDisplayName(_ raw: String) -> String? {
        var label = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        if label.hasPrefix("/") || label.hasPrefix("~") {
            label = (label as NSString).lastPathComponent
        }
        guard !label.isEmpty else { return nil }
        return String(label.prefix(AgentSupervisor.maximumDisplayNameLength))
    }

    /// Give an agent a human name. The name is the RECORD's (`AgentRecord.displayName`),
    /// so it outlives the tile it happens to be shown in and comes back with the agent
    /// after a relaunch — everything that draws a name joins through the record
    /// (`AgentContextIndex`, `AgentInboxRowBuilder`, `AgentInventory`).
    ///
    /// Returns whether anything changed: false for an agent this supervisor does not
    /// have, for a name that sanitises to nothing, and for the name it already had —
    /// so a caller cannot mistake a no-op for a write and re-render for nothing.
    @discardableResult
    func rename(agentID id: AgentID, to name: String) -> Bool {
        guard var record = records[id] else {
            warn("AgentSupervisor.rename: no agent \(id.rawValue.uuidString)")
            return false
        }
        guard let label = AgentSupervisor.sanitizedDisplayName(name) else { return false }
        guard record.displayName != label else { return false }
        record.displayName = label
        records[id] = record
        persist(record)
        return true
    }

    // MARK: - Model and thinking level (P6.1)

    /// What this agent's NEXT turn will run with. Returns the record's own values,
    /// never the global default: `AgentModelConfig` is only what a record was seeded
    /// from at spawn, and changing that Settings default must not move an agent that
    /// already exists. nil for an agent this supervisor does not know.
    func providerSettings(for id: AgentID) -> AgentModelConfig.Resolution? {
        records[id].map { AgentModelConfig.Resolution(model: $0.model, thinking: $0.thinking) }
    }

    /// Choose the model and/or thinking level for ONE agent, and persist it.
    ///
    /// This is the whole mechanism: `piRunner(for:)` builds a runner per turn from
    /// the record (`runnerConfig(for:)` reads `record.model` / `record.thinking`), so
    /// writing them here is what makes the next `send` spawn Pi with those flags.
    /// Nothing mid-turn changes — `send` refuses a prompt on a busy agent rather than
    /// replacing the in-flight runner, and switching a live turn's model needs Pi's
    /// `set_model` RPC (P5.4/P5.5).
    ///
    /// A value outside `AgentModelConfig`'s catalogue is REFUSED rather than
    /// substituted: `--model` takes a *pattern*, so a shortened or misspelt id fuzzy
    /// matches and the agent silently runs whichever model Pi picked — the exact bug
    /// P0.10 exists to prevent. Persisting immediately is correct here even though
    /// P2A.3 keeps writes to lifecycle events: this is a discrete user action, not a
    /// per-token write on the main thread.
    ///
    /// Returns whether anything changed — as `rename` does, so a caller cannot
    /// mistake a no-op for a write.
    @discardableResult
    func setProviderSettings(agentID id: AgentID, model: String? = nil, thinking: String? = nil) -> Bool {
        guard var record = records[id] else {
            warn("AgentSupervisor.setProviderSettings: no agent \(id.rawValue.uuidString)")
            return false
        }
        if let model {
            guard AgentModelConfig.modelOptions.contains(model) else {
                warn("AgentSupervisor.setProviderSettings: \(model) is not a fully-qualified id in AgentModelConfig.modelOptions — refusing, because `--model` takes a pattern and a partial id fuzzy-matches")
                return false
            }
        }
        if let thinking {
            guard AgentModelConfig.thinkingOptions.contains(thinking) else {
                warn("AgentSupervisor.setProviderSettings: \(thinking) is not one of AgentModelConfig.thinkingOptions — refusing")
                return false
            }
        }
        var changed = false
        if let model, record.model != model {
            record.model = model
            changed = true
        }
        if let thinking, record.thinking != thinking {
            record.thinking = thinking
            changed = true
        }
        guard changed else { return false }
        records[id] = record
        persist(record)
        return true
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

    /// Operational state for one tile. State comes only from explicit lifecycle
    /// and request events. Transport occupancy affects capability acceptance, not
    /// the label: a process that has emitted Ready still presents Ready.
    func turnSnapshot(for id: AgentID) -> AgentTileTurnSnapshot? {
        guard records[id] != nil else { return nil }
        let facts = turnFacts[id] ?? TurnFacts()
        let state: AgentTileOperationalState
        if let requestID = facts.requestOrder.first(where: { facts.pendingRequests[$0] != nil }),
           let request = facts.pendingRequests[requestID] {
            state = .needsAction(request)
        } else if facts.didFail {
            state = .failed(message: facts.failureMessage)
        } else if restoredIDs.contains(id) && (history[id]?.isEmpty ?? true) {
            state = .restored
        } else {
            state = facts.execution == .working ? .working : .ready
        }

        let occupied = runners[id] != nil
        return AgentTileTurnSnapshot(
            state: state,
            capabilities: .sendStop(
                canSend: !occupied && state.acceptsNewTurn,
                // In flight = stoppable, full stop (P5.5 consolidation): `stop()`
                // genuinely kills a spawning (pre-turnStarted) or draining
                // (post-settle) process, so gating on `execution == .working`
                // under-advertised the transport — and painted the two windows
                // "Unavailable" on the composer.
                canStop: occupied
            ),
            // P3.3: carried, never derived here. A consumer that wanted an elapsed
            // reading had to reach for the event ring instead, which is why the
            // sidebar and the tile header measured different durations for one turn.
            turnStartedAt: facts.turnStartedAt
        )
    }

    /// One action owner for the v2 composer. Validation and mutation happen on the
    /// same main-actor turn, so an accepted send/stop cannot be refused by a second
    /// capability check hidden in the view.
    func accept(_ intent: AgentComposerIntent, for agentID: AgentID) async -> IntentAcceptance {
        guard records[agentID] != nil else { return .refused(.unknownAgent) }
        guard let snapshot = turnSnapshot(for: agentID) else { return .refused(.unknownAgent) }
        switch intent {
        case .send(let draft):
            let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return .refused(.emptyDraft) }
            guard snapshot.capabilities.canSend else { return .refused(.turnNotReady) }
            send(prompt, to: agentID)
            return .accepted
        case .stop:
            guard snapshot.capabilities.canStop, runners[agentID] != nil else {
                return .refused(.noTurnInProgress)
            }
            stop(agentID)
            return .accepted
        case .steer, .queue, .command:
            // Today's compiled runner has none of these RPCs. Never simulate one by
            // replaying send or retaining text in a local queue.
            return .refused(.unsupported)
        }
    }

    // MARK: - Branch context (P2C.4)

    /// What a view needs to say which checkout this agent is about to touch: the
    /// branch its record names, and the branch actually checked out in the directory
    /// it works in.
    ///
    /// `record.cwd` IS that directory — an isolated agent's own worktree, or the
    /// project root for a shared one — so no repository root has to be re-derived
    /// here (the derivation `cleanUpWorktree` needs, and its container guard, exist
    /// because THAT call deletes things).
    ///
    /// Returns an `AgentRowContext` carrying only the branch fields rather than a
    /// pair of strings: it is the type Phase 3's rows already join, so a renderer
    /// takes one shape from either source and `isBranchMismatch` keeps one
    /// definition. nil for an agent this supervisor does not know.
    func branchContext(for id: AgentID) -> AgentRowContext? {
        guard let record = records[id] else { return nil }
        return AgentRowContext(
            agentKind: .managed,
            worktreeBranch: record.worktreeBranch,
            checkedOutBranch: checkedOutBranches.branch(
                repo: URL(fileURLWithPath: record.cwd, isDirectory: true)
            )
        )
    }

    /// Forget the cached branches, for a caller that knows a checkout moved. The
    /// TTL gets there on its own; this is how a refresh gets there at once.
    func invalidateCheckedOutBranches() {
        checkedOutBranches.invalidate()
    }

    /// How many `git rev-parse` calls the branch cache has made — the witness that
    /// re-rendering a header does not shell out.
    var qaBranchGitReads: Int { checkedOutBranches.gitReads }

    // MARK: - Read state (P3.3)

    /// Agents that finished a turn while you were looking somewhere else.
    ///
    /// LOCAL, AND DELIBERATELY NOT DURABLE OR SYNCED. Not synced because "have I
    /// read this" is per-human and per-device — a phone opening a row is not this
    /// Mac having looked at it — and it is I5-irrelevant, so it must never reach a
    /// payload. Not persisted because nothing writes it to disk: it lives beside
    /// `records` rather than in `AgentRecord`, which is the type both `AgentStore`
    /// and the companion publisher serialize. A relaunch therefore starts with
    /// nothing marked — every restored agent reads `.none` — which is the honest
    /// answer for a mark that means "finished while you were not looking": nobody
    /// was looking at anything before this launch, and the desktop transcript does
    /// not survive either (P2A.7).
    ///
    /// WHO FILLS IT, and who does not yet: `deliver` marks, `focus`/`focusTile`
    /// clear. Nothing in the app calls either yet — the inbox that reads this axis
    /// is P3.6's list view and the open-a-row path is P3.9's, and the row builder
    /// (Core) cannot reach a supervisor, so the value is fed to rows from the
    /// desktop side when that list exists. This ticket owns the fact, not its
    /// consumers.
    private var unread: Set<AgentID> = []

    /// The agent the human is looking at, or nil when that is nothing this
    /// supervisor owns. Read-state is cleared against THIS, not against a hover:
    /// clearing on hover would empty the inbox by sweeping the mouse across it.
    private(set) var focusedAgentID: AgentID?

    /// A deliberate focus or open: the tile was activated, or the inbox row was
    /// revealed (P3.9). Clears the agent's unread mark, and — the half that makes
    /// the mark mean anything — arms it, so a turn that completes while you are here
    /// never sets it.
    ///
    /// Pass nil when focus leaves for something that is not an agent; from then on a
    /// completed turn is unread again.
    func focus(agentID id: AgentID?) {
        focusedAgentID = id
        if let id { unread.remove(id) }
    }

    /// The same thing keyed by TILE, which is how focus actually arrives on the
    /// desktop (`FocusBroker` speaks tile ids). A tile showing no agent focuses
    /// nothing rather than leaving the previous agent armed.
    func focusTile(_ tileId: UUID?) {
        focus(agentID: tileId.flatMap { agent(forTile: $0) })
    }

    /// This agent's attention axis, resolved (`InboxAttention.resolve`).
    ///
    /// `raisedHand` is P4.6's fact — a snoozed agent putting its hand up — and this
    /// supervisor does not own snooze, so it is a parameter rather than a nil
    /// pretending to be an answer. The precedence between the two lives in
    /// `InboxAttention`, not here.
    func attention(for id: AgentID, raisedHand: Bool = false) -> InboxAttention {
        InboxAttention.resolve(unread: unread.contains(id), raisedHand: raisedHand)
    }

    // MARK: - Auto-unsettle (P4.4)

    /// Which reason last cleared each agent's settle. Kept so a clear can be
    /// ATTRIBUTED — `.activity` is the app's own, `.user` is a person's — rather than
    /// inferred from a `.neutral` that both paths produce. In memory only: the
    /// attribution is debugging state, not a fact about the agent, and `AgentRecord`
    /// is what the store and the companion publisher serialize.
    private(set) var settledOverrideClearReasons: [AgentID: SettledOverrideClearReason] = [:]

    /// Every clear is also SAID OUT LOUD, through this file's one logging seam. The
    /// dictionary above answers "who cleared it" only while the process lives, and the
    /// question the packet actually poses ("so the ledger/debugging can tell them
    /// apart") is usually asked after the fact about an override that is already gone.
    /// A line per clear is the durable half of the attribution; `warn` is injectable,
    /// so it is also the testable half. Rare by construction — only a settled agent has
    /// anything to clear — and it names the agent id and the reason, both of which this
    /// file's other log lines already carry.
    private func logSettleCleared(_ id: AgentID, reason: SettledOverrideClearReason) {
        warn("AgentSupervisor: cleared the settle on agent \(id.rawValue.uuidString) — reason \(reason.rawValue)")
    }

    /// Whether this event means the agent is REALLY WORKING AGAIN, as opposed to
    /// reporting on itself.
    ///
    /// The whole set, and why each side of the line sits where it does:
    ///
    /// · `.sessionStateChanged(.starting)`/`(.running)` — a session coming alive.
    /// · `.turnStarted` — the same fact one level down; a turn does not begin unless
    ///   something asked for one.
    /// · `.requestOpened`/`.userInputRequested` — the agent is now waiting on a human,
    ///   which is the case a stale settle hides most damagingly (it is also a P4.2
    ///   blocker, so the row is already visible while the request is open; clearing the
    ///   override is what keeps it visible AFTER the request is answered).
    ///
    /// NOT activity, deliberately:
    ///
    /// · **`.sessionStateChanged(.ready)`** — the packet's named watch-out. An agent
    ///   settling into ready IS the normal end of work, so treating it as activity
    ///   would undo every settle moments after it was made.
    /// · `.waiting`, `.stopped`, `.error` — reports about work that is over or stalled.
    /// · `.turnCompleted` — work ENDING, same reasoning as `.ready`.
    /// · `.contentDelta`, `.itemStarted`, `.itemCompleted` — mid-turn traffic inside a
    ///   turn whose `.turnStarted` has already cleared the settle, so they can only
    ///   re-clear what is already `.neutral`; and `contentDelta` arrives per token, so
    ///   admitting it would put this decision on the hottest path in the app.
    /// · `.requestResolved`, `.userInputResolved` — a human answering, i.e. the far
    ///   side of the request that already counted.
    /// · `.tokenUsageUpdated` — a meter. This is the event-stream shape of the status
    ///   poll the packet excludes by name.
    ///
    /// `nonisolated static` and a total switch over `AgentRuntimeEvent`, like
    /// `isPersistWorthy` beside it: a new event case is a compile error here rather
    /// than a silent default.
    nonisolated static func isRealActivity(_ event: AgentRuntimeEvent) -> Bool {
        switch event {
        case let .sessionStateChanged(state):
            switch state {
            case .starting, .running:
                return true
            case .ready, .waiting, .stopped, .error:
                return false
            }
        case .turnStarted, .requestOpened, .userInputRequested:
            return true
        case .turnCompleted, .itemStarted, .itemCompleted, .contentDelta,
             .requestResolved, .userInputResolved, .tokenUsageUpdated, .runtimeError:
            return false
        }
    }

    /// THE APP's clear, and the only writer of `reason: .activity`. Returns whether the
    /// override actually moved, which is what tells `deliver` it has to persist an
    /// event that is not otherwise persist-worthy — a clear that lives only in memory
    /// comes back settled on the next launch.
    ///
    /// Takes the record `inout` rather than an id so it composes with the callers that
    /// are already holding a mutated copy (`send`, `deliver`); they own writing it back.
    @discardableResult
    private func clearSettleOnActivity(_ record: inout AgentRecord) -> Bool {
        guard record.settledOverride.clearsOnActivity else { return false }
        record.settledOverride = record.settledOverride.afterActivity()
        settledOverrideClearReasons[record.id] = .activity
        logSettleCleared(record.id, reason: .activity)
        return true
    }

    /// THE HUMAN's clear — "not done with this after all" — a separate entry point on
    /// purpose (the packet: only the app may clear for `activity`, a user action is its
    /// own path). Same resulting `.neutral`, different recorded reason.
    ///
    /// Returns false for an agent this supervisor does not have and for one that was
    /// not settled, so a caller cannot mistake a no-op for a write.
    ///
    /// NOTHING CALLS THIS YET: the surface that lets a person settle or un-settle a row
    /// is a later Phase-4 ticket, and this ticket owns the writer, not its button.
    /// Pushes one event through the real `deliver` path. FOR THE CHECKS, like the
    /// `qa`-prefixed members elsewhere in this file.
    ///
    /// It exists because every event this app produces today arrives INSIDE a `send`,
    /// and `send` clears a settle itself (a user message is activity) — so there is no
    /// other way to observe what an ARRIVING event does to a still-settled agent, which
    /// is precisely what this ticket adds. The production caller it defends is Phase 5's
    /// persistent session: an rpc session comes alive, or an approval opens, without
    /// this app having just sent a prompt.
    func qaDeliver(_ event: AgentRuntimeEvent, to id: AgentID) {
        deliver(event, to: id)
    }

    @discardableResult
    func clearSettle(agentID id: AgentID) -> Bool {
        guard var record = records[id] else {
            warn("AgentSupervisor.clearSettle: no agent \(id.rawValue.uuidString)")
            return false
        }
        guard record.settledOverride.clearsOnActivity else { return false }
        record.settledOverride = record.settledOverride.afterActivity()
        settledOverrideClearReasons[id] = .user
        logSettleCleared(id, reason: .user)
        records[id] = record
        persist(record)
        return true
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
        updateTurnFacts(with: event, for: id)
        // P3.3: a COMPLETED TURN is what makes a row unread — the agent stopped and
        // has something for you. Only that event, and only when you are not already
        // looking: streamed tokens and item events are the turn still running, and a
        // turn you watched finish has been read by definition.
        if case .turnCompleted = event, focusedAgentID != id {
            unread.insert(id)
        }

        var buffer = history[id] ?? []
        buffer.append(event)
        if buffer.count > Self.replayCap {
            buffer.removeFirst(buffer.count - Self.replayCap)
        }
        history[id] = buffer

        if var record = records[id] {
            record.lastActivityAt = Date()
            // P4.4: real work un-settles the agent. Narrower than the stamp above —
            // every event is activity for the purposes of "when did this last do
            // anything", but only the `isRealActivity` set means "it is working
            // again", and `.sessionStateChanged(.ready)` in particular must not
            // (it is how a turn ENDS).
            let unsettled = Self.isRealActivity(event) && clearSettleOnActivity(&record)
            records[id] = record
            // Only lifecycle-shaped events reach the disk. `contentDelta` arrives
            // per token and every write is an AtomicWriter write (temp file +
            // fsync + read-back), so persisting all of them would put a synchronous
            // fsync per token on the main thread.
            //
            // A clear forces the write regardless: `.requestOpened` and
            // `.userInputRequested` are not persist-worthy, so without this the
            // agent would read `.neutral` in memory and come back `.settled` on the
            // next launch.
            if Self.isPersistWorthy(event) || unsettled { persist(record) }
        }

        for continuation in (subscribers[id] ?? [:]).values {
            continuation.yield(event)
        }

        // P2D.6: the agent finished the work its item was fanned out for, so the
        // item is done. Only `.completed` — a turn that failed or was aborted has
        // not done the work, and checking the row off would lose it. Last, after
        // the record and every subscriber are consistent, because the handler is
        // the source surface re-rendering.
        if case let .turnCompleted(_, _, outcome, _) = event,
           outcome == .completed,
           let itemId = records[id]?.sourceItemId {
            completedFanOutItems.insert(itemId)
            onFanOutItemCompleted?(itemId, id)
        }
    }

    private func updateTurnFacts(with event: AgentRuntimeEvent, for id: AgentID, now: Date = Date()) {
        var facts = turnFacts[id] ?? TurnFacts()
        switch event {
        case .turnStarted:
            facts.execution = .working
            facts.didFail = false
            facts.failureMessage = nil
            // P3.3: THE elapsed anchor, stamped by the one owner of turn state at
            // the one event that means "work started now". Every other candidate is
            // a proxy: `record.lastSeenAt` is the spawn instant, and the event ring's
            // trailing working run starts at whatever synthetic draft a restore left
            // behind — which is the 158-hour reading the sidebar was showing.
            facts.turnStartedAt = now
        case let .turnCompleted(_, _, outcome, errorMessage):
            facts.execution = .ready
            facts.didFail = outcome == .failed
            facts.failureMessage = outcome == .failed ? errorMessage : nil
            facts.turnStartedAt = nil
        case let .sessionStateChanged(state):
            // `.running` is session/process state, not proof of an active turn.
            // Only turnStarted/turnCompleted move the execution fact.
            if state == .error {
                facts.execution = .ready
                facts.didFail = true
                facts.turnStartedAt = nil
            } else if state == .stopped || state == .ready {
                facts.execution = .ready
                facts.turnStartedAt = nil
            }
        case let .requestOpened(_, requestID, kind):
            let request = AgentPendingRequest(
                requestID: requestID,
                prompt: kind.compiledRequestPrompt,
                responseMode: .fixedChoice(ApprovalDecision.compiledChoices),
                // P3.3: stated by the event that produced it. An approval is an
                // approval because the adapter opened one and is holding it, not
                // because its choice list happened to be non-empty.
                kind: .approval
            )
            facts.pendingRequests[requestID] = request
            if !facts.requestOrder.contains(requestID) { facts.requestOrder.append(requestID) }
        case let .userInputRequested(_, requestID, questions):
            // User-input events carry prompt text but no compiled response-mode
            // capability. Empty choices therefore remain fixed-choice([]), never a
            // fabricated freeform editor — and, since P3.3, never evidence of the
            // request's KIND either: `.fixedChoice([])` is what an approval with no
            // decisions would compile to as well.
            let prompt = questions.map(\.prompt).filter { !$0.isEmpty }.joined(separator: " ")
            let request = AgentPendingRequest(
                requestID: requestID,
                prompt: prompt.isEmpty ? "Provider requested input" : prompt,
                responseMode: .fixedChoice([]),
                kind: .input
            )
            facts.pendingRequests[requestID] = request
            if !facts.requestOrder.contains(requestID) { facts.requestOrder.append(requestID) }
        case let .requestResolved(_, requestID, _), let .userInputResolved(_, requestID):
            facts.pendingRequests.removeValue(forKey: requestID)
            facts.requestOrder.removeAll { $0 == requestID }
        case let .runtimeError(_, message):
            facts.execution = .ready
            facts.didFail = true
            facts.failureMessage = message
            facts.turnStartedAt = nil
        case .itemStarted, .itemCompleted, .contentDelta, .tokenUsageUpdated:
            break
        }
        // The invariant this file owns, asserted in `--agent-supervisor-check`: a
        // stamped start exists exactly while a turn is in flight, so a stale anchor
        // can never outlive the turn it measured.
        assert((facts.turnStartedAt != nil) == (facts.execution == .working),
               "turnStartedAt must be non-nil exactly while execution is working")
        turnFacts[id] = facts
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
        if runners[id] === runner {
            runners[id] = nil
            notifyTurnCapabilitiesChanged(id)
        }
    }

    private func persist(_ record: AgentRecord) {
        do {
            try store.upsert(record)
        } catch {
            warn("AgentSupervisor: could not persist agent \(record.id.rawValue.uuidString): \(error)")
        }
    }
}

extension AgentSupervisor: AgentTileActionSink {}

private extension AgentTileOperationalState {
    var acceptsNewTurn: Bool {
        switch self {
        case .ready, .failed, .restored: return true
        case .working, .queued, .needsAction: return false
        }
    }
}

// MARK: - Self-check

@MainActor
private final class ScriptedTileActionSink: AgentTileActionSink {
    var acceptance: IntentAcceptance
    private(set) var intents: [(AgentComposerIntent, AgentID)] = []

    init(_ acceptance: IntentAcceptance) { self.acceptance = acceptance }

    func accept(_ intent: AgentComposerIntent, for agentID: AgentID) async -> IntentAcceptance {
        intents.append((intent, agentID))
        return acceptance
    }
}

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
    private var spawnHandler: (@Sendable (SpawnRequest) -> Void)?

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

    func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {
        lock.withLock { spawnHandler = handler }
    }

    /// Fires the side channel the supervisor registered, as a provider stream would.
    /// `false` when nothing is observing, so a check cannot mistake "the supervisor
    /// never wired the channel" for "the request was refused".
    func emit(spawn request: SpawnRequest) -> Bool {
        guard let handler = lock.withLock({ spawnHandler }) else { return false }
        handler(request)
        return true
    }
}

@MainActor
private func runComposerKeyContractChecks() throws -> Int {
    struct CheckError: Error, CustomStringConvertible { let description: String }
    func fail(_ message: String) -> CheckError { CheckError(description: "composer key contract: \(message)") }
    func event(
        keyCode: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = [],
        windowNumber: Int = 0
    ) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else { throw fail("could not create synthetic key event") }
        return event
    }

    // Exercise the production composer and its required observer contract, not a
    // private protocol conformer or process-global notification that can mask a
    // dropped intent. P5.4 will bind this already-compiled seam to the live tile.
    let composer = AgentComposerView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
    let textView = composer.textView
    var sendCount = 0
    var submittedPrompt: String?
    var dismissCount = 0
    composer.onSubmitPrompt = { prompt in
        sendCount += 1
        submittedPrompt = prompt
    }
    composer.onDismissSuggestions = { dismissCount += 1 }
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.contentView = composer
    window.makeKey()
    guard window.makeFirstResponder(textView) else {
        throw fail("could not install production composer text view as real first responder")
    }
    func dispatch(_ event: NSEvent) { window.sendEvent(event) }
    func key(_ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try event(keyCode: code, characters: characters, modifiers: modifiers, windowNumber: window.windowNumber)
    }

    textView.string = "send this"
    textView.setSelectedRange(NSRange(location: 9, length: 0))
    dispatch(try key(36, "\r"))
    guard sendCount == 1, submittedPrompt == "send this", textView.string == "send this" else {
        throw fail("plain Return with content did not emit exactly one send without editing")
    }

    dispatch(try key(36, "\r", .shift))
    guard sendCount == 1, textView.string == "send this\n" else {
        throw fail("Shift+Return did not stay on the native newline path")
    }

    let beforeModifiedReturn = textView.string
    dispatch(try key(36, "\r", .command))
    guard sendCount == 1, textView.string == beforeModifiedReturn else {
        throw fail("Command+Return was repurposed or did not preserve native text behavior")
    }
    dispatch(try key(36, "\r", .option))
    guard sendCount == 1, textView.string == beforeModifiedReturn + "\n" else {
        throw fail("Option+Return was repurposed or did not preserve native newline behavior; got '\(textView.string)'")
    }

    textView.string = "   "
    textView.setSelectedRange(NSRange(location: 3, length: 0))
    dispatch(try key(36, "\r"))
    guard sendCount == 1, textView.string == "   \n" else {
        throw fail("whitespace-only Return sent instead of remaining native editing")
    }

    textView.string = "compose "
    textView.setSelectedRange(NSRange(location: 8, length: 0))
    textView.setMarkedText("候", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 8, length: 0))
    guard textView.hasMarkedText() else { throw fail("marked-text setup did not enter IME composition") }
    dispatch(try key(36, "\r"))
    // A synthetic key event has no live input manager/candidate window, so AppKit
    // replaces this artificial marked range with its native Return edit. Assert that
    // observable edit rather than pretending `unmarkText()` proves an IME commit:
    // the policy assertion below owns the crucial contract that marked Return is
    // forwarded, while a real IME remains responsible for choosing its candidate.
    guard ComposerKeyPolicy.action(
            for: try key(36, "\r"),
            hasMarkedText: true,
            hasTrimmedContent: true,
            suggestionsVisible: false
          ) == .nativeTextSystem,
          sendCount == 1,
          !textView.hasMarkedText(),
          textView.string == "compose \n",
          textView.selectedRange() == NSRange(location: 9, length: 0) else {
        throw fail("Return during marked IME text did not traverse AppKit's native input path without sending; got '\(textView.string)' / \(textView.selectedRange())")
    }

    textView.suggestionsAreVisible = true
    dispatch(try key(53, "\u{1b}"))
    guard dismissCount == 1, sendCount == 1, !textView.suggestionsAreVisible else {
        throw fail("Escape did not dismiss suggestions first, or unexpectedly emitted send/stop-like work")
    }
    dispatch(try key(53, "\u{1b}"))
    guard dismissCount == 1 else {
        throw fail("Escape without suggestions was consumed by the composer")
    }

    textView.string = "/rev old tail"
    let originalSelection = NSRange(location: 5, length: 3)
    textView.setSelectedRange(originalSelection)
    textView.undoManager?.removeAllActions()
    textView.insertCompletion("reviewer", replacementRange: NSRange(location: 0, length: 8))
    guard textView.string == "reviewer tail", textView.selectedRange() == NSRange(location: 8, length: 0),
          textView.undoManager?.canUndo == true else {
        throw fail("completion insertion did not replace the query as one undoable native edit")
    }
    textView.undoManager?.undo()
    guard textView.string == "/rev old tail", textView.selectedRange() == originalSelection else {
        throw fail("one undo did not restore completion text and selection; got '\(textView.string)' / \(textView.selectedRange())")
    }

    // P4.5: drive history through the same production composer and real TextKit
    // layout. The live tile binds this already-compiled seam in P5.4.
    let promptHistory = AgentPromptHistory(capacityPerAgent: 4)
    let historyAgentA = AgentID(rawValue: UUID(uuidString: "A0000000-0000-4000-8000-000000009451")!)
    let historyAgentB = AgentID(rawValue: UUID(uuidString: "A0000000-0000-4000-8000-000000009452")!)
    composer.bindPromptHistory(promptHistory, agentID: historyAgentA)
    composer.onSubmitPrompt = nil
    var shouldAcceptHistorySend = false
    var historySendAttempts = 0
    composer.onSubmitIntent = { _ in
        historySendAttempts += 1
        return shouldAcceptHistorySend
    }
    var historyAssertions = 0
    func installHistoryText(_ value: String, selection: NSRange) {
        textView.string = value
        textView.setSelectedRange(selection)
        textView.layoutManager?.invalidateLayout(
            forCharacterRange: NSRange(location: 0, length: (value as NSString).length),
            actualCharacterRange: nil
        )
        composer.layoutSubtreeIfNeeded()
    }
    let upArrow = try key(126, "\u{f700}")
    let downArrow = try key(125, "\u{f701}")

    installHistoryText("rejected prompt", selection: NSRange(location: 15, length: 0))
    dispatch(try key(36, "\r"))
    guard historySendAttempts == 1,
          promptHistory.count(for: historyAgentA) == 0,
          textView.string == "rejected prompt" else {
        throw fail("a rejected send entered history or cleared its draft")
    }
    historyAssertions += 1

    installHistoryText("   ", selection: NSRange(location: 3, length: 0))
    dispatch(try key(36, "\r"))
    guard historySendAttempts == 1, promptHistory.count(for: historyAgentA) == 0 else {
        throw fail("a whitespace-only native Return entered accepted prompt history")
    }
    historyAssertions += 1

    shouldAcceptHistorySend = true
    for prompt in ["accepted one", "accepted two", "accepted two"] {
        installHistoryText(prompt, selection: NSRange(location: (prompt as NSString).length, length: 0))
        dispatch(try key(36, "\r"))
        guard textView.string.isEmpty else {
            throw fail("an accepted history send did not clear the submitted draft")
        }
    }
    guard historySendAttempts == 4,
          promptHistory.count(for: historyAgentA) == 2,
          promptHistory.acceptedSubmissionCount(for: historyAgentA) == 3 else {
        throw fail("accepted sends were not recorded exactly once with adjacent deduplication")
    }
    historyAssertions += 2

    composer.bindPromptHistory(promptHistory, agentID: historyAgentB)
    installHistoryText("agent B draft", selection: NSRange(location: 0, length: 0))
    dispatch(upArrow)
    guard textView.string == "agent B draft",
          !promptHistory.isNavigating(for: historyAgentB) else {
        throw fail("history crossed AgentID when agent B pressed Up")
    }
    historyAssertions += 1
    composer.bindPromptHistory(promptHistory, agentID: historyAgentA)

    promptHistory.cancelNavigation(for: historyAgentA)
    let multilineDraft = "first visual line\nsecond visual line"
    installHistoryText(
        multilineDraft,
        selection: NSRange(location: (multilineDraft as NSString).length, length: 0)
    )
    let multilineEnd = textView.selectedRange().location
    dispatch(upArrow)
    guard textView.string == multilineDraft,
          textView.selectedRange().location < multilineEnd,
          !promptHistory.isNavigating(for: historyAgentA) else {
        throw fail("Up inside multiline text did not remain native")
    }
    historyAssertions += 1

    installHistoryText(multilineDraft, selection: NSRange(location: 2, length: 0))
    dispatch(upArrow)
    guard textView.string == "accepted two", promptHistory.isNavigating(for: historyAgentA) else {
        throw fail("Up on the first visual line did not enter the newest history item")
    }
    historyAssertions += 1
    dispatch(upArrow)
    guard textView.string == "accepted one" else {
        throw fail("repeated Up did not walk toward older accepted prompts")
    }
    historyAssertions += 1
    dispatch(downArrow)
    guard textView.string == "accepted two", promptHistory.isNavigating(for: historyAgentA) else {
        throw fail("Down in history did not walk toward newer accepted prompts")
    }
    historyAssertions += 1
    dispatch(downArrow)
    guard textView.string == multilineDraft, !promptHistory.isNavigating(for: historyAgentA) else {
        throw fail("Down beyond newest history did not restore the exact multiline draft")
    }
    historyAssertions += 1

    promptHistory.recordAccepted("history first\nhistory second", for: historyAgentA)
    installHistoryText("boundary draft", selection: NSRange(location: 0, length: 0))
    dispatch(upArrow)
    guard textView.string == "history first\nhistory second",
          promptHistory.isNavigating(for: historyAgentA) else {
        throw fail("the multiline history fixture did not enter history mode")
    }
    textView.setSelectedRange(NSRange(location: 2, length: 0))
    dispatch(downArrow)
    guard textView.string == "history first\nhistory second",
          promptHistory.isNavigating(for: historyAgentA),
          textView.selectedRange().location > 2 else {
        throw fail("Down before the last visual line did not remain native")
    }
    historyAssertions += 1
    textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    dispatch(downArrow)
    guard textView.string == "boundary draft", !promptHistory.isNavigating(for: historyAgentA) else {
        throw fail("Down on the last visual line did not restore the preserved draft")
    }
    historyAssertions += 1

    promptHistory.cancelNavigation(for: historyAgentA)
    let wrappedDraft = String(repeating: "wrapped text ", count: 80)
    installHistoryText(
        wrappedDraft,
        selection: NSRange(location: (wrappedDraft as NSString).length, length: 0)
    )
    let lineHeight = textView.layoutManager?.defaultLineHeight(for: textView.font ?? .token(.body)) ?? 17
    guard textView.measuredDocumentHeight() > lineHeight * 2 else {
        throw fail("soft-wrap fixture did not produce multiple TextKit visual lines")
    }
    historyAssertions += 1
    let wrappedEnd = textView.selectedRange().location
    dispatch(upArrow)
    guard textView.string == wrappedDraft,
          textView.selectedRange().location < wrappedEnd,
          !promptHistory.isNavigating(for: historyAgentA) else {
        throw fail("Up inside a soft-wrapped line did not remain native")
    }
    historyAssertions += 1
    textView.setSelectedRange(NSRange(location: 1, length: 0))
    dispatch(upArrow)
    guard textView.string == "history first\nhistory second",
          promptHistory.isNavigating(for: historyAgentA) else {
        throw fail("Up on the first soft-wrapped visual line did not enter history")
    }
    historyAssertions += 1
    textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    dispatch(downArrow)
    guard textView.string == wrappedDraft, !promptHistory.isNavigating(for: historyAgentA) else {
        throw fail("soft-wrapped history navigation did not restore its exact draft")
    }
    historyAssertions += 1

    for modifiers: NSEvent.ModifierFlags in [.shift, .command, .option, .control] {
        promptHistory.cancelNavigation(for: historyAgentA)
        installHistoryText("modified arrow", selection: NSRange(location: 0, length: 0))
        dispatch(try key(126, "\u{f700}", modifiers))
        guard textView.string == "modified arrow",
              !promptHistory.isNavigating(for: historyAgentA) else {
            throw fail("a modified Up arrow was repurposed for prompt history")
        }
        historyAssertions += 1
    }

    promptHistory.cancelNavigation(for: historyAgentA)
    installHistoryText("selected arrow", selection: NSRange(location: 0, length: 3))
    dispatch(upArrow)
    guard textView.string == "selected arrow", !promptHistory.isNavigating(for: historyAgentA) else {
        throw fail("Up with a noncollapsed selection entered prompt history")
    }
    historyAssertions += 1

    promptHistory.cancelNavigation(for: historyAgentA)
    installHistoryText("trailing line\n", selection: NSRange(location: 14, length: 0))
    dispatch(upArrow)
    guard textView.string == "trailing line\n", !promptHistory.isNavigating(for: historyAgentA) else {
        throw fail("Up from a trailing empty visual line incorrectly entered history")
    }
    historyAssertions += 1

    installHistoryText("draft before edit", selection: NSRange(location: 0, length: 0))
    dispatch(upArrow)
    guard promptHistory.isNavigating(for: historyAgentA) else {
        throw fail("edit-cancellation fixture did not enter history")
    }
    textView.insertText("!", replacementRange: NSRange(location: (textView.string as NSString).length, length: 0))
    let editedHistoryText = textView.string
    guard !promptHistory.isNavigating(for: historyAgentA), editedHistoryText.hasSuffix("!") else {
        throw fail("editing a recalled prompt did not cancel history navigation")
    }
    historyAssertions += 1
    dispatch(downArrow)
    guard textView.string == editedHistoryText else {
        throw fail("Down after editing a recalled prompt restored a stale preserved draft")
    }
    historyAssertions += 1

    promptHistory.cancelNavigation(for: historyAgentA)
    installHistoryText("ime arrows", selection: NSRange(location: 0, length: 0))
    textView.setMarkedText(
        "候",
        selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: 0, length: 0)
    )
    dispatch(upArrow)
    guard !promptHistory.isNavigating(for: historyAgentA) else {
        throw fail("Up during marked IME text entered prompt history")
    }
    textView.unmarkText()
    historyAssertions += 1

    return 13 + historyAssertions
}

private final class CompletionProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var started = 0
    private var returned = 0
    private var queries: [String] = []

    func record(_ query: String) { lock.withLock { queries.append(query) } }
    func markStarted() { lock.withLock { started += 1 } }
    func markReturned() { lock.withLock { returned += 1 } }
    var startedCount: Int { lock.withLock { started } }
    var returnedCount: Int { lock.withLock { returned } }
    var observedQueries: [String] { lock.withLock { queries } }
}

/// The stale branch deliberately ignores task cancellation and completes after a
/// newer query. This reaches the presentation generation guard directly rather
/// than being filtered by `AgentCompletionProviderRegistry` first.
private struct CompletionProbeSource: AgentCompletionSuggestionSource {
    let state: CompletionProbeState

    func suggestions(for query: AgentCompletionQuery) async -> [AgentCompletion] {
        state.record(query.text)
        if query.text == "s" {
            state.markStarted()
            let values = await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.18) {
                    continuation.resume(returning: [
                        AgentCompletion(id: "stale", title: "stale", insertionText: "/stale")
                    ])
                }
            }
            state.markReturned()
            return values
        }
        guard query.text.hasPrefix("he") else { return [] }
        return [
            AgentCompletion(id: "help", title: "help", insertionText: "/help"),
            AgentCompletion(id: "hello", title: "hello", insertionText: "/hello"),
        ]
    }
}

@MainActor
private func runCompletionComposerChecks() async throws -> Int {
    struct CheckError: Error, CustomStringConvertible { let description: String }
    func fail(_ message: String) -> CheckError {
        CheckError(description: "composer completion contract: \(message)")
    }
    func event(keyCode: UInt16, characters: String, windowNumber: Int) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else { throw fail("could not make a synthetic key event") }
        return event
    }

    let composer = AgentComposerView(frame: NSRect(x: 0, y: 0, width: 480, height: 96))
    let textView = composer.textView
    let state = CompletionProbeState()
    composer.qaBindCompletionSource(CompletionProbeSource(state: state))
    let window = NSWindow(
        contentRect: NSRect(x: 500, y: 500, width: 480, height: 96),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.contentView = composer
    window.makeKey()
    guard window.makeFirstResponder(textView), composer.isEditorFocused else {
        throw fail("could not keep the native text view first responder")
    }
    defer {
        composer.removeFromSuperview()
        window.orderOut(nil)
        window.close()
    }

    func replaceText(_ value: String, caret: Int? = nil) {
        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.insertText(value, replacementRange: fullRange)
        let location = caret ?? (value as NSString).length
        textView.setSelectedRange(NSRange(location: location, length: 0))
        // AppKit normally calls these delegate methods from its field editor event
        // path; the headless check invokes the same production callbacks after its
        // programmatic fixture replacement.
        textView.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        textView.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: textView)
        )
    }
    func dispatch(_ event: NSEvent) { window.sendEvent(event) }

    // Start a source that ignores cancellation, then replace it with a newer query.
    replaceText("/s")
    guard AgentCompletionQueryDetector.activeQuery(
        in: textView.string, selection: textView.selectedRange()
    )?.text == "s" else {
        throw fail("the production editor did not hold the /s query: \(textView.string) / \(textView.selectedRange())")
    }
    guard await waitUntil(timeout: 1, pollInterval: 0.01, { state.startedCount >= 1 }) else {
        throw fail("the uncooperative stale source never started from \(textView.string) / \(textView.selectedRange()); focused=\(composer.isEditorFocused), window=\(textView.window != nil), requestTasks=\(composer.qaCompletionRequestStartCount), queries=\(state.observedQueries)")
    }
    try await Task.sleep(nanoseconds: 20_000_000)
    let firstStaleRequestCount = state.startedCount
    replaceText("/he")
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        composer.qaCompletionIsPresented && composer.qaCompletionTitles == ["help", "hello"]
    }) else {
        throw fail("real text/selection callbacks did not present the newer query")
    }
    guard window.firstResponder === textView else {
        throw fail("the passive completion panel stole first responder from TextKit")
    }
    guard let panelFrame = composer.qaCompletionPanelFrame else {
        throw fail("the real completion panel has no frame")
    }
    let caretFrame = textView.firstRect(
        forCharacterRange: textView.selectedRange(), actualRange: nil
    )
    guard abs(panelFrame.minX - caretFrame.minX) <= 1 else {
        throw fail("panel x \(panelFrame.minX) is not anchored to caret x \(caretFrame.minX)")
    }
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        state.returnedCount >= firstStaleRequestCount
    }) else {
        throw fail("the uncooperative stale source never returned")
    }
    try await Task.sleep(nanoseconds: 30_000_000)
    guard composer.qaCompletionTitles == ["help", "hello"] else {
        throw fail("a stale generation repainted the newer suggestions as \(composer.qaCompletionTitles)")
    }

    // Continued typing stays on the native editor while the passive panel is open.
    dispatch(try event(keyCode: 37, characters: "l", windowNumber: window.windowNumber))
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        textView.string == "/hel" && composer.qaCompletionTitles == ["help", "hello"]
    }), window.firstResponder === textView else {
        throw fail("continued native typing or first-responder retention failed")
    }

    // Unmodified navigation is forwarded while TextKit stays first responder.
    dispatch(try event(keyCode: 125, characters: "", windowNumber: window.windowNumber))
    guard composer.qaCompletionFocusedTitle == "hello" else {
        throw fail("Down did not move completion focus")
    }
    dispatch(try event(keyCode: 115, characters: "", windowNumber: window.windowNumber))
    guard composer.qaCompletionFocusedTitle == "help" else {
        throw fail("Home did not move completion focus to the first row")
    }
    dispatch(try event(keyCode: 119, characters: "", windowNumber: window.windowNumber))
    guard composer.qaCompletionFocusedTitle == "hello" else {
        throw fail("End did not move completion focus to the last row")
    }
    dispatch(try event(keyCode: 126, characters: "", windowNumber: window.windowNumber))
    guard composer.qaCompletionFocusedTitle == "help" else {
        throw fail("Up did not move completion focus")
    }

    // Return follows the real list focus/selection path and insertion is one undo.
    dispatch(try event(keyCode: 36, characters: "\r", windowNumber: window.windowNumber))
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        textView.string == "/help" && !composer.qaCompletionIsPresented
    }) else {
        throw fail("Return did not insert the focused completion and dismiss once")
    }
    try await Task.sleep(nanoseconds: 30_000_000)
    guard !composer.qaCompletionIsPresented else {
        throw fail("the accepted completion immediately reopened its own query")
    }
    guard textView.undoManager?.canUndo == true else {
        throw fail("completion insertion did not register a native undo unit")
    }
    textView.undoManager?.undo()
    guard textView.string == "/hel" else {
        throw fail("one Undo did not restore the complete pre-insertion query")
    }

    // Escape and moving the caret before the trigger cancel the visible request.
    guard await waitUntil(timeout: 1, pollInterval: 0.01, { composer.qaCompletionIsPresented }) else {
        throw fail("Undo did not drive the real query path again")
    }
    dispatch(try event(keyCode: 53, characters: "\u{1b}", windowNumber: window.windowNumber))
    guard !composer.qaCompletionIsPresented, textView.string == "/hel" else {
        throw fail("Escape mutated text or left the completion surface visible")
    }
    replaceText("/he", caret: 0)
    guard !composer.qaCompletionIsPresented else {
        throw fail("moving the caret before the trigger left suggestions actionable")
    }

    // Detaching cancels an in-flight uncooperative request and removes its panel.
    let startedBeforeDetach = state.startedCount
    replaceText("/s")
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        state.startedCount > startedBeforeDetach
    }) else {
        throw fail("the detach cancellation request never started")
    }
    try await Task.sleep(nanoseconds: 20_000_000)
    let detachRequestCount = state.startedCount
    composer.removeFromSuperview()
    guard !composer.qaCompletionIsPresented else {
        throw fail("detaching the composer left its completion panel visible")
    }
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        state.returnedCount >= detachRequestCount
    }) else {
        throw fail("the detached uncooperative source never returned for the guard assertion")
    }
    guard !composer.qaCompletionIsPresented else {
        throw fail("a stale detached request resurrected the completion panel")
    }

    return 25
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
    let composerKeyAssertions = try runComposerKeyContractChecks()
    let completionAssertions = try await runCompletionComposerChecks()

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
    let liveV2Report = try await checkLiveV2TileMigration(store: store, config: config, cwd: cwd, fail: fail)
    let capabilityReport = try await checkTurnCapabilityRepaint(store: store, config: config, cwd: cwd, fail: fail)

    // MARK: 8 · closing a tile is closing a window, not ending the work (P2A.5)

    let detachReport = try await checkDetachOutlivesItsTile(store: store, config: config, cwd: cwd, fail: fail)

    // MARK: 9 · an agent exists and runs with no tile at all (P2A.6)

    let headlessReport = try await checkHeadlessAgents(store: store, config: config, cwd: cwd, fail: fail)

    // MARK: 10 · an isolated spawn works in its own checkout (P2C.2)

    let isolationReport = try await checkIsolatedSpawn(config: config, fail: fail)

    // MARK: 11 · archiving an agent cleans up after it, without losing work (P2C.3)

    let cleanupReport = try await checkArchiveCleanup(config: config, fail: fail)

    // MARK: 12 · a tile SAYS which checkout its agent is about to touch (P2C.4)

    let branchReport = try await checkBranchChip(config: config, fail: fail)

    // MARK: 13 · an observed spawn_agent call becomes a child agent (P2D.2)

    let spawnCallReport = try await checkSpawnFromToolCall(config: config, fail: fail)

    // MARK: 14 · a turn you did not watch is unread, and looking clears it (P3.3)

    let readStateReport = try await checkReadState(config: config, cwd: cwd, fail: fail)

    // MARK: 15 · real work un-settles a settled agent; a refresh does not (P4.4)

    let unsettleReport = try await checkAutoUnsettle(config: config, cwd: cwd, fail: fail)

    // MARK: 16 · the model and the effort level belong to the AGENT, not to Settings (P6.1)

    let providerReport = try await checkPerAgentProviderSettings(cwd: cwd, fail: fail)

    // MARK: 17 · a row's status is the TURN's state, not the process's (P4.14)

    let rowStatusReport = try await AppDelegate.checkRowStatusIsTurnState(config: config, cwd: cwd, fail: fail)

    // MARK: 18 · every semantic kind has one frozen renderer, with a safe fallback (91/P3.1)

    let rendererReport = try checkAgentBlockRendererRegistry(fail: fail)

    // MARK: 19 · tile state and actions follow turn facts/capabilities (91/P5.2)

    let turnStateReport = try await checkCapabilityDrivenTurnStates(config: config, cwd: cwd, fail: fail)

    for task in [taskA, taskB, taskC, taskD] { task.cancel() }
    print("AgentSupervisor: \(script.count) events fanned out to 2 live + 1 late subscriber, spawn persisted headless, stop made a blocked run() return, a send on a busy agent refused, \(composerKeyAssertions) composer key/IME/undo/history assertions, \(completionAssertions) production completion assertions, \(scannedFiles) source files scanned for stray runner construction; \(tileReport); \(liveV2Report); \(capabilityReport); \(detachReport); \(headlessReport); \(isolationReport); \(cleanupReport); \(branchReport); \(spawnCallReport); \(readStateReport); \(unsettleReport); \(providerReport); \(rowStatusReport); \(rendererReport); \(turnStateReport)")
}

@MainActor
private func checkCapabilityDrivenTurnStates<Failure: Error>(
    config: AgentModelConfig.Resolution,
    cwd: URL,
    fail: (String) -> Failure
) async throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-turn-state-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentStore(applicationSupportDirectory: root)
    let runner = ScriptedAgentRunner(
        script: [
            .turnStarted(threadId: "provider", turnId: "turn-1"),
            .sessionStateChanged(.ready),
        ],
        holdUntilStopped: true
    )
    let supervisor = AgentSupervisor(store: store, makeRunner: { _ in runner })
    let id = supervisor.spawn(
        role: nil, prompt: "work", cwd: cwd, model: config.model, thinking: config.thinking
    )
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        runner.runCount == 1 && supervisor.turnSnapshot(for: id)?.state == .ready
    }) else {
        throw fail("turn-state: scripted ready event did not arrive")
    }
    guard supervisor.isRunning(id), supervisor.turnSnapshot(for: id)?.state == .ready else {
        throw fail("turn-state: process alive but explicitly idle did not present Ready")
    }
    guard supervisor.turnSnapshot(for: id)?.capabilities.canSend == false else {
        throw fail("turn-state: occupied send transport advertised acceptance")
    }
    guard supervisor.turnSnapshot(for: id)?.capabilities.canStop == true else {
        throw fail("turn-state: an in-flight alive-but-idle runner lost its Stop — the spawn/drain windows must stay interruptible (P5.5 consolidation)")
    }
    supervisor.qaDeliver(.turnStarted(
        threadId: AgentSupervisor.threadId(for: id), turnId: "turn-2"
    ), to: id)
    guard let working = supervisor.turnSnapshot(for: id),
          working.state == .working, working.capabilities.canStop else {
        throw fail("turn-state: explicit turnStarted did not present stoppable Working")
    }
    supervisor.qaDeliver(.turnCompleted(
        threadId: AgentSupervisor.threadId(for: id),
        turnId: "turn-2",
        outcome: .completed,
        errorMessage: nil
    ), to: id)

    supervisor.qaDeliver(.requestOpened(
        threadId: AgentSupervisor.threadId(for: id),
        requestId: "request-1",
        kind: .commandExecutionApproval
    ), to: id)
    guard let requestSnapshot = supervisor.turnSnapshot(for: id),
          case let .needsAction(request) = requestSnapshot.state,
          request.requestID == "request-1",
          request.prompt.contains("command"),
          request.responseMode == .fixedChoice([
              ApprovalDecision.accept.rawValue,
              ApprovalDecision.acceptForSession.rawValue,
              ApprovalDecision.decline.rawValue,
              ApprovalDecision.cancel.rawValue,
          ]) else {
        throw fail("turn-state: Needs action did not retain matching provider request context and choices")
    }
    let needsPresentation = AgentTileStatePresenter.present(
        name: "Checker",
        snapshot: requestSnapshot,
        branchContext: nil,
        startedAt: Date(timeIntervalSince1970: 1),
        now: Date(timeIntervalSince1970: 3)
    )
    guard needsPresentation.revealRequestID == "request-1",
          needsPresentation.availableActionDescription == "Reveal provider request",
          needsPresentation.stateAccessibilityLabel.contains("accept") else {
        throw fail("turn-state: Needs action presentation cannot reveal its real request and choices")
    }

    supervisor.qaDeliver(.requestResolved(
        threadId: AgentSupervisor.threadId(for: id), requestId: "request-1", decision: "accept"
    ), to: id)
    guard supervisor.turnSnapshot(for: id)?.state == .ready else {
        throw fail("turn-state: resolved request did not restore explicit Ready")
    }
    supervisor.qaDeliver(.runtimeError(
        threadId: AgentSupervisor.threadId(for: id), message: "provider failed"
    ), to: id)
    guard supervisor.turnSnapshot(for: id)?.state == .failed(message: "provider failed") else {
        throw fail("turn-state: runtime error did not present Failed")
    }

    // Required negative semantics: a user-input event with no response-mode
    // capability must remain fixed-choice([]). Treating empty choices as freeform
    // would make this named assertion red.
    supervisor.qaDeliver(.userInputRequested(
        threadId: AgentSupervisor.threadId(for: id),
        requestId: "question-1",
        questions: [.init(key: "answer", prompt: "Explain")]
    ), to: id)
    guard let inputSnapshot = supervisor.turnSnapshot(for: id),
          case let .needsAction(inputRequest) = inputSnapshot.state,
          inputRequest.responseMode == .fixedChoice([]) else {
        throw fail("turn-state negative witness: empty choices fabricated a freeform response capability")
    }

    guard await supervisor.accept(.queue("not supported"), for: id) == .refused(.unsupported) else {
        throw fail("turn-state: conservative runtime accepted a fabricated queue intent")
    }
    let draftBeforeRefusal = "keep this draft"
    guard await supervisor.accept(.send(draftBeforeRefusal), for: id) == .refused(.turnNotReady) else {
        throw fail("turn-state: send while Needs action was not refused")
    }

    // Exercise the real composer acceptance boundary: refusal keeps the exact
    // edited draft; acceptance clears it only after the sink reports success.
    let composer = AgentComposerView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
    composer.apply(.init(
        text: draftBeforeRefusal,
        selection: NSRange(location: (draftBeforeRefusal as NSString).length, length: 0),
        revision: 7
    ))
    let refusingSink = ScriptedTileActionSink(.refused(.turnNotReady))
    composer.bindActionSink(
        refusingSink,
        agentID: id,
        snapshot: .init(
            state: .ready,
            capabilities: .sendStop(canSend: true, canStop: false),
            turnStartedAt: nil
        )
    )
    composer.composerRequestedSend(composer.textView)
    guard await waitUntil(timeout: 1, pollInterval: 0.01, { refusingSink.intents.count == 1 }),
          composer.textView.string == draftBeforeRefusal else {
        throw fail("turn-state: refused composer send cleared or changed its draft")
    }
    // The dealloc-mid-submit latch (P5.5 correction, defect 3): the composer
    // holds its sink weakly, so a submit whose sink dies before the action task
    // runs resolves a nil acceptance — that exit must still release the
    // single-flight latch, or no sink bound afterwards can ever dispatch.
    var dyingSink: ScriptedTileActionSink? = ScriptedTileActionSink(.accepted)
    composer.bindActionSink(
        dyingSink!,
        agentID: id,
        snapshot: .init(
            state: .ready,
            capabilities: .sendStop(canSend: true, canStop: false),
            turnStartedAt: nil
        )
    )
    composer.composerRequestedSend(composer.textView)
    dyingSink = nil
    let acceptingSink = ScriptedTileActionSink(.accepted)
    composer.bindActionSink(
        acceptingSink,
        agentID: id,
        snapshot: .init(
            state: .ready,
            capabilities: .sendStop(canSend: true, canStop: false),
            turnStartedAt: nil
        )
    )
    composer.composerRequestedSend(composer.textView)
    guard await waitUntil(timeout: 1, pollInterval: 0.01, {
        acceptingSink.intents.count == 1 && composer.textView.string.isEmpty
    }) else {
        throw fail("turn-state: a submit whose sink deallocated latched the composer — the sink bound after it never dispatched (dispatches \(acceptingSink.intents.count))")
    }

    supervisor.qaDeliver(.turnStarted(
        threadId: AgentSupervisor.threadId(for: id), turnId: "turn-stop"
    ), to: id)
    guard await supervisor.accept(.stop, for: id) == .accepted else {
        throw fail("turn-state: stoppable turn was refused by the shared action sink")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { runner.completedRuns == 1 }) else {
        throw fail("turn-state: accepted stop did not release runner")
    }
    guard await supervisor.accept(.stop, for: id) == .refused(.noTurnInProgress) else {
        throw fail("turn-state: stop without a turn was reported accepted")
    }

    // Restored is a durable supervisor fact, not inferred from a blank view.
    let restoredRecord = AgentRecord(
        id: AgentID(rawValue: UUID()),
        displayName: "Restored",
        role: nil,
        model: config.model,
        thinking: config.thinking,
        cwd: cwd.path,
        worktreeBranch: nil,
        projectId: nil,
        parentAgentID: nil,
        sourceItemId: nil,
        createdAt: Date(),
        lastActivityAt: Date(),
        tileId: nil
    )
    try store.upsert(restoredRecord)
    let restoredSupervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) })
    _ = restoredSupervisor.restore()
    guard let restored = restoredSupervisor.turnSnapshot(for: restoredRecord.id),
          restored.state == .restored,
          restored.capabilities.canSend else {
        throw fail("turn-state: restored idle agent did not present Restored with Send available")
    }

    // Presentation exhausts the states that have no current transport producer too:
    // missing queue capability means unavailable, not omission from the vocabulary.
    let queued = AgentTileStatePresenter.present(
        name: "Checker",
        snapshot: .init(state: .queued, capabilities: .sendStop(canSend: false, canStop: false), turnStartedAt: nil),
        branchContext: nil,
        startedAt: Date(timeIntervalSince1970: 1),
        now: Date(timeIntervalSince1970: 2)
    )
    let restoredPresentation = AgentTileStatePresenter.present(
        name: "Checker", snapshot: restored, branchContext: nil, startedAt: nil
    )
    guard queued.stateLabel == "Queued", queued.stateAccessibilityLabel.contains("No immediate"),
          restoredPresentation.stateLabel == "Restored",
          restoredPresentation.availableActionDescription == "Send a prompt to continue" else {
        throw fail("turn-state: queued/restored presentation omitted truthful action accessibility")
    }

    return "capability turn states: process-alive Ready, explicit Working, request reveal with fixed choices, Failed, Restored/Queued presentation, accepted Stop, refused queue/send/stop, and empty-choice negative witness held"
}

@MainActor
private func checkAgentBlockRendererRegistry<Failure: Error>(
    fail: (String) -> Failure
) throws -> String {
    let registry = AgentBlockRendererRegistry.production
    guard registry.isFrozen else {
        throw fail("production block renderer registry is not frozen after bootstrap")
    }
    guard Set(AgentBlockRendererRegistry.builtInKinds).count == 16 else {
        throw fail("block renderer built-in fixture is incomplete or duplicated: \(AgentBlockRendererRegistry.builtInKinds.map(\.rawValue))")
    }

    var identities = Set<ObjectIdentifier>()
    for kind in AgentBlockRendererRegistry.builtInKinds {
        guard registry.registrationCount(for: kind) == 1 else {
            throw fail("block kind '\(kind.rawValue)' did not resolve exactly once")
        }
        identities.insert(ObjectIdentifier(try registry.renderer(for: kind)))
    }
    // Fifteen bootstrap renderers plus the one fallback. This catches an
    // accidental many-kinds-to-one registration shortcut as well as omissions.
    guard identities.count == AgentBlockRendererRegistry.builtInKinds.count else {
        throw fail("built-in block kinds resolved to \(identities.count) renderer instances, expected 16")
    }

    let futureKind = AgentBlockKind(rawValue: "provider.future-card.v3")!
    let unknown = try registry.renderer(for: .unknown)
    guard ObjectIdentifier(try registry.renderer(for: futureKind)) == ObjectIdentifier(unknown) else {
        throw fail("an unregistered provider kind did not resolve to the mandatory unknown fallback")
    }

    // Malformed bootstraps must hit their named errors. The ownership witness is
    // important: dictionary registration may not override the renderer's own
    // declaration, nor reuse that renderer for another semantic family.
    let duplicate = AgentBlockRendererRegistry()
    try duplicate.register(
        AgentDeferredBlockRenderer(kind: .paragraph, safeLabel: "first"),
        for: .paragraph
    )
    do {
        try duplicate.register(
            AgentDeferredBlockRenderer(kind: .paragraph, safeLabel: "second"),
            for: .paragraph
        )
        throw fail("duplicate-registration witness did not fail")
    } catch let error as AgentBlockRendererRegistryError {
        guard error == .duplicateKind(.paragraph) else {
            throw fail("duplicate-registration witness failed with unnamed error: \(error)")
        }
    }

    let mismatched = AgentBlockRendererRegistry()
    let paragraphRenderer = AgentDeferredBlockRenderer(kind: .paragraph, safeLabel: "paragraph")
    do {
        try mismatched.register(paragraphRenderer, for: .heading)
        throw fail("renderer-ownership witness did not fail")
    } catch let error as AgentBlockRendererRegistryError {
        guard error == .mismatchedKind(expected: .heading, declared: .paragraph) else {
            throw fail("renderer-ownership witness failed with unnamed error: \(error)")
        }
    }

    let missingFallback = AgentBlockRendererRegistry()
    do {
        try missingFallback.freeze()
        throw fail("missing-fallback witness did not fail")
    } catch let error as AgentBlockRendererRegistryError {
        guard error == .missingFallback else {
            throw fail("missing-fallback witness failed with unnamed error: \(error)")
        }
    }

    do {
        try registry.register(
            AgentDeferredBlockRenderer(kind: futureKind, safeLabel: "late"),
            for: futureKind
        )
        throw fail("frozen-registry witness did not fail")
    } catch let error as AgentBlockRendererRegistryError {
        guard error == .registryFrozen else {
            throw fail("frozen-registry witness failed with wrong error: \(error)")
        }
    }

    let sourceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("Sources/ContinuumRevived/Canvas")
    let switchScanPaths = [
        sourceRoot.appendingPathComponent("AgentTranscript"),
        sourceRoot.appendingPathComponent("ManagedAgentTileNSView.swift")
    ]
    var scanned = 0
    for path in switchScanPaths {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else { continue }
        let files: [URL]
        if isDirectory.boolValue {
            files = (FileManager.default.enumerator(at: path, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" }) ?? []
        } else {
            files = [path]
        }
        for file in files {
            scanned += 1
            let source = try String(contentsOf: file, encoding: .utf8)
            let blockKindSwitch = source.range(
                of: #"switch\s+block\s*\.\s*kind"#,
                options: .regularExpression
            ) != nil
            guard !blockKindSwitch else {
                throw fail("\(file.lastPathComponent) switches on AgentBlockKind instead of resolving through the registry")
            }
        }
    }
    guard scanned >= 3 else {
        throw fail("renderer kind-switch source check scanned only \(scanned) files")
    }

    return "renderer registry: 16 unique built-ins, ownership/duplicate/missing/frozen witnesses named, unknown fallback shared, \(scanned) tile/transcript sources free of block-kind switches"
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
    // The signature carries P3.9's `agentID:` — revealing a headless agent wires an
    // agent that already exists into a fresh tile. Still an EXACT match, so a rename
    // still turns this scan red rather than blind.
    let wiring = try paletteAgentSpawnBranch("private func wireManagedAgentTile(_ tileId: UUID, agentID: AgentID? = nil) {")
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

private final class CapabilityRepaintRunnerBox: @unchecked Sendable {
    var made: [ScriptedAgentRunner] = []
}

/// P5.5 correction gate (`plan-P5.5-review-corrections.md` defect 1). The Pi
/// process prints its terminal turn events before it exits, so the runner slot
/// frees strictly AFTER the last runtime event a tile ever ingests — the tile's
/// repaint of that transition rides the supervisor's capability seam, never a
/// fabricated event. `qaDeliver` cannot represent this race (no runner exists on
/// that path, which is exactly how the latch shipped); this leg drives it with a
/// real held-open scripted runner. The required negative witness is disconnecting
/// `notifyTurnCapabilitiesChanged` from `clearRunner`: the slot-free repaint
/// assertion below goes red.
@MainActor
private func checkTurnCapabilityRepaint<Failure: Error>(
    store: AgentStore,
    config: AgentModelConfig.Resolution,
    cwd: URL,
    fail: (String) -> Failure
) async throws -> String {
    // One FRESH runner per send, as production's makeRunner does: reusing one
    // instance across rounds defeats clearRunner's identity check — a previous
    // round's late completion would clear the next round's slot.
    let box = CapabilityRepaintRunnerBox()
    let supervisor = AgentSupervisor(store: store, makeRunner: { _ in
        let runner = ScriptedAgentRunner(script: [], holdUntilStopped: true)
        box.made.append(runner)
        return runner
    })
    let tileID = UUID()
    let agentID = supervisor.spawn(
        role: "capability-repaint",
        prompt: nil,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking,
        tileId: tileID
    )
    let thread = AgentSupervisor.threadId(for: agentID)
    let tile = ManagedAgentTileNSView(tile: Tile(
        id: tileID,
        kind: .managedAgent,
        title: "capability-repaint",
        frame: TileFrame(x: 0, y: 0, width: 520, height: 420),
        zPosition: .fromLegacyRank(1),
        runtimeRef: nil,
        metadata: TileMetadata(launchProfileId: "managed")
    ))
    tile.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
    tile.attach(agentID: agentID, supervisor: supervisor)
    defer { tile.detach() }

    // Round 1 — the SPAWN window (P5.5 consolidation). The seam fires inside
    // `send` itself, so the button offers Stop before any runtime event exists —
    // and that Stop is callable: it kills the spawning runner.
    supervisor.send("first prompt", to: agentID)
    guard tile.qaV2ActionTitle == "Stop",
          supervisor.turnSnapshot(for: agentID)?.capabilities.canStop == true else {
        throw fail("capability-repaint: send did not synchronously present a stoppable flight (action '\(tile.qaV2ActionTitle ?? "nil")')")
    }
    guard let spawnRunner = box.made.first else {
        throw fail("capability-repaint: send made no runner")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { spawnRunner.runCount == 1 }) else {
        throw fail("capability-repaint: the scripted runner never ran")
    }
    guard await supervisor.accept(.stop, for: agentID) == .accepted else {
        throw fail("capability-repaint: stop during the spawn window was refused")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        spawnRunner.stopCount == 1 && spawnRunner.completedRuns == 1 && tile.qaV2ActionTitle == "Send"
    }) else {
        throw fail("capability-repaint: stopping the spawning runner did not release the flight (stops \(spawnRunner.stopCount), completed \(spawnRunner.completedRuns), action '\(tile.qaV2ActionTitle ?? "nil")')")
    }
    // Let round 1's `.stopped` delivery land before counting round 2's events.
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { tile.ingestedEvents.count == 1 }) else {
        throw fail("capability-repaint: the stop's session event never reached the tile (\(tile.ingestedEvents.count) ingested)")
    }

    // Round 2 — a full natural turn, ending in the DRAIN window: terminal events
    // arrive while the process is still alive and blocked in run().
    supervisor.send("second prompt", to: agentID)
    guard box.made.count == 2, let runner = box.made.last else {
        throw fail("capability-repaint: the second send did not make a fresh runner (\(box.made.count) made)")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { runner.runCount == 1 }) else {
        throw fail("capability-repaint: the second run never started")
    }
    guard runner.emit(.turnStarted(threadId: thread, turnId: "t1")),
          runner.emit(.turnCompleted(threadId: thread, turnId: "t1", outcome: .completed, errorMessage: nil)),
          runner.emit(.sessionStateChanged(.ready)) else {
        throw fail("capability-repaint: no run was in flight to emit the turn from")
    }
    // At the LAST event the tile will ever ingest, the slot is still held:
    // sending is truthfully impossible, and the drain window keeps the interrupt
    // affordance — never "Unavailable" — with the pickers dark alongside it. The
    // event count is part of the condition: spawn and drain deliberately look
    // identical at the button, so only the ingested turn distinguishes them.
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        tile.ingestedEvents.count == 4 && tile.qaV2CanSend == false
            && tile.qaV2ActionTitle == "Stop" && !tile.qaProviderControlsEnabled
    }) else {
        throw fail("capability-repaint: the drain window lost its Stop (canSend \(tile.qaV2CanSend), action '\(tile.qaV2ActionTitle ?? "nil")', pickers \(tile.qaProviderControlsEnabled ? "live" : "dark"), events \(tile.ingestedEvents.count))")
    }

    // The process exits; run() returns; the slot frees. No further runtime event.
    // The button offers Send again (its enablement then follows the draft, which
    // is the composer key contract's business, not this leg's).
    let eventsBeforeExit = tile.ingestedEvents.count
    runner.stop()
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        runner.completedRuns == 1 && tile.qaV2CanSend && tile.qaV2ActionTitle == "Send" && tile.qaProviderControlsEnabled
    }) else {
        throw fail("capability-repaint: composer stayed un-sendable after the runner slot freed — the capability seam did not repaint (canSend \(tile.qaV2CanSend), action '\(tile.qaV2ActionTitle ?? "nil")')")
    }
    // And nothing was fabricated to do it.
    guard tile.ingestedEvents.count == eventsBeforeExit else {
        throw fail("capability-repaint: the repaint rode a fabricated runtime event (\(tile.ingestedEvents.count) ingested, was \(eventsBeforeExit))")
    }
    // The advertised capability is transport-true: a third turn is accepted.
    let acceptance = await supervisor.accept(.send("third prompt"), for: agentID)
    guard case .accepted = acceptance else {
        throw fail("capability-repaint: the supervisor refused the third turn (\(acceptance))")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { box.made.count == 3 && box.made.last?.runCount == 1 }) else {
        throw fail("capability-repaint: the accepted third turn never reached a fresh runner (\(box.made.count) made)")
    }
    box.made.last?.stop()
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { box.made.last?.completedRuns == 1 }) else {
        throw fail("capability-repaint: the third run did not release")
    }
    return "spawn window stoppable, drain window kept Stop, slot-free repainted without an event, third turn ran"
}

/// P5.4 live migration gate. The required negative witness is the empty-choice
/// user-input request: it must render context but never acquire a fabricated text
/// editor or action. Changing that request to freeform makes this assertion red.
@MainActor
private func checkLiveV2TileMigration<Failure: Error>(
    store: AgentStore,
    config: AgentModelConfig.Resolution,
    cwd: URL,
    fail: (String) -> Failure
) async throws -> String {
    let supervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) })
    let tileID = UUID()
    let agentID = supervisor.spawn(
        role: "migration-check",
        prompt: nil,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking,
        tileId: tileID
    )
    let thread = AgentSupervisor.threadId(for: agentID)

    // Replay exists before the v2 view and tail follows after attach. Two deltas
    // update one stable semantic row rather than creating a second visible model.
    supervisor.qaDeliver(.turnStarted(threadId: thread, turnId: "v2-turn"), to: agentID)
    supervisor.qaDeliver(.contentDelta(
        threadId: thread, turnId: "v2-turn", streamKind: .assistant, delta: "replay"
    ), to: agentID)

    let tile = ManagedAgentTileNSView(tile: Tile(
        id: tileID,
        kind: .managedAgent,
        title: "migration-check",
        frame: TileFrame(x: 0, y: 0, width: 520, height: 420),
        zPosition: .fromLegacyRank(1),
        runtimeRef: nil,
        metadata: TileMetadata(launchProfileId: "managed")
    ))
    tile.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
    let draftStore = AgentComposerDraftStore(
        applicationSupportDirectory: store.layout.applicationSupportDirectory,
        debounceInterval: 60
    )
    let promptHistory = AgentPromptHistory()
    tile.bindV2ComposerState(draftStore: draftStore, promptHistory: promptHistory)
    tile.attach(agentID: agentID, supervisor: supervisor)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        tile.ingestedEvents.count == 2 && tile.qaRenderedCardCount == 1
    }) else {
        throw fail("live-v2: replay did not produce exactly one semantic row (events \(tile.ingestedEvents.count), rows \(tile.qaRenderedCardCount), error \(tile.qaV2RenderError ?? "none"))")
    }
    supervisor.qaDeliver(.contentDelta(
        threadId: thread, turnId: "v2-turn", streamKind: .assistant, delta: "→tail"
    ), to: agentID)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        tile.ingestedEvents.count == 3 && tile.qaRenderedCardCount == 1
    }) else {
        throw fail("live-v2: tail duplicated the stable semantic row (events \(tile.ingestedEvents.count), rows \(tile.qaRenderedCardCount))")
    }
    guard tile.qaUsesV2Tile, tile.qaUsesFullTurnComposer,
          !tile.qaHasLegacyComposeField, !tile.qaHasPermanentApprovalDock,
          tile.qaV2RenderError == nil else {
        throw fail("live-v2: migrated shell did not install semantic list/full-turn composer exclusively")
    }

    // The request block is projected by the content reducer, and a choice press
    // is a transport dispatch, never a resolution. The seam here refuses (as an
    // unbound production seam effectively does), so the request must remain
    // pending until the REAL runtime resolution event arrives.
    var dispatches: [(String, String)] = []
    tile.onProviderResponse = { requestID, value in
        dispatches.append((requestID, value))
        return false
    }
    supervisor.qaDeliver(.requestOpened(
        threadId: thread, requestId: "approval-live", kind: .commandExecutionApproval
    ), to: agentID)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        tile.qaV2RequestIDs == ["approval-live"]
            && tile.qaV2RequestChoices("approval-live") == ApprovalDecision.compiledChoices
    }) else {
        throw fail("live-v2: needs-attention did not reveal the matching fixed-choice request")
    }
    tile.layoutSubtreeIfNeeded()
    guard tile.qaClickV2RequestChoice(
        requestID: "approval-live", value: ApprovalDecision.decline.rawValue
    ) else {
        throw fail("live-v2: provider choice was not a clickable action in the semantic request block")
    }
    guard dispatches.count == 1, dispatches[0] == ("approval-live", ApprovalDecision.decline.rawValue),
          tile.qaV2RequestStatus("approval-live") == .inProgress else {
        throw fail("live-v2: a choice press without an accepting transport must dispatch exactly once and resolve nothing")
    }
    supervisor.qaDeliver(.requestResolved(
        threadId: thread, requestId: "approval-live", decision: ApprovalDecision.decline.rawValue
    ), to: agentID)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        tile.qaV2RequestStatus("approval-live") == .cancelled
    }) else {
        throw fail("live-v2: the runtime resolution event did not turn the request block passive")
    }
    _ = tile.qaClickV2RequestChoice(
        requestID: "approval-live", value: ApprovalDecision.decline.rawValue
    )
    guard dispatches.count == 1 else {
        throw fail("live-v2: a stale resolved request action fired twice")
    }

    // Required negative witness: empty choices are an explicit fixed-choice([]),
    // not evidence of freeform. The request remains readable without controls.
    supervisor.qaDeliver(.userInputRequested(
        threadId: thread,
        requestId: "input-without-contract",
        questions: [UserInputQuestion(key: "q", prompt: "Provide deployment context")]
    ), to: agentID)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        tile.qaV2RequestIDs.contains("input-without-contract")
    }) else {
        throw fail("live-v2: explicit input request context was not revealed")
    }
    guard tile.qaV2RequestChoices("input-without-contract") == [],
          !tile.qaV2HasCompactRequestEditor,
          !tile.qaClickV2RequestChoice(requestID: "input-without-contract", value: "fabricated") else {
        throw fail("live-v2 negative witness: fixedChoice([]) fabricated a response editor or action")
    }
    supervisor.qaDeliver(.userInputResolved(
        threadId: thread, requestId: "input-without-contract"
    ), to: agentID)
    supervisor.qaDeliver(.turnCompleted(
        threadId: thread, turnId: "v2-turn", outcome: .completed, errorMessage: nil
    ), to: agentID)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        supervisor.turnSnapshot(for: agentID)?.capabilities.canSend == true
            && tile.qaV2CanSend && tile.qaComposeEnabled
    }) else {
        throw fail("live-v2: tile did not return to a send-capable turn after requests resolved")
    }
    tile.qaSubmitPrompt("sent through the full-turn composer")
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        promptHistory.acceptedSubmissionCount(for: agentID) == 1
            && tile.qaTranscriptText.contains("sent through the full-turn composer")
    }) else {
        throw fail("live-v2: AgentID-bound composer did not accept, record history, and echo its prompt (history \(promptHistory.acceptedSubmissionCount(for: agentID)), transcript \(tile.qaTranscriptText))")
    }
    guard await draftStore.load(for: agentID) == nil else {
        throw fail("live-v2: accepted composer send did not clear the AgentID-bound draft")
    }

    // P5.4: forced reattach. Detaching the v2 view and re-attaching the same
    // agent replays the full history — request blocks included — exactly once
    // into a fresh reducer, with no duplicate nodes and no render error. The
    // branch refresh that ran on this v2 tile at turn completion must have
    // yielded a truthful no-chip for a non-repository cwd, not a shell failure.
    // Replay is event-sourced: the locally appended prompt row is not a runtime
    // event and transcript durability of local entries is an explicit program
    // non-goal, so exactly that one row is absent after a forced reattach.
    let rowsBeforeReattach = tile.qaRenderedCardCount
    let requestsBeforeReattach = tile.qaV2RequestIDs
    tile.detach()
    tile.attach(agentID: agentID, supervisor: supervisor)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        tile.qaRenderedCardCount == rowsBeforeReattach - 1
            && tile.qaV2RequestIDs == requestsBeforeReattach
            && tile.qaV2RenderError == nil
    }) else {
        throw fail("live-v2: reattach did not replay the event-sourced document exactly once (rows \(tile.qaRenderedCardCount) vs \(rowsBeforeReattach - 1) expected, requests \(tile.qaV2RequestIDs), error \(tile.qaV2RenderError ?? "none"))")
    }
    guard tile.qaV2RequestStatus("approval-live") == .cancelled else {
        throw fail("live-v2: reattach lost the resolved request's passive state")
    }
    // The check runs in a shared repo checkout, so the turn-completion branch
    // refresh must have produced a real chip through the v2 header contract —
    // never the shell-failure sentinel and never an empty label.
    guard let v2Chip = tile.qaBranchChipText, v2Chip.hasPrefix("⎇") else {
        throw fail("live-v2: v2 branch refresh did not yield a truthful chip for the shared checkout: \(tile.qaBranchChipText ?? "nil")")
    }

    // P5.5 acceptance removed the reversible construction seam with the legacy
    // path: v2 is the only tile. The rollback assertions this leg carried died
    // with it; the structural absences are asserted below on the live tile.
    guard !tile.qaHasLegacyComposeField, !tile.qaHasPermanentApprovalDock else {
        throw fail("live-v2: the legacy compose field or approval dock is reachable after the P5.5 removal")
    }

    let subscribersBeforeDetach = supervisor.subscriberCount(for: agentID)
    tile.detach()
    guard subscribersBeforeDetach == 1,
          await waitUntil(timeout: 5, pollInterval: 0.02, {
              supervisor.subscriberCount(for: agentID) == 0
          }),
          supervisor.records[agentID] != nil else {
        throw fail("live-v2: detach failed to cancel UI subscription or changed supervisor ownership")
    }
    return "v2 tile replayed then tailed one stable semantic row, sent and history-recorded one AgentID-bound full-turn draft with no legacy field/dock, revealed one reducer-projected fixed-choice request whose choice press dispatched once and resolved NOTHING until the real runtime resolution turned it passive, kept fixedChoice([]) read-only, reattached with an exactly-once replay including resolved request history and a truthful no-chip branch refresh, detached cleanly, with the legacy path structurally unreachable"
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
    // Waiting for the blocking turn's `.turnStarted` to have REACHED THE PROBE, not
    // merely for `run()` to have been entered: the runner emits on a background queue
    // and the supervisor hops each event to main, so `isRunning && runCount == 1` is
    // true while that first event is still in flight. Capturing `probeAtClose` under
    // that condition left a moving baseline, and the `+ 1` comparison below then
    // watched the count step 3 → 4 → 5 and never equal 4. Observed as
    // "an event produced after the tile closed did not reach the supervisor's
    // remaining subscriber: probe holds 5, was 3" in roughly one run in five.
    guard await waitUntil(timeout: 10, pollInterval: 0.02, {
        supervisor.isRunning(agentId) && blocking.runCount == 1
            && probe.events.last == .turnStarted(threadId: AgentSupervisor.threadId(for: agentId), turnId: "t2")
    }) else {
        throw fail("the blocking turn did not start; runCount \(blocking.runCount), probe last \(String(describing: probe.events.last))")
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
        throw fail("an event produced after the tile closed did not reach the supervisor's remaining subscriber: probe holds \(probe.events.count), was \(probeAtClose)")
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

/// A runner that replays P2D.1's REAL captured Pi stream through a REAL
/// `PiEventTranslator`, forwarding both halves: the normalized events to `onEvent`,
/// and the `spawn_agent` arguments to the side channel. So what MARK 13 drives is the
/// production reading path (fixture line → translator → runner seam → supervisor), not
/// a hand-made `SpawnRequest`.
final class FixtureStreamRunner: AgentRunning, @unchecked Sendable {
    private let lines: [String]
    private let lock = NSLock()
    private var spawnHandler: (@Sendable (SpawnRequest) -> Void)?
    private var promptsStorage: [String] = []

    init(lines: [String]) { self.lines = lines }

    var prompts: [String] { lock.withLock { promptsStorage } }

    func run(prompt: String, onEvent: @escaping @Sendable (AgentRuntimeEvent) -> Void) throws {
        lock.withLock { promptsStorage.append(prompt) }
        var translator = PiEventTranslator()
        if let handler = lock.withLock({ spawnHandler }) {
            translator.onSpawnRequest = handler
        }
        for line in lines {
            for event in translator.translate(line: line) { onEvent(event) }
        }
    }

    func stop() {}

    func observeSpawnRequests(_ handler: @escaping @Sendable (SpawnRequest) -> Void) {
        lock.withLock { spawnHandler = handler }
    }
}

/// A runner factory that hands a distinct runner to each agent and remembers which
/// record it was built for, so a child's own prompt and working directory can be read
/// back. The parent's runner is supplied; everybody else gets a fresh scripted one.
@MainActor
private final class SpawnedRunnerFactory {
    private(set) var records: [AgentRecord] = []
    private(set) var runners: [AgentID: ScriptedAgentRunner] = [:]
    private let parent: (id: AgentID, runner: AgentRunning)?

    init(parent: (id: AgentID, runner: AgentRunning)? = nil) { self.parent = parent }

    func make(_ record: AgentRecord) -> AgentRunning {
        records.append(record)
        if let parent, parent.id == record.id { return parent.runner }
        if let existing = runners[record.id] { return existing }
        let runner = ScriptedAgentRunner(script: [.sessionStateChanged(.ready)])
        runners[record.id] = runner
        return runner
    }
}

/// P2D.2 — an observed `spawn_agent` call becomes a real child agent.
///
/// Six properties, all against a temp `git init` repository (the fixture's call is
/// `isolated: true`, so a real worktree is created; P2C.1's inherited trap — the real
/// repository is never a `worktree add` target):
///   1. Replaying the REAL captured stream through the parent's runner produces
///      exactly ONE child, with the role and the prompt the model sent, `parentAgentID`
///      pointing at the emitting agent, the parent's project inherited, and — P2D.3 —
///      the model, thinking level and `--tools` its ROLE FILE declares.
///   2. The child actually RUNS that prompt — read off the child's own runner, so
///      "a child agent was created" is not satisfied by an inert record.
///   3. I5 — the child's prompt and role appear in NO event on the parent's stream and
///      in no activity event published from it, while `tool.spawn_agent` still does.
///   4. The isolated child's checkout is a SIBLING of the parent's, not nested inside
///      it: `<repo>/.worktrees/<child>`, with git agreeing.
///   5. The depth cap holds: a grandchild is allowed, a great-grandchild is refused,
///      and the refusal is SAID in the requesting agent's transcript.
///   6. The per-parent child cap holds, refusing does not disturb the children that
///      already exist, and children whose role declares no provider settings still
///      inherit the parent's (P2D.3).
///   7. A role this project does not define is REFUSED (P2D.3), said on the requesting
///      agent's transcript, without echoing the role id or a path.
///
/// Negative tests observed red at exit 1 with the final code are quoted at each
/// assertion.
@MainActor
private func checkSpawnFromToolCall(
    config: AgentModelConfig.Resolution,
    fail: (String) -> Error
) async throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-spawn-tool-call-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let repo = root.appendingPathComponent("repo", isDirectory: true)
    try makeIsolatedSpawnRepo(at: repo)
    // P2D.3 — the roles this project defines. The captured call asks for `code-scout`,
    // so it gets a model and a reasoning level DIFFERENT from the parent's: a child
    // that matched the parent by coincidence would prove nothing about resolution. The
    // others declare no provider settings, which is where inheritance is asserted.
    // Committed, because the isolated child works in a worktree and only tracked files
    // reach one — which is the property `runnerConfig(for:)` relies on.
    guard let scoutModel = AgentModelConfig.modelOptions.last else {
        throw fail("AgentModelConfig lists no models, so the role fixture cannot name one")
    }
    let scoutThinking = "xhigh"
    let scoutTools = "read, grep, find"
    guard scoutModel != config.model, scoutThinking != config.thinking else {
        throw fail("the role fixture must differ from the inherited settings, or the resolution assertions are vacuous")
    }
    try writeSpawnCheckRole(in: repo, id: "code-scout", model: scoutModel, reasoning: scoutThinking, tools: scoutTools)
    for id in ["grandchild"] + (1..<AgentSupervisor.maxChildrenPerParent).map({ "worker-\($0)" }) {
        try writeSpawnCheckRole(in: repo, id: id)
    }
    try runIsolatedSpawnGit(["add", ".pi"], in: repo)
    try runIsolatedSpawnGit([
        "-c", "user.email=qa@continuum.test",
        "-c", "user.name=Continuum QA",
        "commit", "-q", "--no-gpg-sign", "-m", "roles",
    ], in: repo)
    let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("support", isDirectory: true))

    // The same committed capture P2D.1 produced and `SpawnRequestChecks` parses —
    // one artifact, read from disk, not a copy of its contents.
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()          // App
        .deletingLastPathComponent()          // ContinuumRevived
        .deletingLastPathComponent()          // Sources
        .appendingPathComponent("ContinuumRevivedCoreChecks/Fixtures/spawn-agent-tool-call.jsonl", isDirectory: false)
    guard let fixtureText = try? String(contentsOf: fixtureURL, encoding: .utf8) else {
        throw fail("the captured spawn_agent stream is missing at \(fixtureURL.path)")
    }
    let capturedPrompt = "Find every call site of AgentSupervisor.spawn and report the file:line list."
    let capturedRole = "code-scout"
    guard fixtureText.contains(capturedPrompt), fixtureText.contains(capturedRole) else {
        throw fail("the capture no longer carries the arguments this check asserts on — re-check after a re-capture")
    }
    let lines = fixtureText.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)

    // MARK: 1–2 · the call becomes a child that runs the task

    let parentRunner = FixtureStreamRunner(lines: lines)
    let projectId = UUID()
    var factory: SpawnedRunnerFactory!
    let supervisor = AgentSupervisor(store: store, makeRunner: { factory.make($0) })
    factory = SpawnedRunnerFactory()
    // The parent is spawned WITHOUT a prompt so its id exists before its runner is
    // needed; the factory then hands it the fixture runner.
    let parentId = supervisor.spawn(
        role: "orchestrator",
        prompt: nil,
        cwd: repo,
        model: config.model,
        thinking: config.thinking,
        projectId: projectId
    )
    factory = SpawnedRunnerFactory(parent: (parentId, parentRunner))

    let parentInbox = EventInbox()
    let parentStream = supervisor.events(for: parentId)
    let parentTask = Task { @MainActor in for await event in parentStream { parentInbox.append(event) } }
    defer { parentTask.cancel() }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { supervisor.subscriberCount(for: parentId) == 1 }) else {
        throw fail("the parent's subscriber never registered")
    }

    supervisor.send("delegate the search", to: parentId)
    // Red when `send` does not call `observeSpawnRequests` (the wiring deleted):
    // `the captured spawn_agent call produced 0 child agent(s), expected 1`.
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { supervisor.children(of: parentId).count == 1 }) else {
        throw fail("the captured spawn_agent call produced \(supervisor.children(of: parentId).count) child agent(s), expected 1")
    }
    guard supervisor.records.count == 2 else {
        throw fail("the stream produced \(supervisor.records.count) agents in total, expected the parent and one child")
    }
    guard let childId = supervisor.children(of: parentId).first,
          let child = supervisor.records[childId] else {
        throw fail("the child agent has no record")
    }
    // Red when `handleSpawnRequest` omits `parentAgentID:` — the child exists but
    // nothing links it, so `children(of:)` above returns 0 and this never runs; the
    // durable half is asserted separately below.
    guard child.role == capturedRole else {
        throw fail("the child's role is \(String(describing: child.role)), expected the requested \(capturedRole)")
    }
    // P2D.3 — the ROLE decides the provider settings when it declares them, the parent
    // decides the project. Red when `handleSpawnRequest` passes `parent.model` /
    // `parent.thinking` again: `the child did not take its role's provider settings:
    // model openai-codex/gpt-5.6-sol, thinking medium — expected
    // openai-codex/gpt-5.3-codex-spark / xhigh from .pi/agents/code-scout.md`.
    guard child.model == scoutModel, child.thinking == scoutThinking else {
        throw fail("the child did not take its role's provider settings: model \(child.model), thinking \(child.thinking) — expected \(scoutModel) / \(scoutThinking) from \(RoleRegistry.directoryName)/\(capturedRole).md")
    }
    guard child.projectId == projectId else {
        throw fail("the child did not inherit the parent's project: \(String(describing: child.projectId))")
    }
    // …and the role's tool list is what the provider process would actually be
    // launched with. Red when `runnerConfig(for:)` drops `extraArgs`: `the child's
    // runner would not pass its role's tools: []`.
    let childRunnerArgs = AgentSupervisor.runnerConfig(for: child).extraArgs
    guard childRunnerArgs == ["--tools", scoutTools] else {
        throw fail("the child's runner would not pass its role's tools: \(childRunnerArgs)")
    }
    guard let storedChild = try store.load(id: childId), storedChild.parentAgentID == parentId else {
        throw fail("the parent link did not reach the store: \(String(describing: try store.load(id: childId)?.parentAgentID))")
    }
    // …and it is DOING the work, not merely recorded. Red when `handleSpawnRequest`
    // spawns with `prompt: nil`: `the child never ran the requested task`.
    guard let childRunner = factory.runners[childId] else {
        throw fail("no runner was ever constructed for the child — it was recorded but never started")
    }
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { childRunner.prompts == [capturedPrompt] }) else {
        throw fail("the child never ran the requested task; prompts \(childRunner.prompts)")
    }

    // MARK: 3 · I5 — the arguments stay out of everything that is published

    guard await waitUntil(timeout: 10, pollInterval: 0.02, {
        parentInbox.events.contains { event in
            if case let .itemStarted(_, _, _, title) = event { return title == SpawnRequest.toolName }
            return false
        }
    }) else {
        throw fail("the parent's stream never carried the tool call itself: \(parentInbox.events.count) events")
    }
    let encodedEvents = String(decoding: try JSONEncoder().encode(parentInbox.events), as: UTF8.self)
    for (label, secret) in [("prompt", capturedPrompt), ("role", capturedRole)] {
        guard !encodedEvents.contains(secret) else {
            throw fail("I5: the child's \(label) reached an AgentRuntimeEvent on the parent's stream")
        }
    }
    let published = parentInbox.events.enumerated().compactMap { offset, event in
        ManagedAgentActivityBridge.draft(
            for: event, agentId: parentId.rawValue, tileId: nil, status: .working, now: Date()
        ).map { AgentActivityEvent(stamping: $0, sequence: UInt64(offset), replicaId: UUID()) }
    }
    guard !published.isEmpty else {
        throw fail("no activity event was published from the parent's stream, so the I5 witness is vacuous")
    }
    let encodedPublished = String(decoding: try JSONEncoder().encode(published), as: UTF8.self)
    guard !encodedPublished.contains(capturedPrompt), !encodedPublished.contains(capturedRole) else {
        throw fail("I5: a published activity event carries the spawn arguments: \(encodedPublished)")
    }
    guard encodedPublished.contains("tool.\(SpawnRequest.toolName)") else {
        throw fail("the tool NAME should still cross — no tool.\(SpawnRequest.toolName) in \(encodedPublished)")
    }

    // MARK: 4 · the isolated child is a SIBLING checkout, not a nested one

    guard let branch = child.worktreeBranch else {
        throw fail("the request asked for isolation and the child has no branch")
    }
    let container = repo.appendingPathComponent(WorktreeManager.containerDirectoryName, isDirectory: true)
    guard URL(fileURLWithPath: child.cwd).deletingLastPathComponent().path == container.path else {
        throw fail("the isolated child works in \(child.cwd), not directly in \(container.path)/")
    }
    // Red when `repositoryRoot(of:)` returns the parent's `cwd` unconditionally and
    // the parent is itself isolated (asserted below with a grandchild).
    let listed = try WorktreeManager().list(repo: repo)
    guard listed.contains(where: {
        WorktreeManager.resolved($0.path) == WorktreeManager.resolved(URL(fileURLWithPath: child.cwd)) && $0.branch == branch
    }) else {
        throw fail("git does not know the child's worktree: \(listed.map { "\($0.path.path)@\($0.branch ?? "detached")" })")
    }

    // MARK: 5 · the depth cap, and what a refusal says

    // A grandchild is inside the cap. Requested from the CHILD, which is isolated —
    // so this is also where a nested `.worktrees/.worktrees/` would show up.
    guard let grandchildId = supervisor.handleSpawnRequest(
        SpawnRequest(role: "grandchild", prompt: "look at one file", isolated: true),
        from: childId
    ) else {
        throw fail("a grandchild is at depth \(AgentSupervisor.maxSpawnDepth) and must be allowed")
    }
    guard let grandchild = supervisor.records[grandchildId] else {
        throw fail("the grandchild has no record")
    }
    // A DIRECT child of the container, not merely somewhere under it. `hasPrefix` is
    // the trap the negative test caught: a nested
    // `<repo>/.worktrees/<child>/.worktrees/<grandchild>` satisfies the prefix and is
    // exactly the shape `repositoryRoot(of:)` exists to prevent.
    guard URL(fileURLWithPath: grandchild.cwd).deletingLastPathComponent().path == container.path else {
        throw fail("the grandchild's checkout \(grandchild.cwd) is nested inside its parent's rather than a sibling in \(container.path)/")
    }
    guard supervisor.depth(of: grandchildId) == AgentSupervisor.maxSpawnDepth else {
        throw fail("the grandchild's depth is \(supervisor.depth(of: grandchildId)), expected \(AgentSupervisor.maxSpawnDepth)")
    }

    let grandchildInbox = EventInbox()
    let grandchildStream = supervisor.events(for: grandchildId)
    let grandchildTask = Task { @MainActor in for await event in grandchildStream { grandchildInbox.append(event) } }
    defer { grandchildTask.cancel() }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { supervisor.subscriberCount(for: grandchildId) == 1 }) else {
        throw fail("the grandchild's subscriber never registered")
    }
    let beforeDepthRefusal = supervisor.records.count
    // Red when the depth guard is deleted: `a great-great-grandchild was spawned past
    // the depth cap`.
    guard supervisor.handleSpawnRequest(
        SpawnRequest(role: "too-deep", prompt: "keep delegating", isolated: false),
        from: grandchildId
    ) == nil else {
        throw fail("an agent past the depth cap of \(AgentSupervisor.maxSpawnDepth) was spawned anyway")
    }
    guard supervisor.records.count == beforeDepthRefusal else {
        throw fail("a refused spawn still created a record: \(supervisor.records.count) agents, expected \(beforeDepthRefusal)")
    }
    // The refusal is SAID, not swallowed. Red when `refuseSpawn` only warns:
    // `the refusal never reached the requesting agent's transcript`.
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        grandchildInbox.events.contains { event in
            if case let .itemStarted(_, _, kind, title) = event {
                return kind == .error && (title ?? "").contains("\(SpawnRequest.toolName) refused")
            }
            return false
        }
    }) else {
        throw fail("the refusal never reached the requesting agent's transcript: \(grandchildInbox.events)")
    }
    guard grandchildInbox.events.contains(where: { event in
        if case let .itemCompleted(_, _, kind, status) = event { return kind == .error && status == .failed }
        return false
    }) else {
        throw fail("the refusal was started but never completed as failed: \(grandchildInbox.events)")
    }
    // The reason may not carry the refused prompt or a path — the transcript is the
    // near side of the boundary, but the bridge publishes from it.
    let refusalTitles = grandchildInbox.events.compactMap { event -> String? in
        if case let .itemStarted(_, _, _, title) = event, (title ?? "").contains("refused") { return title }
        return nil
    }
    guard refusalTitles.allSatisfy({ !$0.contains("keep delegating") && !$0.contains(root.path) }) else {
        throw fail("I5: a refusal reason carries the request's prompt or a host path: \(refusalTitles)")
    }

    // MARK: 6 · the per-parent child cap

    // The parent already has one child (the captured call). Fill the rest of the cap,
    // non-isolated so this stays a records-and-caps assertion rather than N worktrees.
    for index in 1..<AgentSupervisor.maxChildrenPerParent {
        guard supervisor.handleSpawnRequest(
            SpawnRequest(role: "worker-\(index)", prompt: "task \(index)", isolated: false),
            from: parentId
        ) != nil else {
            throw fail("child \(index + 1) of \(AgentSupervisor.maxChildrenPerParent) was refused while inside the cap")
        }
    }
    guard supervisor.children(of: parentId).count == AgentSupervisor.maxChildrenPerParent else {
        throw fail("the parent has \(supervisor.children(of: parentId).count) children, expected \(AgentSupervisor.maxChildrenPerParent)")
    }
    // P2D.3 — those roles declare no model or reasoning, so the PARENT's settings are
    // still what they run with (and no `--tools`, because the role names none). Red
    // when `resolve` defaults a silent model instead of inheriting: `worker-1 did not
    // inherit the parent's provider settings`.
    let workers = supervisor.children(of: parentId)
        .compactMap { supervisor.records[$0] }
        .filter { ($0.role ?? "").hasPrefix("worker-") }
    guard workers.count == AgentSupervisor.maxChildrenPerParent - 1 else {
        throw fail("expected \(AgentSupervisor.maxChildrenPerParent - 1) role-only children, got \(workers.count)")
    }
    for worker in workers {
        guard worker.model == config.model, worker.thinking == config.thinking else {
            throw fail("\(worker.role ?? "?") did not inherit the parent's provider settings: model \(worker.model), thinking \(worker.thinking)")
        }
        guard AgentSupervisor.runnerConfig(for: worker).extraArgs.isEmpty else {
            throw fail("\(worker.role ?? "?") declares no tools but its runner would pass \(AgentSupervisor.runnerConfig(for: worker).extraArgs)")
        }
    }
    let atCap = supervisor.children(of: parentId).count
    // Red when the child-count guard is deleted: `a 5th child was spawned past the
    // per-parent cap of 4`.
    guard supervisor.handleSpawnRequest(
        SpawnRequest(role: "one-too-many", prompt: "task N", isolated: false),
        from: parentId
    ) == nil else {
        throw fail("a child past the per-parent cap of \(AgentSupervisor.maxChildrenPerParent) was spawned anyway")
    }
    guard supervisor.children(of: parentId).count == atCap else {
        throw fail("a refused spawn disturbed the existing children: \(supervisor.children(of: parentId).count), expected \(atCap)")
    }
    // An agent this supervisor does not know gets nothing, and does not crash.
    guard supervisor.handleSpawnRequest(
        SpawnRequest(role: nil, prompt: "from nowhere", isolated: false),
        from: AgentID(rawValue: UUID())
    ) == nil else {
        throw fail("a spawn request from an unknown agent produced a child")
    }

    // MARK: 7 · a role this project does not define is refused (P2D.3)

    // Asked of the CHILD: it is at depth 1 with one child of its own, so neither cap
    // can be what stops this — only the unknown role can.
    let childInbox = EventInbox()
    let childStream = supervisor.events(for: childId)
    let childTask = Task { @MainActor in for await event in childStream { childInbox.append(event) } }
    defer { childTask.cancel() }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { supervisor.subscriberCount(for: childId) == 1 }) else {
        throw fail("the child's subscriber never registered")
    }
    let undefinedRole = "not-a-role-in-this-project"
    let beforeRoleRefusal = supervisor.records.count
    // Red when `handleSpawnRequest` skips the registry and inherits the parent's model
    // for an unknown role: `a spawn naming an undefined role produced a child`.
    guard supervisor.handleSpawnRequest(
        SpawnRequest(role: undefinedRole, prompt: "work for a role that does not exist", isolated: false),
        from: childId
    ) == nil else {
        throw fail("a spawn naming an undefined role produced a child")
    }
    guard supervisor.records.count == beforeRoleRefusal else {
        throw fail("the refused role still created a record: \(supervisor.records.count), expected \(beforeRoleRefusal)")
    }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, {
        childInbox.events.contains { event in
            if case let .itemStarted(_, _, kind, title) = event {
                return kind == .error && (title ?? "").contains(AgentSupervisor.SpawnRefusal.roleUnresolved.reason)
            }
            return false
        }
    }) else {
        throw fail("the unknown role was refused silently — nothing on the requesting agent's transcript: \(childInbox.events)")
    }
    // The reason names no role id and no path: the P2D.2 witness above holds the
    // REQUESTED role out of every event on a parent's stream, and this is the one
    // place that could put one back.
    let roleRefusalTitles = childInbox.events.compactMap { event -> String? in
        if case let .itemStarted(_, _, _, title) = event, (title ?? "").contains("refused") { return title }
        return nil
    }
    guard roleRefusalTitles.allSatisfy({ !$0.contains(undefinedRole) && !$0.contains(root.path) }) else {
        throw fail("I5: a role refusal echoes the requested role id or a host path: \(roleRefusalTitles)")
    }

    for id in supervisor.children(of: parentId) + [grandchildId] { supervisor.stop(id) }
    return "the captured spawn_agent call produced 1 child (role \(capturedRole) at \(scoutModel)/\(scoutThinking) and --tools from its role file, isolated on \(branch), parent linked in the store) that ran the requested prompt, prompt/role absent from \(parentInbox.events.count) parent events and \(published.count) published activity events while tool.\(SpawnRequest.toolName) crossed, a grandchild got a sibling worktree, depth capped at \(AgentSupervisor.maxSpawnDepth) and children at \(AgentSupervisor.maxChildrenPerParent) with the refusal said in the requesting agent's transcript, \(workers.count) role-only children inherited the parent's settings, and an undefined role was refused without echoing its id"
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

/// P2C.3 — archiving an agent cleans up after it, and never at the cost of work.
///
/// Everything runs against a TEMP `git init` repository (P2C.1's inherited trap: the
/// real repository is never a `worktree add` target) and a temp `AgentStore`. The
/// orphan half uses SUCCESSIVE supervisors over that one store, because "the record
/// is gone" has to be observed by something that never held the record — a supervisor
/// that spawned the agent could answer from memory.
///
/// Eight properties:
///   1. Archiving an isolated agent with nothing on its branch removes the worktree
///      AND the branch, and deletes the record from memory and from the store.
///   2. An UNMERGED commit keeps the branch: the worktree still goes, the branch is
///      retained and named in the report. This is the packet's headline prohibition.
///   3. Archiving stops a live runner.
///   4. A non-isolated agent's archive touches no worktree and no branch.
///   5. A record claiming a branch whose `cwd` is NOT under `.worktrees/` gets
///      nothing removed — the fixture is a real worktree a human created elsewhere in
///      the repository, which the derivation would otherwise hand to
///      `git worktree remove`.
///   6. Orphans: a worktree whose record was deleted behind the supervisor's back is
///      reported and repaired; a STALE record's worktree (the P2A.7 case: `cwd`
///      missing, so `restore` marks and skips it) is NOT an orphan, because the
///      record is still in the store.
///   7. A store that cannot be read completely makes orphan detection and repair
///      REFUSE, rather than treat the agents it could not read as orphans.
///   8. A store that cannot delete the record cleans up NOTHING.
///
/// Seven negative tests observed red at exit 1 with the final code, each quoted at its
/// assertion below. One mutation that is deliberately NOT red is recorded at MARK 2:
/// deleting the branch without the `isMerged` guard is caught by `git branch -d`
/// instead, and the destructive form of it (`-D`) is red in `runWorktreeMergedBranchCheck`.
@MainActor
private func checkArchiveCleanup(
    config: AgentModelConfig.Resolution,
    fail: (String) -> Error
) async throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-archive-cleanup-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let repo = root.appendingPathComponent("repo", isDirectory: true)
    try makeIsolatedSpawnRepo(at: repo)
    let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("support", isDirectory: true))
    let manager = WorktreeManager()

    // Only the agent given a prompt takes a runner, and it holds `run` open until
    // `stop` arrives — which is how "archive stopped a live runner" is observed as the
    // runner exiting rather than as a dictionary entry disappearing.
    let holding = ScriptedAgentRunner(script: [.sessionStateChanged(.running)], holdUntilStopped: true)
    let queue = ScriptedRunnerQueue([holding])
    let supervisor = AgentSupervisor(store: store, makeRunner: { queue.next($0) })

    func spawnIsolated(_ prompt: String?, role: String) throws -> (id: AgentID, record: AgentRecord) {
        let id = try supervisor.spawn(
            role: role,
            prompt: prompt,
            cwd: repo,
            model: config.model,
            thinking: config.thinking,
            isolated: true
        )
        guard let record = supervisor.records[id] else {
            throw fail("the supervisor lost the isolated agent it spawned for \(role)")
        }
        return (id, record)
    }

    // MARK: 1 · nothing on the branch: the worktree AND the branch go

    let clean = try spawnIsolated(nil, role: "clean")
    guard let cleanBranch = clean.record.worktreeBranch else {
        throw fail("an isolated agent's record does not name its branch")
    }
    let cleanPath = URL(fileURLWithPath: clean.record.cwd, isDirectory: true)
    let listedBefore = try manager.list(repo: repo).count

    // Negative test observed red with the final code: with `archive` calling only
    // `store.delete` (no `cleanUpWorktree`) this reported
    //   FAIL: archiving a clean isolated agent left its worktree on disk: …/.worktrees/clean-…
    let cleanReport = supervisor.archive(clean.id)
    guard !FileManager.default.fileExists(atPath: cleanPath.path) else {
        throw fail("archiving a clean isolated agent left its worktree on disk: \(cleanPath.path)")
    }
    guard cleanReport.worktreeRemoved.map({ WorktreeManager.resolved($0) }) == WorktreeManager.resolved(cleanPath) else {
        throw fail("the report does not name the removed worktree: \(String(describing: cleanReport.worktreeRemoved?.path))")
    }
    guard try !manager.branchExists(repo: repo, branch: cleanBranch) else {
        throw fail("archiving a clean isolated agent left branch \(cleanBranch) behind; it held nothing the repository does not have")
    }
    guard cleanReport.branchDeleted == cleanBranch else {
        throw fail("the report does not name the deleted branch: \(String(describing: cleanReport.branchDeleted))")
    }
    guard try manager.list(repo: repo).count == listedBefore - 1 else {
        throw fail("git still lists the archived agent's worktree")
    }
    guard supervisor.records[clean.id] == nil else {
        throw fail("the archived agent is still in memory")
    }
    guard try store.load(id: clean.id) == nil, cleanReport.recordDeleted else {
        throw fail("the archived agent's record is still in the store")
    }

    // MARK: 2 · an unmerged commit keeps the branch

    let unmerged = try spawnIsolated(nil, role: "unmerged")
    guard let unmergedBranch = unmerged.record.worktreeBranch else {
        throw fail("the unmerged agent's record does not name its branch")
    }
    let unmergedPath = URL(fileURLWithPath: unmerged.record.cwd, isDirectory: true)
    try "the agent's work\n".write(to: unmergedPath.appendingPathComponent("agent.txt"), atomically: true, encoding: .utf8)
    try runIsolatedSpawnGit(["add", "agent.txt"], in: unmergedPath)
    try runIsolatedSpawnGit([
        "-c", "user.email=qa@continuum.test",
        "-c", "user.name=Continuum QA",
        "commit", "-q", "--no-gpg-sign", "-m", "agent work",
    ], in: unmergedPath)

    // TWO INDEPENDENT GUARDS, and the honest note about which one this check catches:
    // deleting the branch unconditionally here (no `isMerged` guard) is NOT red, because
    // `WorktreeManager.deleteBranch` is `git branch -d` and git refuses it too — the
    // branch survives and lands in `branchRetained` carrying git's message instead of
    // this code's reason. The destructive mutation is `-d` -> `-D` in the manager, and
    // it is observed red in `runWorktreeMergedBranchCheck`. What the assertions below
    // do witness is that an unmerged branch survives an archive at all, which is the
    // packet's done-criterion.
    let unmergedReport = supervisor.archive(unmerged.id)
    guard !FileManager.default.fileExists(atPath: unmergedPath.path) else {
        throw fail("the committed worktree was clean, so archive should have removed it: \(unmergedPath.path)")
    }
    guard try manager.branchExists(repo: repo, branch: unmergedBranch) else {
        throw fail("archiving an agent with an unmerged commit DELETED branch \(unmergedBranch) — its work is gone")
    }
    guard unmergedReport.branchRetained?.branch == unmergedBranch, unmergedReport.branchDeleted == nil else {
        throw fail("the report does not say the branch was kept: deleted=\(String(describing: unmergedReport.branchDeleted)) retained=\(String(describing: unmergedReport.branchRetained?.branch))")
    }
    guard let retainedReason = unmergedReport.branchRetained?.reason, !retainedReason.isEmpty else {
        throw fail("a retained branch was reported without a reason")
    }
    // The commit is still reachable, which is the property the branch existing stands
    // in for.
    let reachable = try runIsolatedSpawnGit(["log", "--format=%s", "-1", unmergedBranch], in: repo)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard reachable == "agent work" else {
        throw fail("the retained branch no longer points at the agent's commit: \(reachable)")
    }

    // MARK: 3 · archive stops a live runner

    let live = try spawnIsolated("work on it", role: "live")
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { holding.runCount == 1 }) else {
        throw fail("the live agent's prompt never reached a runner")
    }
    guard supervisor.isRunning(live.id) else {
        throw fail("the live agent should have a prompt in flight")
    }
    // Negative test observed red with the final code: with the `stop` call removed
    // from `archive` this reported
    //   FAIL: archiving a live agent did not stop its runner: run() never returned
    let liveReport = supervisor.archive(live.id)
    guard liveReport.wasRunning else {
        throw fail("the report does not say a live runner was stopped")
    }
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { holding.completedRuns == 1 }) else {
        throw fail("archiving a live agent did not stop its runner: run() never returned")
    }
    guard !supervisor.isRunning(live.id), supervisor.records[live.id] == nil else {
        throw fail("the archived live agent is still around")
    }

    // MARK: 4 · a non-isolated agent's archive touches no git state

    let plainId = supervisor.spawn(
        role: "plain",
        prompt: nil,
        cwd: repo,
        model: config.model,
        thinking: config.thinking
    )
    let listedBeforePlain = try manager.list(repo: repo)
    let plainReport = supervisor.archive(plainId)
    guard plainReport.worktreeRemoved == nil, plainReport.worktreeRetained == nil,
          plainReport.branchDeleted == nil, plainReport.branchRetained == nil else {
        throw fail("archiving a non-isolated agent made a worktree decision: \(plainReport.summary)")
    }
    guard try manager.list(repo: repo).map({ $0.path.path }) == listedBeforePlain.map({ $0.path.path }) else {
        throw fail("archiving a non-isolated agent changed the repository's worktrees")
    }
    guard FileManager.default.fileExists(atPath: repo.appendingPathComponent("README.md").path) else {
        throw fail("archiving a non-isolated agent damaged the project root")
    }
    guard supervisor.records[plainId] == nil, try store.load(id: plainId) == nil else {
        throw fail("the archived non-isolated agent's record survived")
    }

    // MARK: 5 · a branch-claiming record outside .worktrees/ is left alone

    // The fixture is the case that would actually be destroyed: a REAL worktree a
    // human created two levels down inside the repository, so the `<repo>/.worktrees/
    // <slug>` derivation would resolve to a genuine repository that genuinely knows
    // this path — and `git worktree remove` would take it. (A first attempt pointed the
    // record at the project root; that is not discriminating, because the derived
    // "repo" is then the temp directory, which is not a repository at all, so the
    // removal fails for a reason that has nothing to do with the guard.)
    let manual = repo.appendingPathComponent("manual", isDirectory: true)
        .appendingPathComponent("tree", isDirectory: true)
    try runIsolatedSpawnGit(["worktree", "add", "-q", "-b", "manual", manual.path], in: repo)

    // Written straight to the store, so nothing in this process ever spawned it: this
    // is a hand-edited or migrated record.
    let mislabelledId = AgentID(rawValue: UUID())
    let now = Date()
    try store.upsert(AgentRecord(
        id: mislabelledId,
        displayName: "mislabelled",
        role: "mislabelled",
        model: config.model,
        thinking: config.thinking,
        cwd: manual.path,
        worktreeBranch: "manual",
        projectId: nil,
        createdAt: now,
        lastActivityAt: now,
        tileId: nil
    ))
    let adopting = AgentSupervisor(store: store, makeRunner: { ScriptedRunnerQueue([]).next($0) })
    _ = adopting.restore()
    guard adopting.records[mislabelledId] != nil else {
        throw fail("the mislabelled record was not adopted, so the guard is untested")
    }
    let listedBeforeMislabelled = try manager.list(repo: repo).map { $0.path.path }
    // Negative test observed red with the final code: with the container check in
    // `cleanUpWorktree` bypassed this reported
    //   FAIL: archiving a record that claims a worktree outside .worktrees/ removed
    //   it: Optional("…/repo/manual/tree")
    let mislabelledReport = adopting.archive(mislabelledId)
    guard mislabelledReport.worktreeRemoved == nil else {
        throw fail("archiving a record that claims a worktree outside \(WorktreeManager.containerDirectoryName)/ removed it: \(String(describing: mislabelledReport.worktreeRemoved?.path))")
    }
    guard mislabelledReport.worktreeRetained != nil, mislabelledReport.branchRetained != nil else {
        throw fail("the mislabelled record was cleaned up silently: \(mislabelledReport.summary)")
    }
    guard try manager.list(repo: repo).map({ $0.path.path }) == listedBeforeMislabelled else {
        throw fail("archiving a mislabelled record changed the repository's worktrees")
    }
    guard FileManager.default.fileExists(atPath: manual.appendingPathComponent("README.md").path) else {
        throw fail("archiving a mislabelled record destroyed the human's worktree at \(manual.path)")
    }
    guard try manager.branchExists(repo: repo, branch: "manual") else {
        throw fail("archiving a mislabelled record deleted the human's branch `manual`")
    }

    // MARK: 6 · orphans, and what is NOT one

    let orphanSupervisor = AgentSupervisor(store: store, makeRunner: { ScriptedRunnerQueue([]).next($0) })
    func spawnOn(_ supervisor: AgentSupervisor, role: String) throws -> AgentRecord {
        let id = try supervisor.spawn(
            role: role,
            prompt: nil,
            cwd: repo,
            model: config.model,
            thinking: config.thinking,
            isolated: true
        )
        guard let record = supervisor.records[id] else { throw fail("lost the \(role) agent") }
        return record
    }
    let keptAgent = try spawnOn(orphanSupervisor, role: "kept")
    let orphanAgent = try spawnOn(orphanSupervisor, role: "orphaned")
    // Behind the supervisor's back: the record file goes, nothing else does.
    try store.delete(id: orphanAgent.id)

    // A supervisor that never held either record — it only knows what the store says.
    let afterRelaunch = AgentSupervisor(store: store, makeRunner: { ScriptedRunnerQueue([]).next($0) })
    _ = afterRelaunch.restore()
    let orphans = try afterRelaunch.orphanWorktrees(repo: repo)
    // Negative test observed red with the final code: with `knownAgentDirectories`
    // returning `[]` this reported
    //   FAIL: orphan detection reported 2 worktrees, expected only the one whose
    //   record was deleted
    guard orphans.count == 1 else {
        throw fail("orphan detection reported \(orphans.count) worktrees, expected only the one whose record was deleted: \(orphans.map { $0.path.lastPathComponent })")
    }
    guard WorktreeManager.resolved(orphans[0].path) == WorktreeManager.resolved(URL(fileURLWithPath: orphanAgent.cwd)) else {
        throw fail("orphan detection named \(orphans[0].path.path), expected \(orphanAgent.cwd)")
    }
    let repaired = try afterRelaunch.repairWorktrees(repo: repo)
    guard repaired.removed.count == 1, repaired.retained.isEmpty else {
        throw fail("repair removed \(repaired.removed.count) and retained \(repaired.retained.count) worktrees, expected 1 and 0")
    }
    guard !FileManager.default.fileExists(atPath: orphanAgent.cwd) else {
        throw fail("repair left the orphan's worktree on disk")
    }
    guard FileManager.default.fileExists(atPath: keptAgent.cwd) else {
        throw fail("repair deleted the LIVE agent's worktree")
    }
    if let orphanBranch = orphanAgent.worktreeBranch {
        guard try manager.branchExists(repo: repo, branch: orphanBranch) else {
            throw fail("repair deleted branch \(orphanBranch) — it is all that was left of that agent")
        }
    }

    // …and a STALE record's worktree is not an orphan. `restore` marks a record whose
    // `cwd` is missing and does not adopt it (P2A.7), so a known-set built from live
    // records alone would prune the one thing that could bring that agent back.
    let staleAgent = try spawnOn(afterRelaunch, role: "stale")
    try FileManager.default.removeItem(at: URL(fileURLWithPath: staleAgent.cwd))
    let afterSecondRelaunch = AgentSupervisor(store: store, makeRunner: { ScriptedRunnerQueue([]).next($0) })
    let restored = afterSecondRelaunch.restore()
    guard restored.stale.contains(staleAgent.id) else {
        throw fail("the stale agent was not marked stale, so this case is untested")
    }
    // Negative test observed red with the final code: with `knownAgentDirectories`
    // reading only `records.values` (no `store.loadAll()`) this reported
    //   FAIL: a STALE agent's worktree was reported as an orphan — its record is
    //   still in the store
    let staleOrphans = try afterSecondRelaunch.orphanWorktrees(repo: repo)
    guard !staleOrphans.contains(where: {
        WorktreeManager.resolved($0.path) == WorktreeManager.resolved(URL(fileURLWithPath: staleAgent.cwd))
    }) else {
        throw fail("a STALE agent's worktree was reported as an orphan — its record is still in the store")
    }
    guard try store.load(id: staleAgent.id) != nil else {
        throw fail("the stale agent's record disappeared from the store")
    }
    if let staleBranch = staleAgent.worktreeBranch {
        guard try manager.branchExists(repo: repo, branch: staleBranch) else {
            throw fail("the stale agent's branch \(staleBranch) was deleted")
        }
    }

    // MARK: 7 · a store it cannot fully read makes orphan detection REFUSE

    // `AgentStore.loadAll` skips a record it cannot decode, which for the inbox is
    // correct and for a DESTRUCTIVE sweep is a silently narrowed known set: that
    // agent's worktree would be an orphan and repair would delete it.
    //
    // Negative test observed red with the final code: with `knownAgentDirectories`
    // warning instead of throwing on the count mismatch this reported
    //   FAIL: a record file that cannot be decoded did not stop orphan detection;
    //   it reported 0 orphan(s)
    // — zero, and that is the point: a narrowed known set answers confidently, and the
    // only thing standing between that answer and a deleted checkout is which
    // worktrees happen to be on disk at the time.
    let corrupt = store.layout.agentsDirectory.appendingPathComponent("not-a-record.json")
    try "{ this is not an AgentRecord".write(to: corrupt, atomically: true, encoding: .utf8)
    do {
        let reported = try afterSecondRelaunch.orphanWorktrees(repo: repo)
        throw fail("a record file that cannot be decoded did not stop orphan detection; it reported \(reported.count) orphan(s)")
    } catch let refusal as AgentSupervisor.CleanupRefusal {
        guard case .unreadableAgentStore = refusal else { throw fail("unexpected refusal \(refusal)") }
    }
    do {
        _ = try afterSecondRelaunch.repairWorktrees(repo: repo)
        throw fail("repair ran against a store it could not fully read")
    } catch is AgentSupervisor.CleanupRefusal {
        // Expected: the destructive call refuses on the same grounds.
    }
    try FileManager.default.removeItem(at: corrupt)
    _ = try afterSecondRelaunch.orphanWorktrees(repo: repo)

    // MARK: 8 · a store that refuses the delete cleans up NOTHING

    // The durable record and the worktree must not disagree: if the record survives,
    // the checkout it names has to survive too, or the next launch restores an agent
    // whose directory is gone.
    //
    // Negative test observed red with the final code: with `archive` cleaning up before
    // `store.delete` (and not returning on failure) this reported
    //   FAIL: archive removed the worktree of an agent whose record it could not
    //   delete: …/.worktrees/undeletable-…
    let undeletable = try spawnOn(afterSecondRelaunch, role: "undeletable")
    // A real store failure, not an injected fake: the records directory is made
    // read-only, so `removeItem` cannot unlink the file while `loadAll` can still read
    // it. (A first attempt replaced the record file with a directory; `removeItem`
    // deletes those recursively, so the delete succeeded and the case was vacuous.)
    let recordsDirectory = store.layout.agentsDirectory
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: recordsDirectory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recordsDirectory.path) }
    let undeletableReport = afterSecondRelaunch.archive(undeletable.id)
    guard !undeletableReport.recordDeleted else {
        throw fail("the store reported deleting a record it cannot delete, so this case is untested")
    }
    guard undeletableReport.worktreeRemoved == nil else {
        throw fail("archive removed the worktree of an agent whose record it could not delete: \(String(describing: undeletableReport.worktreeRemoved?.path))")
    }
    guard FileManager.default.fileExists(atPath: undeletable.cwd) else {
        throw fail("the worktree of an agent whose record could not be deleted is gone")
    }
    guard afterSecondRelaunch.records[undeletable.id] != nil else {
        throw fail("a failed archive dropped the agent from memory anyway")
    }

    supervisor.stopAll()
    return "archive removed a clean agent's worktree and branch, KEPT the branch of one with an unmerged commit, stopped a live runner, left a non-isolated agent's repo untouched, refused to touch a project root a record wrongly claimed, repaired 1 orphan while leaving a live and a stale agent alone"
}

/// A temp repository with one commit — `git worktree add` needs a HEAD. The `-c`
/// identity keeps the check independent of the host's global git config, as
/// `WorktreeManagerChecks` does for the same reason.
/// Writes one `.pi/agents/<id>.md` role file into a fixture repository (P2D.3).
///
/// `name` is always declared, because `RoleRegistry` requires it — a file without one
/// is deliberately not a role, and that exclusion is asserted directly in
/// `runRoleRegistryChecks`.
private func writeSpawnCheckRole(
    in repo: URL,
    id: String,
    model: String? = nil,
    reasoning: String? = nil,
    tools: String? = nil
) throws {
    let directory = repo.appendingPathComponent(RoleRegistry.directoryName, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var frontmatter = ["name: \(id)"]
    if let model { frontmatter.append("model: \(model)") }
    if let reasoning { frontmatter.append("reasoning: \(reasoning)") }
    if let tools { frontmatter.append("tools: \(tools)") }
    let body = "---\n\(frontmatter.joined(separator: "\n"))\n---\n\nYou are the \(id).\n"
    try body.write(to: directory.appendingPathComponent("\(id).md"), atomically: true, encoding: .utf8)
}

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

/// P2C.4 — the tile SAYS which checkout its agent is about to touch.
///
/// The whole path, against a real temp repository: a real isolated spawn, a real
/// `ManagedAgentTileNSView`, the production `attach(agentID:supervisor:)`, and the
/// chip text read back off the view. Nothing here sets the chip directly — that is
/// what makes it a check of the wiring rather than of `BranchChipNSView.display`.
///
/// Five properties:
///   1. An isolated agent's tile shows its branch, with no warning: its checkout IS
///      on the branch it was given, which is the ordinary case.
///   2. A shared-checkout agent's tile shows the branch the PROJECT is on, marked
///      shared — the "which of five agents is about to touch my tree" question.
///   3. A tile nobody has told anything shows NO chip, rather than implying a
///      shared checkout.
///   4. THE WARNING IS REACHABLE, THROUGH THE PRODUCTION REFRESH: a real `git
///      checkout` inside the agent's own worktree, then an ordinary `.turnCompleted`
///      into the tile — no hand-written re-apply — and the chip flags it and names
///      both branches. Not a synthesized context; git moved the checkout.
///   5. The branch is read from CACHE: re-deriving the context ten times costs no
///      further `git rev-parse`, because the chip re-renders per streamed token.
@MainActor
private func checkBranchChip(
    config: AgentModelConfig.Resolution,
    fail: (String) -> Error
) async throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-branch-chip-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let repo = root.appendingPathComponent("repo", isDirectory: true)
    try makeIsolatedSpawnRepo(at: repo)
    let store = AgentStore(applicationSupportDirectory: root.appendingPathComponent("support", isDirectory: true))
    let supervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) })

    func makeTile(_ title: String) -> ManagedAgentTileNSView {
        let view = ManagedAgentTileNSView(tile: Tile(
            id: UUID(),
            kind: .managedAgent,
            title: title,
            frame: TileFrame(x: 0, y: 0, width: 520, height: 320),
            zPosition: .fromLegacyRank(1),
            runtimeRef: nil,
            metadata: TileMetadata(launchProfileId: "managed")
        ))
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
        return view
    }

    // MARK: 3 · a tile that has been told nothing shows nothing
    let untold = makeTile("untold")
    guard untold.qaBranchChipText == nil else {
        throw fail("a tile with no branch context shows \(untold.qaBranchChipText ?? "nil") — it must show no chip at all")
    }

    // MARK: 1 · the isolated agent
    let isolatedId = try supervisor.spawn(
        role: "implementer",
        prompt: nil,
        cwd: repo,
        model: config.model,
        thinking: config.thinking,
        isolated: true
    )
    guard let isolated = supervisor.records[isolatedId], let branch = isolated.worktreeBranch else {
        throw fail("the isolated spawn produced no record with a branch")
    }
    let isolatedTile = makeTile("isolated")
    isolatedTile.attach(agentID: isolatedId, supervisor: supervisor)
    guard let isolatedChip = isolatedTile.qaBranchChipText else {
        throw fail("an isolated agent's tile shows NO branch — the packet's own done-criterion")
    }
    guard isolatedChip.contains(branch) else {
        throw fail("the chip reads \(isolatedChip), which does not name the agent's branch \(branch)")
    }
    guard !isolatedTile.qaBranchChipIsWarning else {
        throw fail("an isolated agent sitting ON its own branch was flagged as a mismatch: \(isolatedChip)")
    }

    // MARK: 2 · the shared-checkout agent
    let sharedId = supervisor.spawn(
        role: "reviewer",
        prompt: nil,
        cwd: repo,
        model: config.model,
        thinking: config.thinking
    )
    let sharedTile = makeTile("shared")
    sharedTile.attach(agentID: sharedId, supervisor: supervisor)
    guard let sharedChip = sharedTile.qaBranchChipText else {
        throw fail("a shared-checkout agent's tile shows no branch — you cannot tell it apart from an isolated one")
    }
    guard sharedChip.contains("main") else {
        throw fail("a shared agent's chip reads \(sharedChip), not the project's own branch (main)")
    }
    guard sharedChip.contains(BranchChipNSView.sharedSuffix) else {
        throw fail("a shared agent's chip \(sharedChip) does not say it is the project's own checkout")
    }
    guard !sharedTile.qaBranchChipIsWarning else {
        throw fail("an agent working in YOUR checkout was flagged as being on the wrong branch: \(sharedChip)")
    }

    // MARK: 5 · the reads are cached
    let readsBefore = supervisor.qaBranchGitReads
    for _ in 0..<10 { _ = supervisor.branchContext(for: isolatedId) }
    guard supervisor.qaBranchGitReads == readsBefore else {
        throw fail(
            "ten re-renders cost \(supervisor.qaBranchGitReads - readsBefore) extra git call(s) — "
                + "the chip re-renders per streamed token, so the read has to come from cache"
        )
    }

    // MARK: 4 · the agent leaves the branch it was given, for real
    //
    // The refresh goes through the PRODUCTION path — an event the tile ingests —
    // not a hand-written `applyBranchContext`. A turn is the only thing that can move
    // an agent's checkout, so `.turnCompleted` is where the tile re-reads it; a check
    // that invalidated and re-applied by hand would pass over a tile that never
    // refreshes at all (the cross-review's finding).
    try runIsolatedSpawnGit(["checkout", "-q", "-b", "wandered-off"], in: URL(fileURLWithPath: isolated.cwd))
    isolatedTile.ingest(.turnCompleted(
        threadId: AgentSupervisor.threadId(for: isolatedId),
        turnId: "branch-chip-turn",
        outcome: .completed,
        errorMessage: nil
    ))
    guard isolatedTile.qaBranchChipIsWarning else {
        throw fail(
            "the agent's checkout moved to wandered-off and the tile still reads "
                + "\(isolatedTile.qaBranchChipText ?? "nil") with no warning"
        )
    }
    guard let wanderedChip = isolatedTile.qaBranchChipText, wanderedChip.contains("wandered-off") else {
        throw fail("the warning chip \(isolatedTile.qaBranchChipText ?? "nil") does not name the branch the work is actually landing on")
    }
    guard let tooltip = isolatedTile.qaBranchChipTooltip, tooltip.contains(branch), tooltip.contains("wandered-off") else {
        throw fail("the warning names only one of the two branches: \(isolatedTile.qaBranchChipTooltip ?? "nil")")
    }

    return "a tile names its checkout (isolated \(isolatedChip), shared \(sharedChip), moved \(wanderedChip)), an unbound tile shows none, and 10 re-renders cost 0 git calls"
}

/// P3.3 — attention is a separate axis from state, and read-state is LOCAL.
///
/// Driven through real turns from a `ScriptedRunnerQueue` (one runner per `send`,
/// because the supervisor makes a new one per prompt), so "a turn completed" is an
/// event travelling the production `deliver` path rather than a flag set by hand.
///
/// Six properties:
///   1. A turn that completes while you are looking elsewhere leaves the agent
///      `.unread` — the packet's done-criterion.
///   2. A deliberate focus clears it to `.none`.
///   3. A turn completing WHILE FOCUSED never sets it. Without this the mark means
///      "this agent has ever finished a turn", which is every agent.
///   4. Focus leaving re-arms it: the next turn is unread again.
///   5. `focusTile` clears through the tile binding, which is how focus arrives on
///      the desktop (`FocusBroker` speaks tile ids).
///   6. IT IS NOT DURABLE AND NOT SYNCED: the agent's persisted record carries no
///      read-state key, and a second supervisor restoring the same store reports
///      `.none` for an agent this one holds as unread.
///
/// The precedence between `unread` and `woke` is the vocabulary's, checked in
/// `ContinuumRevivedAgentUIChecks/AgentInboxRowChecks.swift`; what is checked here
/// is that the supervisor routes its one fact through `InboxAttention.resolve`
/// rather than answering with a second opinion.
///
/// Three negative tests observed red at exit 1 with the final code, each a
/// production edit to the section above:
/// · `focus(agentID:)` no longer calling `unread.remove(id)` →
///   `FAIL: read-state: focusing the agent left it unread`
/// · `deliver`'s `focusedAgentID != id` guard dropped, so any completed turn marks
///   the row →
///   `FAIL: read-state: a turn you watched finish was marked unread — the mark
///   would then mean `has ever finished a turn``
/// · `archive` no longer dropping the read-state →
///   `FAIL: read-state: archiving left focus Optional(…AgentID…) / attention none
///   behind for a gone agent`
///
/// WHAT HAS NO NEGATIVE TEST, honestly: property 6. The forbidden-key scan is
/// vacuity-guarded on `id` instead — writing a witness for it means adding a
/// persisted read-state field to `AgentRecord`, which is the bug it exists to
/// forbid, and the relaunch leg would then be red for the same one reason.
@MainActor
private func checkReadState(
    config: AgentModelConfig.Resolution,
    cwd: URL,
    fail: (String) -> Error
) async throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-read-state-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentStore(applicationSupportDirectory: root)

    let provider = "provider-thread"
    func turn(_ id: String) -> [AgentRuntimeEvent] {
        [
            .turnStarted(threadId: provider, turnId: id),
            .contentDelta(threadId: provider, turnId: id, streamKind: .assistant, delta: "…"),
            .turnCompleted(threadId: provider, turnId: id, outcome: .completed, errorMessage: nil),
            .sessionStateChanged(.ready)
        ]
    }
    let queue = ScriptedRunnerQueue((1 ... 4).map { ScriptedAgentRunner(script: turn("t\($0)")) })
    let supervisor = AgentSupervisor(store: store, makeRunner: { queue.next($0) })

    let tileId = UUID()
    let agentId = supervisor.spawn(
        role: "reviewer",
        prompt: nil,
        cwd: cwd,
        model: config.model,
        thinking: config.thinking,
        tileId: tileId
    )
    let inbox = EventInbox()
    let stream = supervisor.events(for: agentId)
    let task = Task { @MainActor in for await event in stream { inbox.append(event) } }
    defer { task.cancel() }
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { supervisor.subscriberCount(for: agentId) == 1 }) else {
        throw fail("read-state: the subscriber never registered")
    }

    var turnsRun = 0
    func runOneTurn(_ prompt: String) async throws {
        let before = inbox.events.count
        supervisor.send(prompt, to: agentId)
        guard await waitUntil(timeout: 10, pollInterval: 0.02, { inbox.events.count == before + 4 }) else {
            throw fail("read-state: the turn `\(prompt)` did not complete — \(inbox.events.count - before) of 4 events arrived")
        }
        turnsRun += 1
    }

    // 1 · nothing is unread before anything has happened, and a turn you did not
    //     watch makes it so.
    guard supervisor.attention(for: agentId) == .none else {
        throw fail("read-state: a freshly spawned agent is already \(supervisor.attention(for: agentId).rawValue)")
    }
    try await runOneTurn("first prompt")
    guard supervisor.attention(for: agentId) == .unread else {
        throw fail("read-state: a turn completed while you were looking elsewhere and the agent reads \(supervisor.attention(for: agentId).rawValue), not unread")
    }
    // The axis is routed through the vocabulary, not answered twice: the same
    // unread agent is `woke` once P4.6's fact holds.
    guard supervisor.attention(for: agentId, raisedHand: true) == .woke else {
        throw fail("read-state: a raised hand on an unread agent reads \(supervisor.attention(for: agentId, raisedHand: true).rawValue), not woke")
    }

    // 2 · a deliberate focus clears it.
    supervisor.focus(agentID: agentId)
    guard supervisor.attention(for: agentId) == .none else {
        throw fail("read-state: focusing the agent left it \(supervisor.attention(for: agentId).rawValue)")
    }

    // 3 · a turn completing while you are here is not unread.
    try await runOneTurn("second prompt")
    guard supervisor.attention(for: agentId) == .none else {
        throw fail("read-state: a turn you watched finish was marked \(supervisor.attention(for: agentId).rawValue) — the mark would then mean `has ever finished a turn`")
    }

    // 4 · focus leaves, and the next turn is unread again.
    supervisor.focus(agentID: nil)
    try await runOneTurn("third prompt")
    guard supervisor.attention(for: agentId) == .unread else {
        throw fail("read-state: focus left and the next turn still reads \(supervisor.attention(for: agentId).rawValue)")
    }

    // 5 · focus by TILE, which is the shape the desktop's focus actually has.
    guard supervisor.agent(forTile: tileId) == agentId else {
        throw fail("read-state: the agent is not bound to its tile, so the tile-keyed focus is untested")
    }
    supervisor.focusTile(tileId)
    guard supervisor.focusedAgentID == agentId, supervisor.attention(for: agentId) == .none else {
        throw fail("read-state: focusing the agent's TILE left it \(supervisor.attention(for: agentId).rawValue)")
    }
    // A tile that shows no agent focuses nothing, rather than leaving the previous
    // agent armed — otherwise clicking a terminal would keep an agent's turns read.
    supervisor.focusTile(UUID())
    guard supervisor.focusedAgentID == nil else {
        throw fail("read-state: focusing an unrelated tile left \(String(describing: supervisor.focusedAgentID)) armed")
    }
    try await runOneTurn("fourth prompt")
    guard supervisor.attention(for: agentId) == .unread else {
        throw fail("read-state: a turn after focus moved to another tile reads \(supervisor.attention(for: agentId).rawValue)")
    }

    // 6 · LOCAL ONLY. Read-state is per-human and per-device, so it may not be in
    //     the record — the type `AgentStore` writes and the companion publishes.
    guard let record = supervisor.records[agentId] else {
        throw fail("read-state: the agent lost its record")
    }
    let encoded = try JSONEncoder().encode(record)
    guard let fields = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
        throw fail("read-state: the record did not encode as an object")
    }
    // Vacuity guard: the scan below only means something if it can see the record's
    // real keys.
    guard fields["id"] != nil else {
        throw fail("read-state: the encoded record has no `id` key, so this scan is blind: \(fields.keys.sorted())")
    }
    let forbidden = ["unread", "read", "attention", "focus", "focused", "seen", "viewed"]
    for key in fields.keys {
        let lowered = key.lowercased()
        if let hit = forbidden.first(where: { lowered.contains($0) }) {
            throw fail("read-state: AgentRecord carries `\(key)` (matches `\(hit)`) — read-state is per-human and per-device and must not be persisted or synced")
        }
    }
    // And the store round-trip says the same thing from the other side: a second
    // supervisor over the SAME directory restores the agent and knows nothing about
    // this session's reading.
    let relaunched = AgentSupervisor(store: AgentStore(applicationSupportDirectory: root), makeRunner: { _ in ScriptedAgentRunner(script: []) })
    let report = relaunched.restore()
    guard report.restored.contains(agentId) else {
        throw fail("read-state: the relaunched supervisor did not restore the agent (restored \(report.restored.count), stale \(report.stale.count)), so the round-trip is untested")
    }
    guard relaunched.attention(for: agentId) == .none else {
        throw fail("read-state: an unread mark survived into a fresh supervisor as \(relaunched.attention(for: agentId).rawValue) — it reached the disk")
    }

    // Archiving takes the read-state with it.
    supervisor.focus(agentID: agentId)
    supervisor.archive(agentId)
    guard supervisor.focusedAgentID == nil, supervisor.attention(for: agentId) == .none else {
        throw fail("read-state: archiving left focus \(String(describing: supervisor.focusedAgentID)) / attention \(supervisor.attention(for: agentId).rawValue) behind for a gone agent")
    }

    return "read-state over \(turnsRun) real turns: unwatched turns read unread, focus (by agent and by tile) clears it, a watched turn never sets it, and it survives neither the record (\(fields.count) keys) nor a relaunch"
}

// Ticket: docs/38-tickets/90-agent-ux/P4.4-auto-unsettle.md
//
/// A settle that goes stale silently is the failure here: an agent the human said
/// "done" to starts working again, and the row stays buried.
///
/// Every settled agent in this check is made settled BY THE STORE and adopted with
/// `restore()` — nothing in this process ever wrote the override in memory — so the
/// clear is observed against state the supervisor did not create, which is what a
/// relaunched settled agent really is.
///
/// What it asserts:
///   1. The activity CLASSIFIER, as a table over every `AgentRuntimeEvent` case.
///      `.sessionStateChanged(.ready)` on the not-activity side is the packet's named
///      watch-out — an agent settling into ready is the normal END of work.
///   2. A real activity event through `deliver` clears the settle AND reaches the
///      disk, including for `.requestOpened`/`.userInputRequested`, which are not
///      `isPersistWorthy`: a clear that lived only in memory would come back settled.
///   3. The REGRESSION WITNESS the packet names: an observer-shaped refresh does not
///      clear. Four shapes of it — the `.ready` that ends a turn, a `.turnCompleted`,
///      a `.tokenUsageUpdated` meter, and `stop()`'s `.stopped` — plus the two
///      no-op reads (`focus`/`focusTile` is viewing, and reading is free per P4.9;
///      `branchContext` is the header refresh).
///   4. A user message (`send`) clears it.
///   5. The keep-active `.active` PIN survives activity, per
///      `SettledOverride.afterActivity()`'s reasoning: clearing it would discard a
///      human decision and let the next inactivity sweep bury the row.
///   6. The two clears are ATTRIBUTED: `.activity` for the app's, `.user` for
///      `clearSettle(agentID:)`, and `restore()` records neither.
@MainActor
private func checkAutoUnsettle(
    config: AgentModelConfig.Resolution,
    cwd: URL,
    fail: (String) -> Error
) async throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-auto-unsettle-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentStore(applicationSupportDirectory: root)

    // MARK: 1 · the classifier, as a table

    let provider = "provider-thread"
    let activity: [AgentRuntimeEvent] = [
        .sessionStateChanged(.starting),
        .sessionStateChanged(.running),
        .turnStarted(threadId: provider, turnId: "t1"),
        .requestOpened(threadId: provider, requestId: "r1", kind: .commandExecutionApproval),
        .userInputRequested(threadId: provider, requestId: "q1", questions: [])
    ]
    let notActivity: [AgentRuntimeEvent] = [
        .sessionStateChanged(.ready),
        .sessionStateChanged(.waiting),
        .sessionStateChanged(.stopped),
        .sessionStateChanged(.error),
        .turnCompleted(threadId: provider, turnId: "t1", outcome: .completed, errorMessage: nil),
        .itemStarted(threadId: provider, itemId: "i1", kind: .commandExecution, title: "ls"),
        .itemCompleted(threadId: provider, itemId: "i1", kind: .commandExecution, status: .completed),
        .contentDelta(threadId: provider, turnId: "t1", streamKind: .assistant, delta: "…"),
        .requestResolved(threadId: provider, requestId: "r1", decision: "approved"),
        .userInputResolved(threadId: provider, requestId: "q1"),
        .tokenUsageUpdated(threadId: provider, snapshot: TokenUsageSnapshot(inputTokens: 1, outputTokens: 1, totalCostUsd: nil)),
        .runtimeError(threadId: provider, message: "boom")
    ]
    for event in activity where !AgentSupervisor.isRealActivity(event) {
        throw fail("auto-unsettle: \(event) is real activity and the classifier says it is not")
    }
    for event in notActivity where AgentSupervisor.isRealActivity(event) {
        throw fail("auto-unsettle: \(event) is not real activity and the classifier says it is — un-settling on it would undo a settle the moment it was made")
    }
    // Both sides of the table cover every `AgentRuntimeEvent` case, which
    // `isRealActivity`'s exhaustive switch keeps honest at compile time; the count
    // guard is what catches a case dropped from THIS table.
    let caseCount = activity.count + notActivity.count
    guard caseCount == 17 else {
        throw fail("auto-unsettle: the classifier table covers \(caseCount) event shapes, expected 17 — a case was added or dropped without a decision")
    }

    // MARK: 2 · a settled agent, made settled by the store

    let settledOn = Date(timeIntervalSinceReferenceDate: 700_000_000)
    // The log is the durable half of the attribution (`logSettleCleared`), so it is
    // captured rather than left on stderr — a reason nobody can read is not a reason.
    final class WarningLog { var lines: [String] = [] }
    let warnings = WarningLog()
    let supervisor = AgentSupervisor(
        store: store,
        makeRunner: { _ in ScriptedAgentRunner(script: []) },
        warn: { warnings.lines.append($0) }
    )
    func adoptAgent(_ name: String, override: SettledOverride) throws -> AgentID {
        let id = AgentID(rawValue: UUID())
        try store.upsert(AgentRecord(
            id: id,
            displayName: name,
            model: config.model,
            thinking: config.thinking,
            cwd: cwd.path,
            createdAt: settledOn,
            lastActivityAt: settledOn,
            settledOverride: override,
            settledAt: override == .settled ? settledOn : nil
        ))
        supervisor.restore()
        guard supervisor.records[id]?.settledOverride == override else {
            throw fail("auto-unsettle: restore() did not adopt \(name) as \(override.rawValue) — got \(String(describing: supervisor.records[id]?.settledOverride.rawValue)); a refresh of the store must not touch the override")
        }
        guard supervisor.settledOverrideClearReasons[id] == nil else {
            throw fail("auto-unsettle: restoring \(name) recorded a clear reason \(String(describing: supervisor.settledOverrideClearReasons[id]?.rawValue)) — restore clears nothing")
        }
        return id
    }

    // 2a · an approval opening un-settles it, and the clear reaches the DISK even
    //      though `.requestOpened` is not persist-worthy on its own.
    let approvalAgent = try adoptAgent("approval", override: .settled)
    supervisor.qaDeliver(.requestOpened(threadId: provider, requestId: "r1", kind: .commandExecutionApproval), to: approvalAgent)
    guard supervisor.records[approvalAgent]?.settledOverride == .neutral else {
        throw fail("auto-unsettle: an approval request left the agent \(String(describing: supervisor.records[approvalAgent]?.settledOverride.rawValue)) — a settled agent waiting on a human is the row this ticket exists to un-bury")
    }
    guard supervisor.settledOverrideClearReasons[approvalAgent] == .activity else {
        throw fail("auto-unsettle: the app's own clear was attributed \(String(describing: supervisor.settledOverrideClearReasons[approvalAgent]?.rawValue)), not activity")
    }
    // The attribution is READABLE, not just held in a dictionary that dies with the
    // process: one log line naming the agent and the reason.
    func clearLines(_ id: AgentID) -> [String] {
        warnings.lines.filter { $0.contains(id.rawValue.uuidString) && $0.contains("cleared the settle") }
    }
    guard clearLines(approvalAgent) == ["AgentSupervisor: cleared the settle on agent \(approvalAgent.rawValue.uuidString) — reason activity"] else {
        throw fail("auto-unsettle: the app's clear was not logged as an activity clear — got \(clearLines(approvalAgent))")
    }
    guard try store.load(id: approvalAgent)?.settledOverride == .neutral else {
        throw fail("auto-unsettle: the clear did not reach the store (\(String(describing: try store.load(id: approvalAgent)?.settledOverride.rawValue))) — `.requestOpened` is not persist-worthy, so the agent would come back settled on the next launch")
    }

    // 2b · an INPUT request too — the other not-persist-worthy activity event, and the
    //      one a summary could otherwise claim on the classifier table's word alone.
    let questionAgent = try adoptAgent("question", override: .settled)
    supervisor.qaDeliver(
        .userInputRequested(threadId: provider, requestId: "q1", questions: []),
        to: questionAgent
    )
    guard supervisor.records[questionAgent]?.settledOverride == .neutral,
          try store.load(id: questionAgent)?.settledOverride == .neutral else {
        throw fail("auto-unsettle: an input request left the agent \(String(describing: supervisor.records[questionAgent]?.settledOverride.rawValue)) in memory / \(String(describing: try store.load(id: questionAgent)?.settledOverride.rawValue)) on disk")
    }

    // 2c · a session coming alive does the same.
    let aliveAgent = try adoptAgent("alive", override: .settled)
    supervisor.qaDeliver(.sessionStateChanged(.running), to: aliveAgent)
    guard supervisor.records[aliveAgent]?.settledOverride == .neutral,
          try store.load(id: aliveAgent)?.settledOverride == .neutral else {
        throw fail("auto-unsettle: a session coming alive left the agent \(String(describing: supervisor.records[aliveAgent]?.settledOverride.rawValue)) in memory / \(String(describing: try store.load(id: aliveAgent)?.settledOverride.rawValue)) on disk")
    }

    // MARK: 3 · the regression witness — a refresh does not un-settle

    let refreshAgent = try adoptAgent("refresh", override: .settled)
    for event in notActivity {
        supervisor.qaDeliver(event, to: refreshAgent)
        guard supervisor.records[refreshAgent]?.settledOverride == .settled else {
            throw fail("auto-unsettle: \(event) un-settled the agent — an agent settling into ready, or reporting on itself, is the normal end of work and would undo every settle")
        }
    }
    guard try store.load(id: refreshAgent)?.settledOverride == .settled else {
        throw fail("auto-unsettle: the stored override moved to \(String(describing: try store.load(id: refreshAgent)?.settledOverride.rawValue)) with no activity")
    }
    guard supervisor.settledOverrideClearReasons[refreshAgent] == nil, clearLines(refreshAgent).isEmpty else {
        throw fail("auto-unsettle: a refresh recorded a clear reason \(String(describing: supervisor.settledOverrideClearReasons[refreshAgent]?.rawValue)) / logged \(clearLines(refreshAgent))")
    }
    // A deliberate stop is the same shape through the REAL entry point rather than
    // `qaDeliver`: `stop` delivers `.sessionStateChanged(.stopped)` itself.
    supervisor.stop(refreshAgent)
    guard supervisor.records[refreshAgent]?.settledOverride == .settled else {
        throw fail("auto-unsettle: stopping the agent un-settled it — a stop ends work, it does not start it")
    }
    // Viewing is free (P4.9), and so is the header's branch refresh.
    supervisor.focus(agentID: refreshAgent)
    supervisor.focusTile(UUID())
    _ = supervisor.branchContext(for: refreshAgent)
    guard supervisor.records[refreshAgent]?.settledOverride == .settled,
          supervisor.settledOverrideClearReasons[refreshAgent] == nil else {
        throw fail("auto-unsettle: looking at the row un-settled it (\(String(describing: supervisor.records[refreshAgent]?.settledOverride.rawValue))) — reading is free")
    }

    // MARK: 4 · a user message un-settles it, through `send`

    let promptAgent = try adoptAgent("prompt", override: .settled)
    supervisor.send("carry on", to: promptAgent)
    guard supervisor.records[promptAgent]?.settledOverride == .neutral,
          try store.load(id: promptAgent)?.settledOverride == .neutral else {
        throw fail("auto-unsettle: sending a prompt to a settled agent left it \(String(describing: supervisor.records[promptAgent]?.settledOverride.rawValue)) in memory / \(String(describing: try store.load(id: promptAgent)?.settledOverride.rawValue)) on disk")
    }
    guard supervisor.settledOverrideClearReasons[promptAgent] == .activity else {
        throw fail("auto-unsettle: a user message was attributed \(String(describing: supervisor.settledOverrideClearReasons[promptAgent]?.rawValue)), not activity")
    }
    // `settledAt` is deliberately LEFT ALONE: an override that was cleared still
    // happened, and P3.4 orders history by when work ended.
    guard supervisor.records[promptAgent]?.settledAt == settledOn else {
        throw fail("auto-unsettle: clearing the override also erased settledAt (\(String(describing: supervisor.records[promptAgent]?.settledAt)))")
    }

    // MARK: 5 · the keep-active pin is not something activity may outvote

    let pinnedAgent = try adoptAgent("pinned", override: .active)
    supervisor.qaDeliver(.sessionStateChanged(.running), to: pinnedAgent)
    supervisor.send("carry on", to: pinnedAgent)
    guard supervisor.records[pinnedAgent]?.settledOverride == .active else {
        throw fail("auto-unsettle: activity reset the keep-active pin to \(String(describing: supervisor.records[pinnedAgent]?.settledOverride.rawValue)) — the next inactivity sweep would then bury a row the human deliberately kept")
    }
    guard supervisor.settledOverrideClearReasons[pinnedAgent] == nil else {
        throw fail("auto-unsettle: a pin that did not move still recorded a clear reason \(String(describing: supervisor.settledOverrideClearReasons[pinnedAgent]?.rawValue))")
    }

    // MARK: 6 · the human's own path is separate, and says so

    let userAgent = try adoptAgent("user", override: .settled)
    guard supervisor.clearSettle(agentID: userAgent) else {
        throw fail("auto-unsettle: clearSettle refused a settled agent")
    }
    guard supervisor.records[userAgent]?.settledOverride == .neutral,
          try store.load(id: userAgent)?.settledOverride == .neutral else {
        throw fail("auto-unsettle: the user's clear did not stick (\(String(describing: supervisor.records[userAgent]?.settledOverride.rawValue)) / \(String(describing: try store.load(id: userAgent)?.settledOverride.rawValue)))")
    }
    guard supervisor.settledOverrideClearReasons[userAgent] == .user else {
        throw fail("auto-unsettle: the human's clear was attributed \(String(describing: supervisor.settledOverrideClearReasons[userAgent]?.rawValue)), not user — the two paths must be tellable apart")
    }
    guard clearLines(userAgent) == ["AgentSupervisor: cleared the settle on agent \(userAgent.rawValue.uuidString) — reason user"] else {
        throw fail("auto-unsettle: the human's clear was not logged as a user clear — got \(clearLines(userAgent))")
    }
    guard supervisor.clearSettle(agentID: userAgent) == false else {
        throw fail("auto-unsettle: clearSettle reported a write for an agent that was already neutral")
    }
    guard supervisor.clearSettle(agentID: AgentID(rawValue: UUID())) == false else {
        throw fail("auto-unsettle: clearSettle reported a write for an agent this supervisor does not have")
    }

    return "auto-unsettle over \(caseCount) event shapes: an approval, an input request and a session coming alive clear a restored settle (memory AND store), a user message clears it, \(notActivity.count) observer-shaped events + stop + focus + a branch refresh do not, the keep-active pin survives all of it, and the two clears are attributed activity vs user in \(warnings.lines.filter { $0.contains("cleared the settle") }.count) log lines"
}

// Ticket: docs/38-tickets/90-agent-ux/P6.1-per-agent-model-effort.md
//
/// Model and thinking level, per agent, in the tile — the failure this closes is
/// that both were configurable ONLY as a global default in Settings, for every
/// future agent at once and nowhere near the agent you were looking at.
///
/// NO PI, NO NETWORK, NO WALL CLOCK: the runner behind the two-method
/// `AgentRunning` protocol is a `ScriptedAgentRunner`, and the flags a real turn
/// would carry are asserted through `AgentSupervisor.runnerConfig(for:)` and
/// `PiAgentRunner.processArguments`, both pure over the record.
///
/// THE FIXTURE'S VALUES DIFFER FROM THE GLOBAL DEFAULT, deliberately and with a
/// vacuity guard: the defaults and a freshly-spawned record are equal by
/// construction, so an agent that picked the default would prove nothing — every
/// assertion here would stay green against a `runnerConfig` that read
/// `AgentModelConfig` instead of the record.
///
/// What it asserts:
///   1. The mutator writes the record and the write REACHES DISK — asserted on a
///      re-read from the store, so a change that lived only in memory (and would
///      come back as the old model next launch) is red.
///   2. The next turn's flags: `runnerConfig(for:)` over the RELOADED record, and
///      the argument vector `PiAgentRunner` builds from it.
///   3. Two agents holding different models at the same time.
///   4. Moving the global Settings default does NOT move an existing agent.
///   5. A value outside `AgentModelConfig`'s catalogue is refused, not substituted.
///   6. The tile: its pickers carry exactly the catalogue, seed from the RECORD,
///      write a pick back through to the store, go unavailable with the rest of
///      compose while a turn is in flight, and keep the "next turn" notice
///      unpickable across an `NSMenu.update()`.
///
/// SEVEN NEGATIVE TESTS observed RED at exit 1 against this final code, the failure
/// text quoted verbatim:
///   1. `persist(record)` dropped from `setProviderSettings` — "the store holds
///      openai-codex/gpt-5.6-sol / medium, not the picked openai-codex/gpt-5.4-mini
///      / xhigh". The re-read from disk is what catches it; the in-memory assertion
///      above stays green.
///   2. `runnerConfig(for:)` fed `AgentModelConfig.resolvedFromDefaults()` instead of
///      the record — "the runner would be built with openai-codex/gpt-5.6-sol /
///      medium". THE ONE THAT NEEDS THE UNLIKE-THE-DEFAULT FIXTURE: with a
///      default-valued agent this bug is green.
///   3. The two popups left out of `applyComposeAvailability()` — "the pickers
///      stayed live during a turn".
///   4. `autoenablesItems` left at AppKit's default — "`Applies to the next turn`
///      came back pickable after NSMenu.update()".
///   5. The model options re-typed as a five-entry literal — "the model picker
///      offers […5 ids], not AgentModelConfig.modelOptions […7 ids]".
///   6. `attach` re-seeding the tile from the global default instead of the record —
///      "attaching left the tile showing Resolution(model: openai-codex/gpt-5.6-sol,
///      thinking: medium) instead of the agent's own".
///   7. The compose row left at its old single-body-line height — red in
///      `--ui-geometry-check`, not here: "managedAgent@320pt.NSAppearanceNameAqua:
///      … holds a broken required constraint — measured 24.0, needs == 41.0".
/// Two more for the cross-review's findings, same standard:
///   8. Both fields submitted on every pick instead of only the one that moved —
///      "an off-catalogue model made the thinking level unchangeable".
///   9. The revert-on-refusal dropped — "a refused pick left the record at
///      openai-codex/gpt-5.5 and the picker showing openai-codex/gpt-4o-legacy".
@MainActor
private func checkPerAgentProviderSettings(
    cwd: URL,
    fail: (String) -> Error
) async throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-provider-settings-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AgentStore(applicationSupportDirectory: root)

    // The picks, chosen to be UNLIKE the defaults in both fields. Guarded, because
    // the whole check turns on that difference.
    let pickedModel = "openai-codex/gpt-5.4-mini"
    let pickedThinking = "xhigh"
    let globalDefault = AgentModelConfig.resolvedFromDefaults()
    guard pickedModel != globalDefault.model, pickedThinking != globalDefault.thinking,
          AgentModelConfig.modelOptions.contains(pickedModel),
          AgentModelConfig.thinkingOptions.contains(pickedThinking) else {
        throw fail("provider-settings: the fixture's pick (\(pickedModel) / \(pickedThinking)) is the global default or is not in the catalogue — every assertion below would be green against a runner that ignored the record")
    }

    let supervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) })
    let tileId = UUID()
    let agentId = supervisor.spawn(
        role: nil,
        prompt: nil,
        cwd: cwd,
        model: globalDefault.model,
        thinking: globalDefault.thinking,
        tileId: tileId
    )

    // MARK: 1 · the mutator writes the record, and the write reaches disk

    guard supervisor.providerSettings(for: agentId) == globalDefault else {
        throw fail("provider-settings: a fresh agent reads \(String(describing: supervisor.providerSettings(for: agentId))), not the values it was spawned with")
    }
    guard supervisor.setProviderSettings(agentID: agentId, model: pickedModel, thinking: pickedThinking) else {
        throw fail("provider-settings: setProviderSettings refused a catalogue model/thinking pair on a live agent")
    }
    guard supervisor.setProviderSettings(agentID: agentId, model: pickedModel, thinking: pickedThinking) == false else {
        throw fail("provider-settings: re-picking the values the agent already had reported a write")
    }
    guard supervisor.setProviderSettings(agentID: AgentID(rawValue: UUID()), model: pickedModel) == false else {
        throw fail("provider-settings: setProviderSettings reported a write for an agent this supervisor does not have")
    }
    guard let stored = try store.load(id: agentId) else {
        throw fail("provider-settings: no record on disk for the agent at \(store.layout.agentFile(id: agentId).path)")
    }
    guard stored.model == pickedModel, stored.thinking == pickedThinking else {
        throw fail("provider-settings: the store holds \(stored.model) / \(stored.thinking), not the picked \(pickedModel) / \(pickedThinking) — a pick that lives only in memory comes back as the old model on the next launch")
    }

    // MARK: 2 · the NEXT turn's flags, from the reloaded record

    let config = AgentSupervisor.runnerConfig(for: stored)
    guard config.model == pickedModel, config.thinking == pickedThinking else {
        throw fail("provider-settings: the runner would be built with \(config.model) / \(config.thinking) — the record is not what decides the next turn")
    }
    let args = PiAgentRunner.processArguments(
        model: config.model,
        thinking: config.thinking,
        sessionId: config.sessionId,
        extraArgs: config.extraArgs,
        prompt: "next turn"
    )
    guard let modelFlag = args.firstIndex(of: "--model"), args.indices.contains(modelFlag + 1),
          args[modelFlag + 1] == pickedModel,
          let thinkingFlag = args.firstIndex(of: "--thinking"), args.indices.contains(thinkingFlag + 1),
          args[thinkingFlag + 1] == pickedThinking else {
        throw fail("provider-settings: Pi would be spawned as \(args) — the pick does not reach the flags")
    }

    // MARK: 3 · two agents, two models, at the same time

    let otherId = supervisor.spawn(
        role: nil,
        prompt: nil,
        cwd: cwd,
        model: globalDefault.model,
        thinking: globalDefault.thinking
    )
    guard supervisor.providerSettings(for: otherId) == globalDefault,
          supervisor.providerSettings(for: agentId)?.model == pickedModel else {
        throw fail("provider-settings: picking a model for one agent moved another's — \(String(describing: supervisor.providerSettings(for: otherId))) vs \(String(describing: supervisor.providerSettings(for: agentId)))")
    }

    // MARK: 4 · the global default moves; the agent that already exists does not

    let suite = "continuum-provider-settings-check-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        throw fail("provider-settings: could not open an isolated defaults suite")
    }
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let movedDefault = "openai-codex/gpt-5.3-codex-spark"
    guard movedDefault != pickedModel, movedDefault != globalDefault.model else {
        throw fail("provider-settings: the moved default \(movedDefault) is not distinct from the pick or the original default")
    }
    defaults.set(movedDefault, forKey: AgentModelConfig.modelKey)
    defaults.set("minimal", forKey: AgentModelConfig.thinkingKey)
    guard AgentModelConfig.resolvedFromDefaults(defaults: defaults).model == movedDefault else {
        throw fail("provider-settings: the isolated defaults suite did not take the moved default, so this section proves nothing")
    }
    guard supervisor.providerSettings(for: agentId)?.model == pickedModel,
          try store.load(id: agentId)?.model == pickedModel,
          AgentSupervisor.runnerConfig(for: stored).model == pickedModel else {
        throw fail("provider-settings: moving the global Settings default moved an agent that already existed — the record is the truth, and \"per-agent\" means the default is only a seed")
    }

    // MARK: 5 · a value outside the catalogue is refused, never substituted

    for bad in ["gpt-5.6", "openai-codex/gpt-9", ""] {
        guard supervisor.setProviderSettings(agentID: agentId, model: bad) == false else {
            throw fail("provider-settings: \(bad.isEmpty ? "an empty model" : bad) was accepted — `--model` takes a pattern, so a partial id fuzzy-matches and the agent silently runs whichever model Pi picked (the P0.10 bug)")
        }
    }
    guard supervisor.setProviderSettings(agentID: agentId, thinking: "ludicrous") == false else {
        throw fail("provider-settings: a thinking level Pi does not accept was written to the record")
    }
    guard supervisor.providerSettings(for: agentId)?.model == pickedModel,
          supervisor.providerSettings(for: agentId)?.thinking == pickedThinking else {
        throw fail("provider-settings: a refused value still moved the record to \(String(describing: supervisor.providerSettings(for: agentId)))")
    }
    // `"off"` is a LEGAL thinking level, not a null — the packet's watch-out.
    guard supervisor.setProviderSettings(agentID: agentId, thinking: "off"),
          try store.load(id: agentId)?.thinking == "off" else {
        throw fail("provider-settings: `off` was refused as a thinking level — Pi accepts it, and filtering it out would take a real option off the picker")
    }
    supervisor.setProviderSettings(agentID: agentId, thinking: pickedThinking)

    // MARK: 6 · the tile

    let tile = ManagedAgentTileNSView(tile: Tile(
        id: tileId,
        kind: .managedAgent,
        title: "agent",
        frame: TileFrame(x: 0, y: 0, width: 520, height: 360),
        zPosition: .fromLegacyRank(1),
        runtimeRef: nil,
        metadata: TileMetadata(launchProfileId: "managed")
    ))
    // Before it knows an agent, the tile shows the global default — the seed.
    guard tile.qaProviderSettings == AgentModelConfig.resolvedFromDefaults() else {
        throw fail("provider-settings: a tile with no agent shows \(tile.qaProviderSettings), not the global default")
    }
    // The options ARE the catalogue, listed rather than counted: a second hardcoded
    // list here would drift from Pi's, which is what P0.10 closed.
    guard tile.qaUsesCustomProviderControls else {
        throw fail("provider-settings: the production tile still exposes native popup chrome instead of the custom next-turn footer")
    }
    guard tile.qaModelOptionTitles == AgentModelConfig.modelOptions else {
        throw fail("provider-settings: the model picker offers \(tile.qaModelOptionTitles), not AgentModelConfig.modelOptions \(AgentModelConfig.modelOptions)")
    }
    guard tile.qaThinkingOptionTitles == AgentModelConfig.thinkingOptions else {
        throw fail("provider-settings: the thinking picker offers \(tile.qaThinkingOptionTitles), not AgentModelConfig.thinkingOptions \(AgentModelConfig.thinkingOptions)")
    }
    guard tile.qaProviderNoticeIsPickable == false else {
        throw fail("provider-settings: `\(ManagedAgentTileNSView.providerNoticeText)` came back pickable after NSMenu.update() — autoenablesItems is at AppKit's default, so a menu header re-derives itself live")
    }

    tile.attach(agentID: agentId, supervisor: supervisor)
    guard tile.qaProviderSettings == AgentModelConfig.Resolution(model: pickedModel, thinking: pickedThinking) else {
        throw fail("provider-settings: attaching left the tile showing \(tile.qaProviderSettings) instead of the agent's own \(pickedModel) / \(pickedThinking)")
    }

    // A pick made the way a user makes it reaches the record AND the disk.
    let secondModel = "openai-codex/gpt-5.5"
    guard secondModel != pickedModel else { throw fail("provider-settings: the second pick is the first one") }
    // `qaPick` goes through the popup's own target/action, so a control that was
    // never wired reports false here rather than passing on a handler call the user
    // could not make (from the cross-review).
    guard tile.qaPickModel(secondModel), tile.qaPickThinking("low") else {
        throw fail("provider-settings: a picker's action did not fire — its target/action is unwired, so a real user's pick would do nothing")
    }
    guard supervisor.providerSettings(for: agentId) == AgentModelConfig.Resolution(model: secondModel, thinking: "low"),
          try store.load(id: agentId)?.model == secondModel,
          try store.load(id: agentId)?.thinking == "low" else {
        throw fail("provider-settings: picking in the tile left the record at \(String(describing: supervisor.providerSettings(for: agentId))) / the store at \(String(describing: try store.load(id: agentId).map { "\($0.model) / \($0.thinking)" }))")
    }
    guard AgentSupervisor.runnerConfig(for: try store.load(id: agentId)!).model == secondModel else {
        throw fail("provider-settings: the tile's pick does not reach the next turn's runner config")
    }

    // While a turn is in flight both controls go dark with the rest of compose.
    // Through the supervisor, not direct tile ingest: an attached v2 tile's status
    // derives from the supervisor snapshot (P5.5 status single-ownership), so a
    // fixture event that bypasses `deliver` no longer represents a turn — exactly
    // as a real turn never bypasses it.
    supervisor.qaDeliver(.sessionStateChanged(.running), to: agentId)
    supervisor.qaDeliver(.turnStarted(threadId: AgentSupervisor.threadId(for: agentId), turnId: "t1"), to: agentId)
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { tile.qaComposeEnabled == false }) else {
        throw fail("provider-settings: compose stayed enabled during a turn, so the in-flight assertion below is vacuous")
    }
    guard tile.qaProviderControlsEnabled == false else {
        throw fail("provider-settings: the pickers stayed live during a turn — a change picked mid-turn cannot apply until Phase 5's set_model RPC, and a control that silently does nothing is worse than one that is visibly unavailable")
    }
    tile.qaPickModel(globalDefault.model)
    guard supervisor.providerSettings(for: agentId)?.model == secondModel else {
        throw fail("provider-settings: a disabled picker still wrote \(String(describing: supervisor.providerSettings(for: agentId)?.model)) to the record mid-turn")
    }
    supervisor.qaDeliver(.turnCompleted(threadId: AgentSupervisor.threadId(for: agentId), turnId: "t1", outcome: .completed, errorMessage: nil), to: agentId)
    supervisor.qaDeliver(.sessionStateChanged(.ready), to: agentId)
    // Both, together: the pickers are on `applyComposeAvailability()` and not on a
    // second notion of "busy", so they must come back exactly when compose does.
    guard await waitUntil(timeout: 5, pollInterval: 0.02, { tile.qaProviderControlsEnabled && tile.qaComposeEnabled }) else {
        throw fail("provider-settings: after the turn ended compose is \(tile.qaComposeEnabled ? "live" : "dark") and the pickers are \(tile.qaProviderControlsEnabled ? "live" : "dark") — they must move together")
    }
    tile.detach()

    // MARK: 7 · a value this catalogue no longer has (the cross-review's finding)

    // A record written by an older build can hold a value this catalogue no longer
    // has. The picker SHOWS it rather than renaming it silently, and — the
    // cross-review's finding — the OTHER field stays changeable, because only the
    // field that moved is submitted. Written through the store and re-adopted, so
    // nothing in this process put the foreign value in memory.
    var foreign = try store.load(id: agentId)!
    foreign.model = "openai-codex/gpt-4o-legacy"
    try store.upsert(foreign)
    let foreignSupervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) })
    foreignSupervisor.restore()

    // MARK: 8 · custom composer footer

    // P4.8 exercises the same footer now installed in the production tile: it reads
    // the shared catalogues, labels its scope truthfully, persists through the same
    // supervisor, and submits only the field that moved.
    // Label variants are a MEASURED fit since the P5.5 corrections, not a
    // width threshold: 240 pt cannot hold this catalogue's full titles (compact
    // expected), and at 640 pt the full titles must come back verbatim.
    let footer = AgentComposerFooterView(frame: NSRect(x: 0, y: 0, width: 240, height: 48))
    footer.apply(foreignSupervisor.providerSettings(for: agentId)!)
    footer.onSettingsWrite = { model, thinking in
        foreignSupervisor.setProviderSettings(agentID: agentId, model: model, thinking: thinking)
    }
    footer.layoutSubtreeIfNeeded()
    guard footer.qaModelTitles == (AgentModelConfig.modelOptions + [foreign.model]).map(AgentComposerFooterView.abbreviatedModel),
          footer.qaEffortTitles == AgentModelConfig.thinkingOptions.map(AgentComposerFooterView.abbreviatedEffort),
          footer.modelButton.accessibilityLabel() == "Model, next turn",
          footer.effortButton.accessibilityLabel() == "Reasoning effort, next turn" else {
        throw fail("provider-settings: the custom footer diverged from AgentModelConfig, hid the off-catalog model, or lost its next-turn accessibility labels")
    }
    footer.setFrameSize(NSSize(width: 640, height: 48))
    footer.layoutSubtreeIfNeeded()
    guard footer.qaModelTitles == AgentModelConfig.modelOptions + [foreign.model],
          footer.qaEffortTitles == AgentModelConfig.thinkingOptions.map(\.capitalized) else {
        throw fail("provider-settings: 640 pt did not restore the full model ids and effort names — the measured fit stayed compact with room to spare")
    }
    guard footer.qaPickThinking("high"),
          foreignSupervisor.providerSettings(for: agentId)?.model == foreign.model,
          foreignSupervisor.providerSettings(for: agentId)?.thinking == "high",
          try store.load(id: agentId)?.model == foreign.model,
          try store.load(id: agentId)?.thinking == "high" else {
        throw fail("provider-settings: the custom footer's effort-only change overwrote or rejected the off-catalog model instead of persisting only effort")
    }
    // Detaching is view-only. A new footer populated from a supervisor reloaded from
    // disk must show the same non-default pair.
    let reloadedSupervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) })
    reloadedSupervisor.restore()
    let reattachedFooter = AgentComposerFooterView(frame: footer.frame)
    reattachedFooter.apply(reloadedSupervisor.providerSettings(for: agentId)!)
    guard reattachedFooter.qaSettings == AgentModelConfig.Resolution(model: foreign.model, thinking: "high") else {
        throw fail("provider-settings: custom footer values did not survive detach/re-attach and disk reload — got \(reattachedFooter.qaSettings)")
    }

    // The reciprocal old-record case: a model-only change must not resubmit an
    // effort value this build no longer catalogues.
    let legacyEffort = "legacy-auto"
    let legacyEffortID = foreignSupervisor.spawn(
        role: nil, prompt: nil, cwd: cwd,
        model: pickedModel, thinking: legacyEffort
    )
    let reciprocalFooter = AgentComposerFooterView(frame: footer.frame)
    reciprocalFooter.apply(foreignSupervisor.providerSettings(for: legacyEffortID)!)
    reciprocalFooter.onSettingsWrite = { model, thinking in
        foreignSupervisor.setProviderSettings(agentID: legacyEffortID, model: model, thinking: thinking)
    }
    guard reciprocalFooter.qaEffortTitles.last == AgentComposerFooterView.abbreviatedEffort(legacyEffort),
          reciprocalFooter.qaPickModel(secondModel),
          foreignSupervisor.providerSettings(for: legacyEffortID) == .init(model: secondModel, thinking: legacyEffort),
          try store.load(id: legacyEffortID)?.thinking == legacyEffort else {
        throw fail("provider-settings: the custom footer's model-only change overwrote or rejected an off-catalog effort")
    }
    _ = foreignSupervisor.setProviderSettings(agentID: agentId, thinking: pickedThinking)

    let foreignTile = ManagedAgentTileNSView(tile: Tile(
        id: UUID(),
        kind: .managedAgent,
        title: "agent",
        frame: TileFrame(x: 0, y: 0, width: 520, height: 360),
        zPosition: .fromLegacyRank(1),
        runtimeRef: nil,
        metadata: TileMetadata(launchProfileId: "managed")
    ))
    foreignTile.attach(agentID: agentId, supervisor: foreignSupervisor)
    guard foreignTile.qaProviderSettings.model == foreign.model,
          foreignTile.qaModelOptionTitles == AgentModelConfig.modelOptions + [foreign.model] else {
        throw fail("provider-settings: a record holding \(foreign.model) renders as \(foreignTile.qaProviderSettings.model) with options \(foreignTile.qaModelOptionTitles) — the picker must not rename what the next turn will really run")
    }
    guard foreignTile.qaPickThinking("high"),
          foreignSupervisor.providerSettings(for: agentId)?.thinking == "high",
          foreignSupervisor.providerSettings(for: agentId)?.model == foreign.model else {
        throw fail("provider-settings: an off-catalogue model made the thinking level unchangeable — \(String(describing: foreignSupervisor.providerSettings(for: agentId)))")
    }
    // A pick the supervisor REFUSES puts the record's own value back, rather than
    // leaving a choice on screen that never happened.
    foreignTile.qaPickModel(secondModel)
    foreignTile.qaPickModel(foreign.model)
    guard foreignSupervisor.providerSettings(for: agentId)?.model == secondModel,
          foreignTile.qaProviderSettings.model == secondModel else {
        throw fail("provider-settings: a refused pick left the record at \(String(describing: foreignSupervisor.providerSettings(for: agentId)?.model)) and the picker showing \(foreignTile.qaProviderSettings.model) — a control must not display a choice that was not written")
    }
    foreignTile.detach()

    return "per-agent provider settings: a pick lands on the record and the disk and reaches --model/--thinking (\(pickedModel) / \(pickedThinking), both unlike the global default), two agents hold different models, a moved global default moves neither, \(3 + 1) off-catalogue values are refused while `off` is accepted, and the tile's \(tile.qaModelOptionTitles.count)+\(tile.qaThinkingOptionTitles.count) options are AgentModelConfig's own, unpickable notice included"
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

// MARK: - Fan-out self-check (P2D.6)

/// Gated on `--agent-fanout-check`.
///
/// Deterministic and offline: a real temp `git init` repository (worktrees are the
/// half that cannot be faked without testing nothing) and `ScriptedAgentRunner`s in
/// place of Pi. The runner factory picks its script from the RECORD's
/// `sourceItemId`, which is also the first witness that the mapping exists at spawn
/// time rather than being attached afterwards.
///
/// Six properties:
///   1. Three selected rows → three agents, each with its own worktree, its own
///      branch, and its own item's prompt. Git is asked, not the manager's return
///      value.
///   2. Completing agent 2 checks off item 2 IN THE TILE and leaves 1 and 3 alone.
///   3. Past the cap: 6 items → `maxFanOutBatch` launched, the rest DEFERRED and
///      named in the report the tile renders. Nothing is silently dropped —
///      launched + deferred + refused == items, asserted on every report here.
///   4. An item that already has an agent is REFUSED, not fanned out twice.
///   5. The mapping survives a relaunch: a second supervisor over the same store
///      resolves item → agent from the restored records alone.
///   6. A fan-out under a parent is also held to `maxChildrenPerParent`, so it is
///      not a way around the cap `handleSpawnRequest` enforces one spawn at a time.
///
/// Negative tests observed red at exit 1 with the final code are quoted at the
/// assertions they land at.
@MainActor
func runAgentFanOutChecks() async throws {
    struct CheckError: Error, CustomStringConvertible { let description: String }
    func fail(_ message: String) -> CheckError { CheckError(description: message) }
    func requireAccounted(_ report: AgentSupervisor.FanOutReport, _ items: [AgentSupervisor.FanOutItem], _ label: String) throws {
        let accounted = report.launched.count + report.deferred.count + report.refused.count
        guard accounted == items.count else {
            throw fail("\(label): \(items.count) items in, \(accounted) accounted for (\(report.summary)) — a fan-out may never drop an item silently")
        }
    }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("continuum-agent-fanout-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let repo = root.appendingPathComponent("repo", isDirectory: true)
    try makeIsolatedSpawnRepo(at: repo)
    let storeDirectory = root.appendingPathComponent("support", isDirectory: true)
    let store = AgentStore(applicationSupportDirectory: storeDirectory)
    let config = AgentModelConfig.resolvedFromDefaults()

    // MARK: 1 · three selected rows, three isolated agents

    let rows = [
        LinearTicketQueueRow(identifier: "CON-1", title: "Fix auth", state: "Todo", stateType: "unstarted", priority: .high, labels: []),
        LinearTicketQueueRow(identifier: "CON-2", title: "Trim the sidebar", state: "Todo", stateType: "unstarted", priority: .medium, labels: []),
        LinearTicketQueueRow(identifier: "CON-3", title: "Cache the branch read", state: "Todo", stateType: "unstarted", priority: .low, labels: [])
    ]
    let tile = Tile(
        id: UUID(uuidString: "A2D60000-0000-4000-8000-000000000001")!,
        kind: .ticketQueue,
        title: "CON Ticket Queue",
        frame: TileFrame(x: 0, y: 0, width: 520, height: 480),
        zPosition: .fromLegacyRank(1),
        runtimeRef: nil,
        metadata: TileMetadata(linearTeamKey: "CON", linearTeamId: nil, linearQuery: nil)
    )

    // Only the item that is meant to finish gets a completing script; the other two
    // stay mid-turn, which is what makes "leaves 1 and 3 untouched" a real claim.
    let completing: [AgentRuntimeEvent] = [
        .sessionStateChanged(.running),
        .turnStarted(threadId: "provider", turnId: "t1"),
        .turnCompleted(threadId: "provider", turnId: "t1", outcome: .completed, errorMessage: nil),
        .sessionStateChanged(.ready)
    ]
    let runners = FanOutRunnerLog()
    let supervisor = AgentSupervisor(store: store, makeRunner: { record in
        runners.make(sourceItemId: record.sourceItemId, script: record.sourceItemId == "CON-2" ? completing : [.sessionStateChanged(.running)])
    })

    var fannedOut: [[LinearTicketQueueRow]] = []
    var lastReport: AgentSupervisor.FanOutReport?
    // Assigned once the tile exists; the handler below runs only on a click.
    var renderReport: ((AgentSupervisor.FanOutReport) -> Void)?
    let queueTile = TicketQueueTileNSView(tile: tile, rows: rows, emptyStateMessage: nil, fanOutHandler: { selected in
        fannedOut.append(selected)
        let report = supervisor.fanOut(
            items: selected.map {
                AgentSupervisor.FanOutItem(id: $0.identifier, prompt: "Work \($0.identifier): \($0.title)")
            },
            role: "implementer",
            cwd: repo,
            model: config.model,
            thinking: config.thinking,
            isolated: true
        )
        lastReport = report
        renderReport?(report)
    })
    // The tile is the source surface: it checks its own rows off.
    supervisor.onFanOutItemCompleted = { [weak queueTile] itemId, _ in
        queueTile?.markItemDone(itemId)
    }
    renderReport = { [weak queueTile] report in queueTile?.report(report.summary) }

    // Selection goes through the rendered checkboxes, not the model behind them —
    // a fan-out that could not be reached from the view is not the gesture.
    for identifier in ["CON-1", "CON-2", "CON-3"] {
        guard let box = queueTile.descendant(withIdentifier: "fanout.select.\(identifier)") as? NSButton else {
            throw fail("row \(identifier) rendered no selection control — a fan-out tile must be selectable")
        }
        box.state = .on
    }
    guard queueTile.selectedRowIdentifiers == ["CON-1", "CON-2", "CON-3"] else {
        throw fail("the tile reports \(queueTile.selectedRowIdentifiers) selected, not all three rows")
    }
    guard let runButton = queueTile.descendant(withIdentifier: "fanout.run") as? NSButton else {
        throw fail("the tile rendered no fan-out control")
    }
    runButton.performClick(nil)

    guard fannedOut.map({ $0.map(\.identifier) }) == [["CON-1", "CON-2", "CON-3"]] else {
        throw fail("the fan-out handler received \(fannedOut.map { $0.map(\.identifier) }), not one batch of all three selected rows")
    }
    guard let firstReport = lastReport else {
        throw fail("the fan-out produced no report")
    }
    let firstItems = rows.map { AgentSupervisor.FanOutItem(id: $0.identifier, prompt: "Work \($0.identifier): \($0.title)") }
    try requireAccounted(firstReport, firstItems, "the first fan-out")
    guard firstReport.launched.map(\.itemId) == ["CON-1", "CON-2", "CON-3"], firstReport.deferred.isEmpty, firstReport.refused.isEmpty else {
        throw fail("three items under the cap should all start: \(firstReport.summary)")
    }

    // Each agent: its own item, its own prompt, its own worktree and branch.
    // NEGATIVE TEST (observed red): `makeAgent` dropping `sourceItemId` →
    // "FAIL: agent … was fanned out for CON-1 and its record says nil".
    var worktrees: [String] = []
    var branches: [String] = []
    let manager = WorktreeManager()
    let listed = try manager.list(repo: repo)
    for (itemId, agentId) in firstReport.launched {
        guard let record = supervisor.records[agentId] else {
            throw fail("the supervisor lost the agent it fanned out for \(itemId)")
        }
        guard record.sourceItemId == itemId else {
            throw fail("agent \(agentId.rawValue.uuidString) was fanned out for \(itemId) and its record says \(record.sourceItemId ?? "nil")")
        }
        guard let branch = record.worktreeBranch else {
            throw fail("the agent for \(itemId) has no branch — a fan-out over one checkout is the clobbering P2C prevents")
        }
        guard record.cwd.hasPrefix(repo.appendingPathComponent(WorktreeManager.containerDirectoryName).path + "/") else {
            throw fail("the agent for \(itemId) works in \(record.cwd), which is not its own worktree")
        }
        guard listed.contains(where: {
            isolatedSpawnResolved($0.path) == isolatedSpawnResolved(URL(fileURLWithPath: record.cwd)) && $0.branch == branch
        }) else {
            throw fail("git does not know the worktree for \(itemId): \(listed.map { $0.path.lastPathComponent })")
        }
        worktrees.append(record.cwd)
        branches.append(branch)
    }
    // NEGATIVE TEST (observed red): reusing one slug for the batch →
    // "FAIL: … three agents share 1 worktree …".
    guard Set(worktrees).count == 3, Set(branches).count == 3 else {
        throw fail("three agents share \(Set(worktrees).count) worktree(s) and \(Set(branches).count) branch(es) — each item needs its own")
    }
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { runners.promptCount == 3 }) else {
        throw fail("only \(runners.promptCount) of 3 fanned-out agents were given a prompt")
    }
    guard runners.prompts(for: "CON-1") == ["Work CON-1: Fix auth"],
          runners.prompts(for: "CON-2") == ["Work CON-2: Trim the sidebar"],
          runners.prompts(for: "CON-3") == ["Work CON-3: Cache the branch read"] else {
        throw fail("the agents did not each get their own item's prompt: \(runners.promptsByItem)")
    }

    // MARK: 2 · completing agent 2 checks off item 2, and only item 2

    // NEGATIVE TEST (observed red): `deliver` firing the completion for every
    // outcome, or the tile marking every row → "FAIL: completing the agent for
    // CON-2 checked off ["CON-1", "CON-2", "CON-3"]".
    guard await waitUntil(timeout: 10, pollInterval: 0.02, { queueTile.doneRowIdentifiers == ["CON-2"] }) else {
        throw fail("completing the agent for CON-2 checked off \(queueTile.doneRowIdentifiers)")
    }
    guard supervisor.completedFanOutItems == ["CON-2"] else {
        throw fail("the supervisor records \(supervisor.completedFanOutItems.sorted()) as completed, not just CON-2")
    }
    guard let doneMarker = queueTile.descendant(withIdentifier: "fanout.done.CON-2"), doneMarker.isHidden == false else {
        throw fail("CON-2's row does not SHOW that it is done")
    }
    for untouched in ["CON-1", "CON-3"] {
        guard let marker = queueTile.descendant(withIdentifier: "fanout.done.\(untouched)"), marker.isHidden else {
            throw fail("\(untouched)'s agent has not finished and its row is marked done")
        }
    }
    // A checked-off row drops out of the selection, so the next fan-out cannot
    // re-launch work that is already done.
    guard queueTile.selectedRowIdentifiers == ["CON-1", "CON-3"] else {
        throw fail("a completed row is still selected: \(queueTile.selectedRowIdentifiers)")
    }

    // MARK: 3 · past the cap: launched to the cap, the rest deferred and REPORTED
    //
    // Not isolated, on purpose: the cap is orthogonal to isolation and section 1
    // already proves the worktree half. Six worktrees to re-prove it would only
    // make this leg slower.
    let capItems = (1 ... 6).map { AgentSupervisor.FanOutItem(id: "CAP-\($0)", prompt: "cap item \($0)") }
    let capReport = supervisor.fanOut(
        items: capItems,
        role: nil,
        cwd: repo,
        model: config.model,
        thinking: config.thinking,
        isolated: false
    )
    try requireAccounted(capReport, capItems, "the capped fan-out")
    // NEGATIVE TEST (observed red): `fanOut` launching every item →
    // "FAIL: 6 items past a cap of 4 started 6 agents and deferred []".
    guard capReport.launched.count == AgentSupervisor.maxFanOutBatch,
          capReport.deferred == ["CAP-5", "CAP-6"],
          capReport.cap == AgentSupervisor.maxFanOutBatch else {
        throw fail("6 items past a cap of \(AgentSupervisor.maxFanOutBatch) started \(capReport.launched.count) agents and deferred \(capReport.deferred)")
    }
    guard supervisor.records.values.filter({ $0.sourceItemId?.hasPrefix("CAP-") == true }).count == AgentSupervisor.maxFanOutBatch else {
        throw fail("the store holds more capped agents than the cap allowed")
    }
    // NEGATIVE TEST (observed red): `summary` omitting the deferred clause →
    // "FAIL: the deferred count is not surfaced …".
    queueTile.report(capReport.summary)
    guard let surfaced = queueTile.fanOutStatusMessage,
          surfaced.contains("deferred 2"),
          surfaced.contains("cap of \(AgentSupervisor.maxFanOutBatch)") else {
        throw fail("the deferred count is not surfaced on the tile: \(queueTile.fanOutStatusMessage ?? "nothing")")
    }
    guard let statusView = queueTile.descendant(withIdentifier: "fanout.status") as? NSTextField,
          statusView.isHidden == false,
          statusView.stringValue == capReport.summary else {
        throw fail("the fan-out report is not RENDERED — a cap the user cannot see is a silent truncation")
    }

    // MARK: 4 · an item that already has an agent is refused, not doubled

    let repeatItems = [AgentSupervisor.FanOutItem(id: "CON-1", prompt: "Work CON-1 again")]
    let repeatReport = supervisor.fanOut(
        items: repeatItems,
        role: "implementer",
        cwd: repo,
        model: config.model,
        thinking: config.thinking,
        isolated: true
    )
    try requireAccounted(repeatReport, repeatItems, "the repeat fan-out")
    guard repeatReport.launched.isEmpty,
          repeatReport.refused.count == 1,
          repeatReport.refused[0].itemId == "CON-1",
          case .alreadyRunning = repeatReport.refused[0].refusal else {
        throw fail("fanning out an item that already has an agent produced \(repeatReport.summary)")
    }
    guard supervisor.records.values.filter({ $0.sourceItemId == "CON-1" }).count == 1 else {
        throw fail("CON-1 has \(supervisor.records.values.filter { $0.sourceItemId == "CON-1" }.count) agents — one item is one agent")
    }

    // MARK: 5 · the mapping survives a relaunch

    // A second supervisor over the same store, holding nothing this one built.
    // NEGATIVE TEST (observed red): `sourceItemId` left out of `AgentRecord`'s
    // `encode` → "FAIL: after a relaunch CON-3 has no agent …".
    let afterRelaunch = AgentSupervisor(store: AgentStore(applicationSupportDirectory: storeDirectory),
                                        makeRunner: { _ in ScriptedAgentRunner(script: []) })
    afterRelaunch.restore()
    for (itemId, agentId) in firstReport.launched {
        guard afterRelaunch.agent(forSourceItem: itemId) == agentId else {
            throw fail("after a relaunch \(itemId) has no agent — the mapping did not survive, so nothing can be checked off")
        }
        guard afterRelaunch.sourceItem(of: agentId) == itemId else {
            throw fail("after a relaunch agent \(agentId.rawValue.uuidString) no longer names its item")
        }
    }

    // MARK: 6 · a fan-out under a parent is held to the parent's child cap too

    let parentId = supervisor.spawn(
        role: "orchestrator",
        prompt: nil,
        cwd: repo,
        model: config.model,
        thinking: config.thinking
    )
    for index in 1 ... 3 {
        _ = supervisor.spawn(
            role: "worker-\(index)",
            prompt: nil,
            cwd: repo,
            model: config.model,
            thinking: config.thinking,
            parentAgentID: parentId
        )
    }
    let childItems = (1 ... 3).map { AgentSupervisor.FanOutItem(id: "CHILD-\($0)", prompt: "child item \($0)") }
    let childReport = supervisor.fanOut(
        items: childItems,
        role: nil,
        cwd: repo,
        model: config.model,
        thinking: config.thinking,
        parentAgentID: parentId,
        isolated: false
    )
    try requireAccounted(childReport, childItems, "the parented fan-out")
    // NEGATIVE TEST (observed red): the cap ignoring the parent's existing children
    // → "FAIL: a parent with 3 of 4 child slots used fanned out 3 …".
    guard childReport.cap == 1, childReport.launched.count == 1, childReport.deferred == ["CHILD-2", "CHILD-3"] else {
        throw fail("a parent with 3 of \(AgentSupervisor.maxChildrenPerParent) child slots used fanned out \(childReport.launched.count) (cap \(childReport.cap), deferred \(childReport.deferred))")
    }
    guard supervisor.children(of: parentId).count == AgentSupervisor.maxChildrenPerParent else {
        throw fail("the parent ended with \(supervisor.children(of: parentId).count) children, past the cap of \(AgentSupervisor.maxChildrenPerParent)")
    }

    // MARK: 7 · the gesture is REACHABLE in the app, not only from this check
    //
    // Same shape as P2A.6's headless assertions, and for the same reason: the
    // sections above drive the view directly, so they would all stay green over an
    // app that never wires a `fanOutHandler` or never dispatches the command. The
    // `case .fanOutQueueSelection:` in `performPaletteAction` cannot be scanned for
    // — deleting it is a compile error, the switch is exhaustive — so what is
    // asserted is the registry, the palette rows, and the install branch.
    guard CommandRegistry.all().contains(where: { $0.id == "agent.fanOut" && $0.action == .fanOutQueueSelection }) else {
        throw fail("⌘K cannot reach a fan-out: no agent.fanOut in CommandRegistry")
    }
    guard LaunchPaletteModel.makeRows(profiles: []).contains(.action(.fanOutQueueSelection)) else {
        throw fail("the fan-out command is registered but not offered as a palette row")
    }
    let installBranch = try ticketQueueInstallSource()
    guard installBranch.contains("fanOutHandler:") else {
        throw fail("the app installs its ticket-queue tile with no fanOutHandler, so no row is selectable in the running app:\n\(installBranch)")
    }
    guard installBranch.contains("completedFanOutItems") else {
        throw fail("a tile installed after a completion would not show it — the install branch never replays completedFanOutItems:\n\(installBranch)")
    }

    supervisor.stopAll()
    print("AgentSupervisor fan-out: 3 rows → 3 agents on 3 worktrees with 3 prompts, completing one checked off exactly that row, \(capReport.summary) at the cap, a repeat refused, the mapping survived a relaunch, and a parented batch fell to cap \(childReport.cap)")
}

/// The scripted runners a fan-out produced, keyed by the item their agent was
/// spawned for — so "each agent got ITS item's prompt" is checkable.
private final class FanOutRunnerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var runners: [String: ScriptedAgentRunner] = [:]

    func make(sourceItemId: String?, script: [AgentRuntimeEvent]) -> AgentRunning {
        let runner = ScriptedAgentRunner(script: script)
        if let sourceItemId {
            lock.withLock { runners[sourceItemId] = runner }
        }
        return runner
    }

    func prompts(for itemId: String) -> [String] {
        lock.withLock { runners[itemId] }?.prompts ?? []
    }

    var promptsByItem: [String: [String]] {
        lock.withLock { runners.mapValues(\.prompts) }
    }

    var promptCount: Int {
        lock.withLock { runners.values.reduce(0) { $0 + $1.prompts.count } }
    }
}

/// The body of `installInitialTicketQueueTile`, for the reachability assertions
/// above. A scan for the same reason `managedAgentCloseBranchSource` is one: the
/// install needs a live `CanvasNSView`, which a headless check does not have.
private func ticketQueueInstallSource() throws -> String {
    struct ScanError: Error, CustomStringConvertible { let description: String }
    let path = "Sources/ContinuumRevived/App/ContinuumApp.swift"
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(path)
    guard let source = try? String(contentsOf: url, encoding: .utf8) else {
        throw ScanError(description: "could not read \(path) — run this check from the repo root")
    }
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let start = lines.firstIndex(where: { $0.contains("func installInitialTicketQueueTile(") }) else {
        throw ScanError(description: "no `func installInitialTicketQueueTile(` in \(path) — the install moved, and this scan is now blind")
    }
    var body: [String] = []
    for line in lines[(start + 1)...] {
        if line.hasPrefix("    }") { break }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { continue }
        body.append(line)
    }
    guard !body.isEmpty else {
        throw ScanError(description: "installInitialTicketQueueTile scanned as empty")
    }
    return body.joined(separator: "\n")
}

// MARK: - P3.3 · the row's state and the tile's presentation say the same thing
//
// Ticket: docs/38-tickets/94-sidebar-native-ux/P3.3-single-status-owner.md
//
// `AgentTileStatePresenter` lives above the row builder (it is App-layer, and it
// paints a header), so it cannot be the shared owner — the SNAPSHOT is. This check
// is the agreement: for every one of the six operational states, the row's
// `InboxState` and the tile's presentation must carry the same meaning, with exactly
// one divergence, named and reasoned.
//
// THE DIVERGENCE: the presenter renders `.failed` as `AgentStatus.idle` (the header
// has its own "Failed" label and does not need a status to carry it), which folds to
// `InboxState.ready`. The row maps `.failed` to `.failed`, because the inbox's one
// label slot is the only place a human sees that an agent broke —
// `AgentInboxRow.swift:52-55` records `.failed` as reachable-but-unwired, "Phase 4
// wires a fact"; this is that fact (§5.11).
@MainActor
func checkInboxStateAgreesWithTilePresenter<Failure: Error>(fail: (String) -> Failure) throws -> String {
    let approval = AgentPendingRequest(
        requestID: "req-approval",
        prompt: "Approve running a command?",
        responseMode: .fixedChoice(ApprovalDecision.compiledChoices),
        kind: .approval
    )
    let input = AgentPendingRequest(
        requestID: "req-input",
        prompt: "Which branch should this land on?",
        responseMode: .fixedChoice([]),
        kind: .input
    )
    // Hand-listed because `AgentTileOperationalState` carries associated values and
    // cannot be `CaseIterable` (design C8). `kindName` is the table the count below
    // is asserted against, so a seventh case cannot be added without appearing here.
    let states: [AgentTileOperationalState] = [
        .ready, .working, .queued, .needsAction(approval), .needsAction(input),
        .failed(message: "provider failed"), .restored
    ]
    guard Set(states.map(\.kindName)).count == 6 else {
        throw fail("presenter-agreement: the case table covers \(Set(states.map(\.kindName)).count) of AgentTileOperationalState's 6 kinds — \(Set(states.map(\.kindName)).sorted())")
    }

    let now = Date(timeIntervalSince1970: 1_900_000_000)
    var rows: [String] = []
    for state in states {
        let snapshot = AgentTileTurnSnapshot(
            state: state,
            capabilities: .sendStop(canSend: true, canStop: true),
            turnStartedAt: now.addingTimeInterval(-30)
        )
        let mine = InboxState.state(forSnapshot: snapshot)
        let presented = AgentTileStatePresenter.present(
            name: "Agreement",
            snapshot: snapshot,
            branchContext: nil,
            startedAt: now.addingTimeInterval(-30),
            now: now
        )
        // The tile's fold, given everything the tile knows — including WHICH request
        // is open, which is a fact the presenter holds but does not put in its status.
        var pending: PendingRequest?
        if case let .needsAction(request) = state { pending = request.kind }
        let theirs = AgentInboxRow.state(for: presented.status, pending: pending)
        let isTheDivergence = snapshot.state.kindName == "failed"
        if isTheDivergence {
            guard mine == .failed, theirs == .ready else {
                throw fail("presenter-agreement: the ONE named divergence is gone — a failed turn reads row \(mine.rawValue) / tile-fold \(theirs.rawValue). If the presenter started carrying failure in its status this exception must be deleted, not kept as a lie")
            }
        } else {
            guard mine == theirs else {
                throw fail("presenter-agreement: \(snapshot.state.kindName) reads \(mine.rawValue) on the row and \(theirs.rawValue) through the tile's presentation — two surfaces telling a human different things about one agent")
            }
        }
        rows.append("\(snapshot.state.kindName)=\(mine.rawValue)\(isTheDivergence ? "(tile \(theirs.rawValue), documented)" : "")")
    }

    // The elapsed anchor is the snapshot's, on both surfaces.
    let working = AgentTileTurnSnapshot(
        state: .working,
        capabilities: .sendStop(canSend: false, canStop: true),
        turnStartedAt: now.addingTimeInterval(-30)
    )
    let workingPresentation = AgentTileStatePresenter.present(
        name: "Agreement", snapshot: working, branchContext: nil,
        startedAt: working.turnStartedAt, now: now
    )
    guard workingPresentation.elapsedSeconds == 30 else {
        throw fail("presenter-agreement: the tile header measures \(String(describing: workingPresentation.elapsedSeconds))s from the stamped turn start, expected 30")
    }
    return "row/tile state agreement over \(states.count) snapshots (\(rows.joined(separator: ", "))), one documented divergence, 30s elapsed from the stamped start on both surfaces"
}

// MARK: - P3.2 · no surface may list managed records ungated
//
// The behavioural half of the gate is a compile-time fact inside Core
// (`reconciledRecords(_:)` needs a `Proof` nothing outside Core can mint), and
// `ManagedAgentSessionStore.loadAll()` stays public for Core's own reader and the
// store's round-trip check. This scan is what keeps the app target off it: an
// unreviewed `managedSessionStore.loadAll()` in `ContinuumApp.swift` would restore
// exactly the ungated listing P3.2 removed, and it would do it silently.
//
// It also pins the two swallowed reads out of existence: `(try? …) ?? []` around a
// listing turns a refusal into "no agents", which is the bug in its quietest form.
func checkManagedSessionReadGateSources() throws -> String {
    struct ScanError: Error, CustomStringConvertible { let description: String }
    let path = "Sources/ContinuumRevived/App/ContinuumApp.swift"
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(path)
    guard let source = try? String(contentsOf: url, encoding: .utf8) else {
        throw ScanError(description: "could not read \(path) — run this check from the repo root")
    }
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var offenders: [String] = []
    for (index, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("//") else { continue }
        if trimmed.contains("managedSessionStore.loadAll()") {
            offenders.append("\(index + 1): ungated listing read — \(trimmed)")
        }
        if trimmed.contains("reconciledRecords"), trimmed.contains("try?") {
            offenders.append("\(index + 1): a swallowed listing read reports 'no agents' for a refusal — \(trimmed)")
        }
        if trimmed.contains("reconciledManagedSessionSource.records"), trimmed.contains("try?") {
            offenders.append("\(index + 1): a swallowed listing read reports 'no agents' for a refusal — \(trimmed)")
        }
    }
    guard offenders.isEmpty else {
        throw ScanError(description: "P3.2: \(offenders.count) ungated or swallowed managed-session listing read(s) in \(path):\n" + offenders.joined(separator: "\n"))
    }
    // Vacuity guard: the gated door must actually be in use, or an empty scan means
    // the app stopped listing agents rather than that it lists them safely.
    let gatedReads = lines.filter { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.hasPrefix("//")
            && (trimmed.contains("reconciledRecords(") || trimmed.contains("reconciledManagedSessionSource.records("))
    }
    guard !gatedReads.isEmpty else {
        throw ScanError(description: "P3.2: \(path) contains no gated listing read at all, so the scan above passed vacuously")
    }
    return "managed-session read gate: 0 ungated/swallowed listing reads in ContinuumApp.swift, \(gatedReads.count) gated reads present"
}

import ContinuumRevivedAgentUI
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P2B.1-agent-inventory.md
//
// ONE DERIVATION OF "EVERY AGENT", NOT FOUR.
//
// The union of terminal sessions and managed agents existed in exactly one
// place, momentarily, inside the companion-sync closure:
// `DegradedDesktopActivitySnapshotSource.snapshot(...)` in
// `ContinuumRevivedSync`. The sidebar, the badges, the dock and the phone each
// re-derived their own version of it. This is that fold promoted to an
// app-lifetime value in Core, where the desktop can read it too — a PROMOTION,
// not a rewrite: `DegradedDesktopActivitySnapshotSource` is now a thin caller.
// Stated precisely, because the stronger version of this claim is not proven:
// `DesktopCompanionSyncPublisherTests` was deliberately NOT touched and still
// pins the companion payload's keys, statuses, summaries, tile hints, timeline
// order and I5 sweep — that is field-level equivalence on the fixtures it
// covers, not a byte-diff against the old implementation, which no longer
// exists to diff against.
//
// It folds with the EXISTING `apply(_:_:)` from `AgentActivityEvent.swift`.
// A second fold here would be a second definition of canonical order, and the
// phone folds the same events with the first one.
//
// I5 (sync-boundary purity): `ActivityLogSnapshot` crosses to the phone, and
// `AgentRecord` is host-bound (`cwd`, `worktreeBranch`). This function reads
// only `id`, `displayName`, `tileId` and `lastActivityAt` off a record —
// never a host path. `AgentInventoryChecks` witnesses that with the taint
// scanner over a record whose cwd and branch are deliberately distinctive.
public enum AgentInventory {
    /// Fold every agent the desktop knows about — terminal sessions and
    /// `AgentRecord`-backed agents, tiled or headless — into the one snapshot
    /// every consumer reads.
    ///
    /// `liveStatuses` is keyed by AGGREGATE IDENTITY, i.e. the same key
    /// `AgentActivityEvent.agentId` carries: `AgentRecord.id.rawValue` for an
    /// agent, and a terminal session's `tileId` (whose tile id IS its agent
    /// identity — it has no `AgentRecord`; see the note at the terminal loop).
    /// One keyspace, so a collision means the same agent, not two.
    public static func snapshot(
        terminalDescriptors: [TerminalSessionDescriptor],
        liveStatuses: [UUID: AgentStatus],
        agents: [AgentRecord],
        activityByAgent: [AgentID: [AgentActivityEventDraft]],
        replicaId: UUID,
        now: Date
    ) -> ActivityLogSnapshot {
        var snapshot = ActivityLogSnapshot.empty

        // Sequence numbers are assigned POSITIONALLY from a total order over the
        // input, not from a counter that happens to run in call order: the phone
        // folds on `(sequence, replicaId)`, so a non-deterministic assignment
        // would reorder its timeline between two publishes of identical state.
        let sortedDescriptors = terminalDescriptors.sorted { lhs, rhs in
            lhs.tileId.uuidString == rhs.tileId.uuidString
                ? lhs.id.uuidString < rhs.id.uuidString
                : lhs.tileId.uuidString < rhs.tileId.uuidString
        }
        for (offset, descriptor) in sortedDescriptors.enumerated() {
            let kind = descriptor.agentDescriptor?.agentKind ?? .shell
            let status = liveStatuses[descriptor.tileId] ?? descriptor.agentDescriptor?.status ?? .idle
            let event = AgentActivityEvent(
                stamping: AgentActivityEventDraft(
                    // A terminal session has no AgentRecord, so its tile id IS its
                    // agent identity here — the same equality P2A.8's legacy decode
                    // relies on. The tile hint is that same id, so "Show on canvas"
                    // keeps working for these rows.
                    agentId: descriptor.tileId,
                    tileId: descriptor.tileId,
                    runId: nil,
                    tone: status == .needsAttention ? .approval : .info,
                    kind: "desktop.degradedStatus",
                    status: status,
                    summary: safeSummary(name: displayName(for: kind), status: status),
                    occurredAt: descriptor.agentDescriptor?.statusUpdatedAt ?? now
                ),
                sequence: UInt64(offset + 1),
                replicaId: replicaId
            )
            snapshot = apply(snapshot, event)
        }

        var sequence = UInt64(sortedDescriptors.count)
        // Sorted by identity, NOT by `AgentStore.isOrderedBefore` (most-recent
        // first): that order moves whenever an agent does anything, which would
        // renumber unrelated agents' events on the next publish.
        let sortedAgents = agents.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
        for record in sortedAgents {
            // `record.tileId == nil` is a HEADLESS agent (P2A.6). It needs no
            // special case — the tile is only ever the optional view hint here,
            // never the key — which is the whole point of P2A.8's migration.
            let recorded = activityByAgent[record.id] ?? []
            // Prefer the agent's real timeline; fall back to a single synthetic
            // status event when no events have been recorded yet.
            let drafts: [AgentActivityEventDraft] = recorded.isEmpty
                ? [syntheticStatusDraft(for: record, liveStatuses: liveStatuses)]
                // The record is the CURRENT view binding; a recorded draft carries
                // the binding it had when it was recorded. Publishing the draft's
                // would let an agent that has since detached keep advertising a
                // tile — the phone's "Show on canvas" pointing at a tile that no
                // longer renders it, which is exactly the identity-is-the-view bug
                // P2A.6/P2A.8 removed. Rebind, do not inherit.
                : recorded.map { rebound($0, toTile: record.tileId) }
            for draft in drafts {
                sequence += 1
                snapshot = apply(snapshot, AgentActivityEvent(stamping: draft, sequence: sequence, replicaId: replicaId))
            }
        }
        return snapshot
    }

    private static func rebound(_ draft: AgentActivityEventDraft, toTile tileId: UUID?) -> AgentActivityEventDraft {
        guard draft.tileId != tileId else { return draft }
        return AgentActivityEventDraft(
            agentId: draft.agentId,
            tileId: tileId,
            runId: draft.runId,
            tone: draft.tone,
            kind: draft.kind,
            status: draft.status,
            summary: draft.summary,
            occurredAt: draft.occurredAt,
            approvalRequestId: draft.approvalRequestId
        )
    }

    private static func syntheticStatusDraft(
        for record: AgentRecord,
        liveStatuses: [UUID: AgentStatus]
    ) -> AgentActivityEventDraft {
        let status = liveStatuses[record.id.rawValue] ?? .idle
        return AgentActivityEventDraft(
            agentId: record.id.rawValue,
            tileId: record.tileId,
            runId: nil,
            tone: status == .needsAttention ? .approval : .info,
            kind: "desktop.managedStatus",
            status: status,
            // The local record is host-bound and a prompt-derived display name
            // is prompt text. Only the boundary-safe projection crosses here —
            // never cwd, branch, or the raw prompt-derived title (I5).
            summary: safeSummary(name: record.syncDisplayName, status: status),
            occurredAt: record.lastActivityAt
        )
    }

    /// A summary that is a LABEL, never a transcript body (I5, enforced at
    /// `AgentActivityEvent`).
    public static func safeSummary(name: String, status: AgentStatus) -> String {
        // This is the existing timeline summary contract, whose lowercase
        // spelling is wire-compatible. Derive it from the same canonical word
        // as every rendered surface rather than maintaining a second table.
        "\(name) \(displayName(for: status).lowercased())"
    }

    public static func displayName(for kind: AgentKind) -> String {
        switch kind {
        case .shell: "Shell"
        case .claude: "Claude"
        case .codex: "Codex"
        case .pi: "Pi"
        case .managed: "Managed agent"
        case .unknown: "Agent"
        }
    }

    /// The phone summary carries the same status word as the chip, sidebar
    /// status projection and tile compatibility presentation. It remains a
    /// summary field; the phone payload schema is unchanged.
    public static func displayName(for status: AgentStatus) -> String {
        AgentStatusVocabulary.label(for: status)
    }
}

// Ticket: docs/38-tickets/90-agent-ux/P2B.2-cross-project-walk.md
//
// AGENTS ELSEWHERE ARE STILL AGENTS.
//
// `AgentStore` (P2A.2) is app-level, so agents created since it landed need no
// walk at all. LEGACY `ManagedAgentSessionRecord`s do: one JSON file per tile
// under each project's own `ProjectStoreLayout.managedSessionsDirectory`, and
// only `activeController.managedSessionStore` is reachable at runtime — so an
// agent in any other project is invisible to the inbox.
//
// This reads those files DIRECTLY. It does not open a `ZoneRuntimeController`
// per project: booting a runtime to list agents would start work as a side
// effect of looking, and observer-independence (P2B.8) says listing must need
// no live controller. `ManagedAgentSessionStore` is the same reader the active
// project already uses — a second decode path here would be a second definition
// of what a record is.
public final class CrossProjectManagedSessionWalk {
    /// A registry project entry, reduced to the two fields the walk needs. The
    /// project id travels with each record because the row context join (P2B.3)
    /// has no other way back to the project once the file is read.
    public struct Root: Hashable, Sendable {
        public let projectId: UUID
        public let projectRoot: URL

        public init(projectId: UUID, projectRoot: URL) {
            self.projectId = projectId
            self.projectRoot = projectRoot
        }
    }

    public struct Discovered: Equatable, Sendable {
        public let projectId: UUID
        public let record: ManagedAgentSessionRecord

        public init(projectId: UUID, record: ManagedAgentSessionRecord) {
            self.projectId = projectId
            self.record = record
        }
    }

    /// How long one read stays good. The inbox refreshes far more often than a
    /// project gains an agent, and every miss is a directory enumeration plus a
    /// decode per record across every project on the machine.
    private let ttl: TimeInterval
    private var cached: (roots: [Root], readAt: Date, found: [Discovered])?

    public init(ttl: TimeInterval = 2) {
        self.ttl = ttl
    }

    /// Every legacy managed-session record on disk, from every project root.
    ///
    /// A root that no longer exists is SKIPPED, not an error: `registry.projects`
    /// keeps entries for projects that have been moved or deleted, and an inbox
    /// that throws because one stale entry points at nothing would list nobody.
    ///
    /// P3.2: `proof` is the sweep's evidence, and it is required rather than
    /// advisory — `ManagedSessionReconciliation.Proof.init` is internal to Core, so
    /// a caller outside this module cannot compile a call to this function without
    /// having gone through `ReconciledManagedSessionSource`. THROWS now (it used to
    /// swallow): a listing that cannot be read must refuse, because the caller
    /// renders "which agents exist" from it and an empty answer is the "no agents"
    /// lie this ticket exists to remove.
    public func records(
        roots: [Root],
        now: Date,
        proof: ManagedSessionReconciliation.Proof
    ) throws -> [Discovered] {
        if let cached,
           cached.roots == roots,
           now >= cached.readAt,
           now.timeIntervalSince(cached.readAt) < ttl {
            return cached.found
        }

        var found: [Discovered] = []
        // Ordered by identity, not by registry order: the caller folds this into
        // `AgentInventory.snapshot`, whose sequence numbers are positional, so an
        // order that moved with the registry would renumber unrelated agents'
        // events between two publishes of identical state.
        var seenTiles: Set<UUID> = []
        for root in roots.sorted(by: { $0.projectId.uuidString < $1.projectId.uuidString }) {
            // An explicit early-out, not the only guard: `loadAll` also returns
            // [] for a directory that is not there. Named here because "a
            // registry entry may point at nothing" is a property of the input,
            // not an implementation detail of the reader.
            guard FileManager.default.fileExists(atPath: root.projectRoot.path) else { continue }
            let store = ManagedAgentSessionStore(projectRoot: root.projectRoot)
            let records = try store.reconciledRecords(proof)
            for record in records.sorted(by: { $0.tileId.uuidString < $1.tileId.uuidString })
            where seenTiles.insert(record.tileId).inserted {
                found.append(Discovered(projectId: root.projectId, record: record))
            }
        }
        cached = (roots, now, found)
        return found
    }
}

// Ticket: docs/38-tickets/94-sidebar-native-ux/P3.2-gated-snapshot-read.md
//
// A LISTING IS ONLY READABLE ONCE THE SWEEP HAS COMMITTED.
//
// P3.1 made a persisted record stop claiming liveness across a launch. That is
// only true of the roots the sweep actually visited, and a root is not a launch
// constant: `WorkspaceRuntime` opens a project's controller on a workspace switch
// (`WorkspaceRuntime.swift:540-566`), so a registry the app has never listed can
// gain a root minutes after boot. A sweep that ran once at launch would leave
// every other project's records saying `running` — the same lie, one project
// over. So reconciliation here is LAZY-ONCE-PER-ROOT: armed explicitly at boot,
// and any root first seen later is swept on the way in, exactly once.
//
// Two layers, deliberately different in kind:
//
//   * STRUCTURAL — `ManagedAgentSessionStore.reconciledRecords(_:)` takes a
//     `ManagedSessionReconciliation.Proof` whose `init` is internal to Core, and
//     this type is the only thing in Core that mints one for a listing. A reader
//     in the app target cannot compile an ungated listing read.
//   * BEHAVIOURAL — `records(roots:now:)` THROWS `NotReady` before arming rather
//     than returning `[]`. An empty listing is indistinguishable from "you have no
//     agents", which is the lie in a quieter form: it would blank the inbox and
//     publish an empty inventory to the phone. The refusal is a value the caller
//     must handle.
//
// Deliberately NOT an initializer side effect (design §5.15): a check or an
// observer-wiring fixture that constructs its own store must not have its records
// swept out from under it because something looked at them.
public final class ReconciledManagedSessionSource {
    /// The refusal. Carries what it knows so a log line can say why rather than
    /// "something went wrong": how many roots were asked for, and whether the
    /// process has swept anything at all yet.
    public struct NotReady: Error, CustomStringConvertible, Equatable {
        public let requestedRoots: Int
        public let sweptRoots: Int

        public var description: String {
            "managed-session listing refused: reconciliation has not committed yet"
                + " (\(sweptRoots) of \(requestedRoots) roots swept in this process)"
        }
    }

    /// What one sweep did, summed over the roots it visited. Per-record ids stay in
    /// `ManagedSessionReconciliation.Report`; a caller at this level wants counts
    /// for one log line.
    public struct SweepSummary: Equatable, Sendable {
        public let sweptRoots: Int
        public let alreadySweptRoots: Int
        public let scanned: Int
        public let terminalized: Int

        public init(sweptRoots: Int, alreadySweptRoots: Int, scanned: Int, terminalized: Int) {
            self.sweptRoots = sweptRoots
            self.alreadySweptRoots = alreadySweptRoots
            self.scanned = scanned
            self.terminalized = terminalized
        }
    }

    private let walk: CrossProjectManagedSessionWalk
    /// The reason a lazily-swept root is terminalized with. Set by the first
    /// `reconcile` call, which is also what ARMS this source: nil means nothing has
    /// swept anything, and every listing read refuses.
    private var armedReason: ManagedSessionEndReason?
    private var swept: Set<Root> = []

    public init(ttl: TimeInterval = 2) {
        self.walk = CrossProjectManagedSessionWalk(ttl: ttl)
    }

    /// True once a sweep has committed in this process. The inbox and the phone
    /// publish read this to tell "no agents" from "not yet".
    public var isReconciled: Bool { armedReason != nil }

    public func hasReconciled(_ root: Root) -> Bool { swept.contains(root) }

    public var sweptRootCount: Int { swept.count }

    /// The registry's projects as roots. One definition, so the boot sweep and the
    /// listing read cannot disagree about which roots exist — a root swept under one
    /// mapping and listed under another is the hole this closes.
    ///
    /// `missing` projects are NOT filtered out: a moved-away checkout may still hold
    /// records claiming liveness, and the walk skips a path that is not there anyway.
    public static func roots(in registry: Registry) -> [Root] {
        registry.projects.map { project in
            Root(projectId: project.id, projectRoot: URL(fileURLWithPath: project.rootPath, isDirectory: true))
        }
    }

    /// THE ONE ENTRY POINT (design §5.9). Boot and all twelve check call sites call
    /// this and nothing else, so no caller can open-code a different idea of which
    /// roots the registry contains — a root swept under one mapping and listed under
    /// another is an unswept listing with no symptom.
    @discardableResult
    public func reconcile(
        registry: Registry,
        reason: ManagedSessionEndReason,
        now: Date
    ) throws -> SweepSummary {
        try reconcile(roots: Self.roots(in: registry), reason: reason, now: now)
    }

    /// Sweep every root not yet swept in this process, and arm the source.
    ///
    /// Idempotent at two levels: a root already swept here is skipped without a
    /// disk read, and `ManagedSessionReconciliation` itself writes nothing for a
    /// record that is already terminal.
    @discardableResult
    public func reconcile(
        roots: [Root],
        reason: ManagedSessionEndReason,
        now: Date
    ) throws -> SweepSummary {
        if armedReason == nil { armedReason = reason }
        var sweptRoots = 0
        var alreadySweptRoots = 0
        var scanned = 0
        var terminalized = 0
        for root in roots.sorted(by: { $0.projectId.uuidString < $1.projectId.uuidString }) {
            guard !swept.contains(root) else {
                alreadySweptRoots += 1
                continue
            }
            // A root that is not on disk is SWEPT BY DEFINITION — there is nothing
            // to terminalize — and recorded as such, so a registry full of dead
            // entries cannot make every later read re-stat them.
            if FileManager.default.fileExists(atPath: root.projectRoot.path) {
                let (report, _) = try ManagedSessionReconciliation.reconcile(
                    store: ManagedAgentSessionStore(projectRoot: root.projectRoot),
                    reason: reason,
                    now: now
                )
                scanned += report.scanned
                terminalized += report.terminalized.count
            }
            swept.insert(root)
            sweptRoots += 1
        }
        return SweepSummary(
            sweptRoots: sweptRoots,
            alreadySweptRoots: alreadySweptRoots,
            scanned: scanned,
            terminalized: terminalized
        )
    }

    /// Every managed-session record on disk, from every root — refusing until the
    /// sweep has committed, and sweeping any root it has not seen before first.
    ///
    /// The lazy sweep runs BEFORE the walk reads, so the walk's TTL cache can only
    /// ever hold post-sweep records. Nothing is cached on the refusal path, which is
    /// what makes the first read after arming see the disk rather than an empty
    /// answer cached during the refusal.
    public func records(roots: [Root], now: Date) throws -> [Discovered] {
        guard let armedReason else {
            throw NotReady(requestedRoots: roots.count, sweptRoots: swept.count)
        }
        try reconcile(roots: roots, reason: armedReason, now: now)
        return try walk.records(roots: roots, now: now, proof: proof())
    }

    /// The sweep's evidence, for the one caller that owns its own store instance:
    /// the active project's live `ManagedAgentSessionStore`, which is the WRITER and
    /// so can never be staler than the files the walk reads. Refuses before arming,
    /// exactly as a listing does.
    public func proof() throws -> ManagedSessionReconciliation.Proof {
        guard armedReason != nil else {
            throw NotReady(requestedRoots: 0, sweptRoots: swept.count)
        }
        // Mintable here and nowhere outside Core: `Proof.init` is internal.
        return ManagedSessionReconciliation.Proof()
    }

    public typealias Root = CrossProjectManagedSessionWalk.Root
    public typealias Discovered = CrossProjectManagedSessionWalk.Discovered
}

// Ticket: docs/38-tickets/90-agent-ux/P2B.8-observer-independence.md
//
// LISTING AN AGENT MUST NOT NEED A LIVE OBSERVER.
//
// `ZoneRuntimeBudgetConfig.closeOnZero` defaults true, so releasing a project's
// last zone reference tears down its `ZoneRuntimeController` and with it that
// project's `SessionObserver`. An inbox that spans workspaces therefore hears
// from only the agents in the workspace you happen to be looking at.
//
// `AgentInventory.snapshot` above already has the right shape for that: every
// status reads `liveStatuses[…] ?? persisted`, so persisted state is the base
// truth and a live observer is an OVERLAY on the agents that happen to be
// observed. What was missing is the FACT that a given row came off disk alone —
// without it the UI presents a status nobody has confirmed for an hour exactly
// as it presents one from a second ago.
//
// This is a statement about OUR KNOWLEDGE, not about the agent, which is why it
// is not `AgentStatus.stale`: that one is a DERIVED AGENT STATE
// (`AgentStatusEngine`, 300s since the agent's last signal, on an agent we are
// watching). An agent can be perfectly busy and unobserved, or idle and
// observed. Conflating them would tell a human "this agent went quiet" when the
// truth is "we stopped listening".
//
// NO TIME THRESHOLD HERE, and that is a DELIBERATE DEVIATION from the packet's
// `## Approach` ("mark rows whose newest information is older than a threshold").
// Two reasons, both measured:
//   1. An age-based flag cannot satisfy the packet's own `## Verify` ("with
//      liveStatuses empty and only persisted records present … a staleness flag
//      set"). `ProjectStore.listSessions()` returns every descriptor through
//      `AgentDescriptor.restoredForBoot()`, which stamps `statusUpdatedAt = now`,
//      so a TERMINAL agent's persisted information always measures a second old no
//      matter how long ago anybody actually looked at it. Aging would silently
//      exempt every terminal agent — witnessed in
//      `--agent-observer-independence-check` as a measured age under any threshold.
//   2. The age is not lost by leaving it out: a consumer already has it, on
//      `AgentsBoardRow.updatedAt` / `AgentActivity.updatedAt`. A renderer that
//      wants a grace period ("do not repaint the inbox as suspect the instant you
//      switch workspaces") can hold "unobserved AND older than X" itself; a
//      renderer that wants the raw fact cannot recover it from a pre-thresholded
//      set. The narrower value goes in the model, the policy goes where it is
//      rendered (Phase 3/9), and this way the flag never LIES.
public enum AgentObservation {
    /// The agents in `snapshot` that nothing live is reporting.
    ///
    /// `observedAgentIds` is keyed by the same aggregate identity everything else
    /// here uses (`AgentRecord.id.rawValue`, or a terminal session's `tileId`).
    /// Membership means one thing: this agent's status in that snapshot came from a
    /// LIVE source — a rendering tile view, the runtime observer's map, a running
    /// supervised agent — rather than from a file. Absence is not an error; it is
    /// the normal state of every agent in a workspace you are not looking at.
    ///
    /// The arithmetic is a set difference; the DEFINITION is the deliverable — one
    /// place that says what "we have no observer for this" means, so the desktop and
    /// the inbox cannot each decide for themselves.
    ///
    /// PURE: no disk, no controller, no `AgentStore`. Starting a controller to
    /// freshen the data is the trap this ticket exists to avoid — that would make
    /// looking at the inbox start work.
    public static func unobservedAgentIds(
        in snapshot: ActivityLogSnapshot,
        observedAgentIds: Set<UUID>
    ) -> Set<UUID> {
        Set(snapshot.byAgent.keys).subtracting(observedAgentIds)
    }
}

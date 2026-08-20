import ContinuumRevivedAgentUI
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P3.1-inbox-row-model.md
//
// THE JOIN: `ActivityLogSnapshot` + `AgentContextIndex` → `[AgentInboxRow]`.
//
// It lives in Core rather than beside `AgentInboxRow` because
// ContinuumRevivedAgentUI may not import Core (P1.1: the direction is enforced by
// the compiler), and `AgentsBoardRow` / `AgentRowContext` are Core types. The
// vocabulary is in the shared module so iOS can have it; only this thin fold —
// which reads Core types and nothing else — is desktop-side.
//
// NOTHING IS RE-DERIVED HERE. Status comes from `AgentsBoardProjection`, context
// from `AgentContextIndex`, and the branch rule is the one `BranchChipNSView`
// already ships. This fold picks fields and computes one thing: `elapsed`.
//
// PURE (P2B.8, observer-independence): names and timestamps in, values out. No
// controller, no disk, no clock — `now` is a parameter, because a row is built at
// render time and `elapsed` must be measured against the caller's frame, not
// against whenever this function happened to run.
// Ticket: docs/38-tickets/94-sidebar-native-ux/P3.3-single-status-owner.md
//
// ONE OWNER ANSWERS WHAT AN AGENT IS DOING, and this is the mapping.
//
// PLACEMENT (design C2): `InboxState` lives in ContinuumRevivedAgentUI, which is
// compiler-forbidden from importing Core (`AgentInboxRow.swift:12-17`), and
// `AgentTileTurnSnapshot` is a Core type. So the mapping cannot live beside the
// vocabulary; it lives here, beside the join that uses it, as an extension on the
// vocabulary's own type. That is the same call P1.1 made when it moved
// `AgentStatus` into the shared module, and it introduces no new dependency edge.
//
// TOTAL, WITH NO `default` — the packet's "a new snapshot state without a row
// meaning is a compile error". `AgentTileOperationalState` carries associated
// values so it cannot be `CaseIterable`; the exhaustiveness gate is therefore this
// switch plus `AgentTileOperationalState.kindName`'s hand-listed table and the
// count assertion over it in `runAgentInboxRowBuilderChecks`.
public extension InboxState {
    /// The row's state for an agent the supervisor is reporting a turn for.
    ///
    /// `.queued` folds onto `.working` because a queued prompt is work in motion
    /// from the human's side and a sixth row state is what the vocabulary exists to
    /// forbid. `.restored` folds onto `.ready`: a restored agent is waiting on you,
    /// and "we adopted this record at boot" is a fact about our knowledge, not about
    /// the agent (the same distinction `AgentObservation` draws) — the inbox carries
    /// it as `unobservedAgentIds`, not as a status.
    ///
    /// `.failed` maps to `.failed`, which is the first thing in the program that
    /// makes that state REACHABLE (§5.11): no `AgentStatus` records failure, so
    /// `InboxState.state(for:pending:)` could never produce it. It has been
    /// coloured, labelled and token-gated on every surface since P1.3, waiting for
    /// exactly this fact.
    static func state(forSnapshot snapshot: AgentTileTurnSnapshot) -> InboxState {
        switch snapshot.state {
        case .ready: return .ready
        case .working: return .working
        case .queued: return .working
        case .needsAction(let request):
            switch request.kind {
            case .approval: return .approval
            case .input: return .input
            }
        case .failed: return .failed
        case .restored: return .ready
        }
    }
}

public enum AgentInboxRowBuilder {
    /// Rows for every agent in the snapshot, in the order
    /// `AgentsBoardProjection.rows` returns them.
    ///
    /// That order is attention-first, which is the phone's. The desktop's frozen
    /// creation order is P3.4's `sortForInbox`, deliberately a separate step: this
    /// ticket builds rows, it does not rank them.
    ///
    /// P3.6: `attention` is the desktop's read-state, keyed the same way. It is a
    /// PARAMETER and not something this fold can look up — the axis lives in
    /// `AgentSupervisor` (P3.3: "local, and deliberately not durable or synced"),
    /// which is an App-layer object Core may not reach, and P3.3 says in as many
    /// words that "the value is fed to rows from the desktop side when that list
    /// exists". This is that list existing. An agent with no entry reads `.none`,
    /// which is what a caller with no read-state (the phone, a fixture) gets.
    /// P3.3: `turnSnapshots` is the supervisor's turn state, keyed by the same
    /// aggregate identity every row is keyed by. An agent with an entry takes its
    /// state from it and from nothing else; the ring-derived fold below is the
    /// fallback for a caller that has no supervisor (the phone, a fixture) — and
    /// through the app it is unreachable, because every id in `records` has a
    /// snapshot (`AgentSupervisor.turnSnapshot` returns one for every record it
    /// holds) and the row source IS `records.keys`. That is asserted at the app
    /// level as "every row has a snapshot", non-vacuously; the fallback itself is
    /// exercised by a Core fixture (§5.10).
    public static func rows(
        from snapshot: ActivityLogSnapshot,
        context: [UUID: AgentRowContext] = [:],
        attention: [UUID: InboxAttention] = [:],
        turnSnapshots: [UUID: AgentTileTurnSnapshot] = [:],
        records: [UUID: AgentRecord] = [:],
        lifecycleFacts: [UUID: AgentLifecycleFacts] = [:],
        autoSettleAfter: TimeInterval? = nil,
        now: Date
    ) -> [AgentInboxRow] {
        let boardRows = AgentsBoardProjection.rows(from: snapshot, context: context)
        // Child rollups must be known before a parked parent's lifecycle is
        // resolved. Build an all-active provisional list solely to let the
        // existing `ChildRollup`/`InboxSort` fold see the parent links; using the
        // final lifecycle here would move a settled parent into history before
        // its descendant could hold it open.
        let childBlockers = descendantBlockers(
            in: boardRows,
            attention: attention,
            turnSnapshots: turnSnapshots,
            lifecycleFacts: lifecycleFacts,
            now: now
        )
        return boardRows.map { boardRow in
            var facts = lifecycleFacts[boardRow.agentId] ?? AgentLifecycleFacts()
            facts.descendantBlockers = facts.descendantBlockers.includingDescendants([
                childBlockers[boardRow.agentId] ?? .unblocked
            ])
            return row(
                from: boardRow,
                attention: attention[boardRow.agentId] ?? .none,
                turnSnapshot: turnSnapshots[boardRow.agentId],
                record: records[boardRow.agentId],
                lifecycleFacts: facts,
                autoSettleAfter: autoSettleAfter,
                now: now
            )
        }
    }

    public static func row(
        from boardRow: AgentsBoardRow,
        attention: InboxAttention = .none,
        turnSnapshot: AgentTileTurnSnapshot? = nil,
        record: AgentRecord? = nil,
        lifecycleFacts: AgentLifecycleFacts = AgentLifecycleFacts(),
        autoSettleAfter: TimeInterval? = nil,
        now: Date
    ) -> AgentInboxRow {
        let context = boardRow.context
        // P3.3: ONE OWNER. The supervisor's turn snapshot answers what the agent is
        // doing; the event ring below answers only for a caller that has no
        // supervisor to ask. The arm in which a stamped activity draft outranked the
        // derivation is GONE — drafts supply the timeline, never the status.
        //
        // P3.2 (queue 90): the fallback's status alone cannot say WHICH of the two
        // things a `needsAttention` agent wants, so the ring's pending request still
        // outranks it there. Once a supervisor snapshot exists, the ring is timeline
        // evidence only and cannot supply a second status/blocker opinion.
        let pending = turnSnapshot == nil
            ? AgentsBoardProjection.pendingRequest(in: boardRow.recent)
            : nil
        let state = turnSnapshot.map(InboxState.state(forSnapshot:))
            ?? AgentInboxRow.state(for: boardRow.status, pending: pending)
        // Lifecycle is a read-time projection of raw record fields. Compose the
        // one blocker list here from live observations; it is then consumed by
        // `AgentRecord.lifecycle` and `AgentRecord.canSettle`, never persisted.
        var observedFacts = lifecycleFacts
        // Unread is a read-state mark, not an activity blocker. Only a pending
        // human request belongs in this fact; otherwise a finished-but-unseen
        // row can never be settled. A supervisor snapshot's needsAction state is
        // the authoritative equivalent and is handled below.
        observedFacts.attentionIsYours = observedFacts.attentionIsYours
            || pending != nil
        if let turnSnapshot {
            switch turnSnapshot.state {
            case .working, .queued: observedFacts.hasLiveRunner = true
            case .needsAction: observedFacts.attentionIsYours = true
            case .ready, .failed, .restored: break
            }
        }
        // P6.4: durable completion/wake stamps are the record-backed attention
        // source. Keep the caller's value as a compatibility/live overlay (it is
        // still needed for terminal rows and deterministic fixtures), but never
        // let it erase a persisted mark.
        let hasPendingHuman = observedFacts.attentionIsYours
        let recordAttention = record?.attention(now: now, pending: hasPendingHuman) ?? .none
        let resolvedAttention: InboxAttention
        if record == nil {
            resolvedAttention = attention
        } else {
            resolvedAttention = InboxAttention.resolve(
                unread: attention == .unread || recordAttention == .unread,
                raisedHand: attention == .woke || recordAttention == .woke)
        }
        // Terminal sessions and legacy callers without a record retain the active
        // default; they have no persisted lifecycle facts to reinterpret here.
        let lifecycle = record?.lifecycle(
            facts: observedFacts,
            autoSettleAfter: autoSettleAfter,
            now: now
        ) ?? .active
        return AgentInboxRow(
            id: boardRow.agentId,
            title: title(for: context),
            projectName: context?.projectName,
            projectId: context?.projectId,
            directoryName: context?.directoryName,
            // P3.8: the scope dropdown filters by project OR workspace, and the
            // filter is pure, so the row has to carry the name. Nothing draws it.
            workspaceName: context?.workspaceName,
            state: state,
            // P3.3/P6.4 own read-state. It is local desktop state stored beside
            // the agent record; the compatibility argument cannot erase a newer
            // durable completion or wake signal.
            attention: resolvedAttention,
            lifecycle: lifecycle,
            model: context?.model,
            role: context?.role,
            branch: branch(for: context),
            isIsolated: context?.isIsolated ?? false,
            // P3.3: anchored to STAMPED WORK when the owner stamped some. The ring
            // scan below is the fallback, and it is the 158h bug when it is the only
            // input: a restored agent's ring holds one synthetic draft stamped
            // `record.lastSeenAt`, so the "current working run" starts at the spawn
            // instant however recent the actual prompt was.
            elapsed: elapsed(state: state, turnSnapshot: turnSnapshot, boardRow: boardRow, now: now),
            elapsedStartedAt: elapsedStart(
                state: state, turnSnapshot: turnSnapshot, boardRow: boardRow),
            // P6.5 uses the board's canonical latest event stamp only to choose
            // which children survive a bounded inline fan-out. It never reaches
            // the desktop's global frozen comparator.
            lastActiveAt: boardRow.updatedAt,
            // P2D.4 nests children under their parent, and assigns the depth in
            // `InboxSort` — depth is a property of the row's place in a LIST and
            // this fold sees one agent at a time. `parentId` below is the fact it
            // CAN carry; 0 here is the value that sort overwrites.
            depth: 0,
            variant: RowVariant.forLifecycle(lifecycle),
            // P3.4's frozen order. `distantPast` when the caller passed no context
            // — such a row sinks to the BOTTOM of the list rather than claiming to
            // be the newest thing you spawned, which is what a `now` fallback would
            // do. The index itself always knows the date (both a record and a
            // terminal descriptor carry one), so this fallback is for a caller that
            // built rows with no context at all.
            createdAt: context?.createdAt ?? .distantPast,
            parentId: context?.parentId,
            settlementBlocked: observedFacts.blocksSettlement(now: now),
            // §4.3's tooltip half. `branch(for:)` above collapses the two branches
            // into the one the row prints; the card needs to know when they
            // DISAGREE, which that collapse deliberately hides.
            zoneName: context?.zoneName,
            harness: context?.harness,
            checkedOutBranch: mismatchedCheckout(for: context),
            terminalEvent: record?.latestTerminalEvent,
            terminalIsUnread: record.map {
                ($0.latestTerminalEvent?.sequence ?? 0) > $0.acknowledgedTerminalSequence
            } ?? false
        )
    }

    /// Translate the existing child rollup's two hold-open states into the same
    /// blocker set the parent lifecycle and settle action consume. Failed and
    /// ready descendants remain visible in the rollup but do not block.
    private static func descendantBlockers(
        in boardRows: [AgentsBoardRow],
        attention: [UUID: InboxAttention],
        turnSnapshots: [UUID: AgentTileTurnSnapshot],
        lifecycleFacts: [UUID: AgentLifecycleFacts],
        now: Date
    ) -> [UUID: LifecycleBlockers] {
        let provisionalRows = boardRows.map { boardRow in
            row(
                from: boardRow,
                attention: attention[boardRow.agentId] ?? .none,
                turnSnapshot: turnSnapshots[boardRow.agentId],
                lifecycleFacts: lifecycleFacts[boardRow.agentId] ?? AgentLifecycleFacts(),
                now: now
            )
        }
        let sorted = InboxSort.sortForInbox(rows: provisionalRows)
        let rollups = InboxSort.rollups(in: sorted)
        return rollups.reduce(into: [UUID: LifecycleBlockers]()) { result, entry in
            guard entry.value.holdsParentOpen else { return }
            var blockers = LifecycleBlockers.unblocked
            if entry.value.needsYou > 0 { blockers.insert(.pendingInput) }
            if entry.value.working > 0 { blockers.insert(.sessionRunning) }
            result[entry.key] = blockers
        }
    }

    /// The agent's name, preferring the one the agent owns.
    ///
    /// `displayName` belongs to the `AgentRecord` and survives the tile being
    /// closed (the locked decision: the agent is the entity), so a headless agent
    /// still has a name. `tileTitle` is the fallback for a terminal session, which
    /// has no record and is named by its tile.
    private static func title(for context: AgentRowContext?) -> String {
        context?.displayName ?? context?.tileTitle ?? AgentInboxRow.untitled
    }

    /// The branch this agent's work actually lands on.
    ///
    /// Same rule as `BranchChipNSView.display`, so the tile chip and the inbox row
    /// cannot disagree: what is CHECKED OUT wins when the caller read it (that is
    /// where the commits go, mismatch or not), and the assigned `worktreeBranch`
    /// answers when it did not. nil means "not known", never "no branch".
    private static func branch(for context: AgentRowContext?) -> String? {
        context?.checkedOutBranch ?? context?.worktreeBranch
    }

    /// The checked-out branch, but ONLY when it disagrees with the agent's own.
    ///
    /// Carried nil when they agree, so the row's `isBranchMismatch` is a plain
    /// presence test and no surface has to re-derive the comparison. The context
    /// already computes the same predicate; this just refuses to carry a value
    /// that says nothing.
    private static func mismatchedCheckout(for context: AgentRowContext?) -> String? {
        guard let context, context.isBranchMismatch else { return nil }
        return context.checkedOutBranch
    }

    /// The row's elapsed reading, from the stamped turn start when there is one.
    ///
    /// Clamped at 0 for the same reason the ring scan is: a last-writer-wins merge
    /// can hand us a start from a host whose clock runs ahead, and a negative
    /// duration renders as a count-up backwards.
    ///
    /// nil when the owner reports no turn in flight — the snapshot is authoritative
    /// in BOTH directions, so an agent whose turn ended shows no clock even if the
    /// ring's trailing run still looks working. The ring is consulted only when
    /// there is no snapshot at all, and then only for a working row, exactly as
    /// before.
    private static func elapsed(
        state: InboxState,
        turnSnapshot: AgentTileTurnSnapshot?,
        boardRow: AgentsBoardRow,
        now: Date
    ) -> TimeInterval? {
        elapsedStart(state: state, turnSnapshot: turnSnapshot, boardRow: boardRow)
            .map { max(0, now.timeIntervalSince($0)) }
    }

    private static func elapsedStart(
        state: InboxState,
        turnSnapshot: AgentTileTurnSnapshot?,
        boardRow: AgentsBoardRow
    ) -> Date? {
        guard state == .working else { return nil }
        if let turnSnapshot { return turnSnapshot.turnStartedAt }
        return elapsedStart(in: boardRow)
    }

    /// How long the current working stretch has been running.
    ///
    /// Derived from the event ring, never stored: the start is the OLDEST event in
    /// the unbroken trailing run of events that are themselves `.working` in inbox
    /// terms. Scanning back to a state change rather than to the newest
    /// `turn.started` is deliberate — that kind is emitted only by
    /// `ManagedAgentActivityBridge`, so a terminal-session agent would never get a
    /// duration at all.
    ///
    /// nil when the ring holds no working event (an agent restored from disk with
    /// an empty ring has no measurable start) and clamped at 0, because a
    /// last-writer-wins merge can hand us an `occurredAt` from a host whose clock
    /// runs ahead, and a negative duration would render as a count-up backwards.
    private static func elapsedStart(in boardRow: AgentsBoardRow) -> Date? {
        var start: Date?
        for event in boardRow.recent.reversed() {
            guard AgentInboxRow.state(for: event.status) == .working else { break }
            start = event.occurredAt
        }
        return start
    }
}

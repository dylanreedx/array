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
    public static func rows(
        from snapshot: ActivityLogSnapshot,
        context: [UUID: AgentRowContext] = [:],
        attention: [UUID: InboxAttention] = [:],
        now: Date
    ) -> [AgentInboxRow] {
        AgentsBoardProjection.rows(from: snapshot, context: context)
            .map { row(from: $0, attention: attention[$0.agentId] ?? .none, now: now) }
    }

    public static func row(
        from boardRow: AgentsBoardRow,
        attention: InboxAttention = .none,
        now: Date
    ) -> AgentInboxRow {
        let context = boardRow.context
        // P3.2: the status alone cannot say WHICH of the two things a
        // `needsAttention` agent wants, and a pending request outranks the fold's
        // status. Both facts come from `AgentsBoardProjection`, which owns the
        // ring; this join still derives nothing of its own.
        let state = AgentInboxRow.state(
            for: boardRow.status,
            pending: AgentsBoardProjection.pendingRequest(in: boardRow.recent))
        // P4 populates these two; until it does, every agent is active and no row
        // is slim (`RowVariant.forLifecycle` is what keeps those two consistent —
        // a caller never picks a variant).
        let lifecycle = InboxLifecycle.active
        return AgentInboxRow(
            id: boardRow.agentId,
            title: title(for: context),
            projectName: context?.projectName,
            // P3.8: the scope dropdown filters by project OR workspace, and the
            // filter is pure, so the row has to carry the name. Nothing draws it.
            workspaceName: context?.workspaceName,
            state: state,
            // P3.3 owns read-state. It is local desktop state stored beside the
            // agent record, so it is not visible from a snapshot and cannot be
            // guessed from one — it arrives as an argument or not at all.
            attention: attention,
            lifecycle: lifecycle,
            model: context?.model,
            role: context?.role,
            branch: branch(for: context),
            isIsolated: context?.isIsolated ?? false,
            elapsed: state == .working ? elapsed(in: boardRow, now: now) : nil,
            // P2D.4 nests children under their parent. A flat list is depth 0.
            depth: 0,
            variant: RowVariant.forLifecycle(lifecycle),
            // P3.4's frozen order. `distantPast` when the caller passed no context
            // — such a row sinks to the BOTTOM of the list rather than claiming to
            // be the newest thing you spawned, which is what a `now` fallback would
            // do. The index itself always knows the date (both a record and a
            // terminal descriptor carry one), so this fallback is for a caller that
            // built rows with no context at all.
            createdAt: context?.createdAt ?? .distantPast,
            parentId: context?.parentId
        )
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
    private static func elapsed(in boardRow: AgentsBoardRow, now: Date) -> TimeInterval? {
        var start: Date?
        for event in boardRow.recent.reversed() {
            guard AgentInboxRow.state(for: event.status) == .working else { break }
            start = event.occurredAt
        }
        guard let start else { return nil }
        return max(0, now.timeIntervalSince(start))
    }
}

import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P3.1-inbox-row-model.md
//
// The JOIN: snapshot + context index → inbox rows. The vocabulary's own
// properties (status totality, identity, variant) are checked in
// ContinuumRevivedAgentUIChecks, which cannot see Core; these are the ones that
// need a real snapshot.
//
// Five properties:
//   1. COVERAGE + IDENTITY — one row per agent, and every row's `id` is the
//      agent identity `AgentsBoardRow`/`AgentsBoardChangeSet` use. The list
//      diffs on that key, so if it were the tile id a headless agent could not
//      be addressed at all.
//   2. STABILITY ACROSS REFRESHES — fold a new event in, rebuild, and every id
//      is the one it was. The rows change; the keys do not.
//   3. HEADLESS — an agent with no tile still has a name (from the record, not
//      from a tile it does not have), and reports no branch and no placement.
//   4. ELAPSED — measured from the START of the current working run, only while
//      working, never stored, clamped at 0.
//   5. BRANCH — the same precedence `BranchChipNSView.display` ships, so the
//      tile chip and the inbox row cannot name different branches.

func runAgentInboxRowBuilderChecks() {
    runInboxRowCoverageAndIdentityCheck()
    runInboxRowHeadlessCheck()
    runInboxRowTitleSourceAndTerminalCheck()
    runInboxRowElapsedCheck()
    runInboxRowBranchCheck()
    runInboxRowPendingRequestCheck()
    runInboxSortDivergesFromBoardOrderCheck()
    runInboxRowSnapshotIsTheOwnerCheck()
    runInboxRowStampedElapsedCheck()
    runInboxLifecycleDerivationCheck()
    print("AgentInboxRowBuilder checks: coverage/identity, refresh stability, headless rows, title source, terminal sessions, elapsed derivation, branch precedence, the approval/input split, the frozen-vs-attention-first sort divergence, P3.3's snapshot-owned state over all 6 operational kinds, the stamped elapsed anchor, and P6.1 lifecycle/action agreement passed")
}

// MARK: - Fixture

private let inboxNow = Date(timeIntervalSinceReferenceDate: 806_700_000)
private let inboxReplicaId = UUID(uuidString: "3B200000-0000-4000-8000-0000000000FF")!
private let inboxWorkspaceId = UUID(uuidString: "3B200000-0000-4000-8000-000000000001")!
private let inboxProjectId = UUID(uuidString: "3B200000-0000-4000-8000-000000000011")!
private let inboxHeadlessAgentId = AgentID(rawValue: UUID(uuidString: "3B200000-0000-4000-8000-000000000041")!)
private let inboxIsolatedAgentId = AgentID(rawValue: UUID(uuidString: "3B200000-0000-4000-8000-000000000042")!)
private let inboxTiledAgentId = AgentID(rawValue: UUID(uuidString: "3B200000-0000-4000-8000-000000000043")!)
private let inboxZoneId = UUID(uuidString: "3B200000-0000-4000-8000-000000000021")!
private let inboxTiledAgentTile = UUID(uuidString: "3B200000-0000-4000-8000-000000000031")!
private let inboxTerminalTile = UUID(uuidString: "3B200000-0000-4000-8000-000000000032")!

private func inboxRegistry() -> Registry {
    Registry(
        lastActiveWorkspaceId: nil,
        lastActiveProjectId: nil,
        workspaces: [
            WorkspaceEntry(id: inboxWorkspaceId, name: "Alpha", projectIds: [], createdAt: inboxNow, updatedAt: inboxNow),
        ],
        projects: [
            ProjectEntry(
                id: inboxProjectId,
                name: "Continuum",
                rootPath: "/tmp/continuum-inbox-fixture",
                workspaceId: inboxWorkspaceId,
                lastOpenedAt: inboxNow,
                pinned: false
            ),
        ],
        settings: RegistrySettings(preferredEditor: .auto, zoomModifier: .command, openLastProjectOnLaunch: true)
    )
}

/// Both agents are HEADLESS — no tile, so no workspace document and no canvas is
/// needed to place them. Placement itself is `AgentContextIndex`'s property and is
/// already gated in `AgentContextIndexChecks`; what this fixture needs is agents
/// whose rows exist without a view, which is the locked decision under test.
private func inboxAgents(worktreeBranch: String? = "agent/isolated-1a2b3c4d") -> [AgentRecord] {
    [
        AgentRecord(
            id: inboxHeadlessAgentId,
            displayName: "Headless Reviewer",
            role: "reviewer",
            model: "anthropic/claude-opus-5",
            thinking: "high",
            cwd: "/tmp/continuum-inbox-fixture",
            worktreeBranch: nil,
            projectId: inboxProjectId,
            createdAt: inboxNow,
            lastActivityAt: inboxNow,
            tileId: nil
        ),
        AgentRecord(
            id: inboxIsolatedAgentId,
            displayName: "Isolated Builder",
            role: "builder",
            model: "openai-codex/gpt-5.6-sol",
            thinking: "medium",
            cwd: "/tmp/continuum-inbox-fixture-worktree",
            worktreeBranch: worktreeBranch,
            projectId: inboxProjectId,
            createdAt: inboxNow,
            lastActivityAt: inboxNow,
            tileId: nil
        ),
    ]
}

/// A managed agent WITH a tile, whose record and tile disagree about its name.
private func inboxTiledAgent() -> AgentRecord {
    AgentRecord(
        id: inboxTiledAgentId,
        displayName: "Record Name",
        role: nil,
        model: "anthropic/claude-opus-5",
        thinking: "medium",
        cwd: "/tmp/continuum-inbox-fixture",
        worktreeBranch: nil,
        projectId: inboxProjectId,
        createdAt: inboxNow,
        lastActivityAt: inboxNow,
        tileId: inboxTiledAgentTile
    )
}

/// A terminal session — no `AgentRecord`, so its tile id is its agent identity.
private func inboxTerminalDescriptor() -> TerminalSessionDescriptor {
    TerminalSessionDescriptor(
        id: UUID(uuidString: "3B200000-0000-4000-8000-000000000051")!,
        tileId: inboxTerminalTile,
        launchProfileId: "default",
        command: "/bin/zsh",
        args: [],
        cwd: "/tmp/continuum-inbox-fixture",
        env: [:],
        title: "descriptor title",
        createdAt: inboxNow,
        lastStartedAt: inboxNow,
        lastExit: nil,
        agentDescriptor: AgentDescriptor(agentKind: .claude, worktreePath: nil, status: .idle, statusUpdatedAt: inboxNow)
    )
}

/// One group zone holding both tiles, so `AgentContextIndex` can place them
/// through `SidebarTreeBuilder` exactly as it does in production.
private func inboxDocuments() -> [UUID: WorkspaceDocument] {
    let zone = ZonePlacement(
        zoneId: inboxZoneId,
        projectId: nil,
        origin: ZonePoint(x: 0, y: 0),
        size: ZoneSize(width: 100, height: 100),
        color: "blue",
        collapsed: false,
        hydrationPolicy: .automatic,
        name: "Scratch",
        navKey: nil
    )
    func tile(_ id: UUID, _ title: String, x: Double, y: Double) -> Tile {
        Tile(
            id: id,
            kind: .terminal,
            title: title,
            frame: TileFrame(x: x, y: y, width: 20, height: 20),
            zPosition: .fromLegacyRank(1),
            runtimeRef: nil,
            metadata: TileMetadata()
        ).with(zoneId: inboxZoneId)
    }
    return [
        inboxWorkspaceId: WorkspaceDocument(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            zones: [zone],
            zoneZOrder: [inboxZoneId],
            lastActiveZoneId: nil,
            ambientTiles: [
                tile(inboxTiledAgentTile, "Tile Name", x: 10, y: 10),
                tile(inboxTerminalTile, "Scratch Shell", x: 50, y: 50),
            ]
        ),
    ]
}

private func inboxIndex(
    agents: [AgentRecord]? = nil,
    checkedOutBranches: [UUID: String] = [:]
) -> [UUID: AgentRowContext] {
    AgentContextIndex.build(
        registry: inboxRegistry(),
        documents: [:],
        projectCanvases: [:],
        terminalDescriptors: [],
        agents: agents ?? inboxAgents(),
        checkedOutBranches: checkedOutBranches
    )
}

private func inboxSnapshot(
    agents: [AgentRecord]? = nil,
    liveStatuses: [UUID: AgentStatus] = [:],
    activityByAgent: [AgentID: [AgentActivityEventDraft]] = [:]
) -> ActivityLogSnapshot {
    AgentInventory.snapshot(
        terminalDescriptors: [],
        liveStatuses: liveStatuses,
        agents: agents ?? inboxAgents(),
        activityByAgent: activityByAgent,
        replicaId: inboxReplicaId,
        now: inboxNow
    )
}

private func inboxDraft(
    _ agentId: AgentID,
    status: AgentStatus,
    kind: String,
    secondsAfterStart: TimeInterval
) -> AgentActivityEventDraft {
    AgentActivityEventDraft(
        agentId: agentId.rawValue,
        tileId: nil,
        runId: nil,
        tone: status == .needsAttention ? .approval : .info,
        kind: kind,
        status: status,
        summary: AgentInventory.safeSummary(name: "Isolated Builder", status: status),
        occurredAt: inboxNow.addingTimeInterval(secondsAfterStart)
    )
}

// MARK: - 1 & 2 · coverage, identity, refresh stability

private func runInboxRowCoverageAndIdentityCheck() {
    let snapshot = inboxSnapshot()
    let index = inboxIndex()
    let rows = AgentInboxRowBuilder.rows(from: snapshot, context: index, now: inboxNow)

    expect(rows.count == 2, "one inbox row per agent, got \(rows.count)")
    let boardRows = AgentsBoardProjection.rows(from: snapshot, context: index)
    expect(rows.map(\.id) == boardRows.map(\.id),
           "an inbox row's id IS the board row's agent identity, in the same order — got \(rows.map(\.id)) vs \(boardRows.map(\.id))")
    expect(Set(rows.map(\.id)) == Set([inboxHeadlessAgentId.rawValue, inboxIsolatedAgentId.rawValue]),
           "the ids are the agent ids, not tile ids (both agents are headless and have none), got \(Set(rows.map(\.id)))")

    // 2 · a refresh: fold one more event in and rebuild. Row CONTENT moves; the
    // keys the list diffs on do not.
    let moved = AgentsBoardProjection.appendLocal(
        inboxDraft(inboxIsolatedAgentId, status: .needsAttention, kind: "needs-attention", secondsAfterStart: 30),
        to: snapshot,
        replicaId: inboxReplicaId
    )
    let refreshed = AgentInboxRowBuilder.rows(from: moved, context: index, now: inboxNow.addingTimeInterval(60))
    expect(Set(refreshed.map(\.id)) == Set(rows.map(\.id)),
           "every row keeps its id across a refresh, got \(Set(refreshed.map(\.id))) vs \(Set(rows.map(\.id)))")
    let refreshedById = Dictionary(uniqueKeysWithValues: refreshed.map { ($0.id, $0) })
    // `.input`, not `.approval`: `inboxDraft` carries no `approvalRequestId`, so
    // P3.2's split reads this needs-attention event as a plain question. The
    // property under test is unchanged — the row really did move state.
    expect(refreshedById[inboxIsolatedAgentId.rawValue]?.state == .input,
           "the refreshed row really did change state — otherwise stability is vacuous, got \(String(describing: refreshedById[inboxIsolatedAgentId.rawValue]?.state))")

    // Determinism: the inbox rebuilds this on every frame.
    expect(AgentInboxRowBuilder.rows(from: snapshot, context: index, now: inboxNow) == rows,
           "AgentInboxRowBuilder.rows must be deterministic on identical inputs")
}

// MARK: - 3 · headless

private func runInboxRowHeadlessCheck() {
    let rows = AgentInboxRowBuilder.rows(from: inboxSnapshot(), context: inboxIndex(), now: inboxNow)
    guard let headless = rows.first(where: { $0.id == inboxHeadlessAgentId.rawValue }) else {
        fputs("FAIL: AgentInboxRowBuilder dropped the headless agent\n", stderr)
        Foundation.exit(1)
    }
    // The locked decision, as a row: closing the tile did not close the agent, so
    // the agent's own name is still there to render.
    expect(headless.title == "Headless Reviewer",
           "a headless agent's title is its record's displayName, got \(headless.title)")
    expect(headless.projectName == "Continuum",
           "a headless agent still resolves its project from its record, got \(headless.projectName ?? "nil")")
    expect(headless.branch == nil && !headless.isIsolated,
           "a headless agent sharing the project checkout reports no branch, got \(headless.branch ?? "nil")")
    expect(headless.model == "anthropic/claude-opus-5" && headless.role == "reviewer",
           "a headless agent carries its model and role, got \(headless.model ?? "nil")/\(headless.role ?? "nil")")
    expect(headless.state == .ready && headless.elapsed == nil,
           "an idle agent is at rest with no duration, got \(headless.state.rawValue)/\(String(describing: headless.elapsed))")
    expect(headless.lifecycle == .active && headless.variant == .card && headless.depth == 0 && headless.attention == .none,
           "a fresh neutral record with no blocker or settle window derives an active top-level card, got \(headless)")

    // No index at all — the fixture caller, and the path a consumer takes before
    // it has built one. The row still exists and still renders a name.
    let unjoined = AgentInboxRowBuilder.rows(from: inboxSnapshot(), now: inboxNow)
    expect(unjoined.count == 2, "rows are built with no context index at all, got \(unjoined.count)")
    expect(unjoined.allSatisfy { $0.title == AgentInboxRow.untitled },
           "with no context there is no name to show, so the row says \(AgentInboxRow.untitled) rather than rendering a blank line — got \(unjoined.map(\.title))")
    expect(unjoined.map(\.id) == AgentInboxRowBuilder.rows(from: inboxSnapshot(), context: inboxIndex(), now: inboxNow).map(\.id),
           "joining context must not change row identity or order")
}

// MARK: - 3b · where a title comes from, and a terminal session's row

/// The discriminating case for "the title is the AGENT's name": a managed agent
/// whose record and whose tile are named DIFFERENTLY. Both sources are present, so
/// preferring the wrong one cannot pass — which the headless case above cannot
/// show, since a headless agent has no tile title to prefer.
///
/// And the other half of the list: a TERMINAL SESSION, which has no `AgentRecord`
/// at all. Its tile id is its agent identity, its tile is its name, and it has
/// no model, no role and no branch of its own. Half of a real inbox is these; a
/// fixture of managed agents only would not notice a builder that required a
/// record.
private func runInboxRowTitleSourceAndTerminalCheck() {
    let agents = inboxAgents() + [inboxTiledAgent()]
    let descriptors = [inboxTerminalDescriptor()]
    let index = AgentContextIndex.build(
        registry: inboxRegistry(),
        documents: inboxDocuments(),
        projectCanvases: [:],
        terminalDescriptors: descriptors,
        agents: agents
    )
    let snapshot = AgentInventory.snapshot(
        terminalDescriptors: descriptors,
        liveStatuses: [:],
        agents: agents,
        activityByAgent: [:],
        replicaId: inboxReplicaId,
        now: inboxNow
    )
    let rows = AgentInboxRowBuilder.rows(from: snapshot, context: index, now: inboxNow)
    expect(rows.count == 4, "3 records + 1 terminal session make 4 rows, got \(rows.count)")

    guard let tiled = rows.first(where: { $0.id == inboxTiledAgentId.rawValue }) else {
        fputs("FAIL: AgentInboxRowBuilder dropped the tiled agent\n", stderr)
        Foundation.exit(1)
    }
    expect(index[inboxTiledAgentId.rawValue]?.tileTitle == "Tile Name",
           "fixture check: the tiled agent really does have a DIFFERENT tile title to prefer, got \(index[inboxTiledAgentId.rawValue]?.tileTitle ?? "nil")")
    expect(tiled.title == "Record Name",
           "a tiled agent's title is its record's name, not its tile's — got \(tiled.title)")

    guard let terminal = rows.first(where: { $0.id == inboxTerminalTile }) else {
        fputs("FAIL: AgentInboxRowBuilder dropped the terminal session\n", stderr)
        Foundation.exit(1)
    }
    expect(terminal.title == "Scratch Shell",
           "a terminal session has no record, so its tile names it — got \(terminal.title)")
    expect(terminal.model == nil && terminal.role == nil && terminal.branch == nil && !terminal.isIsolated,
           "a terminal session has no model, role or branch of its own, got \(terminal)")
    expect(terminal.state == .ready && terminal.elapsed == nil,
           "an idle terminal session is at rest, got \(terminal.state.rawValue)/\(String(describing: terminal.elapsed))")
    expect(terminal.projectName == nil,
           "the fixture's group zone has no project, so neither does its session — got \(terminal.projectName ?? "nil")")
}

// MARK: - 4 · elapsed

private func runInboxRowElapsedCheck() {
    // A working run that starts 100s before `now`, with two more working events
    // inside it: the duration is measured from the START of the run, not from the
    // newest event, or a long turn would report a few seconds forever.
    let working: [AgentActivityEventDraft] = [
        inboxDraft(inboxIsolatedAgentId, status: .idle, kind: "turn.completed", secondsAfterStart: -400),
        inboxDraft(inboxIsolatedAgentId, status: .working, kind: "turn.started", secondsAfterStart: -100),
        inboxDraft(inboxIsolatedAgentId, status: .working, kind: "tool.read", secondsAfterStart: -40),
        inboxDraft(inboxIsolatedAgentId, status: .working, kind: "tool.bash", secondsAfterStart: -5),
    ]
    let rows = AgentInboxRowBuilder.rows(
        from: inboxSnapshot(activityByAgent: [inboxIsolatedAgentId: working]),
        context: inboxIndex(),
        now: inboxNow
    )
    guard let row = rows.first(where: { $0.id == inboxIsolatedAgentId.rawValue }) else {
        fputs("FAIL: AgentInboxRowBuilder dropped the working agent\n", stderr)
        Foundation.exit(1)
    }
    expect(row.state == .working, "the fixture agent is working, got \(row.state.rawValue)")
    expect(row.elapsed == 100, "elapsed is measured from the start of the working run, got \(String(describing: row.elapsed))")

    // NOT STORED: the same snapshot, rendered a minute later, reports a minute
    // more. A stored value would report 100 twice.
    let later = AgentInboxRowBuilder.rows(
        from: inboxSnapshot(activityByAgent: [inboxIsolatedAgentId: working]),
        context: inboxIndex(),
        now: inboxNow.addingTimeInterval(60)
    ).first { $0.id == inboxIsolatedAgentId.rawValue }
    expect(later?.elapsed == 160, "elapsed is derived against the caller's clock at render time, got \(String(describing: later?.elapsed))")

    // An interrupted run: the approval in the middle ends the earlier stretch, so
    // the duration is measured from the event AFTER it.
    let interrupted: [AgentActivityEventDraft] = [
        inboxDraft(inboxIsolatedAgentId, status: .working, kind: "turn.started", secondsAfterStart: -900),
        inboxDraft(inboxIsolatedAgentId, status: .needsAttention, kind: "needs-attention", secondsAfterStart: -600),
        inboxDraft(inboxIsolatedAgentId, status: .working, kind: "turn.started", secondsAfterStart: -300),
    ]
    let resumed = AgentInboxRowBuilder.rows(
        from: inboxSnapshot(activityByAgent: [inboxIsolatedAgentId: interrupted]),
        context: inboxIndex(),
        now: inboxNow
    ).first { $0.id == inboxIsolatedAgentId.rawValue }
    expect(resumed?.elapsed == 300,
           "a working run is measured from where it resumed, not from the first one of the day, got \(String(describing: resumed?.elapsed))")

    // Not working: no duration, however many working events are in the ring.
    let stopped: [AgentActivityEventDraft] = working + [
        inboxDraft(inboxIsolatedAgentId, status: .done, kind: "turn.completed", secondsAfterStart: -1),
    ]
    let atRest = AgentInboxRowBuilder.rows(
        from: inboxSnapshot(activityByAgent: [inboxIsolatedAgentId: stopped]),
        context: inboxIndex(),
        now: inboxNow
    ).first { $0.id == inboxIsolatedAgentId.rawValue }
    expect(atRest?.state == .ready && atRest?.elapsed == nil,
           "elapsed is meaningful only while working, got \(String(describing: atRest?.state))/\(String(describing: atRest?.elapsed))")

    // A clock from the future: `apply` is a last-writer-wins merge over hosts, so
    // an `occurredAt` ahead of ours is reachable. It must read as 0, never as a
    // negative count-up.
    let ahead: [AgentActivityEventDraft] = [
        inboxDraft(inboxIsolatedAgentId, status: .working, kind: "turn.started", secondsAfterStart: 500),
    ]
    let future = AgentInboxRowBuilder.rows(
        from: inboxSnapshot(activityByAgent: [inboxIsolatedAgentId: ahead]),
        context: inboxIndex(),
        now: inboxNow
    ).first { $0.id == inboxIsolatedAgentId.rawValue }
    expect(future?.elapsed == 0, "an event stamped in the future clamps to 0, got \(String(describing: future?.elapsed))")

    print("AgentInboxRow elapsed measured run=\(String(describing: row.elapsed)) later=\(String(describing: later?.elapsed)) resumed=\(String(describing: resumed?.elapsed))")
}

// MARK: - 5 · branch

private func runInboxRowBranchCheck() {
    let assigned = "agent/isolated-1a2b3c4d"

    // Isolated, and the caller read the checkout: the two agree.
    let matching = AgentInboxRowBuilder.rows(
        from: inboxSnapshot(),
        context: inboxIndex(checkedOutBranches: [inboxIsolatedAgentId.rawValue: assigned]),
        now: inboxNow
    ).first { $0.id == inboxIsolatedAgentId.rawValue }
    expect(matching?.branch == assigned && matching?.isIsolated == true,
           "an isolated agent's row names its own branch, got \(matching?.branch ?? "nil")")

    // Isolated and wandered: the row names where the commits ACTUALLY land, which
    // is what `BranchChipNSView.display` shows for the same state.
    let wandered = AgentInboxRowBuilder.rows(
        from: inboxSnapshot(),
        context: inboxIndex(checkedOutBranches: [inboxIsolatedAgentId.rawValue: "main"]),
        now: inboxNow
    ).first { $0.id == inboxIsolatedAgentId.rawValue }
    expect(wandered?.branch == "main",
           "when the checkout disagrees with the assignment the row names the checkout, got \(wandered?.branch ?? "nil")")
    expect(wandered?.isIsolated == true,
           "an agent that wandered off its branch still has a checkout of its own")

    // Isolated, checkout never read: the assignment is all there is.
    let unread = AgentInboxRowBuilder.rows(from: inboxSnapshot(), context: inboxIndex(), now: inboxNow)
        .first { $0.id == inboxIsolatedAgentId.rawValue }
    expect(unread?.branch == assigned,
           "with no checkout lookup the row falls back to the assigned branch, got \(unread?.branch ?? "nil")")

    // Shared checkout, read: the project's branch, and not isolated.
    let shared = AgentInboxRowBuilder.rows(
        from: inboxSnapshot(),
        context: inboxIndex(checkedOutBranches: [inboxHeadlessAgentId.rawValue: "main"]),
        now: inboxNow
    ).first { $0.id == inboxHeadlessAgentId.rawValue }
    expect(shared?.branch == "main" && shared?.isIsolated == false,
           "a shared-checkout agent reports the branch it works on and is not isolated, got \(shared?.branch ?? "nil")")

    // Shared and unread: nothing is known, so nothing is claimed.
    let silent = AgentInboxRowBuilder.rows(from: inboxSnapshot(), context: inboxIndex(), now: inboxNow)
        .first { $0.id == inboxHeadlessAgentId.rawValue }
    expect(silent?.branch == nil,
           "a shared agent whose checkout was not read reports no branch, got \(silent?.branch ?? "nil")")
}

// MARK: - 6 · the approval/input split

// Ticket: docs/38-tickets/90-agent-ux/P3.2-five-states-three-colours.md
//
// The fact `AgentStatus` cannot carry, derived where the ring lives. The mapping
// itself (precedence, accents, the uncoloured resting state) is the vocabulary's
// and is checked in ContinuumRevivedAgentUIChecks; what needs a real snapshot is
// that the JOIN actually reaches both sides of the split and knows when nobody is
// waiting on anything.
private func runInboxRowPendingRequestCheck() {
    func pendingDraft(requestId: String?, secondsAfterStart: TimeInterval) -> AgentActivityEventDraft {
        AgentActivityEventDraft(
            agentId: inboxIsolatedAgentId.rawValue,
            tileId: nil,
            runId: nil,
            tone: .approval,
            kind: "needs-attention",
            status: .needsAttention,
            summary: AgentInventory.safeSummary(name: "Isolated Builder", status: .needsAttention),
            occurredAt: inboxNow.addingTimeInterval(secondsAfterStart),
            approvalRequestId: requestId
        )
    }

    func row(_ drafts: [AgentActivityEventDraft]) -> AgentInboxRow {
        let rows = AgentInboxRowBuilder.rows(
            from: inboxSnapshot(activityByAgent: [inboxIsolatedAgentId: drafts]),
            context: inboxIndex(),
            now: inboxNow
        )
        guard let row = rows.first(where: { $0.id == inboxIsolatedAgentId.rawValue }) else {
            fputs("FAIL: AgentInboxRowBuilder dropped the waiting agent\n", stderr)
            Foundation.exit(1)
        }
        return row
    }

    let working = inboxDraft(inboxIsolatedAgentId, status: .working, kind: "turn.started", secondsAfterStart: -100)

    // An adapter is holding a request open — there is something to APPROVE.
    let approving = row([working, pendingDraft(requestId: "req-7", secondsAfterStart: -10)])
    expect(approving.state == .approval,
           "a needs-attention event carrying a request id is an approval, got \(approving.state.rawValue)")

    // The agent asked you something with nothing to approve — INPUT. Same status,
    // same tone, same everything but the request id: this is the discriminating
    // pair, so a builder that ignored the split could not pass both.
    let asking = row([working, pendingDraft(requestId: nil, secondsAfterStart: -10)])
    expect(asking.state == .input,
           "a needs-attention event with no request id is a question, got \(asking.state.rawValue)")
    expect(approving.state != asking.state,
           "one AgentStatus, two states — the split is what this ticket adds")
    expect(approving.accentIsPresent && asking.accentIsPresent,
           "an agent waiting on you is coloured either way")

    // Neither is in motion, so neither counts up. `elapsed` is meaningful only
    // while `.working`, and the pending fact is what takes it away here.
    expect(approving.elapsed == nil && asking.elapsed == nil,
           "a waiting agent shows no live duration, got \(String(describing: approving.elapsed))/\(String(describing: asking.elapsed))")

    // NOBODY IS WAITING: the request was raised and then the agent carried on.
    // The ring's last event is what the fold reads, so the row says working — the
    // same rule `runInboxRowElapsedCheck`'s interrupted run already depends on.
    let resumed = row([
        working,
        pendingDraft(requestId: "req-7", secondsAfterStart: -60),
        inboxDraft(inboxIsolatedAgentId, status: .working, kind: "turn.started", secondsAfterStart: -30),
    ])
    expect(resumed.state == .working && resumed.elapsed == 30,
           "an agent that resumed after a request is working again, got \(resumed.state.rawValue)/\(String(describing: resumed.elapsed))")

    // The derivation agrees with the fold by construction: pending exactly when
    // the status is needs-attention, over every fixture in this file.
    let snapshots: [(String, ActivityLogSnapshot)] = [
        ("approval", inboxSnapshot(activityByAgent: [inboxIsolatedAgentId: [working, pendingDraft(requestId: "req-7", secondsAfterStart: -10)]])),
        ("input", inboxSnapshot(activityByAgent: [inboxIsolatedAgentId: [working, pendingDraft(requestId: nil, secondsAfterStart: -10)]])),
        ("resumed", inboxSnapshot(activityByAgent: [inboxIsolatedAgentId: [working, pendingDraft(requestId: "req-7", secondsAfterStart: -60), inboxDraft(inboxIsolatedAgentId, status: .working, kind: "turn.started", secondsAfterStart: -30)]])),
        ("at rest", inboxSnapshot()),
    ]
    for (name, snapshot) in snapshots {
        for boardRow in AgentsBoardProjection.rows(from: snapshot) {
            let pending = AgentsBoardProjection.pendingRequest(in: boardRow.recent)
            expect((pending != nil) == (boardRow.status == .needsAttention),
                   "\(name): pendingRequest is set exactly when the status is needsAttention — got \(pending?.rawValue ?? "none") for \(boardRow.status.rawValue)")

            // AND THE RELATIONSHIP TO `respondableRequest`, pinned rather than
            // left as prose, because both now live on this type and mean subtly
            // different things. ONE DIRECTION ONLY: a row this ticket calls
            // `.approval` always has something the responder can answer, so the
            // inbox can never offer an approve button with no target. The
            // converse deliberately does NOT hold — `respondableRequest` scans
            // BACK past later events to find something answerable, which is right
            // for "can this be responded to" and wrong for "is this agent waiting
            // on you right now" (the `resumed` fixture is exactly that case, and
            // it is why an `expect` in the other direction would be false).
            guard let activity = snapshot.byAgent[boardRow.agentId] else { continue }
            if pending == .approval {
                expect(AgentsBoardProjection.respondableRequest(in: activity) != nil,
                       "\(name): a row in the approval state always has a respondable request behind it")
            }
        }
    }
    // The asymmetry is real, not hypothetical — measured on the fixture that
    // separates them, so "one direction only" above cannot quietly become two.
    let resumedSnapshot = snapshots.first { $0.0 == "resumed" }!.1
    let resumedActivity = resumedSnapshot.byAgent[inboxIsolatedAgentId.rawValue]!
    expect(AgentsBoardProjection.pendingRequest(in: resumedActivity.recent) == nil
            && AgentsBoardProjection.respondableRequest(in: resumedActivity) != nil,
           "the resumed agent is not waiting on you, though its earlier request is still answerable — got \(String(describing: AgentsBoardProjection.pendingRequest(in: resumedActivity.recent)))")

    // An empty ring asks for nothing rather than trapping.
    expect(AgentsBoardProjection.pendingRequest(in: []) == nil,
           "an agent with no events is not waiting on you")

    print("AgentInboxRow pending split measured approval=\(approving.state.rawValue) input=\(asking.state.rawValue) resumed=\(resumed.state.rawValue)")
}

private extension AgentInboxRow {
    /// Colour is the vocabulary's, not the join's — this only asserts the join
    /// landed on a state that has one.
    var accentIsPresent: Bool { state.accent != nil }
}

// MARK: - 6 · two sorts coexist (P3.4)

// Ticket: docs/38-tickets/90-agent-ux/P3.4-frozen-sort.md
//
// `InboxSort` lives in ContinuumRevivedAgentUI, which cannot see
// `AgentsBoardProjection`. THIS is the one place both orders are visible at once,
// so it is where "two sorts coexist" is asserted rather than described: the board
// projection stays attention-first for the phone's glance surface, and the desktop
// sort is frozen creation order. The check also proves the desktop sort has real
// spawn times to work with — `createdAt` is joined from the records and
// descriptors, not defaulted.
private func runInboxSortDivergesFromBoardOrderCheck() {
    // Spawn order: headless (oldest) → isolated → tiled (newest). The OLDEST is
    // the one asking for attention, so the two orders are exact opposites at the
    // top: a bug that returned the projection's order untouched cannot pass.
    let agents = [
        inboxAgentRecord(inboxHeadlessAgentId, name: "Headless Reviewer", spawnedAfter: 0),
        inboxAgentRecord(inboxIsolatedAgentId, name: "Isolated Builder", spawnedAfter: 100),
        inboxAgentRecord(inboxTiledAgentId, name: "Record Name", spawnedAfter: 200),
    ]
    let index = AgentContextIndex.build(
        registry: inboxRegistry(),
        documents: [:],
        projectCanvases: [:],
        terminalDescriptors: [],
        agents: agents
    )
    let snapshot = AgentInventory.snapshot(
        terminalDescriptors: [],
        liveStatuses: [inboxHeadlessAgentId.rawValue: .needsAttention],
        agents: agents,
        activityByAgent: [:],
        replicaId: inboxReplicaId,
        now: inboxNow
    )

    // The join carries each agent's OWN spawn time through to its row. Without
    // this the frozen sort would be sorting a column of `distantPast`.
    let rows = AgentInboxRowBuilder.rows(from: snapshot, context: index, now: inboxNow)
    let createdById = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.createdAt) })
    for agent in agents {
        expect(createdById[agent.id.rawValue] == agent.createdAt,
               "a row's createdAt is its agent's own, got \(String(describing: createdById[agent.id.rawValue])) for \(agent.displayName)")
    }
    expect(Set(createdById.values).count == agents.count,
           "the fixture's spawn times must be distinct, or the ordering below proves nothing")

    let boardOrder = rows.map(\.id)
    let frozen = InboxSort.sortForInbox(rows: rows).map(\.id)
    expect(boardOrder.first == inboxHeadlessAgentId.rawValue,
           "AgentsBoardProjection stays ATTENTION-FIRST for iOS — the agent asking for you is at the top, got \(boardOrder)")
    expect(frozen == [inboxTiledAgentId.rawValue, inboxIsolatedAgentId.rawValue, inboxHeadlessAgentId.rawValue],
           "the desktop sort is frozen creation order, newest first, got \(frozen)")
    expect(frozen != boardOrder,
           "the two sorts must actually differ on this fixture — if they agree, only one of them is being tested")

    // And the frozen order does not move when the attention does: hand the loudest
    // row to the other agent and the desktop list is unchanged while the board
    // order flips.
    let quieter = AgentInventory.snapshot(
        terminalDescriptors: [],
        liveStatuses: [inboxTiledAgentId.rawValue: .needsAttention],
        agents: agents,
        activityByAgent: [:],
        replicaId: inboxReplicaId,
        now: inboxNow
    )
    let movedRows = AgentInboxRowBuilder.rows(from: quieter, context: index, now: inboxNow)
    expect(movedRows.map(\.id) != boardOrder,
           "the board order really did react to the attention moving, got \(movedRows.map(\.id))")
    expect(InboxSort.sortForInbox(rows: movedRows).map(\.id) == frozen,
           "the desktop order is unmoved by attention changing hands, got \(InboxSort.sortForInbox(rows: movedRows).map(\.id))")

    // A terminal session has no record; its descriptor is its record, and its
    // createdAt has to reach the row the same way.
    let descriptor = inboxTerminalDescriptor()
    let mixedIndex = AgentContextIndex.build(
        registry: inboxRegistry(),
        documents: inboxDocuments(),
        projectCanvases: [:],
        terminalDescriptors: [descriptor],
        agents: agents
    )
    let mixed = AgentInventory.snapshot(
        terminalDescriptors: [descriptor],
        liveStatuses: [:],
        agents: agents,
        activityByAgent: [:],
        replicaId: inboxReplicaId,
        now: inboxNow
    )
    let terminalRow = AgentInboxRowBuilder.rows(from: mixed, context: mixedIndex, now: inboxNow)
        .first { $0.id == inboxTerminalTile }
    expect(terminalRow?.createdAt == descriptor.createdAt,
           "a terminal session's row is positioned by the session's own createdAt, got \(String(describing: terminalRow?.createdAt))")

    // P2D.4's nesting fact has to survive the join as well, or the desktop sort
    // has no parent to put a child under. The child is the NEWER of the two, so a
    // join that dropped `parentAgentID` would sort it above its parent.
    let parent = inboxAgentRecord(inboxHeadlessAgentId, name: "Orchestrator", spawnedAfter: 0)
    var child = inboxAgentRecord(inboxIsolatedAgentId, name: "Child", spawnedAfter: 50)
    child.parentAgentID = parent.id
    let family = [parent, child]
    let familyRows = AgentInboxRowBuilder.rows(
        from: AgentInventory.snapshot(
            terminalDescriptors: [],
            liveStatuses: [:],
            agents: family,
            activityByAgent: [:],
            replicaId: inboxReplicaId,
            now: inboxNow
        ),
        context: AgentContextIndex.build(
            registry: inboxRegistry(),
            documents: [:],
            projectCanvases: [:],
            terminalDescriptors: [],
            agents: family
        ),
        now: inboxNow
    )
    let familyById = Dictionary(uniqueKeysWithValues: familyRows.map { ($0.id, $0) })
    expect(familyById[child.id.rawValue]?.parentId == parent.id.rawValue,
           "a child's row names its parent in the aggregate keyspace, got \(String(describing: familyById[child.id.rawValue]?.parentId))")
    expect(familyById[parent.id.rawValue]?.parentId == nil,
           "a top-level agent's row has no parent, got \(String(describing: familyById[parent.id.rawValue]?.parentId))")
    expect(InboxSort.sortForInbox(rows: familyRows).map(\.id) == [parent.id.rawValue, child.id.rawValue],
           "the newer child sorts UNDER its older parent, got \(InboxSort.sortForInbox(rows: familyRows).map(\.id))")

    print("InboxSort divergence measured board=\(boardOrder.map { $0.uuidString.suffix(2) }) frozen=\(frozen.map { $0.uuidString.suffix(2) })")
}

/// One record, spawned at a stated offset — the fixture above needs distinct
/// creation times, which `inboxAgents()` (all at `inboxNow`) deliberately does not
/// provide.
private func inboxAgentRecord(_ id: AgentID, name: String, spawnedAfter: TimeInterval) -> AgentRecord {
    AgentRecord(
        id: id,
        displayName: name,
        role: nil,
        model: "anthropic/claude-opus-5",
        thinking: "medium",
        cwd: "/tmp/continuum-inbox-fixture",
        worktreeBranch: nil,
        projectId: inboxProjectId,
        createdAt: inboxNow.addingTimeInterval(spawnedAfter),
        lastActivityAt: inboxNow.addingTimeInterval(spawnedAfter),
        tileId: nil
    )
}

// MARK: - 6 · P3.3 · one owner answers what an agent is doing

// Ticket: docs/38-tickets/94-sidebar-native-ux/P3.3-single-status-owner.md
//
// The supervisor's turn snapshot is the ONLY source of a row's state. Two properties
// that a table alone cannot show, so both are asserted through the real builder:
//
//   * the snapshot is authoritative in BOTH directions — a ring that still looks
//     working cannot make a settled agent read Working, and a quiet ring cannot make
//     a working agent read Ready;
//   * the mapping is total over all six operational kinds, and `kindName`'s
//     hand-listed table is what catches a seventh case added without a row meaning
//     (`AgentTileOperationalState` carries associated values, so it cannot be
//     `CaseIterable` — design C8).

private func inboxRequest(_ kind: PendingRequest) -> AgentPendingRequest {
    AgentPendingRequest(
        requestID: "req-\(kind.rawValue)",
        prompt: "PROMPT-MUST-NOT-REACH-THE-ROW",
        responseMode: .fixedChoice([]),
        kind: kind
    )
}

private func inboxTurnSnapshot(
    _ state: AgentTileOperationalState,
    turnStartedAt: Date? = nil
) -> AgentTileTurnSnapshot {
    AgentTileTurnSnapshot(
        state: state,
        capabilities: .sendStop(canSend: true, canStop: true),
        turnStartedAt: turnStartedAt
    )
}

private func runInboxRowSnapshotIsTheOwnerCheck() {
    // THE TRUTH TABLE. Hand-listed with its kindName, so the count assertion below
    // is over the same values the mapping was asserted on.
    let table: [(state: AgentTileOperationalState, expected: InboxState)] = [
        (.ready, .ready),
        (.working, .working),
        // Queued work is in motion from the human's side; a sixth row state is what
        // the vocabulary exists to forbid.
        (.queued, .working),
        (.needsAction(inboxRequest(.approval)), .approval),
        (.needsAction(inboxRequest(.input)), .input),
        // Reachable for the FIRST time here (§5.11): no AgentStatus records failure,
        // so `state(for:pending:)` could never produce `.failed`.
        (.failed(message: "provider failed"), .failed),
        // A restored agent is waiting on you. "We adopted this record at boot" is a
        // fact about our knowledge and travels as `unobservedAgentIds`, not as a
        // status — reading it as Working is the lie P3.1 removed from disk.
        (.restored, .ready),
    ]
    for row in table {
        let mapped = InboxState.state(forSnapshot: inboxTurnSnapshot(row.state))
        expect(mapped == row.expected,
               "P3.3 mapping: \(row.state.kindName) must read \(row.expected.rawValue), got \(mapped.rawValue)")
    }
    expect(Set(table.map(\.state.kindName)).count == 6,
           "the truth table covers all six operational kinds — got \(Set(table.map(\.state.kindName)).sorted())")
    expect(Set(table.map(\.state.kindName)) == Set(["ready", "working", "queued", "needsAction", "failed", "restored"]),
           "AgentTileOperationalState.kindName's table and this one name the same six kinds — got \(Set(table.map(\.state.kindName)).sorted())")

    // I5: the mapping reads the case and the kind, and NOTHING else. The request's
    // prompt is provider text; it must not reach a row that renders on the desktop
    // and feeds the phone's fold.
    let approvalRows = AgentInboxRowBuilder.rows(
        from: inboxSnapshot(),
        context: inboxIndex(),
        turnSnapshots: [inboxIsolatedAgentId.rawValue: inboxTurnSnapshot(.needsAction(inboxRequest(.approval)))],
        now: inboxNow
    )
    expect(!approvalRows.contains { "\($0)".contains("PROMPT-MUST-NOT-REACH-THE-ROW") },
           "a pending request's prompt must not reach any field of a row — \(approvalRows.map(\.title))")
    expect(approvalRows.first { $0.id == inboxIsolatedAgentId.rawValue }?.state == .approval,
           "an open approval reads as approval through the real builder")

    // BOTH DIRECTIONS. The ring says needsAttention 20s ago (the fixture's own
    // drafts); the snapshot says the turn is over. The row follows the snapshot.
    let noisyRing: [AgentActivityEventDraft] = [
        inboxDraft(inboxIsolatedAgentId, status: .working, kind: "turn.started", secondsAfterStart: -120),
        inboxDraft(inboxIsolatedAgentId, status: .needsAttention, kind: "needs-attention", secondsAfterStart: -20),
    ]
    let ringOnly = AgentInboxRowBuilder.rows(
        from: inboxSnapshot(activityByAgent: [inboxIsolatedAgentId: noisyRing]),
        context: inboxIndex(),
        now: inboxNow
    ).first { $0.id == inboxIsolatedAgentId.rawValue }
    // §5.10: this IS the fallback, exercised where it is reachable — a caller with no
    // supervisor. Through the app it cannot be reached (every row's id has a
    // snapshot), which is why the app asserts "every row has a snapshot" instead.
    expect(ringOnly?.state == .input,
           "fixture check: with NO snapshot the ring's fold still answers, or the both-directions assertions below are vacuous — got \(String(describing: ringOnly?.state))")

    let settled = AgentInboxRowBuilder.rows(
        from: inboxSnapshot(activityByAgent: [inboxIsolatedAgentId: noisyRing]),
        context: inboxIndex(),
        turnSnapshots: [inboxIsolatedAgentId.rawValue: inboxTurnSnapshot(.ready)],
        now: inboxNow
    ).first { $0.id == inboxIsolatedAgentId.rawValue }
    expect(settled?.state == .ready,
           "the drafts-win arm is GONE: a stamped activity draft supplies the timeline, never the status — got \(String(describing: settled?.state))")
    expect(settled?.elapsed == nil,
           "a settled agent shows no clock however working its ring still looks — got \(String(describing: settled?.elapsed))")

    let quietRing = AgentInboxRowBuilder.rows(
        from: inboxSnapshot(),
        context: inboxIndex(),
        turnSnapshots: [inboxHeadlessAgentId.rawValue: inboxTurnSnapshot(.working, turnStartedAt: inboxNow.addingTimeInterval(-45))],
        now: inboxNow
    ).first { $0.id == inboxHeadlessAgentId.rawValue }
    expect(quietRing?.state == .working && quietRing?.elapsed == 45,
           "an agent whose ring holds nothing still reads Working from its owner, measured from the stamped start — got \(String(describing: quietRing?.state))/\(String(describing: quietRing?.elapsed))")
}

/// THE 158-HOUR BUG, as a fixture. The reported symptom: a sidebar row on a
/// freshly-prompted agent reading "158h". Its ring holds one synthetic draft stamped
/// `record.lastSeenAt` — the SPAWN instant, days old — because a restored agent has
/// no real events, and the old elapsed derivation measured the trailing working run
/// from exactly that draft.
private func runInboxRowStampedElapsedCheck() {
    let sevenDays: TimeInterval = 7 * 24 * 3600
    // A restored agent: the only thing in its ring is the synthetic status draft the
    // fold writes for a record with no recorded events, stamped a week ago.
    let staleRing: [AgentActivityEventDraft] = [
        inboxDraft(inboxIsolatedAgentId, status: .working, kind: "desktop.managedStatus", secondsAfterStart: -sevenDays),
    ]
    let bugged = AgentInboxRowBuilder.rows(
        from: inboxSnapshot(activityByAgent: [inboxIsolatedAgentId: staleRing]),
        context: inboxIndex(),
        now: inboxNow
    ).first { $0.id == inboxIsolatedAgentId.rawValue }
    expect(bugged?.elapsed == sevenDays,
           "fixture check: the ring-anchored reading really is \(sevenDays)s (168h) here, or the assertion below cannot fail — got \(String(describing: bugged?.elapsed))")

    let fixed = AgentInboxRowBuilder.rows(
        from: inboxSnapshot(activityByAgent: [inboxIsolatedAgentId: staleRing]),
        context: inboxIndex(),
        turnSnapshots: [inboxIsolatedAgentId.rawValue: inboxTurnSnapshot(.working, turnStartedAt: inboxNow.addingTimeInterval(-30))],
        now: inboxNow
    ).first { $0.id == inboxIsolatedAgentId.rawValue }
    expect(fixed?.state == .working,
           "the freshly-prompted restored agent is working — got \(String(describing: fixed?.state))")
    expect(fixed?.elapsed == 30,
           "THE 158-HOUR BUG: a turn stamped 30s ago must read 30s, not the age of the record it was restored from — got \(String(describing: fixed?.elapsed))s")

    // Still measured against the caller's clock, never stored.
    let later = AgentInboxRowBuilder.rows(
        from: inboxSnapshot(activityByAgent: [inboxIsolatedAgentId: staleRing]),
        context: inboxIndex(),
        turnSnapshots: [inboxIsolatedAgentId.rawValue: inboxTurnSnapshot(.working, turnStartedAt: inboxNow.addingTimeInterval(-30))],
        now: inboxNow.addingTimeInterval(60)
    ).first { $0.id == inboxIsolatedAgentId.rawValue }
    expect(later?.elapsed == 90,
           "the stamped anchor is measured at render time against the caller's clock — got \(String(describing: later?.elapsed))")

    // A start from a host whose clock runs ahead clamps at 0 rather than counting
    // backwards, exactly as the ring-derived reading does.
    let ahead = AgentInboxRowBuilder.rows(
        from: inboxSnapshot(),
        context: inboxIndex(),
        turnSnapshots: [inboxIsolatedAgentId.rawValue: inboxTurnSnapshot(.working, turnStartedAt: inboxNow.addingTimeInterval(600))],
        now: inboxNow
    ).first { $0.id == inboxIsolatedAgentId.rawValue }
    expect(ahead?.elapsed == 0,
           "a turn start stamped in the future clamps to 0 — got \(String(describing: ahead?.elapsed))")

    // An owner reporting a turn with no stamp at all (a state that carries no work)
    // shows no clock — the snapshot is authoritative about the ABSENCE too.
    let unstamped = AgentInboxRowBuilder.rows(
        from: inboxSnapshot(activityByAgent: [inboxIsolatedAgentId: staleRing]),
        context: inboxIndex(),
        turnSnapshots: [inboxIsolatedAgentId.rawValue: inboxTurnSnapshot(.restored)],
        now: inboxNow
    ).first { $0.id == inboxIsolatedAgentId.rawValue }
    expect(unstamped?.elapsed == nil,
           "with an owner reporting no turn in flight the row shows no clock, not the ring's week-old run — got \(String(describing: unstamped?.elapsed))")
}

// MARK: - P6.1 · lifecycle is derived and action eligibility agrees

/// The builder-facing matrix uses a separate hand-written expectation for the
/// important production cases. In particular, unread is deliberately paired
/// with a settled override: it is a mark, not a blocker, so the row must still
/// reach the slim settled variant.
private func runInboxLifecycleDerivationCheck() {
    let threeDays: TimeInterval = 3 * 86_400
    let settledAt = inboxNow.addingTimeInterval(-600)

    func row(
        for record: AgentRecord,
        attention: InboxAttention = .none,
        facts: AgentLifecycleFacts = AgentLifecycleFacts(),
        autoSettleAfter: TimeInterval? = nil,
        activity: [AgentActivityEventDraft] = [],
        turnSnapshot: AgentTileTurnSnapshot? = nil
    ) -> AgentInboxRow {
        let snapshot = inboxSnapshot(
            agents: [record],
            activityByAgent: activity.isEmpty ? [:] : [record.id: activity]
        )
        let built = AgentInboxRowBuilder.rows(
            from: snapshot,
            context: inboxIndex(agents: [record]),
            attention: [record.id.rawValue: attention],
            turnSnapshots: turnSnapshot.map { [record.id.rawValue: $0] } ?? [:],
            records: [record.id.rawValue: record],
            lifecycleFacts: [record.id.rawValue: facts],
            autoSettleAfter: autoSettleAfter,
            now: inboxNow
        )
        guard let builtRow = built.first else {
            fputs("FAIL: P6.1 lifecycle fixture did not build a row\n", stderr)
            Foundation.exit(1)
        }
        return builtRow
    }

    var settledRecord = inboxAgentRecord(inboxHeadlessAgentId, name: "Filed Reviewer", spawnedAfter: 0)
    settledRecord.settledOverride = .settled
    settledRecord.settledAt = settledAt
    let settledUnread = row(for: settledRecord, attention: .unread)
    expect(settledUnread.attention == .unread,
           "the lifecycle witness must retain the finished row's unread mark")
    expect(settledUnread.lifecycle == .settled(at: settledAt) && settledUnread.variant == .slim,
           "unread is a mark, not a settlement blocker — expected a slim settled row, got \(settledUnread.lifecycle)/\(settledUnread.variant.rawValue)")
    expect(!settledUnread.canSettle(),
           "an already-settled row is not a settle target even when it is unread")

    var stale = settledRecord
    stale.settledOverride = .neutral
    stale.settledAt = nil
    stale.lastActivityAt = inboxNow.addingTimeInterval(-threeDays)
    // P6.2: auto-settle is driven by a real turn stamp, never the metadata
    // timestamp above. The legacy nil-stamp case is covered separately as active.
    stale.latestTurnAt = inboxNow.addingTimeInterval(-4 * 86_400)
    let liveBlocker = row(
        for: stale,
        facts: AgentLifecycleFacts(hasLiveRunner: true),
        autoSettleAfter: threeDays)
    expect(liveBlocker.lifecycle == .active && liveBlocker.settlementBlocked,
           "a live runner outranks auto-settle and the row carries the same blocker — got \(liveBlocker.lifecycle)/\(liveBlocker.settlementBlocked)")
    expect(!liveBlocker.canSettle(),
           "the settle action must refuse the same live-runner blocker the classifier saw")

    let pendingBlocker = row(
        for: settledRecord,
        attention: .unread,
        activity: [inboxDraft(inboxHeadlessAgentId, status: .needsAttention, kind: "needs-attention", secondsAfterStart: -10)])
    expect(pendingBlocker.lifecycle == .active && pendingBlocker.settlementBlocked,
           "a pending human request outranks a settled override, including when the row is unread — got \(pendingBlocker.lifecycle)/\(pendingBlocker.settlementBlocked)")
    expect(!pendingBlocker.canSettle(),
           "a pending human request is not a settle target")

    // The ring's pending event is only a no-snapshot fallback. Once the supervisor
    // has an authoritative terminal-ish snapshot, the same stale event remains
    // timeline evidence but cannot pin the parked record active.
    let staleRingPending = [
        inboxDraft(inboxHeadlessAgentId, status: .needsAttention, kind: "needs-attention", secondsAfterStart: -10),
    ]
    let noSnapshotPending = row(for: settledRecord, activity: staleRingPending)
    expect(noSnapshotPending.lifecycle == .active && noSnapshotPending.settlementBlocked,
           "without a supervisor snapshot, ring pending still blocks a settled override — got \(noSnapshotPending.lifecycle)/\(noSnapshotPending.settlementBlocked)")
    expect(!noSnapshotPending.canSettle(),
           "the no-snapshot pending fallback still refuses settle")

    let authoritativeStates: [(String, AgentTileOperationalState)] = [
        ("ready", .ready),
        ("failed", .failed(message: "provider")),
        ("restored", .restored),
    ]
    for (name, authoritativeState) in authoritativeStates {
        let authoritative = row(
            for: settledRecord,
            activity: staleRingPending,
            turnSnapshot: inboxTurnSnapshot(authoritativeState))
        expect(authoritative.lifecycle == .settled(at: settledAt) && !authoritative.settlementBlocked,
               "stale ring pending must not pin an authoritative \(name) snapshot active — got \(authoritative.lifecycle)/\(authoritative.settlementBlocked)")
        expect(!authoritative.canSettle(),
               "an authoritative \(name) snapshot leaves the already-settled row a no-op")
    }

    let genuineNeedsAction = row(
        for: settledRecord,
        activity: [],
        turnSnapshot: inboxTurnSnapshot(.needsAction(inboxRequest(.approval))))
    expect(genuineNeedsAction.state == .approval
            && genuineNeedsAction.lifecycle == .active
            && genuineNeedsAction.settlementBlocked,
           "a genuine supervisor needsAction snapshot still blocks a parked override — got \(genuineNeedsAction.state)/\(genuineNeedsAction.lifecycle)/\(genuineNeedsAction.settlementBlocked)")
    expect(!genuineNeedsAction.canSettle(),
           "a genuine supervisor needsAction snapshot is not a settle target")

    // Production builder witness: a parked parent must be promoted back to the
    // active/card variant before lifecycle derivation when its child is working
    // or needs you. The parent's attention stays its own read-state axis; the
    // child hold reaches the shared blocker/action policy instead.
    let parkedParent = settledRecord
    var child = inboxAgentRecord(inboxIsolatedAgentId, name: "Child Worker", spawnedAfter: 10)
    child.parentAgentID = parkedParent.id
    let childCases: [(String, AgentTileOperationalState)] = [
        ("working", .working),
        ("needs-you", .needsAction(inboxRequest(.input))),
    ]
    for (name, childState) in childCases {
        let family = [parkedParent, child]
        let familyRows = AgentInboxRowBuilder.rows(
            from: inboxSnapshot(agents: family),
            context: inboxIndex(agents: family),
            attention: [parkedParent.id.rawValue: .none, child.id.rawValue: .none],
            turnSnapshots: [child.id.rawValue: inboxTurnSnapshot(childState)],
            records: Dictionary(uniqueKeysWithValues: family.map { ($0.id.rawValue, $0) }),
            now: inboxNow)
        let sortedFamily = InboxSort.sortForInbox(rows: familyRows)
        let rollups = InboxSort.rollups(in: sortedFamily)
        expect(rollups[parkedParent.id.rawValue]?.holdsParentOpen == true,
               "the production family must expose a \(name) child hold before the parent is classified")
        guard let parent = familyRows.first(where: { $0.id == parkedParent.id.rawValue }) else {
            expect(false, "the production family must keep its parked parent row")
            continue
        }
        let rollup = rollups[parent.id]
        expect(parent.attention == .none,
               "a \(name) child hold must not be folded into the parent's read attention")
        expect(parent.lifecycle == .active && parent.variant == .card && parent.settlementBlocked,
               "a settled override with a \(name) child must derive active/card with one blocker policy — got \(parent.lifecycle)/\(parent.variant.rawValue)/\(parent.settlementBlocked)")
        expect(!parent.canSettle(rollup: rollup),
               "classifier/action agreement: a parked parent with a \(name) child is not a settle target")
        expect(parent.canSettle(rollup: rollup)
                == InboxSettlement.canSettle(
                    lifecycle: parent.lifecycle,
                    blocked: parent.settlementBlocked,
                    holdsParentOpen: rollup?.holdsParentOpen ?? false),
               "the production row action must consume the same child-inclusive blocker policy for a \(name) child")
    }

    // The unadopted-prompt grace window is two-sided. Inside it a peer clock may
    // be ahead OR behind and still blocks; outside it the stale record reaches
    // the auto-settle rung instead of being pinned active forever.
    for offset in [-10.0, 10.0] {
        let skewed = row(
            for: stale,
            facts: AgentLifecycleFacts(
                unadoptedPromptAt: inboxNow.addingTimeInterval(offset),
                graceWindow: 30),
            autoSettleAfter: threeDays)
        expect(skewed.lifecycle == .active && skewed.settlementBlocked,
               "an unadopted prompt \(offset < 0 ? "behind" : "ahead") of now inside grace blocks — got \(skewed.lifecycle)/\(skewed.settlementBlocked)")
    }
    for offset in [-31.0, 31.0] {
        let expired = row(
            for: stale,
            facts: AgentLifecycleFacts(
                unadoptedPromptAt: inboxNow.addingTimeInterval(offset),
                graceWindow: 30),
            autoSettleAfter: threeDays)
        expect(expired.lifecycle == .settled(at: stale.realActivityAt!),
               "a prompt \(offset < 0 ? "behind" : "ahead") outside grace is clock skew, not a permanent blocker — got \(expired.lifecycle)")
        expect(!expired.settlementBlocked && !expired.canSettle(),
               "the expired prompt has no blocker, while its settled lifecycle still makes the action a no-op")
    }

    // P6.2 strict boundary: exactly one window is still eligible; only a
    // genuinely older real prompt/turn settles. Metadata is intentionally newer
    // in this fixture and must not change either answer.
    var exactBoundary = stale
    exactBoundary.latestPromptAt = inboxNow.addingTimeInterval(-threeDays)
    exactBoundary.latestTurnAt = nil
    let exactBoundaryRow = row(for: exactBoundary, autoSettleAfter: threeDays)
    expect(exactBoundaryRow.lifecycle == .active,
           "real activity exactly at the auto-settle window remains active under strict > — got \(exactBoundaryRow.lifecycle)")
    exactBoundary.latestPromptAt = inboxNow.addingTimeInterval(-threeDays - 0.001)
    let pastBoundaryRow = row(for: exactBoundary, autoSettleAfter: threeDays)
    expect(pastBoundaryRow.lifecycle == .settled(at: exactBoundary.realActivityAt!),
           "real activity older than the window settles — got \(pastBoundaryRow.lifecycle)")

    // The row and record consume the same shared settlement decision over the
    // matrix's own, blocked, snoozed and auto-settled cases.
    var pinned = stale
    pinned.settledOverride = .active
    var snoozed = stale
    snoozed.snoozedUntil = inboxNow.addingTimeInterval(3_600)
    let matrix: [(String, AgentRecord, AgentLifecycleFacts, TimeInterval?)] = [
        ("fresh neutral", settledRecord, AgentLifecycleFacts(), nil),
        ("keep-active pin", pinned, AgentLifecycleFacts(), threeDays),
        ("snoozed", snoozed, AgentLifecycleFacts(), threeDays),
        ("auto-settled", stale, AgentLifecycleFacts(), threeDays),
        ("pending", settledRecord, AgentLifecycleFacts(attentionIsYours: true), nil),
        ("running", stale, AgentLifecycleFacts(hasLiveRunner: true), threeDays),
    ]
    for (name, record, facts, window) in matrix {
        let built = row(for: record, facts: facts, autoSettleAfter: window)
        let expected = record.canSettle(facts: facts, autoSettleAfter: window, now: inboxNow)
        expect(built.canSettle() == expected,
               "classifier/action agreement for \(name): row \(built.canSettle()) vs record \(expected), lifecycle \(built.lifecycle)")
    }

    // P6.3: snooze is a visibility overlay, not a runner pause or a settle
    // blocker. A working row can be snoozed; a pending human request cannot.
    var workingSnooze = stale
    workingSnooze.latestTurnAt = inboxNow.addingTimeInterval(-60)
    workingSnooze.snoozedAt = inboxNow.addingTimeInterval(-30)
    workingSnooze.snoozedUntil = inboxNow.addingTimeInterval(3_600)
    let workingFacts = AgentLifecycleFacts(hasLiveRunner: true)
    let workingRow = row(for: workingSnooze, facts: workingFacts, autoSettleAfter: threeDays)
    expect(workingRow.lifecycle == .snoozed(until: workingSnooze.snoozedUntil!),
           "a working row stays on the snoozed shelf without pausing its runner — got \(workingRow.lifecycle)")
    expect(workingSnooze.canSnooze(facts: workingFacts, now: inboxNow)
            && !workingSnooze.canSettle(facts: workingFacts, autoSettleAfter: threeDays, now: inboxNow),
           "a working row is snoozable but not settleable")

    let needsHumanFacts = AgentLifecycleFacts(attentionIsYours: true, hasLiveRunner: true)
    let needsHumanRow = row(for: workingSnooze, facts: needsHumanFacts, autoSettleAfter: threeDays)
    expect(needsHumanRow.lifecycle == .active && !workingSnooze.canSnooze(facts: needsHumanFacts, now: inboxNow),
           "a snoozed request waiting on a human wakes visibly and refuses another snooze")

    // Required negative witness: if the derived wake is not promoted to an
    // active-placement timestamp, this old quiet turn falls straight back into
    // auto-settled history even though the failure arrived after the snooze.
    var woken = stale
    woken.snoozedAt = inboxNow
    woken.snoozedUntil = inboxNow.addingTimeInterval(3_600)
    woken.failedAt = inboxNow.addingTimeInterval(1)
    let wokenRow = row(for: woken, autoSettleAfter: threeDays)
    expect(wokenRow.lifecycle == .active && wokenRow.attention == .woke,
           "a post-snooze failure reopens an old quiet row as active/woke — got \(wokenRow.lifecycle)/\(wokenRow.attention)")
    expect(woken.snoozedAt == inboxNow && woken.snoozedUntil == inboxNow.addingTimeInterval(3_600),
           "derived wake leaves both stored snooze dates untouched")
}

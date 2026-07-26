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
    print("AgentInboxRowBuilder checks: coverage/identity, refresh stability, headless rows, title source, terminal sessions, elapsed derivation and branch precedence passed")
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
    expect(refreshedById[inboxIsolatedAgentId.rawValue]?.state == .approval,
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
           "Phase-4 lifecycle and P3.3 attention are not yet derivable, so every row is an active top-level card, got \(headless)")

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

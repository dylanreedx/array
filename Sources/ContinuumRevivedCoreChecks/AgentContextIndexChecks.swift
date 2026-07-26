import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P2B.3-row-context-join.md
//
// Eight properties of "which agent is this?":
//   1. TILED — an agent whose tile lives in a project zone resolves workspace,
//      zone, project, title, model and role.
//   2. HEADLESS — an agent with no tile resolves its project from
//      `AgentRecord.projectId` and leaves workspace/zone/title nil. nil, not ""
//      — an empty string renders as a stray "·" in "project · title · model".
//   3. GEOMETRIC MEMBERSHIP — the tiled agent above is in the PROJECT canvas,
//      not in the workspace document, so it is only reachable through the same
//      centre-in-zone fold `SidebarTreeBuilder` owns. Dropping `projectCanvases`
//      from the call loses it, and a tile whose centre is outside the zone is
//      not claimed by it. That is what makes property 4 a real assertion.
//   4. AGREEMENT — for every tiled agent, the index's (workspace, zone, title)
//      equals what `SidebarTreeBuilder.build` says on the same fixture. Stated
//      honestly: the index CALLS the builder, so this is a REGRESSION NET
//      against a future re-implementation of membership, not an independent
//      derivation. The independent part is property 3.
//   5. UNRESOLVED NAMES — the builder falls back to "" for a project zone whose
//      project is not in the registry; the index reports nil for both the zone
//      name and the project name.
//   6. THE JOIN — `AgentsBoardProjection.rows(from:context:)` attaches context by
//      agent identity, and that keyspace really is the one `AgentInventory`
//      publishes: every row of a real folded snapshot finds its context. Called
//      without an index, every row's context is nil — the older-consumer path.
//   7. I5 — no field of a context carries a host PATH, while the branch NAME is
//      carried verbatim (P2C.4's ruling). The record feeding it has a
//      deliberately distinctive `cwd` that neither the taint scanner nor a
//      literal substring sweep finds, and a host path smuggled through
//      `worktreeBranch` is still a violation, so the new field is not a blind
//      spot. The fixture
//      includes an agent whose project has LEFT the registry, because that is
//      the only state in which a "fall back to something" implementation would
//      reach for `cwd` at all — see `contextOrphanAgentId`.
//   9. BRANCH + ISOLATION (P2C.4) — five states, in `runAgentContextBranchCheck`:
//      isolated-and-matching, isolated-and-mismatched, a shared checkout (which is
//      never a mismatch), a lookup that never happened (which never warns), and a
//      terminal session (which has no branch at all).
//   8. PROJECT PRECEDENCE — when an agent's record and the zone its tile sits in
//      name DIFFERENT projects, the record wins and the placement still reports
//      the zone it is really drawn in. Pinned by a fixture in which the two
//      genuinely differ, so a later change of precedence cannot pass silently.

func runAgentContextIndexChecks() {
    runAgentContextTiledAndHeadlessCheck()
    runAgentContextGeometricMembershipCheck()
    runAgentContextSidebarAgreementCheck()
    runAgentContextRowJoinCheck()
    runAgentContextBranchCheck()
    runAgentContextSyncBoundaryCheck()
    print("AgentContextIndex checks: tiled/headless resolution, geometric membership, sidebar agreement, the row join, branch/isolation state and I5 purity passed")
}

// MARK: - Fixture

private let contextNow = Date(timeIntervalSinceReferenceDate: 806_600_000)
private let contextReplicaId = UUID(uuidString: "2B300000-0000-4000-8000-0000000000FF")!

private let contextWorkspaceId = UUID(uuidString: "2B300000-0000-4000-8000-000000000001")!
private let contextEmptyWorkspaceId = UUID(uuidString: "2B300000-0000-4000-8000-000000000002")!
private let contextProjectId = UUID(uuidString: "2B300000-0000-4000-8000-000000000011")!
/// A second live project, for the agent whose RECORD names a different project
/// than the zone its tile is drawn in.
private let contextOtherProjectId = UUID(uuidString: "2B300000-0000-4000-8000-000000000013")!
private let contextGhostProjectId = UUID(uuidString: "2B300000-0000-4000-8000-000000000012")!
private let contextProjectZoneId = UUID(uuidString: "2B300000-0000-4000-8000-000000000021")!
private let contextGroupZoneId = UUID(uuidString: "2B300000-0000-4000-8000-000000000022")!
private let contextGhostZoneId = UUID(uuidString: "2B300000-0000-4000-8000-000000000023")!

/// In the PROJECT canvas, centre inside the project zone — reachable only via
/// geometric membership.
private let contextTiledAgentTile = UUID(uuidString: "2B300000-0000-4000-8000-000000000031")!
/// In the project canvas too, but centre far outside every zone.
private let contextStrayAgentTile = UUID(uuidString: "2B300000-0000-4000-8000-000000000032")!
/// In the project canvas, centre inside project "Continuum"'s zone, but its
/// record names the OTHER project — an agent working in one project whose tile
/// was dropped onto another project's zone.
private let contextGuestAgentTile = UUID(uuidString: "2B300000-0000-4000-8000-000000000035")!
/// In the workspace document, in the group zone.
private let contextTerminalTile = UUID(uuidString: "2B300000-0000-4000-8000-000000000033")!
/// In the workspace document, in a zone pointing at a project not in the registry.
private let contextGhostTile = UUID(uuidString: "2B300000-0000-4000-8000-000000000034")!

private let contextTiledAgentId = AgentID(rawValue: UUID(uuidString: "2B300000-0000-4000-8000-000000000041")!)
private let contextStrayAgentId = AgentID(rawValue: UUID(uuidString: "2B300000-0000-4000-8000-000000000042")!)
private let contextHeadlessAgentId = AgentID(rawValue: UUID(uuidString: "2B300000-0000-4000-8000-000000000043")!)
/// Its tile sits in project "Continuum"'s zone; its record says "Docs".
private let contextGuestAgentId = AgentID(rawValue: UUID(uuidString: "2B300000-0000-4000-8000-000000000045")!)
/// Headless AND its project is gone from the registry, so NOTHING about it
/// resolves to a name. This is the case that makes the I5 sweep discriminating:
/// a lazy "fall back to something" implementation reaches for `cwd` exactly
/// here, and with every other fixture agent naming a live project the fallback
/// would never be exercised. (Observed: it wasn't — see the ledger note.)
private let contextOrphanAgentId = AgentID(rawValue: UUID(uuidString: "2B300000-0000-4000-8000-000000000044")!)

private func contextZone(
    _ zoneId: UUID,
    projectId: UUID?,
    name: String,
    origin: ZonePoint
) -> ZonePlacement {
    ZonePlacement(
        zoneId: zoneId,
        projectId: projectId,
        origin: origin,
        size: ZoneSize(width: 100, height: 100),
        color: "blue",
        collapsed: false,
        hydrationPolicy: .automatic,
        name: name,
        navKey: nil
    )
}

private func contextTile(_ id: UUID, _ title: String, _ kind: TileKind, x: Double, y: Double) -> Tile {
    Tile(
        id: id,
        kind: kind,
        title: title,
        frame: TileFrame(x: x, y: y, width: 20, height: 20),
        zPosition: .fromLegacyRank(1),
        runtimeRef: nil,
        metadata: TileMetadata()
    )
}

private func contextRegistry() -> Registry {
    Registry(
        lastActiveWorkspaceId: nil,
        lastActiveProjectId: nil,
        workspaces: [
            WorkspaceEntry(id: contextWorkspaceId, name: "Alpha", projectIds: [], createdAt: contextNow, updatedAt: contextNow),
            WorkspaceEntry(id: contextEmptyWorkspaceId, name: "Beta", projectIds: [], createdAt: contextNow, updatedAt: contextNow),
        ],
        projects: [
            ProjectEntry(
                id: contextProjectId,
                name: "Continuum",
                rootPath: "/tmp/continuum-context-fixture",
                workspaceId: contextWorkspaceId,
                lastOpenedAt: contextNow,
                pinned: false
            ),
            ProjectEntry(
                id: contextOtherProjectId,
                name: "Docs",
                rootPath: "/tmp/continuum-context-fixture-docs",
                workspaceId: contextWorkspaceId,
                lastOpenedAt: contextNow,
                pinned: false
            ),
        ],
        settings: RegistrySettings(preferredEditor: .auto, zoomModifier: .command, openLastProjectOnLaunch: true)
    )
}

private func contextDocuments() -> [UUID: WorkspaceDocument] {
    let document = WorkspaceDocument(
        viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
        zones: [
            // Project zone: `name` is deliberately "" because that is what a real
            // project zone stores — the sidebar backfills the project's name.
            contextZone(contextProjectZoneId, projectId: contextProjectId, name: "", origin: ZonePoint(x: 0, y: 0)),
            contextZone(contextGroupZoneId, projectId: nil, name: "Scratch", origin: ZonePoint(x: 200, y: 0)),
            contextZone(contextGhostZoneId, projectId: contextGhostProjectId, name: "", origin: ZonePoint(x: 400, y: 0)),
        ],
        zoneZOrder: [contextProjectZoneId, contextGroupZoneId, contextGhostZoneId],
        lastActiveZoneId: nil,
        ambientTiles: [
            contextTile(contextTerminalTile, "Scratch Shell", .terminal, x: 210, y: 10).with(zoneId: contextGroupZoneId),
            contextTile(contextGhostTile, "Ghost Shell", .terminal, x: 410, y: 10).with(zoneId: contextGhostZoneId),
        ]
    )
    return [contextWorkspaceId: document]
}

private func contextProjectCanvases() -> [UUID: CanvasState] {
    [
        contextProjectId: CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
            tiles: [
                // Centre (20, 20) — inside the project zone at (0,0)+100x100.
                contextTile(contextTiledAgentTile, "Agent Tile", .terminal, x: 10, y: 10),
                // Centre (70, 70) — also inside project "Continuum"'s zone.
                contextTile(contextGuestAgentTile, "Guest Tile", .terminal, x: 60, y: 60),
                // Centre (1010, 1010) — inside no zone.
                contextTile(contextStrayAgentTile, "Stray Tile", .terminal, x: 1000, y: 1000),
            ],
            groups: [],
            lastActiveTileId: nil
        ),
    ]
}

private func contextTerminalDescriptors() -> [TerminalSessionDescriptor] {
    [
        contextTerminalDescriptor(tileId: contextTerminalTile, kind: .claude),
        contextTerminalDescriptor(tileId: contextGhostTile, kind: .shell),
    ]
}

private func contextTerminalDescriptor(
    tileId: UUID,
    kind: AgentKind,
    worktreePath: String? = nil
) -> TerminalSessionDescriptor {
    TerminalSessionDescriptor(
        id: UUID(uuidString: "2B300000-0000-4000-8000-0000000000" + tileId.uuidString.suffix(2))!,
        tileId: tileId,
        launchProfileId: "default",
        command: "/bin/zsh",
        args: [],
        cwd: "/tmp/continuum-context-fixture",
        env: [:],
        // Deliberately NOT the tile's title: the index must report the tile row's
        // title, so one tile does not have two names.
        title: "descriptor title",
        createdAt: contextNow,
        lastStartedAt: contextNow,
        lastExit: nil,
        agentDescriptor: AgentDescriptor(agentKind: kind, worktreePath: worktreePath, status: .idle, statusUpdatedAt: contextNow)
    )
}

private func contextAgents(
    cwd: String = "/tmp/continuum-context-fixture",
    worktreeBranch: String? = nil
) -> [AgentRecord] {
    [
        AgentRecord(
            id: contextTiledAgentId,
            displayName: "Reviewer",
            role: "reviewer",
            model: "openai-codex/gpt-5.6-sol",
            thinking: "medium",
            cwd: cwd,
            worktreeBranch: worktreeBranch,
            projectId: contextProjectId,
            createdAt: contextNow,
            lastActivityAt: contextNow,
            tileId: contextTiledAgentTile
        ),
        AgentRecord(
            id: contextStrayAgentId,
            displayName: "Stray",
            role: nil,
            model: "openai-codex/gpt-5.6-sol",
            thinking: "medium",
            cwd: cwd,
            worktreeBranch: worktreeBranch,
            projectId: contextProjectId,
            createdAt: contextNow,
            lastActivityAt: contextNow,
            tileId: contextStrayAgentTile
        ),
        AgentRecord(
            id: contextHeadlessAgentId,
            displayName: "Headless",
            role: "builder",
            model: "anthropic/claude-opus-5",
            thinking: "high",
            cwd: cwd,
            worktreeBranch: worktreeBranch,
            projectId: contextProjectId,
            createdAt: contextNow,
            lastActivityAt: contextNow,
            tileId: nil
        ),
        AgentRecord(
            id: contextGuestAgentId,
            displayName: "Guest",
            role: nil,
            model: "anthropic/claude-opus-5",
            thinking: "medium",
            cwd: cwd,
            worktreeBranch: worktreeBranch,
            projectId: contextOtherProjectId,
            createdAt: contextNow,
            lastActivityAt: contextNow,
            tileId: contextGuestAgentTile
        ),
        AgentRecord(
            id: contextOrphanAgentId,
            displayName: "Orphan",
            role: nil,
            model: "anthropic/claude-opus-5",
            thinking: "medium",
            cwd: cwd,
            worktreeBranch: worktreeBranch,
            projectId: contextGhostProjectId,
            createdAt: contextNow,
            lastActivityAt: contextNow,
            tileId: nil
        ),
    ]
}

private func contextIndex(
    projectCanvases: [UUID: CanvasState]? = nil,
    agents: [AgentRecord]? = nil,
    checkedOutBranches: [UUID: String] = [:]
) -> [UUID: AgentRowContext] {
    AgentContextIndex.build(
        registry: contextRegistry(),
        documents: contextDocuments(),
        projectCanvases: projectCanvases ?? contextProjectCanvases(),
        terminalDescriptors: contextTerminalDescriptors(),
        agents: agents ?? contextAgents(),
        checkedOutBranches: checkedOutBranches
    )
}

// MARK: - 1 & 2 · tiled and headless

private func runAgentContextTiledAndHeadlessCheck() {
    let index = contextIndex()

    expect(index.count == 7, "AgentContextIndex covers every agent — 2 terminal sessions + 5 records, got \(index.count)")

    guard let tiled = index[contextTiledAgentId.rawValue] else {
        fputs("FAIL: AgentContextIndex has no entry for the tiled agent\n", stderr)
        Foundation.exit(1)
    }
    expect(tiled.workspaceName == "Alpha", "tiled agent resolves its workspace name, got \(tiled.workspaceName ?? "nil")")
    expect(tiled.zoneName == "Continuum", "tiled agent's project-zone name is backfilled from the registry, got \(tiled.zoneName ?? "nil")")
    expect(tiled.projectName == "Continuum", "tiled agent resolves its project name, got \(tiled.projectName ?? "nil")")
    expect(tiled.tileTitle == "Agent Tile", "tiled agent resolves its TILE ROW title, not the descriptor's, got \(tiled.tileTitle ?? "nil")")
    expect(tiled.agentKind == .managed, "an AgentRecord-backed agent is the managed tier, got \(tiled.agentKind.rawValue)")
    expect(tiled.model == "openai-codex/gpt-5.6-sol", "tiled agent carries its fully-qualified model id, got \(tiled.model ?? "nil")")
    expect(tiled.role == "reviewer", "tiled agent carries its role id, got \(tiled.role ?? "nil")")

    guard let headless = index[contextHeadlessAgentId.rawValue] else {
        fputs("FAIL: AgentContextIndex has no entry for the headless agent\n", stderr)
        Foundation.exit(1)
    }
    expect(headless.projectName == "Continuum",
           "headless agent resolves its project from AgentRecord.projectId, got \(headless.projectName ?? "nil")")
    expect(headless.workspaceName == nil && headless.zoneName == nil && headless.tileTitle == nil,
           "headless agent has NO workspace/zone/title — nil, never \"\" — got \(headless)")
    expect(headless.model == "anthropic/claude-opus-5" && headless.role == "builder",
           "headless agent still carries model and role, got \(headless.model ?? "nil")/\(headless.role ?? "nil")")

    // An agent whose project has left the registry: no name resolves, and NOTHING
    // stands in for one. The row shows a model and a status; that is the truth.
    guard let orphan = index[contextOrphanAgentId.rawValue] else {
        fputs("FAIL: AgentContextIndex has no entry for the orphaned-project agent\n", stderr)
        Foundation.exit(1)
    }
    expect(orphan.projectName == nil && orphan.workspaceName == nil && orphan.zoneName == nil && orphan.tileTitle == nil,
           "an agent whose project is not in the registry resolves NO name at all, got \(orphan)")
    expect(orphan.model == "anthropic/claude-opus-5",
           "an orphaned agent still carries its model, got \(orphan.model ?? "nil")")

    // The record's project WINS over the zone its tile is drawn in. This case is
    // pinned rather than argued in a comment: the two answers really do differ
    // here, so a future change of precedence cannot pass silently. It is also
    // the deliberate cost of the rule — a row can name a project its zone does
    // not — accepted because the alternative (the zone wins) tells a headless
    // agent's row nothing at all, and an agent's project is where it WORKS, not
    // where its window was dropped.
    guard let guest = index[contextGuestAgentId.rawValue] else {
        fputs("FAIL: AgentContextIndex has no entry for the guest-zone agent\n", stderr)
        Foundation.exit(1)
    }
    expect(guest.projectName == "Docs",
           "an agent's project comes from its RECORD, not from the zone its tile sits in, got \(guest.projectName ?? "nil")")
    expect(guest.zoneName == "Continuum" && guest.tileTitle == "Guest Tile" && guest.workspaceName == "Alpha",
           "the guest agent's placement is still the zone it is actually drawn in, got \(guest)")

    // A terminal session: kind from its descriptor, no model, no role, and a
    // group zone resolves a zone but no project.
    guard let terminal = index[contextTerminalTile] else {
        fputs("FAIL: AgentContextIndex has no entry for the terminal session\n", stderr)
        Foundation.exit(1)
    }
    expect(terminal.workspaceName == "Alpha" && terminal.zoneName == "Scratch" && terminal.tileTitle == "Scratch Shell",
           "terminal session resolves workspace/zone/title, got \(terminal)")
    expect(terminal.projectName == nil, "a group zone has no project, got \(terminal.projectName ?? "nil")")
    expect(terminal.agentKind == .claude, "terminal session's kind comes from its AgentDescriptor, got \(terminal.agentKind.rawValue)")
    expect(terminal.model == nil && terminal.role == nil,
           "a terminal session has no model and no role to report, got \(terminal.model ?? "nil")/\(terminal.role ?? "nil")")

    // 5 · the builder's "" fallbacks become nil, not empty strings.
    let tree = SidebarTreeBuilder.build(
        registry: contextRegistry(),
        documents: contextDocuments(),
        projectCanvases: contextProjectCanvases()
    )
    let ghostZoneRow = tree.workspaces
        .flatMap(\.zones)
        .first { $0.zoneId == contextGhostZoneId }
    expect(ghostZoneRow?.name == "",
           "fixture check: the sidebar really does report \"\" for an unresolved project zone, got \(ghostZoneRow?.name ?? "nil")")
    guard let ghost = index[contextGhostTile] else {
        fputs("FAIL: AgentContextIndex has no entry for the ghost-zone session\n", stderr)
        Foundation.exit(1)
    }
    expect(ghost.zoneName == nil && ghost.projectName == nil,
           "an unresolvable project zone reports nil, not \"\" — got \(ghost)")
    expect(ghost.workspaceName == "Alpha" && ghost.tileTitle == "Ghost Shell",
           "the rest of an unresolvable zone's context still resolves, got \(ghost)")

    // Determinism: the inbox rebuilds this on every refresh.
    expect(contextIndex() == contextIndex(), "AgentContextIndex.build must be deterministic on identical inputs")

    print("AgentContextIndex measured tiled=\(tiled) headless=\(headless) terminal=\(terminal)")
}

// MARK: - 3 · geometric membership

private func runAgentContextGeometricMembershipCheck() {
    let index = contextIndex()

    // The stray agent's tile is in the project canvas but its centre is in no
    // zone, so the sidebar does not claim it and neither does the index. Its
    // project still resolves — from the RECORD, which is the only source a
    // placement-less agent has.
    guard let stray = index[contextStrayAgentId.rawValue] else {
        fputs("FAIL: AgentContextIndex dropped the out-of-zone agent entirely\n", stderr)
        Foundation.exit(1)
    }
    expect(stray.workspaceName == nil && stray.zoneName == nil && stray.tileTitle == nil,
           "a tile whose centre is outside every zone resolves no placement, got \(stray)")
    expect(stray.projectName == "Continuum",
           "an out-of-zone agent still resolves its project from its record, got \(stray.projectName ?? "nil")")

    // Without the project canvases the in-zone tile is unreachable: it lives in
    // no workspace document, so a placement for it can ONLY have come from the
    // centre-in-zone fold.
    let withoutCanvases = contextIndex(projectCanvases: [:])
    let tiled = withoutCanvases[contextTiledAgentId.rawValue]
    expect(tiled?.tileTitle == nil && tiled?.zoneName == nil,
           "the tiled agent's placement comes from geometric membership alone — dropping projectCanvases must lose it, got \(String(describing: tiled))")
    expect(withoutCanvases[contextTerminalTile]?.zoneName == "Scratch",
           "dropping projectCanvases must not disturb a tile stored in the workspace document")
}

// MARK: - 4 · agreement with SidebarTreeBuilder

private func runAgentContextSidebarAgreementCheck() {
    let registry = contextRegistry()
    let documents = contextDocuments()
    let canvases = contextProjectCanvases()
    let index = AgentContextIndex.build(
        registry: registry,
        documents: documents,
        projectCanvases: canvases,
        terminalDescriptors: contextTerminalDescriptors(),
        agents: contextAgents()
    )
    let tree = SidebarTreeBuilder.build(registry: registry, documents: documents, projectCanvases: canvases)

    // Walk the tree independently and compare every placement the index claims.
    var treePlacements: [UUID: (workspace: String, zone: String, title: String)] = [:]
    for workspace in tree.workspaces {
        for zone in workspace.zones {
            for tile in zone.tiles where treePlacements[tile.tileId] == nil {
                treePlacements[tile.tileId] = (workspace.name, zone.name, tile.title)
            }
        }
    }
    expect(treePlacements.count == 4,
           "fixture check: the sidebar places exactly 4 tiles (2 ambient + 2 by geometry), got \(treePlacements.count)")

    // agentId -> tileId, for the agents that have one.
    let tiledAgents: [(UUID, UUID)] = [
        (contextTiledAgentId.rawValue, contextTiledAgentTile),
        (contextGuestAgentId.rawValue, contextGuestAgentTile),
        (contextTerminalTile, contextTerminalTile),
        (contextGhostTile, contextGhostTile),
    ]
    var compared = 0
    for (agentId, tileId) in tiledAgents {
        guard let context = index[agentId], let placement = treePlacements[tileId] else {
            fputs("FAIL: AgentContextIndex/SidebarTree disagree on whether \(tileId) is placed at all\n", stderr)
            Foundation.exit(1)
        }
        // "" -> nil is the index's own normalisation (property 5), so compare
        // through it rather than pretending the two spellings are equal.
        expect(context.workspaceName == placement.workspace,
               "index workspace must equal the sidebar's for \(tileId): \(context.workspaceName ?? "nil") vs \(placement.workspace)")
        expect(context.zoneName == (placement.zone.isEmpty ? nil : placement.zone),
               "index zone must equal the sidebar's for \(tileId): \(context.zoneName ?? "nil") vs \(placement.zone)")
        expect(context.tileTitle == placement.title,
               "index title must equal the sidebar's for \(tileId): \(context.tileTitle ?? "nil") vs \(placement.title)")
        compared += 1
    }
    expect(compared == 4, "the agreement check compared every placed agent, got \(compared)")
    print("AgentContextIndex sidebar agreement measured placed=\(treePlacements.count) compared=\(compared)")
}

// MARK: - 6 · the join onto rows

private func runAgentContextRowJoinCheck() {
    let snapshot = AgentInventory.snapshot(
        terminalDescriptors: contextTerminalDescriptors(),
        liveStatuses: [:],
        agents: contextAgents(),
        activityByAgent: [:],
        replicaId: contextReplicaId,
        now: contextNow
    )
    let index = contextIndex()

    let joined = AgentsBoardProjection.rows(from: snapshot, context: index)
    expect(joined.count == 7, "the fold publishes a row per agent, got \(joined.count)")
    // The load-bearing assertion: the index and the snapshot must be keyed the
    // same way. A join keyed on tile ids would silently miss the headless agent.
    expect(joined.allSatisfy { $0.context != nil },
           "every published row finds its context — the index and ActivityLogSnapshot share one keyspace")
    let joinedById = Dictionary(uniqueKeysWithValues: joined.map { ($0.agentId, $0) })
    expect(joinedById[contextHeadlessAgentId.rawValue]?.context == index[contextHeadlessAgentId.rawValue],
           "the headless agent's row carries the headless agent's context")
    expect(joinedById[contextTiledAgentId.rawValue]?.context?.tileTitle == "Agent Tile",
           "a joined row can render project · title · model with no second lookup")

    // The older-consumer path: no index, no context, same rows.
    let unjoined = AgentsBoardProjection.rows(from: snapshot)
    expect(unjoined.allSatisfy { $0.context == nil }, "rows(from:) with no index leaves context nil")
    expect(unjoined.map(\.agentId) == joined.map(\.agentId), "joining context must not change row identity or order")
}

// MARK: - 9 · the branch an agent works on (P2C.4)

/// Five states, all off the same fold:
///   · ISOLATED, MATCHING — a branch of its own, and its checkout is on it.
///   · ISOLATED, MISMATCHED — the agent has left the branch it was given, so its
///     commits are not landing where the record says.
///   · SHARED — no branch of its own, so it works on whatever the project has
///     checked out. Not a mismatch: `isBranchMismatch` must stay false, or every
///     ordinary agent would warn.
///   · NOT LOOKED UP — no `checkedOutBranches` entry. Both fields nil and NO
///     warning, so a failed or skipped git read cannot invent one.
///   · A TERMINAL SESSION — never reports a branch, even though its descriptor
///     carries a worktree PATH. Nothing may promote that path to a branch.
///
/// Negative tests observed red at exit 1 with the final code, each quoted at its
/// assertion — see the ledger note for this ticket.
private func runAgentContextBranchCheck() {
    let ownBranch = "agent/reviewer-check-auth-1a2b3c4d"
    let isolatedAgents = contextAgents(worktreeBranch: ownBranch)

    // Isolated and matching.
    let matching = contextIndex(
        agents: isolatedAgents,
        checkedOutBranches: [contextTiledAgentId.rawValue: ownBranch]
    )
    guard let onItsBranch = matching[contextTiledAgentId.rawValue] else {
        fputs("FAIL: AgentContextIndex lost the isolated agent\n", stderr)
        Foundation.exit(1)
    }
    expect(onItsBranch.worktreeBranch == ownBranch,
           "an isolated agent's context carries its branch, got \(onItsBranch.worktreeBranch ?? "nil")")
    expect(onItsBranch.isIsolated,
           "an agent with a worktree branch is isolated")
    expect(onItsBranch.checkedOutBranch == ownBranch,
           "the caller's checked-out branch is carried through, got \(onItsBranch.checkedOutBranch ?? "nil")")
    expect(!onItsBranch.isBranchMismatch,
           "an isolated agent ON its own branch must NOT be flagged — this is the ordinary case")

    // Isolated, and it has wandered off.
    let mismatched = contextIndex(
        agents: isolatedAgents,
        checkedOutBranches: [contextTiledAgentId.rawValue: "main"]
    )
    guard let wandered = mismatched[contextTiledAgentId.rawValue] else {
        fputs("FAIL: AgentContextIndex lost the mismatched agent\n", stderr)
        Foundation.exit(1)
    }
    expect(wandered.isBranchMismatch,
           "an isolated agent whose checkout is on \(wandered.checkedOutBranch ?? "nil") rather than \(ownBranch) must be flagged")

    // Shared checkout: no branch of its own, and NOT a mismatch.
    let shared = contextIndex(checkedOutBranches: [contextTiledAgentId.rawValue: "main"])
    guard let sharing = shared[contextTiledAgentId.rawValue] else {
        fputs("FAIL: AgentContextIndex lost the shared-checkout agent\n", stderr)
        Foundation.exit(1)
    }
    expect(sharing.worktreeBranch == nil && !sharing.isIsolated,
           "an agent with no worktree branch is not isolated, got \(String(describing: sharing.worktreeBranch))")
    expect(sharing.checkedOutBranch == "main",
           "a shared agent still reports the branch it works on, got \(sharing.checkedOutBranch ?? "nil")")
    expect(!sharing.isBranchMismatch,
           "an agent that shares the project checkout can never be 'on the wrong branch' — it is on yours")

    // Nothing looked up: no branch state, and no warning.
    let unlooked = contextIndex(agents: isolatedAgents)
    guard let unread = unlooked[contextTiledAgentId.rawValue] else {
        fputs("FAIL: AgentContextIndex lost the agent with no branch lookup\n", stderr)
        Foundation.exit(1)
    }
    expect(unread.checkedOutBranch == nil && !unread.isBranchMismatch,
           "an unread checkout must not warn, got \(String(describing: unread.checkedOutBranch))")

    // A terminal session: no branch, ever. Its descriptor carries a worktree PATH.
    let terminalWorktreePath = "/Users/qa/continuum-worktrees/terminal-session"
    let withTerminalPath = AgentContextIndex.build(
        registry: contextRegistry(),
        documents: contextDocuments(),
        projectCanvases: contextProjectCanvases(),
        terminalDescriptors: [contextTerminalDescriptor(
            tileId: contextTerminalTile, kind: .claude, worktreePath: terminalWorktreePath
        )],
        agents: [],
        checkedOutBranches: [contextTerminalTile: "main"]
    )
    guard let terminal = withTerminalPath[contextTerminalTile] else {
        fputs("FAIL: AgentContextIndex lost the terminal session\n", stderr)
        Foundation.exit(1)
    }
    expect(terminal.worktreeBranch == nil && !terminal.isIsolated,
           "a terminal session has no branch to report, got \(String(describing: terminal.worktreeBranch))")
    expect(terminal.checkedOutBranch == "main",
           "a terminal session still reports the checkout it sits in, got \(terminal.checkedOutBranch ?? "nil")")
    // Discriminating: the path really was in the input, so "no branch" is a choice.
    expect(taintCheck(["worktreePath": terminalWorktreePath]).contains { $0.pattern == .hostLocalPath },
           "fixture check: the terminal descriptor's worktree path really is host-bound")

    print("AgentContextIndex branch states measured matching=\(onItsBranch.worktreeBranch ?? "nil")/\(onItsBranch.checkedOutBranch ?? "nil") mismatched=\(wandered.checkedOutBranch ?? "nil") shared=\(sharing.checkedOutBranch ?? "nil")")
}

// MARK: - 7 · I5

private func runAgentContextSyncBoundaryCheck() {
    let secretCwd = "/Users/qa/Documents/personal/continuum-worktrees/p2b3-secret"
    let secretBranch = "agents/p2b3-secret-branch"
    let index = contextIndex(agents: contextAgents(cwd: secretCwd, worktreeBranch: secretBranch))

    // `AgentRowContext` is not Codable — nothing publishes it — so the scanner is
    // run over its string fields directly, which is every string it holds.
    var scannable: [String: Any] = [:]
    for (agentId, context) in index {
        scannable["\(agentId).workspaceName"] = context.workspaceName
        scannable["\(agentId).zoneName"] = context.zoneName
        scannable["\(agentId).projectName"] = context.projectName
        scannable["\(agentId).tileTitle"] = context.tileTitle
        scannable["\(agentId).agentKind"] = context.agentKind.rawValue
        scannable["\(agentId).model"] = context.model
        scannable["\(agentId).role"] = context.role
        scannable["\(agentId).worktreeBranch"] = context.worktreeBranch
        scannable["\(agentId).checkedOutBranch"] = context.checkedOutBranch
    }
    let compacted = scannable.compactMapValues { $0 }
    let violations = taintCheck(compacted)
    expect(violations.isEmpty, "no field of an AgentRowContext is host-bound — found \(violations)")

    let text = compacted.values.map { "\($0)" }.joined(separator: "\n")
    expect(!text.contains(secretCwd), "AgentRowContext does not carry AgentRecord.cwd")
    // P2C.4 RULED THE BRANCH ADMISSIBLE — "the branch *name* may cross to the
    // phone; the worktree **path** must not" — so this asserts the opposite of what
    // it did under P2B.3: the name is carried VERBATIM, and the two branch fields
    // are swept above so a host path handed to either is still a violation. The
    // narrower invariant, `cwd` never crossing, is unchanged and asserted right here
    // on the same fixture.
    expect(text.contains(secretBranch),
           "AgentRowContext must carry AgentRecord.worktreeBranch — a chip cannot name a branch it was not given")
    // The branch field is not a blind spot: a cwd-shaped value in it is caught.
    let smuggled = AgentContextIndex.build(
        registry: contextRegistry(),
        documents: contextDocuments(),
        projectCanvases: contextProjectCanvases(),
        terminalDescriptors: [],
        agents: contextAgents(cwd: secretCwd, worktreeBranch: secretCwd)
    )
    let smuggledViolations = taintCheck(
        smuggled.compactMapValues { $0.worktreeBranch }.reduce(into: [String: Any]()) { out, pair in
            out["\(pair.key).worktreeBranch"] = pair.value
        }
    )
    expect(smuggledViolations.contains { $0.pattern == .hostLocalPath },
           "a host path smuggled through worktreeBranch must still be a taint violation — found \(smuggledViolations)")
    // Discriminating case: the sweep only means something if those strings were
    // really in the input the join read.
    guard let recordData = try? JSONCodec.makeEncoder().encode(contextAgents(cwd: secretCwd, worktreeBranch: secretBranch)),
          let recordText = String(data: recordData, encoding: .utf8)
    else {
        fputs("FAIL: the P2B.3 I5 witness fixture failed to encode\n", stderr)
        Foundation.exit(1)
    }
    expect(recordText.contains(secretCwd) && recordText.contains(secretBranch),
           "the I5 witness fed the join records that really do carry a host path and a branch")
    // The project's own rootPath is a host path too, and it sits in the registry
    // right beside the name the index is allowed to read.
    expect(!text.contains("/tmp/continuum-context-fixture"),
           "AgentRowContext does not carry ProjectEntry.rootPath")
}

import ContinuumRevivedAgentUI
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P2B.3-row-context-join.md
//
// WHICH AGENT IS THIS?
//
// `AgentsBoardRow` carries an id, a status, a summary and a timestamp. None of
// that answers the only question a human asks of an inbox row — which agent,
// in which project. This is that join, and it is PURE: names in, names out, no
// controller, no disk (observer-independence, P2B.8).
//
// Placement is NOT re-derived here. Whether a tile belongs to a project zone is
// geometric (`ZonePlacement` + a tile's centre in the project canvas), and
// `SidebarTreeBuilder` already owns that fold — so this index CALLS it and walks
// the tree it returns. A second implementation of membership is how the sidebar
// and the inbox end up disagreeing about where an agent lives.
//
// I5 (sync-boundary purity): every field here is a NAME or a model id — a
// workspace name, a zone name, a project name, a tile title, and since P2C.4 a
// BRANCH name. `AgentRecord.cwd` is a host path and is deliberately never read,
// not even as a fallback for a missing project name. `AgentContextIndexChecks`
// witnesses that with a record whose cwd is a distinctive string, and witnesses
// the branch fields the other way round: they must carry the name verbatim, and a
// host path handed to one of them is still caught by the taint scanner.
//
// P2C.4 rules the branch admissible ("the branch *name* may cross to the phone;
// the worktree **path** must not"). A branch name is a ref, not a location: it
// says nothing about where this machine keeps its checkouts.
public struct AgentRowContext: Equatable, Sendable {
    /// nil when the agent has no view — a headless agent lives in no workspace.
    public let workspaceName: String?
    /// nil when the agent has no view, or when its zone's name is unresolvable.
    public let zoneName: String?
    public let projectName: String?
    public let projectId: UUID?
    /// nil when the agent has no tile rendering it.
    public let tileTitle: String?
    /// P3.1: `AgentRecord.displayName` — the name the AGENT owns, which outlives
    /// the tile that renders it (the locked decision), so a headless agent still
    /// has one where `tileTitle` is nil. nil for a terminal session, which has no
    /// record and is named by its tile. A name, so I5-admissible on the same
    /// footing as the workspace / zone / project / tile names beside it.
    public let displayName: String?
    public let agentKind: AgentKind
    /// Which CLI Array drives this agent — `AgentRecord.harness`, carried as its
    /// rawValue (`Claude Code` / `Codex` / `Pi`), which is already display text.
    ///
    /// `agentKind` cannot answer this and never could: every `AgentRecord`-backed
    /// agent is folded in as `.managed` below, and the inbox shows only managed
    /// agents — so `agentKind` is the same value for every row the sidebar draws.
    /// nil for a terminal session, which has no record to own a harness.
    public let harness: String?
    /// nil for a terminal session: `AgentDescriptor` records a kind and a
    /// status, never a model. Only an `AgentRecord`-backed agent has one.
    public let model: String?
    /// A `.pi/agents/<role>.md` id, never a title (see `AgentRecord.role`).
    public let role: String?
    /// P2C.4: the branch an ISOLATED agent was given — `AgentRecord.worktreeBranch`,
    /// which P2C.2 writes as `agent/<slug>` at the moment it creates the checkout.
    /// nil when the agent shares its project's working copy, and always nil for a
    /// terminal session (an `AgentDescriptor` records a worktree PATH, never a
    /// branch).
    public let worktreeBranch: String?
    /// P2C.4: the branch actually checked out in the directory this agent WORKS IN,
    /// as the caller last read it (`CheckedOutBranchCache`).
    ///
    /// "The directory this agent works in" is `AgentRecord.cwd` — for an isolated
    /// agent its own worktree, for a shared one the project root. nil means the
    /// caller did not look, or the checkout is detached or unreadable; never "no
    /// branch". The lookup is I/O, so it is the caller's, not this fold's (this
    /// file is pure — names in, names out).
    public let checkedOutBranch: String?
    /// P3.4: when the agent was SPAWNED — `AgentRecord.createdAt`, or a terminal
    /// session's `TerminalSessionDescriptor.createdAt`. The desktop inbox's frozen
    /// order is keyed on it, and it is the only timestamp this value carries: an
    /// activity time here would be an invitation to sort on it.
    ///
    /// nil only for a caller that built a context by hand; the index always knows
    /// it, because both of the things it indexes record their own birthday.
    public let createdAt: Date?
    /// P2D.4/P3.4: the agent that spawned this one (`AgentRecord.parentAgentID`),
    /// in the aggregate keyspace the rest of this index uses. nil for a top-level
    /// agent, and always nil for a terminal session, which nothing spawns.
    public let parentId: UUID?

    /// This agent has a checkout of its own.
    ///
    /// Derived, not stored, and derived from the BRANCH rather than from `cwd`:
    /// P2C.2's isolated spawn creates the worktree and records its branch in one
    /// step and nothing else ever sets `worktreeBranch`, so a stored flag could
    /// only ever disagree with it — and `cwd` is the one field this value may not
    /// carry.
    public var isIsolated: Bool { worktreeBranch != nil }

    /// The agent is not working on the branch it was given.
    ///
    /// Only an isolated agent can be: it is the only one that HAS a branch of its
    /// own to leave. A shared-checkout agent works on whatever the project has
    /// checked out, which is not a mismatch — it is the thing the chip shows.
    ///
    /// False whenever the checkout was not read, so a failed lookup never warns.
    public var isBranchMismatch: Bool {
        guard let worktreeBranch, let checkedOutBranch else { return false }
        return worktreeBranch != checkedOutBranch
    }

    public init(
        workspaceName: String? = nil,
        zoneName: String? = nil,
        projectName: String? = nil,
        projectId: UUID? = nil,
        tileTitle: String? = nil,
        displayName: String? = nil,
        agentKind: AgentKind,
        harness: String? = nil,
        model: String? = nil,
        role: String? = nil,
        worktreeBranch: String? = nil,
        checkedOutBranch: String? = nil,
        createdAt: Date? = nil,
        parentId: UUID? = nil
    ) {
        self.workspaceName = workspaceName
        self.zoneName = zoneName
        self.projectName = projectName
        self.projectId = projectId
        self.tileTitle = tileTitle
        self.displayName = displayName
        self.agentKind = agentKind
        self.harness = harness
        self.model = model
        self.role = role
        self.worktreeBranch = worktreeBranch
        self.checkedOutBranch = checkedOutBranch
        self.createdAt = createdAt
        self.parentId = parentId
    }
}

public enum AgentContextIndex {
    /// Context for every agent, keyed by the SAME aggregate identity
    /// `AgentActivityEvent.agentId` and `AgentInventory.snapshot` use:
    /// `AgentRecord.id.rawValue` for an agent, and a terminal session's `tileId`
    /// (which has no `AgentRecord`, so its tile id IS its agent identity). One
    /// keyspace, so a row and its context cannot fail to meet.
    ///
    /// `checkedOutBranches` is keyed the same way, and carries what the caller read
    /// off disk for each agent's working directory (P2C.4). Defaulted to empty, so
    /// a caller that has not looked simply reports no branch state rather than a
    /// guess — and the fold stays pure.
    public static func build(
        registry: Registry,
        documents: [UUID: WorkspaceDocument],
        projectCanvases: [UUID: CanvasState] = [:],
        terminalDescriptors: [TerminalSessionDescriptor] = [],
        agents: [AgentRecord] = [],
        checkedOutBranches: [UUID: String] = [:]
    ) -> [UUID: AgentRowContext] {
        let placements = tilePlacements(
            registry: registry,
            documents: documents,
            projectCanvases: projectCanvases
        )
        let projectNames = Dictionary(
            registry.projects.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )

        var index: [UUID: AgentRowContext] = [:]
        for descriptor in terminalDescriptors {
            let placement = placements[descriptor.tileId]
            index[descriptor.tileId] = AgentRowContext(
                workspaceName: placement?.workspaceName,
                zoneName: placement?.zoneName,
                projectName: placement?.projectId.flatMap { projectNames[$0] },
                projectId: placement?.projectId,
                // The builder's title, not the descriptor's: the tile row is what
                // the sidebar shows, and two names for one tile is a bug waiting.
                tileTitle: placement?.tileTitle,
                agentKind: descriptor.agentDescriptor?.agentKind ?? .shell,
                // A terminal session has no branch of its own to report: the
                // descriptor records a worktree PATH, and this value may not carry
                // one. Its checkout is reported if the caller read it.
                checkedOutBranch: checkedOutBranches[descriptor.tileId],
                // The session's own birthday, which is this agent's: a terminal
                // session has no record, so its descriptor IS its record.
                createdAt: descriptor.createdAt
            )
        }
        for record in agents {
            let placement = record.tileId.flatMap { placements[$0] }
            index[record.id.rawValue] = AgentRowContext(
                workspaceName: placement?.workspaceName,
                zoneName: placement?.zoneName,
                // The record's own project wins over the one its tile happens to
                // sit in: a headless agent has only the former, and an agent
                // dropped onto another project's zone is still that project's
                // agent. Falls back to the zone's project so a terminal-shaped
                // record with no projectId still names one.
                projectName: (record.projectId ?? placement?.projectId).flatMap { projectNames[$0] },
                projectId: record.projectId ?? placement?.projectId,
                tileTitle: placement?.tileTitle,
                displayName: nonEmpty(record.displayName),
                // An `AgentRecord` is the managed tier by construction — the
                // record exists because Continuum runs the agent itself. The
                // record carries no kind of its own to read.
                agentKind: .managed,
                // ...which is exactly why `harness` is carried separately. The kind
                // above is `.managed` for every row the inbox draws, so it can never
                // tell a Pi agent from a Codex one; the record knows, and its
                // rawValue is already the display string.
                harness: record.harness?.rawValue,
                model: record.model,
                role: record.role,
                worktreeBranch: record.worktreeBranch,
                checkedOutBranch: checkedOutBranches[record.id.rawValue],
                createdAt: record.createdAt,
                // P2D.4's nesting fact, carried in the aggregate keyspace — the
                // parent's `AgentID` names a record, and a record's agent identity
                // is its raw UUID.
                parentId: record.parentAgentID?.rawValue
            )
        }
        return index
    }

    private struct TilePlacement {
        let workspaceName: String?
        let zoneName: String?
        let projectId: UUID?
        let tileTitle: String?
    }

    /// tileId → where the sidebar says that tile is, via the sidebar's own fold.
    private static func tilePlacements(
        registry: Registry,
        documents: [UUID: WorkspaceDocument],
        projectCanvases: [UUID: CanvasState]
    ) -> [UUID: TilePlacement] {
        let tree = SidebarTreeBuilder.build(
            registry: registry,
            documents: documents,
            projectCanvases: projectCanvases
        )
        var placements: [UUID: TilePlacement] = [:]
        for workspace in tree.workspaces {
            for zone in workspace.zones {
                for tile in zone.tiles {
                    // First wins: a project canvas is reachable from more than one
                    // workspace, and the sidebar draws the tile in each. The inbox
                    // shows one row, so it needs one placement — and workspace
                    // order is registry order, which is stable.
                    guard placements[tile.tileId] == nil else { continue }
                    placements[tile.tileId] = TilePlacement(
                        workspaceName: nonEmpty(workspace.name),
                        // `SidebarTreeBuilder` falls back to "" for a project zone
                        // whose project is not in the registry. An empty string
                        // would render as a stray separator in "project · title ·
                        // model"; absent means absent.
                        zoneName: nonEmpty(zone.name),
                        projectId: zone.projectId,
                        tileTitle: nonEmpty(tile.title)
                    )
                }
            }
        }
        return placements
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}

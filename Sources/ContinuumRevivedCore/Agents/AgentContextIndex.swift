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
// workspace name, a zone name, a project name, a tile title. `AgentRecord.cwd`
// and `worktreeBranch` are host paths and are deliberately never read, not even
// as a fallback for a missing project name. `AgentContextIndexChecks` witnesses
// that with a record whose cwd and branch are distinctive strings.
public struct AgentRowContext: Equatable, Sendable {
    /// nil when the agent has no view — a headless agent lives in no workspace.
    public let workspaceName: String?
    /// nil when the agent has no view, or when its zone's name is unresolvable.
    public let zoneName: String?
    public let projectName: String?
    /// nil when the agent has no tile rendering it.
    public let tileTitle: String?
    public let agentKind: AgentKind
    /// nil for a terminal session: `AgentDescriptor` records a kind and a
    /// status, never a model. Only an `AgentRecord`-backed agent has one.
    public let model: String?
    /// A `.pi/agents/<role>.md` id, never a title (see `AgentRecord.role`).
    public let role: String?

    public init(
        workspaceName: String? = nil,
        zoneName: String? = nil,
        projectName: String? = nil,
        tileTitle: String? = nil,
        agentKind: AgentKind,
        model: String? = nil,
        role: String? = nil
    ) {
        self.workspaceName = workspaceName
        self.zoneName = zoneName
        self.projectName = projectName
        self.tileTitle = tileTitle
        self.agentKind = agentKind
        self.model = model
        self.role = role
    }
}

public enum AgentContextIndex {
    /// Context for every agent, keyed by the SAME aggregate identity
    /// `AgentActivityEvent.agentId` and `AgentInventory.snapshot` use:
    /// `AgentRecord.id.rawValue` for an agent, and a terminal session's `tileId`
    /// (which has no `AgentRecord`, so its tile id IS its agent identity). One
    /// keyspace, so a row and its context cannot fail to meet.
    public static func build(
        registry: Registry,
        documents: [UUID: WorkspaceDocument],
        projectCanvases: [UUID: CanvasState] = [:],
        terminalDescriptors: [TerminalSessionDescriptor] = [],
        agents: [AgentRecord] = []
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
                // The builder's title, not the descriptor's: the tile row is what
                // the sidebar shows, and two names for one tile is a bug waiting.
                tileTitle: placement?.tileTitle,
                agentKind: descriptor.agentDescriptor?.agentKind ?? .shell
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
                tileTitle: placement?.tileTitle,
                // An `AgentRecord` is the managed tier by construction — the
                // record exists because Continuum runs the agent itself. The
                // record carries no kind of its own to read.
                agentKind: .managed,
                model: record.model,
                role: record.role
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

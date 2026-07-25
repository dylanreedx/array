import ContinuumRevivedAgentUI
import Foundation

public enum SidebarAgentStatusKind: String, Codable, Equatable, Sendable {
    case working
    case needsAttention
    case done
    case stale
    case unknown

    public static func kind(for status: AgentStatus) -> SidebarAgentStatusKind {
        switch status {
        case .working: return .working
        case .needsAttention: return .needsAttention
        case .done: return .done
        case .stale: return .stale
        case .configuring, .idle: return .unknown
        }
    }
}

public struct SidebarAgentStatusRollup: Codable, Equatable, Sendable {
    public var working: Int
    public var needsAttention: Int
    public var done: Int
    public var stale: Int
    public var unknown: Int

    public static let empty = SidebarAgentStatusRollup()

    public init(working: Int = 0, needsAttention: Int = 0, done: Int = 0, stale: Int = 0, unknown: Int = 0) {
        self.working = working
        self.needsAttention = needsAttention
        self.done = done
        self.stale = stale
        self.unknown = unknown
    }

    public var isEmpty: Bool {
        working == 0 && needsAttention == 0 && done == 0 && stale == 0 && unknown == 0
    }

    public var dominantKind: SidebarAgentStatusKind? {
        if needsAttention > 0 { return .needsAttention }
        if working > 0 { return .working }
        if stale > 0 { return .stale }
        if done > 0 { return .done }
        if unknown > 0 { return .unknown }
        return nil
    }

    public var displayText: String? {
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if needsAttention > 0 { parts.append("\(needsAttention) needs you") }
        if done > 0 { parts.append("\(done) done") }
        if stale > 0 { parts.append("\(stale) stale") }
        if unknown > 0 { parts.append("\(unknown) unknown") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public mutating func add(_ status: AgentStatus) {
        switch SidebarAgentStatusKind.kind(for: status) {
        case .working: working += 1
        case .needsAttention: needsAttention += 1
        case .done: done += 1
        case .stale: stale += 1
        case .unknown: unknown += 1
        }
    }

    public static func make<S: Sequence>(statuses: S) -> SidebarAgentStatusRollup where S.Element == AgentStatus {
        var rollup = SidebarAgentStatusRollup.empty
        for status in statuses { rollup.add(status) }
        return rollup
    }
}

public struct SidebarTileRow: Codable, Equatable, Sendable {
    public let tileId: UUID
    public let title: String
    public let kind: TileKind
    public let agentStatus: AgentStatus?
    public var evidence: AgentSnapshot.Evidence?

    public init(tileId: UUID, title: String, kind: TileKind, agentStatus: AgentStatus? = nil, evidence: AgentSnapshot.Evidence? = nil) {
        self.tileId = tileId
        self.title = title
        self.kind = kind
        self.agentStatus = agentStatus
        self.evidence = evidence
    }
}

public struct SidebarZoneRow: Codable, Equatable, Sendable {
    public let zoneId: UUID
    public let name: String
    public let color: String
    public let navKey: String?
    public let collapsed: Bool
    public let projectId: UUID?
    public let agentStatusRollup: SidebarAgentStatusRollup
    public var tiles: [SidebarTileRow]

    public init(zoneId: UUID, name: String, color: String, navKey: String?, collapsed: Bool, projectId: UUID?, agentStatusRollup: SidebarAgentStatusRollup = .empty, tiles: [SidebarTileRow] = []) {
        self.zoneId = zoneId
        self.name = name
        self.color = color
        self.navKey = navKey
        self.collapsed = collapsed
        self.projectId = projectId
        self.agentStatusRollup = agentStatusRollup
        self.tiles = tiles
    }
}

public struct SidebarWorkspaceRow: Codable, Equatable, Sendable {
    public let workspaceId: UUID
    public let name: String
    public var zones: [SidebarZoneRow]

    public init(workspaceId: UUID, name: String, zones: [SidebarZoneRow]) {
        self.workspaceId = workspaceId
        self.name = name
        self.zones = zones
    }
}

public struct SidebarTree: Codable, Equatable, Sendable {
    public var workspaces: [SidebarWorkspaceRow]

    public init(workspaces: [SidebarWorkspaceRow]) {
        self.workspaces = workspaces
    }
}

// NAME NOTE: ticket 08 (Sources/ContinuumRevivedCore/AgentActivityEvent.swift) had
// already shipped a public `ActivityTreeSnapshot` — the ActivityStore's materialized
// read model (snapshotSequence/snapshotReplicaId/byAgent) — before this ticket landed.
// Two public types cannot share one name in the same module, so that pre-existing
// type was renamed to `ActivityLogSnapshot` (see the comment above its declaration
// in AgentActivityEvent.swift) to free up `ActivityTreeSnapshot` for this ticket's
// SidebarTree-wrapping envelope, exactly as ticket 11 names it. This is the one
// change fix-round-2 made outside SidebarTree.swift; the ticket's file fence assumed
// no prior claim on the name existed, which was not the case.
//
// No public initializer is declared here: the only construction paths are `make(...)`
// below and `init(from:)` (JSON decoding), both of which derive `rollup` from the tree
// rather than accepting it as an arbitrary argument. This keeps the invariant that
// `rollup` can never disagree with the tree's tile statuses.
//
// fix-round-3: the synthesized `Codable` this struct originally relied on gave decoding
// a THIRD construction path — `init(from:)` synthesized from `Decodable` decodes whatever
// `rollup` bytes are present in the JSON verbatim, so a hand-edited or foreign
// `ActivityTreeSnapshot` document could decode with a `rollup` that disagrees with its own
// `tree`. `init(from:)` is now written by hand: it still requires a well-formed `rollup`
// key to be present (so malformed/missing-field JSON still fails to decode), but it
// discards the decoded value and recomputes `rollup` from the decoded `tree` via the same
// `deriveRollup(from:)` helper `make(...)` uses. This closes the gap non-tautologically —
// see the negative-fixture decode test in SidebarActivityTreeSnapshotTests.swift, which
// decodes JSON carrying a deliberately wrong `rollup` and asserts the decoded value is the
// correctly-derived one, not the tampered bytes.
public struct ActivityTreeSnapshot: Codable, Equatable, Sendable {
    public let tree: SidebarTree
    public let capturedAt: Date          // file-mtime clock, not Date.now()
    public let replicaId: String         // stable device id; empty string in tests
    public let rollup: SidebarAgentStatusRollup   // derived at construction, not stored raw

    public static func make(
        tree: SidebarTree,
        capturedAt: Date,
        replicaId: String
    ) -> ActivityTreeSnapshot {
        ActivityTreeSnapshot(tree: tree, capturedAt: capturedAt, replicaId: replicaId, rollup: deriveRollup(from: tree))
    }

    // Shared by `make(...)` and `init(from:)` so both construction paths — normal
    // construction and JSON decoding — produce a rollup that can never disagree with
    // the tree.
    private static func deriveRollup(from tree: SidebarTree) -> SidebarAgentStatusRollup {
        let allStatuses = tree.workspaces
            .flatMap(\.zones)
            .flatMap(\.tiles)
            .compactMap(\.agentStatus)
        return SidebarAgentStatusRollup.make(statuses: allStatuses)
    }

    private init(tree: SidebarTree, capturedAt: Date, replicaId: String, rollup: SidebarAgentStatusRollup) {
        self.tree = tree
        self.capturedAt = capturedAt
        self.replicaId = replicaId
        self.rollup = rollup
    }

    private enum CodingKeys: String, CodingKey {
        case tree, capturedAt, replicaId, rollup
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tree = try container.decode(SidebarTree.self, forKey: .tree)
        self.tree = tree
        self.capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        self.replicaId = try container.decode(String.self, forKey: .replicaId)
        // Require a well-formed `rollup` key (so truncated/malformed JSON still fails
        // to decode) but ignore its value and recompute from `tree` instead — see the
        // comment above the struct for why.
        _ = try container.decode(SidebarAgentStatusRollup.self, forKey: .rollup)
        self.rollup = Self.deriveRollup(from: tree)
    }
}

public enum SidebarTreeBuilder {
    public static func build(
        registry: Registry,
        documents: [UUID: WorkspaceDocument],
        projectCanvases: [UUID: CanvasState] = [:],
        agentStatusesByTileId: [UUID: AgentStatus] = [:]
    ) -> SidebarTree {
        let workspaceRows = registry.workspaces.map { entry -> SidebarWorkspaceRow in
            let zones: [SidebarZoneRow]
            if let document = documents[entry.id] {
                // Zone order derives from each placement's zPosition register
                // (ticket 04) — the same (zPosition, zoneId) sort the canvas uses.
                let sorted = document.zonesInZOrder
                zones = sorted.map { placement -> SidebarZoneRow in
                    let name: String
                    if let projectId = placement.projectId {
                        name = registry.projects.first(where: { $0.id == projectId })?.name ?? ""
                    } else {
                        name = placement.name
                    }
                    let zoneTiles = tiles(for: placement, document: document, projectCanvases: projectCanvases)
                    let tiles = zoneTiles.map { tile in
                        SidebarTileRow(tileId: tile.id, title: tile.title, kind: tile.kind, agentStatus: agentStatusesByTileId[tile.id])
                    }
                    let rollup = SidebarAgentStatusRollup.make(statuses: zoneTiles.compactMap { agentStatusesByTileId[$0.id] })
                    return SidebarZoneRow(
                        zoneId: placement.zoneId,
                        name: name,
                        color: placement.color,
                        navKey: placement.navKey,
                        collapsed: placement.collapsed,
                        projectId: placement.projectId,
                        agentStatusRollup: rollup,
                        tiles: tiles
                    )
                }
            } else {
                zones = []
            }
            return SidebarWorkspaceRow(workspaceId: entry.id, name: entry.name, zones: zones)
        }
        return SidebarTree(workspaces: workspaceRows)
    }

    public static func build(
        registry: Registry,
        documents: [UUID: WorkspaceDocument],
        projectCanvases: [UUID: CanvasState] = [:],
        agentSnapshots: [UUID: AgentSnapshot]
    ) -> SidebarTree {
        // Derive the agentStatusesByTileId map from snapshots so the existing
        // build path handles all the zone/tile assembly logic unchanged.
        let statusMap = agentSnapshots.mapValues(\.status)
        // Re-use the existing builder to produce the tree structure.
        var tree = build(
            registry: registry,
            documents: documents,
            projectCanvases: projectCanvases,
            agentStatusesByTileId: statusMap
        )
        // Thread evidence into each tile row. Walk every tile by id and attach.
        for wi in tree.workspaces.indices {
            for zi in tree.workspaces[wi].zones.indices {
                for ti in tree.workspaces[wi].zones[zi].tiles.indices {
                    let tileId = tree.workspaces[wi].zones[zi].tiles[ti].tileId
                    tree.workspaces[wi].zones[zi].tiles[ti].evidence =
                        agentSnapshots[tileId]?.evidence
                }
            }
        }
        return tree
    }

    private static func tiles(for placement: ZonePlacement, document: WorkspaceDocument, projectCanvases: [UUID: CanvasState]) -> [Tile] {
        var tiles = document.tiles(forZone: placement.zoneId)
        if let projectId = placement.projectId, let canvas = projectCanvases[projectId] {
            let existing = Set(tiles.map(\.id))
            let projectTiles = canvas.tiles.filter { tileCenter($0).isInside(zone: placement) }
            tiles.append(contentsOf: projectTiles.filter { !existing.contains($0.id) })
        }
        return tiles
    }

    private static func tileCenter(_ tile: Tile) -> ZonePoint {
        ZonePoint(x: tile.frame.x + tile.frame.width / 2, y: tile.frame.y + tile.frame.height / 2)
    }
}

private extension ZonePoint {
    func isInside(zone: ZonePlacement) -> Bool {
        let frame = CanvasEngine.zoneWorldFrame(zone)
        return x >= frame.x && x <= frame.x + frame.width && y >= frame.y && y <= frame.y + frame.height
    }
}

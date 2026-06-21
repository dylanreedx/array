import Foundation

public enum SidebarAgentStatusKind: String, Equatable, Sendable {
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

public struct SidebarAgentStatusRollup: Equatable, Sendable {
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

public struct SidebarTileRow: Equatable, Sendable {
    public let tileId: UUID
    public let title: String
    public let kind: TileKind
    public let agentStatus: AgentStatus?

    public init(tileId: UUID, title: String, kind: TileKind, agentStatus: AgentStatus? = nil) {
        self.tileId = tileId
        self.title = title
        self.kind = kind
        self.agentStatus = agentStatus
    }
}

public struct SidebarZoneRow: Equatable, Sendable {
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

public struct SidebarWorkspaceRow: Equatable, Sendable {
    public let workspaceId: UUID
    public let name: String
    public var zones: [SidebarZoneRow]

    public init(workspaceId: UUID, name: String, zones: [SidebarZoneRow]) {
        self.workspaceId = workspaceId
        self.name = name
        self.zones = zones
    }
}

public struct SidebarTree: Equatable, Sendable {
    public var workspaces: [SidebarWorkspaceRow]

    public init(workspaces: [SidebarWorkspaceRow]) {
        self.workspaces = workspaces
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
                let zOrderIndex = Dictionary(
                    uniqueKeysWithValues: document.zoneZOrder.enumerated().map { ($0.element, $0.offset) }
                )
                let sorted = document.zones.sorted { a, b in
                    let ia = zOrderIndex[a.zoneId] ?? Int.min
                    let ib = zOrderIndex[b.zoneId] ?? Int.min
                    if ia != ib { return ia < ib }
                    return a.zoneId.uuidString < b.zoneId.uuidString
                }
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

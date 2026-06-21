import Foundation

public struct SidebarTileRow: Equatable, Sendable {
    public let tileId: UUID
    public let title: String
    public let kind: TileKind

    public init(tileId: UUID, title: String, kind: TileKind) {
        self.tileId = tileId
        self.title = title
        self.kind = kind
    }
}

public struct SidebarZoneRow: Equatable, Sendable {
    public let zoneId: UUID
    public let name: String
    public let color: String
    public let navKey: String?
    public let collapsed: Bool
    public let projectId: UUID?
    public var tiles: [SidebarTileRow]

    public init(zoneId: UUID, name: String, color: String, navKey: String?, collapsed: Bool, projectId: UUID?, tiles: [SidebarTileRow] = []) {
        self.zoneId = zoneId
        self.name = name
        self.color = color
        self.navKey = navKey
        self.collapsed = collapsed
        self.projectId = projectId
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
    public static func build(registry: Registry, documents: [UUID: WorkspaceDocument]) -> SidebarTree {
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
                    let tiles = document.tiles(forZone: placement.zoneId).map { tile in
                        SidebarTileRow(tileId: tile.id, title: tile.title, kind: tile.kind)
                    }
                    return SidebarZoneRow(
                        zoneId: placement.zoneId,
                        name: name,
                        color: placement.color,
                        navKey: placement.navKey,
                        collapsed: placement.collapsed,
                        projectId: placement.projectId,
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
}

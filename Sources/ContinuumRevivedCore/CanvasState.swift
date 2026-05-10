import Foundation

public struct CanvasState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public var viewport: CanvasViewport
    public var tiles: [Tile]
    public var groups: [TileGroup]
    public var lastActiveTileId: UUID?

    public init(
        schemaVersion: Int = CanvasState.currentSchemaVersion,
        viewport: CanvasViewport,
        tiles: [Tile],
        groups: [TileGroup],
        lastActiveTileId: UUID?
    ) {
        self.schemaVersion = schemaVersion
        self.viewport = viewport
        self.tiles = tiles
        self.groups = groups
        self.lastActiveTileId = lastActiveTileId
    }
}

public struct CanvasViewport: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var zoom: Double

    public init(x: Double, y: Double, zoom: Double) {
        self.x = x
        self.y = y
        self.zoom = zoom
    }
}

public struct Tile: Codable, Equatable, Sendable {
    public let id: UUID
    public var kind: TileKind
    public var title: String
    public var frame: TileFrame
    public var zIndex: Int
    public var runtimeRef: RuntimeRef?
    public var metadata: TileMetadata

    public init(
        id: UUID,
        kind: TileKind,
        title: String,
        frame: TileFrame,
        zIndex: Int,
        runtimeRef: RuntimeRef?,
        metadata: TileMetadata
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.frame = frame
        self.zIndex = zIndex
        self.runtimeRef = runtimeRef
        self.metadata = metadata
    }
}

public enum TileKind: String, Codable, Equatable, Sendable {
    case terminal
    case browser
    case note
    case file
    case fileTree
}

public struct TileFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct RuntimeRef: Codable, Equatable, Sendable {
    public var kind: RuntimeRefKind
    public var id: UUID

    public init(kind: RuntimeRefKind, id: UUID) {
        self.kind = kind
        self.id = id
    }
}

public enum RuntimeRefKind: String, Codable, Equatable, Sendable {
    case terminalSession
    case browserTile
    case note
    case file
}

public struct TileMetadata: Codable, Equatable, Sendable {
    public var launchProfileId: String?
    public var projectRelativeCwd: String?
    public var url: String?
    public var noteId: UUID?
    public var filePath: String?

    public init(
        launchProfileId: String? = nil,
        projectRelativeCwd: String? = nil,
        url: String? = nil,
        noteId: UUID? = nil,
        filePath: String? = nil
    ) {
        self.launchProfileId = launchProfileId
        self.projectRelativeCwd = projectRelativeCwd
        self.url = url
        self.noteId = noteId
        self.filePath = filePath
    }

    private enum CodingKeys: String, CodingKey {
        case launchProfileId
        case projectRelativeCwd
        case url
        case noteId
        case filePath
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(launchProfileId, forKey: .launchProfileId)
        try container.encodeIfPresent(projectRelativeCwd, forKey: .projectRelativeCwd)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(noteId, forKey: .noteId)
        try container.encodeIfPresent(filePath, forKey: .filePath)
    }
}

public struct TileGroup: Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var tileIds: [UUID]
    public var color: String
    public var collapsed: Bool

    public init(id: UUID, title: String, tileIds: [UUID], color: String, collapsed: Bool) {
        self.id = id
        self.title = title
        self.tileIds = tileIds
        self.color = color
        self.collapsed = collapsed
    }
}

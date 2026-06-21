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

public enum TileKind: String, Codable, Equatable, Sendable, CaseIterable {
    case terminal
    case browser
    case browserInspector
    case note
    case file
    case fileTree
    case ticketQueue
    case conductorQueue
    case diffReview
    case runArtifacts
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
    public var browserProfileId: UUID?
    public var linearTeamKey: String?
    public var linearTeamId: String?
    public var linearQuery: String?
    public var reviewId: UUID?
    public var diffSource: String?
    public var baseBranch: String?
    public var branch: String?

    public init(
        launchProfileId: String? = nil,
        projectRelativeCwd: String? = nil,
        url: String? = nil,
        noteId: UUID? = nil,
        filePath: String? = nil,
        browserProfileId: UUID? = nil,
        linearTeamKey: String? = nil,
        linearTeamId: String? = nil,
        linearQuery: String? = nil,
        reviewId: UUID? = nil,
        diffSource: String? = nil,
        baseBranch: String? = nil,
        branch: String? = nil
    ) {
        self.launchProfileId = launchProfileId
        self.projectRelativeCwd = projectRelativeCwd
        self.url = url
        self.noteId = noteId
        self.filePath = filePath
        self.browserProfileId = browserProfileId
        self.linearTeamKey = linearTeamKey
        self.linearTeamId = linearTeamId
        self.linearQuery = linearQuery
        self.reviewId = reviewId
        self.diffSource = diffSource
        self.baseBranch = baseBranch
        self.branch = branch
    }

    private enum CodingKeys: String, CodingKey {
        case launchProfileId
        case projectRelativeCwd
        case url
        case noteId
        case filePath
        case browserProfileId
        case linearTeamKey
        case linearTeamId
        case linearQuery
        case reviewId
        case diffSource
        case baseBranch
        case branch
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(launchProfileId, forKey: .launchProfileId)
        try container.encodeIfPresent(projectRelativeCwd, forKey: .projectRelativeCwd)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(noteId, forKey: .noteId)
        try container.encodeIfPresent(filePath, forKey: .filePath)
        try container.encodeIfPresent(browserProfileId, forKey: .browserProfileId)
        try container.encodeIfPresent(linearTeamKey, forKey: .linearTeamKey)
        try container.encodeIfPresent(linearTeamId, forKey: .linearTeamId)
        try container.encodeIfPresent(linearQuery, forKey: .linearQuery)
        try container.encodeIfPresent(reviewId, forKey: .reviewId)
        try container.encodeIfPresent(diffSource, forKey: .diffSource)
        try container.encodeIfPresent(baseBranch, forKey: .baseBranch)
        try container.encodeIfPresent(branch, forKey: .branch)
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

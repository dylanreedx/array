import Foundation

public struct BrowserState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public var tiles: [BrowserTile]

    public init(schemaVersion: Int = BrowserState.currentSchemaVersion, tiles: [BrowserTile]) {
        self.schemaVersion = schemaVersion
        self.tiles = tiles
    }
}

public struct BrowserTile: Codable, Equatable, Sendable {
    public let id: UUID
    public let tileId: UUID
    public var url: String
    public var title: String
    public var storageGroupId: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        tileId: UUID,
        url: String,
        title: String,
        storageGroupId: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.tileId = tileId
        self.url = url
        self.title = title
        self.storageGroupId = storageGroupId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

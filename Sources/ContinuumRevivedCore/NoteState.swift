import Foundation

public struct NoteState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public var tiles: [NoteTile]
    public init(schemaVersion: Int = NoteState.currentSchemaVersion, tiles: [NoteTile]) {
        self.schemaVersion = schemaVersion
        self.tiles = tiles
    }
}

public struct NoteTile: Codable, Equatable, Sendable {
    public let id: UUID
    public let tileId: UUID
    public var filename: String
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    public init(id: UUID, tileId: UUID, filename: String, title: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.tileId = tileId
        self.filename = filename
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

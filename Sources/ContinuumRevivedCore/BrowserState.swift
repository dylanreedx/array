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

extension BrowserState {
    /// Sentinel storage group id used by `BrowserStoragePolicy.shared`. The app
    /// layer maps this to `WKWebsiteDataStore.default()`; any other value is
    /// expected to parse as a UUID and feed `WKWebsiteDataStore(forIdentifier:)`.
    public static let sharedStorageGroupId: String = "shared"

    /// Resolves the storage group identifier for a project's browser-tile storage
    /// policy. `.perProject` returns the project's UUID string (stable across
    /// relaunches and unique per project). `.shared` returns the sentinel
    /// `sharedStorageGroupId`. Pure function — no I/O, no AppKit, no WebKit.
    public static func storageGroupIdentifier(for project: Project) -> String {
        switch project.settings.browserStoragePolicy {
        case .perProject:
            return project.id.uuidString
        case .shared:
            return sharedStorageGroupId
        }
    }
}

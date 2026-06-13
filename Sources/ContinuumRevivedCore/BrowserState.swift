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
    public var profileId: UUID
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        tileId: UUID,
        url: String,
        title: String,
        storageGroupId: String,
        profileId: UUID = BrowserProfile.defaultProfileId,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.tileId = tileId
        self.url = url
        self.title = title
        self.storageGroupId = storageGroupId
        self.profileId = profileId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, tileId, url, title, storageGroupId, profileId, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        tileId = try container.decode(UUID.self, forKey: .tileId)
        url = try container.decode(String.self, forKey: .url)
        title = try container.decode(String.self, forKey: .title)
        storageGroupId = try container.decode(String.self, forKey: .storageGroupId)
        profileId = try container.decodeIfPresent(UUID.self, forKey: .profileId) ?? BrowserProfile.defaultProfileId
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
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

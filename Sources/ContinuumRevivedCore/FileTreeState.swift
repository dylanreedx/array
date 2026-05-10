import Foundation

public struct FileTreeState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public var tiles: [FileTreeTile]

    public init(schemaVersion: Int = FileTreeState.currentSchemaVersion, tiles: [FileTreeTile]) {
        self.schemaVersion = schemaVersion
        self.tiles = tiles
    }
}

public struct FileTreeTile: Codable, Equatable, Sendable {
    public var tileId: UUID
    public var rootPath: String
    public var expandedPaths: [String]
    public var selectedPath: String?
    public var searchQuery: String
    public var ignoredNames: [String]
    public var gitBadges: FileTreeGitBadgeMode

    public init(
        tileId: UUID,
        rootPath: String,
        expandedPaths: [String],
        selectedPath: String?,
        searchQuery: String,
        ignoredNames: [String],
        gitBadges: FileTreeGitBadgeMode
    ) {
        self.tileId = tileId
        self.rootPath = rootPath
        self.expandedPaths = expandedPaths
        self.selectedPath = selectedPath
        self.searchQuery = searchQuery
        self.ignoredNames = ignoredNames
        self.gitBadges = gitBadges
    }
}

public struct FileTreeNode: Codable, Equatable, Sendable {
    public var relativePath: String
    public var displayName: String
    public var isDirectory: Bool
    public var childCount: Int
    public var isIgnored: Bool
    public var gitStatus: FileTreeGitStatus?

    public init(
        relativePath: String,
        displayName: String,
        isDirectory: Bool,
        childCount: Int,
        isIgnored: Bool,
        gitStatus: FileTreeGitStatus?
    ) {
        self.relativePath = relativePath
        self.displayName = displayName
        self.isDirectory = isDirectory
        self.childCount = childCount
        self.isIgnored = isIgnored
        self.gitStatus = gitStatus
    }
}

public enum FileTreeGitBadgeMode: String, Codable, Equatable, Sendable {
    case off
    case cheap
}

public enum FileTreeGitStatus: String, Codable, Equatable, Sendable {
    case untracked
    case modified
    case added
    case deleted
    case renamed
    case conflicted
}

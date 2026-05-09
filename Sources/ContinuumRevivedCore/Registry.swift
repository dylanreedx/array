import Foundation

public struct Registry: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public var lastActiveWorkspaceId: UUID?
    public var lastActiveProjectId: UUID?
    public var workspaces: [WorkspaceEntry]
    public var projects: [ProjectEntry]
    public var settings: RegistrySettings

    public init(
        schemaVersion: Int = Registry.currentSchemaVersion,
        lastActiveWorkspaceId: UUID?,
        lastActiveProjectId: UUID?,
        workspaces: [WorkspaceEntry],
        projects: [ProjectEntry],
        settings: RegistrySettings
    ) {
        self.schemaVersion = schemaVersion
        self.lastActiveWorkspaceId = lastActiveWorkspaceId
        self.lastActiveProjectId = lastActiveProjectId
        self.workspaces = workspaces
        self.projects = projects
        self.settings = settings
    }

    public static func empty() -> Registry {
        Registry(
            lastActiveWorkspaceId: nil,
            lastActiveProjectId: nil,
            workspaces: [],
            projects: [],
            settings: RegistrySettings(
                preferredEditor: .auto,
                zoomModifier: .command,
                openLastProjectOnLaunch: true
            )
        )
    }
}

public struct WorkspaceEntry: Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var projectIds: [UUID]
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        name: String,
        projectIds: [UUID],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.projectIds = projectIds
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ProjectEntry: Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var rootPath: String
    public var workspaceId: UUID?
    public var lastOpenedAt: Date
    public var pinned: Bool

    public init(
        id: UUID,
        name: String,
        rootPath: String,
        workspaceId: UUID?,
        lastOpenedAt: Date,
        pinned: Bool
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.workspaceId = workspaceId
        self.lastOpenedAt = lastOpenedAt
        self.pinned = pinned
    }
}

public struct RegistrySettings: Codable, Equatable, Sendable {
    public var preferredEditor: EditorPreference
    public var zoomModifier: ZoomModifier
    public var openLastProjectOnLaunch: Bool

    public init(
        preferredEditor: EditorPreference,
        zoomModifier: ZoomModifier,
        openLastProjectOnLaunch: Bool
    ) {
        self.preferredEditor = preferredEditor
        self.zoomModifier = zoomModifier
        self.openLastProjectOnLaunch = openLastProjectOnLaunch
    }
}

public enum ZoomModifier: String, Codable, Equatable, Sendable {
    case command
    case option
    case control
}

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

    public mutating func upsertProject(_ project: Project, openedAt: Date) {
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects[idx].name = project.name
            projects[idx].rootPath = project.rootPath
            projects[idx].lastOpenedAt = openedAt
            projects[idx].missing = false
        } else {
            projects.append(ProjectEntry(
                id: project.id,
                name: project.name,
                rootPath: project.rootPath,
                workspaceId: nil,
                lastOpenedAt: openedAt,
                pinned: false,
                missing: false
            ))
        }
        lastActiveProjectId = project.id
    }

    @discardableResult
    public mutating func selectProjectForNextLaunch(id: UUID) -> Bool {
        guard projects.contains(where: { $0.id == id }) else { return false }
        lastActiveProjectId = id
        return true
    }

    @discardableResult
    public mutating func markProjectMissingStatus(
        directoryExists: @Sendable (String) -> Bool
    ) -> [UUID] {
        var changed: [UUID] = []
        for idx in projects.indices {
            let shouldBeMissing = !directoryExists(projects[idx].rootPath)
            if projects[idx].missing != shouldBeMissing {
                projects[idx].missing = shouldBeMissing
                changed.append(projects[idx].id)
            }
        }
        return changed
    }

    @discardableResult
    public mutating func repairProjectPath(id: UUID, newRootPath: String) -> Bool {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return false }
        projects[idx].rootPath = newRootPath
        projects[idx].missing = false
        return true
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
    public var missing: Bool

    public init(
        id: UUID,
        name: String,
        rootPath: String,
        workspaceId: UUID?,
        lastOpenedAt: Date,
        pinned: Bool,
        missing: Bool = false
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.workspaceId = workspaceId
        self.lastOpenedAt = lastOpenedAt
        self.pinned = pinned
        self.missing = missing
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, rootPath, workspaceId, lastOpenedAt, pinned, missing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        workspaceId = try container.decodeIfPresent(UUID.self, forKey: .workspaceId)
        lastOpenedAt = try container.decode(Date.self, forKey: .lastOpenedAt)
        pinned = try container.decode(Bool.self, forKey: .pinned)
        missing = try container.decodeIfPresent(Bool.self, forKey: .missing) ?? false
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

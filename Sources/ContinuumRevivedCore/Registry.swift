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
    public var linearTicketQueue: LinearTicketQueueConfig?

    public init(
        id: UUID,
        name: String,
        rootPath: String,
        workspaceId: UUID?,
        lastOpenedAt: Date,
        pinned: Bool,
        missing: Bool = false,
        linearTicketQueue: LinearTicketQueueConfig? = nil
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.workspaceId = workspaceId
        self.lastOpenedAt = lastOpenedAt
        self.pinned = pinned
        self.missing = missing
        self.linearTicketQueue = linearTicketQueue
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, rootPath, workspaceId, lastOpenedAt, pinned, missing, linearTicketQueue
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
        linearTicketQueue = try container.decodeIfPresent(LinearTicketQueueConfig.self, forKey: .linearTicketQueue)
    }
}

public struct BrowserProfile: Codable, Equatable, Sendable {
    public static let defaultProfileId = UUID(uuidString: "B0000000-0000-4000-8000-000000000001")!
    public static let defaultDataStoreIdentifier = UUID(uuidString: "B0000000-0000-4000-8000-000000000002")!.uuidString
    public static let defaultCreatedAt = Date(timeIntervalSince1970: 0)

    public let id: UUID
    public var name: String
    public var dataStoreIdentifier: String
    public let createdAt: Date

    public init(id: UUID, name: String, dataStoreIdentifier: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.dataStoreIdentifier = dataStoreIdentifier
        self.createdAt = createdAt
    }

    public static func builtInDefault() -> BrowserProfile {
        BrowserProfile(
            id: defaultProfileId,
            name: "Default",
            dataStoreIdentifier: defaultDataStoreIdentifier,
            createdAt: defaultCreatedAt
        )
    }
}

public struct RegistrySettings: Codable, Equatable, Sendable {
    public var preferredEditor: EditorPreference
    public var zoomModifier: ZoomModifier
    public var openLastProjectOnLaunch: Bool
    public var browserProfiles: [BrowserProfile]
    public var defaultBrowserProfileId: UUID

    public init(
        preferredEditor: EditorPreference,
        zoomModifier: ZoomModifier,
        openLastProjectOnLaunch: Bool,
        browserProfiles: [BrowserProfile] = [BrowserProfile.builtInDefault()],
        defaultBrowserProfileId: UUID = BrowserProfile.defaultProfileId
    ) {
        self.preferredEditor = preferredEditor
        self.zoomModifier = zoomModifier
        self.openLastProjectOnLaunch = openLastProjectOnLaunch
        self.browserProfiles = RegistrySettings.normalizedBrowserProfiles(browserProfiles)
        if self.browserProfiles.contains(where: { $0.id == defaultBrowserProfileId }) {
            self.defaultBrowserProfileId = defaultBrowserProfileId
        } else {
            self.defaultBrowserProfileId = BrowserProfile.defaultProfileId
        }
    }

    private enum CodingKeys: String, CodingKey {
        case preferredEditor, zoomModifier, openLastProjectOnLaunch, browserProfiles, defaultBrowserProfileId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preferredEditor = try container.decode(EditorPreference.self, forKey: .preferredEditor)
        zoomModifier = try container.decode(ZoomModifier.self, forKey: .zoomModifier)
        openLastProjectOnLaunch = try container.decode(Bool.self, forKey: .openLastProjectOnLaunch)
        browserProfiles = RegistrySettings.normalizedBrowserProfiles(
            try container.decodeIfPresent([BrowserProfile].self, forKey: .browserProfiles) ?? []
        )
        let decodedDefaultId = try container.decodeIfPresent(UUID.self, forKey: .defaultBrowserProfileId)
        if let decodedDefaultId, browserProfiles.contains(where: { $0.id == decodedDefaultId }) {
            defaultBrowserProfileId = decodedDefaultId
        } else {
            defaultBrowserProfileId = BrowserProfile.defaultProfileId
        }
    }

    @discardableResult
    public mutating func upsertBrowserProfile(_ profile: BrowserProfile) -> Bool {
        guard profile.id != BrowserProfile.defaultProfileId,
              UUID(uuidString: profile.dataStoreIdentifier) != nil else {
            return false
        }
        if let index = browserProfiles.firstIndex(where: { $0.id == profile.id }) {
            browserProfiles[index] = profile
        } else {
            browserProfiles.append(profile)
        }
        return true
    }

    @discardableResult
    public mutating func deleteBrowserProfile(id: UUID) -> Bool {
        guard id != BrowserProfile.defaultProfileId,
              let index = browserProfiles.firstIndex(where: { $0.id == id }) else {
            return false
        }
        browserProfiles.remove(at: index)
        if defaultBrowserProfileId == id {
            defaultBrowserProfileId = BrowserProfile.defaultProfileId
        }
        return true
    }

    @discardableResult
    public mutating func setDefaultBrowserProfile(id: UUID) -> Bool {
        guard browserProfiles.contains(where: { $0.id == id }) else { return false }
        defaultBrowserProfileId = id
        return true
    }

    private static func normalizedBrowserProfiles(_ profiles: [BrowserProfile]) -> [BrowserProfile] {
        var normalized = profiles.filter { profile in
            profile.id == BrowserProfile.defaultProfileId || UUID(uuidString: profile.dataStoreIdentifier) != nil
        }
        if let defaultIndex = normalized.firstIndex(where: { $0.id == BrowserProfile.defaultProfileId }) {
            normalized[defaultIndex] = BrowserProfile.builtInDefault()
        } else {
            normalized.insert(BrowserProfile.builtInDefault(), at: 0)
        }
        return normalized
    }
}

public enum ZoomModifier: String, Codable, Equatable, Sendable {
    case command
    case option
    case control
}

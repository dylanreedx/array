import Foundation

public struct Project: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let id: UUID
    public let name: String
    public let rootPath: String
    public let createdAt: Date
    public let updatedAt: Date
    public let defaultLaunchProfileId: String
    public let editorPreference: EditorPreference
    public let settings: ProjectSettings
    public let remoteEnvironment: RemoteEnvironment?

    public init(
        schemaVersion: Int = Project.currentSchemaVersion,
        id: UUID = UUID(),
        name: String,
        rootPath: String,
        createdAt: Date,
        updatedAt: Date,
        defaultLaunchProfileId: String,
        editorPreference: EditorPreference,
        settings: ProjectSettings,
        remoteEnvironment: RemoteEnvironment? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.defaultLaunchProfileId = defaultLaunchProfileId
        self.editorPreference = editorPreference
        self.settings = settings
        self.remoteEnvironment = remoteEnvironment
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, rootPath, createdAt, updatedAt, defaultLaunchProfileId, editorPreference, settings, remoteEnvironment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        defaultLaunchProfileId = try container.decode(String.self, forKey: .defaultLaunchProfileId)
        editorPreference = try container.decode(EditorPreference.self, forKey: .editorPreference)
        settings = try container.decode(ProjectSettings.self, forKey: .settings)
        remoteEnvironment = try container.decodeIfPresent(RemoteEnvironment.self, forKey: .remoteEnvironment)
    }
}

public enum EditorPreference: String, Codable, Equatable, Sendable {
    case auto
    case nvim
    case cursor
    case code
    case zed
    case xcode
    case custom
}

public struct ProjectSettings: Codable, Equatable, Sendable {
    public let restorePolicy: RestorePolicy
    public let browserStoragePolicy: BrowserStoragePolicy
    public let terminalClosePolicy: TerminalClosePolicy
    public let defaultBrowserProfileId: UUID

    public init(
        restorePolicy: RestorePolicy,
        browserStoragePolicy: BrowserStoragePolicy,
        terminalClosePolicy: TerminalClosePolicy,
        defaultBrowserProfileId: UUID = BrowserProfile.defaultProfileId
    ) {
        self.restorePolicy = restorePolicy
        self.browserStoragePolicy = browserStoragePolicy
        self.terminalClosePolicy = terminalClosePolicy
        self.defaultBrowserProfileId = defaultBrowserProfileId
    }

    private enum CodingKeys: String, CodingKey {
        case restorePolicy, browserStoragePolicy, terminalClosePolicy, defaultBrowserProfileId
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        restorePolicy = try container.decode(RestorePolicy.self, forKey: .restorePolicy)
        browserStoragePolicy = try container.decode(BrowserStoragePolicy.self, forKey: .browserStoragePolicy)
        terminalClosePolicy = try container.decode(TerminalClosePolicy.self, forKey: .terminalClosePolicy)
        defaultBrowserProfileId = try container.decodeIfPresent(UUID.self, forKey: .defaultBrowserProfileId) ?? BrowserProfile.defaultProfileId
    }
}

public enum RestorePolicy: String, Codable, Equatable, Sendable {
    case restoreDescriptors
    case restoreNothing
}

public enum BrowserStoragePolicy: String, Codable, Equatable, Sendable {
    case perProject
    case shared
}

public enum TerminalClosePolicy: String, Codable, Equatable, Sendable {
    case askWhenRunning
    case alwaysAsk
    case neverAsk
}

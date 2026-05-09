import Foundation

public struct Project: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let name: String
    public let rootPath: String
    public let createdAt: Date
    public let updatedAt: Date
    public let defaultLaunchProfileId: String
    public let editorPreference: EditorPreference
    public let settings: ProjectSettings

    public init(
        schemaVersion: Int = Project.currentSchemaVersion,
        id: UUID = UUID(),
        name: String,
        rootPath: String,
        createdAt: Date,
        updatedAt: Date,
        defaultLaunchProfileId: String,
        editorPreference: EditorPreference,
        settings: ProjectSettings
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

    public init(
        restorePolicy: RestorePolicy,
        browserStoragePolicy: BrowserStoragePolicy,
        terminalClosePolicy: TerminalClosePolicy
    ) {
        self.restorePolicy = restorePolicy
        self.browserStoragePolicy = browserStoragePolicy
        self.terminalClosePolicy = terminalClosePolicy
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

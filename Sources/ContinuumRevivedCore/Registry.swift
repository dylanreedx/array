import Foundation

public struct Registry: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public var lastActiveWorkspaceId: UUID?
    public var lastActiveProjectId: UUID?
    public var workspaces: [WorkspaceEntry]
    public var projects: [ProjectEntry]
    public var settings: RegistrySettings
    public var pairedDevices: [PairedDeviceEntry]

    public init(
        schemaVersion: Int = Registry.currentSchemaVersion,
        lastActiveWorkspaceId: UUID?,
        lastActiveProjectId: UUID?,
        workspaces: [WorkspaceEntry],
        projects: [ProjectEntry],
        settings: RegistrySettings,
        pairedDevices: [PairedDeviceEntry] = []
    ) {
        self.schemaVersion = schemaVersion
        self.lastActiveWorkspaceId = lastActiveWorkspaceId
        self.lastActiveProjectId = lastActiveProjectId
        self.workspaces = workspaces
        self.projects = projects
        self.settings = settings
        self.pairedDevices = pairedDevices
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

    @discardableResult
    public mutating func createWorkspace(id: UUID = UUID(), name: String, now: Date) -> WorkspaceEntry {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = WorkspaceEntry(
            id: id,
            name: trimmed.isEmpty ? "Untitled Workspace" : trimmed,
            projectIds: [],
            createdAt: now,
            updatedAt: now
        )
        workspaces.append(entry)
        lastActiveWorkspaceId = id
        return entry
    }

    @discardableResult
    public mutating func renameWorkspace(id: UUID, name: String, now: Date) -> Bool {
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        workspaces[idx].name = trimmed
        workspaces[idx].updatedAt = now
        return true
    }

    /// Projects are workspace-owned, not shared layout ingredients. Legacy
    /// registries that name the same project from multiple workspaces are left
    /// untouched and reported so the user can explicitly move the project.
    public func validateExclusiveProjectOwnership() throws {
        var memberships: [UUID: [UUID]] = [:]
        for workspace in workspaces {
            for projectId in Set(workspace.projectIds) {
                memberships[projectId, default: []].append(workspace.id)
            }
        }
        for (projectId, workspaceIds) in memberships where workspaceIds.count > 1 {
            throw ProjectWorkspaceOwnershipError.duplicateMembership(
                projectId: projectId,
                workspaceIds: workspaceIds.sorted { $0.uuidString < $1.uuidString })
        }
        for project in projects {
            let membership = memberships[project.id]?.first
            if let declared = project.workspaceId, let membership, declared != membership {
                throw ProjectWorkspaceOwnershipError.ownerMismatch(
                    projectId: project.id, declaredWorkspaceId: declared, membershipWorkspaceId: membership)
            }
        }
    }

    public func exclusiveWorkspaceOwner(of projectId: UUID) throws -> UUID? {
        try validateExclusiveProjectOwnership()
        guard let project = projects.first(where: { $0.id == projectId }) else {
            throw ProjectWorkspaceOwnershipError.unknownProject(projectId)
        }
        let membership = workspaces.first(where: { $0.projectIds.contains(projectId) })?.id
        return project.workspaceId ?? membership
    }

    /// Add an unowned project to a workspace. A project already owned elsewhere
    /// requires the explicit move API; this method never rewrites ownership.
    public mutating func assignProject(_ projectId: UUID, to workspaceId: UUID, now: Date) throws {
        try validateExclusiveProjectOwnership()
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectId }) else {
            throw ProjectWorkspaceOwnershipError.unknownProject(projectId)
        }
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceId }) else {
            throw ProjectWorkspaceOwnershipError.unknownWorkspace(workspaceId)
        }
        if let owner = projects[projectIndex].workspaceId, owner != workspaceId {
            throw ProjectWorkspaceOwnershipError.alreadyOwned(
                projectId: projectId, workspaceId: owner)
        }
        if let membership = workspaces.first(where: { $0.projectIds.contains(projectId) })?.id,
           membership != workspaceId {
            throw ProjectWorkspaceOwnershipError.alreadyOwned(
                projectId: projectId, workspaceId: membership)
        }
        projects[projectIndex].workspaceId = workspaceId
        if !workspaces[workspaceIndex].projectIds.contains(projectId) {
            workspaces[workspaceIndex].projectIds.append(projectId)
        }
        workspaces[workspaceIndex].updatedAt = now
    }

    /// The only operation allowed to transfer ownership. Registry membership is
    /// committed together; callers transfer the workspace zones/documents around
    /// this explicit boundary rather than during an ordinary workspace switch.
    public mutating func moveProject(_ projectId: UUID, to workspaceId: UUID, now: Date) throws {
        try validateExclusiveProjectOwnership()
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectId }) else {
            throw ProjectWorkspaceOwnershipError.unknownProject(projectId)
        }
        guard let targetIndex = workspaces.firstIndex(where: { $0.id == workspaceId }) else {
            throw ProjectWorkspaceOwnershipError.unknownWorkspace(workspaceId)
        }
        for index in workspaces.indices {
            workspaces[index].projectIds.removeAll { $0 == projectId }
        }
        if !workspaces[targetIndex].projectIds.contains(projectId) {
            workspaces[targetIndex].projectIds.append(projectId)
        }
        workspaces[targetIndex].updatedAt = now
        projects[projectIndex].workspaceId = workspaceId
    }

    @discardableResult
    public mutating func deleteWorkspace(id: UUID, replacementId: UUID? = nil, now: Date) -> Bool {
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { return false }
        guard workspaces.count > 1 else { return false }
        let replacement = replacementId.flatMap { wanted in workspaces.contains(where: { $0.id == wanted && $0.id != id }) ? wanted : nil }
            ?? workspaces.first(where: { $0.id != id })?.id
        guard let replacement else { return false }

        let removedProjectIds = Set(workspaces[idx].projectIds)
        workspaces.remove(at: idx)
        for projectIndex in projects.indices
        where projects[projectIndex].workspaceId == id || removedProjectIds.contains(projects[projectIndex].id) {
            projects[projectIndex].workspaceId = nil
        }
        let replacementProjectIds = workspaces.first(where: { $0.id == replacement })?.projectIds ?? []
        for workspaceIdx in workspaces.indices where workspaces[workspaceIdx].id == replacement {
            workspaces[workspaceIdx].updatedAt = now
        }
        if lastActiveWorkspaceId == id {
            lastActiveWorkspaceId = replacement
        }
        if let activeProjectId = lastActiveProjectId, removedProjectIds.contains(activeProjectId) {
            lastActiveProjectId = replacementProjectIds.first
        }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, lastActiveWorkspaceId, lastActiveProjectId, workspaces, projects, settings, pairedDevices
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        lastActiveWorkspaceId = try container.decodeIfPresent(UUID.self, forKey: .lastActiveWorkspaceId)
        lastActiveProjectId = try container.decodeIfPresent(UUID.self, forKey: .lastActiveProjectId)
        workspaces = try container.decode([WorkspaceEntry].self, forKey: .workspaces)
        projects = try container.decode([ProjectEntry].self, forKey: .projects)
        settings = try container.decode(RegistrySettings.self, forKey: .settings)
        pairedDevices = try container.decodeIfPresent([PairedDeviceEntry].self, forKey: .pairedDevices) ?? []
    }
}

public enum ProjectWorkspaceOwnershipError: Error, Equatable, LocalizedError, Sendable {
    case duplicateMembership(projectId: UUID, workspaceIds: [UUID])
    case ownerMismatch(projectId: UUID, declaredWorkspaceId: UUID, membershipWorkspaceId: UUID)
    case alreadyOwned(projectId: UUID, workspaceId: UUID)
    case unknownProject(UUID)
    case unknownWorkspace(UUID)
    case workspaceDocumentMissing(projectId: UUID, workspaceId: UUID)

    public var errorDescription: String? {
        switch self {
        case let .duplicateMembership(projectId, workspaceIds):
            return "Project \(projectId) belongs to multiple workspaces (\(workspaceIds.map(\.uuidString).joined(separator: ", "))). Move it explicitly; no files or zones were changed."
        case let .ownerMismatch(projectId, declared, membership):
            return "Project \(projectId) declares workspace \(declared) but is listed in workspace \(membership). Move it explicitly; no files or zones were changed."
        case let .alreadyOwned(projectId, workspaceId):
            return "Project \(projectId) already belongs to workspace \(workspaceId). Move it explicitly to change ownership."
        case let .unknownProject(projectId):
            return "Unknown project \(projectId)."
        case let .unknownWorkspace(workspaceId):
            return "Unknown workspace \(workspaceId)."
        case let .workspaceDocumentMissing(projectId, workspaceId):
            return "Project \(projectId) belongs to workspace \(workspaceId), but that workspace document is missing. Ownership was not changed."
        }
    }
}

public struct PairedDeviceEntry: Codable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var scopes: Scope
    public var pairedAt: Date
    public var lastSeenAt: Date?

    public init(id: UUID, label: String, scopes: Scope, pairedAt: Date, lastSeenAt: Date?) {
        self.id = id
        self.label = label
        self.scopes = scopes
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
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
    public var worktreeOf: UUID?
    public var linearTicketQueue: LinearTicketQueueConfig?

    public init(
        id: UUID,
        name: String,
        rootPath: String,
        workspaceId: UUID?,
        lastOpenedAt: Date,
        pinned: Bool,
        missing: Bool = false,
        worktreeOf: UUID? = nil,
        linearTicketQueue: LinearTicketQueueConfig? = nil
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.workspaceId = workspaceId
        self.lastOpenedAt = lastOpenedAt
        self.pinned = pinned
        self.missing = missing
        self.worktreeOf = worktreeOf
        self.linearTicketQueue = linearTicketQueue
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, rootPath, workspaceId, lastOpenedAt, pinned, missing, worktreeOf, linearTicketQueue
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
        worktreeOf = try container.decodeIfPresent(UUID.self, forKey: .worktreeOf)
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
        self.browserProfiles = RegistrySettings.normalizedBrowserProfilesForApp(browserProfiles)
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
        browserProfiles = RegistrySettings.normalizedBrowserProfilesForApp(
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

    public static func normalizedBrowserProfilesForApp(_ profiles: [BrowserProfile]) -> [BrowserProfile] {
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

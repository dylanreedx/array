import Foundation

/// Provider-neutral, host-local inputs used to assemble `LocationSessionIndex` without
/// making provider routing material Codable. These summaries deliberately avoid Codable
/// conformance so absolute paths, transcript paths, provider session IDs, and routing
/// handles stay process-local.
public enum LocationSwitcherIndexAdapter {
    public struct ProjectSummary: Sendable {
        public var id: LocationIndexID
        public var label: String
        public var aliases: [String]
        public var rootPath: String?
        public var displayPath: String?
        public var workspaceID: LocationIndexID?
        public var workspaceName: String?
        public var gitBranch: String?
        public var gitWorktreeLabel: String?
        public var isDirty: Bool
        public var isWorkspaceProject: Bool
        public var lastUsedAt: Date?

        public init(id: LocationIndexID, label: String, aliases: [String] = [], rootPath: String? = nil, displayPath: String? = nil, workspaceID: LocationIndexID? = nil, workspaceName: String? = nil, gitBranch: String? = nil, gitWorktreeLabel: String? = nil, isDirty: Bool = false, isWorkspaceProject: Bool = false, lastUsedAt: Date? = nil) {
            self.id = id; self.label = label; self.aliases = aliases; self.rootPath = rootPath; self.displayPath = displayPath; self.workspaceID = workspaceID; self.workspaceName = workspaceName; self.gitBranch = gitBranch; self.gitWorktreeLabel = gitWorktreeLabel; self.isDirty = isDirty; self.isWorkspaceProject = isWorkspaceProject; self.lastUsedAt = lastUsedAt
        }
    }

    public struct WorkspaceSummary: Sendable {
        public var id: LocationIndexID
        public var name: String
        public var aliases: [String]
        public var path: String?
        public var displayPath: String?
        public var projectID: LocationIndexID?
        public var projectLabel: String?
        public var lastUsedAt: Date?

        public init(id: LocationIndexID, name: String, aliases: [String] = [], path: String? = nil, displayPath: String? = nil, projectID: LocationIndexID? = nil, projectLabel: String? = nil, lastUsedAt: Date? = nil) {
            self.id = id; self.name = name; self.aliases = aliases; self.path = path; self.displayPath = displayPath; self.projectID = projectID; self.projectLabel = projectLabel; self.lastUsedAt = lastUsedAt
        }
    }

    public struct AgentSummary: Sendable {
        public var id: LocationIndexID
        public var label: String
        public var aliases: [String]
        public var providerSessionID: String?
        public var transcriptPath: String?
        public var routingHandle: String?
        public var projectID: LocationIndexID?
        public var projectLabel: String?
        public var workspaceID: LocationIndexID?
        public var workspaceName: String?
        public var lastActivityAt: Date?
        public var isActive: Bool

        public init(id: LocationIndexID, label: String, aliases: [String] = [], providerSessionID: String? = nil, transcriptPath: String? = nil, routingHandle: String? = nil, projectID: LocationIndexID? = nil, projectLabel: String? = nil, workspaceID: LocationIndexID? = nil, workspaceName: String? = nil, lastActivityAt: Date? = nil, isActive: Bool = false) {
            self.id = id; self.label = label; self.aliases = aliases; self.providerSessionID = providerSessionID; self.transcriptPath = transcriptPath; self.routingHandle = routingHandle; self.projectID = projectID; self.projectLabel = projectLabel; self.workspaceID = workspaceID; self.workspaceName = workspaceName; self.lastActivityAt = lastActivityAt; self.isActive = isActive
        }
    }

    public struct SessionSummary: Sendable {
        public var id: LocationIndexID
        public var label: String
        public var aliases: [String]
        public var providerSessionID: String?
        public var transcriptPath: String?
        public var projectID: LocationIndexID?
        public var projectLabel: String?
        public var workspaceID: LocationIndexID?
        public var workspaceName: String?
        public var lastActivityAt: Date?

        public init(id: LocationIndexID, label: String, aliases: [String] = [], providerSessionID: String? = nil, transcriptPath: String? = nil, projectID: LocationIndexID? = nil, projectLabel: String? = nil, workspaceID: LocationIndexID? = nil, workspaceName: String? = nil, lastActivityAt: Date? = nil) {
            self.id = id; self.label = label; self.aliases = aliases; self.providerSessionID = providerSessionID; self.transcriptPath = transcriptPath; self.projectID = projectID; self.projectLabel = projectLabel; self.workspaceID = workspaceID; self.workspaceName = workspaceName; self.lastActivityAt = lastActivityAt
        }
    }

    public struct TileSummary: Sendable {
        public var id: LocationIndexID; public var label: String; public var aliases: [String]; public var routingHandle: String?; public var zoneID: LocationIndexID?; public var nearbyContextRank: Int?; public var anchorDistance: Double?
        public init(id: LocationIndexID, label: String, aliases: [String] = [], routingHandle: String? = nil, zoneID: LocationIndexID? = nil, nearbyContextRank: Int? = nil, anchorDistance: Double? = nil) { self.id = id; self.label = label; self.aliases = aliases; self.routingHandle = routingHandle; self.zoneID = zoneID; self.nearbyContextRank = nearbyContextRank; self.anchorDistance = anchorDistance }
    }

    public struct ZoneSummary: Sendable {
        public var id: LocationIndexID; public var label: String; public var aliases: [String]
        public init(id: LocationIndexID, label: String, aliases: [String] = []) { self.id = id; self.label = label; self.aliases = aliases }
    }

    public struct Input: Sendable {
        public var projects: [ProjectSummary]; public var workspaces: [WorkspaceSummary]; public var agents: [AgentSummary]; public var sessions: [SessionSummary]; public var tiles: [TileSummary]; public var zones: [ZoneSummary]
        public init(projects: [ProjectSummary] = [], workspaces: [WorkspaceSummary] = [], agents: [AgentSummary] = [], sessions: [SessionSummary] = [], tiles: [TileSummary] = [], zones: [ZoneSummary] = []) { self.projects = projects; self.workspaces = workspaces; self.agents = agents; self.sessions = sessions; self.tiles = tiles; self.zones = zones }
    }

    public static func makeIndex(from input: Input) -> LocationSessionIndex {
        var records: [LocationIndexRecord] = []
        let sensitiveValues: [String?] = input.agents.flatMap { [$0.providerSessionID, $0.transcriptPath, $0.routingHandle] }
            + input.sessions.flatMap { [$0.providerSessionID, $0.transcriptPath] }
            + input.tiles.map(\.routingHandle)
        records += input.projects.map { project in
            LocationIndexRecord(entry: LocationIndexEntry(id: project.id, kind: .project, label: safeLabel(project.label, fallback: "Project"), aliases: safeAliases(project.aliases, forbidden: sensitiveValues), displayPath: safeDisplayPath(explicit: project.displayPath, hostPath: project.rootPath), activity: .init(lastUsedAt: project.lastUsedAt), workspace: .init(workspaceID: project.workspaceID, workspaceName: safeOptionalText(project.workspaceName), projectID: project.id, projectLabel: safeLabel(project.label, fallback: "Project"), gitBranch: safeOptionalText(project.gitBranch), gitWorktreeLabel: safeOptionalText(project.gitWorktreeLabel), isDirty: project.isDirty, isWorkspaceProject: project.isWorkspaceProject)), privateRouting: .init(absolutePath: project.rootPath))
        }
        records += input.workspaces.map { workspace in
            LocationIndexRecord(entry: LocationIndexEntry(id: workspace.id, kind: .directory, label: safeLabel(workspace.name, fallback: "Workspace"), aliases: safeAliases(workspace.aliases, forbidden: sensitiveValues), displayPath: safeDisplayPath(explicit: workspace.displayPath, hostPath: workspace.path), activity: .init(lastUsedAt: workspace.lastUsedAt), workspace: .init(workspaceID: workspace.id, workspaceName: safeOptionalText(workspace.name), projectID: workspace.projectID, projectLabel: safeOptionalText(workspace.projectLabel))), privateRouting: .init(absolutePath: workspace.path))
        }
        records += input.agents.map { agent in
            LocationIndexRecord(entry: LocationIndexEntry(id: agent.id, kind: .agent, label: safeLabel(agent.label, fallback: "Agent"), aliases: safeAliases(agent.aliases, forbidden: sensitiveValues), activity: .init(lastActivityAt: agent.lastActivityAt, activeAgentCount: agent.isActive ? 1 : 0, isActive: agent.isActive), workspace: .init(workspaceID: agent.workspaceID, workspaceName: safeOptionalText(agent.workspaceName), projectID: agent.projectID, projectLabel: safeOptionalText(agent.projectLabel)), supportedModes: [.location, .globalNavigation]), privateRouting: .init(providerSessionID: agent.providerSessionID, transcriptPath: agent.transcriptPath, absolutePath: agent.routingHandle))
        }
        records += input.sessions.map { session in
            LocationIndexRecord(entry: LocationIndexEntry(id: session.id, kind: .session, label: safeLabel(session.label, fallback: "Session"), aliases: safeAliases(session.aliases, forbidden: sensitiveValues), activity: .init(lastActivityAt: session.lastActivityAt), workspace: .init(workspaceID: session.workspaceID, workspaceName: safeOptionalText(session.workspaceName), projectID: session.projectID, projectLabel: safeOptionalText(session.projectLabel)), supportedModes: [.reference, .globalNavigation]), privateRouting: .init(providerSessionID: session.providerSessionID, transcriptPath: session.transcriptPath))
        }
        records += input.tiles.map { tile in
            LocationIndexRecord(entry: LocationIndexEntry(id: tile.id, kind: .tile, label: safeLabel(tile.label, fallback: "Tile"), aliases: safeAliases(tile.aliases, forbidden: sensitiveValues), spatial: .init(anchorDistance: tile.anchorDistance, nearbyContextRank: tile.nearbyContextRank, zoneID: tile.zoneID), supportedModes: [.location, .globalNavigation]), privateRouting: .init(absolutePath: tile.routingHandle))
        }
        records += input.zones.map { zone in
            LocationIndexRecord(entry: LocationIndexEntry(id: zone.id, kind: .zone, label: safeLabel(zone.label, fallback: "Zone"), aliases: safeAliases(zone.aliases, forbidden: sensitiveValues), supportedModes: [.location, .globalNavigation]))
        }
        return LocationSessionIndex(records: records)
    }

    private static func safeLabel(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        if isAbsolutePathLike(trimmed) { return URL(fileURLWithPath: trimmed).lastPathComponent.nonEmpty ?? fallback }
        return trimmed
    }

    private static func safeOptionalText(_ value: String?) -> String? { value.map { safeLabel($0, fallback: "") }?.nonEmpty }
    private static func safeAliases(_ values: [String], forbidden: [String?] = []) -> [String] {
        let forbiddenValues = Set(forbidden.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !forbiddenValues.contains(trimmed) else { return nil }
            return safeOptionalText(trimmed)
        }
    }

    private static func safeDisplayPath(explicit: String?, hostPath: String?) -> String? {
        if let explicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty, !isAbsolutePathLike(explicit) { return explicit }
        guard let hostPath, !hostPath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: hostPath)
        let parent = url.deletingLastPathComponent().lastPathComponent
        let leaf = url.lastPathComponent
        return [parent, leaf].filter { !$0.isEmpty }.joined(separator: "/").nonEmpty
    }

    private static func isAbsolutePathLike(_ value: String) -> Bool {
        value.hasPrefix("/") || value.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil || value.hasPrefix("~")
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

import Foundation

public enum LaunchPaletteAction: Equatable, Sendable {
    case newManagedAgent
    /// An agent with no tile at all (P2A.6): it runs, persists and appears in the
    /// supervisor's records without any canvas layout.
    case newHeadlessAgent
    case newNote
    case newBrowser
    case openFile
    case openFileTree
    case newDiffReview
    case fitCanvasToAll
    case previousView
    case previousTile
    case previousZone
    case toggleWorkspaceSidebar
    case openURL(String)
    case switchProject(UUID)
    case addProjectToCanvas(UUID)
    case newWorkspace
    case renameWorkspace(UUID)
    case deleteWorkspace(UUID)
    case switchWorkspace(UUID)
    case openInspectorForFocusedBrowser
    case spawnHarnessRole(HarnessRole)
    case jumpToTile(UUID)
    case jumpToZone(UUID)
    case createZone

    public var displayName: String {
        switch self {
        case .newManagedAgent:
            return "New Agent…"
        case .newHeadlessAgent:
            return "New Agent Without a Tile…"
        case .newNote:
            return "New Note"
        case .newBrowser:
            return "New Browser"
        case .openFile:
            return "Open File..."
        case .openFileTree:
            return "Open File Tree..."
        case .newDiffReview:
            return "New Diff Review"
        case .fitCanvasToAll:
            return "Fit Canvas to All"
        case .previousView:
            return "Back to Previous View"
        case .previousTile:
            return "Go to Previous Tile"
        case .previousZone:
            return "Go to Previous Zone"
        case .toggleWorkspaceSidebar:
            return "Toggle Workspace Sidebar"
        case let .openURL(url):
            return "Open \"\(url)\"…"
        case .switchProject:
            return "Switch Project…"
        case .addProjectToCanvas:
            return "Add Project to Canvas…"
        case .newWorkspace:
            return "New Workspace…"
        case .renameWorkspace:
            return "Rename Workspace…"
        case .deleteWorkspace:
            return "Delete Workspace…"
        case .switchWorkspace:
            return "Switch Workspace…"
        case .openInspectorForFocusedBrowser:
            return "Open Inspector for Focused Browser"
        case let .spawnHarnessRole(role):
            return "Run \(role.displayName) Agent…"
        case .jumpToTile:
            return "Jump to Tile…"
        case .jumpToZone:
            return "Jump to Zone…"
        case .createZone:
            return "Create Zone…"
        }
    }

    fileprivate var filterTokens: [String] {
        switch self {
        case .newManagedAgent:
            return ["new", "agent", "managed", "assistant"]
        case .newHeadlessAgent:
            return ["new", "agent", "headless", "tileless"]
        case .newNote:
            return ["new", "note"]
        case .newBrowser:
            return ["new", "browser", "web"]
        case .openFile:
            return ["open", "file"]
        case .openFileTree:
            return ["open", "file", "tree"]
        case .newDiffReview:
            return ["new", "diff", "review", "git"]
        case .fitCanvasToAll:
            return ["fit", "zoom", "all", "canvas"]
        case .previousView:
            return ["back", "previous", "view", "camera"]
        case .previousTile:
            return ["go", "previous", "tile", "back"]
        case .previousZone:
            return ["go", "previous", "zone", "back"]
        case .toggleWorkspaceSidebar:
            return ["toggle", "show", "hide", "workspace", "sidebar", "view"]
        case .openURL:
            return ["open", "url", "browser", "web"]
        case .switchProject:
            return ["switch", "project"]
        case .addProjectToCanvas:
            return ["add", "project", "canvas", "zone"]
        case .newWorkspace:
            return ["new", "workspace", "canvas"]
        case .renameWorkspace:
            return ["rename", "workspace", "canvas"]
        case .deleteWorkspace:
            return ["delete", "workspace", "canvas"]
        case .switchWorkspace:
            return ["switch", "workspace", "canvas"]
        case .openInspectorForFocusedBrowser:
            return ["open", "inspector", "focused", "browser", "continuum", "tile"]
        case let .spawnHarnessRole(role):
            return ["run", "spawn", "agent", "harness", "role", role.id, role.displayName.lowercased()]
        case .jumpToTile:
            return ["jump", "tile", "go"]
        case .jumpToZone:
            return ["jump", "zone", "go"]
        case .createZone:
            return ["create", "new", "zone"]
        }
    }
}

public struct JumpTileRow: Equatable, Sendable {
    public let id: UUID
    public let title: String

    public init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }
}

public struct JumpZoneRow: Equatable, Sendable {
    public let id: UUID
    public let title: String

    public init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }
}

public struct LaunchPaletteProfileRow: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let detail: String
    public let isSelectable: Bool

    public init(id: String, displayName: String, detail: String, isSelectable: Bool) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
        self.isSelectable = isSelectable
    }
}

public enum LaunchPaletteRow: Equatable, Sendable {
    case profile(LaunchPaletteProfileRow)
    case action(LaunchPaletteAction)
    case project(ProjectPickerRow)
    case workspace(WorkspaceEntry)
    case workspaceAction(LaunchPaletteAction, WorkspaceEntry)
    case jumpToTile(JumpTileRow)
    case jumpToZone(JumpZoneRow)

    public var displayName: String {
        switch self {
        case let .profile(profile): return profile.displayName
        case let .action(action): return action.displayName
        case let .project(project):
            if project.worktreeOf != nil {
                return "Add \(project.name) Worktree to Canvas"
            }
            return "Add \(project.name) to Canvas"
        case let .workspace(workspace): return "Switch to \(workspace.name) Workspace"
        case let .workspaceAction(action, workspace):
            switch action {
            case .renameWorkspace: return "Rename \(workspace.name) Workspace…"
            case .deleteWorkspace: return "Delete \(workspace.name) Workspace…"
            default: return action.displayName
            }
        case let .jumpToTile(tile): return "Jump to \(tile.title)"
        case let .jumpToZone(zone): return "Jump to \(zone.title)"
        }
    }

    public var isSelectable: Bool {
        switch self {
        case let .profile(profile): return profile.isSelectable
        case .action: return true
        case let .project(project): return project.isSelectable
        case let .workspace(workspace): return !workspace.projectIds.isEmpty
        case .workspaceAction: return true
        case .jumpToTile: return true
        case .jumpToZone: return true
        }
    }

    fileprivate func matches(query: String) -> Bool {
        guard !query.isEmpty else { return true }
        switch self {
        case let .profile(profile):
            return profile.displayName.lowercased().contains(query)
                || profile.id.lowercased().contains(query)
        case let .action(action):
            if action == .previousView || action == .previousTile || action == .previousZone {
                let tokens = query.split(separator: " ").map(String.init)
                guard tokens.contains(where: { ["previous", "prev", "back"].contains($0) }) else { return false }
            }
            let displayName = action.displayName.lowercased()
            if displayName.contains(query) {
                return true
            }
            let queryTokens = query.split(separator: " ").map(String.init)
            return queryTokens.allSatisfy { queryToken in
                action.filterTokens.contains { token in queryToken.contains(token) || token.contains(queryToken) }
            }
        case let .project(project):
            var haystacks = ["add project canvas zone", "switch project", project.name, project.rootPath, project.id.uuidString]
            if let worktreeOf = project.worktreeOf {
                haystacks += ["worktree", worktreeOf.uuidString]
            }
            let normalizedHaystacks = haystacks.map { $0.lowercased() }
            let queryTokens = query.split(separator: " ").map(String.init)
            return queryTokens.allSatisfy { token in normalizedHaystacks.contains { $0.contains(token) } }
        case let .workspace(workspace):
            let haystacks = ["switch workspace canvas", workspace.name, workspace.id.uuidString].map { $0.lowercased() }
            let queryTokens = query.split(separator: " ").map(String.init)
            return queryTokens.allSatisfy { token in haystacks.contains { $0.contains(token) } }
        case let .workspaceAction(action, workspace):
            let haystacks = [action.displayName, workspace.name, workspace.id.uuidString].map { $0.lowercased() }
            let queryTokens = query.split(separator: " ").map(String.init)
            return queryTokens.allSatisfy { token in haystacks.contains { $0.contains(token) } }
        case let .jumpToTile(tile):
            let haystacks = ["jump tile go", tile.title, tile.id.uuidString].map { $0.lowercased() }
            let queryTokens = query.split(separator: " ").map(String.init)
            return queryTokens.allSatisfy { token in haystacks.contains { $0.contains(token) } }
        case let .jumpToZone(zone):
            let haystacks = ["jump zone go", zone.title, zone.id.uuidString].map { $0.lowercased() }
            let queryTokens = query.split(separator: " ").map(String.init)
            return queryTokens.allSatisfy { token in haystacks.contains { $0.contains(token) } }
        }
    }
}

public enum LaunchPaletteModel {
    public static func makeRows(profiles: [LaunchPaletteProfileRow], projects: [ProjectPickerRow] = [], workspaces: [WorkspaceEntry] = [], contextualActions: [LaunchPaletteAction] = [], harnessRoles: [HarnessRole] = [], jumpTiles: [JumpTileRow] = [], jumpZones: [JumpZoneRow] = []) -> [LaunchPaletteRow] {
        profiles.map(LaunchPaletteRow.profile)
            + CommandRegistry.paletteActions().map(LaunchPaletteRow.action)
            + contextualActions.map(LaunchPaletteRow.action)
            + harnessRoles.map { LaunchPaletteRow.action(.spawnHarnessRole($0)) }
            + jumpTiles.map(LaunchPaletteRow.jumpToTile)
            + jumpZones.map(LaunchPaletteRow.jumpToZone)
            + [LaunchPaletteRow.action(.createZone)]
            + workspaces.flatMap { workspace in
            [
                LaunchPaletteRow.workspace(workspace),
                LaunchPaletteRow.workspaceAction(.renameWorkspace(workspace.id), workspace),
                LaunchPaletteRow.workspaceAction(.deleteWorkspace(workspace.id), workspace)
            ]
        } + projects.map(LaunchPaletteRow.project)
    }

    public static func filterRows(_ rows: [LaunchPaletteRow], query: String) -> [LaunchPaletteRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        let filtered = rows.filter { $0.matches(query: normalized) }
        if let candidate = urlCandidate(from: trimmed) {
            return [.action(.openURL(candidate))] + filtered
        }
        return filtered
    }

    public static func urlCandidate(from query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }

        if let schemeRange = trimmed.range(of: "://") {
            let scheme = String(trimmed[..<schemeRange.lowerBound])
            guard !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) else { return nil }
            return trimmed
        }

        let host = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? trimmed
        let hostWithoutPort = host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? host
        guard host.contains(".") || hostWithoutPort == "localhost" else { return nil }
        let scheme = usesLocalHTTP(host: host) ? "http" : "https"
        return "\(scheme)://\(trimmed)"
    }

    private static func usesLocalHTTP(host: String) -> Bool {
        let hostWithoutPort = host.split(separator: ":", maxSplits: 1).first.map(String.init) ?? host
        if hostWithoutPort == "localhost" { return true }
        let octets = hostWithoutPort.split(separator: ".")
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            guard let value = Int(octet), String(value) == octet else { return false }
            return (0 ... 255).contains(value)
        }
    }

    public static func isFileURL(_ fileURL: URL, insideProjectRoot projectRoot: URL) -> Bool {
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        let rootComponents = projectRoot.standardizedFileURL.pathComponents
        guard fileComponents.count > rootComponents.count else { return false }
        return Array(fileComponents.prefix(rootComponents.count)) == rootComponents
    }
}

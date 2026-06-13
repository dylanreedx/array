import Foundation

public enum LaunchPaletteAction: Equatable, Sendable {
    case newNote
    case newBrowser
    case openFile
    case openFileTree
    case openURL(String)
    case switchProject(UUID)
    case addProjectToCanvas(UUID)
    case newWorkspace
    case renameWorkspace(UUID)
    case deleteWorkspace(UUID)
    case switchWorkspace(UUID)

    public var displayName: String {
        switch self {
        case .newNote:
            return "New Note"
        case .newBrowser:
            return "New Browser"
        case .openFile:
            return "Open File..."
        case .openFileTree:
            return "Open File Tree..."
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
        }
    }

    fileprivate var filterTokens: [String] {
        switch self {
        case .newNote:
            return ["new", "note"]
        case .newBrowser:
            return ["new", "browser", "web"]
        case .openFile:
            return ["open", "file"]
        case .openFileTree:
            return ["open", "file", "tree"]
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
        }
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

    public var displayName: String {
        switch self {
        case let .profile(profile): return profile.displayName
        case let .action(action): return action.displayName
        case let .project(project): return "Add \(project.name) to Canvas"
        case let .workspace(workspace): return "Switch to \(workspace.name) Workspace"
        case let .workspaceAction(action, workspace):
            switch action {
            case .renameWorkspace: return "Rename \(workspace.name) Workspace…"
            case .deleteWorkspace: return "Delete \(workspace.name) Workspace…"
            default: return action.displayName
            }
        }
    }

    public var isSelectable: Bool {
        switch self {
        case let .profile(profile): return profile.isSelectable
        case .action: return true
        case let .project(project): return project.isSelectable
        case let .workspace(workspace): return !workspace.projectIds.isEmpty
        case .workspaceAction: return true
        }
    }

    fileprivate func matches(query: String) -> Bool {
        guard !query.isEmpty else { return true }
        switch self {
        case let .profile(profile):
            return profile.displayName.lowercased().contains(query)
                || profile.id.lowercased().contains(query)
        case let .action(action):
            let displayName = action.displayName.lowercased()
            if displayName.contains(query) {
                return true
            }
            let queryTokens = query.split(separator: " ").map(String.init)
            return queryTokens.allSatisfy { queryToken in
                action.filterTokens.contains { token in queryToken.contains(token) || token.contains(queryToken) }
            }
        case let .project(project):
            let haystacks = ["add project canvas zone", "switch project", project.name, project.rootPath, project.id.uuidString].map { $0.lowercased() }
            let queryTokens = query.split(separator: " ").map(String.init)
            return queryTokens.allSatisfy { token in haystacks.contains { $0.contains(token) } }
        case let .workspace(workspace):
            let haystacks = ["switch workspace canvas", workspace.name, workspace.id.uuidString].map { $0.lowercased() }
            let queryTokens = query.split(separator: " ").map(String.init)
            return queryTokens.allSatisfy { token in haystacks.contains { $0.contains(token) } }
        case let .workspaceAction(action, workspace):
            let haystacks = [action.displayName, workspace.name, workspace.id.uuidString].map { $0.lowercased() }
            let queryTokens = query.split(separator: " ").map(String.init)
            return queryTokens.allSatisfy { token in haystacks.contains { $0.contains(token) } }
        }
    }
}

public enum LaunchPaletteModel {
    public static func makeRows(profiles: [LaunchPaletteProfileRow], projects: [ProjectPickerRow] = [], workspaces: [WorkspaceEntry] = []) -> [LaunchPaletteRow] {
        profiles.map(LaunchPaletteRow.profile) + [
            .action(.newNote),
            .action(.newBrowser),
            .action(.openFile),
            .action(.openFileTree),
            .action(.newWorkspace)
        ] + workspaces.flatMap { workspace in
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

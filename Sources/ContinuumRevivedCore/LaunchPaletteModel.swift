import Foundation

public enum LaunchPaletteAction: String, Equatable, Sendable {
    case newNote
    case openFile
    case openFileTree

    public var displayName: String {
        switch self {
        case .newNote:
            return "New Note"
        case .openFile:
            return "Open File..."
        case .openFileTree:
            return "Open File Tree..."
        }
    }

    fileprivate var filterTokens: [String] {
        switch self {
        case .newNote:
            return ["new", "note"]
        case .openFile:
            return ["open", "file"]
        case .openFileTree:
            return ["open", "file", "tree"]
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

    public var displayName: String {
        switch self {
        case let .profile(profile): return profile.displayName
        case let .action(action): return action.displayName
        }
    }

    public var isSelectable: Bool {
        switch self {
        case let .profile(profile): return profile.isSelectable
        case .action: return true
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
        }
    }
}

public enum LaunchPaletteModel {
    public static func makeRows(profiles: [LaunchPaletteProfileRow]) -> [LaunchPaletteRow] {
        profiles.map(LaunchPaletteRow.profile) + [
            .action(.newNote),
            .action(.openFile),
            .action(.openFileTree)
        ]
    }

    public static func filterRows(_ rows: [LaunchPaletteRow], query: String) -> [LaunchPaletteRow] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rows.filter { $0.matches(query: normalized) }
    }

    public static func isFileURL(_ fileURL: URL, insideProjectRoot projectRoot: URL) -> Bool {
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        let rootComponents = projectRoot.standardizedFileURL.pathComponents
        guard fileComponents.count > rootComponents.count else { return false }
        return Array(fileComponents.prefix(rootComponents.count)) == rootComponents
    }
}

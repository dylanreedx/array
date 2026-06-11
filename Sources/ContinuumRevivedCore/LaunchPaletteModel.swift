import Foundation

public enum LaunchPaletteAction: Equatable, Sendable {
    case newNote
    case newBrowser
    case openFile
    case openFileTree
    case openURL(String)

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
            .action(.newBrowser),
            .action(.openFile),
            .action(.openFileTree)
        ]
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

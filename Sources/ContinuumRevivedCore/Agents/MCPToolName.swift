import Foundation

/// A tool served by someone else's MCP server, made readable for a transcript
/// row: the server first, then the tool as a phrase — "Atlassian · Search Jira
/// issues using JQL" for claude's `mcp__claude_ai_Atlassian__searchJiraIssuesUsingJql`.
///
/// The row used to print the humanised wire name ("Mcp claude ai atlassian
/// searchjiraissuesusingjql"). The exact identifier still reaches the tooltip
/// and the accessibility label through `presentedToolNameText`.
///
/// Two spellings reach the presenter: claude's (and any runner's) namespaced
/// `mcp__<server>__<tool>`, and codex's bare tool name with the server reported
/// beside it. Array's OWN workspace tools are `ArrayWorkspaceTool`'s and are
/// resolved before this.
public struct MCPToolName: Equatable, Sendable {
    /// The server as a reader names it: "Atlassian", "Claude Docs", "GitHub".
    public let server: String
    /// The tool as a sentence-case phrase: "Search Jira issues using JQL".
    public let action: String

    public var title: String { "\(server) · \(action)" }

    /// claude.ai connectors are registered as `claude_ai_<Name>`; the prefix says
    /// where the connector came from, not what it is.
    private static let connectorPrefixes = ["claude_ai_"]

    /// Kept upper case wherever they appear. A trailing "s" is a plural ("IDs").
    private static let acronyms: Set<String> = [
        "jql", "cql", "sql", "api", "url", "uri", "id", "pr", "json", "html", "css",
        "cli", "mcp", "sdk", "ui", "csv", "pdf", "ai",
    ]

    /// Product names whose casing a lowercased word would lose.
    private static let brands: [String: String] = [
        "jira": "Jira", "confluence": "Confluence", "atlassian": "Atlassian",
        "github": "GitHub", "gitlab": "GitLab", "slack": "Slack", "notion": "Notion",
        "figma": "Figma", "asana": "Asana", "hubspot": "HubSpot", "intercom": "Intercom",
        "canva": "Canva", "google": "Google", "gmail": "Gmail", "sentry": "Sentry",
        "stripe": "Stripe", "vercel": "Vercel", "supabase": "Supabase",
    ]

    /// Domain suffixes a registered server name spells with an underscore
    /// (`monday_com`).
    private static let domainSuffixes: Set<String> = ["com", "io", "dev", "app"]

    public init?(toolName: String?, server reportedServer: String? = nil) {
        guard let name = toolName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        let rawServer: String
        let rawTool: String
        if name.hasPrefix("mcp__") {
            let rest = name.dropFirst("mcp__".count)
            guard let separator = rest.range(of: "__") else { return nil }
            rawServer = String(rest[..<separator.lowerBound])
            rawTool = String(rest[separator.upperBound...])
        } else if let reportedServer = reportedServer?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !reportedServer.isEmpty {
            rawServer = reportedServer
            rawTool = name
        } else {
            return nil
        }
        var serverName = rawServer
        for prefix in Self.connectorPrefixes where serverName.lowercased().hasPrefix(prefix) {
            serverName = String(serverName.dropFirst(prefix.count))
        }
        let serverWords = Self.words(serverName)
        var toolWords = Self.words(rawTool)
        guard !serverWords.isEmpty, !toolWords.isEmpty else { return nil }
        // "Notion · Notion search" says the server twice.
        let serverLower = serverWords.map { $0.lowercased() }
        if toolWords.count > serverWords.count,
           Array(toolWords.prefix(serverWords.count)).map({ $0.lowercased() }) == serverLower {
            toolWords.removeFirst(serverWords.count)
        }
        self.server = Self.serverDisplay(serverWords)
        let serverVocabulary = Dictionary(serverWords.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        self.action = Self.phrase(toolWords, serverVocabulary: serverVocabulary)
    }

    /// Words split on separators and on camelCase humps, keeping an acronym run
    /// whole: `getPRUrlsByID` → get, PR, Urls, By, ID.
    static func words(_ raw: String) -> [String] {
        var words: [String] = []
        var current = ""
        let characters = Array(raw)
        for (index, character) in characters.enumerated() {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.append(current); current = "" }
                continue
            }
            if let previous = current.last, character.isUppercase {
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                // lower→Upper starts a word ("searchJira"); so does the last
                // capital of a run when a lowercase follows ("PRUrls" → PR, Urls).
                if !previous.isUppercase || (next?.isLowercase == true) {
                    words.append(current)
                    current = ""
                }
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static func cased(_ word: String) -> String? {
        let lower = word.lowercased()
        if acronyms.contains(lower) { return lower.uppercased() }
        if lower.count > 2, lower.hasSuffix("s"), acronyms.contains(String(lower.dropLast())) {
            return lower.dropLast().uppercased() + "s"
        }
        return brands[lower]
    }

    private static func capitalizedFirst(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }

    private static func serverDisplay(_ words: [String]) -> String {
        var parts = words.enumerated().map { index, word in
            cased(word) ?? (index == 0 ? capitalizedFirst(word) : word)
        }
        if parts.count > 1, let last = parts.last, domainSuffixes.contains(last.lowercased()) {
            parts.removeLast()
            parts[parts.count - 1] += "." + last.lowercased()
        }
        return parts.joined(separator: " ")
    }

    private static func phrase(_ words: [String], serverVocabulary: [String: String]) -> String {
        let parts = words.enumerated().map { index, word -> String in
            if let fixed = cased(word) { return fixed }
            if let serverWord = serverVocabulary[word.lowercased()] { return capitalizedFirst(serverWord) }
            let lower = word.lowercased()
            return index == 0 ? capitalizedFirst(lower) : lower
        }
        return parts.joined(separator: " ")
    }
}

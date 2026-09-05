import Foundation

/// What KIND of work a provider tool does, resolved once from its name.
///
/// TR-03. Before this existed there were three independent classifiers over the
/// same string, with three different matching rules and three different
/// precedence orders:
///
/// - `ToolCallView.symbolName` picked the icon by WORD-BOUNDARY match,
/// - `AgentToolDetailPresenter.pureSummary` picked the action sentence by raw
///   `contains`,
/// - `AgentTranscriptListView.clusterNoun` picked the fold noun by raw
///   `contains`, in yet another order.
///
/// They disagreed on real, shipping tool names. `TodoWrite` drew a wrench, was
/// titled "Edited file", and folded as an "edit". `ToolSearch` — which is in two
/// committed captures — was titled "Searched for …" under a wrench. Every
/// snake_case name (`read_file`, `search_issues`, and every `mcp__server__tool`)
/// fell to the wrench, because `_` is a word character, so a word-boundary
/// search for "read" can never match inside "read_file".
///
/// One resolution, three presentations derived from it.
///
/// ## Matching
///
/// The name is TOKENIZED rather than substring-searched: split on non-alphanumerics
/// AND on camelCase humps, so `TodoWrite` → ["todo", "write"], `read_file` →
/// ["read", "file"], `mcp__linear__create_issue` → ["mcp", "linear", "create",
/// "issue"]. A category matches when one of its keywords is a WHOLE token.
///
/// That is what makes the two historical failure modes impossible at once:
/// `relocate` tokenizes to ["relocate"] and no longer reads as "cat", and
/// `read_file` tokenizes to ["read", "file"] and no longer reads as unknown.
public enum AgentToolKind: String, Equatable, Sendable, CaseIterable {
    case delegate
    case shell
    case edit
    case read
    case search
    case fetch
    case todo
    case unknown

    /// Order matters and is asserted by a witness. Delegation is tested first
    /// because a delegation tool's name routinely contains a "read" or "search"
    /// token; `todo` before `edit` because `TodoWrite` carries both.
    private static let keywords: [(AgentToolKind, Set<String>)] = [
        (.todo, ["todo", "todos", "plan", "checklist"]),
        (.shell, ["bash", "sh", "zsh", "shell", "terminal", "command", "cmd", "run", "exec", "execute"]),
        // Deliberately NOT "create"/"replace"/"insert": those are ordinary verbs
        // on namespaced MCP tools (`mcp__linear__create_issue` creates a ticket,
        // not a file), and a kind is allowed to be `unknown`.
        (.edit, ["edit", "write", "patch", "multiedit"]),
        (.read, ["read", "view", "cat", "open"]),
        (.search, ["search", "grep", "glob", "find", "rg", "ripgrep", "ls", "list"]),
        (.fetch, ["fetch", "web", "http", "https", "url", "browse", "curl"]),
    ]

    /// The delegation NOUNS ("task", "agent") are common suffix words on
    /// unrelated namespaced tools — `mcp__linear__create_task` is a Linear
    /// ticket, not a subagent — so a bare noun only counts when it is the tool's
    /// WHOLE name. The compounds below are unambiguous wherever they appear.
    private static let delegationCompounds = ["subagent", "delegate_agent", "spawn_agent", "delegateagent", "spawnagent"]
    private static let delegationWholeNames: Set<String> = ["task", "agent", "delegate", "spawn"]

    public static func resolve(toolName: String?) -> AgentToolKind {
        guard let name = toolName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return .unknown }
        let raw = name.lowercased()
        if delegationCompounds.contains(where: { raw.contains($0) }) { return .delegate }
        if delegationWholeNames.contains(raw) { return .delegate }
        // Tokenize the ORIGINAL, not the lowercased copy: lowercasing first
        // erases the camelCase humps, which is the only thing that separates
        // "WebSearch" into ["web", "search"].
        let tokens = Set(Self.tokens(name))
        guard !tokens.isEmpty else { return .unknown }
        if !tokens.isDisjoint(with: ["subagent"]) { return .delegate }
        for (kind, needles) in keywords where !tokens.isDisjoint(with: needles) {
            return kind
        }
        return .unknown
    }

    /// Lowercased alphanumeric tokens, split on separators and camelCase humps.
    /// Pass the ORIGINAL casing — the humps are half the signal. Exposed for
    /// witnesses; production goes through `resolve`.
    public static func tokens(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var previous: Character?
        for character in raw {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { tokens.append(current.lowercased()); current = "" }
                previous = nil
                continue
            }
            // A hump: lower-or-digit followed by upper ("todoWrite", "read2File").
            if let previous, character.isUppercase, !previous.isUppercase, !current.isEmpty {
                tokens.append(current.lowercased())
                current = ""
            }
            current.append(character)
            previous = character
        }
        if !current.isEmpty { tokens.append(current.lowercased()) }
        return tokens
    }

    /// A provider IDENTIFIER made readable, for the row's title when there is no
    /// action sentence to show instead.
    ///
    /// Underscores only. Splitting camelCase here too would rewrite claude's own
    /// names ("WebSearch" → "Web search") for no gain, and those already read as
    /// words; what does not read as a word is `delegate_agent`, `spawn_agent`,
    /// `read_file`, `mcp__linear__create_issue` — every pi and MCP tool there
    /// is. The row was printing them verbatim, capitalized: "Delegate_agent".
    ///
    /// The exact identifier survives untouched in the tooltip and the
    /// accessibility label, which is where someone asking "what tool IS this"
    /// should get the literal answer.
    public static func humanizedToolName(_ raw: String) -> String {
        guard raw.contains("_") else { return raw }
        let words = raw.split(separator: "_", omittingEmptySubsequences: true).map(String.init)
        guard let first = words.first else { return raw }
        return ([first] + words.dropFirst().map { $0.lowercased() }).joined(separator: " ")
    }

    /// The SF Symbol for the row's icon column. `unknown` keeps the wrench, so a
    /// tool this build has never heard of degrades to the previous behaviour
    /// rather than to a blank column.
    public var symbolName: String {
        switch self {
        case .delegate: return "person.2"
        case .shell: return "terminal"
        case .edit: return "square.and.pencil"
        case .read: return "eye"
        case .search: return "magnifyingglass"
        case .fetch: return "globe"
        case .todo: return "checklist"
        case .unknown: return "wrench.and.screwdriver"
        }
    }

    /// The noun a fold header counts by ("3 steps · 2 reads, 1 search").
    /// Deliberately not "step": the summary already opens with "N steps", and
    /// "3 steps · 2 reads, 1 step" reads as a counting error.
    public var clusterNoun: String {
        switch self {
        case .delegate: return "delegation"
        case .shell: return "command"
        case .edit: return "edit"
        case .read: return "read"
        case .search: return "search"
        case .fetch: return "fetch"
        case .todo: return "plan"
        case .unknown: return "tool"
        }
    }

    /// The label a disclosure file line hangs off ("Read: …/dir/foo.swift").
    public var fileLineLabel: String {
        switch self {
        case .read: return "Read"
        case .edit: return "Changed"
        case .search: return "Searched in"
        default: return "File"
        }
    }

    /// Whether an action sentence built around this kind NAMES a basename
    /// ("Read foo.js" / "Edited foo.js"). Only those titles can legitimately
    /// suppress a file line underneath them; for any other kind the title's
    /// words are unrelated narration and a substring hit is a coincidence.
    public var actionLineNamesABasename: Bool {
        self == .read || self == .edit
    }
}

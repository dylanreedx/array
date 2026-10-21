import Foundation

/// Array's OWN workspace tools (`array.workspace.v1`, CX-01), recognised from the
/// name any runner reports for them, so a transcript row can say what the agent
/// did on the canvas instead of printing the wire name.
///
/// Two spellings reach the transcript: pi loads `continuum-workspace-tools.ts` and
/// reports the bare name (`array_open_document`); claude and codex reach the same
/// host through the `array-workspace-mcp` server registered as `array_workspace`,
/// and claude reports `mcp__array_workspace__array_open_document` (codex's exec
/// stream carries the bare tool name and the server separately). Only those two
/// spellings are Array's: a bare name under some other MCP namespace belongs to
/// someone else's server.
///
/// The raw values are the tool names `WorkspaceMCPToolCatalog` and the pi
/// extension publish.
public enum ArrayWorkspaceTool: String, CaseIterable, Sendable {
    case workspaceContext = "array_workspace_context"
    case openDocument = "array_open_document"
    case canvasQuery = "array_canvas_query"
    case canvasApply = "array_canvas_apply"
    case findAgent = "array_find_agent"
    case inspectAgent = "array_inspect_agent"
    case delegate = "array_delegate"
    case revealAgent = "array_reveal_agent"
    case getOperation = "array_get_operation"
    case messageAgent = "array_message_agent"
    case boardQuery = "array_board_query"
    case boardApply = "array_board_apply"
    case updateAgent = "array_update_agent"

    /// claude's prefix for a tool served by the `array_workspace` MCP server
    /// (`WorkspaceMCPConfiguration`).
    public static let mcpPrefix = "mcp__array_workspace__"

    public init?(toolName: String?) {
        guard var name = toolName?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if name.hasPrefix(Self.mcpPrefix) { name.removeFirst(Self.mcpPrefix.count) }
        self.init(rawValue: name)
    }

    /// The kind the row is counted as in a fold header and described by.
    public var kind: AgentToolKind {
        switch self {
        case .workspaceContext, .openDocument, .canvasQuery, .inspectAgent, .getOperation, .boardQuery: return .read
        case .canvasApply, .boardApply, .updateAgent: return .edit
        case .findAgent: return .search
        case .delegate: return .delegate
        case .revealAgent, .messageAgent: return .unknown
        }
    }

    /// The row's icon. Finer than the kind's: a board change draws the board's own
    /// glyph (the kanban tile's), not the generic edit pencil.
    public var symbolName: String {
        switch self {
        case .workspaceContext: return "scope"
        case .openDocument, .canvasQuery: return "eye"
        case .canvasApply: return "arrow.up.and.down.and.arrow.left.and.right"
        case .boardQuery, .boardApply: return "rectangle.split.3x1"
        case .findAgent, .inspectAgent, .revealAgent, .updateAgent: return "person.crop.circle"
        case .delegate: return "person.2"
        case .messageAgent: return "bubble.left"
        case .getOperation: return "clock"
        }
    }

    /// The row's sentence, in the transcript's past-tense voice ("Read foo.swift",
    /// "Searched for …"). Only `openDocument` takes an argument — the basename of
    /// the `relativePath` the whitelists let cross; every other sentence is fixed,
    /// so no other argument (a delegated task body) can surface here. A board
    /// change's row is `boardChangeLine`; this is its sentence when nothing names
    /// the op.
    public func actionLine(fileBasename: String?) -> String {
        switch self {
        case .workspaceContext: return "Checked its workspace"
        case .openDocument:
            guard let fileBasename, !fileBasename.isEmpty else { return "Opened a file on the canvas" }
            return "Opened \(fileBasename) on the canvas"
        case .canvasQuery: return "Looked around the canvas"
        case .canvasApply: return "Arranged the canvas"
        case .findAgent: return "Found an agent"
        case .inspectAgent: return "Checked on an agent"
        case .delegate: return "Handed work to an agent"
        case .revealAgent: return "Showed an agent"
        case .getOperation: return "Checked an operation"
        case .messageAgent: return "Messaged an agent"
        case .boardQuery: return "Read the board"
        case .boardApply: return "Updated the board"
        case .updateAgent: return "Changed an agent’s colour"
        }
    }

    /// `array_board_apply`'s row, naming the change: `Moved “Dark mode” to Doing`.
    ///
    /// The request carries ids, so the names come from the host's reply
    /// (`BoardApplyResult.cardTitle`/`columnName`/`assigneeName`) and, for a
    /// create or edit, the title the agent sent. Whatever is missing is left out
    /// rather than guessed — "Moved a card" — and with no op at all the row keeps
    /// the fixed sentence.
    public static func boardChangeLine(op: String?, cardTitle: String?, columnName: String?, assigneeName: String?) -> String {
        guard let op = op.flatMap(BoardApplyRequest.Op.init(rawValue:)) else {
            return ArrayWorkspaceTool.boardApply.actionLine(fileBasename: nil)
        }
        let card = cardTitle.map { "\u{201C}\(clipped($0))\u{201D}" } ?? "a card"
        switch op {
        case .create: return "Added \(card)"
        case .edit: return "Edited \(card)"
        case .move: return "Moved \(card)" + (columnName.map { " to \(clipped($0))" } ?? "")
        case .assign: return "Assigned \(card)" + (assigneeName.map { " to \(clipped($0))" } ?? "")
        case .unassign: return "Unassigned \(card)"
        case .delete: return "Removed \(card)"
        }
    }

    /// `array_message_agent`'s row, naming who it messaged: `Messaged Scout`.
    /// The request carries an id, so the name comes from the host's reply, and
    /// a call still running (or refused) keeps the fixed sentence.
    public static func messageLine(targetName: String?) -> String {
        guard let targetName, !targetName.isEmpty else { return messageAgent.actionLine(fileBasename: nil) }
        return "Messaged \(clipped(targetName))"
    }

    /// A card title is free text; the row is one line with a status column.
    private static func clipped(_ name: String, limit: Int = 60) -> String {
        let single = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard single.count > limit else { return single }
        return String(single.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

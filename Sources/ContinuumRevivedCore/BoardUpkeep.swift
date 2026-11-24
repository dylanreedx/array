import CryptoKit
import Foundation

/// Boards that stay current without anyone remembering. Pure: which columns
/// count as work in progress, when a card has gone stale, what a helper may
/// change, and the deterministic identities that make every automatic write
/// happen once. The host applies these through the board runtime.
public enum BoardUpkeep {
    /// What a helper may do to a task it is assigned to. Create, move, unassign
    /// and delete stay with its lead (and the user).
    public static let helperOperations: Set<BoardApplyRequest.Op> = [.comment, .editComment, .deleteComment, .edit, .assign]
    public static let helperRefusal = "A helper may comment on, edit or assign only a task it is assigned to; creating, moving, unassigning and deleting tasks stay with its lead."

    /// The column a delegated task moves into: the second column, the same
    /// "Doing" a task sent from the board reaches. Only when the board has a
    /// later column too, so Array never moves a task into the last (Done) one.
    public static func doingColumn(_ board: Board) -> UUID? {
        let columns = board.orderedColumns
        return columns.count >= 3 ? columns[1].id : nil
    }

    /// Work in progress: every column between the first (to do) and the last
    /// (done). A board of one or two columns has none.
    public static func workingColumns(_ board: Board) -> Set<UUID> {
        let columns = board.orderedColumns
        guard columns.count >= 3 else { return [] }
        return Set(columns.dropFirst().dropLast().map(\.id))
    }

    /// What an assignee is doing now, as the host sees it.
    public enum AssigneeState: Equatable, Sendable {
        case working
        case idle
        case finished
        case stopped
        case vanished

        var isTerminal: Bool { self == .finished || self == .stopped || self == .vanished }
    }

    /// Every assignee finished, stopped or gone: stale once nothing has
    /// touched the card for this long, so the lead's own result comes first.
    public static let finishedGrace: TimeInterval = 20 * 60
    /// Nobody working on it and nothing touched it for this long.
    public static let untouchedAfter: TimeInterval = 4 * 60 * 60

    /// A card in a working column whose assignees are no longer working on it.
    /// A card nobody is assigned to is the user's, and never stale. `lastTouched`
    /// is the later of the card's own change and its assignees' last activity.
    public static func isStale(_ card: BoardCard, in board: Board, assignees: [AgentID: AssigneeState],
                               lastTouched: Date, now: Date) -> Bool {
        guard workingColumns(board).contains(card.columnId), !card.assignees.isEmpty else { return false }
        let states = card.assignees.map { assignees[$0] ?? .vanished }
        guard !states.contains(.working) else { return false }
        let quiet = now.timeIntervalSince(lastTouched)
        if states.allSatisfy(\.isTerminal) { return quiet >= finishedGrace }
        return quiet >= untouchedAfter
    }

    /// The comment Array posts for a helper's report: one id per run and
    /// text, so a retried report, the run ending after it and a relaunch all
    /// find the comment already there. A different report is a new comment.
    public static func reportCommentID(agent: AgentID, runStartedAt: Date, body: String) -> UUID {
        stableID("report|\(agent.rawValue.uuidString)|\(runStartedAt.timeIntervalSince1970)|\(body)")
    }

    /// The comment for a delegated run that ended without a report.
    public static func runEndCommentID(agent: AgentID, endedAt: Date) -> UUID {
        stableID("run-end|\(agent.rawValue.uuidString)|\(endedAt.timeIntervalSince1970)")
    }

    public static func reportCommentBody(_ report: AgentReport) -> String {
        var lines = ["Report: " + report.summary]
        lines += report.checks.filter { $0.result != .pass }.map { "Check \($0.result.rawValue): \($0.what)" }
        if let next = report.next, !next.isEmpty { lines.append("Next: " + next) }
        return String(lines.joined(separator: "\n").prefix(8000))
    }

    public static func runEndCommentBody(outcome: String) -> String {
        "Run \(outcome) without a report."
    }

    /// One line in a delegated helper's first prompt.
    public static func delegatedCardLine(title: String, boardId: UUID, cardId: UUID) -> String {
        "Your board task: “\(title.prefix(200))” (boardId \(boardId.uuidString), cardId \(cardId.uuidString)). You are assigned to it. Keep it current with array_board_apply (op comment) when your progress changes; Array posts your array_report on it."
    }

    /// The one nudge a stale card's lead gets.
    public static func nudgeText(cardTitle: String, boardTitle: String, boardId: UUID, cardId: UUID) -> String {
        "Board task “\(cardTitle.prefix(200))” on “\(boardTitle.prefix(80))” is still in progress, but nobody assigned to it is working on it (boardId \(boardId.uuidString), cardId \(cardId.uuidString)). Move it, reassign it or delegate it again with array_board_apply or array_delegate; Array will not move it to Done."
    }

    static func stableID(_ text: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

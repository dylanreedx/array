import Foundation

// KB-01: provider-neutral board document contracts. Board coordinates are
// column/card identities and neighbour anchors; they are never canvas frames.

public struct BoardQueryRequest: Codable, Equatable, Sendable {
    public var checkoutHandle: CheckoutHandle?
    public var boardId: UUID?
    public var cardId: UUID?
    public var limit: Int?
    public var cursor: String?

    public init(
        checkoutHandle: CheckoutHandle? = nil,
        boardId: UUID? = nil,
        cardId: UUID? = nil,
        limit: Int? = nil,
        cursor: String? = nil
    ) {
        self.checkoutHandle = checkoutHandle
        self.boardId = boardId
        self.cardId = cardId
        self.limit = limit
        self.cursor = cursor
    }
}

public struct BoardQueryColumn: Codable, Equatable, Sendable {
    public var columnId: UUID
    public var name: String
    public var cardCount: Int

    public init(columnId: UUID, name: String, cardCount: Int) {
        self.columnId = columnId
        self.name = name
        self.cardCount = cardCount
    }
}

public struct BoardQuerySummary: Codable, Equatable, Sendable {
    public var boardId: UUID
    public var tileId: UUID?
    public var title: String
    public var revision: UInt64
    public var columns: [BoardQueryColumn]

    public init(boardId: UUID, tileId: UUID?, title: String, revision: UInt64, columns: [BoardQueryColumn]) {
        self.boardId = boardId
        self.tileId = tileId
        self.title = title
        self.revision = revision
        self.columns = columns
    }
}

/// A path-free link on the API wire. Exactly one value appropriate to `kind`
/// is accepted. Document inputs use an Array-issued artifact handle; document
/// outputs use that handle when resolvable within the caller's checkout.
public struct BoardAPILink: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case document, agent, tile, url }
    public var kind: Kind
    public var artifactHandle: String?
    public var agentId: AgentID?
    public var tileId: UUID?
    public var url: String?

    public init(kind: Kind, artifactHandle: String? = nil, agentId: AgentID? = nil, tileId: UUID? = nil, url: String? = nil) {
        self.kind = kind
        self.artifactHandle = artifactHandle
        self.agentId = agentId
        self.tileId = tileId
        self.url = url
    }
}

public struct BoardQueryCard: Codable, Equatable, Sendable {
    public var comments: [BoardComment] = []
    public var cardId: UUID
    public var columnId: UUID
    public var title: String
    public var body: String
    public var links: [BoardAPILink]
    public var attachments: [BoardAttachment]
    public var assigneeAgentIds: [AgentID]? = nil
    public var assigneeAgentId: AgentID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        cardId: UUID, columnId: UUID, title: String, body: String,
        links: [BoardAPILink], attachments: [BoardAttachment],
        assigneeAgentId: AgentID?, createdAt: Date, updatedAt: Date
    ) {
        self.cardId = cardId
        self.columnId = columnId
        self.title = title
        self.body = body
        self.links = links
        self.attachments = attachments
        self.assigneeAgentId = assigneeAgentId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct BoardQueryDetail: Codable, Equatable, Sendable {
    public var boardId: UUID
    public var tileId: UUID?
    public var title: String
    public var revision: UInt64
    public var columns: [BoardQueryColumn]
    public var cards: [BoardQueryCard]

    public init(boardId: UUID, tileId: UUID?, title: String, revision: UInt64, columns: [BoardQueryColumn], cards: [BoardQueryCard]) {
        self.boardId = boardId
        self.tileId = tileId
        self.title = title
        self.revision = revision
        self.columns = columns
        self.cards = cards
    }
}

public struct BoardQueryResponse: Codable, Equatable, Sendable {
    public var schema: String = WorkspaceAPISchema.v1
    public var checkoutHandle: CheckoutHandle
    public var projectId: UUID
    public var boards: [BoardQuerySummary]
    public var board: BoardQueryDetail?
    public var nextCursor: String?
    public var truncated: Bool

    public init(
        checkoutHandle: CheckoutHandle, projectId: UUID,
        boards: [BoardQuerySummary] = [], board: BoardQueryDetail? = nil,
        nextCursor: String? = nil, truncated: Bool = false
    ) {
        self.checkoutHandle = checkoutHandle
        self.projectId = projectId
        self.boards = boards
        self.board = board
        self.nextCursor = nextCursor
        self.truncated = truncated
    }
}

public enum BoardQueryPage {
    public static let defaultLimit = 50
    public static let maxLimit = 50
    public static let encodedByteCeiling = 12 * 1024

    public static func clampedLimit(_ value: Int?) -> Int {
        min(max(value ?? defaultLimit, 1), maxLimit)
    }

    public static func cursor(boardId: UUID?, revision: UInt64?, offset: Int) -> String {
        let identity = boardId?.uuidString.lowercased() ?? "list"
        let raw = "v1:\(identity):\(revision ?? 0):\(max(0, offset))"
        return Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func offset(from cursor: String?, boardId: UUID?, revision: UInt64?) -> Result<Int, WorkspaceAPIError.Code> {
        guard let cursor, !cursor.isEmpty else { return .success(0) }
        var value = cursor.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value.append("=") }
        guard let data = Data(base64Encoded: value), let raw = String(data: data, encoding: .utf8) else {
            return .failure(.invalidRequest)
        }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "v1", let encodedRevision = UInt64(parts[2]),
              let offset = Int(parts[3]), offset >= 0 else { return .failure(.invalidRequest) }
        let expectedIdentity = boardId?.uuidString.lowercased() ?? "list"
        guard parts[1] == Substring(expectedIdentity) else { return .failure(.invalidRequest) }
        if boardId != nil, encodedRevision != revision { return .failure(.cursorExpired) }
        return .success(offset)
    }
}

public struct BoardApplyRequest: Codable, Equatable, Sendable {
    public enum Op: String, Codable, Sendable { case create, edit, move, assign, unassign, delete, comment, editComment, deleteComment }

    public var commentId: UUID?
    public var op: Op
    public var checkoutHandle: CheckoutHandle?
    public var boardId: UUID
    public var expectedRevision: UInt64
    public var idempotencyKey: String
    public var cardId: UUID?
    public var columnId: UUID?
    public var title: String?
    public var body: String?
    public var links: [BoardAPILink]?
    public var assigneeAgentId: AgentID?
    public var afterCardId: UUID?
    public var beforeCardId: UUID?

    public init(
        op: Op, boardId: UUID, expectedRevision: UInt64, idempotencyKey: String,
        checkoutHandle: CheckoutHandle? = nil, cardId: UUID? = nil,
        columnId: UUID? = nil, title: String? = nil, body: String? = nil,
        links: [BoardAPILink]? = nil, assigneeAgentId: AgentID? = nil,
        afterCardId: UUID? = nil, beforeCardId: UUID? = nil, commentId: UUID? = nil
    ) {
        self.commentId = commentId
        self.op = op
        self.checkoutHandle = checkoutHandle
        self.boardId = boardId
        self.expectedRevision = expectedRevision
        self.idempotencyKey = idempotencyKey
        self.cardId = cardId
        self.columnId = columnId
        self.title = title
        self.body = body
        self.links = links
        self.assigneeAgentId = assigneeAgentId
        self.afterCardId = afterCardId
        self.beforeCardId = beforeCardId
    }
}

public struct BoardApplyResult: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case applied, rebased }
    public enum Durability: String, Codable, Sendable { case committed }

    public var schema: String = WorkspaceAPISchema.v1
    public var operationId: String
    public var op: BoardApplyRequest.Op
    public var boardId: UUID
    public var cardId: UUID
    public var outcome: Outcome
    public var durability: Durability = .committed
    public var undoRegistered: Bool
    public var revision: UInt64
    public var card: BoardQueryCard?
    /// What a reader needs to say what changed, by NAME — the request carries
    /// only ids. `cardTitle` is the card's title after the change, or the title
    /// of the card a `delete` removed (whose `card` is nil); `columnName` is the
    /// column holding the card afterwards; `assigneeName` is the display name of
    /// its assignee afterwards. Optional, so a reply without them still decodes.
    public var cardTitle: String?
    public var columnName: String?
    public var assigneeName: String?

    public init(
        operationId: String, op: BoardApplyRequest.Op, boardId: UUID, cardId: UUID,
        outcome: Outcome, undoRegistered: Bool, revision: UInt64, card: BoardQueryCard?,
        cardTitle: String? = nil, columnName: String? = nil, assigneeName: String? = nil
    ) {
        self.operationId = operationId
        self.op = op
        self.boardId = boardId
        self.cardId = cardId
        self.outcome = outcome
        self.undoRegistered = undoRegistered
        self.revision = revision
        self.card = card
        self.cardTitle = cardTitle
        self.columnName = columnName
        self.assigneeName = assigneeName
    }
}

// MARK: - board.manage

/// One whole-board lifecycle change: the Boards sidebar's New, Rename and
/// Delete. Tasks stay `board.apply`'s.
///
/// - `create` takes an optional `title` (default: the zone's board name, as the
///   UI does) and an optional `nextToTileId` in the caller's own zone (default:
///   the caller's tile). It has no `boardId` or `expectedRevision`: there is no
///   board yet, and the idempotency key alone keeps a retry from making two.
/// - `rename` takes `boardId`, `expectedRevision` and `title`.
/// - `delete` takes `boardId` and `expectedRevision`, and refuses a board that
///   still holds tasks (`target_conflict`, `board_not_empty`).
public struct BoardManageRequest: Codable, Equatable, Sendable {
    public enum Op: String, Codable, Sendable { case create, rename, delete }

    public var op: Op
    public var checkoutHandle: CheckoutHandle?
    public var boardId: UUID?
    public var expectedRevision: UInt64?
    public var idempotencyKey: String
    public var title: String?
    public var nextToTileId: UUID?

    public init(
        op: Op, idempotencyKey: String, checkoutHandle: CheckoutHandle? = nil,
        boardId: UUID? = nil, expectedRevision: UInt64? = nil,
        title: String? = nil, nextToTileId: UUID? = nil
    ) {
        self.op = op
        self.checkoutHandle = checkoutHandle
        self.boardId = boardId
        self.expectedRevision = expectedRevision
        self.idempotencyKey = idempotencyKey
        self.title = title
        self.nextToTileId = nextToTileId
    }
}

public struct BoardManageResult: Codable, Equatable, Sendable {
    public enum Durability: String, Codable, Sendable { case committed }

    public var schema: String = WorkspaceAPISchema.v1
    public var operationId: String
    public var op: BoardManageRequest.Op
    public var boardId: UUID
    /// The board's tile after the change: the new tile for `create`, the open
    /// tile (if any) for `rename`, nil for `delete`.
    public var tileId: UUID?
    /// The zone the new tile was installed in (`create` only).
    public var zoneId: UUID?
    /// The board's title after the change; for `delete`, the title it had.
    public var title: String
    /// The board's revision after the change; for `delete`, the revision it had.
    public var revision: UInt64
    public var columns: [BoardQueryColumn]
    public var durability: Durability = .committed
    /// Whether Edit ▸ Undo can reverse this change. `rename` uses the board's
    /// own history (the focused board tile's Undo); `create` and `delete` use
    /// the canvas history, named "New Board" / "Delete Board".
    public var undoRegistered: Bool

    public init(
        operationId: String, op: BoardManageRequest.Op, boardId: UUID, tileId: UUID?,
        zoneId: UUID? = nil, title: String, revision: UInt64, columns: [BoardQueryColumn],
        undoRegistered: Bool
    ) {
        self.operationId = operationId
        self.op = op
        self.boardId = boardId
        self.tileId = tileId
        self.zoneId = zoneId
        self.title = title
        self.revision = revision
        self.columns = columns
        self.undoRegistered = undoRegistered
    }
}

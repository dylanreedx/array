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
    public var cardId: UUID
    public var columnId: UUID
    public var title: String
    public var body: String
    public var links: [BoardAPILink]
    public var attachments: [BoardAttachment]
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
    public enum Op: String, Codable, Sendable { case create, edit, move, assign, unassign, delete }

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
        afterCardId: UUID? = nil, beforeCardId: UUID? = nil
    ) {
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

    public init(
        operationId: String, op: BoardApplyRequest.Op, boardId: UUID, cardId: UUID,
        outcome: Outcome, undoRegistered: Bool, revision: UInt64, card: BoardQueryCard?
    ) {
        self.operationId = operationId
        self.op = op
        self.boardId = boardId
        self.cardId = cardId
        self.outcome = outcome
        self.undoRegistered = undoRegistered
        self.revision = revision
        self.card = card
    }
}

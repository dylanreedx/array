import Foundation

/// Stable, transport-friendly read model for a board consumer.
///
/// The canvas owns presentation details; this DTO exposes only board facts in
/// deterministic order. Consumers can cache `revision` and submit a command
/// against that revision without reading the persistence format.
public struct BoardSurfaceSnapshot: Codable, Equatable, Sendable {
    public struct Column: Codable, Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let cardIDs: [UUID]

        public init(id: UUID, name: String, cardIDs: [UUID]) {
            self.id = id
            self.name = name
            self.cardIDs = cardIDs
        }
    }

    public struct Card: Codable, Equatable, Sendable {
        public let id: UUID
        public let columnID: UUID
        public let title: String
        public let body: String
        public let links: [CardLink]
        public let attachments: [BoardAttachment]
        public let assignee: AgentID?

        public init(card: BoardCard) {
            id = card.id
            columnID = card.columnId
            title = card.title
            body = card.body
            links = card.links
            attachments = card.attachments
            assignee = card.assignee
        }
    }

    public let boardID: UUID
    public let revision: UInt64
    public let title: String
    public let columns: [Column]
    public let cards: [Card]

    public init(board: Board) {
        boardID = board.id
        revision = board.revision
        title = board.title
        columns = board.orderedColumns.map { column in
            Column(id: column.id, name: column.name, cardIDs: board.orderedCards(in: column.id).map(\.id))
        }
        cards = board.orderedColumns.flatMap { board.orderedCards(in: $0.id).map(Card.init(card:)) }
    }
}

public enum BoardSurfaceCommandError: Error, Equatable, Sendable {
    case staleRevision(expected: UInt64, actual: UInt64)
    case rejected(BoardCommandError)
}

public struct BoardSurfaceCommandResult: Equatable, Sendable {
    public let transaction: BoardTransaction
    public let snapshot: BoardSurfaceSnapshot

    public init(transaction: BoardTransaction) {
        self.transaction = transaction
        snapshot = BoardSurfaceSnapshot(board: transaction.after)
    }
}

/// Pure command façade for non-canvas consumers. AppKit persistence remains in
/// `BoardRuntime`; this type guarantees that a surface sees the same reducer,
/// revision token, rebasing, and inverse as pointer-driven edits.
public struct BoardSurfaceCommandService: Sendable {
    private var board: Board

    public init(board: Board) {
        self.board = board
    }

    public var snapshot: BoardSurfaceSnapshot { BoardSurfaceSnapshot(board: board) }

    public mutating func apply(
        _ command: BoardCommand,
        expectedRevision: UInt64? = nil,
        now: Date,
        transactionID: UUID = UUID()
    ) -> Result<BoardSurfaceCommandResult, BoardSurfaceCommandError> {
        if let expectedRevision, expectedRevision != board.revision {
            return .failure(.staleRevision(expected: expectedRevision, actual: board.revision))
        }
        switch BoardEngine.apply(command, to: board, now: now, transactionId: transactionID) {
        case .failure(let error):
            return .failure(.rejected(error))
        case .success(let transaction):
            board = transaction.after
            return .success(BoardSurfaceCommandResult(transaction: transaction))
        }
    }
}

import Foundation

// KB-01: the local editable kanban board. Plan: .plans/60-kanban-board.md
//
// BOARD DATA IS NOT CANVAS GEOMETRY. A card's column and order live here and
// persist to `<project root>/.array/boards/<id>.json`; the canvas knows only
// `TileMetadata.boardId`. Three concrete failures motivate the split:
//
//  1. `canvas.json` is rewritten under the cover-then-replace merge
//     (`CanvasPersistenceMerge`). A card move landing there races geometry
//     saves and can be erased by a zone below the live hydration tier.
//  2. `canvas.json` holds WORLD frames, converted at the ZoneLayer boundary.
//     Board data has no frame and must never enter that conversion.
//  3. Undo. Canvas history is `CanvasGeometryTransaction`-shaped and wipes its
//     whole stack on a geometry mismatch. One card move is one BOARD undo.
//
// ORDER IS `(position, id)`, ascending — the same deterministic tie-break the
// canvas already uses for `zPosition`, so equal positions are a stable tie and
// never an arbitrary one. Membership (`columnId`) is an LWW register ON THE
// CARD, never an array on the column: that is what lets a pointer move and an
// agent move commute instead of conflicting at the list level.

// MARK: - Card links

/// A typed pointer from a card to something else Array can resolve and reveal.
/// Typed rather than a string so "open this card's plan" and "show the agent
/// working on this" cannot silently resolve to the wrong thing — a stale link
/// reports unavailable with a reason, it does not fall back to a path guess.
public enum CardLink: Codable, Equatable, Sendable {
    case document(DocumentLocation)
    case agent(AgentID)
    case tile(UUID)
    case url(String)

    private enum CodingKeys: String, CodingKey {
        case document, agent, tile, url
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(DocumentLocation.self, forKey: .document) {
            self = .document(value)
        } else if let value = try container.decodeIfPresent(AgentID.self, forKey: .agent) {
            self = .agent(value)
        } else if let value = try container.decodeIfPresent(UUID.self, forKey: .tile) {
            self = .tile(value)
        } else if let value = try container.decodeIfPresent(String.self, forKey: .url) {
            self = .url(value)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "unknown CardLink kind"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .document(let value): try container.encode(value, forKey: .document)
        case .agent(let value): try container.encode(value, forKey: .agent)
        case .tile(let value): try container.encode(value, forKey: .tile)
        case .url(let value): try container.encode(value, forKey: .url)
        }
    }
}

// MARK: - Board

public struct BoardColumn: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var position: FracIndex

    public init(id: UUID, name: String, position: FracIndex) {
        self.id = id
        self.name = name
        self.position = position
    }
}

public struct BoardCard: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    /// LWW register. Not an index into a column's array — see the file header.
    public var columnId: UUID
    public var position: FracIndex
    public var title: String
    public var body: String
    public var links: [CardLink]
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        columnId: UUID,
        position: FracIndex,
        title: String,
        body: String = "",
        links: [CardLink] = [],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.columnId = columnId
        self.position = position
        self.title = title
        self.body = body
        self.links = links
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct Board: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public var title: String
    /// Monotonic. Bumped by exactly one place — `BoardEngine.apply` — so it is a
    /// usable concurrency token for the canvas API's rebase/reject policy.
    public var revision: UInt64
    public var columns: [BoardColumn]
    public var cards: [BoardCard]

    public init(
        schemaVersion: Int = Board.currentSchemaVersion,
        id: UUID,
        title: String,
        revision: UInt64 = 0,
        columns: [BoardColumn],
        cards: [BoardCard]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.revision = revision
        self.columns = columns
        self.cards = cards
    }

    // MARK: Deterministic reads

    /// Columns in `(position, id)` order.
    public var orderedColumns: [BoardColumn] {
        columns.sorted { lhs, rhs in
            if lhs.position != rhs.position { return lhs.position < rhs.position }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// The cards of one column in `(position, id)` order. Unknown column → empty,
    /// never a crash: a rehydrated view can legally ask about a column an API
    /// command deleted a moment ago.
    public func orderedCards(in columnId: UUID) -> [BoardCard] {
        cards.filter { $0.columnId == columnId }.sorted { lhs, rhs in
            if lhs.position != rhs.position { return lhs.position < rhs.position }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    public func card(_ id: UUID) -> BoardCard? { cards.first { $0.id == id } }
    public func column(_ id: UUID) -> BoardColumn? { columns.first { $0.id == id } }

    /// Cards whose `columnId` names no column in this board. Ordinary use cannot
    /// produce one — `deleteColumn` reassigns or refuses — but a hand-edited or
    /// partially-written file can, and dropping those cards silently would lose
    /// user data. The repair adopts them into the first column.
    public var orphanedCards: [BoardCard] {
        let live = Set(columns.map(\.id))
        return cards.filter { !live.contains($0.columnId) }
    }

    /// The default board a new tile is born with.
    public static func makeDefault(id: UUID, title: String, now: Date) -> Board {
        let names = ["To Do", "Doing", "Done"]
        let positions = FracIndex.distribute(count: names.count)
        let columns = zip(names, positions).map { BoardColumn(id: UUID(), name: $0, position: $1) }
        return Board(id: id, title: title, columns: columns, cards: [])
    }
}

// MARK: - Board index (`.array/boards/index.json`)

/// Mirrors `NoteState`/`NoteTile` deliberately: one small index beside the
/// per-board files, so listing boards never means opening every board.
public struct BoardState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public var boards: [BoardIndexEntry]

    public init(schemaVersion: Int = BoardState.currentSchemaVersion, boards: [BoardIndexEntry]) {
        self.schemaVersion = schemaVersion
        self.boards = boards
    }
}

public struct BoardIndexEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    /// The tile currently showing this board, if any. Cleared when the tile
    /// closes — closing a tile is closing a window, not deleting the board.
    public var tileId: UUID?
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID, tileId: UUID?, title: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.tileId = tileId
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

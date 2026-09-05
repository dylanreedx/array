import Foundation

// KB-01: the ONE path every board mutation takes. Plan: .plans/60-kanban-board.md
//
// Pointer drags, keyboard moves, the palette and the canvas API all build a
// `BoardCommand` and hand it here. There is deliberately no second write path,
// so "UI and agent-originated moves use the same validation and persistence"
// is a property of the type system rather than a convention someone maintains.
//
// A move carries NEIGHBOUR ANCHORS (`after`/`before`), never an index. That is
// what makes a command rebasable: when the board moved under a stale caller,
// the anchors still name real cards and the engine can re-derive a position
// between whatever they are adjacent to NOW. An index cannot be repaired —
// it silently means something else.

public enum BoardCommand: Equatable, Sendable {
    case createCard(id: UUID, columnId: UUID, title: String, after: UUID?, before: UUID?)
    case editCard(id: UUID, title: String?, body: String?)
    case moveCard(id: UUID, toColumn: UUID, after: UUID?, before: UUID?)
    case deleteCard(id: UUID)
    /// Undo's inverse of `deleteCard`. Restores the card verbatim, including its
    /// original position, so an undone delete lands exactly where it was.
    case restoreCard(BoardCard)
    case setCardLinks(id: UUID, links: [CardLink])

    case createColumn(id: UUID, name: String, after: UUID?, before: UUID?)
    case renameColumn(id: UUID, name: String)
    case moveColumn(id: UUID, after: UUID?, before: UUID?)
    case deleteColumn(id: UUID, reassignCardsTo: UUID?)
    /// Undo's inverse of `deleteColumn`.
    case restoreColumn(BoardColumn, cards: [BoardCard])

    case renameBoard(title: String)
}

public enum BoardCommandError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownCard(UUID)
    case unknownColumn(UUID)
    case duplicateCard(UUID)
    case duplicateColumn(UUID)
    /// An anchor named a card/column that is no longer where the caller thought.
    /// Distinct from `unknownCard`: the id may exist, just not in the target
    /// column. Reported rather than guessed at.
    case anchorsUnavailable
    /// A board must keep at least one column, or cards have nowhere to live.
    case lastColumn
    /// `deleteColumn` was asked to reassign into a column that does not exist,
    /// or into itself.
    case invalidReassignment

    public var description: String {
        switch self {
        case .unknownCard(let id): return "no card \(id.uuidString)"
        case .unknownColumn(let id): return "no column \(id.uuidString)"
        case .duplicateCard(let id): return "card \(id.uuidString) already exists"
        case .duplicateColumn(let id): return "column \(id.uuidString) already exists"
        case .anchorsUnavailable: return "the neighbouring cards this move was anchored to are gone"
        case .lastColumn: return "a board needs at least one column"
        case .invalidReassignment: return "cards must be reassigned to another existing column"
        }
    }
}

/// What one applied command did. `before`/`after` are whole boards because a
/// board is small and value-typed; holding both makes undo replay exact and
/// makes a witness able to diff without re-deriving anything.
public struct BoardTransaction: Equatable, Sendable {
    public let id: UUID
    public let command: BoardCommand
    public let inverse: BoardCommand
    public let before: Board
    public let after: Board
    /// True when anchors no longer described adjacent cards and the engine
    /// re-derived the position against the board's current neighbours. Surfaced
    /// so the canvas API can report `.rebased` instead of pretending nothing
    /// happened.
    public let rebasedAnchors: Bool

    public var isNoOp: Bool { before == after }
}

public enum BoardEngine {
    /// Applies one command. Pure: no I/O, no clock, no AppKit. `now` is injected
    /// so a witness gets byte-identical output on every run.
    public static func apply(
        _ command: BoardCommand,
        to board: Board,
        now: Date,
        transactionId: UUID = UUID()
    ) -> Result<BoardTransaction, BoardCommandError> {
        var next = board
        var rebased = false
        let inverse: BoardCommand

        switch command {
        case let .createCard(id, columnId, title, after, before):
            guard board.column(columnId) != nil else { return .failure(.unknownColumn(columnId)) }
            guard board.card(id) == nil else { return .failure(.duplicateCard(id)) }
            let resolved: ResolvedPosition
            switch cardPosition(in: board, columnId: columnId, after: after, before: before, moving: nil) {
            case .failure(let error): return .failure(error)
            case .success(let value): resolved = value
            }
            rebased = resolved.rebased
            next = resolved.board
            next.cards.append(BoardCard(
                id: id, columnId: columnId, position: resolved.position,
                title: title, createdAt: now, updatedAt: now))
            inverse = .deleteCard(id: id)

        case let .editCard(id, title, body):
            guard let index = next.cards.firstIndex(where: { $0.id == id }) else {
                return .failure(.unknownCard(id))
            }
            inverse = .editCard(id: id, title: next.cards[index].title, body: next.cards[index].body)
            if let title { next.cards[index].title = title }
            if let body { next.cards[index].body = body }
            next.cards[index].updatedAt = now

        case let .moveCard(id, toColumn, after, before):
            guard let existing = board.card(id) else { return .failure(.unknownCard(id)) }
            guard board.column(toColumn) != nil else { return .failure(.unknownColumn(toColumn)) }
            // The inverse is computed against the board BEFORE the move, so an
            // undo restores the card between the neighbours it actually had —
            // not between whatever happens to be there afterwards.
            inverse = .moveCard(
                id: id, toColumn: existing.columnId,
                after: neighbour(of: id, in: board, offset: -1),
                before: neighbour(of: id, in: board, offset: +1))
            let resolved: ResolvedPosition
            switch cardPosition(in: board, columnId: toColumn, after: after, before: before, moving: id) {
            case .failure(let error): return .failure(error)
            case .success(let value): resolved = value
            }
            rebased = resolved.rebased
            next = resolved.board
            guard let index = next.cards.firstIndex(where: { $0.id == id }) else {
                return .failure(.unknownCard(id))
            }
            next.cards[index].columnId = toColumn
            next.cards[index].position = resolved.position
            next.cards[index].updatedAt = now

        case let .deleteCard(id):
            guard let existing = board.card(id) else { return .failure(.unknownCard(id)) }
            inverse = .restoreCard(existing)
            next.cards.removeAll { $0.id == id }

        case let .restoreCard(card):
            guard board.card(card.id) == nil else { return .failure(.duplicateCard(card.id)) }
            guard board.column(card.columnId) != nil else { return .failure(.unknownColumn(card.columnId)) }
            inverse = .deleteCard(id: card.id)
            next.cards.append(card)

        case let .setCardLinks(id, links):
            guard let index = next.cards.firstIndex(where: { $0.id == id }) else {
                return .failure(.unknownCard(id))
            }
            inverse = .setCardLinks(id: id, links: next.cards[index].links)
            next.cards[index].links = links
            next.cards[index].updatedAt = now

        case let .createColumn(id, name, after, before):
            guard board.column(id) == nil else { return .failure(.duplicateColumn(id)) }
            let resolved: ResolvedColumnPosition
            switch columnPosition(in: board, after: after, before: before, moving: nil) {
            case .failure(let error): return .failure(error)
            case .success(let value): resolved = value
            }
            rebased = resolved.rebased
            next = resolved.board
            next.columns.append(BoardColumn(id: id, name: name, position: resolved.position))
            inverse = .deleteColumn(id: id, reassignCardsTo: nil)

        case let .renameColumn(id, name):
            guard let index = next.columns.firstIndex(where: { $0.id == id }) else {
                return .failure(.unknownColumn(id))
            }
            inverse = .renameColumn(id: id, name: next.columns[index].name)
            next.columns[index].name = name

        case let .moveColumn(id, after, before):
            guard board.column(id) != nil else { return .failure(.unknownColumn(id)) }
            inverse = .moveColumn(
                id: id,
                after: columnNeighbour(of: id, in: board, offset: -1),
                before: columnNeighbour(of: id, in: board, offset: +1))
            let resolved: ResolvedColumnPosition
            switch columnPosition(in: board, after: after, before: before, moving: id) {
            case .failure(let error): return .failure(error)
            case .success(let value): resolved = value
            }
            rebased = resolved.rebased
            next = resolved.board
            guard let index = next.columns.firstIndex(where: { $0.id == id }) else {
                return .failure(.unknownColumn(id))
            }
            next.columns[index].position = resolved.position

        case let .deleteColumn(id, reassignCardsTo):
            guard let existing = board.column(id) else { return .failure(.unknownColumn(id)) }
            guard board.columns.count > 1 else { return .failure(.lastColumn) }
            let members = board.orderedCards(in: id)
            if !members.isEmpty {
                guard let destination = reassignCardsTo, destination != id,
                      board.column(destination) != nil else {
                    return .failure(.invalidReassignment)
                }
                // Appended in their existing relative order, after whatever the
                // destination already holds. Reassignment must never reorder the
                // destination's own cards.
                var cursor = board.orderedCards(in: destination).last?.position
                for member in members {
                    guard let index = next.cards.firstIndex(where: { $0.id == member.id }) else { continue }
                    let position = cursor.map { FracIndex.after($0) } ?? FracIndex(value: 0.5)
                    next.cards[index].columnId = destination
                    next.cards[index].position = position
                    next.cards[index].updatedAt = now
                    cursor = position
                }
                next = renormalizeIfNeeded(next, columnId: destination)
            }
            inverse = .restoreColumn(existing, cards: members)
            next.columns.removeAll { $0.id == id }

        case let .restoreColumn(column, cards):
            guard board.column(column.id) == nil else { return .failure(.duplicateColumn(column.id)) }
            inverse = .deleteColumn(
                id: column.id,
                reassignCardsTo: cards.isEmpty ? nil : board.orderedColumns.first(where: { $0.id != column.id })?.id)
            next.columns.append(column)
            // Restore each card verbatim; a card the user separately deleted in
            // the meantime is skipped rather than resurrected.
            for card in cards {
                if let index = next.cards.firstIndex(where: { $0.id == card.id }) {
                    next.cards[index] = card
                } else {
                    next.cards.append(card)
                }
            }

        case let .renameBoard(title):
            inverse = .renameBoard(title: board.title)
            next.title = title
        }

        next.revision = board.revision &+ 1
        return .success(BoardTransaction(
            id: transactionId, command: command, inverse: inverse,
            before: board, after: next, rebasedAnchors: rebased))
    }

    // MARK: - Position resolution

    private struct ResolvedPosition {
        let position: FracIndex
        let board: Board
        let rebased: Bool
    }

    private struct ResolvedColumnPosition {
        let position: FracIndex
        let board: Board
        let rebased: Bool
    }

    /// Where a card lands, given neighbour anchors. `moving` is excluded from the
    /// sibling set so a card dragged within its own column is not asked to sit
    /// beside itself.
    private static func cardPosition(
        in board: Board, columnId: UUID, after: UUID?, before: UUID?, moving: UUID?
    ) -> Result<ResolvedPosition, BoardCommandError> {
        var working = board
        var siblings = working.orderedCards(in: columnId).filter { $0.id != moving }

        func resolve() -> (FracIndex, Bool)? {
            let afterIndex = after.flatMap { id in siblings.firstIndex(where: { $0.id == id }) }
            let beforeIndex = before.flatMap { id in siblings.firstIndex(where: { $0.id == id }) }
            // An anchor that was asked for but is not in this column means the
            // board moved under the caller. Adjacency is re-derived from the
            // anchor that DID survive; only when neither survives is the move
            // unresolvable.
            let rebased = (after != nil && afterIndex == nil) || (before != nil && beforeIndex == nil)
                || (afterIndex.map { lo in beforeIndex.map { $0 != lo + 1 } ?? false } ?? false)

            let lo: FracIndex?
            let hi: FracIndex?
            switch (afterIndex, beforeIndex) {
            case let (a?, b?) where b == a + 1:
                lo = siblings[a].position; hi = siblings[b].position
            case let (a?, _):
                lo = siblings[a].position
                hi = a + 1 < siblings.count ? siblings[a + 1].position : nil
            case let (_, b?):
                lo = b > 0 ? siblings[b - 1].position : nil
                hi = siblings[b].position
            case (nil, nil):
                if after != nil || before != nil { return nil }
                lo = siblings.last?.position; hi = nil
            }

            switch (lo, hi) {
            case let (lo?, hi?):
                guard lo < hi else { return nil }
                let candidate = FracIndex.between(lo, hi)
                guard candidate > lo, candidate < hi else { return nil }  // precision exhausted
                return (candidate, rebased)
            case let (lo?, nil):
                let candidate = FracIndex.after(lo)
                guard candidate > lo else { return nil }
                return (candidate, rebased)
            case let (nil, hi?):
                let candidate = FracIndex.before(hi)
                guard candidate < hi else { return nil }
                return (candidate, rebased)
            case (nil, nil):
                return (FracIndex(value: 0.5), rebased)
            }
        }

        if let (position, rebased) = resolve() {
            return .success(ResolvedPosition(position: position, board: working, rebased: rebased))
        }
        // Either the anchors are genuinely gone, or double precision ran out
        // between two adjacent cards. Redistributing the column evenly restores
        // headroom without changing anyone's order, then the same resolution is
        // retried exactly once. `FracIndex` never traps here: it degrades to a
        // tie, and this is the path that stops the tie from ever being needed.
        guard after != nil || before != nil else { return .failure(.anchorsUnavailable) }
        let anchorsExist = [after, before].compactMap { $0 }.allSatisfy { id in
            working.cards.contains { $0.id == id && $0.columnId == columnId }
        }
        guard anchorsExist else { return .failure(.anchorsUnavailable) }
        working = renormalize(working, columnId: columnId)
        siblings = working.orderedCards(in: columnId).filter { $0.id != moving }
        guard let (position, _) = resolve() else { return .failure(.anchorsUnavailable) }
        return .success(ResolvedPosition(position: position, board: working, rebased: true))
    }

    private static func columnPosition(
        in board: Board, after: UUID?, before: UUID?, moving: UUID?
    ) -> Result<ResolvedColumnPosition, BoardCommandError> {
        let siblings = board.orderedColumns.filter { $0.id != moving }
        let afterIndex = after.flatMap { id in siblings.firstIndex(where: { $0.id == id }) }
        let beforeIndex = before.flatMap { id in siblings.firstIndex(where: { $0.id == id }) }
        let rebased = (after != nil && afterIndex == nil) || (before != nil && beforeIndex == nil)

        let lo: FracIndex?
        let hi: FracIndex?
        switch (afterIndex, beforeIndex) {
        case let (a?, b?) where b == a + 1:
            lo = siblings[a].position; hi = siblings[b].position
        case let (a?, _):
            lo = siblings[a].position
            hi = a + 1 < siblings.count ? siblings[a + 1].position : nil
        case let (_, b?):
            lo = b > 0 ? siblings[b - 1].position : nil
            hi = siblings[b].position
        case (nil, nil):
            lo = siblings.last?.position; hi = nil
        }

        let position: FracIndex
        switch (lo, hi) {
        case let (lo?, hi?):
            guard lo < hi else { return .failure(.anchorsUnavailable) }
            let candidate = FracIndex.between(lo, hi)
            guard candidate > lo, candidate < hi else { return .failure(.anchorsUnavailable) }
            position = candidate
        case let (lo?, nil):
            let candidate = FracIndex.after(lo)
            guard candidate > lo else { return .failure(.anchorsUnavailable) }
            position = candidate
        case let (nil, hi?):
            let candidate = FracIndex.before(hi)
            guard candidate < hi else { return .failure(.anchorsUnavailable) }
            position = candidate
        case (nil, nil):
            position = FracIndex(value: 0.5)
        }
        return .success(ResolvedColumnPosition(position: position, board: board, rebased: rebased))
    }

    /// Spread one column's cards evenly across (0, 1), preserving their exact
    /// current order. Order-preserving by construction, so it is invisible to
    /// the user and safe to run whenever headroom runs out.
    private static func renormalize(_ board: Board, columnId: UUID) -> Board {
        var next = board
        let ordered = board.orderedCards(in: columnId)
        let positions = FracIndex.distribute(count: ordered.count)
        for (card, position) in zip(ordered, positions) {
            guard let index = next.cards.firstIndex(where: { $0.id == card.id }) else { continue }
            next.cards[index].position = position
        }
        return next
    }

    private static func renormalizeIfNeeded(_ board: Board, columnId: UUID) -> Board {
        let ordered = board.orderedCards(in: columnId)
        // Adjacent equal positions mean `after` hit its exhaustion tie. Redistribute
        // before the tie becomes load-bearing.
        for (lhs, rhs) in zip(ordered, ordered.dropFirst()) where !(lhs.position < rhs.position) {
            return renormalize(board, columnId: columnId)
        }
        return board
    }

    // MARK: - Neighbour lookup (used to build inverses)

    private static func neighbour(of id: UUID, in board: Board, offset: Int) -> UUID? {
        guard let card = board.card(id) else { return nil }
        let ordered = board.orderedCards(in: card.columnId)
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return nil }
        let target = index + offset
        guard target >= 0, target < ordered.count else { return nil }
        return ordered[target].id
    }

    private static func columnNeighbour(of id: UUID, in board: Board, offset: Int) -> UUID? {
        let ordered = board.orderedColumns
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return nil }
        let target = index + offset
        guard target >= 0, target < ordered.count else { return nil }
        return ordered[target].id
    }
}

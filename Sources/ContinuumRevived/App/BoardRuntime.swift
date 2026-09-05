import AppKit
import ContinuumRevivedCore

// KB-01. The single authority for one project's boards.
// Plan: .plans/60-kanban-board.md
//
// Views render; this applies. Every mutation — pointer drag, keyboard, palette,
// and (when CX-01 lands) the canvas API — arrives as a `BoardCommand`, goes
// through `BoardEngine`, is persisted, and is broadcast to every attached view.
// Two tiles showing one board therefore cannot disagree, and an agent-originated
// move is indistinguishable from a pointer one by the time it reaches the model.

/// What happened to a command. Reported rather than swallowed: a caller that
/// cannot tell "applied" from "rejected" is a hidden race.
enum BoardCommandOutcome: Equatable {
    case applied(revision: UInt64)
    /// Anchors no longer described adjacent cards; the engine re-derived the
    /// position against the board's current neighbours.
    case rebased(revision: UInt64)
    /// The command names the card the pointer is currently carrying. Refused so
    /// the model cannot move under the user's finger mid-drag.
    case rejectedCardHeldByPointer
    case rejected(BoardCommandError)
    /// Persistence failed; the in-memory board was rolled back to match disk.
    case persistenceFailed(String)
}

@MainActor
final class BoardRuntime {
    private let projectStore: any ProjectStoring
    private var boards: [UUID: Board] = [:]
    private var views: [UUID: [WeakBoardView]] = [:]
    private var histories: [UUID: BoardHistoryController] = [:]

    /// The card a pointer drag is currently carrying, if any. An API command
    /// that would move or delete THIS card is rejected rather than applied under
    /// the user's finger; anything else applies immediately and the live drag
    /// absorbs it on its next pointer event.
    private(set) var cardHeldByPointer: UUID?

    init(projectStore: any ProjectStoring) {
        self.projectStore = projectStore
    }

    // MARK: - Reading

    /// The board for `id`, loaded from disk on first use and cached after.
    func board(id: UUID) -> Board? {
        if let cached = boards[id] { return cached }
        guard let loaded = try? projectStore.tryLoadBoard(id: id) ?? nil else { return nil }
        boards[id] = loaded
        return loaded
    }

    /// Creates and persists a new board with the default columns. Used by the
    /// spawn path; returns nil only if the store refuses the write, in which case
    /// the caller must not create the tile either.
    func createBoard(id: UUID, title: String, now: Date = Date()) -> Board? {
        let board = Board.makeDefault(id: id, title: title, now: now)
        do {
            try projectStore.saveBoard(board)
            var state = (try? projectStore.tryLoadBoardState() ?? nil) ?? BoardState(boards: [])
            state.boards.append(BoardIndexEntry(
                id: id, tileId: nil, title: title, createdAt: now, updatedAt: now))
            try projectStore.saveBoardState(state)
        } catch {
            return nil
        }
        boards[id] = board
        return board
    }

    // MARK: - View attachment

    func attach(_ view: KanbanTileNSView, to boardId: UUID) {
        var existing = (views[boardId] ?? []).filter { $0.view != nil }
        guard !existing.contains(where: { $0.view === view }) else { return }
        existing.append(WeakBoardView(view: view))
        views[boardId] = existing
        view.boardRuntime = self
        view.boardIdForUndo = boardId
        view.onCommand = { [weak self, weak view] command in
            guard let self, let view else { return }
            _ = self.apply(command, to: boardId, originatingView: view)
        }
        if let board = board(id: boardId) { view.render(board) }
    }

    func detach(_ view: KanbanTileNSView) {
        for (boardId, entries) in views {
            views[boardId] = entries.filter { $0.view !== view && $0.view != nil }
        }
    }

    /// The undo stack for a board, created on first use. Deliberately NOT the
    /// canvas geometry stack: that one replays `CanvasGeometryTransaction`s and
    /// wipes itself whenever live geometry does not match its snapshot.
    func history(for boardId: UUID) -> BoardHistoryController {
        if let existing = histories[boardId] { return existing }
        let controller = BoardHistoryController(boardId: boardId, runtime: self)
        histories[boardId] = controller
        return controller
    }

    // MARK: - Drag lease

    func beginPointerDrag(cardId: UUID) { cardHeldByPointer = cardId }
    func endPointerDrag() { cardHeldByPointer = nil }

    // MARK: - Writing — the one path

    @discardableResult
    func apply(
        _ command: BoardCommand,
        to boardId: UUID,
        originatingView: KanbanTileNSView? = nil,
        recordUndo: Bool = true,
        now: Date = Date()
    ) -> BoardCommandOutcome {
        guard let current = board(id: boardId) else {
            return .rejected(.unknownCard(boardId))
        }
        // The drag lease. An API edit that names the held card is refused with a
        // reason; anything else lands and the drag picks it up next event.
        if let held = cardHeldByPointer, command.touches(cardId: held, in: current) {
            return .rejectedCardHeldByPointer
        }

        let transaction: BoardTransaction
        switch BoardEngine.apply(command, to: current, now: now) {
        case .failure(let error): return .rejected(error)
        case .success(let value): transaction = value
        }

        // Persist BEFORE publishing. A view that renders a state the disk does
        // not hold is a lie that survives relaunch.
        do {
            try projectStore.saveBoard(transaction.after)
        } catch {
            boards[boardId] = transaction.before
            broadcast(transaction.before, for: boardId)
            return .persistenceFailed(error.localizedDescription)
        }

        boards[boardId] = transaction.after
        if recordUndo { history(for: boardId).record(transaction) }
        broadcast(transaction.after, for: boardId, skipping: nil)
        return transaction.rebasedAnchors
            ? .rebased(revision: transaction.after.revision)
            : .applied(revision: transaction.after.revision)
    }

    /// Undo/redo replay. Goes through `apply` so the inverse is validated by the
    /// same reducer as live input — a replay that bypassed validation could
    /// install a board the engine would have refused.
    @discardableResult
    func applyForHistory(_ command: BoardCommand, to boardId: UUID) -> BoardCommandOutcome {
        apply(command, to: boardId, recordUndo: false)
    }

    private func broadcast(_ board: Board, for boardId: UUID, skipping: KanbanTileNSView? = nil) {
        let live = (views[boardId] ?? []).filter { $0.view != nil }
        views[boardId] = live
        for entry in live {
            guard let view = entry.view, view !== skipping else { continue }
            view.render(board)
        }
    }

    // MARK: - Lifecycle

    /// Closing a board TILE is closing a window, not deleting the board — the
    /// same rule `case .managedAgent` states for agents. The index entry loses
    /// its tile pointer and the file stays.
    func detachTile(_ tileId: UUID, boardId: UUID) {
        Self.detachTile(tileId, boardId: boardId, in: projectStore)
    }

    /// The same index edit for callers that hold a store but no runtime — the
    /// tile-delete path resolves a `ProjectStoring`, not a controller. One
    /// implementation, so the two cannot drift.
    static func detachTile(_ tileId: UUID, boardId: UUID, in store: any ProjectStoring) {
        guard var state = try? store.tryLoadBoardState() ?? nil else { return }
        guard let index = state.boards.firstIndex(where: { $0.id == boardId }) else { return }
        guard state.boards[index].tileId == tileId else { return }
        state.boards[index].tileId = nil
        try? store.saveBoardState(state)
    }

    func bindTile(_ tileId: UUID, to boardId: UUID) {
        guard var state = try? projectStore.tryLoadBoardState() ?? nil else { return }
        guard let index = state.boards.firstIndex(where: { $0.id == boardId }) else { return }
        state.boards[index].tileId = tileId
        try? projectStore.saveBoardState(state)
    }
}

private struct WeakBoardView {
    weak var view: KanbanTileNSView?
}

extension BoardCommand {
    /// Whether this command would move or remove a specific card — the test the
    /// drag lease uses. Deliberately NARROW: a command that merely happens to be
    /// concurrent with a drag must still apply, or the board would freeze for as
    /// long as a pointer is down.
    func touches(cardId: UUID, in board: Board) -> Bool {
        switch self {
        case let .editCard(id, _, _), let .moveCard(id, _, _, _),
             let .deleteCard(id), let .setCardLinks(id, _):
            return id == cardId
        case let .restoreCard(card):
            return card.id == cardId
        case let .deleteColumn(id, _):
            // Deleting the held card's own column moves that card too.
            return board.card(cardId)?.columnId == id
        case .createCard, .createColumn, .renameColumn, .moveColumn,
             .restoreColumn, .renameBoard:
            return false
        }
    }
}

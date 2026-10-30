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

enum BoardLifecycleError: LocalizedError {
    case boardUnavailable
    case boardAlreadyOpen
    case bindingChanged
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .boardUnavailable: return "This board is unavailable."
        case .boardAlreadyOpen: return "This board already has an open tile."
        case .bindingChanged: return "The board's open tile changed. Try again."
        case .rollbackFailed(let message): return "The board could not be restored: \(message)"
        }
    }
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

    /// Refresh document lists after a committed metadata or binding change.
    var onBoardIndexChanged: (() -> Void)?

    /// Applied to every tile this runtime adopts. The app installs it once; the
    /// runtime knows nothing about agents or supervisors itself.
    var tileConfigurator: ((KanbanTileNSView) -> Void)?
    /// Installed by the app once. Runs for UI, API, automatic lifecycle and
    /// undo/redo commits alike so assignment context cannot drift by origin.
    /// The second argument is the managed agent whose workspace-API call made
    /// the commit, or nil for the user and Array's own automation.
    var onCommittedTransaction: ((BoardTransaction, AgentID?) -> Void)?

    init(projectStore: any ProjectStoring) {
        self.projectStore = projectStore
    }

    // MARK: - Reading

    /// The board for `id`, loaded from disk on first use and cached after.
    func board(id: UUID) -> Board? {
        if let cached = boards[id] { return cached }
        // Recovery backups may outlive deliberate deletion. Only indexed
        // documents are live; never resurrect one by loading an old backup.
        guard boardIndexEntries().contains(where: { $0.id == id }) else { return nil }
        guard let loaded = try? projectStore.tryLoadBoard(id: id) ?? nil else { return nil }
        boards[id] = loaded
        return loaded
    }

    /// The durable board index, including documents whose tile is currently
    /// closed. Query callers use the index for discovery and `board(id:)` for
    /// authoritative current contents.
    func boardIndexEntries() -> [BoardIndexEntry] {
        ((try? projectStore.tryLoadBoardState()) ?? nil)?.boards ?? []
    }

    /// Creates and persists a new board with the default columns. Used by the
    /// spawn path; returns nil only if the store refuses the write, in which case
    /// the caller must not create the tile either.
    func createBoard(id: UUID, title: String, now: Date = Date()) -> Board? {
        let board = Board.makeDefault(id: id, title: title, now: now)
        do {
            var state = try projectStore.tryLoadBoardState() ?? BoardState(boards: [])
            guard !state.boards.contains(where: { $0.id == id }) else { return nil }
            try projectStore.saveBoard(board)
            state.boards.append(BoardIndexEntry(
                id: id, tileId: nil, title: title, createdAt: now, updatedAt: now))
            do { try projectStore.saveBoardState(state) }
            catch {
                // Creation never leaves an undiscoverable document on an index failure.
                try? projectStore.deleteBoard(id: id)
                return nil
            }
        } catch {
            return nil
        }
        boards[id] = board
        onBoardIndexChanged?()
        return board
    }

    // MARK: - View attachment

    func attach(_ view: KanbanTileNSView, to boardId: UUID) {
        // A tile can switch documents; remove its previous command/undo owner first.
        detach(view)
        var existing = (views[boardId] ?? []).filter { $0.view != nil }
        guard !existing.contains(where: { $0.view === view }) else { return }
        existing.append(WeakBoardView(view: view))
        views[boardId] = existing
        view.boardRuntime = self
        view.boardIdForUndo = boardId
        view.onCommand = { [weak self, weak view] command in
            guard let self, let view else { return }
            switch self.apply(command, to: boardId, originatingView: view) {
            case .applied, .rebased: break
            case .persistenceFailed(let message): view.onTaskActionError?(message)
            case .rejected(let error): view.onTaskActionError?(error.description)
            case .rejectedCardHeldByPointer:
                view.onTaskActionError?("Finish dragging this task before changing it.")
            }
        }
        tileConfigurator?(view)
        if let board = board(id: boardId) {
            view.setTitleBarIdentity(title: board.title)
            view.render(board)
        }
    }

    func detach(_ view: KanbanTileNSView) {
        for (boardId, entries) in views {
            views[boardId] = entries.filter { $0.view !== view && $0.view != nil }
        }
        view.onCommand = nil
        view.boardRuntime = nil
        view.boardIdForUndo = nil
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
        actingAgent: AgentID? = nil,
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
            // Read before writing so a damaged index cannot be silently replaced.
            let storedState = try projectStore.tryLoadBoardState()
            try projectStore.saveBoard(transaction.after)
            if var state = storedState,
               let index = state.boards.firstIndex(where: { $0.id == boardId }) {
                state.boards[index].title = transaction.after.title
                state.boards[index].updatedAt = now
                do {
                    try projectStore.saveBoardState(state)
                } catch {
                    do { try projectStore.saveBoard(transaction.before) }
                    catch {
                        // The durable board remains authoritative even if rollback fails.
                        boards.removeValue(forKey: boardId)
                        if let durable = board(id: boardId) { broadcast(durable, for: boardId) }
                        return .persistenceFailed(BoardLifecycleError.rollbackFailed(error.localizedDescription).localizedDescription)
                    }
                    throw error
                }
            }
        } catch {
            boards[boardId] = transaction.before
            broadcast(transaction.before, for: boardId)
            return .persistenceFailed(error.localizedDescription)
        }

        boards[boardId] = transaction.after
        if recordUndo { history(for: boardId).record(transaction) }
        broadcast(transaction.after, for: boardId, skipping: nil)
        onBoardIndexChanged?()
        onCommittedTransaction?(transaction, actingAgent)
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

    /// The accepted-send lifecycle hook. Starting an attached task advances it
    /// from the first ordered lane to the end of the second, but only while the
    /// assignment still names the sending agent. `apply` supplies persistence,
    /// drag refusal, broadcast, assignment synchronization and one undo.
    @discardableResult
    func advanceAssignedTaskAfterAcceptedSend(
        boardId: UUID,
        cardId: UUID,
        agentId: AgentID
    ) -> BoardCommandOutcome? {
        guard let board = board(id: boardId),
              let card = board.card(cardId),
              card.assignee == agentId,
              board.orderedColumns.count > 1,
              card.columnId == board.orderedColumns[0].id else { return nil }
        let destination = board.orderedColumns[1].id
        return apply(
            .moveCard(
                id: card.id,
                toColumn: destination,
                after: board.orderedCards(in: destination).last?.id,
                before: nil),
            to: board.id)
    }

    private func broadcast(_ board: Board, for boardId: UUID, skipping: KanbanTileNSView? = nil) {
        let live = (views[boardId] ?? []).filter { $0.view != nil }
        views[boardId] = live
        for entry in live {
            guard let view = entry.view, view !== skipping else { continue }
            view.setTitleBarIdentity(title: board.title)
            view.render(board)
        }
    }

    // MARK: - Lifecycle

    /// Closing a board TILE is closing a window, not deleting the board — the
    /// same rule `case .managedAgent` states for agents. The index entry loses
    /// its tile pointer and the file stays.
    @discardableResult
    func detachTile(_ tileId: UUID, boardId: UUID) -> Error? {
        let error = Self.detachTile(tileId, boardId: boardId, in: projectStore)
        if error == nil { onBoardIndexChanged?() }
        return error
    }

    @discardableResult
    static func detachTile(_ tileId: UUID, boardId: UUID, in store: any ProjectStoring) -> Error? {
        do {
            guard var state = try store.tryLoadBoardState(),
                  let index = state.boards.firstIndex(where: { $0.id == boardId }),
                  state.boards[index].tileId == tileId else { return nil }
            state.boards[index].tileId = nil
            try store.saveBoardState(state)
            return nil
        } catch { return error }
    }

    @discardableResult
    func bindTile(_ tileId: UUID, to boardId: UUID) -> Error? {
        do { try setTileBinding(tileId, for: boardId); return nil }
        catch { return error }
    }

    /// The index is a discovery aid. Callers first resolve actual canvas ownership;
    /// this guards against overwriting another tile's durable binding.
    func setTileBinding(_ tileId: UUID?, for boardId: UUID) throws {
        guard var state = try projectStore.tryLoadBoardState(),
              let index = state.boards.firstIndex(where: { $0.id == boardId }),
              board(id: boardId) != nil else { throw BoardLifecycleError.boardUnavailable }
        if let existing = state.boards[index].tileId, let tileId, existing != tileId {
            throw BoardLifecycleError.boardAlreadyOpen
        }
        state.boards[index].tileId = tileId
        try projectStore.saveBoardState(state)
        onBoardIndexChanged?()
    }

    /// One index write changes both bindings; failure leaves both unchanged.
    func switchTileBinding(_ tileId: UUID, from sourceId: UUID, to destinationId: UUID) throws {
        guard sourceId != destinationId else { return }
        guard var state = try projectStore.tryLoadBoardState(),
              let source = state.boards.firstIndex(where: { $0.id == sourceId }),
              let destination = state.boards.firstIndex(where: { $0.id == destinationId }),
              board(id: destinationId) != nil else { throw BoardLifecycleError.boardUnavailable }
        guard state.boards[source].tileId == tileId else { throw BoardLifecycleError.bindingChanged }
        guard state.boards[destination].tileId == nil else { throw BoardLifecycleError.boardAlreadyOpen }
        state.boards[source].tileId = nil
        state.boards[destination].tileId = tileId
        try projectStore.saveBoardState(state)
        onBoardIndexChanged?()
    }

    /// Permanent deletion is separate from closing and requires a closed board.
    /// Remove the document first, then its index; restore the document if the
    /// index write fails. Attachments are retained because other cards may share them.
    func deleteClosedBoard(id: UUID) throws {
        guard var state = try projectStore.tryLoadBoardState(),
              let index = state.boards.firstIndex(where: { $0.id == id }),
              let current = board(id: id) else { throw BoardLifecycleError.boardUnavailable }
        guard state.boards[index].tileId == nil else { throw BoardLifecycleError.boardAlreadyOpen }
        try projectStore.deleteBoard(id: id)
        state.boards.remove(at: index)
        do { try projectStore.saveBoardState(state) }
        catch {
            let original = error
            do { try projectStore.saveBoard(current) }
            catch { throw BoardLifecycleError.rollbackFailed(error.localizedDescription) }
            throw original
        }
        boards.removeValue(forKey: id)
        histories.removeValue(forKey: id)
        views.removeValue(forKey: id)
        onBoardIndexChanged?()
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
        case let .editTask(id, _, _), let .editCard(id, _, _), let .editTaskFields(id, _, _, _),
             let .moveCard(id, _, _, _),
             let .deleteCard(id), let .setCardLinks(id, _), let .assignCard(id, _):
            return id == cardId
        case let .restoreCard(card):
            return card.id == cardId
        case let .deleteColumn(id, _):
            // Deleting the held card's own column moves that card too.
            return board.card(cardId)?.columnId == id
        case .createCard, .createTask, .createColumn, .renameColumn, .moveColumn,
             .restoreColumn, .renameBoard:
            return false
        }
    }
}

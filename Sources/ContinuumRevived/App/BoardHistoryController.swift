import AppKit
import ContinuumRevivedCore

// KB-01. One board's undo stack. Plan: .plans/60-kanban-board.md
//
// Deliberately NOT `CanvasHistoryController`. That one replays
// `CanvasGeometryTransaction`s, guards each replay on `canvas.geometryMatches`,
// and WIPES ITS WHOLE STACK when the live geometry has moved on — correct for
// geometry, and wrong for board data, where a concurrent card edit somewhere
// else on the board must not destroy the user's undo history.
//
// One accepted move is one undo group. A cancelled drag registers nothing at
// all, because a cancelled drag never reaches the engine.

@MainActor
final class BoardHistoryController {
    let undoManager: UndoManager
    private let boardId: UUID
    private weak var runtime: BoardRuntime?
    private var isReplaying = false

    init(boardId: UUID, runtime: BoardRuntime, levelsOfUndo: Int = 100) {
        self.boardId = boardId
        self.runtime = runtime
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.levelsOfUndo = levelsOfUndo
        undoManager = manager
    }

    func record(_ transaction: BoardTransaction) {
        guard !transaction.isNoOp else { return }
        register(command: transaction.inverse, redo: transaction.command, name: transaction.actionName)
    }

    func removeAllActions() { undoManager.removeAllActions() }

    private func register(command: BoardCommand, redo: BoardCommand, name: String) {
        let needsGroup = !isReplaying
        if needsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { target in
            target.replay(command, opposite: redo, name: name)
        }
        undoManager.setActionName(name)
        if needsGroup { undoManager.endUndoGrouping() }
    }

    private func replay(_ command: BoardCommand, opposite: BoardCommand, name: String) {
        isReplaying = true
        defer { isReplaying = false }
        guard let runtime else { return }
        // Replay goes through the SAME reducer as live input. A replay that
        // installed a board directly could install one the engine would refuse.
        switch runtime.applyForHistory(command, to: boardId) {
        case .applied, .rebased:
            register(command: opposite, redo: command, name: name)
        case .rejected, .rejectedCardHeldByPointer, .persistenceFailed:
            // The board moved somewhere this inverse can no longer describe.
            // Drop the rest of the stack rather than replay a command whose
            // meaning has changed — but only this board's stack.
            DispatchQueue.main.async { [weak self] in self?.undoManager.removeAllActions() }
        }
    }
}

extension BoardTransaction {
    /// What the Edit menu says. Named for the user's action, not the internal
    /// command shape.
    var actionName: String {
        switch command {
        case .createCard: return "Add Card"
        case .editCard: return "Edit Card"
        case .moveCard: return "Move Card"
        case .deleteCard, .restoreCard: return "Delete Card"
        case .setCardLinks: return "Change Card Links"
        case .assignCard(_, let agent): return agent == nil ? "Unassign Task" : "Assign Task"
        case .createColumn: return "Add Column"
        case .renameColumn: return "Rename Column"
        case .moveColumn: return "Move Column"
        case .deleteColumn, .restoreColumn: return "Delete Column"
        case .renameBoard: return "Rename Board"
        }
    }
}

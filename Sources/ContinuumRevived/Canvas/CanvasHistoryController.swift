import AppKit
import ContinuumRevivedCore
import Foundation

/// Session-scoped history for one workspace. The controller resolves the live
/// canvas at execution time; undo closures never retain a tile view that may have
/// been replaced during hydration or a workspace switch.
@MainActor
final class CanvasHistoryController: NSObject {
    enum Direction { case undo, redo }

    let undoManager: UndoManager
    weak var canvas: CanvasNSView?
    var onInvalidated: (() -> Void)?
    private var isReplayingHistory = false

    init(canvas: CanvasNSView, levelsOfUndo: Int = 100) {
        self.canvas = canvas
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.levelsOfUndo = levelsOfUndo
        undoManager = manager
        super.init()
    }

    func record(_ transaction: CanvasGeometryTransaction) {
        guard !transaction.isNoOp else { return }
        register(transaction, direction: .undo)
    }

    func removeAllActions() {
        undoManager.removeAllActions()
    }

    private func register(_ transaction: CanvasGeometryTransaction, direction: Direction) {
        let needsGroup = !isReplayingHistory
        if needsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { target in
            target.apply(transaction, direction: direction)
        }
        undoManager.setActionName(transaction.action.displayName)
        if needsGroup { undoManager.endUndoGrouping() }
    }

    private func apply(_ transaction: CanvasGeometryTransaction, direction: Direction) {
        isReplayingHistory = true
        defer { isReplayingHistory = false }
        guard let canvas else {
            invalidateAfterReplay()
            return
        }
        let expected = direction == .undo ? transaction.after : transaction.before
        let destination = direction == .undo ? transaction.before : transaction.after
        guard canvas.geometryMatches(expected) else {
            onInvalidated?()
            invalidateAfterReplay()
            return
        }
        canvas.applyGeometrySnapshot(destination, previous: expected)
        register(transaction, direction: direction == .undo ? .redo : .undo)
    }

    /// Foundation is still closing its internal replay group while invoking an
    /// undo closure. Clearing the manager synchronously there corrupts that
    /// group; defer invalidation to the next main-loop turn.
    private func invalidateAfterReplay() {
        DispatchQueue.main.async { [weak self] in
            self?.undoManager.removeAllActions()
        }
    }
}

import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// KB-01. The pointer drag. Plan: .plans/60-kanban-board.md
//
// Three layers, exactly as the canvas does it for tiles:
//
//   free     `freePoint` accumulates the raw pointer with zero smoothing, and
//            the lifted copy tracks it directly. `TileNSView.mouseDragged`'s
//            `moveFreeWorldFrame` is the same idea.
//   preview  recomputed FROM SCRATCH every event by `BoardDragResolver` over
//            slots rebuilt from the LIVE model. Rebuilding rather than latching
//            is what makes an agent-originated move mid-drag get absorbed.
//   model    untouched until mouse-up, then exactly one command carrying the
//            previewed anchors. Nothing else writes.
//
// Cancel therefore costs nothing: no command was ever issued, so the order is
// unchanged and the undo stack never saw the gesture.

@MainActor
final class BoardDragSession {
    let cardId: UUID
    let sourceColumnId: UUID
    /// The lifted copy the pointer carries. A COPY, so the original can stay in
    /// its column as the vacated slot and the column's height never jumps.
    let liftedView: KanbanCardView
    /// Pointer offset within the card at mouse-down, so the card does not snap
    /// its corner to the cursor.
    let grabOffset: CGPoint
    var freePoint: CGPoint
    var target: BoardDragTarget?
    var didMove = false

    init(cardId: UUID, sourceColumnId: UUID, liftedView: KanbanCardView, grabOffset: CGPoint, freePoint: CGPoint) {
        self.cardId = cardId
        self.sourceColumnId = sourceColumnId
        self.liftedView = liftedView
        self.grabOffset = grabOffset
        self.freePoint = freePoint
    }
}

extension KanbanTileNSView {
    /// Distance from the body edge at which a drag starts scrolling the column.
    static let autoscrollEdge: CGFloat = 32
    static let autoscrollStep: CGFloat = 14

    // MARK: - Begin

    func beginCardDrag(cardId: UUID, event: NSEvent) {
        guard dragSession == nil else { return }
        guard let card = board.card(cardId),
              let cardViewInColumn = cardView(for: cardId),
              let column = columnView(for: card.columnId) else { return }

        // Editing must commit before a drag; a half-typed title that vanishes
        // because the card moved is a data loss the user did not ask for.
        if case .editing = focusState { setFocusState(.selected(cardId)) }

        let pointInTile = convert(event.locationInWindow, from: nil)
        let cardFrame = cardViewInColumn.convert(cardViewInColumn.bounds, to: self)
        let lifted = KanbanCardView(cardId: cardId, title: card.title)
        // Exact dimensions preserved for the whole gesture.
        lifted.frame = cardFrame
        lifted.setSelected(true)
        addSubview(lifted, positioned: .above, relativeTo: nil)

        let session = BoardDragSession(
            cardId: cardId,
            sourceColumnId: card.columnId,
            liftedView: lifted,
            grabOffset: CGPoint(x: pointInTile.x - cardFrame.minX, y: pointInTile.y - cardFrame.minY),
            freePoint: pointInTile)
        dragSession = session

        column.setLifted(cardId)
        boardRuntime?.beginPointerDrag(cardId: cardId)
        installDragCancelMonitor()
        updateDragPreview(freePoint: pointInTile)
    }

    // MARK: - Track

    func continueCardDrag(event: NSEvent) {
        guard let session = dragSession else { return }
        session.didMove = true
        let point = convert(event.locationInWindow, from: nil)
        session.freePoint = point
        // Autoscroll first, then resolve — so the preview is computed against
        // slots in their POST-scroll positions and never lags the scroll.
        if let target = session.target, let column = columnView(for: target.columnId) {
            column.autoscroll(
                towards: point, in: self,
                edge: Self.autoscrollEdge, step: Self.autoscrollStep)
        }
        updateDragPreview(freePoint: point)
    }

    /// Rebuilds the slot set from the live views and re-resolves. Called every
    /// pointer event AND after any re-render, which is what makes a concurrent
    /// model change interruptible rather than a conflict.
    func updateDragPreview(freePoint: CGPoint) {
        guard let session = dragSession else { return }
        session.liftedView.setFrameOrigin(CGPoint(
            x: freePoint.x - session.grabOffset.x,
            y: freePoint.y - session.grabOffset.y))

        var slots: [BoardSlot] = []
        for column in allColumnViews {
            let geometry = column.slotGeometry(excluding: session.cardId, in: self)
            let bounds = column.columnBounds(in: self)
            slots += BoardDragResolver.slots(
                columnId: column.columnId,
                cardIds: geometry.ids,
                cardCenters: geometry.centers,
                cardTops: geometry.tops,
                cardBottoms: geometry.bottoms,
                emptyCenterY: geometry.emptyCenterY,
                columnMinX: bounds.minX,
                columnMaxX: bounds.maxX)
        }

        let resolved = BoardDragResolver.resolve(
            freePoint: freePoint,
            slots: slots,
            previous: session.target,
            zoom: canvasZoomForDrag)
        let changed = resolved != session.target
        session.target = resolved

        let gapHeight = session.liftedView.frame.height
        for column in allColumnViews {
            if let resolved, column.columnId == resolved.columnId {
                column.setLifted(session.cardId)
                column.setPreviewGap(index: resolved.index, height: gapHeight, animated: changed)
            } else {
                column.setPreviewGap(index: nil, height: 0, animated: changed)
            }
        }
    }

    // MARK: - Commit

    func finishCardDrag() {
        guard let session = dragSession else { return }
        // A click that never moved is a selection, not a move.
        guard session.didMove, let target = session.target else {
            endDragSession(commit: false)
            setFocusState(.selected(session.cardId))
            return
        }
        // EXACTLY the previewed anchors. Not "nearest slot at mouse-up" — a fast
        // release would then land somewhere the preview never showed.
        let command = target.moveCommand(for: session.cardId)
        endDragSession(commit: true)
        onCommand?(command)
        setFocusState(.selected(session.cardId))
    }

    /// Esc, app deactivation, or an interrupted AppKit sequence. The model was
    /// never touched, so there is nothing to roll back and nothing lands on the
    /// undo stack.
    func cancelCardDrag() {
        guard dragSession != nil else { return }
        endDragSession(commit: false)
    }

    private func endDragSession(commit: Bool) {
        guard let session = dragSession else { return }
        removeDragCancelMonitor()
        boardRuntime?.endPointerDrag()
        session.liftedView.removeFromSuperview()
        for column in allColumnViews { column.clearDragState() }
        dragSession = nil
        if commit, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // The gap was already the card's exact size, so the settle has
            // nothing to correct — it only removes the lift.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = BoardDragConfig.settleDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                layoutSubtreeIfNeeded()
            }
        }
    }

    private func installDragCancelMonitor() {
        guard dragCancelMonitor == nil else { return }
        dragCancelMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.dragSession != nil, event.keyCode == 53 else { return event }
            self.cancelCardDrag()
            return nil
        }
    }

    private func removeDragCancelMonitor() {
        if let monitor = dragCancelMonitor { NSEvent.removeMonitor(monitor) }
        dragCancelMonitor = nil
    }
}

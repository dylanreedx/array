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
//            slots rebuilt from the LIVE model, and drawn by the same phantom
//            the canvas uses for tiles. Rebuilding rather than latching is what
//            makes an agent-originated move mid-drag get absorbed.
//   model    untouched until mouse-up, then exactly one command carrying the
//            previewed anchors. Nothing else writes.
//
// Cancel therefore costs nothing: no command was ever issued, so the order is
// unchanged and the undo stack never saw the gesture.
//
// A drag that leaves the board tile becomes an ASSIGNMENT gesture: the same
// carried card, now hunting for an agent to hand the task to.

@MainActor
final class BoardDragSession {
    let cardId: UUID
    let sourceColumnId: UUID
    /// The lifted copy the pointer carries. A COPY, so the original can stay in
    /// its lane as the vacated slot and the lane's height never jumps.
    let liftedView: KanbanCardView
    /// Pointer offset within the card at mouse-down, so the card does not snap
    /// its corner to the cursor.
    let grabOffset: CGPoint
    /// Whether the card was ALREADY selected when the gesture began. A click on
    /// an already-selected card opens it for editing; the first click only
    /// selects.
    let wasSelected: Bool
    var freePoint: CGPoint
    var target: BoardDragTarget?
    var didMove = false
    /// The agent tile the pointer is currently over, if the drag has left the
    /// board. Nil means this is still an ordinary reorder.
    var hoveredAgentTileId: UUID?

    init(
        cardId: UUID, sourceColumnId: UUID, liftedView: KanbanCardView,
        grabOffset: CGPoint, freePoint: CGPoint, wasSelected: Bool
    ) {
        self.cardId = cardId
        self.sourceColumnId = sourceColumnId
        self.liftedView = liftedView
        self.grabOffset = grabOffset
        self.freePoint = freePoint
        self.wasSelected = wasSelected
    }
}

extension KanbanTileNSView {
    /// Distance from the lane edge at which a drag starts scrolling it.
    static let autoscrollEdge: CGFloat = 32
    static let autoscrollStep: CGFloat = 14

    // MARK: - Begin

    func beginCardDrag(cardId: UUID, event: NSEvent, wasSelected: Bool) {
        guard dragSession == nil else { return }
        guard let card = board.card(cardId),
              let cardViewInColumn = cardView(for: cardId),
              let column = columnView(for: card.columnId) else { return }

        // Editing must commit before a drag; a half-typed title that vanishes
        // because the card moved is a data loss the user did not ask for.
        if case .editing = focusState { setFocusState(.selected(cardId)) }

        let pointInTile = convert(event.locationInWindow, from: nil)
        let cardFrame = cardViewInColumn.convert(cardViewInColumn.bounds, to: self)
        let lifted = KanbanCardView(card: card, assigneeName: assigneeName(for: card))
        // Exact dimensions preserved for the whole gesture.
        lifted.frame = cardFrame
        lifted.setSelected(true)
        lifted.ignoresHitTesting = true
        lifted.applyLiftedChrome()
        addSubview(lifted, positioned: .above, relativeTo: nil)

        let session = BoardDragSession(
            cardId: cardId,
            sourceColumnId: card.columnId,
            liftedView: lifted,
            grabOffset: CGPoint(x: pointInTile.x - cardFrame.minX, y: pointInTile.y - cardFrame.minY),
            freePoint: pointInTile,
            wasSelected: wasSelected)
        dragSession = session

        column.setLifted(cardId)
        takeKeyboardFocusIfIdle()
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

        // Has the card left the board? If so this is an assignment gesture and
        // the lane preview must get out of the way entirely — showing an
        // insertion slot for a card that is about to be handed to an agent would
        // promise a move that is not going to happen.
        if let agentTileId = agentTile(under: freePoint) {
            if session.hoveredAgentTileId != agentTileId {
                session.hoveredAgentTileId = agentTileId
                highlightAssignmentTarget(agentTileId, cardId: session.cardId)
            }
            session.target = nil
            for column in allColumnViews { column.setPreviewGap(index: nil, height: 0, animated: true) }
            hideCardGhost()
            return
        }
        if session.hoveredAgentTileId != nil {
            session.hoveredAgentTileId = nil
            canvas?.hideDragGhost()
        }

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
        // The phantom goes IN the gap the lane just opened, so the preview is the
        // destination itself rather than a second, separate hint.
        if let resolved, let column = columnView(for: resolved.columnId),
           let gap = column.previewGapFrame {
            showCardGhost(in: column, frame: gap)
        } else {
            hideCardGhost()
        }
    }

    // MARK: - The phantom

    private func showCardGhost(in column: KanbanColumnView, frame: NSRect) {
        let ghost = cardGhost ?? {
            let made = BoardCardGhostView(frame: .zero)
            cardGhost = made
            return made
        }()
        if ghost.superview !== column.ghostHost {
            ghost.removeFromSuperview()
            // Below the cards, so a displaced neighbour sliding over the gap is
            // drawn on top of the phantom rather than under it.
            column.ghostHost.addSubview(ghost, positioned: .below, relativeTo: nil)
        }
        ghost.show(at: frame)
    }

    private func hideCardGhost() { cardGhost?.hide() }

    /// Reuses the canvas's own drag phantom to mark the agent about to receive
    /// the task — the same affordance a tile drag uses for its destination.
    private func highlightAssignmentTarget(_ agentTileId: UUID, cardId: UUID) {
        guard let canvas, let agentView = canvas.tileView(for: agentTileId) else { return }
        let world = canvas.worldFrame(forTileFrame: agentView.tile.frame, tileId: agentTileId)
        let title = board.card(cardId)?.title ?? "Task"
        canvas.showDragGhost(at: world, label: "Assign task", detail: title)
    }

    /// The managed-agent tile under a point given in this tile's coordinates, or
    /// nil when the pointer is still inside the board.
    private func agentTile(under point: CGPoint) -> UUID? {
        guard bounds.contains(point) == false else { return nil }
        guard let canvas, let superview else { return nil }
        let inCanvas = convert(point, to: canvas)
        // The lifted card ignores hit-testing, so it cannot mask the target.
        _ = superview
        guard var hit = canvas.hitTest(inCanvas) else { return nil }
        while let parent = hit.superview {
            if let agent = hit as? ManagedAgentTileNSView { return agent.tile.id }
            hit = parent
        }
        return nil
    }

    // MARK: - Commit

    func finishCardDrag() {
        guard let session = dragSession else { return }

        // Dropped on an agent: this is an assignment, not a reorder.
        if let agentTileId = session.hoveredAgentTileId, session.didMove {
            let cardId = session.cardId
            endDragSession(commit: false)
            onAssignToAgent?(cardId, agentTileId)
            setFocusState(.selected(cardId))
            return
        }

        // A click that never moved is a selection — or, on an already-selected
        // card, the way into editing. This branch is why the drag session records
        // `wasSelected`: mouseDown always opens a session, so mouseUp is the only
        // place that can tell a click from a drag.
        guard session.didMove, let target = session.target else {
            let cardId = session.cardId
            let wasSelected = session.wasSelected
            endDragSession(commit: false)
            setFocusState(wasSelected ? .editing(cardId) : .selected(cardId))
            return
        }
        // EXACTLY the previewed anchors. Not "nearest slot at mouse-up" — a fast
        // release would then land somewhere the preview never showed.
        let command = target.moveCommand(for: session.cardId)
        let cardId = session.cardId
        endDragSession(commit: true)
        onCommand?(command)
        setFocusState(.selected(cardId))
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
        hideCardGhost()
        cardGhost?.removeFromSuperview()
        canvas?.hideDragGhost()
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

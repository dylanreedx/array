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
    let startPoint: CGPoint
    var freePoint: CGPoint
    var target: BoardDragTarget?
    var didMove = false
    var assignmentHints: [NSView] = []
    /// The agent tile the pointer is currently over, if the drag has left the
    /// board. Nil means this is still an ordinary reorder.
    var hoveredAgentTileId: UUID?

    init(
        cardId: UUID, sourceColumnId: UUID, liftedView: KanbanCardView,
        grabOffset: CGPoint, freePoint: CGPoint
    ) {
        self.cardId = cardId
        self.sourceColumnId = sourceColumnId
        self.liftedView = liftedView
        self.grabOffset = grabOffset
        self.startPoint = freePoint
        self.freePoint = freePoint
    }
}

extension KanbanTileNSView {
    /// Distance from the lane edge at which a drag starts scrolling it.
    static let autoscrollEdge: CGFloat = 32
    static let autoscrollStep: CGFloat = 14

    // MARK: - Begin

    func beginCardDrag(cardId: UUID, event: NSEvent) {
        guard dragSession == nil else { return }
        guard let card = board.card(cardId),
              let cardViewInColumn = cardView(for: cardId) else { return }

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
        lifted.loadThumbnail(card: card, store: taskAttachmentStore, boardID: board.id)
        // Host in canvas space so the board's clipping cannot cut off a handoff.
        let host: NSView = canvas ?? self
        host.addSubview(lifted, positioned: .above, relativeTo: nil)
        lifted.frame = convert(cardFrame, to: host)
        lifted.bounds = NSRect(origin: .zero, size: cardFrame.size)
        lifted.isHidden = true

        let session = BoardDragSession(
            cardId: cardId,
            sourceColumnId: card.columnId,
            liftedView: lifted,
            grabOffset: CGPoint(x: pointInTile.x - cardFrame.minX, y: pointInTile.y - cardFrame.minY),
            freePoint: pointInTile)
        dragSession = session

        takeKeyboardFocusIfIdle()
        boardRuntime?.beginPointerDrag(cardId: cardId)
        installDragCancelMonitor()

    }

    // MARK: - Track

    func continueCardDrag(event: NSEvent) {
        guard let session = dragSession else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !session.didMove {
            let distance = hypot(point.x - session.startPoint.x, point.y - session.startPoint.y)
            guard distance * canvasZoomForDrag >= 4 else { return }
            session.didMove = true
            if let canvas {
                for choice in taskAgents?() ?? [] {
                    guard let id = choice.tileID, let target = canvas.tileView(for: id) else { continue }
                    let hint = BoardAssignmentHint(frame: target.convert(target.bounds, to: canvas), name: choice.name)
                    canvas.addSubview(hint, positioned: .above, relativeTo: nil)
                    session.assignmentHints.append(hint)
                }
            }
            session.liftedView.isHidden = false
            columnView(for: session.sourceColumnId)?.setLifted(session.cardId)
        }
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
        guard let session = dragSession, session.didMove else { return }
        let carriedBounds = session.liftedView.bounds
        let frame = NSRect(x: freePoint.x - session.grabOffset.x,
                           y: freePoint.y - session.grabOffset.y,
                           width: carriedBounds.width, height: carriedBounds.height)
        session.liftedView.frame = convert(frame, to: session.liftedView.superview)
        session.liftedView.bounds = carriedBounds

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

        // Empty canvas is not a destination. Keep carrying the card, but do not
        // suggest or commit an unrelated move to the nearest board lane.
        guard bounds.contains(freePoint) else {
            session.target = nil
            for column in allColumnViews { column.setPreviewGap(index: nil, height: 0, animated: true) }
            hideCardGhost()
            return
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

        let gapHeight = session.liftedView.bounds.height
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
        canvas.showDragGhost(at: world, label: "Release to assign to " + (taskAgents?().first(where: { $0.tileID == agentTileId })?.name ?? "agent"), detail: title)
    }

    /// The managed-agent tile under a point given in this tile's coordinates, or
    /// nil when the pointer is still inside the board.
    private func agentTile(under point: CGPoint) -> UUID? {
        guard bounds.contains(point) == false else { return nil }
        guard let canvas, let host = canvas.superview else { return nil }
        // hitTest takes coordinates in the receiver's parent, not its bounds.
        guard var hit = canvas.hitTest(convert(point, to: host)) else { return nil }
        while let parent = hit.superview {
            if let agent = hit as? ManagedAgentTileNSView {
                guard taskAgents?().contains(where: { $0.tileID == agent.tile.id }) ?? true else { return nil }
                return agent.tile.id
            }
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

        // Releasing below the drag threshold only selects. Double-click and
        // Return are the explicit edit gestures.
        guard session.didMove, let target = session.target else {
            let cardId = session.cardId
            endDragSession(commit: false)
            setFocusState(.selected(cardId))
            if !session.didMove { openTask(cardId) }
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
        session.assignmentHints.forEach { $0.removeFromSuperview() }
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
        // AppKit may stop delivering to the source NSView once its lane hides
        // it. Own the rest of this gesture until release, independently of hits.
        dragCancelMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self, self.dragSession != nil else { return event }
            switch event.type {
            case .leftMouseDragged:
                self.continueCardDrag(event: event)
            case .leftMouseUp:
                self.finishCardDrag()
            case .keyDown where event.keyCode == 53:
                self.cancelCardDrag()
            default:
                return event
            }
            return nil
        }
        dragDeactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelCardDrag() }
        }
    }

    private func removeDragCancelMonitor() {
        if let monitor = dragCancelMonitor { NSEvent.removeMonitor(monitor) }
        dragCancelMonitor = nil
        if let observer = dragDeactivationObserver { NotificationCenter.default.removeObserver(observer) }
        dragDeactivationObserver = nil
    }
}

@MainActor
private final class BoardAssignmentHint: NSView {
    init(frame: NSRect, name: String) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = 2
        layer?.cornerRadius = 12
        layer?.borderColor = LineToken.borderStrong.color.cgColor(in: self)
        let label = NSTextField(labelWithString: "Drop to assign · " + name)
        label.frame = NSRect(x: 14, y: 12, width: max(0, frame.width - 28), height: 24)
        label.font = NSFont.token(.caption)
        label.textColor = TextToken.textPrimary.color.nsColor(in: self)
        label.drawsBackground = true
        label.backgroundColor = SurfaceToken.overlay.color.nsColor(in: self)
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

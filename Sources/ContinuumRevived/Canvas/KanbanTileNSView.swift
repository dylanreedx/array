import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// KB-01. The board tile. Plan: .plans/60-kanban-board.md
//
// A PURE RENDERER. It holds a `Board` snapshot to draw from and never mutates
// one: every change leaves through `onCommand`, is applied by `BoardRuntime`
// (the single authority, so two tiles on one board cannot disagree), and comes
// back as `render(_:)`. That is also what makes an agent-originated move and a
// pointer move indistinguishable by the time they reach the model.

@MainActor
final class KanbanTileNSView: TileNSView {
    /// Selection and editing are DISTINCT states, and the distinction decides
    /// which undo stack Cmd-Z reaches: while a card's text field is first
    /// responder, `CanvasNSView.undo(_:)` routes to the field's own manager.
    /// An ambiguous state machine produces an ambiguous Cmd-Z.
    enum FocusState: Equatable {
        case none
        case selected(UUID)
        case editing(UUID)

        var cardId: UUID? {
            switch self {
            case .none: return nil
            case .selected(let id), .editing(let id): return id
            }
        }
    }

    private(set) var board: Board
    private(set) var focusState: FocusState = .none

    /// The only way anything leaves this view.
    var onCommand: ((BoardCommand) -> Void)?

    private let body = FlippedContainerView()
    private let contentContainer = FlippedContainerView()
    private let gestureHint = NSTextField(labelWithString: "Drag a task onto an agent to assign it  ·  Click to open details")
    private let horizontalScroll = NSScrollView()
    fileprivate var columnViews: [KanbanColumnView] = []
    private let emptyBoardLabel = NSTextField(labelWithString: "")

    /// Extra top inset so no card can be laid out inside the tile's move grab
    /// strip. `TileNSView.hitTest` claims that strip before `super.hitTest`, and
    /// `chromeScaleBucket` ENLARGES it as zoom falls — so a fixed inset chosen at
    /// zoom 1 is not enough. Recomputed whenever the canvas rescales chrome.
    private var grabStripInset: CGFloat = 0

    /// The live pointer drag, if any. Nil outside a gesture — a fresh mouse-down
    /// is an unconditional boundary, so an interrupted AppKit sequence cannot
    /// leave the next drag inheriting a target.
    var dragSession: BoardDragSession?
    var dragCancelMonitor: Any?
    var dragDeactivationObserver: NSObjectProtocol?
    /// The insertion phantom, reparented into whichever lane currently holds the
    /// preview. One instance, so moving between lanes keeps its trailing
    /// animation continuous instead of restarting it.
    var cardGhost: BoardCardGhostView?
    /// Resolves an agent's display name for a card's assignee chip. Supplied by
    /// the app; the view must not reach into the supervisor itself.
    var agentDisplayName: ((AgentID) -> String?)?
    /// Fires when a task is dropped on a managed-agent tile. The app turns it
    /// into an assignment. Preparing and sending remain separate actions.
    var onAssignToAgent: ((UUID, UUID) -> Void)?
    var taskAgents: (() -> [BoardAgentChoice])?
    var onTaskAssign: ((UUID, AgentID?) -> String?)?
    var onTaskActionError: ((String) -> Void)?
    var onTaskPrepare: ((UUID) async -> String?)?
    var onTaskCreateAgent: (() -> Bool)?
    var taskAttachmentStore: BoardAttachmentStore?
    private var taskDetail: BoardTaskDetailController?
    func openTask(_ id: UUID, assign: Bool = false) {
        if case .editing(let editingID) = focusState { setFocusState(.selected(editingID)) }
        guard taskDetail?.finishBeforeOpeningAnother() ?? true else { return }
        guard let card = board.card(id) else { return }
        taskDetail = BoardTaskDetailController(tile: self, card: card)
        taskDetail?.present(openAssignee: assign)
    }
    /// The board authority, so a drag can take and release the lease that makes
    /// a concurrent API edit on the carried card reject rather than race.
    weak var boardRuntime: BoardRuntime?
    /// Which board this tile's Cmd-Z reaches.
    var boardIdForUndo: UUID?

    /// Injectable for checks; production reads the system setting.
    var prefersReducedMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Set around the command a local drop issues. The drop's own settle already
    /// placed the card where the model now puts it, so that render must not
    /// FLIP it again from the stale source-lane frame.
    var suppressesChangeAnimation = false
    /// Nothing animates until the board has been laid out once: the first
    /// render, hydration and a restore present their content instantly.
    private var hasLaidOutBoard = false
    /// Card views that left a lane on the last render, re-hosted in `body` (above
    /// every lane's clip) while they fly to their new lane or fade out. They
    /// ignore hits, end at model opacity 0, and live at most until the next
    /// render. Exposed for the witness.
    private(set) var departingCardViews: [KanbanCardView] = []

    /// The undo stack a focused board tile owns. Deliberately separate from the
    /// canvas geometry stack: one accepted card move is one BOARD undo, and a
    /// geometry mismatch elsewhere must not wipe it.
    var boardUndoManager: UndoManager? {
        guard let boardIdForUndo, let boardRuntime else { return nil }
        return boardRuntime.history(for: boardIdForUndo).undoManager
    }

    var allColumnViews: [KanbanColumnView] { columnViews }

    /// Canvas zoom, so the drag bands stay constant in SCREEN points. A drag at
    /// zoom 0.35 that used raw board points would catch at a third the distance.
    var canvasZoomForDrag: Double { canvas?.viewport.zoom ?? 1 }

    func assigneeName(for card: BoardCard) -> String? {
        card.assignee.flatMap { agentDisplayName?($0) } ?? (card.assignee == nil ? nil : "agent")
    }

    func moveTaskFromMenu(_ cardID: UUID, to columnID: UUID) {
        guard board.card(cardID) != nil, board.columns.contains(where: { $0.id == columnID }) else { return }
        onCommand?(.moveCard(
            id: cardID,
            toColumn: columnID,
            after: board.orderedCards(in: columnID).last(where: { $0.id != cardID })?.id,
            before: nil
        ))
    }

    func assignTaskFromMenu(_ cardID: UUID, to agentID: AgentID?) {
        if let error = onTaskAssign?(cardID, agentID) { onTaskActionError?(error) }
    }

    func deleteTaskFromMenu(_ cardID: UUID) {
        guard board.card(cardID) != nil else { return }
        onCommand?(.deleteCard(id: cardID))
    }

    init(tile: Tile, board: Board) {
        self.board = board
        super.init(tile: tile)

        horizontalScroll.hasHorizontalScroller = true
        horizontalScroll.hasVerticalScroller = false
        horizontalScroll.autohidesScrollers = true
        horizontalScroll.scrollerStyle = .overlay
        horizontalScroll.drawsBackground = false
        horizontalScroll.documentView = body

        emptyBoardLabel.font = NSFont.token(.body)
        emptyBoardLabel.alignment = .center
        emptyBoardLabel.stringValue = "This board has no columns yet."
        emptyBoardLabel.isHidden = true
        body.addSubview(emptyBoardLabel)

        gestureHint.font = NSFont.token(.caption)
        gestureHint.lineBreakMode = .byTruncatingTail
        contentContainer.addSubview(horizontalScroll)
        contentContainer.addSubview(gestureHint)
        setContentView(contentContainer)
        installAddAccessory()
        rebuildColumns()
        applyTokens()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A single add action in the tile's title bar. Previously every lane carried
    /// its own "+", which is N pieces of chrome for one verb and competed with
    /// the tasks for attention.
    private func installAddAccessory() {
        let button = NSButton()
        button.title = "+"
        button.bezelStyle = .inline
        button.isBordered = false
        button.font = NSFont.token(.label)
        button.target = self
        button.action = #selector(addTaskFromTitleBar)
        button.setAccessibilityLabel("Add a task")
        button.toolTip = "Add a task (⌘N)"
        button.frame = NSRect(x: 0, y: 0, width: 18, height: 16)
        setTitleBarAccessory(button)
    }

    @objc private func addTaskFromTitleBar() {
        guard let columnId = focusedColumnId ?? board.orderedColumns.first?.id else { return }
        createCard(in: columnId)
    }

    // MARK: - Rendering

    /// Adopts a new board snapshot. Reconciles by id so a re-render mid-drag —
    /// which is exactly what an agent-originated move produces — reuses the view
    /// under the pointer instead of destroying it.
    func render(_ board: Board) {
        let structureChanged = board.orderedColumns.map(\.id) != self.board.orderedColumns.map(\.id)
        // A change from outside a local drag animates (FLIP): capture where every
        // card is on screen now, apply, lay out once, animate from the delta.
        // Never on a structure change or a different board, never mid-drag.
        let animates = !structureChanged && board.id == self.board.id && changeAnimationAllowed
        purgeDepartingCardViews()
        let previous = self.board
        let before = animates ? presentedCardFrames() : [:]
        let addRowsBefore = animates
            ? Dictionary(uniqueKeysWithValues: columnViews.map { ($0.columnId, $0.addButtonOrigin) }) : [:]
        var departed: [KanbanCardView] = []
        self.board = board
        taskDetail?.refresh()
        if structureChanged {
            rebuildColumns()
        } else {
            for column in board.orderedColumns {
                guard let view = columnViews.first(where: { $0.columnId == column.id }) else { continue }
                view.name = column.name
                departed += view.setCards(board.orderedCards(in: column.id), assigneeName: { [weak self] id in
                    self?.agentDisplayName?(id)
                })
            }
        }
        for card in board.cards { cardView(for: card.id)?.loadThumbnail(card: card, store: taskAttachmentStore, boardID: board.id) }
        // A cross-lane move may replace the card view while retaining the
        // focused ID. Reapply selection to that new renderer.
        if let focused = focusState.cardId { cardView(for: focused)?.setSelected(true) }
        // A card the model no longer has cannot stay selected.
        if let focused = focusState.cardId, board.card(focused) == nil {
            setFocusState(.none)
        }
        if animates {
            animateBoardChange(previous: previous, before: before, addRowsBefore: addRowsBefore, departed: departed)
        }
        needsLayout = true
        // A drag in flight re-resolves against the board that just arrived. This
        // is the interruptibility seam: an agent-originated move lands, and the
        // displacement absorbs it on this very render rather than conflicting.
        if let session = dragSession {
            if board.card(session.cardId) == nil {
                cancelCardDrag()
            } else {
                layoutSubtreeIfNeeded()
                updateDragPreview(freePoint: session.freePoint)
            }
        }
    }

    private func rebuildColumns() {
        for view in columnViews { view.removeFromSuperview() }
        columnViews = board.orderedColumns.map { column in
            let view = KanbanColumnView(columnId: column.id, name: column.name)
            view.setCards(board.orderedCards(in: column.id), assigneeName: { [weak self] id in
                self?.agentDisplayName?(id)
            })
            view.onAddTask = { [weak self] in self?.createCard(in: column.id) }
            body.addSubview(view)
            return view
        }
        emptyBoardLabel.isHidden = !columnViews.isEmpty
        needsLayout = true
    }

    func columnView(for id: UUID) -> KanbanColumnView? {
        columnViews.first { $0.columnId == id }
    }

    func cardView(for id: UUID) -> KanbanCardView? {
        for column in columnViews {
            if let view = column.cardView(for: id) { return view }
        }
        return nil
    }

    // MARK: - Change animation

    private var changeAnimationAllowed: Bool {
        window != nil && hasLaidOutBoard && dragSession == nil && !suppressesChangeAnimation
            && !prefersReducedMotion()
    }

    /// Where each card is ON SCREEN, in tile coordinates — the model frame plus
    /// any in-flight slide, so a change landing mid-animation continues from
    /// where the card visibly is instead of jumping. Once per board change.
    private func presentedCardFrames() -> [UUID: NSRect] {
        var frames: [UUID: NSRect] = [:]
        for column in columnViews {
            for card in column.cardViews where !card.isHidden {
                guard let container = card.superview else { continue }
                var rect = card.frame
                if let layer = card.layer, let presented = layer.presentation() {
                    let model = container.convertFromLayer(layer.position)
                    let shown = container.convertFromLayer(presented.position)
                    rect.origin.x += shown.x - model.x
                    rect.origin.y += shown.y - model.y
                }
                frames[card.cardId] = convert(rect, from: container)
            }
        }
        return frames
    }

    /// One forced layout per board change (not per frame), then Core Animation
    /// owns the motion — the film harness steps CA time, so the capture sees
    /// exactly this. Nothing here depends on a completion firing: a departing
    /// card ends at model opacity 0 and is purged by the next render at latest.
    private func animateBoardChange(
        previous: Board, before: [UUID: NSRect], addRowsBefore: [UUID: NSPoint], departed: [KanbanCardView]
    ) {
        layoutSubtreeIfNeeded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let crossedLanes = Set(departed.map(\.cardId)).intersection(board.cards.map(\.id))
        for column in columnViews {
            for card in column.cardViews {
                guard let container = card.superview, let layer = card.layer else { continue }
                if let old = before[card.cardId] {
                    if crossedLanes.contains(card.cardId) {
                        // The lane's clip would cut a card sliding in from another
                        // lane, so its departing view flies above every lane and
                        // this one stays hidden until that flight lands.
                        layer.add(KanbanCardMotion.hold(opacity: 0), forKey: KanbanCardMotion.arriveKey)
                    } else {
                        KanbanCardMotion.slide(layer, in: container,
                                               from: container.convert(old, from: self).origin, to: card.frame.origin)
                    }
                } else if previous.card(card.cardId) == nil {
                    layer.add(KanbanCardMotion.enter(layer), forKey: KanbanCardMotion.enterKey)
                }
            }
            if let origin = addRowsBefore[column.columnId] { column.slideAddButton(from: origin) }
        }
        for proxy in departed {
            guard let old = before[proxy.cardId], let layer = proxy.layer else { continue }
            proxy.ignoresHitTesting = true
            // `old` is where it visibly was, so an in-flight slide is already
            // folded in; leaving it running would double the offset.
            layer.removeAllAnimations()
            let from = body.convert(old, from: self)
            body.addSubview(proxy)
            if let destination = cardView(for: proxy.cardId) {
                let to = body.convert(destination.bounds, from: destination)
                proxy.frame = NSRect(origin: to.origin, size: from.size)
                KanbanCardMotion.slide(layer, in: body, from: from.origin, to: to.origin)
                layer.add(KanbanCardMotion.hold(opacity: 1), forKey: KanbanCardMotion.carryKey)
            } else {
                proxy.frame = from
                layer.add(KanbanCardMotion.exit(layer), forKey: KanbanCardMotion.exitKey)
            }
            layer.opacity = 0
            departingCardViews.append(proxy)
        }
        CATransaction.commit()
    }

    private func purgeDepartingCardViews() {
        for proxy in departingCardViews {
            proxy.removeFromSuperview()
            cardView(for: proxy.cardId)?.layer?.removeAnimation(forKey: KanbanCardMotion.arriveKey)
        }
        departingCardViews.removeAll()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        if !bounds.isEmpty { hasLaidOutBoard = true }
        // Recompute the grab-strip inset every layout: it is zoom-dependent, and
        // the canvas rescales chrome without re-creating the tile.
        grabStripInset = max(0, grabHeightInLocalCoordinates - contentTopInsetWorldHeight)
        horizontalScroll.frame = NSRect(x: 0, y: 0, width: contentContainer.bounds.width,
                                        height: max(0, contentContainer.bounds.height - 30))
        gestureHint.frame = NSRect(x: 20, y: max(0, contentContainer.bounds.height - 24),
                                  width: max(0, contentContainer.bounds.width - 40), height: 16)
        let columnWidth = max(224, (horizontalScroll.contentSize.width - CGFloat(columnViews.count + 1) * 10)
                                  / CGFloat(max(1, columnViews.count)))
        let spacing: CGFloat = 10
        let visible = horizontalScroll.contentSize
        let contentHeight = max(0, visible.height - grabStripInset)
        var x = spacing
        for view in columnViews {
            view.frame = NSRect(x: x, y: grabStripInset, width: columnWidth, height: contentHeight)
            x += columnWidth + spacing
        }
        emptyBoardLabel.frame = NSRect(
            x: 0, y: grabStripInset + 20, width: max(0, visible.width), height: 20)
        body.frame = NSRect(
            x: 0, y: 0,
            width: max(visible.width, x),
            height: max(visible.height, contentHeight + grabStripInset))
    }

    /// Declared so the residency surface bakes at the right scroll position.
    /// An empty list means "nothing here scrolls", which for a board is a lie
    /// that shows the wrong cards after a demote/promote round trip.
    override var surfaceScrollOffsets: [CGPoint] {
        [horizontalScroll.contentView.bounds.origin] + columnViews.map(\.scrollOffset)
    }

    /// Bumped by the board's own revision, so a model change invalidates the
    /// baked picture.
    override var surfaceContentRevision: UInt64? { board.revision }

    // MARK: - Focus state machine

    func setFocusState(_ next: FocusState) {
        guard focusState != next else { return }
        if case .editing(let id) = focusState, next.cardId != id || !isEditing(next) {
            cardView(for: id)?.endEditing(commit: true)
        }
        if let previous = focusState.cardId, previous != next.cardId {
            cardView(for: previous)?.setSelected(false)
        }
        focusState = next
        switch next {
        case .none:
            break
        case .selected(let id):
            cardView(for: id)?.setSelected(true)
        case .editing(let id):
            let view = cardView(for: id)
            view?.setSelected(true)
            view?.onCommit = { [weak self] title in
                self?.onCommand?(.editCard(id: id, title: title, body: nil))
            }
            view?.beginEditing()
        }
        announceFocusForAccessibility()
    }

    private func isEditing(_ state: FocusState) -> Bool {
        if case .editing = state { return true }
        return false
    }

    // MARK: - Commands the view originates

    /// Takes the keyboard for the board unless a card is being edited, whose text
    /// field must keep first responder — that is also what decides whether Cmd-Z
    /// reaches the board stack or the field's own.
    func takeKeyboardFocusIfIdle() {
        if case .editing = focusState { return }
        guard window?.firstResponder !== self else { return }
        window?.makeFirstResponder(self)
    }

    func createCard(in columnId: UUID) {
        let id = UUID()
        let last = board.orderedCards(in: columnId).last?.id
        onCommand?(.createCard(id: id, columnId: columnId, title: "", after: last, before: nil))
        // The runtime will render the new board; select and open the new card so
        // "+" lands the user in a typing state rather than staring at a blank row.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.board.card(id) != nil else { return }
            self.setFocusState(.editing(id))
        }
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Every move below is the SAME `BoardCommand` a drag produces. The
        // keyboard is not a second, simpler path into the model.
        let option = event.modifierFlags.contains(.option)
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 36:  // Return
            switch focusState {
            case .selected(let id): openTask(id)
            case .editing(let id): setFocusState(.selected(id))
            case .none: break
            }
        case 53:  // Escape
            switch focusState {
            case .editing(let id): setFocusState(.selected(id))
            case .selected: setFocusState(.none)
            case .none: break
            }
        case 51, 117:  // Delete / forward delete
            // Deletes ONLY from selection. In editing, the key belongs to the
            // text field, which is where an ambiguous state machine deletes the
            // user's card instead of a character.
            if case .selected(let id) = focusState {
                onCommand?(.deleteCard(id: id))
                setFocusState(.none)
            } else {
                super.keyDown(with: event)
            }
        case 123 where option:  // Option + Left
            moveFocusedCard(columnDelta: -1)
        case 124 where option:  // Option + Right
            moveFocusedCard(columnDelta: +1)
        case 126 where option:  // Option + Up
            moveFocusedCard(orderDelta: -1)
        case 125 where option:  // Option + Down
            moveFocusedCard(orderDelta: +1)
        case 123: moveSelection(columnDelta: -1)
        case 124: moveSelection(columnDelta: +1)
        case 126: moveSelection(orderDelta: -1)
        case 125: moveSelection(orderDelta: +1)
        case 45 where command:  // Command + N
            if let columnId = focusedColumnId ?? board.orderedColumns.first?.id {
                createCard(in: columnId)
            }
        default:
            super.keyDown(with: event)
        }
    }

    private var focusedColumnId: UUID? {
        focusState.cardId.flatMap { board.card($0)?.columnId }
    }

    private func moveSelection(columnDelta: Int = 0, orderDelta: Int = 0) {
        guard case .editing = focusState else {
            let columns = board.orderedColumns.map(\.id)
            guard !columns.isEmpty else { return }
            guard let current = focusState.cardId, let card = board.card(current) else {
                if let first = board.orderedCards(in: columns[0]).first { setFocusState(.selected(first.id)) }
                return
            }
            if columnDelta != 0 {
                guard let index = columns.firstIndex(of: card.columnId) else { return }
                let target = columns[min(max(0, index + columnDelta), columns.count - 1)]
                let siblings = board.orderedCards(in: target)
                guard !siblings.isEmpty else { return }
                let row = board.orderedCards(in: card.columnId).firstIndex { $0.id == current } ?? 0
                setFocusState(.selected(siblings[min(row, siblings.count - 1)].id))
            } else if orderDelta != 0 {
                let siblings = board.orderedCards(in: card.columnId)
                guard let index = siblings.firstIndex(where: { $0.id == current }) else { return }
                let target = index + orderDelta
                guard target >= 0, target < siblings.count else { return }
                setFocusState(.selected(siblings[target].id))
            }
            return
        }
    }

    private func moveFocusedCard(columnDelta: Int = 0, orderDelta: Int = 0) {
        guard case .selected(let id) = focusState, let card = board.card(id) else { return }
        let columns = board.orderedColumns.map(\.id)
        if columnDelta != 0 {
            guard let index = columns.firstIndex(of: card.columnId) else { return }
            let targetIndex = index + columnDelta
            guard targetIndex >= 0, targetIndex < columns.count else { return }
            let target = columns[targetIndex]
            onCommand?(.moveCard(
                id: id, toColumn: target,
                after: board.orderedCards(in: target).last?.id, before: nil))
        } else if orderDelta != 0 {
            let siblings = board.orderedCards(in: card.columnId).filter { $0.id != id }
            let current = board.orderedCards(in: card.columnId).firstIndex { $0.id == id } ?? 0
            let target = current + orderDelta
            guard target >= 0, target <= siblings.count else { return }
            onCommand?(.moveCard(
                id: id, toColumn: card.columnId,
                after: target > 0 ? siblings[target - 1].id : nil,
                before: target < siblings.count ? siblings[target].id : nil))
        }
    }

    // MARK: - Accessibility

    private func announceFocusForAccessibility() {
        guard let id = focusState.cardId, let card = board.card(id),
              let column = board.column(card.columnId) else { return }
        let siblings = board.orderedCards(in: card.columnId)
        let index = (siblings.firstIndex { $0.id == id } ?? 0) + 1
        NSAccessibility.post(
            element: self, notification: .announcementRequested,
            userInfo: [
                .announcement: "\(card.title.isEmpty ? "Untitled" : card.title), \(column.name), \(index) of \(siblings.count)",
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ])
    }

    // MARK: - Tokens

    override func applyTokens() {
        super.applyTokens()
        contentBackgroundLayer?.backgroundColor = SurfaceToken.tileBody.color.cgColor(in: self)
        emptyBoardLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        gestureHint.textColor = TextToken.textSecondary.color.nsColor(in: self)
        for view in columnViews { view.applyTokens() }
    }

    private var contentBackgroundLayer: CALayer? { body.layer }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }
}

/// The board's change animations, all explicit Core Animation on the card
/// layers. Keys are stable: the witness (`--board-interaction-check`) reads them.
@MainActor
enum KanbanCardMotion {
    static let enterKey = "kanban.card.enter"
    static let moveKey = "kanban.card.move"
    static let exitKey = "kanban.card.exit"
    static let arriveKey = "kanban.card.arrive"
    static let carryKey = "kanban.card.carry"

    static let enterDuration: CFTimeInterval = 0.28
    static let moveDuration: CFTimeInterval = 0.3
    static let exitDuration: CFTimeInterval = 0.18
    /// A gentle overshoot, about half a percent of scale at 0.9 → 1.
    static let enterTiming = CAMediaTimingFunction(controlPoints: 0.3, 1.25, 0.55, 1)
    /// Ease-out quint: fast away, long settle.
    static let moveTiming = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)

    /// Additive position slide from `from` to `to` (both in `container`'s view
    /// coordinates). The model is already at `to`; the animation carries the
    /// difference down to zero, so overlapping slides compose.
    static func slide(_ layer: CALayer, in container: NSView, from: NSPoint, to: NSPoint) {
        let a = container.convertToLayer(from), b = container.convertToLayer(to)
        let delta = CGPoint(x: a.x - b.x, y: a.y - b.y)
        guard abs(delta.x) > 0.5 || abs(delta.y) > 0.5 else { return }
        let slide = CABasicAnimation(keyPath: "position")
        slide.isAdditive = true
        slide.fromValue = NSValue(point: delta)
        slide.toValue = NSValue(point: .zero)
        slide.duration = moveDuration
        slide.timingFunction = moveTiming
        layer.add(slide, forKey: moveKey)
    }

    static func enter(_ layer: CALayer) -> CAAnimation {
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = NSValue(caTransform3D: scaledAboutCentre(layer, 0.9))
        scale.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        scale.duration = enterDuration
        scale.timingFunction = enterTiming
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = enterDuration
        return group
    }

    /// Fades and shrinks a removed card in place. The caller sets the model
    /// opacity to 0, so the end state holds without a fill mode.
    static func exit(_ layer: CALayer) -> CAAnimation {
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        scale.toValue = NSValue(caTransform3D: scaledAboutCentre(layer, 0.94))
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = exitDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        return group
    }

    /// Holds opacity for one slide's length, then lets the model value show.
    /// Swaps the flying copy for the landed card on CA time, not a timer.
    static func hold(opacity: Float) -> CAAnimation {
        let hold = CABasicAnimation(keyPath: "opacity")
        hold.fromValue = opacity
        hold.toValue = opacity
        hold.duration = moveDuration
        return hold
    }

    /// A view's layer anchors at its origin, so a bare scale would grow from a
    /// corner. Scale about the centre instead.
    private static func scaledAboutCentre(_ layer: CALayer, _ factor: CGFloat) -> CATransform3D {
        let dx = layer.bounds.width * (0.5 - layer.anchorPoint.x)
        let dy = layer.bounds.height * (0.5 - layer.anchorPoint.y)
        var transform = CATransform3DMakeTranslation(dx, dy, 0)
        transform = CATransform3DScale(transform, factor, factor, 1)
        return CATransform3DTranslate(transform, -dx, -dy, 0)
    }
}

import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// KB-01. One lane: a header and its tasks in a vertical scroller.
// Plan: .plans/60-kanban-board.md
//
// Manual frame layout throughout, deliberately. A host placed by frame that
// constrains its own subviews lets the engine solve it to 0x0 with the origin
// kept — `AgentBlockHostView` learned that the expensive way — and a tile's
// content view is placed by frame.
//
// Adding stays in the lane where the task belongs; the keyboard and title-bar
// action still use the focused lane.

@MainActor
final class KanbanColumnView: NSView, TokenThemed {
    let columnId: UUID

    private let headerLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let cardsContainer = FlippedContainerView()
    private let emptyLabel = NSTextField(labelWithString: "No tasks")

    private(set) var cardViews: [KanbanCardView] = []
    /// Cached per-card heights. Measured when content changes or once after a
    /// width change, then reused across drag and ordinary layout passes.
    private var cardHeights: [UUID: CGFloat] = [:]
    private var measuredWidth: CGFloat = 0
    private var measurementCards: [UUID: (BoardCard, String?)] = [:]
    var onAddTask: (() -> Void)?
    private let addButton = NSButton(title: "+ Add task", target: nil, action: nil)

    private(set) var liftedCardId: UUID?
    private var previewGapIndex: Int?
    private var previewGapHeight: CGFloat = 0
    /// Where the insertion preview sits, in this lane's card-container space.
    /// Nil when this lane holds no preview.
    private(set) var previewGapFrame: NSRect?
    private var animatesNextLayout = false

    static let headerHeight: CGFloat = 38
    static let cardSpacing: CGFloat = 10
    static let contentInset: CGFloat = 10
    static let width: CGFloat = 248

    init(columnId: UUID, name: String) {
        self.columnId = columnId
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10

        headerLabel.stringValue = name
        headerLabel.font = NSFont.token(.label)
        headerLabel.lineBreakMode = .byTruncatingTail
        addSubview(headerLabel)

        countLabel.font = NSFont.token(.captionMono)
        countLabel.alignment = .right
        addSubview(countLabel)

        emptyLabel.font = NSFont.token(.caption)
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = cardsContainer
        addSubview(scrollView)
        addButton.isBordered = false
        addButton.alignment = .left
        addButton.font = NSFont.token(.body)
        addButton.target = self
        addButton.action = #selector(addTask)
        addButton.setAccessibilityLabel("Add task to " + name)
        cardsContainer.addSubview(addButton)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        applyTokens()
    }

    @objc private func addTask() { onAddTask?() }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var name: String {
        get { headerLabel.stringValue }
        set { headerLabel.stringValue = newValue }
    }

    /// The scroll owner this lane contributes to the tile's surface revision.
    /// A tile that scrolls and does not declare its scroll offsets bakes a
    /// residency surface at a stale position (`TileNSView.surfaceScrollOffsets`).
    var scrollOffset: CGPoint { scrollView.contentView.bounds.origin }

    /// The view the ghost is hosted in, so the preview scrolls with the cards.
    var ghostHost: NSView { cardsContainer }

    // MARK: - Content

    /// Reconciles the rendered cards against `cards`, reusing existing views by
    /// id so a re-render during a drag does not destroy the view under the
    /// pointer.
    func setCards(_ cards: [BoardCard], assigneeName: @escaping (AgentID) -> String?) {
        measurementCards.removeAll(keepingCapacity: true)
        var existing = Dictionary(uniqueKeysWithValues: cardViews.map { ($0.cardId, $0) })
        var next: [KanbanCardView] = []
        for card in cards {
            let name = card.assignee.flatMap(assigneeName)
            measurementCards[card.id] = (card, name)
            if let view = existing.removeValue(forKey: card.id) {
                view.update(card: card, assigneeName: name)
                next.append(view)
            } else {
                let view = KanbanCardView(card: card, assigneeName: name)
                cardsContainer.addSubview(view)
                next.append(view)
            }
            cardHeights[card.id] = KanbanCardView.height(
                for: card, assigneeName: name, width: measuredCardWidth)
        }
        for orphan in existing.values {
            orphan.removeFromSuperview()
            cardHeights.removeValue(forKey: orphan.cardId)
        }
        cardViews = next
        countLabel.stringValue = "\(cards.count)"
        emptyLabel.isHidden = true
        needsLayout = true
    }

    func cardView(for id: UUID) -> KanbanCardView? {
        cardViews.first { $0.cardId == id }
    }

    private var measuredCardWidth: CGFloat {
        max(0, measuredWidth > 0 ? measuredWidth : Self.width - Self.contentInset * 2)
    }

    // MARK: - Geometry the drag resolver needs

    /// Card centres/tops/bottoms in TILE coordinates, in rendered order,
    /// excluding the card the pointer is carrying — a card must not be asked to
    /// sit beside itself.
    func slotGeometry(excluding: UUID?, in reference: NSView) -> (
        ids: [UUID], centers: [Double], tops: [Double], bottoms: [Double], emptyCenterY: Double
    ) {
        var ids: [UUID] = []
        var centers: [Double] = []
        var tops: [Double] = []
        var bottoms: [Double] = []
        for view in cardViews where view.cardId != excluding && view.cardId != liftedCardId {
            let frame = view.convert(view.bounds, to: reference)
            ids.append(view.cardId)
            centers.append(Double(frame.midY))
            tops.append(Double(frame.minY))
            bottoms.append(Double(frame.maxY))
        }
        let body = scrollView.convert(scrollView.bounds, to: reference)
        return (ids, centers, tops, bottoms, Double(body.minY + Self.contentInset))
    }

    func columnBounds(in reference: NSView) -> (minX: Double, maxX: Double) {
        let frame = convert(bounds, to: reference)
        return (Double(frame.minX), Double(frame.maxX))
    }

    @discardableResult
    func autoscroll(towards point: CGPoint, in reference: NSView, edge: CGFloat, step: CGFloat) -> CGFloat {
        let body = scrollView.convert(scrollView.bounds, to: reference)
        guard body.height > 0 else { return 0 }
        let documentHeight = cardsContainer.frame.height
        let visible = scrollView.contentView.bounds
        var delta: CGFloat = 0
        if point.y < body.minY + edge {
            delta = -min(step, visible.origin.y)
        } else if point.y > body.maxY - edge {
            delta = min(step, max(0, documentHeight - visible.height - visible.origin.y))
        }
        guard delta != 0 else { return 0 }
        scrollView.contentView.scroll(to: NSPoint(x: visible.origin.x, y: visible.origin.y + delta))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return delta
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let inset = Self.contentInset
        let width = bounds.width
        headerLabel.frame = NSRect(x: inset + 3, y: 7, width: max(0, width - inset * 2 - 34), height: 15)
        countLabel.frame = NSRect(x: width - inset - 30, y: 7, width: 30, height: 15)

        let bodyHeight = max(0, bounds.height - Self.headerHeight)
        scrollView.frame = NSRect(x: 0, y: Self.headerHeight, width: width, height: bodyHeight)
        emptyLabel.frame = NSRect(
            x: inset, y: Self.headerHeight + inset + 6,
            width: max(0, width - inset * 2), height: 16)

        layoutCards(width: width)
    }

    private func layoutCards(width: CGFloat) {
        let cardWidth = max(0, width - Self.contentInset * 2)
        if cardWidth != measuredWidth {
            measuredWidth = cardWidth
            // Width changed, so every cached height is stale. Cleared here and
            // recomputed lazily below — never measured per layout pass.
            cardHeights.removeAll(keepingCapacity: true)
        }
        let animates = animatesNextLayout
        animatesNextLayout = false

        var y: CGFloat = Self.contentInset
        var flowIndex = 0
        var targets: [(KanbanCardView, NSRect)] = []
        var gapFrame: NSRect?
        for view in cardViews {
            // The carried card leaves the flow completely; the gap stands in for
            // it. Keeping both would double its space and grow the lane under the
            // pointer.
            if view.cardId == liftedCardId {
                view.isHidden = true
                continue
            }
            view.isHidden = false
            if previewGapIndex == flowIndex {
                gapFrame = NSRect(x: Self.contentInset, y: y, width: cardWidth, height: previewGapHeight)
                y += previewGapHeight + Self.cardSpacing
            }
            if cardHeights[view.cardId] == nil, let (card, name) = measurementCards[view.cardId] {
                cardHeights[view.cardId] = KanbanCardView.height(for: card, assigneeName: name, width: cardWidth)
            }
            let height = cardHeights[view.cardId] ?? KanbanCardView.minimumHeight
            targets.append((view, NSRect(x: Self.contentInset, y: y, width: cardWidth, height: height)))
            y += height + Self.cardSpacing
            flowIndex += 1
        }
        if previewGapIndex == flowIndex {
            gapFrame = NSRect(x: Self.contentInset, y: y, width: cardWidth, height: previewGapHeight)
            y += previewGapHeight + Self.cardSpacing
        }
        previewGapFrame = gapFrame

        if animates, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = BoardDragConfig.displacementDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                for (view, frame) in targets {
                    // ORIGIN only. A displaced neighbour must never resize —
                    // preserving card dimensions during displacement is the
                    // requirement, and `animateSnapLanding` sets the precedent.
                    view.setFrameSize(frame.size)
                    view.animator().setFrameOrigin(frame.origin)
                }
            }
        } else {
            for (view, frame) in targets { view.frame = frame }
        }

        addButton.frame = NSRect(x: Self.contentInset + 2, y: y + 2, width: cardWidth - 4, height: 30)
        let documentHeight = max(scrollView.contentSize.height, y + 36 + Self.contentInset)
        cardsContainer.frame = NSRect(x: 0, y: 0, width: width, height: documentHeight)
    }

    /// Height of one card as laid out — the drag opens a gap of exactly this, so
    /// releasing changes nothing visually and the settle has nothing to correct.
    func height(forCard id: UUID) -> CGFloat? { cardHeights[id] }

    func setLifted(_ cardId: UUID?) {
        guard liftedCardId != cardId else { return }
        liftedCardId = cardId
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Opens (or closes) the insertion gap. `index` counts the cards remaining in
    /// the flow, which already excludes the lifted one — the same space the drag
    /// resolver's slot indices live in.
    func setPreviewGap(index: Int?, height: CGFloat, animated: Bool) {
        guard previewGapIndex != index || previewGapHeight != height else { return }
        previewGapIndex = index
        previewGapHeight = height
        animatesNextLayout = animated
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func clearDragState() {
        liftedCardId = nil
        previewGapIndex = nil
        previewGapHeight = 0
        previewGapFrame = nil
        animatesNextLayout = false
        for view in cardViews { view.isHidden = false }
        needsLayout = true
    }

    // MARK: - Tokens

    func applyTokens() {
        // The lane is the RECESSED surface; its cards are raised above it.
        layer?.backgroundColor = SurfaceToken.tileBody.color.cgColor(in: self)
        addButton.contentTintColor = TextToken.textSecondary.color.nsColor(in: self)
        headerLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        countLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        emptyLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        for view in cardViews { view.applyTokens() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    override func accessibilityLabel() -> String? {
        "\(headerLabel.stringValue), \(cardViews.count) tasks"
    }
}

/// A flipped plain container. `NSScrollView`'s document view must be flipped for
/// top-down card layout to read naturally.
@MainActor
final class FlippedContainerView: NSView {
    override var isFlipped: Bool { true }
}

import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// KB-01. One column: a header, its cards in a vertical scroller, an add button.
// Plan: .plans/60-kanban-board.md
//
// Manual frame layout throughout, deliberately. A host placed by frame that
// constrains its own subviews lets the engine solve it to 0x0 with the origin
// kept — `AgentBlockHostView` learned that the expensive way — and a tile's
// content view is placed by frame.

@MainActor
final class KanbanColumnView: NSView, TokenThemed {
    let columnId: UUID

    var onAddCard: (() -> Void)?

    private let headerLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let addButton = NSButton()
    private let scrollView = NSScrollView()
    private let cardsContainer = FlippedContainerView()
    private let emptyLabel = NSTextField(labelWithString: "Drop a card here")

    private(set) var cardViews: [KanbanCardView] = []
    /// Cached per-card heights. Recomputed when a title or the width changes,
    /// never during `layout()`.
    private var cardHeights: [UUID: CGFloat] = [:]
    private var measuredWidth: CGFloat = 0

    static let headerHeight: CGFloat = 30
    static let footerHeight: CGFloat = 28
    static let cardSpacing: CGFloat = 8
    static let contentInset: CGFloat = 8
    static let width: CGFloat = 240

    init(columnId: UUID, name: String) {
        self.columnId = columnId
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8

        headerLabel.stringValue = name
        headerLabel.font = NSFont.token(.label)
        headerLabel.lineBreakMode = .byTruncatingTail
        addSubview(headerLabel)

        countLabel.font = NSFont.token(.captionMono)
        countLabel.alignment = .right
        addSubview(countLabel)

        addButton.title = "+"
        addButton.bezelStyle = .inline
        addButton.isBordered = false
        addButton.font = NSFont.token(.label)
        addButton.target = self
        addButton.action = #selector(addCardClicked)
        addButton.setAccessibilityLabel("Add a card to \(name)")
        addSubview(addButton)

        emptyLabel.font = NSFont.token(.caption)
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = cardsContainer
        addSubview(scrollView)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        applyTokens()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var name: String {
        get { headerLabel.stringValue }
        set { headerLabel.stringValue = newValue }
    }

    /// The scroll owner this column contributes to the tile's surface revision.
    /// A tile that scrolls and does not declare its scroll offsets bakes a
    /// residency surface at a stale position (`TileNSView.surfaceScrollOffsets`).
    var scrollOffset: CGPoint { scrollView.contentView.bounds.origin }

    // MARK: - Content

    /// Reconciles the rendered cards against `cards`, reusing existing views by
    /// id so a re-render during a drag does not destroy the view under the
    /// pointer.
    func setCards(_ cards: [BoardCard]) {
        var existing = Dictionary(uniqueKeysWithValues: cardViews.map { ($0.cardId, $0) })
        var next: [KanbanCardView] = []
        for card in cards {
            if let view = existing.removeValue(forKey: card.id) {
                view.title = card.title
                next.append(view)
            } else {
                let view = KanbanCardView(cardId: card.id, title: card.title)
                cardsContainer.addSubview(view)
                next.append(view)
            }
        }
        for orphan in existing.values { orphan.removeFromSuperview() }
        cardViews = next
        cardHeights.removeAll(keepingCapacity: true)
        measuredWidth = 0
        countLabel.stringValue = "\(cards.count)"
        emptyLabel.isHidden = !cards.isEmpty
        needsLayout = true
    }

    func cardView(for id: UUID) -> KanbanCardView? {
        cardViews.first { $0.cardId == id }
    }

    // MARK: - Geometry the drag resolver needs

    /// Card centres/tops/bottoms in TILE coordinates, in rendered order,
    /// excluding `excluding` (the card the pointer is carrying — a card must not
    /// be asked to sit beside itself).
    func slotGeometry(excluding: UUID?, in reference: NSView) -> (
        ids: [UUID], centers: [Double], tops: [Double], bottoms: [Double], emptyCenterY: Double
    ) {
        var ids: [UUID] = []
        var centers: [Double] = []
        var tops: [Double] = []
        var bottoms: [Double] = []
        for view in cardViews where view.cardId != excluding {
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

    /// Scrolls so `point` (tile coordinates) is comfortably inside the body.
    /// Returns the applied delta so the caller can keep the drag's free point in
    /// the same space as the freshly scrolled slots.
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
        headerLabel.frame = NSRect(x: inset, y: 6, width: max(0, width - inset * 2 - 34), height: 18)
        countLabel.frame = NSRect(x: width - inset - 30, y: 6, width: 30, height: 18)

        let bodyHeight = max(0, bounds.height - Self.headerHeight - Self.footerHeight)
        scrollView.frame = NSRect(x: 0, y: Self.headerHeight, width: width, height: bodyHeight)
        addButton.frame = NSRect(
            x: inset, y: Self.headerHeight + bodyHeight + 4,
            width: max(0, width - inset * 2), height: 20)
        emptyLabel.frame = NSRect(
            x: inset, y: Self.headerHeight + inset,
            width: max(0, width - inset * 2), height: 18)

        layoutCards(width: width)
    }

    private func layoutCards(width: CGFloat) {
        let cardWidth = max(0, width - Self.contentInset * 2)
        // Measure only when the width actually changed. Measuring every layout
        // pass is the documented way to freeze this app.
        if cardWidth != measuredWidth {
            measuredWidth = cardWidth
            cardHeights.removeAll(keepingCapacity: true)
        }
        var y: CGFloat = Self.contentInset
        for view in cardViews {
            let height: CGFloat
            if let cached = cardHeights[view.cardId] {
                height = cached
            } else {
                height = KanbanCardView.height(for: view.title, width: cardWidth)
                cardHeights[view.cardId] = height
            }
            view.frame = NSRect(x: Self.contentInset, y: y, width: cardWidth, height: height)
            y += height + Self.cardSpacing
        }
        let documentHeight = max(scrollView.contentSize.height, y + Self.contentInset)
        cardsContainer.frame = NSRect(x: 0, y: 0, width: width, height: documentHeight)
    }

    /// Height each card occupies, in rendered order — the drag controller uses it
    /// to open a gap the exact size of the card being carried.
    func height(forCard id: UUID) -> CGFloat? { cardHeights[id] }

    @objc private func addCardClicked() { onAddCard?() }

    // MARK: - Tokens

    func applyTokens() {
        layer?.backgroundColor = SurfaceToken.tileChrome.color.cgColor(in: self)
        headerLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        countLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        emptyLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        addButton.contentTintColor = TextToken.textSecondary.color.nsColor(in: self)
        for view in cardViews { view.applyTokens() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    override func accessibilityLabel() -> String? {
        "\(headerLabel.stringValue), \(cardViews.count) cards"
    }
}

/// A flipped plain container. `NSScrollView`'s document view must be flipped for
/// top-down card layout to read naturally.
@MainActor
final class FlippedContainerView: NSView {
    override var isFlipped: Bool { true }
}

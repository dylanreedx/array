import AppKit
import ContinuumRevivedAgentUI

// Ticket: .plans/0721-subagents-handoff.md
/// The tree connector for one inbox row: the lanes of the groups it is inside, the
/// elbow into its own card, and the descender to its children.
///
/// PAINTED, NOT SUB-VIEWED, and drawn with `NSBezierPath` rather than layer colours
/// — the same two decisions `Decorations` makes next door, for the same two reasons.
/// One view per row instead of one per segment keeps the recycling cost flat
/// (`docs/internals/performance.md`), and a bezier fill keeps this view out of the
/// `TokenThemed` census it would otherwise have to buy its way into (hazard 8);
/// `AgentInbox96CellView` itself is absent from `tokenAdoptedOwners` for exactly
/// this reason.
///
/// The colour is `AgentLineRole.decorativeHairline` — the sanctioned exempt line.
/// The connector contains and separates content that is already delineated; it
/// carries NO state. Nothing here may ever take an accent: a red lane would be a
/// fourth colour meaning in a list P3.2 holds to three, and it would make the
/// hierarchy a status display.
///
/// It sits ABOVE the card and never below it. A parent's descender runs through its
/// own card's leading inset, and the card paints a fill while hovered, selected or
/// route-active — a connector drawn underneath would be erased by exactly the row
/// you are pointing at.
@MainActor
final class InboxSpineView: NSView {
    private var segments: [InboxSpineSegment] = []

    override var isFlipped: Bool { true }
    /// Decoration only — every click belongs to the row beneath it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// What this row draws of the tree. Frames are in this view's own coordinates,
    /// which the cell keeps equal to the row's.
    func show(
        _ nesting: InboxNesting, metrics: InboxSpineMetrics,
        cardTop: Double, cardHeight: Double, rowHeight: Double
    ) {
        let next = InboxSpine.segments(
            nesting, metrics: metrics, cardTop: cardTop,
            cardHeight: cardHeight, rowHeight: rowHeight)
        guard next != segments else { return }
        segments = next
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !segments.isEmpty else { return }
        AgentLineRole.decorativeHairline.color.nsColor(in: self).setFill()
        for segment in segments {
            NSBezierPath(rect: NSRect(
                x: segment.minX, y: segment.minY,
                width: segment.width, height: segment.height)).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The connector AS DRAWN, for the witness. Read off what `draw` will paint, not
    /// recomputed from the row's depth — a check that re-derives the geometry the
    /// production code derives proves nothing about the production code.
    var qaSegmentsForQA: [InboxSpineSegment] { segments }
}

/// The quiet shared wash behind one parent and its visible descendants. Each
/// table cell paints only its own strip; matching edges bleed across the table's
/// intercell spacing, so the strips read as one grouped surface without a second
/// outline or a per-child card.
@MainActor
final class InboxGroupBackgroundView: NSView {
    private var isGroupMember = false
    private var roundsTop = false
    private var roundsBottom = false
    private var horizontalInset: CGFloat = 0
    /// The row's card, in this view's coordinates, when the cell hands it in.
    /// A group's first row starts its wash at the card's top, and a folded
    /// parent's wash IS its card: at rest the wash is the sheet you see, and
    /// hover paints the card's own plate, so any difference between the two is
    /// a band that appears and vanishes under the pointer.
    private var cardRect: NSRect?
    /// Launch polish, item Q: how many cards a FOLDED parent shows tucked behind
    /// its own — 1 for one hidden child, 2 for two or more, 0 when open.
    private(set) var tuckedCards = 0
    /// Clear space below the card before the next row's card, less a point of
    /// margin: the most a fanned card's lowest corner may travel.
    private var deckRoom: CGFloat = .greatestFiniteMagnitude
    /// How much of the specified fan the last pose used, 1 when it fits whole.
    private(set) var deckScale: CGFloat = 1

    /// How far each tucked card shows below the one in front of it, and how much
    /// narrower it is on each side.
    static let tuckedPeek: CGFloat = 3
    static let tuckedInset: CGFloat = 6
    /// The wash a tucked card is painted in, in front-to-back order: each one
    /// lower in contrast than the sheet in front, so the stack recedes.
    static let washAlpha: CGFloat = 0.035
    static let tuckedAlphas: [CGFloat] = [0.08, 0.055]

    /// The wash and the tucked cards are SUBLAYERS, painted with the same
    /// bezier strip `draw` used, so the deck can move on hover without a
    /// redraw and still paints no layer colour (hazard 8). Back to front:
    /// the second tucked card, the first, then the wash, which is the front
    /// sheet a folded parent shows at rest.
    private let sheet = InboxGroupSheetLayer()
    private let tuckedLayers = [InboxGroupSheetLayer(), InboxGroupSheetLayer()]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        for sublayer in tuckedLayers.reversed() + [sheet] { layer?.addSublayer(sublayer) }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ nesting: InboxNesting, hasChildren: Bool,
              metrics: InboxSpineMetrics, rowHeight: CGFloat, tuckedCards: Int = 0,
              cardRect: NSRect? = nil, roomBelowCard: CGFloat = .greatestFiniteMagnitude) {
        isGroupMember = hasChildren || nesting.depth > 0
        self.cardRect = cardRect
        deckRoom = roomBelowCard - 1
        roundsTop = isGroupMember && nesting.depth == 0
        roundsBottom = isGroupMember && nesting.nextDepth == 0
        horizontalInset = CGFloat(metrics.gutter)
        // Only a group that ends here can show cards below it: a folded parent
        // whose children are hidden. An open group draws its children instead.
        let tucked = roundsBottom ? max(0, min(2, tuckedCards)) : 0
        if tucked != self.tuckedCards {
            self.tuckedCards = tucked
            // A different stack is a different deck: never carry a pose over.
            setDeck(nil, animated: false)
        }
        layoutSheets()
    }

    /// The tucked cards as drawn, back to front, in this view's coordinates.
    /// Anchored at the front sheet: each one spans it and shows only its lower
    /// edge, `tuckedPeek` further down per step back.
    var tuckedCardRects: [NSRect] {
        let sheet = washRect
        guard tuckedCards > 0, sheet.width > 0, sheet.height > 0 else { return [] }
        return (1...tuckedCards).reversed().map { depth in
            let inset = Self.tuckedInset * CGFloat(depth)
            let bottom = sheet.maxY + Self.tuckedPeek * CGFloat(depth)
            return NSRect(x: sheet.minX + inset, y: sheet.minY,
                          width: max(0, sheet.width - inset * 2), height: max(0, bottom - sheet.minY))
        }
    }

    /// The shared wash this strip paints, in this view's coordinates. One
    /// property read by the layers and by the witness.
    var washRect: NSRect {
        // A group's first row starts at its card; a row inside the group runs
        // edge to edge so it joins the strips above and below across the
        // intercell gap; a folded parent ends at its card, and its tucked cards
        // show below it.
        let top = roundsTop ? (cardRect?.minY ?? 0) : 0
        let bottom = tuckedCards > 0 ? (cardRect?.maxY ?? bounds.height) : bounds.height
        return NSRect(x: horizontalInset, y: top,
                      width: max(0, bounds.width - horizontalInset * 2),
                      height: max(0, bottom - top))
    }

    override func layout() {
        super.layout()
        layoutSheets()
    }

    /// Whether this view's layer lays its sublayers out with y growing down.
    /// AppKit keeps a backing layer's sublayer space matching the view's own
    /// flippedness once the tree is attached; the layer's `contentsAreFlipped`
    /// cannot say so while a cell is laid out detached, before it joins a row.
    private var layerIsFlipped: Bool { isFlipped }

    /// Place and colour the three sheets. Bounds and position, never `frame`:
    /// a layer's frame is undefined under a transform, and the deck's pose is
    /// a transform about each card's top centre.
    private func layoutSheets() {
        let appearance = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        let theme: TokenTheme = appearance == .darkAqua ? .dark : .light
        let base = SidebarSurfaceRole.rowBase.color.resolved(for: theme)
        let foreground = TextToken.textPrimary.color.resolved(for: theme)
        func colour(_ alpha: CGFloat) -> NSColor {
            TokenColor(foreground.composited(over: base, alpha: alpha)).nsColor(for: theme)
        }
        // The radius is the card token, never a literal, so it follows the card
        // the sheets sit behind (Settings › Appearance › Corner style).
        let radius = CGFloat(Radius.card)
        let scale = window?.backingScaleFactor ?? 2
        let flipped = layerIsFlipped
        func place(_ sublayer: InboxGroupSheetLayer, _ rect: NSRect?, fill: NSColor?, top: CGFloat, bottom: CGFloat) {
            guard let rect, rect.width > 0, rect.height > 0, let fill else {
                sublayer.isHidden = true
                return
            }
            sublayer.isHidden = false
            sublayer.contentsScale = scale
            sublayer.anchorPoint = CGPoint(x: 0.5, y: flipped ? 0 : 1)
            sublayer.bounds = CGRect(origin: .zero, size: rect.size)
            sublayer.position = CGPoint(x: rect.midX, y: flipped ? rect.minY : bounds.height - rect.minY)
            sublayer.paint(fill: fill, top: top, bottom: bottom)
        }
        let wash = isGroupMember ? washRect : nil
        place(sheet, wash, fill: colour(Self.washAlpha),
              top: roundsTop ? radius : 0, bottom: roundsBottom ? radius : 0)
        // Depth d's card is `tuckedCardRects` read front to back, and recedes in
        // contrast with each step back.
        let rects = Array(tuckedCardRects.reversed())
        for (index, sublayer) in tuckedLayers.enumerated() {
            let rect = isGroupMember && rects.indices.contains(index) ? rects[index] : nil
            place(sublayer, rect, fill: colour(Self.tuckedAlphas[index]), top: radius, bottom: radius)
        }
    }

    // MARK: - Deck breathe

    /// How a folded parent's deck answers the pointer: the front sheet rises
    /// with its card and the cards behind it fan out below. Fixed by the spec
    /// and varied per agent by `Deck.pose(for:)`.
    struct Deck: Equatable {
        /// Up, in points, for the card and its front sheet.
        var lift: CGFloat
        /// Per tucked card, front to back: drop in points, lateral offset in
        /// points and rotation in degrees about the card's top centre.
        var drops: [CGFloat]
        var laterals: [CGFloat]
        var angles: [CGFloat]

        static let lift: CGFloat = 1
        static let drops: [CGFloat] = [2.5, 4.5]
        static let angles: [CGFloat] = [0.8, 1.4]
        static let angleJitter: CGFloat = 0.3
        static let lateralJitter: CGFloat = 1

        /// This pose shrunk evenly until every tucked card's lowest corner stays
        /// within `room` of the card's bottom. A card turned about its top
        /// centre swings its bottom corners by half its width × sin(angle), which
        /// for a full-width card is as much as the drop itself.
        func fitted(cards: [NSRect], peek: CGFloat, room: CGFloat) -> (Deck, scale: CGFloat) {
            var scale: CGFloat = 1
            for (index, card) in cards.enumerated() where index < drops.count {
                let reach = drops[index] + card.width / 2 * sin(abs(angles[index]) * .pi / 180)
                let free = room - peek * CGFloat(index + 1)
                guard reach > 0 else { continue }
                scale = min(scale, max(0, free / reach))
            }
            return (Deck(lift: lift, drops: drops.map { $0 * scale },
                         laterals: laterals.map { $0 * scale }, angles: angles.map { $0 * scale }), scale)
        }

        /// Stable per agent: the same UUID always fans the same way, and two
        /// agents rarely fan alike. Read from an FNV-1a hash of all sixteen
        /// bytes — ids minted in sequence share their leading bytes.
        static func pose(for agent: UUID) -> Deck {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            withUnsafeBytes(of: agent.uuid) { raw in
                for byte in raw { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
            }
            let bytes = withUnsafeBytes(of: hash) { Array($0) }
            func unit(_ byte: UInt8) -> CGFloat { CGFloat(byte) / 255 * 2 - 1 }
            let sign: CGFloat = bytes[0] & 1 == 0 ? 1 : -1
            return Deck(
                lift: lift, drops: drops,
                laterals: [unit(bytes[3]) * lateralJitter, unit(bytes[4]) * lateralJitter],
                angles: [sign * (angles[0] + unit(bytes[1]) * angleJitter),
                         -sign * (angles[1] + unit(bytes[2]) * angleJitter)])
        }
    }

    static let deckAnimationKey = "deck-breathe"
    /// One tucked card after the one in front of it.
    static let deckStagger: CFTimeInterval = 0.04

    /// Pose the deck — `nil` is the resting pose — and spring there from
    /// wherever it is presented now. `animated: false` snaps, for folding,
    /// scrolling and Reduce Motion. Touches three layers; no display link.
    func setDeck(_ requested: Deck?, animated: Bool) {
        let flipped = layerIsFlipped
        var deck = requested
        if let requested {
            let fit = requested.fitted(cards: Array(tuckedCardRects.reversed()), peek: Self.tuckedPeek, room: deckRoom)
            deck = fit.0
            deckScale = fit.scale
        }
        let down: CGFloat = flipped ? 1 : -1
        // The front sheet only lifts where it is the card's own sheet: an open
        // group's strip is shared with the rows around it.
        let sheetLift = tuckedCards > 0 ? (deck?.lift ?? 0) : 0
        Self.spring(sheet, to: CATransform3DMakeTranslation(0, -down * sheetLift, 0),
                    rising: deck != nil, delay: 0, animated: animated)
        for (index, sublayer) in tuckedLayers.enumerated() {
            var target = CATransform3DIdentity
            if let deck, index < tuckedCards {
                target = CATransform3DMakeTranslation(deck.laterals[index], down * deck.drops[index], 0)
                target = CATransform3DRotate(target, deck.angles[index] * .pi / 180 * down, 0, 0, 1)
            }
            Self.spring(sublayer, to: target, rising: deck != nil,
                        delay: Self.deckStagger * CFTimeInterval(index + 1), animated: animated)
        }
    }

    /// Spring one layer's transform to `target`, starting from the value on
    /// screen so a quick pass reverses mid-flight instead of jumping.
    static func spring(_ layer: CALayer, to target: CATransform3D, rising: Bool,
                       delay: CFTimeInterval, animated: Bool) {
        let from = layer.presentation()?.transform ?? layer.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: deckAnimationKey)
        layer.transform = target
        CATransaction.commit()
        guard animated, !CATransform3DEqualToTransform(from, target) else { return }
        let spring = rising
            ? CASpringAnimation(perceptualDuration: 0.32, bounce: 0.15)
            : CASpringAnimation(perceptualDuration: 0.26, bounce: 0)
        spring.keyPath = "transform"
        spring.fromValue = NSValue(caTransform3D: from)
        spring.toValue = NSValue(caTransform3D: target)
        spring.duration = spring.settlingDuration
        if delay > 0 {
            spring.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + delay
            spring.fillMode = .backwards
        }
        layer.add(spring, forKey: deckAnimationKey)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layoutSheets()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layoutSheets()
    }

    var qaIsVisibleForQA: Bool { isGroupMember }
    var qaRoundsTopForQA: Bool { roundsTop }
    var qaRoundsBottomForQA: Bool { roundsBottom }
    var qaTuckedCardsForQA: Int { tuckedCards }
    /// The deck as posed — model transforms, front sheet first, then the tucked
    /// cards front to back — and each tucked card's on-screen bounding box in
    /// this view's coordinates.
    var qaDeckTransformsForQA: [CATransform3D] { [sheet.transform] + tuckedLayers.prefix(tuckedCards).map(\.transform) }
    var qaTuckedBoundingRectsForQA: [NSRect] {
        tuckedLayers.prefix(tuckedCards).compactMap { sublayer in
            guard let host = layer else { return nil }
            let box = sublayer.frame  // the transformed bounding box, in host space
            return layerIsFlipped ? box : NSRect(x: box.minX, y: host.bounds.height - box.maxY,
                                                 width: box.width, height: box.height)
        }
    }
    var qaDeckAnimationCountForQA: Int {
        ([sheet] + tuckedLayers).filter { $0.animation(forKey: Self.deckAnimationKey) != nil }.count
    }
}

/// One sheet of a group background: the wash, or a card tucked behind a folded
/// parent. Painted with a bezier fill into the layer's contents rather than as
/// a layer colour, which keeps it out of the `TokenThemed` census (hazard 8).
final class InboxGroupSheetLayer: CALayer {
    private var fill: NSColor?
    private var topRadius: CGFloat = 0
    private var bottomRadius: CGFloat = 0

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        super.init(layer: layer)
        guard let other = layer as? InboxGroupSheetLayer else { return }
        fill = other.fill
        topRadius = other.topRadius
        bottomRadius = other.bottomRadius
    }

    required init?(coder: NSCoder) { nil }

    /// Geometry and pose are set by the view, inside its own transactions;
    /// nothing here animates implicitly.
    override func action(forKey event: String) -> CAAction? { NSNull() }

    func paint(fill: NSColor, top: CGFloat, bottom: CGFloat) {
        guard fill != self.fill || top != topRadius || bottom != bottomRadius else { return }
        self.fill = fill
        topRadius = top
        bottomRadius = bottom
        setNeedsDisplay()
    }

    override func draw(in context: CGContext) {
        guard let fill else { return }
        let flipped = contentsAreFlipped()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: flipped)
        fill.setFill()
        // The strip is written with y growing down; flip the radii otherwise.
        Self.strip(bounds, top: flipped ? topRadius : bottomRadius,
                   bottom: flipped ? bottomRadius : topRadius).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    static func strip(_ rect: NSRect, top: CGFloat, bottom: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let k: CGFloat = 0.5522847498
        path.move(to: NSPoint(x: rect.minX + top, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - top, y: rect.minY))
        if top > 0 {
            path.curve(to: NSPoint(x: rect.maxX, y: rect.minY + top),
                       controlPoint1: NSPoint(x: rect.maxX - top + top * k, y: rect.minY),
                       controlPoint2: NSPoint(x: rect.maxX, y: rect.minY + top - top * k))
        } else {
            path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        }
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - bottom))
        if bottom > 0 {
            path.curve(to: NSPoint(x: rect.maxX - bottom, y: rect.maxY),
                       controlPoint1: NSPoint(x: rect.maxX, y: rect.maxY - bottom + bottom * k),
                       controlPoint2: NSPoint(x: rect.maxX - bottom + bottom * k, y: rect.maxY))
        } else {
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        }
        path.line(to: NSPoint(x: rect.minX + bottom, y: rect.maxY))
        if bottom > 0 {
            path.curve(to: NSPoint(x: rect.minX, y: rect.maxY - bottom),
                       controlPoint1: NSPoint(x: rect.minX + bottom - bottom * k, y: rect.maxY),
                       controlPoint2: NSPoint(x: rect.minX, y: rect.maxY - bottom + bottom * k))
        } else {
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        }
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + top))
        if top > 0 {
            path.curve(to: NSPoint(x: rect.minX + top, y: rect.minY),
                       controlPoint1: NSPoint(x: rect.minX, y: rect.minY + top - top * k),
                       controlPoint2: NSPoint(x: rect.minX + top - top * k, y: rect.minY))
        } else {
            path.line(to: NSPoint(x: rect.minX, y: rect.minY))
        }
        path.close()
        return path
    }
}

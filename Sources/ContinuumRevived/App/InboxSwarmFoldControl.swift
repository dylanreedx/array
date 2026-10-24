import AppKit
import ContinuumRevivedAgentUI
import QuartzCore

// MARK: - The swarm glyph

/// The glyph the fold button draws. One design survived review: two cards.
/// The enum stays so stills and checks can name what they draw.
enum SwarmGlyphVariant: String, CaseIterable {
    case cards

    @MainActor static var current: SwarmGlyphVariant = .cards
}

/// Where the glyph's two cards sit. Pure, so the control, its witness and the
/// stills share one geometry. Rects are offsets from the glyph's centre in
/// points, y DOWN.
///
/// Folded: two overlapping cards, the front one knocking a gap out of the one
/// behind. Hovered: they ease apart. Open: the front card becomes the head of
/// the group's lane, a stem grows down from it to the connector, and the back
/// card drops into the lane and fades — it has become the rows below.
struct SwarmPose: Equatable {
    var front: CGRect
    var back: CGRect
    var backOpacity: Float
    /// How much of the stem from the head card down to the lane is drawn.
    var stem: CGFloat

    static let side: CGFloat = 14
    static let cornerRadius: CGFloat = 1.8
    /// The gap the front card cuts out of the one behind it.
    static let knockout: CGFloat = 1.3
    /// The stem's run, y down from the glyph centre.
    static let stemTop: CGFloat = 2.6
    static let stemBottom: CGFloat = 10

    static func pose(_ variant: SwarmGlyphVariant = .cards, seed: UUID = UUID(), children: Int = 3,
                     expanded: Bool, hovered: Bool) -> SwarmPose {
        if expanded {
            return SwarmPose(front: CGRect(x: -5, y: -4.2, width: 10, height: 6.6),
                             back: CGRect(x: -4, y: 3.2, width: 8, height: 6.2), backOpacity: 0, stem: 1)
        }
        let apart: CGFloat = hovered ? 1 : 0
        // Half-point steps: anything smaller rounds away on the backing grid.
        return SwarmPose(front: CGRect(x: -5.8 - (hovered ? 0.5 : 0), y: -1.6 + (hovered ? 0.5 : 0), width: 8, height: 6.2),
                         back: CGRect(x: -2.2 + apart, y: -5.6 - apart, width: 8, height: 6.2),
                         backOpacity: 1, stem: 0)
    }
}

// MARK: - The fold button

/// The control that folds a parent's subagents away: two small cards in the
/// connector lane and the child count beside it.
///
/// The CARD is the "go to agent" target; this is the one fold target on it. It
/// takes the card's full height across the lane and the count, acts on MOUSE
/// DOWN, shows a pressed step at once, and is the only thing on the card with a
/// pointing hand. Its highlight is a circle around the glyph alone.
///
/// Filled card = children working, outlined = idle: the front card fills while
/// any child works, the back one too once most do.
///
/// ONE CLOCK PER PARENT. A fold rebuilds the parent's cell, so the control that
/// starts a morph is rarely the one that finishes it. The morph is therefore a
/// record keyed by the parent's id — from-pose, to-pose, start time — and every
/// control that shows that parent adds the same animations with the same
/// absolute `beginTime`. A replacement cell joins the motion mid-flight at
/// exactly the phase the old one was in; nothing waits on a timer, so nothing
/// can drift. The fold presentation leaves the parent row live (see
/// `InboxFoldMotion`), so the morph is what the screen shows.
@MainActor
final class InboxSwarmFoldControl: NSControl, TokenThemed {
    /// Extra inset from the window edge for the glyph and the lane it heads.
    static let laneInset = Space.s
    static let glyphCentreX = CGFloat(AgentInboxView.indentPerLevel) / 2 + CGFloat(laneInset)
    static let countGap: CGFloat = 3
    static let countFont = NSFont.monospacedDigitSystemFont(
        ofSize: Typography.style(for: .label).size, weight: .medium)
    private static let digitAdvance = ceil(("0" as NSString).size(withAttributes: [.font: countFont]).width)
    private static let countPadding: CGFloat = 2
    /// The hover/pressed circle around the glyph.
    static let chipDiameter: CGFloat = 22

    static let expandMorph: CFTimeInterval = 0.32
    static let collapseMorph: CFTimeInterval = 0.28
    static let hoverMorph: CFTimeInterval = 0.24
    static let fadeDuration: CFTimeInterval = 0.12
    /// A soft start and a long, quiet landing — no overshoot.
    static let morphTiming = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0.28, 1)

    /// The control's width for `childCount`: fixed by its digit count, never
    /// measured in layout.
    static func width(childCount: Int) -> CGFloat {
        let digits = CGFloat(String(max(0, childCount)).count)
        return glyphCentreX + SwarmPose.side / 2 + countGap + digits * digitAdvance + countPadding
    }

    /// How many of the two cards are filled, front first: the front while any
    /// child works, both once most do.
    static func filledCards(children: Int, working: Int) -> Int {
        guard working > 0, children > 0 else { return 0 }
        return Double(working) / Double(children) >= 0.75 ? 2 : 1
    }

    // State
    private(set) var variant = SwarmGlyphVariant.current
    private(set) var disclosure: RowDisclosure = .none
    private(set) var childCount = 0
    private(set) var workingChildren = 0
    var filledCardCount: Int { Self.filledCards(children: childCount, working: workingChildren) }
    private var seed = UUID()
    private var leadColour: NSColor?
    private(set) var isPointerInside = false
    private(set) var isPressed = false
    /// The pose the layers rest on.
    private(set) var shownExpanded = false
    /// Where the glyph's centre sits, top-down from the control's top.
    var glyphCentreY: CGFloat = 0 { didSet { if oldValue != glyphCentreY { needsLayout = true } } }
    var prefersReducedMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // Layers
    private let chip = CALayer()
    private let glyph = CALayer()
    private let backHost = CALayer()
    private let knockout = CAShapeLayer()
    private let backCard = CAShapeLayer()
    private let frontCard = CAShapeLayer()
    private let stem = CAShapeLayer()
    private let countLabel = NSTextField(labelWithString: "")
    private var pointerTracking: NSTrackingArea?
    private(set) var isTwinkling = false
    private(set) var registeredCursorsForQA: [(rect: NSRect, cursor: NSCursor)] = []

    // MARK: The per-parent clock

    private struct Morph {
        let expanded: Bool
        let from: SwarmPose
        let start: CFTimeInterval
        let duration: CFTimeInterval
        var end: CFTimeInterval { start + duration }
    }
    /// In-flight morphs by parent. Entries retire once they end.
    private static var morphs: [UUID: Morph] = [:]
    /// A toggle armed by the control or the keyboard: the NEXT show of this
    /// parent in the opposite state starts a morph. Anything else (a scroll, a
    /// streamed update) lands its state without motion.
    private static var armed: [UUID: (from: RowDisclosure, at: CFTimeInterval)] = [:]

    private static var pressedSeed: UUID?
    private static var releaseMonitor: Any?
    private static let live = NSHashTable<InboxSwarmFoldControl>.weakObjects()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        chip.cornerRadius = Self.chipDiameter / 2
        chip.opacity = 0
        layer?.addSublayer(chip)
        layer?.addSublayer(glyph)
        // The back card lives in a host masked by everything EXCEPT the front
        // card grown by the knockout, so the front card cuts a clean gap.
        knockout.fillRule = .evenOdd
        backHost.mask = knockout
        backHost.addSublayer(backCard)
        glyph.addSublayer(backHost)
        glyph.addSublayer(frontCard)
        stem.fillColor = nil
        stem.lineWidth = 1
        stem.lineCap = .butt
        glyph.addSublayer(stem)
        for card in [backCard, frontCard] { card.lineWidth = 1 }
        countLabel.font = Self.countFont
        countLabel.alignment = .left
        countLabel.setAccessibilityElement(false)
        countLabel.wantsLayer = true
        addSubview(countLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        isHidden = true
        Self.live.add(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Content

    /// Configure for a row. `seed` is the parent's id: a fold's morph is keyed
    /// to it so whichever cell shows the parent plays the same motion.
    func show(_ disclosure: RowDisclosure, childCount: Int, workingChildren: Int,
              seed: UUID, leadColour: NSColor?) {
        let wasFilled = filledCardCount
        self.disclosure = disclosure
        self.childCount = disclosure == .none ? 0 : max(0, childCount)
        self.workingChildren = disclosure == .none ? 0 : workingChildren
        self.seed = seed
        self.leadColour = leadColour
        isPressed = Self.pressedSeed == seed && disclosure != .none
        isHidden = disclosure == .none
        countLabel.stringValue = self.childCount > 0 ? "\(self.childCount)" : ""
        if wasFilled != filledCardCount { setTwinkling(false) }
        let expanded = disclosure == .expanded
        let now = CACurrentMediaTime()
        if let arm = Self.armed[seed], arm.from != disclosure, now - arm.at < 1 {
            Self.armed[seed] = nil
            if !prefersReducedMotion() {
                Self.morphs[seed] = Morph(
                    expanded: expanded,
                    from: SwarmPose.pose(expanded: arm.from == .expanded, hovered: false),
                    start: now, duration: expanded ? Self.expandMorph : Self.collapseMorph)
            }
        }
        if let morph = Self.morphs[seed], morph.end <= now || morph.expanded != expanded {
            Self.morphs[seed] = nil
        }
        shownExpanded = expanded
        applyPose(animated: false, duration: 0)
        joinMorph()
        applyAccessibility()
        applyTokens(animated: false)
        refreshTwinkle()
        needsLayout = true
    }

    /// The control, or the keyboard, is about to fold `seed`'s group.
    static func noteToggle(seed: UUID, from disclosure: RowDisclosure) {
        armed[seed] = (disclosure, CACurrentMediaTime())
    }

    private var canAnimate: Bool { window != nil && !prefersReducedMotion() }

    // MARK: Pose

    var currentPose: SwarmPose {
        SwarmPose.pose(expanded: shownExpanded, hovered: isPointerInside && !isPressed && !shownExpanded)
    }

    var isMorphingForQA: Bool { frontCard.animation(forKey: "swarm.morph.front") != nil }
    /// The morph's absolute start, shared by every control showing the parent.
    var morphStartForQA: CFTimeInterval? { Self.morphs[seed]?.start }

    /// The scale the glyph rasterises at; a still sets it explicitly.
    private var stillScale: CGFloat?
    private var rasterScale: CGFloat { window?.backingScaleFactor ?? stillScale ?? 2 }

    /// A pose rect (y down, glyph-centred) in the glyph layer (y up), on the
    /// backing grid.
    private func layerRect(_ rect: CGRect) -> CGRect {
        let scale = rasterScale
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let cx = glyph.bounds.midX, cy = glyph.bounds.midY
        return CGRect(x: snap(cx + rect.minX), y: snap(cy - rect.maxY),
                      width: snap(rect.width), height: snap(rect.height))
    }

    private func cardPath(_ rect: CGRect, filled: Bool) -> CGPath {
        let r = layerRect(rect)
        let shape = filled ? r : r.insetBy(dx: 0.5, dy: 0.5)
        let radius = filled ? SwarmPose.cornerRadius : SwarmPose.cornerRadius - 0.5
        return CGPath(roundedRect: shape, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private func knockoutPath(_ front: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addRect(glyph.bounds.insetBy(dx: -8, dy: -8))
        let gap = SwarmPose.knockout, r = layerRect(front).insetBy(dx: -gap, dy: -gap)
        path.addRoundedRect(in: r, cornerWidth: SwarmPose.cornerRadius + gap,
                            cornerHeight: SwarmPose.cornerRadius + gap)
        return path
    }

    private func stemPath() -> CGPath {
        let path = CGMutablePath()
        let x = (glyph.bounds.midX * rasterScale).rounded() / rasterScale + 0.5 / rasterScale
        path.move(to: CGPoint(x: x, y: glyph.bounds.midY - SwarmPose.stemTop))
        path.addLine(to: CGPoint(x: x, y: glyph.bounds.midY - SwarmPose.stemBottom))
        return path
    }

    /// The four animated facts of a pose, as layer values.
    private func values(_ pose: SwarmPose) -> (front: CGPath, back: CGPath, mask: CGPath, backOpacity: Float, stem: CGFloat) {
        let filled = filledCardCount
        return (cardPath(pose.front, filled: filled >= 1), cardPath(pose.back, filled: filled >= 2),
                knockoutPath(pose.front), pose.backOpacity, pose.stem)
    }

    /// Rest the layers on the current pose; `animated` eases there from
    /// wherever they are on screen (hover).
    private func applyPose(animated: Bool, duration: CFTimeInterval) {
        guard glyph.bounds.width > 0 else { return }
        let target = values(currentPose)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backHost.frame = glyph.bounds
        knockout.frame = backHost.bounds
        backCard.frame = backHost.bounds
        frontCard.frame = glyph.bounds
        stem.frame = glyph.bounds
        stem.path = stemPath()
        let morphing = isMorphingForQA
        func ease(_ layer: CALayer, _ key: String, _ to: Any, presented: Any?) {
            guard animated, !morphing else { return }
            let move = CABasicAnimation(keyPath: key)
            move.fromValue = presented
            move.toValue = to
            move.duration = duration
            move.timingFunction = Self.morphTiming
            layer.add(move, forKey: "swarm.hover.\(key)")
        }
        ease(frontCard, "path", target.front, presented: frontCard.presentation()?.path ?? frontCard.path)
        ease(backCard, "path", target.back, presented: backCard.presentation()?.path ?? backCard.path)
        ease(knockout, "path", target.mask, presented: knockout.presentation()?.path ?? knockout.path)
        frontCard.path = target.front
        backCard.path = target.back
        knockout.path = target.mask
        backHost.opacity = target.backOpacity
        stem.strokeEnd = target.stem
        CATransaction.commit()
    }

    /// Add the parent's in-flight morph to these layers, at its absolute start.
    private func joinMorph() {
        let keys = ["swarm.morph.front", "swarm.morph.back", "swarm.morph.mask", "swarm.morph.fade", "swarm.morph.stem"]
        guard let morph = Self.morphs[seed], glyph.bounds.width > 0 else {
            for (layer, key) in zip([frontCard, backCard, knockout, backHost, stem] as [CALayer], keys) {
                layer.removeAnimation(forKey: key)
            }
            return
        }
        let from = values(morph.from)
        let to = values(SwarmPose.pose(expanded: morph.expanded, hovered: false))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        func add(_ layer: CALayer, _ path: String, _ a: Any, _ b: Any, _ key: String, delay: CFTimeInterval = 0) {
            let move = CABasicAnimation(keyPath: path)
            move.fromValue = a
            move.toValue = b
            move.duration = morph.duration - delay
            move.beginTime = layer.convertTime(morph.start, from: nil) + delay
            move.fillMode = .backwards
            move.timingFunction = Self.morphTiming
            for hover in ["path", "opacity", "strokeEnd"] { layer.removeAnimation(forKey: "swarm.hover.\(hover)") }
            layer.add(move, forKey: key)
        }
        add(frontCard, "path", from.front, to.front, keys[0])
        add(backCard, "path", from.back, to.back, keys[1])
        add(knockout, "path", from.mask, to.mask, keys[2])
        // Unfolding: the back card drops into the lane and fades as the stem
        // draws down after it. Folding: the stem retracts and the card returns.
        add(backHost, "opacity", from.backOpacity, to.backOpacity, keys[3])
        add(stem, "strokeEnd", from.stem, to.stem, keys[4], delay: morph.expanded ? morph.duration * 0.25 : 0)
        CATransaction.commit()
    }

    // MARK: Working children

    /// While a child works, the FILLED cards breathe — a slow, shallow dip in
    /// opacity, the back card a beat behind the front. It moves in place and
    /// never rotates, so it cannot be mistaken for the status gyro. Outlined
    /// cards (idle children) stay still; everything is still when all are done.
    private func refreshTwinkle() {
        setTwinkling(workingChildren > 0 && !isHidden && !prefersReducedMotion())
    }

    static let ripplePeriod: CFTimeInterval = 2.4

    func setTwinkling(_ on: Bool) {
        guard on != isTwinkling else { return }
        isTwinkling = on
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let base = CACurrentMediaTime()
        for (rank, card) in [frontCard, backCard].enumerated() {
            guard on, rank < filledCardCount else {
                card.removeAnimation(forKey: "swarm.ripple")
                continue
            }
            let breathe = CAKeyframeAnimation(keyPath: "opacity")
            breathe.values = [1, 0.62, 1, 1]
            breathe.keyTimes = [0, 0.3, 0.62, 1]
            breathe.duration = Self.ripplePeriod
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breathe.beginTime = card.convertTime(base, from: nil) + Double(rank) * 0.5
            breathe.fillMode = .backwards
            card.add(breathe, forKey: "swarm.ripple")
        }
        CATransaction.commit()
    }

    var twinklePeriodForQA: CFTimeInterval? {
        [frontCard, backCard].lazy.compactMap { $0.animation(forKey: "swarm.ripple")?.duration }.first
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        countInkMidY = Self.countInkMidY(scale: rasterScale)
        applyTokens(animated: false)
    }

    // MARK: Layout

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = SwarmPose.side
        let centreY = bounds.height - glyphCentreY
        let oldFrame = glyph.frame
        glyph.frame = CGRect(x: Self.glyphCentreX - side / 2, y: centreY - side / 2, width: side, height: side)
        let countX = Self.glyphCentreX + side / 2 + Self.countGap
        countLabel.frame = NSRect(x: countX, y: centreY + countInkMidY - Self.countHeight,
                                  width: max(0, bounds.width - countX), height: Self.countHeight)
        let d = Self.chipDiameter
        chip.frame = CGRect(x: Self.glyphCentreX - d / 2, y: centreY - d / 2, width: d, height: d)
        CATransaction.commit()
        applyPose(animated: false, duration: 0)
        // A cell configured before it had bounds joins its parent's morph now.
        if oldFrame != glyph.frame { joinMorph() }
    }

    /// Read in layout, measured only when the backing scale changes.
    private lazy var countInkMidY = Self.countInkMidY(scale: rasterScale)

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        countInkMidY = Self.countInkMidY(scale: rasterScale)
        needsLayout = true
    }

    private static let countHeight = ceil(countFont.ascender - countFont.descender + countFont.leading) + 2
    /// The digits' ink centre, top-down in the count label: digits are capitals,
    /// so their middle is the cap height's, measured once per scale.
    private static func countInkMidY(scale: CGFloat) -> CGFloat {
        InkProbe.cachedInk("swarm-count", scale: scale) {
            let probe = NSTextField(labelWithString: "0123456789")
            probe.font = countFont
            probe.frame = NSRect(x: 0, y: 0, width: 80, height: countHeight)
            return probe
        }?.midY ?? countHeight / 2
    }

    // MARK: Tokens

    func applyTokens() { applyTokens(animated: false) }

    /// The chip is painted once in its step's colour and faded by opacity, so a
    /// hover arrives and leaves over `fadeDuration` instead of snapping.
    private func applyTokens(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let emphasised = isPointerInside || isPressed
        let step: SidebarControlRole? = isPressed ? .pressed : (isPointerInside ? .hover : nil)
        if let step { chip.backgroundColor = step.color.cgColor(in: self) }
        let targetOpacity: Float = step == nil ? 0 : 1
        if animated, chip.opacity != targetOpacity {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = chip.presentation()?.opacity ?? chip.opacity
            fade.toValue = targetOpacity
            fade.duration = Self.fadeDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            chip.add(fade, forKey: "swarm.chip")
        }
        chip.opacity = targetOpacity
        if step == nil, !animated { chip.backgroundColor = nil }
        let ink = (emphasised ? TextToken.textPrimary : TextToken.textSecondary).color.cgColor(in: self)
        let lead: CGColor? = leadColour.map { colour in
            var resolved = colour.cgColor
            effectiveAppearance.performAsCurrentDrawingAppearance { resolved = colour.cgColor }
            return resolved
        }
        // Filled = children working; outlined = idle. The front card carries
        // the parent's identity colour.
        let filled = filledCardCount
        for (rank, card) in [frontCard, backCard].enumerated() {
            let colour = rank == 0 ? (lead ?? ink) : ink
            card.fillColor = rank < filled ? colour : nil
            card.strokeColor = rank < filled ? nil : colour
        }
        stem.strokeColor = LineToken.border.color.cgColor(in: self)
        countLabel.textColor = (emphasised ? TextToken.textPrimary : TextToken.textSecondary).color.nsColor(in: self)
        CATransaction.commit()
        applyPose(animated: false, duration: 0)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens(animated: false)
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTracking = area
    }

    override func mouseEntered(with event: NSEvent) { setPointerInside(true) }
    override func mouseExited(with event: NSEvent) { setPointerInside(false) }

    func setPointerInside(_ inside: Bool) {
        guard inside != isPointerInside else { return }
        isPointerInside = inside
        applyTokens(animated: canAnimate)
        applyPose(animated: canAnimate, duration: Self.hoverMorph)
    }

    override func resetCursorRects() {
        registeredCursorsForQA = []
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func addCursorRect(_ rect: NSRect, cursor object: NSCursor) {
        registeredCursorsForQA.append((rect, object))
        super.addCursorRect(rect, cursor: object)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Acts on the press, not the release: the fold starts with the click.
    override func mouseDown(with event: NSEvent) {
        guard !isHidden, disclosure != .none else { return }
        Self.pressedSeed = seed
        isPressed = true
        applyTokens(animated: false)
        // The release may be routed to a cell the fold rebuilt; watch for it at
        // the application instead.
        if Self.releaseMonitor == nil {
            Self.releaseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
                MainActor.assumeIsolated { Self.release() }
                return event
            }
        }
        toggle()
    }

    override func mouseUp(with event: NSEvent) { Self.release() }

    private static func release() {
        if let monitor = releaseMonitor { NSEvent.removeMonitor(monitor) }
        releaseMonitor = nil
        pressedSeed = nil
        for control in live.allObjects where control.isPressed {
            control.isPressed = false
            control.applyTokens(animated: control.canAnimate)
        }
    }

    override func performClick(_ sender: Any?) {
        guard !isHidden, disclosure != .none else { return }
        toggle()
    }

    override func accessibilityPerformPress() -> Bool {
        performClick(nil)
        return true
    }

    private func toggle() {
        Self.noteToggle(seed: seed, from: disclosure)
        sendAction(action, to: target)
    }

    // MARK: Accessibility

    private func applyAccessibility() {
        let verb = disclosure == .collapsed ? "Expand" : "Collapse"
        let expanded = disclosure == .expanded
        setAccessibilityLabel(childCount > 0 ? "\(verb) \(childCount) subagents" : verb)
        setAccessibilityValue(disclosure == .none ? nil
            : "\(childCount) subagents, \(expanded ? "expanded" : "collapsed")")
        setAccessibilityExpanded(expanded)
        setAccessibilityEnabled(disclosure != .none)
    }

    // MARK: QA

    /// The chip's fill as presented: nil while it is faded out.
    var chipFillForQA: CGColor? { chip.opacity > 0 ? chip.backgroundColor : nil }
    var chipFrameForQA: CGRect { chip.frame }
    var glyphFrameForQA: CGRect { glyph.frame }
    var countTextForQA: String { countLabel.stringValue }
    /// Front then back: filled (true) or outlined (false).
    var cardFillsForQA: [Bool] { [frontCard.fillColor != nil, backCard.fillColor != nil] }
    var cardColoursForQA: [CGColor?] { [frontCard.fillColor ?? frontCard.strokeColor, backCard.fillColor ?? backCard.strokeColor] }
    /// The model pose's front and back card boxes and back opacity, glyph
    /// coordinates (y up) — what the layers will rest on.
    var modelCardsForQA: (front: CGRect, back: CGRect, backOpacity: Float, stem: CGFloat) {
        (frontCard.path?.boundingBoxOfPath ?? .zero, backCard.path?.boundingBoxOfPath ?? .zero,
         backHost.opacity, stem.strokeEnd)
    }
    /// Whether the front card's knockout is cut from the back card's host.
    var knocksOutForQA: Bool { backHost.mask === knockout && knockout.path != nil }
    /// The state the control shows, in the vocabulary the older checks use.
    var qaGlyph: String { isHidden ? "" : disclosure.glyph }
    var qaTitle: String { isHidden ? "" : (childCount > 0 ? "\(disclosure.glyph) \(childCount)" : disclosure.glyph) }

    /// Configure a standalone instance for stills: no window, no motion.
    func configureForStill(variant: SwarmGlyphVariant, disclosure: RowDisclosure, childCount: Int,
                           workingChildren: Int, seed: UUID, hovered: Bool, scale: CGFloat) {
        self.variant = variant
        stillScale = scale
        prefersReducedMotion = { true }
        show(disclosure, childCount: childCount, workingChildren: workingChildren, seed: seed, leadColour: nil)
        isPointerInside = hovered
        applyTokens(animated: false)
        layoutSubtreeIfNeeded()
        applyPose(animated: false, duration: 0)
    }
}

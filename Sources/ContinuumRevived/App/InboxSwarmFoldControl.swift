import AppKit
import ContinuumRevivedAgentUI
import QuartzCore

// MARK: - The swarm glyph

/// The constellation the fold button draws. One design survived review (the
/// triad); the enum stays so stills and checks can name what they draw.
enum SwarmGlyphVariant: String, CaseIterable {
    case triad

    @MainActor static var current: SwarmGlyphVariant = .triad
}

/// Where the constellation's dots sit. Pure, so the control, its witness and
/// the stills share one geometry. Points are offsets from the glyph's centre in
/// points, y DOWN.
struct SwarmPose: Equatable {
    var dots: [CGPoint]
    /// Kept for the stills' vocabulary; the triad draws no strokes.
    var strokeEnd: CGFloat = 0

    static let side: CGFloat = 14
    /// Large enough that an outlined dot still reads as a ring, not a smudge.
    static let dotDiameterPoints: CGFloat = 4

    static func dotCount(_ variant: SwarmGlyphVariant, children: Int) -> Int { 3 }
    static func dotDiameter(_ variant: SwarmGlyphVariant) -> CGFloat { dotDiameterPoints }

    /// Folded: a triangle. Hovered: the triangle opens a little and turns a few
    /// degrees, so pointing at it reads as "this moves". Expanded: a vertical
    /// run that becomes the head of the connector lane.
    ///
    /// The dots are assigned so that EVERY dot travels on a fold — the triangle's
    /// apex drops to the middle of the run, its base corners swing to the ends —
    /// rather than the apex sitting still while two dots slide under it.
    static func pose(_ variant: SwarmGlyphVariant = .triad, seed: UUID = UUID(), children: Int = 3,
                     expanded: Bool, hovered: Bool) -> SwarmPose {
        if expanded {
            return SwarmPose(dots: [CGPoint(x: 0, y: 1.5), CGPoint(x: 0, y: -4.5), CGPoint(x: 0, y: 7.5)])
        }
        let rest = [CGPoint(x: 0, y: -3.6), CGPoint(x: -3.9, y: 2.7), CGPoint(x: 3.9, y: 2.7)]
        guard hovered else { return SwarmPose(dots: rest) }
        let angle = CGFloat(6) * .pi / 180, spread: CGFloat = 1.08
        return SwarmPose(dots: rest.map {
            CGPoint(x: ($0.x * cos(angle) - $0.y * sin(angle)) * spread,
                    y: ($0.x * sin(angle) + $0.y * cos(angle)) * spread)
        })
    }
}

// MARK: - The fold button

/// The control that folds a parent's subagents away: a small constellation in
/// the connector lane and the child count beside it.
///
/// The CARD is the "go to agent" target; this is the one fold target on it. It
/// takes the card's full height across the lane and the count, acts on MOUSE
/// DOWN, shows a pressed step at once, and is the only thing on the card with a
/// pointing hand. Its highlight is a circle around the glyph alone.
///
/// ONE CLOCK PER PARENT. A fold rebuilds the parent's cell, so the control that
/// starts a morph is rarely the one that finishes it. The morph is therefore a
/// record keyed by the parent's id — from-pose, to-pose, start time — and every
/// control that shows that parent adds the same animation with the same absolute
/// `beginTime`. A replacement cell joins the motion mid-flight at exactly the
/// phase the old one was in; nothing waits on a timer, so nothing can drift.
/// The fold presentation leaves the parent row live (see `InboxFoldMotion`), so
/// the morph is what the screen shows, not a photograph of either end.
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
    /// A soft start and a long, quiet landing — no overshoot, so the run lands
    /// as a lane.
    static let morphTiming = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0.28, 1)

    /// The control's width for `childCount`: fixed by its digit count, never
    /// measured in layout.
    static func width(childCount: Int) -> CGFloat {
        let digits = CGFloat(String(max(0, childCount)).count)
        return glyphCentreX + SwarmPose.side / 2 + countGap + digits * digitAdvance + countPadding
    }

    // State
    private(set) var variant = SwarmGlyphVariant.current
    private(set) var disclosure: RowDisclosure = .none
    private(set) var childCount = 0
    private(set) var workingChildren = 0
    /// How many of the three dots are filled: the working share of the
    /// children, at least one while any works. The rest are outlined.
    static func filledDots(children: Int, working: Int) -> Int {
        guard working > 0, children > 0 else { return 0 }
        return min(3, max(1, Int((3 * Double(working) / Double(children)).rounded())))
    }
    var filledDotCount: Int { Self.filledDots(children: childCount, working: workingChildren) }
    /// Dot indices top to bottom in the pose on screen; the first
    /// `filledDotCount` of them are filled.
    private var dotOrder: [Int] {
        let pose = currentPose.dots
        return dots.indices.sorted { pose[$0].y != pose[$1].y ? pose[$0].y < pose[$1].y : pose[$0].x < pose[$1].x }
    }
    private var shownFilled = -1
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
    private var dots: [CALayer] = []
    private let countLabel = NSTextField(labelWithString: "")
    private var pointerTracking: NSTrackingArea?
    private(set) var isTwinkling = false
    private(set) var registeredCursorsForQA: [(rect: NSRect, cursor: NSCursor)] = []

    // MARK: The per-parent clock

    private struct Morph {
        let expanded: Bool
        let from: [CGPoint]
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
        dots = (0..<3).map { _ in
            let dot = CALayer()
            let d = SwarmPose.dotDiameterPoints
            dot.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            dot.cornerRadius = d / 2
            glyph.addSublayer(dot)
            return dot
        }
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
        self.disclosure = disclosure
        self.childCount = disclosure == .none ? 0 : max(0, childCount)
        self.workingChildren = disclosure == .none ? 0 : workingChildren
        self.seed = seed
        self.leadColour = leadColour
        isPressed = Self.pressedSeed == seed && disclosure != .none
        isHidden = disclosure == .none
        countLabel.stringValue = self.childCount > 0 ? "\(self.childCount)" : ""
        if shownFilled != filledDotCount { shownFilled = filledDotCount; isTwinkling = false; dots.forEach { $0.removeAnimation(forKey: "swarm.ripple") } }
        let expanded = disclosure == .expanded
        let now = CACurrentMediaTime()
        if let arm = Self.armed[seed], arm.from != disclosure, now - arm.at < 1 {
            Self.armed[seed] = nil
            if !prefersReducedMotion() {
                let from = SwarmPose.pose(expanded: arm.from == .expanded, hovered: false).dots
                Self.morphs[seed] = Morph(expanded: expanded, from: from, start: now,
                                          duration: expanded ? Self.expandMorph : Self.collapseMorph)
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

    /// The dots' model positions as offsets from the glyph centre, y down — what
    /// the layers will rest on.
    var modelDotOffsetsForQA: [CGPoint] {
        let centre = CGPoint(x: glyph.bounds.midX, y: glyph.bounds.midY)
        return dots.map { CGPoint(x: $0.position.x - centre.x, y: -($0.position.y - centre.y)) }
    }
    var strokeEndForQA: CGFloat { 0 }
    /// Whether this control is playing its parent's fold morph right now.
    var isMorphingForQA: Bool { dots.contains { $0.animation(forKey: "swarm.morph") != nil } }
    /// The morph's absolute start, shared by every control showing the parent.
    var morphStartForQA: CFTimeInterval? { Self.morphs[seed]?.start }

    /// The scale the glyph rasterises at; a still sets it explicitly.
    private var stillScale: CGFloat?
    private var rasterScale: CGFloat { window?.backingScaleFactor ?? stillScale ?? 2 }

    /// Glyph-layer point (y up) for a pose offset (y down), on the backing grid.
    private func layerPoint(_ offset: CGPoint) -> CGPoint {
        let centre = CGPoint(x: glyph.bounds.midX, y: glyph.bounds.midY)
        let scale = rasterScale, radius = SwarmPose.dotDiameterPoints / 2
        func snap(_ value: CGFloat, origin: CGFloat) -> CGFloat {
            ((origin + value - radius) * scale).rounded() / scale + radius - origin
        }
        return CGPoint(x: snap(centre.x + offset.x, origin: glyph.frame.minX),
                       y: snap(centre.y - offset.y, origin: glyph.frame.minY))
    }

    /// Rest the dots on the current pose; `animated` eases there from wherever
    /// they are on screen (hover).
    private func applyPose(animated: Bool, duration: CFTimeInterval) {
        let targets = currentPose.dots.map(layerPoint)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (dot, target) in zip(dots, targets) {
            if animated, dot.animation(forKey: "swarm.morph") == nil {
                let move = CABasicAnimation(keyPath: "position")
                move.fromValue = NSValue(point: dot.presentation()?.position ?? dot.position)
                move.toValue = NSValue(point: target)
                move.duration = duration
                move.timingFunction = Self.morphTiming
                dot.add(move, forKey: "swarm.hover")
            }
            dot.position = target
        }
        CATransaction.commit()
    }

    /// Add the parent's in-flight morph to these layers, at its absolute start.
    /// Each dot swings on a curve (clockwise), so the triangle reads as turning
    /// into the run rather than sliding.
    private func joinMorph() {
        guard let morph = Self.morphs[seed], glyph.bounds.width > 0 else {
            dots.forEach { $0.removeAnimation(forKey: "swarm.morph") }
            return
        }
        let to = SwarmPose.pose(expanded: morph.expanded, hovered: false).dots
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, dot) in dots.enumerated() where index < to.count && index < morph.from.count {
            let a = layerPoint(morph.from[index]), b = layerPoint(to[index])
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let dx = b.x - a.x, dy = b.y - a.y
            let bend: CGFloat = morph.expanded ? 0.18 : -0.18
            let control = CGPoint(x: mid.x - dy * bend, y: mid.y + dx * bend)
            let path = CGMutablePath()
            path.move(to: a)
            path.addQuadCurve(to: b, control: control)
            let swing = CAKeyframeAnimation(keyPath: "position")
            swing.path = path
            swing.duration = morph.duration
            swing.beginTime = dot.convertTime(morph.start, from: nil)
            swing.fillMode = .backwards
            swing.timingFunction = Self.morphTiming
            swing.calculationMode = .paced
            dot.removeAnimation(forKey: "swarm.hover")
            dot.add(swing, forKey: "swarm.morph")
        }
        CATransaction.commit()
        refreshTwinkleAfterMorph(morph)
    }

    // MARK: Working children

    /// While a child works, a quiet ripple runs through the FILLED dots — each
    /// swells a little and brightens in turn, top to bottom when the group is
    /// open. It moves in place and never rotates, so it cannot be mistaken for
    /// the status gyro. Outlined dots (children not working) stay still, and
    /// the whole glyph is still when every child is done.
    private func refreshTwinkle() {
        setTwinkling(workingChildren > 0 && !isHidden && !prefersReducedMotion())
    }

    private func refreshTwinkleAfterMorph(_ morph: Morph) {
        // Re-seat the ripple in the new order once the morph has landed.
        guard isTwinkling else { return }
        let delay = max(0, morph.end - CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isTwinkling else { return }
            self.isTwinkling = false
            self.refreshTwinkle()
        }
    }

    static let ripplePeriod: CFTimeInterval = 2.4

    func setTwinkling(_ on: Bool) {
        guard on != isTwinkling else { return }
        isTwinkling = on
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Order the ripple top to bottom on screen.
        let order = dotOrder
        let base = CACurrentMediaTime()
        for (rank, index) in order.enumerated() {
            let dot = dots[index]
            guard on, rank < filledDotCount else {
                dot.removeAnimation(forKey: "swarm.ripple")
                continue
            }
            let swell = CAKeyframeAnimation(keyPath: "transform.scale")
            swell.values = [1, 1.2, 1, 1]
            swell.keyTimes = [0, 0.2, 0.5, 1]
            let glow = CAKeyframeAnimation(keyPath: "opacity")
            glow.values = [0.7, 1, 0.7, 0.7]
            glow.keyTimes = swell.keyTimes
            let ripple = CAAnimationGroup()
            ripple.animations = [swell, glow]
            ripple.duration = Self.ripplePeriod
            ripple.repeatCount = .infinity
            ripple.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ripple.beginTime = dot.convertTime(base, from: nil) + Double(rank) * 0.24
            ripple.fillMode = .backwards
            dot.add(ripple, forKey: "swarm.ripple")
        }
        CATransaction.commit()
    }

    var twinklePeriodForQA: CFTimeInterval? {
        dots.lazy.compactMap { $0.animation(forKey: "swarm.ripple")?.duration }.first
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
        let ink = (emphasised ? TextToken.textPrimary : TextToken.textSecondary).color
        let lead: CGColor? = leadColour.map { colour in
            var resolved = colour.cgColor
            effectiveAppearance.performAsCurrentDrawingAppearance { resolved = colour.cgColor }
            return resolved
        }
        // Filled = a working child; outlined = one that is not. The lead dot
        // (the top one on screen) carries the parent's identity colour.
        let filled = filledDotCount
        for (rank, index) in dotOrder.enumerated() {
            let dot = dots[index]
            let colour = rank == 0 && lead != nil ? lead! : ink.cgColor(in: self)
            if rank < filled {
                dot.backgroundColor = colour
                dot.borderWidth = 0
                dot.borderColor = nil
            } else {
                dot.backgroundColor = nil
                dot.borderWidth = 1
                dot.borderColor = colour
            }
        }
        countLabel.textColor = ink.nsColor(in: self)
        CATransaction.commit()
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
    var dotColoursForQA: [CGColor?] { dots.map { $0.backgroundColor ?? $0.borderColor } }
    /// Per dot, top to bottom: filled (true) or outlined (false).
    var dotFillsForQA: [Bool] { dotOrder.map { dots[$0].backgroundColor != nil } }
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
        // A still of the working state: the first dot at the crest of its ripple.
        if filledDotCount > 0, let first = dotOrder.first { dots[first].opacity = 1 }
    }
}

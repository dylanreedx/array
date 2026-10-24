import AppKit
import ContinuumRevivedAgentUI
import QuartzCore

// MARK: - The swarm glyph

/// Which constellation the fold button draws.
///
/// TEMPORARY: three candidates behind `ARRAY_SWARM_GLYPH=triad|chart|seeded`, read
/// once at startup, so they can be compared live in the dev preview. Delete this
/// switch and the two losing variants once one is picked.
enum SwarmGlyphVariant: String, CaseIterable {
    case triad, chart, seeded

    @MainActor static var current: SwarmGlyphVariant = ProcessInfo.processInfo
        .environment["ARRAY_SWARM_GLYPH"].flatMap(SwarmGlyphVariant.init(rawValue:)) ?? .triad
}

/// Where a constellation's dots (and, for `chart`, its strokes) sit. Pure, so
/// the control, its witness and the contact sheet share one geometry.
///
/// Points are offsets from the glyph's centre in points, y DOWN.
struct SwarmPose: Equatable {
    var dots: [CGPoint]
    /// How much of the polyline through `dots` is drawn (`chart` only).
    var strokeEnd: CGFloat

    static let side: CGFloat = 14

    static func dotCount(_ variant: SwarmGlyphVariant, children: Int) -> Int {
        switch variant {
        case .triad: return 3
        case .chart: return children >= 4 ? 4 : 3
        case .seeded: return min(max(children, 2), 5)
        }
    }

    static func dotDiameter(_ variant: SwarmGlyphVariant) -> CGFloat {
        variant == .triad ? 3 : 2.5
    }

    /// The pose for one state. Expanded wins over hover: an open group's dots
    /// are the head of its connector lane, and the lane does not wobble.
    static func pose(_ variant: SwarmGlyphVariant, seed: UUID, children: Int,
                     expanded: Bool, hovered: Bool) -> SwarmPose {
        let count = dotCount(variant, children: children)
        if expanded { return SwarmPose(dots: line(count), strokeEnd: variant == .chart ? 1 : 0) }
        switch variant {
        case .triad:
            let spread: CGFloat = hovered ? 1.25 : 1
            let rest = [CGPoint(x: 0, y: -3.5), CGPoint(x: -3.6, y: 2.6), CGPoint(x: 3.6, y: 2.6)]
            return SwarmPose(dots: rest.map { CGPoint(x: $0.x * spread, y: $0.y * spread) }, strokeEnd: 0)
        case .chart:
            let four = [CGPoint(x: -4.5, y: 2.5), CGPoint(x: -1.5, y: -3.5),
                        CGPoint(x: 2.5, y: -1), CGPoint(x: 4.5, y: 4)]
            let three = [CGPoint(x: -4.5, y: 3), CGPoint(x: -0.5, y: -3.5), CGPoint(x: 4, y: 1.5)]
            return SwarmPose(dots: count == 4 ? four : three, strokeEnd: hovered ? 1 : 0)
        case .seeded:
            // Every byte of the id feeds the pattern: ids minted in sequence
            // differ only at the end.
            var state = withUnsafeBytes(of: seed.uuid) { raw in
                raw.load(fromByteOffset: 0, as: UInt64.self) ^ raw.load(fromByteOffset: 8, as: UInt64.self).byteSwapped
            }
            func unit() -> CGFloat {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return CGFloat((z ^ (z >> 31)) >> 11) / CGFloat(1 << 53)
            }
            let rotation = unit() * 2 * .pi
            let reach: CGFloat = hovered ? 1.3 : 1
            return SwarmPose(dots: (0..<count).map { index in
                let jitter = (unit() - 0.5) * (.pi / CGFloat(count)) * 0.7
                let angle = rotation + CGFloat(index) * 2 * .pi / CGFloat(count) + jitter
                let radius = min(6, (3 + unit() * 2.5) * reach)
                return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            }, strokeEnd: 0)
        }
    }

    /// The expanded pose: a vertical run down the lane, head at the top.
    private static func line(_ count: Int) -> [CGPoint] {
        let top: CGFloat = -4, bottom: CGFloat = 7
        return (0..<count).map { index in
            CGPoint(x: 0, y: top + (bottom - top) * CGFloat(index) / CGFloat(max(1, count - 1)))
        }
    }
}

// MARK: - The fold button

/// The control that folds a parent's subagents away: a small constellation in
/// the connector lane and the child count beside it.
///
/// The CARD is the "go to agent" target; this is the one fold target on it. It
/// takes the card's full height across the lane and the count, acts on MOUSE
/// DOWN, shows a pressed step at once, and is the only thing on the card with a
/// pointing hand.
///
/// Motion is Core Animation on the glyph's own layers. A fold photographs the
/// rows and cross-fades them (`InboxFoldMotion`), so a morph started at the click
/// would play hidden under the photographs: the glyph HOLDS the pose you clicked
/// through the photographs and morphs once they have gone.
@MainActor
final class InboxSwarmFoldControl: NSControl, TokenThemed {
    static let glyphCentreX = CGFloat(AgentInboxView.indentPerLevel) / 2
    static let countGap: CGFloat = 3
    static let countFont = NSFont.monospacedDigitSystemFont(
        ofSize: Typography.style(for: .label).size, weight: .medium)
    private static let digitAdvance = ceil(("0" as NSString).size(withAttributes: [.font: countFont]).width)
    private static let countPadding: CGFloat = 2

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
    private var seed = UUID()
    private var leadColour: NSColor?
    private(set) var isPointerInside = false
    private(set) var isPressed = false
    /// The pose the layers hold, which lags `disclosure` while a fold plays.
    private(set) var shownExpanded = false
    /// Where the glyph's centre sits, top-down from the control's top.
    var glyphCentreY: CGFloat = 0 { didSet { if oldValue != glyphCentreY { needsLayout = true } } }
    var prefersReducedMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // Layers
    private let chip = CALayer()
    private let glyph = CALayer()
    private let strokes = CAShapeLayer()
    private var dots: [CALayer] = []
    private let countLabel = NSTextField(labelWithString: "")
    private var pointerTracking: NSTrackingArea?
    private var morphGeneration = 0
    private var keyObservers: [NSObjectProtocol] = []
    private(set) var isTwinkling = false
    private(set) var registeredCursorsForQA: [(rect: NSRect, cursor: NSCursor)] = []

    /// One toggle in flight, so whichever cell the reload binds to the parent
    /// can hold the pose the click came from.
    private static var pendingToggle: (seed: UUID, from: RowDisclosure, at: CFTimeInterval)?
    /// The parent whose control is held down. The fold reloads the list on the
    /// press, which can bind the parent to another cell; the pressed step
    /// follows the parent, and the release clears it wherever it landed.
    private static var pressedSeed: UUID?
    private static var releaseMonitor: Any?
    private static let live = NSHashTable<InboxSwarmFoldControl>.weakObjects()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        chip.cornerRadius = 5
        layer?.addSublayer(chip)
        layer?.addSublayer(glyph)
        strokes.fillColor = nil
        strokes.lineWidth = LineWidth.hairline
        strokes.lineJoin = .round
        strokes.strokeEnd = 0
        glyph.addSublayer(strokes)
        countLabel.font = Self.countFont
        countLabel.alignment = .left
        countLabel.setAccessibilityElement(false)
        addSubview(countLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        isHidden = true
        Self.live.add(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Content

    /// Configure for a row. `seed` is the parent's id: the seeded constellation
    /// is drawn from it, and a toggle is matched to it across a reload.
    func show(_ disclosure: RowDisclosure, childCount: Int, workingChildren: Int,
              seed: UUID, leadColour: NSColor?) {
        let previousSeed = self.seed
        self.disclosure = disclosure
        self.childCount = disclosure == .none ? 0 : max(0, childCount)
        self.workingChildren = disclosure == .none ? 0 : workingChildren
        self.seed = seed
        self.leadColour = leadColour
        isPressed = Self.pressedSeed == seed && disclosure != .none
        isHidden = disclosure == .none
        countLabel.stringValue = self.childCount > 0 ? "\(self.childCount)" : ""
        rebuildDotsIfNeeded()
        let expanded = disclosure == .expanded
        if let pending = Self.pendingToggle, pending.seed == seed,
           CACurrentMediaTime() - pending.at < 1, disclosure != pending.from {
            Self.pendingToggle = nil
            setPose(expanded: pending.from == .expanded, animated: false)
            // Not `canAnimate`: the reload configures a cell before the table
            // puts it back in the window.
            if !prefersReducedMotion() {
                let delay = expanded ? InboxFoldMotion.expandDuration : InboxFoldMotion.collapseDuration
                scheduleMorph(to: expanded, after: delay)
            } else {
                setPose(expanded: expanded, animated: false)
            }
        } else if previousSeed != seed || shownExpanded != expanded {
            morphGeneration += 1
            setPose(expanded: expanded, animated: false)
        }
        applyAccessibility()
        applyTokens()
        refreshTwinkle()
        needsLayout = true
    }

    /// The control, or the keyboard, is about to fold `seed`'s group.
    static func noteToggle(seed: UUID, from disclosure: RowDisclosure) {
        pendingToggle = (seed, disclosure, CACurrentMediaTime())
    }

    private var canAnimate: Bool { window != nil && !prefersReducedMotion() }

    private func scheduleMorph(to expanded: Bool, after delay: TimeInterval) {
        morphGeneration += 1
        let generation = morphGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.02) { [weak self] in
            guard let self, self.morphGeneration == generation else { return }
            self.setPose(expanded: expanded, animated: self.canAnimate)
        }
    }

    private func rebuildDotsIfNeeded() {
        let count = SwarmPose.dotCount(variant, children: childCount)
        let diameter = SwarmPose.dotDiameter(variant)
        guard dots.count != count || dots.first?.bounds.width != diameter else { return }
        dots.forEach { $0.removeFromSuperlayer() }
        dots = (0..<count).map { _ in
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            dot.cornerRadius = diameter / 2
            glyph.addSublayer(dot)
            return dot
        }
        isTwinkling = false
        setPose(expanded: shownExpanded, animated: false)
    }

    // MARK: Pose

    var currentPose: SwarmPose {
        SwarmPose.pose(variant, seed: seed, children: childCount,
                       expanded: shownExpanded, hovered: isPointerInside && !isPressed)
    }

    /// The dots' model positions as offsets from the glyph centre, y down — what
    /// the layers will rest on.
    var modelDotOffsetsForQA: [CGPoint] {
        let centre = CGPoint(x: glyph.bounds.midX, y: glyph.bounds.midY)
        return dots.map { CGPoint(x: $0.position.x - centre.x, y: -($0.position.y - centre.y)) }
    }
    var strokeEndForQA: CGFloat { strokes.strokeEnd }

    private func setPose(expanded: Bool, animated: Bool) {
        shownExpanded = expanded
        applyPose(animated: animated, duration: 0.24, stagger: variant == .seeded ? 0.03 : 0)
    }

    /// The scale the glyph rasterises at; a still sets it explicitly.
    private var stillScale: CGFloat?
    private var rasterScale: CGFloat { window?.backingScaleFactor ?? stillScale ?? 2 }

    private func applyPose(animated: Bool, duration: CFTimeInterval, stagger: CFTimeInterval = 0) {
        let pose = currentPose
        let centre = CGPoint(x: glyph.bounds.midX, y: glyph.bounds.midY)
        // A 3pt dot on a half pixel smears into a plus at 1x: put each dot's
        // edge on the backing grid, in the control's coordinates.
        let scale = rasterScale, radius = SwarmPose.dotDiameter(variant) / 2
        func snap(_ value: CGFloat, origin: CGFloat) -> CGFloat {
            ((origin + value - radius) * scale).rounded() / scale + radius - origin
        }
        // The glyph layer is y-up; a pose is y-down.
        let targets = pose.dots.map {
            CGPoint(x: snap(centre.x + $0.x, origin: glyph.frame.minX),
                    y: snap(centre.y - $0.y, origin: glyph.frame.minY))
        }
        let path = CGMutablePath()
        if let first = targets.first {
            path.move(to: first)
            for point in targets.dropFirst() { path.addLine(to: point) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let now = CACurrentMediaTime()
        for (index, dot) in dots.enumerated() where index < targets.count {
            if animated {
                let move = CABasicAnimation(keyPath: "position")
                move.fromValue = NSValue(point: dot.presentation()?.position ?? dot.position)
                move.toValue = NSValue(point: targets[index])
                move.duration = duration
                move.beginTime = now + stagger * Double(index)
                move.fillMode = .backwards
                move.timingFunction = CAMediaTimingFunction(name: .easeOut)
                dot.add(move, forKey: "swarm.position")
            }
            dot.position = targets[index]
        }
        if animated {
            let reshape = CABasicAnimation(keyPath: "path")
            reshape.fromValue = strokes.presentation()?.path ?? strokes.path
            reshape.toValue = path
            reshape.duration = duration
            reshape.timingFunction = CAMediaTimingFunction(name: .easeOut)
            strokes.add(reshape, forKey: "swarm.path")
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = strokes.presentation()?.strokeEnd ?? strokes.strokeEnd
            draw.toValue = pose.strokeEnd
            draw.duration = duration
            draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
            strokes.add(draw, forKey: "swarm.strokeEnd")
        }
        strokes.path = path
        strokes.strokeEnd = pose.strokeEnd
        CATransaction.commit()
    }

    // MARK: Working children

    /// One dot at a time brightens, on the status glyph's 2 s rhythm with its
    /// 40% floor, while a child is working and the window is key.
    private func refreshTwinkle() {
        let wants = workingChildren > 0 && !isHidden && !prefersReducedMotion()
            && (window?.isKeyWindow ?? false)
        setTwinkling(wants)
    }

    func setTwinkling(_ on: Bool) {
        guard on != isTwinkling else { return }
        isTwinkling = on
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, dot) in dots.enumerated() {
            guard on else { dot.removeAnimation(forKey: "swarm.twinkle"); dot.opacity = 1; continue }
            let count = Double(dots.count)
            let start = Double(index) / count, end = Double(index + 1) / count
            let twinkle = CAKeyframeAnimation(keyPath: "opacity")
            twinkle.values = [0.4, 0.4, 1.0, 0.4, 0.4]
            twinkle.keyTimes = [0, start, (start + end) / 2, end, 1].map { NSNumber(value: $0) }
            twinkle.duration = 2.0 * count
            twinkle.repeatCount = .infinity
            twinkle.calculationMode = .linear
            dot.opacity = 0.4
            dot.add(twinkle, forKey: "swarm.twinkle")
        }
        CATransaction.commit()
    }

    var twinklePeriodForQA: CFTimeInterval? {
        (dots.first?.animation(forKey: "swarm.twinkle") as? CAKeyframeAnimation).map { $0.duration / Double(dots.count) }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        guard let newWindow else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: newWindow, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshTwinkle() }
                })
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        countInkMidY = Self.countInkMidY(scale: rasterScale)
        refreshTwinkle()
        applyTokens()
    }

    // MARK: Layout

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = SwarmPose.side
        let centreY = bounds.height - glyphCentreY
        glyph.frame = CGRect(x: Self.glyphCentreX - side / 2, y: centreY - side / 2, width: side, height: side)
        let countX = Self.glyphCentreX + side / 2 + Self.countGap
        let countInk = countInkMidY
        countLabel.frame = NSRect(x: countX, y: centreY + countInk - Self.countHeight,
                                  width: max(0, bounds.width - countX), height: Self.countHeight)
        chip.frame = CGRect(x: 0, y: centreY - 9, width: bounds.width, height: 18)
        CATransaction.commit()
        applyPose(animated: false, duration: 0)
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

    func applyTokens() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let emphasised = isPointerInside || isPressed
        chip.backgroundColor = isPressed
            ? SidebarControlRole.pressed.color.cgColor(in: self)
            : (isPointerInside ? SidebarControlRole.hover.color.cgColor(in: self) : nil)
        let ink = (emphasised ? TextToken.textPrimary : TextToken.textSecondary).color
        for (index, dot) in dots.enumerated() {
            dot.backgroundColor = index == 0 && leadColour != nil
                ? leadColour.map { colour in
                    var resolved = colour.cgColor
                    effectiveAppearance.performAsCurrentDrawingAppearance { resolved = colour.cgColor }
                    return resolved
                  }
                : ink.cgColor(in: self)
        }
        // The lane's own hairline has no contrast on the hover chip.
        strokes.strokeColor = LineToken.border.color.cgColor(in: self)
        countLabel.textColor = ink.nsColor(in: self)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
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
        applyTokens()
        applyPose(animated: canAnimate, duration: 0.12)
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
        applyTokens()
        // The release may be routed to a cell the reload detached; watch for it
        // at the application instead.
        if Self.releaseMonitor == nil {
            Self.releaseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
                MainActor.assumeIsolated { Self.release() }
                return event
            }
        }
        toggle()
    }

    override func mouseUp(with event: NSEvent) {
        print("DEBUG mouseUp self===held? window=\(window != nil) pressed=\(isPressed)")
        Self.release()
    }

    private static func release() {
        if let monitor = releaseMonitor { NSEvent.removeMonitor(monitor) }
        releaseMonitor = nil
        pressedSeed = nil
        for control in live.allObjects where control.isPressed {
            control.isPressed = false
            control.applyTokens()
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

    var chipFillForQA: CGColor? { chip.backgroundColor }
    var countTextForQA: String { countLabel.stringValue }
    var dotColoursForQA: [CGColor?] { dots.map(\.backgroundColor) }
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
        applyTokens()
        layoutSubtreeIfNeeded()
        applyPose(animated: false, duration: 0)
        // A still of the working state: the first dot at the top of its twinkle.
        if workingChildren > 0 {
            for (index, dot) in dots.enumerated() { dot.opacity = index == 0 ? 1 : 0.4 }
        }
    }
}

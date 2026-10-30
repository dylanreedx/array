import AppKit
import ContinuumRevivedAgentUI

// Plan: .plans/106-sidebar-ownership (LOCKED: T2 + N1)
//
// The sidebar's three moving things — the light round a running lead's card,
// the shimmer across working text, the three pulsing dots — and the stem that
// joins a lead to its subagents. Every motion here is Core Animation on an
// absolute timeline: a cell adds its animation with a `beginTime` derived from
// the media clock and the agent's own phase, so a reload, a recycled cell or a
// neighbouring slice of the same card all land on the same pose, and Array does
// no per-frame work (`docs/internals/performance.md`). Under Reduce Motion
// nothing moves.

/// Where an agent's loop is right now: shared by every view that animates it.
@MainActor
enum InboxOwnershipClock {
    /// A `beginTime` for a loop of `period` seconds in `layer`'s time space, so
    /// that every layer handed the same `phase` (0...1) shows the same pose at the
    /// same instant, whenever it was added.
    static func beginTime(period: CFTimeInterval, phase: Double, in layer: CALayer) -> CFTimeInterval {
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        let into = (now + phase * period).truncatingRemainder(dividingBy: period)
        return now - into
    }

    /// A stable 0...1 phase per agent, so no two leads move in step.
    static func phase(for id: UUID) -> Double {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        withUnsafeBytes(of: id.uuid) { raw in
            for byte in raw { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        }
        return Double(hash % 1000) / 1000
    }
}

// MARK: - The sweep

/// A thin border with one light travelling round it, haloed in the lead's
/// colour. One slice per table cell: each draws the WHOLE card's border and
/// light, clipped to its own strip, and because every slice runs the same path
/// on the same timeline the light passes from one row into the next unbroken.
@MainActor
final class InboxSweepBorderView: NSView {
    static let period: CFTimeInterval = 3
    static let lineWidth: CGFloat = 0.75
    static let haloRadius: CGFloat = 64
    static let coreRadius: CGFloat = 18
    static let animationKey = "ownership.sweep"

    private let ring = CAShapeLayer()
    private let lightHost = CALayer()
    private let ringMask = CAShapeLayer()
    private let halo = CAGradientLayer()
    private let core = CAGradientLayer()
    private var shown: (card: NSRect, colour: NSColor?, phase: Double, dark: Bool, moving: Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        ring.fillColor = nil
        ring.lineWidth = Self.lineWidth
        ringMask.fillColor = nil
        ringMask.strokeColor = NSColor.black.cgColor
        ringMask.lineWidth = Self.lineWidth
        lightHost.mask = ringMask
        for gradient in [halo, core] {
            gradient.type = .radial
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 1)
            lightHost.addSublayer(gradient)
        }
        halo.bounds = CGRect(x: 0, y: 0, width: Self.haloRadius * 2, height: Self.haloRadius * 2)
        core.bounds = CGRect(x: 0, y: 0, width: Self.coreRadius * 2, height: Self.coreRadius * 2)
        layer?.addSublayer(ring)
        layer?.addSublayer(lightHost)
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Removed with the cell; re-added on the same timeline when it returns.
        if let shown { apply(shown, force: true) }
    }

    /// Draw the border of `card` (this view's coordinates; it may extend past
    /// the view, which clips) with its light, or nothing when `card` is nil.
    func show(card: NSRect?, colour: NSColor?, phase: Double, moving: Bool) {
        guard let card else {
            shown = nil
            isHidden = true
            lightHost.removeAllAnimations()
            halo.removeAllAnimations()
            core.removeAllAnimations()
            return
        }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let next = (card, colour, phase, dark, moving)
        if let shown, shown.card == card, shown.colour == colour, shown.phase == phase,
           shown.dark == dark, shown.moving == moving, !isHidden { return }
        apply(next, force: false)
    }

    private func apply(_ next: (card: NSRect, colour: NSColor?, phase: Double, dark: Bool, moving: Bool), force: Bool) {
        shown = next
        isHidden = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let inset = next.card.insetBy(dx: Self.lineWidth / 2, dy: Self.lineWidth / 2)
        let radius = max(0, CGFloat(Radius.card) - Self.lineWidth / 2)
        let path = CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let contrast: NSColor = next.dark ? .white : .black
        ring.frame = bounds
        ring.path = path
        ring.strokeColor = contrast.withAlphaComponent(next.dark ? 0.07 : 0.08).cgColor
        lightHost.frame = bounds
        ringMask.frame = bounds
        ringMask.path = path
        let haloColour = (next.colour ?? contrast)
            .withAlphaComponent(next.colour == nil ? (next.dark ? 0.35 : 0.3) : (next.dark ? 0.85 : 0.9))
        halo.colors = [haloColour.cgColor, haloColour.withAlphaComponent(0).cgColor]
        let coreColour = contrast.withAlphaComponent(next.dark ? 0.9 : 0.6)
        core.colors = [coreColour.cgColor, coreColour.withAlphaComponent(0).cgColor]
        lightHost.isHidden = !next.moving
        guard next.moving, window != nil else {
            halo.removeAnimation(forKey: Self.animationKey)
            core.removeAnimation(forKey: Self.animationKey)
            return
        }
        // The light starts at the top-left corner and runs clockwise, at an even
        // speed round the whole perimeter.
        let travel = CAKeyframeAnimation(keyPath: "position")
        travel.path = Self.clockwise(inset, radius: radius)
        travel.calculationMode = .paced
        travel.duration = Self.period
        travel.repeatCount = .infinity
        travel.isRemovedOnCompletion = false
        for gradient in [halo, core] {
            if !force, gradient.animation(forKey: Self.animationKey) != nil,
               (gradient.animation(forKey: Self.animationKey) as? CAKeyframeAnimation)?.path == travel.path {
                continue
            }
            travel.beginTime = InboxOwnershipClock.beginTime(period: Self.period, phase: next.phase, in: gradient)
            gradient.add(travel, forKey: Self.animationKey)
        }
    }

    /// The rounded rectangle, starting at its top-left and running clockwise on
    /// screen (y grows down in this flipped view).
    static func clockwise(_ rect: NSRect, radius r: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r), radius: r)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r), radius: r)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + r, y: rect.minY), radius: r)
        path.closeSubpath()
        return path
    }

    var isMovingForQA: Bool { !isHidden && !lightHost.isHidden && halo.animation(forKey: Self.animationKey) != nil }
}

// MARK: - Shimmer

/// Working text: the label underneath is drawn muted, and this overlay — a twin
/// of it in full contrast — shows through a soft band that passes across, like a
/// skeleton loader. The twin is a real `NSTextField` with the label's font, frame
/// and truncation, so the two can never lay their glyphs out differently.
@MainActor
final class InboxShimmerOverlay: NSView {
    static let period: CFTimeInterval = 2
    static let band: CGFloat = 70
    static let animationKey = "ownership.shimmer"

    private let twin = NSTextField(labelWithString: "")
    private let mask = CAGradientLayer()
    private var shown: (text: String, width: CGFloat, phase: Double)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        twin.lineBreakMode = .byTruncatingTail
        twin.cell?.truncatesLastVisibleLine = true
        addSubview(twin)
        applyTokens()
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        mask.locations = [0, 0.5, 1]
        layer?.mask = mask
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let shown { animate(shown, force: true) }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }
    /// The band is the label at full strength: the primary text token.
    private func applyTokens() { twin.textColor = TextToken.textPrimary.color.nsColor(in: self) }

    /// Cover `label` (a sibling, same superview) and run the band across its
    /// text; `phase` nil hides the overlay.
    func cover(_ label: NSTextField, phase: Double?) {
        guard let phase, !label.isHidden, !label.stringValue.isEmpty else {
            isHidden = true
            shown = nil
            mask.removeAnimation(forKey: Self.animationKey)
            return
        }
        isHidden = false
        frame = label.frame
        twin.frame = bounds
        twin.font = label.font
        twin.alignment = label.alignment
        twin.lineBreakMode = label.lineBreakMode
        twin.stringValue = label.stringValue
        applyTokens()
        twin.alphaValue = label.alphaValue
        let font = label.font ?? .token(.body)
        let width = min(bounds.width, ceil((label.stringValue as NSString).size(withAttributes: [.font: font]).width))
        animate((label.stringValue, width, phase), force: false)
    }

    private func animate(_ next: (text: String, width: CGFloat, phase: Double), force: Bool) {
        let unchanged = shown.map { $0 == next } ?? false
        shown = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.bounds = CGRect(x: 0, y: 0, width: Self.band, height: max(1, bounds.height))
        mask.position = CGPoint(x: -Self.band, y: bounds.midY)
        CATransaction.commit()
        guard window != nil else { return }
        if unchanged, !force, mask.animation(forKey: Self.animationKey) != nil { return }
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -Self.band / 2
        sweep.toValue = next.width + Self.band / 2
        sweep.duration = Self.period
        sweep.repeatCount = .infinity
        sweep.isRemovedOnCompletion = false
        sweep.beginTime = InboxOwnershipClock.beginTime(period: Self.period, phase: next.phase, in: mask)
        mask.add(sweep, forKey: Self.animationKey)
    }

    var isShimmeringForQA: Bool { !isHidden && mask.animation(forKey: Self.animationKey) != nil }
}

// MARK: - Three dots

/// A working subagent's mark: three small dots that brighten one after another.
@MainActor
final class InboxPulseDotsView: NSView {
    static let period: CFTimeInterval = 1.2
    static let size = NSSize(width: 12, height: 6)
    static let animationKey = "ownership.dots"
    private let dots = [CALayer(), CALayer(), CALayer()]
    private var phase: Double?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for dot in dots {
            dot.bounds = CGRect(x: 0, y: 0, width: 2.6, height: 2.6)
            dot.cornerRadius = 1.3
            dot.opacity = 0.35
            layer?.addSublayer(dot)
        }
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let phase { start(phase, force: true) }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, dot) in dots.enumerated() {
            dot.position = CGPoint(x: bounds.midX - 4 + CGFloat(index) * 4, y: bounds.midY)
        }
        CATransaction.commit()
    }

    func show(colour: NSColor, phase: Double?, reducedMotion: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for dot in dots { dot.backgroundColor = colour.cgColor }
        CATransaction.commit()
        guard let phase else {
            isHidden = true
            self.phase = nil
            for dot in dots { dot.removeAnimation(forKey: Self.animationKey) }
            return
        }
        isHidden = false
        guard !reducedMotion else {
            self.phase = nil
            for dot in dots {
                dot.removeAnimation(forKey: Self.animationKey)
                dot.opacity = 0.6
            }
            return
        }
        start(phase, force: false)
    }

    private func start(_ phase: Double, force: Bool) {
        if !force, self.phase == phase, dots[0].animation(forKey: Self.animationKey) != nil { return }
        self.phase = phase
        guard window != nil else { return }
        for (index, dot) in dots.enumerated() {
            // Each dot peaks a third of the loop after the one before it.
            let peak = (Double(index) + 0.5) / 3
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [0.28, 0.28, 0.9, 0.28, 0.28]
            pulse.keyTimes = [0, max(0, peak - 1.0 / 6), peak, min(1, peak + 1.0 / 6), 1].map { NSNumber(value: $0) }
            pulse.duration = Self.period
            pulse.repeatCount = .infinity
            pulse.isRemovedOnCompletion = false
            pulse.beginTime = InboxOwnershipClock.beginTime(period: Self.period, phase: phase, in: dot)
            dot.add(pulse, forKey: Self.animationKey)
        }
    }

    var isPulsingForQA: Bool { !isHidden && dots[0].animation(forKey: Self.animationKey) != nil }
}

// MARK: - The stem

/// How one lane of the tree crosses a row.
enum InboxStemLane: Hashable {
    case none
    /// The lane begins in this row, under the glyph that heads it.
    case start
    /// The lane passes straight through.
    case through
    /// The lane's last row: its foot rounds off toward the row.
    case foot
}

/// One very quiet stem from under a lead's fold glyph to its last direct
/// subagent, its foot rounding off a quarter of the way toward that row; a
/// subagent with helpers heads a second, shorter one. Painted per row slice.
@MainActor
final class InboxOwnershipStemView: NSView {
    struct Lane: Equatable {
        var kind: InboxStemLane
        var x: CGFloat
        /// Where a `.start` lane begins, y down in this view.
        var top: CGFloat
        /// Where a `.foot` lane turns, y down in this view.
        var turn: CGFloat
        /// How far right the foot reaches.
        var reach: CGFloat
    }

    static let footRadius: CGFloat = 4
    var lanes: [Lane] = [] { didSet { if lanes != oldValue { needsDisplay = true } } }
    var colour: NSColor = .clear { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        colour.setStroke()
        let r = Self.footRadius
        for lane in lanes where lane.kind != .none {
            let path = NSBezierPath()
            let top = lane.kind == .start ? lane.top : 0
            path.move(to: NSPoint(x: lane.x, y: top))
            if lane.kind == .foot {
                path.line(to: NSPoint(x: lane.x, y: lane.turn - r))
                path.appendArc(withCenter: NSPoint(x: lane.x + r, y: lane.turn - r), radius: r,
                               startAngle: 180, endAngle: 90, clockwise: true)
                path.line(to: NSPoint(x: lane.x + max(r + 1, lane.reach), y: lane.turn))
            } else {
                path.line(to: NSPoint(x: lane.x, y: bounds.height))
            }
            path.lineWidth = 0.75
            path.lineCapStyle = .round
            path.stroke()
        }
    }
}

// MARK: - A row's slice of its lead's card

/// Where one table row sits in its lead's card. Derived by the list in one pass
/// (`AgentInboxView.ownershipSlices`) and handed to the row, for the reason
/// `InboxNesting` is: which rows are drawn above and below it is a fact about
/// the LIST, and the slices of one card must agree with each other.
struct InboxOwnershipSlice: Equatable {
    /// From the top of the group's first cell down to this cell's top.
    var offset: CGFloat = 0
    /// From the top of the group's first cell to the bottom of its last.
    var groupHeight: CGFloat = 0
    var continuesAbove = false
    var continuesBelow = false
    /// The lead's title column, in card x: where a subagent row's content starts.
    var titleLeading: CGFloat = 12
    var leadLane: InboxStemLane = .none
    var helperLane: InboxStemLane = .none
    /// The card's light, while anything in it works and nothing in it asks.
    var sweepPhase: Double?
    var sweepColour: String?
    /// The lead only: what someone in its card is asking the user.
    var raisedAsk: String?
}

/// The three things every row of a lead's card paints behind its content: its
/// strip of the solid card, its slice of the moving border, and the stem.
@MainActor
struct InboxOwnershipChrome {
    let sheet: InboxGroupBackgroundView
    let sweep = InboxSweepBorderView()
    let stem = InboxOwnershipStemView()

    /// The card's inner padding, and where the fold control sits in it, so that
    /// its glyph — the head of the stem — is centred `pad + 7` in.
    nonisolated static let pad: CGFloat = 12
    static let foldX: CGFloat = pad + 7 - InboxSwarmFoldControl.glyphCentreX
    static var laneX: CGFloat { foldX + InboxSwarmFoldControl.glyphCentreX }
    /// A subagent row's height; the table's row spacing makes its pitch 24 pt.
    static let subagentHeight: CGFloat = 20
    /// The room under a card's last subagent, inside the card.
    static let footPad: CGFloat = 6
    /// How far an open lead's row overlaps its first subagent, so the first row
    /// sits right under the lead's second line.
    static let headOverlap: CGFloat = 6
    /// A helper's content, one step in from its parent subagent's.
    static let helperIndent: CGFloat = 14

    /// Where the lead's title starts in its card: after the fold glyph and its
    /// count, then the identity dot. Subagent rows line up under it.
    static func titleLeading(foldWidth: CGFloat, hasDot: Bool) -> CGFloat {
        var x = foldWidth > 0 ? foldX + foldWidth + 6 : pad
        if hasDot { x += AgentInboxView.identityDotSide + CGFloat(Space.m) }
        return x
    }

    func install(in view: NSView) {
        for child in [sweep, stem] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = true
            view.addSubview(child)
        }
    }

    /// Lay the three out in a cell of `bounds`. `laneTop` is where the lead's
    /// stem begins (its row only); `rowMid` is the subagent line's centre.
    func layout(_ slice: InboxOwnershipSlice, bounds: NSRect, gutter: CGFloat, gap: CGFloat,
                spacing: CGFloat, laneTop: CGFloat, rowMid: CGFloat) {
        let bleed = spacing / 2
        let top = slice.continuesAbove ? -bleed : 0
        let bottom = bounds.height + (slice.continuesBelow ? bleed : 0)
        let clip = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bottom - top))
        let card = NSRect(x: gutter, y: -slice.offset + gap / 2,
                          width: max(0, bounds.width - gutter * 2), height: max(0, slice.groupHeight - gap))

        sheet.clipsToBounds = false
        sheet.frame = clip
        let strip = card.intersection(clip)
        sheet.ownershipStrip = strip.isEmpty ? nil : (
            strip.offsetBy(dx: 0, dy: -top),
            card.minY >= clip.minY - 0.5, card.maxY <= clip.maxY + 0.5)

        sweep.frame = clip
        sweep.show(card: slice.sweepPhase == nil ? nil : card.offsetBy(dx: 0, dy: -top),
                   colour: slice.sweepColour.map(AgentInboxView.identityDotColour(named:)),
                   phase: slice.sweepPhase ?? 0,
                   moving: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)

        stem.frame = clip
        let dark = stem.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        stem.colour = TextToken.textSecondary.color.nsColor(in: stem).withAlphaComponent(dark ? 0.14 : 0.16)
        let leadX = gutter + Self.laneX
        let helperX = gutter + slice.titleLeading + 5
        stem.lanes = [
            .init(kind: slice.leadLane, x: leadX, top: laneTop - top, turn: rowMid - top,
                  reach: (gutter + slice.titleLeading - 1 - leadX) * 0.25),
            .init(kind: slice.helperLane, x: helperX, top: rowMid + 6 - top, turn: rowMid - top, reach: 0),
        ]
    }
}

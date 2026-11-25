import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// A lead agent's plan: a line in the composer's status row that opens the plan.

/// The plan as ONE list. Plan steps own their helpers; helpers the
/// plan does not name are `strays`. Built from `LeadPlanPresentation`'s
/// `entries` / `tail` (the model owns ordering, linking and ageing).
struct LeadPlanDrawerModel: Equatable {
    enum Phase: Equatable { case needsYou, failed, working, idle, done }
    struct Helper: Equatable {
        var id: AgentID? = nil
        var name: String
        var model: String
        var phase: Phase
        /// Seconds since it finished or failed.
        var endedAgo: TimeInterval? = nil
        /// A failure too old to ask about: folded, never "needs you".
        var stale: Bool = false
    }
    enum Owner: Equatable { case lead, you, helpers([Helper]), unstarted(String), unavailable }
    struct Step: Equatable {
        var title: String
        var owner: Owner
        var done: Bool = false
    }
    var steps: [Step]
    var strays: [Helper] = []
    var decision: String? = nil
    var options: [String] = []
    var collapsed: Bool = false
}

extension LeadPlanDrawerModel {
    init(from p: LeadPlanPresentation, now: Date = Date()) {
        func helper(_ h: LeadPlanPresentation.Helper) -> Helper {
            let phase: Phase
            switch h.bucket {
            case .needsYou: phase = h.state == .failed ? .failed : .needsYou
            case .working: phase = .working
            case .waiting: phase = .idle
            case .finished: phase = h.state == .failed ? .failed : .done
            }
            let ended = (h.bucket == .finished || phase == .failed) ? h.endedAt.map { max(0, now.timeIntervalSince($0)) } : nil
            return Helper(id: h.id, name: h.name, model: h.model, phase: phase, endedAgo: ended,
                          stale: h.bucket == .finished && h.state == .failed)
        }
        let steps = p.entries.map { e -> Step in
            let owner: Owner
            switch e.ownerKind {
            case .lead: owner = .lead
            case .you: owner = .you
            case .unavailable: owner = .unavailable
            case .unstarted: owner = .unstarted(e.ownerLabel)
            case .helpers: owner = e.helpers.isEmpty ? .unavailable : .helpers(e.helpers.map(helper))
            }
            return Step(title: e.title, owner: owner, done: e.state == .done && e.ownerKind != .helpers)
        }
        self.init(steps: steps, strays: p.tail.map(helper), decision: p.decision, options: p.options, collapsed: p.collapsed)
    }

    enum StepPhase: Equatable { case needsYou, failed, working, idle, todo, done }
    func phase(of step: Step) -> StepPhase {
        if step.done { return .done }
        switch step.owner {
        case .you: return .needsYou
        case .lead, .unstarted, .unavailable: return .todo
        case .helpers(let all):
            let live = all.filter { !$0.stale }
            if live.contains(where: { $0.phase == .needsYou }) { return .needsYou }
            if live.contains(where: { $0.phase == .failed }) { return .failed }
            if live.contains(where: { $0.phase == .working }) { return .working }
            if !all.isEmpty, all.allSatisfy({ $0.phase == .done }) { return .done }
            if live.contains(where: { $0.phase == .idle }) { return .idle }
            return .todo
        }
    }
}

/// The resting line in the status row, beside the context meter: a pile of up
/// to four helper orbs (the most pressing in front) and one sentence, "0 of 5 ·
/// 1 running · 2 idle · 2 need you". A click opens the whole plan in a
/// `ChoicePopoverController` panel above it; a second click, Escape or a click
/// elsewhere closes it. Everything updates in place.
@MainActor
final class AgentLeadPlanView: NSView, NativeVectorDrawnContent {
    private(set) var presentation: LeadPlanPresentation?
    private(set) var glance: PlanGlance?
    /// The lead this line belongs to; its own orb marks the steps it owns.
    var leadID: AgentID?
    /// Clicking a helper's row in the popover reveals that helper.
    var onRevealOwner: ((AgentID) -> Void)?
    /// Clicking an answer chip.
    var onChoose: ((String) -> Void)?
    /// The view the popover anchors to. The status row, not this line: the
    /// line's width follows its sentence, and a panel closes when its anchor's
    /// frame changes.
    weak var anchorHost: NSView?
    /// Where the popover may go, in screen coordinates: the tile.
    var placementFrame: (() -> NSRect?)?
    /// The line's width changed or it appeared or went: the row re-fits.
    var onWidthChange: (() -> Void)?
    /// The most the row can give the line; it drops words to fit.
    var widthBudget: CGFloat = .greatestFiniteMagnitude {
        didSet { if widthBudget != oldValue { refit() } }
    }
    var zoom: AgentPageZoom = .default {
        didSet {
            guard zoom != oldValue else { return }
            orbs.forEach { $0.removeFromSuperview() }
            orbs = []
            rebuildPile()
            refit()
        }
    }
    let popover = ChoicePopoverController()
    private(set) var list: PlanListView?
    private var orbs: [PlanOrbView] = []
    private var parts: [(String, PlanGlance.Phase?)] = []
    /// Set while the popover is closing in this pass of the event loop: the
    /// panel's own monitor closes it on a mouse-down before that same click
    /// reaches the line, and that click must not reopen it.
    private var closedThisTurn = false
    /// Checks only: every change the line actually takes.
    var qaOnUpdate: ((LeadPlanPresentation?) -> Void)?

    var isOpen: Bool { popover.isPresented }
    var sentence: String { parts.map(\.0).joined(separator: " · ") }

    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        popover.animatesPresentation = true
        isHidden = true
        trackFill()
    }

    /// The line's whole section, its hover fill included: one control for
    /// hover and click, so there is no dead gap between orbs, words, pill and
    /// chevron, nor in the fill's pad past the line's own bounds.
    private var fillRect: NSRect { bounds.insetBy(dx: -PlanMetrics.s(Space.s, zoom), dy: 0) }

    /// One area for the whole section, orbs included: crossing from orb to
    /// orb, or orb to words, never leaves it.
    private func trackFill() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: fillRect, options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { trackFill() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        return fillRect.contains(convert(point, from: superview)) ? self : nil
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var drawnContentFingerprint: Int {
        var hash = Hasher()
        hash.combine(zoom)
        hash.combine(sentence)
        hash.combine(isOpen)
        for o in orbs { hash.combine("\(o.kind)"); hash.combine("\(o.phase)") }
        hash.combine(lineHovered)
        hash.combine(isPressed)
        hash.combine(hoveredOrb.map { "\($0.kind)" })
        return hash.finalize()
    }

    func update(_ value: LeadPlanPresentation?) {
        guard value != presentation else { return }
        defer { qaOnUpdate?(value) }
        presentation = value
        glance = value.flatMap { p in leadID.map { PlanGlance(LeadPlanDrawerModel(from: p), leadID: $0) } }
        let hide = glance == nil
        if hide, isOpen { popover.dismiss() }
        rebuildPile()
        refit()
        if isHidden != hide { isHidden = hide; onWidthChange?() }
        if let glance, let list, isOpen {
            list.apply(glance)
            popover.resizeContent(to: list.preferredSize(maxWidth: popoverMaxWidth))
        }
    }

    // MARK: The line

    private var orbSide: CGFloat { PlanMetrics.orbSide(zoom) }
    private var overlap: CGFloat { PlanMetrics.s(Space.s, zoom) + PlanMetrics.s(Space.xs, zoom) }
    private var gap: CGFloat { PlanMetrics.s(Space.m, zoom) }
    private var font: NSFont { PlanMetrics.meta(zoom) }
    private var separator: String { " · " }
    private var pileWidth: CGFloat { orbs.isEmpty ? 0 : CGFloat(orbs.count) * (orbSide - overlap) + overlap }
    private var chevronSize: CGFloat { PlanMetrics.s(Space.l, zoom) }

    /// Up to four helpers, most pressing first; ties keep creation order, so
    /// the pile only changes when a helper's state does.
    private func rebuildPile() {
        guard let glance else { orbs.forEach { $0.removeFromSuperview() }; orbs = []; return }
        let ranked = PlanGlance.pressing(glance.helpers.filter { $0.phase != .done }).prefix(4)
        var next: [PlanOrbView] = []
        for h in ranked {
            let kind = PlanOrbView.Kind.agent(h.id, working: true)
            if let o = orbs.first(where: { $0.kind == kind }) { o.phase = h.phase; next.append(o) }
            else {
                let o = PlanOrbView(kind: kind, side: orbSide, phase: h.phase)
                addSubview(o)
                if window != nil { o.show(now: Date()) }
                next.append(o)
            }
        }
        for o in orbs where !next.contains(where: { $0 === o }) { o.removeFromSuperview() }
        orbs = next
        if let h = hoveredOrb, !orbs.contains(where: { $0 === h }) { setHoveredOrb(nil) }
        needsLayout = true
    }

    private func candidates(_ g: PlanGlance) -> [[(String, PlanGlance.Phase?)]] {
        let progress: (String, PlanGlance.Phase?) = ("\(g.done) of \(g.steps.count)", nil)
        let attention: (String, PlanGlance.Phase?)? = g.needsYou > 0 ? ("\(g.needsYou) need\(g.needsYou == 1 ? "s" : "") you", .needsYou) : nil
        var full = g.hasPlan ? [progress] : []
        if g.working > 0 { full.append(("\(g.working) running", nil)) }
        if g.idle > 0 { full.append(("\(g.idle) idle", nil)) }
        if let attention { full.append(attention) }
        // Narrower: what needs him survives longest, then progress.
        guard g.hasPlan else {
            // No plan: what needs him, else the helpers' own count.
            let count: (String, PlanGlance.Phase?) = ("\(g.helpers.count) helper\(g.helpers.count == 1 ? "" : "s")", nil)
            return [full.isEmpty ? [count] : full, [attention ?? count]]
        }
        return [full, [progress] + (attention.map { [$0] } ?? []), [attention ?? progress]]
    }

    private func width(of p: [(String, PlanGlance.Phase?)]) -> CGFloat {
        var w = pileWidth + (orbs.isEmpty ? 0 : gap)
        for (i, (s, phase)) in p.enumerated() {
            w += phase == nil ? PlanInk.width(s, font) : PlanInk.pillWidth(s, font: font, zoom: zoom)
            if i > 0 { w += PlanInk.width(separator, font) }
        }
        return ceil(w + gap + chevronSize)
    }

    private func refit() {
        let before = intrinsicContentSize.width
        if let g = glance {
            let all = candidates(g)
            parts = all.first { width(of: $0) <= widthBudget } ?? all.last ?? []
        } else { parts = [] }
        setAccessibilityLabel(glance.map { "Plan: " + candidates($0)[0].map(\.0).joined(separator: ", ") })
        setAccessibilityValue(isOpen ? "open" : "closed")
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
        if intrinsicContentSize.width != before { onWidthChange?() }
    }

    /// The width it takes at its fullest, which the row charges first.
    var naturalWidth: CGFloat { glance.map { width(of: candidates($0)[0]) } ?? 0 }

    override var intrinsicContentSize: NSSize {
        // The status row's content height (its 28 pt less 4 pt insets).
        NSSize(width: parts.isEmpty ? 0 : width(of: parts),
               height: AgentCompactStatusRowView.preferredHeight(zoom: zoom) - 2 * PlanMetrics.s(Space.s, zoom))
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for o in orbs {
            o.frame = NSRect(x: x, y: (bounds.height - orbSide) / 2, width: orbSide, height: orbSide)
            x += orbSide - overlap
        }
        stackPile()
    }

    private func stackPile() {
        // The front orb, the most pressing, draws on top; a hovered orb comes
        // in front of everything.
        let hovered = hoveredOrb.flatMap { h in orbs.firstIndex { $0 === h } }
        func above(_ a: Int, _ b: Int) -> Bool { a == hovered ? true : b == hovered ? false : a < b }
        for (i, o) in orbs.enumerated() {
            o.layer?.zPosition = CGFloat(i == hovered ? orbs.count + 1 : orbs.count - i)
            // ...and cuts a clean, even gap out of each neighbour behind it, as
            // the inbox swarm's front card does (`SwarmPose.knockout`).
            let fronts = [i - 1, i + 1].filter { orbs.indices.contains($0) && above($0, i) }
                .map { orbs[$0].frame.offsetBy(dx: -o.frame.minX, dy: -o.frame.minY) }
            o.cut(by: fronts, gap: PlanMetrics.s(SwarmPose.knockout, zoom))
        }
    }

    /// Checks only: the pile, front first.
    var qaPile: [PlanOrbView] { orbs }

    override func draw(_ dirtyRect: NSRect) {
        let theme = effectiveTokenTheme
        // Pressed is a step stronger than hover; while its plan is open the line
        // keeps the hover fill. At rest it paints nothing.
        if let fill = lineFill(theme) {
            fill.setFill()
            let r = CGFloat(zoom.scaled(CornerStyle.current.radius(CornerRole.card.base)))
            NSBezierPath(roundedRect: fillRect, xRadius: r, yRadius: r).fill()
        }
        let start = pileWidth + (orbs.isEmpty ? 0 : gap)
        let mid = bounds.midY
        var x = start
        for (i, (s, phase)) in parts.enumerated() {
            if i > 0 { x += PlanInk.text(separator, x: x, midY: mid, maxX: bounds.maxX, font: font, color: PlanInk.secondary(theme)) }
            if let phase { x += PlanInk.pill(s, phase, x: x, midY: mid, font: font, theme: theme, zoom: zoom) }
            else { x += PlanInk.text(s, x: x, midY: mid, maxX: bounds.maxX, font: font, color: PlanInk.secondary(theme)) }
        }
        guard let chevron = CanvasSymbolImage.image(named: isOpen ? "chevron.down" : "chevron.up",
                                                    pointSize: PlanMetrics.s(10, zoom), weight: .semibold) else { return }
        let tinted = NSImage(size: chevron.size, flipped: false) { rect in
            chevron.draw(in: rect)
            PlanInk.secondary(theme).set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let r = NSRect(x: bounds.maxX - chevronSize + (chevronSize - chevron.size.width) / 2,
                       y: (mid - chevron.size.height / 2).rounded(), width: chevron.size.width, height: chevron.size.height)
        tinted.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyTokens() }
    func applyTokens() { needsDisplay = true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Hover

    /// The fill's step now: pressed, then open or hovered, else nothing.
    var qaLineFillRole: SidebarSurfaceRole? { isPressed ? .active : (isOpen || lineHovered) ? .hover : nil }
    /// The hovered orb, which is the front of the pile while it is hovered.
    private(set) var hoveredOrb: PlanOrbView?
    /// Checks only: the line's one tracking area, and how many times the
    /// pointer entered and left it.
    var qaTrackingArea: NSTrackingArea? { hoverArea }
    private(set) var qaCrossings = (entered: 0, exited: 0)
    /// Checks only: the orb card's panel and view while it is up.
    var qaTipPanel: NSPanel? { tip.panel }
    var qaTipView: PlanOrbTipView? { tip.view }

    private var hoverArea: NSTrackingArea?
    private var lineHovered = false
    private var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }
    /// 0 at rest, 1 hovered: the hover fill's strength, faded like a sidebar row's.
    @objc dynamic var hoverAmount: CGFloat = 0 { didSet { needsDisplay = true } }
    /// The hovered orb's card, in its own child panel above the orb.
    private let tip = PlanOrbTip()

    /// How much the canvas magnifies this line on screen; 1 off the canvas.
    var canvasScale: CGFloat {
        guard bounds.width > 0 else { return 1 }
        let w = convert(bounds, to: nil).width
        return w > 0 ? w / bounds.width : 1
    }
    /// The card and the plan are drawn at the scale they opened at. Neither
    /// follows a canvas zoom live (the choice popover never has), so both go
    /// when the canvas zooms under them; a hover brings the card back at the
    /// new size.
    private var planeWatch: NSObjectProtocol?
    private var shownScale: CGFloat = 1
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let planeWatch { NotificationCenter.default.removeObserver(planeWatch) }
        planeWatch = nil
        guard window != nil,
              let plane = sequence(first: superview, next: { $0?.superview }).first(where: { $0 is CanvasWorldPlaneView }) ?? nil
        else { return }
        planeWatch = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: plane, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.canvasMoved() }
        }
    }
    private func canvasMoved() {
        guard tip.panel?.isVisible == true || isOpen, abs(canvasScale - shownScale) > 0.001 else { return }
        tip.dismiss(animated: false)
        if isOpen { close() }
    }

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "hoverAmount" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }

    /// The sidebar's hover pill: `textPrimary` at the hover step's strength,
    /// translucent so it reads the same over the status row's chrome; pressed
    /// is the next step up the ladder.
    private func lineFill(_ theme: TokenTheme) -> NSColor? {
        let ink = TextToken.textPrimary.color.nsColor(for: theme)
        if isPressed { return ink.withAlphaComponent(CGFloat(SidebarSurfaceRole.active.emphasisAlpha)) }
        let hover = NSColor(cgColor: AgentInboxCardView.hoverMarkColour(theme: theme)) ?? ink
        if isOpen { return hover }
        return hoverAmount > 0.001 ? hover.withAlphaComponent(hover.alphaComponent * min(1, hoverAmount)) : nil
    }

    override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea === hoverArea else { return super.mouseEntered(with: event) }
        qaCrossings.entered += 1
        setLineHovered(true)
        setHoveredOrb(orb(at: convert(event.locationInWindow, from: nil)))
    }

    private(set) var qaMoves = 0
    override func mouseMoved(with event: NSEvent) {
        qaMoves += 1
        if !lineHovered { setLineHovered(true) }
        setHoveredOrb(orb(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === hoverArea else { return super.mouseExited(with: event) }
        qaCrossings.exited += 1
        isPressed = false
        setLineHovered(false)
        setHoveredOrb(nil)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        isPressed = false
        lineHovered = false
        hoverAmount = 0
        setHoveredOrb(nil)
        tip.dismiss(animated: false)
    }

    private func setLineHovered(_ on: Bool) {
        guard on != lineHovered else { return }
        lineHovered = on
        NSAnimationContext.runAnimationGroup { context in
            context.duration = window == nil ? 0 : AgentInboxCardView.fillFadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().hoverAmount = on ? 1 : 0
        }
    }

    /// The orb under `point`. The hovered one keeps the pointer while it is
    /// still inside it, so the overlap between two orbs never flips back and
    /// forth; otherwise the front-most orb wins.
    private func orb(at point: NSPoint) -> PlanOrbView? {
        func contains(_ o: PlanOrbView) -> Bool { hypot(point.x - o.frame.midX, point.y - o.frame.midY) <= o.frame.width / 2 }
        if let h = hoveredOrb, contains(h) { return h }
        return orbs.first(where: contains)
    }

    private func setHoveredOrb(_ next: PlanOrbView?) {
        guard next !== hoveredOrb else { return }
        hoveredOrb?.setHovered(false)
        hoveredOrb = next
        next?.setHovered(true)
        stackPile()
        showOrbHover()
    }

    private func helper(for orb: PlanOrbView?) -> PlanGlance.Helper? {
        guard case let .agent(id, _)? = orb?.kind else { return nil }
        return glance?.helpers.first { $0.id == id }
    }

    /// The hovered orb's helper, in a card above that orb; none while the
    /// plan is open.
    private func showOrbHover() {
        shownScale = canvasScale
        if !isOpen, let h = helper(for: hoveredOrb), let orb = hoveredOrb { tip.show(h, over: orb, zoom: zoom, scale: canvasScale) }
        else { tip.dismiss(animated: true) }
    }

    /// Anywhere on the section, an orb included, opens or closes the plan;
    /// going to a helper is the plan's own job, from its row.
    override func mouseDown(with event: NSEvent) {
        // The popover's own outside-click handling closed it on this very
        // click: that click was the close.
        tip.dismiss(animated: false)
        if closedThisTurn { return }
        isPressed = true
        toggle()
    }

    override func mouseUp(with event: NSEvent) { isPressed = false }
    override func accessibilityPerformPress() -> Bool { toggle(); return glance != nil }

    func toggle() { if isOpen { close() } else { open() } }

    private var popoverMaxWidth: CGFloat {
        let frame = placementFrame?() ?? window?.frame ?? .zero
        return max(PlanMetrics.s(320, zoom), frame.width - 2 * PlanMetrics.s(Space.xl, zoom))
    }

    func open() {
        guard let glance, window != nil else { return }
        let list = PlanListView(glance, zoom: zoom)
        list.onReveal = { [weak self] id in self?.close(); self?.onRevealOwner?(id) }
        list.onChoose = { [weak self] answer in self?.close(); self?.onChoose?(answer) }
        tip.dismiss(animated: false)
        shownScale = canvasScale
        let surface = PlanPopoverSurfaceView(list)
        surface.onCancel = { [weak self] in self?.close() }
        let size = list.preferredSize(maxWidth: popoverMaxWidth)
        let host = anchorHost ?? self
        let anchor = host === self ? bounds : convert(bounds, to: host)
        self.list = list
        popover.pageZoom = zoom
        popover.presentContent(surface, size: size, anchor: anchor, relativeTo: host, placementFrame: placementFrame?(),
                               takesFocus: true, initialFirstResponder: surface, accessibilityLabel: "Plan",
                               onClose: { [weak self] in self?.didClose() })
        refit()
    }

    func close() { popover.dismiss() }

    private func didClose() {
        closedThisTurn = true
        DispatchQueue.main.async { [weak self] in self?.closedThisTurn = false }
        list = nil
        refit()
    }
}


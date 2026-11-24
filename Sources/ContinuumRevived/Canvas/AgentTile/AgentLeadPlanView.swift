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
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var drawnContentFingerprint: Int {
        var hash = Hasher()
        hash.combine(zoom)
        hash.combine(sentence)
        hash.combine(isOpen)
        for o in orbs { hash.combine("\(o.kind)"); hash.combine("\(o.phase)") }
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

    private static func rank(_ p: PlanGlance.Phase) -> Int {
        switch p { case .needsYou, .failed: 0; case .working: 1; case .idle: 2; default: 3 }
    }

    /// Up to four helpers, most pressing first; ties keep creation order, so
    /// the pile only changes when a helper's state does.
    private func rebuildPile() {
        guard let glance else { orbs.forEach { $0.removeFromSuperview() }; orbs = []; return }
        let ranked = glance.helpers.enumerated().filter { $0.element.phase != .done }
            .sorted { (Self.rank($0.element.phase), $0.offset) < (Self.rank($1.element.phase), $1.offset) }
            .prefix(4).map(\.element)
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
        for (i, o) in orbs.enumerated() {
            o.frame = NSRect(x: x, y: (bounds.height - orbSide) / 2, width: orbSide, height: orbSide)
            x += orbSide - overlap
            // The front orb, the most pressing, draws on top.
            o.layer?.zPosition = CGFloat(orbs.count - i)
            // ...and cuts a clean, even gap out of the one behind it, as the
            // inbox swarm's front card does (`SwarmPose.knockout`).
            o.cut(by: i == 0 ? nil : orbs[i - 1].frame.offsetBy(dx: -o.frame.minX, dy: -o.frame.minY),
                  gap: PlanMetrics.s(SwarmPose.knockout, zoom))
        }
    }

    /// Checks only: the pile, front first.
    var qaPile: [PlanOrbView] { orbs }

    override func draw(_ dirtyRect: NSRect) {
        let theme = effectiveTokenTheme
        if isOpen {
            // While its plan is open the line wears the row hover fill: full and even.
            AgentSurfaceRole.rowHover.color.nsColor(for: theme).setFill()
            let r = PlanMetrics.s(Space.s, zoom)
            NSBezierPath(roundedRect: bounds.insetBy(dx: -r, dy: 0), xRadius: r, yRadius: r).fill()
        }
        var x = pileWidth + (orbs.isEmpty ? 0 : gap)
        let mid = bounds.midY
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

    override func mouseDown(with event: NSEvent) {
        // The popover's own outside-click handling closed it on this very
        // click: that click was the close.
        if closedThisTurn { return }
        toggle()
    }
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

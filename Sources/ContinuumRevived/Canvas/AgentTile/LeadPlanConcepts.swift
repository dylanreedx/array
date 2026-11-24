import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import QuartzCore

// Design round 2026-11-23: four ways to show a lead's plan without a drawer.
// QA render only (`--lead-plan-concepts-render`); nothing here is mounted in
// production. Every concept reads one `PlanGlance`, built from the same
// `LeadPlanDrawerModel` the shipped drawer draws.

/// What every concept shows, derived once from the drawer model.
struct PlanGlance {
    enum Phase: Equatable { case needsYou, failed, working, idle, done, todo }
    enum Owner: Equatable { case lead, you, helper(Int), unassigned }
    struct Helper: Equatable {
        var id: AgentID
        var name: String
        var model: String
        var phase: Phase
        var ago: TimeInterval?
        /// The plan step this helper owns (index), nil for a helper the plan does not name.
        var step: Int?
    }
    struct Step: Equatable {
        var title: String
        var owner: Owner
        var phase: Phase
    }
    var leadID: AgentID
    var leadName: String
    var steps: [Step] = []
    /// Live helpers: plan-linked first in plan order, then the rest by creation.
    /// Old failures are not here: they are history, not state.
    var helpers: [Helper] = []
    var oldFailures: [Helper] = []
    var decision: String?
    var options: [String] = []

    init(_ m: LeadPlanDrawerModel, leadID: AgentID, leadName: String) {
        self.leadID = leadID
        self.leadName = leadName
        decision = m.decision
        options = m.options
        func phase(_ p: LeadPlanDrawerModel.Phase) -> Phase {
            switch p { case .needsYou: .needsYou; case .failed: .failed; case .working: .working; case .idle: .idle; case .done: .done }
        }
        for (i, s) in m.steps.enumerated() {
            let stepPhase: Phase
            switch m.phase(of: s) {
            case .needsYou: stepPhase = .needsYou
            case .failed: stepPhase = .failed
            case .working: stepPhase = .working
            case .idle: stepPhase = .idle
            case .done: stepPhase = .done
            case .todo: stepPhase = .todo
            }
            var owner: Owner = .unassigned
            switch s.owner {
            case .lead: owner = .lead
            case .you: owner = .you
            case .unstarted, .unavailable: owner = .unassigned
            case .helpers(let hs):
                for h in hs {
                    guard let id = h.id else { continue }
                    if h.stale { oldFailures.append(.init(id: id, name: h.name, model: h.model, phase: .failed, ago: h.endedAgo, step: i)); continue }
                    if case .unassigned = owner { owner = .helper(helpers.count) }
                    helpers.append(.init(id: id, name: h.name, model: h.model, phase: phase(h.phase), ago: h.endedAgo, step: i))
                }
            }
            steps.append(.init(title: s.title, owner: owner, phase: stepPhase))
        }
        // A step Dylan owns needs him only once every step before it is done;
        // until then it is simply his, later in the plan.
        for i in steps.indices where steps[i].owner == .you && steps[i].phase == .needsYou {
            if steps[..<i].contains(where: { $0.phase != .done }) { steps[i].phase = .todo }
        }
        for h in m.strays {
            guard let id = h.id else { continue }
            if h.stale { oldFailures.append(.init(id: id, name: h.name, model: h.model, phase: .failed, ago: h.endedAgo)); continue }
            helpers.append(.init(id: id, name: h.name, model: h.model, phase: phase(h.phase), ago: h.endedAgo))
        }
    }

    var done: Int { steps.filter { $0.phase == .done }.count }
    var working: Int { helpers.filter { $0.phase == .working }.count }
    var idle: Int { helpers.filter { $0.phase == .idle }.count }
    var finished: Int { helpers.filter { $0.phase == .done }.count }
    /// Everything that is waiting on Dylan: the lead's decision, helpers that
    /// need him or failed recently, and undone steps he owns.
    var needsYou: Int {
        (decision == nil ? 0 : 1) + helpers.filter { $0.phase == .needsYou || $0.phase == .failed }.count
            + steps.filter { $0.owner == .you && $0.phase == .needsYou }.count
    }
    /// The step in progress or most urgent, for one-line summaries.
    var current: Int? {
        steps.firstIndex { $0.phase == .needsYou || $0.phase == .failed }
            ?? steps.firstIndex { $0.phase == .working } ?? steps.firstIndex { $0.phase != .done }
    }
    /// Helpers the plan does not name, as one quiet line.
    var alsoText: String? {
        let strays = helpers.filter { $0.step == nil }
        var parts: [String] = []
        let w = strays.filter { $0.phase == .working }.count, i = strays.filter { $0.phase == .idle }.count
        let d = strays.filter { $0.phase == .done }
        if w > 0 { parts.append("\(w) running") }
        if i > 0 { parts.append("\(i) idle") }
        if !d.isEmpty { parts.append("\(d.count) done" + (Self.age(d.compactMap(\.ago).min()).map { " " + $0 } ?? "")) }
        if !oldFailures.isEmpty {
            let days = oldFailures.compactMap(\.ago).map { Int($0 / 86400) }
            let range = days.isEmpty ? "" : (days.min() == days.max() ? " \(days.min()!)d ago" : " \(days.min()!)–\(days.max()!)d ago")
            parts.append("\(oldFailures.count) failed\(range)")
        }
        return parts.isEmpty ? nil : "Also · " + parts.joined(separator: " · ")
    }

    static func age(_ seconds: TimeInterval?) -> String? {
        guard let s = seconds, s >= 60 else { return nil }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86400 { return "\(Int(s / 3600))h ago" }
        return "\(Int(s / 86400))d ago"
    }
    static func word(_ p: Phase, ago: TimeInterval? = nil) -> String? {
        switch p {
        case .needsYou: "Needs you"
        case .failed: ["Failed", age(ago)].compactMap { $0 }.joined(separator: " · ")
        case .working: "Running"
        case .idle: "Idle"
        case .done: "Done"
        case .todo: nil
        }
    }
    func ownerWord(_ s: Step) -> String {
        switch s.owner {
        case .lead: "Lead"
        case .you: "You"
        case .unassigned: "Not started"
        case .helper(let i): helpers[i].model
        }
    }
    func ago(of s: Step) -> TimeInterval? { if case .helper(let i) = s.owner { helpers[i].ago } else { nil } }
}

// MARK: - Shared drawing

/// Metrics taken from the sidebar's helper rows (`AgentInbox96CellView`), the
/// reference surface: a 14 pt icon, a 13 pt regular title 8 pt after it, and
/// 11 pt medium secondary metadata. Nothing here adds a style of its own.
@MainActor
enum PlanMetrics {
    /// The sidebar helper title (`AgentInbox96CellView.subagentTitleFont`).
    static var title: NSFont { AgentInbox96CellView.subagentTitleFont }
    static var meta: NSFont { .token(.label) }
    /// An orb whose glass is the sidebar helper icon's 14 pt.
    static let orbSide: CGFloat = 14 + 2 * (PlanOrbView.ringGap + 1.5)
    static let titleGap: CGFloat = 8
    static let rowHeight: CGFloat = 26
}

@MainActor
enum PlanInk {
    static func accent(_ p: PlanGlance.Phase) -> AccentToken? {
        switch p {
        case .needsYou: .accentApproval
        case .failed: .accentFailed
        case .working: .accentWorking
        case .done: .accentDone
        case .idle, .todo: nil
        }
    }
    static func ring(_ p: PlanGlance.Phase, theme: TokenTheme) -> NSColor {
        if let a = accent(p) { return a.color.nsColor(for: theme) }
        return (p == .idle ? LineToken.borderStrong : LineToken.border).color.nsColor(for: theme)
    }
    static func primary(_ theme: TokenTheme) -> NSColor { TextToken.textPrimary.color.nsColor(for: theme) }
    static func secondary(_ theme: TokenTheme) -> NSColor { TextToken.textSecondary.color.nsColor(for: theme) }

    /// Text centred on `midY` by its capitals. Returns the drawn width.
    @discardableResult
    static func text(_ s: String, x: CGFloat, midY: CGFloat, maxX: CGFloat, font: NSFont, color: NSColor, alignRight: Bool = false) -> CGFloat {
        guard maxX > x, !s.isEmpty else { return 0 }
        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: p]
        let w = min(ceil((s as NSString).size(withAttributes: attrs).width), maxX - x)
        let baseline = midY + font.capHeight / 2
        let offset = NSLayoutManager().defaultBaselineOffset(for: font)
        let ox = alignRight ? maxX - w : x
        (s as NSString).draw(with: NSRect(x: ox, y: baseline - offset, width: w, height: ceil(offset - font.descender + 2)),
                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        return w
    }
    static func width(_ s: String, _ font: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: font]).width) }

    /// A word on a tinted capsule, the house live-state pill.
    @discardableResult
    static func pill(_ s: String, _ token: AccentToken, x: CGFloat, midY: CGFloat, font: NSFont, theme: TokenTheme, alignRight: Bool = false) -> CGFloat {
        let pad: CGFloat = 7, h: CGFloat = 16
        let w = width(s, font) + 2 * pad
        let ox = alignRight ? x - w : x
        let r = NSRect(x: ox, y: midY - h / 2, width: w, height: h)
        token.color.nsColor(for: theme).withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
        text(s, x: ox + pad, midY: midY, maxX: ox + w - pad + 1, font: font, color: token.color.nsColor(for: theme))
        return w
    }

    /// One rounded cell per plan step, the same track the drawer used.
    @discardableResult
    static func track(_ phases: [PlanGlance.Phase], x: CGFloat, midY: CGFloat, cell: CGFloat = 12, theme: TokenTheme) -> CGFloat {
        let h: CGFloat = 4, gap: CGFloat = 2
        for (i, p) in phases.enumerated() {
            let r = NSRect(x: x + CGFloat(i) * (cell + gap), y: midY - h / 2, width: cell, height: h)
            (accent(p)?.color.nsColor(for: theme) ?? LineToken.border.color.nsColor(for: theme)).setFill()
            NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
        }
        return CGFloat(phases.count) * (cell + gap) - gap
    }
}

// MARK: - The orb

/// A helper (or the lead) as the tile's own Orb: `TileAgentBubbleLayer` around
/// its `CharacterSpriteLayer`, the same renderer as the tile header and the
/// sidebar plate. Its state is one full, even ring around the glass. Done
/// helpers rest dimmed. "You" is a plain plate with a person glyph.
@MainActor
final class PlanOrbView: NSView {
    enum Kind { case agent(AgentID, working: Bool), you }
    let kind: Kind
    let side: CGFloat
    var phase: PlanGlance.Phase { didSet { needsLayout = true } }
    private let sprite = CharacterSpriteLayer()
    private let bubble: TileAgentBubbleLayer
    private let ring = CAShapeLayer()
    private let you = NSImageView()
    private var artFrame: CGRect = .zero
    /// The clear gap between the glass and its ring.
    static let ringGap: CGFloat = 2

    override var isFlipped: Bool { true }

    init(kind: Kind, side: CGFloat, phase: PlanGlance.Phase) {
        self.kind = kind
        self.side = side
        self.phase = phase
        bubble = TileAgentBubbleLayer(sprite: sprite)
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        layer?.masksToBounds = false
        sprite.hostIsFlipped = true
        ring.fillColor = nil
        layer?.addSublayer(bubble)
        layer?.addSublayer(ring)
        if case .you = kind {
            bubble.isHidden = true
            you.image = NSImage(systemSymbolName: "person.fill", accessibilityDescription: "You")?
                .withSymbolConfiguration(.init(pointSize: side * 0.42, weight: .semibold))
            you.imageScaling = .scaleNone
            addSubview(you)
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    func show(now: Date) {
        guard case let .agent(id, working) = kind else { return }
        let controller = AgentCharacterController.shared
        guard let atlas = controller.atlas(for: id.rawValue, appearance: AgentCharacterController.appearance(of: self)) else { return }
        let state: InboxState = switch phase {
        case .working: .working
        case .needsYou: .input
        case .failed: .failed
        default: .ready
        }
        let plan = controller.plan(for: AgentCharacterSnapshot(state: state, allowsMotion: false), now: now)
        sprite.show(plan, sprite: atlas, phase: controller.phase(for: id.rawValue), now: now)
        bubble.setStyle(.orb)
        bubble.setWorking(working && phase == .working, style: controller.workingStyle.rawValue, phase: 0)
        let scale = CGFloat(controller.theme?.scale ?? 1)
        let frame = NSSize(width: CGFloat(atlas.atlas.frameWidth) / scale, height: CGFloat(atlas.atlas.frameHeight) / scale)
        let typical = max(1, atlas.typicalInkSide / scale)
        let body = CGPoint(x: atlas.bodyCentre.x / scale, y: atlas.bodyCentre.y / scale)
        let glass = side - 2 * (Self.ringGap + 1.5)
        let per = glass * TileAgentBubbleLayer.Plate.artFit / typical
        artFrame = CGRect(x: side / 2 - body.x * per, y: side / 2 - body.y * per,
                          width: frame.width * per, height: frame.height * per)
        bubble.setShown(true)
        applyPalette()
        needsLayout = true
    }

    private func applyPalette() {
        let theme = effectiveTokenTheme
        bubble.apply(TileAgentBubbleLayer.Palette(
            dark: theme != .light,
            tileChrome: SurfaceToken.tileChrome.color.nsColor(for: theme),
            tileBody: SurfaceToken.tileBody.color.nsColor(for: theme),
            textPrimary: TextToken.textPrimary.color.nsColor(for: theme),
            textSecondary: TextToken.textSecondary.color.nsColor(for: theme),
            providerForeground: BrandToken.providerForeground.nsColor(for: theme),
            orbRimColors: AgentIconMaterialToken.orbRimCGColors))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPalette()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let theme = effectiveTokenTheme
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let lw: CGFloat = side >= 24 ? 2 : 1.5
        let glass = bounds.insetBy(dx: Self.ringGap + lw, dy: Self.ringGap + lw)
        bubble.setGeometry(tileRadius: CGFloat(Radius.container), scale: 1)
        bubble.frame = glass
        sprite.frame = artFrame.offsetBy(dx: -glass.minX, dy: -glass.minY)
        ring.frame = bounds
        ring.lineWidth = lw
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: lw / 2, dy: lw / 2), transform: nil)
        ring.strokeColor = PlanInk.ring(phase, theme: theme).cgColor
        layer?.opacity = phase == .done ? 0.55 : 1
        if case .you = kind {
            you.frame = bounds
            you.contentTintColor = TextToken.textSecondary.color.nsColor(for: theme)
            // A neutral plate inside the ring, the same size as an orb's glass.
            layer?.sublayers?.first { $0.name == "youPlate" }?.removeFromSuperlayer()
            let p = CAShapeLayer()
            p.name = "youPlate"
            p.path = CGPath(ellipseIn: glass, transform: nil)
            p.fillColor = SurfaceToken.tileChrome.color.nsColor(for: theme).cgColor
            layer?.insertSublayer(p, at: 0)
        }
        CATransaction.commit()
        sprite.refreshOrientation()
    }
}

/// Builds orbs for a glance: one per helper, the lead's own, and "You".
@MainActor
enum PlanOrbs {
    static func helper(_ h: PlanGlance.Helper, side: CGFloat) -> PlanOrbView {
        PlanOrbView(kind: .agent(h.id, working: true), side: side, phase: h.phase)
    }
    static func owner(_ s: PlanGlance.Step, in g: PlanGlance, side: CGFloat) -> PlanOrbView? {
        switch s.owner {
        case .helper(let i): return PlanOrbView(kind: .agent(g.helpers[i].id, working: true), side: side, phase: g.helpers[i].phase)
        case .lead: return PlanOrbView(kind: .agent(g.leadID, working: false), side: side, phase: s.phase == .done ? .done : .todo)
        case .you: return PlanOrbView(kind: .you, side: side, phase: s.phase)
        case .unassigned: return nil
        }
    }
}

// MARK: - A · Header orbs

/// The plan in the tile's title bar: a step track and "2/5", then one orb per
/// live helper in plan order, each ringed with its state. Nothing reorders:
/// a ring changes colour in place. Clicking an orb opens that helper's tile.
@MainActor
final class PlanHeaderStripView: NSView {
    let glance: PlanGlance
    private(set) var orbs: [PlanOrbView] = []
    static let orbSide: CGFloat = PlanMetrics.orbSide
    static let maxOrbs = 5
    override var isFlipped: Bool { true }

    init(_ g: PlanGlance) {
        glance = g
        super.init(frame: .zero)
        wantsLayer = true
        for h in g.helpers.filter({ $0.phase != .done }).prefix(Self.maxOrbs) {
            let o = PlanOrbs.helper(h, side: Self.orbSide)
            addSubview(o); orbs.append(o)
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var font: NSFont { .token(.label) }
    private var overflow: Int { max(0, glance.helpers.filter { $0.phase != .done }.count - Self.maxOrbs) }
    private var progress: String { "\(glance.done)/\(glance.steps.count)" }
    private var needs: String? { glance.needsYou > 0 ? "\(glance.needsYou) need\(glance.needsYou == 1 ? "s" : "") you" : nil }
    var preferredWidth: CGFloat {
        let n = CGFloat(orbs.count)
        var w = CGFloat(glance.steps.count) * 10 + 6 + PlanInk.width(progress, .monospacedDigitSystemFont(ofSize: PlanMetrics.meta.pointSize, weight: .medium)) + 12
        w += n * Self.orbSide + max(0, n - 1) * 4
        if overflow > 0 { w += 6 + PlanInk.width("+\(overflow)", font) }
        if let needs { w += 10 + PlanInk.width(needs, font) + 14 }
        return ceil(w)
    }
    func show(now: Date) { orbs.forEach { $0.show(now: now) } }

    override func layout() {
        super.layout()
        var x = CGFloat(glance.steps.count) * 10 + 6 + PlanInk.width(progress, .monospacedDigitSystemFont(ofSize: PlanMetrics.meta.pointSize, weight: .medium)) + 12
        for o in orbs {
            o.frame = NSRect(x: x, y: (bounds.height - Self.orbSide) / 2, width: Self.orbSide, height: Self.orbSide)
            x += Self.orbSide + 4
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let theme = effectiveTokenTheme
        let mid = bounds.midY
        var x: CGFloat = 0
        x += PlanInk.track(glance.steps.map(\.phase), x: x, midY: mid, cell: 8, theme: theme) + 6
        x += PlanInk.text(progress, x: x, midY: mid, maxX: bounds.maxX, font: .monospacedDigitSystemFont(ofSize: PlanMetrics.meta.pointSize, weight: .medium), color: PlanInk.secondary(theme)) + 12
        x += CGFloat(orbs.count) * (Self.orbSide + 4) - 4
        if overflow > 0 { x += 6 + PlanInk.text("+\(overflow)", x: x + 6, midY: mid, maxX: bounds.maxX, font: font, color: PlanInk.secondary(theme)) }
        if let needs { PlanInk.pill(needs, .accentApproval, x: x + 10, midY: mid, font: font, theme: theme) }
    }
}

/// A's click target, drawn open for the still: the hover card an orb opens.
/// It names the step, the helper and its state, and says what a click does.
@MainActor
final class PlanOrbCardView: NSView {
    let helper: PlanGlance.Helper
    let step: PlanGlance.Step?
    let stepNumber: Int?
    override var isFlipped: Bool { true }
    init(helper: PlanGlance.Helper, step: PlanGlance.Step?, stepNumber: Int?) {
        self.helper = helper; self.step = step; self.stepNumber = stepNumber
        super.init(frame: .zero)
        wantsLayer = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    static func size(for h: PlanGlance.Helper, step: PlanGlance.Step?) -> NSSize {
        let label = NSFont.token(.label)
        let stateW = PlanGlance.word(h.phase, ago: h.ago).map { PlanInk.width($0, label) + 14 + 8 } ?? 0
        let w = max(PlanInk.width(step?.title ?? h.name, .token(.title)),
                    stateW + PlanInk.width("\(h.name) · \(h.model)", label),
                    PlanInk.width("Click the orb to open its tile", label))
        return NSSize(width: ceil(w) + 24 + 2, height: 92)
    }
    override func updateLayer() {
        let theme = effectiveTokenTheme
        layer?.applyCorner(.popover)
        layer?.backgroundColor = SurfaceToken.overlay.color.cgColor(for: theme)
        layer?.borderWidth = ChoiceListView.panelBorderWidth
        layer?.borderColor = AgentLineRole.decorativeHairline.color.cgColor(for: theme)
    }
    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let theme = effectiveTokenTheme
        updateLayer()
        let pad: CGFloat = 12
        let label = NSFont.token(.label)
        PlanInk.text(stepNumber.map { "Step \($0)" } ?? "Not in the plan", x: pad, midY: 18, maxX: bounds.width - pad,
                     font: label, color: PlanInk.secondary(theme))
        PlanInk.text(step?.title ?? helper.name, x: pad, midY: 38, maxX: bounds.width - pad, font: .token(.title), color: PlanInk.primary(theme))
        var x = pad
        if let a = PlanInk.accent(helper.phase), let w = PlanGlance.word(helper.phase, ago: helper.ago) {
            x += PlanInk.pill(w, a, x: x, midY: 62, font: label, theme: theme) + 8
        }
        x += PlanInk.text("\(helper.name) · \(helper.model)", x: x, midY: 62, maxX: bounds.width - pad, font: label, color: PlanInk.secondary(theme))
        PlanInk.text("Click the orb to open its tile", x: pad, midY: 80, maxX: bounds.width - pad, font: label, color: PlanInk.secondary(theme))
    }
}

// MARK: - B · Composer status line + popover

/// The plan on the composer's own status line: an orb pile and one sentence.
/// "0 of 5 · 1 running · 1 needs you". It is a button: it opens the plan
/// popover (`ChoicePopoverController.presentContent`).
@MainActor
final class PlanStatusLineView: NSView {
    let glance: PlanGlance
    private(set) var orbs: [PlanOrbView] = []
    static let orbSide: CGFloat = PlanMetrics.orbSide
    static let overlap: CGFloat = 6
    var open = false
    override var isFlipped: Bool { true }
    init(_ g: PlanGlance) {
        glance = g
        super.init(frame: .zero)
        wantsLayer = true
        // Most pressing first so the front orb is the one that matters; the
        // order is fixed by bucket, then creation, so it never shuffles.
        let ranked = g.helpers.filter { $0.phase != .done }.sorted { rank($0.phase) < rank($1.phase) }
        for h in ranked.prefix(4).reversed() {
            let o = PlanOrbs.helper(h, side: Self.orbSide); addSubview(o); orbs.insert(o, at: 0)
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    private func rank(_ p: PlanGlance.Phase) -> Int {
        switch p { case .needsYou, .failed: 0; case .working: 1; case .idle: 2; default: 3 }
    }
    func show(now: Date) { orbs.forEach { $0.show(now: now) } }
    private var pileWidth: CGFloat { orbs.isEmpty ? 0 : CGFloat(orbs.count) * (Self.orbSide - Self.overlap) + Self.overlap }
    private var parts: [(String, AccentToken?)] {
        var out: [(String, AccentToken?)] = [("\(glance.done) of \(glance.steps.count)", nil)]
        if glance.working > 0 { out.append(("\(glance.working) running", nil)) }
        if glance.idle > 0 { out.append(("\(glance.idle) idle", nil)) }
        if glance.needsYou > 0 { out.append(("\(glance.needsYou) need\(glance.needsYou == 1 ? "s" : "") you", .accentApproval)) }
        return out
    }
    var preferredWidth: CGFloat {
        let f = NSFont.token(.label)
        var w = pileWidth + 8
        for (i, (s, a)) in parts.enumerated() { w += PlanInk.width(s, f) + (a == nil ? 0 : 14) + (i == 0 ? 0 : PlanInk.width(" · ", f)) }
        return ceil(w + 6 + 14 + 8)
    }
    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for (i, o) in orbs.enumerated() {
            o.frame = NSRect(x: x, y: (bounds.height - Self.orbSide) / 2, width: Self.orbSide, height: Self.orbSide)
            x += Self.orbSide - Self.overlap
            // The front orb (most pressing) draws on top.
            o.layer?.zPosition = CGFloat(orbs.count - i)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let theme = effectiveTokenTheme
        let f = NSFont.token(.label)
        // A hover/open background: the house control fill, full and even.
        if open {
            AgentSurfaceRole.rowHover.color.nsColor(for: theme).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: -6, dy: 0), xRadius: 6, yRadius: 6).fill()
        }
        var x = pileWidth + 8
        let mid = bounds.midY
        for (i, (s, a)) in parts.enumerated() {
            if i > 0 { x += PlanInk.text(" · ", x: x, midY: mid, maxX: bounds.maxX, font: f, color: PlanInk.secondary(theme)) }
            if let a { x += PlanInk.pill(s, a, x: x, midY: mid, font: f, theme: theme) }
            else { x += PlanInk.text(s, x: x, midY: mid, maxX: bounds.maxX, font: f, color: PlanInk.secondary(theme)) }
        }
        if let chevron = CanvasSymbolImage.image(named: open ? "chevron.down" : "chevron.up", pointSize: 10, weight: .semibold) {
            let tinted = NSImage(size: chevron.size, flipped: false) { rect in
                chevron.draw(in: rect)
                PlanInk.secondary(theme).set()
                rect.fill(using: .sourceAtop)
                return true
            }
            let r = NSRect(x: x + 6, y: (mid - chevron.size.height / 2).rounded(), width: chevron.size.width, height: chevron.size.height)
            tinted.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

/// The plan as one list, for B's popover and C's card: numbered steps with
/// their owner's orb, the owner and a fixed state column; the decision on top
/// with the composer's own answer chips; one "Also" line under it.
@MainActor
final class PlanListView: NSView {
    let glance: PlanGlance
    let showsHeader: Bool
    private(set) var orbs: [PlanOrbView?] = []
    let rail = ComposerReplyOptionRailView(frame: .zero)
    static let rowHeight: CGFloat = PlanMetrics.rowHeight
    /// Title line plus a one-line subheading.
    static let headerHeight: CGFloat = 50
    static let orbSide: CGFloat = PlanMetrics.orbSide
    static let subheading = "Each step and who owns it. Click an orb to open that helper."
    override var isFlipped: Bool { true }
    init(_ g: PlanGlance, showsHeader: Bool = true) {
        glance = g
        self.showsHeader = showsHeader
        super.init(frame: .zero)
        wantsLayer = true
        for s in g.steps {
            let o = PlanOrbs.owner(s, in: g, side: Self.orbSide)
            if let o { addSubview(o) }
            orbs.append(o)
        }
        rail.translatesAutoresizingMaskIntoConstraints = true
        rail.compact = true
        rail.setOptions(g.options.map { AgentReplyOption(label: $0) })
        rail.isHidden = g.options.isEmpty || g.decision == nil
        addSubview(rail)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func show(now: Date) { orbs.forEach { $0?.show(now: now) } }

    private var decisionHeight: CGFloat {
        guard glance.decision != nil else { return 0 }
        return 30 + (rail.isHidden ? 0 : rail.railHeight) + 8
    }
    private var top: CGFloat { (showsHeader ? Self.headerHeight : 6) + decisionHeight }
    var preferredHeight: CGFloat {
        top + CGFloat(glance.steps.count) * Self.rowHeight + (glance.alsoText == nil ? 0 : Self.rowHeight) + 8
    }
    override func layout() {
        super.layout()
        for (i, o) in orbs.enumerated() {
            o?.frame = NSRect(x: 36, y: top + CGFloat(i) * Self.rowHeight + (Self.rowHeight - Self.orbSide) / 2,
                              width: Self.orbSide, height: Self.orbSide)
        }
        rail.frame = NSRect(x: 34, y: (showsHeader ? Self.headerHeight : 6) + 30, width: bounds.width - 46, height: rail.railHeight)
    }
    override func draw(_ dirtyRect: NSRect) {
        let theme = effectiveTokenTheme
        let label = NSFont.token(.label), pad: CGFloat = 12
        if showsHeader {
            let mid: CGFloat = 18
            PlanInk.text(Self.subheading, x: pad, midY: 38, maxX: bounds.width - pad, font: label, color: PlanInk.secondary(theme))
            var x = pad
            x += PlanInk.text("Plan", x: x, midY: mid, maxX: bounds.width, font: .token(.title), color: PlanInk.primary(theme)) + 10
            x += PlanInk.track(glance.steps.map(\.phase), x: x, midY: mid, theme: theme) + 8
            PlanInk.text("\(glance.done) of \(glance.steps.count) done", x: x, midY: mid, maxX: bounds.width - pad, font: label, color: PlanInk.secondary(theme))
            var right = bounds.width - pad
            if glance.working > 0 {
                right -= PlanInk.text("\(glance.working) running", x: pad, midY: mid, maxX: right, font: label, color: PlanInk.secondary(theme), alignRight: true)
            }
            _ = right
        }
        if let d = glance.decision {
            let y = (showsHeader ? Self.headerHeight : 6)
            let box = NSRect(x: 8, y: y, width: bounds.width - 16, height: decisionHeight - 6)
            AccentToken.accentApproval.color.nsColor(for: theme).withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
            let mid = y + 15
            PlanInk.pill("Needs you", .accentApproval, x: pad + 2, midY: mid, font: label, theme: theme)
            PlanInk.text(d, x: pad + 2 + PlanInk.width("Needs you", label) + 14 + 8, midY: mid, maxX: bounds.width - pad,
                         font: label, color: PlanInk.primary(theme))
        }
        let stateColumn: CGFloat = 116
        for (i, s) in glance.steps.enumerated() {
            let mid = top + CGFloat(i) * Self.rowHeight + Self.rowHeight / 2
            PlanInk.text("\(i + 1)", x: pad, midY: mid, maxX: 32, font: .monospacedDigitSystemFont(ofSize: label.pointSize, weight: .medium), color: PlanInk.secondary(theme))
            var right = bounds.width - pad
            let ago = glance.ago(of: s)
            if let w = PlanGlance.word(s.phase, ago: ago) {
                if s.phase == .working || s.phase == .needsYou, let a = PlanInk.accent(s.phase) {
                    PlanInk.pill(w, a, x: right, midY: mid, font: label, theme: theme, alignRight: true)
                } else {
                    let color = s.phase == .failed ? AccentToken.accentFailed.color.nsColor(for: theme) : PlanInk.secondary(theme)
                    PlanInk.text(w, x: right - stateColumn, midY: mid, maxX: right - 7, font: label, color: color, alignRight: true)
                }
            }
            right -= stateColumn + 10
            let owner = glance.ownerWord(s)
            let ow = PlanInk.width(owner, label)
            PlanInk.text(owner, x: right - ow, midY: mid, maxX: right, font: label, color: PlanInk.secondary(theme))
            right -= ow + 12
            PlanInk.text(s.title, x: 36 + Self.orbSide + PlanMetrics.titleGap, midY: mid, maxX: right, font: PlanMetrics.title,
                         color: s.phase == .done ? PlanInk.secondary(theme) : PlanInk.primary(theme))
        }
        if let also = glance.alsoText {
            let mid = top + CGFloat(glance.steps.count) * Self.rowHeight + Self.rowHeight / 2
            PlanInk.text(also, x: 36 + Self.orbSide + PlanMetrics.titleGap, midY: mid, maxX: bounds.width - pad, font: label, color: PlanInk.secondary(theme))
        }
    }
}

/// B's popover surface: the same corner, fill and hairline as every
/// `ChoicePopoverController` panel (`CompletionPopoverContentView.applyTokens`).
@MainActor
final class PlanPopoverSurfaceView: NSView {
    let list: PlanListView
    override var isFlipped: Bool { true }
    init(_ g: PlanGlance) {
        list = PlanListView(g)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(list)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); list.frame = bounds }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyTokens() }
    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.applyCorner(.popover)
        layer?.masksToBounds = true
        layer?.backgroundColor = SurfaceToken.overlay.color.cgColor(for: theme)
        layer?.borderWidth = ChoiceListView.panelBorderWidth
        layer?.borderColor = AgentLineRole.decorativeHairline.color.cgColor(for: theme)
    }
}

// MARK: - C · A card in the transcript

/// The plan as a transcript artifact, pinned at the top of the transcript and
/// rewritten in place. Same anatomy as a plan card: the artifact surface, a
/// full even hairline, the artifact corner. Nothing around the composer.
@MainActor
final class PlanTranscriptCardView: NSView {
    let list: PlanListView
    override var isFlipped: Bool { true }
    init(_ g: PlanGlance) {
        list = PlanListView(g)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(list)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    var preferredHeight: CGFloat { list.preferredHeight }
    override func layout() { super.layout(); list.frame = bounds }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyTokens() }
    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.applyCorner(.artifact)
        layer?.masksToBounds = true
        // The transcript's Changes card: the artifact fill, the artifact
        // corner, no outline.
        layer?.backgroundColor = AgentSurfaceRole.artifact.color.cgColor(for: theme)
        layer?.borderWidth = 0
    }
}

/// The transcript's own surface behind C's pinned card.
@MainActor
final class PlanPinnedBandView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        SurfaceToken.tileBody.color.nsColor(for: effectiveTokenTheme).setFill()
        bounds.fill()
    }
}

// MARK: - D · Satellites on the canvas

/// The plan beside the lead's tile, on the canvas: a spine of step nodes, each
/// the owner's orb with its state ring, the step title and owner beside it.
/// A helper node's line runs on to that helper's own tile. A decision is a
/// callout at the top of the spine with the answer chips.
@MainActor
final class PlanSatelliteView: NSView {
    let glance: PlanGlance
    private(set) var nodes: [PlanOrbView?] = []
    let rail = ComposerReplyOptionRailView(frame: .zero)
    /// World points: where each helper's tile starts, by helper index.
    var helperTileAnchors: [Int: NSPoint] = [:]
    /// Where the lead tile's right edge meets the spine, in this view.
    var leadAnchor: NSPoint = .zero
    static let nodeSide: CGFloat = 30
    static let rowHeight: CGFloat = 58
    static let spineX: CGFloat = 40
    static let labelWidth: CGFloat = 270
    override var isFlipped: Bool { true }
    init(_ g: PlanGlance) {
        glance = g
        super.init(frame: .zero)
        wantsLayer = true
        for s in g.steps {
            let o = PlanOrbs.owner(s, in: g, side: Self.nodeSide)
            if let o { addSubview(o) }
            nodes.append(o)
        }
        rail.translatesAutoresizingMaskIntoConstraints = true
        rail.compact = true
        rail.setOptions(g.options.map { AgentReplyOption(label: $0) })
        rail.isHidden = g.options.isEmpty || g.decision == nil
        addSubview(rail)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func show(now: Date) { nodes.forEach { $0?.show(now: now) } }
    var calloutHeight: CGFloat { glance.decision == nil ? 0 : 92 }
    var top: CGFloat { 16 + calloutHeight }
    func nodeCenter(_ i: Int) -> NSPoint { NSPoint(x: Self.spineX, y: top + CGFloat(i) * Self.rowHeight + Self.nodeSide / 2) }
    override func layout() {
        super.layout()
        for (i, n) in nodes.enumerated() {
            let c = nodeCenter(i)
            n?.frame = NSRect(x: c.x - Self.nodeSide / 2, y: c.y - Self.nodeSide / 2, width: Self.nodeSide, height: Self.nodeSide)
        }
        rail.frame = NSRect(x: 10, y: 58, width: Self.labelWidth + 40, height: rail.railHeight)
    }
    override func draw(_ dirtyRect: NSRect) {
        let theme = effectiveTokenTheme
        let line = LineToken.borderStrong.color.nsColor(for: theme)
        let label = NSFont.token(.label)
        // Lead tile → spine.
        if !glance.steps.isEmpty {
            let p = NSBezierPath()
            p.move(to: leadAnchor)
            p.line(to: NSPoint(x: Self.spineX - 14, y: leadAnchor.y))
            p.line(to: NSPoint(x: Self.spineX - 14, y: nodeCenter(glance.steps.count - 1).y))
            for i in glance.steps.indices {
                let c = nodeCenter(i)
                p.move(to: NSPoint(x: Self.spineX - 14, y: c.y)); p.line(to: NSPoint(x: c.x - Self.nodeSide / 2, y: c.y))
            }
            p.lineWidth = 1
            line.setStroke(); p.stroke()
        }
        // Helper node → its own tile.
        for (i, s) in glance.steps.enumerated() {
            guard case .helper(let h) = s.owner, let anchor = helperTileAnchors[h] else { continue }
            let c = nodeCenter(i)
            let start = NSPoint(x: Self.spineX + Self.labelWidth + 20, y: c.y)
            let p = NSBezierPath()
            p.move(to: start)
            p.curve(to: anchor, controlPoint1: NSPoint(x: start.x + 50, y: start.y), controlPoint2: NSPoint(x: anchor.x - 50, y: anchor.y))
            p.lineWidth = 1.5
            (PlanInk.accent(glance.helpers[h].phase)?.color.nsColor(for: theme) ?? line).withAlphaComponent(0.7).setStroke()
            p.stroke()
        }
        for (i, s) in glance.steps.enumerated() {
            let c = nodeCenter(i)
            let x = c.x + Self.nodeSide / 2 + 10
            PlanInk.text("\(i + 1)  \(s.title)", x: x, midY: c.y - 8, maxX: x + Self.labelWidth, font: PlanMetrics.title,
                         color: s.phase == .done ? PlanInk.secondary(theme) : PlanInk.primary(theme))
            var sx = x
            let owner = glance.ownerWord(s)
            sx += PlanInk.text(owner, x: sx, midY: c.y + 9, maxX: x + Self.labelWidth, font: label, color: PlanInk.secondary(theme))
            if let w = PlanGlance.word(s.phase, ago: glance.ago(of: s)) {
                let color = PlanInk.accent(s.phase).map { $0.color.nsColor(for: theme) } ?? PlanInk.secondary(theme)
                PlanInk.text(" · " + w, x: sx, midY: c.y + 9, maxX: x + Self.labelWidth, font: label, color: color)
            }
        }
        if let also = glance.alsoText, !glance.steps.isEmpty {
            let y = nodeCenter(glance.steps.count - 1).y + Self.rowHeight - 6
            PlanInk.text(also, x: Self.spineX - 14, midY: y, maxX: Self.spineX + Self.labelWidth + 40, font: label, color: PlanInk.secondary(theme))
        }
        if let d = glance.decision {
            let box = NSRect(x: 4, y: 8, width: Self.labelWidth + 60, height: calloutHeight - 12)
            SurfaceToken.overlay.color.nsColor(for: theme).setFill()
            let path = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
            path.fill()
            AccentToken.accentApproval.color.nsColor(for: theme).withAlphaComponent(0.10).setFill(); path.fill()
            AccentToken.accentApproval.color.nsColor(for: theme).withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1; path.stroke()
            PlanInk.pill("Needs you", .accentApproval, x: 14, midY: 26, font: label, theme: theme)
            PlanInk.text(d, x: 14, midY: 46, maxX: box.maxX - 10, font: label, color: PlanInk.primary(theme))
        }
    }
}

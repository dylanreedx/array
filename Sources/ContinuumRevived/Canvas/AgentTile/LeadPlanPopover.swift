import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import QuartzCore

// A lead's plan: one line in the composer's status row (`AgentLeadPlanView`)
// and, on a click, the whole plan in a `ChoicePopoverController` panel
// (`PlanListView`). Both read one `PlanGlance`, built from `LeadPlanDrawerModel`.

/// What the line and the popover show, derived once from the model.
struct PlanGlance: Equatable {
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
    var steps: [Step] = []
    /// Live helpers: plan-linked first in plan order, then the rest by creation.
    /// Old failures are history, not state, and are left out.
    var helpers: [Helper] = []
    var decision: String?
    var options: [String] = []

    init(_ m: LeadPlanDrawerModel, leadID: AgentID) {
        self.leadID = leadID
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
                    guard let id = h.id, !h.stale else { continue }
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
        hasPlan = !m.steps.isEmpty
        for h in m.strays {
            guard let id = h.id, !h.stale else { continue }
            // With no plan, the helpers are the list: one row each, by name.
            let step: Int? = hasPlan ? nil : steps.count
            helpers.append(.init(id: id, name: h.name, model: h.model, phase: phase(h.phase), ago: h.endedAgo, step: step))
            if !hasPlan { steps.append(.init(title: h.name, owner: .helper(helpers.count - 1), phase: phase(h.phase))) }
        }
    }
    /// False when the lead posted no plan: the list is its helpers.
    private(set) var hasPlan = true

    var done: Int { steps.filter { $0.phase == .done }.count }
    var working: Int { helpers.filter { $0.phase == .working }.count }
    var idle: Int { helpers.filter { $0.phase == .idle }.count }
    static func isAttention(_ p: Phase) -> Bool { p == .needsYou || p == .failed }
    /// Helpers the plan does not name.
    var strays: [Helper] { helpers.filter { $0.step == nil } }
    /// What waits on Dylan, counted exactly as the popover marks it: the
    /// decision, each step whose state is Needs you or Failed, and each helper
    /// outside the plan that needs him (an "Also" row).
    var needsYou: Int {
        (decision == nil ? 0 : 1) + steps.filter { Self.isAttention($0.phase) }.count
            + strays.filter { Self.isAttention($0.phase) }.count
    }
    /// Most pressing first, as the line's pile stacks them: needing him or
    /// failed, then running, then idle; ties keep creation order.
    static func pressing(_ hs: [Helper]) -> [Helper] {
        func rank(_ p: Phase) -> Int { switch p { case .needsYou, .failed: 0; case .working: 1; case .idle: 2; default: 3 } }
        return hs.enumerated().sorted { (rank($0.element.phase), $0.offset) < (rank($1.element.phase), $1.offset) }.map(\.element)
    }
    /// Helpers the plan does not name, live ones only (finished work is not
    /// news): the card's "Also" rows, so every helper is a click away.
    var also: [Helper] { hasPlan ? Self.pressing(strays.filter { $0.phase != .done }) : [] }

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
    /// The owner column: a helper's model, "You", or nothing for the lead,
    /// whose own orb already says it.
    func ownerWord(_ s: Step) -> String? {
        switch s.owner {
        case .lead: nil
        case .you: "You"
        case .unassigned: "Not started"
        case .helper(let i): helpers[i].model
        }
    }
    func ago(of s: Step) -> TimeInterval? { if case .helper(let i) = s.owner { helpers[i].ago } else { nil } }
    func helperID(of s: Step) -> AgentID? { if case .helper(let i) = s.owner { helpers[i].id } else { nil } }
}

// MARK: - Shared drawing

/// Metrics from the reference surfaces. Rows follow the sidebar's helper rows
/// (`AgentInbox96CellView`): a 14 pt icon, a 13 pt regular title 8 pt after it,
/// 11 pt medium metadata. Spacing is the `Space` ladder; pills are the status
/// row's (`AgentStatusPillView`). Every length scales with the page zoom.
@MainActor
enum PlanMetrics {
    static func title(_ z: AgentPageZoom) -> NSFont {
        let base = AgentInbox96CellView.subagentTitleFont
        return NSFont.systemFont(ofSize: CGFloat(z.scaled(Double(base.pointSize))), weight: .regular)
    }
    static func meta(_ z: AgentPageZoom) -> NSFont { .token(.label, zoom: z) }
    /// An orb whose glass is the sidebar helper icon's 14 pt.
    static func orbSide(_ z: AgentPageZoom) -> CGFloat {
        CGFloat(z.scaled(14)) + 2 * (PlanOrbView.ringGap + 1.5)
    }
    static func s(_ v: Double, _ z: AgentPageZoom) -> CGFloat { CGFloat(z.scaled(v)) }
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

    static func pillWidth(_ s: String, font: NSFont, zoom: AgentPageZoom) -> CGFloat {
        width(s, font) + 2 * PlanMetrics.s(Space.m, zoom)
    }
    /// A state word on a capsule, ONE way for every state: the status row
    /// pill's height and insets; a live state tints it with its accent, a
    /// resting one (Idle, Done) takes the status pill's own neutral fill.
    @discardableResult
    static func pill(_ s: String, _ phase: PlanGlance.Phase, x: CGFloat, midY: CGFloat, font: NSFont, theme: TokenTheme,
                     zoom: AgentPageZoom, alignRight: Bool = false) -> CGFloat {
        let pad = PlanMetrics.s(Space.m, zoom), h = AgentStatusPillView.preferredHeight(zoom: zoom)
        let w = pillWidth(s, font: font, zoom: zoom)
        let ox = alignRight ? x - w : x
        let r = NSRect(x: ox, y: midY - h / 2, width: w, height: h)
        let ink: NSColor
        if let a = accent(phase), phase != .done {
            ink = a.color.nsColor(for: theme)
            ink.withAlphaComponent(0.16).setFill()
        } else {
            ink = secondary(theme)
            SurfaceToken.cardMessage.color.nsColor(for: theme).setFill()
        }
        NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
        text(s, x: ox + pad, midY: midY, maxX: ox + w - pad + 1, font: font, color: ink)
        return w
    }
}

// MARK: - The orb

/// A helper (or the lead) as the tile's own Orb: `TileAgentBubbleLayer` around
/// its `CharacterSpriteLayer`, the same renderer as the tile header and the
/// sidebar plate. Its state is one full, even ring around the glass. Done
/// helpers rest dimmed. "You" is a plain plate with a person glyph.
@MainActor
final class PlanOrbView: NSView {
    enum Kind: Equatable { case agent(AgentID, working: Bool), you }
    let kind: Kind
    let side: CGFloat
    var phase: PlanGlance.Phase { didSet { if phase != oldValue { show(now: Date()) } } }
    private let sprite = CharacterSpriteLayer()
    private let bubble: TileAgentBubbleLayer
    private let ring = CAShapeLayer()
    private let plate = CAShapeLayer()
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
        if case .you = kind {
            layer?.addSublayer(plate)
            you.image = NSImage(systemSymbolName: "person.fill", accessibilityDescription: "You")?
                .withSymbolConfiguration(.init(pointSize: side * 0.42, weight: .semibold))
            you.imageScaling = .scaleNone
            addSubview(you)
        } else {
            layer?.addSublayer(bubble)
        }
        layer?.addSublayer(ring)
        setAccessibilityElement(false)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    /// The pointer is on this orb: the tile header's own orb hover (the glass
    /// fades in and swells a little).
    func setHovered(_ hovered: Bool) { bubble.setHovered(hovered) }
    var qaIsHovered: Bool { bubble.isHovered }

    /// In a pile: everything except the orbs in front (`fronts`, in this orb's
    /// own coordinates) grown by `gap`, so each front orb's whole circle and a
    /// thin gap of canvas show and this one is clipped along that arc.
    func cut(by fronts: [NSRect], gap: CGFloat) {
        guard let layer else { return }
        guard !fronts.isEmpty else { layer.mask = nil; return }
        let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.fillRule = .evenOdd
        mask.frame = bounds
        let path = CGMutablePath()
        path.addRect(bounds.insetBy(dx: -side, dy: -side))
        for front in fronts { path.addEllipse(in: front.insetBy(dx: -gap, dy: -gap)) }
        mask.path = path
        CATransaction.commit()
        layer.mask = mask
    }

    func show(now: Date) {
        needsLayout = true
        guard case let .agent(id, working) = kind else { return }
        let controller = AgentCharacterController.shared
        guard let atlas = controller.atlas(for: id.rawValue, appearance: AgentCharacterController.appearance(of: self)) else { return }
        let state: InboxState = switch phase {
        case .working: .working
        case .needsYou: .input
        case .failed: .failed
        default: .ready
        }
        // Still art: the line and the popover are read at a glance, not watched.
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { show(now: Date()) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        show(now: Date())
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
            plate.frame = bounds
            plate.path = CGPath(ellipseIn: glass, transform: nil)
            plate.fillColor = SurfaceToken.tileChrome.color.nsColor(for: theme).cgColor
        }
        CATransaction.commit()
        sprite.refreshOrientation()
    }
}

@MainActor
enum PlanOrbs {
    /// What a step's orb shows, so a row keeps its orb while the owner stays.
    static func kind(_ s: PlanGlance.Step, in g: PlanGlance) -> PlanOrbView.Kind? {
        switch s.owner {
        case .helper(let i): .agent(g.helpers[i].id, working: true)
        case .lead: .agent(g.leadID, working: false)
        case .you: .you
        case .unassigned: nil
        }
    }
    static func phase(_ s: PlanGlance.Step, in g: PlanGlance) -> PlanGlance.Phase {
        switch s.owner {
        case .helper(let i): g.helpers[i].phase
        case .lead: s.phase == .done ? .done : .todo
        default: s.phase
        }
    }
}

// MARK: - Orb hover

/// What a hovered orb says about its helper: the plan's state word and age, in
/// the plan's state ink, with the sidebar's own state glyph (the ledger's:
/// a raised hand for needing you, a warning for a failure, a check for done;
/// working and idle carry none, the sidebar shows its gyro or nothing there).
@MainActor
enum PlanOrbHover {
    static func symbol(_ p: PlanGlance.Phase) -> String? {
        switch p {
        case .needsYou: "questionmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .done: "checkmark.circle"
        case .working, .idle, .todo: nil
        }
    }
    static func stateText(_ h: PlanGlance.Helper) -> String { PlanGlance.word(h.phase, ago: h.ago) ?? "" }
    static func stateInk(_ p: PlanGlance.Phase, theme: TokenTheme) -> NSColor {
        PlanInk.accent(p).map { $0.color.nsColor(for: theme) } ?? PlanInk.secondary(theme)
    }
    static func glyph(_ p: PlanGlance.Phase, pointSize: CGFloat, ink: NSColor) -> NSImage? {
        guard let name = symbol(p), let image = CanvasSymbolImage.image(named: name, pointSize: pointSize, weight: .semibold) else { return nil }
        return NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            ink.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

/// Orb hover: a small card centred above the hovered orb. A child panel
/// of the tile's window, placed in screen coordinates, so neither the tile nor
/// the canvas can clip or misplace it; it wears the choice popover's surface
/// and edge and never takes the mouse.
@MainActor
final class PlanOrbTip {
    private(set) var panel: NSPanel?
    private(set) var view: PlanOrbTipView?
    private var dwell: DispatchWorkItem?
    /// The status row's account card and the sidebar's agent card wait this long.
    static let dwellTime: TimeInterval = 0.15

    /// `scale` is the canvas's magnification of the line on screen: the card
    /// is drawn at the size the line and its orbs are, not at 100%.
    func show(_ h: PlanGlance.Helper, over orb: NSView, zoom: AgentPageZoom, scale: CGFloat) {
        dwell?.cancel()
        dwell = nil
        // Already up: it follows the pointer from orb to orb at once.
        if panel?.isVisible == true { place(h, over: orb, zoom: zoom, scale: scale); return }
        let work = DispatchWorkItem { [weak self, weak orb] in
            MainActor.assumeIsolated { if let orb { self?.place(h, over: orb, zoom: zoom, scale: scale) } }
        }
        dwell = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwellTime, execute: work)
    }

    func dismiss(animated: Bool) {
        dwell?.cancel()
        dwell = nil
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func place(_ h: PlanGlance.Helper, over orb: NSView, zoom: AgentPageZoom, scale: CGFloat) {
        dwell = nil
        guard let window = orb.window else { return }
        let view = self.view ?? PlanOrbTipView()
        self.view = view
        view.appearance = window.effectiveAppearance
        view.apply(h, zoom: zoom, scale: scale)
        let size = view.scaledSize
        let panel = self.panel ?? {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .popUpMenu
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.transient, .moveToActiveSpace]
            p.contentView = ChoicePanelShadowView(surface: view)
            p.setAccessibilityElement(false)
            return p
        }()
        self.panel = panel
        panel.appearance = window.effectiveAppearance
        let anchor = window.convertToScreen(orb.convert(orb.bounds, to: nil))
        let gap = PlanMetrics.s(Space.xs, zoom) * scale
        var frame = NSRect(x: (anchor.midX - size.width / 2).rounded(), y: (anchor.maxY + gap).rounded(),
                           width: size.width, height: size.height)
        if let screen = window.screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - size.width)
            if frame.maxY > screen.maxY { frame.origin.y = anchor.minY - gap - size.height }
        }
        let margin = ChoicePanelShadowView.margin
        panel.setFrame(frame.insetBy(dx: -margin, dy: -margin), display: true)
        panel.contentView?.needsLayout = true
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }
}

/// The tip's surface: the choice popover's overlay fill, hairline and corner,
/// the helper's name and its state on two caption lines.
@MainActor
final class PlanOrbTipView: NSView {
    private(set) var helper: PlanGlance.Helper?
    private var zoom: AgentPageZoom = .default
    /// The canvas's magnification. The card is laid out and drawn at the plan
    /// line's own metrics and its bounds are scaled by this, exactly as the
    /// canvas scales the tile: type, padding, corner, glyph and edge all
    /// shrink and grow together, and text keeps its 100% layout.
    private(set) var scale: CGFloat = 1
    override var isFlipped: Bool { true }
    private var font: NSFont { .token(.caption, zoom: zoom) }
    private var padH: CGFloat { PlanMetrics.s(Space.m, zoom) }
    private var padV: CGFloat { PlanMetrics.s(Space.s, zoom) }
    private var lineGap: CGFloat { PlanMetrics.s(Space.xs, zoom) }
    private var maxText: CGFloat { PlanMetrics.s(220, zoom) }
    private var lineHeight: CGFloat { ceil(font.ascender - font.descender) }
    private var radius: CGFloat { CGFloat(zoom.scaled(CornerStyle.current.radius(CornerRole.popover.base))) }
    /// The caption as it lands on screen.
    var qaFontSize: CGFloat { font.pointSize * scale }

    /// On screen, the card is its 100% size times the canvas scale.
    var scaledSize: NSSize {
        let size = intrinsicContentSize
        return NSSize(width: (size.width * scale).rounded(.up), height: (size.height * scale).rounded(.up))
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard scale > 0 else { return }
        setBoundsSize(NSSize(width: newSize.width / scale, height: newSize.height / scale))
    }

    func apply(_ h: PlanGlance.Helper, zoom: AgentPageZoom, scale: CGFloat) {
        helper = h
        self.zoom = zoom
        self.scale = scale
        wantsLayer = true
        layer?.cornerRadius = radius * scale
        invalidateIntrinsicContentSize()
        setFrameSize(frame.size)
        needsDisplay = true
    }

    var qaLines: [String] { helper.map { [$0.name, PlanOrbHover.stateText($0)] } ?? [] }
    var qaSymbol: String? { helper.flatMap { PlanOrbHover.symbol($0.phase) } }

    private var glyphSide: CGFloat { font.pointSize }

    override var intrinsicContentSize: NSSize {
        guard let h = helper else { return .zero }
        let state = (PlanOrbHover.symbol(h.phase) == nil ? 0 : glyphSide + lineGap) + PlanInk.width(PlanOrbHover.stateText(h), font)
        let w = min(maxText, max(PlanInk.width(h.name, font), state))
        return NSSize(width: ceil(w + 2 * padH), height: ceil(2 * lineHeight + lineGap + 2 * padV))
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let h = helper else { return }
        let theme = effectiveTokenTheme
        let edge = ChoiceListView.panelBorderWidth
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: edge / 2, dy: edge / 2), xRadius: radius, yRadius: radius)
        SurfaceToken.overlay.color.nsColor(for: theme).setFill()
        shape.fill()
        AgentLineRole.decorativeHairline.color.nsColor(for: theme).setStroke()
        shape.lineWidth = edge
        shape.stroke()
        let maxX = bounds.maxX - padH
        let first = padV + lineHeight / 2, second = first + lineHeight + lineGap
        PlanInk.text(h.name, x: padH, midY: first, maxX: maxX, font: font, color: PlanInk.primary(theme))
        let ink = PlanOrbHover.stateInk(h.phase, theme: theme)
        var x = padH
        if let glyph = PlanOrbHover.glyph(h.phase, pointSize: glyphSide, ink: ink) {
            glyph.draw(in: NSRect(x: x, y: (second - glyph.size.height / 2).rounded(), width: glyph.size.width, height: glyph.size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += glyph.size.width + lineGap
        }
        PlanInk.text(PlanOrbHover.stateText(h), x: x, midY: second, maxX: maxX, font: font, color: ink)
    }
}

// MARK: - The popover

/// The plan in the popover: a title with "n of m done", the lead's decision
/// with the composer's own answer chips, then one row per step: number, the
/// owner's orb, the step, the owner, and its state as a pill. Updated in place:
/// a row keeps its orb while its owner stays, and a state change recolours it.
@MainActor
final class PlanListView: NSView {
    private(set) var glance: PlanGlance
    private(set) var zoom: AgentPageZoom
    private(set) var orbs: [PlanOrbView?] = []
    /// The "Also" rows' orbs, one per shown unlinked helper.
    private(set) var alsoOrbs: [PlanOrbView] = []
    let rail = ComposerReplyOptionRailView(frame: .zero)
    var onReveal: ((AgentID) -> Void)?
    var onChoose: ((String) -> Void)?
    override var isFlipped: Bool { true }

    init(_ g: PlanGlance, zoom: AgentPageZoom) {
        glance = g
        self.zoom = zoom
        super.init(frame: .zero)
        wantsLayer = true
        rail.translatesAutoresizingMaskIntoConstraints = true
        rail.compact = true
        rail.applyPageZoom(zoom)
        rail.onSelect = { [weak self] answer in self?.onChoose?(answer) }
        addSubview(rail)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect], owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Plan")
        apply(g)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func apply(_ g: PlanGlance) {
        let oldOptions = glance.options, oldDecision = glance.decision
        glance = g
        hovered = nil
        var next: [PlanOrbView?] = []
        for (i, s) in g.steps.enumerated() {
            let kind = PlanOrbs.kind(s, in: g)
            if i < orbs.count, let o = orbs[i], o.kind == kind {
                o.phase = PlanOrbs.phase(s, in: g)
                next.append(o)
            } else if let kind {
                let o = PlanOrbView(kind: kind, side: PlanMetrics.orbSide(zoom), phase: PlanOrbs.phase(s, in: g))
                addSubview(o)
                if window != nil { o.show(now: Date()) }
                next.append(o)
            } else {
                next.append(nil)
            }
        }
        for (i, o) in orbs.enumerated() where o != nil && (i >= next.count || next[i] !== o) { o?.removeFromSuperview() }
        orbs = next
        var nextAlso: [PlanOrbView] = []
        for h in alsoShown {
            let kind = PlanOrbView.Kind.agent(h.id, working: true)
            if let o = alsoOrbs.first(where: { $0.kind == kind }) { o.phase = h.phase; nextAlso.append(o); continue }
            let o = PlanOrbView(kind: kind, side: PlanMetrics.orbSide(zoom), phase: h.phase)
            addSubview(o)
            if window != nil { o.show(now: Date()) }
            nextAlso.append(o)
        }
        for o in alsoOrbs where !nextAlso.contains(where: { $0 === o }) { o.removeFromSuperview() }
        alsoOrbs = nextAlso
        if rail.qaOptions.isEmpty || oldOptions != g.options || oldDecision != g.decision {
            rail.setOptions(g.decision == nil ? [] : g.options.map { AgentReplyOption(label: $0) })
        }
        rail.isHidden = g.decision == nil || g.options.isEmpty
        setAccessibilityHelp((g.steps.enumerated().map { i, s in
            ["\(i + 1). \(s.title)", g.ownerWord(s), PlanGlance.word(s.phase, ago: g.ago(of: s))].compactMap { $0 }.joined(separator: ", ")
        } + g.also.map { "Also: \($0.name), \(PlanOrbHover.stateText($0))" }).joined(separator: "; "))
        needsLayout = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // Metrics: the popover's inset and row are one step up the `Space` ladder
    // from the sidebar row's (`Space.l` → `Space.xl`; a row is its 24 pt line
    // plus `Space.m` of air).
    private var pad: CGFloat { PlanMetrics.s(Space.xl, zoom) }
    private var rowHeight: CGFloat { PlanMetrics.s(Space.xxl + Space.m, zoom) }
    private var headerHeight: CGFloat { PlanMetrics.s(Space.xxl, zoom) }
    private var orbX: CGFloat { pad + PlanMetrics.s(Space.xl, zoom) }
    private var titleX: CGFloat { orbX + PlanMetrics.orbSide(zoom) + PlanMetrics.s(Space.m, zoom) }
    private var decisionLineHeight: CGFloat { PlanMetrics.s(Space.xxl, zoom) }
    private var decisionHeight: CGFloat {
        guard glance.decision != nil else { return 0 }
        let m = PlanMetrics.s(Space.m, zoom)
        return m + decisionLineHeight + (rail.isHidden ? 0 : rail.railHeight) + m
    }
    private var bandRect: NSRect {
        NSRect(x: PlanMetrics.s(Space.m, zoom), y: pad + headerHeight + PlanMetrics.s(Space.s, zoom),
               width: bounds.width - 2 * PlanMetrics.s(Space.m, zoom), height: decisionHeight)
    }
    private var rowsTop: CGFloat {
        pad + headerHeight + PlanMetrics.s(Space.s, zoom) + (glance.decision == nil ? 0 : decisionHeight + PlanMetrics.s(Space.s, zoom))
    }
    private var questionX: CGFloat {
        pad + PlanInk.pillWidth("Needs you", font: PlanMetrics.meta(zoom), zoom: zoom) + PlanMetrics.s(Space.m, zoom)
    }
    private var ownerWidth: CGFloat {
        glance.steps.compactMap { glance.ownerWord($0) }.map { PlanInk.width($0, PlanMetrics.meta(zoom)) }.max() ?? 0
    }
    /// At least as wide as "Needs you", so a state change between the short
    /// words never moves the owner column.
    private var stateWidth: CGFloat {
        let meta = PlanMetrics.meta(zoom)
        return (glance.steps.compactMap { PlanGlance.word($0.phase, ago: glance.ago(of: $0)) }
            + alsoShown.map(PlanOrbHover.stateText)
            + ["Needs you"]).map { PlanInk.pillWidth($0, font: meta, zoom: zoom) }.max() ?? 0
    }

    // The "Also" section: a heading, then one row per unlinked helper with the
    // step rows' metrics, capped at six; the rest fold into an "N more" row
    // that opens the lead, whose sidebar entry lists every helper.
    static let alsoCap = 6
    private var alsoShown: [PlanGlance.Helper] {
        let a = glance.also
        return a.count > Self.alsoCap ? Array(a.prefix(Self.alsoCap - 1)) : a
    }
    private var alsoMore: Int { glance.also.count - alsoShown.count }
    private var alsoHeadHeight: CGFloat { glance.also.isEmpty ? 0 : PlanMetrics.s(Space.xl, zoom) }
    private var alsoTop: CGFloat { rowsTop + CGFloat(glance.steps.count) * rowHeight }
    /// The `j`th "Also" row; `alsoShown.count` is the "N more" row.
    func alsoRowRect(_ j: Int) -> NSRect {
        NSRect(x: 0, y: alsoTop + alsoHeadHeight + CGFloat(j) * rowHeight, width: bounds.width, height: rowHeight)
    }
    var qaAlsoNames: [String] { alsoShown.map(\.name) }
    var qaAlsoMore: Int { alsoMore }
    /// The owner column's right edge, for the steadiness witness.
    var ownerColumnRight: CGFloat { bounds.width - pad - stateWidth - PlanMetrics.s(Space.l, zoom) }

    /// The size the popover asks for: wide enough for the longest step at its
    /// natural width, between a floor and `maxWidth`.
    func preferredSize(maxWidth: CGFloat) -> NSSize {
        let meta = PlanMetrics.meta(zoom)
        let titles = (glance.steps.map(\.title) + alsoShown.map(\.name)).map { PlanInk.width($0, PlanMetrics.title(zoom)) }.max() ?? 0
        let gap = PlanMetrics.s(Space.l, zoom)
        var w = titleX + titles + gap + ownerWidth + gap + stateWidth + pad
        if let d = glance.decision { w = max(w, questionX + PlanInk.width(d, meta) + pad) }
        w = min(max(w, PlanMetrics.s(360, zoom)), maxWidth)
        var h = rowsTop + CGFloat(glance.steps.count) * rowHeight
        h += alsoHeadHeight + CGFloat(alsoShown.count + (alsoMore > 0 ? 1 : 0)) * rowHeight
        return NSSize(width: ceil(w), height: ceil(h + PlanMetrics.s(Space.m, zoom)))
    }

    func rowRect(_ i: Int) -> NSRect {
        NSRect(x: 0, y: rowsTop + CGFloat(i) * rowHeight, width: bounds.width, height: rowHeight)
    }
    func orbFrame(_ i: Int) -> NSRect? { i < orbs.count ? orbs[i]?.frame : nil }
    var chipRailFrame: NSRect { rail.frame }
    var questionTextX: CGFloat { questionX }

    override func layout() {
        super.layout()
        let side = PlanMetrics.orbSide(zoom)
        for (i, o) in orbs.enumerated() {
            let r = rowRect(i)
            o?.frame = NSRect(x: orbX, y: r.midY - side / 2, width: side, height: side)
        }
        for (j, o) in alsoOrbs.enumerated() {
            let r = alsoRowRect(j)
            o.frame = NSRect(x: orbX, y: r.midY - side / 2, width: side, height: side)
        }
        let band = bandRect, m = PlanMetrics.s(Space.m, zoom)
        // The chips start where the question's text starts.
        rail.frame = NSRect(x: questionX, y: band.minY + m + decisionLineHeight,
                            width: max(0, band.maxX - m - questionX), height: rail.railHeight)
    }

    override func resetCursorRects() {
        for (i, s) in glance.steps.enumerated() where glance.helperID(of: s) != nil { addCursorRect(rowRect(i), cursor: .pointingHand) }
        for j in 0..<(alsoShown.count + (alsoMore > 0 ? 1 : 0)) { addCursorRect(alsoRowRect(j), cursor: .pointingHand) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A row that goes somewhere: a helper's step, an "Also" helper, or the
    /// "N more" row, which opens the lead.
    private struct Target: Equatable { var rect: NSRect; var id: AgentID }
    /// The row under the pointer: a whole row reveals its helper, so the
    /// whole row takes the choice list's row hover.
    private var hovered: Target? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private func target(at p: NSPoint) -> Target? {
        for (i, s) in glance.steps.enumerated() where rowRect(i).contains(p) {
            return glance.helperID(of: s).map { Target(rect: rowRect(i), id: $0) }
        }
        for (j, h) in alsoShown.enumerated() where alsoRowRect(j).contains(p) { return Target(rect: alsoRowRect(j), id: h.id) }
        if alsoMore > 0, alsoRowRect(alsoShown.count).contains(p) { return Target(rect: alsoRowRect(alsoShown.count), id: glance.leadID) }
        return nil
    }
    override func mouseEntered(with event: NSEvent) { hovered = target(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { hovered = target(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseDown(with event: NSEvent) {
        if let t = target(at: convert(event.locationInWindow, from: nil)) { onReveal?(t.id) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = effectiveTokenTheme
        let meta = PlanMetrics.meta(zoom)
        let headerMid = pad + headerHeight / 2
        PlanInk.text(glance.hasPlan ? "Plan" : "Helpers", x: pad, midY: headerMid, maxX: bounds.width - pad, font: .token(.title, zoom: zoom), color: PlanInk.primary(theme))
        PlanInk.text("\(glance.done) of \(glance.steps.count) done", x: pad, midY: headerMid, maxX: bounds.width - pad,
                     font: meta, color: PlanInk.secondary(theme), alignRight: true)
        if let d = glance.decision {
            let band = bandRect
            // The decision band: a full, even tint of its state; no edge.
            AccentToken.accentApproval.color.nsColor(for: theme).withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: band, xRadius: CGFloat(Radius.card), yRadius: CGFloat(Radius.card)).fill()
            let mid = band.minY + PlanMetrics.s(Space.m, zoom) + decisionLineHeight / 2
            PlanInk.pill("Needs you", .needsYou, x: pad, midY: mid, font: meta, theme: theme, zoom: zoom)
            PlanInk.text(d, x: questionX, midY: mid, maxX: band.maxX - PlanMetrics.s(Space.m, zoom), font: meta, color: PlanInk.primary(theme))
        }
        if let r = hovered?.rect {
            AgentSurfaceRole.rowHover.color.nsColor(for: theme).setFill()
            let corner = CGFloat(zoom.scaled(CornerStyle.current.radius(CornerRole.card.base)))
            NSBezierPath(roundedRect: r.insetBy(dx: PlanMetrics.s(Space.s, zoom), dy: 0), xRadius: corner, yRadius: corner).fill()
        }
        let gap = PlanMetrics.s(Space.l, zoom)
        let stateLeft = bounds.width - pad - stateWidth
        let ownerRight = stateLeft - gap
        for (i, s) in glance.steps.enumerated() {
            let mid = rowRect(i).midY
            PlanInk.text("\(i + 1)", x: pad, midY: mid, maxX: orbX, font: .monospacedDigitSystemFont(ofSize: meta.pointSize, weight: .medium),
                         color: PlanInk.secondary(theme))
            if let w = PlanGlance.word(s.phase, ago: glance.ago(of: s)) {
                PlanInk.pill(w, s.phase, x: bounds.width - pad, midY: mid, font: meta, theme: theme, zoom: zoom, alignRight: true)
            }
            var titleMax = ownerRight
            if let owner = glance.ownerWord(s) {
                let ow = PlanInk.width(owner, meta)
                PlanInk.text(owner, x: ownerRight - ow, midY: mid, maxX: ownerRight, font: meta, color: PlanInk.secondary(theme))
                titleMax = ownerRight - ownerWidth - gap
            }
            PlanInk.text(s.title, x: titleX, midY: mid, maxX: titleMax, font: PlanMetrics.title(zoom),
                         color: s.phase == .done ? PlanInk.secondary(theme) : PlanInk.primary(theme))
        }
        guard !glance.also.isEmpty else { return }
        PlanInk.text("Also", x: titleX, midY: alsoTop + alsoHeadHeight / 2, maxX: bounds.width - pad, font: meta, color: PlanInk.secondary(theme))
        for (j, h) in alsoShown.enumerated() {
            let mid = alsoRowRect(j).midY
            // The state as the line's orb hover says it: the sidebar's glyph and
            // the plan's state ink, right-aligned in the state column.
            let ink = PlanOrbHover.stateInk(h.phase, theme: theme)
            let word = PlanOrbHover.stateText(h)
            var x = bounds.width - pad - PlanInk.width(word, meta)
            PlanInk.text(word, x: x, midY: mid, maxX: bounds.width - pad, font: meta, color: ink)
            if let glyph = PlanOrbHover.glyph(h.phase, pointSize: meta.pointSize, ink: ink) {
                x -= glyph.size.width + PlanMetrics.s(Space.xs, zoom)
                glyph.draw(in: NSRect(x: x, y: (mid - glyph.size.height / 2).rounded(), width: glyph.size.width, height: glyph.size.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            PlanInk.text(h.name, x: titleX, midY: mid, maxX: stateLeft - gap, font: PlanMetrics.title(zoom), color: PlanInk.primary(theme))
        }
        if alsoMore > 0 {
            PlanInk.text("\(alsoMore) more", x: titleX, midY: alsoRowRect(alsoShown.count).midY, maxX: bounds.width - pad,
                         font: meta, color: PlanInk.secondary(theme))
        }
    }
}

/// The popover's surface: the same corner, fill and hairline as every
/// `ChoicePopoverController` panel (`CompletionPopoverContentView.applyTokens`).
@MainActor
final class PlanPopoverSurfaceView: NSView {
    let list: PlanListView
    var onCancel: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(_ list: PlanListView) {
        self.list = list
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(list)
        applyTokens()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); list.frame = bounds }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyTokens() }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.applyCorner(.popover)
        layer?.masksToBounds = true
        layer?.backgroundColor = SurfaceToken.overlay.color.cgColor(for: theme)
        layer?.borderWidth = ChoiceListView.panelBorderWidth
        layer?.borderColor = AgentLineRole.decorativeHairline.color.cgColor(for: theme)
        list.needsDisplay = true
    }
}

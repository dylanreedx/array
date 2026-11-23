import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// Plan drawer redesign round (2026-11-23). `ARRAY_LEAD_PLAN_DRAWER` =
/// `checklist` | `track` | `triage` is a QA override only; unset keeps the
/// shipped drawer until Dylan picks one.
enum LeadPlanDrawerDirection: String, CaseIterable {
    case shipped, checklist, track, triage

    @MainActor static var current: LeadPlanDrawerDirection = {
        ProcessInfo.processInfo.environment["ARRAY_LEAD_PLAN_DRAWER"].flatMap(LeadPlanDrawerDirection.init(rawValue:)) ?? .shipped
    }()
}

/// What the redesigned drawer draws: ONE list. Plan steps own their helpers;
/// helpers the plan does not name are `strays`. The model side owns ordering,
/// linking and ageing (`stale`); the view only reads them. Until that model
/// lands, `init(adapting:)` derives an approximation from the shipped
/// `LeadPlanPresentation`.
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
    /// Interim bridge from the shipped presentation (sections and display
    /// strings), so the override works live before the model is joined.
    init(adapting p: LeadPlanPresentation) {
        var steps: [Step] = [], strays: [Helper] = []
        var inRoster = false
        func phase(_ s: LeadPlanPresentation.State) -> Phase {
            switch s {
            case .needsYou: return .needsYou
            case .failed: return .failed
            case .running: return .working
            case .waiting: return .idle
            case .done: return .done
            }
        }
        func ago(_ note: String?) -> TimeInterval? {
            guard let note, let n = Double(note.prefix { $0.isNumber }) else { return nil }
            if note.contains("d ago") { return n * 86400 }
            if note.contains("h ago") { return n * 3600 }
            if note.contains("min ago") { return n * 60 }
            return nil
        }
        for row in p.steps {
            if row.isSection { inRoster = !row.title.hasPrefix("Plan"); continue }
            if inRoster {
                let age = ago(row.note)
                strays.append(Helper(id: row.ownerAgent, name: row.title, model: row.owner, phase: phase(row.state),
                                     endedAgo: age, stale: row.state == .failed && (age ?? 0) > 86400))
                continue
            }
            let owner: Owner
            if row.owner == "Lead" { owner = .lead }
            else if row.owner == "You" { owner = .you }
            else if let id = row.ownerAgent {
                let parts = row.owner.components(separatedBy: " · ")
                owner = .helpers([Helper(id: id, name: parts.first ?? row.owner, model: parts.dropFirst().joined(separator: " · "),
                                         phase: phase(row.state))])
            } else if row.owner == "Helper unavailable" { owner = .unavailable }
            else { owner = .unstarted(row.owner) }
            steps.append(Step(title: row.title, owner: owner, done: row.state == .done))
        }
        self.init(steps: steps, strays: strays, decision: p.decision, options: p.options, collapsed: p.collapsed)
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

/// Bounded rows. Draws the selected pinned-steps layout using tokens;
/// no per-step view tree, timers, or text measurement in layout.
@MainActor
final class AgentLeadPlanView: NSView, NativeVectorDrawnContent {
    var drawnContentFingerprint: Int {
        var hash = Hasher()
        hash.combine(presentation?.header)
        for step in presentation?.steps ?? [] {
            hash.combine(step.title); hash.combine(step.owner); hash.combine(step.state.rawValue); hash.combine(step.note); hash.combine(step.liveDot); hash.combine(step.isSection); hash.combine(step.stale)
        }
        hash.combine(presentation?.decision); hash.combine(presentation?.options)
        hash.combine(zoom)
        hash.combine(direction.rawValue)
        hash.combine(drawerLayout.map { "\($0.rows.count)" + ($0.header.text.map(\.0).joined()) })
        hash.combine(triageFilter.rawValue)
        return hash.finalize()
    }
    private(set) var presentation: LeadPlanPresentation?
    /// Which drawer this view draws. Production reads the override once.
    var direction: LeadPlanDrawerDirection = .current {
        didSet { refreshDrawer() }
    }
    /// The joined model the redesign draws (fixtures set it directly).
    private(set) var drawer: LeadPlanDrawerModel?
    private var fixtureDrawer = false
    let chevron = NSImageView()
    /// The lead's offered answers, in the composer's own chip style.
    let optionRail = ComposerReplyOptionRailView(frame: .zero)
    var onToggle: (() -> Void)?
    /// Clicking a helper row's owner.
    var onRevealOwner: ((AgentID) -> Void)?
    /// Clicking an answer chip.
    var onChoose: ((String) -> Void)?
    var zoom: AgentPageZoom = .default {
        didSet { refreshDrawer(); invalidateIntrinsicContentSize(); needsLayout = true; applyTokens() }
    }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        if let drawerLayout { return NSSize(width: NSView.noIntrinsicMetric, height: drawerLayout.height) }
        let height = presentation.map { $0.collapsed ? 32 : 37 + 23 * $0.steps.count + ($0.decision == nil ? 0 : 23) + ($0.options.isEmpty ? 0 : 34) } ?? 0
        return NSSize(width: NSView.noIntrinsicMetric, height: zoom.scaled(Double(height)))
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        chevron.imageScaling = .scaleNone
        chevron.setAccessibilityElement(false)
        addSubview(chevron)
        optionRail.translatesAutoresizingMaskIntoConstraints = true
        optionRail.isHidden = true
        optionRail.onSelect = { [weak self] answer in self?.onChoose?(answer) }
        addSubview(optionRail)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        isHidden = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    /// Checks only: every change the drawer actually takes.
    var qaOnUpdate: ((LeadPlanPresentation?) -> Void)?
    func update(_ value: LeadPlanPresentation?) {
        guard value != presentation else { return }
        defer { qaOnUpdate?(value) }
        let oldHeight = intrinsicContentSize.height
        presentation = value
        isHidden = value == nil
        if !fixtureDrawer { refreshDrawer() }
        if oldHeight != intrinsicContentSize.height { invalidateIntrinsicContentSize() }
        setAccessibilityLabel(drawerLayout?.header.text.map(\.0).joined() ?? value?.header)
        setAccessibilityValue(value?.collapsed == true ? "collapsed" : "expanded")
        setAccessibilityHelp(value?.steps.map { "\($0.title), \($0.owner), \($0.state.rawValue)" }.joined(separator: "; "))
        optionRail.setOptions(value?.collapsed == false ? (value?.options ?? []).map { AgentReplyOption(label: $0) } : [])
        optionRail.isHidden = optionRail.qaOptions.isEmpty
        applyTokens()
        needsLayout = true
    }

    /// Renders and design review only: draw `model` as-is.
    func qaShowDrawer(_ model: LeadPlanDrawerModel) {
        fixtureDrawer = true
        drawer = model
        isHidden = false
        relayoutDrawer()
        optionRail.setOptions(model.collapsed ? [] : model.options.map { AgentReplyOption(label: $0) })
        optionRail.isHidden = optionRail.qaOptions.isEmpty
        applyTokens()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    // MARK: Geometry (one source for drawing and hit-testing)
    private var rowsTop: CGFloat {
        let z = CGFloat(zoom.factor)
        guard let p = presentation else { return 34 * z }
        return (34 + (p.decision == nil ? 0 : 23) + (p.options.isEmpty ? 0 : 34)) * z
    }
    private var ownerX: CGFloat { min(314 * CGFloat(zoom.factor), bounds.width * 0.49) }
    /// Always room for "Done · 14 min ago": sizing this to whether any row has
    /// an age moved every row's owner and state cells when one helper finished.
    private var stateX: CGFloat { bounds.width - 150 * CGFloat(zoom.factor) }
    func rowRect(_ index: Int) -> NSRect {
        let z = CGFloat(zoom.factor)
        return NSRect(x: 0, y: rowsTop + CGFloat(index * 23) * z, width: bounds.width, height: 23 * z)
    }
    /// The clickable owner cell of a helper row, in this view's coordinates.
    func ownerRect(_ index: Int) -> NSRect {
        let row = rowRect(index)
        return NSRect(x: ownerX, y: row.minY, width: max(0, stateX - ownerX - 10 * CGFloat(zoom.factor)), height: row.height)
    }
    func applyTokens() {
        // Same SF Symbol treatment as ProcessesDisclosureRow, also used by
        // Array's choice menus. A real image view, never a drawn/text arrow.
        let collapsed = drawer?.collapsed ?? presentation?.collapsed
        chevron.image = CanvasSymbolImage.image(named: collapsed == true ? "chevron.right" : "chevron.down",
                                                pointSize: CGFloat(zoom.scaled(10)), weight: .semibold)
        chevron.contentTintColor = TextToken.textSecondary.color.nsColor(for: effectiveTokenTheme)
        needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyTokens() }
    override func layout() {
        super.layout()
        let frame = NSRect(x: bounds.width - CGFloat(zoom.scaled(30)), y: CGFloat(zoom.scaled(8)),
                           width: CGFloat(zoom.scaled(14)), height: CGFloat(zoom.scaled(16)))
        if chevron.frame != frame { chevron.frame = frame }
        optionRail.applyPageZoom(zoom)
        let z = CGFloat(zoom.factor)
        let railY = drawerLayout?.railY ?? (34 + (presentation?.decision == nil ? 0 : 23)) * z
        let railX = drawerLayout.map { 30 * z + $0.leadColumn } ?? 16 * z
        let railFrame = NSRect(x: railX, y: railY, width: max(0, bounds.width - 32 * z), height: optionRail.railHeight)
        if optionRail.frame != railFrame { optionRail.frame = railFrame }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // The image is part of the disclosure target, not a separate control.
        // The answer chips are real buttons and keep their own clicks.
        guard let hit = super.hitTest(point) else { return nil }
        if !optionRail.isHidden, hit === optionRail || hit.isDescendant(of: optionRail) { return hit }
        return self
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let layout = drawerLayout {
            if direction == .triage, let chip = chipFrames(layout).first(where: { $0.1.contains(point) }) {
                if drawer?.collapsed == true {
                    triageFilter = chip.0
                    _ = accessibilityPerformPress()
                } else {
                    triageFilter = triageFilter == chip.0 ? .active : chip.0
                }
                refreshDrawer(); invalidateIntrinsicContentSize(); needsDisplay = true
                return
            }
            if point.y <= headerHeight { _ = accessibilityPerformPress(); return }
            for (i, row) in layout.rows.enumerated() {
                if let owner = row.ownerAgent, drawerRowRect(i, in: layout).contains(point) { onRevealOwner?(owner); return }
            }
            return
        }
        if point.y <= CGFloat(zoom.scaled(32)) { _ = accessibilityPerformPress(); return }
        guard let p = presentation, !p.collapsed else { return }
        for (i, step) in p.steps.enumerated() where !step.isSection {
            if let owner = step.ownerAgent, ownerRect(i).contains(point) { onRevealOwner?(owner); return }
        }
    }
    override func accessibilityPerformPress() -> Bool {
        guard presentation != nil || drawer != nil else { return false }
        if fixtureDrawer, var d = drawer { d.collapsed.toggle(); qaShowDrawer(d); return true }
        onToggle?()
        return true
    }
    private func ink(_ state: LeadPlanPresentation.State) -> NSColor {
        let token: AccentToken?
        switch state {
        case .running: token = .accentWorking
        case .failed: token = .accentFailed
        case .needsYou: token = .accentApproval
        default: token = nil
        }
        return token?.color.nsColor(for: effectiveTokenTheme) ?? TextToken.textSecondary.color.nsColor(for: effectiveTokenTheme)
    }
    private func text(_ value: String, rect: NSRect, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(in: rect, withAttributes: [
            .font: NSFont.token(.label, zoom: zoom), .foregroundColor: color, .paragraphStyle: paragraph])
    }
    override func draw(_ dirtyRect: NSRect) {
        if let drawerLayout { drawDrawer(drawerLayout); return }
        guard let p = presentation else { return }
        let z = CGFloat(zoom.factor)
        let inset = 16 * z, line = 20 * z
        SurfaceToken.tileBody.color.nsColor(for: effectiveTokenTheme).setFill(); bounds.fill()
        LineToken.separator.color.nsColor(for: effectiveTokenTheme).setFill()
        NSRect(x: inset, y: 0, width: max(0, bounds.width - inset * 2), height: z).fill()
        let secondary = TextToken.textSecondary.color.nsColor(for: effectiveTokenTheme)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let header = NSMutableAttributedString(string: p.header, attributes: [
            .font: NSFont.token(.label, zoom: zoom), .foregroundColor: secondary, .paragraphStyle: paragraph])
        if p.collapsed, let urgent = p.urgent {
            let start = (p.summary as NSString).length
            header.addAttribute(.foregroundColor, value: ink(urgent.state),
                                range: NSRange(location: start, length: header.length - start))
        }
        header.draw(in: NSRect(x: inset, y: 8 * z, width: max(0, bounds.width - inset - 36 * z), height: line))
        guard !p.collapsed else { return }
        let stateX = self.stateX, ownerX = self.ownerX
        let primary = TextToken.textPrimary.color.nsColor(for: effectiveTokenTheme)
        if let decision = p.decision {
            text("Needs you · " + decision, rect: NSRect(x: inset, y: 34 * z, width: max(0, bounds.width - inset * 2), height: line), color: ink(.needsYou))
        }
        var number = 0
        for (i, step) in p.steps.enumerated() {
            let y = rowRect(i).minY
            if step.isSection {
                text(step.title.uppercased(), rect: NSRect(x: inset, y: y, width: max(0, bounds.width - inset * 2), height: line),
                     color: step.stale ? ink(.needsYou) : secondary)
                continue
            }
            number += 1
            text("\(number)  \(step.title)", rect: NSRect(x: inset, y: y, width: max(0, ownerX - inset - 10 * z), height: line),
                 color: step.state == .done || step.stale ? secondary : primary)
            var ox = ownerX
            if step.liveDot {
                let d = 7 * z
                ink(step.state).setFill()
                NSBezierPath(ovalIn: NSRect(x: ownerX, y: y + (23 * z - d) / 2 - z, width: d, height: d)).fill()
                ox += 12 * z
            }
            text(step.owner, rect: NSRect(x: ox, y: y, width: max(0, stateX - ox - 10 * z), height: line), color: secondary)
            let label = step.state.rawValue + (step.note.map { " · " + $0 } ?? "")
            text(label, rect: NSRect(x: stateX, y: y, width: 138 * z, height: line), color: ink(step.state))
        }
    }

    // MARK: - Redesign (behind `ARRAY_LEAD_PLAN_DRAWER`)

    enum TriageFilter: String { case active, plan, idle, done, older }
    private(set) var triageFilter: TriageFilter = .active

    enum Ink: Equatable { case primary, secondary, accent(AccentToken) }
    enum Glyph: Equatable { case none, dot(AccentToken), ring(Bool) }
    struct DrawerRow: Equatable {
        var glyph: Glyph = .none
        /// A short left column: a step number or a band word.
        var lead: String? = nil
        var title: String
        var titleInk: Ink = .primary
        var owner: String? = nil
        var ownerAgent: AgentID? = nil
        var state: String? = nil
        var stateInk: Ink = .secondary
    }
    struct DrawerChip: Equatable { var glyph: Glyph; var text: String; var ink: Ink; var filter: TriageFilter }
    struct DrawerHeader: Equatable {
        /// Segmented progress, one cell per plan step (Track).
        var track: [LeadPlanDrawerModel.StepPhase] = []
        var text: [(String, Ink)] = []
        var chips: [DrawerChip] = []
        var trailing: [(String, Ink)] = []
        static func == (a: DrawerHeader, b: DrawerHeader) -> Bool {
            a.track == b.track && a.chips == b.chips && a.text.map(\.0) == b.text.map(\.0) && a.trailing.map(\.0) == b.trailing.map(\.0)
        }
    }
    struct DrawerLayout: Equatable {
        var header: DrawerHeader
        var rows: [DrawerRow]
        /// Rows above the answer rail (the decision row).
        var railAfter: Int? = nil
        var railY: CGFloat? = nil
        var height: CGFloat
        var leadColumn: CGFloat = 0
    }
    private(set) var drawerLayout: DrawerLayout?
    /// Most rows a drawer may ever show, header excluded. The budget.
    static let drawerRowBudget = 6
    /// Wide enough for "Failed · 12 min ago".
    static let stateColumn: CGFloat = 104

    private var headerHeight: CGFloat { 32 * CGFloat(zoom.factor) }
    private var rowHeight: CGFloat { 22 * CGFloat(zoom.factor) }

    private func refreshDrawer() {
        guard !fixtureDrawer else { relayoutDrawer(); return }
        drawer = direction == .shipped ? nil : presentation.map(LeadPlanDrawerModel.init(adapting:))
        relayoutDrawer()
    }
    private func relayoutDrawer() {
        drawerLayout = drawer.map { Self.layout($0, direction: direction, filter: triageFilter, zoom: zoom) }
    }

    func drawerRowRect(_ index: Int, in layout: DrawerLayout) -> NSRect {
        let z = CGFloat(zoom.factor)
        var y = headerHeight + CGFloat(index) * rowHeight
        if let after = layout.railAfter, index >= after { y += optionRail.railHeight }
        return NSRect(x: 0, y: y, width: bounds.width, height: 22 * z)
    }

    // MARK: Pure layout per direction

    private static func ageText(_ seconds: TimeInterval?) -> String? {
        guard let s = seconds, s >= 60 else { return nil }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86400 { return "\(Int(s / 3600))h ago" }
        return "\(Int(s / 86400))d ago"
    }
    private static func owner(_ o: LeadPlanDrawerModel.Owner) -> (String, AgentID?) {
        switch o {
        case .lead: return ("Lead", nil)
        case .you: return ("You", nil)
        case .unavailable: return ("Helper unavailable", nil)
        case .unstarted(let name): return ("\(name) · not started", nil)
        case .helpers(let hs):
            guard let h = hs.first(where: { !$0.stale }) ?? hs.first else { return ("Helper", nil) }
            // The step title already says what the helper does; its name would
            // repeat it. The model is the owner cell, still the reveal target.
            return (h.model + (hs.count > 1 ? " +\(hs.count - 1)" : ""), h.id)
        }
    }
    private static func glyph(_ p: LeadPlanDrawerModel.StepPhase) -> Glyph {
        switch p {
        case .needsYou: .dot(.accentApproval)
        case .failed: .dot(.accentFailed)
        case .working: .dot(.accentWorking)
        case .done: .dot(.accentDone)
        case .idle: .ring(true)
        case .todo: .ring(false)
        }
    }
    private static func stateWord(_ p: LeadPlanDrawerModel.StepPhase, step: LeadPlanDrawerModel.Step) -> (String?, Ink) {
        var ended: TimeInterval?
        if case .helpers(let hs) = step.owner { ended = hs.compactMap(\.endedAgo).min() }
        switch p {
        case .needsYou: return ("Needs you", .accent(.accentApproval))
        case .failed: return (["Failed", ageText(ended)].compactMap { $0 }.joined(separator: " · "), .accent(.accentFailed))
        case .working: return ("Running", .accent(.accentWorking))
        case .idle: return ("Idle", .secondary)
        case .done: return (["Done", ageText(ended)].compactMap { $0 }.joined(separator: " · "), .secondary)
        case .todo: return (nil, .secondary)
        }
    }
    private static func stepRow(_ m: LeadPlanDrawerModel, _ i: Int, lead: String?) -> DrawerRow {
        let step = m.steps[i], p = m.phase(of: step)
        let (owner, agent) = owner(step.owner)
        let (state, ink) = stateWord(p, step: step)
        return DrawerRow(glyph: glyph(p), lead: lead, title: step.title, titleInk: p == .done ? .secondary : .primary,
                         owner: owner, ownerAgent: agent, state: state, stateInk: ink)
    }
    private static func strayRow(_ h: LeadPlanDrawerModel.Helper, lead: String? = nil) -> DrawerRow {
        let p: LeadPlanDrawerModel.StepPhase
        switch h.phase {
        case .needsYou: p = .needsYou
        case .failed: p = .failed
        case .working: p = .working
        case .idle: p = .idle
        case .done: p = .done
        }
        let step = LeadPlanDrawerModel.Step(title: h.name, owner: .helpers([h]))
        let (state, ink) = stateWord(p, step: step)
        return DrawerRow(glyph: glyph(p), lead: lead, title: h.name, titleInk: .primary, owner: h.model, ownerAgent: h.id,
                         state: state, stateInk: ink)
    }
    private static func isAttention(_ p: LeadPlanDrawerModel.StepPhase) -> Bool { p == .needsYou || p == .failed }
    private static func attentionStrays(_ m: LeadPlanDrawerModel) -> [LeadPlanDrawerModel.Helper] {
        m.strays.filter { !$0.stale && ($0.phase == .needsYou || $0.phase == .failed) }
    }
    /// "Also · 2 idle · 1 done 1h ago · 3 failed 5–6d ago": every helper the list
    /// does not show, one line.
    private static func foldText(_ hs: [LeadPlanDrawerModel.Helper], prefix: String? = "Also") -> String? {
        var parts: [String] = []
        let working = hs.filter { $0.phase == .working }.count
        let idle = hs.filter { $0.phase == .idle }.count
        let done = hs.filter { $0.phase == .done }
        let stale = hs.filter { $0.stale }
        if working > 0 { parts.append("\(working) running") }
        if idle > 0 { parts.append("\(idle) idle") }
        if !done.isEmpty { parts.append("\(done.count) done" + (ageText(done.compactMap(\.endedAgo).min()).map { " " + $0 } ?? "")) }
        if !stale.isEmpty {
            let days = stale.compactMap(\.endedAgo).map { Int($0 / 86400) }
            let range = days.isEmpty ? "" : (days.min() == days.max() ? " \(days.min()!)d ago" : " \(days.min()!)–\(days.max()!)d ago")
            parts.append("\(stale.count) failed\(range)")
        }
        return parts.isEmpty ? nil : ([prefix].compactMap { $0 } + parts).joined(separator: " · ")
    }
    private static func current(_ m: LeadPlanDrawerModel) -> Int? {
        let phases = m.steps.map { m.phase(of: $0) }
        return phases.firstIndex(where: isAttention) ?? phases.firstIndex(of: .working)
            ?? phases.firstIndex(of: .idle) ?? phases.firstIndex(of: .todo)
    }
    private static func attentionCount(_ m: LeadPlanDrawerModel) -> Int {
        m.steps.filter { isAttention(m.phase(of: $0)) }.count + attentionStrays(m).count + (m.decision == nil ? 0 : 1)
    }
    private static func headline(_ m: LeadPlanDrawerModel) -> [(String, Ink)] {
        let done = m.steps.filter { m.phase(of: $0) == .done }.count
        var out: [(String, Ink)] = [(m.steps.isEmpty ? "Helpers" : "Plan · \(done) of \(m.steps.count) done", .secondary)]
        let attention = attentionCount(m)
        // Open, the decision is its own row; the header only counts it.
        if let d = m.decision, m.collapsed { out.append((" · Needs you: \(d)", .accent(.accentApproval))) }
        else if attention > 0 { out.append((" · \(attention) need\(attention == 1 ? "s" : "") you", .accent(.accentApproval))) }
        return out
    }

    static func layout(_ m: LeadPlanDrawerModel, direction: LeadPlanDrawerDirection, filter: TriageFilter, zoom: AgentPageZoom) -> DrawerLayout {
        let z = CGFloat(zoom.factor)
        var header = DrawerHeader()
        var rows: [DrawerRow] = []
        var railAfter: Int?
        let budget = drawerRowBudget
        let phases = m.steps.map { m.phase(of: $0) }
        let attention = attentionStrays(m)
        func decisionRow() {
            guard let d = m.decision else { return }
            rows.append(DrawerRow(glyph: .dot(.accentApproval), title: d, owner: "Lead", state: "Needs you", stateInk: .accent(.accentApproval)))
            if !m.options.isEmpty { railAfter = rows.count }
        }
        var leadColumn: CGFloat = 0

        switch direction {
        case .shipped:
            break
        case .checklist:
            // The plan IS the list, numbered by plan position. What needs you
            // sits above it; everything the plan does not name is one line.
            header.text = headline(m)
            if m.collapsed, !m.steps.isEmpty { header.track = phases; header.text[0].0 = "\(phases.filter { $0 == .done }.count) of \(m.steps.count) done" }
            if m.collapsed, m.decision == nil, let c = current(m) {
                let (word, ink) = stateWord(phases[c], step: m.steps[c])
                header.text.append((" · " + (word.map { "\($0): " } ?? "Next: ") + m.steps[c].title,
                                    isAttention(phases[c]) ? ink : .secondary))
            }
            guard !m.collapsed else { break }
            decisionRow()
            for h in attention.prefix(2) { rows.append(strayRow(h)) }
            // Never fold the plan itself: `array_status` caps it at six steps.
            for i in m.steps.indices { rows.append(stepRow(m, i, lead: "\(i + 1)")) }
            for h in m.strays where h.phase == .working && rows.count < budget { rows.append(strayRow(h, lead: "")) }
            let folded = m.strays.filter { h in !attention.contains(h) && !rows.contains { $0.ownerAgent != nil && $0.ownerAgent == h.id } }
            if let fold = foldText(folded) { rows.append(DrawerRow(lead: "", title: fold, titleInk: .secondary)) }
            leadColumn = 18
        case .track:
            // One segmented track for the whole plan; the list is Now / Next /
            // Later, so the drawer is about the present, never the history.
            header.track = phases
            if let c = current(m) {
                header.text = [("\(c + 1) of \(m.steps.count) · ", .secondary), (m.steps[c].title, .primary)]
                let (word, ink) = stateWord(phases[c], step: m.steps[c])
                header.trailing = [(owner(m.steps[c].owner).0, .secondary)] + (word.map { [("  " + $0, ink)] } ?? [])
            } else if !m.steps.isEmpty {
                header.text = [("All \(m.steps.count) steps done", .secondary)]
            } else {
                header.text = [("Helpers", .secondary)]
            }
            if attentionCount(m) > 0, m.collapsed {
                let n = attentionCount(m)
                header.trailing = [("\(n) need\(n == 1 ? "s" : "") you", .accent(.accentApproval))]
            }
            guard !m.collapsed else { break }
            // Open, the Now row says it; the header keeps only the track and title.
            header.trailing = []
            decisionRow()
            if !rows.isEmpty { rows[0].lead = "Now" }
            var now = phases.indices.filter { isAttention(phases[$0]) || phases[$0] == .working || phases[$0] == .idle }
            for h in attention.prefix(2) { rows.append(strayRow(h, lead: rows.isEmpty ? "Now" : "")) }
            let nowRoom = max(1, budget - rows.count - 3)
            if now.count > nowRoom { now = Array(now.prefix(nowRoom)) }
            for i in now { rows.append(stepRow(m, i, lead: rows.isEmpty ? "Now" : "")) }
            for h in m.strays where h.phase == .working && rows.count < budget - 3 { rows.append(strayRow(h, lead: rows.isEmpty ? "Now" : "")) }
            let later = phases.indices.filter { phases[$0] == .todo && !now.contains($0) }
            if let next = later.first { rows.append(stepRow(m, next, lead: "Next")) }
            if later.count > 1 {
                let owners = Set(later.dropFirst().map { owner(m.steps[$0].owner).0 })
                rows.append(DrawerRow(lead: "Later", title: "\(later.count - 1) more step\(later.count == 2 ? "" : "s")" + (owners.count == 1 ? " · \(owners.first!)" : ""), titleInk: .secondary))
            }
            let done = phases.filter { $0 == .done }.count
            let folded = m.strays.filter { !attention.contains($0) && $0.phase != .working }
            let tail = [done > 0 ? "\(done) step\(done == 1 ? "" : "s") done" : nil, foldText(folded, prefix: nil)]
                .compactMap { $0 }.filter { !$0.isEmpty }
            if !tail.isEmpty { rows.append(DrawerRow(lead: "Also", title: tail.joined(separator: " · "), titleInk: .secondary)) }
            leadColumn = 44
        case .triage:
            // The resting drawer is a row of counts; the list below is a filter
            // over ONE list, defaulting to what is live.
            let active = phases.indices.filter { isAttention(phases[$0]) || phases[$0] == .working }
            let idle = phases.indices.filter { phases[$0] == .idle }
            let idleStrays = m.strays.filter { $0.phase == .idle }
            let doneSteps = phases.indices.filter { phases[$0] == .done }
            let doneStrays = m.strays.filter { $0.phase == .done }
            let stale = m.strays.filter(\.stale)
            let doneCount = doneSteps.count
            header.chips.append(DrawerChip(glyph: .none, text: m.steps.isEmpty ? "Helpers" : "Plan \(doneCount)/\(m.steps.count)", ink: .primary, filter: .plan))
            let needs = active.filter { isAttention(phases[$0]) }.count + attention.count + (m.decision == nil ? 0 : 1)
            if needs > 0 { header.chips.append(DrawerChip(glyph: .dot(.accentApproval), text: "\(needs) need\(needs == 1 ? "s" : "") you", ink: .accent(.accentApproval), filter: .active)) }
            let running = active.filter { phases[$0] == .working }.count + m.strays.filter { $0.phase == .working }.count
            if running > 0 { header.chips.append(DrawerChip(glyph: .dot(.accentWorking), text: "\(running) running", ink: .primary, filter: .active)) }
            if idle.count + idleStrays.count > 0 { header.chips.append(DrawerChip(glyph: .ring(true), text: "\(idle.count + idleStrays.count) idle", ink: .secondary, filter: .idle)) }
            if !doneStrays.isEmpty { header.chips.append(DrawerChip(glyph: .dot(.accentDone), text: "\(doneStrays.count) done", ink: .secondary, filter: .done)) }
            if !stale.isEmpty { header.chips.append(DrawerChip(glyph: .none, text: "\(stale.count) old failures", ink: .secondary, filter: .older)) }
            guard !m.collapsed else { break }
            var candidate: [DrawerRow] = []
            switch filter {
            case .active:
                decisionRow()
                candidate = attention.map { strayRow($0) } + active.map { stepRow(m, $0, lead: "\($0 + 1)") }
                    + m.strays.filter { $0.phase == .working }.map { strayRow($0) }
                if let next = phases.indices.first(where: { phases[$0] == .todo || phases[$0] == .idle }), !active.contains(next) {
                    candidate.append(stepRow(m, next, lead: "\(next + 1)"))
                }
            case .plan: candidate = m.steps.indices.map { stepRow(m, $0, lead: "\($0 + 1)") }
            case .idle: candidate = idle.map { stepRow(m, $0, lead: "\($0 + 1)") } + idleStrays.map { strayRow($0) }
            case .done: candidate = doneStrays.map { strayRow($0) }
            case .older: candidate = stale.map { strayRow($0) }
            }
            let shownSteps = Set(candidate.compactMap { Int($0.lead ?? "") })
            let hidden = m.steps.count - shownSteps.count
            let room = budget - rows.count - (hidden > 0 && filter == .active ? 1 : 0)
            defer { if hidden > 0, filter == .active, !m.collapsed { rows.append(DrawerRow(lead: "", title: "\(hidden) more step\(hidden == 1 ? "" : "s") in the plan", titleInk: .secondary)) } }
            if candidate.count > room {
                rows += candidate.prefix(room - 1)
                rows.append(DrawerRow(lead: "", title: "\(candidate.count - room + 1) more", titleInk: .secondary))
            } else { rows += candidate }
            leadColumn = 18
        }
        let railHeight = railAfter == nil ? 0 : ComposerReplyOptionRailView.railHeight(zoom: zoom)
        let height = 32 * z + CGFloat(rows.count) * 22 * z + railHeight + (rows.isEmpty ? 0 : 6 * z)
        let railY = railAfter.map { 32 * z + CGFloat($0) * 22 * z }
        return DrawerLayout(header: header, rows: rows, railAfter: railAfter, railY: railY, height: height, leadColumn: leadColumn * z)
    }

    // MARK: Drawing

    private func color(_ ink: Ink) -> NSColor {
        let theme = effectiveTokenTheme
        switch ink {
        case .primary: return TextToken.textPrimary.color.nsColor(for: theme)
        case .secondary: return TextToken.textSecondary.color.nsColor(for: theme)
        case .accent(let a): return a.color.nsColor(for: theme)
        }
    }
    /// Text on a row's midline: the baseline sits half a cap height below
    /// `midY`, so a glyph centred on `midY` is centred on the capitals. Returns
    /// the drawn width.
    @discardableResult
    private func line(_ s: String, x: CGFloat, midY: CGFloat, maxX: CGFloat, ink: Ink, alignRight: Bool = false) -> CGFloat {
        guard maxX > x, !s.isEmpty else { return 0 }
        let font = NSFont.token(.label, zoom: zoom)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(ink), .paragraphStyle: paragraph]
        let width = min(ceil((s as NSString).size(withAttributes: attrs).width), maxX - x)
        let baseline = midY + font.capHeight / 2
        // Where the text system actually puts the baseline in a line fragment
        // (SF's line box is taller than ascender − descender).
        let top = baseline - Self.baselineOffset(font)
        let originX = alignRight ? maxX - width : x
        (s as NSString).draw(with: NSRect(x: originX, y: top, width: width, height: ceil(Self.baselineOffset(font) - font.descender + 2)),
                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        return width
    }
    private static var baselineOffsets: [CGFloat: CGFloat] = [:]
    private static func baselineOffset(_ font: NSFont) -> CGFloat {
        if let cached = baselineOffsets[font.pointSize] { return cached }
        let value = NSLayoutManager().defaultBaselineOffset(for: font)
        baselineOffsets[font.pointSize] = value
        return value
    }
    private func width(_ s: String) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: NSFont.token(.label, zoom: zoom)]).width)
    }
    private func drawGlyph(_ g: Glyph, centerX: CGFloat, midY: CGFloat) {
        let z = CGFloat(zoom.factor)
        switch g {
        case .none: return
        case .dot(let a):
            let d = 6 * z
            a.color.nsColor(for: effectiveTokenTheme).setFill()
            NSBezierPath(ovalIn: NSRect(x: centerX - d / 2, y: midY - d / 2, width: d, height: d)).fill()
        case .ring(let strong):
            let d = 6 * z
            let path = NSBezierPath(ovalIn: NSRect(x: centerX - d / 2, y: midY - d / 2, width: d, height: d).insetBy(dx: 0.6 * z, dy: 0.6 * z))
            path.lineWidth = 1.2 * z
            (strong ? TextToken.textSecondary.color : LineToken.borderStrong.color).nsColor(for: effectiveTokenTheme).setStroke()
            path.stroke()
        }
    }
    private func chipFrames(_ layout: DrawerLayout) -> [(TriageFilter, NSRect)] {
        let z = CGFloat(zoom.factor)
        var x = 16 * z
        let h = 20 * z, y = (headerHeight - h) / 2
        return layout.header.chips.map { chip in
            let w = width(chip.text) + (chip.glyph == .none ? 16 : 26) * z
            defer { x += w + 6 * z }
            return (chip.filter, NSRect(x: x, y: y, width: w, height: h))
        }
    }
    private func drawDrawer(_ layout: DrawerLayout) {
        let z = CGFloat(zoom.factor)
        let theme = effectiveTokenTheme
        let inset = 16 * z
        SurfaceToken.tileBody.color.nsColor(for: theme).setFill(); bounds.fill()
        LineToken.separator.color.nsColor(for: theme).setFill()
        NSRect(x: inset, y: 0, width: max(0, bounds.width - inset * 2), height: z).fill()
        let headerMid = headerHeight / 2
        let headerMax = bounds.width - 36 * z
        var x = inset
        // Track: one rounded cell per step, all the same width.
        if !layout.header.track.isEmpty {
            let n = CGFloat(layout.header.track.count)
            let cell = min(14 * z, (96 * z - (n - 1) * 2 * z) / n), h = 4 * z
            for (i, p) in layout.header.track.enumerated() {
                let r = NSRect(x: x + CGFloat(i) * (cell + 2 * z), y: headerMid - h / 2, width: cell, height: h)
                let fill: NSColor = switch p {
                case .done: AccentToken.accentDone.color.nsColor(for: theme)
                case .working: AccentToken.accentWorking.color.nsColor(for: theme)
                case .needsYou: AccentToken.accentApproval.color.nsColor(for: theme)
                case .failed: AccentToken.accentFailed.color.nsColor(for: theme)
                case .idle, .todo: LineToken.border.color.nsColor(for: theme)
                }
                fill.setFill()
                NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
            }
            x += n * (cell + 2 * z) + 8 * z
        }
        if !layout.header.chips.isEmpty {
            for (chip, (_, r)) in zip(layout.header.chips, chipFrames(layout)) where r.maxX <= headerMax {
                let selected = !(drawer?.collapsed ?? true) && chip.filter == triageFilter && chip.filter != .active
                (selected ? AgentSurfaceRole.rowSelected : AgentSurfaceRole.artifact).color.nsColor(for: theme).setFill()
                NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
                var tx = r.minX + 8 * z
                if chip.glyph != .none { drawGlyph(chip.glyph, centerX: tx + 3 * z, midY: headerMid); tx += 10 * z }
                line(chip.text, x: tx, midY: headerMid, maxX: r.maxX - 6 * z, ink: chip.ink)
            }
        }
        var trailingX = headerMax
        for (s, ink) in layout.header.trailing.reversed() {
            let w = min(width(s), max(0, trailingX - x - 40 * z))
            line(s, x: trailingX - w, midY: headerMid, maxX: trailingX, ink: ink)
            trailingX -= w
        }
        for (s, ink) in layout.header.text {
            x += line(s, x: x, midY: headerMid, maxX: trailingX - 12 * z, ink: ink)
        }

        let glyphX = inset + 3 * z
        let leadX = inset + 14 * z
        let titleX = leadX + layout.leadColumn
        for (i, row) in layout.rows.enumerated() {
            let rect = drawerRowRect(i, in: layout)
            let mid = rect.midY
            drawGlyph(row.glyph, centerX: glyphX, midY: mid)
            if let lead = row.lead, !lead.isEmpty {
                line(lead, x: leadX, midY: mid, maxX: titleX - 4 * z, ink: .secondary)
            }
            var right = bounds.width - inset
            if let state = row.state {
                line(state, x: right - min(width(state), 140 * z), midY: mid, maxX: right, ink: row.stateInk, alignRight: true)
            }
            // A fixed state column, so owners line up whether or not a row has a state.
            if row.owner != nil { right -= Self.stateColumn * z + 12 * z }
            if let owner = row.owner {
                let w = min(width(owner), bounds.width * 0.34)
                line(owner, x: right - w, midY: mid, maxX: right, ink: .secondary, alignRight: true)
                right -= w + 12 * z
            }
            line(row.title, x: titleX, midY: mid, maxX: right, ink: row.titleInk)
        }
    }
}

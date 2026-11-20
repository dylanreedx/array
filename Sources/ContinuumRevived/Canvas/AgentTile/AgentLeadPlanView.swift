import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// Bounded to six rows. Draws the selected pinned-steps layout using tokens;
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
        return hash.finalize()
    }
    private(set) var presentation: LeadPlanPresentation?
    let chevron = NSImageView()
    /// The lead's offered answers, in the composer's own chip style.
    let optionRail = ComposerReplyOptionRailView(frame: .zero)
    var onToggle: (() -> Void)?
    /// Clicking a helper row's owner.
    var onRevealOwner: ((AgentID) -> Void)?
    /// Clicking an answer chip.
    var onChoose: ((String) -> Void)?
    var zoom: AgentPageZoom = .default {
        didSet { invalidateIntrinsicContentSize(); needsLayout = true; applyTokens() }
    }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
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
    func update(_ value: LeadPlanPresentation?) {
        guard value != presentation else { return }
        let oldHeight = intrinsicContentSize.height
        presentation = value
        isHidden = value == nil
        if oldHeight != intrinsicContentSize.height { invalidateIntrinsicContentSize() }
        setAccessibilityLabel(value?.header)
        setAccessibilityValue(value?.collapsed == true ? "collapsed" : "expanded")
        setAccessibilityHelp(value?.steps.map { "\($0.title), \($0.owner), \($0.state.rawValue)" }.joined(separator: "; "))
        optionRail.setOptions(value?.collapsed == false ? (value?.options ?? []).map { AgentReplyOption(label: $0) } : [])
        optionRail.isHidden = optionRail.qaOptions.isEmpty
        applyTokens()
        needsLayout = true
    }

    // MARK: Geometry (one source for drawing and hit-testing)
    private var rowsTop: CGFloat {
        let z = CGFloat(zoom.factor)
        guard let p = presentation else { return 34 * z }
        return (34 + (p.decision == nil ? 0 : 23) + (p.options.isEmpty ? 0 : 34)) * z
    }
    private var anyNote: Bool { presentation?.steps.contains { $0.note != nil } ?? false }
    private var ownerX: CGFloat { min(314 * CGFloat(zoom.factor), bounds.width * 0.49) }
    private var stateX: CGFloat { bounds.width - (anyNote ? 150 : 84) * CGFloat(zoom.factor) }
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
        chevron.image = CanvasSymbolImage.image(named: presentation?.collapsed == true ? "chevron.right" : "chevron.down",
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
        let railY = (34 + (presentation?.decision == nil ? 0 : 23)) * z
        let railFrame = NSRect(x: 16 * z, y: railY, width: max(0, bounds.width - 32 * z), height: optionRail.railHeight)
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
        if point.y <= CGFloat(zoom.scaled(32)) { _ = accessibilityPerformPress(); return }
        guard let p = presentation, !p.collapsed else { return }
        for (i, step) in p.steps.enumerated() where !step.isSection {
            if let owner = step.ownerAgent, ownerRect(i).contains(point) { onRevealOwner?(owner); return }
        }
    }
    override func accessibilityPerformPress() -> Bool {
        guard presentation != nil else { return false }
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
            text(label, rect: NSRect(x: stateX, y: y, width: (anyNote ? 138 : 72) * z, height: line), color: ink(step.state))
        }
    }
}

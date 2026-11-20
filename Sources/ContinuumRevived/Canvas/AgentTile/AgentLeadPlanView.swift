import AppKit
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
            hash.combine(step.title); hash.combine(step.owner); hash.combine(step.state.rawValue); hash.combine(step.note); hash.combine(step.liveDot); hash.combine(step.isSection)
        }
        hash.combine(presentation?.banner); hash.combine(presentation?.chips); hash.combine(presentation?.dimmed)
        hash.combine(zoom)
        return hash.finalize()
    }
    private(set) var presentation: LeadPlanPresentation?
    let chevron = NSImageView()
    var onToggle: (() -> Void)?
    var zoom: AgentPageZoom = .default {
        didSet { invalidateIntrinsicContentSize(); needsLayout = true; applyTokens() }
    }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        let height = presentation.map { $0.collapsed ? 32 : 37 + 23 * $0.steps.count + ($0.banner == nil ? 0 : 23) + ($0.chips.isEmpty ? 0 : 34) } ?? 0
        return NSSize(width: NSView.noIntrinsicMetric, height: zoom.scaled(Double(height)))
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        chevron.imageScaling = .scaleNone
        chevron.setAccessibilityElement(false)
        addSubview(chevron)
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
        applyTokens()
        needsLayout = true
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
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // The image is part of the disclosure target, not a separate control.
        super.hitTest(point) == nil ? nil : self
    }
    override func mouseDown(with event: NSEvent) {
        if convert(event.locationInWindow, from: nil).y <= CGFloat(zoom.scaled(32)) { _ = accessibilityPerformPress() }
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
        let anyNote = p.steps.contains { $0.note != nil }
        let stateX = bounds.width - (anyNote ? 150 : 84) * z
        let ownerX = min(314 * z, bounds.width * 0.49)
        let primary = p.dimmed ? secondary : TextToken.textPrimary.color.nsColor(for: effectiveTokenTheme)
        var top = 34 * z
        if let banner = p.banner {
            text(banner, rect: NSRect(x: inset, y: top, width: max(0, bounds.width - inset * 2), height: line), color: ink(.needsYou))
            top += 23 * z
        }
        for (i, step) in p.steps.enumerated() {
            let y = top + CGFloat(i * 23) * z
            if step.isSection {
                text(step.title.uppercased(), rect: NSRect(x: inset, y: y, width: max(0, bounds.width - inset * 2), height: line), color: secondary)
                continue
            }
            text("\(i + 1)  \(step.title)", rect: NSRect(x: inset, y: y, width: max(0, ownerX - inset - 10 * z), height: line),
                 color: step.state == .done ? secondary : primary)
            var ox = ownerX
            if step.liveDot {
                let d = 7 * z
                ink(step.state).setFill()
                NSBezierPath(ovalIn: NSRect(x: ownerX, y: y + 6.5 * z, width: d, height: d)).fill()
                ox += 12 * z
            }
            text(step.owner, rect: NSRect(x: ox, y: y, width: max(0, stateX - ox - 10 * z), height: line), color: secondary)
            let label = step.state.rawValue + (step.note.map { " · " + $0 } ?? "")
            text(label, rect: NSRect(x: stateX, y: y, width: (anyNote ? 138 : 72) * z, height: line), color: ink(step.state))
        }
        if !p.chips.isEmpty {
            var x = inset
            let y = top + CGFloat(p.steps.count * 23) * z + 6 * z
            let font = NSFont.token(.label, zoom: zoom)
            for chip in p.chips {
                let w = ceil((chip as NSString).size(withAttributes: [.font: font]).width) + 20 * z
                let r = NSRect(x: x, y: y, width: w, height: 24 * z)
                let path = NSBezierPath(roundedRect: r, xRadius: 12 * z, yRadius: 12 * z)
                path.lineWidth = z
                LineToken.separator.color.nsColor(for: effectiveTokenTheme).setStroke()
                path.stroke()
                text(chip, rect: NSRect(x: r.minX + 10 * z, y: r.minY + 2 * z, width: w, height: line), color: TextToken.textPrimary.color.nsColor(for: effectiveTokenTheme))
                x += w + 8 * z
            }
        }
    }
}

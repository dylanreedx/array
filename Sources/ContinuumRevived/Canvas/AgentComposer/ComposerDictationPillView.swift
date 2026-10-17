import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// A live dictation session, in one control: the mic grows into this capsule
/// over the provider controls — waveform, elapsed time, and a stop button
/// sitting exactly where the mic was, so the mic reads as turning into stop.
///
/// The tile owns where it sits and how wide it is (`expansion`); this view
/// only lays out and paints what fits. A click anywhere on it finishes, the
/// same as ↩: the words stay, nothing sends.
@MainActor
final class ComposerDictationPillView: NSView, TokenThemed, AgentPageZoomScalable {
    let waveform = ComposerDictationStripView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private let stopGlyph = NSView(frame: .zero)
    private(set) var pageZoom: AgentPageZoom = .default
    private(set) var mode: ComposerDictationStripView.Mode = .listening
    /// The session's colour: the agent's own when it has one, else input.
    var tint: NSColor? { didSet { applyTokens() } }
    var onFinish: (() -> Void)?
    /// 0 is the mic-sized circle, 1 fully grown. Content fades in with it so
    /// nothing is legible half-clipped.
    private(set) var expansion: CGFloat = 0 { didSet { updateContentAlpha() } }
    /// The tile fades what the pill covers by this.
    var onExpansionChange: ((CGFloat) -> Void)?

    /// The canvas's jelly (the toolbar's landing spring): settles in about a
    /// third of a second and overshoots a little as it lands.
    static let spring = FloatingToolbarSpring(response: 0.38, dampingRatio: 0.74)
    /// Where the pill is pinned: its trailing edge on the mic's, vertically
    /// centred on the row, growing leading-ward to `expandedWidth`.
    private var anchor = Anchor(maxX: 0, midY: 0, height: 0, expandedWidth: 0)
    private(set) var isExpanded = false
    private var width: CGFloat = 0
    private var velocity: CGFloat = 0
    private var motionLink: CADisplayLink?
    private var lastMotionTick: CFTimeInterval?

    struct Anchor: Equatable {
        var maxX: CGFloat
        var midY: CGFloat
        var height: CGFloat
        var expandedWidth: CGFloat
    }
    private var listeningSince: CFTimeInterval?
    private var shownSeconds = -1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        for label in [statusLabel, timeLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setAccessibilityElement(false)
            addSubview(label)
        }
        statusLabel.isHidden = true
        addSubview(waveform)
        stopGlyph.wantsLayer = true
        addSubview(stopGlyph)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Finish dictation")
        setAccessibilityHelp("Keeps what you said. Esc discards it.")
        toolTip = "Finish dictation (↩ or ⇧⌘D) — Esc discards"
        applyPageZoom(.default)
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func setMode(_ newMode: ComposerDictationStripView.Mode) {
        mode = newMode
        waveform.setMode(newMode)
        switch newMode {
        case .preparing(let downloading):
            statusLabel.stringValue = downloading ? "Downloading the speech model…" : "Getting ready…"
            statusLabel.isHidden = false
            waveform.isHidden = true
            listeningSince = nil
        case .listening:
            statusLabel.isHidden = true
            waveform.isHidden = false
            if listeningSince == nil { listeningSince = CACurrentMediaTime() }
        case .finalizing:
            statusLabel.isHidden = true
            waveform.isHidden = false
        }
        updateTime()
        needsLayout = true
    }

    func reset() {
        waveform.reset()
        listeningSince = nil
        shownSeconds = -1
        timeLabel.stringValue = "0:00"
    }

    /// Driven by the tile's motion tick and by the waveform's own cadence; it
    /// only touches the label when the shown second changes.
    func updateTime(now: CFTimeInterval = CACurrentMediaTime()) {
        let seconds = listeningSince.map { Int(now - $0) } ?? 0
        guard seconds != shownSeconds else { return }
        shownSeconds = seconds
        timeLabel.stringValue = String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    override func layout() {
        super.layout()
        layer?.applyCapsule()
        let side = bounds.height
        let inset = CGFloat(pageZoom.scaled(Space.l))
        let glyph = CGFloat(pageZoom.scaled(10))
        stopGlyph.frame = NSRect(
            x: bounds.width - side + (side - glyph) / 2, y: (side - glyph) / 2, width: glyph, height: glyph)
        stopGlyph.layer?.applyCorner(base: 2.5, zoom: pageZoom)
        let timeWidth = ceil(timeLabel.fittingSize.width)
        let timeHeight = ceil(timeLabel.fittingSize.height)
        let timeX = bounds.width - side - timeWidth
        timeLabel.frame = NSRect(x: timeX, y: floor((side - timeHeight) / 2), width: timeWidth, height: timeHeight)
        let contentX = inset
        let contentWidth = max(0, timeX - CGFloat(pageZoom.scaled(Space.m)) - contentX)
        let waveHeight = CGFloat(pageZoom.scaled(16))
        waveform.frame = NSRect(x: contentX, y: floor((side - waveHeight) / 2), width: contentWidth, height: waveHeight)
        let statusHeight = ceil(statusLabel.fittingSize.height)
        statusLabel.frame = NSRect(x: contentX, y: floor((side - statusHeight) / 2), width: contentWidth, height: statusHeight)
    }

    // MARK: - Motion

    /// Re-pins the pill after the row lays out. A width change mid-flight only
    /// moves the target; the spring carries on from where it is.
    func place(_ next: Anchor) {
        guard next != anchor else { return }
        anchor = next
        if motionLink == nil { width = isExpanded ? next.expandedWidth : next.height }
        applyGeometry()
    }

    /// Grow out of the mic, or fold back into it. Reduced motion jumps.
    func setExpanded(_ expanded: Bool) {
        if expanded, isHidden {
            width = anchor.height
            velocity = 0
            isHidden = false
        }
        isExpanded = expanded
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || window == nil {
            width = target
            velocity = 0
            settle()
            return
        }
        startMotion()
    }

    private var target: CGFloat { isExpanded ? max(anchor.expandedWidth, anchor.height) : anchor.height }

    private func startMotion() {
        guard motionLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(motionTick(_:)))
        link.add(to: .main, forMode: .common)
        motionLink = link
        lastMotionTick = nil
    }

    @objc private func motionTick(_ link: CADisplayLink) {
        let dt = lastMotionTick.map { min(link.timestamp - $0, 1.0 / 30.0) } ?? (1.0 / 60.0)
        lastMotionTick = link.timestamp
        advanceMotion(by: CGFloat(dt))
    }

    /// One integration step; also driven directly by checks.
    func advanceMotion(by dt: CGFloat) {
        Self.spring.advance(&width, velocity: &velocity, toward: target, dt: dt)
        updateTime()
        if abs(width - target) < 0.5, abs(velocity) < 4 {
            width = target
            velocity = 0
            settle()
        } else {
            applyGeometry()
        }
    }

    private func settle() {
        motionLink?.invalidate()
        motionLink = nil
        applyGeometry()
        if !isExpanded {
            isHidden = true
            reset()
        }
    }

    private func applyGeometry() {
        // The overshoot is allowed past the target (that is the jelly) but
        // never inside the mic's own circle.
        let shown = max(width, anchor.height)
        frame = NSRect(x: anchor.maxX - shown, y: anchor.midY - anchor.height / 2, width: shown, height: anchor.height)
        let span = anchor.expandedWidth - anchor.height
        expansion = span > 0 ? min(max((width - anchor.height) / span, 0), 1) : (isExpanded ? 1 : 0)
        onExpansionChange?(isHidden ? 0 : expansion)
    }

    var qaIsAnimating: Bool { motionLink != nil }

    isolated deinit {
        motionLink?.invalidate()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden || !frame.contains(point) ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        onFinish?()
    }

    override func accessibilityPerformPress() -> Bool {
        onFinish?()
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        let tint = tint ?? AccentToken.accentInput.color.nsColor(for: theme)
        layer?.backgroundColor = AgentSurfaceRole.composer.color.cgColor(for: theme)
        layer?.borderWidth = CGFloat(LineWidth.hairline)
        layer?.borderColor = tint.cgColor
        stopGlyph.layer?.backgroundColor = tint.cgColor
        waveform.barColor = tint
        timeLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        statusLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
    }

    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        statusLabel.font = .token(.caption, zoom: zoom)
        timeLabel.font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.token(.caption, zoom: zoom).pointSize, weight: .medium)
        needsLayout = true
    }

    private func updateContentAlpha() {
        // The stop glyph is there from the first frame: it is what the mic
        // becomes. Everything else waits until there is room to read it.
        let reveal = min(max((expansion - 0.35) / 0.5, 0), 1)
        for view in [waveform, statusLabel, timeLabel] as [NSView] { view.alphaValue = reveal }
    }

    var qaTimeText: String { timeLabel.stringValue }
    var qaStatusText: String? { statusLabel.isHidden ? nil : statusLabel.stringValue }
    var qaStopGlyphFrame: NSRect { stopGlyph.frame }
}

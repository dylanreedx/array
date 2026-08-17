import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// Quiet v2 header for one agent session. It owns only header presentation and
/// its timer; transcript layout never participates in a timer tick.
@MainActor
final class AgentTileHeaderView: NSView, TokenThemed {
    static let stopActionTitle = "Stop agent run"
    static let detachActionTitle = "Detach agent view"

    static var preferredHeight: CGFloat {
        CGFloat(Metrics.rowHeight(for: .title, lines: 2))
    }

    private let nameLabel = NSTextField(labelWithString: "")
    private let stateDot = NSView(frame: .zero)
    private let stateLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let branchChip = BranchChipNSView()
    private let overflowButton = AgentTileOverflowButton()
    private var presentation: AgentTileStatePresenter.Presentation?
    private var elapsedTimer: Timer?

    var onStopAgentRun: (() -> Void)?
    var onDetachView: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        nameLabel.font = .token(.title)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stateDot.wantsLayer = true
        stateDot.layer?.cornerRadius = 3
        stateDot.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.font = .token(.label)
        elapsedLabel.font = .token(.captionMono)
        elapsedLabel.alignment = .left
        elapsedLabel.lineBreakMode = .byClipping
        elapsedLabel.setContentHuggingPriority(.required, for: .horizontal)
        elapsedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        overflowButton.target = self
        overflowButton.action = #selector(showActions(_:))

        let stateRow = NSStackView(views: [stateDot, stateLabel, elapsedLabel])
        stateRow.orientation = .horizontal
        stateRow.alignment = .centerY
        stateRow.spacing = CGFloat(Space.s)

        let identity = NSStackView(views: [nameLabel, stateRow])
        identity.orientation = .vertical
        identity.alignment = .leading
        identity.spacing = CGFloat(Space.xs)

        let row = NSStackView(views: [identity, NSView(), branchChip, overflowButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = CGFloat(Space.m)
        row.edgeInsets = NSEdgeInsets(Inset.row)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            stateDot.widthAnchor.constraint(equalToConstant: 6),
            stateDot.heightAnchor.constraint(equalToConstant: 6),
            elapsedLabel.widthAnchor.constraint(equalToConstant: Self.elapsedColumnWidth),
            overflowButton.widthAnchor.constraint(equalToConstant: 28),
            overflowButton.heightAnchor.constraint(equalToConstant: 28),
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel("Agent session header")
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit { elapsedTimer?.invalidate() }

    func apply(_ next: AgentTileStatePresenter.Presentation) {
        presentation = next
        nameLabel.stringValue = next.name
        stateLabel.stringValue = next.stateLabel
        branchChip.apply(next.branch)
        updateElapsed(now: Date())
        updateTimer(startedAt: next.startedAt)
        overflowButton.stopIsEnabled = next.status == .working || next.status == .needsAttention
        setAccessibilityValue(next.stateAccessibilityLabel)
        applyTokens()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        nameLabel.textColor = TextToken.textPrimary.color.nsColor(for: theme)
        stateLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        elapsedLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        if let status = presentation?.status {
            stateDot.layer?.backgroundColor = StatusChipPresenter.display(for: status).accent.cgColor(for: theme)
        }
        branchChip.applyTokens()
        overflowButton.applyTokens()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    private func updateTimer(startedAt: Date?) {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        guard startedAt != nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateElapsed(now: Date()) }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    /// The header lane measures the rendered prefixed label, not the bare
    /// formatter value. The separator is decorative on screen but still occupies
    /// drawable width, so leaving it out would clip the timer around ten minutes.
    private static var elapsedColumnWidth: CGFloat {
        let font = NSFont.token(.captionMono)
        // Measured over what the formatter EMITS at every branch boundary, prefix
        // included — not over a hand-kept list. An earlier attempt measured the bare
        // forms and clipped a nine-glyph string; the list it measured was also 8pt
        // short of the rendered need, which is exactly the drift a derived set removes.
        let width = AgentElapsedFormatter.widestFormProbes.map { seconds in
            Double(ceil((AgentElapsedFormatter.prefixedLabel(seconds) as NSString)
                .size(withAttributes: [.font: font]).width))
                + Metrics.cellTextInset
        }.max() ?? Metrics.cellTextInset
        return CGFloat(width)
    }

    private func updateElapsed(now: Date) {
        guard let current = presentation,
              let start = current.startedAt else {
            elapsedLabel.stringValue = ""
            elapsedLabel.isHidden = true
            return
        }
        let interval = now.timeIntervalSince(start)
        let seconds = interval.isFinite ? max(0, Int(interval.rounded(.down))) : 0
        let label = AgentElapsedFormatter.elapsedLabel(interval)
        elapsedLabel.stringValue = AgentElapsedFormatter.headerPrefix + label
        elapsedLabel.isHidden = false
        // Keep the spoken value free of the decorative separator. The numeric
        // duration remains live on each tick; the bounded formatter owns the visual
        // lane rather than replacing the established accessibility vocabulary.
        setAccessibilityValue("\(current.stateLabel), \(seconds) seconds elapsed")
        // Deliberately no `needsLayout`: the mono label has stable reserved width,
        // and a timer tick must not invalidate the transcript below this view.
    }

    @objc private func showActions(_ sender: Any?) {
        let menu = NSMenu(title: "Agent actions")
        let stop = NSMenuItem(title: Self.stopActionTitle, action: #selector(stopAgentRun(_:)), keyEquivalent: "")
        stop.target = self
        stop.isEnabled = overflowButton.stopIsEnabled
        menu.addItem(stop)
        menu.addItem(.separator())
        let detach = NSMenuItem(title: Self.detachActionTitle, action: #selector(detachView(_:)), keyEquivalent: "")
        detach.target = self
        menu.addItem(detach)
        menu.popUp(positioning: nil, at: NSPoint(x: overflowButton.bounds.maxX, y: overflowButton.bounds.maxY), in: overflowButton)
    }

    @objc private func stopAgentRun(_ sender: Any?) { onStopAgentRun?() }
    @objc private func detachView(_ sender: Any?) { onDetachView?() }

    var qaName: String { nameLabel.stringValue }
    var qaState: String { stateLabel.stringValue }
    var qaElapsed: String? { elapsedLabel.isHidden ? nil : elapsedLabel.stringValue }
    var qaBranch: String? { branchChip.isHidden ? nil : branchChip.qaText }
    var qaActionTitles: [String] { [Self.stopActionTitle, Self.detachActionTitle] }
    var qaUsesCustomOverflow: Bool { overflowButton.subviews.allSatisfy { !($0 is NSButton) } }
    var qaBranchIsWarning: Bool { !branchChip.isHidden && branchChip.qaIsWarning }
    var qaBranchTooltip: String? { branchChip.isHidden ? nil : branchChip.toolTip }
    var qaTimerIsActive: Bool { elapsedTimer?.isValid == true }
    // Geometry probes read shell-space frames so lane assertions compare like
    // coordinates regardless of the internal stack nesting.
    var qaNameFrame: NSRect? { nameLabel.superview.map { $0.convert(nameLabel.frame, to: self) } }
    var qaOverflowFrame: NSRect? { overflowButton.superview.map { $0.convert(overflowButton.frame, to: self) } }
    var qaElapsedFrame: NSRect? { elapsedLabel.superview.map { $0.convert(elapsedLabel.frame, to: self) } }

    /// Deterministic action/timer seams used by the existing supervisor check.
    /// They invoke the same callbacks as the production menu items and drive the
    /// same elapsed-label update as the one-second timer; no parallel QA behavior.
    func qaInvokeStopAction() { stopAgentRun(nil) }
    func qaInvokeDetachAction() { detachView(nil) }
    func qaTick(now: Date) { updateElapsed(now: now) }
}

/// NSControl supplies target/action, keyboard focus and accessibility without
/// leaking an Aqua button bezel into the header.
@MainActor
private final class AgentTileOverflowButton: NSControl, TokenThemed {
    private let imageView = NSImageView(frame: .zero)
    var stopIsEnabled = false
    private var isPressed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.image = CanvasSymbolImage.image(named: "ellipsis")
        imageView.imageScaling = .scaleProportionallyDown
        addSubview(imageView)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Agent actions")
        setAccessibilityHelp("Stop the running agent process or detach this view. Detaching does not stop, archive, or delete the agent.")
        toolTip = "Agent actions"
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        imageView.frame = bounds.insetBy(dx: 7, dy: 7)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        applyTokens()
        defer { isPressed = false; applyTokens() }
        _ = sendAction(action, to: target)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 {
            _ = sendAction(action, to: target)
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard window?.firstResponder === self else { return }
        AgentLineRole.focusRing.color.nsColor(in: self).setStroke()
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: CGFloat(Radius.card), yRadius: CGFloat(Radius.card))
        ring.lineWidth = 2
        ring.stroke()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        imageView.contentTintColor = TextToken.textSecondary.color.nsColor(for: theme)
        alphaValue = isPressed ? 0.72 : 1
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        applyTokens()
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        applyTokens()
        return result
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }
}

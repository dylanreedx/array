import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

@MainActor
final class AgentSignalBadgeView: NSView, AgentPageZoomScalable {
    private var pageZoom: AgentPageZoom = .default
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?

    private func updateSize() {
        invalidateIntrinsicContentSize()
        widthConstraint?.constant = intrinsicContentSize.width
        heightConstraint?.constant = intrinsicContentSize.height
        needsLayout = true
    }

    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        label.font = .monospacedSystemFont(ofSize: CGFloat(zoom.scaled(10)), weight: .semibold)
        layer?.cornerRadius = CGFloat(zoom.scaled(11))
        updateSize()
    }
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private(set) var signal: AgentSignal?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.borderWidth = 1
        icon.imageScaling = .scaleProportionallyDown
        label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        addSubview(icon)
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint = widthAnchor.constraint(equalToConstant: intrinsicContentSize.width)
        heightConstraint = heightAnchor.constraint(equalToConstant: intrinsicContentSize.height)
        widthConstraint?.isActive = true
        heightConstraint?.isActive = true
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: pageZoom.scaled(7), y: pageZoom.scaled(4), width: pageZoom.scaled(14), height: pageZoom.scaled(14))
        label.frame = NSRect(x: pageZoom.scaled(25), y: pageZoom.scaled(3), width: max(0, bounds.width - pageZoom.scaled(31)), height: pageZoom.scaled(16))
    }

    override var intrinsicContentSize: NSSize {
        // Cell measurement includes NSTextField's text insets. Glyph width
        // alone truncates even short labels such as “Merged”.
        NSSize(width: ceil(label.cell?.cellSize.width ?? 0) + CGFloat(pageZoom.scaled(32)), height: CGFloat(pageZoom.scaled(22)))
    }

    var qaTextFits: Bool { label.frame.width + 0.5 >= (label.cell?.cellSize.width ?? 0) }

    func apply(_ signal: AgentSignal?) {
        self.signal = signal
        defer { updateSize() }
        guard let signal else {
            isHidden = true
            setAccessibilityLabel(nil)
            return
        }
        isHidden = false
        label.stringValue = signal.kind.displayName
        icon.image = NSImage(systemSymbolName: signal.kind.symbolName, accessibilityDescription: signal.kind.displayName)
        let color = Self.color(for: signal.kind)
        label.textColor = color
        icon.contentTintColor = color
        layer?.borderColor = color.withAlphaComponent(0.72).cgColor
        layer?.backgroundColor = color.withAlphaComponent(0.12).cgColor
        setAccessibilityLabel("Agent status: \(signal.kind.displayName)")
    }

    static func color(for kind: AgentSignalKind) -> NSColor {
        switch kind {
        case .actionRequired: return .systemOrange
        case .failed: return .systemRed
        case .completed: return .systemGreen
        case .gitPushSucceeded: return .systemBlue
        case .gitMergeSucceeded: return .systemPurple
        }
    }
}

@MainActor
final class AgentSignalBorderView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 2
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ signal: AgentSignal?) {
        // Any incoming signal supersedes an acknowledgment in flight: a failure or
        // an action request landing mid-glow must own the border immediately, and
        // must not have its treatment torn down by the glow's own expiry.
        cancelCompletionAcknowledgment()
        guard let signal else { isHidden = true; return }
        let color = AgentSignalBadgeView.color(for: signal.kind)
        layer?.borderColor = color.withAlphaComponent(0.86).cgColor
        layer?.shadowColor = color.cgColor
        layer?.shadowOpacity = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
        layer?.shadowRadius = 7
        layer?.shadowOffset = .zero
        isHidden = false
    }

    // MARK: - WS4 · the finite completion acknowledgment

    /// Where one acknowledgment generation stands.
    ///
    /// `finished` is a distinct state from `idle` on purpose: a witness must be
    /// able to prove the glow ENDED, and "never started" and "started and stopped"
    /// are otherwise indistinguishable from the resting appearance alone.
    enum CompletionAcknowledgmentPhase: String {
        case idle
        case acknowledging
        case finished
    }

    private static let acknowledgmentAnimationKey = "ws4.completionAcknowledgment"

    private(set) var completionAcknowledgmentPhase: CompletionAcknowledgmentPhase = .idle
    /// Monotonic; a late expiry from a superseded generation is ignored.
    private(set) var completionAcknowledgmentGeneration: UInt64 = 0
    private(set) var qaAcknowledgmentsStarted = 0
    /// The plan the production path actually used for the current generation.
    private(set) var qaAcknowledgmentPlan: AgentCompletionAcknowledgmentPlan?
    private(set) var qaAcknowledgmentsFinished = 0
    private var acknowledgmentExpiry: DispatchWorkItem?

    /// Live CoreAnimation count. Zero at rest is the assertion that nothing is
    /// still running — including under Reduce Motion, where it must be zero
    /// throughout.
    var qaActiveAnimationCount: Int { layer?.animationKeys()?.count ?? 0 }
    /// Whether a bounded expiry is still scheduled. There is at most one, and it
    /// is a one-shot `DispatchWorkItem` — never a repeating `Timer`.
    var qaHasScheduledAcknowledgmentWork: Bool { acknowledgmentExpiry != nil }

    /// The live pulse's own schedule, read back off the layer. `repeatCount` must
    /// be a finite count, never `.infinity`, and the cycles must add up to exactly
    /// the plan's duration — this is what makes "the pulse is finite" an assertion
    /// about the animation rather than about the observing loop's latency, which
    /// in a busy check process is not a reliable clock.
    var qaAcknowledgmentAnimationRepeatCount: Float? {
        (layer?.animation(forKey: Self.acknowledgmentAnimationKey) as? CABasicAnimation)?.repeatCount
    }
    var qaAcknowledgmentAnimationTotalDuration: TimeInterval? {
        guard let animation = layer?.animation(forKey: Self.acknowledgmentAnimationKey) as? CABasicAnimation
        else { return nil }
        return animation.duration * Double(animation.repeatCount) * (animation.autoreverses ? 2 : 1)
    }

    /// Play one bounded acknowledgment, then return to the ordinary read
    /// appearance. The plan carries the whole shape (`AgentCompletionAcknowledgmentPlan`);
    /// Reduce Motion arrives here as a zero-pulse plan of the same duration, so the
    /// static and animated paths share one generation, one expiry and one teardown.
    func beginCompletionAcknowledgment(_ plan: AgentCompletionAcknowledgmentPlan) {
        cancelCompletionAcknowledgment()
        completionAcknowledgmentGeneration &+= 1
        qaAcknowledgmentsStarted += 1
        let generation = completionAcknowledgmentGeneration
        completionAcknowledgmentPhase = .acknowledging
        qaAcknowledgmentPlan = plan

        let color = AgentSignalBadgeView.color(for: .completed)
        layer?.borderColor = color.withAlphaComponent(0.9).cgColor
        layer?.shadowColor = color.cgColor
        layer?.shadowRadius = 7
        layer?.shadowOffset = .zero
        // Static acknowledgment carries no shadow at all: under Reduce Motion the
        // treatment must read from the border and symbol, not from a glow whose
        // whole purpose was motion.
        layer?.shadowOpacity = plan.isStatic ? 0 : 0.35
        isHidden = false

        if !plan.isStatic, plan.pulseCount > 0, let layer {
            let pulse = CABasicAnimation(keyPath: "shadowOpacity")
            pulse.fromValue = 0.35
            pulse.toValue = 0.05
            // FINITE: `repeatCount` is the pulse count, never `.infinity`, and the
            // per-cycle duration is derived so the total is exactly the plan's.
            pulse.duration = plan.duration / Double(plan.pulseCount * 2)
            pulse.autoreverses = true
            pulse.repeatCount = Float(plan.pulseCount)
            pulse.isRemovedOnCompletion = true
            layer.add(pulse, forKey: Self.acknowledgmentAnimationKey)
        }

        let expiry = DispatchWorkItem { [weak self] in
            guard let self, self.completionAcknowledgmentGeneration == generation else { return }
            self.finishCompletionAcknowledgment()
        }
        acknowledgmentExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + plan.duration, execute: expiry)
    }

    /// The end state: no animation, no scheduled work, ordinary read appearance.
    private func finishCompletionAcknowledgment() {
        acknowledgmentExpiry = nil
        layer?.removeAllAnimations()
        layer?.shadowOpacity = 0
        isHidden = true
        completionAcknowledgmentPhase = .finished
        qaAcknowledgmentsFinished += 1
    }

    /// Superseded or unmounted. Distinct from expiry: nothing "finished", so the
    /// finished counter does not move and a witness cannot mistake a cancellation
    /// for a completed generation.
    func cancelCompletionAcknowledgment() {
        guard acknowledgmentExpiry != nil || completionAcknowledgmentPhase == .acknowledging else { return }
        acknowledgmentExpiry?.cancel()
        acknowledgmentExpiry = nil
        layer?.removeAllAnimations()
        completionAcknowledgmentPhase = .idle
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // An unmounted tile must not leave a timer or an animation behind.
        if window == nil { cancelCompletionAcknowledgment() }
    }
}

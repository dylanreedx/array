import AppKit
import ContinuumRevivedAgentUI
import QuartzCore

/// Orbit Variation 4 — Solar Handoff.
///
/// A compact three-node Core Animation thinking indicator. The nodes remain on a
/// restrained, slightly off-axis orbit; a brief 120° handoff warms the node that
/// reaches the upper-right highlight angle while the previous lead decays. The
/// center aura is deliberately tiny and decorative, never a warning/error cue.
@MainActor
final class SolarHandoffOrbitThinkingIndicatorView: NSView, AgentThinkingIndicatorAnimating {
    struct QANodeState: Equatable {
        let index: Int
        let center: CGPoint
        let scale: CGFloat
        let opacity: Float
        let handoffWarmth: CGFloat
    }

    private enum Metrics {
        static let side: CGFloat = 18
        static let nodeDiameter: CGFloat = 3.2
        static let centerAuraDiameter: CGFloat = 4.6
        static let orbitXRadius: CGFloat = 5.25
        static let orbitYRadius: CGFloat = 4.35
        static let orbitDuration: CFTimeInterval = 1.44
        static let centerAuraBaseOpacity: Float = 0.13
        static let highlightAngle: CGFloat = -.pi / 4
        static let sampleCount = 36
        static let baseAngles: [CGFloat] = [
            highlightAngle,
            highlightAngle - (2 * .pi / 3),
            highlightAngle - (4 * .pi / 3),
        ]
    }

    private enum AnimationKey {
        static let orbit = "solarHandoff.orbit"
        static let nodeScalePrefix = "solarHandoff.node.scale."
        static let nodeOpacityPrefix = "solarHandoff.node.opacity."
        static let nodeWarmthPrefix = "solarHandoff.node.warmth."
        static let auraOpacity = "solarHandoff.aura.opacity"
        static let auraScale = "solarHandoff.aura.scale"
    }

    private struct NodeModelState {
        let scale: CGFloat
        let opacity: Float
        let handoffWarmth: CGFloat
    }

    private struct TokenPalette {
        let base: CGColor
        let lead: CGColor
        let aura: CGColor
    }

    private struct NodeLayerSet {
        let container = CALayer()
        let base = CAShapeLayer()
        let warm = CAShapeLayer()
    }

    private let orbitLayer = CALayer()
    private let centerAuraLayer = CAShapeLayer()
    private let nodeLayers: [NodeLayerSet]
    private var animationRequested = false
    private var reducedMotionEnabled: Bool
    private var snapshotPhase: CGFloat = 0

    override var intrinsicContentSize: NSSize {
        NSSize(width: Metrics.side, height: Metrics.side)
    }

    override var isHidden: Bool {
        didSet { reconcileAnimationState() }
    }

    init(reducedMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        self.reducedMotionEnabled = reducedMotion
        self.nodeLayers = (0..<3).map { _ in NodeLayerSet() }
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: Metrics.side, height: Metrics.side)))

        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)

        configureLayerTree()
        applyModelLayerState(for: snapshotPhase)
        configureAccessibility(animated: false)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        applyModelLayerState(for: snapshotPhase)
        reconcileAnimationState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
        reconcileAnimationState()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        reconcileAnimationState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyModelLayerState(for: snapshotPhase)
        if animationRequested, canAnimate {
            removeAnimations()
            installAnimations()
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        reconcileAnimationState()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        reconcileAnimationState()
    }

    func startAnimating() {
        animationRequested = true
        configureAccessibility(animated: !reducedMotionEnabled)
        reconcileAnimationState()
    }

    func stopAnimating() {
        animationRequested = false
        removeAnimations()
        applyModelLayerState(for: snapshotPhase)
        configureAccessibility(animated: false)
    }

    func setReducedMotion(_ enabled: Bool) {
        guard reducedMotionEnabled != enabled else { return }
        reducedMotionEnabled = enabled
        removeAnimations()
        applyModelLayerState(for: snapshotPhase)
        configureAccessibility(animated: animationRequested && !enabled)
        reconcileAnimationState()
    }

    /// Pins a deterministic model-layer pose. The same `state(for:nodeIndex:)`
    /// function feeds both snapshots and the CA keyframe values, so snapshot review
    /// can inspect the actual timing curve without depending on wall-clock time.
    func setSnapshotPhase(_ phase: CGFloat) {
        animationRequested = false
        snapshotPhase = Self.normalizedPhase(phase)
        removeAnimations()
        applyModelLayerState(for: snapshotPhase)
        configureAccessibility(animated: false)
    }

    private var canAnimate: Bool {
        animationRequested
            && !reducedMotionEnabled
            && window != nil
            && !isHiddenOrHasHiddenAncestor
            && bounds.width > 0
            && bounds.height > 0
    }

    private func configureLayerTree() {
        let disabledActions: [String: CAAction] = [
            "backgroundColor": NSNull(),
            "bounds": NSNull(),
            "fillColor": NSNull(),
            "frame": NSNull(),
            "opacity": NSNull(),
            "path": NSNull(),
            "position": NSNull(),
            "shadowColor": NSNull(),
            "transform": NSNull(),
        ]

        layer?.actions = disabledActions
        orbitLayer.actions = disabledActions
        centerAuraLayer.actions = disabledActions
        centerAuraLayer.fillRule = .nonZero

        layer?.addSublayer(centerAuraLayer)
        layer?.addSublayer(orbitLayer)

        for node in nodeLayers {
            node.container.actions = disabledActions
            node.base.actions = disabledActions
            node.warm.actions = disabledActions
            node.base.fillRule = .nonZero
            node.warm.fillRule = .nonZero
            node.container.addSublayer(node.base)
            node.container.addSublayer(node.warm)
            orbitLayer.addSublayer(node.container)
        }
        updateContentsScale()
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        centerAuraLayer.contentsScale = scale
        nodeLayers.forEach {
            $0.base.contentsScale = scale
            $0.warm.contentsScale = scale
        }
    }

    private func reconcileAnimationState() {
        guard canAnimate else {
            removeAnimations()
            applyModelLayerState(for: snapshotPhase)
            return
        }
        installAnimationsIfNeeded()
    }

    private func installAnimationsIfNeeded() {
        guard orbitLayer.animation(forKey: AnimationKey.orbit) == nil else { return }
        installAnimations()
    }

    private func installAnimations() {
        removeAnimations()
        applyModelLayerState(for: snapshotPhase)

        let fromAngle = snapshotPhase * 2 * .pi
        let orbit = CABasicAnimation(keyPath: "transform.rotation.z")
        orbit.fromValue = fromAngle
        orbit.toValue = fromAngle + (2 * .pi)
        orbit.duration = Metrics.orbitDuration
        orbit.repeatCount = .infinity
        orbit.timingFunction = CAMediaTimingFunction(name: .linear)
        orbit.isRemovedOnCompletion = false
        orbitLayer.add(orbit, forKey: AnimationKey.orbit)

        let phases = Self.animationSamplePhases(startingAt: snapshotPhase)
        let keyTimes = Self.animationKeyTimes()
        let softTiming = Array(
            repeating: CAMediaTimingFunction(controlPoints: 0.42, 0.0, 0.58, 1.0),
            count: max(0, phases.count - 1)
        )

        for (index, node) in nodeLayers.enumerated() {
            let states = phases.map { Self.state(for: $0, nodeIndex: index) }

            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = states.map(\.scale)
            scale.keyTimes = keyTimes
            scale.timingFunctions = softTiming
            configureRepeating(scale)
            node.container.add(scale, forKey: AnimationKey.nodeScalePrefix + String(index))

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = states.map(\.opacity)
            opacity.keyTimes = keyTimes
            opacity.timingFunctions = softTiming
            configureRepeating(opacity)
            node.container.add(opacity, forKey: AnimationKey.nodeOpacityPrefix + String(index))

            let warmth = CAKeyframeAnimation(keyPath: "opacity")
            warmth.values = states.map { Float($0.handoffWarmth) }
            warmth.keyTimes = keyTimes
            warmth.timingFunctions = softTiming
            configureRepeating(warmth)
            node.warm.add(warmth, forKey: AnimationKey.nodeWarmthPrefix + String(index))
        }

        let auraStates = phases.map(Self.centerAuraState(for:))

        let auraOpacity = CAKeyframeAnimation(keyPath: "opacity")
        auraOpacity.values = auraStates.map(\.opacity)
        auraOpacity.keyTimes = keyTimes
        auraOpacity.timingFunctions = softTiming
        configureRepeating(auraOpacity)
        centerAuraLayer.add(auraOpacity, forKey: AnimationKey.auraOpacity)

        let auraScale = CAKeyframeAnimation(keyPath: "transform.scale")
        auraScale.values = auraStates.map(\.scale)
        auraScale.keyTimes = keyTimes
        auraScale.timingFunctions = softTiming
        configureRepeating(auraScale)
        centerAuraLayer.add(auraScale, forKey: AnimationKey.auraScale)
    }

    private func configureRepeating(_ animation: CAAnimation) {
        animation.duration = Metrics.orbitDuration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
    }

    private func removeAnimations() {
        orbitLayer.removeAnimation(forKey: AnimationKey.orbit)
        centerAuraLayer.removeAnimation(forKey: AnimationKey.auraOpacity)
        centerAuraLayer.removeAnimation(forKey: AnimationKey.auraScale)
        for index in nodeLayers.indices {
            nodeLayers[index].container.removeAnimation(forKey: AnimationKey.nodeScalePrefix + String(index))
            nodeLayers[index].container.removeAnimation(forKey: AnimationKey.nodeOpacityPrefix + String(index))
            nodeLayers[index].warm.removeAnimation(forKey: AnimationKey.nodeWarmthPrefix + String(index))
        }
    }

    private func applyModelLayerState(for phase: CGFloat) {
        let normalized = Self.normalizedPhase(phase)
        let side = max(1, min(bounds.width > 0 ? bounds.width : Metrics.side, bounds.height > 0 ? bounds.height : Metrics.side))
        let localBounds = CGRect(x: 0, y: 0, width: side, height: side)
        let viewCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        let localCenter = CGPoint(x: localBounds.midX, y: localBounds.midY)
        let nodeBounds = CGRect(x: 0, y: 0, width: Metrics.nodeDiameter, height: Metrics.nodeDiameter)
        let auraBounds = CGRect(x: 0, y: 0, width: Metrics.centerAuraDiameter, height: Metrics.centerAuraDiameter)
        let auraState = Self.centerAuraState(for: normalized)
        let palette = Self.palette(for: effectiveTokenTheme)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        orbitLayer.bounds = localBounds
        orbitLayer.position = viewCenter
        orbitLayer.transform = CATransform3DMakeRotation(normalized * 2 * .pi, 0, 0, 1)

        centerAuraLayer.bounds = auraBounds
        centerAuraLayer.position = viewCenter
        centerAuraLayer.path = CGPath(ellipseIn: auraBounds, transform: nil)
        centerAuraLayer.fillColor = palette.aura
        centerAuraLayer.opacity = reducedMotionEnabled ? Metrics.centerAuraBaseOpacity : auraState.opacity
        centerAuraLayer.transform = reducedMotionEnabled ? CATransform3DIdentity : CATransform3DMakeScale(auraState.scale, auraState.scale, 1)

        for (index, node) in nodeLayers.enumerated() {
            let state = Self.state(for: normalized, nodeIndex: index)
            node.container.bounds = nodeBounds
            node.container.position = CGPoint(
                x: localCenter.x + cos(Metrics.baseAngles[index]) * Metrics.orbitXRadius,
                y: localCenter.y + sin(Metrics.baseAngles[index]) * Metrics.orbitYRadius
            )
            node.container.opacity = state.opacity
            node.container.transform = CATransform3DMakeScale(state.scale, state.scale, 1)

            for layer in [node.base, node.warm] {
                layer.bounds = nodeBounds
                layer.position = CGPoint(x: nodeBounds.midX, y: nodeBounds.midY)
                layer.path = CGPath(ellipseIn: nodeBounds, transform: nil)
            }
            node.base.fillColor = palette.base
            node.base.opacity = 1
            node.warm.fillColor = palette.lead
            node.warm.opacity = Float(state.handoffWarmth)
        }

        CATransaction.commit()
        setAccessibilityValue(Self.accessibilityValue(for: normalized))
    }

    private static func palette(for theme: TokenTheme) -> TokenPalette {
        TokenPalette(
            base: AccentToken.accentWorking.color.cgColor(for: theme),
            lead: AccentToken.accentInput.color.cgColor(for: theme),
            aura: AccentToken.accentWorking.color.cgColor(for: theme)
        )
    }

    private static func state(for phase: CGFloat, nodeIndex: Int) -> NodeModelState {
        let normalized = normalizedPhase(phase)
        let nodePhase = CGFloat(nodeIndex) / 3
        let age = positiveUnitDistance(from: nodePhase, to: normalized)
        let pulse = highlightPulse(forSignedDistance: signedUnitDistance(from: nodePhase, to: normalized))

        let baselineOpacity: CGFloat
        let baselineScale: CGFloat
        switch age {
        case 0..<(1.0 / 3.0):
            let decay = smoothstep(age / (1.0 / 3.0))
            baselineOpacity = interpolate(from: 0.82, to: 0.62, amount: decay)
            baselineScale = interpolate(from: 0.98, to: 0.90, amount: decay)
        case (2.0 / 3.0)..<1:
            let approach = smoothstep((age - (2.0 / 3.0)) / (1.0 / 3.0))
            baselineOpacity = interpolate(from: 0.46, to: 0.76, amount: approach)
            baselineScale = interpolate(from: 0.82, to: 0.96, amount: approach)
        default:
            let trail = smoothstep((age - (1.0 / 3.0)) / (1.0 / 3.0))
            baselineOpacity = interpolate(from: 0.52, to: 0.43, amount: trail)
            baselineScale = interpolate(from: 0.86, to: 0.80, amount: trail)
        }

        return NodeModelState(
            scale: min(1.14, baselineScale + (0.16 * pulse)),
            opacity: Float(min(1, baselineOpacity + (0.18 * pulse))),
            handoffWarmth: pulse
        )
    }

    private static func centerAuraState(for phase: CGFloat) -> (opacity: Float, scale: CGFloat) {
        let strongestPulse = (0..<3)
            .map { highlightPulse(forSignedDistance: signedUnitDistance(from: CGFloat($0) / 3, to: normalizedPhase(phase))) }
            .max() ?? 0
        return (
            opacity: Float(CGFloat(Metrics.centerAuraBaseOpacity) + (0.035 * strongestPulse)),
            scale: 0.965 + (0.055 * strongestPulse)
        )
    }

    private static func highlightPulse(forSignedDistance distance: CGFloat) -> CGFloat {
        if distance < 0 {
            return smoothstep((distance + 0.11) / 0.11)
        }
        return 1 - smoothstep(distance / 0.17)
    }

    private static func animationSamplePhases(startingAt phase: CGFloat) -> [CGFloat] {
        (0...Metrics.sampleCount).map { index in
            normalizedPhase(phase + CGFloat(index) / CGFloat(Metrics.sampleCount))
        }
    }

    private static func animationKeyTimes() -> [NSNumber] {
        (0...Metrics.sampleCount).map { NSNumber(value: Double($0) / Double(Metrics.sampleCount)) }
    }

    private static func normalizedPhase(_ phase: CGFloat) -> CGFloat {
        guard phase.isFinite else { return 0 }
        let remainder = phase.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }

    private static func positiveUnitDistance(from start: CGFloat, to end: CGFloat) -> CGFloat {
        normalizedPhase(end - start)
    }

    private static func signedUnitDistance(from start: CGFloat, to end: CGFloat) -> CGFloat {
        var distance = normalizedPhase(end - start)
        if distance > 0.5 { distance -= 1 }
        return distance
    }

    private static func smoothstep(_ value: CGFloat) -> CGFloat {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - (2 * clamped))
    }

    private static func interpolate(from start: CGFloat, to end: CGFloat, amount: CGFloat) -> CGFloat {
        start + ((end - start) * min(max(amount, 0), 1))
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        setReducedMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func configureAccessibility(animated: Bool) {
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(animated ? "Agent thinking, solar handoff orbit" : "Agent thinking, solar handoff orbit, paused")
        setAccessibilityHelp("Three orbiting nodes pass a restrained idea highlight around the system.")
        setAccessibilityValue(Self.accessibilityValue(for: snapshotPhase))
    }

    private static func accessibilityValue(for phase: CGFloat) -> String {
        let leadIndex = Int(floor(normalizedPhase(phase) * 3)).clamped(to: 0...2) + 1
        return "node \(leadIndex) leading"
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

@MainActor
extension SolarHandoffOrbitThinkingIndicatorView {
    var qaActiveAnimationCount: Int {
        var count = orbitLayer.animation(forKey: AnimationKey.orbit) == nil ? 0 : 1
        count += centerAuraLayer.animation(forKey: AnimationKey.auraOpacity) == nil ? 0 : 1
        count += centerAuraLayer.animation(forKey: AnimationKey.auraScale) == nil ? 0 : 1
        for index in nodeLayers.indices {
            count += nodeLayers[index].container.animation(forKey: AnimationKey.nodeScalePrefix + String(index)) == nil ? 0 : 1
            count += nodeLayers[index].container.animation(forKey: AnimationKey.nodeOpacityPrefix + String(index)) == nil ? 0 : 1
            count += nodeLayers[index].warm.animation(forKey: AnimationKey.nodeWarmthPrefix + String(index)) == nil ? 0 : 1
        }
        return count
    }

    var qaSnapshotPhase: CGFloat { snapshotPhase }
    var qaOrbitDuration: CFTimeInterval { Metrics.orbitDuration }
    var qaAnimationSampleCount: Int { Metrics.sampleCount }

    var qaNodeStates: [QANodeState] {
        Self.qaNodeStates(for: snapshotPhase)
    }

    static func qaNodeStates(for phase: CGFloat) -> [QANodeState] {
        let normalized = normalizedPhase(phase)
        let side = Metrics.side
        let center = CGPoint(x: side / 2, y: side / 2)
        return nodeModels(for: normalized).map { index, state in
            let unrotated = CGPoint(
                x: center.x + cos(Metrics.baseAngles[index]) * Metrics.orbitXRadius,
                y: center.y + sin(Metrics.baseAngles[index]) * Metrics.orbitYRadius
            )
            let angle = normalized * 2 * .pi
            let dx = unrotated.x - center.x
            let dy = unrotated.y - center.y
            return QANodeState(
                index: index,
                center: CGPoint(
                    x: center.x + (dx * cos(angle)) - (dy * sin(angle)),
                    y: center.y + (dx * sin(angle)) + (dy * cos(angle))
                ),
                scale: state.scale,
                opacity: state.opacity,
                handoffWarmth: state.handoffWarmth
            )
        }
    }

    private static func nodeModels(for phase: CGFloat) -> [(Int, NodeModelState)] {
        (0..<3).map { ($0, state(for: phase, nodeIndex: $0)) }
    }
}

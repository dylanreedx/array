import AppKit
import QuartzCore
import ContinuumRevivedAgentUI

/// Orbit variation 1: a chromatic relay on the familiar three-node orbit.
///
/// The geometry intentionally stays close to `OrbitingTriadThinkingIndicatorView`:
/// three circular nodes ride a clean circular plane inside an 18×18 footprint.
/// The variation's extra energy comes from compositor-owned layer animations
/// that relay colour, opacity, and a tiny scale emphasis from node to node.
@MainActor
final class ChromaticRelayOrbitThinkingIndicatorView: NSView, AgentThinkingIndicatorAnimating {
    private enum Metrics {
        static let side: CGFloat = 18
        static let orbitRadiusRatio: CGFloat = 0.31
        static let minimumOrbitRadius: CGFloat = 2
        static let orbitDuration: CFTimeInterval = 1.05
        static let nodeDiameter: CGFloat = 3.2
        static let leadScale: CGFloat = 1.16
        static let midScale: CGFloat = 1.0
        static let trailScale: CGFloat = 0.88
        static let leadOpacity: CGFloat = 1.0
        static let midOpacity: CGFloat = CGFloat(Opacity.receded)
        static let trailOpacity: CGFloat = 0.68
    }

    private enum AnimationKey {
        static let orbit = "chromaticRelayOrbit.orbit"
        static let fill = "chromaticRelayOrbit.fill"
        static let opacity = "chromaticRelayOrbit.opacity"
        static let scale = "chromaticRelayOrbit.scale"
    }

    private enum RelayRole {
        case lead
        case mid
        case trail
    }

    private struct NodeStyle {
        let fillColor: CGColor
        let opacity: CGFloat
        let scale: CGFloat
    }

    private static let baseAngles: [CGFloat] = [
        -.pi / 2,
        -.pi / 2 - (2 * .pi / 3),
        -.pi / 2 - (4 * .pi / 3),
    ]
    private static let relayKeyTimes: [CGFloat] = [0, 1 / 3, 2 / 3, 1]

    private let glyphLayer = CALayer()
    private let orbitLayer = CALayer()
    private let nodeLayers: [CAShapeLayer]

    private var animationRequested = false
    private var reducedMotionEnabled: Bool
    private var currentSnapshotPhase: CGFloat = 0

    override var intrinsicContentSize: NSSize {
        NSSize(width: Metrics.side, height: Metrics.side)
    }

    override var isHidden: Bool {
        didSet { reconcileAnimationState() }
    }

    init(reducedMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        self.reducedMotionEnabled = reducedMotion
        self.nodeLayers = (0..<Self.baseAngles.count).map { _ in
            let layer = CAShapeLayer()
            let bounds = CGRect(x: 0, y: 0, width: Metrics.nodeDiameter, height: Metrics.nodeDiameter)
            layer.bounds = bounds
            layer.path = CGPath(ellipseIn: bounds, transform: nil)
            return layer
        }
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: Metrics.side, height: Metrics.side)))

        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)

        configureLayerTree()
        applySnapshotModel(phase: currentSnapshotPhase)
        configureAccessibility(label: Self.accessibilityLabel(animated: false, phase: currentSnapshotPhase))

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        applySnapshotModel(phase: currentSnapshotPhase)
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
        let wasAnimating = qaActiveAnimationCount > 0
        removeCompositorAnimations()
        applySnapshotModel(phase: currentSnapshotPhase)
        if wasAnimating { startCompositorAnimationsIfNeeded() }
    }

    func startAnimating() {
        animationRequested = true
        configureAccessibility(label: reducedMotionEnabled
            ? Self.accessibilityLabel(animated: false, phase: currentSnapshotPhase)
            : "Agent thinking, chromatic relay orbit")
        reconcileAnimationState()
    }

    func stopAnimating() {
        animationRequested = false
        removeCompositorAnimations()
        applySnapshotModel(phase: currentSnapshotPhase)
        configureAccessibility(label: Self.accessibilityLabel(animated: false, phase: currentSnapshotPhase))
    }

    func setReducedMotion(_ enabled: Bool) {
        guard reducedMotionEnabled != enabled else { return }
        reducedMotionEnabled = enabled
        if enabled {
            removeCompositorAnimations()
            applySnapshotModel(phase: currentSnapshotPhase)
            configureAccessibility(label: Self.accessibilityLabel(animated: false, phase: currentSnapshotPhase))
        } else {
            reconcileAnimationState()
        }
    }

    /// Pins a deterministic model-layer pose for static review. This deliberately
    /// removes active CA animations; `startAnimating()` is the explicit way back
    /// to live compositor motion.
    func setSnapshotPhase(_ phase: CGFloat) {
        animationRequested = false
        currentSnapshotPhase = Self.normalized(phase)
        removeCompositorAnimations()
        applySnapshotModel(phase: currentSnapshotPhase)
        configureAccessibility(label: Self.accessibilityLabel(animated: false, phase: currentSnapshotPhase))
    }

    private var tokenTheme: TokenTheme {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    private func configureLayerTree() {
        let disabledActions: [String: CAAction] = [
            "bounds": NSNull(),
            "position": NSNull(),
            "path": NSNull(),
            "transform": NSNull(),
            "opacity": NSNull(),
            "fillColor": NSNull(),
            "backgroundColor": NSNull(),
        ]

        glyphLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        glyphLayer.actions = disabledActions
        orbitLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        orbitLayer.actions = disabledActions
        layer?.actions = disabledActions
        layer?.masksToBounds = false
        layer?.addSublayer(glyphLayer)
        glyphLayer.addSublayer(orbitLayer)

        nodeLayers.forEach { node in
            node.actions = disabledActions
            node.contentsScale = backingScale
            orbitLayer.addSublayer(node)
        }
    }

    private func updateContentsScale() {
        let scale = backingScale
        CATransaction.withoutActions {
            nodeLayers.forEach { $0.contentsScale = scale }
        }
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func applySnapshotModel(phase: CGFloat) {
        let side = max(1, min(bounds.width, bounds.height))
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let localBounds = CGRect(x: 0, y: 0, width: side, height: side)
        let localCenter = CGPoint(x: localBounds.midX, y: localBounds.midY)
        let orbitRadius = max(Metrics.minimumOrbitRadius, floor(side * Metrics.orbitRadiusRatio))
        let angle = -Self.normalized(phase) * 2 * .pi

        CATransaction.withoutActions {
            glyphLayer.bounds = localBounds
            glyphLayer.position = center
            glyphLayer.transform = CATransform3DIdentity
            orbitLayer.bounds = localBounds
            orbitLayer.position = localCenter
            orbitLayer.transform = CATransform3DMakeRotation(angle, 0, 0, 1)

            for (index, node) in nodeLayers.enumerated() {
                let bounds = CGRect(x: 0, y: 0, width: Metrics.nodeDiameter, height: Metrics.nodeDiameter)
                let nodeAngle = Self.baseAngles[index]
                let style = resolvedStyle(forNodeAt: index, phase: phase)
                node.bounds = bounds
                node.path = CGPath(ellipseIn: bounds, transform: nil)
                node.position = CGPoint(
                    x: localCenter.x + cos(nodeAngle) * orbitRadius,
                    y: localCenter.y + sin(nodeAngle) * orbitRadius
                )
                node.fillColor = style.fillColor
                node.opacity = Float(style.opacity)
                node.transform = CATransform3DMakeScale(style.scale, style.scale, 1)
            }
        }
    }

    private func reconcileAnimationState() {
        guard animationRequested,
              !reducedMotionEnabled,
              window != nil,
              !isHiddenOrHasHiddenAncestor,
              bounds.width > 0,
              bounds.height > 0 else {
            removeCompositorAnimations()
            applySnapshotModel(phase: currentSnapshotPhase)
            return
        }
        startCompositorAnimationsIfNeeded()
    }

    private func startCompositorAnimationsIfNeeded() {
        applySnapshotModel(phase: currentSnapshotPhase)

        if orbitLayer.animation(forKey: AnimationKey.orbit) == nil {
            let fromAngle = -currentSnapshotPhase * 2 * .pi
            let orbit = CABasicAnimation(keyPath: "transform.rotation.z")
            orbit.fromValue = fromAngle
            orbit.toValue = fromAngle - 2 * .pi
            orbit.duration = Metrics.orbitDuration
            orbit.repeatCount = .infinity
            orbit.timingFunction = CAMediaTimingFunction(name: .linear)
            orbit.isRemovedOnCompletion = false
            orbitLayer.add(orbit, forKey: AnimationKey.orbit)
        }

        for (index, node) in nodeLayers.enumerated() {
            if node.animation(forKey: AnimationKey.fill) == nil {
                node.add(relayAnimation(nodeIndex: index, keyPath: "fillColor", value: color(for:)), forKey: AnimationKey.fill)
            }
            if node.animation(forKey: AnimationKey.opacity) == nil {
                node.add(relayAnimation(nodeIndex: index, keyPath: "opacity") { NSNumber(value: Double(Self.opacity(for: $0))) }, forKey: AnimationKey.opacity)
            }
            if node.animation(forKey: AnimationKey.scale) == nil {
                node.add(relayAnimation(nodeIndex: index, keyPath: "transform.scale") { NSNumber(value: Double(Self.scale(for: $0))) }, forKey: AnimationKey.scale)
            }
        }
    }

    private func relayAnimation(nodeIndex: Int, keyPath: String, value: (RelayRole) -> Any) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = Self.relayKeyTimes.map { value(Self.role(forNodeAt: nodeIndex, phase: $0)) }
        animation.keyTimes = Self.relayKeyTimes.map { NSNumber(value: Double($0)) }
        animation.duration = Metrics.orbitDuration
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        animation.timeOffset = currentSnapshotPhase * Metrics.orbitDuration
        animation.isRemovedOnCompletion = false
        return animation
    }

    private func removeCompositorAnimations() {
        orbitLayer.removeAnimation(forKey: AnimationKey.orbit)
        nodeLayers.forEach { node in
            node.removeAnimation(forKey: AnimationKey.fill)
            node.removeAnimation(forKey: AnimationKey.opacity)
            node.removeAnimation(forKey: AnimationKey.scale)
        }
    }

    private func resolvedStyle(forNodeAt index: Int, phase: CGFloat) -> NodeStyle {
        let relay = Self.normalized(phase - CGFloat(index) / CGFloat(Self.baseAngles.count))
        let role = Self.dominantRole(forRelayProgress: relay)
        let opacity = Self.interpolate(lead: Metrics.leadOpacity, mid: Metrics.midOpacity, trail: Metrics.trailOpacity, progress: relay)
        let scale = Self.interpolate(lead: Metrics.leadScale, mid: Metrics.midScale, trail: Metrics.trailScale, progress: relay)
        return NodeStyle(fillColor: color(for: role), opacity: opacity, scale: scale)
    }

    private func color(for role: RelayRole) -> CGColor {
        let token: AccentToken = role == .mid ? .accentInput : .accentWorking
        return StatusChipNSView.nsColor(token.color.resolved(for: tokenTheme)).cgColor
    }

    private static func role(forNodeAt index: Int, phase: CGFloat) -> RelayRole {
        dominantRole(forRelayProgress: normalized(phase - CGFloat(index) / CGFloat(baseAngles.count)))
    }

    private static func dominantRole(forRelayProgress progress: CGFloat) -> RelayRole {
        let p = normalized(progress)
        if p < 1 / 6 || p >= 5 / 6 { return .lead }
        if p < 1 / 2 { return .trail }
        return .mid
    }

    private static func opacity(for role: RelayRole) -> CGFloat {
        switch role {
        case .lead: return Metrics.leadOpacity
        case .mid: return Metrics.midOpacity
        case .trail: return Metrics.trailOpacity
        }
    }

    private static func scale(for role: RelayRole) -> CGFloat {
        switch role {
        case .lead: return Metrics.leadScale
        case .mid: return Metrics.midScale
        case .trail: return Metrics.trailScale
        }
    }

    private static func interpolate(lead: CGFloat, mid: CGFloat, trail: CGFloat, progress: CGFloat) -> CGFloat {
        let p = normalized(progress)
        if p < 1 / 3 {
            return interpolate(from: lead, to: trail, amount: p * 3)
        }
        if p < 2 / 3 {
            return interpolate(from: trail, to: mid, amount: (p - 1 / 3) * 3)
        }
        return interpolate(from: mid, to: lead, amount: (p - 2 / 3) * 3)
    }

    private static func interpolate(from start: CGFloat, to end: CGFloat, amount: CGFloat) -> CGFloat {
        start + (end - start) * smoothed(amount)
    }

    private static func smoothed(_ amount: CGFloat) -> CGFloat {
        let t = min(max(amount, 0), 1)
        return t * t * (3 - 2 * t)
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        setReducedMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func configureAccessibility(label: String) {
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(label)
    }

    private static func normalized(_ phase: CGFloat) -> CGFloat {
        let remainder = phase.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }

    private static func accessibilityLabel(animated: Bool, phase: CGFloat) -> String {
        if animated { return "Agent thinking, chromatic relay orbit" }
        let percent = Int((normalized(phase) * 100).rounded())
        return "Agent thinking, chromatic relay orbit, snapshot phase \(percent) percent"
    }
}

@MainActor
extension ChromaticRelayOrbitThinkingIndicatorView {
    var qaActiveAnimationCount: Int {
        let orbitCount = orbitLayer.animation(forKey: AnimationKey.orbit) == nil ? 0 : 1
        let nodeCount = nodeLayers.reduce(0) { count, node in
            count
                + (node.animation(forKey: AnimationKey.fill) == nil ? 0 : 1)
                + (node.animation(forKey: AnimationKey.opacity) == nil ? 0 : 1)
                + (node.animation(forKey: AnimationKey.scale) == nil ? 0 : 1)
        }
        return orbitCount + nodeCount
    }

    var qaSnapshotPhase: CGFloat { currentSnapshotPhase }

    var qaNodePresentation: [(fillColor: CGColor?, opacity: Float, scaleX: CGFloat)] {
        nodeLayers.map { node in
            (node.fillColor, node.opacity, CGFloat(node.transform.m11))
        }
    }
}

private extension CATransaction {
    static func withoutActions(_ body: () -> Void) {
        begin()
        setDisableActions(true)
        body()
        commit()
    }
}

import AppKit
import ContinuumRevivedAgentUI

/// Candidate A: a calm three-node orbit for agent thinking affordances.
///
/// The view owns only fixed Core Animation layers. Runtime motion is compositor-
/// driven by rotating the node container and applying a restrained scale breath;
/// deterministic snapshots remove those animations and pin the model layers.
@MainActor
final class OrbitingTriadThinkingIndicatorView: NSView, AgentThinkingIndicatorAnimating {
    private static let side: CGFloat = 18
    private static let orbitDuration: CFTimeInterval = 1.2
    private static let breatheDuration: CFTimeInterval = 0.6
    private static let orbitAnimationKey = "orbitingTriad.orbit"
    private static let breatheAnimationKey = "orbitingTriad.breathe"
    private static let baseAngles: [CGFloat] = [
        -.pi / 2,
        -.pi / 2 - (2 * .pi / 3),
        -.pi / 2 - (4 * .pi / 3),
    ]
    private static let nodeDiameters: [CGFloat] = [3.6, 3.1, 2.7]
    private static let nodeAlphas: [CGFloat] = [1.0, 0.66, 0.38]

    private let glyphLayer = CALayer()
    private let orbitLayer = CALayer()
    private let nodeLayers: [CAShapeLayer]
    private var animationRequested = false
    private var reducedMotionEnabled: Bool
    private var currentSnapshotPhase: CGFloat = 0

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.side, height: Self.side)
    }

    override var isHidden: Bool {
        didSet { reconcileAnimationState() }
    }

    init(reducedMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        self.reducedMotionEnabled = reducedMotion
        self.nodeLayers = Self.nodeDiameters.map { diameter in
            let layer = CAShapeLayer()
            layer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            layer.path = CGPath(ellipseIn: layer.bounds, transform: nil)
            return layer
        }
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: Self.side, height: Self.side)))

        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)

        configureLayerTree()
        applyTokenColors()
        applySnapshotModel(phase: currentSnapshotPhase, scale: Self.scale(for: currentSnapshotPhase))
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
        applySnapshotModel(phase: currentSnapshotPhase, scale: reducedMotionEnabled ? 1 : Self.scale(for: currentSnapshotPhase))
        reconcileAnimationState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reconcileAnimationState()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        reconcileAnimationState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokenColors()
    }

    func startAnimating() {
        animationRequested = true
        configureAccessibility(label: reducedMotionEnabled
            ? Self.accessibilityLabel(animated: false, phase: currentSnapshotPhase)
            : "Agent thinking, orbiting triad")
        reconcileAnimationState()
    }

    func stopAnimating() {
        animationRequested = false
        removeCompositorAnimations()
        configureAccessibility(label: Self.accessibilityLabel(animated: false, phase: currentSnapshotPhase))
    }

    func setReducedMotion(_ enabled: Bool) {
        guard reducedMotionEnabled != enabled else { return }
        reducedMotionEnabled = enabled
        if enabled {
            removeCompositorAnimations()
            applySnapshotModel(phase: currentSnapshotPhase, scale: 1)
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
        applySnapshotModel(phase: currentSnapshotPhase, scale: reducedMotionEnabled ? 1 : Self.scale(for: currentSnapshotPhase))
        configureAccessibility(label: Self.accessibilityLabel(animated: false, phase: currentSnapshotPhase))
    }

    private func configureLayerTree() {
        let disabledActions: [String: CAAction] = [
            "bounds": NSNull(),
            "position": NSNull(),
            "path": NSNull(),
            "transform": NSNull(),
            "opacity": NSNull(),
            "fillColor": NSNull(),
        ]
        glyphLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        glyphLayer.actions = disabledActions
        orbitLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        orbitLayer.actions = disabledActions
        layer?.actions = disabledActions
        layer?.addSublayer(glyphLayer)
        glyphLayer.addSublayer(orbitLayer)
        nodeLayers.forEach { node in
            node.actions = disabledActions
            node.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            orbitLayer.addSublayer(node)
        }
    }

    private func applyTokenColors() {
        let baseColor = AccentToken.accentWorking.color.cgColor(in: self)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, node) in nodeLayers.enumerated() {
            node.fillColor = baseColor.copy(alpha: Self.nodeAlphas[index]) ?? baseColor
        }
        CATransaction.commit()
    }

    private func applySnapshotModel(phase: CGFloat, scale: CGFloat) {
        let side = max(1, min(bounds.width, bounds.height))
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let localBounds = CGRect(x: 0, y: 0, width: side, height: side)
        let localCenter = CGPoint(x: localBounds.midX, y: localBounds.midY)
        let orbitRadius = max(2, floor(side * 0.31))
        let angle = phase * 2 * .pi

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyphLayer.bounds = localBounds
        glyphLayer.position = center
        glyphLayer.transform = CATransform3DMakeScale(scale, scale, 1)
        orbitLayer.bounds = localBounds
        orbitLayer.position = localCenter
        orbitLayer.transform = CATransform3DMakeRotation(angle, 0, 0, 1)

        for (index, node) in nodeLayers.enumerated() {
            let diameter = Self.nodeDiameters[index]
            let bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            let nodeAngle = Self.baseAngles[index]
            node.bounds = bounds
            node.path = CGPath(ellipseIn: bounds, transform: nil)
            node.position = CGPoint(
                x: localCenter.x + cos(nodeAngle) * orbitRadius,
                y: localCenter.y + sin(nodeAngle) * orbitRadius
            )
        }
        CATransaction.commit()
    }

    private func reconcileAnimationState() {
        guard animationRequested,
              !reducedMotionEnabled,
              window != nil,
              !isHiddenOrHasHiddenAncestor,
              bounds.width > 0,
              bounds.height > 0 else {
            removeCompositorAnimations()
            if reducedMotionEnabled {
                applySnapshotModel(phase: currentSnapshotPhase, scale: 1)
            }
            return
        }
        startCompositorAnimationsIfNeeded()
    }

    private func startCompositorAnimationsIfNeeded() {
        if orbitLayer.animation(forKey: Self.orbitAnimationKey) == nil {
            let fromAngle = currentSnapshotPhase * 2 * .pi
            let orbit = CABasicAnimation(keyPath: "transform.rotation.z")
            orbit.fromValue = fromAngle
            orbit.toValue = fromAngle + 2 * .pi
            orbit.duration = Self.orbitDuration
            orbit.repeatCount = .infinity
            orbit.timingFunction = CAMediaTimingFunction(name: .linear)
            orbit.isRemovedOnCompletion = false
            orbitLayer.add(orbit, forKey: Self.orbitAnimationKey)
        }

        if glyphLayer.animation(forKey: Self.breatheAnimationKey) == nil {
            let breathe = CABasicAnimation(keyPath: "transform.scale")
            breathe.fromValue = 0.97
            breathe.toValue = 1.035
            breathe.duration = Self.breatheDuration
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breathe.isRemovedOnCompletion = false
            glyphLayer.add(breathe, forKey: Self.breatheAnimationKey)
        }
    }

    private func removeCompositorAnimations() {
        orbitLayer.removeAnimation(forKey: Self.orbitAnimationKey)
        glyphLayer.removeAnimation(forKey: Self.breatheAnimationKey)
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

    private static func scale(for phase: CGFloat) -> CGFloat {
        // One sine breath per orbit, intentionally narrow so the motion reads as
        // calm activity rather than urgency.
        1 + 0.025 * sin(phase * 2 * .pi)
    }

    private static func accessibilityLabel(animated: Bool, phase: CGFloat) -> String {
        if animated { return "Agent thinking, orbiting triad" }
        let percent = Int((normalized(phase) * 100).rounded())
        return "Agent thinking, orbiting triad, snapshot phase \(percent) percent"
    }
}

@MainActor
extension OrbitingTriadThinkingIndicatorView {
    var qaActiveAnimationCount: Int {
        [
            orbitLayer.animation(forKey: Self.orbitAnimationKey) == nil ? 0 : 1,
            glyphLayer.animation(forKey: Self.breatheAnimationKey) == nil ? 0 : 1,
        ].reduce(0, +)
    }

    var qaSnapshotPhase: CGFloat { currentSnapshotPhase }
}

import AppKit
import ContinuumRevivedAgentUI
import QuartzCore

/// Orbit variation 3: counter-current.
///
/// Two working-color nodes ride the larger outer ring clockwise while a smaller
/// approval-color node moves counter-clockwise on an inner ring. The 4:3 orbit
/// ratio makes the crossings migrate predictably over a 6.72s master cycle:
/// kinetic enough to read as technical work, but not random or spinner-like.
@MainActor
final class CounterCurrentOrbitThinkingIndicatorView: NSView, AgentThinkingIndicatorAnimating {
    private enum AnimationKey {
        static let outerOrbit = "counterCurrent.outerOrbit"
        static let innerOrbit = "counterCurrent.innerOrbit"
        static let outerLeadingOpacity = "counterCurrent.outerLeadingOpacity"
        static let outerTrailingOpacity = "counterCurrent.outerTrailingOpacity"
        static let innerOpacity = "counterCurrent.innerOpacity"
    }

    private struct OrbitPose: Equatable {
        var outerAngle: CGFloat
        var innerAngle: CGFloat
        var outerLeadingOpacity: Float
        var outerTrailingOpacity: Float
        var innerOpacity: Float
    }

    private enum Constants {
        static let side: CGFloat = 18
        static let masterDuration: CFTimeInterval = 6.72
        static let outerTurnsPerMaster: CGFloat = -4
        static let innerTurnsPerMaster: CGFloat = 3
        static let outerPeriod: CFTimeInterval = masterDuration / CFTimeInterval(abs(outerTurnsPerMaster))
        static let innerPeriod: CFTimeInterval = masterDuration / CFTimeInterval(abs(innerTurnsPerMaster))
        static let outerRadiusScale: CGFloat = 0.335
        static let innerRadiusScale: CGFloat = 0.205
        static let guideLineWidth: CGFloat = 0.72
        static let outerLeadingDiameter: CGFloat = 3.2
        static let outerTrailingDiameter: CGFloat = 2.9
        static let innerDiameter: CGFloat = 2.25
        static let opacityFloor: Float = 0.52
        static let opacityCeiling: Float = 0.92
        static let reducedMotionPhase: CGFloat = 0.135
        static let opacitySampleCount = 33
        static let outerBaseAngles: [CGFloat] = [-.pi / 2, .pi / 2]
        static let innerBaseAngle: CGFloat = 0
    }

    private let glyphLayer = CALayer()
    private let outerGuideLayer = CAShapeLayer()
    private let innerGuideLayer = CAShapeLayer()
    private let outerOrbitLayer = CALayer()
    private let innerOrbitLayer = CALayer()
    private let outerLeadingNodeLayer = CAShapeLayer()
    private let outerTrailingNodeLayer = CAShapeLayer()
    private let innerNodeLayer = CAShapeLayer()

    private var animationRequested = false
    private var reducedMotionEnabled: Bool
    private var currentSnapshotPhase: CGFloat = 0

    override var intrinsicContentSize: NSSize {
        NSSize(width: Constants.side, height: Constants.side)
    }

    override var isHidden: Bool {
        didSet { reconcileAnimationState() }
    }

    init(reducedMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        self.reducedMotionEnabled = reducedMotion
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: Constants.side, height: Constants.side)))

        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)

        configureLayerTree()
        configureAccessibility(animated: false)
        applyResolvedAppearance()
        applyModel(phase: reducedMotion ? Constants.reducedMotionPhase : currentSnapshotPhase)

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
        applyModel(phase: effectiveStillPhase)
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

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyResolvedAppearance()
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
        removeCompositorAnimations()
        applyModel(phase: effectiveStillPhase)
        configureAccessibility(animated: false)
    }

    func setReducedMotion(_ enabled: Bool) {
        guard reducedMotionEnabled != enabled else { return }
        reducedMotionEnabled = enabled
        removeCompositorAnimations()
        applyModel(phase: effectiveStillPhase)
        configureAccessibility(animated: animationRequested && !enabled)
        reconcileAnimationState()
    }

    /// Pins the master-cycle model pose. The outer ring resolves to four
    /// clockwise turns per cycle while the inner node resolves to three
    /// counter-clockwise turns, so deterministic snapshots preserve both
    /// directions instead of freezing only one layer tree.
    func setSnapshotPhase(_ phase: CGFloat) {
        currentSnapshotPhase = Self.normalizedPhase(phase)
        animationRequested = false
        removeCompositorAnimations()
        applyModel(phase: currentSnapshotPhase)
        configureAccessibility(animated: false)
    }

    private var effectiveStillPhase: CGFloat {
        reducedMotionEnabled && animationRequested ? Constants.reducedMotionPhase : currentSnapshotPhase
    }

    private var canAnimate: Bool {
        animationRequested
            && !reducedMotionEnabled
            && window != nil
            && superview != nil
            && !isHiddenOrHasHiddenAncestor
            && bounds.width > 0
            && bounds.height > 0
    }

    private func configureLayerTree() {
        let disabledActions: [String: CAAction] = [
            "bounds": NSNull(),
            "position": NSNull(),
            "path": NSNull(),
            "transform": NSNull(),
            "opacity": NSNull(),
            "fillColor": NSNull(),
            "strokeColor": NSNull(),
            "lineWidth": NSNull(),
        ]

        layer?.actions = disabledActions
        layer?.masksToBounds = false

        glyphLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        glyphLayer.actions = disabledActions
        outerOrbitLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        outerOrbitLayer.actions = disabledActions
        innerOrbitLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        innerOrbitLayer.actions = disabledActions

        [outerGuideLayer, innerGuideLayer].forEach { guide in
            guide.fillColor = nil
            guide.lineCap = .round
            guide.actions = disabledActions
        }

        [outerLeadingNodeLayer, outerTrailingNodeLayer, innerNodeLayer].forEach { node in
            node.actions = disabledActions
            node.fillRule = .nonZero
        }

        layer?.addSublayer(glyphLayer)
        glyphLayer.addSublayer(outerGuideLayer)
        glyphLayer.addSublayer(innerGuideLayer)
        glyphLayer.addSublayer(outerOrbitLayer)
        glyphLayer.addSublayer(innerOrbitLayer)
        outerOrbitLayer.addSublayer(outerLeadingNodeLayer)
        outerOrbitLayer.addSublayer(outerTrailingNodeLayer)
        innerOrbitLayer.addSublayer(innerNodeLayer)
        updateContentsScale()
    }

    private func applyResolvedAppearance() {
        let workingColor = AccentToken.accentWorking.color.cgColor(in: self)
        let contrastColor = AccentToken.accentApproval.color.cgColor(in: self)
        let guideColor = AgentLineRole.decorativeHairline.color.cgColor(in: self)

        CATransaction.withoutActions {
            outerLeadingNodeLayer.fillColor = workingColor
            outerTrailingNodeLayer.fillColor = workingColor
            innerNodeLayer.fillColor = contrastColor
            outerGuideLayer.strokeColor = guideColor.copy(alpha: 0.22) ?? guideColor
            innerGuideLayer.strokeColor = contrastColor.copy(alpha: 0.20) ?? contrastColor
        }
    }

    private func applyModel(phase: CGFloat) {
        let normalized = Self.normalizedPhase(phase)
        let side = max(1, min(bounds.width, bounds.height, Constants.side))
        let localBounds = CGRect(origin: .zero, size: CGSize(width: side, height: side))
        let viewCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        let localCenter = CGPoint(x: localBounds.midX, y: localBounds.midY)
        let outerRadius = max(4.5, floor(side * Constants.outerRadiusScale * 10) / 10)
        let innerRadius = max(2.8, floor(side * Constants.innerRadiusScale * 10) / 10)
        let pose = Self.pose(for: normalized)

        CATransaction.withoutActions {
            glyphLayer.bounds = localBounds
            glyphLayer.position = viewCenter
            glyphLayer.transform = CATransform3DIdentity

            [outerGuideLayer, innerGuideLayer, outerOrbitLayer, innerOrbitLayer].forEach { layer in
                layer.bounds = localBounds
                layer.position = localCenter
            }

            outerGuideLayer.lineWidth = Constants.guideLineWidth
            outerGuideLayer.lineDashPattern = [1.5, 2.1]
            outerGuideLayer.path = Self.ringPath(center: localCenter, radius: outerRadius)
            innerGuideLayer.lineWidth = Constants.guideLineWidth
            innerGuideLayer.lineDashPattern = [0.8, 2.4]
            innerGuideLayer.path = Self.ringPath(center: localCenter, radius: innerRadius)

            outerOrbitLayer.transform = CATransform3DMakeRotation(pose.outerAngle, 0, 0, 1)
            innerOrbitLayer.transform = CATransform3DMakeRotation(pose.innerAngle, 0, 0, 1)

            Self.configureNode(
                outerLeadingNodeLayer,
                diameter: Constants.outerLeadingDiameter,
                center: CGPoint(
                    x: localCenter.x + cos(Constants.outerBaseAngles[0]) * outerRadius,
                    y: localCenter.y + sin(Constants.outerBaseAngles[0]) * outerRadius
                ),
                opacity: pose.outerLeadingOpacity
            )
            Self.configureNode(
                outerTrailingNodeLayer,
                diameter: Constants.outerTrailingDiameter,
                center: CGPoint(
                    x: localCenter.x + cos(Constants.outerBaseAngles[1]) * outerRadius,
                    y: localCenter.y + sin(Constants.outerBaseAngles[1]) * outerRadius
                ),
                opacity: pose.outerTrailingOpacity
            )
            Self.configureNode(
                innerNodeLayer,
                diameter: Constants.innerDiameter,
                center: CGPoint(
                    x: localCenter.x + cos(Constants.innerBaseAngle) * innerRadius,
                    y: localCenter.y + sin(Constants.innerBaseAngle) * innerRadius
                ),
                opacity: pose.innerOpacity
            )
        }

        setAccessibilityValue(Self.accessibilityValue(for: normalized))
    }

    private func reconcileAnimationState() {
        guard canAnimate else {
            removeCompositorAnimations()
            applyModel(phase: effectiveStillPhase)
            configureAccessibility(animated: false)
            return
        }
        configureAccessibility(animated: true)
        startCompositorAnimationsIfNeeded()
    }

    private func startCompositorAnimationsIfNeeded() {
        applyModel(phase: currentSnapshotPhase)
        installOrbitAnimation(
            on: outerOrbitLayer,
            key: AnimationKey.outerOrbit,
            fromAngle: Self.pose(for: currentSnapshotPhase).outerAngle,
            deltaTurns: Constants.outerTurnsPerMaster
        )
        installOrbitAnimation(
            on: innerOrbitLayer,
            key: AnimationKey.innerOrbit,
            fromAngle: Self.pose(for: currentSnapshotPhase).innerAngle,
            deltaTurns: Constants.innerTurnsPerMaster
        )
        installOpacityAnimationIfNeeded(
            on: outerLeadingNodeLayer,
            key: AnimationKey.outerLeadingOpacity,
            values: Self.opacitySamples(from: currentSnapshotPhase, keyPath: \.outerLeadingOpacity)
        )
        installOpacityAnimationIfNeeded(
            on: outerTrailingNodeLayer,
            key: AnimationKey.outerTrailingOpacity,
            values: Self.opacitySamples(from: currentSnapshotPhase, keyPath: \.outerTrailingOpacity)
        )
        installOpacityAnimationIfNeeded(
            on: innerNodeLayer,
            key: AnimationKey.innerOpacity,
            values: Self.opacitySamples(from: currentSnapshotPhase, keyPath: \.innerOpacity)
        )
    }

    private func installOrbitAnimation(on layer: CALayer, key: String, fromAngle: CGFloat, deltaTurns: CGFloat) {
        guard layer.animation(forKey: key) == nil else { return }
        let orbit = CABasicAnimation(keyPath: "transform.rotation.z")
        orbit.fromValue = fromAngle
        orbit.toValue = fromAngle + (deltaTurns * 2 * .pi)
        orbit.duration = Constants.masterDuration
        orbit.repeatCount = .infinity
        orbit.timingFunction = CAMediaTimingFunction(name: .linear)
        orbit.isRemovedOnCompletion = false
        layer.add(orbit, forKey: key)
    }

    private func installOpacityAnimationIfNeeded(on layer: CALayer, key: String, values: [Float]) {
        guard layer.animation(forKey: key) == nil else { return }
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = values
        opacity.keyTimes = Self.keyTimes(count: values.count)
        opacity.duration = Constants.masterDuration
        opacity.repeatCount = .infinity
        opacity.calculationMode = .linear
        opacity.isRemovedOnCompletion = false
        layer.add(opacity, forKey: key)
    }

    private func removeCompositorAnimations() {
        outerOrbitLayer.removeAnimation(forKey: AnimationKey.outerOrbit)
        innerOrbitLayer.removeAnimation(forKey: AnimationKey.innerOrbit)
        outerLeadingNodeLayer.removeAnimation(forKey: AnimationKey.outerLeadingOpacity)
        outerTrailingNodeLayer.removeAnimation(forKey: AnimationKey.outerTrailingOpacity)
        innerNodeLayer.removeAnimation(forKey: AnimationKey.innerOpacity)
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        [
            glyphLayer,
            outerGuideLayer,
            innerGuideLayer,
            outerOrbitLayer,
            innerOrbitLayer,
            outerLeadingNodeLayer,
            outerTrailingNodeLayer,
            innerNodeLayer,
        ].forEach { $0.contentsScale = scale }
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        setReducedMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func configureAccessibility(animated: Bool) {
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(animated
            ? "Agent thinking, counter-current orbit"
            : "Agent thinking, counter-current orbit, still")
        setAccessibilityHelp("Two outer nodes orbit clockwise while a smaller inner node moves counter-clockwise.")
    }

    private static func configureNode(_ layer: CAShapeLayer, diameter: CGFloat, center: CGPoint, opacity: Float) {
        let bounds = CGRect(origin: .zero, size: CGSize(width: diameter, height: diameter))
        layer.bounds = bounds
        layer.path = CGPath(ellipseIn: bounds, transform: nil)
        layer.position = center
        layer.opacity = opacity
    }

    private static func ringPath(center: CGPoint, radius: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ), transform: nil)
    }

    private static func pose(for phase: CGFloat) -> OrbitPose {
        let normalized = normalizedPhase(phase)
        let outerAngle = Constants.outerTurnsPerMaster * normalized * 2 * .pi
        let innerAngle = Constants.innerTurnsPerMaster * normalized * 2 * .pi
        let alternating = smoothPulse(normalized)
        let crossing = crossingPulse(phase: normalized, outerAngle: outerAngle, innerAngle: innerAngle)
        let contrastLift = 0.055 * crossing
        return OrbitPose(
            outerAngle: outerAngle,
            innerAngle: innerAngle,
            outerLeadingOpacity: clampedOpacity(0.56 + (0.24 * alternating) + contrastLift),
            outerTrailingOpacity: clampedOpacity(0.56 + (0.24 * (1 - alternating)) + contrastLift),
            innerOpacity: clampedOpacity(0.62 + (0.18 * crossing) + (0.06 * (1 - alternating)))
        )
    }

    private static func crossingPulse(phase: CGFloat, outerAngle: CGFloat, innerAngle: CGFloat) -> CGFloat {
        let innerGlobal = Constants.innerBaseAngle + innerAngle
        let leadingDelta = angularDistance(innerGlobal, Constants.outerBaseAngles[0] + outerAngle)
        let trailingDelta = angularDistance(innerGlobal, Constants.outerBaseAngles[1] + outerAngle)
        let nearestAlignment = max((1 + cos(leadingDelta)) / 2, (1 + cos(trailingDelta)) / 2)
        // Blend in a slow master-cycle envelope so contrast swells at crossings
        // instead of flashing at every geometric alignment.
        return min(1, (nearestAlignment * 0.70) + (smoothPulse(phase + 0.18) * 0.30))
    }

    private static func opacitySamples(from phase: CGFloat, keyPath: KeyPath<OrbitPose, Float>) -> [Float] {
        (0..<Constants.opacitySampleCount).map { index in
            let samplePhase = phase + CGFloat(index) / CGFloat(Constants.opacitySampleCount - 1)
            return pose(for: samplePhase)[keyPath: keyPath]
        }
    }

    private static func keyTimes(count: Int) -> [NSNumber] {
        guard count > 1 else { return [0] }
        return (0..<count).map { NSNumber(value: Double($0) / Double(count - 1)) }
    }

    private static func smoothPulse(_ phase: CGFloat) -> CGFloat {
        let normalized = normalizedPhase(phase)
        return (1 - cos(normalized * 2 * .pi)) / 2
    }

    private static func angularDistance(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
        let raw = (lhs - rhs).truncatingRemainder(dividingBy: 2 * .pi)
        let wrapped = raw > .pi ? raw - (2 * .pi) : raw
        return wrapped < -.pi ? wrapped + (2 * .pi) : wrapped
    }

    private static func clampedOpacity(_ value: CGFloat) -> Float {
        Float(min(CGFloat(Constants.opacityCeiling), max(CGFloat(Constants.opacityFloor), value)))
    }

    private static func normalizedPhase(_ phase: CGFloat) -> CGFloat {
        let remainder = phase.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }

    private static func accessibilityValue(for phase: CGFloat) -> String {
        let percent = Int((normalizedPhase(phase) * 100).rounded())
        return "Phase \(percent) percent"
    }
}

@MainActor
extension CounterCurrentOrbitThinkingIndicatorView {
    struct QAOrbitMetrics: Equatable {
        var masterDuration: CFTimeInterval
        var outerPeriod: CFTimeInterval
        var innerPeriod: CFTimeInterval
        var outerTurnsPerMaster: CGFloat
        var innerTurnsPerMaster: CGFloat
    }

    struct QANodeState: Equatable {
        var center: CGPoint
        var opacity: Float
        var diameter: CGFloat
    }

    var qaActiveAnimationCount: Int {
        [
            outerOrbitLayer.animation(forKey: AnimationKey.outerOrbit),
            innerOrbitLayer.animation(forKey: AnimationKey.innerOrbit),
            outerLeadingNodeLayer.animation(forKey: AnimationKey.outerLeadingOpacity),
            outerTrailingNodeLayer.animation(forKey: AnimationKey.outerTrailingOpacity),
            innerNodeLayer.animation(forKey: AnimationKey.innerOpacity),
        ].filter { $0 != nil }.count
    }

    var qaSnapshotPhase: CGFloat { currentSnapshotPhase }
    var qaReducedMotionEnabled: Bool { reducedMotionEnabled }
    var qaAccessibilityLabel: String? { accessibilityLabel() }
    var qaAccessibilityValue: String? { accessibilityValue() as? String }

    var qaOrbitMetrics: QAOrbitMetrics {
        QAOrbitMetrics(
            masterDuration: Constants.masterDuration,
            outerPeriod: Constants.outerPeriod,
            innerPeriod: Constants.innerPeriod,
            outerTurnsPerMaster: Constants.outerTurnsPerMaster,
            innerTurnsPerMaster: Constants.innerTurnsPerMaster
        )
    }

    var qaNodeStates: [QANodeState] {
        layoutSubtreeIfNeeded()
        return [
            QANodeState(
                center: outerOrbitLayer.convert(outerLeadingNodeLayer.position, to: glyphLayer),
                opacity: outerLeadingNodeLayer.opacity,
                diameter: outerLeadingNodeLayer.bounds.width
            ),
            QANodeState(
                center: outerOrbitLayer.convert(outerTrailingNodeLayer.position, to: glyphLayer),
                opacity: outerTrailingNodeLayer.opacity,
                diameter: outerTrailingNodeLayer.bounds.width
            ),
            QANodeState(
                center: innerOrbitLayer.convert(innerNodeLayer.position, to: glyphLayer),
                opacity: innerNodeLayer.opacity,
                diameter: innerNodeLayer.bounds.width
            ),
        ]
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

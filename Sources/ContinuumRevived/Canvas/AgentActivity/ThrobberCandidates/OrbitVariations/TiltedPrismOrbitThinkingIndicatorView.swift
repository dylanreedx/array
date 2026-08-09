import AppKit
import ContinuumRevivedAgentUI
import QuartzCore

/// Orbit variation 2: a tilted, prismatic triad on an isometric orbital plane.
///
/// The live path is entirely Core Animation compositor work: each node receives
/// repeated keyframes for position, scale, opacity, and z-depth. Static QA poses
/// use the same geometry function as those keyframes, so snapshot phases are a
/// deterministic view of the animation rather than a separate approximation.
@MainActor
final class TiltedPrismOrbitThinkingIndicatorView: NSView, AgentThinkingIndicatorAnimating {
    struct QANodeState: Equatable {
        let index: Int
        let position: CGPoint
        let scale: CGFloat
        let opacity: Float
        let zPosition: CGFloat
        let accent: AccentToken
    }

    private enum AnimationKey {
        static let position = "tilted-prism-orbit.position"
        static let scale = "tilted-prism-orbit.scale"
        static let opacity = "tilted-prism-orbit.opacity"
        static let zPosition = "tilted-prism-orbit.zPosition"
    }

    private struct NodeState {
        let position: CGPoint
        let scale: CGFloat
        let opacity: Float
        let zPosition: CGFloat
        let accent: AccentToken
    }

    private static let side: CGFloat = 18
    private static let nodeDiameter: CGFloat = 3.45
    private static let duration: CFTimeInterval = 1.55
    private static let animationStepCount = 72
    private static let tiltRadians: CGFloat = 30 * .pi / 180
    private static let reducedMotionPhase: CGFloat = 0.055
    private static let baseAngles: [CGFloat] = [
        -.pi / 2,
        -.pi / 2 - (2 * .pi / 3),
        -.pi / 2 - (4 * .pi / 3),
    ]
    private static let accents: [AccentToken] = [
        .accentWorking,
        .accentInput,
        .accentApproval,
    ]

    private let guideLayer = CAShapeLayer()
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
        self.nodeLayers = Self.accents.map { _ in Self.makeNodeLayer() }
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: Self.side, height: Self.side)))
        configureView()
    }

    override init(frame frameRect: NSRect) {
        self.reducedMotionEnabled = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        self.nodeLayers = Self.accents.map { _ in Self.makeNodeLayer() }
        super.init(frame: frameRect)
        configureView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        updateContentsScale()
        applyModelState(phase: modelPhaseForCurrentMode())
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

    override func viewDidHide() {
        super.viewDidHide()
        reconcileAnimationState()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        reconcileAnimationState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokenColors()
    }

    func startAnimating() {
        animationRequested = true
        configureAccessibility(animated: !reducedMotionEnabled, phase: modelPhaseForCurrentMode())
        reconcileAnimationState()
    }

    func stopAnimating() {
        animationRequested = false
        removeAnimations()
        applyModelState(phase: currentSnapshotPhase)
        configureAccessibility(animated: false, phase: currentSnapshotPhase)
    }

    func setReducedMotion(_ enabled: Bool) {
        guard reducedMotionEnabled != enabled else { return }
        reducedMotionEnabled = enabled
        removeAnimations()
        applyModelState(phase: modelPhaseForCurrentMode())
        configureAccessibility(animated: animationRequested && !enabled, phase: modelPhaseForCurrentMode())
        reconcileAnimationState()
    }

    /// Pins a deterministic model-layer pose for review. Snapshot geometry is
    /// produced by the same orbital math that supplies live CA keyframes.
    func setSnapshotPhase(_ phase: CGFloat) {
        animationRequested = false
        currentSnapshotPhase = Self.normalizedPhase(phase)
        removeAnimations()
        applyModelState(phase: currentSnapshotPhase)
        configureAccessibility(animated: false, phase: currentSnapshotPhase)
    }

    private func configureView() {
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)

        configureLayerTree()
        updateContentsScale()
        applyTokenColors()
        applyModelState(phase: currentSnapshotPhase)
        configureAccessibility(animated: false, phase: currentSnapshotPhase)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    private func configureLayerTree() {
        let disabledActions = Self.disabledLayerActions
        layer?.actions = disabledActions

        guideLayer.fillColor = nil
        guideLayer.lineCap = .round
        guideLayer.lineJoin = .round
        guideLayer.actions = disabledActions
        layer?.addSublayer(guideLayer)

        nodeLayers.forEach { node in
            node.actions = disabledActions
            layer?.addSublayer(node)
        }
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        guideLayer.contentsScale = scale
        nodeLayers.forEach { $0.contentsScale = scale }
    }

    private func applyTokenColors() {
        performWithoutLayerActions {
            guideLayer.strokeColor = AgentLineRole.decorativeHairline.color.cgColor(in: self).copy(alpha: 0.42)
            for (index, node) in nodeLayers.enumerated() {
                let accent = Self.accents[index]
                node.fillColor = accent.color.cgColor(in: self)
            }
        }
    }

    private func applyModelState(phase: CGFloat) {
        let geometry = Self.geometry(in: bounds)
        performWithoutLayerActions {
            guideLayer.frame = bounds
            guideLayer.path = Self.orbitGuidePath(center: geometry.center, majorRadius: geometry.majorRadius, minorRadius: geometry.minorRadius)
            guideLayer.lineWidth = geometry.guideLineWidth

            for (index, node) in nodeLayers.enumerated() {
                let state = Self.nodeState(index: index, phase: phase, geometry: geometry)
                let nodeBounds = CGRect(x: 0, y: 0, width: Self.nodeDiameter, height: Self.nodeDiameter)
                node.bounds = nodeBounds
                node.path = CGPath(ellipseIn: nodeBounds, transform: nil)
                node.position = state.position
                node.transform = CATransform3DMakeScale(state.scale, state.scale, 1)
                node.opacity = state.opacity
                node.zPosition = state.zPosition
            }
        }
        setAccessibilityValue(Self.accessibilityValue(for: phase))
    }

    private func reconcileAnimationState() {
        guard animationRequested else {
            removeAnimations()
            return
        }

        guard !reducedMotionEnabled,
              canAnimate else {
            removeAnimations()
            applyModelState(phase: modelPhaseForCurrentMode())
            configureAccessibility(animated: false, phase: modelPhaseForCurrentMode())
            return
        }

        startAnimationsIfNeeded()
        configureAccessibility(animated: true, phase: currentSnapshotPhase)
    }

    private var canAnimate: Bool {
        window != nil && !isHiddenOrHasHiddenAncestor && bounds.width > 0 && bounds.height > 0
    }

    private func startAnimationsIfNeeded() {
        let needsInstall = nodeLayers.enumerated().contains { index, node in
            node.animation(forKey: animationKey(AnimationKey.position, index: index)) == nil ||
            node.animation(forKey: animationKey(AnimationKey.scale, index: index)) == nil ||
            node.animation(forKey: animationKey(AnimationKey.opacity, index: index)) == nil ||
            node.animation(forKey: animationKey(AnimationKey.zPosition, index: index)) == nil
        }
        guard needsInstall else { return }

        removeAnimations()
        applyModelState(phase: currentSnapshotPhase)

        let geometry = Self.geometry(in: bounds)
        let keyTimes = (0...Self.animationStepCount).map {
            NSNumber(value: Double($0) / Double(Self.animationStepCount))
        }

        for (index, node) in nodeLayers.enumerated() {
            let samples = (0...Self.animationStepCount).map { step in
                Self.nodeState(
                    index: index,
                    phase: currentSnapshotPhase + CGFloat(step) / CGFloat(Self.animationStepCount),
                    geometry: geometry
                )
            }

            let position = CAKeyframeAnimation(keyPath: "position")
            position.values = samples.map { NSValue(point: $0.position) }
            configure(animation: position, keyTimes: keyTimes)
            node.add(position, forKey: animationKey(AnimationKey.position, index: index))

            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = samples.map { NSNumber(value: Double($0.scale)) }
            configure(animation: scale, keyTimes: keyTimes)
            node.add(scale, forKey: animationKey(AnimationKey.scale, index: index))

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = samples.map { NSNumber(value: $0.opacity) }
            configure(animation: opacity, keyTimes: keyTimes)
            node.add(opacity, forKey: animationKey(AnimationKey.opacity, index: index))

            let zPosition = CAKeyframeAnimation(keyPath: "zPosition")
            zPosition.values = samples.map { NSNumber(value: Double($0.zPosition)) }
            configure(animation: zPosition, keyTimes: keyTimes)
            node.add(zPosition, forKey: animationKey(AnimationKey.zPosition, index: index))
        }
    }

    private func configure(animation: CAKeyframeAnimation, keyTimes: [NSNumber]) {
        animation.keyTimes = keyTimes
        animation.duration = Self.duration
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
    }

    private func removeAnimations() {
        for (index, node) in nodeLayers.enumerated() {
            node.removeAnimation(forKey: animationKey(AnimationKey.position, index: index))
            node.removeAnimation(forKey: animationKey(AnimationKey.scale, index: index))
            node.removeAnimation(forKey: animationKey(AnimationKey.opacity, index: index))
            node.removeAnimation(forKey: animationKey(AnimationKey.zPosition, index: index))
        }
    }

    private func modelPhaseForCurrentMode() -> CGFloat {
        reducedMotionEnabled && animationRequested ? Self.reducedMotionPhase : currentSnapshotPhase
    }

    private func animationKey(_ base: String, index: Int) -> String {
        "\(base).\(index)"
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        setReducedMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func configureAccessibility(animated: Bool, phase: CGFloat) {
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(animated ? "Agent thinking, tilted prism orbit" : "Agent thinking, tilted prism orbit snapshot")
        setAccessibilityHelp("A prismatic three-node orbit on a tilted diagonal plane indicates the agent is working.")
        setAccessibilityValue(Self.accessibilityValue(for: phase))
    }

    private func performWithoutLayerActions(_ work: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        work()
        CATransaction.commit()
    }

    private static var disabledLayerActions: [String: CAAction] {
        [
            "backgroundColor": NSNull(),
            "bounds": NSNull(),
            "fillColor": NSNull(),
            "frame": NSNull(),
            "lineWidth": NSNull(),
            "opacity": NSNull(),
            "path": NSNull(),
            "position": NSNull(),
            "strokeColor": NSNull(),
            "sublayers": NSNull(),
            "transform": NSNull(),
            "zPosition": NSNull(),
        ]
    }

    private static func makeNodeLayer() -> CAShapeLayer {
        let layer = CAShapeLayer()
        let bounds = CGRect(x: 0, y: 0, width: nodeDiameter, height: nodeDiameter)
        layer.bounds = bounds
        layer.path = CGPath(ellipseIn: bounds, transform: nil)
        return layer
    }

    private static func geometry(in bounds: CGRect) -> (center: CGPoint, majorRadius: CGFloat, minorRadius: CGFloat, guideLineWidth: CGFloat) {
        let side = max(1, min(bounds.width, bounds.height))
        return (
            center: CGPoint(x: bounds.midX, y: bounds.midY),
            majorRadius: max(2.5, side * 0.297),
            minorRadius: max(1.35, side * 0.128),
            guideLineWidth: max(0.55, side * 0.042)
        )
    }

    private static func nodeState(index: Int, phase: CGFloat, geometry: (center: CGPoint, majorRadius: CGFloat, minorRadius: CGFloat, guideLineWidth: CGFloat)) -> NodeState {
        let angle = baseAngles[index] - normalizedPhase(phase) * 2 * .pi
        let point = tiltedPoint(
            angle: angle,
            center: geometry.center,
            majorRadius: geometry.majorRadius,
            minorRadius: geometry.minorRadius
        )
        let depth = -sin(angle)
        let frontness = smoothstep((depth + 1) / 2)
        return NodeState(
            position: point,
            scale: 0.76 + 0.43 * frontness,
            opacity: Float(0.39 + 0.57 * frontness),
            zPosition: 10 * frontness,
            accent: accents[index]
        )
    }

    private static func tiltedPoint(angle: CGFloat, center: CGPoint, majorRadius: CGFloat, minorRadius: CGFloat) -> CGPoint {
        let localX = cos(angle) * majorRadius
        let localY = sin(angle) * minorRadius
        let cosTilt = cos(tiltRadians)
        let sinTilt = sin(tiltRadians)
        return CGPoint(
            x: center.x + localX * cosTilt - localY * sinTilt,
            y: center.y + localX * sinTilt + localY * cosTilt
        )
    }

    private static func orbitGuidePath(center: CGPoint, majorRadius: CGFloat, minorRadius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let segments = 72
        for step in 0...segments {
            let angle = CGFloat(step) / CGFloat(segments) * 2 * .pi
            let point = tiltedPoint(angle: angle, center: center, majorRadius: majorRadius, minorRadius: minorRadius)
            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }

    private static func smoothstep(_ value: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, value))
        return clamped * clamped * (3 - 2 * clamped)
    }

    private static func normalizedPhase(_ phase: CGFloat) -> CGFloat {
        guard phase.isFinite else { return 0 }
        let remainder = phase.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }

    private static func accessibilityValue(for phase: CGFloat) -> String {
        let percent = Int((normalizedPhase(phase) * 100).rounded())
        return "phase \(percent) percent, tilted diagonal orbit"
    }
}

@MainActor
extension TiltedPrismOrbitThinkingIndicatorView {
    var qaActiveAnimationCount: Int {
        nodeLayers.enumerated().reduce(0) { count, pair in
            let (index, node) = pair
            return count
                + (node.animation(forKey: animationKey(AnimationKey.position, index: index)) == nil ? 0 : 1)
                + (node.animation(forKey: animationKey(AnimationKey.scale, index: index)) == nil ? 0 : 1)
                + (node.animation(forKey: animationKey(AnimationKey.opacity, index: index)) == nil ? 0 : 1)
                + (node.animation(forKey: animationKey(AnimationKey.zPosition, index: index)) == nil ? 0 : 1)
        }
    }

    var qaSnapshotPhase: CGFloat { currentSnapshotPhase }

    var qaReducedMotionPhase: CGFloat { Self.reducedMotionPhase }

    var qaNodeStates: [QANodeState] {
        let geometry = Self.geometry(in: bounds)
        let phase = modelPhaseForCurrentMode()
        return nodeLayers.indices.map { index in
            let state = Self.nodeState(index: index, phase: phase, geometry: geometry)
            return QANodeState(
                index: index,
                position: state.position,
                scale: state.scale,
                opacity: state.opacity,
                zPosition: state.zPosition,
                accent: state.accent
            )
        }
    }

    var qaIntrinsicSide: CGFloat { Self.side }
}

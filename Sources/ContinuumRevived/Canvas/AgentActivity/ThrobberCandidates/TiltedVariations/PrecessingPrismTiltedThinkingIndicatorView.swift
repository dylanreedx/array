import AppKit
import ContinuumRevivedAgentUI
import QuartzCore

/// Tilted Prism variation 4: a precessing, prismatic triad.
///
/// The indicator keeps the Tilted Prism language — three theme-coloured nodes on
/// a shallow diagonal ellipse — but separates cadence into a fast orbital pass
/// and a much slower master-cycle rock of the plane. Live motion is entirely
/// Core Animation keyframes installed on layer properties; deterministic
/// snapshots use the same geometry function with a master-cycle phase so orbit
/// and plane angle stay locked for QA.
@MainActor
final class PrecessingPrismTiltedThinkingIndicatorView: NSView, AgentThinkingIndicatorAnimating {
    struct QAPoseState: Equatable {
        let masterPhase: CGFloat
        let orbitPhase: CGFloat
        let planeAngleRadians: CGFloat
        let planeAngleDegrees: CGFloat
    }

    struct QANodeState: Equatable {
        let index: Int
        let position: CGPoint
        let scale: CGFloat
        let opacity: Float
        let zPosition: CGFloat
        let accent: AccentToken
        let depth: CGFloat
    }

    private enum AnimationKey {
        static let guidePath = "precessing-prism-tilted.guide.path"
        static let position = "precessing-prism-tilted.node.position"
        static let scale = "precessing-prism-tilted.node.scale"
        static let opacity = "precessing-prism-tilted.node.opacity"
        static let zPosition = "precessing-prism-tilted.node.zPosition"
    }

    private struct Geometry {
        let center: CGPoint
        let majorRadius: CGFloat
        let minorRadius: CGFloat
        let guideLineWidth: CGFloat
    }

    private struct NodeState {
        let position: CGPoint
        let scale: CGFloat
        let opacity: Float
        let zPosition: CGFloat
        let accent: AccentToken
        let depth: CGFloat
    }

    private static let side: CGFloat = 18
    private static let nodeDiameter: CGFloat = 3.45
    private static let masterDuration: CFTimeInterval = 8.0
    private static let orbitCyclesPerMaster: CGFloat = 5
    private static let animationStepCount = 120
    private static let basePlaneRadians: CGFloat = 30 * .pi / 180
    private static let planeAmplitudeRadians: CGFloat = 4 * .pi / 180
    private static let reducedMotionMasterPhase: CGFloat = 0
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
    private var animationBounds: CGRect = .null

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
        applyModelState(phase: modelPhaseForCurrentMode(), staticPlane: shouldUseReducedMotionPose)
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
        configureAccessibility(animated: !reducedMotionEnabled, phase: modelPhaseForCurrentMode(), staticPlane: shouldUseReducedMotionPose)
        reconcileAnimationState()
    }

    func stopAnimating() {
        animationRequested = false
        removeAnimations()
        applyModelState(phase: currentSnapshotPhase, staticPlane: false)
        configureAccessibility(animated: false, phase: currentSnapshotPhase, staticPlane: false)
    }

    func setReducedMotion(_ enabled: Bool) {
        guard reducedMotionEnabled != enabled else { return }
        reducedMotionEnabled = enabled
        removeAnimations()
        applyModelState(phase: modelPhaseForCurrentMode(), staticPlane: shouldUseReducedMotionPose)
        configureAccessibility(animated: animationRequested && !enabled, phase: modelPhaseForCurrentMode(), staticPlane: shouldUseReducedMotionPose)
        reconcileAnimationState()
    }

    /// Pins a deterministic master-cycle pose for review. One phase controls both
    /// the fast node orbit and the slow plane precession, avoiding independent
    /// snapshot knobs that could drift from the live animation.
    func setSnapshotPhase(_ phase: CGFloat) {
        animationRequested = false
        currentSnapshotPhase = Self.normalizedPhase(phase)
        removeAnimations()
        applyModelState(phase: currentSnapshotPhase, staticPlane: false)
        configureAccessibility(animated: false, phase: currentSnapshotPhase, staticPlane: false)
    }

    private var canAnimate: Bool {
        window != nil && !isHiddenOrHasHiddenAncestor && bounds.width > 0 && bounds.height > 0
    }

    private var shouldUseReducedMotionPose: Bool {
        reducedMotionEnabled && animationRequested
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
        applyModelState(phase: currentSnapshotPhase, staticPlane: false)
        configureAccessibility(animated: false, phase: currentSnapshotPhase, staticPlane: false)

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
        guideLayer.zPosition = -10
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
            guideLayer.strokeColor = AgentLineRole.decorativeHairline.color.cgColor(in: self).copy(alpha: 0.38)
            for (index, node) in nodeLayers.enumerated() {
                node.fillColor = Self.accents[index].color.cgColor(in: self)
            }
        }
    }

    private func applyModelState(phase: CGFloat, staticPlane: Bool) {
        let geometry = Self.geometry(in: bounds)
        let pose = Self.pose(masterPhase: phase, staticPlane: staticPlane)
        performWithoutLayerActions {
            guideLayer.frame = bounds
            guideLayer.path = Self.orbitGuidePath(center: geometry.center, majorRadius: geometry.majorRadius, minorRadius: geometry.minorRadius, planeAngle: pose.planeAngleRadians)
            guideLayer.lineWidth = geometry.guideLineWidth

            for (index, node) in nodeLayers.enumerated() {
                let state = Self.nodeState(index: index, masterPhase: phase, geometry: geometry, staticPlane: staticPlane)
                let nodeBounds = CGRect(x: 0, y: 0, width: Self.nodeDiameter, height: Self.nodeDiameter)
                node.bounds = nodeBounds
                node.path = CGPath(ellipseIn: nodeBounds, transform: nil)
                node.position = state.position
                node.transform = CATransform3DMakeScale(state.scale, state.scale, 1)
                node.opacity = state.opacity
                node.zPosition = state.zPosition
            }
        }
        setAccessibilityValue(Self.accessibilityValue(for: phase, staticPlane: staticPlane))
    }

    private func reconcileAnimationState() {
        guard animationRequested else {
            removeAnimations()
            return
        }

        guard !reducedMotionEnabled, canAnimate else {
            removeAnimations()
            applyModelState(phase: modelPhaseForCurrentMode(), staticPlane: shouldUseReducedMotionPose)
            configureAccessibility(animated: false, phase: modelPhaseForCurrentMode(), staticPlane: shouldUseReducedMotionPose)
            return
        }

        startAnimationsIfNeeded()
        configureAccessibility(animated: true, phase: currentSnapshotPhase, staticPlane: false)
    }

    private func startAnimationsIfNeeded() {
        let needsInstall = animationBounds != bounds
            || guideLayer.animation(forKey: AnimationKey.guidePath) == nil
            || nodeLayers.enumerated().contains { index, node in
                node.animation(forKey: animationKey(AnimationKey.position, index: index)) == nil
                    || node.animation(forKey: animationKey(AnimationKey.scale, index: index)) == nil
                    || node.animation(forKey: animationKey(AnimationKey.opacity, index: index)) == nil
                    || node.animation(forKey: animationKey(AnimationKey.zPosition, index: index)) == nil
            }

        guard needsInstall else { return }

        removeAnimations()
        applyModelState(phase: currentSnapshotPhase, staticPlane: false)

        let geometry = Self.geometry(in: bounds)
        let keyTimes = (0...Self.animationStepCount).map {
            NSNumber(value: Double($0) / Double(Self.animationStepCount))
        }
        let phases = (0...Self.animationStepCount).map {
            currentSnapshotPhase + CGFloat($0) / CGFloat(Self.animationStepCount)
        }

        let guidePath = CAKeyframeAnimation(keyPath: "path")
        guidePath.values = phases.map { phase in
            let pose = Self.pose(masterPhase: phase, staticPlane: false)
            return Self.orbitGuidePath(
                center: geometry.center,
                majorRadius: geometry.majorRadius,
                minorRadius: geometry.minorRadius,
                planeAngle: pose.planeAngleRadians
            )
        }
        configure(animation: guidePath, keyTimes: keyTimes)
        guideLayer.add(guidePath, forKey: AnimationKey.guidePath)

        for (index, node) in nodeLayers.enumerated() {
            let samples = phases.map { phase in
                Self.nodeState(index: index, masterPhase: phase, geometry: geometry, staticPlane: false)
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

        animationBounds = bounds
    }

    private func configure(animation: CAKeyframeAnimation, keyTimes: [NSNumber]) {
        animation.keyTimes = keyTimes
        animation.duration = Self.masterDuration
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
    }

    private func removeAnimations() {
        guideLayer.removeAnimation(forKey: AnimationKey.guidePath)
        for (index, node) in nodeLayers.enumerated() {
            node.removeAnimation(forKey: animationKey(AnimationKey.position, index: index))
            node.removeAnimation(forKey: animationKey(AnimationKey.scale, index: index))
            node.removeAnimation(forKey: animationKey(AnimationKey.opacity, index: index))
            node.removeAnimation(forKey: animationKey(AnimationKey.zPosition, index: index))
        }
        animationBounds = .null
    }

    private func modelPhaseForCurrentMode() -> CGFloat {
        shouldUseReducedMotionPose ? Self.reducedMotionMasterPhase : currentSnapshotPhase
    }

    private func animationKey(_ base: String, index: Int) -> String {
        "\(base).\(index)"
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        setReducedMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func configureAccessibility(animated: Bool, phase: CGFloat, staticPlane: Bool) {
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(animated ? "Agent thinking, precessing prism" : "Agent thinking, precessing prism snapshot")
        setAccessibilityHelp("Three theme-coloured nodes orbit on a shallow diagonal prism plane while depth is shown with scale and opacity.")
        setAccessibilityValue(Self.accessibilityValue(for: phase, staticPlane: staticPlane))
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

    private static func geometry(in bounds: CGRect) -> Geometry {
        let side = max(1, min(bounds.width, bounds.height))
        return Geometry(
            center: CGPoint(x: bounds.midX, y: bounds.midY),
            majorRadius: max(2.5, side * 0.297),
            minorRadius: max(1.35, side * 0.128),
            guideLineWidth: max(0.55, side * 0.04)
        )
    }

    private static func pose(masterPhase: CGFloat, staticPlane: Bool) -> QAPoseState {
        let master = normalizedPhase(masterPhase)
        let orbit = normalizedPhase(master * orbitCyclesPerMaster)
        let planeAngle = staticPlane
            ? basePlaneRadians
            : basePlaneRadians + planeAmplitudeRadians * sin(master * 2 * .pi)
        return QAPoseState(
            masterPhase: master,
            orbitPhase: orbit,
            planeAngleRadians: planeAngle,
            planeAngleDegrees: planeAngle * 180 / .pi
        )
    }

    private static func nodeState(index: Int, masterPhase: CGFloat, geometry: Geometry, staticPlane: Bool) -> NodeState {
        let pose = pose(masterPhase: masterPhase, staticPlane: staticPlane)
        let angle = baseAngles[index] - pose.orbitPhase * 2 * .pi
        let point = tiltedPoint(
            angle: angle,
            center: geometry.center,
            majorRadius: geometry.majorRadius,
            minorRadius: geometry.minorRadius,
            planeAngle: pose.planeAngleRadians
        )
        let depth = -sin(angle)
        let frontness = smoothstep((depth + 1) / 2)
        return NodeState(
            position: point,
            scale: 0.74 + 0.45 * frontness,
            opacity: Float(0.38 + 0.58 * frontness),
            zPosition: 30 * frontness,
            accent: accents[index],
            depth: depth
        )
    }

    private static func tiltedPoint(angle: CGFloat, center: CGPoint, majorRadius: CGFloat, minorRadius: CGFloat, planeAngle: CGFloat) -> CGPoint {
        let localX = cos(angle) * majorRadius
        let localY = sin(angle) * minorRadius
        let cosTilt = cos(planeAngle)
        let sinTilt = sin(planeAngle)
        return CGPoint(
            x: center.x + localX * cosTilt - localY * sinTilt,
            y: center.y + localX * sinTilt + localY * cosTilt
        )
    }

    private static func orbitGuidePath(center: CGPoint, majorRadius: CGFloat, minorRadius: CGFloat, planeAngle: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let segments = 72
        for step in 0...segments {
            let angle = CGFloat(step) / CGFloat(segments) * 2 * .pi
            let point = tiltedPoint(
                angle: angle,
                center: center,
                majorRadius: majorRadius,
                minorRadius: minorRadius,
                planeAngle: planeAngle
            )
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

    private static func accessibilityValue(for phase: CGFloat, staticPlane: Bool) -> String {
        let pose = pose(masterPhase: phase, staticPlane: staticPlane)
        if staticPlane {
            return "reduced motion, static 30 degree diagonal"
        }
        let masterPercent = Int((pose.masterPhase * 100).rounded())
        let orbitPercent = Int((pose.orbitPhase * 100).rounded())
        let planeDegrees = Int(pose.planeAngleDegrees.rounded())
        return "master phase \(masterPercent) percent, orbit \(orbitPercent) percent, plane \(planeDegrees) degrees"
    }
}

@MainActor
extension PrecessingPrismTiltedThinkingIndicatorView {
    var qaActiveAnimationCount: Int {
        nodeLayers.enumerated().reduce(guideLayer.animation(forKey: AnimationKey.guidePath) == nil ? 0 : 1) { count, pair in
            let (index, node) = pair
            return count
                + (node.animation(forKey: animationKey(AnimationKey.position, index: index)) == nil ? 0 : 1)
                + (node.animation(forKey: animationKey(AnimationKey.scale, index: index)) == nil ? 0 : 1)
                + (node.animation(forKey: animationKey(AnimationKey.opacity, index: index)) == nil ? 0 : 1)
                + (node.animation(forKey: animationKey(AnimationKey.zPosition, index: index)) == nil ? 0 : 1)
        }
    }

    var qaSnapshotPhase: CGFloat { currentSnapshotPhase }

    var qaReducedMotionMasterPhase: CGFloat { Self.reducedMotionMasterPhase }

    var qaPoseState: QAPoseState {
        Self.pose(masterPhase: modelPhaseForCurrentMode(), staticPlane: shouldUseReducedMotionPose)
    }

    var qaNodeStates: [QANodeState] {
        qaNodeStates(forSnapshotPhase: modelPhaseForCurrentMode(), staticPlane: shouldUseReducedMotionPose)
    }

    func qaPoseState(forSnapshotPhase phase: CGFloat) -> QAPoseState {
        Self.pose(masterPhase: phase, staticPlane: false)
    }

    func qaNodeStates(forSnapshotPhase phase: CGFloat, staticPlane: Bool = false) -> [QANodeState] {
        let geometry = Self.geometry(in: bounds)
        return nodeLayers.indices.map { index in
            let state = Self.nodeState(index: index, masterPhase: phase, geometry: geometry, staticPlane: staticPlane)
            return QANodeState(
                index: index,
                position: state.position,
                scale: state.scale,
                opacity: state.opacity,
                zPosition: state.zPosition,
                accent: state.accent,
                depth: state.depth
            )
        }
    }

    var qaIntrinsicSide: CGFloat { Self.side }

    var qaMasterDuration: CFTimeInterval { Self.masterDuration }

    var qaOrbitCyclesPerMaster: CGFloat { Self.orbitCyclesPerMaster }

    var qaPlaneAmplitudeDegrees: CGFloat { Self.planeAmplitudeRadians * 180 / .pi }
}

import AppKit
import ContinuumRevivedAgentUI
import QuartzCore

/// Tilted Prism variation 2 — Dual-plane gyro.
///
/// Visual hierarchy and periods:
/// - Primary plane: two working/input nodes ride the +28° ellipse clockwise,
///   three turns per 7.20s master cycle (2.40s per orbit).
/// - Secondary plane: one approval node rides the -28° ellipse counter to the
///   primary plane, two turns per master cycle (3.60s per orbit).
/// - The 3:2 commensurate ratio lets crossings drift, then resolve cleanly on
///   the master cycle without flashes. Plane guides stay quiet; node scale,
///   opacity, and z-position provide depth while leaving the centre open.
///
/// Live motion is Core Animation keyframes only. The keyframes and deterministic
/// snapshot/reduced-motion poses are all sampled from the same geometry model so
/// QA can inspect a static phase without exercising a separate approximation.
@MainActor
final class DualPlaneGyroTiltedThinkingIndicatorView: NSView, AgentThinkingIndicatorAnimating {
    struct QANodeState: Equatable {
        let index: Int
        let planeIdentifier: String
        let tokenName: String
        let position: CGPoint
        let diameter: CGFloat
        let scale: CGFloat
        let opacity: Float
        let zPosition: CGFloat
        let clearanceFromCenter: CGFloat
    }

    struct QAPlaneReport: Equatable {
        let footprintSide: CGFloat
        let primaryTiltDegrees: CGFloat
        let secondaryTiltDegrees: CGFloat
        let masterDuration: CFTimeInterval
        let primaryOrbitPeriod: CFTimeInterval
        let secondaryOrbitPeriod: CFTimeInterval
        let primaryNodeCount: Int
        let secondaryNodeCount: Int
        let sampledPathFitsFootprint: Bool
        let minimumCenterClearance: CGFloat
        let reducedMotionNodeStates: [QANodeState]
    }

    private enum Plane: String {
        case primary
        case secondary

        var tiltRadians: CGFloat {
            switch self {
            case .primary: return Metrics.primaryTiltRadians
            case .secondary: return Metrics.secondaryTiltRadians
            }
        }

        var depthSign: CGFloat {
            switch self {
            case .primary: return -1
            case .secondary: return 1
            }
        }
    }

    private enum AnimationKey {
        static let position = "dualPlaneGyro.position"
        static let scale = "dualPlaneGyro.scale"
        static let opacity = "dualPlaneGyro.opacity"
        static let zPosition = "dualPlaneGyro.zPosition"
    }

    private enum Metrics {
        static let side: CGFloat = 18
        static let nodeSampleCount = 144
        static let guideSampleCount = 96
        static let masterDuration: CFTimeInterval = 7.20
        static let primaryTurnsPerMaster: CGFloat = -3
        static let secondaryTurnsPerMaster: CGFloat = 2
        static let primaryOrbitPeriod: CFTimeInterval = masterDuration / CFTimeInterval(abs(primaryTurnsPerMaster))
        static let secondaryOrbitPeriod: CFTimeInterval = masterDuration / CFTimeInterval(abs(secondaryTurnsPerMaster))
        static let primaryTiltDegrees: CGFloat = 28
        static let secondaryTiltDegrees: CGFloat = -28
        static let primaryTiltRadians: CGFloat = primaryTiltDegrees * .pi / 180
        static let secondaryTiltRadians: CGFloat = secondaryTiltDegrees * .pi / 180
        static let reducedMotionPhase: CGFloat = 0.185
        static let majorRadiusScale: CGFloat = 0.296
        static let minorRadiusScale: CGFloat = 0.166
        static let guideLineWidthScale: CGFloat = 0.036
        static let primaryGuideAlpha: CGFloat = 0.30
        static let secondaryGuideAlpha: CGFloat = 0.22
        static let centerClearanceSampleCount = 96
    }

    private struct NodeSpec {
        let plane: Plane
        let baseAngle: CGFloat
        let turnsPerMaster: CGFloat
        let diameter: CGFloat
        let token: AccentToken
        let opacityBias: Float
        let scaleBias: CGFloat
    }

    private struct Geometry {
        let bounds: CGRect
        let center: CGPoint
        let majorRadius: CGFloat
        let minorRadius: CGFloat
        let guideLineWidth: CGFloat
    }

    private struct NodeState {
        let plane: Plane
        let token: AccentToken
        let position: CGPoint
        let diameter: CGFloat
        let scale: CGFloat
        let opacity: Float
        let zPosition: CGFloat
    }

    private static let nodeSpecs: [NodeSpec] = [
        NodeSpec(
            plane: .primary,
            baseAngle: -.pi / 2,
            turnsPerMaster: Metrics.primaryTurnsPerMaster,
            diameter: 3.20,
            token: .accentWorking,
            opacityBias: 0,
            scaleBias: 0.02
        ),
        NodeSpec(
            plane: .primary,
            baseAngle: .pi / 2,
            turnsPerMaster: Metrics.primaryTurnsPerMaster,
            diameter: 2.88,
            token: .accentInput,
            opacityBias: -0.05,
            scaleBias: -0.02
        ),
        NodeSpec(
            plane: .secondary,
            baseAngle: .pi * 0.08,
            turnsPerMaster: Metrics.secondaryTurnsPerMaster,
            diameter: 2.64,
            token: .accentApproval,
            opacityBias: -0.03,
            scaleBias: -0.01
        ),
    ]

    private let primaryGuideLayer = CAShapeLayer()
    private let secondaryGuideLayer = CAShapeLayer()
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
        self.nodeLayers = Self.nodeSpecs.map { Self.makeNodeLayer(diameter: $0.diameter) }
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: Metrics.side, height: Metrics.side)))
        configureView()
    }

    override init(frame frameRect: NSRect) {
        self.reducedMotionEnabled = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        self.nodeLayers = Self.nodeSpecs.map { Self.makeNodeLayer(diameter: $0.diameter) }
        super.init(frame: frameRect)
        configureView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        updateContentsScale()
        applyModelState(phase: modelPhaseForCurrentMode())
        if animationRequested && !reducedMotionEnabled {
            removeCompositorAnimations()
        }
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
        applyTokenColors()
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
        configureAccessibility(animated: !reducedMotionEnabled, phase: modelPhaseForCurrentMode())
        reconcileAnimationState()
    }

    func stopAnimating() {
        animationRequested = false
        removeCompositorAnimations()
        applyModelState(phase: currentSnapshotPhase)
        configureAccessibility(animated: false, phase: currentSnapshotPhase)
    }

    func setReducedMotion(_ enabled: Bool) {
        guard reducedMotionEnabled != enabled else { return }
        reducedMotionEnabled = enabled
        removeCompositorAnimations()
        applyModelState(phase: modelPhaseForCurrentMode())
        configureAccessibility(animated: animationRequested && !enabled, phase: modelPhaseForCurrentMode())
        reconcileAnimationState()
    }

    /// Pins a deterministic master-cycle pose for review. This removes live CA
    /// animations; callers explicitly opt back into compositor motion with
    /// `startAnimating()`.
    func setSnapshotPhase(_ phase: CGFloat) {
        animationRequested = false
        currentSnapshotPhase = Self.normalizedPhase(phase)
        removeCompositorAnimations()
        applyModelState(phase: currentSnapshotPhase)
        configureAccessibility(animated: false, phase: currentSnapshotPhase)
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
        applyModelState(phase: modelPhaseForCurrentMode())
        configureAccessibility(animated: false, phase: modelPhaseForCurrentMode())

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

        for guide in [primaryGuideLayer, secondaryGuideLayer] {
            guide.fillColor = nil
            guide.lineCap = .round
            guide.lineJoin = .round
            guide.actions = disabledActions
            guide.zPosition = -2
            layer?.addSublayer(guide)
        }

        for node in nodeLayers {
            node.actions = disabledActions
            layer?.addSublayer(node)
        }
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        primaryGuideLayer.contentsScale = scale
        secondaryGuideLayer.contentsScale = scale
        nodeLayers.forEach { $0.contentsScale = scale }
    }

    private func applyTokenColors() {
        performWithoutLayerActions {
            let guideColor = AgentLineRole.decorativeHairline.color.cgColor(in: self)
            primaryGuideLayer.strokeColor = guideColor.copy(alpha: Metrics.primaryGuideAlpha)
            secondaryGuideLayer.strokeColor = guideColor.copy(alpha: Metrics.secondaryGuideAlpha)

            for (index, node) in nodeLayers.enumerated() {
                node.fillColor = Self.nodeSpecs[index].token.color.cgColor(in: self)
            }
        }
    }

    private func applyModelState(phase: CGFloat) {
        let geometry = Self.geometry(in: bounds)
        performWithoutLayerActions {
            for (plane, guide) in [(Plane.primary, primaryGuideLayer), (.secondary, secondaryGuideLayer)] {
                guide.frame = bounds
                guide.path = Self.planeGuidePath(plane: plane, geometry: geometry)
                guide.lineWidth = geometry.guideLineWidth
            }

            for (index, node) in nodeLayers.enumerated() {
                let state = Self.nodeState(index: index, phase: phase, geometry: geometry)
                let nodeBounds = CGRect(x: 0, y: 0, width: state.diameter, height: state.diameter)
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
            removeCompositorAnimations()
            return
        }

        guard canAnimate else {
            removeCompositorAnimations()
            applyModelState(phase: modelPhaseForCurrentMode())
            configureAccessibility(animated: false, phase: modelPhaseForCurrentMode())
            return
        }

        startCompositorAnimationsIfNeeded()
        configureAccessibility(animated: true, phase: currentSnapshotPhase)
    }

    private func startCompositorAnimationsIfNeeded() {
        let missingAnimation = nodeLayers.enumerated().contains { index, node in
            node.animation(forKey: animationKey(AnimationKey.position, index: index)) == nil
                || node.animation(forKey: animationKey(AnimationKey.scale, index: index)) == nil
                || node.animation(forKey: animationKey(AnimationKey.opacity, index: index)) == nil
                || node.animation(forKey: animationKey(AnimationKey.zPosition, index: index)) == nil
        }
        guard missingAnimation else { return }

        removeCompositorAnimations()
        applyModelState(phase: currentSnapshotPhase)

        let geometry = Self.geometry(in: bounds)
        let keyTimes = (0...Metrics.nodeSampleCount).map { step in
            NSNumber(value: Double(step) / Double(Metrics.nodeSampleCount))
        }

        for (index, node) in nodeLayers.enumerated() {
            let samples = (0...Metrics.nodeSampleCount).map { step in
                Self.nodeState(
                    index: index,
                    phase: currentSnapshotPhase + CGFloat(step) / CGFloat(Metrics.nodeSampleCount),
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
        animation.duration = Metrics.masterDuration
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
    }

    private func removeCompositorAnimations() {
        for (index, node) in nodeLayers.enumerated() {
            node.removeAnimation(forKey: animationKey(AnimationKey.position, index: index))
            node.removeAnimation(forKey: animationKey(AnimationKey.scale, index: index))
            node.removeAnimation(forKey: animationKey(AnimationKey.opacity, index: index))
            node.removeAnimation(forKey: animationKey(AnimationKey.zPosition, index: index))
        }
    }

    private func modelPhaseForCurrentMode() -> CGFloat {
        reducedMotionEnabled && animationRequested ? Metrics.reducedMotionPhase : currentSnapshotPhase
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
        setAccessibilityLabel(animated ? "Agent thinking, dual-plane gyro" : "Agent thinking, dual-plane gyro snapshot")
        setAccessibilityHelp("A restrained three-node constellation crosses two tilted orbital planes while preserving an open center.")
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

    private static func makeNodeLayer(diameter: CGFloat) -> CAShapeLayer {
        let layer = CAShapeLayer()
        let bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        layer.bounds = bounds
        layer.path = CGPath(ellipseIn: bounds, transform: nil)
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        return layer
    }

    private static func geometry(in bounds: CGRect) -> Geometry {
        let side = max(1, min(bounds.width, bounds.height))
        let drawingBounds = CGRect(
            x: bounds.midX - side / 2,
            y: bounds.midY - side / 2,
            width: side,
            height: side
        )
        return Geometry(
            bounds: drawingBounds,
            center: CGPoint(x: drawingBounds.midX, y: drawingBounds.midY),
            majorRadius: max(3.7, side * Metrics.majorRadiusScale),
            minorRadius: max(2.3, side * Metrics.minorRadiusScale),
            guideLineWidth: max(0.55, side * Metrics.guideLineWidthScale)
        )
    }

    private static func nodeState(index: Int, phase: CGFloat, geometry: Geometry) -> NodeState {
        let spec = nodeSpecs[index]
        let angle = spec.baseAngle + normalizedPhase(phase) * 2 * .pi * spec.turnsPerMaster
        let position = projectedPoint(angle: angle, plane: spec.plane, geometry: geometry)
        let depth = spec.plane.depthSign * sin(angle)
        let frontness = smoothstep((depth + 1) / 2)
        let scale = max(0.78, min(1.15, 0.84 + 0.28 * frontness + spec.scaleBias))
        let opacity = max(0.44, min(0.95, Float(0.48 + 0.44 * frontness) + spec.opacityBias))
        return NodeState(
            plane: spec.plane,
            token: spec.token,
            position: position,
            diameter: spec.diameter,
            scale: scale,
            opacity: opacity,
            zPosition: -5 + 12 * frontness
        )
    }

    private static func projectedPoint(angle: CGFloat, plane: Plane, geometry: Geometry) -> CGPoint {
        let localX = cos(angle) * geometry.majorRadius
        let localY = sin(angle) * geometry.minorRadius
        let tilt = plane.tiltRadians
        return CGPoint(
            x: geometry.center.x + localX * cos(tilt) - localY * sin(tilt),
            y: geometry.center.y + localX * sin(tilt) + localY * cos(tilt)
        )
    }

    private static func planeGuidePath(plane: Plane, geometry: Geometry) -> CGPath {
        let path = CGMutablePath()
        for step in 0...Metrics.guideSampleCount {
            let angle = CGFloat(step) / CGFloat(Metrics.guideSampleCount) * 2 * .pi
            let point = projectedPoint(angle: angle, plane: plane, geometry: geometry)
            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }

    private static func qaNodeStates(phase: CGFloat, geometry: Geometry) -> [QANodeState] {
        nodeSpecs.indices.map { index in
            let state = nodeState(index: index, phase: phase, geometry: geometry)
            let radius = state.diameter * state.scale / 2
            let clearance = hypot(state.position.x - geometry.center.x, state.position.y - geometry.center.y) - radius
            return QANodeState(
                index: index,
                planeIdentifier: state.plane.rawValue,
                tokenName: state.token.rawValue,
                position: state.position,
                diameter: state.diameter,
                scale: state.scale,
                opacity: state.opacity,
                zPosition: state.zPosition,
                clearanceFromCenter: clearance
            )
        }
    }

    private static func sampledPathFitsFootprint(geometry: Geometry) -> Bool {
        for step in 0...Metrics.centerClearanceSampleCount {
            let phase = CGFloat(step) / CGFloat(Metrics.centerClearanceSampleCount)
            for index in nodeSpecs.indices {
                let state = nodeState(index: index, phase: phase, geometry: geometry)
                let radius = state.diameter * state.scale / 2
                if state.position.x - radius < geometry.bounds.minX
                    || state.position.x + radius > geometry.bounds.maxX
                    || state.position.y - radius < geometry.bounds.minY
                    || state.position.y + radius > geometry.bounds.maxY {
                    return false
                }
            }
        }
        return true
    }

    private static func minimumCenterClearance(geometry: Geometry) -> CGFloat {
        var minimum = CGFloat.greatestFiniteMagnitude
        for step in 0...Metrics.centerClearanceSampleCount {
            let phase = CGFloat(step) / CGFloat(Metrics.centerClearanceSampleCount)
            for index in nodeSpecs.indices {
                let state = nodeState(index: index, phase: phase, geometry: geometry)
                let radius = state.diameter * state.scale / 2
                let clearance = hypot(state.position.x - geometry.center.x, state.position.y - geometry.center.y) - radius
                minimum = min(minimum, clearance)
            }
        }
        return minimum
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
        return "phase \(percent) percent, primary 2.40 second clockwise plane, secondary 3.60 second counter plane"
    }
}

@MainActor
extension DualPlaneGyroTiltedThinkingIndicatorView {
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
    var qaReducedMotionEnabled: Bool { reducedMotionEnabled }
    var qaReducedMotionPhase: CGFloat { Metrics.reducedMotionPhase }
    var qaAccessibilityLabel: String? { accessibilityLabel() }
    var qaIntrinsicSide: CGFloat { Metrics.side }

    var qaNodeStates: [QANodeState] {
        Self.qaNodeStates(phase: modelPhaseForCurrentMode(), geometry: Self.geometry(in: bounds))
    }

    var qaPlaneReport: QAPlaneReport {
        let geometry = Self.geometry(in: bounds)
        let reducedStates = Self.qaNodeStates(phase: Metrics.reducedMotionPhase, geometry: geometry)
        return QAPlaneReport(
            footprintSide: Metrics.side,
            primaryTiltDegrees: Metrics.primaryTiltDegrees,
            secondaryTiltDegrees: Metrics.secondaryTiltDegrees,
            masterDuration: Metrics.masterDuration,
            primaryOrbitPeriod: Metrics.primaryOrbitPeriod,
            secondaryOrbitPeriod: Metrics.secondaryOrbitPeriod,
            primaryNodeCount: Self.nodeSpecs.filter { $0.plane == .primary }.count,
            secondaryNodeCount: Self.nodeSpecs.filter { $0.plane == .secondary }.count,
            sampledPathFitsFootprint: Self.sampledPathFitsFootprint(geometry: geometry),
            minimumCenterClearance: Self.minimumCenterClearance(geometry: geometry),
            reducedMotionNodeStates: reducedStates
        )
    }
}

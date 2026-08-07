import AppKit
import ContinuumRevivedAgentUI
import QuartzCore

/// Three lab-only derivatives of the dual-plane gyro. They share its compact,
/// open-centre geometry, but keep their visual experiments in one compositor
/// model so snapshot, Reduced Motion, and live keyframes cannot drift apart.
@MainActor
class GyroBrandDerivativeThinkingIndicatorView: NSView, AgentThinkingIndicatorAnimating {
    enum Variant: String {
        case arrayEcho = "array-echo-gyro"
        case signalGrain = "signal-grain-gyro"
        case depthPulse = "depth-pulse-gyro"
        case monochromatic = "monochromatic-gyro"
        case ribbonNoise = "ribbon-noise-gyro"
        case lattice = "lattice-gyro"

        var accessibilityName: String {
            switch self {
            case .arrayEcho: return "array echo gyro"
            case .signalGrain: return "signal grain gyro"
            case .depthPulse: return "depth pulse gyro"
            case .monochromatic: return "monochromatic gyro"
            case .ribbonNoise: return "ribbon noise gyro"
            case .lattice: return "lattice gyro"
            }
        }
    }

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

    struct QAReport: Equatable {
        let variant: String
        let footprintSide: CGFloat
        let nodeCount: Int
        let guideCount: Int
        let sampledPathFitsFootprint: Bool
        let minimumCenterClearance: CGFloat
        let usesDeterministicHarmonics: Bool
        let colorHandoffSamples: Int
        let pathTopology: String
        let nodeShape: String
        let nodePathPointCount: Int
    }

    private enum Plane {
        case primary
        case secondary

        var tiltDegrees: CGFloat { self == .primary ? 28 : -28 }
        var tiltRadians: CGFloat { tiltDegrees * .pi / 180 }
        var depthSign: CGFloat { self == .primary ? -1 : 1 }
        var identifier: String { self == .primary ? "primary" : "secondary" }
    }

    private enum AnimationKey {
        static let position = "gyro-brand.position"
        static let scale = "gyro-brand.scale"
        static let opacity = "gyro-brand.opacity"
        static let zPosition = "gyro-brand.zPosition"
        static let fillColor = "gyro-brand.fillColor"
        static let guidePath = "gyro-brand.guidePath"
    }

    private struct Metrics {
        static let side: CGFloat = 18
        static let sampleCount = 120
        static let geometrySampleCount = 96
        static let duration: CFTimeInterval = 7.20
        static let reducedMotionPhase: CGFloat = 0.185
        static let majorRadiusScale: CGFloat = 0.296
        static let minorRadiusScale: CGFloat = 0.166
        static let guideLineWidthScale: CGFloat = 0.036
        static let monochromeFootprintScale: CGFloat = 1.20
        static let latticeRotation: CGFloat = 0.12
    }

    private struct NodeSpec {
        let plane: Plane
        let baseAngle: CGFloat
        let turnsPerMaster: CGFloat
        let diameter: CGFloat
        let token: AccentToken
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
        NodeSpec(plane: .primary, baseAngle: -.pi / 2, turnsPerMaster: -3, diameter: 3.20, token: .accentWorking),
        NodeSpec(plane: .primary, baseAngle: .pi / 2, turnsPerMaster: -3, diameter: 2.88, token: .accentInput),
        NodeSpec(plane: .secondary, baseAngle: .pi * 0.08, turnsPerMaster: 2, diameter: 2.64, token: .accentApproval),
    ]

    let variant: Variant
    private let primaryGuideLayer = CAShapeLayer()
    private let secondaryGuideLayer = CAShapeLayer()
    private let echoGuideLayer = CAShapeLayer()
    private let nodeLayers: [CAShapeLayer]
    private var animationRequested = false
    private var reducedMotionEnabled: Bool
    private var currentSnapshotPhase: CGFloat = 0
    private(set) var qaColorResolutionGeneration = 0

    override var intrinsicContentSize: NSSize { NSSize(width: Metrics.side, height: Metrics.side) }

    override var isHidden: Bool {
        didSet { reconcileAnimationState() }
    }

    init(variant: Variant, reducedMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        self.variant = variant
        self.reducedMotionEnabled = reducedMotion
        self.nodeLayers = Self.nodeSpecs.map { Self.makeNodeLayer(diameter: $0.diameter) }
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: Metrics.side, height: Metrics.side)))
        configureView()
    }

    override init(frame frameRect: NSRect) {
        self.variant = .arrayEcho
        self.reducedMotionEnabled = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        self.nodeLayers = Self.nodeSpecs.map { Self.makeNodeLayer(diameter: $0.diameter) }
        super.init(frame: frameRect)
        configureView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func layout() {
        super.layout()
        let shouldRebuild = animationRequested && !reducedMotionEnabled && canAnimate
        if shouldRebuild { removeCompositorAnimations() }
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

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if animationRequested { removeCompositorAnimations() }
        applyTokenColors()
        applyModelState(phase: modelPhaseForCurrentMode())
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

    func setSnapshotPhase(_ phase: CGFloat) {
        animationRequested = false
        currentSnapshotPhase = Self.normalizedPhase(phase)
        removeCompositorAnimations()
        applyModelState(phase: currentSnapshotPhase)
        configureAccessibility(animated: false, phase: currentSnapshotPhase)
    }

    private var canAnimate: Bool {
        animationRequested && !reducedMotionEnabled && window != nil && superview != nil
            && !isHiddenOrHasHiddenAncestor && bounds.width > 0 && bounds.height > 0
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
        for guide in [primaryGuideLayer, secondaryGuideLayer, echoGuideLayer] {
            guide.fillColor = nil
            guide.lineCap = .round
            guide.lineJoin = .round
            guide.actions = disabledActions
            guide.zPosition = -2
            layer?.addSublayer(guide)
        }
        nodeLayers.forEach {
            $0.actions = disabledActions
            layer?.addSublayer($0)
        }
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        [primaryGuideLayer, secondaryGuideLayer, echoGuideLayer].forEach { $0.contentsScale = scale }
        nodeLayers.forEach { $0.contentsScale = scale }
    }

    private func applyTokenColors() {
        qaColorResolutionGeneration += 1
        performWithoutLayerActions {
            let guideColor = (variant == .monochromatic ? AccentToken.accentWorking.color : AgentLineRole.decorativeHairline.color).cgColor(in: self)
            primaryGuideLayer.strokeColor = guideColor.copy(alpha: 0.30)
            secondaryGuideLayer.strokeColor = guideColor.copy(alpha: 0.22)
            echoGuideLayer.strokeColor = guideColor.copy(alpha: 0.16)
            for (index, node) in nodeLayers.enumerated() {
                node.fillColor = Self.nodeState(index: index, phase: modelPhaseForCurrentMode(), geometry: Self.geometry(in: bounds), variant: variant).token.color.cgColor(in: self)
            }
        }
    }

    private func applyModelState(phase: CGFloat) {
        let geometry = Self.geometry(in: bounds)
        performWithoutLayerActions {
            primaryGuideLayer.frame = bounds
            primaryGuideLayer.path = Self.guidePath(plane: .primary, phase: phase, geometry: geometry, variant: variant, guideIndex: 0)
            primaryGuideLayer.lineWidth = geometry.guideLineWidth
            secondaryGuideLayer.frame = bounds
            secondaryGuideLayer.path = Self.guidePath(plane: .secondary, phase: phase, geometry: geometry, variant: variant, guideIndex: 1)
            secondaryGuideLayer.lineWidth = geometry.guideLineWidth
            echoGuideLayer.frame = bounds
            echoGuideLayer.path = Self.guidePath(plane: .primary, phase: phase, geometry: geometry, variant: variant, guideIndex: 2)
            echoGuideLayer.lineWidth = geometry.guideLineWidth
            echoGuideLayer.isHidden = variant != .arrayEcho && variant != .lattice

            for (index, node) in nodeLayers.enumerated() {
                let state = Self.nodeState(index: index, phase: phase, geometry: geometry, variant: variant)
                let nodeBounds = CGRect(x: 0, y: 0, width: state.diameter, height: state.diameter)
                node.bounds = nodeBounds
                node.path = Self.nodePath(for: state.diameter, variant: variant)
                node.position = state.position
                node.transform = CATransform3DMakeScale(state.scale, state.scale, 1)
                node.opacity = state.opacity
                node.zPosition = state.zPosition
                node.fillColor = state.token.color.cgColor(in: self)
            }
        }
        setAccessibilityValue(Self.accessibilityValue(for: phase, variant: variant))
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
        let needsNodeAnimations = nodeLayers.enumerated().contains { index, node in
            [AnimationKey.position, AnimationKey.scale, AnimationKey.opacity, AnimationKey.zPosition, AnimationKey.fillColor]
                .contains { node.animation(forKey: animationKey($0, index: index)) == nil }
        }
        let needsEchoAnimation = (variant == .arrayEcho || variant == .lattice) && echoGuideLayer.animation(forKey: animationKey(AnimationKey.guidePath, index: 2)) == nil
        guard needsNodeAnimations || needsEchoAnimation else { return }
        removeCompositorAnimations()
        applyModelState(phase: currentSnapshotPhase)
        let geometry = Self.geometry(in: bounds)
        let keyTimes = (0...Metrics.sampleCount).map { NSNumber(value: Double($0) / Double(Metrics.sampleCount)) }
        let phases = (0...Metrics.sampleCount).map { currentSnapshotPhase + CGFloat($0) / CGFloat(Metrics.sampleCount) }

        for (index, node) in nodeLayers.enumerated() {
            let samples = phases.map { Self.nodeState(index: index, phase: $0, geometry: geometry, variant: variant) }
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
            let fillColor = CAKeyframeAnimation(keyPath: "fillColor")
            fillColor.values = samples.map { $0.token.color.cgColor(in: self) }
            configure(animation: fillColor, keyTimes: keyTimes)
            node.add(fillColor, forKey: animationKey(AnimationKey.fillColor, index: index))
        }

        guard variant == .arrayEcho || variant == .lattice else { return }
        let echoPath = CAKeyframeAnimation(keyPath: "path")
        echoPath.values = phases.map { Self.guidePath(plane: .primary, phase: $0, geometry: geometry, variant: variant, guideIndex: 2) }
        configure(animation: echoPath, keyTimes: keyTimes)
        echoGuideLayer.add(echoPath, forKey: animationKey(AnimationKey.guidePath, index: 2))
    }

    private func configure(animation: CAKeyframeAnimation, keyTimes: [NSNumber]) {
        animation.keyTimes = keyTimes
        animation.duration = Metrics.duration
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
    }

    private func removeCompositorAnimations() {
        for (index, node) in nodeLayers.enumerated() {
            [AnimationKey.position, AnimationKey.scale, AnimationKey.opacity, AnimationKey.zPosition, AnimationKey.fillColor]
                .forEach { node.removeAnimation(forKey: animationKey($0, index: index)) }
        }
        echoGuideLayer.removeAnimation(forKey: animationKey(AnimationKey.guidePath, index: 2))
    }

    private func modelPhaseForCurrentMode() -> CGFloat {
        reducedMotionEnabled && animationRequested ? Metrics.reducedMotionPhase : currentSnapshotPhase
    }

    private func animationKey(_ base: String, index: Int) -> String { "\(base).\(index)" }

    @objc private func accessibilityDisplayOptionsDidChange() {
        setReducedMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func configureAccessibility(animated: Bool, phase: CGFloat) {
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(animated ? "Agent thinking, \(variant.accessibilityName)" : "Agent thinking, \(variant.accessibilityName) snapshot")
        setAccessibilityHelp("A compact open-centre gyro derivative uses semantic accent tokens and compositor-only motion.")
        setAccessibilityValue(Self.accessibilityValue(for: phase, variant: variant))
    }

    private func performWithoutLayerActions(_ work: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        work()
        CATransaction.commit()
    }

    private static var disabledLayerActions: [String: CAAction] {
        ["bounds", "fillColor", "frame", "hidden", "lineWidth", "opacity", "path", "position", "sublayers", "strokeColor", "transform", "zPosition"]
            .reduce(into: [String: CAAction]()) { $0[$1] = NSNull() }
    }

    private static func makeNodeLayer(diameter: CGFloat) -> CAShapeLayer {
        let layer = CAShapeLayer()
        let bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        layer.bounds = bounds
        layer.path = CGPath(ellipseIn: bounds, transform: nil)
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        return layer
    }

    private static func nodePath(for diameter: CGFloat, variant: Variant) -> CGPath {
        let bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        switch variant {
        case .ribbonNoise:
            return CGPath(roundedRect: CGRect(x: diameter * 0.04, y: diameter * 0.31, width: diameter * 0.92, height: diameter * 0.38), cornerWidth: diameter * 0.19, cornerHeight: diameter * 0.19, transform: nil)
        case .lattice:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: diameter * 0.50, y: 0))
            path.addLine(to: CGPoint(x: diameter, y: diameter * 0.50))
            path.addLine(to: CGPoint(x: diameter * 0.50, y: diameter))
            path.addLine(to: CGPoint(x: 0, y: diameter * 0.50))
            path.closeSubpath()
            return path
        default:
            return CGPath(ellipseIn: bounds, transform: nil)
        }
    }

    private static func geometry(in bounds: CGRect) -> Geometry {
        let side = max(1, min(bounds.width, bounds.height))
        let drawingBounds = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        return Geometry(bounds: drawingBounds, center: CGPoint(x: drawingBounds.midX, y: drawingBounds.midY), majorRadius: max(3.7, side * Metrics.majorRadiusScale), minorRadius: max(2.3, side * Metrics.minorRadiusScale), guideLineWidth: max(0.55, side * Metrics.guideLineWidthScale))
    }

    private static func nodeState(index: Int, phase: CGFloat, geometry: Geometry, variant: Variant) -> NodeState {
        let spec = nodeSpecs[index]
        let normalized = normalizedPhase(phase)
        let noise = variant == .ribbonNoise ? organicModulation(phase: normalized, index: index) : 0
        let angle = spec.baseAngle + normalized * 2 * .pi * spec.turnsPerMaster + noise * 0.24
        let position: CGPoint
        if variant == .lattice {
            position = latticePoint(index: index, phase: normalized, geometry: geometry)
        } else {
            let footprintScale = variant == .monochromatic ? Metrics.monochromeFootprintScale : 1
            position = projectedPoint(
                angle: angle,
                plane: spec.plane,
                geometry: geometry,
                radialScale: footprintScale * (1 + noise * 0.18))
        }
        let frontness = smoothstep((spec.plane.depthSign * sin(angle) + 1) / 2)
        let grain = variant == .signalGrain ? organicModulation(phase: normalized, index: index) : 0
        let crossing = smoothstep(1 - abs(frontness - 0.5) * 2)
        let diameter: CGFloat
        let scale: CGFloat
        let opacity: Float
        if variant == .depthPulse {
            diameter = [3.85, 2.55, 3.25][index]
            scale = clamp(0.72 + 0.50 * frontness + 0.05 * crossing, lower: 0.68, upper: 1.24)
            opacity = Float(clamp(0.38 + 0.60 * frontness + 0.08 * crossing, lower: 0.34, upper: 1))
        } else if variant == .ribbonNoise {
            diameter = [3.65, 3.35, 3.05][index]
            scale = clamp(0.86 + 0.26 * frontness + noise, lower: 0.76, upper: 1.18)
            opacity = Float(clamp(0.47 + 0.45 * frontness + noise * 0.50, lower: 0.42, upper: 0.96))
        } else {
            diameter = spec.diameter * (variant == .monochromatic ? Metrics.monochromeFootprintScale : 1)
            scale = clamp(0.84 + 0.28 * frontness + grain, lower: 0.76, upper: 1.16)
            opacity = Float(clamp(0.48 + 0.44 * frontness + grain * 0.62, lower: 0.42, upper: 0.96))
        }
        let token: AccentToken
        if variant == .monochromatic {
            token = .accentWorking
        } else if variant == .depthPulse && frontness > 0.62 {
            token = index == 2 ? .accentApproval : .accentWorking
        } else {
            token = spec.token
        }
        return NodeState(plane: spec.plane, token: token, position: position, diameter: diameter, scale: scale, opacity: opacity, zPosition: variant == .depthPulse ? -6 + 22 * frontness : -5 + 12 * frontness)
    }

    private static func guidePath(plane: Plane, phase: CGFloat, geometry: Geometry, variant: Variant, guideIndex: Int) -> CGPath {
        let path = CGMutablePath()
        if variant == .lattice && guideIndex == 2 {
            let points = latticePoints(phase: phase, geometry: geometry)
            path.move(to: points[0])
            path.addLine(to: points[1])
            path.addLine(to: points[2])
            path.closeSubpath()
            return path
        }
        let offsetAmount: CGFloat
        if variant == .arrayEcho {
            offsetAmount = guideIndex == 2 ? 1.0 + 0.45 * sin(normalizedPhase(phase) * 2 * .pi) : (guideIndex == 1 ? -0.35 : 0)
        } else {
            offsetAmount = 0
        }
        let centerOffset = CGPoint(x: offsetAmount * cos(plane.tiltRadians), y: offsetAmount * sin(plane.tiltRadians))
        for step in 0...72 {
            let angle = CGFloat(step) / 72 * 2 * .pi + (variant == .arrayEcho && guideIndex == 2 ? normalizedPhase(phase) * .pi / 8 : 0)
            let footprintScale = variant == .monochromatic ? Metrics.monochromeFootprintScale : 1
            let point = projectedPoint(angle: angle, plane: plane, geometry: geometry, radialScale: footprintScale)
            let shifted = CGPoint(x: point.x + centerOffset.x, y: point.y + centerOffset.y)
            if step == 0 { path.move(to: shifted) } else { path.addLine(to: shifted) }
        }
        path.closeSubpath()
        return path
    }

    private static func projectedPoint(angle: CGFloat, plane: Plane, geometry: Geometry, radialScale: CGFloat = 1) -> CGPoint {
        let localX = cos(angle) * geometry.majorRadius * radialScale
        let localY = sin(angle) * geometry.minorRadius * radialScale
        return CGPoint(x: geometry.center.x + localX * cos(plane.tiltRadians) - localY * sin(plane.tiltRadians), y: geometry.center.y + localX * sin(plane.tiltRadians) + localY * cos(plane.tiltRadians))
    }

    private static func latticePoints(phase: CGFloat, geometry: Geometry) -> [CGPoint] {
        let rotation = normalizedPhase(phase) * 2 * .pi + Metrics.latticeRotation
        let angles: [CGFloat] = [-CGFloat.pi / 2, 5 * CGFloat.pi / 6, CGFloat.pi / 6]
        return angles.map { angle in
            CGPoint(x: geometry.center.x + cos(angle + rotation) * geometry.majorRadius * 0.78,
                    y: geometry.center.y + sin(angle + rotation) * geometry.minorRadius * 1.28)
        }
    }

    private static func latticePoint(index: Int, phase: CGFloat, geometry: Geometry) -> CGPoint {
        latticePoints(phase: phase, geometry: geometry)[index]
    }

    private static func organicModulation(phase: CGFloat, index: Int) -> CGFloat {
        let t = phase * 2 * .pi
        return 0.042 * sin(t * 2 + CGFloat(index) * 0.71) + 0.021 * sin(t * 5 - CGFloat(index) * 1.13) + 0.012 * sin(t * 7 + CGFloat(index) * 1.91)
    }

    private static func smoothstep(_ value: CGFloat) -> CGFloat {
        let clamped = clamp(value, lower: 0, upper: 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat { min(upper, max(lower, value)) }

    private static func normalizedPhase(_ phase: CGFloat) -> CGFloat {
        guard phase.isFinite else { return 0 }
        let remainder = phase.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }

    private static func accessibilityValue(for phase: CGFloat, variant: Variant) -> String {
        let percent = Int((normalizedPhase(phase) * 100).rounded())
        return "phase \(percent) percent, \(variant.accessibilityName), open centre"
    }

    private static func qaNodeStates(phase: CGFloat, geometry: Geometry, variant: Variant) -> [QANodeState] {
        nodeSpecs.indices.map { index in
            let state = nodeState(index: index, phase: phase, geometry: geometry, variant: variant)
            let radius = state.diameter * state.scale / 2
            return QANodeState(index: index, planeIdentifier: state.plane.identifier, tokenName: state.token.rawValue, position: state.position, diameter: state.diameter, scale: state.scale, opacity: state.opacity, zPosition: state.zPosition, clearanceFromCenter: hypot(state.position.x - geometry.center.x, state.position.y - geometry.center.y) - radius)
        }
    }

    private static func pathFitsFootprint(geometry: Geometry, variant: Variant) -> Bool {
        for step in 0...Metrics.geometrySampleCount {
            let phase = CGFloat(step) / CGFloat(Metrics.geometrySampleCount)
            for index in nodeSpecs.indices {
                let state = nodeState(index: index, phase: phase, geometry: geometry, variant: variant)
                let radius = state.diameter * state.scale / 2
                guard state.position.x - radius >= geometry.bounds.minX, state.position.x + radius <= geometry.bounds.maxX, state.position.y - radius >= geometry.bounds.minY, state.position.y + radius <= geometry.bounds.maxY else { return false }
            }
        }
        return true
    }

    private static func minimumClearance(geometry: Geometry, variant: Variant) -> CGFloat {
        var minimum = CGFloat.greatestFiniteMagnitude
        for step in 0...Metrics.geometrySampleCount {
            let phase = CGFloat(step) / CGFloat(Metrics.geometrySampleCount)
            for state in qaNodeStates(phase: phase, geometry: geometry, variant: variant) { minimum = min(minimum, state.clearanceFromCenter) }
        }
        return minimum
    }

    private static func colorHandoffSamples(variant: Variant) -> Int {
        guard variant == .depthPulse else { return 0 }
        var previous = Array<AccentToken?>(repeating: nil, count: nodeSpecs.count)
        var changes = 0
        let geometry = Geometry(bounds: CGRect(x: 0, y: 0, width: Metrics.side, height: Metrics.side), center: CGPoint(x: 9, y: 9), majorRadius: Metrics.side * Metrics.majorRadiusScale, minorRadius: Metrics.side * Metrics.minorRadiusScale, guideLineWidth: 0.6)
        for step in 0...Metrics.geometrySampleCount {
            let phase = CGFloat(step) / CGFloat(Metrics.geometrySampleCount)
            for index in nodeSpecs.indices {
                let current = nodeState(index: index, phase: phase, geometry: geometry, variant: variant).token
                if let prior = previous[index], prior != current { changes += 1 }
                previous[index] = current
            }
        }
        return changes
    }

    var qaActiveAnimationCount: Int {
        let nodeCount = nodeLayers.enumerated().reduce(0) { count, pair in
            let (index, node) = pair
            return count + [AnimationKey.position, AnimationKey.scale, AnimationKey.opacity, AnimationKey.zPosition, AnimationKey.fillColor].reduce(0) { result, key in result + (node.animation(forKey: animationKey(key, index: index)) == nil ? 0 : 1) }
        }
        return nodeCount + (echoGuideLayer.animation(forKey: animationKey(AnimationKey.guidePath, index: 2)) == nil ? 0 : 1)
    }

    var qaSnapshotPhase: CGFloat { currentSnapshotPhase }
    var qaReducedMotionEnabled: Bool { reducedMotionEnabled }
    var qaReducedMotionPhase: CGFloat { Metrics.reducedMotionPhase }
    var qaAccessibilityLabel: String? { accessibilityLabel() }
    var qaIntrinsicSide: CGFloat { Metrics.side }
    var qaNodeStates: [QANodeState] { Self.qaNodeStates(phase: modelPhaseForCurrentMode(), geometry: Self.geometry(in: bounds), variant: variant) }
    var qaUsesDeterministicHarmonics: Bool { variant == .signalGrain || variant == .ribbonNoise }
    var qaGuideCount: Int { variant == .arrayEcho || variant == .lattice ? 3 : 2 }
    var qaPathTopology: String {
        switch variant {
        case .lattice: return "rotating-triangle"
        case .ribbonNoise: return "band-limited-wobble"
        default: return "dual-tilted-ellipse"
        }
    }
    var qaNodeShape: String {
        switch variant {
        case .ribbonNoise: return "capsule-ribbon"
        case .lattice: return "diamond"
        default: return "circle"
        }
    }
    var qaNodePathPointCount: Int {
        switch variant {
        case .ribbonNoise: return 4
        case .lattice: return 4
        default: return 0
        }
    }
    var qaFootprintFits: Bool { Self.pathFitsFootprint(geometry: Self.geometry(in: bounds), variant: variant) }
    var qaMinimumCenterClearance: CGFloat { Self.minimumClearance(geometry: Self.geometry(in: bounds), variant: variant) }
    var qaColorHandoffSamples: Int { Self.colorHandoffSamples(variant: variant) }
    var qaReport: QAReport {
        QAReport(variant: variant.rawValue, footprintSide: Metrics.side, nodeCount: nodeLayers.count,
                 guideCount: qaGuideCount, sampledPathFitsFootprint: qaFootprintFits,
                 minimumCenterClearance: qaMinimumCenterClearance,
                 usesDeterministicHarmonics: qaUsesDeterministicHarmonics,
                 colorHandoffSamples: qaColorHandoffSamples,
                 pathTopology: qaPathTopology, nodeShape: qaNodeShape,
                 nodePathPointCount: qaNodePathPointCount)
    }
}

@MainActor
final class ArrayEchoGyroThinkingIndicatorView: GyroBrandDerivativeThinkingIndicatorView {
    init(reducedMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) { super.init(variant: .arrayEcho, reducedMotion: reducedMotion) }
    override init(frame frameRect: NSRect) {
        super.init(variant: .arrayEcho, reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        frame = frameRect
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor
final class SignalGrainGyroThinkingIndicatorView: GyroBrandDerivativeThinkingIndicatorView {
    init(reducedMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) { super.init(variant: .signalGrain, reducedMotion: reducedMotion) }
    override init(frame frameRect: NSRect) {
        super.init(variant: .signalGrain, reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        frame = frameRect
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor
final class DepthPulseGyroThinkingIndicatorView: GyroBrandDerivativeThinkingIndicatorView {
    init(reducedMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) { super.init(variant: .depthPulse, reducedMotion: reducedMotion) }
    override init(frame frameRect: NSRect) {
        super.init(variant: .depthPulse, reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        frame = frameRect
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor
final class MonochromeGyroThinkingIndicatorView: GyroBrandDerivativeThinkingIndicatorView {
    init(reducedMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) { super.init(variant: .monochromatic, reducedMotion: reducedMotion) }
    override init(frame frameRect: NSRect) {
        super.init(variant: .monochromatic, reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        frame = frameRect
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor
final class RibbonNoiseGyroThinkingIndicatorView: GyroBrandDerivativeThinkingIndicatorView {
    init(reducedMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) { super.init(variant: .ribbonNoise, reducedMotion: reducedMotion) }
    override init(frame frameRect: NSRect) {
        super.init(variant: .ribbonNoise, reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        frame = frameRect
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor
final class LatticeGyroThinkingIndicatorView: GyroBrandDerivativeThinkingIndicatorView {
    init(reducedMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) { super.init(variant: .lattice, reducedMotion: reducedMotion) }
    override init(frame frameRect: NSRect) {
        super.init(variant: .lattice, reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        frame = frameRect
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

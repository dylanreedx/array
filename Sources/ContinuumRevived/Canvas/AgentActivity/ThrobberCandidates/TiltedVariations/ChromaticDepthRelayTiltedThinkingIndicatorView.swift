import AppKit
import ContinuumRevivedAgentUI
import QuartzCore

/// Tilted prism variation 1: a chromatic relay on a physically tilted orbital plane.
///
/// The spatial model stays the same calm ~30° ellipse for every node: position and
/// z-depth come only from the orbital angle. Separately, a three-stop relay moves
/// the lead/mid/trail emphasis across the semantic accent colours every third of
/// an orbit, so chroma, opacity, and scale hand off without making "front" and
/// "lead" the same concept. Live motion is Core Animation keyframes only; static
/// QA poses and Reduced Motion use the same model function as the animation.
@MainActor
final class ChromaticDepthRelayTiltedThinkingIndicatorView: NSView, AgentThinkingIndicatorAnimating {
    enum RelayRole: Int, CaseIterable, Equatable {
        case lead
        case mid
        case trail

        var accessibilityName: String {
            switch self {
            case .lead: return "lead"
            case .mid: return "mid"
            case .trail: return "trail"
            }
        }
    }

    struct QANodeState: Equatable {
        let index: Int
        let position: CGPoint
        let scale: CGFloat
        let opacity: Float
        let zPosition: CGFloat
        let depthFrontness: CGFloat
        let relayRole: RelayRole
        let relayWeights: [CGFloat]
        let chromaAlpha: CGFloat
        let dominantAccent: AccentToken
    }

    private enum AnimationKey {
        static let position = "chromatic-depth-relay.position"
        static let scale = "chromatic-depth-relay.scale"
        static let opacity = "chromatic-depth-relay.opacity"
        static let zPosition = "chromatic-depth-relay.zPosition"
        static let fillColor = "chromatic-depth-relay.fillColor"
    }

    private struct NodeState {
        let position: CGPoint
        let scale: CGFloat
        let opacity: Float
        let zPosition: CGFloat
        let depthFrontness: CGFloat
        let relayRole: RelayRole
        let relayWeights: [CGFloat]
        let chromaAlpha: CGFloat
        let dominantAccent: AccentToken
    }

    private struct ColorComponents {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
    }

    private static let side: CGFloat = 18
    private static let nodeDiameter: CGFloat = 3.35
    private static let duration: CFTimeInterval = 1.62
    private static let animationStepCount = 96
    private static let tiltRadians: CGFloat = 30 * .pi / 180
    private static let reducedMotionPhase: CGFloat = 0.055
    private static let baseAngles: [CGFloat] = [
        -.pi / 2,
        -.pi / 2 - (2 * .pi / 3),
        -.pi / 2 - (4 * .pi / 3),
    ]

    /// Lead, mid, trail in relay order. These are existing semantic status tokens;
    /// no attention or failure state colour participates in this decorative prism.
    private static let roleAccents: [AccentToken] = [
        .accentWorking,
        .accentInput,
        .accentApproval,
    ]
    private static let roleScales: [CGFloat] = [1.10, 0.96, 0.84]
    private static let roleOpacities: [CGFloat] = [1.00, 0.78, 0.56]
    private static let roleChromaAlphas: [CGFloat] = [1.00, 0.82, 0.64]

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
        self.nodeLayers = Self.roleAccents.map { _ in Self.makeNodeLayer() }
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: Self.side, height: Self.side)))
        configureView()
    }

    override init(frame frameRect: NSRect) {
        self.reducedMotionEnabled = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        self.nodeLayers = Self.roleAccents.map { _ in Self.makeNodeLayer() }
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
        removeAnimations()
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

    /// Pins a deterministic model-layer pose for review. The relay colour mix,
    /// spatial depth, scale, and opacity are all produced by the live model math.
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

    private func applyModelState(phase: CGFloat) {
        let geometry = Self.geometry(in: bounds)
        performWithoutLayerActions {
            guideLayer.frame = bounds
            guideLayer.path = Self.orbitGuidePath(center: geometry.center, majorRadius: geometry.majorRadius, minorRadius: geometry.minorRadius)
            guideLayer.lineWidth = geometry.guideLineWidth
            guideLayer.strokeColor = AgentLineRole.decorativeHairline.color.cgColor(in: self).copy(alpha: 0.38)

            for (index, node) in nodeLayers.enumerated() {
                let state = Self.nodeState(index: index, phase: phase, geometry: geometry)
                let nodeBounds = CGRect(x: 0, y: 0, width: Self.nodeDiameter, height: Self.nodeDiameter)
                node.bounds = nodeBounds
                node.path = CGPath(ellipseIn: nodeBounds, transform: nil)
                node.position = state.position
                node.transform = CATransform3DMakeScale(state.scale, state.scale, 1)
                node.opacity = state.opacity
                node.zPosition = state.zPosition
                node.fillColor = resolvedRelayColor(for: state)
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
            node.animation(forKey: animationKey(AnimationKey.zPosition, index: index)) == nil ||
            node.animation(forKey: animationKey(AnimationKey.fillColor, index: index)) == nil
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

            let fillColor = CAKeyframeAnimation(keyPath: "fillColor")
            fillColor.values = samples.map { resolvedRelayColor(for: $0) }
            configure(animation: fillColor, keyTimes: keyTimes)
            node.add(fillColor, forKey: animationKey(AnimationKey.fillColor, index: index))
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
            node.removeAnimation(forKey: animationKey(AnimationKey.fillColor, index: index))
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
        setAccessibilityLabel(animated ? "Agent thinking, chromatic depth relay" : "Agent thinking, chromatic depth relay snapshot")
        setAccessibilityHelp("Three semantic accent nodes relay lead, mid, and trail emphasis around a tilted diagonal orbit while depth remains spatial.")
        setAccessibilityValue(Self.accessibilityValue(for: phase))
    }

    private func resolvedRelayColor(for state: NodeState) -> CGColor {
        let tokenColors = Self.roleAccents.map { components(for: $0) }
        let mixed = zip(tokenColors, state.relayWeights).reduce(ColorComponents(red: 0, green: 0, blue: 0, alpha: 0)) { partial, pair in
            let (color, weight) = pair
            return ColorComponents(
                red: partial.red + color.red * weight,
                green: partial.green + color.green * weight,
                blue: partial.blue + color.blue * weight,
                alpha: partial.alpha + color.alpha * weight
            )
        }
        let alpha = min(1, max(0, mixed.alpha * state.chromaAlpha))
        return CGColor(red: mixed.red, green: mixed.green, blue: mixed.blue, alpha: alpha)
    }

    private func components(for accent: AccentToken) -> ColorComponents {
        let cgColor = accent.color.cgColor(in: self)
        let nsColor = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB)
        return ColorComponents(
            red: nsColor?.redComponent ?? 0,
            green: nsColor?.greenComponent ?? 0,
            blue: nsColor?.blueComponent ?? 0,
            alpha: nsColor?.alphaComponent ?? 1
        )
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
        let weights = relayWeights(index: index, phase: phase)
        let roleScale = weighted(Self.roleScales, by: weights)
        let roleOpacity = weighted(Self.roleOpacities, by: weights)
        let chromaAlpha = weighted(Self.roleChromaAlphas, by: weights)
        let depthScale = 0.93 + 0.16 * frontness
        let depthOpacity = 0.86 + 0.14 * frontness
        let dominantRole = dominantRelayRole(weights)
        return NodeState(
            position: point,
            scale: depthScale * roleScale,
            opacity: Float(depthOpacity * roleOpacity),
            zPosition: 10 * frontness,
            depthFrontness: frontness,
            relayRole: dominantRole,
            relayWeights: weights,
            chromaAlpha: chromaAlpha,
            dominantAccent: roleAccents[dominantRole.rawValue]
        )
    }

    private static func relayWeights(index: Int, phase: CGFloat) -> [CGFloat] {
        // Relay order intentionally runs counter to the 120° spatial offsets so
        // lead/mid/trail emphasis is not a synonym for front/side/back depth.
        let relayOffset = CGFloat((index * 2) % 3) / 3
        let cycle = normalizedPhase(phase + relayOffset)
        let scaled = cycle * 3
        let fromRole = min(2, Int(floor(scaled)))
        let toRole = (fromRole + 1) % 3
        let progress = smootherstep(scaled - CGFloat(fromRole))
        var weights = [CGFloat](repeating: 0, count: 3)
        weights[fromRole] = 1 - progress
        weights[toRole] = progress
        return weights
    }

    private static func dominantRelayRole(_ weights: [CGFloat]) -> RelayRole {
        let index = weights.enumerated().max { lhs, rhs in lhs.element < rhs.element }?.offset ?? 0
        return RelayRole(rawValue: index) ?? .lead
    }

    private static func weighted(_ values: [CGFloat], by weights: [CGFloat]) -> CGFloat {
        zip(values, weights).reduce(0) { $0 + $1.0 * $1.1 }
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

    private static func smootherstep(_ value: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, value))
        return clamped * clamped * clamped * (clamped * (clamped * 6 - 15) + 10)
    }

    private static func normalizedPhase(_ phase: CGFloat) -> CGFloat {
        guard phase.isFinite else { return 0 }
        let remainder = phase.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }

    private static func accessibilityValue(for phase: CGFloat) -> String {
        let normalized = normalizedPhase(phase)
        let percent = Int((normalized * 100).rounded())
        let relayStep = Int(floor(normalized * 3)) + 1
        return "phase \(percent) percent, relay \(relayStep) of 3 on tilted diagonal orbit"
    }
}

@MainActor
extension ChromaticDepthRelayTiltedThinkingIndicatorView {
    var qaActiveAnimationCount: Int {
        nodeLayers.enumerated().reduce(0) { count, pair in
            let (index, node) = pair
            return count
                + (node.animation(forKey: animationKey(AnimationKey.position, index: index)) == nil ? 0 : 1)
                + (node.animation(forKey: animationKey(AnimationKey.scale, index: index)) == nil ? 0 : 1)
                + (node.animation(forKey: animationKey(AnimationKey.opacity, index: index)) == nil ? 0 : 1)
                + (node.animation(forKey: animationKey(AnimationKey.zPosition, index: index)) == nil ? 0 : 1)
                + (node.animation(forKey: animationKey(AnimationKey.fillColor, index: index)) == nil ? 0 : 1)
        }
    }

    var qaSnapshotPhase: CGFloat { currentSnapshotPhase }

    var qaReducedMotionPhase: CGFloat { Self.reducedMotionPhase }

    var qaAccentTokens: [AccentToken] { Self.roleAccents }

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
                depthFrontness: state.depthFrontness,
                relayRole: state.relayRole,
                relayWeights: state.relayWeights,
                chromaAlpha: state.chromaAlpha,
                dominantAccent: state.dominantAccent
            )
        }
    }

    var qaIntrinsicSide: CGFloat { Self.side }
}

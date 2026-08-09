import AppKit
import ContinuumRevivedAgentUI
import QuartzCore

/// Tilted prism variation 5: three theme-token comet nodes on a compact prismatic plane.
///
/// The live indicator is pure Core Animation compositor work. Nodes and their short
/// discrete ghost-bead trails are sampled from the same tilted ellipse, so static QA
/// poses and live keyframes share one deterministic geometry path. There is no guide
/// stroke or blurred spinner ring: direction is carried only by two restrained beads
/// behind each semantic node.
@MainActor
final class PrismaticCometTiltedThinkingIndicatorView: NSView, AgentThinkingIndicatorAnimating {
    struct QANodeState: Equatable {
        let index: Int
        let position: CGPoint
        let scale: CGFloat
        let opacity: Float
        let zPosition: CGFloat
        let accent: AccentToken
    }

    struct QATrailBeadState: Equatable {
        let nodeIndex: Int
        let beadIndex: Int
        let position: CGPoint
        let diameter: CGFloat
        let scale: CGFloat
        let opacity: Float
        let zPosition: CGFloat
        let accent: AccentToken
    }

    private enum AnimationKey {
        static let nodePosition = "prismatic-comet-tilted.node.position"
        static let nodeScale = "prismatic-comet-tilted.node.scale"
        static let nodeOpacity = "prismatic-comet-tilted.node.opacity"
        static let nodeZPosition = "prismatic-comet-tilted.node.zPosition"
        static let trailPosition = "prismatic-comet-tilted.trail.position"
        static let trailScale = "prismatic-comet-tilted.trail.scale"
        static let trailOpacity = "prismatic-comet-tilted.trail.opacity"
        static let trailZPosition = "prismatic-comet-tilted.trail.zPosition"
    }

    private struct NodeState {
        let position: CGPoint
        let scale: CGFloat
        let opacity: Float
        let zPosition: CGFloat
        let accent: AccentToken
    }

    private struct TrailBeadState {
        let nodeIndex: Int
        let beadIndex: Int
        let position: CGPoint
        let diameter: CGFloat
        let scale: CGFloat
        let opacity: Float
        let zPosition: CGFloat
        let accent: AccentToken
    }

    private static let side: CGFloat = 18
    private static let nodeDiameter: CGFloat = 3.15
    private static let duration: CFTimeInterval = 1.58
    private static let animationStepCount = 84
    private static let tiltRadians: CGFloat = 34 * .pi / 180
    private static let phaseLiftAmplitude: CGFloat = 0.012
    private static let reducedMotionPhase: CGFloat = 0
    private static let trailPhaseOffsets: [CGFloat] = [0.043, 0.086]
    private static let trailDiameters: [CGFloat] = [1.55, 1.18]
    private static let trailBaseOpacities: [CGFloat] = [0.27, 0.13]
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

    private let nodeLayers: [CAShapeLayer]
    private let trailLayers: [[CAShapeLayer]]
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
        self.trailLayers = Self.accents.map { _ in Self.makeTrailLayers() }
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: Self.side, height: Self.side)))
        configureView()
    }

    override init(frame frameRect: NSRect) {
        self.reducedMotionEnabled = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        self.nodeLayers = Self.accents.map { _ in Self.makeNodeLayer() }
        self.trailLayers = Self.accents.map { _ in Self.makeTrailLayers() }
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

    /// Pins a deterministic model-layer pose for review. Trail beads are sampled
    /// from the same tilted ellipse as live keyframes, offset behind each node.
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

        for nodeTrails in trailLayers {
            for trail in nodeTrails {
                trail.actions = disabledActions
                layer?.addSublayer(trail)
            }
        }

        for node in nodeLayers {
            node.actions = disabledActions
            layer?.addSublayer(node)
        }
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        nodeLayers.forEach { $0.contentsScale = scale }
        trailLayers.flatMap { $0 }.forEach { $0.contentsScale = scale }
    }

    private func applyTokenColors() {
        performWithoutLayerActions {
            for (index, node) in nodeLayers.enumerated() {
                let color = Self.accents[index].color.cgColor(in: self)
                node.fillColor = color
                for trail in trailLayers[index] {
                    trail.fillColor = color
                }
            }
        }
    }

    private func applyModelState(phase: CGFloat) {
        let geometry = Self.geometry(in: bounds)
        performWithoutLayerActions {
            for (nodeIndex, node) in nodeLayers.enumerated() {
                let state = nodeState(index: nodeIndex, phase: phase, geometry: geometry)
                let nodeBounds = CGRect(x: 0, y: 0, width: Self.nodeDiameter, height: Self.nodeDiameter)
                node.bounds = nodeBounds
                node.path = CGPath(ellipseIn: nodeBounds, transform: nil)
                node.position = state.position
                node.transform = CATransform3DMakeScale(state.scale, state.scale, 1)
                node.opacity = state.opacity
                node.zPosition = state.zPosition

                for (beadIndex, trail) in trailLayers[nodeIndex].enumerated() {
                    let bead = trailBeadState(nodeIndex: nodeIndex, beadIndex: beadIndex, phase: phase, geometry: geometry)
                    let beadBounds = CGRect(x: 0, y: 0, width: bead.diameter, height: bead.diameter)
                    trail.bounds = beadBounds
                    trail.path = CGPath(ellipseIn: beadBounds, transform: nil)
                    trail.position = bead.position
                    trail.transform = CATransform3DMakeScale(bead.scale, bead.scale, 1)
                    trail.opacity = bead.opacity
                    trail.zPosition = bead.zPosition
                }
            }
        }
        setAccessibilityValue(Self.accessibilityValue(for: phase, reducedMotion: usesReducedMotionCluster))
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

    private var usesReducedMotionCluster: Bool {
        reducedMotionEnabled && animationRequested
    }

    private func startAnimationsIfNeeded() {
        let nodeNeedsInstall = nodeLayers.enumerated().contains { index, node in
            node.animation(forKey: nodeAnimationKey(AnimationKey.nodePosition, index: index)) == nil ||
            node.animation(forKey: nodeAnimationKey(AnimationKey.nodeScale, index: index)) == nil ||
            node.animation(forKey: nodeAnimationKey(AnimationKey.nodeOpacity, index: index)) == nil ||
            node.animation(forKey: nodeAnimationKey(AnimationKey.nodeZPosition, index: index)) == nil
        }
        let trailNeedsInstall = trailLayers.enumerated().contains { nodeIndex, trails in
            trails.enumerated().contains { beadIndex, trail in
                trail.animation(forKey: trailAnimationKey(AnimationKey.trailPosition, nodeIndex: nodeIndex, beadIndex: beadIndex)) == nil ||
                trail.animation(forKey: trailAnimationKey(AnimationKey.trailScale, nodeIndex: nodeIndex, beadIndex: beadIndex)) == nil ||
                trail.animation(forKey: trailAnimationKey(AnimationKey.trailOpacity, nodeIndex: nodeIndex, beadIndex: beadIndex)) == nil ||
                trail.animation(forKey: trailAnimationKey(AnimationKey.trailZPosition, nodeIndex: nodeIndex, beadIndex: beadIndex)) == nil
            }
        }
        guard nodeNeedsInstall || trailNeedsInstall else { return }

        removeAnimations()
        applyModelState(phase: currentSnapshotPhase)

        let geometry = Self.geometry(in: bounds)
        let keyTimes = (0...Self.animationStepCount).map {
            NSNumber(value: Double($0) / Double(Self.animationStepCount))
        }

        for (index, node) in nodeLayers.enumerated() {
            let samples = (0...Self.animationStepCount).map { step in
                nodeState(
                    index: index,
                    phase: currentSnapshotPhase + CGFloat(step) / CGFloat(Self.animationStepCount),
                    geometry: geometry
                )
            }

            let position = CAKeyframeAnimation(keyPath: "position")
            position.values = samples.map { NSValue(point: $0.position) }
            configure(animation: position, keyTimes: keyTimes)
            node.add(position, forKey: nodeAnimationKey(AnimationKey.nodePosition, index: index))

            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = samples.map { NSNumber(value: Double($0.scale)) }
            configure(animation: scale, keyTimes: keyTimes)
            node.add(scale, forKey: nodeAnimationKey(AnimationKey.nodeScale, index: index))

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = samples.map { NSNumber(value: $0.opacity) }
            configure(animation: opacity, keyTimes: keyTimes)
            node.add(opacity, forKey: nodeAnimationKey(AnimationKey.nodeOpacity, index: index))

            let zPosition = CAKeyframeAnimation(keyPath: "zPosition")
            zPosition.values = samples.map { NSNumber(value: Double($0.zPosition)) }
            configure(animation: zPosition, keyTimes: keyTimes)
            node.add(zPosition, forKey: nodeAnimationKey(AnimationKey.nodeZPosition, index: index))
        }

        for (nodeIndex, trails) in trailLayers.enumerated() {
            for (beadIndex, trail) in trails.enumerated() {
                let samples = (0...Self.animationStepCount).map { step in
                    trailBeadState(
                        nodeIndex: nodeIndex,
                        beadIndex: beadIndex,
                        phase: currentSnapshotPhase + CGFloat(step) / CGFloat(Self.animationStepCount),
                        geometry: geometry
                    )
                }

                let position = CAKeyframeAnimation(keyPath: "position")
                position.values = samples.map { NSValue(point: $0.position) }
                configure(animation: position, keyTimes: keyTimes)
                trail.add(position, forKey: trailAnimationKey(AnimationKey.trailPosition, nodeIndex: nodeIndex, beadIndex: beadIndex))

                let scale = CAKeyframeAnimation(keyPath: "transform.scale")
                scale.values = samples.map { NSNumber(value: Double($0.scale)) }
                configure(animation: scale, keyTimes: keyTimes)
                trail.add(scale, forKey: trailAnimationKey(AnimationKey.trailScale, nodeIndex: nodeIndex, beadIndex: beadIndex))

                let opacity = CAKeyframeAnimation(keyPath: "opacity")
                opacity.values = samples.map { NSNumber(value: $0.opacity) }
                configure(animation: opacity, keyTimes: keyTimes)
                trail.add(opacity, forKey: trailAnimationKey(AnimationKey.trailOpacity, nodeIndex: nodeIndex, beadIndex: beadIndex))

                let zPosition = CAKeyframeAnimation(keyPath: "zPosition")
                zPosition.values = samples.map { NSNumber(value: Double($0.zPosition)) }
                configure(animation: zPosition, keyTimes: keyTimes)
                trail.add(zPosition, forKey: trailAnimationKey(AnimationKey.trailZPosition, nodeIndex: nodeIndex, beadIndex: beadIndex))
            }
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
            node.removeAnimation(forKey: nodeAnimationKey(AnimationKey.nodePosition, index: index))
            node.removeAnimation(forKey: nodeAnimationKey(AnimationKey.nodeScale, index: index))
            node.removeAnimation(forKey: nodeAnimationKey(AnimationKey.nodeOpacity, index: index))
            node.removeAnimation(forKey: nodeAnimationKey(AnimationKey.nodeZPosition, index: index))
        }

        for (nodeIndex, trails) in trailLayers.enumerated() {
            for (beadIndex, trail) in trails.enumerated() {
                trail.removeAnimation(forKey: trailAnimationKey(AnimationKey.trailPosition, nodeIndex: nodeIndex, beadIndex: beadIndex))
                trail.removeAnimation(forKey: trailAnimationKey(AnimationKey.trailScale, nodeIndex: nodeIndex, beadIndex: beadIndex))
                trail.removeAnimation(forKey: trailAnimationKey(AnimationKey.trailOpacity, nodeIndex: nodeIndex, beadIndex: beadIndex))
                trail.removeAnimation(forKey: trailAnimationKey(AnimationKey.trailZPosition, nodeIndex: nodeIndex, beadIndex: beadIndex))
            }
        }
    }

    private func modelPhaseForCurrentMode() -> CGFloat {
        usesReducedMotionCluster ? Self.reducedMotionPhase : currentSnapshotPhase
    }

    private func nodeAnimationKey(_ base: String, index: Int) -> String {
        "\(base).\(index)"
    }

    private func trailAnimationKey(_ base: String, nodeIndex: Int, beadIndex: Int) -> String {
        "\(base).\(nodeIndex).\(beadIndex)"
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        setReducedMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func configureAccessibility(animated: Bool, phase: CGFloat) {
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(animated ? "Agent thinking, prismatic comet" : "Agent thinking, prismatic comet snapshot")
        setAccessibilityHelp("A compact three-token comet cluster moves on a tilted diagonal plane while restrained beads show direction and depth.")
        setAccessibilityValue(Self.accessibilityValue(for: phase, reducedMotion: usesReducedMotionCluster))
    }

    private func performWithoutLayerActions(_ work: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        work()
        CATransaction.commit()
    }

    private func nodeState(index: Int, phase: CGFloat, geometry: Geometry) -> NodeState {
        if usesReducedMotionCluster {
            return Self.reducedMotionNodeState(index: index, geometry: geometry)
        }
        return Self.orbitNodeState(index: index, phase: phase, geometry: geometry)
    }

    private func trailBeadState(nodeIndex: Int, beadIndex: Int, phase: CGFloat, geometry: Geometry) -> TrailBeadState {
        if usesReducedMotionCluster {
            return Self.reducedMotionTrailBeadState(nodeIndex: nodeIndex, beadIndex: beadIndex, geometry: geometry)
        }
        return Self.orbitTrailBeadState(nodeIndex: nodeIndex, beadIndex: beadIndex, phase: phase, geometry: geometry)
    }

    private static var disabledLayerActions: [String: CAAction] {
        [
            "backgroundColor": NSNull(),
            "bounds": NSNull(),
            "fillColor": NSNull(),
            "frame": NSNull(),
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

    private static func makeTrailLayers() -> [CAShapeLayer] {
        trailDiameters.map { diameter in
            let layer = CAShapeLayer()
            let bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            layer.bounds = bounds
            layer.path = CGPath(ellipseIn: bounds, transform: nil)
            return layer
        }
    }

    private struct Geometry {
        let center: CGPoint
        let majorRadius: CGFloat
        let minorRadius: CGFloat
        let diagonal: CGVector
        let normal: CGVector
    }

    private static func geometry(in bounds: CGRect) -> Geometry {
        let side = max(1, min(bounds.width, bounds.height))
        let cosTilt = cos(tiltRadians)
        let sinTilt = sin(tiltRadians)
        return Geometry(
            center: CGPoint(x: bounds.midX, y: bounds.midY),
            majorRadius: max(2.5, side * 0.256),
            minorRadius: max(1.25, side * 0.103),
            diagonal: CGVector(dx: cosTilt, dy: sinTilt),
            normal: CGVector(dx: -sinTilt, dy: cosTilt)
        )
    }

    private static func orbitNodeState(index: Int, phase: CGFloat, geometry: Geometry) -> NodeState {
        let angle = angleForNode(index: index, phase: phase)
        let point = tiltedPoint(angle: angle, geometry: geometry)
        let depth = -sin(angle)
        let frontness = smoothstep((depth + 1) / 2)
        let rightness = smoothstep((cos(angle) + 1) / 2)
        let frontRightEmphasis = frontness * rightness
        return NodeState(
            position: point,
            scale: 0.78 + 0.35 * frontness + 0.05 * frontRightEmphasis,
            opacity: Float(min(1, 0.46 + 0.49 * frontness + 0.05 * frontRightEmphasis)),
            zPosition: 8 + 12 * frontness + 2 * frontRightEmphasis,
            accent: accents[index]
        )
    }

    private static func orbitTrailBeadState(nodeIndex: Int, beadIndex: Int, phase: CGFloat, geometry: Geometry) -> TrailBeadState {
        let trailingPhase = phase - trailPhaseOffsets[beadIndex]
        let angle = angleForNode(index: nodeIndex, phase: trailingPhase)
        let point = tiltedPoint(angle: angle, geometry: geometry)
        let depth = -sin(angle)
        let frontness = smoothstep((depth + 1) / 2)
        let baseOpacity = trailBaseOpacities[beadIndex]
        return TrailBeadState(
            nodeIndex: nodeIndex,
            beadIndex: beadIndex,
            position: point,
            diameter: trailDiameters[beadIndex],
            scale: 0.86 + 0.2 * frontness,
            opacity: Float(baseOpacity * (0.58 + 0.42 * frontness)),
            zPosition: 4 + 9 * frontness - CGFloat(beadIndex + 1) * 0.9,
            accent: accents[nodeIndex]
        )
    }

    private static func reducedMotionNodeState(index: Int, geometry: Geometry) -> NodeState {
        let diagonalOffsets: [CGFloat] = [-2.45, 0, 2.45]
        let normalOffsets: [CGFloat] = [0.25, -0.2, 0.16]
        let scales: [CGFloat] = [0.88, 1.04, 0.94]
        let opacities: [Float] = [0.76, 0.95, 0.84]
        let zPositions: [CGFloat] = [8, 12, 10]
        return NodeState(
            position: offsetPoint(
                from: geometry.center,
                diagonal: geometry.diagonal,
                normal: geometry.normal,
                diagonalOffset: diagonalOffsets[index],
                normalOffset: normalOffsets[index]
            ),
            scale: scales[index],
            opacity: opacities[index],
            zPosition: zPositions[index],
            accent: accents[index]
        )
    }

    private static func reducedMotionTrailBeadState(nodeIndex: Int, beadIndex: Int, geometry: Geometry) -> TrailBeadState {
        let node = reducedMotionNodeState(index: nodeIndex, geometry: geometry)
        let stepBack = CGFloat(beadIndex + 1) * 1.02
        let normalNudge: CGFloat = beadIndex == 0 ? 0.16 : -0.08
        return TrailBeadState(
            nodeIndex: nodeIndex,
            beadIndex: beadIndex,
            position: offsetPoint(
                from: node.position,
                diagonal: geometry.diagonal,
                normal: geometry.normal,
                diagonalOffset: -stepBack,
                normalOffset: normalNudge
            ),
            diameter: trailDiameters[beadIndex],
            scale: beadIndex == 0 ? 0.78 : 0.68,
            opacity: Float(trailBaseOpacities[beadIndex] * 0.58),
            zPosition: node.zPosition - CGFloat(beadIndex + 1),
            accent: accents[nodeIndex]
        )
    }

    private static func angleForNode(index: Int, phase: CGFloat) -> CGFloat {
        baseAngles[index] - motionPhase(phase) * 2 * .pi
    }

    private static func motionPhase(_ phase: CGFloat) -> CGFloat {
        let normalized = normalizedPhase(phase)
        let lifted = normalized + phaseLiftAmplitude * sin(normalized * 2 * .pi)
        return normalizedPhase(lifted)
    }

    private static func tiltedPoint(angle: CGFloat, geometry: Geometry) -> CGPoint {
        let localX = cos(angle) * geometry.majorRadius
        let localY = sin(angle) * geometry.minorRadius
        return offsetPoint(
            from: geometry.center,
            diagonal: geometry.diagonal,
            normal: geometry.normal,
            diagonalOffset: localX,
            normalOffset: localY
        )
    }

    private static func offsetPoint(from point: CGPoint, diagonal: CGVector, normal: CGVector, diagonalOffset: CGFloat, normalOffset: CGFloat) -> CGPoint {
        CGPoint(
            x: point.x + diagonal.dx * diagonalOffset + normal.dx * normalOffset,
            y: point.y + diagonal.dy * diagonalOffset + normal.dy * normalOffset
        )
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

    private static func accessibilityValue(for phase: CGFloat, reducedMotion: Bool) -> String {
        if reducedMotion { return "reduced motion diagonal jewel cluster" }
        let percent = Int((normalizedPhase(phase) * 100).rounded())
        return "phase \(percent) percent, tilted prismatic comet"
    }
}

@MainActor
extension PrismaticCometTiltedThinkingIndicatorView {
    var qaActiveAnimationCount: Int {
        let nodeCount = nodeLayers.enumerated().reduce(0) { count, pair in
            let (index, node) = pair
            return count
                + (node.animation(forKey: nodeAnimationKey(AnimationKey.nodePosition, index: index)) == nil ? 0 : 1)
                + (node.animation(forKey: nodeAnimationKey(AnimationKey.nodeScale, index: index)) == nil ? 0 : 1)
                + (node.animation(forKey: nodeAnimationKey(AnimationKey.nodeOpacity, index: index)) == nil ? 0 : 1)
                + (node.animation(forKey: nodeAnimationKey(AnimationKey.nodeZPosition, index: index)) == nil ? 0 : 1)
        }
        let trailCount = trailLayers.enumerated().reduce(0) { total, nodePair in
            let (nodeIndex, trails) = nodePair
            return total + trails.enumerated().reduce(0) { count, beadPair in
                let (beadIndex, trail) = beadPair
                return count
                    + (trail.animation(forKey: trailAnimationKey(AnimationKey.trailPosition, nodeIndex: nodeIndex, beadIndex: beadIndex)) == nil ? 0 : 1)
                    + (trail.animation(forKey: trailAnimationKey(AnimationKey.trailScale, nodeIndex: nodeIndex, beadIndex: beadIndex)) == nil ? 0 : 1)
                    + (trail.animation(forKey: trailAnimationKey(AnimationKey.trailOpacity, nodeIndex: nodeIndex, beadIndex: beadIndex)) == nil ? 0 : 1)
                    + (trail.animation(forKey: trailAnimationKey(AnimationKey.trailZPosition, nodeIndex: nodeIndex, beadIndex: beadIndex)) == nil ? 0 : 1)
            }
        }
        return nodeCount + trailCount
    }

    var qaSnapshotPhase: CGFloat { currentSnapshotPhase }

    var qaReducedMotionPhase: CGFloat { Self.reducedMotionPhase }

    var qaTiltDegrees: CGFloat { Self.tiltRadians * 180 / .pi }

    var qaTrailCountPerNode: Int { Self.trailPhaseOffsets.count }

    var qaTotalTrailBeadCount: Int { Self.accents.count * Self.trailPhaseOffsets.count }

    var qaNodeStates: [QANodeState] {
        qaNodeStates(at: modelPhaseForCurrentMode())
    }

    var qaTrailBeadStates: [QATrailBeadState] {
        qaTrailBeadStates(at: modelPhaseForCurrentMode())
    }

    func qaNodeStates(at phase: CGFloat) -> [QANodeState] {
        let geometry = Self.geometry(in: bounds)
        return nodeLayers.indices.map { index in
            let state = nodeState(index: index, phase: phase, geometry: geometry)
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

    func qaTrailBeadStates(at phase: CGFloat) -> [QATrailBeadState] {
        let geometry = Self.geometry(in: bounds)
        return trailLayers.indices.flatMap { nodeIndex in
            trailLayers[nodeIndex].indices.map { beadIndex in
                let state = trailBeadState(nodeIndex: nodeIndex, beadIndex: beadIndex, phase: phase, geometry: geometry)
                return QATrailBeadState(
                    nodeIndex: state.nodeIndex,
                    beadIndex: state.beadIndex,
                    position: state.position,
                    diameter: state.diameter,
                    scale: state.scale,
                    opacity: state.opacity,
                    zPosition: state.zPosition,
                    accent: state.accent
                )
            }
        }
    }

    var qaIntrinsicSide: CGFloat { Self.side }
}

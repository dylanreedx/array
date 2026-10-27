import AppKit
import ContinuumRevivedAgentUI

/// The transcript tail's working gyro as a plain CALayer, for the one-view
/// canvas transcript, which may own sublayers but no subviews.
///
/// Same motion as `DualPlaneGyroTiltedThinkingIndicatorView`: two tilted guide
/// ellipses and three nodes, positions/scale/opacity/depth from the shared
/// `DualPlaneGyroIndicatorModel`, keyframed over one 7.2 s master cycle on the
/// compositor (no timer, no display link) and placed on the shared timeline by
/// `beginTime` plus the agent's phase offset, so side-by-side tiles stagger.
/// Shape layers are vector; `matchContentsScale` keeps them sharp when the canvas
/// zoom raises the host layer's scale.
final class AgentTranscriptCanvasGyroLayer: CALayer {
    private static let sampleCount = 144
    private static let primaryGuideAlpha: CGFloat = 0.30
    private static let secondaryGuideAlpha: CGFloat = 0.22

    private let guides = [CAShapeLayer(), CAShapeLayer()]
    private let nodes = [CAShapeLayer(), CAShapeLayer(), CAShapeLayer()]
    private var theme: TokenTheme = .dark
    private var animatedBounds: CGRect = .null
    private(set) var isAnimating = false
    /// Turns (0..1) this agent sits ahead on the shared cycle.
    var phaseOffset: CGFloat = 0 {
        didSet { if isAnimating { restart() } }
    }

    override init() {
        super.init()
        masksToBounds = false
        for guide in guides {
            guide.fillColor = nil
            guide.lineWidth = 0.75
            guide.zPosition = -2
            addSublayer(guide)
        }
        nodes.forEach(addSublayer)
        actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        apply(theme: .dark)
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(theme: TokenTheme) {
        guard theme != self.theme || guides[0].strokeColor == nil else { return }
        self.theme = theme
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let guide = AgentLineRole.decorativeHairline.color.cgColor(for: theme)
        guides[0].strokeColor = guide.copy(alpha: Self.primaryGuideAlpha)
        guides[1].strokeColor = guide.copy(alpha: Self.secondaryGuideAlpha)
        for (index, node) in nodes.enumerated() {
            node.fillColor = DualPlaneGyroIndicatorModel.accentTokens[index].color.cgColor(for: theme)
        }
        CATransaction.commit()
    }

    func matchContentsScale(_ scale: CGFloat) {
        guard scale > 0, abs(contentsScale - scale) > 0.01 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentsScale = scale
        (guides + nodes).forEach { $0.contentsScale = scale }
        CATransaction.commit()
    }

    private var phaseNow: CGFloat {
        DualPlaneGyroIndicatorModel.normalizedPhase(
            CGFloat(CACurrentMediaTime() / DualPlaneGyroIndicatorModel.masterDuration) + phaseOffset)
    }

    func start() {
        guard !isAnimating || animatedBounds != bounds else { return }
        restart()
    }

    func stop() {
        guard isAnimating else { return }
        nodes.forEach { $0.removeAllAnimations() }
        isAnimating = false
        applyPose(phase: DualPlaneGyroIndicatorModel.reducedMotionPhase)
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        if isAnimating, animatedBounds != bounds { restart() }
    }

    private func applyPose(phase: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let box = CGRect(origin: .zero, size: bounds.size)
        for (guide, plane) in zip(guides, [DualPlaneGyroNodeState.Plane.primary, .secondary]) {
            guide.frame = box
            let path = CGMutablePath()
            path.addLines(between: DualPlaneGyroIndicatorModel.guidePoints(in: box, plane: plane))
            path.closeSubpath()
            guide.path = path
        }
        for (node, state) in zip(nodes, DualPlaneGyroIndicatorModel.nodeStates(in: box, phase: phase)) {
            let nodeBounds = CGRect(x: 0, y: 0, width: state.diameter, height: state.diameter)
            node.bounds = nodeBounds
            node.path = CGPath(ellipseIn: nodeBounds, transform: nil)
            node.position = state.position
            node.transform = CATransform3DMakeScale(state.scale, state.scale, 1)
            node.opacity = Float(state.opacity)
            node.zPosition = state.zPosition
        }
        CATransaction.commit()
    }

    private func restart() {
        nodes.forEach { $0.removeAllAnimations() }
        let phase = phaseNow
        applyPose(phase: phase)
        let box = CGRect(origin: .zero, size: bounds.size)
        let now = convertTime(CACurrentMediaTime(), from: nil)
        let beginTime = now - Double(phase) * DualPlaneGyroIndicatorModel.masterDuration
        let keyTimes = (0...Self.sampleCount).map { NSNumber(value: Double($0) / Double(Self.sampleCount)) }
        let samples = (0...Self.sampleCount).map {
            DualPlaneGyroIndicatorModel.nodeStates(in: box, phase: CGFloat($0) / CGFloat(Self.sampleCount))
        }
        for (index, node) in nodes.enumerated() {
            func animate(_ keyPath: String, _ values: [Any]) {
                let animation = CAKeyframeAnimation(keyPath: keyPath)
                animation.values = values
                animation.keyTimes = keyTimes
                animation.duration = DualPlaneGyroIndicatorModel.masterDuration
                animation.repeatCount = .infinity
                animation.calculationMode = .linear
                animation.isRemovedOnCompletion = false
                animation.beginTime = beginTime
                node.add(animation, forKey: keyPath)
            }
            animate("position", samples.map { NSValue(point: $0[index].position) })
            animate("transform.scale", samples.map { NSNumber(value: Double($0[index].scale)) })
            animate("opacity", samples.map { NSNumber(value: Double($0[index].opacity)) })
            animate("zPosition", samples.map { NSNumber(value: Double($0[index].zPosition)) })
        }
        animatedBounds = bounds
        isAnimating = true
    }
}

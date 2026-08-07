import AppKit
import ContinuumRevivedAgentUI
import QuartzCore

@MainActor
final class BreathingSparkIndicatorView: NSView, AgentThinkingIndicatorAnimating {
    private enum AnimationKey {
        static let path = "breathing-spark.path"
        static let scale = "breathing-spark.scale"
        static let opacity = "breathing-spark.opacity"
    }

    private struct LayerState {
        let path: CGPath
        let scale: CGFloat
        let opacity: Float
    }

    private static let motionDuration: CFTimeInterval = 2.6

    private let sparkLayer = CAShapeLayer()
    private var animationRequested = false
    private var reducedMotionEnabled = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var snapshotPhase: CGFloat = 0

    override var intrinsicContentSize: NSSize { NSSize(width: 18, height: 18) }

    override var isHidden: Bool {
        didSet { updateAnimationState() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false

        sparkLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        sparkLayer.fillRule = .nonZero
        sparkLayer.lineJoin = .round
        sparkLayer.lineCap = .round
        sparkLayer.actions = [
            "bounds": NSNull(),
            "fillColor": NSNull(),
            "frame": NSNull(),
            "lineWidth": NSNull(),
            "opacity": NSNull(),
            "path": NSNull(),
            "position": NSNull(),
            "strokeColor": NSNull(),
            "transform": NSNull(),
        ]
        layer?.addSublayer(sparkLayer)

        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Agent thinking, breathing spark")
        setAccessibilityHelp("A restrained breathing spark indicates the agent is working.")
        setAccessibilityValue(Self.accessibilityPhaseName(for: snapshotPhase))

        applyTokens()
        applyModelLayerState(for: snapshotPhase)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        performWithoutLayerActions {
            sparkLayer.frame = bounds
            sparkLayer.lineWidth = Self.strokeWidth(for: bounds)
            applyModelLayerState(for: snapshotPhase)
        }

        if animationRequested, canAnimate {
            installAnimations()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sparkLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        updateAnimationState()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateAnimationState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateAnimationState()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateAnimationState()
    }

    func startAnimating() {
        animationRequested = true
        updateAnimationState()
    }

    func stopAnimating() {
        animationRequested = false
        removeAnimations()
        snapshotPhase = 0
        applyModelLayerState(for: snapshotPhase)
    }

    func setReducedMotion(_ enabled: Bool) {
        guard reducedMotionEnabled != enabled else { return }
        reducedMotionEnabled = enabled
        updateAnimationState()
    }

    func setSnapshotPhase(_ phase: CGFloat) {
        animationRequested = false
        removeAnimations()
        snapshotPhase = Self.normalizedPhase(phase)
        applyModelLayerState(for: snapshotPhase)
    }

    private func applyTokens() {
        performWithoutLayerActions {
            sparkLayer.fillColor = AccentToken.accentWorking.color.cgColor(in: self)
            sparkLayer.strokeColor = AgentLineRole.decorativeHairline.color.cgColor(in: self)
        }
    }

    private var canAnimate: Bool {
        window != nil && !isHiddenOrHasHiddenAncestor
    }

    private func updateAnimationState() {
        removeAnimations()
        guard animationRequested, canAnimate else {
            applyModelLayerState(for: snapshotPhase)
            return
        }
        installAnimations()
    }

    private func installAnimations() {
        removeAnimations()
        guard !reducedMotionEnabled else {
            snapshotPhase = 0.25
            applyModelLayerState(for: snapshotPhase)
            return
        }
        installBreathingAnimations()
    }

    private func installBreathingAnimations() {
        snapshotPhase = 0
        applyModelLayerState(for: snapshotPhase)

        let keyPhases: [CGFloat] = [0, 0.5, 1]
        let states = keyPhases.map { Self.state(for: $0, in: sparkLayer.bounds) }
        let timing = CAMediaTimingFunction(name: .easeInEaseOut)

        let pathAnimation = CAKeyframeAnimation(keyPath: "path")
        pathAnimation.values = states.map(\.path)
        pathAnimation.keyTimes = [0, 0.5, 1]
        pathAnimation.timingFunctions = [timing, timing]
        configureRepeating(pathAnimation)
        sparkLayer.add(pathAnimation, forKey: AnimationKey.path)

        let scaleAnimation = CAKeyframeAnimation(keyPath: "transform.scale")
        scaleAnimation.values = states.map(\.scale)
        scaleAnimation.keyTimes = [0, 0.5, 1]
        scaleAnimation.timingFunctions = [timing, timing]
        configureRepeating(scaleAnimation)
        sparkLayer.add(scaleAnimation, forKey: AnimationKey.scale)

        let opacityAnimation = CAKeyframeAnimation(keyPath: "opacity")
        opacityAnimation.values = states.map(\.opacity)
        opacityAnimation.keyTimes = [0, 0.5, 1]
        opacityAnimation.timingFunctions = [timing, timing]
        configureRepeating(opacityAnimation)
        sparkLayer.add(opacityAnimation, forKey: AnimationKey.opacity)
    }

    private func configureRepeating(_ animation: CAAnimation) {
        animation.duration = Self.motionDuration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
    }

    private func removeAnimations() {
        sparkLayer.removeAnimation(forKey: AnimationKey.path)
        sparkLayer.removeAnimation(forKey: AnimationKey.scale)
        sparkLayer.removeAnimation(forKey: AnimationKey.opacity)
    }

    private func applyModelLayerState(for phase: CGFloat) {
        let state = Self.state(for: phase, in: sparkLayer.bounds)
        performWithoutLayerActions {
            sparkLayer.path = state.path
            sparkLayer.transform = CATransform3DMakeScale(state.scale, state.scale, 1)
            sparkLayer.opacity = state.opacity
        }
        setAccessibilityValue(Self.accessibilityPhaseName(for: phase))
    }

    private static func state(for phase: CGFloat, in bounds: CGRect) -> LayerState {
        let normalized = normalizedPhase(phase)
        let breath = (1 - cos(normalized * 2 * .pi)) / 2
        let axis = cos(normalized * 2 * .pi)
        let scale = 0.96 + (0.06 * breath)
        let opacity = Float(Opacity.receded + ((Opacity.full - Opacity.receded) * Double(breath)))
        return LayerState(
            path: sparkPath(in: bounds, axisEmphasis: axis),
            scale: scale,
            opacity: opacity
        )
    }

    private static func sparkPath(in bounds: CGRect, axisEmphasis: CGFloat) -> CGPath {
        let side = max(1, min(bounds.width, bounds.height))
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let insetSide = max(1, side - 2)
        let verticalRadius = insetSide * (0.32 + (0.055 * axisEmphasis))
        let horizontalRadius = insetSide * (0.27 - (0.045 * axisEmphasis))

        let top = CGPoint(x: center.x, y: center.y - verticalRadius)
        let right = CGPoint(x: center.x + horizontalRadius, y: center.y)
        let bottom = CGPoint(x: center.x, y: center.y + verticalRadius)
        let left = CGPoint(x: center.x - horizontalRadius, y: center.y)

        let path = CGMutablePath()
        path.move(to: top)
        path.addCurve(
            to: right,
            control1: CGPoint(x: center.x + horizontalRadius * 0.14, y: center.y - verticalRadius * 0.82),
            control2: CGPoint(x: center.x + horizontalRadius * 0.82, y: center.y - verticalRadius * 0.14)
        )
        path.addCurve(
            to: bottom,
            control1: CGPoint(x: center.x + horizontalRadius * 0.82, y: center.y + verticalRadius * 0.14),
            control2: CGPoint(x: center.x + horizontalRadius * 0.14, y: center.y + verticalRadius * 0.82)
        )
        path.addCurve(
            to: left,
            control1: CGPoint(x: center.x - horizontalRadius * 0.14, y: center.y + verticalRadius * 0.82),
            control2: CGPoint(x: center.x - horizontalRadius * 0.82, y: center.y + verticalRadius * 0.14)
        )
        path.addCurve(
            to: top,
            control1: CGPoint(x: center.x - horizontalRadius * 0.82, y: center.y - verticalRadius * 0.14),
            control2: CGPoint(x: center.x - horizontalRadius * 0.14, y: center.y - verticalRadius * 0.82)
        )
        path.closeSubpath()
        return path
    }

    private static func strokeWidth(for bounds: CGRect) -> CGFloat {
        max(0.65, min(bounds.width, bounds.height) * 0.045)
    }

    private static func normalizedPhase(_ phase: CGFloat) -> CGFloat {
        guard phase.isFinite else { return 0 }
        let truncated = phase.truncatingRemainder(dividingBy: 1)
        return truncated >= 0 ? truncated : truncated + 1
    }

    private static func accessibilityPhaseName(for phase: CGFloat) -> String {
        switch normalizedPhase(phase) {
        case 0..<0.25: return "vertical emphasis"
        case 0.25..<0.5: return "settling"
        case 0.5..<0.75: return "horizontal emphasis"
        default: return "settling"
        }
    }

    var qaActiveAnimationCount: Int {
        [AnimationKey.path, AnimationKey.scale, AnimationKey.opacity].filter {
            sparkLayer.animation(forKey: $0) != nil
        }.count
    }

    private func performWithoutLayerActions(_ work: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        work()
        CATransaction.commit()
    }
}

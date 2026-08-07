import ContinuumRevivedAgentUI
import QuartzCore
import SwiftUI
import UIKit

/// The selected Dual-Plane Gyro companion indicator. It is deliberately a
/// UIViewRepresentable: Core Animation owns the smooth deterministic cycle,
/// while the view gates compositor work on the foreground scene/window.
struct DualPlaneGyroIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    let isActive: Bool

    var body: some View {
        DualPlaneGyroRepresentable(
            isActive: isActive,
            reducedMotion: reduceMotion,
            colorScheme: colorScheme
        )
        .frame(
            width: DualPlaneGyroIndicatorModel.side,
            height: DualPlaneGyroIndicatorModel.side
        )
        .accessibilityHidden(!isActive)
    }
}

private struct DualPlaneGyroRepresentable: UIViewRepresentable {
    let isActive: Bool
    let reducedMotion: Bool
    let colorScheme: ColorScheme

    func makeUIView(context: Context) -> DualPlaneGyroUIView {
        DualPlaneGyroUIView(
            isActive: isActive,
            reducedMotion: reducedMotion,
            colorScheme: colorScheme
        )
    }

    func updateUIView(_ uiView: DualPlaneGyroUIView, context: Context) {
        uiView.update(
            isActive: isActive,
            reducedMotion: reducedMotion,
            colorScheme: colorScheme
        )
    }

    static func dismantleUIView(_ uiView: DualPlaneGyroUIView, coordinator: ()) {
        uiView.stopAnimating()
    }
}

@MainActor
private final class DualPlaneGyroUIView: UIView {
    private enum AnimationKey {
        static let position = "continuum.dualPlaneGyro.position"
        static let scale = "continuum.dualPlaneGyro.scale"
        static let opacity = "continuum.dualPlaneGyro.opacity"
        static let zPosition = "continuum.dualPlaneGyro.zPosition"
    }

    private let primaryGuideLayer = CAShapeLayer()
    private let secondaryGuideLayer = CAShapeLayer()
    private let nodeLayers: [CAShapeLayer]
    private var isActive: Bool
    private var reducedMotion: Bool
    private var colorScheme: ColorScheme
    private var currentSnapshotPhase: CGFloat = 0
    private var masterCycleStartTime: CFTimeInterval?
    private var compositorCycleIsRunning = false

    init(isActive: Bool, reducedMotion: Bool, colorScheme: ColorScheme) {
        self.isActive = isActive
        self.reducedMotion = reducedMotion
        self.colorScheme = colorScheme
        self.nodeLayers = DualPlaneGyroIndicatorModel.accentTokens.map { _ in CAShapeLayer() }
        super.init(frame: .zero)
        isOpaque = false
        isUserInteractionEnabled = false
        isAccessibilityElement = isActive
        accessibilityLabel = DualPlaneGyroIndicatorModel.accessibilityLabel
        configureLayerTree()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationActivityChanged),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationActivityChanged),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        updateColors()
        applyStaticState(phase: modelPhase)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateContentsScale()
        applyStaticState(phase: modelPhase)
        reconcileAnimationState()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateContentsScale()
        reconcileAnimationState()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        reconcileAnimationState()
    }

    func update(isActive: Bool, reducedMotion: Bool, colorScheme: ColorScheme) {
        let nextState = DualPlaneGyroUpdateState(
            isActive: isActive,
            reducedMotion: reducedMotion,
            theme: theme(for: colorScheme)
        )
        guard configurationState.decision(for: nextState) == .rebuild else { return }

        captureCurrentAnimationPhase()
        let colorsChanged = self.colorScheme != colorScheme
        self.isActive = isActive
        self.reducedMotion = reducedMotion
        self.colorScheme = colorScheme
        isAccessibilityElement = isActive
        accessibilityLabel = DualPlaneGyroIndicatorModel.accessibilityLabel
        if colorsChanged {
            updateColors()
        }
        removeCompositorAnimations()
        applyStaticState(phase: modelPhase)
        reconcileAnimationState()
    }

    func stopAnimating() {
        captureCurrentAnimationPhase()
        isActive = false
        isAccessibilityElement = false
        removeCompositorAnimations()
        applyStaticState(phase: currentSnapshotPhase)
    }

    private var configurationState: DualPlaneGyroUpdateState {
        DualPlaneGyroUpdateState(
            isActive: isActive,
            reducedMotion: reducedMotion,
            theme: theme(for: colorScheme)
        )
    }

    private func theme(for colorScheme: ColorScheme) -> DualPlaneGyroUpdateState.Theme {
        colorScheme == .dark ? .dark : .light
    }

    private var modelPhase: CGFloat {
        reducedMotion && isActive
            ? DualPlaneGyroIndicatorModel.reducedMotionPhase
            : currentSnapshotPhase
    }

    private var sceneIsActive: Bool {
        window?.windowScene?.activationState == .foregroundActive
    }

    private var canAnimate: Bool {
        DualPlaneGyroIndicatorModel.shouldAnimate(
            active: isActive,
            windowAttached: window != nil,
            viewVisible: !isHidden && alpha > 0 && superview != nil,
            sceneActive: sceneIsActive,
            reducedMotion: reducedMotion,
            bounds: bounds
        )
    }

    private func configureLayerTree() {
        layer.masksToBounds = false
        layer.actions = Self.disabledLayerActions

        for (index, guide) in [primaryGuideLayer, secondaryGuideLayer].enumerated() {
            guide.fillColor = nil
            guide.lineCap = .round
            guide.lineJoin = .round
            guide.actions = Self.disabledLayerActions
            guide.zPosition = -2 + CGFloat(index) * 0.1
            layer.addSublayer(guide)
        }
        for node in nodeLayers {
            node.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            node.actions = Self.disabledLayerActions
            layer.addSublayer(node)
        }
    }

    private func updateContentsScale() {
        let scale = window?.screen.scale ?? UIScreen.main.scale
        layer.contentsScale = scale
        primaryGuideLayer.contentsScale = scale
        secondaryGuideLayer.contentsScale = scale
        nodeLayers.forEach { $0.contentsScale = scale }
    }

    private func updateColors() {
        let palette = TokenPalette(colorScheme)
        performWithoutLayerActions {
            primaryGuideLayer.strokeColor = UIColor(palette.color(LineToken.separator)).cgColor.copy(alpha: 0.30)
            secondaryGuideLayer.strokeColor = UIColor(palette.color(LineToken.separator)).cgColor.copy(alpha: 0.22)
            for (index, node) in nodeLayers.enumerated() {
                node.fillColor = UIColor(palette.color(DualPlaneGyroIndicatorModel.accentTokens[index])).cgColor
            }
        }
    }

    private func applyStaticState(phase: CGFloat) {
        let states = DualPlaneGyroIndicatorModel.nodeStates(in: bounds, phase: phase)
        let guideWidth = max(0.55, min(bounds.width, bounds.height) * 0.036)
        performWithoutLayerActions {
            primaryGuideLayer.frame = bounds
            primaryGuideLayer.lineWidth = guideWidth
            primaryGuideLayer.path = guidePath(for: .primary)
            secondaryGuideLayer.frame = bounds
            secondaryGuideLayer.lineWidth = guideWidth
            secondaryGuideLayer.path = guidePath(for: .secondary)

            for (index, state) in states.enumerated() {
                let node = nodeLayers[index]
                let nodeBounds = CGRect(x: 0, y: 0, width: state.diameter, height: state.diameter)
                node.bounds = nodeBounds
                node.path = CGPath(ellipseIn: nodeBounds, transform: nil)
                node.position = state.position
                node.transform = CATransform3DMakeScale(state.scale, state.scale, 1)
                node.opacity = Float(state.opacity)
                node.zPosition = state.zPosition
            }
        }
    }

    private func guidePath(for plane: DualPlaneGyroNodeState.Plane) -> CGPath {
        let points = DualPlaneGyroIndicatorModel.guidePoints(in: bounds, plane: plane)
        let path = CGMutablePath()
        for (index, point) in points.enumerated() {
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private func reconcileAnimationState() {
        guard canAnimate else {
            captureCurrentAnimationPhase()
            removeCompositorAnimations()
            applyStaticState(phase: modelPhase)
            return
        }
        startCompositorAnimationsIfNeeded()
    }

    private func startCompositorAnimationsIfNeeded() {
        let missing = nodeLayers.enumerated().contains { index, node in
            node.animation(forKey: animationKey(AnimationKey.position, index: index)) == nil
                || node.animation(forKey: animationKey(AnimationKey.scale, index: index)) == nil
                || node.animation(forKey: animationKey(AnimationKey.opacity, index: index)) == nil
                || node.animation(forKey: animationKey(AnimationKey.zPosition, index: index)) == nil
        }
        guard missing else { return }

        let phase = currentAnimationPhase()
        removeCompositorAnimations()
        currentSnapshotPhase = phase
        applyStaticState(phase: currentSnapshotPhase)
        masterCycleStartTime = layer.convertTime(CACurrentMediaTime(), from: nil)
            - CFTimeInterval(currentSnapshotPhase) * DualPlaneGyroIndicatorModel.masterDuration
        compositorCycleIsRunning = true

        let keyTimes = (0...144).map { NSNumber(value: Double($0) / 144) }
        for (index, node) in nodeLayers.enumerated() {
            let states = (0...144).map { step in
                DualPlaneGyroIndicatorModel.nodeStates(
                    in: bounds,
                    phase: CGFloat(step) / 144
                )[index]
            }

            let position = CAKeyframeAnimation(keyPath: "position")
            position.values = states.map { NSValue(cgPoint: $0.position) }
            configure(position, keyTimes: keyTimes)
            node.add(position, forKey: animationKey(AnimationKey.position, index: index))

            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = states.map { NSNumber(value: Double($0.scale)) }
            configure(scale, keyTimes: keyTimes)
            node.add(scale, forKey: animationKey(AnimationKey.scale, index: index))

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = states.map { NSNumber(value: Double($0.opacity)) }
            configure(opacity, keyTimes: keyTimes)
            node.add(opacity, forKey: animationKey(AnimationKey.opacity, index: index))

            let zPosition = CAKeyframeAnimation(keyPath: "zPosition")
            zPosition.values = states.map { NSNumber(value: Double($0.zPosition)) }
            configure(zPosition, keyTimes: keyTimes)
            node.add(zPosition, forKey: animationKey(AnimationKey.zPosition, index: index))
        }
    }

    private func configure(_ animation: CAKeyframeAnimation, keyTimes: [NSNumber]) {
        animation.beginTime = masterCycleStartTime ?? 0
        animation.keyTimes = keyTimes
        animation.duration = DualPlaneGyroIndicatorModel.masterDuration
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
        compositorCycleIsRunning = false
        masterCycleStartTime = nil
    }

    private func currentAnimationPhase() -> CGFloat {
        guard compositorCycleIsRunning, let masterCycleStartTime else {
            return currentSnapshotPhase
        }
        let elapsed = layer.convertTime(CACurrentMediaTime(), from: nil) - masterCycleStartTime
        return DualPlaneGyroIndicatorModel.normalizedPhase(
            CGFloat(elapsed / DualPlaneGyroIndicatorModel.masterDuration)
        )
    }

    private func captureCurrentAnimationPhase() {
        guard compositorCycleIsRunning else { return }
        currentSnapshotPhase = currentAnimationPhase()
    }

    private func animationKey(_ base: String, index: Int) -> String {
        "\(base).\(index)"
    }

    @objc private func applicationActivityChanged() {
        reconcileAnimationState()
    }

    private func performWithoutLayerActions(_ work: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        work()
        CATransaction.commit()
    }

    private static var disabledLayerActions: [String: CAAction] {
        [
            "bounds": NSNull(), "fillColor": NSNull(), "frame": NSNull(),
            "lineWidth": NSNull(), "opacity": NSNull(), "path": NSNull(),
            "position": NSNull(), "strokeColor": NSNull(), "sublayers": NSNull(),
            "transform": NSNull(), "zPosition": NSNull()
        ]
    }
}

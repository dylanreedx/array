import AppKit
import ContinuumRevivedAgentUI

@MainActor
final class ThinkingWaveIndicatorView: NSView, AgentThinkingIndicatorAnimating {
    private enum Constants {
        static let intrinsicSize = CGSize(width: 18, height: 10)
        static let dotDiameter: CGFloat = 4
        static let dotGap: CGFloat = 3
        static let animationDuration: CFTimeInterval = 1.8
        static let maximumRise: CGFloat = 1.8
        static let restingOpacity: Float = 0.48
        static let peakOpacity: Float = 0.95
        static let reducedOpacity: Float = 0.68
        static let restingScale: CGFloat = 0.94
        static let peakScale: CGFloat = 1.08
        static let phaseBuckets = 6
        static let sampleCount = 36
        static let dotPhaseOffsets: [CGFloat] = [0, 0.13, 0.26]
    }

    struct CandidateBGeometryReport: Equatable {
        var scale: CGFloat
        var footprint: CGSize
        var dotFrames: [CGRect]
        var integralAtScale: Bool
        var fitsFootprint: Bool
    }

    private struct DotState: Equatable {
        var opacity: Float
        var scale: CGFloat
        var rise: CGFloat
    }

    private let dotLayers: [CALayer]
    private var animationRequested = false
    private var reducedMotionEnabled = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var lastSnapshotPhase: CGFloat = 0

    override var intrinsicContentSize: NSSize { Constants.intrinsicSize }

    override var isHidden: Bool {
        didSet { reconcileAnimationEligibility() }
    }

    override init(frame frameRect: NSRect) {
        dotLayers = (0..<3).map { _ in
            let layer = CALayer()
            layer.bounds = CGRect(origin: .zero, size: CGSize(width: Constants.dotDiameter, height: Constants.dotDiameter))
            layer.cornerRadius = Constants.dotDiameter / 2
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.opacity = Constants.restingOpacity
            return layer
        }
        super.init(frame: frameRect)
        wantsLayer = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(Self.accessibilityLabel(for: lastSnapshotPhase, reducedMotion: false))
        dotLayers.forEach { layer?.addSublayer($0) }
        applyTokens()
        applySnapshot(phase: lastSnapshotPhase, reducedMotion: reducedMotionEnabled)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        layoutDotLayers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reconcileAnimationEligibility()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        reconcileAnimationEligibility()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    private func applyTokens() {
        let fill = AccentToken.accentWorking.color.cgColor(in: self)
        dotLayers.forEach { $0.backgroundColor = fill }
    }

    func startAnimating() {
        animationRequested = true
        reconcileAnimationEligibility()
    }

    func stopAnimating() {
        animationRequested = false
        removeDotAnimations()
        applySnapshot(phase: lastSnapshotPhase, reducedMotion: reducedMotionEnabled)
    }

    func setReducedMotion(_ enabled: Bool) {
        guard reducedMotionEnabled != enabled else { return }
        reducedMotionEnabled = enabled
        removeDotAnimations()
        if enabled {
            applySnapshot(phase: lastSnapshotPhase, reducedMotion: true)
        }
        reconcileAnimationEligibility()
    }

    func setSnapshotPhase(_ phase: CGFloat) {
        lastSnapshotPhase = Self.normalizedPhase(phase)
        animationRequested = false
        removeDotAnimations()
        applySnapshot(phase: lastSnapshotPhase, reducedMotion: reducedMotionEnabled)
    }

    func candidateBGeometryReport(backingScaleFactor scale: CGFloat) -> CandidateBGeometryReport {
        layoutSubtreeIfNeeded()
        let frames = dotLayers.map(Self.untransformedFrame)
        let factor = max(scale, 1)
        let integral = frames.allSatisfy { frame in
            Self.isIntegral(frame.minX * factor)
                && Self.isIntegral(frame.minY * factor)
                && Self.isIntegral(frame.width * factor)
                && Self.isIntegral(frame.height * factor)
        }
        return CandidateBGeometryReport(
            scale: factor,
            footprint: bounds.size,
            dotFrames: frames,
            integralAtScale: integral,
            fitsFootprint: bounds.width >= 16 && bounds.width <= 20 && bounds.height <= 20
                && frames.allSatisfy { bounds.contains($0) }
        )
    }

    var qaActiveAnimationCount: Int {
        dotLayers.reduce(0) { partial, layer in partial + (layer.animationKeys()?.count ?? 0) }
    }

    var qaDotFrames: [CGRect] {
        layoutSubtreeIfNeeded()
        return dotLayers.map(Self.untransformedFrame)
    }

    var qaAccessibilityLabel: String? { accessibilityLabel() }

    private func reconcileAnimationEligibility() {
        guard animationRequested, canAnimate else {
            removeDotAnimations()
            applySnapshot(phase: lastSnapshotPhase, reducedMotion: reducedMotionEnabled)
            return
        }
        installAnimationsIfNeeded()
    }

    private var canAnimate: Bool {
        window != nil && superview != nil && !isHidden && !hasHiddenAncestorIncludingSelf && !reducedMotionEnabled
    }

    private var hasHiddenAncestorIncludingSelf: Bool {
        var view: NSView? = self
        while let current = view {
            if current.isHidden { return true }
            view = current.superview
        }
        return false
    }

    private func layoutDotLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let totalWidth = Constants.dotDiameter * 3 + Constants.dotGap * 2
        let startX = floor((bounds.width - totalWidth) / 2) + Constants.dotDiameter / 2
        let centerY = floor(bounds.midY)
        for (index, dot) in dotLayers.enumerated() {
            let x = startX + CGFloat(index) * (Constants.dotDiameter + Constants.dotGap)
            dot.bounds = CGRect(origin: .zero, size: CGSize(width: Constants.dotDiameter, height: Constants.dotDiameter))
            dot.cornerRadius = Constants.dotDiameter / 2
            dot.position = CGPoint(x: x, y: centerY)
        }
        CATransaction.commit()
    }

    private func installAnimationsIfNeeded() {
        layoutDotLayers()
        guard dotLayers.contains(where: { $0.animation(forKey: Self.animationKey) == nil }) else { return }
        applySnapshot(phase: lastSnapshotPhase, reducedMotion: false)
        let beginTime = dotLayers.first?.convertTime(CACurrentMediaTime(), from: nil) ?? CACurrentMediaTime()
        for (index, dot) in dotLayers.enumerated() {
            dot.removeAllAnimations()
            let group = Self.animationGroup(forDotAt: index)
            group.beginTime = beginTime
            dot.add(group, forKey: Self.animationKey)
        }
    }

    private func removeDotAnimations() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dotLayers.forEach { $0.removeAllAnimations() }
        CATransaction.commit()
    }

    private func applySnapshot(phase: CGFloat, reducedMotion: Bool) {
        layoutDotLayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, dot) in dotLayers.enumerated() {
            let state = Self.dotState(dotIndex: index, phase: phase, reducedMotion: reducedMotion)
            dot.opacity = state.opacity
            dot.transform = Self.transform(for: state)
        }
        CATransaction.commit()
        setAccessibilityLabel(Self.accessibilityLabel(for: phase, reducedMotion: reducedMotion))
    }

    private static let animationKey = "thinkingWaveCandidateB.animation"

    private static func untransformedFrame(for layer: CALayer) -> CGRect {
        CGRect(
            x: layer.position.x - layer.bounds.width * layer.anchorPoint.x,
            y: layer.position.y - layer.bounds.height * layer.anchorPoint.y,
            width: layer.bounds.width,
            height: layer.bounds.height
        )
    }

    private static func animationGroup(forDotAt index: Int) -> CAAnimationGroup {
        let phases = (0...Constants.sampleCount).map { CGFloat($0) / CGFloat(Constants.sampleCount) }
        let keyTimes = phases.map { NSNumber(value: Double($0)) }
        let states = phases.map { dotState(dotIndex: index, phase: $0, reducedMotion: false) }

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = states.map { NSNumber(value: $0.opacity) }
        opacity.keyTimes = keyTimes
        opacity.calculationMode = .linear

        let transform = CAKeyframeAnimation(keyPath: "transform")
        transform.values = states.map { NSValue(caTransform3D: Self.transform(for: $0)) }
        transform.keyTimes = keyTimes
        transform.calculationMode = .linear

        let group = CAAnimationGroup()
        group.animations = [opacity, transform]
        group.duration = Constants.animationDuration
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = true
        return group
    }

    private static func dotState(dotIndex: Int, phase: CGFloat, reducedMotion: Bool) -> DotState {
        guard !reducedMotion else {
            let emphasis = dotIndex == 1 ? Float(0.06) : 0
            return DotState(
                opacity: Constants.reducedOpacity + emphasis,
                scale: 1,
                rise: 0
            )
        }
        let offset = Constants.dotPhaseOffsets[min(dotIndex, Constants.dotPhaseOffsets.count - 1)]
        let localPhase = normalizedPhase(phase - offset)
        let pulse = calmPulse(localPhase)
        return DotState(
            opacity: Constants.restingOpacity + Float(pulse) * (Constants.peakOpacity - Constants.restingOpacity),
            scale: Constants.restingScale + pulse * (Constants.peakScale - Constants.restingScale),
            rise: pulse * Constants.maximumRise
        )
    }

    private static func calmPulse(_ phase: CGFloat) -> CGFloat {
        let center: CGFloat = 0.32
        let width: CGFloat = 0.26
        let distance = min(abs(phase - center), 1 - abs(phase - center))
        guard distance < width else { return 0 }
        let raw = 1 - distance / width
        return raw * raw * (3 - 2 * raw)
    }

    private static func transform(for state: DotState) -> CATransform3D {
        var transform = CATransform3DMakeScale(state.scale, state.scale, 1)
        transform.m42 = state.rise
        return transform
    }

    private static func normalizedPhase(_ phase: CGFloat) -> CGFloat {
        guard phase.isFinite else { return 0 }
        let remainder = phase.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }

    private static func accessibilityLabel(for phase: CGFloat, reducedMotion: Bool) -> String {
        let bucket = min(Constants.phaseBuckets - 1, Int((normalizedPhase(phase) * CGFloat(Constants.phaseBuckets)).rounded(.down)))
        let phaseLabel = "wave phase \(bucket + 1) of \(Constants.phaseBuckets)"
        if reducedMotion { return "Agent thinking, wave, reduced motion, \(phaseLabel)" }
        return "Agent thinking, wave, \(phaseLabel)"
    }

    private static func isIntegral(_ value: CGFloat) -> Bool {
        abs(value.rounded() - value) < 0.001
    }
}

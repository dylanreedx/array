import AppKit
import QuartzCore
import ContinuumRevivedAgentUI

/// Candidate D: a compact drawing-loop thinking indicator.
///
/// The animation is entirely Core Animation model/compositor state: a custom loop
/// path is drawn and released by coordinated `strokeStart`/`strokeEnd` keyframes,
/// with a tiny lead node following the same path. No per-frame driver or layout
/// participates.
@MainActor
final class DrawingLoopIndicatorView: NSView, AgentThinkingIndicatorAnimating {
    private enum Metrics {
        static let side: CGFloat = 18
        static let lineWidth: CGFloat = 1.75
        static let guideLineWidth: CGFloat = 1.1
        static let nodeSide: CGFloat = 3.4
        static let animationDuration: CFTimeInterval = 1.85
        static let shapeAnimationDuration: CFTimeInterval = 3.7
    }

    private let guideLayer = CAShapeLayer()
    private let drawingLayer = CAShapeLayer()
    private let leadingNodeLayer = CAShapeLayer()

    private var animationRequested = false
    private var reducedMotionEnabled = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var snapshotPhase: CGFloat = 0
    private var currentVariant: CGFloat = 0

    override var intrinsicContentSize: NSSize {
        NSSize(width: Metrics.side, height: Metrics.side)
    }

    override var isHidden: Bool {
        didSet { reconcileAnimationState() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    override func layout() {
        super.layout()
        updateGeometry(phase: snapshotPhase, animated: isActivelyAnimating)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reconcileAnimationState()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        reconcileAnimationState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyResolvedAppearance()
    }

    func startAnimating() {
        animationRequested = true
        reconcileAnimationState()
    }

    func stopAnimating() {
        animationRequested = false
        removeAnimations()
        applyStableState(phase: snapshotPhase)
    }

    func setReducedMotion(_ enabled: Bool) {
        guard reducedMotionEnabled != enabled else { return }
        reducedMotionEnabled = enabled
        reconcileAnimationState()
    }

    func setSnapshotPhase(_ phase: CGFloat) {
        animationRequested = false
        snapshotPhase = Self.normalizedPhase(phase)
        removeAnimations()
        updateGeometry(phase: snapshotPhase, animated: false)
        applySnapshotState(phase: snapshotPhase)
    }

    private var isDrawable: Bool {
        window != nil && !isHidden && !isHiddenOrHasHiddenAncestor
    }

    private var isActivelyAnimating: Bool {
        drawingLayer.animation(forKey: AnimationKey.strokeStart) != nil
    }

    private func commonInit() {
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Agent thinking, drawing loop")
        setAccessibilityValue("Phase 0 percent")

        guideLayer.fillColor = nil
        guideLayer.lineCap = .round
        guideLayer.lineJoin = .round
        guideLayer.lineWidth = Metrics.guideLineWidth
        guideLayer.opacity = 0.34

        drawingLayer.fillColor = nil
        drawingLayer.lineCap = .round
        drawingLayer.lineJoin = .round
        drawingLayer.lineWidth = Metrics.lineWidth

        leadingNodeLayer.bounds = CGRect(x: 0, y: 0, width: Metrics.nodeSide, height: Metrics.nodeSide)
        leadingNodeLayer.path = Self.nodePath(in: leadingNodeLayer.bounds).cgPath
        leadingNodeLayer.opacity = 0.95

        layer?.masksToBounds = false
        layer?.addSublayer(guideLayer)
        layer?.addSublayer(drawingLayer)
        layer?.addSublayer(leadingNodeLayer)

        applyResolvedAppearance()
        updateGeometry(phase: snapshotPhase, animated: false)
        applyStableState(phase: snapshotPhase)
    }

    private func reconcileAnimationState() {
        if reducedMotionEnabled {
            removeAnimations()
            updateGeometry(phase: 0, animated: false)
            applyReducedMotionState()
            return
        }

        guard animationRequested, isDrawable else {
            removeAnimations()
            applyStableState(phase: snapshotPhase)
            return
        }

        startCoreAnimationLoop()
    }

    private func startCoreAnimationLoop() {
        updateGeometry(phase: snapshotPhase, animated: false)
        applySnapshotState(phase: snapshotPhase)

        let strokeStart = CAKeyframeAnimation(keyPath: "strokeStart")
        strokeStart.values = [0.02, 0.08, 0.36, 0.64, 0.82]
        strokeStart.keyTimes = [0, 0.18, 0.55, 0.82, 1]
        strokeStart.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(controlPoints: 0.36, 0.0, 0.26, 1.0),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(controlPoints: 0.42, 0.0, 0.24, 1.0)
        ]
        strokeStart.duration = Metrics.animationDuration
        strokeStart.repeatCount = .infinity
        strokeStart.isRemovedOnCompletion = false

        let strokeEnd = CAKeyframeAnimation(keyPath: "strokeEnd")
        strokeEnd.values = [0.24, 0.68, 0.88, 0.92, 0.98]
        strokeEnd.keyTimes = [0, 0.28, 0.58, 0.78, 1]
        strokeEnd.timingFunctions = [
            CAMediaTimingFunction(controlPoints: 0.22, 0.0, 0.16, 1.0),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(controlPoints: 0.38, 0.0, 0.24, 1.0),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        strokeEnd.duration = Metrics.animationDuration
        strokeEnd.repeatCount = .infinity
        strokeEnd.isRemovedOnCompletion = false

        let pathMorph = CAKeyframeAnimation(keyPath: "path")
        pathMorph.values = [
            loopPath(phase: 0.00),
            loopPath(phase: 0.32),
            loopPath(phase: 0.68),
            loopPath(phase: 0.00)
        ]
        pathMorph.keyTimes = [0, 0.34, 0.72, 1]
        pathMorph.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        pathMorph.duration = Metrics.shapeAnimationDuration
        pathMorph.repeatCount = .infinity
        pathMorph.isRemovedOnCompletion = false

        let nodePosition = CAKeyframeAnimation(keyPath: "position")
        nodePosition.values = Self.nodeValues(in: drawingBounds, phaseOffset: 0.23)
        nodePosition.keyTimes = [0, 0.16, 0.35, 0.55, 0.73, 0.88, 1]
        nodePosition.timingFunctions = [
            CAMediaTimingFunction(controlPoints: 0.34, 0.0, 0.24, 1.0),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(controlPoints: 0.40, 0.0, 0.20, 1.0),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(controlPoints: 0.32, 0.0, 0.26, 1.0),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        nodePosition.duration = Metrics.animationDuration
        nodePosition.repeatCount = .infinity
        nodePosition.isRemovedOnCompletion = false

        let nodeOpacity = CAKeyframeAnimation(keyPath: "opacity")
        nodeOpacity.values = [0.72, 1.0, 0.82, 0.94, 0.74]
        nodeOpacity.keyTimes = [0, 0.24, 0.52, 0.76, 1]
        nodeOpacity.duration = Metrics.animationDuration
        nodeOpacity.repeatCount = .infinity
        nodeOpacity.isRemovedOnCompletion = false

        drawingLayer.add(strokeStart, forKey: AnimationKey.strokeStart)
        drawingLayer.add(strokeEnd, forKey: AnimationKey.strokeEnd)
        drawingLayer.add(pathMorph, forKey: AnimationKey.pathMorph)
        guideLayer.add(pathMorph.copy() as! CAAnimation, forKey: AnimationKey.pathMorph)
        leadingNodeLayer.add(nodePosition, forKey: AnimationKey.nodePosition)
        leadingNodeLayer.add(nodeOpacity, forKey: AnimationKey.nodeOpacity)
    }

    private func removeAnimations() {
        drawingLayer.removeAllAnimations()
        guideLayer.removeAllAnimations()
        leadingNodeLayer.removeAllAnimations()
    }

    private func applyReducedMotionState() {
        CATransaction.withoutActions {
            currentVariant = 0
            let path = loopPath(phase: 0)
            guideLayer.path = path
            drawingLayer.path = path
            drawingLayer.strokeStart = 0.10
            drawingLayer.strokeEnd = 0.70
            drawingLayer.opacity = 0.78
            leadingNodeLayer.opacity = 0.42
            leadingNodeLayer.position = Self.point(on: drawingBounds, at: 0.70)
            setAccessibilityValue("Reduced motion")
        }
    }

    private func applyStableState(phase: CGFloat) {
        CATransaction.withoutActions {
            let segment = Self.segment(for: phase)
            drawingLayer.strokeStart = segment.start
            drawingLayer.strokeEnd = segment.end
            drawingLayer.opacity = 0.70
            leadingNodeLayer.opacity = 0.58
            leadingNodeLayer.position = Self.point(on: drawingBounds, at: segment.end)
            updateAccessibilityPhase(phase)
        }
    }

    private func applySnapshotState(phase: CGFloat) {
        CATransaction.withoutActions {
            let segment = Self.segment(for: phase)
            drawingLayer.strokeStart = segment.start
            drawingLayer.strokeEnd = segment.end
            drawingLayer.opacity = 1.0
            leadingNodeLayer.opacity = 0.95
            leadingNodeLayer.position = Self.point(on: drawingBounds, at: segment.end)
            updateAccessibilityPhase(phase)
        }
    }

    private func updateGeometry(phase: CGFloat, animated: Bool) {
        currentVariant = reducedMotionEnabled ? 0 : phase
        let path = loopPath(phase: currentVariant)
        CATransaction.withoutActions {
            guideLayer.frame = bounds
            drawingLayer.frame = bounds
            guideLayer.path = path
            drawingLayer.path = path
            if !animated {
                let segment = reducedMotionEnabled ? (start: CGFloat(0.10), end: CGFloat(0.70)) : Self.segment(for: phase)
                leadingNodeLayer.position = Self.point(on: drawingBounds, at: segment.end)
            }
        }
    }

    private func applyResolvedAppearance() {
        CATransaction.withoutActions {
            guideLayer.strokeColor = LineToken.separator.color.cgColor(in: self)
            drawingLayer.strokeColor = AccentToken.accentWorking.color.cgColor(in: self)
            leadingNodeLayer.fillColor = AccentToken.accentWorking.color.cgColor(in: self)
        }
    }

    private var drawingBounds: CGRect {
        let size = min(bounds.width, bounds.height)
        guard size > 0 else {
            return CGRect(x: 0, y: 0, width: Metrics.side, height: Metrics.side).insetBy(dx: 2.4, dy: 2.4)
        }
        let origin = CGPoint(x: bounds.midX - size / 2, y: bounds.midY - size / 2)
        return CGRect(origin: origin, size: CGSize(width: size, height: size)).insetBy(dx: 2.4, dy: 2.4)
    }

    private func loopPath(phase: CGFloat) -> CGPath {
        Self.loopPath(in: drawingBounds, phase: phase)
    }

    private func updateAccessibilityPhase(_ phase: CGFloat) {
        let percent = Int((Self.normalizedPhase(phase) * 100).rounded())
        setAccessibilityValue("Phase \(percent) percent")
    }

    private static func normalizedPhase(_ phase: CGFloat) -> CGFloat {
        let value = phase.truncatingRemainder(dividingBy: 1)
        return value < 0 ? value + 1 : value
    }

    private static func segment(for phase: CGFloat) -> (start: CGFloat, end: CGFloat) {
        let p = normalizedPhase(phase)
        let center = 0.14 + p * 0.70
        let length = 0.22 + 0.10 * (0.5 + 0.5 * sin((p * 2 * .pi) + 0.45))
        return (max(0.02, center - length * 0.44), min(0.98, center + length * 0.56))
    }

    private static func loopPath(in rect: CGRect, phase: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let samples = 72
        for index in 0...samples {
            let t = CGFloat(index) / CGFloat(samples)
            let point = point(on: rect, at: t, variant: phase)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }

    private static func point(on rect: CGRect, at progress: CGFloat, variant: CGFloat = 0) -> CGPoint {
        let t = normalizedPhase(progress)
        let angle = (t * 2 * .pi) - (.pi / 2)
        let wobble = sin((t * 4 * .pi) + variant * 2 * .pi)
        let calmSkew = cos((t * 2 * .pi) - variant * .pi) * 0.035
        let radiusX = rect.width * (0.46 + 0.018 * wobble)
        let radiusY = rect.height * (0.40 - 0.014 * wobble)

        // Superellipse-ish loop: compact and rounded, but with a tiny asymmetry
        // so the drawn/released segment never reads as a stock circular spinner.
        let cosA = cos(angle)
        let sinA = sin(angle)
        let power: CGFloat = 0.68
        let x = copysign(pow(abs(cosA), power), cosA) * radiusX
        let y = copysign(pow(abs(sinA), power), sinA) * radiusY

        return CGPoint(
            x: rect.midX + x + rect.width * calmSkew,
            y: rect.midY + y + rect.height * 0.025 * sin(angle + variant * 2 * .pi)
        )
    }

    private static func nodePath(in rect: CGRect) -> NSBezierPath {
        let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.15, dy: 0.15))
        return path
    }

    private static func nodeValues(in rect: CGRect, phaseOffset: CGFloat) -> [NSValue] {
        [0, 0.15, 0.31, 0.50, 0.66, 0.82, 1].map { progress in
            NSValue(point: point(on: rect, at: CGFloat(progress) + phaseOffset, variant: CGFloat(progress) * 0.35))
        }
    }

    var qaActiveAnimationCount: Int {
        [
            drawingLayer.animationKeys()?.count ?? 0,
            guideLayer.animationKeys()?.count ?? 0,
            leadingNodeLayer.animationKeys()?.count ?? 0,
        ].reduce(0, +)
    }

    private enum AnimationKey {
        static let strokeStart = "drawingLoop.strokeStart"
        static let strokeEnd = "drawingLoop.strokeEnd"
        static let pathMorph = "drawingLoop.pathMorph"
        static let nodePosition = "drawingLoop.nodePosition"
        static let nodeOpacity = "drawingLoop.nodeOpacity"
    }
}

private extension CATransaction {
    static func withoutActions(_ body: () -> Void) {
        begin()
        setDisableActions(true)
        body()
        commit()
    }
}

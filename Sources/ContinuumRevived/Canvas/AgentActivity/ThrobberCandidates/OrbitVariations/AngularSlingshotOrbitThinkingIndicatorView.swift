import AppKit
import ContinuumRevivedAgentUI

/// Orbit variation 5 — Angular Slingshot.
///
/// Path geometry: three nodes share one rounded four-point kite orbit inside the
/// 18×18 footprint. The unrotated kite is top-heavy, then tilted +20° so the
/// motion keeps orbit DNA while challenging the perfect circle. Each edge is a
/// line segment followed by a quadratic corner blend (18% edge inset), so the
/// nodes never snap through vertices. Segment 2 is intentionally shorter in
/// time (18% of the loop) and uses the same smoothed local interpolation, which
/// reads as a brief diagonal slingshot without introducing timer-driven motion.
/// Live Core Animation keyframes and deterministic snapshots both call
/// `nodeState(nodeIndex:timePhase:reducedMotion:in:)`, keeping interpolation and
/// segment colour/opacity decisions on the same path.
@MainActor
final class AngularSlingshotOrbitThinkingIndicatorView: NSView, AgentThinkingIndicatorAnimating {
    private enum Metrics {
        static let side: CGFloat = 18
        static let animationDuration: CFTimeInterval = 1.46
        static let sampleCount = 96
        static let cornerFraction: CGFloat = 0.18
        static let tiltRadians: CGFloat = 20 * .pi / 180
        static let slingshotSegmentIndex = 1
        static let nodeDiameters: [CGFloat] = [3.45, 3.15, 2.85]
        static let phaseOffsets: [CGFloat] = [0, 1.0 / 3.0, 2.0 / 3.0]
        static let reducedMotionPhases: [CGFloat] = [0.08, 0.40, 0.72]
        static let segmentTimes: [CGFloat] = [0, 0.30, 0.48, 0.76, 1]
        static let segmentOpacities: [Float] = [0.98, 0.72, 0.90, 0.62]
        static let nodeOpacityBias: [Float] = [0.00, -0.08, -0.15]
    }

    private enum AnimationKey {
        static let orbit = "angularSlingshot.orbit"
    }

    struct QAOrbitNodeState: Equatable {
        let nodeIndex: Int
        let segmentIndex: Int
        let tokenName: String
        let position: CGPoint
        let diameter: CGFloat
        let opacity: Float
    }

    struct QAPathGeometryReport: Equatable {
        let footprint: CGSize
        let tiltDegrees: CGFloat
        let vertexCount: Int
        let segmentTimes: [CGFloat]
        let slingshotSegmentIndex: Int
        let slingshotDurationFraction: CGFloat
        let maximumSegmentDurationFraction: CGFloat
        let reducedMotionNodeStates: [QAOrbitNodeState]
        let sampledPathFitsFootprint: Bool
    }

    private struct NodeState {
        let position: CGPoint
        let segmentIndex: Int
        let colorToken: AccentToken
        let fillColor: CGColor
        let opacity: Float
        let scale: CGFloat
    }

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
        self.nodeLayers = Metrics.nodeDiameters.map { diameter in
            let layer = CAShapeLayer()
            let bounds = CGRect(origin: .zero, size: CGSize(width: diameter, height: diameter))
            layer.bounds = bounds
            layer.path = CGPath(ellipseIn: bounds, transform: nil)
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            return layer
        }
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: Metrics.side, height: Metrics.side)))

        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)

        configureLayerTree()
        configureAccessibility()
        applyModelState(phase: currentSnapshotPhase)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        applyModelState(phase: currentSnapshotPhase)
        if animationRequested && !reducedMotionEnabled {
            removeCompositorAnimations()
        }
        reconcileAnimationState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBackingScale()
        reconcileAnimationState()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        reconcileAnimationState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyModelState(phase: currentSnapshotPhase)
        if animationRequested && !reducedMotionEnabled {
            removeCompositorAnimations()
        }
        reconcileAnimationState()
    }

    func startAnimating() {
        animationRequested = true
        updateAccessibility(animated: !reducedMotionEnabled)
        reconcileAnimationState()
    }

    func stopAnimating() {
        animationRequested = false
        removeCompositorAnimations()
        applyModelState(phase: currentSnapshotPhase)
        updateAccessibility(animated: false)
    }

    func setReducedMotion(_ enabled: Bool) {
        guard reducedMotionEnabled != enabled else { return }
        reducedMotionEnabled = enabled
        removeCompositorAnimations()
        applyModelState(phase: currentSnapshotPhase)
        updateAccessibility(animated: animationRequested && !enabled)
        reconcileAnimationState()
    }

    /// Pins a deterministic model-layer pose for gallery snapshots and QA. This
    /// removes live CA animations; callers explicitly opt back into motion with
    /// `startAnimating()`.
    func setSnapshotPhase(_ phase: CGFloat) {
        animationRequested = false
        currentSnapshotPhase = Self.normalized(phase)
        removeCompositorAnimations()
        applyModelState(phase: currentSnapshotPhase)
        updateAccessibility(animated: false)
    }

    var qaActiveAnimationCount: Int {
        nodeLayers.reduce(0) { partial, layer in partial + (layer.animation(forKey: AnimationKey.orbit) == nil ? 0 : 1) }
    }

    var qaSnapshotPhase: CGFloat { currentSnapshotPhase }
    var qaReducedMotionEnabled: Bool { reducedMotionEnabled }
    var qaAccessibilityLabel: String? { accessibilityLabel() }

    var qaNodeStates: [QAOrbitNodeState] {
        nodeLayers.enumerated().map { index, layer in
            let state = Self.nodeState(
                nodeIndex: index,
                timePhase: currentSnapshotPhase,
                reducedMotion: reducedMotionEnabled,
                in: drawingBounds,
                colors: resolvedSegmentColors()
            )
            return QAOrbitNodeState(
                nodeIndex: index,
                segmentIndex: state.segmentIndex,
                tokenName: state.colorToken.rawValue,
                position: layer.position,
                diameter: Metrics.nodeDiameters[index],
                opacity: layer.opacity
            )
        }
    }

    var qaPathGeometryReport: QAPathGeometryReport {
        let rect = drawingBounds
        let reducedStates = (0..<nodeLayers.count).map { index in
            let state = Self.nodeState(
                nodeIndex: index,
                timePhase: currentSnapshotPhase,
                reducedMotion: true,
                in: rect,
                colors: resolvedSegmentColors()
            )
            return QAOrbitNodeState(
                nodeIndex: index,
                segmentIndex: state.segmentIndex,
                tokenName: state.colorToken.rawValue,
                position: state.position,
                diameter: Metrics.nodeDiameters[index],
                opacity: state.opacity
            )
        }
        return QAPathGeometryReport(
            footprint: CGSize(width: Metrics.side, height: Metrics.side),
            tiltDegrees: 20,
            vertexCount: Self.vertices(in: rect).count,
            segmentTimes: Metrics.segmentTimes,
            slingshotSegmentIndex: Metrics.slingshotSegmentIndex,
            slingshotDurationFraction: Metrics.segmentTimes[Metrics.slingshotSegmentIndex + 1] - Metrics.segmentTimes[Metrics.slingshotSegmentIndex],
            maximumSegmentDurationFraction: Self.maximumSegmentDuration,
            reducedMotionNodeStates: reducedStates,
            sampledPathFitsFootprint: Self.sampledPathFitsFootprint(in: rect)
        )
    }

    private var drawingBounds: CGRect {
        let side = max(1, min(bounds.width, bounds.height))
        return CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }

    private var canAnimate: Bool {
        animationRequested
            && !reducedMotionEnabled
            && window != nil
            && superview != nil
            && bounds.width > 0
            && bounds.height > 0
            && !hasHiddenAncestorIncludingSelf
    }

    private var hasHiddenAncestorIncludingSelf: Bool {
        var view: NSView? = self
        while let current = view {
            if current.isHidden { return true }
            view = current.superview
        }
        return false
    }

    private static var maximumSegmentDuration: CGFloat {
        zip(Metrics.segmentTimes.dropLast(), Metrics.segmentTimes.dropFirst())
            .map { $1 - $0 }
            .max() ?? 0
    }

    private func configureLayerTree() {
        let disabledActions = Self.disabledActions
        layer?.actions = disabledActions
        nodeLayers.forEach { node in
            node.actions = disabledActions
            node.lineWidth = 0
            node.masksToBounds = false
            layer?.addSublayer(node)
        }
        updateBackingScale()
    }

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityHelp("Three branded orbit nodes move around a rounded angular slingshot path while the agent is working.")
        updateAccessibility(animated: false)
    }

    private func updateAccessibility(animated: Bool) {
        setAccessibilityLabel(animated ? "Agent thinking, angular slingshot orbit" : "Agent thinking, angular slingshot orbit snapshot")
        if reducedMotionEnabled {
            setAccessibilityValue("Reduced motion angular constellation")
        } else {
            let percent = Int((Self.normalized(currentSnapshotPhase) * 100).rounded())
            setAccessibilityValue("Snapshot phase \(percent) percent")
        }
    }

    private func updateBackingScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        nodeLayers.forEach { $0.contentsScale = scale }
    }

    private func reconcileAnimationState() {
        guard canAnimate else {
            removeCompositorAnimations()
            applyModelState(phase: currentSnapshotPhase)
            updateAccessibility(animated: false)
            return
        }
        installCompositorAnimationsIfNeeded()
        updateAccessibility(animated: true)
    }

    private func installCompositorAnimationsIfNeeded() {
        let rect = drawingBounds
        let colors = resolvedSegmentColors()
        let beginTime = nodeLayers.first?.convertTime(CACurrentMediaTime(), from: nil) ?? CACurrentMediaTime()

        for (index, layer) in nodeLayers.enumerated() where layer.animation(forKey: AnimationKey.orbit) == nil {
            let group = Self.animationGroup(
                nodeIndex: index,
                startPhase: currentSnapshotPhase,
                in: rect,
                colors: colors
            )
            group.beginTime = beginTime
            layer.add(group, forKey: AnimationKey.orbit)
        }
    }

    private func removeCompositorAnimations() {
        nodeLayers.forEach { $0.removeAnimation(forKey: AnimationKey.orbit) }
    }

    private func applyModelState(phase: CGFloat) {
        let rect = drawingBounds
        let colors = resolvedSegmentColors()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateBackingScale()
        for (index, layer) in nodeLayers.enumerated() {
            let diameter = Metrics.nodeDiameters[index]
            let bounds = CGRect(origin: .zero, size: CGSize(width: diameter, height: diameter))
            let state = Self.nodeState(
                nodeIndex: index,
                timePhase: phase,
                reducedMotion: reducedMotionEnabled,
                in: rect,
                colors: colors
            )
            layer.bounds = bounds
            layer.path = CGPath(ellipseIn: bounds, transform: nil)
            layer.position = state.position
            layer.opacity = state.opacity
            layer.fillColor = state.fillColor
            layer.transform = CATransform3DMakeScale(state.scale, state.scale, 1)
        }
        CATransaction.commit()
    }

    private func resolvedSegmentColors() -> [AccentToken: CGColor] {
        Dictionary(uniqueKeysWithValues: AccentToken.allCases.map { token in
            (token, resolvedCGColor(for: token))
        })
    }

    private func resolvedCGColor(for token: AccentToken) -> CGColor {
        let appearance = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? TokenTheme.dark
            : TokenTheme.light
        let color = token.color.resolved(for: appearance)
        return CGColor(red: color.r, green: color.g, blue: color.b, alpha: 1)
    }

    private static func animationGroup(
        nodeIndex: Int,
        startPhase: CGFloat,
        in rect: CGRect,
        colors: [AccentToken: CGColor]
    ) -> CAAnimationGroup {
        let phases = (0...Metrics.sampleCount).map { sample in
            normalized(startPhase + CGFloat(sample) / CGFloat(Metrics.sampleCount))
        }
        let keyTimes = (0...Metrics.sampleCount).map { sample in
            NSNumber(value: Double(sample) / Double(Metrics.sampleCount))
        }
        let states = phases.map { phase in
            nodeState(nodeIndex: nodeIndex, timePhase: phase, reducedMotion: false, in: rect, colors: colors)
        }

        let position = CAKeyframeAnimation(keyPath: "position")
        position.values = states.map { NSValue(point: $0.position) }
        position.keyTimes = keyTimes
        position.calculationMode = .linear

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = states.map { NSNumber(value: $0.opacity) }
        opacity.keyTimes = keyTimes
        opacity.calculationMode = .linear

        let fillColor = CAKeyframeAnimation(keyPath: "fillColor")
        fillColor.values = states.map(\.fillColor)
        fillColor.keyTimes = keyTimes
        fillColor.calculationMode = .discrete

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = states.map { NSNumber(value: Double($0.scale)) }
        scale.keyTimes = keyTimes
        scale.calculationMode = .linear

        let group = CAAnimationGroup()
        group.animations = [position, opacity, fillColor, scale]
        group.duration = Metrics.animationDuration
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .linear)
        group.isRemovedOnCompletion = false
        return group
    }

    private static func nodeState(
        nodeIndex: Int,
        timePhase: CGFloat,
        reducedMotion: Bool,
        in rect: CGRect,
        colors: [AccentToken: CGColor]
    ) -> NodeState {
        let phase: CGFloat
        if reducedMotion {
            phase = Metrics.reducedMotionPhases[min(nodeIndex, Metrics.reducedMotionPhases.count - 1)]
        } else {
            let offset = Metrics.phaseOffsets[min(nodeIndex, Metrics.phaseOffsets.count - 1)]
            phase = normalized(timePhase + offset)
        }

        let segment = segmentAndLocalProgress(for: phase)
        let point = point(in: rect, segmentIndex: segment.index, localProgress: segment.local)
        let token = colorToken(forSegment: segment.index)
        let fill = colors[token] ?? CGColor(gray: 1, alpha: 1)
        let baseOpacity = Metrics.segmentOpacities[segment.index % Metrics.segmentOpacities.count]
        let opacity = max(0.36, min(1.0, baseOpacity + Metrics.nodeOpacityBias[min(nodeIndex, Metrics.nodeOpacityBias.count - 1)]))
        let cornerPulse = cornerEmphasis(localProgress: segment.local)
        let scale = reducedMotion ? 1 : 0.98 + cornerPulse * 0.07
        return NodeState(
            position: point,
            segmentIndex: segment.index,
            colorToken: token,
            fillColor: fill,
            opacity: opacity,
            scale: scale
        )
    }

    private static func colorToken(forSegment segmentIndex: Int) -> AccentToken {
        switch segmentIndex % 4 {
        case 0: return .accentWorking
        case 1: return .accentInput
        case 2: return .accentWorking
        default: return .accentApproval
        }
    }

    private static func segmentAndLocalProgress(for phase: CGFloat) -> (index: Int, local: CGFloat) {
        let t = normalized(phase)
        for index in 0..<(Metrics.segmentTimes.count - 1) {
            let start = Metrics.segmentTimes[index]
            let end = Metrics.segmentTimes[index + 1]
            if t >= start && t < end {
                let rawLocal = (t - start) / max(0.001, end - start)
                return (index, localEase(rawLocal, segmentIndex: index))
            }
        }
        return (Metrics.segmentTimes.count - 2, 1)
    }

    private static func localEase(_ progress: CGFloat, segmentIndex: Int) -> CGFloat {
        let clamped = min(1, max(0, progress))
        if segmentIndex == Metrics.slingshotSegmentIndex {
            // Short diagonal: still eased at both ends, but compressed into the
            // smallest time slice so the middle travel feels like a slingshot.
            return smootherStep(clamped)
        }
        return smootherStep(clamped)
    }

    private static func point(in rect: CGRect, segmentIndex: Int, localProgress: CGFloat) -> CGPoint {
        let vertices = vertices(in: rect)
        let count = vertices.count
        let index = ((segmentIndex % count) + count) % count
        let nextIndex = (index + 1) % count
        let afterNextIndex = (index + 2) % count
        let p0 = vertices[index]
        let p1 = vertices[nextIndex]
        let p2 = vertices[afterNextIndex]
        let cornerStart = lerp(p0, p1, Metrics.cornerFraction)
        let cornerEntry = lerp(p0, p1, 1 - Metrics.cornerFraction)
        let cornerExit = lerp(p1, p2, Metrics.cornerFraction)
        let linePortion: CGFloat = 0.70
        let progress = min(1, max(0, localProgress))

        if progress <= linePortion {
            return lerp(cornerStart, cornerEntry, progress / linePortion)
        }

        let cornerProgress = smootherStep((progress - linePortion) / (1 - linePortion))
        return quadratic(from: cornerEntry, control: p1, to: cornerExit, progress: cornerProgress)
    }

    private static func vertices(in rect: CGRect) -> [CGPoint] {
        let scale = min(rect.width, rect.height) / Metrics.side
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let raw = [
            CGPoint(x: 0.00, y: -5.35),
            CGPoint(x: 5.55, y: -0.60),
            CGPoint(x: 0.45, y: 5.45),
            CGPoint(x: -4.85, y: 0.70),
        ]
        return raw.map { point in
            let rotated = rotate(CGPoint(x: point.x * scale, y: point.y * scale), radians: Metrics.tiltRadians)
            return CGPoint(x: center.x + rotated.x, y: center.y + rotated.y)
        }
    }

    private static func sampledPathFitsFootprint(in rect: CGRect) -> Bool {
        let inset = Metrics.nodeDiameters.max().map { $0 / 2 } ?? 0
        let safeRect = rect.insetBy(dx: inset, dy: inset)
        for sample in 0...Metrics.sampleCount {
            let phase = CGFloat(sample) / CGFloat(Metrics.sampleCount)
            let segment = segmentAndLocalProgress(for: phase)
            if !safeRect.contains(point(in: rect, segmentIndex: segment.index, localProgress: segment.local)) {
                return false
            }
        }
        return true
    }

    private static func cornerEmphasis(localProgress: CGFloat) -> CGFloat {
        let distanceToCorner = min(abs(localProgress - 0.70), abs(localProgress - 1.0))
        let width: CGFloat = 0.20
        guard distanceToCorner < width else { return 0 }
        let raw = 1 - distanceToCorner / width
        return raw * raw * (3 - 2 * raw)
    }

    private static func rotate(_ point: CGPoint, radians: CGFloat) -> CGPoint {
        CGPoint(
            x: point.x * cos(radians) - point.y * sin(radians),
            y: point.x * sin(radians) + point.y * cos(radians)
        )
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ progress: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * progress, y: a.y + (b.y - a.y) * progress)
    }

    private static func quadratic(from start: CGPoint, control: CGPoint, to end: CGPoint, progress: CGFloat) -> CGPoint {
        let inverse = 1 - progress
        return CGPoint(
            x: inverse * inverse * start.x + 2 * inverse * progress * control.x + progress * progress * end.x,
            y: inverse * inverse * start.y + 2 * inverse * progress * control.y + progress * progress * end.y
        )
    }

    private static func smootherStep(_ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, value))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    private static func normalized(_ phase: CGFloat) -> CGFloat {
        guard phase.isFinite else { return 0 }
        let remainder = phase.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        setReducedMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private static let disabledActions: [String: CAAction] = [
        "bounds": NSNull(),
        "position": NSNull(),
        "path": NSNull(),
        "fillColor": NSNull(),
        "opacity": NSNull(),
        "transform": NSNull(),
        "contentsScale": NSNull(),
    ]
}

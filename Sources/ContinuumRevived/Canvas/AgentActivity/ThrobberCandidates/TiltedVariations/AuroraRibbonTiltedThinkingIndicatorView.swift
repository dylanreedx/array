import AppKit
import ContinuumRevivedAgentUI
import QuartzCore

/// Tilted Prism variation 3: three prismatic nodes with a restrained aurora
/// ribbon that trails the front node on the same tilted orbital ellipse.
///
/// The animation is entirely Core Animation keyframes. Snapshot and Reduced
/// Motion states use the same geometry helpers as live motion, so QA can inspect
/// deterministic model-layer positions without depending on timers or display
/// refresh.
@MainActor
final class AuroraRibbonTiltedThinkingIndicatorView: NSView, AgentThinkingIndicatorAnimating {
    struct QANodeState: Equatable {
        let index: Int
        let position: CGPoint
        let scale: CGFloat
        let opacity: Float
        let zPosition: CGFloat
        let accent: AccentToken
        let isLead: Bool
    }

    struct QARibbonState: Equatable {
        let leadIndex: Int
        let leadAccent: AccentToken
        let tiltDegrees: CGFloat
        let majorRadius: CGFloat
        let minorRadius: CGFloat
        let lineWidth: CGFloat
        let baseArcDegrees: CGFloat
        let highlightArcDegrees: CGFloat
        let baseAlpha: CGFloat
        let highlightAlpha: CGFloat
    }

    private enum AnimationKey {
        static let nodePosition = "aurora-ribbon-tilted.node.position"
        static let nodeScale = "aurora-ribbon-tilted.node.scale"
        static let nodeOpacity = "aurora-ribbon-tilted.node.opacity"
        static let nodeZPosition = "aurora-ribbon-tilted.node.zPosition"
        static let baseRibbonPath = "aurora-ribbon-tilted.ribbon.base.path"
        static let leadRibbonPath = "aurora-ribbon-tilted.ribbon.lead.path"
        static let leadRibbonColor = "aurora-ribbon-tilted.ribbon.lead.strokeColor"
        static let leadRibbonOpacity = "aurora-ribbon-tilted.ribbon.lead.opacity"
    }

    private struct Geometry {
        let center: CGPoint
        let majorRadius: CGFloat
        let minorRadius: CGFloat
        let lineWidth: CGFloat
    }

    private struct NodeState {
        let position: CGPoint
        let scale: CGFloat
        let opacity: Float
        let zPosition: CGFloat
        let accent: AccentToken
        let angle: CGFloat
        let frontness: CGFloat
    }

    private struct RibbonState {
        let basePath: CGPath
        let highlightPath: CGPath
        let leadIndex: Int
        let leadAccent: AccentToken
        let highlightOpacity: Float
    }

    private static let side: CGFloat = 18
    private static let nodeDiameter: CGFloat = 3.35
    private static let duration: CFTimeInterval = 1.7
    private static let animationStepCount = 72
    private static let tiltDegrees: CGFloat = 30
    private static let tiltRadians: CGFloat = tiltDegrees * .pi / 180
    private static let reducedMotionPhase: CGFloat = 0.12
    private static let ribbonSegmentCount = 18
    private static let baseRibbonArcRadians: CGFloat = 0.46 * .pi
    private static let highlightRibbonArcRadians: CGFloat = 0.20 * .pi
    private static let baseRibbonAlpha: CGFloat = CGFloat(Opacity.receded) * 0.18
    private static let highlightRibbonAlpha: CGFloat = CGFloat(Opacity.full) * 0.30
    private static let baseAngles: [CGFloat] = [
        -.pi / 2,
        -.pi / 2 - (2 * .pi / 3),
        -.pi / 2 - (4 * .pi / 3),
    ]
    private static let accents: [AccentToken] = [
        .accentWorking,
        .accentInput,
        .accentDone,
    ]

    private let baseRibbonLayer = CAShapeLayer()
    private let leadRibbonLayer = CAShapeLayer()
    private let nodeLayers: [CAShapeLayer]
    private var animationRequested = false
    private var reducedMotionEnabled: Bool
    private var currentSnapshotPhase: CGFloat = 0

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    override var isHidden: Bool {
        didSet { reconcileAnimationState() }
    }

    init(reducedMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        self.reducedMotionEnabled = reducedMotion
        self.nodeLayers = Self.accents.map { _ in Self.makeNodeLayer() }
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: Self.side, height: Self.side)))
        configureView()
    }

    override init(frame frameRect: NSRect) {
        self.reducedMotionEnabled = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        self.nodeLayers = Self.accents.map { _ in Self.makeNodeLayer() }
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
        if animationRequested, !reducedMotionEnabled, canAnimate {
            removeAnimations()
            startAnimationsIfNeeded()
        }
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

    /// Pins a deterministic model-layer pose for review. The ribbon and node
    /// geometry come from the same functions that feed the live CA keyframes.
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

        [baseRibbonLayer, leadRibbonLayer].forEach { ribbon in
            ribbon.fillColor = nil
            ribbon.lineCap = .round
            ribbon.lineJoin = .round
            ribbon.actions = disabledActions
            layer?.addSublayer(ribbon)
        }

        nodeLayers.forEach { node in
            node.actions = disabledActions
            layer?.addSublayer(node)
        }
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        baseRibbonLayer.contentsScale = scale
        leadRibbonLayer.contentsScale = scale
        nodeLayers.forEach { $0.contentsScale = scale }
    }

    private func applyTokenColors() {
        let baseRibbonColor = AgentLineRole.decorativeHairline.color.cgColor(in: self)
        performWithoutLayerActions {
            baseRibbonLayer.strokeColor = baseRibbonColor.copy(alpha: Self.baseRibbonAlpha) ?? baseRibbonColor
            let geometry = Self.geometry(in: bounds, contentsScale: layer?.contentsScale ?? 2)
            let ribbon = Self.ribbonState(phase: modelPhaseForCurrentMode(), geometry: geometry)
            let leadColor = ribbon.leadAccent.color.cgColor(in: self)
            leadRibbonLayer.strokeColor = leadColor.copy(alpha: Self.highlightRibbonAlpha) ?? leadColor

            for (index, node) in nodeLayers.enumerated() {
                node.fillColor = Self.accents[index].color.cgColor(in: self)
            }
        }
    }

    private func applyModelState(phase: CGFloat) {
        let geometry = Self.geometry(in: bounds, contentsScale: layer?.contentsScale ?? 2)
        let ribbon = Self.ribbonState(phase: phase, geometry: geometry)
        performWithoutLayerActions {
            baseRibbonLayer.frame = bounds
            baseRibbonLayer.path = ribbon.basePath
            baseRibbonLayer.lineWidth = geometry.lineWidth
            baseRibbonLayer.opacity = 1

            leadRibbonLayer.frame = bounds
            leadRibbonLayer.path = ribbon.highlightPath
            leadRibbonLayer.lineWidth = geometry.lineWidth
            leadRibbonLayer.opacity = ribbon.highlightOpacity
            let leadColor = ribbon.leadAccent.color.cgColor(in: self)
            leadRibbonLayer.strokeColor = leadColor.copy(alpha: Self.highlightRibbonAlpha) ?? leadColor

            for (index, node) in nodeLayers.enumerated() {
                let state = Self.nodeState(index: index, phase: phase, geometry: geometry)
                let nodeBounds = CGRect(x: 0, y: 0, width: Self.nodeDiameter, height: Self.nodeDiameter)
                node.bounds = nodeBounds
                node.path = CGPath(ellipseIn: nodeBounds, transform: nil)
                node.position = state.position
                node.transform = CATransform3DMakeScale(state.scale, state.scale, 1)
                node.opacity = state.opacity
                node.zPosition = state.zPosition
            }
        }
        setAccessibilityValue(Self.accessibilityValue(for: phase, leadIndex: ribbon.leadIndex))
    }

    private func reconcileAnimationState() {
        guard animationRequested else {
            removeAnimations()
            return
        }

        guard !reducedMotionEnabled, canAnimate else {
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
        let needsNodeAnimations = nodeLayers.enumerated().contains { index, node in
            node.animation(forKey: animationKey(AnimationKey.nodePosition, index: index)) == nil ||
            node.animation(forKey: animationKey(AnimationKey.nodeScale, index: index)) == nil ||
            node.animation(forKey: animationKey(AnimationKey.nodeOpacity, index: index)) == nil ||
            node.animation(forKey: animationKey(AnimationKey.nodeZPosition, index: index)) == nil
        }
        let needsRibbonAnimations = baseRibbonLayer.animation(forKey: AnimationKey.baseRibbonPath) == nil ||
            leadRibbonLayer.animation(forKey: AnimationKey.leadRibbonPath) == nil ||
            leadRibbonLayer.animation(forKey: AnimationKey.leadRibbonColor) == nil ||
            leadRibbonLayer.animation(forKey: AnimationKey.leadRibbonOpacity) == nil
        guard needsNodeAnimations || needsRibbonAnimations else { return }

        removeAnimations()
        applyModelState(phase: currentSnapshotPhase)

        let geometry = Self.geometry(in: bounds, contentsScale: layer?.contentsScale ?? 2)
        let keyTimes = (0...Self.animationStepCount).map { NSNumber(value: Double($0) / Double(Self.animationStepCount)) }
        let phases = (0...Self.animationStepCount).map { currentSnapshotPhase + CGFloat($0) / CGFloat(Self.animationStepCount) }

        let ribbonSamples = phases.map { Self.ribbonState(phase: $0, geometry: geometry) }
        let basePath = CAKeyframeAnimation(keyPath: "path")
        basePath.values = ribbonSamples.map(\.basePath)
        configure(animation: basePath, keyTimes: keyTimes)
        baseRibbonLayer.add(basePath, forKey: AnimationKey.baseRibbonPath)

        let leadPath = CAKeyframeAnimation(keyPath: "path")
        leadPath.values = ribbonSamples.map(\.highlightPath)
        configure(animation: leadPath, keyTimes: keyTimes)
        leadRibbonLayer.add(leadPath, forKey: AnimationKey.leadRibbonPath)

        let leadColor = CAKeyframeAnimation(keyPath: "strokeColor")
        leadColor.values = ribbonSamples.map { sample -> CGColor in
            let color = sample.leadAccent.color.cgColor(in: self)
            return color.copy(alpha: Self.highlightRibbonAlpha) ?? color
        }
        configure(animation: leadColor, keyTimes: keyTimes)
        leadRibbonLayer.add(leadColor, forKey: AnimationKey.leadRibbonColor)

        let leadOpacity = CAKeyframeAnimation(keyPath: "opacity")
        leadOpacity.values = ribbonSamples.map { NSNumber(value: $0.highlightOpacity) }
        configure(animation: leadOpacity, keyTimes: keyTimes)
        leadRibbonLayer.add(leadOpacity, forKey: AnimationKey.leadRibbonOpacity)

        for (index, node) in nodeLayers.enumerated() {
            let samples = phases.map { Self.nodeState(index: index, phase: $0, geometry: geometry) }

            let position = CAKeyframeAnimation(keyPath: "position")
            position.values = samples.map { NSValue(point: $0.position) }
            configure(animation: position, keyTimes: keyTimes)
            node.add(position, forKey: animationKey(AnimationKey.nodePosition, index: index))

            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = samples.map { NSNumber(value: Double($0.scale)) }
            configure(animation: scale, keyTimes: keyTimes)
            node.add(scale, forKey: animationKey(AnimationKey.nodeScale, index: index))

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = samples.map { NSNumber(value: $0.opacity) }
            configure(animation: opacity, keyTimes: keyTimes)
            node.add(opacity, forKey: animationKey(AnimationKey.nodeOpacity, index: index))

            let zPosition = CAKeyframeAnimation(keyPath: "zPosition")
            zPosition.values = samples.map { NSNumber(value: Double($0.zPosition)) }
            configure(animation: zPosition, keyTimes: keyTimes)
            node.add(zPosition, forKey: animationKey(AnimationKey.nodeZPosition, index: index))
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
        baseRibbonLayer.removeAnimation(forKey: AnimationKey.baseRibbonPath)
        leadRibbonLayer.removeAnimation(forKey: AnimationKey.leadRibbonPath)
        leadRibbonLayer.removeAnimation(forKey: AnimationKey.leadRibbonColor)
        leadRibbonLayer.removeAnimation(forKey: AnimationKey.leadRibbonOpacity)
        for (index, node) in nodeLayers.enumerated() {
            node.removeAnimation(forKey: animationKey(AnimationKey.nodePosition, index: index))
            node.removeAnimation(forKey: animationKey(AnimationKey.nodeScale, index: index))
            node.removeAnimation(forKey: animationKey(AnimationKey.nodeOpacity, index: index))
            node.removeAnimation(forKey: animationKey(AnimationKey.nodeZPosition, index: index))
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
        setAccessibilityLabel(animated ? "Agent thinking, aurora ribbon tilted orbit" : "Agent thinking, aurora ribbon tilted orbit snapshot")
        setAccessibilityHelp("Three accented nodes move on a tilted ellipse while a fine partial ribbon trails the lead node.")
        let geometry = Self.geometry(in: bounds, contentsScale: layer?.contentsScale ?? 2)
        let leadIndex = Self.leadNodeIndex(phase: phase, geometry: geometry)
        setAccessibilityValue(Self.accessibilityValue(for: phase, leadIndex: leadIndex))
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

    private static func makeNodeLayer() -> CAShapeLayer {
        let layer = CAShapeLayer()
        let bounds = CGRect(x: 0, y: 0, width: nodeDiameter, height: nodeDiameter)
        layer.bounds = bounds
        layer.path = CGPath(ellipseIn: bounds, transform: nil)
        return layer
    }

    private static func geometry(in bounds: CGRect, contentsScale: CGFloat) -> Geometry {
        let side = max(1, min(bounds.width, bounds.height))
        return Geometry(
            center: CGPoint(x: bounds.midX, y: bounds.midY),
            majorRadius: max(2.75, side * 0.31),
            minorRadius: max(1.4, side * 0.13),
            lineWidth: pixelRounded(max(0.5, side * 0.032), scale: contentsScale)
        )
    }

    private static func nodeState(index: Int, phase: CGFloat, geometry: Geometry) -> NodeState {
        let angle = baseAngles[index] - normalizedPhase(phase) * 2 * .pi
        let frontness = frontness(for: angle)
        return NodeState(
            position: tiltedPoint(angle: angle, geometry: geometry),
            scale: 0.78 + 0.32 * frontness,
            opacity: Float(0.76 + 0.22 * frontness),
            zPosition: 8 * frontness,
            accent: accents[index],
            angle: angle,
            frontness: frontness
        )
    }

    private static func ribbonState(phase: CGFloat, geometry: Geometry) -> RibbonState {
        let leadIndex = leadNodeIndex(phase: phase, geometry: geometry)
        let lead = nodeState(index: leadIndex, phase: phase, geometry: geometry)
        let baseStart = lead.angle - baseRibbonArcRadians * 0.86
        let baseEnd = lead.angle + baseRibbonArcRadians * 0.14
        let highlightStart = lead.angle - highlightRibbonArcRadians * 0.58
        let highlightEnd = lead.angle + highlightRibbonArcRadians * 0.42
        return RibbonState(
            basePath: arcPath(from: baseStart, to: baseEnd, geometry: geometry),
            highlightPath: arcPath(from: highlightStart, to: highlightEnd, geometry: geometry),
            leadIndex: leadIndex,
            leadAccent: lead.accent,
            highlightOpacity: Float(0.82 + 0.12 * lead.frontness)
        )
    }

    private static func leadNodeIndex(phase: CGFloat, geometry: Geometry) -> Int {
        var leadIndex = 0
        var leadFrontness = nodeState(index: 0, phase: phase, geometry: geometry).frontness
        for index in 1..<accents.count {
            let frontness = nodeState(index: index, phase: phase, geometry: geometry).frontness
            if frontness > leadFrontness {
                leadIndex = index
                leadFrontness = frontness
            }
        }
        return leadIndex
    }

    private static func arcPath(from startAngle: CGFloat, to endAngle: CGFloat, geometry: Geometry) -> CGPath {
        let path = CGMutablePath()
        for step in 0...ribbonSegmentCount {
            let progress = CGFloat(step) / CGFloat(ribbonSegmentCount)
            let angle = startAngle + (endAngle - startAngle) * progress
            let point = tiltedPoint(angle: angle, geometry: geometry)
            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }

    private static func tiltedPoint(angle: CGFloat, geometry: Geometry) -> CGPoint {
        let localX = cos(angle) * geometry.majorRadius
        let localY = sin(angle) * geometry.minorRadius
        let cosTilt = cos(tiltRadians)
        let sinTilt = sin(tiltRadians)
        return CGPoint(
            x: geometry.center.x + localX * cosTilt - localY * sinTilt,
            y: geometry.center.y + localX * sinTilt + localY * cosTilt
        )
    }

    private static func frontness(for angle: CGFloat) -> CGFloat {
        smoothstep((-sin(angle) + 1) / 2)
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

    private static func pixelRounded(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale.isFinite, scale > 0 else { return value }
        return max(0.5, (value * scale).rounded(.down) / scale)
    }

    private static func accessibilityValue(for phase: CGFloat, leadIndex: Int) -> String {
        let percent = Int((normalizedPhase(phase) * 100).rounded())
        return "phase \(percent) percent, node \(leadIndex + 1) leads the partial aurora ribbon"
    }
}

@MainActor
extension AuroraRibbonTiltedThinkingIndicatorView {
    var qaActiveAnimationCount: Int {
        let nodeAnimationCount = nodeLayers.enumerated().reduce(0) { count, pair in
            let (index, node) = pair
            return count
                + (node.animation(forKey: animationKey(AnimationKey.nodePosition, index: index)) == nil ? 0 : 1)
                + (node.animation(forKey: animationKey(AnimationKey.nodeScale, index: index)) == nil ? 0 : 1)
                + (node.animation(forKey: animationKey(AnimationKey.nodeOpacity, index: index)) == nil ? 0 : 1)
                + (node.animation(forKey: animationKey(AnimationKey.nodeZPosition, index: index)) == nil ? 0 : 1)
        }
        return nodeAnimationCount
            + (baseRibbonLayer.animation(forKey: AnimationKey.baseRibbonPath) == nil ? 0 : 1)
            + (leadRibbonLayer.animation(forKey: AnimationKey.leadRibbonPath) == nil ? 0 : 1)
            + (leadRibbonLayer.animation(forKey: AnimationKey.leadRibbonColor) == nil ? 0 : 1)
            + (leadRibbonLayer.animation(forKey: AnimationKey.leadRibbonOpacity) == nil ? 0 : 1)
    }

    var qaSnapshotPhase: CGFloat { currentSnapshotPhase }

    var qaReducedMotionPhase: CGFloat { Self.reducedMotionPhase }

    var qaIntrinsicSide: CGFloat { Self.side }

    var qaNodeStates: [QANodeState] {
        let geometry = Self.geometry(in: bounds, contentsScale: layer?.contentsScale ?? 2)
        let phase = modelPhaseForCurrentMode()
        let leadIndex = Self.leadNodeIndex(phase: phase, geometry: geometry)
        return nodeLayers.indices.map { index in
            let state = Self.nodeState(index: index, phase: phase, geometry: geometry)
            return QANodeState(
                index: index,
                position: state.position,
                scale: state.scale,
                opacity: state.opacity,
                zPosition: state.zPosition,
                accent: state.accent,
                isLead: index == leadIndex
            )
        }
    }

    var qaRibbonState: QARibbonState {
        let geometry = Self.geometry(in: bounds, contentsScale: layer?.contentsScale ?? 2)
        let phase = modelPhaseForCurrentMode()
        let ribbon = Self.ribbonState(phase: phase, geometry: geometry)
        return QARibbonState(
            leadIndex: ribbon.leadIndex,
            leadAccent: ribbon.leadAccent,
            tiltDegrees: Self.tiltDegrees,
            majorRadius: geometry.majorRadius,
            minorRadius: geometry.minorRadius,
            lineWidth: geometry.lineWidth,
            baseArcDegrees: Self.baseRibbonArcRadians * 180 / .pi,
            highlightArcDegrees: Self.highlightRibbonArcRadians * 180 / .pi,
            baseAlpha: Self.baseRibbonAlpha,
            highlightAlpha: Self.highlightRibbonAlpha
        )
    }
}

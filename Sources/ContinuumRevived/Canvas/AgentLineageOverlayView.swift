import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// Screen-space, ephemeral direct parent→child relationships. The entire fan is
/// one compound path and therefore one Core Animation loop regardless of child
/// count. Identity remains in `AgentRecord.parentAgentID`; this view stores only
/// current presentation.
@MainActor
final class AgentLineageOverlayView: NSView {
    static let lineWidth: CGFloat = 1.25
    static let dashPattern: [NSNumber] = [6, 4]
    private static let animationKey = "agentLineageMarchingAnts"

    private let dashShape = CAShapeLayer()
    private let arrowShape = CAShapeLayer()
    private(set) var routes: [DocumentRelationshipOverlayView.Route] = []
    private(set) var marchingSuspended = false
    private(set) var reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        for shape in [dashShape, arrowShape] {
            shape.fillColor = NSColor.clear.cgColor
            shape.lineCap = .round
            shape.lineJoin = .round
            layer?.addSublayer(shape)
        }
        dashShape.lineWidth = Self.lineWidth
        dashShape.lineDashPattern = Self.dashPattern
        arrowShape.lineWidth = Self.lineWidth
        isHidden = true
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [dashShape, arrowShape] { shape.frame = bounds }
        CATransaction.commit()
        updateContentsScale()
    }

    func show(segments: [DocumentRelationshipOverlayView.Segment]) {
        let nextRoutes = segments.compactMap(DocumentRelationshipOverlayView.route(for:))
        guard !nextRoutes.isEmpty else {
            hide()
            return
        }
        routes = nextRoutes

        let routePath = CGMutablePath()
        let arrowPath = CGMutablePath()
        for route in nextRoutes {
            routePath.addPath(route.path.cgPath)
            appendArrow(for: route, to: arrowPath)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dashShape.path = routePath
        arrowShape.path = arrowPath
        CATransaction.commit()

        let visible = routePath.boundingBoxOfPath.union(arrowPath.boundingBoxOfPath).intersects(bounds)
        isHidden = !visible
        if visible {
            attachAnimationIfNeeded()
        } else {
            dashShape.removeAnimation(forKey: Self.animationKey)
        }
    }

    func hide() {
        routes = []
        isHidden = true
        dashShape.removeAnimation(forKey: Self.animationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dashShape.path = nil
        arrowShape.path = nil
        CATransaction.commit()
    }

    func setMarchingSuspended(_ suspended: Bool) {
        guard suspended != marchingSuspended else { return }
        marchingSuspended = suspended
        if suspended { freezeDash() } else { attachAnimationIfNeeded() }
    }

    private func refreshReduceMotion() {
        let next = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard next != reducesMotion else { return }
        reducesMotion = next
        if next { freezeDash() } else { attachAnimationIfNeeded() }
    }

    @objc private func accessibilityDisplayOptionsDidChange(_ notification: Notification) {
        refreshReduceMotion()
    }

    private func attachAnimationIfNeeded() {
        guard !isHidden, !marchingSuspended, !reducesMotion,
              dashShape.animation(forKey: Self.animationKey) == nil else { return }
        let phase = Self.dashPattern.reduce(0) { $0 + $1.doubleValue }
        let animation = CABasicAnimation(keyPath: "lineDashPhase")
        animation.fromValue = 0
        animation.toValue = phase
        animation.duration = FocusBorderConfig.defaultSpeed
        animation.repeatCount = .infinity
        dashShape.add(animation, forKey: Self.animationKey)
    }

    private func freezeDash() {
        dashShape.removeAnimation(forKey: Self.animationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dashShape.lineDashPhase = 0
        CATransaction.commit()
    }

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // This overlay already has z-priority over tiles. A five-point canvas
        // halo therefore added no legibility benefit and read as a harsh black
        // outline in the dark theme. Let the lighter accent stroke stand alone.
        let accent = NSColor.controlAccentColor.withAlphaComponent(0.62).appResolvedCGColor
        dashShape.strokeColor = accent
        arrowShape.strokeColor = accent
        CATransaction.commit()
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for shape in [dashShape, arrowShape] { shape.contentsScale = scale }
    }

    private func appendArrow(
        for route: DocumentRelationshipOverlayView.Route,
        to path: CGMutablePath
    ) {
        let end: CGPoint
        let tangentOrigin: CGPoint
        switch route {
        case let .cubic(_, _, control2, routeEnd):
            end = routeEnd
            tangentOrigin = control2
        case let .polyline(points):
            guard points.count >= 2, let routeEnd = points.last else { return }
            end = routeEnd
            tangentOrigin = points[points.count - 2]
        }
        guard end != tangentOrigin else { return }
        let angle = atan2(end.y - tangentOrigin.y, end.x - tangentOrigin.x)
        let length: CGFloat = 7
        for offset in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
            path.move(to: end)
            path.addLine(to: CGPoint(
                x: end.x + cos(angle + offset) * length,
                y: end.y + sin(angle + offset) * length
            ))
        }
    }

    var endpoints: [(start: CGPoint, end: CGPoint)] {
        routes.compactMap { route in
            switch route {
            case let .cubic(start, _, _, end): return (start, end)
            case let .polyline(points):
                guard let start = points.first, let end = points.last else { return nil }
                return (start, end)
            }
        }
    }

    var qaIsAnimating: Bool {
        !isHidden && dashShape.animation(forKey: Self.animationKey) != nil
    }

    var qaAnimationCount: Int {
        [dashShape, arrowShape].reduce(0) { $0 + ($1.animationKeys()?.count ?? 0) }
    }
}

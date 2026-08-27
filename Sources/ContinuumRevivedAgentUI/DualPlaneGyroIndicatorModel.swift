import CoreGraphics
import Foundation

/// The provider-neutral geometry and lifecycle contract for the selected iOS
/// companion indicator. The desktop view and iOS view intentionally keep their
/// platform painting separate; this small model keeps the measured 18×18
/// geometry, semantic accents, and deterministic motion contract identical.
public struct DualPlaneGyroNodeState: Equatable, Sendable {
    public enum Plane: String, Sendable {
        case primary
        case secondary
    }

    public let index: Int
    public let plane: Plane
    public let token: AccentToken
    public let position: CGPoint
    public let diameter: CGFloat
    public let scale: CGFloat
    public let opacity: CGFloat
    public let zPosition: CGFloat
    public let centerClearance: CGFloat

    public init(
        index: Int,
        plane: Plane,
        token: AccentToken,
        position: CGPoint,
        diameter: CGFloat,
        scale: CGFloat,
        opacity: CGFloat,
        zPosition: CGFloat,
        centerClearance: CGFloat
    ) {
        self.index = index
        self.plane = plane
        self.token = token
        self.position = position
        self.diameter = diameter
        self.scale = scale
        self.opacity = opacity
        self.zPosition = zPosition
        self.centerClearance = centerClearance
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.index == rhs.index && lhs.plane == rhs.plane && lhs.token.rawValue == rhs.token.rawValue
            && lhs.position.x == rhs.position.x && lhs.position.y == rhs.position.y
            && lhs.diameter == rhs.diameter && lhs.scale == rhs.scale
            && lhs.opacity == rhs.opacity && lhs.zPosition == rhs.zPosition
            && lhs.centerClearance == rhs.centerClearance
    }
}

public struct DualPlaneGyroUpdateState: Equatable, Sendable {
    public enum Theme: String, Sendable {
        case light
        case dark
    }

    public enum Decision: Equatable, Sendable {
        case preserveMasterCycle
        case rebuild
    }

    public let isActive: Bool
    public let reducedMotion: Bool
    public let theme: Theme

    public init(isActive: Bool, reducedMotion: Bool, theme: Theme) {
        self.isActive = isActive
        self.reducedMotion = reducedMotion
        self.theme = theme
    }

    /// SwiftUI may call UIViewRepresentable.updateUIView for unrelated model
    /// changes. Only the indicator's own inputs are allowed to rebuild its CA
    /// state; unchanged inputs preserve the current master cycle.
    public func decision(for next: Self) -> Decision {
        self == next ? .preserveMasterCycle : .rebuild
    }
}

public enum DualPlaneGyroIndicatorModel {
    public static let side: CGFloat = 18
    public static let masterDuration: TimeInterval = 7.20
    public static let primaryTurnsPerMaster: CGFloat = -3
    public static let secondaryTurnsPerMaster: CGFloat = 2
    public static let primaryOrbitPeriod: TimeInterval = masterDuration / 3
    public static let secondaryOrbitPeriod: TimeInterval = masterDuration / 2
    public static let primaryTiltDegrees: CGFloat = 28
    public static let secondaryTiltDegrees: CGFloat = -28
    public static let reducedMotionPhase: CGFloat = 0.185
    public static let accessibilityLabel = "Agent thinking"
    public static let guideSampleCount = 96
    public static let centerClearanceSampleCount = 96

    public static let accentTokens: [AccentToken] = [
        .accentWorking,
        .accentInput,
        .accentApproval
    ]

    private static let primaryTiltRadians = primaryTiltDegrees * .pi / 180
    private static let secondaryTiltRadians = secondaryTiltDegrees * .pi / 180
    private static let majorRadiusScale: CGFloat = 0.296
    private static let minorRadiusScale: CGFloat = 0.166

    private struct NodeSpec {
        let plane: DualPlaneGyroNodeState.Plane
        let baseAngle: CGFloat
        let turnsPerMaster: CGFloat
        let diameter: CGFloat
        let token: AccentToken
        let opacityBias: CGFloat
        let scaleBias: CGFloat
    }

    private static let nodeSpecs: [NodeSpec] = [
        NodeSpec(plane: .primary, baseAngle: -.pi / 2, turnsPerMaster: primaryTurnsPerMaster,
                 diameter: 3.20, token: .accentWorking, opacityBias: 0, scaleBias: 0.02),
        NodeSpec(plane: .primary, baseAngle: .pi / 2, turnsPerMaster: primaryTurnsPerMaster,
                 diameter: 2.88, token: .accentInput, opacityBias: -0.05, scaleBias: -0.02),
        NodeSpec(plane: .secondary, baseAngle: .pi * 0.08, turnsPerMaster: secondaryTurnsPerMaster,
                 diameter: 2.64, token: .accentApproval, opacityBias: -0.03, scaleBias: -0.01)
    ]

    /// Activity is derived only from the synced status, never from summaries or
    /// event prose. Configuring and working are the two in-flight states.
    public static func isActive(status: AgentStatus) -> Bool {
        status == .configuring || status == .working
    }

    /// A pure lifecycle gate used by the UIView and its deterministic checks.
    /// No display link, timer, or per-frame work is needed to answer this.
    public static func shouldAnimate(
        active: Bool,
        windowAttached: Bool,
        viewVisible: Bool,
        sceneActive: Bool,
        reducedMotion: Bool,
        bounds: CGRect
    ) -> Bool {
        active && windowAttached && viewVisible && sceneActive && !reducedMotion
            && bounds.size.width > 0 && bounds.size.height > 0
    }

    public static func normalizedPhase(_ phase: CGFloat) -> CGFloat {
        guard phase.isFinite else { return 0 }
        let remainder = phase.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }

    public static func nodeStates(in bounds: CGRect, phase: CGFloat) -> [DualPlaneGyroNodeState] {
        let geometry = Geometry(bounds: bounds)
        return nodeSpecs.enumerated().map { index, spec in
            let angle = spec.baseAngle + normalizedPhase(phase) * 2 * .pi * spec.turnsPerMaster
            let position = projectedPoint(angle: angle, plane: spec.plane, geometry: geometry)
            let depthSign: CGFloat = spec.plane == .primary ? -1 : 1
            let frontness = smoothstep((depthSign * sin(angle) + 1) / 2)
            let scale = clamp(0.84 + 0.28 * frontness + spec.scaleBias, lower: 0.78, upper: 1.15)
            let opacity = clamp(0.48 + 0.44 * frontness + spec.opacityBias, lower: 0.44, upper: 0.95)
            let radius = spec.diameter * scale / 2
            return DualPlaneGyroNodeState(
                index: index,
                plane: spec.plane,
                token: spec.token,
                position: position,
                diameter: spec.diameter,
                scale: scale,
                opacity: opacity,
                zPosition: -5 + 12 * frontness,
                centerClearance: hypot(position.x - geometry.center.x, position.y - geometry.center.y) - radius
            )
        }
    }

    public static func guidePoints(in bounds: CGRect, plane: DualPlaneGyroNodeState.Plane) -> [CGPoint] {
        let geometry = Geometry(bounds: bounds)
        return (0...guideSampleCount).map { step in
            let angle = CGFloat(step) / CGFloat(guideSampleCount) * 2 * .pi
            return projectedPoint(angle: angle, plane: plane, geometry: geometry)
        }
    }

    public static func sampledPathFitsFootprint(in bounds: CGRect) -> Bool {
        let geometry = Geometry(bounds: bounds)
        for step in 0...centerClearanceSampleCount {
            let phase = CGFloat(step) / CGFloat(centerClearanceSampleCount)
            for state in nodeStates(in: bounds, phase: phase) {
                let radius = state.diameter * state.scale / 2
                if state.position.x - radius < geometry.drawingBounds.origin.x
                    || state.position.x + radius > geometry.drawingBounds.origin.x + geometry.drawingBounds.size.width
                    || state.position.y - radius < geometry.drawingBounds.origin.y
                    || state.position.y + radius > geometry.drawingBounds.origin.y + geometry.drawingBounds.size.height {
                    return false
                }
            }
        }
        return true
    }

    public static func minimumCenterClearance(in bounds: CGRect) -> CGFloat {
        (0...centerClearanceSampleCount)
            .flatMap { step in nodeStates(in: bounds, phase: CGFloat(step) / CGFloat(centerClearanceSampleCount)) }
            .map(\.centerClearance)
            .min() ?? 0
    }

    private struct Geometry {
        let drawingBounds: CGRect
        let center: CGPoint
        let majorRadius: CGFloat
        let minorRadius: CGFloat

        init(bounds: CGRect) {
            let side = max(1, min(bounds.size.width, bounds.size.height))
            drawingBounds = CGRect(
                x: bounds.origin.x + bounds.size.width / 2 - side / 2,
                y: bounds.origin.y + bounds.size.height / 2 - side / 2,
                width: side,
                height: side
            )
            center = CGPoint(
                x: drawingBounds.origin.x + drawingBounds.size.width / 2,
                y: drawingBounds.origin.y + drawingBounds.size.height / 2
            )
            majorRadius = max(3.7, side * majorRadiusScale)
            minorRadius = max(2.3, side * minorRadiusScale)
        }
    }

    private static func projectedPoint(
        angle: CGFloat,
        plane: DualPlaneGyroNodeState.Plane,
        geometry: Geometry
    ) -> CGPoint {
        let localX = cos(angle) * geometry.majorRadius
        let localY = sin(angle) * geometry.minorRadius
        let tilt = plane == .primary ? primaryTiltRadians : secondaryTiltRadians
        return CGPoint(
            x: geometry.center.x + localX * cos(tilt) - localY * sin(tilt),
            y: geometry.center.y + localX * sin(tilt) + localY * cos(tilt)
        )
    }

    private static func smoothstep(_ value: CGFloat) -> CGFloat {
        let clamped = clamp(value, lower: 0, upper: 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(upper, max(lower, value))
    }
}

/// Stable, non-animated poses for WidgetKit, ActivityKit, snapshots, and other
/// system-owned surfaces. Those surfaces are refreshed on a budget and must not
/// imply that an in-process spinner is continuously running.
public enum DualPlaneGyroPresentationPhase: String, Codable, CaseIterable, Hashable, Sendable {
    case idle
    case working
    case needsAttention
    case failed
    case completed
    case stale

    public var modelPhase: CGFloat {
        switch self {
        case .idle: return 0.08
        case .working: return 0.31
        case .needsAttention: return 0.55
        case .failed: return 0.72
        case .completed: return 0.90
        case .stale: return DualPlaneGyroIndicatorModel.reducedMotionPhase
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .idle: return "Array idle"
        case .working: return "Agent working"
        case .needsAttention: return "Agent needs attention"
        case .failed: return "Agent failed"
        case .completed: return "Agent completed"
        case .stale: return "Array status stale"
        }
    }

    public static func resolve(status: AgentStatus, failed: Bool = false) -> Self {
        if failed { return .failed }
        switch status {
        case .configuring, .working: return .working
        case .needsAttention: return .needsAttention
        case .done: return .completed
        case .stale: return .stale
        case .idle: return .idle
        }
    }
}

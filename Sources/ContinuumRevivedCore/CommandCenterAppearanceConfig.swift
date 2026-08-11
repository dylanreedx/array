import Foundation

public enum CommandCenterGlassiness: String, CaseIterable, Sendable {
    case solid = "Solid"
    case frosted = "Frosted"
    case glass = "Glass"
    case custom = "Custom"
}

public struct ResolvedCommandCenterAppearance: Equatable, Sendable {
    public let glassiness: CommandCenterGlassiness
    public let backgroundOpacity: Double
    public let usesBlur: Bool
    public let accessibilityForcedSolid: Bool
}

public enum CommandCenterAppearanceConfig {
    public static let glassinessKey = "continuum.commandCenter.glassiness"
    public static let customOpacityKey = "continuum.commandCenter.backgroundOpacity"
    public static let options = CommandCenterGlassiness.allCases.map(\.rawValue)
    public static let defaultGlassiness = CommandCenterGlassiness.frosted
    public static let defaultCustomOpacity = 0.84
    public static let customOpacityRange = 0.68 ... 0.96

    public static func resolve(
        glassinessRaw: String?,
        customOpacityRaw: String?,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> ResolvedCommandCenterAppearance {
        let requested = glassinessRaw.flatMap(CommandCenterGlassiness.init(rawValue:)) ?? defaultGlassiness
        if reduceTransparency {
            return ResolvedCommandCenterAppearance(glassiness: .solid, backgroundOpacity: 1, usesBlur: false, accessibilityForcedSolid: true)
        }
        let base: Double
        switch requested {
        case .solid: base = 1
        case .frosted: base = 0.84
        case .glass: base = 0.72
        case .custom:
            base = min(customOpacityRange.upperBound, max(customOpacityRange.lowerBound, Double(customOpacityRaw ?? "") ?? defaultCustomOpacity))
        }
        return ResolvedCommandCenterAppearance(
            glassiness: requested,
            backgroundOpacity: increaseContrast ? max(base, 0.92) : base,
            usesBlur: requested != .solid,
            accessibilityForcedSolid: false
        )
    }
}

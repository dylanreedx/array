import Foundation

public enum CanvasAutoLayoutActivation: String, Codable, Equatable, Sendable, CaseIterable {
    case immediately = "Immediately"
    case onFirstEdit = "On First Edit"
}

/// Which way a zone grows when auto layout places a new tile (.plans/107).
/// `fan` lets the zone's shape decide: the side that keeps it closest to the
/// screen's proportions wins.
public enum CanvasGrowthDirection: String, Codable, Equatable, Sendable, CaseIterable {
    case fan = "Fan Out"
    case right = "Right"
    case down = "Down"
}

public enum CanvasAutoLayoutConfig {
    public static let enabledKey = "continuum.canvas.autoLayout.enabled"
    public static let activationKey = "continuum.canvas.autoLayout.activation"
    public static let defaultEnabled = true
    public static let defaultActivation: CanvasAutoLayoutActivation = .immediately

    public static func enabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: enabledKey) != nil else { return defaultEnabled }
        return defaults.bool(forKey: enabledKey)
    }

    public static let growthKey = "continuum.canvas.autoLayout.growth"
    public static let defaultGrowth: CanvasGrowthDirection = .fan

    public static func growth(defaults: UserDefaults = .standard) -> CanvasGrowthDirection {
        defaults.string(forKey: growthKey).flatMap(CanvasGrowthDirection.init(rawValue:)) ?? defaultGrowth
    }

    public static func activation(defaults: UserDefaults = .standard) -> CanvasAutoLayoutActivation {
        defaults.string(forKey: activationKey).flatMap(CanvasAutoLayoutActivation.init(rawValue:)) ?? defaultActivation
    }
}

import Foundation

public enum CanvasAutoLayoutActivation: String, Codable, Equatable, Sendable, CaseIterable {
    case immediately = "Immediately"
    case onFirstEdit = "On First Edit"
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

    public static func activation(defaults: UserDefaults = .standard) -> CanvasAutoLayoutActivation {
        defaults.string(forKey: activationKey).flatMap(CanvasAutoLayoutActivation.init(rawValue:)) ?? defaultActivation
    }
}

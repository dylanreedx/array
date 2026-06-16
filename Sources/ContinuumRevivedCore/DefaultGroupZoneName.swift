import Foundation

/// Resolves the default name used when creating a group zone from the palette.
/// Persisted via UserDefaults so users can override the product default:
///
///     defaults write com.continuum.revived continuum.zone.defaultGroupName "My Zone"
///
public enum DefaultGroupZoneName: Sendable {
    public static let userDefaultsKey = "continuum.zone.defaultGroupName"
    public static let fallback = "Zone"

    public static func resolve(defaults: UserDefaults = .standard) -> String {
        if let raw = defaults.string(forKey: userDefaultsKey), !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return raw
        }
        return fallback
    }
}

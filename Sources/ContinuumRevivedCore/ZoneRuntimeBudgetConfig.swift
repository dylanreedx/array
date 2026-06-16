import Foundation

/// Whether the zone runtime registry closes a project's controller the moment its
/// last workspace reference is released (docs/23 S2). Default `true` (bound resources;
/// matches today's single-controller close-on-switch). Set `false` to keep a released
/// controller warm (faster re-acquire; more resident PTYs/WebViews).
public enum ZoneRuntimeBudgetConfig {
    public static let closeOnZeroKey = "continuum.zoneRuntime.closeOnZero"
    public static let defaultCloseOnZero = true

    public static func closeOnZero(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: closeOnZeroKey) != nil
            ? defaults.bool(forKey: closeOnZeroKey)
            : defaultCloseOnZero
    }
}

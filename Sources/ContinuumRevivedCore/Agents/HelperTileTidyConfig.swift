import Foundation

/// Settings › Agents › "Tidy finished helper tiles". On by default: Array
/// closes a delegated helper's tile, as if the person had closed it, once its
/// work is done and its result has reached the agent that asked for it.
public enum HelperTileTidyConfig {
    public static let enabledKey = "agents.tidyFinishedHelperTiles.enabled"
    public static let enabledDefault = true

    public static func enabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? enabledDefault
    }
}

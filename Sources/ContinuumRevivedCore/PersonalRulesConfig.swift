import Foundation

/// Settings ▸ Agents ▸ Personal rules. Default off. Array only reads the file
/// the user names; it never creates, edits or copies it.
public enum PersonalRulesConfig {
    public static let enabledKey = "agents.personalRules.enabled"
    public static let pathKey = "agents.personalRules.path"

    /// The file to read at the next Codex or Pi launch, or nil when off.
    public static func selectedPath(defaults: UserDefaults) -> String? {
        guard defaults.object(forKey: enabledKey) as? Bool == true,
              let path = defaults.string(forKey: pathKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return (path as NSString).expandingTildeInPath
    }
}

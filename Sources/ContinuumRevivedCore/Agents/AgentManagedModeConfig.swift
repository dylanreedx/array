import Foundation

/// App-wide policy. The record persists the next-turn target; a running turn
/// keeps its captured mode until it finishes. Helpers and Pi always remain free.
public enum AgentManagedModeConfig {
    public static let enabledKey = "agents.managedMode.enabled"
    public static let showIndicatorKey = "agents.managedMode.showIndicator"
    public static func enabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }
    public static func showIndicator(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showIndicatorKey) as? Bool ?? true
    }
    public static func mode(harness: AgentHarness?, parent: AgentID?, enabled: Bool) -> AgentMode {
        enabled && parent == nil && (harness == .claudeCode || harness == .codex) ? .managed : .free
    }
}

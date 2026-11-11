import Foundation

/// App-wide policy. The record persists the next-turn target; a running turn
/// keeps its captured mode until it finishes. Helpers and Pi always remain free.
public enum AgentManagedModeConfig {
    public static let enabledKey = "agents.managedMode.enabled"
    public static let showIndicatorKey = "agents.managedMode.showIndicator"
    /// Off: a lead hears after ten minutes without progress, as before. On: by
    /// what the helper is doing (`HelperLiveness`): three minutes for a stall,
    /// thirty for waiting on a process or tool call, never for waiting on its
    /// own helper, ten otherwise.
    public static let stallAlertsKey = "agents.managedMode.stallAlerts"
    public static func stallAlerts(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: stallAlertsKey) as? Bool ?? false
    }
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

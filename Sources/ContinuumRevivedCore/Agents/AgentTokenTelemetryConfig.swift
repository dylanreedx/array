import Foundation

/// The owner's consent to local token telemetry (`.plans/116` part 14): on by
/// default, kept on this Mac only, never uploaded. Off stops new records from
/// that moment and deletes nothing.
public enum AgentTokenTelemetryConfig {
    public static let enabledKey = "agents.tokenTelemetry.enabled"
    public static let defaultEnabled = true
    public static func enabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }
}

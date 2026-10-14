import Foundation

/// Shared user threshold across the three provider-native compaction commands.
public enum AgentContextAutoCompactionPolicy {
    public static let enabledKey = "continuum.agentContext.autoCompact"
    public static let percentKey = "continuum.agentContext.autoCompactPercent"
    public static func threshold(defaults: UserDefaults = .standard) -> Double? {
        if defaults.object(forKey: enabledKey) != nil, !defaults.bool(forKey: enabledKey) { return nil }
        let percent = defaults.object(forKey: percentKey) == nil ? 90 : defaults.double(forKey: percentKey)
        guard percent.isFinite, percent >= 50, percent <= 99 else { return 0.90 }
        return percent / 100
    }
}

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

    /// A turn at 450k tokens costs about six times a turn at 50-100k, so on a
    /// large window the percentage alone (90% of 1M) lets a conversation grow
    /// far past the point where carrying it is worth it. The absolute cap
    /// compacts at the next turn boundary; the percentage still wins on small
    /// windows and when the user sets it lower.
    public static let tokenCap = 300_000

    public static func shouldCompact(used: Int, max window: Int, threshold: Double) -> Bool {
        guard window > 0 else { return false }
        return Double(used) / Double(window) >= threshold || used >= tokenCap
    }
}

import Foundation

public enum IdleReaperConfig {
    public static let inactivityThresholdKey = "continuum.idleReaper.inactivityThresholdSeconds"
    public static let sweepIntervalKey = "continuum.idleReaper.sweepIntervalSeconds"

    public static let defaultInactivityThreshold: TimeInterval = 30 * 60
    public static let defaultSweepInterval: TimeInterval = 5 * 60
    public static let minSweepInterval: TimeInterval = 10

    public static func resolveInactivityThreshold(defaults: UserDefaults = .standard) -> TimeInterval {
        guard defaults.object(forKey: inactivityThresholdKey) != nil else {
            return defaultInactivityThreshold
        }
        return max(0, defaults.double(forKey: inactivityThresholdKey))
    }

    public static func resolveSweepInterval(defaults: UserDefaults = .standard) -> TimeInterval {
        guard defaults.object(forKey: sweepIntervalKey) != nil else {
            return defaultSweepInterval
        }
        return max(minSweepInterval, defaults.double(forKey: sweepIntervalKey))
    }
}

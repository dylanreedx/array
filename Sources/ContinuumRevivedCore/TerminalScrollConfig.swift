import Foundation

public enum TerminalScrollConfig {
    public static let preciseMultiplierKey = "continuum.terminal.scroll.preciseMultiplier"
    public static let lineMultiplierKey = "continuum.terminal.scroll.lineMultiplier"
    public static let maxAbsDeltaPerEventKey = "continuum.terminal.scroll.maxAbsDeltaPerEvent"

    public static let preciseMultiplierDefault = 1.0
    public static let lineMultiplierDefault = 1.0
    public static let maxAbsDeltaPerEventDefault: Double? = nil

    public static func settings(defaults: UserDefaults = .standard) -> TerminalWheelSettings {
        TerminalWheelSettings(
            preciseMultiplier: multiplier(forKey: preciseMultiplierKey, defaults: defaults, fallback: preciseMultiplierDefault),
            lineMultiplier: multiplier(forKey: lineMultiplierKey, defaults: defaults, fallback: lineMultiplierDefault),
            maxAbsDeltaPerEvent: optionalClamp(forKey: maxAbsDeltaPerEventKey, defaults: defaults)
        )
    }

    private static func multiplier(forKey key: String, defaults: UserDefaults, fallback: Double) -> Double {
        guard let value = doubleValue(forKey: key, defaults: defaults), value.isFinite else { return fallback }
        return min(max(value, 0.1), 2.0)
    }

    private static func optionalClamp(forKey key: String, defaults: UserDefaults) -> Double? {
        guard let value = doubleValue(forKey: key, defaults: defaults), value.isFinite, value > 0 else { return maxAbsDeltaPerEventDefault }
        return min(max(value, 1), 500)
    }

    private static func doubleValue(forKey key: String, defaults: UserDefaults) -> Double? {
        if let string = defaults.string(forKey: key) {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let object = defaults.object(forKey: key)
        if let number = object as? NSNumber { return number.doubleValue }
        if let value = object as? Double { return value }
        return nil
    }
}

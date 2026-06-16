import Foundation

/// Resolves the autosave debounce interval from UserDefaults.
/// Mirrors `ZoneHydrationReconcileConfig` / `DragMagnetizeConfig`.
public enum AutosaveConfig {
    public static let debounceMsKey = "continuum.autosave.debounceMs"
    public static let defaultDebounceMs = 200
    public static let minDebounceMs = 0
    public static let maxDebounceMs = 5000

    /// Clamped to [min,max]; non-numeric/absent → default.
    public static func debounceMs(defaults: UserDefaults = .standard) -> Int {
        guard let raw = defaults.object(forKey: debounceMsKey) else { return defaultDebounceMs }
        let value: Int?
        if let i = raw as? Int { value = i }
        else if let s = raw as? String, let i = Int(s) { value = i }
        else { value = nil }
        guard let v = value else { return defaultDebounceMs }
        return max(minDebounceMs, min(maxDebounceMs, v))
    }

    /// Convenience: seconds for `Timer.scheduledTimer(withTimeInterval:)`.
    public static func debounceInterval(defaults: UserDefaults = .standard) -> TimeInterval {
        return TimeInterval(debounceMs(defaults: defaults)) / 1000.0
    }
}

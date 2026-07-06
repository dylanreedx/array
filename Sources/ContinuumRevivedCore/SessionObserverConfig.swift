import Foundation

/// The three configurable knobs `SessionObserver` (docs/38-tickets/40-session-observer.md)
/// reads at construction — never hardcoded literals (Dylan doctrine, ruling C-20260706-031
/// item 6). Mirrors `ZoneHydrationReconcileConfig`'s resolve shape: read as a string from
/// `UserDefaults` (so the generic Settings `.text` field can bind it), clamp to a sane
/// range, fall back to the default for absent/non-numeric/out-of-range values.
public enum SessionObserverConfig {
    public static let debounceMsKey = "continuum.sessionObserver.debounceMs"
    public static let defaultDebounceMs = 250
    public static let minDebounceMs = 50
    public static let maxDebounceMs = 5000

    public static let maxChangesPerMinuteKey = "continuum.sessionObserver.maxChangesPerMinute"
    public static let defaultMaxChangesPerMinute = 10
    public static let minMaxChangesPerMinute = 1
    public static let maxMaxChangesPerMinute = 120

    public static let detectionPollSecondsKey = "continuum.sessionObserver.detectionPollSeconds"
    public static let defaultDetectionPollSeconds = 5
    public static let minDetectionPollSeconds = 1
    public static let maxDetectionPollSeconds = 60

    public static func debounceMs(defaults: UserDefaults = .standard) -> Int {
        resolve(key: debounceMsKey, default: defaultDebounceMs, min: minDebounceMs, max: maxDebounceMs, defaults: defaults)
    }

    public static func maxChangesPerMinute(defaults: UserDefaults = .standard) -> Int {
        resolve(key: maxChangesPerMinuteKey, default: defaultMaxChangesPerMinute, min: minMaxChangesPerMinute, max: maxMaxChangesPerMinute, defaults: defaults)
    }

    public static func detectionPollSeconds(defaults: UserDefaults = .standard) -> Int {
        resolve(key: detectionPollSecondsKey, default: defaultDetectionPollSeconds, min: minDetectionPollSeconds, max: maxDetectionPollSeconds, defaults: defaults)
    }

    private static func resolve(key: String, default defaultValue: Int, min: Int, max: Int, defaults: UserDefaults) -> Int {
        guard let raw = defaults.object(forKey: key) else { return defaultValue }
        let value: Int?
        if let i = raw as? Int { value = i }
        else if let s = raw as? String, let i = Int(s) { value = i }
        else { value = nil }
        guard let v = value, v >= min, v <= max else { return defaultValue }
        return v
    }
}

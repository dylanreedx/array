import Foundation

/// Debounce interval (ms) between a viewport change settling and the
/// WorkspaceRuntime re-planning + applying zone hydration tiers. Coalesces a
/// flick/pinch burst into one reconcile. Mirrors TileGapResolver's resolve shape.
public enum ZoneHydrationReconcileConfig {
    public static let intervalKey = "continuum.zoneHydration.reconcileDebounceMs"
    public static let defaultIntervalMs = 200
    public static let minIntervalMs = 0
    public static let maxIntervalMs = 2000

    /// Reads the interval in ms; clamps to [min,max]; falls back to the default
    /// for absent/non-numeric/out-of-range values.
    public static func intervalMs(defaults: UserDefaults = .standard) -> Int {
        guard let raw = defaults.object(forKey: intervalKey) else { return defaultIntervalMs }
        let value: Int?
        if let i = raw as? Int { value = i }
        else if let s = raw as? String, let i = Int(s) { value = i }
        else { value = nil }
        guard let v = value, v >= minIntervalMs, v <= maxIntervalMs else { return defaultIntervalMs }
        return v
    }
}

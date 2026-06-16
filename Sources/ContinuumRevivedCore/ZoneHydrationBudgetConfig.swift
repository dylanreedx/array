import Foundation

/// Resolves the max number of zones that may be `.live` simultaneously, from
/// UserDefaults. Mirrors `TileGapResolver` / `DragMagnetizeConfig`. This is the
/// ZONE-count budget the pure `ZoneHydrationOrchestrator` enforces — distinct from the
/// tile-level `BrowserRuntimeBudget` (WKWebView LRU, T07).
public enum ZoneHydrationBudgetConfig {
    public static let maxLiveZonesKey = "continuum.zoneHydration.maxLiveZones"
    public static let defaultMaxLiveZones = 4

    public static func maxLiveZones(defaults: UserDefaults = .standard) -> Int {
        if let value = defaults.object(forKey: maxLiveZonesKey) as? Int, value > 0 {
            return value
        }
        if let s = defaults.string(forKey: maxLiveZonesKey), let value = Int(s), value > 0 {
            return value
        }
        return defaultMaxLiveZones
    }
}

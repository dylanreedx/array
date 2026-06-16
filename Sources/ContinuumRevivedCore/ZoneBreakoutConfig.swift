import Foundation

/// Resolves the zone break-out threshold from UserDefaults. When a member tile is
/// dragged so its center sits more than this many WORLD units beyond its zone's
/// frame, the tile detaches from the zone (becomes a bare/unzoned tile). Below the
/// threshold the tile stays in the zone (a small overshoot doesn't eject it).
/// Dropping a bare tile so its center lands inside a zone adopts it immediately
/// (no threshold — that's a deliberate drop-in).
public enum ZoneBreakoutConfig {
    public static let distanceKey = "continuum.zoneBreakout.distance"
    public static let defaultDistance: Double = 48

    public static func distance(defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: distanceKey) != nil else { return defaultDistance }
        let v = defaults.double(forKey: distanceKey)
        return v > 0 ? v : defaultDistance
    }
}

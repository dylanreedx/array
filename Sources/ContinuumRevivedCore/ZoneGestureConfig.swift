import Foundation

/// Resolves on-canvas zone-gesture thresholds from UserDefaults. The only tunable
/// this task owns: how far (in SCREEN points) an empty-canvas drag must travel
/// before it commits a NEW group zone (below this it is a plain background click /
/// deselect, never an accidental zone). The live gesture converts to world via
/// `/ viewport.zoom` so the catch feels constant at any zoom — same convention as
/// `DragMagnetizeConfig.snapThresholdScreenPoints`.
public enum ZoneGestureConfig {
    public static let minCreateDragScreenPointsKey = "continuum.zoneGesture.minCreateDragScreenPoints"
    public static let defaultMinCreateDragScreenPoints: Double = 24

    public static func minCreateDragScreenPoints(defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: minCreateDragScreenPointsKey) != nil else {
            return defaultMinCreateDragScreenPoints
        }
        let v = defaults.double(forKey: minCreateDragScreenPointsKey)
        return v > 0 ? v : defaultMinCreateDragScreenPoints
    }
}

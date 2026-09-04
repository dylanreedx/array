import Foundation

/// Resolves whether dragging a tile magnetizes (snaps) to nearby tile edges, from
/// UserDefaults. Mirrors `TileGapResolver` / `FocusBorderConfig`. On by default —
/// drag magnetization is the primary snap (docs/30). No modifier needed: while a
/// drag is in range a translucent ghost previews the destination and releasing
/// commits to it; toggle the whole behavior off in Settings.
public enum DragMagnetizeConfig {
    public static let enabledKey = "continuum.dragMagnetize.enabled"
    public static let defaultEnabled = true

    /// Snap pull radius in SCREEN points; the live drag converts to world via
    /// `/ viewport.zoom` so the catch distance feels constant at any zoom. Wide
    /// enough that the phantom catches from a comfortable distance.
    public static let snapThresholdScreenPoints: Double = 44
    public static let snapReleaseScreenPoints: Double = 64

    public static func enabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) != nil
            ? defaults.bool(forKey: enabledKey)
            : defaultEnabled
    }
}

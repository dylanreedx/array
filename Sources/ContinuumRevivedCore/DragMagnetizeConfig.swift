import Foundation

/// Resolves whether dragging a tile magnetizes (snaps) to nearby tile edges, from
/// UserDefaults. Mirrors `TileGapResolver` / `FocusBorderConfig`. On by default —
/// drag magnetization is the primary snap (docs/30). Hold `⌘` during a drag to
/// bypass it for that drag.
public enum DragMagnetizeConfig {
    public static let enabledKey = "continuum.dragMagnetize.enabled"
    public static let defaultEnabled = true

    /// Snap pull radius in SCREEN points; the live drag converts to world via
    /// `/ viewport.zoom` so the pull feels constant at any zoom.
    public static let snapThresholdScreenPoints: Double = 10

    public static func enabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) != nil
            ? defaults.bool(forKey: enabledKey)
            : defaultEnabled
    }
}

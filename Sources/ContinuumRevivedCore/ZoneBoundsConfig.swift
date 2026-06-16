import CoreGraphics
import Foundation

/// Resolves zone-chrome sizing parameters (padding around member tiles, minimum
/// size for an empty zone) from UserDefaults. Mirrors `DragMagnetizeConfig` /
/// `TileGapResolver`: absent OR non-finite OR out-of-range values fall back to
/// the declared defaults. AppKit-free.
public enum ZoneBoundsConfig {
    public static let paddingKey = "continuum.zoneBounds.padding"
    public static let defaultPadding: Double = 24

    public static let emptyMinWidthKey = "continuum.zoneBounds.emptyMinWidth"
    public static let defaultEmptyMinWidth: Double = 480
    public static let emptyMinHeightKey = "continuum.zoneBounds.emptyMinHeight"
    public static let defaultEmptyMinHeight: Double = 320

    public static func padding(defaults: UserDefaults = .standard) -> Double {
        let v = defaults.double(forKey: paddingKey)
        return (defaults.object(forKey: paddingKey) != nil && v.isFinite && v >= 0) ? v : defaultPadding
    }

    public static func emptyMinSize(defaults: UserDefaults = .standard) -> CGSize {
        func dim(_ key: String, _ fallback: Double) -> Double {
            let v = defaults.double(forKey: key)
            return (defaults.object(forKey: key) != nil && v.isFinite && v > 0) ? v : fallback
        }
        return CGSize(width: dim(emptyMinWidthKey, defaultEmptyMinWidth),
                      height: dim(emptyMinHeightKey, defaultEmptyMinHeight))
    }
}

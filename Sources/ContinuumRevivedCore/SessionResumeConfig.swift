import Foundation

/// Resolves configurable knobs for live-session resume (T13). Mirrors
/// `DragMagnetizeConfig` / `TileGapResolver` / `FocusBorderConfig`.
///
/// - `scrollbackEnabled`: whether the terminal scrollback snapshot is captured
///   and replayed on restore. Default true.
/// - `scrollbackMaxLines`: max lines captured in the scrollback snapshot at
///   flush time (tail). Default 2000.
public enum SessionResumeConfig {
    public static let scrollbackEnabledKey = "continuum.sessionResume.scrollback.enabled"
    public static let scrollbackEnabledDefault = true

    public static let scrollbackMaxLinesKey = "continuum.sessionResume.scrollback.maxLines"
    public static let scrollbackMaxLinesDefault = 2000

    public static func scrollbackEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: scrollbackEnabledKey) != nil
            ? defaults.bool(forKey: scrollbackEnabledKey)
            : scrollbackEnabledDefault
    }

    public static func scrollbackMaxLines(defaults: UserDefaults = .standard) -> Int {
        defaults.object(forKey: scrollbackMaxLinesKey) != nil
            ? defaults.integer(forKey: scrollbackMaxLinesKey)
            : scrollbackMaxLinesDefault
    }
}

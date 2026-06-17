import Foundation

/// Resolves whether the live "W × H" resize HUD is shown, from UserDefaults.
/// Mirrors `FocusBorderConfig`: one key + resolver here, one `SettingsField` in
/// `SettingsSchema`. AppKit-free.
public enum ResizeHUDConfig {
    public static let enabledKey = "continuum.resizeHUD.enabled"
    public static let defaultEnabled = true

    public static func enabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) != nil
            ? defaults.bool(forKey: enabledKey)
            : defaultEnabled
    }
}

import Foundation

/// The one user setting for composer dictation. On by default: the microphone
/// is only ever opened by an explicit gesture (the mic button or ⇧⌘D), and the
/// control is absent entirely on a macOS without the on-device transcriber.
public enum DictationConfig {
    public static let enabledKey = "continuum.dictation.enabled"
    public static let defaultEnabled = true

    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) == nil ? defaultEnabled : defaults.bool(forKey: enabledKey)
    }
}

import Foundation

/// Shut down a simulator Array booted once no preview has viewed it for a
/// grace period. A booted iOS simulator holds 2–3 GB; a parked preview tile
/// used to keep it running for good. Off by default.
public enum IOSPreviewReclaimConfig {
    public static let enabledKey = "iosPreview.shutDownUnviewedSimulators"
    public static let defaultEnabled = false
    /// Long enough that panning past a tile does not cost a reboot.
    public static let graceSeconds: Double = 120

    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) == nil ? defaultEnabled : defaults.bool(forKey: enabledKey)
    }
}

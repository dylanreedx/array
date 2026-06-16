import Foundation

public enum WorkspaceProfileConfig {
    public static let defaultCaptureModeKey = "continuum.workspaceProfile.defaultCaptureMode"
    public static let defaultCaptureMode: WorkspaceProfileCaptureMode = .snapshot
    public static let defaultApplyModeKey = "continuum.workspaceProfile.defaultApplyMode"
    public static let defaultApplyMode: WorkspaceProfileApplyMode = .restoreOver

    public static func captureMode(defaults: UserDefaults = .standard) -> WorkspaceProfileCaptureMode {
        guard let raw = defaults.string(forKey: defaultCaptureModeKey),
              let mode = WorkspaceProfileCaptureMode(rawValue: raw) else { return defaultCaptureMode }
        return mode
    }

    public static func applyMode(defaults: UserDefaults = .standard) -> WorkspaceProfileApplyMode {
        guard let raw = defaults.string(forKey: defaultApplyModeKey),
              let mode = WorkspaceProfileApplyMode(rawValue: raw) else { return defaultApplyMode }
        return mode
    }
}

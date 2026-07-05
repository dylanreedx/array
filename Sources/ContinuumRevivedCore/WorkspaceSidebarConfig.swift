import Foundation

public enum WorkspaceSidebarConfig {
    public static let visibleKey = "continuum.workspaceSidebar.visible"
    public static let widthKey = "continuum.workspaceSidebar.width"

    public static let defaultVisible = true
    public static let defaultWidth: Double = 280
    public static let minWidth: Double = 220
    public static let maxWidth: Double = 420

    public static func resolveVisible(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: visibleKey) != nil else { return defaultVisible }
        return defaults.bool(forKey: visibleKey)
    }

    public static func setVisible(_ visible: Bool, defaults: UserDefaults = .standard) {
        defaults.set(visible, forKey: visibleKey)
    }

    public static func resolveWidth(defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: widthKey) != nil else { return defaultWidth }
        if let stringValue = defaults.string(forKey: widthKey),
           let width = Double(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return clampedWidth(width)
        }
        return clampedWidth(defaults.double(forKey: widthKey))
    }

    public static func setWidth(_ width: Double, defaults: UserDefaults = .standard) {
        defaults.set(clampedWidth(width), forKey: widthKey)
    }

    public static func clampedWidth(_ width: Double) -> Double {
        min(max(width, minWidth), maxWidth)
    }
}

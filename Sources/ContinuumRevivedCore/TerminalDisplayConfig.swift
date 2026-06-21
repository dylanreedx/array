import Foundation

public enum TerminalDisplayConfig {
    /// Embedded shell font-size override. The Ghostty surface treats 0 as
    /// "inherit the loaded Ghostty config"; Continuum defaults to a larger
    /// embedded-shell size because canvas tiles are often viewed below native
    /// window scale.
    public static let fontSizeKey = "continuum.terminal.display.fontSize"
    public static let defaultFontSize = 16.0
    public static let minFontSize = 10.0
    public static let maxFontSize = 28.0

    /// Returns nil when the user explicitly asks to inherit Ghostty's configured
    /// font size (currently by setting the preference to 0). Missing or invalid
    /// values use Continuum's readability default.
    public static func fontSize(defaults: UserDefaults = .standard) -> Double? {
        guard let object = defaults.object(forKey: fontSizeKey) else {
            return defaultFontSize
        }
        guard let raw = rawDouble(from: object), raw.isFinite else {
            return defaultFontSize
        }
        if raw == 0 { return nil }
        guard raw > 0 else { return defaultFontSize }
        return min(max(raw, minFontSize), maxFontSize)
    }

    public static func surfaceFontSize(defaults: UserDefaults = .standard) -> Float {
        Float(fontSize(defaults: defaults) ?? 0)
    }

    private static func rawDouble(from object: Any) -> Double? {
        if let number = object as? NSNumber { return number.doubleValue }
        if let string = object as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            if ["inherit", "ghostty", "default"].contains(trimmed.lowercased()) { return 0 }
            return Double(trimmed)
        }
        return nil
    }
}

import Foundation
import ContinuumRevivedAgentUI

public enum EditorDocumentOpenDisposition: String, Codable, Sendable {
    case replaceCurrent
    case newTile
}

public enum EditorAppearance: String, Codable, CaseIterable, Sendable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
}

/// User-wide editor settings. Read a fresh snapshot after a SettingChangeEvent;
/// native and web surfaces consume the same values without replacing documents.
public struct EditorPreferences: Equatable, Sendable {
    public static let appearanceKey = "array.editor.appearance"
    public static let fontFamilyKey = "array.editor.fontFamily"
    public static let fontSizeKey = "array.editor.fontSize"
    public static let lineHeightKey = "array.editor.lineHeight"
    public static let lineNumbersKey = "array.editor.lineNumbers"
    public static let wordWrapKey = "array.editor.wordWrap"
    public static let vimEnabledKey = "array.editor.vimEnabled"
    public static let allKeys = [appearanceKey, fontFamilyKey, fontSizeKey, lineHeightKey, lineNumbersKey, wordWrapKey, vimEnabledKey]
    public static let defaultFontFamily = "System Monospaced"
    public static let defaultFontSize = 13.0
    public static let defaultLineHeight = 1.5
    public static let fontSizeRange = 9.0...32.0
    public static let lineHeightRange = 1.1...2.2

    public let appearance: EditorAppearance
    public let fontFamily: String
    public let fontSize: Double
    public let lineHeight: Double
    public let lineNumbers: Bool
    public let wordWrap: Bool
    public let vimEnabled: Bool

    public init(defaults: UserDefaults = .standard) {
        appearance = defaults.string(forKey: Self.appearanceKey).flatMap(EditorAppearance.init(rawValue:)) ?? .system
        let font = defaults.string(forKey: Self.fontFamilyKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        fontFamily = font.isEmpty ? Self.defaultFontFamily : font
        fontSize = Self.number(defaults, key: Self.fontSizeKey, fallback: Self.defaultFontSize, range: Self.fontSizeRange)
        lineHeight = Self.number(defaults, key: Self.lineHeightKey, fallback: Self.defaultLineHeight, range: Self.lineHeightRange)
        lineNumbers = defaults.object(forKey: Self.lineNumbersKey) == nil ? true : defaults.bool(forKey: Self.lineNumbersKey)
        wordWrap = defaults.bool(forKey: Self.wordWrapKey)
        vimEnabled = defaults.bool(forKey: Self.vimEnabledKey)
    }

    public func resolve(systemIsDark: Bool) -> EditorThemeTokens {
        let dark = appearance == .dark || (appearance == .system && systemIsDark)
        return dark ? .dark : .light
    }

    public static func setVimEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: vimEnabledKey)
        SettingChangeEvent.post(SettingID(rawValue: vimEnabledKey))
    }

    private static func number(_ defaults: UserDefaults, key: String, fallback: Double, range: ClosedRange<Double>) -> Double {
        guard let value = defaults.object(forKey: key) as? NSNumber, value.doubleValue.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value.doubleValue))
    }
}

/// Hex colors intentionally remain platform-neutral so AppKit and CodeMirror
/// share one palette without involving Array's global theme system.
public struct EditorThemeTokens: Equatable, Codable, Sendable {
    public let isDark: Bool
    public let background: String
    public let foreground: String
    public let sidebarBackground: String
    public let chromeBackground: String
    public let border: String
    public let mutedForeground: String
    public let selection: String
    public let hover: String
    public let accent: String
    public let gutterBackground: String
    public let gutterForeground: String
    public let activeLine: String
    public let error: String
    public let warning: String

    /// AppKit consumes the same named palette values that CodeMirror receives
    /// as CSS hex strings, through the existing platform-neutral colour bridge.
    public func resolvedColor(_ key: KeyPath<EditorThemeTokens, String>) -> ChipColor {
        let value = UInt32(self[keyPath: key].dropFirst(), radix: 16) ?? 0
        return ChipColor(r: Double((value >> 16) & 255) / 255,
                         g: Double((value >> 8) & 255) / 255, b: Double(value & 255) / 255)
    }

    public static let light = EditorThemeTokens(
        isDark: false, background: "#FAFBFC", foreground: "#263244",
        sidebarBackground: "#F3F5F7", chromeBackground: "#F3F5F7",
        border: "#E1E6EC", mutedForeground: "#69788C", selection: "#CED9FA",
        hover: "#EDF0F5", accent: "#4263EB", gutterBackground: "#FAFBFC",
        gutterForeground: "#69788C", activeLine: "#EDF0F5", error: "#C33E48", warning: "#946A12"
    )
    public static let dark = EditorThemeTokens(
        isDark: true, background: "#171B22", foreground: "#DCE3ED",
        sidebarBackground: "#1C212A", chromeBackground: "#1C212A",
        border: "#303846", mutedForeground: "#8996AA", selection: "#364665",
        hover: "#212834", accent: "#91A7FF", gutterBackground: "#171B22",
        gutterForeground: "#8996AA", activeLine: "#212834", error: "#FF9494", warning: "#E7BE70"
    )
}

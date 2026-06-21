import AppKit
import Foundation
import GhosttyKit

/// Resolved color data from the same Ghostty config object used to create the
/// embedded terminal app. This intentionally mirrors Ghostty's public C config
/// API instead of reparsing user config files in Continuum.
struct GhosttyThemeSnapshot: Equatable {
    var backgroundHex: String?
    var foregroundHex: String?
    var paletteHex: [String]
    var backgroundOpacity: Double?
    var cursorStyle: String?
    var diagnostics: [String]

    static let empty = GhosttyThemeSnapshot(
        backgroundHex: nil,
        foregroundHex: nil,
        paletteHex: [],
        backgroundOpacity: nil,
        cursorStyle: nil,
        diagnostics: []
    )

    var backgroundColor: NSColor? {
        backgroundHex.flatMap(Self.color(hex:))
    }

    var manifestValue: [String: Any] {
        [
            "backgroundHex": Self.jsonValue(backgroundHex),
            "foregroundHex": Self.jsonValue(foregroundHex),
            "paletteHex0To15": Array(paletteHex.prefix(16)),
            "backgroundOpacity": Self.jsonValue(backgroundOpacity),
            "cursorStyle": Self.jsonValue(cursorStyle),
            "diagnostics": diagnostics
        ]
    }

    static func capture(config: ghostty_config_t) -> GhosttyThemeSnapshot {
        GhosttyThemeSnapshot(
            backgroundHex: configColorHex("background", from: config),
            foregroundHex: configColorHex("foreground", from: config),
            paletteHex: configPaletteHex(from: config),
            backgroundOpacity: configDouble("background-opacity", from: config),
            cursorStyle: configCString("cursor-style", from: config),
            diagnostics: configDiagnostics(from: config)
        )
    }

    static func hexString(cgColor: CGColor?) -> String? {
        guard let cgColor, let color = NSColor(cgColor: cgColor) else { return nil }
        return hexString(color: color)
    }

    static func hexString(color: NSColor?) -> String? {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return nil }
        let r = UInt8(max(0, min(255, (rgb.redComponent * 255).rounded())))
        let g = UInt8(max(0, min(255, (rgb.greenComponent * 255).rounded())))
        let b = UInt8(max(0, min(255, (rgb.blueComponent * 255).rounded())))
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    private static func jsonValue<T>(_ value: T?) -> Any {
        value ?? NSNull()
    }

    private static func color(hex: String) -> NSColor? {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines))
        guard trimmed.count == 6, let raw = UInt32(trimmed, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((raw >> 16) & 0xff) / 255.0,
            green: CGFloat((raw >> 8) & 0xff) / 255.0,
            blue: CGFloat(raw & 0xff) / 255.0,
            alpha: 1.0
        )
    }

    private static func configColorHex(_ key: String, from config: ghostty_config_t) -> String? {
        var color = ghostty_config_color_s(r: 0, g: 0, b: 0)
        let ok = key.withCString { pointer in
            ghostty_config_get(config, &color, pointer, UInt(key.utf8.count))
        }
        guard ok else { return nil }
        return hex(color)
    }

    private static func configPaletteHex(from config: ghostty_config_t) -> [String] {
        var palette = ghostty_config_palette_s()
        let key = "palette"
        let ok = key.withCString { pointer in
            ghostty_config_get(config, &palette, pointer, UInt(key.utf8.count))
        }
        guard ok else { return [] }
        return withUnsafeBytes(of: palette.colors) { rawBuffer -> [String] in
            let colors = rawBuffer.bindMemory(to: ghostty_config_color_s.self)
            return colors.prefix(256).map(hex)
        }
    }

    private static func configDouble(_ key: String, from config: ghostty_config_t) -> Double? {
        var value = 0.0
        let ok = key.withCString { pointer in
            ghostty_config_get(config, &value, pointer, UInt(key.utf8.count))
        }
        return ok ? value : nil
    }

    private static func configCString(_ key: String, from config: ghostty_config_t) -> String? {
        var value: UnsafePointer<CChar>?
        let ok = key.withCString { pointer in
            ghostty_config_get(config, &value, pointer, UInt(key.utf8.count))
        }
        guard ok, let value else { return nil }
        return String(cString: value)
    }

    private static func configDiagnostics(from config: ghostty_config_t) -> [String] {
        let count = ghostty_config_diagnostics_count(config)
        guard count > 0 else { return [] }
        return (0..<count).compactMap { index in
            let diagnostic = ghostty_config_get_diagnostic(config, index)
            guard let message = diagnostic.message else { return nil }
            let text = String(cString: message)
            return text.isEmpty ? nil : text
        }
    }

    private static func hex(_ color: ghostty_config_color_s) -> String {
        String(format: "#%02x%02x%02x", color.r, color.g, color.b)
    }
}

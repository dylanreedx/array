import Foundation

/// Resolves the focused-tile marching-ants border's appearance from UserDefaults
/// (docs/29 §1), mirroring `ZoneChromeFeature` / `TileGapResolver`. AppKit-free:
/// `color` is a name from `colorOptions` that the App layer maps to an `NSColor`.
/// Adding a knob = one key + one field here + one `SettingsField`.
public enum FocusBorderConfig {
    public static let enabledKey = "continuum.focusBorder.enabled"
    public static let colorKey = "continuum.focusBorder.color"
    public static let gapKey = "continuum.focusBorder.gap"
    public static let speedKey = "continuum.focusBorder.speed"

    public static let defaultEnabled = true
    public static let defaultColor = "System Accent"
    public static let defaultGap: Double = 8
    /// Marching-ants loop duration (s). Lower = faster. Matches the pre-config
    /// constant so behavior is unchanged when no preference is set.
    public static let defaultSpeed: Double = 2.5
    // The attention ring's COLOR no longer lives here (P1.6). It used to be
    // `attentionColor = "Orange"`, resolved through the App layer's user-palette
    // map to `systemOrange`, which `--ui-contrast-check` measured at 2.07:1 on a
    // light tile. The semantic ("orange means human action is required") is
    // unchanged but now carried by `StatusChipPresenter.display(for:
    // .needsAttention).accent` — P1.8's single status→appearance mapping, whose
    // amber has a darkened light-appearance variant. Its SPEED is still a
    // canvas-behaviour constant, so it stays.
    /// Faster than the normal focus march so attention remains distinct when a
    /// focused tile is also waiting on the human.
    public static let attentionSpeed: Double = 1.4

    /// Named color palette — the single source shared by `SettingsSchema` (the
    /// `.choice` options), the App's name→`NSColor` map, and the round-trip check.
    public static let colorOptions = ["System Accent", "Blue", "Mint", "Orange", "Pink"]

    public struct Resolution: Equatable, Sendable {
        public let enabled: Bool
        public let color: String
        public let gap: Double
        public let speed: Double

        public init(enabled: Bool, color: String, gap: Double, speed: Double) {
            self.enabled = enabled
            self.color = color
            self.gap = gap
            self.speed = speed
        }
    }

    public static func resolvedFromDefaults(defaults: UserDefaults = .standard) -> Resolution {
        let enabled = defaults.object(forKey: enabledKey) != nil
            ? defaults.bool(forKey: enabledKey)
            : defaultEnabled
        let rawColor = defaults.string(forKey: colorKey)
        let color = (rawColor != nil && colorOptions.contains(rawColor!)) ? rawColor! : defaultColor
        let gap = positiveOr(defaults.double(forKey: gapKey), defaultGap)
        let speed = positiveOr(defaults.double(forKey: speedKey), defaultSpeed)
        return Resolution(enabled: enabled, color: color, gap: gap, speed: speed)
    }

    private static func positiveOr(_ value: Double, _ fallback: Double) -> Double {
        value.isFinite && value > 0 ? value : fallback
    }
}

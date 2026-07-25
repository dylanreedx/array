import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P1.2-tokencolor-light-dark.md
//
// `ChipColor` is a single sRGB triple — structurally incapable of expressing a
// theme, so "light mode" could only ever be "dark that doesn't break". A
// TokenColor carries BOTH values and resolves by theme, which is what lets the
// later gates assert contrast per appearance rather than once.
//
// Foundation only, on purpose. `TokenTheme` deliberately has no `system`/`auto`
// case and never mentions NSAppearance/UITraitCollection: resolving the user's
// current appearance is the platform layer's job, and this type stays a pure
// value the matrix can evaluate offline.

/// Which of a token's two values applies. `allCases` is what every later gate
/// iterates, so a token can never be checked in one theme only.
public enum TokenTheme: String, CaseIterable, Sendable {
    case light
    case dark
}

/// A colour token with a value per theme. The leaf is `ChipColor` (already
/// platform-neutral sRGB with a `hexKey`), so `WCAGContrast` applies unchanged
/// to a resolved pair.
public struct TokenColor: Equatable, Sendable {
    public let light: ChipColor
    public let dark: ChipColor

    public init(light: ChipColor, dark: ChipColor) {
        self.light = light
        self.dark = dark
    }

    /// The same colour in both themes — for tokens that genuinely do not vary
    /// (a brand fill, a fixed-on-colour foreground). Explicit, so an unthemed
    /// token is a decision in the source rather than an oversight.
    public init(_ both: ChipColor) {
        self.init(light: both, dark: both)
    }

    public func resolved(for theme: TokenTheme) -> ChipColor {
        switch theme {
        case .light: return light
        case .dark: return dark
        }
    }
}
